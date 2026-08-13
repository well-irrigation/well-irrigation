-- كل مضخة تنتمي الى بئر واحد، وتستخدم نوع طاقة محدد
create table core.pumps (
    id uuid primary key default gen_random_uuid(),
    well_id uuid not null references core.wells(id) on delete cascade,
    name text not null,
    power_source text not null check (power_source in ('diesel', 'electric', 'solar')),
    status text not null default 'active' check (status in ('active', 'inactive')),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

alter table core.pumps enable row level security;
