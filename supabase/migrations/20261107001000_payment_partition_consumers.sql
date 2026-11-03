begin;
-- نفس المصدر المالي: التخصيص الصريح يسبق وجهة charge الافتراضية.
-- INSERT قديم يحمل تسديدًا مخزنًا بلا صف دفع/تخصيص؛ نحفظ أساسه مرة واحدة.
-- لا نستنتجه من paid_minor عند UPDATE: ذلك العداد مشتق وقد يتضمن direct.
create function billing.capture_inserted_invoice_settlement() returns trigger
language plpgsql security invoker set search_path=pg_catalog,pg_temp as $$
begin
 if new.nonallocation_paid_minor=0 and new.paid_minor>0 then
  new.inserted_settlement_snapshot_minor:=new.paid_minor;
 end if;
 return new;
end;$$;
create trigger invoices_capture_inserted_settlement before insert on billing.invoices
 for each row execute function billing.capture_inserted_invoice_settlement();
revoke all on function billing.capture_inserted_invoice_settlement() from public,anon,authenticated,service_role;

-- قراءة الجلسة تحترم التسديد المحفوظ للفاتورة، بما فيه مسودة تاريخية.
-- الحسابات المالية لا تحول المسودة إلى دين صادر؛ هذا محول قراءة مشترك فقط.
create view billing.session_read_settlements with(security_invoker=true) as
select sc.id as session_charge_id,sc.session_id,
 case when i.id is not null then b.paid_minor else d.settled_minor end as paid_minor
from billing.session_charges sc
left join billing.invoices i on i.session_id=sc.session_id
left join billing.invoice_effective_balances b on b.invoice_id=i.id
left join billing.session_economic_settlements d on d.session_charge_id=sc.id;
revoke all on billing.session_read_settlements from public,anon,authenticated,service_role;
grant select on billing.session_read_settlements to authenticated,service_role;

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

  perform billing.lock_customer_credit_well(p_well_id);

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

    select (select outstanding_minor from billing.session_economic_settlements where session_charge_id=sc.id)
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
create or replace function billing.split_overpayment_to_advance()
returns trigger
language plpgsql
security definer
set search_path = 'billing', 'finance', 'core', 'pg_temp'
as $function$
declare
  v_charge bigint;
  v_paid bigint;
  v_remaining bigint;
  v_over bigint;
begin
  if new.purpose <> 'session' or new.session_charge_id is null then
    return new;
  end if;
  if coalesce(new.status, 'posted') = 'reversed' then
    return new;
  end if;

  perform billing.lock_customer_credit_well(new.well_id);
  select sc.amount_minor into v_charge
  from billing.session_charges sc
  where sc.id = new.session_charge_id;
  if v_charge is null then
    return new;
  end if;

  select outstanding_minor into v_remaining from billing.session_economic_settlements where session_charge_id=new.session_charge_id;
  if v_remaining is null then raise exception 'session_payment_destination_unresolved' using errcode='23514';end if;
  if new.amount_minor <= v_remaining then
    return new;
  end if;

  if new.farmer_well_account_id is null then
    raise exception 'الدفعة تتجاوز المتبقي من قيمة الجلسة ولا يمكن تحويل الزيادة الى رصيد مقدم دون تحديد حساب المزارع';
  end if;

  if v_remaining <= 0 then
    new.note := coalesce(new.note || ' | ', '') || format('حُوّلت كاملة (%s) الى رصيد مقدم: الجلسة مسددة بالكامل', new.amount_minor);
    new.purpose := 'advance';
    new.session_charge_id := null;
    return new;
  end if;

  v_over := new.amount_minor - v_remaining;

  insert into billing.payments (
    tenant_id, well_id, farmer_well_account_id, payer_person_id,
    cashbox_id, shift_id, collected_by_profile_id, received_by_profile_id,
    method, amount_minor, purpose, status, note
  ) values (
    new.tenant_id, new.well_id, new.farmer_well_account_id, new.payer_person_id,
    new.cashbox_id, new.shift_id, new.collected_by_profile_id, new.received_by_profile_id,
    new.method, v_over, 'advance', new.status,
    format('رصيد مقدم تلقائي: زيادة %s عن المتبقي من قيمة الجلسة', v_over)
  );

  new.note := coalesce(new.note || ' | ', '') || format('اقتُطعت الزيادة %s وحُوّلت الى رصيد مقدم', v_over);
  new.amount_minor := v_remaining;
  return new;
end;
$function$;
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

  select * into v_payment from billing.payments where id=p_payment_id;
  if not found then raise exception 'الدفعة غير موجودة: %',p_payment_id;end if;
  if not coalesce(iam.has_well_permission(v_payment.well_id,'payment.allocate'),false) then
    raise exception 'لا تملك صلاحية توزيع دفعات هذا البئر';end if;
  perform billing.lock_customer_credit_well(v_payment.well_id);
  perform billing.refresh_partition_invoices(v_payment.well_id);
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
  if not iam.has_well_permission(v_payment.well_id, 'payment.allocate') then
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

  select b.direct_capacity_minor into strict v_available
  from billing.payment_economic_applications b where b.payment_id=p_payment_id;
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
    if v_invoice.status not in ('issued', 'partially_paid', 'overdue','paid') then
      raise exception 'لا يمكن تخصيص دفعة لفاتورة حالتها %', v_invoice.status;
    end if;
    if v_amount > v_invoice.outstanding_minor + coalesce((select direct_settled_minor from billing.session_economic_settlements d
      where d.session_charge_id=v_payment.session_charge_id and d.session_id=v_invoice.session_id),0) then
      raise exception 'مبلغ التخصيص % يتجاوز دين الفاتورة المتبقي %',
        v_amount, v_invoice.outstanding_minor;
    end if;

    insert into billing.payment_allocations (
      tenant_id, payment_id, invoice_id, allocated_minor
    ) values (
      v_payment.tenant_id, p_payment_id, v_invoice_id, v_amount
    )
    returning id into v_allocation_id;

    perform billing.refresh_partition_invoices(v_payment.well_id);

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
      'invoice_status',(select status from billing.invoices where id=v_invoice_id),
      'journal_entry_id', v_journal_id
    ));
  end loop;

  if (select available_minor from billing.payment_available_balances where payment_id=p_payment_id)<0 then
    raise exception 'payment_effective_availability_negative' using errcode='23514';
  end if;

  return jsonb_build_object(
    'payment_id', p_payment_id,
    'allocated_minor', v_requested_total,
    'remaining_available_minor',(select remaining_minor from billing.payment_economic_applications where payment_id=p_payment_id),
    'remaining_transfer_capacity_minor',v_available-v_requested_total,
    'allocations', v_result_items
  );
end;
$function$;
create or replace function billing.apply_account_credit(p_credit uuid,p_invoice uuid,p_amount bigint,p_source uuid,p_revision bigint,
 p_reason text,p_posted_at timestamptz,p_origin_id uuid default null) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare c billing.account_credits%rowtype;i billing.invoices%rowtype;actor uuid:=auth.uid();
 request jsonb;r jsonb;e uuid:=gen_random_uuid();app uuid;j uuid;available bigint;
begin
 select * into strict c from billing.account_credits where id=p_credit;
 if actor is null or not coalesce(iam.has_well_permission(c.well_id,'payment.allocate'),false) then
  raise exception 'credit_application_forbidden' using errcode='42501';end if;
 if p_amount is null or p_amount<=0 or nullif(btrim(p_reason),'') is null or p_posted_at is null or not isfinite(p_posted_at) then
  raise exception 'financial_effect_facts_required' using errcode='22023';end if;
 request:=jsonb_build_object('operation','apply','credit',p_credit,'invoice',p_invoice,'amount',p_amount,'reason',p_reason,
 'posted_at',to_char(p_posted_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),'actor',actor,'origin_source_id',coalesce(p_origin_id,p_source));
 perform billing.lock_customer_credit_well(c.well_id);
 r:=billing.credit_event_replay(c.tenant_id,p_source,p_revision,request);if r is not null then return r;end if;
 perform billing.refresh_partition_invoices(c.well_id);
 perform 1 from billing.account_credits where id=c.id for update;
 select * into strict i from billing.invoices where id=p_invoice for update;
 if i.tenant_id<>c.tenant_id or i.well_id<>c.well_id or i.farmer_well_account_id<>c.farmer_well_account_id
  or i.deducted_in_cycle_id is not null or i.status not in ('issued','partially_paid','overdue') then
  raise exception 'credit_invoice_scope_or_state_invalid' using errcode='23514';end if;
 select available_minor into available from billing.account_credit_balances where id=c.id;
 if p_amount>available or p_amount>i.outstanding_minor then raise exception 'credit_application_out_of_range' using errcode='23514';end if;
 insert into billing.account_credit_applications(tenant_id,well_id,farmer_well_account_id,credit_id,invoice_id,event_id,amount_minor,reason,created_by)
 values(c.tenant_id,c.well_id,c.farmer_well_account_id,c.id,i.id,e,p_amount,p_reason,actor) returning id into app;
 j:=billing.post_customer_credit_entry(e,c.tenant_id,c.well_id,c.farmer_well_account_id,p_amount,false,p_posted_at,actor);
 r:=jsonb_build_object('status','accepted','event_id',e,'application_id',app,'applied_minor',p_amount);
 r:=r||jsonb_build_object('invalidated_distribution_cycles',billing.invalidate_pending_credit_distributions(c.well_id));
 insert into billing.customer_credit_events(id,tenant_id,well_id,farmer_well_account_id,source_id,origin_source_id,source_revision,operation,
 request_payload,result_payload,reason,created_by,journal_entry_id)
 values(e,c.tenant_id,c.well_id,c.farmer_well_account_id,p_source,coalesce(p_origin_id,p_source),p_revision,'apply',request,r,p_reason,actor,j);
 perform billing.refresh_partition_invoices(c.well_id);
 return r;
end;$$;
create or replace function billing.adjust_credit_application(p_application uuid,p_operation text,p_amount bigint,
 p_source uuid,p_revision bigint,p_reason text,p_posted_at timestamptz,p_origin_id uuid default null) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare a billing.account_credit_applications%rowtype;c billing.account_credits%rowtype;i billing.invoices%rowtype;
 actor uuid:=auth.uid();req jsonb;r jsonb;e uuid:=gen_random_uuid();adj uuid:=gen_random_uuid();j uuid;
 b record;available numeric;review text;op text;cycles jsonb:='[]'::jsonb;
begin
 select * into strict a from billing.account_credit_applications where id=p_application;
 if actor is null or not coalesce(iam.has_well_permission(a.well_id,'session.correct'),false) then
  raise exception 'application_adjustment_forbidden' using errcode='42501';end if;
 if p_operation is null or p_operation not in ('release','restore') or p_amount is null or p_amount<=0
  or nullif(btrim(p_reason),'') is null or p_posted_at is null or not isfinite(p_posted_at) then
  raise exception 'application_adjustment_facts_required' using errcode='22023';end if;
 op:='application_'||p_operation;
 req:=jsonb_build_object('operation',op,'application_id',p_application,'amount_minor',p_amount,'reason',p_reason,
  'actor',actor,'origin_source_id',coalesce(p_origin_id,p_source),
  'posted_at',to_char(p_posted_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
 perform billing.lock_customer_credit_well(a.well_id);
 r:=billing.credit_event_replay(a.tenant_id,p_source,p_revision,req);if r is not null then return r;end if;
 perform billing.refresh_partition_invoices(c.well_id);
 perform 1 from ops.farmer_well_accounts where id=a.farmer_well_account_id for update;
 select * into strict c from billing.account_credits where id=a.credit_id;
 perform 1 from billing.payments where id=c.payment_id for update;
 perform 1 from billing.account_credits where id=c.id for update;
 perform 1 from billing.account_credit_applications where id=a.id for update;
 select * into strict i from billing.invoices where id=a.invoice_id for update;
 select * into strict b from billing.effective_account_credit_applications where id=a.id;
 select available_minor into available from billing.account_credit_balances where id=c.id;
 if p_operation='release' and p_amount>b.effective_amount_minor
  or p_operation='restore' and p_amount>b.amount_minor-b.effective_amount_minor then
  raise exception 'application_adjustment_out_of_range' using errcode='23514';end if;
 if exists(select 1 from billing.account_credit_reversals where credit_id=c.id and receivable_review_minor>0) then
  review:='source_reversal_review_required';
 elsif i.deducted_in_cycle_id is not null then review:='distribution_reconciliation_required';
 elsif i.status not in ('issued','partially_paid','paid','overdue') then review:='invoice_state_requires_review';
 elsif p_operation='restore' and p_amount>available then review:='credit_unavailable';
 elsif p_operation='restore' and p_amount>i.outstanding_minor then review:='invoice_debt_unavailable';end if;
 if review is null then
  begin
   -- قيد فرق جديد؛ لا عكس للقيد الأصلي أو تغيير لتاريخه. المعاملة الفرعية
   -- تعيد كل أثر مالي عند رفض الفترة، ثم يحفظ طلب المراجعة خارجه.
   j:=billing.post_customer_credit_entry(e,a.tenant_id,a.well_id,a.farmer_well_account_id,
    p_amount,p_operation='release',p_posted_at,actor);
   insert into billing.account_credit_application_adjustments(id,event_id,tenant_id,well_id,farmer_well_account_id,
    application_id,operation,amount_minor,source_id,origin_source_id,source_revision,request_payload,reason,created_by,status,journal_entry_id)
   values(adj,e,a.tenant_id,a.well_id,a.farmer_well_account_id,a.id,p_operation,p_amount,p_source,
    coalesce(p_origin_id,p_source),p_revision,req,p_reason,actor,'accepted',j);
   cycles:=billing.invalidate_pending_credit_distributions(a.well_id);
  exception when raise_exception then
   if SQLERRM like 'لا يمكن ترحيل القيد: الفترة المحاسبية المحتوية للتاريخ % مغلقة' then
    review:='accounting_period_closed';j:=null;
   else raise;end if;
  end;
 end if;
 if review is not null then
  insert into billing.account_credit_application_adjustments(id,event_id,tenant_id,well_id,farmer_well_account_id,
   application_id,operation,amount_minor,source_id,origin_source_id,source_revision,request_payload,reason,created_by,status,review_reason)
  values(adj,e,a.tenant_id,a.well_id,a.farmer_well_account_id,a.id,p_operation,p_amount,p_source,
   coalesce(p_origin_id,p_source),p_revision,req,p_reason,actor,'financial_review_required',review);
 end if;
 select * into strict b from billing.effective_account_credit_applications where id=a.id;
 select available_minor into available from billing.account_credit_balances where id=c.id;
 r:=jsonb_build_object('status',case when review is null then 'accepted' else 'financial_review_required' end,
  'event_id',e,'adjustment_id',adj,'application_id',a.id,'credit_id',c.id,'invoice_id',a.invoice_id,
  'operation',p_operation,'requested_minor',p_amount,'applied_minor',case when review is null then p_amount else 0 end,
  'effective_application_minor',b.effective_amount_minor,'credit_available_minor',available,
  'reason',review,'invalidated_distribution_cycles',cycles);
 insert into billing.customer_credit_events(id,tenant_id,well_id,farmer_well_account_id,source_id,origin_source_id,source_revision,
  operation,request_payload,result_payload,reason,created_by,journal_entry_id)
 values(e,a.tenant_id,a.well_id,a.farmer_well_account_id,p_source,coalesce(p_origin_id,p_source),p_revision,
  op,req,r,p_reason,actor,j);
 perform billing.refresh_partition_invoices(c.well_id);
 return r;
end;$$;

create or replace view reporting.farmer_account_balances with(security_invoker=true) as
select a.tenant_id,a.well_id,a.id as farmer_well_account_id,a.public_code,
 coalesce(i.total_minor,0) as invoiced_minor,coalesce(i.paid_minor,0)+coalesce(d.paid_minor,0) as allocated_minor,
 coalesce(p.available_minor,0) as advance_minor,coalesce(i.debt_minor,0)+coalesce(d.debt_minor,0) as debt_minor,
 coalesce(c.available_minor,0) as noncash_credit_minor,
 coalesce(p.available_minor,0)+coalesce(c.available_minor,0)+coalesce(r.available_minor,0) as available_credit_minor,
 coalesce(d.total_minor,0) as uninvoiced_charge_minor,coalesce(r.available_minor,0) as unapplied_payment_minor
from ops.farmer_well_accounts a
left join(select i.farmer_well_account_id,sum(i.total_minor) as total_minor,sum(b.paid_minor) as paid_minor,
 sum(b.outstanding_minor) as debt_minor from billing.invoices i join billing.invoice_effective_balances b on b.invoice_id=i.id
 where i.status not in ('draft','cancelled','reversed') group by 1)i on i.farmer_well_account_id=a.id
left join(select d.farmer_well_account_id,sum(d.debt_minor) as total_minor,sum(d.settled_minor) as paid_minor,
 sum(d.outstanding_minor) as debt_minor from billing.session_economic_settlements d
 where not exists(select 1 from billing.invoices i where i.session_id=d.session_id and i.status not in ('draft','cancelled','reversed'))
 group by 1)d on d.farmer_well_account_id=a.id
left join(select farmer_well_account_id,sum(remaining_minor) as available_minor from billing.payment_economic_applications
 where purpose='advance' group by 1)p on p.farmer_well_account_id=a.id
left join(select farmer_well_account_id,sum(remaining_minor) as available_minor from billing.payment_economic_applications
 where purpose<>'advance' group by 1)r on r.farmer_well_account_id=a.id
left join(select farmer_well_account_id,sum(available_minor) as available_minor from billing.account_credit_balances group by 1)c on c.farmer_well_account_id=a.id;
create or replace function billing.get_available_customer_credit_read(p_farmer_well_account_id uuid) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,pg_temp as $$
declare w uuid;t uuid;r jsonb;
begin
 if auth.uid() is null then raise exception 'customer_credit_authentication_required' using errcode='28000';end if;
 select a.well_id,well.tenant_id into w,t from ops.farmer_well_accounts a join core.wells well
  on well.id=a.well_id and well.tenant_id=a.tenant_id
  where a.id=p_farmer_well_account_id and exists(select 1 from core.well_assignments wa
   where wa.well_id=well.id and wa.profile_id=auth.uid() and wa.status='active');
 if w is null or not coalesce(iam.has_well_permission(w,'payment.allocate'),false) then
  raise exception 'customer_credit_forbidden' using errcode='42501';end if;
 if exists(select 1 from billing.payment_available_balances where farmer_well_account_id=p_farmer_well_account_id and well_id=w and tenant_id=t and purpose='advance'
   and status='posted' and available_minor<0) or exists(select 1 from billing.account_credit_balances
   where farmer_well_account_id=p_farmer_well_account_id and well_id=w and tenant_id=t and available_minor<0) then
  raise exception 'customer_credit_balance_inconsistent' using errcode='23514';end if;
 select jsonb_build_object('contract','available_customer_credit','version',1,'well_id',w,'farmer_well_account_id',p_farmer_well_account_id,
  'cash_advance_minor',coalesce(sum(available_minor) filter(where source_type='cash_advance'),0),
  'noncash_credit_minor',coalesce(sum(available_minor) filter(where source_type='account_credit'),0),
  'unapplied_payment_minor',coalesce(sum(available_minor) filter(where source_type='payment_remaining'),0),
  'total_available_minor',coalesce(sum(available_minor),0),
  'sources',coalesce(jsonb_agg(to_jsonb(x) order by source_type,source_id),'[]')) into r
 from (
  select 'cash_advance'::text as source_type,p.payment_id as source_id,p.amount_minor as issued_minor,
   p.effective_allocated_minor as used_minor,p.credit_reserved_minor as reserved_minor,p.available_minor,
   null::uuid as origin_source_id,null::bigint as origin_revision,
   0::numeric as reversed_minor,0::numeric as held_minor,0::numeric as receivable_review_minor,null::text as credit_origin
  from billing.payment_available_balances p where p.farmer_well_account_id=p_farmer_well_account_id and p.well_id=w and p.tenant_id=t and p.purpose='advance' and p.status='posted'
  union all
  select 'account_credit',c.id,c.amount_minor,c.used_minor,c.held_minor,c.available_minor,c.origin_source_id,c.source_revision,
   c.reversed_minor,c.held_minor,c.receivable_review_minor,c.source_type
  from billing.account_credit_balances c where c.farmer_well_account_id=p_farmer_well_account_id and c.well_id=w and c.tenant_id=t
  union all
  select 'payment_remaining',p.payment_id,p.amount_minor,p.explicit_allocated_minor+p.effective_direct_minor,p.credit_backed_minor,
   p.remaining_minor,null::uuid,null::bigint,0::numeric,0::numeric,0::numeric,null::text
  from billing.payment_economic_applications p where p.farmer_well_account_id=p_farmer_well_account_id
   and p.well_id=w and p.tenant_id=t and p.purpose<>'advance'
 )x;
 return r;
end;$$;
create or replace function billing.get_customer_credit_proposal_read(p_farmer_well_account_id uuid,p_invoice_id uuid,
 p_source_type text,p_source_id uuid) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,pg_temp as $$
declare sources jsonb;i billing.invoices%rowtype;s jsonb;available bigint;
begin
 sources:=billing.get_available_customer_credit_read(p_farmer_well_account_id);
 select inv.* into i from billing.invoices inv join core.wells well on well.id=inv.well_id and well.tenant_id=inv.tenant_id
  where inv.id=p_invoice_id and inv.farmer_well_account_id=p_farmer_well_account_id
  and inv.well_id=(sources->>'well_id')::uuid
  and inv.status in ('issued','partially_paid','overdue','paid')
  and (p_source_type in ('cash_advance','payment_remaining') or inv.deducted_in_cycle_id is null);
 if not found then raise exception 'customer_credit_invoice_forbidden' using errcode='42501';end if;
 select outstanding_minor into i.outstanding_minor from billing.invoice_effective_balances where invoice_id=i.id;
 if i.outstanding_minor<=0 then raise exception 'customer_credit_invoice_forbidden' using errcode='42501';end if;
 select value into s from jsonb_array_elements(sources->'sources') where value->>'source_type'=p_source_type
  and value->>'source_id'=p_source_id::text;
 if not found then raise exception 'customer_credit_source_forbidden' using errcode='42501';end if;
 available:=(s->>'available_minor')::bigint;
 return jsonb_build_object('source_type',p_source_type,'source_id',p_source_id,'invoice_id',p_invoice_id,
 'available_minor',available,'outstanding_minor',i.outstanding_minor,'proposed_minor',least(available,i.outstanding_minor));
end;$$;
create or replace function api.list_well_sessions(
  p_well_id uuid,
  p_farmer_well_account_id uuid default null,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_unpaid_only boolean default false,
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
  v_limit integer := least(greatest(coalesce(p_limit, 200), 1), 500);
  v_items jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة سجل الجلسات'
      using errcode = '28000';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  -- RLS على core.wells هي مصدر التفويض؛ البئر غير المرئي = رفض صريح.
  if not exists (
    select 1
    from core.wells w
    where w.id = p_well_id
  ) then
    raise exception 'لا توجد صلاحية على هذا البئر'
      using errcode = '42501';
  end if;

  select coalesce(
           jsonb_agg(x.item order by x.started_at desc, x.id),
           '[]'::jsonb
         )
  into v_items
  from (
    select
      s.id,
      s.started_at,
      jsonb_build_object(
        'id', s.id,
        'well_id', s.well_id,
        'status', s.status,
        'started_at', s.started_at,
        'ended_at', s.ended_at,
        'farmer_well_account_id', fwa.id,
        'farmer_public_code', fwa.public_code,
        'farmer_name', per.full_name,
        'farm_id', f.id,
        'farm_name', f.name,
        'pump_id', pm.id,
        'pump_name', pm.name,
        'operator_name', pr.full_name,
        'energy_source', run.energy_source,
        'actual_seconds', case
          -- الجارية بلا مدة فعلية نهائية: null لا تلفيق (ق-37).
          when s.ended_at is null then null
          -- المقفلة: مجموع مقاطعها كلها بما فيها التوقفات (ق-131 البند 7)،
          -- والقديمة بلا مقاطع تغلفها المخزَّن ended_at - started_at.
          when seg.segment_count > 0
            and seg.segments_actual_seconds is not null
            then seg.segments_actual_seconds
          else extract(epoch from (s.ended_at - s.started_at))::bigint
        end,
        'billable_seconds', sc.duration_seconds,
        'total_amount_minor', sc.amount_minor,
        'paid_amount_minor', pay.paid_minor,
        'payment_status', case
          when sc.id is null then 'not_billed'
          when coalesce(pay.paid_minor, 0) >= sc.amount_minor
            and sc.amount_minor > 0 then 'settled'
          when coalesce(pay.paid_minor, 0) > 0 then 'partial'
          else 'unpaid'
        end,
        'has_charge', sc.id is not null,
        'has_invoice', inv.id is not null
      ) as item
    from ops.irrigation_sessions s
    -- كل الانضمامات التالية تزويقية (اسم/رمز) والمصدر الحاكم للتفويض هو
    -- RLS على الجلسة نفسها؛ لذلك LEFT JOIN إجباري: صف تزويق محجوب أو
    -- غير معيّن يجب ألا يُخفي جلسة مرئية.
    left join ops.farms f on f.id = s.farm_id
    left join ops.farmer_well_accounts fwa
      on fwa.id = coalesce(s.farmer_well_account_id, f.farmer_well_account_id)
    left join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
    left join core.persons per on per.id = fp.person_id
    left join core.pumps pm on pm.id = s.pump_id
    left join iam.profiles pr on pr.id = s.operator_profile_id
    left join billing.session_charges sc on sc.session_id = s.id
    left join billing.invoices inv on inv.session_id = s.id
    left join lateral (
      select ss.energy_source
      from ops.session_segments ss
      where ss.session_id = s.id
        and ss.energy_source is not null
      order by ss.sequence_number
      limit 1
    ) run on true
    left join lateral (
      select
        count(*) as segment_count,
        sum(ss.actual_seconds)::bigint as segments_actual_seconds
      from ops.session_segments ss
      where ss.session_id = s.id
    ) seg on true
    left join lateral (
      -- الفاتورة الفعالة إن وجدت، وإلا تسديد charge المقسم اقتصاديًا.
      select (select paid_minor from billing.session_read_settlements where session_charge_id=sc.id) as paid_minor
    ) pay on sc.id is not null
    where s.well_id = p_well_id
      and (
        p_farmer_well_account_id is null
        or fwa.id = p_farmer_well_account_id
      )
      and (p_from is null or s.started_at >= p_from)
      and (p_to is null or s.started_at < p_to)
      and (
        coalesce(p_unpaid_only, false) is not true
        or sc.id is null
        or coalesce(pay.paid_minor, 0) < sc.amount_minor
      )
    order by s.started_at desc, s.id
    limit v_limit
  ) x;

  return jsonb_build_object(
    'contract', 'list_well_sessions',
    'version', 1,
    'items', v_items
  );
end;
$function$;
create or replace function api.get_session_detail(
  p_session_id uuid
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_session jsonb;
  v_segments jsonb;
  v_payment jsonb;
  v_crops jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة تفصيل الجلسة'
      using errcode = '28000';
  end if;

  if p_session_id is null then
    raise exception 'معرّف الجلسة مطلوب'
      using errcode = '22023';
  end if;

  select
    jsonb_build_object(
      'id', s.id,
      'well_id', s.well_id,
      'status', s.status,
      'started_at', s.started_at,
      'ended_at', s.ended_at,
      'farmer_well_account_id', fwa.id,
      'farmer_public_code', fwa.public_code,
      'farmer_name', per.full_name,
      'farm_id', f.id,
      'farm_name', f.name,
      'pump_id', pm.id,
      'pump_name', pm.name,
      'operator_name', pr.full_name,
      'energy_source', run.energy_source,
      'actual_seconds', case
        when s.ended_at is null then null
        when seg.segment_count > 0
          and seg.segments_actual_seconds is not null
          then seg.segments_actual_seconds
        else extract(epoch from (s.ended_at - s.started_at))::bigint
      end,
      'billable_seconds', sc.duration_seconds,
      'total_amount_minor', sc.amount_minor,
      'paid_amount_minor', pay.paid_minor,
      'payment_status', case
        when sc.id is null then 'not_billed'
        when coalesce(pay.paid_minor, 0) >= sc.amount_minor
          and sc.amount_minor > 0 then 'settled'
        when coalesce(pay.paid_minor, 0) > 0 then 'partial'
        else 'unpaid'
      end,
      'has_charge', sc.id is not null,
      'has_invoice', inv.id is not null
    ),
    case
      when last_pay.id is null then null
      else jsonb_build_object(
        'method', last_pay.method,
        'reference', last_pay.public_code,
        'paid_at', last_pay.paid_at
      )
    end
  into v_session, v_payment
  from ops.irrigation_sessions s
  left join ops.farms f on f.id = s.farm_id
  left join ops.farmer_well_accounts fwa
    on fwa.id = coalesce(s.farmer_well_account_id, f.farmer_well_account_id)
  left join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
  left join core.persons per on per.id = fp.person_id
  left join core.pumps pm on pm.id = s.pump_id
  left join iam.profiles pr on pr.id = s.operator_profile_id
  left join billing.session_charges sc on sc.session_id = s.id
  left join billing.invoices inv on inv.session_id = s.id
  left join lateral (
    select ss.energy_source
    from ops.session_segments ss
    where ss.session_id = s.id
      and ss.energy_source is not null
    order by ss.sequence_number
    limit 1
  ) run on true
  left join lateral (
    select
      count(*) as segment_count,
      sum(ss.actual_seconds)::bigint as segments_actual_seconds
    from ops.session_segments ss
    where ss.session_id = s.id
  ) seg on true
  left join lateral (
    select (select paid_minor from billing.session_read_settlements where session_charge_id=sc.id) as paid_minor
  ) pay on sc.id is not null
  left join lateral (
    select p.id, p.method, p.public_code, p.paid_at
    from billing.payments p
    join billing.payment_economic_applications econ on econ.payment_id=p.id
    where p.status = 'posted' and (
      (econ.default_session_charge_id=sc.id and econ.effective_direct_minor>0)
      or exists(select 1 from billing.effective_payment_allocations a
        join billing.invoices target on target.id=a.invoice_id
        where a.payment_id=p.id and target.session_id=s.id and a.effective_allocated_minor>0
          and econ.explicit_allocated_minor>0)
      or exists(select 1 from billing.effective_account_credit_applications a
        join billing.account_credits c on c.id=a.credit_id
        join billing.invoices target on target.id=a.invoice_id
        where c.payment_id=p.id and target.session_id=s.id and a.effective_amount_minor>0
          and econ.credit_backed_minor>0)
    )
    order by p.paid_at desc, p.id
    limit 1
  ) last_pay on sc.id is not null
  where s.id = p_session_id;

  -- الجلسة غير المرئية عبر RLS = رفض صريح بدل مغلّف فارغ غامض.
  if v_session is null then
    raise exception 'لا توجد صلاحية على هذه الجلسة'
      using errcode = '42501';
  end if;

  select coalesce(
           jsonb_agg(
             jsonb_build_object(
               'sequence_number', ss.sequence_number,
               'segment_type', ss.segment_type,
               'is_stop', ss.segment_type not in (
                 'solar_run', 'well_diesel_run', 'farmer_diesel_run'
               ),
               'is_billable', ss.is_billable,
               'energy_source', ss.energy_source,
               'started_at', ss.started_at,
               'ended_at', ss.ended_at,
               'actual_seconds', ss.actual_seconds,
               'billable_seconds', ss.billable_seconds,
               'applied_rate_minor', coalesce(
                 ss.applied_operation_rate_minor,
                 ss.applied_hourly_rate_minor
               ),
               'time_charge_minor', ss.time_charge_minor,
               'fuel_charge_minor', ss.fuel_charge_minor,
               'total_charge_minor', ss.total_charge_minor,
               'notes', ss.notes
             )
             order by ss.sequence_number
           ),
           '[]'::jsonb
         )
  into v_segments
  from ops.session_segments ss
  where ss.session_id = p_session_id;

  -- المحاصيل كما اختيرت وقت بدء هذه الجلسة (لقطة مستقلة لا تتبع الأرض).
  select coalesce(
           jsonb_agg(sc.crop_name order by sc.position),
           '[]'::jsonb
         )
  into v_crops
  from ops.session_crops sc
  where sc.session_id = p_session_id;

  return jsonb_build_object(
    'contract', 'get_session_detail',
    'version', 1,
    'session', v_session,
    'segments', v_segments,
    'crops', v_crops,
    'payment', v_payment
  );
end;
$function$;
create or replace function api.get_farmer_account(
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
  v_account jsonb;
  v_invoices jsonb;
  v_payments jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة حساب المزارع'
      using errcode = '28000';
  end if;

  if p_farmer_well_account_id is null then
    raise exception 'معرّف حساب المزارع مطلوب'
      using errcode = '22023';
  end if;

  -- RLS على ops.farmer_well_accounts هي مصدر التفويض؛ الحساب غير المرئي
  -- = رفض صريح بدل كائن فارغ غامض.
  select jsonb_build_object(
    'id', fwa.id,
    'well_id', fwa.well_id,
    'public_code', fwa.public_code,
    'full_name', p.full_name,
    'phone', (
      select pc.contact_value
      from core.person_contacts pc
      where pc.person_id = p.id
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
    'credit_limit_minor', fwa.credit_limit_minor,
    'invoiced_minor', coalesce(b.invoiced_minor, 0),
    'allocated_minor', coalesce(b.allocated_minor, 0),
    'total_debt_minor', coalesce(b.debt_minor, 0),
    'advance_balance_minor', coalesce(b.advance_minor, 0),
    'noncash_credit_minor',coalesce(b.noncash_credit_minor,0),
    'unapplied_payment_minor',coalesce(b.unapplied_payment_minor,0),
    'uninvoiced_charge_minor',coalesce(b.uninvoiced_charge_minor,0),
    'available_credit_minor',coalesce(b.available_credit_minor,0)
  )
  into v_account
  from ops.farmer_well_accounts fwa
  join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
  join core.persons p on p.id = fp.person_id
  left join reporting.farmer_account_balances b
    on b.farmer_well_account_id = fwa.id
  where fwa.id = p_farmer_well_account_id;

  if v_account is null then
    raise exception 'لا توجد صلاحية على حساب هذا المزارع'
      using errcode = '42501';
  end if;

  select coalesce(
    jsonb_agg(x.item order by x.invoice_date desc, x.id desc),
    '[]'::jsonb
  )
  into v_invoices
  from (
    select
      i.id,
      i.invoice_date,
      jsonb_build_object(
        'id', i.id,
        'invoice_number', i.public_code,
        'issue_date', i.invoice_date,
        'due_date', i.due_date,
        'session_id', i.session_id,
        'farm_name', f.name,
        'original_amount_minor', i.total_minor,
        'paid_amount_minor', (select paid_minor from billing.invoice_effective_balances where invoice_id=i.id),
        'outstanding_minor', (select outstanding_minor from billing.invoice_effective_balances where invoice_id=i.id),
        'settlement_method', i.settlement_method,
        'status', i.status
      ) as item
    from billing.invoices i
    left join ops.irrigation_sessions s on s.id = i.session_id
    left join ops.farms f on f.id = s.farm_id
    where i.farmer_well_account_id = p_farmer_well_account_id
    order by i.invoice_date desc, i.id desc
    limit v_limit
  ) x;

  select coalesce(
    jsonb_agg(x.item order by x.paid_at desc, x.id desc),
    '[]'::jsonb
  )
  into v_payments
  from (
    select
      pay.id,
      pay.paid_at,
      jsonb_build_object(
        'id', pay.id,
        'receipt_number', pay.public_code,
        'paid_at', pay.paid_at,
        'amount_minor', pay.amount_minor,
        'method', pay.method,
        'purpose', pay.purpose,
        'status', pay.status,
        'note', pay.note,
        'economic_application',(select to_jsonb(e) from billing.payment_economic_applications e where e.payment_id=pay.id),
        'effective_allocations',(select coalesce(jsonb_agg(jsonb_build_object(
          'allocation_id',ea.id,'invoice_id',ea.invoice_id,'original_minor',ea.allocated_minor,
          'effective_minor',ea.effective_allocated_minor,'released_minor',ea.released_minor) order by ea.id),'[]')
          from billing.effective_payment_allocations ea where ea.payment_id=pay.id),
        'allocated_invoices', (
          select coalesce(
            jsonb_agg(inv.public_code order by inv.public_code),
            '[]'::jsonb
          )
          from billing.payment_allocations pa
          join billing.invoices inv on inv.id = pa.invoice_id
          where pa.payment_id = pay.id
        )
      ) as item
    from billing.payments pay
    where pay.status <> 'reversed'
      and (
        pay.farmer_well_account_id = p_farmer_well_account_id
        or exists (
          select 1
          from billing.payment_allocations pa2
          join billing.invoices inv2 on inv2.id = pa2.invoice_id
          where pa2.payment_id = pay.id
            and inv2.farmer_well_account_id = p_farmer_well_account_id
        )
      )
    order by pay.paid_at desc, pay.id desc
    limit v_limit
  ) x;

  return jsonb_build_object(
    'contract', 'get_farmer_account',
    'version', 1,
    'account', v_account,
    'invoices', v_invoices,
    'payments', v_payments
  );
end;
$function$;

create or replace function billing.issue_session_invoice(
  p_session_id uuid,
  p_issued_by uuid
)
returns uuid
language plpgsql
security definer
set search_path to 'billing', 'ops', 'finance', 'core', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_well_id uuid;
  v_farmer_well_account_id uuid;
  v_session_status text;
  v_ended_at timestamptz;
  v_charge_amount bigint;
  v_invoice_id uuid;
  v_partner_policy_id uuid;
  v_partner_policy_type text;
  v_settlement_method text := 'normal';
  v_line_number integer := 0;
  v_lines_total bigint;
  v_segment record;
  v_time_rate bigint;
  v_fuel_quantity bigint;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إصدار فاتورة الجلسة';
  end if;
  if p_issued_by is distinct from v_actor then
    raise exception 'مصدر الفاتورة يجب أن يطابق المستخدم المسجل حاليًا';
  end if;

  select well_id into v_well_id from ops.irrigation_sessions where id=p_session_id;
  if not coalesce(iam.has_well_permission(v_well_id,'invoice.issue'),false) then
   raise exception 'لا تملك صلاحية إصدار فاتورة هذه الجلسة';end if;
  perform billing.lock_customer_credit_well(v_well_id);
  select w.tenant_id, s.well_id, s.farmer_well_account_id,
         s.status, s.ended_at
  into v_tenant_id, v_well_id, v_farmer_well_account_id,
       v_session_status, v_ended_at
  from ops.irrigation_sessions s
  join core.wells w on w.id = s.well_id
  where s.id = p_session_id
  for update of s;

  if not found then
    raise exception 'جلسة السقي غير موجودة: %', p_session_id;
  end if;
  if v_session_status <> 'closed' then
    raise exception 'لا يمكن إصدار فاتورة قبل إكمال الجلسة';
  end if;
  if not iam.has_well_permission(v_well_id, 'invoice.issue') then
    raise exception 'لا تملك صلاحية إصدار فاتورة هذه الجلسة';
  end if;
  if v_farmer_well_account_id is null then
    raise exception 'لا يمكن إصدار الفاتورة لأن الجلسة غير مرتبطة بحساب مزارع';
  end if;
  if exists (
    select 1 from billing.invoices i
    where i.session_id = p_session_id
      and i.status not in ('cancelled', 'reversed')
  ) then
    raise exception 'توجد فاتورة سارية مسبقًا لهذه الجلسة';
  end if;
  if not exists (
    select 1 from ops.session_segments ss
    where ss.session_id = p_session_id
      and ss.ended_at is not null
  ) then
    raise exception 'لا توجد مقاطع مكتملة يمكن بناء بنود الفاتورة منها';
  end if;

  select sc.amount_minor
  into v_charge_amount
  from billing.session_charges sc
  where sc.session_id = p_session_id
    and sc.pricing_mode = 'segments';

  if not found then
    raise exception 'لا يوجد ملخص تكلفة مقاطع مكتمل لهذه الجلسة';
  end if;

  select pip.id, pip.policy_type
  into v_partner_policy_id, v_partner_policy_type
  from ops.farmer_well_accounts fwa
  join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
  join core.well_partners wp
    on wp.well_id = fwa.well_id and wp.person_id = fp.person_id
  join core.partner_irrigation_policies pip
    on pip.partner_id = wp.id and pip.well_id = fwa.well_id
  where fwa.id = v_farmer_well_account_id
    and pip.period_start <= v_ended_at::date
    and (pip.period_end is null or pip.period_end > v_ended_at::date)
  order by pip.period_start desc, pip.created_at desc, pip.id desc
  limit 1;

  if found and v_partner_policy_type = 'deduct_from_profit' then
    v_settlement_method := 'partner_profit_offset';
  end if;

  insert into billing.invoices (
    tenant_id, public_code, well_id, farmer_well_account_id,
    session_id, invoice_date, status, subtotal_minor, total_minor,
    paid_minor, outstanding_minor, settlement_method, partner_policy_id
  ) values (
    v_tenant_id, core.generate_public_code('INV'), v_well_id,
    v_farmer_well_account_id, p_session_id, v_ended_at, 'draft',
    v_charge_amount, v_charge_amount, 0, v_charge_amount,
    v_settlement_method, v_partner_policy_id
  )
  returning id into v_invoice_id;

  for v_segment in
    select ss.id, ss.sequence_number, ss.segment_type, ss.energy_source,
           ss.billable_seconds, ss.applied_hourly_rate_minor,
           ss.applied_operation_rate_minor,
           ss.applied_fuel_price_per_liter_minor,
           ss.fuel_actual_ml, ss.fuel_estimated_ml,
           ss.time_charge_minor, ss.fuel_charge_minor,
           ss.total_charge_minor
    from ops.session_segments ss
    where ss.session_id = p_session_id
      and ss.is_billable
      and ss.total_charge_minor > 0
    order by ss.sequence_number
  loop
    if v_segment.time_charge_minor > 0 then
      v_line_number := v_line_number + 1;
      v_time_rate := coalesce(v_segment.applied_operation_rate_minor,
                              v_segment.applied_hourly_rate_minor);

      insert into billing.invoice_lines (
        tenant_id, invoice_id, line_number, line_type, description,
        quantity, unit, unit_price_minor, amount_minor,
        session_segment_id
      ) values (
        v_tenant_id, v_invoice_id, v_line_number,
        case when v_segment.energy_source = 'solar'
          then 'solar_irrigation' else 'diesel_operation' end,
        case when v_segment.energy_source = 'solar'
          then 'سقي شمسي — المقطع ' || v_segment.sequence_number
          else 'تشغيل ديزل — المقطع ' || v_segment.sequence_number end,
        v_segment.billable_seconds::numeric / 3600,
        'hour', v_time_rate, v_segment.time_charge_minor,
        v_segment.id
      );
    end if;

    if v_segment.fuel_charge_minor > 0 then
      v_line_number := v_line_number + 1;
      v_fuel_quantity := coalesce(v_segment.fuel_actual_ml,
                                  v_segment.fuel_estimated_ml);

      insert into billing.invoice_lines (
        tenant_id, invoice_id, line_number, line_type, description,
        quantity, unit, unit_price_minor, amount_minor,
        session_segment_id
      ) values (
        v_tenant_id, v_invoice_id, v_line_number, 'diesel_fuel',
        'وقود ديزل — المقطع ' || v_segment.sequence_number,
        v_fuel_quantity::numeric / 1000,
        'liter', v_segment.applied_fuel_price_per_liter_minor,
        v_segment.fuel_charge_minor, v_segment.id
      );
    end if;
  end loop;

  if v_line_number = 0 then
    raise exception 'لم تنتج مقاطع الجلسة أي بند قابل للفوترة';
  end if;

  select coalesce(sum(il.amount_minor), 0)
  into v_lines_total
  from billing.invoice_lines il
  where il.invoice_id = v_invoice_id;

  if v_lines_total <> v_charge_amount then
    raise exception 'مجموع بنود الفاتورة % لا يساوي تكلفة الجلسة %',
      v_lines_total, v_charge_amount;
  end if;

  update billing.invoices
  set status = 'issued',
      issued_at = clock_timestamp(),
      issued_by = p_issued_by
  where id = v_invoice_id;

  perform billing.refresh_partition_invoices(v_well_id);
  return v_invoice_id;
end;
$function$;
create or replace function billing.reverse_payment(p_payment_id uuid, p_reason text, p_reversed_by uuid default null)
returns uuid
language plpgsql
security definer
set search_path = 'billing', 'finance', 'core', 'pg_temp'
as $function$
declare
  v_pay billing.payments%rowtype;
  v_rev uuid;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'سبب العكس مطلوب';
  end if;

  perform billing.lock_customer_credit_well((select well_id from billing.payments where id=p_payment_id));
  select * into v_pay from billing.payments where id = p_payment_id for update;
  if not found then
    raise exception 'الدفعة غير موجودة: %', p_payment_id;
  end if;
  if v_pay.status <> 'posted' then
    raise exception 'لا يمكن عكس دفعة حالتها % — يجب ان تكون مرحلة', v_pay.status;
  end if;

  if v_pay.journal_entry_id is not null then
    v_rev := finance.reverse_journal_entry(v_pay.journal_entry_id, 'عكس دفعة ' || coalesce(v_pay.public_code, v_pay.id::text) || ': ' || p_reason, p_reversed_by);
  end if;

  update billing.payments
  set status = 'reversed',
      note = coalesce(note || ' | ', '') || 'معكوسة: ' || p_reason,
      updated_at = now()
  where id = v_pay.id;

  perform billing.refresh_partition_invoices(v_pay.well_id);
  return v_rev;
end;
$function$;
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
  select b.outstanding_minor
  into v_invoice
  from billing.invoices i join billing.invoice_effective_balances b on b.invoice_id=i.id
  where i.id = p_invoice_id
    and i.well_id = v_payment.well_id
    and i.farmer_well_account_id = v_payment.farmer_well_account_id
    and i.status in ('issued', 'partially_paid', 'overdue','paid') and b.outstanding_minor>0;

  if v_invoice.outstanding_minor is null then
    raise exception 'الفاتورة غير صالحة للتسديد من الرصيد المقدم'
      using errcode = '42501';
  end if;

  -- المتبقي من السند من المخزَّن: المبلغ ناقص مجموع التخصيصات المخزَّنة.
  select b.available_minor into v_advance_remaining
  from billing.payment_available_balances b where b.payment_id=p_payment_id;

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
-- أصل charge لا يتحول إلى جلسة أخرى؛ تغيير المبلغ ليس محظورًا بهذه الحماية.
create function billing.guard_charge_destination_identity() returns trigger
language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
begin
 perform billing.lock_customer_credit_well(old.well_id);
 if (new.session_id,new.well_id) is distinct from(old.session_id,old.well_id) and exists(
  select 1 from billing.payments where session_charge_id=old.id) then
  raise exception 'charge_destination_identity_immutable' using errcode='23514';end if;return new;
end;$$;
create trigger charge_destination_identity before update on billing.session_charges
 for each row execute function billing.guard_charge_destination_identity();
revoke all on function billing.guard_charge_destination_identity() from public,anon,authenticated,service_role;
create function billing.serialize_partition_invoice_change() returns trigger
language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
begin
 if new.inserted_settlement_snapshot_minor is distinct from old.inserted_settlement_snapshot_minor then
  raise exception 'original_invoice_settlement_snapshot_immutable' using errcode='23514';end if;
 perform billing.lock_customer_credit_well(least(old.well_id,new.well_id));
 if old.well_id<>new.well_id then perform billing.lock_customer_credit_well(greatest(old.well_id,new.well_id));end if;
 return new;
end;$$;
create trigger partition_invoice_serialization before update of total_minor,nonallocation_paid_minor,inserted_settlement_snapshot_minor,status,session_id,well_id,farmer_well_account_id
 on billing.invoices for each row execute function billing.serialize_partition_invoice_change();
revoke all on function billing.serialize_partition_invoice_change() from public,anon,authenticated,service_role;

-- عدادات الفواتير مشتقة؛ لا مبلغ فاتورة أو قيد تاريخي يُعدّل.
do $refresh$ declare w uuid;begin
 for w in select distinct well_id from billing.payments where status='posted' and purpose='session' order by well_id loop
  perform billing.lock_customer_credit_well(w);perform billing.refresh_partition_invoices(w);end loop;
end;$refresh$;
commit;
