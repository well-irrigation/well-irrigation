\set ON_ERROR_STOP on

begin;

do $test$
declare
  v_farmers oid := to_regprocedure('api.list_well_farmers(uuid, text, integer)');
  v_farms oid := to_regprocedure('api.list_well_farms(uuid, uuid)');
  v_pumps oid := to_regprocedure('api.list_well_pumps(uuid)');
  v_count integer;
  v_user uuid;
  v_profile uuid;
  v_tenant uuid;
  v_well uuid;
  v_other_well uuid;
  v_person_a uuid;
  v_person_b uuid;
  v_fp_a uuid;
  v_fp_b uuid;
  v_acc_a uuid;
  v_acc_b uuid;
  v_payload jsonb;
  v_denied boolean;
begin

  -- ---------------------------------------------------------------
  -- 1. وجود العقود الثلاثة وتوقيعها
  -- ---------------------------------------------------------------

  if v_farmers is not null
     and v_farms is not null
     and v_pumps is not null
     and pg_get_function_result(v_farmers) = 'jsonb'
     and pg_get_function_result(v_farms) = 'jsonb'
     and pg_get_function_result(v_pumps) = 'jsonb'
  then
    raise notice 'PASS 1: عقود القراءة الثلاثة موجودة وتعيد jsonb';
  else
    raise notice 'FAIL 1: عقد قراءة مفقود أو نوع الإرجاع خاطئ';
  end if;


  -- ---------------------------------------------------------------
  -- 2. INVOKER + STABLE + search_path آمن
  -- ---------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  where p.oid in (v_farmers, v_farms, v_pumps)
    and p.prosecdef = false
    and p.provolatile = 's'
    and p.proconfig @> array['search_path=pg_catalog, pg_temp'];

  if v_count = 3 then
    raise notice
      'PASS 2: العقود INVOKER وSTABLE وsearch_path مثبت على pg_catalog, pg_temp';
  else
    raise notice
      'FAIL 2: خاصية أمان مفقودة في % من العقود الثلاثة', 3 - v_count;
  end if;


  -- ---------------------------------------------------------------
  -- 3. ACL — authenticated/service_role مسموح وanon محجوب
  -- ---------------------------------------------------------------

  if has_function_privilege('authenticated', v_farmers, 'EXECUTE')
     and has_function_privilege('authenticated', v_farms, 'EXECUTE')
     and has_function_privilege('authenticated', v_pumps, 'EXECUTE')
     and has_function_privilege('service_role', v_farmers, 'EXECUTE')
     and has_function_privilege('service_role', v_farms, 'EXECUTE')
     and has_function_privilege('service_role', v_pumps, 'EXECUTE')
     and not has_function_privilege('anon', v_farmers, 'EXECUTE')
     and not has_function_privilege('anon', v_farms, 'EXECUTE')
     and not has_function_privilege('anon', v_pumps, 'EXECUTE')
  then
    raise notice 'PASS 3: ACL مطابق — anon محجوب على العقود الثلاثة';
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
  -- 5. Direct DML يبقى صفرًا على المخططات الداخلية
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
    raise notice 'PASS 6: Direct DML ما زال صفرًا بعد إضافة عقود القراءة';
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
    'ops-read-089@test.local',
    crypt('x', gen_salt('bf')),
    now(),
    now(),
    now()
  ) returning id into v_user;

  select id into v_profile from iam.profiles where id = v_user;

  if v_profile is null then
    raise exception '089: لم يُنشأ iam.profiles للمستخدم التجريبي';
  end if;

  insert into core.tenants (name)
  values ('جهة عقود القراءة 089')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name, location)
  values (v_tenant, 'بئر عقود القراءة', 'موقع 089')
  returning id into v_well;

  insert into core.wells (tenant_id, name, location)
  values (v_tenant, 'بئر غير مُعيَّن', 'موقع 089-ب')
  returning id into v_other_well;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_well, v_profile, 'owner', 'active');

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'أحمد المزارع', 'احمد المزارع')
  returning id into v_person_a;

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'بشير المزارع', 'بشير المزارع')
  returning id into v_person_b;

  insert into core.person_contacts (
    tenant_id, person_id, contact_type, contact_value,
    normalized_value, is_primary
  ) values
    (v_tenant, v_person_a, 'landline', '01234567', '01234567', false),
    (v_tenant, v_person_a, 'mobile', '+967711000089', '967711000089', true),
    (v_tenant, v_person_b, 'mobile', '+967722000089', '967722000089', true);

  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person_a)
  returning id into v_fp_a;

  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person_b)
  returning id into v_fp_b;

  insert into ops.farmer_well_accounts (
    tenant_id, farmer_profile_id, well_id, public_code
  ) values (v_tenant, v_fp_a, v_well, 'FA-089-A')
  returning id into v_acc_a;

  insert into ops.farmer_well_accounts (
    tenant_id, farmer_profile_id, well_id, public_code
  ) values (v_tenant, v_fp_b, v_well, 'FA-089-B')
  returning id into v_acc_b;

  insert into ops.farms (well_id, name, farmer_well_account_id, status)
  values
    (v_well, 'أرض أحمد', v_acc_a, 'active'),
    (v_well, 'أرض بشير', v_acc_b, 'active'),
    (v_well, 'أرض معطّلة', v_acc_b, 'inactive');

  insert into core.pumps (
    tenant_id, well_id, name, public_code, power_source, status
  ) values
    (v_tenant, v_well, 'مضخة أولى', 'P-089-1', 'diesel', 'active'),
    (v_tenant, v_well, 'مضخة متقاعدة', 'P-089-2', 'diesel', 'retired');

  raise notice 'PASS 7: بيانات الاختبار جاهزة على بئرين';


  -- ---------------------------------------------------------------
  -- 7. قراءة المزارعين بدور authenticated
  -- ---------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  select api.list_well_farmers(v_well) into v_payload;

  if v_payload ->> 'contract' = 'list_well_farmers'
     and (v_payload ->> 'version')::integer = 1
     and jsonb_array_length(v_payload -> 'items') = 2
     and v_payload -> 'items' -> 0 ->> 'full_name' = 'أحمد المزارع'
     and v_payload -> 'items' -> 0 ->> 'public_code' = 'FA-089-A'
  then
    raise notice 'PASS 8: قائمة المزارعين تعيد مزارعَي البئر بترتيب حتمي';
  else
    raise notice 'FAIL 8: استجابة غير متوقعة للمزارعين: %', v_payload;
  end if;


  -- الهاتف يُختار من جهة الاتصال الأساسية لا من أول صف
  if v_payload -> 'items' -> 0 ->> 'phone' = '+967711000089' then
    raise notice 'PASS 9: الهاتف مأخوذ من جهة الاتصال الأساسية';
  else
    raise notice 'FAIL 9: اختيار الهاتف خاطئ: %',
      v_payload -> 'items' -> 0 ->> 'phone';
  end if;


  -- ---------------------------------------------------------------
  -- 8. البحث يضيّق النتيجة (ق-88)
  -- ---------------------------------------------------------------

  select api.list_well_farmers(v_well, 'بشير') into v_payload;

  if jsonb_array_length(v_payload -> 'items') = 1
     and v_payload -> 'items' -> 0 ->> 'public_code' = 'FA-089-B'
  then
    raise notice 'PASS 10: البحث بالاسم يعيد المزارع المطابق فقط';
  else
    raise notice 'FAIL 10: البحث بالاسم غير صحيح: %', v_payload;
  end if;

  select api.list_well_farmers(v_well, '967722000089') into v_payload;

  if jsonb_array_length(v_payload -> 'items') = 1
     and v_payload -> 'items' -> 0 ->> 'public_code' = 'FA-089-B'
  then
    raise notice 'PASS 11: البحث بالرقم المطبّع يطابق جهة الاتصال';
  else
    raise notice 'FAIL 11: البحث بالرقم غير صحيح: %', v_payload;
  end if;


  -- ---------------------------------------------------------------
  -- 9. تثبيت الحد الأعلى للنتائج
  -- ---------------------------------------------------------------

  select api.list_well_farmers(v_well, null, 0) into v_payload;

  if jsonb_array_length(v_payload -> 'items') = 1 then
    raise notice 'PASS 12: الحد الأدنى مثبت على صف واحد بدل صفر';
  else
    raise notice 'FAIL 12: حد النتائج غير مثبت: %', v_payload;
  end if;

  -- ---------------------------------------------------------------
  -- 10. الأراضي — النشطة فقط، مع تصفية اختيارية بحساب المزارع
  -- ---------------------------------------------------------------

  select api.list_well_farms(v_well) into v_payload;

  if v_payload ->> 'contract' = 'list_well_farms'
     and jsonb_array_length(v_payload -> 'items') = 2
     and not (v_payload -> 'items')::text like '%أرض معطّلة%'
  then
    raise notice 'PASS 13: الأراضي النشطة فقط تظهر في العقد';
  else
    raise notice 'FAIL 13: استجابة الأراضي غير متوقعة: %', v_payload;
  end if;

  select api.list_well_farms(v_well, v_acc_a) into v_payload;

  if jsonb_array_length(v_payload -> 'items') = 1
     and v_payload -> 'items' -> 0 ->> 'name' = 'أرض أحمد'
     and v_payload -> 'items' -> 0 ->> 'farmer_well_account_id' = v_acc_a::text
  then
    raise notice 'PASS 14: تصفية الأراضي بحساب المزارع تعمل';
  else
    raise notice 'FAIL 14: تصفية الأراضي غير صحيحة: %', v_payload;
  end if;


  -- ---------------------------------------------------------------
  -- 11. المضخات — النشطة فقط
  -- ---------------------------------------------------------------

  select api.list_well_pumps(v_well) into v_payload;

  if v_payload ->> 'contract' = 'list_well_pumps'
     and jsonb_array_length(v_payload -> 'items') = 1
     and v_payload -> 'items' -> 0 ->> 'public_code' = 'P-089-1'
  then
    raise notice 'PASS 15: المضخات النشطة فقط تظهر في العقد';
  else
    raise notice 'FAIL 15: استجابة المضخات غير متوقعة: %', v_payload;
  end if;


  -- ---------------------------------------------------------------
  -- 12. Fail-closed على بئر غير مُعيَّن — رفض صريح لا قائمة فارغة
  -- ---------------------------------------------------------------

  v_denied := false;
  begin
    perform api.list_well_farmers(v_other_well);
  exception
    when insufficient_privilege then
      v_denied := true;
  end;

  if v_denied then
    raise notice 'PASS 16: البئر غير المرئي يُرفض بـ 42501 على المزارعين';
  else
    raise notice 'FAIL 16: بئر غير مُعيَّن أعاد نتيجة بدل الرفض';
  end if;

  v_denied := false;
  begin
    perform api.list_well_farms(v_other_well);
  exception
    when insufficient_privilege then
      v_denied := true;
  end;

  if v_denied then
    raise notice 'PASS 17: البئر غير المرئي يُرفض بـ 42501 على الأراضي';
  else
    raise notice 'FAIL 17: عقد الأراضي لم يفشل مغلقًا';
  end if;

  v_denied := false;
  begin
    perform api.list_well_pumps(v_other_well);
  exception
    when insufficient_privilege then
      v_denied := true;
  end;

  if v_denied then
    raise notice 'PASS 18: البئر غير المرئي يُرفض بـ 42501 على المضخات';
  else
    raise notice 'FAIL 18: عقد المضخات لم يفشل مغلقًا';
  end if;


  -- ---------------------------------------------------------------
  -- 13. المعرّف الفارغ يُرفض قبل أي قراءة
  -- ---------------------------------------------------------------

  v_denied := false;
  begin
    perform api.list_well_farmers(null);
  exception
    when invalid_parameter_value then
      v_denied := true;
  end;

  if v_denied then
    raise notice 'PASS 19: معرّف البئر الفارغ مرفوض بـ 22023';
  else
    raise notice 'FAIL 19: معرّف بئر فارغ قُبل';
  end if;

  execute 'reset role';


  -- ---------------------------------------------------------------
  -- 14. anon محجوب فعليًا عند التنفيذ
  -- ---------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role anon';

  v_denied := false;
  begin
    perform api.list_well_farmers(v_well);
  exception
    when insufficient_privilege then
      v_denied := true;
  end;

  execute 'reset role';

  if v_denied then
    raise notice 'PASS 20: anon لا يستطيع تنفيذ عقود القراءة';
  else
    raise notice 'FAIL 20: anon نفّذ عقد قراءة العمليات';
  end if;

end;
$test$;

rollback;
