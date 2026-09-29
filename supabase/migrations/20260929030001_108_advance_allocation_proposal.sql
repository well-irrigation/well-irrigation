-- ق-131 البند 10 / م-45 المرحلة A: اقتراح تسوية المقدم بتأكيد صريح.
--
-- القرار الحاكم (اعتماد المالك 2026-09-28):
--   1. المقدم القديم **لا يُستهلك صمتًا** (ق-99 / الثوابت 267–271):
--      لا Netting صامت بين الدين والرصيد المقدم.
--   2. يجوز للنظام أن **يحسب ويقترح** آليًا كم مقدَّم يمكن تطبيقه على
--      التسوية الجارية، لكن قبل التخصيص/القيد يُعرض **التسوية
--      المقترحة** ويُشترط **تأكيد صريح من المستخدم**.
--   3. ترتيب الفواتير الأقدم اقتراح افتراضي مرئي قابل للتعديل — لا
--      تسوية صامتة.
--
-- **الحاجة:** سندات الرصيد المقدم صارت تُقرأ بمعرّفاتها ومتبقّياتها
-- (097)، والكتابة تحتاج تأكيد إنسان (081). الناقص: **رقم مقترح يحسبه
-- الخادم** تعبّئه النافذة لتأكيده أو تعديله — فلا يحسبه العميل (ق-99).
--
-- **عقد قراءة صرف:** STABLE وINVOKER وقراءة حصرًا — لا يُنشئ ولا
-- يُحدّث ولا يُحذف أي صف مالي، ولا قيد يومية، ولا تخصيص تلقائي.
-- الكتابة تبقى على `api.allocate_payment` → `billing.allocate_payment`
-- (081) بلا تغيير ولا عقد كتابة ثانٍ.
--
-- **حساب الاقتراح من المخزَّن حصرًا:** متبقّي السند = `amount_minor`
-- المخزَّن ناقص مجموع `payment_allocations.allocated_minor` المخزَّن
-- (نمط 097/081 نفسه)، والمتبقي على الفاتورة = `outstanding_minor`
-- العمود الحاكم، والمقترح = أصغرهما — لا سعر ولا توزيع ولا اشتقاق.
--
-- **السلطة:** الحقيقة المسمّاة نفسها التي تحرس الكتابة —
-- `payment.allocate` على بئر الدفعة (080: للمالك والمدير والمشغّل؛
-- الشريك خارجها وفق §26). وفشل مغلق: سند غير مرحّل أو غير مقدَّم أو
-- بلا حساب مزارع، وفاتورة من بئر/حساب آخر أو بحالة لا يقبلها
-- التخصيص (`issued`/`partially_paid`/`overdue` حصرًا كما تشترط
-- billing.allocate_payment)، ومعرّفات فارغة أو غير موجودة — كلها
-- رفض صريح بلا غلاف فارغ.

begin;

-- ==============================================================
-- عقد الاقتراح: قراءة واحدة محسومة قبل تأكيد الإنسان
-- ==============================================================

create or replace function api.get_advance_allocation_proposal(
  p_payment_id uuid,
  p_invoice_id uuid
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_payment record;
  v_invoice record;
  v_advance_remaining bigint;
  v_invoice_outstanding bigint;
  v_proposed bigint;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل حساب التسوية المقترحة'
      using errcode = '28000';
  end if;

  if p_payment_id is null or p_invoice_id is null then
    raise exception 'معرّفا السند والفاتورة مطلوبان'
      using errcode = '22023';
  end if;

  -- السند: مرحّل، غرضه مقدم، مرتبط بحساب مزارع، ومرئي عبر RLS المتصل.
  select p.id, p.well_id, p.farmer_well_account_id, p.amount_minor
  into v_payment
  from billing.payments p
  where p.id = p_payment_id
    and p.status = 'posted'
    and p.purpose = 'advance'
    and p.farmer_well_account_id is not null;

  -- سند غير مرئي أو غير مؤهل: رفض واحد لا يفشي الوجود — والسلطة
  -- المسمّاة نفسها التي تفتح الكتابة هي من يفتح الاقتراح.
  if v_payment.id is null
     or not iam.has_well_permission(v_payment.well_id, 'payment.allocate') then
    raise exception 'لا توجد صلاحية على سند الرصيد المقدم هذا'
      using errcode = '42501';
  end if;

  -- الفاتورة: نفس البئر ونفس حساب المزارع، وبحالة يقبلها التخصيص
  -- المخوَّل في billing.allocate_payment حرفيًا.
  select i.outstanding_minor
  into v_invoice
  from billing.invoices i
  where i.id = p_invoice_id
    and i.well_id = v_payment.well_id
    and i.farmer_well_account_id = v_payment.farmer_well_account_id
    and i.status in ('issued', 'partially_paid', 'overdue');

  if v_invoice.outstanding_minor is null then
    raise exception 'الفاتورة غير صالحة للتسديد من الرصيد المقدم'
      using errcode = '42501';
  end if;

  -- المتبقي من السند من المخزَّن: المبلغ ناقص مجموع التخصيصات المخزَّنة.
  select v_payment.amount_minor - coalesce(sum(pa.allocated_minor), 0)
  into v_advance_remaining
  from billing.payment_allocations pa
  where pa.payment_id = p_payment_id;

  v_invoice_outstanding := v_invoice.outstanding_minor;
  v_proposed := least(v_advance_remaining, v_invoice_outstanding);

  return jsonb_build_object(
    'contract', 'get_advance_allocation_proposal',
    'version', 1,
    'payment_id', v_payment.id,
    'invoice_id', p_invoice_id,
    'farmer_well_account_id', v_payment.farmer_well_account_id,
    'well_id', v_payment.well_id,
    'advance_remaining_minor', v_advance_remaining,
    'invoice_outstanding_minor', v_invoice_outstanding,
    'proposed_minor', v_proposed,
    'can_apply', v_proposed > 0
  );
end;
$function$;

comment on function api.get_advance_allocation_proposal(uuid, uuid) is
  'ق-131 البند 10: اقتراح تسوية من الرصيد المقدم يحسبه الخادم من المخزَّن حصرًا — متبقّي السند ناقص تخصيصاته، والمتبقي على الفاتورة العمود الحاكم، والمقترح أصغرهما. قراءة صرف STABLE/INVOKER بسلطة payment.allocate: لا صف مالي يتغير ولا قيد يومية ولا تخصيص تلقائي — والتطبيق يبقى بتأكيد إنسان عبر api.allocate_payment (081).';

revoke all on function api.get_advance_allocation_proposal(uuid, uuid)
  from public, anon, authenticated, service_role;

grant execute on function api.get_advance_allocation_proposal(uuid, uuid)
  to authenticated, service_role;

commit;
