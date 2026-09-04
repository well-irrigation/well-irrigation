-- 098 — حدود اليوم بمنطقة الجهة، ويوم الجلسة = يوم النهاية
--
-- ثلاثة عيوب في عقد واحد، تُعالَج معًا لأنها تصيب نفس الأرقام:
--
-- 1) `core.tenants.timezone` موجود `NOT NULL` بافتراض `Asia/Aden`، **ولا
--    دالة واحدة في القاعدة تقرأه**. فـ092 يحسب الفترات المسمّاة بـ
--    `date_trunc('day', now())` بمنطقة جلسة القاعدة — أي `UTC` — فيبدأ
--    «اليوم» الساعة 03:00 بتوقيت عدن، وجلسة 01:30 ليلًا تُحسب على أمس.
--    والفترة المخصَّصة تُقصّ بالمنطقة نفسها فتُزاح ثلاث ساعات حتى لو أرسل
--    العميل حدودًا صحيحة.
--
-- 2) ق-27 يقول: الجلسة العابرة لمنتصف الليل تُنسب **كاملة إلى يوم
--    انتهائها ولا تُجزّأ** — وهو تعديل من المالك على اقتراح كان يقول «يوم
--    البداية». و092 يصفّي ويُسند على `started_at`، أي بُني على الاقتراح
--    المرفوض. وق-39 يجعل عبور نهاية الشهر تابعًا لشهر النهاية، وهو نتيجة
--    مباشرة لق-27 لا استثناء.
--
-- 3) ق-37 يقول: الجلسة غير المقفلة **لا تدخل مجاميع أي يوم**، لأن المجموع
--    لا يُعرف قبل معرفة وقت النهاية. و092 يُدخلها.
--
-- وق-38 لا يُلمس: انتماء الجلسة للنوبة يبقى ببدايتها (لمساءلة المشغّل)،
-- وانتماؤها المحاسبي بنهايتها. القرار يفرّق بينهما صريحًا.
--
-- والتدقيق السابق قاس العيبين 2 و3 وسجّلهما
-- (`start_day_sessions=2, end_day_sessions=0, open_sessions_inside_daily=1`)
-- ولم يُسدّا، وسجّل أن لا اختبار دائمًا يحرسهما — فنُسي ما لا يُقاس.

-- ---------------------------------------------------------------------
-- 1) منطقة الجهة المالكة للبئر
-- ---------------------------------------------------------------------
-- تُقرأ بصلاحية التعريف لغرض واحد: إرجاع نصّ المنطقة. السبب أن
-- `core.tenants` عليه عزل صفوف، فقراءتها بصلاحية المتصل تُعيد صفر صفوف لمن
-- لا يرى صفّ الجهة، فتسقط إلى الافتراضي **بصمت** — فتختلف نافذة التقرير
-- باختلاف من يفتحه، وذلك غياب كاذب لا رفض صريح. والمنطقة إعداد عرض لا
-- معلومة حسّاسة، والدالة لا تمنح سلطة ولا تقرأ غير هذا العمود.
create or replace function core.well_timezone(p_well_id uuid)
returns text
language sql
stable
security definer
set search_path = pg_catalog, pg_temp
as $function$
  select coalesce(nullif(btrim(t.timezone), ''), 'Asia/Aden')
  from core.wells w
  join core.tenants t on t.id = w.tenant_id
  where w.id = p_well_id
$function$;

comment on function core.well_timezone(uuid) is
  'منطقة الجهة المالكة للبئر (098). افتراضها Asia/Aden، وهي مرجع حدود اليوم.';

revoke all on function core.well_timezone(uuid)
  from public, anon, authenticated, service_role;

grant execute on function core.well_timezone(uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2) حدود الفترة بمنطقة الجهة — منتصف الليل المحلي قاطعًا
-- ---------------------------------------------------------------------
-- الصيغة `(date_trunc(..., now() at time zone tz)) at time zone tz` هي ما
-- يجعل الحدّ منتصف ليلٍ محليًّا لا منتصف ليل الخادم. والأسبوع يبدأ السبت.
create or replace function core.period_bounds(
  p_well_id uuid,
  p_period text default 'this_month',
  p_start timestamptz default null,
  p_end timestamptz default null
)
returns tstzrange
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_tz text := core.well_timezone(p_well_id);
  v_period text := coalesce(nullif(btrim(coalesce(p_period, '')), ''), 'this_month');
  v_today date;
  v_from timestamp;
  v_to timestamp;
begin
  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  v_today := (now() at time zone v_tz)::date;

  if v_period = 'today' then
    v_from := v_today::timestamp;
    v_to := v_from + interval '1 day';
  elsif v_period = 'this_week' then
    v_from := (v_today - ((extract(dow from v_today)::integer + 1) % 7))::timestamp;
    v_to := v_from + interval '7 days';
  elsif v_period = 'this_month' then
    v_from := date_trunc('month', v_today::timestamp);
    v_to := v_from + interval '1 month';
  elsif v_period = 'custom' then
    if p_start is null or p_end is null then
      raise exception 'الفترة المخصصة تحتاج بداية ونهاية'
        using errcode = '22023';
    end if;
    if p_end <= p_start then
      raise exception 'نهاية الفترة يجب أن تكون بعد بدايتها'
        using errcode = '22023';
    end if;
    v_from := date_trunc('day', p_start at time zone v_tz);
    v_to := date_trunc('day', p_end at time zone v_tz) + interval '1 day';
    if v_to - v_from > interval '92 days' then
      raise exception 'أقصى مدى للفترة المخصصة 92 يومًا'
        using errcode = '22023';
    end if;
  else
    raise exception 'رمز فترة غير معروف: %', v_period
      using errcode = '22023';
  end if;

  return tstzrange(v_from at time zone v_tz, v_to at time zone v_tz, '[)');
end;
$function$;

comment on function core.period_bounds(uuid, text, timestamptz, timestamptz) is
  'حدود فترة التقرير بمنطقة الجهة (098). منتصف الليل المحلي، والأسبوع يبدأ السبت.';

revoke all on function core.period_bounds(uuid, text, timestamptz, timestamptz)
  from public, anon, authenticated, service_role;

grant execute on function core.period_bounds(uuid, text, timestamptz, timestamptz)
  to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3) إعادة تعريف عقد التقارير على الحدود الصحيحة وعلى يوم النهاية
-- ---------------------------------------------------------------------
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
  sess as (
    select
      s.id,
      s.ended_at,
      coalesce(sc.duration_seconds, 0) as duration_seconds,
      coalesce(sc.amount_minor, 0) as amount_minor
    from ops.irrigation_sessions s
    left join billing.session_charges sc on sc.session_id = s.id
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
        select coalesce(sum(x.duration_seconds), 0)
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
  energy as (
    select
      src.energy_source,
      coalesce((
        select sum(coalesce(seg.actual_minutes, 0)) * 60
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
    'version', 2,
    'well_id', p_well_id,
    'period_code', v_period,
    'period_start', v_start,
    'period_end', v_end,
    'timezone', v_tz,
    'week_starts_on', 'saturday',
    'session_day_basis', 'ended_at',
    'open_sessions_excluded', true,
    'totals', jsonb_build_object(
      'total_sessions', (select count(*) from sess),
      'total_duration_seconds', (
        select coalesce(sum(duration_seconds), 0) from sess
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
  'عقد مؤشرات التقارير (098). الحدود بمنطقة الجهة، ويوم الجلسة يوم نهايتها (ق-27)، والجارية خارج المجاميع (ق-37).';
