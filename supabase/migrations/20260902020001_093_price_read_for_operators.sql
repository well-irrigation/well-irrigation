-- 093 — قراءة التسعيرة السارية لمن يشغّل البئر (م-41D7)
--
-- المشكلة التي تغلقها هذه الهجرة:
-- المشغل هو من يبدأ جلسة السقي، ولا يرى سعر الساعة على شاشته. عقد
-- api.get_active_price_schedule في هجرة 091 يفحص صلاحية price.manage،
-- وهي للمالك وحده (هجرة 080)، فيتلقى المشغل رفض 42501 وتبقى شاشته بلا
-- تسعيرة. القرار المالكي: يجب أن يرى المشغل سعر الساعة.
--
-- أدلة جُمعت قبل الكتابة (لا Blind Remap):
-- أ) ops.start_irrigation_session (هجرة 066) لا تأخذ سعرًا إطلاقًا،
--    وتفوّض على iam.has_well_role(['owner','manager','operator'])، وتُسعّر
--    المقطع في ops.create_priced_session_segment. فمن حقه بدء جلسة
--    مُسعَّرة من حقه رؤية السعر الذي ستُسعَّر به.
-- ب) price.manage صلاحية تعديل: هجرة 080 تمنحها للمالك عبر cross join،
--    ولا تظهر في قائمة منح operator ولا well_manager. استعمالها بوابة
--    قراءة خلطٌ بين حق التعديل وحق الاطلاع.
-- ج) الطبقة الثانية: سياسات RLS في هجرة 031
--    (price_schedules_select_owner / price_rules_select_owner) تحصر
--    SELECT بـ iam.has_well_role(well_id, array['owner']). لذلك تخفيف
--    الفحص المسمّى وحده داخل عقد INVOKER يُعيد صفر صفوف، أي
--    schedule = null: «غياب كاذب» أسوأ من الرفض الصريح. الطبقتان
--    تتحركان معًا أو لا تتحرك أي منهما.
-- د) العميل جاهز: شاشة العمليات بعد م-41D6 تعرض التسعيرة حين تتوفر،
--    وتعرض حالة الصلاحية حين 42501 — فلا تغيير في Flutter هنا.
--
-- القواعد المطبقة (ق-78 / ق-79 / ق-82 / ق-88 / ق-99):
-- 1. مخطط api يبقى SECURITY INVOKER بلا استثناء. القراءة التي تتجاوز
--    RLS تنتقل إلى إجراء داخلي SECURITY DEFINER بـsearch_path مثبت
--    يحمل الفحص المسمّى — نفس نمط الكتابة في 084/091. والغلاف لا
--    يكرّر قرار الصلاحية (اختبار 084، PASS 7).
-- 2. لا تخفيف لسياسات RLS على ops.price_schedules/ops.price_rules:
--    الجداول تبقى مغلقة على المالك، والاطلاع يمر عبر العقد وحده.
-- 3. صلاحية قراءة جديدة price.read بدل توسيع price.manage صامتًا.
-- 4. المنح مقصورة على من يشغّل البئر: tenant_owner وwell_manager
--    وoperator. partner/accountant/viewer بلا منح (هجرة 081 تحرس ذلك
--    بصفر منح)، وfarmer خارج خريطة الأدوار أصلًا في هجرة 080.
-- 5. غياب جدول ساري يبقى حالة مشروعة: schedule = null بلا خطأ.
--
-- أثر مقصود على أرقام الحرس:
-- iam.permissions 41 → 42، وiam.role_permissions 75 → 78
-- (tenant_owner 41 → 42، well_manager 13 → 14، operator 21 → 22).
-- حُدّثت أرقام اختباري 080 و081 بتعليق يسمّي هجرة 093، كما فعلت 091.

begin;

-- ==============================================================
-- 0. صلاحية القراءة الجديدة price.read
-- ==============================================================

insert into iam.permissions (code, description_ar)
values
  ('price.read', 'الاطلاع على جدول التسعير الساري للبئر')
on conflict (code) do nothing;

-- المنح لمن يشغّل البئر: نفس مجموعة الأدوار التي تقبلها
-- ops.start_irrigation_session في هجرة 066.
insert into iam.role_permissions (role_id, permission_id)
select r.id, p.id
from iam.roles r
join iam.permissions p on p.code = 'price.read'
where r.code in ('tenant_owner', 'well_manager', 'operator')
on conflict do nothing;

-- ==============================================================
-- 1. القارئ الداخلي: SECURITY DEFINER يحمل الفحص المسمّى
--
-- سبب وجوده: سياسات SELECT على ops.price_schedules وops.price_rules
-- (هجرة 031) تحصر الصفوف بالمالك. عقد INVOKER لا يستطيع رؤية صف
-- المشغل، وتخفيف السياسات نفسها يفتح الجداول للقراءة المباشرة من
-- PostgREST مستقبلًا. فالتجاوز يحدث في نقطة واحدة مُراجَعة، وسلطتها
-- فحص صريح باسم الصلاحية لا دور نصي.
--
-- أسلوب اختيار الجدول الساري مطابق حرفيًا لهجرة 091: status='active'
-- وeffective_period يحتوي اللحظة، ثم ترتيب lower(effective_period)
-- تنازليًا ثم created_at ثم id. والمغلّف نفسه بحرفه حتى لا يتغير أي
-- مفتاح يقرأه العميل.
-- ==============================================================

create or replace function ops.read_active_price_schedule(
  p_well_id uuid,
  p_at timestamptz
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_at timestamptz := coalesce(p_at, now());
  v_schedule_id uuid;
  v_schedule jsonb;
  v_rules jsonb;
begin
  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  -- السلطة: صلاحية مسمّاة على هذا البئر. auth.uid() لـ anon
  -- وservice_role يكون null فالنتيجة false — الإجراء يفشل مغلقًا.
  if not iam.has_well_permission(p_well_id, 'price.read') then
    raise exception 'الاطلاع على التسعيرة متاح لمن يشغّل هذا البئر'
      using errcode = '42501';
  end if;

  select
    ps.id,
    jsonb_build_object(
      'id', ps.id,
      'well_id', ps.well_id,
      'name', ps.name,
      'status', ps.status,
      'reason', ps.reason,
      'effective_from', lower(ps.effective_period),
      'effective_to', upper(ps.effective_period),
      'approved_by', ps.approved_by,
      'created_at', ps.created_at
    )
  into v_schedule_id, v_schedule
  from ops.price_schedules ps
  where ps.well_id = p_well_id
    and ps.status = 'active'
    and ps.effective_period @> v_at
  order by
    lower(ps.effective_period) desc,
    ps.created_at desc,
    ps.id desc
  limit 1;

  -- غياب جدول ساري حالة مشروعة لا خطأ: تُعاد schedule = null
  -- وقواعد فارغة، والشاشة تعرضها كحالة «لا تسعير» صريحة.
  if v_schedule_id is null then
    return jsonb_build_object(
      'contract', 'get_active_price_schedule',
      'version', 1,
      'schedule', null,
      'rules', '[]'::jsonb
    );
  end if;

  select coalesce(
    jsonb_agg(x.item order by x.energy_source),
    '[]'::jsonb
  )
  into v_rules
  from (
    select
      pr.energy_source,
      jsonb_build_object(
        'id', pr.id,
        'energy_source', pr.energy_source,
        'diesel_pricing_model', pr.diesel_pricing_model,
        'hourly_rate_minor', pr.hourly_rate_minor,
        'operation_hourly_rate_minor', pr.operation_hourly_rate_minor,
        'fuel_price_per_liter_minor', pr.fuel_price_per_liter_minor
      ) as item
    from ops.price_rules pr
    where pr.price_schedule_id = v_schedule_id
    order by pr.energy_source
  ) x;

  return jsonb_build_object(
    'contract', 'get_active_price_schedule',
    'version', 1,
    'schedule', v_schedule,
    'rules', v_rules
  );
end;
$function$;

comment on function ops.read_active_price_schedule(uuid, timestamptz) is
  'م-41D7: قراءة الجدول الساري وقواعده متجاوزةً RLS المالك في هجرة 031، وسلطتها صلاحية price.read وحدها. الغلاف العام api.get_active_price_schedule يبقى INVOKER.';

revoke all on function ops.read_active_price_schedule(uuid, timestamptz)
  from public, anon, authenticated, service_role;

grant execute on function ops.read_active_price_schedule(uuid, timestamptz)
  to authenticated, service_role;

-- ==============================================================
-- 2. الغلاف العام: INVOKER رقيق يتحقق ثم يفوّض
--
-- ما يبقى داخل الغلاف هو ما يجب أن يبقى تحت RLS المتصل نفسه:
-- وجود جلسة (28000)، صلاحية المدخل (22023)، ورؤية البئر عبر سياسة
-- wells_select_staff_or_farmer_self (هجرة 079) — فبئر لا يملك عليه
-- المتصل تعيينًا لا يظهر له أصلًا، والنتيجة رفض 42501 لا جدول فارغ.
-- ثم تنتقل قراءة الأسعار وحدها إلى القارئ الداخلي.
--
-- المغلّف والمفاتيح والإصدار (version = 1) لم تتغير: ما تغيّر هو
-- مَن يُسمح له بالقراءة، لا شكل ما يُقرأ.
-- ==============================================================

create or replace function api.get_active_price_schedule(
  p_well_id uuid,
  p_at timestamptz default null
)
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
    raise exception 'يجب تسجيل الدخول قبل قراءة التسعير'
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

  return ops.read_active_price_schedule(p_well_id, coalesce(p_at, now()));
end;
$function$;

comment on function api.get_active_price_schedule(uuid, timestamptz) is
  'عقد قراءة التسعيرة السارية. م-41D7 نقل سلطته من price.manage (المالك وحده) إلى price.read الممنوحة لمن يشغّل البئر، والقراءة تمر عبر ops.read_active_price_schedule.';

revoke all on function api.get_active_price_schedule(uuid, timestamptz)
  from public, anon, authenticated, service_role;

grant execute on function api.get_active_price_schedule(uuid, timestamptz)
  to authenticated, service_role;

commit;
