create or replace function api.get_well_day_schedule(
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
  v_server_time timestamptz;
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

  v_server_time := statement_timestamp();
  return jsonb_build_object(
    'status', 'ok',
    'server_time', v_server_time,
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
  'ق-132 §ب: جدول اليوم للبئر، مع server_time read-only لمرساة زمن الهاتف المحلية.';

revoke all on function api.get_well_day_schedule(uuid, date)
  from public, anon, authenticated, service_role;
grant execute on function api.get_well_day_schedule(uuid, date)
  to authenticated, service_role;
