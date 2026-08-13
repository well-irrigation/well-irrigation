-- مقاطع الجلسة (القسم 21)
create table ops.session_segments (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references core.tenants(id),
    session_id uuid not null references ops.irrigation_sessions(id),
    sequence_number integer not null check (sequence_number > 0),
    segment_type text not null
        check (segment_type in ('solar_run','well_diesel_run','farmer_diesel_run','billable_stop','non_billable_stop','breakdown','operator_pause','farmer_requested_pause','source_change_pause')),
    energy_source text check (energy_source is null or energy_source in ('solar','well_diesel','farmer_diesel')),
    started_at timestamptz not null,
    ended_at timestamptz,
    actual_minutes integer,
    raw_billable_minutes integer,
    is_billable boolean not null,
    fuel_owner_person_id uuid references core.persons(id),
    fuel_actual_ml bigint check (fuel_actual_ml is null or fuel_actual_ml >= 0),
    fuel_estimated_ml bigint check (fuel_estimated_ml is null or fuel_estimated_ml >= 0),
    fuel_measurement_type text check (fuel_measurement_type is null or fuel_measurement_type in ('actual','estimated')),
    applied_price_rule_id uuid references ops.price_rules(id),
    applied_hourly_rate_minor bigint,
    applied_operation_rate_minor bigint,
    applied_fuel_price_per_liter_minor bigint,
    notes text,
    created_at timestamptz not null default now(),
    unique (session_id, sequence_number),
    check (ended_at is null or ended_at > started_at)
);
alter table ops.session_segments enable row level security;

-- زناد منع تداخل المقاطع (القسم 21.1) - تنفيذ مُستنتج من الوصف النصي، يحتاج تأكيدك
create or replace function ops.validate_session_segment_overlap()
returns trigger
language plpgsql
as $$
begin
    if exists (
        select 1 from ops.session_segments s
        where s.session_id = new.session_id
          and s.id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid)
          and tstzrange(s.started_at, coalesce(s.ended_at, 'infinity'), '[)') &&
              tstzrange(new.started_at, coalesce(new.ended_at, 'infinity'), '[)')
    ) then
        raise exception 'تداخل زمني مع مقطع آخر في الجلسة نفسها، لا يمكن حفظ المقطع %', new.id;
    end if;
    return new;
end;
$$;

create trigger session_segments_validate_overlap
    before insert or update on ops.session_segments
    for each row
    execute function ops.validate_session_segment_overlap();

create policy session_segments_select_assigned on ops.session_segments for select using (
    exists (select 1 from ops.irrigation_sessions s where s.id = session_segments.session_id and iam.has_well_role(s.well_id, array['owner','operator','farmer']))
);
create policy session_segments_insert_operator on ops.session_segments for insert with check (
    exists (select 1 from ops.irrigation_sessions s where s.id = session_segments.session_id and iam.has_well_role(s.well_id, array['owner','operator']))
);
create policy session_segments_update_operator on ops.session_segments for update using (
    exists (select 1 from ops.irrigation_sessions s where s.id = session_segments.session_id and iam.has_well_role(s.well_id, array['owner','operator']))
);

grant select, insert, update on ops.session_segments to authenticated;
