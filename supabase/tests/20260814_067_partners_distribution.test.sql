begin;

set local timezone to 'UTC';

do $$
declare
  v_tenant uuid; v_well uuid; v_remainder_well uuid; v_user uuid; v_profile uuid;
  v_farmer_person uuid; v_fp uuid; v_fwa uuid; v_invoice uuid; v_policy uuid;
  v_partner_person uuid; v_partner uuid; v_share uuid; v_cycle_jan uuid; v_cycle_feb uuid;
  v_remainder_person uuid; v_remainder_partner uuid; v_remainder_fp uuid; v_remainder_fwa uuid;
  v_remainder_cycle uuid; v_i integer; v_pct numeric; v_count bigint;
  v_remainder_partners uuid[] := array[]::uuid[];
begin
  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'partners067@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_user;
  select id into v_profile from iam.profiles where id = v_user;
  if not found then
    insert into iam.profiles (id, full_name) values (v_user, 'مالك توزيع 067') returning id into v_profile;
  end if;

  insert into core.tenants (name) values ('جهة اختبار الشركاء 067') returning id into v_tenant;
  insert into core.wells (tenant_id, name) values (v_tenant, 'بئر توزيع الشركاء 067') returning id into v_well;
  insert into core.well_assignments (well_id, profile_id, role, status) values (v_well, v_profile, 'owner', 'active');

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع توزيع 067', 'مزارع توزيع 067') returning id into v_farmer_person;
  insert into ops.farmer_profiles (tenant_id, person_id) values (v_tenant, v_farmer_person) returning id into v_fp;
  insert into ops.farmer_well_accounts (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_fp, v_well, 'FWA-067-DIST') returning id into v_fwa;

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'شريك توزيع 067', 'شريك توزيع 067') returning id into v_partner_person;
  insert into core.well_partners (tenant_id, well_id, person_id, phone)
  values (v_tenant, v_well, v_partner_person, '731067001') returning id into v_partner;
  insert into core.ownership_share_versions
    (tenant_id, well_id, partner_id, ownership_percentage, profit_percentage, effective_period, approved_by)
  values
    (v_tenant, v_well, v_partner, 100, 100, daterange(date '2026-01-01', null, '[)'), v_profile)
  returning id into v_share;
  execute 'set constraints all immediate';
  execute 'set constraints all deferred';

  insert into finance.maintenance_reserve_rules
    (tenant_id, well_id, reserve_type, reserve_percentage, effective_period)
  values
    (v_tenant, v_well, 'percentage_of_collections', 10, daterange(date '2026-01-01', null, '[)'));

  insert into billing.invoices
    (tenant_id, public_code, well_id, farmer_well_account_id, invoice_date,
     status, subtotal_minor, total_minor, outstanding_minor)
  values
    (v_tenant, 'INV-067-UNPAID', v_well, v_fwa, timestamptz '2026-01-10 10:00:00+00',
     'draft', 20000, 20000, 20000)
  returning id into v_invoice;
  insert into billing.invoice_lines
    (tenant_id, invoice_id, line_number, line_type, description, quantity, unit, unit_price_minor, amount_minor)
  values
    (v_tenant, v_invoice, 1, 'solar_irrigation', 'فاتورة غير محصلة', 1, 'session', 20000, 20000);
  update billing.invoices set status = 'issued', issued_at = timestamptz '2026-01-10 10:00:00+00', issued_by = v_profile
  where id = v_invoice;

  insert into billing.payments
    (farmer_well_account_id, amount_minor, method, purpose, paid_at)
  values
    (v_fwa, 10000, 'cash', 'old_debt', timestamptz '2026-01-15 10:00:00+00'),
    (v_fwa, 5000, 'cash', 'advance', timestamptz '2026-01-16 10:00:00+00');

  v_cycle_jan := finance.calculate_profit_distribution(
    v_well, timestamptz '2026-01-01 00:00:00+00', timestamptz '2026-02-01 00:00:00+00', v_profile, 0
  );
  if exists (
    select 1 from finance.profit_distribution_cycles
    where id = v_cycle_jan
      and eligible_collections_minor = 10000
      and maintenance_reserve_minor = 1000
      and distributable_amount_minor = 9000
  ) then
    raise notice 'PASS 1: التوزيع احتسب المحصل 10000 فقط واستبعد الفاتورة غير المحصلة والمقدم 5000';
  else raise notice 'FAIL 1: المال المؤهل أو استبعاد المقدم/غير المحصل غير صحيح'; end if;

  perform finance.approve_profit_distribution(v_cycle_jan, v_profile);
  if exists (
    select 1 from finance.journal_entries je
    join finance.journal_lines jl on jl.journal_entry_id = je.id
    join finance.ledger_accounts la on la.id = jl.ledger_account_id
    where je.source_type = 'maintenance_reserve' and je.source_id = v_cycle_jan
      and je.status = 'posted' and jl.entry_side = 'credit'
      and la.account_code = '2500' and jl.amount_minor = 1000
  ) then
    raise notice 'PASS 2: احتياطي الصيانة 10 بالمئة رُحل إلى الحساب 2500 بقيمة 1000';
  else raise notice 'FAIL 2: قيد احتياطي الصيانة غير موجود أو غير صحيح'; end if;

  insert into core.partner_irrigation_policies
    (tenant_id, well_id, partner_id, policy_type, period_start)
  values
    (v_tenant, v_well, v_partner, 'deduct_from_profit', date '2026-01-01')
  returning id into v_policy;

  insert into billing.invoices
    (tenant_id, public_code, well_id, farmer_well_account_id, invoice_date,
     status, subtotal_minor, total_minor, outstanding_minor,
     settlement_method, partner_policy_id)
  values
    (v_tenant, 'INV-067-PARTNER', v_well, v_fwa, timestamptz '2026-02-10 10:00:00+00',
     'draft', 6000, 6000, 6000, 'partner_profit_offset', v_policy)
  returning id into v_invoice;
  insert into billing.invoice_lines
    (tenant_id, invoice_id, line_number, line_type, description, quantity, unit, unit_price_minor, amount_minor)
  values
    (v_tenant, v_invoice, 1, 'solar_irrigation', 'سقي شريك يخصم من الأرباح', 1, 'session', 6000, 6000);
  update billing.invoices set status = 'issued', issued_at = timestamptz '2026-02-10 10:00:00+00', issued_by = v_profile
  where id = v_invoice;

  insert into billing.payments
    (farmer_well_account_id, amount_minor, method, purpose, paid_at)
  values
    (v_fwa, 5000, 'cash', 'old_debt', timestamptz '2026-02-15 10:00:00+00');

  v_cycle_feb := finance.calculate_profit_distribution(
    v_well, timestamptz '2026-02-01 00:00:00+00', timestamptz '2026-03-01 00:00:00+00', v_profile, 0
  );
  -- يثبت هذا الفحص سلوكين موثقين معًا: احتجاز مستحقات الشركاء المعتمدة غير المدفوعة قبل توزيع جديد (withhold_liabilities)،
  -- وخصم سقي الشريك من الأرباح بصاف سالب.
  if exists (
    select 1 from finance.profit_distribution_lines
    where distribution_cycle_id = v_cycle_feb and partner_id = v_partner
      and gross_share_minor = 0 and irrigation_deductions_minor = 6000
      and net_payable_minor = -6000
  ) then
    raise notice 'PASS 3: حُجزت مستحقات يناير المعتمدة غير المدفوعة 9000 فصار متاح فبراير صفرًا، وخُصم سقي الشريك 6000 فظهر صافيه -6000';
  else raise notice 'FAIL 3: لم تُحجز مستحقات يناير 9000 أو لم يصبح متاح فبراير صفرًا أو لم يظهر خصم السقي 6000 بصاف -6000'; end if;

  begin
    perform finance.approve_profit_distribution(v_cycle_feb, v_profile);
    raise notice 'FAIL 4: سُمح باعتماد أرباح أقل من استقطاعات الشريك';
  exception when others then
    if position('صافي مستحقه سالب' in sqlerrm) > 0 then
      raise notice 'PASS 4: رُفض اعتماد دورة أرباح أقل من استقطاعات الشريك';
    else raise notice 'FAIL 4: سبب رفض الدورة السالبة غير متوقع: %', sqlerrm; end if;
  end;

  begin
    insert into core.ownership_share_versions
      (tenant_id, well_id, partner_id, ownership_percentage, profit_percentage, effective_period, approved_by)
    values
      (v_tenant, v_well, v_partner, 100, 100, daterange(date '2026-06-01', null, '[)'), v_profile);
    raise notice 'FAIL 5: سُمح بتداخل إصدارين لنسبة الشريك';
  exception when exclusion_violation then
    raise notice 'PASS 5: رُفض تداخل إصدارات نسب الشريك تاريخيًا';
  when others then
    raise notice 'FAIL 5: رُفض تداخل النسب لسبب غير متوقع: %', sqlerrm;
  end;

  update core.ownership_share_versions
  set effective_period = daterange(date '2026-01-01', date '2026-06-01', '[)')
  where id = v_share;
  insert into core.ownership_share_versions
    (tenant_id, well_id, partner_id, ownership_percentage, profit_percentage, effective_period, approved_by)
  values
    (v_tenant, v_well, v_partner, 100, 100, daterange(date '2026-06-01', null, '[)'), v_profile);
  execute 'set constraints all immediate';
  if (select count(*) from core.ownership_share_versions where partner_id = v_partner) = 2 then
    raise notice 'PASS 6: قُبل تغير نسبة الشريك بإصدار جديد متجاور بلا تداخل';
  else raise notice 'FAIL 6: لم يُحفظ الإصدار التاريخي المتجاور'; end if;
  execute 'set constraints all deferred';

  insert into core.wells (tenant_id, name) values (v_tenant, 'بئر باقي القسمة 067') returning id into v_remainder_well;
  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_remainder_well, v_profile, 'owner', 'active');
  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع باقي القسمة', 'مزارع باقي القسمة') returning id into v_remainder_person;
  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_remainder_person) returning id into v_remainder_fp;
  insert into ops.farmer_well_accounts (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_remainder_fp, v_remainder_well, 'FWA-067-REM') returning id into v_remainder_fwa;

  for v_i in 1..3 loop
    insert into core.persons (tenant_id, full_name, normalized_name)
    values (v_tenant, 'شريك باقي ' || v_i, 'شريك باقي ' || v_i)
    returning id into v_remainder_person;
    insert into core.well_partners (tenant_id, well_id, person_id, phone)
    values (v_tenant, v_remainder_well, v_remainder_person, '73206700' || v_i)
    returning id into v_remainder_partner;
    v_remainder_partners := array_append(v_remainder_partners, v_remainder_partner);
    v_pct := case v_i when 1 then 40 when 2 then 35 else 25 end;
    insert into core.ownership_share_versions
      (tenant_id, well_id, partner_id, ownership_percentage, profit_percentage, effective_period, approved_by)
    values
      (v_tenant, v_remainder_well, v_remainder_partner, v_pct, v_pct,
       daterange(date '2026-01-01', null, '[)'), v_profile);
  end loop;
  execute 'set constraints all immediate';
  execute 'set constraints all deferred';

  insert into billing.payments (farmer_well_account_id, amount_minor, method, purpose, paid_at)
  values (v_remainder_fwa, 2, 'cash', 'old_debt', timestamptz '2026-03-10 10:00:00+00');
  v_remainder_cycle := finance.calculate_profit_distribution(
    v_remainder_well, timestamptz '2026-03-01 00:00:00+00', timestamptz '2026-04-01 00:00:00+00', v_profile, 0
  );
  if (select gross_share_minor from finance.profit_distribution_lines
      where distribution_cycle_id = v_remainder_cycle and partner_id = v_remainder_partners[1]) = 2
     and (select gross_share_minor from finance.profit_distribution_lines
          where distribution_cycle_id = v_remainder_cycle and partner_id = v_remainder_partners[2]) = 0
     and (select gross_share_minor from finance.profit_distribution_lines
          where distribution_cycle_id = v_remainder_cycle and partner_id = v_remainder_partners[3]) = 0 then
    raise notice 'PASS 7: باقي مبلغ وحدتين ذهب كله لصاحب أكبر حصة 40 بالمئة حسب ق-74 وق-77';
  else raise notice 'FAIL 7: توزيع باقي القسمة لا يطابق قرار صاحب أكبر حصة'; end if;

  if (select sum(gross_share_minor) from finance.profit_distribution_lines
      where distribution_cycle_id = v_remainder_cycle) = 2 then
    raise notice 'PASS 8: مجموع حصص التوزيع يساوي المبلغ المحصل بالضبط';
  else raise notice 'FAIL 8: مجموع حصص التوزيع لا يساوي الأصل'; end if;

  raise notice '--- انتهى اختبار الشركاء والتوزيع 067 (8 فحوص) ---';
end $$;

rollback;
