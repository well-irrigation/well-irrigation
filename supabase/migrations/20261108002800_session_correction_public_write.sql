begin;

-- R6-C2B write activation only. Authorization, canonical request identity,
-- exact replay, stale-revision rejection and pending work remain owned by C1.
create function api.correct_irrigation_session(
 p_session_id uuid,
 p_command_id uuid,
 p_base_revision bigint,
 p_reason text,
 p_desired_started_at timestamptz,
 p_desired_ended_at timestamptz,
 p_requested_at timestamptz
)
returns jsonb
language sql volatile security invoker
set search_path=pg_catalog,pg_temp
as $function$
 select ops.accept_session_correction(
  p_session_id,p_command_id,p_base_revision,p_reason,
  p_desired_started_at,p_desired_ended_at,p_requested_at
 );
$function$;

-- INVOKER bridge into the existing authenticated/permission-checked contract.
-- ops is not a Data API exposed schema; no table write grants are introduced.
revoke all on function ops.accept_session_correction(uuid,uuid,bigint,text,timestamptz,timestamptz,timestamptz)
 from public,anon;
grant execute on function ops.accept_session_correction(uuid,uuid,bigint,text,timestamptz,timestamptz,timestamptz)
 to authenticated,service_role;

revoke all on function api.correct_irrigation_session(uuid,uuid,bigint,text,timestamptz,timestamptz,timestamptz)
 from public,anon,authenticated,service_role;
grant execute on function api.correct_irrigation_session(uuid,uuid,bigint,text,timestamptz,timestamptz,timestamptz)
 to authenticated,service_role;

commit;
