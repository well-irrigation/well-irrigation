begin;

set local timezone to 'UTC';

do $test$
declare
  v_count bigint;
  v_count_2 bigint;
  v_owner uuid;
  v_manager uuid;
  v_operator uuid;
  v_partner uuid;
  v_accountant uuid;
  v_viewer uuid;
  v_farmer uuid;
  v_inactive uuid;
  v_multi uuid;
  v_tenant uuid;
  v_well_1 uuid;
  v_well_2 uuid;
begin

  -- ------------------------------------------------------------
  -- 1. Canonical bridge is complete and farmer is excluded.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from iam.well_assignment_role_map m
  join iam.roles r
    on r.id = m.role_id
  where (m.assignment_role, r.code) in (
    ('owner', 'tenant_owner'),
    ('manager', 'well_manager'),
    ('operator', 'operator'),
    ('partner', 'partner'),
    ('accountant', 'accountant'),
    ('viewer', 'viewer')
  );

  select count(*)
  into v_count_2
  from iam.well_assignment_role_map
  where assignment_role = 'farmer';

  if v_count = 6 and v_count_2 = 0 then
    raise notice 'PASS 1: Legacy assignment roles مربوطة Canonical bundles وfarmer خارجها';
  else
    raise notice 'FAIL 1: bridge_count=% farmer_map_count=%', v_count, v_count_2;
  end if;


  -- ------------------------------------------------------------
  -- 2. Permission catalog = original 21 + 17 current V1 codes.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from iam.permissions;

  select count(*)
  into v_count_2
  from iam.permissions
  where code = any(array[
    'session.resume',
    'invoice.issue',
    'payment.allocate',
    'distribution.pay',
    'fuel.purchase',
    'fuel.consume',
    'fuel.count',
    'shift.open',
    'shift.close',
    'shift.close_override',
    'handover.declare',
    'handover.confirm',
    'handover.settle',
    'session.transfer.request',
    'session.transfer.respond',
    'payroll.accrue',
    'payroll.pay'
  ]);

  -- الكتالوج صار 39 بعد Migration 081 التي أضافت
  -- `session.energy.change` (الثغرة الوحيدة التي كشفها إثبات
  -- التكافؤ في ق-113). Migration 080 نفسها لم تُعدل.
  -- ثم صار 41 بعد Migration 091 التي أضافت `well.update`
  -- و`pump.manage`: عقود الكتابة صارت إجراءات SECURITY DEFINER
  -- بسبب ق-79، فاحتاجت صلاحية مسمّاة للتفويض الصريح.
  -- ثم صار 42 بعد Migration 093 التي أضافت `price.read`: قراءة
  -- التسعيرة كانت محكومة بـ`price.manage` (صلاحية تعديل للمالك)،
  -- فصارت صلاحية اطلاع مستقلة لمن يشغّل البئر.
  if v_count = 42 and v_count_2 = 17 then
    raise notice 'PASS 2: Permission catalog = 42 ويغطي تدفقات V1 الحالية';
  else
    raise notice 'FAIL 2: permission_total=% new_codes=%', v_count, v_count_2;
  end if;


  -- ------------------------------------------------------------
  -- 3. Conservative permission grant counts.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from iam.role_permissions;

  -- +3 منح بعد Migration 081: `session.energy.change` مُنحت
  -- للثلاثة الذين كان الحرس النصي يسمح لهم بها أصلًا
  -- (owner + manager + operator) — بلا توسيع ولا تضييق.
  -- +2 منح بعد Migration 091: `well.update` و`pump.manage`
  -- للمالك وحده، مطابقةً لسياسات RLS على core.wells وcore.pumps.
  -- +3 منح بعد Migration 093: `price.read` للمالك والمدير والمشغل،
  -- وهي نفس مجموعة الأدوار التي تقبلها ops.start_irrigation_session:
  -- من يبدأ جلسة مُسعَّرة يرى السعر الذي ستُسعَّر به.
  if v_count = 78
     and (
       select count(*)
       from iam.role_permissions rp
       join iam.roles r on r.id = rp.role_id
       where r.code = 'tenant_owner'
     ) = 42
     and (
       select count(*)
       from iam.role_permissions rp
       join iam.roles r on r.id = rp.role_id
       where r.code = 'well_manager'
     ) = 14
     and (
       select count(*)
       from iam.role_permissions rp
       join iam.roles r on r.id = rp.role_id
       where r.code = 'operator'
     ) = 22
  then
    raise notice 'PASS 3: Role permission seed = owner 42 / manager 14 / operator 22';
  else
    raise notice 'FAIL 3: role_permissions total=%', v_count;
  end if;


  -- ------------------------------------------------------------
  -- 4. No silent writes for partner/accountant/viewer.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from iam.role_permissions rp
  join iam.roles r
    on r.id = rp.role_id
  where r.code in (
    'partner',
    'accountant',
    'viewer'
  );

  if v_count = 0 then
    raise notice 'PASS 4: partner/accountant/viewer لم يحصلوا على كتابة جديدة';
  else
    raise notice 'FAIL 4: unexpected grants=%', v_count;
  end if;


  -- ------------------------------------------------------------
  -- 5. has_well_permission security contract.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'iam'
    and p.proname = 'has_well_permission'
    and pg_get_function_identity_arguments(p.oid)
        = 'p_well_id uuid, p_permission_code text'
    and p.prosecdef
    and p.provolatile = 's'
    and has_function_privilege(
      'authenticated',
      p.oid,
      'EXECUTE'
    )
    and not has_function_privilege(
      'anon',
      p.oid,
      'EXECUTE'
    )
    and exists (
      select 1
      from unnest(coalesce(p.proconfig, array[]::text[])) cfg
      where cfg = 'search_path=pg_catalog, pg_temp'
    );

  if v_count = 1 then
    raise notice 'PASS 5: has_well_permission ثابتة وآمنة وممنوحة لـauthenticated فقط';
  else
    raise notice 'FAIL 5: helper contract count=%', v_count;
  end if;


  -- ------------------------------------------------------------
  -- 6. Assignment constraint accepts the complete legacy bridge.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from pg_constraint c
  join pg_class t
    on t.oid = c.conrelid
  join pg_namespace n
    on n.oid = t.relnamespace
  where n.nspname = 'core'
    and t.relname = 'well_assignments'
    and c.conname = 'well_assignments_role_check'
    and pg_get_constraintdef(c.oid) like '%accountant%'
    and pg_get_constraintdef(c.oid) like '%viewer%'
    and pg_get_constraintdef(c.oid) like '%farmer%';

  if v_count = 1 then
    raise notice 'PASS 6: well_assignments يدعم accountant/viewer ويحافظ farmer';
  else
    raise notice 'FAIL 6: role constraint غير مطابق';
  end if;


  -- ------------------------------------------------------------
  -- 7. API boundary unchanged.
  -- ------------------------------------------------------------

  if (
       select count(*)
       from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'api'
         and p.prokind = 'f'
         and has_function_privilege('authenticated', p.oid, 'EXECUTE')
     ) >= 33
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
  then
    raise notice 'PASS 7: API surface آمنة ومطابقة و 0 anon / 0 definer';
  else
    raise notice 'FAIL 7: API surface تغيرت';
  end if;



  -- ------------------------------------------------------------
  -- 8. Direct DML remains zero.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from pg_class c
  join pg_namespace n
    on n.oid = c.relnamespace
  where n.nspname in (
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
    and c.relkind in ('r', 'p')
    and (
      has_table_privilege('authenticated', c.oid, 'INSERT')
      or has_table_privilege('authenticated', c.oid, 'UPDATE')
      or has_table_privilege('authenticated', c.oid, 'DELETE')
      or has_table_privilege('anon', c.oid, 'INSERT')
      or has_table_privilege('anon', c.oid, 'UPDATE')
      or has_table_privilege('anon', c.oid, 'DELETE')
    );

  if v_count = 0 then
    raise notice 'PASS 8: Direct DML بقي صفرًا';
  else
    raise notice 'FAIL 8: Direct DML ظهر على % جدول/جداول', v_count;
  end if;


  -- ------------------------------------------------------------
  -- 9. 080 does not rewrite the legacy RLS layer.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from pg_policies
  where (
    coalesce(qual, '') || ' ' || coalesce(with_check, '')
  ) like '%iam.has_well_role%';

  if v_count = 273 then
    raise notice 'PASS 9: Legacy RLS compatibility layer بقيت 273 policy';
  else
    raise notice 'FAIL 9: has_well_role policy count=% بدل 273', v_count;
  end if;


  -- ------------------------------------------------------------
  -- Fixture users.
  -- ------------------------------------------------------------

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at,
    created_at, updated_at
  )
  values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'q112-owner@test.local',
    crypt('x', gen_salt('bf')),
    now(), now(), now()
  )
  returning id into v_owner;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at,
    created_at, updated_at
  )
  values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'q112-manager@test.local',
    crypt('x', gen_salt('bf')),
    now(), now(), now()
  )
  returning id into v_manager;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at,
    created_at, updated_at
  )
  values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'q112-operator@test.local',
    crypt('x', gen_salt('bf')),
    now(), now(), now()
  )
  returning id into v_operator;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at,
    created_at, updated_at
  )
  values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'q112-partner@test.local',
    crypt('x', gen_salt('bf')),
    now(), now(), now()
  )
  returning id into v_partner;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at,
    created_at, updated_at
  )
  values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'q112-accountant@test.local',
    crypt('x', gen_salt('bf')),
    now(), now(), now()
  )
  returning id into v_accountant;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at,
    created_at, updated_at
  )
  values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'q112-viewer@test.local',
    crypt('x', gen_salt('bf')),
    now(), now(), now()
  )
  returning id into v_viewer;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at,
    created_at, updated_at
  )
  values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'q112-farmer@test.local',
    crypt('x', gen_salt('bf')),
    now(), now(), now()
  )
  returning id into v_farmer;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at,
    created_at, updated_at
  )
  values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'q112-inactive@test.local',
    crypt('x', gen_salt('bf')),
    now(), now(), now()
  )
  returning id into v_inactive;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at,
    created_at, updated_at
  )
  values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'q112-multi@test.local',
    crypt('x', gen_salt('bf')),
    now(), now(), now()
  )
  returning id into v_multi;

  update iam.profiles
  set full_name = coalesce(full_name, 'W1-03 Test User')
  where id in (
    v_owner, v_manager, v_operator, v_partner,
    v_accountant, v_viewer, v_farmer, v_inactive, v_multi
  );


  -- ------------------------------------------------------------
  -- Fixture tenant/wells.
  -- ------------------------------------------------------------

  insert into core.tenants (name)
  values ('W1-03 Permission Authority Test')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'W1-03 Well 1')
  returning id into v_well_1;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'W1-03 Well 2')
  returning id into v_well_2;

  insert into core.well_assignments (
    well_id, profile_id, role, status
  )
  values
    (v_well_1, v_owner, 'owner', 'active'),
    (v_well_1, v_manager, 'manager', 'active'),
    (v_well_1, v_operator, 'operator', 'active'),
    (v_well_1, v_partner, 'partner', 'active'),
    (v_well_1, v_accountant, 'accountant', 'active'),
    (v_well_1, v_viewer, 'viewer', 'active'),
    (v_well_1, v_farmer, 'farmer', 'active'),
    (v_well_1, v_inactive, 'operator', 'inactive'),
    (v_well_1, v_multi, 'manager', 'active'),
    (v_well_1, v_multi, 'operator', 'active');


  -- ------------------------------------------------------------
  -- 10. Owner gets the complete well-scoped bundle.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';

  if iam.has_well_permission(v_well_1, 'ownership.manage')
     and iam.has_well_permission(v_well_1, 'distribution.approve')
     and iam.has_well_permission(v_well_1, 'shift.close_override')
     and iam.has_well_permission(v_well_1, 'audit.view')
  then
    raise notice 'PASS 10: owner/tenant_owner bundle يملك الصلاحيات الكاملة داخل البئر';
  else
    raise notice 'FAIL 10: owner bundle ناقص';
  end if;

  execute 'reset role';


  -- ------------------------------------------------------------
  -- 11. Manager preserves only current manager authority.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_manager::text, true);
  execute 'set local role authenticated';

  if iam.has_well_permission(v_well_1, 'session.start')
     and iam.has_well_permission(v_well_1, 'payment.create')
     and iam.has_well_permission(v_well_1, 'period.close')
     and iam.has_well_permission(v_well_1, 'payroll.pay')
     and not iam.has_well_permission(v_well_1, 'farmer.create')
     and not iam.has_well_permission(v_well_1, 'expense.create')
     and not iam.has_well_permission(v_well_1, 'distribution.approve')
  then
    raise notice 'PASS 11: manager bundle يحافظ على السلوك الحالي بلا توسيع';
  else
    raise notice 'FAIL 11: manager bundle غير محافظ';
  end if;

  execute 'reset role';


  -- ------------------------------------------------------------
  -- 12. Operator preserves field-operation authority only.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_operator::text, true);
  execute 'set local role authenticated';

  if iam.has_well_permission(v_well_1, 'farmer.create')
     and iam.has_well_permission(v_well_1, 'booking.create')
     and iam.has_well_permission(v_well_1, 'session.start')
     and iam.has_well_permission(v_well_1, 'payment.create')
     and iam.has_well_permission(v_well_1, 'expense.create')
     and iam.has_well_permission(v_well_1, 'fuel.count')
     and iam.has_well_permission(v_well_1, 'shift.open')
     and not iam.has_well_permission(v_well_1, 'farm.create')
     and not iam.has_well_permission(v_well_1, 'expense.approve')
     and not iam.has_well_permission(v_well_1, 'period.close')
  then
    raise notice 'PASS 12: operator bundle يحافظ Field authority الحالية';
  else
    raise notice 'FAIL 12: operator bundle غير محافظ';
  end if;

  execute 'reset role';


  -- ------------------------------------------------------------
  -- 13. Partner gets no new administrative write authority.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_partner::text, true);
  execute 'set local role authenticated';

  if not iam.has_well_permission(v_well_1, 'payment.create')
     and not iam.has_well_permission(v_well_1, 'distribution.approve')
  then
    raise notice 'PASS 13: partner لم يحصل على Administrative write جديدة';
  else
    raise notice 'FAIL 13: partner حصل على كتابة غير معتمدة';
  end if;

  execute 'reset role';


  -- ------------------------------------------------------------
  -- 14. Accountant is assignable but no silent writes yet.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_accountant::text, true);
  execute 'set local role authenticated';

  if not iam.has_well_permission(v_well_1, 'payment.create')
     and not iam.has_well_permission(v_well_1, 'period.close')
  then
    raise notice 'PASS 14: accountant قابل للتعيين لكن بلا كتابة غير معتمدة';
  else
    raise notice 'FAIL 14: accountant حصل على كتابة صامتة';
  end if;

  execute 'reset role';


  -- ------------------------------------------------------------
  -- 15. Viewer is strictly non-writing in the permission layer.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_viewer::text, true);
  execute 'set local role authenticated';

  if not iam.has_well_permission(v_well_1, 'session.start')
     and not iam.has_well_permission(v_well_1, 'expense.create')
  then
    raise notice 'PASS 15: viewer بلا Permission كتابة';
  else
    raise notice 'FAIL 15: viewer حصل على كتابة';
  end if;

  execute 'reset role';


  -- ------------------------------------------------------------
  -- 16. Farmer assignment does not become an admin role.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_farmer::text, true);
  execute 'set local role authenticated';

  if not iam.has_well_permission(v_well_1, 'session.start')
     and not iam.has_well_permission(v_well_1, 'payment.create')
     and iam.has_well_role(v_well_1, array['farmer'])
  then
    raise notice 'PASS 16: farmer بقي Self-scope منفصلًا عن Administrative permissions';
  else
    raise notice 'FAIL 16: farmer permission separation غير صحيح';
  end if;

  execute 'reset role';


  -- ------------------------------------------------------------
  -- 17. Inactive assignment is denied.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_inactive::text, true);
  execute 'set local role authenticated';

  if not iam.has_well_permission(v_well_1, 'session.start') then
    raise notice 'PASS 17: inactive assignment لا تمنح Permission';
  else
    raise notice 'FAIL 17: inactive assignment مُنحت Permission';
  end if;

  execute 'reset role';


  -- ------------------------------------------------------------
  -- 18. Permission is well-scoped.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';

  if iam.has_well_permission(v_well_1, 'session.start')
     and not iam.has_well_permission(v_well_2, 'session.start')
  then
    raise notice 'PASS 18: Permission محصورة في well_id';
  else
    raise notice 'FAIL 18: cross-well permission leak';
  end if;

  execute 'reset role';


  -- ------------------------------------------------------------
  -- 19. Multiple assignments union their permission bundles.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_multi::text, true);
  execute 'set local role authenticated';

  if iam.has_well_permission(v_well_1, 'period.close')
     and iam.has_well_permission(v_well_1, 'farmer.create')
     and not iam.has_well_permission(v_well_1, 'distribution.approve')
  then
    raise notice 'PASS 19: multi-role user يحصل على Union بدون owner escalation';
  else
    raise notice 'FAIL 19: multi-role union غير صحيح';
  end if;

  execute 'reset role';


  -- ------------------------------------------------------------
  -- 20. Unknown permission is false and legacy role helper remains.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_operator::text, true);
  execute 'set local role authenticated';

  if not iam.has_well_permission(v_well_1, 'does.not.exist')
     and iam.has_well_role(v_well_1, array['operator'])
  then
    raise notice 'PASS 20: unknown permission=false وhas_well_role بقي Compatibility سليمة';
  else
    raise notice 'FAIL 20: unknown/compatibility behavior غير صحيح';
  end if;

  execute 'reset role';

end;
$test$;

rollback;
