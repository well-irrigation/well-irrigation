-- المرحلة 5 - الملف 048 (ق-73): سياسة سقي الشريك: دفع عادي او خصم من الارباح فقط

create table core.partner_irrigation_policies (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  well_id uuid not null references core.wells(id) on delete cascade,
  partner_id uuid not null references core.well_partners(id) on delete cascade,
  policy_type text not null default 'normal'
    check (policy_type in ('normal', 'profit_offset')),
  period_start date not null default current_date,
  period_end date,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index partner_irrigation_policies_active_unique
  on core.partner_irrigation_policies (partner_id) where period_end is null;

alter table core.partner_irrigation_policies enable row level security;
create policy partner_irrigation_policies_select on core.partner_irrigation_policies for select
  using (iam.has_well_role(well_id, array['owner', 'manager']) or iam.is_well_partner(well_id));
create policy partner_irrigation_policies_insert_owner on core.partner_irrigation_policies for insert
  with check (iam.has_well_role(well_id, array['owner']));
create policy partner_irrigation_policies_update_owner on core.partner_irrigation_policies for update
  using (iam.has_well_role(well_id, array['owner']));
grant select, insert, update on core.partner_irrigation_policies to authenticated;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'invoices_partner_policy_id_fkey') then
    alter table billing.invoices
      add constraint invoices_partner_policy_id_fkey
      foreign key (partner_policy_id) references core.partner_irrigation_policies(id);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'journal_lines_partner_id_fkey') then
    alter table finance.journal_lines
      add constraint journal_lines_partner_id_fkey
      foreign key (partner_id) references core.well_partners(id);
  end if;
end $$;
