-- الدفعة الختامية - الملف 059 (ق-75): سجل المرفقات العام (doc03 قسم 42)

create table core.attachments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  well_id uuid references core.wells(id) on delete cascade,
  entity_type text not null,
  entity_id uuid not null,
  storage_bucket text not null,
  storage_path text not null,
  original_file_name text,
  mime_type text,
  file_size_bytes bigint,
  upload_status text not null default 'pending'
    check (upload_status in ('pending', 'uploaded', 'failed', 'deleted')),
  created_at timestamptz not null default now(),
  created_by uuid references iam.profiles(id),
  unique (storage_bucket, storage_path)
);
create index attachments_entity_idx on core.attachments (entity_type, entity_id);

alter table core.attachments enable row level security;
create policy attachments_select on core.attachments for select
  using (exists (select 1 from core.wells w where w.tenant_id = attachments.tenant_id
    and (iam.has_well_role(w.id, array['owner', 'manager', 'operator']) or iam.is_well_partner(w.id))));
create policy attachments_insert_member on core.attachments for insert
  with check (exists (select 1 from core.wells w where w.tenant_id = attachments.tenant_id
    and iam.has_well_role(w.id, array['owner', 'manager', 'operator'])));
create policy attachments_update_owner_manager on core.attachments for update
  using (exists (select 1 from core.wells w where w.tenant_id = attachments.tenant_id
    and iam.has_well_role(w.id, array['owner', 'manager'])));
grant select, insert, update on core.attachments to authenticated;
