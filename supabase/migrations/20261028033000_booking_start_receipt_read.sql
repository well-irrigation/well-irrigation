begin;
-- ق-137: قراءة النتيجة الأصلية فقط؛ لا تعديل لعقد البدء أو M114 أو البيانات.
create function sync.get_booking_start_receipt_read(
  p_well_id uuid, p_booking_id uuid, p_command_id uuid,
  p_started_at timestamptz, p_crops text[] default null
)
returns jsonb
language plpgsql stable security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_tenant uuid;
  v_command sync.processed_commands%rowtype;
  v_request jsonb;
  v_expected jsonb;
  v_receipt jsonb;
  v_result jsonb;
  v_session uuid;
  v_started timestamptz;
  v_until timestamptz;
  v_duration integer;
begin
  if v_actor is null then
    raise exception 'booking_start_receipt_requires_authentication' using errcode='28000';
  end if;
  if p_well_id is null or p_booking_id is null or p_command_id is null
     or p_started_at is null or not pg_catalog.isfinite(p_started_at) then
    raise exception 'booking_start_receipt_invalid_inputs' using errcode='22023';
  end if;
  -- Resolve tenant and scope from the booking, never from client claims.
  select w.tenant_id into v_tenant
  from ops.irrigation_bookings b
  join core.wells w on w.id=b.well_id and w.tenant_id=b.tenant_id
  join ops.farmer_well_accounts a on a.id=b.farmer_well_account_id
    and a.well_id=w.id and a.tenant_id=w.tenant_id
  where b.id=p_booking_id and b.well_id=p_well_id
    and exists(select 1 from core.well_assignments wa
      where wa.well_id=w.id and wa.profile_id=v_actor and wa.status='active');
  if v_tenant is null or not coalesce(iam.has_well_permission(p_well_id,'session.start'),false) then
    raise exception 'booking_start_receipt_forbidden' using errcode='42501';
  end if;
  v_result := pg_catalog.jsonb_build_object(
    'contract','get_booking_start_receipt','version',1,
    'well_id',p_well_id,'booking_id',p_booking_id,'command_id',p_command_id,
    'command_type','start_irrigation_session_from_booking',
    'started_at',p_started_at,'crops',pg_catalog.to_jsonb(p_crops),
    'status','unresolved','receipt',null,'retry_authorized',false);
  select c.* into v_command from sync.processed_commands c
  where c.tenant_id=v_tenant and c.command_id=p_command_id;
  if not found then
    return v_result || pg_catalog.jsonb_build_object('status','not_found');
  end if;
  if v_command.command_type is distinct from 'start_irrigation_session_from_booking'
     or v_command.entity_id is distinct from p_booking_id then
    return v_result;
  end if;
  v_request := v_command.request_payload;
  v_expected := pg_catalog.jsonb_build_object('booking_execution_contract_version',113,
    'booking_id',p_booking_id,'started_at',p_started_at,'crops',pg_catalog.to_jsonb(p_crops));
  if pg_catalog.jsonb_typeof(v_request) is distinct from 'object'
     or pg_catalog.jsonb_typeof(v_request->'started_at') is distinct from 'string'
     or (v_request->>'started_at') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$'
     or (v_request-'started_at') is distinct from (v_expected-'started_at') then
    return v_result;
  end if;
  begin
    v_started := (v_request->>'started_at')::timestamptz;
    if not pg_catalog.isfinite(v_started) or v_started is distinct from p_started_at then
      return v_result;
    end if;
  exception when invalid_datetime_format or datetime_field_overflow then return v_result;
  end;
  if v_command.status='processing' and v_command.response_payload is null then
    return v_result || pg_catalog.jsonb_build_object('status','processing');
  end if;
  if v_command.status is distinct from 'accepted' then return v_result; end if;
  v_receipt := v_command.response_payload;
  if pg_catalog.jsonb_typeof(v_receipt) is distinct from 'object'
     or v_receipt->>'booking_id' is distinct from p_booking_id::text
     or v_receipt->>'well_id' is distinct from p_well_id::text
     or v_receipt->>'session_status' is distinct from 'open'
     or v_receipt->>'booking_status' is distinct from 'confirmed'
     or pg_catalog.jsonb_typeof(v_receipt->'session_id') is distinct from 'string'
     or pg_catalog.jsonb_typeof(v_receipt->'started_at') is distinct from 'string'
     or pg_catalog.jsonb_typeof(v_receipt->'operational_end_at') is distinct from 'string'
     or (v_receipt->>'started_at') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$'
     or (v_receipt->>'operational_end_at') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$'
     or pg_catalog.jsonb_typeof(v_receipt->'booked_duration_minutes') is distinct from 'number'
     or (v_receipt->>'booked_duration_minutes') !~ '^[1-9][0-9]*$'
     or (v_receipt ? 'command_id' and v_receipt->>'command_id' is distinct from p_command_id::text)
     or (v_receipt ? 'command_type' and v_receipt->>'command_type' is distinct from v_command.command_type)
     or (v_receipt ? 'tenant_id' and v_receipt->>'tenant_id' is distinct from v_tenant::text) then
    return v_result;
  end if;
  begin
    v_session := (v_receipt->>'session_id')::uuid;
    v_started := (v_receipt->>'started_at')::timestamptz;
    v_until := (v_receipt->>'operational_end_at')::timestamptz;
    v_duration := (v_receipt->>'booked_duration_minutes')::integer;
    if not pg_catalog.isfinite(v_started) or not pg_catalog.isfinite(v_until)
       or v_started is distinct from p_started_at
       or v_until is distinct from v_started+pg_catalog.make_interval(mins=>v_duration) then
      return v_result;
    end if;
  exception when invalid_text_representation or invalid_datetime_format
    or datetime_field_overflow or numeric_value_out_of_range then return v_result;
  end;
  -- The original result is valid even when the session has since ended.
  -- Current schedule/status is never used to manufacture an accepted command.
  if not exists(select 1 from ops.irrigation_sessions s
    where s.id=v_session and s.well_id=p_well_id and s.booking_id=p_booking_id
      and s.started_at=v_started) then return v_result; end if;
  return v_result || pg_catalog.jsonb_build_object('status','accepted','receipt',v_receipt);
end;
$function$;
revoke all on function sync.get_booking_start_receipt_read(uuid,uuid,uuid,timestamptz,text[])
  from public,anon,authenticated,service_role;
grant execute on function sync.get_booking_start_receipt_read(uuid,uuid,uuid,timestamptz,text[])
  to authenticated,service_role;

create function api.get_booking_start_receipt(
  p_well_id uuid, p_booking_id uuid, p_command_id uuid,
  p_started_at timestamptz, p_crops text[] default null
)
returns jsonb
language sql stable security invoker
set search_path = pg_catalog, pg_temp
as $function$
  select sync.get_booking_start_receipt_read(p_well_id,p_booking_id,p_command_id,p_started_at,p_crops);
$function$;
revoke all on function api.get_booking_start_receipt(uuid,uuid,uuid,timestamptz,text[])
  from public,anon,authenticated,service_role;
grant execute on function api.get_booking_start_receipt(uuid,uuid,uuid,timestamptz,text[])
  to authenticated,service_role;
commit;
