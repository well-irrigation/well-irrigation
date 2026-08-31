-- 091 — عقود إدارة البئر: قراءة وكتابة (م-41D1)
--
-- المشكلة التي تغلقها هذه الهجرة:
-- شاشة إدارة البئر في Flutter تنادي تسع دوال RPC بأسماء مجرّدة لا
-- وجود لها في api إطلاقًا (get_well_details / update_well_details /
-- get_well_pumps / save_pump / get_active_price_schedule /
-- create_price_schedule / get_fuel_tanks). كل نداء يفشل صامتًا
-- ويُستبدل ببيانات تجريبية داخل المستودع، فتظهر الشاشة «ناجحة»
-- وهي لم تقرأ ولم تكتب شيئًا.
--
-- القواعد المطبقة (ق-82 / ق-88 / ق-98 / ق-113):
-- 1. api.* تبقى SECURITY INVOKER بلا أي SECURITY DEFINER.
-- 2. لا جداول ولا Views داخل api — دوال فقط.
-- 3. التفويض من السلطة القائمة: RLS + iam.has_well_permission،
--    لا من وسيط نطاق يرسله العميل.
-- 4. لا وسيط جدول/مخطط ديناميكي، وحدود النتائج مثبتة، وanon محجوب.
-- 5. الترتيب حتمي في كل قائمة.
-- 6. الرفض صريح: 28000 بلا جلسة، 22023 لمدخل غير صالح،
--    42501 لغياب الصلاحية. لا صفوف صفرية غامضة ولا نجاح كاذب.
--
-- تصحيحات مثبتة بالأدلة قبل الكتابة (لا Blind Remap):
-- أ) مصدر التسعير الحقيقي هو ops.price_schedules + ops.price_rules
--    (هجرة 031، وقيد 085 يحصر diesel_pricing_model في
--    'inclusive_hourly')، وليس billing.well_pricing القديم.
-- ب) core.wells لا تحتوي depth_meters ولا static_water_level_meters
--    ولا notes. الشاشة تعرض هذه الثلاثة فعلًا، فالإصلاح الصادق هو
--    إضافتها كأعمدة حقيقية (القسم 0) لا تجاهلها ولا تلفيقها.
-- ج) core.pumps تخزّن power_rating نصًا،
--    estimated_water_flow_liters_per_minute (لتر/دقيقة لا لتر/ثانية)،
--    estimated_fuel_ml_per_hour (مل/ساعة لا لتر/ساعة)، وحالاتها
--    active/inactive/maintenance/retired ولا وجود لـ running/standby.
--    العقود تُعيد أسماء ووحدات قاعدة البيانات كما هي، والتحويل
--    مسؤولية طبقة العرض بتخطيط صريح.
-- د) inventory.fuel_tanks لا تحتوي last_measured_at؛ تُشتق من آخر
--    حركة physical_count بحالة posted في inventory.fuel_transactions.
-- هـ) ق-79 (هجرة 072) نزعت INSERT/UPDATE/DELETE عن جداول المخططات
--    الداخلية من authenticated. لذلك لا تكتب أي دالة INVOKER جدولًا:
--    كل عقد كتابة هنا زوج — إجراء SECURITY DEFINER داخلي يحمل فحص
--    الصلاحية المسمّاة، وغلاف api رقيق INVOKER يبني المغلّف فقط
--    (نفس معمار هجرة 084).

begin;

-- ==============================================================
-- 0. إصلاح إضافي: بيانات البئر الفنية الثلاثة
--
-- إضافة أعمدة فقط، بلا تعديل ولا حذف لأي عمود قائم، وبلا أي
-- تأثير على الصفوف الموجودة (كلها nullable). لا مساس بالهجرات
-- 071–088 المجمّدة.
-- ==============================================================

alter table core.wells
  add column if not exists depth_meters numeric(8,2),
  add column if not exists static_water_level_meters numeric(8,2),
  add column if not exists notes text;

alter table core.wells
  drop constraint if exists wells_depth_meters_check;

alter table core.wells
  add constraint wells_depth_meters_check
    check (depth_meters is null or depth_meters > 0);

alter table core.wells
  drop constraint if exists wells_static_water_level_check;

alter table core.wells
  add constraint wells_static_water_level_check
    check (
      static_water_level_meters is null
      or static_water_level_meters >= 0
    );

comment on column core.wells.depth_meters is
  'عمق البئر بالأمتار. أضيف في 091 لأن شاشة إدارة البئر تعرضه.';

comment on column core.wells.static_water_level_meters is
  'مستوى الماء الساكن بالأمتار من سطح الأرض.';

-- السلطة داخل أجساد الدوال هي iam.has_well_permission وحدها: هجرة 082
-- أغلقت م-18 بمنع iam.has_well_role في أي جسم دالة، وبقاؤها في سياسات
-- RLS طبقة توافق فقط. لذلك التفويض هنا إمّا صلاحية مسمّاة، وإمّا نتيجة
-- RLS نفسها (صفر صفوف = رفض صريح 42501).
--
-- ملاحظة مقصودة: auth.uid() لـ service_role يكون null، فالنتيجة false
-- والعقد يفشل مغلقًا — service_role ليس عضوًا في بئر ولا يُفترض أن يكون.
grant execute on function iam.has_well_permission(uuid, text)
  to service_role;

-- --------------------------------------------------------------
-- 0.ب صلاحيتان جديدتان: well.update وpump.manage
--
-- سبب الإضافة: ق-79 (هجرة 072) نزعت INSERT/UPDATE/DELETE عن كل
-- جداول المخططات الداخلية من authenticated، فلا يمكن لعقد
-- SECURITY INVOKER أن يكتب. الكتابة تنتقل إلى إجراء
-- SECURITY DEFINER يتجاوز RLS، وحينها يصبح التفويض فحصًا صريحًا
-- بصلاحية مسمّاة داخل الإجراء — ولم تكن هاتان الصلاحيتان موجودتين
-- في الكتالوج (28/080/081).
--
-- أثر مقصود: كتالوج iam.permissions يصير 41 بدل 39،
-- وiam.role_permissions يصير 75 بدل 73 مع tenant_owner = 41.
-- حُدّثت أرقام الحرس في اختباري 080 و081 بتعليق يسمّي هجرة 091،
-- تمامًا كما حُدّثت سابقًا عند هجرة 081.
--
-- المنح للمالك فقط: تعديل بيانات البئر وإدارة مضخاته قرار مالك،
-- وهو ما تفرضه أصلًا سياسات RLS على core.wells وcore.pumps.
-- --------------------------------------------------------------

insert into iam.permissions (code, description_ar)
values
  ('well.update', 'تعديل بيانات البئر الأساسية والفنية'),
  ('pump.manage', 'إضافة وتعديل مضخات البئر')
on conflict (code) do nothing;

insert into iam.role_permissions (role_id, permission_id)
select r.id, p.id
from iam.roles r
join iam.permissions p on p.code in ('well.update', 'pump.manage')
where r.code = 'tenant_owner'
on conflict do nothing;

-- ==============================================================
-- 1. قراءة تفاصيل البئر
-- ==============================================================

create or replace function api.get_well_details(
  p_well_id uuid
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_well jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة بيانات البئر'
      using errcode = '28000';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  -- RLS على core.wells هي مصدر التفويض؛ البئر غير المرئي = رفض صريح
  -- بدل كائن فارغ غامض.
  select jsonb_build_object(
    'id', w.id,
    'tenant_id', w.tenant_id,
    'name', w.name,
    'location', w.location,
    'status', w.status,
    'depth_meters', w.depth_meters,
    'static_water_level_meters', w.static_water_level_meters,
    'notes', w.notes,
    'created_at', w.created_at,
    'updated_at', w.updated_at,
    'has_open_session', exists (
      select 1
      from ops.irrigation_sessions s
      where s.well_id = w.id
        and s.status = 'open'
    )
  )
  into v_well
  from core.wells w
  where w.id = p_well_id;

  if v_well is null then
    raise exception 'لا توجد صلاحية على هذا البئر'
      using errcode = '42501';
  end if;

  return jsonb_build_object(
    'contract', 'get_well_details',
    'version', 1,
    'well', v_well
  );
end;
$function$;

revoke all on function api.get_well_details(uuid)
  from public, anon, authenticated, service_role;

grant execute on function api.get_well_details(uuid)
  to authenticated, service_role;

-- ==============================================================
-- 2. تحديث بيانات البئر
--
-- ق-79 (هجرة 072): authenticated لا يملك أي DML مباشر على الجداول
-- الداخلية. فالكتابة تجري داخل إجراء SECURITY DEFINER في core،
-- وغلاف api يبقى INVOKER بلا سلطة إضافية. السلطة صلاحية مسمّاة
-- عبر iam.has_well_permission لا مصفوفة أدوار نصية.
--
-- الحقول الاختيارية تتبع دلالة «مرسَل = يُحدَّث»: تمرير null يعني
-- تفريغ الحقل عمدًا، لأن الشاشة ترسل النموذج كاملًا. الاسم وحده
-- إلزامي ولا يُقبل فارغًا.
-- ==============================================================

create or replace function core.update_well_details(
  p_well_id uuid,
  p_name text,
  p_location text default null,
  p_depth_meters numeric default null,
  p_static_water_level_meters numeric default null,
  p_notes text default null
)
returns uuid
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل تعديل بيانات البئر'
      using errcode = '28000';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  if v_name is null then
    raise exception 'اسم البئر مطلوب'
      using errcode = '22023';
  end if;

  if p_depth_meters is not null and p_depth_meters <= 0 then
    raise exception 'عمق البئر يجب أن يكون أكبر من صفر'
      using errcode = '22023';
  end if;

  if p_static_water_level_meters is not null
     and p_static_water_level_meters < 0 then
    raise exception 'مستوى الماء الساكن لا يكون سالبًا'
      using errcode = '22023';
  end if;

  -- السلطة صلاحية مسمّاة: well.update. الإجراء DEFINER يتجاوز RLS،
  -- فالفحص الصريح هنا هو الحد الوحيد ولا يجوز إغفاله.
  if not iam.has_well_permission(p_well_id, 'well.update') then
    raise exception 'لا توجد صلاحية لتعديل بيانات هذا البئر'
      using errcode = '42501';
  end if;

  update core.wells w
  set
    name = v_name,
    location = nullif(btrim(coalesce(p_location, '')), ''),
    depth_meters = p_depth_meters,
    static_water_level_meters = p_static_water_level_meters,
    notes = nullif(btrim(coalesce(p_notes, '')), ''),
    updated_at = now()
  where w.id = p_well_id;

  if not found then
    raise exception 'البئر غير موجود'
      using errcode = '22023';
  end if;

  return p_well_id;
end;
$function$;

revoke all on function core.update_well_details(
  uuid, text, text, numeric, numeric, text
) from public, anon, authenticated, service_role;

grant execute on function core.update_well_details(
  uuid, text, text, numeric, numeric, text
) to authenticated, service_role;

create or replace function api.update_well_details(
  p_well_id uuid,
  p_name text,
  p_location text default null,
  p_depth_meters numeric default null,
  p_static_water_level_meters numeric default null,
  p_notes text default null
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول قبل تعديل بيانات البئر'
      using errcode = '28000';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  return jsonb_build_object(
    'contract', 'update_well_details',
    'version', 1,
    'well_id', core.update_well_details(
      p_well_id,
      p_name,
      p_location,
      p_depth_meters,
      p_static_water_level_meters,
      p_notes
    )
  );
end;
$function$;

revoke all on function api.update_well_details(
  uuid, text, text, numeric, numeric, text
) from public, anon, authenticated, service_role;

grant execute on function api.update_well_details(
  uuid, text, text, numeric, numeric, text
) to authenticated, service_role;

-- ==============================================================
-- 3. قراءة مضخات البئر بمواصفاتها الكاملة
--
-- عقد 089 api.list_well_pumps يخدم شاشة بدء الجلسة: المضخات
-- النشطة بخمسة حقول فقط. شاشة الإدارة تحتاج المضخات كلها بكل
-- المواصفات، فهو عقد ثانٍ مستقل لا تعديلًا على الأول.
--
-- الوحدات تُعاد بأسماء قاعدة البيانات حرفيًا:
-- estimated_water_flow_liters_per_minute (لتر/دقيقة)
-- estimated_fuel_ml_per_hour (مل/ساعة)
-- power_rating (نص حر، ليس رقم قدرة حصانية)
-- ==============================================================

create or replace function api.list_well_pumps_detail(
  p_well_id uuid,
  p_include_inactive boolean default true
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_items jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة المضخات'
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
    jsonb_agg(x.item order by x.name, x.id),
    '[]'::jsonb
  )
  into v_items
  from (
    select
      pm.id,
      pm.name,
      jsonb_build_object(
        'id', pm.id,
        'well_id', pm.well_id,
        'public_code', pm.public_code,
        'name', pm.name,
        'pump_type', pm.pump_type,
        'power_rating', pm.power_rating,
        'estimated_water_flow_liters_per_minute',
          pm.estimated_water_flow_liters_per_minute,
        'estimated_fuel_ml_per_hour', pm.estimated_fuel_ml_per_hour,
        'status', pm.status,
        'installed_at', pm.installed_at,
        'notes', pm.notes,
        'is_in_open_session', exists (
          select 1
          from ops.irrigation_sessions s
          where s.pump_id = pm.id
            and s.status = 'open'
        )
      ) as item
    from core.pumps pm
    where pm.well_id = p_well_id
      and (
        coalesce(p_include_inactive, true)
        or pm.status = 'active'
      )
    order by pm.name, pm.id
  ) x;

  return jsonb_build_object(
    'contract', 'list_well_pumps_detail',
    'version', 1,
    'items', v_items
  );
end;
$function$;

revoke all on function api.list_well_pumps_detail(uuid, boolean)
  from public, anon, authenticated, service_role;

grant execute on function api.list_well_pumps_detail(uuid, boolean)
  to authenticated, service_role;

-- ==============================================================
-- 4. حفظ مضخة (إضافة أو تعديل)
--
-- p_pump_id = null يعني إضافة. القيم الاختيارية تتبع دلالة
-- «مرسَل = يُحدَّث» كما في تحديث البئر.
--
-- power_source القديم يبقى null للمضخات الجديدة: هجرة 076 تصفه
-- توافقًا تاريخيًا فقط، ومصدر الطاقة الفعلي في مقاطع الجلسة.
--
-- الكتابة داخل إجراء DEFINER في core لنفس سبب القسم 2 (ق-79).
-- ==============================================================

create or replace function core.save_well_pump(
  p_well_id uuid,
  p_name text,
  p_pump_id uuid default null,
  p_pump_type text default null,
  p_power_rating text default null,
  p_estimated_water_flow_liters_per_minute numeric default null,
  p_estimated_fuel_ml_per_hour bigint default null,
  p_status text default 'active',
  p_installed_at date default null,
  p_notes text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_status text := coalesce(nullif(btrim(coalesce(p_status, '')), ''), 'active');
  v_pump_id uuid;
  v_created boolean := false;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل حفظ المضخة'
      using errcode = '28000';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  if v_name is null then
    raise exception 'اسم المضخة مطلوب'
      using errcode = '22023';
  end if;

  -- الحالات المسموحة هي حالات قاعدة البيانات نفسها. أي قيمة أخرى
  -- (مثل running أو standby التي كانت الشاشة ترسلها) ترفض صريحًا
  -- ولا تُترجَم ضمنيًا.
  if v_status not in ('active', 'inactive', 'maintenance', 'retired') then
    raise exception 'حالة المضخة غير مقبولة: %', v_status
      using errcode = '22023';
  end if;

  if p_estimated_water_flow_liters_per_minute is not null
     and p_estimated_water_flow_liters_per_minute < 0 then
    raise exception 'تدفق الماء لا يكون سالبًا'
      using errcode = '22023';
  end if;

  if p_estimated_fuel_ml_per_hour is not null
     and p_estimated_fuel_ml_per_hour < 0 then
    raise exception 'معدل الوقود لا يكون سالبًا'
      using errcode = '22023';
  end if;

  -- السلطة صلاحية مسمّاة: pump.manage. الإجراء DEFINER يتجاوز RLS.
  if not iam.has_well_permission(p_well_id, 'pump.manage') then
    raise exception 'لا توجد صلاحية لإدارة مضخات هذا البئر'
      using errcode = '42501';
  end if;

  if p_pump_id is null then
    insert into core.pumps (
      well_id, name, pump_type, power_rating,
      estimated_water_flow_liters_per_minute,
      estimated_fuel_ml_per_hour, status, installed_at, notes
    )
    values (
      p_well_id, v_name,
      nullif(btrim(coalesce(p_pump_type, '')), ''),
      nullif(btrim(coalesce(p_power_rating, '')), ''),
      p_estimated_water_flow_liters_per_minute,
      p_estimated_fuel_ml_per_hour, v_status,
      p_installed_at,
      nullif(btrim(coalesce(p_notes, '')), '')
    )
    returning id into v_pump_id;

    v_created := true;
  else
    if not exists (
      select 1
      from core.pumps pm
      where pm.id = p_pump_id
        and pm.well_id = p_well_id
    ) then
      raise exception 'المضخة غير موجودة في هذا البئر'
        using errcode = '22023';
    end if;

    -- تعطيل مضخة لها جلسة جارية يخلق تناقضًا في العمليات، فيرفض.
    if v_status <> 'active'
       and exists (
         select 1
         from ops.irrigation_sessions s
         where s.pump_id = p_pump_id
           and s.status = 'open'
       ) then
      raise exception 'لا يمكن تغيير حالة مضخة لها جلسة جارية'
        using errcode = '22023';
    end if;

    update core.pumps pm
    set
      name = v_name,
      pump_type = nullif(btrim(coalesce(p_pump_type, '')), ''),
      power_rating = nullif(btrim(coalesce(p_power_rating, '')), ''),
      estimated_water_flow_liters_per_minute =
        p_estimated_water_flow_liters_per_minute,
      estimated_fuel_ml_per_hour = p_estimated_fuel_ml_per_hour,
      status = v_status,
      installed_at = p_installed_at,
      notes = nullif(btrim(coalesce(p_notes, '')), '')
    where pm.id = p_pump_id
      and pm.well_id = p_well_id;

    if not found then
      raise exception 'تعذر تحديث المضخة'
        using errcode = '42501';
    end if;

    v_pump_id := p_pump_id;
  end if;

  return jsonb_build_object(
    'pump_id', v_pump_id,
    'created', v_created
  );
end;
$function$;

revoke all on function core.save_well_pump(
  uuid, text, uuid, text, text, numeric, bigint, text, date, text
) from public, anon, authenticated, service_role;

grant execute on function core.save_well_pump(
  uuid, text, uuid, text, text, numeric, bigint, text, date, text
) to authenticated, service_role;

create or replace function api.save_well_pump(
  p_well_id uuid,
  p_name text,
  p_pump_id uuid default null,
  p_pump_type text default null,
  p_power_rating text default null,
  p_estimated_water_flow_liters_per_minute numeric default null,
  p_estimated_fuel_ml_per_hour bigint default null,
  p_status text default 'active',
  p_installed_at date default null,
  p_notes text default null
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول قبل حفظ المضخة'
      using errcode = '28000';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  return jsonb_build_object(
    'contract', 'save_well_pump',
    'version', 1
  ) || core.save_well_pump(
    p_well_id,
    p_name,
    p_pump_id,
    p_pump_type,
    p_power_rating,
    p_estimated_water_flow_liters_per_minute,
    p_estimated_fuel_ml_per_hour,
    p_status,
    p_installed_at,
    p_notes
  );
end;
$function$;

revoke all on function api.save_well_pump(
  uuid, text, uuid, text, text, numeric, bigint, text, date, text
) from public, anon, authenticated, service_role;

grant execute on function api.save_well_pump(
  uuid, text, uuid, text, text, numeric, bigint, text, date, text
) to authenticated, service_role;

-- ==============================================================
-- 5. قراءة جدول التسعير الساري
--
-- المصدر ops.price_schedules + ops.price_rules، وأسلوب الاختيار
-- مطابق حرفيًا لما يستخدمه محرك الجلسات في هجرة 066:
-- status = 'active' و effective_period يحتوي اللحظة، ثم الترتيب
-- بـ lower(effective_period) تنازليًا ثم created_at ثم id.
-- التسعير بيانات حساسة: RLS على price_schedules تحصره بالمالك،
-- فغير المالك يحصل على رفض 42501 لا على جدول فارغ.
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
  v_at timestamptz := coalesce(p_at, now());
  v_schedule_id uuid;
  v_schedule jsonb;
  v_rules jsonb;
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

  if not iam.has_well_permission(p_well_id, 'price.manage') then
    raise exception 'قراءة التسعير متاحة لمن يملك صلاحية إدارة الأسعار'
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

revoke all on function api.get_active_price_schedule(uuid, timestamptz)
  from public, anon, authenticated, service_role;

grant execute on function api.get_active_price_schedule(uuid, timestamptz)
  to authenticated, service_role;

-- ==============================================================
-- 6. إنشاء جدول تسعير جديد
--
-- الأسعار *_minor بريالات كاملة (ق-77). النمط مطابق لما تفعله
-- core.setup_well_full في هجرة 086: جدول واحد status='active'
-- وقاعدة واحدة لكل مصدر طاقة، وwell_diesel تحمل
-- diesel_pricing_model = 'inclusive_hourly' (القيمة الوحيدة
-- المسموحة بعد قيد 085).
--
-- الجدول السابق يُقصّ حدّه الأعلى عند تاريخ سريان الجديد، ويصبح
-- 'expired' إن كان التاريخ قد حلّ. الجلسات المفوترة سابقًا لا
-- تتأثر: أسعارها ملتقطة داخل مقاطع الجلسة (ق-99).
--
-- الكتابة داخل إجراء DEFINER في ops لنفس سبب القسم 2 (ق-79).
-- ==============================================================

create or replace function ops.create_price_schedule(
  p_well_id uuid,
  p_name text,
  p_effective_from timestamptz default null,
  p_reason text default null,
  p_solar_rate_minor bigint default null,
  p_well_diesel_rate_minor bigint default null,
  p_farmer_diesel_rate_minor bigint default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_from timestamptz := coalesce(p_effective_from, now());
  v_tenant_id uuid;
  v_schedule_id uuid;
  v_conflict timestamptz;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إنشاء جدول تسعير'
      using errcode = '28000';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  if v_name is null then
    raise exception 'اسم جدول التسعير مطلوب'
      using errcode = '22023';
  end if;

  if coalesce(p_solar_rate_minor, 0) <= 0
     and coalesce(p_well_diesel_rate_minor, 0) <= 0
     and coalesce(p_farmer_diesel_rate_minor, 0) <= 0 then
    raise exception 'يجب تحديد سعر واحد على الأقل أكبر من صفر'
      using errcode = '22023';
  end if;

  if coalesce(p_solar_rate_minor, 0) < 0
     or coalesce(p_well_diesel_rate_minor, 0) < 0
     or coalesce(p_farmer_diesel_rate_minor, 0) < 0 then
    raise exception 'الأسعار لا تكون سالبة'
      using errcode = '22023';
  end if;

  -- السلطة القائمة (ق-113): price.manage. حاليًا لا تُمنح إلا
  -- لحزمة tenant_owner، أي المالك — وهو نفس ما تطلبه سياسة
  -- price_schedules_insert_owner، فلا تعارض بين الطبقتين.
  -- الإجراء DEFINER يتجاوز RLS، فهذا الفحص هو التفويض الفعلي.
  if not iam.has_well_permission(p_well_id, 'price.manage') then
    raise exception 'إدارة التسعير متاحة للمالك فقط'
      using errcode = '42501';
  end if;

  select w.tenant_id
  into v_tenant_id
  from core.wells w
  where w.id = p_well_id;

  if v_tenant_id is null then
    raise exception 'لا توجد صلاحية على هذا البئر'
      using errcode = '42501';
  end if;

  -- منع الجداول المتراكبة: تاريخ السريان يجب أن يكون بعد بداية
  -- أي جدول قائم، وإلا استحال قصّ الحدّ الأعلى بشكل صحيح.
  select lower(ps.effective_period)
  into v_conflict
  from ops.price_schedules ps
  where ps.well_id = p_well_id
    and ps.status = 'active'
    and lower(ps.effective_period) >= v_from
  order by lower(ps.effective_period) desc
  limit 1;

  if v_conflict is not null then
    raise exception
      'يوجد جدول تسعير يبدأ في % أو بعده؛ اختر تاريخًا لاحقًا',
      v_conflict
      using errcode = '22023';
  end if;

  update ops.price_schedules ps
  set
    effective_period = tstzrange(lower(ps.effective_period), v_from),
    status = case
      when v_from <= now() then 'expired'
      else ps.status
    end
  where ps.well_id = p_well_id
    and ps.status = 'active'
    and (
      upper(ps.effective_period) is null
      or upper(ps.effective_period) > v_from
    );

  insert into ops.price_schedules (
    tenant_id, well_id, name, effective_period,
    status, reason, approved_by
  )
  values (
    v_tenant_id, p_well_id, v_name,
    tstzrange(v_from, null), 'active',
    nullif(btrim(coalesce(p_reason, '')), ''),
    v_actor
  )
  returning id into v_schedule_id;

  if coalesce(p_solar_rate_minor, 0) > 0 then
    insert into ops.price_rules (
      tenant_id, price_schedule_id, energy_source, hourly_rate_minor
    )
    values (
      v_tenant_id, v_schedule_id, 'solar', p_solar_rate_minor
    );
  end if;

  if coalesce(p_well_diesel_rate_minor, 0) > 0 then
    insert into ops.price_rules (
      tenant_id, price_schedule_id, energy_source,
      diesel_pricing_model, hourly_rate_minor
    )
    values (
      v_tenant_id, v_schedule_id, 'well_diesel',
      'inclusive_hourly', p_well_diesel_rate_minor
    );
  end if;

  if coalesce(p_farmer_diesel_rate_minor, 0) > 0 then
    insert into ops.price_rules (
      tenant_id, price_schedule_id, energy_source, hourly_rate_minor
    )
    values (
      v_tenant_id, v_schedule_id, 'farmer_diesel',
      p_farmer_diesel_rate_minor
    );
  end if;

  return jsonb_build_object(
    'schedule_id', v_schedule_id,
    'effective_from', v_from
  );
end;
$function$;

revoke all on function ops.create_price_schedule(
  uuid, text, timestamptz, text, bigint, bigint, bigint
) from public, anon, authenticated, service_role;

grant execute on function ops.create_price_schedule(
  uuid, text, timestamptz, text, bigint, bigint, bigint
) to authenticated, service_role;

create or replace function api.create_price_schedule(
  p_well_id uuid,
  p_name text,
  p_effective_from timestamptz default null,
  p_reason text default null,
  p_solar_rate_minor bigint default null,
  p_well_diesel_rate_minor bigint default null,
  p_farmer_diesel_rate_minor bigint default null
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول قبل إنشاء جدول تسعير'
      using errcode = '28000';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  return jsonb_build_object(
    'contract', 'create_price_schedule',
    'version', 1
  ) || ops.create_price_schedule(
    p_well_id,
    p_name,
    p_effective_from,
    p_reason,
    p_solar_rate_minor,
    p_well_diesel_rate_minor,
    p_farmer_diesel_rate_minor
  );
end;
$function$;

revoke all on function api.create_price_schedule(
  uuid, text, timestamptz, text, bigint, bigint, bigint
) from public, anon, authenticated, service_role;

grant execute on function api.create_price_schedule(
  uuid, text, timestamptz, text, bigint, bigint, bigint
) to authenticated, service_role;

-- ==============================================================
-- 7. قراءة خزانات وقود البئر
--
-- الأرصدة والسعات بالمليلتر كما في inventory.fuel_tanks حرفيًا،
-- بلا أي تحويل إلى لتر داخل عقد القراءة.
-- last_measured_at مشتق من آخر حركة جرد فعلي (physical_count)
-- بحالة posted، لأن العمود غير موجود في الجدول.
-- ==============================================================

create or replace function api.list_well_fuel_tanks(
  p_well_id uuid,
  p_include_inactive boolean default false
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_items jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة خزانات الوقود'
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
    jsonb_agg(x.item order by x.name, x.id),
    '[]'::jsonb
  )
  into v_items
  from (
    select
      ft.id,
      ft.name,
      jsonb_build_object(
        'id', ft.id,
        'well_id', ft.well_id,
        'public_code', ft.public_code,
        'name', ft.name,
        'capacity_ml', ft.capacity_ml,
        'current_balance_ml', ft.current_balance_ml,
        'avg_cost_per_liter_minor', ft.avg_cost_per_liter_minor,
        'measurement_method', ft.measurement_method,
        'status', ft.status,
        'notes', ft.notes,
        'last_measured_at', (
          select max(tr.occurred_at)
          from inventory.fuel_transactions tr
          where tr.fuel_tank_id = ft.id
            and tr.transaction_type = 'physical_count'
            and tr.status = 'posted'
        )
      ) as item
    from inventory.fuel_tanks ft
    where ft.well_id = p_well_id
      and (
        coalesce(p_include_inactive, false)
        or ft.status = 'active'
      )
    order by ft.name, ft.id
  ) x;

  return jsonb_build_object(
    'contract', 'list_well_fuel_tanks',
    'version', 1,
    'items', v_items
  );
end;
$function$;

revoke all on function api.list_well_fuel_tanks(uuid, boolean)
  from public, anon, authenticated, service_role;

grant execute on function api.list_well_fuel_tanks(uuid, boolean)
  to authenticated, service_role;

commit;
