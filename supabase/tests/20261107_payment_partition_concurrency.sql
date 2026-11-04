\set ON_ERROR_STOP on
-- OWNER ONLY: اتصالان مستقلان، Unix socket، قاعدة قابلة للمحو، ثم إعادة بنائها.
set session characteristics as transaction isolation level read committed;
do $$begin
 if current_setting('r6c02_partition.disposable_database',true) is distinct from 'yes'
  or not (select rolsuper from pg_roles where rolname=current_user) then
  raise exception 'PAYMENT_PARTITION_OWNER_DISPOSABLE_LOCAL_REQUIRED';end if;
end;$$;
begin;
create extension if not exists dblink with schema extensions;
create schema payment_partition_probe;
create function payment_partition_probe.pp_check(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL %',label;end if;raise notice 'PASS %',label;end;$$;
create function payment_partition_probe.pp_base(p_tenant uuid default null,p_actor uuid default null)
returns jsonb language plpgsql as $$
declare t uuid:=p_tenant; op uuid:=coalesce(p_actor,gen_random_uuid()); p uuid; fp uuid;
 w uuid; a uuid; f uuid; pump uuid; b uuid; cmd uuid:=gen_random_uuid();
 at_time timestamptz:=date_trunc('day',transaction_timestamp())-interval '4 hours';
begin
 if t is null then insert into core.tenants(name) values('إقرار تشغيل') returning id into t;end if;
 insert into auth.users(id,instance_id,aud,role,email,email_confirmed_at,created_at,updated_at)
 values(op,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',op||'@r6b.test',now(),now(),now())
 on conflict(id) do nothing;
 insert into iam.profiles(id,full_name) values(op,'مشغل إقرار') on conflict(id) do nothing;
 insert into core.wells(tenant_id,name) values(t,'بئر إقرار') returning id into w;
 insert into core.well_assignments(well_id,profile_id,role,status) values(w,op,'operator','active');
 insert into core.persons(tenant_id,full_name,normalized_name) values(t,'مزارع إقرار','مزارع إقرار') returning id into p;
 insert into ops.farmer_profiles(tenant_id,person_id) values(t,p) returning id into fp;
 insert into ops.farmer_well_accounts(tenant_id,farmer_profile_id,well_id,public_code)
 values(t,fp,w,'RB-'||substr(cmd::text,1,8)) returning id into a;
 insert into ops.farms(well_id,name,farmer_well_account_id) values(w,'أرض الإقرار',a) returning id into f;
 insert into core.pumps(well_id,name,power_source,status) values(w,'مضخة الإقرار','diesel','active') returning id into pump;
 insert into billing.well_pricing(well_id,price_per_hour_minor,period_start) values(w,3600,date '1970-01-01');
 insert into ops.shifts(tenant_id,well_id,operator_profile_id,started_at,status)
 values(t,w,op,at_time-interval '1 hour','open');
 insert into ops.irrigation_bookings(tenant_id,public_code,well_id,farmer_well_account_id,farm_id,
 scheduled_start,scheduled_end,expected_duration_minutes,expected_energy_source,status,created_by)
 values(t,'RB-'||substr(cmd::text,1,8),w,a,f,at_time+interval '30 minutes',at_time+interval '60 minutes',30,'well_diesel','confirmed',op)
 returning id into b;
 return jsonb_build_object('tenant',t,'operator',op,'well',w,'account',a,'farm',f,'pump',pump,
   'booking',b,'at',at_time,'command',cmd);
end;$$;
create function payment_partition_probe.pp_start(f jsonb,kind text default 'start_operational_session',
 booking uuid default null,identified boolean default true) returns uuid language plpgsql as $$
declare sid uuid; cmd uuid:=case when identified then (f->>'command')::uuid end;
begin
 perform set_config('request.jwt.claim.sub',f->>'operator',true);
 execute 'set local role authenticated';
 if kind='start_operational_session' then
  sid:=api.start_operational_session((f->>'well')::uuid,(f->>'pump')::uuid,(f->>'farm')::uuid,
   (f->>'account')::uuid,'well_diesel',(f->>'at')::timestamptz,cmd,null,array['قمح'],booking);
 elsif kind='start_irrigation_session' then
  sid:=api.start_irrigation_session((f->>'well')::uuid,(f->>'pump')::uuid,(f->>'farm')::uuid,
   (f->>'account')::uuid,'well_diesel',(f->>'at')::timestamptz,null,cmd,array['قمح']);
 elsif kind='start_adhoc_session' then
  sid:=api.start_adhoc_session((f->>'well')::uuid,(f->>'pump')::uuid,(f->>'farm')::uuid,
   (f->>'account')::uuid,'well_diesel',null,(f->>'at')::timestamptz,null,cmd,array['قمح']);
 else raise exception 'unknown test start';end if;
 execute 'reset role';return sid;
exception when others then execute 'reset role';raise;
end;$$;
create function payment_partition_probe.pp_cash(w uuid) returns jsonb language sql as $$
 select jsonb_build_object('payments',(select jsonb_agg(to_jsonb(p) order by id) from billing.payments p where p.well_id=w),
 'cash',(select jsonb_agg(to_jsonb(l) order by l.id) from finance.journal_lines l join finance.journal_entries e on e.id=l.journal_entry_id
 where e.well_id=w and l.cashbox_id is not null),'receipts',(select jsonb_agg(to_jsonb(c) order by c.id) from sync.processed_commands c
 where c.tenant_id=(select tenant_id from core.wells where id=w)));
$$;

create function payment_partition_probe.pp_fixture(amount bigint default 10000,allocated bigint default 2000) returns jsonb language plpgsql as $$
declare f jsonb;g jsonb;sida uuid;sidb uuid;ra jsonb;rb jsonb;pay jsonb;invoice uuid;allocation uuid;person uuid;partner uuid;
begin
 f:=payment_partition_probe.pp_base();f:=f||jsonb_build_object('at',(f->>'at')::timestamptz-interval '1 day');
 update ops.shifts set started_at=(f->>'at')::timestamptz-interval '1 hour' where well_id=(f->>'well')::uuid;
 sida:=payment_partition_probe.pp_start(f);
 execute 'set local role authenticated';
 ra:=api.complete_irrigation_session(p_session_id=>sida,p_ended_at=>(f->>'at')::timestamptz+(amount::text||' seconds')::interval,p_command_id=>gen_random_uuid());
 execute 'reset role';
 g:=f||jsonb_build_object('command',gen_random_uuid(),'at',(f->>'at')::timestamptz+interval '4 hours');
 sidb:=payment_partition_probe.pp_start(g);
 execute 'set local role authenticated';
 rb:=api.complete_irrigation_session(p_session_id=>sidb,p_ended_at=>(g->>'at')::timestamptz+(amount::text||' seconds')::interval,p_command_id=>gen_random_uuid());
 invoice:=api.issue_session_invoice(sidb);
 pay:=api.record_payment(p_well_id=>(f->>'well')::uuid,p_farmer_well_account_id=>(f->>'account')::uuid,
  p_amount_minor=>amount,p_method=>'cash',p_session_charge_id=>(ra->>'session_charge_id')::uuid,
  p_paid_at=>(g->>'at')::timestamptz+(amount::text||' seconds')::interval,p_command_id=>gen_random_uuid());
 if allocated>0 then
  perform api.allocate_payment((pay->>'payment_id')::uuid,jsonb_build_array(jsonb_build_object('invoice_id',invoice,'amount_minor',allocated)));
 end if;
 execute 'reset role';
 select id into allocation from billing.payment_allocations where payment_id=(pay->>'payment_id')::uuid and invoice_id=invoice;
 select fp.person_id into person from ops.farmer_profiles fp join ops.farmer_well_accounts a on a.farmer_profile_id=fp.id where a.id=(f->>'account')::uuid;
 insert into core.well_partners(tenant_id,well_id,person_id,phone,period_start)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,person,'777777777',date '1970-01-01') returning id into partner;
 insert into core.ownership_share_versions(tenant_id,well_id,partner_id,ownership_percentage,profit_percentage,effective_period)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,partner,100,100,daterange(date '1970-01-01',null,'[)'));
 return f||jsonb_build_object('session_a',sida,'session_b',sidb,'charge_a',ra->'session_charge_id','charge_b',rb->'session_charge_id',
  'invoice_b',invoice,'payment',pay->'payment_id','allocation',allocation,'receipt',pay);
exception when others then execute 'reset role';raise;
end;$$;
create function payment_partition_probe.pp_release(f jsonb,amount bigint,source uuid) returns jsonb language sql as $$
 select billing.release_payment_allocation((f->>'allocation')::uuid,amount,source,1,'سبب محفوظ  ',(f->>'at')::timestamptz);
$$;
create function payment_partition_probe.pp_restore(f jsonb,amount bigint,source uuid) returns jsonb language sql as $$
 select billing.restore_payment_allocation((f->>'allocation')::uuid,amount,source,1,'استعادة نقل',(f->>'at')::timestamptz);
$$;
create function payment_partition_probe.pp_debt(f jsonb,amount bigint) returns void language sql as $$
 -- تجهيز دين مصحح فقط؛ لا مسار تصحيح جلسة في الإنتاج.
 update billing.session_charges set amount_minor=amount where id=(f->>'charge_a')::uuid;
$$;
create function payment_partition_probe.pp_conserved(f jsonb) returns boolean language sql as $$
 select least(explicit_allocated_minor,effective_direct_minor,credit_backed_minor,remaining_minor)>=0
  and explicit_allocated_minor+effective_direct_minor+credit_backed_minor+remaining_minor=amount_minor
 from billing.payment_economic_applications where payment_id=(f->>'payment')::uuid;
$$;

create table payment_partition_probe.fixtures(case_id integer primary key,f jsonb,source_id uuid);
create function payment_partition_probe.attempt(f jsonb,kind text,amount bigint,source uuid) returns jsonb language plpgsql as $$
declare credit uuid;
begin
 perform set_config('request.jwt.claim.sub',f->>'operator',true);
 if kind='release' then return payment_partition_probe.pp_release(f,amount,source);
 elsif kind='restore' then return payment_partition_probe.pp_restore(f,amount,source);
 elsif kind='correction' then
  -- تجهيز مالك فقط يحاكي تغير الدين في معاملة الكاتب المستقبلية؛ ليس API تصحيح جلسة.
  perform billing.lock_customer_credit_well((f->>'well')::uuid);
  perform payment_partition_probe.pp_debt(f,8000);
  return billing.rebalance_payment_capacity((f->>'payment')::uuid,source,1,'دين مصحح في التجهيز',(f->>'at')::timestamptz);
 elsif kind='rebalance' then return billing.rebalance_payment_capacity((f->>'payment')::uuid,source,1,'توزيع المتبقي',(f->>'at')::timestamptz);
 elsif kind='spend' then
  perform billing.lock_customer_credit_well((f->>'well')::uuid);
  select id into strict credit from billing.account_credits where payment_id=(f->>'payment')::uuid;
  return billing.apply_account_credit(credit,(f->>'invoice_b')::uuid,amount,source,1,'استخدام متزامن',(f->>'at')::timestamptz);
 elsif kind='default_use' then
  return billing.allocate_payment((f->>'payment')::uuid,jsonb_build_array(jsonb_build_object('invoice_id',(f->>'invoice_a')::uuid,'amount_minor',amount)))
   ||jsonb_build_object('status','accepted');
 else raise exception 'unknown race';end if;
exception when check_violation then return jsonb_build_object('status','denied','sqlstate',SQLSTATE);end;$$;
do $$declare f jsonb;r jsonb;n integer;invoice uuid;begin
 for n in 1..7 loop
  f:=payment_partition_probe.pp_fixture(10000,case when n=4 then 0 else 2000 end);
  if n in (3,4,5) then perform payment_partition_probe.pp_debt(f,8000);end if;
  if n in (2,7) then
   perform payment_partition_probe.pp_release(f,2000,gen_random_uuid());
   if n=2 then
    invoice:=billing.issue_session_invoice((f->>'session_a')::uuid,(f->>'operator')::uuid);
    f:=f||jsonb_build_object('invoice_a',invoice);
   end if;
  end if;
  insert into payment_partition_probe.fixtures values(n,f,gen_random_uuid());
 end loop;
end;$$;
create function payment_partition_probe.barrier() returns trigger language plpgsql as $$
begin
 if exists(select 1 from payment_partition_probe.fixtures where f->>'well'=new.well_id::text) then
  perform pg_advisory_xact_lock(744604);end if;return new;
end;$$;
create trigger partition_race_barrier after insert on billing.payment_repartition_events
 for each row execute function payment_partition_probe.barrier();
commit;
do $concurrency$
declare conn text;socket_dir text;ext_schema text;f jsonb;source uuid;n integer;
 qa text;qb text;pa integer;pb integer;deadline timestamptz;ra jsonb;rb jsonb;
begin
 select ns.nspname into ext_schema from pg_extension e join pg_namespace ns on ns.oid=e.extnamespace where e.extname='dblink';
 perform set_config('search_path',quote_ident(ext_schema)||',pg_catalog,payment_partition_probe',true);
 socket_dir:=btrim(split_part(current_setting('unix_socket_directories'),',',1));
 if socket_dir not like '/%' then raise exception 'LOCAL_UNIX_SOCKET_REQUIRED';end if;
 conn:=format('host=%L port=%s dbname=%L user=%L',socket_dir,current_setting('port'),current_database(),current_user);
 for n in 1..7 loop
  select x.f,x.source_id into f,source from payment_partition_probe.fixtures x where case_id=n;
  perform dblink_connect('partition_a',conn);perform dblink_connect('partition_b',conn);
  perform dblink_exec('partition_a','set session characteristics as transaction isolation level read committed');
  perform dblink_exec('partition_b','set session characteristics as transaction isolation level read committed');
  select pid into pa from dblink('partition_a','select pg_backend_pid()')as t(pid integer);
  select pid into pb from dblink('partition_b','select pg_backend_pid()')as t(pid integer);
  if n=1 then
   qa:=format('select payment_partition_probe.attempt(%L::jsonb,%L,2000,%L::uuid)',f::text,'release',source);
   qb:=format('select payment_partition_probe.attempt(%L::jsonb,%L,0,%L::uuid)',f::text,'correction',gen_random_uuid());
  elsif n=2 then
   qa:=format('select payment_partition_probe.attempt(%L::jsonb,%L,2000,%L::uuid)',f::text,'restore',source);
   qb:=format('select payment_partition_probe.attempt(%L::jsonb,%L,8000,%L::uuid)',f::text,'default_use',gen_random_uuid());
  elsif n=3 then
   qa:=format('select payment_partition_probe.attempt(%L::jsonb,%L,2000,%L::uuid)',f::text,'release',source);
   qb:=format('select payment_partition_probe.attempt(%L::jsonb,%L,2000,%L::uuid)',f::text,'spend',gen_random_uuid());
  elsif n=4 then
   qa:=format('select payment_partition_probe.attempt(%L::jsonb,%L,0,%L::uuid)',f::text,'rebalance',source);
   qb:=format('select payment_partition_probe.attempt(%L::jsonb,%L,0,%L::uuid)',f::text,'rebalance',gen_random_uuid());
  elsif n=5 then
   qa:=format('select payment_partition_probe.attempt(%L::jsonb,%L,2000,%L::uuid)',f::text,'release',source);qb:=qa;
  elsif n=6 then
   qa:=format('select payment_partition_probe.attempt(%L::jsonb,%L,1500,%L::uuid)',f::text,'release',source);
   qb:=format('select payment_partition_probe.attempt(%L::jsonb,%L,1500,%L::uuid)',f::text,'release',gen_random_uuid());
  else
   qa:=format('select payment_partition_probe.attempt(%L::jsonb,%L,1500,%L::uuid)',f::text,'restore',source);
   qb:=format('select payment_partition_probe.attempt(%L::jsonb,%L,1500,%L::uuid)',f::text,'restore',gen_random_uuid());
  end if;
  perform pg_advisory_lock(744604);perform dblink_send_query('partition_a',qa);
  deadline:=clock_timestamp()+interval '10 seconds';
  loop
   perform pg_stat_clear_snapshot();
   exit when exists(select 1 from pg_stat_activity where pid=pa and wait_event='advisory');
   if clock_timestamp()>deadline then raise exception 'FIRST_REAL_TRANSACTION_BARRIER_NOT_REACHED';end if;
   perform pg_sleep(0.01);
  end loop;
  perform dblink_send_query('partition_b',qb);deadline:=clock_timestamp()+interval '10 seconds';
  loop
   perform pg_stat_clear_snapshot();
   exit when pa=any(pg_blocking_pids(pb));
   if clock_timestamp()>deadline then raise exception 'SECOND_TRANSACTION_NOT_BLOCKED_BY_FIRST';end if;
   perform pg_sleep(0.01);
  end loop;
  perform pg_advisory_unlock(744604);
  select result into ra from dblink_get_result('partition_a')as t(result jsonb);
  select result into rb from dblink_get_result('partition_b')as t(result jsonb);
  perform payment_partition_probe.pp_check(ra->>'status'='accepted','first actual transaction accepted');
  if n in (6,7) then
   perform payment_partition_probe.pp_check(rb->>'status'='denied','second operation cannot exceed released capacity');
  else
   perform payment_partition_probe.pp_check(rb->>'status'='accepted','second transaction observes committed partition');
  end if;
  perform payment_partition_probe.pp_check(payment_partition_probe.pp_conserved(f),'AL real concurrent partition conserves original cash value');
  if n=1 then
   perform payment_partition_probe.pp_check((select count(*)=1 and sum(amount_minor)=2000 from billing.account_credits where payment_id=(f->>'payment')::uuid),
    'AI release racing rebalance cannot issue duplicate credit');
  elsif n=2 then
   perform payment_partition_probe.pp_check((select explicit_allocated_minor=10000 and effective_direct_minor=0 and credit_backed_minor=0
    from billing.payment_economic_applications where payment_id=(f->>'payment')::uuid),'AJ restore racing direct-capacity transfer cannot double settle');
  elsif n=3 then
   perform payment_partition_probe.pp_check((select available_minor=0 and used_minor=2000 from billing.account_credit_balances where payment_id=(f->>'payment')::uuid),
    'AK release racing spend consumes new credit once');
  elsif n=4 then
   perform payment_partition_probe.pp_check((select count(*)=1 and sum(amount_minor)=2000 from billing.account_credits where payment_id=(f->>'payment')::uuid)
    and rb->>'credit_amount_minor'='0','AL two rebalances cannot both consume same remaining value');
  elsif n=5 then
   perform payment_partition_probe.pp_check(rb=ra and (select count(*)=1 from billing.payment_repartition_events where payment_id=(f->>'payment')::uuid)
    and (select count(*)=1 from billing.account_credits where payment_id=(f->>'payment')::uuid)
    and (select count(*)=1 from finance.journal_entries where source_type='customer_credit' and source_id=(ra->>'event_id')::uuid),
    'AM racing replay creates one allocation adjustment credit journal set');
  end if;
  perform dblink_disconnect('partition_a');perform dblink_disconnect('partition_b');
 end loop;
exception when others then
 perform pg_advisory_unlock(744604);
 begin perform dblink_disconnect('partition_a');exception when others then null;end;
 begin perform dblink_disconnect('partition_b');exception when others then null;end;
 raise;
end;$concurrency$;
