-- Owner-adopted per-well account status. This is not global financial closure.
begin;
create table ops.farmer_account_status_history(
 id uuid primary key default gen_random_uuid(),account_id uuid not null references ops.farmer_well_accounts(id),
 tenant_id uuid not null references core.tenants(id),well_id uuid not null references core.wells(id),
 previous_status text not null,new_status text not null check(new_status in('active','inactive')),
 actor_id uuid not null references iam.profiles(id),accepted_at timestamptz not null default clock_timestamp()
);
alter table ops.farmer_account_status_history enable row level security;
create policy farmer_account_status_history_read on ops.farmer_account_status_history for select
 using(iam.has_well_role(well_id,array['owner','manager','operator']));
revoke all on ops.farmer_account_status_history from public,anon,authenticated,service_role;
grant select on ops.farmer_account_status_history to authenticated;
create trigger farmer_account_status_history_append_only before update or delete on ops.farmer_account_status_history
 for each row execute function finance.reject_distribution_source_history_mutation();

create function api.set_farmer_account_active(p_account_id uuid,p_is_active boolean) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare candidate ops.farmer_well_accounts%rowtype;locked ops.farmer_well_accounts%rowtype;target text;
begin
 if auth.uid() is null then raise exception 'authentication_required' using errcode='42501';end if;
 if p_is_active is null then raise exception 'farmer_account_state_required' using errcode='22023';end if;
 select * into candidate from ops.farmer_well_accounts where id=p_account_id;
 if not found then raise exception 'farmer_account_not_found' using errcode='22023';end if;
 perform billing.enter_financial_write(candidate.well_id,null,array['owner'],candidate.tenant_id);
 select * into locked from ops.farmer_well_accounts where id=p_account_id for update;
 if not found or(locked.tenant_id,locked.well_id,locked.farmer_profile_id)
  is distinct from(candidate.tenant_id,candidate.well_id,candidate.farmer_profile_id)
  or not coalesce(iam.has_well_role(locked.well_id,array['owner']),false) then
  raise exception 'farmer_account_owner_required' using errcode='42501';end if;
 target:=case when p_is_active then 'active' else 'inactive' end;
 if locked.status<>target then
  insert into ops.farmer_account_status_history(account_id,tenant_id,well_id,previous_status,new_status,actor_id)
  values(locked.id,locked.tenant_id,locked.well_id,locked.status,target,auth.uid());
  update ops.farmer_well_accounts set status=target where id=locked.id;
 end if;
 return jsonb_build_object('status','saved','account_id',locked.id,'account_status',target,
  'new_sessions_allowed',p_is_active,'new_bookings_allowed',p_is_active,'previous_debt_collection_allowed',true,
  'title',case when p_is_active then 'تم تفعيل حساب المزارع' else 'تم إيقاف حساب المزارع' end,
  'message',case when p_is_active then 'يمكن تسجيل جلسات وحجوزات جديدة لهذا المزارع في هذا البئر.'
   else 'لن تُسجل جلسات أو حجوزات جديدة. تبقى الديون السابقة متاحة للتحصيل، ويبقى السجل محفوظًا.' end,
  'action','عرض التفاصيل');
end;$$;
revoke all on function api.set_farmer_account_active(uuid,boolean) from public,anon,authenticated,service_role;
grant execute on function api.set_farmer_account_active(uuid,boolean) to authenticated;

-- Creation is already sanctioned by create_farmer/resolve_farmer_identity;
-- status, notes and credit limit now have their own narrow APIs below.
revoke insert,update,delete,truncate on ops.farmer_well_accounts from public,anon,authenticated,service_role;
do $acl$ declare c record;begin
 for c in select attname from pg_attribute where attrelid='ops.farmer_well_accounts'::regclass and attnum>0 and not attisdropped loop
  execute format('revoke insert (%I),update (%I) on ops.farmer_well_accounts from public,anon,authenticated,service_role',c.attname,c.attname);
 end loop;
end;$acl$;

-- Booking is operational-only. Share its existing well protection with the
-- root-owning status boundary before authoritatively checking the account.
create function ops.require_active_booking_farmer() returns trigger
language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
begin
 perform ops.lock_operational_scope(new.well_id);
 if not exists(select 1 from ops.farmer_well_accounts a where a.id=new.farmer_well_account_id
   and a.well_id=new.well_id and a.status='active') then
  raise exception 'farmer_account_not_active' using errcode='23514',
   detail='{"status":"not_available","title":"حساب المزارع موقوف","message":"لا يمكن إنشاء حجز جديد لهذا الحساب. اطلب من المالك إعادة تفعيله.","action":"عرض التفاصيل"}';end if;
 return new;
end;$$;
revoke all on function ops.require_active_booking_farmer() from public,anon,authenticated,service_role;
create trigger booking_active_farmer_account before insert on ops.irrigation_bookings
 for each row execute function ops.require_active_booking_farmer();

-- Deactivation blocks new execution, never collection of existing debt.
create or replace function billing.record_payment(
  p_well_id uuid,
  p_farmer_well_account_id uuid,
  p_amount_minor bigint,
  p_method text,
  p_allocations jsonb default '[]'::jsonb,
  p_session_charge_id uuid default null,
  p_payer_person_id uuid default null,
  p_cashbox_id uuid default null,
  p_paid_at timestamptz default clock_timestamp(),
  p_note text default null,
  p_attachment_url text default null
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,pg_temp
as $function$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_cashbox_id uuid;
  v_payment_id uuid;
  v_advance_payment_id uuid;
  v_payment_amount bigint;
  v_payment_purpose text;
  v_journal_id uuid;
  v_advance_journal_id uuid;
  v_requested_total bigint := 0;
  v_settled_minor bigint := 0;
  v_advance_minor bigint := 0;
  v_item jsonb;
  v_invoice_id uuid;
  v_item_amount bigint;
  v_charge_remaining bigint;
  v_existing_advance_ids uuid[] := '{}'::uuid[];
  v_allocation_summary jsonb := jsonb_build_object(
    'allocated_minor', 0, 'remaining_available_minor', 0, 'allocations', '[]'::jsonb
  );
begin
 perform billing.enter_financial_write(p_well_id,'payment.create',null);
  -- 1) صلاحية المستخدم والدور.
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل تسجيل الدفعة';
  end if;
  if not iam.has_well_permission(p_well_id, 'payment.create') then
    raise exception 'لا تملك صلاحية تسجيل دفعة لهذا البئر';
  end if;

  perform billing.lock_customer_credit_well(p_well_id);
  perform billing.require_no_disputed_invoice(i.id,p_amount_minor) from billing.invoices i
   where (p_session_charge_id is not null and i.session_id=(select session_id from billing.session_charges where id=p_session_charge_id))
;
  perform billing.require_no_disputed_invoice((x->>'invoice_id')::uuid,(x->>'amount_minor')::bigint) from jsonb_array_elements(p_allocations) x;


  -- 2) البئر وحساب المزارع.
  select w.tenant_id into v_tenant_id
  from core.wells w
  where w.id = p_well_id;
  if not found then
    raise exception 'البئر غير موجود: %', p_well_id;
  end if;
  if p_farmer_well_account_id is null then
    raise exception 'حساب المزارع غير موجود في هذا البئر';
  end if;
  perform 1 from ops.farmer_well_accounts fwa
    where fwa.id = p_farmer_well_account_id
      and fwa.well_id = p_well_id
  for update;
  if not found then
    raise exception 'حساب المزارع غير موجود في هذا البئر';
  end if;
  if p_payer_person_id is not null and not exists (
    select 1 from core.persons p
    where p.id = p_payer_person_id and p.tenant_id = v_tenant_id
  ) then
    raise exception 'الشخص الدافع غير موجود في الجهة التابعة لهذا البئر';
  end if;

  -- 3) المبلغ موجب.
  if p_amount_minor is null or p_amount_minor <= 0 then
    raise exception 'مبلغ الدفعة يجب أن يكون أكبر من صفر';
  end if;
  if p_method is null or p_method not in ('cash', 'bank_transfer', 'mobile_wallet', 'fuel_in_kind', 'offset_credit', 'other') then
    raise exception 'طريقة الدفع غير صالحة';
  end if;
  if p_allocations is null or jsonb_typeof(p_allocations) <> 'array' then
    raise exception 'قائمة تخصيص الفواتير يجب أن تكون مصفوفة';
  end if;

  for v_item in select value from jsonb_array_elements(p_allocations)
  loop
    begin
      v_invoice_id := (v_item ->> 'invoice_id')::uuid;
      v_item_amount := (v_item ->> 'amount_minor')::bigint;
    exception when others then
      raise exception 'صيغة تخصيص الفاتورة غير صالحة — يلزم invoice_id و amount_minor صحيحان';
    end;
    if v_invoice_id is null or v_item_amount is null or v_item_amount <= 0 then
      raise exception 'كل تخصيص يحتاج فاتورة ومبلغًا أكبر من صفر';
    end if;
    if not exists (
      select 1 from billing.invoices i
      where i.id = v_invoice_id
        and i.well_id = p_well_id
        and i.farmer_well_account_id = p_farmer_well_account_id
        and i.status in ('issued', 'partially_paid', 'overdue')
    ) then
      raise exception 'الفاتورة % غير مفتوحة أو لا تخص حساب المزارع المحدد', v_invoice_id;
    end if;
    v_requested_total := v_requested_total + v_item_amount;
  end loop;

  -- 4) الصندوق الحاكم عند الدفع النقدي (ق-131 بند 18).
  --    المشغل النشط: نقد المزارع يدخل حيازته حصرًا — تمرير معرف صندوق
  --    آخر (وفيه صندوق البئر العام) يُرفض، فلا يرسل المشغل نقدًا إلى
  --    main_well عبر المعامل. سلوك غير المشغل وغير النقدي كما كان.
  if p_method = 'cash'
     and finance.is_active_operator_assignment(p_well_id, v_actor) then
    if p_cashbox_id is not null
       and p_cashbox_id is distinct from finance.ensure_operator_custody_cashbox(p_well_id, v_actor) then
      raise exception 'لا يجوز للمشغل توجيه نقد المزارع إلى صندوق آخر: التحصيل النقدي يدخل حيازة المشغل لهذا البئر إلزامًا';
    end if;
    v_cashbox_id := finance.ensure_operator_custody_cashbox(p_well_id, v_actor);
  else
    v_cashbox_id := coalesce(p_cashbox_id, finance.main_cashbox_id(p_well_id));
  end if;
  if p_method = 'cash' and not exists (
    select 1 from finance.cashboxes c
    where c.id = v_cashbox_id and c.well_id = p_well_id and c.status = 'active'
  ) then
    raise exception 'الصندوق النقدي غير موجود أو غير فعال لهذا البئر';
  end if;

  if p_session_charge_id is not null then
    select coalesce(array_agg(p.id), '{}'::uuid[])
    into v_existing_advance_ids
    from billing.payments p
    where p.farmer_well_account_id = p_farmer_well_account_id
      and p.well_id = p_well_id
      and p.purpose = 'advance';

    select (select outstanding_minor from billing.session_economic_settlements where session_charge_id=sc.id)
    into v_charge_remaining
    from billing.session_charges sc
    join ops.irrigation_sessions s on s.id = sc.session_id
    where sc.id = p_session_charge_id
      and sc.well_id = p_well_id
      and s.farmer_well_account_id = p_farmer_well_account_id
    for update of sc;

    if not found then
      raise exception 'تكلفة الجلسة غير موجودة أو لا تخص حساب المزارع المحدد';
    end if;
    v_charge_remaining := greatest(v_charge_remaining, 0);
    if jsonb_array_length(p_allocations) > 0
       and v_requested_total <> least(p_amount_minor, v_charge_remaining) then
      raise exception 'مجموع الفواتير المختارة % يجب أن يساوي الجزء المسدد من المستحق %',
        v_requested_total, least(p_amount_minor, v_charge_remaining);
    end if;

    -- 5) إنشاء الدفعة العادية؛ الزناد يقسم أي زيادة إلى رصيد مقدم
    --    ويرث الصندوق الحاكم نفسه — فتتغير الحيازة بمبلغ الاستلام
    --    كاملًا مرة واحدة لا مرتين.
    insert into billing.payments (
      tenant_id, well_id, session_charge_id, farmer_well_account_id,
      payer_person_id, cashbox_id, collected_by_profile_id,
      received_by_profile_id, amount_minor, method, paid_at,
      purpose, status, note, attachment_url
    ) values (
      v_tenant_id, p_well_id, p_session_charge_id, p_farmer_well_account_id,
      p_payer_person_id, v_cashbox_id, v_actor,
      v_actor, p_amount_minor, p_method, p_paid_at,
      'session', 'posted', p_note, p_attachment_url
    )
    returning id, amount_minor, purpose
    into v_payment_id, v_payment_amount, v_payment_purpose;

    select p.journal_entry_id into v_journal_id
    from billing.payments p where p.id = v_payment_id;

    if v_payment_purpose = 'advance' then
      v_settled_minor := 0;
      v_advance_minor := v_payment_amount;
      v_advance_payment_id := v_payment_id;
      v_advance_journal_id := v_journal_id;
    else
      v_settled_minor := v_payment_amount;
      v_advance_minor := p_amount_minor - v_payment_amount;
    end if;

    -- 6-8) تخصيص الفواتير المختارة مع حارسي قيمة الدفعة والدين.
    if jsonb_array_length(p_allocations) > 0 then
      v_allocation_summary := billing.allocate_payment(v_payment_id, p_allocations);
    end if;

    -- 9) التحقق من الرصيد المقدم الذي أنشأه الزناد.
    if v_advance_minor > 0 and v_advance_payment_id is null then
      select p.id, p.journal_entry_id
      into v_advance_payment_id, v_advance_journal_id
      from billing.payments p
      where p.farmer_well_account_id = p_farmer_well_account_id
        and p.well_id = p_well_id
        and p.purpose = 'advance'
        and p.amount_minor = v_advance_minor
        and not (p.id = any(v_existing_advance_ids))
        and p.note like 'رصيد مقدم تلقائي:%'
      order by p.created_at desc, p.id desc
      limit 1;
      if not found then
        raise exception 'فشل التحقق من تحويل زيادة الدفعة إلى رصيد مقدم';
      end if;
    end if;
  else
    -- التحصيل العام يخصص المبلغ المختار، وما بقي يسجل رصيدًا مقدمًا.
    if v_requested_total > p_amount_minor then
      raise exception 'إجمالي تخصيص الفواتير % يتجاوز مبلغ الدفعة %',
        v_requested_total, p_amount_minor;
    end if;

    v_settled_minor := v_requested_total;
    v_advance_minor := p_amount_minor - v_settled_minor;

    if v_settled_minor > 0 then
      insert into billing.payments (
        tenant_id, well_id, farmer_well_account_id, payer_person_id,
        cashbox_id, collected_by_profile_id, received_by_profile_id,
        amount_minor, method, paid_at, purpose, status, note, attachment_url
      ) values (
        v_tenant_id, p_well_id, p_farmer_well_account_id, p_payer_person_id,
        v_cashbox_id, v_actor, v_actor,
        v_settled_minor, p_method, p_paid_at, 'old_debt', 'posted', p_note, p_attachment_url
      )
      returning id into v_payment_id;

      select p.journal_entry_id into v_journal_id
      from billing.payments p where p.id = v_payment_id;

      v_allocation_summary := billing.allocate_payment(v_payment_id, p_allocations);
    end if;

    if v_advance_minor > 0 then
      insert into billing.payments (
        tenant_id, well_id, farmer_well_account_id, payer_person_id,
        cashbox_id, collected_by_profile_id, received_by_profile_id,
        amount_minor, method, paid_at, purpose, status, note, attachment_url
      ) values (
        v_tenant_id, p_well_id, p_farmer_well_account_id, p_payer_person_id,
        v_cashbox_id, v_actor, v_actor,
        v_advance_minor, p_method, p_paid_at, 'advance', 'posted',
        coalesce(p_note || ' | ', '') || 'المتبقي بعد تخصيص الفواتير رصيد مقدم',
        p_attachment_url
      )
      returning id into v_advance_payment_id;

      select p.journal_entry_id into v_advance_journal_id
      from billing.payments p where p.id = v_advance_payment_id;

      if v_payment_id is null then
        v_payment_id := v_advance_payment_id;
        v_journal_id := v_advance_journal_id;
      end if;
    end if;
  end if;

  -- 10) التحقق من أن القيود المالية أنشئت ورحلت.
  if v_journal_id is null or not exists (
    select 1 from finance.journal_entries je
    where je.id = v_journal_id and je.status = 'posted'
  ) then
    raise exception 'فشل إنشاء القيد المالي المرحل للدفعة';
  end if;
  if v_advance_minor > 0 and (
    v_advance_journal_id is null or not exists (
      select 1 from finance.journal_entries je
      where je.id = v_advance_journal_id and je.status = 'posted'
    )
  ) then
    raise exception 'فشل إنشاء القيد المالي المرحل للرصيد المقدم';
  end if;

  -- 11) حالات الفواتير حدثها إجراء التخصيص؛ نتحقق من سلامة الأرصدة.
  if exists (
    select 1 from billing.invoices i
    where i.id in (
      select (x ->> 'invoice_id')::uuid from jsonb_array_elements(p_allocations) x
    ) and (i.paid_minor + i.outstanding_minor <> i.total_minor::numeric+i.correction_total_delta_minor
           or i.outstanding_minor < 0)
  ) then
    raise exception 'فشل التحقق النهائي من أرصدة الفواتير بعد الدفعة';
  end if;

  -- 12) سجل التدقيق.
  perform audit.log(
    v_tenant_id, p_well_id, 'record_payment', 'billing.payments', v_payment_id,
    null,
    jsonb_build_object(
      'payment_id', v_payment_id,
      'settled_minor', v_settled_minor,
      'advance_minor', v_advance_minor,
      'advance_payment_id', v_advance_payment_id,
      'journal_entry_id', v_journal_id,
      'advance_journal_entry_id', v_advance_journal_id
    ),
    'تسجيل دفعة وتوزيعها'
  );

  -- 13) الإيصال جزء من الملخص النهائي ويحمل رقم السند ووقته ومكوناته.
  return jsonb_build_object(
    'payment_id', v_payment_id,
    'settled_minor', v_settled_minor,
    'advance_minor', v_advance_minor,
    'journal_entry_id', v_journal_id,
    'advance_payment_id', v_advance_payment_id,
    'advance_journal_entry_id', v_advance_journal_id,
    'allocation', v_allocation_summary,
    'receipt', jsonb_build_object(
      'payment_id', v_payment_id,
      'public_code', (select p.public_code from billing.payments p where p.id = v_payment_id),
      'paid_at', p_paid_at,
      'amount_minor', p_amount_minor,
      'method', p_method,
      'payer_person_id', p_payer_person_id
    )
  );
end;
$function$;

create table ops.farmer_account_settings_history(
 id uuid primary key default gen_random_uuid(),account_id uuid not null references ops.farmer_well_accounts(id),
 tenant_id uuid not null references core.tenants(id),well_id uuid not null references core.wells(id),
 field_name text not null check(field_name in('credit_limit_minor','notes')),
 previous_value jsonb,new_value jsonb,actor_id uuid not null references iam.profiles(id),
 accepted_at timestamptz not null default clock_timestamp()
);
alter table ops.farmer_account_settings_history enable row level security;
create policy farmer_account_settings_history_read on ops.farmer_account_settings_history for select
 using(iam.has_well_role(well_id,array['owner','manager','operator']));
revoke all on ops.farmer_account_settings_history from public,anon,authenticated,service_role;
grant select on ops.farmer_account_settings_history to authenticated;
create trigger farmer_account_settings_history_append_only before update or delete on ops.farmer_account_settings_history
 for each row execute function finance.reject_distribution_source_history_mutation();

create function ops.lock_editable_farmer_account(p_account uuid,p_owner_only boolean)
returns ops.farmer_well_accounts language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare candidate ops.farmer_well_accounts%rowtype;locked ops.farmer_well_accounts%rowtype;
begin
 if auth.uid() is null then raise exception 'authentication_required' using errcode='42501';end if;
 select * into candidate from ops.farmer_well_accounts where id=p_account;
 if not found then raise exception 'farmer_account_not_found' using errcode='22023';end if;
 perform billing.enter_financial_write(candidate.well_id,null,case when p_owner_only then array['owner'] else array['owner','operator'] end,candidate.tenant_id);
 select * into locked from ops.farmer_well_accounts where id=p_account for update;
 if not found or(locked.well_id,locked.tenant_id,locked.farmer_profile_id)
  is distinct from(candidate.well_id,candidate.tenant_id,candidate.farmer_profile_id)
  or not(coalesce(iam.has_well_role(locked.well_id,array['owner']),false)
    or(not p_owner_only and coalesce(iam.has_well_role(locked.well_id,array['operator']),false)
     and coalesce(iam.has_well_permission(locked.well_id,'farmer.create'),false))) then
  raise exception 'farmer_account_settings_forbidden' using errcode='42501';end if;
 return locked;
end;$$;
revoke all on function ops.lock_editable_farmer_account(uuid,boolean) from public,anon,authenticated,service_role;

create function api.set_farmer_account_credit_limit(p_account_id uuid,p_limit_minor bigint) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare a ops.farmer_well_accounts%rowtype;
begin
 if p_limit_minor<0 then raise exception 'farmer_credit_limit_invalid' using errcode='22023';end if;
 a:=ops.lock_editable_farmer_account(p_account_id,true);
 if a.credit_limit_minor is distinct from p_limit_minor then
  insert into ops.farmer_account_settings_history(account_id,tenant_id,well_id,field_name,previous_value,new_value,actor_id)
  values(a.id,a.tenant_id,a.well_id,'credit_limit_minor',to_jsonb(a.credit_limit_minor),to_jsonb(p_limit_minor),auth.uid());
  update ops.farmer_well_accounts set credit_limit_minor=p_limit_minor where id=a.id;
 end if;
 return jsonb_build_object('status','saved','credit_limit_minor',p_limit_minor,'title','تم حفظ الحد الائتماني',
  'message','لم تتغير الديون أو الجلسات السابقة.','action','عرض التفاصيل');
end;$$;
create function api.set_farmer_account_notes(p_account_id uuid,p_notes text) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare a ops.farmer_well_accounts%rowtype;
begin
 a:=ops.lock_editable_farmer_account(p_account_id,false);
 if a.notes is distinct from p_notes then
  insert into ops.farmer_account_settings_history(account_id,tenant_id,well_id,field_name,previous_value,new_value,actor_id)
  values(a.id,a.tenant_id,a.well_id,'notes',to_jsonb(a.notes),to_jsonb(p_notes),auth.uid());
  update ops.farmer_well_accounts set notes=p_notes where id=a.id;
 end if;
 return jsonb_build_object('status','saved','notes',p_notes,'title','تم حفظ الملاحظات','action','عرض التفاصيل');
end;$$;
revoke all on function api.set_farmer_account_credit_limit(uuid,bigint),api.set_farmer_account_notes(uuid,text)
 from public,anon,authenticated,service_role;
grant execute on function api.set_farmer_account_credit_limit(uuid,bigint),api.set_farmer_account_notes(uuid,text) to authenticated;


-- A tenant-wide farmer identity is not a per-well status editor. Creation and
-- identity binding already use the sanctioned identity-resolution functions.
-- Preserve SELECT visibility; no shared identity mutation is exposed.
revoke insert,update,delete,truncate on ops.farmer_profiles from public,anon,authenticated,service_role;
do $profile_acl$ declare c record;begin
 for c in select attname from pg_attribute where attrelid='ops.farmer_profiles'::regclass and attnum>0 and not attisdropped loop
  execute format('revoke insert (%I),update (%I) on ops.farmer_profiles from public,anon,authenticated,service_role',c.attname,c.attname);
 end loop;
end;$profile_acl$;

-- Preserve the established API architecture: invoker-only public wrappers,
-- explicit protected implementations in a non-exposed schema. These names
-- belong exclusively to this unadopted R6-C2 follow-up set. Original argument
-- names/defaults, return types, volatility, owner authorization and API ACLs
-- are preserved. No helper acquires root later than its original boundary.
do $api_boundary$
declare f record;definition text;header text;implementation text;arguments text;
 signature text;internal_signature text;can_auth boolean;can_service boolean;
begin
 for f in select p.oid,p.proname,p.pronargs,pg_get_function_identity_arguments(p.oid) as identity_args
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='api' and p.prosecdef and p.proname=any(array[
   'add_opening_balance_item',
   'add_partner_distribution_adjustment',
   'add_well_partner',
   'cancel_partner_distribution_adjustment',
   'configure_fuel_tank',
   'create_custom_expense_category',
   'create_fuel_tank',
   'create_opening_balance_batch',
   'create_worker_compensation_rule',
   'deactivate_worker_compensation_rule',
   'disable_maintenance_reserve_rule',
   'get_custom_expense_categories',
   'get_distribution_configuration',
   'get_expense_approval_configuration',
   'get_legacy_invoice_accounting_review',
   'get_partner_distribution_sources',
   'get_partner_irrigation_policy',
   'get_worker_compensation_history',
   'open_legacy_invoice_accounting_review',
   'pay_departed_partner_source',
   'prepare_partner_payable_source',
   'preview_partner_share_change',
   'preview_worker_compensation_effective_date',
   'recalculate_profit_distribution',
   'record_partner_departure',
   'rename_cashbox',
   'rename_custom_expense_category',
   'resolve_legacy_invoice_accounting_review',
   'review_legacy_partner_expense_source',
   'select_partner_distribution_source',
   'set_custom_expense_category_active',
   'set_expense_approval_configuration',
   'set_farmer_account_active',
   'set_farmer_account_credit_limit',
   'set_farmer_account_notes',
   'set_maintenance_reserve_rule',
   'set_partner_irrigation_policy',
   'set_partner_shares',
   'set_well_partner_administrative_state',
   'update_distribution_settings',
   'update_opening_balance_item',
   'update_partner_distribution_adjustment',
   'update_well_partner_contact',
   'update_worker_compensation_rule'
  ]) order by p.proname,p.oid loop
  signature:=format('api.%I(%s)',f.proname,f.identity_args);
  implementation:='r6c2_api_'||f.proname;
  internal_signature:=format('finance.%I(%s)',implementation,f.identity_args);
  can_auth:=has_function_privilege('authenticated',f.oid,'EXECUTE');
  can_service:=has_function_privilege('service_role',f.oid,'EXECUTE');
  definition:=pg_get_functiondef(f.oid);
  execute replace(definition,'FUNCTION api.'||quote_ident(f.proname)||'(',
   'FUNCTION finance.'||quote_ident(implementation)||'(');
  execute format('revoke all on function %s from public,anon,authenticated,service_role',internal_signature);
  if can_auth then
   execute format('grant execute on function %s to authenticated,service_role',internal_signature);
   execute format('grant execute on function %s to service_role',signature);
  end if;
  if can_service then execute format('grant execute on function %s to service_role',internal_signature);end if;
  header:=split_part(definition,E'\nAS $function$',1);
  if header=definition then raise exception 'api_wrapper_definition_shape_unexpected: %',signature;end if;
  header:=regexp_replace(header,'LANGUAGE [a-z]+','LANGUAGE sql');
  header:=replace(header,'SECURITY DEFINER','SECURITY INVOKER');
  select string_agg('$'||k::text,',' order by k) into arguments from generate_series(1,f.pronargs) k;
  execute header||E'\nAS $r6_wrapper$ SELECT * FROM finance.'||quote_ident(implementation)||'('||coalesce(arguments,'')||'); $r6_wrapper$;';
 end loop;
end;$api_boundary$;

commit;
