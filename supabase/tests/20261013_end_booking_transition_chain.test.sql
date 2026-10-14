-- Package A: إنهاء السلسلة الأخيرة دون كسر فجوة اليوم.
begin;

set local timezone to 'UTC';

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
  select id into c from ops.booking_transition_chains where well_id=w and status<>'ended';
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

create function pg_temp.call_terminal(p_case jsonb,p_command uuid)
returns jsonb language plpgsql as $f$
begin
  return api.end_booking_transition_chain((p_case->>'session')::uuid,p_command);
end $f$;

create function pg_temp.rejected_unchanged(p_case jsonb,p_reason text)
returns void language plpgsql as $f$
declare before_row jsonb; response jsonb; after_row jsonb;
begin
  select to_jsonb(c) into before_row from ops.booking_transition_chains c where id=(p_case->>'chain')::uuid;
  execute 'set local role authenticated';
  response:=pg_temp.call_terminal(p_case,gen_random_uuid());
  execute 'reset role';
  select to_jsonb(c) into after_row from ops.booking_transition_chains c where id=(p_case->>'chain')::uuid;
  perform pg_temp.check_terminal(response->>'status'='rejected' and response->>'reason_code'=p_reason,
    'reject '||p_reason);
  perform pg_temp.check_terminal(before_row=after_row,'rejection preserves every chain field: '||p_reason);
end $f$;

do $tests$
declare
  x jsonb; y jsonb; response jsonb; replay jsonb; before_row jsonb;
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

  x:=pg_temp.terminal_case('SUCCESS');
  execute 'set local role authenticated';
  response:=pg_temp.call_terminal(x,command);
  replay:=pg_temp.call_terminal(x,command);
  execute 'reset role';
  perform pg_temp.check_terminal(response->>'contract'='end_booking_transition_chain' and response->>'version'='1'
    and response->>'status'='ended','final settled booking ends chain');
  perform pg_temp.check_terminal(response=replay,'same command exact stored response replay');
  perform pg_temp.check_terminal((select count(*)=1 from sync.processed_commands where command_id=command),'one processed command');
  perform pg_temp.check_terminal((select c.status='ended' and c.ended_at=s.ended_at
    and c.ended_reason='final_booking_completed' and c.current_session_id=s.id and c.opened_by_session_id=s.id
    from ops.booking_transition_chains c join ops.irrigation_sessions s on s.id=c.current_session_id
    where c.id=(x->>'chain')::uuid),'end timestamp/reason and session identities preserved');
  perform pg_temp.rejected_unchanged(x,'no_non_ended_chain');
  y:=pg_temp.terminal_case('PAYLOAD');
  begin
    perform pg_temp.call_terminal(y,command);
    raise exception 'FAIL reused command with another session accepted';
  exception when sqlstate '22023' then raise notice 'PASS different payload rejected'; end;

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
  response:=pg_temp.call_terminal(y,gen_random_uuid());
  perform pg_temp.check_terminal(response->>'status'='ended' and
    (select current_session_id=next_session and opened_by_session_id=(x->>'session')::uuid
      from ops.booking_transition_chains where id=(x->>'chain')::uuid),
    'A gap rejects terminal close; final B ends chain preserving A opening identity');
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
  perform pg_temp.check_terminal(pg_temp.call_terminal(x,gen_random_uuid())->>'status'='ended','cancelled later booking does not block');
  x:=pg_temp.terminal_case('NEXT-DAY');b:=pg_temp.terminal_next(x,'NEXT-DAY-NEXT','confirmed',1);
  -- 00:30 في عدن لليوم التالي = 21:30 UTC من تاريخ حجز A نفسه.
  -- يكشف هذا الحد خطأ استعمال UTC بدل يوم Asia/Aden.
  update ops.irrigation_bookings set scheduled_start=(x->>'start')::timestamptz+interval '18 hours 30 minutes',
    scheduled_end=(x->>'start')::timestamptz+interval '18 hours 33 minutes' where id=b;
  perform pg_temp.check_terminal(pg_temp.call_terminal(x,gen_random_uuid())->>'status'='ended','next day booking does not block');
  x:=pg_temp.terminal_case('OTHER-WELL');y:=pg_temp.terminal_case('OTHER-WELL-2');
  perform pg_temp.terminal_next(y,'OTHER-WELL-NEXT');
  perform pg_temp.check_terminal(pg_temp.call_terminal(x,gen_random_uuid())->>'status'='ended','another well does not block');
  x:=pg_temp.terminal_case('UNAUTHORIZED');
  perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
  perform pg_temp.rejected_unchanged(x,'unauthorized');
  perform set_config('request.jwt.claim.sub',actor::text,true);
  perform pg_temp.check_terminal(ops.end_booking_transition_chain((x->>'session')::uuid,gen_random_uuid(),gen_random_uuid())->>'reason_code'='actor_mismatch','actor must equal auth.uid');
  execute 'set local role authenticated';
  begin
    perform ops.end_booking_transition_chain((x->>'session')::uuid,actor,gen_random_uuid());
    raise exception 'FAIL direct ops execute allowed';
  exception when insufficient_privilege then raise notice 'PASS direct ops call denied'; end;
  execute 'reset role';
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
