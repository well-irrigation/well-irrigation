-- بطاقة الشخص الموحدة: لمنع تكرار المزارعين والشركاء (القسم 7 من المخطط التنفيذي)
create table core.persons (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references core.tenants(id),
    public_code text not null default core.generate_public_code('PER'),
    full_name text not null,
    normalized_name text not null,
    preferred_name text,
    father_name text,
    family_name text,
    nickname text,
    notes text,
    status text not null default 'active'
        check (status in ('active', 'inactive', 'merged', 'archived')),
    merged_into_person_id uuid references core.persons(id),
    created_at timestamptz not null default now(),
    created_by uuid,
    updated_at timestamptz not null default now(),
    updated_by uuid,
    archived_at timestamptz,
    version bigint not null default 1,
    unique (tenant_id, public_code)
);

alter table core.persons enable row level security;

create table core.person_contacts (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references core.tenants(id),
    person_id uuid not null references core.persons(id),
    contact_type text not null
        check (contact_type in ('mobile', 'whatsapp', 'landline', 'email', 'other')),
    contact_value text not null,
    normalized_value text not null,
    is_primary boolean not null default false,
    belongs_to_person boolean not null default true,
    contact_owner_name text,
    verified_at timestamptz,
    created_at timestamptz not null default now()
);

alter table core.person_contacts enable row level security;

-- عمدا: لا فهرس فريد على رقم الهاتف، لان اكثر من شخص قد يستخدم الرقم نفسه (القسم 7.2)
create index idx_person_contacts_normalized on core.person_contacts (tenant_id, normalized_value);

create table core.person_aliases (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references core.tenants(id),
    person_id uuid not null references core.persons(id),
    alias text not null,
    normalized_alias text not null,
    alias_type text not null default 'known_as'
        check (alias_type in ('known_as', 'nickname', 'old_name', 'local_name', 'other')),
    created_at timestamptz not null default now()
);

alter table core.person_aliases enable row level security;

-- فهارس البحث العربي التقريبي لمنع التكرار (القسم 7.4)
create index idx_persons_normalized_name on core.persons (tenant_id, normalized_name);
create index idx_persons_name_trgm on core.persons using gin (normalized_name gin_trgm_ops);
create index idx_person_aliases_trgm on core.person_aliases using gin (normalized_alias gin_trgm_ops);

-- القراءة: لكل من له اي دور نشط على اي بئر ضمن نفس المستاجر (يلزم البحث الشامل لمنع التكرار عبر كل ابار المستاجر)
create policy persons_select_assigned
    on core.persons for select
    using (
        exists (
            select 1 from core.wells w
            where w.tenant_id = persons.tenant_id
              and iam.has_well_role(w.id, array['owner', 'operator', 'farmer'])
        )
    );

-- الانشاء والتعديل: للمالك او المشغل (من يسجل المزارعين ميدانيا)
create policy persons_insert_operator on core.persons for insert with check (
    exists (
        select 1 from core.wells w
        where w.tenant_id = persons.tenant_id
          and iam.has_well_role(w.id, array['owner', 'operator'])
    )
);
create policy persons_update_operator on core.persons for update using (
    exists (
        select 1 from core.wells w
        where w.tenant_id = persons.tenant_id
          and iam.has_well_role(w.id, array['owner', 'operator'])
    )
);

create policy person_contacts_select_assigned
    on core.person_contacts for select
    using (
        exists (
            select 1 from core.wells w
            where w.tenant_id = person_contacts.tenant_id
              and iam.has_well_role(w.id, array['owner', 'operator', 'farmer'])
        )
    );
create policy person_contacts_insert_operator on core.person_contacts for insert with check (
    exists (
        select 1 from core.wells w
        where w.tenant_id = person_contacts.tenant_id
          and iam.has_well_role(w.id, array['owner', 'operator'])
    )
);
create policy person_contacts_update_operator on core.person_contacts for update using (
    exists (
        select 1 from core.wells w
        where w.tenant_id = person_contacts.tenant_id
          and iam.has_well_role(w.id, array['owner', 'operator'])
    )
);

create policy person_aliases_select_assigned
    on core.person_aliases for select
    using (
        exists (
            select 1 from core.wells w
            where w.tenant_id = person_aliases.tenant_id
              and iam.has_well_role(w.id, array['owner', 'operator', 'farmer'])
        )
    );
create policy person_aliases_insert_operator on core.person_aliases for insert with check (
    exists (
        select 1 from core.wells w
        where w.tenant_id = person_aliases.tenant_id
          and iam.has_well_role(w.id, array['owner', 'operator'])
    )
);
create policy person_aliases_update_operator on core.person_aliases for update using (
    exists (
        select 1 from core.wells w
        where w.tenant_id = person_aliases.tenant_id
          and iam.has_well_role(w.id, array['owner', 'operator'])
    )
);

grant select, insert, update on core.persons, core.person_contacts, core.person_aliases to authenticated;
