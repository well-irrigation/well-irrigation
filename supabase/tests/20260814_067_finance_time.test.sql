begin;

set local timezone to 'UTC';

-- ق-12: اختبارات تقريب 1->15 و15->15 و16->30 وتقريب المصدر ملغاة بقرار إلغاء التقريب.
-- ق-75 / م-21: تعارض جهازين وتصحيح فاتورة عبر التطبيق مؤجلان إلى مرحلة التطبيق.
-- م-21: اختبار دمج الأشخاص الميداني مؤجل؛ الاختبار الدائم 062 يغطي محرك الدمج نفسه.
-- ق-77: سيناريوهات الجزء من ألف والرصيد الكسري منسوخة باعتماد الريال اليمني الكامل.

do $$
declare
  v_tenant uuid; v_well uuid; v_user uuid; v_profile uuid; v_admin uuid;
  v_person uuid; v_payer uuid; v_fp uuid; v_fwa uuid; v_farm uuid;
  v_pump uuid; v_pump_61 uuid; v_pump_75 uuid; v_pump_fraction uuid; v_pump_month uuid; v_pump_long uuid;
  v_session uuid; v_charge uuid; v_shift uuid; v_handover uuid;
  v_entry_unbalanced uuid; v_entry_closed uuid; v_entry_offset uuid; v_period uuid; v_request uuid;
  v_partner_person uuid; v_partner uuid; v_batch uuid; v_cashbox uuid;
  v_debit uuid; v_credit uuid; v_result text; v_count bigint; v_amount bigint;
  v_partners uuid[] := array[]::uuid[];
  v_i integer;
begin
  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'finance067@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_user;

  select id into v_profile from iam.profiles where id = v_user;
  if not found then
    insert into iam.profiles (id, full_name) values (v_user, 'مالك اختبار المال 067') returning id into v_profile;
  end if;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'admin067@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_admin;
  update iam.profiles set full_name = 'مدير عام اختبار 067', is_platform_admin = true where id = v_admin;

  insert into core.tenants (name) values ('جهة اختبار المال والوقت 067') returning id into v_tenant;
  insert into core.wells (tenant_id, name) values (v_tenant, 'بئر اختبار المال والوقت 067') returning id into v_well;
  insert into core.well_assignments (well_id, profile_id, role, status) values (v_well, v_profile, 'owner', 'active');
  v_cashbox := finance.main_cashbox_id(v_well);

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع اختبار المال', 'مزارع اختبار المال') returning id into v_person;
  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'دافع نيابة عن المزارع', 'دافع نيابة عن المزارع') returning id into v_payer;
  insert into ops.farmer_profiles (tenant_id, person_id) values (v_tenant, v_person) returning id into v_fp;
  insert into ops.farmer_well_accounts (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_fp, v_well, 'FWA-067-FIN') returning id into v_fwa;
  insert into ops.farms (well_id, name) values (v_well, 'مزرعة اختبار المال') returning id into v_farm;
  insert into core.pumps (well_id, name, power_source) values (v_well, 'مضخة دفعات', 'solar') returning id into v_pump;

  v_debit := finance.ledger_account_id(v_well, '1000');
  v_credit := finance.ledger_account_id(v_well, '3000');

  insert into finance.journal_entries
    (tenant_id, public_code, well_id, entry_date, source_type, source_id, description, idempotency_key)
  values
    (v_tenant, 'JE-067-UNBAL', v_well, timestamptz '2026-03-10 10:00:00+00',
     'manual_test', gen_random_uuid(), 'قيد غير متوازن للاختبار', '067-UNBAL')
  returning id into v_entry_unbalanced;
  insert into finance.journal_lines
    (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, cashbox_id)
  values
    (v_tenant, v_entry_unbalanced, v_debit, 'debit', 100, v_cashbox),
    (v_tenant, v_entry_unbalanced, v_credit, 'credit', 99, null);
  begin
    perform finance.post_journal_entry(v_entry_unbalanced, v_profile);
    raise notice 'FAIL 1: سُمح بترحيل قيد غير متوازن';
  exception when others then
    if position('القيد غير متوازن' in sqlerrm) > 0 then
      raise notice 'PASS 1: رُفض القيد غير المتوازن برسالة صريحة';
    else raise notice 'FAIL 1: سبب رفض القيد غير متوقع: %', sqlerrm; end if;
  end;

  perform finance.ensure_periods(v_well, date '2026-03-10');
  select id into v_period from finance.accounting_periods
  where well_id = v_well and period_type = 'monthly' and starts_at = date '2026-03-01';
  perform finance.close_period(v_period, v_profile);

  insert into finance.journal_entries
    (tenant_id, public_code, well_id, entry_date, source_type, source_id, description, idempotency_key)
  values
    (v_tenant, 'JE-067-CLOSED', v_well, timestamptz '2026-03-11 10:00:00+00',
     'manual_test', gen_random_uuid(), 'قيد في فترة مغلقة', '067-CLOSED')
  returning id into v_entry_closed;
  insert into finance.journal_lines
    (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, cashbox_id)
  values
    (v_tenant, v_entry_closed, v_debit, 'debit', 100, v_cashbox),
    (v_tenant, v_entry_closed, v_credit, 'credit', 100, null);
  begin
    perform finance.post_journal_entry(v_entry_closed, v_profile);
    raise notice 'FAIL 2: سُمح بالترحيل داخل فترة مغلقة';
  exception when others then
    if position('الفترة المحاسبية' in sqlerrm) > 0 and position('مغلقة' in sqlerrm) > 0 then
      raise notice 'PASS 2: رُفض الترحيل داخل الفترة المغلقة';
    else raise notice 'FAIL 2: سبب رفض الفترة المغلقة غير متوقع: %', sqlerrm; end if;
  end;

  for v_i in 1..4 loop
    insert into core.persons (tenant_id, full_name, normalized_name)
    values (v_tenant, 'شريك إعادة فتح ' || v_i, 'شريك إعادة فتح ' || v_i)
    returning id into v_partner_person;
    insert into core.well_partners (tenant_id, well_id, person_id, phone)
    values (v_tenant, v_well, v_partner_person, '73006700' || v_i)
    returning id into v_partner;
    v_partners := array_append(v_partners, v_partner);
  end loop;

  v_request := finance.request_period_reopen(v_period, v_profile, 'تصحيح قيد بعد مراجعة موثقة');
  perform finance.approve_period_reopen(v_request, v_partners[1]);
  perform finance.approve_period_reopen(v_request, v_partners[2]);
  if (select status from finance.period_reopen_requests where id = v_request) = 'pending' then
    raise notice 'PASS 3: صوتان من أربعة لم يكملا حد 70 بالمئة';
  else raise notice 'FAIL 3: اكتمل التصويت قبل بلوغ 70 بالمئة'; end if;

  perform finance.approve_period_reopen(v_request, v_partners[3]);
  perform finance.decide_period_reopen(v_request, v_admin, true, 'اعتماد إعادة الفتح للاختبار');
  perform finance.post_journal_entry(v_entry_closed, v_profile);
  if (select status from finance.accounting_periods where id = v_period) = 'reopened'
     and (select status from finance.journal_entries where id = v_entry_closed) = 'posted' then
    raise notice 'PASS 4: ثلاثة من أربعة أكملوا 70 بالمئة ثم أعاد المدير العام الفتح وأتاح الترحيل';
  else raise notice 'FAIL 4: دورة إعادة فتح الفترة لم تكتمل'; end if;

  insert into ops.irrigation_sessions
    (well_id, pump_id, farm_id, farmer_well_account_id, operator_profile_id, started_at)
  values
    (v_well, v_pump, v_farm, v_fwa, v_profile, timestamptz '2026-03-12 08:00:00+00')
  returning id into v_session;
  insert into billing.session_charges
    (session_id, well_id, duration_seconds, price_per_hour_minor, amount_minor)
  values (v_session, v_well, 3600, 1000, 1000) returning id into v_charge;

  insert into billing.payments
    (session_charge_id, farmer_well_account_id, payer_person_id, amount_minor, method, paid_at)
  values (v_charge, v_fwa, v_payer, 400, 'cash', timestamptz '2026-03-12 09:00:00+00');
  select coalesce(sum(amount_minor), 0) into v_amount from billing.payments
  where session_charge_id = v_charge and status = 'posted';
  if v_amount = 400 then
    raise notice 'PASS 5: الدفعة الجزئية سجلت 400 وبقي من المستحق 600';
  else raise notice 'FAIL 5: مجموع الدفعة الجزئية = %', v_amount; end if;

  insert into billing.payments
    (session_charge_id, farmer_well_account_id, payer_person_id, amount_minor, method, paid_at)
  values (v_charge, v_fwa, v_payer, 600, 'cash', timestamptz '2026-03-12 09:05:00+00');
  select coalesce(sum(amount_minor), 0) into v_amount from billing.payments
  where session_charge_id = v_charge and status = 'posted';
  if v_amount = 1000 then
    raise notice 'PASS 6: الدفعة الثانية أكملت السداد الكامل دون زيادة';
  else raise notice 'FAIL 6: مجموع السداد الكامل = %', v_amount; end if;

  if (select count(*) from billing.payments
      where session_charge_id = v_charge and payer_person_id = v_payer) = 2 then
    raise notice 'PASS 7: حُفظت هوية الشخص الذي دفع نيابة عن المزارع';
  else raise notice 'FAIL 7: لم تُحفظ هوية الدافع نيابة عن المزارع'; end if;

  insert into billing.payments
    (farmer_well_account_id, amount_minor, method, purpose, paid_at)
  values (v_fwa, 300, 'cash', 'advance', timestamptz '2026-03-12 09:10:00+00');
  insert into finance.journal_entries
    (tenant_id, public_code, well_id, entry_date, source_type, source_id, description, idempotency_key)
  values
    (v_tenant, 'JE-067-OFFSET', v_well, timestamptz '2026-03-12 09:15:00+00',
     'advance_offset', gen_random_uuid(), 'استخدام رصيد مقدم لسداد ذمة', '067-OFFSET')
  returning id into v_entry_offset;
  insert into finance.journal_lines
    (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, farmer_well_account_id)
  values
    (v_tenant, v_entry_offset, finance.ledger_account_id(v_well, '2000'), 'debit', 300, v_fwa),
    (v_tenant, v_entry_offset, finance.ledger_account_id(v_well, '1100'), 'credit', 300, v_fwa);
  perform finance.post_journal_entry(v_entry_offset, v_profile);
  if (select status from finance.journal_entries where id = v_entry_offset) = 'posted' then
    raise notice 'PASS 8: استخدام الرصيد المقدم رحّل 2000 مدينًا مقابل 1100 دائنًا';
  else raise notice 'FAIL 8: لم يترحل قيد استخدام الرصيد المقدم'; end if;

  v_shift := ops.open_shift(v_well, v_profile);
  v_handover := ops.declare_handover(v_shift, 1000, v_admin, null, 'اختبار فرق الصندوق');
  v_result := ops.confirm_handover(v_handover, 900, v_admin, 'نقص مئة ريال عند العد');
  if v_result = 'difference_pending'
     and (select difference_minor from ops.shift_handovers where id = v_handover) = -100 then
    raise notice 'PASS 9: فرق صندوق تسليم المناوبة حُفظ بقيمة -100 وحالة معلقة';
  else raise notice 'FAIL 9: فرق تسليم المناوبة غير صحيح'; end if;

  perform ops.settle_handover(v_handover, v_profile);
  if (select status from ops.shift_handovers where id = v_handover) = 'settled' then
    raise notice 'PASS 10: حُسم فرق تسليم المناوبة ورفعت مسؤوليته';
  else raise notice 'FAIL 10: لم يُحسم فرق التسليم'; end if;

  insert into finance.opening_balance_batches
    (tenant_id, well_id, reference_date, notes, created_by)
  values (v_tenant, v_well, date '2025-12-31', 'أرصدة قديمة للاختبار', v_profile)
  returning id into v_batch;
  insert into finance.opening_balance_items
    (tenant_id, batch_id, item_type, cashbox_id, amount_minor, description)
  values
    (v_tenant, v_batch, 'cashbox_balance', v_cashbox, 1200, 'رصيد صندوق قديم'),
    (v_tenant, v_batch, 'capital_balance', null, 1200, 'مقابل رأس المال');
  perform finance.approve_opening_balance_batch(v_batch, v_profile);
  perform finance.post_opening_balance_batch(v_batch, v_profile);
  if (select status from finance.opening_balance_batches where id = v_batch) = 'posted'
     and exists (select 1 from finance.journal_entries where source_type = 'opening_balance' and source_id = v_batch and status = 'posted') then
    raise notice 'PASS 11: الأرصدة القديمة المتوازنة اعتُمدت ورُحلت بقيد افتتاحي';
  else raise notice 'FAIL 11: لم تترحل الأرصدة القديمة'; end if;

  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well, 3600, date '2026-01-01');

  insert into core.pumps (well_id, name, power_source) values (v_well, 'مضخة 61 دقيقة', 'solar') returning id into v_pump_61;
  insert into ops.irrigation_sessions (well_id, pump_id, farm_id, operator_profile_id, started_at)
  values (v_well, v_pump_61, v_farm, v_profile, timestamptz '2026-04-01 08:00:00+00') returning id into v_session;
  update ops.irrigation_sessions set ended_at = timestamptz '2026-04-01 09:01:00+00', status = 'closed' where id = v_session;
  if (select duration_seconds = 3660 and amount_minor = 3660 from billing.session_charges where session_id = v_session) then
    raise notice 'PASS 12: جلسة شمس 1:01 حُسبت 3660 ثانية بلا تقريب';
  else raise notice 'FAIL 12: جلسة 1:01 لم تُحسب حرفيًا'; end if;

  insert into core.pumps (well_id, name, power_source) values (v_well, 'مضخة 75 دقيقة', 'solar') returning id into v_pump_75;
  insert into ops.irrigation_sessions (well_id, pump_id, farm_id, operator_profile_id, started_at)
  values (v_well, v_pump_75, v_farm, v_profile, timestamptz '2026-04-01 10:00:00+00') returning id into v_session;
  update ops.irrigation_sessions set ended_at = timestamptz '2026-04-01 11:15:00+00', status = 'closed' where id = v_session;
  if (select duration_seconds = 4500 and amount_minor = 4500 from billing.session_charges where session_id = v_session) then
    raise notice 'PASS 13: جلسة شمس 1:15 حُسبت 4500 ثانية بلا تقريب';
  else raise notice 'FAIL 13: جلسة 1:15 لم تُحسب حرفيًا'; end if;

  update billing.well_pricing
  set period_end = date '2026-04-02'
  where well_id = v_well and period_start = date '2026-01-01';
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well, 5000, date '2026-04-02');

  insert into core.pumps (well_id, name, power_source) values (v_well, 'مضخة كسر الريال', 'solar') returning id into v_pump_fraction;
  insert into ops.irrigation_sessions (well_id, pump_id, farm_id, operator_profile_id, started_at)
  values (v_well, v_pump_fraction, v_farm, v_profile, timestamptz '2026-04-02 12:00:00+00') returning id into v_session;
  update ops.irrigation_sessions set ended_at = timestamptz '2026-04-02 12:00:01+00', status = 'closed' where id = v_session;
  select amount_minor into v_amount from billing.session_charges where session_id = v_session;
  if v_amount = 1 then
    raise notice 'PASS 14: كسر الريال 1.388 اقتُطع إلى ريال كامل واحد حسب ق-71 وق-77';
  else raise notice 'FAIL 14: ناتج كسر الريال = % والمتوقع 1', v_amount; end if;

  insert into core.pumps (well_id, name, power_source) values (v_well, 'مضخة نهاية الشهر', 'solar') returning id into v_pump_month;
  insert into ops.irrigation_sessions (well_id, pump_id, farm_id, operator_profile_id, started_at)
  values (v_well, v_pump_month, v_farm, v_profile, timestamptz '2026-01-31 23:30:00+00') returning id into v_session;
  update ops.irrigation_sessions set ended_at = timestamptz '2026-02-01 02:00:00+00', status = 'closed' where id = v_session;
  if exists (select 1 from reporting.well_daily_summary where well_id = v_well and day = date '2026-02-01' and charges_minor >= 9000)
     and not exists (select 1 from reporting.well_daily_summary where well_id = v_well and day = date '2026-01-31' and sessions_count > 0) then
    raise notice 'PASS 15: جلسة نهاية الشهر نُسبت كاملة إلى فبراير يوم النهاية';
  else raise notice 'FAIL 15: جلسة نهاية الشهر لم تُنسب حصريًا إلى يوم النهاية'; end if;

  insert into core.pumps (well_id, name, power_source) values (v_well, 'مضخة الجلسة المنسية', 'solar') returning id into v_pump_long;
  insert into ops.irrigation_sessions (well_id, pump_id, farm_id, operator_profile_id, started_at)
  values (v_well, v_pump_long, v_farm, v_profile, now() - interval '7 hours') returning id into v_session;
  perform ops.flag_long_running_sessions();
  if (select status from ops.irrigation_sessions where id = v_session) = 'open'
     and exists (select 1 from ops.notifications where session_id = v_session and type = 'long_session') then
    raise notice 'PASS 16: الجلسة المنسية بقيت مفتوحة وأنتجت تنبيهًا بعد تجاوز ست ساعات';
  else raise notice 'FAIL 16: تنبيه الجلسة المنسية أو منع الإقفال التلقائي غير صحيح'; end if;

  raise notice '--- انتهى اختبار المال والوقت 067 (16 فحصا) ---';
end $$;

rollback;
