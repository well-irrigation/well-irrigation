-- جلسة السقي: تربط البئر والمضخة والمزرعة والمشغل في حدث واحد بداية ونهاية
create table ops.irrigation_sessions (
    id uuid primary key default gen_random_uuid(),
    well_id uuid not null references core.wells(id) on delete cascade,
    pump_id uuid not null references core.pumps(id) on delete restrict,
    farm_id uuid not null references ops.farms(id) on delete restrict,
    operator_profile_id uuid not null references iam.profiles(id) on delete restrict,
    started_at timestamptz not null default now(),
    ended_at timestamptz,
    status text not null default 'open' check (status in ('open', 'closed', 'forgotten')),
    long_alert_sent_at timestamptz,
    ending_alert_sent_at timestamptz,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    check (
        (status = 'open' and ended_at is null)
        or (status in ('closed', 'forgotten') and ended_at is not null)
    )
);

alter table ops.irrigation_sessions enable row level security;

-- تسريع البحث عن الجلسات الجارية حاليا لكل بئر
create index irrigation_sessions_open_idx
    on ops.irrigation_sessions (well_id)
    where status = 'open';
