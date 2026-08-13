-- حجز الموارد ومنع التعارض (القسم 19)
create table ops.resource_reservations (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references core.tenants(id),
    well_id uuid not null references core.wells(id),
    resource_type text not null check (resource_type in ('pump', 'water_line')),
    resource_id uuid not null,
    booking_id uuid references ops.irrigation_bookings(id),
    session_id uuid,
    reserved_period tstzrange not null,
    status text not null check (status in ('active', 'released', 'cancelled')),
    created_at timestamptz not null default now()
);
alter table ops.resource_reservations enable row level security;

-- دالة حجز مورد مع فحص التزامن: تقرأ max_parallel_sessions من core.water_lines للخطوط
-- المضخات تعامل بحد اقصى 1 دائما (لا يوجد عمود مشابه على core.pumps حاليا - انظر م-19)
-- تنفيذ مُستنتج من الوصف النصي في القسم 19 (لا SQL حرفي في الوثيقة) - يحتاج تأكيدك
create or replace function ops.reserve_resource(
    p_well_id uuid,
    p_resource_type text,
    p_resource_id uuid,
    p_reserved_period tstzrange,
    p_booking_id uuid default null,
    p_session_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ops, core, pg_temp
as $$
declare
    v_tenant_id uuid;
    v_max_parallel integer;
    v_active_count integer;
    v_reservation_id uuid;
begin
    select tenant_id into v_tenant_id from core.wells where id = p_well_id;
    if v_tenant_id is null then
        raise exception 'البئر المحدد غير موجود: %', p_well_id;
    end if;

    if p_resource_type = 'water_line' then
        select max_parallel_sessions into v_max_parallel from core.water_lines where id = p_resource_id;
    else
        v_max_parallel := 1;
    end if;

    if v_max_parallel is null then
        raise exception 'المورد المحدد غير موجود: % (%)', p_resource_id, p_resource_type;
    end if;

    select count(*) into v_active_count
    from ops.resource_reservations
    where resource_type = p_resource_type
      and resource_id = p_resource_id
      and status = 'active'
      and reserved_period && p_reserved_period;

    if v_active_count >= v_max_parallel then
        raise exception 'المورد محجوز بالكامل خلال هذه الفترة (الحد الأقصى للتوازي: %)', v_max_parallel;
    end if;

    insert into ops.resource_reservations (tenant_id, well_id, resource_type, resource_id, booking_id, session_id, reserved_period, status)
    values (v_tenant_id, p_well_id, p_resource_type, p_resource_id, p_booking_id, p_session_id, p_reserved_period, 'active')
    returning id into v_reservation_id;

    return v_reservation_id;
end;
$$;

create policy resource_reservations_select_assigned on ops.resource_reservations for select using (iam.has_well_role(well_id, array['owner','operator','farmer']));
-- عمدا: لا سياسة INSERT مباشرة لمستخدم عادي - الحجز فقط عبر الدالة اعلاه (security definer)

grant select on ops.resource_reservations to authenticated;
grant execute on function ops.reserve_resource(uuid, text, uuid, tstzrange, uuid, uuid) to authenticated;
