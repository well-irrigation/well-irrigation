-- R6-C2B coordinated follow-up; owner DB verification pending.
begin;
alter table core.partner_irrigation_policies add column accepted_at timestamptz,
 add column accepted_by uuid references iam.profiles(id),add column policy_version bigint;
alter table core.partner_irrigation_policies add constraint accepted_partner_policy_context
 check((accepted_at is null and accepted_by is null and policy_version is null)
  or(accepted_at is not null and accepted_by is not null and policy_version>0));
-- Existing date-based historical policies remain constrained identically.
-- New immutable snapshots are selected by server save sequence at invoice
-- issuance, not by the old session completion date or overlapping date ranges.
alter table core.partner_irrigation_policies drop constraint no_partner_policy_period_overlap;
alter table core.partner_irrigation_policies add constraint no_partner_policy_period_overlap
 exclude using gist(partner_id with =,daterange(period_start,period_end,'[)') with &&) where(accepted_at is null);
drop index core.partner_irrigation_policies_active_unique;
create unique index partner_irrigation_policies_active_unique on core.partner_irrigation_policies(partner_id)
 where period_end is null and accepted_at is null;
create unique index partner_irrigation_policy_version on core.partner_irrigation_policies(partner_id,policy_version)
 where policy_version is not null;
create function core.guard_partner_irrigation_policy_snapshot() returns trigger language plpgsql set search_path=pg_catalog,pg_temp as $$
begin
 if old.accepted_at is not null or exists(select 1 from billing.invoices i where i.partner_policy_id=old.id) then
  raise exception 'partner_invoice_policy_history_preserved' using errcode='23514';end if;
 if tg_op='DELETE' then return old;end if;return new;
end;$$;
create trigger partner_irrigation_policy_snapshot_immutable before update or delete on core.partner_irrigation_policies
 for each row execute function core.guard_partner_irrigation_policy_snapshot();
revoke all on function core.guard_partner_irrigation_policy_snapshot() from public,anon,authenticated,service_role;
create function api.set_partner_irrigation_policy(p_partner_id uuid,p_policy_type text) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare candidate core.well_partners%rowtype;p core.well_partners%rowtype;v bigint;stamp timestamptz;policy uuid;
begin
 select * into candidate from core.well_partners where id=p_partner_id;
 if candidate.id is null or auth.uid() is null or not coalesce(iam.has_well_role(candidate.well_id,array['owner']),false) then
  raise exception 'partner_policy_owner_required' using errcode='42501';end if;
 perform billing.enter_financial_write(candidate.well_id,null,array['owner'],candidate.tenant_id);
 select * into strict p from core.well_partners where id=p_partner_id for update;
 if(p.well_id,p.tenant_id,p.person_id) is distinct from(candidate.well_id,candidate.tenant_id,candidate.person_id)
  or not coalesce(iam.has_well_role(p.well_id,array['owner']),false) then raise exception 'partner_policy_owner_required' using errcode='42501';end if;
 if p_policy_type is null or p_policy_type not in ('normal_customer','deduct_from_profit') then
  raise exception 'partner_irrigation_policy_invalid' using errcode='22023';end if;
 perform 1 from core.partner_irrigation_policies where partner_id=p.id order by id for update;
 select coalesce(max(policy_version),0)+1 into v from core.partner_irrigation_policies where partner_id=p.id;
 stamp:=clock_timestamp();
 insert into core.partner_irrigation_policies(tenant_id,well_id,partner_id,policy_type,period_start,accepted_at,accepted_by,policy_version)
 values(p.tenant_id,p.well_id,p.id,p_policy_type,(stamp at time zone core.well_timezone(p.well_id))::date,stamp,auth.uid(),v) returning id into policy;
 return jsonb_build_object('status','saved','policy_id',policy,'policy_type',p_policy_type,'effective_from',stamp,
  'title','تم حفظ إعداد سقي الشريك','message','سيطبق على الفواتير الجديدة فقط. الفواتير السابقة لن تتغير.','action','عرض الإعدادات');
end;$$;
create function api.get_partner_irrigation_policy(p_partner_id uuid) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare p core.well_partners%rowtype;versions jsonb;current_policy jsonb;
begin
 select * into strict p from core.well_partners where id=p_partner_id;
 if auth.uid() is null or not coalesce(iam.has_well_role(p.well_id,array['owner','manager']),false) then
  raise exception 'partner_policy_read_forbidden' using errcode='42501';end if;
 select to_jsonb(x) into current_policy from core.partner_irrigation_policies x where x.partner_id=p.id
  and((x.accepted_at is not null and x.accepted_at<=clock_timestamp()) or(x.accepted_at is null
   and daterange(x.period_start,x.period_end,'[)') @> (clock_timestamp() at time zone core.well_timezone(p.well_id))::date))
  order by(x.accepted_at is not null) desc,x.policy_version desc nulls last,x.period_start desc,x.created_at desc,x.id desc limit 1;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.accepted_at nulls first,x.created_at,x.id),'[]'::jsonb)
 into versions from core.partner_irrigation_policies x where x.partner_id=p.id;
 return jsonb_build_object('current',current_policy,'history',versions,'title','سقي الشريك',
  'notice','تغيير الإعداد يسري على الفواتير الجديدة فقط.','save_action','حفظ الإعدادات');
end;$$;
revoke all on function api.set_partner_irrigation_policy(uuid,text),api.get_partner_irrigation_policy(uuid)
 from public,anon,authenticated,service_role;
grant execute on function api.set_partner_irrigation_policy(uuid,text),api.get_partner_irrigation_policy(uuid) to authenticated;
revoke insert,update,delete,truncate on core.partner_irrigation_policies from public,anon,authenticated,service_role;
do $columns$ declare c record;begin
 for c in select attname from pg_attribute where attrelid='core.partner_irrigation_policies'::regclass and attnum>0 and not attisdropped loop
  execute format('revoke insert (%I),update (%I) on core.partner_irrigation_policies from public,anon,authenticated,service_role',c.attname,c.attname);
 end loop;
end;$columns$;

create or replace function billing.issue_session_invoice(
  p_session_id uuid,
  p_issued_by uuid
)
returns uuid
language plpgsql
security definer
set search_path=pg_catalog,pg_temp
as $function$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_well_id uuid;
  v_farmer_well_account_id uuid;
  v_session_status text;
  v_ended_at timestamptz;
  v_charge_amount bigint;
  v_invoice_id uuid;
  v_partner_policy_id uuid;
  v_partner_policy_type text;
  v_settlement_method text := 'normal';
  v_line_number integer := 0;
  v_lines_total bigint;
  v_segment record;
  v_time_rate bigint;
  v_fuel_quantity bigint;
begin
 perform billing.enter_financial_write((select well_id from ops.irrigation_sessions where id=p_session_id),'invoice.issue',null);
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إصدار فاتورة الجلسة';
  end if;
  if p_issued_by is distinct from v_actor then
    raise exception 'مصدر الفاتورة يجب أن يطابق المستخدم المسجل حاليًا';
  end if;

  select well_id into v_well_id from ops.irrigation_sessions where id=p_session_id;
  if not coalesce(iam.has_well_permission(v_well_id,'invoice.issue'),false) then
   raise exception 'لا تملك صلاحية إصدار فاتورة هذه الجلسة';end if;
  perform billing.lock_customer_credit_well(v_well_id);
  perform ops.lock_operational_scope(v_well_id,true);
  select w.tenant_id, s.well_id, s.farmer_well_account_id,
         s.status, s.ended_at
  into v_tenant_id, v_well_id, v_farmer_well_account_id,
       v_session_status, v_ended_at
  from ops.irrigation_sessions s
  join core.wells w on w.id = s.well_id
  where s.id = p_session_id
  for update of s;

  if not found then
    raise exception 'جلسة السقي غير موجودة: %', p_session_id;
  end if;
  if v_session_status <> 'closed' then
    raise exception 'لا يمكن إصدار فاتورة قبل إكمال الجلسة';
  end if;
  if not iam.has_well_permission(v_well_id, 'invoice.issue') then
    raise exception 'لا تملك صلاحية إصدار فاتورة هذه الجلسة';
  end if;
  if v_farmer_well_account_id is null then
    raise exception 'لا يمكن إصدار الفاتورة لأن الجلسة غير مرتبطة بحساب مزارع';
  end if;
  if exists (
    select 1 from billing.invoices i
    where i.session_id = p_session_id
      and i.status not in ('cancelled', 'reversed')
  ) then
    raise exception 'توجد فاتورة سارية مسبقًا لهذه الجلسة';
  end if;
  if not exists (
    select 1 from ops.session_segments ss
    where ss.session_id = p_session_id
      and ss.ended_at is not null
  ) then
    raise exception 'لا توجد مقاطع مكتملة يمكن بناء بنود الفاتورة منها';
  end if;

  select sc.amount_minor,sc.effective_ended_at
  into v_charge_amount,v_ended_at
  from billing.effective_session_charges sc
  where sc.session_id = p_session_id
    and sc.pricing_mode = 'segments';

  if not found then
    raise exception 'لا يوجد ملخص تكلفة مقاطع مكتمل لهذه الجلسة';
  end if;

  select pip.id, pip.policy_type
  into v_partner_policy_id, v_partner_policy_type
  from ops.farmer_well_accounts fwa
  join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
  join core.well_partners wp
    on wp.well_id = fwa.well_id and wp.person_id = fp.person_id
  join core.partner_irrigation_policies pip
    on pip.partner_id = wp.id and pip.well_id = fwa.well_id
  where fwa.id = v_farmer_well_account_id
    and((pip.accepted_at is not null and pip.accepted_at<=clock_timestamp())
     or(pip.accepted_at is null and pip.period_start<=(clock_timestamp() at time zone core.well_timezone(v_well_id))::date
      and(pip.period_end is null or pip.period_end>(clock_timestamp() at time zone core.well_timezone(v_well_id))::date)))
  order by(pip.accepted_at is not null) desc,pip.policy_version desc nulls last,pip.period_start desc,pip.created_at desc,pip.id desc
  limit 1;

  if found and v_partner_policy_type = 'deduct_from_profit' then
    v_settlement_method := 'partner_profit_offset';
  end if;

  insert into billing.invoices (
    tenant_id, public_code, well_id, farmer_well_account_id,
    session_id, invoice_date, status, subtotal_minor, total_minor,
    paid_minor, outstanding_minor, settlement_method, partner_policy_id
  ) values (
    v_tenant_id, core.generate_public_code('INV'), v_well_id,
    v_farmer_well_account_id, p_session_id, v_ended_at, 'draft',
    v_charge_amount, v_charge_amount, 0, v_charge_amount,
    v_settlement_method, v_partner_policy_id
  )
  returning id into v_invoice_id;

  for v_segment in
    select ss.id, ss.sequence_number, ss.segment_type, ss.energy_source,
           ss.billable_seconds, ss.applied_hourly_rate_minor,
           ss.applied_operation_rate_minor,
           ss.applied_fuel_price_per_liter_minor,
           ss.fuel_actual_ml, ss.fuel_estimated_ml,
           ss.time_charge_minor, ss.fuel_charge_minor,
           ss.total_charge_minor
    from billing.financial_session_segments ss
    where ss.session_id = p_session_id
      and ss.is_billable
      and ss.total_charge_minor > 0
    order by ss.sequence_number
  loop
    if v_segment.time_charge_minor > 0 then
      v_line_number := v_line_number + 1;
      v_time_rate := coalesce(v_segment.applied_operation_rate_minor,
                              v_segment.applied_hourly_rate_minor);

      insert into billing.invoice_lines (
        tenant_id, invoice_id, line_number, line_type, description,
        quantity, unit, unit_price_minor, amount_minor,
        session_segment_id
      ) values (
        v_tenant_id, v_invoice_id, v_line_number,
        case when v_segment.energy_source = 'solar'
          then 'solar_irrigation' else 'diesel_operation' end,
        case when v_segment.energy_source = 'solar'
          then 'سقي شمسي — المقطع ' || v_segment.sequence_number
          else 'تشغيل ديزل — المقطع ' || v_segment.sequence_number end,
        v_segment.billable_seconds::numeric / 3600,
        'hour', v_time_rate, v_segment.time_charge_minor,
        v_segment.id
      );
    end if;

    if v_segment.fuel_charge_minor > 0 then
      v_line_number := v_line_number + 1;
      v_fuel_quantity := coalesce(v_segment.fuel_actual_ml,
                                  v_segment.fuel_estimated_ml);

      insert into billing.invoice_lines (
        tenant_id, invoice_id, line_number, line_type, description,
        quantity, unit, unit_price_minor, amount_minor,
        session_segment_id
      ) values (
        v_tenant_id, v_invoice_id, v_line_number, 'diesel_fuel',
        'وقود ديزل — المقطع ' || v_segment.sequence_number,
        v_fuel_quantity::numeric / 1000,
        'liter', v_segment.applied_fuel_price_per_liter_minor,
        v_segment.fuel_charge_minor, v_segment.id
      );
    end if;
  end loop;

  if v_line_number = 0 then
    raise exception 'لم تنتج مقاطع الجلسة أي بند قابل للفوترة';
  end if;

  select coalesce(sum(il.amount_minor), 0)
  into v_lines_total
  from billing.invoice_lines il
  where il.invoice_id = v_invoice_id;

  if v_lines_total <> v_charge_amount then
    raise exception 'مجموع بنود الفاتورة % لا يساوي تكلفة الجلسة %',
      v_lines_total, v_charge_amount;
  end if;

  update billing.invoices
  set status = 'issued',
      issued_at = clock_timestamp(),
      issued_by = p_issued_by
  where id = v_invoice_id;

  perform billing.refresh_partition_invoices(v_well_id);
  return v_invoice_id;
end;
$function$;
commit;
