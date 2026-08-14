begin;

do $$
declare
  v_tenant uuid; v_well uuid; v_cash uuid; v_tank uuid;
  v_user uuid; v_oprof uuid;
  v_person uuid; v_fp uuid; v_fwa uuid;
  v_pump uuid; v_farm uuid; v_session uuid; v_charge uuid;
  v_pp uuid; v_partner uuid; v_cat uuid;
  v_p1 uuid; v_p1s uuid; v_p2 uuid;
  v_e1 uuid; v_e2 uuid; v_e3 uuid;
  v_i1 uuid; v_i3 uuid;
  v_je1 uuid; v_rev uuid; v_ftx uuid;
  v_amt bigint;
  v_a1000 uuid; v_a1100 uuid; v_a2000 uuid; v_a2300 uuid; v_a2400 uuid;
  v_a4000 uuid; v_a4100 uuid; v_a5100 uuid;
begin
  insert into core.tenants (name) values ('مستأجر اختبار 061') returning id into v_tenant;
  insert into core.wells (tenant_id, name) values (v_tenant, 'بئر اختبار 061') returning id into v_well;
  v_cash := finance.main_cashbox_id(v_well);
  select id into v_tank from inventory.fuel_tanks where well_id = v_well order by created_at limit 1;

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'op061@test.local', crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_user;
  select id into v_oprof from iam.profiles where id = v_user;
  if v_oprof is null then
    insert into iam.profiles (id, full_name) values (v_user, 'مشغل الاختبار') returning id into v_oprof;
  end if;

  insert into core.persons (tenant_id, full_name, normalized_name) values (v_tenant, 'مزارع الاختبار', 'مزارع الاختبار') returning id into v_person;
  insert into ops.farmer_profiles (tenant_id, person_id) values (v_tenant, v_person) returning id into v_fp;
  insert into ops.farmer_well_accounts (tenant_id, farmer_profile_id, well_id, public_code) values (v_tenant, v_fp, v_well, 'FWA-061') returning id into v_fwa;

  insert into core.pumps (well_id, name, power_source) values (v_well, 'مضخة الاختبار', 'solar') returning id into v_pump;
  insert into ops.farms (well_id, name) values (v_well, 'مزرعة الاختبار') returning id into v_farm;
  insert into ops.irrigation_sessions (well_id, pump_id, farm_id, operator_profile_id) values (v_well, v_pump, v_farm, v_oprof) returning id into v_session;
  insert into billing.session_charges (session_id, well_id, duration_seconds, price_per_hour_minor, amount_minor)
  values (v_session, v_well, 3600, 500, 500) returning id into v_charge;

  insert into core.persons (tenant_id, full_name, normalized_name) values (v_tenant, 'شريك الاختبار', 'شريك الاختبار') returning id into v_pp;
  insert into core.well_partners (tenant_id, well_id, person_id, phone) values (v_tenant, v_well, v_pp, '777000061') returning id into v_partner;

  insert into finance.expense_categories (tenant_id, code, name_ar, ledger_account_code, attachment_required)
  values (v_tenant, 'TST061', 'مصروف اختبار', '5100', false) returning id into v_cat;

  v_a1000 := finance.ledger_account_id(v_well, '1000');
  v_a1100 := finance.ledger_account_id(v_well, '1100');
  v_a2000 := finance.ledger_account_id(v_well, '2000');
  v_a2300 := finance.ledger_account_id(v_well, '2300');
  v_a2400 := finance.ledger_account_id(v_well, '2400');
  v_a4000 := finance.ledger_account_id(v_well, '4000');
  v_a4100 := finance.ledger_account_id(v_well, '4100');
  v_a5100 := finance.ledger_account_id(v_well, '5100');

  insert into billing.payments (session_charge_id, farmer_well_account_id, amount_minor, method)
  values (v_charge, v_fwa, 700, 'cash') returning id into v_p1;

  select amount_minor into v_amt from billing.payments where id = v_p1;
  if v_amt = 500 then
    raise notice 'PASS 1: دفعة 700 على مستحق 500 اقتُطعت الى 500';
  else raise notice 'FAIL 1 (%)', v_amt; end if;

  select id into v_p1s from billing.payments
  where farmer_well_account_id = v_fwa and purpose = 'advance' and amount_minor = 200
    and note like 'رصيد مقدم تلقائي%';
  if v_p1s is not null then
    raise notice 'PASS 2: الزيادة 200 تحولت الى رصيد مقدم تلقائيا';
  else raise notice 'FAIL 2'; end if;

  if exists (select 1 from finance.journal_entries e
             where e.source_type = 'payment' and e.source_id = v_p1 and e.status = 'posted'
               and exists (select 1 from finance.journal_lines l where l.journal_entry_id = e.id and l.entry_side = 'debit'  and l.ledger_account_id = v_a1000 and l.amount_minor = 500 and l.cashbox_id = v_cash)
               and exists (select 1 from finance.journal_lines l where l.journal_entry_id = e.id and l.entry_side = 'credit' and l.ledger_account_id = v_a1100 and l.amount_minor = 500 and l.farmer_well_account_id = v_fwa))
  then raise notice 'PASS 3: قيد دفعة الجلسة مرحل 1000 بالصندوق / 1100';
  else raise notice 'FAIL 3'; end if;

  if exists (select 1 from finance.journal_entries e
             where e.source_type = 'payment' and e.source_id = v_p1s and e.status = 'posted'
               and exists (select 1 from finance.journal_lines l where l.journal_entry_id = e.id and l.entry_side = 'credit' and l.ledger_account_id = v_a2000 and l.amount_minor = 200))
  then raise notice 'PASS 4: قيد الرصيد المقدم يقيد 2000 دائنا';
  else raise notice 'FAIL 4'; end if;

  insert into billing.payments (session_charge_id, farmer_well_account_id, amount_minor, method)
  values (v_charge, v_fwa, 300, 'cash') returning id into v_p2;

  if exists (select 1 from billing.payments where id = v_p2 and purpose = 'advance' and session_charge_id is null and amount_minor = 300)
  then raise notice 'PASS 5: دفعة على جلسة مسددة بالكامل تحولت كليا الى رصيد مقدم';
  else raise notice 'FAIL 5'; end if;

  insert into finance.expenses (well_id, category_id, amount_minor, description, payment_source, attachment_skipped)
  values (v_well, v_cat, 6000, 'مصروف صيانة تجريبي', 'cashbox', true) returning id into v_e1;

  if exists (select 1 from finance.expenses x
             join finance.journal_entries e on e.id = x.journal_entry_id and e.status = 'posted'
             where x.id = v_e1
               and exists (select 1 from finance.journal_lines l where l.journal_entry_id = e.id and l.entry_side = 'debit'  and l.ledger_account_id = v_a5100 and l.amount_minor = 6000)
               and exists (select 1 from finance.journal_lines l where l.journal_entry_id = e.id and l.entry_side = 'credit' and l.ledger_account_id = v_a1000 and l.amount_minor = 6000 and l.cashbox_id = v_cash))
  then raise notice 'PASS 6: المصروف النقدي رُحّل 5100 / 1000 مع الصندوق';
  else raise notice 'FAIL 6'; end if;

  insert into finance.expenses (well_id, category_id, amount_minor, description, payment_source, partner_id, attachment_skipped)
  values (v_well, v_cat, 800, 'مصروف دفعه شريك', 'partner_paid', v_partner, true) returning id into v_e2;

  if exists (select 1 from finance.expenses x
             join finance.journal_entries e on e.id = x.journal_entry_id and e.status = 'posted'
             where x.id = v_e2
               and exists (select 1 from finance.journal_lines l where l.journal_entry_id = e.id and l.entry_side = 'credit' and l.ledger_account_id = v_a2400 and l.amount_minor = 800 and l.partner_id = v_partner))
  then raise notice 'PASS 7: مصروف الشريك يقيد 2400 دائنا بمعرف الشريك';
  else raise notice 'FAIL 7'; end if;

  insert into finance.expenses (well_id, category_id, amount_minor, description, payment_source, attachment_skipped)
  values (v_well, v_cat, 900, 'مصروف آجل', 'unpaid_payable', true) returning id into v_e3;

  if exists (select 1 from finance.expenses x
             join finance.journal_entries e on e.id = x.journal_entry_id and e.status = 'posted'
             where x.id = v_e3
               and exists (select 1 from finance.journal_lines l where l.journal_entry_id = e.id and l.entry_side = 'credit' and l.ledger_account_id = v_a2300 and l.amount_minor = 900))
  then raise notice 'PASS 8: المصروف الآجل يقيد 2300 دائنا';
  else raise notice 'FAIL 8'; end if;

  insert into billing.invoices (tenant_id, public_code, well_id, farmer_well_account_id, session_id, invoice_date, status, total_minor, outstanding_minor)
  values (v_tenant, 'INV-061-1', v_well, v_fwa, v_session, now(), 'draft', 5000, 5000) returning id into v_i1;
  insert into billing.invoice_lines (tenant_id, invoice_id, line_number, line_type, description, quantity, unit, unit_price_minor, amount_minor) values
    (v_tenant, v_i1, 1, 'solar_irrigation', 'سقي شمسي', 1, 'session', 3000, 3000),
    (v_tenant, v_i1, 2, 'diesel_operation', 'تشغيل ديزل', 1, 'session', 2000, 2000);
  update billing.invoices set status = 'issued', issued_at = now(), issued_by = v_oprof where id = v_i1;

  if exists (select 1 from finance.journal_entries e
             where e.source_type = 'invoice' and e.source_id = v_i1 and e.status = 'posted'
               and exists (select 1 from finance.journal_lines l where l.journal_entry_id = e.id and l.entry_side = 'debit'  and l.ledger_account_id = v_a1100 and l.amount_minor = 5000 and l.farmer_well_account_id = v_fwa)
               and exists (select 1 from finance.journal_lines l where l.journal_entry_id = e.id and l.entry_side = 'credit' and l.ledger_account_id = v_a4000 and l.amount_minor = 3000)
               and exists (select 1 from finance.journal_lines l where l.journal_entry_id = e.id and l.entry_side = 'credit' and l.ledger_account_id = v_a4100 and l.amount_minor = 2000))
     and (select journal_entry_id from billing.invoices where id = v_i1) is not null
  then raise notice 'PASS 9: قيد الفاتورة مرحل 1100 / 4000+4100 حسب البنود';
  else raise notice 'FAIL 9'; end if;

  begin
    insert into billing.invoices (tenant_id, public_code, well_id, farmer_well_account_id, session_id, invoice_date, status, total_minor, outstanding_minor)
    values (v_tenant, 'INV-061-2', v_well, v_fwa, v_session, now(), 'draft', 100, 100);
    raise notice 'FAIL 10: سُمح بفاتورة ثانية لنفس الجلسة';
  exception when unique_violation then
    raise notice 'PASS 10: رُفضت فاتورة ثانية لنفس الجلسة';
  end;

  insert into billing.invoices (tenant_id, public_code, well_id, farmer_well_account_id, invoice_date, status, total_minor, outstanding_minor)
  values (v_tenant, 'INV-061-3', v_well, v_fwa, now(), 'draft', 5000, 5000) returning id into v_i3;
  insert into billing.invoice_lines (tenant_id, invoice_id, line_number, line_type, description, quantity, unit, unit_price_minor, amount_minor)
  values (v_tenant, v_i3, 1, 'solar_irrigation', 'سقي', 1, 'session', 4000, 4000);
  begin
    update billing.invoices set status = 'issued', issued_at = now(), issued_by = v_oprof where id = v_i3;
    raise notice 'FAIL 11: صدرت فاتورة مجموع بنودها لا يساوي اجماليها';
  exception when others then
    raise notice 'PASS 11: رُفض اصدار فاتورة مجموع بنودها 4000 لا يساوي اجماليها 5000';
  end;

  select journal_entry_id into v_je1 from billing.payments where id = v_p1;
  v_rev := finance.reverse_journal_entry(v_je1, 'اختبار العكس', v_oprof);

  if (select status from finance.journal_entries where id = v_je1) = 'reversed'
     and exists (select 1 from finance.journal_entries r where r.id = v_rev and r.status = 'posted' and r.source_type = 'reversal' and r.reversal_of_entry_id = v_je1)
  then raise notice 'PASS 12: عكس القيد انشأ قيدا عكسيا مرحلا وعلّم الاصلي معكوسا';
  else raise notice 'FAIL 12'; end if;

  begin
    perform finance.reverse_journal_entry(v_je1, 'عكس ثان', v_oprof);
    raise notice 'FAIL 13: سُمح بعكس قيد معكوس';
  exception when others then
    raise notice 'PASS 13: رُفض عكس قيد معكوس مسبقا';
  end;

  perform billing.reverse_payment(v_p2, 'اختبار عكس الدفعة', v_oprof);

  if (select status from billing.payments where id = v_p2) = 'reversed'
     and (select e.status from finance.journal_entries e join billing.payments p on p.journal_entry_id = e.id where p.id = v_p2) = 'reversed'
  then raise notice 'PASS 14: عكس الدفعة عكس قيدها وعلّمها معكوسة';
  else raise notice 'FAIL 14'; end if;

  begin
    perform billing.reverse_payment(v_p2, 'عكس ثان', v_oprof);
    raise notice 'FAIL 15: سُمح بعكس دفعة معكوسة';
  exception when others then
    raise notice 'PASS 15: رُفض عكس دفعة معكوسة مسبقا';
  end;

  insert into inventory.fuel_transactions (tenant_id, well_id, fuel_tank_id, transaction_type, ownership_type, quantity_ml, direction, unit_cost_per_liter_minor, total_cost_minor)
  values (v_tenant, v_well, v_tank, 'purchase', 'well', 5000, 'in', 2000, 10000) returning id into v_ftx;

  if exists (select 1 from finance.journal_entries e
             where e.source_type = 'fuel_purchase' and e.source_id = v_ftx and e.status = 'posted'
               and exists (select 1 from finance.journal_lines l where l.journal_entry_id = e.id and l.entry_side = 'credit' and l.ledger_account_id = v_a1000 and l.amount_minor = 10000 and l.cashbox_id = v_cash))
  then raise notice 'PASS 16: قيد شراء الديزل يحمل الصندوق الرئيسي';
  else raise notice 'FAIL 16'; end if;

  select coalesce(sum(balance_minor), 0) into v_amt from reporting.cashbox_balances where well_id = v_well;
  if v_amt = -15800 then
    raise notice 'PASS 17: رصيد الصندوق = % (+200 رصيد مقدم، -6000 مصروف، -10000 ديزل، والعكسان متعادلان)', v_amt;
  else
    raise notice 'FAIL 17: رصيد الصندوق = % (المتوقع -15800)', v_amt;
  end if;

  raise notice '--- انتهى الاختبار المالي للدفعة الختامية (17 فحصا) ---';
end $$;

rollback;
