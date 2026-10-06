-- =====================================================================
-- P2 Automated Execution Proof — Phase 1 (LOCAL ONLY)
-- ق-135 / ق-136: هوية تنفيذ تقنية منفصلة، Actor نظامي ثابت، مشغّل
-- بشري حقيقي، إعادة تفويض ذرية، P1-B منسق الأعمال الوحيد.
-- التزامن الحقيقي متعدد الاتصالات في scripts/p2_automation_concurrency_proof.py.
-- =====================================================================

begin;

set local timezone to 'UTC';

create temporary table p2_seed (
  tenant_id uuid not null,
  farmer_profile_id uuid not null,
  owner_profile_id uuid not null,
  operator_profile_id uuid not null
) on commit drop;

do $seed$
declare
  v_tenant uuid;
  v_person uuid;
  v_farmer uuid;
  v_owner uuid := gen_random_uuid();
  v_operator uuid := gen_random_uuid();
begin
  insert into core.tenants (name)
  values ('جهة P2 Automation Phase 1')
  returning id into v_tenant;

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع P2', 'مزارع P2')
  returning id into v_person;

  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person)
  returning id into v_farmer;

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at
  ) values
    (v_owner, '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'p2-owner@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now()),
    (v_operator, '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'p2-operator@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now());

  insert into iam.profiles (id, full_name) values
    (v_owner, 'مالك P2'),
    (v_operator, 'مشغل P2')
  on conflict (id) do nothing;

  insert into p2_seed values (v_tenant, v_farmer, v_owner, v_operator);
end;
$seed$;

create function pg_temp.make_p2_case(p_label text)
returns jsonb
language plpgsql
as $function$
declare
  v_seed p2_seed%rowtype;
  v_well uuid;
  v_assignment uuid;
  v_authorization_revision bigint;
  v_account uuid;
  v_farm uuid;
  v_pump uuid;
  v_current_booking uuid;
  v_next_booking uuid;
  v_current_session uuid;
  v_chain uuid;
  v_auto_revision bigint;
  v_policy_version bigint;
  v_now timestamptz := date_trunc('minute', clock_timestamp());
  v_result jsonb;
begin
  select * into v_seed from p2_seed limit 1;

  insert into core.wells (tenant_id, name)
  values (v_seed.tenant_id, 'بئر ' || p_label)
  returning id into v_well;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values
    (v_well, v_seed.owner_profile_id, 'owner', 'active'),
    (v_well, v_seed.operator_profile_id, 'operator', 'active');

  select wa.id, wa.authorization_revision
    into v_assignment, v_authorization_revision
  from core.well_assignments wa
  where wa.well_id = v_well
    and wa.profile_id = v_seed.operator_profile_id
    and wa.role = 'operator';

  insert into ops.farmer_well_accounts (
    tenant_id, farmer_profile_id, well_id, public_code
  ) values (
    v_seed.tenant_id, v_seed.farmer_profile_id, v_well,
    'FWA-' || p_label
  ) returning id into v_account;

  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well, 'أرض ' || p_label, v_account)
  returning id into v_farm;

  insert into core.pumps (well_id, name, power_source, status)
  values (v_well, 'مضخة ' || p_label, 'diesel', 'active')
  returning id into v_pump;

  insert into billing.well_pricing (
    well_id, price_per_hour_minor, period_start
  ) values (v_well, 5000, current_date - 1);

  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values (
    v_seed.tenant_id, 'CUR-' || p_label, v_well, v_account, v_farm,
    v_now - interval '130 minutes', v_now - interval '10 minutes', 120,
    'well_diesel', 'confirmed'
  ) returning id into v_current_booking;

  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values (
    v_seed.tenant_id, 'NEXT-' || p_label, v_well, v_account, v_farm,
    v_now - interval '5 minutes', v_now + interval '55 minutes', 60,
    'well_diesel', 'confirmed'
  ) returning id into v_next_booking;

  perform set_config(
    'request.jwt.claim.sub', v_seed.operator_profile_id::text, true
  );

  v_result := api.set_well_booking_automation(
    v_well, true, 0::bigint, gen_random_uuid()
  );

  v_result := ops.start_booking_session_core(
    v_current_booking,
    v_seed.operator_profile_id,
    v_now - interval '130 minutes'
  );
  v_current_session := (v_result ->> 'session_id')::uuid;

  select c.id into v_chain
  from ops.booking_transition_chains c
  where c.well_id = v_well and c.status = 'active';

  select ws.booking_auto_transition_revision
    into v_auto_revision
  from core.well_settings ws
  where ws.well_id = v_well;

  select ctl.policy_version into v_policy_version
  from ops.booking_automation_control ctl
  where ctl.control_key = 'global';

  return jsonb_build_object(
    'tenant_id', v_seed.tenant_id,
    'well_id', v_well,
    'operator_profile_id', v_seed.operator_profile_id,
    'operator_assignment_id', v_assignment,
    'authorization_revision', v_authorization_revision,
    'chain_id', v_chain,
    'current_session_id', v_current_session,
    'next_booking_id', v_next_booking,
    'decision_revision', 0,
    'automation_revision', v_auto_revision,
    'policy_version', v_policy_version
  );
end;
$function$;

create function pg_temp.call_automation(
  p_context jsonb,
  p_command_id uuid,
  p_attempt_id uuid,
  p_runtime_run_id uuid
)
returns jsonb
language plpgsql
as $function$
begin
  return ops.execute_booking_transition_automation(
    (p_context ->> 'well_id')::uuid,
    (p_context ->> 'chain_id')::uuid,
    (p_context ->> 'current_session_id')::uuid,
    (p_context ->> 'next_booking_id')::uuid,
    (p_context ->> 'decision_revision')::bigint,
    (p_context ->> 'automation_revision')::bigint,
    (p_context ->> 'policy_version')::bigint,
    p_command_id,
    p_attempt_id,
    p_runtime_run_id
  );
end;
$function$;

do $test$
declare
  v_seed p2_seed%rowtype;
  v_ctx jsonb;
  v_res jsonb;
  v_res2 jsonb;
  v_command uuid;
  v_attempt uuid;
  v_run uuid;
  v_second_operator uuid;
  v_new_operator uuid;
  v_count integer;
  v_session_count integer;
  v_charge_count integer;
begin
  select * into v_seed from p2_seed limit 1;

  update ops.booking_automation_control
  set execution_enabled = true,
      policy_version = policy_version + 1,
      updated_at = clock_timestamp()
  where control_key = 'global';

  -- AP1: المسار البشري القديم يبقى كما هو ولا يعتمد على دور الأتمتة.
  v_ctx := pg_temp.make_p2_case('AP1-HUMAN');
  perform set_config(
    'request.jwt.claim.sub', v_seed.operator_profile_id::text, true
  );
  v_res := ops.execute_booking_transition(
    (v_ctx ->> 'well_id')::uuid,
    (v_ctx ->> 'decision_revision')::bigint,
    gen_random_uuid()
  );
  if (v_res ->> 'auto_transition_executed')::boolean
     and (v_res ->> 'executed_by')::uuid = v_seed.operator_profile_id then
    raise notice 'PASS AP1: المسار البشري بقي بهوية auth الحقيقية والعقد القديم';
  else
    raise notice 'FAIL AP1: تغير المسار البشري أو إسناده: %', v_res;
  end if;

  -- AP2–AP5: لا anon/authenticated/operator/service_role على المدخل الداخلي.
  v_ctx := pg_temp.make_p2_case('AP2-AUTH');
  perform set_config('request.jwt.claim.sub', '', true);

  execute 'set local role anon';
  begin
    perform pg_temp.call_automation(
      v_ctx, gen_random_uuid(), gen_random_uuid(), gen_random_uuid()
    );
    raise notice 'FAIL AP2: anon استدعى مسار الأتمتة';
  exception when insufficient_privilege then
    raise notice 'PASS AP2: anon لا يستدعي مسار الأتمتة';
  end;
  execute 'reset role';

  execute 'set local role authenticated';
  begin
    perform pg_temp.call_automation(
      v_ctx, gen_random_uuid(), gen_random_uuid(), gen_random_uuid()
    );
    raise notice 'FAIL AP3: authenticated عادي استدعى مسار الأتمتة';
  exception when insufficient_privilege then
    raise notice 'PASS AP3: authenticated العادي محجوب';
  end;
  execute 'reset role';

  perform set_config(
    'request.jwt.claim.sub', v_seed.operator_profile_id::text, true
  );
  execute 'set local role authenticated';
  begin
    perform pg_temp.call_automation(
      v_ctx, gen_random_uuid(), gen_random_uuid(), gen_random_uuid()
    );
    raise notice 'FAIL AP4: المشغل اختار Actor الأتمتة لنفسه';
  exception when insufficient_privilege then
    if position('actor' in lower(pg_get_function_arguments(
      'ops.execute_booking_transition_automation'::regproc
    ))) = 0
       and position('operator' in lower(pg_get_function_arguments(
      'ops.execute_booking_transition_automation'::regproc
    ))) = 0 then
      raise notice 'PASS AP4: المشغل محجوب والمدخل لا يقبل Actor أو Operator';
    else
      raise notice 'FAIL AP4: توقيع المدخل يسمح باختيار هوية أعمال';
    end if;
  end;
  execute 'reset role';

  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role service_role';
  begin
    perform pg_temp.call_automation(
      v_ctx, gen_random_uuid(), gen_random_uuid(), gen_random_uuid()
    );
    raise notice 'FAIL AP5: service_role أصبح Actor أعمال';
  exception when insufficient_privilege then
    raise notice 'PASS AP5: service_role وحده لا يستدعي الأتمتة';
  end;
  execute 'reset role';

  -- AP6/AP17/AP18: السياق التقني الموثوق ينجح بلا auth.uid، والمشغّل بشري.
  v_ctx := pg_temp.make_p2_case('AP6-TRUSTED');
  v_command := gen_random_uuid();
  v_attempt := gen_random_uuid();
  v_run := gen_random_uuid();
  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role booking_automation_executor';
  v_res := pg_temp.call_automation(v_ctx, v_command, v_attempt, v_run);
  execute 'reset role';

  if v_res ->> 'result' = 'accepted'
     and v_res ->> 'actor_kind' = 'system'
     and v_res ->> 'actor_ref' = 'booking_automation_system' then
    raise notice 'PASS AP6: المسار الموثوق نجح بسياق نظامي بلا auth مزيف';
  else
    raise notice 'FAIL AP6: المسار الموثوق لم ينجح: %', v_res;
  end if;

  if exists (
    select 1
    from ops.irrigation_sessions s
    where s.booking_id = (v_ctx ->> 'next_booking_id')::uuid
      and s.operator_profile_id = v_seed.operator_profile_id
  ) then
    raise notice 'PASS AP17: operator_profile_id بقي المشغل البشري الحقيقي';
  else
    raise notice 'FAIL AP17: الجلسة الجديدة لا تحمل المشغل الحقيقي';
  end if;

  if exists (
    select 1
    from audit.booking_automation_attempts a
    where a.attempt_id = v_attempt
      and a.actor_kind = 'system'
      and a.actor_ref = 'booking_automation_system'
      and a.executor_id = 'booking_automation_executor'
      and a.operator_profile_id = v_seed.operator_profile_id
      and a.command_id = v_command
      and a.runtime_run_id = v_run
      and a.result = 'accepted'
  ) then
    raise notice 'PASS AP18: التدقيق يفصل Actor وExecutor وOperator';
  else
    raise notice 'FAIL AP18: إسناد التدقيق ناقص أو مختلط';
  end if;

  -- AP7: غياب أي تعيين مشغل صالح يرفض مغلقًا.
  v_ctx := pg_temp.make_p2_case('AP7-NONE');
  delete from core.well_assignments
  where id = (v_ctx ->> 'operator_assignment_id')::uuid;
  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role booking_automation_executor';
  v_res := pg_temp.call_automation(
    v_ctx, gen_random_uuid(), gen_random_uuid(), gen_random_uuid()
  );
  execute 'reset role';
  if v_res ->> 'result' = 'rejected'
     and v_res ->> 'failure_reason' = 'operator_unassigned' then
    raise notice 'PASS AP7: غياب المشغل الصالح يرفض مغلقًا';
  else
    raise notice 'FAIL AP7: غياب المشغل لم يرفض كما يجب: %', v_res;
  end if;

  -- AP8: أكثر من مشغل نشط حالة ملتبسة لا اختيار تلقائيًا.
  v_ctx := pg_temp.make_p2_case('AP8-MULTI');
  v_second_operator := gen_random_uuid();
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at
  ) values (
    v_second_operator, '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'p2-second@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  );
  insert into iam.profiles (id, full_name)
  values (v_second_operator, 'مشغل P2 ثان')
  on conflict (id) do update set full_name = excluded.full_name;
  insert into core.well_assignments (well_id, profile_id, role, status)
  values ((v_ctx ->> 'well_id')::uuid, v_second_operator, 'operator', 'active');
  execute 'set local role booking_automation_executor';
  v_res := pg_temp.call_automation(
    v_ctx, gen_random_uuid(), gen_random_uuid(), gen_random_uuid()
  );
  execute 'reset role';
  if v_res ->> 'failure_reason' = 'ambiguous_responsible_operator' then
    raise notice 'PASS AP8: تعدد المشغلين يرفض بلا اختيار ضمني';
  else
    raise notice 'FAIL AP8: تعدد المشغلين لم يرفض: %', v_res;
  end if;

  -- AP9: سحب التفويض بعد Discovery يرفض، والجلسة الحالية تبقى مفتوحة.
  v_ctx := pg_temp.make_p2_case('AP9-REVOKED');
  update core.well_assignments
  set status = 'inactive', updated_at = now()
  where id = (v_ctx ->> 'operator_assignment_id')::uuid;
  execute 'set local role booking_automation_executor';
  v_res := pg_temp.call_automation(
    v_ctx, gen_random_uuid(), gen_random_uuid(), gen_random_uuid()
  );
  execute 'reset role';
  if v_res ->> 'failure_reason' = 'revoked_delegation' then
    raise notice 'PASS AP9: سحب التفويض قبل الحسم يرفض';
  else
    raise notice 'FAIL AP9: سحب التفويض لم يرفض: %', v_res;
  end if;
  if exists (
    select 1 from ops.irrigation_sessions s
    where s.id = (v_ctx ->> 'current_session_id')::uuid
      and s.status = 'open' and s.ended_at is null
  ) then
    raise notice 'PASS AP19: رفض الأتمتة لم ينه الجلسة الجارية';
  else
    raise notice 'FAIL AP19: الرفض قطع الجلسة الجارية';
  end if;

  -- AP10: تغيير المشغل لا ينقل ON بصمت.
  v_ctx := pg_temp.make_p2_case('AP10-CHANGED');
  update core.well_assignments
  set status = 'inactive', updated_at = now()
  where id = (v_ctx ->> 'operator_assignment_id')::uuid;
  v_new_operator := gen_random_uuid();
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at
  ) values (
    v_new_operator, '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'p2-new@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  );
  insert into iam.profiles (id, full_name)
  values (v_new_operator, 'مشغل P2 جديد')
  on conflict (id) do update set full_name = excluded.full_name;
  insert into core.well_assignments (well_id, profile_id, role, status)
  values ((v_ctx ->> 'well_id')::uuid, v_new_operator, 'operator', 'active');
  execute 'set local role booking_automation_executor';
  v_res := pg_temp.call_automation(
    v_ctx, gen_random_uuid(), gen_random_uuid(), gen_random_uuid()
  );
  execute 'reset role';
  if v_res ->> 'failure_reason' = 'operator_changed_pending_confirmation' then
    raise notice 'PASS AP10: تغيير المشغل يحتاج إعادة تفويض وON جديدًا';
  else
    raise notice 'FAIL AP10: ON انتقل إلى المشغل الجديد: %', v_res;
  end if;

  -- AP11: OFF الذي سبق القرار الذري يمنع الانتقال.
  v_ctx := pg_temp.make_p2_case('AP11-OFF');
  perform set_config(
    'request.jwt.claim.sub', v_seed.operator_profile_id::text, true
  );
  perform api.set_well_booking_automation(
    (v_ctx ->> 'well_id')::uuid,
    false,
    (v_ctx ->> 'automation_revision')::bigint,
    gen_random_uuid()
  );
  select ws.booking_auto_transition_revision
    into v_count
  from core.well_settings ws
  where ws.well_id = (v_ctx ->> 'well_id')::uuid;
  v_ctx := jsonb_set(v_ctx, '{automation_revision}', to_jsonb(v_count));
  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role booking_automation_executor';
  v_res := pg_temp.call_automation(
    v_ctx, gen_random_uuid(), gen_random_uuid(), gen_random_uuid()
  );
  execute 'reset role';
  if v_res ->> 'failure_reason' = 'booking_auto_transition_disabled' then
    raise notice 'PASS AP11: OFF قبل الحسم يمنع الانتقال';
  else
    raise notice 'FAIL AP11: OFF لم يمنع الانتقال: %', v_res;
  end if;

  -- AP12: المفتاح العام داخل القاعدة يمنع الطلب الموجود في الطريق.
  v_ctx := pg_temp.make_p2_case('AP12-KILL');
  update ops.booking_automation_control
  set execution_enabled = false,
      policy_version = policy_version + 1,
      updated_at = clock_timestamp()
  where control_key = 'global';
  select ctl.policy_version into v_count
  from ops.booking_automation_control ctl
  where ctl.control_key = 'global';
  v_ctx := jsonb_set(v_ctx, '{policy_version}', to_jsonb(v_count));
  execute 'set local role booking_automation_executor';
  v_res := pg_temp.call_automation(
    v_ctx, gen_random_uuid(), gen_random_uuid(), gen_random_uuid()
  );
  execute 'reset role';
  if v_res ->> 'failure_reason' = 'global_automation_disabled' then
    raise notice 'PASS AP12: المفتاح العام الذري يمنع التنفيذ';
  else
    raise notice 'FAIL AP12: المفتاح العام لم يمنع التنفيذ: %', v_res;
  end if;
  update ops.booking_automation_control
  set execution_enabled = true,
      policy_version = policy_version + 1,
      updated_at = clock_timestamp()
  where control_key = 'global';

  -- AP15: مرشح next/revision قديم يرفض بلا أثر.
  v_ctx := pg_temp.make_p2_case('AP15-STALE');
  select ctl.policy_version into v_count
  from ops.booking_automation_control ctl
  where ctl.control_key = 'global';
  v_ctx := jsonb_set(v_ctx, '{policy_version}', to_jsonb(v_count));
  v_ctx := jsonb_set(v_ctx, '{next_booking_id}', to_jsonb(gen_random_uuid()));
  execute 'set local role booking_automation_executor';
  v_res := pg_temp.call_automation(
    v_ctx, gen_random_uuid(), gen_random_uuid(), gen_random_uuid()
  );
  execute 'reset role';
  if v_res ->> 'result' = 'rejected'
     and v_res ->> 'failure_reason' = 'next_booking_changed' then
    raise notice 'PASS AP15: الحجز التالي القديم يرفض';
  else
    raise notice 'FAIL AP15: المرشح القديم لم يرفض: %', v_res;
  end if;

  v_ctx := pg_temp.make_p2_case('AP15-REVISION');
  select ctl.policy_version into v_count
  from ops.booking_automation_control ctl
  where ctl.control_key = 'global';
  v_ctx := jsonb_set(v_ctx, '{policy_version}', to_jsonb(v_count));
  v_ctx := jsonb_set(
    v_ctx,
    '{decision_revision}',
    to_jsonb((v_ctx ->> 'decision_revision')::bigint + 1)
  );
  execute 'set local role booking_automation_executor';
  v_res := pg_temp.call_automation(
    v_ctx, gen_random_uuid(), gen_random_uuid(), gen_random_uuid()
  );
  execute 'reset role';
  if v_res ->> 'result' = 'rejected'
     and v_res ->> 'failure_reason' = 'stale_decision_revision' then
    raise notice 'PASS AP15: مراجعة القرار القديمة ترفض';
  else
    raise notice 'FAIL AP15: مراجعة القرار القديمة لم ترفض: %', v_res;
  end if;

  -- AP14/AP16: معرفان لنفس النية أو ضياع الرد يعيدان الإقرار فقط.
  v_ctx := pg_temp.make_p2_case('AP14-REPLAY');
  select ctl.policy_version into v_count
  from ops.booking_automation_control ctl
  where ctl.control_key = 'global';
  v_ctx := jsonb_set(v_ctx, '{policy_version}', to_jsonb(v_count));
  v_command := gen_random_uuid();
  execute 'set local role booking_automation_executor';
  v_res := pg_temp.call_automation(
    v_ctx, v_command, gen_random_uuid(), gen_random_uuid()
  );
  v_res2 := pg_temp.call_automation(
    v_ctx, gen_random_uuid(), gen_random_uuid(), gen_random_uuid()
  );
  execute 'reset role';
  select count(*) into v_session_count
  from ops.irrigation_sessions s
  where s.booking_id = (v_ctx ->> 'next_booking_id')::uuid;
  select count(*) into v_charge_count
  from billing.session_charges sc
  where sc.session_id = (v_ctx ->> 'current_session_id')::uuid;
  if v_res ->> 'result' = 'accepted'
     and v_res2 ->> 'result' = 'replayed'
     and v_session_count = 1 and v_charge_count = 1 then
    raise notice 'PASS AP14: معرفان لنفس النية أنتجا أثرًا واحدًا وإقرارًا معادًا';
  else
    raise notice 'FAIL AP14: تكررت النية أو لم تعد الإقرار: % / %', v_res, v_res2;
  end if;

  execute 'set local role booking_automation_executor';
  v_res2 := pg_temp.call_automation(
    v_ctx, v_command, gen_random_uuid(), gen_random_uuid()
  );
  execute 'reset role';
  select count(*) into v_session_count
  from ops.irrigation_sessions s
  where s.booking_id = (v_ctx ->> 'next_booking_id')::uuid;
  select count(*) into v_charge_count
  from billing.session_charges sc
  where sc.session_id = (v_ctx ->> 'current_session_id')::uuid;
  if v_res2 ->> 'result' = 'replayed'
     and v_session_count = 1 and v_charge_count = 1
     and v_res2 -> 'business_receipt' = v_res -> 'business_receipt' then
    raise notice 'PASS AP16: ضياع الرد صولح بالإقرار المخزن بلا أثر مكرر';
  else
    raise notice 'FAIL AP16: replay لم يحسم النتيجة المجهولة: %', v_res2;
  end if;

  raise notice 'INFO AP13: الإثبات المتزامن متعدد الاتصالات في p2_automation_concurrency_proof.py';
  raise notice '--- انتهى اختبار P2 Automated Execution Phase 1 ---';
end;
$test$;

rollback;
