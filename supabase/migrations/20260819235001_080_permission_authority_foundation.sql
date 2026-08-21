-- =====================================================================
-- 080 — W1-03 / م-18
-- Permission Authority Foundation
--
-- الهدف:
-- ربط core.well_assignments بكتالوج iam.roles / iam.permissions /
-- iam.role_permissions دون توسيع صلاحيات المستخدمين الحالية.
--
-- قواعد التصميم:
-- 1) Preserve Existing Authority: لا صلاحيات كتابة جديدة للأدوار التي
--    لم تكن تملكها في API الحالية.
-- 2) owner -> tenant_owner permission bundle، لكن النطاق يبقى well_id.
--    لا تنشئ هذه الهجرة Tenant-wide access.
-- 3) manager -> well_manager.
-- 4) operator / partner / accountant / viewer تطابق codes النظامية.
-- 5) farmer خارج Administrative Role Authority؛ وصوله الذاتي تحكمه 079.
-- 6) RLS policies القديمة وiam.has_well_role تبقى Compatibility Layer.
-- 7) API enforcement الفعلي ينتقل إلى Permission Codes في Migration 081.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- A. Expand the permission catalog to cover current V1 write contracts.
-- Existing 21 permission codes remain unchanged.
-- ---------------------------------------------------------------------

insert into iam.permissions (code, description_ar)
values
  ('session.resume', 'استئناف جلسة سقي'),
  ('invoice.issue', 'إصدار فاتورة جلسة'),
  ('payment.allocate', 'تخصيص دفعة على فواتير'),
  ('distribution.pay', 'صرف استحقاق توزيع لشريك'),
  ('fuel.purchase', 'تسجيل شراء وقود'),
  ('fuel.consume', 'تسجيل استهلاك وقود'),
  ('fuel.count', 'تسجيل جرد فعلي للوقود'),
  ('shift.open', 'فتح مناوبة تشغيل'),
  ('shift.close', 'إغلاق المناوبة الخاصة بالمستخدم'),
  ('shift.close_override', 'إغلاق مناوبة بتجاوزات إدارية'),
  ('handover.declare', 'إقرار تسليم مناوبة'),
  ('handover.confirm', 'تأكيد استلام وتسوية فرق التسليم'),
  ('handover.settle', 'حسم فرق تسليم المناوبة'),
  ('session.transfer.request', 'طلب نقل جلسة بين المناوبات'),
  ('session.transfer.respond', 'الرد على طلب نقل جلسة'),
  ('payroll.accrue', 'إثبات استحقاق راتب'),
  ('payroll.pay', 'صرف راتب مستحق')
on conflict (code) do nothing;


-- ---------------------------------------------------------------------
-- B. Canonical bridge: legacy assignment role -> system role bundle.
--
-- farmer intentionally has no row here.
-- ---------------------------------------------------------------------

create table iam.well_assignment_role_map (
  assignment_role text primary key,
  role_id uuid not null
    references iam.roles(id)
    on delete restrict,
  created_at timestamptz not null default now(),
  constraint well_assignment_role_map_role_check
    check (
      assignment_role in (
        'owner',
        'manager',
        'operator',
        'partner',
        'accountant',
        'viewer'
      )
    )
);

comment on table iam.well_assignment_role_map is
  'W1-03: bridge from core.well_assignments.role legacy codes to canonical iam.roles permission bundles. farmer is intentionally excluded and remains identity/self-scope based.';

alter table iam.well_assignment_role_map
  enable row level security;

create policy well_assignment_role_map_select_authenticated
on iam.well_assignment_role_map
for select
to authenticated
using ((select auth.uid()) is not null);

revoke all on table iam.well_assignment_role_map
from public, anon, authenticated;

grant select on table iam.well_assignment_role_map
to authenticated;

insert into iam.well_assignment_role_map (
  assignment_role,
  role_id
)
select x.assignment_role, r.id
from (
  values
    ('owner', 'tenant_owner'),
    ('manager', 'well_manager'),
    ('operator', 'operator'),
    ('partner', 'partner'),
    ('accountant', 'accountant'),
    ('viewer', 'viewer')
) as x(assignment_role, role_code)
join iam.roles r
  on r.code = x.role_code;


-- ---------------------------------------------------------------------
-- C. Allow canonical accountant/viewer assignments.
-- Existing legacy values stay valid.
-- ---------------------------------------------------------------------

alter table core.well_assignments
  drop constraint well_assignments_role_check;

alter table core.well_assignments
  add constraint well_assignments_role_check
  check (
    role in (
      'owner',
      'operator',
      'farmer',
      'manager',
      'partner',
      'accountant',
      'viewer'
    )
  );


-- ---------------------------------------------------------------------
-- D. Conservative role-permission seed.
--
-- tenant_owner:
--   full system permission catalog.
--
-- well_manager:
--   ONLY operations already allowed to manager by current API/internal
--   function authorization.
--
-- operator:
--   ONLY operations already allowed to operator by current API/internal
--   function authorization.
--
-- partner/accountant/viewer:
--   no new write grants in 080. Their future write authority requires an
--   explicit later decision, preventing silent privilege expansion.
-- ---------------------------------------------------------------------

insert into iam.role_permissions (
  role_id,
  permission_id
)
select
  r.id,
  p.id
from iam.roles r
cross join iam.permissions p
where r.code = 'tenant_owner'
on conflict do nothing;


with grants(role_code, permission_code) as (
  values
    -- well_manager — preserve current behavior only
    ('well_manager', 'session.start'),
    ('well_manager', 'session.pause'),
    ('well_manager', 'session.resume'),
    ('well_manager', 'session.complete'),
    ('well_manager', 'session.correct'),
    ('well_manager', 'invoice.issue'),
    ('well_manager', 'payment.create'),
    ('well_manager', 'payment.allocate'),
    ('well_manager', 'distribution.pay'),
    ('well_manager', 'period.close'),
    ('well_manager', 'payroll.accrue'),
    ('well_manager', 'payroll.pay'),

    -- operator — preserve current behavior only
    ('operator', 'farmer.create'),
    ('operator', 'booking.create'),
    ('operator', 'booking.reschedule'),
    ('operator', 'session.start'),
    ('operator', 'session.pause'),
    ('operator', 'session.resume'),
    ('operator', 'session.complete'),
    ('operator', 'session.correct'),
    ('operator', 'invoice.issue'),
    ('operator', 'payment.create'),
    ('operator', 'payment.allocate'),
    ('operator', 'expense.create'),
    ('operator', 'fuel.purchase'),
    ('operator', 'fuel.consume'),
    ('operator', 'fuel.count'),
    ('operator', 'shift.open'),
    ('operator', 'shift.close'),
    ('operator', 'handover.declare'),
    ('operator', 'session.transfer.request'),
    ('operator', 'session.transfer.respond')
)
insert into iam.role_permissions (
  role_id,
  permission_id
)
select
  r.id,
  p.id
from grants g
join iam.roles r
  on r.code = g.role_code
join iam.permissions p
  on p.code = g.permission_code
on conflict do nothing;


-- ---------------------------------------------------------------------
-- E. Canonical permission authority helper.
-- ---------------------------------------------------------------------

create function iam.has_well_permission(
  p_well_id uuid,
  p_permission_code text
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, pg_temp
as $function$
  select exists (
    select 1
    from core.well_assignments wa
    join iam.well_assignment_role_map arm
      on arm.assignment_role = wa.role
    join iam.role_permissions rp
      on rp.role_id = arm.role_id
    join iam.permissions perm
      on perm.id = rp.permission_id
    where wa.well_id = p_well_id
      and wa.profile_id = auth.uid()
      and wa.status = 'active'
      and perm.code = p_permission_code
  );
$function$;

comment on function
  iam.has_well_permission(uuid, text)
is
  'W1-03 canonical well-scoped permission check. Reads active well assignment -> canonical role bundle -> role_permissions. Farmer self access remains separate under Migration 079.';

revoke all on function
  iam.has_well_permission(uuid, text)
from public, anon, authenticated, service_role;

grant execute on function
  iam.has_well_permission(uuid, text)
to authenticated;


commit;
