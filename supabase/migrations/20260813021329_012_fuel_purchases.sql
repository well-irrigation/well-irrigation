-- كل عملية شراء وقود لبئر معين، تؤثر على صافي الربح الفعلي لاحقا
create table inventory.fuel_purchases (
    id uuid primary key default gen_random_uuid(),
    well_id uuid not null references core.wells(id) on delete cascade,
    liters numeric(10, 2) not null check (liters > 0),
    cost_milli bigint not null check (cost_milli > 0),
    purchased_at timestamptz not null default now(),
    recorded_by_profile_id uuid references iam.profiles(id) on delete set null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

alter table inventory.fuel_purchases enable row level security;
