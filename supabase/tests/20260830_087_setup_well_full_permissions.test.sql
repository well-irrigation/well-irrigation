\set ON_ERROR_STOP on

begin;

do $test$
declare
  v_user uuid;
  v_result jsonb;
  v_service_result jsonb;
  v_api oid := to_regprocedure('api.setup_well_full(jsonb)');
  v_core oid := to_regprocedure('core.setup_well_full(jsonb)');
  v_direct_dml integer;
  v_anon_denied boolean := false;
begin
  if v_api is null or v_core is null then
    raise exception '087: setup_well_full functions are missing';
  end if;

  if not has_function_privilege('authenticated', v_api, 'EXECUTE')
     or has_function_privilege('anon', v_api, 'EXECUTE') then
    raise exception '087: api grants are not restricted to authenticated callers';
  end if;

  if not has_function_privilege('service_role', v_api, 'EXECUTE')
     or not has_function_privilege('service_role', v_core, 'EXECUTE')
     or not has_schema_privilege('service_role', 'core', 'USAGE') then
    raise exception '087: service_role cannot traverse the api-to-core contract';
  end if;
  raise notice 'PASS 1: api/core grants cover authenticated and service_role; anon is denied';

  if (select p.prosecdef from pg_proc p where p.oid = v_api) then
    raise exception '087: api.setup_well_full must remain SECURITY INVOKER';
  end if;

  if not (select p.prosecdef from pg_proc p where p.oid = v_core) then
    raise exception '087: core.setup_well_full must remain SECURITY DEFINER';
  end if;
  raise notice 'PASS 2: api remains INVOKER and core remains DEFINER';

  select count(*) into v_direct_dml
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where c.relkind in ('r', 'p')
    and n.nspname in ('core', 'iam', 'ops', 'billing', 'finance', 'inventory')
    and (
      has_table_privilege('authenticated', c.oid, 'INSERT')
      or has_table_privilege('authenticated', c.oid, 'UPDATE')
      or has_table_privilege('authenticated', c.oid, 'DELETE')
      or has_table_privilege('anon', c.oid, 'INSERT')
      or has_table_privilege('anon', c.oid, 'UPDATE')
      or has_table_privilege('anon', c.oid, 'DELETE')
    );

  if v_direct_dml <> 0 then
    raise exception '087: Direct DML expanded to % internal tables', v_direct_dml;
  end if;
  raise notice 'PASS 3: Direct DML remains zero for application roles';

  if has_schema_privilege('anon', 'core', 'USAGE')
     or has_schema_privilege('authenticated', 'core', 'CREATE')
     or has_schema_privilege('service_role', 'core', 'CREATE') then
    raise exception '087: core schema privileges expanded beyond traversal';
  end if;
  raise notice 'PASS 4: core grants are traversal-only and exclude anon/CREATE';

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_user_meta_data, created_at, updated_at
  ) values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'setup-well-087@test.local',
    crypt('x', gen_salt('bf')),
    now(),
    jsonb_build_object('full_name', 'مالك اختبار 087', 'phone', '+967700000087'),
    now(),
    now()
  ) returning id into v_user;

  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  select api.setup_well_full(
    jsonb_build_object(
      'well_name', 'بئر اختبار 087',
      'location', 'موقع اختبار محلي',
      'pump_name', 'المضخة الرئيسية',
      'pump_power_source', 'solar',
      'pricing', jsonb_build_object(
        'solar_rate_minor', 3500,
        'well_diesel_rate_minor', 7000,
        'farmer_diesel_rate_minor', 6000
      ),
      'owner_equity_share', 100,
      'owner_profit_share', 100,
      'partners', '[]'::jsonb,
      'operators', '[]'::jsonb
    )
  ) into v_result;

  execute 'reset role';

  if v_result ->> 'status' <> 'success'
     or nullif(v_result ->> 'well_id', '') is null
     or nullif(v_result ->> 'tenant_id', '') is null then
    raise exception '087: authenticated call returned unexpected result: %', v_result;
  end if;
  raise notice 'PASS 5: authenticated setup returned %', v_result;

  if not exists (
    select 1 from core.wells w
    where w.id = (v_result ->> 'well_id')::uuid
      and w.name = 'بئر اختبار 087'
  ) then
    raise exception '087: successful response did not create the expected well';
  end if;
  raise notice 'PASS 6: authenticated setup created the expected well';

  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role service_role';

  select api.setup_well_full(
    jsonb_build_object(
      'well_name', 'بئر خدمة اختبار 087',
      'location', 'موقع اختبار محلي',
      'pump_name', 'المضخة الرئيسية',
      'pump_power_source', 'solar',
      'pricing', jsonb_build_object(
        'solar_rate_minor', 3500,
        'well_diesel_rate_minor', 0,
        'farmer_diesel_rate_minor', 0
      ),
      'owner_equity_share', 100,
      'owner_profit_share', 100,
      'partners', '[]'::jsonb,
      'operators', '[]'::jsonb
    )
  ) into v_service_result;

  execute 'reset role';

  if v_service_result ->> 'status' <> 'success' then
    raise exception '087: service_role call returned unexpected result: %', v_service_result;
  end if;
  raise notice 'PASS 7: service_role traversed the same api contract';

  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role anon';
  begin
    perform api.setup_well_full('{"well_name":"anon must fail"}'::jsonb);
  exception
    when insufficient_privilege then
      v_anon_denied := true;
  end;
  execute 'reset role';

  if not v_anon_denied then
    raise exception '087: anon unexpectedly invoked api.setup_well_full';
  end if;
  raise notice 'PASS 8: anon invocation failed with insufficient_privilege';
end;
$test$;

rollback;
