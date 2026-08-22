-- =====================================================================
-- Migration 083 — W2-01/1 — مُحلِّلات هوية العملية (Command Resolvers)
-- القرار: ق-114 (W2-01 Server-side idempotency)
-- المسألة: م-25 (تضيق ولا تُغلق)
--
-- الغرض:
--   تمكين طبقة `api` من استخدام حماية التكرار القائمة في `sync`
--   دون أن يُرسل العميل `tenant_id` بنفسه.
--
--   المشكلة العملية: عند ضعف الشبكة يُنفِّذ الخادم العملية ثم يضيع
--   الردّ، فيعيد الهاتف الإرسال، فتُسجَّل العملية مرتين. الأثر
--   الأخطر مالي: دفعة واحدة تصبح دفعتين.
--
-- قواعد التصميم:
--   1) إعادة استخدام لا استبدال. `sync.begin_command` و
--      `sync.finish_command` من 058 تبقى كما هي وهي المُنفِّذ
--      الفعلي. وفق ق-89 بند 10: لا تنشأ طبقة duplicate-prevention
--      موازية.
--   2) العميل لا يُرسل `tenant_id` أبدًا. تُستخرَج على الخادم من
--      البئر أو الجلسة. تمرير tenant غير مملوك كان يسمح بحجز
--      `command_id` سلفًا فتبدو عملية الضحية «مكرَّرة» فلا تُنفَّذ.
--      وهذا امتداد لنفس منطق ق-78/ق-79 في عدم كشف هوية المنفِّذ.
--   3) لا قرار صلاحية هنا. المُحلِّل لا يسأل عن رمز صلاحية ولا عن
--      دور، ولا يقرر ما يجوز للمتصل فعله — ذلك يبقى في الدوال
--      الداخلية عبر `iam.has_well_permission` (ق-113). لكنه يرفض
--      أن يلمس بئرًا أو جلسة لا علاقة للمتصل بها أصلًا: يشترط
--      تعيينًا نشطًا (`core.well_assignments`) بلا اشتراط دور.
--      هذا حدّ نطاق (Scope) لا تفويض (Authority).
--   4) الشرط في البند 3 لا يغيّر نتيجة أي عملية مشروعة، والبرهان:
--      `iam.has_well_permission` نفسها تشترط
--      `wa.profile_id = auth.uid() and wa.status = 'active'`
--      (`080:243`). فالعضوية شرط لازم لكل واحدة من العمليات
--      الثماني، ومن يجتاز فحص الصلاحية الداخلي يجتاز هذا الشرط
--      حتمًا. فلا يمكن أن يرفض المُحلِّل عملية كانت الدالة
--      الداخلية ستقبلها.
--   5) رسالة واحدة لحالتي «غير موجود» و«لا علاقة لك به»، حتى لا
--      يصبح المُحلِّل كاشفًا لوجود معرّفات جهات أخرى.
--   6) `security definer` لازم لأن 072 سحبت DML من `authenticated`
--      على كل المخططات الداخلية بما فيها `sync`، وأغلفة `api`
--      تبقى `security invoker` وفق ق-78.
--   7) `search_path` مثبَّت، و EXECUTE إلى `authenticated`
--      و`service_role` فقط — نفس مستفيدي أغلفة `api` بالضبط، حتى
--      لا توجد هوية تستطيع بدء العملية ولا تستطيع إتمامها.
--   8) لا تلمس هذه الهجرة أي جدول ولا أي RLS policy ولا أي دالة
--      أعمال. لا تغيير في سلوك أي مستخدم حالي.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- A) تقوية: سحب EXECUTE العام عن مُنفِّذي 058
--
-- دوال PostgreSQL تمنح EXECUTE إلى PUBLIC افتراضيًا. الملف 058 لم
-- يسحب ذلك. لا ثقب حيّ اليوم لأن `sync` غير مكشوف عبر Data API
-- (`config.toml` يكشف `api` و`graphql_public` فقط)، لكن بقاء المنح
-- يخالف Least Privilege في ق-89 بند 22 ويجعل الأمان معتمدًا على
-- إعداد خارجي وحده لا على منح قاعدة البيانات.
--
-- هاتان الدالتان تأخذان `p_tenant_id` من المتصل بلا تحقق، فلا يجوز
-- أن تكونا في متناول أي دور عميل.
-- ---------------------------------------------------------------------

revoke all on function
  sync.begin_command(uuid, uuid, text, jsonb, uuid)
from public, anon, authenticated;

revoke all on function
  sync.finish_command(uuid, uuid, text, jsonb)
from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- B) بدء عملية معرَّفة ببئر
--
-- تُستخدم للعمليات التي يحدد البئر نطاقها:
-- بدء جلسة، تسجيل دفعة، إنشاء مزارع، إنشاء أرض.
--
-- الشرط: تعيين نشط على البئر. بلا اشتراط دور — القرار في الداخل.
-- ---------------------------------------------------------------------

create or replace function sync.begin_well_command(
  p_well_id uuid,
  p_command_id uuid,
  p_command_type text,
  p_payload jsonb default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_tenant_id uuid;
begin
  if p_command_id is null then
    raise exception 'معرّف العملية مطلوب';
  end if;

  select w.tenant_id
  into v_tenant_id
  from core.wells w
  where w.id = p_well_id
    and exists (
      select 1
      from core.well_assignments wa
      where wa.well_id = w.id
        and wa.profile_id = auth.uid()
        and wa.status = 'active'
    );

  if v_tenant_id is null then
    raise exception 'البئر غير موجود أو لا تملك وصولًا إليه';
  end if;

  return sync.begin_command(
    v_tenant_id,
    p_command_id,
    p_command_type,
    p_payload,
    null
  );
end;
$function$;

comment on function sync.begin_well_command(uuid, uuid, text, jsonb) is
  'ق-114: يحلّ الجهة من بئر يملك المتصل تعيينًا نشطًا عليه، ثم يحجز معرّف العملية عبر sync.begin_command. حدّ نطاق لا قرار صلاحية.';


-- ---------------------------------------------------------------------
-- C) إنهاء عملية معرَّفة ببئر
-- ---------------------------------------------------------------------

create or replace function sync.finish_well_command(
  p_well_id uuid,
  p_command_id uuid,
  p_status text,
  p_response jsonb default null
)
returns void
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_tenant_id uuid;
begin
  select w.tenant_id
  into v_tenant_id
  from core.wells w
  where w.id = p_well_id
    and exists (
      select 1
      from core.well_assignments wa
      where wa.well_id = w.id
        and wa.profile_id = auth.uid()
        and wa.status = 'active'
    );

  if v_tenant_id is null then
    raise exception 'البئر غير موجود أو لا تملك وصولًا إليه';
  end if;

  perform sync.finish_command(
    v_tenant_id,
    p_command_id,
    p_status,
    p_response
  );
end;
$function$;

comment on function sync.finish_well_command(uuid, uuid, text, jsonb) is
  'ق-114: يثبّت نتيجة عملية معرَّفة ببئر حتى تُعاد حرفيًا عند إعادة المحاولة.';


-- ---------------------------------------------------------------------
-- D) بدء عملية معرَّفة بجلسة سقي
--
-- تُستخدم لأحداث الجلسة الجارية: Pause، Resume، تغيير مصدر الطاقة،
-- الإنهاء. الجلسة لا تحمل `tenant_id` مباشرة، فتُستخرَج عبر بئرها،
-- ويُشترط تعيين نشط على ذلك البئر.
-- ---------------------------------------------------------------------

create or replace function sync.begin_session_command(
  p_session_id uuid,
  p_command_id uuid,
  p_command_type text,
  p_payload jsonb default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_tenant_id uuid;
begin
  if p_command_id is null then
    raise exception 'معرّف العملية مطلوب';
  end if;

  select w.tenant_id
  into v_tenant_id
  from ops.irrigation_sessions s
  join core.wells w
    on w.id = s.well_id
  where s.id = p_session_id
    and exists (
      select 1
      from core.well_assignments wa
      where wa.well_id = w.id
        and wa.profile_id = auth.uid()
        and wa.status = 'active'
    );

  if v_tenant_id is null then
    raise exception 'الجلسة غير موجودة أو لا تملك وصولًا إليها';
  end if;

  return sync.begin_command(
    v_tenant_id,
    p_command_id,
    p_command_type,
    p_payload,
    p_session_id
  );
end;
$function$;

comment on function sync.begin_session_command(uuid, uuid, text, jsonb) is
  'ق-114: يحلّ الجهة من جلسة سقي في بئر يملك المتصل تعيينًا نشطًا عليه، ثم يحجز معرّف العملية. حدّ نطاق لا قرار صلاحية.';


-- ---------------------------------------------------------------------
-- E) إنهاء عملية معرَّفة بجلسة سقي
-- ---------------------------------------------------------------------

create or replace function sync.finish_session_command(
  p_session_id uuid,
  p_command_id uuid,
  p_status text,
  p_response jsonb default null
)
returns void
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_tenant_id uuid;
begin
  select w.tenant_id
  into v_tenant_id
  from ops.irrigation_sessions s
  join core.wells w
    on w.id = s.well_id
  where s.id = p_session_id
    and exists (
      select 1
      from core.well_assignments wa
      where wa.well_id = w.id
        and wa.profile_id = auth.uid()
        and wa.status = 'active'
    );

  if v_tenant_id is null then
    raise exception 'الجلسة غير موجودة أو لا تملك وصولًا إليها';
  end if;

  perform sync.finish_command(
    v_tenant_id,
    p_command_id,
    p_status,
    p_response
  );
end;
$function$;

comment on function sync.finish_session_command(uuid, uuid, text, jsonb) is
  'ق-114: يثبّت نتيجة حدث جلسة حتى يُعاد حرفيًا عند إعادة المحاولة.';


-- ---------------------------------------------------------------------
-- F) المنح: الحد الأدنى فقط
--
-- تُسحب المنح الافتراضية أولًا ثم تُمنح صراحة إلى `authenticated`
-- و`service_role` — وهما بالضبط مستفيدو أغلفة `api` الثمانية، فلا
-- توجد هوية تستطيع استدعاء الغلاف ولا تستطيع حجز معرّف العملية.
-- `anon` لا يملك شيئًا.
--
-- المُحلِّلات آمنة للعميل لأنها لا تقبل `tenant_id` منه، وتشترط
-- تعيينًا نشطًا على البئر قبل أي كتابة.
-- ---------------------------------------------------------------------

revoke all on function
  sync.begin_well_command(uuid, uuid, text, jsonb)
from public, anon, authenticated, service_role;

revoke all on function
  sync.finish_well_command(uuid, uuid, text, jsonb)
from public, anon, authenticated, service_role;

revoke all on function
  sync.begin_session_command(uuid, uuid, text, jsonb)
from public, anon, authenticated, service_role;

revoke all on function
  sync.finish_session_command(uuid, uuid, text, jsonb)
from public, anon, authenticated, service_role;

grant execute on function
  sync.begin_well_command(uuid, uuid, text, jsonb)
to authenticated, service_role;

grant execute on function
  sync.finish_well_command(uuid, uuid, text, jsonb)
to authenticated, service_role;

grant execute on function
  sync.begin_session_command(uuid, uuid, text, jsonb)
to authenticated, service_role;

grant execute on function
  sync.finish_session_command(uuid, uuid, text, jsonb)
to authenticated, service_role;

commit;
