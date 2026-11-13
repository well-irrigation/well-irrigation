\set ON_ERROR_STOP on
-- Private provenance foundation only. Full public APIs remain a separate RED gate.
begin;
set local timezone='UTC';
create function pg_temp.pm_check(ok boolean,label text) returns void language plpgsql as $$
begin
 if ok is distinct from true then raise exception 'FAIL %',label;end if;
 raise notice 'PASS %',label;
end;$$;
do $surface$
begin
 perform pg_temp.pm_check(to_regprocedure('ops.manual_session_entry_mode(uuid)') is not null,
  '01 trusted manual provenance helper exists');
 perform pg_temp.pm_check(to_regprocedure('ops.begin_terminal_occurrence_materialization(uuid,jsonb)') is not null,
  '02 shared terminal insertion core exists without rejected/completion request arguments');
end;$surface$;
create function pg_temp.pm_fixture() returns jsonb language plpgsql as $$
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
  'start_command',start_command,'end_command',end_command,'charge',completion->'session_charge_id','pump',pump,'farm',farm,'account',account);
exception when others then execute 'reset role';raise;
end;$$;


-- Owner fixture simulates a future trusted wrapper; no production test hook.
create function pg_temp.pm_seed(f jsonb,mode text,at_time timestamptz,end_time timestamptz,
 why text default 'سجل متأخر',note text default 'ملاحظة اختبار') returns uuid language plpgsql as $$
declare cmd uuid:=gen_random_uuid();sid uuid:=gen_random_uuid();facts jsonb;req jsonb;
begin
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 perform billing.enter_financial_write((f->>'well')::uuid,'session.start',null);
 facts:=jsonb_build_object('start',jsonb_build_object('pump_id',f->'pump','farm_id',f->'farm',
  'farmer_well_account_id',f->'account','energy_source','solar','crops','[]'::jsonb));
 req:=jsonb_build_object('contract','manual_session_entry','version',1,'tenant_id',f->'tenant',
  'well_id',f->'well','actor_id',auth.uid(),'entry_type',mode,'reason',why,'notes',note,
  'started_at',to_char(at_time at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
  'ended_at',case when end_time is not null then to_char(end_time at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') end,
  'facts',facts);
 perform sync.begin_command((f->>'tenant')::uuid,cmd,'manual_session_entry',req,(f->>'well')::uuid);
 insert into ops.operational_occurrences(tenant_id,occurrence_command_id,well_id,original_request_id,
  original_operator_id,started_at,ended_at,original_facts,provenance,server_session_id,status,manual_reason,manual_notes)
 values((f->>'tenant')::uuid,cmd,(f->>'well')::uuid,cmd,auth.uid(),at_time,end_time,facts,mode,sid,'materializing',why,note);
 return sid;
end;$$;
create function pg_temp.pm_accept(sid uuid) returns jsonb language plpgsql as $$
declare o ops.operational_occurrences%rowtype;r jsonb;
begin
 select * into strict o from ops.operational_occurrences where server_session_id=sid;
 r:=ops.manual_session_entry_result(sid);
 perform sync.finish_command(o.tenant_id,o.occurrence_command_id,'accepted',r);
 update ops.operational_occurrences set status='accepted',resolved_at=clock_timestamp(),manual_result=r
 where tenant_id=o.tenant_id and occurrence_command_id=o.occurrence_command_id;
 return r;
end;$$;

do $guards$
declare f jsonb;sid uuid;active_id uuid;seg uuid;r jsonb;t timestamptz;denied boolean;
 cmd uuid;before_bookings jsonb;mode text;row_snapshot jsonb;legacy uuid;legacy_cmd uuid;completion uuid;facts jsonb;actual_shift uuid;fuel_sid uuid;ordinary_active uuid;
begin
 f:=pg_temp.pm_fixture();t:=(f->>'at')::timestamptz;
 perform pg_temp.pm_check((select current_shift_id is not null and collector_profile_id is not null
  from ops.irrigation_sessions where id=(f->>'session')::uuid),'03 normal start retains shift and collector');
 perform pg_temp.pm_check((select count(*)=1 from billing.session_charges where session_id=(f->>'session')::uuid),
  '04 normal completion retains one canonical charge');
 insert into ops.irrigation_bookings(tenant_id,public_code,well_id,farmer_well_account_id,farm_id,
  scheduled_start,scheduled_end,expected_duration_minutes,expected_energy_source,status,created_by)
 values((f->>'tenant')::uuid,'PM-'||substr(f->>'well',1,8),(f->>'well')::uuid,(f->>'account')::uuid,
  (f->>'farm')::uuid,t-interval '23 hours 30 minutes',t-interval '22 hours 30 minutes',60,'solar','confirmed',(f->>'actor')::uuid);
 insert into ops.irrigation_bookings(tenant_id,public_code,well_id,farmer_well_account_id,farm_id,
  scheduled_start,scheduled_end,expected_duration_minutes,expected_energy_source,status,created_by)
 values((f->>'tenant')::uuid,'PM-F-'||substr(f->>'well',1,8),(f->>'well')::uuid,(f->>'account')::uuid,
  (f->>'farm')::uuid,transaction_timestamp()+interval '1 hour',transaction_timestamp()+interval '2 hours',
  60,'solar','confirmed',auth.uid());
 select jsonb_agg(to_jsonb(b) order by id) into before_bookings from ops.irrigation_bookings b;
 -- A client flag never turns an ordinary row into a trusted manual occurrence.
 perform set_config('manual.entry_type','manual_historical_completed',true);
 denied:=false;
 begin
  insert into ops.irrigation_sessions(well_id,pump_id,farm_id,farmer_well_account_id,operator_profile_id,started_at,ended_at,status)
  values((f->>'well')::uuid,(f->>'pump')::uuid,(f->>'farm')::uuid,(f->>'account')::uuid,
   (f->>'actor')::uuid,t-interval '24 hours',t-interval '23 hours','closed');
  set constraints ops.irrigation_sessions_adhoc_duration_guard immediate;
 exception when check_violation then denied:=true;
 end;
 perform pg_temp.pm_check(denied,'05 ordinary booking guard is not bypassed by a client flag');
 perform set_config('manual.entry_type','',true);
 ordinary_active:=api.start_operational_session((f->>'well')::uuid,(f->>'pump')::uuid,(f->>'farm')::uuid,
  (f->>'account')::uuid,'solar',t+interval '3 hours',gen_random_uuid());
 select to_jsonb(s) into row_snapshot from ops.irrigation_sessions s where id=ordinary_active;
 sid:=pg_temp.pm_seed(f,'manual_historical_completed',t-interval '24 hours',t-interval '23 hours');
 perform pg_temp.pm_check(ops.manual_session_entry_mode(sid)='manual_historical_completed','06 processing proof recognized');
 seg:=ops.begin_terminal_occurrence_materialization(sid);
 update ops.session_segments set ended_at=t-interval '23 hours' where id=seg;
 r:=ops.finalize_session_from_closed_segments(sid,t-interval '23 hours');
 r:=pg_temp.pm_accept(sid);
 set constraints ops.manual_session_entry_resolved,ops.irrigation_sessions_adhoc_duration_guard immediate;
 set constraints ops.manual_session_entry_resolved,ops.irrigation_sessions_adhoc_duration_guard deferred;
 perform pg_temp.pm_check((select status='closed' and booking_id is null and current_shift_id is null
  and collector_profile_id is null from ops.irrigation_sessions where id=sid),'07 manual completed isolation');
 perform pg_temp.pm_check((select count(*)=1 from billing.session_charges where session_id=sid),'08 shared financial finalization');
 perform pg_temp.pm_check((select manual_reason='سجل متأخر' and manual_notes='ملاحظة اختبار' and manual_result=r
  and original_operator_id=auth.uid() from ops.operational_occurrences where server_session_id=sid),'09 immutable admission evidence');
 denied:=false;
 begin
  perform pg_temp.pm_seed(f,'manual_historical_completed',t-interval '25 hours',t-interval '24 hours',' ');
 exception when check_violation then denied:=true;end;
 perform pg_temp.pm_check(denied,'10 mandatory reason cannot be omitted');
 -- A completed manual interval must not bypass overlap with ordinary execution.
 denied:=false;
 begin
  legacy:=pg_temp.pm_seed(f,'manual_historical_completed',t,t+interval '1 hour');
  perform ops.begin_terminal_occurrence_materialization(legacy);
 exception when check_violation then denied:=true;end;
 perform pg_temp.pm_check(denied,'11 manual provenance cannot bypass actual overlap');
 perform pg_temp.pm_check(row_snapshot=(select to_jsonb(s) from ops.irrigation_sessions s where id=ordinary_active),
  '11a historical materialization leaves the current open resource untouched');
 perform api.complete_irrigation_session(ordinary_active,t+interval '4 hours',null,null,null,gen_random_uuid());
 -- Same helper and guard path supports a genuine external OPEN session.
 active_id:=pg_temp.pm_seed(f,'manual_external_active',transaction_timestamp()-interval '1 hour',null);
 insert into ops.irrigation_sessions(id,well_id,pump_id,farm_id,farmer_well_account_id,operator_profile_id,
  started_at,status,current_shift_id,collector_profile_id)
 values(active_id,(f->>'well')::uuid,(f->>'pump')::uuid,(f->>'farm')::uuid,(f->>'account')::uuid,
  auth.uid(),transaction_timestamp()-interval '1 hour','open',
  (select current_shift_id from ops.irrigation_sessions where id=(f->>'session')::uuid),auth.uid());
 seg:=ops.create_priced_session_segment(active_id,'solar',transaction_timestamp()-interval '1 hour',null);
 r:=pg_temp.pm_accept(active_id);
 set constraints ops.manual_session_entry_resolved,ops.irrigation_sessions_adhoc_duration_guard immediate;
 set constraints ops.manual_session_entry_resolved,ops.irrigation_sessions_adhoc_duration_guard deferred;
 perform pg_temp.pm_check((select status='open' and current_shift_id is null and collector_profile_id is null
  and booking_id is null from ops.irrigation_sessions where id=active_id),'12 active manual shift/collector isolation');
 perform pg_temp.pm_check((select started_at=transaction_timestamp()-interval '1 hour'
  and coalesce(applied_operation_rate_minor,applied_hourly_rate_minor)=3600 from ops.session_segments where id=seg),'13 true start and event-time price retained');
 select to_jsonb(s) into row_snapshot from ops.irrigation_sessions s where id=active_id;
 denied:=false;
 begin
  legacy:=pg_temp.pm_seed(f,'manual_historical_completed',transaction_timestamp()-interval '30 minutes',transaction_timestamp()-interval '1 minute');
  perform ops.begin_terminal_occurrence_materialization(legacy);
 exception when check_violation then denied:=true;end;
 perform pg_temp.pm_check(denied and row_snapshot=(select to_jsonb(s) from ops.irrigation_sessions s where id=active_id),
  '14 open resource conflict leaves current session unchanged');

 denied:=false;
 begin
  legacy:=pg_temp.pm_seed(f,'manual_external_active',transaction_timestamp()-interval '30 minutes',null);
  insert into ops.irrigation_sessions(id,well_id,pump_id,farm_id,farmer_well_account_id,operator_profile_id,started_at,status)
  values(legacy,(f->>'well')::uuid,(f->>'pump')::uuid,(f->>'farm')::uuid,(f->>'account')::uuid,
   auth.uid(),transaction_timestamp()-interval '30 minutes','open');
 exception when raise_exception then
  denied:=SQLERRM like 'لا يمكن فتح جلسة جديدة: المضخة مشغولة%';
 end;
 perform pg_temp.pm_check(denied and row_snapshot=(select to_jsonb(s) from ops.irrigation_sessions s where id=active_id),
  '14a second active entry never overwrites/adopts the existing resource');
 r:=api.complete_irrigation_session(active_id,transaction_timestamp(),null,null,null,gen_random_uuid());
 perform pg_temp.pm_check(r->>'status'='closed' and ops.manual_session_entry_mode(active_id)='manual_external_active',
  '15 later normal completion preserves immutable manual provenance');
 perform pg_temp.pm_check(before_bookings=(select jsonb_agg(to_jsonb(b) order by id) from ops.irrigation_bookings b),
  '16 no booking consumption or schedule mutation');
 -- Private admission cannot be forged by authenticated callers (or service_role).
 foreach mode in array array['authenticated','anon','service_role'] loop
  perform pg_temp.pm_check(not has_table_privilege(mode,'ops.operational_occurrences','INSERT,UPDATE,DELETE'),
   '17 no direct provenance writes: '||mode);
  perform pg_temp.pm_check(not has_function_privilege(mode,'ops.manual_session_entry_mode(uuid)','EXECUTE')
   and not has_function_privilege(mode,'ops.begin_terminal_occurrence_materialization(uuid,jsonb)','EXECUTE'),
   '18 private helpers cannot be called by client role: '||mode);
 end loop;
 denied:=false;
 begin
  update ops.operational_occurrences set manual_notes='rewrite' where server_session_id=sid;
 exception when check_violation then denied:=true;end;
 perform pg_temp.pm_check(denied,'19 accepted metadata immutable');

 denied:=false;
 begin
  insert into ops.irrigation_sessions(well_id,pump_id,farm_id,farmer_well_account_id,operator_profile_id,started_at,ended_at,status)
  values((f->>'well')::uuid,(f->>'pump')::uuid,(f->>'farm')::uuid,(f->>'account')::uuid,auth.uid(),
    t-interval '24 hours',t-interval '23 hours','closed');
 exception when check_violation then denied:=SQLERRM='manual_entry_resource_overlap';end;
 perform pg_temp.pm_check(denied,'19a later ordinary write cannot overlap an accepted manual session');
 -- Unresolved private admission may not survive a commit.
 denied:=false;
 begin
  legacy:=pg_temp.pm_seed(f,'manual_historical_completed',t-interval '48 hours',t-interval '47 hours');
  set constraints ops.manual_session_entry_resolved immediate;
 exception when check_violation then denied:=true;end;
 perform pg_temp.pm_check(denied,'20 unresolved admission cannot be committed');

 -- Legacy settlement still follows its existing wrapper and completion identity.
 legacy:=gen_random_uuid();legacy_cmd:=gen_random_uuid();completion:=gen_random_uuid();cmd:=gen_random_uuid();
 facts:=jsonb_build_object('root_local_id','legacy-root','start',jsonb_build_object(
  'pump_id',f->'pump','farm_id',f->'farm','farmer_well_account_id',f->'account',
  'energy_source','solar','started_at',t-interval '72 hours','crops','[]'::jsonb),
  'events','[]'::jsonb,'completion',jsonb_build_object('command_id',completion,
  'occurred_at',t-interval '71 hours','payload',jsonb_build_object('p_session_id',
    jsonb_build_object('$ref','legacy-root','$kind','session'))));
 perform sync.begin_command((f->>'tenant')::uuid,legacy_cmd,'settle_operational_occurrence',
  jsonb_build_object('actor_id',auth.uid()),(f->>'well')::uuid);
 insert into ops.operational_occurrences(tenant_id,occurrence_command_id,well_id,original_request_id,
  original_operator_id,started_at,ended_at,original_facts,provenance,settlement_command_id,
  completion_command_id,server_session_id,status)
 values((f->>'tenant')::uuid,cmd,(f->>'well')::uuid,gen_random_uuid(),auth.uid(),
  t-interval '72 hours',t-interval '71 hours',facts,'historical_settlement',legacy_cmd,completion,legacy,'materializing');
 r:=ops.materialize_historical_occurrence((f->>'well')::uuid,cmd,legacy_cmd,facts);
 perform sync.finish_command((f->>'tenant')::uuid,legacy_cmd,'accepted',jsonb_build_object('server_session_id',legacy));
 update ops.operational_occurrences set status='accepted',resolved_at=clock_timestamp()
 where server_session_id=legacy;
 set constraints ops.irrigation_sessions_adhoc_duration_guard immediate;
 set constraints ops.irrigation_sessions_adhoc_duration_guard deferred;
 perform pg_temp.pm_check(r->>'status'='closed' and (select current_shift_id is null
  and collector_profile_id is null from ops.irrigation_sessions where id=legacy),
  '21 legacy materializer retains closed state and shift isolation');
 perform pg_temp.pm_check(ops.manual_session_entry_mode(legacy) is null,'22 legacy remains separately recognizable');
 -- Exercise the real fuel fill trigger without posting artificial stock/finance.
 foreach fuel_sid in array array[(f->>'session')::uuid,sid,active_id,legacy] loop
  insert into inventory.fuel_transactions(tenant_id,well_id,transaction_type,ownership_type,
    quantity_ml,direction,status,session_segment_id,occurred_at)
  values((f->>'tenant')::uuid,(f->>'well')::uuid,'session_consumption','well',1000,'out','draft',
    (select id from ops.session_segments where session_id=fuel_sid order by sequence_number limit 1),t)
  returning shift_id into actual_shift;
  perform pg_temp.pm_check((actual_shift is null)=(fuel_sid<>(f->>'session')::uuid),
   '23 fuel shift assignment matches trusted origin: '||fuel_sid);
 end loop;
 denied:=false;
 begin
  insert into inventory.fuel_transactions(tenant_id,well_id,transaction_type,ownership_type,
   quantity_ml,direction,status,session_segment_id)
  values((f->>'tenant')::uuid,(f->>'well')::uuid,'session_consumption','farmer',1000,'out','draft',
   (select id from ops.session_segments where session_id=sid limit 1));
 exception when check_violation then denied:=true;end;
 perform pg_temp.pm_check(denied,'24 manual provenance does not invent fuel ownership');


 denied:=false;
 begin
  insert into ops.operational_occurrences(tenant_id,occurrence_command_id,well_id,original_request_id,
   original_operator_id,started_at,ended_at,original_facts,provenance,server_session_id,status,manual_reason)
  values((f->>'tenant')::uuid,gen_random_uuid(),(f->>'well')::uuid,gen_random_uuid(),auth.uid(),
   t-interval '100 hours',t-interval '99 hours','{}','manual_historical_completed',gen_random_uuid(),'materializing','forged');
 exception when check_violation then denied:=true;end;
 perform pg_temp.pm_check(denied,'25 occurrence without exact private reservation cannot forge manual proof');
 denied:=false;
 begin
  execute 'set local role authenticated';
  insert into ops.operational_occurrences default values;
 exception when insufficient_privilege then denied:=true;end;
 execute 'reset role';
 perform pg_temp.pm_check(denied,'26 authenticated caller cannot write provenance');
 denied:=false;
 begin
  insert into ops.operational_occurrences(tenant_id,occurrence_command_id,well_id,original_request_id,
   original_operator_id,started_at,ended_at,original_facts,provenance,server_session_id,status,manual_reason)
  values((f->>'tenant')::uuid,gen_random_uuid(),(f->>'well')::uuid,gen_random_uuid(),gen_random_uuid(),
   t-interval '100 hours',t-interval '99 hours','{}','manual_historical_completed',gen_random_uuid(),'materializing','forged actor');
 exception when insufficient_privilege then denied:=true;end;
 perform pg_temp.pm_check(denied,'27 admission cannot claim another authenticated actor');


end;$guards$;
rollback;
