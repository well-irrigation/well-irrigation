-- خطوط المياه (القسم 13.2)
create table core.water_lines (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references core.tenants(id),
    well_id uuid not null references core.wells(id),
    public_code text not null,
    name text not null,
    status text not null default 'active'
        check (status in ('active', 'inactive', 'maintenance', 'retired')),
    allows_parallel_use boolean not null default false,
    max_parallel_sessions integer not null default 1
        check (max_parallel_sessions >= 1),
    notes text,
    created_at timestamptz not null default now(),
    unique (well_id, public_code)
);
alter table core.water_lines enable row level security;

-- ربط المضخة بالخط (القسم 13.3)
create table core.pump_line_links (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references core.tenants(id),
    pump_id uuid not null references core.pumps(id),
    water_line_id uuid not null references core.water_lines(id),
    effective_from timestamptz not null default now(),
    effective_to timestamptz,
    is_primary boolean not null default false,
    check (effective_to is null or effective_to > effective_from)
);
alter table core.pump_line_links enable row level security;

create policy water_lines_select_assigned on core.water_lines for select using (iam.has_well_role(well_id, array['owner', 'operator', 'farmer']));
create policy water_lines_insert_owner on core.water_lines for insert with check (iam.has_well_role(well_id, array['owner']));
create policy water_lines_update_owner on core.water_lines for update using (iam.has_well_role(well_id, array['owner']));

create policy pump_line_links_select_assigned on core.pump_line_links for select using (
    exists (select 1 from core.pumps p where p.id = pump_line_links.pump_id and iam.has_well_role(p.well_id, array['owner', 'operator', 'farmer']))
);
create policy pump_line_links_insert_owner on core.pump_line_links for insert with check (
    exists (select 1 from core.pumps p where p.id = pump_line_links.pump_id and iam.has_well_role(p.well_id, array['owner']))
);
create policy pump_line_links_update_owner on core.pump_line_links for update using (
    exists (select 1 from core.pumps p where p.id = pump_line_links.pump_id and iam.has_well_role(p.well_id, array['owner']))
);

grant select, insert, update on core.water_lines, core.pump_line_links to authenticated;
