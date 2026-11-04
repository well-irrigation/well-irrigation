-- إضافة مرجع الجلسة الكنوني فقط؛ لا تغيير في الإصدار أو الصلاحيات.
create or replace function api.get_well_booking_automation(
  p_well_id uuid
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_enabled boolean;
  v_revision bigint;
  v_updated_at timestamptz;
  v_row_exists boolean;
  v_chain ops.booking_transition_chains%rowtype;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة إعداد الانتقال الآلي';
  end if;
  -- حرس القراءة عبر المسار الكنوني: تعيين نشط للمستدعي على البئر
  --   يقابله في خريطة أدوار التعيين رمز الدور الكنوني tenant_owner
  --   (المالك) أو operator (المشغل) في iam.roles — نفس نافذة سياسة
  --   قراءة well_settings دون مصفوفات الأدوار النصية القديمة.
  if not exists (
    select 1
    from core.well_assignments wa
    join iam.well_assignment_role_map arm
      on arm.assignment_role = wa.role
    join iam.roles r
      on r.id = arm.role_id
    where wa.well_id = p_well_id
      and wa.profile_id = v_actor
      and wa.status = 'active'
      and r.code in ('tenant_owner', 'operator')
  ) then
    raise exception 'لا تملك صلاحية قراءة إعداد الانتقال الآلي على هذا البئر'
      using errcode = '42501';
  end if;

  select true,
         ws.booking_auto_transition_enabled,
         ws.booking_auto_transition_revision,
         ws.updated_at
    into v_row_exists, v_enabled, v_revision, v_updated_at
  from core.well_settings ws
  where ws.well_id = p_well_id;
  if not found then
    v_row_exists := false;
    v_enabled := false;
    v_revision := null;
  end if;

  select c.* into v_chain
  from ops.booking_transition_chains c
  where c.well_id = p_well_id
    and c.status <> 'ended'
  limit 1;

  return jsonb_build_object(
    'contract', 'get_well_booking_automation',
    'version', 1,
    'well_id', p_well_id,
    -- الإعداد المحفوظ ومراجعته: المراجعة وحدها تُرسل مع أمر التغيير.
    'booking_auto_transition_enabled', v_enabled,
    'booking_auto_transition_revision', v_revision,
    'settings_row_exists', v_row_exists,
    'settings_updated_at', v_updated_at,
    -- حالة التنفيذ الفعلية من سلسلة البئر (JSON null بلا أي سلسلة).
    'active_chain', case
      when v_chain.id is null then null
      else jsonb_build_object(
        'chain_id', v_chain.id,
        'status', v_chain.status,
        'current_session_id', v_chain.current_session_id,
        'next_booking_id', v_chain.next_booking_id,
        'decision_revision', v_chain.decision_revision
      )
    end,
    -- منفّذ الأتمتة غير جاهز حاليًا — ثابت false حتى تنفيذ منفّذ
    -- الانتقال في جولة لاحقة، مستقل كليًا عن كون الإعداد ON محفوظًا.
    'automation_executor_ready', false,
    -- بند 7 صراحةً: حفظ الإعداد بوضع التشغيل ليس نجاح تشغيل آلي.
    'auto_transition_executed', false,
    'first_session', 'manual'
  );
end;
$function$;
