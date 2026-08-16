-- =====================================================================
-- 073 — ق-79: عقد الكتابة الرسمي لتطبيق Flutter داخل api
--
-- المبادئ:
-- 1) api يحتوي أغلفة رقيقة فقط ولا يكرر منطق الأعمال.
-- 2) الأغلفة SECURITY INVOKER.
-- 3) الإجراءات الداخلية المعتمدة تبقى مصدر منطق الأعمال.
-- 4) هوية المنفذ تؤخذ من auth.uid() عندما يكون الإجراء الداخلي
--    يطلب معرف المنفذ، ولا نسمح للعميل بإرسال هويته بنفسه.
-- 5) create_farm غير مكشوف حاليًا بسبب م-22.
-- =====================================================================


-- ---------------------------------------------------------------------
-- دورة جلسة السقي
-- ---------------------------------------------------------------------

create function api.start_irrigation_session(
  p_well_id uuid,
  p_pump_id uuid,
  p_farm_id uuid,
  p_farmer_well_account_id uuid,
  p_energy_source text,
  p_started_at timestamptz default clock_timestamp(),
  p_fuel_owner_person_id uuid default null
)
returns uuid
language sql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
  select ops.start_irrigation_session(
    p_well_id,
    p_pump_id,
    p_farm_id,
    p_farmer_well_account_id,
    auth.uid(),
    p_energy_source,
    p_started_at,
    p_fuel_owner_person_id
  );
$function$;


create function api.pause_irrigation_session(
  p_session_id uuid,
  p_reason text,
  p_paused_at timestamptz default clock_timestamp()
)
returns uuid
language sql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
  select ops.pause_irrigation_session(
    p_session_id,
    p_reason,
    p_paused_at
  );
$function$;


create function api.change_session_energy_source(
  p_session_id uuid,
  p_new_source text,
  p_changed_at timestamptz default clock_timestamp(),
  p_closed_fuel_quantity_ml bigint default null,
  p_closed_fuel_measurement_type text default null,
  p_new_fuel_owner_person_id uuid default null
)
returns uuid
language sql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
  select ops.change_session_energy_source(
    p_session_id,
    p_new_source,
    p_changed_at,
    p_closed_fuel_quantity_ml,
    p_closed_fuel_measurement_type,
    p_new_fuel_owner_person_id
  );
$function$;


create function api.resume_irrigation_session(
  p_session_id uuid,
  p_resumed_at timestamptz default clock_timestamp()
)
returns uuid
language sql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
  select ops.resume_irrigation_session(
    p_session_id,
    p_resumed_at
  );
$function$;


create function api.complete_irrigation_session(
  p_session_id uuid,
  p_ended_at timestamptz default clock_timestamp(),
  p_fuel_quantity_ml bigint default null,
  p_fuel_measurement_type text default null,
  p_fuel_tank_id uuid default null
)
returns jsonb
language sql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
  select ops.complete_irrigation_session(
    p_session_id,
    p_ended_at,
    p_fuel_quantity_ml,
    p_fuel_measurement_type,
    p_fuel_tank_id
  );
$function$;


-- ---------------------------------------------------------------------
-- الفوترة والتحصيل
-- ---------------------------------------------------------------------

create function api.issue_session_invoice(
  p_session_id uuid
)
returns uuid
language sql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
  select billing.issue_session_invoice(
    p_session_id,
    auth.uid()
  );
$function$;


create function api.allocate_payment(
  p_payment_id uuid,
  p_allocations jsonb
)
returns jsonb
language sql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
  select billing.allocate_payment(
    p_payment_id,
    p_allocations
  );
$function$;


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
  p_attachment_url text default null
)
returns jsonb
language sql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
  select billing.record_payment(
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
$function$;


create function api.pay_partner_distribution(
  p_distribution_line_id uuid,
  p_amount_minor bigint,
  p_paid_at timestamptz default clock_timestamp()
)
returns jsonb
language sql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
  select finance.pay_partner_distribution(
    p_distribution_line_id,
    p_amount_minor,
    auth.uid(),
    p_paid_at
  );
$function$;


-- ---------------------------------------------------------------------
-- المزارعون والحجوزات
-- ---------------------------------------------------------------------

create function api.create_farmer(
  p_well_id uuid,
  p_full_name text,
  p_phone text default null,
  p_preferred_name text default null,
  p_notes text default null,
  p_credit_limit_minor bigint default null
)
returns jsonb
language sql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
  select ops.create_farmer(
    p_well_id,
    p_full_name,
    p_phone,
    p_preferred_name,
    p_notes,
    p_credit_limit_minor
  );
$function$;


create function api.create_booking(
  p_well_id uuid,
  p_farmer_well_account_id uuid,
  p_farm_id uuid,
  p_scheduled_start timestamptz,
  p_scheduled_end timestamptz,
  p_pump_id uuid default null,
  p_water_line_id uuid default null,
  p_expected_energy_source text default null,
  p_priority integer default 0,
  p_notes text default null
)
returns jsonb
language sql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
  select ops.create_booking(
    p_well_id,
    p_farmer_well_account_id,
    p_farm_id,
    p_scheduled_start,
    p_scheduled_end,
    p_pump_id,
    p_water_line_id,
    p_expected_energy_source,
    p_priority,
    p_notes
  );
$function$;


create function api.reschedule_booking(
  p_booking_id uuid,
  p_scheduled_start timestamptz,
  p_scheduled_end timestamptz,
  p_reason text
)
returns jsonb
language sql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
  select ops.reschedule_booking(
    p_booking_id,
    p_scheduled_start,
    p_scheduled_end,
    p_reason
  );
$function$;


-- ---------------------------------------------------------------------
-- الوقود
-- ---------------------------------------------------------------------

create function api.purchase_fuel(
  p_well_id uuid,
  p_liters numeric,
  p_cost_minor bigint,
  p_purchased_at timestamptz default clock_timestamp()
)
returns jsonb
language sql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
  select inventory.purchase_fuel(
    p_well_id,
    p_liters,
    p_cost_minor,
    p_purchased_at,
    auth.uid()
  );
$function$;


create function api.record_fuel_consumption(
  p_well_id uuid,
  p_quantity_ml bigint,
  p_ownership_type text,
  p_measurement_type text,
  p_owner_person_id uuid default null,
  p_farmer_well_account_id uuid default null,
  p_fuel_tank_id uuid default null,
  p_session_segment_id uuid default null,
  p_occurred_at timestamptz default clock_timestamp(),
  p_estimated_transaction_id uuid default null
)
returns jsonb
language sql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
  select inventory.record_fuel_consumption(
    p_well_id,
    p_quantity_ml,
    p_ownership_type,
    p_measurement_type,
    p_owner_person_id,
    p_farmer_well_account_id,
    p_fuel_tank_id,
    p_session_segment_id,
    p_occurred_at,
    auth.uid(),
    p_estimated_transaction_id
  );
$function$;


create function api.record_physical_fuel_count(
  p_well_id uuid,
  p_fuel_tank_id uuid,
  p_measured_balance_ml bigint,
  p_counted_at timestamptz default clock_timestamp(),
  p_notes text default null
)
returns jsonb
language sql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
  select inventory.record_physical_fuel_count(
    p_well_id,
    p_fuel_tank_id,
    p_measured_balance_ml,
    p_counted_at,
    auth.uid(),
    p_notes
  );
$function$;


-- ---------------------------------------------------------------------
-- المنح: كل دالة داخل api Opt-in صريحة.
-- ---------------------------------------------------------------------

revoke all on all functions in schema api
from public, anon, authenticated, service_role;

grant execute on function api.health()
to authenticated, service_role;

grant execute on function api.start_irrigation_session(
  uuid, uuid, uuid, uuid, text, timestamptz, uuid
) to authenticated, service_role;

grant execute on function api.pause_irrigation_session(
  uuid, text, timestamptz
) to authenticated, service_role;

grant execute on function api.change_session_energy_source(
  uuid, text, timestamptz, bigint, text, uuid
) to authenticated, service_role;

grant execute on function api.resume_irrigation_session(
  uuid, timestamptz
) to authenticated, service_role;

grant execute on function api.complete_irrigation_session(
  uuid, timestamptz, bigint, text, uuid
) to authenticated, service_role;

grant execute on function api.issue_session_invoice(
  uuid
) to authenticated, service_role;

grant execute on function api.allocate_payment(
  uuid, jsonb
) to authenticated, service_role;

grant execute on function api.record_payment(
  uuid, uuid, bigint, text, jsonb, uuid, uuid, uuid,
  timestamptz, text, text
) to authenticated, service_role;

grant execute on function api.pay_partner_distribution(
  uuid, bigint, timestamptz
) to authenticated, service_role;

grant execute on function api.create_farmer(
  uuid, text, text, text, text, bigint
) to authenticated, service_role;

grant execute on function api.create_booking(
  uuid, uuid, uuid, timestamptz, timestamptz,
  uuid, uuid, text, integer, text
) to authenticated, service_role;

grant execute on function api.reschedule_booking(
  uuid, timestamptz, timestamptz, text
) to authenticated, service_role;

grant execute on function api.purchase_fuel(
  uuid, numeric, bigint, timestamptz
) to authenticated, service_role;

grant execute on function api.record_fuel_consumption(
  uuid, bigint, text, text, uuid, uuid, uuid, uuid,
  timestamptz, uuid
) to authenticated, service_role;

grant execute on function api.record_physical_fuel_count(
  uuid, uuid, bigint, timestamptz, text
) to authenticated, service_role;
