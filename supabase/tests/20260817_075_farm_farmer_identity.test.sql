begin;

set local timezone to 'UTC';

do $test$
declare
  v_count bigint;

  v_owner_user uuid;
  v_owner_profile uuid;

  v_tenant uuid;
  v_well uuid;
  v_well_2 uuid;

  v_pump uuid;

  v_summary jsonb;
  v_summary_2 jsonb;
  v_summary_3 jsonb;

  v_person uuid;
  v_account uuid;
  v_account_2 uuid;
  v_account_other_well uuid;

  v_farm uuid;
  v_booking uuid;
begin

  -- ============================================================
  -- 1. Schema: العمود الجديد موجود وnullable
  -- ============================================================

  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'ops'
      and table_name = 'farms'
      and column_name = 'farmer_well_account_id'
      and is_nullable = 'YES'
  ) then
    raise notice
      'PASS 1: الأرض تستخدم farmer_well_account_id اختياريًا على مستوى الجدول';
  else
    raise notice
      'FAIL 1: farmer_well_account_id مفقود أو nullability غير صحيحة';
  end if;


  -- ============================================================
  -- 2. العمود القديم أزيل
  -- ============================================================

  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'ops'
      and table_name = 'farms'
      and column_name = 'farmer_profile_id'
  ) then
    raise notice
      'PASS 2: ops.farms لم يعد مرتبطًا بـ Login Profile القديم';
  else
    raise notice
      'FAIL 2: farmer_profile_id القديم ما زال موجودًا داخل ops.farms';
  end if;


  -- ============================================================
  -- 3. القيود البنيوية الأربعة
  -- ============================================================

  select count(*)
  into v_count
  from pg_constraint c
  join pg_class t
    on t.oid = c.conrelid
  join pg_namespace n
    on n.oid = t.relnamespace
  where n.nspname = 'ops'
    and c.conname = any(array[
      'farmer_well_accounts_well_id_id_key',
      'farms_well_farmer_account_fkey',
      'farms_id_farmer_account_key',
      'irrigation_bookings_farm_farmer_account_fkey',
      'irrigation_sessions_farm_farmer_account_fkey'
    ]);

  if v_count = 5 then
    raise notice
      'PASS 3: قيود Farm/Well/Farmer Account مثبتة في قاعدة البيانات';
  else
    raise notice
      'FAIL 3: عدد قيود الاتساق = % بدل 5',
      v_count;
  end if;


  -- ============================================================
  -- 4. Triggers تعطي رفض أعمال واضحًا
  -- ============================================================

  select count(*)
  into v_count
  from pg_trigger tg
  join pg_class t
    on t.oid = tg.tgrelid
  join pg_namespace n
    on n.oid = t.relnamespace
  where not tg.tgisinternal
    and n.nspname = 'ops'
    and tg.tgname = any(array[
      'trg_irrigation_bookings_farm_assignment',
      'trg_irrigation_sessions_farm_assignment'
    ]);

  if v_count = 2 then
    raise notice
      'PASS 4: الحجز والجلسة يملكان حارس Farm/Account دائمًا';
  else
    raise notice
      'FAIL 4: حراس Farm/Account = % بدل 2',
      v_count;
  end if;


  -- ============================================================
  -- 5. العقد الداخلي تغير اسمه الدلالي وبقي SECURITY DEFINER
  -- ============================================================

  if exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'ops'
      and p.proname = 'create_farm'
      and pg_get_function_identity_arguments(p.oid)
          = 'p_well_id uuid, p_name text, p_farmer_well_account_id uuid'
      and p.prosecdef
      and exists (
        select 1
        from unnest(coalesce(p.proconfig, array[]::text[])) cfg
        where cfg like 'search_path=%'
      )
  ) then
    raise notice
      'PASS 5: ops.create_farm يستخدم Farmer Well Account وعقد Definer آمن';
  else
    raise notice
      'FAIL 5: توقيع أو أمان ops.create_farm غير صحيح';
  end if;


  -- ============================================================
  -- 6. api.create_farm آمن ومتاح فقط للأدوار المعتمدة
  -- ============================================================

  if exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'api'
      and p.proname = 'create_farm'
      and pg_get_function_identity_arguments(p.oid)
          = 'p_well_id uuid, p_name text, p_farmer_well_account_id uuid'
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
  ) then
    raise notice
      'PASS 6: api.create_farm هو SECURITY INVOKER بمنح صريحة';
  else
    raise notice
      'FAIL 6: عقد أو منح api.create_farm غير صحيحة';
  end if;


  -- ============================================================
  -- 7. Surface baseline from 075 = at least 32; later safe API additions are allowed
  -- ============================================================

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'api'
    and has_function_privilege(
      'authenticated',
      p.oid,
      'EXECUTE'
    );

  if v_count >= 32
     and (
       select count(*)
       from pg_proc p
       join pg_namespace n
         on n.oid = p.pronamespace
       where n.nspname = 'api'
         and has_function_privilege(
           'service_role',
           p.oid,
           'EXECUTE'
         )
     ) >= 32
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
     and (
       select count(*)
       from pg_proc p
       join pg_namespace n
         on n.oid = p.pronamespace
       where n.nspname = 'api'
         and p.prosecdef
     ) = 0
  then
    raise notice
      'PASS 7: سطح api الأساسي من 075 محفوظ مع السماح بإضافات آمنة لاحقة وanon/Definer = صفر';
  else
    raise notice
      'FAIL 7: سطح api الأساسي من 075 غير محفوظ أو توجد صلاحيات غير آمنة';
  end if;


  -- ============================================================
  -- Setup
  -- ============================================================

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
    'q80-owner@test.local',
    crypt('x', gen_salt('bf')),
    now(),
    now(),
    now()
  )
  returning id into v_owner_user;


  select id
  into v_owner_profile
  from iam.profiles
  where id = v_owner_user;

  if not found then
    insert into iam.profiles (
      id,
      full_name
    )
    values (
      v_owner_user,
      'مالك اختبار ق-80'
    )
    returning id into v_owner_profile;
  end if;


  insert into core.tenants (name)
  values ('جهة اختبار ق-80')
  returning id into v_tenant;


  insert into core.wells (
    tenant_id,
    name
  )
  values (
    v_tenant,
    'بئر اختبار ق-80 الرئيسي'
  )
  returning id into v_well;


  insert into core.wells (
    tenant_id,
    name
  )
  values (
    v_tenant,
    'بئر اختبار ق-80 الآخر'
  )
  returning id into v_well_2;


  insert into core.well_assignments (
    well_id,
    profile_id,
    role,
    status
  )
  values
    (
      v_well,
      v_owner_profile,
      'owner',
      'active'
    ),
    (
      v_well_2,
      v_owner_profile,
      'owner',
      'active'
    );


  insert into core.pumps (
    well_id,
    name,
    power_source
  )
  values (
    v_well,
    'مضخة اختبار ق-80',
    'solar'
  )
  returning id into v_pump;


  perform set_config(
    'request.jwt.claim.sub',
    v_owner_user::text,
    true
  );

  execute 'set local role authenticated';


  -- ============================================================
  -- 8. Farmer field identity does not require login
  -- ============================================================

  v_summary := api.create_farmer(
    v_well,
    'مزارع ميداني أول',
    '700000801'
  );

  v_person :=
    (v_summary ->> 'person_id')::uuid;

  v_account :=
    (v_summary ->> 'farmer_well_account_id')::uuid;


  -- هذا فحص بنيوي للاختبار فقط.
  -- لا نمنح authenticated أي SELECT على auth.users.
  -- نخرج مؤقتًا من دور التطبيق، نفحص كـpostgres،
  -- ثم نعيد authenticated لبقية اختبارات API.
  execute 'reset role';

  if v_person is not null
     and v_account is not null
     and not exists (
       select 1
       from auth.users u
       where u.id = v_person
     )
  then
    raise notice
      'PASS 8: المزارع الميداني موجود دون اشتراط حساب دخول';
  else
    raise notice
      'FAIL 8: هوية المزارع الميداني ما زالت تعتمد على auth.users';
  end if;

  execute 'set local role authenticated';


  v_summary_2 := api.create_farmer(
    v_well,
    'مزارع ميداني ثان',
    '700000802'
  );

  v_account_2 :=
    (v_summary_2 ->> 'farmer_well_account_id')::uuid;


  v_summary_3 := api.create_farmer(
    v_well_2,
    'مزارع البئر الآخر',
    '700000803'
  );

  v_account_other_well :=
    (v_summary_3 ->> 'farmer_well_account_id')::uuid;


  -- ============================================================
  -- 9. إنشاء الأرض بالعلاقة الجديدة
  -- ============================================================

  v_summary := api.create_farm(
    v_well,
    'أرض المزارع الأول',
    v_account
  );

  v_farm :=
    (v_summary ->> 'farm_id')::uuid;


  if exists (
    select 1
    from ops.farms f
    where f.id = v_farm
      and f.well_id = v_well
      and f.farmer_well_account_id = v_account
      and f.status = 'active'
  ) then
    raise notice
      'PASS 9: api.create_farm ربط الأرض بحساب المزارع داخل البئر';
  else
    raise notice
      'FAIL 9: الأرض لم تحمل Farmer Well Account الصحيح';
  end if;


  -- ============================================================
  -- 10. Return contract no longer returns Login Profile
  -- ============================================================

  if (v_summary ->> 'farmer_well_account_id')::uuid = v_account
     and not (v_summary ? 'farmer_profile_id')
  then
    raise notice
      'PASS 10: نتيجة create_farm تستخدم Farmer Well Account ولا تعيد Login Profile';
  else
    raise notice
      'FAIL 10: نتيجة create_farm ما زالت تحمل عقد الهوية القديم';
  end if;


  -- ============================================================
  -- 11. Cross-well assignment rejected
  -- ============================================================

  begin
    perform api.create_farm(
      v_well,
      'أرض بحساب من بئر آخر',
      v_account_other_well
    );

    raise notice
      'FAIL 11: سُمح بربط أرض بحساب مزارع من بئر آخر';

  exception
    when others then
      if position(
        'حساب المزارع غير موجود أو غير فعال في هذا البئر'
        in sqlerrm
      ) > 0 then
        raise notice
          'PASS 11: رُفض Farmer Well Account من بئر آخر';
      else
        raise notice
          'FAIL 11: سبب رفض الحساب عبر البئر غير متوقع: %',
          sqlerrm;
      end if;
  end;


  -- ============================================================
  -- 12. Booking mismatch rejected
  -- ============================================================

  begin
    perform api.create_booking(
      v_well,
      v_account_2,
      v_farm,
      timestamptz '2030-01-01 06:00:00+00',
      timestamptz '2030-01-01 07:00:00+00',
      v_pump,
      null,
      'solar',
      0,
      'اختبار عدم تطابق الأرض'
    );

    raise notice
      'FAIL 12: سُمح بحجز أرض تخص حساب مزارع آخر';

  exception
    when others then
      if position(
        'الأرض لا تخص حساب المزارع المحدد'
        in sqlerrm
      ) > 0 then
        raise notice
          'PASS 12: create_booking رفض Farm/Account mismatch';
      else
        raise notice
          'FAIL 12: سبب رفض mismatch في الحجز غير متوقع: %',
          sqlerrm;
      end if;
  end;


  -- ============================================================
  -- 13. Booking matched succeeds
  -- ============================================================

  v_summary := api.create_booking(
    v_well,
    v_account,
    v_farm,
    timestamptz '2030-01-01 06:00:00+00',
    timestamptz '2030-01-01 07:00:00+00',
    v_pump,
    null,
    'solar',
    0,
    'حجز صحيح لق-80'
  );

  v_booking :=
    (v_summary ->> 'booking_id')::uuid;


  if exists (
    select 1
    from ops.irrigation_bookings b
    where b.id = v_booking
      and b.farm_id = v_farm
      and b.farmer_well_account_id = v_account
      and b.status = 'confirmed'
  ) then
    raise notice
      'PASS 13: الحجز الصحيح احتفظ بعلاقة Farm/Account المتطابقة';
  else
    raise notice
      'FAIL 13: الحجز المتطابق لم يُنشأ بالصورة الصحيحة';
  end if;


  -- ============================================================
  -- 14. Session mismatch rejected
  -- ============================================================

  begin
    perform api.start_irrigation_session(
      v_well,
      v_pump,
      v_farm,
      v_account_2,
      'solar',
      timestamptz '2030-01-02 06:00:00+00',
      null
    );

    raise notice
      'FAIL 14: سُمح ببدء جلسة بحساب لا يملك الأرض';

  exception
    when others then
      if position(
        'الأرض لا تخص حساب المزارع المحدد'
        in sqlerrm
      ) > 0 then
        raise notice
          'PASS 14: start_irrigation_session رفض Farm/Account mismatch';
      else
        raise notice
          'FAIL 14: سبب رفض mismatch في الجلسة غير متوقع: %',
          sqlerrm;
      end if;
  end;


  execute 'reset role';


  -- ============================================================
  -- 15. Direct DML remains zero
  -- ============================================================

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
      'PASS 15: ق-80 لم يعِد أي Direct DML لتطبيق العميل';
  else
    raise notice
      'FAIL 15: ق-80 أعاد % صلاحية Direct DML',
      v_count;
  end if;

end;
$test$;

rollback;
