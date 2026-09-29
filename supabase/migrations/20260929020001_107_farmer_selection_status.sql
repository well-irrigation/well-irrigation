-- ق-131 البند 11 / م-45 المرحلة A: تحذير حالة المزارع عند اختياره.
--
-- القرار الحاكم (اعتماد المالك 2026-09-28):
--   1. عند اختيار مزارع مصرَّح له لجلسة (ولاحقًا حجز)، يظهر ملخص
--      تحذيري مختصر **غير مانع**: مديونيته، ورصيد مقدمه، وكمية ديزله
--      المملوكة — إخبارية ولا تحجب بدء السقي آليًا.
--   2. الدلالات نصية صريحة في العميل («عليه مديونية»، «له رصيد مقدم»)
--      لا إشارات +/- غامضة ولا لون وحده.
--   3. المال وديزل المزارع متمايزان (ق-131 البند 9): كمية لا تُحوَّل
--      صمتًا إلى مال ولا تُقاص مع الدين أو المقدم.
--
-- **لماذا عقد جديد لا توسيع `api.list_well_farmers`:** ذلك العقد يُستعمل
-- في اختيار المزارع أثناء بدء الجلسة وهو متعمد البساطة (اسم/رمز/هاتف) —
-- حملُه بأرقام مالية يوسّع سطح الكشف بلا حاجة. والقراءة المالية الكاملة
-- (`invoices/payments` بالتاريخ) سطح أوسع من حاجة اللحظة. فالعقد الجديد
-- قراءة تشغيلية دنيا لحساب واحد.
--
-- **مصادر القيم الثلاث كلها من الخادم (ق-99):**
--   - الدين والمقدم من `reporting.farmer_account_balances` (060) —
--     العرض الحي نفسه الذي يقرؤه دليل المزارعين (099): الدين = فوترة
--     غير ملغاة/معكوسة ناقص المخصص، والمقدم = دفعات `advance` المرحّلة.
--   - ديزل المزارع من حركات المخزون المرحّلة نفسها التي يجمعها
--     `inventory.farmer_fuel_balance_ml` (046) — التعبير الحاكم نفسه
--     حرفيًا.
--
-- **ولماذا قارئ غرضي للوقود لا استخدام الدالة القائمة من العقد:**
-- `inventory.farmer_fuel_balance_ml(p_well_id, p_person_id)` دالة
-- SECURITY DEFINER بلا أي فحص سلطة داخلها تقبل أي زوج بئر/شخص —
-- وفضحها للعقد كان سيفتح سؤال أزواج اعتباطية على كل مصادَق. القارئ
-- الجديد محصور بمعرّف حساب المزارع (يربط البئر بالشخص معًا)، وبحقيقة
-- مسمّاة واحدة: نفس بابت `session.start` الذي يفتح نموذج الاختيار
-- أصلًا — فمن يستطيع بدء سقي لهذا البئر يقرأ ملخص حالة مزارعه، ولا
-- أحد سواه. وسياسات RLS القائمة بلا مساس، وحرس م-18 (اختبار 082
-- التحقق 5) سليم.
--
-- **وإغلاق فجوة إرثية مكتشفة أثناء هذه الجولة:** أثبت فحص القاعدة أن
-- الدالة القائمة فوقها منح EXECUTE الافتراضي عبر PUBLIC من زمن إنشائها
-- في 046 — هجرة 072 (ق-79) تسحب صلاحيات الجداول ولا تمسّ EXECUTE،
-- و085 سحبت من anon وحده فلم يُزل ميراث PUBLIC — فأي مصادَق كان
-- يستطيع استدعاء الدالة مباشرة بأي زوج بئر/شخص. القسم 3 أدناه يسحب
-- EXECUTE منها من public وanon وauthenticated سحبًا ضيقًا: الجسم
-- والمعاملات والدلالة بلا مسّ، وservice_role بمنحه الصريح باقٍ،
-- ومستدعياها الإنتاجيان داخل inventory.record_fuel_consumption
-- بصيغة SECURITY DEFINER (069 ثم إعادة تعريفها في 082) ينفَّذان
-- بمالك الدالة فلا يتأثران، ولا مستدعى لها في مخطط api ولا في
-- العميل — فالمسار الوحيد المواجه للعميل هو العقد الجديد أعلاه.

begin;

-- ==============================================================
-- 1. القارئ الغرضي لكمية ديزل المزارع (كمية لا مال)
-- ==============================================================

create or replace function inventory.farmer_selection_fuel_ml(
  p_farmer_well_account_id uuid
)
returns bigint
language plpgsql
stable
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_well_id uuid;
  v_person_id uuid;
begin
  if p_farmer_well_account_id is null then
    raise exception 'معرّف حساب المزارع مطلوب'
      using errcode = '22023';
  end if;

  select fwa.well_id, fp.person_id
  into v_well_id, v_person_id
  from ops.farmer_well_accounts fwa
  join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
  where fwa.id = p_farmer_well_account_id;

  if v_well_id is null then
    raise exception 'حساب المزارع غير موجود'
      using errcode = '22023';
  end if;

  -- سلطة مسمّاة واحدة (حرس م-18): نفس بابت بدء الجلسة على بئر الحساب.
  -- الحساب نفسه يربط البئر بالشخص، فلا سؤال عن أزواج اعتباطية.
  if not iam.has_well_permission(v_well_id, 'session.start') then
    raise exception 'لا توجد صلاحية على هذا حساب المزارع'
      using errcode = '42501';
  end if;

  -- التعبير الحاكم نفسه كما في inventory.farmer_fuel_balance_ml (046):
  -- مجموع الحركات المرحّلة لمزارع هذا البئر. كمية لا مال (ق-131
  -- البند 9) — لا تحويل ولا مقاصلة هنا ولا في العميل.
  return (
    select coalesce(
             sum(
               case when t.direction = 'in'
                    then t.quantity_ml
                    else -t.quantity_ml
               end
             ),
             0
           )
    from inventory.fuel_transactions t
    where t.well_id = v_well_id
      and t.ownership_type = 'farmer'
      and t.owner_person_id = v_person_id
      and t.status = 'posted'
  );
end;
$function$;

revoke all on function inventory.farmer_selection_fuel_ml(uuid)
  from public, anon, authenticated, service_role;

grant execute on function inventory.farmer_selection_fuel_ml(uuid)
  to authenticated, service_role;

comment on function inventory.farmer_selection_fuel_ml(uuid) is
  'ق-131 البند 11: قارئ غرضي لكمية ديزل المزارع عند اختياره لجلسة/حجز — بحقيقة مسمّاة session.start على بئر الحساب، ومحصور بمعرّف حساب المزارع لا بأزواج بئر/شخص اعتباطية. كمية لا مال ولا مقاصلة.';

-- ==============================================================
-- 2. عقد القراءة التشغيلي الدنيء لحالة المزارع المختار
-- ==============================================================

create or replace function api.get_farmer_selection_status(
  p_farmer_well_account_id uuid
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_account record;
  v_fuel_ml bigint;
  v_result jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة حالة المزارع'
      using errcode = '28000';
  end if;

  if p_farmer_well_account_id is null then
    raise exception 'معرّف حساب المزارع مطلوب'
      using errcode = '22023';
  end if;

  -- الحساب غير المرئي عبر RLS أو غير الموجود = رفض صريح واحد بلا
  -- تسريب وجود (نمط 090).
  select fwa.id, fwa.well_id
  into v_account
  from ops.farmer_well_accounts fwa
  where fwa.id = p_farmer_well_account_id;

  if v_account.id is null
     or not exists (
       select 1
       from core.wells w
       where w.id = v_account.well_id
     ) then
    raise exception 'لا توجد صلاحية على هذا حساب المزارع'
      using errcode = '42501';
  end if;

  -- كمية ديزل المزارع عبر القارئ الغرضي المعتمد (بابت الجلسة نفسه).
  v_fuel_ml := inventory.farmer_selection_fuel_ml(p_farmer_well_account_id);

  -- المال من عرض الأرصدة الحاكم كما هو: لا حساب في العقد ولا في العميل
  -- (ق-99)، والصفر الحقيقي صفر لا غياب مُصطنع.
  select jsonb_build_object(
    'contract', 'get_farmer_selection_status',
    'version', 1,
    'farmer_well_account_id', v_account.id,
    'well_id', v_account.well_id,
    'debt_minor', coalesce(max(b.debt_minor), 0),
    'advance_minor', coalesce(max(b.advance_minor), 0),
    'farmer_fuel_balance_ml', coalesce(v_fuel_ml, 0)
  )
  into v_result
  from reporting.farmer_account_balances b
  where b.farmer_well_account_id = v_account.id
    and b.well_id = v_account.well_id;

  return v_result;
end;
$function$;

revoke all on function api.get_farmer_selection_status(uuid)
  from public, anon, authenticated, service_role;

grant execute on function api.get_farmer_selection_status(uuid)
  to authenticated, service_role;

comment on function api.get_farmer_selection_status(uuid) is
  'ق-131 البند 11: ملخص حالة المزارع عند اختياره لجلسة/حجز — الدين والمقدم من عرض الأرصدة الحاكم (060) وكمية ديزله من حركات المخزون المرحّلة عبر قارئ غرضي بحقيقة session.start. قراءة تشغيلية غير مانعة: كمية لا مال ولا مقاصلة، ولا سطح مالي كامل.';

-- ==============================================================
-- 3. إغلاق الفجوة الإرثية: منح EXECUTE الافتراضي عبر PUBLIC على
--    الدالة القديمة (046) — سحب ضيق بلا مسّ الجسم ولا RLS.
--
-- المستدعون الإنتاجيون الوحيدان داخل inventory.record_fuel_consumption
-- بصيغة SECURITY DEFINER (069 ثم إعادة تعريفها في 082): تنفَّذ بمالك
-- الدالة فلا يعنيها سحب منح العملاء. ولا مستدعى في api ولا في
-- العميل — فالمسار المواجه للعميل هو العقد الغرضي أعلاه وحده.
-- ==============================================================

revoke execute on function inventory.farmer_fuel_balance_ml(uuid, uuid)
  from public, anon, authenticated;

comment on function inventory.farmer_fuel_balance_ml(uuid, uuid) is
  'رصيد ديزل مزارع محسوب لحظيًا (046). أغلقت هجرة 107 منح EXECUTE الافتراضي عبر PUBLIC: لا استدعاء مباشر من العميل — الداخلية عبر إجراءات DEFINER وحدها، وللعميل القارئ الغرضي inventory.farmer_selection_fuel_ml بحقيقة session.start (ق-131 البند 11).';

commit;
