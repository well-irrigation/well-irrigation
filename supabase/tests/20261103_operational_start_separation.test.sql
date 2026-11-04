
\set ON_ERROR_STOP on
-- محلي فقط؛ لا تشغيل سحابي. كل التجهيزات تُلغى في نهاية هذا الملف.
begin;
set local timezone='UTC';
create function pg_temp.r6_check(ok boolean,label text) returns void language plpgsql as $$
begin
 if ok is distinct from true then raise exception 'FAIL %',label; end if;
 raise notice 'PASS %',label;
end;$$;
create function pg_temp.r6_fixture() returns jsonb language plpgsql as $$
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
create function pg_temp.r6_group(f jsonb,request jsonb default null) returns jsonb language plpgsql as $$
declare r jsonb;
begin
 perform set_config('request.jwt.claim.sub',f->>'operator',true);
 execute 'set local role authenticated';
 r:=api.start_session_with_booking_delays((f->>'well')::uuid,(f->>'command')::uuid,coalesce(request,f->'request'));
 execute 'reset role'; return r;
exception when others then execute 'reset role'; raise;
end;$$;
create function pg_temp.r6_settlement(f jsonb,rejected jsonb,events jsonb default '[]') returns jsonb language sql as $$
 select jsonb_build_object('version',1,'human_confirmed',true,'reason','حسم بشري للواقعة الأصلية',
 'occurrence_command_id',f->'command','original_rejected_request_id',f->'command',
 'original_rejected_result',rejected,'original_request_fingerprint',md5((f->'request')::text),
 'facts',jsonb_build_object('root_local_id',f->'local','start',f->'request'->'start','events',events,
 'completion',jsonb_build_object('command_id',gen_random_uuid(),'local_id',gen_random_uuid(),
 'occurred_at',(f->>'at')::timestamptz+interval '20 minutes',
 'payload',jsonb_build_object('p_session_id',jsonb_build_object('$ref',f->>'local','$kind','session')))));
$$;
create function pg_temp.r6_settle(f jsonb,cmd uuid,request jsonb) returns jsonb language plpgsql as $$
declare r jsonb;
begin
 perform set_config('request.jwt.claim.sub',f->>'operator',true);
 execute 'set local role authenticated';
 r:=api.settle_operational_occurrence((f->>'well')::uuid,cmd,request);
 execute 'reset role'; return r;
exception when others then execute 'reset role'; raise;
end;$$;
create function pg_temp.r6_snapshot(w uuid,p_commands boolean default false) returns jsonb language sql as $$
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
-- اختبارات السلوك أولًا؛ إعادة قيد الجدول أو إسقاط الهوية يجب أن يفشلها.
create function pg_temp.r6_start(f jsonb, booking uuid default null) returns uuid
language plpgsql as $$
declare sid uuid;
begin
 perform set_config('request.jwt.claim.sub',f->>'operator',true);
 execute 'set local role authenticated';
 sid:=api.start_operational_session((f->>'well')::uuid,(f->>'pump')::uuid,
   (f->>'farm')::uuid,(f->>'account')::uuid,'well_diesel',
   (f->>'at')::timestamptz,(f->>'command')::uuid,null,array['قمح'],booking);
 execute 'reset role'; return sid;
exception when others then execute 'reset role'; raise;
end;$$;

create function pg_temp.r6_fail_insert() returns trigger language plpgsql as $$
begin
 if new.well_id::text=current_setting('r6.fail_well',true) then
   raise exception 'r6_injected_failure' using errcode='XX000';
 end if;
 return new;
end;$$;
create trigger r6_test_failure after insert on ops.irrigation_sessions
 for each row execute function pg_temp.r6_fail_insert();

do $test$
declare f jsonb; h jsonb; z jsonb; r jsonb; req jsonb; settled jsonb; before_state jsonb;
 sid uuid; other uuid; revision bigint; denied boolean; old_session jsonb; old_commands jsonb;
 old_resources jsonb; old_segments jsonb; old_occurrence jsonb; old_receipt jsonb; rejected jsonb;
 reschedule_command_id uuid:=gen_random_uuid();
begin
 f:=pg_temp.r6_fixture();
 -- حجز مستقبلي بالنسبة إلى ساعة الخادم أيضًا، لا بالنسبة إلى البداية فقط.
 update ops.irrigation_bookings set scheduled_start=clock_timestamp()+interval '1 hour',
   scheduled_end=clock_timestamp()+interval '2 hours',expected_duration_minutes=60
 where id=(f->>'booking')::uuid;
 revision:=(select operational_schedule_revision from core.wells where id=(f->>'well')::uuid);
 sid:=pg_temp.r6_start(f);
 set constraints ops.irrigation_sessions_adhoc_duration_guard immediate;
 set constraints ops.irrigation_sessions_adhoc_duration_guard deferred;
 perform pg_temp.r6_check(exists(select 1 from ops.irrigation_sessions where id=sid
   and status='open' and ended_at is null and planned_end_at is null and planned_duration_minutes is null),
   'A identified start without duration');
 perform pg_temp.r6_check(exists(select 1 from ops.irrigation_bookings where id=(f->>'booking')::uuid
   and scheduled_start>clock_timestamp()),'B future booking does not block start');
 perform pg_temp.r6_check((select operational_schedule_revision=revision from core.wells where id=(f->>'well')::uuid),
   'planning revision unchanged by operational start');
 perform pg_temp.r6_check(exists(select 1 from ops.session_segments where session_id=sid
   and applied_hourly_rate_minor=3600), 'event time pricing remains canonical');
 perform pg_temp.r6_check(exists(select 1 from ops.operational_occurrences where server_session_id=sid
   and occurrence_command_id=(f->>'command')::uuid and original_request_id=occurrence_command_id
   and source_booking_id is null and status='accepted'),'F optional provenance and original command identity');
 old_session:=(select to_jsonb(s) from ops.irrigation_sessions s where id=sid);
 old_segments:=(select jsonb_agg(to_jsonb(s) order by id) from ops.session_segments s where session_id=sid);
 old_resources:=(select jsonb_agg(to_jsonb(s) order by id) from ops.resource_reservations s where session_id=sid);
 old_commands:=(select jsonb_agg(to_jsonb(c) order by id) from sync.processed_commands c where tenant_id=(f->>'tenant')::uuid);
 old_occurrence:=(select to_jsonb(o) from ops.operational_occurrences o where server_session_id=sid);
 perform set_config('request.jwt.claim.sub',f->>'operator',true);
 execute 'set local role authenticated';
 r:=api.reschedule_booking((f->>'booking')::uuid,(f->>'at')::timestamptz+interval '30 minutes',
   (f->>'at')::timestamptz+interval '60 minutes','تعديل خطة فقط',reschedule_command_id,null);
 execute 'reset role';
 perform pg_temp.r6_check(r->>'status'='confirmed','E actual reschedule accepted');
 -- إعادة الجدولة نفسها أمر مشروع؛ لا نخلطه بأمر إكمال أو أثر تشغيلي.
 perform pg_temp.r6_check(exists(select 1 from sync.processed_commands c
   where c.tenant_id=(f->>'tenant')::uuid and c.command_id=reschedule_command_id
     and c.command_type='reschedule_booking' and c.status='accepted' and c.response_payload=r)
   and old_commands=(select jsonb_agg(to_jsonb(c) order by id) from sync.processed_commands c
     where c.tenant_id=(f->>'tenant')::uuid and c.command_id<>reschedule_command_id),
   'E reschedule adds only its identified command without altering existing commands');
 old_commands:=(select jsonb_agg(to_jsonb(c) order by id) from sync.processed_commands c
   where c.tenant_id=(f->>'tenant')::uuid);
 perform pg_temp.r6_check((select operational_schedule_revision>revision from core.wells where id=(f->>'well')::uuid),
   'planning mutation still advances revision');
 perform pg_temp.r6_check(old_session=(select to_jsonb(s) from ops.irrigation_sessions s where id=sid)
   and old_occurrence=(select to_jsonb(o) from ops.operational_occurrences o where server_session_id=sid),
   'E booking reschedule leaves existing session and occurrence binding unchanged');
 perform pg_temp.r6_check((select scheduled_end<clock_timestamp() from ops.irrigation_bookings where id=(f->>'booking')::uuid)
   and (select started_at<(select scheduled_start from ops.irrigation_bookings where id=(f->>'booking')::uuid)
     and status='open' and ended_at is null from ops.irrigation_sessions where id=sid),
   'C session remains open beyond actual booking scheduled end');
 execute 'set local role authenticated';
 r:=api.evaluate_well_booking_transition((f->>'well')::uuid);
 execute 'reset role';
 set constraints all immediate;
 set constraints all deferred;
 perform pg_temp.r6_check(old_session=(select to_jsonb(s) from ops.irrigation_sessions s where id=sid)
   and old_segments=(select jsonb_agg(to_jsonb(s) order by id) from ops.session_segments s where session_id=sid)
   and old_resources is not distinct from (select jsonb_agg(to_jsonb(s) order by id) from ops.resource_reservations s where session_id=sid),
   'D booking end and evaluator do not stop alter segments or release resource');
 perform pg_temp.r6_check(not exists(select 1 from billing.session_charges where session_id=sid)
   and old_commands=(select jsonb_agg(to_jsonb(c) order by id) from sync.processed_commands c where tenant_id=(f->>'tenant')::uuid)
   and (select count(*)=1 from ops.irrigation_sessions where well_id=(f->>'well')::uuid)
   and not exists(select 1 from ops.booking_transition_chains where well_id=(f->>'well')::uuid),
   'D O no charge completion command successor or chain');
 perform pg_temp.r6_check(pg_temp.r6_start(f)=sid,'I exact replay after schedule revision changed');
 perform set_config('TimeZone','Asia/Aden',true);
 perform pg_temp.r6_check(pg_temp.r6_start(f)=sid,'I same actual instant replays across server timezone');
 perform set_config('TimeZone','UTC',true);
 denied:=false;
 begin perform pg_temp.r6_start(jsonb_set(f,'{at}',to_jsonb((f->>'at')::timestamptz-interval '1 minute')));
 exception when invalid_parameter_value then denied:=true; end;
 perform pg_temp.r6_check(denied,'J changed actual time with same command rejected');
 denied:=false;
 begin perform pg_temp.r6_start(f,(f->>'booking')::uuid);
 exception when invalid_parameter_value then denied:=true; end;
 perform pg_temp.r6_check(denied,'J changed provenance with same command rejected');
 denied:=false;
 begin perform pg_temp.r6_start(jsonb_set(f,'{command}',to_jsonb(gen_random_uuid())));
 exception when raise_exception then denied:=true; end;
 perform pg_temp.r6_check(denied and (select count(*)=1 from ops.irrigation_sessions where well_id=(f->>'well')::uuid),
   'H real pump concurrency retained');
 perform pg_temp.r6_check(old_commands=(select jsonb_agg(to_jsonb(c) order by id) from sync.processed_commands c where tenant_id=(f->>'tenant')::uuid),
   'failed conflict creates no accepted or processing command');
 perform pg_temp.r6_check(old_occurrence=(select to_jsonb(o) from ops.operational_occurrences o where server_session_id=sid),
   'replay and failed conflicting starts leave occurrence immutable');
 denied:=false;
 begin
  insert into ops.operational_occurrences select tenant_id,gen_random_uuid(),well_id,source_booking_id,original_request_id,
   original_operator_id,started_at,ended_at,original_facts,provenance,settlement_command_id,completion_command_id,
   server_session_id,status,created_at,resolved_at from ops.operational_occurrences where server_session_id=sid;
 exception when unique_violation then denied:=true;end;
 perform pg_temp.r6_check(denied,'K one session cannot bind two occurrences');
 denied:=false;
 begin perform pg_temp.r6_start(f-'command');exception when invalid_parameter_value then denied:=true;end;
 perform pg_temp.r6_check(denied,'mandatory command no fallback');
 denied:=false;
 begin perform pg_temp.r6_start(f-'at');exception when invalid_parameter_value then denied:=true;end;
 perform pg_temp.r6_check(denied,'mandatory actual start');
 h:=pg_temp.r6_fixture();
 update ops.irrigation_bookings set status='cancelled' where id=(h->>'booking')::uuid;
 set constraints ops.irrigation_sessions_adhoc_duration_guard immediate;
 other:=pg_temp.r6_start(h,(h->>'booking')::uuid);
 set constraints ops.irrigation_sessions_adhoc_duration_guard immediate;
 set constraints ops.irrigation_sessions_adhoc_duration_guard deferred;
 perform pg_temp.r6_check(exists(select 1 from ops.irrigation_sessions where id=other and booking_id is null
   and planned_duration_minutes is null and planned_end_at is null and ended_at is null)
   and exists(select 1 from ops.operational_occurrences where server_session_id=other
     and source_booking_id=(h->>'booking')::uuid),'G cancelled booking retained only as provenance without duration');
 update ops.irrigation_bookings set scheduled_start=scheduled_start+interval '1 day',
   scheduled_end=scheduled_end+interval '1 day' where id=(h->>'booking')::uuid;
 perform pg_temp.r6_check(pg_temp.r6_start(h,(h->>'booking')::uuid)=other,
   'rescheduled provenance cannot invalidate accepted execution');
 denied:=false;
 begin perform pg_temp.r6_start(jsonb_set(h,'{command}',to_jsonb(gen_random_uuid())),(f->>'booking')::uuid);
 exception when invalid_parameter_value then denied:=true;end;
 perform pg_temp.r6_check(denied,'cross tenant booking provenance rejected');
 z:=pg_temp.r6_fixture();
 update ops.irrigation_bookings set status='cancelled' where id=(z->>'booking')::uuid;
 perform set_config('request.jwt.claim.sub',z->>'operator',true);
 execute 'set local role authenticated';
 other:=api.start_irrigation_session((z->>'well')::uuid,(z->>'pump')::uuid,(z->>'farm')::uuid,
   (z->>'account')::uuid,'well_diesel',(z->>'at')::timestamptz,null,null);
 execute 'reset role';
 perform pg_temp.r6_check(other is not null and not exists(select 1 from ops.operational_occurrences where server_session_id=other),
   'L legacy nullable start preserved without fabricated occurrence');
 z:=pg_temp.r6_fixture();
 update ops.irrigation_bookings set status='cancelled' where id=(z->>'booking')::uuid;
 perform set_config('request.jwt.claim.sub',z->>'operator',true);
 execute 'set local role authenticated';
 other:=api.start_adhoc_session((z->>'well')::uuid,(z->>'pump')::uuid,(z->>'farm')::uuid,
   (z->>'account')::uuid,'well_diesel',null,(z->>'at')::timestamptz,null,null);
 execute 'reset role';
 perform pg_temp.r6_check(other is not null and not exists(select 1 from ops.operational_occurrences where server_session_id=other),
   'L legacy nullable adhoc start preserved');
 z:=pg_temp.r6_fixture();before_state:=pg_temp.r6_snapshot((z->>'well')::uuid,true);
 perform set_config('r6.fail_well',z->>'well',true);denied:=false;
 begin perform pg_temp.r6_start(z);exception when internal_error then denied:=true;end;
 perform set_config('r6.fail_well','',true);
 perform pg_temp.r6_check(denied and before_state=pg_temp.r6_snapshot((z->>'well')::uuid,true),
   'atomic failure leaves no session occurrence command or resource mutation');
 -- نتائج مجموعة وتسوية حقيقية، لا إقرارات مصطنعة.
 z:=pg_temp.r6_fixture();r:=pg_temp.r6_group(z);
 before_state:=pg_temp.r6_snapshot((z->>'well')::uuid,true);
 execute 'set local role authenticated';
 old_receipt:=api.get_delay_start_group_receipt((z->>'well')::uuid,(z->>'command')::uuid,z->'request');
 execute 'reset role';
 perform pg_temp.r6_check(r->>'status'='accepted' and old_receipt->'receipt'=r
   and pg_temp.r6_group(z)=r and before_state=pg_temp.r6_snapshot((z->>'well')::uuid,true),
   'M group receipts remain read only exact replay');
 z:=pg_temp.r6_fixture();req:=jsonb_set(z->'request','{expected_revision}','-1');
 z:=jsonb_set(z,'{request}',req);rejected:=pg_temp.r6_group(z);
 req:=pg_temp.r6_settlement(z,rejected);other:=gen_random_uuid();
 settled:=pg_temp.r6_settle(z,other,req);
 before_state:=pg_temp.r6_snapshot((z->>'well')::uuid,true);
 execute 'set local role authenticated';
 old_receipt:=api.get_occurrence_settlement_receipt((z->>'well')::uuid,other,req);
 execute 'reset role';
 perform pg_temp.r6_check(settled->>'status'='accepted' and old_receipt->'receipt'=settled
   and before_state=pg_temp.r6_snapshot((z->>'well')::uuid,true),'M historical settlement receipt preserved');
 denied:=false;
 begin perform pg_temp.r6_start(z);exception when invalid_parameter_value then denied:=true;end;
 perform pg_temp.r6_check(denied,'command identity cannot be reused across command types');
 denied:=false;
 begin perform pg_temp.r6_start(jsonb_set(z,'{command}',to_jsonb(gen_random_uuid())));
 exception when check_violation then denied:=true;end;
 perform pg_temp.r6_check(denied,'actual historical interval overlap still rejected');
 perform set_config('request.jwt.claim.sub',f->>'operator',true);
 execute 'set local role authenticated';
 denied:=false;
 begin perform api.record_booking_transition_decision((f->>'well')::uuid,gen_random_uuid(),gen_random_uuid(),'start_next',1,gen_random_uuid());
 exception when feature_not_supported then denied:=true;end;
 perform pg_temp.r6_check(denied,'N record transition remains retired');
 denied:=false;
 begin perform api.execute_pending_booking_start((f->>'well')::uuid,1,gen_random_uuid());
 exception when feature_not_supported then denied:=true;end;
 perform pg_temp.r6_check(denied,'N pending start remains retired');
 execute 'reset role';
 denied:=false;
 begin perform ops.execute_booking_transition((f->>'well')::uuid,1,gen_random_uuid());
 exception when feature_not_supported then denied:=true;end;
 perform pg_temp.r6_check(denied,'N transition executor remains retired');
 -- اختبارات إذن الدخول ومنع الكتابة المباشرة منفصلة عن اختبارات السلوك.
 execute 'set local role anon';denied:=false;
 begin perform api.start_operational_session((f->>'well')::uuid,(f->>'pump')::uuid,(f->>'farm')::uuid,
   (f->>'account')::uuid,'well_diesel',(f->>'at')::timestamptz,gen_random_uuid());
 exception when insufficient_privilege then denied:=true;end;
 execute 'reset role';
 perform pg_temp.r6_check(denied,'anonymous start denied');
 perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);denied:=false;
 execute 'set local role authenticated';
 begin perform api.start_operational_session((f->>'well')::uuid,(f->>'pump')::uuid,(f->>'farm')::uuid,
   (f->>'account')::uuid,'well_diesel',(f->>'at')::timestamptz,gen_random_uuid());
 exception when insufficient_privilege then denied:=true;end;
 execute 'reset role';
 perform pg_temp.r6_check(denied,'actor without well permission denied');
 perform pg_temp.r6_check(not has_table_privilege('authenticated','ops.operational_occurrences','INSERT')
   and not has_table_privilege('authenticated','ops.operational_occurrences','UPDATE'),
   'authenticated cannot fabricate or rebind occurrences');
 perform pg_temp.r6_check(not has_function_privilege('anon',
   'ops.start_operational_session(uuid,uuid,uuid,uuid,text,timestamptz,uuid,uuid,text[],uuid)','EXECUTE'),
   'anonymous internal entry denied');
 perform pg_temp.r6_check(not (select prosecdef from pg_proc where oid=
   'api.start_operational_session(uuid,uuid,uuid,uuid,text,timestamptz,uuid,uuid,text[],uuid)'::regprocedure),
   'public API remains invoker');
end;$test$;
rollback;
