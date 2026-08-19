-- =====================================================================
-- 079 — W1-02 / م-16
-- Farmer self-scope authorization
-- =====================================================================

begin;

create function iam.current_farmer_well_account_id(p_well_id uuid)
returns uuid
language sql
stable
security definer
set search_path = pg_catalog, pg_temp
as $function$
  select fwa.id
  from ops.farmer_well_accounts fwa
  join ops.farmer_profiles fp
    on fp.id = fwa.farmer_profile_id
   and fp.tenant_id = fwa.tenant_id
  join core.wells w
    on w.id = fwa.well_id
   and w.tenant_id = fwa.tenant_id
  join iam.profile_person_links l
    on l.tenant_id = fwa.tenant_id
   and l.person_id = fp.person_id
   and l.profile_id = auth.uid()
   and l.revoked_at is null
  join core.persons p
    on p.id = fp.person_id
   and p.tenant_id = fwa.tenant_id
  where fwa.well_id = p_well_id
    and fwa.status = 'active'
    and fp.status = 'active'
    and p.status = 'active';
$function$;

comment on function iam.current_farmer_well_account_id(uuid) is
  'W1-02: يعيد Farmer Well Account الفعالة الخاصة بهوية الحساب الحالية داخل البئر دون تخمين.';

revoke all on function iam.current_farmer_well_account_id(uuid)
from public, anon, authenticated, service_role;
grant execute on function iam.current_farmer_well_account_id(uuid)
to authenticated;

create function iam.has_farmer_self_access(p_well_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
  select iam.current_farmer_well_account_id(p_well_id) is not null;
$function$;

revoke all on function iam.has_farmer_self_access(uuid)
from public, anon, authenticated, service_role;
grant execute on function iam.has_farmer_self_access(uuid)
to authenticated;

create function iam.can_staff_read_profile(p_profile_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, pg_temp
as $function$
  select exists (
    select 1
    from core.well_assignments mine
    join core.well_assignments theirs
      on theirs.well_id = mine.well_id
    where mine.profile_id = auth.uid()
      and mine.status = 'active'
      and mine.role = any(array['owner','manager','operator'])
      and theirs.profile_id = p_profile_id
      and theirs.status = 'active'
  );
$function$;

revoke all on function iam.can_staff_read_profile(uuid)
from public, anon, authenticated, service_role;
grant execute on function iam.can_staff_read_profile(uuid)
to authenticated;

create index if not exists idx_wells_tenant_id on core.wells (tenant_id);
create index if not exists idx_wells_location_id on core.wells (location_id) where location_id is not null;
create index if not exists idx_person_aliases_person on core.person_aliases (tenant_id, person_id);
create index if not exists idx_person_contacts_person on core.person_contacts (tenant_id, person_id);
create index if not exists idx_pump_line_links_pump on core.pump_line_links (pump_id);
create index if not exists idx_irrigation_bookings_farmer_account on ops.irrigation_bookings (farmer_well_account_id);
create index if not exists idx_booking_status_history_booking on ops.booking_status_history (booking_id);
create index if not exists idx_resource_reservations_booking on ops.resource_reservations (booking_id) where booking_id is not null;
create index if not exists idx_resource_reservations_session on ops.resource_reservations (session_id) where session_id is not null;

drop policy if exists profiles_select_self_or_colleague on iam.profiles;
create policy profiles_select_self_or_staff_colleague on iam.profiles
for select to authenticated
using (id = (select auth.uid()) or iam.can_staff_read_profile(id));

drop policy if exists wells_select_assigned on core.wells;
drop policy if exists wells_select_assigned_manager on core.wells;
create policy wells_select_staff_or_farmer_self on core.wells
for select to authenticated
using (
  iam.has_well_role(id, array['owner','manager','operator'])
  or iam.has_farmer_self_access(id)
);

drop policy if exists tenants_select_assigned on core.tenants;
drop policy if exists tenants_select_assigned_manager on core.tenants;
create policy tenants_select_staff_or_farmer_self on core.tenants
for select to authenticated
using (
  exists (
    select 1 from core.wells w
    where w.tenant_id = tenants.id
      and (
        iam.has_well_role(w.id, array['owner','manager','operator'])
        or iam.has_farmer_self_access(w.id)
      )
  )
);

drop policy if exists locations_select_assigned on core.locations;
drop policy if exists locations_select_assigned_manager on core.locations;
create policy locations_select_staff_or_farmer_self on core.locations
for select to authenticated
using (
  exists (
    select 1 from core.wells w
    where w.tenant_id = locations.tenant_id
      and (
        iam.has_well_role(w.id, array['owner','manager','operator'])
        or (w.location_id = locations.id and iam.has_farmer_self_access(w.id))
      )
  )
);

drop policy if exists pumps_select_assigned on core.pumps;
drop policy if exists pumps_select_assigned_manager on core.pumps;
create policy pumps_select_staff_or_farmer_self on core.pumps
for select to authenticated
using (
  iam.has_well_role(well_id, array['owner','manager','operator'])
  or iam.has_farmer_self_access(well_id)
);

drop policy if exists water_lines_select_assigned on core.water_lines;
drop policy if exists water_lines_select_assigned_manager on core.water_lines;
create policy water_lines_select_staff_or_farmer_self on core.water_lines
for select to authenticated
using (
  iam.has_well_role(well_id, array['owner','manager','operator'])
  or iam.has_farmer_self_access(well_id)
);

drop policy if exists pump_line_links_select_assigned on core.pump_line_links;
drop policy if exists pump_line_links_select_assigned_manager on core.pump_line_links;
create policy pump_line_links_select_staff_or_farmer_self on core.pump_line_links
for select to authenticated
using (
  exists (
    select 1 from core.pumps p
    where p.id = pump_line_links.pump_id
      and (
        iam.has_well_role(p.well_id, array['owner','manager','operator'])
        or iam.has_farmer_self_access(p.well_id)
      )
  )
);

drop policy if exists persons_select_assigned on core.persons;
drop policy if exists persons_select_assigned_manager on core.persons;
create policy persons_select_staff_or_self on core.persons
for select to authenticated
using (
  id = iam.current_person_id(tenant_id)
  or exists (
    select 1 from core.wells w
    where w.tenant_id = persons.tenant_id
      and iam.has_well_role(w.id, array['owner','manager','operator'])
  )
);

drop policy if exists person_contacts_select_assigned on core.person_contacts;
drop policy if exists person_contacts_select_assigned_manager on core.person_contacts;
create policy person_contacts_select_staff_or_self on core.person_contacts
for select to authenticated
using (
  person_id = iam.current_person_id(tenant_id)
  or exists (
    select 1 from core.wells w
    where w.tenant_id = person_contacts.tenant_id
      and iam.has_well_role(w.id, array['owner','manager','operator'])
  )
);

drop policy if exists person_aliases_select_assigned on core.person_aliases;
drop policy if exists person_aliases_select_assigned_manager on core.person_aliases;
create policy person_aliases_select_staff_or_self on core.person_aliases
for select to authenticated
using (
  person_id = iam.current_person_id(tenant_id)
  or exists (
    select 1 from core.wells w
    where w.tenant_id = person_aliases.tenant_id
      and iam.has_well_role(w.id, array['owner','manager','operator'])
  )
);

drop policy if exists farmer_profiles_select_assigned on ops.farmer_profiles;
drop policy if exists farmer_profiles_select_assigned_manager on ops.farmer_profiles;
create policy farmer_profiles_select_staff_or_self on ops.farmer_profiles
for select to authenticated
using (
  person_id = iam.current_person_id(tenant_id)
  or exists (
    select 1 from core.wells w
    where w.tenant_id = farmer_profiles.tenant_id
      and iam.has_well_role(w.id, array['owner','manager','operator'])
  )
);

drop policy if exists farmer_well_accounts_select_assigned on ops.farmer_well_accounts;
drop policy if exists farmer_well_accounts_select_assigned_manager on ops.farmer_well_accounts;
create policy farmer_well_accounts_select_staff_or_self on ops.farmer_well_accounts
for select to authenticated
using (
  iam.has_well_role(well_id, array['owner','manager','operator'])
  or id = iam.current_farmer_well_account_id(well_id)
);

drop policy if exists farms_select_assigned on ops.farms;
drop policy if exists farms_select_assigned_manager on ops.farms;
create policy farms_select_staff_or_self on ops.farms
for select to authenticated
using (
  iam.has_well_role(well_id, array['owner','manager','operator'])
  or farmer_well_account_id = iam.current_farmer_well_account_id(well_id)
);

drop policy if exists irrigation_bookings_select_assigned on ops.irrigation_bookings;
drop policy if exists irrigation_bookings_select_assigned_manager on ops.irrigation_bookings;
create policy irrigation_bookings_select_staff_or_self on ops.irrigation_bookings
for select to authenticated
using (
  iam.has_well_role(well_id, array['owner','manager','operator'])
  or farmer_well_account_id = iam.current_farmer_well_account_id(well_id)
);

drop policy if exists irrigation_sessions_select_assigned on ops.irrigation_sessions;
drop policy if exists irrigation_sessions_select_assigned_manager on ops.irrigation_sessions;
create policy irrigation_sessions_select_staff_or_self on ops.irrigation_sessions
for select to authenticated
using (
  iam.has_well_role(well_id, array['owner','manager','operator'])
  or farmer_well_account_id = iam.current_farmer_well_account_id(well_id)
);

drop policy if exists booking_status_history_select_assigned on ops.booking_status_history;
drop policy if exists booking_status_history_select_assigned_manager on ops.booking_status_history;
create policy booking_status_history_select_staff_or_self on ops.booking_status_history
for select to authenticated
using (
  exists (
    select 1 from ops.irrigation_bookings b
    where b.id = booking_status_history.booking_id
      and (
        iam.has_well_role(b.well_id, array['owner','manager','operator'])
        or b.farmer_well_account_id = iam.current_farmer_well_account_id(b.well_id)
      )
  )
);

drop policy if exists resource_reservations_select_assigned on ops.resource_reservations;
drop policy if exists resource_reservations_select_assigned_manager on ops.resource_reservations;
create policy resource_reservations_select_staff_or_self on ops.resource_reservations
for select to authenticated
using (
  iam.has_well_role(well_id, array['owner','manager','operator'])
  or exists (
    select 1 from ops.irrigation_bookings b
    where b.id = resource_reservations.booking_id
      and b.farmer_well_account_id = iam.current_farmer_well_account_id(b.well_id)
  )
  or exists (
    select 1 from ops.irrigation_sessions s
    where s.id = resource_reservations.session_id
      and s.farmer_well_account_id = iam.current_farmer_well_account_id(s.well_id)
  )
);

drop policy if exists session_segments_select_assigned on ops.session_segments;
drop policy if exists session_segments_select_assigned_manager on ops.session_segments;
create policy session_segments_select_staff_or_self on ops.session_segments
for select to authenticated
using (
  exists (
    select 1 from ops.irrigation_sessions s
    where s.id = session_segments.session_id
      and (
        iam.has_well_role(s.well_id, array['owner','manager','operator'])
        or s.farmer_well_account_id = iam.current_farmer_well_account_id(s.well_id)
      )
  )
);

drop policy if exists session_charges_select_assigned on billing.session_charges;
drop policy if exists session_charges_select_assigned_manager on billing.session_charges;
create policy session_charges_select_staff_or_self on billing.session_charges
for select to authenticated
using (
  exists (
    select 1 from ops.irrigation_sessions s
    where s.id = session_charges.session_id
      and (
        iam.has_well_role(s.well_id, array['owner','manager','operator'])
        or s.farmer_well_account_id = iam.current_farmer_well_account_id(s.well_id)
      )
  )
);

commit;
