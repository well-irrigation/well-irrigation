begin;
-- R6-C1: private operational acceptance only. Original execution/receipts and
-- all financial records remain unchanged. Public write activation belongs to C4.
alter table ops.irrigation_sessions add column operational_revision bigint not null default 0
 constraint irrigation_sessions_operational_revision_nonnegative check(operational_revision>=0);
revoke update(operational_revision) on ops.irrigation_sessions from public,anon,authenticated,service_role;

create table ops.session_corrections (
 id uuid primary key default gen_random_uuid(),
 tenant_id uuid not null references core.tenants(id),
 well_id uuid not null references core.wells(id),
 session_id uuid not null references ops.irrigation_sessions(id),
 command_id uuid not null,
 previous_revision bigint not null check(previous_revision>=0),
 new_revision bigint not null check(new_revision=previous_revision+1),
 before_started_at timestamptz not null,
 before_ended_at timestamptz not null,
 after_started_at timestamptz not null,
 after_ended_at timestamptz not null,
 reason text not null check(nullif(btrim(reason),'') is not null),
 actor_id uuid not null references iam.profiles(id),
 requested_at timestamptz not null,
 accepted_at timestamptz not null default clock_timestamp(),
 created_at timestamptz not null default clock_timestamp(),
 occurrence_command_id uuid,
 original_start_command_id uuid,
 original_completion_command_id uuid,
 request_payload jsonb not null check(jsonb_typeof(request_payload)='object'),
 accepted_result jsonb not null check(jsonb_typeof(accepted_result)='object'),
 unique(tenant_id,command_id),
 unique(session_id,new_revision),
 unique(id,session_id,new_revision),
 foreign key(tenant_id,occurrence_command_id)
  references ops.operational_occurrences(tenant_id,occurrence_command_id),
 check(isfinite(before_started_at) and isfinite(before_ended_at) and before_started_at<before_ended_at),
 check(isfinite(after_started_at) and isfinite(after_ended_at) and after_started_at<after_ended_at),
 check(isfinite(requested_at) and isfinite(accepted_at) and isfinite(created_at))
);
create index session_corrections_scope_idx on ops.session_corrections(tenant_id,well_id,session_id,new_revision);

create table ops.session_correction_reconciliations (
 correction_id uuid primary key,
 session_id uuid not null,
 operational_revision bigint not null check(operational_revision>0),
 status text not null default 'pending' check(status in ('pending','applied','financial_review_required')),
 attempt_count bigint not null default 0 check(attempt_count>=0),
 last_attempt_at timestamptz,
 last_error text,
 created_at timestamptz not null default clock_timestamp(),
 updated_at timestamptz not null default clock_timestamp(),
 unique(session_id,operational_revision),
 foreign key(correction_id,session_id,operational_revision)
  references ops.session_corrections(id,session_id,new_revision),
 check(last_attempt_at is null or isfinite(last_attempt_at))
);
create index session_correction_work_pending_idx on ops.session_correction_reconciliations(session_id,operational_revision)
 where status<>'applied';
alter table ops.session_corrections enable row level security;
alter table ops.session_correction_reconciliations enable row level security;
revoke all on ops.session_corrections,ops.session_correction_reconciliations from public,anon,authenticated,service_role;

-- A missing positive revision must never fall back to original execution facts.
create view ops.effective_session_facts with(security_invoker=true) as
select s.id as session_id,s.operational_revision,
 case when s.operational_revision=0 then s.started_at else c.after_started_at end as effective_started_at,
 case when s.operational_revision=0 then s.ended_at else c.after_ended_at end as effective_ended_at
from ops.irrigation_sessions s left join ops.session_corrections c
 on c.session_id=s.id and c.new_revision=s.operational_revision;
revoke all on ops.effective_session_facts from public,anon,authenticated,service_role;

create function ops.reject_session_correction_history_mutation() returns trigger
language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
begin raise exception 'session_correction_history_immutable' using errcode='23514';end;$$;
create trigger session_correction_history_immutable before update or delete on ops.session_corrections
 for each row execute function ops.reject_session_correction_history_mutation();

-- Even if a future table-wide UPDATE grant is introduced, a client cannot mint
-- a revision: the matching private history row must exist in this transaction.
create function ops.guard_session_operational_revision() returns trigger
language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
begin
 if TG_OP='INSERT' then
  if new.operational_revision<>0 then raise exception 'session_correction_revision_private' using errcode='23514';end if;
 elsif new.operational_revision is distinct from old.operational_revision then
  if new.operational_revision<>old.operational_revision+1
   or (to_jsonb(new)-'operational_revision') is distinct from (to_jsonb(old)-'operational_revision')
   or not exists(select 1 from ops.session_corrections c where c.session_id=old.id
      and c.previous_revision=old.operational_revision and c.new_revision=new.operational_revision) then
   raise exception 'session_correction_revision_private' using errcode='23514';
  end if;
 elsif old.operational_revision>0 and
   (new.started_at,new.ended_at) is distinct from (old.started_at,old.ended_at) then
  raise exception 'corrected_session_original_times_immutable' using errcode='23514';
 end if;
 return new;
end;$$;
create trigger session_correction_revision_private before insert or update on ops.irrigation_sessions
 for each row execute function ops.guard_session_operational_revision();

create function ops.guard_session_correction_work() returns trigger
language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
begin
 if TG_OP='DELETE' then raise exception 'session_correction_work_delete_disabled' using errcode='23514';end if;
 if TG_OP='INSERT' then
  if new.status<>'pending' or new.attempt_count<>0 or new.last_attempt_at is not null or new.last_error is not null then
   raise exception 'session_correction_work_must_start_pending' using errcode='23514';end if;
 else
  if (new.correction_id,new.session_id,new.operational_revision,new.created_at) is distinct from
     (old.correction_id,old.session_id,old.operational_revision,old.created_at)
   or new.attempt_count<old.attempt_count or old.status='applied' then
   raise exception 'session_correction_work_identity_immutable' using errcode='23514';end if;
  -- Future financial workers must lock this session before taking work. C1 has
  -- no financial worker and never advances a work item beyond pending.
  perform 1 from ops.irrigation_sessions s where s.id=new.session_id for update;
  if (new.status='applied' or new.attempt_count>old.attempt_count) and exists(
    select 1 from ops.session_correction_reconciliations r where r.session_id=new.session_id
    and r.operational_revision<new.operational_revision and r.status<>'applied') then
   raise exception 'session_correction_financial_revision_out_of_order' using errcode='23514';end if;
  new.updated_at:=clock_timestamp();
 end if;
 return new;
end;$$;
create trigger session_correction_work_guard before insert or update or delete on ops.session_correction_reconciliations
 for each row execute function ops.guard_session_correction_work();

create function ops.accept_session_correction(
 p_session_id uuid,p_command_id uuid,p_base_revision bigint,p_reason text,
 p_desired_started_at timestamptz,p_desired_ended_at timestamptz,p_requested_at timestamptz
) returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $function$
declare
 actor uuid:=auth.uid();tenant uuid;well uuid;s ops.irrigation_sessions%rowtype;
 facts ops.effective_session_facts%rowtype;c sync.processed_commands%rowtype;
 occurrence ops.operational_occurrences%rowtype;
 req jsonb;result jsonb;guard jsonb;correction uuid:=gen_random_uuid();accepted timestamptz;
 start_command uuid;completion_command uuid;commands uuid[];candidate record;completion_ids uuid[]:=array[]::uuid[];
begin
 if actor is null then raise exception 'session_correction_requires_authentication' using errcode='28000';end if;
 select w.tenant_id,sess.well_id into tenant,well from ops.irrigation_sessions sess
 join core.wells w on w.id=sess.well_id where sess.id=p_session_id;
 if tenant is null or not exists(select 1 from core.well_assignments a where a.well_id=well
   and a.profile_id=actor and a.status='active')
   or not coalesce(iam.has_well_permission(well,'session.correct'),false) then
  raise exception 'session_correction_forbidden' using errcode='42501';end if;
 if p_command_id is null then
  raise exception 'session_correction_identity_required' using errcode='22023';end if;
 if current_setting('transaction_isolation')<>'read committed' then
  raise exception 'session_correction_requires_read_committed' using errcode='25000';end if;
 perform ops.lock_operational_scope(well,true);
 select sess.* into s from ops.irrigation_sessions sess where sess.id=p_session_id for update;
 -- Authorization and scope are rechecked after waiting, also on exact replay.
 if not found or s.well_id<>well or not exists(select 1 from core.wells w where w.id=well and w.tenant_id=tenant)
   or not exists(select 1 from core.well_assignments a where a.well_id=well and a.profile_id=actor and a.status='active')
   or not coalesce(iam.has_well_permission(well,'session.correct'),false) then
  raise exception 'session_correction_forbidden' using errcode='42501';end if;
 req:=jsonb_build_object('contract','session_correction','version',1,'tenant_id',tenant,'well_id',well,
  'session_id',p_session_id,'actor_id',actor,'base_revision',p_base_revision,'reason',p_reason,
  'desired_started_at',to_char(p_desired_started_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
  'desired_ended_at',to_char(p_desired_ended_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
  'requested_at',to_char(p_requested_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
 guard:=sync.begin_command(tenant,p_command_id,'correct_irrigation_session',req,p_session_id);
 if coalesce((guard->>'duplicate')::boolean,false) then
  select pc.* into strict c from sync.processed_commands pc where pc.tenant_id=tenant and pc.command_id=p_command_id;
  if c.command_type is distinct from 'correct_irrigation_session' or c.entity_id is distinct from p_session_id
   or c.request_payload is distinct from req then
   raise exception 'session_correction_idempotency_conflict' using errcode='22023';end if;
  if c.status<>'accepted' or not exists(select 1 from ops.session_corrections h
     where h.tenant_id=tenant and h.command_id=p_command_id and h.session_id=p_session_id
       and h.request_payload=req and h.accepted_result=c.response_payload) then
   raise exception 'session_correction_result_unresolved' using errcode='55000';end if;
  return c.response_payload;
 end if;
 if p_base_revision is null or p_base_revision<0 then
  raise exception 'session_correction_identity_required' using errcode='22023';end if;
 if s.operational_revision<>p_base_revision then raise exception 'stale_revision' using errcode='40001';end if;
 select * into strict facts from ops.effective_session_facts where session_id=p_session_id;
 if s.status not in ('closed','forgotten') or facts.effective_started_at is null or facts.effective_ended_at is null
   or not isfinite(facts.effective_started_at) or not isfinite(facts.effective_ended_at)
   or facts.effective_started_at>=facts.effective_ended_at then
  raise exception 'session_correction_completed_facts_required' using errcode='23514';end if;
 if nullif(btrim(p_reason),'') is null then raise exception 'session_correction_reason_required' using errcode='22023';end if;
 if p_desired_started_at is null or p_desired_ended_at is null or not isfinite(p_desired_started_at)
   or not isfinite(p_desired_ended_at) or p_desired_started_at>=p_desired_ended_at
   or p_desired_ended_at>clock_timestamp() then
  raise exception 'session_correction_invalid_times' using errcode='22023';end if;
 if p_requested_at is null or not isfinite(p_requested_at) then
  raise exception 'session_correction_requested_at_required' using errcode='22023';end if;
 -- Original topology must be complete, contiguous and bound to original facts.
 -- Only the two outer boundaries are substituted, including a one-segment case.
 if not exists(select 1 from ops.session_segments seg where seg.session_id=p_session_id)
  or exists(select 1 from (
   select seg.*,row_number() over(order by sequence_number) as n,
    count(*) over() as total,lag(ended_at) over(order by sequence_number) as prior_end
   from ops.session_segments seg where seg.session_id=p_session_id) topology
   where topology.tenant_id<>tenant or topology.sequence_number<>topology.n
    or topology.ended_at is null or not isfinite(topology.started_at) or not isfinite(topology.ended_at)
    or topology.started_at>=topology.ended_at
    or (topology.n=1 and topology.started_at is distinct from s.started_at)
    or (topology.n=topology.total and topology.ended_at is distinct from s.ended_at)
    or (topology.n>1 and topology.started_at is distinct from topology.prior_end)
    or (case when topology.n=1 then p_desired_started_at else topology.started_at end)
      >=(case when topology.n=topology.total then p_desired_ended_at else topology.ended_at end)) then
  raise exception 'session_correction_segment_boundary_invalid' using errcode='23514';end if;
 -- Same actual resource authority as R6-A: well OR pump; never booking time.
 -- Positive revisions with missing history fail closed rather than using originals.
 if exists(select 1 from ops.irrigation_sessions other join ops.effective_session_facts ef on ef.session_id=other.id
   where other.id<>s.id and (other.well_id=well or other.pump_id=s.pump_id)
    and (ef.effective_started_at is null or (other.status<>'open' and ef.effective_ended_at is null))) then
  raise exception 'session_correction_resource_facts_unresolved' using errcode='23514';end if;
 if exists(select 1 from ops.irrigation_sessions other join ops.effective_session_facts ef on ef.session_id=other.id
   where other.id<>s.id and (other.well_id=well or other.pump_id=s.pump_id)
    and tstzrange(ef.effective_started_at,ef.effective_ended_at,'[)')
       &&tstzrange(p_desired_started_at,p_desired_ended_at,'[)')) then
  raise exception 'session_correction_resource_overlap' using errcode='23514';end if;
 select o.* into occurrence from ops.operational_occurrences o where o.tenant_id=tenant
  and o.well_id=well and o.server_session_id=p_session_id and o.status='accepted';
 if found then
  start_command:=occurrence.original_request_id;
  completion_command:=occurrence.completion_command_id;
 else
  -- Legacy command references are optional evidence, never manufactured IDs.
  select array_agg(pc.command_id) into commands from sync.processed_commands pc
   where pc.tenant_id=tenant and pc.status='accepted'
    and pc.command_type in ('start_operational_session','start_irrigation_session','start_adhoc_session','start_irrigation_session_from_booking')
    and (pc.entity_id is null or pc.entity_id=well or pc.entity_id=s.booking_id)
    and (not coalesce(pc.request_payload ? 'well_id',false) or pc.request_payload->>'well_id'=well::text)
    and (not coalesce(pc.response_payload ? 'well_id',false) or pc.response_payload->>'well_id'=well::text)
    and (pc.response_payload->>'id'=p_session_id::text or pc.response_payload->>'session_id'=p_session_id::text);
  if cardinality(commands)=1 then start_command:=commands[1];end if;
 end if;
 if completion_command is null then
  for candidate in select pc.command_id,pc.response_payload from sync.processed_commands pc
   where pc.tenant_id=tenant and pc.entity_id=p_session_id and pc.status='accepted'
    and pc.command_type in ('complete_irrigation_session','complete_booking_session')
    and pc.response_payload->>'session_id'=p_session_id::text and pc.response_payload->>'status'='closed'
    and exists(select 1 from billing.session_charges ch where ch.session_id=p_session_id
      and ch.id::text=pc.response_payload->>'session_charge_id') loop
   begin
    if (candidate.response_payload->>'ended_at')::timestamptz=s.ended_at then
     completion_ids:=array_append(completion_ids,candidate.command_id);end if;
   exception when invalid_text_representation or invalid_datetime_format or datetime_field_overflow then null;
   end;
  end loop;
  if cardinality(completion_ids)=1 then completion_command:=completion_ids[1];end if;
 end if;
 accepted:=clock_timestamp();
 result:=jsonb_build_object('contract','session_correction','version',1,'status','accepted',
  'tenant_id',tenant,'well_id',well,'session_id',p_session_id,'command_id',p_command_id,'correction_id',correction,
  'previous_revision',s.operational_revision,'operational_revision',s.operational_revision+1,
  'actual_started_at',p_desired_started_at,'actual_ended_at',p_desired_ended_at,
  'accepted_at',accepted,'financial_status','pending');
 insert into ops.session_corrections(id,tenant_id,well_id,session_id,command_id,previous_revision,new_revision,
  before_started_at,before_ended_at,after_started_at,after_ended_at,reason,actor_id,requested_at,accepted_at,
  occurrence_command_id,original_start_command_id,original_completion_command_id,request_payload,accepted_result)
 values(correction,tenant,well,p_session_id,p_command_id,s.operational_revision,s.operational_revision+1,
  facts.effective_started_at,facts.effective_ended_at,p_desired_started_at,p_desired_ended_at,p_reason,actor,p_requested_at,accepted,
  occurrence.occurrence_command_id,start_command,completion_command,req,result);
 update ops.irrigation_sessions set operational_revision=s.operational_revision+1 where id=p_session_id;
 insert into ops.session_correction_reconciliations(correction_id,session_id,operational_revision)
 values(correction,p_session_id,s.operational_revision+1);
 perform sync.finish_command(tenant,p_command_id,'accepted',result);
 return result;
end;$function$;

revoke all on function ops.accept_session_correction(uuid,uuid,bigint,text,timestamptz,timestamptz,timestamptz),
 ops.reject_session_correction_history_mutation(),ops.guard_session_operational_revision(),ops.guard_session_correction_work()
 from public,anon,authenticated,service_role;
comment on function ops.accept_session_correction(uuid,uuid,bigint,text,timestamptz,timestamptz,timestamptz) is
 'R6-C1 private acceptance: full desired operational pair; original facts/receipts immutable; financial work pending. No public grant before C4.';
commit;
