begin;

set local timezone to 'UTC';

-- =====================================================================
-- اختبار الهجرة 101 — فرادة الأراضي والصفة المميزة وتكامل الطابور المتين
-- القرار: ق-80، ق-84، ق-88، ق-89، ق-113، ق-114، م-21
-- =====================================================================

do $test$
declare
  v_count bigint;
  v_count_2 bigint;
  v_tenant uuid;
  v_user uuid;
  v_well uuid;
  v_farmer_account_1 uuid;
  v_farmer_account_2 uuid;
  v_farm_1 uuid;
  v_farm_2 uuid;
  v_cmd_1 uuid;
  v_cmd_2 uuid;
  v_res_1 jsonb;
  v_res_2 jsonb;
  v_res_3 jsonb;
  v_conflict_res jsonb;
  v_dup_1 uuid;
  v_dup_2 uuid;
  v_profile uuid;
  v_msg text;
begin

  -- ============================================================
  -- 1. العقد الساكن وتوقيعات الدوال ومنع تضخم السطح
  -- ============================================================

  -- التأكد من وجود توقيع واحد فقط لـ api.create_farm
  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'api' and p.proname = 'create_farm';

  select count(*)
  into v_count_2
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'api' and p.proname = 'create_farm'
    and pg_get_function_identity_arguments(p.oid)
        = 'p_well_id uuid, p_name text, p_farmer_well_account_id uuid, p_distinguishing_label text, p_command_id uuid';

  if v_count = 1 and v_count_2 = 1 then
    raise notice 'PASS O: api.create_farm توقيع واحد فقط بـ 5 وسائط دون تضخم السطح';
  else
    raise notice 'FAIL O: api.create_farm عدد التوقيعات=% ومطابقة العقد=%', v_count, v_count_2;
  end if;

  -- التأكد من أمان ومنح api.create_farm
  if not has_function_privilege('anon', 'api.create_farm(uuid,text,uuid,text,uuid)', 'EXECUTE')
     and has_function_privilege('authenticated', 'api.create_farm(uuid,text,uuid,text,uuid)', 'EXECUTE')
     and has_function_privilege('service_role', 'api.create_farm(uuid,text,uuid,text,uuid)', 'EXECUTE')
  then
    raise notice 'PASS P: منح api.create_farm محصورة على authenticated و service_role ومحجوبة عن anon';
  else
    raise notice 'FAIL P: أمان أو منح api.create_farm غير صحيحة';
  end if;

  -- التأكد من توقيع ops.create_farm
  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'ops' and p.proname = 'create_farm';

  select count(*)
  into v_count_2
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'ops' and p.proname = 'create_farm'
    and pg_get_function_identity_arguments(p.oid)
        = 'p_well_id uuid, p_name text, p_farmer_well_account_id uuid, p_distinguishing_label text';

  if v_count = 1 and v_count_2 = 1 then
    raise notice 'PASS O-ops: ops.create_farm توقيع واحد فقط بـ 4 وسائط';
  else
    raise notice 'FAIL O-ops: ops.create_farm عدد التوقيعات=% ومطابقة العقد=%', v_count, v_count_2;
  end if;

  -- ============================================================
  -- 2. إعداد بيانات الاختبار
  --    نمط التركيب المثبت في اختباري 075/082: مستخدم auth حقيقي، ثم
  --    iam.profiles(id, full_name) — الجدول الحالي بلا tenant_id ولا role،
  --    والمعرّف يشير إلى auth.users. البئر بلا location (نوعه text لا point).
  --    التعيين بدور owner لأن حزمة tenant_owner وحدها تملك farm.create؛
  --    operator لا يملكها في نموذج الصلاحيات الحالي (هجرة 080).
  -- ============================================================

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'm101-owner@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_user;

  -- إدراج auth.users يُطلق محفّز handle_new_user الذي يُنشئ iam.profiles
  -- تلقائيًا، فالإدراج المباشر يصطدم بـ profiles_pkey. نمط 075 المثبت:
  -- نقرأ أولًا، وننشئ فقط إن غاب.
  select id into v_profile
  from iam.profiles
  where id = v_user;

  if not found then
    insert into iam.profiles (id, full_name)
    values (v_user, 'مالك اختبار الفرادة')
    returning id into v_profile;
  end if;

  insert into core.tenants (name)
  values ('جهة اختبار الفرادة')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'بئر اختبار الفرادة')
  returning id into v_well;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_well, v_user, 'owner', 'active');

  -- هوية الفاعل عبر الاتفاقية المثبتة في المشروع، ثم دخول دور التطبيق.
  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  -- حسابا مزارعين عبر المسار العام api.create_farmer (نفس نموذج 069/075):
  -- ops.farmer_well_accounts ليس فيه full_name، والهوية تُبنى داخل العقد
  -- core.persons -> ops.farmer_profiles -> ops.farmer_well_accounts، ونلتقط
  -- المعرّف من الرد بدل تكرار معرفة المخطط في الاختبار.
  v_res_1 := api.create_farmer(v_well, 'المزارع الأول', '700000101');
  v_farmer_account_1 := (v_res_1 ->> 'farmer_well_account_id')::uuid;

  v_res_2 := api.create_farmer(v_well, 'المزارع الثاني', '700000102');
  v_farmer_account_2 := (v_res_2 ->> 'farmer_well_account_id')::uuid;

  -- ============================================================
  -- A. محاكاة وجود عنقود تكرار تاريخي (مثل حادثة الكوثة في الإنتاج)
  -- ============================================================

  -- إيقاف المحفز مؤقتاً لمحاكاة الصفوف التاريخية الموجودة قبل M101.
  -- هذا إعداد اختبار مُمتَاز عمدًا: ALTER TABLE ... DISABLE TRIGGER يحتاج
  -- ملكية الجدول، فنخرج من دور التطبيق authenticated إلى postgres لهذا
  -- البلوك وحده، ثم نعيد الدور لبقية نداءات api. لا نمنح authenticated أي
  -- DML مباشر أو DDL لإنجاح الإعداد.
  execute 'reset role';

  alter table ops.farms disable trigger trg_enforce_farm_uniqueness;

  insert into ops.farms (well_id, farmer_well_account_id, name, distinguishing_label, status)
  values (v_well, v_farmer_account_1, 'الكوثة التاريخية', null, 'active')
  returning id into v_dup_1;

  insert into ops.farms (well_id, farmer_well_account_id, name, distinguishing_label, status)
  values (v_well, v_farmer_account_1, 'الكوثة التاريخية', null, 'active')
  returning id into v_dup_2;

  alter table ops.farms enable trigger trg_enforce_farm_uniqueness;

  execute 'set local role authenticated';

  -- التحقق من وجود صفي الكوثة التاريخيين
  select count(*)
  into v_count
  from ops.farms
  where well_id = v_well
    and farmer_well_account_id = v_farmer_account_1
    and name = 'الكوثة التاريخية'
    and status = 'active';

  if v_count = 2 then
    raise notice 'PASS A: محاكاة وجود عنقود تكرار تاريخي ناجحة بلا إتلاف أدلة';
  else
    raise notice 'FAIL A: فشل إنشاء عنقود التكرار التاريخي';
  end if;

  -- ============================================================
  -- B. 0 مطابق -> إنشاء أرض جديدة (created)
  -- ============================================================

  v_res_1 := api.create_farm(
    p_well_id => v_well,
    p_name => 'أرض الوادي',
    p_farmer_well_account_id => v_farmer_account_1
  );

  if v_res_1 ->> 'status' = 'created' and (v_res_1 ->> 'farm_id')::uuid is not null then
    raise notice 'PASS B: 0 مطابق أنشأ أرضاً جديدة (created)';
    v_farm_1 := (v_res_1 ->> 'farm_id')::uuid;
  else
    raise notice 'FAIL B: نتيجة إنشاء أرض جديدة: %', v_res_1;
  end if;

  -- ============================================================
  -- C. 1 مطابق تماماً قائم -> matched_existing دون إنشاء صف ثانٍ
  -- ============================================================

  v_res_2 := api.create_farm(
    p_well_id => v_well,
    p_name => 'أرض الوادي',
    p_farmer_well_account_id => v_farmer_account_1
  );

  select count(*)
  into v_count
  from ops.farms
  where well_id = v_well
    and farmer_well_account_id = v_farmer_account_1
    and name = 'أرض الوادي';

  if v_res_2 ->> 'status' = 'matched_existing'
     and (v_res_2 ->> 'farm_id')::uuid = v_farm_1
     and v_count = 1
  then
    raise notice 'PASS C: مطابق تام واحد أعاد matched_existing ونفس farm_id دون صف إضافي';
  else
    raise notice 'FAIL C: مطابق تام أحدث نتيجة: % صفوف=%', v_res_2, v_count;
  end if;

  -- ============================================================
  -- D. >1 مطابق تاريخي -> requires_resolution دون اختيار عشوائي ودون صف إضافي
  -- ============================================================

  v_cmd_1 := gen_random_uuid();
  v_res_1 := api.create_farm(
    p_well_id => v_well,
    p_name => 'الكوثة التاريخية',
    p_farmer_well_account_id => v_farmer_account_1,
    p_command_id => v_cmd_1
  );

  select count(*)
  into v_count
  from ops.farms
  where well_id = v_well
    and farmer_well_account_id = v_farmer_account_1
    and name = 'الكوثة التاريخية';

  v_conflict_res := v_res_1;

  if v_res_1 ->> 'status' = 'requires_resolution'
     and v_count = 2
     and jsonb_array_length(v_res_1 -> 'candidate_farm_ids') = 2
  then
    raise notice 'PASS D: العنقود الملتبس أعاد requires_resolution مع قائمة المرشحين دون صف جديد';
  else
    raise notice 'FAIL D: العنقود الملتبس أحدث نتيجة: % صفوف=%', v_res_1, v_count;
  end if;

  -- ============================================================
  -- E. إعادة إرسال نفس command_id بعد accepted -> نفس الرد تماماً
  -- ============================================================

  v_cmd_2 := gen_random_uuid();
  v_res_1 := api.create_farm(
    p_well_id => v_well,
    p_name => 'أرض الجبل',
    p_farmer_well_account_id => v_farmer_account_1,
    p_command_id => v_cmd_2
  );

  v_res_2 := api.create_farm(
    p_well_id => v_well,
    p_name => 'أرض الجبل',
    p_farmer_well_account_id => v_farmer_account_1,
    p_command_id => v_cmd_2
  );

  if v_res_1 = v_res_2 and v_res_1 ->> 'status' = 'created' then
    raise notice 'PASS E: إعادة نفس command_id بعد accepted أعادت نفس الرد المخزن تماماً';
  else
    raise notice 'FAIL E: إعادة accepted أحدثت عدم تطابق: ر1=% ر2=%', v_res_1, v_res_2;
  end if;

  -- ============================================================
  -- F. إعادة إرسال نفس command_id بعد conflict -> نفس رد التعارض تماماً
  -- ============================================================

  v_res_2 := api.create_farm(
    p_well_id => v_well,
    p_name => 'الكوثة التاريخية',
    p_farmer_well_account_id => v_farmer_account_1,
    p_command_id => v_cmd_1
  );

  select status into v_msg
  from sync.processed_commands
  where command_id = v_cmd_1;

  if v_res_2 = v_conflict_res
     and v_res_2 ->> 'status' = 'requires_resolution'
     and v_msg = 'conflict'
  then
    raise notice 'PASS F: إعادة نفس command_id بعد conflict أعادت نفس رد التعارض المخزن تماماً وحالة conflict';
  else
    raise notice 'FAIL F: إعادة conflict أحدثت: status=% رد1=% رد2=%', v_msg, v_conflict_res, v_res_2;
  end if;

  -- ============================================================
  -- G. أمري مزامنة متتاليين بمعرفين مختلفين لنفس الأرض المطابقة -> سلوك تسلسلي حتمي ينتج صفاً واحداً
  -- ============================================================

  v_cmd_1 := gen_random_uuid();
  v_cmd_2 := gen_random_uuid();

  v_res_1 := api.create_farm(
    p_well_id => v_well,
    p_name => 'أرض السد',
    p_farmer_well_account_id => v_farmer_account_1,
    p_command_id => v_cmd_1
  );

  v_res_2 := api.create_farm(
    p_well_id => v_well,
    p_name => 'أرض السد',
    p_farmer_well_account_id => v_farmer_account_1,
    p_command_id => v_cmd_2
  );

  select count(*)
  into v_count
  from ops.farms
  where well_id = v_well
    and farmer_well_account_id = v_farmer_account_1
    and name = 'أرض السد';

  if v_res_1 ->> 'status' = 'created'
     and v_res_2 ->> 'status' = 'matched_existing'
     and (v_res_1 ->> 'farm_id') = (v_res_2 ->> 'farm_id')
     and v_count = 1
  then
    raise notice 'PASS G: معرّفا عملية مختلفان متتاليان لنفس الأرض نتج عنهما صف واحد فقط بسلوك تسلسلي حتمي';
  else
    raise notice 'FAIL G: تكرار بمعرفين مختلفين أحدث صفوف=% ر1=% ر2=%', v_count, v_res_1, v_res_2;
  end if;

  -- ============================================================
  -- H. نفس الاسم الأساسي لمزارع آخر -> مسموح وينشئ أرضاً جديدة
  -- ============================================================

  v_res_1 := api.create_farm(
    p_well_id => v_well,
    p_name => 'أرض السد',
    p_farmer_well_account_id => v_farmer_account_2
  );

  if v_res_1 ->> 'status' = 'created'
     and (v_res_1 ->> 'farmer_well_account_id')::uuid = v_farmer_account_2
  then
    raise notice 'PASS H: نفس الاسم لمزارع مختلف مسموح به وينشئ أرضاً جديدة';
  else
    raise notice 'FAIL H: إنشاء أرض بنفس الاسم لمزارع آخر فشل: %', v_res_1;
  end if;

  -- ============================================================
  -- I. نفس المزارع + نفس الاسم الأساسي + صفات مميزة مختلفة -> مسموح
  -- ============================================================

  v_res_1 := api.create_farm(
    p_well_id => v_well,
    p_name => 'أرض النخيل',
    p_farmer_well_account_id => v_farmer_account_1,
    p_distinguishing_label => 'الشرقية'
  );

  v_res_2 := api.create_farm(
    p_well_id => v_well,
    p_name => 'أرض النخيل',
    p_farmer_well_account_id => v_farmer_account_1,
    p_distinguishing_label => 'الغربية'
  );

  select count(*)
  into v_count
  from ops.farms
  where well_id = v_well
    and farmer_well_account_id = v_farmer_account_1
    and name = 'أرض النخيل';

  if v_res_1 ->> 'status' = 'created'
     and v_res_2 ->> 'status' = 'created'
     and v_count = 2
  then
    raise notice 'PASS I: صفات مميزة مختلفة لنفس الاسم سمحت بإنشاء الأرضين';
  else
    raise notice 'FAIL I: الصفات المميزة المختلفة أحدثت صفوف=% ر1=% ر2=%', v_count, v_res_1, v_res_2;
  end if;

  -- ============================================================
  -- J. نفس المزارع + نفس الاسم + نفس الصفة المميزة -> matched_existing
  -- ============================================================

  v_res_3 := api.create_farm(
    p_well_id => v_well,
    p_name => 'أرض النخيل',
    p_farmer_well_account_id => v_farmer_account_1,
    p_distinguishing_label => 'الشرقية'
  );

  select count(*)
  into v_count
  from ops.farms
  where well_id = v_well
    and farmer_well_account_id = v_farmer_account_1
    and name = 'أرض النخيل';

  if v_res_3 ->> 'status' = 'matched_existing'
     and (v_res_3 ->> 'farm_id') = (v_res_1 ->> 'farm_id')
     and v_count = 2
  then
    raise notice 'PASS J: نفس الصفة المميزة لم تنشئ صفاً إضافياً وطابقت القائم';
  else
    raise notice 'FAIL J: تكرار الصفة المميزة أحدث صفوف=% ر3=%', v_count, v_res_3;
  end if;

  -- ============================================================
  -- K. طلب دون صفة مميزة مع وجود أشقاء بصفات مميزة -> requires_disambiguation
  -- ============================================================

  v_res_1 := api.create_farm(
    p_well_id => v_well,
    p_name => 'أرض النخيل',
    p_farmer_well_account_id => v_farmer_account_1,
    p_distinguishing_label => null
  );

  if v_res_1 ->> 'status' = 'requires_disambiguation'
     and jsonb_array_length(v_res_1 -> 'existing_labels') >= 2
  then
    raise notice 'PASS K: طلب دون صفة مميزة مع وجود أشقاء بصفات مميزة أعاد requires_disambiguation';
  else
    raise notice 'FAIL K: فحص التمييز أحدث: %', v_res_1;
  end if;

  -- ============================================================
  -- L. تحويل active -> inactive ينجح دائماً (أرشفة/تعطيل)
  --    تأكيد سلوك محفّز/جدول لا تأكيد صلاحية دور التطبيق: UPDATE مباشر على
  --    ops.farms يمنعه ACL على authenticated (وهو صحيح، يثبته 072). ننفّذه
  --    بصلاحية postgres عبر reset role، ثم نعيد الدور لبقية نداءات api.
  -- ============================================================

  execute 'reset role';

  update ops.farms
  set status = 'inactive'
  where id = v_dup_1;

  select status into v_msg
  from ops.farms
  where id = v_dup_1;

  if v_msg = 'inactive' then
    raise notice 'PASS L: تحويل الأرض النشطة إلى غير نشطة (أرشفة) نجح بنجاح حتى لأحد صفي الكوثة التاريخيين';
  else
    raise notice 'FAIL L: فشل تحويل الأرض إلى inactive';
  end if;

  -- ============================================================
  -- M. إعادة تفعيل inactive -> active تصطدم بمطابق فعال تُرفض
  --    ما زلنا في دور postgres من كتلة L: UPDATE مباشر تأكيدُ محفّز لا ACL.
  --    نشترط تحديدًا SQLSTATE 23505 (رفض الفرادة)، فلا يُرضي الاختبارَ
  --    رفضٌ لسبب آخر (كصلاحية) — وهو ما كان يفعله catch العام السابق.
  -- ============================================================

  begin
    update ops.farms
    set status = 'active'
    where id = v_dup_1;

    raise notice 'FAIL M: سُمح بإعادة تفعيل أرض متطابقة مع أرض نشطة أخرى';
  exception
    when unique_violation then
      raise notice 'PASS M: رُفضت إعادة تفعيل أرض مطابقة بحماية الفرادة (23505): %', sqlerrm;
    when others then
      raise notice 'FAIL M: رُفضت لكن ليس بحماية الفرادة (SQLSTATE=%): %', sqlstate, sqlerrm;
  end;

  -- استعادة دور التطبيق لبقية نداءات api.
  execute 'set local role authenticated';

  -- ============================================================
  -- N. تنويعات الرسم العربي (تطبيع الهمزات والتاء المربوطة)
  -- ============================================================

  -- إنشاء بألف مهموزة
  v_res_1 := api.create_farm(
    p_well_id => v_well,
    p_name => 'أرض البركة',
    p_farmer_well_account_id => v_farmer_account_1
  );

  -- طلب ثانٍ بألف مجردة وهاء بدل التاء المربوطة "ارض البركه"
  v_res_2 := api.create_farm(
    p_well_id => v_well,
    p_name => 'ارض البركه',
    p_farmer_well_account_id => v_farmer_account_1
  );

  select count(*)
  into v_count
  from ops.farms
  where well_id = v_well
    and farmer_well_account_id = v_farmer_account_1
    and core.normalize_arabic(name) = core.normalize_arabic('أرض البركة');

  if v_res_1 ->> 'status' = 'created'
     and v_res_2 ->> 'status' = 'matched_existing'
     and (v_res_1 ->> 'farm_id') = (v_res_2 ->> 'farm_id')
     and v_count = 1
  then
    raise notice 'PASS N: التطبيع العربي وحّد تنويعات الرسم (الهمزات والتاء المربوطة)';
  else
    raise notice 'FAIL N: التطبيع العربي أحدث صفوف=% ر1=% ر2=%', v_count, v_res_1, v_res_2;
  end if;

  -- ============================================================
  -- Q. التحقق من أن api.list_well_farms يعيد distinguishing_label
  -- ============================================================

  v_res_1 := api.list_well_farms(v_well, v_farmer_account_1);

  select count(*)
  into v_count
  from jsonb_array_elements(v_res_1 -> 'items') elem
  where elem ->> 'name' = 'أرض النخيل'
    and elem ->> 'distinguishing_label' in ('الشرقية', 'الغربية');

  if v_count = 2 then
    raise notice 'PASS Q: api.list_well_farms يعيد distinguishing_label للأراضي المميزة';
  else
    raise notice 'FAIL Q: api.list_well_farms لم يعد الصفات المميزة كما ينبغي: %', v_res_1;
  end if;

  -- ============================================================
  -- R. رفض الإدراج المباشر المكرر (Direct INSERT) عبر محفز فرادة الجدول
  --    غرضه إثبات حماية على مستوى الجدول لا على مستوى ACL. لو نُفّذ تحت
  --    authenticated لرفضه ACL فصار الاختبار أجوفَ. ننفّذه بصلاحية postgres
  --    (المحفّز يبقى مُفعّلًا) ونشترط تحديدًا SQLSTATE 23505 من فرادة الأرض.
  -- ============================================================

  execute 'reset role';

  begin
    insert into ops.farms (well_id, farmer_well_account_id, name, distinguishing_label, status)
    values (v_well, v_farmer_account_1, 'أرض الوادي', null, 'active');

    raise notice 'FAIL R: سُمح بإدراج مباشر مكرر دون اعتراض';
  exception
    when unique_violation then
      raise notice 'PASS R: رُفض الإدراج المباشر المكرر بحماية فرادة الجدول (23505): %', sqlerrm;
    when others then
      raise notice 'FAIL R: رُفض لكن ليس بحماية الفرادة (SQLSTATE=%): %', sqlstate, sqlerrm;
  end;

  execute 'set local role authenticated';

end;
$test$;

rollback;
