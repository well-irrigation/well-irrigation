-- =====================================================================
-- 078 — ق-110 / W1-01
-- Explicit Login Profile ↔ Tenant-scoped Business Person identity link
--
-- الهدف:
-- توفير العلاقة الصريحة التي يحتاجها Authorization لاحقًا لمعرفة
-- الشخص التجاري المرتبط بحساب الدخول دون أي تخمين بالاسم أو الهاتف.
--
-- مهم:
-- - لا تحل هذه الهجرة Farmer RLS / م-16 بعد؛ إنها prerequisite لها.
-- - لا تربط iam.roles بcore.well_assignments؛ م-18 تبقى مفتوحة.
-- - لا تضيف أي api.* RPC.
-- - لا backfill تخميني.
-- =====================================================================

begin;

-- نحتاج مفتاحًا مركبًا حتى تضمن قاعدة البيانات أن person_id
-- ينتمي فعلًا إلى tenant_id الموجود في الرابط.
alter table core.persons
  add constraint persons_tenant_id_id_key
  unique (tenant_id, id);


create table iam.profile_person_links (
  id uuid primary key default gen_random_uuid(),

  tenant_id uuid not null
    references core.tenants(id),

  profile_id uuid not null
    references iam.profiles(id),

  person_id uuid not null,

  linked_at timestamptz not null default now(),
  linked_by uuid
    references iam.profiles(id),

  link_reason text not null
    check (nullif(btrim(link_reason), '') is not null),

  revoked_at timestamptz,
  revoked_by uuid
    references iam.profiles(id),

  revoke_reason text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint profile_person_links_tenant_person_fkey
    foreign key (tenant_id, person_id)
    references core.persons(tenant_id, id),

  constraint profile_person_links_revoke_time_check
    check (
      revoked_at is null
      or revoked_at >= linked_at
    ),

  constraint profile_person_links_revocation_state_check
    check (
      (
        revoked_at is null
        and revoked_by is null
        and revoke_reason is null
      )
      or
      (
        revoked_at is not null
        and nullif(btrim(revoke_reason), '') is not null
      )
    )
);

comment on table iam.profile_person_links is
  'ق-110: رابطة صريحة وتاريخية بين حساب الدخول والشخص التجاري داخل المستأجر؛ لا يجوز استنتاجها من الاسم أو الهاتف.';

comment on column iam.profile_person_links.profile_id is
  'iam.profiles / auth user account';

comment on column iam.profile_person_links.person_id is
  'core.persons identity inside tenant_id';

comment on column iam.profile_person_links.link_reason is
  'سبب إنشاء الربط الصريح؛ لا يمثل مطابقة آلية أو تخمينًا';


-- حساب الدخول يمكن أن يمثل شخصًا واحدًا فعالًا فقط داخل Tenant.
create unique index profile_person_links_active_profile_tenant_unique
  on iam.profile_person_links (tenant_id, profile_id)
  where revoked_at is null;


-- Person الواحدة لا ترتبط بأكثر من Login Account فعال.
create unique index profile_person_links_active_person_unique
  on iam.profile_person_links (person_id)
  where revoked_at is null;


create index profile_person_links_profile_lookup_idx
  on iam.profile_person_links (profile_id, tenant_id)
  where revoked_at is null;

alter table iam.profile_person_links
  enable row level security;


-- الجدول Internal Identity State.
-- لا Direct Read/Write للعميل.
revoke all on table iam.profile_person_links
  from public, anon, authenticated, service_role;


-- ---------------------------------------------------------------------
-- حماية تاريخ العلاقة:
-- لا Retarget ولا Hard Delete.
-- التصحيح المستقبلي = revoke old link + create explicit new link.
-- ---------------------------------------------------------------------

create function iam.protect_profile_person_link_history()
returns trigger
language plpgsql
security invoker
set search_path = pg_catalog, pg_temp
as $function$
begin
  if tg_op = 'DELETE' then
    raise exception
      'لا يمكن حذف رابط الهوية؛ استخدم إلغاء الرابط مع الاحتفاظ بالتاريخ';
  end if;

  if new.tenant_id is distinct from old.tenant_id
     or new.profile_id is distinct from old.profile_id
     or new.person_id is distinct from old.person_id
     or new.linked_at is distinct from old.linked_at
     or new.linked_by is distinct from old.linked_by
     or new.link_reason is distinct from old.link_reason
  then
    raise exception
      'لا يمكن إعادة توجيه رابط هوية قائم؛ ألغ الرابط وأنشئ رابطًا صريحًا جديدًا';
  end if;

  if old.revoked_at is not null
     and (
       new.revoked_at is distinct from old.revoked_at
       or new.revoked_by is distinct from old.revoked_by
       or new.revoke_reason is distinct from old.revoke_reason
     )
  then
    raise exception
      'لا يمكن تعديل بيانات إلغاء رابط هوية تاريخي';
  end if;

  new.updated_at := now();

  return new;
end;
$function$;


revoke all on function
  iam.protect_profile_person_link_history()
from public, anon, authenticated, service_role;


create trigger trg_profile_person_links_protect_history
before update or delete
on iam.profile_person_links
for each row
execute function iam.protect_profile_person_link_history();


-- ---------------------------------------------------------------------
-- Helper للـRLS المستقبلية.
--
-- يعيد الشخص الفعال المرتبط بالحساب الحالي داخل Tenant محدد.
-- لا يبحث بالاسم، ولا الهاتف، ولا aliases.
-- ---------------------------------------------------------------------

create function iam.current_person_id(
  p_tenant_id uuid
)
returns uuid
language sql
stable
security definer
set search_path = iam, core, pg_temp
as $function$
  select l.person_id
  from iam.profile_person_links l
  join core.persons p
    on p.id = l.person_id
   and p.tenant_id = l.tenant_id
  where l.tenant_id = p_tenant_id
    and l.profile_id = auth.uid()
    and l.revoked_at is null
    and p.status = 'active';
$function$;


comment on function iam.current_person_id(uuid) is
  'ق-110: يعيد Person المرتبطة صراحة بحساب الدخول الحالي داخل Tenant؛ fail-closed بلا تخمين.';


revoke all on function
  iam.current_person_id(uuid)
from public, anon, authenticated, service_role;

grant execute on function
  iam.current_person_id(uuid)
to authenticated;


commit;
