\set ON_ERROR_STOP on
-- Owner-only local regression; STATIC authoring, no DB executed by agent.
begin;
set local timezone='UTC';
create function pg_temp.lr_check(ok boolean,label text) returns void language plpgsql as $$
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

create function pg_temp.lr_fixture() returns jsonb language plpgsql as $$
declare f jsonb;person uuid;partner uuid;policy uuid;cycle uuid;
begin
 f:=pg_temp.c2_fixture(10000,0,true);
 update core.well_assignments set role='owner' where well_id=(f->>'well')::uuid and profile_id=(f->>'actor')::uuid;
 select fp.person_id into person from ops.farmer_profiles fp join ops.farmer_well_accounts a on a.farmer_profile_id=fp.id where a.id=(f->>'account')::uuid;
 insert into core.well_partners(tenant_id,well_id,person_id,phone,period_start)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,person,'777777777',date '1970-01-01') returning id into partner;
 insert into core.partner_irrigation_policies(tenant_id,well_id,partner_id,policy_type,period_start)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,partner,'deduct_from_profit',date '1970-01-01') returning id into policy;
 -- Ambiguous historical fixture: deliberately no exact source-level accounting
 -- evidence. It MUST enter review, never automatic proven settlement.
 insert into finance.profit_distribution_cycles(tenant_id,well_id,period_start,period_end,status,distributable_amount_minor)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,(f->>'at')::timestamptz-interval '1 day',
  (f->>'at')::timestamptz+interval '1 day','calculated',10000) returning id into cycle;
 insert into finance.profit_distribution_lines(tenant_id,distribution_cycle_id,partner_id,profit_percentage_snapshot,
  gross_share_minor,irrigation_deductions_minor,net_payable_minor)
 values((f->>'tenant')::uuid,cycle,partner,100,10000,4000,6000);
 update finance.profit_distribution_cycles set status='approved' where id=cycle;
 update finance.profit_distribution_lines set status='approved' where distribution_cycle_id=cycle;
 update billing.invoices set partner_policy_id=policy,deducted_in_cycle_id=cycle where id=(f->>'invoice')::uuid;
 return f||jsonb_build_object('partner',partner,'cycle',cycle);
end;$$;

do $test$
declare f jsonb;g jsonb;r jsonb;z jsonb;review_key uuid;cmd uuid;opening_cmd uuid;
 before_invoice jsonb;before_cycle jsonb;before_lines jsonb;before_j bigint;before_pay bigint;role_name text;body text;
begin
 f:=pg_temp.lr_fixture();
 select to_jsonb(i) into before_invoice from billing.invoices i where id=(f->>'invoice')::uuid;
 select to_jsonb(c) into before_cycle from finance.profit_distribution_cycles c where id=(f->>'cycle')::uuid;
 select jsonb_agg(to_jsonb(l) order by id) into before_lines from finance.profit_distribution_lines l where distribution_cycle_id=(f->>'cycle')::uuid;
 select count(*) into before_j from finance.journal_entries;select count(*) into before_pay from billing.payments;
 perform set_config('request.jwt.claim.sub',f->>'actor',true);opening_cmd:=gen_random_uuid();
 execute 'set local role authenticated';
 r:=api.open_legacy_invoice_accounting_review((f->>'invoice')::uuid,(f->>'cycle')::uuid,4000,'  owner confirms historical use  ',opening_cmd);
 execute 'reset role';review_key:=(r->>'review_id')::uuid;
 perform pg_temp.lr_check(r->>'status'='accounting_review_required','ambiguous accounting offset not silently proven');
 perform pg_temp.lr_check((select outstanding_minor=10000 and collection_hold_minor=4000 and collectible_minor=6000
  from billing.invoice_effective_balances where invoice_id=(f->>'invoice')::uuid),'pending amount held within canonical effective balance, debt unchanged');
 perform pg_temp.lr_check(exists(select 1 from billing.legacy_invoice_review_effects where review_id=review_key
  and status='accounting_review_required'),'durable unresolved review');
 begin perform api.record_payment(p_well_id=>(f->>'well')::uuid,p_farmer_well_account_id=>(f->>'account')::uuid,
  p_amount_minor=>10000,p_method=>'cash',p_session_charge_id=>(f->>'charge')::uuid,p_command_id=>gen_random_uuid());
  raise exception 'EXPECTED_DISPUTED_COLLECTION_DENIED';exception when check_violation then null;end;
 foreach role_name in array array['manager','operator'] loop
  update core.well_assignments set role=role_name where well_id=(f->>'well')::uuid and profile_id=(f->>'actor')::uuid;
  begin perform api.resolve_legacy_invoice_accounting_review(review_key,'confirmed_non_cash_settlement','decision',gen_random_uuid());
   raise exception 'EXPECTED_ROLE_DENIED';exception when insufficient_privilege then null;end;
 end loop;
 -- There is no independent accountant assignment authority for this action;
 -- only the exact active owner assignment qualifies, regardless of permission.
 update core.well_assignments set role='owner',status='inactive' where well_id=(f->>'well')::uuid and profile_id=(f->>'actor')::uuid;
 begin perform api.resolve_legacy_invoice_accounting_review(review_key,'confirmed_not_settled','decision',gen_random_uuid());
  raise exception 'EXPECTED_INACTIVE_DENIED';exception when insufficient_privilege then null;end;
 update core.well_assignments set status='active' where well_id=(f->>'well')::uuid and profile_id=(f->>'actor')::uuid;
 g:=pg_temp.lr_fixture();
 begin perform api.resolve_legacy_invoice_accounting_review(review_key,'confirmed_non_cash_settlement','decision',gen_random_uuid());
  raise exception 'EXPECTED_CROSS_WELL_DENIED';exception when insufficient_privilege then null;end;
 perform set_config('request.jwt.claim.sub',f->>'actor',true);cmd:=gen_random_uuid();
 select count(*) into before_j from finance.journal_entries;select count(*) into before_pay from billing.payments;
 execute 'set local role authenticated';
 r:=api.resolve_legacy_invoice_accounting_review(review_key,'confirmed_non_cash_settlement','  resolved by owner  ',cmd);
 z:=api.resolve_legacy_invoice_accounting_review(review_key,'confirmed_non_cash_settlement','  resolved by owner  ',cmd);
 execute 'reset role';
 perform pg_temp.lr_check(before_j=(select count(*) from finance.journal_entries) and before_pay=(select count(*) from billing.payments),'confirmed settlement creates no payment or journal');
 perform pg_temp.lr_check(r=z and r->>'status'='confirmed_non_cash_settlement','owner exact replay returns original result');
 perform pg_temp.lr_check((select count(*)=1 and sum(settlement_amount_minor)=4000 from billing.legacy_invoice_accounting_resolutions where review_id=review_key),
  'one terminal effect despite replay');
 begin perform api.resolve_legacy_invoice_accounting_review(review_key,'confirmed_not_settled','different',gen_random_uuid());
  raise exception 'EXPECTED_CONFLICT';exception when invalid_parameter_value then null;end;
 perform pg_temp.lr_check((select paid_minor=4000 and outstanding_minor=6000 and collectible_minor=6000 and collection_hold_minor=0
  from billing.invoice_effective_balances where invoice_id=(f->>'invoice')::uuid),'noncash settlement reduces debt exactly once');
 perform pg_temp.lr_check((select debt_minor=6000 from reporting.farmer_account_balances where farmer_well_account_id=(f->>'account')::uuid),
  'farmer debt agrees with canonical invoice balance');
 begin perform api.record_payment(p_well_id=>(f->>'well')::uuid,p_farmer_well_account_id=>(f->>'account')::uuid,
  p_amount_minor=>10000,p_method=>'cash',p_session_charge_id=>(f->>'charge')::uuid,
  p_allocations=>jsonb_build_array(jsonb_build_object('invoice_id',(f->>'invoice')::uuid,'amount_minor',10000)),p_command_id=>gen_random_uuid());
  raise exception 'EXPECTED_DOUBLE_COLLECTION_DENIED';exception when check_violation or raise_exception then
   if SQLERRM='EXPECTED_DOUBLE_COLLECTION_DENIED' then raise;end if;
   perform pg_temp.lr_check(SQLERRM='invoice_collectible_amount_exceeded' or SQLERRM like 'مبلغ التخصيص % يتجاوز دين الفاتورة المتبقي %' or SQLERRM=format('مجموع الفواتير المختارة %s يجب أن يساوي الجزء المسدد من المستحق %s',10000,6000),'failure is debt capacity, not unrelated fixture error');end;
 z:=api.get_legacy_invoice_accounting_review(review_key);
 perform pg_temp.lr_check(z->>'status'='confirmed_non_cash_settlement' and z->>'collectible_amount_minor'='6000'
  and z->>'message'='تم تحديث المبلغ المتبقي ولن يتم تحصيل الجزء المستخدم مرة أخرى.','simple current owner read uses canonical debt');
 perform pg_temp.lr_check(before_invoice=(select to_jsonb(i) from billing.invoices i where id=(f->>'invoice')::uuid),
  'resolution leaves entire original invoice row unchanged');
 perform pg_temp.lr_check(before_cycle=(select to_jsonb(c) from finance.profit_distribution_cycles c where id=(f->>'cycle')::uuid)
  and before_lines=(select jsonb_agg(to_jsonb(l) order by id) from finance.profit_distribution_lines l where distribution_cycle_id=(f->>'cycle')::uuid),
  'approved historical cycle and lines unchanged');
 -- Second fixture already created genuine invoices/journals: snapshot now and
 -- prove resolution creates none, rather than comparing unrelated fixture work.
 select count(*) into before_j from finance.journal_entries;select count(*) into before_pay from billing.payments;
 perform set_config('request.jwt.claim.sub',g->>'actor',true);
 r:=api.open_legacy_invoice_accounting_review((g->>'invoice')::uuid,(g->>'cycle')::uuid,3000,'historical use',gen_random_uuid());
 r:=api.resolve_legacy_invoice_accounting_review((r->>'review_id')::uuid,'confirmed_not_settled','owner determined not settled',gen_random_uuid());
 perform pg_temp.lr_check(r->>'status'='confirmed_not_settled' and (select outstanding_minor=10000 and collectible_minor=10000 and collection_hold_minor=0
  from billing.invoice_effective_balances where invoice_id=(g->>'invoice')::uuid),'not-settled releases hold without reducing debt');
 perform pg_temp.lr_check(before_j=(select count(*) from finance.journal_entries) and before_pay=(select count(*) from billing.payments),
  'no fake payment or duplicate journal');
 begin update billing.legacy_invoice_accounting_resolutions set reason='erased';raise exception 'EXPECTED_HISTORY_DENIED';exception when check_violation then null;end;
 select pg_get_functiondef('finance.r6c2_api_resolve_legacy_invoice_accounting_review(uuid,text,text,uuid)'::regprocedure) into body;
 perform pg_temp.lr_check(position('billing.lock_customer_credit_well' in body)<position('for update' in body)
  and position('iam.has_well_role(r.well_id,array[''owner''])' in body)>position('for update' in body)
  and position('session.correct' in body)=0,'root first; active owner rechecked after wait; session.correct never authority');
 perform pg_temp.lr_check(exists(select 1 from pg_constraint where conrelid='billing.legacy_invoice_accounting_resolutions'::regclass
  and contype='u' and pg_get_constraintdef(oid)='UNIQUE (review_id)'),'one resolution physically enforced for concurrent attempts');
end;$test$;
rollback;
