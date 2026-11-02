\set ON_ERROR_STOP on
-- ثلاثة اختبارات تزامن حقيقية عبر اتصالين Unix socket إلى قاعدة الاختبار نفسها.
-- OWNER ONLY: قاعدة محلية قابلة للمحو؛ تجهيز التزامن يحتاج COMMIT كي تراه جلستان.
-- لا يُشغّل ضمن الملفات rollback-only، ولا على السحابة/الإنتاج.
-- قبل تشغيل هذا الملف محليًا: SET r4.disposable_database = 'yes';
-- بعدها يعيد المالك قاعدة الاختبار إلى تجهيزها المعتاد. لا نحذف حقائق مقبولة لتسهيل التنظيف.
do $$begin
 if current_setting('r4.disposable_database',true) is distinct from 'yes'
    or not (select rolsuper from pg_roles where rolname=current_user) then
   raise exception 'R4_CONCURRENCY_REQUIRES_OWNER_DISPOSABLE_LOCAL_DATABASE'; end if;
end$$;
begin;
create extension if not exists dblink with schema extensions;
create schema r4_occurrence_probe;
create function r4_occurrence_probe.r4_check(ok boolean,label text) returns void language plpgsql as $$
begin
 if ok is distinct from true then raise exception 'FAIL %',label; end if;
 raise notice 'PASS %',label;
end;$$;
create function r4_occurrence_probe.r4_fixture() returns jsonb language plpgsql as $$
declare t uuid; p uuid; fp uuid; op uuid:=gen_random_uuid(); w uuid; a uuid; f uuid; pump uuid; b uuid;
 at_time timestamptz:=date_trunc('minute',transaction_timestamp())-interval '4 hours';
 cmd uuid:=gen_random_uuid(); local_id uuid:=gen_random_uuid(); req jsonb; tank uuid;
begin
 insert into core.tenants(name) values('اختبار عقد الواقعة') returning id into t;
 insert into core.persons(tenant_id,full_name,normalized_name) values(t,'مزارع واقعة','مزارع واقعة') returning id into p;
 insert into ops.farmer_profiles(tenant_id,person_id) values(t,p) returning id into fp;
 insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
 values(op,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',op||'@r4.test.local','',now(),now(),now());
 insert into iam.profiles(id,full_name) values(op,'مشغل واقعة') on conflict(id) do nothing;
 insert into core.wells(tenant_id,name) values(t,'بئر واقعة') returning id into w;
 insert into core.well_assignments(well_id,profile_id,role,status) values(w,op,'operator','active');
 insert into ops.farmer_well_accounts(tenant_id,farmer_profile_id,well_id,public_code)
 values(t,fp,w,'R4-'||substr(op::text,1,8)) returning id into a;
 insert into ops.farms(well_id,name,farmer_well_account_id) values(w,'أرض الواقعة',a) returning id into f;
 insert into core.pumps(well_id,name,power_source,status) values(w,'مضخة الواقعة','diesel','active') returning id into pump;
 insert into billing.well_pricing(well_id,price_per_hour_minor,period_start,period_end)
 values(w,3600,timestamptz '1970-01-01 UTC',transaction_timestamp()-interval '1 hour');
 insert into billing.well_pricing(well_id,price_per_hour_minor,period_start)
 values(w,7200,transaction_timestamp()-interval '1 hour');
 insert into ops.shifts(tenant_id,well_id,operator_profile_id,started_at,status)
 values(t,w,op,transaction_timestamp()-interval '1 hour','open');
 insert into ops.irrigation_bookings(tenant_id,public_code,well_id,farmer_well_account_id,farm_id,
 scheduled_start,scheduled_end,expected_duration_minutes,expected_energy_source,status,created_by)
 values(t,'R4-'||substr(op::text,1,8),w,a,f,at_time+interval '30 minutes',at_time+interval '60 minutes',30,'well_diesel','confirmed',op)
 returning id into b;
 insert into inventory.fuel_tanks(tenant_id,well_id,name,current_balance_ml)
 values(t,w,'خزان الواقعة',1000000) returning id into tank;
 req:=jsonb_build_object('version',1,'occurrence_command_id',cmd,'root_local_id',local_id,
 'requested_at',at_time,'reason','تأخير صريح لاختبار العقد',
 'expected_revision',(select operational_schedule_revision from core.wells where id=w),
 'start',jsonb_build_object('started_at',at_time,'pump_id',pump,'farm_id',f,
 'farmer_well_account_id',a,'energy_source','well_diesel','planned_duration_minutes',60,'crops',jsonb_build_array('قمح')),
 'delays',jsonb_build_array(jsonb_build_object('booking_id',b,'original_start',at_time+interval '30 minutes',
 'original_end',at_time+interval '60 minutes','scheduled_start',at_time+interval '60 minutes','scheduled_end',at_time+interval '90 minutes')));
 return jsonb_build_object('tenant',t,'operator',op,'well',w,'account',a,'farm',f,'pump',pump,'booking',b,
 'at',at_time,'command',cmd,'local',local_id,'request',req,'tank',tank);
end;$$;
create function r4_occurrence_probe.r4_group(f jsonb,request jsonb default null) returns jsonb language plpgsql as $$
declare r jsonb;
begin
 perform set_config('request.jwt.claim.sub',f->>'operator',true);
 execute 'set local role authenticated';
 r:=api.start_session_with_booking_delays((f->>'well')::uuid,(f->>'command')::uuid,coalesce(request,f->'request'));
 execute 'reset role'; return r;
exception when others then execute 'reset role'; raise;
end;$$;
create function r4_occurrence_probe.r4_settlement(f jsonb,rejected jsonb,events jsonb default '[]') returns jsonb language sql as $$
 select jsonb_build_object('version',1,'human_confirmed',true,'reason','حسم بشري للواقعة الأصلية',
 'occurrence_command_id',f->'command','original_rejected_request_id',f->'command',
 'original_rejected_result',rejected,'original_request_fingerprint',md5((f->'request')::text),
 'facts',jsonb_build_object('root_local_id',f->'local','start',f->'request'->'start','events',events,
 'completion',jsonb_build_object('command_id',gen_random_uuid(),'local_id',gen_random_uuid(),
 'occurred_at',(f->>'at')::timestamptz+interval '20 minutes',
 'payload',jsonb_build_object('p_session_id',jsonb_build_object('$ref',f->>'local','$kind','session')))));
$$;
create function r4_occurrence_probe.r4_settle(f jsonb,cmd uuid,request jsonb) returns jsonb language plpgsql as $$
declare r jsonb;
begin
 perform set_config('request.jwt.claim.sub',f->>'operator',true);
 execute 'set local role authenticated';
 r:=api.settle_operational_occurrence((f->>'well')::uuid,cmd,request);
 execute 'reset role'; return r;
exception when others then execute 'reset role'; raise;
end;$$;
create function r4_occurrence_probe.r4_snapshot(w uuid,p_commands boolean default false) returns jsonb language sql as $$
 select jsonb_build_object(
 'revision',(select operational_schedule_revision from core.wells where id=w),
 'commands',case when p_commands then (select jsonb_agg(to_jsonb(pc) order by pc.id) from sync.processed_commands pc where pc.tenant_id=(select tenant_id from core.wells where id=w)) end,
 'sessions',(select jsonb_agg(to_jsonb(s) order by id) from ops.irrigation_sessions s where well_id=w),
 'segments',(select jsonb_agg(to_jsonb(s) order by s.id) from ops.session_segments s join ops.irrigation_sessions x on x.id=s.session_id where x.well_id=w),
 'pumps',(select jsonb_agg(to_jsonb(p) order by id) from core.pumps p where well_id=w),
 'resources',(select jsonb_agg(to_jsonb(r) order by id) from ops.resource_reservations r where well_id=w),
 'occurrences',(select jsonb_agg(to_jsonb(o) order by occurrence_command_id) from ops.operational_occurrences o where well_id=w),
 'charges',(select jsonb_agg(to_jsonb(c) order by id) from billing.session_charges c where well_id=w),
 'bookings',(select jsonb_agg(to_jsonb(b) order by id) from ops.irrigation_bookings b where well_id=w));
$$;

create table r4_occurrence_probe.fixtures(case_id integer primary key,f jsonb,request jsonb,settlement_id uuid);
do $setup$
declare f jsonb; r jsonb; req jsonb; i integer;
begin
 for i in 1..3 loop
   f:=r4_occurrence_probe.r4_fixture();
   if i>1 then
     f:=jsonb_set(f,'{request,expected_revision}','-1');
     r:=r4_occurrence_probe.r4_group(f);
     if r->>'status'<>'rejected' then raise exception 'concurrency_fixture_rejection_missing'; end if;
     req:=r4_occurrence_probe.r4_settlement(f,r);
   end if;
   insert into r4_occurrence_probe.fixtures values(i,f,req,gen_random_uuid());
 end loop;
end;$setup$;
create function r4_occurrence_probe.barrier() returns trigger language plpgsql as $$
begin
 if exists(select 1 from r4_occurrence_probe.fixtures where f->>'well'=new.well_id::text) then
   perform pg_advisory_xact_lock(744137);
 end if;
 return new;
end;$$;
create trigger r4_concurrency_barrier after insert on ops.irrigation_sessions
 for each row execute function r4_occurrence_probe.barrier();
commit;

do $concurrency$
declare connection text; socket_dir text; extension_schema text; f jsonb; req jsonb; cmd uuid;
 query_a text; query_b text; pid_a integer; pid_b integer; deadline timestamptz; r jsonb; i integer; failed boolean;
begin
 select n.nspname into extension_schema from pg_extension e join pg_namespace n on n.oid=e.extnamespace where e.extname='dblink';
 perform set_config('search_path',quote_ident(extension_schema)||',pg_catalog,r4_occurrence_probe',true);
 socket_dir:=btrim(split_part(current_setting('unix_socket_directories'),',',1));
 if socket_dir='' or socket_dir not like '/%' then raise exception 'LOCAL_UNIX_SOCKET_REQUIRED'; end if;
 connection:=format('host=%L port=%s dbname=%L user=%L',socket_dir,current_setting('port'),current_database(),current_user);
 for i in 1..3 loop
   select x.f,x.request,x.settlement_id into f,req,cmd from r4_occurrence_probe.fixtures x where case_id=i;
   perform dblink_connect('r4_a',connection);perform dblink_connect('r4_b',connection);
   select pid into pid_a from dblink('r4_a','select pg_backend_pid()') as x(pid integer);
   select pid into pid_b from dblink('r4_b','select pg_backend_pid()') as x(pid integer);
   if i=1 then
     query_a:=format('select r4_occurrence_probe.r4_group(%L::jsonb)',f::text);query_b:=query_a;
   else
     query_a:=format('select r4_occurrence_probe.r4_settle(%L::jsonb,%L::uuid,%L::jsonb)',f::text,cmd,req::text);
     if i=2 then query_b:=query_a;
     else query_b:=format('select api.start_irrigation_session(%L::uuid,%L::uuid,%L::uuid,%L::uuid,''well_diesel'',%L::timestamptz,null,%L::uuid)',
       f->>'well',f->>'pump',f->>'farm',f->>'account',(f->>'at')::timestamptz+interval '5 minutes',gen_random_uuid());
       -- الهوية المصادقة في الاتصال الثاني قبل محاولة البدء العادي.
       perform dblink_exec('r4_b',format('set request.jwt.claim.sub=%L',f->>'operator'));
     end if;
   end if;
   perform pg_advisory_lock(744137);
   perform dblink_send_query('r4_a',query_a);
   deadline:=clock_timestamp()+interval '10 seconds';
   loop
     perform pg_stat_clear_snapshot();
     exit when exists(select 1 from pg_stat_activity where pid=pid_a and wait_event='advisory');
     if clock_timestamp()>deadline then raise exception 'REAL_CONTENTION_BARRIER_NOT_REACHED'; end if;
     perform pg_sleep(0.01);
   end loop;
   perform dblink_send_query('r4_b',query_b);
   -- المجموعة/التسوية الجديدة تنتظر وتعيد نفس النتيجة. الكاتب القديم يفشل NOWAIT.
   deadline:=clock_timestamp()+interval '10 seconds';
   if i<3 then
     loop
       perform pg_stat_clear_snapshot();
       exit when exists(select 1 from pg_stat_activity where pid=pid_b and wait_event_type='Lock');
       if clock_timestamp()>deadline then raise exception 'SECOND_REQUEST_DID_NOT_CONTEND'; end if;
       perform pg_sleep(0.01);
     end loop;
     perform pg_advisory_unlock(744137);
     select result into r from dblink_get_result('r4_a') as x(result jsonb);
     perform r4_occurrence_probe.r4_check(r->>'status'='accepted','first concurrent request accepted');
     perform r4_occurrence_probe.r4_check(
       (select result from dblink_get_result('r4_b') as x(result jsonb))=r,
       'same concurrent request returns exact persisted result');
   else
     while dblink_is_busy('r4_b')=1 loop
       if clock_timestamp()>deadline then raise exception 'COMPETING_WRITER_DID_NOT_FAIL_CLOSED'; end if;
       perform pg_sleep(0.01);
     end loop;
     failed:=false;
     begin perform * from dblink_get_result('r4_b') as x(id uuid);
     exception when lock_not_available then failed:=true;end;
     perform r4_occurrence_probe.r4_check(failed,'ordinary writer fails before unsafe mutation');
     perform pg_advisory_unlock(744137);
     select result into r from dblink_get_result('r4_a') as x(result jsonb);
     perform r4_occurrence_probe.r4_check(r->>'status'='accepted','first concurrent request accepted');
   end if;
   if i=1 then
     perform r4_occurrence_probe.r4_check(
       (select count(*) from ops.irrigation_sessions where well_id=(f->>'well')::uuid)=1
       and (select count(*) from sync.processed_commands where tenant_id=(f->>'tenant')::uuid and command_id=(f->>'command')::uuid and status='accepted')=1,
       'T03 concurrent same group one result session');
   elsif i=2 then
     perform r4_occurrence_probe.r4_check(
       (select count(*) from ops.irrigation_sessions where well_id=(f->>'well')::uuid and status='closed')=1
       and (select count(*) from billing.session_charges where well_id=(f->>'well')::uuid)=1,
       'T13 concurrent same settlement one terminal session charge');
   else
     perform set_config('request.jwt.claim.sub',f->>'operator',true);failed:=false;
     begin perform api.start_irrigation_session((f->>'well')::uuid,(f->>'pump')::uuid,(f->>'farm')::uuid,
       (f->>'account')::uuid,'well_diesel',(f->>'at')::timestamptz+interval '5 minutes',null,gen_random_uuid());
     exception when check_violation then failed:=SQLERRM='historical_interval_conflict';end;
     perform r4_occurrence_probe.r4_check(failed and
       (select count(*) from ops.irrigation_sessions where well_id=(f->>'well')::uuid)=1,
       'T29 ordinary backdated writer cannot race historical settlement');
   end if;
   perform dblink_disconnect('r4_a');perform dblink_disconnect('r4_b');
 end loop;
exception when others then
 perform pg_advisory_unlock_all();
 if 'r4_a'=any(coalesce(dblink_get_connections(),array[]::text[])) then perform dblink_disconnect('r4_a');end if;
 if 'r4_b'=any(coalesce(dblink_get_connections(),array[]::text[])) then perform dblink_disconnect('r4_b');end if;
 raise;
end;$concurrency$;
drop trigger r4_concurrency_barrier on ops.irrigation_sessions;
-- التجهيزات المقبولة تبقى في قاعدة الاختبار القابلة للمحو، لا تُمحى حقائق الإنتاج أو تُعطّل حراسها.
