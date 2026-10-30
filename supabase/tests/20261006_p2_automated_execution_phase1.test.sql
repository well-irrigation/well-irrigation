-- Q137: منع إعادة تشغيل منفذ الأتمتة القديم؛ اختبار محلي سلبي.
\set ON_ERROR_STOP on
begin;

set local timezone to 'UTC';


-- مساعدات مؤقتة داخل معاملة الاختبار؛ لا تعديل لأي عقد إنتاج.
create function pg_temp.q137_check(ok boolean,label text)
returns void language plpgsql as $qcheck$
begin
  if ok is distinct from true then raise exception 'FAIL %',label; end if;
  raise notice 'PASS %',label;
end;
$qcheck$;

-- Q137-REFERENCE-CLASS: EXPECTED_NEGATIVE_TEST
-- مقارنة الصفوف كاملة، بما فيها بيانات المحاسبة والتدقيق ومحاولات التنفيذ.
create function pg_temp.q137_snapshot()
returns jsonb language plpgsql as $qsnapshot$
declare r record; rows_json jsonb; result jsonb := '{}'::jsonb;
begin
  for r in
    select n.nspname,c.relname
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid=c.relnamespace
    where c.relkind in ('r','p') and not c.relispartition
      and (n.nspname in ('billing','finance','inventory','audit','sync')
        or (n.nspname='core' and c.relname in ('wells','well_settings'))
        or (n.nspname='ops' and c.relname in (
          'irrigation_bookings','irrigation_sessions','session_segments',
          'booking_transition_chains','booking_transition_decisions',
          'booking_status_history','resource_reservations',
          'booking_automation_control','booking_automation_execution_contexts')))
    order by n.nspname,c.relname
  loop
    execute format(
      'select coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text),''[]''::jsonb) from %I.%I t',
      r.nspname,r.relname) into rows_json;
    result := result || jsonb_build_object(r.nspname||'.'||r.relname,rows_json);
  end loop;
  perform pg_temp.q137_check(result ?& array[
    'ops.irrigation_bookings','ops.irrigation_sessions',
    'ops.booking_transition_chains','ops.booking_transition_decisions',
    'sync.processed_commands','audit.booking_automation_attempts',
    'billing.session_charges','finance.journal_entries','finance.journal_lines'],
    'snapshot covers operational, execution, command and financial authorities');
  return result;
end;
$qsnapshot$;

-- النجاح غير المتوقع أو خطأ مختلف يفشل الاختبار؛ لا ابتلاع للأخطاء.
create function pg_temp.q137_refused(
  statement text,label text,expected_state text,
  as_role text default 'authenticated',expected_message text default null)
returns void language plpgsql as $qrefused$
declare before_state jsonb; caught_state text; caught_message text;
begin
  before_state := pg_temp.q137_snapshot();
  begin
    if as_role is not null then execute format('set local role %I',as_role); end if;
    execute statement;
  exception when others then
    get stacked diagnostics caught_state=returned_sqlstate,caught_message=message_text;
  end;
  execute 'reset role';
  perform pg_temp.q137_check(
    caught_state=expected_state
    and (expected_message is null or caught_message=expected_message),label);
  perform pg_temp.q137_check(pg_temp.q137_snapshot()=before_state,
    label||' / zero partial effects');
end;
$qrefused$;

-- Q137-REFERENCE-CLASS: EXPECTED_HISTORICAL_READ_FIXTURE
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

  v_result := ops.start_booking_session_core(
    v_current_booking,
    v_seed.operator_profile_id,
    v_now - interval '130 minutes'
  );
  v_current_session := (v_result ->> 'session_id')::uuid;

  perform pg_temp.q137_check(not exists(
    select 1 from ops.booking_transition_chains where well_id=v_well),
    'manual start creates no chain');
  -- historical fixture for retained Q137 read/replay contract.
  -- صف اختبار قديم صريح، وليس أثرًا لعقد البدء اليدوي الحالي.
  insert into ops.booking_transition_chains(
    tenant_id,well_id,status,opened_by_session_id,opened_at,
    current_session_id,next_booking_id,decision_revision,created_by)
  values(v_seed.tenant_id,v_well,'active',v_current_session,
    v_now-interval '130 minutes',v_current_session,v_next_booking,0,
    v_seed.operator_profile_id) returning id into v_chain;

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
    'automation_revision', coalesce(v_auto_revision,0),
    'policy_version', coalesce(v_policy_version,1)
  );
end;
$function$;


-- Q137-REFERENCE-CLASS: EXPECTED_NEGATIVE_TEST
do $test$
declare
  seed p2_seed%rowtype;
  ctx jsonb;
  r record;
  args text;
  statement text;
  caller text;
  invocation text;
  command_id uuid := gen_random_uuid();
  same_attempt uuid := gen_random_uuid();
  same_run uuid := gen_random_uuid();
  calls integer := 0;
  other_operator uuid := gen_random_uuid();
begin
  select * into seed from p2_seed limit 1;
  ctx := pg_temp.make_p2_case('Q137-RETIRED');
  perform pg_temp.q137_check(
    (select status='open' and ended_at is null
      and operator_profile_id=seed.operator_profile_id
     from ops.irrigation_sessions where id=(ctx->>'current_session_id')::uuid),
    'AP17/AP19: real human operator and open current session');

  -- نفس مجموعة الهجرة؛ يشمل كل overload مثبت، لا توقيعًا مفترضًا فقط.
  for r in
    select p.oid,n.nspname,p.proname,p.proargtypes,p.prosecdef,p.proconfig
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
    where (n.nspname='ops' and p.proname in (
      'execute_booking_transition','execute_booking_transition_automation',
      'execute_pending_booking_start','record_booking_transition_decision'))
      or (n.nspname='api' and p.proname in (
        'execute_pending_booking_start','record_booking_transition_decision'))
    order by n.nspname,p.proname,p.oid
  loop
    calls := calls+1;
    perform pg_temp.q137_check(
      r.prosecdef=(r.nspname='ops')
      and r.proconfig @> array['search_path=pg_catalog, pg_temp']
      and not has_function_privilege('anon',r.oid,'execute')
      and not exists(select 1 from pg_catalog.pg_proc p,
        lateral pg_catalog.aclexplode(coalesce(p.proacl,pg_catalog.acldefault('f',p.proowner))) acl
        where p.oid=r.oid and acl.grantee=0 and acl.privilege_type='EXECUTE')
      and case when r.nspname='api' then
        has_function_privilege('authenticated',r.oid,'execute')
        and has_function_privilege('service_role',r.oid,'execute')
      else not has_function_privilege('authenticated',r.oid,'execute')
        and not has_function_privilege('service_role',r.oid,'execute') end,
      'AP2-AP5: exact grants/security for '||r.oid::regprocedure::text);
    select string_agg('NULL::'||pg_catalog.format_type(t,null),',' order by ord)
      into args from unnest(r.proargtypes::oid[]) with ordinality a(t,ord);
    statement := format('select %I.%I(%s)',r.nspname,r.proname,args);
    perform pg_temp.q137_refused(statement,
      'disabled installed identity '||r.oid::regprocedure::text,'0A000',
      case when r.nspname='api' then 'authenticated' else null end,
      'legacy_booking_automation_disabled');
    foreach caller in array array['anon','authenticated','service_role','booking_automation_executor'] loop
      perform pg_temp.q137_refused(statement,
        'role boundary '||caller||' / '||r.oid::regprocedure::text,
        case when has_function_privilege(caller,r.oid,'execute') then '0A000' else '42501' end,
        caller,case when has_function_privilege(caller,r.oid,'execute')
          then 'legacy_booking_automation_disabled' else null end);
    end loop;
  end loop;
  perform pg_temp.q137_check(calls>=6
    and to_regprocedure('ops.execute_booking_transition(uuid,bigint,uuid)') is not null
    and to_regprocedure('ops.execute_booking_transition_automation(uuid,uuid,uuid,uuid,bigint,bigint,bigint,uuid,uuid,uuid)') is not null
    and to_regprocedure('ops.execute_pending_booking_start(uuid,bigint,uuid)') is not null
    and to_regprocedure('ops.record_booking_transition_decision(uuid,uuid,uuid,text,bigint,uuid,uuid)') is not null
    and to_regprocedure('api.execute_pending_booking_start(uuid,bigint,uuid)') is not null
    and to_regprocedure('api.record_booking_transition_decision(uuid,uuid,uuid,text,bigint,uuid)') is not null,
    'all six required production identities covered');
  perform pg_temp.q137_check(
    position('actor' in lower(pg_get_function_arguments(
      'ops.execute_booking_transition_automation(uuid,uuid,uuid,uuid,bigint,bigint,bigint,uuid,uuid,uuid)'::regprocedure)))=0
    and position('operator' in lower(pg_get_function_arguments(
      'ops.execute_booking_transition_automation(uuid,uuid,uuid,uuid,bigint,bigint,bigint,uuid,uuid,uuid)'::regprocedure)))=0,
    'AP4: caller cannot select actor or operator identity');

  -- معرفات تاريخية حقيقية: لا تكفي اختبارات NULL وحدها لإثبات الرفض.
  statement := format(
    'select ops.execute_booking_transition_automation(%L::uuid,%L::uuid,%L::uuid,%L::uuid,0::bigint,%L::bigint,%L::bigint,%L::uuid,%L::uuid,%L::uuid)',
    ctx->>'well_id',ctx->>'chain_id',ctx->>'current_session_id',ctx->>'next_booking_id',
    ctx->>'automation_revision',ctx->>'policy_version',command_id,same_attempt,same_run);
  perform set_config('request.jwt.claim.sub','',true);
  perform pg_temp.q137_refused(statement,'AP6: trusted technical role also retired',
    '0A000','booking_automation_executor','legacy_booking_automation_disabled');
  perform pg_temp.q137_refused(statement,'AP14/AP16: identical retry cannot execute',
    '0A000','booking_automation_executor','legacy_booking_automation_disabled');
  perform set_config('request.jwt.claim.sub',seed.operator_profile_id::text,true);
  perform pg_temp.q137_refused(format(
    'select ops.execute_booking_transition(%L::uuid,0::bigint,%L::uuid)',
    ctx->>'well_id',gen_random_uuid()),'AP1: old human transition is retired',
    '0A000',null,'legacy_booking_automation_disabled');

  foreach invocation in array array['true','false'] loop
    perform pg_temp.q137_refused(format(
      'select api.set_well_booking_automation(%L::uuid,%s,0::bigint,%L::uuid)',
      ctx->>'well_id',invocation,gen_random_uuid()),'AP11: new ON/OFF disabled',
      '0A000','authenticated','legacy_booking_automation_disabled');
  end loop;
  perform pg_temp.q137_refused(format(
    'select ops.set_well_booking_automation(%L::uuid,true,0::bigint,%L::uuid,%L::uuid)',
    ctx->>'well_id',seed.owner_profile_id,gen_random_uuid()),
    'actor mismatch cannot impersonate another profile','42501','authenticated');
  perform set_config('request.jwt.claim.sub',seed.owner_profile_id::text,true);
  perform pg_temp.q137_refused(format(
    'select api.set_well_booking_automation(%L::uuid,true,0::bigint,%L::uuid)',
    ctx->>'well_id',gen_random_uuid()),'owner is not the authorized operator','42501');

  -- AP7/AP9: السحب الفعلي للتعيين لا يمنح مسارًا بديلًا.
  perform set_config('request.jwt.claim.sub',seed.operator_profile_id::text,true);
  update core.well_assignments set status='inactive'
    where id=(ctx->>'operator_assignment_id')::uuid;
  perform pg_temp.q137_refused(format(
    'select api.set_well_booking_automation(%L::uuid,true,0::bigint,%L::uuid)',
    ctx->>'well_id',gen_random_uuid()),'revoked operator cannot activate','42501');
  perform set_config('request.jwt.claim.sub','',true);
  perform pg_temp.q137_refused(statement,'revoked delegation cannot bypass retirement',
    '0A000','booking_automation_executor','legacy_booking_automation_disabled');

  -- AP8/AP10: إضافة مشغل أو تغييره لا يعيد فتح التنفيذ القديم.
  insert into auth.users(id,raw_user_meta_data)
    values(other_operator,'{"full_name":"مشغل بديل للاختبار"}');
  insert into core.well_assignments(well_id,profile_id,role,status)
    values((ctx->>'well_id')::uuid,other_operator,'operator','active');
  perform set_config('request.jwt.claim.sub',other_operator::text,true);
  perform pg_temp.q137_refused(statement,'changed operator cannot revive executor',
    '0A000','booking_automation_executor','legacy_booking_automation_disabled');
  update core.well_assignments set status='active'
    where id=(ctx->>'operator_assignment_id')::uuid;
  perform pg_temp.q137_refused(statement,'multiple operators cannot revive executor',
    '0A000','booking_automation_executor','legacy_booking_automation_disabled');

  -- AP12/AP15: اختلاف المفاتيح والمراجعات لا يصل إلى محرك الأعمال القديم.
  update ops.booking_automation_control set execution_enabled=false where control_key='global';
  perform pg_temp.q137_refused(statement,'global OFF does not change retirement contract',
    '0A000','booking_automation_executor','legacy_booking_automation_disabled');
  update ops.booking_automation_control set execution_enabled=true where control_key='global';
  perform pg_temp.q137_refused(statement,'global ON cannot reactivate retirement',
    '0A000','booking_automation_executor','legacy_booking_automation_disabled');
  perform pg_temp.q137_refused(format(
    'select ops.execute_booking_transition_automation(%L::uuid,%L::uuid,%L::uuid,%L::uuid,999::bigint,999::bigint,999::bigint,%L::uuid,%L::uuid,%L::uuid)',
    ctx->>'well_id',ctx->>'chain_id',ctx->>'current_session_id',gen_random_uuid(),
    gen_random_uuid(),gen_random_uuid(),gen_random_uuid()),'stale intent remains disabled',
    '0A000','booking_automation_executor','legacy_booking_automation_disabled');

  perform pg_temp.q137_check(
    (select status='open' and ended_at is null
      and operator_profile_id=seed.operator_profile_id from ops.irrigation_sessions
     where id=(ctx->>'current_session_id')::uuid)
    and not exists(select 1 from ops.irrigation_sessions
      where booking_id=(ctx->>'next_booking_id')::uuid)
    and not exists(select 1 from billing.session_charges
      where session_id=(ctx->>'current_session_id')::uuid),
    'AP17-AP19: original session/operator retained, no next session or charge');
  -- كل رفض أعلاه يقارن جميع صفوف الأوامر والمحاولات والمال، لا عدّ النجاح فقط.
end
$test$;
rollback;
