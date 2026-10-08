-- PRE-PRODUCTION fixture only: resolve the one known preflight ambiguity
-- before 20261001034419 publishes the exactly-one-active-pump invariant.
-- No rows are deleted and no application user is changed.
begin;

do $fixture$
declare
  v_tenant_id uuid;
  v_active_count integer;
  v_changed boolean := false;
begin
  select w.tenant_id into v_tenant_id
  from core.wells w
  where w.id = 'dc84a15e-9894-4bbd-8830-dbb907397344'::uuid;

  -- Local reset does not contain the Cloud-only fixture: it is a no-op there.
  if v_tenant_id is null then
    return;
  end if;

  select count(*) into v_active_count
  from core.pumps p
  where p.well_id = 'dc84a15e-9894-4bbd-8830-dbb907397344'::uuid
    and p.status = 'active';

  if v_active_count = 2
     and exists (
       select 1 from core.pumps p
       where p.id = '6e795d36-8679-49f6-a510-9ffcbb951c96'::uuid
         and p.well_id = 'dc84a15e-9894-4bbd-8830-dbb907397344'::uuid
         and p.status = 'active'
     ) then
    update core.pumps
    set status = 'inactive', updated_at = clock_timestamp()
    where id = '6e795d36-8679-49f6-a510-9ffcbb951c96'::uuid
      and well_id = 'dc84a15e-9894-4bbd-8830-dbb907397344'::uuid
      and status = 'active';
    v_changed := found;
  elsif v_active_count = 1
        and exists (
          select 1 from core.pumps p
          where p.id = '6e795d36-8679-49f6-a510-9ffcbb951c96'::uuid
            and p.well_id = 'dc84a15e-9894-4bbd-8830-dbb907397344'::uuid
            and p.status = 'inactive'
        ) then
    -- Idempotent rerun after a partially completed pre-production attempt.
    null;
  else
    raise exception 'P2 fixture preflight changed unexpectedly for well %',
      'dc84a15e-9894-4bbd-8830-dbb907397344';
  end if;

  if v_changed then
    insert into audit.audit_logs (
      tenant_id, well_id, user_id, action, entity_type, entity_id,
      new_values, reason
    ) values (
      v_tenant_id,
      'dc84a15e-9894-4bbd-8830-dbb907397344'::uuid,
      null,
      'p2_cloud_fixture_normalized',
      'core.pumps',
      '6e795d36-8679-49f6-a510-9ffcbb951c96'::uuid,
      jsonb_build_object('status', 'inactive'),
      'PRE-PRODUCTION TEST ONLY: resolve multiple active pumps before '
      || 'booking execution contract migration'
    );
  end if;
end;
$fixture$;

commit;
