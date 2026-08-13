-- ملف المزارع (القسم 14.1): يمثل كون الشخص مزارعا، دون تكرار بطاقة core.persons
create table ops.farmer_profiles (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references core.tenants(id),
    person_id uuid not null references core.persons(id),
    status text not null default 'active'
        check (status in ('active', 'inactive', 'blocked', 'archived')),
    notes text,
    created_at timestamptz not null default now(),
    unique (tenant_id, person_id)
);
alter table ops.farmer_profiles enable row level security;

-- حساب المزارع في بئر معين (القسم 14.2): المزارع نفسه قد يمتلك حسابا في اكثر من بئر
create table ops.farmer_well_accounts (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references core.tenants(id),
    farmer_profile_id uuid not null references ops.farmer_profiles(id),
    well_id uuid not null references core.wells(id),
    public_code text not null,
    status text not null default 'active'
        check (status in ('active', 'inactive', 'blocked', 'archived')),
    credit_limit_minor bigint,
    notes text,
    created_at timestamptz not null default now(),
    unique (farmer_profile_id, well_id),
    unique (well_id, public_code)
);
alter table ops.farmer_well_accounts enable row level security;

create policy farmer_profiles_select_assigned on ops.farmer_profiles for select using (
    exists (select 1 from core.wells w where w.tenant_id = farmer_profiles.tenant_id and iam.has_well_role(w.id, array['owner', 'operator', 'farmer']))
);
create policy farmer_profiles_insert_operator on ops.farmer_profiles for insert with check (
    exists (select 1 from core.wells w where w.tenant_id = farmer_profiles.tenant_id and iam.has_well_role(w.id, array['owner', 'operator']))
);
create policy farmer_profiles_update_operator on ops.farmer_profiles for update using (
    exists (select 1 from core.wells w where w.tenant_id = farmer_profiles.tenant_id and iam.has_well_role(w.id, array['owner', 'operator']))
);

create policy farmer_well_accounts_select_assigned on ops.farmer_well_accounts for select using (iam.has_well_role(well_id, array['owner', 'operator', 'farmer']));
create policy farmer_well_accounts_insert_operator on ops.farmer_well_accounts for insert with check (iam.has_well_role(well_id, array['owner', 'operator']));
create policy farmer_well_accounts_update_operator on ops.farmer_well_accounts for update using (iam.has_well_role(well_id, array['owner', 'operator']));

grant select, insert, update on ops.farmer_profiles, ops.farmer_well_accounts to authenticated;
