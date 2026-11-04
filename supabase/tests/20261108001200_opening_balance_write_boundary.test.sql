\set ON_ERROR_STOP on
-- Owner-only local regression, all evidence rolled back; STATIC authoring only.
begin;
set local timezone='UTC';
create function pg_temp.ob_check(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL %',label;end if;raise notice 'PASS %',label;end;$$;
do $test$
declare t uuid;w uuid;other_w uuid;other_t uuid;actor uuid:=gen_random_uuid();outsider uuid:=gen_random_uuid();
 b uuid;i uuid;capital uuid;cash uuid;box uuid;r text;before_j bigint;before_f bigint;before_p bigint;body text;
begin
 insert into core.tenants(name) values('opening boundary') returning id into t;
 insert into core.tenants(name) values('other opening tenant') returning id into other_t;
 insert into auth.users(id,instance_id,aud,role,email,created_at,updated_at)
 values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@ob.test',now(),now()),
 (outsider,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',outsider||'@ob.test',now(),now());
 insert into iam.profiles(id,full_name) values(actor,'opening owner'),(outsider,'other owner') on conflict(id) do nothing;
 insert into core.wells(tenant_id,name) values(t,'opening well') returning id into w;
 insert into core.wells(tenant_id,name) values(other_t,'other opening well') returning id into other_w;
 insert into core.well_assignments(well_id,profile_id,role,status) values(w,actor,'owner','active'),(other_w,outsider,'owner','active');
 box:=finance.main_cashbox_id(w);
 select count(*) into before_j from finance.journal_entries;
 select count(*) into before_f from inventory.fuel_transactions;
 select count(*) into before_p from billing.payments;
 perform set_config('request.jwt.claim.sub',actor::text,true);
 execute 'set local role authenticated';
 b:=api.create_opening_balance_batch(w,current_date,'  unchanged notes  ');
 i:=api.add_opening_balance_item(b,'cashbox_balance',100, null,null,null,box);
 perform api.update_opening_balance_item(i,'cashbox_balance',200,null,null,null,box);
 capital:=api.add_opening_balance_item(b,'capital_balance',200);
 select description into r from finance.opening_balance_items where id=i;
 execute 'reset role';
 perform pg_temp.ob_check((select status='draft' and tenant_id=t and well_id=w and created_by=actor
  and notes='  unchanged notes  ' from finance.opening_balance_batches where id=b),'owner creates exact scoped draft');
 perform pg_temp.ob_check((select amount_minor=200 and batch_id=b and tenant_id=t from finance.opening_balance_items where id=i),'owner add/update same item identity');
 perform pg_temp.ob_check((select count(*)=2 from finance.opening_balance_items where batch_id=b),'no duplicate item on update');
 perform pg_temp.ob_check(before_j=(select count(*) from finance.journal_entries) and before_f=(select count(*) from inventory.fuel_transactions)
  and before_p=(select count(*) from billing.payments),'draft writes create no journal/fuel/payment value');
 perform set_config('request.jwt.claim.sub',outsider::text,true);
 begin perform api.add_opening_balance_item(b,'capital_balance',1);raise exception 'EXPECTED_DENIED';
 exception when insufficient_privilege then null;end;
 begin perform api.create_opening_balance_batch(w,current_date);raise exception 'EXPECTED_DENIED';
 exception when insufficient_privilege then null;end;
 perform set_config('request.jwt.claim.sub',actor::text,true);
 update core.well_assignments set status='inactive' where well_id=w and profile_id=actor;
 begin perform api.add_opening_balance_item(b,'capital_balance',1);raise exception 'EXPECTED_INACTIVE_DENIED';
 exception when insufficient_privilege then null;end;
 update core.well_assignments set status='active' where well_id=w and profile_id=actor;
 begin perform api.create_opening_balance_batch(other_w,current_date);raise exception 'EXPECTED_DENIED';
 exception when insufficient_privilege then null;end;
 begin perform api.add_opening_balance_item(b,'cashbox_balance',1,null,null,null,finance.main_cashbox_id(other_w));raise exception 'EXPECTED_SCOPE_DENIED';
 exception when check_violation then null;end;
 perform set_config('request.jwt.claim.sub','',true);
 begin perform api.create_opening_balance_batch(w,current_date);raise exception 'EXPECTED_ANON_DENIED';
 exception when insufficient_privilege then null;end;
 perform set_config('request.jwt.claim.sub',actor::text,true);
 execute 'set local role authenticated';
 begin insert into finance.opening_balance_batches(tenant_id,well_id,reference_date) values(t,w,current_date);raise exception 'EXPECTED_INSERT_DENIED';
 exception when insufficient_privilege then null;end;
 begin insert into finance.opening_balance_items(tenant_id,batch_id,item_type,amount_minor) values(t,b,'capital_balance',1);raise exception 'EXPECTED_ITEM_INSERT_DENIED';
 exception when insufficient_privilege then null;end;
 begin update finance.opening_balance_batches set notes='forbidden' where id=b;raise exception 'EXPECTED_BATCH_UPDATE_DENIED';
 exception when insufficient_privilege then null;end;
 begin update finance.opening_balance_items set amount_minor=999 where id=i;raise exception 'EXPECTED_UPDATE_DENIED';
 exception when insufficient_privilege then null;end;
 begin delete from finance.opening_balance_items where id=i;raise exception 'EXPECTED_DELETE_DENIED';
 exception when insufficient_privilege then null;end;
 execute 'reset role';
 perform pg_temp.ob_check(not has_any_column_privilege('authenticated','finance.opening_balance_items','UPDATE')
  and not has_table_privilege('authenticated','finance.opening_balance_batches','INSERT'),'table and column direct DML denied');
 perform pg_temp.ob_check(not has_function_privilege('anon','api.create_opening_balance_batch(uuid,date,text)','EXECUTE'),'anon RPC execute denied');
 -- Existing approval/post functions are unchanged; new draft objects feed them.
 perform finance.approve_opening_balance_batch(b,actor);
 begin perform api.update_opening_balance_item(i,'cashbox_balance',300,null,null,null,box);raise exception 'EXPECTED_APPROVED_DENIED';
 exception when check_violation then null;end;
 perform finance.post_opening_balance_batch(b,actor);
 perform pg_temp.ob_check((select status='posted' from finance.opening_balance_batches where id=b),'existing balanced approval/post workflow works');
 perform pg_temp.ob_check((select count(*)=1 from finance.journal_entries where source_type='opening_balance' and source_id=b),'one original opening journal');
 begin perform finance.post_opening_balance_batch(b,actor);raise exception 'EXPECTED_REPOST_DENIED';
 exception when raise_exception then if SQLERRM='EXPECTED_REPOST_DENIED' then raise;end if;end;
 perform pg_temp.ob_check((select count(*)=1 from finance.journal_entries where source_type='opening_balance' and source_id=b),'repost cannot duplicate financial value');
 foreach r in array array['approved','posted','reversed'] loop
  b:=api.create_opening_balance_batch(w,current_date);i:=api.add_opening_balance_item(b,'capital_balance',1);
  update finance.opening_balance_batches set status=r where id=b;
  begin perform api.update_opening_balance_item(i,'capital_balance',2);raise exception 'EXPECTED_STATE_DENIED';
  exception when check_violation then null;end;
 end loop;
 b:=api.create_opening_balance_batch(w,current_date);
 update finance.opening_balance_batches set status='pending_approval' where id=b;
 i:=api.add_opening_balance_item(b,'capital_balance',1);
 perform pg_temp.ob_check(i is not null,'pending approval remains editable before approval');
 select pg_get_functiondef('finance.lock_editable_opening_batch(uuid)'::regprocedure) into body;
 perform pg_temp.ob_check(position('billing.lock_customer_credit_well' in body)<position('for update of x' in body)
  and position('opening_batch_scope_changed' in body)>0
  and position('opening_batch_not_editable' in body)>position('for update of x' in body),
  'root precedes batch lock; scope/status checked after wait');
 perform pg_temp.ob_check(exists(select 1 from pg_constraint where conrelid='finance.opening_balance_items'::regclass
  and confrelid='finance.opening_balance_batches'::regclass and contype='f'),'batch FK retained');
 perform pg_temp.ob_check(exists(select 1 from pg_trigger where tgrelid='finance.opening_balance_items'::regclass
  and tgname='opening_balance_items_validate' and tgenabled<>'D'),'existing accounting validator retained');
end;$test$;
rollback;
