\set ON_ERROR_STOP on
-- OWNER ONLY / disposable local DB. R6-C2B RED specification; no activation here.
begin;
set local timezone='UTC';
set local row_security=on;

create function pg_temp.c2b_check(ok boolean,label text) returns void language plpgsql as $$
begin
 if ok is distinct from true then raise exception 'FAIL %',label;end if;
 raise notice 'PASS %',label;
end;$$;

-- Resolve signatures before any call, so baseline RED is an explicit assertion.
do $surface$
declare writer oid;reader oid;obj text;role_name text;
begin
 writer:=to_regprocedure('api.correct_irrigation_session(uuid,uuid,bigint,text,timestamptz,timestamptz,timestamptz)');
 perform pg_temp.c2b_check(writer is not null,
  '01 missing public correction write: api.correct_irrigation_session(uuid,uuid,bigint,text,timestamptz,timestamptz,timestamptz)');
 reader:=to_regprocedure('api.get_session_correction_receipt(uuid,uuid)');
 perform pg_temp.c2b_check(reader is not null,
  '02 missing public recovery read: api.get_session_correction_receipt(uuid,uuid)');
 perform pg_temp.c2b_check((select not prosecdef and prorettype='jsonb'::regtype and provolatile='v'
  and proargnames=array['p_session_id','p_command_id','p_base_revision','p_reason',
   'p_desired_started_at','p_desired_ended_at','p_requested_at']::text[] from pg_proc where oid=writer),
  '03 write is INVOKER jsonb with seven business arguments and no client actor identity');
 perform pg_temp.c2b_check((select not prosecdef and prorettype='jsonb'::regtype and provolatile in ('s','i')
  and proargnames=array['p_session_id','p_command_id']::text[] from pg_proc where oid=reader),
  '04 receipt is a stable read-only INVOKER jsonb contract');
 perform pg_temp.c2b_check(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='api' and p.proname in ('correct_irrigation_session','get_session_correction_receipt')
   and p.oid not in (writer,reader)),
  '05 no parallel correction overload accepting client actor/tenant identity');
 perform pg_temp.c2b_check(has_function_privilege('authenticated',writer,'EXECUTE')
  and has_function_privilege('service_role',writer,'EXECUTE')
  and not has_function_privilege('anon',writer,'EXECUTE')
  and has_function_privilege('authenticated',reader,'EXECUTE')
  and has_function_privilege('service_role',reader,'EXECUTE')
  and not has_function_privilege('anon',reader,'EXECUTE'),
  '06 authenticated/service_role parity and anonymous denial for both contracts');
 -- An INVOKER wrapper may need internal acceptance EXECUTE. That grant alone
 -- is not a Data API exposure: ops remains unexposed; business authorization
 -- must remain inside acceptance. This RED suite never grants it.
 perform pg_temp.c2b_check(not has_function_privilege('anon',
  'ops.accept_session_correction(uuid,uuid,bigint,text,timestamptz,timestamptz,timestamptz)','EXECUTE'),
  '07 anon cannot execute internal acceptance');
 foreach role_name in array array['authenticated','anon'] loop
  perform pg_temp.c2b_check(not has_function_privilege(role_name,
   'billing.reconcile_session_correction(uuid,uuid,timestamptz)','EXECUTE'),
   '08 financial reconciliation stays closed to '||role_name);
  foreach obj in array array['ops.session_corrections','ops.session_correction_reconciliations'] loop
   perform pg_temp.c2b_check(not has_table_privilege(role_name,obj,'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'),
    '09 no direct writes/control on '||obj||' for '||role_name);
  end loop;
 end loop;
end;$surface$;

-- Independent fixture: each SQL test runs in its own connection/transaction.
-- All operational evidence is produced by real public start/complete commands.
create function pg_temp.c2b_fixture() returns jsonb language plpgsql as $$
declare tenant uuid;well uuid;actor uuid:=gen_random_uuid();person uuid;farmer uuid;
 account uuid;farm uuid;pump uuid;sid uuid;completion jsonb;
 started timestamptz:=date_trunc('day',transaction_timestamp())-interval '3 days'+interval '8 hours';
 start_command uuid:=gen_random_uuid();end_command uuid:=gen_random_uuid();
begin
 insert into core.tenants(name) values('R6C2B write recovery') returning id into tenant;
 insert into auth.users(id,instance_id,aud,role,email,email_confirmed_at,created_at,updated_at)
 values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
  actor||'@r6c2b.test',now(),now(),now());
 insert into iam.profiles(id,full_name) values(actor,'مشغل اختبار استعادة التصحيح') on conflict(id) do nothing;
 insert into core.wells(tenant_id,name) values(tenant,'R6C2B well') returning id into well;
 insert into core.well_assignments(well_id,profile_id,role,status) values(well,actor,'operator','active');
 insert into core.persons(tenant_id,full_name,normalized_name)
 values(tenant,'R6C2B farmer','R6C2B farmer') returning id into person;
 insert into ops.farmer_profiles(tenant_id,person_id) values(tenant,person) returning id into farmer;
 insert into ops.farmer_well_accounts(tenant_id,farmer_profile_id,well_id,public_code)
 values(tenant,farmer,well,'R6C2B-'||substr(actor::text,1,8)) returning id into account;
 insert into ops.farms(well_id,name,farmer_well_account_id) values(well,'R6C2B farm',account) returning id into farm;
 insert into core.pumps(well_id,name,power_source,status) values(well,'R6C2B pump','diesel','active') returning id into pump;
 insert into billing.well_pricing(well_id,price_per_hour_minor,period_start)
 values(well,3600,date '1970-01-01');
 insert into ops.shifts(tenant_id,well_id,operator_profile_id,started_at,status)
 values(tenant,well,actor,started-interval '1 hour','open');
 perform set_config('request.jwt.claim.sub',actor::text,true);
 execute 'set local role authenticated';
 sid:=api.start_operational_session(well,pump,farm,account,'solar',started,start_command);
 completion:=api.complete_irrigation_session(sid,started+interval '2 hours',null,null,null,end_command);
 execute 'reset role';
 return jsonb_build_object('tenant',tenant,'actor',actor,'well',well,'session',sid,'at',started,
  'start_command',start_command,'end_command',end_command,'charge',completion->'session_charge_id');
exception when others then execute 'reset role';raise;
end;$$;

create function pg_temp.c2b_write(sid uuid,cmd uuid,base bigint,reason text,
 desired_start timestamptz,desired_end timestamptz,requested timestamptz)
returns jsonb language plpgsql as $$
declare result jsonb;
begin
 execute 'set local role authenticated';
 result:=api.correct_irrigation_session(sid,cmd,base,reason,desired_start,desired_end,requested);
 execute 'reset role';return result;
exception when others then execute 'reset role';raise;
end;$$;

create function pg_temp.c2b_attempt(sid uuid,cmd uuid,base bigint,reason text,
 desired_start timestamptz,desired_end timestamptz,requested timestamptz)
returns jsonb language plpgsql as $$
declare result jsonb;
begin
 result:=pg_temp.c2b_write(sid,cmd,base,reason,desired_start,desired_end,requested);
 return jsonb_build_object('outcome','returned','response',result);
exception when others then
 return jsonb_build_object('outcome','raised','sqlstate',SQLSTATE,'message',SQLERRM);
end;$$;

create function pg_temp.c2b_receipt(sid uuid,cmd uuid) returns jsonb language plpgsql as $$
declare result jsonb;
begin
 execute 'set local role authenticated';
 result:=api.get_session_correction_receipt(sid,cmd);
 execute 'reset role';return result;
exception when others then execute 'reset role';raise;
end;$$;

create function pg_temp.c2b_state() returns jsonb language sql as $$
 select jsonb_build_object(
  'sessions',(select jsonb_agg(to_jsonb(s) order by id) from ops.irrigation_sessions s),
  'history',(select jsonb_agg(to_jsonb(h) order by id) from ops.session_corrections h),
  'work',(select jsonb_agg(to_jsonb(w) order by correction_id) from ops.session_correction_reconciliations w),
  'commands',(select jsonb_agg(to_jsonb(c) order by id) from sync.processed_commands c));
$$;

create function pg_temp.c2b_originals() returns jsonb language plpgsql as $$
declare result jsonb:='{}';value jsonb;obj record;
begin
 for obj in select n.nspname,c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where c.relkind in ('r','p') and n.nspname in ('billing','finance','inventory') order by 1,2 loop
  execute format('select jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text) from %I.%I t',obj.nspname,obj.relname) into value;
  result:=result||jsonb_build_object(obj.nspname||'.'||obj.relname,value);
 end loop;
 return result||jsonb_build_object(
  'sessions',(select jsonb_agg(to_jsonb(s)-'operational_revision' order by id) from ops.irrigation_sessions s),
  'segments',(select jsonb_agg(to_jsonb(s) order by id) from ops.session_segments s),
  'occurrences',(select jsonb_agg(to_jsonb(o) order by tenant_id,occurrence_command_id) from ops.operational_occurrences o),
  'receipts',(select jsonb_agg(to_jsonb(c) order by id) from sync.processed_commands c
   where command_type<>'correct_irrigation_session'));
end;$$;

-- Recovery follows the existing public receipt envelope convention. A read is
-- never authority to resend, even when durable evidence cannot be found.
create function pg_temp.c2b_accepted_receipt(result jsonb,sid uuid,cmd uuid,accepted jsonb)
returns boolean language sql as $$
 select coalesce(result->>'contract'='get_session_correction_receipt'
  and result->'version'='1'::jsonb and result->>'status'='accepted'
  and result->>'session_id'=sid::text and result->>'command_id'=cmd::text
  and result->>'command_type'='correct_irrigation_session'
  and result->'retry_authorized'='false'::jsonb and result->'receipt'=accepted,false);
$$;

do $behavior$
declare f jsonb;foreign_fixture jsonb;sid uuid;tenant uuid;cmd uuid:=gen_random_uuid();cmd2 uuid:=gen_random_uuid();
 unknown_cmd uuid:=gen_random_uuid();stale_cmd uuid:=gen_random_uuid();rejected_cmd uuid:=gen_random_uuid();
 processing_cmd uuid:=gen_random_uuid();orphan_cmd uuid:=gen_random_uuid();
 t timestamptz;requested timestamptz:=transaction_timestamp();v_reason text:='  تصحيح وقت التنفيذ  ';
 accepted jsonb;accepted2 jsonb;result jsonb;attempt jsonb;before_state jsonb;originals jsonb;
 request jsonb;key text;kind text;foreign_result jsonb;denied boolean;
begin
 f:=pg_temp.c2b_fixture();sid:=(f->>'session')::uuid;tenant:=(f->>'tenant')::uuid;t:=(f->>'at')::timestamptz;
 originals:=pg_temp.c2b_originals();
 perform pg_temp.c2b_check(iam.has_well_permission((f->>'well')::uuid,'session.correct'),
  '10 fixture actor actually has server correction permission');
 accepted:=pg_temp.c2b_write(sid,cmd,0,v_reason,t+interval '15 minutes',t+interval '2 hours 30 minutes',requested);
 perform pg_temp.c2b_check(accepted->>'status'='accepted'
  and nullif(accepted->>'correction_id','') is not null
  and accepted->>'session_id'=sid::text and accepted->>'command_id'=cmd::text
  and (accepted->>'previous_revision')::bigint=0 and (accepted->>'operational_revision')::bigint=1
  and (accepted->>'actual_started_at')::timestamptz=t+interval '15 minutes'
  and (accepted->>'actual_ended_at')::timestamptz=t+interval '2 hours 30 minutes'
  and accepted->>'financial_status'='pending','11 public correction accepts full desired pair with pending finance');
 perform pg_temp.c2b_check((select operational_revision=1 from ops.irrigation_sessions where id=sid)
  and (select count(*)=1 from ops.session_corrections where session_id=sid)
  and (select count(*)=1 and bool_and(status='pending' and attempt_count=0)
   from ops.session_correction_reconciliations where session_id=sid)
  and (select actor_id=(f->>'actor')::uuid and request_payload->>'actor_id'=f->>'actor'
   and reason=v_reason and accepted_result=accepted from ops.session_corrections where session_id=sid),
  '12 one revision/history/pending work; actor comes from authenticated identity');
 perform pg_temp.c2b_check(exists(select 1 from sync.processed_commands pc
  join ops.session_corrections h on h.tenant_id=pc.tenant_id and h.command_id=pc.command_id
  where pc.tenant_id=tenant and pc.command_id=cmd and pc.entity_id=sid
   and pc.command_type='correct_irrigation_session' and pc.status='accepted'
   and pc.request_payload=h.request_payload and pc.response_payload=h.accepted_result
   and pc.response_payload=accepted),
  '12a public accepted result is bound to original command type, request, history and durable response');

 before_state:=pg_temp.c2b_state();
 result:=pg_temp.c2b_write(sid,cmd,0,v_reason,t+interval '15 minutes',t+interval '2 hours 30 minutes',requested);
 perform pg_temp.c2b_check(result=accepted and pg_temp.c2b_state()=before_state,'13 exact replay is the original result with zero effects');
 foreach kind in array array['reason','start','end','requested'] loop
  attempt:=pg_temp.c2b_attempt(sid,cmd,0,case when kind='reason' then v_reason||' changed' else v_reason end,
   t+interval '15 minutes'+case when kind='start' then interval '1 second' else interval '0' end,
   t+interval '2 hours 30 minutes'+case when kind='end' then interval '1 second' else interval '0' end,
   requested+case when kind='requested' then interval '1 second' else interval '0' end);
  perform pg_temp.c2b_check(
   (attempt->>'outcome'='raised' and attempt->>'sqlstate'='22023'
     and attempt->>'message'='session_correction_idempotency_conflict')
   or (attempt->>'outcome'='returned' and attempt->'response'->>'status'='conflict'
     and attempt->'response'->>'reason_code'='session_correction_idempotency_conflict'
     and attempt->'response'->'retry_authorized'='false'::jsonb),
   '14 changed payload conflicts under fixed command identity: '||kind);
  perform pg_temp.c2b_check(pg_temp.c2b_state()=before_state,'15 payload conflict has no durable effects: '||kind);
 end loop;

 -- Lost response: deliberately discard the public write return. The oracle for
 -- recovery is the immutable durable history, not a second write invocation.
 perform pg_temp.c2b_write(sid,cmd2,1,'تصحيح لاحق',t+interval '20 minutes',t+interval '2 hours 35 minutes',requested);
 select accepted_result into strict accepted2 from ops.session_corrections
 where tenant_id=tenant and command_id=cmd2 and session_id=sid;
 before_state:=pg_temp.c2b_state();
 result:=pg_temp.c2b_receipt(sid,cmd2);
 perform pg_temp.c2b_check(pg_temp.c2b_accepted_receipt(result,sid,cmd2,accepted2)
  and result->'receipt'->>'correction_id'=accepted2->>'correction_id'
  and (result->'receipt'->>'operational_revision')::bigint=2,
  '16 lost response recovered as the original accepted revision-2 receipt');
 perform pg_temp.c2b_check(pg_temp.c2b_state()=before_state,'17 recovery is read-only; no second correction or work item');
 result:=pg_temp.c2b_write(sid,cmd,0,v_reason,t+interval '15 minutes',t+interval '2 hours 30 minutes',requested);
 perform pg_temp.c2b_check(result=accepted and pg_temp.c2b_state()=before_state,
  '18 exact replay remains valid after a later operational revision');
 result:=pg_temp.c2b_receipt(sid,cmd);
 perform pg_temp.c2b_check(pg_temp.c2b_accepted_receipt(result,sid,cmd,accepted)
  and pg_temp.c2b_state()=before_state,'19 receipt recovers original revision, not current head');

 attempt:=pg_temp.c2b_attempt(sid,stale_cmd,0,'طلب متقادم',t+interval '25 minutes',t+interval '2 hours 40 minutes',requested);
 -- Preserve the published SQLSTATE. The stale_revision identity distinguishes
 -- this business conflict from a transient serialization error; it grants no retry.
 perform pg_temp.c2b_check(attempt->>'outcome'='raised'
  and attempt->>'message'='stale_revision' and attempt->>'sqlstate'='40001',
  '20 stale_revision business conflict preserves SQLSTATE 40001; no blind retry authorization');
 perform pg_temp.c2b_check(pg_temp.c2b_state()=before_state
  and (select operational_revision=2 from ops.irrigation_sessions where id=sid)
  and (select count(*)=2 from ops.session_corrections where session_id=sid)
  and (select count(*)=2 from ops.session_correction_reconciliations where session_id=sid),
  '21 stale write has zero mutation: unchanged revision, correction count, work count and command evidence');
 before_state:=pg_temp.c2b_state();

 result:=pg_temp.c2b_receipt(sid,unknown_cmd);
 perform pg_temp.c2b_check(result->>'status'='not_found' and result->'receipt'='null'::jsonb
  and result->'retry_authorized'='false'::jsonb and pg_temp.c2b_state()=before_state,
  '22 absent receipt never authorizes resend or mutates/reserves the command');
 -- The existing internal contract supplies a rejection KNOWN to roll back.
 -- This fixture does not prohibit a future public contract from persisting an
 -- explicit conflict; it prohibits fabricating a rejection when no row exists.
 denied:=false;
 begin
  perform ops.accept_session_correction(sid,rejected_cmd,2,'  ',
   t+interval '25 minutes',t+interval '2 hours 40 minutes',requested);
 exception when invalid_parameter_value then denied:=true;
 end;
 perform pg_temp.c2b_check(denied
  and not exists(select 1 from sync.processed_commands where tenant_id=tenant and command_id=rejected_cmd),
  '23 invalid correction rolls back its command reservation');
 result:=pg_temp.c2b_receipt(sid,rejected_cmd);
 perform pg_temp.c2b_check(result->>'status'='not_found' and result->'receipt'='null'::jsonb
  and result->'retry_authorized'='false'::jsonb and pg_temp.c2b_state()=before_state,
  '24 recovery does not fabricate a durable rejection from a rolled-back attempt');

 select request_payload into strict request from sync.processed_commands where tenant_id=tenant and command_id=cmd;
 foreach kind in array array['command_type','entity_id','response_payload','command_id',
  'request_missing','response_missing','processing','rejected_without_result'] loop
  begin
   update sync.processed_commands set
    command_type=case when kind='command_type' then 'complete_irrigation_session' else command_type end,
    entity_id=case when kind='entity_id' then gen_random_uuid() else entity_id end,
    command_id=case when kind='command_id' then gen_random_uuid() else command_id end,
    status=case when kind='processing' then 'processing' when kind='rejected_without_result' then 'rejected' else status end,
    request_payload=case when kind='request_missing' then null else request_payload end,
    response_payload=case when kind='response_payload' then jsonb_set(response_payload,'{correction_id}',to_jsonb(gen_random_uuid()))
      when kind in ('response_missing','processing','rejected_without_result') then null else response_payload end
   where tenant_id=tenant and command_id=cmd;
   before_state:=pg_temp.c2b_state();result:=pg_temp.c2b_receipt(sid,cmd);
   perform pg_temp.c2b_check((result->>'status'='unresolved'
     or (kind='processing' and result->>'status'='processing'))
    and result->'receipt'='null'::jsonb and result->'retry_authorized'='false'::jsonb,
    '25 inconsistent command/history/result cannot become accepted: '||kind);
   perform pg_temp.c2b_check(pg_temp.c2b_state()=before_state,'26 recovery never repairs or writes corrupted evidence: '||kind);
   raise exception 'rollback test corruption' using errcode='P0B01';
  exception when sqlstate 'P0B01' then null;
  end;
 end loop;
 foreach key in array array['contract','version','tenant_id','well_id','session_id','actor_id','base_revision',
  'reason','desired_started_at','desired_ended_at','requested_at'] loop
  begin
   update sync.processed_commands set request_payload=jsonb_set(request_payload,array[key],'"tampered"'::jsonb)
   where tenant_id=tenant and command_id=cmd;
   before_state:=pg_temp.c2b_state();result:=pg_temp.c2b_receipt(sid,cmd);
   perform pg_temp.c2b_check(result->>'status'='unresolved' and result->'receipt'='null'::jsonb
    and result->'retry_authorized'='false'::jsonb and pg_temp.c2b_state()=before_state,
    '27 accepted receipt requires exact original request/history binding: '||key);
   raise exception 'rollback test corruption' using errcode='P0B01';
  exception when sqlstate 'P0B01' then null;
  end;
 end loop;

 -- A terminal-looking command result alone does not prove acceptance.
 begin
  insert into sync.processed_commands(tenant_id,command_id,command_type,entity_id,status,request_payload,response_payload)
  values(tenant,orphan_cmd,'correct_irrigation_session',sid,'accepted',request,
   jsonb_set(accepted,'{command_id}',to_jsonb(orphan_cmd)));
  before_state:=pg_temp.c2b_state();result:=pg_temp.c2b_receipt(sid,orphan_cmd);
  perform pg_temp.c2b_check(result->>'status'='unresolved' and result->'receipt'='null'::jsonb
   and result->'retry_authorized'='false'::jsonb and pg_temp.c2b_state()=before_state,
   '28 command row without matching correction history is unresolved');
  raise exception 'rollback orphan fixture' using errcode='P0B01';
 exception when sqlstate 'P0B01' then null;
 end;
 begin
  insert into sync.processed_commands(tenant_id,command_id,command_type,entity_id,status,request_payload,response_payload)
  values(tenant,processing_cmd,'correct_irrigation_session',sid,'processing',request,null);
  before_state:=pg_temp.c2b_state();result:=pg_temp.c2b_receipt(sid,processing_cmd);
  perform pg_temp.c2b_check(result->>'status' in ('processing','unresolved') and result->'receipt'='null'::jsonb
   and result->'retry_authorized'='false'::jsonb and pg_temp.c2b_state()=before_state,
   '29 incomplete processing reservation is neither accepted nor resend authorization');
  raise exception 'rollback processing fixture' using errcode='P0B01';
 exception when sqlstate 'P0B01' then null;
 end;
 perform pg_temp.c2b_check(pg_temp.c2b_originals()=originals,
  '30 writes, exact replays, conflicts and recovery preserve all original operational/financial evidence');
 perform pg_temp.c2b_check((select count(*)=2 from ops.session_corrections where session_id=sid)
  and (select count(*)=2 and bool_and(status='pending' and attempt_count=0)
   from ops.session_correction_reconciliations where session_id=sid)
  and (select operational_revision=2 from ops.irrigation_sessions where id=sid),
  '31 precisely two corrections and pending work items; recovery never applies finance');

 foreign_fixture:=pg_temp.c2b_fixture();
 foreign_result:=pg_temp.c2b_write((foreign_fixture->>'session')::uuid,gen_random_uuid(),0,'تصحيح أجنبي مثبت',
  (foreign_fixture->>'at')::timestamptz+interval '15 minutes',
  (foreign_fixture->>'at')::timestamptz+interval '2 hours 30 minutes',requested);
 perform pg_temp.c2b_check(foreign_result->>'status'='accepted','32 foreign target really has an accepted correction');
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 before_state:=pg_temp.c2b_state();
 attempt:=pg_temp.c2b_attempt((foreign_fixture->>'session')::uuid,gen_random_uuid(),1,'محاولة غير مخولة',
  (foreign_fixture->>'at')::timestamptz+interval '20 minutes',
  (foreign_fixture->>'at')::timestamptz+interval '2 hours 35 minutes',requested);
 perform pg_temp.c2b_check(attempt->>'outcome'='raised' and attempt->>'sqlstate'='42501'
  and pg_temp.c2b_state()=before_state,'33 cross-well correction write is denied without durable effects');
 denied:=false;
 begin
  perform pg_temp.c2b_receipt((foreign_fixture->>'session')::uuid,(foreign_result->>'command_id')::uuid);
 exception when insufficient_privilege then denied:=true;
 end;
 perform pg_temp.c2b_check(denied and pg_temp.c2b_state()=before_state,'34 cross-well accepted receipt is inaccessible');
 denied:=false;
 begin
  execute 'set local role anon';
  perform api.correct_irrigation_session(sid,gen_random_uuid(),2,v_reason,t,t+interval '2 hours',requested);
 exception when insufficient_privilege then denied:=true;
 end;
 execute 'reset role';
 perform pg_temp.c2b_check(denied,'35 anon write is denied even with a leftover authenticated JWT subject');
 denied:=false;
 begin
  execute 'set local role anon';perform api.get_session_correction_receipt(sid,cmd);
 exception when insufficient_privilege then denied:=true;
 end;
 execute 'reset role';
 perform pg_temp.c2b_check(denied and pg_temp.c2b_state()=before_state,'36 anon receipt is denied and cannot mutate evidence');
end;$behavior$;

rollback;
