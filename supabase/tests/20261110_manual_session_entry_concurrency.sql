\set ON_ERROR_STOP on
-- OWNER ONLY, disposable local database: committed fixtures survive by design.
-- Set manual_entry.disposable_database=yes before executing this file.
-- Supabase's owner role need not be SUPERUSER. Require explicit opt-in AND
-- the repository's postgres owner/database via a local Unix socket instead.
do $$begin
 if current_setting('manual_entry.disposable_database',true) is distinct from 'yes'
  or current_user<>'postgres' or session_user<>'postgres'
  or current_database()<>'postgres' or inet_server_addr() is not null then
  raise exception 'OWNER_DISPOSABLE_DATABASE_REQUIRED';end if;
end$$;
-- Owner supplies the inspected container IPv4 and disposable DB password.
-- No default/committed password. gset prevents printing the setting's value.
\getenv me_host MANUAL_ENTRY_LOCAL_HOST
\if :{?me_host}
select set_config('manual_entry.local_host', :'me_host',false) as me_host_loaded \gset
\unset me_host
\unset me_host_loaded
\else
\echo MANUAL_ENTRY_LOCAL_HOST_REQUIRED
\quit 3
\endif
\getenv me_password MANUAL_ENTRY_LOCAL_PASSWORD
\if :{?me_password}
select set_config('manual_entry.local_password', :'me_password',false) as me_secret_loaded \gset
\unset me_password
\unset me_secret_loaded
\else
\echo MANUAL_ENTRY_LOCAL_PASSWORD_REQUIRED
\quit 3
\endif
do $$declare target inet;begin
 target:=current_setting('manual_entry.local_host')::inet;
 if family(target)<>4 or masklen(target)<>32
  or not (target<<=inet '10.0.0.0/8' or target<<=inet '172.16.0.0/12'
   or target<<=inet '192.168.0.0/16') then
  raise exception 'PRIVATE_DOCKER_IPV4_REQUIRED';end if;
 if nullif(current_setting('manual_entry.local_password',true),'') is null then
  raise exception 'LOCAL_TEST_PASSWORD_REQUIRED';end if;
end$$;
begin;
create extension if not exists dblink with schema extensions;
create schema manual_entry_probe;
create function manual_entry_probe.fixture() returns jsonb language plpgsql as $$
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

create function manual_entry_probe.call(f jsonb,cmd uuid,req jsonb,active boolean) returns jsonb language plpgsql as $$
declare r jsonb;
begin
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 execute 'set local role authenticated';
 if active then r:=api.adopt_external_session((f->>'well')::uuid,cmd,req);
 else r:=api.record_historical_session((f->>'well')::uuid,cmd,req);end if;
 execute 'reset role';return r;
exception when others then execute 'reset role';raise;
end;$$;
create table manual_entry_probe.fixtures(n integer primary key,f jsonb,req jsonb,cmd uuid);
do $$declare f jsonb;req jsonb;i integer;at_time timestamptz;
begin
 for i in 1..4 loop
  f:=manual_entry_probe.fixture();
  at_time:=case when i>2 then transaction_timestamp()-interval '1 hour' else (f->>'at')::timestamptz end;
  req:=jsonb_build_object('version',1,'pump_id',f->'pump','farm_id',f->'farm','farmer_well_account_id',f->'account',
   'started_at',at_time,'energy_source','solar','reason','تزامن إدخال مستقل');
  if i<=2 then req:=req||jsonb_build_object('ended_at',at_time+interval '1 hour');end if;
  insert into manual_entry_probe.fixtures values(i,f,req,gen_random_uuid());
 end loop;
end$$;
create function manual_entry_probe.barrier() returns trigger language plpgsql as $$
begin
 if exists(select 1 from manual_entry_probe.fixtures where f->>'well'=new.well_id::text) then
  perform pg_advisory_xact_lock(918137);end if;
 return new;
end;$$;
create trigger manual_entry_concurrency_barrier after insert on ops.irrigation_sessions
 for each row execute function manual_entry_probe.barrier();
commit;
do $concurrent$
declare connection text;password_option text;target inet;child_proof text;ext text;f jsonb;req jsonb;cmd uuid;cmd_b uuid;
 a text;b text;pid_a integer;pid_b integer;deadline timestamptz;i integer;r jsonb;second_result jsonb;
begin
 select n.nspname into ext from pg_extension e join pg_namespace n on n.oid=e.extnamespace where e.extname='dblink';
 perform set_config('search_path',quote_ident(ext)||',pg_catalog',true);
 -- Non-superuser dblink requires password authentication, not socket trust.
 target:=current_setting('manual_entry.local_host')::inet;
 -- Admission above restricts target to a single private Docker IPv4 address.
 -- Escape libpq conninfo syntax (not SQL literal syntax), including quotes.
 password_option:=chr(39)||replace(replace(current_setting('manual_entry.local_password'),
  chr(92),chr(92)||chr(92)),chr(39),chr(92)||chr(39))||chr(39);
 connection:=format('host=%s port=%s dbname=postgres user=postgres password=%s connect_timeout=5',
  host(target),current_setting('port'),password_option);
 password_option:=null;
 perform set_config('manual_entry.local_password','',false);
 for i in 1..4 loop
  select x.f,x.req,x.cmd into f,req,cmd from manual_entry_probe.fixtures x where n=i;
  cmd_b:=case when i in (1,3) then cmd else gen_random_uuid() end;
  a:=format('select manual_entry_probe.call(%L::jsonb,%L::uuid,%L::jsonb,%L::boolean)',f,cmd,req,i>2);
  b:=format('select manual_entry_probe.call(%L::jsonb,%L::uuid,%L::jsonb,%L::boolean)',f,cmd_b,req,i>2);
  perform dblink_connect('me_a',connection);perform dblink_connect('me_b',connection);
  -- Session GUCs do not cross connections. Opt in explicitly on each connection
  -- to the inspected Docker server/database, then verify before any work.
  perform dblink_exec('me_a','set manual_entry.disposable_database=''yes''');
  perform dblink_exec('me_b','set manual_entry.disposable_database=''yes''');
  child_proof:=format(
   'select current_setting(''manual_entry.disposable_database'',true)=''yes'' and current_user=''postgres'' and session_user=''postgres'' and current_database()=''postgres'' and inet_server_addr()=%L::inet and inet_client_addr()=%L::inet',
   host(target),host(target));
  if (select ok from dblink('me_a',child_proof) as x(ok boolean)) is distinct from true
   or (select ok from dblink('me_b',child_proof) as x(ok boolean)) is distinct from true then
   raise exception 'CHILD_OWNER_DISPOSABLE_LOCAL_REQUIRED';end if;
  select pid into pid_a from dblink('me_a','select pg_backend_pid()') as x(pid integer);
  select pid into pid_b from dblink('me_b','select pg_backend_pid()') as x(pid integer);
  if pid_a=pid_b or pid_a=pg_backend_pid() or pid_b=pg_backend_pid() then
   raise exception 'INDEPENDENT_CONNECTIONS_REQUIRED';end if;
  perform pg_advisory_lock(918137);perform dblink_send_query('me_a',a);
  deadline:=clock_timestamp()+interval '10 seconds';
  loop
   perform pg_stat_clear_snapshot();
   exit when exists(select 1 from pg_stat_activity where pid=pid_a and wait_event='advisory');
   if clock_timestamp()>deadline then raise exception 'FIRST_WRITER_BARRIER_NOT_REACHED';end if;
   perform pg_sleep(0.01);
  end loop;
  perform dblink_send_query('me_b',b);
  loop
   perform pg_stat_clear_snapshot();
   exit when pid_a=any(pg_blocking_pids(pid_b));
   if clock_timestamp()>deadline then raise exception 'SECOND_WRITER_DID_NOT_CONTEND';end if;
   perform pg_sleep(0.01);
  end loop;
  perform pg_advisory_unlock(918137);
  select result into r from dblink_get_result('me_a') as x(result jsonb);
  select result into second_result from dblink_get_result('me_b') as x(result jsonb);
  if r->>'status'<>'accepted' then raise exception 'FIRST_REQUEST_NOT_ACCEPTED: %',r;end if;
  if i in (1,3) then
   if second_result is distinct from r then raise exception 'EXACT_CONCURRENT_REPLAY_MISMATCH';end if;
  elsif second_result->>'status' is distinct from (case when i=2 then 'conflict_overlap' else 'conflict_active_resource' end) then
   raise exception 'CONCURRENT_CONFLICT_NOT_ACTIONABLE: %',second_result;
  end if;
  if (select count(*) from ops.irrigation_sessions where well_id=(f->>'well')::uuid)<>1
   or (select count(*) from billing.session_charges where well_id=(f->>'well')::uuid)<>(case when i<=2 then 1 else 0 end) then
   raise exception 'DUPLICATE_SESSION_OR_CHARGE';end if;
  raise notice 'PASS concurrency %: real contention, one session, exact replay or actionable conflict',i;
  perform dblink_disconnect('me_a');perform dblink_disconnect('me_b');
 end loop;
exception when others then
 perform pg_advisory_unlock_all();
 if 'me_a'=any(coalesce(dblink_get_connections(),array[]::text[])) then perform dblink_disconnect('me_a');end if;
 if 'me_b'=any(coalesce(dblink_get_connections(),array[]::text[])) then perform dblink_disconnect('me_b');end if;
 raise;
end;$concurrent$;
drop trigger manual_entry_concurrency_barrier on ops.irrigation_sessions;
-- Keep accepted immutable fixtures in this disposable DB, just like R4 probes.
