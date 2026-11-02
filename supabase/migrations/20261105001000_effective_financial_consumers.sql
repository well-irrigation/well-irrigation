begin;
-- R6-C0: ربط المستهلكين الحاليين بالقيمة الفعالة، دون تغيير سجلات القبض.

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

  select b.available_minor into strict v_available
  from billing.payment_available_balances b where b.payment_id=p_payment_id;
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

    perform billing.refresh_effective_invoice(v_invoice_id);

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

  if (select available_minor from billing.payment_available_balances where payment_id=p_payment_id)<0 then
    raise exception 'payment_effective_availability_negative' using errcode='23514';
  end if;

  return jsonb_build_object(
    'payment_id', p_payment_id,
    'allocated_minor', v_requested_total,
    'remaining_available_minor', v_available - v_requested_total,
    'allocations', v_result_items
  );
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
        'remaining_minor', p.amount_minor - coalesce(alloc.allocated_minor, 0) - coalesce(alloc.credit_reserved_minor,0),
        'is_exhausted',
          (p.amount_minor - coalesce(alloc.allocated_minor, 0) - coalesce(alloc.credit_reserved_minor,0)) <= 0,
        'note', p.note
      )||case when coalesce(alloc.credit_reserved_minor,0)>0 then
        jsonb_build_object('credit_reserved_minor',alloc.credit_reserved_minor) else '{}'::jsonb end as item
    from billing.payments p
    left join lateral (
      select b.effective_allocated_minor as allocated_minor,b.credit_reserved_minor
      from billing.payment_available_balances b where b.payment_id=p.id
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

create or replace view reporting.farmer_account_balances with (security_invoker=true) as
select a.tenant_id,a.well_id,a.id as farmer_well_account_id,a.public_code,
 coalesce(i.total_billed,0) as invoiced_minor,coalesce(i.settled_minor,0) as allocated_minor,
 coalesce(p.available_minor,0) as advance_minor,coalesce(i.debt_minor,0) as debt_minor,
 coalesce(c.available_minor,0) as noncash_credit_minor,
 coalesce(p.available_minor,0)+coalesce(c.available_minor,0) as available_credit_minor
from ops.farmer_well_accounts a
left join(select farmer_well_account_id,sum(total_minor) as total_billed,sum(paid_minor) as settled_minor,
 sum(outstanding_minor) as debt_minor from billing.invoices where status not in ('cancelled','reversed') group by 1)i on i.farmer_well_account_id=a.id
left join(select farmer_well_account_id,sum(available_minor) as available_minor from billing.payment_available_balances
 where purpose='advance' and status='posted' group by 1)p on p.farmer_well_account_id=a.id
left join(select farmer_well_account_id,sum(available_minor) as available_minor from billing.account_credit_balances group by 1)c on c.farmer_well_account_id=a.id;

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
        'paid_amount_minor', i.paid_minor,
        'outstanding_minor', i.outstanding_minor,
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

create or replace function api.get_farmer_selection_status(
  p_farmer_well_account_id uuid
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_account record;
  v_fuel_ml bigint;
  v_result jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة حالة المزارع'
      using errcode = '28000';
  end if;

  if p_farmer_well_account_id is null then
    raise exception 'معرّف حساب المزارع مطلوب'
      using errcode = '22023';
  end if;

  -- الحساب غير المرئي عبر RLS أو غير الموجود = رفض صريح واحد بلا
  -- تسريب وجود (نمط 090).
  select fwa.id, fwa.well_id
  into v_account
  from ops.farmer_well_accounts fwa
  where fwa.id = p_farmer_well_account_id;

  if v_account.id is null
     or not exists (
       select 1
       from core.wells w
       where w.id = v_account.well_id
     ) then
    raise exception 'لا توجد صلاحية على هذا حساب المزارع'
      using errcode = '42501';
  end if;

  -- كمية ديزل المزارع عبر القارئ الغرضي المعتمد (بابت الجلسة نفسه).
  v_fuel_ml := inventory.farmer_selection_fuel_ml(p_farmer_well_account_id);

  -- المال من عرض الأرصدة الحاكم كما هو: لا حساب في العقد ولا في العميل
  -- (ق-99)، والصفر الحقيقي صفر لا غياب مُصطنع.
  select jsonb_build_object(
    'contract', 'get_farmer_selection_status',
    'version', 1,
    'farmer_well_account_id', v_account.id,
    'well_id', v_account.well_id,
    'debt_minor', coalesce(max(b.debt_minor), 0),
    'advance_minor', coalesce(max(b.advance_minor), 0),
    'noncash_credit_minor',coalesce(max(b.noncash_credit_minor),0),
    'available_credit_minor',coalesce(max(b.available_credit_minor),0),
    'farmer_fuel_balance_ml', coalesce(v_fuel_ml, 0)
  )
  into v_result
  from reporting.farmer_account_balances b
  where b.farmer_well_account_id = v_account.id
    and b.well_id = v_account.well_id;

  return v_result;
end;
$function$;

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
    'noncash_credit_minor',coalesce(b.noncash_credit_minor,0),
        'available_credit_minor',coalesce(b.available_credit_minor,0),
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

create or replace function api.list_well_farmer_balances(
  p_well_id uuid,
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
    raise exception 'يجب تسجيل الدخول قبل قراءة أرصدة المزارعين'
      using errcode = '28000';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  if not exists (
    select 1
    from core.wells w
    where w.id = p_well_id
  ) then
    raise exception 'لا توجد صلاحية على هذا البئر'
      using errcode = '42501';
  end if;

  select coalesce(
    jsonb_agg(x.item order by x.debt_minor desc, x.full_name, x.id),
    '[]'::jsonb
  )
  into v_items
  from (
    select
      b.farmer_well_account_id as id,
      b.debt_minor,
      pe.full_name,
      jsonb_build_object(
        'farmer_well_account_id', b.farmer_well_account_id,
        'public_code', b.public_code,
        'full_name', pe.full_name,
        'status', fwa.status,
        'invoiced_minor', b.invoiced_minor,
        'allocated_minor', b.allocated_minor,
        'advance_minor', b.advance_minor,
    'noncash_credit_minor',b.noncash_credit_minor,
        'available_credit_minor',b.available_credit_minor,
        'debt_minor', b.debt_minor
      ) as item
    from reporting.farmer_account_balances b
    join ops.farmer_well_accounts fwa on fwa.id = b.farmer_well_account_id
    left join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
    left join core.persons pe on pe.id = fp.person_id
    where b.well_id = p_well_id
    order by b.debt_minor desc, pe.full_name, b.farmer_well_account_id
    limit v_limit
  ) x;

  return jsonb_build_object(
    'contract', 'list_well_farmer_balances',
    'version', 1,
    'well_id', p_well_id,
    'items', v_items
  );
end;
$function$;

create or replace function ops.check_debt_thresholds()
returns jsonb
language plpgsql
security definer
set search_path = 'ops', 'reporting', 'billing', 'core', 'iam', 'auth', 'pg_temp'
as $function$
declare
  v_actor_id uuid := auth.uid();
  v_account record;
  v_outstanding_minor bigint;
  v_inserted integer;
  v_accounts_checked integer := 0;
  v_accounts_over_limit integer := 0;
  v_notifications_created integer := 0;
begin
  for v_account in
    select
      a.id as account_id,
      a.well_id,
      a.credit_limit_minor,
      p.full_name as farmer_name,
      coalesce(b.debt_minor, 0) as debt_minor,
      coalesce(b.available_credit_minor, 0) as advance_minor
    from ops.farmer_well_accounts a
    join ops.farmer_profiles fp on fp.id = a.farmer_profile_id
    join core.persons p on p.id = fp.person_id
    join core.wells w on w.id = a.well_id
    left join reporting.farmer_account_balances b
      on b.farmer_well_account_id = a.id
    where a.status = 'active'
      and fp.status = 'active'
      and p.status = 'active'
      and w.status = 'active'
      and a.credit_limit_minor is not null
      and (
        v_actor_id is null
        or exists (
          select 1
          from core.well_assignments mine
          where mine.well_id = a.well_id
            and mine.profile_id = v_actor_id
            and mine.status = 'active'
            and mine.role in ('owner', 'manager')
        )
      )
    order by a.id
  loop
    v_accounts_checked := v_accounts_checked + 1;
    v_outstanding_minor := greatest(
      v_account.debt_minor - v_account.advance_minor,
      0
    );

    if v_outstanding_minor > v_account.credit_limit_minor then
      v_accounts_over_limit := v_accounts_over_limit + 1;

      insert into ops.notifications (
        recipient_profile_id, well_id, type, message, deduplication_key
      )
      select distinct
        wa.profile_id,
        v_account.well_id,
        'debt_threshold_exceeded',
        format(
          'المزارع %s تجاوز حد الدين: ذمته %s والحد %s',
          v_account.farmer_name,
          v_outstanding_minor,
          v_account.credit_limit_minor
        ),
        format('debt:%s:%s', v_account.account_id, current_date)
      from core.well_assignments wa
      where wa.well_id = v_account.well_id
        and wa.status = 'active'
        and wa.role in ('owner', 'manager')
      on conflict (recipient_profile_id, type, deduplication_key)
        where deduplication_key is not null
        do nothing;

      get diagnostics v_inserted = row_count;
      v_notifications_created := v_notifications_created + v_inserted;
    end if;
  end loop;

  return jsonb_build_object(
    'day', current_date,
    'accounts_checked', v_accounts_checked,
    'accounts_over_limit', v_accounts_over_limit,
    'notifications_created', v_notifications_created
  );
end;
$function$;

-- قراءة موحدة جديدة؛ عقد المقدم النقدي القديم يبقى بوسائطه ونتيجته القديمة.
create function billing.get_available_customer_credit_read(p_farmer_well_account_id uuid) returns jsonb
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
  'total_available_minor',coalesce(sum(available_minor),0),
  'sources',coalesce(jsonb_agg(to_jsonb(x) order by source_type,source_id),'[]')) into r
 from (
  select 'cash_advance'::text as source_type,p.payment_id as source_id,p.amount_minor as issued_minor,
   p.effective_allocated_minor as used_minor,p.credit_reserved_minor as reserved_minor,p.available_minor,
   null::uuid as origin_source_id,null::bigint as origin_revision,
   0::numeric as reversed_minor,0::numeric as held_minor,0::numeric as receivable_review_minor
  from billing.payment_available_balances p where p.farmer_well_account_id=p_farmer_well_account_id and p.well_id=w and p.tenant_id=t and p.purpose='advance' and p.status='posted'
  union all
  select 'account_credit',c.id,c.amount_minor,c.used_minor,c.held_minor,c.available_minor,c.origin_source_id,c.source_revision,
   c.reversed_minor,c.held_minor,c.receivable_review_minor
  from billing.account_credit_balances c where c.farmer_well_account_id=p_farmer_well_account_id and c.well_id=w and c.tenant_id=t
 )x;
 return r;
end;$$;
create function billing.get_customer_credit_proposal_read(p_farmer_well_account_id uuid,p_invoice_id uuid,
 p_source_type text,p_source_id uuid) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,pg_temp as $$
declare sources jsonb;i billing.invoices%rowtype;s jsonb;available bigint;
begin
 sources:=billing.get_available_customer_credit_read(p_farmer_well_account_id);
 select inv.* into i from billing.invoices inv join core.wells well on well.id=inv.well_id and well.tenant_id=inv.tenant_id
  where inv.id=p_invoice_id and inv.farmer_well_account_id=p_farmer_well_account_id
  and inv.well_id=(sources->>'well_id')::uuid
  and inv.status in ('issued','partially_paid','overdue')
  and (p_source_type='cash_advance' or inv.deducted_in_cycle_id is null);
 if not found then raise exception 'customer_credit_invoice_forbidden' using errcode='42501';end if;
 select value into s from jsonb_array_elements(sources->'sources') where value->>'source_type'=p_source_type
  and value->>'source_id'=p_source_id::text;
 if not found then raise exception 'customer_credit_source_forbidden' using errcode='42501';end if;
 available:=(s->>'available_minor')::bigint;
 return jsonb_build_object('source_type',p_source_type,'source_id',p_source_id,'invoice_id',p_invoice_id,
 'available_minor',available,'outstanding_minor',i.outstanding_minor,'proposed_minor',least(available,i.outstanding_minor));
end;$$;
create function api.get_available_customer_credit(p_farmer_well_account_id uuid) returns jsonb
language sql stable security invoker set search_path=pg_catalog,pg_temp as $$
 select billing.get_available_customer_credit_read(p_farmer_well_account_id);
$$;
create function api.get_customer_credit_proposal(p_farmer_well_account_id uuid,p_invoice_id uuid,
 p_source_type text,p_source_id uuid) returns jsonb
language sql stable security invoker set search_path=pg_catalog,pg_temp as $$
 select billing.get_customer_credit_proposal_read(p_farmer_well_account_id,p_invoice_id,p_source_type,p_source_id);
$$;
revoke all on function billing.get_available_customer_credit_read(uuid),billing.get_customer_credit_proposal_read(uuid,uuid,text,uuid)
 from public,anon,authenticated,service_role;
grant execute on function billing.get_available_customer_credit_read(uuid),billing.get_customer_credit_proposal_read(uuid,uuid,text,uuid)
 to authenticated,service_role;
revoke all on function api.get_available_customer_credit(uuid),api.get_customer_credit_proposal(uuid,uuid,text,uuid)
 from public,anon,authenticated,service_role;
grant execute on function api.get_available_customer_credit(uuid),api.get_customer_credit_proposal(uuid,uuid,text,uuid)
 to authenticated,service_role;

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
  v_customer_credit bigint;
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

  -- رصيد مصدره قبض غير مقدم أصبح التزامًا. المقدم النقدي مستبعد أصلًا من التحصيل.
  -- المحجوز للمراجعة يظل التزامًا؛ المستهلك/المعاد للتخصيص لا يحجز ثانية.
  select coalesce(sum(c.amount_minor-c.used_minor-c.reversed_minor),0) into v_customer_credit
  from billing.account_credit_balances c join billing.payments p on p.id=c.payment_id
  where c.well_id=p_well_id and p.purpose<>'advance' and p.status='posted';
  return v_partners + v_payroll + v_customer_credit;
end;
$function$;

create or replace function finance.calculate_profit_distribution(
  p_well_id uuid, p_period_start timestamptz, p_period_end timestamptz,
  p_calculated_by uuid default null, p_manual_reserve_minor bigint default 0
) returns uuid language plpgsql security definer
set search_path to 'finance', 'billing', 'inventory', 'core', 'ops', 'pg_temp' as $$
declare
  v_tenant uuid;
  v_cycle uuid;
  v_collected bigint;
  v_expenses bigint;
  v_liabilities bigint := 0;
  v_reserve bigint := 0;
  v_distributable bigint;
  v_total_pct numeric;
  v_withhold boolean;
  v_rule record;
  v_rule_found boolean;
  v_share record;
  v_gross bigint;
  v_remaining bigint;
  v_max_pct numeric := -1;
  v_max_partner uuid;
  v_receivables bigint;
  v_irrigation bigint;
begin
  perform billing.lock_customer_credit_well(p_well_id);
  if p_period_end <= p_period_start then
    raise exception 'نهاية الفترة يجب ان تكون بعد بدايتها';
  end if;
  select tenant_id into v_tenant from core.wells where id = p_well_id;

  if exists (select 1 from finance.profit_distribution_cycles c
             where c.well_id = p_well_id and c.status not in ('paid', 'cancelled')
               and tstzrange(c.period_start, c.period_end) && tstzrange(p_period_start, p_period_end)) then
    raise exception 'توجد دورة توزيع متداخلة غير مغلقة لهذا البئر';
  end if;

  select coalesce(sum(p.amount_minor), 0) into v_collected
  from billing.payments p
  where p.well_id = p_well_id and p.status = 'posted' and p.purpose <> 'advance'
    and p.paid_at >= p_period_start and p.paid_at < p_period_end;

  select coalesce((
    select sum(x.amt) from (
      select fp.cost_minor as amt from inventory.fuel_purchases fp
      where fp.well_id = p_well_id and fp.purchased_at >= p_period_start and fp.purchased_at < p_period_end
      union all
      select e.amount_minor from finance.expenses e
      where e.well_id = p_well_id and e.status = 'posted'
        and e.spent_at >= p_period_start and e.spent_at < p_period_end
    ) x
  ), 0) into v_expenses;

  select withhold_liabilities into v_withhold from finance.distribution_settings where well_id = p_well_id;
  if coalesce(v_withhold, true) then
    v_liabilities := finance.compute_reserved_liabilities(p_well_id);
  end if;

  -- الاحتياطي: found وليس "سجل is not null" (الاخير خطان مع الحقول الفارغة)
  select * into v_rule from finance.maintenance_reserve_rules r
  where r.well_id = p_well_id and r.effective_period @> p_period_end::date
  order by r.created_at desc limit 1;
  v_rule_found := found;
  if v_rule_found then
    if v_rule.reserve_type = 'percentage_of_collections' then
      v_reserve := round(v_collected * v_rule.reserve_percentage / 100);
    elsif v_rule.reserve_type = 'percentage_of_profit' then
      v_reserve := round(greatest(v_collected - v_expenses, 0) * v_rule.reserve_percentage / 100);
    elsif v_rule.reserve_type = 'fixed_amount' then
      v_reserve := coalesce(v_rule.fixed_amount_minor, 0);
    elsif v_rule.reserve_type = 'manual_per_cycle' then
      v_reserve := coalesce(p_manual_reserve_minor, 0);
    end if;
  end if;

  v_distributable := greatest(v_collected - v_expenses - v_liabilities - v_reserve, 0);

  select coalesce(sum(v.profit_percentage), 0) into v_total_pct
  from core.ownership_share_versions v
  where v.well_id = p_well_id and v.effective_period @> p_period_end::date;
  if v_total_pct <> 100 then
    raise exception 'مجموع نسب الارباح الفعالة عند نهاية الفترة يساوي % وليس 100 — لا يمكن الاحتساب', v_total_pct;
  end if;

  insert into finance.profit_distribution_cycles (
    tenant_id, well_id, period_start, period_end, status,
    eligible_collections_minor, eligible_cash_expenses_minor,
    reserved_liabilities_minor, maintenance_reserve_minor, distributable_amount_minor,
    calculated_at, calculated_by
  ) values (
    v_tenant, p_well_id, p_period_start, p_period_end, 'calculated',
    v_collected, v_expenses, v_liabilities, v_reserve, v_distributable,
    now(), p_calculated_by
  ) returning id into v_cycle;

  v_remaining := v_distributable;
  for v_share in
    select v.partner_id, v.profit_percentage
    from core.ownership_share_versions v
    where v.well_id = p_well_id and v.effective_period @> p_period_end::date
    order by v.profit_percentage desc, v.partner_id
  loop
    v_gross := floor(v_distributable * v_share.profit_percentage / 100);
    v_remaining := v_remaining - v_gross;

    -- مستحقات الشريك غير المسواة فقط (منع الازدواج)
    select coalesce(sum(e.amount_minor), 0) into v_receivables
    from finance.expenses e
    where e.well_id = p_well_id and e.partner_id = v_share.partner_id
      and e.payment_source = 'partner_paid' and e.status = 'posted'
      and e.spent_at < p_period_end
      and e.settled_in_cycle_id is null;

    -- فواتير سقي الشريك غير المخصومة سابقا فقط
    select coalesce(sum(i.outstanding_minor), 0) into v_irrigation
    from billing.invoices i
    join core.partner_irrigation_policies pol on pol.id = i.partner_policy_id
    where pol.partner_id = v_share.partner_id
      and i.status in ('issued', 'partially_paid', 'overdue')
      and i.invoice_date < p_period_end
      and i.deducted_in_cycle_id is null;

    insert into finance.profit_distribution_lines (
      tenant_id, distribution_cycle_id, partner_id, profit_percentage_snapshot,
      gross_share_minor, partner_receivables_minor, irrigation_deductions_minor,
      other_deductions_minor, net_payable_minor
    ) values (
      v_tenant, v_cycle, v_share.partner_id, v_share.profit_percentage,
      v_gross, v_receivables, v_irrigation, 0,
      v_gross + v_receivables - v_irrigation
    );

    if v_max_pct = -1 then
      v_max_pct := v_share.profit_percentage;
      v_max_partner := v_share.partner_id;
    end if;
  end loop;

  if v_remaining <> 0 and v_max_partner is not null then
    update finance.profit_distribution_lines
    set gross_share_minor = gross_share_minor + v_remaining,
        net_payable_minor = net_payable_minor + v_remaining
    where distribution_cycle_id = v_cycle and partner_id = v_max_partner;
  end if;

  return v_cycle;
end;
$$;
create or replace function finance.approve_profit_distribution(p_cycle_id uuid, p_approved_by uuid)
returns void language plpgsql security definer
set search_path to 'finance', 'core', 'ops', 'billing', 'pg_temp' as $$
declare
  v_cycle record;
  v_line record;
  v_je uuid;
  v_acc3200 uuid; v_acc2500 uuid; v_acc2100 uuid; v_acc2400 uuid; v_acc1100 uuid;
begin
  perform billing.lock_customer_credit_well((select well_id from finance.profit_distribution_cycles where id=p_cycle_id));
  select * into v_cycle from finance.profit_distribution_cycles where id = p_cycle_id for update;
  if v_cycle is null then raise exception 'الدورة غير موجودة: %', p_cycle_id; end if;
  if v_cycle.status not in ('calculated', 'under_review') then
    raise exception 'لا يمكن اعتماد دورة حالتها % — يجب ان تكون محسوبة او قيد المراجعة', v_cycle.status;
  end if;
  if exists (select 1 from finance.profit_distribution_lines l
             where l.distribution_cycle_id = p_cycle_id and l.net_payable_minor < 0) then
    raise exception 'لا يمكن الاعتماد: يوجد شريك صافي مستحقه سالب — راجع الاستقطاعات';
  end if;

  v_acc3200 := finance.ledger_account_id(v_cycle.well_id, '3200');
  v_acc2100 := finance.ledger_account_id(v_cycle.well_id, '2100');
  v_acc2400 := finance.ledger_account_id(v_cycle.well_id, '2400');
  v_acc1100 := finance.ledger_account_id(v_cycle.well_id, '1100');

  if v_cycle.maintenance_reserve_minor > 0 then
    v_acc2500 := finance.ledger_account_id(v_cycle.well_id, '2500');
    insert into finance.journal_entries (tenant_id, public_code, well_id, entry_date, source_type, source_id, description, idempotency_key)
    values (v_cycle.tenant_id, core.generate_public_code('JE'), v_cycle.well_id, now(),
            'maintenance_reserve', p_cycle_id, 'تكوين احتياطي الصيانة لدورة التوزيع ' || v_cycle.public_code,
            'MRS-' || p_cycle_id::text)
    returning id into v_je;
    insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, description) values
      (v_cycle.tenant_id, v_je, v_acc3200, 'debit',  v_cycle.maintenance_reserve_minor, 'من الارباح القابلة للتوزيع'),
      (v_cycle.tenant_id, v_je, v_acc2500, 'credit', v_cycle.maintenance_reserve_minor, 'الى احتياطي الصيانة');
    perform finance.post_journal_entry(v_je, p_approved_by);
  end if;

  for v_line in
    select * from finance.profit_distribution_lines where distribution_cycle_id = p_cycle_id
  loop
    if v_line.gross_share_minor = 0 and v_line.partner_receivables_minor = 0 then
      continue;
    end if;
    insert into finance.journal_entries (tenant_id, public_code, well_id, entry_date, source_type, source_id, description, idempotency_key)
    values (v_cycle.tenant_id, core.generate_public_code('JE'), v_cycle.well_id, now(),
            'profit_distribution', v_line.id, 'مستحقات شريك من دورة التوزيع ' || v_cycle.public_code,
            'PDC-' || v_line.id::text)
    returning id into v_je;
    insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, partner_id, description)
    values (v_cycle.tenant_id, v_je, v_acc3200, 'debit', v_line.gross_share_minor, v_line.partner_id, 'حصة الشريك الاجمالية');
    if v_line.partner_receivables_minor > 0 then
      insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, partner_id, description)
      values (v_cycle.tenant_id, v_je, v_acc2400, 'debit', v_line.partner_receivables_minor, v_line.partner_id, 'تسوية مبالغ كانت مستحقة للشريك');
    end if;
    insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, partner_id, description)
    values (v_cycle.tenant_id, v_je, v_acc2100, 'credit', v_line.net_payable_minor, v_line.partner_id, 'صافي مستحق الشريك');
    if v_line.irrigation_deductions_minor > 0 then
      insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, partner_id, description)
      values (v_cycle.tenant_id, v_je, v_acc1100, 'credit', v_line.irrigation_deductions_minor, v_line.partner_id, 'خصم قيمة سقيه من ديون المزارعين');
    end if;
    perform finance.post_journal_entry(v_je, p_approved_by);
  end loop;

  -- تعليم المسواة: المصروفات المدفوعة من الشركاء والفواتير المخصومة لا تحسب مرة اخرى
  update finance.expenses e set settled_in_cycle_id = p_cycle_id
  where e.well_id = v_cycle.well_id and e.payment_source = 'partner_paid'
    and e.status = 'posted' and e.spent_at < v_cycle.period_end
    and e.settled_in_cycle_id is null;

  update billing.invoices i set deducted_in_cycle_id = p_cycle_id
  from core.partner_irrigation_policies pol
  where i.partner_policy_id = pol.id
    and i.well_id = v_cycle.well_id
    and i.status in ('issued', 'partially_paid', 'overdue')
    and i.outstanding_minor > 0
    and i.invoice_date < v_cycle.period_end
    and i.deducted_in_cycle_id is null;

  update finance.profit_distribution_lines set status = 'approved' where distribution_cycle_id = p_cycle_id;
  update finance.profit_distribution_cycles
  set status = 'approved', approved_at = now(), approved_by = p_approved_by
  where id = p_cycle_id;

  insert into ops.notifications (recipient_profile_id, well_id, type, message)
  select wp.profile_id, v_cycle.well_id, 'distribution_approved',
    format('اعتمدت دورة توزيع %s: صافي مستحقك %s ريال', v_cycle.public_code, l.net_payable_minor)
  from finance.profit_distribution_lines l
  join core.well_partners wp on wp.id = l.partner_id
  where l.distribution_cycle_id = p_cycle_id and wp.profile_id is not null;
end;
$$;
commit;
