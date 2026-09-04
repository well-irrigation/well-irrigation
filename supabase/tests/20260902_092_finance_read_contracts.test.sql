-- اختبار 092 — عقود القراءة المالية وعقد مؤشرات التقارير (م-41D2)
--
-- يثبّت: وجود العقود الخمسة وتوقيعاتها، STABLE + INVOKER مع search_path
-- مثبت، ACL بلا anon، حدود مخطط api، الرفض المغلق بالرموز الثلاثة،
-- تخطيط الأسماء الحقيقي مقابل أعمدة موجودة، وأن كل رقم يعود محسوبًا
-- من القاعدة لا من ثابت في الكود.

\set ON_ERROR_STOP on

begin;

do $test$
declare
  v_exp oid := to_regprocedure(
    'api.list_well_expenses(uuid, text, integer)'
  );
  v_partners oid := to_regprocedure(
    'api.list_well_partners(uuid, integer)'
  );
  v_cycles oid := to_regprocedure(
    'api.list_well_profit_cycles(uuid, integer)'
  );
  v_farmer oid := to_regprocedure(
    'api.get_farmer_account(uuid, integer)'
  );
  v_reports oid := to_regprocedure(
    'api.get_reports_summary(uuid, text, timestamptz, timestamptz)'
  );
  v_all oid[];
  v_count integer;
  v_user uuid;
  v_profile uuid;
  v_tenant uuid;
  v_well uuid;
  v_other_well uuid;
  v_pump uuid;
  v_tank uuid;
  v_partner_person uuid;
  v_farmer_person uuid;
  v_farmer_profile uuid;
  v_account uuid;
  v_other_account uuid;
  v_farm uuid;
  v_session uuid;
  v_charge uuid;
  v_invoice uuid;
  v_session_payment uuid;
  v_category uuid;
  v_partner uuid;
  v_cycle uuid;
  v_line uuid;
  v_payload jsonb;
  v_item jsonb;
  v_code text;
  v_started timestamptz := date_trunc('day', now()) + interval '9 hours';
begin
  v_all := array[v_exp, v_partners, v_cycles, v_farmer, v_reports];

  -- ---------------------------------------------------------------
  -- 1. وجود العقود الخمسة وإرجاعها jsonb
  -- ---------------------------------------------------------------

  select count(*)
  into v_count
  from unnest(v_all) as t(o)
  where t.o is not null
    and pg_get_function_result(t.o) = 'jsonb';

  if v_count = 5 then
    raise notice 'PASS 1: عقود القراءة المالية الخمسة موجودة وتعيد jsonb';
  else
    raise notice 'FAIL 1: % عقد فقط من الخمسة سليم', v_count;
  end if;

  -- ---------------------------------------------------------------
  -- 2. الخمسة STABLE وINVOKER وsearch_path مثبت
  -- ---------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  where p.oid = any(v_all)
    and p.provolatile = 's'
    and p.prosecdef = false;

  if v_count = 5 then
    raise notice 'PASS 2: الخمسة STABLE وSECURITY INVOKER';
  else
    raise notice 'FAIL 2: % عقد فقط STABLE وINVOKER', v_count;
  end if;

  select count(*)
  into v_count
  from pg_proc p
  where p.oid = any(v_all)
    and p.proconfig @> array['search_path=pg_catalog, pg_temp'];

  if v_count = 5 then
    raise notice 'PASS 3: search_path مثبت في الخمسة';
  else
    raise notice 'FAIL 3: search_path غير مثبت في % عقد', 5 - v_count;
  end if;

  -- ---------------------------------------------------------------
  -- 3. ACL: anon محجوب، وauthenticated وservice_role يملكان EXECUTE
  -- ---------------------------------------------------------------

  select count(*)
  into v_count
  from unnest(v_all) as t(o)
  where has_function_privilege('anon', t.o, 'EXECUTE');

  if v_count = 0 then
    raise notice 'PASS 4: anon بلا EXECUTE على أي عقد مالي';
  else
    raise notice 'FAIL 4: anon يملك EXECUTE على % عقد', v_count;
  end if;

  select count(*)
  into v_count
  from unnest(v_all) as t(o)
  where has_function_privilege('authenticated', t.o, 'EXECUTE')
    and has_function_privilege('service_role', t.o, 'EXECUTE');

  if v_count = 5 then
    raise notice 'PASS 5: authenticated وservice_role يملكان الخمسة';
  else
    raise notice 'FAIL 5: المنح ناقص في % عقد', 5 - v_count;
  end if;

  -- ---------------------------------------------------------------
  -- 4. حدود مخطط api بعد إضافة العقود الخمسة
  -- ---------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'api'
    and p.prosecdef;

  if v_count = 0 then
    raise notice 'PASS 6: مخطط api خالٍ من SECURITY DEFINER';
  else
    raise notice 'FAIL 6: يوجد % دالة SECURITY DEFINER داخل api', v_count;
  end if;

  select count(*)
  into v_count
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'api'
    and c.relkind in ('r', 'p', 'v', 'm', 'f');

  if v_count = 0 then
    raise notice 'PASS 7: مخطط api دوال فقط — لا جداول ولا Views';
  else
    raise notice 'FAIL 7: يوجد % كائن علائقي داخل api', v_count;
  end if;

  -- ---------------------------------------------------------------
  -- 5. حرس المراجع الميتة: لا جدول ولا مخطط مخترع داخل أي عقد api
  -- ---------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'api'
    and (
      p.prosrc like '%well_memberships%'
      or p.prosrc like '%public.farms%'
    );

  if v_count = 0 then
    raise notice 'PASS 8: لا عقد api يشير إلى well_memberships أو public.farms';
  else
    raise notice 'FAIL 8: % عقد يشير إلى مرجع لا وجود له', v_count;
  end if;

  select count(*)
  into v_count
  from pg_proc p
  where p.oid = v_farmer
    and p.prosrc like '%i.invoice_date%'
    and p.prosrc not like '%i.issue_date%';

  if v_count = 1 then
    raise notice 'PASS 9: get_farmer_account يقرأ invoice_date الحقيقي';
  else
    raise notice 'FAIL 9: عقد المزارع لا يقرأ invoice_date كما يجب';
  end if;

  -- ---------------------------------------------------------------
  -- 6. عروض reporting التي تستند إليها العقود موجودة وsecurity_invoker
  -- ---------------------------------------------------------------

  select count(*)
  into v_count
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'reporting'
    and c.relkind = 'v'
    and c.relname in ('partner_account_summary', 'farmer_account_balances')
    and c.reloptions @> array['security_invoker=true'];

  if v_count = 2 then
    raise notice 'PASS 10: عرضا reporting المستخدمان موجودان وsecurity_invoker';
  else
    raise notice 'FAIL 10: عروض reporting غير مطابقة (%)', v_count;
  end if;

  -- ---------------------------------------------------------------
  -- 7. تجهيز بيانات حقيقية (كسوبر يوزر قبل تحويل الدور)
  -- ---------------------------------------------------------------

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at
  ) values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'finance-092@test.local',
    crypt('x', gen_salt('bf')),
    now(), now(), now()
  ) returning id into v_user;

  select id into v_profile from iam.profiles where id = v_user;

  if v_profile is null then
    raise exception '092: لم يُنشأ iam.profiles للمستخدم التجريبي';
  end if;

  insert into core.tenants (name)
  values ('جهة مالية 092')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name, location)
  values (v_tenant, 'بئر مالي 092', 'موقع 092')
  returning id into v_well;

  insert into core.wells (tenant_id, name, location)
  values (v_tenant, 'بئر غير مُعيَّن 092', 'موقع 092-ب')
  returning id into v_other_well;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_well, v_profile, 'owner', 'active');

  insert into core.pumps (well_id, name, status, pump_type, power_rating)
  values (v_well, 'مضخة 092', 'active', 'submersible', '30 HP')
  returning id into v_pump;

  select ft.id
  into v_tank
  from inventory.fuel_tanks ft
  where ft.well_id = v_well
  order by ft.created_at, ft.id
  limit 1;

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'شريك 092', 'شريك 092')
  returning id into v_partner_person;

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع 092', 'مزارع 092')
  returning id into v_farmer_person;

  insert into core.person_contacts (
    tenant_id, person_id, contact_type, contact_value,
    normalized_value, is_primary
  ) values (
    v_tenant, v_farmer_person, 'mobile', '770000092',
    '770000092', true
  );

  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_farmer_person)
  returning id into v_farmer_profile;

  insert into ops.farmer_well_accounts (
    tenant_id, farmer_profile_id, well_id, public_code
  ) values (v_tenant, v_farmer_profile, v_well, 'FWA-092')
  returning id into v_account;

  -- هوية المزارع المسؤول عن الأرض هي Farmer Well Account لا Login
  -- Profile: هجرة 075 (ق-80) أسقطت ops.farms.farmer_profile_id
  -- وأضافت farmer_well_account_id بمفتاح مركب مع البئر.
  insert into ops.farms (well_id, name, farmer_well_account_id, status)
  values (v_well, 'أرض 092', v_account, 'active')
  returning id into v_farm;

  -- الزناد ops.enforce_farm_assignment_consistency يشترط أن حساب
  -- الجلسة يطابق حساب الأرض نفسها حين تكون الأرض معيَّنة لحساب.
  insert into ops.irrigation_sessions (
    well_id, pump_id, farm_id, farmer_well_account_id,
    operator_profile_id, started_at, ended_at, status
  ) values (
    v_well, v_pump, v_farm, v_account, v_profile,
    v_started, v_started + interval '2 hours', 'closed'
  ) returning id into v_session;

  insert into ops.session_segments (
    tenant_id, session_id, sequence_number, segment_type,
    energy_source, started_at, ended_at, actual_minutes, is_billable
  ) values (
    v_tenant, v_session, 1, 'solar_run',
    'solar', v_started, v_started + interval '2 hours', 120, true
  );

  insert into billing.session_charges (
    session_id, well_id, duration_seconds,
    price_per_hour_minor, amount_minor
  ) values (v_session, v_well, 7200, 100000, 200000)
  returning id into v_charge;

  insert into billing.invoices (
    tenant_id, public_code, well_id, farmer_well_account_id,
    session_id, invoice_date, status, subtotal_minor,
    total_minor, paid_minor, outstanding_minor
  ) values (
    v_tenant, 'INV-092', v_well, v_account,
    v_session, v_started, 'partially_paid', 200000,
    200000, 50000, 150000
  ) returning id into v_invoice;

  -- دفعة جلسة: مربوطة بالتكلفة لا بحساب المزارع (قيد payments_target_check
  -- في هجرة 043 يشترط session_charge_id للغرض 'session')، فلا تُلتقط في
  -- كشف الحساب إلا عبر تخصيصها للفاتورة. هذا بالضبط ما يختبره الفحص 26.
  insert into billing.payments (
    tenant_id, well_id, session_charge_id, purpose,
    amount_minor, method, paid_at, status,
    collected_by_profile_id
  ) values (
    v_tenant, v_well, v_charge, 'session',
    50000, 'cash', v_started + interval '3 hours', 'posted',
    v_profile
  ) returning id into v_session_payment;

  insert into billing.payment_allocations (
    tenant_id, payment_id, invoice_id, allocated_minor
  ) values (v_tenant, v_session_payment, v_invoice, 50000);

  insert into billing.payments (
    tenant_id, well_id, farmer_well_account_id, purpose,
    amount_minor, method, paid_at, status,
    collected_by_profile_id
  ) values (
    v_tenant, v_well, v_account, 'advance',
    30000, 'cash', v_started + interval '4 hours', 'posted',
    v_profile
  );

  insert into finance.expense_categories (
    tenant_id, code, name_ar
  ) values (v_tenant, 'maintenance_092', 'صيانة 092')
  returning id into v_category;

  -- share_ppm أُسقط في هجرة 051 (ق-74): النسب صارت في
  -- core.ownership_share_versions بتاريخ نفاذ، لا عمودًا في الشريك.
  insert into core.well_partners (
    tenant_id, well_id, person_id, phone,
    status, period_start
  ) values (
    v_tenant, v_well, v_partner_person, '770000192',
    'active', current_date - 10
  ) returning id into v_partner;

  -- الزناد core.check_well_profit_shares_total يشترط أن مجموع نسب
  -- الأرباح السارية = 100 بالضبط (ق-03)، وهو DEFERRABLE فلا يُغري
  -- بتركه مخالفًا اعتمادًا على ROLLBACK. أما نسبة الملكية فغير
  -- مقيدة بمجموع، فتُترك 40 لتظل مختلفة عن نسبة الأرباح — وهذا
  -- بالضبط ما يكشف خلط العمودين في العقد.
  insert into core.ownership_share_versions (
    tenant_id, well_id, partner_id,
    ownership_percentage, profit_percentage, effective_period
  ) values (
    v_tenant, v_well, v_partner,
    40, 100, daterange(current_date - 10, null, '[)')
  );

  -- مصروفان: الأقدم بلا شريك، والأحدث مرتبط بالشريك ومسجَّل بمستخدم.
  insert into finance.expenses (
    tenant_id, well_id, category_id, amount_minor, description,
    spent_at, payment_source, status, attachment_skipped,
    attachment_skip_reason, created_by
  ) values (
    v_tenant, v_well, v_category, 40000, 'مصروف قديم 092',
    v_started - interval '2 days', 'other', 'posted', true,
    'اختبار', v_profile
  );

  insert into finance.expenses (
    tenant_id, well_id, category_id, partner_id, amount_minor,
    description, spent_at, payment_source, status,
    attachment_skipped, attachment_skip_reason, created_by
  ) values (
    v_tenant, v_well, v_category, v_partner, 60000,
    'مصروف حديث 092', v_started + interval '1 hour', 'partner_paid',
    'posted', true, 'اختبار', v_profile
  );

  -- الزناد inventory.apply_fuel_transaction يرفض أي صرف يجعل رصيد
  -- الخزان سالبًا، والخزان يُنشأ تلقائيًا مع البئر برصيد صفر (هجرة
  -- 046)، فيلزم وارد قبل الاستهلاك. الوارد لا يدخل في مجموع الاستهلاك
  -- لأن العقد يجمع direction = 'out' وحده.
  insert into inventory.fuel_transactions (
    tenant_id, well_id, fuel_tank_id, transaction_type,
    ownership_type, quantity_ml, direction,
    unit_cost_per_liter_minor, occurred_at, status
  ) values (
    v_tenant, v_well, v_tank, 'purchase',
    'well', 100000, 'in',
    1000, v_started - interval '1 hour', 'posted'
  );

  insert into inventory.fuel_transactions (
    tenant_id, well_id, fuel_tank_id, transaction_type,
    ownership_type, quantity_ml, direction, occurred_at, status
  ) values (
    v_tenant, v_well, v_tank, 'session_consumption',
    'well', 40000, 'out', v_started + interval '2 hours', 'posted'
  );

  -- الزناد finance.prevent_approved_line_change يمنع INSERT لأي بند
  -- في دورة حالتها approved/partially_paid/paid، فتُنشأ الدورة
  -- calculated ثم تُحدَّث حالتها بعد إدخال البند.
  insert into finance.profit_distribution_cycles (
    tenant_id, well_id, period_start, period_end, status,
    eligible_collections_minor, eligible_cash_expenses_minor,
    reserved_liabilities_minor, maintenance_reserve_minor,
    distributable_amount_minor
  ) values (
    v_tenant, v_well, v_started - interval '30 days', v_started,
    'calculated', 500000, 120000, 20000, 30000, 330000
  ) returning id into v_cycle;

  -- الزناد finance.check_distribution_cycle_lines_total يشترط أن
  -- مجموع gross_share_minor = distributable_amount_minor بالضبط،
  -- والشريك الواحد نسبة أرباحه 100 فحصته كل القابل للتوزيع.
  -- والمستحق = الإجمالي ناقص مستحقات الشريك وخصم السقي.
  insert into finance.profit_distribution_lines (
    tenant_id, distribution_cycle_id, partner_id,
    profit_percentage_snapshot, gross_share_minor,
    partner_receivables_minor, irrigation_deductions_minor,
    other_deductions_minor, net_payable_minor, paid_minor, status
  ) values (
    v_tenant, v_cycle, v_partner,
    100, 330000, 5000, 7000, 0, 318000, 3500, 'partially_paid'
  ) returning id into v_line;

  update finance.profit_distribution_cycles
  set status = 'partially_paid'
  where id = v_cycle;

  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  -- ---------------------------------------------------------------
  -- 8. مصروفات البئر: الغلاف والترتيب والأسماء الحقيقية
  -- ---------------------------------------------------------------

  v_payload := api.list_well_expenses(v_well);
  v_item := v_payload -> 'expenses' -> 0;

  if v_payload ->> 'contract' = 'list_well_expenses'
     and (v_payload ->> 'version')::int = 1
     and v_payload ->> 'well_id' = v_well::text
     and jsonb_array_length(v_payload -> 'expenses') = 2
  then
    raise notice 'PASS 11: غلاف list_well_expenses صحيح ويعيد المصروفين';
  else
    raise notice 'FAIL 11: غلاف أو عدد المصروفات غير مطابق';
  end if;

  if v_item ->> 'description' = 'مصروف حديث 092'
     and (v_item ->> 'amount_minor')::bigint = 60000
  then
    raise notice 'PASS 12: الترتيب حتمي — الأحدث أولًا';
  else
    raise notice 'FAIL 12: ترتيب المصروفات غير حتمي (%)',
      v_item ->> 'description';
  end if;

  if v_item ->> 'category_code' = 'maintenance_092'
     and v_item ->> 'category_name' = 'صيانة 092'
  then
    raise notice 'PASS 13: اسم الفئة من انضمام حقيقي لا من نص ثابت';
  else
    raise notice 'FAIL 13: بيانات الفئة غير مطابقة';
  end if;

  if v_item ->> 'partner_name' = 'شريك 092'
     and v_item ->> 'partner_id' = v_partner::text
     and v_payload -> 'expenses' -> 1 -> 'partner_name' = 'null'::jsonb
  then
    raise notice 'PASS 14: اسم الشريك يظهر عند وجوده وnull عند غيابه';
  else
    raise notice 'FAIL 14: ربط الشريك بالمصروف غير مطابق';
  end if;

  if v_item ->> 'recorded_by_name' is not distinct from (
       select p.full_name from iam.profiles p where p.id = v_profile
     )
     and v_item ? 'attachment_skipped'
     and (v_item ->> 'attachment_skipped')::boolean = true
     and v_item ->> 'skip_reason' = 'اختبار'
  then
    raise notice 'PASS 15: مُسجِّل المصروف وحالة المرفق من القاعدة';
  else
    raise notice 'FAIL 15: حقول المُسجِّل أو المرفق غير مطابقة';
  end if;

  v_payload := api.list_well_expenses(v_well, 'reversed');

  if jsonb_array_length(v_payload -> 'expenses') = 0 then
    raise notice 'PASS 16: تصفية الحالة تعمل ولا تتجاهل الوسيط';
  else
    raise notice 'FAIL 16: تصفية الحالة تجاهلت الوسيط';
  end if;

  begin
    v_payload := api.list_well_expenses(v_well, 'ghost_status');
    raise notice 'FAIL 17: حالة مخترعة قُبلت بلا رفض';
  exception
    when others then
      v_code := sqlstate;
      if v_code = '22023' then
        raise notice 'PASS 17: الحالة غير المعروفة تُرفض بـ22023';
      else
        raise notice 'FAIL 17: رمز الرفض % بدل 22023', v_code;
      end if;
  end;

  -- ---------------------------------------------------------------
  -- 9. الشركاء: نسب من النسخة السارية ومال من أسطر التوزيع
  -- ---------------------------------------------------------------

  v_payload := api.list_well_partners(v_well);
  v_item := v_payload -> 'partners' -> 0;

  if v_payload ->> 'contract' = 'list_well_partners'
     and jsonb_array_length(v_payload -> 'partners') = 1
     and v_item ->> 'full_name' = 'شريك 092'
     and v_item ->> 'phone' = '770000192'
  then
    raise notice 'PASS 18: list_well_partners يقرأ شركاء حقيقيين';
  else
    raise notice 'FAIL 18: قراءة الشركاء غير مطابقة';
  end if;

  -- المستودع كان يثبّت 25 لكل شريك؛ الحقيقة نسختان مختلفتان في
  -- الصف السّاري: 40 ملكية و100 أرباحًا. اختلافهما يمنع أن يمر
  -- خلط العمودين مرور الكرام.
  if (v_item ->> 'ownership_percent')::numeric = 40
     and (v_item ->> 'profit_percent')::numeric = 100
  then
    raise notice 'PASS 19: النسبتان من النسخة السارية لا من ثابت 25';
  else
    raise notice 'FAIL 19: النسب غير مطابقة (% / %)',
      v_item ->> 'ownership_percent', v_item ->> 'profit_percent';
  end if;

  -- الأرقام الأربعة التي كانت ملفّقة (180000 / 25000 / 35000 / 100000).
  if (v_item ->> 'total_earnings_minor')::bigint = 330000
     and (v_item ->> 'out_of_pocket_minor')::bigint = 5000
     and (v_item ->> 'irrigation_deduction_minor')::bigint = 7000
     and (v_item ->> 'total_paid_minor')::bigint = 3500
     and (v_item ->> 'net_payable_minor')::bigint = 318000
  then
    raise notice 'PASS 20: مال الشريك كله من أعمدة حقيقية لا من ثوابت';
  else
    raise notice 'FAIL 20: مال الشريك غير مطابق للأعمدة';
  end if;

  -- ---------------------------------------------------------------
  -- 10. دورات التوزيع: تخطيط الأسماء والمتبقي
  -- ---------------------------------------------------------------

  v_payload := api.list_well_profit_cycles(v_well);
  v_item := v_payload -> 'cycles' -> 0;

  if v_payload ->> 'contract' = 'list_well_profit_cycles'
     and jsonb_array_length(v_payload -> 'cycles') = 1
     and (v_item ->> 'eligible_revenue_minor')::bigint = 500000
     and (v_item ->> 'eligible_expenses_minor')::bigint = 120000
     and (v_item ->> 'retained_liabilities_minor')::bigint = 20000
     and (v_item ->> 'maintenance_reserve_minor')::bigint = 30000
     and (v_item ->> 'distributable_profit_minor')::bigint = 330000
  then
    raise notice 'PASS 21: تخطيط أسماء الدورة الخمسة صحيح مقابل أعمدتها';
  else
    raise notice 'FAIL 21: تخطيط أسماء دورة التوزيع غير مطابق';
  end if;

  if jsonb_array_length(v_item -> 'partner_lines') = 1
     and v_item -> 'partner_lines' -> 0 ->> 'line_id' = v_line::text
     and v_item -> 'partner_lines' -> 0 ->> 'partner_name' = 'شريك 092'
     and (v_item -> 'partner_lines' -> 0 ->> 'net_share_minor')::bigint
         = 318000
     and (v_item -> 'partner_lines' -> 0 ->> 'paid_amount_minor')::bigint
         = 3500
     and (v_item -> 'partner_lines' -> 0 ->> 'remaining_minor')::bigint
         = 314500
  then
    raise notice 'PASS 22: سطر الشريك مكتمل والمتبقي = المستحق ناقص المدفوع';
  else
    raise notice 'FAIL 22: سطر توزيع الشريك غير مطابق';
  end if;

  -- ---------------------------------------------------------------
  -- 11. حساب المزارع: هوية حقيقية ودين ومقدَّم محسوبان في القاعدة
  -- ---------------------------------------------------------------

  v_payload := api.get_farmer_account(v_account);

  if v_payload ->> 'contract' = 'get_farmer_account'
     and v_payload -> 'account' ->> 'full_name' = 'مزارع 092'
     and v_payload -> 'account' ->> 'public_code' = 'FWA-092'
     and v_payload -> 'account' ->> 'phone' = '770000092'
  then
    raise notice 'PASS 23: هوية المزارع من القاعدة لا من ثابت في الكود';
  else
    raise notice 'FAIL 23: هوية المزارع غير مطابقة';
  end if;

  -- كان الدين يُجمع في العميل والمقدَّم ثابتًا 15000.
  if (v_payload -> 'account' ->> 'total_debt_minor')::bigint = 150000
     and (v_payload -> 'account' ->> 'advance_balance_minor')::bigint
         = 30000
     and (v_payload -> 'account' ->> 'invoiced_minor')::bigint = 200000
     and (v_payload -> 'account' ->> 'allocated_minor')::bigint = 50000
  then
    raise notice 'PASS 24: الدين والمقدَّم محسوبان في القاعدة';
  else
    raise notice 'FAIL 24: أرقام رصيد المزارع غير مطابقة';
  end if;

  v_item := v_payload -> 'invoices' -> 0;

  if jsonb_array_length(v_payload -> 'invoices') = 1
     and v_item ->> 'invoice_number' = 'INV-092'
     and (v_item ->> 'issue_date')::timestamptz = v_started
     and v_item ->> 'farm_name' = 'أرض 092'
     and (v_item ->> 'original_amount_minor')::bigint = 200000
     and (v_item ->> 'paid_amount_minor')::bigint = 50000
  then
    raise notice 'PASS 25: الفاتورة تحمل رمزها وتاريخها الحقيقي واسم الأرض';
  else
    raise notice 'FAIL 25: حقول الفاتورة غير مطابقة';
  end if;

  if jsonb_array_length(v_payload -> 'payments') = 2 then
    raise notice 'PASS 26: دفعة الجلسة تُلتقط عبر تخصيصها لا بحقل مفقود';
  else
    raise notice 'FAIL 26: عدد الدفعات % بدل 2',
      jsonb_array_length(v_payload -> 'payments');
  end if;

  select x.item
  into v_item
  from jsonb_array_elements(v_payload -> 'payments') as x(item)
  where x.item ->> 'id' = v_session_payment::text;

  if v_item is not null
     and jsonb_array_length(v_item -> 'allocated_invoices') = 1
     and v_item -> 'allocated_invoices' ->> 0 = 'INV-092'
     and (v_item ->> 'amount_minor')::bigint = 50000
  then
    raise notice 'PASS 27: الدفعة تحمل أرقام الفواتير المخصصة لها';
  else
    raise notice 'FAIL 27: تخصيصات الدفعة غير مطابقة';
  end if;

  -- ---------------------------------------------------------------
  -- 12. مؤشرات التقارير: أرقام مقاسة لا ثوابت
  -- ---------------------------------------------------------------

  v_payload := api.get_reports_summary(v_well, 'today');

  -- حُدِّث في 098: كان هذا التحقق يشترط `period_start = date_trunc('day',
  -- now())` — أي **يُرسّخ العطب**: يُثبّت أن حدّ اليوم منتصف ليل الخادم،
  -- فيمنع إصلاحه. كُتب من الكود لا من القرار. والآن يقيس الخاصية المطلوبة
  -- نفسها لا صيغة حسابها: الحدّ يقع عند منتصف الليل بمنطقة الجهة.
  if v_payload ->> 'contract' = 'get_reports_summary'
     and v_payload ->> 'period_code' = 'today'
     and v_payload ->> 'week_starts_on' = 'saturday'
     and v_payload ->> 'timezone' = 'Asia/Aden'
     and (
       ((v_payload ->> 'period_start')::timestamptz
         at time zone (v_payload ->> 'timezone'))::time = '00:00:00'
     )
     and (v_payload ->> 'period_end')::timestamptz
         - (v_payload ->> 'period_start')::timestamptz = interval '1 day'
  then
    raise notice 'PASS 28: غلاف التقارير وحدّ اليوم بمنطقة الجهة';
  else
    raise notice 'FAIL 28: غلاف التقارير أو حدود الفترة غير مطابقة';
  end if;

  -- كانت الشاشة تعرض 24 جلسة و945000 و720000 و285000 و460 لترًا.
  if (v_payload -> 'totals' ->> 'total_sessions')::bigint = 1
     and (v_payload -> 'totals' ->> 'total_duration_seconds')::bigint = 7200
     and (v_payload -> 'totals' ->> 'total_revenue_minor')::bigint = 200000
     and (v_payload -> 'totals' ->> 'total_collected_minor')::bigint = 80000
     and (v_payload -> 'totals' ->> 'total_expenses_minor')::bigint = 60000
     and (v_payload -> 'totals' ->> 'total_fuel_consumed_ml')::bigint = 40000
  then
    raise notice 'PASS 29: مجاميع اليوم تطابق المُدخل بالضبط';
  else
    raise notice 'FAIL 29: مجاميع التقارير غير مطابقة (%)',
      v_payload -> 'totals';
  end if;

  if jsonb_array_length(v_payload -> 'daily_irrigation') = 1
     and (v_payload -> 'daily_irrigation' -> 0 ->> 'sessions_count')::int = 1
     and (v_payload -> 'daily_irrigation' -> 0 ->> 'duration_seconds')::bigint
         = 7200
  then
    raise notice 'PASS 30: السلسلة اليومية صف لكل يوم في النافذة';
  else
    raise notice 'FAIL 30: السلسلة اليومية غير مطابقة';
  end if;

  -- توزيع الطاقة ثلاثة صفوف دائمًا (شمسي/ديزل البئر/ديزل المزارع)،
  -- والشمسي هنا 120 دقيقة فعلية = 7200 ثانية. الشاشة كانت تعرض 58/31/11%.
  select x.item
  into v_item
  from jsonb_array_elements(v_payload -> 'energy_distribution') as x(item)
  where x.item ->> 'energy_source' = 'solar';

  if jsonb_array_length(v_payload -> 'energy_distribution') = 3
     and v_item is not null
     and (v_item ->> 'total_seconds')::bigint = 7200
  then
    raise notice 'PASS 31: توزيع الطاقة مقاس من مقاطع الجلسة';
  else
    raise notice 'FAIL 31: توزيع الطاقة غير مطابق (%)',
      v_payload -> 'energy_distribution';
  end if;

  -- فترة مخصصة تغطي المصروف الأقدم أيضًا: أربعة أيام، 100000 ريال.
  v_payload := api.get_reports_summary(
    v_well,
    'custom',
    v_started - interval '3 days',
    v_started
  );

  if v_payload ->> 'period_code' = 'custom'
     and jsonb_array_length(v_payload -> 'daily_irrigation') = 4
     and (v_payload -> 'totals' ->> 'total_expenses_minor')::bigint = 100000
     and (v_payload -> 'totals' ->> 'total_sessions')::bigint = 1
  then
    raise notice 'PASS 32: الفترة المخصصة تُحسب على حدودها لا على اليوم';
  else
    raise notice 'FAIL 32: الفترة المخصصة غير مطابقة';
  end if;

  if jsonb_array_length(v_payload -> 'financial_trends') >= 1
     and (v_payload -> 'financial_trends' -> 0 ->> 'week_start') is not null
     and (
       select bool_and(
         extract(dow from (x.item ->> 'week_start')::date) = 6
       )
       from jsonb_array_elements(v_payload -> 'financial_trends') as x(item)
     )
  then
    raise notice 'PASS 33: أسابيع الاتجاه المالي تبدأ السبت';
  else
    raise notice 'FAIL 33: بداية الأسبوع ليست السبت';
  end if;

  -- ---------------------------------------------------------------
  -- 13. مدخلات غير صالحة تُرفض بـ22023 لا تُصحَّح بصمت
  -- ---------------------------------------------------------------

  v_count := 0;

  v_code := null;
  begin
    perform api.get_reports_summary(v_well, 'last_decade');
  exception
    when others then
      v_code := sqlstate;
  end;
  if v_code = '22023' then v_count := v_count + 1; end if;

  v_code := null;
  begin
    perform api.get_reports_summary(v_well, 'custom');
  exception
    when others then
      v_code := sqlstate;
  end;
  if v_code = '22023' then v_count := v_count + 1; end if;

  v_code := null;
  begin
    perform api.get_reports_summary(v_well, 'custom', v_started, null);
  exception
    when others then
      v_code := sqlstate;
  end;
  if v_code = '22023' then v_count := v_count + 1; end if;

  v_code := null;
  begin
    perform api.get_reports_summary(
      v_well, 'custom', v_started, v_started - interval '1 day'
    );
  exception
    when others then
      v_code := sqlstate;
  end;
  if v_code = '22023' then v_count := v_count + 1; end if;

  v_code := null;
  begin
    perform api.get_reports_summary(
      v_well, 'custom', v_started - interval '200 days', v_started
    );
  exception
    when others then
      v_code := sqlstate;
  end;
  if v_code = '22023' then v_count := v_count + 1; end if;

  if v_count = 5 then
    raise notice 'PASS 34: خمس حالات مدخلات فاسدة رُفضت بـ22023';
  else
    raise notice 'FAIL 34: % حالة فقط رُفضت من 5', v_count;
  end if;

  -- ---------------------------------------------------------------
  -- 14. بئر غير مُعيَّن: 42501 لا قائمة فارغة مبهمة
  -- ---------------------------------------------------------------

  v_count := 0;

  v_code := null;
  begin
    perform api.list_well_expenses(v_other_well);
  exception
    when others then
      v_code := sqlstate;
  end;
  if v_code = '42501' then v_count := v_count + 1; end if;

  v_code := null;
  begin
    perform api.list_well_partners(v_other_well);
  exception
    when others then
      v_code := sqlstate;
  end;
  if v_code = '42501' then v_count := v_count + 1; end if;

  v_code := null;
  begin
    perform api.list_well_profit_cycles(v_other_well);
  exception
    when others then
      v_code := sqlstate;
  end;
  if v_code = '42501' then v_count := v_count + 1; end if;

  v_code := null;
  begin
    perform api.get_reports_summary(v_other_well, 'today');
  exception
    when others then
      v_code := sqlstate;
  end;
  if v_code = '42501' then v_count := v_count + 1; end if;

  if v_count = 4 then
    raise notice 'PASS 35: العقود الأربعة ترفض البئر غير المُعيَّن بـ42501';
  else
    raise notice 'FAIL 35: % عقد فقط رفض البئر غير المُعيَّن', v_count;
  end if;

  -- حساب مزارع غير مرئي: الرفض بالصلاحية لا بحساب وهمي.
  v_other_account := gen_random_uuid();

  v_code := null;
  begin
    perform api.get_farmer_account(v_other_account);
  exception
    when others then
      v_code := sqlstate;
  end;

  if v_code = '42501' then
    raise notice 'PASS 36: حساب مزارع غير مرئي يُرفض بـ42501';
  else
    raise notice 'FAIL 36: رمز الخطأ % بدل 42501', coalesce(v_code, 'بلا');
  end if;

  -- ---------------------------------------------------------------
  -- 15. anon محجوب وقت التنفيذ لا في الجداول فقط
  -- ---------------------------------------------------------------

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role anon';

  v_count := 0;

  begin
    perform api.list_well_expenses(v_well);
  exception
    when insufficient_privilege then
      v_count := v_count + 1;
  end;

  begin
    perform api.list_well_partners(v_well);
  exception
    when insufficient_privilege then
      v_count := v_count + 1;
  end;

  begin
    perform api.list_well_profit_cycles(v_well);
  exception
    when insufficient_privilege then
      v_count := v_count + 1;
  end;

  begin
    perform api.get_farmer_account(v_account);
  exception
    when insufficient_privilege then
      v_count := v_count + 1;
  end;

  begin
    perform api.get_reports_summary(v_well, 'today');
  exception
    when insufficient_privilege then
      v_count := v_count + 1;
  end;

  execute 'reset role';

  if v_count = 5 then
    raise notice 'PASS 37: anon لا ينفّذ أيًّا من عقود المال الخمسة';
  else
    raise notice 'FAIL 37: anon نفّذ % عقدًا من 5', 5 - v_count;
  end if;
end;
$test$;

rollback;
