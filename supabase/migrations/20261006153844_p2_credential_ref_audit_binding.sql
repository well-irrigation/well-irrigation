-- Cloud Phase 2: the Edge adapter sets this non-secret version label only
-- after validating its credential. The DB keeps the Phase 1 default when
-- called by the local technical proof.
begin;

do $ref$
declare
  v_oid regprocedure :=
    'ops.execute_booking_transition_automation(uuid,uuid,uuid,uuid,bigint,bigint,bigint,uuid,uuid,uuid)'::regprocedure;
  v_definition text;
  v_changed text;
begin
  select pg_get_functiondef(v_oid) into v_definition;
  v_changed := replace(
    v_definition,
    $old$'vault:p2-booking-automation:v1'$old$,
    $new$coalesce(
      nullif(current_setting('well_irrigation.credential_ref', true), ''),
      'vault:p2-booking-automation:v1'
    )$new$
  );
  if v_changed = v_definition then
    raise exception 'P2 credential_ref audit anchor missing';
  end if;
  execute v_changed;
end;
$ref$;

commit;
