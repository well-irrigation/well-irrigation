-- =====================================================================
-- 077 — ق-82: عقد القراءة الأولي لتهيئة تطبيق Stage 7
--
-- الهدف:
-- توفير سياق المستخدم والآبار المتاحة له عبر api فقط، دون كشف
-- core / iam أو أي مخطط أعمال مباشرة إلى Flutter.
--
-- مصادر الحقيقة الحالية:
-- - هوية الدخول: iam.profiles / auth.uid()
-- - الأدوار التشغيلية: core.well_assignments
-- - وصول الشريك الفعلي: core.well_partners
--
-- م-18 لا تُحل هنا:
-- iam.roles / permissions كتالوج غير مربوط بعد بالنظام التشغيلي.
-- =====================================================================

create function api.app_bootstrap()
returns jsonb
language plpgsql
stable
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
declare
  v_actor_id uuid := auth.uid();
  v_profile jsonb;
  v_wells jsonb;
begin
  if v_actor_id is null then
    raise exception
      'Authentication required for api.app_bootstrap'
      using errcode = '28000';
  end if;

  select jsonb_build_object(
    'id', p.id,
    'full_name', p.full_name,
    'phone', p.phone,
    'is_platform_admin', p.is_platform_admin
  )
  into v_profile
  from iam.profiles p
  where p.id = v_actor_id;

  if v_profile is null then
    raise exception
      'Authenticated profile is missing for user %',
      v_actor_id;
  end if;

  with access_roles as (
    -- النموذج التشغيلي الحالي للأدوار.
    select
      wa.well_id,
      wa.role
    from core.well_assignments wa
    where wa.profile_id = v_actor_id
      and wa.status = 'active'

    union

    -- الشريك قد تكون صلاحيته الفعلية آتية من well_partners
    -- حتى لو لم يوجد سطر partner موازٍ في well_assignments.
    select
      wp.well_id,
      'partner'::text as role
    from core.well_partners wp
    where wp.profile_id = v_actor_id
      and wp.status = 'active'
      and wp.period_end is null
  ),
  accessible_wells as (
    select
      w.id,
      w.tenant_id,
      w.name,
      w.location,
      w.status,
      jsonb_agg(
        ar.role
        order by ar.role
      ) as roles
    from access_roles ar
    join core.wells w
      on w.id = ar.well_id
    group by
      w.id,
      w.tenant_id,
      w.name,
      w.location,
      w.status
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', aw.id,
        'tenant_id', aw.tenant_id,
        'name', aw.name,
        'location', aw.location,
        'status', aw.status,
        'roles', aw.roles
      )
      order by aw.name, aw.id
    ),
    '[]'::jsonb
  )
  into v_wells
  from accessible_wells aw;

  return jsonb_build_object(
    'contract', 'app_bootstrap',
    'version', 1,
    'profile', v_profile,
    'wells', v_wells
  );
end;
$function$;


comment on function api.app_bootstrap() is
  'ق-82: عقد القراءة الأولي لتطبيق Stage 7. يعيد ملف المستخدم والآبار/الأدوار المتاحة وفق النموذج التشغيلي الحالي.';


-- كل دالة api يجب أن تُغلق أولًا ثم تُفتح صراحة.
revoke all on function api.app_bootstrap()
  from public, anon, authenticated, service_role;

grant execute on function api.app_bootstrap()
  to authenticated;

grant execute on function api.app_bootstrap()
  to service_role;
