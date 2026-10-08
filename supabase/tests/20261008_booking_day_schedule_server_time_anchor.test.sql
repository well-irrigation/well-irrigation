begin;
set local timezone to 'UTC';

create function pg_temp.assert_anchor(p_ok boolean, p_label text)
returns void language plpgsql as $$
begin
  if p_ok is distinct from true then raise exception 'FAIL: %', p_label; end if;
  raise notice 'PASS %', p_label;
end;
$$;

select pg_temp.assert_anchor(to_regprocedure('api.get_well_day_schedule(uuid,date)') is not null, 'signature unchanged');
select pg_temp.assert_anchor(provolatile = 's', 'STABLE preserved')
from pg_proc where oid = 'api.get_well_day_schedule(uuid,date)'::regprocedure;
select pg_temp.assert_anchor(prosrc ~ 'statement_timestamp\(\)' and prosrc !~ 'clock_timestamp\(\)', 'statement timestamp without clock timestamp')
from pg_proc where oid = 'api.get_well_day_schedule(uuid,date)'::regprocedure;
select pg_temp.assert_anchor(not prosecdef, 'SECURITY INVOKER')
from pg_proc where oid = 'api.get_well_day_schedule(uuid,date)'::regprocedure;
select pg_temp.assert_anchor(has_function_privilege('authenticated','api.get_well_day_schedule(uuid,date)','EXECUTE'), 'authenticated EXECUTE');
select pg_temp.assert_anchor(has_function_privilege('service_role','api.get_well_day_schedule(uuid,date)','EXECUTE'), 'service_role EXECUTE');
select pg_temp.assert_anchor(not has_function_privilege('anon','api.get_well_day_schedule(uuid,date)','EXECUTE'), 'anon cannot EXECUTE');
select pg_temp.assert_anchor(not exists (
  select 1 from pg_proc p, lateral aclexplode(p.proacl) a
  where p.oid = 'api.get_well_day_schedule(uuid,date)'::regprocedure
  and a.grantee = 0 and a.privilege_type = 'EXECUTE'), 'PUBLIC cannot EXECUTE');
select pg_temp.assert_anchor(not exists (
  select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='api' and p.prosecdef), 'no API SECURITY DEFINER');
select pg_temp.assert_anchor(prosrc !~* '\m(insert|update|delete)\M', 'read-only function body')
from pg_proc where oid = 'api.get_well_day_schedule(uuid,date)'::regprocedure;

select pg_temp.assert_anchor(not has_table_privilege('authenticated','ops.irrigation_bookings','INSERT,UPDATE,DELETE'), 'no direct booking DML');
select pg_temp.assert_anchor(not has_table_privilege('authenticated','ops.irrigation_sessions','INSERT,UPDATE,DELETE'), 'no direct session DML');

do $$
declare
  v_tenant uuid;
  v_owner uuid := gen_random_uuid();
  v_well uuid;
  v_before timestamptz;
  v_reply jsonb;
  v_time timestamptz;
  v_day date := date '2026-10-08';
begin
  insert into core.tenants(name) values ('server anchor test') returning id into v_tenant;
  insert into auth.users(id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
  values (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
    'anchor@test.local', crypt('x',gen_salt('bf')), now(), now());
  insert into iam.profiles(id,full_name) values(v_owner,'مالك مرساة') on conflict do nothing;
  insert into core.wells(tenant_id,name) values(v_tenant,'بئر المرساة') returning id into v_well;
  insert into core.well_assignments(well_id,profile_id,role,status) values(v_well,v_owner,'owner','active');
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  set local role authenticated;
  v_before := statement_timestamp();
  v_reply := api.get_well_day_schedule(v_well,v_day);
  v_time := (v_reply->>'server_time')::timestamptz;
  perform pg_temp.assert_anchor(v_time = v_before and v_time <= clock_timestamp(), 'server_time is server statement timestamptz');
  perform pg_temp.assert_anchor(v_reply->>'requested_day' = v_day::text, 'requested_day retained');
  perform pg_temp.assert_anchor(v_reply->>'timezone' = 'Asia/Aden', 'timezone retained');
  perform pg_temp.assert_anchor(v_reply->>'well_timezone' = 'Asia/Aden', 'well timezone retained');
  perform pg_temp.assert_anchor((v_reply->>'day_start')::timestamptz = v_day::timestamp at time zone 'Asia/Aden', 'day_start retained');
  perform pg_temp.assert_anchor((v_reply->>'day_end')::timestamptz = (v_day+1)::timestamp at time zone 'Asia/Aden', 'day_end retained');
  perform pg_temp.assert_anchor(v_reply->'bookings' = '[]'::jsonb, 'empty bookings preserved');
  perform pg_temp.assert_anchor(v_reply->'current_session' = 'null'::jsonb, 'no fabricated current session');
  reset role;
end;
$$;
rollback;
