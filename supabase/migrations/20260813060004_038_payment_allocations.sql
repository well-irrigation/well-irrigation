-- تخصيص الدفعات للفواتير (وثيقة 03 القسم 28.1)
-- تنبيه صريح: billing.payments المبني (الهجرة 011) مبني على session_charge_id وamount_milli،
-- لا على farmer_well_account_id وamount_minor كما في القسم 28. لم يُعدّل هنا التزامًا بقاعدة
-- عدم المساس بهجرة مطبّقة ومختبرة ولها زناد فعّال — التباعد مسجّل كمسألة مفتوحة (م-20).
create table billing.payment_allocations (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references core.tenants(id),
    payment_id uuid not null references billing.payments(id),
    invoice_id uuid not null references billing.invoices(id),
    allocated_minor bigint not null
        check (allocated_minor > 0),
    created_at timestamptz not null default now(),
    unique (payment_id, invoice_id)
);
alter table billing.payment_allocations enable row level security;

create index payment_allocations_invoice_idx on billing.payment_allocations (invoice_id);

create policy payment_allocations_select_assigned on billing.payment_allocations for select using (
    exists (select 1 from billing.invoices i where i.id = payment_allocations.invoice_id and iam.has_well_role(i.well_id, array['owner', 'operator']))
);
create policy payment_allocations_insert_operator on billing.payment_allocations for insert with check (
    exists (select 1 from billing.invoices i where i.id = payment_allocations.invoice_id and iam.has_well_role(i.well_id, array['owner', 'operator']))
);
create policy payment_allocations_update_operator on billing.payment_allocations for update using (
    exists (select 1 from billing.invoices i where i.id = payment_allocations.invoice_id and iam.has_well_role(i.well_id, array['owner', 'operator']))
);

grant select, insert, update on billing.payment_allocations to authenticated;
