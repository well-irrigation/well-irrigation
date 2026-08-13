-- المبلغ المستحق فعليا لكل جلسة، محسوب من المدة والسعر النشط وقت الحساب
create table billing.session_charges (
    id uuid primary key default gen_random_uuid(),
    session_id uuid not null unique references ops.irrigation_sessions(id) on delete cascade,
    well_id uuid not null references core.wells(id) on delete cascade,
    duration_seconds integer not null check (duration_seconds >= 0),
    price_per_hour_milli bigint not null check (price_per_hour_milli > 0),
    amount_milli bigint not null check (amount_milli >= 0),
    computed_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    -- حارس رياضي: المبلغ يجب ان يطابق المعادلة تماما دائما
    check (amount_milli = (duration_seconds::bigint * price_per_hour_milli) / 3600)
);

alter table billing.session_charges enable row level security;
