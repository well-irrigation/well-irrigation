begin;

-- ق-137 / 3C-0: هجرة تقنية مستقلة، لا تستهلك الرقم الوظيفي M114.
-- لا تغيير للجداول أو RLS أو العقود الكاتبة. النتيجة قراءة وليست تصريح إعادة إرسال.
create function sync.get_completion_receipt_read(
  p_well_id uuid,
  p_session_id uuid,
  p_command_id uuid,
  p_expected_command_type text default 'complete_irrigation_session'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_tenant uuid;
  v_session ops.irrigation_sessions%rowtype;
  v_command sync.processed_commands%rowtype;
  v_receipt jsonb;
  v_request jsonb;
  v_result jsonb;
  v_ended timestamptz;
  v_actual bigint;
  v_billable bigint;
  v_amount bigint;
  v_rate bigint;
  v_charge uuid;
  v_key text;
begin
  if v_actor is null then
    raise exception 'completion_receipt_requires_authentication' using errcode = '28000';
  end if;
  if p_well_id is null or p_session_id is null or p_command_id is null
     or p_expected_command_type is null
     or p_expected_command_type not in ('complete_irrigation_session', 'complete_booking_session') then
    raise exception 'completion_receipt_invalid_inputs' using errcode = '22023';
  end if;

  -- نفس صلاحية الإكمال القائمة: تعيين نشط ← دور كنوني ← صلاحية خادمية.
  -- لا actor/tenant من العميل، ولا ثقة بـ user_metadata، ولا قراءة للإقرارات قبله.
  if not exists (
    select 1 from core.well_assignments wa
    where wa.well_id = p_well_id and wa.profile_id = v_actor
      and wa.status = 'active'
  ) or not iam.has_well_permission(p_well_id, 'session.complete') then
    raise exception 'completion_receipt_forbidden' using errcode = '42501';
  end if;
  select s.* into v_session
  from ops.irrigation_sessions s
  join core.wells w on w.id = s.well_id
  where s.id = p_session_id and s.well_id = p_well_id
    and (s.farmer_well_account_id is null or exists (
      select 1 from ops.farmer_well_accounts a
      where a.id = s.farmer_well_account_id
        and a.well_id = w.id and a.tenant_id = w.tenant_id
    ));
  if not found then
    -- الجلسة التاريخية الغائبة لا تُستنتج من الإقرار ولا تمنح وصولًا إليه.
    -- رسالة واحدة للغياب وعدم تطابق النطاق، مستقلة عن وجود الأمر.
    raise exception 'completion_receipt_forbidden' using errcode = '42501';
  end if;
  select w.tenant_id into v_tenant from core.wells w where w.id = v_session.well_id;

  v_result := pg_catalog.jsonb_build_object(
    'contract', 'get_completion_receipt', 'version', 1,
    'well_id', p_well_id, 'session_id', p_session_id,
    'command_id', p_command_id, 'command_type', p_expected_command_type,
    'status', 'unresolved', 'receipt', null, 'retry_authorized', false
  );
  -- هذه القراءة وحدها تحتاج صلاحيات مالك الدالة: RLS على الجدول لا يشمل
  -- المشغل. التعيين والصلاحية ونطاق الجلسة تحققت قبل الوصول إليه؛ لا SELECT جديد.
  -- مفتاح الحساب المستقل مأخوذ من علاقة الجلسة بالبئر، لا من claims العميل.
  select c.* into v_command from sync.processed_commands c
  where c.tenant_id = v_tenant and c.command_id = p_command_id;
  if not found then
    return v_result || pg_catalog.jsonb_build_object('status', 'not_found',
      'reason', 'receipt_absent_execution_not_disproved');
  end if;
  if v_command.entity_id is distinct from p_session_id
     or v_command.command_type is distinct from p_expected_command_type then
    return v_result || pg_catalog.jsonb_build_object('reason', 'command_identity_mismatch');
  end if;

  v_request := v_command.request_payload;
  -- العقد العادي المختوم يمرر SQL NULL فعليًا. لا نخترع بصمة طلب له.
  -- أي هوية مخزنة موجودة بالفعل يجب ألا تناقض النطاق المطلوب.
  if v_request is not null then
    if pg_catalog.jsonb_typeof(v_request) is distinct from 'object' then
      return v_result || pg_catalog.jsonb_build_object('reason', 'request_inconsistent');
    end if;
    if (v_request ? 'session_id' and v_request->>'session_id' is distinct from p_session_id::text)
       or (v_request ? 'well_id' and v_request->>'well_id' is distinct from p_well_id::text)
       or (v_request ? 'tenant_id' and v_request->>'tenant_id' is distinct from v_tenant::text) then
      return v_result || pg_catalog.jsonb_build_object('reason', 'request_inconsistent');
    end if;
  end if;
  if p_expected_command_type = 'complete_booking_session' and (
    v_request is null
    or v_request->'booking_execution_contract_version' is distinct from '113'::jsonb
    or v_request->>'session_id' is distinct from p_session_id::text
    or pg_catalog.jsonb_typeof(v_request->'ended_at') is distinct from 'string'
  ) then
    return v_result || pg_catalog.jsonb_build_object('reason', 'booking_request_unproven');
  end if;

  if v_command.status = 'processing' and v_command.response_payload is null then
    return v_result || pg_catalog.jsonb_build_object('status', 'processing', 'reason', 'result_pending');
  end if;
  if v_command.status <> 'accepted' then
    return v_result || pg_catalog.jsonb_build_object('reason', 'non_final_or_conflicting_result');
  end if;

  v_receipt := v_command.response_payload;
  if pg_catalog.jsonb_typeof(v_receipt) is distinct from 'object'
     or v_receipt->>'status' is distinct from 'closed'
     or pg_catalog.jsonb_typeof(v_receipt->'ended_at') is distinct from 'string'
     or pg_catalog.jsonb_typeof(v_receipt->'session_charge_id') is distinct from 'string'
     or pg_catalog.jsonb_typeof(v_receipt->'session_id') is distinct from 'string'
     or v_receipt->>'session_id' is distinct from p_session_id::text
     or (v_receipt ? 'well_id' and v_receipt->>'well_id' is distinct from p_well_id::text)
     or (v_receipt ? 'tenant_id' and v_receipt->>'tenant_id' is distinct from v_tenant::text)
     or (v_receipt ? 'command_id' and v_receipt->>'command_id' is distinct from p_command_id::text)
     or (v_receipt ? 'command_type' and v_receipt->>'command_type' is distinct from p_expected_command_type)
     or pg_catalog.jsonb_typeof(v_receipt->'segments') is distinct from 'array' then
    return v_result || pg_catalog.jsonb_build_object('reason', 'receipt_incomplete_or_inconsistent');
  end if;
  foreach v_key in array array['actual_seconds', 'billable_seconds',
    'weighted_price_per_hour_minor', 'amount_minor'] loop
    if pg_catalog.jsonb_typeof(v_receipt->v_key) is distinct from 'number'
       or (v_receipt->>v_key) !~ '^[0-9]+$' then
      return v_result || pg_catalog.jsonb_build_object('reason', 'receipt_incomplete_or_inconsistent');
    end if;
  end loop;
  begin
    -- تحقق من الشكل والمدى فقط، دون أي إعادة حساب مالي أو زمني.
    if v_receipt->>'ended_at' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$' then
      return v_result || pg_catalog.jsonb_build_object('reason', 'receipt_incomplete_or_inconsistent');
    end if;
    v_ended := (v_receipt->>'ended_at')::timestamptz;
    v_actual := (v_receipt->>'actual_seconds')::bigint;
    v_billable := (v_receipt->>'billable_seconds')::bigint;
    v_amount := (v_receipt->>'amount_minor')::bigint;
    v_rate := (v_receipt->>'weighted_price_per_hour_minor')::bigint;
    v_charge := (v_receipt->>'session_charge_id')::uuid;
    if not pg_catalog.isfinite(v_ended) or v_charge is null or v_billable > v_actual
       or v_session.status not in ('closed', 'forgotten')
       or v_session.ended_at is distinct from v_ended
       or (p_expected_command_type = 'complete_booking_session'
         and (v_request->>'ended_at')::timestamptz is distinct from v_ended) then
      return v_result || pg_catalog.jsonb_build_object('reason', 'receipt_incomplete_or_inconsistent');
    end if;
  exception when invalid_text_representation or invalid_datetime_format
    or datetime_field_overflow or numeric_value_out_of_range then
    return v_result || pg_catalog.jsonb_build_object('reason', 'receipt_incomplete_or_inconsistent');
  end;

  -- response_payload كامل كما خُزّن؛ لا إعادة تركيب للتكلفة أو الديزل أو المقاطع.
  return v_result || pg_catalog.jsonb_build_object('status', 'accepted', 'receipt', v_receipt,
    'reason', 'exact_stored_receipt');
end;
$function$;

revoke all on function sync.get_completion_receipt_read(uuid, uuid, uuid, text)
  from public, anon, authenticated, service_role;
grant execute on function sync.get_completion_receipt_read(uuid, uuid, uuid, text)
  to authenticated, service_role;

-- سطح api يبقى SECURITY INVOKER، والقارئ الداخلي يعيد كامل التحقق حتى عند استدعائه مباشرة.
create function api.get_completion_receipt(
  p_well_id uuid,
  p_session_id uuid,
  p_command_id uuid,
  p_expected_command_type text default 'complete_irrigation_session'
)
returns jsonb
language sql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
  select sync.get_completion_receipt_read(
    p_well_id, p_session_id, p_command_id, p_expected_command_type
  );
$function$;
revoke all on function api.get_completion_receipt(uuid, uuid, uuid, text)
  from public, anon, authenticated, service_role;
grant execute on function api.get_completion_receipt(uuid, uuid, uuid, text)
  to authenticated, service_role;

comment on function api.get_completion_receipt(uuid, uuid, uuid, text) is
  'ق-137: قراءة الإقرار الأصلي فقط؛ not_found لا يثبت عدم التنفيذ وretry_authorized دائمًا false. لا إصلاح مالي أو إعادة إرسال.';
commit;
