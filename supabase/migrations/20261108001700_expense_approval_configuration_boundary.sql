begin;
-- Well-local, prospective-only configuration. No legacy rule reassignment.
create table finance.expense_approval_configurations(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null references core.tenants(id),well_id uuid not null references core.wells(id),
 sequence bigint not null check(sequence>0),previous_id uuid references finance.expense_approval_configurations(id),
 rules jsonb not null check(jsonb_typeof(rules)='array'),actor_id uuid not null references iam.profiles(id),
 accepted_at timestamptz not null,unique(well_id,sequence)
);
create table finance.expense_approval_contexts(
 expense_id uuid primary key references finance.expenses(id),tenant_id uuid not null references core.tenants(id),
 well_id uuid not null references core.wells(id),configuration_id uuid references finance.expense_approval_configurations(id),
 source text not null check(source in ('well_configuration','legacy_rules_snapshot')),
 category_id uuid references finance.expense_categories(id),amount_minor bigint not null,
 matched_rules jsonb not null,requires_approval boolean not null,initial_status text not null,
 captured_at timestamptz not null default clock_timestamp()
);
create function finance.reject_expense_approval_history_mutation() returns trigger language plpgsql set search_path=pg_catalog,pg_temp as $$
begin raise exception 'expense_approval_history_append_only' using errcode='23514';end;$$;
do $install$
declare tab text;
begin
 foreach tab in array array['expense_approval_configurations','expense_approval_contexts'] loop
  execute format('alter table finance.%I enable row level security',tab);
  execute format('revoke all on finance.%I from public,anon,authenticated,service_role',tab);
  execute format('grant select on finance.%I to authenticated',tab);
  execute format('create policy expense_approval_context_read on finance.%I for select to authenticated
   using(iam.has_well_role(well_id,array[''owner'',''manager'',''operator'']) or iam.is_well_partner(well_id))',tab);
  execute format('create trigger expense_approval_history_immutable before update or delete on finance.%I
   for each row execute function finance.reject_expense_approval_history_mutation()',tab);
 end loop;
end;$install$;
revoke all on function finance.reject_expense_approval_history_mutation() from public,anon,authenticated,service_role;

create function api.set_expense_approval_configuration(p_well_id uuid,p_rules jsonb)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare tenant uuid;cfg finance.expense_approval_configurations%rowtype;item jsonb;category uuid;
 normalized jsonb:='[]'::jsonb;new_id uuid:=gen_random_uuid();stamp timestamptz;min_amount bigint;needed boolean;
begin
 if auth.uid() is null or not coalesce(iam.has_well_role(p_well_id,array['owner','manager']),false) then
  raise exception 'expense_approval_configuration_forbidden' using errcode='42501';end if;
 select tenant_id into tenant from core.wells where id=p_well_id;
 perform billing.lock_customer_credit_well(p_well_id);
 if tenant is null or not exists(select 1 from core.wells where id=p_well_id and tenant_id=tenant)
  or not coalesce(iam.has_well_role(p_well_id,array['owner','manager']),false) then
  raise exception 'expense_approval_configuration_forbidden' using errcode='42501';end if;
 select * into cfg from finance.expense_approval_configurations where well_id=p_well_id order by sequence desc limit 1 for update;
 if p_rules is null or jsonb_typeof(p_rules)<>'array' then raise exception 'expense_approval_rules_required' using errcode='22023';end if;
 for item in select value from jsonb_array_elements(p_rules) loop
  if jsonb_typeof(item)<>'object' or (item-array['category_id','min_amount_minor','requires_approval'])<>'{}'::jsonb
   or jsonb_typeof(item->'min_amount_minor') is distinct from 'number'
   or jsonb_typeof(item->'requires_approval') is distinct from 'boolean' then
   raise exception 'expense_approval_rule_invalid' using errcode='22023';end if;
  min_amount:=(item->>'min_amount_minor')::bigint;needed:=(item->>'requires_approval')::boolean;category:=(item->>'category_id')::uuid;
  if min_amount<0 or (item->>'min_amount_minor')::numeric<>min_amount then
   raise exception 'expense_approval_threshold_invalid' using errcode='22023';end if;
  if category is not null and not exists(select 1 from finance.expense_categories c where c.id=category and c.tenant_id=tenant
   and(c.well_id is null or c.well_id=p_well_id)) then
   raise exception 'expense_approval_category_scope_invalid' using errcode='23514';end if;
  normalized:=normalized||jsonb_build_array(jsonb_build_object('category_id',category,'min_amount_minor',min_amount,'requires_approval',needed));
 end loop;
 stamp:=clock_timestamp();
 insert into finance.expense_approval_configurations(id,tenant_id,well_id,sequence,previous_id,rules,actor_id,accepted_at)
 values(new_id,tenant,p_well_id,coalesce(cfg.sequence,0)+1,cfg.id,normalized,auth.uid(),stamp);
 return jsonb_build_object('status','saved','configuration_id',new_id,'well_id',p_well_id,'effective_from',stamp,
  'title','تم تحديث إعدادات اعتماد المصروفات','message','ستطبق على المصروفات الجديدة فقط. المصروفات المنتظرة حاليًا لن تتغير.','action','عرض الإعدادات');
end;$$;
revoke all on function api.set_expense_approval_configuration(uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function api.set_expense_approval_configuration(uuid,jsonb) to authenticated;

-- Same existing bool_or semantics: rules are minimum thresholds, optionally
-- category-specific; any matching requires_approval=true requires approval.
-- No maximum-band, multiple-voter, auto-approval or new approver semantics.
create function finance.expense_approval_context(p_well uuid,p_category uuid,p_amount bigint) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare cfg finance.expense_approval_configurations%rowtype;rules jsonb;needed boolean;
begin
 select * into cfg from finance.expense_approval_configurations where well_id=p_well order by sequence desc limit 1;
 if found then
  select coalesce(jsonb_agg(x order by x::text),'[]'::jsonb),coalesce(bool_or((x->>'requires_approval')::boolean),false)
  into rules,needed from jsonb_array_elements(cfg.rules) x
  where ((x->>'category_id')::uuid is null or(x->>'category_id')::uuid=p_category) and p_amount>=(x->>'min_amount_minor')::bigint;
 else
  select coalesce(jsonb_agg(to_jsonb(r) order by r.id),'[]'::jsonb),coalesce(bool_or(r.requires_approval),false)
  into rules,needed from finance.expense_approval_rules r where r.tenant_id=(select tenant_id from core.wells where id=p_well)
  and(r.well_id is null or r.well_id=p_well) and(r.category_id is null or r.category_id=p_category)
  and p_amount>=r.min_amount_minor and r.effective_period @> current_date;
 end if;
 return jsonb_build_object('configuration_id',cfg.id,'source',case when cfg.id is null then 'legacy_rules_snapshot' else 'well_configuration' end,
  'matched_rules',rules,'requires_approval',needed,'initial_status',case when needed then 'pending_approval' else 'posted' end);
end;$$;
revoke all on function finance.expense_approval_context(uuid,uuid,bigint) from public,anon,authenticated,service_role;

create function finance.capture_expense_approval_context() returns trigger language plpgsql security definer
set search_path=pg_catalog,pg_temp as $$
declare ctx jsonb;
begin
 ctx:=finance.expense_approval_context(new.well_id,new.category_id,new.amount_minor);
 if ctx->>'configuration_id' is not null and new.status in ('posted','pending_approval')
  and new.status<>ctx->>'initial_status' then
  raise exception 'expense_approval_context_mismatch' using errcode='23514';end if;
 insert into finance.expense_approval_contexts(expense_id,tenant_id,well_id,configuration_id,source,category_id,amount_minor,
 matched_rules,requires_approval,initial_status)
 values(new.id,new.tenant_id,new.well_id,(ctx->>'configuration_id')::uuid,ctx->>'source',new.category_id,new.amount_minor,
 ctx->'matched_rules',(ctx->>'requires_approval')::boolean,new.status);
 return new;
end;$$;
create trigger expenses_approval_context_capture after insert on finance.expenses
 for each row execute function finance.capture_expense_approval_context();
revoke all on function finance.capture_expense_approval_context() from public,anon,authenticated,service_role;

create function api.get_expense_approval_configuration(p_well_id uuid) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare cfg finance.expense_approval_configurations%rowtype;
begin
 if auth.uid() is null or not coalesce(iam.has_well_role(p_well_id,array['owner','manager']),false) then
  raise exception 'expense_approval_configuration_forbidden' using errcode='42501';end if;
 select * into cfg from finance.expense_approval_configurations where well_id=p_well_id order by sequence desc limit 1;
 return jsonb_build_object('title','اعتماد المصروفات','current',case when cfg.id is not null then to_jsonb(cfg) else
  jsonb_build_object('source','legacy_rules','rules',coalesce((select jsonb_agg(to_jsonb(r) order by r.id) from finance.expense_approval_rules r
   where r.tenant_id=(select tenant_id from core.wells where id=p_well_id) and(r.well_id is null or r.well_id=p_well_id) and r.effective_period @> current_date),'[]'::jsonb)) end,
  'history',coalesce((select jsonb_agg(to_jsonb(c) order by sequence) from finance.expense_approval_configurations c where well_id=p_well_id),'[]'::jsonb),
  'save_notice','سيطبق هذا التغيير على المصروفات الجديدة فقط. المصروفات المنتظرة حاليًا لن تتغير.','save_action','حفظ الإعدادات',
  'automatic_label','المصروفات حتى هذا المبلغ','approval_label','المصروفات التي تحتاج موافقة');
end;$$;
revoke all on function api.get_expense_approval_configuration(uuid) from public,anon,authenticated,service_role;
grant execute on function api.get_expense_approval_configuration(uuid) to authenticated;
create or replace function finance.record_expense(
  p_well_id uuid,
  p_category_code text,
  p_amount_minor bigint,
  p_description text,
  p_created_by uuid default null,
  p_attachment_url text default null,
  p_attachment_skipped boolean default false,
  p_payment_source text default 'cashbox',
  p_note text default null,
  p_partner_id uuid default null,
  p_attachment_skip_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path to 'finance', 'core', 'ops', 'pg_temp'
as $$
declare
  v_tenant uuid;
  v_cat uuid;
  v_requires boolean := false;
  v_status text;
  v_id uuid;
  v_attachment_url text;
  v_skip_reason text;
  v_skipped boolean;
begin
  perform billing.lock_customer_credit_well(p_well_id);
  select tenant_id into v_tenant from core.wells where id = p_well_id;
  if v_tenant is null then
    raise exception 'البئر % غير موجود', p_well_id;
  end if;

  select id into v_cat from finance.expense_categories
  where tenant_id = v_tenant and code = p_category_code and is_active
   and(well_id is null or well_id=p_well_id);
  if v_cat is null then
    raise exception 'نوع المصروف % غير معروف', p_category_code;
  end if;

  -- ═══ تحقّق الإثبات: مرفق صريح أو تخطٍ صريح بسببه — حصريًا ═══
  --    التطبيع: الفراغ والبياض يصيران NULL، ولا يُقبل سبب في
  --    حقل الملاحظات بديلًا (الطي القديم في Flutter ينتهي هنا).
  v_attachment_url := nullif(btrim(coalesce(p_attachment_url, '')), '');
  v_skip_reason := nullif(btrim(coalesce(p_attachment_skip_reason, '')), '');
  v_skipped := coalesce(p_attachment_skipped, false);

  if v_attachment_url is not null and v_skipped then
    raise exception 'لا يجوز إرفاق السند مع تخطي المرفق في الوقت نفسه';
  end if;
  if v_attachment_url is not null and v_skip_reason is not null then
    raise exception 'لا يجوز إرفاق السند مع تدوين سبب تخطٍ';
  end if;
  if v_skip_reason is not null and not v_skipped then
    raise exception 'سبب التخطي بلا تخطٍ صريح — علّم التخطي أو احذف السبب';
  end if;
  if v_skipped and v_skip_reason is null then
    raise exception 'سبب التخطي إلزامي عند تخطي المرفق ولا يقبل فراغًا';
  end if;
  if v_attachment_url is null and not v_skipped then
    raise exception 'إرفاق صورة السند/الفاتورة أو التخطي الصريح بسببه إلزامي';
  end if;

  if p_payment_source = 'partner_paid' and p_partner_id is null then
    raise exception 'مصروف دفعه شريك من جيبه يلزم تحديد الشريك';
  end if;

  v_requires:=(finance.expense_approval_context(p_well_id,v_cat,p_amount_minor)->>'requires_approval')::boolean;

  v_status := case when v_requires then 'pending_approval' else 'posted' end;

  insert into finance.expenses (
    tenant_id, well_id, category_id, amount_minor, description, payment_source,
    created_by, attachment_url, attachment_skipped, attachment_skip_reason,
    status, note, partner_id
  ) values (
    v_tenant, p_well_id, v_cat, p_amount_minor, p_description, p_payment_source,
    p_created_by, v_attachment_url, v_skipped, v_skip_reason,
    v_status, p_note, p_partner_id
  ) returning id into v_id;

  return v_id;
end;
$$;
-- Historical shared rows remain unchanged. No tenant-wide mutation survives
-- through the old direct client surface (including 050 dynamic manager policy).
revoke insert,update,delete,truncate on finance.expense_approval_rules from public,anon,authenticated,service_role;
do $acl$ declare c record;begin
 for c in select attname from pg_attribute where attrelid='finance.expense_approval_rules'::regclass and attnum>0 and not attisdropped loop
  execute format('revoke insert (%I),update (%I) on finance.expense_approval_rules from public,anon,authenticated,service_role',c.attname,c.attname);
 end loop;
end;$acl$;
drop policy if exists expense_approval_rules_insert_owner on finance.expense_approval_rules;
drop policy if exists expense_approval_rules_update_owner on finance.expense_approval_rules;
drop policy if exists expense_approval_rules_insert_owner_manager on finance.expense_approval_rules;
drop policy if exists expense_approval_rules_update_owner_manager on finance.expense_approval_rules;
-- SELECT and historical expense/approval rows remain untouched.
commit;
