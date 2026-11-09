begin;
-- Private provenance foundation. No manual-entry public API is activated.
-- Existing occurrence identity remains authoritative; no parallel session map.
alter table ops.operational_occurrences
 add column manual_reason text,
 add column manual_notes text,
 add column manual_result jsonb;
alter table ops.operational_occurrences drop constraint operational_occurrences_provenance_check;
alter table ops.operational_occurrences add constraint operational_occurrences_provenance_check
 check(provenance in ('accepted_start','delay_start_group','historical_settlement',
  'manual_historical_completed','manual_external_active'));
alter table ops.operational_occurrences add constraint manual_session_entry_shape check (
 case when provenance in ('manual_historical_completed','manual_external_active') then
  source_booking_id is null and settlement_command_id is null and completion_command_id is null
  and original_request_id=occurrence_command_id and server_session_id is not null
  and nullif(btrim(manual_reason),'') is not null and jsonb_typeof(original_facts)='object'
  and jsonb_typeof(original_facts->'start')='object'
  and (original_facts-array['start','fuel_tank_id','fuel_quantity_ml','fuel_measurement_type'])='{}'::jsonb
  and ((original_facts->'start')-array['pump_id','farm_id','farmer_well_account_id','energy_source','fuel_owner_person_id','crops'])='{}'::jsonb
  and jsonb_typeof(original_facts->'start'->'pump_id')='string'
  and jsonb_typeof(original_facts->'start'->'farm_id')='string'
  and jsonb_typeof(original_facts->'start'->'farmer_well_account_id')='string'
  and original_facts->'start'->>'energy_source' in ('solar','well_diesel','farmer_diesel')
  and isfinite(started_at) and started_at<=created_at
  and ((provenance='manual_historical_completed' and ended_at is not null and isfinite(ended_at) and ended_at<=created_at)
    or (provenance='manual_external_active' and ended_at is null))
  and ((status='materializing' and manual_result is null and resolved_at is null)
    or (status='accepted' and jsonb_typeof(manual_result)='object'))
 else manual_reason is null and manual_notes is null and manual_result is null end is true);

-- Composite form also validates BEFORE INSERT NEW, before the row is visible.
-- SQL role clients cannot reserve commands or write occurrences themselves.
create function ops.manual_session_occurrence_mode(o ops.operational_occurrences)
returns text language sql stable security definer set search_path=pg_catalog,pg_temp as $proof$
 select (o).provenance from sync.processed_commands c
 where (o).provenance in ('manual_historical_completed','manual_external_active')
  and (o).source_booking_id is null and (o).original_request_id=(o).occurrence_command_id
  and c.tenant_id=(o).tenant_id and c.command_id=(o).occurrence_command_id
  and c.entity_id=(o).well_id and c.command_type='manual_session_entry'
  and c.request_payload=jsonb_build_object('contract','manual_session_entry','version',1,
   'tenant_id',(o).tenant_id,'well_id',(o).well_id,'actor_id',(o).original_operator_id,
   'entry_type',(o).provenance,'reason',(o).manual_reason,'notes',(o).manual_notes,
   'started_at',to_char((o).started_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
   'ended_at',case when (o).ended_at is not null then to_char((o).ended_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') end,
   'facts',(o).original_facts)
  and (((o).status='materializing' and c.status='processing' and c.response_payload is null and (o).manual_result is null)
   or ((o).status='accepted' and c.status='accepted' and (o).manual_result=c.response_payload
     and (o).manual_result->>'status'='accepted'
     and (o).manual_result->>'session_id'=(o).server_session_id::text
     and (o).manual_result->>'command_id'=(o).occurrence_command_id::text
     and (o).manual_result->>'well_id'=(o).well_id::text
     and (o).manual_result->>'entry_type'=(o).provenance));
$proof$;
create function ops.manual_session_entry_mode(p_session_id uuid)
returns text language plpgsql stable security definer set search_path=pg_catalog,pg_temp as $proof$
declare o ops.operational_occurrences%rowtype;mode text;
begin
 select * into o from ops.operational_occurrences where server_session_id=p_session_id;
 if not found or o.provenance not in ('manual_historical_completed','manual_external_active') then return null;end if;
 mode:=ops.manual_session_occurrence_mode(o);
 if mode is null then raise exception 'manual_entry_trusted_proof_required' using errcode='23514';end if;
 return mode;
end;$proof$;

-- Construct the immutable acceptance snapshot from canonical rows, never from a
-- client result. Only the future trusted wrapper will call this private helper.
create function ops.manual_session_entry_result(p_session_id uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,pg_temp as $result$
declare o ops.operational_occurrences%rowtype;s ops.irrigation_sessions%rowtype;ch billing.session_charges%rowtype;
begin
 select * into strict o from ops.operational_occurrences where server_session_id=p_session_id;
 select * into strict s from ops.irrigation_sessions where id=p_session_id;
 if o.provenance not in ('manual_historical_completed','manual_external_active') or o.status<>'materializing'
  or s.well_id<>o.well_id or s.operator_profile_id<>o.original_operator_id
  or s.started_at is distinct from o.started_at or s.ended_at is distinct from o.ended_at
  or s.booking_id is not null or s.current_shift_id is not null or s.collector_profile_id is not null
  or s.pump_id::text is distinct from o.original_facts->'start'->>'pump_id'
  or s.farm_id::text is distinct from o.original_facts->'start'->>'farm_id'
  or s.farmer_well_account_id::text is distinct from o.original_facts->'start'->>'farmer_well_account_id'
  or (o.provenance='manual_external_active' and s.status<>'open')
  or (o.provenance='manual_historical_completed' and s.status<>'closed') then
  raise exception 'manual_entry_canonical_binding_required' using errcode='23514';end if;
 if (select count(*) from ops.session_segments where session_id=p_session_id)<>1
  or not exists(select 1 from ops.session_segments seg where seg.session_id=p_session_id
   and seg.tenant_id=o.tenant_id and seg.sequence_number=1 and seg.started_at=o.started_at
   and seg.ended_at is not distinct from o.ended_at
   and seg.energy_source=o.original_facts->'start'->>'energy_source'
   and (not seg.is_billable or coalesce(seg.applied_operation_rate_minor,seg.applied_hourly_rate_minor,0)>0)) then
  raise exception 'manual_entry_initial_segment_required' using errcode='23514';end if;
 if o.provenance='manual_historical_completed' then
  select * into strict ch from billing.session_charges where session_id=p_session_id;
 elsif exists(select 1 from billing.session_charges where session_id=p_session_id) then
  raise exception 'manual_entry_unexpected_charge' using errcode='23514';
 end if;
 return jsonb_build_object('contract','manual_session_entry','version',1,'status','accepted',
  'entry_type',o.provenance,'tenant_id',o.tenant_id,'well_id',o.well_id,
  'command_id',o.occurrence_command_id,'session_id',s.id,
  'started_at',to_char(s.started_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
  'ended_at',case when s.ended_at is not null then to_char(s.ended_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') end,
  'session_charge_id',ch.id,'amount_minor',ch.amount_minor);
end;$result$;


create or replace function ops.guard_operational_schedule_write() returns trigger
language plpgsql security definer set search_path=pg_catalog,pg_temp as $f$
declare w uuid; o ops.operational_occurrences%rowtype; historical boolean := false; changed boolean; manual_mode text;
begin
 if TG_TABLE_NAME='operational_occurrences' then
   if TG_OP='DELETE' then raise exception 'occurrence_delete_disabled' using errcode='23514'; end if;
   if new.provenance in ('manual_historical_completed','manual_external_active') then
     if TG_OP='INSERT' then
       if auth.uid() is null or new.original_operator_id is distinct from auth.uid()
        or not coalesce(iam.has_well_permission(new.well_id,'session.start'),false)
        or (new.provenance='manual_historical_completed' and
          not coalesce(iam.has_well_permission(new.well_id,'session.complete'),false))
        or new.status<>'materializing' then
        raise exception 'manual_entry_admission_forbidden' using errcode='42501';end if;
       new.created_at:=clock_timestamp();
     else
       if (to_jsonb(new)-array['status','resolved_at','manual_result']) is distinct from
          (to_jsonb(old)-array['status','resolved_at','manual_result'])
        or (old.status='accepted' and to_jsonb(new) is distinct from to_jsonb(old)) then
        raise exception 'occurrence_identity_immutable' using errcode='23514';end if;
       if old.status='materializing' and new.status='accepted' then
        -- The constructor reads the still-materializing OLD row. Reservation is
        -- accepted already, so use the canonical snapshot built before finish.
        if new.manual_result is distinct from ops.manual_session_entry_result(new.server_session_id) then
         raise exception 'manual_entry_result_binding_required' using errcode='23514';end if;
        new.resolved_at:=clock_timestamp();
       end if;
     end if;
     if ops.manual_session_occurrence_mode(new) is null then
      raise exception 'manual_entry_trusted_proof_required' using errcode='23514';end if;
     if not exists(select 1 from core.wells x where x.id=new.well_id and x.tenant_id=new.tenant_id) then
      raise exception 'occurrence_scope_mismatch' using errcode='23514';end if;
     return new;
   end if;
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
   manual_mode:=ops.manual_session_entry_mode(new.id);
   if manual_mode is not null then
     select * into strict o from ops.operational_occurrences where server_session_id=new.id;
     if new.well_id<>o.well_id or new.operator_profile_id<>o.original_operator_id
       or new.started_at is distinct from o.started_at or new.booking_id is not null
       or new.pump_id::text is distinct from o.original_facts->'start'->>'pump_id'
       or new.farm_id::text is distinct from o.original_facts->'start'->>'farm_id'
       or new.farmer_well_account_id::text is distinct from o.original_facts->'start'->>'farmer_well_account_id'
       or (manual_mode='manual_historical_completed' and
          (new.status not in ('closed','forgotten') or new.ended_at is distinct from o.ended_at))
       or (TG_OP='INSERT' and manual_mode='manual_external_active' and (new.status<>'open' or new.ended_at is not null)) then
       raise exception 'manual_entry_session_binding_required' using errcode='23514';end if;
   end if;
   -- Correction revisions have their own exact effective-fact overlap proof.
   -- Check new/changed original intervals here, including later normal closure.
   if TG_OP='INSERT' or (new.started_at,new.ended_at,new.well_id,new.pump_id)
       is distinct from (old.started_at,old.ended_at,old.well_id,old.pump_id) then
     if exists(select 1 from ops.irrigation_sessions other
       left join ops.effective_session_facts ef on ef.session_id=other.id
       where other.id<>new.id and (other.well_id=w or other.pump_id=new.pump_id)
        and (manual_mode is not null or ops.manual_session_entry_mode(other.id) is not null)
        and (ef.session_id is null or ef.effective_started_at is null
          or (other.status<>'open' and ef.effective_ended_at is null)
          or tstzrange(ef.effective_started_at,ef.effective_ended_at,'[)')
             &&tstzrange(new.started_at,new.ended_at,'[)'))) then
       raise exception 'manual_entry_resource_overlap' using errcode='23514';end if;
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
 if changed and not historical and TG_TABLE_NAME<>'irrigation_sessions' then
   update core.wells set operational_schedule_revision=operational_schedule_revision+1 where id=w;
 end if;
 if TG_OP='DELETE' then return old; end if;
 return new;
end;$f$;

create or replace function ops.attach_session_to_open_shift()
returns trigger
language plpgsql
security definer
set search_path to 'ops', 'pg_temp'
as $$
begin
  if ops.manual_session_entry_mode(new.id) is not null then
    new.current_shift_id:=null;new.collector_profile_id:=null;return new;
  end if;
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
  if ops.manual_session_entry_mode(new.id) is not null then return null;end if;
  -- إثبات المسار الحالي من سجل أوامر خاص، لا من راية يرسلها العميل.
  -- فرع processing لازم حين يطلب المستدعي فحص القيد فورًا أثناء INSERT؛
  -- المعاملة لا تقبل الأمر إلا بعد إنشاء ربط الواقعة الفريد.
  if exists (
    select 1 from sync.processed_commands c
    where c.tenant_id=(select w.tenant_id from core.wells w where w.id=new.well_id)
      and c.entity_id=new.well_id
      and c.command_type='start_operational_session'
      and c.request_payload->>'actor_id'=new.operator_profile_id::text
      and (c.request_payload->>'well_id')::uuid=new.well_id
      and (c.request_payload->>'pump_id')::uuid=new.pump_id
      and (c.request_payload->>'farm_id')::uuid=new.farm_id
      and (c.request_payload->>'farmer_well_account_id')::uuid=new.farmer_well_account_id
      and (c.request_payload->>'started_at')::timestamptz=new.started_at
      and ((c.status='processing' and c.response_payload is null)
        or (c.status='accepted' and c.response_payload->>'id'=new.id::text
          and exists(select 1 from ops.operational_occurrences o
            where o.tenant_id=c.tenant_id and o.occurrence_command_id=c.command_id
              and o.server_session_id=new.id and o.status='accepted')))
  ) then return null; end if;
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

  if exists(select 1 from ops.session_segments ss where ss.id=new.session_segment_id
      and ops.manual_session_entry_mode(ss.session_id) is not null) then
    new.shift_id:=null;
  elsif new.shift_id is null and not exists(select 1 from ops.session_segments ss
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


-- Shared terminal insertion + initial event-time-priced segment. The legacy
-- wrapper retains all its rejection/completion/event identity validation.
create function ops.begin_terminal_occurrence_materialization(p_session_id uuid,p_start jsonb default null)
returns uuid language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $core$
declare o ops.operational_occurrences%rowtype;s jsonb;mode text;segment uuid;
begin
 select * into strict o from ops.operational_occurrences where server_session_id=p_session_id for update;
 perform billing.require_customer_credit_well_lock(o.well_id);
 perform ops.lock_operational_scope(o.well_id,true);
 mode:=ops.manual_session_entry_mode(p_session_id);
 if o.provenance='historical_settlement' then
  -- Keep the existing wrapper's validated p_facts as the legacy data source.
  s:=coalesce(p_start,o.original_facts->'start');
 else
  s:=o.original_facts->'start';
  if p_start is not null and p_start is distinct from s then
   raise exception 'terminal_occurrence_facts_mismatch' using errcode='23514';end if;
 end if;
 if o.status<>'materializing' or (o.provenance<>'historical_settlement' and mode is distinct from 'manual_historical_completed')
  or auth.uid() is null or not coalesce(iam.has_well_permission(o.well_id,'session.complete'),false)
  or (mode is not null and o.original_operator_id is distinct from auth.uid())
  or o.ended_at is null or not isfinite(o.started_at) or not isfinite(o.ended_at)
  or o.started_at>=o.ended_at or o.ended_at>transaction_timestamp() then
  raise exception 'terminal_occurrence_proof_required' using errcode='23514';end if;
 if not exists(select 1 from core.pumps where id=(s->>'pump_id')::uuid and well_id=o.well_id)
  or not exists(select 1 from ops.farms f join ops.farmer_well_accounts a on a.id=f.farmer_well_account_id
    where f.id=(s->>'farm_id')::uuid and f.well_id=o.well_id and a.well_id=o.well_id
     and a.tenant_id=o.tenant_id and a.id=(s->>'farmer_well_account_id')::uuid) then
  raise exception 'terminal_occurrence_scope_required' using errcode='23514';end if;
 insert into ops.irrigation_sessions(id,well_id,pump_id,farm_id,farmer_well_account_id,
  operator_profile_id,started_at,ended_at,status,booking_id,current_shift_id,collector_profile_id)
 values(p_session_id,o.well_id,(s->>'pump_id')::uuid,(s->>'farm_id')::uuid,
  (s->>'farmer_well_account_id')::uuid,o.original_operator_id,o.started_at,o.ended_at,'closed',null,null,null);
 segment:=ops.create_priced_session_segment(p_session_id,s->>'energy_source',o.started_at,(s->>'fuel_owner_person_id')::uuid);
 return segment;
end;$core$;


create or replace function ops.materialize_historical_occurrence(
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
 perform billing.require_customer_credit_well_lock(p_well_id);
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
 source:=s->>'energy_source'; owner_id:=(s->>'fuel_owner_person_id')::uuid;
 segment_id:=ops.begin_terminal_occurrence_materialization(sid,s);
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


create function ops.require_manual_session_entry_resolved() returns trigger
language plpgsql security definer set search_path=pg_catalog,pg_temp as $resolved$
declare o ops.operational_occurrences%rowtype;
begin
 select * into strict o from ops.operational_occurrences
 where tenant_id=new.tenant_id and occurrence_command_id=new.occurrence_command_id;
 if o.provenance in ('manual_historical_completed','manual_external_active')
   and (o.status<>'accepted' or ops.manual_session_occurrence_mode(o) is null) then
  raise exception 'manual_entry_must_resolve_atomically' using errcode='23514';end if;
 return null;
end;$resolved$;
create constraint trigger manual_session_entry_resolved after insert or update on ops.operational_occurrences
 deferrable initially deferred for each row execute function ops.require_manual_session_entry_resolved();

revoke all on function ops.manual_session_occurrence_mode(ops.operational_occurrences),
 ops.manual_session_entry_mode(uuid),ops.manual_session_entry_result(uuid),
 ops.begin_terminal_occurrence_materialization(uuid,jsonb),ops.require_manual_session_entry_resolved()
 from public,anon,authenticated,service_role;
-- No new API, table grant, client retry authority, or financial override.
commit;
