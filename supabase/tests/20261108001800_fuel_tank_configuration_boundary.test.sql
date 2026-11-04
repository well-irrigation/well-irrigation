\set ON_ERROR_STOP on
begin;
create function pg_temp.ftc_check(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL %',label;end if;raise notice 'PASS %',label;end;$$;
do $test$
declare t uuid;w uuid;other_well uuid;o uuid:=gen_random_uuid();m uuid:=gen_random_uuid();op uuid:=gen_random_uuid();
 outsider uuid:=gen_random_uuid();tank uuid;result jsonb;old_stock jsonb;history_count bigint;body text;
begin
 insert into core.tenants(name) values('tank configuration') returning id into t;
 insert into core.wells(tenant_id,name) values(t,'tank A') returning id into w;
 insert into core.wells(tenant_id,name) values(t,'tank B') returning id into other_well;
 insert into auth.users(id,instance_id,aud,role,email,created_at,updated_at)
 select x,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',x||'@tank.test',now(),now()
 from unnest(array[o,m,op,outsider]) x;
 insert into iam.profiles(id,full_name) select x,'tank configuration actor' from unnest(array[o,m,op,outsider]) x on conflict(id) do nothing;
 insert into core.well_assignments(well_id,profile_id,role,status)
 values(w,o,'owner','active'),(w,m,'manager','active'),(w,op,'operator','active'),(other_well,outsider,'owner','active');
 perform set_config('request.jwt.claim.sub',o::text,true);
 execute 'set local role authenticated';
 result:=api.create_fuel_tank(w,'owner tank',100000,'manual');tank:=(result->>'fuel_tank_id')::uuid;
 execute 'reset role';
 perform pg_temp.ftc_check((select current_balance_ml=0 and avg_cost_per_liter_minor=0 from inventory.fuel_tanks where id=tank),'owner creates metadata only');
 perform set_config('request.jwt.claim.sub',m::text,true);
 execute 'set local role authenticated';
 result:=api.create_fuel_tank(w,'manager tank',null,'estimated');
 result:=api.configure_fuel_tank(tank,'manager rename',100000,'dipstick','active');
 execute 'reset role';
 perform pg_temp.ftc_check((select name='manager rename' and measurement_method='dipstick' from inventory.fuel_tanks where id=tank),'manager creates/configures same-well tank');
 -- Owner-only probe fixture: represent existing stock, never through the API.
 update inventory.fuel_tanks set current_balance_ml=10000,avg_cost_per_liter_minor=500 where id=tank;
 select jsonb_build_object('quantity',current_balance_ml,'cost',avg_cost_per_liter_minor) into old_stock from inventory.fuel_tanks where id=tank;
 perform set_config('request.jwt.claim.sub',op::text,true);
 execute 'set local role authenticated';
 result:=api.configure_fuel_tank(tank,'operator rename',100000,'meter','inactive');
 begin perform api.create_fuel_tank(w,'operator cannot create');raise exception 'EXPECTED_CREATE_DENIED';exception when insufficient_privilege then null;end;
 execute 'reset role';
 perform pg_temp.ftc_check((select status='inactive' and name='operator rename' from inventory.fuel_tanks where id=tank)
  and old_stock=(select jsonb_build_object('quantity',current_balance_ml,'cost',avg_cost_per_liter_minor) from inventory.fuel_tanks where id=tank),'operator may disable stocked tank without changing stock/cost');
 perform pg_temp.ftc_check(result->>'message'='تم إيقاف الخزان. بقي رصيده وسجله محفوظين.','simple inactive UX state');
 result:=api.configure_fuel_tank(tank,'operator rename',100000,'meter','active');
 perform pg_temp.ftc_check((select status='active' from inventory.fuel_tanks where id=tank),'same tank may reactivate');
 perform set_config('request.jwt.claim.sub',outsider::text,true);
 begin perform api.configure_fuel_tank(tank,'cross well',null,'manual','active');raise exception 'EXPECTED_CROSS_WELL_DENIED';exception when insufficient_privilege then null;end;
 begin perform api.create_fuel_tank(w,'cross well');raise exception 'EXPECTED_CROSS_WELL_CREATE_DENIED';exception when insufficient_privilege then null;end;
 perform set_config('request.jwt.claim.sub',o::text,true);
 execute 'set local role authenticated';
 begin insert into inventory.fuel_tanks(tenant_id,well_id,name) values(t,w,'direct');raise exception 'EXPECTED_INSERT_DENIED';exception when insufficient_privilege then null;end;
 begin update inventory.fuel_tanks set current_balance_ml=0 where id=tank;raise exception 'EXPECTED_UPDATE_DENIED';exception when insufficient_privilege then null;end;
 begin delete from inventory.fuel_tanks where id=tank;raise exception 'EXPECTED_DELETE_DENIED';exception when insufficient_privilege then null;end;
 perform pg_temp.ftc_check((select count(*)=1 from inventory.fuel_tanks where id=tank),'SELECT preserved');
 execute 'reset role';
 select count(*) into history_count from inventory.fuel_tank_configuration_history where fuel_tank_id=tank;
 perform pg_temp.ftc_check(history_count=4,'create and every configuration mutation preserve history');
 begin delete from inventory.fuel_tank_configuration_history where fuel_tank_id=tank;raise exception 'EXPECTED_HISTORY_DENIED';exception when check_violation then null;end;
 update core.well_assignments set status='inactive' where well_id=w and profile_id=op;
 perform set_config('request.jwt.claim.sub',op::text,true);
 begin perform api.configure_fuel_tank(tank,'inactive actor',null,'manual','inactive');raise exception 'EXPECTED_INACTIVE_DENIED';exception when insufficient_privilege then null;end;
 select pg_get_functiondef('finance.r6c2_api_configure_fuel_tank(uuid,text,bigint,text,text)'::regprocedure) into body;
 perform pg_temp.ftc_check(position('billing.lock_customer_credit_well' in body)<position('for update' in body)
  and position('is distinct from(candidate.well_id,candidate.tenant_id)' in body)>0,'root before tank lock, scope rechecked');
 perform pg_temp.ftc_check(old_stock=(select jsonb_build_object('quantity',current_balance_ml,'cost',avg_cost_per_liter_minor) from inventory.fuel_tanks where id=tank),'configuration never changes quantities or financial valuation');
end;$test$;
rollback;
