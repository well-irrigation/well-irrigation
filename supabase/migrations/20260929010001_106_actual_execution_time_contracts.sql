-- ق-131 البند 7 / م-45 المرحلة A: انتشار الزمن الفعلي في عقود القراءة.
--
-- القرار الحاكم (اعتماد المالك 2026-09-28):
--   1. الزمن الفعلي للتنفيذ هو مصدر المدة التشغيلية في السجل والتفصيل
--      والتقارير، لا أوقات الحجز المخططة ولا الزمن المفوتر.
--   2. actual_seconds (الفعلي) وbillable_seconds (المفوتر) كميتان
--      مستقلتان: لا يُعيد أحدهما تسمية للآخر ولا يُشتق أحدهما من الآخر
--      في العميل (ق-99).
--   3. المدة الفعلية على مستوى الجلسة المقفلة = مجموع actual_seconds
--      لمقاطعها كلها بما فيها مقاطع التوقف. والجلسة القديمة بلا مقاطع
--      تعود بالمغلف المخزَّن (ended_at - started_at) كما هو بلا تقريب.
--   4. الجلسة الجارية بلا مدة فعلية نهائية: المفتاح يعود null ولا
--      يُلفَّق من بيانات الفوترة (ق-37 / الثابت 713).
--   5. المال كما هو: billing.session_charges.duration_seconds يبقى
--      أساس الفوترة والإيراد، ولا تُمسّ صيغ المبلغ إطلاقًا.
--
-- النمط المتبع (نمط 105): إضافة مفاتيح بنفس التوقيع في عقود القراءة،
-- فالعميل القديم الذي لا يقرأ المفتاح الجديد لا يخسر شيئًا.

begin;

-- ==============================================================
-- 1. api.list_well_sessions — مدة فعلية على مستوى الجلسة
-- ==============================================================

create or replace function api.list_well_sessions(
  p_well_id uuid,
  p_farmer_well_account_id uuid default null,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_unpaid_only boolean default false,
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
  v_limit integer := least(greatest(coalesce(p_limit, 200), 1), 500);
  v_items jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة سجل الجلسات'
      using errcode = '28000';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  -- RLS على core.wells هي مصدر التفويض؛ البئر غير المرئي = رفض صريح.
  if not exists (
    select 1
    from core.wells w
    where w.id = p_well_id
  ) then
    raise exception 'لا توجد صلاحية على هذا البئر'
      using errcode = '42501';
  end if;

  select coalesce(
           jsonb_agg(x.item order by x.started_at desc, x.id),
           '[]'::jsonb
         )
  into v_items
  from (
    select
      s.id,
      s.started_at,
      jsonb_build_object(
        'id', s.id,
        'well_id', s.well_id,
        'status', s.status,
        'started_at', s.started_at,
        'ended_at', s.ended_at,
        'farmer_well_account_id', fwa.id,
        'farmer_public_code', fwa.public_code,
        'farmer_name', per.full_name,
        'farm_id', f.id,
        'farm_name', f.name,
        'pump_id', pm.id,
        'pump_name', pm.name,
        'operator_name', pr.full_name,
        'energy_source', run.energy_source,
        'actual_seconds', case
          -- الجارية بلا مدة فعلية نهائية: null لا تلفيق (ق-37).
          when s.ended_at is null then null
          -- المقفلة: مجموع مقاطعها كلها بما فيها التوقفات (ق-131 البند 7)،
          -- والقديمة بلا مقاطع تغلفها المخزَّن ended_at - started_at.
          when seg.segment_count > 0
            and seg.segments_actual_seconds is not null
            then seg.segments_actual_seconds
          else extract(epoch from (s.ended_at - s.started_at))::bigint
        end,
        'billable_seconds', sc.duration_seconds,
        'total_amount_minor', sc.amount_minor,
        'paid_amount_minor', pay.paid_minor,
        'payment_status', case
          when sc.id is null then 'not_billed'
          when coalesce(pay.paid_minor, 0) >= sc.amount_minor
            and sc.amount_minor > 0 then 'settled'
          when coalesce(pay.paid_minor, 0) > 0 then 'partial'
          else 'unpaid'
        end,
        'has_charge', sc.id is not null,
        'has_invoice', inv.id is not null
      ) as item
    from ops.irrigation_sessions s
    -- كل الانضمامات التالية تزويقية (اسم/رمز) والمصدر الحاكم للتفويض هو
    -- RLS على الجلسة نفسها؛ لذلك LEFT JOIN إجباري: صف تزويق محجوب أو
    -- غير معيّن يجب ألا يُخفي جلسة مرئية.
    left join ops.farms f on f.id = s.farm_id
    left join ops.farmer_well_accounts fwa
      on fwa.id = coalesce(s.farmer_well_account_id, f.farmer_well_account_id)
    left join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
    left join core.persons per on per.id = fp.person_id
    left join core.pumps pm on pm.id = s.pump_id
    left join iam.profiles pr on pr.id = s.operator_profile_id
    left join billing.session_charges sc on sc.session_id = s.id
    left join billing.invoices inv on inv.session_id = s.id
    left join lateral (
      select ss.energy_source
      from ops.session_segments ss
      where ss.session_id = s.id
        and ss.energy_source is not null
      order by ss.sequence_number
      limit 1
    ) run on true
    left join lateral (
      select
        count(*) as segment_count,
        sum(ss.actual_seconds)::bigint as segments_actual_seconds
      from ops.session_segments ss
      where ss.session_id = s.id
    ) seg on true
    left join lateral (
      -- المدفوع = ما خُزّن في الفاتورة إن وُجدت، وإلا مجموع الدفعات
      -- المرحّلة على تكلفة الجلسة. لا Netting ضمني ولا تقدير.
      select case
        when inv.id is not null then inv.paid_minor
        else (
          select coalesce(sum(p.amount_minor), 0)
          from billing.payments p
          where p.session_charge_id = sc.id
            and p.status = 'posted'
        )
      end as paid_minor
    ) pay on sc.id is not null
    where s.well_id = p_well_id
      and (
        p_farmer_well_account_id is null
        or fwa.id = p_farmer_well_account_id
      )
      and (p_from is null or s.started_at >= p_from)
      and (p_to is null or s.started_at < p_to)
      and (
        coalesce(p_unpaid_only, false) is not true
        or sc.id is null
        or coalesce(pay.paid_minor, 0) < sc.amount_minor
      )
    order by s.started_at desc, s.id
    limit v_limit
  ) x;

  return jsonb_build_object(
    'contract', 'list_well_sessions',
    'version', 1,
    'items', v_items
  );
end;
$function$;

revoke all on function api.list_well_sessions(
  uuid, uuid, timestamptz, timestamptz, boolean, integer
) from public, anon, authenticated, service_role;

grant execute on function api.list_well_sessions(
  uuid, uuid, timestamptz, timestamptz, boolean, integer
) to authenticated, service_role;

comment on function api.list_well_sessions(
  uuid, uuid, timestamptz, timestamptz, boolean, integer
) is
  'عقد سجل الجلسات (090/106). actual_seconds = مجموع actual_seconds لمقاطع الجلسة المقفلة بما فيها التوقفات (ق-131 البند 7)، والقديمة بلا مقاطع بمغلفها المخزَّن، والجارية null. billable_seconds يبقى أساس الفوترة كما خُزّن.';

-- ==============================================================
-- 2. api.get_session_detail — المدّة الفعلية مع الجلسة ومقاطعها
--    (نمط 105: إضافة جمعية بنفس التوقيع، والعميل القديم لا يقرأ
--    المفتاح الجديد لا يخسر شيئًا)
-- ==============================================================

create or replace function api.get_session_detail(
  p_session_id uuid
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_session jsonb;
  v_segments jsonb;
  v_payment jsonb;
  v_crops jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة تفصيل الجلسة'
      using errcode = '28000';
  end if;

  if p_session_id is null then
    raise exception 'معرّف الجلسة مطلوب'
      using errcode = '22023';
  end if;

  select
    jsonb_build_object(
      'id', s.id,
      'well_id', s.well_id,
      'status', s.status,
      'started_at', s.started_at,
      'ended_at', s.ended_at,
      'farmer_well_account_id', fwa.id,
      'farmer_public_code', fwa.public_code,
      'farmer_name', per.full_name,
      'farm_id', f.id,
      'farm_name', f.name,
      'pump_id', pm.id,
      'pump_name', pm.name,
      'operator_name', pr.full_name,
      'energy_source', run.energy_source,
      'actual_seconds', case
        when s.ended_at is null then null
        when seg.segment_count > 0
          and seg.segments_actual_seconds is not null
          then seg.segments_actual_seconds
        else extract(epoch from (s.ended_at - s.started_at))::bigint
      end,
      'billable_seconds', sc.duration_seconds,
      'total_amount_minor', sc.amount_minor,
      'paid_amount_minor', pay.paid_minor,
      'payment_status', case
        when sc.id is null then 'not_billed'
        when coalesce(pay.paid_minor, 0) >= sc.amount_minor
          and sc.amount_minor > 0 then 'settled'
        when coalesce(pay.paid_minor, 0) > 0 then 'partial'
        else 'unpaid'
      end,
      'has_charge', sc.id is not null,
      'has_invoice', inv.id is not null
    ),
    case
      when last_pay.id is null then null
      else jsonb_build_object(
        'method', last_pay.method,
        'reference', last_pay.public_code,
        'paid_at', last_pay.paid_at
      )
    end
  into v_session, v_payment
  from ops.irrigation_sessions s
  left join ops.farms f on f.id = s.farm_id
  left join ops.farmer_well_accounts fwa
    on fwa.id = coalesce(s.farmer_well_account_id, f.farmer_well_account_id)
  left join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
  left join core.persons per on per.id = fp.person_id
  left join core.pumps pm on pm.id = s.pump_id
  left join iam.profiles pr on pr.id = s.operator_profile_id
  left join billing.session_charges sc on sc.session_id = s.id
  left join billing.invoices inv on inv.session_id = s.id
  left join lateral (
    select ss.energy_source
    from ops.session_segments ss
    where ss.session_id = s.id
      and ss.energy_source is not null
    order by ss.sequence_number
    limit 1
  ) run on true
  left join lateral (
    select
      count(*) as segment_count,
      sum(ss.actual_seconds)::bigint as segments_actual_seconds
    from ops.session_segments ss
    where ss.session_id = s.id
  ) seg on true
  left join lateral (
    select case
      when inv.id is not null then inv.paid_minor
      else (
        select coalesce(sum(p.amount_minor), 0)
        from billing.payments p
        where p.session_charge_id = sc.id
          and p.status = 'posted'
      )
    end as paid_minor
  ) pay on sc.id is not null
  left join lateral (
    select p.id, p.method, p.public_code, p.paid_at
    from billing.payments p
    where p.session_charge_id = sc.id
      and p.status = 'posted'
    order by p.paid_at desc, p.id
    limit 1
  ) last_pay on sc.id is not null
  where s.id = p_session_id;

  -- الجلسة غير المرئية عبر RLS = رفض صريح بدل مغلّف فارغ غامض.
  if v_session is null then
    raise exception 'لا توجد صلاحية على هذه الجلسة'
      using errcode = '42501';
  end if;

  select coalesce(
           jsonb_agg(
             jsonb_build_object(
               'sequence_number', ss.sequence_number,
               'segment_type', ss.segment_type,
               'is_stop', ss.segment_type not in (
                 'solar_run', 'well_diesel_run', 'farmer_diesel_run'
               ),
               'is_billable', ss.is_billable,
               'energy_source', ss.energy_source,
               'started_at', ss.started_at,
               'ended_at', ss.ended_at,
               'actual_seconds', ss.actual_seconds,
               'billable_seconds', ss.billable_seconds,
               'applied_rate_minor', coalesce(
                 ss.applied_operation_rate_minor,
                 ss.applied_hourly_rate_minor
               ),
               'time_charge_minor', ss.time_charge_minor,
               'fuel_charge_minor', ss.fuel_charge_minor,
               'total_charge_minor', ss.total_charge_minor,
               'notes', ss.notes
             )
             order by ss.sequence_number
           ),
           '[]'::jsonb
         )
  into v_segments
  from ops.session_segments ss
  where ss.session_id = p_session_id;

  -- المحاصيل كما اختيرت وقت بدء هذه الجلسة (لقطة مستقلة لا تتبع الأرض).
  select coalesce(
           jsonb_agg(sc.crop_name order by sc.position),
           '[]'::jsonb
         )
  into v_crops
  from ops.session_crops sc
  where sc.session_id = p_session_id;

  return jsonb_build_object(
    'contract', 'get_session_detail',
    'version', 1,
    'session', v_session,
    'segments', v_segments,
    'crops', v_crops,
    'payment', v_payment
  );
end;
$function$;

revoke all on function api.get_session_detail(uuid)
  from public, anon, authenticated, service_role;

grant execute on function api.get_session_detail(uuid)
  to authenticated, service_role;

comment on function api.get_session_detail(uuid) is
  'عقد تفصيل الجلسة (090/105/106). actual_seconds على مستوى الجلسة كما في list_well_sessions (ق-131 البند 7)، ومقاطعها تحمل فعليها ومفوترها كما خُزّنا.';

-- ==============================================================
-- 3. api.get_reports_summary — المدة التشغيلية بالزمن الفعلي
--    (الإيراد والتحصيل والمصروف تبقى بمصادرها المالية كما هي)
-- ==============================================================

create or replace function api.get_reports_summary(
  p_well_id uuid,
  p_period text default 'this_month',
  p_start timestamptz default null,
  p_end timestamptz default null
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_period text := nullif(btrim(coalesce(p_period, '')), '');
  v_tz text;
  v_bounds tstzrange;
  v_start timestamptz;
  v_end timestamptz;
  v_first_day date;
  v_last_day date;
  v_result jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة التقارير'
      using errcode = '28000';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  v_period := coalesce(v_period, 'this_month');

  -- الحدود تُحسب في عقد واحد، فيَرِثها كل مستهلك بلا نسخة ثانية منها.
  v_tz := core.well_timezone(p_well_id);
  v_bounds := core.period_bounds(p_well_id, v_period, p_start, p_end);
  v_start := lower(v_bounds);
  v_end := upper(v_bounds);
  v_first_day := (v_start at time zone v_tz)::date;
  v_last_day := (v_end at time zone v_tz)::date - 1;

  if not exists (
    select 1
    from core.wells w
    where w.id = p_well_id
  ) then
    raise exception 'لا توجد صلاحية على هذا البئر'
      using errcode = '42501';
  end if;

  with days as (
    select gs::date as day
    from generate_series(
      v_first_day::timestamp, v_last_day::timestamp, interval '1 day'
    ) as gs
  ),
  -- ق-27: التصفية على وقت النهاية. وق-37: الجلسة غير المقفلة خارج المجاميع.
  -- ق-131 البند 7: المدة التشغيلية = الفعلي (مقاطع الجلسة أو مغلفها
  -- القديم)، والفوترة والإيراد يبقيان من billing.session_charges.
  sess as (
    select
      s.id,
      s.ended_at,
      case
        when seg.segment_count > 0
          and seg.segments_actual_seconds is not null
          then seg.segments_actual_seconds
        else extract(epoch from (s.ended_at - s.started_at))::bigint
      end as actual_seconds,
      coalesce(sc.duration_seconds, 0) as billable_seconds,
      coalesce(sc.amount_minor, 0) as amount_minor
    from ops.irrigation_sessions s
    left join billing.session_charges sc on sc.session_id = s.id
    left join lateral (
      select
        count(*) as segment_count,
        sum(ss.actual_seconds)::bigint as segments_actual_seconds
      from ops.session_segments ss
      where ss.session_id = s.id
    ) seg on true
    where s.well_id = p_well_id
      and s.ended_at is not null
      and s.ended_at >= v_start
      and s.ended_at < v_end
  ),
  paid_rows as (
    select p.paid_at, p.amount_minor
    from billing.payments p
    where p.well_id = p_well_id
      and p.status = 'posted'
      and p.paid_at >= v_start
      and p.paid_at < v_end
  ),
  exp_rows as (
    select e.spent_at, e.amount_minor
    from finance.expenses e
    where e.well_id = p_well_id
      and e.status = 'posted'
      and e.spent_at >= v_start
      and e.spent_at < v_end
  ),
  fuel as (
    select coalesce(sum(f.quantity_ml), 0) as fuel_out_ml
    from inventory.fuel_transactions f
    where f.well_id = p_well_id
      and f.status = 'posted'
      and f.direction = 'out'
      and f.occurred_at >= v_start
      and f.occurred_at < v_end
  ),
  -- إسناد اليوم بالمنطقة المحلية: `::date` الخام يقع على منطقة الخادم.
  daily as (
    select
      d.day,
      (
        select count(*)
        from sess x
        where (x.ended_at at time zone v_tz)::date = d.day
      ) as sessions_count,
      (
        select coalesce(sum(x.actual_seconds), 0)
        from sess x
        where (x.ended_at at time zone v_tz)::date = d.day
      ) as duration_seconds,
      (
        select coalesce(sum(x.amount_minor), 0)
        from paid_rows x
        where (x.paid_at at time zone v_tz)::date = d.day
      ) as collected_minor,
      (
        select coalesce(sum(x.amount_minor), 0)
        from exp_rows x
        where (x.spent_at at time zone v_tz)::date = d.day
      ) as expenses_minor
    from days d
  ),
  weekly as (
    select
      (
        dd.day
        - ((((extract(dow from dd.day)::integer + 1) % 7)) || ' days')::interval
      )::date as week_start,
      sum(dd.collected_minor) as collected_minor,
      sum(dd.expenses_minor) as expenses_minor
    from daily dd
    group by 1
  ),
  -- توزيع الطاقة من actual_seconds للمقاطع الحاملة لمصدر طاقة (ق-131):
  -- بلا مسار actual_minutes*60 القديم، وبلا استخدام المفوتر زمنًا للطاقة.
  energy as (
    select
      src.energy_source,
      coalesce((
        select sum(seg.actual_seconds)
        from ops.session_segments seg
        join sess s2 on s2.id = seg.session_id
        where seg.energy_source = src.energy_source
      ), 0) as total_seconds
    from (
      values ('solar'), ('well_diesel'), ('farmer_diesel')
    ) as src(energy_source)
  )
  select jsonb_build_object(
    'contract', 'get_reports_summary',
    'version', 3,
    'well_id', p_well_id,
    'period_code', v_period,
    'period_start', v_start,
    'period_end', v_end,
    'timezone', v_tz,
    'week_starts_on', 'saturday',
    'session_day_basis', 'ended_at',
    'open_sessions_excluded', true,
    'duration_basis', 'actual_execution',
    'totals', jsonb_build_object(
      'total_sessions', (select count(*) from sess),
      'total_duration_seconds', (
        select coalesce(sum(actual_seconds), 0) from sess
      ),
      'total_revenue_minor', (
        select coalesce(sum(amount_minor), 0) from sess
      ),
      'total_collected_minor', (
        select coalesce(sum(amount_minor), 0) from paid_rows
      ),
      'total_expenses_minor', (
        select coalesce(sum(amount_minor), 0) from exp_rows
      ),
      'total_fuel_consumed_ml', (select fuel_out_ml from fuel)
    ),
    'daily_irrigation', (
      select coalesce(jsonb_agg(
        jsonb_build_object(
          'day', dd.day,
          'sessions_count', dd.sessions_count,
          'duration_seconds', dd.duration_seconds
        ) order by dd.day
      ), '[]'::jsonb)
      from daily dd
    ),
    'financial_trends', (
      select coalesce(jsonb_agg(
        jsonb_build_object(
          'week_start', wk.week_start,
          'week_end', wk.week_start + 6,
          'collected_minor', wk.collected_minor,
          'expenses_minor', wk.expenses_minor
        ) order by wk.week_start
      ), '[]'::jsonb)
      from weekly wk
    ),
    'energy_distribution', (
      select coalesce(jsonb_agg(
        jsonb_build_object(
          'energy_source', en.energy_source,
          'total_seconds', en.total_seconds
        ) order by en.energy_source
      ), '[]'::jsonb)
      from energy en
    )
  )
  into v_result;

  return v_result;
end;
$function$;

revoke all on function api.get_reports_summary(
  uuid, text, timestamptz, timestamptz
) from public, anon, authenticated, service_role;

grant execute on function api.get_reports_summary(
  uuid, text, timestamptz, timestamptz
) to authenticated, service_role;

comment on function api.get_reports_summary(uuid, text, timestamptz, timestamptz) is
  'عقد مؤشرات التقارير (098/106). الحدود بمنطقة الجهة، ويوم الجلسة يوم نهايتها (ق-27)، والجارية خارج المجاميع (ق-37)، والمدة التشغيلية بالزمن الفعلي للتنفيذ (ق-131 البند 7) والإيراد يبقى من الفوترة كما خُزّنت.';

commit;
