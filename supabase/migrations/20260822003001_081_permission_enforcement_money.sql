-- =====================================================================
-- Migration 081 — W1-03b/1 — إكمال الكتالوج + نقل إنفاذ المال والمالية
-- القرار: ق-113 (W1-03b Enforcement wiring)
-- المسألة: م-18
--
-- الغرض:
--   نقل سلطة الصلاحية في نطاق المال والمالية من مصفوفات الأدوار
--   النصية إلى `iam.has_well_permission`، وإضافة الصلاحية المفقودة
--   `session.energy.change` إلى الكتالوج تمهيدًا لـ082.
--   13 موضعًا في 13 دالة.
--
-- قواعد التصميم:
--   1) لا توسيع ولا تضييق صلاحية. أُثبت قبل الكتابة أن كل موضع
--      يعطي نفس المجموعة بالضبط عبر المصدرين
--      (29 موضعًا مفحوصًا، 28 EQUIVALENT، 0 DIFFERS، NO_SILENT_DRIFT).
--   2) أجساد الدوال منقولة آليًا بلا تعديل؛ التغيير الوحيد المسموح
--      هو استبدال نداء السلطة نفسه. أُثبت بالمقارنة الآلية.
--   3) فحوص الهوية (actor = صاحب المناوبة، actor is null) تبقى كما هي.
--      تحويلها إلى فحص صلاحية يضيف شرطًا لم يكن موجودًا.
--   4) `iam.has_well_role` تبقى دون تغيير: 273 RLS policy تعتمدها
--      كطبقة توافق. هذه الهجرة لا تلمس أي policy.
--   5) `create or replace function` يحفظ الصلاحيات القائمة،
--      فلا تُعاد صياغة grant/revoke ولا تتغير مساحة الـAPI.
--   6) الدوال ذات التعريف المتعدد تُنقل من أحدث تعريف حيّ فقط.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- A) إكمال الكتالوج — صلاحية مفقودة
--
-- `ops.change_session_energy_source` تسمح للمالك والمدير والمشغل
-- بتحويل مصدر الطاقة أثناء جلسة جارية، ولا يوجد لها code في
-- الكتالوج إطلاقًا. بلا هذه الإضافة لا يمكن نقل ذلك الموضع.
--
-- إضافة محضة: لا شيء يستهلك هذه الصلاحية في هذه الهجرة،
-- فسلوك المستخدم لا يتغير بها. المستهلك في Migration 082.
-- ---------------------------------------------------------------------

insert into iam.permissions (code, description_ar)
values ('session.energy.change', 'تغيير مصدر الطاقة أثناء جلسة سقي جارية')
on conflict (code) do nothing;

-- المنح تطابق حرس الدالة الحالي حرفيًا: owner + manager + operator.
insert into iam.role_permissions (role_id, permission_id)
select r.id, p.id
from (values
  ('tenant_owner'),
  ('well_manager'),
  ('operator')
) as x(role_code)
join iam.roles r on r.code = x.role_code
join iam.permissions p on p.code = 'session.energy.change'
on conflict do nothing;


-- ---------------------------------------------------------------------
-- B) billing.issue_session_invoice
--    المصدر: 20260814043001_066_session_procedures.sql
--    الصلاحية: invoice.issue
-- ---------------------------------------------------------------------

create or replace function billing.issue_session_invoice(
  p_session_id uuid,
  p_issued_by uuid
)
returns uuid
language plpgsql
security definer
set search_path to 'billing', 'ops', 'finance', 'core', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_well_id uuid;
  v_farmer_well_account_id uuid;
  v_session_status text;
  v_ended_at timestamptz;
  v_charge_amount bigint;
  v_invoice_id uuid;
  v_partner_policy_id uuid;
  v_partner_policy_type text;
  v_settlement_method text := 'normal';
  v_line_number integer := 0;
  v_lines_total bigint;
  v_segment record;
  v_time_rate bigint;
  v_fuel_quantity bigint;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إصدار فاتورة الجلسة';
  end if;
  if p_issued_by is distinct from v_actor then
    raise exception 'مصدر الفاتورة يجب أن يطابق المستخدم المسجل حاليًا';
  end if;

  select w.tenant_id, s.well_id, s.farmer_well_account_id,
         s.status, s.ended_at
  into v_tenant_id, v_well_id, v_farmer_well_account_id,
       v_session_status, v_ended_at
  from ops.irrigation_sessions s
  join core.wells w on w.id = s.well_id
  where s.id = p_session_id
  for update of s;

  if not found then
    raise exception 'جلسة السقي غير موجودة: %', p_session_id;
  end if;
  if v_session_status <> 'closed' then
    raise exception 'لا يمكن إصدار فاتورة قبل إكمال الجلسة';
  end if;
  if not iam.has_well_permission(v_well_id, 'invoice.issue') then
    raise exception 'لا تملك صلاحية إصدار فاتورة هذه الجلسة';
  end if;
  if v_farmer_well_account_id is null then
    raise exception 'لا يمكن إصدار الفاتورة لأن الجلسة غير مرتبطة بحساب مزارع';
  end if;
  if exists (
    select 1 from billing.invoices i
    where i.session_id = p_session_id
      and i.status not in ('cancelled', 'reversed')
  ) then
    raise exception 'توجد فاتورة سارية مسبقًا لهذه الجلسة';
  end if;
  if not exists (
    select 1 from ops.session_segments ss
    where ss.session_id = p_session_id
      and ss.ended_at is not null
  ) then
    raise exception 'لا توجد مقاطع مكتملة يمكن بناء بنود الفاتورة منها';
  end if;

  select sc.amount_minor
  into v_charge_amount
  from billing.session_charges sc
  where sc.session_id = p_session_id
    and sc.pricing_mode = 'segments';

  if not found then
    raise exception 'لا يوجد ملخص تكلفة مقاطع مكتمل لهذه الجلسة';
  end if;

  select pip.id, pip.policy_type
  into v_partner_policy_id, v_partner_policy_type
  from ops.farmer_well_accounts fwa
  join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
  join core.well_partners wp
    on wp.well_id = fwa.well_id and wp.person_id = fp.person_id
  join core.partner_irrigation_policies pip
    on pip.partner_id = wp.id and pip.well_id = fwa.well_id
  where fwa.id = v_farmer_well_account_id
    and pip.period_start <= v_ended_at::date
    and (pip.period_end is null or pip.period_end > v_ended_at::date)
  order by pip.period_start desc, pip.created_at desc, pip.id desc
  limit 1;

  if found and v_partner_policy_type = 'deduct_from_profit' then
    v_settlement_method := 'partner_profit_offset';
  end if;

  insert into billing.invoices (
    tenant_id, public_code, well_id, farmer_well_account_id,
    session_id, invoice_date, status, subtotal_minor, total_minor,
    paid_minor, outstanding_minor, settlement_method, partner_policy_id
  ) values (
    v_tenant_id, core.generate_public_code('INV'), v_well_id,
    v_farmer_well_account_id, p_session_id, v_ended_at, 'draft',
    v_charge_amount, v_charge_amount, 0, v_charge_amount,
    v_settlement_method, v_partner_policy_id
  )
  returning id into v_invoice_id;

  for v_segment in
    select ss.id, ss.sequence_number, ss.segment_type, ss.energy_source,
           ss.billable_seconds, ss.applied_hourly_rate_minor,
           ss.applied_operation_rate_minor,
           ss.applied_fuel_price_per_liter_minor,
           ss.fuel_actual_ml, ss.fuel_estimated_ml,
           ss.time_charge_minor, ss.fuel_charge_minor,
           ss.total_charge_minor
    from ops.session_segments ss
    where ss.session_id = p_session_id
      and ss.is_billable
      and ss.total_charge_minor > 0
    order by ss.sequence_number
  loop
    if v_segment.time_charge_minor > 0 then
      v_line_number := v_line_number + 1;
      v_time_rate := coalesce(v_segment.applied_operation_rate_minor,
                              v_segment.applied_hourly_rate_minor);

      insert into billing.invoice_lines (
        tenant_id, invoice_id, line_number, line_type, description,
        quantity, unit, unit_price_minor, amount_minor,
        session_segment_id
      ) values (
        v_tenant_id, v_invoice_id, v_line_number,
        case when v_segment.energy_source = 'solar'
          then 'solar_irrigation' else 'diesel_operation' end,
        case when v_segment.energy_source = 'solar'
          then 'سقي شمسي — المقطع ' || v_segment.sequence_number
          else 'تشغيل ديزل — المقطع ' || v_segment.sequence_number end,
        v_segment.billable_seconds::numeric / 3600,
        'hour', v_time_rate, v_segment.time_charge_minor,
        v_segment.id
      );
    end if;

    if v_segment.fuel_charge_minor > 0 then
      v_line_number := v_line_number + 1;
      v_fuel_quantity := coalesce(v_segment.fuel_actual_ml,
                                  v_segment.fuel_estimated_ml);

      insert into billing.invoice_lines (
        tenant_id, invoice_id, line_number, line_type, description,
        quantity, unit, unit_price_minor, amount_minor,
        session_segment_id
      ) values (
        v_tenant_id, v_invoice_id, v_line_number, 'diesel_fuel',
        'وقود ديزل — المقطع ' || v_segment.sequence_number,
        v_fuel_quantity::numeric / 1000,
        'liter', v_segment.applied_fuel_price_per_liter_minor,
        v_segment.fuel_charge_minor, v_segment.id
      );
    end if;
  end loop;

  if v_line_number = 0 then
    raise exception 'لم تنتج مقاطع الجلسة أي بند قابل للفوترة';
  end if;

  select coalesce(sum(il.amount_minor), 0)
  into v_lines_total
  from billing.invoice_lines il
  where il.invoice_id = v_invoice_id;

  if v_lines_total <> v_charge_amount then
    raise exception 'مجموع بنود الفاتورة % لا يساوي تكلفة الجلسة %',
      v_lines_total, v_charge_amount;
  end if;

  update billing.invoices
  set status = 'issued',
      issued_at = clock_timestamp(),
      issued_by = p_issued_by
  where id = v_invoice_id;

  return v_invoice_id;
end;
$function$;

-- ---------------------------------------------------------------------
-- C) billing.record_payment
--    المصدر: 20260815023001_068_money_procedures.sql
--    الصلاحية: payment.create
-- ---------------------------------------------------------------------

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
set search_path to 'billing', 'finance', 'ops', 'core', 'audit', 'iam', 'pg_temp'
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
  -- 1) صلاحية المستخدم والدور.
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل تسجيل الدفعة';
  end if;
  if not iam.has_well_permission(p_well_id, 'payment.create') then
    raise exception 'لا تملك صلاحية تسجيل دفعة لهذا البئر';
  end if;

  -- 2) البئر وحساب المزارع.
  select w.tenant_id into v_tenant_id
  from core.wells w
  where w.id = p_well_id;
  if not found then
    raise exception 'البئر غير موجود: %', p_well_id;
  end if;
  if p_farmer_well_account_id is null then
    raise exception 'حساب المزارع غير موجود أو غير فعال في هذا البئر';
  end if;
  perform 1 from ops.farmer_well_accounts fwa
    where fwa.id = p_farmer_well_account_id
      and fwa.well_id = p_well_id
      and fwa.status = 'active'
  for update;
  if not found then
    raise exception 'حساب المزارع غير موجود أو غير فعال في هذا البئر';
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

  -- 4) الصندوق عند الدفع النقدي.
  v_cashbox_id := coalesce(p_cashbox_id, finance.main_cashbox_id(p_well_id));
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

    select sc.amount_minor - coalesce((
      select sum(p.amount_minor)
      from billing.payments p
      where p.session_charge_id = sc.id and p.status <> 'reversed'
    ), 0)
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

    -- 5) إنشاء الدفعة العادية؛ الزناد يقسم أي زيادة إلى رصيد مقدم.
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
    ) and (i.paid_minor + i.outstanding_minor <> i.total_minor
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

-- ---------------------------------------------------------------------
-- D) billing.allocate_payment
--    المصدر: 20260815023001_068_money_procedures.sql
--    الصلاحية: payment.allocate
-- ---------------------------------------------------------------------

create or replace function billing.allocate_payment(
  p_payment_id uuid,
  p_allocations jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'billing', 'finance', 'core', 'audit', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_payment billing.payments%rowtype;
  v_invoice billing.invoices%rowtype;
  v_item jsonb;
  v_invoice_id uuid;
  v_amount bigint;
  v_requested_total bigint := 0;
  v_allocated_before bigint;
  v_available bigint;
  v_allocation_id uuid;
  v_journal_id uuid;
  v_result_items jsonb := '[]'::jsonb;
  v_position integer := 0;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل توزيع الدفعة على الفواتير';
  end if;

  select p.* into v_payment
  from billing.payments p
  where p.id = p_payment_id
  for update;

  if not found then
    raise exception 'الدفعة غير موجودة: %', p_payment_id;
  end if;
  if v_payment.status <> 'posted' then
    raise exception 'لا يمكن توزيع دفعة حالتها % — يجب أن تكون مرحلة', v_payment.status;
  end if;
  if v_payment.farmer_well_account_id is null then
    raise exception 'لا يمكن توزيع الدفعة لأنها غير مرتبطة بحساب مزارع';
  end if;
  if not iam.has_well_permission(v_payment.well_id, 'payment.allocate') then
    raise exception 'لا تملك صلاحية توزيع دفعات هذا البئر';
  end if;
  if p_allocations is null or jsonb_typeof(p_allocations) <> 'array'
     or jsonb_array_length(p_allocations) = 0 then
    raise exception 'يجب إرسال فاتورة واحدة على الأقل مع مبلغ التخصيص';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(p_allocations) x
    group by x ->> 'invoice_id'
    having count(*) > 1
  ) then
    raise exception 'لا يجوز تكرار الفاتورة نفسها في طلب التوزيع';
  end if;

  for v_item in select value from jsonb_array_elements(p_allocations)
  loop
    begin
      v_invoice_id := (v_item ->> 'invoice_id')::uuid;
      v_amount := (v_item ->> 'amount_minor')::bigint;
    exception when others then
      raise exception 'صيغة تخصيص الفاتورة غير صالحة — يلزم invoice_id و amount_minor صحيحان';
    end;
    if v_invoice_id is null then
      raise exception 'معرف الفاتورة مطلوب في كل تخصيص';
    end if;
    if v_amount is null or v_amount <= 0 then
      raise exception 'مبلغ تخصيص كل فاتورة يجب أن يكون أكبر من صفر';
    end if;
    v_requested_total := v_requested_total + v_amount;
  end loop;

  select coalesce(sum(pa.allocated_minor), 0)
  into v_allocated_before
  from billing.payment_allocations pa
  where pa.payment_id = p_payment_id;

  v_available := v_payment.amount_minor - v_allocated_before;
  if v_requested_total > v_available then
    raise exception 'إجمالي التخصيص المطلوب % يتجاوز المتاح من الدفعة %',
      v_requested_total, v_available;
  end if;

  for v_item in
    select a.value
    from jsonb_array_elements(p_allocations) with ordinality as a(value, position)
    order by a.position
  loop
    v_position := v_position + 1;
    v_invoice_id := (v_item ->> 'invoice_id')::uuid;
    v_amount := (v_item ->> 'amount_minor')::bigint;

    select i.* into v_invoice
    from billing.invoices i
    where i.id = v_invoice_id
    for update;

    if not found then
      raise exception 'الفاتورة غير موجودة: %', v_invoice_id;
    end if;
    if v_invoice.well_id is distinct from v_payment.well_id
       or v_invoice.farmer_well_account_id is distinct from v_payment.farmer_well_account_id then
      raise exception 'الفاتورة % لا تخص البئر وحساب المزارع المرتبطين بالدفعة', v_invoice_id;
    end if;
    if v_invoice.status not in ('issued', 'partially_paid', 'overdue') then
      raise exception 'لا يمكن تخصيص دفعة لفاتورة حالتها %', v_invoice.status;
    end if;
    if v_amount > v_invoice.outstanding_minor then
      raise exception 'مبلغ التخصيص % يتجاوز دين الفاتورة المتبقي %',
        v_amount, v_invoice.outstanding_minor;
    end if;

    insert into billing.payment_allocations (
      tenant_id, payment_id, invoice_id, allocated_minor
    ) values (
      v_payment.tenant_id, p_payment_id, v_invoice_id, v_amount
    )
    returning id into v_allocation_id;

    update billing.invoices
    set paid_minor = paid_minor + v_amount,
        outstanding_minor = outstanding_minor - v_amount,
        status = case
          when outstanding_minor - v_amount = 0 then 'paid'
          else 'partially_paid'
        end
    where id = v_invoice_id;

    -- استخدام الرصيد المقدم يحوّل الالتزام إلى تسوية ذمة المزارع.
    if v_payment.purpose = 'advance' then
      v_journal_id := gen_random_uuid();
      insert into finance.journal_entries (
        id, tenant_id, public_code, well_id, entry_date,
        source_type, source_id, description, idempotency_key
      ) values (
        v_journal_id, v_payment.tenant_id, core.generate_public_code('JE'),
        v_payment.well_id, clock_timestamp(), 'advance_allocation',
        v_allocation_id, 'استخدام رصيد مقدم في الفاتورة ' || v_invoice.public_code,
        'ADV-ALLOC-' || v_allocation_id::text
      );

      insert into finance.journal_lines (
        tenant_id, journal_entry_id, ledger_account_id, entry_side,
        amount_minor, farmer_well_account_id, description
      ) values
        (v_payment.tenant_id, v_journal_id,
         finance.ledger_account_id(v_payment.well_id, '2000'), 'debit',
         v_amount, v_payment.farmer_well_account_id, 'استخدام الرصيد المقدم'),
        (v_payment.tenant_id, v_journal_id,
         finance.ledger_account_id(v_payment.well_id, '1100'), 'credit',
         v_amount, v_payment.farmer_well_account_id, 'تسديد ذمة فاتورة من الرصيد المقدم');

      perform finance.post_journal_entry(v_journal_id, v_actor);
    else
      v_journal_id := null;
    end if;

    perform audit.log(
      v_payment.tenant_id, v_payment.well_id,
      'allocate_payment', 'billing.payment_allocations', v_allocation_id,
      null,
      jsonb_build_object(
        'payment_id', p_payment_id,
        'invoice_id', v_invoice_id,
        'allocated_minor', v_amount,
        'position', v_position,
        'journal_entry_id', v_journal_id
      ),
      'توزيع دفعة على فاتورة'
    );

    v_result_items := v_result_items || jsonb_build_array(jsonb_build_object(
      'allocation_id', v_allocation_id,
      'invoice_id', v_invoice_id,
      'allocated_minor', v_amount,
      'invoice_status', case
        when v_invoice.outstanding_minor - v_amount = 0 then 'paid'
        else 'partially_paid'
      end,
      'journal_entry_id', v_journal_id
    ));
  end loop;

  if (select coalesce(sum(pa.allocated_minor), 0)
      from billing.payment_allocations pa
      where pa.payment_id = p_payment_id) > v_payment.amount_minor then
    raise exception 'فشل التحقق النهائي: مجموع التخصيصات تجاوز قيمة الدفعة';
  end if;

  return jsonb_build_object(
    'payment_id', p_payment_id,
    'allocated_minor', v_requested_total,
    'remaining_available_minor', v_available - v_requested_total,
    'allocations', v_result_items
  );
end;
$function$;

-- ---------------------------------------------------------------------
-- E) finance.pay_partner_distribution
--    المصدر: 20260815023001_068_money_procedures.sql
--    الصلاحية: distribution.pay
-- ---------------------------------------------------------------------

create or replace function finance.pay_partner_distribution(
  p_distribution_line_id uuid,
  p_amount_minor bigint,
  p_paid_by uuid default null,
  p_paid_at timestamptz default clock_timestamp()
)
returns jsonb
language plpgsql
security definer
set search_path to 'finance', 'core', 'audit', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_line finance.profit_distribution_lines%rowtype;
  v_cycle finance.profit_distribution_cycles%rowtype;
  v_remaining bigint;
  v_new_paid bigint;
  v_new_line_status text;
  v_new_cycle_status text;
  v_cashbox_id uuid;
  v_journal_id uuid;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل دفع مستحق الشريك';
  end if;
  if p_paid_by is not null and p_paid_by is distinct from v_actor then
    raise exception 'منفذ الدفع يجب أن يطابق المستخدم المسجل حاليًا';
  end if;
  if p_amount_minor is null or p_amount_minor <= 0 then
    raise exception 'مبلغ دفع الشريك يجب أن يكون أكبر من صفر';
  end if;

  select l.* into v_line
  from finance.profit_distribution_lines l
  where l.id = p_distribution_line_id
  for update;

  if not found then
    raise exception 'سطر توزيع الشريك غير موجود: %', p_distribution_line_id;
  end if;

  select c.* into v_cycle
  from finance.profit_distribution_cycles c
  where c.id = v_line.distribution_cycle_id
  for update;

  if not iam.has_well_permission(v_cycle.well_id, 'distribution.pay') then
    raise exception 'لا تملك صلاحية دفع مستحقات شركاء هذا البئر';
  end if;
  if v_line.status = 'paid' then
    raise exception 'مستحق الشريك في هذا السطر مدفوع بالكامل مسبقًا';
  end if;
  if v_cycle.status not in ('approved', 'partially_paid') then
    raise exception 'لا يمكن دفع مستحق شريك من دورة حالتها % — يجب أن تكون معتمدة', v_cycle.status;
  end if;
  if v_line.status not in ('approved', 'partially_paid') then
    raise exception 'لا يمكن دفع سطر حالته % — يجب أن يكون معتمدًا', v_line.status;
  end if;

  v_remaining := v_line.net_payable_minor - v_line.paid_minor;
  if v_remaining <= 0 then
    raise exception 'لا يوجد مبلغ متبقٍ لدفعه في مستحق الشريك';
  end if;
  if p_amount_minor > v_remaining then
    raise exception 'مبلغ الدفع % يتجاوز مستحق الشريك المتبقي %',
      p_amount_minor, v_remaining;
  end if;

  v_cashbox_id := finance.main_cashbox_id(v_cycle.well_id);
  if v_cashbox_id is null or not exists (
    select 1 from finance.cashboxes c
    where c.id = v_cashbox_id and c.status = 'active'
  ) then
    raise exception 'الصندوق الرئيسي غير موجود أو غير فعال لهذا البئر';
  end if;

  -- قيد الصرف: تخفيض مستحق الشريك مقابل النقد الخارج من الصندوق الرئيسي.
  v_journal_id := gen_random_uuid();
  insert into finance.journal_entries (
    id, tenant_id, public_code, well_id, entry_date,
    source_type, source_id, description, idempotency_key
  ) values (
    v_journal_id, v_cycle.tenant_id, core.generate_public_code('JE'),
    v_cycle.well_id, p_paid_at, 'partner_distribution_payment',
    v_journal_id, 'دفع مستحق شريك من دورة ' || v_cycle.public_code,
    'PDP-' || v_journal_id::text
  );

  insert into finance.journal_lines (
    tenant_id, journal_entry_id, ledger_account_id, entry_side,
    amount_minor, partner_id, cashbox_id, description
  ) values
    (v_cycle.tenant_id, v_journal_id,
     finance.ledger_account_id(v_cycle.well_id, '2100'), 'debit',
     p_amount_minor, v_line.partner_id, null, 'تخفيض مستحق الشريك'),
    (v_cycle.tenant_id, v_journal_id,
     finance.ledger_account_id(v_cycle.well_id, '1000'), 'credit',
     p_amount_minor, v_line.partner_id, v_cashbox_id, 'صرف من الصندوق الرئيسي');

  perform finance.post_journal_entry(v_journal_id, v_actor);

  v_new_paid := v_line.paid_minor + p_amount_minor;
  v_new_line_status := case
    when v_new_paid = v_line.net_payable_minor then 'paid'
    else 'partially_paid'
  end;

  update finance.profit_distribution_lines
  set paid_minor = v_new_paid,
      status = v_new_line_status
  where id = p_distribution_line_id;

  if exists (
    select 1 from finance.profit_distribution_lines l
    where l.distribution_cycle_id = v_cycle.id
      and l.paid_minor < greatest(l.net_payable_minor, 0)
  ) then
    v_new_cycle_status := 'partially_paid';
  else
    v_new_cycle_status := 'paid';
  end if;

  update finance.profit_distribution_cycles
  set status = v_new_cycle_status
  where id = v_cycle.id;

  perform audit.log(
    v_cycle.tenant_id, v_cycle.well_id,
    'pay_partner_distribution', 'finance.profit_distribution_lines',
    p_distribution_line_id,
    jsonb_build_object(
      'paid_minor', v_line.paid_minor,
      'status', v_line.status
    ),
    jsonb_build_object(
      'paid_minor', v_new_paid,
      'status', v_new_line_status,
      'cycle_status', v_new_cycle_status,
      'journal_entry_id', v_journal_id
    ),
    'دفع مستحق شريك'
  );

  return jsonb_build_object(
    'distribution_line_id', p_distribution_line_id,
    'paid_now_minor', p_amount_minor,
    'paid_total_minor', v_new_paid,
    'remaining_minor', v_line.net_payable_minor - v_new_paid,
    'line_status', v_new_line_status,
    'cycle_status', v_new_cycle_status,
    'journal_entry_id', v_journal_id
  );
end;
$function$;

-- ---------------------------------------------------------------------
-- F) api.record_expense
--    المصدر: 20260816235001_074_api_critical_flows.sql
--    الصلاحية: expense.create
-- ---------------------------------------------------------------------

create or replace function api.record_expense(
  p_well_id uuid,
  p_category_code text,
  p_amount_minor bigint,
  p_description text,
  p_attachment_url text default null,
  p_attachment_skipped boolean default false,
  p_payment_source text default 'cashbox',
  p_note text default null,
  p_partner_id uuid default null
)
returns uuid
language plpgsql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
declare
  v_actor uuid;
begin
  v_actor := auth.uid();

  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل تسجيل مصروف';
  end if;

  if not iam.has_well_permission(
    p_well_id,
    'expense.create'
  ) then
    raise exception 'لا تملك صلاحية تسجيل مصروف في هذا البئر';
  end if;

  return finance.record_expense(
    p_well_id,
    p_category_code,
    p_amount_minor,
    p_description,
    v_actor,
    p_attachment_url,
    p_attachment_skipped,
    p_payment_source,
    p_note,
    p_partner_id
  );
end;
$function$;

-- ---------------------------------------------------------------------
-- G) api.decide_expense
--    المصدر: 20260816235001_074_api_critical_flows.sql
--    الصلاحية: expense.approve
-- ---------------------------------------------------------------------

create or replace function api.decide_expense(
  p_expense_id uuid,
  p_approve boolean,
  p_note text default null
)
returns text
language plpgsql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_well_id uuid;
begin
  v_actor := auth.uid();

  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل اعتماد المصروف';
  end if;

  select e.well_id
  into v_well_id
  from finance.expenses e
  where e.id = p_expense_id;

  if not found then
    raise exception 'المصروف غير موجود: %', p_expense_id;
  end if;

  if not iam.has_well_permission(
    v_well_id,
    'expense.approve'
  ) then
    raise exception 'اعتماد المصروف خاص بمالك البئر';
  end if;

  return finance.decide_expense(
    p_expense_id,
    v_actor,
    p_approve,
    p_note
  );
end;
$function$;

-- ---------------------------------------------------------------------
-- H) api.confirm_handover
--    المصدر: 20260816235001_074_api_critical_flows.sql
--    الصلاحية: handover.confirm
-- ---------------------------------------------------------------------

create or replace function api.confirm_handover(
  p_handover_id uuid,
  p_confirmed_amount_minor bigint,
  p_difference_reason text default null
)
returns text
language plpgsql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_well_id uuid;
begin
  v_actor := auth.uid();

  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل تأكيد التسليم';
  end if;

  select h.well_id
  into v_well_id
  from ops.shift_handovers h
  where h.id = p_handover_id;

  if not found then
    raise exception 'إقرار التسليم غير موجود: %', p_handover_id;
  end if;

  if not iam.has_well_permission(
    v_well_id,
    'handover.confirm'
  ) then
    raise exception 'تأكيد التسليم خاص بمالك البئر';
  end if;

  return ops.confirm_handover(
    p_handover_id,
    p_confirmed_amount_minor,
    v_actor,
    p_difference_reason
  );
end;
$function$;

-- ---------------------------------------------------------------------
-- I) api.settle_handover
--    المصدر: 20260816235001_074_api_critical_flows.sql
--    الصلاحية: handover.settle
-- ---------------------------------------------------------------------

create or replace function api.settle_handover(
  p_handover_id uuid
)
returns text
language plpgsql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_well_id uuid;
begin
  v_actor := auth.uid();

  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل حسم فرق التسليم';
  end if;

  select h.well_id
  into v_well_id
  from ops.shift_handovers h
  where h.id = p_handover_id;

  if not found then
    raise exception 'إقرار التسليم غير موجود: %', p_handover_id;
  end if;

  if not iam.has_well_permission(
    v_well_id,
    'handover.settle'
  ) then
    raise exception 'حسم فرق التسليم خاص بمالك البئر';
  end if;

  return ops.settle_handover(
    p_handover_id,
    v_actor
  );
end;
$function$;

-- ---------------------------------------------------------------------
-- J) api.close_period
--    المصدر: 20260816235001_074_api_critical_flows.sql
--    الصلاحية: period.close
-- ---------------------------------------------------------------------

create or replace function api.close_period(
  p_period_id uuid
)
returns void
language plpgsql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_well_id uuid;
begin
  v_actor := auth.uid();

  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إغلاق الفترة';
  end if;

  select ap.well_id
  into v_well_id
  from finance.accounting_periods ap
  where ap.id = p_period_id;

  if not found then
    raise exception 'الفترة غير موجودة: %', p_period_id;
  end if;

  if not iam.has_well_permission(
    v_well_id,
    'period.close'
  ) then
    raise exception 'لا تملك صلاحية إغلاق هذه الفترة';
  end if;

  perform finance.close_period(
    p_period_id,
    v_actor
  );
end;
$function$;

-- ---------------------------------------------------------------------
-- K) api.calculate_profit_distribution
--    المصدر: 20260816235001_074_api_critical_flows.sql
--    الصلاحية: distribution.calculate
-- ---------------------------------------------------------------------

create or replace function api.calculate_profit_distribution(
  p_well_id uuid,
  p_period_start timestamptz,
  p_period_end timestamptz,
  p_manual_reserve_minor bigint default 0
)
returns uuid
language plpgsql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
declare
  v_actor uuid;
begin
  v_actor := auth.uid();

  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل احتساب توزيع الأرباح';
  end if;

  if not iam.has_well_permission(
    p_well_id,
    'distribution.calculate'
  ) then
    raise exception 'احتساب توزيع الأرباح خاص بمالك البئر';
  end if;

  if coalesce(p_manual_reserve_minor, 0) < 0 then
    raise exception 'الاحتياطي اليدوي لا يجوز أن يكون سالبًا';
  end if;

  return finance.calculate_profit_distribution(
    p_well_id,
    p_period_start,
    p_period_end,
    v_actor,
    coalesce(p_manual_reserve_minor, 0)
  );
end;
$function$;

-- ---------------------------------------------------------------------
-- L) api.approve_profit_distribution
--    المصدر: 20260816235001_074_api_critical_flows.sql
--    الصلاحية: distribution.approve
-- ---------------------------------------------------------------------

create or replace function api.approve_profit_distribution(
  p_cycle_id uuid
)
returns void
language plpgsql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_well_id uuid;
begin
  v_actor := auth.uid();

  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل اعتماد توزيع الأرباح';
  end if;

  select c.well_id
  into v_well_id
  from finance.profit_distribution_cycles c
  where c.id = p_cycle_id;

  if not found then
    raise exception 'دورة التوزيع غير موجودة: %', p_cycle_id;
  end if;

  if not iam.has_well_permission(
    v_well_id,
    'distribution.approve'
  ) then
    raise exception 'اعتماد توزيع الأرباح خاص بمالك البئر';
  end if;

  perform finance.approve_profit_distribution(
    p_cycle_id,
    v_actor
  );
end;
$function$;

-- ---------------------------------------------------------------------
-- M) api.accrue_payroll
--    المصدر: 20260816235001_074_api_critical_flows.sql
--    الصلاحية: payroll.accrue
-- ---------------------------------------------------------------------

create or replace function api.accrue_payroll(
  p_well_id uuid,
  p_person_id uuid,
  p_period_start date,
  p_period_end date,
  p_gross_minor bigint default null,
  p_deductions_minor bigint default 0
)
returns uuid
language plpgsql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
declare
  v_actor uuid;
begin
  v_actor := auth.uid();

  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل تسجيل استحقاق راتب';
  end if;

  if not iam.has_well_permission(
    p_well_id,
    'payroll.accrue'
  ) then
    raise exception 'لا تملك صلاحية تسجيل استحقاق راتب';
  end if;

  return finance.accrue_payroll(
    p_well_id,
    p_person_id,
    p_period_start,
    p_period_end,
    p_gross_minor,
    coalesce(p_deductions_minor, 0),
    v_actor
  );
end;
$function$;

-- ---------------------------------------------------------------------
-- N) api.pay_salary
--    المصدر: 20260816235001_074_api_critical_flows.sql
--    الصلاحية: payroll.pay
-- ---------------------------------------------------------------------

create or replace function api.pay_salary(
  p_accrual_id uuid
)
returns void
language plpgsql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_well_id uuid;
begin
  v_actor := auth.uid();

  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل صرف الراتب';
  end if;

  select a.well_id
  into v_well_id
  from finance.payroll_accruals a
  where a.id = p_accrual_id;

  if not found then
    raise exception 'مستحق الراتب غير موجود: %', p_accrual_id;
  end if;

  if not iam.has_well_permission(
    v_well_id,
    'payroll.pay'
  ) then
    raise exception 'لا تملك صلاحية صرف هذا الراتب';
  end if;

  perform finance.pay_salary(
    p_accrual_id,
    v_actor
  );
end;
$function$;


commit;
