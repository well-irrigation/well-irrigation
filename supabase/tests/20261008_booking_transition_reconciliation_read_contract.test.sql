-- Q137 retained historical reconciliation: قراءة فقط لإقرارات سابقة مع عزل الجهة.
\set ON_ERROR_STOP on
-- Q137-REFERENCE-CLASS: EXPECTED_HISTORICAL_READ_FIXTURE
begin;

set local timezone to 'UTC';

create temporary table reconciliation_seed (
  tenant_id uuid not null,
  owner_id uuid not null,
  operator_id uuid not null,
  farmer_id uuid not null
) on commit drop;

do $seed$
declare
  v_tenant uuid;
  v_person uuid;
  v_farmer uuid;
  v_owner uuid := gen_random_uuid();
  v_operator uuid := gen_random_uuid();
begin
  insert into core.tenants (name) values ('P2 reconciliation test')
  returning id into v_tenant;
  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع مصالحة', 'مزارع مصالحة') returning id into v_person;
  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person) returning id into v_farmer;
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at
  ) values
    (v_owner, '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'p2-reconciliation-owner@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now()),
    (v_operator, '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'p2-reconciliation-operator@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now());
  insert into iam.profiles (id, full_name) values
    (v_owner, 'مالك المصالحة'), (v_operator, 'مشغل المصالحة')
  on conflict (id) do nothing;
  insert into reconciliation_seed values (v_tenant, v_owner, v_operator, v_farmer);
end;
$seed$;

create function pg_temp.make_reconciliation_case(p_label text)
returns jsonb
language plpgsql
as $function$
declare
  v_seed reconciliation_seed%rowtype;
  v_well uuid;
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
  v_started jsonb;
begin
  select * into v_seed from reconciliation_seed limit 1;
  insert into core.wells (tenant_id, name) values (v_seed.tenant_id, p_label)
  returning id into v_well;
  insert into core.well_assignments (well_id, profile_id, role, status) values
    (v_well, v_seed.owner_id, 'owner', 'active'),
    (v_well, v_seed.operator_id, 'operator', 'active');
  insert into ops.farmer_well_accounts (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_seed.tenant_id, v_seed.farmer_id, v_well, 'REC-' || p_label)
  returning id into v_account;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well, 'أرض ' || p_label, v_account) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_well, 'مضخة ' || p_label, 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well, 5000, current_date - 1);
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values (
    v_seed.tenant_id, 'REC-CUR-' || p_label, v_well, v_account, v_farm,
    v_now - interval '130 minutes', v_now - interval '10 minutes', 120,
    'well_diesel', 'confirmed'
  )
  returning id into v_current_booking;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values (
    v_seed.tenant_id, 'REC-NEXT-' || p_label, v_well, v_account, v_farm,
    v_now - interval '5 minutes', v_now + interval '55 minutes', 60,
    'well_diesel', 'confirmed'
  ) returning id into v_next_booking;
  perform set_config('request.jwt.claim.sub', v_seed.operator_id::text, true);
  v_started := ops.start_booking_session_core(
    v_current_booking, v_seed.operator_id, v_now - interval '130 minutes'
  );
  v_current_session := (v_started ->> 'session_id')::uuid;
  if exists(select 1 from ops.booking_transition_chains where well_id=v_well) then
    raise exception 'FAIL manual start unexpectedly created a chain';
  end if;
  -- historical fixture for retained Q137 read/replay contract.
  -- تُدرج بهوية الجهة والبئر والجلسة الفعلية داخل المعاملة فقط.
  insert into ops.booking_transition_chains(
    tenant_id,well_id,status,opened_by_session_id,opened_at,
    current_session_id,next_booking_id,decision_revision,created_by)
  values(v_seed.tenant_id,v_well,'active',v_current_session,
    v_now-interval '130 minutes',v_current_session,v_next_booking,0,v_seed.operator_id)
  returning id into v_chain;
  select booking_auto_transition_revision into v_auto_revision
  from core.well_settings where well_id = v_well;
  select policy_version into v_policy_version
  from ops.booking_automation_control where control_key = 'global';
  return jsonb_build_object(
    'tenant_id', v_seed.tenant_id, 'well_id', v_well, 'chain_id', v_chain,
    'current_session_id', v_current_session, 'next_booking_id', v_next_booking,
    'decision_revision', 0, 'automation_revision', coalesce(v_auto_revision,0),
    'policy_version', coalesce(v_policy_version,1),
    'current_end',v_now-interval '10 minutes','next_start',v_now-interval '5 minutes'
  );
end;
$function$;

-- historical fixture for retained Q137 read/replay contract.
-- إنشاء جلسات صالحة بالعقود اليدوية، ثم تجهيز إقرار قديم صريح.
-- لا استدعاء لمنفذ انتقال، ولا محاكاة نجاح طلب runtime جديد.
create function pg_temp.seed_historical_receipt(p_ctx jsonb,p_command uuid)
returns void language plpgsql as $fixture$
declare
  seed reconciliation_seed%rowtype;
  completed jsonb;
  started jsonb;
  chain_before jsonb;
begin
  select * into seed from reconciliation_seed limit 1;
  select to_jsonb(c) into strict chain_before from ops.booking_transition_chains c
    where c.id=(p_ctx->>'chain_id')::uuid;
  perform set_config('request.jwt.claim.sub',seed.operator_id::text,true);
  completed := api.complete_booking_session(
    (p_ctx->>'current_session_id')::uuid,(p_ctx->>'current_end')::timestamptz,
    gen_random_uuid(),null,null,null);
  started := api.start_irrigation_session_from_booking(
    (p_ctx->>'next_booking_id')::uuid,(p_ctx->>'next_start')::timestamptz,
    gen_random_uuid(),null);
  if completed->>'status' is distinct from 'closed'
    or started->>'session_id' is null
    or (select to_jsonb(c) from ops.booking_transition_chains c
      where c.id=(p_ctx->>'chain_id')::uuid) is distinct from chain_before then
    raise exception 'FAIL manual fixture operations must not move the historical chain';
  end if;
  -- التغيير التالي بيانات تاريخية صريحة للقراءة، وليس ناتج runtime.
  update ops.booking_transition_chains
    set current_session_id=(started->>'session_id')::uuid,next_booking_id=null
    where id=(p_ctx->>'chain_id')::uuid;
  insert into ops.booking_transition_decisions(
    tenant_id,well_id,chain_id,prev_session_id,next_booking_id,decision,decided_by,command_id)
  values((p_ctx->>'tenant_id')::uuid,(p_ctx->>'well_id')::uuid,
    (p_ctx->>'chain_id')::uuid,(p_ctx->>'current_session_id')::uuid,
    (p_ctx->>'next_booking_id')::uuid,'run_now',seed.operator_id,p_command);
  insert into sync.processed_commands(
    tenant_id,command_id,command_type,entity_id,status,request_payload,
    response_payload,intent_fingerprint)
  values((p_ctx->>'tenant_id')::uuid,p_command,'execute_booking_transition',
    (p_ctx->>'well_id')::uuid,'accepted','{}'::jsonb,
    jsonb_build_object('well_id',p_ctx->>'well_id',
      'closed_session_id',p_ctx->>'current_session_id',
      'started_session_id',started->>'session_id',
      'started_booking_id',p_ctx->>'next_booking_id'),
    jsonb_build_object('tenant_id',(p_ctx->>'tenant_id')::uuid,
      'well_id',(p_ctx->>'well_id')::uuid,'chain_id',(p_ctx->>'chain_id')::uuid,
      'current_session_id',(p_ctx->>'current_session_id')::uuid,
      'next_booking_id',(p_ctx->>'next_booking_id')::uuid,
      'decision_revision',(p_ctx->>'decision_revision')::bigint,
      'automation_revision',(p_ctx->>'automation_revision')::bigint,
      'policy_version',(p_ctx->>'policy_version')::bigint,
      'actor_kind','system','actor_ref','booking_automation_system'));
end;
$fixture$;

-- مقارنة كاملة للصفوف حول قراءة الإقرار في R5، بما فيها الأوامر والتدقيق والمال.
create function pg_temp.reconciliation_snapshot()
returns jsonb language plpgsql as $read_snapshot$
declare r record; rows_json jsonb; result jsonb := '{}'::jsonb;
begin
  for r in select n.nspname,c.relname from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid=c.relnamespace
    where c.relkind in ('r','p') and not c.relispartition
      and n.nspname in ('ops','sync','audit','billing','finance','core')
    order by n.nspname,c.relname
  loop
    execute format(
      'select coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text),''[]''::jsonb) from %I.%I t',
      r.nspname,r.relname) into rows_json;
    result:=result||jsonb_build_object(r.nspname||'.'||r.relname,rows_json);
  end loop;
  return result;
end;
$read_snapshot$;

create function pg_temp.read_reconciliation(p_ctx jsonb, p_command uuid)
returns jsonb
language plpgsql
as $function$
begin
  return api.get_booking_transition_reconciliation(
    (p_ctx ->> 'well_id')::uuid, (p_ctx ->> 'chain_id')::uuid,
    (p_ctx ->> 'current_session_id')::uuid,
    (p_ctx ->> 'next_booking_id')::uuid,
    (p_ctx ->> 'decision_revision')::bigint,
    (p_ctx ->> 'automation_revision')::bigint, p_command
  );
end;
$function$;

do $test$
declare
  v_seed reconciliation_seed%rowtype;
  v_ctx jsonb;
  v_pending_ctx jsonb;
  v_rejected_ctx jsonb;
  v_mismatched_receipt_ctx jsonb;
  v_result jsonb;
  v_command uuid := gen_random_uuid();
  v_other_command uuid := gen_random_uuid();
  v_rejected_command uuid := gen_random_uuid();
  v_accepted_after_rejection_command uuid := gen_random_uuid();
  v_mismatched_receipt_command uuid := gen_random_uuid();
  v_before_commands integer;
  v_before_audit integer;
  v_before_sessions integer;
  v_other_user uuid := gen_random_uuid();
  v_fp jsonb;
  before_read jsonb;
begin
  select * into v_seed from reconciliation_seed limit 1;

  -- Function shape, volatility, search path, and tightly scoped grants.
  if exists (
    select 1 from pg_proc p
    where p.oid = 'api.get_booking_transition_reconciliation(uuid,uuid,uuid,uuid,bigint,bigint,uuid)'::regprocedure
      and p.provolatile = 's' and not p.prosecdef
      and p.proconfig @> array['search_path=pg_catalog, pg_temp']
  ) and exists (
    select 1 from pg_proc p
    where p.oid = 'sync.get_booking_transition_reconciliation_read(uuid,uuid,uuid,uuid,bigint,bigint,uuid)'::regprocedure
      and p.provolatile = 's' and p.prosecdef
      and p.proconfig @> array['search_path=pg_catalog, pg_temp']
  ) and has_function_privilege('authenticated', 'api.get_booking_transition_reconciliation(uuid,uuid,uuid,uuid,bigint,bigint,uuid)', 'EXECUTE')
    and not has_function_privilege('anon', 'api.get_booking_transition_reconciliation(uuid,uuid,uuid,uuid,bigint,bigint,uuid)', 'EXECUTE')
    and has_function_privilege('service_role', 'api.get_booking_transition_reconciliation(uuid,uuid,uuid,uuid,bigint,bigint,uuid)', 'EXECUTE')
    and has_function_privilege('authenticated', 'sync.get_booking_transition_reconciliation_read(uuid,uuid,uuid,uuid,bigint,bigint,uuid)', 'EXECUTE')
    and not has_function_privilege('anon', 'sync.get_booking_transition_reconciliation_read(uuid,uuid,uuid,uuid,bigint,bigint,uuid)', 'EXECUTE')
    and has_function_privilege('service_role', 'sync.get_booking_transition_reconciliation_read(uuid,uuid,uuid,uuid,bigint,bigint,uuid)', 'EXECUTE')
    and not exists (
      select 1
      from pg_proc p
      cross join lateral aclexplode(
        coalesce(p.proacl, acldefault('f', p.proowner))
      ) acl
      where p.oid = 'api.get_booking_transition_reconciliation(uuid,uuid,uuid,uuid,bigint,bigint,uuid)'::regprocedure
        and acl.grantee = 0
        and acl.privilege_type = 'EXECUTE'
    )
    and not has_function_privilege('booking_automation_executor', 'api.get_booking_transition_reconciliation(uuid,uuid,uuid,uuid,bigint,bigint,uuid)', 'EXECUTE')
    and not has_table_privilege('anon', 'sync.processed_commands', 'SELECT')
    and not has_table_privilege('service_role', 'sync.processed_commands', 'SELECT')
    and not has_table_privilege('authenticated', 'audit.booking_automation_attempts', 'SELECT') then
    raise notice 'PASS R1: invoker API, guarded reader, and grants are exact';
  else
    raise notice 'FAIL R1: function shape, grants, or internal table isolation is wrong';
  end if;

  -- API EXECUTE for service_role preserves the shared API-surface invariant;
  -- it grants no business identity. The guarded reader must reject it when
  -- there is no authenticated human subject.
  v_pending_ctx := pg_temp.make_reconciliation_case('REC-SERVICE-ROLE');
  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role service_role';
  begin
    perform pg_temp.read_reconciliation(v_pending_ctx, gen_random_uuid());
    raise notice 'FAIL R2: service_role without auth.uid read a receipt';
  exception when sqlstate '28000' then
    raise notice 'PASS R2: service_role without auth.uid is rejected';
  end;
  execute 'reset role';

  v_pending_ctx := pg_temp.make_reconciliation_case('REC-NOT-FOUND');
  perform set_config('request.jwt.claim.sub', v_seed.owner_id::text, true);
  execute 'set local role authenticated';
  v_result := pg_temp.read_reconciliation(v_pending_ctx, gen_random_uuid());
  execute 'reset role';
  if v_result ->> 'status' = 'not_found'
     and v_result ->> 'review_reason' = 'not_found' then
    raise notice 'PASS R3: missing canonical receipt is not found';
  else raise notice 'FAIL R3: not-found response is unsafe: %', v_result; end if;

  v_ctx := pg_temp.make_reconciliation_case('REC-FOUND');
  perform set_config('request.jwt.claim.sub', '', true);
  perform pg_temp.seed_historical_receipt(v_ctx, v_command);
  execute 'reset role';

  before_read := pg_temp.reconciliation_snapshot();
  select count(*) into v_before_commands from sync.processed_commands;
  select count(*) into v_before_audit from audit.booking_automation_attempts;
  select count(*) into v_before_sessions from ops.irrigation_sessions;
  perform set_config('request.jwt.claim.sub', v_seed.owner_id::text, true);
  execute 'set local role authenticated';
  v_result := pg_temp.read_reconciliation(v_ctx, v_command);
  execute 'reset role';
  if v_result ->> 'status' = 'found'
     and v_result ->> 'match_kind' = 'exact_command'
     and v_result ->> 'canonical_command_id' = v_command::text
     and v_result #>> '{business_receipt,started_session,booking_id}'
           = v_ctx ->> 'next_booking_id'
     and v_result::text !~ '(credential_ref|executor_id|attempt_id|runtime_run_id|authorization_revision|operator_profile_id)' then
    raise notice 'PASS R4: exact command returns a minimal canonical receipt';
  else raise notice 'FAIL R4: exact canonical receipt invalid: %', v_result; end if;
  if pg_temp.reconciliation_snapshot()=before_read
     and (select count(*) from sync.processed_commands) = v_before_commands
     and (select count(*) from audit.booking_automation_attempts) = v_before_audit
     and (select count(*) from ops.irrigation_sessions) = v_before_sessions then
    raise notice 'PASS R5: read reconciliation has no mutation side effects';
  else raise notice 'FAIL R5: read reconciliation changed canonical rows'; end if;

  -- historical fixture for retained Q137 read/replay contract.
  -- R6 يحتاج أثر replay قديمًا فقط؛ لا إعادة تنفيذ لأي انتقال.
  insert into audit.booking_automation_attempts(
    actor_kind,actor_ref,executor_id,credential_ref,authorization_source,
    tenant_id,well_id,chain_id,current_session_id,next_booking_id,
    command_id,attempt_id,runtime_run_id,decision_revision,automation_revision,
    policy_version,observed_at,attempted_at,decided_at,result,business_receipt)
  values('system','booking_automation_system','historical-test-executor',
    'historical-test-credential','historical fixture',
    (v_ctx->>'tenant_id')::uuid,(v_ctx->>'well_id')::uuid,
    (v_ctx->>'chain_id')::uuid,(v_ctx->>'current_session_id')::uuid,
    (v_ctx->>'next_booking_id')::uuid,v_command,gen_random_uuid(),gen_random_uuid(),
    (v_ctx->>'decision_revision')::bigint,(v_ctx->>'automation_revision')::bigint,
    (v_ctx->>'policy_version')::bigint,now(),now(),now(),'replayed',
    (select response_payload from sync.processed_commands
      where tenant_id=(v_ctx->>'tenant_id')::uuid and command_id=v_command));
  perform set_config('request.jwt.claim.sub', v_seed.owner_id::text, true);
  execute 'set local role authenticated';
  v_result := pg_temp.read_reconciliation(v_ctx, v_command);
  execute 'reset role';
  if v_result ->> 'status' = 'found'
     and v_result ->> 'canonical_result' = 'replayed' then
    raise notice 'PASS R6: canonical replay is read as a receipt';
  else raise notice 'FAIL R6: canonical replay was not projected: %', v_result; end if;

  perform set_config('request.jwt.claim.sub', v_seed.owner_id::text, true);
  execute 'set local role authenticated';
  v_result := pg_temp.read_reconciliation(v_ctx, v_other_command);
  execute 'reset role';
  if v_result ->> 'status' = 'found'
     and v_result ->> 'match_kind' = 'logical_intent'
     and v_result ->> 'requested_command_id' = v_other_command::text
     and v_result ->> 'canonical_command_id' = v_command::text then
    raise notice 'PASS R7: different command matches the same logical intent';
  else raise notice 'FAIL R7: logical match failed: %', v_result; end if;

  perform set_config('request.jwt.claim.sub', v_seed.owner_id::text, true);
  execute 'set local role authenticated';
  v_result := api.get_booking_transition_reconciliation(
    (v_ctx ->> 'well_id')::uuid, (v_ctx ->> 'chain_id')::uuid,
    (v_ctx ->> 'current_session_id')::uuid, gen_random_uuid(),
    (v_ctx ->> 'decision_revision')::bigint,
    (v_ctx ->> 'automation_revision')::bigint, v_command
  );
  execute 'reset role';
  if v_result ->> 'status' = 'rejected'
     and v_result ->> 'review_reason' = 'intent_mismatch' then
    raise notice 'PASS R8: same command with a wrong intent is rejected';
  else raise notice 'FAIL R8: command mismatch accepted: %', v_result; end if;

  select intent_fingerprint into v_fp from sync.processed_commands
  where command_id = v_command and tenant_id = (v_ctx ->> 'tenant_id')::uuid;
  insert into sync.processed_commands (
    tenant_id, command_id, command_type, entity_id, status,
    request_payload, response_payload, intent_fingerprint
  ) values (
    (v_ctx ->> 'tenant_id')::uuid, gen_random_uuid(), 'execute_booking_transition',
    (v_ctx ->> 'well_id')::uuid, 'accepted', '{}'::jsonb,
    (select response_payload from sync.processed_commands where command_id = v_command),
    jsonb_set(v_fp, '{policy_version}', to_jsonb(999999::bigint))
  );
  perform set_config('request.jwt.claim.sub', v_seed.owner_id::text, true);
  execute 'set local role authenticated';
  v_result := pg_temp.read_reconciliation(v_ctx, gen_random_uuid());
  execute 'reset role';
  if v_result ->> 'status' = 'conflict'
     and v_result ->> 'review_reason' = 'ambiguous_canonical_intent' then
    raise notice 'PASS R9: ambiguous logical candidates require review';
  else raise notice 'FAIL R9: ambiguity was hidden: %', v_result; end if;

  -- Audit-only exact rejection: no processed-command row exists for A. Two
  -- attempts still prove only one rejected business intent, never ambiguity.
  v_rejected_ctx := pg_temp.make_reconciliation_case('REC-AUDIT-REJECTED');
  insert into audit.booking_automation_attempts (
    actor_kind, actor_ref, executor_id, credential_ref, authorization_source,
    tenant_id, well_id, chain_id, current_session_id, next_booking_id,
    command_id, attempt_id, runtime_run_id, decision_revision,
    automation_revision, policy_version, observed_at, attempted_at, decided_at,
    result, failure_reason
  ) values
    ('system', 'booking_automation_system', 'test-executor', 'test-credential',
     'test', (v_rejected_ctx ->> 'tenant_id')::uuid,
     (v_rejected_ctx ->> 'well_id')::uuid,
     (v_rejected_ctx ->> 'chain_id')::uuid,
     (v_rejected_ctx ->> 'current_session_id')::uuid,
     (v_rejected_ctx ->> 'next_booking_id')::uuid,
     v_rejected_command, gen_random_uuid(), gen_random_uuid(),
     (v_rejected_ctx ->> 'decision_revision')::bigint,
     (v_rejected_ctx ->> 'automation_revision')::bigint,
     (v_rejected_ctx ->> 'policy_version')::bigint,
     now(), now(), now(), 'rejected', 'internal_rejection_reason'),
    ('system', 'booking_automation_system', 'test-executor', 'test-credential',
     'test', (v_rejected_ctx ->> 'tenant_id')::uuid,
     (v_rejected_ctx ->> 'well_id')::uuid,
     (v_rejected_ctx ->> 'chain_id')::uuid,
     (v_rejected_ctx ->> 'current_session_id')::uuid,
     (v_rejected_ctx ->> 'next_booking_id')::uuid,
     v_rejected_command, gen_random_uuid(), gen_random_uuid(),
     (v_rejected_ctx ->> 'decision_revision')::bigint,
     (v_rejected_ctx ->> 'automation_revision')::bigint,
     (v_rejected_ctx ->> 'policy_version')::bigint,
     now(), now(), now(), 'rejected', 'internal_rejection_reason');
  perform set_config('request.jwt.claim.sub', v_seed.owner_id::text, true);
  execute 'set local role authenticated';
  v_result := pg_temp.read_reconciliation(v_rejected_ctx, v_rejected_command);
  execute 'reset role';
  if v_result ->> 'status' = 'rejected'
     and v_result ->> 'match_kind' = 'exact_command'
     and v_result ->> 'canonical_command_id' = v_rejected_command::text
     and v_result ->> 'canonical_result' = 'rejected' then
    raise notice 'PASS R10: audit-only exact rejection requires review';
  else raise notice 'FAIL R10: audit-only rejection is not explicit: %', v_result; end if;
  if v_result -> 'business_receipt' = 'null'::jsonb
     and v_result::text !~ '(failure_reason|credential_ref|executor_id|attempt_id|runtime_run_id|operator_profile_id|operator_assignment_id|authorization_revision|policy_version)' then
    raise notice 'PASS R11: audit rejection does not leak technical fields';
  else raise notice 'FAIL R11: audit rejection leaked technical fields: %', v_result; end if;

  -- A later accepted command for the same logical intent wins over old exact
  -- rejected audit evidence and keeps the two command identities separate.
  perform set_config('request.jwt.claim.sub', '', true);
  perform pg_temp.seed_historical_receipt(v_rejected_ctx, v_accepted_after_rejection_command);
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_seed.owner_id::text, true);
  execute 'set local role authenticated';
  v_result := pg_temp.read_reconciliation(v_rejected_ctx, v_rejected_command);
  execute 'reset role';
  if v_result ->> 'status' = 'found'
     and v_result ->> 'match_kind' = 'logical_intent'
     and v_result ->> 'canonical_command_id'
           = v_accepted_after_rejection_command::text then
    raise notice 'PASS R12: accepted logical intent wins over old audit rejection';
  else raise notice 'FAIL R12: old audit rejection hid canonical acceptance: %', v_result; end if;

  -- An accepted fingerprint is insufficient when its receipt claims that a
  -- different session was closed than the local current session.
  v_mismatched_receipt_ctx := pg_temp.make_reconciliation_case('REC-MISMATCHED-CLOSED');
  perform set_config('request.jwt.claim.sub', '', true);
  perform pg_temp.seed_historical_receipt(v_mismatched_receipt_ctx, v_mismatched_receipt_command);
  execute 'reset role';
  update sync.processed_commands
  set response_payload = jsonb_set(
    response_payload,
    '{closed_session_id}',
    to_jsonb(gen_random_uuid()::text)
  )
  where tenant_id = (v_mismatched_receipt_ctx ->> 'tenant_id')::uuid
    and command_id = v_mismatched_receipt_command;
  perform set_config('request.jwt.claim.sub', v_seed.owner_id::text, true);
  execute 'set local role authenticated';
  v_result := pg_temp.read_reconciliation(
    v_mismatched_receipt_ctx, v_mismatched_receipt_command
  );
  execute 'reset role';
  if v_result ->> 'status' = 'conflict'
     and v_result ->> 'review_reason' = 'server_state_changed' then
    raise notice 'PASS R13: mismatched closed session receipt requires review';
  else raise notice 'FAIL R13: mismatched closed session receipt was accepted: %', v_result; end if;

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at)
  values (v_other_user, '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'p2-reconciliation-other@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now());
  insert into iam.profiles (id, full_name) values (v_other_user, 'غريب المصالحة')
  on conflict (id) do nothing;
  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role authenticated';
  begin
    perform pg_temp.read_reconciliation(v_ctx, v_command);
    raise notice 'FAIL R14: unauthenticated caller read a receipt';
  exception when sqlstate '28000' then raise notice 'PASS R14: unauthenticated caller is rejected'; end;
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_other_user::text, true);
  execute 'set local role authenticated';
  begin
    perform pg_temp.read_reconciliation(v_ctx, v_command);
    raise notice 'FAIL R15: cross-tenant or unauthorized caller read a receipt';
  exception when insufficient_privilege then raise notice 'PASS R15: unauthorized caller is rejected'; end;
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_seed.owner_id::text, true);
  execute 'set local role authenticated';
  begin
    perform api.get_booking_transition_reconciliation(
      null, (v_ctx ->> 'chain_id')::uuid,
      (v_ctx ->> 'current_session_id')::uuid,
      (v_ctx ->> 'next_booking_id')::uuid,
      0, 1, v_command
    );
    raise notice 'FAIL R16: null inputs passed';
  exception when sqlstate '22023' then raise notice 'PASS R16: invalid required inputs fail closed'; end;
  execute 'reset role';

  -- Q137-REFERENCE-CLASS: EXPECTED_NEGATIVE_TEST
  if not exists (
    select 1
    from (
      select lower(regexp_replace(
        pg_get_functiondef(
          'sync.get_booking_transition_reconciliation_read(uuid,uuid,uuid,uuid,bigint,bigint,uuid)'::regprocedure
        ), E'--[^\\n]*(\\n|$)', E'\\n', 'g'
      )) as body
    ) definition
    where body ~ '\\m(insert|update|delete)\\M'
       or strpos(body, 'ops.execute_booking_transition(') > 0
       or strpos(body, 'ops.execute_booking_transition_automation(') > 0
       or strpos(body, 'sync.begin_command(') > 0
  ) and not exists (
    select 1
    from (
      select lower(regexp_replace(
        pg_get_functiondef(
          'api.get_booking_transition_reconciliation(uuid,uuid,uuid,uuid,bigint,bigint,uuid)'::regprocedure
        ), E'--[^\\n]*(\\n|$)', E'\\n', 'g'
      )) as body
    ) definition
    where body ~ '\\m(insert|update|delete)\\M'
       or strpos(body, 'ops.execute_booking_transition(') > 0
       or strpos(body, 'ops.execute_booking_transition_automation(') > 0
       or strpos(body, 'sync.begin_command(') > 0
  ) then
    raise notice 'PASS R17: deployed function bodies contain no business execution or mutation';
  else
    raise notice 'FAIL R17: deployed function body contains forbidden execution or mutation';
  end if;
end;
$test$;

rollback;
