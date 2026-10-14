-- Package A: إغلاق صريح للسلسلة الأخيرة بعد الإكمال المحاسبي.
-- لا تعديل لزناد الإغلاق ولا لهجرة وظيفية مختومة.
begin;

create function ops.end_booking_transition_chain(
  p_session_id uuid,
  p_actor uuid,
  p_command_id uuid
) returns jsonb
language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_session ops.irrigation_sessions%rowtype;
  v_chain ops.booking_transition_chains%rowtype;
  v_booking ops.irrigation_bookings%rowtype;
  v_tenant uuid;
  v_ids uuid[];
  v_guard jsonb;
  v_payload jsonb := jsonb_build_object('version',1,'session_id',p_session_id);
  v_stored sync.processed_commands%rowtype;
  v_response jsonb;
  v_reason text;
  v_day date;
  v_window tstzrange;
begin
  v_response := jsonb_build_object('contract','end_booking_transition_chain','version',1,
    'status','rejected','session_id',p_session_id);
  if p_actor is null or auth.uid() is null or p_actor is distinct from auth.uid() then
    return v_response || jsonb_build_object('reason_code','actor_mismatch');
  end if;
  if p_command_id is null then
    return v_response || jsonb_build_object('reason_code','command_id_required');
  end if;
  select s.* into v_session from ops.irrigation_sessions s where s.id=p_session_id;
  if not found then return v_response || jsonb_build_object('reason_code','session_not_found'); end if;
  if not iam.has_well_permission(v_session.well_id,'session.complete') then
    return v_response || jsonb_build_object('reason_code','unauthorized');
  end if;
  select tenant_id into v_tenant from core.wells where id=v_session.well_id;

  v_guard := sync.begin_session_command(p_session_id,p_command_id,'end_booking_transition_chain',v_payload);
  select pc.* into strict v_stored from sync.processed_commands pc
    where pc.tenant_id=v_tenant and pc.command_id=p_command_id for update;
  if v_stored.command_type is distinct from 'end_booking_transition_chain'
     or v_stored.entity_id is distinct from p_session_id
     or v_stored.request_payload is distinct from v_payload then
    raise exception 'معرّف العملية مستخدم لمحتوى مختلف' using errcode='22023';
  end if;
  if coalesce((v_guard->>'duplicate')::boolean,false) then
    if v_stored.status in ('accepted','rejected','conflict') and v_stored.response_payload is not null then
      return v_stored.response_payload;
    end if;
    raise exception 'العملية نفسها قيد المعالجة' using errcode='40001';
  end if;

  -- ترتيب القفل القائم: settings → session → chain → booking → pump.
  -- كل قفل لبئر/جلسة واحدة؛ لا قفل عام ولا مسح عابر للآبار.
  perform 1 from core.well_settings where well_id=v_session.well_id for update;
  select s.* into strict v_session from ops.irrigation_sessions s where s.id=p_session_id for update;
  v_response := v_response || jsonb_build_object('well_id',v_session.well_id);
  if v_session.booking_id is null then v_reason:='session_not_booked';
  elsif v_session.status<>'closed' or v_session.ended_at is null then v_reason:='session_not_closed';
  elsif not exists(select 1 from billing.session_charges sc
    where sc.session_id=p_session_id and sc.well_id=v_session.well_id) then v_reason:='session_not_settled';
  end if;

  if v_reason is null then
    select array_agg(c.id) into v_ids from (
      select id from ops.booking_transition_chains
      where well_id=v_session.well_id and status<>'ended' limit 2 for update
    ) c;
    if coalesce(cardinality(v_ids),0)=0 then
      v_reason:='no_non_ended_chain';
    elsif cardinality(v_ids)<>1 then v_reason:='ambiguous_chain';
    else
      select * into strict v_chain from ops.booking_transition_chains where id=v_ids[1];
      v_response:=v_response || jsonb_build_object('chain_id',v_chain.id);
      if v_chain.current_session_id is distinct from p_session_id then v_reason:='session_not_chain_current';
      elsif v_chain.status<>'decision_required' then v_reason:='chain_state_not_terminal';
      elsif v_chain.next_booking_id is not null then v_reason:='chain_next_booking_set';
      end if;
    end if;
  end if;

  if v_reason is null then
    select * into v_booking from ops.irrigation_bookings where id=v_session.booking_id for key share;
    if not found or v_booking.well_id is distinct from v_session.well_id then
      v_reason:='booking_session_mismatch';
    else
      -- نفس نافذة api.get_well_day_schedule(p_day): منتصف الليل في Asia/Aden.
      -- يوم الحجز لا يوم وصول الأمر المتأخر؛ لا يحجب حجز اليوم التالي إنهاء هذا اليوم.
      v_day := (v_booking.scheduled_start at time zone 'Asia/Aden')::date;
      v_window := tstzrange((v_day::timestamp) at time zone 'Asia/Aden',
        ((v_day+1)::timestamp) at time zone 'Asia/Aden','[)');
      -- شرط الفترة يطابق GiST الجزئي irrigation_bookings_no_confirmed_well_overlap.
      if exists(select 1 from ops.irrigation_bookings b
        where b.well_id=v_session.well_id and b.status='confirmed'
          and b.scheduled_start>v_booking.scheduled_start
          and b.scheduled_start<upper(v_window)
          and tstzrange(b.scheduled_start,b.scheduled_end,'[)') &&
              tstzrange(v_booking.scheduled_start,upper(v_window),'[)')
        limit 1) then v_reason:='next_booking_exists'; end if;
    end if;
  end if;

  if v_reason is null then
    -- يبدأ السقي القائم تحت قفل المضخة نفسه؛ لا يُقبل الإنهاء مع جلسة مفتوحة.
    perform 1 from core.pumps where id=v_session.pump_id for update;
    if exists(select 1 from ops.irrigation_sessions s
      where s.well_id=v_session.well_id and s.status='open' limit 1) then
      v_reason:='open_session_exists';
    end if;
  end if;

  if v_reason is not null then
    v_response := v_response || jsonb_build_object('reason_code',v_reason);
    perform sync.finish_session_command(p_session_id,p_command_id,'rejected',v_response);
    return v_response;
  end if;

  update ops.booking_transition_chains set status='ended',ended_at=v_session.ended_at,
    ended_reason='final_booking_completed' where id=v_chain.id;
  v_response := jsonb_build_object('contract','end_booking_transition_chain','version',1,
    'status','ended','chain_id',v_chain.id,'session_id',p_session_id,'well_id',v_session.well_id,
    'ended_at',v_session.ended_at,'ended_reason','final_booking_completed');
  perform sync.finish_session_command(p_session_id,p_command_id,'accepted',v_response);
  return v_response;
end;
$function$;
revoke all on function ops.end_booking_transition_chain(uuid,uuid,uuid)
  from public,anon,authenticated,service_role,booking_automation_executor;

-- ممر داخلي محدود، كما في قارئ المصالحة: API invoker لا يحتاج EXECUTE للنواة.
-- sync غير مكشوفة عبر Data API؛ لا actor من العميل ولا كتابة مباشرة للجداول.
create function sync.end_booking_transition_chain_command(p_session_id uuid,p_command_id uuid)
returns jsonb language sql volatile security definer
set search_path = pg_catalog, pg_temp
as $function$
  select ops.end_booking_transition_chain(p_session_id,auth.uid(),p_command_id);
$function$;
revoke all on function sync.end_booking_transition_chain_command(uuid,uuid)
  from public,anon,authenticated,service_role,booking_automation_executor;
grant execute on function sync.end_booking_transition_chain_command(uuid,uuid) to authenticated,service_role;

create function api.end_booking_transition_chain(p_session_id uuid,p_command_id uuid)
returns jsonb language sql volatile security invoker
set search_path = pg_catalog, pg_temp
as $function$
  select sync.end_booking_transition_chain_command(p_session_id,p_command_id);
$function$;
revoke all on function api.end_booking_transition_chain(uuid,uuid)
  from public,anon,authenticated,service_role,booking_automation_executor;
grant execute on function api.end_booking_transition_chain(uuid,uuid) to authenticated,service_role;
commit;
