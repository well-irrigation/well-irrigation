-- 070: مرسلا الملخص اليومي وتجاوز حد الدين (م-08: بناء المنطق فقط)

-- النوعان غير موجودين في قائمة التنبيهات السابقة، لذلك يضافان مع إبقاء الأنواع القائمة.
alter table ops.notifications drop constraint if exists notifications_type_check;
alter table ops.notifications add constraint notifications_type_check
  check (type in (
    'long_session', 'approaching_long_session', 'distribution_finalized', 'expense_recorded',
    'handover_declared', 'handover_confirmed', 'handover_difference', 'handover_settled',
    'shift_opened', 'shift_closed', 'shift_open_too_long', 'shift_blocked',
    'session_transfer_requested', 'session_transfer_accepted', 'session_transfer_rejected',
    'period_reopen_requested', 'period_reopen_ready', 'period_reopen_approved', 'period_reopen_rejected',
    'distribution_approved', 'daily_summary', 'debt_threshold_exceeded'
  ));

-- مفتاح داخلي اختياري يجعل منع التكرار ذريًا حتى عند تزامن استدعاءين.
alter table ops.notifications add column deduplication_key text;

create unique index notifications_recipient_type_dedup_unique
  on ops.notifications (recipient_profile_id, type, deduplication_key)
  where deduplication_key is not null;

drop function if exists ops.send_daily_summaries(date);

create function ops.send_daily_summaries(
  p_day date default (current_date - 1)
)
returns jsonb
language plpgsql
security definer
set search_path = 'ops', 'reporting', 'core', 'iam', 'auth', 'pg_temp'
as $function$
declare
  v_actor_id uuid := auth.uid();
  v_summary record;
  v_duration_seconds bigint;
  v_inserted integer;
  v_wells_processed integer := 0;
  v_notifications_created integer := 0;
begin
  if p_day is null then
    raise exception 'يجب تحديد يوم الملخص';
  end if;

  for v_summary in
    select
      s.well_id,
      s.sessions_count,
      s.open_sessions,
      s.solar_seconds,
      s.diesel_seconds,
      s.collected_minor,
      s.expenses_minor
    from reporting.well_daily_summary s
    join core.wells w on w.id = s.well_id
    where s.day = p_day
      and w.status = 'active'
      and (
        s.sessions_count <> 0
        or s.open_sessions <> 0
        or s.solar_seconds <> 0
        or s.diesel_seconds <> 0
        or s.charges_minor <> 0
        or s.collected_minor <> 0
        or s.expenses_minor <> 0
        or s.fuel_out_ml <> 0
      )
      and (
        v_actor_id is null
        or exists (
          select 1
          from core.well_assignments mine
          where mine.well_id = s.well_id
            and mine.profile_id = v_actor_id
            and mine.status = 'active'
            and mine.role in ('owner', 'manager')
        )
      )
    order by s.well_id
  loop
    v_wells_processed := v_wells_processed + 1;
    v_duration_seconds := coalesce(v_summary.solar_seconds, 0)
                        + coalesce(v_summary.diesel_seconds, 0);

    insert into ops.notifications (
      recipient_profile_id, well_id, type, message, deduplication_key
    )
    select distinct
      wa.profile_id,
      v_summary.well_id,
      'daily_summary',
      format(
        'ملخص يوم %s: %s جلسة، المدة %s ساعة و%s دقيقة و%s ثانية، المحصل %s، المصروف %s',
        p_day,
        v_summary.sessions_count,
        v_duration_seconds / 3600,
        (v_duration_seconds % 3600) / 60,
        v_duration_seconds % 60,
        v_summary.collected_minor,
        v_summary.expenses_minor
      ),
      format('daily:%s:%s', v_summary.well_id, p_day)
    from core.well_assignments wa
    where wa.well_id = v_summary.well_id
      and wa.status = 'active'
      and wa.role in ('owner', 'manager')
    on conflict (recipient_profile_id, type, deduplication_key)
      where deduplication_key is not null
      do nothing;

    get diagnostics v_inserted = row_count;
    v_notifications_created := v_notifications_created + v_inserted;
  end loop;

  return jsonb_build_object(
    'day', p_day,
    'wells_processed', v_wells_processed,
    'notifications_created', v_notifications_created
  );
end;
$function$;

revoke all on function ops.send_daily_summaries(date) from public;
revoke all on function ops.send_daily_summaries(date) from anon;
grant execute on function ops.send_daily_summaries(date) to authenticated;

drop function if exists ops.check_debt_thresholds();

create function ops.check_debt_thresholds()
returns jsonb
language plpgsql
security definer
set search_path = 'ops', 'reporting', 'billing', 'core', 'iam', 'auth', 'pg_temp'
as $function$
declare
  v_actor_id uuid := auth.uid();
  v_account record;
  v_outstanding_minor bigint;
  v_inserted integer;
  v_accounts_checked integer := 0;
  v_accounts_over_limit integer := 0;
  v_notifications_created integer := 0;
begin
  for v_account in
    select
      a.id as account_id,
      a.well_id,
      a.credit_limit_minor,
      p.full_name as farmer_name,
      coalesce(b.debt_minor, 0) as debt_minor,
      coalesce(b.advance_minor, 0) as advance_minor
    from ops.farmer_well_accounts a
    join ops.farmer_profiles fp on fp.id = a.farmer_profile_id
    join core.persons p on p.id = fp.person_id
    join core.wells w on w.id = a.well_id
    left join reporting.farmer_account_balances b
      on b.farmer_well_account_id = a.id
    where a.status = 'active'
      and fp.status = 'active'
      and p.status = 'active'
      and w.status = 'active'
      and a.credit_limit_minor is not null
      and (
        v_actor_id is null
        or exists (
          select 1
          from core.well_assignments mine
          where mine.well_id = a.well_id
            and mine.profile_id = v_actor_id
            and mine.status = 'active'
            and mine.role in ('owner', 'manager')
        )
      )
    order by a.id
  loop
    v_accounts_checked := v_accounts_checked + 1;
    v_outstanding_minor := greatest(
      v_account.debt_minor - v_account.advance_minor,
      0
    );

    if v_outstanding_minor > v_account.credit_limit_minor then
      v_accounts_over_limit := v_accounts_over_limit + 1;

      insert into ops.notifications (
        recipient_profile_id, well_id, type, message, deduplication_key
      )
      select distinct
        wa.profile_id,
        v_account.well_id,
        'debt_threshold_exceeded',
        format(
          'المزارع %s تجاوز حد الدين: ذمته %s والحد %s',
          v_account.farmer_name,
          v_outstanding_minor,
          v_account.credit_limit_minor
        ),
        format('debt:%s:%s', v_account.account_id, current_date)
      from core.well_assignments wa
      where wa.well_id = v_account.well_id
        and wa.status = 'active'
        and wa.role in ('owner', 'manager')
      on conflict (recipient_profile_id, type, deduplication_key)
        where deduplication_key is not null
        do nothing;

      get diagnostics v_inserted = row_count;
      v_notifications_created := v_notifications_created + v_inserted;
    end if;
  end loop;

  return jsonb_build_object(
    'day', current_date,
    'accounts_checked', v_accounts_checked,
    'accounts_over_limit', v_accounts_over_limit,
    'notifications_created', v_notifications_created
  );
end;
$function$;

revoke all on function ops.check_debt_thresholds() from public;
revoke all on function ops.check_debt_thresholds() from anon;
grant execute on function ops.check_debt_thresholds() to authenticated;
