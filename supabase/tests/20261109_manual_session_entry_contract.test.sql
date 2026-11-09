\set ON_ERROR_STOP on
-- Owner-run RED gate. No implementation or grants are installed by this test.
begin;
set local timezone='UTC';
create function pg_temp.manual_check(ok boolean,label text) returns void
language plpgsql as $$
begin
 if ok is distinct from true then raise exception 'FAIL %',label;end if;
 raise notice 'PASS %',label;
end;$$;

do $surface$
declare name text; signature text; fn oid;
begin
 perform pg_temp.manual_check(to_regprocedure('ops.manual_session_entry_mode(uuid)') is not null,
  'trusted provenance foundation required before public entry');
 foreach name in array array['record_historical_session','adopt_external_session'] loop
  signature:='api.'||name||'(uuid,uuid,jsonb)';
  fn:=to_regprocedure(signature);
  perform pg_temp.manual_check(fn is not null,'missing general manual entry contract: '||signature);
  perform pg_temp.manual_check((select not prosecdef and prorettype='jsonb'::regtype
    and provolatile='v' and proargnames=array['p_well_id','p_command_id','p_request']::text[]
    from pg_proc where oid=fn),'INVOKER JSON contract without actor/booking authority: '||name);
  perform pg_temp.manual_check(has_function_privilege('authenticated',fn,'EXECUTE')
    and not has_function_privilege('anon',fn,'EXECUTE')
    and not exists(select 1 from pg_proc p,
      lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
      where p.oid=fn and a.grantee=0 and a.privilege_type='EXECUTE'),
    'authenticated-only mutation: '||name);
 end loop;
 fn:=to_regprocedure('api.get_manual_session_entry_receipt(uuid,uuid)');
 perform pg_temp.manual_check(fn is not null,'manual entry receipt exists independently of rejected requests');
 perform pg_temp.manual_check((select not prosecdef and provolatile='s'
   and prorettype='jsonb'::regtype from pg_proc where oid=fn),'receipt is stable INVOKER');
end;$surface$;

-- Unauthenticated callers must not gain authority from claimed actor metadata.
do $anonymous$
declare name text; denied boolean;result jsonb;
begin
 perform set_config('request.jwt.claim.sub','',true);
 foreach name in array array['record_historical_session','adopt_external_session'] loop
  denied:=false;
  begin
   execute 'set local role anon';
   execute format('select api.%I($1,$2,$3)',name)
     into result using gen_random_uuid(),gen_random_uuid(),jsonb_build_object(
      'version',1,'actor_id',gen_random_uuid(),'reason','manual entry');
  exception when insufficient_privilege or invalid_authorization_specification then denied:=true;
  end;
  execute 'reset role';
  perform pg_temp.manual_check(denied,'anonymous manual entry denied: '||name);
 end loop;
end;$anonymous$;
rollback;
