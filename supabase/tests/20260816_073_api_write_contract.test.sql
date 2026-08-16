begin;

do $test$
declare
  v_count integer;
  v_user uuid;
  v_profile uuid;
  v_tenant uuid;
  v_well uuid;
  v_summary jsonb;
  v_health jsonb;
begin

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'api'
    and p.proname = any(array[
      'start_irrigation_session',
      'pause_irrigation_session',
      'change_session_energy_source',
      'resume_irrigation_session',
      'complete_irrigation_session',
      'issue_session_invoice',
      'allocate_payment',
      'record_payment',
      'pay_partner_distribution',
      'create_farmer',
      'create_booking',
      'reschedule_booking',
      'purchase_fuel',
      'record_fuel_consumption',
      'record_physical_fuel_count'
    ]);

  if v_count = 15 then
    raise notice 'PASS 1: توجد أغلفة api الخمسة عشر المعتمدة';
  else
    raise notice 'FAIL 1: عدد أغلفة api المعتمدة = % بدل 15', v_count;
  end if;


  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'api'
    and p.proname = any(array[
      'start_irrigation_session',
      'pause_irrigation_session',
      'change_session_energy_source',
      'resume_irrigation_session',
      'complete_irrigation_session',
      'issue_session_invoice',
      'allocate_payment',
      'record_payment',
      'pay_partner_distribution',
      'create_farmer',
      'create_booking',
      'reschedule_booking',
      'purchase_fuel',
      'record_fuel_consumption',
      'record_physical_fuel_count'
    ])
    and has_function_privilege('authenticated', p.oid, 'EXECUTE');

  if v_count = 15 then
    raise notice 'PASS 2: authenticated يملك EXECUTE على أغلفة 073 الخمسة عشر';
  else
    raise notice 'FAIL 2: عدد أغلفة 073 القابلة للتنفيذ = % بدل 15', v_count;
  end if;


  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'api'
    and (
      p.proname = 'health'
      or p.proname = any(array[
      'start_irrigation_session',
      'pause_irrigation_session',
      'change_session_energy_source',
      'resume_irrigation_session',
      'complete_irrigation_session',
      'issue_session_invoice',
      'allocate_payment',
      'record_payment',
      'pay_partner_distribution',
      'create_farmer',
      'create_booking',
      'reschedule_booking',
      'purchase_fuel',
      'record_fuel_consumption',
      'record_physical_fuel_count'
    ])
    )
    and has_function_privilege('service_role', p.oid, 'EXECUTE');

  if v_count = 16 then
    raise notice 'PASS 3: service_role يرى health وعقد 073 كاملًا';
  else
    raise notice 'FAIL 3: عدد دوال عقد 073 المتاحة لـservice_role = % بدل 16', v_count;
  end if;


  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'api'
    and has_function_privilege('anon', p.oid, 'EXECUTE');

  if v_count = 0 then
    raise notice 'PASS 4: anon لا يستطيع تنفيذ أي دالة داخل api';
  else
    raise notice 'FAIL 4: anon يستطيع تنفيذ % دالة داخل api', v_count;
  end if;


  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'api'
    and p.prosecdef;

  if v_count = 0 then
    raise notice 'PASS 5: جميع دوال api تعمل SECURITY INVOKER';
  else
    raise notice 'FAIL 5: توجد % دالة SECURITY DEFINER داخل api', v_count;
  end if;


  select count(*)
  into v_count
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'api'
    and c.relkind in ('r', 'p', 'v', 'm', 'f');

  if v_count = 0 then
    raise notice 'PASS 6: api لا يحتوي جداول أو Views أعمال';
  else
    raise notice 'FAIL 6: api يحتوي % علاقة جدولية أو View', v_count;
  end if;


  -- في 073 كان create_farm مؤجلًا فعلًا.
  -- بعد ق-80/075 يسمح ببقائه إذا كان عقده اللاحق آمنًا.
  if to_regprocedure(
       'api.create_farm(uuid,text,uuid)'
     ) is null
     or exists (
       select 1
       from pg_proc p
       join pg_namespace n
         on n.oid = p.pronamespace
       where n.nspname = 'api'
         and p.proname = 'create_farm'
         and not p.prosecdef
         and has_function_privilege(
           'authenticated',
           p.oid,
           'EXECUTE'
         )
         and has_function_privilege(
           'service_role',
           p.oid,
           'EXECUTE'
         )
         and not has_function_privilege(
           'anon',
           p.oid,
           'EXECUTE'
         )
     )
  then
    raise notice 'PASS 7: تأجيل create_farm التاريخي لا يتعارض مع عقد ق-80 اللاحق';
  else
    raise notice 'FAIL 7: create_farm موجود لاحقًا بعقد غير آمن';
  end if;


  if
    to_regprocedure(
      'api.start_irrigation_session(uuid,uuid,uuid,uuid,text,timestamptz,uuid)'
    ) is not null
    and to_regprocedure(
      'api.start_irrigation_session(uuid,uuid,uuid,uuid,uuid,text,timestamptz,uuid)'
    ) is null
    and to_regprocedure(
      'api.issue_session_invoice(uuid)'
    ) is not null
    and to_regprocedure(
      'api.issue_session_invoice(uuid,uuid)'
    ) is null
    and to_regprocedure(
      'api.purchase_fuel(uuid,numeric,bigint,timestamptz)'
    ) is not null
    and to_regprocedure(
      'api.purchase_fuel(uuid,numeric,bigint,timestamptz,uuid)'
    ) is null
    and to_regprocedure(
      'api.pay_partner_distribution(uuid,bigint,timestamptz)'
    ) is not null
    and to_regprocedure(
      'api.pay_partner_distribution(uuid,bigint,uuid,timestamptz)'
    ) is null
  then
    raise notice 'PASS 8: عقد api لا يسمح للعميل بإرسال هوية المنفذ';
  else
    raise notice 'FAIL 8: أحد أغلفة api ما زال يكشف معامل هوية المنفذ';
  end if;


  select count(*)
  into v_count
  from information_schema.table_privileges
  where grantee in ('anon', 'authenticated')
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
    raise notice 'PASS 9: Direct DML بقي مغلقًا بعد إضافة عقد api';
  else
    raise notice 'FAIL 9: عاد % مسار Direct DML بعد 073', v_count;
  end if;


  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at
  ) values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'api073@test.local',
    crypt('x', gen_salt('bf')),
    now(),
    now(),
    now()
  ) returning id into v_user;

  select id into v_profile
  from iam.profiles
  where id = v_user;

  if not found then
    insert into iam.profiles (id, full_name)
    values (v_user, 'مالك اختبار api 073')
    returning id into v_profile;
  end if;

  insert into core.tenants (name)
  values ('جهة اختبار api 073')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'بئر اختبار api 073')
  returning id into v_well;

  insert into core.well_assignments (
    well_id,
    profile_id,
    role,
    status
  ) values (
    v_well,
    v_profile,
    'owner',
    'active'
  );

  perform set_config(
    'request.jwt.claim.sub',
    v_user::text,
    true
  );

  execute 'set local role authenticated';

  v_summary := api.create_farmer(
    v_well,
    'مزارع عقد api',
    '777123073'
  );

  if
    (v_summary ->> 'person_id')::uuid is not null
    and (v_summary ->> 'farmer_profile_id')::uuid is not null
    and (v_summary ->> 'farmer_well_account_id')::uuid is not null
    and exists (
      select 1
      from ops.farmer_well_accounts fwa
      where fwa.id =
        (v_summary ->> 'farmer_well_account_id')::uuid
        and fwa.well_id = v_well
    )
  then
    raise notice 'PASS 10: api.create_farmer نفذ العملية كاملة بهوية المستخدم الحقيقي';
  else
    raise notice 'FAIL 10: api.create_farmer لم ينفذ العقد كما هو متوقع';
  end if;


  v_health := api.health();

  if v_health = jsonb_build_object(
    'status', 'ok',
    'contract', 'api',
    'version', 1
  ) then
    raise notice 'PASS 11: api.health بقي سليمًا بعد إضافة عقد الكتابة';
  else
    raise notice 'FAIL 11: api.health تغير بعد 073: %', v_health;
  end if;

  execute 'reset role';


  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'api'
    and (
      p.proname = 'health'
      or p.proname = any(array[
      'start_irrigation_session',
      'pause_irrigation_session',
      'change_session_energy_source',
      'resume_irrigation_session',
      'complete_irrigation_session',
      'issue_session_invoice',
      'allocate_payment',
      'record_payment',
      'pay_partner_distribution',
      'create_farmer',
      'create_booking',
      'reschedule_booking',
      'purchase_fuel',
      'record_fuel_consumption',
      'record_physical_fuel_count'
    ])
    )
    and has_function_privilege(
      'authenticated',
      p.oid,
      'EXECUTE'
    );

  if v_count = 16 then
    raise notice 'PASS 12: عقد 073 الأساسي بقي health + 15 عملية معتمدة';
  else
    raise notice 'FAIL 12: عقد 073 الأساسي يحتوي % دالة بدل 16', v_count;
  end if;

end;
$test$;

rollback;
