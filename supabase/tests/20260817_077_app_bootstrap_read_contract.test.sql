begin;

do $test$
declare
  v_oid oid;
  v_count integer;
  v_user uuid;
  v_profile uuid;
  v_tenant uuid;
  v_well_multi uuid;
  v_well_inactive uuid;
  v_well_partner_only uuid;
  v_person uuid;
  v_payload jsonb;
  v_multi jsonb;
  v_partner_only jsonb;
  v_keys text[];
begin

  -- ---------------------------------------------------------------
  -- 1. Contract existence/signature
  -- ---------------------------------------------------------------

  v_oid := to_regprocedure('api.app_bootstrap()');

  if v_oid is not null
     and pg_get_function_result(v_oid) = 'jsonb'
  then
    raise notice
      'PASS 1: api.app_bootstrap() موجودة وتعيد jsonb';
  else
    raise notice
      'FAIL 1: عقد api.app_bootstrap() غير موجود أو نوع الإرجاع خاطئ';
  end if;


  -- ---------------------------------------------------------------
  -- 2. ACL
  -- ---------------------------------------------------------------

  if has_function_privilege(
       'authenticated',
       v_oid,
       'EXECUTE'
     )
     and has_function_privilege(
       'service_role',
       v_oid,
       'EXECUTE'
     )
     and not has_function_privilege(
       'anon',
       v_oid,
       'EXECUTE'
     )
  then
    raise notice
      'PASS 2: ACL لعقد app_bootstrap مطابق لق-78';
  else
    raise notice
      'FAIL 2: ACL لعقد app_bootstrap غير صحيح';
  end if;


  -- ---------------------------------------------------------------
  -- 3. SECURITY INVOKER + STABLE + safe search_path
  -- ---------------------------------------------------------------

  if exists (
    select 1
    from pg_proc p
    where p.oid = v_oid
      and not p.prosecdef
      and p.provolatile = 's'
      and array_to_string(
        p.proconfig,
        ','
      ) like '%search_path=pg_catalog, pg_temp%'
  )
  then
    raise notice
      'PASS 3: app_bootstrap SECURITY INVOKER/STABLE وبـsearch_path آمن';
  else
    raise notice
      'FAIL 3: خصائص أمان app_bootstrap غير صحيحة';
  end if;


  -- ---------------------------------------------------------------
  -- 4. No SECURITY DEFINER in exposed api
  -- ---------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'api'
    and p.prosecdef;

  if v_count = 0 then
    raise notice
      'PASS 4: لا توجد SECURITY DEFINER داخل api';
  else
    raise notice
      'FAIL 4: توجد % دالة SECURITY DEFINER داخل api',
      v_count;
  end if;


  -- ---------------------------------------------------------------
  -- 5. anon remains blocked from every api function
  -- ---------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'api'
    and has_function_privilege(
      'anon',
      p.oid,
      'EXECUTE'
    );

  if v_count = 0 then
    raise notice
      'PASS 5: anon محجوب عن جميع دوال api';
  else
    raise notice
      'FAIL 5: anon يستطيع تنفيذ % دالة api',
      v_count;
  end if;


  -- ---------------------------------------------------------------
  -- 6. Direct DML remains zero
  -- ---------------------------------------------------------------

  select count(*)
  into v_count
  from information_schema.table_privileges
  where grantee in (
    'anon',
    'authenticated'
  )
    and table_schema in (
      'core',
      'iam',
      'ops',
      'billing',
      'finance',
      'inventory',
      'audit',
      'sync',
      'reporting'
    )
    and privilege_type in (
      'INSERT',
      'UPDATE',
      'DELETE',
      'TRUNCATE',
      'REFERENCES',
      'TRIGGER'
    );

  if v_count = 0 then
    raise notice
      'PASS 6: Direct DML بقي صفرًا';
  else
    raise notice
      'FAIL 6: عاد % مسار Direct DML',
      v_count;
  end if;


  -- ---------------------------------------------------------------
  -- 7. api remains function-only
  -- ---------------------------------------------------------------

  select count(*)
  into v_count
  from pg_class c
  join pg_namespace n
    on n.oid = c.relnamespace
  where n.nspname = 'api'
    and c.relkind in (
      'r',
      'p',
      'v',
      'm',
      'f'
    );

  if v_count = 0 then
    raise notice
      'PASS 7: api ما زال بلا جداول أو Views أعمال';
  else
    raise notice
      'FAIL 7: api يحتوي % علاقة جدولية',
      v_count;
  end if;


  -- ---------------------------------------------------------------
  -- Fixtures
  -- ---------------------------------------------------------------

  insert into auth.users (
    id,
    instance_id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    created_at,
    updated_at
  )
  values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'q82-bootstrap@test.local',
    crypt('x', gen_salt('bf')),
    now(),
    now(),
    now()
  )
  returning id into v_user;


  select id
  into v_profile
  from iam.profiles
  where id = v_user;

  if not found then
    insert into iam.profiles (
      id,
      full_name,
      phone
    )
    values (
      v_user,
      'مستخدم ق-82',
      '777000082'
    )
    returning id into v_profile;
  else
    update iam.profiles
    set
      full_name = 'مستخدم ق-82',
      phone = '777000082'
    where id = v_profile;
  end if;


  insert into core.tenants (
    name
  )
  values (
    'جهة ق-82'
  )
  returning id into v_tenant;


  insert into core.wells (
    tenant_id,
    name,
    location
  )
  values (
    v_tenant,
    'بئر متعدد الأدوار',
    'موقع أ'
  )
  returning id into v_well_multi;


  insert into core.wells (
    tenant_id,
    name,
    location
  )
  values (
    v_tenant,
    'بئر تعيين غير نشط',
    'موقع ب'
  )
  returning id into v_well_inactive;


  insert into core.wells (
    tenant_id,
    name,
    location
  )
  values (
    v_tenant,
    'بئر شريك فقط',
    'موقع ج'
  )
  returning id into v_well_partner_only;


  insert into core.well_assignments (
    well_id,
    profile_id,
    role,
    status
  )
  values
    (
      v_well_multi,
      v_profile,
      'owner',
      'active'
    ),
    (
      v_well_multi,
      v_profile,
      'operator',
      'active'
    ),
    (
      v_well_multi,
      v_profile,
      'partner',
      'active'
    ),
    (
      v_well_inactive,
      v_profile,
      'manager',
      'inactive'
    );


  insert into core.persons (
    tenant_id,
    full_name,
    normalized_name
  )
  values (
    v_tenant,
    'شريك ق-82',
    'شريك ق-82'
  )
  returning id into v_person;


  -- وصول الشريك الفعلي يأتي من well_partners.
  -- نسب الملكية أصبحت في ownership_share_versions منذ migration 051،
  -- لذلك لا يستخدم هذا الاختبار حقل النسبة التاريخي القديم.
  insert into core.well_partners (
    tenant_id,
    well_id,
    person_id,
    profile_id,
    phone
  )
  values
    (
      v_tenant,
      v_well_multi,
      v_person,
      v_profile,
      '777000082'
    ),
    (
      v_tenant,
      v_well_partner_only,
      v_person,
      v_profile,
      '777000082'
    );


  perform set_config(
    'request.jwt.claim.sub',
    v_user::text,
    true
  );

  execute 'set local role authenticated';


  v_payload := api.app_bootstrap();


  -- ---------------------------------------------------------------
  -- 8. Contract/version/profile
  -- ---------------------------------------------------------------

  if v_payload ->> 'contract' = 'app_bootstrap'
     and (v_payload ->> 'version')::integer = 1
     and (v_payload #>> '{profile,id}')::uuid = v_user
     and v_payload #>> '{profile,full_name}' = 'مستخدم ق-82'
     and v_payload #>> '{profile,phone}' = '777000082'
     and (
       v_payload #>> '{profile,is_platform_admin}'
     )::boolean = false
  then
    raise notice
      'PASS 8: contract/version/profile مطابق للعقد';
  else
    raise notice
      'FAIL 8: payload profile غير مطابق: %',
      v_payload;
  end if;


  -- ---------------------------------------------------------------
  -- 9. Only active/effective wells are exposed
  -- ---------------------------------------------------------------

  if jsonb_array_length(
       v_payload -> 'wells'
     ) = 2
     and exists (
       select 1
       from jsonb_array_elements(
         v_payload -> 'wells'
       ) x
       where (x ->> 'id')::uuid =
         v_well_multi
     )
     and exists (
       select 1
       from jsonb_array_elements(
         v_payload -> 'wells'
       ) x
       where (x ->> 'id')::uuid =
         v_well_partner_only
     )
     and not exists (
       select 1
       from jsonb_array_elements(
         v_payload -> 'wells'
       ) x
       where (x ->> 'id')::uuid =
         v_well_inactive
     )
  then
    raise notice
      'PASS 9: التعيين غير النشط مستبعد والآبار الفعالة فقط ظاهرة';
  else
    raise notice
      'FAIL 9: مجموعة الآبار غير متوقعة: %',
      v_payload -> 'wells';
  end if;


  -- ---------------------------------------------------------------
  -- 10. Multi-role aggregation + partner dedup
  -- ---------------------------------------------------------------

  select x
  into v_multi
  from jsonb_array_elements(
    v_payload -> 'wells'
  ) x
  where (x ->> 'id')::uuid =
    v_well_multi;

  if v_multi -> 'roles' =
       '["operator","owner","partner"]'::jsonb
  then
    raise notice
      'PASS 10: الأدوار مجمعة ومزالة التكرار بترتيب ثابت';
  else
    raise notice
      'FAIL 10: أدوار البئر المتعدد غير صحيحة: %',
      v_multi -> 'roles';
  end if;


  -- ---------------------------------------------------------------
  -- 11. Partner-only access is preserved
  -- ---------------------------------------------------------------

  select x
  into v_partner_only
  from jsonb_array_elements(
    v_payload -> 'wells'
  ) x
  where (x ->> 'id')::uuid =
    v_well_partner_only;

  if v_partner_only -> 'roles' =
       '["partner"]'::jsonb
  then
    raise notice
      'PASS 11: well_partners يحفظ وصول الشريك حتى بلا well_assignment';
  else
    raise notice
      'FAIL 11: وصول الشريك فقط غير صحيح: %',
      v_partner_only;
  end if;


  -- ---------------------------------------------------------------
  -- 12. Well payload is deliberately minimal
  -- ---------------------------------------------------------------

  select array_agg(k order by k)
  into v_keys
  from jsonb_object_keys(v_multi) k;

  if v_keys = array[
       'id',
       'location',
       'name',
       'roles',
       'status',
       'tenant_id'
     ]::text[]
  then
    raise notice
      'PASS 12: payload البئر محدود بالحقول المعتمدة فقط';
  else
    raise notice
      'FAIL 12: مفاتيح payload البئر غير متوقعة: %',
      v_keys;
  end if;

  execute 'reset role';

end;
$test$;

rollback;
