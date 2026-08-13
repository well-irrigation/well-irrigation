-- المرحلة 4 (الديزل والمصروفات) - الملف 040
-- توسيع انواع الاشعارات المسموحة واضافة دالة مساعدة لتنبيه ملاك البئر
-- المرجع: قرار المالك (اشعار لحظي عند كل مصروف وعند التسليم والفروقات) - ق-72

alter table ops.notifications drop constraint if exists notifications_type_check;

alter table ops.notifications add constraint notifications_type_check check (type = any (array[
  'long_session',
  'approaching_long_session',
  'distribution_finalized',
  'expense_recorded',
  'handover_declared',
  'handover_confirmed',
  'handover_difference',
  'handover_settled',
  'shift_opened',
  'shift_closed',
  'shift_open_too_long',
  'shift_blocked',
  'session_transfer_requested',
  'session_transfer_accepted',
  'session_transfer_rejected'
]));

-- تنبيه كل من يملك حصة فعالة في البئر
create or replace function ops.notify_well_owners(
  p_well_id uuid,
  p_type text,
  p_message text,
  p_session_id uuid default null
) returns integer
language plpgsql
security definer
set search_path to 'ops', 'core', 'pg_temp'
as $$
declare
  v_count integer := 0;
begin
  insert into ops.notifications (recipient_profile_id, well_id, session_id, type, message)
  select distinct s.profile_id, p_well_id, p_session_id, p_type, p_message
  from core.well_ownership_shares s
  where s.well_id = p_well_id
    and (s.period_start is null or s.period_start <= current_date)
    and (s.period_end is null or s.period_end >= current_date);

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- تنبيه شخص محدد (مشغل او مالك)
create or replace function ops.notify_profile(
  p_profile_id uuid,
  p_well_id uuid,
  p_type text,
  p_message text,
  p_session_id uuid default null
) returns uuid
language plpgsql
security definer
set search_path to 'ops', 'pg_temp'
as $$
declare
  v_id uuid;
begin
  insert into ops.notifications (recipient_profile_id, well_id, session_id, type, message)
  values (p_profile_id, p_well_id, p_session_id, p_type, p_message)
  returning id into v_id;
  return v_id;
end;
$$;
