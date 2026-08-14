-- =====================================================================
-- 068 — إجراءات المال الذرية المتبقية
-- record_payment / allocate_payment / pay_partner_distribution
-- =====================================================================

-- المبلغ المدفوع تراكميًا حالة تشغيلية، ولا يغيّر أي مبلغ محسوب ومعتمد.
alter table finance.profit_distribution_lines
  add column paid_minor bigint not null default 0;

alter table finance.profit_distribution_lines
  add constraint profit_distribution_lines_paid_minor_check
  check (
    paid_minor >= 0
    and paid_minor <= greatest(net_payable_minor, 0)
  );

-- بعد الدفع الجزئي لا يبقى التزامًا إلا المتبقي، مع إبقاء حجز الرواتب المستحقة.
create or replace function finance.compute_reserved_liabilities(p_well_id uuid)
returns bigint
language plpgsql
stable
security definer
set search_path to 'finance', 'pg_temp'
as $function$
declare
  v_partners bigint;
  v_payroll bigint;
begin
  select coalesce(sum(greatest(l.net_payable_minor - l.paid_minor, 0)), 0)
  into v_partners
  from finance.profit_distribution_lines l
  join finance.profit_distribution_cycles c on c.id = l.distribution_cycle_id
  where c.well_id = p_well_id
    and l.status in ('approved', 'partially_paid', 'carried_forward');

  select coalesce(sum(a.net_amount_minor), 0)
  into v_payroll
  from finance.payroll_accruals a
  where a.well_id = p_well_id and a.status = 'due';

  return v_partners + v_payroll;
end;
$function$;

-- توزيع دفعة موجودة على فواتير محددة بالمبالغ والترتيب المرسلين.
create or replace function billing.allocate_payment(
  p_payment_id uuid,
  p_allocations jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'billing', 'finance', 'core', 'audit', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_payment billing.payments%rowtype;
  v_invoice billing.invoices%rowtype;
  v_item jsonb;
  v_invoice_id uuid;
  v_amount bigint;
  v_requested_total bigint := 0;
  v_allocated_before bigint;
  v_available bigint;
  v_allocation_id uuid;
  v_journal_id uuid;
  v_result_items jsonb := '[]'::jsonb;
  v_position integer := 0;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل توزيع الدفعة على الفواتير';
  end if;

  select p.* into v_payment
  from billing.payments p
  where p.id = p_payment_id
  for update;

  if not found then
    raise exception 'الدفعة غير موجودة: %', p_payment_id;
  end if;
  if v_payment.status <> 'posted' then
    raise exception 'لا يمكن توزيع دفعة حالتها % — يجب أن تكون مرحلة', v_payment.status;
  end if;
  if v_payment.farmer_well_account_id is null then
    raise exception 'لا يمكن توزيع الدفعة لأنها غير مرتبطة بحساب مزارع';
  end if;
  if not iam.has_well_role(v_payment.well_id, array['owner', 'manager', 'operator']) then
    raise exception 'لا تملك صلاحية توزيع دفعات هذا البئر';
  end if;
  if p_allocations is null or jsonb_typeof(p_allocations) <> 'array'
     or jsonb_array_length(p_allocations) = 0 then
    raise exception 'يجب إرسال فاتورة واحدة على الأقل مع مبلغ التخصيص';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(p_allocations) x
    group by x ->> 'invoice_id'
    having count(*) > 1
  ) then
    raise exception 'لا يجوز تكرار الفاتورة نفسها في طلب التوزيع';
  end if;

  for v_item in select value from jsonb_array_elements(p_allocations)
  loop
    begin
      v_invoice_id := (v_item ->> 'invoice_id')::uuid;
      v_amount := (v_item ->> 'amount_minor')::bigint;
    exception when others then
      raise exception 'صيغة تخصيص الفاتورة غير صالحة — يلزم invoice_id و amount_minor صحيحان';
    end;
    if v_invoice_id is null then
      raise exception 'معرف الفاتورة مطلوب في كل تخصيص';
    end if;
    if v_amount is null or v_amount <= 0 then
      raise exception 'مبلغ تخصيص كل فاتورة يجب أن يكون أكبر من صفر';
    end if;
    v_requested_total := v_requested_total + v_amount;
  end loop;

  select coalesce(sum(pa.allocated_minor), 0)
  into v_allocated_before
  from billing.payment_allocations pa
  where pa.payment_id = p_payment_id;

  v_available := v_payment.amount_minor - v_allocated_before;
  if v_requested_total > v_available then
    raise exception 'إجمالي التخصيص المطلوب % يتجاوز المتاح من الدفعة %',
      v_requested_total, v_available;
  end if;

  for v_item in
    select a.value
    from jsonb_array_elements(p_allocations) with ordinality as a(value, position)
    order by a.position
  loop
    v_position := v_position + 1;
    v_invoice_id := (v_item ->> 'invoice_id')::uuid;
    v_amount := (v_item ->> 'amount_minor')::bigint;

    select i.* into v_invoice
    from billing.invoices i
    where i.id = v_invoice_id
    for update;

    if not found then
      raise exception 'الفاتورة غير موجودة: %', v_invoice_id;
    end if;
    if v_invoice.well_id is distinct from v_payment.well_id
       or v_invoice.farmer_well_account_id is distinct from v_payment.farmer_well_account_id then
      raise exception 'الفاتورة % لا تخص البئر وحساب المزارع المرتبطين بالدفعة', v_invoice_id;
    end if;
    if v_invoice.status not in ('issued', 'partially_paid', 'overdue') then
      raise exception 'لا يمكن تخصيص دفعة لفاتورة حالتها %', v_invoice.status;
    end if;
    if v_amount > v_invoice.outstanding_minor then
      raise exception 'مبلغ التخصيص % يتجاوز دين الفاتورة المتبقي %',
        v_amount, v_invoice.outstanding_minor;
    end if;

    insert into billing.payment_allocations (
      tenant_id, payment_id, invoice_id, allocated_minor
    ) values (
      v_payment.tenant_id, p_payment_id, v_invoice_id, v_amount
    )
    returning id into v_allocation_id;

    update billing.invoices
    set paid_minor = paid_minor + v_amount,
        outstanding_minor = outstanding_minor - v_amount,
        status = case
          when outstanding_minor - v_amount = 0 then 'paid'
          else 'partially_paid'
        end
    where id = v_invoice_id;

    -- استخدام الرصيد المقدم يحوّل الالتزام إلى تسوية ذمة المزارع.
    if v_payment.purpose = 'advance' then
      v_journal_id := gen_random_uuid();
      insert into finance.journal_entries (
        id, tenant_id, public_code, well_id, entry_date,
        source_type, source_id, description, idempotency_key
      ) values (
        v_journal_id, v_payment.tenant_id, core.generate_public_code('JE'),
        v_payment.well_id, clock_timestamp(), 'advance_allocation',
        v_allocation_id, 'استخدام رصيد مقدم في الفاتورة ' || v_invoice.public_code,
        'ADV-ALLOC-' || v_allocation_id::text
      );

      insert into finance.journal_lines (
        tenant_id, journal_entry_id, ledger_account_id, entry_side,
        amount_minor, farmer_well_account_id, description
      ) values
        (v_payment.tenant_id, v_journal_id,
         finance.ledger_account_id(v_payment.well_id, '2000'), 'debit',
         v_amount, v_payment.farmer_well_account_id, 'استخدام الرصيد المقدم'),
        (v_payment.tenant_id, v_journal_id,
         finance.ledger_account_id(v_payment.well_id, '1100'), 'credit',
         v_amount, v_payment.farmer_well_account_id, 'تسديد ذمة فاتورة من الرصيد المقدم');

      perform finance.post_journal_entry(v_journal_id, v_actor);
    else
      v_journal_id := null;
    end if;

    perform audit.log(
      v_payment.tenant_id, v_payment.well_id,
      'allocate_payment', 'billing.payment_allocations', v_allocation_id,
      null,
      jsonb_build_object(
        'payment_id', p_payment_id,
        'invoice_id', v_invoice_id,
        'allocated_minor', v_amount,
        'position', v_position,
        'journal_entry_id', v_journal_id
      ),
      'توزيع دفعة على فاتورة'
    );

    v_result_items := v_result_items || jsonb_build_array(jsonb_build_object(
      'allocation_id', v_allocation_id,
      'invoice_id', v_invoice_id,
      'allocated_minor', v_amount,
      'invoice_status', case
        when v_invoice.outstanding_minor - v_amount = 0 then 'paid'
        else 'partially_paid'
      end,
      'journal_entry_id', v_journal_id
    ));
  end loop;

  if (select coalesce(sum(pa.allocated_minor), 0)
      from billing.payment_allocations pa
      where pa.payment_id = p_payment_id) > v_payment.amount_minor then
    raise exception 'فشل التحقق النهائي: مجموع التخصيصات تجاوز قيمة الدفعة';
  end if;

  return jsonb_build_object(
    'payment_id', p_payment_id,
    'allocated_minor', v_requested_total,
    'remaining_available_minor', v_available - v_requested_total,
    'allocations', v_result_items
  );
end;
$function$;

-- تسجيل دفعة واحدة، وترك زنادات السياق والتقسيم والترحيل تعمل بإدخال عادي.
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
  if not iam.has_well_role(p_well_id, array['owner', 'manager', 'operator']) then
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

  -- 4) الصندوق عند الدفع النقدي.
  v_cashbox_id := coalesce(p_cashbox_id, finance.main_cashbox_id(p_well_id));
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

    -- 5) إنشاء الدفعة العادية؛ الزناد يقسم أي زيادة إلى رصيد مقدم.
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

-- دفع صافي مستحق شريك من دورة معتمدة، كليًا أو جزئيًا.
create or replace function finance.pay_partner_distribution(
  p_distribution_line_id uuid,
  p_amount_minor bigint,
  p_paid_by uuid default null,
  p_paid_at timestamptz default clock_timestamp()
)
returns jsonb
language plpgsql
security definer
set search_path to 'finance', 'core', 'audit', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_line finance.profit_distribution_lines%rowtype;
  v_cycle finance.profit_distribution_cycles%rowtype;
  v_remaining bigint;
  v_new_paid bigint;
  v_new_line_status text;
  v_new_cycle_status text;
  v_cashbox_id uuid;
  v_journal_id uuid;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل دفع مستحق الشريك';
  end if;
  if p_paid_by is not null and p_paid_by is distinct from v_actor then
    raise exception 'منفذ الدفع يجب أن يطابق المستخدم المسجل حاليًا';
  end if;
  if p_amount_minor is null or p_amount_minor <= 0 then
    raise exception 'مبلغ دفع الشريك يجب أن يكون أكبر من صفر';
  end if;

  select l.* into v_line
  from finance.profit_distribution_lines l
  where l.id = p_distribution_line_id
  for update;

  if not found then
    raise exception 'سطر توزيع الشريك غير موجود: %', p_distribution_line_id;
  end if;

  select c.* into v_cycle
  from finance.profit_distribution_cycles c
  where c.id = v_line.distribution_cycle_id
  for update;

  if not iam.has_well_role(v_cycle.well_id, array['owner', 'manager']) then
    raise exception 'لا تملك صلاحية دفع مستحقات شركاء هذا البئر';
  end if;
  if v_line.status = 'paid' then
    raise exception 'مستحق الشريك في هذا السطر مدفوع بالكامل مسبقًا';
  end if;
  if v_cycle.status not in ('approved', 'partially_paid') then
    raise exception 'لا يمكن دفع مستحق شريك من دورة حالتها % — يجب أن تكون معتمدة', v_cycle.status;
  end if;
  if v_line.status not in ('approved', 'partially_paid') then
    raise exception 'لا يمكن دفع سطر حالته % — يجب أن يكون معتمدًا', v_line.status;
  end if;

  v_remaining := v_line.net_payable_minor - v_line.paid_minor;
  if v_remaining <= 0 then
    raise exception 'لا يوجد مبلغ متبقٍ لدفعه في مستحق الشريك';
  end if;
  if p_amount_minor > v_remaining then
    raise exception 'مبلغ الدفع % يتجاوز مستحق الشريك المتبقي %',
      p_amount_minor, v_remaining;
  end if;

  v_cashbox_id := finance.main_cashbox_id(v_cycle.well_id);
  if v_cashbox_id is null or not exists (
    select 1 from finance.cashboxes c
    where c.id = v_cashbox_id and c.status = 'active'
  ) then
    raise exception 'الصندوق الرئيسي غير موجود أو غير فعال لهذا البئر';
  end if;

  -- قيد الصرف: تخفيض مستحق الشريك مقابل النقد الخارج من الصندوق الرئيسي.
  v_journal_id := gen_random_uuid();
  insert into finance.journal_entries (
    id, tenant_id, public_code, well_id, entry_date,
    source_type, source_id, description, idempotency_key
  ) values (
    v_journal_id, v_cycle.tenant_id, core.generate_public_code('JE'),
    v_cycle.well_id, p_paid_at, 'partner_distribution_payment',
    v_journal_id, 'دفع مستحق شريك من دورة ' || v_cycle.public_code,
    'PDP-' || v_journal_id::text
  );

  insert into finance.journal_lines (
    tenant_id, journal_entry_id, ledger_account_id, entry_side,
    amount_minor, partner_id, cashbox_id, description
  ) values
    (v_cycle.tenant_id, v_journal_id,
     finance.ledger_account_id(v_cycle.well_id, '2100'), 'debit',
     p_amount_minor, v_line.partner_id, null, 'تخفيض مستحق الشريك'),
    (v_cycle.tenant_id, v_journal_id,
     finance.ledger_account_id(v_cycle.well_id, '1000'), 'credit',
     p_amount_minor, v_line.partner_id, v_cashbox_id, 'صرف من الصندوق الرئيسي');

  perform finance.post_journal_entry(v_journal_id, v_actor);

  v_new_paid := v_line.paid_minor + p_amount_minor;
  v_new_line_status := case
    when v_new_paid = v_line.net_payable_minor then 'paid'
    else 'partially_paid'
  end;

  update finance.profit_distribution_lines
  set paid_minor = v_new_paid,
      status = v_new_line_status
  where id = p_distribution_line_id;

  if exists (
    select 1 from finance.profit_distribution_lines l
    where l.distribution_cycle_id = v_cycle.id
      and l.paid_minor < greatest(l.net_payable_minor, 0)
  ) then
    v_new_cycle_status := 'partially_paid';
  else
    v_new_cycle_status := 'paid';
  end if;

  update finance.profit_distribution_cycles
  set status = v_new_cycle_status
  where id = v_cycle.id;

  perform audit.log(
    v_cycle.tenant_id, v_cycle.well_id,
    'pay_partner_distribution', 'finance.profit_distribution_lines',
    p_distribution_line_id,
    jsonb_build_object(
      'paid_minor', v_line.paid_minor,
      'status', v_line.status
    ),
    jsonb_build_object(
      'paid_minor', v_new_paid,
      'status', v_new_line_status,
      'cycle_status', v_new_cycle_status,
      'journal_entry_id', v_journal_id
    ),
    'دفع مستحق شريك'
  );

  return jsonb_build_object(
    'distribution_line_id', p_distribution_line_id,
    'paid_now_minor', p_amount_minor,
    'paid_total_minor', v_new_paid,
    'remaining_minor', v_line.net_payable_minor - v_new_paid,
    'line_status', v_new_line_status,
    'cycle_status', v_new_cycle_status,
    'journal_entry_id', v_journal_id
  );
end;
$function$;

-- العقد العام متاح للمستخدم الموثق فقط.
revoke all on function billing.allocate_payment(uuid, jsonb) from public;
revoke all on function billing.allocate_payment(uuid, jsonb) from anon;
revoke all on function billing.record_payment(uuid, uuid, bigint, text, jsonb, uuid, uuid, uuid, timestamptz, text, text) from public;
revoke all on function billing.record_payment(uuid, uuid, bigint, text, jsonb, uuid, uuid, uuid, timestamptz, text, text) from anon;
revoke all on function finance.pay_partner_distribution(uuid, bigint, uuid, timestamptz) from public;
revoke all on function finance.pay_partner_distribution(uuid, bigint, uuid, timestamptz) from anon;

grant execute on function billing.allocate_payment(uuid, jsonb) to authenticated;
grant execute on function billing.record_payment(uuid, uuid, bigint, text, jsonb, uuid, uuid, uuid, timestamptz, text, text) to authenticated;
grant execute on function finance.pay_partner_distribution(uuid, bigint, uuid, timestamptz) to authenticated;
