-- المرحلة 6 - الملف 056:
-- 1) حذف النسخة القديمة (9 معاملات) من record_expense التي بقيت كازدواج بعد اضافة معامل الشريك
-- 2) فحص توازن جلسة الارصدة الافتتاحية عند الاعتماد ايضا (اكتشاف مبكر للخلل)

drop function if exists finance.record_expense(uuid, text, bigint, text, uuid, text, boolean, text, text);

create or replace function finance.approve_opening_balance_batch(p_batch_id uuid, p_approved_by uuid)
returns void language plpgsql security definer set search_path to 'finance', 'pg_temp' as $$
declare
  v_status text;
  v_items integer;
  v_debits bigint;
  v_credits bigint;
begin
  select status into v_status from finance.opening_balance_batches where id = p_batch_id for update;
  if v_status is null then raise exception 'جلسة الارصدة غير موجودة: %', p_batch_id; end if;
  if v_status not in ('draft', 'pending_approval') then
    raise exception 'لا يمكن اعتماد جلسة حالتها % — يجب ان تكون مسودة او بانتظار الاعتماد', v_status;
  end if;
  select count(*) into v_items from finance.opening_balance_items where batch_id = p_batch_id;
  if v_items = 0 then raise exception 'لا يمكن اعتماد جلسة بلا عناصر'; end if;

  -- التوازن الافتتاحي يفحص عند الاعتماد (والترحيل يعيده كحارس نهائي)
  select coalesce(sum(case when item_type in ('farmer_debt','cashbox_balance','fuel_tank_balance','partner_receivable') then amount_minor else 0 end), 0),
         coalesce(sum(case when item_type in ('farmer_advance','partner_payable','salary_payable','expense_payable','capital_balance') then amount_minor else 0 end), 0)
  into v_debits, v_credits
  from finance.opening_balance_items where batch_id = p_batch_id;
  if v_debits <> v_credits then
    raise exception 'جلسة الارصدة غير متوازنة: مجموع الاصول % لا يساوي مجموع الالتزامات وراس المال %', v_debits, v_credits;
  end if;

  update finance.opening_balance_batches
  set status = 'approved', approved_by = p_approved_by, approved_at = now()
  where id = p_batch_id;
end;
$$;
