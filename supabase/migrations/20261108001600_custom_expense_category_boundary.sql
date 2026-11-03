begin;
-- New categories are well-local. Legacy tenant categories stay unassigned and
-- read-only, with every historical category id/FK intact. No guessed backfill.
alter table finance.expense_categories add column well_id uuid references core.wells(id),
 add column created_by uuid references iam.profiles(id),add column modified_at timestamptz,
 add column modified_by uuid references iam.profiles(id);
create index expense_categories_well_idx on finance.expense_categories(well_id,is_active);
create table finance.custom_expense_category_history(
 id uuid primary key default gen_random_uuid(),category_id uuid not null references finance.expense_categories(id),
 tenant_id uuid not null references core.tenants(id),well_id uuid not null references core.wells(id),
 operation text not null check(operation in ('create','rename','activate','deactivate')),
 old_name text,new_name text not null,old_active boolean,new_active boolean not null,
 actor_id uuid not null references iam.profiles(id),accepted_at timestamptz not null default clock_timestamp()
);
alter table finance.custom_expense_category_history enable row level security;
revoke all on finance.custom_expense_category_history from public,anon,authenticated,service_role;
grant select on finance.custom_expense_category_history to authenticated;
create policy custom_category_history_read on finance.custom_expense_category_history for select to authenticated
 using(exists(select 1 from finance.expense_categories c where c.id=category_id));
create function finance.reject_custom_category_history_mutation() returns trigger
language plpgsql set search_path=pg_catalog,pg_temp as $$
begin raise exception 'custom_category_history_append_only' using errcode='23514';end;$$;
create trigger custom_category_history_immutable before update or delete on finance.custom_expense_category_history
 for each row execute function finance.reject_custom_category_history_mutation();
revoke all on function finance.reject_custom_category_history_mutation() from public,anon,authenticated,service_role;

create function finance.can_manage_custom_expense_category(p_well uuid) returns boolean
language sql stable security definer set search_path=pg_catalog,pg_temp as $$
 select auth.uid() is not null and exists(select 1 from core.well_assignments a where a.well_id=p_well
  and a.profile_id=auth.uid() and a.status='active'
  and(a.role='owner' or(a.role='operator' and iam.has_well_permission(p_well,'expense.create'))))
$$;
revoke all on function finance.can_manage_custom_expense_category(uuid) from public,anon,authenticated,service_role;

create function finance.mutate_custom_expense_category(p_well uuid,p_category uuid,p_name text,p_active boolean,p_operation text)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare tenant uuid;c finance.expense_categories%rowtype;candidate finance.expense_categories%rowtype;new_id uuid;stamp timestamptz;
begin
 if not finance.can_manage_custom_expense_category(p_well) then
  raise exception 'custom_category_permission_required' using errcode='42501';end if;
 select w.tenant_id into tenant from core.wells w where w.id=p_well;
 if p_category is not null then
  select x.* into candidate from finance.expense_categories x where x.id=p_category;
  if not found or candidate.well_id is distinct from p_well or candidate.tenant_id is distinct from tenant then
   raise exception 'custom_category_scope_invalid' using errcode='42501';end if;
 end if;
 perform billing.lock_customer_credit_well(p_well);
 if not finance.can_manage_custom_expense_category(p_well)
  or not exists(select 1 from core.wells w where w.id=p_well and w.tenant_id=tenant) then
  raise exception 'custom_category_permission_required' using errcode='42501';end if;
 if p_category is not null then
  select x.* into c from finance.expense_categories x where x.id=p_category for update of x;
  if not found or(c.well_id,c.tenant_id) is distinct from(p_well,tenant) then
   raise exception 'custom_category_scope_invalid' using errcode='42501';end if;
 end if;
 if p_operation not in ('create','rename','set_active') or p_operation is null
  or(p_operation='create' and p_category is not null) or(p_operation<>'create' and p_category is null) then
  raise exception 'custom_category_action_invalid' using errcode='22023';end if;
 if p_operation in ('create','rename') and nullif(btrim(p_name),'') is null then
  raise exception 'اسم التصنيف مطلوب' using errcode='22023';end if;
 if p_operation='set_active' and p_active is null then raise exception 'حالة التصنيف مطلوبة' using errcode='22023';end if;
 stamp:=clock_timestamp();
 if p_operation='create' then
  new_id:=gen_random_uuid();
  -- Existing journalize_expense uses its existing 5900 fallback when mapping
  -- is NULL. No client mapping parameter and no new accounting policy.
  insert into finance.expense_categories(id,tenant_id,well_id,code,name_ar,created_by,modified_at,modified_by)
  values(new_id,tenant,p_well,'custom_'||new_id::text,p_name,auth.uid(),stamp,auth.uid());
 else
  new_id:=c.id;
  update finance.expense_categories set name_ar=case when p_operation='rename' then p_name else name_ar end,
   is_active=case when p_operation='set_active' then p_active else is_active end,
   modified_at=stamp,modified_by=auth.uid() where id=c.id;
 end if;
 insert into finance.custom_expense_category_history(category_id,tenant_id,well_id,operation,old_name,new_name,old_active,new_active,actor_id,accepted_at)
 select new_id,tenant,p_well,case when p_operation='set_active' then case when p_active then 'activate' else 'deactivate' end else p_operation end,
 c.name_ar,x.name_ar,c.is_active,x.is_active,auth.uid(),stamp from finance.expense_categories x where x.id=new_id;
 return (select jsonb_build_object('status','saved','category_id',x.id,'well_id',x.well_id,'code',x.code,
  'name',x.name_ar,'is_active',x.is_active,'modified_at',x.modified_at,'title','تم حفظ التصنيف','action','عرض التصنيفات')
  from finance.expense_categories x where x.id=new_id);
end;$$;
revoke all on function finance.mutate_custom_expense_category(uuid,uuid,text,boolean,text) from public,anon,authenticated,service_role;
create function api.create_custom_expense_category(p_well_id uuid,p_name text) returns jsonb
language sql volatile security definer set search_path=pg_catalog,pg_temp as $$
 select finance.mutate_custom_expense_category(p_well_id,null,p_name,null,'create')
$$;
create function api.rename_custom_expense_category(p_category_id uuid,p_name text) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare w uuid;
begin
 select well_id into w from finance.expense_categories where id=p_category_id;
 return finance.mutate_custom_expense_category(w,p_category_id,p_name,null,'rename');
end;$$;
create function api.set_custom_expense_category_active(p_category_id uuid,p_is_active boolean) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare w uuid;
begin
 select well_id into w from finance.expense_categories where id=p_category_id;
 return finance.mutate_custom_expense_category(w,p_category_id,null,p_is_active,'set_active');
end;$$;
create function api.get_custom_expense_categories(p_well_id uuid) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,pg_temp as $$
begin
 if not finance.can_manage_custom_expense_category(p_well_id) then raise exception 'custom_category_permission_required' using errcode='42501';end if;
 return jsonb_build_object('title','تصنيفات المصروفات','create_action','إضافة تصنيف','name_field','اسم التصنيف','save_action','حفظ',
  'deactivate_title','إيقاف هذا التصنيف؟','deactivate_message','لن يظهر هذا التصنيف للمصروفات الجديدة، وستبقى المصروفات السابقة محفوظة كما هي.',
  'deactivate_action','إيقاف التصنيف','cancel_action','رجوع','reactivate_action','إعادة التفعيل','rename_action','تعديل الاسم',
  'categories',coalesce((select jsonb_agg(jsonb_build_object('category_id',c.id,'code',c.code,'name',c.name_ar,
   'is_active',c.is_active,'modified_at',c.modified_at) order by c.name_ar,c.id) from finance.expense_categories c where c.well_id=p_well_id),'[]'::jsonb),
  'history',coalesce((select jsonb_agg(to_jsonb(h) order by h.accepted_at,h.id) from finance.custom_expense_category_history h where h.well_id=p_well_id),'[]'::jsonb));
end;$$;
revoke all on function api.create_custom_expense_category(uuid,text),api.rename_custom_expense_category(uuid,text),
 api.set_custom_expense_category_active(uuid,boolean),api.get_custom_expense_categories(uuid) from public,anon,authenticated,service_role;
grant execute on function api.create_custom_expense_category(uuid,text),api.rename_custom_expense_category(uuid,text),
 api.set_custom_expense_category_active(uuid,boolean),api.get_custom_expense_categories(uuid) to authenticated;

-- Legacy SELECT visibility remains; new scoped categories are visible only in
-- their well. No historical category is rebound or guessed to belong to a well.
-- 050 generated *_manager policies dynamically from the old tenant policies.
-- Replace that additive broad-read policy as well, or it would bypass the new
-- per-well predicate despite replacing the explicitly declared base policy.
drop policy if exists expense_categories_select_member_manager on finance.expense_categories;
drop policy expense_categories_select_member on finance.expense_categories;
create policy expense_categories_select_member on finance.expense_categories for select using(
 (well_id is null and exists(select 1 from core.wells w where w.tenant_id=expense_categories.tenant_id
  and iam.has_well_role(w.id,array['owner','operator','manager'])))
 or(well_id is not null and iam.has_well_role(well_id,array['owner','operator','manager'])));
revoke insert,update,delete,truncate on finance.expense_categories from public,anon,authenticated,service_role;
do $acl$ declare c record;begin
 for c in select attname from pg_attribute where attrelid='finance.expense_categories'::regclass and attnum>0 and not attisdropped loop
  execute format('revoke insert (%I),update (%I) on finance.expense_categories from public,anon,authenticated,service_role',c.attname,c.attname);
 end loop;
end;$acl$;
drop policy if exists expense_categories_insert_owner_manager on finance.expense_categories;
drop policy if exists expense_categories_update_owner_manager on finance.expense_categories;
drop policy expense_categories_insert_owner on finance.expense_categories;
drop policy expense_categories_update_owner on finance.expense_categories;

-- Labels for NEW expenses are captured at insertion, not reconstructed after
-- rename. Legacy labels remain readable through their unmodified legacy ids.
alter table finance.expenses add column category_name_snapshot text;
create function finance.guard_expense_category_scope() returns trigger language plpgsql security definer
set search_path=pg_catalog,pg_temp as $$
declare c finance.expense_categories%rowtype;t uuid;
begin
 if tg_op='UPDATE' and new.category_id is not distinct from old.category_id then
  if new.category_name_snapshot is distinct from old.category_name_snapshot then
   raise exception 'expense_original_category_label_immutable' using errcode='23514';end if;
  return new;
 end if;
 select * into c from finance.expense_categories where id=new.category_id;
 select tenant_id into t from core.wells where id=new.well_id;
 if c.id is null or c.tenant_id is distinct from t or new.tenant_id is distinct from t
  or(c.well_id is not null and c.well_id is distinct from new.well_id) or not c.is_active then
  raise exception 'expense_category_unavailable' using errcode='23514',detail=
   '{"status":"choose_category","title":"هذا التصنيف غير متاح","message":"اختر تصنيفًا مفعّلًا لهذا البئر.","action":"اختيار تصنيف"}';end if;
 new.category_name_snapshot:=c.name_ar;return new;
end;$$;
create trigger zz_expense_category_scope before insert or update of category_id,category_name_snapshot on finance.expenses
 for each row execute function finance.guard_expense_category_scope();
revoke all on function finance.guard_expense_category_scope() from public,anon,authenticated,service_role;
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

  select coalesce(bool_or(r.requires_approval), false) into v_requires
  from finance.expense_approval_rules r
  where r.tenant_id = v_tenant
    and (r.well_id is null or r.well_id = p_well_id)
    and (r.category_id is null or r.category_id = v_cat)
    and p_amount_minor >= r.min_amount_minor
    and r.effective_period @> current_date;

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
create or replace function api.list_expense_categories(p_well_id uuid)
returns jsonb
language plpgsql
stable
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
declare
  v_actor uuid;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة فئات المصروفات';
  end if;
  if not (
    iam.has_well_permission(p_well_id, 'expense.create')
    or iam.has_well_permission(p_well_id, 'expense.approve')
  ) then
    raise exception 'قراءة فئات المصروفات خاصة بمن يملك صلاحية المصروفات في هذا البئر';
  end if;

  return jsonb_build_object(
    'categories',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'code', c.code,
          'name_ar', c.name_ar,
          'attachment_required', c.attachment_required,
          'requires_approval', c.requires_approval,
          'sort_order', c.sort_order
        )
        order by c.sort_order, c.name_ar, c.code
      )
      from finance.expense_categories c
      where c.is_active and(c.well_id is null or c.well_id=p_well_id)
        and c.tenant_id = (
          select w.tenant_id from core.wells w where w.id = p_well_id
        )
    ), '[]'::jsonb)
  );
end;
$function$;
create or replace function api.list_well_expenses(
  p_well_id uuid,
  p_status text default null,
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_status text := nullif(btrim(coalesce(p_status, '')), '');
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 500);
  v_partner_only boolean;
  v_items jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة المصروفات'
      using errcode = '28000';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  -- الحالات هي حالات finance.expenses الحقيقية لا قائمة مخترعة.
  if v_status is not null and v_status not in (
    'draft', 'pending_approval', 'approved', 'rejected', 'posted', 'reversed'
  ) then
    raise exception 'حالة مصروف غير معروفة: %', v_status
      using errcode = '22023';
  end if;

  if not exists (
    select 1
    from core.wells w
    where w.id = p_well_id
  ) then
    raise exception 'لا توجد صلاحية على هذا البئر'
      using errcode = '42501';
  end if;

  v_partner_only := iam.is_partner_only(p_well_id);

  select coalesce(
    jsonb_agg(x.item order by x.spent_at desc, x.id desc),
    '[]'::jsonb
  )
  into v_items
  from (
    select
      e.id,
      e.spent_at,
      jsonb_build_object(
        'id', e.id,
        'well_id', e.well_id,
        'public_code', e.public_code,
        'category_code', ec.code,
        'category_name', coalesce(e.category_name_snapshot,ec.name_ar),
        'amount_minor', e.amount_minor,
        'description', e.description,
        'status', e.status,
        'spent_at', e.spent_at,
        'payment_source', e.payment_source,
        'partner_id', e.partner_id,
        'partner_name', pp.full_name,
        'attachment_url', e.attachment_url,
        'attachment_skipped', e.attachment_skipped,
        'skip_reason', e.attachment_skip_reason,
        'recorded_by_name', case
          when v_partner_only then null
          else pf.full_name
        end
      ) as item
    from finance.expenses e
    left join finance.expense_categories ec on ec.id = e.category_id
    left join core.well_partners wp on wp.id = e.partner_id
    left join core.persons pp on pp.id = wp.person_id
    left join iam.profiles pf on pf.id = e.created_by
    where e.well_id = p_well_id
      and (v_status is null or e.status = v_status)
    order by e.spent_at desc, e.id desc
    limit v_limit
  ) x;

  return jsonb_build_object(
    'contract', 'list_well_expenses',
    'version', 1,
    'well_id', p_well_id,
    'partner_scope', v_partner_only,
    'expenses', v_items
  );
end;
$function$;
commit;
