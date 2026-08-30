\set ON_ERROR_STOP on

begin;

do $test$
declare
  v_user uuid;
  v_other uuid;
  v_result jsonb;
  v_api oid := to_regprocedure('api.update_profile_name(text)');
  v_internal oid := to_regprocedure('iam.update_own_profile_name(text)');
  v_direct_dml integer;
  v_anon_denied boolean := false;
  v_blank_denied boolean := false;
begin
  if v_api is null or v_internal is null then
    raise exception '088: profile-name functions are missing';
  end if;

  if (select p.prosecdef from pg_proc p where p.oid = v_api) then
    raise exception '088: api.update_profile_name must remain SECURITY INVOKER';
  end if;

  if not (select p.prosecdef from pg_proc p where p.oid = v_internal) then
    raise exception '088: internal profile-name function must be SECURITY DEFINER';
  end if;

  raise notice 'PASS 1: api is INVOKER and internal function is DEFINER';

  if not has_function_privilege('authenticated', v_api, 'EXECUTE')
     or not has_function_privilege('authenticated', v_internal, 'EXECUTE')
     or not has_function_privilege('service_role', v_api, 'EXECUTE')
     or not has_function_privilege('service_role', v_internal, 'EXECUTE')
     or not has_schema_privilege('service_role', 'iam', 'USAGE')
     or has_function_privilege('anon', v_api, 'EXECUTE')
     or has_function_privilege('anon', v_internal, 'EXECUTE') then
    raise exception '088: function grants are incorrect';
  end if;

  raise notice 'PASS 2: authenticated/service_role can traverse the contract and anon is denied';

  select count(*) into v_direct_dml
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where c.relkind in ('r', 'p')
    and n.nspname in (
      'core', 'iam', 'ops', 'billing',
      'finance', 'inventory'
    )
    and (
      has_table_privilege('authenticated', c.oid, 'INSERT')
      or has_table_privilege('authenticated', c.oid, 'UPDATE')
      or has_table_privilege('authenticated', c.oid, 'DELETE')
      or has_table_privilege('anon', c.oid, 'INSERT')
      or has_table_privilege('anon', c.oid, 'UPDATE')
      or has_table_privilege('anon', c.oid, 'DELETE')
    );

  if v_direct_dml <> 0 then
    raise exception '088: Direct DML expanded to % internal tables',
      v_direct_dml;
  end if;

  raise notice 'PASS 3: Direct DML remains zero';

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_user_meta_data, created_at, updated_at
  ) values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'profile-name-088@test.local',
    crypt('x', gen_salt('bf')),
    now(),
    jsonb_build_object(
      'full_name', 'الاسم القديم 088',
      'phone', '+967700000088'
    ),
    now(),
    now()
  ) returning id into v_user;

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_user_meta_data, created_at, updated_at
  ) values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'profile-other-088@test.local',
    crypt('x', gen_salt('bf')),
    now(),
    jsonb_build_object(
      'full_name', 'المستخدم الآخر 088',
      'phone', '+967700000188'
    ),
    now(),
    now()
  ) returning id into v_other;

  perform set_config(
    'request.jwt.claim.sub',
    v_user::text,
    true
  );

  execute 'set local role authenticated';

  select api.update_profile_name('الاسم الجديد 088')
    into v_result;

  execute 'reset role';

  if v_result ->> 'id' <> v_user::text
     or v_result ->> 'full_name' <> 'الاسم الجديد 088' then
    raise exception '088: unexpected response: %', v_result;
  end if;

  if not exists (
    select 1
    from iam.profiles
    where id = v_user
      and full_name = 'الاسم الجديد 088'
  ) then
    raise exception '088: current profile was not updated';
  end if;

  raise notice 'PASS 4: authenticated user updated only the current profile';

  if not exists (
    select 1
    from iam.profiles
    where id = v_other
      and full_name = 'المستخدم الآخر 088'
  ) then
    raise exception '088: another profile was modified unexpectedly';
  end if;

  raise notice 'PASS 5: another profile remained unchanged';

  perform set_config(
    'request.jwt.claim.sub',
    v_user::text,
    true
  );

  execute 'set local role authenticated';

  begin
    perform api.update_profile_name('   ');
  exception
    when invalid_parameter_value then
      v_blank_denied := true;
  end;

  execute 'reset role';

  if not v_blank_denied then
    raise exception '088: blank profile name was accepted';
  end if;

  raise notice 'PASS 6: blank name is rejected';

  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role anon';

  begin
    perform api.update_profile_name('anon must fail');
  exception
    when insufficient_privilege then
      v_anon_denied := true;
  end;

  execute 'reset role';

  if not v_anon_denied then
    raise exception '088: anon unexpectedly invoked profile update';
  end if;

  raise notice 'PASS 7: anon invocation is denied';
end;
$test$;

rollback;
