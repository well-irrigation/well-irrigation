\set ON_ERROR_STOP on
-- OWNER ONLY / local disposable database. No public correction API in C1.
begin;
set local timezone='UTC';
set local row_security=on;

create function pg_temp.c1_check(ok boolean,label text) returns void language plpgsql as $$
begin
 if ok is distinct from true then raise exception 'FAIL %',label;end if;
 raise notice 'PASS %',label;
end;$$;

create function pg_temp.c1_fixture(with_financial_history boolean default false) returns jsonb language plpgsql as $$
declare t uuid;w uuid;actor uuid:=gen_random_uuid();person uuid;farmer uuid;account uuid;farm uuid;pump uuid;
 sid uuid;start_command uuid:=gen_random_uuid();end_command uuid:=gen_random_uuid();booking uuid;
 at_time timestamptz:=date_trunc('day',transaction_timestamp())-interval '2 days';r jsonb;invoice uuid;
begin
 insert into core.tenants(name) values('C1 correction') returning id into t;
 insert into auth.users(id,instance_id,aud,role,email,email_confirmed_at,created_at,updated_at)
 values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@c1.test',now(),now(),now());
 insert into iam.profiles(id,full_name) values(actor,'C1 operator') on conflict(id) do nothing;
 insert into core.wells(tenant_id,name) values(t,'C1 well') returning id into w;
 insert into core.well_assignments(well_id,profile_id,role,status) values(w,actor,'operator','active');
 insert into core.persons(tenant_id,full_name,normalized_name) values(t,'C1 farmer','C1 farmer') returning id into person;
 insert into ops.farmer_profiles(tenant_id,person_id) values(t,person) returning id into farmer;
 insert into ops.farmer_well_accounts(tenant_id,farmer_profile_id,well_id,public_code)
 values(t,farmer,w,'C1-'||substr(actor::text,1,8)) returning id into account;
 insert into ops.farms(well_id,name,farmer_well_account_id) values(w,'C1 farm',account) returning id into farm;
 insert into core.pumps(well_id,name,power_source,status) values(w,'C1 pump','diesel','active') returning id into pump;
 insert into billing.well_pricing(well_id,price_per_hour_minor,period_start) values(w,3600,date '1970-01-01');
 insert into ops.shifts(tenant_id,well_id,operator_profile_id,started_at,status)
 values(t,w,actor,at_time-interval '1 hour','open');
 -- A planning overlap must not control the actual operational interval.
 insert into ops.irrigation_bookings(tenant_id,public_code,well_id,farmer_well_account_id,farm_id,
 scheduled_start,scheduled_end,expected_duration_minutes,expected_energy_source,status,created_by)
 values(t,'C1-'||substr(actor::text,1,8),w,account,farm,at_time+interval '30 minutes',
 at_time+interval '90 minutes',60,'solar','confirmed',actor) returning id into booking;
 perform set_config('request.jwt.claim.sub',actor::text,true);
 execute 'set local role authenticated';
 sid:=api.start_operational_session(w,pump,farm,account,'solar',at_time,start_command);
 perform api.pause_irrigation_session(sid,'operator_pause',at_time+interval '20 minutes',gen_random_uuid());
 perform api.resume_irrigation_session(sid,at_time+interval '30 minutes',gen_random_uuid());
 r:=api.complete_irrigation_session(sid,at_time+interval '1 hour',null,null,null,end_command);
 if with_financial_history then
  invoice:=api.issue_session_invoice(sid);
  perform api.record_payment(p_well_id=>w,p_farmer_well_account_id=>account,p_amount_minor=>1000,
   p_method=>'cash',p_session_charge_id=>(r->>'session_charge_id')::uuid,
   p_allocations=>jsonb_build_array(jsonb_build_object('invoice_id',invoice,'amount_minor',1000)),
   p_paid_at=>at_time+interval '1 hour',p_command_id=>gen_random_uuid());
 end if;
 execute 'reset role';
 return jsonb_build_object('tenant',t,'well',w,'actor',actor,'session',sid,'at',at_time,'farm',farm,'account',account,
 'start_command',start_command,'end_command',end_command,'booking',booking,'pump',pump);
exception when others then execute 'reset role';raise;
end;$$;

create function pg_temp.c1_accept(f jsonb,cmd uuid,base bigint,desired_start timestamptz,desired_end timestamptz,
 reason text default '  original reason  ',requested timestamptz default '2026-01-01T00:00:00Z')
returns jsonb language sql as $$
 select ops.accept_session_correction((f->>'session')::uuid,cmd,base,reason,desired_start,desired_end,requested);
$$;
create function pg_temp.c1_error(f jsonb,cmd uuid,base bigint,s timestamptz,e timestamptz,
 reason text default 'reason',requested timestamptz default '2026-01-01T00:00:00Z')
returns text language plpgsql as $$
begin
 perform pg_temp.c1_accept(f,cmd,base,s,e,reason,requested);return null;
exception when others then return SQLERRM;end;$$;

-- All financial/inventory rows, original receipts and operational evidence,
-- compared by content, not merely counts. Only C1's permitted revision differs.
create function pg_temp.c1_original_snapshot() returns jsonb language plpgsql as $$
declare x record;v jsonb;r jsonb:='{}';
begin
 for x in select n.nspname,c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
 where c.relkind in ('r','p') and n.nspname in ('billing','finance','inventory') order by 1,2 loop
  execute format('select jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text) from %I.%I t',x.nspname,x.relname) into v;
  r:=r||jsonb_build_object(x.nspname||'.'||x.relname,v);
 end loop;
 return r||jsonb_build_object(
 'sessions',(select jsonb_agg(to_jsonb(s)-'operational_revision' order by id) from ops.irrigation_sessions s),
 'segments',(select jsonb_agg(to_jsonb(s) order by id) from ops.session_segments s),
 'occurrences',(select jsonb_agg(to_jsonb(o) order by tenant_id,occurrence_command_id) from ops.operational_occurrences o),
 'bookings',(select jsonb_agg(to_jsonb(b) order by id) from ops.irrigation_bookings b),
 'receipts',(select jsonb_agg(to_jsonb(c) order by id) from sync.processed_commands c
 where command_type<>'correct_irrigation_session'));
end;$$;

create function pg_temp.c1_fail_work_insert() returns trigger language plpgsql as $$
begin
 if new.session_id::text=current_setting('c1.fail_session',true) then
  raise exception 'c1_work_insert_failure' using errcode='XX000';end if;
 return new;
end;$$;
create trigger c1_test_work_failure before insert on ops.session_correction_reconciliations
 for each row execute function pg_temp.c1_fail_work_insert();

do $tests$
declare f jsonb;g jsonb;h jsonb;r jsonb;again jsonb;snap jsonb;history jsonb;
 t timestamptz;cmd uuid:=gen_random_uuid();cmd2 uuid:=gen_random_uuid();cid uuid;sid uuid;other uuid;other_well uuid;failed_cmd uuid;
 denied boolean;role_name text;obj text;key text;err text;completion_receipt jsonb;start_receipt jsonb;
begin
 f:=pg_temp.c1_fixture(true);t:=(f->>'at')::timestamptz;sid:=(f->>'session')::uuid;
 -- Original posting context is closed: accepting operational facts must not
 -- post, reopen, or select an alternative accounting period.
 update finance.accounting_periods set status='closed',closed_at=clock_timestamp(),closed_by=(f->>'actor')::uuid
 where well_id=(f->>'well')::uuid and t::date between starts_at and ends_at;
 perform pg_temp.c1_check((select operational_revision=0 from ops.irrigation_sessions where id=sid),'01 original revision zero');
 snap:=pg_temp.c1_original_snapshot();
 start_receipt:=api.get_operational_start_receipt((f->>'well')::uuid,(f->>'start_command')::uuid);
 completion_receipt:=api.get_completion_receipt((f->>'well')::uuid,sid,(f->>'end_command')::uuid);
 r:=pg_temp.c1_accept(f,cmd,0,t-interval '5 minutes',t+interval '1 hour');
 cid:=(r->>'correction_id')::uuid;
 perform pg_temp.c1_check(r->>'status'='accepted' and r->>'operational_revision'='1'
 and r->>'financial_status'='pending'
 and exists(select 1 from finance.accounting_periods where well_id=(f->>'well')::uuid and status='closed'),
 '02 completed correction accepted in closed original financial period, financial pending');
 perform pg_temp.c1_check((select before_started_at=t and before_ended_at=t+interval '1 hour'
 and after_started_at=t-interval '5 minutes' and after_ended_at=t+interval '1 hour'
 and reason='  original reason  ' and accepted_at>requested_at
 from ops.session_corrections where id=cid),'03 start-only full pair and exact reason preserved');
 perform pg_temp.c1_check((select operational_revision=1 and effective_started_at=t-interval '5 minutes'
 and effective_ended_at=t+interval '1 hour' from ops.effective_session_facts where session_id=sid),'04 effective revision one');
 again:=pg_temp.c1_accept(f,cmd,0,t-interval '5 minutes',t+interval '1 hour');
 perform pg_temp.c1_check(again=r,'05 exact replay before stale base check returns original result');
 perform pg_temp.c1_check(pg_temp.c1_error(f,cmd,0,t,t+interval '1 hour')='session_correction_idempotency_conflict',
 '06 changed replay rejected');
 perform pg_temp.c1_check(pg_temp.c1_error(f,cmd,0,t-interval '5 minutes',t+interval '1 hour',
 '  original reason  ','2026-01-02T00:00:00Z')='session_correction_idempotency_conflict','07 requested_at belongs to replay identity');
 perform pg_temp.c1_check(pg_temp.c1_error(f,gen_random_uuid(),0,t,t+interval '1 hour')='stale_revision','08 stale revision rejected');
 r:=pg_temp.c1_accept(f,cmd2,1,t-interval '5 minutes',t+interval '65 minutes');
 perform pg_temp.c1_check((select previous_revision=1 and new_revision=2 and before_started_at=t-interval '5 minutes'
 and before_ended_at=t+interval '1 hour' and after_ended_at=t+interval '65 minutes'
 from ops.session_corrections where command_id=cmd2),'09 end-only revision chains from effective revision one');
 r:=pg_temp.c1_accept(f,gen_random_uuid(),2,t-interval '10 minutes',t+interval '70 minutes');
 perform pg_temp.c1_check((select operational_revision=3 and effective_started_at=t-interval '10 minutes'
 and effective_ended_at=t+interval '70 minutes' from ops.effective_session_facts where session_id=sid),'10 both outer boundaries corrected');
 perform pg_temp.c1_check(pg_temp.c1_original_snapshot()=snap,
 '11 original times, segments, occurrence, receipts, charge, invoice, payment, allocation, credit, journal, distribution and fuel unchanged; no replacement session');
 perform pg_temp.c1_check(not(r ?| array['amount_minor','approved_amount_minor','financial_revision']),
 '11b operational acceptance does not fabricate applied financial values');
 perform pg_temp.c1_check(api.get_operational_start_receipt((f->>'well')::uuid,(f->>'start_command')::uuid)=start_receipt
 and api.get_completion_receipt((f->>'well')::uuid,sid,(f->>'end_command')::uuid)=completion_receipt,
 '12 original accepted receipt reads unchanged');
 perform pg_temp.c1_check((select count(*)=3 and bool_and(status='pending' and attempt_count=0)
 from ops.session_correction_reconciliations where session_id=sid),'13 exactly one pending work item per correction');
 perform pg_temp.c1_check((select occurrence_command_id=(f->>'start_command')::uuid
 and original_start_command_id=(f->>'start_command')::uuid and original_completion_command_id=(f->>'end_command')::uuid
 from ops.session_corrections where id=cid),'14 proven original identities preserved');
 again:=pg_temp.c1_accept(f,cmd,0,t-interval '5 minutes',t+interval '1 hour');
 perform pg_temp.c1_check(again->>'operational_revision'='1' and again->>'correction_id'=cid::text,
 '14b old exact result remains original after later revisions');
 history:=(select jsonb_agg(to_jsonb(c) order by new_revision) from ops.session_corrections c where session_id=sid);
 begin update ops.irrigation_sessions set started_at=started_at-interval '1 minute' where id=sid;
 raise exception 'missing original time protection';exception when check_violation then null;end;
 begin update ops.session_corrections set reason='tamper' where id=cid;raise exception 'missing history protection';
 exception when check_violation then null;end;
 begin delete from ops.session_corrections where id=cid;raise exception 'missing history protection';
 exception when check_violation then null;end;
 perform pg_temp.c1_check(history=(select jsonb_agg(to_jsonb(c) order by new_revision)
 from ops.session_corrections c where session_id=sid),'15 history append-only even for owner DML');
 begin update ops.session_correction_reconciliations set status='applied' where session_id=sid and operational_revision=2;
 raise exception 'missing financial ordering';exception when check_violation then null;end;
 perform pg_temp.c1_check((select bool_and(status='pending') from ops.session_correction_reconciliations where session_id=sid),
 '16 later financial revision cannot overtake pending predecessor');
 perform pg_temp.c1_check(pg_temp.c1_error(f,gen_random_uuid(),3,t,t+interval '1 hour','  ')='session_correction_reason_required','17 blank reason denied');
 perform pg_temp.c1_check(pg_temp.c1_error(f,gen_random_uuid(),3,t,t)='session_correction_invalid_times','18 nonpositive pair denied');
 perform pg_temp.c1_check(pg_temp.c1_error(f,gen_random_uuid(),3,null,t+interval '1 hour')='session_correction_invalid_times'
 and pg_temp.c1_error(f,gen_random_uuid(),3,t,null)='session_correction_invalid_times','19 no NULL patch semantics');
 perform pg_temp.c1_check(pg_temp.c1_error(f,gen_random_uuid(),3,'-infinity',t+interval '1 hour')='session_correction_invalid_times',
 '20 infinite time denied');
 perform pg_temp.c1_check(pg_temp.c1_error(f,gen_random_uuid(),3,t,clock_timestamp()+interval '1 day')='session_correction_invalid_times',
 '20b future actual end denied');
 perform pg_temp.c1_check(pg_temp.c1_error(f,gen_random_uuid(),3,t,t+interval '1 hour','reason',null)=
 'session_correction_requested_at_required','20c original intent time is mandatory');
 perform pg_temp.c1_check(pg_temp.c1_error(f,gen_random_uuid(),3,t+interval '20 minutes',t+interval '1 hour')=
 'session_correction_segment_boundary_invalid','21 first segment cannot be swallowed');
 perform pg_temp.c1_check(pg_temp.c1_error(f,gen_random_uuid(),3,t,t+interval '30 minutes')=
 'session_correction_segment_boundary_invalid','22 last segment cannot be swallowed');
 -- A second actual session on the same well, after the corrected end.
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 execute 'set local role authenticated';
 other:=api.start_operational_session((f->>'well')::uuid,(f->>'pump')::uuid,(f->>'farm')::uuid,(f->>'account')::uuid,
 'solar',t+interval '2 hours',gen_random_uuid());
 execute 'reset role';
 h:=f||jsonb_build_object('session',other);
 perform pg_temp.c1_check(pg_temp.c1_error(h,gen_random_uuid(),0,t+interval '2 hours',t+interval '3 hours')=
 'session_correction_completed_facts_required','22b open session cannot be corrected');
 perform pg_temp.c1_check(pg_temp.c1_error(f,gen_random_uuid(),3,t,t+interval '3 hours')='session_correction_resource_overlap',
 '23 open actual session overlap denied');
 perform api.complete_irrigation_session(other,t+interval '3 hours',null,null,null,gen_random_uuid());
 r:=ops.accept_session_correction(other,gen_random_uuid(),0,'other effective boundary',t+interval '90 minutes',
 t+interval '3 hours','2026-01-01T00:00:00Z');
 perform pg_temp.c1_check(pg_temp.c1_error(f,gen_random_uuid(),3,t,t+interval '100 minutes')='session_correction_resource_overlap',
 '24 overlap uses other corrected session rather than original start');
 perform pg_temp.c1_check(pg_temp.c1_error(f,gen_random_uuid(),3,t,t+interval '90 minutes') is null,
 '25 touching intervals allowed; planning overlap has no authority');
 h:=f||jsonb_build_object('session',other);
 perform pg_temp.c1_check(pg_temp.c1_error(h,cmd,1,t+interval '90 minutes',t+interval '3 hours')=
 'session_correction_idempotency_conflict','25a command cannot be rebound to another authorized session');
 failed_cmd:=gen_random_uuid();
 perform set_config('c1.fail_session',sid::text,true);
 perform pg_temp.c1_check(pg_temp.c1_error(f,failed_cmd,4,t-interval '1 minute',t+interval '90 minutes')=
 'c1_work_insert_failure','25b injected work failure reaches final acceptance step');
 perform set_config('c1.fail_session','',true);
 perform pg_temp.c1_check((select operational_revision=4 from ops.irrigation_sessions where id=sid)
 and not exists(select 1 from ops.session_corrections where command_id=failed_cmd)
 and not exists(select 1 from sync.processed_commands where tenant_id=(f->>'tenant')::uuid and command_id=failed_cmd)
 and (select count(*)=4 from ops.session_correction_reconciliations where session_id=sid),
 '25c history, revision, work and processed command roll back together');
 -- No evidence is invented for a historical session without command provenance.
 g:=pg_temp.c1_fixture();
 -- Owner fixture removes only provenance by constructing a separate legacy closed session.
 perform set_config('request.jwt.claim.sub',g->>'actor',true);
 insert into ops.irrigation_sessions(well_id,pump_id,farm_id,farmer_well_account_id,operator_profile_id,started_at,ended_at,status)
 select well_id,pump_id,farm_id,farmer_well_account_id,operator_profile_id,t-interval '1 day',t-interval '23 hours','closed'
 from ops.irrigation_sessions where id=(g->>'session')::uuid returning id into other;
 insert into ops.session_segments(tenant_id,session_id,sequence_number,segment_type,energy_source,started_at,ended_at,is_billable)
 values((g->>'tenant')::uuid,other,1,'solar_run','solar',t-interval '1 day',t-interval '23 hours',true);
 r:=ops.accept_session_correction(other,gen_random_uuid(),0,'legacy no invented identity',t-interval '1 day 1 minute',
 t-interval '23 hours','2026-01-01T00:00:00Z');
 perform pg_temp.c1_check((select occurrence_command_id is null and original_start_command_id is null
 and original_completion_command_id is null from ops.session_corrections where id=(r->>'correction_id')::uuid),
 '26 historical missing identities remain NULL');
 perform pg_temp.c1_check((select count(*)=count(distinct session_id) from ops.effective_session_facts)
 and (select count(*) from ops.effective_session_facts)=(select count(*) from ops.irrigation_sessions),
 '26b exactly one internal effective state for every original session');
 -- Authorization is checked on replay too, before returning a stored result.
 perform set_config('request.jwt.claim.sub','',true);
 perform pg_temp.c1_check(pg_temp.c1_error(f,cmd,0,t-interval '5 minutes',t+interval '1 hour')=
 'session_correction_requires_authentication','27 missing authentication denied');
 perform set_config('request.jwt.claim.sub',g->>'actor',true);
 perform pg_temp.c1_check(pg_temp.c1_error(f,gen_random_uuid(),4,t,t+interval '1 hour')='session_correction_forbidden','28 cross tenant denied');
 insert into core.wells(tenant_id,name) values((f->>'tenant')::uuid,'C1 other well') returning id into other_well;
 insert into core.well_assignments(well_id,profile_id,role,status) values(other_well,(g->>'actor')::uuid,'operator','active');
 perform pg_temp.c1_check(pg_temp.c1_error(f,gen_random_uuid(),4,t,t+interval '1 hour')='session_correction_forbidden',
 '28b active assignment elsewhere in same tenant does not authorize this well');
 insert into core.well_assignments(well_id,profile_id,role,status)
 values((f->>'well')::uuid,(g->>'actor')::uuid,'operator','active');
 r:=pg_temp.c1_accept(f,gen_random_uuid(),4,t-interval '2 minutes',t+interval '90 minutes');
 perform pg_temp.c1_check((select actor_id=(g->>'actor')::uuid from ops.session_corrections where id=(r->>'correction_id')::uuid),
 '28c correcting operator need not be original operator');
 insert into core.well_assignments(well_id,profile_id,role,status)
 values((g->>'well')::uuid,(f->>'actor')::uuid,'operator','active');
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 update core.well_assignments set status='inactive' where well_id=(f->>'well')::uuid and profile_id=(f->>'actor')::uuid;
 perform pg_temp.c1_check(pg_temp.c1_error(f,cmd,0,t-interval '5 minutes',t+interval '1 hour')='session_correction_forbidden',
 '29 inactive assignment cannot replay');
 update core.well_assignments set status='active',role='viewer' where well_id=(f->>'well')::uuid and profile_id=(f->>'actor')::uuid;
 perform pg_temp.c1_check(pg_temp.c1_error(f,gen_random_uuid(),4,t,t+interval '1 hour')='session_correction_forbidden','30 session.correct required');
 update core.well_assignments set role='operator' where well_id=(f->>'well')::uuid and profile_id=(f->>'actor')::uuid;
 h:=f||jsonb_build_object('session',gen_random_uuid());
 perform pg_temp.c1_check(pg_temp.c1_error(h,gen_random_uuid(),0,t,t+interval '1 hour')='session_correction_forbidden','31 nonexistent scope denied');
 foreach role_name in array array['anon','authenticated','service_role'] loop
  perform pg_temp.c1_check(not has_function_privilege(role_name,
  'ops.accept_session_correction(uuid,uuid,bigint,text,timestamptz,timestamptz,timestamptz)','EXECUTE'),
  '32 private acceptance denied to '||role_name);
  foreach obj in array array['ops.session_corrections','ops.session_correction_reconciliations'] loop
   perform pg_temp.c1_check(not has_table_privilege(role_name,obj,'INSERT,UPDATE,DELETE'), '33 no direct DML '||role_name||' '||obj);
  end loop;
 end loop;
 execute 'set local role authenticated';denied:=false;
 begin insert into ops.session_corrections default values;
 exception when insufficient_privilege then denied:=true;end;
 execute 'reset role';perform pg_temp.c1_check(denied,'33b authenticated direct history INSERT denied');
 execute 'set local role authenticated';denied:=false;
 begin update ops.session_correction_reconciliations set status='applied' where session_id=sid;
 exception when insufficient_privilege then denied:=true;end;
 execute 'reset role';perform pg_temp.c1_check(denied,'33c authenticated direct work UPDATE denied');
 execute 'set local role authenticated';denied:=false;
 begin update ops.irrigation_sessions set operational_revision=999 where id=sid;
 exception when insufficient_privilege or check_violation then denied:=true;end;
 execute 'reset role';perform pg_temp.c1_check(denied,'34 client revision DML denied');
 execute 'set local role anon';denied:=false;
 begin perform ops.accept_session_correction(sid,gen_random_uuid(),4,'denied',t,t+interval '1 hour',now());
 exception when insufficient_privilege then denied:=true;end;
 execute 'reset role';perform pg_temp.c1_check(denied,'35 anonymous EXECUTE denied');
 perform pg_temp.c1_check(to_regprocedure('api.correct_irrigation_session(uuid,uuid,bigint,text,timestamptz,timestamptz,timestamptz)') is null,
 '36 no public correction endpoint');
 select lower(prosrc) into key from pg_proc where oid=
 'ops.accept_session_correction(uuid,uuid,bigint,text,timestamptz,timestamptz,timestamptz)'::regprocedure;
 perform pg_temp.c1_check(key !~ '(execute_booking_transition|execute_booking_transition_automation|execute_pending_booking_start|record_booking_transition_decision)',
 '37 zero retired transition calls');
end;$tests$;
rollback;
