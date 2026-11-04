\set ON_ERROR_STOP on
-- Owner local regression; all fixtures/effects roll back. No dblink in this file.
begin;
set local timezone='UTC';
create function pg_temp.period_check(ok boolean,label text) returns void language plpgsql as $$
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
create function pg_temp.c2_correct(f jsonb,base bigint,seconds bigint,shift_start interval default interval '0')
returns uuid language plpgsql as $$
declare r jsonb;
begin
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 r:=ops.accept_session_correction((f->>'session')::uuid,gen_random_uuid(),base,'  original correction reason  ',
  (f->>'at')::timestamptz+shift_start,(f->>'at')::timestamptz+(seconds+(f->>'pause_seconds')::bigint)*interval '1 second',
  (f->>'posting')::timestamptz);
 return (r->>'correction_id')::uuid;
end;$$;
do $test$
declare f jsonb;g jsonb;period uuid;request uuid;partner uuid;person uuid;admin uuid:=gen_random_uuid();
 correction uuid;r jsonb;n bigint;before_audit bigint;before_finance jsonb;body text;fn text;role_name text;error_context text;
begin
 f:=pg_temp.c2_fixture(10000,10000,true);
 update core.well_assignments set role='owner' where well_id=(f->>'well')::uuid and profile_id=(f->>'actor')::uuid;
 select id into strict period from finance.accounting_periods where well_id=(f->>'well')::uuid and period_type='monthly';
 select count(*) into before_audit from audit.audit_logs where entity_id=period;
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 execute 'set local role authenticated';
 perform api.close_period(period);
 execute 'reset role';
 perform pg_temp.period_check((select status='closed' from finance.accounting_periods where id=period),'close through sanctioned API');
 perform pg_temp.period_check((select count(*)=before_audit+1 from audit.audit_logs where entity_id=period),'close audit exactly once');
 begin perform finance.close_period(period,(f->>'actor')::uuid);raise exception 'EXPECTED_ALREADY_CLOSED';
 exception when raise_exception then if SQLERRM='EXPECTED_ALREADY_CLOSED' then raise;end if;
  perform pg_temp.period_check(SQLERRM='الفترة مغلقة مسبقًا','already closed semantics');end;
 -- Existing business flow: owner requests, active partner votes, platform admin decides.
 insert into core.persons(tenant_id,full_name,normalized_name) values((f->>'tenant')::uuid,'period partner','period partner') returning id into person;
 insert into core.well_partners(tenant_id,well_id,person_id,profile_id,phone,period_start,status)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,person,(f->>'actor')::uuid,'777777777',((f->>'at')::timestamptz-interval '1 year')::date,'active') returning id into partner;
 request:=finance.request_period_reopen(period,(f->>'actor')::uuid,'  retained reason  ');
 perform pg_temp.period_check((select status='pending' and reason='  retained reason  ' from finance.period_reopen_requests where id=request),'request reason/status preserved');
 perform pg_temp.period_check(exists(select 1 from ops.notifications where well_id=(f->>'well')::uuid and type='period_reopen_requested'),'request notification preserved');
 insert into auth.users(id,instance_id,aud,role,email,created_at,updated_at)
 values(admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',admin||'@period.test',now(),now());
 insert into iam.profiles(id,full_name,is_platform_admin) values(admin,'period admin',true) on conflict(id) do update set is_platform_admin=true;
 perform finance.approve_period_reopen(request,partner);
 perform pg_temp.period_check((select status='partners_approved' from finance.period_reopen_requests where id=request)
  and exists(select 1 from finance.period_reopen_approvals where request_id=request and partner_id=partner)
  and exists(select 1 from ops.notifications where well_id=(f->>'well')::uuid and type='period_reopen_ready'),'approval threshold, vote and notification preserved');
 begin perform finance.decide_period_reopen(request,(f->>'actor')::uuid,true);raise exception 'EXPECTED_ADMIN_DENIAL';
 exception when raise_exception then if SQLERRM='EXPECTED_ADMIN_DENIAL' then raise;end if;
  perform pg_temp.period_check(position('الإدارة العامة' in SQLERRM)>0,'nonadmin decision still denied');end;
 perform set_config('request.jwt.claim.sub',admin::text,true);
 perform finance.decide_period_reopen(request,admin,true,'approved');
 perform pg_temp.period_check((select status='reopened' from finance.accounting_periods where id=period),'admin decision reopens');
 perform pg_temp.period_check(exists(select 1 from ops.notifications where well_id=(f->>'well')::uuid and type='period_reopen_approved')
  and exists(select 1 from audit.audit_logs where entity_id=period and new_values->>'status'='reopened'),'decision audit/notification preserved');
 -- Normal SQL clients must not mutate even their own authorized well directly.
 foreach role_name in array array['authenticated','anon','service_role'] loop
  perform pg_temp.period_check(not has_table_privilege(role_name,'finance.accounting_periods','UPDATE')
   and not has_any_column_privilege(role_name,'finance.accounting_periods','UPDATE')
   and not has_table_privilege(role_name,'finance.accounting_periods','DELETE')
   and not has_table_privilege(role_name,'finance.accounting_periods','INSERT'),'no table/column DML: '||role_name);
  execute format('set local role %I',role_name);
  begin update finance.accounting_periods set status='closed' where id=period;raise exception 'EXPECTED_UPDATE_DENIAL';
  exception when insufficient_privilege then null;end;
  begin delete from finance.accounting_periods where id=period;raise exception 'EXPECTED_DELETE_DENIAL';
  exception when insufficient_privilege then null;end;
  execute 'reset role';
 end loop;
 -- RESET ROLE does not restore the JWT identity used for the admin decision.
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 execute 'set local role authenticated';
 perform pg_temp.period_check(auth.uid()=(f->>'actor')::uuid
  and iam.has_well_role((f->>'well')::uuid,array['owner']),'owner identity restored before SELECT');
 select count(*) into n from finance.accounting_periods where id=period;
 execute 'reset role';
 perform pg_temp.period_check(n=1,'owner SELECT retained');
 g:=pg_temp.c2_fixture();
 perform set_config('request.jwt.claim.sub',g->>'actor',true);
 perform pg_temp.period_check((g->>'well')::uuid<>(f->>'well')::uuid
  and exists(select 1 from finance.accounting_periods where id=period and well_id=(f->>'well')::uuid and status='reopened'),
  'cross-well fixture targets an existing reopened period in another well');
 execute 'set local role authenticated';
 perform pg_temp.period_check(auth.uid()=(g->>'actor')::uuid
  and not iam.has_well_permission((f->>'well')::uuid,'period.close'),'cross-well caller has no target close permission');
 select count(*) into n from finance.accounting_periods where id=period;
 perform pg_temp.period_check(n=0,'cross-well period hidden by read policy');
 -- SECURITY INVOKER cannot discover the hidden period. The historical API
 -- raises P0001 at its not-found branch, before the permission-message branch.
 begin perform api.close_period(period);raise exception 'EXPECTED_CROSS_WELL_DENIAL';
 exception when sqlstate 'P0001' then if SQLERRM='EXPECTED_CROSS_WELL_DENIAL' then raise;end if;
  get stacked diagnostics error_context=PG_EXCEPTION_CONTEXT;
  perform pg_temp.period_check(SQLSTATE='P0001' and position('api.close_period' in error_context)>0
   and position('finance.close_period' in error_context)=0,'cross-well close denied');end;
 execute 'reset role';
 perform pg_temp.period_check((select status='reopened' from finance.accounting_periods where id=period),
  'cross-well close leaves target period unchanged');
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 -- Same well manager without period.close is still denied by unchanged API policy.
 update core.well_assignments set role='manager' where well_id=(f->>'well')::uuid and profile_id=(f->>'actor')::uuid;
 execute 'set local role authenticated';
 begin update finance.accounting_periods set status='closed' where id=period;raise exception 'EXPECTED_MANAGER_DML_DENIAL';
 exception when insufficient_privilege then null;end;
 execute 'reset role';
 if not iam.has_well_permission((f->>'well')::uuid,'period.close') then
  execute 'set local role authenticated';
  begin perform api.close_period(period);raise exception 'EXPECTED_MANAGER_CLOSE_DENIAL';
  exception when raise_exception then if SQLERRM='EXPECTED_MANAGER_CLOSE_DENIAL' then raise;end if;
   perform pg_temp.period_check(position('صلاحية' in SQLERRM)>0,'manager cannot bypass existing period.close policy');end;
  execute 'reset role';
 end if;
 update core.well_assignments set role='owner' where well_id=(f->>'well')::uuid and profile_id=(f->>'actor')::uuid;
 perform pg_temp.period_check(exists(select 1 from pg_trigger where tgrelid='finance.accounting_periods'::regclass
  and tgname='track_accounting_periods' and tgenabled<>'D'),'audit trigger enabled');
 perform pg_temp.period_check(exists(select 1 from pg_constraint where conrelid='audit.audit_logs'::regclass
  and confrelid='core.wells'::regclass and contype='f'),'audit well FK retained');
 perform pg_temp.period_check(not exists(select 1 from pg_policy where polrelid='finance.accounting_periods'::regclass
  and polcmd in ('w','a','d','*')),'no client mutation RLS policy');
 foreach fn in array array['close_period(uuid,uuid)','request_period_reopen(uuid,uuid,text)',
  'approve_period_reopen(uuid,uuid)','decide_period_reopen(uuid,uuid,boolean,text)'] loop
  select pg_get_functiondef(('finance.'||fn)::regprocedure) into body;
  perform pg_temp.period_check(position('billing.lock_customer_credit_well' in body)>0
   and position('billing.lock_customer_credit_well' in body)<position('finance.lock_period_write' in body),'root-owning period entry used: '||fn);
  perform pg_temp.period_check((select prosecdef from pg_proc where oid=('finance.'||fn)::regprocedure),'definer retained: '||fn);
 end loop;
 select pg_get_functiondef('finance.lock_period_write(uuid)'::regprocedure) into body;
 perform pg_temp.period_check(position('billing.require_customer_credit_well_lock' in body)>0
  and position('billing.lock_customer_credit_well' in body)=0
  and position('billing.require_customer_credit_well_lock' in body)<position('for update of ap' in body)
  and position('order by ap.id for update' in body)>0
  and position('accounting_period_scope_changed' in body)>0,'helper requires preowned root, deterministic period order and postwait scope revalidation');
 perform pg_temp.period_check(not has_function_privilege('authenticated','finance.lock_period_write(uuid)','EXECUTE')
  and not has_function_privilege('anon','finance.lock_period_write(uuid)','EXECUTE'),'private lock helper not client executable');
 perform pg_temp.period_check((select exists(select 1 from unnest(proconfig) cfg where replace(cfg,' ','')='search_path=pg_catalog,pg_temp')
  from pg_proc where oid='finance.lock_period_write(uuid)'::regprocedure),'hardened private helper search path');
 select pg_get_functiondef('finance.close_period(uuid,uuid)'::regprocedure) into body;
 perform pg_temp.period_check(position('v_per.status' in body)>position('finance.lock_period_write' in body),'status checked after lock');
 -- C2 open context still applies; a later accepted operational revision remains
 -- accepted when the financial attempt sees the now-closed posting context.
 correction:=pg_temp.c2_correct(f,0,8000);
 r:=billing.reconcile_session_correction(correction,gen_random_uuid(),(f->>'posting')::timestamptz);
 perform pg_temp.period_check(r->>'status'='applied','C2 valid explicit reopened context applies');
 correction:=pg_temp.c2_correct(f,1,7000);
 perform finance.close_period(period,(f->>'actor')::uuid);
 select jsonb_build_object('charge',(select count(*) from billing.session_charge_corrections),
  'invoice',(select count(*) from billing.invoice_corrections),'events',(select count(*) from billing.customer_credit_events),
  'journal',(select count(*) from finance.journal_entries),'fuel',(select count(*) from inventory.fuel_transactions)) into before_finance;
 r:=billing.reconcile_session_correction(correction,gen_random_uuid(),(f->>'posting')::timestamptz);
 perform pg_temp.period_check(r->>'status'='financial_review_required' and r->>'review_code'='accounting_period_not_open','C2 closed period review unchanged');
 perform pg_temp.period_check(before_finance=jsonb_build_object('charge',(select count(*) from billing.session_charge_corrections),
  'invoice',(select count(*) from billing.invoice_corrections),'events',(select count(*) from billing.customer_credit_events),
  'journal',(select count(*) from finance.journal_entries),'fuel',(select count(*) from inventory.fuel_transactions))
  and exists(select 1 from ops.session_corrections where id=correction),'closed attempt leaves no financial children, operational acceptance retained');
end;$test$;
rollback;
