-- 090 — عقود قراءة الجلسات (م-41C2)
--
-- المشكلة التي تغلقها هذه الهجرة:
-- كان Flutter يقرأ سجل الجلسات وتفصيلها من ops وbilling مباشرة،
-- بأسماء أعمدة غير موجودة أصلًا (segment_index / duration_seconds /
-- hourly_rate_minor / is_paused / pause_reason)، ومن مخططات غير
-- مكشوفة في Data API. فكان كل نداء يفشل ويُستبدل ببيانات تجريبية.
--
-- القواعد المطبقة (ق-82 / ق-88 / ق-98 / ق-99):
-- 1. api.* تبقى SECURITY INVOKER بلا أي SECURITY DEFINER.
-- 2. لا جداول ولا Views داخل api — دوال فقط.
-- 3. التفويض من RLS القائمة، لا من وسيط يرسله العميل.
-- 4. لا وسيط جدول/مخطط ديناميكي، وحد النتائج مثبت، وanon محجوب.
-- 5. الترتيب حتمي: started_at تنازليًا ثم id.
-- 6. **لا حساب مال داخل عقد القراءة**: المبالغ تُقرأ كما خُزّنت في
--    billing.session_charges وops.session_segments وbilling.invoices.
--    الجلسة غير المفوترة تُعاد بمبلغ null وحالة 'not_billed'،
--    لا بصفر ولا بـ'settled' مصطنعة (ق-99 + القرار 341).
-- 7. النافذة الزمنية وسيط صريح من العميل (p_from / p_to) ولا تُفترض
--    منطقة زمنية للخادم: عقد حدود اليوم ما زال مسألة مفتوحة، ولا
--    يجوز اختراعه هنا.
-- 8. رموز segment_type وenergy_source تُعاد كما هي في قاعدة البيانات.
--    الترجمة العربية مسؤولية طبقة العرض بتخطيط صريح، لا Blind Remap.

begin;

-- ==============================================================
-- 1. سجل جلسات البئر
-- ==============================================================

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

  select coalesce(
           jsonb_agg(x.item order by x.started_at desc, x.id),
           '[]'::jsonb
         )
  into v_items
  from (
    select
      s.id,
      s.started_at,
      jsonb_build_object(
        'id', s.id,
        'well_id', s.well_id,
        'status', s.status,
        'started_at', s.started_at,
        'ended_at', s.ended_at,
        'farmer_well_account_id', fwa.id,
        'farmer_public_code', fwa.public_code,
        'farmer_name', per.full_name,
        'farm_id', f.id,
        'farm_name', f.name,
        'pump_id', pm.id,
        'pump_name', pm.name,
        'operator_name', pr.full_name,
        'energy_source', run.energy_source,
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
    left join billing.session_charges sc on sc.session_id = s.id
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
      -- المدفوع = ما خُزّن في الفاتورة إن وُجدت، وإلا مجموع الدفعات
      -- المرحّلة على تكلفة الجلسة. لا Netting ضمني ولا تقدير.
      select case
        when inv.id is not null then inv.paid_minor
        else (
          select coalesce(sum(p.amount_minor), 0)
          from billing.payments p
          where p.session_charge_id = sc.id
            and p.status = 'posted'
        )
      end as paid_minor
    ) pay on sc.id is not null
    where s.well_id = p_well_id
      and (
        p_farmer_well_account_id is null
        or fwa.id = p_farmer_well_account_id
      )
      and (p_from is null or s.started_at >= p_from)
      and (p_to is null or s.started_at < p_to)
      and (
        coalesce(p_unpaid_only, false) is not true
        or sc.id is null
        or coalesce(pay.paid_minor, 0) < sc.amount_minor
      )
    order by s.started_at desc, s.id
    limit v_limit
  ) x;

  return jsonb_build_object(
    'contract', 'list_well_sessions',
    'version', 1,
    'items', v_items
  );
end;
$function$;

revoke all on function api.list_well_sessions(
  uuid, uuid, timestamptz, timestamptz, boolean, integer
) from public, anon, authenticated, service_role;

grant execute on function api.list_well_sessions(
  uuid, uuid, timestamptz, timestamptz, boolean, integer
) to authenticated, service_role;

-- ==============================================================
-- 2. تفصيل جلسة واحدة مع مقاطعها
-- ==============================================================

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
  v_payment jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة تفصيل الجلسة'
      using errcode = '28000';
  end if;

  if p_session_id is null then
    raise exception 'معرّف الجلسة مطلوب'
      using errcode = '22023';
  end if;

  select
    jsonb_build_object(
      'id', s.id,
      'well_id', s.well_id,
      'status', s.status,
      'started_at', s.started_at,
      'ended_at', s.ended_at,
      'farmer_well_account_id', fwa.id,
      'farmer_public_code', fwa.public_code,
      'farmer_name', per.full_name,
      'farm_id', f.id,
      'farm_name', f.name,
      'pump_id', pm.id,
      'pump_name', pm.name,
      'operator_name', pr.full_name,
      'energy_source', run.energy_source,
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
  left join ops.farms f on f.id = s.farm_id
  left join ops.farmer_well_accounts fwa
    on fwa.id = coalesce(s.farmer_well_account_id, f.farmer_well_account_id)
  left join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
  left join core.persons per on per.id = fp.person_id
  left join core.pumps pm on pm.id = s.pump_id
  left join iam.profiles pr on pr.id = s.operator_profile_id
  left join billing.session_charges sc on sc.session_id = s.id
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
    select case
      when inv.id is not null then inv.paid_minor
      else (
        select coalesce(sum(p.amount_minor), 0)
        from billing.payments p
        where p.session_charge_id = sc.id
          and p.status = 'posted'
      )
    end as paid_minor
  ) pay on sc.id is not null
  left join lateral (
    select p.id, p.method, p.public_code, p.paid_at
    from billing.payments p
    where p.session_charge_id = sc.id
      and p.status = 'posted'
    order by p.paid_at desc, p.id
    limit 1
  ) last_pay on sc.id is not null
  where s.id = p_session_id;

  -- الجلسة غير المرئية عبر RLS = رفض صريح بدل مغلّف فارغ غامض.
  if v_session is null then
    raise exception 'لا توجد صلاحية على هذه الجلسة'
      using errcode = '42501';
  end if;

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
               'started_at', ss.started_at,
               'ended_at', ss.ended_at,
               'actual_seconds', ss.actual_seconds,
               'billable_seconds', ss.billable_seconds,
               'applied_rate_minor', coalesce(
                 ss.applied_operation_rate_minor,
                 ss.applied_hourly_rate_minor
               ),
               'time_charge_minor', ss.time_charge_minor,
               'fuel_charge_minor', ss.fuel_charge_minor,
               'total_charge_minor', ss.total_charge_minor,
               'notes', ss.notes
             )
             order by ss.sequence_number
           ),
           '[]'::jsonb
         )
  into v_segments
  from ops.session_segments ss
  where ss.session_id = p_session_id;

  return jsonb_build_object(
    'contract', 'get_session_detail',
    'version', 1,
    'session', v_session,
    'segments', v_segments,
    'payment', v_payment
  );
end;
$function$;

revoke all on function api.get_session_detail(uuid)
  from public, anon, authenticated, service_role;

grant execute on function api.get_session_detail(uuid)
  to authenticated, service_role;

commit;
