-- القيود اليومية (وثيقة 03 القسم 31)
-- تصحيح: iam.users غير موجود، نستخدم iam.profiles (السابقة المعتمدة).
-- تنبيه موثّق: القيد الفريد (well_id, source_type, source_id) منقول حرفيًا من الوثيقة،
-- وقد يمنع إنشاء قيد عكسي لنفس المصدر — يحتاج قرار مالك لاحقًا.
create table finance.journal_entries (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references core.tenants(id),
    public_code text not null,
    well_id uuid not null references core.wells(id),
    entry_date timestamptz not null,
    status text not null default 'draft'
        check (status in ('draft', 'posted', 'reversed')),
    source_type text not null,
    source_id uuid not null,
    description text not null,
    idempotency_key text not null,
    posted_at timestamptz,
    posted_by uuid references iam.profiles(id),
    reversal_of_entry_id uuid references finance.journal_entries(id),
    created_at timestamptz not null default now(),
    unique (tenant_id, idempotency_key),
    unique (well_id, source_type, source_id)
);
alter table finance.journal_entries enable row level security;

-- أطراف القيد (وثيقة 03 القسم 31.1)
-- تصحيح موثّق: finance.cashboxes (المرحلة 4)، inventory.fuel_tanks (المرحلة 4)،
-- core.well_partners (المرحلة 5) غير موجودة بعد، فالأعمدة uuid بلا مفتاح خارجي، تُربط لاحقًا.
create table finance.journal_lines (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references core.tenants(id),
    journal_entry_id uuid not null references finance.journal_entries(id),
    ledger_account_id uuid not null references finance.ledger_accounts(id),
    entry_side text not null
        check (entry_side in ('debit', 'credit')),
    amount_minor bigint not null
        check (amount_minor > 0),
    person_id uuid references core.persons(id),
    farmer_well_account_id uuid references ops.farmer_well_accounts(id),
    partner_id uuid,
    cashbox_id uuid,
    fuel_tank_id uuid,
    description text,
    created_at timestamptz not null default now()
);
alter table finance.journal_lines enable row level security;

create index journal_lines_entry_idx on finance.journal_lines (journal_entry_id);
create index journal_lines_account_idx on finance.journal_lines (ledger_account_id);
create index journal_entries_well_date_idx on finance.journal_entries (well_id, entry_date);

-- ترحيل القيد (وثيقة 03 القسم 32) — الخطوات 1-4 و6-7 منفّذة.
-- فجوة موثّقة: الخطوة 5 (التأكد من عدم إغلاق الفترة) مؤجلة لأن جدول الفترات المحاسبية في المرحلة 5.
-- تصحيح موثّق: الوثيقة تكتب post_journal_entry(entry_id)؛ أُضيف معامل ثانٍ اختياري للمُرحِّل
-- لأن auth.uid() غير متاح في سياق الخادم/الاختبار.
create or replace function finance.post_journal_entry(p_entry_id uuid, p_posted_by uuid default null)
returns void
language plpgsql
security definer
set search_path = finance, public
as $$
declare
    v_status text;
    v_debit bigint;
    v_credit bigint;
    v_lines integer;
begin
    select status into v_status from finance.journal_entries where id = p_entry_id for update;
    if v_status is null then
        raise exception 'القيد غير موجود: %', p_entry_id;
    end if;
    if v_status <> 'draft' then
        raise exception 'لا يمكن ترحيل قيد حالته % — يجب أن يكون مسودة', v_status;
    end if;

    select count(*),
           coalesce(sum(case when entry_side = 'debit'  then amount_minor else 0 end), 0),
           coalesce(sum(case when entry_side = 'credit' then amount_minor else 0 end), 0)
      into v_lines, v_debit, v_credit
      from finance.journal_lines
     where journal_entry_id = p_entry_id;

    if v_lines < 2 then
        raise exception 'القيد يجب أن يحتوي طرفين على الأقل (الموجود: %)', v_lines;
    end if;
    if v_debit <> v_credit then
        raise exception 'القيد غير متوازن: مجموع المدين % لا يساوي مجموع الدائن %', v_debit, v_credit;
    end if;

    update finance.journal_entries
       set status = 'posted', posted_at = now(), posted_by = p_posted_by
     where id = p_entry_id;
end;
$$;

-- منع أي تعديل لاحق على قيد مُرحّل (الخطوة 7)
create or replace function finance.prevent_posted_entry_change()
returns trigger
language plpgsql
as $$
begin
    if tg_op = 'DELETE' then
        if old.status <> 'draft' then
            raise exception 'لا يمكن حذف قيد حالته %', old.status;
        end if;
        return old;
    end if;

    if old.status = 'draft' then
        return new;
    end if;

    if old.status = 'posted' and new.status = 'reversed'
       and (to_jsonb(new) - 'status' - 'reversal_of_entry_id')
         = (to_jsonb(old) - 'status' - 'reversal_of_entry_id') then
        return new;
    end if;

    raise exception 'لا يمكن تعديل قيد مُرحّل أو معكوس (الحالة: %)', old.status;
end;
$$;

create trigger journal_entries_lock_when_posted
before update or delete on finance.journal_entries
for each row execute function finance.prevent_posted_entry_change();

create or replace function finance.prevent_posted_line_change()
returns trigger
language plpgsql
as $$
declare
    v_entry_id uuid;
    v_status text;
begin
    v_entry_id := case when tg_op = 'DELETE' then old.journal_entry_id else new.journal_entry_id end;
    select status into v_status from finance.journal_entries where id = v_entry_id;
    if v_status is distinct from 'draft' then
        raise exception 'لا يمكن تعديل أطراف قيد غير مسودة (الحالة: %)', coalesce(v_status, 'قيد غير موجود');
    end if;
    if tg_op = 'DELETE' then
        return old;
    end if;
    return new;
end;
$$;

create trigger journal_lines_lock_when_posted
before insert or update or delete on finance.journal_lines
for each row execute function finance.prevent_posted_line_change();

create policy journal_entries_select_owner on finance.journal_entries for select using (iam.has_well_role(well_id, array['owner']));
create policy journal_entries_insert_owner on finance.journal_entries for insert with check (iam.has_well_role(well_id, array['owner']));
create policy journal_entries_update_owner on finance.journal_entries for update using (iam.has_well_role(well_id, array['owner']));

create policy journal_lines_select_owner on finance.journal_lines for select using (
    exists (select 1 from finance.journal_entries je where je.id = journal_lines.journal_entry_id and iam.has_well_role(je.well_id, array['owner']))
);
create policy journal_lines_insert_owner on finance.journal_lines for insert with check (
    exists (select 1 from finance.journal_entries je where je.id = journal_lines.journal_entry_id and iam.has_well_role(je.well_id, array['owner']))
);
create policy journal_lines_update_owner on finance.journal_lines for update using (
    exists (select 1 from finance.journal_entries je where je.id = journal_lines.journal_entry_id and iam.has_well_role(je.well_id, array['owner']))
);

grant select, insert, update on finance.journal_entries, finance.journal_lines to authenticated;
grant execute on function finance.post_journal_entry(uuid, uuid) to authenticated;
