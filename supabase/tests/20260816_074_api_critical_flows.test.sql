begin;

do $test$
declare
  v_count integer;
  v_owner_user uuid;
  v_owner_profile uuid;
  v_intruder_user uuid;
  v_intruder_profile uuid;
  v_well uuid;
  v_tenant uuid;
  v_shift uuid;
  v_expense uuid;
  v_handover uuid;
  v_result text;
begin

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'api'
    and p.proname = any(array[
      'create_tenant_with_well',
      'record_expense',
      'decide_expense',
      'open_shift',
      'close_shift',
      'declare_handover',
      'confirm_handover',
      'settle_handover',
      'request_session_transfer',
      'respond_session_transfer',
      'close_period',
      'calculate_profit_distribution',
      'approve_profit_distribution',
      'accrue_payroll',
      'pay_salary'
    ]);

  if v_count = 15 then
    raise notice 'PASS 1: أغلفة التدفقات الحرجة الخمسة عشر في 074 موجودة';
  else
    raise notice 'FAIL 1: عدد أغلفة 074 = % بدل 15', v_count;
  end if;


  -- لا يثبت 074 العدد العالمي إلى الأبد؛
  -- الهجرات اللاحقة قد توسع العقد بصورة معتمدة.
  -- المطلوب هنا أن كل دالة متاحة لـauthenticated
  -- تحمل grant متناظرًا لـservice_role وأن anon يبقى صفرًا.
  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'api'
    and (
      has_function_privilege(
        'authenticated',
        p.oid,
        'EXECUTE'
      )
      is distinct from
      has_function_privilege(
        'service_role',
        p.oid,
        'EXECUTE'
      )
    );

  if v_count = 0
     and (
       select count(*)
       from pg_proc p
       join pg_namespace n
         on n.oid = p.pronamespace
       where n.nspname = 'api'
         and has_function_privilege(
           'anon',
           p.oid,
           'EXECUTE'
         )
     ) = 0
  then
    raise notice 'PASS 2: منح api متناظرة للأدوار المعتمدة وanon محجوب بالكامل';
  else
    raise notice 'FAIL 2: منح سطح api لا تطابق قواعد العقد';
  end if;


  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'api'
    and p.prosecdef;

  if v_count = 0 then
    raise notice 'PASS 3: كل دوال api بقيت SECURITY INVOKER';
  else
    raise notice 'FAIL 3: توجد % دالة SECURITY DEFINER داخل api', v_count;
  end if;


  if
    to_regprocedure('api.open_shift(uuid)') is not null
    and to_regprocedure('api.open_shift(uuid,uuid)') is null

    and to_regprocedure(
      'api.record_expense(uuid,text,bigint,text,text,boolean,text,text,uuid)'
    ) is not null
    and to_regprocedure(
      'api.record_expense(uuid,text,bigint,text,uuid,text,boolean,text,text,uuid)'
    ) is null

    and to_regprocedure(
      'api.confirm_handover(uuid,bigint,text)'
    ) is not null
    and to_regprocedure(
      'api.confirm_handover(uuid,bigint,uuid,text)'
    ) is null

    and to_regprocedure('api.close_period(uuid)') is not null
    and to_regprocedure('api.close_period(uuid,uuid)') is null

    and to_regprocedure(
      'api.calculate_profit_distribution(uuid,timestamptz,timestamptz,bigint)'
    ) is not null
    and to_regprocedure(
      'api.calculate_profit_distribution(uuid,timestamptz,timestamptz,uuid,bigint)'
    ) is null

    and to_regprocedure(
      'api.accrue_payroll(uuid,uuid,date,date,bigint,bigint)'
    ) is not null
    and to_regprocedure(
      'api.accrue_payroll(uuid,uuid,date,date,bigint,bigint,uuid)'
    ) is null

    and to_regprocedure('api.pay_salary(uuid)') is not null
    and to_regprocedure('api.pay_salary(uuid,uuid)') is null
  then
    raise notice 'PASS 4: عقد 074 لا يكشف معاملات هوية المنفذ للعميل';
  else
    raise notice 'FAIL 4: يوجد توقيع api يسمح بتمرير هوية المنفذ';
  end if;


  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at
  ) values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'owner074@test.local',
    crypt('x', gen_salt('bf')),
    now(), now(), now()
  ) returning id into v_owner_user;

  select id into v_owner_profile
  from iam.profiles
  where id = v_owner_user;

  if not found then
    insert into iam.profiles (id, full_name)
    values (v_owner_user, 'مالك اختبار 074')
    returning id into v_owner_profile;
  end if;


  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at
  ) values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'intruder074@test.local',
    crypt('x', gen_salt('bf')),
    now(), now(), now()
  ) returning id into v_intruder_user;

  select id into v_intruder_profile
  from iam.profiles
  where id = v_intruder_user;

  if not found then
    insert into iam.profiles (id, full_name)
    values (v_intruder_user, 'مستخدم بلا صلاحية 074')
    returning id into v_intruder_profile;
  end if;


  perform set_config(
    'request.jwt.claim.sub',
    v_owner_user::text,
    true
  );

  execute 'set local role authenticated';


  v_well := api.create_tenant_with_well(
    'جهة اختبار عقد 074',
    'بئر اختبار عقد 074'
  );

  select w.tenant_id
  into v_tenant
  from core.wells w
  where w.id = v_well;

  if v_well is not null
     and v_tenant is not null
     and exists (
       select 1
       from core.well_assignments wa
       where wa.well_id = v_well
         and wa.profile_id = v_owner_profile
         and wa.role = 'owner'
         and wa.status = 'active'
     ) then
    raise notice 'PASS 5: api.create_tenant_with_well أنشأ البئر وربط المستخدم مالكًا';
  else
    raise notice 'FAIL 5: إنشاء الجهة والبئر عبر api غير مكتمل';
  end if;


  v_shift := api.open_shift(v_well);

  if exists (
    select 1
    from ops.shifts s
    where s.id = v_shift
      and s.well_id = v_well
      and s.operator_profile_id = v_owner_profile
      and s.status = 'open'
  ) then
    raise notice 'PASS 6: api.open_shift اشتق هوية مشغل المناوبة من المستخدم الحالي';
  else
    raise notice 'FAIL 6: هوية المناوبة أو حالتها غير صحيحة';
  end if;


  v_expense := api.record_expense(
    v_well,
    'other',
    1000,
    'مصروف اختبار عقد 074',
    null,
    true,
    'other',
    'اختبار API',
    null
  );

  if exists (
    select 1
    from finance.expenses e
    where e.id = v_expense
      and e.well_id = v_well
      and e.created_by = v_owner_profile
      and e.amount_minor = 1000
  ) then
    raise notice 'PASS 7: api.record_expense ثبت هوية المنشئ الفعلية';
  else
    raise notice 'FAIL 7: المصروف لم يحمل هوية المستخدم الصحيحة';
  end if;


  v_handover := api.declare_handover(
    v_shift,
    500,
    null,
    'مالك البئر',
    'اختبار التسليم'
  );

  v_result := api.confirm_handover(
    v_handover,
    500,
    null
  );

  if v_result = 'confirmed'
     and exists (
       select 1
       from ops.shift_handovers h
       where h.id = v_handover
         and h.from_profile_id = v_owner_profile
         and h.confirmed_by = v_owner_profile
         and h.status = 'confirmed'
     ) then
    raise notice 'PASS 8: إقرار وتسليم المناوبة ثبتا هويتي المرسل والمؤكد';
  else
    raise notice 'FAIL 8: هوية أو حالة إقرار التسليم غير صحيحة';
  end if;


  perform api.close_shift(
    v_shift,
    false
  );

  if exists (
    select 1
    from ops.shifts s
    where s.id = v_shift
      and s.status = 'closed'
  ) then
    raise notice 'PASS 9: api.close_shift أغلق المناوبة بصورة صحيحة';
  else
    raise notice 'FAIL 9: المناوبة لم تغلق';
  end if;


  perform set_config(
    'request.jwt.claim.sub',
    v_intruder_user::text,
    true
  );

  begin
    perform api.open_shift(v_well);
    raise notice 'FAIL 10: مستخدم بلا تعيين استطاع فتح مناوبة';
  exception
    when others then
      if position(
        'لا تملك صلاحية بدء مناوبة'
        in sqlerrm
      ) > 0 then

        begin
          perform api.record_expense(
            v_well,
            'other',
            100,
            'مصروف غير مصرح',
            null,
            true,
            'other',
            null,
            null
          );

          raise notice 'FAIL 10: مستخدم بلا تعيين استطاع تسجيل مصروف';
        exception
          when others then
            if position(
              'لا تملك صلاحية تسجيل مصروف'
              in sqlerrm
            ) > 0 then
              raise notice 'PASS 10: مستخدم بلا تعيين رُفض من المناوبة والمصروف';
            else
              raise notice 'FAIL 10: سبب رفض المصروف غير المتوقع: %', sqlerrm;
            end if;
        end;

      else
        raise notice 'FAIL 10: سبب رفض المناوبة غير المتوقع: %', sqlerrm;
      end if;
  end;


  if
    to_regprocedure('api.close_period(uuid)') is not null
    and to_regprocedure(
      'api.calculate_profit_distribution(uuid,timestamptz,timestamptz,bigint)'
    ) is not null
    and to_regprocedure(
      'api.approve_profit_distribution(uuid)'
    ) is not null
    and to_regprocedure(
      'api.accrue_payroll(uuid,uuid,date,date,bigint,bigint)'
    ) is not null
    and to_regprocedure(
      'api.pay_salary(uuid)'
    ) is not null
  then
    raise notice 'PASS 11: الإقفال والأرباح والرواتب أصبحت ضمن عقد api';
  else
    raise notice 'FAIL 11: عقد مالي حرج مفقود من api';
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
    raise notice 'PASS 12: Direct DML بقي صفرًا بعد 074 والهجرات اللاحقة';
  else
    raise notice 'FAIL 12: عاد Direct DML بعد عقد api';
  end if;


  execute 'reset role';
end;
$test$;

rollback;
