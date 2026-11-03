\set ON_ERROR_STOP on
-- OWNER ONLY. Run standalone on a disposable LOCAL database, then RESET it.
-- Opt in explicitly with r6c1_session_correction.disposable_database=yes.
-- Setup commits real fixtures so two independent Unix-socket sessions can see
-- them. This probe is NOT rollback-only and must never run against production.
set session characteristics as transaction isolation level read committed;
do $$begin
 if current_setting('r6c1_session_correction.disposable_database',true) is distinct from 'yes'
  or not (select rolsuper from pg_roles where rolname=current_user)
  or current_setting('transaction_isolation')<>'read committed' then
  raise exception 'SESSION_CORRECTION_OWNER_DISPOSABLE_LOCAL_REQUIRED';end if;
end;$$;

begin;
create extension if not exists dblink with schema extensions;
-- Intentionally fail on a repeat run: the owner must reset the disposable DB.
create schema session_correction_probe;
revoke all on schema session_correction_probe from public,anon,authenticated,service_role;

create function session_correction_probe.check_result(ok boolean,label text) returns void
language plpgsql as $$
begin
 if ok is distinct from true then raise exception 'FAIL %',label;end if;
 raise notice 'PASS %',label;
end;$$;

create function session_correction_probe.fixture() returns jsonb language plpgsql as $$
declare tenant uuid;well uuid;actor uuid:=gen_random_uuid();second_actor uuid:=gen_random_uuid();person uuid;
 farmer uuid;account uuid;farm uuid;pump uuid;sid uuid;uid uuid;start_cmd uuid:=gen_random_uuid();end_cmd uuid:=gen_random_uuid();
 at_time timestamptz:=date_trunc('day',transaction_timestamp())-interval '2 days';
begin
 insert into core.tenants(name) values('C1 concurrency probe') returning id into tenant;
 foreach uid in array array[actor,second_actor] loop
  insert into auth.users(id,instance_id,aud,role,email,email_confirmed_at,created_at,updated_at)
  values(uid,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',uid||'@c1-race.test',now(),now(),now());
  insert into iam.profiles(id,full_name) values(uid,'C1 race operator') on conflict(id) do nothing;
 end loop;
 insert into core.wells(tenant_id,name) values(tenant,'C1 race well') returning id into well;
 insert into core.well_assignments(well_id,profile_id,role,status)
 values(well,actor,'operator','active'),(well,second_actor,'operator','active');
 insert into core.persons(tenant_id,full_name,normalized_name) values(tenant,'C1 race farmer','C1 race farmer') returning id into person;
 insert into ops.farmer_profiles(tenant_id,person_id) values(tenant,person) returning id into farmer;
 insert into ops.farmer_well_accounts(tenant_id,farmer_profile_id,well_id,public_code)
 values(tenant,farmer,well,'C1-RACE-'||substr(actor::text,1,8)) returning id into account;
 insert into ops.farms(well_id,name,farmer_well_account_id) values(well,'C1 race farm',account) returning id into farm;
 insert into core.pumps(well_id,name,power_source,status) values(well,'C1 race pump','diesel','active') returning id into pump;
 insert into billing.well_pricing(well_id,price_per_hour_minor,period_start) values(well,3600,date '1970-01-01');
 insert into ops.shifts(tenant_id,well_id,operator_profile_id,started_at,status)
 values(tenant,well,actor,at_time-interval '1 hour','open');
 perform set_config('request.jwt.claim.sub',actor::text,true);
 execute 'set local role authenticated';
 sid:=api.start_operational_session(well,pump,farm,account,'solar',at_time,start_cmd);
 -- Only initial fixture completion creates its original charge. Races never
 -- execute completion again, create financial effects, or alter that charge.
 perform api.complete_irrigation_session(sid,at_time+interval '1 hour',null,null,null,end_cmd);
 execute 'reset role';
 return jsonb_build_object('tenant',tenant,'well',well,'actor',actor,'second_actor',second_actor,
  'session',sid,'started_at',at_time,'ended_at',at_time+interval '1 hour',
  'start_command',start_cmd,'completion_command',end_cmd);
exception when others then execute 'reset role';raise;
end;$$;

create function session_correction_probe.original_snapshot() returns jsonb language plpgsql as $$
declare x record;fingerprint text;r jsonb:='{}';
begin
 -- Include every financial/inventory base table, not only row counts.
 for x in select n.nspname,c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where c.relkind in ('r','p') and n.nspname in ('billing','finance','inventory') order by 1,2 loop
  execute format('select md5(coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text)::text,''null'')) from %I.%I t',
   x.nspname,x.relname) into fingerprint;
  r:=r||jsonb_build_object(x.nspname||'.'||x.relname,fingerprint);
 end loop;
 return r||jsonb_build_object(
  'sessions',(select jsonb_agg(to_jsonb(s)-'operational_revision' order by id) from ops.irrigation_sessions s),
  'segments',(select jsonb_agg(to_jsonb(s) order by id) from ops.session_segments s),
  'occurrences',(select jsonb_agg(to_jsonb(o) order by tenant_id,occurrence_command_id) from ops.operational_occurrences o),
  'original_commands',(select jsonb_agg(to_jsonb(c) order by id) from sync.processed_commands c
   where command_type<>'correct_irrigation_session'));
end;$$;

create table session_correction_probe.fixtures (
 case_id integer primary key,
 f jsonb not null,
 command_a uuid not null,
 command_b uuid not null,
 request_a jsonb not null,
 request_b jsonb not null
);
do $$declare n integer;f jsonb;ca uuid;cb uuid;qa jsonb;qb jsonb;begin
 for n in 1..4 loop
  f:=session_correction_probe.fixture();ca:=gen_random_uuid();
  cb:=case when n in (2,3) then ca else gen_random_uuid() end;
  qa:=jsonb_build_object('base_revision',0,'reason','  original race reason  ',
   'desired_started_at',(f->>'started_at')::timestamptz-interval '5 minutes',
   'desired_ended_at',(f->>'ended_at')::timestamptz,
   'requested_at',(f->>'ended_at')::timestamptz+interval '1 hour');
  qb:=case when n=2 then qa else qa||jsonb_build_object(
   'desired_ended_at',(f->>'ended_at')::timestamptz+interval '5 minutes') end;
  insert into session_correction_probe.fixtures values(n,f,ca,cb,qa,qb);
 end loop;
end;$$;

-- AFTER INSERT is inside the actual production acceptance transaction, after
-- the well scope AND session row locks, before revision/work/receipt commit.
create function session_correction_probe.barrier() returns trigger language plpgsql as $$
declare gate integer;
begin
 select x.case_id into gate from session_correction_probe.fixtures x where x.f->>'session'=new.session_id::text;
 if found then perform pg_advisory_xact_lock(746108,gate);end if;
 return new;
end;$$;
create trigger session_correction_race_barrier after insert on ops.session_corrections
 for each row execute function session_correction_probe.barrier();

create function session_correction_probe.attempt(f jsonb,cmd uuid,request jsonb,
 revoke_after_accept uuid default null) returns jsonb language plpgsql as $$
declare r jsonb;
begin
 if current_setting('transaction_isolation')<>'read committed' then
  raise exception 'RACE_REQUIRES_READ_COMMITTED';end if;
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 begin
  r:=ops.accept_session_correction((f->>'session')::uuid,cmd,(request->>'base_revision')::bigint,
   request->>'reason',(request->>'desired_started_at')::timestamptz,
   (request->>'desired_ended_at')::timestamptz,(request->>'requested_at')::timestamptz);
  if revoke_after_accept is not null then
   -- Test-only authorization change committed by A before B resumes. The
   -- controller cannot do this in its own uncommitted DO transaction.
   update core.well_assignments set status='inactive'
    where well_id=(f->>'well')::uuid and profile_id=revoke_after_accept;
  end if;
  return jsonb_build_object('outcome','accepted','result',r);
 exception when serialization_failure or invalid_parameter_value or insufficient_privilege then
  -- This subtransaction rolls back a losing command reservation and any C1
  -- writes. Capture only expected business errors; other errors fail the probe.
  return jsonb_build_object('outcome','rejected','sqlstate',SQLSTATE,'reason',SQLERRM);
 end;
end;$$;
revoke all on all functions in schema session_correction_probe from public,anon,authenticated,service_role;
commit;

do $concurrency$
declare conn text;socket_dir text;ext_schema text;n integer;f jsonb;fb jsonb;request_a jsonb;request_b jsonb;
 ca uuid;cb uuid;sid uuid;qa text;qb text;pa integer;pb integer;super_a boolean;super_b boolean;socket_a boolean;socket_b boolean;
 isolation_a text;isolation_b text;deadline timestamptz;ra jsonb;rb jsonb;originals jsonb;prior_history jsonb;
 row_a ops.session_corrections%rowtype;pc sync.processed_commands%rowtype;
 initial_revision bigint;initial_history bigint;initial_work bigint;gate_held boolean:=false;
 a_open boolean:=false;b_open boolean:=false;
begin
 select ns.nspname into strict ext_schema from pg_extension e join pg_namespace ns on ns.oid=e.extnamespace where e.extname='dblink';
 perform set_config('search_path',quote_ident(ext_schema)||',pg_catalog,session_correction_probe',true);
 socket_dir:=btrim(split_part(current_setting('unix_socket_directories'),',',1));
 if socket_dir not like '/%' then raise exception 'LOCAL_UNIX_SOCKET_REQUIRED';end if;
 conn:=format('host=%L port=%s dbname=%L user=%L connect_timeout=5',
  socket_dir,current_setting('port'),current_database(),current_user);
 perform dblink_connect('session_correction_a',conn);a_open:=true;
 perform dblink_connect('session_correction_b',conn);b_open:=true;
 perform dblink_exec('session_correction_a','set session characteristics as transaction isolation level read committed');
 perform dblink_exec('session_correction_b','set session characteristics as transaction isolation level read committed');
 perform dblink_exec('session_correction_a','set timezone=''UTC''');
 perform dblink_exec('session_correction_b','set timezone=''UTC''');
 perform dblink_exec('session_correction_a','set statement_timeout=''20s''');
 perform dblink_exec('session_correction_b','set statement_timeout=''20s''');
 perform dblink_exec('session_correction_a','set lock_timeout=''12s''');
 perform dblink_exec('session_correction_b','set lock_timeout=''12s''');
 select pid,isolation,is_super,is_socket into pa,isolation_a,super_a,socket_a from dblink('session_correction_a',
  'select pg_backend_pid(),current_setting(''transaction_isolation''),(select rolsuper from pg_roles where rolname=current_user),inet_server_addr() is null')
  as t(pid integer,isolation text,is_super boolean,is_socket boolean);
 select pid,isolation,is_super,is_socket into pb,isolation_b,super_b,socket_b from dblink('session_correction_b',
  'select pg_backend_pid(),current_setting(''transaction_isolation''),(select rolsuper from pg_roles where rolname=current_user),inet_server_addr() is null')
  as t(pid integer,isolation text,is_super boolean,is_socket boolean);
 perform session_correction_probe.check_result(pa<>pb and pa<>pg_backend_pid() and pb<>pg_backend_pid()
  and super_a and super_b and socket_a and socket_b and isolation_a='read committed' and isolation_b='read committed',
  'two independent superuser Unix-socket sessions, READ COMMITTED');

 for n in 1..4 loop
  select x.f,x.command_a,x.command_b,x.request_a,x.request_b into strict f,ca,cb,request_a,request_b
   from session_correction_probe.fixtures x where case_id=n;
  sid:=(f->>'session')::uuid;fb:=f;
  if n=4 then fb:=f||jsonb_build_object('actor',f->'second_actor');end if;
  select operational_revision into strict initial_revision from ops.irrigation_sessions where id=sid;
  select count(*) into initial_history from ops.session_corrections where session_id=sid;
  select count(*) into initial_work from ops.session_correction_reconciliations where session_id=sid;
  perform session_correction_probe.check_result(initial_revision=0 and initial_history=0 and initial_work=0,
   'fresh completed session at revision N=0, case '||n);
  originals:=session_correction_probe.original_snapshot();
  select jsonb_agg(to_jsonb(h) order by session_id,new_revision) into prior_history
   from ops.session_corrections h where session_id<>sid;
  qa:=format('select session_correction_probe.attempt(%L::jsonb,%L::uuid,%L::jsonb,%L::uuid)',
   f::text,ca,request_a::text,case when n=4 then f->>'second_actor' end);
  qb:=format('select session_correction_probe.attempt(%L::jsonb,%L::uuid,%L::jsonb)',fb::text,cb,request_b::text);

  perform pg_advisory_lock(746108,n);gate_held:=true;
  perform session_correction_probe.check_result(dblink_send_query('session_correction_a',qa)=1,'A query launched');
  deadline:=clock_timestamp()+interval '5 seconds';
  loop
   perform pg_stat_clear_snapshot();
   exit when exists(select 1 from pg_stat_activity where pid=pa and wait_event='advisory')
    and pg_backend_pid()=any(pg_blocking_pids(pa));
   if clock_timestamp()>deadline then raise exception 'FIRST_REAL_TRANSACTION_PROTECTED_BARRIER_NOT_REACHED case %',n;end if;
   perform pg_sleep(0.01);
  end loop;
  perform session_correction_probe.check_result(dblink_send_query('session_correction_b',qb)=1,'B query launched');
  deadline:=clock_timestamp()+interval '5 seconds';
  loop
   perform pg_stat_clear_snapshot();
   exit when pa=any(pg_blocking_pids(pb))
    and exists(select 1 from pg_stat_activity where pid=pb and wait_event_type='Lock');
   if clock_timestamp()>deadline then raise exception 'SECOND_REAL_TRANSACTION_NOT_BLOCKED_BY_FIRST case %',n;end if;
   perform pg_sleep(0.01);
  end loop;
  perform session_correction_probe.check_result(dblink_is_busy('session_correction_a')=1
   and dblink_is_busy('session_correction_b')=1,'observed A inside acceptance and B actually blocked by A, case '||n);
  perform session_correction_probe.check_result(pg_advisory_unlock(746108,n),'controller releases verified barrier');
  gate_held:=false;
  deadline:=clock_timestamp()+interval '20 seconds';
  loop
   exit when dblink_is_busy('session_correction_a')=0 and dblink_is_busy('session_correction_b')=0;
   if clock_timestamp()>deadline then raise exception 'REAL_RACE_RESULTS_TIMEOUT case %',n;end if;
   perform pg_sleep(0.01);
  end loop;
  select result into strict ra from dblink_get_result('session_correction_a') as t(result jsonb);
  select result into strict rb from dblink_get_result('session_correction_b') as t(result jsonb);
  -- Drain the terminal empty result before reusing these same two sessions.
  perform * from dblink_get_result('session_correction_a') as t(result jsonb);
  perform * from dblink_get_result('session_correction_b') as t(result jsonb);
  perform session_correction_probe.check_result(ra->>'outcome'='accepted' and ra->'result'->>'status'='accepted',
   'A committed an accepted operational correction');
  if n=1 then
   perform session_correction_probe.check_result(rb->>'outcome'='rejected' and rb->>'sqlstate'='40001'
    and rb->>'reason'='stale_revision','CASE 1 / 4 waiting command re-evaluates current revision; no N+2');
  elsif n=2 then
   perform session_correction_probe.check_result(rb->>'outcome'='accepted' and rb->'result'=ra->'result',
    'CASE 2 / 4 exact replay after waiting returns original result before stale check');
  elsif n=3 then
   perform session_correction_probe.check_result(rb->>'outcome'='rejected' and rb->>'sqlstate'='22023'
    and rb->>'reason'='session_correction_idempotency_conflict','CASE 3 changed payload after waiting cannot rebind command');
  else
   perform session_correction_probe.check_result(rb->>'outcome'='rejected' and rb->>'sqlstate'='42501'
    and rb->>'reason'='session_correction_forbidden'
    and exists(select 1 from core.well_assignments where well_id=(f->>'well')::uuid
      and profile_id=(f->>'second_actor')::uuid and status='inactive'),
    'CASE 4 authorization revoked by A commit is checked again after B actually waited');
  end if;
  select h.* into strict row_a from ops.session_corrections h where h.tenant_id=(f->>'tenant')::uuid and h.command_id=ca;
  select c.* into strict pc from sync.processed_commands c where c.tenant_id=(f->>'tenant')::uuid and c.command_id=ca;
  perform session_correction_probe.check_result((select operational_revision=initial_revision+1 from ops.irrigation_sessions where id=sid)
   and (select count(*)=initial_history+1 from ops.session_corrections where session_id=sid)
   and (select count(*)=initial_work+1 from ops.session_correction_reconciliations where session_id=sid),
   'exactly one revision increment, one history row and one reconciliation item, case '||n);
  perform session_correction_probe.check_result(row_a.previous_revision=initial_revision and row_a.new_revision=initial_revision+1
   and row_a.before_started_at=(f->>'started_at')::timestamptz and row_a.before_ended_at=(f->>'ended_at')::timestamptz
   and row_a.after_started_at=(request_a->>'desired_started_at')::timestamptz
   and row_a.after_ended_at=(request_a->>'desired_ended_at')::timestamptz
   and row_a.reason=request_a->>'reason' and row_a.requested_at=(request_a->>'requested_at')::timestamptz
   and row_a.actor_id=(f->>'actor')::uuid and row_a.accepted_result=ra->'result',
   'persisted typed facts and original accepted result belong only to winning payload A');
  perform session_correction_probe.check_result(pc.status='accepted' and pc.command_type='correct_irrigation_session'
   and pc.entity_id=sid and pc.request_payload=row_a.request_payload and pc.response_payload=row_a.accepted_result
   and (pc.request_payload->>'desired_started_at')::timestamptz=row_a.after_started_at
   and (pc.request_payload->>'desired_ended_at')::timestamptz=row_a.after_ended_at
   and (pc.request_payload->>'base_revision')::bigint=initial_revision
   and pc.request_payload->>'reason'=row_a.reason
   and (pc.request_payload->>'requested_at')::timestamptz=row_a.requested_at
   and pc.request_payload->>'actor_id'=f->>'actor'
   and pc.request_payload->>'well_id'=f->>'well' and pc.request_payload->>'tenant_id'=f->>'tenant'
   and pc.request_payload->>'session_id'=sid::text
   and (select count(*)=1 from sync.processed_commands where tenant_id=(f->>'tenant')::uuid
     and command_id in (ca,cb) and command_type='correct_irrigation_session'),
   'one canonical stored request/result; no losing or duplicate command reservation remains');
  perform session_correction_probe.check_result((select count(*)=1 and bool_and(operational_revision=initial_revision+1
    and effective_started_at=row_a.after_started_at and effective_ended_at=row_a.after_ended_at)
   from ops.effective_session_facts where session_id=sid),'exactly one latest effective operational state');
  perform session_correction_probe.check_result((select count(*)=1 and bool_and(status='pending' and attempt_count=0
    and operational_revision=initial_revision+1 and correction_id=row_a.id)
   from ops.session_correction_reconciliations where session_id=sid)
   and not exists(select 1 from ops.session_corrections where session_id=sid and new_revision>initial_revision+1),
   'CASE 5 only accepted N+1 pending work exists; no N+2 or applied financial revision');
  if ca<>cb then
   perform session_correction_probe.check_result(not exists(select 1 from ops.session_corrections where command_id=cb)
    and not exists(select 1 from sync.processed_commands where tenant_id=(f->>'tenant')::uuid and command_id=cb),
    'losing transaction left no history, work FK target, or processed-command row');
  end if;
  perform session_correction_probe.check_result(session_correction_probe.original_snapshot()=originals,
   'original session facts, segments, occurrence, receipts and all financial/inventory rows unchanged');
  perform session_correction_probe.check_result(prior_history is not distinct from
   (select jsonb_agg(to_jsonb(h) order by session_id,new_revision) from ops.session_corrections h where session_id<>sid),
   'earlier accepted correction history unchanged');
  begin
   update ops.session_corrections set reason='probe forbidden rewrite' where id=row_a.id;
   raise exception 'HISTORY_UPDATE_WAS_ALLOWED';
  exception when check_violation then
   perform session_correction_probe.check_result(SQLERRM='session_correction_history_immutable','accepted history UPDATE denied');
  end;
  begin
   delete from ops.session_corrections where id=row_a.id;
   raise exception 'HISTORY_DELETE_WAS_ALLOWED';
  exception when check_violation then
   perform session_correction_probe.check_result(SQLERRM='session_correction_history_immutable','accepted history DELETE denied');
  end;
 end loop;
 perform dblink_disconnect('session_correction_a');a_open:=false;
 perform dblink_disconnect('session_correction_b');b_open:=false;
exception when others then
 -- Exception rollback restores transaction-local settings, but dblink sessions
 -- and session advisory locks survive. Restore extension resolution for cleanup.
 if ext_schema is not null then
  perform set_config('search_path',quote_ident(ext_schema)||',pg_catalog,session_correction_probe',true);
 end if;
 -- Cancel both independent transactions before releasing a held barrier; then
 -- close sessions. Setup/committed race fixtures intentionally require RESET.
 if a_open then begin perform dblink_cancel_query('session_correction_a');exception when others then null;end;end if;
 if b_open then begin perform dblink_cancel_query('session_correction_b');exception when others then null;end;end if;
 if gate_held then perform pg_advisory_unlock(746108,n);end if;
 if a_open then begin perform dblink_disconnect('session_correction_a');exception when others then null;end;end if;
 if b_open then begin perform dblink_disconnect('session_correction_b');exception when others then null;end;end if;
 raise;
end;$concurrency$;
-- Success cleanup removes the hook; dedicated probe schema/fixtures remain
-- intentionally for inspection. The owner must perform a final clean RESET.
drop trigger session_correction_race_barrier on ops.session_corrections;
