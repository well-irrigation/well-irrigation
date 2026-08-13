-- كل دفعة يسددها المزارع مقابل تكلفة جلسة سقي محددة
create table billing.payments (
    id uuid primary key default gen_random_uuid(),
    session_charge_id uuid not null references billing.session_charges(id) on delete restrict,
    amount_milli bigint not null check (amount_milli > 0),
    method text not null check (method in ('cash', 'bank_transfer', 'mobile_wallet')),
    paid_at timestamptz not null default now(),
    received_by_profile_id uuid references iam.profiles(id) on delete set null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

alter table billing.payments enable row level security;

-- حارس: مجموع المدفوعات لتكلفة واحدة لا يمكن ان يتجاوز المبلغ المستحق عليها ابدا
create or replace function billing.check_payment_not_exceed_charge()
returns trigger
language plpgsql
as $$
declare
    total_paid bigint;
    charge_amount bigint;
begin
    select coalesce(sum(amount_milli), 0) into total_paid
    from billing.payments
    where session_charge_id = new.session_charge_id;

    select amount_milli into charge_amount
    from billing.session_charges
    where id = new.session_charge_id;

    if total_paid > charge_amount then
        raise exception 'مجموع المدفوعات للتكلفة % تجاوز المبلغ المستحق %، القيمة المحاولة %', new.session_charge_id, charge_amount, total_paid;
    end if;

    return new;
end;
$$;

create trigger payments_not_exceed_charge_check
    after insert or update on billing.payments
    for each row
    execute function billing.check_payment_not_exceed_charge();
