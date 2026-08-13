-- كل مزرعة تروى من بئر واحد، ولها مزارع مسؤول عنها اختياريا
create table ops.farms (
    id uuid primary key default gen_random_uuid(),
    well_id uuid not null references core.wells(id) on delete cascade,
    name text not null,
    farmer_profile_id uuid references iam.profiles(id) on delete set null,
    status text not null default 'active' check (status in ('active', 'inactive')),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

alter table ops.farms enable row level security;
