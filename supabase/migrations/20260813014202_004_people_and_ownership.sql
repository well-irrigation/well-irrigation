-- الملف الشخصي لكل مستخدم مسجل دخول فعليا في النظام
create table iam.profiles (
    id uuid primary key references auth.users(id) on delete cascade,
    full_name text not null,
    phone text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

alter table iam.profiles enable row level security;

-- دور كل شخص في كل بئر: مالك او مشغل او مزارع
create table core.well_assignments (
    id uuid primary key default gen_random_uuid(),
    well_id uuid not null references core.wells(id) on delete cascade,
    profile_id uuid not null references iam.profiles(id) on delete cascade,
    role text not null check (role in ('owner', 'operator', 'farmer')),
    status text not null default 'active' check (status in ('active', 'inactive')),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (well_id, profile_id, role)
);

alter table core.well_assignments enable row level security;

-- حصص الملكية، مخزنة كجزء من مليون، بفترات تاريخية عند تغير النسب
create table core.well_ownership_shares (
    id uuid primary key default gen_random_uuid(),
    well_id uuid not null references core.wells(id) on delete cascade,
    profile_id uuid not null references iam.profiles(id) on delete cascade,
    share_ppm integer not null check (share_ppm > 0 and share_ppm <= 1000000),
    period_start date not null default current_date,
    period_end date,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

alter table core.well_ownership_shares enable row level security;

-- يمنع وجود سطرين فعالين في نفس الوقت لنفس الشخص في نفس البئر
create unique index well_ownership_shares_active_unique
    on core.well_ownership_shares (well_id, profile_id)
    where period_end is null;

-- حارس تلقائي: مجموع الحصص الفعالة لكل بئر يجب ان يساوي 1000000 بالضبط دائما
create or replace function core.check_well_ownership_shares_total()
returns trigger
language plpgsql
as $$
declare
    total integer;
    target_well_id uuid;
begin
    target_well_id := coalesce(new.well_id, old.well_id);

    select coalesce(sum(share_ppm), 0) into total
    from core.well_ownership_shares
    where well_id = target_well_id
      and period_end is null;

    if total <> 1000000 then
        raise exception 'مجموع حصص الملكية الفعالة للبئر % يجب ان يساوي 1000000 بالضبط، القيمة الحالية %', target_well_id, total;
    end if;

    return new;
end;
$$;

create constraint trigger well_ownership_shares_total_check
    after insert or update on core.well_ownership_shares
    deferrable initially deferred
    for each row
    execute function core.check_well_ownership_shares_total();
