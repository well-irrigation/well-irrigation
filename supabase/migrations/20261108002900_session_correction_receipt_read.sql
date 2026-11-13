begin;

-- R6-C2B recovery is historical proof, never execution or retry authority.
-- Only this reader needs owner access to processed commands. Authenticate and
-- authorize the requested session before looking up any command/history row.
create function sync.get_session_correction_receipt_read(
 p_session_id uuid,
 p_command_id uuid
)
returns jsonb
language plpgsql stable security definer
set search_path=pg_catalog,pg_temp
as $function$
declare
 v_actor uuid:=auth.uid();
 v_well uuid;v_tenant uuid;
 v_command sync.processed_commands%rowtype;
 v_history ops.session_corrections%rowtype;
 v_history_count bigint;
 v_result jsonb;v_request jsonb;v_canonical_request jsonb;v_receipt jsonb;
 v_request_actor uuid;v_base_revision bigint;v_reason text;
 v_desired_start timestamptz;v_desired_end timestamptz;v_requested_at timestamptz;
begin
 if v_actor is null then
  raise exception 'session_correction_receipt_requires_authentication' using errcode='28000';
 end if;
 if p_session_id is null or p_command_id is null then
  raise exception 'session_correction_receipt_invalid_inputs' using errcode='22023';
 end if;
 select s.well_id,w.tenant_id into v_well,v_tenant
 from ops.irrigation_sessions s join core.wells w on w.id=s.well_id
 where s.id=p_session_id;
 if v_well is null or v_tenant is null
  or not exists(select 1 from core.well_assignments a
    where a.well_id=v_well and a.profile_id=v_actor and a.status='active')
  or not coalesce(iam.has_well_permission(v_well,'session.correct'),false) then
  raise exception 'session_correction_receipt_forbidden' using errcode='42501';
 end if;

 v_result:=jsonb_build_object('contract','get_session_correction_receipt','version',1,
  'session_id',p_session_id,'command_id',p_command_id,
  'command_type','correct_irrigation_session','status','unresolved',
  'receipt',null,'retry_authorized',false);
 select pc.* into v_command from sync.processed_commands pc
 where pc.tenant_id=v_tenant and pc.command_id=p_command_id;
 if not found then
  -- History without its processed command is incomplete proof, not absence.
  if exists(select 1 from ops.session_corrections h
    where h.tenant_id=v_tenant and h.well_id=v_well
      and h.session_id=p_session_id and h.command_id=p_command_id) then
   return v_result;
  end if;
  return v_result||jsonb_build_object('status','not_found');
 end if;
 if v_command.entity_id is distinct from p_session_id then
  -- Mask a command belonging elsewhere as absent in the requested scope.
  -- A matching local history row instead proves contradictory local evidence.
  if exists(select 1 from ops.session_corrections h
    where h.tenant_id=v_tenant and h.well_id=v_well
      and h.session_id=p_session_id and h.command_id=p_command_id) then
   return v_result;
  end if;
  return v_result||jsonb_build_object('status','not_found');
 end if;
 if v_command.tenant_id is distinct from v_tenant
  or v_command.command_id is distinct from p_command_id
  or v_command.command_type is distinct from 'correct_irrigation_session' then
  return v_result;
 end if;

 v_request:=v_command.request_payload;
 if jsonb_typeof(v_request) is distinct from 'object'
  or v_request->'contract' is distinct from to_jsonb('session_correction'::text)
  or v_request->'version' is distinct from '1'::jsonb
  or v_request->'tenant_id' is distinct from to_jsonb(v_tenant)
  or v_request->'well_id' is distinct from to_jsonb(v_well)
  or v_request->'session_id' is distinct from to_jsonb(p_session_id)
  or jsonb_typeof(v_request->'actor_id') is distinct from 'string'
  or jsonb_typeof(v_request->'base_revision') is distinct from 'number'
  or jsonb_typeof(v_request->'reason') is distinct from 'string'
  or jsonb_typeof(v_request->'desired_started_at') is distinct from 'string'
  or jsonb_typeof(v_request->'desired_ended_at') is distinct from 'string'
  or jsonb_typeof(v_request->'requested_at') is distinct from 'string' then
  return v_result;
 end if;

 -- Malformed persisted proof is unresolved. These handlers cover data parsing
 -- only; authentication/authorization errors above are deliberately not hidden.
 begin
  v_request_actor:=(v_request->>'actor_id')::uuid;
  v_base_revision:=(v_request->>'base_revision')::bigint;
  v_reason:=v_request->>'reason';
  v_desired_start:=(v_request->>'desired_started_at')::timestamptz;
  v_desired_end:=(v_request->>'desired_ended_at')::timestamptz;
  v_requested_at:=(v_request->>'requested_at')::timestamptz;
  if v_request_actor is null or v_base_revision is null or v_base_revision<0
   or nullif(btrim(v_reason),'') is null
   or not isfinite(v_desired_start) or not isfinite(v_desired_end)
   or not isfinite(v_requested_at) or v_desired_start>=v_desired_end
   or not exists(select 1 from iam.profiles p where p.id=v_request_actor) then
   return v_result;
  end if;
  -- Match C1's immutable request format, including microseconds and UTC. The
  -- stored actor is historical identity, not the identity of the current reader.
  v_canonical_request:=jsonb_build_object('contract','session_correction','version',1,
   'tenant_id',v_tenant,'well_id',v_well,'session_id',p_session_id,'actor_id',v_request_actor,
   'base_revision',v_base_revision,'reason',v_reason,
   'desired_started_at',to_char(v_desired_start at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
   'desired_ended_at',to_char(v_desired_end at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
   'requested_at',to_char(v_requested_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
  if v_request is distinct from v_canonical_request then return v_result;end if;

  select count(*) into v_history_count from ops.session_corrections h
  where h.tenant_id=v_tenant and h.well_id=v_well
    and h.session_id=p_session_id and h.command_id=p_command_id;
  if v_command.status='processing' then
   if v_command.response_payload is null and v_history_count=0 then
    return v_result||jsonb_build_object('status','processing');
   end if;
   return v_result;
  end if;
  if v_command.status is distinct from 'accepted'
   or jsonb_typeof(v_command.response_payload) is distinct from 'object'
   or v_history_count<>1 then return v_result;end if;

  select h.* into v_history from ops.session_corrections h
  where h.tenant_id=v_tenant and h.well_id=v_well
    and h.session_id=p_session_id and h.command_id=p_command_id;
  if v_history.request_payload is distinct from v_request
   or v_history.accepted_result is distinct from v_command.response_payload
   or v_history.actor_id is distinct from v_request_actor
   or v_history.previous_revision is distinct from v_base_revision
   or v_history.new_revision-v_history.previous_revision<>1
   or v_history.reason is distinct from v_reason
   or v_history.after_started_at is distinct from v_desired_start
   or v_history.after_ended_at is distinct from v_desired_end
   or v_history.requested_at is distinct from v_requested_at then
   return v_result;
  end if;

  v_receipt:=v_history.accepted_result;
  if jsonb_typeof(v_receipt) is distinct from 'object'
   or v_receipt->'contract' is distinct from to_jsonb('session_correction'::text)
   or v_receipt->'version' is distinct from '1'::jsonb
   or v_receipt->'status' is distinct from to_jsonb('accepted'::text)
   or v_receipt->'tenant_id' is distinct from to_jsonb(v_tenant)
   or v_receipt->'well_id' is distinct from to_jsonb(v_well)
   or v_receipt->'session_id' is distinct from to_jsonb(p_session_id)
   or v_receipt->'command_id' is distinct from to_jsonb(p_command_id)
   or v_receipt->'correction_id' is distinct from to_jsonb(v_history.id)
   or v_receipt->'previous_revision' is distinct from to_jsonb(v_history.previous_revision)
   or v_receipt->'operational_revision' is distinct from to_jsonb(v_history.new_revision)
   or v_receipt->'financial_status' is distinct from to_jsonb('pending'::text)
   or jsonb_typeof(v_receipt->'actual_started_at') is distinct from 'string'
   or jsonb_typeof(v_receipt->'actual_ended_at') is distinct from 'string'
   or jsonb_typeof(v_receipt->'accepted_at') is distinct from 'string' then
   return v_result;
  end if;
  -- Compare timestamptz values, not timezone-dependent JSON spelling. Return
  -- the stored JSON verbatim; never rebuild it in the reader's timezone.
  if (v_receipt->>'actual_started_at')::timestamptz is distinct from v_history.after_started_at
   or (v_receipt->>'actual_ended_at')::timestamptz is distinct from v_history.after_ended_at
   or (v_receipt->>'accepted_at')::timestamptz is distinct from v_history.accepted_at then
   return v_result;
  end if;
  return v_result||jsonb_build_object('status','accepted','receipt',v_receipt);
 exception when invalid_text_representation or numeric_value_out_of_range
   or invalid_datetime_format or datetime_field_overflow then
  return v_result;
 end;
end;$function$;

create function api.get_session_correction_receipt(
 p_session_id uuid,
 p_command_id uuid
)
returns jsonb
language sql stable security invoker
set search_path=pg_catalog,pg_temp
as $function$
 select sync.get_session_correction_receipt_read(p_session_id,p_command_id);
$function$;

revoke all on function sync.get_session_correction_receipt_read(uuid,uuid),
 api.get_session_correction_receipt(uuid,uuid)
 from public,anon,authenticated,service_role;
grant execute on function sync.get_session_correction_receipt_read(uuid,uuid),
 api.get_session_correction_receipt(uuid,uuid)
 to authenticated,service_role;

commit;
