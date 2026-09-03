-- 094 — ق-123: دعوات الفريق والتنشيط بيد صاحب الحساب (م-41E المرحلة 2)
--
-- المشكلة التي تغلقها هذه الهجرة:
-- دور المشغّل غير قابل للاستخدام أصلًا. إضافة مشغّل في هجرة 086 تُنشئ
-- شخصًا في دفاتر المالك (core.persons + core.person_contacts) لا حساب
-- دخول، ثم تبحث عن ملف بنفس الهاتف وتربطه إن وُجد. ولا مسار في التطبيق
-- لإنشاء حساب لمشغّل، فلا أحد يضع كلمة مروره الأولى لأنه لا حساب ولا
-- كلمة مرور. والربط يجري لحظة إنشاء البئر وحدها، فمن أنشأ حسابه بعدها
-- يبقى سجلّان لا يعرف أحدهما الآخر.
--
-- أدلة جُمعت قبل الكتابة (لا تخمين):
-- أ) core.well_assignments.profile_id إلزامي (NOT NULL) وstatus محصور
--    بـ active/inactive. فلا يقبل الجدول صفًّا «بانتظار التنشيط» بلا
--    حساب — ولذلك يلزم جدول دعوات مستقل، لا عمود حالة جديد.
-- ب) UNIQUE (well_id, profile_id, role) على التعيينات هو ما يجعل
--    المطالبة مرتين تُنتج تعيينًا واحدًا بلا منطق إضافي.
-- ج) core.well_partners يحمل أصلًا phone وprofile_id قابلًا للإفراغ
--    وinvited_at وactivated_at — فنموذج الدعوة للشريك مُهيَّأ في
--    التصميم من مرحلة سابقة، وهذه الهجرة تُكمِله لا تخالفه.
-- د) core.normalize_phone(text) موجودة وimmutable، فالتطبيع يُعاد
--    استخدامه ولا يُنسخ (الثابت 86).
-- هـ) iam.has_well_permission(uuid, text) هي بوابة السلطة المسمّاة
--    المستعملة في 081/091/093، وauth.uid() لـ anon تكون null فتفشل
--    مغلقةً.
--
-- القواعد المطبقة (ق-78 / ق-79 / ق-113 / ق-123):
-- 1. مخطط api يبقى SECURITY INVOKER، والعمل الذي يتجاوز RLS ينتقل إلى
--    إجراء داخلي SECURITY DEFINER بـsearch_path مثبت يحمل الفحص
--    المسمّى — نفس نمط 084/091/093.
-- 2. الجدول الجديد يبدأ بلا Direct DML لأي دور تطبيق: RLS مفعّلة بلا
--    سياسات، وكل الصلاحيات مسحوبة. لا يُقرأ ولا يُكتب إلا عبر العقود.
-- 3. الدعوة **صفر صلاحية** حتى تُطالَب: لا صف في well_assignments قبل
--    المطالبة، فالسلطة تأتي من التعيين النافذ وحده (الثابت 707).
-- 4. الرمز يُخزَّن مُلبَّدًا بملح لكل صف، ولا يُعاد نصًّا إلا مرة واحدة
--    لمن دعا (الثابت 708). التلبيد pg_catalog.sha256 بلا اعتماد على
--    مخطط إضافة: الحماية الفعلية هي عدّاد المحاولات (5) وحصر البحث
--    برقم صاحب الحساب المُصدَّق ومدة الصلاحية — لا بطء دالة التلبيد.
-- 5. لا كلمة مرور يكتبها أحد لأحد (الثابت 706): لا شيء في هذه الهجرة
--    يمسّ auth.users ولا كلمات المرور.
-- 6. من له حساب قائم بنفس الرقم يُربط **بلا رمز** لحظة الدعوة، ويُعاد
--    outcome = 'linked' (ق-123 §4 / الثابت 709).
-- 7. إعادة الدعوة لنفس (البئر، الدور، الرقم) تُبطل ما قبلها وتُصدر
--    رمزًا جديدًا — فلا حاجة إلى دالة إعادة إصدار منفصلة.
--
-- أثر مقصود على أرقام الحرس:
-- iam.permissions 42 → 43، وiam.role_permissions 78 → 79
-- (tenant_owner 42 → 43 وحده؛ well_manager وoperator بلا تغيير لأن
-- إدارة الفريق للمالك في هذه الجولة — ق-123 §10).

begin;

-- ==============================================================
-- 0. صلاحية إدارة الفريق: للمالك وحده في هذه الجولة
-- ==============================================================

insert into iam.permissions (code, description_ar)
values
  ('team.manage', 'دعوة أعضاء البئر وإلغاء وصولهم وقراءة قائمة الفريق')
on conflict (code) do nothing;

insert into iam.role_permissions (role_id, permission_id)
select r.id, p.id
from iam.roles r
join iam.permissions p on p.code = 'team.manage'
where r.code in ('tenant_owner')
on conflict do nothing;

-- ==============================================================
-- 1. جدول الدعوات
--
-- سبب وجوده كجدول مستقل لا عمود حالة: core.well_assignments.profile_id
-- إلزامي وstatus محصور بـ active/inactive، فلا يقبل «بانتظار التنشيط».
--
-- أربع حالات لا خامسة داخل هذا الجدول: invited / claimed / expired /
-- revoked. والحالة الخامسة في دورة الحياة (active) تسكن التعيين النافذ
-- في core.well_assignments — فالدعوة ليست صلاحية.
-- ==============================================================

create table if not exists core.well_invitations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  well_id uuid not null references core.wells(id) on delete cascade,
  role text not null,
  person_id uuid not null references core.persons(id) on delete cascade,
  phone text not null,
  normalized_phone text not null,
  code_salt text not null,
  code_hash text not null,
  expires_at timestamptz not null,
  attempts_left integer not null default 5,
  status text not null default 'invited',
  invited_by uuid not null references iam.profiles(id) on delete cascade,
  invited_at timestamptz not null default now(),
  claimed_at timestamptz,
  claimed_profile_id uuid references iam.profiles(id) on delete set null,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint well_invitations_role_check
    check (role in ('operator', 'partner')),
  constraint well_invitations_status_check
    check (status in ('invited', 'claimed', 'expired', 'revoked')),
  constraint well_invitations_attempts_check
    check (attempts_left >= 0 and attempts_left <= 5),
  constraint well_invitations_claim_shape
    check (
      (status = 'claimed')
      = (claimed_at is not null and claimed_profile_id is not null)
    )
);

comment on table core.well_invitations is
  'ق-123: دعوة عضو إلى بئر بصفر صلاحية حتى يُطالِب بها صاحب الرقم برمز. الرمز مُلبَّد بملح لكل صف ولا يُخزَّن نصًّا. السلطة تأتي من core.well_assignments النافذ وحده.';

-- دعوة قائمة واحدة لكل (بئر، دور، رقم): إعادة الدعوة تُبطل ما قبلها.
create unique index if not exists well_invitations_open_uniq
  on core.well_invitations (well_id, role, normalized_phone)
  where status = 'invited';

-- مسار المطالبة يبحث برقم صاحب الحساب المُصدَّق وحده.
create index if not exists well_invitations_claim_idx
  on core.well_invitations (normalized_phone, status);

create index if not exists well_invitations_well_idx
  on core.well_invitations (well_id, status);

-- بلا Direct DML ولا قراءة مباشرة لأي دور تطبيق (ق-79): RLS مفعّلة بلا
-- سياسات فتُعيد صفر صفوف، والصلاحيات مسحوبة فلا مسار غير العقود.
alter table core.well_invitations enable row level security;

revoke all on table core.well_invitations from public;
revoke all on table core.well_invitations from anon;
revoke all on table core.well_invitations from authenticated;

-- ==============================================================
-- 2. توليد رمز من ستة أرقام بمصدر عشوائي معتمد
--
-- gen_random_uuid() في PostgreSQL 13+ يأخذ عشوائيته من نظام التشغيل،
-- فيصلح مصدرًا لرمز أمني. random() لا يصلح: مولّد شبه عشوائي قابل
-- للتوقع. و`abs` ضرورية لأن تحويل bit(32) إلى عدد قد يعطي قيمة سالبة،
-- فباقي القسمة منها ينتج نصًّا بإشارة لا رمزًا. والانحياز الناتج عن
-- باقي القسمة (2^31 % 10^6) مهمَل.
-- ==============================================================

create or replace function core.new_invitation_code()
returns text
language sql
volatile
set search_path = pg_catalog, pg_temp
as $function$
  select lpad(
    mod(
      abs(
        ('x' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))
          ::bit(32)::bigint
      ),
      1000000
    )::text,
    6,
    '0'
  );
$function$;

comment on function core.new_invitation_code() is
  'ق-123: رمز تنشيط من ستة أرقام بعشوائية gen_random_uuid المعتمدة، لا random().';

revoke all on function core.new_invitation_code() from public;
revoke all on function core.new_invitation_code() from anon;
revoke all on function core.new_invitation_code() from authenticated;

-- تلبيد الرمز: ملح لكل صف ثم sha256. لا اعتماد على مخطط إضافة.
create or replace function core.hash_invitation_code(
  p_code text,
  p_salt text
)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $function$
  select encode(sha256(convert_to(p_salt || ':' || p_code, 'utf8')), 'hex');
$function$;

comment on function core.hash_invitation_code(text, text) is
  'ق-123 / الثابت 708: تلبيد رمز التنشيط بملح صفّه. الرمز لا يُخزَّن نصًّا في أي مكان.';

revoke all on function core.hash_invitation_code(text, text) from public;
revoke all on function core.hash_invitation_code(text, text) from anon;
revoke all on function core.hash_invitation_code(text, text) from authenticated;

-- ==============================================================
-- 3. الدعوة: إنشاء شخص عند الحاجة، وربط فوري لمن له حساب قائم
--
-- ثلاثة مبادئ:
-- أ) لا هوية جديدة عند إسناد دور (ق-101 §6): الشخص يُعاد استخدامه إن
--    وُجد بنفس الرقم في نفس الجهة، ولا يُنشأ شخص موازٍ.
-- ب) من له حساب دخول بنفس الرقم يُربط **الآن وبلا رمز**: الرمز لإثبات
--    هوية جديدة لا لتكرار إثبات قائم (الثابت 709).
-- ج) إعادة الدعوة تُبطل ما قبلها: رمز واحد صالح لكل (بئر، دور، رقم).
-- ==============================================================

create or replace function core.invite_well_member(
  p_well_id uuid,
  p_role text,
  p_full_name text,
  p_phone text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_tenant uuid;
  v_name text := btrim(coalesce(p_full_name, ''));
  v_phone text := btrim(coalesce(p_phone, ''));
  v_norm text;
  v_person uuid;
  v_profile uuid;
  v_code text;
  v_salt text;
  v_invitation uuid;
  v_expires timestamptz;
begin
  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  if p_role is null or p_role not in ('operator', 'partner') then
    raise exception 'الدور المدعو غير مقبول: مشغّل أو شريك فقط'
      using errcode = '22023';
  end if;

  if v_name = '' then
    raise exception 'اسم العضو مطلوب'
      using errcode = '22023';
  end if;

  v_norm := core.normalize_phone(v_phone);
  if v_norm is null or v_norm = '' then
    raise exception 'رقم هاتف العضو مطلوب'
      using errcode = '22023';
  end if;

  -- السلطة: صلاحية مسمّاة على هذا البئر. anon تُعيد null فتفشل مغلقةً.
  if not iam.has_well_permission(p_well_id, 'team.manage') then
    raise exception 'إدارة فريق هذا البئر متاحة لمالكه'
      using errcode = '42501';
  end if;

  select w.tenant_id into v_tenant
  from core.wells w
  where w.id = p_well_id;

  if v_tenant is null then
    raise exception 'لا توجد صلاحية على هذا البئر'
      using errcode = '42501';
  end if;

  -- الشخص: يُعاد استخدامه بالرقم المطبَّع في نفس الجهة، ولا يُنشأ موازٍ.
  select pc.person_id into v_person
  from core.person_contacts pc
  join core.persons pe on pe.id = pc.person_id
  where pc.tenant_id = v_tenant
    and pc.normalized_value = v_norm
    and pe.status = 'active'
  order by pc.is_primary desc, pc.created_at
  limit 1;

  if v_person is null then
    insert into core.persons (
      tenant_id, full_name, normalized_name, created_by, updated_by
    ) values (
      v_tenant, v_name, core.normalize_arabic(v_name), v_actor, v_actor
    )
    returning id into v_person;

    insert into core.person_contacts (
      tenant_id, person_id, contact_type, contact_value,
      normalized_value, is_primary
    ) values (
      v_tenant, v_person, 'mobile', v_phone, v_norm, true
    );
  end if;

  -- من له حساب دخول بنفس الرقم: يُربط الآن بلا رمز ولا دعوة.
  select pr.id into v_profile
  from iam.profiles pr
  where pr.phone is not null
    and core.normalize_phone(pr.phone) = v_norm
  order by pr.created_at
  limit 1;

  if v_profile is not null then
    insert into core.well_assignments (well_id, profile_id, role, status)
    values (p_well_id, v_profile, p_role, 'active')
    on conflict (well_id, profile_id, role)
    do update set status = 'active', updated_at = now();

    if p_role = 'partner' then
      update core.well_partners wp
      set profile_id = v_profile,
          activated_at = coalesce(wp.activated_at, now()),
          updated_at = now()
      where wp.well_id = p_well_id
        and wp.profile_id is null
        and core.normalize_phone(wp.phone) = v_norm;
    end if;

    return jsonb_build_object(
      'contract', 'invite_well_member',
      'version', 1,
      'outcome', 'linked',
      'person_id', v_person,
      'profile_id', v_profile,
      'invitation_id', null,
      'code', null,
      'expires_at', null
    );
  end if;

  -- إعادة الدعوة تُبطل ما قبلها: رمز واحد صالح لكل (بئر، دور، رقم).
  update core.well_invitations
  set status = 'revoked',
      revoked_at = now(),
      updated_at = now()
  where well_id = p_well_id
    and role = p_role
    and normalized_phone = v_norm
    and status = 'invited';

  v_code := core.new_invitation_code();
  v_salt := replace(gen_random_uuid()::text, '-', '');
  v_expires := now() + interval '14 days';

  insert into core.well_invitations (
    tenant_id, well_id, role, person_id, phone, normalized_phone,
    code_salt, code_hash, expires_at, invited_by
  ) values (
    v_tenant, p_well_id, p_role, v_person, v_phone, v_norm,
    v_salt, core.hash_invitation_code(v_code, v_salt), v_expires, v_actor
  )
  returning id into v_invitation;

  -- الرمز يُعاد نصًّا **مرة واحدة** لمن دعا، ولا يُخزَّن نصًّا أبدًا.
  return jsonb_build_object(
    'contract', 'invite_well_member',
    'version', 1,
    'outcome', 'invited',
    'person_id', v_person,
    'profile_id', null,
    'invitation_id', v_invitation,
    'code', v_code,
    'expires_at', v_expires
  );
end;
$function$;

comment on function core.invite_well_member(uuid, text, text, text) is
  'ق-123: دعوة عضو بصفر صلاحية. من له حساب بنفس الرقم يُربط فورًا بلا رمز (outcome=linked)، وغيره يُصدر له رمز يُعاد نصًّا مرة واحدة (outcome=invited).';

revoke all on function core.invite_well_member(uuid, text, text, text)
  from public, anon, authenticated, service_role;

grant execute on function core.invite_well_member(uuid, text, text, text)
  to authenticated, service_role;

-- ==============================================================
-- 4. المطالبة بالدعوة: صاحب الرقم المُصدَّق وحده
--
-- البحث محصور برقم **حساب المتصل نفسه** (iam.profiles.phone)، لا برقم
-- يرسله العميل. فمن لا يملك الرقم المدعو لا يجد الدعوة أصلًا، ولو خمّن
-- الرمز — وهذا ما يحصر التخمين بخمس محاولات على دعوة واحدة بدل مليون
-- احتمال على كل الدعوات.
--
-- Idempotency: المطالبة بالرمز نفسه مرتين تُنتج تعيينًا واحدًا. الثانية
-- تجد الدعوة claimed بنفس الحساب فتُعيد النتيجة نفسها بلا تغيير.
-- ==============================================================

create or replace function core.claim_well_invitation(
  p_code text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_code text := btrim(coalesce(p_code, ''));
  v_norm text;
  v_row core.well_invitations;
  v_well_name text;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل تنشيط الدعوة'
      using errcode = '28000';
  end if;

  if v_code = '' then
    raise exception 'رمز التنشيط مطلوب'
      using errcode = '22023';
  end if;

  select core.normalize_phone(pr.phone) into v_norm
  from iam.profiles pr
  where pr.id = v_actor;

  if v_norm is null or v_norm = '' then
    raise exception 'لا رقم هاتف في بيانات حسابك — تعذر مطابقة الدعوة'
      using errcode = '22023';
  end if;

  -- انتهاء متأخّر: ما مضى وقته يُوسم منتهيًا قبل البحث، فلا يُطالَب به.
  update core.well_invitations
  set status = 'expired',
      updated_at = now()
  where normalized_phone = v_norm
    and status = 'invited'
    and expires_at <= now();

  -- مطالبة مكرّرة بالرمز نفسه: تُعاد النتيجة نفسها بلا تعيين ثانٍ.
  select inv.* into v_row
  from core.well_invitations inv
  where inv.normalized_phone = v_norm
    and inv.status = 'claimed'
    and inv.claimed_profile_id = v_actor
    and inv.code_hash = core.hash_invitation_code(v_code, inv.code_salt)
  order by inv.claimed_at desc
  limit 1;

  if v_row.id is not null then
    select w.name into v_well_name
    from core.wells w
    where w.id = v_row.well_id;

    return jsonb_build_object(
      'contract', 'claim_well_invitation',
      'version', 1,
      'outcome', 'already_claimed',
      'well_id', v_row.well_id,
      'well_name', v_well_name,
      'role', v_row.role
    );
  end if;

  select inv.* into v_row
  from core.well_invitations inv
  where inv.normalized_phone = v_norm
    and inv.status = 'invited'
    and inv.expires_at > now()
    and inv.attempts_left > 0
  order by inv.invited_at desc
  limit 1;

  if v_row.id is null then
    -- حالة عمل معلنة لا استثناء: الاستثناء كان سيُلغي أي أثر في نفس
    -- المعاملة، والعميل يحتاج التفريق بين «لا دعوة» و«رمز خاطئ».
    return jsonb_build_object(
      'contract', 'claim_well_invitation',
      'version', 1,
      'outcome', 'no_invitation',
      'well_id', null,
      'well_name', null,
      'role', null,
      'attempts_left', null
    );
  end if;

  if v_row.code_hash <> core.hash_invitation_code(v_code, v_row.code_salt) then
    -- الخصم يجب أن يبقى: `raise` كان سيتراجع عنه في نفس المعاملة فيصير
    -- العدّاد بلا معنى ويُفتح التخمين بلا حدّ.
    update core.well_invitations
    set attempts_left = attempts_left - 1,
        updated_at = now()
    where id = v_row.id;

    return jsonb_build_object(
      'contract', 'claim_well_invitation',
      'version', 1,
      'outcome', 'wrong_code',
      'well_id', null,
      'well_name', null,
      'role', null,
      'attempts_left', v_row.attempts_left - 1
    );
  end if;

  -- الرمز صحيح: التعيين النافذ هو ما يمنح الصلاحية، والقيد الفريد
  -- (well_id, profile_id, role) هو ما يجعل التكرار تعيينًا واحدًا.
  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_row.well_id, v_actor, v_row.role, 'active')
  on conflict (well_id, profile_id, role)
  do update set status = 'active', updated_at = now();

  -- الشريك: يُربط صفّه القائم بحسابه ويُوسم وقت تنشيطه.
  if v_row.role = 'partner' then
    update core.well_partners wp
    set profile_id = v_actor,
        activated_at = coalesce(wp.activated_at, now()),
        updated_at = now()
    where wp.well_id = v_row.well_id
      and wp.profile_id is null
      and core.normalize_phone(wp.phone) = v_norm;
  end if;

  update core.well_invitations
  set status = 'claimed',
      claimed_at = now(),
      claimed_profile_id = v_actor,
      updated_at = now()
  where id = v_row.id;

  select w.name into v_well_name
  from core.wells w
  where w.id = v_row.well_id;

  return jsonb_build_object(
    'contract', 'claim_well_invitation',
    'version', 1,
    'outcome', 'claimed',
    'well_id', v_row.well_id,
    'well_name', v_well_name,
    'role', v_row.role,
    'attempts_left', null
  );
end;
$function$;

comment on function core.claim_well_invitation(text) is
  'ق-123: مطالبة صاحب الرقم المُصدَّق بدعوته. البحث برقم حساب المتصل وحده، والرمز الخاطئ يخصم من العدّاد ويُعاد كحالة لا كاستثناء حتى يبقى الخصم. المطالبة مرتين = تعيين واحد.';

revoke all on function core.claim_well_invitation(text)
  from public, anon, authenticated, service_role;

grant execute on function core.claim_well_invitation(text)
  to authenticated, service_role;

-- ==============================================================
-- 5. إلغاء الدعوة وإلغاء وصول عضو نافذ
--
-- الإلغاء ليس حذفًا (الثابت 714): الدعوة تُوسم revoked، والتعيين
-- النافذ يُوسم inactive. ولا يُمسّ سجل مالي ولا تاريخ شراكة.
-- ==============================================================

create or replace function core.revoke_well_member(
  p_well_id uuid,
  p_role text,
  p_phone text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_norm text;
  v_invitations integer := 0;
  v_assignments integer := 0;
begin
  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  if p_role is null or p_role not in ('operator', 'partner') then
    raise exception 'الدور غير مقبول: مشغّل أو شريك فقط'
      using errcode = '22023';
  end if;

  v_norm := core.normalize_phone(btrim(coalesce(p_phone, '')));
  if v_norm is null or v_norm = '' then
    raise exception 'رقم هاتف العضو مطلوب'
      using errcode = '22023';
  end if;

  if not iam.has_well_permission(p_well_id, 'team.manage') then
    raise exception 'إدارة فريق هذا البئر متاحة لمالكه'
      using errcode = '42501';
  end if;

  update core.well_invitations
  set status = 'revoked',
      revoked_at = now(),
      updated_at = now()
  where well_id = p_well_id
    and role = p_role
    and normalized_phone = v_norm
    and status = 'invited';

  get diagnostics v_invitations = row_count;

  -- التعيين النافذ يُوسم inactive: لا حذف، فالسجل المالي لا يُمسّ.
  update core.well_assignments wa
  set status = 'inactive',
      updated_at = now()
  where wa.well_id = p_well_id
    and wa.role = p_role
    and wa.status = 'active'
    and wa.profile_id in (
      select pr.id
      from iam.profiles pr
      where pr.phone is not null
        and core.normalize_phone(pr.phone) = v_norm
    );

  get diagnostics v_assignments = row_count;

  return jsonb_build_object(
    'contract', 'revoke_well_member',
    'version', 1,
    'revoked_invitations', v_invitations,
    'deactivated_assignments', v_assignments
  );
end;
$function$;

comment on function core.revoke_well_member(uuid, text, text) is
  'ق-123 / الثابت 714: إلغاء الوصول لا حذف — الدعوة تُوسم revoked والتعيين inactive، ولا يُمسّ سجل مالي ولا تاريخ شراكة.';

revoke all on function core.revoke_well_member(uuid, text, text)
  from public, anon, authenticated, service_role;

grant execute on function core.revoke_well_member(uuid, text, text)
  to authenticated, service_role;

-- ==============================================================
-- 6. قراءة الفريق: الأعضاء النافذون والدعوات المعلَّقة معًا
--
-- الرمز **لا يُعاد** هنا ولا تلبيدته: الرمز يُعرض مرة واحدة لحظة
-- الدعوة. وما يُعاد للمالك هو الحالة ووقت الانتهاء والمحاولات المتبقية.
-- ==============================================================

create or replace function core.read_well_team(
  p_well_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_members jsonb;
  v_invitations jsonb;
begin
  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  if not iam.has_well_permission(p_well_id, 'team.manage') then
    raise exception 'قراءة فريق هذا البئر متاحة لمالكه'
      using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(x.item order by x.role, x.full_name), '[]'::jsonb)
  into v_members
  from (
    select
      wa.role,
      coalesce(pr.full_name, '') as full_name,
      jsonb_build_object(
        'profile_id', pr.id,
        'full_name', pr.full_name,
        'phone', pr.phone,
        'role', wa.role,
        'status', wa.status,
        'since', wa.created_at
      ) as item
    from core.well_assignments wa
    join iam.profiles pr on pr.id = wa.profile_id
    where wa.well_id = p_well_id
  ) x;

  select coalesce(jsonb_agg(y.item order by y.invited_at desc), '[]'::jsonb)
  into v_invitations
  from (
    select
      inv.invited_at,
      jsonb_build_object(
        'invitation_id', inv.id,
        'full_name', pe.full_name,
        'phone', inv.phone,
        'role', inv.role,
        'status', inv.status,
        'expires_at', inv.expires_at,
        'attempts_left', inv.attempts_left,
        'invited_at', inv.invited_at,
        'claimed_at', inv.claimed_at
      ) as item
    from core.well_invitations inv
    join core.persons pe on pe.id = inv.person_id
    where inv.well_id = p_well_id
  ) y;

  return jsonb_build_object(
    'contract', 'list_well_team',
    'version', 1,
    'members', v_members,
    'invitations', v_invitations
  );
end;
$function$;

comment on function core.read_well_team(uuid) is
  'ق-123: قراءة أعضاء البئر ودعواته المعلَّقة لمالكه. لا يُعاد الرمز ولا تلبيدته — الرمز يُعرض مرة واحدة لحظة الدعوة.';

revoke all on function core.read_well_team(uuid)
  from public, anon, authenticated, service_role;

grant execute on function core.read_well_team(uuid)
  to authenticated, service_role;

-- ==============================================================
-- 7. الأغلفة العامة: INVOKER رقيقة تتحقق ثم تفوّض
--
-- ما يبقى داخل الغلاف هو ما يجب أن يبقى تحت RLS المتصل نفسه: وجود
-- جلسة (28000)، وصلاحية المدخل (22023)، ورؤية البئر عبر سياسة 079
-- فبئر لا تعيين عليه لا يظهر أصلًا (42501). ولا يكرّر الغلاف قرار
-- الصلاحية: القرار حيث يقع التجاوز (اختبار 084 PASS 7).
-- ==============================================================

create or replace function api.invite_well_member(
  p_well_id uuid,
  p_role text,
  p_full_name text,
  p_phone text
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل دعوة عضو'
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

  return core.invite_well_member(p_well_id, p_role, p_full_name, p_phone);
end;
$function$;

comment on function api.invite_well_member(uuid, text, text, text) is
  'عقد دعوة عضو إلى بئر (ق-123). يعيد code نصًّا مرة واحدة عند outcome=invited، وnull عند outcome=linked لمن له حساب قائم.';

revoke all on function api.invite_well_member(uuid, text, text, text)
  from public, anon, authenticated, service_role;

grant execute on function api.invite_well_member(uuid, text, text, text)
  to authenticated, service_role;

create or replace function api.claim_well_invitation(
  p_code text
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل تنشيط الدعوة'
      using errcode = '28000';
  end if;

  -- لا فحص بئر هنا: المتصل لا يعرف بئره بعد، والدعوة هي ما يحدّده.
  return core.claim_well_invitation(p_code);
end;
$function$;

comment on function api.claim_well_invitation(text) is
  'عقد تنشيط دعوة (ق-123). يعيد outcome = claimed | already_claimed | wrong_code | no_invitation، ومع wrong_code عدد المحاولات المتبقية.';

revoke all on function api.claim_well_invitation(text)
  from public, anon, authenticated, service_role;

grant execute on function api.claim_well_invitation(text)
  to authenticated, service_role;

create or replace function api.revoke_well_member(
  p_well_id uuid,
  p_role text,
  p_phone text
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إلغاء وصول عضو'
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

  return core.revoke_well_member(p_well_id, p_role, p_phone);
end;
$function$;

comment on function api.revoke_well_member(uuid, text, text) is
  'عقد إلغاء وصول عضو (ق-123 / الثابت 714): الدعوة revoked والتعيين inactive، بلا حذف أي سجل.';

revoke all on function api.revoke_well_member(uuid, text, text)
  from public, anon, authenticated, service_role;

grant execute on function api.revoke_well_member(uuid, text, text)
  to authenticated, service_role;

create or replace function api.list_well_team(
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
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة الفريق'
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

  return core.read_well_team(p_well_id);
end;
$function$;

comment on function api.list_well_team(uuid) is
  'عقد قراءة فريق البئر ودعواته المعلَّقة (ق-123). لا يعيد رمز تنشيط ولا تلبيدته.';

revoke all on function api.list_well_team(uuid)
  from public, anon, authenticated, service_role;

grant execute on function api.list_well_team(uuid)
  to authenticated, service_role;

commit;











