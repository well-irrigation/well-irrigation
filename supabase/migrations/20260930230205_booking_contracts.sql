-- =====================================================================
-- Migration 112 — م-45 المرحلة B / ق-131 بند 8 / ق-98 م-28
-- عقد الحجوزات الحاكم: مسار بئر واحد، الخادم سلطة التعارض النهائية
-- =====================================================================
--
-- الغرض:
--   إرساء عقد الحجز الخادمي الذي ستستهلكه واجهة ق-131 V1 ومسار
--   العمل دون اتصال لاحقًا:
--   1) قيد استبعاد (Exclusion Constraint) على قاعدة البيانات يمنع
--      تداخل الحجوزات المؤكدة على نفس البئر — هو سلطة التزامن
--      النهائية لا الفحص التطبيقي (count-then-insert) القديم.
--   2) إعادة استخدام ops.resource_reservations بنوع مورد جديد
--      well_path (المورد = البئر نفسه، التوازي الأقصى = 1)، مع حرس
--      تفرّد جزئي: حجز well_path نشط واحد لكل حجز.
--   3) استبدال عقد إنشاء الحجز: نموذج V1 لا يختار مضخة ولا خط مياه
--      — تُسقَط الأحمال القديمة البارامترية pump/water_line كليًا
--      (الأعمدة التاريخية تبقى وتبقى null في الحجوزات الجديدة).
--   4) التعارض نتيجة مكتوبة من نوع معلوم (status=conflict /
--      conflict_code=time_overlap) لا خطأ SQL خام.
--   5) api.create_booking وapi.reschedule_booking وapi.cancel_booking
--      كلها ذات معرّف عملية إلزامي عبر sync.begin_well_command /
--      sync.finish_well_command — إعادة الإرسال تعيد الرد المخزن حرفيًا
--      للقبول والتعارض معًا.
--   6) قراءات مكتوبة: api.list_well_bookings وapi.get_booking_detail
--      مع اليوم المجدول المشتق من منطقة بئر الجهة (098) لا من ساعة
--      الجهاز.
--
-- قواعد التصميم:
--   - لا جدول حجوزات ثانٍ ولا سجل حالة ثانٍ ولا نظام حجز موارد موازٍ.
--     كل شيء فوق ops.irrigation_bookings وops.booking_status_history
--     وops.resource_reservations القائمة.
--   - قبل إضافة القيد: فحص يفشل إغلاقًا إن وُجد تداخل قائم بين حجوزات
--     مؤكدة تاريخية — لا يُلغى ولا يُعدَّل حجز تاريخي بصمت.
--   - الصلاحية عبر iam.has_well_permission (سلطة ق-113 الحاكمة).
--     صلاحيتان جديدتان: booking.cancel للمالك والمشغل، وbooking.read
--     للمالك والمدير والمشغل حفاظًا على دلالة قراءة 079. لا منح كتابة
--     صامتة للشريك/المزارع/المحاسب/العارض، وقراءة المزارع الذاتية
--     منفصلة ومشتقة من هويته لا صلاحية booking.read عامة.
--   - سعة الفترات نصف مفتوحة [start, end) في كل الفحوص والقيود:
--     ‏08:00–09:00 و09:00–10:00 متتاليان ولا يتعارضان.
--   - القيود البنيوية تُقرأ في اختبار 112 الدائم؛ تعليقات هذه الهجرة
--     لا تحمل أنماطًا يبحث عنها الحرس النصي.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- A) صلاحيات جديدة: booking.cancel (مالك+مشغل) وbooking.read
--    (مالك+مدير+مشغل)
-- ---------------------------------------------------------------------

insert into iam.permissions (code, description_ar)
values
  ('booking.cancel', 'إلغاء حجز سقي'),
  ('booking.read', 'قراءة حجوزات السقي')
on conflict (code) do nothing;

-- booking.cancel: إدارة الحجوزات للمالك والمشغل وحدهما.
insert into iam.role_permissions (role_id, permission_id)
select r.id, p.id
from iam.roles r
join iam.permissions p
  on p.code = 'booking.cancel'
where r.code in ('tenant_owner', 'operator')
on conflict do nothing;

-- booking.read: قراءة حجوزات البئر لموظفي البئر الثلاثة حفاظًا على
-- دلالة القراءة التي كانت تمنحها سياسات 079 (owner/manager/operator).
-- نطاق المزارع الذاتي ليس هذه الصلاحية — يُشتق في العقود من
-- iam.current_farmer_well_account_id وحده.
insert into iam.role_permissions (role_id, permission_id)
select r.id, p.id
from iam.roles r
join iam.permissions p
  on p.code = 'booking.read'
where r.code in ('tenant_owner', 'well_manager', 'operator')
on conflict do nothing;

-- ---------------------------------------------------------------------
-- B) توسيع أنواع الموارد المحجوزة بـwell_path: مورد البئر نفسه
-- ---------------------------------------------------------------------

alter table ops.resource_reservations
  drop constraint resource_reservations_resource_type_check;

alter table ops.resource_reservations
  add constraint resource_reservations_resource_type_check
  check (resource_type in ('pump', 'water_line', 'well_path'));

-- ---------------------------------------------------------------------
-- C) ops.reserve_resource يفهم well_path
--
--    الأساس نسخة 076 القائمة (تحقق لكل مورد + قواعد
--    ops.resource_concurrency_rules) مع إضافة فرع well_path:
--    المورد هو البئر نفسه والتوازي الأقصى 1. الفحص العدّي هنا
--    advisory لا حاكم: سلطة التزامن النهائية للبئر هي قيد
--    الاستبعاد على ops.irrigation_bookings الذي يأتي لاحقًا
--    في هذه الهجرة. صفوف pump/water_line التاريخية تتصرف كما كانت.
-- ---------------------------------------------------------------------

create or replace function ops.reserve_resource(
  p_well_id uuid,
  p_resource_type text,
  p_resource_id uuid,
  p_reserved_period tstzrange,
  p_booking_id uuid default null,
  p_session_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = 'ops', 'core', 'pg_temp'
as $function$
declare
  v_tenant_id uuid;
  v_default_limit integer;
  v_rule_limit integer;
  v_max_parallel integer;
  v_active_count integer;
  v_reservation_id uuid;
begin
  select w.tenant_id
  into v_tenant_id
  from core.wells w
  where w.id = p_well_id;

  if v_tenant_id is null then
    raise exception 'البئر المحدد غير موجود: %', p_well_id;
  end if;

  if p_resource_type = 'well_path' then

    if p_resource_id is distinct from p_well_id then
      raise exception 'حجز مسار البئر يجب أن يكون على البئر نفسه';
    end if;
    v_default_limit := 1;

  elsif p_resource_type = 'water_line' then

    select wl.max_parallel_sessions
    into v_default_limit
    from core.water_lines wl
    where wl.id = p_resource_id
      and wl.well_id = p_well_id
      and wl.status = 'active'
    for update;

    if not found then
      raise exception
        'المورد المحدد غير موجود أو غير فعال في هذا البئر: % (%)',
        p_resource_id,
        p_resource_type;
    end if;

  elsif p_resource_type = 'pump' then

    perform 1
    from core.pumps p
    where p.id = p_resource_id
      and p.well_id = p_well_id
      and p.status = 'active'
    for update;

    if not found then
      raise exception
        'المورد المحدد غير موجود أو غير فعال في هذا البئر: % (%)',
        p_resource_id,
        p_resource_type;
    end if;

    v_default_limit := 1;

  else
    raise exception
      'نوع المورد غير صالح للحجز: %',
      p_resource_type;
  end if;

  select r.max_parallel_sessions
  into v_rule_limit
  from ops.resource_concurrency_rules r
  where r.well_id = p_well_id
    and r.rule_status = 'active'
    and (
      (
        r.resource_type = p_resource_type
        and r.resource_id = p_resource_id
      )
      or r.resource_type = 'well'
    )
  order by
    case
      when r.resource_type = p_resource_type
       and r.resource_id = p_resource_id
      then 0
      else 1
    end
  limit 1;

  v_max_parallel :=
    coalesce(v_rule_limit, v_default_limit);

  select count(*)
  into v_active_count
  from ops.resource_reservations rr
  where rr.resource_type = p_resource_type
    and rr.resource_id = p_resource_id
    and rr.status = 'active'
    and rr.reserved_period && p_reserved_period;

  if v_active_count >= v_max_parallel then
    raise exception
      'المورد محجوز بالكامل خلال هذه الفترة (الحد الأقصى للتوازي: %)',
      v_max_parallel;
  end if;

  insert into ops.resource_reservations (
    tenant_id,
    well_id,
    resource_type,
    resource_id,
    booking_id,
    session_id,
    reserved_period,
    status
  )
  values (
    v_tenant_id,
    p_well_id,
    p_resource_type,
    p_resource_id,
    p_booking_id,
    p_session_id,
    p_reserved_period,
    'active'
  )
  returning id into v_reservation_id;

  return v_reservation_id;
end;
$function$;

revoke all on function ops.reserve_resource(uuid, text, uuid, tstzrange, uuid, uuid) from public, anon;
grant execute on function ops.reserve_resource(uuid, text, uuid, tstzrange, uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- D) حرس تفرّد جزئي: حجز well_path نشط واحد لكل حجز
-- ---------------------------------------------------------------------

create unique index if not exists uq_resource_reservations_active_well_path_booking
  on ops.resource_reservations (booking_id)
  where resource_type = 'well_path' and status = 'active';

-- ---------------------------------------------------------------------
-- E) فحص إغلاق فاشل قبل القيد: لا تداخل قائم بين حجوزات مؤكدة
--    — لا يُلغى ولا يُعدَّل حجز تاريخي بصمت؛ وجود تعارض يوقف الهجرة.
-- ---------------------------------------------------------------------

do $guard$
begin
  if exists (
    select 1
    from ops.irrigation_bookings a
    join ops.irrigation_bookings b
      on b.well_id = a.well_id
     and b.id < a.id
     and b.status = 'confirmed'
     and a.status = 'confirmed'
     and tstzrange(a.scheduled_start, a.scheduled_end, '[)')
         && tstzrange(b.scheduled_start, b.scheduled_end, '[)')
  ) then
    raise exception 'توجد حجوزات مؤكدة متداخلة على نفس البئر — يلزم حسمها قبل نشر قيد عدم التداخل';
  end if;
end
$guard$;

-- ---------------------------------------------------------------------
-- F) قيد الاستبعاد: سلطة التزامن النهائية على مستوى القاعدة
--    نفس البئر + status=confirmed + تداخل [start,end) => رفض الصف الثاني
--    الفترات نصف مفتوحة [) فالمتتاليان 08:00–09:00 و09:00–10:00 صحيحان.
-- ---------------------------------------------------------------------

alter table ops.irrigation_bookings
  add constraint irrigation_bookings_no_confirmed_well_overlap
  exclude using gist (
    well_id with =,
    tstzrange(scheduled_start, scheduled_end, '[)') with &&
  ) where (status = 'confirmed');

-- ---------------------------------------------------------------------
-- F2) ملء حجوزات well_path الناقصة للحجوزات المؤكدة القائمة —
--     غير المتعارضة وحدها، وصفوف pump/water_line التاريخية لا تُمس.
--     صفًا صفًا حتى يرى كل إدراج ما قبله فلا يُملأ زوج متعارض.
-- ---------------------------------------------------------------------

do $backfill$
declare
  r record;
begin
  for r in
    select b.id, b.tenant_id, b.well_id, b.scheduled_start, b.scheduled_end
    from ops.irrigation_bookings b
    where b.status = 'confirmed'
      and not exists (
        select 1 from ops.resource_reservations rr
        where rr.booking_id = b.id
          and rr.resource_type = 'well_path'
          and rr.status = 'active'
      )
    order by b.well_id, b.scheduled_start, b.id
  loop
    if exists (
      select 1 from ops.resource_reservations rr
      where rr.resource_type = 'well_path'
        and rr.status = 'active'
        and rr.resource_id = r.well_id
        and rr.reserved_period
              && tstzrange(r.scheduled_start, r.scheduled_end, '[)')
    ) then
      continue;
    end if;

    insert into ops.resource_reservations (
      tenant_id, well_id, resource_type, resource_id,
      booking_id, session_id, reserved_period, status
    ) values (
      r.tenant_id, r.well_id, 'well_path', r.well_id,
      r.id, null,
      tstzrange(r.scheduled_start, r.scheduled_end, '[)'), 'active'
    );
  end loop;
end
$backfill$;

-- ---------------------------------------------------------------------
-- G) عقد إنشاء الحجز الجديد — بلا مضخة ولا خط مياه
--
--    التعارض نتيجة مكتوبة لا خطأ: فحص مسبق يكتب الحالة، وقيد
--    الاستبعاد مرجع السباق — يُلتقط بحد استثناء داخل معاملة فرعية
--    فلا يبقى حجز ولا سجل حالة ولا حجز مورد ناقص.
-- ---------------------------------------------------------------------

create or replace function ops.create_booking(
  p_well_id uuid,
  p_farmer_well_account_id uuid,
  p_farm_id uuid,
  p_scheduled_start timestamptz,
  p_scheduled_end timestamptz,
  p_expected_energy_source text default null,
  p_priority integer default 0,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'ops', 'core', 'audit', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_booking_id uuid;
  v_public_code text;
  v_reservation_id uuid;
  v_period tstzrange;
  v_duration integer;
  v_conflict_id uuid;
  v_conflict_code text;
  v_conflict_start timestamptz;
  v_conflict_end timestamptz;
  v_constraint_name text;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إنشاء حجز سقي';
  end if;
  if not iam.has_well_permission(p_well_id, 'booking.create') then
    raise exception 'لا تملك صلاحية إنشاء حجز في هذا البئر';
  end if;
  if p_scheduled_start is null or p_scheduled_end is null
     or p_scheduled_end <= p_scheduled_start then
    raise exception 'فترة الحجز غير صالحة — يجب أن تكون النهاية بعد البداية';
  end if;
  if p_expected_energy_source is not null
     and p_expected_energy_source not in ('solar', 'well_diesel', 'farmer_diesel', 'mixed') then
    raise exception 'مصدر الطاقة المتوقع غير صالح';
  end if;

  select w.tenant_id into v_tenant_id
  from core.wells w where w.id = p_well_id;
  if not found then
    raise exception 'البئر غير موجود: %', p_well_id;
  end if;

  perform 1 from ops.farmer_well_accounts fwa
  where fwa.id = p_farmer_well_account_id
    and fwa.well_id = p_well_id and fwa.status = 'active'
  for update;
  if not found then
    raise exception 'حساب المزارع غير موجود أو غير فعال في هذا البئر';
  end if;

  if not exists (
    select 1 from ops.farms f
    where f.id = p_farm_id and f.well_id = p_well_id and f.status = 'active'
  ) then
    raise exception 'الأرض غير موجودة أو غير فعالة في هذا البئر';
  end if;

  v_period := tstzrange(p_scheduled_start, p_scheduled_end, '[)');
  v_duration := ceil(extract(epoch from (p_scheduled_end - p_scheduled_start)) / 60.0)::integer;

  select b.id, b.public_code, b.scheduled_start, b.scheduled_end
    into v_conflict_id, v_conflict_code, v_conflict_start, v_conflict_end
  from ops.irrigation_bookings b
  where b.well_id = p_well_id
    and b.status = 'confirmed'
    and tstzrange(b.scheduled_start, b.scheduled_end, '[)') && v_period
  order by b.scheduled_start, b.id
  limit 1;

  if v_conflict_id is not null then
    return jsonb_build_object(
      'status', 'conflict',
      'conflict_code', 'time_overlap',
      'requested_start', p_scheduled_start,
      'requested_end', p_scheduled_end,
      'conflicting_booking_id', v_conflict_id,
      'conflicting_public_code', v_conflict_code,
      'conflicting_start', v_conflict_start,
      'conflicting_end', v_conflict_end
    );
  end if;

  begin
    insert into ops.irrigation_bookings (
      tenant_id, public_code, well_id, farmer_well_account_id,
      farm_id, scheduled_start, scheduled_end,
      expected_duration_minutes, expected_energy_source, status,
      priority, notes, created_by
    ) values (
      v_tenant_id, core.generate_public_code('BKG'), p_well_id,
      p_farmer_well_account_id, p_farm_id,
      p_scheduled_start, p_scheduled_end, v_duration,
      p_expected_energy_source, 'confirmed', p_priority, p_notes, v_actor
    ) returning id, public_code into v_booking_id, v_public_code;

    v_reservation_id := ops.reserve_resource(
      p_well_id, 'well_path', p_well_id, v_period, v_booking_id, null
    );

    insert into ops.booking_status_history (
      tenant_id, booking_id, old_status, new_status, reason, changed_by, changed_at
    ) values (
      v_tenant_id, v_booking_id, null, 'confirmed', 'إنشاء الحجز', v_actor,
      clock_timestamp()
    );

    perform audit.log(
      v_tenant_id, p_well_id, 'create_booking',
      'ops.irrigation_bookings', v_booking_id, null,
      jsonb_build_object(
        'booking_id', v_booking_id,
        'scheduled_start', p_scheduled_start,
        'scheduled_end', p_scheduled_end,
        'well_path_reservation_id', v_reservation_id
      ),
      'إنشاء حجز سقي مؤكد على مسار البئر'
    );
  exception
    when exclusion_violation then
      get stacked diagnostics v_constraint_name = CONSTRAINT_NAME;
      if v_constraint_name <> 'irrigation_bookings_no_confirmed_well_overlap' then
        raise;
      end if;
      select b.id, b.public_code, b.scheduled_start, b.scheduled_end
        into v_conflict_id, v_conflict_code, v_conflict_start, v_conflict_end
      from ops.irrigation_bookings b
      where b.well_id = p_well_id
        and b.status = 'confirmed'
        and tstzrange(b.scheduled_start, b.scheduled_end, '[)') && v_period
      order by b.scheduled_start, b.id
      limit 1;
      return jsonb_build_object(
        'status', 'conflict',
        'conflict_code', 'time_overlap',
        'requested_start', p_scheduled_start,
        'requested_end', p_scheduled_end,
        'conflicting_booking_id', v_conflict_id,
        'conflicting_public_code', v_conflict_code,
        'conflicting_start', v_conflict_start,
        'conflicting_end', v_conflict_end
      );
  end;

  return jsonb_build_object(
    'status', 'confirmed',
    'booking_id', v_booking_id,
    'public_code', v_public_code,
    'well_id', p_well_id,
    'scheduled_start', p_scheduled_start,
    'scheduled_end', p_scheduled_end,
    'expected_duration_minutes', v_duration,
    'well_path_reservation_id', v_reservation_id
  );
end;
$function$;

-- إسقاط الحمل القديم البارامتري pump/water_line كليًا حتى لا يتجاوز
-- عقد مسار البئر الجديد.
drop function if exists ops.create_booking(
  uuid, uuid, uuid, timestamptz, timestamptz, uuid, uuid, text, integer, text
);

revoke all on function ops.create_booking(
  uuid, uuid, uuid, timestamptz, timestamptz, text, integer, text
) from public, anon;
grant execute on function ops.create_booking(
  uuid, uuid, uuid, timestamptz, timestamptz, text, integer, text
) to authenticated;

-- ---------------------------------------------------------------------
-- H) عقد إعادة الجدولة — تنتهي confirmed وتحرر/تنشئ well_path
--    الحالات المسموحة في تدفق V1: confirmed وpostponed (إرث).
-- ---------------------------------------------------------------------

create or replace function ops.reschedule_booking(
  p_booking_id uuid,
  p_scheduled_start timestamptz,
  p_scheduled_end timestamptz,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to 'ops', 'core', 'audit', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_booking ops.irrigation_bookings%rowtype;
  v_period tstzrange;
  v_duration integer;
  v_well_path_reservation_id uuid;
  v_pump_reservation_id uuid;
  v_line_reservation_id uuid;
  v_conflict_id uuid;
  v_conflict_code text;
  v_conflict_start timestamptz;
  v_conflict_end timestamptz;
  v_constraint_name text;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إعادة جدولة الحجز';
  end if;
  if p_scheduled_start is null or p_scheduled_end is null
     or p_scheduled_end <= p_scheduled_start then
    raise exception 'فترة الحجز الجديدة غير صالحة — يجب أن تكون النهاية بعد البداية';
  end if;
  if nullif(btrim(p_reason), '') is null then
    raise exception 'سبب إعادة الجدولة مطلوب';
  end if;

  select b.* into v_booking
  from ops.irrigation_bookings b
  where b.id = p_booking_id
  for update;
  if not found then
    raise exception 'الحجز غير موجود: %', p_booking_id;
  end if;
  if not iam.has_well_permission(v_booking.well_id, 'booking.reschedule') then
    raise exception 'لا تملك صلاحية إعادة جدولة هذا الحجز';
  end if;
  if v_booking.status not in ('confirmed', 'postponed') then
    raise exception 'لا يمكن إعادة جدولة حجز حالته %', v_booking.status;
  end if;

  v_period := tstzrange(p_scheduled_start, p_scheduled_end, '[)');
  v_duration := ceil(extract(epoch from (p_scheduled_end - p_scheduled_start)) / 60.0)::integer;

  select b.id, b.public_code, b.scheduled_start, b.scheduled_end
    into v_conflict_id, v_conflict_code, v_conflict_start, v_conflict_end
  from ops.irrigation_bookings b
  where b.well_id = v_booking.well_id
    and b.id <> p_booking_id
    and b.status = 'confirmed'
    and tstzrange(b.scheduled_start, b.scheduled_end, '[)') && v_period
  order by b.scheduled_start, b.id
  limit 1;

  if v_conflict_id is not null then
    return jsonb_build_object(
      'status', 'conflict',
      'conflict_code', 'time_overlap',
      'booking_id', p_booking_id,
      'requested_start', p_scheduled_start,
      'requested_end', p_scheduled_end,
      'conflicting_booking_id', v_conflict_id,
      'conflicting_public_code', v_conflict_code,
      'conflicting_start', v_conflict_start,
      'conflicting_end', v_conflict_end
    );
  end if;

  begin
    update ops.resource_reservations
    set status = 'released'
    where booking_id = p_booking_id and status = 'active';

    update ops.irrigation_bookings
    set scheduled_start = p_scheduled_start,
        scheduled_end = p_scheduled_end,
        expected_duration_minutes = v_duration,
        status = 'confirmed'
    where id = p_booking_id;

    v_well_path_reservation_id := ops.reserve_resource(
      v_booking.well_id, 'well_path', v_booking.well_id,
      v_period, p_booking_id, null
    );

    -- صفوف الموارد التاريخية للحقول الإرثية تُعاد حجزها كما كانت.
    if v_booking.pump_id is not null then
      perform 1 from core.pumps p
      where p.id = v_booking.pump_id and p.status = 'active'
      for update;
      if not found then
        raise exception 'مضخة الحجز غير موجودة أو غير فعالة';
      end if;
      v_pump_reservation_id := ops.reserve_resource(
        v_booking.well_id, 'pump', v_booking.pump_id,
        v_period, p_booking_id, null
      );
    end if;
    if v_booking.water_line_id is not null then
      perform 1 from core.water_lines wl
      where wl.id = v_booking.water_line_id and wl.status = 'active'
      for update;
      if not found then
        raise exception 'خط مياه الحجز غير موجود أو غير فعال';
      end if;
      v_line_reservation_id := ops.reserve_resource(
        v_booking.well_id, 'water_line', v_booking.water_line_id,
        v_period, p_booking_id, null
      );
    end if;

    insert into ops.booking_status_history (
      tenant_id, booking_id, old_status, new_status, reason, changed_by, changed_at
    ) values (
      v_booking.tenant_id, p_booking_id, v_booking.status,
      'confirmed', 'إعادة جدولة: ' || btrim(p_reason), v_actor,
      clock_timestamp()
    );

    perform audit.log(
      v_booking.tenant_id, v_booking.well_id, 'reschedule_booking',
      'ops.irrigation_bookings', p_booking_id,
      jsonb_build_object(
        'scheduled_start', v_booking.scheduled_start,
        'scheduled_end', v_booking.scheduled_end,
        'status', v_booking.status
      ),
      jsonb_build_object(
        'scheduled_start', p_scheduled_start,
        'scheduled_end', p_scheduled_end,
        'status', 'confirmed',
        'well_path_reservation_id', v_well_path_reservation_id,
        'pump_reservation_id', v_pump_reservation_id,
        'water_line_reservation_id', v_line_reservation_id
      ),
      btrim(p_reason)
    );
  exception
    when exclusion_violation then
      get stacked diagnostics v_constraint_name = CONSTRAINT_NAME;
      if v_constraint_name <> 'irrigation_bookings_no_confirmed_well_overlap' then
        raise;
      end if;
      select b.id, b.public_code, b.scheduled_start, b.scheduled_end
        into v_conflict_id, v_conflict_code, v_conflict_start, v_conflict_end
      from ops.irrigation_bookings b
      where b.well_id = v_booking.well_id
        and b.id <> p_booking_id
        and b.status = 'confirmed'
        and tstzrange(b.scheduled_start, b.scheduled_end, '[)') && v_period
      order by b.scheduled_start, b.id
      limit 1;
      return jsonb_build_object(
        'status', 'conflict',
        'conflict_code', 'time_overlap',
        'booking_id', p_booking_id,
        'requested_start', p_scheduled_start,
        'requested_end', p_scheduled_end,
        'conflicting_booking_id', v_conflict_id,
        'conflicting_public_code', v_conflict_code,
        'conflicting_start', v_conflict_start,
        'conflicting_end', v_conflict_end
      );
  end;

  return jsonb_build_object(
    'status', 'confirmed',
    'booking_id', p_booking_id,
    'well_id', v_booking.well_id,
    'previous_status', v_booking.status,
    'scheduled_start', p_scheduled_start,
    'scheduled_end', p_scheduled_end,
    'expected_duration_minutes', v_duration,
    'well_path_reservation_id', v_well_path_reservation_id
  );
end;
$function$;

revoke all on function ops.reschedule_booking(uuid, timestamptz, timestamptz, text) from public, anon;
grant execute on function ops.reschedule_booking(uuid, timestamptz, timestamptz, text) to authenticated;

-- ---------------------------------------------------------------------
-- I) الإلغاء الصريح: داخلي + عام ذاتي التكرار
-- ---------------------------------------------------------------------

create or replace function ops.cancel_booking(
  p_booking_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to 'ops', 'core', 'audit', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_booking ops.irrigation_bookings%rowtype;
  v_released integer := 0;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إلغاء حجز سقي';
  end if;
  if nullif(btrim(p_reason), '') is null then
    raise exception 'سبب إلغاء الحجز مطلوب';
  end if;

  select b.* into v_booking
  from ops.irrigation_bookings b
  where b.id = p_booking_id
  for update;
  if not found then
    raise exception 'الحجز غير موجود: %', p_booking_id;
  end if;
  if not iam.has_well_permission(v_booking.well_id, 'booking.cancel') then
    raise exception 'لا تملك صلاحية إلغاء هذا الحجز';
  end if;
  if v_booking.status not in ('draft', 'pending', 'confirmed', 'waiting', 'ready', 'postponed') then
    raise exception 'لا يمكن إلغاء حجز حالته %', v_booking.status;
  end if;

  update ops.resource_reservations
  set status = 'cancelled'
  where booking_id = p_booking_id and status = 'active';
  get diagnostics v_released = row_count;

  update ops.irrigation_bookings
  set status = 'cancelled'
  where id = p_booking_id;

  insert into ops.booking_status_history (
    tenant_id, booking_id, old_status, new_status, reason, changed_by, changed_at
  ) values (
    v_booking.tenant_id, p_booking_id, v_booking.status,
    'cancelled', btrim(p_reason), v_actor,
    clock_timestamp()
  );

  perform audit.log(
    v_booking.tenant_id, v_booking.well_id, 'cancel_booking',
    'ops.irrigation_bookings', p_booking_id,
    jsonb_build_object(
      'status', v_booking.status,
      'scheduled_start', v_booking.scheduled_start,
      'scheduled_end', v_booking.scheduled_end
    ),
    jsonb_build_object(
      'status', 'cancelled',
      'released_reservations', v_released
    ),
    btrim(p_reason)
  );

  return jsonb_build_object(
    'status', 'cancelled',
    'booking_id', p_booking_id,
    'previous_status', v_booking.status,
    'released_reservations', v_released
  );
end;
$function$;

revoke all on function ops.cancel_booking(uuid, text) from public, anon;
grant execute on function ops.cancel_booking(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- J) الأغلفة العامة ذات معرّف العملية الإلزامي
-- ---------------------------------------------------------------------

drop function if exists api.create_booking(
  uuid, uuid, uuid, timestamptz, timestamptz, uuid, uuid, text, integer, text
);

create function api.create_booking(
  p_well_id uuid,
  p_farmer_well_account_id uuid,
  p_farm_id uuid,
  p_scheduled_start timestamptz,
  p_scheduled_end timestamptz,
  p_command_id uuid,
  p_expected_energy_source text default null,
  p_priority integer default 0,
  p_notes text default null
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_guard jsonb;
  v_result jsonb;
begin
  if p_command_id is null then
    raise exception 'معرّف العملية مطلوب';
  end if;

  v_guard := sync.begin_well_command(
    p_well_id,
    p_command_id,
    'create_booking',
    jsonb_build_object(
      'farmer_well_account_id', p_farmer_well_account_id,
      'farm_id', p_farm_id,
      'scheduled_start', p_scheduled_start,
      'scheduled_end', p_scheduled_end
    )
  );

  if coalesce((v_guard ->> 'duplicate')::boolean, false) then
    if v_guard ->> 'status' in ('accepted', 'conflict') then
      return v_guard -> 'response';
    end if;
    raise exception 'العملية نفسها قيد المعالجة أو تحتاج مراجعة';
  end if;

  v_result := ops.create_booking(
    p_well_id,
    p_farmer_well_account_id,
    p_farm_id,
    p_scheduled_start,
    p_scheduled_end,
    p_expected_energy_source,
    p_priority,
    p_notes
  );

  if v_result ->> 'status' = 'conflict' then
    perform sync.finish_well_command(p_well_id, p_command_id, 'conflict', v_result);
  elsif v_result ->> 'status' = 'confirmed' then
    perform sync.finish_well_command(p_well_id, p_command_id, 'accepted', v_result);
  else
    raise exception 'نتيجة إنشاء الحجز غير معروفة: %', coalesce(v_result ->> 'status', 'null');
  end if;

  return v_result;
end;
$function$;

revoke all on function api.create_booking(
  uuid, uuid, uuid, timestamptz, timestamptz, uuid, text, integer, text
) from public, anon, authenticated, service_role;
grant execute on function api.create_booking(
  uuid, uuid, uuid, timestamptz, timestamptz, uuid, text, integer, text
) to authenticated, service_role;


drop function if exists api.reschedule_booking(uuid, timestamptz, timestamptz, text);

create function api.reschedule_booking(
  p_booking_id uuid,
  p_scheduled_start timestamptz,
  p_scheduled_end timestamptz,
  p_reason text,
  p_command_id uuid
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_well_id uuid;
  v_guard jsonb;
  v_result jsonb;
begin
  if p_command_id is null then
    raise exception 'معرّف العملية مطلوب';
  end if;

  select b.well_id into v_well_id
  from ops.irrigation_bookings b
  where b.id = p_booking_id;
  if v_well_id is null then
    raise exception 'الحجز غير موجود: %', p_booking_id;
  end if;

  v_guard := sync.begin_well_command(
    v_well_id,
    p_command_id,
    'reschedule_booking',
    jsonb_build_object(
      'booking_id', p_booking_id,
      'scheduled_start', p_scheduled_start,
      'scheduled_end', p_scheduled_end
    )
  );

  if coalesce((v_guard ->> 'duplicate')::boolean, false) then
    if v_guard ->> 'status' in ('accepted', 'conflict') then
      return v_guard -> 'response';
    end if;
    raise exception 'العملية نفسها قيد المعالجة أو تحتاج مراجعة';
  end if;

  v_result := ops.reschedule_booking(
    p_booking_id,
    p_scheduled_start,
    p_scheduled_end,
    p_reason
  );

  if v_result ->> 'status' = 'conflict' then
    perform sync.finish_well_command(v_well_id, p_command_id, 'conflict', v_result);
  elsif v_result ->> 'status' = 'confirmed' then
    perform sync.finish_well_command(v_well_id, p_command_id, 'accepted', v_result);
  else
    raise exception 'نتيجة إعادة الجدولة غير معروفة: %', coalesce(v_result ->> 'status', 'null');
  end if;

  return v_result;
end;
$function$;

revoke all on function api.reschedule_booking(
  uuid, timestamptz, timestamptz, text, uuid
) from public, anon, authenticated, service_role;
grant execute on function api.reschedule_booking(
  uuid, timestamptz, timestamptz, text, uuid
) to authenticated, service_role;


create function api.cancel_booking(
  p_booking_id uuid,
  p_reason text,
  p_command_id uuid
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_well_id uuid;
  v_guard jsonb;
  v_result jsonb;
begin
  if p_command_id is null then
    raise exception 'معرّف العملية مطلوب';
  end if;

  select b.well_id into v_well_id
  from ops.irrigation_bookings b
  where b.id = p_booking_id;
  if v_well_id is null then
    raise exception 'الحجز غير موجود: %', p_booking_id;
  end if;

  v_guard := sync.begin_well_command(
    v_well_id,
    p_command_id,
    'cancel_booking',
    jsonb_build_object('booking_id', p_booking_id)
  );

  if coalesce((v_guard ->> 'duplicate')::boolean, false) then
    if v_guard ->> 'status' in ('accepted', 'conflict') then
      return v_guard -> 'response';
    end if;
    raise exception 'العملية نفسها قيد المعالجة أو تحتاج مراجعة';
  end if;

  v_result := ops.cancel_booking(p_booking_id, p_reason);

  perform sync.finish_well_command(v_well_id, p_command_id, 'accepted', v_result);

  return v_result;
end;
$function$;

revoke all on function api.cancel_booking(uuid, text, uuid)
from public, anon, authenticated, service_role;
grant execute on function api.cancel_booking(uuid, text, uuid)
to authenticated, service_role;

-- ---------------------------------------------------------------------
-- K) القراءات المكتوبة — المنطقة الزمنية واليوم المجدول من الخادم
--
--    نطاق القراءة يحفظ دلالة 079 داخل العقود المكتوبة:
--    - موظف البئر صاحب booking.read (owner/manager/operator) يرى
--      حجوزات البئر كلها.
--    - المزارع بلا booking.read عامة: يرى حجوزات حسابه الذاتي فقط،
--      والهوية مشتقة من auth.uid() عبر iam.current_farmer_well_account_id
--      — لا يقبل المزارع معرّف حساب يختاره بنفسه.
--    - غير ذلك الرفض 42501 بلا كشف وجود حجوزات جهات أخرى.
--    كل القراءة تمر عبر RLS (invoker) وعبر api وحدها — لا قراءة
--    مباشرة لجداول ops من العميل.
-- ---------------------------------------------------------------------

create function api.list_well_bookings(
  p_well_id uuid,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_limit integer default 200
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_tz text;
  v_limit integer;
  v_bookings jsonb;
  v_staff boolean;
  v_self_account uuid;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة الحجوزات';
  end if;

  v_staff := iam.has_well_permission(p_well_id, 'booking.read');
  if not v_staff then
    v_self_account := iam.current_farmer_well_account_id(p_well_id);
    if v_self_account is null then
      raise exception 'لا تملك صلاحية قراءة حجوزات هذا البئر'
        using errcode = '42501';
    end if;
  end if;

  v_tz := core.well_timezone(p_well_id);
  v_limit := greatest(1, least(coalesce(p_limit, 200), 500));

  select coalesce(jsonb_agg(item order by item ->> 'scheduled_start', item ->> 'public_code'), '[]'::jsonb)
    into v_bookings
  from (
    select jsonb_build_object(
      'id', b.id,
      'public_code', b.public_code,
      'well_id', b.well_id,
      'farmer_well_account_id', b.farmer_well_account_id,
      'farmer_name', person.full_name,
      'farm_id', b.farm_id,
      'farm_name', f.name,
      'scheduled_start', b.scheduled_start,
      'scheduled_end', b.scheduled_end,
      'scheduled_day', (b.scheduled_start at time zone v_tz)::date::text,
      'expected_duration_minutes', b.expected_duration_minutes,
      'expected_energy_source', b.expected_energy_source,
      'status', b.status,
      'priority', b.priority,
      'notes', b.notes,
      'created_at', b.created_at
    ) as item
    from ops.irrigation_bookings b
    left join ops.farms f on f.id = b.farm_id
    left join ops.farmer_well_accounts fwa on fwa.id = b.farmer_well_account_id
    left join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
    left join core.persons person on person.id = fp.person_id
    where b.well_id = p_well_id
      and (v_staff or b.farmer_well_account_id = v_self_account)
      and (p_from is null or b.scheduled_end >= p_from)
      and (p_to is null or b.scheduled_start <= p_to)
    order by b.scheduled_start asc, b.public_code asc
    limit v_limit
  ) window_items;

  return jsonb_build_object(
    'status', 'ok',
    'well_id', p_well_id,
    'well_timezone', v_tz,
    'count', jsonb_array_length(v_bookings),
    'bookings', v_bookings
  );
end;
$function$;

revoke all on function api.list_well_bookings(uuid, timestamptz, timestamptz, integer)
from public, anon, authenticated, service_role;
grant execute on function api.list_well_bookings(uuid, timestamptz, timestamptz, integer)
to authenticated, service_role;


create function api.get_booking_detail(
  p_booking_id uuid
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_booking ops.irrigation_bookings%rowtype;
  v_tz text;
  v_farmer_name text;
  v_farm_name text;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة تفاصيل الحجز';
  end if;

  select b.* into v_booking
  from ops.irrigation_bookings b
  where b.id = p_booking_id;

  if not found then
    -- إما معرّف مغلوط أو صف يخفيه RLS عن غير المصرح له —
    -- الرفض نفسه بلا كشف وجود حجوزات جهات أخرى.
    raise exception 'لا تملك صلاحية قراءة هذا الحجز'
      using errcode = '42501';
  end if;

  if not iam.has_well_permission(v_booking.well_id, 'booking.read') then
    -- نطاق المزارع الذاتي: حسابه هو حساب الحجز، والهوية من auth.uid().
    if v_booking.farmer_well_account_id
         is distinct from iam.current_farmer_well_account_id(v_booking.well_id) then
      raise exception 'لا تملك صلاحية قراءة هذا الحجز'
        using errcode = '42501';
    end if;
  end if;

  v_tz := core.well_timezone(v_booking.well_id);

  select person.full_name into v_farmer_name
  from ops.farmer_well_accounts fwa
  join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
  join core.persons person on person.id = fp.person_id
  where fwa.id = v_booking.farmer_well_account_id;

  select f.name into v_farm_name
  from ops.farms f
  where f.id = v_booking.farm_id;

  return jsonb_build_object(
    'status', 'ok',
    'booking', jsonb_build_object(
      'id', v_booking.id,
      'public_code', v_booking.public_code,
      'well_id', v_booking.well_id,
      'farmer_well_account_id', v_booking.farmer_well_account_id,
      'farmer_name', v_farmer_name,
      'farm_id', v_booking.farm_id,
      'farm_name', v_farm_name,
      'scheduled_start', v_booking.scheduled_start,
      'scheduled_end', v_booking.scheduled_end,
      'scheduled_day', (v_booking.scheduled_start at time zone v_tz)::date::text,
      'expected_duration_minutes', v_booking.expected_duration_minutes,
      'expected_energy_source', v_booking.expected_energy_source,
      'status', v_booking.status,
      'priority', v_booking.priority,
      'notes', v_booking.notes,
      'created_at', v_booking.created_at
    ),
    'well_timezone', v_tz,
    'status_history', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', h.id,
        'old_status', h.old_status,
        'new_status', h.new_status,
        'reason', h.reason,
        'changed_at', h.changed_at,
        'changed_by', h.changed_by
      ) order by h.changed_at asc, h.id asc)
      from ops.booking_status_history h
      where h.booking_id = p_booking_id
    ), '[]'::jsonb),
    'reservations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id,
        'resource_type', r.resource_type,
        'resource_id', r.resource_id,
        'reserved_period', r.reserved_period::text,
        'status', r.status,
        'created_at', r.created_at
      ) order by r.created_at asc, r.id asc)
      from ops.resource_reservations r
      where r.booking_id = p_booking_id
    ), '[]'::jsonb)
  );
end;
$function$;

revoke all on function api.get_booking_detail(uuid)
from public, anon, authenticated, service_role;
grant execute on function api.get_booking_detail(uuid)
to authenticated, service_role;

commit;
