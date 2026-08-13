-- توحيد وحدة المال: من أجزاء الألف (milli) إلى الريال الكامل (minor)
-- القرار: ق-71. السبب: المرحلة 3 (الفواتير والقيود) بُنيت بـ minor، والجداول القديمة بـ milli،
-- والخلط بينهما يعني فرق ألف ضِعف في المبالغ المعروضة. كل الجداول المتأثرة فارغة (0 صفوف) عند التنفيذ.
-- ملاحظة: إعادة تسمية العمود في PostgreSQL تُحدّث تعريفات قيود CHECK تلقائيًا، لكنها لا تُحدّث
-- أجساد الدوال (نصوص)، فتُعاد كتابة الدوال الخمس المعتمدة أدناه.

-- 1) إزالة القيود المعتمدة على الأسماء القديمة
alter table billing.payments drop constraint payments_amount_milli_check;
alter table billing.session_charges drop constraint session_charges_amount_milli_check;
alter table billing.session_charges drop constraint session_charges_check;
alter table billing.session_charges drop constraint session_charges_price_per_hour_milli_check;
alter table billing.well_pricing drop constraint well_pricing_price_per_hour_milli_check;
alter table finance.distribution_batches drop constraint distribution_batches_total_amount_milli_check;
alter table finance.distribution_lines drop constraint distribution_lines_amount_milli_check;
alter table inventory.fuel_purchases drop constraint fuel_purchases_cost_milli_check;

-- 2) إعادة التسمية
alter table billing.payments rename column amount_milli to amount_minor;
alter table billing.session_charges rename column amount_milli to amount_minor;
alter table billing.session_charges rename column price_per_hour_milli to price_per_hour_minor;
alter table billing.well_pricing rename column price_per_hour_milli to price_per_hour_minor;
alter table finance.distribution_batches rename column total_amount_milli to total_amount_minor;
alter table finance.distribution_lines rename column amount_milli to amount_minor;
alter table inventory.fuel_purchases rename column cost_milli to cost_minor;

-- 3) تحويل أي قيم موجودة (÷ 1000). الجداول فارغة الآن، وهذا للسلامة المنطقية فقط.
update billing.payments set amount_minor = amount_minor / 1000;
update billing.session_charges set amount_minor = amount_minor / 1000, price_per_hour_minor = price_per_hour_minor / 1000;
update billing.well_pricing set price_per_hour_minor = price_per_hour_minor / 1000;
update finance.distribution_batches set total_amount_minor = total_amount_minor / 1000;
update finance.distribution_lines set amount_minor = amount_minor / 1000;
update inventory.fuel_purchases set cost_minor = cost_minor / 1000;

-- 4) إرجاع القيود بأسمائها الجديدة (نفس المنطق حرفيًا)
alter table billing.payments add constraint payments_amount_minor_check check (amount_minor > 0);
alter table billing.session_charges add constraint session_charges_amount_minor_check check (amount_minor >= 0);
alter table billing.session_charges add constraint session_charges_price_per_hour_minor_check check (price_per_hour_minor > 0);
alter table billing.session_charges add constraint session_charges_amount_formula_check
    check (amount_minor = ((duration_seconds::bigint * price_per_hour_minor) / 3600));
alter table billing.well_pricing add constraint well_pricing_price_per_hour_minor_check check (price_per_hour_minor > 0);
alter table finance.distribution_batches add constraint distribution_batches_total_amount_minor_check check (total_amount_minor >= 0);
alter table finance.distribution_lines add constraint distribution_lines_amount_minor_check check (amount_minor >= 0);
alter table inventory.fuel_purchases add constraint fuel_purchases_cost_minor_check check (cost_minor > 0);

-- 5) إعادة كتابة الدوال الخمس بأسماء الأعمدة الجديدة (منطقها كما هو دون تغيير)

create or replace function billing.check_payment_not_exceed_charge()
returns trigger
language plpgsql
as $function$
declare
    total_paid bigint;
    charge_amount bigint;
begin
    select coalesce(sum(amount_minor), 0) into total_paid
    from billing.payments
    where session_charge_id = new.session_charge_id;

    select amount_minor into charge_amount
    from billing.session_charges
    where id = new.session_charge_id;

    if total_paid > charge_amount then
        raise exception 'مجموع المدفوعات للتكلفة % تجاوز المبلغ المستحق %، القيمة المحاولة %', new.session_charge_id, charge_amount, total_paid;
    end if;

    return new;
end;
$function$;

create or replace function finance.check_distribution_lines_total()
returns trigger
language plpgsql
as $function$
declare
    total bigint;
    batch_total bigint;
    target_batch_id uuid;
begin
    target_batch_id := coalesce(new.batch_id, old.batch_id);

    select coalesce(sum(amount_minor), 0) into total
    from finance.distribution_lines
    where batch_id = target_batch_id;

    select total_amount_minor into batch_total
    from finance.distribution_batches
    where id = target_batch_id;

    if total <> batch_total then
        raise exception 'مجموع اسطر التوزيع للدفعة % يجب ان يساوي % بالضبط، القيمة الحالية %', target_batch_id, batch_total, total;
    end if;

    return new;
end;
$function$;

create or replace function finance.generate_distribution_batch(p_well_id uuid, p_period_start date, p_period_end date)
returns uuid
language plpgsql
security definer
set search_path to 'finance', 'billing', 'inventory', 'core', 'pg_temp'
as $function$
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
    select coalesce(sum(p.amount_minor), 0) into v_collected
    from billing.payments p
    join billing.session_charges sc on sc.id = p.session_charge_id
    where sc.well_id = p_well_id
      and p.paid_at::date between p_period_start and p_period_end;

    select coalesce(sum(fp.cost_minor), 0) into v_expenses
    from inventory.fuel_purchases fp
    where fp.well_id = p_well_id
      and fp.purchased_at::date between p_period_start and p_period_end;

    v_net := greatest(v_collected - v_expenses, 0);

    insert into finance.distribution_batches (well_id, period_start, period_end, total_amount_minor, status)
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

        insert into finance.distribution_lines (batch_id, profile_id, share_ppm, amount_minor)
        values (v_batch_id, v_share.profile_id, v_share.share_ppm, v_line_amount);

        if v_max_share_ppm = -1 then
            v_max_share_ppm := v_share.share_ppm;
            v_max_line_profile := v_share.profile_id;
        end if;
    end loop;

    -- تصحيح باقي القسمة الصحيحة (ان وجد) بإضافته الى صاحب اكبر حصة، ليطابق المجموع تماما
    if v_remaining <> 0 and v_max_line_profile is not null then
        update finance.distribution_lines
        set amount_minor = amount_minor + v_remaining
        where batch_id = v_batch_id and profile_id = v_max_line_profile;
    end if;

    return v_batch_id;
end;
$function$;

create or replace function finance.notify_distribution_finalized()
returns trigger
language plpgsql
security definer
set search_path to 'finance', 'ops', 'pg_temp'
as $function$
declare
    v_line record;
begin
    if new.status = 'finalized' and old.status <> 'finalized' then
        for v_line in
            select profile_id, amount_minor from finance.distribution_lines where batch_id = new.id
        loop
            insert into ops.notifications (recipient_profile_id, well_id, type, message)
            values (v_line.profile_id, new.well_id, 'distribution_finalized',
                format('اكتملت دفعة توزيع للفترة من %s الى %s بمبلغ %s ريال لك', new.period_start, new.period_end, v_line.amount_minor));
        end loop;
    end if;
    return new;
end;
$function$;

create or replace function ops.compute_session_charge()
returns trigger
language plpgsql
security definer
set search_path to 'ops', 'billing', 'pg_temp'
as $function$
declare
    v_duration_seconds integer;
    v_price_per_hour_minor bigint;
    v_amount_minor bigint;
begin
    if new.status in ('closed', 'forgotten') and new.ended_at is not null
       and old.status = 'open' then

        v_duration_seconds := extract(epoch from (new.ended_at - new.started_at))::integer;

        select price_per_hour_minor into v_price_per_hour_minor
        from billing.well_pricing
        where well_id = new.well_id
          and period_start <= new.ended_at
          and (period_end is null or period_end > new.ended_at)
        order by period_start desc
        limit 1;

        if v_price_per_hour_minor is null then
            raise exception 'لا يوجد سعر فعال للبئر % في وقت اغلاق الجلسة %، لا يمكن حساب التكلفة ولا اغلاق الجلسة', new.well_id, new.id;
        end if;

        v_amount_minor := (v_duration_seconds::bigint * v_price_per_hour_minor) / 3600;

        insert into billing.session_charges (session_id, well_id, duration_seconds, price_per_hour_minor, amount_minor)
        values (new.id, new.well_id, v_duration_seconds, v_price_per_hour_minor, v_amount_minor);
    end if;

    return new;
end;
$function$;
