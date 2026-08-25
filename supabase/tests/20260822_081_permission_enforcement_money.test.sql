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
  v_viewer uuid;
  v_tenant uuid;
  v_well_1 uuid;
begin

  -- ------------------------------------------------------------
  -- 1. Catalog completion: session.energy.change exists.
  --    كانت العملية موجودة بلا صلاحية تقابلها إطلاقًا.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from iam.permissions
  where code = 'session.energy.change';

  select count(*)
  into v_count_2
  from iam.permissions;

  if v_count = 1 and v_count_2 = 39 then
    raise notice 'PASS 1: session.energy.change مضافة والكتالوج = 39';
  else
    raise notice 'FAIL 1: energy_code=% catalog_total=% (توقع 1 و39)',
      v_count, v_count_2;
  end if;


  -- ------------------------------------------------------------
  -- 2. session.energy.change grants match the existing guard
  --    exactly: owner + manager + operator. لا توسيع ولا تضييق.
  -- ------------------------------------------------------------

  select coalesce(
    array_to_string(
      array_agg(distinct m.assignment_role order by m.assignment_role),
      ','
    ),
    ''
  )
  into v_src
  from iam.permissions p
  join iam.role_permissions rp
    on rp.permission_id = p.id
  join iam.well_assignment_role_map m
    on m.role_id = rp.role_id
  where p.code = 'session.energy.change';

  if v_src = 'manager,operator,owner' then
    raise notice 'PASS 2: session.energy.change ممنوحة لـowner/manager/operator بالضبط';
  else
    raise notice 'FAIL 2: energy grants = "%" بدل manager,operator,owner', v_src;
  end if;


  -- ------------------------------------------------------------
  -- 3. Grant total grew by exactly 3 (70 -> 73).
  --    أي رقم آخر يعني منحًا صامتًا.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from iam.role_permissions;

  if v_count = 73 then
    raise notice 'PASS 3: iam.role_permissions = 73 (70 + 3 فقط)';
  else
    raise notice 'FAIL 3: role_permissions = % بدل 73', v_count;
  end if;


  -- ------------------------------------------------------------
  -- 4. partner/accountant/viewer still hold zero grants.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from iam.role_permissions rp
  join iam.roles r
    on r.id = rp.role_id
  where r.code in ('partner', 'accountant', 'viewer');

  if v_count = 0 then
    raise notice 'PASS 4: partner/accountant/viewer بلا أي منح جديدة';
  else
    raise notice 'FAIL 4: منح غير معتمدة = %', v_count;
  end if;


  -- ------------------------------------------------------------
  -- 5. All 13 money/finance functions now call the new authority
  --    and none of them still calls the legacy role authority.
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
      ('billing', 'issue_session_invoice'),
      ('billing', 'record_payment'),
      ('billing', 'allocate_payment'),
      ('finance', 'pay_partner_distribution'),
      ('api', 'record_expense'),
      ('api', 'decide_expense'),
      ('api', 'confirm_handover'),
      ('api', 'settle_handover'),
      ('api', 'close_period'),
      ('api', 'calculate_profit_distribution'),
      ('api', 'approve_profit_distribution'),
      ('api', 'accrue_payroll'),
      ('api', 'pay_salary')
    )
  ) s;

  if v_count = 13 and v_count_2 = 0 then
    raise notice 'PASS 5: 13 دالة مالية تستهلك has_well_permission وصفر منها على القديمة';
  else
    raise notice 'FAIL 5: permission_fns=% legacy_fns=% (توقع 13 و0)',
      v_count, v_count_2;
  end if;


  -- ------------------------------------------------------------
  -- 6. Each money function is bound to its intended permission
  --    code — لا خلط بين صلاحية وأخرى.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from (values
    ('billing', 'issue_session_invoice',      'invoice.issue'),
    ('billing', 'record_payment',             'payment.create'),
    ('billing', 'allocate_payment',           'payment.allocate'),
    ('finance', 'pay_partner_distribution',   'distribution.pay'),
    ('api',     'record_expense',             'expense.create'),
    ('api',     'decide_expense',             'expense.approve'),
    ('api',     'confirm_handover',           'handover.confirm'),
    ('api',     'settle_handover',            'handover.settle'),
    ('api',     'close_period',               'period.close'),
    ('api',     'calculate_profit_distribution', 'distribution.calculate'),
    ('api',     'approve_profit_distribution',   'distribution.approve'),
    ('api',     'accrue_payroll',             'payroll.accrue'),
    ('api',     'pay_salary',                 'payroll.pay')
  ) as x(nsp, fn, code)
  join pg_proc p
    on p.proname = x.fn
  join pg_namespace n
    on n.oid = p.pronamespace
   and n.nspname = x.nsp
  where pg_get_functiondef(p.oid) like '%' || x.code || '%';

  if v_count = 13 then
    raise notice 'PASS 6: كل دالة مالية مرتبطة بصلاحيتها المقصودة';
  else
    raise notice 'FAIL 6: ربط صحيح = % من 13', v_count;
  end if;


  -- ------------------------------------------------------------
  -- 7. Login check preserved: every function still refuses a
  --    NULL actor. نقل الصلاحية لم يحذف فحص الدخول.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where (n.nspname, p.proname) in (
    ('billing', 'issue_session_invoice'),
    ('billing', 'record_payment'),
    ('billing', 'allocate_payment'),
    ('finance', 'pay_partner_distribution'),
    ('api', 'record_expense'),
    ('api', 'decide_expense'),
    ('api', 'confirm_handover'),
    ('api', 'settle_handover'),
    ('api', 'close_period'),
    ('api', 'calculate_profit_distribution'),
    ('api', 'approve_profit_distribution'),
    ('api', 'accrue_payroll'),
    ('api', 'pay_salary')
  )
    and pg_get_functiondef(p.oid) like '%v_actor is null%';

  if v_count = 13 then
    raise notice 'PASS 7: فحص تسجيل الدخول محفوظ في 13 دالة';
  else
    raise notice 'FAIL 7: login check موجود في % من 13', v_count;
  end if;


  -- ------------------------------------------------------------
  -- 8. Security attributes unchanged by the swap.
  --    api.* تبقى invoker، والداخلية تبقى definer.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'api'
    and p.proname in (
      'record_expense', 'decide_expense', 'confirm_handover',
      'settle_handover', 'close_period',
      'calculate_profit_distribution', 'approve_profit_distribution',
      'accrue_payroll', 'pay_salary'
    )
    and not p.prosecdef;

  select count(*)
  into v_count_2
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where (n.nspname, p.proname) in (
    ('billing', 'issue_session_invoice'),
    ('billing', 'record_payment'),
    ('billing', 'allocate_payment'),
    ('finance', 'pay_partner_distribution')
  )
    and p.prosecdef;

  if v_count = 9 and v_count_2 = 4 then
    raise notice 'PASS 8: api.* بقيت invoker والداخلية بقيت definer';
  else
    raise notice 'FAIL 8: api_invoker=% internal_definer=% (توقع 9 و4)',
      v_count, v_count_2;
  end if;


  -- ------------------------------------------------------------
  -- 9. API surface unchanged: create or replace حفظ الصلاحيات.
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
    raise notice 'PASS 9: API surface آمنة ومطابقة و 0 anon / 0 definer';
  else
    raise notice 'FAIL 9: API surface تغيرت بعد إعادة التعريف';
  end if;


  -- ------------------------------------------------------------
  -- 10. Legacy RLS compatibility layer untouched.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from pg_policies
  where (
    coalesce(qual, '') || ' ' || coalesce(with_check, '')
  ) like '%iam.has_well_role%';

  if v_count = 273 then
    raise notice 'PASS 10: 273 RLS policy على has_well_role بلا تغيير';
  else
    raise notice 'FAIL 10: has_well_role policy count = % بدل 273', v_count;
  end if;


  -- ------------------------------------------------------------
  -- 11. Direct DML remains zero.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from pg_class c
  join pg_namespace n
    on n.oid = c.relnamespace
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
    );

  if v_count = 0 then
    raise notice 'PASS 11: Direct DML بقي صفرًا';
  else
    raise notice 'FAIL 11: Direct DML ظهر على % جدول', v_count;
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
    'authenticated', 'authenticated', 'q113m-owner@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_owner;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q113m-manager@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_manager;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q113m-operator@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_operator;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q113m-partner@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_partner;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q113m-viewer@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_viewer;

  insert into core.tenants (name)
  values ('W1-03b Money Enforcement Test')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'W1-03b Money Well')
  returning id into v_well_1;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values
    (v_well_1, v_owner, 'owner', 'active'),
    (v_well_1, v_manager, 'manager', 'active'),
    (v_well_1, v_operator, 'operator', 'active'),
    (v_well_1, v_partner, 'partner', 'active'),
    (v_well_1, v_viewer, 'viewer', 'active');


  -- ------------------------------------------------------------
  -- 12. Behaviour equivalence for owner across all money codes.
  --     المالك كان يقدر على كل شيء، ويبقى كذلك.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';

  select count(*)
  into v_count
  from unnest(array[
    'invoice.issue', 'payment.create', 'payment.allocate',
    'distribution.pay', 'expense.create', 'expense.approve',
    'handover.confirm', 'handover.settle', 'period.close',
    'distribution.calculate', 'distribution.approve',
    'payroll.accrue', 'payroll.pay'
  ]) code
  where iam.has_well_permission(v_well_1, code);

  execute 'reset role';

  if v_count = 13 then
    raise notice 'PASS 12: owner يملك الصلاحيات المالية الـ13 كما قبل النقل';
  else
    raise notice 'FAIL 12: owner يملك % من 13', v_count;
  end if;


  -- ------------------------------------------------------------
  -- 13. Manager equivalence: كان يملك 5 من هذه المالية فقط.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_manager::text, true);
  execute 'set local role authenticated';

  select coalesce(array_to_string(array_agg(code order by code), ','), '')
  into v_src
  from unnest(array[
    'invoice.issue', 'payment.create', 'payment.allocate',
    'distribution.pay', 'expense.create', 'expense.approve',
    'handover.confirm', 'handover.settle', 'period.close',
    'distribution.calculate', 'distribution.approve',
    'payroll.accrue', 'payroll.pay'
  ]) code
  where iam.has_well_permission(v_well_1, code);

  execute 'reset role';

  if v_src = 'distribution.pay,invoice.issue,payment.allocate,'
             || 'payment.create,payroll.accrue,payroll.pay,period.close'
  then
    raise notice 'PASS 13: manager يملك نفس السبع صلاحيات المالية بلا زيادة';
  else
    raise notice 'FAIL 13: manager money set = "%"', v_src;
  end if;


  -- ------------------------------------------------------------
  -- 14. Operator equivalence: field money only.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_operator::text, true);
  execute 'set local role authenticated';

  select coalesce(array_to_string(array_agg(code order by code), ','), '')
  into v_src
  from unnest(array[
    'invoice.issue', 'payment.create', 'payment.allocate',
    'distribution.pay', 'expense.create', 'expense.approve',
    'handover.confirm', 'handover.settle', 'period.close',
    'distribution.calculate', 'distribution.approve',
    'payroll.accrue', 'payroll.pay'
  ]) code
  where iam.has_well_permission(v_well_1, code);

  execute 'reset role';

  if v_src = 'expense.create,invoice.issue,payment.allocate,payment.create'
  then
    raise notice 'PASS 14: operator يملك الأربع المالية الميدانية فقط';
  else
    raise notice 'FAIL 14: operator money set = "%"', v_src;
  end if;


  -- ------------------------------------------------------------
  -- 15. Partner/viewer hold zero money authority.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_partner::text, true);
  execute 'set local role authenticated';

  select count(*)
  into v_count
  from unnest(array[
    'invoice.issue', 'payment.create', 'payment.allocate',
    'distribution.pay', 'expense.create', 'expense.approve',
    'period.close', 'payroll.pay'
  ]) code
  where iam.has_well_permission(v_well_1, code);

  execute 'reset role';

  perform set_config('request.jwt.claim.sub', v_viewer::text, true);
  execute 'set local role authenticated';

  select count(*)
  into v_count_2
  from unnest(array[
    'invoice.issue', 'payment.create', 'payment.allocate',
    'distribution.pay', 'expense.create', 'expense.approve',
    'period.close', 'payroll.pay'
  ]) code
  where iam.has_well_permission(v_well_1, code);

  execute 'reset role';

  if v_count = 0 and v_count_2 = 0 then
    raise notice 'PASS 15: partner وviewer بلا أي سلطة مالية';
  else
    raise notice 'FAIL 15: partner=% viewer=%', v_count, v_count_2;
  end if;


  -- ------------------------------------------------------------
  -- 16. Cross-well isolation still holds after the swap.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';

  select count(*)
  into v_count
  from core.wells w
  where w.id <> v_well_1
    and iam.has_well_permission(w.id, 'payment.create');

  execute 'reset role';

  if v_count = 0 then
    raise notice 'PASS 16: صلاحية المال محصورة في البئر ولا تتسرب';
  else
    raise notice 'FAIL 16: تسرب صلاحية إلى % بئر', v_count;
  end if;


  -- ------------------------------------------------------------
  -- 17. Anonymous caller has no money permission at all.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role authenticated';

  select count(*)
  into v_count
  from unnest(array[
    'payment.create', 'expense.create', 'period.close', 'payroll.pay'
  ]) code
  where iam.has_well_permission(v_well_1, code);

  execute 'reset role';

  if v_count = 0 then
    raise notice 'PASS 17: غير المسجل بلا أي صلاحية مالية';
  else
    raise notice 'FAIL 17: غير المسجل حصل على % صلاحية', v_count;
  end if;


  -- ------------------------------------------------------------
  -- 18. Removing a grant now propagates to the API instantly —
  --     هذا هو المكسب الفعلي من النقل.
  -- ------------------------------------------------------------

  delete from iam.role_permissions rp
  using iam.roles r, iam.permissions p
  where rp.role_id = r.id
    and rp.permission_id = p.id
    and r.code = 'operator'
    and p.code = 'payment.create';

  perform set_config('request.jwt.claim.sub', v_operator::text, true);
  execute 'set local role authenticated';

  if not iam.has_well_permission(v_well_1, 'payment.create')
     and iam.has_well_permission(v_well_1, 'expense.create')
  then
    raise notice 'PASS 18: سحب منح واحد يسري فورًا ولا يمس غيره';
  else
    raise notice 'FAIL 18: سحب المنح لم يسرِ كما يجب';
  end if;

  execute 'reset role';


  -- ------------------------------------------------------------
  -- 19. Legacy role authority is unaffected by that removal —
  --     يثبت أن السلطة صارت في الكتالوج لا في الأدوار النصية.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_operator::text, true);
  execute 'set local role authenticated';

  if iam.has_well_role(v_well_1, array['operator'])
     and not iam.has_well_permission(v_well_1, 'payment.create')
  then
    raise notice 'PASS 19: الدور باقٍ لكن الصلاحية صارت هي الفاصل';
  else
    raise notice 'FAIL 19: الفصل بين الدور والصلاحية غير صحيح';
  end if;

  execute 'reset role';


  -- ------------------------------------------------------------
  -- 20. Unknown permission code is always false — fail closed.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';

  if not iam.has_well_permission(v_well_1, 'money.does.not.exist')
     and not iam.has_well_permission(v_well_1, '')
  then
    raise notice 'PASS 20: الصلاحية المجهولة ترفض دائمًا (fail closed)';
  else
    raise notice 'FAIL 20: صلاحية مجهولة سمحت بالمرور';
  end if;

  execute 'reset role';

end;
$test$;

rollback;
