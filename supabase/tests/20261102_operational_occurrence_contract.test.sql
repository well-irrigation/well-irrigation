
\set ON_ERROR_STOP on
-- محلي فقط؛ لا تشغيل سحابي. كل التجهيزات تُلغى في نهاية هذا الملف.
begin;
set local timezone='UTC';
create function pg_temp.r4_check(ok boolean,label text) returns void language plpgsql as $$
begin
 if ok is distinct from true then raise exception 'FAIL %',label; end if;
 raise notice 'PASS %',label;
end;$$;
create function pg_temp.r4_fixture() returns jsonb language plpgsql as $$
declare t uuid; p uuid; fp uuid; op uuid:=gen_random_uuid(); w uuid; a uuid; f uuid; pump uuid; b uuid;
 -- well_pricing بفترات date؛ الواقعة قبل حد اليوم والتعرفة الحالية بعده.
 at_time timestamptz:=date_trunc('day',transaction_timestamp())-interval '4 hours';
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
 values(w,3600,date '1970-01-01',current_date);
 insert into billing.well_pricing(well_id,price_per_hour_minor,period_start)
 values(w,7200,current_date);
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
create function pg_temp.r4_group(f jsonb,request jsonb default null) returns jsonb language plpgsql as $$
declare r jsonb;
begin
 perform set_config('request.jwt.claim.sub',f->>'operator',true);
 execute 'set local role authenticated';
 r:=api.start_session_with_booking_delays((f->>'well')::uuid,(f->>'command')::uuid,coalesce(request,f->'request'));
 execute 'reset role'; return r;
exception when others then execute 'reset role'; raise;
end;$$;
create function pg_temp.r4_settlement(f jsonb,rejected jsonb,events jsonb default '[]') returns jsonb language sql as $$
 select jsonb_build_object('version',1,'human_confirmed',true,'reason','حسم بشري للواقعة الأصلية',
 'occurrence_command_id',f->'command','original_rejected_request_id',f->'command',
 'original_rejected_result',rejected,'original_request_fingerprint',md5((f->'request')::text),
 'facts',jsonb_build_object('root_local_id',f->'local','start',f->'request'->'start','events',events,
 'completion',jsonb_build_object('command_id',gen_random_uuid(),'local_id',gen_random_uuid(),
 'occurred_at',(f->>'at')::timestamptz+interval '20 minutes',
 'payload',jsonb_build_object('p_session_id',jsonb_build_object('$ref',f->>'local','$kind','session')))));
$$;
create function pg_temp.r4_settle(f jsonb,cmd uuid,request jsonb) returns jsonb language plpgsql as $$
declare r jsonb;
begin
 perform set_config('request.jwt.claim.sub',f->>'operator',true);
 execute 'set local role authenticated';
 r:=api.settle_operational_occurrence((f->>'well')::uuid,cmd,request);
 execute 'reset role'; return r;
exception when others then execute 'reset role'; raise;
end;$$;
create function pg_temp.r4_snapshot(w uuid,p_commands boolean default false) returns jsonb language sql as $$
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
create function pg_temp.r4_inject_failure() returns trigger language plpgsql as $$
begin
 if new.well_id::text=current_setting('r4.fail_well',true) then
   raise exception 'r4_injected_after_session_insert' using errcode='XX000'; end if;
 return new;
end;$$;
create trigger r4_test_failure after insert on ops.irrigation_sessions for each row execute function pg_temp.r4_inject_failure();

do $test$
declare f jsonb; h jsonb; z jsonb; req jsonb; r jsonb; replay jsonb; rejected jsonb;
 settlement jsonb; settled jsonb; before_state jsonb; original_before jsonb; live_before jsonb; pricing_before jsonb;
 sid uuid; live uuid; end_id uuid; settlement_id uuid; another uuid; denied boolean; n bigint; rev bigint;
 event jsonb; at_time timestamptz; charge bigint; tank_before bigint;
begin
 f:=pg_temp.r4_fixture(); r:=pg_temp.r4_group(f);
 perform pg_temp.r4_check(r->>'status'='accepted' and pg_temp.r4_group(f)=r,'T01 exact group replay');
 denied:=false;
 begin perform pg_temp.r4_group(f,jsonb_set(f->'request','{reason}','"changed"'));
 exception when invalid_parameter_value then denied:=true; end;
 perform pg_temp.r4_check(denied,'T02 changed group payload rejected');
 h:=pg_temp.r4_fixture(); req:=jsonb_set(h->'request','{expected_revision}','-1');
 before_state:=pg_temp.r4_snapshot((h->>'well')::uuid);
 rejected:=pg_temp.r4_group(h,req);
 perform pg_temp.r4_check(rejected->>'status'='rejected' and rejected->>'reason'='stale_operational_schedule'
   and before_state=pg_temp.r4_snapshot((h->>'well')::uuid),'T04 stale group atomic rejection');
 -- يحفظ f.request البصمة التي أُرسلت فعليًا لا المعاينة السابقة.
 h:=jsonb_set(h,'{request}',req);
 z:=pg_temp.r4_fixture(); before_state:=pg_temp.r4_snapshot((z->>'well')::uuid,true);
 perform set_config('r4.fail_well',z->>'well',true); denied:=false;
 begin perform pg_temp.r4_group(z);exception when internal_error then denied:=true;end;
 perform set_config('r4.fail_well','',true);
 perform pg_temp.r4_check(denied and before_state=pg_temp.r4_snapshot((z->>'well')::uuid,true),
   'T05 injected group failure rolls back delays session binding');
 before_state:=pg_temp.r4_snapshot((f->>'well')::uuid,true);
 perform set_config('request.jwt.claim.sub',f->>'operator',true);
 execute 'set local role authenticated';
 replay:=api.get_delay_start_group_receipt((f->>'well')::uuid,(f->>'command')::uuid,f->'request');
 execute 'reset role';
 perform pg_temp.r4_check(replay->'receipt'=r and replay->'retry_authorized'='false' and before_state=pg_temp.r4_snapshot((f->>'well')::uuid,true),'T06 lost group response receipt');
 settlement_id:=gen_random_uuid(); settlement:=pg_temp.r4_settlement(h,rejected);
 original_before:=(select to_jsonb(pc) from sync.processed_commands pc where tenant_id=(h->>'tenant')::uuid and command_id=(h->>'command')::uuid);
 -- جلسة حالية تبدأ بعد نهاية الواقعة التاريخية. إلغاء الحجز تجهيز فقط قبل التقاط حالة المورد.
 update ops.irrigation_bookings set status='cancelled' where id=(h->>'booking')::uuid;
 perform set_config('request.jwt.claim.sub',h->>'operator',true);
 live:=api.start_irrigation_session((h->>'well')::uuid,(h->>'pump')::uuid,(h->>'farm')::uuid,
   (h->>'account')::uuid,'well_diesel',transaction_timestamp()-interval '30 minutes',null,gen_random_uuid());
 live_before:=(select jsonb_build_object('revision',(select operational_schedule_revision from core.wells where id=s.well_id),'session',to_jsonb(s),'segments',
   (select jsonb_agg(to_jsonb(ss) order by sequence_number) from ops.session_segments ss where session_id=live),
   'pump',(select to_jsonb(p) from core.pumps p where id=s.pump_id),
   'resources',(select jsonb_agg(to_jsonb(rr) order by id) from ops.resource_reservations rr where well_id=s.well_id))
   from ops.irrigation_sessions s where id=live);
 pricing_before:=(select to_jsonb(wp) from billing.well_pricing wp
   where wp.well_id=(h->>'well')::uuid and wp.period_end is null);
 settled:=pg_temp.r4_settle(h,settlement_id,settlement);
 perform pg_temp.r4_check(settled->>'status'='accepted','T07 historical settlement after planning rejection');
 perform pg_temp.r4_check(original_before=(select to_jsonb(pc) from sync.processed_commands pc
   where tenant_id=(h->>'tenant')::uuid and command_id=(h->>'command')::uuid),'T08 original rejected result immutable');
 sid:=(settled->>'server_session_id')::uuid;
 perform pg_temp.r4_check(exists(select 1 from ops.irrigation_sessions where id=sid and status='closed'
   and ended_at<(select started_at from ops.irrigation_sessions where id=live)),'T09 historical completed before live session');
 perform pg_temp.r4_check(live_before=(select jsonb_build_object('revision',(select operational_schedule_revision from core.wells where id=s.well_id),'session',to_jsonb(s),'segments',
   (select jsonb_agg(to_jsonb(ss) order by sequence_number) from ops.session_segments ss where session_id=live),
   'pump',(select to_jsonb(p) from core.pumps p where id=s.pump_id),
   'resources',(select jsonb_agg(to_jsonb(rr) order by id) from ops.resource_reservations rr where well_id=s.well_id))
   from ops.irrigation_sessions s where id=live),'T10 active session segments resource unchanged');
 z:=pg_temp.r4_fixture(); req:=jsonb_set(z->'request','{expected_revision}','-1');z:=jsonb_set(z,'{request}',req);
 replay:=pg_temp.r4_group(z); req:=pg_temp.r4_settlement(z,replay);
 update ops.irrigation_bookings set status='cancelled' where id=(z->>'booking')::uuid;
 perform set_config('request.jwt.claim.sub',z->>'operator',true);
 live:=api.start_irrigation_session((z->>'well')::uuid,(z->>'pump')::uuid,(z->>'farm')::uuid,
   (z->>'account')::uuid,'well_diesel',(z->>'at')::timestamptz+interval '10 minutes',null,gen_random_uuid());
 before_state:=pg_temp.r4_snapshot((z->>'well')::uuid);
 replay:=pg_temp.r4_settle(z,gen_random_uuid(),req);
 perform pg_temp.r4_check(replay->>'status'='review' and replay->>'reason'='historical_interval_conflict'
   and before_state=pg_temp.r4_snapshot((z->>'well')::uuid),'T11 overlap review no partial effects');
 perform pg_temp.r4_check(pg_temp.r4_settle(h,settlement_id,settlement)=settled,'T12 settlement exact replay');
 replay:=pg_temp.r4_settle(h,gen_random_uuid(),settlement);
 perform pg_temp.r4_check(replay->>'server_session_id'=sid::text
   and (select count(*) from ops.operational_occurrences where well_id=(h->>'well')::uuid and provenance='historical_settlement')=1,
   'T14 different settlement request same occurrence no second session');
 denied:=false;
 begin
  insert into ops.operational_occurrences select tenant_id,gen_random_uuid(),well_id,source_booking_id,original_request_id,
   original_operator_id,started_at,ended_at,original_facts,provenance,settlement_command_id,completion_command_id,
   server_session_id,status,created_at,resolved_at from ops.operational_occurrences where server_session_id=sid;
 exception when unique_violation then denied:=true;end;
 perform pg_temp.r4_check(denied and (select count(*) from ops.operational_occurrences where tenant_id=(h->>'tenant')::uuid
   and occurrence_command_id=(h->>'command')::uuid)=1,'T15 occurrence and session uniqueness');
 end_id:=(settlement->'facts'->'completion'->>'command_id')::uuid;
 perform pg_temp.r4_check((select request_payload->'original_command'=settlement->'facts'->'completion'
    and (response_payload->>'ended_at')::timestamptz=(settlement->'facts'->'completion'->>'occurred_at')::timestamptz
    from sync.processed_commands where tenant_id=(h->>'tenant')::uuid and command_id=end_id),
    'T16 original completion identity time payload preserved');
 perform set_config('request.jwt.claim.sub',h->>'operator',true);execute 'set local role authenticated';
 replay:=api.get_completion_receipt((h->>'well')::uuid,sid,end_id,'complete_irrigation_session');execute 'reset role';
 perform pg_temp.r4_check(replay->>'status'='accepted' and replay->'receipt'=settled->'completion_receipt',
   'T17 original completion receipt adoption');
 perform pg_temp.r4_check((select count(*) from sync.processed_commands where tenant_id=(h->>'tenant')::uuid
   and command_type='complete_irrigation_session' and entity_id=sid)=1,'T18 no replacement completion');
 perform pg_temp.r4_check((select count(*) from billing.session_charges where session_id=sid)=1,'T19 one session charge');
 -- سعر الحاضر مختلف؛ الأصل التاريخي يبقى 3600/ساعة.
 perform pg_temp.r4_check((settled->'completion_receipt'->>'amount_minor')::bigint=1200
   and (select price_per_hour_minor from billing.session_charges where session_id=sid)=3600
   and exists(select 1 from billing.well_pricing wp where wp.well_id=(h->>'well')::uuid
     and wp.price_per_hour_minor=3600 and wp.period_end=current_date
     and wp.period_start<=(h->>'at')::timestamptz
     and wp.period_end>(settlement->'facts'->'completion'->>'occurred_at')::timestamptz)
   and exists(select 1 from ops.irrigation_sessions where id=sid
     and started_at=(h->>'at')::timestamptz
     and ended_at=(settlement->'facts'->'completion'->>'occurred_at')::timestamptz
     and price_per_hour_minor_snapshot=3600)
   and (select count(*) from ops.session_segments where session_id=sid)=1
   and exists(select 1 from ops.session_segments where session_id=sid
     and started_at=(h->>'at')::timestamptz
     and ended_at=(settlement->'facts'->'completion'->>'occurred_at')::timestamptz
     and is_billable and coalesce(applied_operation_rate_minor,applied_hourly_rate_minor)=3600)
   and exists(select 1 from billing.well_pricing wp where wp.well_id=(h->>'well')::uuid
     and wp.period_start=current_date and wp.period_start<=transaction_timestamp()
     and wp.period_end is null and wp.price_per_hour_minor=7200 and to_jsonb(wp)=pricing_before),
   'T20 event time tariff not current tariff');
 z:=pg_temp.r4_fixture(); req:=jsonb_set(z->'request','{expected_revision}','-1');z:=jsonb_set(z,'{request}',req);
 replay:=pg_temp.r4_group(z);req:=pg_temp.r4_settlement(z,replay);
 delete from billing.well_pricing where well_id=(z->>'well')::uuid;
 before_state:=pg_temp.r4_snapshot((z->>'well')::uuid);replay:=pg_temp.r4_settle(z,gen_random_uuid(),req);
 perform pg_temp.r4_check(replay->>'status'='review' and before_state=pg_temp.r4_snapshot((z->>'well')::uuid),
   'T21 missing historical price no invented charge');
 z:=pg_temp.r4_fixture();req:=jsonb_set(z->'request','{expected_revision}','-1');z:=jsonb_set(z,'{request}',req);
 replay:=pg_temp.r4_group(z);req:=pg_temp.r4_settlement(z,replay);
 req:=jsonb_set(req,'{facts,events}',jsonb_build_array(jsonb_build_object('type','resume_irrigation_session',
   'command_id',gen_random_uuid(),'occurred_at',(z->>'at')::timestamptz+interval '10 minutes',
   'payload',jsonb_build_object('p_session_id',req->'facts'->'completion'->'payload'->'p_session_id'))));
 before_state:=pg_temp.r4_snapshot((z->>'well')::uuid);replay:=pg_temp.r4_settle(z,gen_random_uuid(),req);
 perform pg_temp.r4_check(replay->>'status'='review' and before_state=pg_temp.r4_snapshot((z->>'well')::uuid),
   'T22 malformed event chronology atomic review');
 z:=pg_temp.r4_fixture();req:=jsonb_set(z->'request','{expected_revision}','-1');z:=jsonb_set(z,'{request}',req);
 replay:=pg_temp.r4_group(z);req:=pg_temp.r4_settlement(z,replay);before_state:=pg_temp.r4_snapshot((z->>'well')::uuid,true);
 perform set_config('r4.fail_well',z->>'well',true);denied:=false;
 begin perform pg_temp.r4_settle(z,gen_random_uuid(),req);exception when internal_error then denied:=true;end;
 perform set_config('r4.fail_well','',true);
 perform pg_temp.r4_check(denied and before_state=pg_temp.r4_snapshot((z->>'well')::uuid,true),
   'T23 injected terminal insertion failure no orphan');
 denied:=false;
 begin perform pg_temp.r4_settle(z,gen_random_uuid(),jsonb_set(req,'{source_booking_id}',to_jsonb((f->>'booking')::uuid)));
 exception when invalid_parameter_value then denied:=true;end;
 perform set_config('request.jwt.claim.sub',f->>'operator',true);
 begin perform api.settle_operational_occurrence((z->>'well')::uuid,gen_random_uuid(),req);denied:=false;
 exception when insufficient_privilege then null;end;
 perform pg_temp.r4_check(denied,'T24 cross tenant well booking denied');
 perform pg_temp.r4_check((select current_shift_id is null and collector_profile_id is null from ops.irrigation_sessions where id=sid),
   'T25 no current shift or collector assignment');
 -- حالة closed وحدها لا تتجاوز حارس الجدولة: صف حر بلا مدة أمام حجز مؤكد.
 z:=pg_temp.r4_fixture();denied:=false;
 begin
  insert into ops.irrigation_sessions(well_id,pump_id,farm_id,farmer_well_account_id,operator_profile_id,started_at,ended_at,status)
  values((z->>'well')::uuid,(z->>'pump')::uuid,(z->>'farm')::uuid,(z->>'account')::uuid,(z->>'operator')::uuid,
    (z->>'at')::timestamptz,(z->>'at')::timestamptz+interval '20 minutes','closed');
  set constraints ops.irrigation_sessions_adhoc_duration_guard immediate;
 exception when check_violation then denied:=true;end;
 set constraints ops.irrigation_sessions_adhoc_duration_guard deferred;
 perform pg_temp.r4_check(denied,'T26 generic closed status is not historical bypass');
 -- الحارس العادي باقٍ مع تكرار الضغط، والتوافق NULL باقٍ لبئر آخر غير مشغول.
 perform set_config('request.jwt.claim.sub',f->>'operator',true);denied:=false;
 begin perform api.start_irrigation_session((f->>'well')::uuid,(f->>'pump')::uuid,(f->>'farm')::uuid,
   (f->>'account')::uuid,'well_diesel',(f->>'at')::timestamptz,null,gen_random_uuid());
 exception when raise_exception then denied:=true;end;
 perform pg_temp.r4_check(denied,'T27 normal start active resource guard retained');
 z:=pg_temp.r4_fixture();req:=jsonb_set(z->'request','{expected_revision}','-1');z:=jsonb_set(z,'{request}',req);
 replay:=pg_temp.r4_group(z);req:=pg_temp.r4_settlement(z,replay);
 update ops.irrigation_bookings set status='cancelled' where id=(z->>'booking')::uuid;
 perform set_config('request.jwt.claim.sub',z->>'operator',true);
 live:=api.start_irrigation_session((z->>'well')::uuid,(z->>'pump')::uuid,(z->>'farm')::uuid,
   (z->>'account')::uuid,'well_diesel',(req->'facts'->'completion'->>'occurred_at')::timestamptz,null,gen_random_uuid());
 replay:=pg_temp.r4_settle(z,gen_random_uuid(),req);
 perform pg_temp.r4_check(replay->>'status'='accepted','T28 half open intervals may touch');
 perform set_config('request.jwt.claim.sub',f->>'operator',true);
 sid:=(r->>'server_session_id')::uuid;end_id:=gen_random_uuid();
 execute 'set local role authenticated';
 replay:=api.complete_irrigation_session(sid,(f->>'at')::timestamptz+interval '20 minutes',null,null,null,end_id);
 execute 'reset role';
 perform pg_temp.r4_check(replay->>'status'='closed' and (select count(*) from billing.session_charges where session_id=sid)=1,
   'T30 normal completion shared financial core');
 z:=pg_temp.r4_fixture();req:=jsonb_set(z->'request','{expected_revision}','-1');z:=jsonb_set(z,'{request}',req);
 replay:=pg_temp.r4_group(z);req:=pg_temp.r4_settlement(z,replay);
 req:=jsonb_set(req,'{facts,fuel_tank_id}',z->'tank');
 req:=jsonb_set(req,'{facts,completion,fuel_quantity_ml}','1000');
 req:=jsonb_set(req,'{facts,completion,fuel_measurement_type}','"actual"');
 settlement_id:=gen_random_uuid();replay:=pg_temp.r4_settle(z,settlement_id,req);
 perform pg_temp.r4_settle(z,settlement_id,req);sid:=(replay->>'server_session_id')::uuid;
 perform pg_temp.r4_check(replay->>'status'='accepted'
   and (select count(*) from inventory.fuel_transactions x join ops.session_segments ss on ss.id=x.session_segment_id where ss.session_id=sid)=1
   and (select count(*) from audit.audit_logs where entity_id=sid and action='session_completed')=1,
   'T31 fuel and completion audit once');
 before_state:=pg_temp.r4_snapshot((z->>'well')::uuid,true);
 perform set_config('request.jwt.claim.sub',z->>'operator',true);execute 'set local role authenticated';
 replay:=api.get_occurrence_settlement_receipt((z->>'well')::uuid,settlement_id,req);
 execute 'reset role';
 perform pg_temp.r4_check(replay->>'status'='accepted' and before_state=pg_temp.r4_snapshot((z->>'well')::uuid,true),
   'T32 settlement receipt is read only');
 execute 'set local role authenticated';
 replay:=api.get_occurrence_settlement_receipt((z->>'well')::uuid,gen_random_uuid(),req);
 r:=api.get_delay_start_group_receipt((z->>'well')::uuid,(z->>'command')::uuid,jsonb_build_object('different',true));
 execute 'reset role';
 perform pg_temp.r4_check(replay->>'status'='not_found' and r->>'status'='unresolved'
   and replay->'retry_authorized'='false' and r->'retry_authorized'='false','T33 receipt absence never authorizes retry');
 denied:=false;
 execute 'set local role authenticated';
 begin perform api.execute_pending_booking_start(gen_random_uuid(),0,gen_random_uuid());
 exception when feature_not_supported then denied:=true;end;
 execute 'reset role';
 perform pg_temp.r4_check(denied,'T34 legacy pending start remains disabled');

 -- التوافق القديم باقٍ؛ ليس جزءًا من تتبع الواقعة الجديدة.
 z:=pg_temp.r4_fixture();update ops.irrigation_bookings set status='cancelled' where id=(z->>'booking')::uuid;
 perform set_config('request.jwt.claim.sub',z->>'operator',true);
 execute 'set local role authenticated';
 sid:=api.start_irrigation_session((z->>'well')::uuid,(z->>'pump')::uuid,(z->>'farm')::uuid,
   (z->>'account')::uuid,'well_diesel',(z->>'at')::timestamptz,null,null);
 perform api.complete_irrigation_session(sid,(z->>'at')::timestamptz+interval '20 minutes');
 live:=api.start_adhoc_session((z->>'well')::uuid,(z->>'pump')::uuid,(z->>'farm')::uuid,
   (z->>'account')::uuid,'well_diesel',10,(z->>'at')::timestamptz+interval '1 hour',null,null);
 execute 'reset role';
 perform pg_temp.r4_check(sid is not null and live is not null and
   not exists(select 1 from ops.operational_occurrences where well_id=(z->>'well')::uuid),
   'T35 legacy null identity preserved without synthetic occurrence');
 perform pg_temp.r4_check(not has_table_privilege('authenticated','ops.operational_occurrences','INSERT')
   and not has_table_privilege('authenticated','ops.operational_occurrences','UPDATE')
   and not has_table_privilege('authenticated','ops.operational_occurrences','SELECT')
   and not has_function_privilege('anon','api.start_session_with_booking_delays(uuid,uuid,jsonb)','EXECUTE')
   and not has_function_privilege('authenticated','ops.materialize_historical_occurrence(uuid,uuid,uuid,jsonb)','EXECUTE')
   and not has_function_privilege('authenticated','ops.finalize_session_from_closed_segments(uuid,timestamptz,uuid)','EXECUTE')
   and (select not prosecdef from pg_proc where oid='api.settle_operational_occurrence(uuid,uuid,jsonb)'::regprocedure),
   'T36 private table cores and public invoker boundary');
 z:=pg_temp.r4_fixture();update ops.irrigation_bookings set status='cancelled' where id=(z->>'booking')::uuid;
 perform set_config('request.jwt.claim.sub',z->>'operator',true);another:=gen_random_uuid();
 execute 'set local role authenticated';
 sid:=api.start_irrigation_session((z->>'well')::uuid,(z->>'pump')::uuid,(z->>'farm')::uuid,
   (z->>'account')::uuid,'well_diesel',(z->>'at')::timestamptz,null,another);
 execute 'reset role';
 before_state:=pg_temp.r4_snapshot((z->>'well')::uuid,true);
 execute 'set local role authenticated';
 live:=api.start_irrigation_session((z->>'well')::uuid,(z->>'pump')::uuid,(z->>'farm')::uuid,
   (z->>'account')::uuid,'well_diesel',(z->>'at')::timestamptz,null,another);
 execute 'reset role';
 perform pg_temp.r4_check(exists(select 1 from ops.operational_occurrences o
   join ops.irrigation_sessions sess on sess.id=o.server_session_id
   join core.wells scope_well on scope_well.id=sess.well_id
   where o.tenant_id=(z->>'tenant')::uuid and o.occurrence_command_id=another
     and o.server_session_id=sid and o.provenance='accepted_start'
     and o.well_id=sess.well_id and sess.well_id=(z->>'well')::uuid
     and scope_well.tenant_id=o.tenant_id)
   and exists(select 1 from sync.processed_commands where tenant_id=(z->>'tenant')::uuid
     and command_id=another and command_type='start_irrigation_session' and status='accepted'
     and entity_id is null and request_payload is null and (response_payload->>'id')::uuid=sid)
   and live=sid
   and (select count(*) from ops.operational_occurrences where well_id=(z->>'well')::uuid)=1
   and (select count(*) from ops.irrigation_sessions where well_id=(z->>'well')::uuid)=1
   and before_state=pg_temp.r4_snapshot((z->>'well')::uuid,true),
   'T37 identified normal start null entity scope exact binding and unchanged replay');
 z:=pg_temp.r4_fixture();perform set_config('request.jwt.claim.sub',z->>'operator',true);another:=gen_random_uuid();
 execute 'set local role authenticated';
 r:=api.start_irrigation_session_from_booking((z->>'booking')::uuid,(z->>'at')::timestamptz,another,array['قمح']);
 replay:=api.get_booking_start_receipt((z->>'well')::uuid,(z->>'booking')::uuid,another,(z->>'at')::timestamptz,array['قمح']);
 execute 'reset role';
 perform pg_temp.r4_check(replay->>'status'='accepted' and replay->'receipt'=r and
   exists(select 1 from ops.operational_occurrences where tenant_id=(z->>'tenant')::uuid
     and occurrence_command_id=another and server_session_id=(r->>'session_id')::uuid),
   'T38 identified booking start receipt compatible');

 denied:=false;perform set_config('request.jwt.claim.sub',z->>'operator',true);
 execute 'set local role authenticated';
 begin perform api.start_session_with_booking_delays((z->>'well')::uuid,null,z->'request');
 exception when insufficient_privilege then denied:=true;end;
 begin perform api.settle_operational_occurrence((z->>'well')::uuid,null,'{}');denied:=false;
 exception when insufficient_privilege then null;end;
 execute 'reset role';
 perform pg_temp.r4_check(denied,'T39 new APIs reject absent identity no generated fallback');
 z:=pg_temp.r4_fixture();
 insert into sync.processed_commands(tenant_id,command_id,command_type,entity_id,status,request_payload)
 values((z->>'tenant')::uuid,(z->>'command')::uuid,'start_session_with_booking_delays',(z->>'well')::uuid,
 'processing',jsonb_build_object('request',z->'request','actor_id',z->'operator'));
 before_state:=pg_temp.r4_snapshot((z->>'well')::uuid,true);
 perform set_config('request.jwt.claim.sub',z->>'operator',true);execute 'set local role authenticated';
 replay:=api.get_delay_start_group_receipt((z->>'well')::uuid,(z->>'command')::uuid,z->'request');
 execute 'reset role';
 perform pg_temp.r4_check(replay->>'status'='processing' and replay->'retry_authorized'='false'
   and before_state=pg_temp.r4_snapshot((z->>'well')::uuid,true),'T40 processing receipt read only no resend permission');
 perform set_config('request.jwt.claim.sub',h->>'operator',true);execute 'set local role authenticated';
 replay:=api.get_delay_start_group_receipt((h->>'well')::uuid,(h->>'command')::uuid,h->'request');
 execute 'reset role';
 perform pg_temp.r4_check(replay->>'status'='rejected' and replay->'receipt'=rejected,
   'T41 accepted settlement does not replace original rejection receipt');
 -- settlement_id تغيّر في اختبارات أخرى؛ اختبر الهوية الأصلية المثبتة من سجل الواقعة نفسه.
 select settlement_command_id into another from ops.operational_occurrences
   where tenant_id=(h->>'tenant')::uuid and occurrence_command_id=(h->>'command')::uuid;
 denied:=false;
 begin perform pg_temp.r4_settle(h,another,jsonb_set(settlement,'{reason}','"different request"'));
 exception when invalid_parameter_value then denied:=true;end;
 perform pg_temp.r4_check(denied,'T42 changed settlement payload rejected');
 z:=pg_temp.r4_fixture();req:=jsonb_set(z->'request','{expected_revision}','-1');z:=jsonb_set(z,'{request}',req);
 replay:=pg_temp.r4_group(z);req:=pg_temp.r4_settlement(z,replay);
 event:=jsonb_build_array(
   jsonb_build_object('command_id',gen_random_uuid(),'type','pause_irrigation_session',
     'occurred_at',(z->>'at')::timestamptz+interval '5 minutes','payload',jsonb_build_object(
       'p_session_id',req->'facts'->'completion'->'payload'->'p_session_id','p_reason','operator_pause')),
   jsonb_build_object('command_id',gen_random_uuid(),'type','change_session_energy_source',
     'occurred_at',(z->>'at')::timestamptz+interval '7 minutes','payload',jsonb_build_object(
       'p_session_id',req->'facts'->'completion'->'payload'->'p_session_id','p_new_source','solar')),
   jsonb_build_object('command_id',gen_random_uuid(),'type','resume_irrigation_session',
     'occurred_at',(z->>'at')::timestamptz+interval '10 minutes','payload',jsonb_build_object(
       'p_session_id',req->'facts'->'completion'->'payload'->'p_session_id')));
 req:=jsonb_set(req,'{facts,events}',event);replay:=pg_temp.r4_settle(z,gen_random_uuid(),req);
 perform pg_temp.r4_check(replay->>'status'='accepted'
   and (replay->'completion_receipt'->>'billable_seconds')::bigint=900
   and (replay->'completion_receipt'->>'actual_seconds')::bigint=1200
   and (replay->'completion_receipt'->>'amount_minor')::bigint=900
   and (select count(*) from sync.processed_commands where tenant_id=(z->>'tenant')::uuid
       and command_id in (select (value->>'command_id')::uuid from jsonb_array_elements(event)) and status='accepted')=3,
   'T43 pause resume paused energy chronology and original event receipts');
 z:=pg_temp.r4_fixture();req:=jsonb_set(z->'request','{expected_revision}','-1');
 req:=jsonb_set(req,'{start,booking_id}',z->'booking');req:=jsonb_set(req,'{delays}','[]');
 z:=jsonb_set(z,'{request}',req);replay:=pg_temp.r4_group(z);req:=pg_temp.r4_settlement(z,replay);
 req:=jsonb_set(req,'{source_booking_id}',z->'booking');
 perform set_config('request.jwt.claim.sub',z->>'operator',true);execute 'set local role authenticated';
 r:=api.start_irrigation_session_from_booking((z->>'booking')::uuid,
   (z->>'at')::timestamptz+interval '30 minutes',gen_random_uuid(),array['قمح']);
 execute 'reset role';before_state:=pg_temp.r4_snapshot((z->>'well')::uuid);
 replay:=pg_temp.r4_settle(z,gen_random_uuid(),req);
 perform pg_temp.r4_check(replay->>'status'='review' and replay->>'reason'='existing_session_requires_exact_occurrence_proof'
   and before_state=pg_temp.r4_snapshot((z->>'well')::uuid),'T44 no heuristic adoption of an existing booked session');
end;$test$;
rollback;
