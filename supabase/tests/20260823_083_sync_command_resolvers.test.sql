begin;

set local timezone to 'UTC';

-- =====================================================================
-- اختبار 083 — مُحلِّلات هوية العملية (ق-114 / W2-01)
--
-- يثبت أن المُحلِّلات:
--   1) موجودة بالتوقيع المتوقَّع و security definer و search_path مثبَّت.
--   2) متاحة لـ authenticated و service_role فقط، لا anon.
--   3) مُنفِّذو 058 لم يبقوا في متناول أي دور عميل.
--   4) تستخرج الجهة من الخادم ولا تقبلها من العميل.
--   5) ترفض بئرًا/جلسة لا يملك المتصل تعيينًا نشطًا عليها.
--   6) لا تكشف وجود معرّفات جهة أخرى (نفس الرسالة للحالتين).
--   7) تُرجع نفس النتيجة المخزَّنة عند تكرار معرّف العملية.
-- =====================================================================

do $test$
declare
  v_count bigint;
  v_count_2 bigint;
  v_owner uuid;
  v_stranger uuid;
  v_inactive uuid;
  v_tenant uuid;
  v_well uuid;
  v_other_tenant uuid;
  v_other_well uuid;
  v_person uuid;
  v_farmer_profile uuid;
  v_farmer_account uuid;
  v_farm uuid;
  v_pump uuid;
  v_session uuid;
  v_command uuid;
  v_first jsonb;
  v_second jsonb;
  v_msg text;
begin

  -- ------------------------------------------------------------
  -- 1. المُحلِّلات الأربعة موجودة بعقد آمن.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'sync'
    and p.proname in (
      'begin_well_command',
      'finish_well_command',
      'begin_session_command',
      'finish_session_command'
    )
    and p.prosecdef
    and exists (
      select 1
      from unnest(coalesce(p.proconfig, array[]::text[])) cfg
      where cfg like 'search_path=%'
    );

  if v_count = 4 then
    raise notice 'PASS 1: المُحلِّلات الأربعة definer بمسار بحث مثبَّت';
  else
    raise notice 'FAIL 1: المُحلِّلات المطابقة = % بدل 4', v_count;
  end if;


  -- ------------------------------------------------------------
  -- 2. التوقيعات كما يتوقعها غلاف api بالضبط.
  -- ------------------------------------------------------------

  if to_regprocedure('sync.begin_well_command(uuid,uuid,text,jsonb)')
       is not null
     and to_regprocedure('sync.finish_well_command(uuid,uuid,text,jsonb)')
       is not null
     and to_regprocedure('sync.begin_session_command(uuid,uuid,text,jsonb)')
       is not null
     and to_regprocedure('sync.finish_session_command(uuid,uuid,text,jsonb)')
       is not null
  then
    raise notice 'PASS 2: توقيعات المُحلِّلات الأربعة مطابقة للمتوقَّع';
  else
    raise notice 'FAIL 2: أحد توقيعات المُحلِّلات غير مطابق';
  end if;


  -- ------------------------------------------------------------
  -- 3. لا مُحلِّل يقبل tenant_id من المتصل.
  --    هذا هو جوهر ق-114: لو وصل tenant من العميل لأمكن حجز
  --    معرّف عملية في جهة أخرى فتبدو عملية الضحية «مكرَّرة».
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'sync'
    and p.proname in (
      'begin_well_command',
      'finish_well_command',
      'begin_session_command',
      'finish_session_command'
    )
    and pg_get_function_identity_arguments(p.oid) like '%tenant%';

  if v_count = 0 then
    raise notice 'PASS 3: لا مُحلِّل يقبل الجهة من العميل';
  else
    raise notice 'FAIL 3: % مُحلِّل يقبل معامل جهة', v_count;
  end if;


  -- ------------------------------------------------------------
  -- 4. المنح: authenticated و service_role نعم، anon لا.
  --    تساوي المستفيدين مع أغلفة api شرط، وإلا وُجدت هوية
  --    تستطيع بدء العملية ولا تستطيع إتمامها.
  -- ------------------------------------------------------------

  select
    count(*) filter (
      where has_function_privilege('authenticated', p.oid, 'EXECUTE')
    ),
    count(*) filter (
      where has_function_privilege('anon', p.oid, 'EXECUTE')
    )
  into v_count, v_count_2
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'sync'
    and p.proname in (
      'begin_well_command',
      'finish_well_command',
      'begin_session_command',
      'finish_session_command'
    );

  if v_count = 4 and v_count_2 = 0 then
    raise notice 'PASS 4: authenticated يملك الأربعة و anon لا يملك شيئًا';
  else
    raise notice 'FAIL 4: authenticated=% anon=% (توقع 4 و0)',
      v_count, v_count_2;
  end if;


  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'sync'
    and p.proname in (
      'begin_well_command',
      'finish_well_command',
      'begin_session_command',
      'finish_session_command'
    )
    and has_function_privilege('service_role', p.oid, 'EXECUTE');

  if v_count = 4 then
    raise notice 'PASS 5: service_role يصل إلى المُحلِّلات كما يصل إلى أغلفة api';
  else
    raise notice 'FAIL 5: service_role يملك % من 4 مُحلِّلات', v_count;
  end if;


  -- ------------------------------------------------------------
  -- 6. مُنفِّذو 058 خرجوا من متناول أدوار العميل.
  --    كانا ممنوحين لـPUBLIC افتراضيًا ولم يُسحبا قط، وهما
  --    يأخذان tenant_id بلا تحقق.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'sync'
    and p.proname in ('begin_command', 'finish_command')
    and (
      has_function_privilege('authenticated', p.oid, 'EXECUTE')
      or has_function_privilege('anon', p.oid, 'EXECUTE')
      or has_function_privilege('public', p.oid, 'EXECUTE')
    );

  if v_count = 0 then
    raise notice 'PASS 6: مُنفِّذو 058 لم يبقوا في متناول أي دور عميل';
  else
    raise notice 'FAIL 6: % من مُنفِّذي 058 ما زال في متناول العميل', v_count;
  end if;


  -- ------------------------------------------------------------
  -- 7. المُحلِّل لا يقرر صلاحية: لا يسأل عن رمز صلاحية ولا دور.
  --    القرار يبقى في الدوال الداخلية (ق-113).
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'sync'
    and p.proname in (
      'begin_well_command',
      'finish_well_command',
      'begin_session_command',
      'finish_session_command'
    )
    and (
      pg_get_functiondef(p.oid) like '%has_well_permission%'
      or pg_get_functiondef(p.oid) like '%has_well_role%'
    );

  if v_count = 0 then
    raise notice 'PASS 7: المُحلِّل حدّ نطاق لا سلطة صلاحية';
  else
    raise notice 'FAIL 7: % مُحلِّل يتخذ قرار صلاحية', v_count;
  end if;


  -- ============================================================
  -- تركيبة حيّة: جهتان، بئر لكل منهما، وثلاث هويات.
  -- ============================================================

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q114r-owner@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_owner;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q114r-stranger@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_stranger;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q114r-inactive@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_inactive;

  insert into core.tenants (name)
  values ('جهة اختبار مُحلِّلات 083')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'بئر اختبار مُحلِّلات 083')
  returning id into v_well;

  insert into core.tenants (name)
  values ('جهة أخرى لا علاقة لها 083')
  returning id into v_other_tenant;

  insert into core.wells (tenant_id, name)
  values (v_other_tenant, 'بئر الجهة الأخرى 083')
  returning id into v_other_well;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values
    (v_well, v_owner, 'owner', 'active'),
    (v_well, v_inactive, 'operator', 'inactive');

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع مُحلِّلات 083', 'مزارع محللات 083')
  returning id into v_person;

  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person)
  returning id into v_farmer_profile;

  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_farmer_profile, v_well, 'FWA-083')
  returning id into v_farmer_account;

  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well, 'مزرعة مُحلِّلات 083', v_farmer_account)
  returning id into v_farm;

  insert into core.pumps (well_id, name, power_source)
  values (v_well, 'مضخة مُحلِّلات 083', 'solar')
  returning id into v_pump;

  -- جلسة بإدراج مباشر لا عبر الإجراء: 083 لا تخصّ منطق الجلسة،
  -- ووجود صفّ جلسة يكفي لاختبار استخراج الجهة عبر بئرها. هذا
  -- يجنّب الاختبار الاعتماد على تركيبة التسعير كاملة.
  insert into ops.irrigation_sessions (
    well_id, pump_id, farm_id, farmer_well_account_id,
    operator_profile_id, started_at, status
  )
  values (
    v_well, v_pump, v_farm, v_farmer_account,
    v_owner, timestamptz '2026-08-10 08:00:00+00', 'open'
  )
  returning id into v_session;


  -- ------------------------------------------------------------
  -- 8. المُحلِّل يستخرج الجهة الصحيحة من البئر.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';

  v_command := gen_random_uuid();
  v_first := sync.begin_well_command(v_well, v_command, 'probe_well', null);

  execute 'reset role';

  if coalesce((v_first ->> 'duplicate')::boolean, true) = false
     and exists (
       select 1
       from sync.processed_commands pc
       where pc.command_id = v_command
         and pc.tenant_id = v_tenant
         and pc.status = 'processing'
     )
  then
    raise notice 'PASS 8: المُحلِّل حجز العملية في جهة البئر الصحيحة';
  else
    raise notice 'FAIL 8: الحجز لم يقع في الجهة الصحيحة: %', v_first;
  end if;


  -- ------------------------------------------------------------
  -- 9. تكرار نفس معرّف العملية يُعيد النتيجة المخزَّنة.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';

  perform sync.finish_well_command(
    v_well, v_command, 'accepted', jsonb_build_object('probe', 'أول')
  );

  v_second := sync.begin_well_command(v_well, v_command, 'probe_well', null);

  execute 'reset role';

  select count(*)
  into v_count
  from sync.processed_commands pc
  where pc.command_id = v_command;

  if (v_second ->> 'duplicate')::boolean
     and v_second ->> 'status' = 'accepted'
     and v_second -> 'response' = jsonb_build_object('probe', 'أول')
     and v_count = 1
  then
    raise notice 'PASS 9: الإعادة أرجعت النتيجة الأولى نفسها بصفّ واحد';
  else
    raise notice 'FAIL 9: الإعادة لم تُرجع النتيجة المخزَّنة: % (صفوف=%)',
      v_second, v_count;
  end if;


  -- ------------------------------------------------------------
  -- 10. غريب تمامًا لا يستطيع حجز عملية في بئر جهة أخرى.
  --     بلا هذا الشرط كان بإمكانه تلويث جدول جهة لا يملكها.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_stranger::text, true);
  execute 'set local role authenticated';

  begin
    perform sync.begin_well_command(
      v_well, gen_random_uuid(), 'probe_well', null
    );
    v_msg := 'ALLOWED';
  exception
    when others then
      v_msg := sqlerrm;
  end;

  execute 'reset role';

  if v_msg <> 'ALLOWED'
     and position('لا تملك وصولًا' in v_msg) > 0
  then
    raise notice 'PASS 10: الغريب مُنع من حجز عملية في بئر ليس له';
  else
    raise notice 'FAIL 10: نتيجة الغريب غير متوقعة: %', v_msg;
  end if;


  -- ------------------------------------------------------------
  -- 11. تعيين غير نشط = لا وصول. سحب التعيين يسحب القدرة فورًا.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_inactive::text, true);
  execute 'set local role authenticated';

  begin
    perform sync.begin_well_command(
      v_well, gen_random_uuid(), 'probe_well', null
    );
    v_msg := 'ALLOWED';
  exception
    when others then
      v_msg := sqlerrm;
  end;

  execute 'reset role';

  if v_msg <> 'ALLOWED' then
    raise notice 'PASS 11: التعيين غير النشط لا يستطيع حجز عملية';
  else
    raise notice 'FAIL 11: تعيين غير نشط نجح في حجز عملية';
  end if;


  -- ------------------------------------------------------------
  -- 12. لا كشف للوجود: «بئر جهة أخرى» و«بئر غير موجود» يعطيان
  --     الرسالة نفسها، فلا يصلح المُحلِّل أداة استكشاف.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';

  begin
    perform sync.begin_well_command(
      v_other_well, gen_random_uuid(), 'probe_well', null
    );
    v_msg := 'ALLOWED';
  exception
    when others then
      v_msg := sqlerrm;
  end;

  declare
    v_msg_absent text;
  begin
    begin
      perform sync.begin_well_command(
        gen_random_uuid(), gen_random_uuid(), 'probe_well', null
      );
      v_msg_absent := 'ALLOWED';
    exception
      when others then
        v_msg_absent := sqlerrm;
    end;

    execute 'reset role';

    if v_msg <> 'ALLOWED'
       and v_msg_absent <> 'ALLOWED'
       and v_msg = v_msg_absent
    then
      raise notice 'PASS 12: رسالة واحدة للحالتين فلا يُكشف وجود جهة أخرى';
    else
      raise notice 'FAIL 12: الرسالتان مختلفتان: [%] مقابل [%]',
        v_msg, v_msg_absent;
    end if;
  end;


  -- ------------------------------------------------------------
  -- 13. مُحلِّل الجلسة يستخرج الجهة عبر بئر الجلسة.
  --     الجلسة لا تحمل الجهة مباشرة في عقد الاستدعاء.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';

  v_command := gen_random_uuid();
  v_first := sync.begin_session_command(
    v_session, v_command, 'probe_session', null
  );

  execute 'reset role';

  if coalesce((v_first ->> 'duplicate')::boolean, true) = false
     and exists (
       select 1
       from sync.processed_commands pc
       where pc.command_id = v_command
         and pc.tenant_id = v_tenant
         and pc.entity_id = v_session
     )
  then
    raise notice 'PASS 13: مُحلِّل الجلسة ربط العملية بالجهة والجلسة معًا';
  else
    raise notice 'FAIL 13: ربط مُحلِّل الجلسة غير صحيح: %', v_first;
  end if;


  -- ------------------------------------------------------------
  -- 14. غريب لا يستطيع حجز عملية على جلسة ليست في بئره.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_stranger::text, true);
  execute 'set local role authenticated';

  begin
    perform sync.begin_session_command(
      v_session, gen_random_uuid(), 'probe_session', null
    );
    v_msg := 'ALLOWED';
  exception
    when others then
      v_msg := sqlerrm;
  end;

  execute 'reset role';

  if v_msg <> 'ALLOWED'
     and position('لا تملك وصولًا' in v_msg) > 0
  then
    raise notice 'PASS 14: الغريب مُنع من حجز عملية على جلسة ليست له';
  else
    raise notice 'FAIL 14: نتيجة الغريب على الجلسة غير متوقعة: %', v_msg;
  end if;


  -- ------------------------------------------------------------
  -- 15. معرّف عملية مطلوب: لا حجز بلا هوية للعملية.
  -- ------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';

  begin
    perform sync.begin_well_command(v_well, null, 'probe_well', null);
    v_msg := 'ALLOWED';
  exception
    when others then
      v_msg := sqlerrm;
  end;

  execute 'reset role';

  if v_msg <> 'ALLOWED'
     and position('معرّف العملية مطلوب' in v_msg) > 0
  then
    raise notice 'PASS 15: رُفض الحجز بلا معرّف عملية';
  else
    raise notice 'FAIL 15: نتيجة الحجز بلا معرّف غير متوقعة: %', v_msg;
  end if;


  -- ------------------------------------------------------------
  -- 16. 083 لم تلمس جدولًا ولا سياسة: Direct DML بقي مغلقًا.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
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
    raise notice 'PASS 16: Direct DML بقي مغلقًا بعد 083';
  else
    raise notice 'FAIL 16: عاد % مسار Direct DML بعد 083', v_count;
  end if;

end;
$test$;

rollback;
