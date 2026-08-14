-- الدفعة الختامية - الملف 057 (ق-75): سجل التدقيق (doc03 قسم 43، doc02 قسم 35)
-- append-only: ممنوع التعديل، ممنوع الحذف، قراءة لاصحاب الصلاحية فقط

create schema if not exists audit;

create table audit.audit_logs (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  well_id uuid references core.wells(id) on delete cascade,
  user_id uuid references iam.profiles(id),
  device_id uuid,
  action text not null,
  entity_type text not null,
  entity_id uuid not null,
  old_values jsonb,
  new_values jsonb,
  reason text,
  client_timestamp timestamptz,
  server_timestamp timestamptz not null default now(),
  ip_address inet,
  app_version text
);
create index audit_logs_entity_idx on audit.audit_logs (entity_type, entity_id, server_timestamp);
create index audit_logs_well_idx on audit.audit_logs (well_id, server_timestamp desc);

alter table audit.audit_logs enable row level security;
create policy audit_logs_select on audit.audit_logs for select
  using (exists (select 1 from core.wells w
    where w.tenant_id = audit_logs.tenant_id
      and (iam.has_well_role(w.id, array['owner', 'manager']) or iam.is_well_partner(w.id))));
grant select on audit.audit_logs to authenticated;
grant usage on schema audit to authenticated;

create or replace function audit.prevent_audit_modification()
returns trigger language plpgsql as $$
begin
  raise exception 'سجل التدقيق للإضافة فقط — ممنوع التعديل أو الحذف';
end;
$$;
create trigger audit_logs_append_only
before update or delete on audit.audit_logs
for each row execute function audit.prevent_audit_modification();

create or replace function audit.log(
  p_tenant_id uuid, p_well_id uuid, p_action text, p_entity_type text, p_entity_id uuid,
  p_old jsonb default null, p_new jsonb default null, p_reason text default null
) returns uuid language plpgsql security definer set search_path to 'audit', 'pg_temp' as $$
declare
  v_id uuid;
begin
  insert into audit.audit_logs (tenant_id, well_id, user_id, action, entity_type, entity_id, old_values, new_values, reason)
  values (p_tenant_id, p_well_id, auth.uid(), p_action, p_entity_type, p_entity_id, p_old, p_new, p_reason)
  returning id into v_id;
  return v_id;
end;
$$;

-- تتبع تلقائي للاحداث الحساسة (doc02 قسم 35.2)
create or replace function audit.track_changes()
returns trigger language plpgsql security definer set search_path to 'audit', 'core', 'pg_temp' as $$
declare
  v_new jsonb;
  v_old jsonb;
  v_tenant uuid;
  v_well uuid;
  v_entity uuid;
begin
  if tg_op <> 'DELETE' then v_new := to_jsonb(new); end if;
  if tg_op <> 'INSERT' then v_old := to_jsonb(old); end if;
  v_tenant := coalesce((v_new ->> 'tenant_id')::uuid, (v_old ->> 'tenant_id')::uuid);
  v_well := coalesce((v_new ->> 'well_id')::uuid, (v_old ->> 'well_id')::uuid);
  if v_tenant is null and v_well is not null then
    select tenant_id into v_tenant from core.wells where id = v_well;
  end if;
  v_entity := coalesce((v_new ->> 'id')::uuid, (v_old ->> 'id')::uuid);
  insert into audit.audit_logs (tenant_id, well_id, user_id, action, entity_type, entity_id, old_values, new_values)
  values (v_tenant, v_well, auth.uid(), lower(tg_op), tg_table_schema || '.' || tg_table_name, v_entity, v_old, v_new);
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

create trigger track_partners after insert or update or delete on core.well_partners
  for each row execute function audit.track_changes();
create trigger track_share_versions after insert or update or delete on core.ownership_share_versions
  for each row execute function audit.track_changes();
create trigger track_partner_policies after insert or update or delete on core.partner_irrigation_policies
  for each row execute function audit.track_changes();
create trigger track_well_pricing after insert or update or delete on billing.well_pricing
  for each row execute function audit.track_changes();
create trigger track_accounting_periods after insert or update or delete on finance.accounting_periods
  for each row execute function audit.track_changes();
create trigger track_distribution_cycles after insert or update or delete on finance.profit_distribution_cycles
  for each row execute function audit.track_changes();
