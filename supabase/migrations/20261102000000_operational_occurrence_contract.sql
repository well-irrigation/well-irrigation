begin;
-- طلب المجموعة v1: occurrence_command_id (= p_command_id)، root_local_id، requested_at،
-- expected_revision، reason، start{started_at,pump_id,farm_id,farmer_well_account_id,
-- energy_source,crops,planned_duration_minutes,booking_id?,fuel_owner_person_id?}، delays[].
-- كل delay: booking_id,original_start,original_end,scheduled_start,scheduled_end.
-- التسوية v1: human_confirmed,reason,occurrence_command_id,original_rejected_request_id,
-- original_rejected_result,original_request_fingerprint,source_booking_id?,facts.
-- facts: root_local_id,start الأصلي، events[{command_id,type,occurred_at,payload}]،
-- completion{command_id,local_id,occurred_at,payload{p_session_id:{$ref,$kind}},
-- fuel_quantity_ml?,fuel_measurement_type?}، fuel_tank_id?.
-- قراءتا الإقرار تستقبلان الطلب الأصلي نفسه؛ fingerprint الناتج audit-only وليس هوية بديلة.
-- ق-137: هوية الواقعة من أمر البدء الأصلي؛ لا هوية بديلة ولا انتقال آلي.
-- تنفيذ محلي غير مشغّل؛ التحقق من PostgreSQL واختبارات التزامن مسؤولية المالك.
alter table core.wells add column operational_schedule_revision bigint not null default 0
  check (operational_schedule_revision >= 0);
create table ops.operational_occurrences (
  tenant_id uuid not null references core.tenants(id),
  occurrence_command_id uuid not null,
  well_id uuid not null references core.wells(id),
  source_booking_id uuid references ops.irrigation_bookings(id),
  original_request_id uuid not null,
  original_operator_id uuid not null references iam.profiles(id),
  started_at timestamptz not null,
  ended_at timestamptz,
  original_facts jsonb not null,
  provenance text not null check (provenance in ('accepted_start','delay_start_group','historical_settlement')),
  settlement_command_id uuid,
  completion_command_id uuid,
  server_session_id uuid references ops.irrigation_sessions(id) deferrable initially deferred,
  status text not null check (status in ('materializing','accepted')),
  created_at timestamptz not null default clock_timestamp(),
  resolved_at timestamptz,
  primary key (tenant_id, occurrence_command_id),
  unique (server_session_id),
  check (ended_at is null or ended_at > started_at),
  check (status <> 'accepted' or (server_session_id is not null and resolved_at is not null)),
  check (provenance <> 'historical_settlement' or
    (ended_at is not null and settlement_command_id is not null and completion_command_id is not null))
);
alter table ops.operational_occurrences enable row level security;
revoke all on ops.operational_occurrences from public,anon,authenticated,service_role;
create index operational_occurrences_well_time_idx on ops.operational_occurrences(well_id,started_at);
create index operational_occurrences_settlement_idx on ops.operational_occurrences(tenant_id,settlement_command_id);

-- قفل خاص لا يمنح جهة العميل سلطة على بئر. الدخول المفوّض مسؤولية غلاف الأعمال.
-- المدخل الجديد ينتظر قبل حمل أقفال أخرى؛ مدخل الكتابة القديم/الزناد يستخدم NOWAIT
-- حتى لا ينتظر قفل بئر أثناء حمل قفل صف قديم بترتيب معاكس.
create function ops.lock_operational_scope(p_well_id uuid,p_wait boolean default false) returns bigint
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $f$
declare r bigint;
begin
 if p_wait then
   select operational_schedule_revision into r from core.wells where id=p_well_id for update;
 else
   select operational_schedule_revision into r from core.wells where id=p_well_id for update nowait;
 end if;
 if not found then raise exception 'operational_scope_missing' using errcode='22023'; end if;
 return r;
end;$f$;

create function ops.guard_operational_schedule_write() returns trigger
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
 if changed and not historical then
   update core.wells set operational_schedule_revision=operational_schedule_revision+1 where id=w;
 end if;
 if TG_OP='DELETE' then return old; end if;
 return new;
end;$f$;
create trigger operational_occurrence_identity before insert or update or delete on ops.operational_occurrences
 for each row execute function ops.guard_operational_schedule_write();
create trigger operational_revision_well before update on core.wells
 for each row execute function ops.guard_operational_schedule_write();
do $install$
declare t text;
begin
 foreach t in array array['ops.irrigation_bookings','ops.resource_reservations','ops.irrigation_sessions',
   'core.pumps','core.water_lines','ops.resource_concurrency_rules','ops.farms','ops.farmer_well_accounts'] loop
   execute format('create trigger operational_scope_write before insert or update or delete on %s for each row execute function ops.guard_operational_schedule_write()',t);
 end loop;
end;$install$;

-- نواة مشتركة: لا منطق تسعير موازٍ، ولا فتح جلسة تاريخية.
create function ops.finalize_session_from_closed_segments(
 p_session_id uuid,p_ended_at timestamptz,p_fuel_tank_id uuid default null)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp
as $function$
declare
  v_actor uuid;
  v_well_id uuid;
  v_tenant_id uuid;
  v_status text;
  v_session_started_at timestamptz;
  v_operator_profile_id uuid;
  v_farmer_well_account_id uuid;
  v_open_segment_id uuid;
  v_open_segment_type text;
  v_open_energy_source text;
  v_open_started_at timestamptz;
  v_total_actual_seconds bigint;
  v_total_billable_seconds bigint;
  v_total_amount_minor bigint;
  v_weighted_numerator numeric;
  v_weighted_rate_minor bigint;
  v_charge_id uuid;
  v_fuel_quantity bigint;
  v_segment record;
  v_segments_json jsonb;
begin
 select s.well_id,w.tenant_id,s.started_at,s.farmer_well_account_id
 into v_well_id,v_tenant_id,v_session_started_at,v_farmer_well_account_id
 from ops.irrigation_sessions s join core.wells w on w.id=s.well_id
 where s.id=p_session_id for update of s;
 v_actor:=auth.uid();
 if not found or v_actor is null or not iam.has_well_permission(v_well_id,'session.complete') then
   raise exception 'completion_forbidden' using errcode='42501'; end if;
 if exists(select 1 from billing.session_charges where session_id=p_session_id) then
   raise exception 'session_already_charged' using errcode='23514'; end if;
 if p_ended_at<=v_session_started_at or not isfinite(p_ended_at) or
    not exists(select 1 from ops.session_segments where session_id=p_session_id) or
    exists(select 1 from (select started_at,ended_at,lag(ended_at) over(order by sequence_number) prev,
      row_number() over(order by sequence_number) n from ops.session_segments where session_id=p_session_id) q
      where (n=1 and started_at<>v_session_started_at) or (n>1 and started_at is distinct from prev)) or
    (select max(ended_at) from ops.session_segments where session_id=p_session_id) is distinct from p_ended_at then
   raise exception 'historical_segment_chronology_invalid' using errcode='23514'; end if;
  if exists (
    select 1
    from (
      select ss.sequence_number,
             row_number() over (order by ss.sequence_number) as expected_sequence
      from ops.session_segments ss
      where ss.session_id = p_session_id
    ) ordered_segments
    where ordered_segments.sequence_number <> ordered_segments.expected_sequence
  ) then
    raise exception 'ترتيب مقاطع الجلسة غير متسلسل ولا يمكن إكمالها';
  end if;

  if exists (
    select 1
    from ops.session_segments a
    join ops.session_segments b
      on b.session_id = a.session_id and b.id <> a.id
    where a.session_id = p_session_id
      and tstzrange(a.started_at, a.ended_at, '[)')
          && tstzrange(b.started_at, b.ended_at, '[)')
  ) then
    raise exception 'يوجد تداخل زمني بين مقاطع الجلسة ولا يمكن إكمالها';
  end if;

  if exists (
    select 1 from ops.session_segments ss
    where ss.session_id = p_session_id
      and (ss.ended_at is null or ss.ended_at <= ss.started_at)
  ) then
    raise exception 'يوجد مقطع بلا نهاية صحيحة ولا يمكن إكمال الجلسة';
  end if;

  if exists (
    select 1 from ops.session_segments ss
    where ss.session_id = p_session_id
      and ss.is_billable
      and ss.segment_type in ('solar_run', 'well_diesel_run', 'farmer_diesel_run')
      and coalesce(ss.applied_operation_rate_minor,
                   ss.applied_hourly_rate_minor, 0) <= 0
  ) then
    raise exception 'يوجد مقطع تشغيل بلا سعر مثبت صالح';
  end if;

  if exists (
    select 1 from ops.session_segments ss
    where ss.session_id = p_session_id
      and (ss.fuel_actual_ml is not null or ss.fuel_estimated_ml is not null)
      and ss.fuel_measurement_type is null
  ) then
    raise exception 'يوجد استهلاك وقود بلا نوع قياس محدد';
  end if;

  update ops.session_segments ss
  set actual_seconds = extract(epoch from (ss.ended_at - ss.started_at))::bigint,
      billable_seconds = case
        when ss.is_billable
          then extract(epoch from (ss.ended_at - ss.started_at))::bigint
        else 0
      end,
      actual_minutes = extract(epoch from (ss.ended_at - ss.started_at))::bigint / 60,
      raw_billable_minutes = case
        when ss.is_billable
          then extract(epoch from (ss.ended_at - ss.started_at))::bigint / 60
        else 0
      end,
      time_charge_minor = case
        when not ss.is_billable then 0
        else (
          extract(epoch from (ss.ended_at - ss.started_at))::bigint
          * coalesce(ss.applied_operation_rate_minor,
                     ss.applied_hourly_rate_minor)
        ) / 3600
      end,
      fuel_charge_minor = case
        when not ss.is_billable then 0
        when coalesce(ss.fuel_actual_ml, ss.fuel_estimated_ml, 0) = 0 then 0
        when ss.applied_fuel_price_per_liter_minor is null then 0
        else (
          coalesce(ss.fuel_actual_ml, ss.fuel_estimated_ml)
          * ss.applied_fuel_price_per_liter_minor
        ) / 1000
      end,
      -- تصحيح ق-17/ق-91: total = time فقط (الوقود رقابي لا يُضاف كرسوم)
      total_charge_minor = case
        when not ss.is_billable then 0
        else (
          extract(epoch from (ss.ended_at - ss.started_at))::bigint
          * coalesce(ss.applied_operation_rate_minor,
                     ss.applied_hourly_rate_minor)
        ) / 3600
      end
  where ss.session_id = p_session_id;

  select coalesce(sum(ss.actual_seconds), 0),
         coalesce(sum(ss.billable_seconds), 0),
         -- تصحيح ق-17/ق-91: المبلغ الإجمالي = مجموع time_charge_minor فقط
         coalesce(sum(ss.time_charge_minor), 0),
         coalesce(sum(
           ss.billable_seconds::numeric
           * coalesce(ss.applied_operation_rate_minor,
                      ss.applied_hourly_rate_minor, 0)::numeric
         ), 0)
  into v_total_actual_seconds, v_total_billable_seconds,
       v_total_amount_minor, v_weighted_numerator
  from ops.session_segments ss
  where ss.session_id = p_session_id;

  if v_total_billable_seconds <= 0 then
    raise exception 'لا يوجد وقت تشغيل مفوتر في الجلسة';
  end if;
  if v_total_billable_seconds > 2147483647 then
    raise exception 'مدة الجلسة المفوترة تتجاوز الحد المدعوم';
  end if;

  v_weighted_rate_minor := round(
    v_weighted_numerator / v_total_billable_seconds
  )::bigint;

  if v_weighted_rate_minor <= 0 then
    raise exception 'تعذر حساب متوسط سعر زمني صالح للجلسة';
  end if;

  update ops.irrigation_sessions
  set ended_at = p_ended_at,
      status = 'closed',
      updated_at = clock_timestamp()
  where id = p_session_id;

  insert into billing.session_charges (
    session_id, well_id, duration_seconds, price_per_hour_minor,
    amount_minor, pricing_mode
  ) values (
    p_session_id, v_well_id, v_total_billable_seconds::integer,
    v_weighted_rate_minor, v_total_amount_minor, 'segments'
  )
  returning id into v_charge_id;

  for v_segment in
    select ss.id, ss.energy_source, ss.fuel_owner_person_id,
           ss.fuel_actual_ml, ss.fuel_estimated_ml,
           ss.fuel_measurement_type, ss.ended_at
    from ops.session_segments ss
    where ss.session_id = p_session_id
      and ss.energy_source in ('well_diesel', 'farmer_diesel')
      and coalesce(ss.fuel_actual_ml, ss.fuel_estimated_ml, 0) > 0
    order by ss.sequence_number
  loop
    v_fuel_quantity := coalesce(v_segment.fuel_actual_ml,
                                v_segment.fuel_estimated_ml);

    insert into inventory.fuel_transactions (
      tenant_id, well_id, fuel_tank_id, transaction_type,
      ownership_type, owner_person_id, farmer_well_account_id,
      quantity_ml, direction, measurement_type, session_segment_id,
      occurred_at, status, created_by, notes
    ) values (
      v_tenant_id, v_well_id,
      case when v_segment.energy_source = 'well_diesel'
        then p_fuel_tank_id else null end,
      'session_consumption',
      case when v_segment.energy_source = 'well_diesel'
        then 'well' else 'farmer' end,
      case when v_segment.energy_source = 'farmer_diesel'
        then v_segment.fuel_owner_person_id else null end,
      case when v_segment.energy_source = 'farmer_diesel'
        then v_farmer_well_account_id else null end,
      v_fuel_quantity, 'out', v_segment.fuel_measurement_type,
      v_segment.id, v_segment.ended_at, 'posted', v_actor,
      'استهلاك وقود ناتج عن إكمال جلسة السقي'
    );
  end loop;

  select jsonb_agg(
    jsonb_build_object(
      'segment_id', ss.id,
      'sequence_number', ss.sequence_number,
      'segment_type', ss.segment_type,
      'energy_source', ss.energy_source,
      'actual_seconds', ss.actual_seconds,
      'billable_seconds', ss.billable_seconds,
      'time_charge_minor', ss.time_charge_minor,
      'fuel_charge_minor', ss.fuel_charge_minor,
      'total_charge_minor', ss.total_charge_minor
    ) order by ss.sequence_number
  )
  into v_segments_json
  from ops.session_segments ss
  where ss.session_id = p_session_id;

  insert into audit.audit_logs (
    tenant_id, well_id, user_id, action, entity_type, entity_id,
    new_values, reason
  ) values (
    v_tenant_id, v_well_id, v_actor, 'session_completed',
    'ops.irrigation_sessions', p_session_id,
    jsonb_build_object(
      'ended_at', p_ended_at,
      'actual_seconds', v_total_actual_seconds,
      'billable_seconds', v_total_billable_seconds,
      'amount_minor', v_total_amount_minor,
      'pricing_mode', 'segments'
    ),
    'إكمال جلسة السقي عبر الإجراء الذري'
  );

  return jsonb_build_object(
    'session_id', p_session_id,
    'session_charge_id', v_charge_id,
    'status', 'closed',
    'ended_at', p_ended_at,
    'actual_seconds', v_total_actual_seconds,
    'billable_seconds', v_total_billable_seconds,
    'weighted_price_per_hour_minor', v_weighted_rate_minor,
    'amount_minor', v_total_amount_minor,
    'segments', coalesce(v_segments_json, '[]'::jsonb)
  );
end;
$function$;

create or replace function ops.complete_irrigation_session(
  p_session_id uuid,
  p_ended_at timestamptz default now(),
  p_fuel_quantity_ml bigint default null,
  p_fuel_measurement_type text default null,
  p_fuel_tank_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'ops', 'billing', 'inventory', 'core', 'audit', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_well_id uuid;
  v_tenant_id uuid;
  v_status text;
  v_session_started_at timestamptz;
  v_operator_profile_id uuid;
  v_farmer_well_account_id uuid;
  v_open_segment_id uuid;
  v_open_segment_type text;
  v_open_energy_source text;
  v_open_started_at timestamptz;
  v_total_actual_seconds bigint;
  v_total_billable_seconds bigint;
  v_total_amount_minor bigint;
  v_weighted_numerator numeric;
  v_weighted_rate_minor bigint;
  v_charge_id uuid;
  v_fuel_quantity bigint;
  v_segment record;
  v_segments_json jsonb;
begin
  perform ops.lock_operational_scope((select well_id from ops.irrigation_sessions where id=p_session_id));
  if p_fuel_quantity_ml is not null and p_fuel_quantity_ml <= 0 then
    raise exception 'كمية الوقود المستهلك يجب أن تكون أكبر من صفر';
  end if;
  if p_fuel_quantity_ml is not null
     and coalesce(p_fuel_measurement_type, 'actual') not in ('actual', 'estimated') then
    raise exception 'نوع قياس الوقود يجب أن يكون actual أو estimated';
  end if;

  select s.well_id, w.tenant_id, s.status, s.started_at,
         s.operator_profile_id, s.farmer_well_account_id
  into v_well_id, v_tenant_id, v_status, v_session_started_at,
       v_operator_profile_id, v_farmer_well_account_id
  from ops.irrigation_sessions s
  join core.wells w on w.id = s.well_id
  where s.id = p_session_id
  for update of s;

  if not found then
    raise exception 'جلسة السقي غير موجودة: %', p_session_id;
  end if;
  if v_status <> 'open' then
    raise exception 'لا يمكن إكمال جلسة مغلقة أو غير مفتوحة';
  end if;

  v_actor := auth.uid();
  if v_actor is null or not iam.has_well_permission(v_well_id, 'session.complete') then
    raise exception 'لا تملك صلاحية إكمال هذه الجلسة';
  end if;
  if p_ended_at <= v_session_started_at then
    raise exception 'وقت نهاية الجلسة يجب أن يكون بعد وقت بدايتها';
  end if;
  if p_fuel_tank_id is not null and not exists (
    select 1 from inventory.fuel_tanks ft
    where ft.id = p_fuel_tank_id
      and ft.well_id = v_well_id
      and ft.status = 'active'
  ) then
    raise exception 'خزان الوقود غير موجود أو غير فعال في هذا البئر';
  end if;
  if exists (
    select 1 from billing.session_charges sc where sc.session_id = p_session_id
  ) then
    raise exception 'توجد تكلفة مسجلة مسبقًا لهذه الجلسة';
  end if;

  select ss.id, ss.segment_type, ss.energy_source, ss.started_at
  into v_open_segment_id, v_open_segment_type, v_open_energy_source,
       v_open_started_at
  from ops.session_segments ss
  where ss.session_id = p_session_id and ss.ended_at is null
  order by ss.sequence_number desc
  limit 1
  for update;

  if not found then
    raise exception 'لا يوجد مقطع مفتوح يمكن إغلاقه عند إكمال الجلسة';
  end if;
  if p_ended_at <= v_open_started_at then
    raise exception 'وقت نهاية الجلسة يجب أن يكون بعد وقت بدء المقطع المفتوح';
  end if;
  if p_fuel_quantity_ml is not null
     and v_open_energy_source not in ('well_diesel', 'farmer_diesel') then
    raise exception 'لا يمكن تسجيل استهلاك وقود على مقطع غير ديزل';
  end if;

  update ops.session_segments
  set ended_at = p_ended_at,
      fuel_measurement_type = case
        when p_fuel_quantity_ml is null then fuel_measurement_type
        else coalesce(p_fuel_measurement_type, 'actual')
      end,
      fuel_actual_ml = case
        when p_fuel_quantity_ml is not null
         and coalesce(p_fuel_measurement_type, 'actual') = 'actual'
          then p_fuel_quantity_ml
        else fuel_actual_ml
      end,
      fuel_estimated_ml = case
        when p_fuel_quantity_ml is not null
         and coalesce(p_fuel_measurement_type, 'actual') = 'estimated'
          then p_fuel_quantity_ml
        else fuel_estimated_ml
      end
  where id = v_open_segment_id;

  return ops.finalize_session_from_closed_segments(p_session_id,p_ended_at,p_fuel_tank_id);
end;
$function$;

create or replace function ops.attach_session_to_open_shift()
returns trigger
language plpgsql
security definer
set search_path to 'ops', 'pg_temp'
as $$
begin
  if exists(select 1 from ops.operational_occurrences o where o.server_session_id=new.id
     and o.provenance='historical_settlement' and new.status='closed'
     and new.started_at=o.started_at and new.ended_at=o.ended_at) then
    new.current_shift_id:=null;
    new.collector_profile_id:=null;
    return new;
  end if;
  if new.current_shift_id is null then
    select s.id into new.current_shift_id from ops.shifts s
    where s.well_id = new.well_id and s.status = 'open' limit 1;
  end if;

  if new.collector_profile_id is null then
    if new.current_shift_id is not null then
      select s.operator_profile_id into new.collector_profile_id
      from ops.shifts s where s.id = new.current_shift_id;
    end if;
    new.collector_profile_id := coalesce(new.collector_profile_id, new.operator_profile_id);
  end if;

  return new;
end;
$$;

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

create or replace function ops.create_booking(
  p_well_id uuid,
  p_farmer_well_account_id uuid,
  p_farm_id uuid,
  p_scheduled_start timestamptz,
  p_scheduled_end timestamptz,
  p_expected_energy_source text,
  p_priority integer,
  p_notes text,
  p_alternative_energy_source text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ops, core, audit, iam, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_readiness jsonb;
  v_result jsonb;
  v_active_pump_id uuid;
begin
  perform ops.lock_operational_scope(p_well_id);
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إنشاء حجز سقي';
  end if;
  if not iam.has_well_permission(p_well_id, 'booking.create') then
    raise exception 'لا تملك صلاحية إنشاء حجز في هذا البئر';
  end if;

  v_readiness := ops.evaluate_booking_execution_readiness(
    p_well_id,
    p_scheduled_start,
    p_scheduled_end,
    p_expected_energy_source,
    p_alternative_energy_source
  );

  if not coalesce((v_readiness ->> 'ready')::boolean, false) then
    return jsonb_build_object(
      'status', 'rejected',
      'reason_code', v_readiness ->> 'reason_code',
      'requested_start', p_scheduled_start,
      'requested_end', p_scheduled_end,
      'execution_readiness', v_readiness
    );
  end if;

  v_active_pump_id := (v_readiness ->> 'active_pump_id')::uuid;
  perform 1
  from core.pumps p
  where p.id = v_active_pump_id
    and p.well_id = p_well_id
    and p.status = 'active'
  for update;

  if not found then
    v_readiness := ops.evaluate_booking_execution_readiness(
      p_well_id,
      p_scheduled_start,
      p_scheduled_end,
      p_expected_energy_source,
      p_alternative_energy_source
    );
    return jsonb_build_object(
      'status', 'rejected',
      'reason_code', v_readiness ->> 'reason_code',
      'requested_start', p_scheduled_start,
      'requested_end', p_scheduled_end,
      'execution_readiness', v_readiness
    );
  end if;

  v_result := ops.create_booking_m112_unchecked(
    p_well_id,
    p_farmer_well_account_id,
    p_farm_id,
    p_scheduled_start,
    p_scheduled_end,
    p_expected_energy_source,
    p_priority,
    p_notes
  );

  if v_result ->> 'status' = 'confirmed' then
    update ops.irrigation_bookings
    set alternative_energy_source = p_alternative_energy_source
    where id = (v_result ->> 'booking_id')::uuid;
  end if;

  return v_result || jsonb_build_object(
    'alternative_energy_source', p_alternative_energy_source,
    'execution_readiness', v_readiness
  );
end;
$function$;

create or replace function ops.reschedule_booking(
  p_booking_id uuid,
  p_scheduled_start timestamptz,
  p_scheduled_end timestamptz,
  p_reason text,
  p_alternative_energy_source text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ops, core, audit, iam, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_booking ops.irrigation_bookings%rowtype;
  v_alternative text;
  v_readiness jsonb;
  v_result jsonb;
  v_active_pump_id uuid;
begin
  perform ops.lock_operational_scope((select well_id from ops.irrigation_bookings where id=p_booking_id));
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إعادة جدولة الحجز';
  end if;

  select b.* into v_booking
  from ops.irrigation_bookings b
  where b.id = p_booking_id
  for update;
  if not found then
    raise exception 'الحجز غير موجود: %', p_booking_id;
  end if;
  if not iam.has_well_permission(v_booking.well_id, 'booking.reschedule') then
    raise exception 'لا تملك صلاحية إعادة جدولة هذا الحجز';
  end if;
  if v_booking.status not in ('confirmed', 'postponed') then
    raise exception 'لا يمكن إعادة جدولة حجز حالته %', v_booking.status;
  end if;

  -- NULL يعني أن العميل القديم لم يرسل الوسيط: احتفظ بالمحفوظ.
  -- تغيير البديل يتم بقيمة غير NULL صريحة، فلا تصفير صامتًا.
  v_alternative := coalesce(
    p_alternative_energy_source,
    v_booking.alternative_energy_source
  );

  v_readiness := ops.evaluate_booking_execution_readiness(
    v_booking.well_id,
    p_scheduled_start,
    p_scheduled_end,
    v_booking.expected_energy_source,
    v_alternative
  );

  if not coalesce((v_readiness ->> 'ready')::boolean, false) then
    return jsonb_build_object(
      'status', 'rejected',
      'reason_code', v_readiness ->> 'reason_code',
      'booking_id', p_booking_id,
      'requested_start', p_scheduled_start,
      'requested_end', p_scheduled_end,
      'execution_readiness', v_readiness
    );
  end if;

  v_active_pump_id := (v_readiness ->> 'active_pump_id')::uuid;
  perform 1
  from core.pumps p
  where p.id = v_active_pump_id
    and p.well_id = v_booking.well_id
    and p.status = 'active'
  for update;

  if not found then
    v_readiness := ops.evaluate_booking_execution_readiness(
      v_booking.well_id,
      p_scheduled_start,
      p_scheduled_end,
      v_booking.expected_energy_source,
      v_alternative
    );
    return jsonb_build_object(
      'status', 'rejected',
      'reason_code', v_readiness ->> 'reason_code',
      'booking_id', p_booking_id,
      'requested_start', p_scheduled_start,
      'requested_end', p_scheduled_end,
      'execution_readiness', v_readiness
    );
  end if;

  v_result := ops.reschedule_booking_m112_unchecked(
    p_booking_id,
    p_scheduled_start,
    p_scheduled_end,
    p_reason
  );

  if v_result ->> 'status' = 'confirmed' then
    update ops.irrigation_bookings
    set alternative_energy_source = v_alternative
    where id = p_booking_id;
  end if;

  return v_result || jsonb_build_object(
    'alternative_energy_source', v_alternative,
    'execution_readiness', v_readiness
  );
end;
$function$;

create or replace function ops.cancel_booking(
  p_booking_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to 'ops', 'core', 'audit', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_booking ops.irrigation_bookings%rowtype;
  v_released integer := 0;
begin
  perform ops.lock_operational_scope((select well_id from ops.irrigation_bookings where id=p_booking_id));
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إلغاء حجز سقي';
  end if;
  if nullif(btrim(p_reason), '') is null then
    raise exception 'سبب إلغاء الحجز مطلوب';
  end if;

  select b.* into v_booking
  from ops.irrigation_bookings b
  where b.id = p_booking_id
  for update;
  if not found then
    raise exception 'الحجز غير موجود: %', p_booking_id;
  end if;
  if not iam.has_well_permission(v_booking.well_id, 'booking.cancel') then
    raise exception 'لا تملك صلاحية إلغاء هذا الحجز';
  end if;
  if v_booking.status not in ('draft', 'pending', 'confirmed', 'waiting', 'ready', 'postponed') then
    raise exception 'لا يمكن إلغاء حجز حالته %', v_booking.status;
  end if;

  update ops.resource_reservations
  set status = 'cancelled'
  where booking_id = p_booking_id and status = 'active';
  get diagnostics v_released = row_count;

  update ops.irrigation_bookings
  set status = 'cancelled'
  where id = p_booking_id;

  insert into ops.booking_status_history (
    tenant_id, booking_id, old_status, new_status, reason, changed_by, changed_at
  ) values (
    v_booking.tenant_id, p_booking_id, v_booking.status,
    'cancelled', btrim(p_reason), v_actor,
    clock_timestamp()
  );

  perform audit.log(
    v_booking.tenant_id, v_booking.well_id, 'cancel_booking',
    'ops.irrigation_bookings', p_booking_id,
    jsonb_build_object(
      'status', v_booking.status,
      'scheduled_start', v_booking.scheduled_start,
      'scheduled_end', v_booking.scheduled_end
    ),
    jsonb_build_object(
      'status', 'cancelled',
      'released_reservations', v_released
    ),
    btrim(p_reason)
  );

  return jsonb_build_object(
    'status', 'cancelled',
    'booking_id', p_booking_id,
    'previous_status', v_booking.status,
    'released_reservations', v_released
  );
end;
$function$;

create or replace function ops.reserve_resource(
  p_well_id uuid,
  p_resource_type text,
  p_resource_id uuid,
  p_reserved_period tstzrange,
  p_booking_id uuid default null,
  p_session_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = 'ops', 'core', 'pg_temp'
as $function$
declare
  v_tenant_id uuid;
  v_default_limit integer;
  v_rule_limit integer;
  v_max_parallel integer;
  v_active_count integer;
  v_reservation_id uuid;
begin
  perform ops.lock_operational_scope(p_well_id);
  select w.tenant_id
  into v_tenant_id
  from core.wells w
  where w.id = p_well_id;

  if v_tenant_id is null then
    raise exception 'البئر المحدد غير موجود: %', p_well_id;
  end if;

  if p_resource_type = 'well_path' then

    if p_resource_id is distinct from p_well_id then
      raise exception 'حجز مسار البئر يجب أن يكون على البئر نفسه';
    end if;
    v_default_limit := 1;

  elsif p_resource_type = 'water_line' then

    select wl.max_parallel_sessions
    into v_default_limit
    from core.water_lines wl
    where wl.id = p_resource_id
      and wl.well_id = p_well_id
      and wl.status = 'active'
    for update;

    if not found then
      raise exception
        'المورد المحدد غير موجود أو غير فعال في هذا البئر: % (%)',
        p_resource_id,
        p_resource_type;
    end if;

  elsif p_resource_type = 'pump' then

    perform 1
    from core.pumps p
    where p.id = p_resource_id
      and p.well_id = p_well_id
      and p.status = 'active'
    for update;

    if not found then
      raise exception
        'المورد المحدد غير موجود أو غير فعال في هذا البئر: % (%)',
        p_resource_id,
        p_resource_type;
    end if;

    v_default_limit := 1;

  else
    raise exception
      'نوع المورد غير صالح للحجز: %',
      p_resource_type;
  end if;

  select r.max_parallel_sessions
  into v_rule_limit
  from ops.resource_concurrency_rules r
  where r.well_id = p_well_id
    and r.rule_status = 'active'
    and (
      (
        r.resource_type = p_resource_type
        and r.resource_id = p_resource_id
      )
      or r.resource_type = 'well'
    )
  order by
    case
      when r.resource_type = p_resource_type
       and r.resource_id = p_resource_id
      then 0
      else 1
    end
  limit 1;

  v_max_parallel :=
    coalesce(v_rule_limit, v_default_limit);

  select count(*)
  into v_active_count
  from ops.resource_reservations rr
  where rr.resource_type = p_resource_type
    and rr.resource_id = p_resource_id
    and rr.status = 'active'
    and rr.reserved_period && p_reserved_period;

  if v_active_count >= v_max_parallel then
    raise exception
      'المورد محجوز بالكامل خلال هذه الفترة (الحد الأقصى للتوازي: %)',
      v_max_parallel;
  end if;

  insert into ops.resource_reservations (
    tenant_id,
    well_id,
    resource_type,
    resource_id,
    booking_id,
    session_id,
    reserved_period,
    status
  )
  values (
    v_tenant_id,
    p_well_id,
    p_resource_type,
    p_resource_id,
    p_booking_id,
    p_session_id,
    p_reserved_period,
    'active'
  )
  returning id into v_reservation_id;

  return v_reservation_id;
end;
$function$;

create or replace function ops.start_irrigation_session(
  p_well_id uuid,
  p_pump_id uuid,
  p_farm_id uuid,
  p_farmer_well_account_id uuid,
  p_operator_profile_id uuid,
  p_energy_source text,
  p_started_at timestamptz default clock_timestamp(),
  p_fuel_owner_person_id uuid default null,
  p_crops text[] default null
)
returns uuid
language plpgsql
security definer
set search_path to 'ops', 'core', 'billing', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_session_id uuid;
begin
  perform ops.lock_operational_scope(p_well_id);
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل بدء جلسة السقي';
  end if;
  if p_operator_profile_id is distinct from v_actor then
    raise exception 'معرف المشغل يجب أن يطابق المستخدم المسجل حاليًا';
  end if;
  if not iam.has_well_permission(p_well_id, 'session.start') then
    raise exception 'لا تملك صلاحية بدء جلسة على هذا البئر';
  end if;
  if not exists (
    select 1 from core.pumps p
    where p.id = p_pump_id and p.well_id = p_well_id and p.status = 'active'
  ) then
    raise exception 'المضخة غير موجودة أو غير فعالة في هذا البئر';
  end if;
  if not exists (
    select 1 from ops.farms f
    where f.id = p_farm_id and f.well_id = p_well_id and f.status = 'active'
  ) then
    raise exception 'المزرعة غير موجودة أو غير فعالة في هذا البئر';
  end if;
  if not exists (
    select 1 from ops.farmer_well_accounts fwa
    where fwa.id = p_farmer_well_account_id
      and fwa.well_id = p_well_id
      and fwa.status = 'active'
  ) then
    raise exception 'حساب المزارع غير موجود أو غير فعال في هذا البئر';
  end if;

  insert into ops.irrigation_sessions (
    well_id, pump_id, farm_id, farmer_well_account_id,
    operator_profile_id, started_at, status
  ) values (
    p_well_id, p_pump_id, p_farm_id, p_farmer_well_account_id,
    p_operator_profile_id, p_started_at, 'open'
  )
  returning id into v_session_id;

  perform ops.create_priced_session_segment(
    v_session_id, p_energy_source, p_started_at, p_fuel_owner_person_id
  );

  -- محاصيل الجلسة (ق-131 البند 1): لقطة تُكتب مرة واحدة عند البدء ولا
  -- مسار تعديل لها لاحقًا. الفراغ بعد التطبيع يُتجاهل والتكرار يُدنَّب
  -- بلا فشل: قائمة اختيارية غير مالية، وتعطيل بدء الجلسة كلها بسبب
  -- عنصر تجميلي كان منع عمل يقبله الخادم (فشل كاذب).
  if p_crops is not null then
    insert into ops.session_crops (session_id, crop_name, position)
    select
      v_session_id,
      normalized.name,
      row_number() over (order by normalized.ord)
    from (
      select t.ord, btrim(t.crop) as name
      from unnest(p_crops) with ordinality as t(crop, ord)
      where t.crop is not null and btrim(t.crop) <> ''
    ) normalized
    on conflict (session_id, crop_name) do nothing;
  end if;

  return v_session_id;
end;
$function$;

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
  perform ops.lock_operational_scope((select well_id from ops.irrigation_bookings where id=p_booking_id));
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

create or replace function ops.start_adhoc_session(
  p_well_id uuid,
  p_pump_id uuid,
  p_farm_id uuid,
  p_farmer_well_account_id uuid,
  p_energy_source text,
  p_planned_duration_minutes integer,
  p_started_at timestamptz default clock_timestamp(),
  p_fuel_owner_person_id uuid default null,
  p_crops text[] default null
)
returns uuid
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_session_id uuid;
begin
  perform ops.lock_operational_scope(p_well_id);
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل بدء جلسة سقي';
  end if;
  if p_planned_duration_minutes is not null and p_planned_duration_minutes <= 0 then
    raise exception 'المدة المخطّطة يجب أن تكون دقائق موجبة' using errcode = '22023';
  end if;

  v_session_id := ops.start_irrigation_session(
    p_well_id, p_pump_id, p_farm_id, p_farmer_well_account_id,
    v_actor, p_energy_source, p_started_at, p_fuel_owner_person_id, p_crops
  );

  if p_planned_duration_minutes is not null then
    update ops.irrigation_sessions
    set planned_duration_minutes = p_planned_duration_minutes,
        planned_end_at = started_at + make_interval(mins => p_planned_duration_minutes)
    where id = v_session_id;
  end if;

  return v_session_id;
end;
$function$;

create or replace function api.get_well_day_schedule(
  p_well_id uuid,
  p_day date default null
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_staff boolean;
  v_self_account uuid;
  v_day date;
  v_window tstzrange;
  v_day_start timestamptz;
  v_day_end timestamptz;
  v_well_tz text;
  v_current_session jsonb;
  v_bookings jsonb;
  v_server_time timestamptz;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة جدول اليوم';
  end if;

  v_staff := iam.has_well_permission(p_well_id, 'booking.read');
  if not v_staff then
    v_self_account := iam.current_farmer_well_account_id(p_well_id);
    if v_self_account is null then
      raise exception 'لا تملك صلاحية قراءة جدول هذا البئر'
        using errcode = '42501';
    end if;
  end if;

  -- اليوم الحاكم = Asia/Aden (ق-132 §ب / الثابت 756)، لا منطقة الهاتف
  -- ولا منطقة اتصال قاعدة البيانات؛ وبلا Cron لتغيّر التاريخ. النافذة
  -- محسوبة سطريًا هنا داخل غلاف SECURITY INVOKER: لا دالة مساعدة تحتاج
  -- GRANT لدور تطبيق (تفادي permission denied بلا توسيع صلاحيات ops).
  v_day := coalesce(p_day, (now() at time zone 'Asia/Aden')::date);
  v_window := tstzrange(
    (v_day::timestamp) at time zone 'Asia/Aden',
    ((v_day + 1)::timestamp) at time zone 'Asia/Aden',
    '[)'
  );
  v_day_start := lower(v_window);
  v_day_end := upper(v_window);
  v_well_tz := core.well_timezone(p_well_id);

  -- الجلسة الجارية (status='open') المرئية للمستخدم المخوّل إن تداخلت
  -- مع يوم الطلب (بدأت قبل نهاية اليوم). لا اختلاق: null عند غيابها.
  select jsonb_build_object(
      'session_id', s.id,
      'status', s.status,
      'started_at', s.started_at,
      'ended_at', s.ended_at,
      'well_id', s.well_id,
      'pump_id', s.pump_id,
      'farm_id', s.farm_id,
      'farmer_well_account_id', s.farmer_well_account_id,
      'booking_id', s.booking_id,
      'booking_public_code', b.public_code
    )
    into v_current_session
  from ops.irrigation_sessions s
  left join ops.irrigation_bookings b on b.id = s.booking_id
  where s.well_id = p_well_id
    and s.status = 'open'
    and (v_staff or s.farmer_well_account_id = v_self_account)
    and s.started_at < v_day_end
  order by s.started_at desc
  limit 1;

  -- حجوزات اليوم: كل حجز يتداخل مع نافذة اليوم (يشمل العابر لمنتصف
  -- الليل). الترتيب: المجموعة الفعّالة أولًا ثم المطوية، وداخل كل
  -- مجموعة بوقت البداية ثم الأولوية ثم الرمز العام. الجلسة الفعلية
  -- تُرفق في مفتاح session منفصل عن الحقول المخططة (booking ≠ session).
  select coalesce(
      jsonb_agg(
        x.item
        order by x.grp_rank, x.scheduled_start, x.priority desc, x.public_code
      ),
      '[]'::jsonb
    )
    into v_bookings
  from (
    select
      b.scheduled_start,
      b.priority,
      b.public_code,
      case
        when b.status in
          ('confirmed','pending','waiting','ready','started') then 0
        when b.status in
          ('completed','postponed','cancelled','no_show') then 1
        else 2
      end as grp_rank,
      jsonb_build_object(
        'id', b.id,
        'public_code', b.public_code,
        'well_id', b.well_id,
        'farmer_well_account_id', b.farmer_well_account_id,
        'farmer_name', person.full_name,
        'farm_id', b.farm_id,
        'farm_name', f.name,
        'scheduled_start', b.scheduled_start,
        'scheduled_end', b.scheduled_end,
        'scheduled_day',
          (b.scheduled_start at time zone 'Asia/Aden')::date::text,
        'expected_duration_minutes', b.expected_duration_minutes,
        'expected_energy_source', b.expected_energy_source,
        'alternative_energy_source', b.alternative_energy_source,
        'status', b.status,
        'priority', b.priority,
        'status_group', case
          when b.status in
            ('confirmed','pending','waiting','ready','started') then 'active'
          when b.status in
            ('completed','postponed','cancelled','no_show') then 'closed'
          else 'draft'
        end,
        'notes', b.notes,
        'session', case
          when s.id is null then null
          else jsonb_build_object(
            'session_id', s.id,
            'status', s.status,
            'started_at', s.started_at,
            'ended_at', s.ended_at
          )
        end
      ) as item
    from ops.irrigation_bookings b
    left join ops.farms f on f.id = b.farm_id
    left join ops.farmer_well_accounts fwa
      on fwa.id = b.farmer_well_account_id
    left join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
    left join core.persons person on person.id = fp.person_id
    left join ops.irrigation_sessions s on s.booking_id = b.id
    where b.well_id = p_well_id
      and (v_staff or b.farmer_well_account_id = v_self_account)
      and tstzrange(b.scheduled_start, b.scheduled_end, '[)') && v_window
  ) x;

  v_server_time := statement_timestamp();
  return jsonb_build_object(
    'status', 'ok',
    'server_time', v_server_time,
    'well_id', p_well_id,
    'operational_schedule_revision', (select operational_schedule_revision from core.wells where id=p_well_id),
    'requested_day', v_day::text,
    'timezone', 'Asia/Aden',
    'day_start', v_day_start,
    'day_end', v_day_end,
    'well_timezone', v_well_tz,
    'current_session', v_current_session,
    'count', jsonb_array_length(v_bookings),
    'bookings', v_bookings
  );
end;
$function$;

-- شكل الوقائع: start الأصلي، events مرتبة، completion الأصلي. لا مبلغ ولا سعر من الهاتف.
create function ops.materialize_historical_occurrence(
 p_well_id uuid,p_occurrence_id uuid,p_settlement_id uuid,p_facts jsonb)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $f$
declare
 o ops.operational_occurrences%rowtype; s jsonb:=p_facts->'start'; c jsonb:=p_facts->'completion';
 e jsonb; ep jsonb; at_time timestamptz; stop_time timestamptz; previous_time timestamptz;
 sid uuid; segment_id uuid; completion_id uuid; guard jsonb; result jsonb; seq integer:=1;
 running boolean:=true; pending_source boolean:=false; source text; owner_id uuid;
 last_run ops.session_segments%rowtype; old_segment ops.session_segments%rowtype;
 reason text; request_payload jsonb; event_ids uuid[]; q bigint; measurement text;
begin
 select * into strict o from ops.operational_occurrences
 where well_id=p_well_id and occurrence_command_id=p_occurrence_id
   and settlement_command_id=p_settlement_id and provenance='historical_settlement' for update;
 sid:=o.server_session_id; stop_time:=(c->>'occurred_at')::timestamptz;
 completion_id:=(c->>'command_id')::uuid;
 if auth.uid() is null or not iam.has_well_permission(p_well_id,'session.complete') then
   raise exception 'historical_settlement_forbidden' using errcode='42501'; end if;
 if o.status<>'materializing' or completion_id is null or completion_id<>o.completion_command_id
    or (s->>'started_at')::timestamptz<>o.started_at or stop_time<>o.ended_at
    or not isfinite(o.started_at) or not isfinite(stop_time)
    or o.started_at>=stop_time or stop_time>=transaction_timestamp()
    or jsonb_typeof(p_facts->'events') is distinct from 'array'
    or jsonb_typeof(c->'payload') is distinct from 'object'
    or (select count(*) from jsonb_object_keys(c->'payload'))<>1
    or c->'payload'->'p_session_id' is distinct from jsonb_build_object('$ref',p_facts->>'root_local_id','$kind','session') then
   raise exception 'historical_facts_invalid' using errcode='22023'; end if;
 if exists(select 1 from ops.irrigation_sessions x
    where (x.well_id=p_well_id or x.pump_id=(s->>'pump_id')::uuid)
    and tstzrange(x.started_at,x.ended_at,'[)') && tstzrange(o.started_at,stop_time,'[)')) then
   raise exception 'historical_interval_conflict' using errcode='23514'; end if;
 if not exists(select 1 from core.pumps where id=(s->>'pump_id')::uuid and well_id=p_well_id)
    or not exists(select 1 from ops.farms f join ops.farmer_well_accounts a on a.id=f.farmer_well_account_id
      where f.id=(s->>'farm_id')::uuid and f.well_id=p_well_id and a.well_id=p_well_id
        and a.tenant_id=o.tenant_id and a.id=(s->>'farmer_well_account_id')::uuid) then
   raise exception 'historical_entity_scope_mismatch' using errcode='22023'; end if;
 request_payload:=jsonb_build_object('session_id',sid,'well_id',p_well_id,
   'ended_at',stop_time,'original_command',c,'occurrence_command_id',p_occurrence_id);
 guard:=sync.begin_command(o.tenant_id,completion_id,'complete_irrigation_session',request_payload,sid);
 if coalesce((guard->>'duplicate')::boolean,false) then
   -- لا استبدال لنتيجة إكمال سابقة، حتى عند نقص بصمتها القديمة.
   raise exception 'original_completion_already_has_result' using errcode='22023'; end if;
 insert into ops.irrigation_sessions(id,well_id,pump_id,farm_id,farmer_well_account_id,
   operator_profile_id,started_at,ended_at,status,booking_id,current_shift_id,collector_profile_id)
 values(sid,p_well_id,(s->>'pump_id')::uuid,(s->>'farm_id')::uuid,
   (s->>'farmer_well_account_id')::uuid,o.original_operator_id,o.started_at,stop_time,'closed',null,null,null);
 -- source_booking_id في سجل الواقعة هو المنشأ؛ لا استهلاك لحجز أعيدت جدولته الآن.
 source:=s->>'energy_source'; owner_id:=(s->>'fuel_owner_person_id')::uuid;
 segment_id:=ops.create_priced_session_segment(sid,source,o.started_at,owner_id);
 previous_time:=o.started_at; event_ids:=array[p_occurrence_id,completion_id,p_settlement_id];
 for e in select value from jsonb_array_elements(p_facts->'events') loop
   ep:=e->'payload'; at_time:=(e->>'occurred_at')::timestamptz;
   if (e->>'command_id')::uuid is null or (e->>'command_id')::uuid=any(event_ids)
      or at_time is null or not isfinite(at_time) or at_time<=previous_time or at_time>=stop_time
      or jsonb_typeof(ep) is distinct from 'object'
      or ep->'p_session_id' is distinct from c->'payload'->'p_session_id' then
     raise exception 'historical_event_chronology_invalid' using errcode='22023'; end if;
   event_ids:=array_append(event_ids,(e->>'command_id')::uuid);
   guard:=sync.begin_command(o.tenant_id,(e->>'command_id')::uuid,e->>'type',
     jsonb_build_object('session_id',sid,'original_command',e,'occurrence_command_id',p_occurrence_id),sid);
   if coalesce((guard->>'duplicate')::boolean,false) then
     raise exception 'historical_event_identity_already_used' using errcode='22023'; end if;
   select * into strict old_segment from ops.session_segments where id=segment_id;
   update ops.session_segments set ended_at=at_time where id=segment_id;
   if running then select * into strict last_run from ops.session_segments where id=segment_id; end if;
   q:=(ep->>'p_closed_fuel_quantity_ml')::bigint;
   measurement:=ep->>'p_closed_fuel_measurement_type';
   if q is not null then
     if not running or source not in ('well_diesel','farmer_diesel') or q<=0
       or coalesce(measurement,'actual') not in ('actual','estimated') then
       raise exception 'historical_fuel_invalid' using errcode='22023'; end if;
     update ops.session_segments set fuel_measurement_type=coalesce(measurement,'actual'),
       fuel_actual_ml=case when coalesce(measurement,'actual')='actual' then q end,
       fuel_estimated_ml=case when measurement='estimated' then q end where id=segment_id;
   elsif measurement is not null then raise exception 'historical_fuel_invalid' using errcode='22023'; end if;
   seq:=seq+1;
   case e->>'type'
   when 'pause_irrigation_session' then
     reason:=ep->>'p_reason';
     if not running or reason not in ('operator_pause','farmer_requested_pause') then
       raise exception 'historical_pause_invalid' using errcode='22023'; end if;
     insert into ops.session_segments(tenant_id,session_id,sequence_number,segment_type,started_at,is_billable,notes)
       values(o.tenant_id,sid,seq,reason,at_time,false,reason) returning id into segment_id;
     running:=false; pending_source:=false;
   when 'resume_irrigation_session' then
     if running then raise exception 'historical_resume_invalid' using errcode='22023'; end if;
     if pending_source then segment_id:=ops.create_priced_session_segment(sid,source,at_time,owner_id);
     else
       insert into ops.session_segments(tenant_id,session_id,sequence_number,segment_type,energy_source,
         started_at,is_billable,fuel_owner_person_id,applied_price_rule_id,applied_hourly_rate_minor,
         applied_operation_rate_minor,applied_fuel_price_per_liter_minor)
       values(o.tenant_id,sid,seq,last_run.segment_type,last_run.energy_source,at_time,true,
         last_run.fuel_owner_person_id,last_run.applied_price_rule_id,last_run.applied_hourly_rate_minor,
         last_run.applied_operation_rate_minor,last_run.applied_fuel_price_per_liter_minor)
       returning id into segment_id;
     end if;
     running:=true; pending_source:=false;
   when 'change_session_energy_source' then
     if ep->>'p_new_source' is null or ep->>'p_new_source' not in ('solar','well_diesel','farmer_diesel')
       or ep->>'p_new_source'=source then
       raise exception 'historical_energy_invalid' using errcode='22023'; end if;
     source:=ep->>'p_new_source'; owner_id:=(ep->>'p_new_fuel_owner_person_id')::uuid;
     if running then segment_id:=ops.create_priced_session_segment(sid,source,at_time,owner_id);
     else
       if source='farmer_diesel' and owner_id is null then
         select fp.person_id into owner_id from ops.farmer_well_accounts a
          join ops.farmer_profiles fp on fp.id=a.farmer_profile_id where a.id=(s->>'farmer_well_account_id')::uuid;
       end if;
       if source='farmer_diesel' and not exists(select 1 from core.persons where id=owner_id and tenant_id=o.tenant_id) then
         raise exception 'historical_fuel_owner_invalid' using errcode='22023'; end if;
       insert into ops.session_segments(tenant_id,session_id,sequence_number,segment_type,energy_source,
         started_at,is_billable,fuel_owner_person_id,notes)
       values(o.tenant_id,sid,seq,'source_change_pause',source,at_time,false,
         case when source='farmer_diesel' then owner_id end,'source_change_pause') returning id into segment_id;
       pending_source:=true;
     end if;
   else raise exception 'historical_event_type_invalid' using errcode='22023';
   end case;
   perform sync.finish_command(o.tenant_id,(e->>'command_id')::uuid,'accepted',jsonb_build_object('id',segment_id));
   previous_time:=at_time;
 end loop;
 q:=(c->>'fuel_quantity_ml')::bigint;
 measurement:=c->>'fuel_measurement_type';
 if q is not null and (not running or source not in ('well_diesel','farmer_diesel') or q<=0
   or coalesce(measurement,'actual') not in ('actual','estimated')) then
   raise exception 'historical_completion_fuel_invalid' using errcode='22023'; end if;
 if q is null and measurement is not null then
   raise exception 'historical_completion_fuel_invalid' using errcode='22023'; end if;
 update ops.session_segments set ended_at=stop_time,
   fuel_measurement_type=case when q is not null then coalesce(measurement,'actual') else fuel_measurement_type end,
   fuel_actual_ml=case when q is not null and coalesce(measurement,'actual')='actual' then q else fuel_actual_ml end,
   fuel_estimated_ml=case when q is not null and measurement='estimated' then q else fuel_estimated_ml end
 where id=segment_id;
 if exists(select 1 from ops.session_segments where session_id=sid and energy_source='well_diesel'
     and coalesce(fuel_actual_ml,fuel_estimated_ml,0)>0) and nullif(p_facts->>'fuel_tank_id','') is null then
   raise exception 'historical_fuel_tank_required' using errcode='22023'; end if;
 if p_facts ? 'fuel_tank_id' and not exists(select 1 from inventory.fuel_tanks
    where id=(p_facts->>'fuel_tank_id')::uuid and well_id=p_well_id and status='active') then
   raise exception 'historical_fuel_tank_invalid' using errcode='22023'; end if;
 -- لا حقول مبلغ أو سعر تؤخذ من الوقائع؛ محاصيل الأصل تُطبّع بالقواعد القائمة.
 if jsonb_typeof(s->'crops') is distinct from 'array' then
   raise exception 'historical_crops_invalid' using errcode='22023'; end if;
 insert into ops.session_crops(session_id,crop_name,position)
 select sid,name,row_number() over(order by ord) from (
   select btrim(value) name,min(ordinality) ord from jsonb_array_elements_text(s->'crops') with ordinality
   where btrim(value)<>'' group by btrim(value)) q;
 result:=ops.finalize_session_from_closed_segments(sid,stop_time,(p_facts->>'fuel_tank_id')::uuid);
 perform sync.finish_command(o.tenant_id,completion_id,'accepted',result);
 return result;
end;$f$;

create function ops.accept_delay_start_group(
 p_well_id uuid,p_command_id uuid,p_request jsonb,p_mode text default 'group')
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $f$
declare
 tenant uuid; actor uuid:=auth.uid(); rev bigint; pc sync.processed_commands%rowtype;
 session_row ops.irrigation_sessions%rowtype; s jsonb:=p_request->'start'; stored jsonb;
 guard jsonb; result jsonb; start_result jsonb; changes jsonb:='[]'; item jsonb; b record;
 boundary_at timestamptz; proposed_at timestamptz; begun timestamptz; sid uuid;
 kind text; duration_minutes integer; scope_booking uuid;
begin
 if p_well_id is null or p_command_id is null or actor is null or
    not coalesce(iam.has_well_permission(p_well_id,'session.start'),false) then
   raise exception 'group_start_forbidden' using errcode='42501'; end if;
 select tenant_id into tenant from core.wells where id=p_well_id;
 if tenant is null then raise exception 'group_start_forbidden' using errcode='42501'; end if;
 rev:=ops.lock_operational_scope(p_well_id,p_mode='group');
 if p_mode='bind_accepted_start' then
   select * into strict pc from sync.processed_commands where tenant_id=tenant and command_id=p_command_id;
   if pc.status<>'accepted' or pc.command_type not in
      ('start_irrigation_session','start_adhoc_session','start_irrigation_session_from_booking') then
     raise exception 'accepted_start_unproven' using errcode='22023'; end if;
   -- معاني entity_id المختومة تختلف؛ begin_well_command لا يحفظ نطاقًا فيه.
   if pc.command_type='start_irrigation_session' then
     sid:=(pc.response_payload->>'id')::uuid;
     if pc.entity_id is not null or pc.request_payload is not null then
       raise exception 'accepted_start_scope_mismatch' using errcode='22023'; end if;
   elsif pc.command_type='start_adhoc_session' then
     sid:=(pc.response_payload->>'id')::uuid;
     if pc.entity_id is distinct from p_well_id
        or (pc.request_payload->>'well_id')::uuid is distinct from p_well_id then
       raise exception 'accepted_start_scope_mismatch' using errcode='22023'; end if;
   elsif pc.command_type='start_irrigation_session_from_booking' then
     sid:=(pc.response_payload->>'session_id')::uuid;
     if pc.entity_id is null
        or (pc.request_payload->>'booking_id')::uuid is distinct from pc.entity_id
        or (pc.response_payload->>'booking_id')::uuid is distinct from pc.entity_id
        or (pc.response_payload->>'well_id')::uuid is distinct from p_well_id then
       raise exception 'accepted_start_scope_mismatch' using errcode='22023'; end if;
   end if;
   select sess.* into strict session_row
     from ops.irrigation_sessions sess
     join core.wells scope_well on scope_well.id=sess.well_id
     where sess.id=sid and sess.well_id=p_well_id and scope_well.tenant_id=tenant;
   if pc.command_type='start_irrigation_session_from_booking' then
     if session_row.booking_id is distinct from pc.entity_id
        or not exists(select 1 from ops.irrigation_bookings
          where id=pc.entity_id and well_id=p_well_id and tenant_id=tenant) then
       raise exception 'accepted_start_scope_mismatch' using errcode='22023'; end if;
   end if;
   insert into ops.operational_occurrences(tenant_id,occurrence_command_id,well_id,source_booking_id,
     original_request_id,original_operator_id,started_at,original_facts,provenance,server_session_id,status,resolved_at)
   values(tenant,p_command_id,p_well_id,session_row.booking_id,p_command_id,session_row.operator_profile_id,
     session_row.started_at,jsonb_build_object('request',pc.request_payload,'result',pc.response_payload),
     'accepted_start',sid,'accepted',clock_timestamp()) on conflict(tenant_id,occurrence_command_id) do nothing;
   if not exists(select 1 from ops.operational_occurrences where tenant_id=tenant
      and occurrence_command_id=p_command_id and well_id=p_well_id and server_session_id=sid) then
     raise exception 'occurrence_binding_conflict' using errcode='23514'; end if;
   return pc.response_payload;
 elsif p_mode is distinct from 'group' then raise exception 'group_mode_invalid' using errcode='22023'; end if;
 if not coalesce(iam.has_well_permission(p_well_id,'booking.reschedule'),false) then
   raise exception 'group_reschedule_forbidden' using errcode='42501'; end if;
 if jsonb_typeof(p_request) is distinct from 'object' or p_request->'version' is distinct from '1'::jsonb
   or p_request->>'occurrence_command_id' is distinct from p_command_id::text
   or nullif(p_request->>'root_local_id','') is null or jsonb_typeof(s) is distinct from 'object'
   or jsonb_typeof(p_request->'delays') is distinct from 'array'
   or jsonb_typeof(s->'crops') is distinct from 'array'
   or nullif(s->>'started_at','') is null or nullif(s->>'pump_id','') is null
   or nullif(s->>'farm_id','') is null or nullif(s->>'farmer_well_account_id','') is null
   or s->>'energy_source' is null or s->>'energy_source' not in ('solar','well_diesel','farmer_diesel')
   or nullif(btrim(p_request->>'reason'),'') is null then
   raise exception 'group_request_invalid' using errcode='22023'; end if;
 stored:=jsonb_build_object('request',p_request,'actor_id',actor);
 guard:=sync.begin_command(tenant,p_command_id,'start_session_with_booking_delays',stored,p_well_id);
 if coalesce((guard->>'duplicate')::boolean,false) then
   select * into strict pc from sync.processed_commands where tenant_id=tenant and command_id=p_command_id;
   if pc.command_type<>'start_session_with_booking_delays' or pc.entity_id<>p_well_id
     or pc.request_payload is distinct from stored then
     raise exception 'command_identity_mismatch' using errcode='22023'; end if;
   if pc.status in ('accepted','rejected','conflict') then return pc.response_payload; end if;
   raise exception 'group_processing' using errcode='55000';
 end if;
 -- الجزء الداخلي وحده يُلغى عند رفض أعمال؛ المطالبة والرفض النهائي يبقيان محفوظين.
 begin
   if (p_request->>'expected_revision')::bigint is distinct from rev then
     raise exception 'stale_operational_schedule' using errcode='P0001'; end if;
   begun:=(s->>'started_at')::timestamptz;
   if begun is null or not isfinite(begun) or begun>clock_timestamp()
      or (p_request->>'requested_at')::timestamptz is null
      or not isfinite((p_request->>'requested_at')::timestamptz)
      or (p_request->>'requested_at')::timestamptz>clock_timestamp() then
     raise exception 'group_time_invalid' using errcode='22023'; end if;
   scope_booking:=(s->>'booking_id')::uuid;
   duration_minutes:=(s->>'planned_duration_minutes')::integer;
   if scope_booking is not null then
     select expected_duration_minutes into duration_minutes from ops.irrigation_bookings
      where id=scope_booking and well_id=p_well_id and tenant_id=tenant and status='confirmed';
     if not found then raise exception 'group_booking_invalid' using errcode='22023'; end if;
   end if;
   if duration_minutes is null or duration_minutes<=0 then
     raise exception 'group_duration_required' using errcode='22023'; end if;
   boundary_at:=begun+make_interval(mins=>duration_minutes);
   for b in select x.* from ops.irrigation_bookings x where x.well_id=p_well_id and x.status='confirmed'
      and x.id is distinct from scope_booking and x.scheduled_end>begun
      and not exists(select 1 from ops.irrigation_sessions z where z.booking_id=x.id)
      order by x.scheduled_start,x.id for update nowait loop
     if b.scheduled_start<begun then raise exception 'group_missed_booking_requires_review' using errcode='P0001'; end if;
     proposed_at:=greatest(b.scheduled_start,boundary_at);
     if proposed_at<>b.scheduled_start then
       changes:=changes||jsonb_build_array(jsonb_build_object('booking_id',b.id,
         'original_start',b.scheduled_start,'original_end',b.scheduled_end,
         'scheduled_start',proposed_at,'scheduled_end',proposed_at+(b.scheduled_end-b.scheduled_start)));
     end if;
     boundary_at:=proposed_at+(b.scheduled_end-b.scheduled_start);
   end loop;
   if p_request->'delays' is distinct from changes then
     raise exception 'group_preview_mismatch' using errcode='P0001'; end if;
   for item in select value from jsonb_array_elements(changes) with ordinality order by ordinality desc loop
     result:=ops.reschedule_booking((item->>'booking_id')::uuid,(item->>'scheduled_start')::timestamptz,
       (item->>'scheduled_end')::timestamptz,p_request->>'reason',null);
     if result->>'status'<>'confirmed' then raise exception 'group_delay_rejected' using errcode='P0001'; end if;
   end loop;
   if scope_booking is not null then
     start_result:=ops.start_irrigation_session_from_booking(scope_booking,actor,begun,
       array(select jsonb_array_elements_text(s->'crops')));
     sid:=(start_result->>'session_id')::uuid;
   else
     sid:=ops.start_adhoc_session(p_well_id,(s->>'pump_id')::uuid,(s->>'farm_id')::uuid,
       (s->>'farmer_well_account_id')::uuid,s->>'energy_source',duration_minutes,begun,
       (s->>'fuel_owner_person_id')::uuid,array(select jsonb_array_elements_text(s->'crops')));
     start_result:=jsonb_build_object('session_id',sid,'started_at',begun);
   end if;
   insert into ops.operational_occurrences(tenant_id,occurrence_command_id,well_id,source_booking_id,
     original_request_id,original_operator_id,started_at,original_facts,provenance,server_session_id,status,resolved_at)
   values(tenant,p_command_id,p_well_id,scope_booking,p_command_id,actor,begun,p_request,
     'delay_start_group',sid,'accepted',clock_timestamp());
   set constraints ops.irrigation_sessions_adhoc_duration_guard immediate;
   set constraints ops.irrigation_sessions_adhoc_duration_guard deferred;
   select operational_schedule_revision into rev from core.wells where id=p_well_id;
   result:=jsonb_build_object('contract','delay_start_group','version',1,'status','accepted',
     'group_request_id',p_command_id,'occurrence_command_id',p_command_id,'start_command_id',p_command_id,
     'well_id',p_well_id,'requested_at',p_request->'requested_at','started_at',begun,
     'request_fingerprint',md5(p_request::text),'accepted_revision',rev,'schedule_changes',changes,
     'server_session_id',sid,'start_result',start_result,'resolved_at',clock_timestamp());
 exception when check_violation or exclusion_violation or unique_violation or raise_exception
   or invalid_parameter_value or invalid_text_representation or invalid_datetime_format or datetime_field_overflow then
   if SQLSTATE='P0001' and SQLERRM !~ '^(group_|stale_operational_|لا |الحجز |الجلسة |المضخة |المزرعة |حساب |بدء |المدة |وقت |يوجد |رصيد )' then
     raise;
   end if;
   result:=jsonb_build_object('contract','delay_start_group','version',1,'status','rejected',
     'group_request_id',p_command_id,'occurrence_command_id',p_command_id,'well_id',p_well_id,
     'request_fingerprint',md5(p_request::text),'reason',SQLERRM,'resolved_at',clock_timestamp());
 end;
 perform sync.finish_command(tenant,p_command_id,result->>'status',result);
 return result;
end;$f$;

create function ops.settle_operational_occurrence(p_well_id uuid,p_command_id uuid,p_request jsonb)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $f$
declare
 tenant uuid; actor uuid:=auth.uid(); original sync.processed_commands%rowtype; pc sync.processed_commands%rowtype;
 o ops.operational_occurrences%rowtype; guard jsonb; stored jsonb; result jsonb; completed jsonb;
 occurrence_id uuid; original_id uuid; sid uuid; facts jsonb:=p_request->'facts'; start_fact jsonb;
 stop_at timestamptz; source_booking uuid; existing boolean;
begin
 if actor is null or p_well_id is null or p_command_id is null or
    not coalesce(iam.has_well_permission(p_well_id,'session.start'),false) or
    not coalesce(iam.has_well_permission(p_well_id,'session.complete'),false) then
   raise exception 'settlement_forbidden' using errcode='42501'; end if;
 select tenant_id into tenant from core.wells where id=p_well_id;
 if tenant is null then raise exception 'settlement_forbidden' using errcode='42501'; end if;
 perform ops.lock_operational_scope(p_well_id,true);
 if jsonb_typeof(p_request) is distinct from 'object' or p_request->'version' is distinct from '1'::jsonb
    or p_request->'human_confirmed' is distinct from 'true'::jsonb
    or nullif(btrim(p_request->>'reason'),'') is null then
   raise exception 'settlement_confirmation_required' using errcode='22023'; end if;
 occurrence_id:=(p_request->>'occurrence_command_id')::uuid;
 original_id:=(p_request->>'original_rejected_request_id')::uuid;
 if occurrence_id is null or original_id is null or p_command_id in (occurrence_id,original_id)
    or nullif(facts->'completion'->>'command_id','') is null
    or p_command_id=(facts->'completion'->>'command_id')::uuid then
   raise exception 'settlement_identity_invalid' using errcode='22023'; end if;
 select * into original from sync.processed_commands where tenant_id=tenant and command_id=original_id;
 if not found or original.entity_id is distinct from p_well_id
    or original.command_type<>'start_session_with_booking_delays'
    or original.status<>'rejected' or original.response_payload is null
    or original.request_payload->'request'->>'occurrence_command_id' is distinct from occurrence_id::text
    or original.response_payload is distinct from p_request->'original_rejected_result'
    or md5((original.request_payload->'request')::text) is distinct from p_request->>'original_request_fingerprint' then
   raise exception 'original_rejection_unproven' using errcode='22023'; end if;
 start_fact:=original.request_payload->'request'->'start';
 if jsonb_typeof(facts) is distinct from 'object' or facts->'start' is distinct from start_fact
    or facts->>'root_local_id' is distinct from original.request_payload->'request'->>'root_local_id'
    or (p_request->>'source_booking_id')::uuid is distinct from (start_fact->>'booking_id')::uuid then
   raise exception 'settlement_original_facts_mismatch' using errcode='22023'; end if;
 stored:=jsonb_build_object('request',p_request,'actor_id',actor);
 guard:=sync.begin_command(tenant,p_command_id,'settle_operational_occurrence',stored,p_well_id);
 if coalesce((guard->>'duplicate')::boolean,false) then
   select * into strict pc from sync.processed_commands where tenant_id=tenant and command_id=p_command_id;
   if pc.command_type<>'settle_operational_occurrence' or pc.entity_id<>p_well_id or pc.request_payload is distinct from stored then
     raise exception 'command_identity_mismatch' using errcode='22023'; end if;
   if pc.status in ('accepted','conflict','rejected') then return pc.response_payload; end if;
   raise exception 'settlement_processing' using errcode='55000';
 end if;
 begin
   select * into o from ops.operational_occurrences where tenant_id=tenant and occurrence_command_id=occurrence_id for update;
   existing:=found;
   if existing then
     if o.well_id<>p_well_id or o.original_request_id<>original_id or o.original_facts is distinct from facts
       or o.status<>'accepted' or o.provenance<>'historical_settlement' then
       raise exception 'occurrence_binding_conflict' using errcode='23514'; end if;
     sid:=o.server_session_id;
     select response_payload into completed from sync.processed_commands
       where tenant_id=tenant and command_id=o.completion_command_id and status='accepted'
         and command_type='complete_irrigation_session' and entity_id=sid;
     if completed is null then raise exception 'completion_result_unproven' using errcode='23514'; end if;
   else
     -- لا تبنٍّ لجلسة سابقة بلا رابط واقعة؛ حتى تطابق الحجز ليس إثباتًا كافيًا.
     source_booking:=(start_fact->>'booking_id')::uuid;
     if source_booking is not null and (not exists(select 1 from ops.irrigation_bookings b
         where b.id=source_booking and b.well_id=p_well_id and b.tenant_id=tenant)
       or exists(select 1 from ops.irrigation_sessions s where s.booking_id=source_booking)) then
       raise exception 'existing_session_requires_exact_occurrence_proof' using errcode='23514'; end if;
     sid:=gen_random_uuid(); stop_at:=(facts->'completion'->>'occurred_at')::timestamptz;
     insert into ops.operational_occurrences(tenant_id,occurrence_command_id,well_id,source_booking_id,
       original_request_id,original_operator_id,started_at,ended_at,original_facts,provenance,
       settlement_command_id,completion_command_id,server_session_id,status)
     values(tenant,occurrence_id,p_well_id,source_booking,original_id,
       (original.request_payload->>'actor_id')::uuid,(start_fact->>'started_at')::timestamptz,stop_at,facts,
       'historical_settlement',p_command_id,(facts->'completion'->>'command_id')::uuid,sid,'materializing');
     completed:=ops.materialize_historical_occurrence(p_well_id,occurrence_id,p_command_id,facts);
     update ops.operational_occurrences set status='accepted',resolved_at=clock_timestamp()
       where tenant_id=tenant and occurrence_command_id=occurrence_id;
   end if;
   result:=jsonb_build_object('contract','occurrence_settlement','version',1,'status','accepted',
     'settlement_request_id',p_command_id,'occurrence_command_id',occurrence_id,
     'original_rejected_request_id',original_id,'original_rejected_result',original.response_payload,
     'well_id',p_well_id,'source_booking_id',start_fact->'booking_id',
     'request_fingerprint',md5(p_request::text),'server_session_id',sid,
     'started_at',start_fact->'started_at','ended_at',completed->'ended_at',
     'original_completion_command_id',facts->'completion'->'command_id',
     'session_charge_id',completed->'session_charge_id','completion_receipt',completed,'resolved_at',clock_timestamp());
   perform sync.finish_command(tenant,p_command_id,'accepted',result);
   -- التحقق المؤجل يرى الآن دليل التسوية المقبول في المعاملة نفسها.
   set constraints ops.irrigation_sessions_adhoc_duration_guard immediate;
   set constraints ops.irrigation_sessions_adhoc_duration_guard deferred;
 exception when check_violation or exclusion_violation or unique_violation or raise_exception
   or invalid_parameter_value or invalid_text_representation or invalid_datetime_format or datetime_field_overflow then
   if SQLSTATE='P0001' and SQLERRM !~ '^(group_|stale_operational_|لا |الحجز |الجلسة |المضخة |المزرعة |حساب |بدء |المدة |وقت |يوجد |رصيد )' then
     raise;
   end if;
   result:=jsonb_build_object('contract','occurrence_settlement','version',1,'status','review',
     'settlement_request_id',p_command_id,'occurrence_command_id',occurrence_id,'well_id',p_well_id,
     'original_rejected_request_id',original_id,'original_rejected_result',original.response_payload,
     'request_fingerprint',md5(p_request::text),'reason',SQLERRM,'resolved_at',clock_timestamp());
   perform sync.finish_command(tenant,p_command_id,'conflict',result);
 end;
 return result;
end;$f$;

create function sync.get_delay_start_group_receipt_read(p_well_id uuid,p_command_id uuid,p_original_request jsonb)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,pg_temp as $f$
declare tenant uuid; c sync.processed_commands%rowtype; r jsonb;
begin
 if auth.uid() is null or not coalesce(iam.has_well_permission(p_well_id,'session.start'),false) then
   raise exception 'occurrence_receipt_forbidden' using errcode='42501'; end if;
 if p_well_id is null or p_command_id is null or jsonb_typeof(p_original_request) is distinct from 'object' then
   raise exception 'occurrence_receipt_inputs_invalid' using errcode='22023'; end if;
 select tenant_id into tenant from core.wells where id=p_well_id;
 r:=jsonb_build_object('contract','get_delay_start_group_receipt','version',1,'well_id',p_well_id,
   'group_request_id',p_command_id,'status','unresolved','receipt',null,'retry_authorized',false);
 select * into c from sync.processed_commands where tenant_id=tenant and command_id=p_command_id;
 if not found then return r||jsonb_build_object('status','not_found'); end if;
 if c.entity_id is distinct from p_well_id or c.command_type<>'start_session_with_booking_delays'
    or c.request_payload->'request' is distinct from p_original_request then return r; end if;
 if c.status='processing' and c.response_payload is null then
   return r||jsonb_build_object('status','processing'); end if;
 if c.response_payload is null or c.response_payload->>'request_fingerprint' is distinct from md5(p_original_request::text)
   or c.response_payload->>'group_request_id' is distinct from p_command_id::text then return r; end if;
 if c.status='accepted' and c.response_payload->>'status'='accepted' then
   return r||jsonb_build_object('status','accepted','receipt',c.response_payload);
 elsif c.status='rejected' and c.response_payload->>'status'='rejected' then
   return r||jsonb_build_object('status','rejected','receipt',c.response_payload);
 elsif c.status='conflict' and c.response_payload->>'status'='review' then
   return r||jsonb_build_object('status','review','receipt',c.response_payload);
 end if;
 return r;
end;$f$;

create function sync.get_occurrence_settlement_receipt_read(p_well_id uuid,p_command_id uuid,p_original_request jsonb)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,pg_temp as $f$
declare tenant uuid; c sync.processed_commands%rowtype; r jsonb;
begin
 if auth.uid() is null or not coalesce(iam.has_well_permission(p_well_id,'session.complete'),false) then
   raise exception 'occurrence_receipt_forbidden' using errcode='42501'; end if;
 if p_well_id is null or p_command_id is null or jsonb_typeof(p_original_request) is distinct from 'object' then
   raise exception 'occurrence_receipt_inputs_invalid' using errcode='22023'; end if;
 select tenant_id into tenant from core.wells where id=p_well_id;
 r:=jsonb_build_object('contract','get_occurrence_settlement_receipt','version',1,'well_id',p_well_id,
   'settlement_request_id',p_command_id,'status','unresolved','receipt',null,'retry_authorized',false);
 select * into c from sync.processed_commands where tenant_id=tenant and command_id=p_command_id;
 if not found then return r||jsonb_build_object('status','not_found'); end if;
 if c.entity_id is distinct from p_well_id or c.command_type<>'settle_operational_occurrence'
    or c.request_payload->'request' is distinct from p_original_request then return r; end if;
 if c.status='processing' and c.response_payload is null then
   return r||jsonb_build_object('status','processing'); end if;
 if c.response_payload is null or c.response_payload->>'request_fingerprint' is distinct from md5(p_original_request::text)
   or c.response_payload->>'settlement_request_id' is distinct from p_command_id::text then return r; end if;
 if c.status='accepted' and c.response_payload->>'status'='accepted' then
   return r||jsonb_build_object('status','accepted','receipt',c.response_payload);
 elsif c.status='rejected' and c.response_payload->>'status'='rejected' then
   return r||jsonb_build_object('status','rejected','receipt',c.response_payload);
 elsif c.status='conflict' and c.response_payload->>'status'='review' then
   return r||jsonb_build_object('status','review','receipt',c.response_payload);
 end if;
 return r;
end;$f$;

create function api.start_session_with_booking_delays(p_well_id uuid,p_command_id uuid,p_request jsonb)
returns jsonb language sql volatile security invoker set search_path=pg_catalog,pg_temp as $f$
 select ops.accept_delay_start_group(p_well_id,p_command_id,p_request);
$f$;

create function api.settle_operational_occurrence(p_well_id uuid,p_command_id uuid,p_request jsonb)
returns jsonb language sql volatile security invoker set search_path=pg_catalog,pg_temp as $f$
 select ops.settle_operational_occurrence(p_well_id,p_command_id,p_request);
$f$;

create function api.get_delay_start_group_receipt(p_well_id uuid,p_command_id uuid,p_original_request jsonb)
returns jsonb language sql stable security invoker set search_path=pg_catalog,pg_temp as $f$
 select sync.get_delay_start_group_receipt_read(p_well_id,p_command_id,p_original_request);
$f$;

create function api.get_occurrence_settlement_receipt(p_well_id uuid,p_command_id uuid,p_original_request jsonb)
returns jsonb language sql stable security invoker set search_path=pg_catalog,pg_temp as $f$
 select sync.get_occurrence_settlement_receipt_read(p_well_id,p_command_id,p_original_request);
$f$;

-- التوافق: NULL لا ينشئ واقعة؛ replay التاريخي يبقى كما هو.
create or replace function api.start_irrigation_session(
  p_well_id uuid,
  p_pump_id uuid,
  p_farm_id uuid,
  p_farmer_well_account_id uuid,
  p_energy_source text,
  p_started_at timestamptz default clock_timestamp(),
  p_fuel_owner_person_id uuid default null,
  p_command_id uuid default null,
  p_crops text[] default null
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
    p_fuel_owner_person_id,
    p_crops
  );

  if p_command_id is not null then
    perform sync.finish_well_command(
      p_well_id,
      p_command_id,
      'accepted',
      jsonb_build_object('id', v_session_id)
    );
  end if;

  if p_command_id is not null then
    perform ops.accept_delay_start_group(p_well_id,p_command_id,'{}'::jsonb,'bind_accepted_start');
  end if;
  return v_session_id;
end;
$function$;

-- التوافق: NULL لا ينشئ واقعة؛ replay التاريخي يبقى كما هو.
create or replace function api.start_adhoc_session(
  p_well_id uuid,
  p_pump_id uuid,
  p_farm_id uuid,
  p_farmer_well_account_id uuid,
  p_energy_source text,
  p_planned_duration_minutes integer,
  p_started_at timestamptz default clock_timestamp(),
  p_fuel_owner_person_id uuid default null,
  p_command_id uuid default null,
  p_crops text[] default null
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
    v_guard := sync.begin_adhoc_session_command(
      p_well_id, p_pump_id, p_farm_id, p_farmer_well_account_id,
      p_energy_source, p_planned_duration_minutes, p_started_at,
      p_command_id, p_crops, p_fuel_owner_person_id
    );
    if coalesce((v_guard ->> 'duplicate')::boolean, false) then
      if v_guard ->> 'status' = 'accepted' then
        return (v_guard -> 'response' ->> 'id')::uuid;
      end if;
      raise exception 'العملية نفسها قيد المعالجة أو تحتاج مراجعة';
    end if;
  end if;

  v_session_id := ops.start_adhoc_session(
    p_well_id, p_pump_id, p_farm_id, p_farmer_well_account_id,
    p_energy_source, p_planned_duration_minutes, p_started_at,
    p_fuel_owner_person_id, p_crops
  );

  if p_command_id is not null then
    perform sync.finish_well_command(
      p_well_id, p_command_id, 'accepted',
      jsonb_build_object('id', v_session_id)
    );
  end if;

  if p_command_id is not null then
    perform ops.accept_delay_start_group(p_well_id,p_command_id,'{}'::jsonb,'bind_accepted_start');
  end if;
  return v_session_id;
end;
$function$;

-- التوافق: NULL لا ينشئ واقعة؛ replay التاريخي يبقى كما هو.
create or replace function api.start_irrigation_session_from_booking(
  p_booking_id uuid,
  p_started_at timestamptz,
  p_command_id uuid,
  p_crops text[] default null
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
  v_well_id uuid;
begin
  v_guard := sync.begin_booking_session_command(
    p_booking_id,
    p_command_id,
    p_started_at,
    p_crops
  );

  v_well_id := (v_guard ->> 'well_id')::uuid;

  if coalesce((v_guard ->> 'duplicate')::boolean, false) then
    if v_guard ->> 'status' = 'accepted' then
      return v_guard -> 'response';
    end if;
    raise exception 'العملية نفسها قيد المعالجة أو تحتاج مراجعة';
  end if;

  v_result := ops.start_irrigation_session_from_booking(
    p_booking_id,
    auth.uid(),
    p_started_at,
    p_crops
  );

  perform sync.finish_well_command(
    v_well_id,
    p_command_id,
    'accepted',
    v_result
  );

  if p_command_id is not null then
    perform ops.accept_delay_start_group((v_result->>'well_id')::uuid,p_command_id,'{}'::jsonb,'bind_accepted_start');
  end if;
  return v_result;
end;
$function$;
revoke all on function ops.lock_operational_scope(uuid,boolean) from public,anon,authenticated,service_role;
revoke all on function ops.guard_operational_schedule_write() from public,anon,authenticated,service_role;
revoke all on function ops.finalize_session_from_closed_segments(uuid,timestamptz,uuid) from public,anon,authenticated,service_role;
revoke all on function ops.materialize_historical_occurrence(uuid,uuid,uuid,jsonb) from public,anon,authenticated,service_role;
revoke all on function ops.accept_delay_start_group(uuid,uuid,jsonb,text) from public,anon,authenticated,service_role;
grant execute on function ops.accept_delay_start_group(uuid,uuid,jsonb,text) to authenticated,service_role;
revoke all on function ops.settle_operational_occurrence(uuid,uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function ops.settle_operational_occurrence(uuid,uuid,jsonb) to authenticated,service_role;
revoke all on function sync.get_delay_start_group_receipt_read(uuid,uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function sync.get_delay_start_group_receipt_read(uuid,uuid,jsonb) to authenticated,service_role;
revoke all on function sync.get_occurrence_settlement_receipt_read(uuid,uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function sync.get_occurrence_settlement_receipt_read(uuid,uuid,jsonb) to authenticated,service_role;
revoke all on function api.start_session_with_booking_delays(uuid,uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function api.start_session_with_booking_delays(uuid,uuid,jsonb) to authenticated,service_role;
revoke all on function api.settle_operational_occurrence(uuid,uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function api.settle_operational_occurrence(uuid,uuid,jsonb) to authenticated,service_role;
revoke all on function api.get_delay_start_group_receipt(uuid,uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function api.get_delay_start_group_receipt(uuid,uuid,jsonb) to authenticated,service_role;
revoke all on function api.get_occurrence_settlement_receipt(uuid,uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function api.get_occurrence_settlement_receipt(uuid,uuid,jsonb) to authenticated,service_role;

-- حفظ إسناد الوقود التاريخي دون استعارة مناوبة الحاضر.
create or replace function inventory.fill_fuel_transaction()
returns trigger
language plpgsql
security definer
set search_path to 'inventory', 'core', 'ops', 'pg_temp'
as $$
declare
  v_liters numeric;
begin
  if new.tenant_id is null then
    select tenant_id into new.tenant_id from core.wells where id = new.well_id;
  end if;

  if new.fuel_tank_id is null then
    select id into new.fuel_tank_id from inventory.fuel_tanks
    where well_id = new.well_id and status = 'active'
    order by created_at limit 1;
  end if;

  if new.shift_id is null and not exists(select 1 from ops.session_segments ss
      join ops.operational_occurrences o on o.server_session_id=ss.session_id
      where ss.id=new.session_segment_id and o.provenance='historical_settlement') then
    select s.id into new.shift_id from ops.shifts s
    where s.well_id = new.well_id and s.status = 'open' limit 1;
  end if;

  -- القياس التقديري يبقى بانتظار قياس فعلي (doc 02 §26.2)
  if new.measurement_type = 'estimated' and new.status = 'posted' then
    new.status := 'pending_actual_measurement';
  end if;

  v_liters := new.quantity_ml::numeric / 1000;

  if new.direction = 'in' then
    if new.unit_cost_per_liter_minor is not null and new.total_cost_minor is null then
      new.total_cost_minor := round(v_liters * new.unit_cost_per_liter_minor);
    elsif new.total_cost_minor is not null and new.unit_cost_per_liter_minor is null and v_liters > 0 then
      new.unit_cost_per_liter_minor := round(new.total_cost_minor / v_liters);
    end if;
  else
    if new.ownership_type = 'well' and new.unit_cost_per_liter_minor is null then
      select avg_cost_per_liter_minor into new.unit_cost_per_liter_minor
      from inventory.fuel_tanks where id = new.fuel_tank_id;
    end if;
    if new.total_cost_minor is null and new.unit_cost_per_liter_minor is not null then
      new.total_cost_minor := round(v_liters * new.unit_cost_per_liter_minor);
    end if;
  end if;

  return new;
end;
$$;
commit;
