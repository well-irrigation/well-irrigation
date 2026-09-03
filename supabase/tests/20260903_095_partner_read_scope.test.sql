-- اختبار 095 — نطاق قراءة الشريك (م-41E المرحلة 4 / ق-123 §8)
--
-- يثبّت الجدول المُقرَّر في technical/ACCOUNT_SETTINGS_ARCHITECTURE.md §26
-- سلوكًا على الخادم لا عرضًا في واجهة:
-- الشريك يرى الجلسات المقفلة بأرقامها ولا يرى الجارية، ويرى **حضورها
-- وعددها** عبر العقد الجديد رغم حجب صفّها عنه، ويرى بنود المصروف ولا يرى
-- من سجّله، وتُعاد له الفترة المفتوحة موسومة غير نهائية، ولا يكتب شيئًا،
-- ولا يقرأ جدولًا مباشرة. ومن كان مشغّلًا إلى جانب شراكته يرى الجارية عبر
-- سياسة دوره — فالتضييق لا يُنتج فشلًا كاذبًا على من له سلطة أخرى.

\set ON_ERROR_STOP on

begin;

do $test$
declare
  v_api_overview oid := to_regprocedure('api.read_partner_overview(uuid)');
  v_core_overview oid := to_regprocedure(
    'finance.read_partner_overview(uuid)'
  );
  v_owner_user uuid;
  v_partner_user uuid;
  v_dual_user uuid;
  v_other_user uuid;
  v_tenant uuid;
  v_well uuid;
  v_pump uuid;
  v_pump2 uuid;
  v_partner_person uuid;
  v_dual_person uuid;
  v_farmer_person uuid;
  v_farmer_profile uuid;
  v_account uuid;
  v_farm uuid;
  v_closed_session uuid;
  v_open_session uuid;
  v_charge uuid;
  v_category uuid;
  v_partner_a uuid;
  v_partner_b uuid;
  v_cycle uuid;
  v_started timestamptz := now() - interval '3 days';
  v_payload jsonb;
  v_item jsonb;
  v_count integer;
  v_count_2 integer;
  v_text text;
  v_denied boolean;
begin

  -- ---------------------------------------------------------------
  -- 1. خصائص الأمان: الغلاف INVOKER والقارئ DEFINER بمسار مثبت
  -- ---------------------------------------------------------------

  if v_api_overview is not null and v_core_overview is not null then
    raise notice 'PASS 1: عقد api.read_partner_overview وقارئه موجودان';
  else
    raise notice 'FAIL 1: العقد أو قارئه غير موجود';
  end if;

  select count(*) into v_count
  from pg_proc p
  where p.oid = v_api_overview
    and p.prosecdef is false
    and p.proconfig @> array['search_path=pg_catalog, pg_temp'];

  select count(*) into v_count_2
  from pg_proc p
  where p.oid = v_core_overview
    and p.prosecdef is true
    and p.proconfig @> array['search_path=pg_catalog, pg_temp'];

  if v_count = 1 and v_count_2 = 1 then
    raise notice 'PASS 2: الغلاف INVOKER والقارئ DEFINER بمسار بحث مثبت';
  else
    raise notice 'FAIL 2: خصائص أمان الإجراءين غير مطابقة';
  end if;

  if not has_function_privilege('anon', v_api_overview, 'EXECUTE')
     and not has_function_privilege('anon', v_core_overview, 'EXECUTE')
     and has_function_privilege('authenticated', v_api_overview, 'EXECUTE')
  then
    raise notice 'PASS 3: anon بلا EXECUTE على العقد وقارئه، والمصدَّق يملكه';
  else
    raise notice 'FAIL 3: منح EXECUTE غير مطابق للحد';
  end if;

  -- ---------------------------------------------------------------
  -- 2. تجهيز: مالك، وشريك بلا دور تشغيلي، وشريك هو أيضًا مشغّل، وغريب
  -- ---------------------------------------------------------------

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'partner-owner-095@test.local',
    crypt('x', gen_salt('bf')),
    now(), now(), now(),
    jsonb_build_object('full_name', 'مالك 095', 'phone', '770000095')
  ) returning id into v_owner_user;

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'partner-only-095@test.local',
    crypt('x', gen_salt('bf')),
    now(), now(), now(),
    jsonb_build_object('full_name', 'شريك 095', 'phone', '771000095')
  ) returning id into v_partner_user;

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'partner-operator-095@test.local',
    crypt('x', gen_salt('bf')),
    now(), now(), now(),
    jsonb_build_object('full_name', 'شريك مشغّل 095', 'phone', '772000095')
  ) returning id into v_dual_user;

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'partner-outsider-095@test.local',
    crypt('x', gen_salt('bf')),
    now(), now(), now(),
    jsonb_build_object('full_name', 'غريب 095', 'phone', '773000095')
  ) returning id into v_other_user;

  insert into core.tenants (name)
  values ('جهة الشريك 095')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name, location)
  values (v_tenant, 'بئر الشريك 095', 'موقع 095')
  returning id into v_well;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values
    (v_well, v_owner_user, 'owner', 'active'),
    (v_well, v_dual_user, 'operator', 'active');

  insert into core.pumps (well_id, name, status, pump_type, power_rating)
  values (v_well, 'مضخة 095', 'active', 'submersible', '30 HP')
  returning id into v_pump;

  insert into core.pumps (well_id, name, status, pump_type, power_rating)
  values (v_well, 'مضخة 095-ب', 'active', 'submersible', '30 HP')
  returning id into v_pump2;

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'شريك 095', 'شريك 095')
  returning id into v_partner_person;

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'شريك مشغّل 095', 'شريك مشغّل 095')
  returning id into v_dual_person;

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع 095', 'مزارع 095')
  returning id into v_farmer_person;

  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_farmer_person)
  returning id into v_farmer_profile;

  insert into ops.farmer_well_accounts (
    tenant_id, farmer_profile_id, well_id, public_code
  ) values (v_tenant, v_farmer_profile, v_well, 'FWA-095')
  returning id into v_account;

  insert into ops.farms (well_id, name, farmer_well_account_id, status)
  values (v_well, 'أرض 095', v_account, 'active')
  returning id into v_farm;

  -- جلسة مقفلة بأرقامها: يراها الشريك — إيرادها هو ما يُشتقّ منه نصيبه.
  insert into ops.irrigation_sessions (
    well_id, pump_id, farm_id, farmer_well_account_id,
    operator_profile_id, started_at, ended_at, status
  ) values (
    v_well, v_pump, v_farm, v_account, v_dual_user,
    v_started, v_started + interval '2 hours', 'closed'
  ) returning id into v_closed_session;

  insert into ops.session_segments (
    tenant_id, session_id, sequence_number, segment_type,
    energy_source, started_at, ended_at, actual_minutes,
    is_billable, applied_hourly_rate_minor
  ) values (
    v_tenant, v_closed_session, 1, 'solar_run',
    'solar', v_started, v_started + interval '2 hours', 120,
    true, 100000
  );

  insert into billing.session_charges (
    session_id, well_id, duration_seconds,
    price_per_hour_minor, amount_minor
  ) values (v_closed_session, v_well, 7200, 100000, 200000)
  returning id into v_charge;

  -- فاتورة غير مسدَّدة: منها يُقرأ دين المزارع في عرض 060 (الفواتير ناقص
  -- المخصَّص)، فبلا فاتورة يكون الدين صفرًا ويصير الفحص بلا معنى.
  insert into billing.invoices (
    tenant_id, public_code, well_id, farmer_well_account_id,
    session_id, invoice_date, status, subtotal_minor,
    total_minor, paid_minor, outstanding_minor
  ) values (
    v_tenant, 'INV-095', v_well, v_account,
    v_closed_session, v_started, 'issued', 200000,
    200000, 0, 200000
  );

  -- جلسة جارية: أرقامها غير نهائية (ق-37 / الثابت 713) فلا يراها الشريك،
  -- والمقطع يحمل السعر المطبَّق أي أساس المستحق اللحظي.
  insert into ops.irrigation_sessions (
    well_id, pump_id, farm_id, farmer_well_account_id,
    operator_profile_id, started_at, status
  ) values (
    v_well, v_pump2, v_farm, v_account, v_dual_user,
    now() - interval '40 minutes', 'open'
  ) returning id into v_open_session;

  insert into ops.session_segments (
    tenant_id, session_id, sequence_number, segment_type,
    energy_source, started_at, actual_minutes,
    is_billable, applied_hourly_rate_minor
  ) values (
    v_tenant, v_open_session, 1, 'solar_run',
    'solar', now() - interval '40 minutes', null,
    true, 100000
  );

  -- الشريكان: الأول بلا دور تشغيلي، والثاني مشغّل أيضًا. مجموع نسب
  -- الأرباح السارية = 100 بالضبط (ق-03 / زناد 051 المؤجَّل).
  insert into core.well_partners (
    tenant_id, well_id, person_id, profile_id, phone,
    status, period_start
  ) values (
    v_tenant, v_well, v_partner_person, v_partner_user, '771000095',
    'active', current_date - 30
  ) returning id into v_partner_a;

  insert into core.well_partners (
    tenant_id, well_id, person_id, profile_id, phone,
    status, period_start
  ) values (
    v_tenant, v_well, v_dual_person, v_dual_user, '772000095',
    'active', current_date - 30
  ) returning id into v_partner_b;

  insert into core.ownership_share_versions (
    tenant_id, well_id, partner_id,
    ownership_percentage, profit_percentage, effective_period
  ) values
    (v_tenant, v_well, v_partner_a, 50, 60,
     daterange(current_date - 30, null, '[)')),
    (v_tenant, v_well, v_partner_b, 50, 40,
     daterange(current_date - 30, null, '[)'));

  insert into finance.expense_categories (
    tenant_id, code, name_ar
  ) values (v_tenant, 'maintenance_095', 'صيانة 095')
  returning id into v_category;

  -- created_by هو **الشريك المشغّل** لا المالك بقصد: سياسة 050
  -- profiles_select_partner_colleague تُتيح للشريك رؤية اسم شريكه، فلو
  -- بقي الاسم مخفيًّا بحكم RLS وحده لكان نجاح الاختبار كاذبًا. إخفاؤه
  -- هنا دليل على شرط v_partner_only في العقد لا على حجب صفّ الحساب.
  insert into finance.expenses (
    tenant_id, well_id, category_id, amount_minor, description,
    spent_at, payment_source, status, attachment_skipped,
    attachment_skip_reason, created_by, note
  ) values (
    v_tenant, v_well, v_category, 40000, 'مصروف 095',
    v_started - interval '1 day', 'other', 'posted', true,
    'اختبار', v_dual_user, 'ملاحظة داخلية 095'
  );

  -- دورة توزيع منتهية المدة: نهايتها هي بداية الفترة المفتوحة. وحالتها
  -- 'calculated' لا 'approved': الزناد finance.prevent_approved_line_change
  -- (هجرة 052) يمنع إدخال بند في دورة معتمدة، والاعتماد ليس محلّ القياس
  -- هنا — المحسوب من الدورة هو مداها ومدفوع بندها، وكلاهما لا يشترط
  -- الاعتماد ('cancelled' وحدها مستثناة في العقد).
  insert into finance.profit_distribution_cycles (
    tenant_id, well_id, period_start, period_end, status,
    eligible_collections_minor, eligible_cash_expenses_minor,
    distributable_amount_minor, calculated_at
  ) values (
    v_tenant, v_well, v_started - interval '30 days',
    v_started - interval '2 days', 'calculated',
    500000, 100000, 400000, now()
  ) returning id into v_cycle;

  -- سطر الشريك في الدورة: نسبته لحظتها 60، ومنه يُقرأ المدفوع فعلًا.
  insert into finance.profit_distribution_lines (
    tenant_id, distribution_cycle_id, partner_id,
    profit_percentage_snapshot, gross_share_minor,
    net_payable_minor, paid_minor, status
  ) values (
    v_tenant, v_cycle, v_partner_a,
    60, 240000, 240000, 100000, 'partially_paid'
  );

  -- ---------------------------------------------------------------
  -- 3. الشريك بلا دور تشغيلي: الجارية محجوبة والمقفلة مقروءة
  -- ---------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_partner_user::text, true);
  execute 'set local role authenticated';

  select
    count(*) filter (where s.status = 'open'),
    count(*) filter (where s.status = 'closed')
  into v_count, v_count_2
  from ops.irrigation_sessions s
  where s.well_id = v_well;

  if v_count = 0 and v_count_2 = 1 then
    raise notice 'PASS 4: صفّ الجلسة الجارية محجوب والمقفلة مقروءة';
  else
    raise notice 'FAIL 4: اطلاع الشريك على الجلسات غير مطابق: جارية=% مقفلة=%',
      v_count, v_count_2;
  end if;

  select
    count(*) filter (where ss.session_id = v_open_session),
    count(*) filter (where ss.session_id = v_closed_session)
  into v_count, v_count_2
  from ops.session_segments ss;

  if v_count = 0 and v_count_2 = 1 then
    raise notice 'PASS 5: مقاطع الجارية محجوبة — لا أساس مستحق لحظي';
  else
    raise notice 'FAIL 5: اطلاع الشريك على المقاطع غير مطابق: جارية=% مقفلة=%',
      v_count, v_count_2;
  end if;

  -- ---------------------------------------------------------------
  -- 4. عقود الجلسات: المقفلة تُعاد بأرقامها، والجارية لا تُعاد ولا تُفصَّل
  -- ---------------------------------------------------------------

  v_payload := api.list_well_sessions(v_well);
  v_item := v_payload -> 'items' -> 0;

  if jsonb_array_length(v_payload -> 'items') = 1
     and v_item ->> 'id' = v_closed_session::text
     and (v_item ->> 'total_amount_minor')::bigint = 200000
  then
    raise notice 'PASS 6: سجل الجلسات للشريك = المقفلة وحدها بأرقامها';
  else
    raise notice 'FAIL 6: سجل الجلسات للشريك غير مطابق: %', v_payload;
  end if;

  v_denied := false;
  begin
    perform api.get_session_detail(v_open_session);
  exception
    when insufficient_privilege then
      v_denied := true;
  end;

  if v_denied then
    raise notice 'PASS 7: تفصيل الجلسة الجارية مرفوض صريحًا للشريك';
  else
    raise notice 'FAIL 7: تفصيل الجلسة الجارية عاد للشريك';
  end if;

  v_payload := api.get_session_detail(v_closed_session);

  if v_payload -> 'session' ->> 'id' = v_closed_session::text
     and jsonb_array_length(v_payload -> 'segments') = 1
  then
    raise notice 'PASS 8: تفصيل الجلسة المقفلة يعمل — لا حجب زائد';
  else
    raise notice 'FAIL 8: تفصيل الجلسة المقفلة لم يعد للشريك: %', v_payload;
  end if;

  -- ---------------------------------------------------------------
  -- 5. المصروفات: البنود تُقرأ، ومن سجّلها لا يُقرأ، والحدّ مُعلَن
  -- ---------------------------------------------------------------

  v_payload := api.list_well_expenses(v_well);
  v_item := v_payload -> 'expenses' -> 0;

  if (v_payload ->> 'partner_scope')::boolean is true
     and (v_item ->> 'recorded_by_name') is null
     and (v_item ->> 'amount_minor')::bigint = 40000
     and v_item ->> 'description' = 'مصروف 095'
     and v_item ->> 'category_name' = 'صيانة 095'
     and (v_item ->> 'spent_at') is not null
  then
    raise notice 'PASS 9: بنود المصروف تُقرأ واسم المسجِّل مفرَّغ للشريك';
  else
    raise notice 'FAIL 9: حمولة المصروف للشريك غير مطابقة: %', v_item;
  end if;

  if not (v_payload::text like '%ملاحظة داخلية 095%') then
    raise notice 'PASS 10: الملاحظة الداخلية غير مكشوفة في العقد';
  else
    raise notice 'FAIL 10: الملاحظة الداخلية ظهرت في حمولة المصروفات';
  end if;

  -- ---------------------------------------------------------------
  -- 6. العقد الجديد: هوية الشريك وأرقامه، والحضور بلا أرقام الجلسة
  -- ---------------------------------------------------------------

  v_payload := api.read_partner_overview(v_well);
  v_item := v_payload -> 'partner';

  if v_payload ->> 'contract' = 'read_partner_overview'
     and (v_payload ->> 'version')::int = 1
     and (v_payload ->> 'is_partner')::boolean is true
     and v_item ->> 'partner_id' = v_partner_a::text
     and (v_item ->> 'profit_percent')::numeric = 60
     and (v_item ->> 'ownership_percent')::numeric = 50
     and (v_item ->> 'total_paid_minor')::bigint = 100000
     and (v_payload ->> 'server_time') is not null
  then
    raise notice 'PASS 11: العقد يعيد سطر الشريك نفسه ونسبته وأرقامه';
  else
    raise notice 'FAIL 11: حمولة الشريك غير مطابقة: %', v_payload;
  end if;

  -- الحضور نعم والأرقام لا: الصف محجوب عن الشريك ومع ذلك يُعلن العدد.
  if (v_payload -> 'active_sessions' ->> 'count')::int = 1
     and (v_payload -> 'active_sessions' ->> 'has_active')::boolean is true
  then
    raise notice 'PASS 12: حضور الجلسة الجارية وعددها يُعرضان للشريك';
  else
    raise notice 'FAIL 12: الحضور لم يُعرض — غياب كاذب: %',
      v_payload -> 'active_sessions';
  end if;

  select count(*) into v_count
  from jsonb_object_keys(v_payload -> 'active_sessions') k;

  if v_count = 2
     and position(v_open_session::text in v_payload::text) = 0
     and position(v_pump2::text in v_payload::text) = 0
     and not (v_payload::text like '%amount%')
     and not (v_payload::text like '%seconds%')
  then
    raise notice 'PASS 13: حمولة الحضور بلا معرّف جلسة ولا مضخة ولا مستحق';
  else
    raise notice 'FAIL 13: الحضور حمل رقمًا من الجلسة الجارية: %', v_payload;
  end if;

  -- الفترة المفتوحة: موسومة غير نهائية، وتبدأ من نهاية آخر دورة.
  v_item := v_payload -> 'open_window';

  if (v_item ->> 'is_final')::boolean is false
     and (v_item ->> 'starts_at')::timestamptz
       = (v_started - interval '2 days')
     and (v_item ->> 'expenses_minor')::bigint >= 0
     and (v_item ->> 'collected_minor')::bigint >= 0
  then
    raise notice 'PASS 14: الفترة المفتوحة موسومة غير نهائية من نهاية الدورة';
  else
    raise notice 'FAIL 14: وسم الفترة المفتوحة أو بدايتها غير مطابق: %', v_item;
  end if;

  -- المزارعون وديونهم: §26 يعطيها الشريك قراءةً، ومصدرها عرض 060 كما هو.
  v_payload := api.list_well_farmer_balances(v_well);
  v_item := v_payload -> 'items' -> 0;

  if v_payload ->> 'contract' = 'list_well_farmer_balances'
     and jsonb_array_length(v_payload -> 'items') = 1
     and v_item ->> 'full_name' = 'مزارع 095'
     and (v_item ->> 'invoiced_minor')::bigint = 200000
     and (v_item ->> 'debt_minor')::bigint = 200000
     and (v_item ->> 'advance_minor')::bigint = 0
  then
    raise notice 'PASS 24: الشريك يقرأ المزارعين وديونهم من العرض كما هي';
  else
    raise notice 'FAIL 24: أرصدة المزارعين للشريك غير مطابقة: %', v_payload;
  end if;

  -- ---------------------------------------------------------------
  -- 7. لا كتابة للشريك — مُثبتًا على الخادم لا بإخفاء زرّ
  --
  -- يُحتسب **رمزان معروفان وحدهما**: 42501 حيث كُتب صريحًا (عقود 094 وما
  -- بعدها)، وP0001 وهو رمز `raise exception` بلا errcode في العقود الأقدم
  -- (074 و081 و066). واحتساب «أي خطأ» رفضًا نجاحٌ كاذب في أداة التحقق
  -- نفسها (ق-113 / الثابت 699). ومعهما الدليل الحقيقي: لا صفّ جديد.
  -- ---------------------------------------------------------------

  v_count := 0;

  begin
    perform api.record_expense(
      v_well, 'maintenance_095', 1000, 'محاولة 095', null,
      false, 'other', null, null
    );
    v_text := 'no-error';
  exception
    when others then
      v_text := sqlstate;
  end;
  if v_text in ('42501', 'P0001') then
    v_count := v_count + 1;
  else
    raise notice 'INFO: record_expense أعاد % لا رمز رفض', v_text;
  end if;

  begin
    perform api.start_irrigation_session(
      v_well, v_pump, v_farm, v_account, 'solar', now(), null, null
    );
    v_text := 'no-error';
  exception
    when others then
      v_text := sqlstate;
  end;
  if v_text in ('42501', 'P0001') then
    v_count := v_count + 1;
  else
    raise notice 'INFO: start_irrigation_session أعاد % لا رمز رفض', v_text;
  end if;

  begin
    perform api.invite_well_member(
      v_well, 'operator', 'محاولة 095', '774000095'
    );
    v_text := 'no-error';
  exception
    when others then
      v_text := sqlstate;
  end;
  if v_text in ('42501', 'P0001') then
    v_count := v_count + 1;
  else
    raise notice 'INFO: invite_well_member أعاد % لا رمز رفض', v_text;
  end if;

  -- الدليل على أن الرفض رفضٌ فعلي: المصروف واحد كما كان، بلا صفّ جديد.
  select count(*) into v_count_2
  from finance.expenses e
  where e.well_id = v_well;

  if v_count = 3 and v_count_2 = 1 then
    raise notice 'PASS 15: الشريك لا يكتب: ثلاثة عقود ترفض ولا صفّ جديد';
  else
    raise notice 'FAIL 15: رفضت % من 3، والمصروفات = %', v_count, v_count_2;
  end if;

  -- ---------------------------------------------------------------
  -- 8. لا كتابة مباشرة على الجداول: الاطلاع ليس كتابة
  -- ---------------------------------------------------------------

  begin
    insert into ops.irrigation_sessions (
      well_id, pump_id, farm_id, farmer_well_account_id,
      operator_profile_id, started_at, status
    ) values (
      v_well, v_pump, v_farm, v_account, v_partner_user, now(), 'open'
    );
    v_text := 'no-error';
  exception
    when others then
      v_text := sqlstate;
  end;

  if v_text = '42501' then
    raise notice 'PASS 16: الشريك لا يُدخل جلسة مباشرة في الجدول';
  else
    raise notice 'FAIL 16: إدخال الجلسة المباشر أعاد % لا 42501', v_text;
  end if;

  begin
    update finance.expenses
    set amount_minor = 999
    where well_id = v_well;
    v_text := 'no-error';
  exception
    when others then
      v_text := sqlstate;
  end;

  select e.amount_minor into v_count
  from finance.expenses e
  where e.well_id = v_well
  limit 1;

  if v_count = 40000 then
    raise notice 'PASS 17: تعديل المصروف من الشريك لم يغيّر شيئًا';
  else
    raise notice 'FAIL 17: مبلغ المصروف صار % بعد محاولة الشريك', v_count;
  end if;

  if iam.is_partner_only(v_well) is true then
    raise notice 'PASS 18: is_partner_only = true لمن سلطته شراكة وحدها';
  else
    raise notice 'FAIL 18: is_partner_only لم تُعد true للشريك';
  end if;

  -- ---------------------------------------------------------------
  -- 9. شريكٌ هو أيضًا مشغّل: يرى الجارية بسلطة دوره — لا فشل كاذب
  -- ---------------------------------------------------------------

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_dual_user::text, true);
  execute 'set local role authenticated';

  v_payload := api.list_well_sessions(v_well);

  select count(*) into v_count
  from jsonb_array_elements(v_payload -> 'items') it
  where it ->> 'id' = v_open_session::text;

  if v_count = 1
     and iam.is_partner_only(v_well) is false
     and (api.list_well_expenses(v_well) ->> 'partner_scope')::boolean is false
  then
    raise notice 'PASS 19: الشريك المشغّل يرى الجارية ولا يُقيَّد كشريك';
  else
    raise notice 'FAIL 19: تضييق الشريك أصاب من له دور تشغيلي';
  end if;

  -- ---------------------------------------------------------------
  -- 10. المالك: لا انحدار في اطلاعه، وحالته في العقد صريحة لا خطأ
  -- ---------------------------------------------------------------

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';

  v_payload := api.list_well_sessions(v_well);
  v_item := api.list_well_expenses(v_well) -> 'expenses' -> 0;

  if jsonb_array_length(v_payload -> 'items') = 2
     and v_item ->> 'recorded_by_name' = 'شريك مشغّل 095'
  then
    raise notice 'PASS 20: المالك يرى الجلستين واسم مسجِّل المصروف';
  else
    raise notice 'FAIL 20: اطلاع المالك انحدر بعد التضييق';
  end if;

  -- سلطة العقد شراكةٌ سارية وحدها، بلا مصفوفة أدوار نصية (م-18 / اختبار
  -- 082 التحقق 5). والمالك لا يخسر بيانة: عقوده هو تُعيد الجلستين
  -- بأرقامهما كما ثبت في الفحص 20، فالرفض هنا حصرُ نطاق لا حجب معلومة.
  begin
    perform api.read_partner_overview(v_well);
    v_text := 'no-error';
  exception
    when others then
      v_text := sqlstate;
  end;

  if v_text = '42501' then
    raise notice 'PASS 21: مالكٌ بلا سطر شراكة يُرفض صريحًا من عقد الشريك';
  else
    raise notice 'FAIL 21: عقد الشريك أعاد % للمالك لا 42501', v_text;
  end if;  -- ---------------------------------------------------------------
  -- 11. الغريب: لا شراكة ولا دور ⟹ رفض صريح لا مغلّف فارغ
  -- ---------------------------------------------------------------

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_other_user::text, true);
  execute 'set local role authenticated';

  begin
    perform api.read_partner_overview(v_well);
    v_text := 'no-error';
  exception
    when others then
      v_text := sqlstate;
  end;

  if v_text = '42501' then
    raise notice 'PASS 22: من لا سلطة له يُرفض صريحًا 42501';
  else
    raise notice 'FAIL 22: عقد الشريك أعاد % للغريب لا 42501', v_text;
  end if;

  begin
    perform api.list_well_farmer_balances(v_well);
    v_text := 'no-error';
  exception
    when others then
      v_text := sqlstate;
  end;

  if v_text = '42501' then
    raise notice 'PASS 25: أرصدة المزارعين مرفوضة للغريب صريحًا';
  else
    raise notice 'FAIL 25: أرصدة المزارعين أعادت % للغريب لا 42501', v_text;
  end if;

  -- ---------------------------------------------------------------
  -- 12. anon: لا ينفّذ العقد الجديد ولو نادى مباشرة
  -- ---------------------------------------------------------------

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role anon';

  begin
    perform api.read_partner_overview(v_well);
    v_text := 'no-error';
  exception
    when others then
      v_text := sqlstate;
  end;

  execute 'reset role';

  if v_text = '42501' then
    raise notice 'PASS 23: anon لا ينفّذ عقد ملخص الشريك';
  else
    raise notice 'FAIL 23: نداء anon أعاد % لا 42501', v_text;
  end if;

  -- ---------------------------------------------------------------
  -- 13. حرس م-18 يبقى صفرًا بعد هذه الهجرة
  --
  -- الفحص الأول لهجرة 095 أسقط اختبار 082 التحقق 5: فرعُ «أو من يديره» في
  -- القارئ الداخلي كان مصفوفة أدوار نصية داخل مخطط finance. يُعاد الفحص
  -- هنا في ملف الهجرة نفسها حتى تُكتشف العودة في موضعها لا في ملف آخر.
  -- ---------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in (
    'api', 'ops', 'billing', 'finance', 'inventory', 'core', 'reporting'
  )
    and p.prokind = 'f'
    and pg_get_functiondef(p.oid) like '%iam.has_well_role%';

  if v_count = 0 then
    raise notice 'PASS 26: صفر دوال عمل على مصفوفات الأدوار النصية بعد 095';
  else
    raise notice 'FAIL 26: بقيت % دالة على السلطة النصية', v_count;
  end if;
end;
$test$;

rollback;
