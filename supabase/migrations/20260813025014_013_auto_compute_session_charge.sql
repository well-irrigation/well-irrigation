-- تحسب تلقائيا تكلفة اي جلسة سقي فور اغلاقها، باستخدام السعر الفعلي وقت الاغلاق
create or replace function ops.compute_session_charge()
returns trigger
language plpgsql
as $$
declare
    v_duration_seconds integer;
    v_price_per_hour_milli bigint;
    v_amount_milli bigint;
begin
    -- فقط عند تحول الجلسة من مفتوحة الى مغلقة او منسية، مع وجود وقت نهاية
    if new.status in ('closed', 'forgotten') and new.ended_at is not null
       and old.status = 'open' then

        v_duration_seconds := extract(epoch from (new.ended_at - new.started_at))::integer;

        select price_per_hour_milli into v_price_per_hour_milli
        from billing.well_pricing
        where well_id = new.well_id
          and period_start <= new.ended_at
          and (period_end is null or period_end > new.ended_at)
        order by period_start desc
        limit 1;

        if v_price_per_hour_milli is null then
            raise exception 'لا يوجد سعر فعال للبئر % في وقت اغلاق الجلسة %، لا يمكن حساب التكلفة ولا اغلاق الجلسة', new.well_id, new.id;
        end if;

        v_amount_milli := (v_duration_seconds::bigint * v_price_per_hour_milli) / 3600;

        insert into billing.session_charges (session_id, well_id, duration_seconds, price_per_hour_milli, amount_milli)
        values (new.id, new.well_id, v_duration_seconds, v_price_per_hour_milli, v_amount_milli);
    end if;

    return new;
end;
$$;

create trigger irrigation_sessions_compute_charge
    after update on ops.irrigation_sessions
    for each row
    execute function ops.compute_session_charge();
