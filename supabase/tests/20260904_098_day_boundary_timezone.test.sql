-- اختبار 098 — حدود اليوم بمنطقة الجهة، ويوم الجلسة = يوم النهاية
--
-- يمتحن ثلاثة قرارات نافذة كان الكود يخالفها:
--   ق-27: الجلسة العابرة لمنتصف الليل تُنسب كاملة ليوم انتهائها ولا تُجزّأ.
--   ق-37: الجلسة غير المقفلة لا تدخل مجاميع أي يوم.
--   ق-39: عبور نهاية الشهر يتبع شهر النهاية (نتيجة ق-27 لا استثناء).
-- ومعها الحدّ الجديد: النافذة تُحسب بمنطقة الجهة لا بمنطقة جلسة القاعدة.
--
-- والسيناريوهان المكتوبان س-02 و س-03 مُجسَّدان في جلسة واحدة تبدأ
-- 31 يناير 23:20 وتنتهي 1 فبراير 01:40 بتوقيت عدن: 140 دقيقة كاملة،
-- وتقع في نافذة فبراير وحدها.

\set ON_ERROR_STOP on

begin;

do $test$
declare
  v_owner uuid;
  v_operator uuid;
  v_tenant uuid;
  v_well uuid;
  v_pump uuid;
  v_person uuid;
  v_profile uuid;
  v_account uuid;
  v_farm uuid;
  v_cross uuid;      -- الجلسة العابرة لمنتصف الليل ونهاية الشهر
  v_day uuid;        -- جلسة نهارية في 31 يناير
  v_open uuid;       -- جلسة جارية لم تُقفل
  v_bounds tstzrange;
  v_bounds_2 tstzrange;
  v_payload jsonb;
  v_item jsonb;
  v_tz text;
  v_count integer;
  -- 8400 ثانية × 36000 ÷ 3600 = 84000 بالضبط، فيصمد قيد الصيغة.
  v_rate bigint := 36000;
  v_jan_start timestamptz := '2026-01-31 00:00:00+03';
  v_feb_start timestamptz := '2026-02-01 00:00:00+03';
begin

  -- ---------------------------------------------------------------
  -- تجهيز
  -- ---------------------------------------------------------------

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'tz-owner-098@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now(),
    jsonb_build_object('full_name', 'مالك 098', 'phone', '770000098')
  ) returning id into v_owner;

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'tz-operator-098@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now(),
    jsonb_build_object('full_name', 'مشغّل 098', 'phone', '771000098')
  ) returning id into v_operator;

  insert into core.tenants (name)
  values ('جهة التوقيت 098')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name, location)
  values (v_tenant, 'بئر 098', 'موقع 098')
  returning id into v_well;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values
    (v_well, v_owner, 'owner', 'active'),
    (v_well, v_operator, 'operator', 'active');

  insert into core.pumps (well_id, name, status, pump_type, power_rating)
  values (v_well, 'مضخة 098', 'active', 'submersible', '30 HP')
  returning id into v_pump;

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع 098', 'مزارع 098')
  returning id into v_person;

  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person)
  returning id into v_profile;

  insert into ops.farmer_well_accounts (
    tenant_id, farmer_profile_id, well_id, public_code
  ) values (v_tenant, v_profile, v_well, 'FWA-098')
  returning id into v_account;

  insert into ops.farms (well_id, name, farmer_well_account_id, status)
  values (v_well, 'أرض 098', v_account, 'active')
  returning id into v_farm;

  -- ثلاث جلسات: عابرة لمنتصف الليل ونهاية الشهر، ونهارية في يناير، وجارية.
  insert into ops.irrigation_sessions (
    well_id, pump_id, farm_id, farmer_well_account_id,
    operator_profile_id, started_at, ended_at, status
  ) values (
    v_well, v_pump, v_farm, v_account, v_operator,
    '2026-01-31 23:20:00+03', '2026-02-01 01:40:00+03', 'closed'
  ) returning id into v_cross;

  insert into ops.irrigation_sessions (
    well_id, pump_id, farm_id, farmer_well_account_id,
    operator_profile_id, started_at, ended_at, status
  ) values (
    v_well, v_pump, v_farm, v_account, v_operator,
    '2026-01-31 10:00:00+03', '2026-01-31 12:00:00+03', 'closed'
  ) returning id into v_day;

  insert into ops.irrigation_sessions (
    well_id, pump_id, farm_id, farmer_well_account_id,
    operator_profile_id, started_at, ended_at, status
  ) values (
    v_well, v_pump, v_farm, v_account, v_operator,
    '2026-02-01 08:00:00+03', null, 'open'
  ) returning id into v_open;

  insert into billing.session_charges (
    session_id, well_id, duration_seconds, price_per_hour_minor, amount_minor
  ) values
    (v_cross, v_well, 8400, v_rate, 84000),
    (v_day, v_well, 7200, v_rate, 72000);

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';

  -- ---------------------------------------------------------------
  -- 1. منطقة الجهة تُقرأ فعلًا ولا تُفترض
  -- ---------------------------------------------------------------
  begin
    v_tz := core.well_timezone(v_well);

    select count(*) into v_count
    from pg_proc p
    where p.oid = to_regprocedure('core.well_timezone(uuid)')
      and p.prosecdef is true
      and p.proconfig @> array['search_path=pg_catalog, pg_temp'];

    if v_tz = 'Asia/Aden' and v_count = 1
       and not has_function_privilege('anon',
             to_regprocedure('core.well_timezone(uuid)'), 'EXECUTE')
    then
      raise notice 'PASS 1: منطقة الجهة % بمسار مثبت وanon محجوب', v_tz;
    else
      raise notice 'FAIL 1: المنطقة % أو خصائص الدالة غير مطابقة', coalesce(v_tz, 'NULL');
    end if;
  exception when others then
    raise notice 'FAIL 1: قراءة منطقة الجهة تعذّرت — %', sqlerrm;
  end;

  -- ---------------------------------------------------------------
  -- 2. حدّ اليوم منتصف ليل محليّ، ومداه يوم كامل
  -- ---------------------------------------------------------------
  begin
    v_bounds := core.period_bounds(v_well, 'today');

    if (lower(v_bounds) at time zone 'Asia/Aden')::time = '00:00:00'
       and upper(v_bounds) - lower(v_bounds) = interval '1 day'
    then
      raise notice 'PASS 2: اليوم يبدأ منتصف الليل المحلي ومداه يوم';
    else
      raise notice 'FAIL 2: حدّ اليوم % إلى %', lower(v_bounds), upper(v_bounds);
    end if;
  exception when others then
    raise notice 'FAIL 2: حساب حدّ اليوم تعذّر — %', sqlerrm;
  end;

  -- ---------------------------------------------------------------
  -- 3. الحدّ لا يتبع منطقة جلسة القاعدة — وإلا اختلف التقرير بالقارئ
  -- ---------------------------------------------------------------
  begin
    execute 'set local timezone to ''UTC''';
    v_bounds := core.period_bounds(v_well, 'today');
    execute 'set local timezone to ''America/New_York''';
    v_bounds_2 := core.period_bounds(v_well, 'today');
    execute 'reset timezone';

    if v_bounds = v_bounds_2 then
      raise notice 'PASS 3: النافذة ثابتة مهما كانت منطقة جلسة القاعدة';
    else
      raise notice 'FAIL 3: النافذة تغيّرت: % مقابل %', v_bounds, v_bounds_2;
    end if;
  exception when others then
    raise notice 'FAIL 3: مقارنة المناطق تعذّرت — %', sqlerrm;
  end;

  -- ---------------------------------------------------------------
  -- 4. والحدّ ليس منتصف ليل الخادم — وهو ما كان يفعله 092
  -- ---------------------------------------------------------------
  begin
    execute 'set local timezone to ''UTC''';
    v_bounds := core.period_bounds(v_well, 'today');

    if lower(v_bounds) <> date_trunc('day', now()) then
      raise notice 'PASS 4: الحدّ يزيح عن منتصف ليل الخادم بفارق المنطقة';
    else
      raise notice 'FAIL 4: الحدّ ما زال منتصف ليل الخادم';
    end if;

    execute 'reset timezone';
  exception when others then
    raise notice 'FAIL 4: مقارنة حدّ الخادم تعذّرت — %', sqlerrm;
  end;

  -- ---------------------------------------------------------------
  -- 5. نافذة 31 يناير: النهارية وحدها — العابرة انتهت في فبراير (ق-27)
  -- ---------------------------------------------------------------
  begin
    v_payload := api.get_reports_summary(
      v_well, 'custom', v_jan_start, v_jan_start + interval '23 hours'
    );

    if (v_payload -> 'totals' ->> 'total_sessions')::int = 1
       and (v_payload -> 'totals' ->> 'total_duration_seconds')::bigint = 7200
       and (v_payload -> 'totals' ->> 'total_revenue_minor')::bigint = 72000
    then
      raise notice 'PASS 5: يناير 31 يحمل الجلسة النهارية وحدها';
    else
      raise notice 'FAIL 5: مجاميع يناير 31 = %', (v_payload -> 'totals')::text;
    end if;
  exception when others then
    raise notice 'FAIL 5: قراءة نافذة يناير رُفضت — %', sqlerrm;
  end;

  -- ---------------------------------------------------------------
  -- 6. نافذة 1 فبراير: العابرة كاملةً 140 دقيقة، ولا تُجزّأ (ق-27/ق-39)
  -- ---------------------------------------------------------------
  begin
    v_payload := api.get_reports_summary(
      v_well, 'custom', v_feb_start, v_feb_start + interval '23 hours'
    );

    if (v_payload -> 'totals' ->> 'total_sessions')::int = 1
       and (v_payload -> 'totals' ->> 'total_duration_seconds')::bigint = 8400
       and (v_payload -> 'totals' ->> 'total_revenue_minor')::bigint = 84000
    then
      raise notice 'PASS 6: فبراير 1 يحمل العابرة كاملةً 140 دقيقة';
    else
      raise notice 'FAIL 6: مجاميع فبراير 1 = %', (v_payload -> 'totals')::text;
    end if;
  exception when others then
    raise notice 'FAIL 6: قراءة نافذة فبراير رُفضت — %', sqlerrm;
  end;

  -- ---------------------------------------------------------------
  -- 7. واليوم المُسنَد في السلسلة اليومية هو يوم النهاية لا البداية
  -- ---------------------------------------------------------------
  begin
    v_payload := api.get_reports_summary(
      v_well, 'custom', v_jan_start, v_feb_start + interval '23 hours'
    );

    select count(*) into v_count
    from jsonb_array_elements(v_payload -> 'daily_irrigation') d
    where d ->> 'day' = '2026-02-01'
      and (d ->> 'sessions_count')::int = 1
      and (d ->> 'duration_seconds')::bigint = 8400;

    v_item := (
      select d
      from jsonb_array_elements(v_payload -> 'daily_irrigation') d
      where d ->> 'day' = '2026-01-31'
    );

    if v_count = 1 and (v_item ->> 'sessions_count')::int = 1
       and (v_item ->> 'duration_seconds')::bigint = 7200
    then
      raise notice 'PASS 7: العابرة في 2026-02-01 والنهارية في 2026-01-31';
    else
      raise notice 'FAIL 7: الإسناد اليومي = %', (v_payload -> 'daily_irrigation')::text;
    end if;
  exception when others then
    raise notice 'FAIL 7: قراءة السلسلة اليومية رُفضت — %', sqlerrm;
  end;

  -- ---------------------------------------------------------------
  -- 8. ق-37: الجلسة الجارية خارج كل مجموع — مجموعها لا يُعرف بعد
  -- ---------------------------------------------------------------
  begin
    v_payload := api.get_reports_summary(
      v_well, 'custom', v_feb_start, v_feb_start + interval '23 hours'
    );

    -- الجارية بدأت 2026-02-01 08:00 فلو كان الإسناد بالبداية لظهرت هنا.
    select count(*) into v_count
    from ops.irrigation_sessions s
    where s.id = v_open
      and s.ended_at is null;

    if v_count = 1
       and (v_payload -> 'totals' ->> 'total_sessions')::int = 1
       and (v_payload ->> 'open_sessions_excluded')::boolean is true
    then
      raise notice 'PASS 8: الجارية موجودة في اليوم ومستثناة من المجاميع';
    else
      raise notice 'FAIL 8: الجارية دخلت المجاميع أو الوسم غائب — %',
        (v_payload -> 'totals')::text;
    end if;
  exception when others then
    raise notice 'FAIL 8: تحقق الجلسة الجارية تعذّر — %', sqlerrm;
  end;

  -- ---------------------------------------------------------------
  -- 9. المغلَّف يُعلن أساسه: المنطقة، ويوم النهاية، ورقم النسخة
  -- ---------------------------------------------------------------
  begin
    v_payload := api.get_reports_summary(v_well, 'today');

    if v_payload ->> 'contract' = 'get_reports_summary'
       and (v_payload ->> 'version')::int = 2
       and v_payload ->> 'timezone' = 'Asia/Aden'
       and v_payload ->> 'session_day_basis' = 'ended_at'
       and v_payload ->> 'week_starts_on' = 'saturday'
       and (v_payload ->> 'period_start') is not null
    then
      raise notice 'PASS 9: المغلَّف يعلن المنطقة وأساس اليوم والنسخة 2';
    else
      raise notice 'FAIL 9: مغلَّف غير متوقَّع — %',
        (v_payload - 'totals' - 'daily_irrigation'
          - 'financial_trends' - 'energy_distribution')::text;
    end if;
  exception when others then
    raise notice 'FAIL 9: قراءة المغلَّف رُفضت — %', sqlerrm;
  end;

  -- ---------------------------------------------------------------
  -- 10. غير المصدَّق مرفوض صريحًا على العقد وعلى دالتي الحدود
  -- ---------------------------------------------------------------
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role anon';

  begin
    perform api.get_reports_summary(v_well, 'today');
    raise notice 'FAIL 10: غير المصدَّق قرأ التقارير';
  exception when insufficient_privilege then
    raise notice 'PASS 10: غير المصدَّق مرفوض على عقد التقارير';
  when others then
    raise notice 'PASS 10: غير المصدَّق مرفوض — %', sqlerrm;
  end;

  execute 'reset role';

end;
$test$;

rollback;
