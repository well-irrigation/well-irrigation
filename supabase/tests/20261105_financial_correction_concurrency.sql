\set ON_ERROR_STOP on
-- OWNER ONLY: قاعدة محلية قابلة للمحو؛ التجهيز يُحفظ كي يراه اتصالان مستقلان.
-- لا يضاف إلى db:test؛ بعده يعيد المالك بناء قاعدة الاختبار، ولا نمحو التاريخ لتنظيفه.
-- يلزم SET r6c0.disposable_database='yes' قبل تشغيل الملف يدويًا.
do $$begin
 if current_setting('r6c0.disposable_database',true) is distinct from 'yes'
  or not (select rolsuper from pg_roles where rolname=current_user) then
  raise exception 'R6C0_OWNER_DISPOSABLE_LOCAL_DATABASE_REQUIRED';end if;
end;$$;
begin;
create extension if not exists dblink with schema extensions;
create schema r6c0_probe;
create function r6c0_probe.c0_check(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL %',label;end if;
 raise notice 'PASS %',label;end;$$;
create function r6c0_probe.c0_fixture(p_total bigint default 10000,p_paid bigint default 10000)
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
create function r6c0_probe.c0_release(f jsonb,amount bigint,source uuid,revision bigint default 1) returns jsonb
language sql as $$select billing.release_payment_allocation((f->>'allocation')::uuid,amount,source,revision,
 'سبب اختبار محفوظ  ',(f->>'at')::timestamptz);$$;
create function r6c0_probe.c0_apply(credit uuid,invoice uuid,amount bigint,source uuid,at_time timestamptz) returns jsonb
language sql as $$select billing.apply_account_credit(credit,invoice,amount,source,1,'تطبيق رصيد',at_time);$$;
create function r6c0_probe.c0_cash_snapshot(w uuid) returns jsonb language sql as $$
 select jsonb_build_object('payments',(select jsonb_agg(to_jsonb(p) order by id) from billing.payments p where p.well_id=w),
 'cash',(select jsonb_agg(to_jsonb(l) order by l.id) from finance.journal_lines l join finance.journal_entries e on e.id=l.journal_entry_id
 where e.well_id=w and l.cashbox_id is not null),'receipts',(select jsonb_agg(to_jsonb(c) order by c.id) from sync.processed_commands c
 where c.tenant_id=(select tenant_id from core.wells where id=w)));
$$;
create function r6c0_probe.c0_invoice(f jsonb,amount bigint) returns uuid language plpgsql as $$
declare i uuid;
begin
 insert into billing.invoices(tenant_id,public_code,well_id,farmer_well_account_id,invoice_date,status,
 subtotal_minor,total_minor,paid_minor,outstanding_minor)
 values((f->>'tenant')::uuid,core.generate_public_code('INV'),(f->>'well')::uuid,(f->>'account')::uuid,
 (f->>'at')::timestamptz,'draft',amount,amount,0,amount) returning id into i;
 update billing.invoices set status='issued' where id=i;return i;
end;$$;

create table r6c0_probe.fixtures(case_id integer primary key,f jsonb,source_id uuid);
create function r6c0_probe.release_attempt(f jsonb,amount bigint,source uuid) returns jsonb language plpgsql as $$
begin
 perform set_config('request.jwt.claim.sub',f->>'operator',true);
 return r6c0_probe.c0_release(f,amount,source);
exception when check_violation then return jsonb_build_object('status','denied','sqlstate',SQLSTATE);end;$$;
create function r6c0_probe.apply_attempt(f jsonb,amount bigint,source uuid) returns jsonb language plpgsql as $$
begin
 perform set_config('request.jwt.claim.sub',f->>'operator',true);
 return r6c0_probe.c0_apply((f->>'credit')::uuid,(f->>'invoice')::uuid,amount,source,(f->>'at')::timestamptz);
exception when check_violation then return jsonb_build_object('status','denied','sqlstate',SQLSTATE);end;$$;
do $$declare f jsonb;r jsonb;n integer;begin
 for n in 1..3 loop
  f:=r6c0_probe.c0_fixture();
  if n=2 then
   r:=r6c0_probe.c0_release(f,2000,gen_random_uuid());f:=f||jsonb_build_object('credit',r->'credit_id');
  end if;
  insert into r6c0_probe.fixtures values(n,f,gen_random_uuid());
 end loop;
end;$$;
create function r6c0_probe.barrier() returns trigger language plpgsql as $$
begin
 if exists(select 1 from r6c0_probe.fixtures where f->>'well'=new.well_id::text) then
  perform pg_advisory_xact_lock(744600);end if;
 return new;
end;$$;
create trigger c0_concurrency_barrier after insert on billing.payment_allocation_adjustments
 for each row execute function r6c0_probe.barrier();
create trigger c0_concurrency_barrier after insert on billing.account_credit_applications
 for each row execute function r6c0_probe.barrier();
commit;
do $concurrency$
declare conn text;socket_dir text;ext_schema text;f jsonb;source uuid;n integer;
 qa text;qb text;pa integer;pb integer;deadline timestamptz;ra jsonb;rb jsonb;
begin
 select ns.nspname into ext_schema from pg_extension e join pg_namespace ns on ns.oid=e.extnamespace where e.extname='dblink';
 perform set_config('search_path',quote_ident(ext_schema)||',pg_catalog,r6c0_probe',true);
 socket_dir:=btrim(split_part(current_setting('unix_socket_directories'),',',1));
 if socket_dir not like '/%' then raise exception 'LOCAL_UNIX_SOCKET_REQUIRED';end if;
 conn:=format('host=%L port=%s dbname=%L user=%L',socket_dir,current_setting('port'),current_database(),current_user);
 for n in 1..3 loop
  select x.f,x.source_id into f,source from r6c0_probe.fixtures x where case_id=n;
  perform dblink_connect('c0_a',conn);perform dblink_connect('c0_b',conn);
  select pid into pa from dblink('c0_a','select pg_backend_pid()')as t(pid integer);
  select pid into pb from dblink('c0_b','select pg_backend_pid()')as t(pid integer);
  if n=1 then
   qa:=format('select r6c0_probe.release_attempt(%L::jsonb,6000,%L::uuid)',f::text,source);
   qb:=format('select r6c0_probe.release_attempt(%L::jsonb,6000,%L::uuid)',f::text,gen_random_uuid());
  elsif n=2 then
   qa:=format('select r6c0_probe.apply_attempt(%L::jsonb,1500,%L::uuid)',f::text,source);
   qb:=format('select r6c0_probe.apply_attempt(%L::jsonb,1500,%L::uuid)',f::text,gen_random_uuid());
  else
   qa:=format('select r6c0_probe.release_attempt(%L::jsonb,2000,%L::uuid)',f::text,source);qb:=qa;
  end if;
  perform pg_advisory_lock(744600);perform dblink_send_query('c0_a',qa);
  deadline:=clock_timestamp()+interval '10 seconds';
  loop
   perform pg_stat_clear_snapshot();
   exit when exists(select 1 from pg_stat_activity where pid=pa and wait_event='advisory');
   if clock_timestamp()>deadline then raise exception 'FIRST_REAL_TRANSACTION_BARRIER_NOT_REACHED';end if;
   perform pg_sleep(0.01);
  end loop;
  perform dblink_send_query('c0_b',qb);deadline:=clock_timestamp()+interval '10 seconds';
  loop
   perform pg_stat_clear_snapshot();
   exit when pa=any(pg_blocking_pids(pb));
   if clock_timestamp()>deadline then raise exception 'SECOND_TRANSACTION_NOT_BLOCKED_BY_FIRST';end if;
   perform pg_sleep(0.01);
  end loop;
  perform pg_advisory_unlock(744600);
  select result into ra from dblink_get_result('c0_a')as t(result jsonb);
  select result into rb from dblink_get_result('c0_b')as t(result jsonb);
  perform r6c0_probe.c0_check(ra->>'status'='accepted','first concurrent financial effect accepted');
  if n<3 then perform r6c0_probe.c0_check(rb->>'status'='denied','second concurrent spend/release rejected');
  else perform r6c0_probe.c0_check(rb=ra,'racing replay returns exact persisted effect');end if;
  if n=1 then
   perform r6c0_probe.c0_check((select effective_allocated_minor=4000 from billing.effective_payment_allocations
    where id=(f->>'allocation')::uuid),'F real concurrent releases cannot over release');
  elsif n=2 then
   perform r6c0_probe.c0_check((select available_minor=500 and used_minor=1500 from billing.account_credit_balances
    where id=(f->>'credit')::uuid),'O real concurrent applications cannot double spend');
  else
   perform r6c0_probe.c0_check((select count(*)=1 from billing.account_credits where well_id=(f->>'well')::uuid),
    'AI racing replay creates one credit and one release');
  end if;
  perform dblink_disconnect('c0_a');perform dblink_disconnect('c0_b');
 end loop;
exception when others then
 perform pg_advisory_unlock(744600);
 begin perform dblink_disconnect('c0_a');exception when others then null;end;
 begin perform dblink_disconnect('c0_b');exception when others then null;end;
 raise;
end;$concurrency$;
