begin;

set local timezone to 'UTC';

do $$
declare
  v_tenant uuid;
  v_well uuid;
  v_user uuid;
  v_profile uuid;
  v_person uuid;
  v_farmer_profile uuid;
  v_farmer_account uuid;
  v_partner_person uuid;
  v_partner uuid;
  v_invoice_1 uuid;
  v_invoice_2 uuid;
  v_invoice_3 uuid;
  v_payment_id uuid;
  v_advance_payment_id uuid;
  v_cycle_paid uuid;
  v_line_paid uuid;
  v_cycle_over uuid;
  v_line_over uuid;
  v_cycle_draft uuid;
  v_line_draft uuid;
  v_summary jsonb;
begin
  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'money068@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_user;

  select id into v_profile from iam.profiles where id = v_user;
  if not found then
    insert into iam.profiles (id, full_name)
    values (v_user, 'مالك اختبار المال 068')
    returning id into v_profile;
  end if;

  insert into core.tenants (name)
  values ('جهة اختبار إجراءات المال 068')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'بئر اختبار إجراءات المال 068')
  returning id into v_well;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_well, v_profile, 'owner', 'active');

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع اختبار المال', 'مزارع اختبار المال')
  returning id into v_person;

  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person)
  returning id into v_farmer_profile;

  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_farmer_profile, v_well, 'FWA-068')
  returning id into v_farmer_account;

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'شريك اختبار المال', 'شريك اختبار المال')
  returning id into v_partner_person;

  insert into core.well_partners
    (tenant_id, well_id, person_id, profile_id, phone)
  values (v_tenant, v_well, v_partner_person, v_profile, '777000068')
  returning id into v_partner;

  insert into billing.invoices (
    tenant_id, public_code, well_id, farmer_well_account_id,
    invoice_date, status, total_minor, outstanding_minor
  ) values (
    v_tenant, 'INV-068-1', v_well, v_farmer_account,
    timestamptz '2026-08-01 08:00:00+00', 'draft', 1000, 1000
  ) returning id into v_invoice_1;
  update billing.invoices
  set status = 'issued', issued_at = now(), issued_by = v_profile
  where id = v_invoice_1;

  insert into billing.invoices (
    tenant_id, public_code, well_id, farmer_well_account_id,
    invoice_date, status, total_minor, outstanding_minor
  ) values (
    v_tenant, 'INV-068-2', v_well, v_farmer_account,
    timestamptz '2026-08-02 08:00:00+00', 'draft', 500, 500
  ) returning id into v_invoice_2;
  update billing.invoices
  set status = 'issued', issued_at = now(), issued_by = v_profile
  where id = v_invoice_2;

  insert into billing.invoices (
    tenant_id, public_code, well_id, farmer_well_account_id,
    invoice_date, status, total_minor, outstanding_minor
  ) values (
    v_tenant, 'INV-068-3', v_well, v_farmer_account,
    timestamptz '2026-08-03 08:00:00+00', 'draft', 300, 300
  ) returning id into v_invoice_3;
  update billing.invoices
  set status = 'issued', issued_at = now(), issued_by = v_profile
  where id = v_invoice_3;

  -- دورة معتمدة لاختبار الدفع الجزئي ثم الكامل.
  insert into finance.profit_distribution_cycles (
    tenant_id, well_id, period_start, period_end, status,
    distributable_amount_minor, calculated_at, calculated_by
  ) values (
    v_tenant, v_well,
    timestamptz '2026-05-01 00:00:00+00',
    timestamptz '2026-06-01 00:00:00+00',
    'calculated', 1000, now(), v_profile
  ) returning id into v_cycle_paid;
  insert into finance.profit_distribution_lines (
    tenant_id, distribution_cycle_id, partner_id,
    profit_percentage_snapshot, gross_share_minor, net_payable_minor
  ) values (
    v_tenant, v_cycle_paid, v_partner, 100, 1000, 1000
  ) returning id into v_line_paid;
  perform finance.approve_profit_distribution(v_cycle_paid, v_profile);

  -- دورة معتمدة مستقلة لاختبار تجاوز المستحق.
  insert into finance.profit_distribution_cycles (
    tenant_id, well_id, period_start, period_end, status,
    distributable_amount_minor, calculated_at, calculated_by
  ) values (
    v_tenant, v_well,
    timestamptz '2026-06-01 00:00:00+00',
    timestamptz '2026-07-01 00:00:00+00',
    'calculated', 500, now(), v_profile
  ) returning id into v_cycle_over;
  insert into finance.profit_distribution_lines (
    tenant_id, distribution_cycle_id, partner_id,
    profit_percentage_snapshot, gross_share_minor, net_payable_minor
  ) values (
    v_tenant, v_cycle_over, v_partner, 100, 500, 500
  ) returning id into v_line_over;
  perform finance.approve_profit_distribution(v_cycle_over, v_profile);

  -- دورة غير معتمدة لاختبار الرفض.
  insert into finance.profit_distribution_cycles (
    tenant_id, well_id, period_start, period_end, status,
    distributable_amount_minor, calculated_at, calculated_by
  ) values (
    v_tenant, v_well,
    timestamptz '2026-07-01 00:00:00+00',
    timestamptz '2026-08-01 00:00:00+00',
    'calculated', 400, now(), v_profile
  ) returning id into v_cycle_draft;
  insert into finance.profit_distribution_lines (
    tenant_id, distribution_cycle_id, partner_id,
    profit_percentage_snapshot, gross_share_minor, net_payable_minor
  ) values (
    v_tenant, v_cycle_draft, v_partner, 100, 400, 400
  ) returning id into v_line_draft;

  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  -- 1) المسار السعيد لتسجيل دفعة: 1000 للمستحق و200 رصيد مقدم.
  v_summary := billing.record_payment(
    v_well, v_farmer_account, 1200, 'cash',
    jsonb_build_array(jsonb_build_object(
      'invoice_id', v_invoice_1, 'amount_minor', 1000
    )),
    null, v_person
  );
  v_payment_id := (v_summary ->> 'payment_id')::uuid;
  v_advance_payment_id := (v_summary ->> 'advance_payment_id')::uuid;

  if (v_summary ->> 'settled_minor')::bigint = 1000
     and (v_summary ->> 'advance_minor')::bigint = 200
     and v_summary -> 'receipt' ->> 'public_code' is not null
     and (v_summary ->> 'journal_entry_id')::uuid is not null then
    raise notice 'PASS 1: تسجيل الدفعة سدد 1000 وأصدر إيصالًا وحوّل الزيادة 200 إلى رصيد مقدم';
  else
    raise notice 'FAIL 1: ملخص تسجيل الدفعة أو الإيصال غير صحيح: %', v_summary;
  end if;

  if exists (
    select 1 from billing.invoices i
    where i.id = v_invoice_1 and i.status = 'paid'
      and i.paid_minor = 1000 and i.outstanding_minor = 0
  ) and exists (
    select 1 from billing.payments p
    join finance.journal_entries je on je.id = p.journal_entry_id
    where p.id = v_advance_payment_id and p.purpose = 'advance'
      and p.amount_minor = 200 and je.status = 'posted'
  ) then
    raise notice 'PASS 2: الفاتورة أصبحت مدفوعة والرصيد المقدم له قيد مرحل مستقل';
  else
    raise notice 'FAIL 2: حالة الفاتورة أو قيد الرصيد المقدم غير صحيح';
  end if;

  if exists (
    select 1 from audit.audit_logs a
    where a.action = 'record_payment' and a.entity_id = v_payment_id
  ) then
    raise notice 'PASS 3: تسجيل الدفعة ترك أثر تدقيق يحمل معرف السند';
  else
    raise notice 'FAIL 3: أثر تدقيق تسجيل الدفعة غير موجود';
  end if;

  -- 2) المسار السعيد لتوزيع رصيد مقدم موجود على فاتورة.
  v_summary := billing.record_payment(
    v_well, v_farmer_account, 500, 'cash', '[]'::jsonb,
    null, v_person
  );
  v_advance_payment_id := (v_summary ->> 'payment_id')::uuid;

  v_summary := billing.allocate_payment(
    v_advance_payment_id,
    jsonb_build_array(jsonb_build_object(
      'invoice_id', v_invoice_2, 'amount_minor', 300
    ))
  );

  if (v_summary ->> 'allocated_minor')::bigint = 300
     and (v_summary ->> 'remaining_available_minor')::bigint = 200
     and exists (
       select 1 from billing.invoices i
       where i.id = v_invoice_2 and i.status = 'partially_paid'
         and i.paid_minor = 300 and i.outstanding_minor = 200
     )
     and exists (
       select 1 from finance.journal_entries je
       where je.source_type = 'advance_allocation'
         and je.status = 'posted'
         and exists (
           select 1 from finance.journal_lines jl
           where jl.journal_entry_id = je.id
             and jl.entry_side = 'debit' and jl.amount_minor = 300
             and jl.ledger_account_id = finance.ledger_account_id(v_well, '2000')
         )
     )
     and exists (
       select 1 from audit.audit_logs a
       where a.action = 'allocate_payment'
         and a.new_values ->> 'payment_id' = v_advance_payment_id::text
     ) then
    raise notice 'PASS 4: توزيع الرصيد المقدم خصص 300 وحدّث الفاتورة ورحّل 2000/1100';
  else
    raise notice 'FAIL 4: توزيع الرصيد المقدم أو حالة الفاتورة أو قيده غير صحيح';
  end if;

  begin
    perform billing.allocate_payment(
      v_advance_payment_id,
      jsonb_build_array(jsonb_build_object(
        'invoice_id', v_invoice_3, 'amount_minor', 300
      ))
    );
    raise notice 'FAIL 5: سُمح بتوزيع 300 والمتاح من الدفعة 200 فقط';
  exception when others then
    if position('يتجاوز المتاح من الدفعة' in sqlerrm) > 0 then
      raise notice 'PASS 5: رُفض توزيع يتجاوز المتاح من الدفعة';
    else
      raise notice 'FAIL 5: سبب رفض تجاوز المتاح غير متوقع: %', sqlerrm;
    end if;
  end;

  -- حارس الدين: المتاح في دفعة جديدة 500 لكن دين الفاتورة المتبقي 200 فقط.
  v_summary := billing.record_payment(
    v_well, v_farmer_account, 500, 'cash', '[]'::jsonb,
    null, v_person
  );
  begin
    perform billing.allocate_payment(
      (v_summary ->> 'payment_id')::uuid,
      jsonb_build_array(jsonb_build_object(
        'invoice_id', v_invoice_2, 'amount_minor', 250
      ))
    );
    raise notice 'FAIL 6: سُمح بتخصيص 250 ودين الفاتورة المتبقي 200 فقط';
  exception when others then
    if position('يتجاوز دين الفاتورة المتبقي' in sqlerrm) > 0 then
      raise notice 'PASS 6: رُفض تخصيص يتجاوز دين الفاتورة المتبقي';
    else
      raise notice 'FAIL 6: سبب رفض تجاوز دين الفاتورة غير متوقع: %', sqlerrm;
    end if;
  end;

  begin
    perform billing.record_payment(
      v_well, v_farmer_account, 100, 'cash', '[]'::jsonb,
      null, v_person, gen_random_uuid()
    );
    raise notice 'FAIL 7: سُمح بدفعة نقدية مرتبطة بصندوق غير صالح';
  exception when others then
    if position('الصندوق النقدي غير موجود أو غير فعال' in sqlerrm) > 0 then
      raise notice 'PASS 7: رُفضت دفعة نقدية بصندوق غير صالح';
    else
      raise notice 'FAIL 7: سبب رفض الصندوق غير الصالح غير متوقع: %', sqlerrm;
    end if;
  end;

  begin
    perform billing.record_payment(v_well, null, 100, 'cash');
    raise notice 'FAIL 8: سُمح بتسجيل دفعة بلا حساب مزارع';
  exception when others then
    if position('حساب المزارع غير موجود' in sqlerrm) > 0 then
      raise notice 'PASS 8: رُفضت دفعة بلا حساب مزارع';
    else
      raise notice 'FAIL 8: سبب رفض الحساب المفقود غير متوقع: %', sqlerrm;
    end if;
  end;

  begin
    perform billing.record_payment(v_well, v_farmer_account, 0, 'cash');
    raise notice 'FAIL 9: سُمح بدفعة مبلغها صفر';
  exception when others then
    if position('أكبر من صفر' in sqlerrm) > 0 then
      raise notice 'PASS 9: رُفضت دفعة مبلغها صفر';
    else
      raise notice 'FAIL 9: سبب رفض المبلغ صفر غير متوقع: %', sqlerrm;
    end if;
  end;

  begin
    perform billing.record_payment(v_well, v_farmer_account, -10, 'cash');
    raise notice 'FAIL 10: سُمح بدفعة سالبة';
  exception when others then
    if position('أكبر من صفر' in sqlerrm) > 0 then
      raise notice 'PASS 10: رُفضت الدفعة السالبة';
    else
      raise notice 'FAIL 10: سبب رفض الدفعة السالبة غير متوقع: %', sqlerrm;
    end if;
  end;

  -- 3) المسار السعيد لدفع مستحق الشريك جزئيًا ثم إكماله.
  v_summary := finance.pay_partner_distribution(v_line_paid, 400, v_profile);
  if (v_summary ->> 'paid_total_minor')::bigint = 400
     and v_summary ->> 'line_status' = 'partially_paid'
     and v_summary ->> 'cycle_status' = 'partially_paid'
     and exists (
       select 1 from finance.journal_entries je
       where je.id = (v_summary ->> 'journal_entry_id')::uuid
         and je.status = 'posted'
         and exists (
           select 1 from finance.journal_lines jl
           where jl.journal_entry_id = je.id and jl.entry_side = 'credit'
             and jl.amount_minor = 400
             and jl.cashbox_id = finance.main_cashbox_id(v_well)
         )
     )
     and exists (
       select 1 from audit.audit_logs a
       where a.action = 'pay_partner_distribution'
         and a.entity_id = v_line_paid
     ) then
    raise notice 'PASS 11: دفع الشريك الجزئي حدّث السطر والدورة ورحّل الصرف من الصندوق الرئيسي';
  else
    raise notice 'FAIL 11: نتيجة دفع الشريك الجزئي غير صحيحة: %', v_summary;
  end if;

  v_summary := finance.pay_partner_distribution(v_line_paid, 600, v_profile);
  if (v_summary ->> 'paid_total_minor')::bigint = 1000
     and (v_summary ->> 'remaining_minor')::bigint = 0
     and v_summary ->> 'line_status' = 'paid'
     and v_summary ->> 'cycle_status' = 'paid' then
    raise notice 'PASS 12: الدفعة الثانية أكملت مستحق الشريك وغيّرت السطر والدورة إلى مدفوع';
  else
    raise notice 'FAIL 12: إكمال مستحق الشريك غير صحيح: %', v_summary;
  end if;

  begin
    perform finance.pay_partner_distribution(v_line_draft, 100, v_profile);
    raise notice 'FAIL 13: سُمح بدفع شريك من دورة غير معتمدة';
  exception when others then
    if position('يجب أن تكون معتمدة' in sqlerrm) > 0 then
      raise notice 'PASS 13: رُفض دفع شريك من دورة غير معتمدة';
    else
      raise notice 'FAIL 13: سبب رفض الدورة غير المعتمدة غير متوقع: %', sqlerrm;
    end if;
  end;

  begin
    perform finance.pay_partner_distribution(v_line_over, 600, v_profile);
    raise notice 'FAIL 14: سُمح بدفع مبلغ يتجاوز مستحق الشريك';
  exception when others then
    if position('يتجاوز مستحق الشريك المتبقي' in sqlerrm) > 0 then
      raise notice 'PASS 14: رُفض دفع يتجاوز مستحق الشريك';
    else
      raise notice 'FAIL 14: سبب رفض تجاوز مستحق الشريك غير متوقع: %', sqlerrm;
    end if;
  end;

  begin
    perform finance.pay_partner_distribution(v_line_paid, 1, v_profile);
    raise notice 'FAIL 15: سُمح بدفع ثان لسطر مدفوع بالكامل';
  exception when others then
    if position('مدفوع بالكامل مسبقًا' in sqlerrm) > 0 then
      raise notice 'PASS 15: رُفض دفع ثان لسطر مدفوع بالكامل';
    else
      raise notice 'FAIL 15: سبب رفض الدفع الثاني غير متوقع: %', sqlerrm;
    end if;
  end;

  execute 'reset role';
  raise notice '--- انتهى اختبار إجراءات المال الذرية 068 (15 فحصًا) ---';
end $$;

rollback;
