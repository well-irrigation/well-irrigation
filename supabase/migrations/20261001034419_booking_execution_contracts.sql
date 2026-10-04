-- =====================================================================
-- Migration 113 — ق-132 / م-45 Phase B / م-28
-- M113-A/B/C: تأسيس عقد تنفيذ الحجوزات وإنفاذه وبدء الجلسة منه
-- =====================================================================
--
-- نطاق هذه الجولة (M113-A) حصرًا:
--   1) علاقة booking → session الحاكمة: عمود ops.irrigation_sessions
--      .booking_id مع FK ومؤشر فريد جزئي — الجلسات التاريخية تبقى
--      NULL بلا أي backfill بالاستنتاج الزمني، ولا تعديل للسجلات
--      القديمة، وbooking واحدة لا تنشئ أكثر من Session واحدة.
--   2) عمود المصدر البديل للحجز alternative_energy_source (nullable):
--      يقبَل well_diesel/farmer_diesel/NULL فقط — لا solar ولا mixed
--      ولا نصوص أخرى؛ والحجوزات التاريخية بقيمها (بما فيها mixed
--      وnull) لا تُمس ولا تُرقَّى بصمت إلى نموذج ق-132.
--   3) مضخة فعالة واحدة كحد أقصى لكل بئر (ق-132 / الثابت 743): فحص
--      إغلاق فاشل قبل القيد يوقف الهجرة بوضوح إن وُجد بئر بأكثر من
--      مضخة active — لا تعطيل تلقائي ولا اختيار صامت — ثم مؤشر فريد
--      جزئي على core.pumps(well_id) where status='active'. حالة صفر
--      مضخات لا يضمنها الجدول وتعالجها جاهزية التنفيذ أدناه.
--   4) مصدر مركزي لنافذة الشمس الحاكمة: ops.solar_window_for_day(p_day
--      date) يعيد tstzrange بيوم محدد بمنطقة Asia/Aden — بداية 06:00
--      شاملة ونهاية 18:00 غير شاملة — بلا literals مبعثرة، وبلا نظام
--      Platform Settings جديد (م-35 مستقلة). لا GRANT للعميل.
--   5) Evaluator داخلي typed/stable لجاهزية الحجز للتنفيذ:
--      ops.evaluate_booking_execution_readiness — قراءة فقط بلا أي
--      كتابة، لا يستقبل actor ولا pump id من العميل، ويعيد ready /
--      reason_code / timezone / primary / alternative /
--      requires_alternative / نافذة الشمس / active_pump_id. لا GRANT
--      للعميل: ليس سطحًا عامًا جديدًا.
--
-- ما لا تفعله هذه الهجرة بعد M113-C:
--   لا شاشة يوم ولا انتقال تلقائي ولا إشعارات ولا Offline queue ولا
--   تسوية إنهاء، ولا تغيّر عقد api.start_irrigation_session الحر القائم.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- A) علاقة booking → session (ق-132 / الثابت 742)
--
--    ON DELETE NO ACTION عمدًا: لا CASCADE يحذف جلسة بحذف booking؛
--    والحذف التاريخي ليس مسار UX عاديًا أصلًا، فإن حصل يمنع الـFK
--    حذف booking له جلسة بدل أن ينقطع الرابط الحاكم بصمت.
-- ---------------------------------------------------------------------

alter table ops.irrigation_sessions
  add column booking_id uuid null;

alter table ops.irrigation_sessions
  add constraint irrigation_sessions_booking_fkey
  foreign key (booking_id)
  references ops.irrigation_bookings (id)
  on delete no action;

-- Booking واحدة لا تنشئ أكثر من Session واحدة.
create unique index uq_irrigation_sessions_booking
  on ops.irrigation_sessions (booking_id)
  where booking_id is not null;

-- E2-e-b2: مدة مخطّطة اختيارية للجلسة الحرّة (ق-132/750). nullable فلا أثر
-- رجعي على جلسات قديمة؛ لا تُفرَض على جلسة بدأت سابقًا. planned_end_at حقيقة
-- مخطّطة تُشتق من البداية الفعلية + المدة (الثابت 748)، للإنفاذ المؤجَّل مقابل
-- الحجز القادم؛ ويتميّز صراحةً عن ended_at الفعلي (الذي يُضبَط عند الإكمال).
-- المدة المخطّطة لا تُغلق الجلسة تلقائيًا — لا زناد إغلاق على هذه الأعمدة.
alter table ops.irrigation_sessions
  add column planned_duration_minutes integer null
    check (planned_duration_minutes is null or planned_duration_minutes > 0),
  add column planned_end_at timestamptz null;

-- ---------------------------------------------------------------------
-- B) المصدر البديل للحجز (ق-132 / الثابت 755)
--
--    nullable: الحجوزات التاريخية السابقة لق-132 تبقى كما هي، ولا
--    يعاد كتابة expected_energy_source التاريخي ولا mixed/null القائم.
-- ---------------------------------------------------------------------

alter table ops.irrigation_bookings
  add column alternative_energy_source text null
  check (alternative_energy_source is null
         or alternative_energy_source in ('well_diesel', 'farmer_diesel'));

-- ---------------------------------------------------------------------
-- C) مضخة فعالة واحدة كحد أقصى لكل بئر (ق-132 / الثابت 743)
--
--    فحص إغلاق فاشل: آبار بأكثر من مضخة active توقف الهجرة برسالة
--    تحمل البئر وعدد المضخات — لا تعطيل تاريخي تلقائي ولا اختيار
--    صامت. الحسم البشري يسبق النشر.
-- ---------------------------------------------------------------------

do $guard$
declare
  v_conflicts record;
  v_found boolean := false;
begin
  for v_conflicts in
    select w.id as well_id, w.name as well_name, count(p.id) as active_count
    from core.wells w
    join core.pumps p
      on p.well_id = w.id
     and p.status = 'active'
    group by w.id, w.name
    having count(p.id) > 1
    order by w.id
  loop
    v_found := true;
    raise warning 'بئر بأكثر من مضخة فعالة: % (%) — مضخات فعالة: %',
      v_conflicts.well_name, v_conflicts.well_id, v_conflicts.active_count;
  end loop;

  if v_found then
    raise exception 'توجد آبار بأكثر من مضخة فعالة واحدة — يلزم حسمها بشريًا قبل نشر قيد المضخة الواحدة (لا تعطيل تلقائي ولا اختيار صامت)';
  end if;
end
$guard$;

create unique index uq_core_pumps_single_active_per_well
  on core.pumps (well_id)
  where status = 'active';

-- ---------------------------------------------------------------------
-- D) نافذة الشمس الحاكمة — مصدر مركزي واحد (ق-132 / الثابت 756)
--
--    timezone = Asia/Aden؛ بداية 06:00 شاملة ونهاية 18:00 غير شاملة
--    لليوم المحدد. هذا مصدر M113 الحالي للـdefault الموثق؛ عندما
--    تنفذ إعدادات Platform Admin مستقبلًا (م-35) يُغيَّر مصدر القيمة
--    هنا وحده دون نشر literals في بقية المنطق. دالة داخلية: لا GRANT
--    للعميل ولا surface عامة جديدة.
-- ---------------------------------------------------------------------

create function ops.solar_window_for_day(p_day date)
returns tstzrange
language sql
stable
security definer
set search_path = pg_catalog, pg_temp
as $function$
  select tstzrange(
    (p_day::timestamp + interval '06:00') at time zone 'Asia/Aden',
    (p_day::timestamp + interval '18:00') at time zone 'Asia/Aden',
    '[)'
  );
$function$;

comment on function ops.solar_window_for_day(date) is
  'ق-132: نافذة الشمس الحاكمة لليوم بمنطقة Asia/Aden — [06:00, 18:00). مصدر واحد للـdefault الموثق حتى تُستبدل بإعدادات Platform Admin (م-35).';

revoke all on function ops.solar_window_for_day(date)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- E) Booking execution readiness evaluator — قراءة فقط typed/stable
--
--    لا يستقبل actor ولا pump id من العميل؛ يبحث عن المضخة الفعالة
--    بنفسه. SECURITY DEFINER ضروري ليقرأ المضخة بمعزل عن RLS المتصل
--    لأن العقود الخادمية القادمة (M113-B) ستستدعيه داخل معاملات
--    خادمية؛ search_path مثبت ومحدود، ولا GRANT للعميل إطلاقًا.
-- ---------------------------------------------------------------------

create function ops.evaluate_booking_execution_readiness(
  p_well_id uuid,
  p_scheduled_start timestamptz,
  p_scheduled_end timestamptz,
  p_expected_energy_source text,
  p_alternative_energy_source text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ops, core, pg_temp
as $function$
declare
  v_active_count integer;
  v_active_pump_id uuid;
  v_window tstzrange;
  v_primary text := p_expected_energy_source;
  v_alternative text := p_alternative_energy_source;
  v_requires_alternative boolean := false;
  v_ready boolean := false;
  v_reason text := 'ready';
begin
  -- 1) صحة الفترة.
  if p_scheduled_start is null or p_scheduled_end is null
     or p_scheduled_end <= p_scheduled_start then
    return jsonb_build_object(
      'ready', false, 'reason_code', 'invalid_period',
      'timezone', 'Asia/Aden',
      'primary_energy_source', v_primary,
      'alternative_energy_source', v_alternative,
      'requires_alternative', false,
      'solar_window_start', null,
      'solar_window_end', null,
      'active_pump_id', null
    );
  end if;

  -- 2) المضخة الفعالة للبئر: بالضبط واحدة؛ والصفر مانع؛ وأكثر من
  --    واحدة مستحيلة بعد قيد M113 فإن ظهرت لا تُخفى.
  select count(*)
    into v_active_count
  from core.pumps p
  where p.well_id = p_well_id
    and p.status = 'active';

  if v_active_count = 1 then
    select p.id
      into v_active_pump_id
    from core.pumps p
    where p.well_id = p_well_id
      and p.status = 'active'
    order by p.id
    limit 1;
  end if;

  if v_active_count <> 1 then
    return jsonb_build_object(
      'ready', false,
      'reason_code',
        case when v_active_count = 0 then 'active_pump_missing'
             else 'active_pump_ambiguous' end,
      'timezone', 'Asia/Aden',
      'primary_energy_source', v_primary,
      'alternative_energy_source', v_alternative,
      'requires_alternative', false,
      'solar_window_start', null,
      'solar_window_end', null,
      'active_pump_id', v_active_pump_id
    );
  end if;

  -- 3) المصدر الأساسي: null مرفوض، وmixed التاريخي وأي نص آخر غير
  --    مدعوم للتنفيذ (ق-132: solar/well_diesel/farmer_diesel حصرًا).
  if v_primary is null then
    return jsonb_build_object(
      'ready', false, 'reason_code', 'missing_energy_source',
      'timezone', 'Asia/Aden',
      'primary_energy_source', v_primary,
      'alternative_energy_source', v_alternative,
      'requires_alternative', false,
      'solar_window_start', null,
      'solar_window_end', null,
      'active_pump_id', v_active_pump_id
    );
  end if;
  if v_primary not in ('solar', 'well_diesel', 'farmer_diesel') then
    return jsonb_build_object(
      'ready', false, 'reason_code', 'unsupported_energy_source',
      'timezone', 'Asia/Aden',
      'primary_energy_source', v_primary,
      'alternative_energy_source', v_alternative,
      'requires_alternative', false,
      'solar_window_start', null,
      'solar_window_end', null,
      'active_pump_id', v_active_pump_id
    );
  end if;

  -- 4) البديل: إن وُجد يجب أن يكون ديزلًا صالحًا — solar/mixed/غيره
  --    مرفوض typed، ووجوده مع أساسي ديزلي غير منطقي ولا يُتجاهل
  --    بصمت (نفس الكود المكتوب: بديل غير صالح في سياقه).
  if v_alternative is not null
     and v_alternative not in ('well_diesel', 'farmer_diesel') then
    return jsonb_build_object(
      'ready', false, 'reason_code', 'invalid_alternative_energy_source',
      'timezone', 'Asia/Aden',
      'primary_energy_source', v_primary,
      'alternative_energy_source', v_alternative,
      'requires_alternative', false,
      'solar_window_start', null,
      'solar_window_end', null,
      'active_pump_id', v_active_pump_id
    );
  end if;
  if v_primary in ('well_diesel', 'farmer_diesel')
     and v_alternative is not null then
    return jsonb_build_object(
      'ready', false, 'reason_code', 'invalid_alternative_energy_source',
      'timezone', 'Asia/Aden',
      'primary_energy_source', v_primary,
      'alternative_energy_source', v_alternative,
      'requires_alternative', false,
      'solar_window_start', null,
      'solar_window_end', null,
      'active_pump_id', v_active_pump_id
    );
  end if;

  -- 5) Solar: البداية داخل نافذة الشمس لذلك اليوم بمنطقة Asia/Aden،
  --    والبديل مطلوب إذا تجاوزت النهاية 18:00 (والنهاية عند 18:00
  --    بالضبط لا تحتاج بديلًا). الزمن من الخادم لا من timezone الجهاز.
  if v_primary = 'solar' then
    v_window := ops.solar_window_for_day(
      (p_scheduled_start at time zone 'Asia/Aden')::date
    );

    if p_scheduled_start < lower(v_window)
       or p_scheduled_start >= upper(v_window) then
      return jsonb_build_object(
        'ready', false, 'reason_code', 'solar_start_outside_window',
        'timezone', 'Asia/Aden',
        'primary_energy_source', v_primary,
        'alternative_energy_source', v_alternative,
        'requires_alternative', false,
        'solar_window_start', lower(v_window),
        'solar_window_end', upper(v_window),
        'active_pump_id', v_active_pump_id
      );
    end if;

    v_requires_alternative := p_scheduled_end > upper(v_window);

    if v_requires_alternative and v_alternative is null then
      return jsonb_build_object(
        'ready', false, 'reason_code', 'missing_alternative_energy_source',
        'timezone', 'Asia/Aden',
        'primary_energy_source', v_primary,
        'alternative_energy_source', v_alternative,
        'requires_alternative', true,
        'solar_window_start', lower(v_window),
        'solar_window_end', upper(v_window),
        'active_pump_id', v_active_pump_id
      );
    end if;
  end if;

  v_ready := true;
  v_reason := 'ready';

  return jsonb_build_object(
    'ready', v_ready,
    'reason_code', v_reason,
    'timezone', 'Asia/Aden',
    'primary_energy_source', v_primary,
    'alternative_energy_source', v_alternative,
    'requires_alternative', v_requires_alternative,
    'solar_window_start',
      case when v_primary = 'solar' then lower(v_window) end,
    'solar_window_end',
      case when v_primary = 'solar' then upper(v_window) end,
    'active_pump_id', v_active_pump_id
  );
end;
$function$;

comment on function ops.evaluate_booking_execution_readiness(uuid, timestamptz, timestamptz, text, text) is
  'ق-132 / الثوابت 742-756: تقييم جاهزية خطة حجز للتنفيذ — قراءة فقط typed بلا كتابة وبلا actor/pump id من العميل. reason codes هي العقد، لا نصوص الرسائل.';

revoke all on function ops.evaluate_booking_execution_readiness(uuid, timestamptz, timestamptz, text, text)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- F) M113-B — إنفاذ الجاهزية في إنشاء الحجز وإعادة جدولته.
--
--    تُخفى تنفيذات M112 غير المتحققة تحت أسماء داخلية بلا EXECUTE
--    لأدوار التطبيق، ثم تمر العقود الوحيدة الجديدة عبر evaluator.
-- ---------------------------------------------------------------------

drop function api.create_booking(
  uuid, uuid, uuid, timestamptz, timestamptz, uuid, text, integer, text
);
drop function api.reschedule_booking(
  uuid, timestamptz, timestamptz, text, uuid
);

alter function ops.create_booking(
  uuid, uuid, uuid, timestamptz, timestamptz, text, integer, text
) rename to create_booking_m112_unchecked;

alter function ops.reschedule_booking(
  uuid, timestamptz, timestamptz, text
) rename to reschedule_booking_m112_unchecked;

revoke all on function ops.create_booking_m112_unchecked(
  uuid, uuid, uuid, timestamptz, timestamptz, text, integer, text
) from public, anon, authenticated, service_role;
revoke all on function ops.reschedule_booking_m112_unchecked(
  uuid, timestamptz, timestamptz, text
) from public, anon, authenticated, service_role;

comment on function ops.create_booking_m112_unchecked(
  uuid, uuid, uuid, timestamptz, timestamptz, text, integer, text
) is
  'تنفيذ M112 داخلي غير قابل للاستدعاء من أدوار التطبيق؛ يستدعيه عقد M113-B بعد readiness فقط.';
comment on function ops.reschedule_booking_m112_unchecked(
  uuid, timestamptz, timestamptz, text
) is
  'تنفيذ M112 داخلي غير قابل للاستدعاء من أدوار التطبيق؛ يستدعيه عقد M113-B بعد readiness فقط.';

create function ops.create_booking(
  p_well_id uuid,
  p_farmer_well_account_id uuid,
  p_farm_id uuid,
  p_scheduled_start timestamptz,
  p_scheduled_end timestamptz,
  p_expected_energy_source text,
  p_priority integer,
  p_notes text,
  p_alternative_energy_source text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ops, core, audit, iam, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_readiness jsonb;
  v_result jsonb;
  v_active_pump_id uuid;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إنشاء حجز سقي';
  end if;
  if not iam.has_well_permission(p_well_id, 'booking.create') then
    raise exception 'لا تملك صلاحية إنشاء حجز في هذا البئر';
  end if;

  v_readiness := ops.evaluate_booking_execution_readiness(
    p_well_id,
    p_scheduled_start,
    p_scheduled_end,
    p_expected_energy_source,
    p_alternative_energy_source
  );

  if not coalesce((v_readiness ->> 'ready')::boolean, false) then
    return jsonb_build_object(
      'status', 'rejected',
      'reason_code', v_readiness ->> 'reason_code',
      'requested_start', p_scheduled_start,
      'requested_end', p_scheduled_end,
      'execution_readiness', v_readiness
    );
  end if;

  v_active_pump_id := (v_readiness ->> 'active_pump_id')::uuid;
  perform 1
  from core.pumps p
  where p.id = v_active_pump_id
    and p.well_id = p_well_id
    and p.status = 'active'
  for update;

  if not found then
    v_readiness := ops.evaluate_booking_execution_readiness(
      p_well_id,
      p_scheduled_start,
      p_scheduled_end,
      p_expected_energy_source,
      p_alternative_energy_source
    );
    return jsonb_build_object(
      'status', 'rejected',
      'reason_code', v_readiness ->> 'reason_code',
      'requested_start', p_scheduled_start,
      'requested_end', p_scheduled_end,
      'execution_readiness', v_readiness
    );
  end if;

  v_result := ops.create_booking_m112_unchecked(
    p_well_id,
    p_farmer_well_account_id,
    p_farm_id,
    p_scheduled_start,
    p_scheduled_end,
    p_expected_energy_source,
    p_priority,
    p_notes
  );

  if v_result ->> 'status' = 'confirmed' then
    update ops.irrigation_bookings
    set alternative_energy_source = p_alternative_energy_source
    where id = (v_result ->> 'booking_id')::uuid;
  end if;

  return v_result || jsonb_build_object(
    'alternative_energy_source', p_alternative_energy_source,
    'execution_readiness', v_readiness
  );
end;
$function$;

revoke all on function ops.create_booking(
  uuid, uuid, uuid, timestamptz, timestamptz, text, integer, text, text
) from public, anon, authenticated, service_role;
grant execute on function ops.create_booking(
  uuid, uuid, uuid, timestamptz, timestamptz, text, integer, text, text
) to authenticated, service_role;

create function ops.reschedule_booking(
  p_booking_id uuid,
  p_scheduled_start timestamptz,
  p_scheduled_end timestamptz,
  p_reason text,
  p_alternative_energy_source text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ops, core, audit, iam, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_booking ops.irrigation_bookings%rowtype;
  v_alternative text;
  v_readiness jsonb;
  v_result jsonb;
  v_active_pump_id uuid;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إعادة جدولة الحجز';
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

  -- NULL يعني أن العميل القديم لم يرسل الوسيط: احتفظ بالمحفوظ.
  -- تغيير البديل يتم بقيمة غير NULL صريحة، فلا تصفير صامتًا.
  v_alternative := coalesce(
    p_alternative_energy_source,
    v_booking.alternative_energy_source
  );

  v_readiness := ops.evaluate_booking_execution_readiness(
    v_booking.well_id,
    p_scheduled_start,
    p_scheduled_end,
    v_booking.expected_energy_source,
    v_alternative
  );

  if not coalesce((v_readiness ->> 'ready')::boolean, false) then
    return jsonb_build_object(
      'status', 'rejected',
      'reason_code', v_readiness ->> 'reason_code',
      'booking_id', p_booking_id,
      'requested_start', p_scheduled_start,
      'requested_end', p_scheduled_end,
      'execution_readiness', v_readiness
    );
  end if;

  v_active_pump_id := (v_readiness ->> 'active_pump_id')::uuid;
  perform 1
  from core.pumps p
  where p.id = v_active_pump_id
    and p.well_id = v_booking.well_id
    and p.status = 'active'
  for update;

  if not found then
    v_readiness := ops.evaluate_booking_execution_readiness(
      v_booking.well_id,
      p_scheduled_start,
      p_scheduled_end,
      v_booking.expected_energy_source,
      v_alternative
    );
    return jsonb_build_object(
      'status', 'rejected',
      'reason_code', v_readiness ->> 'reason_code',
      'booking_id', p_booking_id,
      'requested_start', p_scheduled_start,
      'requested_end', p_scheduled_end,
      'execution_readiness', v_readiness
    );
  end if;

  v_result := ops.reschedule_booking_m112_unchecked(
    p_booking_id,
    p_scheduled_start,
    p_scheduled_end,
    p_reason
  );

  if v_result ->> 'status' = 'confirmed' then
    update ops.irrigation_bookings
    set alternative_energy_source = v_alternative
    where id = p_booking_id;
  end if;

  return v_result || jsonb_build_object(
    'alternative_energy_source', v_alternative,
    'execution_readiness', v_readiness
  );
end;
$function$;

revoke all on function ops.reschedule_booking(
  uuid, timestamptz, timestamptz, text, text
) from public, anon, authenticated, service_role;
grant execute on function ops.reschedule_booking(
  uuid, timestamptz, timestamptz, text, text
) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- G) تحقق replay داخل حد sync الموثوق، بلا كشف request_payload.
--
--    أغلفة api هي SECURITY INVOKER ولا يجوز أن تفسر صفًا حجبه RLS
--    على أنه اختلاف محتوى. هذا المساعد يحل الجهة من البئر، ويتحقق من
--    التعيين والصلاحية، ثم يعيد العقد والحالة والرد المخزن فقط.
-- ---------------------------------------------------------------------

create function sync.verify_booking_command_replay(
  p_well_id uuid,
  p_command_id uuid,
  p_command_type text,
  p_m113_payload jsonb,
  p_m112_payload jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_tenant_id uuid;
  v_required_permission text;
  v_stored_type text;
  v_stored_payload jsonb;
  v_status text;
  v_response jsonb;
  v_contract_version integer;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إعادة إرسال أمر حجز';
  end if;
  if p_command_id is null then
    raise exception 'معرّف العملية مطلوب';
  end if;

  v_required_permission := case p_command_type
    when 'create_booking' then 'booking.create'
    when 'reschedule_booking' then 'booking.reschedule'
    else null
  end;
  if v_required_permission is null then
    raise exception 'نوع أمر الحجز غير مدعوم: %', p_command_type;
  end if;

  select w.tenant_id
    into v_tenant_id
  from core.wells w
  where w.id = p_well_id
    and exists (
      select 1
      from core.well_assignments wa
      where wa.well_id = w.id
        and wa.profile_id = v_actor
        and wa.status = 'active'
    );

  if v_tenant_id is null then
    raise exception 'البئر غير موجود أو لا تملك وصولًا إليه';
  end if;
  if not iam.has_well_permission(p_well_id, v_required_permission) then
    if p_command_type = 'create_booking' then
      raise exception 'لا تملك صلاحية إنشاء حجز في هذا البئر';
    end if;
    raise exception 'لا تملك صلاحية إعادة جدولة حجز في هذا البئر';
  end if;

  if jsonb_typeof(p_m113_payload) is distinct from 'object'
     or p_m113_payload ->> 'booking_contract_version' is distinct from '113'
     or (p_m113_payload ->> 'well_id')::uuid is distinct from p_well_id then
    raise exception 'معرّف العملية مستخدم لمحتوى مختلف';
  end if;

  if p_command_type = 'create_booking' then
    if not exists (
      select 1
      from ops.farmer_well_accounts fwa
      join ops.farms f
        on f.id = (p_m113_payload ->> 'farm_id')::uuid
       and f.farmer_well_account_id = fwa.id
       and f.well_id = fwa.well_id
      where fwa.id = (p_m113_payload ->> 'farmer_well_account_id')::uuid
        and fwa.well_id = p_well_id
    ) then
      raise exception 'معرّف العملية مستخدم لمحتوى مختلف';
    end if;
  elsif not exists (
    select 1
    from ops.irrigation_bookings b
    where b.id = (p_m113_payload ->> 'booking_id')::uuid
      and b.well_id = p_well_id
  ) then
    raise exception 'معرّف العملية مستخدم لمحتوى مختلف';
  end if;

  select
    pc.command_type,
    pc.request_payload,
    pc.status,
    pc.response_payload
  into
    v_stored_type,
    v_stored_payload,
    v_status,
    v_response
  from sync.processed_commands pc
  where pc.tenant_id = v_tenant_id
    and pc.command_id = p_command_id;

  if not found then
    raise exception 'الأمر غير موجود: %', p_command_id;
  end if;
  if v_stored_type is distinct from p_command_type then
    raise exception 'معرّف العملية مستخدم لمحتوى مختلف';
  end if;

  if v_stored_payload ? 'booking_contract_version' then
    if v_stored_payload ->> 'booking_contract_version' is distinct from '113'
       or v_stored_payload is distinct from p_m113_payload then
      raise exception 'معرّف العملية مستخدم لمحتوى مختلف';
    end if;
    v_contract_version := 113;
  else
    if v_stored_payload is distinct from p_m112_payload then
      raise exception 'معرّف العملية مستخدم لمحتوى مختلف';
    end if;
    v_contract_version := 112;
  end if;

  return jsonb_build_object(
    'booking_contract_version', v_contract_version,
    'status', v_status,
    'response', v_response
  );
end;
$function$;

comment on function sync.verify_booking_command_replay(
  uuid, uuid, text, jsonb, jsonb
) is
  'ق-114/ق-132: يتحقق داخليًا من نطاق أمر الحجز ونوعه وبصمته، ويعيد الرد المخزن بلا كشف request_payload.';

revoke all on function sync.verify_booking_command_replay(
  uuid, uuid, text, jsonb, jsonb
) from public, anon, authenticated, service_role;
grant execute on function sync.verify_booking_command_replay(
  uuid, uuid, text, jsonb, jsonb
) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- H) الأغلفة العامة: بصمة محتوى كاملة لعقود M113-B.
--
--    أوامر M112 المقبولة قبل هذه الهجرة تحمل البصمة القديمة؛ تُقبل
--    إعادة محاولتها المطابقة دون تغيير النتيجة. الأوامر الجديدة تحمل
--    booking_contract_version وتُقارن بكل وسيط مؤثر.
-- ---------------------------------------------------------------------

create function api.create_booking(
  p_well_id uuid,
  p_farmer_well_account_id uuid,
  p_farm_id uuid,
  p_scheduled_start timestamptz,
  p_scheduled_end timestamptz,
  p_command_id uuid,
  p_expected_energy_source text default null,
  p_priority integer default 0,
  p_notes text default null,
  p_alternative_energy_source text default null
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
  v_payload jsonb;
  v_legacy_payload jsonb;
  v_replay jsonb;
begin
  if p_command_id is null then
    raise exception 'معرّف العملية مطلوب';
  end if;

  v_payload := jsonb_build_object(
    'booking_contract_version', 113,
    'well_id', p_well_id,
    'farmer_well_account_id', p_farmer_well_account_id,
    'farm_id', p_farm_id,
    'scheduled_start', p_scheduled_start,
    'scheduled_end', p_scheduled_end,
    'expected_energy_source', p_expected_energy_source,
    'alternative_energy_source', p_alternative_energy_source,
    'priority', p_priority,
    'notes', p_notes
  );
  v_legacy_payload := jsonb_build_object(
    'farmer_well_account_id', p_farmer_well_account_id,
    'farm_id', p_farm_id,
    'scheduled_start', p_scheduled_start,
    'scheduled_end', p_scheduled_end
  );

  v_guard := sync.begin_well_command(
    p_well_id, p_command_id, 'create_booking', v_payload
  );

  if coalesce((v_guard ->> 'duplicate')::boolean, false) then
    v_replay := sync.verify_booking_command_replay(
      p_well_id,
      p_command_id,
      'create_booking',
      v_payload,
      v_legacy_payload
    );

    if (v_replay ->> 'booking_contract_version')::integer = 112
       and v_replay ->> 'status' = 'accepted'
       and (
         p_alternative_energy_source is not null
         or not exists (
           select 1
           from ops.irrigation_bookings b
           where b.id = (v_replay -> 'response' ->> 'booking_id')::uuid
             and b.expected_energy_source is not distinct from p_expected_energy_source
             and b.priority is not distinct from p_priority
             and b.notes is not distinct from p_notes
         )
       ) then
      raise exception 'معرّف العملية مستخدم لمحتوى مختلف';
    end if;

    if v_replay ->> 'status' in ('accepted', 'conflict', 'rejected') then
      return v_replay -> 'response';
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
    p_notes,
    p_alternative_energy_source
  );

  if v_result ->> 'status' = 'conflict' then
    perform sync.finish_well_command(
      p_well_id, p_command_id, 'conflict', v_result
    );
  elsif v_result ->> 'status' = 'rejected' then
    perform sync.finish_well_command(
      p_well_id, p_command_id, 'rejected', v_result
    );
  elsif v_result ->> 'status' = 'confirmed' then
    perform sync.finish_well_command(
      p_well_id, p_command_id, 'accepted', v_result
    );
  else
    raise exception 'نتيجة إنشاء الحجز غير معروفة: %',
      coalesce(v_result ->> 'status', 'null');
  end if;

  return v_result;
end;
$function$;

revoke all on function api.create_booking(
  uuid, uuid, uuid, timestamptz, timestamptz, uuid,
  text, integer, text, text
) from public, anon, authenticated, service_role;
grant execute on function api.create_booking(
  uuid, uuid, uuid, timestamptz, timestamptz, uuid,
  text, integer, text, text
) to authenticated, service_role;


create function api.reschedule_booking(
  p_booking_id uuid,
  p_scheduled_start timestamptz,
  p_scheduled_end timestamptz,
  p_reason text,
  p_command_id uuid,
  p_alternative_energy_source text default null
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
  v_payload jsonb;
  v_legacy_payload jsonb;
  v_replay jsonb;
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

  v_payload := jsonb_build_object(
    'booking_contract_version', 113,
    'well_id', v_well_id,
    'booking_id', p_booking_id,
    'scheduled_start', p_scheduled_start,
    'scheduled_end', p_scheduled_end,
    'reason', btrim(p_reason),
    'alternative_energy_source', p_alternative_energy_source
  );
  v_legacy_payload := jsonb_build_object(
    'booking_id', p_booking_id,
    'scheduled_start', p_scheduled_start,
    'scheduled_end', p_scheduled_end
  );

  v_guard := sync.begin_well_command(
    v_well_id, p_command_id, 'reschedule_booking', v_payload
  );

  if coalesce((v_guard ->> 'duplicate')::boolean, false) then
    v_replay := sync.verify_booking_command_replay(
      v_well_id,
      p_command_id,
      'reschedule_booking',
      v_payload,
      v_legacy_payload
    );

    if (v_replay ->> 'booking_contract_version')::integer = 112
       and p_alternative_energy_source is not null then
      raise exception 'معرّف العملية مستخدم لمحتوى مختلف';
    end if;

    if v_replay ->> 'status' in ('accepted', 'conflict', 'rejected') then
      return v_replay -> 'response';
    end if;
    raise exception 'العملية نفسها قيد المعالجة أو تحتاج مراجعة';
  end if;

  v_result := ops.reschedule_booking(
    p_booking_id,
    p_scheduled_start,
    p_scheduled_end,
    p_reason,
    p_alternative_energy_source
  );

  if v_result ->> 'status' = 'conflict' then
    perform sync.finish_well_command(
      v_well_id, p_command_id, 'conflict', v_result
    );
  elsif v_result ->> 'status' = 'rejected' then
    perform sync.finish_well_command(
      v_well_id, p_command_id, 'rejected', v_result
    );
  elsif v_result ->> 'status' = 'confirmed' then
    perform sync.finish_well_command(
      v_well_id, p_command_id, 'accepted', v_result
    );
  else
    raise exception 'نتيجة إعادة الجدولة غير معروفة: %',
      coalesce(v_result ->> 'status', 'null');
  end if;

  return v_result;
end;
$function$;

revoke all on function api.reschedule_booking(
  uuid, timestamptz, timestamptz, text, uuid, text
) from public, anon, authenticated, service_role;
grant execute on function api.reschedule_booking(
  uuid, timestamptz, timestamptz, text, uuid, text
) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- H) القراءات: المصدر البديل المخزن جزء من عقد التنفيذ اللاحق.
-- ---------------------------------------------------------------------

create or replace function api.list_well_bookings(
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

  select coalesce(
      jsonb_agg(item order by item ->> 'scheduled_start', item ->> 'public_code'),
      '[]'::jsonb
    )
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
      'alternative_energy_source', b.alternative_energy_source,
      'status', b.status,
      'priority', b.priority,
      'notes', b.notes,
      'created_at', b.created_at
    ) as item
    from ops.irrigation_bookings b
    left join ops.farms f on f.id = b.farm_id
    left join ops.farmer_well_accounts fwa
      on fwa.id = b.farmer_well_account_id
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


revoke all on function api.list_well_bookings(
  uuid, timestamptz, timestamptz, integer
) from public, anon, authenticated, service_role;
grant execute on function api.list_well_bookings(
  uuid, timestamptz, timestamptz, integer
) to authenticated, service_role;


create or replace function api.get_booking_detail(p_booking_id uuid)
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
    raise exception 'لا تملك صلاحية قراءة هذا الحجز'
      using errcode = '42501';
  end if;

  if not iam.has_well_permission(v_booking.well_id, 'booking.read') then
    if v_booking.farmer_well_account_id is distinct from
       iam.current_farmer_well_account_id(v_booking.well_id) then
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
      'scheduled_day',
        (v_booking.scheduled_start at time zone v_tz)::date::text,
      'expected_duration_minutes', v_booking.expected_duration_minutes,
      'expected_energy_source', v_booking.expected_energy_source,
      'alternative_energy_source', v_booking.alternative_energy_source,
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

-- ---------------------------------------------------------------------
-- I) M113-C — تسلسل إدراج الجلسات على المضخة.
--
--    القفل لا يغيّر حد التوازي القائم؛ بل يجعل trigger الحاكم من 062
--    يرى الإدراج السابق بعد اكتماله، فيحفظ قراره تحت التزامن لكل من
--    مسار الحجز ومسار البدء الحر القديم.
-- ---------------------------------------------------------------------

create function ops.lock_session_pump_for_concurrency()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $function$
begin
  perform 1
  from core.pumps p
  where p.id = new.pump_id
    and p.well_id = new.well_id
  for update;

  return new;
end;
$function$;

revoke all on function ops.lock_session_pump_for_concurrency()
  from public, anon, authenticated, service_role;

create trigger irrigation_sessions_00_pump_lock
before insert on ops.irrigation_sessions
for each row execute function ops.lock_session_pump_for_concurrency();

-- ---------------------------------------------------------------------
-- J-pre) M113-E2-a — سلسلة تشغيل الحجوزات الدائمة.
--
--    حالة دائمة لكل بئر تثبت أن أول بدء يدوي ناجح من حجز قد حدث فعلًا
--    (ق-132 §ه / الثابتان 252/253). التسليح يُثبَت بجلسة البداية الحقيقية
--    opened_by_session_id لا براية مجردة. سلسلة واحدة غير منتهية لكل بئر
--    بفهرس فريد جزئي. الكتابة عبر مسار البدء الموثوق (DEFINER) وحده؛ لا
--    DML مباشر لأدوار التطبيق. تقدّم السلسلة (الجلسة الحالية/الانتظار/
--    القرار/التالي) مؤجَّل إلى E2-b/c؛ حقولها معرَّفة خاملة الآن.
-- ---------------------------------------------------------------------

create table ops.booking_transition_chains (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id),
  well_id uuid not null references core.wells(id),
  status text not null default 'active'
    check (status in
      ('active', 'waiting', 'pending_start', 'decision_required', 'blocked', 'ended')),
  opened_by_session_id uuid not null references ops.irrigation_sessions(id),
  opened_at timestamptz not null,
  current_session_id uuid references ops.irrigation_sessions(id),
  next_booking_id uuid references ops.irrigation_bookings(id),
  last_decision text check (last_decision in ('run_now', 'wait')),
  decided_at timestamptz,
  decided_by uuid references iam.profiles(id),
  -- عدّاد قرارات تصاعدي للمقارنة-والتبديل (E2-b FIX2): يمنع قرارًا قديمًا
  -- من تجاوز قرار أحدث؛ يبدأ 0 عند التأسيس ويزيد مع كل قرار مقبول.
  decision_revision bigint not null default 0,
  ended_at timestamptz,
  ended_reason text,
  created_at timestamptz not null default now(),
  created_by uuid not null references iam.profiles(id),
  constraint booking_transition_chains_ended_consistent
    check ((status = 'ended') = (ended_at is not null))
);

-- ضمان قاعدي: سلسلة واحدة غير منتهية لكل بئر (لا فحص مسبق وحده).
create unique index booking_transition_chains_one_active_per_well
  on ops.booking_transition_chains (well_id)
  where status <> 'ended';

create index booking_transition_chains_well_status_idx
  on ops.booking_transition_chains (well_id, status);

alter table ops.booking_transition_chains enable row level security;

-- اتساق الجهة والبئر وجلستي البداية/الحالية على مستوى القاعدة.
create function ops.enforce_booking_transition_chain_consistency()
returns trigger
language plpgsql
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_well uuid;
  v_tenant uuid;
begin
  select s.well_id into v_well
  from ops.irrigation_sessions s
  where s.id = new.opened_by_session_id;
  if v_well is null or v_well is distinct from new.well_id then
    raise exception 'جلسة بداية السلسلة لا تنتمي لبئر السلسلة';
  end if;

  if new.current_session_id is not null then
    select s.well_id into v_well
    from ops.irrigation_sessions s
    where s.id = new.current_session_id;
    if v_well is null or v_well is distinct from new.well_id then
      raise exception 'الجلسة الحالية للسلسلة لا تنتمي لبئرها';
    end if;
  end if;

  select w.tenant_id into v_tenant
  from core.wells w
  where w.id = new.well_id;
  if v_tenant is null or v_tenant is distinct from new.tenant_id then
    raise exception 'جهة السلسلة لا تطابق جهة البئر';
  end if;

  return new;
end;
$function$;

revoke all on function ops.enforce_booking_transition_chain_consistency()
  from public, anon, authenticated, service_role;

create trigger booking_transition_chains_consistency
before insert or update on ops.booking_transition_chains
for each row execute function ops.enforce_booking_transition_chain_consistency();

-- القراءة تركّب رؤية البئر لطاقم booking.read؛ لا سياسة كتابة = الكتابة
-- محجوبة عن كل دور تطبيق، وتجري عبر مسار البدء DEFINER وحده.
create policy booking_transition_chains_select_staff
  on ops.booking_transition_chains
  for select
  to authenticated
  using (iam.has_well_permission(well_id, 'booking.read'));

grant select on ops.booking_transition_chains to authenticated;

comment on table ops.booking_transition_chains is
  'ق-132 §ه / 252-253 / E2-a: سلسلة تشغيل حجوزات البئر — تثبت أول بدء يدوي ناجح بجلسة بداية حقيقية؛ سلسلة واحدة غير منتهية لكل بئر؛ الكتابة عبر مسار البدء DEFINER وحده. تقدّم الحالة مؤجَّل إلى E2-b/c.';

-- ---------------------------------------------------------------------
-- J-pre2) E2-c1 — مصالحة السلسلة عند الإغلاق المحاسبي الصحيح (أي مسار).
--
--    حين تُغلق الجلسة الجارية لسلسلة فعّالة بـ open→closed — عبر أي مسار
--    إكمال محاسبي بما فيه غلاف M084 القديم — تنتقل السلسلة إلى
--    decision_required: الدور انتهى وثمة قرار صريح منتظر، لا بدء ناجح ولا
--    انتظار محفوظ ولا نهاية. زناد لا غلاف: فلا يُغلق مسارٌ قديم الجلسة دون
--    مصالحة السلسلة (الشرط الحرج). الحالة forgotten (هجر لا إكمال مالي
--    ناجح، ولا يكتبها عقد قائم) مستثناة صراحةً فلا تُعدّ إذنًا للانتقال.
--    لا يلمس opened_by_session_id ولا decision_revision ولا سجل القرارات،
--    ولا يستبدل current_session_id (يبقى الجلسة المغلقة الصادقة).
-- ---------------------------------------------------------------------

create function ops.reconcile_booking_chain_on_session_close()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $function$
begin
  update ops.booking_transition_chains
  set status = 'decision_required'
  where current_session_id = new.id
    and status = 'active';
  return new;
end;
$function$;

revoke all on function ops.reconcile_booking_chain_on_session_close()
  from public, anon, authenticated, service_role;

create trigger irrigation_sessions_zz_chain_reconcile
after update on ops.irrigation_sessions
for each row
when (old.status = 'open' and new.status = 'closed')
execute function ops.reconcile_booking_chain_on_session_close();

-- ---------------------------------------------------------------------
-- J) بدء جلسة من بيانات الحجز الحاكمة.
--
--    المدخلات التشغيلية الوحيدة هي زمن التنفيذ الفعلي والمحاصيل؛
--    البئر والمزارع والأرض والطاقة والمضخة والمدة كلها من الخادم.
-- ---------------------------------------------------------------------

-- E2-c2-S: نواة داخلية غير ممنوحة لأي دور تطبيقي. تنفيذ قرار run_now
-- المحفوظ (chain في pending_start) حصرٌ على عقد التنفيذ المخصص
-- execute_pending_booking_start بعد مقارنة-وتبديل على decision_revision؛
-- فالبدء المباشر من pending_start ممنوع. العلم p_executing_pending_decision
-- يُمرَّر true من المنفِّذ وحده (دالة definer بلا منح للعميل)، false من
-- الغلاف اليدوي؛ العميل لا يملك EXECUTE على النواة ولا يرى العلم فلا يُنتحَل.
create function ops.start_booking_session_core(
  p_booking_id uuid,
  p_operator_profile_id uuid,
  p_started_at timestamptz,
  p_crops text[] default null,
  p_executing_pending_decision boolean default false
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_well_id uuid;
  v_tenant_id uuid;
  v_chain ops.booking_transition_chains%rowtype;
  v_has_chain boolean := false;
  v_prev_status text;
  v_booking ops.irrigation_bookings%rowtype;
  v_readiness jsonb;
  v_pump_id uuid;
  v_session_id uuid;
  v_operational_end_at timestamptz;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل بدء جلسة من حجز';
  end if;
  if p_operator_profile_id is distinct from v_actor then
    raise exception 'معرف المشغل يجب أن يطابق المستخدم المسجل حاليًا';
  end if;
  if p_started_at is null then
    raise exception 'زمن البداية الفعلي مطلوب';
  end if;
  -- ق-132 و)/ز) + الثابتان 748/753: الزمن الفعلي حقيقة لا تُختلق، ولا
  -- تُنسب للجلسة بداية لم تحدث. المستقبل غير مُثبَت خادميًا: ساعة الخادم
  -- تُثبت أن أي بداية بعد اللحظة الحالية مستحيلة الحدوث. لا نستبدل زمن
  -- حدث ماضٍ صحيح (Offline وصل متأخرًا) بوقت الوصول — الحد الأدنى فجوة
  -- سياسة لم تُعتمد بعد؛ الحد الأعلى هنا هو ما يملك الخادم إثباته فقط.
  if p_started_at > clock_timestamp() then
    raise exception 'زمن البداية الفعلي لا يكون في المستقبل'
      using errcode = '22023';
  end if;

  -- E2-c2-a: ترتيب أقفال موحّد chain → booking → pump لتفادي دورة أقفال مع
  -- record_booking_transition_decision (الذي يقفل chain ثم booking). نقرأ
  -- بئر الحجز بلا قفل (البئر ثابت) ثم نقفل السلسلة الفعّالة أولًا إن وُجدت.
  select b.well_id, b.tenant_id into v_well_id, v_tenant_id
  from ops.irrigation_bookings b
  where b.id = p_booking_id;
  if not found then
    raise exception 'الحجز غير موجود أو لا تملك وصولًا إليه';
  end if;

  select c.* into v_chain
  from ops.booking_transition_chains c
  where c.well_id = v_well_id and c.status <> 'ended'
  for update;
  v_has_chain := found;

  select b.*
    into v_booking
  from ops.irrigation_bookings b
  where b.id = p_booking_id
  for update;

  if not found then
    raise exception 'الحجز غير موجود أو لا تملك وصولًا إليه';
  end if;
  if not iam.has_well_permission(v_booking.well_id, 'session.start') then
    raise exception 'لا تملك صلاحية بدء جلسة على هذا البئر';
  end if;
  if v_booking.status <> 'confirmed' then
    raise exception 'لا يمكن بدء جلسة من حجز غير مؤكد';
  end if;
  if exists (
    select 1
    from ops.irrigation_sessions s
    where s.booking_id = p_booking_id
  ) then
    raise exception 'الحجز مرتبط بجلسة سابقة ولا يمكن بدء جلسة ثانية';
  end if;

  v_readiness := ops.evaluate_booking_execution_readiness(
    v_booking.well_id,
    v_booking.scheduled_start,
    v_booking.scheduled_end,
    v_booking.expected_energy_source,
    v_booking.alternative_energy_source
  );

  if not coalesce((v_readiness ->> 'ready')::boolean, false) then
    raise exception 'الحجز غير جاهز للتنفيذ: %',
      coalesce(v_readiness ->> 'reason_code', 'unknown');
  end if;

  if v_booking.farm_id is null
     or not exists (
       select 1
       from ops.farmer_well_accounts fwa
       join ops.farms f
         on f.id = v_booking.farm_id
        and f.well_id = fwa.well_id
        and f.farmer_well_account_id = fwa.id
        and f.status = 'active'
       where fwa.id = v_booking.farmer_well_account_id
         and fwa.well_id = v_booking.well_id
         and fwa.status = 'active'
     ) then
    raise exception 'الحجز غير جاهز للتنفيذ: invalid_farmer_or_farm';
  end if;

  v_pump_id := (v_readiness ->> 'active_pump_id')::uuid;
  perform 1
  from core.pumps p
  where p.id = v_pump_id
    and p.well_id = v_booking.well_id
    and p.status = 'active'
  for update;
  if not found then
    raise exception 'الحجز غير جاهز للتنفيذ: active_pump_missing';
  end if;

  if exists (
    select 1
    from ops.irrigation_sessions s
    where s.well_id = v_booking.well_id
      and s.status = 'open'
  ) then
    raise exception 'لا يمكن بدء الحجز: توجد جلسة مفتوحة مانعة على البئر';
  end if;

  -- E2-c2-a/b/S: بدء حجز لاحق في سلسلة قائمة. يُسمح من decision_required (قرار
  -- يدوي بالتشغيل بعد الإكمال) أو waiting (بدء يدوي مبكر مسموح، ق-132 §و/750).
  -- أما pending_start (قرار run_now محفوظ) فتنفيذه حصرٌ على عقد التنفيذ
  -- المخصص الذي يقارن النسخة؛ البدء المباشر منه ممنوع ولو لحجزه المحدَّد
  -- (p_executing_pending_decision=false) فلا يتجاوز بدءٌ العقدَ الحاكم. المنفِّذ
  -- وحده يمرّر العلم true بعد CAS. بدء حجز مختلف من pending_start مرفوض أصلًا.
  -- active/blocked محجوبتان بحارس الجلسة المفتوحة أعلاه.
  if v_has_chain then
    if v_chain.status in ('decision_required', 'waiting') then
      null;
    elsif v_chain.status = 'pending_start'
          and v_chain.last_decision = 'run_now'
          and v_chain.next_booking_id = p_booking_id then
      if not p_executing_pending_decision then
        raise exception 'نفّذ قرار التشغيل المحفوظ عبر عقد التنفيذ المخصص، لا بالبدء المباشر'
          using errcode = '22023';
      end if;
    else
      raise exception 'لا يمكن بدء حجز لاحق والسلسلة في الحالة %', v_chain.status
        using errcode = '22023';
    end if;
    -- بوابة تسوية الجلسة السابقة: مغلقة فعلًا (لا forgotten) ولها تسوية
    -- محاسبية مثبتة. status='closed' وحدها ليست دليل تسوية. قراءة بلا قفل
    -- (الجلسة السابقة مغلقة ثابتة) لتفادي حافة chain→session في ترتيب الأقفال.
    if v_chain.current_session_id is null then
      raise exception 'السلسلة بلا جلسة سابقة لإثبات حسمها';
    end if;
    select s.status into v_prev_status
    from ops.irrigation_sessions s
    where s.id = v_chain.current_session_id and s.well_id = v_well_id;
    if v_prev_status is null then
      raise exception 'الجلسة السابقة لا تنتمي لبئر السلسلة';
    end if;
    if v_prev_status <> 'closed' then
      raise exception 'لا يبدأ التالي قبل حسم الجلسة السابقة (closed)'
        using errcode = '22023';
    end if;
    if not exists (
      select 1 from billing.session_charges sc
      where sc.session_id = v_chain.current_session_id
    ) then
      raise exception 'الجلسة السابقة بلا تسوية محاسبية مثبتة — لا يبدأ التالي'
        using errcode = '22023';
    end if;
  end if;

  v_session_id := ops.start_irrigation_session(
    v_booking.well_id,
    v_pump_id,
    v_booking.farm_id,
    v_booking.farmer_well_account_id,
    v_actor,
    v_booking.expected_energy_source,
    p_started_at,
    null,
    p_crops
  );

  update ops.irrigation_sessions
  set booking_id = p_booking_id
  where id = v_session_id;

  if not found then
    raise exception 'تعذر ربط جلسة السقي بالحجز';
  end if;

  -- السلسلة (STEP 4/5): أول بدء (لا سلسلة فعّالة) يؤسّس سلسلة بدليل جلسة
  -- البداية؛ بدء لاحق (سلسلة قائمة مقفلة أعلاه) يُحدّث current_session_id
  -- إلى الجلسة الجديدة ويعيد الحالة active (بدء فعلي ناجح)، دون لمس
  -- opened_by_session_id ولا decision_revision ولا سجل القرارات. الإعادة
  -- المطابقة لا تصل هنا (حارس الأمر يعيد الرد المخزَّن).
  --
  -- E2-d (STEP 2): إن كان next_booking_id يشير إلى الحجز الذي استُهلك الآن
  -- (p_booking_id) — وهو حال تنفيذ pending_start والبدء اليدوي المبكر أثناء
  -- waiting لنفس التالي — نمسح المؤشر في المعاملة ذاتها فلا يبقى معلّقًا على
  -- حجز صار جلسةً. مؤشرٌ لحجز آخر (جلسة عابرة أثناء waiting) يبقى كما هو. لا
  -- مسّ لـ decision_revision (ليس قرارًا جديدًا) ولا لسجل القرارات ولا
  -- opened_by. المسح بعد نجاح الإنشاء حصرًا؛ الفشل يُرجِع كل شيء ذريًا.
  if v_has_chain then
    update ops.booking_transition_chains
    set current_session_id = v_session_id,
        status = 'active',
        next_booking_id = case
          when next_booking_id = p_booking_id then null
          else next_booking_id
        end
    where id = v_chain.id;
  else
    insert into ops.booking_transition_chains (
      tenant_id, well_id, status, opened_by_session_id, opened_at,
      current_session_id, created_by
    ) values (
      v_booking.tenant_id, v_booking.well_id, 'active',
      v_session_id, p_started_at, v_session_id, v_actor
    );
  end if;

  v_operational_end_at := p_started_at
    + make_interval(mins => v_booking.expected_duration_minutes);

  return jsonb_build_object(
    'booking_id', p_booking_id,
    'booking_status', v_booking.status,
    'session_id', v_session_id,
    'session_status', 'open',
    'well_id', v_booking.well_id,
    'farmer_well_account_id', v_booking.farmer_well_account_id,
    'farm_id', v_booking.farm_id,
    'pump_id', v_pump_id,
    'energy_source', v_booking.expected_energy_source,
    'alternative_energy_source', v_booking.alternative_energy_source,
    'started_at', p_started_at,
    'booked_duration_minutes', v_booking.expected_duration_minutes,
    'operational_end_at', v_operational_end_at
  );
end;
$function$;

comment on function ops.start_booking_session_core(
  uuid, uuid, timestamptz, text[], boolean
) is
  'ق-132 / E2-c2-S: نواة بدء جلسة من حجز confirmed (المضخة الفعالة وقت البدء، ربط booking_id ذريًا). غير ممنوحة لأي دور تطبيقي؛ تنفيذ pending_start حصرٌ على المنفِّذ الذي يمرّر العلم true بعد CAS.';

-- النواة بلا أي منح لأدوار التطبيق: العميل لا يصلها مباشرة فلا يمرّر العلم.
-- يستدعيها فقط الغلافان definer في هذا الملف عبر ملكية الدالة.
revoke all on function ops.start_booking_session_core(
  uuid, uuid, timestamptz, text[], boolean
) from public, anon, authenticated, service_role;

-- الغلاف اليدوي: يحافظ على التوقيع والمنح السابقين (api يبقى invoker ويستدعيه)
-- ويمرّر العلم false دائمًا، فالبدء المباشر من pending_start ممنوع.
create function ops.start_irrigation_session_from_booking(
  p_booking_id uuid,
  p_operator_profile_id uuid,
  p_started_at timestamptz,
  p_crops text[] default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
begin
  return ops.start_booking_session_core(
    p_booking_id, p_operator_profile_id, p_started_at, p_crops, false
  );
end;
$function$;

comment on function ops.start_irrigation_session_from_booking(
  uuid, uuid, timestamptz, text[]
) is
  'ق-132: فعل بدء يدوي صريح من حجز confirmed؛ يفوّض للنواة بعلم تنفيذ=false، فلا يبدأ pending_start مباشرة (يُنفَّذ عبر عقد التنفيذ المخصص).';

revoke all on function ops.start_irrigation_session_from_booking(
  uuid, uuid, timestamptz, text[]
) from public, anon, authenticated, service_role;
grant execute on function ops.start_irrigation_session_from_booking(
  uuid, uuid, timestamptz, text[]
) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- K) حارس الأمر: يحل الجهة والبئر من الحجز، ويقارن الحمولة داخل sync
--    حيث لا تحجب RLS الصف المخزن. لا يعيد request_payload للعميل.
-- ---------------------------------------------------------------------

create function sync.begin_booking_session_command(
  p_booking_id uuid,
  p_command_id uuid,
  p_started_at timestamptz,
  p_crops text[] default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_tenant_id uuid;
  v_well_id uuid;
  v_payload jsonb;
  v_guard jsonb;
  v_stored_type text;
  v_stored_payload jsonb;
  v_status text;
  v_response jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل بدء جلسة من حجز';
  end if;
  if p_command_id is null then
    raise exception 'معرّف العملية مطلوب';
  end if;
  if p_started_at is null then
    raise exception 'زمن البداية الفعلي مطلوب';
  end if;

  select w.tenant_id, b.well_id
    into v_tenant_id, v_well_id
  from ops.irrigation_bookings b
  join core.wells w on w.id = b.well_id
  where b.id = p_booking_id
    and exists (
      select 1
      from core.well_assignments wa
      where wa.well_id = b.well_id
        and wa.profile_id = v_actor
        and wa.status = 'active'
    );

  if v_tenant_id is null then
    raise exception 'الحجز غير موجود أو لا تملك وصولًا إليه';
  end if;
  if not iam.has_well_permission(v_well_id, 'session.start') then
    raise exception 'لا تملك صلاحية بدء جلسة على هذا البئر';
  end if;

  v_payload := jsonb_build_object(
    'booking_execution_contract_version', 113,
    'booking_id', p_booking_id,
    'started_at', p_started_at,
    'crops', to_jsonb(p_crops)
  );

  v_guard := sync.begin_command(
    v_tenant_id,
    p_command_id,
    'start_irrigation_session_from_booking',
    v_payload,
    p_booking_id
  );

  if not coalesce((v_guard ->> 'duplicate')::boolean, false) then
    return jsonb_build_object(
      'duplicate', false,
      'well_id', v_well_id
    );
  end if;

  select
    pc.command_type,
    pc.request_payload,
    pc.status,
    pc.response_payload
  into
    v_stored_type,
    v_stored_payload,
    v_status,
    v_response
  from sync.processed_commands pc
  where pc.tenant_id = v_tenant_id
    and pc.command_id = p_command_id;

  if not found
     or v_stored_type is distinct from
          'start_irrigation_session_from_booking'
     or v_stored_payload is distinct from v_payload then
    raise exception 'معرّف العملية مستخدم لمحتوى مختلف';
  end if;

  return jsonb_build_object(
    'duplicate', true,
    'well_id', v_well_id,
    'status', v_status,
    'response', v_response
  );
end;
$function$;

comment on function sync.begin_booking_session_command(
  uuid, uuid, timestamptz, text[]
) is
  'ق-114/ق-132: يحجز أمر بدء جلسة من حجز ويقارن بصمته داخل sync بعد حل الجهة والبئر من الحجز؛ لا يكشف الحمولة المخزنة.';

revoke all on function sync.begin_booking_session_command(
  uuid, uuid, timestamptz, text[]
) from public, anon, authenticated, service_role;
grant execute on function sync.begin_booking_session_command(
  uuid, uuid, timestamptz, text[]
) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- L) سطح API المستقل — يبقى SECURITY INVOKER.
-- ---------------------------------------------------------------------

create function api.start_irrigation_session_from_booking(
  p_booking_id uuid,
  p_started_at timestamptz,
  p_command_id uuid,
  p_crops text[] default null
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
  v_well_id uuid;
begin
  v_guard := sync.begin_booking_session_command(
    p_booking_id,
    p_command_id,
    p_started_at,
    p_crops
  );

  v_well_id := (v_guard ->> 'well_id')::uuid;

  if coalesce((v_guard ->> 'duplicate')::boolean, false) then
    if v_guard ->> 'status' = 'accepted' then
      return v_guard -> 'response';
    end if;
    raise exception 'العملية نفسها قيد المعالجة أو تحتاج مراجعة';
  end if;

  v_result := ops.start_irrigation_session_from_booking(
    p_booking_id,
    auth.uid(),
    p_started_at,
    p_crops
  );

  perform sync.finish_well_command(
    v_well_id,
    p_command_id,
    'accepted',
    v_result
  );

  return v_result;
end;
$function$;

comment on function api.start_irrigation_session_from_booking(
  uuid, timestamptz, uuid, text[]
) is
  'ق-132: فعل صريح idempotent لبدء جلسة من حجز confirmed؛ العميل يرسل booking/time/command/crops فقط.';

revoke all on function api.start_irrigation_session_from_booking(
  uuid, timestamptz, uuid, text[]
) from public, anon, authenticated, service_role;
grant execute on function api.start_irrigation_session_from_booking(
  uuid, timestamptz, uuid, text[]
) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- M) M113-D — عقد قراءة «جدول اليوم» (قراءة فقط، SECURITY INVOKER).
--
--   اليوم الحاكم بمنطقة Asia/Aden (ق-132 §ب / الثابت 756): عند غياب
--   p_day يُشتق اليوم من الآن بمنطقة Asia/Aden، لا من منطقة الهاتف ولا
--   من منطقة اتصال قاعدة البيانات، وبلا Cron. نافذة اليوم من منتصف
--   الليل إلى منتصف الليل بـ Asia/Aden فتلتقط الحجوزات/الجلسات العابرة
--   لمنتصف الليل عبر تداخل المدى. booking ≠ session: الحقول المخططة
--   (scheduled_*) منفصلة عن الفعلية (session.*) ولا اختلاق عند الغياب.
-- ---------------------------------------------------------------------

create function api.get_well_day_schedule(
  p_well_id uuid,
  p_day date default null
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_staff boolean;
  v_self_account uuid;
  v_day date;
  v_window tstzrange;
  v_day_start timestamptz;
  v_day_end timestamptz;
  v_well_tz text;
  v_current_session jsonb;
  v_bookings jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة جدول اليوم';
  end if;

  v_staff := iam.has_well_permission(p_well_id, 'booking.read');
  if not v_staff then
    v_self_account := iam.current_farmer_well_account_id(p_well_id);
    if v_self_account is null then
      raise exception 'لا تملك صلاحية قراءة جدول هذا البئر'
        using errcode = '42501';
    end if;
  end if;

  -- اليوم الحاكم = Asia/Aden (ق-132 §ب / الثابت 756)، لا منطقة الهاتف
  -- ولا منطقة اتصال قاعدة البيانات؛ وبلا Cron لتغيّر التاريخ. النافذة
  -- محسوبة سطريًا هنا داخل غلاف SECURITY INVOKER: لا دالة مساعدة تحتاج
  -- GRANT لدور تطبيق (تفادي permission denied بلا توسيع صلاحيات ops).
  v_day := coalesce(p_day, (now() at time zone 'Asia/Aden')::date);
  v_window := tstzrange(
    (v_day::timestamp) at time zone 'Asia/Aden',
    ((v_day + 1)::timestamp) at time zone 'Asia/Aden',
    '[)'
  );
  v_day_start := lower(v_window);
  v_day_end := upper(v_window);
  v_well_tz := core.well_timezone(p_well_id);

  -- الجلسة الجارية (status='open') المرئية للمستخدم المخوّل إن تداخلت
  -- مع يوم الطلب (بدأت قبل نهاية اليوم). لا اختلاق: null عند غيابها.
  select jsonb_build_object(
      'session_id', s.id,
      'status', s.status,
      'started_at', s.started_at,
      'ended_at', s.ended_at,
      'well_id', s.well_id,
      'pump_id', s.pump_id,
      'farm_id', s.farm_id,
      'farmer_well_account_id', s.farmer_well_account_id,
      'booking_id', s.booking_id,
      'booking_public_code', b.public_code
    )
    into v_current_session
  from ops.irrigation_sessions s
  left join ops.irrigation_bookings b on b.id = s.booking_id
  where s.well_id = p_well_id
    and s.status = 'open'
    and (v_staff or s.farmer_well_account_id = v_self_account)
    and s.started_at < v_day_end
  order by s.started_at desc
  limit 1;

  -- حجوزات اليوم: كل حجز يتداخل مع نافذة اليوم (يشمل العابر لمنتصف
  -- الليل). الترتيب: المجموعة الفعّالة أولًا ثم المطوية، وداخل كل
  -- مجموعة بوقت البداية ثم الأولوية ثم الرمز العام. الجلسة الفعلية
  -- تُرفق في مفتاح session منفصل عن الحقول المخططة (booking ≠ session).
  select coalesce(
      jsonb_agg(
        x.item
        order by x.grp_rank, x.scheduled_start, x.priority desc, x.public_code
      ),
      '[]'::jsonb
    )
    into v_bookings
  from (
    select
      b.scheduled_start,
      b.priority,
      b.public_code,
      case
        when b.status in
          ('confirmed','pending','waiting','ready','started') then 0
        when b.status in
          ('completed','postponed','cancelled','no_show') then 1
        else 2
      end as grp_rank,
      jsonb_build_object(
        'id', b.id,
        'public_code', b.public_code,
        'well_id', b.well_id,
        'farmer_well_account_id', b.farmer_well_account_id,
        'farmer_name', person.full_name,
        'farm_id', b.farm_id,
        'farm_name', f.name,
        'scheduled_start', b.scheduled_start,
        'scheduled_end', b.scheduled_end,
        'scheduled_day',
          (b.scheduled_start at time zone 'Asia/Aden')::date::text,
        'expected_duration_minutes', b.expected_duration_minutes,
        'expected_energy_source', b.expected_energy_source,
        'alternative_energy_source', b.alternative_energy_source,
        'status', b.status,
        'priority', b.priority,
        'status_group', case
          when b.status in
            ('confirmed','pending','waiting','ready','started') then 'active'
          when b.status in
            ('completed','postponed','cancelled','no_show') then 'closed'
          else 'draft'
        end,
        'notes', b.notes,
        'session', case
          when s.id is null then null
          else jsonb_build_object(
            'session_id', s.id,
            'status', s.status,
            'started_at', s.started_at,
            'ended_at', s.ended_at
          )
        end
      ) as item
    from ops.irrigation_bookings b
    left join ops.farms f on f.id = b.farm_id
    left join ops.farmer_well_accounts fwa
      on fwa.id = b.farmer_well_account_id
    left join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
    left join core.persons person on person.id = fp.person_id
    left join ops.irrigation_sessions s on s.booking_id = b.id
    where b.well_id = p_well_id
      and (v_staff or b.farmer_well_account_id = v_self_account)
      and tstzrange(b.scheduled_start, b.scheduled_end, '[)') && v_window
  ) x;

  return jsonb_build_object(
    'status', 'ok',
    'well_id', p_well_id,
    'requested_day', v_day::text,
    'timezone', 'Asia/Aden',
    'day_start', v_day_start,
    'day_end', v_day_end,
    'well_timezone', v_well_tz,
    'current_session', v_current_session,
    'count', jsonb_array_length(v_bookings),
    'bookings', v_bookings
  );
end;
$function$;

comment on function api.get_well_day_schedule(uuid, date) is
  'ق-132 §ب: جدول اليوم للبئر بتاريخ مطلوب أو اليوم الحالي بمنطقة Asia/Aden. الجلسة الجارية منفصلة، والحجوزات موسومة active/closed مع ربط الجلسة الفعلية دون اختلاق. SECURITY INVOKER يحترم booking.read و RLS و M112 self-scope.';

revoke all on function api.get_well_day_schedule(uuid, date)
  from public, anon, authenticated, service_role;
grant execute on function api.get_well_day_schedule(uuid, date)
  to authenticated, service_role;

-- ---------------------------------------------------------------------
-- M) M113-E1 — مُقيّم حالة انتقال الحجوزات (قراءة فقط، للعرض والقرار).
--
--    يحدد الحالة التشغيلية الحالية للبئر والحجز المؤكد التالي تمهيدًا
--    لجولة تنفيذ الانتقال (E2). لا DML ولا بدء/إنهاء، ولا يُعدّ ناتجه
--    تصريحًا دائمًا بالبدء: التنفيذ اللاحق يعيد التحقق ذريًا (ق-132
--    §و/ز). التوقيت من ساعة الخادم لا العميل، وبلوغ الموعد وحده ليس
--    إذنًا ببداية فعلية. جاهزية الطاقة/المضخة/الشمس لا تُكرَّر هنا:
--    مُقيّمها DEFINER محجوب عن أدوار التطبيق (نمط ق-79)، ويعاد تقييمها
--    ذريًا وقت البدء — فلا توسيع صلاحيات ولا منطق مكرَّر قابل للتباعد.
-- ---------------------------------------------------------------------
create function api.evaluate_well_booking_transition(p_well_id uuid)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := now();
  v_session record;
  v_next record;
  v_has_open boolean := false;
  v_current jsonb := null;
  v_next_json jsonb := null;
  v_reached_end boolean := null;
  v_op_end timestamptz := null;
  v_next_due boolean := false;
  v_decision text;
  v_reason text;
  v_safe_auto boolean := false;
  v_req_decision boolean := false;
  v_req_manual boolean := false;
  -- E2-d: رؤية السلسلة الدائمة المخوّلة (قراءة فقط).
  v_chain_armed boolean := false;
  v_chain_status text := null;
  v_chain_cur uuid := null;
  v_chain_next uuid := null;
  v_chain_dec text := null;
  v_chain_rev bigint := null;
  v_timing_eligible boolean := false;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل تقييم حالة الانتقال'
      using errcode = '28000';
  end if;
  -- بوابة واحدة: صلاحية طاقم القراءة التشغيلية. كشف الجلسة المانعة يحتاج
  -- رؤية كل جلسات البئر المفتوحة (قد تخص مزارعًا آخر)، فلا يُفتح هذا
  -- السطح لنطاق المزارع الذاتي تفاديًا لتسريب جلسة غيره أو قرار مضلِّل.
  -- جدول اليوم يبقى سطح المزارع.
  if not iam.has_well_permission(p_well_id, 'booking.read') then
    raise exception 'لا تملك صلاحية تقييم حالة انتقال هذا البئر'
      using errcode = '42501';
  end if;

  -- الجلسة الجارية (status='open') على البئر إن وُجدت، مع مدتها المحجوزة
  -- حين تكون ناتجة عن حجز. الجلسة الحرة/العابرة (booking_id null) بلا حد
  -- تشغيلي معروف فلا يُختلق لها حد. RLS تحكم الرؤية؛ null عند الغياب.
  select s.id, s.started_at, s.status, s.booking_id,
         b.expected_duration_minutes as dur
    into v_session
  from ops.irrigation_sessions s
  left join ops.irrigation_bookings b on b.id = s.booking_id
  where s.well_id = p_well_id
    and s.status = 'open'
  order by s.started_at desc
  limit 1;
  v_has_open := found;

  if v_has_open then
    -- الثابت 748: الحد = البداية الفعلية + المدة المحجوزة لا scheduled_end.
    if v_session.booking_id is not null and v_session.dur is not null then
      v_op_end := v_session.started_at + make_interval(mins => v_session.dur);
      v_reached_end := v_now >= v_op_end;
    else
      v_op_end := null;
      v_reached_end := null;  -- حرة/عابرة: لا حد محجوز، لا اختلاق
    end if;
    v_current := jsonb_build_object(
      'session_id', v_session.id,
      'status', v_session.status,
      'started_at', v_session.started_at,
      'booking_id', v_session.booking_id,
      'is_booked', v_session.booking_id is not null,
      'booked_duration_minutes', v_session.dur,
      'operational_end_at', v_op_end,
      'reached_operational_end', v_reached_end
    );
  end if;

  -- الحجز المؤكد التالي غير المرتبط بجلسة بعد: أبكر موعد ثم الأولوية ثم
  -- الرمز. قد يكون مستحقًا/متأخرًا/مستقبليًا. booking ≠ session: وجود
  -- جلسة على الحجز يستهلكه فلا يُعدّ "التالي".
  select b.id, b.public_code, b.scheduled_start, b.scheduled_end,
         b.expected_duration_minutes, b.expected_energy_source,
         b.alternative_energy_source
    into v_next
  from ops.irrigation_bookings b
  where b.well_id = p_well_id
    and b.status = 'confirmed'
    and not exists (
      select 1 from ops.irrigation_sessions s where s.booking_id = b.id
    )
  order by b.scheduled_start asc, b.priority desc, b.public_code asc
  limit 1;

  if found then
    v_next_due := v_next.scheduled_start <= v_now;  -- مستحق أو متأخر
    v_next_json := jsonb_build_object(
      'id', v_next.id,
      'public_code', v_next.public_code,
      'scheduled_start', v_next.scheduled_start,
      'scheduled_end', v_next.scheduled_end,
      'expected_duration_minutes', v_next.expected_duration_minutes,
      'expected_energy_source', v_next.expected_energy_source,
      'alternative_energy_source', v_next.alternative_energy_source,
      'timing', case when v_next_due then 'due' else 'future' end,
      'is_overdue', v_next.scheduled_start < v_now
    );
  end if;

  -- شجرة القرار (ق-132 §و + الثوابت 748-753 و252/253 بصيغة §ه). الفرق
  -- الحاكم: «بلوغ الموعد» ليس «إذنًا آمنًا ببداية فعلية». الإذن الآمن
  -- للانتقال التلقائي لا يكون إلا من جلسة جارية بلغت حدها الفعلي؛ وأول
  -- بدء في السلسلة يدوي صريح لا ينشأ ببلوغ الوقت وحده.
  if v_next_json is null then
    v_decision := 'no_next_booking';
    v_reason := 'no_confirmed_next_booking';
  elsif v_has_open then
    if v_reached_end is true then
      if v_next_due then
        v_decision := 'transition_ready';
        v_reason := 'current_reached_end_next_due';
        -- E2-d: أهلية توقيت لا إذن تنفيذ. safe_to_auto_start يبقى محافظًا
        -- false (الجاهزية غير مفحوصة هنا، والجلسة الحالية ما تزال مفتوحة).
        v_timing_eligible := true;
      else
        v_decision := 'decision_required_run_now_or_wait';
        v_reason := 'current_reached_end_next_future';
        v_req_decision := true;
      end if;
    else
      -- جلسة لم تبلغ حدها، أو حرة/عابرة بلا حد: لا انتقال فوقها (751).
      if v_next_due then
        v_decision := 'blocked_by_open_session';
        v_reason := case when v_session.booking_id is null
                         then 'transient_session_blocks_due_next'
                         else 'current_session_active_blocks_due_next' end;
        v_req_decision := true;
      else
        v_decision := 'waiting';
        v_reason := 'open_session_running_next_future';
      end if;
    end if;
  else
    -- لا جلسة مفتوحة: البدء الأول/الصريح يدوي (252/253). بلوغ الموعد أو
    -- تجاوزه لا ينشئ جلسة ولا يمنح إذنًا؛ القرار فعل مستخدم صريح.
    v_decision := 'manual_start_required';
    v_reason := case when v_next_due then 'manual_start_pending_due'
                     else 'manual_start_awaiting_schedule' end;
    v_req_manual := true;
  end if;

  -- E2-d (STEP 3): رؤية السلسلة الدائمة المخوّلة (RLS: booking.read). فهرس
  -- فريد جزئي يضمن ≤1 سلسلة غير منتهية لكل بئر. قراءة فقط بلا قفل. تميّز
  -- السلسلة المسلّحة (active/waiting/pending_start/decision_required/blocked)
  -- عن غيابها (أول بدء يدوي)، وتفصح عن current_session_id الصادق للسلسلة
  -- (قد يكون جلسة مغلقة) مقابل الجلسة المفتوحة الحالية v_current أعلاه.
  select c.status, c.current_session_id, c.next_booking_id,
         c.last_decision, c.decision_revision
    into v_chain_status, v_chain_cur, v_chain_next, v_chain_dec, v_chain_rev
  from ops.booking_transition_chains c
  where c.well_id = p_well_id and c.status <> 'ended';
  v_chain_armed := found;

  return jsonb_build_object(
    'contract', 'evaluate_well_booking_transition',
    'version', 1,
    'well_id', p_well_id,
    'server_time', v_now,
    'timezone', 'Asia/Aden',
    'has_open_session', v_has_open,
    'current_session', v_current,
    'next_booking', v_next_json,
    'decision', v_decision,
    'reason_code', v_reason,
    'safe_to_auto_start', v_safe_auto,
    'requires_user_decision', v_req_decision,
    'requires_manual_start', v_req_manual,
    'advisory_only', true,
    -- E2-d: حقول السلسلة الاستشارية. chain_armed=سلسلة غير منتهية موجودة؛
    -- pending_execution=قرار run_now محفوظ ينتظر عقد التنفيذ المخصص؛
    -- transition_timing_eligible=أهلية توقيت للانتقال لا إذن تنفيذ؛
    -- requires_atomic_recheck=الجاهزية/المنع يُعاد فحصهما ذريًا وقت البدء.
    'chain_armed', v_chain_armed,
    'chain_status', v_chain_status,
    'chain', case when v_chain_armed then jsonb_build_object(
        'status', v_chain_status,
        'current_session_id', v_chain_cur,
        'next_booking_id', v_chain_next,
        'last_decision', v_chain_dec,
        'decision_revision', v_chain_rev
      ) else null end,
    'pending_execution', coalesce(v_chain_status = 'pending_start', false),
    'transition_timing_eligible', v_timing_eligible,
    'requires_atomic_recheck', true,
    'execution_readiness_note',
      'energy/pump/solar readiness is re-evaluated atomically at session start, not here',
    'missed_exact_start_note',
      'offline missed-start arming is not in schema; overdue is not proof of a missed armed start'
  );
end;
$function$;

comment on function api.evaluate_well_booking_transition(uuid) is
  'ق-132 §و/ز / E2-d: تقييم حالة انتقال الحجوزات للبئر — قراءة فقط للعرض والقرار. SECURITY INVOKER + booking.read؛ التوقيت من الخادم؛ بلوغ الموعد ليس إذنًا ببداية فعلية؛ لا DML. يفصح عن حالة السلسلة الدائمة (chain_armed/chain_status/pending_execution) ويميّز current المفتوحة عن جلسة السلسلة المغلقة. safe_to_auto_start محافظ (false): الجاهزية والمنع يُعاد فحصهما ذريًا وقت البدء (requires_atomic_recheck)، والأهلية الزمنية في transition_timing_eligible.';

revoke all on function api.evaluate_well_booking_transition(uuid)
  from public, anon, authenticated, service_role;
grant execute on function api.evaluate_well_booking_transition(uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------
-- N) M113-E2-b — قرارات الانتقال الدائمة (run_now / wait).
--
--    حفظ قرار المشغل حول الحجز التالي كسجل مؤرَّخ قابل للتدقيق، دون بدء
--    جلسة أو إكمالها أو انتقال فعلي (ق-132 §و: الانتظار قرار مقصود لا
--    سقوط صامت). القرار يُقبل فقط بعد حسم الجلسة السابقة وبلا جلسة مانعة؛
--    و wait لا يُخفي لحظة فائتة (الثابت 753). الكتابة عبر مسار موثوق
--    DEFINER مع حارس أمر إيديمبوتنت؛ لا DML مباشر لأدوار التطبيق.
-- ---------------------------------------------------------------------

create table ops.booking_transition_decisions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id),
  well_id uuid not null references core.wells(id),
  chain_id uuid not null references ops.booking_transition_chains(id),
  prev_session_id uuid not null references ops.irrigation_sessions(id),
  next_booking_id uuid not null references ops.irrigation_bookings(id),
  decision text not null check (decision in ('run_now', 'wait')),
  decided_by uuid not null references iam.profiles(id),
  decided_at timestamptz not null default now(),
  command_id uuid not null,
  created_at timestamptz not null default now(),
  constraint booking_transition_decisions_command_unique
    unique (tenant_id, command_id)
);

create index booking_transition_decisions_chain_idx
  on ops.booking_transition_decisions (chain_id, decided_at);

alter table ops.booking_transition_decisions enable row level security;

-- قراءة فقط لطاقم booking.read؛ لا سياسة كتابة = محجوبة عن أدوار التطبيق.
create policy booking_transition_decisions_select_staff
  on ops.booking_transition_decisions
  for select
  to authenticated
  using (iam.has_well_permission(well_id, 'booking.read'));

grant select on ops.booking_transition_decisions to authenticated;

comment on table ops.booking_transition_decisions is
  'ق-132 §و / E2-b: سجل مؤرَّخ لقرارات انتقال الحجوزات (run_now/wait) — تاريخ قابل للتدقيق لا تحديث مكان واحد؛ الكتابة عبر مسار DEFINER إيديمبوتنت وحده.';

create function ops.record_booking_transition_decision(
  p_chain_id uuid,
  p_prev_session_id uuid,
  p_next_booking_id uuid,
  p_decision text,
  p_expected_revision bigint,
  p_actor uuid,
  p_command_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_chain ops.booking_transition_chains%rowtype;
  v_next ops.irrigation_bookings%rowtype;
  v_prev_status text;
  v_prev_well uuid;
  v_decision_id uuid;
  v_new_status text;
  v_new_revision bigint;
  v_now timestamptz := now();
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل تسجيل قرار الانتقال';
  end if;
  if p_actor is distinct from v_actor then
    raise exception 'معرف المستخدم يجب أن يطابق المسجل حاليًا';
  end if;
  if p_decision is null or p_decision not in ('run_now', 'wait') then
    raise exception 'قرار الانتقال يجب أن يكون run_now أو wait'
      using errcode = '22023';
  end if;

  -- قفل السلسلة لتسلسل القرارات المتنافسة وإعادة التحقق الحاكم تحته.
  select c.* into v_chain
  from ops.booking_transition_chains c
  where c.id = p_chain_id
  for update;
  if not found then
    raise exception 'سلسلة الانتقال غير موجودة';
  end if;
  if v_chain.status = 'ended' then
    raise exception 'لا يمكن اتخاذ قرار على سلسلة منتهية'
      using errcode = '22023';
  end if;
  if not iam.has_well_permission(v_chain.well_id, 'session.start') then
    raise exception 'لا تملك صلاحية اتخاذ قرار انتقال على هذا البئر'
      using errcode = '42501';
  end if;

  -- FIX2 (مقارنة-وتبديل): القرار يحمل النسخة التي رآها العميل. تحت القفل
  -- نرفض النسخة القديمة بلا كتابة فلا يتجاوز قرار قديم قرارًا أحدث؛
  -- والمقبول يزيد العدّاد ذريًا. (الإعادة المطابقة لا تصل هنا: حارس الأمر
  -- يعيد الرد المخزَّن ولو تقدّمت النسخة.)
  if p_expected_revision is distinct from v_chain.decision_revision then
    raise exception 'نسخة قرار قديمة؛ أُعيد تقييم الحالة (المتوقع % الحالي %)',
      p_expected_revision, v_chain.decision_revision
      using errcode = '40001';
  end if;

  -- الجلسة السابقة = الجلسة الحالية للسلسلة، ويجب أن تكون محسومة (مغلقة).
  if p_prev_session_id is distinct from v_chain.current_session_id then
    raise exception 'الجلسة السابقة لا تطابق الجلسة الحالية للسلسلة'
      using errcode = '22023';
  end if;
  select s.status, s.well_id into v_prev_status, v_prev_well
  from ops.irrigation_sessions s
  where s.id = p_prev_session_id;
  if v_prev_status is null or v_prev_well is distinct from v_chain.well_id then
    raise exception 'الجلسة السابقة لا تنتمي لبئر السلسلة';
  end if;
  if v_prev_status <> 'closed' then
    raise exception 'لا يُتخذ قرار انتقال قبل حسم الجلسة السابقة'
      using errcode = '22023';
  end if;

  -- لا جلسة مفتوحة مانعة على البئر (شرط run_now و wait معًا، الثابت 751).
  if exists (
    select 1 from ops.irrigation_sessions s
    where s.well_id = v_chain.well_id and s.status = 'open'
  ) then
    raise exception 'توجد جلسة مفتوحة مانعة على البئر؛ لا يُتخذ القرار الآن'
      using errcode = '22023';
  end if;

  -- الحجز التالي: مؤكد وغير مستهلك ومن البئر والجهة نفسيهما.
  select b.* into v_next
  from ops.irrigation_bookings b
  where b.id = p_next_booking_id
  for update;
  if not found
     or v_next.well_id is distinct from v_chain.well_id
     or v_next.tenant_id is distinct from v_chain.tenant_id then
    raise exception 'الحجز التالي غير موجود أو من بئر/جهة مختلفة'
      using errcode = '22023';
  end if;
  if v_next.status <> 'confirmed' then
    raise exception 'الحجز التالي غير مؤكد'
      using errcode = '22023';
  end if;
  if exists (
    select 1 from ops.irrigation_sessions s where s.booking_id = p_next_booking_id
  ) then
    raise exception 'الحجز التالي مستهلك بجلسة سابقة'
      using errcode = '22023';
  end if;

  -- FIX3 (ق-132 §و / الثابت 750): «انتظار حتى الموعد» يتطلب حجزًا تاليًا
  -- لم يحن موعده بعد؛ فإن حلّ موعده أو تجاوزه فلا شيء يُنتظر (القرار عندئذ
  -- تشغيل لا انتظار). هذا رفض انطباق لا تصنيفُ لحظةِ تنفيذ تلقائي فائتة:
  -- الثابت 753 يخصّ تفويت لحظة تنفيذ مقصودة فعليًا (Offline) ولا يُستنتج
  -- من مجرد مرور الموعد، ولا يُنفَّذ كشفه في هذه الجولة.
  if p_decision = 'wait' and v_next.scheduled_start <= v_now then
    raise exception 'قرار الانتظار يتطلب حجزًا تاليًا لم يحن موعده بعد'
      using errcode = '22023';
  end if;

  insert into ops.booking_transition_decisions (
    tenant_id, well_id, chain_id, prev_session_id, next_booking_id,
    decision, decided_by, decided_at, command_id
  ) values (
    v_chain.tenant_id, v_chain.well_id, p_chain_id, p_prev_session_id,
    p_next_booking_id, p_decision, v_actor, v_now, p_command_id
  ) returning id into v_decision_id;

  -- wait → waiting (انتظار مقصود). run_now → pending_start: نيّة بدء
  -- مسجَّلة بانتظار التنفيذ، لا جلسة تعمل. لا تُنشأ جلسة ولا يتغيّر
  -- current_session_id (يبقى صادقًا)، ولا يُعاد تعريف opened_by_session_id
  -- ولا التسليح. البدء الفعلي وتحوّل الحالة إلى active في E2-c.
  if p_decision = 'wait' then
    v_new_status := 'waiting';
  else
    v_new_status := 'pending_start';
  end if;

  v_new_revision := v_chain.decision_revision + 1;

  update ops.booking_transition_chains
  set status = v_new_status,
      last_decision = p_decision,
      decided_at = v_now,
      decided_by = v_actor,
      next_booking_id = p_next_booking_id,
      decision_revision = v_new_revision
  where id = p_chain_id;

  return jsonb_build_object(
    'contract', 'record_booking_transition_decision',
    'version', 1,
    'decision_id', v_decision_id,
    'chain_id', p_chain_id,
    'well_id', v_chain.well_id,
    'prev_session_id', p_prev_session_id,
    'next_booking_id', p_next_booking_id,
    'decision', p_decision,
    'chain_status', v_new_status,
    'chain_revision', v_new_revision,
    'decided_by', v_actor,
    'decided_at', v_now
  );
end;
$function$;

revoke all on function ops.record_booking_transition_decision(
  uuid, uuid, uuid, text, bigint, uuid, uuid
) from public, anon, authenticated, service_role;
grant execute on function ops.record_booking_transition_decision(
  uuid, uuid, uuid, text, bigint, uuid, uuid
) to authenticated, service_role;

create function sync.begin_booking_transition_decision_command(
  p_chain_id uuid,
  p_prev_session_id uuid,
  p_next_booking_id uuid,
  p_decision text,
  p_expected_revision bigint,
  p_command_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_tenant_id uuid;
  v_well_id uuid;
  v_payload jsonb;
  v_guard jsonb;
  v_stored_type text;
  v_stored_payload jsonb;
  v_status text;
  v_response jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل تسجيل قرار الانتقال';
  end if;
  if p_command_id is null then
    raise exception 'معرّف العملية مطلوب';
  end if;
  if p_decision is null or p_decision not in ('run_now', 'wait') then
    raise exception 'قرار الانتقال يجب أن يكون run_now أو wait';
  end if;

  -- الجهة/البئر من السلسلة داخل sync حيث لا تحجب RLS الصف، مع تعيين نشط.
  select w.tenant_id, c.well_id
    into v_tenant_id, v_well_id
  from ops.booking_transition_chains c
  join core.wells w on w.id = c.well_id
  where c.id = p_chain_id
    and c.status <> 'ended'
    and exists (
      select 1 from core.well_assignments wa
      where wa.well_id = c.well_id
        and wa.profile_id = v_actor
        and wa.status = 'active'
    );
  if v_tenant_id is null then
    raise exception 'سلسلة الانتقال غير موجودة أو منتهية أو لا تملك وصولًا إليها';
  end if;
  if not iam.has_well_permission(v_well_id, 'session.start') then
    raise exception 'لا تملك صلاحية اتخاذ قرار انتقال على هذا البئر';
  end if;

  -- النسخة المتوقعة جزء من بصمة الإيديمبوتنس: إعادة بنفس المعرّف والنسخة
  -- تعيد الرد المخزَّن، واختلاف النسخة لنفس المعرّف = حمولة مختلفة.
  v_payload := jsonb_build_object(
    'booking_execution_contract_version', 113,
    'chain_id', p_chain_id,
    'prev_session_id', p_prev_session_id,
    'next_booking_id', p_next_booking_id,
    'decision', p_decision,
    'expected_revision', p_expected_revision
  );

  v_guard := sync.begin_command(
    v_tenant_id,
    p_command_id,
    'record_booking_transition_decision',
    v_payload,
    p_chain_id
  );

  if not coalesce((v_guard ->> 'duplicate')::boolean, false) then
    return jsonb_build_object('duplicate', false, 'well_id', v_well_id);
  end if;

  select pc.command_type, pc.request_payload, pc.status, pc.response_payload
  into v_stored_type, v_stored_payload, v_status, v_response
  from sync.processed_commands pc
  where pc.tenant_id = v_tenant_id
    and pc.command_id = p_command_id;

  if not found
     or v_stored_type is distinct from 'record_booking_transition_decision'
     or v_stored_payload is distinct from v_payload then
    raise exception 'معرّف العملية مستخدم لمحتوى مختلف';
  end if;

  return jsonb_build_object(
    'duplicate', true,
    'well_id', v_well_id,
    'status', v_status,
    'response', v_response
  );
end;
$function$;

revoke all on function sync.begin_booking_transition_decision_command(
  uuid, uuid, uuid, text, bigint, uuid
) from public, anon, authenticated, service_role;
grant execute on function sync.begin_booking_transition_decision_command(
  uuid, uuid, uuid, text, bigint, uuid
) to authenticated, service_role;

create function api.record_booking_transition_decision(
  p_chain_id uuid,
  p_prev_session_id uuid,
  p_next_booking_id uuid,
  p_decision text,
  p_expected_revision bigint,
  p_command_id uuid
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
  v_well_id uuid;
begin
  v_guard := sync.begin_booking_transition_decision_command(
    p_chain_id,
    p_prev_session_id,
    p_next_booking_id,
    p_decision,
    p_expected_revision,
    p_command_id
  );

  v_well_id := (v_guard ->> 'well_id')::uuid;

  if coalesce((v_guard ->> 'duplicate')::boolean, false) then
    if v_guard ->> 'status' = 'accepted' then
      return v_guard -> 'response';
    end if;
    raise exception 'العملية نفسها قيد المعالجة أو تحتاج مراجعة';
  end if;

  v_result := ops.record_booking_transition_decision(
    p_chain_id,
    p_prev_session_id,
    p_next_booking_id,
    p_decision,
    p_expected_revision,
    auth.uid(),
    p_command_id
  );

  perform sync.finish_well_command(
    v_well_id,
    p_command_id,
    'accepted',
    v_result
  );

  return v_result;
end;
$function$;

comment on function api.record_booking_transition_decision(
  uuid, uuid, uuid, text, bigint, uuid
) is
  'ق-132 §و / E2-b: حفظ قرار الانتقال (run_now/wait) للحجز التالي — تحقق حاكم ذري بمقارنة-وتبديل على decision_revision، بلا بدء/إكمال جلسة. run_now → pending_start. SECURITY INVOKER + session.start + حارس أمر إيديمبوتنت.';

revoke all on function api.record_booking_transition_decision(
  uuid, uuid, uuid, text, bigint, uuid
) from public, anon, authenticated, service_role;
grant execute on function api.record_booking_transition_decision(
  uuid, uuid, uuid, text, bigint, uuid
) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- O) M113-E2-c1 — إكمال جلسة محجوزة واعٍ بالسلسلة (المرحلة الأولى).
--
--    غلاف يضيف حارس المستقبل على ended_at وعضوية السلسلة والإيديمبوتنس،
--    ويفوّض المحاسبة كاملةً إلى ops.complete_irrigation_session (لا تكرار
--    خوارزمية رسوم ولا صف session_charges ثانٍ). مصالحة حالة السلسلة تجري
--    بالزناد المستقل عن المسار، فمسار M084 القديم يبقى متسقًا أيضًا. نوع
--    الأمر مميّز (complete_booking_session) فلا يلتبس بأمر الإكمال القديم.
-- ---------------------------------------------------------------------

create function sync.begin_booking_completion_command(
  p_session_id uuid,
  p_ended_at timestamptz,
  p_fuel_quantity_ml bigint,
  p_fuel_measurement_type text,
  p_fuel_tank_id uuid,
  p_command_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_tenant_id uuid;
  v_well_id uuid;
  v_payload jsonb;
  v_guard jsonb;
  v_stored_type text;
  v_stored_payload jsonb;
  v_status text;
  v_response jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إكمال جلسة محجوزة';
  end if;
  if p_command_id is null then
    raise exception 'معرّف العملية مطلوب';
  end if;

  -- عضوية السلسلة: الجلسة هي الجلسة الجارية لسلسلة فعّالة، مع تعيين نشط.
  select w.tenant_id, s.well_id
    into v_tenant_id, v_well_id
  from ops.irrigation_sessions s
  join core.wells w on w.id = s.well_id
  where s.id = p_session_id
    and exists (
      select 1 from ops.booking_transition_chains c
      where c.current_session_id = s.id and c.status <> 'ended'
    )
    and exists (
      select 1 from core.well_assignments wa
      where wa.well_id = s.well_id
        and wa.profile_id = v_actor
        and wa.status = 'active'
    );
  if v_tenant_id is null then
    raise exception 'الجلسة ليست جلسة سلسلة جارية أو لا تملك وصولًا إليها';
  end if;
  if not iam.has_well_permission(v_well_id, 'session.complete') then
    raise exception 'لا تملك صلاحية إكمال جلسة على هذا البئر';
  end if;

  v_payload := jsonb_build_object(
    'booking_execution_contract_version', 113,
    'session_id', p_session_id,
    'ended_at', p_ended_at,
    'fuel_quantity_ml', p_fuel_quantity_ml,
    'fuel_measurement_type', p_fuel_measurement_type,
    'fuel_tank_id', p_fuel_tank_id
  );

  v_guard := sync.begin_command(
    v_tenant_id, p_command_id, 'complete_booking_session',
    v_payload, p_session_id
  );

  if not coalesce((v_guard ->> 'duplicate')::boolean, false) then
    return jsonb_build_object('duplicate', false, 'well_id', v_well_id);
  end if;

  select pc.command_type, pc.request_payload, pc.status, pc.response_payload
  into v_stored_type, v_stored_payload, v_status, v_response
  from sync.processed_commands pc
  where pc.tenant_id = v_tenant_id and pc.command_id = p_command_id;

  if not found
     or v_stored_type is distinct from 'complete_booking_session'
     or v_stored_payload is distinct from v_payload then
    raise exception 'معرّف العملية مستخدم لمحتوى مختلف';
  end if;

  return jsonb_build_object(
    'duplicate', true, 'well_id', v_well_id,
    'status', v_status, 'response', v_response
  );
end;
$function$;

revoke all on function sync.begin_booking_completion_command(
  uuid, timestamptz, bigint, text, uuid, uuid
) from public, anon, authenticated, service_role;
grant execute on function sync.begin_booking_completion_command(
  uuid, timestamptz, bigint, text, uuid, uuid
) to authenticated, service_role;

create function api.complete_booking_session(
  p_session_id uuid,
  p_ended_at timestamptz,
  p_command_id uuid,
  p_fuel_quantity_ml bigint default null,
  p_fuel_measurement_type text default null,
  p_fuel_tank_id uuid default null
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
  v_well_id uuid;
begin
  if p_ended_at is null then
    raise exception 'زمن الإكمال الفعلي مطلوب';
  end if;
  -- حارس المستقبل (نظير M113-T): لا يُنسب إكمال إلى زمن لم يقع بعد خادميًا.
  if p_ended_at > clock_timestamp() then
    raise exception 'زمن الإكمال الفعلي لا يكون في المستقبل'
      using errcode = '22023';
  end if;

  v_guard := sync.begin_booking_completion_command(
    p_session_id, p_ended_at, p_fuel_quantity_ml,
    p_fuel_measurement_type, p_fuel_tank_id, p_command_id
  );
  v_well_id := (v_guard ->> 'well_id')::uuid;

  if coalesce((v_guard ->> 'duplicate')::boolean, false) then
    if v_guard ->> 'status' = 'accepted' then
      return v_guard -> 'response';
    end if;
    raise exception 'العملية نفسها قيد المعالجة أو تحتاج مراجعة';
  end if;

  -- المحاسبة كاملةً من العقد القائم (لا تكرار خوارزمية ولا صف رسوم ثانٍ)؛
  -- ومصالحة السلسلة تجري بالزناد عند إغلاق الجلسة في هذا الاستدعاء.
  v_result := ops.complete_irrigation_session(
    p_session_id, p_ended_at, p_fuel_quantity_ml,
    p_fuel_measurement_type, p_fuel_tank_id
  );

  perform sync.finish_well_command(
    v_well_id, p_command_id, 'accepted', v_result
  );

  return v_result;
end;
$function$;

comment on function api.complete_booking_session(
  uuid, timestamptz, uuid, bigint, text, uuid
) is
  'ق-132 / E2-c1: المرحلة الأولى — إكمال جلسة سلسلة محجوزة محاسبيًا (يفوّض ops.complete_irrigation_session) مع حارس المستقبل على ended_at وعضوية السلسلة وإيديمبوتنس؛ مصالحة الحالة بالزناد. SECURITY INVOKER + session.complete.';

revoke all on function api.complete_booking_session(
  uuid, timestamptz, uuid, bigint, text, uuid
) from public, anon, authenticated, service_role;
grant execute on function api.complete_booking_session(
  uuid, timestamptz, uuid, bigint, text, uuid
) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- P) M113-E2-c2-b — تنفيذ قرار التشغيل الفوري المحفوظ (pending_start).
--
--    يحوّل قرار run_now المحفوظ إلى جلسة فعلية واحدة فقط بعد تحقق حاكم:
--    السلسلة pending_start، آخر قرار run_now، مقارنة-وتبديل على
--    decision_revision (لا يتجاوزه قرار أحدث)، وحجز تالٍ محدَّد. ثم يعيد
--    استخدام نواة البدء القائمة (start_booking_session_core, علم تنفيذ=true)
--    بزمن الخادم الفعلي — لا تكرار خوارزمية إنشاء الجلسة، ولا إعادة إكمال
--    السابقة، ولا تسوية ثانية. ليست جولة مؤقت/تشغيل تلقائي.
-- ---------------------------------------------------------------------

create function ops.execute_pending_booking_start(
  p_chain_id uuid,
  p_expected_revision bigint,
  p_actor uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_chain ops.booking_transition_chains%rowtype;
  v_result jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل تنفيذ قرار التشغيل';
  end if;
  if p_actor is distinct from v_actor then
    raise exception 'معرف المستخدم يجب أن يطابق المسجل حاليًا';
  end if;

  -- قفل السلسلة أولًا (ترتيب chain → booking → pump الموحّد).
  select c.* into v_chain
  from ops.booking_transition_chains c
  where c.id = p_chain_id
  for update;
  if not found then
    raise exception 'سلسلة الانتقال غير موجودة';
  end if;
  if not iam.has_well_permission(v_chain.well_id, 'session.start') then
    raise exception 'لا تملك صلاحية تنفيذ تشغيل على هذا البئر'
      using errcode = '42501';
  end if;
  -- لا يُعتمد pending_start وحدها: نثبت قرار run_now نافذًا ونسخته.
  if v_chain.status <> 'pending_start' then
    raise exception 'لا يوجد قرار تشغيل فوري نافذ للتنفيذ (الحالة %)',
      v_chain.status
      using errcode = '22023';
  end if;
  if v_chain.last_decision is distinct from 'run_now' then
    raise exception 'آخر قرار ليس run_now'
      using errcode = '22023';
  end if;
  if p_expected_revision is distinct from v_chain.decision_revision then
    raise exception 'نسخة قرار قديمة؛ تجاوزها قرار أحدث (المتوقع % الحالي %)',
      p_expected_revision, v_chain.decision_revision
      using errcode = '40001';
  end if;
  if v_chain.next_booking_id is null then
    raise exception 'قرار التشغيل بلا حجز تالٍ محدَّد';
  end if;

  -- التنفيذ: يعيد استخدام نواة البدء القائمة بعلم تنفيذ=true (المسار الوحيد
  -- الذي يبدأ pending_start لحجزه المحدَّد، بعد CAS أعلاه)، فيبدأ الجلسة بزمن
  -- الخادم الفعلي ويحوّل السلسلة إلى active ويحدّث current_session_id ذريًا.
  -- فشل أي حارس بدء يُرجِع كل شيء ذريًا (لا جلسة يتيمة، والسلسلة تبقى
  -- pending_start وقرارها التاريخي سليم).
  v_result := ops.start_booking_session_core(
    v_chain.next_booking_id,
    v_actor,
    clock_timestamp(),
    null,
    true
  );

  return jsonb_build_object(
    'contract', 'execute_pending_booking_start',
    'version', 1,
    'chain_id', p_chain_id,
    'well_id', v_chain.well_id,
    'executed_booking_id', v_chain.next_booking_id,
    'decision_revision', v_chain.decision_revision,
    'start', v_result
  );
end;
$function$;

revoke all on function ops.execute_pending_booking_start(uuid, bigint, uuid)
  from public, anon, authenticated, service_role;
grant execute on function ops.execute_pending_booking_start(uuid, bigint, uuid)
  to authenticated, service_role;

create function sync.begin_booking_execution_command(
  p_chain_id uuid,
  p_expected_revision bigint,
  p_command_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_tenant_id uuid;
  v_well_id uuid;
  v_payload jsonb;
  v_guard jsonb;
  v_stored_type text;
  v_stored_payload jsonb;
  v_status text;
  v_response jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل تنفيذ قرار التشغيل';
  end if;
  if p_command_id is null then
    raise exception 'معرّف العملية مطلوب';
  end if;

  select w.tenant_id, c.well_id
    into v_tenant_id, v_well_id
  from ops.booking_transition_chains c
  join core.wells w on w.id = c.well_id
  where c.id = p_chain_id
    and c.status <> 'ended'
    and exists (
      select 1 from core.well_assignments wa
      where wa.well_id = c.well_id
        and wa.profile_id = v_actor
        and wa.status = 'active'
    );
  if v_tenant_id is null then
    raise exception 'سلسلة الانتقال غير موجودة أو منتهية أو لا تملك وصولًا إليها';
  end if;
  if not iam.has_well_permission(v_well_id, 'session.start') then
    raise exception 'لا تملك صلاحية تنفيذ تشغيل على هذا البئر';
  end if;

  -- النسخة المتوقعة جزء من البصمة: إعادة بنفس المعرّف والنسخة تعيد المخزَّن،
  -- واختلاف النسخة لنفس المعرّف = حمولة مختلفة (طلب تشغيل قديم بعد تغيّر النسخة).
  v_payload := jsonb_build_object(
    'booking_execution_contract_version', 113,
    'chain_id', p_chain_id,
    'expected_revision', p_expected_revision
  );

  v_guard := sync.begin_command(
    v_tenant_id, p_command_id, 'execute_pending_booking_start',
    v_payload, p_chain_id
  );

  if not coalesce((v_guard ->> 'duplicate')::boolean, false) then
    return jsonb_build_object('duplicate', false, 'well_id', v_well_id);
  end if;

  select pc.command_type, pc.request_payload, pc.status, pc.response_payload
  into v_stored_type, v_stored_payload, v_status, v_response
  from sync.processed_commands pc
  where pc.tenant_id = v_tenant_id and pc.command_id = p_command_id;

  if not found
     or v_stored_type is distinct from 'execute_pending_booking_start'
     or v_stored_payload is distinct from v_payload then
    raise exception 'معرّف العملية مستخدم لمحتوى مختلف';
  end if;

  return jsonb_build_object(
    'duplicate', true, 'well_id', v_well_id,
    'status', v_status, 'response', v_response
  );
end;
$function$;

revoke all on function sync.begin_booking_execution_command(uuid, bigint, uuid)
  from public, anon, authenticated, service_role;
grant execute on function sync.begin_booking_execution_command(uuid, bigint, uuid)
  to authenticated, service_role;

create function api.execute_pending_booking_start(
  p_chain_id uuid,
  p_expected_revision bigint,
  p_command_id uuid
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
  v_well_id uuid;
begin
  v_guard := sync.begin_booking_execution_command(
    p_chain_id, p_expected_revision, p_command_id
  );
  v_well_id := (v_guard ->> 'well_id')::uuid;

  if coalesce((v_guard ->> 'duplicate')::boolean, false) then
    if v_guard ->> 'status' = 'accepted' then
      return v_guard -> 'response';
    end if;
    raise exception 'العملية نفسها قيد المعالجة أو تحتاج مراجعة';
  end if;

  v_result := ops.execute_pending_booking_start(
    p_chain_id, p_expected_revision, auth.uid()
  );

  perform sync.finish_well_command(
    v_well_id, p_command_id, 'accepted', v_result
  );

  return v_result;
end;
$function$;

comment on function api.execute_pending_booking_start(uuid, bigint, uuid) is
  'ق-132 / E2-c2-b: تنفيذ قرار run_now المحفوظ (pending_start) — تحقق حاكم بمقارنة-وتبديل على decision_revision ثم إعادة استخدام عقد البدء بزمن الخادم؛ جلسة واحدة إيديمبوتنت بلا إعادة تسوية. SECURITY INVOKER + session.start.';

revoke all on function api.execute_pending_booking_start(uuid, bigint, uuid)
  from public, anon, authenticated, service_role;
grant execute on function api.execute_pending_booking_start(uuid, bigint, uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------
-- Q) M113-E2-e-b2 — قاعدة المدة المشروطة للجلسة الحرّة (ق-132/750).
--    زناد قيد مؤجَّل: نقطة إنفاذ شاملة تُنفَّذ عند COMMIT، تعيد قراءة الصف
--    بـ id (لا تثق NEW الذي التُقِط وقت الإدراج بـ booking_id=null)، فترى
--    booking_id النهائي وتميّز المحجوزة (معفاة) عن الحرّة. يغطّي كل مسارات
--    الإدراج بما فيها العقد المختوم القديم. لا يُغلق جلسة ولا يختلق زمنًا.
-- ---------------------------------------------------------------------
create function ops.enforce_adhoc_duration_vs_next_booking()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_booking_id uuid;
  v_started_at timestamptz;
  v_planned_end_at timestamptz;
  v_well_id uuid;
  v_next_start timestamptz;
begin
  select s.booking_id, s.started_at, s.planned_end_at, s.well_id
    into v_booking_id, v_started_at, v_planned_end_at, v_well_id
  from ops.irrigation_sessions s
  where s.id = new.id;
  if not found or v_booking_id is not null then
    return null;  -- حُذف الصف، أو جلسة محجوزة نهايتها من الحجز (معفاة).
  end if;
  -- الحجز المانع: أبكر مؤكّد غير مستهلك لم ينتهِ موعده مقابل بداية الجلسة.
  -- يغطّي القادم (scheduled_start > started) والمستحق معًا: المستحق يُرفَض
  -- حتمًا لأنّ planned_end > started_at >= scheduled_start.
  select b.scheduled_start into v_next_start
  from ops.irrigation_bookings b
  where b.well_id = v_well_id and b.status = 'confirmed'
    and b.scheduled_end > v_started_at
    and not exists (select 1 from ops.irrigation_sessions s2 where s2.booking_id = b.id)
  order by b.scheduled_start asc, b.priority desc, b.public_code asc
  limit 1;
  if not found then
    return null;  -- لا حجز قادم: بدء حرّ بلا مدة مقبول.
  end if;
  if v_planned_end_at is null then
    raise exception 'بدء السقي الحر يتطلّب مدة مخطّطة لوجود حجز مؤكّد قادم على البئر'
      using errcode = '23514';
  end if;
  if v_planned_end_at > v_next_start then
    raise exception 'المدة المخطّطة تتجاوز بداية الحجز القادم؛ لا تقصير صامت'
      using errcode = '23514';
  end if;
  return null;
end;
$function$;
revoke all on function ops.enforce_adhoc_duration_vs_next_booking()
  from public, anon, authenticated, service_role;

create constraint trigger irrigation_sessions_adhoc_duration_guard
after insert on ops.irrigation_sessions
deferrable initially deferred
for each row
execute function ops.enforce_adhoc_duration_vs_next_booking();
-- عقد البدء الحرّ بمدة مخطّطة (ق-132/750). يعيد استخدام عقد الإدراج المختوم
-- (المحاسبة/المقاطع/المحاصيل بلا تكرار) ثم يضبط المدة/النهاية المخطّطة من
-- البداية الفعلية في المعاملة ذاتها — كما يربط المسار المحجوز booking_id.
-- القاعدة تُنفَّذ مؤجَّلًا عند COMMIT عبر زناد القيد (لا بوليان ثقة ولا GUC).
create function ops.start_adhoc_session(
  p_well_id uuid,
  p_pump_id uuid,
  p_farm_id uuid,
  p_farmer_well_account_id uuid,
  p_energy_source text,
  p_planned_duration_minutes integer,
  p_started_at timestamptz default clock_timestamp(),
  p_fuel_owner_person_id uuid default null,
  p_crops text[] default null
)
returns uuid
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_session_id uuid;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل بدء جلسة سقي';
  end if;
  if p_planned_duration_minutes is not null and p_planned_duration_minutes <= 0 then
    raise exception 'المدة المخطّطة يجب أن تكون دقائق موجبة' using errcode = '22023';
  end if;

  v_session_id := ops.start_irrigation_session(
    p_well_id, p_pump_id, p_farm_id, p_farmer_well_account_id,
    v_actor, p_energy_source, p_started_at, p_fuel_owner_person_id, p_crops
  );

  if p_planned_duration_minutes is not null then
    update ops.irrigation_sessions
    set planned_duration_minutes = p_planned_duration_minutes,
        planned_end_at = started_at + make_interval(mins => p_planned_duration_minutes)
    where id = v_session_id;
  end if;

  return v_session_id;
end;
$function$;

revoke all on function ops.start_adhoc_session(
  uuid, uuid, uuid, uuid, text, integer, timestamptz, uuid, text[]
) from public, anon, authenticated, service_role;
grant execute on function ops.start_adhoc_session(
  uuid, uuid, uuid, uuid, text, integer, timestamptz, uuid, text[]
) to authenticated, service_role;
-- حارس أمر إيديمبوتنت للبدء الحرّ بمدة (ق-114): يحل الجهة من البئر ويقارن
-- البصمة (تشمل المدة) داخل sync؛ لا يكشف الحمولة المخزّنة للعميل.
create function sync.begin_adhoc_session_command(
  p_well_id uuid,
  p_pump_id uuid,
  p_farm_id uuid,
  p_farmer_well_account_id uuid,
  p_energy_source text,
  p_planned_duration_minutes integer,
  p_started_at timestamptz,
  p_command_id uuid,
  p_crops text[],
  p_fuel_owner_person_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_tenant_id uuid;
  v_payload jsonb;
  v_guard jsonb;
  v_stored_type text;
  v_stored_payload jsonb;
  v_status text;
  v_response jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل بدء جلسة سقي';
  end if;
  if p_command_id is null then
    raise exception 'معرّف العملية مطلوب';
  end if;
  if p_started_at is null then
    raise exception 'زمن البداية الفعلي مطلوب';
  end if;

  select w.tenant_id into v_tenant_id
  from core.wells w
  where w.id = p_well_id
    and exists (
      select 1 from core.well_assignments wa
      where wa.well_id = p_well_id and wa.profile_id = v_actor
        and wa.status = 'active'
    );
  if v_tenant_id is null then
    raise exception 'البئر غير موجود أو لا تملك وصولًا إليه';
  end if;
  if not iam.has_well_permission(p_well_id, 'session.start') then
    raise exception 'لا تملك صلاحية بدء جلسة على هذا البئر';
  end if;
  v_payload := jsonb_build_object(
    'booking_execution_contract_version', 113,
    'well_id', p_well_id,
    'pump_id', p_pump_id,
    'farm_id', p_farm_id,
    'farmer_well_account_id', p_farmer_well_account_id,
    'energy_source', p_energy_source,
    'planned_duration_minutes', p_planned_duration_minutes,
    'started_at', p_started_at,
    'crops', to_jsonb(p_crops),
    'fuel_owner_person_id', p_fuel_owner_person_id
  );

  v_guard := sync.begin_command(
    v_tenant_id, p_command_id, 'start_adhoc_session', v_payload, p_well_id
  );

  if not coalesce((v_guard ->> 'duplicate')::boolean, false) then
    return jsonb_build_object('duplicate', false, 'tenant_id', v_tenant_id);
  end if;

  select pc.command_type, pc.request_payload, pc.status, pc.response_payload
  into v_stored_type, v_stored_payload, v_status, v_response
  from sync.processed_commands pc
  where pc.tenant_id = v_tenant_id and pc.command_id = p_command_id;

  if not found
     or v_stored_type is distinct from 'start_adhoc_session'
     or v_stored_payload is distinct from v_payload then
    raise exception 'معرّف العملية مستخدم لمحتوى مختلف';
  end if;

  return jsonb_build_object(
    'duplicate', true, 'tenant_id', v_tenant_id,
    'status', v_status, 'response', v_response
  );
end;
$function$;

revoke all on function sync.begin_adhoc_session_command(
  uuid, uuid, uuid, uuid, text, integer, timestamptz, uuid, text[], uuid
) from public, anon, authenticated, service_role;
grant execute on function sync.begin_adhoc_session_command(
  uuid, uuid, uuid, uuid, text, integer, timestamptz, uuid, text[], uuid
) to authenticated, service_role;
-- سطح البدء الحرّ بمدة — SECURITY INVOKER، إيديمبوتنت. command_id اختياري
-- (توافق مع نمط M105). الإنفاذ المؤجَّل يقع عند COMMIT عبر زناد القيد؛ فشل
-- القاعدة يُرجِع المعاملة كاملةً بما فيها حجز الأمر، فتبقى إعادة المحاولة آمنة.
create function api.start_adhoc_session(
  p_well_id uuid,
  p_pump_id uuid,
  p_farm_id uuid,
  p_farmer_well_account_id uuid,
  p_energy_source text,
  p_planned_duration_minutes integer,
  p_started_at timestamptz default clock_timestamp(),
  p_fuel_owner_person_id uuid default null,
  p_command_id uuid default null,
  p_crops text[] default null
)
returns uuid
language plpgsql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_guard jsonb;
  v_session_id uuid;
begin
  if p_command_id is not null then
    v_guard := sync.begin_adhoc_session_command(
      p_well_id, p_pump_id, p_farm_id, p_farmer_well_account_id,
      p_energy_source, p_planned_duration_minutes, p_started_at,
      p_command_id, p_crops, p_fuel_owner_person_id
    );
    if coalesce((v_guard ->> 'duplicate')::boolean, false) then
      if v_guard ->> 'status' = 'accepted' then
        return (v_guard -> 'response' ->> 'id')::uuid;
      end if;
      raise exception 'العملية نفسها قيد المعالجة أو تحتاج مراجعة';
    end if;
  end if;

  v_session_id := ops.start_adhoc_session(
    p_well_id, p_pump_id, p_farm_id, p_farmer_well_account_id,
    p_energy_source, p_planned_duration_minutes, p_started_at,
    p_fuel_owner_person_id, p_crops
  );

  if p_command_id is not null then
    perform sync.finish_well_command(
      p_well_id, p_command_id, 'accepted',
      jsonb_build_object('id', v_session_id)
    );
  end if;

  return v_session_id;
end;
$function$;

comment on function api.start_adhoc_session(
  uuid, uuid, uuid, uuid, text, integer, timestamptz, uuid, uuid, text[]
) is
  'ق-132/750 / E2-e-b2: بدء سقي حرّ بمدة مخطّطة اختيارية. SECURITY INVOKER + session.start؛ الإنفاذ (المدة لازمة عند وجود حجز قادم، والنهاية لا تتجاوزه) يقع مؤجَّلًا عند COMMIT عبر زناد القيد الشامل.';

revoke all on function api.start_adhoc_session(
  uuid, uuid, uuid, uuid, text, integer, timestamptz, uuid, uuid, text[]
) from public, anon, authenticated, service_role;
grant execute on function api.start_adhoc_session(
  uuid, uuid, uuid, uuid, text, integer, timestamptz, uuid, uuid, text[]
) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- P) P1-A — ق-134 §1/§5: إعداد تشغيل/إيقاف الانتقال الآلي لكل بئر.
--
--    نطاق هذا القسم حصرًا: حفظ الإعداد وقراءته وتغييره بعقد API
--    إيديمبوتنت. لا ينفّذ أي انتقال ولا إغلاقًا محاسبيًا ولا بدء حجز،
--    ولا يمسّ ops.booking_transition_chains إطلاقًا: إيقاف الوضع وسط
--    جلسة لا يقطعها (ق-134 §1)، وتفعيله ليس أذنًا بأثر رجعي ولا يعرض
--    نجاح انتقال لم يُنفَّذ.
--    الإعداد في core.well_settings القائمة (لا مخزن موازٍ)، وافتراضه
--    false بمراجعة 0 لكل الآبار القائمة والجديدة — لا تفعيل تلقائي.
--    الصلاحية (مراجعة المهندس الرئيسي): التحكم للمشغل المخوّل حصرًا —
--    الصلاحية الحاكمة session.start (سلطة قرارات الانتقال نفسها في
--    E2-b) + حيازة دور المشغل على البئر في well_assignments. مالك
--    البئر يراقب ولا يتحكم عن بُعد قبل استكمال ضوابط هاتف المشغّل في
--    ق-134 §5 — مساره المؤجَّل إلى P7 لا يُفتح هنا. القراءة للمالك
--    والمشغل (مراقبة) دون تغيير.
--    الأمان (توفيق عقد 073 مع إغلاق دورة الأمر): أغلفة api SECURITY
--    INVOKER حصرًا — لا دالة DEFINER داخل api إطلاقًا. العمليات
--    المميزة داخل عملية داخلية واحدة SECURITY DEFINER ممنوحة EXECUTE،
--    تنفّذ دورة الأمر كاملة ذريًا: هوية وتفويض (session.start +
--    حيازة المشغل)، بصمة حمولة، تسجيل الأمر، مقارنة المراجعة تحت قفل
--    الصف، الكتابة، وإثبات الرد — فشل أي خطوة يتراجع عن التسجيل نفسه.
--    الاستدعاء المباشر يطبّق العقد كاملًا فلا باب خلفي ولا مسار حجز
--    معرّفات منفرد، والكتابة بصف مالك الجدول فتنجح للمشغل المخوّل رغم
--    حجب المنح العمودي على العمودين المحميين.
--    التزامن: مراجعة تصاعدية مستقلة booking_auto_transition_revision
--    تُقارن ذريًا تحت قفل الصف وترفع 1 عند كل تغيير مقبول (وأول إنشاء
--    لصف مفقود يبدأ من 1 لا 0) — لا updated_at/now() كرقم نسخة لأنها
--    ثابتة داخل المعاملة الواحدة فتسمح لأمر قديم بتجاوز تعديلين وقعا
--    داخلها؛ updated_at يُحدَّث للعرض عند القبول فقط. الكتابة المباشرة
--    للعمودين المحميين مغلقة حتى بيد المالك بسحب منح الجدول الكامل
--    وإعادة منح أعمدة التنبيهات القديمة وحدها (P1-A.0).
-- ---------------------------------------------------------------------

alter table core.well_settings
  add column booking_auto_transition_enabled boolean not null default false;

alter table core.well_settings
  add column booking_auto_transition_revision bigint not null default 0;

comment on column core.well_settings.booking_auto_transition_enabled is
  'ق-134 §1 / P1-A: وضع الانتقال التلقائي المتتابع لحجوزات البئر. الافتراض false ولا يُفعَّل تلقائيًا. حفظه ليس تنفيذ انتقال: أول جلسة تبدأ يدويًا والتنفيذ عبر منفّذ الانتقال لاحقًا وحده.';

comment on column core.well_settings.booking_auto_transition_revision is
  'ق-134 / P1-A: مراجعة تصاعدية مستقلة لإعداد الانتقال الآلي — تُقارن ذريًا تحت قفل الصف وترفع 1 عند كل تغيير مقبول (وأول إنشاء لصف مفقود يبدأ من 1)؛ أساس رفض الأوامر المؤجَّلة القديمة حتى لو وقعت التعديلات داخل المعاملة نفسها. لا يُستعمل updated_at رقمًا للنسخة.';

-- P1-A.0) إغلاق الكتابة المباشرة على العمودين المحميين حتى بيد المالك
--   (مراجعة ثانية): 017 منحت insert, update, delete على كل جداول core
--   لـauthenticated، وسياسة تحديث المالك فيها تسمح له بتحديث صف إعدادات
--   بئره — فبقي العمودان مكشوفَين لكتابة مباشرة بتجاوز api. السحب
--   وإعادة المنح على أعمدة التنبيهات القديمة (وأثرها الزمني) وحدها
--   يحفظ سلوك تعديل التنبيهات القائم ويجعل العمودين المحميين بلا أي
--   منح كتابة لأي دور تطبيق — حماية من نظام امتيازات الخادم نفسه لا
--   يستطيع authenticated تجاوزها، وأغلفة api الجديدة SECURITY INVOKER
--   والعملية الداخلية الموثوقة في ops SECURITY DEFINER بمالكها فلا
--   يتأثر مسارها بالسحب.
revoke insert, update on core.well_settings from authenticated;

grant insert (well_id, long_session_alert_minutes, session_ending_alert_minutes)
  on core.well_settings to authenticated;

grant update (long_session_alert_minutes, session_ending_alert_minutes, updated_at)
  on core.well_settings to authenticated;

-- P1-A.1) القراءة: عقد واضح يفصل «الإعداد المحفوظ» عن «حالة التنفيذ»
--   وعن «جاهزية المنفّذ». SECURITY INVOKER (عقد 073: لا DEFINER داخل
--   api) بفحص دور صريح مطابق تمامًا لسياسة قراءة well_settings
--   (مالك/مشغل) — تطابق الحرس مع سياسة RLS يمنع التباس صفٍّ مفقود
--   مع صفٍّ محجوب فلا false كاذب (ق-113). حالة السلسلة تُقرأ عبر RLS
--   (booking.read) من ops.booking_transition_chains الفعلية لا من
--   الإعداد.
create function api.get_well_booking_automation(
  p_well_id uuid
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_enabled boolean;
  v_revision bigint;
  v_updated_at timestamptz;
  v_row_exists boolean;
  v_chain ops.booking_transition_chains%rowtype;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة إعداد الانتقال الآلي';
  end if;
  -- حرس القراءة عبر المسار الكنوني: تعيين نشط للمستدعي على البئر
  --   يقابله في خريطة أدوار التعيين رمز الدور الكنوني tenant_owner
  --   (المالك) أو operator (المشغل) في iam.roles — نفس نافذة سياسة
  --   قراءة well_settings دون مصفوفات الأدوار النصية القديمة.
  if not exists (
    select 1
    from core.well_assignments wa
    join iam.well_assignment_role_map arm
      on arm.assignment_role = wa.role
    join iam.roles r
      on r.id = arm.role_id
    where wa.well_id = p_well_id
      and wa.profile_id = v_actor
      and wa.status = 'active'
      and r.code in ('tenant_owner', 'operator')
  ) then
    raise exception 'لا تملك صلاحية قراءة إعداد الانتقال الآلي على هذا البئر'
      using errcode = '42501';
  end if;

  select true,
         ws.booking_auto_transition_enabled,
         ws.booking_auto_transition_revision,
         ws.updated_at
    into v_row_exists, v_enabled, v_revision, v_updated_at
  from core.well_settings ws
  where ws.well_id = p_well_id;
  if not found then
    v_row_exists := false;
    v_enabled := false;
    v_revision := null;
  end if;

  select c.* into v_chain
  from ops.booking_transition_chains c
  where c.well_id = p_well_id
    and c.status <> 'ended'
  limit 1;

  return jsonb_build_object(
    'contract', 'get_well_booking_automation',
    'version', 1,
    'well_id', p_well_id,
    -- الإعداد المحفوظ ومراجعته: المراجعة وحدها تُرسل مع أمر التغيير.
    'booking_auto_transition_enabled', v_enabled,
    'booking_auto_transition_revision', v_revision,
    'settings_row_exists', v_row_exists,
    'settings_updated_at', v_updated_at,
    -- حالة التنفيذ الفعلية من سلسلة البئر (JSON null بلا أي سلسلة).
    'active_chain', case
      when v_chain.id is null then null
      else jsonb_build_object(
        'chain_id', v_chain.id,
        'status', v_chain.status,
        'next_booking_id', v_chain.next_booking_id,
        'decision_revision', v_chain.decision_revision
      )
    end,
    -- منفّذ الأتمتة غير جاهز حاليًا — ثابت false حتى تنفيذ منفّذ
    -- الانتقال في جولة لاحقة، مستقل كليًا عن كون الإعداد ON محفوظًا.
    'automation_executor_ready', false,
    -- بند 7 صراحةً: حفظ الإعداد بوضع التشغيل ليس نجاح تشغيل آلي.
    'auto_transition_executed', false,
    'first_session', 'manual'
  );
end;
$function$;

revoke all on function api.get_well_booking_automation(uuid)
  from public, anon, authenticated, service_role;
grant execute on function api.get_well_booking_automation(uuid)
  to authenticated, service_role;

-- P1-A.2) العملية الداخلية الموثوقة: دورة الأمر كاملة ذريًا داخل دالة
--   واحدة — حرس الهوية، حرس التفويض، بصمة الحمولة، تسجيل الأمر
--   (begin_command)، مقارنة المراجعة تحت قفل الصف، الكتابة، ثم إثبات
--   الرد النهائي (finish_command). الكل في معاملة واحدة: فشل أي خطوة
--   يتراجع عن التسجيل نفسه، فلا كتابة بلا أمر مقبول مسجَّل، ولا أمر
--   مسجَّل بلا رد، ولا حجز معرّفات معلّق يفسد أوامر صحيحة لاحقًا.
--   الاستدعاء المباشر يطبّق هذا العقد كاملًا فلا باب خلفي: لا مسار
--   تسجيل منفرد يبقى، ولا كتابة تسبق القبول، والرد المخزَّن هو وحده
--   ما يعاد عند إعادة الأمر المطابق ولو تقدّمت المراجعة.
create function ops.set_well_booking_automation(
  p_well_id uuid,
  p_enabled boolean,
  p_expected_revision bigint,
  p_actor uuid,
  p_command_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_tenant_id uuid;
  v_payload jsonb;
  v_guard jsonb;
  v_stored_type text;
  v_stored_payload jsonb;
  v_status text;
  v_response jsonb;
  v_revision bigint;
  v_result jsonb;
begin
  -- حرس الهوية: المستدعي الحقيقي من رمز JWT لا من وسيط.
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل تغيير إعداد الانتقال الآلي';
  end if;
  if p_actor is distinct from v_actor then
    raise exception 'معرف المستخدم يجب أن يطابق المسجل حاليًا';
  end if;
  if p_enabled is null then
    raise exception 'قيمة الانتقال الآلي مطلوبة (تشغيل أو إيقاف)';
  end if;
  if p_command_id is null then
    raise exception 'معرّف العملية مطلوب';
  end if;

  -- حرس التفويض (ق-134 §1/§5): المشغل المخوّل حصرًا — الصلاحية الحاكمة
  -- لقرارات الانتقال (session.start) عبر السلطة الكنونية، مع تعيين
  -- نشط للمستدعي يقابله في خريطة أدوار التعيين رمز الدور الكنوني
  -- operator في iam.roles (المالك برمز tenant_owner والمدير برمز
  -- well_manager فيحجبان رغم امتلاكهما session.start). مالك البئر
  -- يراقب ولا يتحكم عن بُعد قبل استكمال ضوابط هاتف المشغّل؛ مساره
  -- المؤجَّل إلى P7 لا يُفتح هنا.
  if not iam.has_well_permission(p_well_id, 'session.start')
     or not exists (
      select 1
      from core.well_assignments wa
      join iam.well_assignment_role_map arm
        on arm.assignment_role = wa.role
      join iam.roles r
        on r.id = arm.role_id
      where wa.well_id = p_well_id
        and wa.profile_id = v_actor
        and wa.status = 'active'
        and r.code = 'operator'
    ) then
    raise exception 'تغيير إعداد الانتقال الآلي قرار المشغل المخول على هاتف التشغيل؛ مسار المالك عن بعد مؤجل إلى P7'
      using errcode = '42501';
  end if;

  select w.tenant_id into v_tenant_id
  from core.wells w
  where w.id = p_well_id;
  if v_tenant_id is null then
    raise exception 'البئر غير موجود';
  end if;

  -- بصمة الحمولة: كل وسيط مؤثر جزء منها، وإعادة نفس المعرف ونفس
  -- الحمولة تعيد الرد المخزَّن حرفيًا بلا تنفيذ ثانٍ.
  v_payload := jsonb_build_object(
    'well_settings_contract_version', 113,
    'well_id', p_well_id,
    'enabled', p_enabled,
    'expected_revision', p_expected_revision
  );

  v_guard := sync.begin_command(
    v_tenant_id,
    p_command_id,
    'set_well_booking_automation',
    v_payload,
    p_well_id
  );

  if coalesce((v_guard ->> 'duplicate')::boolean, false) then
    select pc.command_type, pc.request_payload, pc.status, pc.response_payload
      into v_stored_type, v_stored_payload, v_status, v_response
    from sync.processed_commands pc
    where pc.tenant_id = v_tenant_id
      and pc.command_id = p_command_id;

    if not found
       or v_stored_type is distinct from 'set_well_booking_automation'
       or v_stored_payload is distinct from v_payload then
      raise exception 'معرّف العملية مستخدم لمحتوى مختلف';
    end if;
    if v_status <> 'accepted' then
      raise exception 'العملية نفسها قيد المعالجة أو تحتاج مراجعة';
    end if;
    return v_response;
  end if;

  -- مقارنة-التبديل تحت قفل الصف: أمر مؤجَّل قديم لا يتجاوز تعديلًا
  -- أحدث إطلاقًا، ولو وقعت التعديلات داخل المعاملة نفسها. بئر أُنشئ
  -- قبل 020 بلا صف إعدادات: يُنشأ الآن، والنسخة المتوقعة يجب أن تكون
  -- null، وأول تغيير مقبول يبدأ المراجعة من 1 لا 0.
  select ws.booking_auto_transition_revision into v_revision
  from core.well_settings ws
  where ws.well_id = p_well_id
  for update;

  if found then
    if p_expected_revision is null
       or p_expected_revision is distinct from v_revision then
      raise exception 'نسخة إعداد قديمة؛ أُعيد التقييم (المتوقع % الحالي %)',
        coalesce(p_expected_revision::text, 'null'), v_revision
        using errcode = '40001';
    end if;
    update core.well_settings
      set booking_auto_transition_enabled = p_enabled,
          booking_auto_transition_revision = booking_auto_transition_revision + 1,
          updated_at = now()
      where well_id = p_well_id
      returning booking_auto_transition_revision into v_revision;
  else
    if p_expected_revision is not null then
      raise exception 'لا يوجد صف إعدادات للبئر؛ النسخة المتوقعة غير صالحة'
        using errcode = '22023';
    end if;
    insert into core.well_settings
      (well_id, booking_auto_transition_enabled, booking_auto_transition_revision)
      values (p_well_id, p_enabled, 1)
      returning booking_auto_transition_revision into v_revision;
  end if;

  v_result := jsonb_build_object(
    'contract', 'set_well_booking_automation',
    'version', 1,
    'well_id', p_well_id,
    'booking_auto_transition_enabled', p_enabled,
    'booking_auto_transition_revision', v_revision,
    -- بند 7 صراحةً: الإعداد حُفظ، ولا انتقال نُفِّذ في هذه العملية.
    'setting_saved', true,
    'auto_transition_executed', false
  );

  -- إثبات الرد النهائي في نفس المعاملة: القبول بلا تسجيل مستحيل.
  perform sync.finish_command(v_tenant_id, p_command_id, 'accepted', v_result);

  return v_result;
end;
$function$;

comment on function ops.set_well_booking_automation(
  uuid, boolean, bigint, uuid, uuid
) is
  'ق-134 §1/§5 / P1-A: العملية الداخلية الموثوقة لإعداد الانتقال الآلي — تنفّذ دورة الأمر كاملة ذريًا: هوية وتفويض (المشغل المخول حصرًا، المالك مؤجل إلى P7)، بصمة حمولة، تسجيل ومنع تكرار عبر sync.begin_command، مقارنة-وتبديل على المراجعة التصاعدية تحت قفل الصف، كتابة، ثم إثبات الرد عبر sync.finish_command. SECURITY DEFINER ممنوحة EXECUTE وآمنة عند الاستدعاء المباشر لأن العقد كاملًا داخلها؛ الكتابة بصف مالك الجدول فتنجح رغم حجب المنح العمودي للعمودين.';

revoke all on function ops.set_well_booking_automation(
  uuid, boolean, bigint, uuid, uuid
) from public, anon, authenticated, service_role;
grant execute on function ops.set_well_booking_automation(
  uuid, boolean, bigint, uuid, uuid
) to authenticated, service_role;

-- P1-A.3) غلاف api: SECURITY INVOKER (عقد 073) بحرسَي الهوية
--   والتفويض، يفوّض دورة الأمر كاملةً إلى العملية الداخلية الموثوقة
--   ويعيد ردها — فلا تعتمد الحماية على الغلاف وحده ولا على الداخلية
--   وحدها.
create function api.set_well_booking_automation(
  p_well_id uuid,
  p_enabled boolean,
  p_expected_revision bigint,
  p_command_id uuid
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_result jsonb;
begin
  -- حرس الهوية: المستدعي الحقيقي من رمز JWT لا من وسيط.
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل تغيير إعداد الانتقال الآلي';
  end if;
  if p_enabled is null then
    raise exception 'قيمة الانتقال الآلي مطلوبة (تشغيل أو إيقاف)';
  end if;
  if p_command_id is null then
    raise exception 'معرّف العملية مطلوب';
  end if;

  -- حرس التفويض (ق-134 §1/§5): المشغل المخوّل حصرًا — الصلاحية الحاكمة
  -- لقرارات الانتقال (session.start) عبر السلطة الكنونية، مع تعيين
  -- نشط للمستدعي يقابله في خريطة أدوار التعيين رمز الدور الكنوني
  -- operator في iam.roles (المالك برمز tenant_owner والمدير برمز
  -- well_manager فيحجبان رغم امتلاكهما session.start). مالك البئر
  -- يراقب ولا يتحكم عن بُعد قبل استكمال ضوابط هاتف المشغّل؛ مساره
  -- المؤجَّل إلى P7 لا يُفتح هنا.
  if not iam.has_well_permission(p_well_id, 'session.start')
     or not exists (
      select 1
      from core.well_assignments wa
      join iam.well_assignment_role_map arm
        on arm.assignment_role = wa.role
      join iam.roles r
        on r.id = arm.role_id
      where wa.well_id = p_well_id
        and wa.profile_id = v_actor
        and wa.status = 'active'
        and r.code = 'operator'
    ) then
    raise exception 'تغيير إعداد الانتقال الآلي قرار المشغل المخول على هاتف التشغيل؛ مسار المالك عن بعد مؤجل إلى P7'
      using errcode = '42501';
  end if;

  v_result := ops.set_well_booking_automation(
    p_well_id,
    p_enabled,
    p_expected_revision,
    v_actor,
    p_command_id
  );

  return v_result;
end;
$function$;

comment on function api.set_well_booking_automation(
  uuid, boolean, bigint, uuid
) is
  'ق-134 §1/§5 / P1-A: حفظ وضع الانتقال الآلي لكل بئر — المشغل المخول حصرًا (session.start + حيازة المشغل)؛ مالك البئر يراقب ولا يتحكم عن بعد ومساره مؤجل إلى P7. SECURITY INVOKER (عقد 073) بحرسَي هوية وتفويض يفوّض إلى العملية الداخلية الموثوقة التي تنفّذ دورة الأمر كاملة ذريًا (بصمة، منع تكرار، مقارنة مراجعة، كتابة، إثبات رد). حفظ الإعداد لا ينفّذ أي انتقال ولا يمسّ السلسلة الجارية.';

revoke all on function api.set_well_booking_automation(
  uuid, boolean, bigint, uuid
) from public, anon, authenticated, service_role;
grant execute on function api.set_well_booking_automation(
  uuid, boolean, bigint, uuid
) to authenticated, service_role;
commit;
