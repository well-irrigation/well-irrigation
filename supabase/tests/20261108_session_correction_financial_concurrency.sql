\set ON_ERROR_STOP on
-- OWNER ONLY: standalone disposable LOCAL database; final owner RESET required.
-- Fixtures COMMIT for two real Unix-socket sessions. Never run in production.
set session characteristics as transaction isolation level read committed;
do $$begin
 if current_setting('r6c2_session_financial.disposable_database',true) is distinct from 'yes'
  or not (select rolsuper from pg_roles where rolname=current_user)
  or current_setting('transaction_isolation')<>'read committed' then
  raise exception 'SESSION_FINANCIAL_OWNER_DISPOSABLE_LOCAL_REQUIRED';end if;
end;$$;
begin;
set local timezone='UTC';
create extension if not exists dblink with schema extensions;
-- A repeat run requires RESET, not reuse of previous committed probe evidence.
create schema session_financial_probe;
revoke all on schema session_financial_probe from public,anon,authenticated,service_role;
create function session_financial_probe.check_result(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL %',label;end if;raise notice 'PASS %',label;end;$$;
-- Same real manual fixture as the verified C2 targeted test; no dependency on it.
create function session_financial_probe.fixture(seconds bigint default 10000,paid bigint default 0,invoiced boolean default false,
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

create function session_financial_probe.correct(f jsonb,cmd uuid,base bigint,seconds bigint,
 shift_start interval default interval '0') returns uuid language plpgsql as $$
declare r jsonb;
begin
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 r:=ops.accept_session_correction((f->>'session')::uuid,cmd,base,'  financial concurrency reason  ',
  (f->>'at')::timestamptz+shift_start,(f->>'at')::timestamptz+seconds*interval '1 second',(f->>'posting')::timestamptz);
 return (r->>'correction_id')::uuid;
end;$$;
create function session_financial_probe.seed_credit() returns jsonb language plpgsql as $$
declare f jsonb;c uuid;r jsonb;i uuid;credit uuid;
begin
 f:=session_financial_probe.fixture(10000,10000,false);
 c:=session_financial_probe.correct(f,gen_random_uuid(),0,8000);
 r:=billing.reconcile_session_correction(c,gen_random_uuid(),(f->>'posting')::timestamptz);
 perform session_financial_probe.check_result(r->>'status'='applied','fixture credit derived through production C2/C0.2');
 i:=billing.issue_session_invoice((f->>'session')::uuid,(f->>'actor')::uuid);
 select id into strict credit from billing.account_credits where payment_id=(f->>'payment')::uuid;
 return f||jsonb_build_object('invoice',i,'credit',credit);
end;$$;
create function session_financial_probe.other_invoice(f jsonb) returns uuid language plpgsql as $$
declare i uuid;
begin
 -- A separate genuine test debt, not a replacement for the corrected session.
 insert into billing.invoices(tenant_id,well_id,public_code,farmer_well_account_id,invoice_date,status,
  subtotal_minor,total_minor,paid_minor,outstanding_minor)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,core.generate_public_code('INV'),(f->>'account')::uuid,
  (f->>'posting')::timestamptz,'draft',2000,2000,0,2000) returning id into i;
 update billing.invoices set status='issued' where id=i;return i;
end;$$;
create function session_financial_probe.approved_history(f jsonb) returns void language plpgsql as $$
declare person uuid;partner uuid;cycle uuid;original_role text;
begin
 -- Real existing distribution calculation/approval over a zero-collection
 -- historical interval, so approved protection is non-vacuous. No C3 effects.
 select fp.person_id into strict person from ops.farmer_profiles fp join ops.farmer_well_accounts a
  on a.farmer_profile_id=fp.id where a.id=(f->>'account')::uuid;
 insert into core.well_partners(tenant_id,well_id,person_id,phone,period_start)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,person,'777777777',date '1970-01-01') returning id into partner;
 insert into core.ownership_share_versions(tenant_id,well_id,partner_id,ownership_percentage,profit_percentage,effective_period)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,partner,100,100,daterange(date '1970-01-01',null,'[)'));
 select role into strict original_role from core.well_assignments where well_id=(f->>'well')::uuid and profile_id=(f->>'actor')::uuid;
 update core.well_assignments set role='owner' where well_id=(f->>'well')::uuid and profile_id=(f->>'actor')::uuid;
 perform set_config('request.jwt.claim.sub',f->>'actor',true);
 cycle:=finance.calculate_profit_distribution((f->>'well')::uuid,(f->>'at')::timestamptz-interval '100 days',
  (f->>'at')::timestamptz-interval '90 days',(f->>'actor')::uuid,0);
 perform finance.approve_profit_distribution(cycle,(f->>'actor')::uuid);
 update core.well_assignments set role=original_role where well_id=(f->>'well')::uuid and profile_id=(f->>'actor')::uuid;
end;$$;

create table session_financial_probe.fixtures (
 case_id integer primary key,f jsonb not null,correction_a uuid not null,correction_b uuid,
 command_a uuid not null,command_b uuid not null,source_b uuid not null,
 target_revision bigint not null,expected_amount bigint not null,expected_children integer not null,
 period_id uuid
);
do $setup$
declare n integer;f jsonb;ca uuid;cb uuid;cmd_a uuid;cmd_b uuid;source_b uuid;revision bigint;amount bigint;
 child_count integer;i uuid;r jsonb;app uuid;period uuid;
begin
 for n in 1..10 loop
  cb:=null;period:=null;revision:=1;amount:=8000;cmd_a:=gen_random_uuid();cmd_b:=gen_random_uuid();source_b:=gen_random_uuid();
  if n in (1,4) then f:=session_financial_probe.seed_credit();
  else f:=session_financial_probe.fixture(10000,case when n in (6,7) then 0 else 10000 end,
    n not in (5,9),false,n=5);end if;
  if n=1 then
   ca:=session_financial_probe.correct(f,gen_random_uuid(),1,10000);
   r:=billing.reconcile_session_correction(ca,gen_random_uuid(),(f->>'posting')::timestamptz);
   perform session_financial_probe.check_result(r->>'status'='applied','fixture financial revision two');
   r:=billing.apply_account_credit((f->>'credit')::uuid,(f->>'invoice')::uuid,2000,gen_random_uuid(),1,
    'fixture explicit credit application',(f->>'posting')::timestamptz);
   app:=(r->>'application_id')::uuid;f:=f||jsonb_build_object('application',app);
   revision:=3;amount:=1000;child_count:=2;
   ca:=session_financial_probe.correct(f,gen_random_uuid(),2,1000);cmd_b:=cmd_a;
  elsif n=4 then
   i:=session_financial_probe.other_invoice(f);f:=f||jsonb_build_object('recipient_invoice',i);
   revision:=2;amount:=10000;child_count:=0;
   ca:=session_financial_probe.correct(f,gen_random_uuid(),1,10000);
  elsif n=6 then
   ca:=session_financial_probe.correct(f,gen_random_uuid(),0,8000,interval '1 second');
   cb:=session_financial_probe.correct(f,gen_random_uuid(),1,9000,interval '1 second');child_count:=0;
  else
   ca:=session_financial_probe.correct(f,gen_random_uuid(),0,8000);
   child_count:=case when n in (5,9) then 1 when n=7 then 0 else 2 end;
   if n=2 then cmd_b:=cmd_a;end if;
  end if;
  if n=5 then source_b:=md5(ca::text||':rebalance:'||(f->>'payment'))::uuid;end if;
  if n in (8,10) then
   update core.well_assignments set role='owner' where well_id=(f->>'well')::uuid and profile_id=(f->>'actor')::uuid;
   select id into strict period from finance.accounting_periods where well_id=(f->>'well')::uuid
    and period_type='monthly' and (f->>'posting')::timestamptz::date between starts_at and ends_at;
  end if;
  f:=f||jsonb_build_object('reason','  financial concurrency reason  ');
  perform session_financial_probe.approved_history(f);
  insert into session_financial_probe.fixtures values(n,f,ca,cb,cmd_a,cmd_b,source_b,revision,amount,child_count,period);
 end loop;
end;$setup$;

-- Freeze existing evidence by identity; later legitimate child rows are allowed.
-- Invoice paid/outstanding/status/cache and C1 operational_revision are derived.
create table session_financial_probe.frozen_relations(
 schema_name text,table_name text,key_name text,strip_keys text[] not null default '{}',primary key(schema_name,table_name));
insert into session_financial_probe.frozen_relations(schema_name,table_name,key_name,strip_keys) values
 ('ops','irrigation_sessions','id',array['operational_revision']),
 ('ops','session_segments','id','{}'),('ops','session_corrections','id','{}'),
 ('billing','session_charges','id','{}'),
 ('billing','invoices','id',array['paid_minor','outstanding_minor','status','correction_total_delta_minor']),
 ('billing','invoice_lines','id','{}'),('billing','payments','id','{}'),('billing','payment_allocations','id','{}'),
 ('billing','account_credits','id','{}'),('billing','account_credit_applications','id','{}'),
 ('billing','customer_credit_events','id','{}'),('billing','payment_allocation_adjustments','id','{}'),
 ('billing','account_credit_application_adjustments','id','{}'),('billing','account_credit_reversals','id','{}'),
 ('billing','session_charge_corrections','correction_id','{}'),('billing','invoice_corrections','correction_id','{}'),
 ('finance','journal_entries','id','{}'),('finance','journal_lines','id','{}'),
 ('finance','profit_distribution_cycles','id','{}'),('finance','profit_distribution_lines','id','{}'),
 ('inventory','fuel_transactions','id','{}'),('sync','processed_commands','id','{}');
create table session_financial_probe.frozen_rows(schema_name text,table_name text,row_id uuid,payload jsonb,
 primary key(schema_name,table_name,row_id));
do $$declare x record;begin
 for x in select * from session_financial_probe.frozen_relations loop
  execute format('insert into session_financial_probe.frozen_rows select %L,%L,t.%I,to_jsonb(t)-$1 from %I.%I t',
   x.schema_name,x.table_name,x.key_name,x.schema_name,x.table_name) using x.strip_keys;
 end loop;
end;$$;
create function session_financial_probe.assert_frozen() returns void language plpgsql as $$
declare x record;violations bigint;
begin
 for x in select * from session_financial_probe.frozen_relations loop
  execute format('select count(*) from session_financial_probe.frozen_rows f left join %I.%I t on t.%I=f.row_id
   where f.schema_name=%L and f.table_name=%L and (to_jsonb(t)-$1) is distinct from f.payload',
   x.schema_name,x.table_name,x.key_name,x.schema_name,x.table_name) into violations using x.strip_keys;
  perform session_financial_probe.check_result(violations=0,'immutable original evidence '||x.schema_name||'.'||x.table_name);
 end loop;
end;$$;
create function session_financial_probe.financial_state(include_work boolean default false) returns jsonb language plpgsql as $$
declare x record;v text;r jsonb:='{}';
begin
 for x in select n.nspname,c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where c.relkind in ('r','p') and (n.nspname in ('billing','finance','inventory')
   or(include_work and ((n.nspname='ops' and c.relname='session_correction_reconciliations')
    or(n.nspname='sync' and c.relname='processed_commands')))) order by 1,2 loop
  execute format('select md5(coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text)::text,''null'')) from %I.%I t',
   x.nspname,x.relname) into v;r:=r||jsonb_build_object(x.nspname||'.'||x.relname,v);
 end loop;return r;
end;$$;

create table session_financial_probe.post_observations(journal_id uuid primary key,backend_pid integer,period_status text);
create table session_financial_probe.close_observations(period_id uuid primary key,backend_pid integer,
 work_status text,committed_postings bigint);
create function session_financial_probe.post_observer() returns trigger language plpgsql
 security definer set search_path = pg_catalog, pg_temp as $$
declare period uuid;st text;
begin
 select x.period_id into period from session_financial_probe.fixtures x where x.case_id=8 and x.f->>'well'=new.well_id::text;
 if found and new.status='posted' and old.status is distinct from new.status then
  select status into strict st from finance.accounting_periods where id=period;
  insert into session_financial_probe.post_observations values(new.id,pg_backend_pid(),st);
 end if;return new;
end;$$;
create trigger session_financial_post_observer after update of status on finance.journal_entries
 for each row execute function session_financial_probe.post_observer();
create function session_financial_probe.close_observer() returns trigger language plpgsql
 security definer set search_path = pg_catalog, pg_temp as $$
declare correction uuid;st text;n bigint;
begin
 select x.correction_a into correction from session_financial_probe.fixtures x where x.case_id=8 and x.period_id=new.id;
 if found and new.status='closed' and old.status is distinct from new.status then
  select status into strict st from ops.session_correction_reconciliations where correction_id=correction;
  select count(*) into n from session_financial_probe.post_observations;
  -- READ COMMITTED visibility here proves A's postings/work committed before
  -- B changed the period. A closed period after the race is therefore valid.
  insert into session_financial_probe.close_observations values(new.id,pg_backend_pid(),st,n);
 end if;return new;
end;$$;
create trigger session_financial_close_observer after update of status on finance.accounting_periods
 for each row execute function session_financial_probe.close_observer();
-- CASE 8B gate is inside the real close function's UPDATE, after its canonical
-- financial lock and explicit period lock, BEFORE audit/FK evaluation.
create function session_financial_probe.close_first_barrier() returns trigger language plpgsql as $$
begin
 if new.status='closed' and old.status is distinct from new.status and exists(
  select 1 from session_financial_probe.fixtures where case_id=10 and period_id=new.id) then
  perform pg_advisory_xact_lock(746208,10);
 end if;
 return new;
end;$$;
create trigger session_financial_close_first_barrier before update of status on finance.accounting_periods
 for each row execute function session_financial_probe.close_first_barrier();
create function session_financial_probe.charge_barrier() returns trigger language plpgsql as $$
declare gate integer;
begin
 select case_id into gate from session_financial_probe.fixtures where correction_a=new.correction_id and case_id<>6;
 if found then perform pg_advisory_xact_lock(746208,gate);end if;return new;
end;$$;
create trigger session_financial_charge_barrier after insert on billing.session_charge_corrections
 for each row execute function session_financial_probe.charge_barrier();
create function session_financial_probe.work_barrier() returns trigger language plpgsql as $$
begin
 if exists(select 1 from session_financial_probe.fixtures where case_id=6 and correction_a=new.correction_id) then
  perform pg_advisory_xact_lock(746208,6);end if;return new;
end;$$;
create trigger session_financial_work_barrier after update on ops.session_correction_reconciliations
 for each row when(new.attempt_count>old.attempt_count) execute function session_financial_probe.work_barrier();

create function session_financial_probe.attempt(case_number integer,kind text) returns jsonb language plpgsql as $$
declare x session_financial_probe.fixtures%rowtype;r jsonb;sid uuid;posting timestamptz;
begin
 if current_setting('transaction_isolation')<>'read committed' then raise exception 'RACE_REQUIRES_READ_COMMITTED';end if;
 select * into strict x from session_financial_probe.fixtures where case_id=case_number;
 perform set_config('request.jwt.claim.sub',x.f->>'actor',true);posting:=(x.f->>'posting')::timestamptz;
 begin
  if kind='reconcile_a' then r:=billing.reconcile_session_correction(x.correction_a,x.command_a,posting);
  elsif kind='reconcile_b' then
   r:=billing.reconcile_session_correction(coalesce(x.correction_b,x.correction_a),x.command_b,
    posting+case when case_number=2 then interval '1 minute' else interval '0' end);
  elsif kind='release' then
   r:=billing.release_payment_allocation((select id from billing.payment_allocations where invoice_id=(x.f->>'invoice')::uuid),
    9000,x.source_b,1,'competing explicit release',posting,x.source_b);
  elsif kind='spend' then
   r:=billing.apply_account_credit((x.f->>'credit')::uuid,(x.f->>'recipient_invoice')::uuid,2000,x.source_b,1,'competing credit spend',posting);
  elsif kind='rebalance' then
   -- Exactly the child source/request that A will have committed after waiting.
   r:=billing.rebalance_payment_capacity((x.f->>'payment')::uuid,x.source_b,x.target_revision,x.f->>'reason',posting,x.correction_a);
  elsif kind='operational' then
   sid:=session_financial_probe.correct(x.f,x.command_b,1,9000);
   r:=jsonb_build_object('status','accepted','correction_id',sid);
  elsif kind='close' then
   perform finance.close_period(x.period_id,(x.f->>'actor')::uuid);r:=jsonb_build_object('status','closed');
  elsif kind='invoice' then
   sid:=billing.issue_session_invoice((x.f->>'session')::uuid,(x.f->>'actor')::uuid);
   r:=jsonb_build_object('status','issued','invoice_id',sid);
  else raise exception 'unknown probe operation';end if;
  return jsonb_build_object('outcome','returned','result',r);
 exception when check_violation or invalid_parameter_value or serialization_failure or insufficient_privilege then
  return jsonb_build_object('outcome','denied','sqlstate',SQLSTATE,'reason',SQLERRM);
 end;
end;$$;
revoke all on all functions in schema session_financial_probe from public,anon,authenticated,service_role;
commit;

-- STATIC PRODUCTION LOCK AUDIT (no production replacements in this file):
-- C2 reconcile: financial well advisory -> operational well row -> session ->
-- work -> account -> period rows FOR SHARE -> invoice -> native C0 children.
-- C0.2 release/rebalance: financial well -> source identity -> account ->
-- payment -> allocation/invoice/credit; release takes period SHARE later.
-- Credit spend: financial well -> refresh/credit/invoice -> posting period.
-- Same-well financial operations are serialized before these differing inner
-- row orders. C1: operational well -> session, no financial lock. C2 and invoice
-- issuance take operational scope BEFORE session. R6-C2A close/reopen:
-- financial well -> period FOR UPDATE -> reopen request if needed -> audit/FK.
-- ensure_periods and its journal caller now also acquire financial well first.
-- CASE 8A is reconciliation-first; fixture 10 is CASE 8B close-first.
-- The protected gates below are inside these real transactions, not wrappers
-- taking artificial business locks instead of invoking the production paths.
do $races$
declare conn text;socket_dir text;ext_schema text;x session_financial_probe.fixtures%rowtype;
 n integer;pa integer;pb integer;iso_a text;iso_b text;su_a boolean;su_b boolean;socket_a boolean;socket_b boolean;
 qa text;qb text;kind_b text;deadline timestamptz;ra jsonb;rb jsonb;replay jsonb;before_finance jsonb;before_replay jsonb;
 initial_op bigint;initial_fin bigint;payments_before bigint;charges_before bigint;allocations_before bigint;fuel_before bigint;
 invoices_before bigint;invoice_lines_before bigint;journals_before bigint;journal_lines_before bigint;expected_journals integer;
 invoice uuid;expected_fin bigint;expected_debt bigint;child record;event billing.customer_credit_events%rowtype;
 pc sync.processed_commands%rowtype;work ops.session_correction_reconciliations%rowtype;
 gate_held boolean:=false;a_open boolean:=false;b_open boolean:=false;
begin
 perform set_config('TimeZone','UTC',true);
 select ns.nspname into strict ext_schema from pg_extension e join pg_namespace ns on ns.oid=e.extnamespace where e.extname='dblink';
 perform set_config('search_path',quote_ident(ext_schema)||',pg_catalog,session_financial_probe',true);
 socket_dir:=btrim(split_part(current_setting('unix_socket_directories'),',',1));
 if socket_dir not like '/%' then raise exception 'LOCAL_UNIX_SOCKET_REQUIRED';end if;
 conn:=format('host=%L port=%s dbname=%L user=%L connect_timeout=5',
  socket_dir,current_setting('port'),current_database(),current_user);
 perform dblink_connect('session_financial_a',conn);a_open:=true;
 perform dblink_connect('session_financial_b',conn);b_open:=true;
 perform dblink_exec('session_financial_a','set session characteristics as transaction isolation level read committed');
 perform dblink_exec('session_financial_b','set session characteristics as transaction isolation level read committed');
 perform dblink_exec('session_financial_a','set timezone=''UTC''');
 perform dblink_exec('session_financial_b','set timezone=''UTC''');
 perform dblink_exec('session_financial_a','set statement_timeout=''30s''');
 perform dblink_exec('session_financial_b','set statement_timeout=''30s''');
 perform dblink_exec('session_financial_a','set lock_timeout=''15s''');
 perform dblink_exec('session_financial_b','set lock_timeout=''15s''');
 select pid,isolation,is_super,is_socket into pa,iso_a,su_a,socket_a from dblink('session_financial_a',
  'select pg_backend_pid(),current_setting(''transaction_isolation''),(select rolsuper from pg_roles where rolname=current_user),inet_server_addr() is null')
  as t(pid integer,isolation text,is_super boolean,is_socket boolean);
 select pid,isolation,is_super,is_socket into pb,iso_b,su_b,socket_b from dblink('session_financial_b',
  'select pg_backend_pid(),current_setting(''transaction_isolation''),(select rolsuper from pg_roles where rolname=current_user),inet_server_addr() is null')
  as t(pid integer,isolation text,is_super boolean,is_socket boolean);
 perform session_financial_probe.check_result(pa<>pb and pa<>pg_backend_pid() and pb<>pg_backend_pid()
  and su_a and su_b and socket_a and socket_b and iso_a='read committed' and iso_b='read committed',
  'two independent owner Unix-socket sessions with READ COMMITTED');

 for n in 1..9 loop
  select * into strict x from session_financial_probe.fixtures where case_id=n;
  select operational_revision into strict initial_op from ops.irrigation_sessions where id=(x.f->>'session')::uuid;
  select financial_applied_revision into strict initial_fin from billing.effective_session_charges where id=(x.f->>'charge')::uuid;
  perform session_financial_probe.check_result(initial_fin=x.target_revision-1,'target financial predecessor, case '||n);
  select count(*) into payments_before from billing.payments;
  select count(*) into charges_before from billing.session_charges;
  select count(*) into allocations_before from billing.payment_allocations;
  select count(*) into fuel_before from inventory.fuel_transactions;
  select count(*) into invoices_before from billing.invoices;
  select count(*) into invoice_lines_before from billing.invoice_lines;
  select count(*) into journals_before from finance.journal_entries;
  select count(*) into journal_lines_before from finance.journal_lines;
  before_finance:=session_financial_probe.financial_state();
  kind_b:=case when n in (1,2,6) then 'reconcile_b' when n=3 then 'release' when n=4 then 'spend'
   when n=5 then 'rebalance' when n=7 then 'operational' when n=8 then 'close' else 'invoice' end;
  qa:=format('select session_financial_probe.attempt(%s,%L)',n,'reconcile_a');
  qb:=format('select session_financial_probe.attempt(%s,%L)',n,kind_b);
  perform pg_advisory_lock(746208,n);gate_held:=true;
  perform session_financial_probe.check_result(dblink_send_query('session_financial_a',qa)=1,'launch real transaction A, case '||n);
  deadline:=clock_timestamp()+interval '5 seconds';
  loop
   perform pg_stat_clear_snapshot();
   exit when exists(select 1 from pg_stat_activity where pid=pa and wait_event='advisory')
    and pg_backend_pid()=any(pg_blocking_pids(pa));
   if clock_timestamp()>deadline then raise exception 'A_PROTECTED_GATE_NOT_REACHED case %',n;end if;
   perform pg_sleep(0.01);
  end loop;
  perform session_financial_probe.check_result(dblink_send_query('session_financial_b',qb)=1,'launch real transaction B, case '||n);
  deadline:=clock_timestamp()+interval '5 seconds';
  loop
   perform pg_stat_clear_snapshot();
   exit when pa=any(pg_blocking_pids(pb))
    and exists(select 1 from pg_stat_activity where pid=pb and wait_event_type='Lock');
   if clock_timestamp()>deadline then raise exception 'B_NOT_ACTUALLY_BLOCKED_BY_A case %',n;end if;
   perform pg_sleep(0.01);
  end loop;
  perform session_financial_probe.check_result(dblink_is_busy('session_financial_a')=1 and dblink_is_busy('session_financial_b')=1,
   'observed protected A and actual B -> A blocking, case '||n);
  perform session_financial_probe.check_result(pg_advisory_unlock(746208,n),'release verified barrier, case '||n);gate_held:=false;
  deadline:=clock_timestamp()+interval '30 seconds';
  loop
   exit when dblink_is_busy('session_financial_a')=0 and dblink_is_busy('session_financial_b')=0;
   if clock_timestamp()>deadline then raise exception 'RACE_RESULT_TIMEOUT case %',n;end if;
   perform pg_sleep(0.01);
  end loop;
  select result into strict ra from dblink_get_result('session_financial_a') as t(result jsonb);
  select result into strict rb from dblink_get_result('session_financial_b') as t(result jsonb);
  perform * from dblink_get_result('session_financial_a') as t(result jsonb);
  perform * from dblink_get_result('session_financial_b') as t(result jsonb);
  perform session_financial_probe.check_result(ra->>'outcome'='returned'
   and ra->'result'->>'status'=case when n=6 then 'financial_review_required' else 'applied' end,
   'A returned the expected durable financial result, case '||n||'; result='||ra::text);

  if n=1 then
   perform session_financial_probe.check_result(rb=ra,'CASE 1 exact racing reconciliation returns one original logical result');
   perform session_financial_probe.check_result((select count(*)=1 and sum(amount_minor)=1000
    from billing.account_credit_application_adjustments where application_id=(x.f->>'application')::uuid)
    and (select effective_amount_minor=1000 from billing.effective_account_credit_applications where id=(x.f->>'application')::uuid),
    'CASE 1 one C0.1 release, immutable original application, no duplicate adjustment');
   perform session_financial_probe.check_result((select count(*)=1 and sum(amount_minor)=8000 from billing.account_credits where origin_source_id=x.correction_a),
    'CASE 1 one new credit backs released capacity, no recreated original value');
  elsif n=2 then
   perform session_financial_probe.check_result(rb->>'outcome'='denied' and rb->>'sqlstate'='22023'
    and rb->>'reason'='session_financial_idempotency_conflict','CASE 2 changed immutable posting context rejected after wait');
  elsif n=3 then
   perform session_financial_probe.check_result(rb->>'outcome'='denied' and rb->>'sqlstate'='23514'
    and rb->>'reason'='payment_allocation_adjustment_out_of_range'
    and not exists(select 1 from billing.customer_credit_events where source_id=x.source_b),
    'CASE 3 stale 9000 release cannot exceed 8000 remaining allocation; no losing effect');
  elsif n=4 then
   perform session_financial_probe.check_result(rb->>'outcome'='returned' and rb->'result'->>'status'='accepted'
    and (select available_minor=0 and used_minor=2000 from billing.account_credit_balances where id=(x.f->>'credit')::uuid)
    and (select count(*)=1 and sum(amount_minor)=2000 from billing.account_credit_applications
      where credit_id=(x.f->>'credit')::uuid and invoice_id=(x.f->>'recipient_invoice')::uuid)
    and (select outstanding_minor=2000 from billing.session_economic_settlements where session_charge_id=(x.f->>'charge')::uuid),
    'CASE 4 credit spent on other debt once; increased session debt outstanding, no clawback');
  elsif n=5 then
   perform session_financial_probe.check_result(rb->>'outcome'='returned' and rb->'result'=(ra->'result'->'child_effects'->0)
    and (select count(*)=1 from billing.customer_credit_events where source_id=x.source_b and source_revision=x.target_revision)
    and (select count(*)=1 and sum(credit_amount_minor)=2000 from billing.payment_repartition_events p
      join billing.customer_credit_events e on e.id=p.event_id where e.source_id=x.source_b),
    'CASE 5 native rebalance races its identical C2 child: one event, one credit, one liability posting');
  elsif n=6 then
   perform session_financial_probe.check_result(ra->'result'->>'review_code'='historical_price_unproven'
    and rb->>'outcome'='returned' and rb->'result'->>'status'='pending'
    and rb->'result'->'attempt_started'='false'::jsonb
    and (select status='pending' and attempt_count=0 from ops.session_correction_reconciliations where correction_id=x.correction_b)
    and not exists(select 1 from sync.processed_commands where tenant_id=(x.f->>'tenant')::uuid and command_id=x.command_b)
    and before_finance=session_financial_probe.financial_state(),
    'CASE 6 unresolved financial revision 1 blocks 2 with zero financial children/partial reservation');
  elsif n=7 then
   perform session_financial_probe.check_result(rb->>'outcome'='returned' and rb->'result'->>'status'='accepted'
    and (select operational_revision=2 from ops.irrigation_sessions where id=(x.f->>'session')::uuid)
    and (select before_ended_at=(x.f->>'at')::timestamptz+interval '8000 seconds'
      and after_ended_at=(x.f->>'at')::timestamptz+interval '9000 seconds' and new_revision=2
      from ops.session_corrections where command_id=x.command_b and tenant_id=(x.f->>'tenant')::uuid)
    and (select status='pending' from ops.session_correction_reconciliations where correction_id=(rb->'result'->>'correction_id')::uuid)
    and ra->'result'->>'operational_revision'='1',
    'CASE 7 newer operational truth durable while financial result stays bound to revision 1');
  elsif n=8 then
   perform session_financial_probe.check_result(rb->>'outcome'='returned' and rb->'result'->>'status'='closed'
    and (select status='closed' from finance.accounting_periods where id=x.period_id)
    and (select count(*)=2 and bool_and(backend_pid=pa and period_status in ('open','reopened'))
      from session_financial_probe.post_observations)
    and (select backend_pid=pb and work_status='applied' and committed_postings=2
      from session_financial_probe.close_observations where period_id=x.period_id),
    'CASE 8 actual period lock blocks close until ALL postings and financial acceptance committed');
  else
   invoice:=(rb->'result'->>'invoice_id')::uuid;
   perform session_financial_probe.check_result(rb->>'outcome'='returned' and rb->'result'->>'status'='issued'
    and (select count(*)=1 from billing.invoices where session_id=(x.f->>'session')::uuid)
    and (select total_minor=8000 and session_financial_revision=1 from billing.invoices where id=invoice)
    and (select sum(amount_minor)=8000 from billing.invoice_lines where invoice_id=invoice)
    and not exists(select 1 from billing.invoice_corrections where correction_id=x.correction_a),
    'CASE 9 one invoice at applied revision 1; no missed/double pre-invoice delta');
  end if;

  expected_fin:=case when n=6 then initial_fin else x.target_revision end;
  expected_debt:=case when n=6 then 10000 else x.expected_amount end;
  perform session_financial_probe.check_result((select count(*)=1 and bool_and(financial_applied_revision=expected_fin and amount_minor=expected_debt)
   from billing.effective_session_charges where id=(x.f->>'charge')::uuid),'single-valued effective charge/financial revision, case '||n);
  if n not in (5) then
   perform session_financial_probe.check_result((select count(*)=1 and bool_and(b.total_minor=expected_debt
     and b.paid_minor+b.outstanding_minor=b.total_minor and least(b.paid_minor,b.outstanding_minor)>=0)
    from billing.invoice_effective_balances b join billing.invoices i on i.id=b.invoice_id
    where i.session_id=(x.f->>'session')::uuid and i.status not in ('cancelled','reversed')),
    'single-valued effective invoice/debt, case '||n);
  end if;
  perform session_financial_probe.check_result((select count(*)=1 and bool_and(debt_minor=expected_debt
    and settled_minor+outstanding_minor=debt_minor and least(settled_minor,outstanding_minor)>=0)
   from billing.session_economic_settlements where session_charge_id=(x.f->>'charge')::uuid),
   'single-valued conserved effective debt/settlement, case '||n);
  perform session_financial_probe.check_result((select count(*)=count(distinct payment_id)
   and coalesce(bool_and(explicit_allocated_minor+effective_direct_minor+credit_backed_minor+remaining_minor=amount_minor
    and least(explicit_allocated_minor,effective_direct_minor,credit_backed_minor,remaining_minor)>=0),true)
   from billing.payment_economic_applications where well_id=(x.f->>'well')::uuid),
   'payment = explicit allocations + direct + active credit backing + remaining, case '||n);
  perform session_financial_probe.check_result((select count(*)=case when n=6 then 0 else 1 end
   from billing.session_charge_corrections where correction_id=x.correction_a)
   and (select count(*)=case when n in (5,6,9) then 0 else 1 end
    from billing.invoice_corrections where correction_id=x.correction_a),
   'exactly one charge/invoice correcting history when applicable, case '||n);
  select * into strict pc from sync.processed_commands where tenant_id=(x.f->>'tenant')::uuid and command_id=x.command_a;
  select * into strict work from ops.session_correction_reconciliations where correction_id=x.correction_a;
  perform session_financial_probe.check_result(pc.status='accepted' and pc.command_type='reconcile_session_correction'
   and pc.entity_id=x.correction_a and pc.response_payload=ra->'result'
   and work.last_financial_result=pc.response_payload and work.last_financial_request=pc.request_payload
   and work.status=ra->'result'->>'status' and work.attempt_count=1
   and ((n=6 and work.financial_applied_revision is null) or (n<>6 and work.financial_applied_revision=x.target_revision))
   and work.last_reconciliation_command_id=x.command_a
   and pc.request_payload->>'posting_timezone'='UTC'
   and (pc.request_payload->>'posted_at')::timestamptz=(x.f->>'posting')::timestamptz,
   'one durable canonical financial context/result and one state transition, case '||n);
  perform session_financial_probe.check_result((select count(*)=x.expected_children from billing.customer_credit_events
   where origin_source_id=x.correction_a),'one stable C0/C0.1/C0.2 child set, case '||n);
  perform session_financial_probe.check_result((select count(*)=case when n in (2,3,8) then 1 else 0 end
    from billing.payment_allocation_adjustments a join billing.customer_credit_events e on e.id=a.event_id
    where e.origin_source_id=x.correction_a)
   and (select count(*)=case when n=1 then 1 else 0 end from billing.account_credit_application_adjustments a
    join billing.customer_credit_events e on e.id=a.event_id where e.origin_source_id=x.correction_a)
   and (select count(*)=case when n in (1,2,3,5,8,9) then 1 else 0 end from billing.account_credits
    where origin_source_id=x.correction_a), 'no duplicate allocation/application/credit effects, case '||n);
  for child in select value from jsonb_array_elements(coalesce(ra->'result'->'child_effects','[]'::jsonb)) loop
   select * into strict event from billing.customer_credit_events where id=(child.value->>'event_id')::uuid;
   perform session_financial_probe.check_result(event.origin_source_id=x.correction_a and event.source_revision=x.target_revision
    and event.result_payload=child.value,'child result belongs to exactly one stable source');
   perform session_financial_probe.check_result((select count(*)=case when event.journal_entry_id is null then 0 else 1 end
    from finance.journal_entries where source_type='customer_credit' and source_id=event.id),
    'no duplicate child liability/reclassification journal');
  end loop;
  perform session_financial_probe.check_result((select count(*)=case when n in (5,6,9) then 0 else 1 end
   from finance.journal_entries where source_type='session_correction' and source_id=x.correction_a),
   'one canonical revenue correction journal when applicable, case '||n);
  perform session_financial_probe.check_result(not exists(select 1 from billing.session_charge_corrections h
   join ops.session_correction_reconciliations earlier on earlier.session_id=h.session_id
   and earlier.operational_revision<h.operational_revision where earlier.status<>'applied'),
   'no applied financial revision overtakes unresolved predecessor');
  perform session_financial_probe.check_result((select operational_revision=initial_op+case when n=7 then 1 else 0 end
   from ops.irrigation_sessions where id=(x.f->>'session')::uuid),
   'only explicit case-7 human action advances operational revision');
  perform session_financial_probe.assert_frozen();
  expected_journals:=case when n=1 then 3 when n in (2,3,4,8,9) then 2 when n in (5,7) then 1 else 0 end;
  perform session_financial_probe.check_result((select count(*) from billing.payments)=payments_before
   and (select count(*) from billing.session_charges)=charges_before
   and (select count(*) from billing.payment_allocations)=allocations_before
   and (select count(*) from inventory.fuel_transactions)=fuel_before
   and (select count(*) from billing.invoices)=invoices_before+case when n=9 then 1 else 0 end
   and (select count(*) from billing.invoice_lines)=invoice_lines_before+case when n=9 then 1 else 0 end
   and (select count(*) from finance.journal_entries)=journals_before+expected_journals
   and (select count(*) from finance.journal_lines)=journal_lines_before+2*expected_journals,
   'no replacement payment/charge/allocation/fuel; only real case-9 invoice issuance');
  -- Exact retry also runs after case-8 closes the posting period. It must
  -- return the original durable result without re-posting or re-checking time.
  before_replay:=session_financial_probe.financial_state(true);
  select result into strict replay from dblink('session_financial_a',qa) as t(result jsonb);
  perform session_financial_probe.check_result(replay=ra and before_replay=session_financial_probe.financial_state(true),
   'durable exact retry adds no financial/work/command effect, case '||n);
 end loop;
 perform session_financial_probe.check_result(to_regclass('finance.session_distribution_corrections') is null,
  'no C3 correction distribution machinery');
 -- CASE 8B: close FIRST. Keep the same two independent connections; do
 -- not substitute sequential calls or a pre-lock wrapper for production close.
 n:=10;
 select * into strict x from session_financial_probe.fixtures where case_id=n;
 before_finance:=session_financial_probe.financial_state();
 perform pg_advisory_lock(746208,n);gate_held:=true;
 perform session_financial_probe.check_result(dblink_send_query('session_financial_a',
  'select session_financial_probe.attempt(10,''close'')')=1,'CASE 8B launch close first');
 deadline:=clock_timestamp()+interval '5 seconds';
 loop
  perform pg_stat_clear_snapshot();
  exit when exists(select 1 from pg_stat_activity where pid=pa and wait_event='advisory')
   and pg_backend_pid()=any(pg_blocking_pids(pa));
  if clock_timestamp()>deadline then raise exception 'CLOSE_FIRST_PROTECTED_GATE_NOT_REACHED';end if;
  perform pg_sleep(0.01);
 end loop;
 -- Exact existing bigint advisory key, not just any gate lock owned by A.
 -- Old period-first close FAILS this assertion deterministically before a
 -- deadlock can masquerade as a successful run.
 perform session_financial_probe.check_result(exists(select 1 from pg_locks l
  where l.pid=pa and l.locktype='advisory' and l.granted and l.objsubid=1
   and l.classid=((hashtextextended('customer-credit-well:'||(x.f->>'well'),0)>>32)&4294967295)::oid
   and l.objid=(hashtextextended('customer-credit-well:'||(x.f->>'well'),0)&4294967295)::oid),
  'CASE 8B real close owns canonical financial well BEFORE audit/close barrier');
 perform session_financial_probe.check_result(dblink_send_query('session_financial_b',
  'select session_financial_probe.attempt(10,''reconcile_a'')')=1,'CASE 8B launch financial reconciliation second');
 deadline:=clock_timestamp()+interval '5 seconds';
 loop
  perform pg_stat_clear_snapshot();
  exit when pa=any(pg_blocking_pids(pb)) and exists(select 1 from pg_stat_activity
   where pid=pb and wait_event='advisory');
  if clock_timestamp()>deadline then raise exception 'CLOSE_FIRST_RECONCILIATION_NOT_BLOCKED_ON_CANONICAL_LOCK';end if;
  perform pg_sleep(0.01);
 end loop;
 perform session_financial_probe.check_result(not(pb=any(pg_blocking_pids(pa)))
  and pg_backend_pid()=any(pg_blocking_pids(pa))
  and dblink_is_busy('session_financial_a')=1 and dblink_is_busy('session_financial_b')=1,
  'CASE 8B B waits for close A; A waits only controller, NO opposite/circular wait');
 perform session_financial_probe.check_result(pg_advisory_unlock(746208,n),'CASE 8B release close barrier');gate_held:=false;
 deadline:=clock_timestamp()+interval '30 seconds';
 loop
  exit when dblink_is_busy('session_financial_a')=0 and dblink_is_busy('session_financial_b')=0;
  if clock_timestamp()>deadline then raise exception 'CLOSE_FIRST_DEADLOCK_OR_COMPLETION_TIMEOUT';end if;
  perform pg_sleep(0.01);
 end loop;
 -- 40P01/timeout are not caught by attempt(): either remote error FAILS here.
 select result into strict ra from dblink_get_result('session_financial_a') as t(result jsonb);
 select result into strict rb from dblink_get_result('session_financial_b') as t(result jsonb);
 perform * from dblink_get_result('session_financial_a') as t(result jsonb);
 perform * from dblink_get_result('session_financial_b') as t(result jsonb);
 perform session_financial_probe.check_result(ra->>'outcome'='returned' and ra->'result'->>'status'='closed'
  and rb->>'outcome'='returned' and rb->'result'->>'status'='financial_review_required'
  and rb->'result'->>'review_code'='accounting_period_not_open',
  'CASE 8B close commits; reconciliation rechecks CLOSED period after wait');
 perform session_financial_probe.check_result((select status='closed' from finance.accounting_periods where id=x.period_id)
  and (select status='financial_review_required' and attempt_count=1 from ops.session_correction_reconciliations where correction_id=x.correction_a)
  and (select financial_applied_revision=0 and amount_minor=10000 from billing.effective_session_charges where id=(x.f->>'charge')::uuid)
  and (select operational_revision=1 from ops.irrigation_sessions where id=(x.f->>'session')::uuid),
  'CASE 8B operational correction durable; financial revision unchanged and review durable');
 perform session_financial_probe.check_result(before_finance-'finance.accounting_periods'=
  session_financial_probe.financial_state()-'finance.accounting_periods',
  'CASE 8B ZERO financial children: charge/invoice/payment/allocation/credit/journal/fuel/distribution unchanged');
 perform session_financial_probe.check_result(not exists(select 1 from billing.session_charge_corrections where correction_id=x.correction_a)
  and not exists(select 1 from billing.invoice_corrections where correction_id=x.correction_a)
  and (select count(*)=1 from billing.effective_session_charges where id=(x.f->>'charge')::uuid),
  'CASE 8B no correction child or duplicate effective charge');
 perform session_financial_probe.assert_frozen();
 before_replay:=session_financial_probe.financial_state(true);
 replay:=session_financial_probe.attempt(10,'reconcile_a');
 perform session_financial_probe.check_result(replay=rb and before_replay=session_financial_probe.financial_state(true),
  'CASE 8B review retry returns original result without children or transition duplication');
 perform dblink_disconnect('session_financial_a');a_open:=false;
 perform dblink_disconnect('session_financial_b');b_open:=false;
exception when others then
 -- Transaction-local search_path rolls back on error; dblink connections and
 -- session advisory locks do not. Restore resolution before explicit cleanup.
 if ext_schema is not null then
  perform set_config('search_path',quote_ident(ext_schema)||',pg_catalog,session_financial_probe',true);end if;
 if a_open then begin perform dblink_cancel_query('session_financial_a');exception when others then null;end;end if;
 if b_open then begin perform dblink_cancel_query('session_financial_b');exception when others then null;end;end if;
 if gate_held then perform pg_advisory_unlock(746208,n);end if;
 if a_open then begin perform dblink_disconnect('session_financial_a');exception when others then null;end;end if;
 if b_open then begin perform dblink_disconnect('session_financial_b');exception when others then null;end;end if;
 raise;
end;$races$;
-- Success removes hooks; committed fixtures/probe evidence are retained for
-- inspection. On any failure ON_ERROR_STOP + cleanup applies; owner RESET is
-- mandatory in either outcome, including any test hooks left after an error.
drop trigger session_financial_charge_barrier on billing.session_charge_corrections;
drop trigger session_financial_work_barrier on ops.session_correction_reconciliations;
drop trigger session_financial_post_observer on finance.journal_entries;
drop trigger session_financial_close_observer on finance.accounting_periods;
drop trigger session_financial_close_first_barrier on finance.accounting_periods;

-- Oldest-first regression: a real payment reversal makes older debt eligible
-- while a newer manual selection waits on the SAME financial root. Run only
-- after the complete financial-boundary migration set is owner-approved.
begin;
create table session_financial_probe.source_order_fixture(f jsonb not null,cycle_id uuid not null,source_id uuid not null,selection_id uuid not null);
do $setup$
declare f jsonb;person uuid;partner uuid;policy uuid;newer uuid;cycle uuid;src uuid;r jsonb;
begin
 f:=session_financial_probe.fixture(10000,10000,true);
 update core.well_assignments set role='owner' where well_id=(f->>'well')::uuid and profile_id=(f->>'actor')::uuid;
 select fp.person_id into person from ops.farmer_profiles fp join ops.farmer_well_accounts a on a.farmer_profile_id=fp.id where a.id=(f->>'account')::uuid;
 insert into core.well_partners(tenant_id,well_id,person_id,phone,period_start)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,person,'777777777',date '1970-01-01') returning id into partner;
 insert into core.ownership_share_versions(tenant_id,well_id,partner_id,ownership_percentage,profit_percentage,effective_period)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,partner,100,100,daterange(date '1970-01-01',null,'[)'));
 insert into core.partner_irrigation_policies(tenant_id,well_id,partner_id,policy_type,period_start)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,partner,'deduct_from_profit',date '1970-01-01') returning id into policy;
 update billing.invoices set partner_policy_id=policy where id=(f->>'invoice')::uuid;
 insert into billing.invoices(tenant_id,well_id,public_code,farmer_well_account_id,invoice_date,status,subtotal_minor,total_minor,paid_minor,outstanding_minor,partner_policy_id)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,core.generate_public_code('INV'),(f->>'account')::uuid,
  (f->>'at')::timestamptz+interval '12 hours','draft',2000,2000,0,2000,policy) returning id into newer;
 update billing.invoices set status='issued' where id=newer;
 perform api.update_distribution_settings((f->>'well')::uuid,false);
 cycle:=finance.calculate_profit_distribution((f->>'well')::uuid,(f->>'at')::timestamptz-interval '1 day',now(),(f->>'actor')::uuid,0);
 select id into strict src from finance.distribution_sources where invoice_id=newer;
 r:=api.select_partner_distribution_source(cycle,src,1000,'selection while older invoice fully paid');
 insert into session_financial_probe.source_order_fixture values(f,cycle,src,(r->>'selection_id')::uuid);
end;$setup$;
create function session_financial_probe.source_order_gate() returns trigger language plpgsql as $$
begin
 if new.status='reversed' and old.status='posted' and exists(select 1 from session_financial_probe.source_order_fixture x where x.f->>'payment'=new.id::text) then
  perform pg_advisory_xact_lock(746219,1);end if;
 return new;
end;$$;
create trigger source_order_reversal_gate after update of status on billing.payments
 for each row execute function session_financial_probe.source_order_gate();
create function session_financial_probe.source_order_attempt(kind text) returns jsonb language plpgsql as $$
declare x session_financial_probe.source_order_fixture%rowtype;r jsonb;id uuid;
begin
 if current_setting('transaction_isolation')<>'read committed' then raise exception 'SOURCE_ORDER_REQUIRES_READ_COMMITTED';end if;
 select * into strict x from session_financial_probe.source_order_fixture;
 perform set_config('request.jwt.claim.sub',x.f->>'actor',true);
 begin
  if kind='reverse' then
   id:=billing.reverse_payment((x.f->>'payment')::uuid,'owner concurrency: older debt restored',(x.f->>'actor')::uuid);
   return jsonb_build_object('status','reversed','id',id);
  elsif kind='select' then return api.select_partner_distribution_source(x.cycle_id,x.source_id,500,'must recheck oldest after wait');
  elsif kind='approve' then perform finance.approve_profit_distribution(x.cycle_id,(x.f->>'actor')::uuid);return jsonb_build_object('status','approved');
  else raise exception 'UNKNOWN_SOURCE_ORDER_ATTEMPT';end if;
 exception when check_violation then return jsonb_build_object('status','denied','reason',SQLERRM);end;
end;$$;
revoke all on all functions in schema session_financial_probe from public,anon,authenticated,service_role;
commit;
do $source_race$
declare ext_schema text;socket_dir text;conn text;pa integer;pb integer;deadline timestamptz;ra jsonb;rb jsonb;r jsonb;
 x session_financial_probe.source_order_fixture%rowtype;initial_selections bigint;initial_consumptions bigint;after_journals bigint;
 a_open boolean:=false;b_open boolean:=false;gate_held boolean:=false;
begin
 select ns.nspname into strict ext_schema from pg_extension e join pg_namespace ns on ns.oid=e.extnamespace where e.extname='dblink';
 perform set_config('search_path',quote_ident(ext_schema)||',pg_catalog,session_financial_probe',true);
 socket_dir:=btrim(split_part(current_setting('unix_socket_directories'),',',1));
 if socket_dir not like '/%' then raise exception 'LOCAL_UNIX_SOCKET_REQUIRED';end if;
 conn:=format('host=%L port=%s dbname=%L user=%L connect_timeout=5',socket_dir,current_setting('port'),current_database(),current_user);
 select * into strict x from session_financial_probe.source_order_fixture;
 select count(*) into initial_selections from finance.distribution_source_selections where cycle_id=x.cycle_id;
 select count(*) into initial_consumptions from finance.distribution_source_consumptions where cycle_id=x.cycle_id;
 perform dblink_connect('source_order_a',conn);a_open:=true;
 perform dblink_connect('source_order_b',conn);b_open:=true;
 perform dblink_exec('source_order_a','set session characteristics as transaction isolation level read committed');
 perform dblink_exec('source_order_b','set session characteristics as transaction isolation level read committed');
 perform dblink_exec('source_order_a','set timezone=''UTC''');perform dblink_exec('source_order_b','set timezone=''UTC''');
 perform dblink_exec('source_order_a','set statement_timeout=''20s''');perform dblink_exec('source_order_b','set statement_timeout=''20s''');
 perform dblink_exec('source_order_a','set lock_timeout=''10s''');perform dblink_exec('source_order_b','set lock_timeout=''10s''');
 select pid into pa from dblink('source_order_a','select pg_backend_pid()') as t(pid integer);
 select pid into pb from dblink('source_order_b','select pg_backend_pid()') as t(pid integer);
 perform session_financial_probe.check_result(pa<>pb,'oldest-first uses independent real backends');
 perform pg_advisory_lock(746219,1);gate_held:=true;
 perform session_financial_probe.check_result(dblink_send_query('source_order_a','select session_financial_probe.source_order_attempt(''reverse'')')=1,'launch real older-debt change');
 deadline:=clock_timestamp()+interval '5 seconds';
 loop
  perform pg_stat_clear_snapshot();exit when pg_backend_pid()=any(pg_blocking_pids(pa));
  if clock_timestamp()>deadline then raise exception 'SOURCE_ORDER_A_GATE_TIMEOUT';end if;perform pg_sleep(0.01);
 end loop;
 perform session_financial_probe.check_result(dblink_send_query('source_order_b','select session_financial_probe.source_order_attempt(''select'')')=1,'launch competing newer selection');
 deadline:=clock_timestamp()+interval '5 seconds';
 loop
  perform pg_stat_clear_snapshot();exit when pa=any(pg_blocking_pids(pb)) and exists(select 1 from pg_stat_activity where pid=pb and wait_event_type='Lock');
  if clock_timestamp()>deadline then raise exception 'SOURCE_ORDER_B_NOT_BLOCKED_BY_A';end if;perform pg_sleep(0.01);
 end loop;
 perform session_financial_probe.check_result(not(pb=any(pg_blocking_pids(pa))),'no opposite wait');
 perform pg_advisory_unlock(746219,1);gate_held:=false;
 deadline:=clock_timestamp()+interval '20 seconds';
 loop
  exit when dblink_is_busy('source_order_a')=0 and dblink_is_busy('source_order_b')=0;
  if clock_timestamp()>deadline then raise exception 'SOURCE_ORDER_RESULT_TIMEOUT';end if;perform pg_sleep(0.01);
 end loop;
 select result into strict ra from dblink_get_result('source_order_a') as t(result jsonb);
 select result into strict rb from dblink_get_result('source_order_b') as t(result jsonb);
 perform * from dblink_get_result('source_order_a') as t(result jsonb);perform * from dblink_get_result('source_order_b') as t(result jsonb);
 perform session_financial_probe.check_result(ra->>'status'='reversed' and rb->>'status'='denied'
  and rb->>'reason'='distribution_older_debt_requires_settlement','waiter re-evaluates oldest debt after real concurrent reversal');
 select count(*) into after_journals from finance.journal_entries;
 select result into strict r from dblink('source_order_b','select session_financial_probe.source_order_attempt(''approve'')') as t(result jsonb);
 perform session_financial_probe.check_result(r->>'status'='denied' and r->>'reason'='distribution_older_debt_requires_settlement'
  and after_journals=(select count(*) from finance.journal_entries),'stale approval rechecks order with zero child journal effects');
 perform session_financial_probe.check_result(initial_selections=(select count(*) from finance.distribution_source_selections where cycle_id=x.cycle_id)
  and initial_consumptions=(select count(*) from finance.distribution_source_consumptions where cycle_id=x.cycle_id)
  and exists(select 1 from finance.current_distribution_source_selections where id=x.selection_id and amount_minor=1000)
  and(select status='calculated' from finance.profit_distribution_cycles where id=x.cycle_id),'no partial consumption, lost draft, reservation or source substitution');
 perform dblink_disconnect('source_order_a');a_open:=false;perform dblink_disconnect('source_order_b');b_open:=false;
exception when others then
 if ext_schema is not null then perform set_config('search_path',quote_ident(ext_schema)||',pg_catalog,session_financial_probe',true);end if;
 if a_open then begin perform dblink_cancel_query('source_order_a');exception when others then null;end;end if;
 if b_open then begin perform dblink_cancel_query('source_order_b');exception when others then null;end;end if;
 if gate_held then perform pg_advisory_unlock(746219,1);end if;
 if a_open then begin perform dblink_disconnect('source_order_a');exception when others then null;end;end if;
 if b_open then begin perform dblink_disconnect('source_order_b');exception when others then null;end;end if;
 raise;
end;$source_race$;
drop trigger source_order_reversal_gate on billing.payments;

-- Additional owner races through sanctioned/root-owning production paths.
-- No standalone client journal reversal: owner adopted source-level cancellation.
begin;
create table session_financial_probe.extra_fixtures(case_id integer primary key,well_id uuid not null,actor_id uuid not null,data jsonb not null);
create function session_financial_probe.partner_source_fixture() returns jsonb language plpgsql as $$
declare tenant uuid;well uuid;actor uuid:=gen_random_uuid();person uuid;partner uuid;expense uuid;category text;cycle uuid;source uuid;
begin
 insert into core.tenants(name) values('source concurrency fixture') returning id into tenant;
 insert into core.wells(tenant_id,name) values(tenant,'source concurrency well') returning id into well;
 insert into auth.users(id,instance_id,aud,role,email,created_at,updated_at)
 values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@source-race.test',now(),now());
 insert into iam.profiles(id,full_name) values(actor,'source owner') on conflict(id) do nothing;
 insert into core.well_assignments(well_id,profile_id,role,status) values(well,actor,'owner','active');
 insert into core.persons(tenant_id,full_name,normalized_name) values(tenant,'source partner','source partner') returning id into person;
 insert into core.well_partners(tenant_id,well_id,person_id,phone,period_start) values(tenant,well,person,'777777777',date '1970-01-01') returning id into partner;
 insert into core.ownership_share_versions(tenant_id,well_id,partner_id,ownership_percentage,profit_percentage,effective_period)
 values(tenant,well,partner,100,100,daterange(date '1970-01-01',null,'[)'));
 perform set_config('request.jwt.claim.sub',actor::text,true);
 perform api.update_distribution_settings(well,false);
 select code into category from finance.expense_categories where tenant_id=tenant order by id limit 1;
 expense:=finance.record_expense(well,category,100000,'source race payable',actor,null,true,'partner_paid',null,partner,'اختبار بلا سند');
 -- The source must be strictly before the half-open distribution end; use a
 -- future end because this expense is timestamped at the transaction's now().
 cycle:=finance.calculate_profit_distribution(well,now()-interval '1 day',now()+interval '1 day',actor,0);
 select id into strict source from finance.distribution_sources where expense_id=expense;
 return jsonb_build_object('tenant',tenant,'well',well,'actor',actor,'partner',partner,'expense',expense,'cycle_a',cycle,'source',source);
end;$$;
do $extra_setup$
declare n integer;f jsonb;r jsonb;a uuid;b uuid;line uuid;period_date date:=make_date(extract(year from now())::integer+10,1,2);
 batch_a uuid;batch_b uuid;cashbox uuid;sid uuid;original ops.irrigation_sessions%rowtype;correction uuid;
begin
 for n in 1..8 loop
  if n in (1,2,4,5,8) then
   f:=session_financial_probe.partner_source_fixture();a:=(f->>'cycle_a')::uuid;
   select id into strict line from finance.profit_distribution_lines where distribution_cycle_id=a;
   f:=f||jsonb_build_object('line',line);
   if n=2 then perform finance.approve_profit_distribution(a,(f->>'actor')::uuid);end if;
   if n=8 then r:=api.select_partner_distribution_source(a,(f->>'source')::uuid,50000,'initial editable selection');f:=f||jsonb_build_object('adjustment',r->>'selection_id');end if;
   if n in (4,5) then
    b:=finance.calculate_profit_distribution((f->>'well')::uuid,now()+interval '1 day',now()+interval '2 days',(f->>'actor')::uuid,0);
    r:=api.select_partner_distribution_source(a,(f->>'source')::uuid,case when n=4 then 70000 else 30000 end,'first partial race');
    if n=4 then r:=api.select_partner_distribution_source(b,(f->>'source')::uuid,70000,'competing partial race');end if;
    f:=f||jsonb_build_object('cycle_b',b);
   end if;
  elsif n=3 then
   f:=session_financial_probe.fixture(10000,0,false);
   update core.well_assignments set role='owner' where well_id=(f->>'well')::uuid and profile_id=(f->>'actor')::uuid;
   perform set_config('request.jwt.claim.sub',f->>'actor',true);
   cashbox:=finance.main_cashbox_id((f->>'well')::uuid);
   batch_a:=api.create_opening_balance_batch((f->>'well')::uuid,period_date,'first future opening');
   batch_b:=api.create_opening_balance_batch((f->>'well')::uuid,period_date,'second future opening');
   perform api.add_opening_balance_item(batch_a,'cashbox_balance',1000,null,null,null,cashbox);
   perform api.add_opening_balance_item(batch_a,'capital_balance',1000);
   perform api.add_opening_balance_item(batch_b,'cashbox_balance',1000,null,null,null,cashbox);
   perform api.add_opening_balance_item(batch_b,'capital_balance',1000);
   perform finance.approve_opening_balance_batch(batch_a,(f->>'actor')::uuid);
   perform finance.approve_opening_balance_batch(batch_b,(f->>'actor')::uuid);
   f:=f||jsonb_build_object('batch_a',batch_a,'batch_b',batch_b,'period_date',period_date);
  elsif n=6 then
   f:=session_financial_probe.fixture(10000,10000,true);
   update core.well_assignments set role='owner' where well_id=(f->>'well')::uuid and profile_id=(f->>'actor')::uuid;
   f:=f||jsonb_build_object('journal',(select journal_entry_id from billing.payments where id=(f->>'payment')::uuid));
  else
   f:=session_financial_probe.fixture(10000,10000,true);
   update core.well_assignments set role='owner' where well_id=(f->>'well')::uuid and profile_id=(f->>'actor')::uuid;
   perform set_config('request.jwt.claim.sub',f->>'actor',true);
   perform inventory.purchase_fuel((f->>'well')::uuid,100,100000,(f->>'at')::timestamptz,(f->>'actor')::uuid);
   select * into strict original from ops.irrigation_sessions where id=(f->>'session')::uuid;
   sid:=api.start_operational_session((f->>'well')::uuid,original.pump_id,original.farm_id,(f->>'account')::uuid,
    'well_diesel',now()-interval '1 hour',gen_random_uuid());
   correction:=session_financial_probe.correct(f,gen_random_uuid(),0,8000);
   f:=f||jsonb_build_object('open_session',sid,'correction',correction,'reconcile_command',gen_random_uuid());
  end if;
  insert into session_financial_probe.extra_fixtures values(n,(f->>'well')::uuid,(f->>'actor')::uuid,f);
 end loop;
end;$extra_setup$;
create function session_financial_probe.extra_gate() returns trigger language plpgsql as $$
declare n integer;
begin
 if tg_table_name='distribution_source_selections' then
  select x.case_id into n from session_financial_probe.extra_fixtures x where x.case_id=8 and x.data->>'cycle_a'=new.cycle_id::text and new.mode='manual_partial';
 elsif tg_table_name='distribution_source_consumptions' then
  select x.case_id into n from session_financial_probe.extra_fixtures x where x.case_id in (1,4,5) and x.data->>'cycle_a'=new.cycle_id::text;
 elsif tg_table_name='accounting_periods' then
  select x.case_id into n from session_financial_probe.extra_fixtures x where x.case_id=3 and x.well_id=new.well_id
   and new.period_type='monthly' and new.starts_at=date_trunc('month',(x.data->>'period_date')::date)::date;
 elsif tg_table_name='journal_entries' then
  if new.status='posted' and old.status='draft' and new.source_type='partner_distribution_payment' then
   select x.case_id into n from session_financial_probe.extra_fixtures x where x.case_id=2 and x.well_id=new.well_id;
  elsif new.status='reversed' and old.status='posted' then
   select x.case_id into n from session_financial_probe.extra_fixtures x where x.case_id=6 and x.data->>'journal'=new.id::text;
  end if;
 elsif tg_table_name='session_charge_corrections' then
  select x.case_id into n from session_financial_probe.extra_fixtures x where x.case_id=7 and x.data->>'correction'=new.correction_id::text;
 end if;
 if n is not null then perform pg_advisory_xact_lock(746220,n);end if;return new;
end;$$;
create trigger extra_selection_gate after insert on finance.distribution_source_selections for each row execute function session_financial_probe.extra_gate();
create trigger extra_source_gate after insert on finance.distribution_source_consumptions for each row execute function session_financial_probe.extra_gate();
create trigger extra_period_gate after insert on finance.accounting_periods for each row execute function session_financial_probe.extra_gate();
create trigger extra_journal_gate after update of status on finance.journal_entries for each row execute function session_financial_probe.extra_gate();
create trigger extra_charge_gate after insert on billing.session_charge_corrections for each row execute function session_financial_probe.extra_gate();
create function session_financial_probe.extra_attempt(p_case integer,p_side text) returns jsonb language plpgsql as $$
declare x session_financial_probe.extra_fixtures%rowtype;r jsonb;id uuid;
begin
 if current_setting('transaction_isolation')<>'read committed' then raise exception 'EXTRA_REQUIRES_READ_COMMITTED';end if;
 select * into strict x from session_financial_probe.extra_fixtures where case_id=p_case;
 perform set_config('request.jwt.claim.sub',x.actor_id::text,true);
 begin
  if p_case=8 then
   r:=api.update_partner_distribution_adjustment((x.data->>'adjustment')::uuid,case when p_side='a' then 30000 else 40000 end,'competing adjustment edit');
  elsif p_case=1 and p_side='b' or p_case=2 and p_side='a' then
   r:=finance.pay_partner_distribution((x.data->>'line')::uuid,1000,x.actor_id,clock_timestamp());
  elsif p_case in (1,2,4,5) then
   perform finance.approve_profit_distribution((x.data->>case when p_side='b' and p_case in (4,5) then 'cycle_b' else 'cycle_a' end)::uuid,x.actor_id);
   r:=jsonb_build_object('status','approved');
  elsif p_case=3 then
   perform finance.post_opening_balance_batch((x.data->>case when p_side='a' then 'batch_a' else 'batch_b' end)::uuid,x.actor_id);
   r:=jsonb_build_object('status','posted');
  elsif p_case=6 then
   id:=api.reverse_payment((x.data->>'payment')::uuid,'concurrent source-level reversal');r:=jsonb_build_object('status','reversed','id',id);
  elsif p_case=7 and p_side='a' then
   r:=billing.reconcile_session_correction((x.data->>'correction')::uuid,(x.data->>'reconcile_command')::uuid,(x.data->>'posting')::timestamptz);
  elsif p_case=7 then
   r:=api.complete_irrigation_session((x.data->>'open_session')::uuid,clock_timestamp(),1000,'actual',null,gen_random_uuid());
  else raise exception 'UNKNOWN_EXTRA_CASE';end if;
  return jsonb_build_object('outcome','returned','result',r);
 exception when check_violation or raise_exception or insufficient_privilege or invalid_parameter_value then
  return jsonb_build_object('outcome','denied','reason',SQLERRM,'sqlstate',SQLSTATE);
 end;
end;$$;
revoke all on all functions in schema session_financial_probe from public,anon,authenticated,service_role;
commit;
do $extra_races$
declare ext_schema text;socket_dir text;conn text;pa integer;pb integer;n integer;deadline timestamptz;
 ra jsonb;rb jsonb;x session_financial_probe.extra_fixtures%rowtype;before_consumed bigint;before_payment bigint;before_lines jsonb;
 original_times jsonb;original_charge jsonb;original_invoice jsonb;original_expense jsonb;
 old_fuel jsonb;old_invoice_lines jsonb;old_allocations jsonb;old_receipts jsonb;old_approved jsonb;old_approved_lines jsonb;
 a_open boolean:=false;b_open boolean:=false;gate_held boolean:=false;
begin
 select ns.nspname into strict ext_schema from pg_extension e join pg_namespace ns on ns.oid=e.extnamespace where e.extname='dblink';
 perform set_config('search_path',quote_ident(ext_schema)||',pg_catalog,session_financial_probe',true);
 socket_dir:=btrim(split_part(current_setting('unix_socket_directories'),',',1));
 if socket_dir not like '/%' then raise exception 'LOCAL_UNIX_SOCKET_REQUIRED';end if;
 conn:=format('host=%L port=%s dbname=%L user=%L connect_timeout=5',socket_dir,current_setting('port'),current_database(),current_user);
 perform dblink_connect('extra_financial_a',conn);a_open:=true;
 perform dblink_connect('extra_financial_b',conn);b_open:=true;
 perform dblink_exec('extra_financial_a','set session characteristics as transaction isolation level read committed');
 perform dblink_exec('extra_financial_b','set session characteristics as transaction isolation level read committed');
 perform dblink_exec('extra_financial_a','set timezone=''UTC''');perform dblink_exec('extra_financial_b','set timezone=''UTC''');
 perform dblink_exec('extra_financial_a','set statement_timeout=''25s''');perform dblink_exec('extra_financial_b','set statement_timeout=''25s''');
 perform dblink_exec('extra_financial_a','set lock_timeout=''12s''');perform dblink_exec('extra_financial_b','set lock_timeout=''12s''');
 select pid into pa from dblink('extra_financial_a','select pg_backend_pid()') as t(pid integer);
 select pid into pb from dblink('extra_financial_b','select pg_backend_pid()') as t(pid integer);
 perform session_financial_probe.check_result(pa<>pb,'additional races use two independent sessions');
 for n in 1..8 loop
  select * into strict x from session_financial_probe.extra_fixtures where case_id=n;
  select coalesce(sum(amount_minor),0) into before_consumed from finance.distribution_source_consumptions where source_id=(x.data->>'source')::uuid;
  select amount_minor into before_payment from billing.payments where id=(x.data->>'payment')::uuid;
  select jsonb_agg(to_jsonb(l) order by l.id) into before_lines from finance.journal_lines l join finance.journal_entries j on j.id=l.journal_entry_id where j.well_id=x.well_id;
  select jsonb_build_object('started',started_at,'ended',ended_at) into original_times from ops.irrigation_sessions where id=(x.data->>'session')::uuid;
  select to_jsonb(ch) into original_charge from billing.session_charges ch where id=(x.data->>'charge')::uuid;
  select jsonb_build_object('id',id,'total',total_minor,'subtotal',subtotal_minor,'session_id',session_id,'account',farmer_well_account_id)
   into original_invoice from billing.invoices where id=(x.data->>'invoice')::uuid;
  select to_jsonb(e) into original_expense from finance.expenses e where id=(x.data->>'expense')::uuid;
  select jsonb_agg(to_jsonb(t) order by t.id) into old_fuel from inventory.fuel_transactions t where t.well_id=x.well_id;
  select jsonb_agg(to_jsonb(t) order by t.id) into old_invoice_lines from billing.invoice_lines t join billing.invoices i on i.id=t.invoice_id where i.well_id=x.well_id;
  select jsonb_agg(to_jsonb(t) order by t.id) into old_allocations from billing.payment_allocations t join billing.payments p on p.id=t.payment_id where p.well_id=x.well_id;
  select jsonb_agg(to_jsonb(t) order by t.id) into old_receipts from sync.processed_commands t where t.tenant_id=(x.data->>'tenant')::uuid and t.status='accepted';
  select jsonb_agg(to_jsonb(t)-'status' order by t.id) into old_approved from finance.profit_distribution_cycles t where t.well_id=x.well_id and t.status in ('approved','partially_paid','paid');
  select jsonb_agg(to_jsonb(t)-'paid_minor'-'status' order by t.id) into old_approved_lines from finance.profit_distribution_lines t join finance.profit_distribution_cycles c on c.id=t.distribution_cycle_id
   where c.well_id=x.well_id and c.status in ('approved','partially_paid','paid');
  perform pg_advisory_lock(746220,n);gate_held:=true;
  perform session_financial_probe.check_result(dblink_send_query('extra_financial_a',format('select session_financial_probe.extra_attempt(%s,''a'')',n))=1,'extra launch A '||n);
  deadline:=clock_timestamp()+interval '5 seconds';
  loop
   perform pg_stat_clear_snapshot();exit when pg_backend_pid()=any(pg_blocking_pids(pa)) and exists(select 1 from pg_stat_activity where pid=pa and wait_event='advisory');
   if clock_timestamp()>deadline then raise exception 'EXTRA_A_PROTECTED_REGION_TIMEOUT %',n;end if;perform pg_sleep(0.01);
  end loop;
  perform session_financial_probe.check_result(dblink_send_query('extra_financial_b',format('select session_financial_probe.extra_attempt(%s,''b'')',n))=1,'extra launch B '||n);
  deadline:=clock_timestamp()+interval '5 seconds';
  loop
   perform pg_stat_clear_snapshot();exit when pa=any(pg_blocking_pids(pb)) and exists(select 1 from pg_stat_activity where pid=pb and wait_event_type='Lock');
   if clock_timestamp()>deadline then raise exception 'EXTRA_B_NOT_BLOCKED_BY_A %',n;end if;perform pg_sleep(0.01);
  end loop;
  perform session_financial_probe.check_result(not(pb=any(pg_blocking_pids(pa))) and dblink_is_busy('extra_financial_a')=1 and dblink_is_busy('extra_financial_b')=1,
   'real one-way protected blocking, no circular wait '||n);
  perform pg_advisory_unlock(746220,n);gate_held:=false;
  deadline:=clock_timestamp()+interval '25 seconds';
  loop
   exit when dblink_is_busy('extra_financial_a')=0 and dblink_is_busy('extra_financial_b')=0;
   if clock_timestamp()>deadline then raise exception 'EXTRA_RESULT_TIMEOUT %',n;end if;perform pg_sleep(0.01);
  end loop;
  select result into strict ra from dblink_get_result('extra_financial_a') as t(result jsonb);
  select result into strict rb from dblink_get_result('extra_financial_b') as t(result jsonb);
  perform * from dblink_get_result('extra_financial_a') as t(result jsonb);perform * from dblink_get_result('extra_financial_b') as t(result jsonb);
  perform session_financial_probe.check_result(ra->>'outcome'='returned','first protected business operation commits '||n);
  if n=1 then
   perform session_financial_probe.check_result(rb->>'outcome'='returned' and (rb->'result'->>'paid_now_minor')::bigint=1000
    and(select paid_minor=1000 and partner_receivables_minor=100000 from finance.profit_distribution_lines where id=(x.data->>'line')::uuid),
    'approval first then partner payment: no line-before-cycle/root inversion');
  elsif n=2 then
   perform session_financial_probe.check_result(rb->>'outcome'='denied'
    and(select paid_minor=1000 and net_payable_minor=100000 from finance.profit_distribution_lines where id=(x.data->>'line')::uuid)
    and(select count(*)=1 from finance.journal_entries where source_type='profit_distribution' and source_id=(x.data->>'line')::uuid),
    'partner payment first then reapproval denied without duplicate approved history');
  elsif n=3 then
   perform session_financial_probe.check_result(rb->>'outcome'='returned'
    and(select count(*)=2 from finance.accounting_periods where well_id=x.well_id
     and (x.data->>'period_date')::date between starts_at and ends_at)
    and(select count(*)=2 from finance.journal_entries where source_type='opening_balance' and source_id in ((x.data->>'batch_a')::uuid,(x.data->>'batch_b')::uuid) and status='posted'),
    'concurrent real posting creates one monthly/annual period pair and two distinct legitimate journals');
  elsif n in (4,5) then
   perform session_financial_probe.check_result(rb->>'outcome'='denied'
    and(select count(*)=1 and sum(amount_minor)=case when n=4 then 70000 else 30000 end from finance.distribution_source_consumptions where source_id=(x.data->>'source')::uuid)
    and(select status='calculated' from finance.profit_distribution_cycles where id=(x.data->>'cycle_b')::uuid)
    and(finance.distribution_source_availability((x.data->>'source')::uuid)->>'remaining_amount_minor')::bigint=case when n=4 then 30000 else 70000 end,
    'partial/manual and automatic approval share one source authority; loser has zero partial effect '||n);
  elsif n=6 then
   perform session_financial_probe.check_result(rb->>'outcome'='denied'
    and(select status='reversed' and amount_minor=before_payment from billing.payments where id=(x.data->>'payment')::uuid)
    and(select count(*)=1 from finance.journal_entries where reversal_of_entry_id=(x.data->>'journal')::uuid),
    'source cancellation races its journal child through same parent boundary: one reversal only');
  elsif n=8 then
   perform session_financial_probe.check_result(rb->>'outcome'='denied' and rb->>'reason'='distribution_adjustment_changed'
    and(select count(*)=1 and max(amount_minor)=30000 from finance.current_distribution_source_selections where cycle_id=(x.data->>'cycle_a')::uuid and source_id=(x.data->>'source')::uuid)
    and(select count(*)=0 from finance.distribution_source_consumptions where source_id=(x.data->>'source')::uuid),
    'concurrent edits retain one current state and reject the superseded version without consuming funds');
  else
   perform session_financial_probe.check_result(rb->>'outcome'='returned' and ra->'result'->>'status'='applied'
    and(select count(*)=1 from billing.session_charge_corrections where correction_id=(x.data->>'correction')::uuid)
    and(select status='closed' from ops.irrigation_sessions where id=(x.data->>'open_session')::uuid)
    and(select count(*)=1 and sum(quantity_ml)=1000 from inventory.fuel_transactions where session_segment_id in(select id from ops.session_segments where session_id=(x.data->>'open_session')::uuid) and direction='out')
    and not exists(select 1 from inventory.fuel_transactions where session_segment_id in(select id from ops.session_segments where session_id=(x.data->>'session')::uuid) and direction='out'),
    'completion/fuel waits for correction; only genuine later completion consumes fuel');
  end if;
  if original_times is not null then
   perform session_financial_probe.check_result(original_times=(select jsonb_build_object('started',started_at,'ended',ended_at)
    from ops.irrigation_sessions where id=(x.data->>'session')::uuid),'original completed execution times preserved '||n);
  end if;
  if original_charge is not null then
   perform session_financial_probe.check_result(original_charge=(select to_jsonb(ch) from billing.session_charges ch where id=(x.data->>'charge')::uuid),'original session charge preserved '||n);
  end if;
  if original_invoice is not null then
   perform session_financial_probe.check_result(original_invoice=(select jsonb_build_object('id',id,'total',total_minor,'subtotal',subtotal_minor,'session_id',session_id,'account',farmer_well_account_id)
    from billing.invoices where id=(x.data->>'invoice')::uuid),'original invoice obligation identity/amount preserved '||n);
  end if;
  if original_expense is not null then
   perform session_financial_probe.check_result(original_expense=(select to_jsonb(e) from finance.expenses e where id=(x.data->>'expense')::uuid),'original payable evidence preserved '||n);
  end if;
  perform session_financial_probe.check_result(not exists(select 1 from jsonb_array_elements(coalesce(before_lines,'[]'::jsonb)) old_line
   where not exists(select 1 from finance.journal_lines l where l.id=(old_line->>'id')::uuid and to_jsonb(l)=old_line)),
   'all original journal lines preserved '||n);
  perform session_financial_probe.check_result(not exists(select 1 from jsonb_array_elements(coalesce(old_fuel,'[]'::jsonb)) old_row
   where not exists(select 1 from inventory.fuel_transactions t where t.id=(old_row->>'id')::uuid and to_jsonb(t)=old_row)),
   'original fuel transactions unchanged '||n);
  perform session_financial_probe.check_result(not exists(select 1 from jsonb_array_elements(coalesce(old_invoice_lines,'[]'::jsonb)) old_row
   where not exists(select 1 from billing.invoice_lines t where t.id=(old_row->>'id')::uuid and to_jsonb(t)=old_row)),
   'original invoice lines unchanged '||n);
  perform session_financial_probe.check_result(not exists(select 1 from jsonb_array_elements(coalesce(old_allocations,'[]'::jsonb)) old_row
   where not exists(select 1 from billing.payment_allocations t where t.id=(old_row->>'id')::uuid and to_jsonb(t)=old_row)),
   'original allocation evidence unchanged '||n);
  perform session_financial_probe.check_result(not exists(select 1 from jsonb_array_elements(coalesce(old_receipts,'[]'::jsonb)) old_row
   where not exists(select 1 from sync.processed_commands t where t.id=(old_row->>'id')::uuid and to_jsonb(t)=old_row)),
   'original accepted command receipts unchanged '||n);
  perform session_financial_probe.check_result(not exists(select 1 from jsonb_array_elements(coalesce(old_approved,'[]'::jsonb)) old_row
   where not exists(select 1 from finance.profit_distribution_cycles t where t.id=(old_row->>'id')::uuid and(to_jsonb(t)-'status')=old_row))
   and not exists(select 1 from jsonb_array_elements(coalesce(old_approved_lines,'[]'::jsonb)) old_row
    where not exists(select 1 from finance.profit_distribution_lines t where t.id=(old_row->>'id')::uuid and(to_jsonb(t)-'paid_minor'-'status')=old_row)),
   'approved financial basis preserved; only legitimate payment progress changes '||n);
  perform session_financial_probe.check_result((select coalesce(bool_and(explicit_allocated_minor+effective_direct_minor+credit_backed_minor+remaining_minor=amount_minor
   and least(explicit_allocated_minor,effective_direct_minor,credit_backed_minor,remaining_minor)>=0),true)
   from billing.payment_economic_applications where well_id=x.well_id),'payment value conserved '||n);
 end loop;
 perform dblink_disconnect('extra_financial_a');a_open:=false;perform dblink_disconnect('extra_financial_b');b_open:=false;
exception when others then
 if ext_schema is not null then perform set_config('search_path',quote_ident(ext_schema)||',pg_catalog,session_financial_probe',true);end if;
 if a_open then begin perform dblink_cancel_query('extra_financial_a');exception when others then null;end;end if;
 if b_open then begin perform dblink_cancel_query('extra_financial_b');exception when others then null;end;end if;
 if gate_held then perform pg_advisory_unlock(746220,n);end if;
 if a_open then begin perform dblink_disconnect('extra_financial_a');exception when others then null;end;end if;
 if b_open then begin perform dblink_disconnect('extra_financial_b');exception when others then null;end;end if;
 raise;
end;$extra_races$;
drop trigger extra_source_gate on finance.distribution_source_consumptions;
drop trigger extra_period_gate on finance.accounting_periods;
drop trigger extra_journal_gate on finance.journal_entries;
drop trigger extra_charge_gate on billing.session_charge_corrections;

drop trigger extra_selection_gate on finance.distribution_source_selections;
