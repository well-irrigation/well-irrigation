begin;
-- Read-plan factoring only. No write contract, balance cache, or RLS bypass.
-- The unvalidated financial CTEs below retain the complete INVOKER-visible
-- context. NO session/payment filter is pushed into the cumulative windows.
-- Materialize shared evidence once; keep validation expressions lazy until a
-- requested settlement/payment uses them, as in the original views.
create function billing.session_read_financial_context(p_session_ids uuid[],p_include_latest boolean default false)
returns table(session_id uuid,session_charge_id uuid,paid_minor numeric,latest_payment jsonb)
language sql stable security invoker set search_path=pg_catalog,pg_temp as $context$
with
targets as materialized (select sc.id,sc.session_id from billing.session_charges sc where sc.session_id=any(p_session_ids)),
read_effective_payment_allocations as materialized (
SELECT pa.id,
    pa.tenant_id,
    pa.payment_id,
    pa.invoice_id,
    pa.allocated_minor,
    pa.created_at,
    pa.allocated_minor::numeric - COALESCE(x.released_minor, 0::numeric) + COALESCE(x.restored_minor, 0::numeric) AS effective_allocated_minor,
    COALESCE(x.released_minor, 0::numeric) - COALESCE(x.restored_minor, 0::numeric) AS released_minor
   FROM billing.payment_allocations pa
     LEFT JOIN LATERAL ( SELECT sum(x_1.amount_minor) FILTER (WHERE x_1.operation = 'release'::text) AS released_minor,
            sum(x_1.amount_minor) FILTER (WHERE x_1.operation = 'restore'::text) AS restored_minor
           FROM billing.payment_allocation_adjustments x_1
          WHERE x_1.allocation_id = pa.id) x ON true
),
read_effective_account_credit_applications as materialized (
SELECT a.id,
    a.tenant_id,
    a.well_id,
    a.farmer_well_account_id,
    a.credit_id,
    a.invoice_id,
    a.event_id,
    a.amount_minor,
    a.reason,
    a.created_by,
    a.created_at,
    COALESCE(x.released_minor, 0::numeric) AS released_minor,
    COALESCE(x.restored_minor, 0::numeric) AS restored_minor,
    a.amount_minor::numeric - COALESCE(x.released_minor, 0::numeric) + COALESCE(x.restored_minor, 0::numeric) AS effective_amount_minor
   FROM billing.account_credit_applications a
     LEFT JOIN LATERAL ( SELECT sum(x_1.amount_minor) FILTER (WHERE x_1.operation = 'release'::text) AS released_minor,
            sum(x_1.amount_minor) FILTER (WHERE x_1.operation = 'restore'::text) AS restored_minor
           FROM billing.account_credit_application_adjustments x_1
          WHERE x_1.application_id = a.id AND x_1.status = 'accepted'::text) x ON true
),
read_account_credit_balances as materialized (
SELECT c.id,
    c.tenant_id,
    c.well_id,
    c.farmer_well_account_id,
    c.payment_id,
    c.allocation_adjustment_id,
    c.event_id,
    c.source_type,
    c.source_id,
    c.origin_source_id,
    c.source_revision,
    c.amount_minor,
    c.reason,
    c.created_by,
    c.created_at,
    COALESCE(a.used_minor, 0::numeric) AS used_minor,
    COALESCE(r.restored_minor, 0::numeric) AS reversed_minor,
    COALESCE(r.held_minor, 0::numeric) AS held_minor,
    COALESCE(r.review_minor, 0::numeric) AS receivable_review_minor,
    c.amount_minor::numeric - COALESCE(a.used_minor, 0::numeric) - COALESCE(r.restored_minor, 0::numeric) - COALESCE(r.held_minor, 0::numeric) AS available_minor
   FROM billing.account_credits c
     LEFT JOIN LATERAL ( SELECT sum(a_1.effective_amount_minor) AS used_minor
           FROM read_effective_account_credit_applications a_1
          WHERE a_1.credit_id = c.id) a ON true
     LEFT JOIN LATERAL ( SELECT sum(r_1.restored_minor) AS restored_minor,
            sum(r_1.held_minor) AS held_minor,
            sum(r_1.receivable_review_minor) AS review_minor
           FROM billing.account_credit_reversals r_1
          WHERE r_1.credit_id = c.id) r ON true
),
read_payment_scope_evidence as materialized (
SELECT p.id,
    p.tenant_id,
    p.well_id,
    p.purpose,
    p.status,
    p.paid_at,
    p.amount_minor,
    p.session_charge_id,
    evidence.farmer_well_account_id,
    evidence.account_count = 1 AND COALESCE(evidence.scope_valid, true) AS scope_valid
   FROM billing.payments p
     LEFT JOIN LATERAL ( SELECT count(DISTINCT sources.account_id) AS account_count,
            (array_agg(DISTINCT sources.account_id) FILTER (WHERE sources.account_id IS NOT NULL))[1] AS farmer_well_account_id,
            bool_and(sources.source_tenant = p.tenant_id AND sources.source_well = p.well_id) AS scope_valid
           FROM ( SELECT p.farmer_well_account_id AS account_id,
                    p.tenant_id AS source_tenant,
                    p.well_id AS source_well
                UNION ALL
                 SELECT s.farmer_well_account_id,
                    w.tenant_id,
                    s.well_id
                   FROM billing.session_charges sc
                     JOIN ops.irrigation_sessions s ON s.id = sc.session_id
                     JOIN core.wells w ON w.id = s.well_id
                  WHERE sc.id = p.session_charge_id AND p.purpose = 'session'::text
                UNION ALL
                 SELECT i.farmer_well_account_id,
                    i.tenant_id,
                    i.well_id
                   FROM billing.invoices i
                     JOIN billing.session_charges sc ON sc.session_id = i.session_id
                  WHERE sc.id = p.session_charge_id AND p.purpose = 'session'::text AND (i.status <> ALL (ARRAY['cancelled'::text, 'reversed'::text]))
                UNION ALL
                 SELECT i.farmer_well_account_id,
                    i.tenant_id,
                    i.well_id
                   FROM billing.payment_allocations a
                     JOIN billing.invoices i ON i.id = a.invoice_id
                  WHERE a.payment_id = p.id) sources) evidence ON true
),
read_invoice_explicit_settlements as materialized (
SELECT i.id AS invoice_id,
    i.tenant_id,
    i.well_id,
    i.farmer_well_account_id,
    i.session_id,
    tot.total_minor,
    i.status,
    i.nonallocation_paid_minor::numeric + GREATEST(COALESCE(i.inserted_settlement_snapshot_minor, 0::bigint)::numeric - COALESCE(original_allocations.amount_minor, 0::numeric), 0::numeric) + COALESCE(a.amount_minor, 0::numeric) + COALESCE(c.amount_minor, 0::numeric) + COALESCE(legacy.non_cash_settled_minor, 0::bigint)::numeric + COALESCE(dist.amount_minor, 0::numeric) AS explicitly_settled_minor,
    (EXISTS ( SELECT 1
           FROM core.wells w
             JOIN ops.farmer_well_accounts fa ON fa.well_id = w.id AND fa.tenant_id = w.tenant_id
          WHERE w.id = i.well_id AND w.tenant_id = i.tenant_id AND fa.id = i.farmer_well_account_id)) AND COALESCE(a.scope_valid, true) AND COALESCE(c.scope_valid, true) AND (i.session_id IS NULL OR (EXISTS ( SELECT 1
           FROM ops.irrigation_sessions sess
          WHERE sess.id = i.session_id AND sess.well_id = i.well_id AND (sess.farmer_well_account_id IS NULL OR sess.farmer_well_account_id = i.farmer_well_account_id)))) AND NOT (EXISTS ( SELECT 1
           FROM billing.invoice_lines l
             JOIN ops.session_segments seg ON seg.id = l.session_segment_id
          WHERE l.invoice_id = i.id AND (l.tenant_id <> i.tenant_id OR i.session_id IS NULL OR seg.session_id <> i.session_id))) AS scope_valid
   FROM billing.invoices i
     JOIN billing.effective_invoice_totals tot ON tot.id = i.id
     LEFT JOIN LATERAL ( SELECT sum(payment_allocations.allocated_minor) AS amount_minor
           FROM billing.payment_allocations
          WHERE payment_allocations.invoice_id = i.id) original_allocations ON true
     LEFT JOIN LATERAL ( SELECT sum(a_1.effective_allocated_minor) AS amount_minor,
            bool_and(p.scope_valid AND p.tenant_id = i.tenant_id AND p.well_id = i.well_id AND p.farmer_well_account_id = i.farmer_well_account_id AND (p.purpose = 'session'::text OR p.session_charge_id IS NULL) AND a_1.tenant_id = i.tenant_id AND a_1.effective_allocated_minor >= 0::numeric AND a_1.effective_allocated_minor <= a_1.allocated_minor::numeric) AS scope_valid
           FROM read_effective_payment_allocations a_1
             JOIN read_payment_scope_evidence p ON p.id = a_1.payment_id
          WHERE a_1.invoice_id = i.id AND p.status = 'posted'::text) a ON true
     LEFT JOIN LATERAL ( SELECT sum(c_1.effective_amount_minor) AS amount_minor,
            bool_and(c_1.tenant_id = i.tenant_id AND c_1.well_id = i.well_id AND c_1.farmer_well_account_id = i.farmer_well_account_id AND src.tenant_id = i.tenant_id AND src.well_id = i.well_id AND src.farmer_well_account_id = i.farmer_well_account_id AND p.status = 'posted'::text AND c_1.effective_amount_minor >= 0::numeric AND c_1.effective_amount_minor <= c_1.amount_minor::numeric) AS scope_valid
           FROM read_effective_account_credit_applications c_1
             JOIN billing.account_credits src ON src.id = c_1.credit_id
             JOIN billing.payments p ON p.id = src.payment_id
          WHERE c_1.invoice_id = i.id) c ON true
     LEFT JOIN billing.legacy_invoice_review_effects legacy ON legacy.invoice_id = i.id
     LEFT JOIN LATERAL ( SELECT sum(distribution_source_consumptions.amount_minor) AS amount_minor
           FROM finance.distribution_source_consumptions
          WHERE distribution_source_consumptions.invoice_id = i.id) dist ON true
),
read_default_session_debts as materialized (
SELECT sc.id AS session_charge_id,
    sc.session_id,
    sc.well_id,
    scope.farmer_well_account_id,
    COALESCE(i.total_minor, sc.amount_minor::numeric) AS debt_minor,
    COALESCE(i.settled_minor, 0::numeric) AS explicitly_settled_minor,
    GREATEST(COALESCE(i.total_minor, sc.amount_minor::numeric) - COALESCE(i.settled_minor, 0::numeric), 0::numeric) AS remaining_before_direct_minor,
    s.well_id = sc.well_id AND scope.account_count <= 1 AND COALESCE(i.invoice_count, 0::bigint) <= 1 AND COALESCE(i.scope_valid, true) AS scope_valid
   FROM billing.approved_session_charges sc
     JOIN ops.irrigation_sessions s ON s.id = sc.session_id
     LEFT JOIN LATERAL ( SELECT count(DISTINCT evidence.account_id) AS account_count,
            (array_agg(DISTINCT evidence.account_id) FILTER (WHERE evidence.account_id IS NOT NULL))[1] AS farmer_well_account_id
           FROM ( SELECT s.farmer_well_account_id AS account_id
                UNION ALL
                 SELECT p.farmer_well_account_id
                   FROM billing.payments p
                  WHERE p.session_charge_id = sc.id AND p.purpose = 'session'::text AND p.status = 'posted'::text
                UNION ALL
                 SELECT inv.farmer_well_account_id
                   FROM billing.invoices inv
                  WHERE inv.session_id = s.id AND (inv.status <> ALL (ARRAY['cancelled'::text, 'reversed'::text]))) evidence) scope ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS invoice_count,
            sum(x.total_minor) AS total_minor,
            sum(x.explicitly_settled_minor) AS settled_minor,
            bool_and(x.scope_valid AND x.well_id = sc.well_id AND x.farmer_well_account_id = scope.farmer_well_account_id AND x.tenant_id = (( SELECT wells.tenant_id
                   FROM core.wells
                  WHERE wells.id = sc.well_id))) AS scope_valid
           FROM read_invoice_explicit_settlements x
          WHERE x.session_id = sc.session_id AND (x.status <> ALL (ARRAY['draft'::text, 'cancelled'::text, 'reversed'::text]))) i ON true
),
read_payment_partition_inputs as materialized (
SELECT p.id AS payment_id,
    p.tenant_id,
    p.well_id,
    p.farmer_well_account_id,
    p.purpose,
    p.status,
    p.paid_at,
    p.amount_minor,
        CASE
            WHEN p.purpose = 'session'::text THEN p.session_charge_id
            ELSE NULL::uuid
        END AS default_session_charge_id,
    COALESCE(a.amount_minor, 0::numeric) AS allocated_minor,
    COALESCE(c.amount_minor, 0::numeric) AS credit_backed_minor,
    p.amount_minor::numeric - COALESCE(a.amount_minor, 0::numeric) - COALESCE(c.amount_minor, 0::numeric) AS capacity_minor,
    d.remaining_before_direct_minor,
    p.scope_valid AND (EXISTS ( SELECT 1
           FROM core.wells w
          WHERE w.id = p.well_id AND w.tenant_id = p.tenant_id)) AND (EXISTS ( SELECT 1
           FROM ops.farmer_well_accounts fa
          WHERE fa.id = p.farmer_well_account_id AND fa.tenant_id = p.tenant_id AND fa.well_id = p.well_id)) AND COALESCE(a.scope_valid, true) AND COALESCE(c.scope_valid, true) AND (p.purpose = 'session'::text OR p.session_charge_id IS NULL) AND (p.purpose <> 'session'::text OR d.session_charge_id IS NOT NULL AND d.well_id = p.well_id AND d.farmer_well_account_id = p.farmer_well_account_id AND d.scope_valid) AND (p.amount_minor::numeric - COALESCE(a.amount_minor, 0::numeric) - COALESCE(c.amount_minor, 0::numeric)) >= 0::numeric AS scope_valid
   FROM read_payment_scope_evidence p
     LEFT JOIN LATERAL ( SELECT sum(pa.effective_allocated_minor) AS amount_minor,
            bool_and(ix.scope_valid AND pa.tenant_id = p.tenant_id AND i.tenant_id = p.tenant_id AND i.well_id = p.well_id AND i.farmer_well_account_id = p.farmer_well_account_id AND pa.effective_allocated_minor >= 0::numeric AND pa.effective_allocated_minor <= pa.allocated_minor::numeric) AS scope_valid
           FROM read_effective_payment_allocations pa
             JOIN billing.invoices i ON i.id = pa.invoice_id
             JOIN read_invoice_explicit_settlements ix ON ix.invoice_id = i.id
          WHERE pa.payment_id = p.id) a ON true
     LEFT JOIN LATERAL ( SELECT sum(c_1.amount_minor::numeric - c_1.reversed_minor) AS amount_minor,
            bool_and(c_1.tenant_id = p.tenant_id AND c_1.well_id = p.well_id AND c_1.farmer_well_account_id = p.farmer_well_account_id AND c_1.amount_minor::numeric >= c_1.reversed_minor AND c_1.available_minor >= 0::numeric) AS scope_valid
           FROM read_account_credit_balances c_1
          WHERE c_1.payment_id = p.id) c ON true
     LEFT JOIN read_default_session_debts d ON d.session_charge_id = p.session_charge_id
  WHERE p.status = 'posted'::text
),
read_economic_raw as materialized (
WITH capacities AS (
         SELECT x.payment_id,
            x.tenant_id,
            x.well_id,
            x.farmer_well_account_id,
            x.purpose,
            x.status,
            x.paid_at,
            x.amount_minor,
            x.default_session_charge_id,
            x.allocated_minor,
            x.credit_backed_minor,
            x.capacity_minor,
            x.remaining_before_direct_minor,
            x.scope_valid,
            x.capacity_minor AS checked_capacity,
            bool_and(x.scope_valid) OVER (PARTITION BY (COALESCE(x.default_session_charge_id, x.payment_id))) AS group_valid,
            sum(
                CASE
                    WHEN x.default_session_charge_id IS NOT NULL THEN x.capacity_minor
                    ELSE 0::numeric
                END) OVER (PARTITION BY (COALESCE(x.default_session_charge_id, x.payment_id)) ORDER BY x.paid_at, x.payment_id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS preceding_capacity
           FROM read_payment_partition_inputs x
        ), settled AS (
         SELECT capacities.payment_id,
            capacities.tenant_id,
            capacities.well_id,
            capacities.farmer_well_account_id,
            capacities.purpose,
            capacities.status,
            capacities.paid_at,
            capacities.amount_minor,
            capacities.default_session_charge_id,
            capacities.allocated_minor,
            capacities.credit_backed_minor,
            capacities.capacity_minor,
            capacities.remaining_before_direct_minor,
            capacities.scope_valid,
            capacities.checked_capacity,
            capacities.group_valid,
            capacities.preceding_capacity,
                CASE
                    WHEN capacities.default_session_charge_id IS NOT NULL THEN LEAST(capacities.checked_capacity, GREATEST(capacities.remaining_before_direct_minor - COALESCE(capacities.preceding_capacity, 0::numeric), 0::numeric))
                    ELSE 0::numeric
                END AS direct_minor
           FROM capacities
        )
 select * from settled
),
read_payment_economic_applications as not materialized (

 SELECT payment_id,
    tenant_id,
    well_id,
    farmer_well_account_id,
    purpose,
    status,
    paid_at,
    amount_minor,
    default_session_charge_id,
    billing.require_valid_payment_partition(scope_valid AND group_valid, allocated_minor) AS explicit_allocated_minor,
    billing.require_valid_payment_partition(scope_valid AND group_valid, credit_backed_minor) AS credit_backed_minor,
    billing.require_valid_payment_partition(scope_valid AND group_valid, checked_capacity) AS direct_capacity_minor,
    billing.require_valid_payment_partition(scope_valid AND group_valid, direct_minor) AS effective_direct_minor,
    billing.require_valid_payment_partition(scope_valid AND group_valid, checked_capacity - direct_minor) AS remaining_minor
   FROM read_economic_raw
),
read_session_economic_settlements as not materialized (
SELECT d.session_charge_id,
    d.session_id,
    d.well_id,
    d.farmer_well_account_id,
    d.debt_minor,
    d.explicitly_settled_minor,
    d.remaining_before_direct_minor,
    d.scope_valid,
    COALESCE(p.direct_minor, 0::numeric) AS direct_settled_minor,
    billing.require_valid_payment_partition(d.scope_valid, d.explicitly_settled_minor + COALESCE(p.direct_minor, 0::numeric)) AS settled_minor,
    billing.require_valid_payment_partition(d.scope_valid, GREATEST(d.debt_minor - d.explicitly_settled_minor - COALESCE(p.direct_minor, 0::numeric), 0::numeric)) AS outstanding_minor
   FROM read_default_session_debts d
     LEFT JOIN LATERAL ( SELECT sum(p_1.effective_direct_minor) AS direct_minor
           FROM read_payment_economic_applications p_1
          WHERE p_1.default_session_charge_id = d.session_charge_id) p ON true
),
read_invoice_effective_balances as not materialized (
SELECT i.id AS invoice_id,
    i.well_id,
    i.tenant_id,
    i.farmer_well_account_id,
    x.total_minor,
    billing.require_valid_payment_partition(x.scope_valid, x.explicitly_settled_minor + COALESCE(d.direct_settled_minor, 0::numeric)) AS paid_minor,
    billing.require_valid_payment_partition(x.scope_valid, x.total_minor::numeric - x.explicitly_settled_minor - COALESCE(d.direct_settled_minor, 0::numeric)) AS outstanding_minor,
        CASE
            WHEN quarantine.unknown_use THEN GREATEST(x.total_minor::numeric - x.explicitly_settled_minor - COALESCE(d.direct_settled_minor, 0::numeric), 0::numeric)
            ELSE LEAST(COALESCE(legacy.disputed_minor, 0::bigint)::numeric, GREATEST(x.total_minor::numeric - x.explicitly_settled_minor - COALESCE(d.direct_settled_minor, 0::numeric), 0::numeric))
        END AS collection_hold_minor,
        CASE
            WHEN quarantine.unknown_use THEN 0::bigint::numeric
            ELSE GREATEST(x.total_minor::numeric - x.explicitly_settled_minor - COALESCE(d.direct_settled_minor, 0::numeric) - COALESCE(legacy.disputed_minor, 0::bigint)::numeric, 0::numeric)
        END AS collectible_minor
   FROM billing.invoices i
     JOIN read_invoice_explicit_settlements x ON x.invoice_id = i.id
     LEFT JOIN read_session_economic_settlements d ON d.session_id = i.session_id AND (i.status <> ALL (ARRAY['draft'::text, 'cancelled'::text, 'reversed'::text]))
     LEFT JOIN billing.legacy_invoice_review_effects legacy ON legacy.invoice_id = i.id
     LEFT JOIN LATERAL ( SELECT (EXISTS ( SELECT 1
                   FROM finance.distribution_sources s
                  WHERE s.invoice_id = i.id AND s.legacy_review_required AND NOT (EXISTS ( SELECT 1
                           FROM billing.legacy_invoice_accounting_reviews r
                          WHERE r.invoice_id = i.id)))) AS unknown_use) quarantine ON true
),
read_session_read_settlements as not materialized (
SELECT sc.id AS session_charge_id,
    sc.session_id,
        CASE
            WHEN i.id IS NOT NULL THEN b.paid_minor
            ELSE d.settled_minor
        END AS paid_minor
   FROM billing.session_charges sc
     LEFT JOIN billing.invoices i ON i.session_id = sc.session_id
     LEFT JOIN read_invoice_effective_balances b ON b.invoice_id = i.id
     LEFT JOIN read_session_economic_settlements d ON d.session_charge_id = sc.id
)
select t.session_id,t.id,
 (select s.paid_minor from read_session_read_settlements s where s.session_charge_id=t.id),
 case when last_pay.id is null then null else jsonb_build_object(
  'method',last_pay.method,'reference',last_pay.public_code,'paid_at',last_pay.paid_at) end
from targets t
left join lateral (
select p.id,p.method,p.public_code,p.paid_at
 from billing.payments p
 join read_payment_economic_applications econ on econ.payment_id=p.id
 where p_include_latest and p.status='posted' and (
 (econ.default_session_charge_id=t.id and econ.effective_direct_minor>0)
 or exists(select 1 from read_effective_payment_allocations a
  join billing.invoices target on target.id=a.invoice_id
  where a.payment_id=p.id and target.session_id=t.session_id and a.effective_allocated_minor>0
   and econ.explicit_allocated_minor>0)
 or exists(select 1 from read_effective_account_credit_applications a
  join billing.account_credits c on c.id=a.credit_id
  join billing.invoices target on target.id=a.invoice_id
  where c.payment_id=p.id and target.session_id=t.session_id and a.effective_amount_minor>0
   and econ.credit_backed_minor>0))
 order by p.paid_at desc,p.id limit 1
) last_pay on p_include_latest;
$context$;
revoke all on function billing.session_read_financial_context(uuid[],boolean) from public,anon,authenticated,service_role;
grant execute on function billing.session_read_financial_context(uuid[],boolean) to authenticated,service_role;
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

  with target_sessions as materialized (
    select s.id,ef.effective_started_at
    from ops.irrigation_sessions s
    join ops.effective_session_facts ef on ef.session_id=s.id
    left join ops.farms f on f.id=s.farm_id
    left join ops.farmer_well_accounts fwa
      on fwa.id=coalesce(s.farmer_well_account_id,f.farmer_well_account_id)
    where s.well_id=p_well_id
      and (p_farmer_well_account_id is null or fwa.id=p_farmer_well_account_id)
      and (p_from is null or ef.effective_started_at>=p_from)
      and (p_to is null or ef.effective_started_at<p_to)
    order by ef.effective_started_at desc,s.id
    limit case when coalesce(p_unpaid_only,false) then null::integer else v_limit end
  ), financial as materialized (
    select * from billing.session_read_financial_context(
      array(select id from target_sessions),false)
  )
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
        'original_amount_minor',sc.original_amount_minor,'system_amount_minor',sc.system_amount_minor,
      'approved_amount_minor',sc.approved_amount_minor,'manual_approval_revision',sc.manual_approval_revision,
      'total_amount_minor', sc.amount_minor,
        'paid_amount_minor', pay.paid_minor,
        'payment_status', case
          when sc.id is null then 'not_billed'
          when coalesce(pay.paid_minor, 0) >= sc.amount_minor then 'settled'
          when coalesce(pay.paid_minor, 0) > 0 then 'partial'
          else 'unpaid'
        end,
        'has_charge', sc.id is not null,
        'has_invoice', inv.id is not null
      ) as item
    from target_sessions target
    join ops.irrigation_sessions s on s.id=target.id
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
    left join billing.approved_session_charges sc on sc.session_id = s.id
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
    left join financial pay on pay.session_charge_id=sc.id
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

  with target_sessions as materialized (
    select s.* from ops.irrigation_sessions s where s.id=p_session_id
  ), financial as materialized (
    select * from billing.session_read_financial_context(
      array(select id from target_sessions),true)
  )
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
      'original_amount_minor',sc.original_amount_minor,'system_amount_minor',sc.system_amount_minor,
      'approved_amount_minor',sc.approved_amount_minor,'manual_approval_revision',sc.manual_approval_revision,
      'total_amount_minor', sc.amount_minor,
      'paid_amount_minor', pay.paid_minor,
      'payment_status', case
        when sc.id is null then 'not_billed'
        when coalesce(pay.paid_minor, 0) >= sc.amount_minor then 'settled'
        when coalesce(pay.paid_minor, 0) > 0 then 'partial'
        else 'unpaid'
      end,
      'has_charge', sc.id is not null,
      'has_invoice', inv.id is not null
    ),
    pay.latest_payment
  into v_session, v_payment
  from target_sessions s
  join ops.effective_session_facts ef on ef.session_id=s.id
  left join ops.farms f on f.id = s.farm_id
  left join ops.farmer_well_accounts fwa
    on fwa.id = coalesce(s.farmer_well_account_id, f.farmer_well_account_id)
  left join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
  left join core.persons per on per.id = fp.person_id
  left join core.pumps pm on pm.id = s.pump_id
  left join iam.profiles pr on pr.id = s.operator_profile_id
  left join billing.approved_session_charges sc on sc.session_id = s.id
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
  left join financial pay on pay.session_charge_id=sc.id
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
             (v_session->>'system_amount_minor')::bigint
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
             is distinct from (v_session->>'system_amount_minor')::numeric
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

  -- Base visibility and all effective/financial validation have already passed.
  v_session := v_session || ops.session_correction_capabilities_read(p_session_id);

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


commit;
