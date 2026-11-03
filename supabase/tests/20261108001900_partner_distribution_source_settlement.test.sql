\set ON_ERROR_STOP on
-- Permanent owner-local tests, authored only; never executed by agent.
begin;
set local timezone='UTC';
create function pg_temp.ps_check(ok boolean,label text) returns void language plpgsql as $$
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
declare t uuid;w uuid;o uuid:=gen_random_uuid();m uuid:=gen_random_uuid();op uuid:=gen_random_uuid();acc uuid:=gen_random_uuid();
 person uuid;partner uuid;expense uuid;category text;cycle uuid;cycle2 uuid;sid uuid;sel uuid;r jsonb;z jsonb;before_j bigint;before_p bigint;
 start_at timestamptz:=date_trunc('day',now())-interval '1 day';end_at timestamptz:=date_trunc('day',now())+interval '1 day';
 f jsonb;policy uuid;invoice uuid;inv_before jsonb;prior_used bigint;old_count bigint;body text;role_id uuid;older_invoice uuid;guarded_selection uuid;before_consumptions bigint;repayment_well uuid;repayment_partner uuid;repayment_source uuid;repayment_command uuid;receipt jsonb;legacy_source uuid;legacy_cycle uuid;legacy_review uuid;legacy_invoice_before jsonb;legacy_cycle_before jsonb;legacy_partner uuid;
begin
 insert into core.tenants(name) values('partner source settlement') returning id into t;
 insert into core.wells(tenant_id,name) values(t,'partner source well') returning id into w;
 insert into auth.users(id,instance_id,aud,role,email,created_at,updated_at)
 select x,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',x||'@source.test',now(),now() from unnest(array[o,m,op,acc]) x;
 insert into iam.profiles(id,full_name) select x,'source actor' from unnest(array[o,m,op,acc]) x on conflict(id) do nothing;
 insert into core.well_assignments(well_id,profile_id,role,status) values(w,o,'owner','active'),(w,m,'manager','active'),(w,op,'operator','active'),(w,acc,'accountant','active');
 insert into core.persons(tenant_id,full_name,normalized_name) values(t,'source partner','source partner') returning id into person;
 insert into core.well_partners(tenant_id,well_id,person_id,phone,period_start) values(t,w,person,'777777777',date '1970-01-01') returning id into partner;
 insert into core.ownership_share_versions(tenant_id,well_id,partner_id,ownership_percentage,profit_percentage,effective_period)
 values(t,w,partner,100,100,daterange(date '1970-01-01',null,'[)'));
 perform set_config('request.jwt.claim.sub',o::text,true);
 perform api.update_distribution_settings(w,false);
 select code into category from finance.expense_categories where tenant_id=t order by id limit 1;
 expense:=finance.record_expense(w,category,100000,'partner paid expense',o,null,true,'partner_paid',null,partner,'اختبار بلا سند');
 cycle:=finance.calculate_profit_distribution(w,start_at,end_at,o,0);
 select s.id into strict sid from finance.distribution_sources s where s.expense_id=expense;
 perform pg_temp.ps_check((select mode='automatic' and amount_minor=100000 from finance.current_distribution_source_selections where cycle_id=cycle and source_id=sid),'automatic source inclusion defaults to entire eligible payable');
 select count(*) into before_j from finance.journal_entries;select count(*) into before_p from billing.payments;
 execute 'set local role authenticated';
 r:=api.add_partner_distribution_adjustment(cycle,sid,'additional_entitlement',30000,'use a partial amount');sel:=(r->>'selection_id')::uuid;
 execute 'reset role';
 perform pg_temp.ps_check((select mode='manual_partial' and amount_minor=30000 from finance.current_distribution_source_selections where cycle_id=cycle and source_id=sid)
  and(select partner_receivables_minor=30000 and net_payable_minor=30000 from finance.profit_distribution_lines where distribution_cycle_id=cycle),'one manual amount replaces automatic amount, never adds to it');
 foreach role_id in array array[m,op,acc] loop
  perform set_config('request.jwt.claim.sub',role_id::text,true);
  begin perform api.select_partner_distribution_source(cycle,sid,20000,'not owner');raise exception 'EXPECTED_OWNER_DENIED';exception when insufficient_privilege then null;end;
 end loop;
 perform set_config('request.jwt.claim.sub',o::text,true);
 begin perform api.select_partner_distribution_source(cycle,sid,0,'zero');raise exception 'EXPECTED_ZERO_DENIED';exception when check_violation then null;end;
 begin perform api.select_partner_distribution_source(cycle,sid,100001,'too much');raise exception 'EXPECTED_CAPACITY_DENIED';exception when check_violation then null;end;
 r:=api.update_partner_distribution_adjustment(sel,40000,'edit with history');sel:=(r->>'selection_id')::uuid;
 r:=api.cancel_partner_distribution_adjustment(sel,'back to automatic');
 begin perform api.update_partner_distribution_adjustment(sel,20000,'old cancelled edit');raise exception 'EXPECTED_OLD_ADJUSTMENT_DENIED';exception when check_violation then
  perform pg_temp.ps_check(SQLERRM='distribution_adjustment_changed','cancelled historical version cannot silently become current again');end;
 perform pg_temp.ps_check((select mode='automatic' and amount_minor=100000 from finance.current_distribution_source_selections where cycle_id=cycle and source_id=sid),'cancel retains history and returns to automatic');
 r:=api.select_partner_distribution_source(cycle,sid,30000,'partial after revert');sel:=(r->>'selection_id')::uuid;
 z:=api.recalculate_profit_distribution(cycle);
 perform pg_temp.ps_check(z->>'status'='confirmation_required' and(z->>'manual_adjustments_present')::boolean,'recalculation warns about explicit manual selections');
 r:=api.recalculate_profit_distribution(cycle,true,z->>'state_token',0,true);cycle2:=(r->>'cycle_id')::uuid;
 perform pg_temp.ps_check((select mode='automatic' and amount_minor=100000 from finance.current_distribution_source_selections where cycle_id=cycle2 and source_id=sid)
  and exists(select 1 from finance.distribution_source_selections where id=sel),'recalculation keeps historical selection and never carries manual mode');
 r:=api.select_partner_distribution_source(cycle2,sid,30000,'consume thirty thousand');
 perform pg_temp.ps_check(before_j=(select count(*) from finance.journal_entries) and before_p=(select count(*) from billing.payments)
  and not exists(select 1 from finance.distribution_source_consumptions where source_id=sid),'all draft editing is nonposting/nonconsuming');
 perform finance.approve_profit_distribution(cycle2,o);
 perform pg_temp.ps_check((select count(*)=1 and sum(amount_minor)=30000 from finance.distribution_source_consumptions where source_id=sid)
  and(finance.distribution_source_availability(sid)->>'remaining_amount_minor')::bigint=70000,'approval consumes exact partial amount once');
 begin perform api.select_partner_distribution_source(cycle2,sid,20000,'cannot alter approved');raise exception 'EXPECTED_APPROVED_DENIED';exception when check_violation then null;end;
 cycle:=finance.calculate_profit_distribution(w,end_at,end_at+interval '1 day',o,0);
 perform pg_temp.ps_check((select amount_minor=70000 from finance.current_distribution_source_selections where cycle_id=cycle and source_id=sid),'next nonoverlapping cycle sees remaining amount');
 r:=api.select_partner_distribution_source(cycle,sid,70000,'remaining amount');
 perform finance.approve_profit_distribution(cycle,o);
 perform pg_temp.ps_check((finance.distribution_source_availability(sid)->>'remaining_amount_minor')::bigint=0
  and(select sum(amount_minor)=100000 from finance.distribution_source_consumptions where source_id=sid)
  and(select amount_minor=100000 from finance.expenses where id=expense),'cross-cycle use conserves original source');
 begin delete from finance.distribution_source_consumptions where source_id=sid;raise exception 'EXPECTED_APPEND_ONLY';exception when check_violation then null;end;
 -- Real session/invoice/payment fixture; source selection uses only canonical
 -- collectible debt, not the original invoice cached outstanding value.
 f:=pg_temp.c2_fixture(10000,5000,true);
 update core.well_assignments set role='owner' where well_id=(f->>'well')::uuid and profile_id=(f->>'actor')::uuid;
 select fp.person_id into person from ops.farmer_profiles fp join ops.farmer_well_accounts a on a.farmer_profile_id=fp.id where a.id=(f->>'account')::uuid;
 insert into core.well_partners(tenant_id,well_id,person_id,phone,period_start) values((f->>'tenant')::uuid,(f->>'well')::uuid,person,'777777777',date '1970-01-01') returning id into partner;
 insert into core.ownership_share_versions(tenant_id,well_id,partner_id,ownership_percentage,profit_percentage,effective_period)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,partner,100,100,daterange(date '1970-01-01',null,'[)'));
 insert into core.partner_irrigation_policies(tenant_id,well_id,partner_id,policy_type,period_start)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,partner,'deduct_from_profit',date '1970-01-01') returning id into policy;
 invoice:=(f->>'invoice')::uuid;update billing.invoices set partner_policy_id=policy where id=invoice;
 select to_jsonb(i) into inv_before from billing.invoices i where id=invoice;
 perform api.update_distribution_settings((f->>'well')::uuid,false);
 cycle:=finance.calculate_profit_distribution((f->>'well')::uuid,(f->>'at')::timestamptz-interval '1 day',now(),(f->>'actor')::uuid,0);
 select id into strict sid from finance.distribution_sources where invoice_id=invoice;
 r:=api.add_partner_distribution_adjustment(cycle,sid,'deduction',2000,'partial irrigation offset');
 guarded_selection:=(r->>'selection_id')::uuid;
 -- An invoice becomes eligible after the newer source was selected. It is
 -- deliberately absent from the old selection list, so validation must inspect
 -- current canonical debt, not only the old proposal rows.
 insert into billing.invoices(tenant_id,well_id,public_code,farmer_well_account_id,invoice_date,status,
  subtotal_minor,total_minor,paid_minor,outstanding_minor,partner_policy_id)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,core.generate_public_code('INV'),(f->>'account')::uuid,
  (f->>'at')::timestamptz-interval '1 day','draft',1000,1000,0,1000,policy) returning id into older_invoice;
 update billing.invoices set status='issued' where id=older_invoice;
 select count(*) into before_consumptions from finance.distribution_source_consumptions;
 select count(*) into before_j from finance.journal_entries;
 begin perform finance.approve_profit_distribution(cycle,(f->>'actor')::uuid);raise exception 'EXPECTED_OLDER_BLOCK';
 exception when check_violation then
  perform pg_temp.ps_check(SQLERRM='distribution_older_debt_requires_settlement','newly eligible older debt blocks approval');end;
 perform pg_temp.ps_check(before_consumptions=(select count(*) from finance.distribution_source_consumptions)
  and before_j=(select count(*) from finance.journal_entries)
  and(select status='calculated' from finance.profit_distribution_cycles where id=cycle)
  and exists(select 1 from finance.current_distribution_source_selections where id=guarded_selection),
  'approval failure preserves draft and history, with zero partial consumption or posting');
 z:=api.get_partner_distribution_sources(cycle);
 perform pg_temp.ps_check(exists(select 1 from jsonb_array_elements(z->'sources') x
  where x->>'id'=guarded_selection::text and(x->'selection_review'->>'blocked_by_older_debt')::boolean
   and x->'selection_review'->>'title'='يوجد مبلغ أقدم يجب تسويته أولًا'),
  'review state is recoverable from persisted draft/current debt after failed approval');
 begin perform api.select_partner_distribution_source(cycle,sid,1000,'newer must not reserve');raise exception 'EXPECTED_NEWER_BLOCK';
 exception when check_violation then
  perform pg_temp.ps_check(SQLERRM='distribution_older_debt_requires_settlement','older invoice blocks newer manual selection');end;
 perform pg_temp.ps_check((select count(*)=0 from finance.distribution_source_consumptions where invoice_id=older_invoice)
  and exists(select 1 from finance.current_distribution_source_selections where id=guarded_selection and amount_minor=2000),
  'no silent source substitution or redirection');
 r:=api.select_partner_distribution_source(cycle,sid,null,'explicit return to automatic calculation');
 perform pg_temp.ps_check((select x.mode='automatic' and x.amount_minor=1000 from finance.current_distribution_source_selections x
   join finance.distribution_sources src on src.id=x.source_id where x.cycle_id=cycle and src.invoice_id=older_invoice)
  and(select amount_minor=4000 from finance.current_distribution_source_selections where cycle_id=cycle and source_id=sid),
  'explicit automatic mode discovers current older debt and consumes its proposed amount before newer debt');
 r:=api.record_payment(p_well_id=>(f->>'well')::uuid,p_farmer_well_account_id=>(f->>'account')::uuid,
  p_amount_minor=>500,p_method=>'cash',p_allocations=>jsonb_build_array(jsonb_build_object('invoice_id',older_invoice,'amount_minor',500)),
  p_paid_at=>(f->>'posting')::timestamptz,p_command_id=>gen_random_uuid());
 begin perform api.select_partner_distribution_source(cycle,sid,1000,'still newer');raise exception 'EXPECTED_PARTIAL_OLDER_BLOCK';
 exception when check_violation then
  perform pg_temp.ps_check(SQLERRM='distribution_older_debt_requires_settlement','partial remaining older debt still blocks');end;
 r:=api.record_payment(p_well_id=>(f->>'well')::uuid,p_farmer_well_account_id=>(f->>'account')::uuid,
  p_amount_minor=>500,p_method=>'cash',p_allocations=>jsonb_build_array(jsonb_build_object('invoice_id',older_invoice,'amount_minor',500)),
  p_paid_at=>(f->>'posting')::timestamptz,p_command_id=>gen_random_uuid());
 perform pg_temp.ps_check((select collectible_minor=0 from billing.invoice_effective_balances where invoice_id=older_invoice),
  'older debt genuinely exhausted through canonical payment authority');
 r:=api.select_partner_distribution_source(cycle,sid,2000,'owner chooses again after oldest paid');
 perform pg_temp.ps_check(r->>'status'='saved' and r->>'selection_id'<>guarded_selection::text,
  'currently eligible source accepts partial selection in a new preserved version');
 select to_jsonb(i) into inv_before from billing.invoices i where id=invoice;
 select count(*) into before_p from billing.payments;
 perform finance.approve_profit_distribution(cycle,(f->>'actor')::uuid);
 perform pg_temp.ps_check((select outstanding_minor=3000 and collectible_minor=3000 from billing.invoice_effective_balances where invoice_id=invoice)
  and inv_before=(select to_jsonb(i) from billing.invoices i where id=invoice),'non-cash source settlement enters canonical effective invoice debt without invoice mutation');
 perform pg_temp.ps_check(before_p=(select count(*) from billing.payments),'no fake payment');
 -- Departed partner's unused payable remains payable OUTSIDE distribution.
 -- No invented zero-share distribution line and no transfer to another person.
 insert into core.wells(tenant_id,name) values(t,'departed partner repayment') returning id into repayment_well;
 insert into core.well_assignments(well_id,profile_id,role,status) values(repayment_well,o,'owner','active');
 select person_id into person from core.well_partners where well_id=w order by id limit 1;
 insert into core.well_partners(tenant_id,well_id,person_id,phone,period_start,status)
 values(t,repayment_well,person,'777777777',date '1970-01-01','left') returning id into repayment_partner;
 perform set_config('request.jwt.claim.sub',o::text,true);
 select code into category from finance.expense_categories where tenant_id=t order by id limit 1;
 expense:=finance.record_expense(repayment_well,category,100000,'departed partner payable',o,null,true,'partner_paid',null,repayment_partner,'اختبار بلا سند');
 r:=api.prepare_partner_payable_source(expense);repayment_source:=(r->>'source_id')::uuid;repayment_command:=gen_random_uuid();
 select count(*) into before_p from billing.payments;
 receipt:=api.pay_departed_partner_source(repayment_source,30000,'actual standalone repayment',repayment_command);
 perform pg_temp.ps_check(receipt->>'status'='paid' and(receipt->>'remaining_amount_minor')::bigint=70000
  and(select count(*)=1 and sum(amount_minor)=30000 from finance.distribution_source_consumptions
   where source_id=repayment_source and settlement_kind='standalone_payment'),
  'departed partner repayment uses the same exact partial-consumption authority');
 r:=api.pay_departed_partner_source(repayment_source,30000,'actual standalone repayment',repayment_command);
 perform pg_temp.ps_check(r=receipt and(select count(*)=1 from finance.journal_entries where id=(receipt->>'journal_entry_id')::uuid),
  'standalone receipt replay has exactly one real cash posting');
 begin perform api.pay_departed_partner_source(repayment_source,30001,'changed request',repayment_command);raise exception 'EXPECTED_CHANGED_RECEIPT_DENIED';
 exception when invalid_parameter_value then null;end;
 r:=api.pay_departed_partner_source(repayment_source,70000,'actual remaining standalone repayment',gen_random_uuid());
 perform pg_temp.ps_check((r->>'remaining_amount_minor')::bigint=0 and before_p=(select count(*) from billing.payments)
  and not exists(select 1 from finance.profit_distribution_cycles where well_id=repayment_well),
  'remaining payable is settled without a fake farmer payment or new distribution cycle');
 -- Ambiguous legacy expense is quarantined; only the owner-confirmed
 -- remainder is reusable. Review itself never manufactures a journal/payment.
 perform set_config('request.jwt.claim.sub',o::text,true);
 select person_id into person from core.well_partners where well_id=w order by id limit 1;
 select id into legacy_partner from core.well_partners where well_id=w and person_id=person order by id limit 1;
 select code into category from finance.expense_categories where tenant_id=t order by id limit 1;
 expense:=finance.record_expense(w,category,50000,'ambiguous legacy payable',o,null,true,'partner_paid',null,legacy_partner,'اختبار بلا سند');
 r:=api.prepare_partner_payable_source(expense);legacy_source:=(r->>'source_id')::uuid;
 perform pg_temp.ps_check(r->>'status'='review_required' and r->>'remaining_amount_minor' is null,'ambiguous expense source does not invent historical consumption');
 select count(*) into before_j from finance.journal_entries;select count(*) into before_p from billing.payments;
 perform set_config('request.jwt.claim.sub',m::text,true);
 begin perform api.review_legacy_partner_expense_source(legacy_source,10000,'not owner');raise exception 'EXPECTED_REVIEW_OWNER_ONLY';exception when insufficient_privilege then null;end;
 perform set_config('request.jwt.claim.sub',o::text,true);
 begin perform api.review_legacy_partner_expense_source(legacy_source,50001,'too much');raise exception 'EXPECTED_REVIEW_CAPACITY';exception when invalid_parameter_value then null;end;
 r:=api.review_legacy_partner_expense_source(legacy_source,10000,'owner confirms old consumption');
 perform pg_temp.ps_check((r->>'remaining_amount_minor')::bigint=40000 and(r->>'used_amount_minor')::bigint=10000
  and before_j=(select count(*) from finance.journal_entries) and before_p=(select count(*) from billing.payments),
  'review derives remaining and preserves financial evidence without fake posting');
 begin update finance.distribution_source_reviews set confirmed_consumed_minor=0 where source_id=legacy_source;raise exception 'EXPECTED_REVIEW_IMMUTABLE';exception when check_violation then null;end;
 -- Historical invoice marker alone proves neither zero nor full usage.
 f:=pg_temp.c2_fixture(10000,0,true);
 update core.well_assignments set role='owner' where well_id=(f->>'well')::uuid and profile_id=(f->>'actor')::uuid;
 select fp.person_id into person from ops.farmer_profiles fp join ops.farmer_well_accounts a on a.farmer_profile_id=fp.id where a.id=(f->>'account')::uuid;
 insert into core.well_partners(tenant_id,well_id,person_id,phone,period_start)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,person,'777777777',date '1970-01-01') returning id into legacy_partner;
 insert into core.ownership_share_versions(tenant_id,well_id,partner_id,ownership_percentage,profit_percentage,effective_period)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,legacy_partner,100,100,daterange(date '1970-01-01',null,'[)'));
 insert into core.partner_irrigation_policies(tenant_id,well_id,partner_id,policy_type,period_start)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,legacy_partner,'deduct_from_profit',date '1970-01-01') returning id into policy;
 insert into finance.profit_distribution_cycles(tenant_id,well_id,period_start,period_end,status,distributable_amount_minor)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,(f->>'at')::timestamptz-interval '1 day',now(),'calculated',10000) returning id into legacy_cycle;
 insert into finance.profit_distribution_lines(tenant_id,distribution_cycle_id,partner_id,profit_percentage_snapshot,gross_share_minor,irrigation_deductions_minor,net_payable_minor)
 values((f->>'tenant')::uuid,legacy_cycle,legacy_partner,100,10000,1000,9000);
 update finance.profit_distribution_cycles set status='approved' where id=legacy_cycle;
 update finance.profit_distribution_lines set status='approved' where distribution_cycle_id=legacy_cycle;
 invoice:=(f->>'invoice')::uuid;update billing.invoices set partner_policy_id=policy,deducted_in_cycle_id=legacy_cycle where id=invoice;
 select to_jsonb(i) into legacy_invoice_before from billing.invoices i where id=invoice;
 select to_jsonb(c) into legacy_cycle_before from finance.profit_distribution_cycles c where id=legacy_cycle;
 legacy_source:=finance.register_distribution_source(null,invoice);
 perform pg_temp.ps_check(finance.distribution_source_availability(legacy_source)->>'status'='review_required'
  and(select collectible_minor=0 and collection_hold_minor=10000 from billing.invoice_effective_balances where invoice_id=invoice),
  'unknown legacy invoice usage is held in canonical debt view, never silently collected');
 begin perform billing.require_no_disputed_invoice(invoice,1);raise exception 'EXPECTED_QUARANTINE_COLLECTION_DENIED';exception when check_violation then null;end;
 select count(*) into before_j from finance.journal_entries;select count(*) into before_p from billing.payments;
 r:=api.open_legacy_invoice_accounting_review(invoice,legacy_cycle,1000,'owner checks old amount',gen_random_uuid());legacy_review:=(r->>'review_id')::uuid;
 r:=api.resolve_legacy_invoice_accounting_review(legacy_review,'confirmed_not_settled','owner confirms not consumed',gen_random_uuid());
 perform pg_temp.ps_check((finance.distribution_source_availability(legacy_source)->>'remaining_amount_minor')::bigint=10000
  and not billing.invoice_legacy_distribution_unresolved(invoice) and not billing.invoice_has_protected_distribution_use(invoice)
  and legacy_invoice_before=(select to_jsonb(i) from billing.invoices i where id=invoice)
  and legacy_cycle_before=(select to_jsonb(c) from finance.profit_distribution_cycles c where id=legacy_cycle)
  and before_j=(select count(*) from finance.journal_entries) and before_p=(select count(*) from billing.payments),
  'resolved nonsettlement releases canonical eligibility without historic invoice/cycle rewrite or fake payment/journal');
 select pg_get_functiondef('finance.r6c2_api_select_partner_distribution_source(uuid,uuid,bigint,text)'::regprocedure) into body;
 perform pg_temp.ps_check(position('billing.lock_customer_credit_well' in body)<position('for update' in body),'root first at manual selection boundary');
 perform pg_temp.ps_check(not has_table_privilege('authenticated','finance.profit_distribution_lines','UPDATE')
  and not has_function_privilege('authenticated','finance.consume_distribution_sources(uuid,uuid)','EXECUTE'),'no direct line mutation/private consumption execution');
end;$test$;
rollback;
