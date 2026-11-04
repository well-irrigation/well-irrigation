-- Q137: قراءة الجلسة الحالية من بيانات سلسلة تاريخية فقط.
\set ON_ERROR_STOP on
-- Q137-REFERENCE-CLASS: EXPECTED_HISTORICAL_READ_FIXTURE
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
  -- تجهيز بمالك الاختبار دون هوية تطبيق موروثة من اختبار رفض سابق.
  -- RESET ROLE وحده لا يمسح JWT؛ تضبط هوية المشغل لاحقًا قبل عقد التشغيل.
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
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
  if exists(select 1 from ops.booking_transition_chains where well_id=w) then
    raise exception 'FAIL current manual operations created a transition chain';
  end if;
  -- historical fixture for retained Q137 read/replay contract.
  -- صف تاريخي صريح متسق مع الجلسة والبئر؛ لا ينشئه start أو complete.
  insert into ops.booking_transition_chains(
    tenant_id,well_id,status,opened_by_session_id,opened_at,
    current_session_id,decision_revision,created_by)
  values(t.tenant_id,w,'active',s,started+interval '23 seconds',s,0,t.operator_id)
  returning id into c;
  return jsonb_build_object('well',w,'booking',b,'session',s,'chain',c,'start',started,
    'account',a,'farm',f,'tenant',t.tenant_id);
end $f$;

do $tests$
declare
 x jsonb; isolated jsonb; isolated_actor uuid:=gen_random_uuid(); response jsonb; chain_json jsonb; st text; denied boolean; before_row jsonb;
begin
 x := pg_temp.terminal_case('recovery-read');
 -- terminal_case leaves the same canonical actor configured.
 for st in select unnest(array['active','decision_required','waiting','pending_start']) loop
   update ops.booking_transition_chains set status=st,decision_revision=7
     where id=(x->>'chain')::uuid;
   select to_jsonb(c) into before_row from ops.booking_transition_chains c where id=(x->>'chain')::uuid;
   execute 'set local role authenticated';
   response:=api.get_well_booking_automation((x->>'well')::uuid);
   execute 'reset role';
   chain_json:=response->'active_chain';
   perform pg_temp.check_terminal(chain_json ? 'current_session_id' and
     chain_json->>'current_session_id'=x->>'session','canonical current session: '||st);
   perform pg_temp.check_terminal(chain_json-'current_session_id'=jsonb_build_object(
     'chain_id',x->>'chain','status',st,'next_booking_id',null,'decision_revision',7),
     'existing chain keys unchanged: '||st);
   perform pg_temp.check_terminal(response->>'contract'='get_well_booking_automation' and
     response->>'version'='1' and response->>'well_id'=x->>'well' and
     response->>'first_session'='manual' and response->>'automation_executor_ready'='false' and
     response->>'auto_transition_executed'='false','outer contract unchanged: '||st);
   perform pg_temp.check_terminal(before_row=(select to_jsonb(c) from ops.booking_transition_chains c where id=(x->>'chain')::uuid),'read leaves chain unchanged: '||st);
 end loop;
 update ops.booking_transition_chains set current_session_id=null where id=(x->>'chain')::uuid;
 execute 'set local role authenticated';
 response:=api.get_well_booking_automation((x->>'well')::uuid);
 execute 'reset role';
 perform pg_temp.check_terminal(response->'active_chain' ? 'current_session_id' and
   response->'active_chain'->'current_session_id'='null'::jsonb,'legitimate null current session');
 update ops.booking_transition_chains set status='ended',ended_at=now() where id=(x->>'chain')::uuid;
 execute 'set local role authenticated';response:=api.get_well_booking_automation((x->>'well')::uuid);execute 'reset role';
 perform pg_temp.check_terminal(response->'active_chain'='null'::jsonb,'no non-ended chain remains null');
 perform pg_temp.check_terminal(exists(select 1 from pg_proc where oid='api.get_well_booking_automation(uuid)'::regprocedure
   and not prosecdef and provolatile='s' and proconfig @> array['search_path=pg_catalog, pg_temp']),'invoker stable search_path preserved');
 perform pg_temp.check_terminal(not has_function_privilege('anon','api.get_well_booking_automation(uuid)','execute'),'anon remains denied');
 perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 execute 'set local role authenticated';denied:=false;
 begin perform api.get_well_booking_automation((x->>'well')::uuid);exception when insufficient_privilege then denied:=true;end;
 execute 'reset role';perform pg_temp.check_terminal(denied,'unassigned actor remains denied');
 -- فاعل مخول على بئر آخر في الجهة نفسها؛ لا يقرأ البئر الأصلي.
 isolated := pg_temp.terminal_case('isolated-read');
 insert into auth.users(id,raw_user_meta_data)
   values(isolated_actor,'{"full_name":"مشغل بئر معزول"}');
 insert into core.well_assignments(well_id,profile_id,role,status)
   values((isolated->>'well')::uuid,isolated_actor,'operator','active');
 perform set_config('request.jwt.claim.sub',isolated_actor::text,true);
 execute 'set local role authenticated';
 response:=api.get_well_booking_automation((isolated->>'well')::uuid);
 execute 'reset role';
 perform pg_temp.check_terminal(response->>'well_id'=isolated->>'well',
   'assigned other well is readable');
 execute 'set local role authenticated';denied:=false;
 begin perform api.get_well_booking_automation((x->>'well')::uuid);
 exception when insufficient_privilege then denied:=true;end;
 execute 'reset role';
 perform pg_temp.check_terminal(denied,'same-tenant well isolation preserved');
 perform set_config('request.jwt.claim.sub','',true);
 execute 'set local role authenticated';denied:=false;
 begin perform api.get_well_booking_automation((x->>'well')::uuid);exception when others then denied:=true;end;
 execute 'reset role';perform pg_temp.check_terminal(denied,'missing auth remains denied');
end $tests$;
rollback;
