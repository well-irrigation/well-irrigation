begin;

set local timezone to 'UTC';

-- =====================================================================
-- اختبار الهجرة 102 — منع إنشاء هوية مزارع عند وجود مرشح يحتاج حسمًا
-- القرار: ق-84، ق-88، ق-89، ق-113، ق-114
-- =====================================================================

do $test$
declare
  v_count bigint;
  v_count_2 bigint;
  v_before bigint;
  v_after bigint;
  v_people_before bigint;
  v_profiles_before bigint;
  v_accounts_before bigint;
  v_tenant uuid;
  v_other_tenant uuid;
  v_user uuid;
  v_profile uuid;
  v_intruder uuid;
  v_well uuid;
  v_person uuid;
  v_account uuid;
  v_historical_1 uuid;
  v_historical_2 uuid;
  v_command uuid;
  v_res_command uuid;
  v_res_cmd_conflict uuid;
  v_cmd_candidate_test uuid;
  v_cmd_phone_test uuid;
  v_cmd_nophone_test uuid;
  v_candidate_person uuid;
  v_candidate_account uuid;
  v_other_person uuid;
  v_diff_person uuid;
  v_diff_account uuid;
  v_result jsonb;
  v_result_2 jsonb;
  v_res_result jsonb;
  v_res_result_2 jsonb;
  v_conflict jsonb;
  v_message text;
begin
  -- ============================================================
  -- 1. العقد العام، SECURITY INVOKER، المنح، والقفل الداخلي
  -- ============================================================

  select count(*), count(*) filter (
    where pg_get_function_identity_arguments(p.oid) =
      'p_well_id uuid, p_full_name text, p_phone text, p_preferred_name text, p_notes text, p_credit_limit_minor bigint, p_command_id uuid'
      and not p.prosecdef
  )
  into v_count, v_count_2
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'api' and p.proname = 'create_farmer';

  if v_count = 1 and v_count_2 = 1 then
    raise notice 'PASS 1: api.create_farmer له توقيع واحد ويبقى SECURITY INVOKER';
  else
    raise notice 'FAIL 1: توقيعات api.create_farmer=% والعقد الآمن=%', v_count, v_count_2;
  end if;

  if not has_function_privilege(
       'anon',
       'api.create_farmer(uuid,text,text,text,text,bigint,uuid)',
       'EXECUTE'
     )
     and has_function_privilege(
       'authenticated',
       'api.create_farmer(uuid,text,text,text,text,bigint,uuid)',
       'EXECUTE'
     )
     and has_function_privilege(
       'service_role',
       'api.create_farmer(uuid,text,text,text,text,bigint,uuid)',
       'EXECUTE'
     )
  then
    raise notice 'PASS 2: api.create_farmer محجوبة عن anon وممنوحة للأدوار المعتمدة فقط';
  else
    raise notice 'FAIL 2: منح api.create_farmer غير صحيحة';
  end if;

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'ops'
    and p.proname = 'lock_farmer_identity'
    and pg_get_function_identity_arguments(p.oid) =
      'p_tenant_id uuid, p_normalized_name text, p_normalized_phone text'
    and p.prosecdef;

  if v_count = 1
     and not has_function_privilege(
       'anon', 'ops.lock_farmer_identity(uuid,text,text)', 'EXECUTE'
     )
     and not has_function_privilege(
       'authenticated', 'ops.lock_farmer_identity(uuid,text,text)', 'EXECUTE'
     )
     and not has_function_privilege(
       'service_role', 'ops.lock_farmer_identity(uuid,text,text)', 'EXECUTE'
     )
  then
    raise notice 'PASS 3: قفل هوية المزارع داخلي ومحجوب عن أدوار العميل';
  else
    raise notice 'FAIL 3: عقد أو منح قفل هوية المزارع غير صحيحة';
  end if;

  select count(*), count(*) filter (
    where pg_get_function_identity_arguments(p.oid) =
      'p_well_id uuid, p_original_command_id uuid, p_resolution_action text, p_command_id uuid, p_selected_person_id uuid, p_full_name text, p_phone text, p_preferred_name text, p_notes text, p_credit_limit_minor bigint'
      and not p.prosecdef
  )
  into v_count, v_count_2
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'api' and p.proname = 'resolve_farmer_identity';

  if v_count = 1 and v_count_2 = 1 then
    raise notice 'PASS 3b: api.resolve_farmer_identity له توقيع واحد ويبقى SECURITY INVOKER';
  else
    raise notice 'FAIL 3b: توقيعات api.resolve_farmer_identity=% والعقد الآمن=%', v_count, v_count_2;
  end if;

  if not has_function_privilege(
       'anon',
       'api.resolve_farmer_identity(uuid,uuid,text,uuid,uuid,text,text,text,text,bigint)',
       'EXECUTE'
     )
     and has_function_privilege(
       'authenticated',
       'api.resolve_farmer_identity(uuid,uuid,text,uuid,uuid,text,text,text,text,bigint)',
       'EXECUTE'
     )
     and has_function_privilege(
       'service_role',
       'api.resolve_farmer_identity(uuid,uuid,text,uuid,uuid,text,text,text,text,bigint)',
       'EXECUTE'
     )
     and not has_function_privilege(
       'anon',
       'ops.resolve_farmer_identity(uuid,uuid,text,uuid,text,text,text,text,bigint)',
       'EXECUTE'
     )
     and has_function_privilege(
       'authenticated',
       'ops.resolve_farmer_identity(uuid,uuid,text,uuid,text,text,text,text,bigint)',
       'EXECUTE'
     )
     and has_function_privilege(
       'service_role',
       'ops.resolve_farmer_identity(uuid,uuid,text,uuid,text,text,text,text,bigint)',
       'EXECUTE'
     )
  then
    raise notice 'PASS 3c: منح api.resolve_farmer_identity و ops.resolve_farmer_identity محكمة';
  else
    raise notice 'FAIL 3c: منح حسم هوية المزارع غير صحيحة';
  end if;

  -- ============================================================
  -- 2. بيانات الاختبار وقياس أن مفاتيح القفل تراعي الجهة
  -- ============================================================

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  ) values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'm102-owner@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  ) returning id into v_user;

  select id into v_profile from iam.profiles where id = v_user;
  if not found then
    insert into iam.profiles (id, full_name)
    values (v_user, 'مالك اختبار هوية المزارع')
    returning id into v_profile;
  end if;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  ) values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'm102-intruder@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  ) returning id into v_intruder;

  insert into core.tenants (name)
  values ('جهة اختبار هوية المزارع')
  returning id into v_tenant;

  insert into core.tenants (name)
  values ('جهة أخرى لاختبار القفل')
  returning id into v_other_tenant;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'بئر اختبار هوية المزارع')
  returning id into v_well;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_well, v_profile, 'owner', 'active');

  select count(*) into v_before
  from pg_locks
  where pid = pg_backend_pid() and locktype = 'advisory';

  perform ops.lock_farmer_identity(v_tenant, 'اسم قفل', '711111111');

  select count(*) into v_after
  from pg_locks
  where pid = pg_backend_pid() and locktype = 'advisory';

  if v_after - v_before = 2 then
    raise notice 'PASS 4: الاسم والهاتف ينتجان قفلين معامليين مستقلين';
  else
    raise notice 'FAIL 4: عدد أقفال الاسم والهاتف الجديدة=%', v_after - v_before;
  end if;

  v_before := v_after;
  perform ops.lock_farmer_identity(v_other_tenant, 'اسم قفل', '711111111');

  select count(*) into v_after
  from pg_locks
  where pid = pg_backend_pid() and locktype = 'advisory';

  if v_after - v_before = 2 then
    raise notice 'PASS 5: مفاتيح قفل الهوية تراعي tenant_id';
  else
    raise notice 'FAIL 5: الجهة الأخرى لم تنتج مفاتيح مستقلة؛ الفرق=%', v_after - v_before;
  end if;

  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  -- ============================================================
  -- 3. لا مرشح: إنشاء هوية واحدة كاملة
  -- ============================================================

  select count(*) into v_people_before
  from core.persons where tenant_id = v_tenant;
  select count(*) into v_profiles_before
  from ops.farmer_profiles where tenant_id = v_tenant;
  select count(*) into v_accounts_before
  from ops.farmer_well_accounts where tenant_id = v_tenant;

  v_result := api.create_farmer(
    p_well_id => v_well,
    p_full_name => 'أحمد علي',
    p_phone => '+967 777-111-222'
  );

  v_person := (v_result ->> 'person_id')::uuid;
  v_account := (v_result ->> 'farmer_well_account_id')::uuid;

  if v_result ->> 'status' = 'created'
     and coalesce((v_result ->> 'already_exists')::boolean, true) = false
     and (select count(*) from core.persons where tenant_id = v_tenant) = v_people_before + 1
     and (select count(*) from ops.farmer_profiles where tenant_id = v_tenant) = v_profiles_before + 1
     and (select count(*) from ops.farmer_well_accounts where tenant_id = v_tenant) = v_accounts_before + 1
  then
    raise notice 'PASS 6: عدم وجود مرشح أنشأ شخصًا وملفًا وحساب بئر واحدًا';
  else
    raise notice 'FAIL 6: نتيجة الإنشاء بلا مرشح غير صحيحة: %', v_result;
  end if;

  -- ============================================================
  -- 4. الاسم والهاتف بعد التطبيع: إعادة canonical دون صف ثانٍ
  -- ============================================================

  select count(*) into v_people_before
  from core.persons where tenant_id = v_tenant;

  v_result_2 := api.create_farmer(
    p_well_id => v_well,
    p_full_name => 'احمد علي',
    p_phone => '00967 777111222'
  );

  if v_result_2 ->> 'status' = 'matched_existing'
     and (v_result_2 ->> 'person_id')::uuid = v_person
     and (v_result_2 ->> 'farmer_well_account_id')::uuid = v_account
     and (select count(*) from core.persons where tenant_id = v_tenant) = v_people_before
  then
    raise notice 'PASS 7: التطابق الحتمي أعاد الهوية والحساب canonical دون تكرار';
  else
    raise notice 'FAIL 7: إعادة التطابق الحتمي غير صحيحة: %', v_result_2;
  end if;

  -- ============================================================
  -- 5. الهاتف نفسه مع تهجئة مختلفة: تعارض بلا إنشاء
  -- ============================================================

  select count(*) into v_people_before
  from core.persons where tenant_id = v_tenant;
  select count(*) into v_profiles_before
  from ops.farmer_profiles where tenant_id = v_tenant;
  select count(*) into v_accounts_before
  from ops.farmer_well_accounts where tenant_id = v_tenant;

  v_result_2 := api.create_farmer(
    p_well_id => v_well,
    p_full_name => 'محمود صالح',
    p_phone => '777111222'
  );

  if v_result_2 ->> 'status' = 'requires_resolution'
     and (select count(*) from core.persons where tenant_id = v_tenant) = v_people_before
     and (select count(*) from ops.farmer_profiles where tenant_id = v_tenant) = v_profiles_before
     and (select count(*) from ops.farmer_well_accounts where tenant_id = v_tenant) = v_accounts_before
     and exists (
       select 1
       from jsonb_array_elements(v_result_2 -> 'duplicate_candidates') c
       where (c ->> 'person_id')::uuid = v_person
         and c ->> 'matched_on' = 'phone'
     )
  then
    raise notice 'PASS 8: الهاتف نفسه مع اسم مختلف أعاد requires_resolution دون إنشاء';
  else
    raise notice 'FAIL 8: حالة الهاتف نفسه غير آمنة: %', v_result_2;
  end if;

  -- ============================================================
  -- 6. الاسم نفسه مع هاتف مختلف: تعارض متين وإعادة حرفية
  -- ============================================================

  v_command := gen_random_uuid();
  v_conflict := api.create_farmer(
    p_well_id => v_well,
    p_full_name => 'أحمد علي',
    p_phone => '733444555',
    p_command_id => v_command
  );

  v_result_2 := api.create_farmer(
    p_well_id => v_well,
    p_full_name => 'أحمد علي',
    p_phone => '733444555',
    p_command_id => v_command
  );

  select count(*) into v_count
  from sync.processed_commands pc
  where pc.tenant_id = v_tenant
    and pc.command_id = v_command
    and pc.status = 'conflict'
    and pc.response_payload = v_conflict;

  if v_conflict ->> 'status' = 'requires_resolution'
     and v_result_2 = v_conflict
     and v_count = 1
     and (select count(*) from core.persons where tenant_id = v_tenant) = v_people_before
     and (select count(*) from ops.farmer_profiles where tenant_id = v_tenant) = v_profiles_before
     and (select count(*) from ops.farmer_well_accounts where tenant_id = v_tenant) = v_accounts_before
  then
    raise notice 'PASS 9: الاسم نفسه مع هاتف مختلف خُزّن conflict وأعيد الرد نفسه دون إنشاء';
  else
    raise notice 'FAIL 9: تعارض الاسم والهاتف أو إعادة المحاولة غير صحيحة: ر1=% ر2=% سجلات=%', v_conflict, v_result_2, v_count;
  end if;

  -- ============================================================
  -- 7. الاسم نفسه بلا هاتف: تعارض بلا إنشاء
  -- ============================================================

  v_result_2 := api.create_farmer(
    p_well_id => v_well,
    p_full_name => 'أحمد علي',
    p_phone => null
  );

  if v_result_2 ->> 'status' = 'requires_resolution'
     and (select count(*) from core.persons where tenant_id = v_tenant) = v_people_before
     and (select count(*) from ops.farmer_profiles where tenant_id = v_tenant) = v_profiles_before
     and (select count(*) from ops.farmer_well_accounts where tenant_id = v_tenant) = v_accounts_before
  then
    raise notice 'PASS 10: الاسم نفسه بلا هاتف أعاد requires_resolution دون إنشاء';
  else
    raise notice 'FAIL 10: الاشتباه بلا هاتف غير آمن: %', v_result_2;
  end if;

  -- ============================================================
  -- 8. مطابقات تاريخية متعددة: لا اختيار LIMIT 1 ولا دمج
  -- ============================================================

  execute 'reset role';

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (
    v_tenant,
    'متطابق تاريخي نادر',
    core.normalize_arabic('متطابق تاريخي نادر')
  ) returning id into v_historical_1;

  insert into core.person_contacts (
    tenant_id, person_id, contact_type, contact_value,
    normalized_value, is_primary
  ) values (
    v_tenant, v_historical_1, 'mobile', '711222333',
    core.normalize_phone('711222333'), true
  );

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (
    v_tenant,
    'متطابق تاريخي نادر',
    core.normalize_arabic('متطابق تاريخي نادر')
  ) returning id into v_historical_2;

  insert into core.person_contacts (
    tenant_id, person_id, contact_type, contact_value,
    normalized_value, is_primary
  ) values (
    v_tenant, v_historical_2, 'mobile', '711222333',
    core.normalize_phone('711222333'), true
  );

  execute 'set local role authenticated';

  select count(*) into v_people_before
  from core.persons where tenant_id = v_tenant;
  select count(*) into v_profiles_before
  from ops.farmer_profiles where tenant_id = v_tenant;
  select count(*) into v_accounts_before
  from ops.farmer_well_accounts where tenant_id = v_tenant;

  v_result_2 := api.create_farmer(
    p_well_id => v_well,
    p_full_name => 'متطابق تاريخي نادر',
    p_phone => '711222333'
  );

  select count(*) into v_count
  from jsonb_array_elements(v_result_2 -> 'duplicate_candidates') c
  where (c ->> 'person_id')::uuid in (v_historical_1, v_historical_2);

  if v_result_2 ->> 'status' = 'requires_resolution'
     and v_count = 2
     and (select count(*) from core.persons where tenant_id = v_tenant) = v_people_before
     and (select count(*) from ops.farmer_profiles where tenant_id = v_tenant) = v_profiles_before
     and (select count(*) from ops.farmer_well_accounts where tenant_id = v_tenant) = v_accounts_before
     and exists (select 1 from core.persons where id = v_historical_1 and status = 'active')
     and exists (select 1 from core.persons where id = v_historical_2 and status = 'active')
  then
    raise notice 'PASS 11: المطابقان التاريخيان أعادا requires_resolution بلا اختيار أو دمج أو إنشاء';
  else
    raise notice 'FAIL 11: العنقود التاريخي لم يُحفظ بأمان: %', v_result_2;
  end if;

  -- كل المرشحين، لا أول مرشح فقط، لا يكشفون إلا البنية الآمنة المطلوبة.
  select count(*) into v_count
  from jsonb_array_elements(v_result_2 -> 'duplicate_candidates') c
  where not (c ?& array[
      'person_id', 'public_code', 'full_name', 'match_level', 'matched_on'
    ])
    or (
      c - array[
        'person_id', 'public_code', 'full_name', 'match_level', 'matched_on'
      ]
    ) <> '{}'::jsonb;

  if v_count = 0
     and jsonb_array_length(v_result_2 -> 'duplicate_candidates') >= 2
  then
    raise notice 'PASS 12: كل حمولات المرشحين تحتوي الحقول الآمنة المطلوبة فقط';
  else
    raise notice 'FAIL 12: % حمولة مرشح ناقصة أو تكشف حقولًا إضافية: %', v_count, v_result_2 -> 'duplicate_candidates';
  end if;

  -- ============================================================
  -- 9. accepted: إعادة command_id نفسها تعيد الرد نفسه مرة واحدة
  -- ============================================================

  v_command := gen_random_uuid();
  select count(*) into v_people_before
  from core.persons where tenant_id = v_tenant;

  v_result := api.create_farmer(
    p_well_id => v_well,
    p_full_name => 'شخص فريد لإعادة المحاولة',
    p_phone => '700555111',
    p_command_id => v_command
  );

  v_result_2 := api.create_farmer(
    p_well_id => v_well,
    p_full_name => 'شخص فريد لإعادة المحاولة',
    p_phone => '700555111',
    p_command_id => v_command
  );

  select count(*) into v_count
  from sync.processed_commands pc
  where pc.tenant_id = v_tenant
    and pc.command_id = v_command
    and pc.status = 'accepted'
    and pc.response_payload = v_result;

  if v_result ->> 'status' = 'created'
     and v_result_2 = v_result
     and v_count = 1
     and (select count(*) from core.persons where tenant_id = v_tenant) = v_people_before + 1
  then
    raise notice 'PASS 13: إعادة accepted أعادت الرد المخزن ولم تكرر الشخص';
  else
    raise notice 'FAIL 13: إعادة accepted غير صحيحة: ر1=% ر2=% سجلات=%', v_result, v_result_2, v_count;
  end if;

  -- معرفا أمر مختلفان لهوية جديدة واحدة: إنشاء ثم matched_existing.
  v_command := gen_random_uuid();
  v_result := api.create_farmer(
    p_well_id => v_well,
    p_full_name => 'هوية تسلسلية واحدة',
    p_phone => '700666111',
    p_command_id => v_command
  );

  v_result_2 := api.create_farmer(
    p_well_id => v_well,
    p_full_name => 'هوية تسلسلية واحدة',
    p_phone => '700666111',
    p_command_id => gen_random_uuid()
  );

  select count(*) into v_count
  from core.persons p
  where p.tenant_id = v_tenant
    and core.normalize_arabic(p.full_name) =
      core.normalize_arabic('هوية تسلسلية واحدة');

  if v_result ->> 'status' = 'created'
     and v_result_2 ->> 'status' = 'matched_existing'
     and v_result ->> 'person_id' = v_result_2 ->> 'person_id'
     and v_count = 1
  then
    raise notice 'PASS 14: معرفا أمر مختلفان متتاليان أعادا هوية واحدة';
  else
    raise notice 'FAIL 14: التسلسل بمعرفي أمر مختلفين غير حتمي: ر1=% ر2=% صفوف=%', v_result, v_result_2, v_count;
  end if;

  -- ============================================================
  -- 10. الصلاحيات: فاعل بلا تعيين وanon مرفوضان
  -- ============================================================

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_intruder::text, true);
  execute 'set local role authenticated';

  begin
    perform api.create_farmer(v_well, 'ممنوع', '700777111');
    v_message := 'ALLOWED';
  exception when others then
    v_message := sqlerrm;
  end;

  execute 'reset role';

  if v_message <> 'ALLOWED' then
    raise notice 'PASS 15: الفاعل بلا صلاحية لا يستطيع إنشاء مزارع';
  else
    raise notice 'FAIL 15: فاعل بلا صلاحية أنشأ مزارعًا';
  end if;

  execute 'set local role anon';
  begin
    perform api.create_farmer(v_well, 'ممنوع anon', '700888111');
    v_message := 'ALLOWED';
  exception when others then
    v_message := sqlerrm;
  end;
  execute 'reset role';

  if v_message <> 'ALLOWED' then
    raise notice 'PASS 16: anon لا يستطيع تنفيذ api.create_farmer';
  else
    raise notice 'FAIL 16: anon نفذ api.create_farmer';
  end if;

  select count(*) into v_count
  from information_schema.table_privileges
  where grantee in ('anon', 'authenticated')
    and table_schema in (
      'core', 'iam', 'ops', 'billing', 'finance',
      'inventory', 'audit', 'sync', 'reporting'
    )
    and privilege_type in (
      'INSERT', 'UPDATE', 'DELETE',
      'TRUNCATE', 'REFERENCES', 'TRIGGER'
    );

  if v_count = 0 then
    raise notice 'PASS 17: لم يظهر أي Direct DML للعميل';
  else
    raise notice 'FAIL 17: ظهر % امتياز Direct DML للعميل', v_count;
  end if;

  -- ============================================================
  -- 11. عقد Farm Dedup القائم يبقى كما هو
  -- ============================================================

  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  v_result := api.create_farm(
    p_well_id => v_well,
    p_name => 'أرض عدم الانحدار 102',
    p_farmer_well_account_id => v_account
  );
  v_result_2 := api.create_farm(
    p_well_id => v_well,
    p_name => 'أرض عدم الانحدار 102',
    p_farmer_well_account_id => v_account
  );

  if v_result ->> 'status' = 'created'
     and v_result_2 ->> 'status' = 'matched_existing'
     and v_result ->> 'farm_id' = v_result_2 ->> 'farm_id'
  then
    raise notice 'PASS 18: عقد Farm Dedup في الهجرة 101 لم يتغير';
  else
    raise notice 'FAIL 18: ظهر انحدار في عقد Farm Dedup: ر1=% ر2=%', v_result, v_result_2;
  end if;

  -- ============================================================
  -- 12. حسم هوية المزارع: اختيار مرشح قائم (use_existing)
  -- ============================================================

  -- Fixture مرشح أصلي
  v_result := api.create_farmer(
    p_well_id => v_well,
    p_full_name => 'سالم سعيد قاسم',
    p_phone => '771122334'
  );
  v_candidate_person := (v_result ->> 'person_id')::uuid;
  v_candidate_account := (v_result ->> 'farmer_well_account_id')::uuid;

  -- أمر تعارض أصلي: نفس الاسم بهاتف مختلف ينتج requires_resolution
  v_cmd_candidate_test := gen_random_uuid();
  v_conflict := api.create_farmer(
    p_well_id => v_well,
    p_full_name => 'سالم سعيد قاسم',
    p_phone => '775566778',
    p_command_id => v_cmd_candidate_test
  );

  if v_conflict ->> 'status' = 'requires_resolution' then
    raise notice 'PASS 19: تعارض المزارع أُنشئ بنجاح لاختبار الحسم';
  else
    raise notice 'FAIL 19: لم ينتج تعارض المزارع: %', v_conflict;
  end if;

  -- مرشح غير موجود في قائمة التعارض الأصلية يُرفض
  begin
    perform api.resolve_farmer_identity(
      p_well_id => v_well,
      p_original_command_id => v_cmd_candidate_test,
      p_resolution_action => 'use_existing',
      p_selected_person_id => gen_random_uuid(),
      p_command_id => gen_random_uuid()
    );
    v_message := 'ALLOWED';
  exception when others then
    v_message := sqlerrm;
  end;

  if v_message <> 'ALLOWED' then
    raise notice 'PASS 20: معرّف مرشح غير موجود في قائمة تعارض الأمر الأصلي مرفوض';
  else
    raise notice 'FAIL 20: قُبل مرشح غير موجود في قائمة تعارض الأمر الأصلي';
  end if;

  -- مرشح من جهة أخرى يُرفض
  execute 'reset role';
  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_other_tenant, 'شخص جهة أخرى', core.normalize_arabic('شخص جهة أخرى'))
  returning id into v_other_person;
  execute 'set local role authenticated';

  begin
    perform api.resolve_farmer_identity(
      p_well_id => v_well,
      p_original_command_id => v_cmd_candidate_test,
      p_resolution_action => 'use_existing',
      p_selected_person_id => v_other_person,
      p_command_id => gen_random_uuid()
    );
    v_message := 'ALLOWED';
  exception when others then
    v_message := sqlerrm;
  end;

  if v_message <> 'ALLOWED' then
    raise notice 'PASS 21: مرشح من جهة أخرى مرفوض ولا يمكن اختياره';
  else
    raise notice 'FAIL 21: قُبل مرشح من جهة أخرى';
  end if;

  -- حسم ناجح باختيار مرشح التعارض القائم
  select count(*) into v_people_before from core.persons where tenant_id = v_tenant;
  select count(*) into v_profiles_before from ops.farmer_profiles where tenant_id = v_tenant;
  select count(*) into v_accounts_before from ops.farmer_well_accounts where tenant_id = v_tenant;

  v_res_command := gen_random_uuid();
  v_res_result := api.resolve_farmer_identity(
    p_well_id => v_well,
    p_original_command_id => v_cmd_candidate_test,
    p_resolution_action => 'use_existing',
    p_selected_person_id => v_candidate_person,
    p_command_id => v_res_command
  );

  if v_res_result ->> 'status' = 'matched_existing'
     and (v_res_result ->> 'person_id')::uuid = v_candidate_person
     and (v_res_result ->> 'farmer_well_account_id')::uuid = v_candidate_account
     and (v_res_result ->> 'already_exists')::boolean = true
     and (select count(*) from core.persons where tenant_id = v_tenant) = v_people_before
     and (select count(*) from ops.farmer_profiles where tenant_id = v_tenant) = v_profiles_before
     and (select count(*) from ops.farmer_well_accounts where tenant_id = v_tenant) = v_accounts_before
  then
    raise notice 'PASS 22: حسم الهوية بمرشح قائم أعاد canonical دون إنشاء مكرر';
  else
    raise notice 'FAIL 22: حسم الهوية بمرشح قائم غير صحيح: %', v_res_result;
  end if;

  -- إعادة أمر الحسم بمعرّف الأمر نفسه يعيد الرد المخزن
  v_res_result_2 := api.resolve_farmer_identity(
    p_well_id => v_well,
    p_original_command_id => v_cmd_candidate_test,
    p_resolution_action => 'use_existing',
    p_selected_person_id => v_candidate_person,
    p_command_id => v_res_command
  );

  select count(*) into v_count
  from sync.processed_commands pc
  where pc.tenant_id = v_tenant
    and pc.command_id = v_res_command
    and pc.status = 'accepted'
    and pc.response_payload = v_res_result;

  if v_res_result_2 = v_res_result and v_count = 1 then
    raise notice 'PASS 23: إعادة أمر الحسم أعادت الرد المقبول المخزن ولم تكرر المعالجة';
  else
    raise notice 'FAIL 23: إعادة أمر الحسم غير متطابقة: ر1=% ر2=% سجلات=%', v_res_result, v_res_result_2, v_count;
  end if;

  -- سجل التعارض الأصلي لا يُمحى ولا يُزوَّر إلى نجاح وهمي
  select count(*) into v_count
  from sync.processed_commands pc
  where pc.tenant_id = v_tenant
    and pc.command_id = v_cmd_candidate_test
    and pc.status = 'conflict'
    and pc.response_payload ->> 'status' = 'requires_resolution';

  if v_count = 1 then
    raise notice 'PASS 24: أمر إنشاء المزارع الأصلي باقٍ في السجل كـ conflict وتاريخه محفوظ';
  else
    raise notice 'FAIL 24: تاريخ الأمر الأصلي فُقد أو عُدّل: سجلات=%', v_count;
  end if;

  -- ============================================================
  -- 13. حسم هوية المزارع: شخص مختلف (different_person)
  -- ============================================================

  -- تعارض جديد على تطابق الهاتف
  v_cmd_phone_test := gen_random_uuid();
  v_conflict := api.create_farmer(
    p_well_id => v_well,
    p_full_name => 'هاني عبد الله صالح',
    p_phone => '771122334', -- هاتف سالم سعيد قاسم نفسه
    p_command_id => v_cmd_phone_test
  );

  -- ق-88: لا يمكن حسم "شخص مختلف" بنفس هاتف المرشح القائم
  begin
    perform api.resolve_farmer_identity(
      p_well_id => v_well,
      p_original_command_id => v_cmd_phone_test,
      p_resolution_action => 'different_person',
      p_full_name => 'هاني عبد الله صالح',
      p_phone => '+967 771-122-334',
      p_command_id => gen_random_uuid()
    );
    v_message := 'ALLOWED';
  exception when others then
    v_message := sqlerrm;
  end;

  if v_message <> 'ALLOWED' then
    raise notice 'PASS 25: ق-88: حسم شخص مختلف بنفس هاتف المرشح مرفوض قطعًا';
  else
    raise notice 'FAIL 25: قُبل حسم شخص مختلف بنفس هاتف المرشح';
  end if;

  -- تعارض بلا هاتف: حسم "شخص مختلف" بلا بيانات تمييز لا ينشئ بصمت
  v_cmd_nophone_test := gen_random_uuid();
  v_conflict := api.create_farmer(
    p_well_id => v_well,
    p_full_name => 'سالم سعيد قاسم',
    p_phone => null,
    p_command_id => v_cmd_nophone_test
  );

  select count(*) into v_people_before from core.persons where tenant_id = v_tenant;
  v_res_cmd_conflict := gen_random_uuid();
  v_res_result := api.resolve_farmer_identity(
    p_well_id => v_well,
    p_original_command_id => v_cmd_nophone_test,
    p_resolution_action => 'different_person',
    p_full_name => 'سالم سعيد قاسم',
    p_phone => null,
    p_command_id => v_res_cmd_conflict
  );

  if v_res_result ->> 'status' = 'requires_resolution'
     and v_res_result ->> 'person_id' is null
     and (select count(*) from core.persons where tenant_id = v_tenant) = v_people_before
  then
    raise notice 'PASS 26: حسم شخص مختلف بلا بيانات تمييز أعاد requires_resolution ولم ينشئ بصمت';
  else
    raise notice 'FAIL 26: حسم شخص مختلف بلا هاتف غير آمن: %', v_res_result;
  end if;

  -- إعادة محاولة الحسم المتعارض تعيد الرد المتعارض نفسه
  v_res_result_2 := api.resolve_farmer_identity(
    p_well_id => v_well,
    p_original_command_id => v_cmd_nophone_test,
    p_resolution_action => 'different_person',
    p_full_name => 'سالم سعيد قاسم',
    p_phone => null,
    p_command_id => v_res_cmd_conflict
  );

  select count(*) into v_count
  from sync.processed_commands pc
  where pc.tenant_id = v_tenant
    and pc.command_id = v_res_cmd_conflict
    and pc.status = 'conflict'
    and pc.response_payload = v_res_result;

  if v_res_result_2 = v_res_result and v_count = 1 then
    raise notice 'PASS 27: إعادة أمر الحسم المتعارض أعادت الرد المخزن نفسه';
  else
    raise notice 'FAIL 27: إعادة أمر الحسم المتعارض غير متطابقة';
  end if;

  -- شخص مختلف مميز قانونيًا بهاتف حقيقي غير مستخدم ينشئ شخصًا وملفًا وحسابًا واحدًا
  select count(*) into v_people_before from core.persons where tenant_id = v_tenant;
  select count(*) into v_profiles_before from ops.farmer_profiles where tenant_id = v_tenant;
  select count(*) into v_accounts_before from ops.farmer_well_accounts where tenant_id = v_tenant;

  v_res_command := gen_random_uuid();
  v_res_result := api.resolve_farmer_identity(
    p_well_id => v_well,
    p_original_command_id => v_cmd_nophone_test,
    p_resolution_action => 'different_person',
    p_full_name => 'سالم سعيد قاسم',
    p_phone => '779988112',
    p_command_id => v_res_command
  );

  v_diff_person := (v_res_result ->> 'person_id')::uuid;
  v_diff_account := (v_res_result ->> 'farmer_well_account_id')::uuid;

  if v_res_result ->> 'status' = 'created'
     and (v_res_result ->> 'already_exists')::boolean = false
     and v_diff_person <> v_candidate_person
     and (select count(*) from core.persons where tenant_id = v_tenant) = v_people_before + 1
     and (select count(*) from ops.farmer_profiles where tenant_id = v_tenant) = v_profiles_before + 1
     and (select count(*) from ops.farmer_well_accounts where tenant_id = v_tenant) = v_accounts_before + 1
  then
    raise notice 'PASS 28: شخص مختلف مميز بهاتف مستقل أنشأ شخصًا وملفًا وحسابًا واحدًا';
  else
    raise notice 'FAIL 28: إنشاء شخص مختلف مميز غير صحيح: %', v_res_result;
  end if;

  -- ============================================================
  -- 14. الصلاحيات: الحسم محجوب عن فاعل بلا تعيين وعن anon
  -- ============================================================

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_intruder::text, true);
  execute 'set local role authenticated';

  begin
    perform api.resolve_farmer_identity(
      p_well_id => v_well,
      p_original_command_id => v_cmd_candidate_test,
      p_resolution_action => 'use_existing',
      p_command_id => gen_random_uuid(),
      p_selected_person_id => v_candidate_person
    );
    v_message := 'ALLOWED';
  exception when others then
    v_message := sqlerrm;
  end;

  execute 'reset role';

  if v_message <> 'ALLOWED' then
    raise notice 'PASS 29: الفاعل بلا صلاحية لا يستطيع حسم هوية المزارع';
  else
    raise notice 'FAIL 29: فاعل بلا صلاحية نفذ حسم هوية المزارع';
  end if;

  execute 'set local role anon';
  begin
    perform api.resolve_farmer_identity(
      p_well_id => v_well,
      p_original_command_id => v_cmd_candidate_test,
      p_resolution_action => 'use_existing',
      p_command_id => gen_random_uuid(),
      p_selected_person_id => v_candidate_person
    );
    v_message := 'ALLOWED';
  exception when others then
    v_message := sqlerrm;
  end;
  execute 'reset role';

  if v_message <> 'ALLOWED' then
    raise notice 'PASS 30: anon لا يستطيع تنفيذ api.resolve_farmer_identity';
  else
    raise notice 'FAIL 30: anon نفذ api.resolve_farmer_identity';
  end if;
end;
$test$;

rollback;
