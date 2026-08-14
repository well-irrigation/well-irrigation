-- الدفعة الختامية - الملف 058 (ق-75): منع تنفيذ العملية مرتين + سجل تعارضات الاجهزة
-- (doc03 قسم 44 و45، doc02 قسم 36 و37)

create schema if not exists sync;

create table sync.processed_commands (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  command_id uuid not null,
  command_type text not null,
  entity_id uuid,
  status text not null check (status in ('processing', 'accepted', 'rejected', 'conflict')),
  request_payload jsonb,
  response_payload jsonb,
  processed_at timestamptz not null default now(),
  unique (tenant_id, command_id)
);
alter table sync.processed_commands enable row level security;
create policy processed_commands_select on sync.processed_commands for select
  using (exists (select 1 from core.wells w where w.tenant_id = processed_commands.tenant_id
    and iam.has_well_role(w.id, array['owner', 'manager'])));
grant select on sync.processed_commands to authenticated;
grant usage on schema sync to authenticated;

-- اذا وصل الامر نفسه مرتين من الهاتف: يعاد الرد المخزن ولا ينفذ مجددا
create or replace function sync.begin_command(
  p_tenant_id uuid, p_command_id uuid, p_command_type text,
  p_payload jsonb default null, p_entity_id uuid default null
) returns jsonb language plpgsql security definer set search_path to 'sync', 'pg_temp' as $$
declare
  v_existing record;
  v_found boolean;
begin
  select * into v_existing from sync.processed_commands
  where tenant_id = p_tenant_id and command_id = p_command_id;
  v_found := found;
  if v_found then
    return jsonb_build_object('duplicate', true, 'status', v_existing.status, 'response', v_existing.response_payload);
  end if;
  insert into sync.processed_commands (tenant_id, command_id, command_type, entity_id, status, request_payload)
  values (p_tenant_id, p_command_id, p_command_type, p_entity_id, 'processing', p_payload);
  return jsonb_build_object('duplicate', false);
end;
$$;

create or replace function sync.finish_command(p_tenant_id uuid, p_command_id uuid, p_status text, p_response jsonb default null)
returns void language plpgsql security definer set search_path to 'sync', 'pg_temp' as $$
begin
  update sync.processed_commands
  set status = p_status, response_payload = p_response, processed_at = now()
  where tenant_id = p_tenant_id and command_id = p_command_id;
  if not found then raise exception 'الأمر غير موجود: %', p_command_id; end if;
end;
$$;

create table sync.sync_conflicts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  well_id uuid references core.wells(id) on delete cascade,
  entity_type text not null,
  entity_id uuid not null,
  server_version bigint not null,
  client_version bigint not null,
  server_data jsonb not null,
  client_data jsonb not null,
  status text not null default 'open'
    check (status in ('open', 'resolved_server', 'resolved_client', 'merged', 'discarded')),
  resolved_by uuid references iam.profiles(id),
  resolved_at timestamptz,
  resolution_notes text,
  created_at timestamptz not null default now()
);
alter table sync.sync_conflicts enable row level security;
create policy sync_conflicts_select on sync.sync_conflicts for select
  using (exists (select 1 from core.wells w where w.tenant_id = sync_conflicts.tenant_id
    and (iam.has_well_role(w.id, array['owner', 'manager']) or iam.is_well_partner(w.id))));
create policy sync_conflicts_insert_member on sync.sync_conflicts for insert
  with check (exists (select 1 from core.wells w where w.tenant_id = sync_conflicts.tenant_id
    and iam.has_well_role(w.id, array['owner', 'manager', 'operator'])));
create policy sync_conflicts_update_owner_manager on sync.sync_conflicts for update
  using (exists (select 1 from core.wells w where w.tenant_id = sync_conflicts.tenant_id
    and iam.has_well_role(w.id, array['owner', 'manager'])));
grant select, insert, update on sync.sync_conflicts to authenticated;
