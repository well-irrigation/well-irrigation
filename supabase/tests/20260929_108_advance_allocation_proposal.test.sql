-- ق-131 البند 10 / م-45 المرحلة A: اقتراح تسوية المقدم بتأكيد صريح.
-- هذا اختبار DB فقط؛ كل التغييرات تتراجع في النهاية.
--
-- ما يثبه هذا الملف:
--   1. سطح العقد: وجوده ونوعه وINVOKER ومسار بحثه الآمن ومنحه.
--   2. anon محجوب، والمالك والمشغل المصرَّح لهما يقرآن الاقتراح.
--   3. متبقّي سند مُستنزَف جزئيًّا يُحسب من المخزَّن: 60000 − 20000 = 40000.
--   4. المقترح أصغر مقدارَين: من متبقّي السند ومن المتبقي على الفاتورة.
--   5. فشل مغلق: متصل بلا سلطة، فاتورة مزارع آخر، فاتورة مسدَّدة،
--      دفعة غير مقدَّمة، ومعرّفات فارغة أو غير موجودة.
--   6. القراءة صرف: صف مالي وصندوق تخصيصات ويومية — صفر تغيير.
--   7. الكتابة تبقى على api.allocate_payment → billing.allocate_payment
--      بلا توسيع، واقتراح القراءة لا يفتح طريق كتابة ثانيًا.
--
-- والتجهيز كله بسلطة الإعداد قبل دخول دور المصادَق (نمط 106): المصادَق
-- يقرأ العقود ولا يكتب الجداول مباشرة (ق-79).

\set ON_ERROR_STOP on

begin;

set local timezone to 'UTC';

do $test$
declare
  v_owner uuid;
  v_operator uuid;
  v_stranger uuid;
  v_tenant uuid;
  v_well uuid;
  v_person uuid;
  v_other_person uuid;
  v_farmer_profile uuid;
  v_other_farmer_profile uuid;
  v_account uuid;
  v_other_account uuid;
  v_payment uuid;
  v_other_payment uuid;
  v_invoice_full uuid;
  v_invoice_small uuid;
  v_invoice_paid uuid;
  v_other_invoice uuid;
  v_before_allocations bigint;
  v_before_journals bigint;
  v_before_outstanding bigint;
  v_after_allocations bigint;
  v_after_journals bigint;
  v_after_outstanding bigint;
  v_proposal jsonb;
  v_denied boolean;
begin
  -- -------------------------------------------------------------
  -- 1. التجهيز بسلطة الإعداد.
  -- -------------------------------------------------------------
  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q131-advance-owner@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_owner;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q131-advance-operator@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_operator;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q131-advance-stranger@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_stranger;

  insert into core.tenants (name)
  values ('جهة اختبار اقتراح المقدم 108')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'بئر اقتراح المقدم 108')
  returning id into v_well;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values
    (v_well, v_owner, 'owner', 'active'),
    (v_well, v_operator, 'operator', 'active');

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع اقتراح المقدم 108', 'مزارع اقتراح المقدم 108')
  returning id into v_person;

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع آخر 108', 'مزارع آخر 108')
  returning id into v_other_person;

  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person)
  returning id into v_farmer_profile;

  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_other_person)
  returning id into v_other_farmer_profile;

  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_farmer_profile, v_well, 'FWA-108-A')
  returning id into v_account;

  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_other_farmer_profile, v_well, 'FWA-108-B')
  returning id into v_other_account;

  -- سند مقدم مرحّل 60000 على حساب المزارع، ومُخصص منه 20000 تجهيزًا
  -- — فمتبقيه 40000. ودفعة old_debt للرفض (غير مقدَّمة).
  insert into billing.payments (
    tenant_id, well_id, farmer_well_account_id,
    purpose, amount_minor, method, paid_at, status
  ) values (
    v_tenant, v_well, v_account,
    'advance', 60000, 'cash', timestamptz '2026-09-20 08:00:00+03', 'posted'
  )
  returning id into v_payment;

  insert into billing.payments (
    tenant_id, well_id, farmer_well_account_id,
    purpose, amount_minor, method, paid_at, status
  ) values (
    v_tenant, v_well, v_account,
    'old_debt', 30000, 'cash', timestamptz '2026-09-20 09:00:00+03', 'posted'
  )
  returning id into v_other_payment;

  -- فاتورة كبيرة مستحقة 100000، وفاتورة صغيرة متبقٍّها 30000،
  -- وفاتورة مسدَّدة للرفض، وفاتورة مزارع آخر للرفض.
  insert into billing.invoices (
    tenant_id, public_code, well_id, farmer_well_account_id,
    invoice_date, status, subtotal_minor, total_minor,
    paid_minor, outstanding_minor
  ) values
    (v_tenant, 'INV-108-A', v_well, v_account,
     timestamptz '2026-09-21 08:00:00+03', 'issued',
     100000, 100000, 0, 100000),
    (v_tenant, 'INV-108-B', v_well, v_account,
     timestamptz '2026-09-22 08:00:00+03', 'partially_paid',
     100000, 100000, 70000, 30000),
    (v_tenant, 'INV-108-C', v_well, v_account,
     timestamptz '2026-09-23 08:00:00+03', 'paid',
     40000, 40000, 40000, 0),
    (v_tenant, 'INV-108-D', v_well, v_other_account,
     timestamptz '2026-09-23 09:00:00+03', 'issued',
     50000, 50000, 0, 50000);

  select id into v_invoice_full
  from billing.invoices where public_code = 'INV-108-A';
  select id into v_invoice_small
  from billing.invoices where public_code = 'INV-108-B';
  select id into v_invoice_paid
  from billing.invoices where public_code = 'INV-108-C';
  select id into v_other_invoice
  from billing.invoices where public_code = 'INV-108-D';

  -- تخصيص 20000 من سند المقدم على الفاتورة الكبيرة (تجهيز الإعداد).
  insert into billing.payment_allocations (
    tenant_id, payment_id, invoice_id, allocated_minor
  ) values (v_tenant, v_payment, v_invoice_full, 20000);

  -- -------------------------------------------------------------
  -- 2. سطح العقد والمنح.
  -- -------------------------------------------------------------
  if to_regprocedure('api.get_advance_allocation_proposal(uuid, uuid)')
       is not null
     and exists (
      select 1 from pg_proc p
      where p.oid = to_regprocedure(
              'api.get_advance_allocation_proposal(uuid, uuid)'
            )
        and p.prorettype = 'jsonb'::regtype
        and p.prolang = (
          select oid from pg_language where lanname = 'plpgsql'
        )
        and not p.prosecdef
        and p.proconfig @> array['search_path=pg_catalog, pg_temp']
    )
     and has_function_privilege(
      'authenticated',
      to_regprocedure('api.get_advance_allocation_proposal(uuid, uuid)'),
      'EXECUTE'
    )
     and has_function_privilege(
      'service_role',
      to_regprocedure('api.get_advance_allocation_proposal(uuid, uuid)'),
      'EXECUTE'
    )
     and not has_function_privilege(
      'anon',
      to_regprocedure('api.get_advance_allocation_proposal(uuid, uuid)'),
      'EXECUTE'
    )
  then
    raise notice 'PASS 1: العقد موجود INVOKER بمسار بحث آمن ومنحه للعملاء كما هو';
  else
    raise notice 'FAIL 1: سطح العقد أو منحه غير مطابق';
  end if;

  -- -------------------------------------------------------------
  -- 3. المالك يقرأ الاقتراح: المتبقي من المخزَّن والمقترح أصغر مقدارين.
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';

  v_proposal := api.get_advance_allocation_proposal(v_payment, v_invoice_full);

  if v_proposal ->> 'contract' = 'get_advance_allocation_proposal'
     and (v_proposal ->> 'version')::int = 1
     and (v_proposal ->> 'payment_id')::uuid = v_payment
     and (v_proposal ->> 'invoice_id')::uuid = v_invoice_full
     and (v_proposal ->> 'farmer_well_account_id')::uuid = v_account
     and (v_proposal ->> 'well_id')::uuid = v_well
  then
    raise notice 'PASS 2: الغلاف يعيد اسمه وإصداره والسند والفاتورة والحساب والبئر';
  else
    raise notice 'FAIL 2: غلاف غير متوقع: %', v_proposal;
  end if;

  if (v_proposal ->> 'advance_remaining_minor')::bigint = 40000
     and (v_proposal ->> 'invoice_outstanding_minor')::bigint = 100000
     and (v_proposal ->> 'proposed_minor')::bigint = 40000
     and (v_proposal ->> 'can_apply')::boolean is true
  then
    raise notice 'PASS 3: متبقّي السند 40000 من المخزَّن والمقترح أصغره مع متبقي الفاتورة';
  else
    raise notice 'FAIL 3: الاقتراح: %', v_proposal;
  end if;

  -- -------------------------------------------------------------
  -- 4. المشغل المصرَّح له يقرأ، والمقترح يتبع الفاتورة الأصغر متبقيًا.
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_operator::text, true);
  execute 'set local role authenticated';

  v_proposal := api.get_advance_allocation_proposal(v_payment, v_invoice_small);

  if (v_proposal ->> 'advance_remaining_minor')::bigint = 40000
     and (v_proposal ->> 'invoice_outstanding_minor')::bigint = 30000
     and (v_proposal ->> 'proposed_minor')::bigint = 30000
     and (v_proposal ->> 'can_apply')::boolean is true
  then
    raise notice 'PASS 4: المشغل يقرأ والاقترح 30000 = أصغر المتبقيَّين';
  else
    raise notice 'FAIL 4: اقتراح المشغل: %', v_proposal;
  end if;

  -- -------------------------------------------------------------
  -- 5. فشل مغلق: متصل بلا سلطة، فاتورة مزارع آخر، فاتورة مسدَّدة،
  --    دفعة غير مقدَّمة، ومعرّفات فارغة أو غير موجودة.
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_stranger::text, true);
  execute 'set local role authenticated';

  v_denied := false;
  begin
    perform api.get_advance_allocation_proposal(v_payment, v_invoice_full);
  exception when insufficient_privilege then
    v_denied := true;
  end;

  if v_denied then
    raise notice 'PASS 5: متصل بلا payment.allocate مرفوض صريحًا';
  else
    raise notice 'FAIL 5: غير مصرَّح له قرأ الاقتراح';
  end if;

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';

  v_denied := false;
  begin
    perform api.get_advance_allocation_proposal(v_payment, v_other_invoice);
  exception when insufficient_privilege then
    v_denied := true;
  end;

  if v_denied then
    raise notice 'PASS 6: فاتورة مزارع آخر في البئر نفسه مرفوضة';
  else
    raise notice 'FAIL 6: فاتورة حساب آخر قبلت اقتراحًا';
  end if;

  v_denied := false;
  begin
    perform api.get_advance_allocation_proposal(v_payment, v_invoice_paid);
  exception when insufficient_privilege then
    v_denied := true;
  end;

  if v_denied then
    raise notice 'PASS 7: الفاتورة المسدَّدة لا تقبل اقتراح تسوية';
  else
    raise notice 'FAIL 7: فاتورة مسدَّدة قبلت اقتراحًا';
  end if;

  v_denied := false;
  begin
    perform api.get_advance_allocation_proposal(v_other_payment, v_invoice_full);
  exception when insufficient_privilege then
    v_denied := true;
  end;

  if v_denied then
    raise notice 'PASS 8: الدفعة غير المقدَّمة لا تقبل اقتراح مقدم';
  else
    raise notice 'FAIL 8: دفعة غير مقدَّمة قبلت اقتراحًا';
  end if;

  v_denied := false;
  begin
    perform api.get_advance_allocation_proposal(null, v_invoice_full);
  exception when invalid_parameter_value then
    v_denied := true;
  end;

  if v_denied then
    raise notice 'PASS 9: معرّف سند فارغ مرفوض بـ22023';
  else
    raise notice 'FAIL 9: معرّف فارغ لم يُرفض';
  end if;

  v_denied := false;
  begin
    perform api.get_advance_allocation_proposal(v_payment, gen_random_uuid());
  exception when insufficient_privilege then
    v_denied := true;
  end;

  if v_denied then
    raise notice 'PASS 10: فاتورة غير موجودة رفض مغلق بلا تسريب';
  else
    raise notice 'FAIL 10: فاتورة غير موجودة أعادت اقتراحًا';
  end if;

  -- -------------------------------------------------------------
  -- 6. القراءة صرف: ثلاث نداءات لا تغيّر أي صف مالي.
  -- -------------------------------------------------------------
  select count(*) into v_before_allocations
  from billing.payment_allocations where payment_id = v_payment;
  select count(*) into v_before_journals
  from finance.journal_entries where well_id = v_well;
  select outstanding_minor into v_before_outstanding
  from billing.invoices where id = v_invoice_full;

  perform api.get_advance_allocation_proposal(v_payment, v_invoice_full);
  perform api.get_advance_allocation_proposal(v_payment, v_invoice_small);
  perform api.get_advance_allocation_proposal(v_payment, v_invoice_full);

  select count(*) into v_after_allocations
  from billing.payment_allocations where payment_id = v_payment;
  select count(*) into v_after_journals
  from finance.journal_entries where well_id = v_well;
  select outstanding_minor into v_after_outstanding
  from billing.invoices where id = v_invoice_full;

  if v_before_allocations = v_after_allocations
     and v_before_journals = v_after_journals
     and v_before_outstanding = v_after_outstanding
  then
    raise notice 'PASS 11: ثلاث قراءات للاقتراح صفر تخصيص وصفر يومية وصفر تغيير مالي';
  else
    raise notice 'FAIL 11: قراءة الاقتراح غيّرت ماليًّا: تخصيصات %→% يومية %→% outstanding %→%',
      v_before_allocations, v_after_allocations,
      v_before_journals, v_after_journals,
      v_before_outstanding, v_after_outstanding;
  end if;

  -- -------------------------------------------------------------
  -- 7. الكتابة تبقى على api.allocate_payment بلا توسيع.
  -- -------------------------------------------------------------
  if to_regprocedure('api.allocate_payment(uuid, jsonb)') is not null
     and exists (
      select 1 from pg_proc p
      where p.oid = to_regprocedure('billing.allocate_payment(uuid, jsonb)')
        and p.prosecdef
        and position('has_well_permission' in pg_get_functiondef(p.oid)) > 0
        and position('''payment.allocate''' in pg_get_functiondef(p.oid)) > 0
    )
     and has_function_privilege(
      'authenticated',
      to_regprocedure('api.allocate_payment(uuid, jsonb)'),
      'EXECUTE'
    )
     and not has_function_privilege(
      'anon',
      to_regprocedure('api.get_advance_allocation_proposal(uuid, uuid)'),
      'EXECUTE'
    )
  then
    raise notice 'PASS 12: سلطة الكتابة billing.allocate_payment كما هي والاقتراح قراءة لا كتابة ثانية';
  else
    raise notice 'FAIL 12: سلطة الكتابة أو حدود الاقتراح غير مطابقة';
  end if;
end;
$test$;

rollback;
