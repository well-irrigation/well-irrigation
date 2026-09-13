-- 099 — دليل المزارعين: آخر جلسة، والأرض، والدين، في قراءة واحدة
--
-- **الحاجة المقيسة (2026-09-04، أول تشغيل ميداني):** المالك يسأل يوميًّا «من
-- سقى أخيرًا؟» و«من عليه مستحقّات؟»، والعقد القائم `api.list_well_farmers`
-- (089) يرتّب **أبجديًّا** ولا يعيد تاريخ جلسة ولا رصيدًا ولا عدد أراضٍ. فلا
-- يمكن ترتيب القائمة بآخر سقي ولا فلترتها بالدين — والعميل لا يخترع رقمًا لا
-- يرسله الخادم (ق-99).
--
-- **ولماذا عقد جديد لا توسيع القائم:** `list_well_farmers` يُستعمل في اختيار
-- المزارع أثناء بدء جلسة — سياقٌ يحتاج الاسم والرقم وحدهما، وحمله بأرقام
-- مالية يوسّع سطح الكشف بلا حاجة. فالجديد لدليل المزارعين وحده، والقائم يبقى
-- كما هو بلا تغيير في توقيعه ولا في حمولته.
--
-- **ولا صلاحية جديدة:** الحمولة كلها من مصادر يراها من يرى البئر أصلًا —
-- `reporting.farmer_account_balances` (المستعمل في 095) و`ops.farms` و
-- `ops.irrigation_sessions`. والكتالوج يبقى 43/79.

-- ---------------------------------------------------------------------
-- دليل المزارعين الغنيّ
-- ---------------------------------------------------------------------
create or replace function api.list_well_farmer_directory(
  p_well_id uuid,
  p_query text default null,
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
  v_query text := nullif(btrim(coalesce(p_query, '')), '');
  v_limit integer := least(greatest(coalesce(p_limit, 200), 1), 500);
  v_tz text;
  v_day_bounds tstzrange;
  v_today date;
  v_items jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة المزارعين'
      using errcode = '28000';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  -- RLS على core.wells هي مصدر التفويض؛ البئر غير المرئي = رفض صريح
  -- بدل قائمة فارغة غامضة.
  if not exists (
    select 1
    from core.wells w
    where w.id = p_well_id
  ) then
    raise exception 'لا توجد صلاحية على هذا البئر'
      using errcode = '42501';
  end if;

  -- يوم البئر بمنطقة الجهة (098): «آخر سقي» واليوم المرجعي يُحسبان في
  -- المنطقة نفسها. واليوم يُشتق من الحدّ الحاكم نفسه، لا من حساب ثانٍ قد
  -- ينحرف عنه: `period_bounds('today')` يبدأ عند 00:00:00 المحلي بالضبط.
  v_tz := core.well_timezone(p_well_id);
  v_day_bounds := core.period_bounds(p_well_id, 'today');
  v_today := (lower(v_day_bounds) at time zone v_tz)::date;

  -- الترتيب: آخر سقي أولًا (قرار المالك 2026-09-04)، ومن لم يسقِ قطّ في
  -- الآخر — `nulls last` لا يُحوّل الغياب إلى «أقدم جلسة» كاذبة. ثم الدين
  -- الأعلى، ثم الاسم: ترتيبٌ حاسم فلا يتغيّر بين قراءتين.
  select coalesce(
    jsonb_agg(
      x.item order by
        x.last_session_at desc nulls last,
        x.debt_minor desc,
        x.full_name,
        x.id
    ),
    '[]'::jsonb
  )
  into v_items
  from (
    select
      fwa.id,
      pe.full_name,
      s.last_session_at,
      coalesce(b.debt_minor, 0) as debt_minor,
      jsonb_build_object(
        'id', fwa.id,
        'public_code', fwa.public_code,
        'full_name', pe.full_name,
        'phone', (
          select pc.contact_value
          from core.person_contacts pc
          where pc.person_id = pe.id
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
        'farms_count', coalesce(f.farms_count, 0),
        -- المبالغ من عرض الأرصدة كما هي: لا حساب في العقد ولا في العميل.
        'invoiced_minor', coalesce(b.invoiced_minor, 0),
        'allocated_minor', coalesce(b.allocated_minor, 0),
        'advance_minor', coalesce(b.advance_minor, 0),
        'debt_minor', coalesce(b.debt_minor, 0),
        -- اللحظة كاملةً **واليوم المحلي معها**: العميل يعرض اليوم ولا يشتقّه،
        -- فلا يختلف «آخر سقي» باختلاف منطقة الجهاز.
        'last_session_at', s.last_session_at,
        'last_session_day', (s.last_session_at at time zone v_tz)::date,
        'sessions_count', coalesce(s.sessions_count, 0),
        'has_open_session', coalesce(s.has_open, false)
      ) as item
    from ops.farmer_well_accounts fwa
    join ops.farmer_profiles fp
      on fp.id = fwa.farmer_profile_id
    join core.persons pe
      on pe.id = fp.person_id
    left join reporting.farmer_account_balances b
      on b.farmer_well_account_id = fwa.id
     and b.well_id = fwa.well_id
    left join (
      select
        fr.farmer_well_account_id as account_id,
        count(*) as farms_count
      from ops.farms fr
      where fr.well_id = p_well_id
        and fr.status = 'active'
      group by fr.farmer_well_account_id
    ) f on f.account_id = fwa.id
    left join (
      -- آخر سقي = آخر **نهاية** جلسة (ق-27)، والجلسة الجارية لا تُعدّ نهايةً
      -- (ق-37) لكن حضورها يُعلَن في حقله. وهذا يُبقي العقد متسقًا مع 098.
      select
        ses.farmer_well_account_id as account_id,
        max(ses.ended_at) as last_session_at,
        count(*) filter (where ses.ended_at is not null) as sessions_count,
        bool_or(ses.ended_at is null) as has_open
      from ops.irrigation_sessions ses
      where ses.well_id = p_well_id
      group by ses.farmer_well_account_id
    ) s on s.account_id = fwa.id
    where fwa.well_id = p_well_id
      and fwa.status = 'active'
      and (
        v_query is null
        or pe.full_name ilike '%' || v_query || '%'
        or fwa.public_code ilike '%' || v_query || '%'
        or exists (
          select 1
          from core.person_contacts pc
          where pc.person_id = pe.id
            and (
              pc.contact_value ilike '%' || v_query || '%'
              or pc.normalized_value ilike '%' || v_query || '%'
            )
        )
      )
    order by
      s.last_session_at desc nulls last,
      coalesce(b.debt_minor, 0) desc,
      pe.full_name,
      fwa.id
    limit v_limit
  ) x;

  return jsonb_build_object(
    'contract', 'list_well_farmer_directory',
    'version', 1,
    'well_id', p_well_id,
    'timezone', v_tz,
    'current_day', v_today,
    -- أساس الترتيب يُعلَن في المخرَج: العميل يعرض ما رتّبه الخادم ولا يعيد
    -- ترتيبه بنفسه، فإن تغيّر الأساس يومًا ظهر في الحمولة لا في الكود.
    'sort', 'last_session_at desc, debt desc, name',
    'session_day_basis', 'ended_at',
    'items', v_items
  );
end;
$function$;

comment on function api.list_well_farmer_directory(uuid, text, integer) is
  'دليل مزارعي البئر (099): الاسم والهاتف وعدد الأراضي والأرصدة وآخر سقي، مرتَّبًا بآخر سقي. آخر سقي = آخر نهاية جلسة (ق-27)، واليوم بمنطقة الجهة (098).';

revoke all on function api.list_well_farmer_directory(uuid, text, integer)
  from public, anon, authenticated, service_role;

grant execute on function api.list_well_farmer_directory(uuid, text, integer)
  to authenticated, service_role;
