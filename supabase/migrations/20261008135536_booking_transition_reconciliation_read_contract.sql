begin;

-- P2 mobile reconciliation: this is deliberately a read-only projection of
-- canonical P1-B/P2 evidence. It never begins a command and never executes a
-- transition. The phone supplies only the intent fields it was allowed to see.
create function sync.get_booking_transition_reconciliation_read(
  p_well_id uuid,
  p_chain_id uuid,
  p_current_session_id uuid,
  p_next_booking_id uuid,
  p_decision_revision bigint,
  p_automation_revision bigint,
  p_command_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_tenant_id uuid;
  v_exact sync.processed_commands%rowtype;
  v_candidate sync.processed_commands%rowtype;
  v_candidate_count integer := 0;
  v_has_accepted_candidate boolean := false;
  v_match_kind text;
  v_result text := 'accepted';
  v_closed_session ops.irrigation_sessions%rowtype;
  v_started_session ops.irrigation_sessions%rowtype;
  v_receipt jsonb;
begin
  if p_well_id is null
     or p_chain_id is null
     or p_current_session_id is null
     or p_next_booking_id is null
     or p_decision_revision is null
     or p_automation_revision is null
     or p_command_id is null then
    raise exception 'booking_transition_reconciliation_inputs_required'
      using errcode = '22023';
  end if;

  if v_actor is null then
    raise exception 'booking_transition_reconciliation_requires_authentication'
      using errcode = '28000';
  end if;

  if not iam.has_well_permission(p_well_id, 'booking.read') then
    raise exception 'booking_transition_reconciliation_forbidden'
      using errcode = '42501';
  end if;

  select w.tenant_id into v_tenant_id
  from core.wells w
  where w.id = p_well_id;

  if not found then
    raise exception 'booking_transition_reconciliation_well_not_found'
      using errcode = '22023';
  end if;

  -- A command id is only an exact match when its canonical fingerprint also
  -- proves the complete phone-visible intent. A command collision/mismatch is
  -- never treated as a receipt.
  select pc.* into v_exact
  from sync.processed_commands pc
  where pc.tenant_id = v_tenant_id
    and pc.command_id = p_command_id;

  if found then
    if v_exact.command_type <> 'execute_booking_transition'
       or v_exact.intent_fingerprint is null
       or not (v_exact.intent_fingerprint @> jsonb_build_object(
         'tenant_id', v_tenant_id,
         'well_id', p_well_id,
         'chain_id', p_chain_id,
         'current_session_id', p_current_session_id,
         'next_booking_id', p_next_booking_id,
         'decision_revision', p_decision_revision,
         'automation_revision', p_automation_revision,
         'actor_kind', 'system',
         'actor_ref', 'booking_automation_system'
       )) then
      return jsonb_build_object(
        'contract', 'get_booking_transition_reconciliation',
        'version', 1,
        'status', 'rejected',
        'match_kind', null,
        'requested_command_id', p_command_id,
        'canonical_command_id', null,
        'well_id', p_well_id,
        'chain_id', p_chain_id,
        'current_session_id', p_current_session_id,
        'next_booking_id', p_next_booking_id,
        'decision_revision', p_decision_revision,
        'automation_revision', p_automation_revision,
        'canonical_result', null,
        'business_receipt', null,
        'review_reason', 'intent_mismatch'
      );
    end if;

    if v_exact.status = 'accepted' then
      v_candidate := v_exact;
      v_match_kind := 'exact_command';
      v_has_accepted_candidate := true;
    end if;
  end if;

  if not v_has_accepted_candidate then
    -- The executor treats a complete logical intent as idempotent across a
    -- different command id. We make the same lookup read-only and reject an
    -- ambiguous result rather than hiding it with LIMIT 1.
    select count(*) into v_candidate_count
    from sync.processed_commands pc
    where pc.tenant_id = v_tenant_id
      and pc.command_type = 'execute_booking_transition'
      and pc.status = 'accepted'
      and pc.intent_fingerprint @> jsonb_build_object(
        'tenant_id', v_tenant_id,
        'well_id', p_well_id,
        'chain_id', p_chain_id,
        'current_session_id', p_current_session_id,
        'next_booking_id', p_next_booking_id,
        'decision_revision', p_decision_revision,
        'automation_revision', p_automation_revision,
        'actor_kind', 'system',
        'actor_ref', 'booking_automation_system'
      );

    if v_candidate_count = 0 then
      -- Rejection evidence is exact-command only. A rejected attempt never
      -- hides an accepted canonical receipt, and a different rejected command
      -- never becomes a logical match.
      if exists (
        select 1
        from audit.booking_automation_attempts a
        where a.tenant_id = v_tenant_id
          and a.well_id = p_well_id
          and a.chain_id = p_chain_id
          and a.current_session_id = p_current_session_id
          and a.next_booking_id = p_next_booking_id
          and a.decision_revision = p_decision_revision
          and a.automation_revision = p_automation_revision
          and a.command_id = p_command_id
          and a.result = 'rejected'
      ) then
        return jsonb_build_object(
          'contract', 'get_booking_transition_reconciliation',
          'version', 1,
          'status', 'rejected',
          'match_kind', 'exact_command',
          'requested_command_id', p_command_id,
          'canonical_command_id', p_command_id,
          'well_id', p_well_id,
          'chain_id', p_chain_id,
          'current_session_id', p_current_session_id,
          'next_booking_id', p_next_booking_id,
          'decision_revision', p_decision_revision,
          'automation_revision', p_automation_revision,
          'canonical_result', 'rejected',
          'business_receipt', null,
          'review_reason', 'canonical_rejected'
        );
      end if;

      return jsonb_build_object(
        'contract', 'get_booking_transition_reconciliation',
        'version', 1,
        'status', 'not_found',
        'match_kind', null,
        'requested_command_id', p_command_id,
        'canonical_command_id', null,
        'well_id', p_well_id,
        'chain_id', p_chain_id,
        'current_session_id', p_current_session_id,
        'next_booking_id', p_next_booking_id,
        'decision_revision', p_decision_revision,
        'automation_revision', p_automation_revision,
        'canonical_result', null,
        'business_receipt', null,
        'review_reason', 'not_found'
      );
    elsif v_candidate_count > 1 then
      return jsonb_build_object(
        'contract', 'get_booking_transition_reconciliation',
        'version', 1,
        'status', 'conflict',
        'match_kind', null,
        'requested_command_id', p_command_id,
        'canonical_command_id', null,
        'well_id', p_well_id,
        'chain_id', p_chain_id,
        'current_session_id', p_current_session_id,
        'next_booking_id', p_next_booking_id,
        'decision_revision', p_decision_revision,
        'automation_revision', p_automation_revision,
        'canonical_result', null,
        'business_receipt', null,
        'review_reason', 'ambiguous_canonical_intent'
      );
    end if;

    select pc.* into v_candidate
    from sync.processed_commands pc
    where pc.tenant_id = v_tenant_id
      and pc.command_type = 'execute_booking_transition'
      and pc.status = 'accepted'
      and pc.intent_fingerprint @> jsonb_build_object(
        'tenant_id', v_tenant_id,
        'well_id', p_well_id,
        'chain_id', p_chain_id,
        'current_session_id', p_current_session_id,
        'next_booking_id', p_next_booking_id,
        'decision_revision', p_decision_revision,
        'automation_revision', p_automation_revision,
        'actor_kind', 'system',
        'actor_ref', 'booking_automation_system'
      );
    v_match_kind := 'logical_intent';
  end if;

  -- The processed command is the receipt source. Rows in ops only validate
  -- that the small receipt projection still names the stated well/bookings.
  select s.* into v_closed_session
  from ops.irrigation_sessions s
  where s.id = (v_candidate.response_payload ->> 'closed_session_id')::uuid
    and s.id = p_current_session_id
    and s.well_id = p_well_id;

  select s.* into v_started_session
  from ops.irrigation_sessions s
  where s.id = (v_candidate.response_payload ->> 'started_session_id')::uuid
    and s.well_id = p_well_id
    and s.booking_id = p_next_booking_id;

  if v_closed_session.id is null
     or v_closed_session.id is distinct from p_current_session_id
     or v_started_session.id is null
     or (v_candidate.response_payload ->> 'closed_session_id')::uuid
          is distinct from p_current_session_id
     or (v_candidate.response_payload ->> 'well_id')::uuid
          is distinct from p_well_id
     or (v_candidate.response_payload ->> 'started_booking_id')::uuid
          is distinct from p_next_booking_id then
    return jsonb_build_object(
      'contract', 'get_booking_transition_reconciliation',
      'version', 1,
      'status', 'conflict',
      'match_kind', v_match_kind,
      'requested_command_id', p_command_id,
      'canonical_command_id', v_candidate.command_id,
      'well_id', p_well_id,
      'chain_id', p_chain_id,
      'current_session_id', p_current_session_id,
      'next_booking_id', p_next_booking_id,
      'decision_revision', p_decision_revision,
      'automation_revision', p_automation_revision,
      'canonical_result', null,
      'business_receipt', null,
      'review_reason', 'server_state_changed'
    );
  end if;

  if exists (
    select 1
    from audit.booking_automation_attempts a
    where a.tenant_id = v_tenant_id
      and a.command_id = v_candidate.command_id
      and a.result = 'replayed'
  ) then
    v_result := 'replayed';
  end if;

  v_receipt := jsonb_build_object(
    'well_id', p_well_id,
    'closed_session', jsonb_build_object(
      'id', v_closed_session.id,
      'ended_at', v_closed_session.ended_at
    ),
    'started_session', jsonb_build_object(
      'id', v_started_session.id,
      'booking_id', v_started_session.booking_id,
      'started_at', v_started_session.started_at
    )
  );

  return jsonb_build_object(
    'contract', 'get_booking_transition_reconciliation',
    'version', 1,
    'status', 'found',
    'match_kind', v_match_kind,
    'requested_command_id', p_command_id,
    'canonical_command_id', v_candidate.command_id,
    'well_id', p_well_id,
    'chain_id', p_chain_id,
    'current_session_id', p_current_session_id,
    'next_booking_id', p_next_booking_id,
    'decision_revision', p_decision_revision,
    'automation_revision', p_automation_revision,
    'canonical_result', v_result,
    'business_receipt', v_receipt,
    'review_reason', null
  );
end;
$function$;

comment on function sync.get_booking_transition_reconciliation_read(
  uuid, uuid, uuid, uuid, bigint, bigint, uuid
) is
  'P2 mobile: read-only reconciliation of provisional phone evidence against canonical P1-B/P2 receipts. It never starts commands, creates aliases, or executes business transitions.';

revoke all on function sync.get_booking_transition_reconciliation_read(
  uuid, uuid, uuid, uuid, bigint, bigint, uuid
) from public, anon, authenticated, service_role,
       booking_automation_executor;
grant execute on function sync.get_booking_transition_reconciliation_read(
  uuid, uuid, uuid, uuid, bigint, bigint, uuid
) to authenticated, service_role;
grant usage on schema sync to authenticated, service_role;

-- The exposed API remains SECURITY INVOKER. It has no direct table grants;
-- the narrowly scoped internal reader repeats the authentication and read
-- guard before it can inspect internal canonical evidence.
create function api.get_booking_transition_reconciliation(
  p_well_id uuid,
  p_chain_id uuid,
  p_current_session_id uuid,
  p_next_booking_id uuid,
  p_decision_revision bigint,
  p_automation_revision bigint,
  p_command_id uuid
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
begin
  if p_well_id is null
     or p_chain_id is null
     or p_current_session_id is null
     or p_next_booking_id is null
     or p_decision_revision is null
     or p_automation_revision is null
     or p_command_id is null then
    raise exception 'booking_transition_reconciliation_inputs_required'
      using errcode = '22023';
  end if;

  if auth.uid() is null then
    raise exception 'booking_transition_reconciliation_requires_authentication'
      using errcode = '28000';
  end if;

  if not iam.has_well_permission(p_well_id, 'booking.read') then
    raise exception 'booking_transition_reconciliation_forbidden'
      using errcode = '42501';
  end if;

  return sync.get_booking_transition_reconciliation_read(
    p_well_id,
    p_chain_id,
    p_current_session_id,
    p_next_booking_id,
    p_decision_revision,
    p_automation_revision,
    p_command_id
  );
end;
$function$;

comment on function api.get_booking_transition_reconciliation(
  uuid, uuid, uuid, uuid, bigint, bigint, uuid
) is
  'P2 mobile public read-only reconciliation contract. Delegates to a guarded internal reader and never executes business transitions.';

revoke all on function api.get_booking_transition_reconciliation(
  uuid, uuid, uuid, uuid, bigint, bigint, uuid
) from public, anon, authenticated, service_role,
       booking_automation_executor;
grant execute on function api.get_booking_transition_reconciliation(
  uuid, uuid, uuid, uuid, bigint, bigint, uuid
) to authenticated, service_role;

-- This migration adds no table privileges. `sync.processed_commands` retains
-- its pre-existing authenticated read grant from migration 058, which legacy
-- database assertions still use under RLS. The reconciliation contract never
-- exposes its raw payload. The automation audit has no application-role read
-- grant.

commit;
