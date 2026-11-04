-- Q137: رفض إنهاء جديد، وإعادة إقرارات تاريخية مصرح بها فقط.
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
create temporary table terminal_seed (
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
  insert into core.tenants (name) values ('terminal chain test')
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
     'authenticated', 'authenticated', 'terminal-chain-owner@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now()),
    (v_operator, '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'terminal-chain-operator@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now());
  insert into iam.profiles (id, full_name) values
    (v_owner, 'مالك المصالحة'), (v_operator, 'مشغل المصالحة')
  on conflict (id) do nothing;
  insert into terminal_seed values (v_tenant, v_owner, v_operator, v_farmer);
end;
$seed$;

create function pg_temp.check_terminal(p_ok boolean, p_label text)
returns void language plpgsql as $f$
begin
  if p_ok is distinct from true then raise exception 'FAIL %', p_label; end if;
  raise notice 'PASS %', p_label;
end $f$;

create function pg_temp.terminal_case(p_label text, p_close boolean default true)
returns jsonb language plpgsql as $f$
declare
  t terminal_seed%rowtype;
  w uuid; a uuid; f uuid; b uuid; s uuid; c uuid;
  started timestamptz := (((now() at time zone 'Asia/Aden')::date - 2)::timestamp
    + interval '06:00') at time zone 'Asia/Aden';
  response jsonb;
begin
  select * into t from terminal_seed limit 1;
  insert into core.wells(tenant_id,name) values(t.tenant_id,p_label) returning id into w;
  insert into core.well_assignments(well_id,profile_id,role,status) values
    (w,t.owner_id,'owner','active'),(w,t.operator_id,'operator','active');
  insert into ops.farmer_well_accounts(tenant_id,farmer_profile_id,well_id,public_code)
    values(t.tenant_id,t.farmer_id,w,'END-'||p_label) returning id into a;
  insert into ops.farms(well_id,name,farmer_well_account_id) values(w,p_label,a) returning id into f;
  insert into core.pumps(well_id,name,power_source,status) values(w,p_label,'diesel','active');
  insert into billing.well_pricing(well_id,price_per_hour_minor,period_start)
    values(w,3600,current_date-10);
  insert into ops.irrigation_bookings(tenant_id,public_code,well_id,farmer_well_account_id,
    farm_id,scheduled_start,scheduled_end,expected_duration_minutes,expected_energy_source,status)
    values(t.tenant_id,'CUR-'||p_label,w,a,f,started,started+interval '4 minutes',4,'well_diesel','confirmed') returning id into b;
  perform set_config('request.jwt.claim.sub',t.operator_id::text,true);
  response := ops.start_booking_session_core(b,t.operator_id,started+interval '23 seconds');
  s := (response->>'session_id')::uuid;
  if p_close then
    perform api.complete_irrigation_session(s,started+interval '4 minutes 23 seconds',p_command_id=>gen_random_uuid());
  end if;
  perform pg_temp.check_terminal(not exists(
    select 1 from ops.booking_transition_chains where well_id=w),
    'manual fixture operations do not create a chain');
  -- historical fixture for retained Q137 read/replay contract.
  insert into ops.booking_transition_chains(
    tenant_id,well_id,status,opened_by_session_id,opened_at,
    current_session_id,decision_revision,created_by)
  values(t.tenant_id,w,case when p_close then 'decision_required' else 'active' end,
    s,started+interval '23 seconds',s,0,t.operator_id) returning id into c;
  return jsonb_build_object('well',w,'booking',b,'session',s,'chain',c,'start',started,
    'account',a,'farm',f,'tenant',t.tenant_id);
end $f$;

create function pg_temp.terminal_next(p_case jsonb,p_label text,p_status text default 'confirmed',p_days integer default 0)
returns uuid language plpgsql as $f$
declare b uuid; at_time timestamptz := (p_case->>'start')::timestamptz+interval '5 minutes'+make_interval(days=>p_days);
begin
  insert into ops.irrigation_bookings(tenant_id,public_code,well_id,farmer_well_account_id,
    farm_id,scheduled_start,scheduled_end,expected_duration_minutes,expected_energy_source,status)
  values((p_case->>'tenant')::uuid,p_label,(p_case->>'well')::uuid,(p_case->>'account')::uuid,
    (p_case->>'farm')::uuid,at_time,at_time+interval '3 minutes',3,'well_diesel',p_status) returning id into b;
  return b;
end $f$;

-- Q137-REFERENCE-CLASS: EXPECTED_HISTORICAL_REPLAY
create function pg_temp.call_terminal(p_case jsonb,p_command uuid)
returns jsonb language plpgsql as $f$
begin
  return api.end_booking_transition_chain((p_case->>'session')::uuid,p_command);
end $f$;

-- Q137-REFERENCE-CLASS: EXPECTED_NEGATIVE_TEST
create function pg_temp.rejected_unchanged(p_case jsonb,p_label text)
returns void language plpgsql as $reject$
begin
  perform pg_temp.q137_refused(format(
    'select api.end_booking_transition_chain(%L::uuid,%L::uuid)',
    p_case->>'session',gen_random_uuid()),'new terminal request / '||p_label,
    case when p_label='unauthorized' then '42501' else '0A000' end,
    'authenticated',case when p_label='unauthorized' then null
      else 'legacy_booking_automation_disabled' end);
end;
$reject$;

do $tests$
declare
  x jsonb; y jsonb; response jsonb; replay jsonb; before_row jsonb;
  historical_case jsonb;
  stored_response jsonb;
  historical_state jsonb;
  original_command jsonb;
  command uuid:=gen_random_uuid(); b uuid; next_session uuid; actor uuid; st text; plan jsonb;
begin
  perform pg_temp.check_terminal(to_regprocedure('api.end_booking_transition_chain(uuid,uuid)') is not null,'API exists');
  perform pg_temp.check_terminal(exists(select 1 from pg_proc where oid='api.end_booking_transition_chain(uuid,uuid)'::regprocedure
    and not prosecdef and proconfig @> array['search_path=pg_catalog, pg_temp']),'API invoker and fixed search_path');
  perform pg_temp.check_terminal(exists(select 1 from pg_proc where oid='ops.end_booking_transition_chain(uuid,uuid,uuid)'::regprocedure
    and prosecdef and proconfig @> array['search_path=pg_catalog, pg_temp']),'ops definer and fixed search_path');
  perform pg_temp.check_terminal(has_function_privilege('authenticated','api.end_booking_transition_chain(uuid,uuid)','execute')
    and has_function_privilege('service_role','api.end_booking_transition_chain(uuid,uuid)','execute')
    and not has_function_privilege('anon','api.end_booking_transition_chain(uuid,uuid)','execute'),'API grants');
  perform pg_temp.check_terminal(not has_function_privilege('authenticated','ops.end_booking_transition_chain(uuid,uuid,uuid)','execute')
    and not has_function_privilege('service_role','ops.end_booking_transition_chain(uuid,uuid,uuid)','execute')
    and not has_function_privilege('anon','ops.end_booking_transition_chain(uuid,uuid,uuid)','execute'),'no direct application ops execute');
  perform pg_temp.check_terminal(not has_table_privilege('authenticated','ops.booking_transition_chains','update'),'no direct table update');

  perform pg_temp.check_terminal(not exists(
    select 1 from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid=p.pronamespace
    cross join lateral pg_catalog.aclexplode(
      coalesce(p.proacl,pg_catalog.acldefault('f',p.proowner))) acl
    where ((n.nspname in ('api','ops') and p.proname='end_booking_transition_chain')
      or (n.nspname='sync' and p.proname='end_booking_transition_chain_command'))
      and acl.grantee=0 and acl.privilege_type='EXECUTE'),
    'PUBLIC has no terminal/replay executor grant');

  -- Q137-REFERENCE-CLASS: EXPECTED_HISTORICAL_REPLAY
  -- historical fixture for retained Q137 read/replay contract.
  -- الإقرار موجود مسبقًا؛ لا طلب إنهاء جديد يُستخدم لإنشائه.
  x:=pg_temp.terminal_case('HISTORICAL');
  historical_case:=x;
  select operator_id into actor from terminal_seed limit 1;
  update ops.booking_transition_chains set status='ended',
    ended_at=(select ended_at from ops.irrigation_sessions where id=(x->>'session')::uuid),
    ended_reason='final_booking_completed'
    where id=(x->>'chain')::uuid;
  stored_response:=jsonb_build_object(
    'contract','end_booking_transition_chain','version',1,'status','ended',
    'session_id',x->>'session','chain_id',x->>'chain',
    'reason_code','final_booking_completed');
  insert into sync.processed_commands(
    tenant_id,command_id,command_type,entity_id,status,request_payload,response_payload)
  values((x->>'tenant')::uuid,command,'end_booking_transition_chain',
    (x->>'session')::uuid,'accepted',
    jsonb_build_object('version',1,'session_id',(x->>'session')::uuid),stored_response);
  select to_jsonb(pc) into strict original_command from sync.processed_commands pc
    where tenant_id=(x->>'tenant')::uuid and command_id=command;
  historical_state:=pg_temp.q137_snapshot();
  execute 'set local role authenticated';
  response:=pg_temp.call_terminal(x,command);
  replay:=pg_temp.call_terminal(x,command);
  execute 'reset role';
  perform pg_temp.check_terminal(response=stored_response and replay=stored_response,
    'historical accepted acknowledgement replays the exact preexisting response');
  perform pg_temp.check_terminal(pg_temp.q137_snapshot()=historical_state
    and (select to_jsonb(pc) from sync.processed_commands pc
      where tenant_id=(x->>'tenant')::uuid and command_id=command)=original_command
    and (select count(*)=1 from sync.processed_commands where command_id=command),
    'historical replay changes no row, command or financial identity');
  perform pg_temp.check_terminal((select c.status='ended' and c.ended_at=s.ended_at
    and c.ended_reason='final_booking_completed' and c.current_session_id=s.id and c.opened_by_session_id=s.id
    from ops.booking_transition_chains c join ops.irrigation_sessions s on s.id=c.current_session_id
    where c.id=(x->>'chain')::uuid),'historical timestamps and session identities preserved');
  -- rejected/conflict التاريخيتان مسموحتان أيضًا، دون إعادة حسمهما.
  foreach st in array array['rejected','conflict'] loop
    update sync.processed_commands set status=st,
      response_payload=jsonb_build_object('status',st,'historical',true)
      where tenant_id=(x->>'tenant')::uuid and command_id=command;
    historical_state:=pg_temp.q137_snapshot();
    execute 'set local role authenticated';
    response:=pg_temp.call_terminal(x,command);
    execute 'reset role';
    perform pg_temp.check_terminal(
      response=jsonb_build_object('status',st,'historical',true)
      and pg_temp.q137_snapshot()=historical_state,
      'historical '||st||' acknowledgement remains unchanged');
  end loop;

  -- Q137-REFERENCE-CLASS: EXPECTED_NEGATIVE_TEST
  perform pg_temp.rejected_unchanged(x,'fresh request despite existing history');
  y:=pg_temp.terminal_case('PAYLOAD');
  perform pg_temp.q137_refused(format(
    'select api.end_booking_transition_chain(%L::uuid,%L::uuid)',
    y->>'session',command),'historical command cannot target a different session',
    '22023','authenticated','command_identity_mismatch');

  x:=pg_temp.terminal_case('OPEN',false);perform pg_temp.rejected_unchanged(x,'session_not_closed');
  x:=pg_temp.terminal_case('FREE');
  update ops.irrigation_sessions set booking_id=null where id=(x->>'session')::uuid;
  perform pg_temp.rejected_unchanged(x,'session_not_booked');
  x:=pg_temp.terminal_case('UNSETTLED');
  delete from billing.session_charges where session_id=(x->>'session')::uuid;
  perform pg_temp.rejected_unchanged(x,'session_not_settled');
  x:=pg_temp.terminal_case('OTHER-CURRENT');
  b:=pg_temp.terminal_next(x,'OTHER-CURRENT-NEXT');
  select operator_id into actor from terminal_seed limit 1;
  response:=ops.start_booking_session_core(b,actor,(x->>'start')::timestamptz+interval '5 minutes');
  next_session:=(response->>'session_id')::uuid;
  perform api.complete_irrigation_session(next_session,(x->>'start')::timestamptz+interval '8 minutes',p_command_id=>gen_random_uuid());
  perform pg_temp.rejected_unchanged(x,'session_not_chain_current');
  y:=x||jsonb_build_object('session',next_session);
  perform pg_temp.rejected_unchanged(y,'manual next session does not authorize chain termination');
  perform pg_temp.check_terminal(
    (select current_session_id=(x->>'session')::uuid
      and opened_by_session_id=(x->>'session')::uuid
      from ops.booking_transition_chains where id=(x->>'chain')::uuid),
    'manual start/complete of B leaves historical A chain untouched');
  foreach st in array array['active','waiting','pending_start','blocked'] loop
    x:=pg_temp.terminal_case('STATE-'||st);
    update ops.booking_transition_chains set status=st where id=(x->>'chain')::uuid;
    perform pg_temp.rejected_unchanged(x,'chain_state_not_terminal');
  end loop;
  x:=pg_temp.terminal_case('POINTED');b:=pg_temp.terminal_next(x,'POINTED-NEXT');
  update ops.booking_transition_chains set next_booking_id=b where id=(x->>'chain')::uuid;
  perform pg_temp.rejected_unchanged(x,'chain_next_booking_set');
  x:=pg_temp.terminal_case('GAP');perform pg_temp.terminal_next(x,'GAP-NEXT');
  perform pg_temp.rejected_unchanged(x,'next_booking_exists');
  x:=pg_temp.terminal_case('CANCELLED');perform pg_temp.terminal_next(x,'CANCELLED-NEXT','cancelled');
  perform pg_temp.rejected_unchanged(x,'cancelled later booking still cannot authorize new terminal request');
  x:=pg_temp.terminal_case('NEXT-DAY');b:=pg_temp.terminal_next(x,'NEXT-DAY-NEXT','confirmed',1);
  -- 00:30 في عدن لليوم التالي = 21:30 UTC من تاريخ حجز A نفسه.
  -- بيانات تاريخية تعبر منتصف ليل عدن؛ رفض الطلب الجديد مستقل عن يوم الحجز.
  update ops.irrigation_bookings set scheduled_start=(x->>'start')::timestamptz+interval '18 hours 30 minutes',
    scheduled_end=(x->>'start')::timestamptz+interval '18 hours 33 minutes' where id=b;
  perform pg_temp.rejected_unchanged(x,'next day booking still cannot authorize new terminal request');
  x:=pg_temp.terminal_case('OTHER-WELL');y:=pg_temp.terminal_case('OTHER-WELL-2');
  perform pg_temp.terminal_next(y,'OTHER-WELL-NEXT');
  perform pg_temp.rejected_unchanged(x,'other well still cannot authorize new terminal request');
  x:=pg_temp.terminal_case('UNAUTHORIZED');
  perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
  perform pg_temp.rejected_unchanged(x,'unauthorized');
  perform set_config('request.jwt.claim.sub',actor::text,true);
  perform pg_temp.q137_refused(format(
    'select ops.end_booking_transition_chain(%L::uuid,%L::uuid,%L::uuid)',
    x->>'session',gen_random_uuid(),gen_random_uuid()),
    'actor must equal auth.uid','42501',null,'unauthorized');
  perform pg_temp.q137_refused(format(
    'select ops.end_booking_transition_chain(%L::uuid,%L::uuid,%L::uuid)',
    x->>'session',actor,gen_random_uuid()),'direct ops call denied','42501');
  perform pg_temp.q137_refused(format(
    'select api.end_booking_transition_chain(%L::uuid,%L::uuid)',
    x->>'session',gen_random_uuid()),'anonymous terminal API denied','42501','anon');
  perform set_config('request.jwt.claim.sub','',true);
  perform pg_temp.q137_refused(format(
    'select api.end_booking_transition_chain(%L::uuid,%L::uuid)',
    x->>'session',gen_random_uuid()),'service role alone has no human identity',
    '42501','service_role','unauthorized');
  perform set_config('request.jwt.claim.sub',actor::text,true);
  perform pg_temp.q137_refused(format(
    'update ops.booking_transition_chains set decision_revision=decision_revision+1 where id=%L::uuid',
    x->>'chain'),'direct chain DML denied','42501');

  -- هوية لا تملك تعيينًا على البئر لا تقرأ حتى الإقرار التاريخي.
  perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
  perform pg_temp.q137_refused(format(
    'select api.end_booking_transition_chain(%L::uuid,%L::uuid)',
    historical_case->>'session',command),'unauthorized historical replay denied','42501');
  perform set_config('request.jwt.claim.sub',actor::text,true);
  x:=pg_temp.terminal_case('OTHER-OPEN');
  select id into b from core.pumps where well_id=(x->>'well')::uuid and status='active';
  perform ops.start_irrigation_session((x->>'well')::uuid,b,(x->>'farm')::uuid,(x->>'account')::uuid,actor,'well_diesel',clock_timestamp()-interval '1 minute');
  perform pg_temp.rejected_unchanged(x,'open_session_exists');

  -- نفس شرط GiST الحاكم؛ إثبات وجود مسار مفهرس لا يعتمد على حجم fixture.
  perform set_config('enable_seqscan','off',true);
  execute format('explain (format json) select 1 from ops.irrigation_bookings b where b.well_id=%L::uuid and b.status=''confirmed'' and tstzrange(b.scheduled_start,b.scheduled_end,''[)'') && tstzrange(%L::timestamptz,%L::timestamptz,''[)'') and b.scheduled_start>%L::timestamptz limit 1',
    x->>'well',x->>'start',((x->>'start')::timestamptz+interval '18 hours')::text,x->>'start') into plan;
  perform pg_temp.check_terminal(plan::text like '%irrigation_bookings_no_confirmed_well_overlap%','GiST index path for well/status/day interval');
end $tests$;
rollback;
