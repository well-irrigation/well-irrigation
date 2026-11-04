\set ON_ERROR_STOP on
-- OWNER ONLY: قاعدة محلية قابلة للمحو. لا يضم إلى db:test ولا ينفذه الوكيل.
-- يلزم SET r6c01.disposable_database='yes' ثم إعادة بناء القاعدة بعده.
set session characteristics as transaction isolation level read committed;
do $$begin
 if current_setting('r6c01.disposable_database',true) is distinct from 'yes'
  or not (select rolsuper from pg_roles where rolname=current_user) then
  raise exception 'R6C01_OWNER_DISPOSABLE_LOCAL_DATABASE_REQUIRED';end if;
end;$$;
begin;
create extension if not exists dblink with schema extensions;
create schema r6c01_probe;
create function r6c01_probe.c01_check(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL %',label;end if;
 raise notice 'PASS %',label;end;$$;
create function r6c01_probe.c01_fixture(p_total bigint default 10000,p_paid bigint default 10000)
returns jsonb language plpgsql as $$
declare t uuid; person uuid; fp uuid; actor uuid:=gen_random_uuid();w uuid;a uuid;i uuid;payment uuid;allocation uuid;
 cmd uuid:=gen_random_uuid();r jsonb;partner uuid;at_time timestamptz:=transaction_timestamp();
begin
 insert into core.tenants(name) values('أساس تصحيح مالي') returning id into t;
 insert into auth.users(id,instance_id,aud,role,email,email_confirmed_at,created_at,updated_at)
 values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@c0.test',now(),now(),now());
 insert into iam.profiles(id,full_name) values(actor,'مالك اختبار') on conflict(id) do nothing;
 insert into core.wells(tenant_id,name) values(t,'بئر أساس مالي') returning id into w;
 insert into core.well_assignments(well_id,profile_id,role,status) values(w,actor,'owner','active');
 insert into core.persons(tenant_id,full_name,normalized_name) values(t,'مزارع مالي','مزارع مالي') returning id into person;
 insert into ops.farmer_profiles(tenant_id,person_id) values(t,person) returning id into fp;
 insert into ops.farmer_well_accounts(tenant_id,well_id,farmer_profile_id,public_code)
 values(t,w,fp,'C0-'||substr(actor::text,1,8)) returning id into a;
 insert into core.well_partners(tenant_id,well_id,person_id,phone,period_start)
 values(t,w,person,'777777777',date '1970-01-01') returning id into partner;
 insert into core.ownership_share_versions(tenant_id,well_id,partner_id,ownership_percentage,profit_percentage,effective_period)
 values(t,w,partner,100,100,daterange(date '1970-01-01',null,'[)'));
 insert into billing.invoices(tenant_id,public_code,well_id,farmer_well_account_id,invoice_date,status,
 subtotal_minor,total_minor,paid_minor,outstanding_minor)
 values(t,'C0-'||substr(actor::text,1,8),w,a,at_time,'draft',p_total,p_total,0,p_total) returning id into i;
 update billing.invoices set status='issued' where id=i;
 perform set_config('request.jwt.claim.sub',actor::text,true);
 execute 'set local role authenticated';
 r:=api.record_payment(p_well_id=>w,p_farmer_well_account_id=>a,p_amount_minor=>p_paid,
 p_method=>'cash',p_allocations=>jsonb_build_array(jsonb_build_object('invoice_id',i,'amount_minor',least(p_total,p_paid))),
 p_command_id=>cmd);
 execute 'reset role';
 select pa.id,pa.payment_id into allocation,payment from billing.payment_allocations pa where pa.invoice_id=i;
 return jsonb_build_object('tenant',t,'well',w,'account',a,'operator',actor,'invoice',i,'payment',payment,
 'allocation',allocation,'payment_command',cmd,'at',at_time);
exception when others then execute 'reset role';raise;
end;$$;
create function r6c01_probe.c01_release(f jsonb,amount bigint,source uuid,revision bigint default 1) returns jsonb
language sql as $$select billing.release_payment_allocation((f->>'allocation')::uuid,amount,source,revision,
 'سبب اختبار محفوظ  ',(f->>'at')::timestamptz);$$;
create function r6c01_probe.c01_apply(credit uuid,invoice uuid,amount bigint,source uuid,at_time timestamptz) returns jsonb
language sql as $$select billing.apply_account_credit(credit,invoice,amount,source,1,'تطبيق رصيد',at_time);$$;
create function r6c01_probe.c01_cash_snapshot(w uuid) returns jsonb language sql as $$
 select jsonb_build_object('payments',(select jsonb_agg(to_jsonb(p) order by id) from billing.payments p where p.well_id=w),
 'cash',(select jsonb_agg(to_jsonb(l) order by l.id) from finance.journal_lines l join finance.journal_entries e on e.id=l.journal_entry_id
 where e.well_id=w and l.cashbox_id is not null),'receipts',(select jsonb_agg(to_jsonb(c) order by c.id) from sync.processed_commands c
 where c.tenant_id=(select tenant_id from core.wells where id=w)));
$$;
create function r6c01_probe.c01_invoice(f jsonb,amount bigint) returns uuid language plpgsql as $$
declare i uuid;
begin
 insert into billing.invoices(tenant_id,public_code,well_id,farmer_well_account_id,invoice_date,status,
 subtotal_minor,total_minor,paid_minor,outstanding_minor)
 values((f->>'tenant')::uuid,core.generate_public_code('INV'),(f->>'well')::uuid,(f->>'account')::uuid,
 (f->>'at')::timestamptz,'draft',amount,amount,0,amount) returning id into i;
 update billing.invoices set status='issued' where id=i;return i;
end;$$;
-- تجهيز تصحيح مالي مستقل للجداول والقيود؛ ليس API إنتاجيًا أو تعديل جلسة.
create function r6c01_probe.c01_debt_fixture(f jsonb,new_total bigint) returns void language plpgsql as $$
declare old_total bigint;j uuid;delta bigint;
begin
 select total_minor into old_total from billing.invoices where id=(f->>'invoice')::uuid;
 delta:=abs(new_total-old_total);
 update billing.invoices set total_minor=new_total,subtotal_minor=new_total,
 paid_minor=least(paid_minor,new_total),outstanding_minor=new_total-least(paid_minor,new_total)
 where id=(f->>'invoice')::uuid;
 if delta=0 then return;end if;
 insert into finance.journal_entries(tenant_id,well_id,public_code,entry_date,source_type,source_id,description,idempotency_key)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,core.generate_public_code('JE'),(f->>'at')::timestamptz,
 'fixture_debt_correction',gen_random_uuid(),'تجهيز حقيقة مالية مصححة','FIXTURE-'||gen_random_uuid()::text) returning id into j;
 insert into finance.journal_lines(tenant_id,journal_entry_id,ledger_account_id,entry_side,amount_minor,farmer_well_account_id)
 values((f->>'tenant')::uuid,j,finance.ledger_account_id((f->>'well')::uuid,'1100'),
 case when new_total>old_total then 'debit' else 'credit' end,delta,(f->>'account')::uuid),
 ((f->>'tenant')::uuid,j,finance.ledger_account_id((f->>'well')::uuid,'4000'),
 case when new_total>old_total then 'credit' else 'debit' end,delta,(f->>'account')::uuid);
 perform finance.post_journal_entry(j,(f->>'operator')::uuid);
end;$$;
-- إنشاء تطبيق أصلي صحيح عبر أدوات C0؛ لا تلاعب بتاريخ الدفع/التطبيق.
create function r6c01_probe.c01_applied() returns jsonb language plpgsql as $$
declare f jsonb;r jsonb;i uuid;a jsonb;
begin
 f:=r6c01_probe.c01_fixture();r:=r6c01_probe.c01_release(f,2000,gen_random_uuid());
 i:=r6c01_probe.c01_invoice(f,2000);
 a:=r6c01_probe.c01_apply((r->>'credit_id')::uuid,i,2000,gen_random_uuid(),(f->>'at')::timestamptz);
 return f||jsonb_build_object('original_invoice',f->'invoice','invoice',i,'credit',r->'credit_id','application',a->'application_id');
end;$$;
create function r6c01_probe.c01_adjust(f jsonb,operation text,amount bigint,source uuid) returns jsonb language sql as $$
 select billing.adjust_credit_application((f->>'application')::uuid,operation,amount,source,1,
 'سبب محفوظ  ',(f->>'at')::timestamptz);
$$;

create table r6c01_probe.fixtures(case_id integer primary key,f jsonb,source_id uuid);
create function r6c01_probe.adjust_attempt(f jsonb,operation text,amount bigint,source uuid) returns jsonb language plpgsql as $$
begin
 perform set_config('request.jwt.claim.sub',f->>'operator',true);
 return r6c01_probe.c01_adjust(f,operation,amount,source);
exception when check_violation or invalid_transaction_state then
 return jsonb_build_object('status','denied','sqlstate',SQLSTATE);end;$$;
create function r6c01_probe.spend_attempt(f jsonb,amount bigint,source uuid) returns jsonb language plpgsql as $$
begin
 perform set_config('request.jwt.claim.sub',f->>'operator',true);
 return r6c01_probe.c01_apply((f->>'credit')::uuid,(f->>'spend_invoice')::uuid,amount,source,(f->>'at')::timestamptz);
exception when check_violation then return jsonb_build_object('status','denied','sqlstate',SQLSTATE);end;$$;
do $$declare f jsonb;n integer;begin
 for n in 1..4 loop
  f:=r6c01_probe.c01_applied();
  if n in (1,3) then perform r6c01_probe.c01_adjust(f,'release',1000,gen_random_uuid());end if;
  if n=2 then f:=f||jsonb_build_object('spend_invoice',r6c01_probe.c01_invoice(f,1001));end if;
  insert into r6c01_probe.fixtures values(n,f,gen_random_uuid());
 end loop;
end;$$;
create function r6c01_probe.barrier() returns trigger language plpgsql as $$
begin
 if new.status='accepted' and exists(select 1 from r6c01_probe.fixtures where f->>'well'=new.well_id::text) then
  perform pg_advisory_xact_lock(744601);end if;
 return new;
end;$$;
create trigger c01_concurrency_barrier after insert on billing.account_credit_application_adjustments
 for each row execute function r6c01_probe.barrier();
commit;
do $concurrency$
declare conn text;socket_dir text;ext_schema text;f jsonb;source uuid;n integer;
 qa text;qb text;pa integer;pb integer;deadline timestamptz;ra jsonb;rb jsonb;
begin
 select ns.nspname into ext_schema from pg_extension e join pg_namespace ns on ns.oid=e.extnamespace where e.extname='dblink';
 perform set_config('search_path',quote_ident(ext_schema)||',pg_catalog,r6c01_probe',true);
 socket_dir:=btrim(split_part(current_setting('unix_socket_directories'),',',1));
 if socket_dir not like '/%' then raise exception 'LOCAL_UNIX_SOCKET_REQUIRED';end if;
 conn:=format('host=%L port=%s dbname=%L user=%L',socket_dir,current_setting('port'),current_database(),current_user);
 for n in 1..4 loop
  select x.f,x.source_id into f,source from r6c01_probe.fixtures x where case_id=n;
  perform dblink_connect('c01_a',conn);perform dblink_connect('c01_b',conn);
  perform dblink_exec('c01_a','set session characteristics as transaction isolation level read committed');
  perform dblink_exec('c01_b','set session characteristics as transaction isolation level read committed');
  select pid into pa from dblink('c01_a','select pg_backend_pid()')as t(pid integer);
  select pid into pb from dblink('c01_b','select pg_backend_pid()')as t(pid integer);
  if n=1 then
   qa:=format('select r6c01_probe.adjust_attempt(%L::jsonb,%L,800,%L::uuid)',f::text,'release',source);
   qb:=format('select r6c01_probe.adjust_attempt(%L::jsonb,%L,800,%L::uuid)',f::text,'release',gen_random_uuid());
  elsif n=2 then
   qa:=format('select r6c01_probe.adjust_attempt(%L::jsonb,%L,1000,%L::uuid)',f::text,'release',source);
   qb:=format('select r6c01_probe.spend_attempt(%L::jsonb,1000,%L::uuid)',f::text,gen_random_uuid());
  elsif n=3 then
   qa:=format('select r6c01_probe.adjust_attempt(%L::jsonb,%L,800,%L::uuid)',f::text,'restore',source);
   qb:=format('select r6c01_probe.adjust_attempt(%L::jsonb,%L,800,%L::uuid)',f::text,'restore',gen_random_uuid());
  else
   qa:=format('select r6c01_probe.adjust_attempt(%L::jsonb,%L,500,%L::uuid)',f::text,'release',source);qb:=qa;
  end if;
  if n=1 then
   perform dblink_exec('c01_a','begin isolation level repeatable read');
   select result into ra from dblink('c01_a',qa)as t(result jsonb);
   perform dblink_exec('c01_a','rollback');
   perform r6c01_probe.c01_check(ra->>'status'='denied' and ra->>'sqlstate'='25000',
    'stale snapshot isolation rejected before any adjustment');
  end if;
  perform pg_advisory_lock(744601);perform dblink_send_query('c01_a',qa);
  deadline:=clock_timestamp()+interval '10 seconds';
  loop
   perform pg_stat_clear_snapshot();
   exit when exists(select 1 from pg_stat_activity where pid=pa and wait_event='advisory');
   if clock_timestamp()>deadline then raise exception 'FIRST_REAL_TRANSACTION_BARRIER_NOT_REACHED';end if;
   perform pg_sleep(0.01);
  end loop;
  perform dblink_send_query('c01_b',qb);deadline:=clock_timestamp()+interval '10 seconds';
  loop
   perform pg_stat_clear_snapshot();
   exit when pa=any(pg_blocking_pids(pb));
   if clock_timestamp()>deadline then raise exception 'SECOND_TRANSACTION_NOT_BLOCKED_BY_FIRST';end if;
   perform pg_sleep(0.01);
  end loop;
  perform pg_advisory_unlock(744601);
  select result into ra from dblink_get_result('c01_a')as t(result jsonb);
  select result into rb from dblink_get_result('c01_b')as t(result jsonb);
  perform r6c01_probe.c01_check(ra->>'status'='accepted','first real adjustment accepted');
  if n in (1,3) then
   perform r6c01_probe.c01_check(rb->>'status'='denied','competing adjustment exceeds remaining capacity');
  elsif n=2 then
   perform r6c01_probe.c01_check(rb->>'status'='accepted','spend waits for release commit and consumes once');
  else
   perform r6c01_probe.c01_check(rb=ra,'racing replay returns exact persisted result');
  end if;
  if n=1 then
   perform r6c01_probe.c01_check((select effective_amount_minor=200 from billing.effective_account_credit_applications
    where id=(f->>'application')::uuid),'AG concurrent release cannot over release');
  elsif n=2 then
   perform r6c01_probe.c01_check((select available_minor=0 and used_minor=2000 from billing.account_credit_balances
    where id=(f->>'credit')::uuid),'AH released credit consumed exactly once without negative balance');
   perform r6c01_probe.c01_check(r6c01_probe.spend_attempt(f,1,gen_random_uuid())->>'status'='denied',
    'AH newly released value cannot be spent again');
  elsif n=3 then
   perform r6c01_probe.c01_check((select effective_amount_minor=1800 from billing.effective_account_credit_applications
    where id=(f->>'application')::uuid),'AI concurrent restore stays below original amount');
  else
   perform r6c01_probe.c01_check((select count(*)=1 from billing.account_credit_application_adjustments
    where application_id=(f->>'application')::uuid and operation='release')
    and (select count(*)=1 from finance.journal_entries where source_type='customer_credit' and source_id=(ra->>'event_id')::uuid),
    'AJ racing replay has one adjustment and one journal');
  end if;
  perform dblink_disconnect('c01_a');perform dblink_disconnect('c01_b');
 end loop;
exception when others then
 perform pg_advisory_unlock(744601);
 begin perform dblink_disconnect('c01_a');exception when others then null;end;
 begin perform dblink_disconnect('c01_b');exception when others then null;end;
 raise;
end;$concurrency$;
