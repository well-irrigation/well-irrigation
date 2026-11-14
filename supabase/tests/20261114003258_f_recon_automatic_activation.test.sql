\set ON_ERROR_STOP on
-- Local disposable DB only. pg_net sends after commit; ALL dummy requests roll back.
begin;
create function pg_temp.r4b_check(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL %',label;end if;
 raise notice 'PASS %',label;end;$$;
select pg_temp.r4b_check(to_regprocedure('billing.wake_session_correction_reconciliation()') is not null,
 'private wake exists');
do $tests$
declare r jsonb;h jsonb;n bigint;first_id bigint;key_id uuid;role_name text;job record;
begin
 select * into strict job from cron.job where jobname='session-correction-reconciliation-wake';
 perform pg_temp.r4b_check(job.active and job.schedule='* * * * *' and job.username='postgres',
  'exactly one active minute job owned by postgres');
 perform pg_temp.r4b_check(job.command='select billing.wake_session_correction_reconciliation();',
  'cron command is only private wake: no URL credential identifiers or business options');
 -- Hold scheduler state against cron for the remainder of this rollback test.
 perform 1 from billing.session_correction_reconciliation_wake_state for update;
 delete from pgmq.q_session_correction_reconciliation;
 delete from vault.secrets where name in ('f_recon_project_url','f_recon_worker_credential');
 update billing.session_correction_reconciliation_wake_state set last_request_id=null,last_requested_at=null;
 select count(*) into n from net.http_request_queue;
 r:=billing.wake_session_correction_reconciliation();
 perform pg_temp.r4b_check(r->>'status'='idle' and (select count(*)=n from net.http_request_queue),
  'empty queue never enqueues HTTP');
 perform pgmq.send('session_correction_reconciliation','{}');
 update pgmq.q_session_correction_reconciliation set vt=clock_timestamp()+interval '5 minutes';
 r:=billing.wake_session_correction_reconciliation();
 perform pg_temp.r4b_check(r->>'status'='idle' and (select count(*)=n from net.http_request_queue),
  'leased future work does not wake');
 update pgmq.q_session_correction_reconciliation set vt=clock_timestamp()-interval '1 second';
 r:=billing.wake_session_correction_reconciliation();
 perform pg_temp.r4b_check(r->>'status'='configuration_missing' and (select count(*)=n from net.http_request_queue),
  'ready work with missing Vault values does not send');
 perform vault.create_secret('http://127.0.0.1:1','f_recon_project_url');
 r:=billing.wake_session_correction_reconciliation();
 perform pg_temp.r4b_check(r->>'status'='configuration_missing' and (select count(*)=n from net.http_request_queue),
  'project URL alone cannot send');
 select vault.create_secret('   ','f_recon_worker_credential') into key_id;
 r:=billing.wake_session_correction_reconciliation();
 perform pg_temp.r4b_check(r->>'status'='configuration_missing' and (select count(*)=n from net.http_request_queue),
  'empty credential cannot send');
 perform vault.update_secret(key_id,'dummy-r4b-test-key');
 r:=billing.wake_session_correction_reconciliation();
 select last_request_id into first_id from billing.session_correction_reconciliation_wake_state;
 perform pg_temp.r4b_check(r->>'status'='wake_queued' and (select count(*)=n+1 from net.http_request_queue),
  'configured ready work enqueues exactly one request');
 perform pg_temp.r4b_check((select method='POST'
  and url='http://127.0.0.1:1/functions/v1/session-correction-reconciliation-worker'
  and headers=jsonb_build_object('Content-Type','application/json','x-f-recon-worker-key','dummy-r4b-test-key')
  and convert_from(body,'UTF8')::jsonb='{}'::jsonb and timeout_milliseconds=115000
  from net.http_request_queue where id=first_id),
  'POST exact worker URL custom header empty business body bounded timeout');
 perform pg_temp.r4b_check(not exists(select 1 from net._http_response where id=first_id),
  'dummy request is uncommitted and has not executed');
 r:=billing.wake_session_correction_reconciliation();
 perform pg_temp.r4b_check(r->>'status'='in_flight' and (select count(*)=n+1 from net.http_request_queue),
  'second wake cannot overlap unanswered request younger than 120 seconds');
 h:=billing.session_correction_reconciliation_health();
 perform pg_temp.r4b_check((h->>'queued_count')::bigint=1 and (h->>'ready_count')::bigint=1
  and (h->>'last_request_id')::bigint=first_id and (h->>'in_flight')::boolean
  and h->>'oldest_queued_at' is not null and h->>'oldest_ready_at' is not null,
  'health reports queue and in-flight operational state');
 -- Inject a response which must never be echoed verbatim by health.
 insert into net._http_response(id,status_code,content,error_msg,timed_out)
 values(first_id,503,'dummy-r4b-test-key','http://127.0.0.1:1 dummy-r4b-test-key',false);
 h:=billing.session_correction_reconciliation_health();
 perform pg_temp.r4b_check(not (h->>'in_flight')::boolean and (h->>'last_http_status')::integer=503
  and h->>'last_http_outcome'='transport_error'
  and position('dummy-r4b-test-key' in h::text)=0 and position('http://127.0.0.1:1' in h::text)=0,
  'health exposes sanitized outcome only, never Vault values or response/error text');
 r:=billing.wake_session_correction_reconciliation();
 perform pg_temp.r4b_check(r->>'status'='wake_queued' and (select count(*)=n+2 from net.http_request_queue),
  'completed request permits next wake');
 update billing.session_correction_reconciliation_wake_state
 set last_requested_at=clock_timestamp()-interval '120 seconds';
 r:=billing.wake_session_correction_reconciliation();
 perform pg_temp.r4b_check(r->>'status'='wake_queued' and (select count(*)=n+3 from net.http_request_queue),
  'unanswered stale request at 120 seconds permits recovery wake');
 foreach role_name in array array['anon','authenticated','service_role','reconciliation_executor'] loop
  perform pg_temp.r4b_check(not has_function_privilege(role_name,'billing.wake_session_correction_reconciliation()','EXECUTE')
   and not has_function_privilege(role_name,'billing.session_correction_reconciliation_health()','EXECUTE')
   and not has_table_privilege(role_name,'billing.session_correction_reconciliation_wake_state','SELECT')
   and not has_table_privilege(role_name,'billing.session_correction_reconciliation_wake_state','INSERT,UPDATE,DELETE'),
   role_name||' has no scheduler execute or state access (including PUBLIC grants)');
  begin
   execute format('set local role %I',role_name);
   perform billing.wake_session_correction_reconciliation();
   raise exception 'unexpected scheduler access';
  exception when insufficient_privilege then reset role;end;
  begin
   execute format('set local role %I',role_name);
   perform billing.session_correction_reconciliation_health();
   raise exception 'unexpected health access';
  exception when insufficient_privilege then reset role;end;
  begin
   execute format('set local role %I',role_name);
   perform 1 from billing.session_correction_reconciliation_wake_state;
   raise exception 'unexpected scheduler state access';
  exception when insufficient_privilege then reset role;end;
 end loop;
 perform pg_temp.r4b_check((select not rolcanlogin and not rolinherit and not rolbypassrls from pg_roles
  where rolname='reconciliation_executor') and
  -- Trigger functions are not directly callable SQL entrypoints.
  (select count(*)=2 from pg_proc p where p.pronamespace='billing'::regnamespace
   and p.prorettype not in ('trigger'::regtype,'event_trigger'::regtype)
   and has_function_privilege('reconciliation_executor',p.oid,'EXECUTE')) and not exists(
   select 1 from pg_class c join pg_namespace ns on ns.oid=c.relnamespace
   where ns.nspname in ('billing','ops','pgmq') and c.relkind in ('r','p')
    and has_table_privilege('reconciliation_executor',c.oid,'SELECT,INSERT,UPDATE,DELETE')),
  'executor remains isolated with only its existing two worker functions and no tables');
end;$tests$;
rollback;
