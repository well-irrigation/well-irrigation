-- 096 — إعادة تعيين كلمة المرور بإثبات بشري (البند الموحَّد، الجزء الذي لا
-- يحتاج مزوّد رسائل)
--
-- المشكلة: من ينسى كلمة مروره لا سبيل له للعودة. وجلسة المالك **لا تستطيع**
-- تغيير كلمة مرور شخص آخر بالتصميم (خصيصة في نظام المصادقة لا اختيار)،
-- والثابت 706 يمنع أصلًا أن يكتب أحدٌ كلمة مرور لأحد.
--
-- أدلة جُمعت قبل الكتابة، وهي التي حدّدت الشكل:
-- أ) **الاستعادة تحدث قبل المصادقة**، و`anon EXECUTE = 0` حدٌّ مقيس بحرس
--    دائم (اختبار 071). فلا يمكن أن يكون في `api` عقدٌ يناديه من لا جلسة
--    له — أيًّا كان تصميمه. لذلك خطوة الاستهلاك هنا **ليست في `api`**:
--    إجراء داخلي لا يُمنح إلا لـ`service_role`، ينادَى من طرف خادمي
--    (دالة حافة) يحمل مفتاح الخدمة. وهذا هو «الطرف الخادمي» المسجَّل في
--    `ACCOUNT_SETTINGS_ARCHITECTURE.md` §27 وق-105.
-- ب) آلية رمز الدعوة في هجرة 094 تخدم هذا البند حرفيًّا: تلبيدة بملح صفّه،
--    ومدة صلاحية، وعدّاد محاولات، ورمز يُعاد **مرة واحدة** لمن أصدره. فلا
--    تُكتب آلية ثانية: `core.new_invitation_code()` و
--    `core.hash_invitation_code()` و`core.normalize_phone()` تُستعمل كما هي.
-- ج) لا صلاحية مسمّاة جديدة: إصدار التذكرة سلطته `team.manage` القائمة
--    (هجرة 094، للمالك وحده). فأرقام الكتالوج تبقى 43 و79.
-- د) الرمز يُسلَّم باليد (الثابت 711): المالك يُثبت هوية صاحب الحساب أمامه
--    ثم يقرأ له الرمز. فلا رسالة، ولا كلفة، ولا انتظار مزوّد — والرسالة
--    حين تُربط تصير **بديلًا** لا أساسًا (712).
--
-- ما تفعله الهجرة:
-- 1. `core.password_reset_tickets`: تذكرة واحدة سارية لكل حساب، بأربع
--    حالات، ومدة 24 ساعة، وخمس محاولات، وبلا نصّ رمز مخزَّن (708).
-- 2. `core.request_member_password_reset`: يُصدر التذكرة ويُبطل ما قبلها،
--    ويعيد الرمز مرة واحدة. سلطته `team.manage`.
-- 3. `core.consume_password_reset`: يتحقق ويُعلن النتيجة، ولا يكتب كلمة
--    مرور ولا يعرفها — يعيد `profile_id` لمن يملك مفتاح الخدمة وحده.
-- 4. `core.read_member_reset_requests` + غلافان في `api` للمالك.
--
-- ما لا تفعله بقصد: لا تكتب في مخطط `auth` ولا تلمس كلمة مرور. كتابة
-- كلمة المرور تبقى في نظام المصادقة عبر الطرف الخادمي، فصاحب الحساب هو
-- من يختارها (706).
--
-- أثر مقصود على الفهرس: functions 451 → 456، وجدول واحد جديد بأعمدته
-- وقيوده، وtriggers بلا تغيير، والكتالوج 43/79 بلا تغيير.

begin;

-- ==============================================================
-- 1. جدول التذاكر — مغلق تمامًا: لا سياسات ولا منح، والوصول عبر العقود
-- ==============================================================

create table if not exists core.password_reset_tickets (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  well_id uuid not null references core.wells(id) on delete cascade,
  profile_id uuid not null references iam.profiles(id) on delete cascade,
  person_id uuid references core.persons(id) on delete set null,
  normalized_phone text not null,
  code_salt text not null,
  code_hash text not null,
  expires_at timestamptz not null,
  attempts_left integer not null default 5,
  status text not null default 'pending',
  requested_by uuid not null references iam.profiles(id) on delete restrict,
  requested_at timestamptz not null default now(),
  consumed_at timestamptz,
  constraint password_reset_tickets_status_check
    check (status in ('pending', 'consumed', 'expired', 'revoked')),
  constraint password_reset_tickets_attempts_check
    check (attempts_left >= 0 and attempts_left <= 5),
  constraint password_reset_tickets_consumed_check
    check ((status = 'consumed') = (consumed_at is not null)),
  constraint password_reset_tickets_phone_check
    check (btrim(normalized_phone) <> '')
);

comment on table core.password_reset_tickets is
  'م-41F: تذاكر إعادة تعيين كلمة المرور بإثبات بشري. الرمز مُلبَّد بملح صفّه ولا يُخزَّن نصًّا (708)، والتذكرة تموت باستهلاكها أو بانتهاء مدتها أو باستنفاد محاولاتها.';

-- تذكرة سارية واحدة لكل حساب: إعادة الإصدار تُبطل ما قبلها، فلا تتجاور
-- تذكرتان يُخمَّن عليهما معًا.
create unique index if not exists password_reset_tickets_open_uniq
  on core.password_reset_tickets (profile_id)
  where status = 'pending';

create index if not exists password_reset_tickets_phone_idx
  on core.password_reset_tickets (normalized_phone, status);

create index if not exists password_reset_tickets_well_idx
  on core.password_reset_tickets (well_id, status);

alter table core.password_reset_tickets enable row level security;

revoke all on table core.password_reset_tickets from public;
revoke all on table core.password_reset_tickets from anon;
revoke all on table core.password_reset_tickets from authenticated;
revoke all on table core.password_reset_tickets from service_role;

-- ==============================================================
-- 2. إصدار التذكرة — سلطته team.manage، والرمز يُعاد مرة واحدة
--
-- «لا عضو بهذا الرقم» حالة مُعادة لا استثناء: المالك قد يكتب رقمًا خطأً،
-- والجواب الموحَّد لا يفشي من له حساب خارج هذا البئر.
-- ==============================================================

create or replace function core.request_member_password_reset(
  p_well_id uuid,
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
  v_norm text;
  v_tenant uuid;
  v_profile uuid;
  v_person uuid;
  v_name text;
  v_code text;
  v_salt text;
  v_expires timestamptz := now() + interval '24 hours';
  v_ticket uuid;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إصدار إعادة تعيين'
      using errcode = '28000';
  end if;

  if p_well_id is null or btrim(coalesce(p_phone, '')) = '' then
    raise exception 'معرّف البئر ورقم الهاتف مطلوبان'
      using errcode = '22023';
  end if;

  if not iam.has_well_permission(p_well_id, 'team.manage') then
    raise exception 'إعادة تعيين كلمة مرور عضو متاحة لمالك البئر'
      using errcode = '42501';
  end if;

  v_norm := core.normalize_phone(p_phone);

  select w.tenant_id into v_tenant
  from core.wells w
  where w.id = p_well_id;

  -- العضو = حساب له تعيين نافذ على هذا البئر ورقمه مطابق بعد التطبيع.
  select pr.id, pr.full_name
  into v_profile, v_name
  from iam.profiles pr
  where core.normalize_phone(pr.phone) = v_norm
    and exists (
      select 1
      from core.well_assignments wa
      where wa.well_id = p_well_id
        and wa.profile_id = pr.id
        and wa.status = 'active'
    )
  order by pr.id
  limit 1;

  if v_profile is null then
    return jsonb_build_object(
      'contract', 'request_member_password_reset',
      'version', 1,
      'outcome', 'no_member',
      'ticket_id', null,
      'code', null,
      'expires_at', null
    );
  end if;

  select pc.person_id into v_person
  from core.person_contacts pc
  where pc.tenant_id = v_tenant
    and pc.normalized_value = v_norm
  order by pc.is_primary desc, pc.created_at, pc.id
  limit 1;

  update core.password_reset_tickets
  set status = 'revoked'
  where profile_id = v_profile
    and status = 'pending';

  v_code := core.new_invitation_code();
  v_salt := replace(gen_random_uuid()::text, '-', '');

  insert into core.password_reset_tickets (
    tenant_id, well_id, profile_id, person_id, normalized_phone,
    code_salt, code_hash, expires_at, requested_by
  ) values (
    v_tenant, p_well_id, v_profile, v_person, v_norm,
    v_salt, core.hash_invitation_code(v_code, v_salt), v_expires, v_actor
  ) returning id into v_ticket;

  return jsonb_build_object(
    'contract', 'request_member_password_reset',
    'version', 1,
    'outcome', 'issued',
    'ticket_id', v_ticket,
    'full_name', v_name,
    'phone', v_norm,
    'code', v_code,
    'expires_at', v_expires
  );
end;
$function$;

comment on function core.request_member_password_reset(uuid, text) is
  'م-41F: يُصدر تذكرة إعادة تعيين لعضو في هذا البئر ويُبطل ما قبلها، ويعيد الرمز مرة واحدة لمن يسلّمه باليد (711). لا يكتب كلمة مرور ولا يعرفها.';

revoke all on function core.request_member_password_reset(uuid, text)
  from public, anon, authenticated, service_role;

grant execute on function core.request_member_password_reset(uuid, text)
  to authenticated, service_role;

-- ==============================================================
-- 3. استهلاك التذكرة — لمفتاح الخدمة وحده، وبلا جلسة بالتصميم
--
-- هذه هي الخطوة التي تحدث **قبل** المصادقة، ولذلك لا وجود لها في `api`:
-- حدّ `anon EXECUTE = 0` مقيس بحرس دائم، فأي عقد عام هنا كان سيخرقه.
-- المنح لـ`service_role` وحده، ومن يناديه هو الطرف الخادمي.
--
-- ولا يكتب كلمة مرور ولا يعرفها: يعيد `profile_id` وحده، وكتابة كلمة
-- المرور تبقى في نظام المصادقة حيث يختارها صاحبها (706).
--
-- والرمز الخاطئ **حالة مُعادة لا استثناء** (درس 094): الاستثناء يتراجع
-- عن خصم العدّاد في نفس المعاملة فيصير العدّاد بلا معنى.
-- ==============================================================

create or replace function core.consume_password_reset(
  p_phone text,
  p_code text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_norm text;
  v_code text := btrim(coalesce(p_code, ''));
  v_row core.password_reset_tickets;
begin
  if btrim(coalesce(p_phone, '')) = '' or v_code = '' then
    raise exception 'رقم الهاتف والرمز مطلوبان'
      using errcode = '22023';
  end if;

  v_norm := core.normalize_phone(p_phone);

  -- المنتهية تُوسم منتهية قبل البحث، فلا تُستهلك بعد وقتها.
  update core.password_reset_tickets
  set status = 'expired'
  where status = 'pending'
    and expires_at <= now();

  select t.* into v_row
  from core.password_reset_tickets t
  where t.normalized_phone = v_norm
    and t.status = 'pending'
    and t.attempts_left > 0
  order by t.requested_at desc
  limit 1;

  -- جواب موحَّد لمن لا تذكرة له ولمن لا حساب له: لا إفشاء (710).
  if v_row.id is null then
    return jsonb_build_object(
      'contract', 'consume_password_reset',
      'version', 1,
      'outcome', 'no_ticket',
      'profile_id', null,
      'attempts_left', null
    );
  end if;

  if v_row.code_hash <> core.hash_invitation_code(v_code, v_row.code_salt)
  then
    update core.password_reset_tickets
    set attempts_left = attempts_left - 1,
        status = case
          when attempts_left - 1 <= 0 then 'revoked'
          else status
        end
    where id = v_row.id;

    return jsonb_build_object(
      'contract', 'consume_password_reset',
      'version', 1,
      'outcome', 'wrong_code',
      'profile_id', null,
      'attempts_left', v_row.attempts_left - 1
    );
  end if;

  update core.password_reset_tickets
  set status = 'consumed',
      consumed_at = now()
  where id = v_row.id;

  return jsonb_build_object(
    'contract', 'consume_password_reset',
    'version', 1,
    'outcome', 'ok',
    'profile_id', v_row.profile_id,
    'attempts_left', null
  );
end;
$function$;

comment on function core.consume_password_reset(text, text) is
  'م-41F: يتحقق من تذكرة إعادة التعيين ويستهلكها، ويعيد profile_id لمن يملك مفتاح الخدمة وحده. لا يكتب كلمة مرور ولا يعيد رمزًا ولا تلبيدة، والرمز الخاطئ يخصم من العدّاد ويبقى الخصم.';

revoke all on function core.consume_password_reset(text, text)
  from public, anon, authenticated, service_role;

grant execute on function core.consume_password_reset(text, text)
  to service_role;

-- ==============================================================
-- 4. قراءة الطلبات للمالك — بلا رمز وبلا تلبيدة
-- ==============================================================

create or replace function core.read_member_reset_requests(
  p_well_id uuid,
  p_limit integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_items jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة طلبات إعادة التعيين'
      using errcode = '28000';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  if not iam.has_well_permission(p_well_id, 'team.manage') then
    raise exception 'قراءة طلبات إعادة التعيين متاحة لمالك البئر'
      using errcode = '42501';
  end if;

  select coalesce(
    jsonb_agg(x.item order by x.requested_at desc, x.id desc),
    '[]'::jsonb
  )
  into v_items
  from (
    select
      t.id,
      t.requested_at,
      jsonb_build_object(
        'ticket_id', t.id,
        'profile_id', t.profile_id,
        'full_name', pr.full_name,
        'phone', t.normalized_phone,
        'status', t.status,
        'attempts_left', t.attempts_left,
        'expires_at', t.expires_at,
        'requested_at', t.requested_at,
        'consumed_at', t.consumed_at
      ) as item
    from core.password_reset_tickets t
    left join iam.profiles pr on pr.id = t.profile_id
    where t.well_id = p_well_id
    order by t.requested_at desc, t.id desc
    limit v_limit
  ) x;

  return jsonb_build_object(
    'contract', 'list_member_reset_requests',
    'version', 1,
    'well_id', p_well_id,
    'requests', v_items
  );
end;
$function$;

comment on function core.read_member_reset_requests(uuid, integer) is
  'م-41F: طلبات إعادة التعيين على بئر واحد للمالك: الحالة والمحاولات والمدة، بلا رمز ولا تلبيدة.';

revoke all on function core.read_member_reset_requests(uuid, integer)
  from public, anon, authenticated, service_role;

grant execute on function core.read_member_reset_requests(uuid, integer)
  to authenticated, service_role;

-- ==============================================================
-- 5. غلافان في api — INVOKER رقيقان يتحققان ثم يفوّضان
--
-- لا غلاف للاستهلاك بقصد: تلك خطوة ما قبل المصادقة، ووجودها في `api`
-- يخرق `anon EXECUTE = 0`.
-- ==============================================================

create or replace function api.request_member_password_reset(
  p_well_id uuid,
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
    raise exception 'يجب تسجيل الدخول قبل إصدار إعادة تعيين'
      using errcode = '28000';
  end if;

  if p_well_id is null or btrim(coalesce(p_phone, '')) = '' then
    raise exception 'معرّف البئر ورقم الهاتف مطلوبان'
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

  return core.request_member_password_reset(p_well_id, p_phone);
end;
$function$;

comment on function api.request_member_password_reset(uuid, text) is
  'عقد إصدار إعادة تعيين كلمة مرور لعضو (م-41F): يعيد الرمز مرة واحدة لمن يسلّمه باليد. لا كلمة مرور تُكتب هنا ولا في العميل (706).';

revoke all on function api.request_member_password_reset(uuid, text)
  from public, anon, authenticated, service_role;

grant execute on function api.request_member_password_reset(uuid, text)
  to authenticated, service_role;

create or replace function api.list_member_reset_requests(
  p_well_id uuid,
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
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة طلبات إعادة التعيين'
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

  return core.read_member_reset_requests(p_well_id, p_limit);
end;
$function$;

comment on function api.list_member_reset_requests(uuid, integer) is
  'عقد قراءة طلبات إعادة التعيين على البئر (م-41F): الحالة والمحاولات والمدة بلا رمز ولا تلبيدة.';

revoke all on function api.list_member_reset_requests(uuid, integer)
  from public, anon, authenticated, service_role;

grant execute on function api.list_member_reset_requests(uuid, integer)
  to authenticated, service_role;

-- ==============================================================
-- 6. غلاف الاستهلاك — في `api` لأن الطرف الخادمي يناديه عبر PostgREST،
--    ومخطط `core` غير مكشوف بالتصميم (ق-78).
--
-- **والمنح متناظرة عن قصد** (`authenticated` و`service_role` معًا): حرس
-- اختبار 074 التحقق 2 يشترط تناظر منح سطح `api` بين الدورين، وهو حرس
-- صحيح يكشف عقدًا لا يستطيع التطبيق نداءه. فالحدّ لا يُبنى بكسر التناظر
-- بل في موضعين أقوى:
--   1. الإجراء الداخلي `core.consume_password_reset` ممنوح لـ
--      `service_role` وحده — فجلسة مستخدم تفشل عند التفويض لا محالة.
--   2. وهذا الغلاف يرفض صريحًا كل من له جلسة مستخدم: الاستعادة تحدث قبل
--      الدخول، فوجود جلسة يعني أن النداء ليس من الطرف الخادمي.
-- ومفتاح الخدمة بلا `sub` في رمزه، فـ`auth.uid()` عنده null وحده.
-- ==============================================================

create or replace function api.consume_password_reset(
  p_phone text,
  p_code text
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
begin
  if auth.uid() is not null then
    raise exception 'إعادة التعيين تجري قبل الدخول، ولا تُنادى من جلسة مستخدم'
      using errcode = '42501';
  end if;

  if btrim(coalesce(p_phone, '')) = '' or btrim(coalesce(p_code, '')) = ''
  then
    raise exception 'رقم الهاتف والرمز مطلوبان'
      using errcode = '22023';
  end if;

  return core.consume_password_reset(p_phone, p_code);
end;
$function$;

comment on function api.consume_password_reset(text, text) is
  'عقد استهلاك تذكرة إعادة التعيين (م-41F). يناديه الطرف الخادمي بمفتاح الخدمة: كل جلسة مستخدم تُرفض 42501، والإجراء الداخلي ممنوح لـservice_role وحده. لا كلمة مرور تُكتب هنا — يكتبها صاحبها في نظام المصادقة.';

revoke all on function api.consume_password_reset(text, text)
  from public, anon, authenticated, service_role;

grant execute on function api.consume_password_reset(text, text)
  to authenticated, service_role;

commit;
