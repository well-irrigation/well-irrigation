-- 097 — قراءة سندات الرصيد المقدَّم (البند المفتوح من م-41D5)
--
-- المشكلة: زرّ «استخدام الرصيد المقدم» معلَن «غير متاح» في التطبيق منذ
-- م-41D5، لأن عقد `api.get_farmer_account` يعيد الرصيد المقدَّم **رقمًا
-- مُجمَّعًا** (مشتقًّا في عرض 060 كفرق مدفوع − مخصَّص) والسندات بأرقام
-- فواتيرها بلا مبالغ. فلا يُعرف أيّ سند بقي فيه رصيد ولا كم — وأي اختيار
-- سند في العميل قرارٌ ماليّ مُختلَق تمنعه ق-99. والحلّ المسجَّل في
-- `OPEN_ISSUES` حرفيًّا: **عقد يعيد لكل سند معرّفه ورصيده المتبقي**، ثم
-- واجهة يختار فيها الإنسانُ السند والفاتورة والمبلغ، ثم
-- `api.allocate_payment` القائم يستقبل التخصيصات ويتحقق منها خادميًّا.
--
-- أدلة جُمعت قبل الكتابة، وواحدٌ منها **صحّح تصميمًا أولًا**:
-- أ) الوثائق تسجّل أن دفعة المقدَّم «تُكتب ولا تُقرأ» بسبب سياسة 016 التي
--    تشترط ارتباط الدفعة بتكلفة جلسة. **وهذا قديم:** هجرة 085 القسم 1
--    أعادت السياسة بحالتين — دفعة مرتبطة بجلسة، **أو** دفعة بلا جلسة
--    مربوطة بـ`well_id` — للمالك والمشغّل. فأول تشغيل لاختبار هذه الهجرة
--    أسقط الفحص الذي كان يُثبت الحجب، فحُذف التجاوز من التصميم: العقد
--    `SECURITY INVOKER` يقرأ تحت RLS المتصل نفسه، ولا إجراء داخلي ولا
--    تجاوز صلاحية في هذه الهجرة إطلاقًا.
-- ب) **السلطة `payment.allocate` القائمة** (هجرة 080: للمالك والمدير
--    والمشغّل): من يملك تخصيص الدفعة يملك رؤية ما يخصّصه — ولا يُخصَّص ما
--    لا يُرى. فلا صلاحية جديدة والكتالوج يبقى 43/79. والفحص المسمّى داخل
--    العقد هو ما يمنع **الشريك** من قراءة السندات: سياسة 050 المولَّدة
--    تفتح له صفوف الدفعات، ونطاقه المُقرَّر (§26) لا يشملها.
-- ج) **لا حساب مال جديد:** المتبقي = `amount_minor` المخزَّن ناقص مجموع
--    `payment_allocations.allocated_minor` المخزَّن. جمعٌ وطرحٌ لأعمدة
--    مخزَّنة لا اشتقاق سعر ولا توزيع.
-- د) عقد الكتابة موجود وسليم: `api.allocate_payment` (هجرة 068/073/081)
--    يتحقق من الحالة والحساب والصلاحية ومن مجموع التخصيصات. فلا عقد كتابة
--    جديد هنا — العيب كان في جهة القراءة وحدها.
--
-- أثر مقصود على الفهرس: functions 457 → 458، وبلا أعمدة ولا قيود ولا
-- مشغّلات جديدة، والكتالوج 43/79 بلا تغيير.

begin;

-- ==============================================================
-- عقد واحد: INVOKER يفحص السلطة المسمّاة ثم يقرأ تحت RLS المتصل
--
-- ولماذا الفحص المسمّى داخل عقد INVOKER: RLS وحدها تفتح صفوف الدفعات
-- للشريك أيضًا (سياسة 050 المولَّدة)، ونطاقه المُقرَّر لا يشملها. فالفحص
-- يحدّ، وRLS تحصر الصفوف ببئر المتصل — طبقتان تعملان معًا لا واحدة.
-- ==============================================================

create or replace function api.list_advance_receipts(
  p_farmer_well_account_id uuid,
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
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_well uuid;
  v_items jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة سندات الرصيد المقدَّم'
      using errcode = '28000';
  end if;

  if p_farmer_well_account_id is null then
    raise exception 'معرّف حساب المزارع مطلوب'
      using errcode = '22023';
  end if;

  select fwa.well_id into v_well
  from ops.farmer_well_accounts fwa
  where fwa.id = p_farmer_well_account_id;

  -- حسابٌ غير مرئي وحسابٌ لا سلطة عليه: جواب واحد لا يفشي وجود الحساب.
  if v_well is null
     or not iam.has_well_permission(v_well, 'payment.allocate') then
    raise exception 'لا توجد صلاحية على حساب هذا المزارع'
      using errcode = '42501';
  end if;

  select coalesce(
    jsonb_agg(x.item order by x.paid_at, x.id),
    '[]'::jsonb
  )
  into v_items
  from (
    select
      p.id,
      p.paid_at,
      jsonb_build_object(
        'payment_id', p.id,
        'public_code', p.public_code,
        'paid_at', p.paid_at,
        'method', p.method,
        'amount_minor', p.amount_minor,
        'allocated_minor', coalesce(alloc.allocated_minor, 0),
        'remaining_minor', p.amount_minor - coalesce(alloc.allocated_minor, 0),
        'is_exhausted',
          (p.amount_minor - coalesce(alloc.allocated_minor, 0)) <= 0,
        'note', p.note
      ) as item
    from billing.payments p
    left join lateral (
      select sum(pa.allocated_minor) as allocated_minor
      from billing.payment_allocations pa
      where pa.payment_id = p.id
    ) alloc on true
    where p.farmer_well_account_id = p_farmer_well_account_id
      and p.purpose = 'advance'
      and p.status = 'posted'
    order by p.paid_at, p.id
    limit v_limit
  ) x;

  return jsonb_build_object(
    'contract', 'list_advance_receipts',
    'version', 1,
    'farmer_well_account_id', p_farmer_well_account_id,
    'receipts', v_items
  );
end;
$function$;

comment on function api.list_advance_receipts(uuid, integer) is
  'عقد قراءة سندات الرصيد المقدَّم (م-41G): معرّف كل سند ومبلغه والمخصَّص منه والمتبقّي ووسم الاستنفاد. INVOKER بلا تجاوز: هجرة 085 فتحت قراءة الدفعات غير المرتبطة بجلسة للمالك والمشغّل، والفحص المسمّى payment.allocate هو ما يحدّ. والتخصيص يبقى على api.allocate_payment بمبالغ يختارها إنسان.';

revoke all on function api.list_advance_receipts(uuid, integer)
  from public, anon, authenticated, service_role;

grant execute on function api.list_advance_receipts(uuid, integer)
  to authenticated, service_role;

commit;
