-- 088 — عقد رسمي لتحديث اسم الملف الشخصي
-- api.* يبقى SECURITY INVOKER، والتنفيذ الداخلي محدود بالمستخدم الحالي.

create or replace function iam.update_own_profile_name(
  p_full_name text
)
returns jsonb
language plpgsql
security definer
set search_path to 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_name text := btrim(coalesce(p_full_name, ''));
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل تحديث الاسم'
      using errcode = '28000';
  end if;

  if v_name = '' then
    raise exception 'الاسم مطلوب'
      using errcode = '22023';
  end if;

  update iam.profiles
  set full_name = v_name,
      updated_at = now()
  where id = v_actor;

  if not found then
    raise exception 'لا يوجد ملف مستخدم للحساب المسجل'
      using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'id', v_actor,
    'full_name', v_name
  );
end;
$function$;

revoke all on function iam.update_own_profile_name(text)
  from public, anon, authenticated, service_role;

-- مثل بقية عقود api: service_role يملك المرور إلى الإجراء
-- الداخلي المحدد فقط، بلا أي Direct DML على جداول iam.
grant usage on schema iam to service_role;

grant execute on function iam.update_own_profile_name(text)
  to authenticated, service_role;

create or replace function api.update_profile_name(
  p_full_name text
)
returns jsonb
language sql
security invoker
set search_path to 'pg_catalog', 'pg_temp'
as $function$
  select iam.update_own_profile_name(p_full_name);
$function$;

revoke all on function api.update_profile_name(text)
  from public, anon, authenticated, service_role;

grant execute on function api.update_profile_name(text)
  to authenticated, service_role;
