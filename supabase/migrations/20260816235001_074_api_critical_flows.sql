-- =====================================================================
-- 074 — ق-79: استكمال عقد الكتابة للتدفقات الحرجة في MVP
--
-- يضيف أغلفة api آمنة للتدفقات القديمة التي كانت إجراءاتها الداخلية
-- موجودة قبل ق-78/ق-79:
-- - إنشاء الجهة والبئر
-- - المصروفات واعتمادها
-- - المناوبات والتسليم ونقل الجلسة
-- - إغلاق الفترة
-- - احتساب واعتماد الأرباح
-- - الرواتب الأساسية
--
-- الأغلفة SECURITY INVOKER.
-- هوية المنفذ مشتقة من auth.uid().
-- المخططات الداخلية تبقى غير مكشوفة عبر Data API.
-- =====================================================================


-- ---------------------------------------------------------------------
-- إنشاء الجهة والبئر
-- ---------------------------------------------------------------------

create function api.create_tenant_with_well(
  p_tenant_name text,
  p_well_name text
)
returns uuid
language sql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
  select core.create_tenant_with_well(
    p_tenant_name,
    p_well_name
  );
$function$;


-- ---------------------------------------------------------------------
-- المصروفات
-- ---------------------------------------------------------------------

create function api.record_expense(
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

  if not iam.has_well_role(
    p_well_id,
    array['owner', 'operator']
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


create function api.decide_expense(
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

  if not iam.has_well_role(
    v_well_id,
    array['owner']
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
-- المناوبات
-- ---------------------------------------------------------------------

create function api.open_shift(
  p_well_id uuid
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
    raise exception 'يجب تسجيل الدخول قبل بدء مناوبة';
  end if;

  if not iam.has_well_role(
    p_well_id,
    array['owner', 'operator']
  ) then
    raise exception 'لا تملك صلاحية بدء مناوبة في هذا البئر';
  end if;

  return ops.open_shift(
    p_well_id,
    v_actor
  );
end;
$function$;


create function api.close_shift(
  p_shift_id uuid,
  p_allow_open_sessions boolean default false
)
returns uuid
language plpgsql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_well_id uuid;
  v_operator_profile_id uuid;
begin
  v_actor := auth.uid();

  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إغلاق المناوبة';
  end if;

  select s.well_id, s.operator_profile_id
  into v_well_id, v_operator_profile_id
  from ops.shifts s
  where s.id = p_shift_id;

  if not found then
    raise exception 'المناوبة غير موجودة: %', p_shift_id;
  end if;

  if v_actor is distinct from v_operator_profile_id
     and not iam.has_well_role(
       v_well_id,
       array['owner']
     ) then
    raise exception 'لا تملك صلاحية إغلاق هذه المناوبة';
  end if;

  if p_allow_open_sessions
     and not iam.has_well_role(
       v_well_id,
       array['owner']
     ) then
    raise exception 'تجاوز الجلسات المفتوحة عند إغلاق المناوبة خاص بالمالك';
  end if;

  return ops.close_shift(
    p_shift_id,
    p_allow_open_sessions
  );
end;
$function$;


create function api.declare_handover(
  p_shift_id uuid,
  p_amount_minor bigint,
  p_to_profile_id uuid default null,
  p_to_description text default null,
  p_note text default null
)
returns uuid
language plpgsql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_operator_profile_id uuid;
begin
  v_actor := auth.uid();

  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إقرار التسليم';
  end if;

  select s.operator_profile_id
  into v_operator_profile_id
  from ops.shifts s
  where s.id = p_shift_id;

  if not found then
    raise exception 'المناوبة غير موجودة: %', p_shift_id;
  end if;

  if v_actor is distinct from v_operator_profile_id then
    raise exception 'إقرار التسليم يجب أن يصدر من مشغل المناوبة نفسه';
  end if;

  return ops.declare_handover(
    p_shift_id,
    p_amount_minor,
    p_to_profile_id,
    p_to_description,
    p_note
  );
end;
$function$;


create function api.confirm_handover(
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

  if not iam.has_well_role(
    v_well_id,
    array['owner']
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


create function api.settle_handover(
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

  if not iam.has_well_role(
    v_well_id,
    array['owner']
  ) then
    raise exception 'حسم فرق التسليم خاص بمالك البئر';
  end if;

  return ops.settle_handover(
    p_handover_id,
    v_actor
  );
end;
$function$;


create function api.request_session_transfer(
  p_session_id uuid,
  p_from_shift_id uuid,
  p_to_profile_id uuid,
  p_collection_right text,
  p_note text default null
)
returns uuid
language plpgsql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_well_id uuid;
  v_operator_profile_id uuid;
  v_shift_status text;
begin
  v_actor := auth.uid();

  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل طلب نقل الجلسة';
  end if;

  select
    s.well_id,
    s.operator_profile_id,
    s.status
  into
    v_well_id,
    v_operator_profile_id,
    v_shift_status
  from ops.shifts s
  where s.id = p_from_shift_id;

  if not found then
    raise exception 'المناوبة غير موجودة: %', p_from_shift_id;
  end if;

  if v_shift_status <> 'open' then
    raise exception 'طلب النقل يجب أن يصدر من مناوبة مفتوحة';
  end if;

  if v_actor is distinct from v_operator_profile_id then
    raise exception 'طلب نقل الجلسة يجب أن يصدر من مشغل المناوبة نفسه';
  end if;

  if not exists (
    select 1
    from ops.irrigation_sessions s
    where s.id = p_session_id
      and s.well_id = v_well_id
      and s.status = 'open'
      and (
        s.current_shift_id = p_from_shift_id
        or (
          s.current_shift_id is null
          and s.operator_profile_id = v_actor
        )
      )
  ) then
    raise exception 'الجلسة لا تنتمي إلى هذه المناوبة أو ليست مفتوحة';
  end if;

  return ops.request_session_transfer(
    p_session_id,
    p_from_shift_id,
    p_to_profile_id,
    p_collection_right,
    p_note
  );
end;
$function$;


create function api.respond_session_transfer(
  p_transfer_id uuid,
  p_accept boolean,
  p_to_shift_id uuid default null
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
  v_to_profile_id uuid;
begin
  v_actor := auth.uid();

  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل الرد على نقل الجلسة';
  end if;

  select
    t.well_id,
    t.to_profile_id
  into
    v_well_id,
    v_to_profile_id
  from ops.session_shift_transfers t
  where t.id = p_transfer_id;

  if not found then
    raise exception 'طلب النقل غير موجود: %', p_transfer_id;
  end if;

  if v_actor is distinct from v_to_profile_id then
    raise exception 'الرد على نقل الجلسة خاص بالمشغل المطلوب منه الاستلام';
  end if;

  if p_to_shift_id is not null
     and not exists (
       select 1
       from ops.shifts s
       where s.id = p_to_shift_id
         and s.well_id = v_well_id
         and s.operator_profile_id = v_actor
         and s.status = 'open'
     ) then
    raise exception 'المناوبة المستقبلة غير صالحة لهذا المشغل';
  end if;

  return ops.respond_session_transfer(
    p_transfer_id,
    p_accept,
    p_to_shift_id
  );
end;
$function$;


-- ---------------------------------------------------------------------
-- الإقفال وتوزيع الأرباح
-- ---------------------------------------------------------------------

create function api.close_period(
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

  if not iam.has_well_role(
    v_well_id,
    array['owner', 'manager']
  ) then
    raise exception 'لا تملك صلاحية إغلاق هذه الفترة';
  end if;

  perform finance.close_period(
    p_period_id,
    v_actor
  );
end;
$function$;


create function api.calculate_profit_distribution(
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

  if not iam.has_well_role(
    p_well_id,
    array['owner']
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


create function api.approve_profit_distribution(
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

  if not iam.has_well_role(
    v_well_id,
    array['owner']
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
-- الرواتب الأساسية
-- ---------------------------------------------------------------------

create function api.accrue_payroll(
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

  if not iam.has_well_role(
    p_well_id,
    array['owner', 'manager']
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


create function api.pay_salary(
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

  if not iam.has_well_role(
    v_well_id,
    array['owner', 'manager']
  ) then
    raise exception 'لا تملك صلاحية صرف هذا الراتب';
  end if;

  perform finance.pay_salary(
    p_accrual_id,
    v_actor
  );
end;
$function$;


-- ---------------------------------------------------------------------
-- منح صريحة فقط
-- ---------------------------------------------------------------------

revoke all on function api.create_tenant_with_well(text, text)
from public, anon, authenticated, service_role;
grant execute on function api.create_tenant_with_well(text, text)
to authenticated, service_role;

revoke all on function api.record_expense(
  uuid, text, bigint, text, text, boolean, text, text, uuid
) from public, anon, authenticated, service_role;
grant execute on function api.record_expense(
  uuid, text, bigint, text, text, boolean, text, text, uuid
) to authenticated, service_role;

revoke all on function api.decide_expense(uuid, boolean, text)
from public, anon, authenticated, service_role;
grant execute on function api.decide_expense(uuid, boolean, text)
to authenticated, service_role;

revoke all on function api.open_shift(uuid)
from public, anon, authenticated, service_role;
grant execute on function api.open_shift(uuid)
to authenticated, service_role;

revoke all on function api.close_shift(uuid, boolean)
from public, anon, authenticated, service_role;
grant execute on function api.close_shift(uuid, boolean)
to authenticated, service_role;

revoke all on function api.declare_handover(
  uuid, bigint, uuid, text, text
) from public, anon, authenticated, service_role;
grant execute on function api.declare_handover(
  uuid, bigint, uuid, text, text
) to authenticated, service_role;

revoke all on function api.confirm_handover(uuid, bigint, text)
from public, anon, authenticated, service_role;
grant execute on function api.confirm_handover(uuid, bigint, text)
to authenticated, service_role;

revoke all on function api.settle_handover(uuid)
from public, anon, authenticated, service_role;
grant execute on function api.settle_handover(uuid)
to authenticated, service_role;

revoke all on function api.request_session_transfer(
  uuid, uuid, uuid, text, text
) from public, anon, authenticated, service_role;
grant execute on function api.request_session_transfer(
  uuid, uuid, uuid, text, text
) to authenticated, service_role;

revoke all on function api.respond_session_transfer(
  uuid, boolean, uuid
) from public, anon, authenticated, service_role;
grant execute on function api.respond_session_transfer(
  uuid, boolean, uuid
) to authenticated, service_role;

revoke all on function api.close_period(uuid)
from public, anon, authenticated, service_role;
grant execute on function api.close_period(uuid)
to authenticated, service_role;

revoke all on function api.calculate_profit_distribution(
  uuid, timestamptz, timestamptz, bigint
) from public, anon, authenticated, service_role;
grant execute on function api.calculate_profit_distribution(
  uuid, timestamptz, timestamptz, bigint
) to authenticated, service_role;

revoke all on function api.approve_profit_distribution(uuid)
from public, anon, authenticated, service_role;
grant execute on function api.approve_profit_distribution(uuid)
to authenticated, service_role;

revoke all on function api.accrue_payroll(
  uuid, uuid, date, date, bigint, bigint
) from public, anon, authenticated, service_role;
grant execute on function api.accrue_payroll(
  uuid, uuid, date, date, bigint, bigint
) to authenticated, service_role;

revoke all on function api.pay_salary(uuid)
from public, anon, authenticated, service_role;
grant execute on function api.pay_salary(uuid)
to authenticated, service_role;
