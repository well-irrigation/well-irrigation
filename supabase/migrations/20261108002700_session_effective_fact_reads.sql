begin;

-- R6-C2A effective reads. Existing session RLS remains the visibility authority.
-- Existing session readers need the matching correction to read current facts;
-- correction-history RPCs retain their additional session.correct check.
create policy session_corrections_read_visible_session
on ops.session_corrections for select to authenticated
using (exists (
 select 1 from ops.irrigation_sessions s
 join core.wells w on w.id=s.well_id
 where s.id=session_corrections.session_id
  and w.id=session_corrections.well_id and w.tenant_id=session_corrections.tenant_id
));

grant select on ops.effective_session_facts to authenticated,service_role;
grant select on ops.session_corrections,ops.session_correction_reconciliations to service_role;


create or replace function api.list_well_sessions(
  p_well_id uuid,
  p_farmer_well_account_id uuid default null,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_unpaid_only boolean default false,
  p_limit integer default 200
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_limit integer := least(greatest(coalesce(p_limit, 200), 1), 500);
  v_items jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة سجل الجلسات'
      using errcode = '28000';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  -- RLS على core.wells هي مصدر التفويض؛ البئر غير المرئي = رفض صريح.
  if not exists (
    select 1
    from core.wells w
    where w.id = p_well_id
  ) then
    raise exception 'لا توجد صلاحية على هذا البئر'
      using errcode = '42501';
  end if;

  -- Check all visible candidate sessions before filtering or limiting.
  -- Missing positive-revision facts must neither disappear nor use originals.
  if exists (
    select 1 from ops.irrigation_sessions s
    left join ops.effective_session_facts ef on ef.session_id=s.id
    where s.well_id=p_well_id and s.operational_revision>0
      and (ef.operational_revision is distinct from s.operational_revision
        or ef.effective_started_at is null or ef.effective_ended_at is null
        or ef.effective_started_at>=ef.effective_ended_at)
  ) then
    raise exception 'سجل تصحيح الجلسة غير مكتمل' using errcode='55000';
  end if;

  select coalesce(
           jsonb_agg(x.item order by x.started_at desc, x.id),
           '[]'::jsonb
         )
  into v_items
  from (
    select
      s.id,
      ef.effective_started_at as started_at,
      jsonb_build_object(
        'id', s.id,
        'well_id', s.well_id,
        'status', s.status,
        'original_started_at', s.started_at,
        'original_ended_at', s.ended_at,
        'effective_started_at', ef.effective_started_at,
        'effective_ended_at', ef.effective_ended_at,
        'operational_revision', s.operational_revision,
        'financial_applied_revision', sc.financial_applied_revision,
        'financial_status', coalesce((select work.status
          from ops.session_correction_reconciliations work
          where work.session_id=s.id and work.operational_revision=s.operational_revision),
          case when s.operational_revision=0 then 'not_applicable' else 'pending' end),
        'started_at', ef.effective_started_at,
        'ended_at', ef.effective_ended_at,
        'farmer_well_account_id', fwa.id,
        'farmer_public_code', fwa.public_code,
        'farmer_name', per.full_name,
        'farm_id', f.id,
        'farm_name', f.name,
        'pump_id', pm.id,
        'pump_name', pm.name,
        'operator_name', pr.full_name,
        'energy_source', run.energy_source,
        'actual_seconds', case
          -- الجارية بلا مدة فعلية نهائية: null لا تلفيق (ق-37).
          when ef.effective_ended_at is null then null
          when s.operational_revision>0 then extract(epoch from (ef.effective_ended_at-ef.effective_started_at))::bigint
          -- المقفلة: مجموع مقاطعها كلها بما فيها التوقفات (ق-131 البند 7)،
          -- والقديمة بلا مقاطع تغلفها المخزَّن ended_at - started_at.
          when seg.segment_count > 0
            and seg.segments_actual_seconds is not null
            then seg.segments_actual_seconds
          else extract(epoch from (s.ended_at - s.started_at))::bigint
        end,
        'billable_seconds', sc.duration_seconds,
        'total_amount_minor', sc.amount_minor,
        'paid_amount_minor', pay.paid_minor,
        'payment_status', case
          when sc.id is null then 'not_billed'
          when coalesce(pay.paid_minor, 0) >= sc.amount_minor
            and sc.amount_minor > 0 then 'settled'
          when coalesce(pay.paid_minor, 0) > 0 then 'partial'
          else 'unpaid'
        end,
        'has_charge', sc.id is not null,
        'has_invoice', inv.id is not null
      ) as item
    from ops.irrigation_sessions s
    join ops.effective_session_facts ef on ef.session_id=s.id
    -- كل الانضمامات التالية تزويقية (اسم/رمز) والمصدر الحاكم للتفويض هو
    -- RLS على الجلسة نفسها؛ لذلك LEFT JOIN إجباري: صف تزويق محجوب أو
    -- غير معيّن يجب ألا يُخفي جلسة مرئية.
    left join ops.farms f on f.id = s.farm_id
    left join ops.farmer_well_accounts fwa
      on fwa.id = coalesce(s.farmer_well_account_id, f.farmer_well_account_id)
    left join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
    left join core.persons per on per.id = fp.person_id
    left join core.pumps pm on pm.id = s.pump_id
    left join iam.profiles pr on pr.id = s.operator_profile_id
    left join billing.effective_session_charges sc on sc.session_id = s.id
    left join billing.invoices inv on inv.session_id = s.id
    left join lateral (
      select ss.energy_source
      from ops.session_segments ss
      where ss.session_id = s.id
        and ss.energy_source is not null
      order by ss.sequence_number
      limit 1
    ) run on true
    left join lateral (
      select
        count(*) as segment_count,
        sum(ss.actual_seconds)::bigint as segments_actual_seconds
      from ops.session_segments ss
      where ss.session_id = s.id
    ) seg on true
    left join lateral (
      -- الفاتورة الفعالة إن وجدت، وإلا تسديد charge المقسم اقتصاديًا.
      select (select paid_minor from billing.session_read_settlements where session_charge_id=sc.id) as paid_minor
    ) pay on sc.id is not null
    where s.well_id = p_well_id
      and (
        p_farmer_well_account_id is null
        or fwa.id = p_farmer_well_account_id
      )
      and (p_from is null or ef.effective_started_at >= p_from)
      and (p_to is null or ef.effective_started_at < p_to)
      and (
        coalesce(p_unpaid_only, false) is not true
        or sc.id is null
        or coalesce(pay.paid_minor, 0) < sc.amount_minor
      )
    order by ef.effective_started_at desc, s.id
    limit v_limit
  ) x;

  return jsonb_build_object(
    'contract', 'list_well_sessions',
    'version', 1,
    'items', v_items
  );
end;
$function$;

create or replace function api.get_session_detail(
  p_session_id uuid
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_session jsonb;
  v_segments jsonb;
  v_segments_invalid boolean;
  v_financial_revision bigint;
  v_charge_id uuid;
  v_pricing_evidence jsonb;
  v_financial_segments jsonb := '[]'::jsonb;
  v_payment jsonb;
  v_crops jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة تفصيل الجلسة'
      using errcode = '28000';
  end if;

  if p_session_id is null then
    raise exception 'معرّف الجلسة مطلوب'
      using errcode = '22023';
  end if;

  -- Check all visible candidate sessions before filtering or limiting.
  -- Missing positive-revision facts must neither disappear nor use originals.
  if exists (
    select 1 from ops.irrigation_sessions s
    left join ops.effective_session_facts ef on ef.session_id=s.id
    where s.id=p_session_id and s.operational_revision>0
      and (ef.operational_revision is distinct from s.operational_revision
        or ef.effective_started_at is null or ef.effective_ended_at is null
        or ef.effective_started_at>=ef.effective_ended_at)
  ) then
    raise exception 'سجل تصحيح الجلسة غير مكتمل' using errcode='55000';
  end if;

  select
    jsonb_build_object(
      'id', s.id,
      'well_id', s.well_id,
      'status', s.status,
      'original_started_at', s.started_at,
      'original_ended_at', s.ended_at,
      'effective_started_at', ef.effective_started_at,
      'effective_ended_at', ef.effective_ended_at,
      'operational_revision', s.operational_revision,
      'financial_applied_revision', sc.financial_applied_revision,
      'financial_status', coalesce((select work.status
        from ops.session_correction_reconciliations work
        where work.session_id=s.id and work.operational_revision=s.operational_revision),
        case when s.operational_revision=0 then 'not_applicable' else 'pending' end),
      'started_at', ef.effective_started_at,
      'ended_at', ef.effective_ended_at,
      'farmer_well_account_id', fwa.id,
      'farmer_public_code', fwa.public_code,
      'farmer_name', per.full_name,
      'farm_id', f.id,
      'farm_name', f.name,
      'pump_id', pm.id,
      'pump_name', pm.name,
      'operator_name', pr.full_name,
      'energy_source', run.energy_source,
      'actual_seconds', case
        when ef.effective_ended_at is null then null
        when s.operational_revision>0 then extract(epoch from (ef.effective_ended_at-ef.effective_started_at))::bigint
        when seg.segment_count > 0
          and seg.segments_actual_seconds is not null
          then seg.segments_actual_seconds
        else extract(epoch from (s.ended_at - s.started_at))::bigint
      end,
      'billable_seconds', sc.duration_seconds,
      'total_amount_minor', sc.amount_minor,
      'paid_amount_minor', pay.paid_minor,
      'payment_status', case
        when sc.id is null then 'not_billed'
        when coalesce(pay.paid_minor, 0) >= sc.amount_minor
          and sc.amount_minor > 0 then 'settled'
        when coalesce(pay.paid_minor, 0) > 0 then 'partial'
        else 'unpaid'
      end,
      'has_charge', sc.id is not null,
      'has_invoice', inv.id is not null
    ),
    case
      when last_pay.id is null then null
      else jsonb_build_object(
        'method', last_pay.method,
        'reference', last_pay.public_code,
        'paid_at', last_pay.paid_at
      )
    end
  into v_session, v_payment
  from ops.irrigation_sessions s
  join ops.effective_session_facts ef on ef.session_id=s.id
  left join ops.farms f on f.id = s.farm_id
  left join ops.farmer_well_accounts fwa
    on fwa.id = coalesce(s.farmer_well_account_id, f.farmer_well_account_id)
  left join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
  left join core.persons per on per.id = fp.person_id
  left join core.pumps pm on pm.id = s.pump_id
  left join iam.profiles pr on pr.id = s.operator_profile_id
  left join billing.effective_session_charges sc on sc.session_id = s.id
  left join billing.invoices inv on inv.session_id = s.id
  left join lateral (
    select ss.energy_source
    from ops.session_segments ss
    where ss.session_id = s.id
      and ss.energy_source is not null
    order by ss.sequence_number
    limit 1
  ) run on true
  left join lateral (
    select
      count(*) as segment_count,
      sum(ss.actual_seconds)::bigint as segments_actual_seconds
    from ops.session_segments ss
    where ss.session_id = s.id
  ) seg on true
  left join lateral (
    select (select paid_minor from billing.session_read_settlements where session_charge_id=sc.id) as paid_minor
  ) pay on sc.id is not null
  left join lateral (
    select p.id, p.method, p.public_code, p.paid_at
    from billing.payments p
    join billing.payment_economic_applications econ on econ.payment_id=p.id
    where p.status = 'posted' and (
      (econ.default_session_charge_id=sc.id and econ.effective_direct_minor>0)
      or exists(select 1 from billing.effective_payment_allocations a
        join billing.invoices target on target.id=a.invoice_id
        where a.payment_id=p.id and target.session_id=s.id and a.effective_allocated_minor>0
          and econ.explicit_allocated_minor>0)
      or exists(select 1 from billing.effective_account_credit_applications a
        join billing.account_credits c on c.id=a.credit_id
        join billing.invoices target on target.id=a.invoice_id
        where c.payment_id=p.id and target.session_id=s.id and a.effective_amount_minor>0
          and econ.credit_backed_minor>0)
    )
    order by p.paid_at desc, p.id
    limit 1
  ) last_pay on sc.id is not null
  where s.id = p_session_id;

  -- الجلسة غير المرئية عبر RLS = رفض صريح بدل مغلّف فارغ غامض.
  if v_session is null then
    raise exception 'لا توجد صلاحية على هذه الجلسة'
      using errcode = '42501';
  end if;

  v_financial_revision:=coalesce((v_session->>'financial_applied_revision')::bigint,0);
  if v_financial_revision>0 then
    -- Read the last FINANCIALLY applied revision, which may trail the current
    -- operational revision. Never derive a new price or fall back to originals.
    select ch.id,ch.pricing_evidence into v_charge_id,v_pricing_evidence
    from billing.effective_session_charges ch
    where ch.session_id=p_session_id and ch.financial_applied_revision=v_financial_revision;
    if v_financial_revision>(v_session->>'operational_revision')::bigint
      or jsonb_typeof(v_pricing_evidence) is distinct from 'object'
      or jsonb_typeof(v_pricing_evidence->'segments') is distinct from 'array' then
      raise exception 'دليل المقاطع المالي المطبق غير مكتمل' using errcode='55000';
    end if;
    v_financial_segments:=v_pricing_evidence->'segments';
    if not exists (
      select 1 from billing.session_charge_corrections fc
      join ops.session_correction_reconciliations work on work.correction_id=fc.correction_id
      where fc.session_charge_id=v_charge_id and fc.session_id=p_session_id
        and fc.operational_revision=v_financial_revision
        and fc.pricing_evidence=v_pricing_evidence
        and work.session_id=p_session_id and work.operational_revision=v_financial_revision
        and work.status='applied' and work.financial_applied_revision=v_financial_revision
        and fc.correction_id::text=v_pricing_evidence->>'correction_id'
    ) then
      raise exception 'دليل المقاطع المالي المطبق غير مثبت' using errcode='55000';
    end if;
    -- Validate persisted shape, one-to-one segment identities and aggregates.
    -- Summation verifies evidence; no duration/rate multiplication occurs here.
    begin
      if (v_pricing_evidence->>'operational_revision')::bigint is distinct from v_financial_revision
        or v_pricing_evidence->>'original_charge_id' is distinct from v_charge_id::text
        or (v_pricing_evidence->>'amount_minor')::bigint is distinct from
             (v_session->>'total_amount_minor')::bigint
        or (v_pricing_evidence->>'billable_seconds')::bigint is distinct from
             (v_session->>'billable_seconds')::bigint
        or jsonb_array_length(v_financial_segments)=0
        or jsonb_array_length(v_financial_segments)<>(select count(*) from ops.session_segments
             where session_id=p_session_id)
        or exists (select 1 from jsonb_array_elements(v_financial_segments) e
             group by e->>'segment_id' having count(*)<>1)
        or exists (
          select 1 from jsonb_array_elements(v_financial_segments) e
          left join ops.session_segments original on original.id::text=e->>'segment_id'
            and original.session_id=p_session_id
          left join ops.session_corrections accepted on accepted.session_id=p_session_id
            and accepted.new_revision=v_financial_revision
          where original.id is null or jsonb_typeof(e) is distinct from 'object'
            or accepted.id is null
            or (e->>'sequence_number')::bigint is distinct from original.sequence_number
            or (e->>'effective_started_at')::timestamptz is distinct from
              case when original.sequence_number=1 then accepted.after_started_at else original.started_at end
            or (e->>'effective_ended_at')::timestamptz is distinct from
              case when original.sequence_number=(select max(sequence_number) from ops.session_segments
                where session_id=p_session_id) then accepted.after_ended_at else original.ended_at end
            or jsonb_typeof(e->'actual_seconds') is distinct from 'number'
            or (e->>'actual_seconds')::bigint is distinct from extract(epoch from
              ((e->>'effective_ended_at')::timestamptz-(e->>'effective_started_at')::timestamptz))::bigint
            or jsonb_typeof(e->'billable_seconds') is distinct from 'number'
            or jsonb_typeof(e->'time_charge_minor') is distinct from 'number'
            or (e->>'billable_seconds')::bigint<0 or (e->>'time_charge_minor')::bigint<0
            or ((e->>'rate_minor') is not null and jsonb_typeof(e->'rate_minor') is distinct from 'number')
            or (e->>'rate_minor')::bigint<0
            or (original.is_billable and
              (jsonb_typeof(e->'rate_minor') is distinct from 'number' or (e->>'rate_minor')::bigint<=0))
            or (not original.is_billable and
              ((e->>'billable_seconds')::bigint<>0 or (e->>'time_charge_minor')::bigint<>0))
        )
        or (select sum((e->>'time_charge_minor')::bigint) from jsonb_array_elements(v_financial_segments) e)
             is distinct from (v_session->>'total_amount_minor')::numeric
        or (select sum((e->>'billable_seconds')::bigint) from jsonb_array_elements(v_financial_segments) e)
             is distinct from (v_session->>'billable_seconds')::numeric then
        raise exception 'دليل المقاطع المالي المطبق غير متسق' using errcode='55000';
      end if;
    exception when invalid_text_representation or numeric_value_out_of_range
      or invalid_datetime_format or datetime_field_overflow then
      raise exception 'قيم دليل المقاطع المالي المطبق غير صالحة' using errcode='55000';
    end;
  end if;

  -- Same operational boundary substitution as C1 acceptance: only the first
  -- start and last end change. Internal execution boundaries stay pinned.
  with original_segments as (
    select ss.*,
      row_number() over(order by sequence_number) as n,
      count(*) over() as total,
      lag(ended_at) over(order by sequence_number) as prior_end
    from ops.session_segments ss where ss.session_id=p_session_id
  ), effective_segments as (
    select original_segments.*,
      case when n=1 then (v_session->>'effective_started_at')::timestamptz
        else started_at end as effective_started_at,
      case when n=total then (v_session->>'effective_ended_at')::timestamptz
        else ended_at end as effective_ended_at
    from original_segments
  )
  select coalesce(
           jsonb_agg(
             jsonb_build_object(
               'sequence_number', ss.sequence_number,
               'segment_type', ss.segment_type,
               'is_stop', ss.segment_type not in (
                 'solar_run', 'well_diesel_run', 'farmer_diesel_run'
               ),
               'is_billable', ss.is_billable,
               'energy_source', ss.energy_source,
               'original_started_at', ss.started_at,
               'original_ended_at', ss.ended_at,
               'started_at', ss.effective_started_at,
               'ended_at', ss.effective_ended_at,
               'actual_seconds', case when (v_session->>'operational_revision')::bigint>0
                 then extract(epoch from (ss.effective_ended_at-ss.effective_started_at))::bigint
                 else ss.actual_seconds end,
               'financial_evidence_basis', case when v_financial_revision>0
                 then 'applied_reconciliation' else 'original_execution' end,
               'financial_evidence_revision', v_financial_revision,
               'billable_seconds', case when v_financial_revision>0
                 then (financial.value->>'billable_seconds')::bigint else ss.billable_seconds end,
               'applied_rate_minor', case when v_financial_revision>0
                 then (financial.value->>'rate_minor')::bigint else coalesce(
                 ss.applied_operation_rate_minor,
                 ss.applied_hourly_rate_minor
               ) end,
               'time_charge_minor', case when v_financial_revision>0
                 then (financial.value->>'time_charge_minor')::bigint else ss.time_charge_minor end,
               -- C2 applied charge evidence is operation-only; its canonical
               -- financial_session_segments contract carries zero fuel charge.
               'fuel_charge_minor', case when v_financial_revision>0 then 0::bigint else ss.fuel_charge_minor end,
               'total_charge_minor', case when v_financial_revision>0
                 then (financial.value->>'time_charge_minor')::bigint else ss.total_charge_minor end,
               'notes', ss.notes
             )
             order by ss.sequence_number
           ),
           '[]'::jsonb
         ),
         count(*)=0
         -- Timeline validity uses exact numeric epoch durations. Independent
         -- bigint conversions belong only to presentation, never this check.
         or coalesce(sum(extract(epoch from (ss.effective_ended_at-ss.effective_started_at))),0::numeric)
              is distinct from extract(epoch from (
                (v_session->>'effective_ended_at')::timestamptz
                -(v_session->>'effective_started_at')::timestamptz))
         or coalesce(bool_or(
           ss.sequence_number<>ss.n
           or ss.started_at is null or ss.ended_at is null
           or not isfinite(ss.started_at) or not isfinite(ss.ended_at)
           or ss.started_at>=ss.ended_at
           or (ss.n=1 and ss.started_at is distinct from
               (v_session->>'original_started_at')::timestamptz)
           or (ss.n=ss.total and ss.ended_at is distinct from
               (v_session->>'original_ended_at')::timestamptz)
           or (ss.n>1 and ss.started_at is distinct from ss.prior_end)
           or ss.effective_started_at is null or ss.effective_ended_at is null
           or not isfinite(ss.effective_started_at) or not isfinite(ss.effective_ended_at)
           or ss.effective_started_at>=ss.effective_ended_at
         ),false)
  into v_segments,v_segments_invalid
  from effective_segments ss
  left join jsonb_array_elements(v_financial_segments) financial(value)
    on financial.value->>'segment_id'=ss.id::text;

  if (v_session->>'operational_revision')::bigint>0 and v_segments_invalid then
    raise exception 'مقاطع الجلسة المصححة غير متسقة' using errcode='55000';
  end if;

  -- المحاصيل كما اختيرت وقت بدء هذه الجلسة (لقطة مستقلة لا تتبع الأرض).
  select coalesce(
           jsonb_agg(sc.crop_name order by sc.position),
           '[]'::jsonb
         )
  into v_crops
  from ops.session_crops sc
  where sc.session_id = p_session_id;

  return jsonb_build_object(
    'contract', 'get_session_detail',
    'version', 1,
    'session', v_session,
    'segments', v_segments,
    'crops', v_crops,
    'payment', v_payment
  );
end;
$function$;

-- CREATE OR REPLACE preserves ACLs; state the API boundary explicitly.
revoke all on function api.get_session_detail(uuid),
 api.list_well_sessions(uuid,uuid,timestamptz,timestamptz,boolean,integer)
 from public,anon;
grant execute on function api.get_session_detail(uuid),
 api.list_well_sessions(uuid,uuid,timestamptz,timestamptz,boolean,integer)
 to authenticated,service_role;

commit;
