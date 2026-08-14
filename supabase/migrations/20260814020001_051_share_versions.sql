-- المرحلة 6 - الملف 051 (ق-74): فصل نسبة الملكية عن نسبة الارباح بتاريخ موثق (doc 03 قسم 16.2)
-- وتبني حالات الشريك الاربع، وتوحيد مسميات سياسة السقي مع المرجع

create table core.ownership_share_versions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  well_id uuid not null references core.wells(id) on delete cascade,
  partner_id uuid not null references core.well_partners(id) on delete cascade,
  ownership_percentage numeric(9,6) not null
    check (ownership_percentage >= 0 and ownership_percentage <= 100),
  profit_percentage numeric(9,6) not null
    check (profit_percentage >= 0 and profit_percentage <= 100),
  effective_period daterange not null,
  approved_by uuid references iam.profiles(id),
  approval_notes text,
  created_at timestamptz not null default now()
);

alter table core.ownership_share_versions add constraint no_partner_share_period_overlap
  exclude using gist (partner_id with =, effective_period with &&);

create index ownership_share_versions_well_idx on core.ownership_share_versions (well_id);

alter table core.ownership_share_versions enable row level security;
create policy ownership_share_versions_select on core.ownership_share_versions for select
  using (iam.has_well_role(well_id, array['owner', 'manager']) or iam.is_well_partner(well_id));
create policy ownership_share_versions_insert_owner on core.ownership_share_versions for insert
  with check (iam.has_well_role(well_id, array['owner']));
create policy ownership_share_versions_update_owner on core.ownership_share_versions for update
  using (iam.has_well_role(well_id, array['owner']));
grant select, insert, update on core.ownership_share_versions to authenticated;

-- ترحيل النسب الحالية من share_ppm الى اصدارات (1,000,000 ppm = 100)
insert into core.ownership_share_versions (tenant_id, well_id, partner_id, ownership_percentage, profit_percentage, effective_period)
select tenant_id, well_id, id, share_ppm / 10000.0, share_ppm / 10000.0, daterange(period_start, period_end)
from core.well_partners;

-- ازالة قيد المجموع القديم من جدول الشركاء ثم اسقاط العمود
drop trigger well_partners_total_check on core.well_partners;
drop function core.check_well_partners_total();

alter table core.well_partners drop constraint well_partners_status_check;
alter table core.well_partners add constraint well_partners_status_check
  check (status in ('active', 'inactive', 'left', 'archived'));
alter table core.well_partners add column joined_at date;
alter table core.well_partners add column left_at date;
alter table core.well_partners drop column share_ppm;

-- قيد المجموع 100 بالمئة على نسب الارباح الفعالة (الان على الاصدارات)
create or replace function core.check_well_profit_shares_total()
returns trigger language plpgsql as $$
declare
  total numeric;
  target_well uuid;
begin
  target_well := coalesce(new.well_id, old.well_id);
  select coalesce(sum(profit_percentage), 0) into total
  from core.ownership_share_versions
  where well_id = target_well and effective_period @> current_date;
  if total <> 100 then
    raise exception 'مجموع نسب ارباح الشركاء الفعالة للبئر % يجب ان يساوي 100 بالضبط، القيمة الحالية %',
      target_well, total;
  end if;
  return new;
end;
$$;

create constraint trigger ownership_share_versions_total_check
after insert or update on core.ownership_share_versions
deferrable initially deferred
for each row execute function core.check_well_profit_shares_total();

-- توحيد مسميات سياسة السقي مع المرجع (قيمتان فقط حسب ق-73 بند 3)
alter table core.partner_irrigation_policies drop constraint partner_irrigation_policies_policy_type_check;
update core.partner_irrigation_policies set policy_type = 'normal_customer' where policy_type = 'normal';
update core.partner_irrigation_policies set policy_type = 'deduct_from_profit' where policy_type = 'profit_offset';
alter table core.partner_irrigation_policies add constraint partner_irrigation_policies_policy_type_check
  check (policy_type in ('normal_customer', 'deduct_from_profit'));
alter table core.partner_irrigation_policies alter column policy_type set default 'normal_customer';
