-- تفعيل الامتدادات المتبقية المطلوبة (القسم 3 من المخطط التنفيذي)
-- pg_trgm: للبحث التقريبي في الاسماء ومنع التكرار
-- btree_gist: لمنع تداخل الفترات الزمنية (نسب شركاء، اسعار، حجوزات، استخدام موارد)
-- citext: للنصوص الانجليزية غير الحساسة لحالة الاحرف
create extension if not exists pg_trgm;
create extension if not exists btree_gist;
create extension if not exists citext;

-- دالة توليد الرقم الظاهر: قابلة للعمل دون انترنت، لا تعتمد على تسلسل مركزي (القسم 1.4)
create or replace function core.generate_public_code(p_prefix text)
returns text
language sql
stable
as $$
    select p_prefix || '-' || to_char(now(), 'YY') || '-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 5));
$$;

-- المواقع: بيانات جغرافية للبئر (القسم 10 من المخطط التنفيذي)
create table core.locations (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references core.tenants(id),
    country text not null default 'Yemen',
    governorate text not null,
    district text,
    subdistrict text,
    village text,
    valley text,
    local_area text,
    access_description text,
    latitude numeric(10,7),
    longitude numeric(10,7),
    created_at timestamptz not null default now(),
    check (latitude is null or latitude between -90 and 90),
    check (longitude is null or longitude between -180 and 180)
);

alter table core.locations enable row level security;

-- ربط البئر بموقعه: عمود اضافي جديد، لا يعدل اي بيانات موجودة
alter table core.wells add column location_id uuid references core.locations(id);

-- القراءة: لكل من له اي دور نشط على اي بئر ضمن نفس المستاجر (نفس منطق tenants_select_assigned)
create policy locations_select_assigned
    on core.locations for select
    using (
        exists (
            select 1 from core.wells w
            where w.tenant_id = locations.tenant_id
              and iam.has_well_role(w.id, array['owner', 'operator', 'farmer'])
        )
    );

-- الانشاء: متاح لاي مستخدم مسجل دخوله (نفس منطق wells_insert_authenticated المؤقت، لان الموقع قد ينشأ قبل ربطه ببئر)
create policy locations_insert_authenticated on core.locations for insert with check (auth.uid() is not null);

-- التعديل: حصرا لمالك اي بئر ضمن نفس المستاجر
create policy locations_update_owner on core.locations for update using (
    exists (
        select 1 from core.wells w
        where w.tenant_id = locations.tenant_id
          and iam.has_well_role(w.id, array['owner'])
    )
);

grant select, insert, update on core.locations to authenticated;
