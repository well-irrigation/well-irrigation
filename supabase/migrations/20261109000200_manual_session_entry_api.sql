begin;

insert into iam.permissions(code,description_ar)
 values('session.manual_entry','إضافة جلسة سقي منفذة خارج التطبيق') on conflict(code) do nothing;
insert into iam.role_permissions(role_id,permission_id)
 select r.id,p.id from iam.roles r cross join iam.permissions p
 where r.code in ('tenant_owner','well_manager','operator') and p.code='session.manual_entry'
 on conflict do nothing;

-- Event-time snapshots reuse existing segment pricing rules. Expired schedules
-- remain historical evidence; cancelled/draft schedules never supply authority.
create function ops.create_manual_entry_priced_segment(
  p_session_id uuid,
  p_energy_source text,
  p_started_at timestamptz,
  p_fuel_owner_person_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path=pg_catalog,pg_temp
as $function$
declare
  v_segment_id uuid;
  v_tenant_id uuid;
  v_well_id uuid;
  v_farmer_well_account_id uuid;
  v_session_snapshot bigint;
  v_sequence_number integer;
  v_segment_type text;
  v_price_rule_id uuid;
  v_diesel_pricing_model text;
  v_hourly_rate_minor bigint;
  v_operation_rate_minor bigint;
  v_fuel_price_per_liter_minor bigint;
  v_owner_person_id uuid;
begin
  if p_energy_source not in ('solar', 'well_diesel', 'farmer_diesel') then
    raise exception 'مصدر الطاقة غير صالح؛ القيم المسموحة: solar أو well_diesel أو farmer_diesel';
  end if;

  select s.well_id, w.tenant_id, s.farmer_well_account_id,
         s.price_per_hour_minor_snapshot
  into v_well_id, v_tenant_id, v_farmer_well_account_id,
       v_session_snapshot
  from ops.irrigation_sessions s
  join core.wells w on w.id = s.well_id
  where s.id = p_session_id;

  if not found then
    raise exception 'جلسة السقي غير موجودة: %', p_session_id;
  end if;

  select coalesce(max(ss.sequence_number), 0) + 1
  into v_sequence_number
  from ops.session_segments ss
  where ss.session_id = p_session_id;

  select pr.id, pr.diesel_pricing_model, pr.hourly_rate_minor,
         pr.operation_hourly_rate_minor, pr.fuel_price_per_liter_minor
  into v_price_rule_id, v_diesel_pricing_model, v_hourly_rate_minor,
       v_operation_rate_minor, v_fuel_price_per_liter_minor
  from ops.price_schedules ps
  join ops.price_rules pr on pr.price_schedule_id = ps.id
  where ps.well_id = v_well_id
    and ps.status in ('active','expired')
    and ps.effective_period @> p_started_at
    and pr.energy_source = p_energy_source
  order by lower(ps.effective_period) desc, ps.created_at desc, ps.id desc
  limit 1;

  if not found then
    if v_sequence_number = 1 then
      v_hourly_rate_minor := v_session_snapshot;
    else
      select wp.price_per_hour_minor
      into v_hourly_rate_minor
      from billing.well_pricing wp
      where wp.well_id = v_well_id
        and wp.period_start <= p_started_at
        and (wp.period_end is null or wp.period_end > p_started_at)
      order by wp.period_start desc, wp.created_at desc, wp.id desc
      limit 1;
    end if;

    v_price_rule_id := null;
    v_diesel_pricing_model := 'inclusive_hourly';
    v_operation_rate_minor := null;
    v_fuel_price_per_liter_minor := null;
  end if;

  if p_energy_source = 'solar' then
    if v_hourly_rate_minor is null or v_hourly_rate_minor <= 0 then
      raise exception 'لا يوجد سعر شمسي فعال يمكن تثبيته عند فتح المقطع';
    end if;
    v_operation_rate_minor := null;
    v_fuel_price_per_liter_minor := null;
    v_owner_person_id := null;
    v_segment_type := 'solar_run';
  elsif p_energy_source = 'well_diesel' then
    if v_diesel_pricing_model = 'operation_plus_fuel' then
      if v_operation_rate_minor is null or v_operation_rate_minor <= 0 then
        raise exception 'لا يوجد سعر تشغيل ديزل فعال يمكن تثبيته عند فتح المقطع';
      end if;
      if v_fuel_price_per_liter_minor is null or v_fuel_price_per_liter_minor < 0 then
        raise exception 'لا يوجد سعر وقود صالح يمكن تثبيته لمقطع ديزل البئر';
      end if;
      v_hourly_rate_minor := null;
    elsif v_hourly_rate_minor is null or v_hourly_rate_minor <= 0 then
      raise exception 'لا يوجد سعر ديزل شامل فعال يمكن تثبيته عند فتح المقطع';
    else
      v_operation_rate_minor := null;
      v_fuel_price_per_liter_minor := null;
    end if;
    v_owner_person_id := null;
    v_segment_type := 'well_diesel_run';
  else
    if v_diesel_pricing_model = 'operation_plus_fuel' then
      if v_operation_rate_minor is null or v_operation_rate_minor <= 0 then
        raise exception 'لا يوجد سعر تشغيل ديزل فعال يمكن تثبيته عند فتح المقطع';
      end if;
      if v_fuel_price_per_liter_minor is null or v_fuel_price_per_liter_minor < 0 then
        raise exception 'لا يوجد سعر وقود صالح يمكن تثبيته لمقطع ديزل المزارع';
      end if;
      v_hourly_rate_minor := null;
    elsif v_hourly_rate_minor is null or v_hourly_rate_minor <= 0 then
      raise exception 'لا يوجد سعر ديزل شامل فعال يمكن تثبيته عند فتح المقطع';
    else
      v_operation_rate_minor := null;
      v_fuel_price_per_liter_minor := null;
    end if;

    v_owner_person_id := p_fuel_owner_person_id;
    if v_owner_person_id is null and v_farmer_well_account_id is not null then
      select fp.person_id
      into v_owner_person_id
      from ops.farmer_well_accounts fwa
      join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
      where fwa.id = v_farmer_well_account_id;
    end if;

    if v_owner_person_id is null then
      raise exception 'يجب تحديد مالك ديزل المزارع قبل فتح المقطع';
    end if;

    if not exists (
      select 1 from core.persons p
      where p.id = v_owner_person_id and p.tenant_id = v_tenant_id
    ) then
      raise exception 'مالك ديزل المزارع لا ينتمي إلى جهة البئر';
    end if;

    v_segment_type := 'farmer_diesel_run';
  end if;

  insert into ops.session_segments (
    tenant_id, session_id, sequence_number, segment_type, energy_source,
    started_at, is_billable, fuel_owner_person_id, applied_price_rule_id,
    applied_hourly_rate_minor, applied_operation_rate_minor,
    applied_fuel_price_per_liter_minor
  ) values (
    v_tenant_id, p_session_id, v_sequence_number, v_segment_type,
    p_energy_source, p_started_at, true, v_owner_person_id, v_price_rule_id,
    v_hourly_rate_minor, v_operation_rate_minor,
    v_fuel_price_per_liter_minor
  )
  returning id into v_segment_id;

  return v_segment_id;
end;
$function$;
revoke all on function ops.create_manual_entry_priced_segment(uuid,text,timestamptz,uuid) from public,anon,authenticated,service_role;
create or replace function ops.begin_terminal_occurrence_materialization(p_session_id uuid,p_start jsonb default null)
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
 if mode='manual_historical_completed' then
  segment:=ops.create_manual_entry_priced_segment(p_session_id,s->>'energy_source',o.started_at,(s->>'fuel_owner_person_id')::uuid);
 else
  segment:=ops.create_priced_session_segment(p_session_id,s->>'energy_source',o.started_at,(s->>'fuel_owner_person_id')::uuid);
 end if;
 return segment;
end;$core$;

-- Private authorization shared by write and recovery. Authorization precedes
-- command lookup, including the not-found case. No client actor/tenant input.
create function ops.require_manual_session_entry_scope(p_well uuid) returns uuid
language plpgsql stable security definer set search_path=pg_catalog,pg_temp as $$
declare tenant uuid;
begin
 if auth.uid() is null then raise exception 'يجب تسجيل الدخول' using errcode='28000';end if;
 select w.tenant_id into tenant from core.wells w
 where w.id=p_well and exists(select 1 from core.well_assignments a
  where a.well_id=w.id and a.profile_id=auth.uid() and a.status='active');
 if tenant is null or not coalesce(iam.has_well_permission(p_well,'session.manual_entry'),false) then
  raise exception 'لا توجد صلاحية لإضافة جلسة على هذا البئر' using errcode='42501';end if;
 return tenant;
end;$$;

create function ops.read_manual_session_entry_receipt(p_well uuid,p_command uuid) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,pg_temp as $$
declare tenant uuid;c sync.processed_commands%rowtype;o ops.operational_occurrences%rowtype;
 envelope jsonb;state text:='unresolved';mode text;
begin
 tenant:=ops.require_manual_session_entry_scope(p_well);
 if p_command is null then raise exception 'معرّف الطلب مطلوب' using errcode='22023';end if;
 envelope:=jsonb_build_object('contract','get_manual_session_entry_receipt','version',1,
  'well_id',p_well,'command_id',p_command,'status','unresolved','result',null,'retry_authorized',false);
 select * into c from sync.processed_commands where tenant_id=tenant and command_id=p_command;
 if not found or c.entity_id is distinct from p_well then
  return envelope||jsonb_build_object('status','not_found');end if;
 if c.command_type<>'manual_session_entry'
  or c.request_payload->>'contract' is distinct from 'manual_session_entry'
  or c.request_payload->'version' is distinct from '1'::jsonb
  or c.request_payload->>'tenant_id' is distinct from tenant::text
  or c.request_payload->>'well_id' is distinct from p_well::text
  or not coalesce(c.request_payload->>'entry_type' in ('manual_historical_completed','manual_external_active'),false)
  or jsonb_typeof(c.request_payload->'actor_id') is distinct from 'string'
  or jsonb_typeof(c.request_payload->'reason') is distinct from 'string'
  or jsonb_typeof(c.request_payload->'facts') is distinct from 'object'
  or jsonb_typeof(c.request_payload->'started_at') is distinct from 'string'
  or nullif(btrim(c.request_payload->>'reason'),'') is null then return envelope;end if;
 if c.status='processing' then
  if c.response_payload is null and not exists(select 1 from ops.operational_occurrences x
    where x.tenant_id=tenant and x.occurrence_command_id=p_command) then
   return envelope||jsonb_build_object('status','processing');end if;
  return envelope;
 end if;
 if jsonb_typeof(c.response_payload) is distinct from 'object'
  or c.response_payload->>'contract' is distinct from 'manual_session_entry'
  or c.response_payload->'version' is distinct from '1'::jsonb
  or c.response_payload->>'command_id' is distinct from p_command::text
  or c.response_payload->>'well_id' is distinct from p_well::text
  or c.response_payload->>'entry_type' is distinct from c.request_payload->>'entry_type' then return envelope;end if;
 state:=c.response_payload->>'status';
 if c.status='accepted' and state='accepted' then
  select * into o from ops.operational_occurrences
   where tenant_id=tenant and occurrence_command_id=p_command and well_id=p_well;
  if not found or o.status<>'accepted' or o.manual_result is distinct from c.response_payload
    or ops.manual_session_occurrence_mode(o) is null
    or not exists(select 1 from ops.irrigation_sessions s where s.id=o.server_session_id and s.well_id=p_well) then
   return envelope;end if;
 elsif c.status in ('rejected','conflict') and state in
   ('conflict_overlap','conflict_active_resource','validation_error','needs_review','unresolved') then
  if exists(select 1 from ops.operational_occurrences x where x.tenant_id=tenant and x.occurrence_command_id=p_command) then return envelope;end if;
 else return envelope;
 end if;
 return envelope||jsonb_build_object('status',state,'result',c.response_payload);
end;$$;

-- No business detail is taken from exception text by the future UI. The few
-- known internal error identities are translated HERE; unknown failures remain
-- unresolved and the entire materialization subtransaction is rolled back.
create function ops.write_manual_session_entry(p_well uuid,p_command uuid,p_request jsonb,p_mode text)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare tenant uuid;actor uuid:=auth.uid();req jsonb;facts jsonb;start_facts jsonb;result jsonb;receipt jsonb;
 c sync.processed_commands%rowtype;guard jsonb;sid uuid;seg uuid;at_time timestamptz;end_time timestamptz;
 pump uuid;farm uuid;account uuid;owner_id uuid;tank uuid;quantity bigint;measurement text;
 energy text;why text;note text;crops jsonb;key text;state text;message text;errstate text;
begin
 tenant:=ops.require_manual_session_entry_scope(p_well);
 if not coalesce(iam.has_well_permission(p_well,'session.start'),false)
  or (p_mode='manual_historical_completed' and not coalesce(iam.has_well_permission(p_well,'session.complete'),false)) then
  raise exception 'لا توجد صلاحية لتنفيذ هذه العملية' using errcode='42501';end if;
 if p_mode is null or p_mode not in ('manual_historical_completed','manual_external_active') then
  raise exception 'نوع الإدخال غير صالح' using errcode='22023';end if;
 result:=jsonb_build_object('contract','manual_session_entry','version',1,'well_id',p_well,
  'command_id',p_command,'entry_type',p_mode,'status','validation_error');
 -- Canonicalize only accepted business fields; no actor, booking, prices,
 -- events, revision, or client result can enter persisted authority.
 begin
  if p_command is null or jsonb_typeof(p_request) is distinct from 'object'
   or p_request->'version' is distinct from '1'::jsonb
   or exists(select 1 from jsonb_object_keys(p_request) k where k not in
    ('version','pump_id','farm_id','farmer_well_account_id','started_at','ended_at','energy_source',
     'reason','notes','fuel_owner_person_id','fuel_tank_id','fuel_quantity_ml','fuel_measurement_type','crops'))
   or jsonb_typeof(p_request->'reason') is distinct from 'string'
   or nullif(btrim(p_request->>'reason'),'') is null
   or jsonb_typeof(p_request->'pump_id') is distinct from 'string'
   or jsonb_typeof(p_request->'farm_id') is distinct from 'string'
   or jsonb_typeof(p_request->'farmer_well_account_id') is distinct from 'string'
   or jsonb_typeof(p_request->'started_at') is distinct from 'string'
   or jsonb_typeof(p_request->'energy_source') is distinct from 'string'
   or p_request->>'energy_source' not in ('solar','well_diesel','farmer_diesel')
   or (p_request ? 'notes' and p_request->'notes'<>'null'::jsonb and jsonb_typeof(p_request->'notes')<>'string') then return result;end if;
  if (p_request->>'started_at') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$' then return result;end if;
  at_time:=(p_request->>'started_at')::timestamptz;
  if not isfinite(at_time) or at_time>clock_timestamp() then return result;end if;
  if p_mode='manual_historical_completed' then
   if jsonb_typeof(p_request->'ended_at') is distinct from 'string'
    or (p_request->>'ended_at') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$' then return result;end if;
   end_time:=(p_request->>'ended_at')::timestamptz;
   if not isfinite(end_time) or end_time<=at_time or end_time>transaction_timestamp() then return result;end if;
  elsif p_request ?| array['ended_at','fuel_tank_id','fuel_quantity_ml','fuel_measurement_type'] then return result;
  end if;
  pump:=(p_request->>'pump_id')::uuid;farm:=(p_request->>'farm_id')::uuid;account:=(p_request->>'farmer_well_account_id')::uuid;
  foreach key in array array['fuel_owner_person_id','fuel_tank_id'] loop
   if p_request ? key and p_request->key<>'null'::jsonb and jsonb_typeof(p_request->key)<>'string' then return result;end if;
  end loop;
  owner_id:=(p_request->>'fuel_owner_person_id')::uuid;tank:=(p_request->>'fuel_tank_id')::uuid;
  energy:=p_request->>'energy_source';why:=p_request->>'reason';note:=p_request->>'notes';
  crops:=coalesce(p_request->'crops','[]'::jsonb);
  if jsonb_typeof(crops) is distinct from 'array' or exists(select 1 from jsonb_array_elements(crops) x where jsonb_typeof(x)<>'string') then return result;end if;
  if p_request ? 'fuel_quantity_ml' then
   if jsonb_typeof(p_request->'fuel_quantity_ml') is distinct from 'number' or p_request->>'fuel_quantity_ml' !~ '^[0-9]+$' then return result;end if;
   quantity:=(p_request->>'fuel_quantity_ml')::bigint;
   if quantity<=0 or energy='solar' then return result;end if;
  end if;
  if p_request ? 'fuel_measurement_type' and jsonb_typeof(p_request->'fuel_measurement_type') is distinct from 'string' then return result;end if;
  measurement:=p_request->>'fuel_measurement_type';
  if (measurement is not null and (quantity is null or measurement not in ('actual','estimated')))
    or (quantity is not null and energy='well_diesel' and tank is null)
    or (owner_id is not null and energy<>'farmer_diesel') then return result;end if;
  if quantity is not null then measurement:=coalesce(measurement,'actual');end if;
 exception when invalid_text_representation or numeric_value_out_of_range or invalid_datetime_format or datetime_field_overflow then
  return result;
 end;
 start_facts:=jsonb_build_object('pump_id',pump,'farm_id',farm,'farmer_well_account_id',account,
  'energy_source',energy,'fuel_owner_person_id',owner_id,'crops',crops);
 facts:=jsonb_build_object('start',start_facts);
 if tank is not null then facts:=facts||jsonb_build_object('fuel_tank_id',tank);end if;
 if quantity is not null then facts:=facts||jsonb_build_object('fuel_quantity_ml',quantity,'fuel_measurement_type',measurement);end if;
 req:=jsonb_build_object('contract','manual_session_entry','version',1,'tenant_id',tenant,'well_id',p_well,
  'actor_id',actor,'entry_type',p_mode,'reason',why,'notes',note,'facts',facts,
  'started_at',to_char(at_time at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
  'ended_at',case when end_time is not null then to_char(end_time at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') end);
 -- Root -> well -> command reservation matches the existing financial writers.
 perform billing.enter_financial_write(p_well,'session.manual_entry',null,tenant);
 guard:=sync.begin_command(tenant,p_command,'manual_session_entry',req,p_well);
 select * into strict c from sync.processed_commands where tenant_id=tenant and command_id=p_command;
 if c.command_type<>'manual_session_entry' or c.entity_id is distinct from p_well or c.request_payload is distinct from req then
  return result||jsonb_build_object('reason','request_changed');end if;
 if c.status<>'processing' then
  receipt:=ops.read_manual_session_entry_receipt(p_well,p_command);
  return coalesce(nullif(receipt->'result','null'::jsonb),result||jsonb_build_object('status','unresolved'));
 end if;
 -- A pre-existing processing reservation is recovery-only. begin_command's
 -- duplicate flag is checked below using the row returned by its own guard.
 if coalesce((guard->>'duplicate')::boolean,false) then
  return result||jsonb_build_object('status','processing');end if;
 begin
  if not exists(select 1 from core.pumps p where p.id=pump and p.well_id=p_well and p.status='active')
   or not exists(select 1 from ops.farms f join ops.farmer_well_accounts a on a.id=f.farmer_well_account_id
    where f.id=farm and f.well_id=p_well and f.status='active' and a.id=account
      and a.well_id=p_well and a.tenant_id=tenant and a.status='active')
   or (owner_id is not null and not exists(select 1 from core.persons where id=owner_id and tenant_id=tenant))
   or (tank is not null and not exists(select 1 from inventory.fuel_tanks where id=tank and well_id=p_well and status='active')) then
   result:=result||jsonb_build_object('reason','context_invalid');
  elsif exists(select 1 from ops.irrigation_sessions s left join ops.effective_session_facts ef on ef.session_id=s.id
   where (s.well_id=p_well or s.pump_id=pump) and
    (ef.session_id is null or ef.effective_started_at is null or (s.status<>'open' and ef.effective_ended_at is null))) then
   result:=result||jsonb_build_object('status','needs_review','reason','resource_facts_unavailable');
  elsif exists(select 1 from ops.irrigation_sessions s join ops.effective_session_facts ef on ef.session_id=s.id
   where (s.well_id=p_well or s.pump_id=pump) and s.status='open'
    and tstzrange(ef.effective_started_at,ef.effective_ended_at,'[)')&&tstzrange(at_time,end_time,'[)')) then
   result:=result||jsonb_build_object('status','conflict_active_resource');
  elsif exists(select 1 from ops.irrigation_sessions s join ops.effective_session_facts ef on ef.session_id=s.id
   where (s.well_id=p_well or s.pump_id=pump)
    and tstzrange(ef.effective_started_at,ef.effective_ended_at,'[)')&&tstzrange(at_time,end_time,'[)')) then
   result:=result||jsonb_build_object('status','conflict_overlap');
  else
   sid:=gen_random_uuid();
   insert into ops.operational_occurrences(tenant_id,occurrence_command_id,well_id,original_request_id,
    original_operator_id,started_at,ended_at,original_facts,provenance,server_session_id,status,manual_reason,manual_notes)
   values(tenant,p_command,p_well,p_command,actor,at_time,end_time,facts,p_mode,sid,'materializing',why,note);
   if p_mode='manual_historical_completed' then
    seg:=ops.begin_terminal_occurrence_materialization(sid);
    update ops.session_segments set ended_at=end_time,fuel_measurement_type=measurement,
      fuel_actual_ml=case when measurement='actual' then quantity end,
      fuel_estimated_ml=case when measurement='estimated' then quantity end where id=seg;
    perform ops.finalize_session_from_closed_segments(sid,end_time,tank);
   else
    insert into ops.irrigation_sessions(id,well_id,pump_id,farm_id,farmer_well_account_id,
     operator_profile_id,started_at,status,booking_id,current_shift_id,collector_profile_id)
    values(sid,p_well,pump,farm,account,actor,at_time,'open',null,null,null);
    seg:=ops.create_manual_entry_priced_segment(sid,energy,at_time,owner_id);
   end if;
   insert into ops.session_crops(session_id,crop_name,position)
    select sid,name,row_number() over(order by ord) from (
     select btrim(value) name,min(ordinality) ord from jsonb_array_elements_text(crops) with ordinality
     where btrim(value)<>'' group by btrim(value)) normalized;
   result:=ops.manual_session_entry_result(sid);
   perform sync.finish_command(tenant,p_command,'accepted',result);
   update ops.operational_occurrences set status='accepted',resolved_at=clock_timestamp(),manual_result=result
    where tenant_id=tenant and occurrence_command_id=p_command;
  end if;
 exception when others then
  get stacked diagnostics message=MESSAGE_TEXT,errstate=RETURNED_SQLSTATE;
  state:=case
   when errstate='P0C02' or message like 'لا يوجد سعر%' then 'needs_review'
   when message in ('manual_entry_resource_overlap','historical_interval_conflict','actual_session_interval_conflict') then 'conflict_overlap'
   when message like 'لا يمكن فتح جلسة جديدة: المضخة مشغولة%' then 'conflict_active_resource'
   when errstate='42501' then 'needs_review'
   else 'unresolved' end;
  result:=jsonb_build_object('contract','manual_session_entry','version',1,'well_id',p_well,
   'command_id',p_command,'entry_type',p_mode,'status',state);
  if state='needs_review' then result:=result||jsonb_build_object('reason',case when errstate='42501'
   then 'permission_changed' else 'price_unavailable' end);end if;
 end;
 if result->>'status'<>'accepted' then
  perform sync.finish_command(tenant,p_command,case when result->>'status' in
   ('conflict_overlap','conflict_active_resource') then 'conflict' else 'rejected' end,result);
 end if;
 return result;
end;$$;

create function api.record_historical_session(p_well_id uuid,p_command_id uuid,p_request jsonb)
returns jsonb language sql volatile security invoker set search_path=pg_catalog,pg_temp as $$
 select ops.write_manual_session_entry(p_well_id,p_command_id,p_request,'manual_historical_completed');
$$;
create function api.adopt_external_session(p_well_id uuid,p_command_id uuid,p_request jsonb)
returns jsonb language sql volatile security invoker set search_path=pg_catalog,pg_temp as $$
 select ops.write_manual_session_entry(p_well_id,p_command_id,p_request,'manual_external_active');
$$;
create function api.get_manual_session_entry_receipt(p_well_id uuid,p_command_id uuid)
returns jsonb language sql stable security invoker set search_path=pg_catalog,pg_temp as $$
 select ops.read_manual_session_entry_receipt(p_well_id,p_command_id);
$$;
create function ops.read_manual_session_entry_capability(p_well uuid) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,pg_temp as $$
declare allowed boolean;
begin
 if auth.uid() is null then raise exception 'يجب تسجيل الدخول' using errcode='28000';end if;
 allowed:=exists(select 1 from core.well_assignments a where a.well_id=p_well and a.profile_id=auth.uid() and a.status='active')
  and coalesce(iam.has_well_permission(p_well,'session.manual_entry'),false)
  and coalesce(iam.has_well_permission(p_well,'session.start'),false);
 return jsonb_build_object('contract','manual_session_entry_capability','version',1,'well_id',p_well,
  'can_adopt_external_session',allowed,'can_record_historical_session',allowed and coalesce(iam.has_well_permission(p_well,'session.complete'),false));
end;$$;
create function api.get_manual_session_entry_capability(p_well_id uuid) returns jsonb
language sql stable security invoker set search_path=pg_catalog,pg_temp as $$
 select ops.read_manual_session_entry_capability(p_well_id);
$$;

revoke all on function ops.require_manual_session_entry_scope(uuid),
 ops.write_manual_session_entry(uuid,uuid,jsonb,text),ops.read_manual_session_entry_receipt(uuid,uuid),
 ops.read_manual_session_entry_capability(uuid),
 api.record_historical_session(uuid,uuid,jsonb),api.adopt_external_session(uuid,uuid,jsonb),
 api.get_manual_session_entry_receipt(uuid,uuid),api.get_manual_session_entry_capability(uuid)
 from public,anon,authenticated,service_role;
-- Internal entry wrappers are callable by INVOKER APIs, but enforce auth.uid,
-- active assignment and named permission themselves. Private proof stays private.
grant execute on function ops.write_manual_session_entry(uuid,uuid,jsonb,text),
 ops.read_manual_session_entry_receipt(uuid,uuid),ops.read_manual_session_entry_capability(uuid),
 api.record_historical_session(uuid,uuid,jsonb),api.adopt_external_session(uuid,uuid,jsonb),
 api.get_manual_session_entry_receipt(uuid,uuid),api.get_manual_session_entry_capability(uuid)
 to authenticated,service_role;
commit;
