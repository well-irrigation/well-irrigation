-- =====================================================================
-- Migration 084 — W2-01/2 — أغلفة api لا تُنفِّذ العملية مرتين
-- القرار: ق-114 (W2-01 Server-side idempotency)
-- المسألة: م-25 (تضيق ولا تُغلق)
--
-- الغرض:
--   إضافة `p_command_id` إلى أغلفة الدورة الميدانية الأولى الثمانية
--   حتى تُعيد إعادة المحاولة نفس النتيجة بدل تنفيذ العملية ثانية.
--
--   بلا هذا: يُنفِّذ الخادم العملية ثم يضيع الردّ في شبكة ضعيفة،
--   فيعيد الهاتف الإرسال، فتُسجَّل مرتين. الأثر الأخطر مالي —
--   دفعة 500 تصبح 1000.
--
-- النطاق:
--   الثماني في القسم 13 من SYNC_ARCHITECTURE حصرًا. الورديات ونقل
--   الجلسة والحجوزات (ق-98) والمصروفات والتوزيعات (ق-99) خارج
--   النطاق عمدًا: «الإداريات الأخرى تناقش كل شاشة على حدة ولا
--   تصبح Offline تلقائيًا من ق-89».
--
-- قواعد التصميم:
--   1) `p_command_id` آخر معامل و `default null`. عند null يسلك
--      الغلاف المسار القديم حرفيًا. كل عميل قائم لا يتأثر.
--   2) استبدال التوقيع لا إضافة overload: سطح api يبقى 33 دالة
--      بالضبط كما تؤكده خمسة اختبارات قائمة.
--   3) الأغلفة تبقى `security invoker` وفق ق-78/ق-79، ولا تكشف
--      هوية المنفِّذ: `auth.uid()` يبقى داخليًا.
--   4) لا تفويض جديد ولا تفويض مكرر. الصلاحية تبقى في الدوال
--      الداخلية عبر `iam.has_well_permission` (ق-113). الغلاف
--      يحجز معرّف العملية فقط، والدالة الداخلية هي من يقبل أو يرفض.
--   5) الدوال الداخلية في 081/082 لا تُمسّ.
--   6) لا تُسجَّل حالة رفض: استدعاء RPC واحد = transaction واحدة،
--      فرفض العملية يُرجِع صفّ الحجز معها. لا يبقى أثر، وإعادة
--      المحاولة تُنفَّذ من جديد بأمان. ولنفس السبب حالة `processing`
--      العالقة مستحيلة ولا تحتاج مُنظِّفًا دوريًا.
--   7) `drop` يُفقد المنح، فتُعاد صراحة لكل دالة.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- A) بدء جلسة سقي
--
-- معرَّفة ببئر لأن الجلسة لم تُخلق بعد.
-- ---------------------------------------------------------------------

drop function if exists api.start_irrigation_session(
  uuid, uuid, uuid, uuid, text, timestamptz, uuid
);

create function api.start_irrigation_session(
  p_well_id uuid,
  p_pump_id uuid,
  p_farm_id uuid,
  p_farmer_well_account_id uuid,
  p_energy_source text,
  p_started_at timestamptz default clock_timestamp(),
  p_fuel_owner_person_id uuid default null,
  p_command_id uuid default null
)
returns uuid
language plpgsql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_guard jsonb;
  v_session_id uuid;
begin
  if p_command_id is not null then
    v_guard := sync.begin_well_command(
      p_well_id,
      p_command_id,
      'start_irrigation_session',
      null
    );

    if coalesce((v_guard ->> 'duplicate')::boolean, false) then
      if v_guard ->> 'status' = 'accepted' then
        return (v_guard -> 'response' ->> 'id')::uuid;
      end if;
      raise exception 'العملية نفسها قيد المعالجة أو تحتاج مراجعة';
    end if;
  end if;

  v_session_id := ops.start_irrigation_session(
    p_well_id,
    p_pump_id,
    p_farm_id,
    p_farmer_well_account_id,
    auth.uid(),
    p_energy_source,
    p_started_at,
    p_fuel_owner_person_id
  );

  if p_command_id is not null then
    perform sync.finish_well_command(
      p_well_id,
      p_command_id,
      'accepted',
      jsonb_build_object('id', v_session_id)
    );
  end if;

  return v_session_id;
end;
$function$;

revoke all on function api.start_irrigation_session(
  uuid, uuid, uuid, uuid, text, timestamptz, uuid, uuid
) from public, anon, authenticated, service_role;

grant execute on function api.start_irrigation_session(
  uuid, uuid, uuid, uuid, text, timestamptz, uuid, uuid
) to authenticated, service_role;


-- ---------------------------------------------------------------------
-- B) إيقاف الجلسة مؤقتًا
-- ---------------------------------------------------------------------

drop function if exists api.pause_irrigation_session(
  uuid, text, timestamptz
);

create function api.pause_irrigation_session(
  p_session_id uuid,
  p_reason text,
  p_paused_at timestamptz default clock_timestamp(),
  p_command_id uuid default null
)
returns uuid
language plpgsql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_guard jsonb;
  v_result_id uuid;
begin
  if p_command_id is not null then
    v_guard := sync.begin_session_command(
      p_session_id,
      p_command_id,
      'pause_irrigation_session',
      null
    );

    if coalesce((v_guard ->> 'duplicate')::boolean, false) then
      if v_guard ->> 'status' = 'accepted' then
        return (v_guard -> 'response' ->> 'id')::uuid;
      end if;
      raise exception 'العملية نفسها قيد المعالجة أو تحتاج مراجعة';
    end if;
  end if;

  v_result_id := ops.pause_irrigation_session(
    p_session_id,
    p_reason,
    p_paused_at
  );

  if p_command_id is not null then
    perform sync.finish_session_command(
      p_session_id,
      p_command_id,
      'accepted',
      jsonb_build_object('id', v_result_id)
    );
  end if;

  return v_result_id;
end;
$function$;

revoke all on function api.pause_irrigation_session(
  uuid, text, timestamptz, uuid
) from public, anon, authenticated, service_role;

grant execute on function api.pause_irrigation_session(
  uuid, text, timestamptz, uuid
) to authenticated, service_role;


-- ---------------------------------------------------------------------
-- C) تغيير مصدر الطاقة أثناء الجلسة
-- ---------------------------------------------------------------------

drop function if exists api.change_session_energy_source(
  uuid, text, timestamptz, bigint, text, uuid
);

create function api.change_session_energy_source(
  p_session_id uuid,
  p_new_source text,
  p_changed_at timestamptz default clock_timestamp(),
  p_closed_fuel_quantity_ml bigint default null,
  p_closed_fuel_measurement_type text default null,
  p_new_fuel_owner_person_id uuid default null,
  p_command_id uuid default null
)
returns uuid
language plpgsql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_guard jsonb;
  v_result_id uuid;
begin
  if p_command_id is not null then
    v_guard := sync.begin_session_command(
      p_session_id,
      p_command_id,
      'change_session_energy_source',
      null
    );

    if coalesce((v_guard ->> 'duplicate')::boolean, false) then
      if v_guard ->> 'status' = 'accepted' then
        return (v_guard -> 'response' ->> 'id')::uuid;
      end if;
      raise exception 'العملية نفسها قيد المعالجة أو تحتاج مراجعة';
    end if;
  end if;

  v_result_id := ops.change_session_energy_source(
    p_session_id,
    p_new_source,
    p_changed_at,
    p_closed_fuel_quantity_ml,
    p_closed_fuel_measurement_type,
    p_new_fuel_owner_person_id
  );

  if p_command_id is not null then
    perform sync.finish_session_command(
      p_session_id,
      p_command_id,
      'accepted',
      jsonb_build_object('id', v_result_id)
    );
  end if;

  return v_result_id;
end;
$function$;

revoke all on function api.change_session_energy_source(
  uuid, text, timestamptz, bigint, text, uuid, uuid
) from public, anon, authenticated, service_role;

grant execute on function api.change_session_energy_source(
  uuid, text, timestamptz, bigint, text, uuid, uuid
) to authenticated, service_role;


-- ---------------------------------------------------------------------
-- D) استئناف الجلسة
-- ---------------------------------------------------------------------

drop function if exists api.resume_irrigation_session(
  uuid, timestamptz
);

create function api.resume_irrigation_session(
  p_session_id uuid,
  p_resumed_at timestamptz default clock_timestamp(),
  p_command_id uuid default null
)
returns uuid
language plpgsql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_guard jsonb;
  v_result_id uuid;
begin
  if p_command_id is not null then
    v_guard := sync.begin_session_command(
      p_session_id,
      p_command_id,
      'resume_irrigation_session',
      null
    );

    if coalesce((v_guard ->> 'duplicate')::boolean, false) then
      if v_guard ->> 'status' = 'accepted' then
        return (v_guard -> 'response' ->> 'id')::uuid;
      end if;
      raise exception 'العملية نفسها قيد المعالجة أو تحتاج مراجعة';
    end if;
  end if;

  v_result_id := ops.resume_irrigation_session(
    p_session_id,
    p_resumed_at
  );

  if p_command_id is not null then
    perform sync.finish_session_command(
      p_session_id,
      p_command_id,
      'accepted',
      jsonb_build_object('id', v_result_id)
    );
  end if;

  return v_result_id;
end;
$function$;

revoke all on function api.resume_irrigation_session(
  uuid, timestamptz, uuid
) from public, anon, authenticated, service_role;

grant execute on function api.resume_irrigation_session(
  uuid, timestamptz, uuid
) to authenticated, service_role;


-- ---------------------------------------------------------------------
-- E) إنهاء الجلسة
--
-- ترجع jsonb، فتُخزَّن النتيجة كما هي وتُعاد كما هي.
-- ---------------------------------------------------------------------

drop function if exists api.complete_irrigation_session(
  uuid, timestamptz, bigint, text, uuid
);

create function api.complete_irrigation_session(
  p_session_id uuid,
  p_ended_at timestamptz default clock_timestamp(),
  p_fuel_quantity_ml bigint default null,
  p_fuel_measurement_type text default null,
  p_fuel_tank_id uuid default null,
  p_command_id uuid default null
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_guard jsonb;
  v_result jsonb;
begin
  if p_command_id is not null then
    v_guard := sync.begin_session_command(
      p_session_id,
      p_command_id,
      'complete_irrigation_session',
      null
    );

    if coalesce((v_guard ->> 'duplicate')::boolean, false) then
      if v_guard ->> 'status' = 'accepted' then
        return v_guard -> 'response';
      end if;
      raise exception 'العملية نفسها قيد المعالجة أو تحتاج مراجعة';
    end if;
  end if;

  v_result := ops.complete_irrigation_session(
    p_session_id,
    p_ended_at,
    p_fuel_quantity_ml,
    p_fuel_measurement_type,
    p_fuel_tank_id
  );

  if p_command_id is not null then
    perform sync.finish_session_command(
      p_session_id,
      p_command_id,
      'accepted',
      v_result
    );
  end if;

  return v_result;
end;
$function$;

revoke all on function api.complete_irrigation_session(
  uuid, timestamptz, bigint, text, uuid, uuid
) from public, anon, authenticated, service_role;

grant execute on function api.complete_irrigation_session(
  uuid, timestamptz, bigint, text, uuid, uuid
) to authenticated, service_role;


-- ---------------------------------------------------------------------
-- F) تسجيل دفعة
--
-- أخطر عملية في هذه الدفعة: تكرارها يعني مالًا مضاعفًا في الحساب.
-- ---------------------------------------------------------------------

drop function if exists api.record_payment(
  uuid, uuid, bigint, text, jsonb, uuid, uuid, uuid, timestamptz, text, text
);

create function api.record_payment(
  p_well_id uuid,
  p_farmer_well_account_id uuid,
  p_amount_minor bigint,
  p_method text,
  p_allocations jsonb default '[]'::jsonb,
  p_session_charge_id uuid default null,
  p_payer_person_id uuid default null,
  p_cashbox_id uuid default null,
  p_paid_at timestamptz default clock_timestamp(),
  p_note text default null,
  p_attachment_url text default null,
  p_command_id uuid default null
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_guard jsonb;
  v_result jsonb;
begin
  if p_command_id is not null then
    v_guard := sync.begin_well_command(
      p_well_id,
      p_command_id,
      'record_payment',
      null
    );

    if coalesce((v_guard ->> 'duplicate')::boolean, false) then
      if v_guard ->> 'status' = 'accepted' then
        return v_guard -> 'response';
      end if;
      raise exception 'العملية نفسها قيد المعالجة أو تحتاج مراجعة';
    end if;
  end if;

  v_result := billing.record_payment(
    p_well_id,
    p_farmer_well_account_id,
    p_amount_minor,
    p_method,
    p_allocations,
    p_session_charge_id,
    p_payer_person_id,
    p_cashbox_id,
    p_paid_at,
    p_note,
    p_attachment_url
  );

  if p_command_id is not null then
    perform sync.finish_well_command(
      p_well_id,
      p_command_id,
      'accepted',
      v_result
    );
  end if;

  return v_result;
end;
$function$;

revoke all on function api.record_payment(
  uuid, uuid, bigint, text, jsonb, uuid, uuid, uuid,
  timestamptz, text, text, uuid
) from public, anon, authenticated, service_role;

grant execute on function api.record_payment(
  uuid, uuid, bigint, text, jsonb, uuid, uuid, uuid,
  timestamptz, text, text, uuid
) to authenticated, service_role;


-- ---------------------------------------------------------------------
-- G) إنشاء مزارع
--
-- يُنشأ inline أثناء بدء جلسة عندما لا يكون المزارع مسجَّلًا.
-- تكراره يعني مزارعًا مزدوجًا وحسابين منفصلين لنفس الشخص.
-- ---------------------------------------------------------------------

drop function if exists api.create_farmer(
  uuid, text, text, text, text, bigint
);

create function api.create_farmer(
  p_well_id uuid,
  p_full_name text,
  p_phone text default null,
  p_preferred_name text default null,
  p_notes text default null,
  p_credit_limit_minor bigint default null,
  p_command_id uuid default null
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_guard jsonb;
  v_result jsonb;
begin
  if p_command_id is not null then
    v_guard := sync.begin_well_command(
      p_well_id,
      p_command_id,
      'create_farmer',
      null
    );

    if coalesce((v_guard ->> 'duplicate')::boolean, false) then
      if v_guard ->> 'status' = 'accepted' then
        return v_guard -> 'response';
      end if;
      raise exception 'العملية نفسها قيد المعالجة أو تحتاج مراجعة';
    end if;
  end if;

  v_result := ops.create_farmer(
    p_well_id,
    p_full_name,
    p_phone,
    p_preferred_name,
    p_notes,
    p_credit_limit_minor
  );

  if p_command_id is not null then
    perform sync.finish_well_command(
      p_well_id,
      p_command_id,
      'accepted',
      v_result
    );
  end if;

  return v_result;
end;
$function$;

revoke all on function api.create_farmer(
  uuid, text, text, text, text, bigint, uuid
) from public, anon, authenticated, service_role;

grant execute on function api.create_farmer(
  uuid, text, text, text, text, bigint, uuid
) to authenticated, service_role;


-- ---------------------------------------------------------------------
-- H) إنشاء أرض
--
-- التعريف الحيّ من 075 (ق-80) لا من 073.
-- ---------------------------------------------------------------------

drop function if exists api.create_farm(
  uuid, text, uuid
);

create function api.create_farm(
  p_well_id uuid,
  p_name text,
  p_farmer_well_account_id uuid,
  p_command_id uuid default null
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_guard jsonb;
  v_result jsonb;
begin
  if p_command_id is not null then
    v_guard := sync.begin_well_command(
      p_well_id,
      p_command_id,
      'create_farm',
      null
    );

    if coalesce((v_guard ->> 'duplicate')::boolean, false) then
      if v_guard ->> 'status' = 'accepted' then
        return v_guard -> 'response';
      end if;
      raise exception 'العملية نفسها قيد المعالجة أو تحتاج مراجعة';
    end if;
  end if;

  v_result := ops.create_farm(
    p_well_id,
    p_name,
    p_farmer_well_account_id
  );

  if p_command_id is not null then
    perform sync.finish_well_command(
      p_well_id,
      p_command_id,
      'accepted',
      v_result
    );
  end if;

  return v_result;
end;
$function$;

revoke all on function api.create_farm(
  uuid, text, uuid, uuid
) from public, anon, authenticated, service_role;

grant execute on function api.create_farm(
  uuid, text, uuid, uuid
) to authenticated, service_role;

commit;
