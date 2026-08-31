\set ON_ERROR_STOP on

begin;

do $test$
declare
  v_list oid := to_regprocedure(
    'api.list_well_sessions(uuid, uuid, timestamptz, timestamptz, boolean, integer)'
  );
  v_detail oid := to_regprocedure('api.get_session_detail(uuid)');
  v_count integer;
  v_user uuid;
  v_profile uuid;
  v_tenant uuid;
  v_well uuid;
  v_other_well uuid;
  v_person uuid;
  v_person_b uuid;
  v_fp uuid;
  v_fp_b uuid;
  v_acc uuid;
  v_acc_b uuid;
  v_farm uuid;
  v_farm_b uuid;
  v_other_farm uuid;
  v_pump uuid;
  v_other_pump uuid;
  v_sess_a uuid;
  v_sess_b uuid;
  v_sess_c uuid;
  v_sess_d uuid;
  v_other_sess uuid;
  v_charge_a uuid;
  v_charge_b uuid;
  v_charge_c uuid;
  v_payload jsonb;
  v_item jsonb;
  v_seg jsonb;
  v_denied boolean;
begin

  -- ---------------------------------------------------------------
  -- 1. وجود العقدين وتوقيعهما
  -- ---------------------------------------------------------------

  if v_list is not null
     and v_detail is not null
     and pg_get_function_result(v_list) = 'jsonb'
     and pg_get_function_result(v_detail) = 'jsonb'
  then
    raise notice 'PASS 1: عقدا قراءة الجلسات موجودان ويعيدان jsonb';
  else
    raise notice 'FAIL 1: عقد قراءة جلسات مفقود أو نوع الإرجاع خاطئ';
  end if;


  -- ---------------------------------------------------------------
  -- 2. INVOKER + STABLE + search_path آمن
  -- ---------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  where p.oid in (v_list, v_detail)
    and p.prosecdef = false
    and p.provolatile = 's'
    and p.proconfig @> array['search_path=pg_catalog, pg_temp'];

  if v_count = 2 then
    raise notice
      'PASS 2: العقدان INVOKER وSTABLE وsearch_path مثبت على pg_catalog, pg_temp';
  else
    raise notice 'FAIL 2: خاصية أمان مفقودة في % من العقدين', 2 - v_count;
  end if;


  -- ---------------------------------------------------------------
  -- 3. ACL — authenticated/service_role مسموح وanon محجوب
  -- ---------------------------------------------------------------

  if has_function_privilege('authenticated', v_list, 'EXECUTE')
     and has_function_privilege('authenticated', v_detail, 'EXECUTE')
     and has_function_privilege('service_role', v_list, 'EXECUTE')
     and has_function_privilege('service_role', v_detail, 'EXECUTE')
     and not has_function_privilege('anon', v_list, 'EXECUTE')
     and not has_function_privilege('anon', v_detail, 'EXECUTE')
  then
    raise notice 'PASS 3: ACL مطابق — anon محجوب على عقدي الجلسات';
  else
    raise notice 'FAIL 3: صلاحيات التنفيذ غير مطابقة لق-78';
  end if;


  -- ---------------------------------------------------------------
  -- 4. حدود مخطط api — لا SECURITY DEFINER ولا جداول/Views
  -- ---------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'api'
    and p.prosecdef;

  if v_count = 0 then
    raise notice 'PASS 4: مخطط api خالٍ من SECURITY DEFINER';
  else
    raise notice 'FAIL 4: يوجد % دالة SECURITY DEFINER داخل api', v_count;
  end if;

  select count(*)
  into v_count
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'api'
    and c.relkind in ('r', 'p', 'v', 'm', 'f');

  if v_count = 0 then
    raise notice 'PASS 5: مخطط api دوال فقط — لا جداول ولا Views';
  else
    raise notice 'FAIL 5: يوجد % كائن علائقي داخل api', v_count;
  end if;


  -- ---------------------------------------------------------------
  -- 5. Direct DML يبقى صفرًا
  -- ---------------------------------------------------------------

  select count(*)
  into v_count
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where c.relkind in ('r', 'p')
    and n.nspname in (
      'core', 'iam', 'ops', 'billing',
      'finance', 'inventory'
    )
    and (
      has_table_privilege('authenticated', c.oid, 'INSERT')
      or has_table_privilege('authenticated', c.oid, 'UPDATE')
      or has_table_privilege('authenticated', c.oid, 'DELETE')
      or has_table_privilege('anon', c.oid, 'INSERT')
      or has_table_privilege('anon', c.oid, 'UPDATE')
      or has_table_privilege('anon', c.oid, 'DELETE')
    );

  if v_count = 0 then
    raise notice 'PASS 6: Direct DML ما زال صفرًا بعد عقود الجلسات';
  else
    raise notice 'FAIL 6: Direct DML توسّع إلى % جدول داخلي', v_count;
  end if;

  -- ---------------------------------------------------------------
  -- 6. بيانات اختبار: بئر مُعيَّن وبئر آخر غير مُعيَّن
  -- ---------------------------------------------------------------

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at
  ) values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'session-read-090@test.local',
    crypt('x', gen_salt('bf')),
    now(), now(), now()
  ) returning id into v_user;

  select id into v_profile from iam.profiles where id = v_user;

  if v_profile is null then
    raise exception '090: لم يُنشأ iam.profiles للمستخدم التجريبي';
  end if;

  insert into core.tenants (name)
  values ('جهة عقود الجلسات 090')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name, location)
  values (v_tenant, 'بئر عقود الجلسات', 'موقع 090')
  returning id into v_well;

  insert into core.wells (tenant_id, name, location)
  values (v_tenant, 'بئر غير مُعيَّن 090', 'موقع 090-ب')
  returning id into v_other_well;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_well, v_profile, 'owner', 'active');

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'سالم المزارع', 'سالم المزارع')
  returning id into v_person;

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'ناصر المزارع', 'ناصر المزارع')
  returning id into v_person_b;

  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person)
  returning id into v_fp;

  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person_b)
  returning id into v_fp_b;

  insert into ops.farmer_well_accounts (
    tenant_id, farmer_profile_id, well_id, public_code
  ) values (v_tenant, v_fp, v_well, 'FA-090-A')
  returning id into v_acc;

  insert into ops.farmer_well_accounts (
    tenant_id, farmer_profile_id, well_id, public_code
  ) values (v_tenant, v_fp_b, v_well, 'FA-090-B')
  returning id into v_acc_b;

  insert into ops.farms (well_id, name, farmer_well_account_id, status)
  values (v_well, 'أرض سالم', v_acc, 'active')
  returning id into v_farm;

  insert into ops.farms (well_id, name, farmer_well_account_id, status)
  values (v_well, 'أرض ناصر', v_acc_b, 'active')
  returning id into v_farm_b;

  insert into ops.farms (well_id, name, status)
  values (v_other_well, 'أرض بئر آخر', 'active')
  returning id into v_other_farm;

  insert into core.pumps (
    tenant_id, well_id, name, public_code, power_source, status
  ) values (v_tenant, v_well, 'مضخة 090', 'P-090-1', 'diesel', 'active')
  returning id into v_pump;

  insert into core.pumps (
    tenant_id, well_id, name, public_code, power_source, status
  ) values (v_tenant, v_other_well, 'مضخة أخرى', 'P-090-2', 'diesel', 'active')
  returning id into v_other_pump;

  -- أربع جلسات مغلقة تغطي الحالات المالية الأربع، وجلسة خامسة على
  -- بئر غير مُعيَّن لإثبات الفشل المغلق.
  insert into ops.irrigation_sessions (
    well_id, pump_id, farm_id, farmer_well_account_id,
    operator_profile_id, started_at, ended_at, status
  ) values (
    v_well, v_pump, v_farm, v_acc, v_profile,
    now() - interval '2 hours', now() - interval '1 hour', 'closed'
  ) returning id into v_sess_a;

  insert into ops.irrigation_sessions (
    well_id, pump_id, farm_id, farmer_well_account_id,
    operator_profile_id, started_at, ended_at, status
  ) values (
    v_well, v_pump, v_farm_b, v_acc_b, v_profile,
    now() - interval '4 hours', now() - interval '2 hours', 'closed'
  ) returning id into v_sess_b;

  insert into ops.irrigation_sessions (
    well_id, pump_id, farm_id, farmer_well_account_id,
    operator_profile_id, started_at, ended_at, status
  ) values (
    v_well, v_pump, v_farm, v_acc, v_profile,
    now() - interval '6 hours', now() - interval '5 hours', 'closed'
  ) returning id into v_sess_c;

  insert into ops.irrigation_sessions (
    well_id, pump_id, farm_id, farmer_well_account_id,
    operator_profile_id, started_at, ended_at, status
  ) values (
    v_well, v_pump, v_farm, v_acc, v_profile,
    now() - interval '10 days',
    now() - interval '10 days' + interval '1 hour',
    'closed'
  ) returning id into v_sess_d;

  insert into ops.irrigation_sessions (
    well_id, pump_id, farm_id,
    operator_profile_id, started_at, ended_at, status
  ) values (
    v_other_well, v_other_pump, v_other_farm, v_profile,
    now() - interval '3 hours', now() - interval '2 hours', 'closed'
  ) returning id into v_other_sess;

  -- تكاليف الجلسات كما تُخزّن فعليًا؛ العقد يقرأها ولا يعيد حسابها.
  insert into billing.session_charges (
    session_id, well_id, duration_seconds,
    price_per_hour_minor, amount_minor
  ) values (v_sess_a, v_well, 3600, 3500, 3500)
  returning id into v_charge_a;

  insert into billing.session_charges (
    session_id, well_id, duration_seconds,
    price_per_hour_minor, amount_minor
  ) values (v_sess_b, v_well, 7200, 3500, 7000)
  returning id into v_charge_b;

  insert into billing.session_charges (
    session_id, well_id, duration_seconds,
    price_per_hour_minor, amount_minor
  ) values (v_sess_c, v_well, 3600, 3500, 3500)
  returning id into v_charge_c;

  -- الفاتورة هي المصدر الحاكم للمدفوع حين توجد (ق-99 + الملف 068).
  insert into billing.invoices (
    tenant_id, public_code, well_id, farmer_well_account_id,
    session_id, invoice_date, status,
    subtotal_minor, total_minor, paid_minor, outstanding_minor
  ) values (
    v_tenant, 'INV-090-A', v_well, v_acc,
    v_sess_a, now() - interval '1 hour', 'draft',
    3500, 3500, 3500, 0
  );

  insert into billing.invoices (
    tenant_id, public_code, well_id, farmer_well_account_id,
    session_id, invoice_date, status,
    subtotal_minor, total_minor, paid_minor, outstanding_minor
  ) values (
    v_tenant, 'INV-090-B', v_well, v_acc_b,
    v_sess_b, now() - interval '2 hours', 'draft',
    7000, 7000, 3000, 4000
  );

  -- مقاطع الجلسة أ: مقطع تشغيل شمسي ثم توقف مشغّل غير قابل للفوترة.
  insert into ops.session_segments (
    tenant_id, session_id, sequence_number, segment_type, energy_source,
    started_at, ended_at, actual_seconds, billable_seconds, is_billable,
    applied_hourly_rate_minor,
    time_charge_minor, fuel_charge_minor, total_charge_minor
  ) values (
    v_tenant, v_sess_a, 1, 'solar_run', 'solar',
    now() - interval '2 hours',
    now() - interval '2 hours' + interval '50 minutes',
    3000, 3000, true,
    3500,
    2917, 0, 2917
  );

  insert into ops.session_segments (
    tenant_id, session_id, sequence_number, segment_type, energy_source,
    started_at, ended_at, actual_seconds, billable_seconds, is_billable,
    time_charge_minor, fuel_charge_minor, total_charge_minor, notes
  ) values (
    v_tenant, v_sess_a, 2, 'operator_pause', null,
    now() - interval '2 hours' + interval '50 minutes',
    now() - interval '1 hour',
    600, 0, false,
    0, 0, 0, 'operator_pause'
  );

  raise notice 'PASS 7: بيانات الاختبار جاهزة — 4 جلسات مرئية وجلسة على بئر آخر';


  -- ---------------------------------------------------------------
  -- 7. قراءة السجل بدور authenticated
  -- ---------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  select api.list_well_sessions(v_well) into v_payload;

  if v_payload ->> 'contract' = 'list_well_sessions'
     and (v_payload ->> 'version')::integer = 1
     and jsonb_array_length(v_payload -> 'items') = 4
     and v_payload -> 'items' -> 0 ->> 'id' = v_sess_a::text
     and v_payload -> 'items' -> 3 ->> 'id' = v_sess_d::text
  then
    raise notice 'PASS 8: السجل يعيد جلسات البئر بترتيب started_at تنازليًا';
  else
    raise notice 'FAIL 8: استجابة السجل غير متوقعة: %', v_payload;
  end if;

  -- ---------------------------------------------------------------
  -- 8. حالات السداد الأربع مقروءة كما خُزّنت — لا حساب داخل العقد
  -- ---------------------------------------------------------------

  v_item := v_payload -> 'items' -> 0;

  if v_item ->> 'payment_status' = 'settled'
     and (v_item ->> 'total_amount_minor')::bigint = 3500
     and (v_item ->> 'paid_amount_minor')::bigint = 3500
     and (v_item ->> 'billable_seconds')::bigint = 3600
     and v_item ->> 'farmer_public_code' = 'FA-090-A'
     and v_item ->> 'farmer_name' = 'سالم المزارع'
     and v_item ->> 'farm_name' = 'أرض سالم'
     and v_item ->> 'pump_name' = 'مضخة 090'
     and v_item ->> 'energy_source' = 'solar'
  then
    raise notice 'PASS 9: الجلسة المسدّدة تُقرأ من الفاتورة كما خُزّنت';
  else
    raise notice 'FAIL 9: قراءة الجلسة المسدّدة خاطئة: %', v_item;
  end if;

  v_item := v_payload -> 'items' -> 1;

  if v_item ->> 'payment_status' = 'partial'
     and (v_item ->> 'total_amount_minor')::bigint = 7000
     and (v_item ->> 'paid_amount_minor')::bigint = 3000
     and v_item ->> 'farmer_public_code' = 'FA-090-B'
  then
    raise notice 'PASS 10: الجلسة المسدّدة جزئيًا تعيد partial بالمبلغ المخزّن';
  else
    raise notice 'FAIL 10: قراءة السداد الجزئي خاطئة: %', v_item;
  end if;

  v_item := v_payload -> 'items' -> 2;

  if v_item ->> 'payment_status' = 'unpaid'
     and (v_item ->> 'total_amount_minor')::bigint = 3500
     and (v_item ->> 'paid_amount_minor')::bigint = 0
     and (v_item ->> 'has_charge')::boolean
     and not (v_item ->> 'has_invoice')::boolean
  then
    raise notice 'PASS 11: الجلسة المفوترة بلا دفعات تعيد unpaid وصفرًا مخزّنًا';
  else
    raise notice 'FAIL 11: قراءة الجلسة غير المسدّدة خاطئة: %', v_item;
  end if;

  v_item := v_payload -> 'items' -> 3;

  if v_item ->> 'payment_status' = 'not_billed'
     and v_item -> 'total_amount_minor' = 'null'::jsonb
     and v_item -> 'paid_amount_minor' = 'null'::jsonb
     and not (v_item ->> 'has_charge')::boolean
  then
    raise notice 'PASS 12: الجلسة غير المفوترة تعيد null وnot_billed لا صفرًا مصطنعًا';
  else
    raise notice 'FAIL 12: الجلسة غير المفوترة أعادت مبلغًا مخترعًا: %', v_item;
  end if;

  -- ---------------------------------------------------------------
  -- 9. المرشّحات: حساب المزارع، غير المسدّد، النافذة الزمنية، الحد
  -- ---------------------------------------------------------------

  select api.list_well_sessions(v_well, v_acc_b) into v_payload;

  if jsonb_array_length(v_payload -> 'items') = 1
     and v_payload -> 'items' -> 0 ->> 'id' = v_sess_b::text
  then
    raise notice 'PASS 13: تصفية السجل بحساب المزارع تعمل';
  else
    raise notice 'FAIL 13: تصفية حساب المزارع خاطئة: %', v_payload;
  end if;

  select api.list_well_sessions(v_well, null, null, null, true) into v_payload;

  if jsonb_array_length(v_payload -> 'items') = 3
     and not (v_payload -> 'items')::text like '%' || v_sess_a::text || '%'
  then
    raise notice 'PASS 14: مرشّح غير المسدّد يستثني الجلسة المسدّدة فقط';
  else
    raise notice 'FAIL 14: مرشّح غير المسدّد خاطئ: %', v_payload;
  end if;

  select api.list_well_sessions(
    v_well, null, now() - interval '1 day', now()
  ) into v_payload;

  if jsonb_array_length(v_payload -> 'items') = 3
     and not (v_payload -> 'items')::text like '%' || v_sess_d::text || '%'
  then
    raise notice 'PASS 15: النافذة الزمنية الصريحة تستثني ما قبلها';
  else
    raise notice 'FAIL 15: النافذة الزمنية غير مطبّقة: %', v_payload;
  end if;

  select api.list_well_sessions(v_well, null, null, null, false, 0)
  into v_payload;

  if jsonb_array_length(v_payload -> 'items') = 1 then
    raise notice 'PASS 16: حد النتائج مثبت على صف واحد بدل صفر';
  else
    raise notice 'FAIL 16: حد النتائج غير مثبت: %', v_payload;
  end if;

  -- ---------------------------------------------------------------
  -- 10. تفصيل الجلسة ومقاطعها بالأعمدة الحقيقية
  -- ---------------------------------------------------------------

  select api.get_session_detail(v_sess_a) into v_payload;

  if v_payload ->> 'contract' = 'get_session_detail'
     and (v_payload ->> 'version')::integer = 1
     and v_payload -> 'session' ->> 'id' = v_sess_a::text
     and v_payload -> 'session' ->> 'payment_status' = 'settled'
     and (v_payload -> 'session' ->> 'total_amount_minor')::bigint = 3500
     and jsonb_array_length(v_payload -> 'segments') = 2
  then
    raise notice 'PASS 17: تفصيل الجلسة يعيد مغلّفًا كاملًا بمقطعين';
  else
    raise notice 'FAIL 17: تفصيل الجلسة غير متوقع: %', v_payload;
  end if;

  v_seg := v_payload -> 'segments' -> 0;

  if (v_seg ->> 'sequence_number')::integer = 1
     and v_seg ->> 'segment_type' = 'solar_run'
     and v_seg ->> 'energy_source' = 'solar'
     and not (v_seg ->> 'is_stop')::boolean
     and (v_seg ->> 'is_billable')::boolean
     and (v_seg ->> 'actual_seconds')::bigint = 3000
     and (v_seg ->> 'billable_seconds')::bigint = 3000
     and (v_seg ->> 'applied_rate_minor')::bigint = 3500
     and (v_seg ->> 'time_charge_minor')::bigint = 2917
     and (v_seg ->> 'total_charge_minor')::bigint = 2917
  then
    raise notice 'PASS 18: مقطع التشغيل يُقرأ بأعمدة الثواني والمبالغ المخزّنة';
  else
    raise notice 'FAIL 18: تخطيط مقطع التشغيل خاطئ: %', v_seg;
  end if;

  v_seg := v_payload -> 'segments' -> 1;

  if v_seg ->> 'segment_type' = 'operator_pause'
     and (v_seg ->> 'is_stop')::boolean
     and not (v_seg ->> 'is_billable')::boolean
     and v_seg -> 'energy_source' = 'null'::jsonb
     and v_seg ->> 'notes' = 'operator_pause'
     and (v_seg ->> 'billable_seconds')::bigint = 0
  then
    raise notice 'PASS 19: مقطع التوقف يُستنتج من segment_type ورمزه يُعاد كما هو';
  else
    raise notice 'FAIL 19: تخطيط مقطع التوقف خاطئ: %', v_seg;
  end if;

  select api.get_session_detail(v_sess_d) into v_payload;

  if v_payload -> 'session' ->> 'payment_status' = 'not_billed'
     and v_payload -> 'session' -> 'total_amount_minor' = 'null'::jsonb
     and v_payload -> 'payment' = 'null'::jsonb
     and jsonb_array_length(v_payload -> 'segments') = 0
  then
    raise notice 'PASS 20: تفصيل الجلسة غير المفوترة يعيد null بلا دفعة مخترعة';
  else
    raise notice 'FAIL 20: تفصيل الجلسة غير المفوترة خاطئ: %', v_payload;
  end if;


  -- ---------------------------------------------------------------
  -- 11. الفشل المغلق: بئر/جلسة غير مرئية ومعرّف فارغ
  -- ---------------------------------------------------------------

  v_denied := false;
  begin
    perform api.get_session_detail(v_other_sess);
  exception
    when insufficient_privilege then
      v_denied := true;
  end;

  if v_denied then
    raise notice 'PASS 21: جلسة بئر غير مُعيَّن تُرفض بـ 42501';
  else
    raise notice 'FAIL 21: تفصيل جلسة غير مرئية أعاد بيانات';
  end if;

  v_denied := false;
  begin
    perform api.list_well_sessions(v_other_well);
  exception
    when insufficient_privilege then
      v_denied := true;
  end;

  if v_denied then
    raise notice 'PASS 22: سجل بئر غير مُعيَّن يُرفض بـ 42501';
  else
    raise notice 'FAIL 22: سجل بئر غير مُعيَّن أعاد نتيجة';
  end if;

  v_denied := false;
  begin
    perform api.list_well_sessions(null);
  exception
    when invalid_parameter_value then
      v_denied := true;
  end;

  if v_denied then
    raise notice 'PASS 23: معرّف البئر الفارغ مرفوض بـ 22023';
  else
    raise notice 'FAIL 23: معرّف بئر فارغ قُبل في السجل';
  end if;

  v_denied := false;
  begin
    perform api.get_session_detail(null);
  exception
    when invalid_parameter_value then
      v_denied := true;
  end;

  if v_denied then
    raise notice 'PASS 24: معرّف الجلسة الفارغ مرفوض بـ 22023';
  else
    raise notice 'FAIL 24: معرّف جلسة فارغ قُبل في التفصيل';
  end if;

  execute 'reset role';


  -- ---------------------------------------------------------------
  -- 12. anon محجوب فعليًا عند التنفيذ
  -- ---------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role anon';

  v_denied := false;
  begin
    perform api.list_well_sessions(v_well);
  exception
    when insufficient_privilege then
      v_denied := true;
  end;

  if v_denied then
    v_denied := false;
    begin
      perform api.get_session_detail(v_sess_a);
    exception
      when insufficient_privilege then
        v_denied := true;
    end;
  end if;

  execute 'reset role';

  if v_denied then
    raise notice 'PASS 25: anon لا يستطيع تنفيذ عقدي قراءة الجلسات';
  else
    raise notice 'FAIL 25: anon نفّذ أحد عقدي قراءة الجلسات';
  end if;

end;
$test$;

rollback;
