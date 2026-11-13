\set ON_ERROR_STOP on
-- Owner-run RED gate. No implementation or grants are installed by this test.
begin;
set local timezone='UTC';
create function pg_temp.manual_check(ok boolean,label text) returns void
language plpgsql as $$
begin
 if ok is distinct from true then raise exception 'FAIL %',label;end if;
 raise notice 'PASS %',label;
end;$$;

do $surface$
declare name text; signature text; fn oid;
begin
 perform pg_temp.manual_check(to_regprocedure('ops.manual_session_entry_mode(uuid)') is not null,
  'trusted provenance foundation required before public entry');
 foreach name in array array['record_historical_session','adopt_external_session'] loop
  signature:='api.'||name||'(uuid,uuid,jsonb)';
  fn:=to_regprocedure(signature);
  perform pg_temp.manual_check(fn is not null,'missing general manual entry contract: '||signature);
  perform pg_temp.manual_check((select not prosecdef and prorettype='jsonb'::regtype
    and provolatile='v' and proargnames=array['p_well_id','p_command_id','p_request']::text[]
    from pg_proc where oid=fn),'INVOKER JSON contract without actor/booking authority: '||name);
  perform pg_temp.manual_check(has_function_privilege('authenticated',fn,'EXECUTE')
    and not has_function_privilege('anon',fn,'EXECUTE')
    and not exists(select 1 from pg_proc p,
      lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
      where p.oid=fn and a.grantee=0 and a.privilege_type='EXECUTE'),
    'authenticated-only mutation: '||name);
 end loop;
 fn:=to_regprocedure('api.get_manual_session_entry_receipt(uuid,uuid)');
 perform pg_temp.manual_check(fn is not null,'manual entry receipt exists independently of rejected requests');
 perform pg_temp.manual_check((select not prosecdef and provolatile='s'
   and prorettype='jsonb'::regtype from pg_proc where oid=fn),'receipt is stable INVOKER');
 perform pg_temp.manual_check(has_function_privilege('authenticated',fn,'EXECUTE')
  and not has_function_privilege('anon',fn,'EXECUTE')
  and not exists(select 1 from pg_proc p,
   lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
   where p.oid=fn and a.grantee=0 and a.privilege_type='EXECUTE'),
  'receipt has no anonymous or PUBLIC disclosure');
end;$surface$;

-- Unauthenticated callers must not gain authority from claimed actor metadata.
do $anonymous$
declare name text; denied boolean;result jsonb;
begin
 perform set_config('request.jwt.claim.sub','',true);
 foreach name in array array['record_historical_session','adopt_external_session'] loop
  denied:=false;
  begin
   execute 'set local role anon';
   execute format('select api.%I($1,$2,$3)',name)
     into result using gen_random_uuid(),gen_random_uuid(),jsonb_build_object(
      'version',1,'actor_id',gen_random_uuid(),'reason','manual entry');
  exception when insufficient_privilege or invalid_authorization_specification then denied:=true;
  end;
  execute 'reset role';
  perform pg_temp.manual_check(denied,'anonymous manual entry denied: '||name);
 end loop;
end;$anonymous$;
create function pg_temp.me_fixture() returns jsonb language plpgsql as $$
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
 return jsonb_build_object('tenant',tenant,'actor',actor,'well',well,'pump',pump,'farm',farm,'account',account,'at',started);
end;$$;

create function pg_temp.me_request(f jsonb,active boolean default false) returns jsonb language sql as $$
 select jsonb_build_object('version',1,'pump_id',f->'pump','farm_id',f->'farm',
 'farmer_well_account_id',f->'account','energy_source','solar','reason','إدخال متأخر',
 'notes','ملاحظة محفوظة','started_at',case when active then transaction_timestamp()-interval '1 hour' else (f->>'at')::timestamptz end)
 ||case when active then '{}'::jsonb else jsonb_build_object('ended_at',(f->>'at')::timestamptz+interval '1 hour') end;
$$;
create function pg_temp.me_write(f jsonb,cmd uuid,req jsonb,active boolean default false) returns jsonb language plpgsql as $$
declare r jsonb;
begin
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 execute 'set local role authenticated';
 if active then r:=api.adopt_external_session((f->>'well')::uuid,cmd,req);
 else r:=api.record_historical_session((f->>'well')::uuid,cmd,req);end if;
 execute 'reset role';return r;
exception when others then execute 'reset role';raise;
end;$$;
create function pg_temp.me_read(f jsonb,cmd uuid) returns jsonb language plpgsql as $$
declare r jsonb;
begin
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 execute 'set local role authenticated';
 r:=api.get_manual_session_entry_receipt((f->>'well')::uuid,cmd);
 execute 'reset role';return r;
exception when others then execute 'reset role';raise;
end;$$;
create function pg_temp.me_snapshot() returns jsonb language sql as $$
 select jsonb_build_object(
 'sessions',(select jsonb_agg(to_jsonb(s) order by id) from ops.irrigation_sessions s),
 'segments',(select jsonb_agg(to_jsonb(s) order by id) from ops.session_segments s),
 'charges',(select jsonb_agg(to_jsonb(s) order by id) from billing.session_charges s),
 'occurrences',(select jsonb_agg(to_jsonb(s) order by tenant_id,occurrence_command_id) from ops.operational_occurrences s));
$$;
create temp table me_fail_well(well uuid);
create function pg_temp.me_fail_charge() returns trigger language plpgsql as $$
begin
 if exists(select 1 from me_fail_well where well=new.well_id) then
  raise exception 'test_materialization_failure' using errcode='23514';end if;
 return new;
end;$$;
create trigger me_test_failure after insert on billing.session_charges for each row execute function pg_temp.me_fail_charge();


do $behavior$
declare f jsonb;g jsonb;r jsonb;again jsonb;req jsonb;cmd uuid;sid uuid;active_id uuid;before_state jsonb;
 original_evidence jsonb;bookings jsonb;receipt jsonb;key text;role_name text;denied boolean;t timestamptz;guard jsonb;
begin
 f:=pg_temp.me_fixture();t:=(f->>'at')::timestamptz;
 perform pg_temp.manual_check(not exists(select 1 from ops.operational_occurrences where well_id=(f->>'well')::uuid)
  and not exists(select 1 from ops.irrigation_sessions where well_id=(f->>'well')::uuid),'B01 fresh scope has no app occurrence/session');
 update billing.well_pricing set period_end=t+interval '1 day' where well_id=(f->>'well')::uuid;
 insert into billing.well_pricing(well_id,price_per_hour_minor,period_start)
 values((f->>'well')::uuid,7200,t+interval '1 day');
 insert into ops.price_schedules(tenant_id,well_id,name,effective_period,status,reason,approved_by)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,'Historical tariff',tstzrange(t,t+interval '1 day'),
  'expired','دليل تاريخي',(f->>'actor')::uuid) returning id into sid;
 insert into ops.price_rules(tenant_id,price_schedule_id,energy_source,hourly_rate_minor)
 values((f->>'tenant')::uuid,sid,'solar',4500);

 select jsonb_agg(to_jsonb(b) order by id) into bookings from ops.irrigation_bookings b;
 cmd:=gen_random_uuid();req:=pg_temp.me_request(f);r:=pg_temp.me_write(f,cmd,req);
 perform pg_temp.manual_check(r->>'status'='accepted','B02 completed without booking/rejection/start request');
 sid:=(r->>'session_id')::uuid;
 perform pg_temp.manual_check((select status='closed' and started_at=t and ended_at=t+interval '1 hour'
  and booking_id is null and current_shift_id is null and collector_profile_id is null
  and operator_profile_id=(f->>'actor')::uuid from ops.irrigation_sessions where id=sid),'B03 true closed facts and isolated actor');
 perform pg_temp.manual_check((select count(*)=1 and bool_and(ended_at is not null and started_at<ended_at)
  from ops.session_segments where session_id=sid) and (select count(*)=1 and min(amount_minor)=4500
  from billing.session_charges where session_id=sid),'B04 historical event-time rate, valid segment, one charge');
 perform pg_temp.manual_check((select provenance='manual_historical_completed' and manual_reason=req->>'reason'
  and manual_notes=req->>'notes' and manual_result=r from ops.operational_occurrences where server_session_id=sid),'B05 persisted reason notes provenance result');
 before_state:=pg_temp.me_snapshot();again:=pg_temp.me_write(f,cmd,req);
 perform pg_temp.manual_check(again=r and before_state=pg_temp.me_snapshot(),'B06 exact replay has zero effects');
 again:=pg_temp.me_write(f,cmd,req||jsonb_build_object('notes','changed'));
 perform pg_temp.manual_check(again->>'status'='validation_error' and before_state=pg_temp.me_snapshot(),'B07 changed-payload replay conflict');
 receipt:=pg_temp.me_read(f,cmd);
 perform pg_temp.manual_check(receipt->>'status'='accepted' and receipt->'result'=r
  and receipt->'retry_authorized'='false'::jsonb and before_state=pg_temp.me_snapshot(),'B08 lost response receipt exact and read-only');
 foreach key in array array['booking_id','actor_id','source_booking_id','amount_minor','events'] loop
  again:=pg_temp.me_write(f,gen_random_uuid(),req||jsonb_build_object(key,'unsupported'));
  perform pg_temp.manual_check(again->>'status'='validation_error' and before_state=pg_temp.me_snapshot(),'B09 unsupported authority rejected: '||key);
 end loop;
 again:=pg_temp.me_write(f,gen_random_uuid(),req||jsonb_build_object('reason',' '));
 perform pg_temp.manual_check(again->>'status'='validation_error','B10 reason mandatory');
 again:=pg_temp.me_write(f,gen_random_uuid(),req||jsonb_build_object('ended_at',t));
 perform pg_temp.manual_check(again->>'status'='validation_error','B11 end strictly after start');
 again:=pg_temp.me_write(f,gen_random_uuid(),req||jsonb_build_object('ended_at',transaction_timestamp()+interval '1 hour'));
 perform pg_temp.manual_check(again->>'status'='validation_error','B12 future end invalid');
 again:=pg_temp.me_write(f,gen_random_uuid(),req);
 perform pg_temp.manual_check(again->>'status'='conflict_overlap' and before_state=pg_temp.me_snapshot(),'B13 overlapping different request atomic conflict');
 -- No product age cutoff; only actual historical price evidence matters.
 g:=pg_temp.me_fixture();req:=pg_temp.me_request(g)||jsonb_build_object('started_at','2000-01-01T08:00:00Z','ended_at','2000-01-01T09:00:00Z');
 again:=pg_temp.me_write(g,gen_random_uuid(),req-'notes');
 perform pg_temp.manual_check(again->>'status'='accepted','B14 old valid date and optional notes');
 g:=pg_temp.me_fixture();delete from billing.well_pricing where well_id=(g->>'well')::uuid;
 insert into billing.well_pricing(well_id,price_per_hour_minor,period_start)
 values((g->>'well')::uuid,99999,transaction_timestamp());
 cmd:=gen_random_uuid();before_state:=pg_temp.me_snapshot();again:=pg_temp.me_write(g,cmd,pg_temp.me_request(g));
 perform pg_temp.manual_check(pg_temp.me_read(g,cmd)->'result'=again,'B15a review outcome recoverable by receipt');
 perform pg_temp.manual_check(again->>'status'='needs_review' and before_state=pg_temp.me_snapshot(),'B15 no current-tariff fallback or partial facts');
 g:=pg_temp.me_fixture();insert into me_fail_well values((g->>'well')::uuid);
 before_state:=pg_temp.me_snapshot();again:=pg_temp.me_write(g,gen_random_uuid(),pg_temp.me_request(g));
 perform pg_temp.manual_check(again->>'status'='unresolved' and before_state=pg_temp.me_snapshot(),'B16 failure after charge insertion rolls back whole materialization');
 delete from me_fail_well;
 -- Existing detail and correction contracts target the canonical session.
 perform set_config('request.jwt.claim.sub',f->>'actor',true);execute 'set local role authenticated';
 again:=api.get_session_detail(sid);
 perform pg_temp.manual_check(again->'session'->>'id'=sid::text and (again->'session'->>'can_correct_session')::boolean,'B17 readable/correctable canonical detail');
 execute 'reset role';select to_jsonb(o) into original_evidence from ops.operational_occurrences o where server_session_id=sid;
 execute 'set local role authenticated';
 again:=api.correct_irrigation_session(sid,gen_random_uuid(),0,'تصحيح لاحق',t,t+interval '50 minutes',transaction_timestamp());
 execute 'reset role';
 perform pg_temp.manual_check(again->>'status'='accepted' and original_evidence=(select to_jsonb(o) from ops.operational_occurrences o where server_session_id=sid),'B18 later correction preserves original manual history');
 -- Active case on a fresh well, with a real booking that must remain irrelevant.
 g:=pg_temp.me_fixture();req:=pg_temp.me_request(g,true);cmd:=gen_random_uuid();
 insert into ops.irrigation_bookings(tenant_id,public_code,well_id,farmer_well_account_id,farm_id,
  scheduled_start,scheduled_end,expected_duration_minutes,expected_energy_source,status,created_by)
 values((g->>'tenant')::uuid,'ME-'||substr(g->>'well',1,8),(g->>'well')::uuid,(g->>'account')::uuid,
  (g->>'farm')::uuid,transaction_timestamp(),transaction_timestamp()+interval '1 hour',60,'solar','confirmed',(g->>'actor')::uuid);
 select jsonb_agg(to_jsonb(b) order by id) into bookings from ops.irrigation_bookings b;
 r:=pg_temp.me_write(g,cmd,req,true);active_id:=(r->>'session_id')::uuid;
 perform pg_temp.manual_check(r->>'status'='accepted' and (select status='open' and booking_id is null
  and current_shift_id is null and collector_profile_id is null and started_at=(req->>'started_at')::timestamptz
  from ops.irrigation_sessions where id=active_id),'B19 external active true facts isolated');
 perform pg_temp.manual_check((select count(*)=1 and bool_and(ended_at is null
  and started_at=(req->>'started_at')::timestamptz and applied_hourly_rate_minor=3600)
  from ops.session_segments where session_id=active_id),'B20 one initial open segment with event-time price');
 before_state:=pg_temp.me_snapshot();again:=pg_temp.me_write(g,cmd,req,true);
 perform pg_temp.manual_check(again=r and before_state=pg_temp.me_snapshot(),'B21 active replay no second start');
 again:=pg_temp.me_write(g,cmd,req||jsonb_build_object('reason','changed'),true);
 perform pg_temp.manual_check(again->>'status'='validation_error','B22 active payload conflict');
 again:=pg_temp.me_write(g,gen_random_uuid(),req,true);
 perform pg_temp.manual_check(again->>'status'='conflict_active_resource' and before_state=pg_temp.me_snapshot(),'B23 active conflict never adopts/overwrites');
 again:=pg_temp.me_write(g,gen_random_uuid(),req||jsonb_build_object('started_at',transaction_timestamp()+interval '1 hour'),true);
 perform pg_temp.manual_check(again->>'status'='validation_error','B24 active future start invalid');
 perform pg_temp.manual_check(pg_temp.me_read(g,cmd)->'result'=r,'B25 active lost response receipt');
 select to_jsonb(s) into original_evidence from ops.irrigation_sessions s where id=active_id;
 again:=pg_temp.me_write(g,gen_random_uuid(),pg_temp.me_request(g));
 perform pg_temp.manual_check(again->>'status'='accepted' and original_evidence=(select to_jsonb(s) from ops.irrigation_sessions s where id=active_id),
  'B25a nonoverlapping completed history leaves current resource untouched');
 perform set_config('request.jwt.claim.sub',g->>'actor',true);execute 'set local role authenticated';
 perform api.pause_irrigation_session(active_id,'operator_pause',transaction_timestamp()-interval '45 minutes',gen_random_uuid());
 perform api.resume_irrigation_session(active_id,transaction_timestamp()-interval '30 minutes',gen_random_uuid());
 perform api.change_session_energy_source(active_id,'well_diesel',transaction_timestamp()-interval '15 minutes',null,null,null,gen_random_uuid());
 again:=api.complete_irrigation_session(active_id,transaction_timestamp(),null,null,null,gen_random_uuid());
 execute 'reset role';
 perform pg_temp.manual_check(again->>'status'='closed' and (select count(*)=1 from billing.session_charges where session_id=active_id)
  and ops.manual_session_entry_mode(active_id)='manual_external_active','B26 normal active actions and one completion charge');
 perform pg_temp.manual_check(pg_temp.me_read(g,cmd)->'result'=r,'B27 receipt remains original active acceptance after completion');
 perform pg_temp.manual_check(bookings=(select jsonb_agg(to_jsonb(b) order by id) from ops.irrigation_bookings b),'B28 booking records unchanged');
 -- Persisted processing reservations are read, never executed by receipt lookup.
 cmd:=gen_random_uuid();select request_payload into req from sync.processed_commands where tenant_id=(g->>'tenant')::uuid and command_id=(r->>'command_id')::uuid;
 perform sync.begin_command((g->>'tenant')::uuid,cmd,'manual_session_entry',req,(g->>'well')::uuid);
 before_state:=pg_temp.me_snapshot();again:=pg_temp.me_read(g,cmd);
 perform pg_temp.manual_check(again->>'status'='processing' and before_state=pg_temp.me_snapshot(),'B29 processing read has no materialization');
 again:=pg_temp.me_write(g,cmd,pg_temp.me_request(g,true),true);
 perform pg_temp.manual_check(again->>'status'='processing' and before_state=pg_temp.me_snapshot(),'B29a processing duplicate never starts again');
 insert into core.well_assignments(well_id,profile_id,role,status) values((f->>'well')::uuid,(g->>'actor')::uuid,'operator','active');
 again:=pg_temp.me_read(g||jsonb_build_object('well',f->'well'),(r->>'command_id')::uuid);
 perform pg_temp.manual_check(again->>'status'='not_found','B29b wrong tenant/well does not disclose receipt');
 denied:=false;begin perform pg_temp.me_read(f||jsonb_build_object('well',g->'well'),(r->>'command_id')::uuid);
 exception when insufficient_privilege then denied:=true;end;
 perform pg_temp.manual_check(denied,'B29c scope authorization precedes disclosure');
 begin
  update sync.processed_commands set response_payload=jsonb_set(response_payload,'{session_id}',to_jsonb(gen_random_uuid()))
   where tenant_id=(g->>'tenant')::uuid and command_id=(r->>'command_id')::uuid;
  again:=pg_temp.me_read(g,(r->>'command_id')::uuid);
  perform pg_temp.manual_check(again->>'status'='unresolved' and again->'result'='null'::jsonb,'B29d contradictory accepted proof fails closed');
  raise exception 'rollback malformed owner fixture' using errcode='ZX001';
 exception when sqlstate 'ZX001' then null;end;
 again:=pg_temp.me_read(g,gen_random_uuid());
 perform pg_temp.manual_check(again->>'status'='not_found' and again->'retry_authorized'='false'::jsonb,'B30 absence grants no retry');
 foreach role_name in array array['operator','manager','owner'] loop
  update core.well_assignments set role=role_name where well_id=(g->>'well')::uuid and profile_id=(g->>'actor')::uuid;
  perform set_config('request.jwt.claim.sub',g->>'actor',true);
  perform pg_temp.manual_check(iam.has_well_permission((g->>'well')::uuid,'session.manual_entry'),'B31 manual capability role: '||role_name);
 end loop;
 update core.well_assignments set role='operator' where well_id=(g->>'well')::uuid and profile_id=(g->>'actor')::uuid;
 delete from iam.role_permissions where permission_id=(select id from iam.permissions where code='session.manual_entry')
  and role_id=(select id from iam.roles where code='operator');
 denied:=false;begin perform pg_temp.me_write(g,gen_random_uuid(),pg_temp.me_request(g));exception when insufficient_privilege then denied:=true;end;
 perform pg_temp.manual_check(denied,'B32 manual permission independent of correction/start');
 foreach role_name in array array['manager','owner'] loop
  g:=pg_temp.me_fixture();
  update core.well_assignments set role=role_name where well_id=(g->>'well')::uuid and profile_id=(g->>'actor')::uuid;
  again:=pg_temp.me_write(g,gen_random_uuid(),pg_temp.me_request(g));
  perform pg_temp.manual_check(again->>'status'='accepted','B33 actual manual entry role: '||role_name);
  execute 'set local role authenticated';receipt:=api.get_manual_session_entry_capability((g->>'well')::uuid);execute 'reset role';
  perform pg_temp.manual_check(receipt->'can_record_historical_session'='true'::jsonb
   and receipt->'can_adopt_external_session'='true'::jsonb,'B34 readable capability role: '||role_name);
 end loop;

end;$behavior$;
rollback;
