\set ON_ERROR_STOP on
-- Disposable local DB only; fixtures and deferred checks roll back.
begin;
set local timezone='UTC';
create function pg_temp.fq_check(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL %',label;end if;raise notice 'PASS %',label;end;$$;
select pg_temp.fq_check(to_regprocedure('billing.process_session_correction_reconciliation_message(bigint)') is not null,'private worker boundary exists');
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


-- Exercise the real technical role with an empty JWT; never impersonate actor.
create function pg_temp.fq_process(mid bigint) returns jsonb language plpgsql as $$
declare r jsonb;begin
 perform set_config('request.jwt.claim.sub','',true);
 execute 'set local role reconciliation_executor';
 perform billing.lease_session_correction_reconciliation_messages(100,60);
 r:=billing.process_session_correction_reconciliation_message(mid);
 execute 'reset role';return r;
exception when others then execute 'reset role';raise;end;$$;
create function pg_temp.fq_message(c uuid) returns bigint language sql as $$
 select msg_id from pgmq.q_session_correction_reconciliation where message=jsonb_build_object('correction_id',c) order by msg_id limit 1;
$$;

-- One private authority for interactive, trusted P2 and historical worker actors.
do $authority$
declare f jsonb;w uuid;a uuid;ctx uuid;role_name text;begin
 perform pg_temp.fq_check(to_regprocedure('iam.has_well_permission_for_actor(uuid,text,uuid)') is not null,
  'L canonical explicit-actor IAM authority exists');
 f:=pg_temp.sfa_fixture();w:=(f->>'well')::uuid;a:=(f->>'actor')::uuid;
 perform set_config('request.jwt.claim.sub',a::text,true);
 set local role authenticated;
 perform pg_temp.fq_check(iam.has_well_permission(w,'session.correct'),'L authenticated permission unchanged');
 reset role;
 perform pg_temp.fq_check(iam.has_well_permission_for_actor(w,'session.correct',a)
  and not iam.has_well_permission_for_actor(w,'session.correct',null)
  and not iam.has_well_permission_for_actor(gen_random_uuid(),'session.correct',a)
  and not iam.has_well_permission_for_actor(w,'missing.permission',a),'L explicit authority binds actor well and permission');
 foreach role_name in array array['anon','authenticated','service_role','reconciliation_executor','booking_automation_executor'] loop
  perform pg_temp.fq_check(not has_function_privilege(role_name,
   'iam.has_well_permission_for_actor(uuid,text,uuid)','EXECUTE'),'L '||role_name||' cannot select an actor');
  begin
   execute format('set local role %I',role_name);
   perform iam.has_well_permission_for_actor(w,'session.correct',a);
   raise exception 'explicit actor helper unexpectedly callable';
  exception when insufficient_privilege then reset role;end;
 end loop;
 -- A real transaction/backend-bound P2 context, not JWT impersonation.
 insert into ops.booking_automation_execution_contexts(transaction_id,backend_pid,tenant_id,well_id,
  chain_id,current_session_id,next_booking_id,decision_revision,automation_revision,policy_version,
  operator_profile_id,operator_assignment_id,authorization_revision,intent_fingerprint)
 values(txid_current(),pg_backend_pid(),(f->>'tenant')::uuid,w,gen_random_uuid(),(f->>'session')::uuid,
  gen_random_uuid(),1,1,1,a,(select id from core.well_assignments where well_id=w and profile_id=a),1,'{}')
 returning context_id into ctx;
 perform set_config('request.jwt.claim.sub','',true);
 perform set_config('well_irrigation.booking_automation_context',ctx::text,true);
 perform pg_temp.fq_check(ops.current_execution_operator()=a and iam.has_well_permission(w,'session.correct'),
  'L trusted P2 operator uses the same permission authority without JWT');
 update core.well_assignments set status='inactive' where well_id=w and profile_id=a;
 perform pg_temp.fq_check(not iam.has_well_permission(w,'session.correct')
  and not iam.has_well_permission_for_actor(w,'session.correct',a),'L revoked assignment denies both paths');
 update core.well_assignments set status='active' where well_id=w and profile_id=a;
 update ops.booking_automation_execution_contexts set backend_pid=pg_backend_pid()+1 where context_id=ctx;
 perform pg_temp.fq_check(ops.current_execution_operator() is null and not iam.has_well_permission(w,'session.correct'),
  'L unbound P2 context cannot supply an actor');
 perform set_config('well_irrigation.booking_automation_context','',true);
 perform set_config('request.jwt.claim.sub',a::text,true);
 -- A scoped test fault proves the existing helper delegates rather than retaining
 -- an independent set of permission joins. Subtransaction restores the function.
 begin
  create or replace function iam.has_well_permission_for_actor(p_well_id uuid,p_permission_code text,p_actor_id uuid)
   returns boolean language sql stable security definer set search_path=pg_catalog,pg_temp as $probe$ select false $probe$;
  perform pg_temp.fq_check(not iam.has_well_permission(w,'session.correct')
   and not billing.reconciliation_actor_authorized(w,a),'L interactive and worker gates delegate to canonical IAM');
  raise exception 'restore authority probe' using errcode='P0T01';
 exception when sqlstate 'P0T01' then null;end;
 perform pg_temp.fq_check(iam.has_well_permission(w,'session.correct'),'L real IAM authority restored after probe');
end;$authority$;

-- Fault probes exercise forwarding of every argument through the four original
-- signatures. Original cores are restored by rollback of this subtransaction.
do $wrappers$
declare a uuid:=gen_random_uuid();u uuid:=gen_random_uuid();v uuid:=gen_random_uuid();
 t timestamptz:=transaction_timestamp();details text;prior_sub text:=current_setting('request.jwt.claim.sub',true);begin
 perform set_config('request.jwt.claim.sub',a::text,true);
 begin
create or replace function billing.reconcile_session_correction_core(p_actor_id uuid,p_correction uuid,p_command_id uuid,p_posted_at timestamptz)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $probe$
begin raise exception 'core forwarding probe' using errcode='P0T02',
 detail=jsonb_build_array(p_actor_id,p_correction,p_command_id,p_posted_at)::text;end;$probe$;
  begin
   perform billing.reconcile_session_correction(u,v,t);
   raise exception 'wrapper bypassed core';
  exception when sqlstate 'P0T02' then
   get stacked diagnostics details=PG_EXCEPTION_DETAIL;
   perform pg_temp.fq_check(details::jsonb=jsonb_build_array(a,u,v,t),
    'M reconcile_session_correction forwards interactive actor and every argument to its only core');
  end;
create or replace function billing.post_session_correction_delta_core(p_actor_id uuid,p_correction uuid,p_invoice uuid,p_evidence jsonb,p_previous jsonb,
 p_posted_at timestamptz) returns uuid language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $probe$
begin raise exception 'core forwarding probe' using errcode='P0T02',
 detail=jsonb_build_array(p_actor_id,p_correction,p_invoice,p_evidence,p_previous,p_posted_at)::text;end;$probe$;
  begin
   perform billing.post_session_correction_delta(u,v,'{}'::jsonb,'[]'::jsonb,t);
   raise exception 'wrapper bypassed core';
  exception when sqlstate 'P0T02' then
   get stacked diagnostics details=PG_EXCEPTION_DETAIL;
   perform pg_temp.fq_check(details::jsonb=jsonb_build_array(a,u,v,'{}'::jsonb,'[]'::jsonb,t),
    'M post_session_correction_delta forwards interactive actor and every argument to its only core');
  end;
create or replace function billing.adjust_credit_application_core(p_actor_id uuid,p_application uuid,p_operation text,p_amount bigint,
 p_source uuid,p_revision bigint,p_reason text,p_posted_at timestamptz,p_origin_id uuid default null) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $probe$
begin raise exception 'core forwarding probe' using errcode='P0T02',
 detail=jsonb_build_array(p_actor_id,p_application,p_operation,p_amount,p_source,p_revision,p_reason,p_posted_at,p_origin_id)::text;end;$probe$;
  begin
   perform billing.adjust_credit_application(u,'release',7,v,2,'reason',t,u);
   raise exception 'wrapper bypassed core';
  exception when sqlstate 'P0T02' then
   get stacked diagnostics details=PG_EXCEPTION_DETAIL;
   perform pg_temp.fq_check(details::jsonb=jsonb_build_array(a,u,'release',7,v,2,'reason',t,u),
    'M adjust_credit_application forwards interactive actor and every argument to its only core');
  end;
create or replace function billing.repartition_payment_internal_core(p_actor_id uuid,p_payment uuid,p_allocation uuid,p_credit uuid,p_amount bigint,
 p_mode text,p_source uuid,p_revision bigint,p_reason text,p_posted_at timestamptz,p_origin uuid default null,p_parent uuid default null)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $probe$
begin raise exception 'core forwarding probe' using errcode='P0T02',
 detail=jsonb_build_array(p_actor_id,p_payment,p_allocation,p_credit,p_amount,p_mode,p_source,p_revision,p_reason,p_posted_at,p_origin,p_parent)::text;end;$probe$;
  begin
   perform billing.repartition_payment_internal(u,v,u,7,'restore',v,2,'reason',t,u,v);
   raise exception 'wrapper bypassed core';
  exception when sqlstate 'P0T02' then
   get stacked diagnostics details=PG_EXCEPTION_DETAIL;
   perform pg_temp.fq_check(details::jsonb=jsonb_build_array(a,u,v,u,7,'restore',v,2,'reason',t,u,v),
    'M repartition_payment_internal forwards interactive actor and every argument to its only core');
  end;
  raise exception 'restore financial probes' using errcode='P0T01';
 exception when sqlstate 'P0T01' then null;end;
 perform set_config('request.jwt.claim.sub',coalesce(prior_sub,''),true);
end;$wrappers$;

do $tests$
declare f jsonb;c uuid;d uuid;mid bigint;r jsonb;x jsonb;before_count bigint;role_name text;fn record;
 cmd uuid;before_journals bigint;before_periods jsonb;before_attempt bigint;bad jsonb;other uuid:=gen_random_uuid();
begin
 perform pg_temp.fq_check((select not is_unlogged and not is_partitioned from pgmq.list_queues()
  where queue_name='session_correction_reconciliation') and
  (select bool_and(relpersistence='p') from pg_class where oid in
   ('pgmq.q_session_correction_reconciliation'::regclass,'pgmq.a_session_correction_reconciliation'::regclass)),
  'A durable logged Basic queue');
 -- pgmq.create is idempotent in supported 1.5; characterize repeat create/list.
 perform pgmq.create('session_correction_reconciliation');
 perform pg_temp.fq_check((select count(*)=1 from pgmq.list_queues() where queue_name='session_correction_reconciliation'),
  'A repeated create retains exactly one queue');
 f:=pg_temp.sfa_fixture(10000,10000,true);
 c:=pg_temp.sfa_correct(f,0,8000);mid:=pg_temp.fq_message(c);
 perform pg_temp.fq_check((select count(*)=1 and bool_and(message=jsonb_build_object('correction_id',c))
  from pgmq.q_session_correction_reconciliation where message->>'correction_id'=c::text),
  'A work insert enqueues exactly one correction-only payload');
 begin
  d:=pg_temp.sfa_correct(f,1,7500);
  perform pg_temp.fq_check(pg_temp.fq_message(d) is not null,'A enqueue visible inside accepting transaction');
  raise exception 'fixture_rollback' using errcode='P0T01';
 exception when sqlstate 'P0T01' then null;end;
 perform pg_temp.fq_check(not exists(select 1 from ops.session_correction_reconciliations where correction_id=d)
  and pg_temp.fq_message(d) is null,'A rollback removes work and queue message');
 cmd:=md5('session-correction-auto-reconcile:v1:'||c::text)::uuid;
 r:=pg_temp.fq_process(mid);
 perform pg_temp.fq_check(r->>'status'='applied' and (select amount_minor=8000 from billing.approved_session_charges
  where session_id=(f->>'session')::uuid),'B worker applies canonical amount with no JWT');
 perform pg_temp.fq_check(not exists(select 1 from pgmq.q_session_correction_reconciliation where msg_id=mid)
  and exists(select 1 from pgmq.a_session_correction_reconciliation where msg_id=mid),'B applied message archived');
 perform pg_temp.fq_check(exists(select 1 from sync.processed_commands where command_id=cmd and status='accepted'
  and request_payload->>'actor_id'=f->>'actor') and exists(select 1 from finance.journal_entries
  where source_type='session_correction' and source_id=c and posted_by=(f->>'actor')::uuid and status='posted'),
  'B deterministic command and journal retain original human actor');
 perform pg_temp.fq_check(current_setting('request.jwt.claim.sub',true)='' and
  (select posted_at::date=current_date from billing.session_charge_corrections where correction_id=c),
  'B server current posting context without auth impersonation');
 select count(*) into before_journals from finance.journal_entries;
 mid:=pgmq.send('session_correction_reconciliation',jsonb_build_object('correction_id',c));
 r:=pg_temp.fq_process(mid);x:=pg_temp.fq_process(mid);
 perform pg_temp.fq_check(r->>'status'='applied' and r->>'already_completed'='true'
  and x->>'status'='already_completed' and
  (select count(*)=1 from billing.session_charge_corrections where correction_id=c)
  and (select count(*)=1 from sync.processed_commands where command_id=cmd)
  and (select count(*)=before_journals from finance.journal_entries),'C duplicate/redelivery no second economic effect');

 f:=pg_temp.sfa_fixture(10000,0,true);
 r:=pg_temp.sfa_adjust(f,8500);
 perform pg_temp.fq_check(r->>'status'='accepted','D original manual approval accepted');
 c:=pg_temp.sfa_correct(f,0,8000);mid:=pg_temp.fq_message(c);r:=pg_temp.fq_process(mid);
 perform pg_temp.fq_check(r->>'status'='financial_review_required' and r->>'review_code'='manual_approval_reconciliation_required'
  and (select amount_minor=8500 from billing.approved_session_charges where session_id=(f->>'session')::uuid)
  and not exists(select 1 from billing.session_charge_corrections where correction_id=c)
  and exists(select 1 from pgmq.a_session_correction_reconciliation where msg_id=mid),
  'D automatic review archives without overwriting manual approval');
 cmd:=gen_random_uuid();r:=pg_temp.sfa_adjust(f,9000,1,0,1,cmd);
 perform pg_temp.fq_check(r->>'status'='accepted' and
  (select amount_minor=9000 from billing.approved_session_charges where session_id=(f->>'session')::uuid)
  and exists(select 1 from billing.session_financial_resolution_links where correction_id=c)
  and (select status='applied' from ops.session_correction_reconciliations where correction_id=c),
  'E later explicit manual approval pairs and closes system basis');
 r:=pg_temp.sfa_adjust(f,9000,1,0,1,cmd);
 mid:=pgmq.send('session_correction_reconciliation',jsonb_build_object('correction_id',c));x:=pg_temp.fq_process(mid);
 perform pg_temp.fq_check(r->>'status'='accepted' and x->>'status'='applied' and
  (select count(*)=1 from billing.session_charge_corrections where correction_id=c)
  and (select count(*)=2 from billing.session_financial_adjustments where session_id=(f->>'session')::uuid),
  'E pairing replay and queue redelivery create no duplicate');

 -- Both removal of assignment activity and removal of session.correct fail closed.
 foreach role_name in array array['inactive','viewer'] loop
  f:=pg_temp.sfa_fixture(10000,0,true);c:=pg_temp.sfa_correct(f,0,8000);mid:=pg_temp.fq_message(c);
  if role_name='inactive' then
   update core.well_assignments set status='inactive' where well_id=(f->>'well')::uuid;
  else update core.well_assignments set role='viewer' where well_id=(f->>'well')::uuid;end if;
  select count(*) into before_journals from finance.journal_entries;
  r:=pg_temp.fq_process(mid);
  perform pg_temp.fq_check(r->>'status'='financial_review_required' and r->>'review_code'='actor_authorization_changed'
   and (select last_error='actor_authorization_changed' from ops.session_correction_reconciliations where correction_id=c)
   and not exists(select 1 from billing.session_charge_corrections where correction_id=c)
   and (select count(*)=before_journals from finance.journal_entries)
   and exists(select 1 from pgmq.a_session_correction_reconciliation where msg_id=mid),'F revoked actor '||role_name||' terminal review no financial effect');
 end loop;

 f:=pg_temp.sfa_fixture();c:=pg_temp.sfa_correct(f,0,8000);mid:=pg_temp.fq_message(c);
 -- Closing through the supported financial boundary; never bypass period guards.
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 update core.well_assignments set role='owner' where well_id=(f->>'well')::uuid;
 perform finance.close_period((select id from finance.accounting_periods where well_id=(f->>'well')::uuid
  and period_type='monthly' and current_date between starts_at and ends_at),(f->>'actor')::uuid);
 select jsonb_agg(to_jsonb(ap) order by id) into before_periods from finance.accounting_periods ap where well_id=(f->>'well')::uuid;
 r:=pg_temp.fq_process(mid);
 perform pg_temp.fq_check(r->>'status'='financial_review_required' and r->>'review_code'='posting_context_unavailable'
  and before_periods=(select jsonb_agg(to_jsonb(ap) order by id) from finance.accounting_periods ap where well_id=(f->>'well')::uuid)
  and not exists(select 1 from billing.session_charge_corrections where correction_id=c)
  and exists(select 1 from pgmq.a_session_correction_reconciliation where msg_id=mid),'G closed context review no implicit reopen');

 f:=pg_temp.sfa_fixture();c:=pg_temp.sfa_correct(f,0,9000);d:=pg_temp.sfa_correct(f,1,8000);
 mid:=pg_temp.fq_message(d);r:=pg_temp.fq_process(mid);
 perform pg_temp.fq_check(r->>'status'='pending' and r->>'reason'='predecessor_not_applied' and r->>'attempt_started'='false'
  and (select status='pending' and attempt_count=0 from ops.session_correction_reconciliations where correction_id=d)
  and exists(select 1 from pgmq.q_session_correction_reconciliation where msg_id=mid)
  and not exists(select 1 from pgmq.a_session_correction_reconciliation where msg_id=mid),
  'H successor waits without archive or attempt');
 -- Simulate VT expiry with the real PGMQ visibility API, without sleeping.
 perform pgmq.set_vt('session_correction_reconciliation',mid,0);
 execute 'set local role reconciliation_executor';
 r:=billing.process_session_correction_reconciliation_message(mid);
 execute 'reset role';
 perform pg_temp.fq_check(r->>'reason'='lease_required' and
  exists(select 1 from pgmq.q_session_correction_reconciliation where msg_id=mid),'H expired lease cannot process');
 r:=pg_temp.fq_process(mid);
 perform pg_temp.fq_check(r->>'reason'='predecessor_not_applied' and
  (select read_ct=2 from pgmq.q_session_correction_reconciliation where msg_id=mid),
  'H visibility expiry permits redelivery while predecessor remains pending');
 r:=pg_temp.fq_process(pg_temp.fq_message(c));x:=pg_temp.fq_process(mid);
 perform pg_temp.fq_check(r->>'status'='applied' and x->>'status'='applied' and
  (select count(*)=2 and count(distinct operational_revision)=2 from billing.session_charge_corrections
   where session_id=(f->>'session')::uuid),'H DB predecessor invariant permits successor after predecessor');

 foreach role_name in array array['anon','authenticated','service_role'] loop
  for fn in select p.oid,p.proname from pg_proc p where p.pronamespace='billing'::regnamespace and
   (p.proname in ('reconciliation_actor_authorized','enqueue_session_correction_reconciliation',
    'lease_session_correction_reconciliation_messages','process_session_correction_reconciliation_message')
    or p.proname in ('reconcile_session_correction_core','post_session_correction_delta_core',
     'adjust_credit_application_core','repartition_payment_internal_core')) loop
   perform pg_temp.fq_check(not has_function_privilege(role_name,fn.oid,'EXECUTE'),'I '||role_name||' denied '||fn.proname);
  end loop;
  perform pg_temp.fq_check(not has_schema_privilege(role_name,'pgmq','USAGE') and not exists(
   select 1 from pg_proc p where p.pronamespace='pgmq'::regnamespace and has_function_privilege(role_name,p.oid,'EXECUTE')),
   'I '||role_name||' denied all private queue functions');
 end loop;
 perform pg_temp.fq_check(not exists(select 1 from pg_auth_members where member='reconciliation_executor'::regrole)
  and (select not rolcanlogin and not rolinherit and not rolbypassrls and not rolsuper from pg_roles where rolname='reconciliation_executor')
  and not has_function_privilege('reconciliation_executor','billing.reconcile_session_correction_core(uuid,uuid,uuid,timestamptz)','EXECUTE')
  and not has_function_privilege('reconciliation_executor','billing.establish_paired_system_basis(uuid,uuid,timestamptz)','EXECUTE'),
  'I executor isolated NOLOGIN without general financial authority');

 f:=pg_temp.sfa_fixture();c:=pg_temp.sfa_correct(f,0,8000);
 select count(*) into before_count from billing.session_charge_corrections;
 foreach bad in array array['null'::jsonb,'[]'::jsonb,'{}'::jsonb,jsonb_build_object('correction_id',null),
  jsonb_build_object('correction_id','bad'),jsonb_build_object('correction_id',c,'actor_id',other),
  jsonb_build_object('correction_id',other)] loop
  mid:=pgmq.send('session_correction_reconciliation',bad);r:=pg_temp.fq_process(mid);
  perform pg_temp.fq_check(r->>'status'='invalid_message' and
   exists(select 1 from pgmq.a_session_correction_reconciliation where msg_id=mid),
   'J malformed/unknown payload terminally quarantined');
 end loop;
 perform pg_temp.fq_check((select count(*)=before_count from billing.session_charge_corrections)
  and (select status='pending' from ops.session_correction_reconciliations where correction_id=c),
  'J malformed messages cannot select actor or publish money');
end;$tests$;

-- A crash after financial processing but before archive must roll back both.
create function pg_temp.fq_fail_archive() returns trigger language plpgsql as $$
begin raise exception 'archive_infrastructure_failure' using errcode='58000';end;$$;
do $atomic$
declare f jsonb;c uuid;mid bigint;r jsonb;n bigint;begin
 f:=pg_temp.sfa_fixture(10000,10000,true);c:=pg_temp.sfa_correct(f,0,8000);mid:=pg_temp.fq_message(c);
 select count(*) into n from finance.journal_entries;
 -- Test-only fault at the real archive boundary, after the core financial write.
 create trigger fq_archive_failure before insert on pgmq.a_session_correction_reconciliation
  for each row execute function pg_temp.fq_fail_archive();
 begin
  r:=pg_temp.fq_process(mid);
  raise exception 'archive failure did not propagate';
 exception when sqlstate '58000' then null;end;
 drop trigger fq_archive_failure on pgmq.a_session_correction_reconciliation;
 perform pg_temp.fq_check((select status='pending' and attempt_count=0 from ops.session_correction_reconciliations where correction_id=c)
  and exists(select 1 from pgmq.q_session_correction_reconciliation where msg_id=mid)
  and not exists(select 1 from billing.session_charge_corrections where correction_id=c)
  and (select count(*)=n from finance.journal_entries),'K archive failure rolls back money work command and archive');
 r:=pg_temp.fq_process(mid);
 perform pg_temp.fq_check(r->>'status'='applied','K redelivery after rollback applies once');
end;$atomic$;
set constraints all immediate;
rollback;
