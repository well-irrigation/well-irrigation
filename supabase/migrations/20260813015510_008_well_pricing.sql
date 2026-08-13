-- سعر الساعة الواحدة لكل بئر، بجزء من الالف من الريال، بفترات تاريخية عند تغير السعر
create table billing.well_pricing (
    id uuid primary key default gen_random_uuid(),
    well_id uuid not null references core.wells(id) on delete cascade,
    price_per_hour_milli bigint not null check (price_per_hour_milli > 0),
    period_start date not null default current_date,
    period_end date,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

alter table billing.well_pricing enable row level security;

-- سعر نشط واحد فقط لكل بئر في نفس اللحظة
create unique index well_pricing_active_unique
    on billing.well_pricing (well_id)
    where period_end is null;
