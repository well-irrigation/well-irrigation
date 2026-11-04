\set ON_ERROR_STOP on
-- محلي فقط؛ كل تجهيزات الاختبار والتصحيحات المضبوطة تلغى في النهاية.
begin;
set local timezone='UTC';
set local row_security=on;
create function pg_temp.rb_check(ok boolean,label text) returns void language plpgsql as $$
begin
 if ok is distinct from true then raise exception 'FAIL %',label; end if;
 raise notice 'PASS %',label;
end;$$;
create function pg_temp.rb_fixture(p_tenant uuid default null,p_actor uuid default null)
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
create function pg_temp.rb_start(f jsonb,kind text default 'start_operational_session',
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
create function pg_temp.rb_request(f jsonb) returns jsonb language sql as $$
 select jsonb_build_object('actor_id',f->'operator','well_id',f->'well','pump_id',f->'pump',
 'farm_id',f->'farm','farmer_well_account_id',f->'account','energy_source','well_diesel',
 'started_at',f->'at','fuel_owner_person_id',null,'crops',jsonb_build_array('قمح'),'source_booking_id',null);
$$;
-- بصمة جميع جداول الأعمال، بما فيها التدقيق والصلاحيات؛ لا نكتفي بعدّ الصفوف.
create function pg_temp.rb_snapshot() returns jsonb language plpgsql as $$
declare r record; digest text; result jsonb:='{}';
begin
 for r in select n.nspname,c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where c.relkind in ('r','p') and n.nspname in ('core','ops','sync','billing','audit','finance','inventory','iam')
  order by n.nspname,c.relname loop
  execute format('select md5(coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text)::text,''null'')) from %I.%I t',
    r.nspname,r.relname) into digest;
  result:=result||jsonb_build_object(r.nspname||'.'||r.relname,digest);
 end loop;
 return result;
end;$$;
create function pg_temp.rb_read(w uuid,c uuid,kind text default 'start_operational_session') returns jsonb language plpgsql as $$
declare before_state jsonb:=pg_temp.rb_snapshot();r jsonb;
begin
 execute 'set local role authenticated';r:=api.get_operational_start_receipt(w,c,kind);execute 'reset role';
 if before_state is distinct from pg_temp.rb_snapshot() then raise exception 'FAIL C read changed business state';end if;
 if r->'retry_authorized' is distinct from 'false'::jsonb then raise exception 'FAIL read authorized retry';end if;
 return r;
exception when others then execute 'reset role';raise;
end;$$;
create function pg_temp.rb_denied(w uuid,c uuid) returns boolean language plpgsql as $$
begin perform pg_temp.rb_read(w,c);return false;
exception when insufficient_privilege or invalid_authorization_specification then return true;end;$$;
do $tests$
declare f jsonb; g jsonb; h jsonb; q jsonb; l jsonb; original jsonb; r jsonb; replay jsonb; payload jsonb;
 sid uuid; other_sid uuid; cmd uuid; absent uuid:=gen_random_uuid(); key text; bad jsonb;
 before_state jsonb; command_row sync.processed_commands%rowtype; denied boolean; booking_result jsonb;
begin
 f:=pg_temp.rb_fixture();sid:=pg_temp.rb_start(f,'start_operational_session',(f->>'booking')::uuid);
 select * into command_row from sync.processed_commands where tenant_id=(f->>'tenant')::uuid and command_id=(f->>'command')::uuid;
 original:=command_row.response_payload;
 -- يحاكي ضياع استجابة البدء: القارئ لا يتلقى session id أو طلبًا جديدًا.
 r:=pg_temp.rb_read((f->>'well')::uuid,(f->>'command')::uuid);
 perform pg_temp.rb_check(r->>'status'='accepted' and r->'receipt'=original
   and r->'receipt'->>'id'=sid::text,'A D lost response recovered by original command only');
 replay:=pg_temp.rb_read((f->>'well')::uuid,(f->>'command')::uuid);
 perform pg_temp.rb_check(replay=r,'B C repeated read returns identical original receipt without mutations');
 perform pg_temp.rb_check(not (r->'receipt' ?| array['operational_end_at','planned_end_at','booked_duration_minutes'])
   and (select planned_end_at is null and planned_duration_minutes is null from ops.irrigation_sessions where id=sid),
   'R no duration or booking runtime authority added');
 r:=pg_temp.rb_read((f->>'well')::uuid,absent);
 perform pg_temp.rb_check(r->>'status'='not_found' and r->'receipt'='null','E not found never authorizes resend');
 -- تغيير طابع الجلسة الحالي فقط، دون تغيير أمر البدء أو واقعة الأصل المختومة.
 update ops.irrigation_sessions set started_at=started_at+interval '1 second' where id=sid;
 r:=pg_temp.rb_read((f->>'well')::uuid,(f->>'command')::uuid);
 perform pg_temp.rb_check(r->>'status'='accepted' and r->'receipt'=original
   and (select started_at<>(command_row.request_payload->>'started_at')::timestamptz from ops.irrigation_sessions where id=sid),
   'Q mutable session start does not rewrite original start evidence');
 update ops.irrigation_bookings set status='cancelled',scheduled_start=scheduled_start+interval '1 day',
 scheduled_end=scheduled_end+interval '1 day' where id=(f->>'booking')::uuid;
 r:=pg_temp.rb_read((f->>'well')::uuid,(f->>'command')::uuid);
 perform pg_temp.rb_check(r->>'status'='accepted' and r->'receipt'=original,'R later booking state cannot invalidate original receipt');
 -- بئر آخر في الجهة نفسها، وجهة مستقلة؛ لا فرق عن UUID غائب.
 g:=pg_temp.rb_fixture((f->>'tenant')::uuid,(f->>'operator')::uuid);
 r:=pg_temp.rb_read((g->>'well')::uuid,(f->>'command')::uuid);
 replay:=pg_temp.rb_read((g->>'well')::uuid,absent);
 perform pg_temp.rb_check(r-'command_id'=replay-'command_id' and r->>'status'='not_found','H other well command existence masked');
 h:=pg_temp.rb_fixture();perform set_config('request.jwt.claim.sub',h->>'operator',true);
 r:=pg_temp.rb_read((h->>'well')::uuid,(f->>'command')::uuid);
 perform pg_temp.rb_check(r->>'status'='not_found' and r->'receipt'='null','H other tenant command not disclosed');
 -- نفس UUID في جهتين لا يختلط: المفتاح يظل tenant + command.
 h:=jsonb_set(h,'{command}',f->'command');other_sid:=pg_temp.rb_start(h);
 r:=pg_temp.rb_read((h->>'well')::uuid,(f->>'command')::uuid);
 perform pg_temp.rb_check(r->>'status'='accepted' and r->'receipt'->>'id'=other_sid::text and other_sid<>sid,
   'H same command UUID remains tenant isolated');
 perform set_config('request.jwt.claim.sub',f->>'operator',true);
 update core.well_assignments set status='inactive' where well_id=(f->>'well')::uuid and profile_id=(f->>'operator')::uuid;
 perform pg_temp.rb_check(pg_temp.rb_denied((f->>'well')::uuid,(f->>'command')::uuid),'I inactive assignment denied');
 update core.well_assignments set status='active',role='viewer' where well_id=(f->>'well')::uuid and profile_id=(f->>'operator')::uuid;
 perform pg_temp.rb_check(pg_temp.rb_denied((f->>'well')::uuid,(f->>'command')::uuid),'J active assignment without start permission denied');
 update core.well_assignments set role='operator' where well_id=(f->>'well')::uuid and profile_id=(f->>'operator')::uuid;
 execute 'set local role anon';denied:=false;
 begin perform api.get_operational_start_receipt((f->>'well')::uuid,(f->>'command')::uuid);
 exception when insufficient_privilege then denied:=true;end;
 execute 'reset role';perform pg_temp.rb_check(denied,'K anonymous public receipt denied');
 denied:=false;
 begin perform pg_temp.rb_read((f->>'well')::uuid,null);exception when invalid_parameter_value then denied:=true;end;
 perform pg_temp.rb_check(denied,'command identity mandatory');
 -- طوابير محفوظة صراحةً؛ لا تحول SQL exception إلى رفض دائم مصطنع.
 q:=pg_temp.rb_fixture();payload:=pg_temp.rb_request(q);
 insert into sync.processed_commands(tenant_id,command_id,command_type,entity_id,status,request_payload)
 values((q->>'tenant')::uuid,(q->>'command')::uuid,'start_operational_session',(q->>'well')::uuid,'processing',payload);
 perform set_config('request.jwt.claim.sub',q->>'operator',true);
 r:=pg_temp.rb_read((q->>'well')::uuid,(q->>'command')::uuid);
 perform pg_temp.rb_check(r->>'status'='processing' and r->'receipt'='null','F processing never authorizes resend');
 update sync.processed_commands set response_payload=jsonb_build_object('status','accepted','id','bad')
 where tenant_id=(q->>'tenant')::uuid and command_id=(q->>'command')::uuid;
 r:=pg_temp.rb_read((q->>'well')::uuid,(q->>'command')::uuid);
 perform pg_temp.rb_check(r->>'status'='unresolved' and r->'receipt'='null','processing with terminal looking response fails closed');
 original:=jsonb_build_object('status','rejected','reason','explicit_persisted_test_rejection');
 update sync.processed_commands set status='rejected',response_payload=original
 where tenant_id=(q->>'tenant')::uuid and command_id=(q->>'command')::uuid;
 r:=pg_temp.rb_read((q->>'well')::uuid,(q->>'command')::uuid);
 perform pg_temp.rb_check(r->>'status'='rejected' and r->'receipt'=original,'exact persisted scoped rejection returned');
 update sync.processed_commands set response_payload=null
 where tenant_id=(q->>'tenant')::uuid and command_id=(q->>'command')::uuid;
 r:=pg_temp.rb_read((q->>'well')::uuid,(q->>'command')::uuid);
 perform pg_temp.rb_check(r->>'status'='unresolved','missing persisted rejection is never fabricated');
 -- طفرات بيانات أصلية مضبوطة؛ لا نعطل زناد ربط الواقعة أو نعدله.
 perform set_config('request.jwt.claim.sub',f->>'operator',true);
 original:=command_row.response_payload;
 foreach key in array array['id','occurrence_command_id'] loop
  update sync.processed_commands set response_payload=original-key
  where tenant_id=(f->>'tenant')::uuid and command_id=(f->>'command')::uuid;
  r:=pg_temp.rb_read((f->>'well')::uuid,(f->>'command')::uuid);
  perform pg_temp.rb_check(r->>'status'='unresolved' and r->'receipt'='null','L missing canonical result identity '||key);
 end loop;
 for bad in select v from (values ('[]'::jsonb),('"invalid"'::jsonb),('null'::jsonb),
  (jsonb_build_object('id','not-a-uuid','occurrence_command_id',f->'command')),
  (jsonb_build_object('id',other_sid,'occurrence_command_id',f->'command')),
  (jsonb_build_object('id',sid,'occurrence_command_id',gen_random_uuid()))) x(v) loop
  update sync.processed_commands set response_payload=bad
  where tenant_id=(f->>'tenant')::uuid and command_id=(f->>'command')::uuid;
  r:=pg_temp.rb_read((f->>'well')::uuid,(f->>'command')::uuid);
  perform pg_temp.rb_check(r->>'status'='unresolved' and r->'receipt'='null','L M malformed or inconsistent original result');
 end loop;
 update sync.processed_commands set response_payload=original,request_payload=jsonb_set(command_row.request_payload,'{started_at}',
   to_jsonb((f->>'at')::timestamptz+interval '2 minutes'))
 where tenant_id=(f->>'tenant')::uuid and command_id=(f->>'command')::uuid;
 r:=pg_temp.rb_read((f->>'well')::uuid,(f->>'command')::uuid);
 perform pg_temp.rb_check(r->>'status'='unresolved','M occurrence original facts disagree with command');
 update sync.processed_commands set request_payload=command_row.request_payload,command_type='pause_irrigation_session'
 where tenant_id=(f->>'tenant')::uuid and command_id=(f->>'command')::uuid;
 r:=pg_temp.rb_read((f->>'well')::uuid,(f->>'command')::uuid);
 perform pg_temp.rb_check(r->>'status'='unresolved' and r->'receipt'='null','G wrong command type cannot become a start receipt');
 update sync.processed_commands set command_type=command_row.command_type
 where tenant_id=(f->>'tenant')::uuid and command_id=(f->>'command')::uuid;
 cmd:=gen_random_uuid();
 insert into sync.processed_commands(tenant_id,command_id,command_type,entity_id,status,request_payload,response_payload)
 values((f->>'tenant')::uuid,cmd,'start_operational_session',(f->>'well')::uuid,'accepted',command_row.request_payload,
   jsonb_build_object('id',sid,'occurrence_command_id',cmd));
 r:=pg_temp.rb_read((f->>'well')::uuid,cmd);
 perform pg_temp.rb_check(r->>'status'='unresolved','M current accepted start requires its own occurrence binding');
 -- عقدان قديمان حقيقيان محددان، لا إقرار بديل من الذاكرة الحالية.
 foreach key in array array['start_irrigation_session','start_adhoc_session'] loop
  l:=pg_temp.rb_fixture();update ops.irrigation_bookings set status='cancelled' where id=(l->>'booking')::uuid;
  other_sid:=pg_temp.rb_start(l,key);
  select response_payload into original from sync.processed_commands
   where tenant_id=(l->>'tenant')::uuid and command_id=(l->>'command')::uuid;
  r:=pg_temp.rb_read((l->>'well')::uuid,(l->>'command')::uuid,key);
  perform pg_temp.rb_check(r->>'status'='accepted' and r->'receipt'=original,'N O legacy identified receipt '||key);
  update ops.irrigation_sessions set started_at=started_at+interval '1 second' where id=other_sid;
  replay:=pg_temp.rb_read((l->>'well')::uuid,(l->>'command')::uuid,key);
  perform pg_temp.rb_check(replay=r,'Q legacy receipt independent of mutable session time '||key);
  if key='start_adhoc_session' then
   select request_payload into payload from sync.processed_commands
    where tenant_id=(l->>'tenant')::uuid and command_id=(l->>'command')::uuid;
   update sync.processed_commands set request_payload=null
    where tenant_id=(l->>'tenant')::uuid and command_id=(l->>'command')::uuid;
   r:=pg_temp.rb_read((l->>'well')::uuid,(l->>'command')::uuid,key);
   perform pg_temp.rb_check(r->>'status'='unresolved' and r->'receipt'='null',
     'P incomplete adhoc request is not reconstructed from session');
   update sync.processed_commands set request_payload=payload
    where tenant_id=(l->>'tenant')::uuid and command_id=(l->>'command')::uuid;
  end if;
 end loop;
 l:=pg_temp.rb_fixture();update ops.irrigation_bookings set status='cancelled' where id=(l->>'booking')::uuid;
 other_sid:=pg_temp.rb_start(l,'start_irrigation_session',null,false);
 original:=jsonb_build_object('id',other_sid);
 insert into sync.processed_commands(tenant_id,command_id,command_type,status,response_payload)
 values((l->>'tenant')::uuid,(l->>'command')::uuid,'start_irrigation_session','accepted',original);
 r:=pg_temp.rb_read((l->>'well')::uuid,(l->>'command')::uuid,'start_irrigation_session');
 perform pg_temp.rb_check(r->>'status'='accepted' and r->'receipt'=original
   and not (r->'receipt' ? 'started_at'),'N old NULL request can prove UUID only without fabricating time');
 update sync.processed_commands set response_payload=null
 where tenant_id=(l->>'tenant')::uuid and command_id=(l->>'command')::uuid;
 r:=pg_temp.rb_read((l->>'well')::uuid,(l->>'command')::uuid,'start_irrigation_session');
 perform pg_temp.rb_check(r->>'status'='unresolved' and r->'receipt'='null','P incomplete old evidence not fabricated');
 replay:=pg_temp.rb_read((l->>'well')::uuid,absent,'start_irrigation_session');
 perform pg_temp.rb_check(r-'command_id'=replay-'command_id',
   'H P unattributable legacy row does not disclose existence');
 update sync.processed_commands set response_payload=original
  where tenant_id=(l->>'tenant')::uuid and command_id=(l->>'command')::uuid;
 g:=pg_temp.rb_fixture((l->>'tenant')::uuid,(l->>'operator')::uuid);
 r:=pg_temp.rb_read((g->>'well')::uuid,(l->>'command')::uuid,'start_irrigation_session');
 replay:=pg_temp.rb_read((g->>'well')::uuid,absent,'start_irrigation_session');
 perform pg_temp.rb_check(r-'command_id'=replay-'command_id',
   'H scoped historical legacy command in another well is masked');
 -- عقود الحجز منفصلة؛ القراءة الحالية لا تتبناها.
 l:=pg_temp.rb_fixture();perform set_config('request.jwt.claim.sub',l->>'operator',true);
 execute 'set local role authenticated';
 booking_result:=api.start_irrigation_session_from_booking((l->>'booking')::uuid,(l->>'at')::timestamptz,
   (l->>'command')::uuid,array['قمح']);
 execute 'reset role';
 r:=pg_temp.rb_read((l->>'well')::uuid,(l->>'command')::uuid);
 perform pg_temp.rb_check(r->>'status'='unresolved' and r->'receipt'='null','S booking start not merged into free receipt');
 before_state:=pg_temp.rb_snapshot();execute 'set local role authenticated';
 r:=api.get_booking_start_receipt((l->>'well')::uuid,(l->>'booking')::uuid,(l->>'command')::uuid,
   (l->>'at')::timestamptz,array['قمح']);
 execute 'reset role';
 perform pg_temp.rb_check(r->>'status'='accepted' and r->'receipt'=booking_result
   and before_state=pg_temp.rb_snapshot(),'S dedicated booking receipt unchanged');
 before_state:=pg_temp.rb_snapshot();execute 'set local role authenticated';denied:=false;
 begin perform api.record_booking_transition_decision((l->>'well')::uuid,gen_random_uuid(),gen_random_uuid(),
   'start_next',1,gen_random_uuid());exception when feature_not_supported then denied:=true;end;
 perform pg_temp.rb_check(denied,'T record transition remains retired');
 denied:=false;begin perform api.execute_pending_booking_start((l->>'well')::uuid,1,gen_random_uuid());
 exception when feature_not_supported then denied:=true;end;
 execute 'reset role';perform pg_temp.rb_check(denied and before_state=pg_temp.rb_snapshot(),'T pending start remains retired without writes');
 denied:=false;
 begin perform ops.execute_booking_transition((l->>'well')::uuid,1,gen_random_uuid());
 exception when feature_not_supported then denied:=true;end;
 perform pg_temp.rb_check(denied and before_state=pg_temp.rb_snapshot(),'T transition executor remains retired');
 perform pg_temp.rb_check(not (select prosecdef from pg_proc where oid='api.get_operational_start_receipt(uuid,uuid,text)'::regprocedure)
   and (select provolatile='s' from pg_proc where oid='sync.get_operational_start_receipt_read(uuid,uuid,text)'::regprocedure),
   'security invoker API and stable internal reader');
 perform pg_temp.rb_check(has_function_privilege('authenticated','api.get_operational_start_receipt(uuid,uuid,text)','EXECUTE')
   and has_function_privilege('service_role','api.get_operational_start_receipt(uuid,uuid,text)','EXECUTE')
   and not has_function_privilege('anon','api.get_operational_start_receipt(uuid,uuid,text)','EXECUTE'),
   'explicit role grant symmetry and anonymous denial');
 perform pg_temp.rb_check(has_function_privilege('authenticated','sync.get_operational_start_receipt_read(uuid,uuid,text)','EXECUTE')
   and has_function_privilege('service_role','sync.get_operational_start_receipt_read(uuid,uuid,text)','EXECUTE')
   and not has_function_privilege('anon','sync.get_operational_start_receipt_read(uuid,uuid,text)','EXECUTE'),
   'internal reader role grant symmetry and anonymous denial');
 perform pg_temp.rb_check(not exists(select 1 from pg_proc p,
   lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
   where p.oid in ('api.get_operational_start_receipt(uuid,uuid,text)'::regprocedure,
     'sync.get_operational_start_receipt_read(uuid,uuid,text)'::regprocedure)
     and a.grantee=0 and a.privilege_type='EXECUTE'), 'PUBLIC execute revoked');
end;$tests$;
rollback;
