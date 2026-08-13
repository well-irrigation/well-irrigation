-- الحجوزات (القسم 18)
create table ops.irrigation_bookings (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references core.tenants(id),
    public_code text not null,
    well_id uuid not null references core.wells(id),
    farmer_well_account_id uuid not null references ops.farmer_well_accounts(id),
    farm_id uuid references ops.farms(id),
    pump_id uuid references core.pumps(id),
    water_line_id uuid references core.water_lines(id),
    scheduled_start timestamptz not null,
    scheduled_end timestamptz not null,
    expected_duration_minutes integer not null check (expected_duration_minutes > 0),
    expected_energy_source text
        check (expected_energy_source is null or expected_energy_source in ('solar', 'well_diesel', 'farmer_diesel', 'mixed')),
    status text not null default 'draft'
        check (status in ('draft','pending','confirmed','waiting','ready','started','completed','postponed','cancelled','no_show')),
    priority integer not null default 0,
    notes text,
    created_at timestamptz not null default now(),
    created_by uuid,
    check (scheduled_end > scheduled_start),
    unique (well_id, public_code)
);
alter table ops.irrigation_bookings enable row level security;

-- تاريخ حالة الحجز (القسم 18.1)
-- ملاحظة تصميم: سجل يُدخل من التطبيق عند كل تغيير حالة (لا زناد تلقائي - الوثيقة لا تحدد ذلك صريحا)
-- تصحيح: iam.users -> iam.profiles
create table ops.booking_status_history (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references core.tenants(id),
    booking_id uuid not null references ops.irrigation_bookings(id),
    old_status text,
    new_status text not null,
    reason text,
    changed_at timestamptz not null default now(),
    changed_by uuid references iam.profiles(id)
);
alter table ops.booking_status_history enable row level security;

create policy irrigation_bookings_select_assigned on ops.irrigation_bookings for select using (iam.has_well_role(well_id, array['owner','operator','farmer']));
create policy irrigation_bookings_insert_operator on ops.irrigation_bookings for insert with check (iam.has_well_role(well_id, array['owner','operator']));
create policy irrigation_bookings_update_operator on ops.irrigation_bookings for update using (iam.has_well_role(well_id, array['owner','operator']));

create policy booking_status_history_select_assigned on ops.booking_status_history for select using (
    exists (select 1 from ops.irrigation_bookings b where b.id = booking_status_history.booking_id and iam.has_well_role(b.well_id, array['owner','operator','farmer']))
);
create policy booking_status_history_insert_operator on ops.booking_status_history for insert with check (
    exists (select 1 from ops.irrigation_bookings b where b.id = booking_status_history.booking_id and iam.has_well_role(b.well_id, array['owner','operator']))
);

grant select, insert, update on ops.irrigation_bookings to authenticated;
grant select, insert on ops.booking_status_history to authenticated;
