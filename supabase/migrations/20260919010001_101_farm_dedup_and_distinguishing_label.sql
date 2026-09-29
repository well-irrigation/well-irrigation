-- =====================================================================
-- Migration 101 — Farm Deduplication, Distinguishing Label, and Outbox Integration
-- المسألة: م-21 (تكرار إنشاء أرض الكوثة وتوحيد مسار الإرسال المتين)
-- القرارات الحاكمة: ق-80، ق-84، ق-88، ق-89، ق-113، ق-114
--
-- أهداف الهجرة:
--   1. إضافة حقل الصفة المميزة ops.farms.distinguishing_label text null
--      مع قيد التحقق من عدم الفراغ.
--   2. تأمين قفل تسلسلي ذري على مستوى هوية القاعدة ops.lock_farm_base_identity
--      باستخدام core.normalize_arabic ودون إدخال الصفة المميزة في مفتاح القفل.
--   3. جدول علامات الفرادة ops.farm_identity_markers ومحفّز الحماية
--      ops.trg_enforce_farm_uniqueness لحماية التزامن المباشر ومنع إنشاء
--      أي صف مكرر مستقبلاً دون المساس بصفوف الكوثة التاريخية.
--   4. ترقية ops.create_farm لتطبيق مصفوفة أعمال فرادة الأراضي:
--      - 0 مطابق -> إنشاء (created).
--      - 1 مطابق -> مطابقة القائم (matched_existing).
--      - >1 مطابق -> تعارض يتطلب مراجعة (requires_resolution).
--      - وجود أشقاء بصفات مميزة مع طلب بدون صفة -> (requires_disambiguation).
--   5. ترقية api.create_farm بالتوقيع المطور (p_command_id اختياري في الأخير)
--      وإنهاء العمليات الناجحة كـ accepted والمتعارضة كـ conflict في sync.processed_commands،
--      مع دعم إعادة التشغيل المتطابقة لكلتا الحالتين.
--   6. تحديث api.list_well_farms ليعيد distinguishing_label.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. إضافة عمود الصفة المميزة ops.farms.distinguishing_label
-- ---------------------------------------------------------------------

alter table ops.farms
  add column if not exists distinguishing_label text null
  check (
    distinguishing_label is null
    or nullif(btrim(distinguishing_label), '') is not null
  );

comment on column ops.farms.distinguishing_label is
  'صفة مميزة اختيارية للأرض الزراعية (مثل: الشرقية، الغربية) لتمييز الأراضي ذات الاسم المشترك للمزارع نفسه دون دمجها في الاسم الأساسي.';

-- ---------------------------------------------------------------------
-- 2. جدول علامات فرادة الأراضي (Enforcement Marker)
--    يضمن فرادة الأراضي النشطة مستقبلاً حتى في حالات INSERT المتزامنة المباشرة
--    دون تعديل أو حذف أي صف تاريخي قائم.
-- ---------------------------------------------------------------------

create table if not exists ops.farm_identity_markers (
  well_id uuid not null,
  farmer_well_account_id uuid not null,
  normalized_name text not null,
  normalized_label text not null default '',
  created_at timestamptz not null default clock_timestamp(),
  primary key (well_id, farmer_well_account_id, normalized_name, normalized_label)
);

alter table ops.farm_identity_markers enable row level security;

-- جدول علامات الفرادة داخلي بحت: لا يُقرأ ولا يُكتب من العميل مباشرة.
-- المحفّز `trg_enforce_farm_uniqueness` و`ops.create_farm` كلاهما
-- SECURITY DEFINER يُدير هذا الجدول بصلاحية المالك، فلا حاجة لأي منح
-- مباشر لـ authenticated (وإلا لصار كتابةً مباشرة على جدول داخلي يرصدها
-- عقد 072/ق-82). لا service_role كذلك: لا مسار عقد داخلي يكتبه بدوره.
revoke all on ops.farm_identity_markers from public, anon, authenticated, service_role;

-- إدراج علامات للأراضي النشطة القائمة غير المكررة فقط
-- صفوف الكوثة التاريخية المكررة (count > 1) تُستثنى بفضل having count(*) = 1
-- فلا تفشل الهجرة ولا يُعدل أو يُحذف أي صف من صفي الكوثة.
insert into ops.farm_identity_markers (
  well_id,
  farmer_well_account_id,
  normalized_name,
  normalized_label
)
select
  f.well_id,
  f.farmer_well_account_id,
  core.normalize_arabic(f.name),
  coalesce(core.normalize_arabic(f.distinguishing_label), '')
from ops.farms f
where f.status = 'active'
  and f.farmer_well_account_id is not null
group by
  f.well_id,
  f.farmer_well_account_id,
  core.normalize_arabic(f.name),
  coalesce(core.normalize_arabic(f.distinguishing_label), '')
having count(*) = 1
on conflict do nothing;

-- ---------------------------------------------------------------------
-- 3. إجراء قفل تسلسل الهوية الأساسية (Base Identity Lock)
--    يقفل ذرياً على مستوى: tenant_id + well_id + farmer_well_account_id + normalized_base
--    دون إدخال الصفة المميزة حتى تتسلسل كل عمليات نفس الاسم الأساسي للمزارع.
-- ---------------------------------------------------------------------

create or replace function ops.lock_farm_base_identity(
  p_well_id uuid,
  p_farmer_well_account_id uuid,
  p_name text
)
returns void
language plpgsql
security definer
set search_path = ops, core, pg_catalog, pg_temp
as $function$
declare
  v_tenant_id uuid;
  v_norm_base text;
  v_lock_str text;
  v_lock_key bigint;
begin
  if p_well_id is null or p_farmer_well_account_id is null or nullif(btrim(p_name), '') is null then
    return;
  end if;

  select w.tenant_id
  into v_tenant_id
  from core.wells w
  where w.id = p_well_id;

  if v_tenant_id is null then
    return;
  end if;

  v_norm_base := core.normalize_arabic(btrim(p_name));
  v_lock_str := 'farm_base:' || v_tenant_id::text || ':' || p_well_id::text || ':' || p_farmer_well_account_id::text || ':' || v_norm_base;
  v_lock_key := ('x' || substr(md5(v_lock_str), 1, 16))::bit(64)::bigint;

  perform pg_advisory_xact_lock(v_lock_key);
end;
$function$;

comment on function ops.lock_farm_base_identity(uuid, uuid, text) is
  'ق-114/م-21: قفل تسلسلي استشاري على هوية الأرض الأساسية للمزارع في البئر لمنع سباق الإنشاء المتزامن.';

-- قفل داخلي بحت: يُنادى فقط من داخل `trg_enforce_farm_uniqueness`
-- و`ops.create_farm`، وكلاهما SECURITY DEFINER فيُنفَّذ بصلاحية مالك
-- الدالة لا المتصل. فلا يحتاج العميل EXECUTE مباشرًا عليه.
revoke all on function ops.lock_farm_base_identity(uuid, uuid, text)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 4. مشغّل حماية فرادة الأراضي على جدول ops.farms
-- ---------------------------------------------------------------------

create or replace function ops.trg_enforce_farm_uniqueness()
returns trigger
language plpgsql
security definer
set search_path = ops, core, pg_catalog, pg_temp
as $function$
declare
  v_norm_base text;
  v_norm_label text;
  v_old_norm_base text;
  v_old_norm_label text;
  v_exact_count integer := 0;
  v_labeled_siblings integer := 0;
begin
  -- عند الحذف: إزالة علامة الفرادة إن وُجدت
  if TG_OP = 'DELETE' then
    if OLD.farmer_well_account_id is not null then
      delete from ops.farm_identity_markers
      where well_id = OLD.well_id
        and farmer_well_account_id = OLD.farmer_well_account_id
        and normalized_name = core.normalize_arabic(OLD.name)
        and normalized_label = coalesce(core.normalize_arabic(OLD.distinguishing_label), '');
    end if;
    return OLD;
  end if;

  -- السماح دائماً بالتحويل من فعال إلى غير فعال (أرشفة/تعطيل)
  if TG_OP = 'UPDATE' and OLD.status = 'active' and NEW.status <> 'active' then
    if OLD.farmer_well_account_id is not null then
      delete from ops.farm_identity_markers
      where well_id = OLD.well_id
        and farmer_well_account_id = OLD.farmer_well_account_id
        and normalized_name = core.normalize_arabic(OLD.name)
        and normalized_label = coalesce(core.normalize_arabic(OLD.distinguishing_label), '');
    end if;
    return NEW;
  end if;

  -- الحالات غير الفعالة لا تفرض فرادة نشطة
  if NEW.status <> 'active' then
    return NEW;
  end if;

  -- تنظيف المدخلات
  NEW.name := btrim(NEW.name);
  if nullif(NEW.name, '') is null then
    raise exception 'اسم الأرض مطلوب';
  end if;
  NEW.distinguishing_label := nullif(btrim(NEW.distinguishing_label), '');

  if NEW.farmer_well_account_id is null then
    return NEW;
  end if;

  v_norm_base := core.normalize_arabic(NEW.name);
  v_norm_label := coalesce(core.normalize_arabic(NEW.distinguishing_label), '');

  -- فحص ما إذا كان التحديث لم يمس الهوية الأساسية
  if TG_OP = 'UPDATE' and OLD.status = 'active' then
    v_old_norm_base := core.normalize_arabic(OLD.name);
    v_old_norm_label := coalesce(core.normalize_arabic(OLD.distinguishing_label), '');
    if v_old_norm_base = v_norm_base
       and v_old_norm_label = v_norm_label
       and OLD.farmer_well_account_id = NEW.farmer_well_account_id
       and OLD.well_id = NEW.well_id then
      return NEW;
    end if;

    -- إذا تغيرت الهوية، احذف العلامة القديمة
    delete from ops.farm_identity_markers
    where well_id = OLD.well_id
      and farmer_well_account_id = OLD.farmer_well_account_id
      and normalized_name = v_old_norm_base
      and normalized_label = v_old_norm_label;
  end if;

  -- قفل تسلسلي
  perform ops.lock_farm_base_identity(NEW.well_id, NEW.farmer_well_account_id, NEW.name);

  -- التحقق من عدم وجود أرض نشطة مطابقة تماماً في جدول الأراضي
  select count(*)
  into v_exact_count
  from ops.farms f
  where f.well_id = NEW.well_id
    and f.farmer_well_account_id = NEW.farmer_well_account_id
    and f.status = 'active'
    and (TG_OP = 'INSERT' or f.id <> NEW.id)
    and core.normalize_arabic(f.name) = v_norm_base
    and coalesce(core.normalize_arabic(f.distinguishing_label), '') = v_norm_label;

  if v_exact_count > 0 then
    raise exception 'يوجد بالفعل أرض فعالة مطابقة تماماً للمزارع في هذا البئر'
      using errcode = '23505';
  end if;

  -- التحقق من شرط التمييز إذا لم تُحدد صفة مميزة
  if NEW.distinguishing_label is null then
    select count(*)
    into v_labeled_siblings
    from ops.farms f
    where f.well_id = NEW.well_id
      and f.farmer_well_account_id = NEW.farmer_well_account_id
      and f.status = 'active'
      and (TG_OP = 'INSERT' or f.id <> NEW.id)
      and core.normalize_arabic(f.name) = v_norm_base
      and f.distinguishing_label is not null;

    if v_labeled_siblings > 0 then
      raise exception 'توجد أراضٍ بنفس الاسم مع صفات مميزة؛ يجب تحديد صفة مميزة لهذه الأرض'
        using errcode = '23514';
    end if;
  end if;

  -- تسجيل علامة الفرادة؛ إذا حاول إدخال متزامن إدخال نفس العلامة فسيمنعه المفتاح الأساسي
  insert into ops.farm_identity_markers (
    well_id,
    farmer_well_account_id,
    normalized_name,
    normalized_label
  ) values (
    NEW.well_id,
    NEW.farmer_well_account_id,
    v_norm_base,
    v_norm_label
  );

  return NEW;
end;
$function$;

drop trigger if exists trg_enforce_farm_uniqueness on ops.farms;
create trigger trg_enforce_farm_uniqueness
  before insert or update or delete on ops.farms
  for each row
  execute function ops.trg_enforce_farm_uniqueness();

-- ---------------------------------------------------------------------
-- 5. إجراء ops.create_farm المطور (4 وسائط)
-- ---------------------------------------------------------------------

drop function if exists ops.create_farm(uuid, text, uuid);

create or replace function ops.create_farm(
  p_well_id uuid,
  p_name text,
  p_farmer_well_account_id uuid,
  p_distinguishing_label text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ops, core, audit, iam, pg_temp
as $function$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_farm_id uuid;
  v_clean_name text;
  v_clean_label text;
  v_norm_base text;
  v_norm_label text;
  v_exact_count integer := 0;
  v_labeled_siblings_count integer := 0;
  v_candidate_ids jsonb;
  v_existing_labels jsonb;
  v_matched_farm ops.farms%rowtype;
begin
  v_actor := auth.uid();

  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إنشاء أرض';
  end if;

  if not iam.has_well_permission(p_well_id, 'farm.create') then
    raise exception 'لا تملك صلاحية إنشاء أرض في هذا البئر';
  end if;

  v_clean_name := nullif(btrim(p_name), '');
  if v_clean_name is null then
    raise exception 'اسم الأرض مطلوب';
  end if;

  v_clean_label := nullif(btrim(p_distinguishing_label), '');

  select w.tenant_id
  into v_tenant_id
  from core.wells w
  where w.id = p_well_id;

  if not found then
    raise exception 'البئر غير موجود: %', p_well_id;
  end if;

  if p_farmer_well_account_id is null
     or not exists (
       select 1
       from ops.farmer_well_accounts fwa
       where fwa.id = p_farmer_well_account_id
         and fwa.well_id = p_well_id
         and fwa.tenant_id = v_tenant_id
         and fwa.status = 'active'
     ) then
    raise exception 'حساب المزارع غير موجود أو غير فعال في هذا البئر';
  end if;

  -- 1. القفل التسلسلي لهوية القاعدة
  perform ops.lock_farm_base_identity(p_well_id, p_farmer_well_account_id, v_clean_name);

  v_norm_base := core.normalize_arabic(v_clean_name);
  v_norm_label := coalesce(core.normalize_arabic(v_clean_label), '');

  -- 2. حصر المطابقات التامة القائمة
  select
    count(*),
    coalesce(jsonb_agg(f.id order by f.created_at, f.id), '[]'::jsonb)
  into
    v_exact_count,
    v_candidate_ids
  from ops.farms f
  where f.well_id = p_well_id
    and f.farmer_well_account_id = p_farmer_well_account_id
    and f.status = 'active'
    and core.normalize_arabic(f.name) = v_norm_base
    and coalesce(core.normalize_arabic(f.distinguishing_label), '') = v_norm_label;

  -- 3. حالة وجود أكثر من مرشح مطابق تماماً (عنقود تاريخي ملتبس) -> تعارض يتطلب مراجعة
  if v_exact_count > 1 then
    return jsonb_build_object(
      'status', 'requires_resolution',
      'reason', 'multiple_exact_candidates',
      'well_id', p_well_id,
      'farmer_well_account_id', p_farmer_well_account_id,
      'name', v_clean_name,
      'distinguishing_label', v_clean_label,
      'candidate_farm_ids', v_candidate_ids
    );
  end if;

  -- 4. حالة وجود مرشح مطابق تماماً واحد فقط -> إعادة استخدام القائم
  if v_exact_count = 1 then
    select *
    into v_matched_farm
    from ops.farms f
    where f.well_id = p_well_id
      and f.farmer_well_account_id = p_farmer_well_account_id
      and f.status = 'active'
      and core.normalize_arabic(f.name) = v_norm_base
      and coalesce(core.normalize_arabic(f.distinguishing_label), '') = v_norm_label
    limit 1;

    return jsonb_build_object(
      'status', 'matched_existing',
      'farm_id', v_matched_farm.id,
      'well_id', p_well_id,
      'farmer_well_account_id', p_farmer_well_account_id,
      'name', v_matched_farm.name,
      'distinguishing_label', v_matched_farm.distinguishing_label,
      'already_exists', true
    );
  end if;

  -- 5. في حالة عدم وجود مطابق تام، وكان الطلب دون صفة مميزة:
  -- فحص ما إذا كان للمزارع أراضٍ أخرى بنفس الاسم الأساسي تحمل صفات مميزة
  if v_clean_label is null then
    select
      count(*),
      coalesce(jsonb_agg(distinct f.distinguishing_label), '[]'::jsonb)
    into
      v_labeled_siblings_count,
      v_existing_labels
    from ops.farms f
    where f.well_id = p_well_id
      and f.farmer_well_account_id = p_farmer_well_account_id
      and f.status = 'active'
      and core.normalize_arabic(f.name) = v_norm_base
      and f.distinguishing_label is not null;

    if v_labeled_siblings_count > 0 then
      return jsonb_build_object(
        'status', 'requires_disambiguation',
        'reason', 'labeled_siblings_exist',
        'well_id', p_well_id,
        'farmer_well_account_id', p_farmer_well_account_id,
        'name', v_clean_name,
        'existing_labels', v_existing_labels
      );
    end if;
  end if;

  -- 6. إنشاء الأرض الجديدة
  insert into ops.farms (
    well_id,
    name,
    farmer_well_account_id,
    distinguishing_label,
    status
  )
  values (
    p_well_id,
    v_clean_name,
    p_farmer_well_account_id,
    v_clean_label,
    'active'
  )
  returning id into v_farm_id;

  perform audit.log(
    v_tenant_id,
    p_well_id,
    'create_farm',
    'ops.farms',
    v_farm_id,
    null,
    jsonb_build_object(
      'farm_id', v_farm_id,
      'name', v_clean_name,
      'distinguishing_label', v_clean_label,
      'farmer_well_account_id', p_farmer_well_account_id
    ),
    'إنشاء أرض للمزارع'
  );

  return jsonb_build_object(
    'status', 'created',
    'farm_id', v_farm_id,
    'well_id', p_well_id,
    'farmer_well_account_id', p_farmer_well_account_id,
    'name', v_clean_name,
    'distinguishing_label', v_clean_label
  );
end;
$function$;

revoke all on function ops.create_farm(uuid, text, uuid, text)
  from public, anon, authenticated, service_role;
grant execute on function ops.create_farm(uuid, text, uuid, text)
  to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 6. غلاف api.create_farm بالتوقيع المطور (5 وسائط، p_command_id اختياري في الأخير)
-- ---------------------------------------------------------------------

drop function if exists api.create_farm(uuid, text, uuid, uuid);

create or replace function api.create_farm(
  p_well_id uuid,
  p_name text,
  p_farmer_well_account_id uuid,
  p_distinguishing_label text default null,
  p_command_id uuid default null
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_guard jsonb;
  v_result jsonb;
  v_status text;
begin
  if p_command_id is not null then
    v_guard := sync.begin_well_command(
      p_well_id,
      p_command_id,
      'create_farm',
      null
    );

    if coalesce((v_guard ->> 'duplicate')::boolean, false) then
      -- إعادة التشغيل المتطابقة: accepted أو conflict تعيد الرد المخزن المطابق
      if v_guard ->> 'status' in ('accepted', 'conflict') then
        return v_guard -> 'response';
      end if;
      raise exception 'العملية نفسها قيد المعالجة أو تحتاج مراجعة';
    end if;
  end if;

  v_result := ops.create_farm(
    p_well_id,
    p_name,
    p_farmer_well_account_id,
    p_distinguishing_label
  );

  if p_command_id is not null then
    if v_result ->> 'status' in ('created', 'matched_existing') then
      v_status := 'accepted';
    elsif v_result ->> 'status' in ('requires_resolution', 'requires_disambiguation') then
      v_status := 'conflict';
    else
      raise exception 'حالة غير متوقعة لإنشاء الأرض: %', coalesce(v_result ->> 'status', 'null');
    end if;

    perform sync.finish_well_command(
      p_well_id,
      p_command_id,
      v_status,
      v_result
    );
  end if;

  return v_result;
end;
$function$;

revoke all on function api.create_farm(uuid, text, uuid, text, uuid)
  from public, anon, authenticated, service_role;
grant execute on function api.create_farm(uuid, text, uuid, text, uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 7. تحديث api.list_well_farms ليعيد distinguishing_label
-- ---------------------------------------------------------------------

create or replace function api.list_well_farms(
  p_well_id uuid,
  p_farmer_well_account_id uuid default null
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
    raise exception 'يجب تسجيل الدخول قبل قراءة الأراضي'
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

  select coalesce(jsonb_agg(x.item order by x.name, x.id), '[]'::jsonb)
  into v_items
  from (
    select
      f.id,
      f.name,
      jsonb_build_object(
        'id', f.id,
        'well_id', f.well_id,
        'name', f.name,
        'distinguishing_label', f.distinguishing_label,
        'farmer_well_account_id', f.farmer_well_account_id,
        'status', f.status
      ) as item
    from ops.farms f
    where f.well_id = p_well_id
      and f.status = 'active'
      and (
        p_farmer_well_account_id is null
        or f.farmer_well_account_id = p_farmer_well_account_id
      )
    order by f.name, f.id
  ) x;

  return jsonb_build_object(
    'contract', 'list_well_farms',
    'version', 1,
    'items', v_items
  );
end;
$function$;

revoke all on function api.list_well_farms(uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function api.list_well_farms(uuid, uuid)
  to authenticated, service_role;

commit;
