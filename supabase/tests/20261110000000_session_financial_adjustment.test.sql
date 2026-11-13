\set ON_ERROR_STOP on
-- Disposable local database only. All fixtures and assertions roll back.
begin;
set local timezone='UTC';
create function pg_temp.sfa_assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL %',label;end if;raise notice 'PASS %',label;end;$$;
do $$begin
 perform pg_temp.sfa_assert(to_regprocedure('api.adjust_session_financial_amount(uuid,uuid,bigint,bigint,bigint,bigint,text,timestamptz)') is not null,'corrected three-revision contract exists');
end;$$;
create function pg_temp.sfa_fixture(seconds bigint default 10000,paid bigint default 0,invoiced boolean default false,
 paused boolean default false,diesel boolean default false,price bigint default 3600,
 fixture_tenant uuid default null,fixture_actor uuid default null) returns jsonb language plpgsql as $$
declare t uuid:=fixture_tenant;w uuid;actor uuid:=coalesce(fixture_actor,gen_random_uuid());person uuid;farmer uuid;account uuid;farm uuid;pump uuid;sid uuid;
 invoice uuid;start_cmd uuid:=gen_random_uuid();end_cmd uuid:=gen_random_uuid();charge jsonb;payment jsonb;
 at_time timestamptz:=date_trunc('day',transaction_timestamp())-interval '2 days';pause_seconds bigint:=case when paused then 600 else 0 end;
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

create function pg_temp.sfa_adjust(f jsonb,amount bigint,op bigint default 0,sys bigint default 0,manual bigint default 0,cmd uuid default gen_random_uuid())
returns jsonb language plpgsql as $$declare r jsonb;begin
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 execute 'set local role authenticated';
 r:=api.adjust_session_financial_amount((f->>'session')::uuid,cmd,op,sys,manual,amount,'  approved reason  ',(f->>'posting')::timestamptz);
 execute 'reset role';return r;
exception when others then execute 'reset role';raise;end;$$;
create function pg_temp.sfa_state(f jsonb) returns jsonb language plpgsql as $$begin
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 return api.get_session_financial_state((f->>'session')::uuid);end;$$;
create function pg_temp.sfa_correct(f jsonb,base bigint,seconds bigint) returns uuid language plpgsql as $$declare r jsonb;begin
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 r:=ops.accept_session_correction((f->>'session')::uuid,gen_random_uuid(),base,'time reason',
 (f->>'at')::timestamptz,(f->>'at')::timestamptz+seconds*interval '1 second',(f->>'posting')::timestamptz);
 return(r->>'correction_id')::uuid;end;$$;

create function pg_temp.sfa_zero_reads(invoiced boolean default false,system_zero boolean default false,read_kind text default 'both')
returns void language plpgsql as $$
declare f jsonb;r jsonb;st jsonb;item jsonb;before_pay jsonb;before_alloc jsonb;before_credit jsonb;
 original_invoice jsonb;original_lines jsonb;original_journal jsonb;kind text;label text;
begin
 f:=pg_temp.sfa_fixture(case when system_zero then 1 else 10000 end,case when invoiced then 10000 else 0 end,invoiced,false,false,case when system_zero then 1 else 3600 end);
 label:=case when invoiced then 'invoiced' when system_zero then 'system' else 'uninvoiced' end;
 select coalesce(jsonb_agg(to_jsonb(p) order by id),'[]') into before_pay from billing.payments p;
 select coalesce(jsonb_agg(to_jsonb(a) order by id),'[]') into before_alloc from billing.payment_allocations a;
 select coalesce(jsonb_agg(to_jsonb(e) order by id),'[]') into before_credit from billing.customer_credit_events e;
 if invoiced then
  select to_jsonb(i)-array['paid_minor','outstanding_minor','status','correction_total_delta_minor','updated_at'] into original_invoice
   from billing.invoices i where id=(f->>'invoice')::uuid;
  select jsonb_agg(to_jsonb(l) order by id) into original_lines from billing.invoice_lines l where invoice_id=(f->>'invoice')::uuid;
  select to_jsonb(j) into original_journal from finance.journal_entries j where id=(original_invoice->>'journal_entry_id')::uuid;
 end if;
 if not system_zero then r:=pg_temp.sfa_adjust(f,0);perform pg_temp.sfa_assert(r->>'status'='accepted',label||' zero accepted');end if;
 st:=pg_temp.sfa_state(f);
 perform pg_temp.sfa_assert(st->>'effective_amount_minor'='0' and st->>'paid_amount_minor'='0'
  and st->>'outstanding_amount_minor'='0'
  and case when system_zero then st->>'system_amount_minor'='0' else st->>'approved_amount_minor'='0' end,
  label||' zero effective settlement and outstanding');
 execute 'set local role authenticated';
 foreach kind in array case when read_kind='both' then array['list','detail'] else array[read_kind] end loop
  if kind='list' then
   st:=api.list_well_sessions((f->>'well')::uuid,null,null,null,false,200);
   select value into strict item from jsonb_array_elements(st->'items') where value->>'id'=f->>'session';
  else
   st:=api.get_session_detail((f->>'session')::uuid);item:=st->'session';
   if not invoiced then perform pg_temp.sfa_assert(st->'payment'='null'::jsonb,label||' zero detail has no receipt evidence');end if;
  end if;
  perform pg_temp.sfa_assert(item->>'total_amount_minor'='0' and item->>'paid_amount_minor'='0'
   and item->>'payment_status'='settled' and item->>'has_charge'='true',label||' zero '||kind||' canonical settled without balance');
 end loop;
 st:=api.list_well_sessions((f->>'well')::uuid,null,null,null,true,200);
 perform pg_temp.sfa_assert(not exists(select 1 from jsonb_array_elements(st->'items') i where i->>'id'=f->>'session'),label||' zero absent from unpaid filter');
 execute 'reset role';
 perform pg_temp.sfa_assert(before_pay=(select coalesce(jsonb_agg(to_jsonb(p) order by id),'[]') from billing.payments p),label||' payment rows unchanged');
 perform pg_temp.sfa_assert(before_alloc=(select coalesce(jsonb_agg(to_jsonb(a) order by id),'[]') from billing.payment_allocations a),label||' payment allocations unchanged');
 if not invoiced then
  perform pg_temp.sfa_assert(before_credit=(select coalesce(jsonb_agg(to_jsonb(e) order by id),'[]') from billing.customer_credit_events e),label||' account-credit events unchanged');
  r:=api.issue_session_invoice_result((f->>'session')::uuid);
  perform pg_temp.sfa_assert(r->>'status'='not_required_zero_effective' and r->'invoice_id'='null'::jsonb
   and not exists(select 1 from billing.invoices where session_id=(f->>'session')::uuid)
   and not exists(select 1 from finance.journal_entries where well_id=(f->>'well')::uuid),label||' no fake invoice or journal');
 else
  perform pg_temp.sfa_assert(original_invoice=(select to_jsonb(i)-array['paid_minor','outstanding_minor','status','correction_total_delta_minor','updated_at']
   from billing.invoices i where id=(f->>'invoice')::uuid)
   and original_lines=(select jsonb_agg(to_jsonb(l) order by id) from billing.invoice_lines l where invoice_id=(f->>'invoice')::uuid)
   and original_journal=(select to_jsonb(j) from finance.journal_entries j where id=(original_invoice->>'journal_entry_id')::uuid),'invoiced zero source invoice lines and journal preserved');
  perform pg_temp.sfa_assert((select count(*)=1 and min(delta_minor)=-10000 from billing.invoice_financial_adjustments where adjustment_id=(r->>'adjustment_id')::uuid)
   and exists(select 1 from finance.journal_entries where id=(select journal_entry_id from billing.invoice_financial_adjustments where adjustment_id=(r->>'adjustment_id')::uuid) and status='posted'),'invoiced zero compensating adjustment preserved');
  perform pg_temp.sfa_assert((select sum(effective_allocated_minor)=0 from billing.effective_payment_allocations where invoice_id=(f->>'invoice')::uuid)
   and (select sum(available_minor)=10000 from billing.account_credit_balances where payment_id=(f->>'payment')::uuid),'invoiced zero releases only provable original settlement');
  r:=api.issue_session_invoice_result((f->>'session')::uuid);
  perform pg_temp.sfa_assert(r->>'status'='already_issued' and r->>'invoice_id'=f->>'invoice','invoiced zero retains original invoice identity');
 end if;
 set constraints all immediate;
exception when others then execute 'reset role';raise;end;$$;

create function pg_temp.sfa_command_reads() returns void language plpgsql as $$
declare f jsonb;g jsonb;r jsonb;original jsonb;cmd uuid:=gen_random_uuid();before_adjust bigint;before_journal bigint;before_invoice bigint;
begin
 f:=pg_temp.sfa_fixture();original:=pg_temp.sfa_adjust(f,8500,0,0,0,cmd);
 r:=pg_temp.sfa_adjust(f,9000,0,0,1);
 select count(*) into before_adjust from billing.session_financial_adjustments;
 select count(*) into before_journal from finance.journal_entries;select count(*) into before_invoice from billing.invoices;
 r:=pg_temp.sfa_adjust(f,8500,0,0,0,cmd);
 perform pg_temp.sfa_assert(r=original and pg_temp.sfa_state(f)->>'effective_amount_minor'='9000','command replay preserves stored result after newer approval');
 r:=pg_temp.sfa_adjust(f,8600,0,0,0,cmd);
 perform pg_temp.sfa_assert(r->>'status'='conflict_request' and not(r ? 'adjustment_id'),'changed request typed conflict without stored financial result');
 g:=pg_temp.sfa_fixture(fixture_tenant=>(f->>'tenant')::uuid,fixture_actor=>(f->>'actor')::uuid);
 r:=pg_temp.sfa_adjust(g,8500,0,0,0,cmd);
 perform pg_temp.sfa_assert(r=jsonb_build_object('contract','session_financial_adjustment','version',1,'status','conflict_request',
  'session_id',g->>'session','command_id',cmd,'retry_authorized',false),'cross-well command conflict discloses only requested scope');
 r:=api.get_session_financial_adjustment_receipt((g->>'session')::uuid,cmd);
 perform pg_temp.sfa_assert(r->>'status'='not_found' and r->'result'='null'::jsonb and r->>'retry_authorized'='false','cross-well receipt absence never discloses or authorizes resend');
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 r:=api.get_session_financial_adjustment_receipt((f->>'session')::uuid,cmd);
 perform pg_temp.sfa_assert(r->'result'=original and r->>'retry_authorized'='false','original receipt unchanged after newer state');
 r:=api.get_session_financial_adjustment_receipt((f->>'session')::uuid,gen_random_uuid());
 perform pg_temp.sfa_assert(r->>'status'='not_found' and r->'result'='null'::jsonb and r->>'retry_authorized'='false','unknown receipt still not resend authorization');
 perform pg_temp.sfa_assert(before_adjust=(select count(*) from billing.session_financial_adjustments)
  and before_journal=(select count(*) from finance.journal_entries) and before_invoice=(select count(*) from billing.invoices)
  and (select count(*)=1 from sync.processed_commands where tenant_id=(f->>'tenant')::uuid and command_id=cmd),'command reads and conflicts have no second economic effect');
 set constraints all immediate;
end;$$;

\if :{?sfa_focused_only}
\else
do $tests$
declare f jsonb;r jsonb;st jsonb;again jsonb;cmd uuid;iv uuid;j uuid;c uuid;n bigint;rowdata jsonb;denied boolean;kind text;delta bigint;
begin
 f:=pg_temp.sfa_fixture();st:=pg_temp.sfa_state(f);
 perform pg_temp.sfa_assert(st->>'original_amount_minor'='10000' and st->>'system_amount_minor'='10000'
 and st->>'effective_amount_minor'='10000' and st->>'manual_approval_revision'='0','original system and effective baseline');
 cmd:=gen_random_uuid();r:=pg_temp.sfa_adjust(f,8500,0,0,0,cmd);
 perform pg_temp.sfa_assert(r->>'status'='accepted','first manual approval accepted');
 st:=pg_temp.sfa_state(f);
 perform pg_temp.sfa_assert(st->>'effective_amount_minor'='8500' and st->>'system_amount_minor'='10000'
 and st->>'manual_approval_revision'='1' and st->>'system_financial_revision'='0','manual and system revisions independent');
 perform pg_temp.sfa_assert(not exists(select 1 from billing.invoices where session_id=(f->>'session')::uuid)
 and not exists(select 1 from finance.journal_entries where source_type='session_financial_adjustment' and source_id=(r->>'adjustment_id')::uuid),'uninvoiced approval invents no invoice or revenue journal');
 again:=pg_temp.sfa_adjust(f,8500,0,0,0,cmd);
 perform pg_temp.sfa_assert(again=r,'exact command replay');
 again:=pg_temp.sfa_adjust(f,8600,0,0,0,cmd);
 perform pg_temp.sfa_assert(again->>'status'='conflict_request','changed payload deterministic conflict');
 perform pg_temp.sfa_assert(api.get_session_financial_adjustment_receipt((f->>'session')::uuid,cmd)->'result'=r,'accepted receipt returns original result');
 again:=api.get_session_financial_adjustment_receipt((f->>'session')::uuid,gen_random_uuid());
 perform pg_temp.sfa_assert(again->>'status'='not_found' and again->>'retry_authorized'='false','receipt absence never authorizes resend');
 again:=pg_temp.sfa_adjust(f,9000,0,0,1);
 perform pg_temp.sfa_assert(again->>'delta_minor'='500' and again->>'manual_approval_revision'='2','second delta from previous effective');
 r:=api.issue_session_invoice_result((f->>'session')::uuid);iv:=(r->>'invoice_id')::uuid;
 perform pg_temp.sfa_assert(r->>'status'='issued' and (select total_minor=9000 from billing.invoices where id=iv),'later invoice approved total');
 perform pg_temp.sfa_assert((select count(*)=1 and min(amount_minor)=-1000 from billing.invoice_lines where invoice_id=iv and line_type='manual_adjustment'),'carry-in is net minus1000 not last plus500');
 select journal_entry_id into j from billing.invoices where id=iv;
 perform pg_temp.sfa_assert((select sum(case when entry_side='debit' then amount_minor else -amount_minor end)=0 and min(amount_minor)>0 from finance.journal_lines where journal_entry_id=j),'signed invoice journal balances positive magnitudes');
 perform pg_temp.sfa_assert(exists(select 1 from finance.journal_lines l join finance.ledger_accounts a on a.id=l.ledger_account_id where l.journal_entry_id=j and a.account_code='4300' and l.entry_side='debit' and l.amount_minor=1000),'carry-in debit4300');
 f:=pg_temp.sfa_fixture();r:=pg_temp.sfa_adjust(f,0);r:=api.issue_session_invoice_result((f->>'session')::uuid);
 perform pg_temp.sfa_assert(r->>'status'='not_required_zero_effective' and r->'invoice_id'='null'::jsonb
 and not exists(select 1 from billing.invoices where session_id=(f->>'session')::uuid)
 and not exists(select 1 from finance.journal_entries where well_id=(f->>'well')::uuid)
 and (pg_temp.sfa_state(f)->>'outstanding_amount_minor')='0','typed zero no invoice no journal no debt');
 f:=pg_temp.sfa_fixture();r:=pg_temp.sfa_adjust(f,12000);r:=api.issue_session_invoice_result((f->>'session')::uuid);
 select journal_entry_id into j from billing.invoices where id=(r->>'invoice_id')::uuid;
 perform pg_temp.sfa_assert(exists(select 1 from finance.journal_lines l join finance.ledger_accounts a on a.id=l.ledger_account_id where l.journal_entry_id=j and a.account_code='4300' and l.entry_side='credit' and l.amount_minor=2000),'increase credit4300');
 f:=pg_temp.sfa_fixture(10000,4000,true);r:=pg_temp.sfa_adjust(f,8500);st:=pg_temp.sfa_state(f);
 perform pg_temp.sfa_assert(r->>'status'='accepted' and st->>'paid_amount_minor'='4000' and st->>'outstanding_amount_minor'='4500','partial payment 4000 outstanding4500');
 perform pg_temp.sfa_assert((select total_minor=10000 from billing.invoices where id=(f->>'invoice')::uuid)
 and not exists(select 1 from billing.invoice_lines where invoice_id=(f->>'invoice')::uuid and line_type='manual_adjustment'),'existing invoice source and lines preserved');
 f:=pg_temp.sfa_fixture(10000,10000,true);r:=pg_temp.sfa_adjust(f,8500);st:=pg_temp.sfa_state(f);
 perform pg_temp.sfa_assert(r->>'status'='accepted' and st->>'paid_amount_minor'='8500' and st->>'outstanding_amount_minor'='0'
 and (select sum(available_minor)=1500 from billing.account_credit_balances where payment_id=(f->>'payment')::uuid),'fully paid decrease creates backed1500 credit');
 perform pg_temp.sfa_assert((select amount_minor=10000 from billing.payments where id=(f->>'payment')::uuid),'original receipt10000 preserved');
 f:=pg_temp.sfa_fixture(10000,10000,true);r:=pg_temp.sfa_adjust(f,12000);st:=pg_temp.sfa_state(f);
 perform pg_temp.sfa_assert(r->>'status'='accepted' and st->>'paid_amount_minor'='10000' and st->>'outstanding_amount_minor'='2000','fully paid increase outstanding2000');
 f:=pg_temp.sfa_fixture(10000,10000,true);r:=pg_temp.sfa_adjust(f,0);st:=pg_temp.sfa_state(f);
 perform pg_temp.sfa_assert(r->>'status'='accepted' and st->>'effective_amount_minor'='0' and st->>'paid_amount_minor'='0'
 and (select sum(available_minor)=10000 from billing.account_credit_balances where payment_id=(f->>'payment')::uuid),'existing paid invoice zero preserves backed credit');
 f:=pg_temp.sfa_fixture(10000,0,true);r:=pg_temp.sfa_adjust(f,8500);
 c:=pg_temp.sfa_correct(f,0,11000);r:=billing.reconcile_session_correction(c,gen_random_uuid(),(f->>'posting')::timestamptz);
 perform pg_temp.sfa_assert(r->>'status'='financial_review_required' and r->>'review_code'='manual_approval_reconciliation_required'
 and pg_temp.sfa_state(f)->>'effective_amount_minor'='8500','time correction preserves manual approval and reviews');
 r:=pg_temp.sfa_adjust(f,9000,1,0,1);st:=pg_temp.sfa_state(f);
 perform pg_temp.sfa_assert(r->>'status'='accepted' and st->>'system_amount_minor'='11000' and st->>'effective_amount_minor'='9000'
 and st->>'system_financial_revision'='1' and st->>'manual_approval_revision'='2' and r->>'delta_minor'='500','paired reapproval advances system and applies only500');
 perform pg_temp.sfa_assert(not exists(select 1 from billing.invoice_corrections where correction_id=c)
 and (select status='applied' from ops.session_correction_reconciliations where correction_id=c),'paired calculation has no duplicate system economic publication');
 c:=pg_temp.sfa_correct(f,1,12000);r:=billing.reconcile_session_correction(c,gen_random_uuid(),(f->>'posting')::timestamptz);
 r:=pg_temp.sfa_adjust(f,9500,2,1,2);st:=pg_temp.sfa_state(f);
 perform pg_temp.sfa_assert(r->>'status'='accepted' and st->>'system_amount_minor'='12000' and st->>'system_financial_revision'='2','second later correction continues system chain');
 r:=pg_temp.sfa_adjust(f,9600,2,1,3);
 perform pg_temp.sfa_assert(r->>'status'='conflict_revision','stale system revision rejected');
 r:=pg_temp.sfa_adjust(f,-1,2,2,3);
 perform pg_temp.sfa_assert(r->>'status'='validation_error','negative amount rejected');
 select to_jsonb(a) into rowdata from billing.session_financial_adjustments a where session_id=(f->>'session')::uuid order by manual_approval_revision limit 1;
 denied:=false;begin delete from billing.session_financial_adjustments where id=(rowdata->>'id')::uuid;exception when check_violation then denied:=true;end;
 perform pg_temp.sfa_assert(denied,'approval append only');
 set constraints all immediate;
 perform pg_temp.sfa_assert(true,'deferred table-specific validators and C2 validators pass');
end;$tests$;

-- Additional boundaries are exercised as real authenticated operations.
do $boundaries$
declare f jsonb;r jsonb;sid uuid;who uuid;iv uuid;j uuid;kind text;sign bigint;rev bigint;denied boolean;
begin
 f:=pg_temp.sfa_fixture();
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 for kind in select unnest(array['operator','manager','owner']) loop
  update core.well_assignments set role=kind where well_id=(f->>'well')::uuid and profile_id=(f->>'actor')::uuid;
  r:=pg_temp.sfa_adjust(f,10000,0,0,case kind when 'operator' then 0 when 'manager' then 1 else 2 end);
  perform pg_temp.sfa_assert(r->>'status'='accepted',kind||' explicit financial permission');
 end loop;
 update core.well_assignments set status='inactive' where well_id=(f->>'well')::uuid and profile_id=(f->>'actor')::uuid;
 denied:=false;begin perform api.get_session_financial_state((f->>'session')::uuid);exception when insufficient_privilege then denied:=true;end;
 perform pg_temp.sfa_assert(denied,'inactive assignment cannot read financial authority');
 update core.well_assignments set status='active',role='operator' where well_id=(f->>'well')::uuid and profile_id=(f->>'actor')::uuid;
 execute 'set local role authenticated';
 sid:=api.start_operational_session((f->>'well')::uuid,(select pump_id from ops.irrigation_sessions where id=(f->>'session')::uuid),
 (select farm_id from ops.irrigation_sessions where id=(f->>'session')::uuid),(f->>'account')::uuid,'solar',clock_timestamp()-interval '1 hour',gen_random_uuid());
 execute 'reset role';
 r:=api.get_session_financial_adjustment_capability(sid);
 perform pg_temp.sfa_assert(r->>'can_adjust'='false','active uncharged session has no amount authority');
 execute 'set local role authenticated';perform api.complete_irrigation_session(sid,clock_timestamp()-interval '1 minute',null::bigint,null::text,null::uuid,gen_random_uuid());execute 'reset role';
 r:=api.get_session_financial_adjustment_capability(sid);
 perform pg_temp.sfa_assert(r->>'can_adjust'='true','completion joins ordinary financial path');
 foreach kind in array array['solar_irrigation','diesel_operation','diesel_fuel','partner_adjustment','additional_fee','opening_balance','manual_adjustment'] loop
  foreach sign in array array[-1::bigint,0::bigint,1::bigint] loop
   perform billing.enter_financial_write((f->>'well')::uuid,'invoice.issue');
   insert into billing.invoices(tenant_id,well_id,farmer_well_account_id,public_code,invoice_date,status,subtotal_minor,total_minor,outstanding_minor)
   values((f->>'tenant')::uuid,(f->>'well')::uuid,(f->>'account')::uuid,core.generate_public_code('INV'),clock_timestamp(),'draft',5000+sign*1000,5000+sign*1000,5000+sign*1000) returning id into iv;
   insert into billing.invoice_lines(tenant_id,invoice_id,line_number,line_type,description,quantity,unit,unit_price_minor,amount_minor)
   values((f->>'tenant')::uuid,iv,1,'solar_irrigation','system',1,'unit',5000,5000),
    ((f->>'tenant')::uuid,iv,2,kind,'signed',1,'unit',sign*1000,sign*1000);
   update billing.invoices set status='issued',issued_by=(f->>'actor')::uuid where id=iv;
   select journal_entry_id into j from billing.invoices where id=iv;
   perform pg_temp.sfa_assert((select min(amount_minor)>0 and sum(case when entry_side='debit' then amount_minor else -amount_minor end)=0
    from finance.journal_lines where journal_entry_id=j),kind||' sign '||sign||' valid balanced journal');
  end loop;
 end loop;
 perform pg_temp.sfa_assert(not has_function_privilege('anon','api.adjust_session_financial_amount(uuid,uuid,bigint,bigint,bigint,bigint,text,timestamptz)','EXECUTE'),'anonymous write denied');
 perform pg_temp.sfa_assert(not has_table_privilege('authenticated','billing.session_financial_adjustments','INSERT')
 and not has_table_privilege('authenticated','billing.invoice_financial_adjustments','UPDATE'),'no direct history DML');
 perform pg_temp.sfa_assert((select count(*)=2 from pg_constraint where conname in('session_charge_corrections_check1','invoice_corrections_check1')),'C2 sequence constraints retained');
 set constraints all immediate;
end;$boundaries$;
set constraints all deferred;
do $coverage$
declare f jsonb;r jsonb;c ops.session_corrections%rowtype;e jsonb;cmd uuid:=gen_random_uuid();denied boolean:=false;
begin
 f:=pg_temp.sfa_fixture(10000,0,true);r:=pg_temp.sfa_adjust(f,8500);
 cmd:=pg_temp.sfa_correct(f,0,11000);
 select * into strict c from ops.session_corrections where id=cmd;
 cmd:=gen_random_uuid();
 e:=billing.derive_session_correction_charge(c.id);
 begin
  update ops.session_correction_reconciliations set status='applied',financial_applied_revision=c.new_revision,
   last_reconciliation_command_id=cmd where correction_id=c.id;
  insert into billing.session_charge_corrections(correction_id,tenant_id,well_id,session_id,session_charge_id,
   operational_revision,previous_financial_revision,old_amount_minor,new_amount_minor,delta_minor,billable_seconds,
   weighted_rate_minor,effective_started_at,effective_ended_at,pricing_evidence,reconciliation_command_id,source_id,posted_at)
  values(c.id,c.tenant_id,c.well_id,c.session_id,(f->>'charge')::uuid,1,0,10000,11000,1000,
   (e->>'billable_seconds')::bigint,(e->>'weighted_rate_minor')::bigint,c.after_started_at,c.after_ended_at,e,cmd,gen_random_uuid(),(f->>'posting')::timestamptz);
  set constraints all immediate;
 exception when check_violation then denied:=true;
 end;
 perform pg_temp.sfa_assert(denied,'unpaired system advance under manual approval cannot commit');
end;$coverage$;

set constraints all deferred;
do $integration$
declare f jsonb;r jsonb;st jsonb;sid uuid;req jsonb;pump uuid;farm uuid;iv uuid;cmd uuid;before_count bigint;denied boolean;
begin
 f:=pg_temp.sfa_fixture();r:=pg_temp.sfa_adjust(f,8500);
 st:=api.get_session_detail((f->>'session')::uuid);
 perform pg_temp.sfa_assert(st->'session'->>'total_amount_minor'='8500' and st->'session'->>'system_amount_minor'='10000','detail exposes approved separately from system');
 st:=api.list_well_sessions((f->>'well')::uuid,null,null,null,false,200);
 perform pg_temp.sfa_assert(exists(select 1 from jsonb_array_elements(st->'items')i where i->>'id'=f->>'session' and i->>'total_amount_minor'='8500'),'history uses approved amount');
 select pump_id,farm_id into pump,farm from ops.irrigation_sessions where id=(f->>'session')::uuid;
 req:=jsonb_build_object('version',1,'pump_id',pump,'farm_id',farm,'farmer_well_account_id',f->>'account',
  'energy_source','solar','reason','historical session','notes','original note','started_at',(f->>'at')::timestamptz-interval '3 hours',
  'ended_at',(f->>'at')::timestamptz-interval '2 hours');
 r:=api.record_historical_session((f->>'well')::uuid,gen_random_uuid(),req);sid:=(r->>'session_id')::uuid;
 r:=pg_temp.sfa_adjust(f||jsonb_build_object('session',sid),3000);
 perform pg_temp.sfa_assert(r->>'status'='accepted' and (api.get_session_financial_state(sid)->>'system_amount_minor')='3600','historical manual entry uses canonical finance path');
 req:=req-'ended_at'||jsonb_build_object('started_at',clock_timestamp()-interval '1 hour');
 r:=api.adopt_external_session((f->>'well')::uuid,gen_random_uuid(),req);sid:=(r->>'session_id')::uuid;
 perform pg_temp.sfa_assert(api.get_session_financial_adjustment_capability(sid)->>'can_adjust'='false','active external cannot adjust before completion');
 perform api.complete_irrigation_session(sid,clock_timestamp()-interval '1 minute',null::bigint,null::text,null::uuid,gen_random_uuid());
 r:=pg_temp.sfa_adjust(f||jsonb_build_object('session',sid),3000);
 perform pg_temp.sfa_assert(r->>'status'='accepted','completed external uses same approval path');
 f:=pg_temp.sfa_fixture(10000,0,true);
 update finance.accounting_periods set status='closed' where well_id=(f->>'well')::uuid;
 r:=pg_temp.sfa_adjust(f,8500);
 perform pg_temp.sfa_assert(r->>'status'='financial_review_required' and not exists(select 1 from billing.session_financial_adjustments where session_id=(f->>'session')::uuid),'closed posting context leaves zero approval children');
 f:=pg_temp.sfa_fixture(10000,0,true);
 update billing.invoices set settlement_method='special_policy' where id=(f->>'invoice')::uuid;
 r:=pg_temp.sfa_adjust(f,8500);
 perform pg_temp.sfa_assert(r->>'status'='financial_review_required' and not exists(select 1 from billing.invoice_financial_adjustments where invoice_id=(f->>'invoice')::uuid),'abnormal invoice leaves no partial adjustment');
 f:=pg_temp.sfa_fixture();cmd:=gen_random_uuid();
 r:=pg_temp.sfa_adjust(f,8500,0,0,0,cmd);
 perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 r:=api.get_session_financial_adjustment_receipt((f->>'session')::uuid,cmd);
 perform pg_temp.sfa_assert(r->>'status'='permission_denied' and r->'result'='null'::jsonb
 and r->>'retry_authorized'='false','foreign actor gets typed denial without another session receipt');
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 r:=api.adjust_session_financial_amount((f->>'session')::uuid,gen_random_uuid(),0,0,1,8500,'  ',now());
 perform pg_temp.sfa_assert(r->>'status'='validation_error','blank reason rejected');
 r:=api.adjust_session_financial_amount((f->>'session')::uuid,gen_random_uuid(),0,0,1,8500,'reason','infinity'::timestamptz);
 perform pg_temp.sfa_assert(r->>'status'='validation_error','nonfinite requested time rejected');
 denied:=false;begin execute format('select api.adjust_session_financial_amount(%L::uuid,%L::uuid,0,0,1,%L::bigint,%L,now())',f->>'session',gen_random_uuid(),'1.5','reason');exception when invalid_text_representation then denied:=true;end;
 perform pg_temp.sfa_assert(denied,'fractional wire integer rejected');
 set constraints all immediate;
end;$integration$;

set constraints all deferred;
do $exact_postings$
declare f jsonb;r jsonb;iv uuid;j uuid;
begin
 f:=pg_temp.sfa_fixture();r:=pg_temp.sfa_adjust(f,8500);
 r:=api.issue_session_invoice_result((f->>'session')::uuid);iv:=(r->>'invoice_id')::uuid;
 select journal_entry_id into j from billing.invoices where id=iv;
 perform pg_temp.sfa_assert((select count(*)=3 from finance.journal_lines where journal_entry_id=j)
 and exists(select 1 from finance.journal_lines l where journal_entry_id=j and ledger_account_id=finance.ledger_account_id((f->>'well')::uuid,'1100') and entry_side='debit' and amount_minor=8500)
 and exists(select 1 from finance.journal_lines l where journal_entry_id=j and ledger_account_id=finance.ledger_account_id((f->>'well')::uuid,'4300') and entry_side='debit' and amount_minor=1500)
 and exists(select 1 from finance.journal_lines l where journal_entry_id=j and ledger_account_id=finance.ledger_account_id((f->>'well')::uuid,'4000') and entry_side='credit' and amount_minor=10000),'exact decrease8500 journal directions and magnitudes');
 f:=pg_temp.sfa_fixture();r:=pg_temp.sfa_adjust(f,12000);r:=api.issue_session_invoice_result((f->>'session')::uuid);iv:=(r->>'invoice_id')::uuid;
 select journal_entry_id into j from billing.invoices where id=iv;
 perform pg_temp.sfa_assert((select count(*)=3 from finance.journal_lines where journal_entry_id=j)
 and exists(select 1 from finance.journal_lines l where journal_entry_id=j and ledger_account_id=finance.ledger_account_id((f->>'well')::uuid,'1100') and entry_side='debit' and amount_minor=12000)
 and exists(select 1 from finance.journal_lines l where journal_entry_id=j and ledger_account_id=finance.ledger_account_id((f->>'well')::uuid,'4300') and entry_side='credit' and amount_minor=2000)
 and exists(select 1 from finance.journal_lines l where journal_entry_id=j and ledger_account_id=finance.ledger_account_id((f->>'well')::uuid,'4000') and entry_side='credit' and amount_minor=10000),'exact increase12000 journal directions and magnitudes');
 set constraints all immediate;
end;$exact_postings$;

set constraints all deferred;
do $money_bounds$
declare f jsonb;r jsonb;denied boolean:=false;begin
 f:=pg_temp.sfa_fixture();r:=pg_temp.sfa_adjust(f,9223372036854775807);
 perform pg_temp.sfa_assert(r->>'status'='accepted' and r->>'effective_amount_minor'='9223372036854775807','BIGINT approved bound retained exactly');
 begin execute format('select api.adjust_session_financial_amount(%L::uuid,%L::uuid,0,0,1,%L::bigint,%L,now())',f->>'session',gen_random_uuid(),'9223372036854775808','reason');exception when numeric_value_out_of_range then denied:=true;end;
 perform pg_temp.sfa_assert(denied,'overflow wire integer rejected without economic mutation');
 set constraints all immediate;
end;$money_bounds$;

set constraints all deferred;
do $payment_edges$
declare f jsonb;r jsonb;st jsonb;n bigint;begin
 f:=pg_temp.sfa_fixture(10000,10000,false);r:=pg_temp.sfa_adjust(f,8500);st:=pg_temp.sfa_state(f);
 perform pg_temp.sfa_assert(r->>'status'='accepted' and st->>'paid_amount_minor'='8500'
 and (select sum(available_minor)=1500 from billing.account_credit_balances where payment_id=(f->>'payment')::uuid)
 and not exists(select 1 from billing.invoices where session_id=(f->>'session')::uuid),'uninvoiced direct payment rebalances source-backed excess without invoice');
 f:=pg_temp.sfa_fixture(10000,0,true);select count(*) into n from finance.journal_entries where well_id=(f->>'well')::uuid;
 r:=pg_temp.sfa_adjust(f,10000);
 perform pg_temp.sfa_assert(r->>'status'='accepted' and r->>'delta_minor'='0'
 and n=(select count(*) from finance.journal_entries where well_id=(f->>'well')::uuid),'zero economic delta keeps history without fake journal');
 set constraints all immediate;
end;$payment_edges$;

set constraints all deferred;
do $currency_guard$
declare f jsonb;r jsonb;begin
 f:=pg_temp.sfa_fixture(10000,0,true);
 update billing.invoices set currency_code='USD' where id=(f->>'invoice')::uuid;
 r:=pg_temp.sfa_adjust(f,8500);
 perform pg_temp.sfa_assert(r->>'status'='financial_review_required'
 and not exists(select 1 from billing.invoice_financial_adjustments where invoice_id=(f->>'invoice')::uuid),'foreign invoice currency cannot be adjusted as canonical YER');
end;$currency_guard$;

set constraints all deferred;
do $capability_denial$
declare f jsonb;r jsonb;begin
 f:=pg_temp.sfa_fixture();
 update core.well_assignments set role='viewer' where well_id=(f->>'well')::uuid and profile_id=(f->>'actor')::uuid;
 execute 'set local role authenticated';
 r:=api.get_session_financial_adjustment_capability((f->>'session')::uuid);
 execute 'reset role';
 perform pg_temp.sfa_assert(r->>'can_adjust'='false' and r->>'reason_code'='permission_denied','valid capability denial is typed and exposes no financial authority');
 r:=pg_temp.sfa_adjust(f,8500);
 perform pg_temp.sfa_assert(r->>'status'='permission_denied' and not exists(select 1 from billing.session_financial_adjustments where session_id=(f->>'session')::uuid),'unauthorized write has typed outcome and no effect');
end;$capability_denial$;

set constraints all deferred;
do $legacy_zero$
declare f jsonb;r jsonb;begin
 f:=pg_temp.sfa_fixture();
 update ops.irrigation_sessions set status='forgotten' where id=(f->>'session')::uuid;
 r:=pg_temp.sfa_adjust(f,0);r:=api.issue_session_invoice_result((f->>'session')::uuid);
 perform pg_temp.sfa_assert(r->>'status'='not_required_zero_effective'
 and not exists(select 1 from billing.invoices where session_id=(f->>'session')::uuid),'completed legacy zero also needs no invoice');
end;$legacy_zero$;
\endif
set constraints all deferred;
\if :{?sfa_existing_only}
\elif :{?sfa_zero_list_only}
select pg_temp.sfa_zero_reads(false,false,'list');
\elif :{?sfa_zero_detail_only}
select pg_temp.sfa_zero_reads(false,false,'detail');
\elif :{?sfa_zero_only}
select pg_temp.sfa_zero_reads();
set constraints all deferred;
select pg_temp.sfa_zero_reads(true);
set constraints all deferred;
select pg_temp.sfa_zero_reads(false,true);
\elif :{?sfa_command_only}
select pg_temp.sfa_command_reads();
\else
select pg_temp.sfa_zero_reads();
set constraints all deferred;
select pg_temp.sfa_zero_reads(true);
set constraints all deferred;
select pg_temp.sfa_zero_reads(false,true);
set constraints all deferred;
select pg_temp.sfa_command_reads();
\endif
rollback;
