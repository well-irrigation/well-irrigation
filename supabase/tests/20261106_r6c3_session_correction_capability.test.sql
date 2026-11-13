\set ON_ERROR_STOP on
-- OWNER ONLY: disposable local DB. Independent fixtures; no migration changes.
begin;
set local timezone='UTC';
set local row_security=on;

create function pg_temp.r6c3_check(ok boolean,label text) returns void
language plpgsql as $$
begin
 if ok is distinct from true then raise exception 'FAIL %',label;end if;
 raise notice 'PASS %',label;
end;$$;

create function pg_temp.r6c3_fixture(completed boolean default true) returns jsonb
language plpgsql as $$
declare tenant uuid;well uuid;actor uuid:=gen_random_uuid();person uuid;
 farmer uuid;account uuid;farm uuid;pump uuid;sid uuid;
 at_time timestamptz:=date_trunc('day',transaction_timestamp())-interval '3 days'+interval '8 hours';
begin
 insert into core.tenants(name) values('R6C3 capability') returning id into tenant;
 insert into auth.users(id,instance_id,aud,role,email,email_confirmed_at,created_at,updated_at)
 values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
  actor||'@r6c3.test',now(),now(),now());
 insert into iam.profiles(id,full_name) values(actor,'R6C3 operator') on conflict(id) do nothing;
 insert into core.wells(tenant_id,name) values(tenant,'R6C3 well') returning id into well;
 insert into core.well_assignments(well_id,profile_id,role,status)
 values(well,actor,'operator','active');
 insert into core.persons(tenant_id,full_name,normalized_name)
 values(tenant,'R6C3 farmer','R6C3 farmer') returning id into person;
 insert into ops.farmer_profiles(tenant_id,person_id) values(tenant,person) returning id into farmer;
 insert into ops.farmer_well_accounts(tenant_id,farmer_profile_id,well_id,public_code)
 values(tenant,farmer,well,'R6C3-'||substr(actor::text,1,8)) returning id into account;
 insert into ops.farms(well_id,name,farmer_well_account_id)
 values(well,'R6C3 farm',account) returning id into farm;
 insert into core.pumps(well_id,name,power_source,status)
 values(well,'R6C3 pump','diesel','active') returning id into pump;
 insert into billing.well_pricing(well_id,price_per_hour_minor,period_start)
 values(well,3600,date '1970-01-01');
 insert into ops.shifts(tenant_id,well_id,operator_profile_id,started_at,status)
 values(tenant,well,actor,at_time-interval '1 hour','open');
 perform set_config('request.jwt.claim.sub',actor::text,true);
 execute 'set local role authenticated';
 sid:=api.start_operational_session(well,pump,farm,account,'solar',at_time,gen_random_uuid());
 if completed then
  perform api.complete_irrigation_session(sid,at_time+interval '2 hours',null,null,null,gen_random_uuid());
 end if;
 execute 'reset role';
 return jsonb_build_object('tenant',tenant,'well',well,'actor',actor,'session',sid,
  'pump',pump,'farm',farm,'account',account,'at',at_time);
exception when others then execute 'reset role';raise;
end;$$;

create function pg_temp.r6c3_detail(sid uuid) returns jsonb language plpgsql as $$
declare result jsonb;
begin
 execute 'set local role authenticated';
 result:=api.get_session_detail(sid);
 execute 'reset role';return result;
exception when others then execute 'reset role';raise;
end;$$;

create function pg_temp.r6c3_detail_error(sid uuid) returns text language plpgsql as $$
begin
 perform pg_temp.r6c3_detail(sid);return null;
exception when others then return SQLSTATE;
end;$$;

create function pg_temp.r6c3_permission(well uuid) returns boolean language plpgsql as $$
declare allowed boolean;
begin
 execute 'set local role authenticated';
 allowed:=iam.has_well_permission(well,'session.correct');
 execute 'reset role';return allowed;
exception when others then execute 'reset role';raise;
end;$$;

create function pg_temp.r6c3_accept(f jsonb) returns jsonb language plpgsql as $$
declare result jsonb;t timestamptz:=(f->>'at')::timestamptz;
begin
 execute 'set local role authenticated';
 result:=ops.accept_session_correction((f->>'session')::uuid,gen_random_uuid(),0,
  'Capability authorization proof',t+interval '15 minutes',t+interval '150 minutes',
  transaction_timestamp());
 execute 'reset role';return result;
exception when others then execute 'reset role';raise;
end;$$;

create function pg_temp.r6c3_accept_error(f jsonb) returns text language plpgsql as $$
begin
 perform pg_temp.r6c3_accept(f);return null;
exception when others then return SQLERRM;
end;$$;

create function pg_temp.r6c3_flags(detail jsonb,read_allowed boolean,correct_allowed boolean,label text)
returns void language plpgsql as $$
begin
 perform pg_temp.r6c3_check(
  jsonb_typeof(detail->'session'->'can_read_session_corrections')='boolean'
  and jsonb_typeof(detail->'session'->'can_correct_session')='boolean'
  and detail->'session'->'can_read_session_corrections'=to_jsonb(read_allowed)
  and detail->'session'->'can_correct_session'=to_jsonb(correct_allowed),label);
end;$$;

-- Permission-only fixture change is scoped to this transaction and restored
-- before the remaining cases. The reader retains the same visible staff role;
-- actual IAM permission, rather than a role label, is what changes.
create temporary table r6c3_saved_permission on commit drop as
 select rp.* from iam.role_permissions rp
 join iam.permissions p on p.id=rp.permission_id
 join iam.well_assignment_role_map m on m.role_id=rp.role_id
 where m.assignment_role='operator' and p.code='session.correct';

do $tests$
declare f jsonb;g jsonb;opened jsonb;d jsonb;r jsonb;legacy uuid;
 reader uuid:=gen_random_uuid();counts_before bigint;counts_after bigint;
 detail_oid oid:=to_regprocedure('api.get_session_detail(uuid)');
 exposed text;obj text;privilege_name text;
begin
 f:=pg_temp.r6c3_fixture();
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 d:=pg_temp.r6c3_detail((f->>'session')::uuid);
 -- These must be the first RED assertions: existing detail has neither field.
 perform pg_temp.r6c3_check(d->'session' ? 'can_read_session_corrections',
  '01 session detail missing can_read_session_corrections');
 perform pg_temp.r6c3_check(d->'session' ? 'can_correct_session',
  '02 session detail missing can_correct_session');
 perform pg_temp.r6c3_flags(d,true,true,
  '03 authorized completed session has two real boolean capabilities');
 perform pg_temp.r6c3_check(pg_temp.r6c3_permission((f->>'well')::uuid)
  and exists(select 1 from core.well_assignments where well_id=(f->>'well')::uuid
   and profile_id=auth.uid() and status='active'),
  '04 positive capability has active assignment and actual session.correct');
 select count(*) into counts_before from ops.session_corrections;
 perform pg_temp.r6c3_detail((f->>'session')::uuid);
 select count(*) into counts_after from ops.session_corrections;
 perform pg_temp.r6c3_check(counts_before=counts_after,
  '05 capability read creates no correction');
 r:=pg_temp.r6c3_accept(f);
 perform pg_temp.r6c3_check(r->>'status'='accepted' and r->>'financial_status'='pending',
  '06 true eligibility agrees with real C1 acceptance, without financial reconciliation');

 insert into auth.users(id,instance_id,aud,role,email,email_confirmed_at,created_at,updated_at)
 values(reader,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
  reader||'@r6c3.test',now(),now(),now());
 insert into iam.profiles(id,full_name) values(reader,'R6C3 reader') on conflict(id) do nothing;
 insert into core.well_assignments(well_id,profile_id,role,status)
 values((f->>'well')::uuid,reader,'operator','active');
 perform pg_temp.r6c3_check(exists(select 1 from r6c3_saved_permission),
  '07 fixture found actual operator permission mapping');
 delete from iam.role_permissions rp using r6c3_saved_permission saved
 where rp.role_id=saved.role_id and rp.permission_id=saved.permission_id;
 perform set_config('request.jwt.claim.sub',reader::text,true);
 -- Untrusted JWT metadata cannot override server IAM or the session scope.
 perform set_config('request.jwt.claims',jsonb_build_object('sub',reader,'role','authenticated',
  'user_metadata',jsonb_build_object('actor',f->>'actor','role','owner',
   'can_correct_session',true,'can_read_session_corrections',true))::text,true);
 perform pg_temp.r6c3_check(not pg_temp.r6c3_permission((f->>'well')::uuid),
  '08 real visible staff reader lacks session.correct, irrespective of role/metadata');
 d:=pg_temp.r6c3_detail((f->>'session')::uuid);
 perform pg_temp.r6c3_check(d->'session'->>'id'=f->>'session',
  '09 missing correction permission does not forbid ordinary detail read');
 perform pg_temp.r6c3_flags(d,false,false,
  '10 visible reader without permission has neither capability');
 perform pg_temp.r6c3_check(pg_temp.r6c3_accept_error(f)='session_correction_forbidden',
  '11 false permission capability agrees with C1 authorization denial');
 insert into iam.role_permissions select * from r6c3_saved_permission on conflict do nothing;
 perform pg_temp.r6c3_check(pg_temp.r6c3_permission((f->>'well')::uuid),
  '12 restoring actual permission changes capability without changing role');
 perform pg_temp.r6c3_flags(pg_temp.r6c3_detail((f->>'session')::uuid),true,true,
  '13 permission restoration is reflected for the same caller/session');
 perform set_config('request.jwt.claims','{}',true);

 opened:=pg_temp.r6c3_fixture(false);
 perform set_config('request.jwt.claim.sub',opened->>'actor',true);
 perform pg_temp.r6c3_check(pg_temp.r6c3_permission((opened->>'well')::uuid),
  '14 open-session caller still has real correction permission');
 perform pg_temp.r6c3_flags(pg_temp.r6c3_detail((opened->>'session')::uuid),true,false,
  '15 open session separates history permission from current correction eligibility');
 perform pg_temp.r6c3_check(pg_temp.r6c3_accept_error(opened)='session_correction_completed_facts_required',
  '16 open-session eligibility agrees with actual C1 state/facts rejection');

 -- Closed legacy facts alone are insufficient: C1 also requires a complete
 -- original segment topology. This row deliberately has no segment evidence.
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 insert into ops.irrigation_sessions(well_id,pump_id,farm_id,operator_profile_id,
  farmer_well_account_id,started_at,ended_at,status)
 values((f->>'well')::uuid,(f->>'pump')::uuid,(f->>'farm')::uuid,(f->>'actor')::uuid,
  (f->>'account')::uuid,(f->>'at')::timestamptz-interval '7 days',
  (f->>'at')::timestamptz-interval '7 days'+interval '2 hours','closed') returning id into legacy;
 perform pg_temp.r6c3_flags(pg_temp.r6c3_detail(legacy),true,false,
  '17 completed facts without original segment topology are not currently correctable');
 perform pg_temp.r6c3_check(pg_temp.r6c3_accept_error(f||jsonb_build_object(
  'session',legacy,'at',(f->>'at')::timestamptz-interval '7 days'))='session_correction_segment_boundary_invalid',
  '18 missing topology capability is no weaker than C1');

 update core.well_assignments set status='inactive'
 where well_id=(f->>'well')::uuid and profile_id=(f->>'actor')::uuid;
 perform pg_temp.r6c3_check(pg_temp.r6c3_detail_error((f->>'session')::uuid)='42501',
  '19 inactive assignment preserves existing detail visibility denial, not false flags');
 update core.well_assignments set status='active'
 where well_id=(f->>'well')::uuid and profile_id=(f->>'actor')::uuid;

 g:=pg_temp.r6c3_fixture();
 perform set_config('request.jwt.claim.sub',g->>'actor',true);
 perform pg_temp.r6c3_check(exists(select 1 from ops.session_corrections
  where session_id=(f->>'session')::uuid),
  '20 foreign session has a real correction, not an empty isolation fixture');
 perform pg_temp.r6c3_check(pg_temp.r6c3_detail_error((f->>'session')::uuid)='42501',
  '21 cross-well caller cannot read detail or foreign capability values');

 perform pg_temp.r6c3_check(detail_oid is not null
  and (select not prosecdef and pronargs=1 and proargnames=array['p_session_id']::text[]
   from pg_proc where oid=detail_oid)
  and has_function_privilege('authenticated',detail_oid,'EXECUTE')
  and has_function_privilege('service_role',detail_oid,'EXECUTE')
  and not has_function_privilege('anon',detail_oid,'EXECUTE'),
  '22 detail remains INVOKER with one session argument, no client actor/role/override');
 perform pg_temp.r6c3_check(not exists(select 1 from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace where n.nspname='api' and p.prosecdef),
  '23 no SECURITY DEFINER inside api');
 perform pg_temp.r6c3_check(not exists(select 1 from information_schema.table_privileges
  where grantee in ('authenticated','anon')
  and table_schema in ('core','iam','ops','billing','finance','inventory','audit','sync','reporting')
  and privilege_type in ('INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER')),
  '24 no direct internal table writes');
 perform pg_temp.r6c3_check(to_regprocedure('api.reconcile_session_correction(uuid,uuid,timestamptz)') is null
  and not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='api' and p.proname ilike '%reconcile%session%correction%')
  and not has_function_privilege('authenticated',
   'billing.reconcile_session_correction(uuid,uuid,timestamptz)','EXECUTE')
  and not has_function_privilege('anon',
   'billing.reconcile_session_correction(uuid,uuid,timestamptz)','EXECUTE'),
  '25 financial reconciliation remains private');
 exposed:=current_setting('pgrst.db_schemas',true);
 if nullif(exposed,'') is not null then
  perform pg_temp.r6c3_check(not ('ops'=any(regexp_split_to_array(exposed,'\s*,\s*')))
   and not ('billing'=any(regexp_split_to_array(exposed,'\s*,\s*'))),
   '26 configured Data API does not expose ops/billing');
 else
  raise notice 'UNVERIFIED Data API schemas: DB GUC unset; config.toml must remain unchanged';
 end if;
end;$tests$;

-- Regression: capability is availability to BEGIN correction, before there is
-- a desired interval. C1 alone validates the subsequently proposed payload.
-- Existing overlapping historical execution must remain repairable. The test
-- owner seeds that history directly; operational APIs rightly prevent creating
-- a new overlapping execution. No trigger, constraint or RLS is disabled.
do $current_overlap_regression$
declare
 f jsonb;sid uuid;competing uuid;d jsonb;r jsonb;failure text;
 t timestamptz;desired_start timestamptz;desired_end timestamptz;
 denied_command uuid:=gen_random_uuid();accepted_command uuid:=gen_random_uuid();
 corrections_before bigint;work_before bigint;
begin
 f:=pg_temp.r6c3_fixture();
 sid:=(f->>'session')::uuid;t:=(f->>'at')::timestamptz;
 desired_start:=t-interval '2 hours';desired_end:=t;
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 insert into ops.irrigation_sessions(well_id,pump_id,farm_id,operator_profile_id,
  farmer_well_account_id,started_at,ended_at,status)
 values((f->>'well')::uuid,(f->>'pump')::uuid,(f->>'farm')::uuid,(f->>'actor')::uuid,
  (f->>'account')::uuid,t+interval '1 hour',t+interval '3 hours','closed')
 returning id into competing;
 insert into ops.session_segments(tenant_id,session_id,sequence_number,segment_type,
  started_at,ended_at,is_billable,actual_seconds,billable_seconds)
 values((f->>'tenant')::uuid,competing,1,'operator_pause',
  t+interval '1 hour',t+interval '3 hours',false,7200,0);
 perform pg_temp.r6c3_check(
  exists(select 1 from ops.irrigation_sessions s where s.id=sid and s.status='closed'
   and s.started_at=t and s.ended_at=t+interval '2 hours' and s.operational_revision=0)
  and exists(select 1 from ops.irrigation_sessions s
   join ops.session_segments seg on seg.session_id=s.id
   where s.id=competing and s.status='closed' and seg.sequence_number=1
    and s.started_at=t+interval '1 hour' and s.ended_at=t+interval '3 hours'
    and seg.started_at=s.started_at and seg.ended_at=s.ended_at)
  and tstzrange(t,t+interval '2 hours','[)')
    &&tstzrange(t+interval '1 hour',t+interval '3 hours','[)')
  and not (tstzrange(desired_start,desired_end,'[)')
    &&tstzrange(t+interval '1 hour',t+interval '3 hours','[)')),
  '27a real target 08:00-10:00 and competitor 09:00-11:00 overlap; proposal 06:00-08:00 does not');
 perform pg_temp.r6c3_check(pg_temp.r6c3_permission((f->>'well')::uuid)
  and exists(select 1 from core.well_assignments a
   where a.well_id=(f->>'well')::uuid and a.profile_id=auth.uid() and a.status='active'),
  '27b repair caller has active assignment and actual session.correct');
 d:=pg_temp.r6c3_detail(sid);
 -- Expected RED with 030: it incorrectly validates the old interval here.
 -- No desired times have been supplied to the capability read.
 perform pg_temp.r6c3_flags(d,true,true,
  '27c capability must remain true when current overlap can be corrected by a valid desired interval');

 select count(*) into corrections_before from ops.session_corrections where session_id=sid;
 select count(*) into work_before from ops.session_correction_reconciliations where session_id=sid;
 -- true capability never preapproves an arbitrary requested interval.
 failure:=null;
 begin
  execute 'set local role authenticated';
  perform ops.accept_session_correction(sid,denied_command,0,
   'Deliberately overlapping desired interval',t+interval '15 minutes',
   t+interval '150 minutes',transaction_timestamp());
  execute 'reset role';
 exception when others then
  failure:=SQLERRM;execute 'reset role';
 end;
 perform pg_temp.r6c3_check(failure='session_correction_resource_overlap',
  '27d true capability does not authorize an overlapping desired interval; C1 rejects it');
 perform pg_temp.r6c3_check(
  (select operational_revision=0 from ops.irrigation_sessions where id=sid)
  and (select count(*) from ops.session_corrections where session_id=sid)=corrections_before
  and (select count(*) from ops.session_correction_reconciliations where session_id=sid)=work_before
  and not exists(select 1 from sync.processed_commands
   where tenant_id=(f->>'tenant')::uuid and command_id=denied_command),
  '27e rejected desired overlap leaves no revision/history/work/command mutation');

 begin
  execute 'set local role authenticated';
  r:=ops.accept_session_correction(sid,accepted_command,0,
   'Repair existing historical overlap',desired_start,desired_end,transaction_timestamp());
  execute 'reset role';
 exception when others then execute 'reset role';raise;
 end;
 perform pg_temp.r6c3_check(r->>'status'='accepted'
  and r->>'session_id'=sid::text and r->>'command_id'=accepted_command::text
  and (r->>'previous_revision')::bigint=0 and (r->>'operational_revision')::bigint=1
  and (r->>'actual_started_at')::timestamptz=desired_start
  and (r->>'actual_ended_at')::timestamptz=desired_end
  and r->>'financial_status'='pending',
  '27f C1 accepts the nonoverlapping 06:00-08:00 proposal for the same caller/session');
 perform pg_temp.r6c3_check(
  exists(select 1 from ops.session_corrections c
   where c.session_id=sid and c.command_id=accepted_command and c.id::text=r->>'correction_id'
    and c.after_started_at=desired_start and c.after_ended_at=desired_end)
  and (select count(*) from ops.session_corrections where session_id=sid)=corrections_before+1
  and (select count(*) from ops.session_correction_reconciliations where session_id=sid)=work_before+1
  and exists(select 1 from ops.irrigation_sessions where id=sid
   and started_at=t and ended_at=t+interval '2 hours' and operational_revision=1)
  and exists(select 1 from ops.session_segments where session_id=sid
   and sequence_number=1 and started_at=t and ended_at=t+interval '2 hours'),
  '27g repair persists one correction/work item and preserves original execution evidence');
end;$current_overlap_regression$;
rollback;
