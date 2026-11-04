\set ON_ERROR_STOP on
-- Owner-local permanent regression, static authoring only.
begin;
set local timezone='UTC';
create function pg_temp.policy_check(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL %',label;end if;raise notice 'PASS %',label;end;$$;
create function pg_temp.c2_fixture(seconds bigint default 10000,paid bigint default 0,invoiced boolean default false,
 paused boolean default false,diesel boolean default false) returns jsonb language plpgsql as $$
declare t uuid;w uuid;actor uuid:=gen_random_uuid();person uuid;farmer uuid;account uuid;farm uuid;pump uuid;sid uuid;
 invoice uuid;start_cmd uuid:=gen_random_uuid();end_cmd uuid:=gen_random_uuid();charge jsonb;payment jsonb;
 at_time timestamptz:=date_trunc('day',transaction_timestamp())-interval '2 days';pause_seconds bigint:=case when paused then 600 else 0 end;
begin
 insert into core.tenants(name) values('C2 fixture') returning id into t;
 insert into auth.users(id,instance_id,aud,role,email,email_confirmed_at,created_at,updated_at)
 values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@c2.test',now(),now(),now());
 insert into iam.profiles(id,full_name) values(actor,'C2 operator') on conflict(id) do nothing;
 insert into core.wells(tenant_id,name) values(t,'C2 well') returning id into w;
 insert into core.well_assignments(well_id,profile_id,role,status) values(w,actor,'operator','active');
 insert into core.persons(tenant_id,full_name,normalized_name) values(t,'C2 farmer','C2 farmer') returning id into person;
 insert into ops.farmer_profiles(tenant_id,person_id) values(t,person) returning id into farmer;
 insert into ops.farmer_well_accounts(tenant_id,farmer_profile_id,well_id,public_code)
 values(t,farmer,w,'C2-'||substr(actor::text,1,8)) returning id into account;
 insert into ops.farms(well_id,name,farmer_well_account_id) values(w,'C2 farm',account) returning id into farm;
 insert into core.pumps(well_id,name,power_source,status) values(w,'C2 pump','diesel','active') returning id into pump;
 insert into billing.well_pricing(well_id,price_per_hour_minor,period_start) values(w,3600,date '1970-01-01');
 insert into ops.shifts(tenant_id,well_id,operator_profile_id,started_at,status) values(t,w,actor,at_time-interval '1 hour','open');
 perform set_config('request.jwt.claim.sub',actor::text,true);
 execute 'set local role authenticated';
 sid:=api.start_operational_session(w,pump,farm,account,case when diesel then 'well_diesel' else 'solar' end,at_time,start_cmd);
 if paused then
  perform api.pause_irrigation_session(sid,'operator_pause',at_time+interval '2000 seconds',gen_random_uuid());
  perform api.resume_irrigation_session(sid,at_time+interval '2600 seconds',gen_random_uuid());
 end if;
 charge:=api.complete_irrigation_session(sid,at_time+(seconds+pause_seconds)*interval '1 second',
  case when diesel then 1000::bigint end,case when diesel then 'estimated' end,null,end_cmd);
 if invoiced then invoice:=api.issue_session_invoice(sid);end if;
 if paid>0 then
  payment:=api.record_payment(p_well_id=>w,p_farmer_well_account_id=>account,p_amount_minor=>paid,
   p_method=>'cash',p_session_charge_id=>(charge->>'session_charge_id')::uuid,
   p_allocations=>case when invoiced then jsonb_build_array(jsonb_build_object('invoice_id',invoice,'amount_minor',paid)) else '[]'::jsonb end,
   p_paid_at=>at_time+(seconds+pause_seconds)*interval '1 second',p_command_id=>gen_random_uuid());
 end if;
 execute 'reset role';
 perform finance.ensure_periods(w,at_time::date);
 return jsonb_build_object('tenant',t,'well',w,'actor',actor,'account',account,'session',sid,'at',at_time,
  'charge',charge->'session_charge_id','invoice',invoice,'payment',payment->'payment_id',
  'pause_seconds',pause_seconds,'posting',at_time+interval '6 hours');
exception when others then execute 'reset role';raise;end;$$;

do $test$
declare f jsonb;person uuid;partner uuid;manager uuid:=gen_random_uuid();r jsonb;old_row jsonb;sid uuid;invoice uuid;
 original ops.irrigation_sessions%rowtype;body text;started timestamptz;policy_id uuid;
begin
 f:=pg_temp.c2_fixture(10000,0,true);
 update core.well_assignments set role='owner' where well_id=(f->>'well')::uuid and profile_id=(f->>'actor')::uuid;
 select fp.person_id into person from ops.farmer_profiles fp join ops.farmer_well_accounts a on a.farmer_profile_id=fp.id where a.id=(f->>'account')::uuid;
 insert into core.well_partners(tenant_id,well_id,person_id,phone,period_start)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,person,'777777777',date '1970-01-01') returning id into partner;
 insert into core.ownership_share_versions(tenant_id,well_id,partner_id,ownership_percentage,profit_percentage,effective_period)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,partner,100,100,daterange(date '1970-01-01',null,'[)'));
 select to_jsonb(i) into old_row from billing.invoices i where id=(f->>'invoice')::uuid;
 execute 'set local role authenticated';
 r:=api.set_partner_irrigation_policy(partner,'normal_customer');
 r:=api.set_partner_irrigation_policy(partner,'deduct_from_profit');policy_id:=(r->>'policy_id')::uuid;
 execute 'reset role';
 perform pg_temp.policy_check(old_row=(select to_jsonb(i) from billing.invoices i where id=(f->>'invoice')::uuid),
  'policy change never rewrites existing unpaid invoice');
 perform pg_temp.policy_check((select count(*)=2 and count(distinct policy_version)=2 and bool_and(accepted_at is not null and accepted_by=(f->>'actor')::uuid)
  from core.partner_irrigation_policies where partner_id=partner),'each server-timed policy snapshot preserves actor/history');
 select * into strict original from ops.irrigation_sessions where id=(f->>'session')::uuid;
 started:=(f->>'at')::timestamptz+interval '8 hours';
 execute 'set local role authenticated';
 sid:=api.start_operational_session((f->>'well')::uuid,original.pump_id,original.farm_id,(f->>'account')::uuid,'solar',started,gen_random_uuid());
 perform api.complete_irrigation_session(sid,started+interval '1 hour',null,null,null,gen_random_uuid());
 invoice:=api.issue_session_invoice(sid);
 execute 'reset role';
 perform pg_temp.policy_check((select partner_policy_id=policy_id and settlement_method='partner_profit_offset' from billing.invoices where id=invoice),
  'new issuance uses current saved policy even if actual session ended before policy save');
 select to_jsonb(i) into old_row from billing.invoices i where id=invoice;
 r:=api.set_partner_irrigation_policy(partner,'normal_customer');
 perform pg_temp.policy_check(old_row=(select to_jsonb(i) from billing.invoices i where id=invoice)
  and(select policy_type='deduct_from_profit' from core.partner_irrigation_policies where id=policy_id),
  'later normal policy cannot change old deduction invoice or its referenced policy');
 r:=api.get_partner_irrigation_policy(partner);
 perform pg_temp.policy_check(r->'current'->>'policy_type'='normal_customer' and jsonb_array_length(r->'history')=3,
  'owner sees current setting and previous policy snapshots');
 insert into auth.users(id,instance_id,aud,role,email,created_at,updated_at)
 values(manager,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',manager||'@policy.test',now(),now());
 insert into iam.profiles(id,full_name) values(manager,'policy manager') on conflict(id) do nothing;
 insert into core.well_assignments(well_id,profile_id,role,status) values((f->>'well')::uuid,manager,'manager','active');
 perform set_config('request.jwt.claim.sub',manager::text,true);
 begin perform api.set_partner_irrigation_policy(partner,'normal_customer');raise exception 'EXPECTED_MANAGER_DENIED';exception when insufficient_privilege then null;end;
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 execute 'set local role authenticated';
 begin update core.partner_irrigation_policies set policy_type='normal_customer' where id=policy_id;raise exception 'EXPECTED_DIRECT_DENIED';exception when insufficient_privilege then null;end;
 execute 'reset role';
 begin delete from core.partner_irrigation_policies where id=policy_id;raise exception 'EXPECTED_HISTORY_DENIED';exception when check_violation then null;end;
 select pg_get_functiondef('finance.r6c2_api_set_partner_irrigation_policy(uuid,text)'::regprocedure) into body;
 perform pg_temp.policy_check(position('billing.enter_financial_write' in body)<position('for update' in body),
  'policy root before partner/policy locks');
end;$test$;
rollback;
