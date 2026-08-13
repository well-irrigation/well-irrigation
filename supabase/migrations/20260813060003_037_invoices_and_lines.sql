-- الفواتير (وثيقة 03 القسم 27)
-- تصحيح: iam.users -> iam.profiles (السابقة المعتمدة).
-- تصحيح موثّق: core.partner_irrigation_policies (المرحلة 5) غير موجود، فالعمود uuid بلا مفتاح خارجي.
-- إضافة موثّقة: due_date مأخوذ من وثيقة 02 القسم 19.1 (لازم لحالة overdue، وغائب عن DDL وثيقة 03).
create table billing.invoices (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references core.tenants(id),
    public_code text not null,
    sequence_number bigint,
    well_id uuid not null references core.wells(id),
    farmer_well_account_id uuid not null references ops.farmer_well_accounts(id),
    session_id uuid references ops.irrigation_sessions(id),
    invoice_date timestamptz not null,
    due_date timestamptz,
    status text not null default 'draft'
        check (status in ('draft', 'issued', 'partially_paid', 'paid', 'overdue', 'cancelled', 'reversed')),
    currency_code char(3) not null default 'YER',
    subtotal_minor bigint not null default 0,
    rounding_minor bigint not null default 0,
    total_minor bigint not null default 0,
    paid_minor bigint not null default 0,
    outstanding_minor bigint not null default 0,
    settlement_method text not null default 'normal'
        check (settlement_method in ('normal', 'partner_profit_offset', 'free_entitlement', 'special_policy')),
    partner_policy_id uuid,
    issued_at timestamptz,
    issued_by uuid references iam.profiles(id),
    reversed_invoice_id uuid references billing.invoices(id),
    notes text,
    created_at timestamptz not null default now(),
    unique (well_id, public_code),
    check (subtotal_minor >= 0),
    check (total_minor >= 0),
    check (paid_minor >= 0),
    check (outstanding_minor >= 0),
    check (paid_minor + outstanding_minor = total_minor)
);
alter table billing.invoices enable row level security;

-- بنود الفاتورة (وثيقة 03 القسم 27.1)
create table billing.invoice_lines (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references core.tenants(id),
    invoice_id uuid not null references billing.invoices(id),
    line_number integer not null
        check (line_number > 0),
    line_type text not null
        check (line_type in ('solar_irrigation', 'diesel_operation', 'diesel_fuel', 'partner_adjustment', 'additional_fee', 'opening_balance', 'manual_adjustment')),
    description text not null,
    quantity numeric(18,6) not null,
    unit text not null,
    unit_price_minor bigint not null,
    amount_minor bigint not null,
    session_segment_id uuid references ops.session_segments(id),
    created_at timestamptz not null default now(),
    unique (invoice_id, line_number)
);
alter table billing.invoice_lines enable row level security;

create index invoices_well_status_idx on billing.invoices (well_id, status);
create index invoices_account_idx on billing.invoices (farmer_well_account_id);
create index invoice_lines_invoice_idx on billing.invoice_lines (invoice_id);

-- الفواتير يراها ويصدرها المالك والمشغل (نفس منطق billing.session_charges/payments)
create policy invoices_select_assigned on billing.invoices for select using (iam.has_well_role(well_id, array['owner', 'operator']));
create policy invoices_insert_operator on billing.invoices for insert with check (iam.has_well_role(well_id, array['owner', 'operator']));
create policy invoices_update_operator on billing.invoices for update using (iam.has_well_role(well_id, array['owner', 'operator']));

create policy invoice_lines_select_assigned on billing.invoice_lines for select using (
    exists (select 1 from billing.invoices i where i.id = invoice_lines.invoice_id and iam.has_well_role(i.well_id, array['owner', 'operator']))
);
create policy invoice_lines_insert_operator on billing.invoice_lines for insert with check (
    exists (select 1 from billing.invoices i where i.id = invoice_lines.invoice_id and iam.has_well_role(i.well_id, array['owner', 'operator']))
);
create policy invoice_lines_update_operator on billing.invoice_lines for update using (
    exists (select 1 from billing.invoices i where i.id = invoice_lines.invoice_id and iam.has_well_role(i.well_id, array['owner', 'operator']))
);

grant select, insert, update on billing.invoices, billing.invoice_lines to authenticated;
