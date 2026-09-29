-- =====================================================================
-- Migration 111 — إثباتات المصروفات: مرفق صريح أو سبب تخطٍ صريح
-- (ق-131 البند 13 / م-45 مرحلة A)
--
-- العقد الحاكم:
--   1. المصروف تدفق مالي قابل للتدقيق: مبلغ، فئة، بيان، مصدر دفع،
--      وشريك عند partner_paid، ومرفق حين يوفر — أو سبب صريح حين
--      يُتخطى عمدًا.
--   2. `finance.expenses.attachment_skip_reason` قائم وهو الحاكم:
--      **لا عمود موازٍ ولا اصطلاح ملاحظات** — سبب التخطي لا يُطوى
--      داخل `note` أبدًا، و`note` ملاحظة عمل مستقلة.
--   3. الحالات الإثباتية الصالحة حصرًا (يفرضها قيد الجدول لا Flutter):
--        أ) مرفق: url غير فراغ + skipped=false + سبب فارغ (NULL).
--        ب) تخطٍ: url فراغ + skipped=true + سبب غير فراغ.
--      كل حالة أخرى مرفوضة حتى لو تجاوز المتصل دالة العمل.
--   4. القاعدة الأصغر الحالية الأصرع تبقى: «مرفق أو تخطٍ صريح بسببه» —
--      `expense_categories.attachment_required` لا تُخفِّض العقد بذاتها.
--   5. الدلو خاص، والمرجع المخزَّن مرجع مستقر `storage://...` — روابط
--      التوقيع قيم عرض لحظية لا تُخزَّن كإثبات مالي.
--   6. لا DELETE للعميل: الإثبات المالي المرحَّل لا يصير قابلًا
--      للحذف العابر من التطبيق.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1) قيد جدولي: الحالات الإثباتية الصالحة حصرًا
-- ---------------------------------------------------------------------

-- حارس صريح قبل القيد: صفوف إثبات غير صالحة قائمة (مثل skipped بلا
-- سبب من اصطلاح الطي القديم في Flutter) تسقط الهجرة — ولا تُلفَّق
-- أسباب صمتًا ولا تُمسّ الإثباتات القائمة.
do $$
declare
  v_violations bigint;
begin
  select count(*) into v_violations
  from finance.expenses
  where not (
    (
      coalesce(attachment_url, '') <> ''
      and attachment_skipped = false
      and attachment_skip_reason is null
    )
    or (
      coalesce(attachment_url, '') = ''
      and attachment_skipped = true
      and btrim(coalesce(attachment_skip_reason, '')) <> ''
    )
  );

  if v_violations > 0 then
    raise exception
      'توجد % مصروفات بحالة إثبات غير صالحة (مرفق مع تخطٍ، أو تخطٍ بلا سبب صريح) — يلزم قرار صريح بمعالجتها قبل هذه الهجرة ولا تُستكمل أسبابها صمتًا',
      v_violations;
  end if;
end $$;

alter table finance.expenses
  drop constraint if exists expenses_attachment_check;

alter table finance.expenses
  add constraint expenses_evidence_check
  check (
    (
      coalesce(attachment_url, '') <> ''
      and attachment_skipped = false
      and attachment_skip_reason is null
    )
    or (
      coalesce(attachment_url, '') = ''
      and attachment_skipped = true
      and btrim(coalesce(attachment_skip_reason, '')) <> ''
    )
  );

-- ---------------------------------------------------------------------
-- 2) finance.record_expense — معامل السبب trailing + تحقّق الإثبات
--
-- درس م-056: create or replace بتغيير التوقيع يخلق overload جديد إلى
-- جانب القديم. التوقيع القديم (10 وسائط بلا السبب) يُسقط صراحةً هنا
-- كي يبقى تعريف داخلي واحد حي — والجديد ذو 11 وسيطًا وحده.
-- ---------------------------------------------------------------------

drop function if exists finance.record_expense(
  uuid,
  text,
  bigint,
  text,
  uuid,
  text,
  boolean,
  text,
  text,
  uuid
);

create or replace function finance.record_expense(
  p_well_id uuid,
  p_category_code text,
  p_amount_minor bigint,
  p_description text,
  p_created_by uuid default null,
  p_attachment_url text default null,
  p_attachment_skipped boolean default false,
  p_payment_source text default 'cashbox',
  p_note text default null,
  p_partner_id uuid default null,
  p_attachment_skip_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path to 'finance', 'core', 'ops', 'pg_temp'
as $$
declare
  v_tenant uuid;
  v_cat uuid;
  v_requires boolean := false;
  v_status text;
  v_id uuid;
  v_attachment_url text;
  v_skip_reason text;
  v_skipped boolean;
begin
  select tenant_id into v_tenant from core.wells where id = p_well_id;
  if v_tenant is null then
    raise exception 'البئر % غير موجود', p_well_id;
  end if;

  select id into v_cat from finance.expense_categories
  where tenant_id = v_tenant and code = p_category_code and is_active;
  if v_cat is null then
    raise exception 'نوع المصروف % غير معروف', p_category_code;
  end if;

  -- ═══ تحقّق الإثبات: مرفق صريح أو تخطٍ صريح بسببه — حصريًا ═══
  --    التطبيع: الفراغ والبياض يصيران NULL، ولا يُقبل سبب في
  --    حقل الملاحظات بديلًا (الطي القديم في Flutter ينتهي هنا).
  v_attachment_url := nullif(btrim(coalesce(p_attachment_url, '')), '');
  v_skip_reason := nullif(btrim(coalesce(p_attachment_skip_reason, '')), '');
  v_skipped := coalesce(p_attachment_skipped, false);

  if v_attachment_url is not null and v_skipped then
    raise exception 'لا يجوز إرفاق السند مع تخطي المرفق في الوقت نفسه';
  end if;
  if v_attachment_url is not null and v_skip_reason is not null then
    raise exception 'لا يجوز إرفاق السند مع تدوين سبب تخطٍ';
  end if;
  if v_skip_reason is not null and not v_skipped then
    raise exception 'سبب التخطي بلا تخطٍ صريح — علّم التخطي أو احذف السبب';
  end if;
  if v_skipped and v_skip_reason is null then
    raise exception 'سبب التخطي إلزامي عند تخطي المرفق ولا يقبل فراغًا';
  end if;
  if v_attachment_url is null and not v_skipped then
    raise exception 'إرفاق صورة السند/الفاتورة أو التخطي الصريح بسببه إلزامي';
  end if;

  if p_payment_source = 'partner_paid' and p_partner_id is null then
    raise exception 'مصروف دفعه شريك من جيبه يلزم تحديد الشريك';
  end if;

  select coalesce(bool_or(r.requires_approval), false) into v_requires
  from finance.expense_approval_rules r
  where r.tenant_id = v_tenant
    and (r.well_id is null or r.well_id = p_well_id)
    and (r.category_id is null or r.category_id = v_cat)
    and p_amount_minor >= r.min_amount_minor
    and r.effective_period @> current_date;

  v_status := case when v_requires then 'pending_approval' else 'posted' end;

  insert into finance.expenses (
    tenant_id, well_id, category_id, amount_minor, description, payment_source,
    created_by, attachment_url, attachment_skipped, attachment_skip_reason,
    status, note, partner_id
  ) values (
    v_tenant, p_well_id, v_cat, p_amount_minor, p_description, p_payment_source,
    p_created_by, v_attachment_url, v_skipped, v_skip_reason,
    v_status, p_note, p_partner_id
  ) returning id into v_id;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 3) api.record_expense — توقيع واحد حي، بلا v2 ولا تحميل زائد عرضي
-- ---------------------------------------------------------------------

drop function if exists api.record_expense(
  uuid, text, bigint, text, text, boolean, text, text, uuid
);

create or replace function api.record_expense(
  p_well_id uuid,
  p_category_code text,
  p_amount_minor bigint,
  p_description text,
  p_attachment_url text default null,
  p_attachment_skipped boolean default false,
  p_payment_source text default 'cashbox',
  p_note text default null,
  p_partner_id uuid default null,
  p_attachment_skip_reason text default null
)
returns uuid
language plpgsql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
declare
  v_actor uuid;
begin
  v_actor := auth.uid();

  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل تسجيل مصروف';
  end if;

  if not iam.has_well_permission(
    p_well_id,
    'expense.create'
  ) then
    raise exception 'لا تملك صلاحية تسجيل مصروف في هذا البئر';
  end if;

  return finance.record_expense(
    p_well_id,
    p_category_code,
    p_amount_minor,
    p_description,
    v_actor,
    p_attachment_url,
    p_attachment_skipped,
    p_payment_source,
    p_note,
    p_partner_id,
    p_attachment_skip_reason
  );
end;
$function$;

revoke all on function api.record_expense(
  uuid, text, bigint, text, text, boolean, text, text, uuid, text
) from public, anon, authenticated, service_role;
grant execute on function api.record_expense(
  uuid, text, bigint, text, text, boolean, text, text, uuid, text
) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 4) api.list_expense_categories — الفئات من الخادم لا من ذاكرة Flutter
-- ---------------------------------------------------------------------

create or replace function api.list_expense_categories(p_well_id uuid)
returns jsonb
language plpgsql
stable
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
declare
  v_actor uuid;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة فئات المصروفات';
  end if;
  if not (
    iam.has_well_permission(p_well_id, 'expense.create')
    or iam.has_well_permission(p_well_id, 'expense.approve')
  ) then
    raise exception 'قراءة فئات المصروفات خاصة بمن يملك صلاحية المصروفات في هذا البئر';
  end if;

  return jsonb_build_object(
    'categories',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'code', c.code,
          'name_ar', c.name_ar,
          'attachment_required', c.attachment_required,
          'requires_approval', c.requires_approval,
          'sort_order', c.sort_order
        )
        order by c.sort_order, c.name_ar, c.code
      )
      from finance.expense_categories c
      where c.is_active
        and c.tenant_id = (
          select w.tenant_id from core.wells w where w.id = p_well_id
        )
    ), '[]'::jsonb)
  );
end;
$function$;

revoke all on function api.list_expense_categories(uuid)
from public, anon, authenticated, service_role;
grant execute on function api.list_expense_categories(uuid)
to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 5) تخزين الإثباتات: دلو خاص + سياسات مُسوَّرة بسلطة الصلاحيات
-- ---------------------------------------------------------------------

insert into storage.buckets (id, name, public)
values ('expense-evidence', 'expense-evidence', false)
on conflict (id) do nothing;

-- الدلو خاص حصرًا حتى لو وُجد مسبقًا بحالة أخرى.
update storage.buckets
set public = false
where id = 'expense-evidence';

-- رفع: مصادَق فقط، بمسار <well_id>/<auth_uid>/<ملف>، وصلاحية
-- expense.create على البئر الذي يمثّله المجلد الأول — لا اعتماد على
-- بيانات قابلة للتعديل من العميل.
drop policy if exists ee_insert_well_scoped on storage.objects;
create policy ee_insert_well_scoped on storage.objects
for insert to authenticated
with check (
  bucket_id = 'expense-evidence'
  and exists (
    select 1 from core.wells w
    where w.id::text = (storage.foldername(storage.objects.name))[1]
      and (storage.foldername(storage.objects.name))[2] = auth.uid()::text
      and iam.has_well_permission(w.id, 'expense.create')
  )
);

-- قراءة: من يملك صلاحية المصروفات على بئر المسار (إنشاء أو اعتماد).
drop policy if exists ee_select_well_scoped on storage.objects;
create policy ee_select_well_scoped on storage.objects
for select to authenticated
using (
  bucket_id = 'expense-evidence'
  and exists (
    select 1 from core.wells w
    where w.id::text = (storage.foldername(storage.objects.name))[1]
      and (
        iam.has_well_permission(w.id, 'expense.create')
        or iam.has_well_permission(w.id, 'expense.approve')
      )
  )
);

-- لا سياسات UPDATE ولا DELETE: الإثبات المرحَّل غير قابل للحذف
-- العابر من العميل — وبسقوط السياسات يكون الوصول مرفوضًا افتراضيًا.

commit;
