-- جدول الابار، كل بئر ينتمي الى مستاجر واحد
create table core.wells (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references core.tenants(id) on delete cascade,
    name text not null,
    location text,
    status text not null default 'active' check (status in ('active', 'inactive')),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

alter table core.wells enable row level security;

-- اعدادات كل بئر: توقيت التنبيهات المتعلقة بالجلسات
create table core.well_settings (
    well_id uuid primary key references core.wells(id) on delete cascade,
    long_session_alert_minutes integer not null default 360 check (long_session_alert_minutes > 0),
    session_ending_alert_minutes integer not null default 10 check (session_ending_alert_minutes >= 0),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

alter table core.well_settings enable row level security;
