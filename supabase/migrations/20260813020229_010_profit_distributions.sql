-- دفعة توزيع ارباح واحدة لبئر معين عن فترة زمنية محددة
create table finance.distribution_batches (
    id uuid primary key default gen_random_uuid(),
    well_id uuid not null references core.wells(id) on delete cascade,
    period_start date not null,
    period_end date not null,
    total_amount_milli bigint not null check (total_amount_milli >= 0),
    status text not null default 'draft' check (status in ('draft', 'finalized')),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    check (period_end >= period_start)
);

alter table finance.distribution_batches enable row level security;

-- نصيب كل مالك من دفعة توزيع واحدة
create table finance.distribution_lines (
    id uuid primary key default gen_random_uuid(),
    batch_id uuid not null references finance.distribution_batches(id) on delete cascade,
    profile_id uuid not null references iam.profiles(id) on delete restrict,
    share_ppm integer not null check (share_ppm > 0 and share_ppm <= 1000000),
    amount_milli bigint not null check (amount_milli >= 0),
    created_at timestamptz not null default now(),
    unique (batch_id, profile_id)
);

alter table finance.distribution_lines enable row level security;

-- حارس: مجموع اسطر اي دفعة يجب ان يساوي مبلغها الكلي بالضبط دائما
create or replace function finance.check_distribution_lines_total()
returns trigger
language plpgsql
as $$
declare
    total bigint;
    batch_total bigint;
    target_batch_id uuid;
begin
    target_batch_id := coalesce(new.batch_id, old.batch_id);

    select coalesce(sum(amount_milli), 0) into total
    from finance.distribution_lines
    where batch_id = target_batch_id;

    select total_amount_milli into batch_total
    from finance.distribution_batches
    where id = target_batch_id;

    if total <> batch_total then
        raise exception 'مجموع اسطر التوزيع للدفعة % يجب ان يساوي % بالضبط، القيمة الحالية %', target_batch_id, batch_total, total;
    end if;

    return new;
end;
$$;

create constraint trigger distribution_lines_total_check
    after insert or update on finance.distribution_lines
    deferrable initially deferred
    for each row
    execute function finance.check_distribution_lines_total();
