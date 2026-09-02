-- 092 — عقود القراءة المالية وعقد مؤشرات التقارير (م-41D2)
--
-- المشكلة التي تغلقها هذه الهجرة:
-- الشاشات المالية في Flutter لم تقرأ بيانات حقيقية ولا مرة واحدة. خمس
-- قراءات تستعمل from('schema.table') على مخططات غير مكشوفة في
-- PostgREST، وكل واحدة ملفوفة بـ catch(_) يُرجع بيانات تجريبية،
-- فالفشل يظهر للمستخدم نجاحًا.
--
-- أدلة جُمعت قبل الكتابة (لا Blind Remap):
-- أ) iam.well_memberships الذي تقرأه شاشة الشركاء لا وجود له في أي من
--    الهجرات التسعين. مصدر الشركاء الحقيقي core.well_partners،
--    والنِسَب في core.ownership_share_versions، والمال في
--    finance.profit_distribution_lines.
-- ب) billing.invoices لا تحتوي issue_date؛ العمود اسمه invoice_date.
-- ج) لا يوجد public.farms إطلاقًا؛ الأراضي في ops.farms، وربطها
--    بالفاتورة يمر عبر ops.irrigation_sessions.farm_id.
-- د) محلّلات JSON في العميل تنتظر مفاتيح لا ينتجها أي جدول خام
--    (category_code / category_name / partner_name / recorded_by_name /
--    distributable_profit_minor / invoice_number / farm_name /
--    allocated_invoices)، أي أنها كُتبت لعقد لم يُبنَ قط. هذه الهجرة
--    تبني ذلك العقد بالأسماء نفسها مقابل أعمدة حقيقية.
-- هـ) الأرقام التي كان العميل يلفّقها موجودة محسوبة في مخطط reporting
--    منذ هجرة 060 بعروض security_invoker: partner_account_summary
--    وfarmer_account_balances. والمدفوع فعلًا للشريك عمود حقيقي
--    (paid_minor) أضافته هجرة 068.
--
-- القواعد المطبقة (ق-82 / ق-88 / ق-98 / ق-99 / ق-113):
-- 1. api.* تبقى SECURITY INVOKER، دوال فقط بلا جداول ولا Views.
-- 2. التفويض من السلطة القائمة: RLS، والرفض صريح 42501 لا قائمة فارغة.
-- 3. 28000 بلا جلسة، و22023 لكل مدخل غير صالح.
-- 4. الحدود مثبتة ومقصوصة، والترتيب حتمي في كل قائمة وكل قائمة داخلية.
-- 5. لا حساب مال جديد داخل عقد قراءة: كل مبلغ يُقرأ من عمود أو من عرض
--    reporting قائم. التحويل إلى ليتر أو ساعة أو نسبة مئوية أو تسمية
--    عربية مسؤولية طبقة العرض وحدها.
-- 6. anon محجوب: revoke all ثم grant لـ authenticated وservice_role.
--
-- استثناء واحد مقصود من القاعدة 5: remaining_minor في سطر توزيع الشريك
-- يُعاد كفرق net_payable_minor − paid_minor، وهو التعريف نفسه الذي
-- تفرضه هجرة 068 داخل finance.pay_partner_distribution وتبني عليه قبول
-- الدفعة أو رفضها. فهو ثابت مجالي لا تجميل عرض. أما «صافي التدفق»
-- (المحصّل ناقص المصروف) فلا يُعاد هنا: تحسبه طبقة العرض من رقمين
-- مُعادين، لأنه تجميع عرضي لا ثابت مجالي.
--
-- حدّ معروف ومسجَّل: لا عمود منطقة زمنية في core.wells، فحدود اليوم
-- تُحسب بـ date_trunc على UTC تمامًا كما في عرض well_daily_summary.
-- توحيد حدود اليوم على منطقة البئر بند مفتوح مستقل في OPEN_ISSUES.
-- وأسبوع التقارير يبدأ السبت (العُرف المحلي) لا الاثنين، وهو محسوب
-- صريحًا لا متروكًا لـ date_trunc('week').

begin;

-- ==============================================================
-- 1. مصروفات البئر
--
-- كانت: from('finance.expenses').select('*, finance.expense_categories(name_ar)')
-- وهي مستحيلة النجاح مرتين: المخطط غير مكشوف، وصيغة التضمين
-- المنقوطة ليست صيغة PostgREST. اسم الفئة يأتي هنا من انضمام حقيقي.
-- ==============================================================

create or replace function api.list_well_expenses(
  p_well_id uuid,
  p_status text default null,
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_status text := nullif(btrim(coalesce(p_status, '')), '');
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 500);
  v_items jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة المصروفات'
      using errcode = '28000';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  -- الحالات هي حالات finance.expenses الحقيقية لا قائمة مخترعة.
  if v_status is not null and v_status not in (
    'draft', 'pending_approval', 'approved', 'rejected', 'posted', 'reversed'
  ) then
    raise exception 'حالة مصروف غير معروفة: %', v_status
      using errcode = '22023';
  end if;

  if not exists (
    select 1
    from core.wells w
    where w.id = p_well_id
  ) then
    raise exception 'لا توجد صلاحية على هذا البئر'
      using errcode = '42501';
  end if;

  select coalesce(
    jsonb_agg(x.item order by x.spent_at desc, x.id desc),
    '[]'::jsonb
  )
  into v_items
  from (
    select
      e.id,
      e.spent_at,
      jsonb_build_object(
        'id', e.id,
        'well_id', e.well_id,
        'public_code', e.public_code,
        'category_code', ec.code,
        'category_name', ec.name_ar,
        'amount_minor', e.amount_minor,
        'description', e.description,
        'status', e.status,
        'spent_at', e.spent_at,
        'payment_source', e.payment_source,
        'partner_id', e.partner_id,
        'partner_name', pp.full_name,
        'attachment_url', e.attachment_url,
        'attachment_skipped', e.attachment_skipped,
        'skip_reason', e.attachment_skip_reason,
        'recorded_by_name', pf.full_name
      ) as item
    from finance.expenses e
    left join finance.expense_categories ec on ec.id = e.category_id
    left join core.well_partners wp on wp.id = e.partner_id
    left join core.persons pp on pp.id = wp.person_id
    left join iam.profiles pf on pf.id = e.created_by
    where e.well_id = p_well_id
      and (v_status is null or e.status = v_status)
    order by e.spent_at desc, e.id desc
    limit v_limit
  ) x;

  return jsonb_build_object(
    'contract', 'list_well_expenses',
    'version', 1,
    'well_id', p_well_id,
    'expenses', v_items
  );
end;
$function$;

revoke all on function api.list_well_expenses(uuid, text, integer)
  from public, anon, authenticated, service_role;

grant execute on function api.list_well_expenses(uuid, text, integer)
  to authenticated, service_role;

-- ==============================================================
-- 2. شركاء البئر وحساباتهم
--
-- كانت: from('iam.well_memberships') — جدول لا وجود له، فالنداء يفشل
-- دائمًا وتُعرض أرقام ثابتة دائمًا. وحتى عند «النجاح» كان المستودع
-- يحشر total_earnings_minor = 180000 وout_of_pocket = 25000
-- وirrigation_deduction = 35000 وtotal_paid = 100000 في كل صف،
-- ويثبّت النسبتين على 25 لكل شريك.
--
-- الحقيقة: النِسَب نسخة سارية في core.ownership_share_versions
-- (effective_period @> current_date)، والمال مجموع أسطر التوزيع
-- كما يعرّفه عرض reporting.partner_account_summary، والمدفوع فعلًا
-- مجموع paid_minor. لا رقم واحد مخترع هنا.
-- ==============================================================

create or replace function api.list_well_partners(
  p_well_id uuid,
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 200);
  v_items jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة الشركاء'
      using errcode = '28000';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  if not exists (
    select 1
    from core.wells w
    where w.id = p_well_id
  ) then
    raise exception 'لا توجد صلاحية على هذا البئر'
      using errcode = '42501';
  end if;

  select coalesce(
    jsonb_agg(x.item order by x.full_name, x.id),
    '[]'::jsonb
  )
  into v_items
  from (
    select
      wp.id,
      p.full_name,
      jsonb_build_object(
        'id', wp.id,
        'partner_person_id', wp.person_id,
        'full_name', p.full_name,
        'phone', wp.phone,
        'ownership_percent', v.ownership_percentage,
        'profit_percent', v.profit_percentage,
        'total_earnings_minor', coalesce(s.gross_earned_minor, 0),
        'out_of_pocket_minor', coalesce(s.expenses_paid_minor, 0),
        'irrigation_deduction_minor', coalesce(s.irrigation_deducted_minor, 0),
        'net_payable_minor', coalesce(s.net_payable_minor, 0),
        'unpaid_minor', coalesce(s.unpaid_minor, 0),
        'total_paid_minor', coalesce(paid.paid_total, 0),
        'status', wp.status,
        'period_start', wp.period_start,
        'period_end', wp.period_end
      ) as item
    from core.well_partners wp
    join core.persons p on p.id = wp.person_id
    left join reporting.partner_account_summary s on s.partner_id = wp.id
    left join lateral (
      select vv.ownership_percentage, vv.profit_percentage
      from core.ownership_share_versions vv
      where vv.partner_id = wp.id
        and vv.effective_period @> current_date
      order by lower(vv.effective_period) desc
      limit 1
    ) v on true
    left join lateral (
      select sum(l.paid_minor) as paid_total
      from finance.profit_distribution_lines l
      join finance.profit_distribution_cycles c
        on c.id = l.distribution_cycle_id
      where l.partner_id = wp.id
        and c.status <> 'cancelled'
    ) paid on true
    where wp.well_id = p_well_id
    order by p.full_name, wp.id
    limit v_limit
  ) x;

  return jsonb_build_object(
    'contract', 'list_well_partners',
    'version', 1,
    'well_id', p_well_id,
    'partners', v_items
  );
end;
$function$;

revoke all on function api.list_well_partners(uuid, integer)
  from public, anon, authenticated, service_role;

grant execute on function api.list_well_partners(uuid, integer)
  to authenticated, service_role;

-- ==============================================================
-- 3. دورات توزيع الأرباح وأسطرها
--
-- كانت: from('finance.profit_distribution_cycles') على مخطط غير مكشوف،
-- ثم يقرأ العميل مفاتيح لا تطابق الأعمدة أصلًا. التخطيط الصحيح:
--   eligible_revenue_minor      ← eligible_collections_minor
--   eligible_expenses_minor     ← eligible_cash_expenses_minor
--   retained_liabilities_minor  ← reserved_liabilities_minor
--   distributable_profit_minor  ← distributable_amount_minor
-- والأسطر من finance.profit_distribution_lines لا من جدول مخترع.
-- ==============================================================

create or replace function api.list_well_profit_cycles(
  p_well_id uuid,
  p_limit integer default 24
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_limit integer := least(greatest(coalesce(p_limit, 24), 1), 120);
  v_items jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة دورات التوزيع'
      using errcode = '28000';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  if not exists (
    select 1
    from core.wells w
    where w.id = p_well_id
  ) then
    raise exception 'لا توجد صلاحية على هذا البئر'
      using errcode = '42501';
  end if;

  select coalesce(
    jsonb_agg(x.item order by x.period_start desc, x.id desc),
    '[]'::jsonb
  )
  into v_items
  from (
    select
      c.id,
      c.period_start,
      jsonb_build_object(
        'id', c.id,
        'well_id', c.well_id,
        'public_code', c.public_code,
        'period_start', c.period_start,
        'period_end', c.period_end,
        'status', c.status,
        'eligible_revenue_minor', c.eligible_collections_minor,
        'eligible_expenses_minor', c.eligible_cash_expenses_minor,
        'retained_liabilities_minor', c.reserved_liabilities_minor,
        'maintenance_reserve_minor', c.maintenance_reserve_minor,
        'distributable_profit_minor', c.distributable_amount_minor,
        'calculated_at', c.calculated_at,
        'approved_at', c.approved_at,
        'partner_lines', (
          select coalesce(
            jsonb_agg(li.item order by li.full_name, li.line_id),
            '[]'::jsonb
          )
          from (
            select
              l.id as line_id,
              pn.full_name,
              jsonb_build_object(
                'line_id', l.id,
                'partner_id', l.partner_id,
                'partner_name', pn.full_name,
                'profit_percent', l.profit_percentage_snapshot,
                'gross_share_minor', l.gross_share_minor,
                'out_of_pocket_minor', l.partner_receivables_minor,
                'irrigation_deduction_minor', l.irrigation_deductions_minor,
                'other_deductions_minor', l.other_deductions_minor,
                'net_share_minor', l.net_payable_minor,
                'paid_amount_minor', l.paid_minor,
                'remaining_minor', l.net_payable_minor - l.paid_minor,
                'payout_status', l.status
              ) as item
            from finance.profit_distribution_lines l
            join core.well_partners wp2 on wp2.id = l.partner_id
            join core.persons pn on pn.id = wp2.person_id
            where l.distribution_cycle_id = c.id
          ) li
        )
      ) as item
    from finance.profit_distribution_cycles c
    where c.well_id = p_well_id
    order by c.period_start desc, c.id desc
    limit v_limit
  ) x;

  return jsonb_build_object(
    'contract', 'list_well_profit_cycles',
    'version', 1,
    'well_id', p_well_id,
    'cycles', v_items
  );
end;
$function$;

revoke all on function api.list_well_profit_cycles(uuid, integer)
  from public, anon, authenticated, service_role;

grant execute on function api.list_well_profit_cycles(uuid, integer)
  to authenticated, service_role;

-- ==============================================================
-- 4. حساب المزارع المالي: فواتيره ودفعاته ورصيده
--
-- كانت: from('billing.invoices').select('*, public.farms(name)')
-- مرتَّبة على issue_date، ثم from('billing.payments'). ثلاثة أخطاء:
-- المخطط غير مكشوف، وpublic.farms لا وجود له، وissue_date لا وجود له.
-- وكان الدين يُجمع في العميل، والاسم والرمز والهاتف والرصيد المقدَّم
-- ثوابت مكتوبة في الكود.
--
-- الحقيقة: الدين والمقدَّم رقمان محسوبان في عرض
-- reporting.farmer_account_balances، والهوية من core.persons،
-- والهاتف من core.person_contacts بنفس ترتيب أفضلية عقد
-- api.list_well_farmers (هجرة 089) — تعريف واحد لا تعريفان.
--
-- الدفعات: دفعة الجلسة قد لا تحمل farmer_well_account_id (قيد هجرة 043
-- يربطها بـ session_charge_id)، فتُلتقط أيضًا عبر تخصيصاتها على فواتير
-- هذا الحساب. وإلا لظهر سجل دفعات ناقص وهو نجاح كاذب من نوع آخر.
-- ==============================================================

create or replace function api.get_farmer_account(
  p_farmer_well_account_id uuid,
  p_limit integer default 50
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_account jsonb;
  v_invoices jsonb;
  v_payments jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة حساب المزارع'
      using errcode = '28000';
  end if;

  if p_farmer_well_account_id is null then
    raise exception 'معرّف حساب المزارع مطلوب'
      using errcode = '22023';
  end if;

  -- RLS على ops.farmer_well_accounts هي مصدر التفويض؛ الحساب غير المرئي
  -- = رفض صريح بدل كائن فارغ غامض.
  select jsonb_build_object(
    'id', fwa.id,
    'well_id', fwa.well_id,
    'public_code', fwa.public_code,
    'full_name', p.full_name,
    'phone', (
      select pc.contact_value
      from core.person_contacts pc
      where pc.person_id = p.id
      order by
        pc.is_primary desc,
        case
          when pc.contact_type in ('mobile', 'whatsapp') then 0
          else 1
        end,
        pc.created_at,
        pc.id
      limit 1
    ),
    'status', fwa.status,
    'credit_limit_minor', fwa.credit_limit_minor,
    'invoiced_minor', coalesce(b.invoiced_minor, 0),
    'allocated_minor', coalesce(b.allocated_minor, 0),
    'total_debt_minor', coalesce(b.debt_minor, 0),
    'advance_balance_minor', coalesce(b.advance_minor, 0)
  )
  into v_account
  from ops.farmer_well_accounts fwa
  join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
  join core.persons p on p.id = fp.person_id
  left join reporting.farmer_account_balances b
    on b.farmer_well_account_id = fwa.id
  where fwa.id = p_farmer_well_account_id;

  if v_account is null then
    raise exception 'لا توجد صلاحية على حساب هذا المزارع'
      using errcode = '42501';
  end if;

  select coalesce(
    jsonb_agg(x.item order by x.invoice_date desc, x.id desc),
    '[]'::jsonb
  )
  into v_invoices
  from (
    select
      i.id,
      i.invoice_date,
      jsonb_build_object(
        'id', i.id,
        'invoice_number', i.public_code,
        'issue_date', i.invoice_date,
        'due_date', i.due_date,
        'session_id', i.session_id,
        'farm_name', f.name,
        'original_amount_minor', i.total_minor,
        'paid_amount_minor', i.paid_minor,
        'outstanding_minor', i.outstanding_minor,
        'settlement_method', i.settlement_method,
        'status', i.status
      ) as item
    from billing.invoices i
    left join ops.irrigation_sessions s on s.id = i.session_id
    left join ops.farms f on f.id = s.farm_id
    where i.farmer_well_account_id = p_farmer_well_account_id
    order by i.invoice_date desc, i.id desc
    limit v_limit
  ) x;

  select coalesce(
    jsonb_agg(x.item order by x.paid_at desc, x.id desc),
    '[]'::jsonb
  )
  into v_payments
  from (
    select
      pay.id,
      pay.paid_at,
      jsonb_build_object(
        'id', pay.id,
        'receipt_number', pay.public_code,
        'paid_at', pay.paid_at,
        'amount_minor', pay.amount_minor,
        'method', pay.method,
        'purpose', pay.purpose,
        'status', pay.status,
        'note', pay.note,
        'allocated_invoices', (
          select coalesce(
            jsonb_agg(inv.public_code order by inv.public_code),
            '[]'::jsonb
          )
          from billing.payment_allocations pa
          join billing.invoices inv on inv.id = pa.invoice_id
          where pa.payment_id = pay.id
        )
      ) as item
    from billing.payments pay
    where pay.status <> 'reversed'
      and (
        pay.farmer_well_account_id = p_farmer_well_account_id
        or exists (
          select 1
          from billing.payment_allocations pa2
          join billing.invoices inv2 on inv2.id = pa2.invoice_id
          where pa2.payment_id = pay.id
            and inv2.farmer_well_account_id = p_farmer_well_account_id
        )
      )
    order by pay.paid_at desc, pay.id desc
    limit v_limit
  ) x;

  return jsonb_build_object(
    'contract', 'get_farmer_account',
    'version', 1,
    'account', v_account,
    'invoices', v_invoices,
    'payments', v_payments
  );
end;
$function$;

revoke all on function api.get_farmer_account(uuid, integer)
  from public, anon, authenticated, service_role;

grant execute on function api.get_farmer_account(uuid, integer)
  to authenticated, service_role;

-- ==============================================================
-- 5. مؤشرات التقارير
--
-- كان: client.rpc('get_reports_summary', …) بلا أي دالة بهذا الاسم في
-- القاعدة، والخطأ يُبتلع بـ debugPrint ثم تُعرض أرقام ثابتة: 24 جلسة
-- و945000 إيراد و720000 محصّل و285000 مصروف و460 لترًا، مع سلسلة
-- أسبوعية وتوزيع طاقة مخترعين بالكامل.
--
-- المصادر الحقيقية: ops.irrigation_sessions وbilling.session_charges
-- وbilling.payments وfinance.expenses وinventory.fuel_transactions،
-- وتوزيع الطاقة من ops.session_segments (الثلاثية الحقيقية:
-- solar / well_diesel / farmer_diesel) لا من نوع المضخة.
--
-- الوقود يُعاد بالمليلتر (وحدة القاعدة) والمدد بالثواني، والتحويل إلى
-- لتر أو ساعة والنسب المئوية وتسمية الأيام بالعربية على طبقة العرض.
-- ==============================================================

create or replace function api.get_reports_summary(
  p_well_id uuid,
  p_period text default 'this_month',
  p_start timestamptz default null,
  p_end timestamptz default null
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_period text := nullif(btrim(coalesce(p_period, '')), '');
  v_start timestamptz;
  v_end timestamptz;
  v_result jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة التقارير'
      using errcode = '28000';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  v_period := coalesce(v_period, 'this_month');

  -- الأسبوع المحلي يبدأ السبت: (dow + 1) % 7 يوم إلى الوراء من اليوم.
  if v_period = 'today' then
    v_start := date_trunc('day', now());
    v_end := v_start + interval '1 day';
  elsif v_period = 'this_week' then
    v_start := date_trunc('day', now())
      - ((((extract(dow from now())::integer + 1) % 7)) || ' days')::interval;
    v_end := v_start + interval '7 days';
  elsif v_period = 'this_month' then
    v_start := date_trunc('month', now());
    v_end := v_start + interval '1 month';
  elsif v_period = 'custom' then
    if p_start is null or p_end is null then
      raise exception 'الفترة المخصصة تحتاج بداية ونهاية'
        using errcode = '22023';
    end if;
    if p_end <= p_start then
      raise exception 'نهاية الفترة يجب أن تكون بعد بدايتها'
        using errcode = '22023';
    end if;
    v_start := date_trunc('day', p_start);
    v_end := date_trunc('day', p_end) + interval '1 day';
    -- حد مثبت: السلسلة اليومية تُبنى صفًا لكل يوم، فالنافذة محدودة.
    if v_end - v_start > interval '92 days' then
      raise exception 'أقصى مدى للفترة المخصصة 92 يومًا'
        using errcode = '22023';
    end if;
  else
    raise exception 'رمز فترة غير معروف: %', v_period
      using errcode = '22023';
  end if;

  if not exists (
    select 1
    from core.wells w
    where w.id = p_well_id
  ) then
    raise exception 'لا توجد صلاحية على هذا البئر'
      using errcode = '42501';
  end if;

  with days as (
    select generate_series(
      v_start, v_end - interval '1 day', interval '1 day'
    )::date as day
  ),
  sess as (
    select
      s.id,
      s.started_at,
      coalesce(sc.duration_seconds, 0) as duration_seconds,
      coalesce(sc.amount_minor, 0) as amount_minor
    from ops.irrigation_sessions s
    left join billing.session_charges sc on sc.session_id = s.id
    where s.well_id = p_well_id
      and s.started_at >= v_start
      and s.started_at < v_end
  ),
  paid_rows as (
    select p.paid_at, p.amount_minor
    from billing.payments p
    where p.well_id = p_well_id
      and p.status = 'posted'
      and p.paid_at >= v_start
      and p.paid_at < v_end
  ),
  exp_rows as (
    select e.spent_at, e.amount_minor
    from finance.expenses e
    where e.well_id = p_well_id
      and e.status = 'posted'
      and e.spent_at >= v_start
      and e.spent_at < v_end
  ),
  fuel as (
    select coalesce(sum(f.quantity_ml), 0) as fuel_out_ml
    from inventory.fuel_transactions f
    where f.well_id = p_well_id
      and f.status = 'posted'
      and f.direction = 'out'
      and f.occurred_at >= v_start
      and f.occurred_at < v_end
  ),
  daily as (
    select
      d.day,
      (
        select count(*)
        from sess x
        where date_trunc('day', x.started_at)::date = d.day
      ) as sessions_count,
      (
        select coalesce(sum(x.duration_seconds), 0)
        from sess x
        where date_trunc('day', x.started_at)::date = d.day
      ) as duration_seconds,
      (
        select coalesce(sum(x.amount_minor), 0)
        from paid_rows x
        where date_trunc('day', x.paid_at)::date = d.day
      ) as collected_minor,
      (
        select coalesce(sum(x.amount_minor), 0)
        from exp_rows x
        where date_trunc('day', x.spent_at)::date = d.day
      ) as expenses_minor
    from days d
  ),
  weekly as (
    select
      (
        dd.day
        - ((((extract(dow from dd.day)::integer + 1) % 7)) || ' days')::interval
      )::date as week_start,
      sum(dd.collected_minor) as collected_minor,
      sum(dd.expenses_minor) as expenses_minor
    from daily dd
    group by 1
  ),
  energy as (
    select
      src.energy_source,
      coalesce((
        select sum(coalesce(seg.actual_minutes, 0)) * 60
        from ops.session_segments seg
        join sess s2 on s2.id = seg.session_id
        where seg.energy_source = src.energy_source
      ), 0) as total_seconds
    from (
      values ('solar'), ('well_diesel'), ('farmer_diesel')
    ) as src(energy_source)
  )
  select jsonb_build_object(
    'contract', 'get_reports_summary',
    'version', 1,
    'well_id', p_well_id,
    'period_code', v_period,
    'period_start', v_start,
    'period_end', v_end,
    'week_starts_on', 'saturday',
    'totals', jsonb_build_object(
      'total_sessions', (select count(*) from sess),
      'total_duration_seconds', (
        select coalesce(sum(duration_seconds), 0) from sess
      ),
      'total_revenue_minor', (
        select coalesce(sum(amount_minor), 0) from sess
      ),
      'total_collected_minor', (
        select coalesce(sum(amount_minor), 0) from paid_rows
      ),
      'total_expenses_minor', (
        select coalesce(sum(amount_minor), 0) from exp_rows
      ),
      'total_fuel_consumed_ml', (select fuel_out_ml from fuel)
    ),
    'daily_irrigation', (
      select coalesce(jsonb_agg(
        jsonb_build_object(
          'day', dd.day,
          'sessions_count', dd.sessions_count,
          'duration_seconds', dd.duration_seconds
        ) order by dd.day
      ), '[]'::jsonb)
      from daily dd
    ),
    'financial_trends', (
      select coalesce(jsonb_agg(
        jsonb_build_object(
          'week_start', wk.week_start,
          'week_end', wk.week_start + 6,
          'collected_minor', wk.collected_minor,
          'expenses_minor', wk.expenses_minor
        ) order by wk.week_start
      ), '[]'::jsonb)
      from weekly wk
    ),
    'energy_distribution', (
      select coalesce(jsonb_agg(
        jsonb_build_object(
          'energy_source', en.energy_source,
          'total_seconds', en.total_seconds
        ) order by en.energy_source
      ), '[]'::jsonb)
      from energy en
    )
  )
  into v_result;

  return v_result;
end;
$function$;

revoke all on function api.get_reports_summary(
  uuid, text, timestamptz, timestamptz
) from public, anon, authenticated, service_role;

grant execute on function api.get_reports_summary(
  uuid, text, timestamptz, timestamptz
) to authenticated, service_role;

comment on function api.list_well_expenses(uuid, text, integer) is
  'عقد قراءة مصروفات البئر (092). يستبدل from(finance.expenses).';

comment on function api.list_well_partners(uuid, integer) is
  'عقد قراءة شركاء البئر ومالهم (092). يستبدل جدولًا لا وجود له: iam.well_memberships.';

comment on function api.list_well_profit_cycles(uuid, integer) is
  'عقد قراءة دورات توزيع الأرباح وأسطرها (092).';

comment on function api.get_farmer_account(uuid, integer) is
  'عقد قراءة حساب المزارع: فواتير ودفعات ودين ومقدَّم محسوبة في القاعدة (092).';

comment on function api.get_reports_summary(uuid, text, timestamptz, timestamptz) is
  'عقد مؤشرات التقارير (092). الوقود بالمليلتر والمدد بالثواني؛ التحويل على العرض.';

commit;

