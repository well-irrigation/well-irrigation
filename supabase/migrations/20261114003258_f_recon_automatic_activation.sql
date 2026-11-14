-- Wake/watchdog only. Financial execution remains in the existing queue worker.
begin;
create extension if not exists pg_cron;
create extension if not exists pg_net;

create table billing.session_correction_reconciliation_wake_state (
 singleton boolean primary key default true check(singleton),
 last_request_id bigint,
 last_requested_at timestamptz,
 check((last_request_id is null)=(last_requested_at is null))
);
insert into billing.session_correction_reconciliation_wake_state(singleton) values(true);
alter table billing.session_correction_reconciliation_wake_state enable row level security;

create function billing.wake_session_correction_reconciliation() returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare s billing.session_correction_reconciliation_wake_state%rowtype;
 project_url text;credential text;request_id bigint;
begin
 if not exists(select 1 from pgmq.q_session_correction_reconciliation where vt<=clock_timestamp()) then
  return jsonb_build_object('status','idle');
 end if;
 -- Serialize concurrent cron/manual owner wakes, without locking queue work.
 select * into strict s from billing.session_correction_reconciliation_wake_state
  where singleton for update;
 if not exists(select 1 from pgmq.q_session_correction_reconciliation where vt<=clock_timestamp()) then
  return jsonb_build_object('status','idle');
 end if;
 if s.last_request_id is not null and s.last_requested_at>clock_timestamp()-interval '120 seconds'
  and not exists(select 1 from net._http_response where id=s.last_request_id) then
  return jsonb_build_object('status','in_flight');
 end if;
 select decrypted_secret into project_url from vault.decrypted_secrets where name='f_recon_project_url';
 select decrypted_secret into credential from vault.decrypted_secrets where name='f_recon_worker_credential';
 if nullif(btrim(project_url),'') is null or nullif(btrim(credential),'') is null then
  return jsonb_build_object('status','configuration_missing');
 end if;
 -- Four items / concurrency two, up to two waves of 55s worker statements.
 -- Bound HTTP to 115s, below the 120s unanswered-request recovery window.
 request_id:=net.http_post(
  url:=rtrim(btrim(project_url),'/')||'/functions/v1/session-correction-reconciliation-worker',
  body:='{}'::jsonb,
  headers:=jsonb_build_object('Content-Type','application/json','x-f-recon-worker-key',credential),
  timeout_milliseconds:=115000
 );
 update billing.session_correction_reconciliation_wake_state
  set last_request_id=request_id,last_requested_at=clock_timestamp() where singleton;
 return jsonb_build_object('status','wake_queued');
end;$$;

create function billing.session_correction_reconciliation_health() returns jsonb
language sql volatile security definer set search_path=pg_catalog,pg_temp as $$
 select jsonb_build_object(
  'queued_count',q.queued_count,'ready_count',q.ready_count,
  'oldest_queued_at',q.oldest_queued_at,'oldest_ready_at',q.oldest_ready_at,'max_read_count',q.max_read_count,
  'last_request_id',s.last_request_id,'last_requested_at',s.last_requested_at,
  'in_flight',s.last_request_id is not null and s.last_requested_at>clock_timestamp()-interval '120 seconds'
   and r.id is null,
  'last_http_status',r.status_code,'last_timed_out',r.timed_out,
  -- libcurl errors or remote bodies can echo URLs/headers: expose categories only.
  'last_http_outcome',case when r.id is null then null
   when r.timed_out then 'timeout' when r.error_msg is not null then 'transport_error'
   when r.status_code>=400 then 'http_error' else 'completed' end
 )
 from billing.session_correction_reconciliation_wake_state s
 cross join (select count(*) as queued_count,count(*) filter(where vt<=clock_timestamp()) as ready_count,
  min(enqueued_at) as oldest_queued_at,min(enqueued_at) filter(where vt<=clock_timestamp()) as oldest_ready_at,
  max(read_ct) as max_read_count from pgmq.q_session_correction_reconciliation) q
 left join net._http_response r on r.id=s.last_request_id
 where s.singleton;
$$;

revoke all on table billing.session_correction_reconciliation_wake_state
 from public,anon,authenticated,service_role,reconciliation_executor;
revoke all on function billing.wake_session_correction_reconciliation(),
 billing.session_correction_reconciliation_health()
 from public,anon,authenticated,service_role,reconciliation_executor;

-- Replace all same-name jobs, including a stale registration under another owner.
-- The resulting postgres job contains no URL, credential or business identifier.
do $$declare j record;begin
 for j in select jobid from cron.job where jobname='session-correction-reconciliation-wake' loop
  perform cron.unschedule(j.jobid);
 end loop;
 perform cron.schedule('session-correction-reconciliation-wake','* * * * *',
  'select billing.wake_session_correction_reconciliation();');
end;$$;
commit;
