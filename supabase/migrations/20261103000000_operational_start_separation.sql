begin;
-- R6-A: الحجز ترتيب وتذكير فقط. البدء والإيقاف فعل بشري صريح.
-- هجرة متابعة؛ لا تعديل للتاريخ أو الإقرارات أو هوية واقعة R4.
-- مسارات التوافق القديمة تحتفظ بتواقيعها؛ التكامل الحالي يستخدم المدخل الجديد.

-- مراجعة الجدول تخص التخطيط وموارده؛ كتابة جلسة لا تغيّر نسخة الخطة.
-- الأقفال وحارس التداخل التاريخي وهوية الواقعة باقية.
create or replace function ops.guard_operational_schedule_write() returns trigger
language plpgsql security definer set search_path=pg_catalog,pg_temp as $f$
declare w uuid; o ops.operational_occurrences%rowtype; historical boolean := false; changed boolean;
begin
 if TG_TABLE_NAME='operational_occurrences' then
   if TG_OP='DELETE' then raise exception 'occurrence_delete_disabled' using errcode='23514'; end if;
   if TG_OP='UPDATE' and (to_jsonb(new)-array['status','resolved_at']) is distinct from
       (to_jsonb(old)-array['status','resolved_at']) then
     raise exception 'occurrence_identity_immutable' using errcode='23514';
   end if;
   if TG_OP='UPDATE' and old.status='accepted' and to_jsonb(new) is distinct from to_jsonb(old) then
     raise exception 'accepted_occurrence_immutable' using errcode='23514';
   end if;
   if not exists(select 1 from core.wells x where x.id=new.well_id and x.tenant_id=new.tenant_id) then
     raise exception 'occurrence_scope_mismatch' using errcode='23514';
   end if;
   return new;
 end if;
 if TG_TABLE_NAME='wells' then
   if (to_jsonb(new)-'operational_schedule_revision') is distinct from
      (to_jsonb(old)-'operational_schedule_revision') then
     new.operational_schedule_revision:=old.operational_schedule_revision+1;
   end if;
   return new;
 end if;
 w:=case when TG_OP='DELETE' then old.well_id else new.well_id end;
 -- نقل صف بين بئرين ليس وسيلة لتجاوز مراجعة أي منهما.
 if TG_OP='UPDATE' and old.well_id is distinct from new.well_id then
   perform ops.lock_operational_scope(least(old.well_id,new.well_id));
   perform ops.lock_operational_scope(greatest(old.well_id,new.well_id));
   update core.wells set operational_schedule_revision=operational_schedule_revision+1 where id=old.well_id;
 else perform ops.lock_operational_scope(w); end if;
 if TG_TABLE_NAME='irrigation_sessions' and TG_OP<>'DELETE' then
   select * into o from ops.operational_occurrences where server_session_id=new.id
     and provenance='historical_settlement';
   historical:=found;
   if historical and (new.well_id<>o.well_id or new.status<>'closed' or new.started_at is distinct from o.started_at
      or new.ended_at is distinct from o.ended_at or new.booking_id is not null) then
     raise exception 'historical_session_identity_mismatch' using errcode='23514';
   end if;
   if exists(select 1 from ops.irrigation_sessions s
      where s.id<>new.id and (s.well_id=w or s.pump_id=new.pump_id)
      and tstzrange(s.started_at,s.ended_at,'[)') && tstzrange(new.started_at,new.ended_at,'[)')
      and (historical or exists(select 1 from ops.operational_occurrences x
           where x.server_session_id=s.id and x.provenance='historical_settlement'))) then
     raise exception 'historical_interval_conflict' using errcode='23514';
   end if;
 end if;
 if TG_OP='UPDATE' then changed:=to_jsonb(new) is distinct from to_jsonb(old);else changed:=true;end if;
 if changed and not historical and TG_TABLE_NAME<>'irrigation_sessions' then
   update core.wells set operational_schedule_revision=operational_schedule_revision+1 where id=w;
 end if;
 if TG_OP='DELETE' then return old; end if;
 return new;
end;$f$;

-- قيد مدة الحجز القديم يبقى للتوافق فقط. المسار المحدد الجديد لا يستمد
-- أي إذن من وجود حجز أو مدته أو حالته أو نسخته.
create or replace function ops.enforce_adhoc_duration_vs_next_booking()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_booking_id uuid;
  v_started_at timestamptz;
  v_planned_end_at timestamptz;
  v_well_id uuid;
  v_next_start timestamptz;
begin
  -- إثبات المسار الحالي من سجل أوامر خاص، لا من راية يرسلها العميل.
  -- فرع processing لازم حين يطلب المستدعي فحص القيد فورًا أثناء INSERT؛
  -- المعاملة لا تقبل الأمر إلا بعد إنشاء ربط الواقعة الفريد.
  if exists (
    select 1 from sync.processed_commands c
    where c.tenant_id=(select w.tenant_id from core.wells w where w.id=new.well_id)
      and c.entity_id=new.well_id
      and c.command_type='start_operational_session'
      and c.request_payload->>'actor_id'=new.operator_profile_id::text
      and (c.request_payload->>'well_id')::uuid=new.well_id
      and (c.request_payload->>'pump_id')::uuid=new.pump_id
      and (c.request_payload->>'farm_id')::uuid=new.farm_id
      and (c.request_payload->>'farmer_well_account_id')::uuid=new.farmer_well_account_id
      and (c.request_payload->>'started_at')::timestamptz=new.started_at
      and ((c.status='processing' and c.response_payload is null)
        or (c.status='accepted' and c.response_payload->>'id'=new.id::text
          and exists(select 1 from ops.operational_occurrences o
            where o.tenant_id=c.tenant_id and o.occurrence_command_id=c.command_id
              and o.server_session_id=new.id and o.status='accepted')))
  ) then return null; end if;
  if exists(select 1 from ops.operational_occurrences o
    join ops.irrigation_sessions s on s.id=o.server_session_id
    join sync.processed_commands c on c.tenant_id=o.tenant_id and c.command_id=o.settlement_command_id
    where s.id=new.id and o.provenance='historical_settlement' and o.status='accepted'
      and s.status='closed' and s.started_at=o.started_at and s.ended_at=o.ended_at
      and c.command_type='settle_operational_occurrence' and c.status='accepted'
      and c.response_payload->>'server_session_id'=s.id::text) then return null; end if;
  select s.booking_id, s.started_at, s.planned_end_at, s.well_id
    into v_booking_id, v_started_at, v_planned_end_at, v_well_id
  from ops.irrigation_sessions s
  where s.id = new.id;
  if not found or v_booking_id is not null then
    return null;  -- حُذف الصف، أو جلسة محجوزة نهايتها من الحجز (معفاة).
  end if;
  -- الحجز المانع: أبكر مؤكّد غير مستهلك لم ينتهِ موعده مقابل بداية الجلسة.
  -- يغطّي القادم (scheduled_start > started) والمستحق معًا: المستحق يُرفَض
  -- حتمًا لأنّ planned_end > started_at >= scheduled_start.
  select b.scheduled_start into v_next_start
  from ops.irrigation_bookings b
  where b.well_id = v_well_id and b.status = 'confirmed'
    and b.scheduled_end > v_started_at
    and not exists (select 1 from ops.irrigation_sessions s2 where s2.booking_id = b.id)
  order by b.scheduled_start asc, b.priority desc, b.public_code asc
  limit 1;
  if not found then
    return null;  -- لا حجز قادم: بدء حرّ بلا مدة مقبول.
  end if;
  if v_planned_end_at is null then
    raise exception 'بدء السقي الحر يتطلّب مدة مخطّطة لوجود حجز مؤكّد قادم على البئر'
      using errcode = '23514';
  end if;
  if v_planned_end_at > v_next_start then
    raise exception 'المدة المخطّطة تتجاوز بداية الحجز القادم؛ لا تقصير صامت'
      using errcode = '23514';
  end if;
  return null;
end;
$function$;


create function ops.start_operational_session(
 p_well_id uuid,
 p_pump_id uuid,
 p_farm_id uuid,
 p_farmer_well_account_id uuid,
 p_energy_source text,
 p_started_at timestamptz,
 p_command_id uuid,
 p_fuel_owner_person_id uuid default null,
 p_crops text[] default null,
 p_source_booking_id uuid default null
) returns uuid
language plpgsql volatile security definer
set search_path=pg_catalog,pg_temp as $function$
declare
 actor uuid:=auth.uid(); tenant uuid; request jsonb; guard jsonb;
 command sync.processed_commands%rowtype; sid uuid; result jsonb;
begin
 if actor is null or p_well_id is null
    or not coalesce(iam.has_well_permission(p_well_id,'session.start'),false) then
   raise exception 'operational_start_forbidden' using errcode='42501';
 end if;
 if p_command_id is null or p_started_at is null or not isfinite(p_started_at)
    or p_started_at>clock_timestamp() or p_pump_id is null or p_farm_id is null
    or p_farmer_well_account_id is null or p_energy_source is null then
   raise exception 'operational_start_identity_and_actual_facts_required' using errcode='22023';
 end if;
 -- لا expected_revision هنا؛ القفل تسلسل كتابة فقط وليس إذنًا من الخطة.
 perform ops.lock_operational_scope(p_well_id,true);
 select tenant_id into strict tenant from core.wells where id=p_well_id;
 request:=jsonb_build_object('actor_id',actor,'well_id',p_well_id,'pump_id',p_pump_id,
   'farm_id',p_farm_id,'farmer_well_account_id',p_farmer_well_account_id,
   'energy_source',p_energy_source,'started_at',
   to_char(p_started_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
   'fuel_owner_person_id',p_fuel_owner_person_id,'crops',to_jsonb(p_crops),
   'source_booking_id',p_source_booking_id);
 guard:=sync.begin_command(tenant,p_command_id,'start_operational_session',request,p_well_id);
 if coalesce((guard->>'duplicate')::boolean,false) then
   select * into strict command from sync.processed_commands
     where tenant_id=tenant and command_id=p_command_id;
   if command.command_type is distinct from 'start_operational_session'
      or command.entity_id is distinct from p_well_id
      or command.request_payload is distinct from request then
     raise exception 'operational_start_idempotency_mismatch' using errcode='22023';
   end if;
   if command.status is distinct from 'accepted' then
     raise exception 'operational_start_unresolved' using errcode='55000';
   end if;
   sid:=(command.response_payload->>'id')::uuid;
   if not exists(select 1 from ops.operational_occurrences o
      join ops.irrigation_sessions s on s.id=o.server_session_id
      where o.tenant_id=tenant and o.well_id=p_well_id
        and o.occurrence_command_id=p_command_id and o.original_request_id=p_command_id
        and o.server_session_id=sid and o.status='accepted'
        and s.well_id=p_well_id) then
     raise exception 'operational_start_binding_missing' using errcode='23514';
   end if;
   return sid;
 end if;
 -- لا فحص لحالة الحجز أو مواعيده أو مدته؛ نتحقق من النطاق فقط.
 if p_source_booking_id is not null and not exists(
   select 1 from ops.irrigation_bookings b
   where b.id=p_source_booking_id and b.tenant_id=tenant and b.well_id=p_well_id
 ) then
   raise exception 'operational_start_booking_scope_mismatch' using errcode='22023';
 end if;
 -- البدء المفتوح لا يمكن أن يسبق نهاية تنفيذ مغلق فعليًا على المورد.
 -- الجلسات المفتوحة تفحصها نواة التزامن بقواعد السعة القائمة.
 if exists(select 1 from ops.irrigation_sessions s
   where (s.well_id=p_well_id or s.pump_id=p_pump_id) and s.ended_at is not null
     and tstzrange(s.started_at,s.ended_at,'[)') && tstzrange(p_started_at,null,'[)')) then
   raise exception 'actual_session_interval_conflict' using errcode='23514';
 end if;
 sid:=ops.start_irrigation_session(p_well_id,p_pump_id,p_farm_id,
   p_farmer_well_account_id,actor,p_energy_source,p_started_at,p_fuel_owner_person_id,p_crops);
 -- لا كتابة booking_id ولا planned_end_at ولا مدّة مفترضة في الجلسة.
 result:=jsonb_build_object('id',sid,'occurrence_command_id',p_command_id);
 insert into ops.operational_occurrences(
   tenant_id,occurrence_command_id,well_id,source_booking_id,original_request_id,
   original_operator_id,started_at,original_facts,provenance,server_session_id,status,resolved_at)
 values(tenant,p_command_id,p_well_id,p_source_booking_id,p_command_id,actor,p_started_at,
   jsonb_build_object('request',request,'result',result),'accepted_start',sid,'accepted',clock_timestamp());
 perform sync.finish_command(tenant,p_command_id,'accepted',result);
 return sid;
end;
$function$;

create function api.start_operational_session(
 p_well_id uuid,
 p_pump_id uuid,
 p_farm_id uuid,
 p_farmer_well_account_id uuid,
 p_energy_source text,
 p_started_at timestamptz,
 p_command_id uuid,
 p_fuel_owner_person_id uuid default null,
 p_crops text[] default null,
 p_source_booking_id uuid default null
) returns uuid language sql volatile security invoker
set search_path=pg_catalog,pg_temp as $function$
 select ops.start_operational_session(p_well_id,p_pump_id,p_farm_id,
   p_farmer_well_account_id,p_energy_source,p_started_at,p_command_id,
   p_fuel_owner_person_id,p_crops,p_source_booking_id);
$function$;

revoke all on function ops.start_operational_session(uuid,uuid,uuid,uuid,text,timestamptz,uuid,uuid,text[],uuid)
 from public,anon,authenticated,service_role;
grant execute on function ops.start_operational_session(uuid,uuid,uuid,uuid,text,timestamptz,uuid,uuid,text[],uuid)
 to authenticated,service_role;
revoke all on function api.start_operational_session(uuid,uuid,uuid,uuid,text,timestamptz,uuid,uuid,text[],uuid)
 from public,anon,authenticated,service_role;
grant execute on function api.start_operational_session(uuid,uuid,uuid,uuid,text,timestamptz,uuid,uuid,text[],uuid)
 to authenticated,service_role;
comment on function api.start_operational_session(uuid,uuid,uuid,uuid,text,timestamptz,uuid,uuid,text[],uuid)
 is 'R6-A: بدء بشري محدد بأمره الأصلي؛ الحجز منشأ اختياري فقط؛ لا مدة أو نهاية أو نسخة جدول تحكم التنفيذ.';
comment on function api.start_session_with_booking_delays(uuid,uuid,jsonb)
 is 'NOT_FOR_NORMAL_OPERATIONAL_START: أداة تخطيط جماعية قديمة؛ الإقرارات التاريخية محفوظة؛ البدء الحالي عبر api.start_operational_session.';
comment on function ops.start_booking_session_core(uuid,uuid,timestamptz,text[],boolean)
 is 'توافق قديم فقط: operational_end_at نهاية متوقعة للعرض/الإقرار، وليست أمر إيقاف أو تسوية مالية. البدء الحالي عبر api.start_operational_session.';
comment on function api.evaluate_well_booking_transition(uuid)
 is 'قراءة توافق قديمة؛ operational_end_at وreached_operational_end معلومات تخطيط فقط بلا سلطة بدء أو إيقاف أو تحرير مورد أو مال.';
commit;
