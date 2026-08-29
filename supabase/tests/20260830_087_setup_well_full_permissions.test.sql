begin;

do $test$
declare
  v_api oid := to_regprocedure('api.setup_well_full(jsonb)');
  v_core oid := to_regprocedure('core.setup_well_full(jsonb)');
  v_api_definer boolean;
  v_core_definer boolean;
  v_core_exposed boolean;
  v_direct_dml integer;
begin
  if v_api is not null and has_function_privilege('authenticated', v_api, 'EXECUTE')
     and not has_function_privilege('anon', v_api, 'EXECUTE') then
    raise notice 'PASS 1: authenticated يملك api.setup_well_full وanon محجوب';
  else
    raise notice 'FAIL 1: منح api.setup_well_full غير صحيحة';
  end if;

  select not p.prosecdef into v_api_definer from pg_proc p where p.oid = v_api;
  select p.prosecdef into v_core_definer from pg_proc p where p.oid = v_core;
  if v_api_definer and v_core_definer then
    raise notice 'PASS 2: api invoker وcore definer محفوظان';
  else
    raise notice 'FAIL 2: نمط أمان الدوال تغيّر';
  end if;

  select exists (
    select 1 from pg_namespace n where n.nspname = 'core'
      and has_schema_privilege('authenticated', n.oid, 'USAGE')
  ) into v_core_exposed;
  if v_core_exposed and not has_schema_privilege('authenticated', 'core', 'CREATE') then
    raise notice 'PASS 3: core غير قابل للإنشاء ولا يُضاف إلى Data API';
  else
    raise notice 'FAIL 3: صلاحيات core غير آمنة';
  end if;

  select count(*) into v_direct_dml
  from information_schema.table_privileges
  where grantee = 'authenticated' and table_schema in ('core','ops','iam')
    and privilege_type in ('INSERT','UPDATE','DELETE');
  if v_direct_dml = 0 then
    raise notice 'PASS 4: لا توجد صلاحيات Direct DML جديدة';
  else
    raise notice 'FAIL 4: Direct DML موجودة (% rows)', v_direct_dml;
  end if;
end;
$test$;

rollback;
