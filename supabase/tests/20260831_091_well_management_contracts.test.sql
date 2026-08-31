-- اختبار 091 — عقود إدارة البئر: قراءة وكتابة (م-41D1)
--
-- يثبّت: وجود العقود السبعة وتوقيعاتها، خصائص الأمان، ACL،
-- الأعمدة الثلاثة المضافة إلى core.wells، الرفض المغلق بالرموز،
-- وحدات قاعدة البيانات كما هي بلا تلفيق، وسلوك تعاقب جداول التسعير.

\set ON_ERROR_STOP on

begin;

do $test$
declare
  v_get_well oid := to_regprocedure('api.get_well_details(uuid)');
  v_upd_well oid := to_regprocedure(
    'api.update_well_details(uuid, text, text, numeric, numeric, text)'
  );
  v_pumps oid := to_regprocedure(
    'api.list_well_pumps_detail(uuid, boolean)'
  );
  v_save_pump oid := to_regprocedure(
    'api.save_well_pump(uuid, text, uuid, text, text, numeric, bigint, text, date, text)'
  );
  v_get_price oid := to_regprocedure(
    'api.get_active_price_schedule(uuid, timestamptz)'
  );
  v_new_price oid := to_regprocedure(
    'api.create_price_schedule(uuid, text, timestamptz, text, bigint, bigint, bigint)'
  );
  v_tanks oid := to_regprocedure(
    'api.list_well_fuel_tanks(uuid, boolean)'
  );
  v_all oid[];
  v_reads oid[];
  v_writes oid[];
  v_count integer;
  v_user uuid;
  v_profile uuid;
  v_tenant uuid;
  v_well uuid;
  v_other_well uuid;
  v_pump uuid;
  v_new_pump uuid;
  v_tank uuid;
  v_payload jsonb;
  v_item jsonb;
  v_code text;
  v_denied boolean;
  v_ok boolean;
begin

  v_reads := array[v_get_well, v_pumps, v_get_price, v_tanks];
  v_writes := array[v_upd_well, v_save_pump, v_new_price];
  v_all := v_reads || v_writes;

  -- ---------------------------------------------------------------
  -- 1. وجود العقود السبعة وإرجاعها jsonb
  -- ---------------------------------------------------------------

  select count(*)
  into v_count
  from unnest(v_all) as t(o)
  where t.o is not null
    and pg_get_function_result(t.o) = 'jsonb';

  if v_count = 7 then
    raise notice 'PASS 1: عقود إدارة البئر السبعة موجودة وتعيد jsonb';
  else
    raise notice 'FAIL 1: % عقد فقط من السبعة سليم', v_count;
  end if;


  -- ---------------------------------------------------------------
  -- 2. القراءة STABLE والكتابة VOLATILE، والكل INVOKER بـ search_path
  -- ---------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  where p.oid = any(v_reads)
    and p.prosecdef = false
    and p.provolatile = 's'
    and p.proconfig @> array['search_path=pg_catalog, pg_temp'];

  if v_count = 4 then
    raise notice 'PASS 2: عقود القراءة الأربعة INVOKER وSTABLE وsearch_path مثبت';
  else
    raise notice 'FAIL 2: خاصية أمان مفقودة في % من عقود القراءة', 4 - v_count;
  end if;

  select count(*)
  into v_count
  from pg_proc p
  where p.oid = any(v_writes)
    and p.prosecdef = false
    and p.provolatile = 'v'
    and p.proconfig @> array['search_path=pg_catalog, pg_temp'];

  if v_count = 3 then
    raise notice 'PASS 3: عقود الكتابة الثلاثة INVOKER وVOLATILE وsearch_path مثبت';
  else
    raise notice 'FAIL 3: خاصية أمان مفقودة في % من عقود الكتابة', 3 - v_count;
  end if;


  -- ---------------------------------------------------------------
  -- 3. ACL — authenticated وservice_role مسموحان وanon محجوب
  -- ---------------------------------------------------------------

  select count(*)
  into v_count
  from unnest(v_all) as t(o)
  where has_function_privilege('authenticated', t.o, 'EXECUTE')
    and has_function_privilege('service_role', t.o, 'EXECUTE')
    and not has_function_privilege('anon', t.o, 'EXECUTE');

  if v_count = 7 then
    raise notice 'PASS 4: ACL مطابق ق-78 على العقود السبعة — anon محجوب';
  else
    raise notice 'FAIL 4: صلاحيات التنفيذ غير مطابقة في % عقد', 7 - v_count;
  end if;


  -- ---------------------------------------------------------------
  -- 4. حدود مخطط api — لا SECURITY DEFINER ولا كائنات علائقية
  -- ---------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'api'
    and p.prosecdef;

  if v_count = 0 then
    raise notice 'PASS 5: مخطط api خالٍ من SECURITY DEFINER';
  else
    raise notice 'FAIL 5: يوجد % دالة SECURITY DEFINER داخل api', v_count;
  end if;

  select count(*)
  into v_count
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'api'
    and c.relkind in ('r', 'p', 'v', 'm', 'f');

  if v_count = 0 then
    raise notice 'PASS 6: مخطط api دوال فقط — لا جداول ولا Views';
  else
    raise notice 'FAIL 6: يوجد % كائن علائقي داخل api', v_count;
  end if;


  -- ---------------------------------------------------------------
  -- 5. Direct DML يبقى صفرًا بعد الأعمدة والعقود الجديدة
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
      has_table_privilege('anon', c.oid, 'INSERT')
      or has_table_privilege('anon', c.oid, 'UPDATE')
      or has_table_privilege('anon', c.oid, 'DELETE')
    );

  if v_count = 0 then
    raise notice 'PASS 7: anon بلا أي DML على المخططات الداخلية';
  else
    raise notice 'FAIL 7: anon يملك DML على % جدول داخلي', v_count;
  end if;


  -- ---------------------------------------------------------------
  -- 6. الأعمدة الثلاثة المضافة إلى core.wells موجودة وnullable
  -- ---------------------------------------------------------------

  select count(*)
  into v_count
  from information_schema.columns c
  where c.table_schema = 'core'
    and c.table_name = 'wells'
    and c.is_nullable = 'YES'
    and c.column_name in (
      'depth_meters',
      'static_water_level_meters',
      'notes'
    );

  if v_count = 3 then
    raise notice 'PASS 8: أعمدة البئر الفنية الثلاثة موجودة وnullable';
  else
    raise notice 'FAIL 8: % عمود فقط من الثلاثة موجود', v_count;
  end if;

  select count(*)
  into v_count
  from pg_constraint con
  where con.conrelid = 'core.wells'::regclass
    and con.contype = 'c'
    and con.conname in (
      'wells_depth_meters_check',
      'wells_static_water_level_check'
    );

  if v_count = 2 then
    raise notice 'PASS 9: قيدا العمق ومستوى الماء مثبتان';
  else
    raise notice 'FAIL 9: قيد ناقص على أعمدة البئر الجديدة';
  end if;


  -- ---------------------------------------------------------------
  -- 7. بيانات اختبار: بئر مُعيَّن للمالك وبئر آخر غير مُعيَّن
  -- ---------------------------------------------------------------

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at
  ) values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'well-mgmt-091@test.local',
    crypt('x', gen_salt('bf')),
    now(), now(), now()
  ) returning id into v_user;

  select id into v_profile from iam.profiles where id = v_user;

  if v_profile is null then
    raise exception '091: لم يُنشأ iam.profiles للمستخدم التجريبي';
  end if;

  insert into core.tenants (name)
  values ('جهة إدارة البئر 091')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name, location)
  values (v_tenant, 'بئر إدارة 091', 'موقع 091')
  returning id into v_well;

  insert into core.wells (tenant_id, name, location)
  values (v_tenant, 'بئر غير مُعيَّن 091', 'موقع 091-ب')
  returning id into v_other_well;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_well, v_profile, 'owner', 'active');

  insert into core.pumps (well_id, name, status, pump_type, power_rating)
  values (v_well, 'مضخة 091', 'active', 'submersible', '25 HP')
  returning id into v_pump;

  select ft.id
  into v_tank
  from inventory.fuel_tanks ft
  where ft.well_id = v_well
  order by ft.created_at, ft.id
  limit 1;

  if v_tank is null then
    raise exception '091: لم يُنشأ خزان وقود افتراضي للبئر';
  end if;

  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';


  -- ---------------------------------------------------------------
  -- 8. قراءة تفاصيل البئر — الغلاف والحقول
  -- ---------------------------------------------------------------

  v_payload := api.get_well_details(v_well);

  if v_payload ->> 'contract' = 'get_well_details'
     and (v_payload ->> 'version')::int = 1
     and v_payload -> 'well' ->> 'id' = v_well::text
     and v_payload -> 'well' ->> 'name' = 'بئر إدارة 091'
     and (v_payload -> 'well' -> 'has_open_session')::boolean = false
  then
    raise notice 'PASS 10: get_well_details يعيد غلافًا صحيحًا بلا جلسة جارية';
  else
    raise notice 'FAIL 10: غلاف أو حقول get_well_details غير مطابقة';
  end if;

  if v_payload -> 'well' ? 'depth_meters'
     and v_payload -> 'well' ? 'static_water_level_meters'
     and v_payload -> 'well' ? 'notes'
     and v_payload -> 'well' -> 'depth_meters' = 'null'::jsonb
  then
    raise notice 'PASS 11: الحقول الفنية الثلاثة معادة وقيمتها null قبل التحديث';
  else
    raise notice 'FAIL 11: الحقول الفنية غائبة أو ملفَّقة بقيمة صفر';
  end if;


  -- ---------------------------------------------------------------
  -- 9. تحديث بيانات البئر يُخزَّن فعلًا
  -- ---------------------------------------------------------------

  v_payload := api.update_well_details(
    v_well, 'بئر إدارة 091 معدّل', 'موقع محدّث',
    120.50, 45.25, 'ملاحظة تشغيلية'
  );

  if v_payload ->> 'contract' = 'update_well_details' then
    v_payload := api.get_well_details(v_well);

    if v_payload -> 'well' ->> 'name' = 'بئر إدارة 091 معدّل'
       and v_payload -> 'well' ->> 'location' = 'موقع محدّث'
       and (v_payload -> 'well' ->> 'depth_meters')::numeric = 120.50
       and (v_payload -> 'well' ->> 'static_water_level_meters')::numeric = 45.25
       and v_payload -> 'well' ->> 'notes' = 'ملاحظة تشغيلية'
    then
      raise notice 'PASS 12: تحديث بيانات البئر محفوظ ومقروء بنفس القيم';
    else
      raise notice 'FAIL 12: القيم المحدَّثة لم تُحفظ كما أُرسلت';
    end if;
  else
    raise notice 'FAIL 12: update_well_details لم يُعِد غلافًا صحيحًا';
  end if;


  -- ---------------------------------------------------------------
  -- 10. رفض المدخلات غير الصالحة في تحديث البئر
  -- ---------------------------------------------------------------

  v_code := null;
  begin
    perform api.update_well_details(v_well, '   ');
  exception
    when others then
      v_code := sqlstate;
  end;

  if v_code = '22023' then
    raise notice 'PASS 13: الاسم الفارغ مرفوض بـ22023 لا نجاح كاذب';
  else
    raise notice 'FAIL 13: الاسم الفارغ أعطى %', coalesce(v_code, 'نجاحًا');
  end if;

  v_code := null;
  begin
    perform api.update_well_details(v_well, 'اسم', null, -5, null, null);
  exception
    when others then
      v_code := sqlstate;
  end;

  if v_code = '22023' then
    raise notice 'PASS 14: العمق السالب مرفوض بـ22023';
  else
    raise notice 'FAIL 14: العمق السالب أعطى %', coalesce(v_code, 'نجاحًا');
  end if;

  v_code := null;
  begin
    perform api.update_well_details(null, 'اسم');
  exception
    when others then
      v_code := sqlstate;
  end;

  if v_code = '22023' then
    raise notice 'PASS 15: معرّف البئر الفارغ مرفوض بـ22023';
  else
    raise notice 'FAIL 15: معرّف البئر الفارغ أعطى %', coalesce(v_code, 'نجاحًا');
  end if;


  -- ---------------------------------------------------------------
  -- 11. قراءة المضخات بوحدات قاعدة البيانات لا بوحدات ملفَّقة
  -- ---------------------------------------------------------------

  v_payload := api.list_well_pumps_detail(v_well);
  v_item := v_payload -> 'items' -> 0;

  if v_payload ->> 'contract' = 'list_well_pumps_detail'
     and jsonb_array_length(v_payload -> 'items') = 1
     and v_item ->> 'id' = v_pump::text
     and v_item ->> 'power_rating' = '25 HP'
     and v_item ? 'estimated_water_flow_liters_per_minute'
     and v_item ? 'estimated_fuel_ml_per_hour'
     and (v_item -> 'is_in_open_session')::boolean = false
  then
    raise notice 'PASS 16: list_well_pumps_detail يعيد المضخة بأسماء ووحدات القاعدة';
  else
    raise notice 'FAIL 16: حقول المضخة غير مطابقة لقاعدة البيانات';
  end if;

  if not (v_item ? 'horsepower')
     and not (v_item ? 'flow_rate_lps')
     and not (v_item ? 'fuel_rate_lph')
  then
    raise notice 'PASS 17: لا حقول وحدات ملفَّقة (horsepower / lps / lph)';
  else
    raise notice 'FAIL 17: العقد يُعيد وحدة ملفَّقة غير موجودة في القاعدة';
  end if;


  -- ---------------------------------------------------------------
  -- 12. حفظ مضخة جديدة ثم تعديلها
  -- ---------------------------------------------------------------

  v_payload := api.save_well_pump(
    v_well, 'مضخة مضافة 091', null, 'surface', '18 HP',
    850.500, 4200, 'active', current_date, 'ملاحظة'
  );

  v_new_pump := (v_payload ->> 'pump_id')::uuid;

  if (v_payload -> 'created')::boolean = true
     and v_new_pump is not null
     and (
       select count(*)
       from core.pumps pm
       where pm.well_id = v_well
     ) = 2
  then
    raise notice 'PASS 18: save_well_pump أضاف مضخة فعلًا وأعاد created = true';
  else
    raise notice 'FAIL 18: إضافة المضخة لم تُنفَّذ أو الغلاف غير صحيح';
  end if;

  v_payload := api.save_well_pump(
    v_well, 'مضخة معدّلة 091', v_new_pump, 'surface', '20 HP',
    900.000, 4300, 'maintenance', current_date, null
  );

  select pm.name = 'مضخة معدّلة 091'
     and pm.status = 'maintenance'
     and pm.estimated_fuel_ml_per_hour = 4300
  into v_ok
  from core.pumps pm
  where pm.id = v_new_pump;

  if (v_payload -> 'created')::boolean = false and v_ok then
    raise notice 'PASS 19: مسار التعديل حدَّث المضخة وأعاد created = false';
  else
    raise notice 'FAIL 19: مسار تعديل المضخة لم يحفظ القيم';
  end if;

  v_code := null;
  begin
    perform api.save_well_pump(
      v_well, 'مضخة حالة خاطئة', null, null, null,
      null, null, 'running', null, null
    );
  exception
    when others then
      v_code := sqlstate;
  end;

  if v_code = '22023' then
    raise notice 'PASS 20: الحالة running مرفوضة صريحًا بلا ترجمة ضمنية';
  else
    raise notice 'FAIL 20: الحالة running أعطت %', coalesce(v_code, 'نجاحًا');
  end if;


  -- ---------------------------------------------------------------
  -- 13. التسعير — لا جدول ساري في البداية
  -- ---------------------------------------------------------------

  v_payload := api.get_active_price_schedule(v_well);

  if v_payload ->> 'contract' = 'get_active_price_schedule'
     and v_payload -> 'schedule' = 'null'::jsonb
     and jsonb_array_length(v_payload -> 'rules') = 0
  then
    raise notice 'PASS 21: غياب التسعير حالة صريحة null لا صفر مصطنع';
  else
    raise notice 'FAIL 21: قراءة التسعير الفارغ غير صحيحة';
  end if;


  -- ---------------------------------------------------------------
  -- 14. إنشاء جدول تسعير بثلاث قواعد
  -- ---------------------------------------------------------------

  v_payload := api.create_price_schedule(
    v_well, 'جدول 091 الأول', null, 'تهيئة أولى',
    1000, 2000, 1500
  );

  if v_payload ->> 'schedule_id' is not null then
    v_payload := api.get_active_price_schedule(v_well);

    if jsonb_array_length(v_payload -> 'rules') = 3
       and v_payload -> 'schedule' ->> 'status' = 'active'
    then
      raise notice 'PASS 22: جدول التسعير الجديد ساري بثلاث قواعد';
    else
      raise notice 'FAIL 22: قواعد التسعير غير مكتملة أو الجدول غير ساري';
    end if;

    select r ->> 'diesel_pricing_model' = 'inclusive_hourly'
       and (r ->> 'hourly_rate_minor')::bigint = 2000
    into v_ok
    from jsonb_array_elements(v_payload -> 'rules') as r
    where r ->> 'energy_source' = 'well_diesel';

    if coalesce(v_ok, false) then
      raise notice 'PASS 23: قاعدة well_diesel تحمل inclusive_hourly والسعر كما أُرسل';
    else
      raise notice 'FAIL 23: قاعدة well_diesel غير مطابقة لقيد 085';
    end if;
  else
    raise notice 'FAIL 22: create_price_schedule لم يُعِد معرّف جدول';
    raise notice 'FAIL 23: تعذر فحص قاعدة well_diesel';
  end if;

  v_code := null;
  begin
    perform api.create_price_schedule(
      v_well, 'جدول بأصفار', null, null, 0, 0, 0
    );
  exception
    when others then
      v_code := sqlstate;
  end;

  if v_code = '22023' then
    raise notice 'PASS 24: جدول تسعير بلا سعر واحد موجب مرفوض بـ22023';
  else
    raise notice 'FAIL 24: الجدول الصفري أعطى %', coalesce(v_code, 'نجاحًا');
  end if;


  -- ---------------------------------------------------------------
  -- 15. تعاقب الجداول: قصّ حدّ السابق بلا تراكب
  -- ---------------------------------------------------------------

  v_payload := api.create_price_schedule(
    v_well, 'جدول 091 الثاني', now() + interval '1 day',
    'مراجعة سعر', 1100, 2100, 1600
  );

  select count(*)
  into v_count
  from ops.price_schedules ps
  where ps.well_id = v_well
    and upper(ps.effective_period) is null;

  if v_count = 1 then
    raise notice 'PASS 25: جدول واحد فقط مفتوح النهاية بعد التعاقب';
  else
    raise notice 'FAIL 25: % جدول مفتوح النهاية — تراكب في التسعير', v_count;
  end if;

  v_payload := api.get_active_price_schedule(v_well);
  v_item := api.get_active_price_schedule(
    v_well, now() + interval '2 days'
  );

  if v_payload -> 'schedule' ->> 'name' = 'جدول 091 الأول'
     and v_item -> 'schedule' ->> 'name' = 'جدول 091 الثاني'
  then
    raise notice 'PASS 26: الجدول الساري يتبع اللحظة المطلوبة لا الأحدث إدخالًا';
  else
    raise notice 'FAIL 26: اختيار الجدول الساري غير مطابق لمحرك 066';
  end if;

  v_code := null;
  begin
    perform api.create_price_schedule(
      v_well, 'جدول متراكب', now(), null, 900, null, null
    );
  exception
    when others then
      v_code := sqlstate;
  end;

  if v_code = '22023' then
    raise notice 'PASS 27: تاريخ سريان متراكب مع جدول قائم مرفوض بـ22023';
  else
    raise notice 'FAIL 27: التاريخ المتراكب أعطى %', coalesce(v_code, 'نجاحًا');
  end if;


  -- ---------------------------------------------------------------
  -- 16. خزانات الوقود بالمليلتر وlast_measured_at مشتق
  -- ---------------------------------------------------------------

  v_payload := api.list_well_fuel_tanks(v_well);
  v_item := v_payload -> 'items' -> 0;

  if v_payload ->> 'contract' = 'list_well_fuel_tanks'
     and jsonb_array_length(v_payload -> 'items') >= 1
     and v_item ? 'capacity_ml'
     and v_item ? 'current_balance_ml'
     and v_item ? 'last_measured_at'
     and not (v_item ? 'capacity_liters')
     and not (v_item ? 'current_balance_liters')
  then
    raise notice 'PASS 28: الخزانات معادة بالمليلتر مع last_measured_at مشتق';
  else
    raise notice 'FAIL 28: حقول الخزان غير مطابقة لقاعدة البيانات';
  end if;

  if v_item -> 'last_measured_at' = 'null'::jsonb then
    raise notice 'PASS 29: last_measured_at = null قبل أي جرد فعلي';
  else
    raise notice 'FAIL 29: last_measured_at ملفَّق قبل وجود جرد';
  end if;


  -- ---------------------------------------------------------------
  -- 17. البئر غير المُعيَّن = رفض 42501 في القراءة والكتابة
  -- ---------------------------------------------------------------

  v_count := 0;

  v_code := null;
  begin
    perform api.get_well_details(v_other_well);
  exception
    when others then
      v_code := sqlstate;
  end;
  if v_code = '42501' then v_count := v_count + 1; end if;

  v_code := null;
  begin
    perform api.list_well_pumps_detail(v_other_well);
  exception
    when others then
      v_code := sqlstate;
  end;
  if v_code = '42501' then v_count := v_count + 1; end if;

  v_code := null;
  begin
    perform api.get_active_price_schedule(v_other_well);
  exception
    when others then
      v_code := sqlstate;
  end;
  if v_code = '42501' then v_count := v_count + 1; end if;

  v_code := null;
  begin
    perform api.list_well_fuel_tanks(v_other_well);
  exception
    when others then
      v_code := sqlstate;
  end;
  if v_code = '42501' then v_count := v_count + 1; end if;

  if v_count = 4 then
    raise notice 'PASS 30: عقود القراءة الأربعة ترفض البئر غير المُعيَّن بـ42501';
  else
    raise notice 'FAIL 30: % عقد قراءة فقط رفض البئر غير المُعيَّن', v_count;
  end if;

  v_count := 0;

  v_code := null;
  begin
    perform api.update_well_details(v_other_well, 'محاولة');
  exception
    when others then
      v_code := sqlstate;
  end;
  if v_code = '42501' then v_count := v_count + 1; end if;

  v_code := null;
  begin
    perform api.save_well_pump(v_other_well, 'مضخة دخيلة');
  exception
    when others then
      v_code := sqlstate;
  end;
  if v_code = '42501' then v_count := v_count + 1; end if;

  v_code := null;
  begin
    perform api.create_price_schedule(
      v_other_well, 'تسعير دخيل', null, null, 500, null, null
    );
  exception
    when others then
      v_code := sqlstate;
  end;
  if v_code = '42501' then v_count := v_count + 1; end if;

  if v_count = 3 then
    raise notice 'PASS 31: عقود الكتابة الثلاثة ترفض البئر غير المُعيَّن بـ42501';
  else
    raise notice 'FAIL 31: % عقد كتابة فقط رفض البئر غير المُعيَّن', v_count;
  end if;


  -- ---------------------------------------------------------------
  -- 18. anon محجوب فعليًا وقت التنفيذ لا في الجداول فقط
  -- ---------------------------------------------------------------

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role anon';

  v_denied := false;
  begin
    perform api.get_well_details(v_well);
  exception
    when insufficient_privilege then
      v_denied := true;
  end;

  execute 'reset role';

  if v_denied then
    raise notice 'PASS 32: anon لا يستطيع تنفيذ عقود إدارة البئر';
  else
    raise notice 'FAIL 32: anon نفّذ عقد إدارة بئر';
  end if;


  -- ---------------------------------------------------------------
  -- 19. أزواج الكتابة: الإجراء الداخلي DEFINER مع search_path مثبت
  --     (ق-79 يمنع أي كتابة من INVOKER)، والصلاحيتان الجديدتان
  --     موجودتان وممنوحتان للمالك وحده.
  -- ---------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where p.prokind = 'f'
    and (
      (n.nspname = 'core' and p.proname in (
        'update_well_details', 'save_well_pump'
      ))
      or (n.nspname = 'ops' and p.proname = 'create_price_schedule')
    )
    and p.prosecdef
    and p.provolatile = 'v'
    and exists (
      select 1
      from unnest(coalesce(p.proconfig, array[]::text[])) s
      where s like 'search_path=%'
    );

  if v_count = 3 then
    raise notice 'PASS 33: إجراءات الكتابة الثلاثة DEFINER بـsearch_path مثبت';
  else
    raise notice 'FAIL 33: % إجراء فقط من الثلاثة مطابق', v_count;
  end if;

  select count(*)
  into v_count
  from iam.permissions p
  join iam.role_permissions rp on rp.permission_id = p.id
  join iam.roles r on r.id = rp.role_id
  where p.code in ('well.update', 'pump.manage');

  if v_count = 2
     and (
       select count(*)
       from iam.permissions p
       join iam.role_permissions rp on rp.permission_id = p.id
       join iam.roles r on r.id = rp.role_id
       where p.code in ('well.update', 'pump.manage')
         and r.code = 'tenant_owner'
     ) = 2
  then
    raise notice 'PASS 34: well.update وpump.manage ممنوحتان للمالك وحده';
  else
    raise notice 'FAIL 34: منح الصلاحيتين الجديدتين غير مطابق (%)', v_count;
  end if;

end;
$test$;

rollback;
