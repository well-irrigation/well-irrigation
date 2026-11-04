begin;

-- =============================================================================
-- هجرة تقنية مستقلة: إنهاء الاعتماد على سلاسل الانتقال التلقائي للحجوزات
--
-- 1. فصل عقد بدء الجلسة المحجوزة (ops.start_booking_session_core) عن سلاسل الانتقال.
-- 2. فصل عقد إكمال الجلسة المحجوزة (sync.begin_booking_completion_command) عن سلاسل الانتقال.
-- 3. إبطال زناد مصالحة السلسلة عند إغلاق الجلسة لمنع إعادة إنشاء decision_required.
-- 4. إغلاق وإبطال نقاط الدخول القديمة للانتقال التلقائي دون أي آثار جانبية.
-- =============================================================================

-- 1. نواة بدء الجلسة المحجوزة: مستقلة تمامًا عن جداول وسلاسل الانتقال
create or replace function ops.start_booking_session_core(
  p_booking_id uuid,
  p_operator_profile_id uuid,
  p_started_at timestamptz,
  p_crops text[] default null,
  p_executing_pending_decision boolean default false
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_well_id uuid;
  v_tenant_id uuid;
  v_booking ops.irrigation_bookings%rowtype;
  v_readiness jsonb;
  v_pump_id uuid;
  v_session_id uuid;
  v_operational_end_at timestamptz;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل بدء جلسة من حجز';
  end if;
  if p_operator_profile_id is distinct from v_actor then
    raise exception 'معرف المشغل يجب أن يطابق المستخدم المسجل حاليًا';
  end if;
  if p_executing_pending_decision is distinct from false then
    raise exception 'legacy_booking_automation_disabled' using errcode = '0A000';
  end if;
  if p_started_at is null then
    raise exception 'زمن البداية الفعلي مطلوب';
  end if;

  if p_started_at > clock_timestamp() then
    raise exception 'زمن البداية الفعلي لا يكون في المستقبل'
      using errcode = '22023';
  end if;

  select b.well_id, b.tenant_id into v_well_id, v_tenant_id
  from ops.irrigation_bookings b
  where b.id = p_booking_id;
  if not found then
    raise exception 'الحجز غير موجود أو لا تملك وصولًا إليه';
  end if;

  if not exists (
    select 1 from core.well_assignments wa
    where wa.well_id = v_well_id and wa.profile_id = v_actor and wa.status = 'active'
  ) or not iam.has_well_permission(v_well_id, 'session.start') then
    raise exception 'booking_start_forbidden' using errcode = '42501';
  end if;
  -- The existing common pump lock/unique-open-session constraint remains the
  -- serialization point shared with ad-hoc starts. No chain lock is acquired.
  select b.*
    into v_booking
  from ops.irrigation_bookings b
  where b.id = p_booking_id
  for update;

  if not found then
    raise exception 'الحجز غير موجود أو لا تملك وصولًا إليه';
  end if;
  if not iam.has_well_permission(v_booking.well_id, 'session.start') then
    raise exception 'لا تملك صلاحية بدء جلسة على هذا البئر';
  end if;
  if v_booking.status <> 'confirmed' then
    raise exception 'لا يمكن بدء جلسة من حجز غير مؤكد';
  end if;
  if exists (
    select 1
    from ops.irrigation_sessions s
    where s.booking_id = p_booking_id
  ) then
    raise exception 'الحجز مرتبط بجلسة سابقة ولا يمكن بدء جلسة ثانية';
  end if;

  v_readiness := ops.evaluate_booking_execution_readiness(
    v_booking.well_id,
    v_booking.scheduled_start,
    v_booking.scheduled_end,
    v_booking.expected_energy_source,
    v_booking.alternative_energy_source
  );

  if not coalesce((v_readiness ->> 'ready')::boolean, false) then
    raise exception 'الحجز غير جاهز للتنفيذ: %',
      coalesce(v_readiness ->> 'reason_code', 'unknown');
  end if;

  if v_booking.farm_id is null
     or not exists (
       select 1
       from ops.farmer_well_accounts fwa
       join ops.farms f
         on f.id = v_booking.farm_id
        and f.well_id = fwa.well_id
        and f.farmer_well_account_id = fwa.id
        and f.status = 'active'
       where fwa.id = v_booking.farmer_well_account_id
         and fwa.well_id = v_booking.well_id
         and fwa.tenant_id = v_booking.tenant_id
         and exists (select 1 from core.wells w
           where w.id = v_booking.well_id and w.tenant_id = v_booking.tenant_id)
         and fwa.status = 'active'
     ) then
    raise exception 'الحجز غير جاهز للتنفيذ: invalid_farmer_or_farm';
  end if;

  v_pump_id := (v_readiness ->> 'active_pump_id')::uuid;
  perform 1
  from core.pumps p
  where p.id = v_pump_id
    and p.well_id = v_booking.well_id
    and p.status = 'active'
  for update;
  if not found then
    raise exception 'الحجز غير جاهز للتنفيذ: active_pump_missing';
  end if;

  if exists (
    select 1
    from ops.irrigation_sessions s
    where s.well_id = v_booking.well_id
      and s.status = 'open'
  ) then
    raise exception 'لا يمكن بدء الحجز: توجد جلسة مفتوحة مانعة على البئر';
  end if;

  v_session_id := ops.start_irrigation_session(
    v_booking.well_id,
    v_pump_id,
    v_booking.farm_id,
    v_booking.farmer_well_account_id,
    v_actor,
    v_booking.expected_energy_source,
    p_started_at,
    null,
    p_crops
  );

  update ops.irrigation_sessions
  set booking_id = p_booking_id
  where id = v_session_id;

  if not found then
    raise exception 'تعذر ربط جلسة السقي بالحجز';
  end if;

  v_operational_end_at := p_started_at
    + make_interval(mins => v_booking.expected_duration_minutes);

  return jsonb_build_object(
    'booking_id', p_booking_id,
    'booking_status', v_booking.status,
    'session_id', v_session_id,
    'session_status', 'open',
    'well_id', v_booking.well_id,
    'farmer_well_account_id', v_booking.farmer_well_account_id,
    'farm_id', v_booking.farm_id,
    'pump_id', v_pump_id,
    'energy_source', v_booking.expected_energy_source,
    'alternative_energy_source', v_booking.alternative_energy_source,
    'started_at', p_started_at,
    'booked_duration_minutes', v_booking.expected_duration_minutes,
    'operational_end_at', v_operational_end_at
  );
end;
$function$;

revoke all on function ops.start_booking_session_core(uuid, uuid, timestamptz, text[], boolean)
  from public, anon, authenticated, service_role;

-- 2. إكمال الجلسة المحجوزة: فحص الجلسة والصلاحية دون اشتراط عضوية السلاسل
create or replace function sync.begin_booking_completion_command(
  p_session_id uuid,
  p_ended_at timestamptz,
  p_fuel_quantity_ml bigint,
  p_fuel_measurement_type text,
  p_fuel_tank_id uuid,
  p_command_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_tenant_id uuid;
  v_well_id uuid;
  v_payload jsonb;
  v_guard jsonb;
  v_stored_type text;
  v_stored_payload jsonb;
  v_status text;
  v_response jsonb;
  v_entity_id uuid;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إكمال جلسة محجوزة';
  end if;
  if p_command_id is null then
    raise exception 'معرّف العملية مطلوب';
  end if;

  select w.tenant_id, s.well_id
    into v_tenant_id, v_well_id
  from ops.irrigation_sessions s
  join core.wells w on w.id = s.well_id
  where s.id = p_session_id
    and exists (
      select 1 from core.well_assignments wa
      where wa.well_id = s.well_id
        and wa.profile_id = v_actor
        and wa.status = 'active'
    );
  if v_tenant_id is null then
    raise exception 'الجلسة غير موجودة أو لا تملك وصولًا إليها';
  end if;
  if not iam.has_well_permission(v_well_id, 'session.complete') then
    raise exception 'لا تملك صلاحية إكمال جلسة على هذا البئر';
  end if;

  -- Prove a real booking association from server data; a free session must
  -- continue to use complete_irrigation_session, never this booking contract.
  if not exists (
    select 1 from ops.irrigation_sessions s
    join ops.irrigation_bookings b on b.id = s.booking_id
    join core.wells w on w.id = s.well_id
    join ops.farmer_well_accounts a on a.id = s.farmer_well_account_id
    where s.id = p_session_id and s.well_id = v_well_id
      and s.booking_id is not null and b.well_id = s.well_id
      and b.tenant_id = w.tenant_id and a.tenant_id = w.tenant_id
      and a.well_id = s.well_id and b.farmer_well_account_id = a.id
      and b.farm_id = s.farm_id
  ) then
    raise exception 'booking_completion_requires_booked_session' using errcode = '22023';
  end if;

  v_payload := jsonb_build_object(
    'booking_execution_contract_version', 113,
    'session_id', p_session_id,
    'ended_at', p_ended_at,
    'fuel_quantity_ml', p_fuel_quantity_ml,
    'fuel_measurement_type', p_fuel_measurement_type,
    'fuel_tank_id', p_fuel_tank_id
  );

  v_guard := sync.begin_command(
    v_tenant_id,
    p_command_id,
    'complete_booking_session',
    v_payload,
    p_session_id
  );

  if not coalesce((v_guard ->> 'duplicate')::boolean, false) then
    return jsonb_build_object('duplicate', false, 'well_id', v_well_id);
  end if;

  select pc.command_type, pc.request_payload, pc.status, pc.response_payload, pc.entity_id
  into v_stored_type, v_stored_payload, v_status, v_response, v_entity_id
  from sync.processed_commands pc
  where pc.tenant_id = v_tenant_id and pc.command_id = p_command_id;

  if not found
     or v_stored_type is distinct from 'complete_booking_session'
     or v_stored_payload is distinct from v_payload
     or v_entity_id is distinct from p_session_id then
    raise exception 'معرّف العملية مستخدم لمحتوى مختلف';
  end if;

  return jsonb_build_object(
    'duplicate', true,
    'status', v_status,
    'response', v_response,
    'well_id', v_well_id
  );
end;
$function$;

revoke all on function sync.begin_booking_completion_command(uuid, timestamptz, bigint, text, uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function sync.begin_booking_completion_command(uuid, timestamptz, bigint, text, uuid, uuid)
  to authenticated, service_role;

-- 3. إبطال زناد مصالحة السلسلة عند إغلاق الجلسة
drop trigger if exists irrigation_sessions_zz_chain_reconcile on ops.irrigation_sessions;

create or replace function ops.reconcile_booking_chain_on_session_close()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $function$
begin
  return new;
end;
$function$;

revoke all on function ops.reconcile_booking_chain_on_session_close()
  from public, anon, authenticated, service_role;

-- 4. Retire the installed identities, not guessed overloads. The three public
-- production identities are explicitly required; all installed overloads of
-- every legacy executor below are blocked before any command/attempt write.
do $retire$
declare
  v_signature text;
  v_function record;
begin
  foreach v_signature in array array[
    'ops.execute_booking_transition(uuid,bigint,uuid)',
    'api.record_booking_transition_decision(uuid,uuid,uuid,text,bigint,uuid)',
    'api.execute_pending_booking_start(uuid,bigint,uuid)',
    'ops.execute_booking_transition_automation(uuid,uuid,uuid,uuid,bigint,bigint,bigint,uuid,uuid,uuid)',
    'ops.execute_pending_booking_start(uuid,bigint,uuid)',
    'ops.record_booking_transition_decision(uuid,uuid,uuid,text,bigint,uuid,uuid)'
  ] loop
    if pg_catalog.to_regprocedure(v_signature) is null then
      raise exception 'q137_missing_production_signature: %', v_signature;
    end if;
  end loop;

  for v_function in
    select p.oid, n.nspname, p.proname,
      pg_catalog.pg_get_function_arguments(p.oid) as arguments,
      pg_catalog.pg_get_function_identity_arguments(p.oid) as identity_arguments,
      p.prorettype
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where (n.nspname = 'ops' and p.proname in (
      'execute_booking_transition', 'execute_booking_transition_automation',
      'execute_pending_booking_start', 'record_booking_transition_decision'
    )) or (n.nspname = 'api' and p.proname in (
      'record_booking_transition_decision', 'execute_pending_booking_start'
    ))
  loop
    if v_function.prorettype <> 'pg_catalog.jsonb'::pg_catalog.regtype then
      raise exception 'q137_unexpected_executor_return_type: %.%',
        v_function.nspname, v_function.proname;
    end if;
    execute pg_catalog.format(
      'create or replace function %I.%I(%s) returns jsonb language plpgsql '
      'volatile security %s set search_path = pg_catalog, pg_temp as '
      '$disabled$ begin raise exception ''legacy_booking_automation_disabled'' '
      'using errcode = ''0A000''; end; $disabled$',
      v_function.nspname, v_function.proname, v_function.arguments,
      case when v_function.nspname = 'api' then 'invoker' else 'definer' end
    );
    execute pg_catalog.format('revoke all on function %I.%I(%s) from public, anon, authenticated, service_role',
      v_function.nspname, v_function.proname, v_function.identity_arguments);
    if v_function.nspname = 'api' then
      execute pg_catalog.format('grant execute on function %I.%I(%s) to authenticated, service_role',
        v_function.nspname, v_function.proname, v_function.identity_arguments);
    end if;
  end loop;
end;
$retire$;

-- Retired control contracts retain authorized, exact historical replay only.
-- No begin_command, locks, settings/chain mutation or financial execution.
create or replace function ops.set_well_booking_automation(
  p_well_id uuid, p_enabled boolean, p_expected_revision bigint,
  p_actor uuid, p_command_id uuid
) returns jsonb language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $replay$
declare
  v_tenant uuid;
  v_row sync.processed_commands%rowtype;
  v_payload jsonb;
begin
  if auth.uid() is null or p_actor is distinct from auth.uid()
    or not iam.has_well_permission(p_well_id,'session.start')
    or not exists(select 1 from core.well_assignments wa
      join iam.well_assignment_role_map arm on arm.assignment_role=wa.role
      join iam.roles r on r.id=arm.role_id
      where wa.well_id=p_well_id and wa.profile_id=auth.uid()
        and wa.status='active' and r.code='operator') then
    raise exception 'unauthorized' using errcode='42501';
  end if;
  select w.tenant_id into v_tenant from core.wells w where w.id=p_well_id;
  v_payload:=pg_catalog.jsonb_build_object('well_settings_contract_version',113,
    'well_id',p_well_id,'enabled',p_enabled,'expected_revision',p_expected_revision);
  select pc.* into v_row from sync.processed_commands pc
    where pc.tenant_id=v_tenant and pc.command_id=p_command_id;
  if found then
    if v_row.command_type is distinct from 'set_well_booking_automation'
      or v_row.entity_id is distinct from p_well_id
      or v_row.request_payload is distinct from v_payload then
      raise exception 'command_identity_mismatch' using errcode='22023';
    end if;
    if v_row.status='accepted' and v_row.response_payload is not null then
      return v_row.response_payload;
    end if;
  end if;
  raise exception 'legacy_booking_automation_disabled' using errcode='0A000';
end;
$replay$;
revoke all on function ops.set_well_booking_automation(uuid,boolean,bigint,uuid,uuid)
  from public,anon,authenticated,service_role,booking_automation_executor;
grant execute on function ops.set_well_booking_automation(uuid,boolean,bigint,uuid,uuid)
  to authenticated,service_role;

create or replace function ops.end_booking_transition_chain(
  p_session_id uuid, p_actor uuid, p_command_id uuid
) returns jsonb language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $replay$
declare
  v_tenant uuid;
  v_well uuid;
  v_row sync.processed_commands%rowtype;
begin
  if auth.uid() is null or p_actor is distinct from auth.uid() then
    raise exception 'unauthorized' using errcode='42501';
  end if;
  select w.tenant_id,s.well_id into v_tenant,v_well
    from ops.irrigation_sessions s join core.wells w on w.id=s.well_id
    join ops.farmer_well_accounts a on a.id=s.farmer_well_account_id
      and a.well_id=s.well_id and a.tenant_id=w.tenant_id
    where s.id=p_session_id;
  if v_tenant is null or not iam.has_well_permission(v_well,'session.complete')
    or not exists(select 1 from core.well_assignments wa
      where wa.well_id=v_well and wa.profile_id=auth.uid() and wa.status='active') then
    raise exception 'unauthorized' using errcode='42501';
  end if;
  select pc.* into v_row from sync.processed_commands pc
    where pc.tenant_id=v_tenant and pc.command_id=p_command_id;
  if found then
    if v_row.command_type is distinct from 'end_booking_transition_chain'
      or v_row.entity_id is distinct from p_session_id
      or v_row.request_payload is distinct from pg_catalog.jsonb_build_object('version',1,'session_id',p_session_id) then
      raise exception 'command_identity_mismatch' using errcode='22023';
    end if;
    if v_row.status in ('accepted','rejected','conflict') and v_row.response_payload is not null then
      return v_row.response_payload;
    end if;
  end if;
  raise exception 'legacy_booking_automation_disabled' using errcode='0A000';
end;
$replay$;
revoke all on function ops.end_booking_transition_chain(uuid,uuid,uuid)
  from public,anon,authenticated,service_role,booking_automation_executor;
-- Existing API INVOKER and narrow sync DEFINER wrappers/grants stay intact.

-- Scheduled/Edge callers of the P2 automation executor hit the same disabled
-- identity above. Read/reconciliation functions, accepted receipts, global
-- execution settings and cron history are intentionally untouched.
commit;
