-- 095 — نطاق قراءة الشريك: ما يراه وما لا يراه (م-41E المرحلة 4 / ق-123 §8)
--
-- المشكلة التي تغلقها هذه الهجرة:
-- بعد المرحلة 3 صار الشريك يدخل التطبيق فعلًا: يُطالب برمزه فيُنشأ له
-- تعيين partner ويُربط سطره في core.well_partners (هجرة 094). ومن تلك
-- اللحظة تنفتح له سياسات اطلاع الشريك المولَّدة آليًا في هجرة 050 §3 على
-- كل جدول أساسي يحمل well_id أو tenant_id — ومنها ops.irrigation_sessions.
-- وعقود القراءة في هجرة 090 (api.list_well_sessions وapi.get_session_detail)
-- هي INVOKER تفوّض على RLS، فتُعيد له **الجلسة الجارية بأرقامها**: المستحق
-- والمدة والمضخة. وذلك ما يمنعه الجدول المُقرَّر في
-- technical/ACCOUNT_SETTINGS_ARCHITECTURE.md §26 نصًّا، ويمنعه الثابت 713
-- مبدأً: الجلسة غير المقفلة لا تدخل مجاميع أي يوم (ق-37)، فرقمها غير نهائي
-- وسيتغيّر، ومن يُعرض عليه يبني توقّعًا ينقلب. وحضورها وحده حقيقة نهائية.
--
-- ومعها: api.list_well_expenses (هجرة 092) تعيد recorded_by_name، و§26
-- يمنع «من اعتمد المصروف وملاحظاته الداخلية» عن الشريك.
--
-- أدلة جُمعت قبل الكتابة (لا Blind Remap):
-- أ) هجرة 050 §3 تولّد سياسة `<table>_select_partner` لكل جدول أساسي في
--    core/iam/ops/billing/finance/inventory، فاطلاع الشريك **قائم فعلًا**
--    ولا يحتاج منحًا جديدًا. المطلوب تضييق لا توسيع، ولذلك لا صلاحية
--    مسمّاة جديدة هنا ولا تغيير في أرقام الكتالوج (43 صلاحية / 79 منحًا).
-- ب) api.app_bootstrap (هجرة 077) يوحّد أدوار core.well_assignments مع
--    وصول core.well_partners، فالشريك يرى بئره في الحمولة الأولى بدور
--    'partner' حتى لو لم يوجد سطر تعيين موازٍ.
-- ج) الجلسة الجارية هي status='open' وحدها: قيد
--    irrigation_sessions_status_check يحصر الحالات في open/closed/forgotten.
-- د) ops.session_segments بلا عمود well_id، فسياسة 050 وقعت على فرع
--    tenant_id: شريك في بئر واحد يقرأ مقاطع كل آبار المستأجر. والمقطع يحمل
--    applied_hourly_rate_minor وraw_billable_minutes، أي **أساس المستحق
--    اللحظي**. تضييقها هنا يصلح الاتساع والتسريب معًا.
-- هـ) أرقام الشريك النهائية موجودة سلفًا ومخزَّنة: api.list_well_profit_cycles
--    تعيد إيراد الفترة ومصروفاتها وصافيها ونسبة كل شريك **لحظة الدورة**
--    (profit_percentage_snapshot)، وعرض reporting.partner_account_summary
--    يعيد حصته ومدفوعاته ورصيده. فلا حساب مال جديد في هذه الهجرة (ق-99).
--
-- ما تفعله الهجرة بالضبط:
-- 1. تضييق سياستَي اطلاع الشريك على الجلسات ومقاطعها: الجارية لا تُقرأ.
-- 2. iam.is_partner_only: هل سلطة المتصل على هذا البئر شراكةٌ وحدها؟
--    مالكٌ أضاف نفسه شريكًا يبقى مالكًا فلا يُقيَّد، وشريكٌ هو أيضًا مشغّل
--    يرى الجلسة الجارية عبر سياسة دوره لا عبر سياسة شراكته.
-- 3. api.list_well_expenses: اسم من سجّل المصروف يُفرَّغ للشريك وحده،
--    والمفاتيح والإصدار كما هما، ومفتاح partner_scope يُضاف ليُقال الحدّ
--    صريحًا: الإخفاء الصامت يُقرأ إخفاءً، والوسم يقول الحقيقة (§26).
-- 4. عقد جديد api.read_partner_overview: هوية الشريك في هذا البئر وأرقامه،
--    و**حضور** الجلسة الجارية وعددها بلا أي رقم منها، والفترة المفتوحة
--    موسومة is_final=false. القراءة الوحيدة التي تحتاج تجاوز RLS هي
--    الحضور، فانتقلت إلى إجراء داخلي SECURITY DEFINER يحمل سلطته صريحة.
-- 5. عقد جديد api.list_well_farmer_balances: «المزارعون وديونهم» في §26
--    لا عقد يعيدها في قائمة، فأُضيف قارئًا لعرض 060 كما هو بلا حساب.
--
-- أثر مقصود على الفهرس المولَّد: functions 447 → 451، والأعمدة والقيود
-- والمشغّلات بلا تغيير، وiam.permissions 43 وiam.role_permissions 79 كما هما.

begin;

-- ==============================================================
-- 1. تضييق اطلاع الشريك على الجلسات: الجارية لا تُقرأ
--
-- التضييق في طبقة الصفوف لا في عقد واحد: كل عقد قراءة قائم أو قادم
-- يفوّض على RLS يستفيد منه بلا تعديل، فلا يعود الحدّ مرهونًا بتذكّر
-- كاتب العقد التالي. والسياسات تُجمع بـOR، فمن كان مشغّلًا أو مالكًا
-- إلى جانب شراكته يرى الجلسة الجارية عبر سياسة دوره كما كان.
-- ==============================================================

drop policy if exists irrigation_sessions_select_partner
  on ops.irrigation_sessions;

create policy irrigation_sessions_select_partner
on ops.irrigation_sessions
for select
using (
  iam.is_well_partner(well_id)
  and status <> 'open'
);

comment on policy irrigation_sessions_select_partner
  on ops.irrigation_sessions is
  'م-41E/4 (§26 / الثابت 713): الشريك يقرأ الجلسات المقفلة وحدها. الجارية غير نهائية، وحضورها يُعرض عبر api.read_partner_overview بلا أي رقم منها.';

-- المقاطع: تُقصر على مقاطع جلسات بئرٍ هو شريك فيه، وعلى غير الجارية.
-- سياسة 050 كانت على فرع tenant_id فوسّعت النطاق إلى كل آبار المستأجر.
drop policy if exists session_segments_select_partner
  on ops.session_segments;

create policy session_segments_select_partner
on ops.session_segments
for select
using (
  exists (
    select 1
    from ops.irrigation_sessions s
    where s.id = session_segments.session_id
      and s.status <> 'open'
      and iam.is_well_partner(s.well_id)
  )
);

comment on policy session_segments_select_partner
  on ops.session_segments is
  'م-41E/4: مقاطع جلسات آبار الشريك غير الجارية وحدها. المقطع يحمل السعر المطبَّق والدقائق القابلة للفوترة، أي أساس المستحق اللحظي.';

-- ==============================================================
-- 2. iam.is_partner_only — سلطة المتصل على هذا البئر شراكةٌ وحدها؟
--
-- تُستعمل لحجب حقل عن الشريك دون أن يمسّ ذلك من له دور تشغيلي أيضًا.
-- تعتمد دالتين قائمتين: iam.is_well_partner (هجرة 047، شراكة سارية
-- بلا period_end) وiam.has_well_role (هجرة 080، تعيين نشِط).
-- ==============================================================

create or replace function iam.is_partner_only(p_well_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, pg_temp
as $function$
  select iam.is_well_partner(p_well_id)
     and not iam.has_well_role(
       p_well_id,
       array['owner', 'manager', 'operator']
     );
$function$;

comment on function iam.is_partner_only(uuid) is
  'م-41E/4: true حين تكون سلطة المتصل على البئر شراكةً وحدها بلا دور تشغيلي. لا تُعيد شيئًا عن غير المتصل نفسه.';

revoke all on function iam.is_partner_only(uuid)
  from public, anon, authenticated, service_role;

grant execute on function iam.is_partner_only(uuid)
  to authenticated, service_role;

-- ==============================================================
-- 3. api.list_well_expenses — اسم المسجِّل يُفرَّغ للشريك وحده
--
-- §26: «من اعتمد المصروف وملاحظاته الداخلية: لا يرى». بنود المصروف نفسها
-- (تاريخ/نوع/مبلغ/وصف) يراها، فالحجب حقلٌ واحد لا صفٌّ محجوب: صفّ ناقص
-- كان سيُقرأ «مصروف غير موجود» وهو غياب كاذب.
-- والملاحظة الداخلية (finance.expenses.note وسطور finance.expense_approvals)
-- لم تكن مكشوفة في هذا العقد ولا في غيره، وتبقى كذلك.
--
-- ما لم يتغيّر: التوقيع، والمفاتيح، وversion = 1 (اختبار 092 PASS 11
-- يثبّتها)، والترتيب، والحدود، والحالات المقبولة. المضاف مفتاح واحد
-- partner_scope يقول الحدّ صريحًا للواجهة.
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
  v_partner_only boolean;
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

  v_partner_only := iam.is_partner_only(p_well_id);

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
        'recorded_by_name', case
          when v_partner_only then null
          else pf.full_name
        end
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
    'partner_scope', v_partner_only,
    'expenses', v_items
  );
end;
$function$;

comment on function api.list_well_expenses(uuid, text, integer) is
  'عقد قراءة مصروفات البئر. م-41E/4 أفرغ recorded_by_name لمن سلطته شراكة وحدها (§26)، وأضاف partner_scope ليُعلَن الحدّ بدل إخفائه صامتًا.';

revoke all on function api.list_well_expenses(uuid, text, integer)
  from public, anon, authenticated, service_role;

grant execute on function api.list_well_expenses(uuid, text, integer)
  to authenticated, service_role;

-- ==============================================================
-- 4. القارئ الداخلي لملخص الشريك — SECURITY DEFINER بسلطة صريحة
--
-- سبب وجوده كـDEFINER: **الحضور**. سياسة §1 أعلاه تحجب صف الجلسة الجارية
-- عن الشريك، فعقد INVOKER يعدّها صفرًا دائمًا — وذلك غياب كاذب يقول «لا
-- جلسة» عن بئر يعمل الآن. فالتجاوز يحدث في نقطة واحدة مُراجَعة، وما
-- يُعاد منها **عدد فقط**: لا معرّف جلسة، ولا مستحق، ولا مدة، ولا مضخة،
-- ولا مزارع (§26 / الثابت 713).
--
-- وما لا يفعله هذا العقد بقصد: لا يكرّر دورات التوزيع ولا المصروفات ولا
-- المزارعين ولا الوقود — لكلٍّ عقده المُثبَت في هجرتَي 089 و092، ونسبة كل
-- فترة التاريخية موجودة فيها (profit_percentage_snapshot). تكرارها هنا
-- كان سيُنتج رقمين لمعنى واحد.
--
-- ولا صافيَ محسوبًا للفترة المفتوحة: الإيراد والمصروف يُعرضان كما هما
-- مجموعَي أعمدة مخزَّنة (أسلوب api.get_reports_summary نفسه، وهو لا يعيد
-- صافيًا أيضًا)، والصافي يُعلَن عند الإقفال. الفترة المفتوحة موسومة
-- is_final=false، لأن إخفاءها يُقرأ إخفاءً ووسمها يقول الحقيقة (§26).
-- ==============================================================

create or replace function finance.read_partner_overview(p_well_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_partner_id uuid;
  v_partner jsonb;
  v_active_count integer;
  v_window_start timestamptz;
  v_window jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة ملخص الشريك'
      using errcode = '28000';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  -- السلطة: شراكة سارية على هذا البئر، أو دور يدير البئر ليرى ما يراه
  -- شريكه. auth.uid() لـanon وservice_role = null فالنتيجة false،
  -- والإجراء يفشل مغلقًا.
  if not iam.is_well_partner(p_well_id)
     and not iam.has_well_role(p_well_id, array['owner', 'manager']) then
    raise exception 'ملخص الشريك متاح لشريك هذا البئر أو لمن يديره'
      using errcode = '42501';
  end if;

  -- 1) الشريك نفسه: سطر شراكته السارِي وحده، ونسبته السارية اليوم من
  --    core.ownership_share_versions، وأرقامه من عرض
  --    reporting.partner_account_summary كما هي — نفس مصادر
  --    api.list_well_partners حرفيًّا فلا يختلف رقم بين شاشتين.
  select
    wp.id,
    jsonb_build_object(
      'partner_id', wp.id,
      'person_id', wp.person_id,
      'full_name', pe.full_name,
      'phone', wp.phone,
      'period_start', wp.period_start,
      'ownership_percent', v.ownership_percentage,
      'profit_percent', v.profit_percentage,
      'gross_earned_minor', coalesce(s.gross_earned_minor, 0),
      'irrigation_deducted_minor', coalesce(s.irrigation_deducted_minor, 0),
      'expenses_paid_minor', coalesce(s.expenses_paid_minor, 0),
      'net_payable_minor', coalesce(s.net_payable_minor, 0),
      'unpaid_minor', coalesce(s.unpaid_minor, 0),
      'total_paid_minor', coalesce(paid.paid_total, 0)
    )
  into v_partner_id, v_partner
  from core.well_partners wp
  join core.persons pe on pe.id = wp.person_id
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
    and wp.profile_id = v_actor
    and wp.status = 'active'
    and wp.period_end is null
  order by wp.period_start desc, wp.id
  limit 1;

  -- 2) حضور الجلسة الجارية: العدد وحده. الحضور حقيقة نهائية، ورقمها ليس
  --    كذلك — الثابت 713.
  select count(*)::integer
  into v_active_count
  from ops.irrigation_sessions ses
  where ses.well_id = p_well_id
    and ses.status = 'open';

  -- 3) الفترة المفتوحة: من نهاية آخر دورة توزيع غير ملغاة إلى الآن. أرقامها
  --    مجاميع أعمدة مخزَّنة في reporting.well_daily_summary لا حسابًا جديدًا،
  --    ويوم انتهاء الدورة قد يتقاطع يومًا واحدًا — وهي موسومة غير نهائية
  --    أصلًا فلا يُبنى عليها التزام.
  select max(c.period_end)
  into v_window_start
  from finance.profit_distribution_cycles c
  where c.well_id = p_well_id
    and c.status <> 'cancelled';

  select jsonb_build_object(
    'starts_at', v_window_start,
    'is_final', false,
    'days_counted', count(*),
    'sessions_count', coalesce(sum(d.sessions_count), 0),
    'charges_minor', coalesce(sum(d.charges_minor), 0),
    'collected_minor', coalesce(sum(d.collected_minor), 0),
    'expenses_minor', coalesce(sum(d.expenses_minor), 0)
  )
  into v_window
  from reporting.well_daily_summary d
  where d.well_id = p_well_id
    and (v_window_start is null or d.day >= v_window_start::date);

  return jsonb_build_object(
    'contract', 'read_partner_overview',
    'version', 1,
    'well_id', p_well_id,
    'is_partner', v_partner_id is not null,
    'partner', v_partner,
    'active_sessions', jsonb_build_object(
      'count', v_active_count,
      'has_active', v_active_count > 0
    ),
    'open_window', v_window,
    'server_time', now()
  );
end;
$function$;

comment on function finance.read_partner_overview(uuid) is
  'م-41E/4: ملخص الشريك على بئره. يتجاوز RLS في موضع واحد — عدّ الجلسات الجارية للحضور — ولا يعيد أي رقم منها. سلطته شراكة سارية أو دور يدير البئر.';

revoke all on function finance.read_partner_overview(uuid)
  from public, anon, authenticated, service_role;

grant execute on function finance.read_partner_overview(uuid)
  to authenticated, service_role;

-- ==============================================================
-- 5. الغلاف العام — INVOKER رقيق يتحقق ثم يفوّض
--
-- ما يبقى تحت RLS المتصل نفسه: وجود الجلسة (28000)، وصلاحية المدخل
-- (22023)، ورؤية البئر عبر سياسة wells_select_partner (هجرة 050) أو
-- wells_select_staff_or_farmer_self (هجرة 079) — فبئر لا سلطة للمتصل
-- عليه لا يظهر له أصلًا، والنتيجة رفض صريح لا مغلّف فارغ.
-- ==============================================================

create or replace function api.read_partner_overview(p_well_id uuid)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة ملخص الشريك'
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

  return finance.read_partner_overview(p_well_id);
end;
$function$;

comment on function api.read_partner_overview(uuid) is
  'عقد قراءة ملخص الشريك (م-41E/4 / §26): هويته وأرقامه، وحضور الجلسة الجارية وعددها بلا أرقامها، والفترة المفتوحة موسومة غير نهائية.';

revoke all on function api.read_partner_overview(uuid)
  from public, anon, authenticated, service_role;

grant execute on function api.read_partner_overview(uuid)
  to authenticated, service_role;

-- ==============================================================
-- 6. api.list_well_farmer_balances — «المزارعون وديونهم» (§26)
--
-- §26 يعطي الشريك صفوف المزارعين وديونهم قراءةً، والعقود القائمة لا تعيد
-- الدين في قائمة: api.list_well_farmers (هجرة 089) يعيد الاسم والرمز
-- والحالة بلا رصيد، وapi.get_farmer_account (هجرة 092) يعيد حساب مزارع
-- واحد بمعرّفه. وبناء الدين في العميل من قائمة بلا أرصدة تلفيقٌ لا توصيل
-- (درس م-41B3B)، فالبديل عقد يقرأ عرض reporting.farmer_account_balances
-- (هجرة 060) كما هو: الفواتير والمخصَّص والمقدَّم والدين، بلا حساب جديد.
--
-- INVOKER بلا استثناء: التفويض من RLS على ops.farmer_well_accounts
-- وbilling، فمن لا سلطة له لا يرى صفًّا، ومن له سلطة يرى أرصدة بئره وحده.
-- والعرض نفسه security_invoker فيبقى الحدّ حدَّ القارئ لا حدَّ المالك.
-- ==============================================================

create or replace function api.list_well_farmer_balances(
  p_well_id uuid,
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
    raise exception 'يجب تسجيل الدخول قبل قراءة أرصدة المزارعين'
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
    jsonb_agg(x.item order by x.debt_minor desc, x.full_name, x.id),
    '[]'::jsonb
  )
  into v_items
  from (
    select
      b.farmer_well_account_id as id,
      b.debt_minor,
      pe.full_name,
      jsonb_build_object(
        'farmer_well_account_id', b.farmer_well_account_id,
        'public_code', b.public_code,
        'full_name', pe.full_name,
        'status', fwa.status,
        'invoiced_minor', b.invoiced_minor,
        'allocated_minor', b.allocated_minor,
        'advance_minor', b.advance_minor,
        'debt_minor', b.debt_minor
      ) as item
    from reporting.farmer_account_balances b
    join ops.farmer_well_accounts fwa on fwa.id = b.farmer_well_account_id
    left join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
    left join core.persons pe on pe.id = fp.person_id
    where b.well_id = p_well_id
    order by b.debt_minor desc, pe.full_name, b.farmer_well_account_id
    limit v_limit
  ) x;

  return jsonb_build_object(
    'contract', 'list_well_farmer_balances',
    'version', 1,
    'well_id', p_well_id,
    'items', v_items
  );
end;
$function$;

comment on function api.list_well_farmer_balances(uuid, integer) is
  'عقد قراءة أرصدة مزارعي البئر (م-41E/4 / §26): الفواتير والمخصَّص والمقدَّم والدين من عرض reporting.farmer_account_balances كما هي، بلا حساب في العقد ولا في العميل.';

revoke all on function api.list_well_farmer_balances(uuid, integer)
  from public, anon, authenticated, service_role;

grant execute on function api.list_well_farmer_balances(uuid, integer)
  to authenticated, service_role;

commit;
