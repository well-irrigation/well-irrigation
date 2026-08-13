-- تُنشئ دفعة توزيع (draft) وبنودها تلقائيا لبئر معين عن فترة معينة:
-- الصافي = المدفوعات المُحصَّلة فعليا خلال الفترة ناقص مصاريف الوقود خلال نفس الفترة
-- ثم يُوزَّع الصافي حسب حصص الملكية السارية في نهاية الفترة (period_end)، مع تصحيح باقي القسمة
create or replace function finance.generate_distribution_batch(p_well_id uuid, p_period_start date, p_period_end date)
returns uuid
language plpgsql
security definer
set search_path = finance, billing, inventory, core, pg_temp
as $$
declare
    v_collected bigint;
    v_expenses bigint;
    v_net bigint;
    v_batch_id uuid;
    v_share record;
    v_remaining bigint;
    v_line_amount bigint;
    v_max_line_profile uuid;
    v_max_share_ppm int := -1;
begin
    select coalesce(sum(p.amount_milli), 0) into v_collected
    from billing.payments p
    join billing.session_charges sc on sc.id = p.session_charge_id
    where sc.well_id = p_well_id
      and p.paid_at::date between p_period_start and p_period_end;

    select coalesce(sum(fp.cost_milli), 0) into v_expenses
    from inventory.fuel_purchases fp
    where fp.well_id = p_well_id
      and fp.purchased_at::date between p_period_start and p_period_end;

    v_net := greatest(v_collected - v_expenses, 0);

    insert into finance.distribution_batches (well_id, period_start, period_end, total_amount_milli, status)
    values (p_well_id, p_period_start, p_period_end, v_net, 'draft')
    returning id into v_batch_id;

    v_remaining := v_net;

    for v_share in
        select profile_id, share_ppm
        from core.well_ownership_shares
        where well_id = p_well_id
          and period_start <= p_period_end
          and (period_end is null or period_end >= p_period_end)
        order by share_ppm desc, profile_id
    loop
        v_line_amount := (v_net * v_share.share_ppm) / 1000000;
        v_remaining := v_remaining - v_line_amount;

        insert into finance.distribution_lines (batch_id, profile_id, share_ppm, amount_milli)
        values (v_batch_id, v_share.profile_id, v_share.share_ppm, v_line_amount);

        if v_max_share_ppm = -1 then
            v_max_share_ppm := v_share.share_ppm;
            v_max_line_profile := v_share.profile_id;
        end if;
    end loop;

    -- تصحيح باقي القسمة الصحيحة (ان وجد) بإضافته الى صاحب اكبر حصة، ليطابق المجموع تماما
    if v_remaining <> 0 and v_max_line_profile is not null then
        update finance.distribution_lines
        set amount_milli = amount_milli + v_remaining
        where batch_id = v_batch_id and profile_id = v_max_line_profile;
    end if;

    return v_batch_id;
end;
$$;
