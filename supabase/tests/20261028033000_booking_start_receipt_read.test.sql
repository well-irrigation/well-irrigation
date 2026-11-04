\set ON_ERROR_STOP on
-- اختبار محلي فقط. إدراج وقائع للاختبار داخل معاملة ملغاة، دون تنفيذ بدء.
begin;
set local timezone = 'UTC';
set local row_security = on;
create function pg_temp.start_receipt_check(ok boolean, label text)
returns void language plpgsql as $$
begin
  if ok is distinct from true then raise exception 'FAIL %', label; end if;
  raise notice 'PASS %', label;
end $$;
create function pg_temp.start_receipt_snapshot()
returns jsonb language sql as $$
 select jsonb_build_array(
  (select jsonb_agg(to_jsonb(c) order by c.id) from sync.processed_commands c),
  (select jsonb_agg(to_jsonb(s) order by s.id) from ops.irrigation_sessions s),
  (select jsonb_agg(to_jsonb(b) order by b.id) from ops.irrigation_bookings b),
  (select jsonb_agg(to_jsonb(c) order by c.id) from billing.session_charges c),
  (select jsonb_agg(to_jsonb(s) order by s.id) from ops.session_segments s),
  (select jsonb_agg(to_jsonb(j) order by j.id) from finance.journal_entries j)
 );
$$;
create function pg_temp.start_receipt_read(w uuid,b uuid,c uuid,t timestamptz,
  crops text[] default array[]::text[])
returns jsonb language plpgsql as $$
declare r jsonb; original jsonb := pg_temp.start_receipt_snapshot();
begin
 execute 'set local role authenticated';
 r := api.get_booking_start_receipt(w,b,c,t,crops);
 execute 'reset role';
 if original is distinct from pg_temp.start_receipt_snapshot() then
   raise exception 'FAIL receipt read changed business state';
 end if;
 if r->'retry_authorized' is distinct from 'false'::jsonb then
   raise exception 'FAIL receipt read authorized retry';
 end if;
 return r;
exception when others then execute 'reset role'; raise;
end $$;
create function pg_temp.start_receipt_denied(w uuid,b uuid,c uuid,t timestamptz)
returns boolean language plpgsql as $$
begin perform pg_temp.start_receipt_read(w,b,c,t); return false;
exception when insufficient_privilege or invalid_authorization_specification then return true;
end $$;

do $tests$
declare
 tenant uuid; tenant_other uuid; actor uuid := gen_random_uuid();
 viewer uuid := gen_random_uuid(); stranger uuid := gen_random_uuid();
 wells uuid[] := array[gen_random_uuid(),gen_random_uuid(),gen_random_uuid()];
 bookings uuid[] := array[gen_random_uuid(),gen_random_uuid(),gen_random_uuid()];
 sessions uuid[] := array[gen_random_uuid(),gen_random_uuid(),gen_random_uuid()];
 command uuid := gen_random_uuid(); absent uuid := gen_random_uuid();
 other_command uuid := gen_random_uuid();
 person uuid; farmer uuid; account_id uuid; farm uuid; pump uuid;
 at_time timestamptz := '2026-10-20 09:00:00Z';
 payload jsonb; original jsonb; r jsonb; key text; n integer;
 fn regprocedure;
begin
 insert into core.tenants(name) values ('start receipt A') returning id into tenant;
 insert into core.tenants(name) values ('start receipt B') returning id into tenant_other;
 insert into auth.users(id,instance_id,aud,role,email,email_confirmed_at,created_at,updated_at)
 select id,'00000000-0000-0000-0000-000000000000'::uuid,'authenticated','authenticated',
   id::text||'@start-receipt.test',now(),now(),now() from unnest(array[actor,viewer,stranger]) u(id);
 insert into iam.profiles(id,full_name) values(actor,'مشغل'),(viewer,'قارئ'),(stranger,'بلا تعيين')
 on conflict(id) do nothing;
 for n in 1..3 loop
  insert into core.wells(id,tenant_id,name)
  values(wells[n],case when n=3 then tenant_other else tenant end,'start receipt '||n);
  insert into core.well_assignments(well_id,profile_id,role,status)
  values(wells[n],actor,'operator',case when n=3 then 'inactive' else 'active' end);
  insert into core.persons(tenant_id,full_name,normalized_name)
  values(case when n=3 then tenant_other else tenant end,'مزارع '||n,'مزارع '||n) returning id into person;
  insert into ops.farmer_profiles(tenant_id,person_id)
  values(case when n=3 then tenant_other else tenant end,person) returning id into farmer;
  insert into ops.farmer_well_accounts(tenant_id,well_id,farmer_profile_id,public_code)
  values(case when n=3 then tenant_other else tenant end,wells[n],farmer,'START-RECEIPT-'||n) returning id into account_id;
  insert into ops.farms(well_id,name,farmer_well_account_id)
  values(wells[n],'أرض',account_id) returning id into farm;
  insert into core.pumps(well_id,name,power_source,status)
  values(wells[n],'مضخة','diesel','active') returning id into pump;
  insert into ops.irrigation_bookings(id,tenant_id,public_code,well_id,farmer_well_account_id,
    farm_id,scheduled_start,scheduled_end,expected_duration_minutes,expected_energy_source,status,created_by)
  values(bookings[n],case when n=3 then tenant_other else tenant end,'START-BKG-'||n,
    wells[n],account_id,farm,at_time,at_time+interval '10 minutes',10,'well_diesel','confirmed',actor);
  -- الجلسة مغلقة الآن؛ الإقرار الأصلي يجب أن يبقى قابلًا للاسترجاع.
  insert into ops.irrigation_sessions(id,well_id,pump_id,farm_id,farmer_well_account_id,
    operator_profile_id,booking_id,started_at,ended_at,status)
  values(sessions[n],wells[n],pump,farm,account_id,actor,bookings[n],at_time,
    at_time+interval '10 minutes','closed');
 end loop;
 insert into core.well_assignments(well_id,profile_id,role,status)
 values(wells[1],viewer,'viewer','active');
 perform set_config('request.jwt.claim.sub',actor::text,true);
 payload := jsonb_build_object('booking_execution_contract_version',113,
   'booking_id',bookings[1],'started_at',at_time,'crops','[]'::jsonb);
 original := jsonb_build_object('session_id',sessions[1],'booking_id',bookings[1],
   'well_id',wells[1],'session_status','open','booking_status','confirmed',
   'started_at',at_time,'booked_duration_minutes',10,
   'operational_end_at',at_time+interval '10 minutes');
 insert into sync.processed_commands(tenant_id,command_id,command_type,entity_id,status,
   request_payload,response_payload)
 values(tenant,command,'start_irrigation_session_from_booking',bookings[1],'accepted',payload,original),
   (tenant_other,other_command,'start_irrigation_session_from_booking',bookings[3],'accepted',
    payload||jsonb_build_object('booking_id',bookings[3]),original||jsonb_build_object(
      'well_id',wells[3],'booking_id',bookings[3],'session_id',sessions[3]));
 r := pg_temp.start_receipt_read(wells[1],bookings[1],command,at_time);
 perform pg_temp.start_receipt_check(r->>'status'='accepted' and r->'receipt'=original,
   'إقرار البداية الأصلي يبقى كما هو بعد إغلاق الجلسة');
 perform pg_temp.start_receipt_check(r=pg_temp.start_receipt_read(wells[1],bookings[1],command,at_time),
   'تكرار القراءة يعيد الإقرار نفسه بلا أثر');
 execute 'set local role authenticated';
 perform pg_temp.start_receipt_check(current_user='authenticated' and
   pg_catalog.row_security_active('sync.processed_commands'::regclass) and
   not exists(select 1 from sync.processed_commands where command_id=command),
   'المشغل لا يقرأ سجل الأوامر مباشرة رغم نجاح العقد');
 execute 'reset role';
 perform set_config('TimeZone','Asia/Aden',true);
 r := pg_temp.start_receipt_read(wells[1],bookings[1],command,at_time);
 perform pg_temp.start_receipt_check(r->>'status'='accepted','المقارنة الزمنية لا تتأثر بمنطقة الاتصال');
 perform set_config('TimeZone','UTC',true);
 r := pg_temp.start_receipt_read(wells[1],bookings[1],absent,at_time);
 perform pg_temp.start_receipt_check(r->>'status'='not_found' and r->'receipt'='null'::jsonb,
   'الغياب ليس إذن إعادة البدء');
 r := pg_temp.start_receipt_read(wells[1],bookings[1],command,at_time+interval '1 second');
 perform pg_temp.start_receipt_check(r->>'status'='unresolved','رفض تغيير وقت البداية');
 r := pg_temp.start_receipt_read(wells[1],bookings[1],command,at_time,null);
 perform pg_temp.start_receipt_check(r->>'status'='unresolved','المحاصيل الفارغة تختلف عن null');
 r := pg_temp.start_receipt_read(wells[2],bookings[2],command,at_time);
 perform pg_temp.start_receipt_check(r->>'status'='unresolved','رفض إعادة استعمال الأمر في بئر آخر');
 r := pg_temp.start_receipt_read(wells[1],bookings[1],other_command,at_time);
 perform pg_temp.start_receipt_check(r->>'status'='not_found','عدم كشف أمر جهة أخرى');
 update sync.processed_commands set status='processing',response_payload=null where command_id=command;
 r := pg_temp.start_receipt_read(wells[1],bookings[1],command,at_time);
 perform pg_temp.start_receipt_check(r->>'status'='processing' and r->'receipt'='null'::jsonb,'نتيجة غير نهائية');
 update sync.processed_commands set status='accepted',response_payload=original where command_id=command;
 foreach key in array array['session_id','booking_id','well_id','started_at','operational_end_at','booked_duration_minutes'] loop
  update sync.processed_commands set response_payload=original-key where command_id=command;
  r := pg_temp.start_receipt_read(wells[1],bookings[1],command,at_time);
  perform pg_temp.start_receipt_check(r->>'status'='unresolved' and r->'receipt'='null'::jsonb,
    'رفض إقرار ناقص: '||key);
 end loop;
 update sync.processed_commands set response_payload=original||jsonb_build_object('session_id',sessions[2]) where command_id=command;
 r := pg_temp.start_receipt_read(wells[1],bookings[1],command,at_time);
 perform pg_temp.start_receipt_check(r->>'status'='unresolved','رفض جلسة أخرى في الإقرار');
 update sync.processed_commands set response_payload=original,request_payload=null where command_id=command;
 r := pg_temp.start_receipt_read(wells[1],bookings[1],command,at_time);
 perform pg_temp.start_receipt_check(r->>'status'='unresolved','عدم اختراع بصمة لطلب قديم غائب');
 update sync.processed_commands set request_payload=payload,command_type='pause_irrigation_session' where command_id=command;
 r := pg_temp.start_receipt_read(wells[1],bookings[1],command,at_time);
 perform pg_temp.start_receipt_check(r->>'status'='unresolved','رفض نوع أمر مختلف');
 update sync.processed_commands set command_type='start_irrigation_session_from_booking' where command_id=command;
 update sync.processed_commands set entity_id=bookings[2] where command_id=command;
 r := pg_temp.start_receipt_read(wells[1],bookings[1],command,at_time);
 perform pg_temp.start_receipt_check(r->>'status'='unresolved','كيان الأمر هو الحجز الأصلي');
 update sync.processed_commands set entity_id=bookings[1],status='rejected' where command_id=command;
 r := pg_temp.start_receipt_read(wells[1],bookings[1],command,at_time);
 perform pg_temp.start_receipt_check(r->>'status'='unresolved','الرفض لا يتحول إلى قبول');
 update sync.processed_commands set status='accepted' where command_id=command;
 r := pg_temp.start_receipt_read(wells[1],bookings[1],command,at_time,array['different']);
 perform pg_temp.start_receipt_check(r->>'status'='unresolved','رفض تغيير المحاصيل الأصلية');
 perform pg_temp.start_receipt_check(pg_temp.start_receipt_denied(wells[3],bookings[3],other_command,at_time),
   'التعيين غير النشط لا يسمح بقراءة جهة أخرى');
 perform pg_temp.start_receipt_check(pg_temp.start_receipt_denied(wells[1],bookings[2],command,at_time),
   'الحجز خارج البئر لا يكشف وجود الأمر');
 perform set_config('request.jwt.claim.sub',viewer::text,true);
 perform pg_temp.start_receipt_check(pg_temp.start_receipt_denied(wells[1],bookings[1],command,at_time),
   'القارئ بلا صلاحية بدء محجوب');
 perform set_config('request.jwt.claim.sub',stranger::text,true);
 perform pg_temp.start_receipt_check(pg_temp.start_receipt_denied(wells[1],bookings[1],command,at_time),
   'غياب التعيين محجوب');
 perform set_config('request.jwt.claim.sub','',true);
 perform pg_temp.start_receipt_check(pg_temp.start_receipt_denied(wells[1],bookings[1],command,at_time),
   'غياب تسجيل الدخول محجوب');
 foreach fn in array array[
   'api.get_booking_start_receipt(uuid,uuid,uuid,timestamptz,text[])'::regprocedure,
   'sync.get_booking_start_receipt_read(uuid,uuid,uuid,timestamptz,text[])'::regprocedure] loop
  perform pg_temp.start_receipt_check(not has_function_privilege('anon',fn,'EXECUTE'), 'منع anon');
  perform pg_temp.start_receipt_check(not exists(select 1 from pg_proc p,
    lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
    where p.oid=fn and a.grantee=0 and a.privilege_type='EXECUTE'), 'سحب PUBLIC');
  perform pg_temp.start_receipt_check(exists(select 1 from pg_proc p where p.oid=fn
    and p.provolatile='s' and p.prosecdef=(p.pronamespace='sync'::regnamespace)
    and 'search_path=pg_catalog, pg_temp'=any(p.proconfig)), 'عقد قراءة وصلاحيات محددة');
 end loop;
end $tests$;
rollback;
