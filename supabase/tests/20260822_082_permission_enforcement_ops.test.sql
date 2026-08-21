begin;

set local timezone to 'UTC';

do $test$
declare
  v_count bigint;
  v_count_2 bigint;
  v_src text;
  v_owner uuid;
  v_manager uuid;
  v_operator uuid;
  v_partner uuid;
  v_farmer uuid;
  v_inactive uuid;
  v_tenant uuid;
  v_well_1 uuid;
begin

  -- ------------------------------------------------------------
  -- 1. All 14 ops/session/inventory functions consume the new
  --    authority and none still calls the legacy role authority.
  -- ------------------------------------------------------------

  select
    count(*) filter (where src like '%has_well_permission%'),
    count(*) filter (where src like '%has_well_role%')
  into v_count, v_count_2
  from (
    select pg_get_functiondef(p.oid) as src
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (
      ('ops', 'start_irrigation_session'),
      ('ops', 'pause_irrigation_session'),
      ('ops', 'resume_irrigation_session'),
      ('ops', 'complete_irrigation_session'),
      ('ops', 'change_session_energy_source'),
      ('ops', 'create_farmer'),
      ('ops', 'create_farm'),
      ('ops', 'create_booking'),
      ('ops', 'reschedule_booking'),
      ('inventory', 'purchase_fuel'),
      ('inventory', 'record_fuel_consumption'),
      ('inventory', 'record_physical_fuel_count'),
      ('api', 'open_shift'),
      ('api', 'close_shift')
    )
  ) s;

  if v_count = 14 and v_count_2 = 0 then
    raise notice 'PASS 1: 14 دالة تشغيلية تستهلك has_well_permission وصفر منها على القديمة';
  else
    raise notice 'FAIL 1: permission_fns=% legacy_fns=% (توقع 14 و0)',
      v_count, v_count_2;
  end if;


  -- ------------------------------------------------------------
  -- 2. Each ops function is bound to its intended code.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from (values
    ('ops',       'start_irrigation_session',     'session.start'),
    ('ops',       'pause_irrigation_session',     'session.pause'),
    ('ops',       'resume_irrigation_session',    'session.resume'),
    ('ops',       'complete_irrigation_session',  'session.complete'),
    ('ops',       'change_session_energy_source', 'session.energy.change'),
    ('ops',       'create_farmer',                'farmer.create'),
    ('ops',       'create_farm',                  'farm.create'),
    ('ops',       'create_booking',               'booking.create'),
    ('ops',       'reschedule_booking',           'booking.reschedule'),
    ('inventory', 'purchase_fuel',                'fuel.purchase'),
    ('inventory', 'record_fuel_consumption',      'fuel.consume'),
    ('inventory', 'record_physical_fuel_count',   'fuel.count'),
    ('api',       'open_shift',                   'shift.open'),
    ('api',       'close_shift',                  'shift.close_override')
  ) as x(nsp, fn, code)
  join pg_proc p
    on p.proname = x.fn
  join pg_namespace n
    on n.oid = p.pronamespace
   and n.nspname = x.nsp
  where pg_get_functiondef(p.oid) like '%''' || x.code || '''%';

  if v_count = 14 then
    raise notice 'PASS 2: كل دالة تشغيلية مرتبطة بصلاحيتها المقصودة';
  else
    raise notice 'FAIL 2: ربط صحيح = % من 14', v_count;
  end if;


  -- ------------------------------------------------------------
  -- 3. Identity checks preserved — لم تتحول أسئلة الهوية
  --    إلى أسئلة صلاحية.
  --    close_shift: يبقى «أنا صاحب المناوبة» بديلًا عن التجاوز.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'api'
    and p.proname = 'close_shift'
    and pg_get_functiondef(p.oid) like '%is distinct from v_operator_profile_id%'
    and pg_get_functiondef(p.oid) like '%p_allow_open_sessions%';

  if v_count = 1 then
    raise notice 'PASS 3: close_shift حفظ فحص الهوية إلى جانب صلاحية التجاوز';
  else
    raise notice 'FAIL 3: close_shift فقد فحص الهوية';
  end if;


  -- ------------------------------------------------------------
  -- 4. Handover/transfer identity-only functions were NOT
  --    converted — تحويلها كان سيضيف شرطًا لم يكن موجودًا.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'api'
    and p.proname in (
      'declare_handover',
      'request_session_transfer',
      'respond_session_transfer'
    )
    and pg_get_functiondef(p.oid) not like '%has_well_permission%'
    and pg_get_functiondef(p.oid) not like '%has_well_role%';

  if v_count = 3 then
    raise notice 'PASS 4: الأبواب المبنية على الهوية وحدها بقيت كما هي';
  else
    raise notice 'FAIL 4: identity-only functions سليمة = % من 3', v_count;
  end if;


  -- ------------------------------------------------------------
  -- 5. Zero function-body guards remain on the legacy authority
  --    anywhere in the database. م-18 تغلق هنا.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname in (
    'api', 'ops', 'billing', 'finance', 'inventory', 'core', 'reporting'
  )
    and p.prokind = 'f'
    and pg_get_functiondef(p.oid) like '%iam.has_well_role%';

  if v_count = 0 then
    raise notice 'PASS 5: صفر حرس دالة على مصفوفات الأدوار النصية';
  else
    raise notice 'FAIL 5: بقي % دالة على السلطة القديمة', v_count;
  end if;


  -- ------------------------------------------------------------
  -- 6. Legacy RLS compatibility layer still intact and is now
  --    the ONLY consumer of has_well_role.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from pg_policies
  where (
    coalesce(qual, '') || ' ' || coalesce(with_check, '')
  ) like '%iam.has_well_role%';

  if v_count = 273 then
    raise notice 'PASS 6: 273 RLS policy باقية كطبقة توافق وحيدة';
  else
    raise notice 'FAIL 6: has_well_role policy count = % بدل 273', v_count;
  end if;


  -- ------------------------------------------------------------
  -- 7. Login check preserved in all 14 functions.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where (n.nspname, p.proname) in (
    ('ops', 'start_irrigation_session'),
    ('ops', 'pause_irrigation_session'),
    ('ops', 'resume_irrigation_session'),
    ('ops', 'complete_irrigation_session'),
    ('ops', 'change_session_energy_source'),
    ('ops', 'create_farmer'),
    ('ops', 'create_farm'),
    ('ops', 'create_booking'),
    ('ops', 'reschedule_booking'),
    ('inventory', 'purchase_fuel'),
    ('inventory', 'record_fuel_consumption'),
    ('inventory', 'record_physical_fuel_count'),
    ('api', 'open_shift'),
    ('api', 'close_shift')
  )
    and pg_get_functiondef(p.oid) like '%v_actor is null%';

  if v_count = 14 then
    raise notice 'PASS 7: فحص تسجيل الدخول محفوظ في 14 دالة';
  else
    raise notice 'FAIL 7: login check موجود في % من 14', v_count;
  end if;


  -- ------------------------------------------------------------
  -- 8. ops.create_farm kept the 075 signature — لم تُستعد
  --    نسخة 069 المسقطة.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'ops'
    and p.proname = 'create_farm'
    and pg_get_function_identity_arguments(p.oid)
        = 'p_well_id uuid, p_name text, p_farmer_well_account_id uuid';

  select count(*)
  into v_count_2
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'ops'
    and p.proname = 'create_farm';

  if v_count = 1 and v_count_2 = 1 then
    raise notice 'PASS 8: ops.create_farm بقيت على توقيع 075 وحده';
  else
    raise notice 'FAIL 8: create_farm 075_sig=% total=%', v_count, v_count_2;
  end if;


  -- ------------------------------------------------------------
  -- 9. Security attributes unchanged.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'api'
    and p.proname in ('open_shift', 'close_shift')
    and not p.prosecdef;

  select count(*)
  into v_count_2
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where (n.nspname, p.proname) in (
    ('ops', 'start_irrigation_session'),
    ('ops', 'pause_irrigation_session'),
    ('ops', 'resume_irrigation_session'),
    ('ops', 'complete_irrigation_session'),
    ('ops', 'change_session_energy_source'),
    ('ops', 'create_farmer'),
    ('ops', 'create_farm'),
    ('ops', 'create_booking'),
    ('ops', 'reschedule_booking'),
    ('inventory', 'purchase_fuel'),
    ('inventory', 'record_fuel_consumption'),
    ('inventory', 'record_physical_fuel_count')
  )
    and p.prosecdef;

  if v_count = 2 and v_count_2 = 12 then
    raise notice 'PASS 9: api.* بقيت invoker والداخلية الـ12 بقيت definer';
  else
    raise notice 'FAIL 9: api_invoker=% internal_definer=% (توقع 2 و12)',
      v_count, v_count_2;
  end if;


  -- ------------------------------------------------------------
  -- 10. API surface and Direct DML unchanged.
  -- ------------------------------------------------------------

  if (
       select count(*)
       from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'api'
         and p.prokind = 'f'
         and has_function_privilege('authenticated', p.oid, 'EXECUTE')
     ) = 33
     and (
       select count(*)
       from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'api'
         and p.prokind = 'f'
         and has_function_privilege('anon', p.oid, 'EXECUTE')
     ) = 0
     and (
       select count(*)
       from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'api'
         and p.prokind = 'f'
         and p.prosecdef
     ) = 0
     and (
       select count(*)
       from pg_class c
       join pg_namespace n on n.oid = c.relnamespace
       where n.nspname in (
         'core', 'iam', 'ops', 'billing', 'finance',
         'inventory', 'audit', 'sync', 'reporting'
       )
         and c.relkind in ('r', 'p')
         and (
           has_table_privilege('authenticated', c.oid, 'INSERT')
           or has_table_privilege('authenticated', c.oid, 'UPDATE')
           or has_table_privilege('authenticated', c.oid, 'DELETE')
           or has_table_privilege('anon', c.oid, 'INSERT')
           or has_table_privilege('anon', c.oid, 'UPDATE')
           or has_table_privilege('anon', c.oid, 'DELETE')
         )
     ) = 0
  then
    raise notice 'PASS 10: API surface 33/0/0 وDirect DML صفر بلا تغيير';
  else
    raise notice 'FAIL 10: API surface أو Direct DML تغيرت';
  end if;


  -- ------------------------------------------------------------
  -- Fixture users/tenant/well.
  -- ------------------------------------------------------------

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q113o-owner@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_owner;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q113o-manager@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_manager;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q113o-operator@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_operator;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q113o-partner@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_partner;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q113o-farmer@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_farmer;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q113o-inactive@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_inactive;

  insert into core.tenants (name)
  values ('W1-03b Ops Enforcement Test')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'W1-03b Ops Well')
  returning id into v_well_1;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values
    (v_well_1, v_owner, 'owner', 'active'),
    (v_well_1, v_manager, 'manager', 'active'),
    (v_well_1, v_operator, 'operator', 'active'),
    (v_well_1, v_partner, 'partner', 'active'),
    (v_well_1, v_farmer, 'farmer', 'active'),
    (v_well_1, v_inactive, 'operator', 'inactive');


  -- ------------------------------------------------------------
  -- 11. Owner equivalence across all 15 ops codes.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';

  select count(*)
  into v_count
  from unnest(array[
    'session.start', 'session.pause', 'session.resume',
    'session.complete', 'session.energy.change',
    'farmer.create', 'farm.create', 'booking.create',
    'booking.reschedule', 'fuel.purchase', 'fuel.consume',
    'fuel.count', 'shift.open', 'shift.close_override'
  ]) code
  where iam.has_well_permission(v_well_1, code);

  execute 'reset role';

  if v_count = 14 then
    raise notice 'PASS 11: owner يملك الصلاحيات التشغيلية الـ14 كما قبل النقل';
  else
    raise notice 'FAIL 11: owner يملك % من 14', v_count;
  end if;


  -- ------------------------------------------------------------
  -- 12. Manager equivalence: session authority only.
  --     كان لا يملك المزارع/الأرض/الحجز/الوقود/المناوبة.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_manager::text, true);
  execute 'set local role authenticated';

  select coalesce(array_to_string(array_agg(code order by code), ','), '')
  into v_src
  from unnest(array[
    'session.start', 'session.pause', 'session.resume',
    'session.complete', 'session.energy.change',
    'farmer.create', 'farm.create', 'booking.create',
    'booking.reschedule', 'fuel.purchase', 'fuel.consume',
    'fuel.count', 'shift.open', 'shift.close_override'
  ]) code
  where iam.has_well_permission(v_well_1, code);

  execute 'reset role';

  if v_src = 'session.complete,session.energy.change,session.pause,'
             || 'session.resume,session.start'
  then
    raise notice 'PASS 12: manager يملك سلطة الجلسة وحدها بلا توسيع';
  else
    raise notice 'FAIL 12: manager ops set = "%"', v_src;
  end if;


  -- ------------------------------------------------------------
  -- 13. Operator equivalence: full field authority, no farm,
  --     no administrative shift override.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_operator::text, true);
  execute 'set local role authenticated';

  select coalesce(array_to_string(array_agg(code order by code), ','), '')
  into v_src
  from unnest(array[
    'session.start', 'session.pause', 'session.resume',
    'session.complete', 'session.energy.change',
    'farmer.create', 'farm.create', 'booking.create',
    'booking.reschedule', 'fuel.purchase', 'fuel.consume',
    'fuel.count', 'shift.open', 'shift.close_override'
  ]) code
  where iam.has_well_permission(v_well_1, code);

  execute 'reset role';

  if v_src = 'booking.create,booking.reschedule,farmer.create,'
             || 'fuel.consume,fuel.count,fuel.purchase,'
             || 'session.complete,session.energy.change,session.pause,'
             || 'session.resume,session.start,shift.open'
  then
    raise notice 'PASS 13: operator يملك الميدان كاملًا بلا الأرض وبلا تجاوز المناوبة';
  else
    raise notice 'FAIL 13: operator ops set = "%"', v_src;
  end if;


  -- ------------------------------------------------------------
  -- 14. Shift override remains owner-only.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_operator::text, true);
  execute 'set local role authenticated';
  v_count := case
    when iam.has_well_permission(v_well_1, 'shift.close_override') then 1
    else 0
  end;
  execute 'reset role';

  perform set_config('request.jwt.claim.sub', v_manager::text, true);
  execute 'set local role authenticated';
  v_count_2 := case
    when iam.has_well_permission(v_well_1, 'shift.close_override') then 1
    else 0
  end;
  execute 'reset role';

  if v_count = 0 and v_count_2 = 0 then
    raise notice 'PASS 14: تجاوز إغلاق المناوبة بقي للمالك وحده';
  else
    raise notice 'FAIL 14: operator=% manager=% حصلا على التجاوز',
      v_count, v_count_2;
  end if;


  -- ------------------------------------------------------------
  -- 15. Farm creation remains owner-only.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_operator::text, true);
  execute 'set local role authenticated';
  v_count := case
    when iam.has_well_permission(v_well_1, 'farm.create') then 1 else 0
  end;
  execute 'reset role';

  perform set_config('request.jwt.claim.sub', v_manager::text, true);
  execute 'set local role authenticated';
  v_count_2 := case
    when iam.has_well_permission(v_well_1, 'farm.create') then 1 else 0
  end;
  execute 'reset role';

  if v_count = 0 and v_count_2 = 0 then
    raise notice 'PASS 15: إنشاء الأرض بقي للمالك وحده';
  else
    raise notice 'FAIL 15: operator=% manager=% حصلا على إنشاء الأرض',
      v_count, v_count_2;
  end if;


  -- ------------------------------------------------------------
  -- 16. farmer assignment grants zero operational authority
  --     but keeps its self-scope role.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_farmer::text, true);
  execute 'set local role authenticated';

  select count(*)
  into v_count
  from unnest(array[
    'session.start', 'session.energy.change', 'booking.create',
    'fuel.purchase', 'shift.open', 'farm.create'
  ]) code
  where iam.has_well_permission(v_well_1, code);

  if v_count = 0 and iam.has_well_role(v_well_1, array['farmer']) then
    raise notice 'PASS 16: المزارع بلا سلطة تشغيلية ودوره الذاتي محفوظ';
  else
    raise notice 'FAIL 16: farmer ops permissions = %', v_count;
  end if;

  execute 'reset role';


  -- ------------------------------------------------------------
  -- 17. Inactive assignment grants nothing.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_inactive::text, true);
  execute 'set local role authenticated';

  select count(*)
  into v_count
  from unnest(array[
    'session.start', 'session.energy.change', 'booking.create',
    'fuel.purchase', 'shift.open'
  ]) code
  where iam.has_well_permission(v_well_1, code);

  execute 'reset role';

  if v_count = 0 then
    raise notice 'PASS 17: التعيين الموقوف لا يمنح أي سلطة تشغيلية';
  else
    raise notice 'FAIL 17: التعيين الموقوف منح % صلاحية', v_count;
  end if;


  -- ------------------------------------------------------------
  -- 18. partner holds zero operational authority.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_partner::text, true);
  execute 'set local role authenticated';

  select count(*)
  into v_count
  from unnest(array[
    'session.start', 'session.energy.change', 'booking.create',
    'fuel.purchase', 'shift.open', 'farm.create'
  ]) code
  where iam.has_well_permission(v_well_1, code);

  execute 'reset role';

  if v_count = 0 then
    raise notice 'PASS 18: الشريك بلا أي سلطة تشغيلية';
  else
    raise notice 'FAIL 18: partner ops permissions = %', v_count;
  end if;


  -- ------------------------------------------------------------
  -- 19. Cross-well isolation after the swap.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';

  select count(*)
  into v_count
  from core.wells w
  where w.id <> v_well_1
    and (
      iam.has_well_permission(w.id, 'session.start')
      or iam.has_well_permission(w.id, 'session.energy.change')
    );

  execute 'reset role';

  if v_count = 0 then
    raise notice 'PASS 19: الصلاحية التشغيلية محصورة في البئر ولا تتسرب';
  else
    raise notice 'FAIL 19: تسرب صلاحية إلى % بئر', v_count;
  end if;


  -- ------------------------------------------------------------
  -- 20. Removing the energy grant propagates instantly and
  --     touches nothing else. م-18 تُثمر هنا عمليًا.
  -- ------------------------------------------------------------

  delete from iam.role_permissions rp
  using iam.roles r, iam.permissions p
  where rp.role_id = r.id
    and rp.permission_id = p.id
    and r.code = 'operator'
    and p.code = 'session.energy.change';

  perform set_config('request.jwt.claim.sub', v_operator::text, true);
  execute 'set local role authenticated';

  if not iam.has_well_permission(v_well_1, 'session.energy.change')
     and iam.has_well_permission(v_well_1, 'session.start')
     and iam.has_well_role(v_well_1, array['operator'])
  then
    raise notice 'PASS 20: سحب صلاحية واحدة يسري فورًا ولا يمس الدور ولا غيرها';
  else
    raise notice 'FAIL 20: سحب الصلاحية لم يسرِ كما يجب';
  end if;

  execute 'reset role';

end;
$test$;

rollback;
