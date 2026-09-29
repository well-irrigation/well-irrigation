-- =====================================================================
-- Migration 110 — جسر ترحيل الحيازة على مستوى البئر (ق-131 بند 18 / م-45 A)
--
-- **لماذا:** م-109 نمذجت الحيازة «مشغل + بئر» بدقة، لكن إقرار الترحيل
-- فيها يتطلب `shift_id`، وواجهة Flutter ليس لها بعد عقد دورة حياة
-- نوبات (Shift). **لا نوبات مُختلقة ولا نوبة تُفتح صمتًا**: يجوز أن
-- يُسجَّل ترحيل حيازة النقد إقرارًا ماليًا على مستوى البئر بلا إسناد
-- نوبة، والقيود المحاسبية تبقى لسلطة تأكيد م-109 كما هي.
--
-- الحدود:
--   1. التسليم الشخصي/العادي يبقى ملزمًا بنوبة حقيقية: قيد check
--      يمنع 'person' بلا shift_id، والصفوف التاريخية لم تُمس.
--   2. `ops.declare_handover` القائم لا يُعدَّل.
--   3. لا جدول ترحيل موازٍ: الإدخال في `ops.shift_handovers` القائم.
--   4. الإقرار بلا قيد يومية؛ التأكيد المطابق للمالك هو وحده ما ينشر
--      قيد النقل 1000→1000 (م-109) — وقفل صف صندوق المصدر فيه يبقى
--      نقطة تسلسل التزامن.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- A1) التسليم الشخصي يلزمه نوبة، وترحيل الحيازة يجوز بلا نوبة
-- ---------------------------------------------------------------------

alter table ops.shift_handovers
  alter column shift_id drop not null;

-- الصفوف التاريخية كلها 'person' بنوبة قائمة فتجتاز القيد كما هي،
-- و'operator_cash_remittance' وحده يجوز له shift_id = null.
alter table ops.shift_handovers
  add constraint shift_handovers_shift_required_for_person
  check (handover_kind <> 'person' or shift_id is not null);

-- ---------------------------------------------------------------------
-- A2) الإقرار الداخلي على مستوى البئر (اسم مميز عن نسخة النوبة)
-- ---------------------------------------------------------------------

create or replace function ops.declare_operator_cash_remittance_for_well(
  p_well_id uuid,
  p_operator_profile_id uuid,
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
  v_tenant_id uuid;
  v_custody_id uuid;
  v_main_cashbox uuid;
  v_balance bigint;
  v_id uuid;
begin
  if p_amount_minor is null or p_amount_minor <= 0 then
    raise exception 'مبلغ الترحيل يجب أن يكون أكبر من صفر';
  end if;

  select w.tenant_id into v_tenant_id from core.wells w where w.id = p_well_id;
  if v_tenant_id is null then
    raise exception 'البئر غير موجود: %', p_well_id;
  end if;

  -- تعيين مشغل نشط على هذا البئر شرط، والحيازة تُضمن له (م-109):
  -- لا حيازة لغير المشغل النشط مهما كانت صلاحياته المالية.
  if not finance.is_active_operator_assignment(p_well_id, p_operator_profile_id) then
    raise exception 'لا يوجد تعيين مشغل نشط للملف % في البئر %', p_operator_profile_id, p_well_id;
  end if;
  v_custody_id := finance.ensure_operator_custody_cashbox(p_well_id, p_operator_profile_id);

  v_main_cashbox := finance.main_cashbox_id(p_well_id);
  if v_main_cashbox is null or not exists (
    select 1 from finance.cashboxes c
    where c.id = v_main_cashbox and c.well_id = p_well_id and c.status = 'active'
  ) then
    raise exception 'صندوق البئر العام غير موجود أو غير فعال — لا وجهة للترحيل';
  end if;

  -- الحيازة من دفتر الحسابات حصرًا: لا إقرار فوق المتوفر.
  select finance.cashbox_balance_minor(v_custody_id) into v_balance;
  if v_balance < p_amount_minor then
    raise exception 'مبلغ الترحيل % يتجاوز حيازة المشغل الحالية % — لا يُقرَّر ترحيل فوق المتوفر', p_amount_minor, v_balance;
  end if;

  -- إقرار بلا نوبة: shift_id = null من النوع الصريح، بلا قيد يومية —
  -- تأكيد المالك في م-109 هو سلطة القيد المحاسبي وحدها.
  insert into ops.shift_handovers (
    tenant_id, well_id, shift_id, from_profile_id,
    to_description, declared_amount_minor, note,
    handover_kind, from_cashbox_id, to_cashbox_id
  ) values (
    v_tenant_id, p_well_id, null, p_operator_profile_id,
    'ترحيل إلى صندوق البئر العام', p_amount_minor, p_note,
    'operator_cash_remittance', v_custody_id, v_main_cashbox
  ) returning id into v_id;

  perform ops.notify_well_owners(p_well_id, 'handover_declared',
    format('أقر المشغل بترحيل مبلغ %s ريال من حيازته إلى صندوق البئر - بانتظار تأكيدك', p_amount_minor));

  return v_id;
end;
$$;

revoke all on function ops.declare_operator_cash_remittance_for_well(uuid, uuid, bigint, text)
from public, anon;
grant execute on function ops.declare_operator_cash_remittance_for_well(uuid, uuid, bigint, text)
to authenticated, service_role;

-- ---------------------------------------------------------------------
-- A3) عقد الإقرار العام: الفاعل من auth.uid() وحده — لا profile من العميل
-- ---------------------------------------------------------------------

create or replace function api.declare_my_operator_cash_remittance(
  p_well_id uuid,
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
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إقرار ترحيل الحيازة';
  end if;
  if not finance.is_active_operator_assignment(p_well_id, v_actor) then
    raise exception 'إقرار ترحيل الحيازة خاص بالمشغل النشط لهذا البئر';
  end if;

  return ops.declare_operator_cash_remittance_for_well(
    p_well_id, v_actor, p_amount_minor, p_note
  );
end;
$function$;

revoke all on function api.declare_my_operator_cash_remittance(uuid, bigint, text)
from public, anon, authenticated, service_role;
grant execute on function api.declare_my_operator_cash_remittance(uuid, bigint, text)
to authenticated, service_role;

-- ---------------------------------------------------------------------
-- A4) قراءة التراخيم: المالك يرى كل تراخيم البئر، والمشغل النشط
--     يرى تراخيمه وحده، وغيرهما مرفوض — ولا تعرض جداول داخلية.
-- ---------------------------------------------------------------------

create or replace function api.list_operator_cash_remittances(
  p_well_id uuid,
  p_limit integer default 50
)
returns jsonb
language plpgsql
stable
security invoker
set search_path to 'pg_catalog', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_is_owner boolean;
  v_is_operator boolean;
  v_safe_limit integer;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة التراخيم';
  end if;

  -- المالك بكود الصلاحية الحاكم (من يؤكد التراخيم يراها كلها) — لا
  -- مصفوفات أدوار نصية: حرس م-18/082 يسقط أي جسد دالة عليها.
  v_is_owner := iam.has_well_permission(p_well_id, 'handover.confirm');
  v_is_operator := finance.is_active_operator_assignment(p_well_id, v_actor);
  if not (v_is_owner or v_is_operator) then
    raise exception 'قراءة تراخيم الحيازة خاصة بمالك البئر أو مشغله النشط';
  end if;

  v_safe_limit := greatest(least(coalesce(p_limit, 50), 200), 1);

  return jsonb_build_object(
    'remittances',
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', h.id,
        'well_id', h.well_id,
        'from_profile_id', h.from_profile_id,
        'from_profile_name', p.full_name,
        'declared_amount_minor', h.declared_amount_minor,
        'confirmed_amount_minor', h.confirmed_amount_minor,
        'difference_minor', h.difference_minor,
        'difference_reason', h.difference_reason,
        'status', h.status,
        'declared_at', h.declared_at,
        'confirmed_at', h.confirmed_at,
        'note', h.note,
        'journal_entry_id', h.journal_entry_id
      ) order by h.declared_at desc, h.id desc)
      from ops.shift_handovers h
      join iam.profiles p on p.id = h.from_profile_id
      where h.well_id = p_well_id
        and h.handover_kind = 'operator_cash_remittance'
        and (v_is_owner or h.from_profile_id = v_actor)
      limit v_safe_limit
    ), '[]'::jsonb)
  );
end;
$function$;

revoke all on function api.list_operator_cash_remittances(uuid, integer)
from public, anon, authenticated, service_role;
grant execute on function api.list_operator_cash_remittances(uuid, integer)
to authenticated, service_role;

commit;
