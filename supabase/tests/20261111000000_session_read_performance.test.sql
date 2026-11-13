\set ON_ERROR_STOP on
-- Disposable local test; all fixtures and assertions roll back.
begin;
set local timezone='UTC';
-- Fixture construction is not a read benchmark. Benchmark restores jit=on.
set local jit=off;
create function pg_temp.srp_assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL %',label;end if;raise notice 'PASS %',label;end;$$;
create function pg_temp.srp_fixture(seconds bigint default 10000,paid bigint default 0,invoiced boolean default false,
 paused boolean default false,diesel boolean default false,price bigint default 3600,
 fixture_tenant uuid default null,fixture_actor uuid default null) returns jsonb language plpgsql as $$
declare t uuid:=fixture_tenant;w uuid;actor uuid:=coalesce(fixture_actor,gen_random_uuid());person uuid;farmer uuid;account uuid;farm uuid;pump uuid;sid uuid;
 invoice uuid;start_cmd uuid:=gen_random_uuid();end_cmd uuid:=gen_random_uuid();charge jsonb;payment jsonb;
 at_time timestamptz:=date_trunc('day',transaction_timestamp())-interval '8 days';pause_seconds bigint:=case when paused then 600 else 0 end;
begin
 if t is null then insert into core.tenants(name) values('C2 fixture') returning id into t;end if;
 if fixture_actor is null then
 insert into auth.users(id,instance_id,aud,role,email,email_confirmed_at,created_at,updated_at)
 values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@c2.test',now(),now(),now());
 end if;
 insert into iam.profiles(id,full_name) values(actor,'C2 operator') on conflict(id) do nothing;
 insert into core.wells(tenant_id,name) values(t,'C2 well') returning id into w;
 insert into core.well_assignments(well_id,profile_id,role,status) values(w,actor,'operator','active');
 insert into core.persons(tenant_id,full_name,normalized_name) values(t,'C2 farmer','C2 farmer') returning id into person;
 insert into ops.farmer_profiles(tenant_id,person_id) values(t,person) returning id into farmer;
 insert into ops.farmer_well_accounts(tenant_id,farmer_profile_id,well_id,public_code)
 values(t,farmer,w,'C2-'||substr(actor::text,1,8)) returning id into account;
 insert into ops.farms(well_id,name,farmer_well_account_id) values(w,'C2 farm',account) returning id into farm;
 insert into core.pumps(well_id,name,power_source,status) values(w,'C2 pump','diesel','active') returning id into pump;
 insert into billing.well_pricing(well_id,price_per_hour_minor,period_start) values(w,price,date '1970-01-01');
 insert into ops.shifts(tenant_id,well_id,operator_profile_id,started_at,status) values(t,w,actor,at_time-interval '1 hour','open');
 perform set_config('request.jwt.claim.sub',actor::text,true);
 -- fixture writes use the owner connection; API actor checks still apply.

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

create function pg_temp.srp_adjust(f jsonb,amount bigint,op bigint default 0,sys bigint default 0,manual bigint default 0,cmd uuid default gen_random_uuid())
returns jsonb language plpgsql as $$declare r jsonb;begin
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 -- fixture writes use the owner connection; API actor checks still apply.

 r:=api.adjust_session_financial_amount((f->>'session')::uuid,cmd,op,sys,manual,amount,'  approved reason  ',(f->>'posting')::timestamptz);
 execute 'reset role';return r;
exception when others then execute 'reset role';raise;end;$$;
create function pg_temp.srp_state(f jsonb) returns jsonb language plpgsql as $$begin
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 return api.get_session_financial_state((f->>'session')::uuid);end;$$;
create function pg_temp.srp_correct(f jsonb,base bigint,seconds bigint) returns uuid language plpgsql as $$declare r jsonb;begin
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 r:=ops.accept_session_correction((f->>'session')::uuid,gen_random_uuid(),base,'time reason',
 (f->>'at')::timestamptz,(f->>'at')::timestamptz+seconds*interval '1 second',(f->>'posting')::timestamptz);
 return(r->>'correction_id')::uuid;end;$$;


-- Seed valid posted evidence without benchmarking unrelated payment-write
-- preflight reads. Drafts are populated before posting; all constraints,
-- journaling triggers and credit locks stay enabled. No RLS is disabled.
create function pg_temp.srp_payment(f jsonb,charge uuid,amount bigint,allocations jsonb,at_time timestamptz)
returns jsonb language plpgsql as $$declare payment uuid;a jsonb;begin
 perform billing.lock_customer_credit_well((f->>'well')::uuid);
 insert into billing.payments(tenant_id,well_id,farmer_well_account_id,received_by_profile_id,
  amount_minor,method,paid_at,purpose,status)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,(f->>'account')::uuid,(f->>'actor')::uuid,
  amount,'cash',at_time,'advance','draft') returning id into payment;
 update billing.payments set purpose='session',session_charge_id=charge,status='posted' where id=payment;
 for a in select * from jsonb_array_elements(allocations) loop
  insert into billing.payment_allocations(tenant_id,payment_id,invoice_id,allocated_minor)
  values((f->>'tenant')::uuid,payment,(a->>'invoice_id')::uuid,(a->>'amount_minor')::bigint);
 end loop;
 return jsonb_build_object('payment_id',payment);
end;$$;

create function pg_temp.srp_dataset() returns jsonb language plpgsql as $$
declare f jsonb;foreign_fixture jsonb;sid uuid;charge jsonb;iv uuid;r jsonb;credit uuid;app uuid;
 sessions uuid[];invoices uuid[]:='{}';actor uuid;well uuid;account uuid;farm uuid;pump uuid;
 t timestamptz;person uuid;farmer uuid;other_account uuid;other_farm uuid;other_sid uuid;self_actor uuid:=gen_random_uuid();correction uuid;
begin
 f:=pg_temp.srp_fixture(); actor:=(f->>'actor')::uuid;well:=(f->>'well')::uuid;
 account:=(f->>'account')::uuid;
 select s.farm_id,s.pump_id into farm,pump from ops.irrigation_sessions s where s.id=(f->>'session')::uuid;
 sessions:=array[(f->>'session')::uuid];
 correction:=pg_temp.srp_correct(f,0,11000);
 r:=billing.reconcile_session_correction(correction,gen_random_uuid(),(f->>'posting')::timestamptz);
 if r->>'status'<>'applied' then raise exception 'fixture reconciliation failed: %',r;end if;

 for n in 1..26 loop
  t:=(f->>'at')::timestamptz+n*interval '4 hours';
  perform set_config('request.jwt.claim.sub',actor::text,true);-- fixture writes use the owner connection; API actor checks still apply.

  sid:=api.start_operational_session(well,pump,farm,account,'solar',t,gen_random_uuid());
  if n<=4 then
   perform api.pause_irrigation_session(sid,'operator_pause',t+interval '1200 seconds',gen_random_uuid());
   perform api.resume_irrigation_session(sid,t+interval '1800 seconds',gen_random_uuid());
  end if;
  charge:=api.complete_irrigation_session(sid,t+(case when n<=4 then 4200 else 3600 end)*interval '1 second',null::bigint,null::text,null::uuid,gen_random_uuid());
  if n<=12 then iv:=api.issue_session_invoice(sid);invoices:=array_append(invoices,iv);end if;
  execute 'reset role';sessions:=array_append(sessions,sid);
  if n=1 then
   r:=pg_temp.srp_payment(f,(charge->>'session_charge_id')::uuid,3600,
    jsonb_build_array(jsonb_build_object('invoice_id',iv,'amount_minor',3600)),t+interval '2 hours');
   r:=api.adjust_session_financial_amount(sid,gen_random_uuid(),0,0,0,2600,'approved fixture decrease',t+interval '3 hours');
   if r->>'status'<>'accepted' then raise exception 'fixture approval failed: %',r;end if;
   select id into strict credit from billing.account_credits where farmer_well_account_id=account;
  elsif n=2 then
   perform billing.lock_customer_credit_well(well);
   r:=billing.apply_account_credit(credit,iv,500,gen_random_uuid(),1,'fixture credit application',t+interval '3 hours');
   if r->>'status'<>'accepted' then raise exception 'fixture credit failed: %',r;end if;
  end if;

 end loop;
 -- Same account and well: multiple payments in a default-charge partition,
 -- including a payment explicitly allocated to OTHER sessions' invoices.
 perform set_config('request.jwt.claim.sub',actor::text,true);-- fixture writes use the owner connection; API actor checks still apply.

 raise notice 'fixture sessions ready';
 for n in 2..17 loop
  r:=pg_temp.srp_payment(f,
   case when n=2 then (f->>'charge')::uuid else
    (select id from billing.session_charges where session_id=sessions[n+1]) end,
   case when n=1 then 3600 else 1000 end,
   case when n=2 then jsonb_build_array(
     jsonb_build_object('invoice_id',invoices[3],'amount_minor',400),
     jsonb_build_object('invoice_id',invoices[4],'amount_minor',600))
    when n<=12 then jsonb_build_array(jsonb_build_object('invoice_id',invoices[n],
     'amount_minor',case when n=1 then 3600 else 1000 end)) else '[]'::jsonb end,
   (f->>'posting')::timestamptz-n*interval '1 minute');
 end loop;
 r:=pg_temp.srp_payment(f,(f->>'charge')::uuid,2000,'[]'::jsonb,(f->>'posting')::timestamptz);
 r:=pg_temp.srp_payment(f,(f->>'charge')::uuid,1000,'[]'::jsonb,(f->>'posting')::timestamptz+interval '1 second');
 raise notice 'fixture payments ready';
 -- Another farmer in the SAME well: self access must not become staff access.
 insert into core.persons(tenant_id,full_name,normalized_name) values((f->>'tenant')::uuid,'other farmer','other farmer') returning id into person;
 insert into ops.farmer_profiles(tenant_id,person_id) values((f->>'tenant')::uuid,person) returning id into farmer;
 insert into ops.farmer_well_accounts(tenant_id,well_id,farmer_profile_id,public_code)
 values((f->>'tenant')::uuid,well,farmer,'OTHER-'||substr(actor::text,1,8)) returning id into other_account;
 insert into ops.farms(well_id,farmer_well_account_id,name) values(well,other_account,'other farm') returning id into other_farm;
 perform set_config('request.jwt.claim.sub',actor::text,true);-- fixture writes use the owner connection; API actor checks still apply.

 t:=(f->>'at')::timestamptz+interval '6 days';
 other_sid:=api.start_operational_session(well,pump,other_farm,other_account,'solar',t,gen_random_uuid());
 perform api.complete_irrigation_session(other_sid,t+interval '1 hour',null::bigint,null::text,null::uuid,gen_random_uuid());execute 'reset role';
 insert into auth.users(id,instance_id,aud,role,email,email_confirmed_at,created_at,updated_at)
 values(self_actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',self_actor||'@srp.test',now(),now(),now());
 insert into iam.profiles(id,full_name) values(self_actor,'self farmer') on conflict(id) do nothing;
 select fp.person_id into person from ops.farmer_well_accounts a join ops.farmer_profiles fp on fp.id=a.farmer_profile_id where a.id=account;
 insert into iam.profile_person_links(tenant_id,profile_id,person_id,linked_by,link_reason)
 values((f->>'tenant')::uuid,self_actor,person,actor,'explicit fixture self scope');
 foreign_fixture:=pg_temp.srp_fixture();
 return f||jsonb_build_object('sessions',to_jsonb(sessions),'invoices',to_jsonb(invoices),
  'self_actor',self_actor,'other_session',other_sid,'other_account',other_account,'foreign',foreign_fixture);
exception when others then execute 'reset role';raise;
end;$$;
create temp table srp_context as select pg_temp.srp_dataset() f;
grant select on srp_context to authenticated;
-- END FIXTURE

-- CONTRACT ASSERTIONS (the benchmark also exercises old/new full JSON equality).
set local jit=on;
set local statement_timeout='15s';
do $$declare f jsonb;items jsonb;d jsonb;u jsonb;denied boolean;started timestamptz;elapsed numeric;begin
 select srp_context.f into f from srp_context;
 perform set_config('request.jwt.claim.sub',f->>'actor',true);set local role authenticated;
 started:=clock_timestamp();items:=api.list_well_sessions((f->>'well')::uuid);
 elapsed:=extract(epoch from clock_timestamp()-started);
 raise notice 'LIST_MS %',elapsed*1000;
 perform pg_temp.srp_assert(elapsed<3,'list contract under 3 seconds with RLS and JIT enabled');
 perform pg_temp.srp_assert(jsonb_array_length(items->'items')=28,'staff sees 28 sessions');
 started:=clock_timestamp();d:=api.get_session_detail((f->>'session')::uuid);
 elapsed:=extract(epoch from clock_timestamp()-started);
 raise notice 'DETAIL_MS %',elapsed*1000;
 perform pg_temp.srp_assert(elapsed<3,'detail contract under 3 seconds with RLS and JIT enabled');
 perform pg_temp.srp_assert(d->'session'->>'total_amount_minor'='11000' and d->'session'->>'paid_amount_minor'='3000'
  and d->'session'->>'operational_revision'='1','correction effective facts and cumulative direct settlement');
 d:=api.get_session_detail((f->'sessions'->>1)::uuid);
 perform pg_temp.srp_assert(d->'session'->>'total_amount_minor'='2600' and d->'session'->>'paid_amount_minor'='2600'
  and d->'session'->>'payment_status'='settled','manual approval remains effective');
 d:=api.get_session_detail((f->'sessions'->>2)::uuid);
 perform pg_temp.srp_assert(d->'session'->>'paid_amount_minor'='500' and d->'payment' is distinct from 'null'::jsonb,'credit-backed latest payment retained');
 u:=api.list_well_sessions((f->>'well')::uuid,null,null,null,true,200);
 perform pg_temp.srp_assert(not exists(select 1 from jsonb_array_elements(u->'items') x where x->>'payment_status'='settled'),'unpaid filter excludes settled sessions');
 perform pg_temp.srp_assert(jsonb_array_length(api.list_well_sessions((f->>'well')::uuid,(f->>'other_account')::uuid)->'items')=1,'farmer filter exact');
 perform pg_temp.srp_assert(jsonb_array_length(api.list_well_sessions((f->>'well')::uuid,null,null,null,false,2)->'items')=2,'limit retained');
 perform set_config('request.jwt.claim.sub',f->>'self_actor',true);
 items:=api.list_well_sessions((f->>'well')::uuid);
 perform pg_temp.srp_assert(jsonb_array_length(items->'items')=27 and not exists(select 1 from jsonb_array_elements(items->'items') x where x->>'id'=f->>'other_session'),'self farmer sees only own sessions');
 denied:=false;begin perform api.get_session_detail((f->>'other_session')::uuid);exception when insufficient_privilege then denied:=true;end;
 perform pg_temp.srp_assert(denied,'self farmer cannot read other farmer detail');
 perform pg_temp.srp_assert(not exists(select 1 from billing.session_read_financial_context(
  array[(f->>'other_session')::uuid],true)),'invoker helper cannot expose another farmer settlement');
 perform set_config('request.jwt.claim.sub',f->'foreign'->>'actor',true);
 denied:=false;begin perform api.list_well_sessions((f->>'well')::uuid);exception when insufficient_privilege then denied:=true;end;
 perform pg_temp.srp_assert(denied,'unassigned actor cannot read well history');
 denied:=false;begin perform api.get_session_detail((f->>'session')::uuid);exception when insufficient_privilege then denied:=true;end;
 perform pg_temp.srp_assert(denied,'unassigned actor cannot read session detail');
 reset role;
 perform pg_temp.srp_assert(not (select prosecdef from pg_proc where oid='billing.session_read_financial_context(uuid[],boolean)'::regprocedure),'financial context is SECURITY INVOKER');
 perform pg_temp.srp_assert(not has_function_privilege('anon','billing.session_read_financial_context(uuid[],boolean)','EXECUTE'),'anonymous cannot execute financial context');
 perform pg_temp.srp_assert(has_function_privilege('authenticated','billing.session_read_financial_context(uuid[],boolean)','EXECUTE'),'authenticated may execute invoker financial context');
 perform pg_temp.srp_assert((select count(*) from billing.payments where well_id=(f->>'well')::uuid)=19,'reads preserve 19 original payments');
 perform pg_temp.srp_assert((select count(*) from ops.session_segments s join ops.irrigation_sessions i on i.id=s.session_id where i.well_id=(f->>'well')::uuid)=36,'representative 36 segments retained');
end;$$;
-- Execute deferred integrity checks before rolling the disposable fixture back.
set constraints all immediate;
rollback;
