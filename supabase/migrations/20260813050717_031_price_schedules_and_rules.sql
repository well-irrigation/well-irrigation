-- مجموعة الأسعار (القسم 17.1)
-- تصحيح: iam.users غير موجود في قاعدتنا، نستخدم iam.profiles (القرار المعتمد سابقا)
create table ops.price_schedules (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references core.tenants(id),
    well_id uuid not null references core.wells(id),
    name text not null,
    effective_period tstzrange not null,
    status text not null default 'active'
        check (status in ('draft', 'active', 'expired', 'cancelled')),
    reason text,
    approved_by uuid references iam.profiles(id),
    created_at timestamptz not null default now()
);
alter table ops.price_schedules enable row level security;

-- قواعد السعر (القسم 17.2)
-- عمدا: لا يوجد minimum_billable_minutes، حُذف بالقرار ق-16 (شكل مقنّع من التقريب)
create table ops.price_rules (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references core.tenants(id),
    price_schedule_id uuid not null references ops.price_schedules(id),
    energy_source text not null
        check (energy_source in ('solar', 'well_diesel', 'farmer_diesel')),
    diesel_pricing_model text
        check (diesel_pricing_model is null or diesel_pricing_model in ('inclusive_hourly', 'operation_plus_fuel')),
    hourly_rate_minor bigint check (hourly_rate_minor is null or hourly_rate_minor >= 0),
    operation_hourly_rate_minor bigint check (operation_hourly_rate_minor is null or operation_hourly_rate_minor >= 0),
    fuel_price_per_liter_minor bigint check (fuel_price_per_liter_minor is null or fuel_price_per_liter_minor >= 0),
    created_at timestamptz not null default now(),
    unique (price_schedule_id, energy_source)
);
alter table ops.price_rules enable row level security;

-- التسعير بيانات تجارية حساسة، للمالك فقط (نفس منطق billing.well_pricing)
create policy price_schedules_select_owner on ops.price_schedules for select using (iam.has_well_role(well_id, array['owner']));
create policy price_schedules_insert_owner on ops.price_schedules for insert with check (iam.has_well_role(well_id, array['owner']));
create policy price_schedules_update_owner on ops.price_schedules for update using (iam.has_well_role(well_id, array['owner']));

create policy price_rules_select_owner on ops.price_rules for select using (
    exists (select 1 from ops.price_schedules ps where ps.id = price_rules.price_schedule_id and iam.has_well_role(ps.well_id, array['owner']))
);
create policy price_rules_insert_owner on ops.price_rules for insert with check (
    exists (select 1 from ops.price_schedules ps where ps.id = price_rules.price_schedule_id and iam.has_well_role(ps.well_id, array['owner']))
);
create policy price_rules_update_owner on ops.price_rules for update using (
    exists (select 1 from ops.price_schedules ps where ps.id = price_rules.price_schedule_id and iam.has_well_role(ps.well_id, array['owner']))
);

grant select, insert, update on ops.price_schedules, ops.price_rules to authenticated;
