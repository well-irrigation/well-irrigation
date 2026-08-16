begin;

-- مسبار مؤقت يثبت نمط إنشاء دوال api الصحيح:
-- الإنشاء ثم REVOKE الفوري ثم المنح الانتقائي عند الحاجة.
create function api.__q78_default_privilege_probe()
returns integer
language sql
as $function$
  select 1;
$function$;

revoke all on function api.__q78_default_privilege_probe()
  from public, anon, authenticated, service_role;

do $test$
declare
  v_health_oid oid;
  v_probe_oid oid;
  v_payload jsonb;
  v_is_definer boolean;
  v_anon_function_count integer;
begin
  if to_regnamespace('api') is not null then
    raise notice 'PASS 1: مخطط api موجود';
  else
    raise notice 'FAIL 1: مخطط api غير موجود';
  end if;

  if has_schema_privilege('authenticated', 'api', 'USAGE')
     and not has_schema_privilege('authenticated', 'api', 'CREATE')
     and not has_schema_privilege('anon', 'api', 'USAGE') then
    raise notice 'PASS 2: authenticated يملك USAGE فقط وanon محجوب عن api';
  else
    raise notice 'FAIL 2: صلاحيات مخطط api لا تطابق ق-78';
  end if;

  if has_schema_privilege('service_role', 'api', 'USAGE')
     and not has_schema_privilege('service_role', 'api', 'CREATE') then
    raise notice 'PASS 3: service_role يملك USAGE بلا CREATE داخل api';
  else
    raise notice 'FAIL 3: صلاحيات service_role على api غير صحيحة';
  end if;

  v_health_oid := to_regprocedure('api.health()');

  if v_health_oid is not null
     and has_function_privilege('authenticated', v_health_oid, 'EXECUTE')
     and has_function_privilege('service_role', v_health_oid, 'EXECUTE')
     and not has_function_privilege('anon', v_health_oid, 'EXECUTE') then
    raise notice 'PASS 4: api.health لها منح EXECUTE صريحة فقط للأدوار المعتمدة';
  else
    raise notice 'FAIL 4: صلاحيات api.health غير صحيحة';
  end if;

  select api.health() into v_payload;

  if v_payload = jsonb_build_object(
       'status', 'ok',
       'contract', 'api',
       'version', 1
     ) then
    raise notice 'PASS 5: api.health تعيد عقد الصحة المتوقع';
  else
    raise notice 'FAIL 5: api.health أعادت قيمة غير متوقعة: %', v_payload;
  end if;

  select p.prosecdef
    into v_is_definer
  from pg_proc p
  where p.oid = v_health_oid;

  if v_is_definer = false then
    raise notice 'PASS 6: api.health تعمل SECURITY INVOKER وليست SECURITY DEFINER';
  else
    raise notice 'FAIL 6: api.health تعمل بصلاحيات مالك الدالة';
  end if;

  v_probe_oid := to_regprocedure('api.__q78_default_privilege_probe()');

  select count(*)
    into v_anon_function_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'api'
    and has_function_privilege('anon', p.oid, 'EXECUTE');

  if v_probe_oid is not null
     and not has_function_privilege('anon', v_probe_oid, 'EXECUTE')
     and not has_function_privilege('authenticated', v_probe_oid, 'EXECUTE')
     and not has_function_privilege('service_role', v_probe_oid, 'EXECUTE')
     and v_anon_function_count = 0 then
    raise notice 'PASS 7: REVOKE الصريح أغلق الدالة الجديدة وكل دوال api محجوبة عن anon';
  else
    raise notice 'FAIL 7: توجد دالة api بمنح غير آمنة أو لم يُغلق مسبار الاختبار: anon_functions=%',
      v_anon_function_count;
  end if;
end;
$test$;

rollback;
