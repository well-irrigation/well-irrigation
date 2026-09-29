-- =====================================================================
-- Migration 109 — حيازة المشغل النقدية والترحيل (ق-131 بند 18 / م-45 A)
--
-- العقد الحاكم:
--   1. النقد المحصَّل من مزارع بيد مشغل يبقى مال البئر/العمل **في حيازة
--      ذلك المشغل** لذلك البئر — وليس محفظته الشخصية الاقتصادية.
--   2. الترحيل ينقل الحيازة من صندوق حيازة المشغل إلى صندوق البئر العام
--      — **نقل حيازة لا إيراد ثاني**: حساب 1000 مدينًا للوجهة ودائنًا
--      للمصدر، والمبلغ الاقتصادي الكلي للبئر لا يتغير.
--   3. المصروف مصروف البئر اقتصاديًا دائمًا: إن دُفع فعليًا من نقد في
--      حيازة المشغل خُفضت الحيازة؛ وإن دُفع من مصدر آخر لا تُخفض لمجرد
--      أن المشغل سجّله.
--   4. تُعاد استخدام البنى القائمة: finance.cashboxes (النوع
--      operator_custody موجود في 041)، ops.shifts، ops.shift_handovers
--      (يُمدَّد لا يُستنسخ)، القيود اليومية، reporting.cashbox_balances.
--      **لا محفظة موازية ولا جدول أرصدة ولا حقيقة محاسبية ثانية.**
--   5. تسليم النقد القائم (شخص/عادي) يبقى كما هو ولا يصير ترحيل بئر
--      صمتًا: handover_kind الافتراضي 'person' للصفوف التاريخية.
--
-- الأساس المعاد بناؤه حرفيًا:
--   ops.open_shift وops.confirm_handover وops.settle_handover من 042،
--   billing.record_payment من 081، billing.fill_payment_context من 045،
--   finance.fill_expense_context من 044، ops.operator_totals من 045.
--   التغيير الوحيد في record_payment هو سلطة الصندوق النقدي؛ كل ما
--   عدا ذلك (payment.create، التخصيصات، الزيادة→مقدم، التدقيق، القيود،
--   الإيصال، غلاف 084 للمعرف الثابت) باقٍ كما هو.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- A) صندوق حيازة المشغل: فريد نشط لكل (بئر، مشغل)
-- ---------------------------------------------------------------------

-- حارس صريح قبل الفهرس الفريد: إن وُجدت صفوف نشطة مكررة فالهجرة تسقط
-- ولا تُدمج الحاويات المالية صمتًا.
do $$
begin
  if exists (
    select 1 from finance.cashboxes
    where cashbox_type = 'operator_custody' and status = 'active'
    group by well_id, assigned_profile_id
    having count(*) > 1
  ) then
    raise exception 'توجد صناديق حيازة نشطة مكررة لنفس (البئر، المشغل) — يلزم قرار صريح بمعالجتها قبل هذه الهجرة، ولا تُدمج صمتًا';
  end if;
end $$;

create unique index cashboxes_one_active_custody_per_operator
  on finance.cashboxes (well_id, assigned_profile_id)
  where cashbox_type = 'operator_custody' and status = 'active';

-- هل الملف مشغلًا نشطًا في هذا البئر؟ مساعد قراءة داخلي (definer).
create or replace function finance.is_active_operator_assignment(
  p_well_id uuid,
  p_profile_id uuid
)
returns boolean
language sql
stable
security definer
set search_path to 'finance', 'core', 'pg_temp'
as $$
  select exists (
    select 1 from core.well_assignments wa
    where wa.well_id = p_well_id
      and wa.profile_id = p_profile_id
      and wa.role = 'operator'
      and wa.status = 'active'
  );
$$;

-- رصيد صندوق من القيود المرحلة/المعكوسة معًا — نفس دلالة
-- reporting.cashbox_balances (061) لكن داخلية definer تصلح للقارئات
-- ذات الامتياز الأدنى. اشتقاق من دفتر الحسابات، لا عمود رصيد يدوي.
create or replace function finance.cashbox_balance_minor(p_cashbox_id uuid)
returns bigint
language sql
stable
security definer
set search_path to 'finance', 'pg_temp'
as $$
  select coalesce(sum(
    case when l.entry_side = 'debit' then l.amount_minor else -l.amount_minor end
  ), 0)::bigint
  from finance.journal_lines l
  join finance.journal_entries e on e.id = l.journal_entry_id
  where l.cashbox_id = p_cashbox_id
    and e.status in ('posted', 'reversed');
$$;

-- ضمان صندوق حيازة واحد للمشغل في البئر: مساعد داخلي (ليس RPC تطبيقيًا).
create or replace function finance.ensure_operator_custody_cashbox(
  p_well_id uuid,
  p_profile_id uuid
)
returns uuid
language plpgsql
volatile
security definer
set search_path to 'finance', 'core', 'iam', 'pg_temp'
as $$
declare
  v_tenant_id uuid;
  v_cashbox_id uuid;
  v_name text;
begin
  select w.tenant_id into v_tenant_id from core.wells w where w.id = p_well_id;
  if v_tenant_id is null then
    raise exception 'البئر غير موجود: %', p_well_id;
  end if;
  if not finance.is_active_operator_assignment(p_well_id, p_profile_id) then
    raise exception 'لا يوجد تعيين مشغل نشط للملف % في البئر %', p_profile_id, p_well_id;
  end if;

  select c.id into v_cashbox_id
  from finance.cashboxes c
  where c.well_id = p_well_id
    and c.assigned_profile_id = p_profile_id
    and c.cashbox_type = 'operator_custody'
    and c.status = 'active'
  limit 1;
  if v_cashbox_id is not null then
    return v_cashbox_id;
  end if;

  select 'حيازة نقد المشغل ' || p.full_name into v_name
  from iam.profiles p
  where p.id = p_profile_id;

  begin
    insert into finance.cashboxes (
      tenant_id, well_id, name, cashbox_type, assigned_profile_id
    ) values (
      v_tenant_id, p_well_id, v_name, 'operator_custody', p_profile_id
    ) returning id into v_cashbox_id;
  exception when unique_violation then
    -- نداء متوازٍ سبقنا: الصندوق موجود بالفعل، نعيد قراءته ولا نكرر.
    select c.id into v_cashbox_id
    from finance.cashboxes c
    where c.well_id = p_well_id
      and c.assigned_profile_id = p_profile_id
      and c.cashbox_type = 'operator_custody'
      and c.status = 'active'
    limit 1;
    if v_cashbox_id is null then
      raise exception 'تعذر ضمان صندوق حيازة المشغل دون تكرار';
    end if;
  end;

  return v_cashbox_id;
end;
$$;

-- ترقية رجعية: صندوق حيازة لكل تعيين مشغل نشط قائم.
-- لا تُنشأ حيازات للمالكين/المديرين لمجرد امتلاكهم صلاحيات مالية.
insert into finance.cashboxes (tenant_id, well_id, name, cashbox_type, assigned_profile_id)
select w.tenant_id, wa.well_id, 'حيازة نقد المشغل ' || p.full_name,
       'operator_custody', wa.profile_id
from core.well_assignments wa
join core.wells w on w.id = wa.well_id
join iam.profiles p on p.id = wa.profile_id
where wa.role = 'operator'
  and wa.status = 'active'
  and not exists (
    select 1 from finance.cashboxes c
    where c.well_id = wa.well_id
      and c.assigned_profile_id = wa.profile_id
      and c.cashbox_type = 'operator_custody'
      and c.status = 'active'
  );

-- ---------------------------------------------------------------------
-- B) صندوق المناوبة: مناوبة المشغل النشط تُفتح على حيازته
-- ---------------------------------------------------------------------

create or replace function ops.open_shift(p_well_id uuid, p_operator_profile_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'ops', 'core', 'finance', 'pg_temp'
as $$
declare
  v_shift_id uuid;
  v_tenant_id uuid;
  v_cashbox_id uuid;
begin
  select tenant_id into v_tenant_id from core.wells where id = p_well_id;
  if v_tenant_id is null then
    raise exception 'البئر % غير موجود', p_well_id;
  end if;

  -- المناوبة تنطلق من الصندوق الحاكم: حيازة المشغل النشط، وإلا صندوق
  -- البئر العام كما كان (مناوبات يفتحها غير المشغل).
  if finance.is_active_operator_assignment(p_well_id, p_operator_profile_id) then
    v_cashbox_id := finance.ensure_operator_custody_cashbox(p_well_id, p_operator_profile_id);
  else
    v_cashbox_id := finance.main_cashbox_id(p_well_id);
  end if;

  insert into ops.shifts (tenant_id, well_id, operator_profile_id, cashbox_id)
  values (v_tenant_id, p_well_id, p_operator_profile_id, v_cashbox_id)
  returning id into v_shift_id;

  -- ربط الجلسات المنقولة المقبولة بالمناوبة الجديدة
  update ops.session_shift_transfers t
  set to_shift_id = v_shift_id
  where t.well_id = p_well_id
    and t.to_profile_id = p_operator_profile_id
    and t.status = 'accepted'
    and t.to_shift_id is null;

  update ops.irrigation_sessions s
  set current_shift_id = v_shift_id
  where s.id in (
    select t.session_id from ops.session_shift_transfers t
    where t.to_shift_id = v_shift_id and t.status = 'accepted'
  );

  perform ops.notify_well_owners(p_well_id, 'shift_opened',
    format('بدات مناوبة جديدة في البئر بواسطة المشغل %s', p_operator_profile_id));

  return v_shift_id;
end;
$$;

-- المناوبات المفتوحة عند الهجرة: تحويل استباقي لصندوق حيازة مشغلها
-- النشط. المناوبات المقفلة التاريخية لا تُعاد كتابتها.
update ops.shifts s
set cashbox_id = c.id
from finance.cashboxes c
where s.status = 'open'
  and c.well_id = s.well_id
  and c.cashbox_type = 'operator_custody'
  and c.assigned_profile_id = s.operator_profile_id
  and c.status = 'active'
  and finance.is_active_operator_assignment(s.well_id, s.operator_profile_id)
  and s.cashbox_id is distinct from c.id;

-- ---------------------------------------------------------------------
-- C) تحصيل نقد المزارع: سلطة الصندوق تتغير وحدها
-- ---------------------------------------------------------------------

create or replace function billing.record_payment(
  p_well_id uuid,
  p_farmer_well_account_id uuid,
  p_amount_minor bigint,
  p_method text,
  p_allocations jsonb default '[]'::jsonb,
  p_session_charge_id uuid default null,
  p_payer_person_id uuid default null,
  p_cashbox_id uuid default null,
  p_paid_at timestamptz default clock_timestamp(),
  p_note text default null,
  p_attachment_url text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'billing', 'finance', 'ops', 'core', 'audit', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_cashbox_id uuid;
  v_payment_id uuid;
  v_advance_payment_id uuid;
  v_payment_amount bigint;
  v_payment_purpose text;
  v_journal_id uuid;
  v_advance_journal_id uuid;
  v_requested_total bigint := 0;
  v_settled_minor bigint := 0;
  v_advance_minor bigint := 0;
  v_item jsonb;
  v_invoice_id uuid;
  v_item_amount bigint;
  v_charge_remaining bigint;
  v_existing_advance_ids uuid[] := '{}'::uuid[];
  v_allocation_summary jsonb := jsonb_build_object(
    'allocated_minor', 0, 'remaining_available_minor', 0, 'allocations', '[]'::jsonb
  );
begin
  -- 1) صلاحية المستخدم والدور.
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل تسجيل الدفعة';
  end if;
  if not iam.has_well_permission(p_well_id, 'payment.create') then
    raise exception 'لا تملك صلاحية تسجيل دفعة لهذا البئر';
  end if;

  -- 2) البئر وحساب المزارع.
  select w.tenant_id into v_tenant_id
  from core.wells w
  where w.id = p_well_id;
  if not found then
    raise exception 'البئر غير موجود: %', p_well_id;
  end if;
  if p_farmer_well_account_id is null then
    raise exception 'حساب المزارع غير موجود أو غير فعال في هذا البئر';
  end if;
  perform 1 from ops.farmer_well_accounts fwa
    where fwa.id = p_farmer_well_account_id
      and fwa.well_id = p_well_id
      and fwa.status = 'active'
  for update;
  if not found then
    raise exception 'حساب المزارع غير موجود أو غير فعال في هذا البئر';
  end if;
  if p_payer_person_id is not null and not exists (
    select 1 from core.persons p
    where p.id = p_payer_person_id and p.tenant_id = v_tenant_id
  ) then
    raise exception 'الشخص الدافع غير موجود في الجهة التابعة لهذا البئر';
  end if;

  -- 3) المبلغ موجب.
  if p_amount_minor is null or p_amount_minor <= 0 then
    raise exception 'مبلغ الدفعة يجب أن يكون أكبر من صفر';
  end if;
  if p_method is null or p_method not in ('cash', 'bank_transfer', 'mobile_wallet', 'fuel_in_kind', 'offset_credit', 'other') then
    raise exception 'طريقة الدفع غير صالحة';
  end if;
  if p_allocations is null or jsonb_typeof(p_allocations) <> 'array' then
    raise exception 'قائمة تخصيص الفواتير يجب أن تكون مصفوفة';
  end if;

  for v_item in select value from jsonb_array_elements(p_allocations)
  loop
    begin
      v_invoice_id := (v_item ->> 'invoice_id')::uuid;
      v_item_amount := (v_item ->> 'amount_minor')::bigint;
    exception when others then
      raise exception 'صيغة تخصيص الفاتورة غير صالحة — يلزم invoice_id و amount_minor صحيحان';
    end;
    if v_invoice_id is null or v_item_amount is null or v_item_amount <= 0 then
      raise exception 'كل تخصيص يحتاج فاتورة ومبلغًا أكبر من صفر';
    end if;
    if not exists (
      select 1 from billing.invoices i
      where i.id = v_invoice_id
        and i.well_id = p_well_id
        and i.farmer_well_account_id = p_farmer_well_account_id
        and i.status in ('issued', 'partially_paid', 'overdue')
    ) then
      raise exception 'الفاتورة % غير مفتوحة أو لا تخص حساب المزارع المحدد', v_invoice_id;
    end if;
    v_requested_total := v_requested_total + v_item_amount;
  end loop;

  -- 4) الصندوق الحاكم عند الدفع النقدي (ق-131 بند 18).
  --    المشغل النشط: نقد المزارع يدخل حيازته حصرًا — تمرير معرف صندوق
  --    آخر (وفيه صندوق البئر العام) يُرفض، فلا يرسل المشغل نقدًا إلى
  --    main_well عبر المعامل. سلوك غير المشغل وغير النقدي كما كان.
  if p_method = 'cash'
     and finance.is_active_operator_assignment(p_well_id, v_actor) then
    if p_cashbox_id is not null
       and p_cashbox_id is distinct from finance.ensure_operator_custody_cashbox(p_well_id, v_actor) then
      raise exception 'لا يجوز للمشغل توجيه نقد المزارع إلى صندوق آخر: التحصيل النقدي يدخل حيازة المشغل لهذا البئر إلزامًا';
    end if;
    v_cashbox_id := finance.ensure_operator_custody_cashbox(p_well_id, v_actor);
  else
    v_cashbox_id := coalesce(p_cashbox_id, finance.main_cashbox_id(p_well_id));
  end if;
  if p_method = 'cash' and not exists (
    select 1 from finance.cashboxes c
    where c.id = v_cashbox_id and c.well_id = p_well_id and c.status = 'active'
  ) then
    raise exception 'الصندوق النقدي غير موجود أو غير فعال لهذا البئر';
  end if;

  if p_session_charge_id is not null then
    select coalesce(array_agg(p.id), '{}'::uuid[])
    into v_existing_advance_ids
    from billing.payments p
    where p.farmer_well_account_id = p_farmer_well_account_id
      and p.well_id = p_well_id
      and p.purpose = 'advance';

    select sc.amount_minor - coalesce((
      select sum(p.amount_minor)
      from billing.payments p
      where p.session_charge_id = sc.id and p.status <> 'reversed'
    ), 0)
    into v_charge_remaining
    from billing.session_charges sc
    join ops.irrigation_sessions s on s.id = sc.session_id
    where sc.id = p_session_charge_id
      and sc.well_id = p_well_id
      and s.farmer_well_account_id = p_farmer_well_account_id
    for update of sc;

    if not found then
      raise exception 'تكلفة الجلسة غير موجودة أو لا تخص حساب المزارع المحدد';
    end if;
    v_charge_remaining := greatest(v_charge_remaining, 0);
    if jsonb_array_length(p_allocations) > 0
       and v_requested_total <> least(p_amount_minor, v_charge_remaining) then
      raise exception 'مجموع الفواتير المختارة % يجب أن يساوي الجزء المسدد من المستحق %',
        v_requested_total, least(p_amount_minor, v_charge_remaining);
    end if;

    -- 5) إنشاء الدفعة العادية؛ الزناد يقسم أي زيادة إلى رصيد مقدم
    --    ويرث الصندوق الحاكم نفسه — فتتغير الحيازة بمبلغ الاستلام
    --    كاملًا مرة واحدة لا مرتين.
    insert into billing.payments (
      tenant_id, well_id, session_charge_id, farmer_well_account_id,
      payer_person_id, cashbox_id, collected_by_profile_id,
      received_by_profile_id, amount_minor, method, paid_at,
      purpose, status, note, attachment_url
    ) values (
      v_tenant_id, p_well_id, p_session_charge_id, p_farmer_well_account_id,
      p_payer_person_id, v_cashbox_id, v_actor,
      v_actor, p_amount_minor, p_method, p_paid_at,
      'session', 'posted', p_note, p_attachment_url
    )
    returning id, amount_minor, purpose
    into v_payment_id, v_payment_amount, v_payment_purpose;

    select p.journal_entry_id into v_journal_id
    from billing.payments p where p.id = v_payment_id;

    if v_payment_purpose = 'advance' then
      v_settled_minor := 0;
      v_advance_minor := v_payment_amount;
      v_advance_payment_id := v_payment_id;
      v_advance_journal_id := v_journal_id;
    else
      v_settled_minor := v_payment_amount;
      v_advance_minor := p_amount_minor - v_payment_amount;
    end if;

    -- 6-8) تخصيص الفواتير المختارة مع حارسي قيمة الدفعة والدين.
    if jsonb_array_length(p_allocations) > 0 then
      v_allocation_summary := billing.allocate_payment(v_payment_id, p_allocations);
    end if;

    -- 9) التحقق من الرصيد المقدم الذي أنشأه الزناد.
    if v_advance_minor > 0 and v_advance_payment_id is null then
      select p.id, p.journal_entry_id
      into v_advance_payment_id, v_advance_journal_id
      from billing.payments p
      where p.farmer_well_account_id = p_farmer_well_account_id
        and p.well_id = p_well_id
        and p.purpose = 'advance'
        and p.amount_minor = v_advance_minor
        and not (p.id = any(v_existing_advance_ids))
        and p.note like 'رصيد مقدم تلقائي:%'
      order by p.created_at desc, p.id desc
      limit 1;
      if not found then
        raise exception 'فشل التحقق من تحويل زيادة الدفعة إلى رصيد مقدم';
      end if;
    end if;
  else
    -- التحصيل العام يخصص المبلغ المختار، وما بقي يسجل رصيدًا مقدمًا.
    if v_requested_total > p_amount_minor then
      raise exception 'إجمالي تخصيص الفواتير % يتجاوز مبلغ الدفعة %',
        v_requested_total, p_amount_minor;
    end if;

    v_settled_minor := v_requested_total;
    v_advance_minor := p_amount_minor - v_settled_minor;

    if v_settled_minor > 0 then
      insert into billing.payments (
        tenant_id, well_id, farmer_well_account_id, payer_person_id,
        cashbox_id, collected_by_profile_id, received_by_profile_id,
        amount_minor, method, paid_at, purpose, status, note, attachment_url
      ) values (
        v_tenant_id, p_well_id, p_farmer_well_account_id, p_payer_person_id,
        v_cashbox_id, v_actor, v_actor,
        v_settled_minor, p_method, p_paid_at, 'old_debt', 'posted', p_note, p_attachment_url
      )
      returning id into v_payment_id;

      select p.journal_entry_id into v_journal_id
      from billing.payments p where p.id = v_payment_id;

      v_allocation_summary := billing.allocate_payment(v_payment_id, p_allocations);
    end if;

    if v_advance_minor > 0 then
      insert into billing.payments (
        tenant_id, well_id, farmer_well_account_id, payer_person_id,
        cashbox_id, collected_by_profile_id, received_by_profile_id,
        amount_minor, method, paid_at, purpose, status, note, attachment_url
      ) values (
        v_tenant_id, p_well_id, p_farmer_well_account_id, p_payer_person_id,
        v_cashbox_id, v_actor, v_actor,
        v_advance_minor, p_method, p_paid_at, 'advance', 'posted',
        coalesce(p_note || ' | ', '') || 'المتبقي بعد تخصيص الفواتير رصيد مقدم',
        p_attachment_url
      )
      returning id into v_advance_payment_id;

      select p.journal_entry_id into v_advance_journal_id
      from billing.payments p where p.id = v_advance_payment_id;

      if v_payment_id is null then
        v_payment_id := v_advance_payment_id;
        v_journal_id := v_advance_journal_id;
      end if;
    end if;
  end if;

  -- 10) التحقق من أن القيود المالية أنشئت ورحلت.
  if v_journal_id is null or not exists (
    select 1 from finance.journal_entries je
    where je.id = v_journal_id and je.status = 'posted'
  ) then
    raise exception 'فشل إنشاء القيد المالي المرحل للدفعة';
  end if;
  if v_advance_minor > 0 and (
    v_advance_journal_id is null or not exists (
      select 1 from finance.journal_entries je
      where je.id = v_advance_journal_id and je.status = 'posted'
    )
  ) then
    raise exception 'فشل إنشاء القيد المالي المرحل للرصيد المقدم';
  end if;

  -- 11) حالات الفواتير حدثها إجراء التخصيص؛ نتحقق من سلامة الأرصدة.
  if exists (
    select 1 from billing.invoices i
    where i.id in (
      select (x ->> 'invoice_id')::uuid from jsonb_array_elements(p_allocations) x
    ) and (i.paid_minor + i.outstanding_minor <> i.total_minor
           or i.outstanding_minor < 0)
  ) then
    raise exception 'فشل التحقق النهائي من أرصدة الفواتير بعد الدفعة';
  end if;

  -- 12) سجل التدقيق.
  perform audit.log(
    v_tenant_id, p_well_id, 'record_payment', 'billing.payments', v_payment_id,
    null,
    jsonb_build_object(
      'payment_id', v_payment_id,
      'settled_minor', v_settled_minor,
      'advance_minor', v_advance_minor,
      'advance_payment_id', v_advance_payment_id,
      'journal_entry_id', v_journal_id,
      'advance_journal_entry_id', v_advance_journal_id
    ),
    'تسجيل دفعة وتوزيعها'
  );

  -- 13) الإيصال جزء من الملخص النهائي ويحمل رقم السند ووقته ومكوناته.
  return jsonb_build_object(
    'payment_id', v_payment_id,
    'settled_minor', v_settled_minor,
    'advance_minor', v_advance_minor,
    'journal_entry_id', v_journal_id,
    'advance_payment_id', v_advance_payment_id,
    'advance_journal_entry_id', v_advance_journal_id,
    'allocation', v_allocation_summary,
    'receipt', jsonb_build_object(
      'payment_id', v_payment_id,
      'public_code', (select p.public_code from billing.payments p where p.id = v_payment_id),
      'paid_at', p_paid_at,
      'amount_minor', p_amount_minor,
      'method', p_method,
      'payer_person_id', p_payer_person_id
    )
  );
end;
$function$;

-- تعبئة سياق الدفعة دفاعيًا: إدخال داخلي بنقد وجامع مشغل نشط وبلا
-- صندوق يُحل إلى حيازة المشغل لا إلى صندوق البئر. بقية السلوك كما هو.
create or replace function billing.fill_payment_context()
returns trigger
language plpgsql
security definer
set search_path to 'billing', 'ops', 'finance', 'core', 'pg_temp'
as $$
declare
  v_well_id uuid;
begin
  if new.well_id is null then
    if new.session_charge_id is not null then
      select sc.well_id into v_well_id from billing.session_charges sc where sc.id = new.session_charge_id;
    elsif new.farmer_well_account_id is not null then
      select fwa.well_id into v_well_id from ops.farmer_well_accounts fwa where fwa.id = new.farmer_well_account_id;
    end if;
    new.well_id := v_well_id;
  end if;

  if new.tenant_id is null and new.well_id is not null then
    select w.tenant_id into new.tenant_id from core.wells w where w.id = new.well_id;
  end if;

  if new.shift_id is null and new.well_id is not null then
    select s.id into new.shift_id from ops.shifts s
    where s.well_id = new.well_id and s.status = 'open' limit 1;
  end if;

  if new.collected_by_profile_id is null and new.shift_id is not null then
    select s.operator_profile_id into new.collected_by_profile_id from ops.shifts s where s.id = new.shift_id;
  end if;

  new.collected_by_profile_id := coalesce(new.collected_by_profile_id, new.received_by_profile_id);
  new.received_by_profile_id := coalesce(new.received_by_profile_id, new.collected_by_profile_id);

  if new.cashbox_id is null and new.well_id is not null then
    if new.method = 'cash'
       and new.collected_by_profile_id is not null
       and finance.is_active_operator_assignment(new.well_id, new.collected_by_profile_id) then
      new.cashbox_id := finance.ensure_operator_custody_cashbox(new.well_id, new.collected_by_profile_id);
    else
      new.cashbox_id := finance.main_cashbox_id(new.well_id);
    end if;
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- D) المصروفات من الحيازة: مصروف البئر يبقى مصروف البئر
-- ---------------------------------------------------------------------

-- ترتيب الحل الآمن: الجهة ← المناوبة المفتوحة ← المنشئ ← الصندوق.
-- المشغل النشط الذي يدفع فعليًا من 'cashbox' يدفع من حيازته فتُخفض
-- حيازته (دائن 1000 بصندوق الحيازة في journalize_expense دون تغيير)،
-- وغير ذلك من مصادر الدفع لا يمس الحيازة مجرد أن مشغلًا سجّله.
create or replace function finance.fill_expense_context()
returns trigger
language plpgsql
security definer
set search_path to 'finance', 'ops', 'core', 'pg_temp'
as $$
begin
  if new.tenant_id is null then
    select w.tenant_id into new.tenant_id from core.wells w where w.id = new.well_id;
  end if;

  if new.shift_id is null then
    select s.id into new.shift_id from ops.shifts s
    where s.well_id = new.well_id and s.status = 'open' limit 1;
  end if;

  if new.created_by is null and new.shift_id is not null then
    select s.operator_profile_id into new.created_by from ops.shifts s where s.id = new.shift_id;
  end if;

  if new.cashbox_id is null and new.payment_source = 'cashbox' then
    if new.created_by is not null
       and finance.is_active_operator_assignment(new.well_id, new.created_by) then
      new.cashbox_id := finance.ensure_operator_custody_cashbox(new.well_id, new.created_by);
    else
      new.cashbox_id := finance.main_cashbox_id(new.well_id);
    end if;
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- E) الترحيل الصريح: امتداد ops.shift_handovers بلا جدول موازٍ
-- ---------------------------------------------------------------------

alter table ops.shift_handovers
  add column handover_kind text not null default 'person',
  add column from_cashbox_id uuid references finance.cashboxes(id),
  add column to_cashbox_id uuid references finance.cashboxes(id),
  add column journal_entry_id uuid references finance.journal_entries(id);

-- الصفوف التاريخية القائمة 'person' بالافتراضي ولا تصير ترحيل بئر صمتًا.
alter table ops.shift_handovers
  add constraint shift_handovers_kind_check
  check (handover_kind in ('person', 'operator_cash_remittance'));

-- إقرار المشغل بترحيل نقد حيازته إلى صندوق البئر العام.
-- إقرار فقط: لا قيد عند الإقرار، والتأكيد للمالك، والفرق يعلق.
create or replace function ops.declare_operator_cash_remittance(
  p_shift_id uuid,
  p_amount_minor bigint,
  p_note text default null
)
returns uuid
language plpgsql
volatile
security definer
set search_path to 'ops', 'core', 'finance', 'pg_temp'
as $$
declare
  v_shift ops.shifts%rowtype;
  v_main_cashbox uuid;
  v_balance bigint;
  v_id uuid;
begin
  if p_amount_minor is null or p_amount_minor <= 0 then
    raise exception 'مبلغ الترحيل يجب أن يكون أكبر من صفر';
  end if;

  select * into v_shift from ops.shifts where id = p_shift_id;
  if v_shift.id is null then
    raise exception 'المناوبة % غير موجودة', p_shift_id;
  end if;

  if v_shift.cashbox_id is null or not exists (
    select 1 from finance.cashboxes c
    where c.id = v_shift.cashbox_id
      and c.cashbox_type = 'operator_custody'
      and c.status = 'active'
      and c.assigned_profile_id = v_shift.operator_profile_id
  ) then
    raise exception 'المناوبة % غير مدعومة بصندوق حيازة المشغل المخصص له نفسه — لا ترحيل', p_shift_id;
  end if;

  v_main_cashbox := finance.main_cashbox_id(v_shift.well_id);
  if v_main_cashbox is null or not exists (
    select 1 from finance.cashboxes c
    where c.id = v_main_cashbox and c.well_id = v_shift.well_id and c.status = 'active'
  ) then
    raise exception 'صندوق البئر العام غير موجود أو غير فعال — لا وجهة للترحيل';
  end if;

  select finance.cashbox_balance_minor(v_shift.cashbox_id) into v_balance;
  if v_balance < p_amount_minor then
    raise exception 'مبلغ الترحيل % يتجاوز حيازة المشغل الحالية % — لا يُقرَّر ترحيل فوق المتوفر', p_amount_minor, v_balance;
  end if;

  insert into ops.shift_handovers (
    tenant_id, well_id, shift_id, from_profile_id,
    to_description, declared_amount_minor, note,
    handover_kind, from_cashbox_id, to_cashbox_id
  ) values (
    v_shift.tenant_id, v_shift.well_id, v_shift.id, v_shift.operator_profile_id,
    'ترحيل إلى صندوق البئر العام', p_amount_minor, p_note,
    'operator_cash_remittance', v_shift.cashbox_id, v_main_cashbox
  ) returning id into v_id;

  perform ops.notify_well_owners(v_shift.well_id, 'handover_declared',
    format('أقر المشغل بترحيل مبلغ %s ريال من حيازته إلى صندوق البئر - بانتظار تأكيدك', p_amount_minor));

  return v_id;
end;
$$;

-- غلاف التطبيق: invoker، ومصادقة إلزامية، والإقرار لمشغل المناوبة وحده.
create or replace function api.declare_operator_cash_remittance(
  p_shift_id uuid,
  p_amount_minor bigint,
  p_note text default null
)
returns uuid
language plpgsql
volatile
security invoker
set search_path to 'pg_catalog', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_well_id uuid;
  v_operator_profile_id uuid;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إقرار ترحيل الحيازة';
  end if;

  select s.well_id, s.operator_profile_id
  into v_well_id, v_operator_profile_id
  from ops.shifts s
  where s.id = p_shift_id;
  if v_well_id is null then
    raise exception 'المناوبة % غير موجودة', p_shift_id;
  end if;
  if v_operator_profile_id is distinct from v_actor then
    raise exception 'إقرار ترحيل الحيازة يصدر عن مشغل المناوبة وحده';
  end if;

  return ops.declare_operator_cash_remittance(p_shift_id, p_amount_minor, p_note);
end;
$function$;

revoke all on function api.declare_operator_cash_remittance(uuid, bigint, text)
from public, anon, authenticated, service_role;
grant execute on function api.declare_operator_cash_remittance(uuid, bigint, text)
to authenticated, service_role;

revoke all on function ops.declare_operator_cash_remittance(uuid, bigint, text)
from public, anon;
grant execute on function ops.declare_operator_cash_remittance(uuid, bigint, text)
to authenticated, service_role;

-- ---------------------------------------------------------------------
-- F) التأكيد والنقل المحاسبي: قيد موقع نقدي ← نقدي لا أكثر
-- ---------------------------------------------------------------------

create or replace function ops.confirm_handover(
  p_handover_id uuid,
  p_confirmed_amount_minor bigint,
  p_confirmed_by uuid,
  p_difference_reason text default null
)
returns text
language plpgsql
security definer
set search_path to 'ops', 'finance', 'core', 'pg_temp'
as $$
declare
  v_h ops.shift_handovers%rowtype;
  v_src finance.cashboxes%rowtype;
  v_diff bigint;
  v_je uuid;
  v_amount bigint;
begin
  select * into v_h from ops.shift_handovers where id = p_handover_id for update;
  if v_h.id is null then
    raise exception 'اقرار التسليم % غير موجود', p_handover_id;
  end if;
  if v_h.status in ('confirmed', 'settled') then
    raise exception 'اقرار التسليم % مؤكد مسبقا', p_handover_id;
  end if;

  v_diff := p_confirmed_amount_minor - v_h.declared_amount_minor;

  -- ═══ ترحيل حيازة المشغل: مطابقة تامة = قيد نقل واحد وتكراره مستحيل ═══
  --    مدين 1000 لصندوق البئر العام / دائن 1000 لحيازة المشغل —
  --    بلا إيراد ولا ذمم ولا مقدم ولا مصروف، والنقد الكلي للبئر
  --    لا يتغير. (unique(well_id, source_type, source_id) في 036
  --    ومفتاح idempotency ثانٍ يمنعان قيدًا ثانيًا حتى لو حُاول.)
  if v_h.handover_kind = 'operator_cash_remittance' and v_diff = 0 then
    if v_h.from_cashbox_id is null or v_h.to_cashbox_id is null then
      raise exception 'اقرار الترحيل % بلا صندوق مصدر أو وجهة — لا قيد نقلي', p_handover_id;
    end if;

    -- نقطة التسلسل: قفل صف صندوق الحيازة المصدر قبل أي قراءة رصيد.
    -- كل تأكيدات الترحيل على الصندوق نفسه تتصالح على هذا الصف الواحد؛
    -- فالمتأخر في القفل يرى بعد انتظاره الترحيل المرحّل سلفًا في
    -- رصيده — فلا حيازة سالبة ولا قيد مزدوج تحت التزامن.
    select * into v_src
    from finance.cashboxes c
    where c.id = v_h.from_cashbox_id
      and c.well_id = v_h.well_id
      and c.cashbox_type = 'operator_custody'
      and c.status = 'active'
      and c.assigned_profile_id = v_h.from_profile_id
    for update;
    if not found then
      raise exception 'صندوق حيازة المصدر غير صالح للاقرار %: يلزم حيازة نشطة للملف المرسل في البئر نفسه', p_handover_id;
    end if;

    -- الوجهة: صندوق البئر العام في البئر نفسه وفعّال.
    if not exists (
      select 1 from finance.cashboxes c
      where c.id = v_h.to_cashbox_id
        and c.well_id = v_h.well_id
        and c.cashbox_type = 'main_well'
        and c.status = 'active'
    ) then
      raise exception 'صناديق الترحيل غير صالحة: المصدر حيازة المشغل والوجهة صندوق البئر العام في البئر نفسه';
    end if;

    -- قراءة الرصيد بعد اكتساب قفل المصدر حصرًا.
    if finance.cashbox_balance_minor(v_h.from_cashbox_id) < v_h.declared_amount_minor then
      raise exception 'حيازة المشغل الحالية أقل من مبلغ الترحيل % — لا قيد نقلي', v_h.declared_amount_minor;
    end if;

    v_amount := v_h.declared_amount_minor;
    v_je := gen_random_uuid();

    insert into finance.journal_entries (
      id, tenant_id, public_code, well_id, entry_date,
      source_type, source_id, description, idempotency_key
    ) values (
      v_je, v_h.tenant_id, core.generate_public_code('JE'), v_h.well_id,
      clock_timestamp(), 'operator_cash_remittance', v_h.id,
      'ترحيل حيازة المشغل النقدية إلى صندوق البئر — نقل حيازة لا إيراد',
      'CUSTODY-REMIT-' || v_h.id::text
    );

    insert into finance.journal_lines (
      tenant_id, journal_entry_id, ledger_account_id, entry_side,
      amount_minor, cashbox_id, description
    ) values
      (v_h.tenant_id, v_je, finance.ledger_account_id(v_h.well_id, '1000'), 'debit',
       v_amount, v_h.to_cashbox_id, 'استلام صندوق البئر العام من حيازة المشغل'),
      (v_h.tenant_id, v_je, finance.ledger_account_id(v_h.well_id, '1000'), 'credit',
       v_amount, v_h.from_cashbox_id, 'خروج نقد حيازة المشغل إلى صندوق البئر العام');

    perform finance.post_journal_entry(v_je, p_confirmed_by);

    update ops.shift_handovers
    set confirmed_amount_minor = p_confirmed_amount_minor, difference_minor = 0,
        status = 'confirmed', confirmed_by = p_confirmed_by, confirmed_at = now(),
        journal_entry_id = v_je
    where id = p_handover_id;

    perform ops.notify_profile(v_h.from_profile_id, v_h.well_id, 'handover_confirmed',
      format('تم تأكيد ترحيل %s ريال من حيازتك إلى صندوق البئر، ورفعت المسؤولية', p_confirmed_amount_minor));
    return 'confirmed';
  end if;

  -- ═══ التسليم العادي/الشخصي: سلوكه القائم كما هو حرفيًا ═══
  if v_diff = 0 then
    update ops.shift_handovers
    set confirmed_amount_minor = p_confirmed_amount_minor, difference_minor = 0,
        status = 'confirmed', confirmed_by = p_confirmed_by, confirmed_at = now()
    where id = p_handover_id;

    perform ops.notify_profile(v_h.from_profile_id, v_h.well_id, 'handover_confirmed',
      format('تم تاكيد استلام مبلغ %s ريال منك، ورفعت المسؤولية', p_confirmed_amount_minor));
    return 'confirmed';
  end if;

  if p_difference_reason is null then
    raise exception 'يوجد فرق % ريال بين المبلغ المقر والمبلغ المؤكد، وذكر السبب الزامي', v_diff;
  end if;

  -- ترحيل بفرق: يعلق difference_pending ولا يُرحَّل نقديًا صمتًا ولا
  -- يُخترع محاسبة عجز/زيادة — حسمه عقد مالي مخصص (رسالة settle أدناه).
  update ops.shift_handovers
  set confirmed_amount_minor = p_confirmed_amount_minor, difference_minor = v_diff,
      difference_reason = p_difference_reason, status = 'difference_pending',
      confirmed_by = p_confirmed_by, confirmed_at = now()
  where id = p_handover_id;

  perform ops.notify_well_owners(v_h.well_id, 'handover_difference',
    format('فرق في التسليم: المقر %s ريال والمؤكد %s ريال (الفرق %s) - السبب: %s',
      v_h.declared_amount_minor, p_confirmed_amount_minor, v_diff, p_difference_reason));
  perform ops.notify_profile(v_h.from_profile_id, v_h.well_id, 'handover_difference',
    format('يوجد فرق %s ريال في تسليمك، معلق حتى حسم المالك', v_diff));

  return 'difference_pending';
end;
$$;

create or replace function ops.settle_handover(p_handover_id uuid, p_settled_by uuid)
returns text
language plpgsql
security definer
set search_path to 'ops', 'pg_temp'
as $$
declare
  v_h record;
begin
  select * into v_h from ops.shift_handovers where id = p_handover_id;
  if v_h.id is null then
    raise exception 'اقرار التسليم % غير موجود', p_handover_id;
  end if;
  if v_h.status <> 'difference_pending' then
    raise exception 'لا يوجد فرق معلق في الاقرار % (الحالة %)', p_handover_id, v_h.status;
  end if;
  -- الترتيب المقصود: «لا فرق معلق» أولًا بسلوكه العادي، ثم رفض ترحيل
  -- الحيازة بعقد التسوية المالية المخصص — فترحيل مؤكد مطابقًا يحصل
  -- على رسالة «لا فرق معلق» لا رسالة العقد المضللة.
  if v_h.handover_kind = 'operator_cash_remittance' then
    raise exception 'فرق ترحيل حيازة المشغل في الاقرار % لا يُحسم بلا عقد تسوية مالية مخصص — لا يُفترض اختفاؤه ولا يُخترع محاسبة للعجز', p_handover_id;
  end if;

  update ops.shift_handovers
  set status = 'settled', confirmed_by = p_settled_by, confirmed_at = now()
  where id = p_handover_id;

  perform ops.notify_profile(v_h.from_profile_id, v_h.well_id, 'handover_settled',
    'تم حسم فرق التسليم من المالك، ورفعت المسؤولية عنك');

  return 'settled';
end;
$$;

-- ---------------------------------------------------------------------
-- G) حقيقة القراءة: الحيازة من دفتر الحسابات لا من طرح معلوماتي
-- ---------------------------------------------------------------------

-- unsettled_minor التاريخي (محصل - مصروفات - مُسلَّم) لم يعد حاكمًا
-- لأنه يخصم مصروفات قد تكون من مصدر آخر. الحيازة = رصيد صناديق
-- الحيازة من القيود، وتُعاد في unsettled_minor توافقًا وفي
-- custody_minor صراحة. بقية الأرقام معلوماتية كما هي.
create or replace function ops.operator_totals(p_profile_id uuid, p_well_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'ops', 'billing', 'finance', 'pg_temp'
as $$
declare
  v_collected bigint;
  v_expenses bigint;
  v_handed bigint;
  v_debt bigint;
  v_shifts integer;
  v_custody bigint;
begin
  select count(*) into v_shifts from ops.shifts s
  where s.operator_profile_id = p_profile_id
    and (p_well_id is null or s.well_id = p_well_id);

  select coalesce(sum(p.amount_minor), 0) into v_collected
  from billing.payments p
  join ops.shifts s on s.id = p.shift_id
  where s.operator_profile_id = p_profile_id
    and (p_well_id is null or s.well_id = p_well_id)
    and p.status <> 'reversed';

  select coalesce(sum(e.amount_minor), 0) into v_expenses
  from finance.expenses e
  join ops.shifts s on s.id = e.shift_id
  where s.operator_profile_id = p_profile_id
    and (p_well_id is null or s.well_id = p_well_id)
    and e.status in ('posted', 'approved');

  select coalesce(sum(coalesce(h.confirmed_amount_minor, h.declared_amount_minor)), 0) into v_handed
  from ops.shift_handovers h
  where h.from_profile_id = p_profile_id
    and (p_well_id is null or h.well_id = p_well_id)
    and h.status in ('confirmed', 'settled');

  select coalesce(sum(sc.amount_minor), 0) - coalesce((
    select sum(p.amount_minor) from billing.payments p
    where p.session_charge_id in (
      select sc2.id from billing.session_charges sc2
      join ops.irrigation_sessions s2 on s2.id = sc2.session_id
      where s2.collector_profile_id = p_profile_id
        and (p_well_id is null or s2.well_id = p_well_id)
    ) and p.status <> 'reversed'
  ), 0)
  into v_debt
  from billing.session_charges sc
  join ops.irrigation_sessions s on s.id = sc.session_id
  where s.collector_profile_id = p_profile_id
    and (p_well_id is null or s.well_id = p_well_id);

  select coalesce(sum(finance.cashbox_balance_minor(c.id)), 0) into v_custody
  from finance.cashboxes c
  where c.cashbox_type = 'operator_custody'
    and c.status = 'active'
    and c.assigned_profile_id = p_profile_id
    and (p_well_id is null or c.well_id = p_well_id);

  return jsonb_build_object(
    'profile_id', p_profile_id,
    'shifts_count', v_shifts,
    'collected_minor', v_collected,
    'expenses_minor', v_expenses,
    'handed_over_minor', v_handed,
    'farmer_debt_minor', greatest(v_debt, 0),
    'unsettled_minor', v_custody,
    'custody_minor', v_custody
  );
end;
$$;

-- عقد قراءة حيازة المشغل: حقيقي من الدفتر، وموسوم دلاليًا بأنه مال
-- البئر في حيازته لا ماله الشخصي. قراءة حرة من آثار جانبية للإنشاء.
create or replace function api.get_my_operator_cash_custody(p_well_id uuid)
returns jsonb
language plpgsql
stable
security invoker
set search_path to 'pg_catalog', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_box record;
  v_balance bigint;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة حيازة النقد';
  end if;
  if not finance.is_active_operator_assignment(p_well_id, v_actor) then
    raise exception 'لا يوجد تعيين مشغل نشط لك في هذا البئر';
  end if;

  select c.id, c.public_code, c.name
  into v_box
  from finance.cashboxes c
  where c.well_id = p_well_id
    and c.assigned_profile_id = v_actor
    and c.cashbox_type = 'operator_custody'
    and c.status = 'active'
  limit 1;
  if v_box.id is null then
    raise exception 'لا يوجد صندوق حيازة نشط لك في هذا البئر بعد — ينشأ مع أول مناوبة أو تحصيل نقدي';
  end if;

  select finance.cashbox_balance_minor(v_box.id) into v_balance;

  return jsonb_build_object(
    'well_id', p_well_id,
    'profile_id', v_actor,
    'cashbox_id', v_box.id,
    'cashbox_public_code', v_box.public_code,
    'cashbox_name', v_box.name,
    'balance_minor', v_balance,
    'is_well_money_in_operator_custody', true,
    'semantics', 'مال البئر/العمل في حيازة المشغل لهذا البئر — ليس محفظة شخصية، والترحيل نقل حيازة لا إيراد'
  );
end;
$function$;

revoke all on function api.get_my_operator_cash_custody(uuid)
from public, anon, authenticated, service_role;
grant execute on function api.get_my_operator_cash_custody(uuid)
to authenticated, service_role;

-- مساعدات داخلية تستدعيها العقود الـinvoker بحساب المصادَق:
-- منح محكومة لمصادَق فقط، ولا public ولا anon.
revoke all on function finance.is_active_operator_assignment(uuid, uuid)
from public, anon;
grant execute on function finance.is_active_operator_assignment(uuid, uuid)
to authenticated, service_role;

revoke all on function finance.cashbox_balance_minor(uuid)
from public, anon;
grant execute on function finance.cashbox_balance_minor(uuid)
to authenticated, service_role;

-- مساعد ضمان الحيازة داخلي حصرًا (يستدعيه definer دائمًا):
revoke all on function finance.ensure_operator_custody_cashbox(uuid, uuid)
from public, anon, authenticated, service_role;

commit;
