\set ON_ERROR_STOP on
-- Owner execution only. Authored statically; no execution by the agent.
begin;
create function pg_temp.account_check(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL %',label;end if;raise notice 'PASS %',label;end;$$;
do $test$
declare t uuid;w uuid;other_well uuid;actor uuid:=gen_random_uuid();manager uuid:=gen_random_uuid();person uuid;profile uuid;account uuid;
 before_row jsonb;r jsonb;body text;invoice uuid;other_account uuid;
begin
 insert into core.tenants(name) values('account status boundary') returning id into t;
 insert into core.wells(tenant_id,name) values(t,'account well') returning id into w;
 insert into core.wells(tenant_id,name) values(t,'other account well') returning id into other_well;
 insert into auth.users(id,instance_id,aud,role,email,created_at,updated_at)
 select x,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',x||'@account.test',now(),now()
 from unnest(array[actor,manager])x;
 insert into iam.profiles(id,full_name) values(actor,'account owner'),(manager,'account manager') on conflict(id) do nothing;
 insert into core.well_assignments(well_id,profile_id,role,status) values(w,actor,'owner','active'),(w,manager,'manager','active');
 insert into core.persons(tenant_id,full_name,normalized_name) values(t,'account farmer','account farmer') returning id into person;
 insert into ops.farmer_profiles(tenant_id,person_id) values(t,person) returning id into profile;
 insert into ops.farmer_well_accounts(tenant_id,farmer_profile_id,well_id,public_code) values(t,profile,w,'FA-status') returning id into account;
 insert into ops.farmer_well_accounts(tenant_id,farmer_profile_id,well_id,public_code)
 values(t,profile,other_well,'FA-other') returning id into other_account;
 insert into billing.invoices(tenant_id,public_code,well_id,farmer_well_account_id,invoice_date,status,subtotal_minor,total_minor,paid_minor,outstanding_minor)
 values(t,core.generate_public_code('INV'),w,account,clock_timestamp(),'draft',10000,10000,0,10000) returning id into invoice;
 update billing.invoices set status='issued' where id=invoice;
 select to_jsonb(a)-'status' into before_row from ops.farmer_well_accounts a where id=account;
 perform set_config('request.jwt.claim.sub',actor::text,true);
 execute 'set local role authenticated';
 r:=api.set_farmer_account_active(account,false);
 perform pg_temp.account_check(r->>'status'='saved' and r->>'account_status'='inactive','active owner stops only this well account');
 begin perform api.set_farmer_account_active(other_account,false);raise exception 'EXPECTED_CROSS_WELL_DENIED';
 exception when insufficient_privilege then null;end;
 r:=api.record_payment(p_well_id=>w,p_farmer_well_account_id=>account,p_amount_minor=>1000,p_method=>'cash',
  p_allocations=>jsonb_build_array(jsonb_build_object('invoice_id',invoice,'amount_minor',1000)),p_command_id=>gen_random_uuid());
 begin update ops.farmer_well_accounts set status='active' where id=account;raise exception 'EXPECTED_DIRECT_STATUS_DENIED';
 exception when insufficient_privilege then null;end;
 execute 'reset role';
 perform pg_temp.account_check((select collectible_minor=9000 from billing.invoice_effective_balances where invoice_id=invoice)
  and (select total_minor=10000 from billing.invoices where id=invoice),'stopped account keeps real collection and canonical old debt');
 perform pg_temp.account_check(before_row=(select to_jsonb(a)-'status' from ops.farmer_well_accounts a where id=account),
  'deactivation does not rewrite account identity, credit limit, notes or history');
 perform pg_temp.account_check((select status='active' from ops.farmer_profiles where id=profile),
  'tenant-wide farmer identity unchanged');
 perform set_config('request.jwt.claim.sub',manager::text,true);execute 'set local role authenticated';
 begin perform api.set_farmer_account_active(account,true);raise exception 'EXPECTED_MANAGER_DENIED';
 exception when insufficient_privilege then null;end;
 execute 'reset role';
 perform set_config('request.jwt.claim.sub',actor::text,true);execute 'set local role authenticated';
 r:=api.set_farmer_account_active(account,true);
 execute 'reset role';
 perform pg_temp.account_check(r->>'account_status'='active' and (select count(*)=2 from ops.farmer_account_status_history where account_id=account),
  'reactivation preserves both accepted state changes');
 execute 'set local role authenticated';
 r:=api.set_farmer_account_credit_limit(account,25000);
 r:=api.set_farmer_account_notes(account,'ملاحظات الحساب في هذا البئر');
 begin update ops.farmer_well_accounts set credit_limit_minor=50000 where id=account;raise exception 'EXPECTED_DIRECT_LIMIT_DENIED';
 exception when insufficient_privilege then null;end;
 execute 'reset role';
 perform pg_temp.account_check((select credit_limit_minor=25000 and notes='ملاحظات الحساب في هذا البئر' from ops.farmer_well_accounts where id=account),
  'owner saves per-well limit and notes through narrow APIs');
 perform set_config('request.jwt.claim.sub',manager::text,true);execute 'set local role authenticated';
 begin perform api.set_farmer_account_credit_limit(account,50000);raise exception 'EXPECTED_MANAGER_LIMIT_DENIED';
 exception when insufficient_privilege then null;end;
 execute 'reset role';
 update core.well_assignments set role='operator' where well_id=w and profile_id=manager;
 execute 'set local role authenticated';
 r:=api.set_farmer_account_notes(account,'ملاحظة المشغّل');
 begin perform api.set_farmer_account_credit_limit(account,50000);raise exception 'EXPECTED_OPERATOR_LIMIT_DENIED';
 exception when insufficient_privilege then null;end;
 execute 'reset role';
 perform pg_temp.account_check((select count(*)=3 from ops.farmer_account_settings_history where account_id=account),
  'configuration changes preserve previous values and actor');
 perform set_config('request.jwt.claim.sub',actor::text,true);
 update core.well_assignments set status='inactive' where well_id=w and profile_id=actor;
 execute 'set local role authenticated';
 begin perform api.set_farmer_account_active(account,false);raise exception 'EXPECTED_INACTIVE_OWNER_DENIED';
 exception when insufficient_privilege then null;end;
 execute 'reset role';
 body:=pg_get_functiondef('finance.r6c2_api_set_farmer_account_active(uuid,boolean)'::regprocedure);
 perform pg_temp.account_check(position('billing.enter_financial_write' in body)<position('for update' in body)
  and position('farmer_account_owner_required' in body)>position('for update' in body),'root first and owner rechecked after wait');
 body:=pg_get_functiondef('billing.record_payment(uuid,uuid,bigint,text,jsonb,uuid,uuid,uuid,timestamptz,text,text)'::regprocedure);
 perform pg_temp.account_check(position('fwa.status = ''active''' in body)=0,'inactive well account still permits existing payment collection');
 perform pg_temp.account_check(exists(select 1 from pg_trigger where tgrelid='ops.irrigation_bookings'::regclass
  and tgname='booking_active_farmer_account'),'new booking checks active account after well scope protection');
end;$test$;
rollback;
