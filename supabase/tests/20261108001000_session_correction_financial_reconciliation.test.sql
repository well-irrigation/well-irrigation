\set ON_ERROR_STOP on
-- OWNER ONLY, disposable local DB; fixtures and assertions roll back together.
begin;
set local timezone='UTC';
create function pg_temp.c2_check(ok boolean,label text) returns void language plpgsql as $$
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
create function pg_temp.c2_apply(f jsonb,correction uuid,cmd uuid,posting timestamptz default null)
returns jsonb language plpgsql as $$
begin
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 return billing.reconcile_session_correction(correction,cmd,coalesce(posting,(f->>'posting')::timestamptz));
end;$$;
create function pg_temp.c2_evidence() returns jsonb language plpgsql as $$
declare r jsonb:='{}';v jsonb;x record;
begin
 for x in select * from (values('billing','session_charges'),('billing','invoice_lines'),('billing','payments'),
 ('billing','payment_allocations'),('billing','account_credits'),('billing','account_credit_applications'),
 ('finance','profit_distribution_cycles'),('finance','profit_distribution_lines'),('inventory','fuel_transactions'))z(ns,tbl) loop
  execute format('select jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text) from %I.%I t',x.ns,x.tbl) into v;
  r:=r||jsonb_build_object(x.ns||'.'||x.tbl,v);
 end loop;
 return r||jsonb_build_object(
 'sessions',(select jsonb_agg(to_jsonb(s) order by id) from ops.irrigation_sessions s),
 'segments',(select jsonb_agg(to_jsonb(s) order by id) from ops.session_segments s),
 'invoices',(select jsonb_agg(to_jsonb(i)-array['paid_minor','outstanding_minor','status','correction_total_delta_minor'] order by id) from billing.invoices i),
 'original_journals',(select jsonb_agg(to_jsonb(j) order by id) from finance.journal_entries j where source_type not in ('session_correction','customer_credit')),
 'original_receipts',(select jsonb_agg(to_jsonb(c) order by id) from sync.processed_commands c
  where command_type not in ('correct_irrigation_session','reconcile_session_correction')));
end;$$;
create function pg_temp.c2_financial_snapshot() returns jsonb language plpgsql as $$
declare r jsonb:='{}';v jsonb;x record;
begin
 for x in select n.nspname,c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
 where c.relkind in ('r','p') and n.nspname in ('billing','finance','inventory') order by 1,2 loop
  execute format('select jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text) from %I.%I t',x.nspname,x.relname) into v;
  r:=r||jsonb_build_object(x.nspname||'.'||x.relname,v);
 end loop;return r;
end;$$;
create function pg_temp.c2_fail_invoice_history() returns trigger language plpgsql as $$
begin
 if new.session_id::text=current_setting('c2.fail_session',true) then
  raise exception 'c2_injected_after_releases' using errcode='P0C02';end if;return new;
end;$$;
create trigger c2_test_fail_invoice_history before insert on billing.invoice_corrections
 for each row execute function pg_temp.c2_fail_invoice_history();

do $tests$
declare f jsonb;g jsonb;r jsonb;again jsonb;raw jsonb;snapshot jsonb;payment_snapshot jsonb;fuel jsonb;
 c uuid;d uuid;cmd uuid;credit uuid;application uuid;invoice uuid;cycle uuid;entry uuid;amount bigint;denied boolean;role_name text;object_name text;
begin
 -- Uninvoiced direct payment: correction cannot be hidden behind invoice logic.
 f:=pg_temp.c2_fixture(10000,10000);c:=pg_temp.c2_correct(f,0,8000);raw:=pg_temp.c2_evidence();
 cmd:=gen_random_uuid();r:=pg_temp.c2_apply(f,c,cmd);
 perform pg_temp.c2_check(r->>'status'='applied' and r->>'financial_applied_revision'='1','01 shorter duration applied');
 perform pg_temp.c2_check((select amount_minor=8000 and duration_seconds=8000 and financial_applied_revision=1
 from billing.effective_session_charges where id=(f->>'charge')::uuid),'02 corrected charge exactly once');
 perform pg_temp.c2_check((select settled_minor=8000 and outstanding_minor=0 from billing.session_economic_settlements
 where session_charge_id=(f->>'charge')::uuid) and (select sum(available_minor)=2000 from billing.account_credit_balances
 where payment_id=(f->>'payment')::uuid),'03 original payment 10000 settles 8000 plus traceable credit 2000');
 -- Credits are new correcting effects; compare original payment/charge evidence separately.
 perform pg_temp.c2_check((select amount_minor=10000 from billing.session_charges where id=(f->>'charge')::uuid)
 and (select amount_minor=10000 from billing.payments where id=(f->>'payment')::uuid), '04 original charge/payment unchanged, no fake payment');
 snapshot:=pg_temp.c2_financial_snapshot();again:=pg_temp.c2_apply(f,c,cmd);
 perform pg_temp.c2_check(again=r and snapshot=pg_temp.c2_financial_snapshot(),'05 exact financial replay has zero effects');
 denied:=false;begin perform pg_temp.c2_apply(f,c,cmd,(f->>'posting')::timestamptz+interval '1 minute');
 exception when invalid_parameter_value then denied:=true;end;
 perform pg_temp.c2_check(denied,'06 changed context under same command rejected');
 perform set_config('TimeZone','Asia/Aden',true);denied:=false;
 begin perform pg_temp.c2_apply(f,c,cmd);exception when invalid_parameter_value then denied:=true;end;
 perform set_config('TimeZone','UTC',true);
 perform pg_temp.c2_check(denied,'06b accounting timezone is part of immutable reconciliation context');
 invoice:=billing.issue_session_invoice((f->>'session')::uuid,(f->>'actor')::uuid);
 perform pg_temp.c2_check((select total_minor=8000 and session_financial_revision=1 from billing.invoices where id=invoice)
 and (select sum(amount_minor)=8000 from billing.invoice_lines where invoice_id=invoice),'07 later invoice uses applied financial revision');
 f:=f||jsonb_build_object('invoice',invoice);
 d:=pg_temp.c2_correct(f,1,10000);r:=pg_temp.c2_apply(f,d,gen_random_uuid());
 perform pg_temp.c2_check(r->>'status'='applied' and (select total_minor=10000 from billing.effective_invoice_totals where id=invoice)
 and (select total_minor=8000 from billing.invoices where id=invoice),'08 late-issued original invoice receives only subsequent delta');
 -- No automatic clawback/spend of previously created credit.
 select id into strict credit from billing.account_credits where payment_id=(f->>'payment')::uuid;
 perform billing.apply_account_credit(credit,invoice,2000,gen_random_uuid(),1,'explicit application',(f->>'posting')::timestamptz);
 select id into strict application from billing.account_credit_applications where credit_id=credit;
 c:=pg_temp.c2_correct(f,2,1000);r:=pg_temp.c2_apply(f,c,gen_random_uuid());
 perform pg_temp.c2_check(r->>'status'='applied' and (select amount_minor=2000 from billing.account_credit_applications where id=application)
 and (select effective_amount_minor=1000 from billing.effective_account_credit_applications where id=application),
 '09 C0.1 releases only excess application; original application immutable');
 perform pg_temp.c2_check((select explicit_allocated_minor+effective_direct_minor+credit_backed_minor+remaining_minor=amount_minor
 from billing.payment_economic_applications where payment_id=(f->>'payment')::uuid),'10 used credit cannot duplicate payment value');
 -- A genuinely separate debt consumes the credit. Raising the original debt
 -- must leave an outstanding balance, not claw that payment value back twice.
 f:=pg_temp.c2_fixture(10000,10000);c:=pg_temp.c2_correct(f,0,8000);r:=pg_temp.c2_apply(f,c,gen_random_uuid());
 select id into strict credit from billing.account_credits where payment_id=(f->>'payment')::uuid;
 insert into billing.invoices(tenant_id,well_id,public_code,farmer_well_account_id,invoice_date,status,
  subtotal_minor,total_minor,paid_minor,outstanding_minor)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,core.generate_public_code('INV'),(f->>'account')::uuid,
  (f->>'posting')::timestamptz,'draft',2000,2000,0,2000) returning id into invoice;
 update billing.invoices set status='issued' where id=invoice;
 perform billing.apply_account_credit(credit,invoice,2000,gen_random_uuid(),1,'other genuine debt',(f->>'posting')::timestamptz);
 select id into strict application from billing.account_credit_applications where credit_id=credit;
 d:=pg_temp.c2_correct(f,1,10000);r:=pg_temp.c2_apply(f,d,gen_random_uuid());
 perform pg_temp.c2_check(r->>'status'='applied' and (select settled_minor=8000 and outstanding_minor=2000
 from billing.session_economic_settlements where session_charge_id=(f->>'charge')::uuid)
 and (select effective_amount_minor=2000 from billing.effective_account_credit_applications where id=application)
 and (select explicit_allocated_minor+effective_direct_minor+credit_backed_minor+remaining_minor=10000
 from billing.payment_economic_applications where payment_id=(f->>'payment')::uuid),
 '10b credit consumed elsewhere remains there; increased original debt does not duplicate money');

 f:=pg_temp.c2_fixture(8000,8000,true);c:=pg_temp.c2_correct(f,0,10000);raw:=pg_temp.c2_evidence();
 r:=pg_temp.c2_apply(f,c,gen_random_uuid());
 perform pg_temp.c2_check(r->>'status'='applied' and (select total_minor=10000 and paid_minor=8000 and outstanding_minor=2000
 from billing.invoice_effective_balances where invoice_id=(f->>'invoice')::uuid),'11 increased invoice debt has 2000 outstanding, no payment invented');
 perform pg_temp.c2_check(raw=pg_temp.c2_evidence(),'12 original invoice, lines, allocations, receipts, journals and execution unchanged');
 select journal_entry_id into strict entry from billing.invoices where id=(f->>'invoice')::uuid;
 denied:=false;begin update finance.journal_entries set entry_date=entry_date+interval '1 day' where id=entry;
 exception when others then denied:=true;end;
 perform pg_temp.c2_check(denied,'12b original posted journal remains immutable');
 -- A later explicit human collection is allowed by the unchanged payment
 -- contract; it is not a payment fabricated by reconciliation.
 execute 'set local role authenticated';
 perform api.record_payment(p_well_id=>(f->>'well')::uuid,p_farmer_well_account_id=>(f->>'account')::uuid,
  p_amount_minor=>2000,p_method=>'cash',p_session_charge_id=>(f->>'charge')::uuid,
  p_allocations=>jsonb_build_array(jsonb_build_object('invoice_id',(f->>'invoice')::uuid,'amount_minor',2000)),
  p_paid_at=>(f->>'posting')::timestamptz,p_command_id=>gen_random_uuid());
 execute 'reset role';
 perform pg_temp.c2_check((select total_minor=10000 and paid_minor=10000 and outstanding_minor=0
 from billing.invoice_effective_balances where invoice_id=(f->>'invoice')::uuid)
 and (select total_minor=8000 from billing.invoices where id=(f->>'invoice')::uuid),
 '12c later explicit payment consumes corrected debt without rewriting original invoice total');

 f:=pg_temp.c2_fixture(10000,10000,true);c:=pg_temp.c2_correct(f,0,8000);
 payment_snapshot:=(select jsonb_agg(to_jsonb(p) order by id) from billing.payments p);
 r:=pg_temp.c2_apply(f,c,gen_random_uuid());
 perform pg_temp.c2_check(r->>'status'='applied' and (select total_minor=8000 and outstanding_minor=0 from billing.invoice_effective_balances
 where invoice_id=(f->>'invoice')::uuid),'13 existing invoice decreases through append-only history');
 perform pg_temp.c2_check((select allocated_minor=10000 from billing.payment_allocations where invoice_id=(f->>'invoice')::uuid)
 and (select effective_allocated_minor=8000 from billing.effective_payment_allocations where invoice_id=(f->>'invoice')::uuid),
 '14 C0 allocation release preserves original row');
 perform pg_temp.c2_check(payment_snapshot=(select jsonb_agg(to_jsonb(p) order by id) from billing.payments p)
 and (select count(*)=1 from billing.session_charge_corrections where correction_id=c)
 and (select count(*)=1 from billing.invoice_corrections where correction_id=c),'15 one charge/invoice correction and no replacement payment');
 g:=f;
 denied:=false;begin update billing.session_charge_corrections set new_amount_minor=1 where correction_id=c;
 exception when check_violation then denied:=true;end;perform pg_temp.c2_check(denied,'16 charge history append-only');
 denied:=false;begin delete from billing.invoice_corrections where correction_id=c;
 exception when check_violation then denied:=true;end;perform pg_temp.c2_check(denied,'17 invoice history append-only');

 f:=pg_temp.c2_fixture(10000,0,false,true);c:=pg_temp.c2_correct(f,0,8000);r:=pg_temp.c2_apply(f,c,gen_random_uuid());
 perform pg_temp.c2_check(r->>'status'='applied' and (select duration_seconds=8000 and amount_minor=8000
 from billing.effective_session_charges where id=(f->>'charge')::uuid),'18 pause remains excluded; not end minus start');
 d:=pg_temp.c2_correct(f,1,9000);c:=pg_temp.c2_correct(f,2,9500);
 snapshot:=pg_temp.c2_financial_snapshot();r:=pg_temp.c2_apply(f,c,gen_random_uuid());
 perform pg_temp.c2_check(r->>'status'='pending' and snapshot=pg_temp.c2_financial_snapshot(), '19 revision 3 cannot overtake pending 2');
 r:=pg_temp.c2_apply(f,d,gen_random_uuid());again:=pg_temp.c2_apply(f,c,gen_random_uuid());
 perform pg_temp.c2_check(r->>'status'='applied' and again->>'status'='applied'
 and (select amount_minor=9500 and financial_applied_revision=3 from billing.effective_session_charges where id=(f->>'charge')::uuid),
 '20 financial derivation uses each target revision rather than latest operational head');

 f:=pg_temp.c2_fixture();c:=pg_temp.c2_correct(f,0,8000,interval '1 second');
 update billing.well_pricing set price_per_hour_minor=99999 where well_id=(f->>'well')::uuid;
 snapshot:=pg_temp.c2_financial_snapshot();r:=pg_temp.c2_apply(f,c,gen_random_uuid());
 perform pg_temp.c2_check(r->>'status'='financial_review_required' and r->>'review_code'='historical_price_unproven'
 and snapshot=pg_temp.c2_financial_snapshot(),'21 changed pricing event has no current-price fallback or financial children');
 perform pg_temp.c2_check((select operational_revision=1 from ops.irrigation_sessions where id=(f->>'session')::uuid)
 and (select status='pending' or status='financial_review_required' from ops.session_correction_reconciliations where correction_id=c),
 '22 operational correction survives financial review');
 f:=pg_temp.c2_fixture();
 update billing.well_pricing set price_per_hour_minor=99999 where well_id=(f->>'well')::uuid;
 c:=pg_temp.c2_correct(f,0,8000);r:=pg_temp.c2_apply(f,c,gen_random_uuid());
 perform pg_temp.c2_check(r->>'status'='applied' and (select amount_minor=8000 from billing.effective_session_charges
 where id=(f->>'charge')::uuid),'22b unchanged pricing event uses pinned snapshot, not current tariff');
 f:=pg_temp.c2_fixture();c:=pg_temp.c2_correct(f,0,8000);
 update ops.session_segments set applied_hourly_rate_minor=null,applied_operation_rate_minor=null where session_id=(f->>'session')::uuid;
 snapshot:=pg_temp.c2_financial_snapshot();r:=pg_temp.c2_apply(f,c,gen_random_uuid());
 perform pg_temp.c2_check(r->>'status'='financial_review_required' and r->>'review_code'='historical_price_unproven'
 and snapshot=pg_temp.c2_financial_snapshot(),'22c missing snapshot cannot fall back to well price');
 f:=pg_temp.c2_fixture();c:=pg_temp.c2_correct(f,0,8000);snapshot:=pg_temp.c2_financial_snapshot();
 r:=billing.reconcile_session_correction(c,gen_random_uuid(),null);
 perform pg_temp.c2_check(r->>'status'='financial_review_required' and r->>'review_code'='explicit_posting_context_required'
 and snapshot=pg_temp.c2_financial_snapshot(),'22d requested_at/current clock cannot supply missing posting context');

 f:=pg_temp.c2_fixture(10000,10000,true);c:=pg_temp.c2_correct(f,0,8000);
 update finance.accounting_periods set status='closed' where well_id=(f->>'well')::uuid;
 snapshot:=pg_temp.c2_financial_snapshot();cmd:=gen_random_uuid();r:=pg_temp.c2_apply(f,c,cmd);
 perform pg_temp.c2_check(r->>'status'='financial_review_required' and r->>'review_code'='accounting_period_not_open'
 and snapshot=pg_temp.c2_financial_snapshot(),'23 closed context leaves zero financial children');
 perform finance.ensure_periods((f->>'well')::uuid,((f->>'posting')::timestamptz+interval '2 years')::date);
 r:=pg_temp.c2_apply(f,c,gen_random_uuid(),(f->>'posting')::timestamptz+interval '2 years');
 perform pg_temp.c2_check(r->>'status'='applied' and exists(select 1 from finance.journal_entries
 where source_type='session_correction' and source_id=c and status='posted'),'24 explicit open context posts new correcting journal');

 f:=pg_temp.c2_fixture(10000,10000,true);c:=pg_temp.c2_correct(f,0,8000);
 snapshot:=pg_temp.c2_financial_snapshot();perform set_config('c2.fail_session',f->>'session',true);
 r:=pg_temp.c2_apply(f,c,gen_random_uuid());perform set_config('c2.fail_session','',true);
 perform pg_temp.c2_check(r->>'status'='financial_review_required' and snapshot=pg_temp.c2_financial_snapshot(),
 '25 failure after allocation release rolls back every financial child and debt publication');

 f:=pg_temp.c2_fixture(10000,0,false,false,true);c:=pg_temp.c2_correct(f,0,8000);
 fuel:=(select jsonb_agg(to_jsonb(x) order by id) from inventory.fuel_transactions x);
 r:=pg_temp.c2_apply(f,c,gen_random_uuid());
 perform pg_temp.c2_check(r->>'status'='applied' and fuel=(select jsonb_agg(to_jsonb(x) order by id) from inventory.fuel_transactions x),
 '26 nonempty fuel history unchanged by time correction');
 f:=pg_temp.c2_fixture(10000,10000,true);c:=pg_temp.c2_correct(f,0,8000);
 insert into finance.profit_distribution_cycles(tenant_id,well_id,period_start,period_end,status)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,(f->>'at')::timestamptz-interval '1 day',
 (f->>'posting')::timestamptz,'approved') returning id into cycle;
 update billing.invoices set deducted_in_cycle_id=cycle where id=(f->>'invoice')::uuid;
 snapshot:=pg_temp.c2_financial_snapshot();r:=pg_temp.c2_apply(f,c,gen_random_uuid());
 perform pg_temp.c2_check(r->>'status'='financial_review_required' and r->>'review_code'='approved_distribution_reconciliation_required'
 and snapshot=pg_temp.c2_financial_snapshot(),'26b approved distribution protection leaves all child effects absent');
 perform pg_temp.c2_check(to_regclass('finance.session_distribution_corrections') is null,
 '26c C3 carry-forward not implemented');
 foreach role_name in array array['anon','authenticated','service_role'] loop
  perform pg_temp.c2_check(not has_function_privilege(role_name,'billing.reconcile_session_correction(uuid,uuid,timestamptz)','EXECUTE'),
   '27 private reconciliation denied to '||role_name);
  foreach object_name in array array['billing.session_charge_corrections','billing.invoice_corrections'] loop
   perform pg_temp.c2_check(not has_table_privilege(role_name,object_name,'INSERT,UPDATE,DELETE'),'28 no direct DML '||object_name);
  end loop;
 end loop;
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 execute 'set local role authenticated';denied:=false;
 begin perform billing.reconcile_session_correction(c,gen_random_uuid(),(f->>'posting')::timestamptz);
 exception when insufficient_privilege then denied:=true;end;
 execute 'reset role';perform pg_temp.c2_check(denied,'28b authenticated cannot invoke private financial acceptance');
 execute 'set local role authenticated';denied:=false;
 begin insert into billing.session_charge_corrections default values;
 exception when insufficient_privilege then denied:=true;end;
 execute 'reset role';perform pg_temp.c2_check(denied,'28c direct financial history INSERT denied');
 execute 'set local role authenticated';
 select count(*) into amount from billing.effective_session_charges where id=(f->>'charge')::uuid;
 select exists(select 1 from billing.effective_session_charges where id=(g->>'charge')::uuid) into denied;
 execute 'reset role';
 perform pg_temp.c2_check(amount=1 and not denied,'28d INVOKER financial projections retain own-well visibility and cross-well RLS');
 update core.well_assignments set role='viewer' where well_id=(f->>'well')::uuid and profile_id=(f->>'actor')::uuid;
 denied:=false;begin perform pg_temp.c2_apply(f,c,gen_random_uuid());exception when insufficient_privilege then denied:=true;end;
 perform pg_temp.c2_check(denied,'28e private reconciliation still enforces session.correct');
 update core.well_assignments set role='operator' where well_id=(f->>'well')::uuid and profile_id=(f->>'actor')::uuid;
 perform pg_temp.c2_check(
 to_regprocedure('api.correct_irrigation_session(uuid,uuid,bigint,text,timestamptz,timestamptz,timestamptz)') is not null
 and not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='api' and (p.proname='reconcile_session_correction'
  or p.prosrc ~ 'billing[[:space:]]*\.[[:space:]]*reconcile_session_correction[[:space:]]*\(')),
 '29 operational correction endpoint allowed; public financial reconciliation remains closed');
 perform pg_temp.c2_check(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='billing' and p.proname in ('reconcile_session_correction','derive_session_correction_charge',
  'post_session_correction_delta','validate_session_financial_correction') and p.prosrc~
  '(execute_booking_transition|execute_booking_transition_automation|execute_pending_booking_start|record_booking_transition_decision)'),
 '30 no retired transition calls from C2');
end;$tests$;
-- Exercise deferred C0/C1/C2 integrity too; a final ROLLBACK alone would not.
set constraints all immediate;
rollback;
