-- ق-131 البند 18 / م-45 المرحلة A: حيازة المشغل النقدية والترحيل.
-- هذا اختبار DB فقط؛ كل التغييرات تتراجع في النهاية.
--
-- ما يثبه هذا الملف (مطابق لأبنود عقد الهجرة 109):
--   1-3.  صندوق حيازة نشط واحد لكل (بئر، مشغل)، وضمانه المتكرر يُعيد
--         نفسه، ومشغلا مختلفان لهما صندوقان مختلفان.
--   4-5.  مناوبة المشغل تنطلق من حيازته، ومناوبة غير المشغل (المالك)
--         تبقى على صندوق البئر العام.
--   6-11. نقد المزارع بيد مشغل يدخل الحيازة حصرًا (القيد المدين
--         بصندوق الحيازة، والصندوق العام لا يستلمه، وتمرير معرف
--         صندوق آخر يُرفض)، وسلوك المالك/غير المشغل كما كان، وزيادة
--         الدفعة (مقدم) ترث الصندوق الحاكم فتتغير الحيازة مرة واحدة.
--   12-13. مصروف المشغل من 'cashbox' يخفض الحيازة، ومن مصدر آخر
--         (unpaid_payable) لا يخفضها مجرد أن مشغلًا سجّله.
--   14-16. إقرار ترحيل فوق الحيازة يُرفض؛ والإقرار ينشئ صف
--         shift_handovers من النوع الصريح بلا قيد يومية.
--   17-24. التأكيد للمالك: المطابقة التامة تنشر قيد نقل واحد
--         (1000 مدين للعام / 1000 دائن للحيازة) بلا حساب إيراد أو
--         ذمم أو مقدم أو مصروف، والحيازة تنقص والعام يزيد والمجموع
--         ثابت؛ والتأكيد الثاني لنفس الإقرار لا يخلق قيدًا ثانيًا؛
--         وغير المصرح له لا يؤكد.
--   25-27. تسلسل التزامن: إقرارا ترحيل مستقلان على الحيازة نفسها
--         قُبلا فرديًا؛ تأكيد الأول نشر قيده وخفض الحيازة؛ وتأكيد
--         الثاني — فوق المتبقي بعد قفل صف صندوق المصدر — رُفض بلا
--         أي قيد وبلا حيازة سالبة.
--   28-29. الفرق يعلق difference_pending بلا قيد؛ وحسم فرق الترحيل
--         محجوب بعقد تسوية مالية مخصص.
--   30.   التسليم الشخصي القائم يبقى كما هو ولا يصير ترحيل بئر.
--   31-33. الحيازة المقروءة = رصيد الدفتر في operator_totals
--         (unsettled_minor وcustody_minor) وفي api.get_my_operator_
--         cash_custody.
--   34-35. وصول غير المصادَق للعقدين الجديدين محجوب، وحماية الإدخال
--         المباشر كما هي (ق-79).
--   36.   حرس بنيوي: تعريف confirm_handover الحي يقفل صف
--         finance.cashboxes بقفل FOR UPDATE.
--
-- القراءة والتحقق تجري بلسان المالك (يقرأ كل أسطر البئر)، والأفعال
-- تبديل أدوار: بلسان المشغل للتحصيل والإقرار، ولسان المالك للتأكيد.

\set ON_ERROR_STOP on

begin;

set local timezone to 'UTC';

do $test$
declare
  v_owner uuid;
  v_op1 uuid;
  v_op2 uuid;
  v_tenant uuid;
  v_well1 uuid;
  v_well2 uuid;
  v_person uuid;
  v_farmer_profile uuid;
  v_farmer_account uuid;
  v_farm uuid;
  v_custody1 uuid;
  v_custody1_again uuid;
  v_custody2 uuid;
  v_main1 uuid;
  v_main2 uuid;
  v_shift1 uuid;
  v_shift2 uuid;
  v_pay_owner jsonb;
  v_pay_adv jsonb;
  v_rem1 uuid;
  v_rem2 uuid;
  v_rem3 uuid;
  v_je_rem1 uuid;
  v_ret text;
  v_err text;
  v_balance bigint;
  v_main_before bigint;
  v_custody_before bigint;
  v_total_before bigint;
  v_total_after bigint;
  v_count bigint;
  v_line record;
  v_ok boolean;
begin
  -- -------------------------------------------------------------
  -- التجهيز: جهة وبئران — بئر 1 لمشغلين ومالك وبئر 2 للمالك وحده.
  -- -------------------------------------------------------------
  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q131-custody-owner@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_owner;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q131-custody-op1@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_op1;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q131-custody-op2@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_op2;

  insert into core.tenants (name)
  values ('جهة اختبار الحيازة 109')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'بئر الحيازة 109')
  returning id into v_well1;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'بئر الحيازة 109 - المالك وحده')
  returning id into v_well2;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_well1, v_owner, 'owner', 'active'),
         (v_well1, v_op1, 'operator', 'active'),
         (v_well1, v_op2, 'operator', 'active'),
         (v_well2, v_owner, 'owner', 'active');

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع الحيازة 109', 'مزارع الحيازة 109')
  returning id into v_person;

  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person)
  returning id into v_farmer_profile;

  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_farmer_profile, v_well1, 'FWA-109')
  returning id into v_farmer_account;

  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well1, 'مزرعة الحيازة 109', v_farmer_account)
  returning id into v_farm;

  v_main1 := finance.main_cashbox_id(v_well1);
  v_main2 := finance.main_cashbox_id(v_well2);

  -- -------------------------------------------------------------
  -- 2-3. ضمان الحيازة: التكرار يعيد نفس الصندوق، والمشغلان مختلفان.
  -- -------------------------------------------------------------
  v_custody1 := finance.ensure_operator_custody_cashbox(v_well1, v_op1);
  v_custody1_again := finance.ensure_operator_custody_cashbox(v_well1, v_op1);

  if v_custody1 is not null and v_custody1 = v_custody1_again then
    raise notice 'PASS 2: ضمان الحيازة المتكرر يعيد الصندوق نفسه';
  else
    raise notice 'FAIL 2: ضمان الحيازة المتكرر أنشأ أو أعاد صندوقًا مختلفًا';
  end if;

  v_custody2 := finance.ensure_operator_custody_cashbox(v_well1, v_op2);

  if v_custody2 is distinct from v_custody1 then
    raise notice 'PASS 3: مشغلان مختلفان لهما صندوقا حيازة مختلفان';
  else
    raise notice 'FAIL 3: مشغلا مختلفان حصلا على الصندوق نفسه';
  end if;

  -- -------------------------------------------------------------
  -- 4. مناوبة المشغل تنطلق من حيازته.
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_op1::text, true);
  execute 'set local role authenticated';

  v_shift1 := api.open_shift(v_well1);

  if v_shift1 is not null and exists (
    select 1 from ops.shifts s
    where s.id = v_shift1 and s.cashbox_id = v_custody1
  ) then
    raise notice 'PASS 4: مناوبة المشغل مربوطة بصندوق حيازته';
  else
    raise notice 'FAIL 4: مناوبة المشغل لم ترتبط بصندوق حيازته';
  end if;

  -- -------------------------------------------------------------
  -- 5. مناوبة غير المشغل (المالك) تبقى على صندوق البئر العام.
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_shift2 := api.open_shift(v_well2);

  if v_shift2 is not null and exists (
    select 1 from ops.shifts s
    where s.id = v_shift2 and s.cashbox_id = v_main2
  ) then
    raise notice 'PASS 5: مناوبة غير المشغل حافظت على سلوك الصندوق العام';
  else
    raise notice 'FAIL 5: مناوبة غير المشغل لم تعد إلى الصندوق العام';
  end if;

  -- -------------------------------------------------------------
  -- 6-8. تحصيل المشغل النقدي يدخل الحيازة حصرًا.
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_op1::text, true);

  v_pay_owner := null;
  v_pay_owner := api.record_payment(
    v_well1, v_farmer_account, 1000, 'cash', '[]'::jsonb
  );

  if v_pay_owner ->> 'payment_id' is not null and exists (
    select 1 from billing.payments p
    where p.id = (v_pay_owner ->> 'payment_id')::uuid
      and p.cashbox_id = v_custody1
      and p.status = 'posted'
  ) then
    raise notice 'PASS 6: التحصيل النقدي للمشغل استقر في حيازته';
  else
    raise notice 'FAIL 6: التحصيل النقدي للمشغل لم يدخل حيازته';
  end if;

  -- قراءة أسطر القيد بلسان المالك.
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  select l.cashbox_id into v_line
  from finance.journal_lines l
  where l.journal_entry_id = (v_pay_owner ->> 'journal_entry_id')::uuid
    and l.entry_side = 'debit';

  if v_line.cashbox_id = v_custody1 then
    raise notice 'PASS 7: سطر القيد المدين للدفعة يشير إلى حيازة المشغل';
  else
    raise notice 'FAIL 7: القيد المدين للدفعة لا يشير إلى الحيازة';
  end if;

  select finance.cashbox_balance_minor(v_main1) into v_balance;
  if v_balance = 0 then
    raise notice 'PASS 8: صندوق البئر العام لم يستلم نقد المشغل';
  else
    raise notice 'FAIL 8: صندوق البئر العام استلم نقد المشغل (الرصيد %)', v_balance;
  end if;

  -- -------------------------------------------------------------
  -- 9. المشغل لا يستطيع توجيه النقد إلى العام بتمرير معرفه.
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_op1::text, true);

  v_err := null;
  begin
    perform api.record_payment(
      v_well1, v_farmer_account, 50, 'cash', '[]'::jsonb,
      null, null, v_main1
    );
  exception when others then
    v_err := sqlerrm;
  end;

  if v_err like '%حيازة المشغل%' then
    raise notice 'PASS 9: تمرير صندوق العام من المشغل رُفض صراحة';
  else
    raise notice 'FAIL 9: سلوك غير متوقع عند تمرير صندوق العام: %', coalesce(v_err, 'لم يُرفض');
  end if;

  -- -------------------------------------------------------------
  -- 10. تحصيل المالك (غير المشغل) يحافظ على سلوك الصندوق العام.
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_pay_owner := api.record_payment(
    v_well1, v_farmer_account, 300, 'cash', '[]'::jsonb
  );

  if exists (
    select 1 from billing.payments p
    where p.id = (v_pay_owner ->> 'payment_id')::uuid
      and p.cashbox_id = v_main1
  ) and finance.cashbox_balance_minor(v_main1) = 300 then
    raise notice 'PASS 10: تحصيل المالك النقدي دخل الصندوق العام كما كان';
  else
    raise notice 'FAIL 10: سلوك تحصيل المالك تغير عن الصندوق العام';
  end if;

  -- -------------------------------------------------------------
  -- 11. استلام 500 بلا تخصيص = رصيد مقدم في الحيازة مرة واحدة
  --     (الحيازة +500 حرفًا لا +1000).
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_op1::text, true);

  v_pay_adv := api.record_payment(
    v_well1, v_farmer_account, 500, 'cash', '[]'::jsonb
  );

  if exists (
    select 1 from billing.payments p
    where p.id = (v_pay_adv ->> 'payment_id')::uuid
      and p.purpose = 'advance'
      and p.cashbox_id = v_custody1
  ) and finance.cashbox_balance_minor(v_custody1) = 1500
    and finance.cashbox_balance_minor(v_main1) = 300 then
    raise notice 'PASS 11: زيادة/مقدم الاستلام ورث الحيازة فتغيرت مرة واحدة (1500)';
  else
    raise notice 'FAIL 11: الحيازة تغيرت أكثر أو أقل من مبلغ الاستلام مرة واحدة';
  end if;

  -- -------------------------------------------------------------
  -- 12. مصروف المشغل من cashbox يخفض الحيازة (مصروف بئر بقي بئريًا).
  -- -------------------------------------------------------------
  perform api.record_expense(
    v_well1, 'salaries', 200, 'أجور حراسة من حيازة المشغل',
    null, true, 'cashbox'
  );

  if finance.cashbox_balance_minor(v_custody1) = 1300 then
    raise notice 'PASS 12: مصروف cashbox للمشغل خفض الحيازة إلى 1300';
  else
    raise notice 'FAIL 12: مصروف cashbox للمشغل لم يخفض الحيازة كما يجب';
  end if;

  -- -------------------------------------------------------------
  -- 13. مصروف المشغل من unpaid_payable لا يخفض الحيازة.
  -- -------------------------------------------------------------
  perform api.record_expense(
    v_well1, 'salaries', 300, 'مصروف مؤجل من المشغل',
    null, true, 'unpaid_payable'
  );

  if finance.cashbox_balance_minor(v_custody1) = 1300 then
    raise notice 'PASS 13: مصروف من مصدر آخر لم يمس حيازة المشغل';
  else
    raise notice 'FAIL 13: مصروف من مصدر آخر خفض الحيازة ظلمًا';
  end if;

  -- -------------------------------------------------------------
  -- 14. إقرار ترحيل فوق الحيازة يُرفض.
  -- -------------------------------------------------------------
  v_err := null;
  begin
    perform api.declare_operator_cash_remittance(v_shift1, 9999, null);
  exception when others then
    v_err := sqlerrm;
  end;

  if v_err like '%فوق المتوفر%' or v_err like '%يتجاوز حيازة%' then
    raise notice 'PASS 14: إقرار ترحيل فوق الحيازة رُفض';
  else
    raise notice 'FAIL 14: إقرار فوق الحيازة لم يُرفض كما يجب: %', coalesce(v_err, 'لم يُرفض');
  end if;

  -- -------------------------------------------------------------
  -- 15-16. الإقرار الصحيح: صف shift_handovers من النوع الصريح،
  --        بلا قيد يومية.
  -- -------------------------------------------------------------
  v_main_before := finance.cashbox_balance_minor(v_main1);
  v_custody_before := finance.cashbox_balance_minor(v_custody1);
  v_total_before := v_main_before + v_custody_before;

  v_rem1 := api.declare_operator_cash_remittance(v_shift1, 1300, 'ترحيل دوري');

  if v_rem1 is not null and exists (
    select 1 from ops.shift_handovers h
    where h.id = v_rem1
      and h.handover_kind = 'operator_cash_remittance'
      and h.from_cashbox_id = v_custody1
      and h.to_cashbox_id = v_main1
      and h.declared_amount_minor = 1300
      and h.status = 'declared'
  ) then
    raise notice 'PASS 15: الإقرار أنشأ صف تسليم قائمًا من النوع الصريح';
  else
    raise notice 'FAIL 15: صف الترحيل لم ينشأ في shift_handovers كما يجب';
  end if;

  if not exists (
    select 1 from finance.journal_entries je
    where je.source_type = 'operator_cash_remittance' and je.source_id = v_rem1
  ) then
    raise notice 'PASS 16: الإقرار لم ينشئ أي قيد يومية';
  else
    raise notice 'FAIL 16: الإقرار أنشأ قيدًا قبل تأكيد المالك';
  end if;

  -- -------------------------------------------------------------
  -- 17. غير المصرح له (مشغل آخر) لا يؤكد الترحيل.
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_op2::text, true);

  v_err := null;
  begin
    perform api.confirm_handover(v_rem1, 1300, null);
  exception when others then
    v_err := sqlerrm;
  end;

  if v_err like '%خاص بمالك البئر%' or v_err like '%صلاحية%' then
    raise notice 'PASS 17: غير المصرح له حُجب عن تأكيد الترحيل';
  else
    raise notice 'FAIL 17: تأكيد غير المصرح له لم يُحجب: %', coalesce(v_err, 'لم يُرفض');
  end if;

  -- -------------------------------------------------------------
  -- 18-20. تأكيد المالك المطابق: قيد نقل واحد مرحل، طرفاه 1000،
  --        بلا حساب آخر إطلاقًا.
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_ret := api.confirm_handover(v_rem1, 1300, null);

  select je.id into v_je_rem1
  from finance.journal_entries je
  where je.source_type = 'operator_cash_remittance' and je.source_id = v_rem1;

  if v_ret = 'confirmed' and v_je_rem1 is not null and exists (
    select 1 from finance.journal_entries je
    where je.id = v_je_rem1 and je.status = 'posted'
  ) and (select count(*) from finance.journal_entries je
         where je.source_type = 'operator_cash_remittance' and je.source_id = v_rem1) = 1 then
    raise notice 'PASS 18: التأكيد المطابق نشر قيد نقل واحد مرحلًا';
  else
    raise notice 'FAIL 18: التأكيد المطابق لم ينشر قيد النقل كما يجب (النتيجة: %)', v_ret;
  end if;

  v_ok := true;
  for v_line in
    select l.entry_side, l.amount_minor, l.cashbox_id, la.account_code
    from finance.journal_lines l
    join finance.ledger_accounts la on la.id = l.ledger_account_id
    where l.journal_entry_id = v_je_rem1
  loop
    if v_line.account_code <> '1000' then v_ok := false; end if;
    if v_line.entry_side = 'debit' and not (v_line.amount_minor = 1300 and v_line.cashbox_id = v_main1) then v_ok := false; end if;
    if v_line.entry_side = 'credit' and not (v_line.amount_minor = 1300 and v_line.cashbox_id = v_custody1) then v_ok := false; end if;
  end loop;

  if v_ok then
    raise notice 'PASS 19: قيد الترحيل = 1000 مدين للعام / 1000 دائن للحيازة (1300)';
  else
    raise notice 'FAIL 19: أطراف قيد الترحيل لا تطابق النقل النقدي الصحيح';
  end if;

  select count(*) into v_count
  from finance.journal_lines l
  join finance.ledger_accounts la on la.id = l.ledger_account_id
  where l.journal_entry_id = v_je_rem1
    and la.account_code <> '1000';

  if v_count = 0 then
    raise notice 'PASS 20: لا سطر إيراد أو ذمم أو مقدم أو مصروف في قيد الترحيل';
  else
    raise notice 'FAIL 20: ظهر % سطر بحساب غير النقدي في قيد الترحيل', v_count;
  end if;

  -- -------------------------------------------------------------
  -- 21-23. الحيازة نقصت، والعام زاز بالمقدار نفسه، والمجموع ثابت.
  -- -------------------------------------------------------------
  if finance.cashbox_balance_minor(v_custody1) = 0 then
    raise notice 'PASS 21: الحيازة نقصت بمبلغ الترحيل كاملًا';
  else
    raise notice 'FAIL 21: الحيازة بعد الترحيل = % وليست صفرًا', finance.cashbox_balance_minor(v_custody1);
  end if;

  if finance.cashbox_balance_minor(v_main1) = v_main_before + 1300 then
    raise notice 'PASS 22: صندوق البئر العام زاد بمبلغ الترحيل نفسه';
  else
    raise notice 'FAIL 22: صندوق البئر العام لم يزد بمبلغ الترحيل';
  end if;

  v_total_after := finance.cashbox_balance_minor(v_main1)
                 + finance.cashbox_balance_minor(v_custody1);

  if v_total_after = v_total_before then
    raise notice 'PASS 23: النقد الكلي للبئر لم يتغير بالترحيل (%)', v_total_after;
  else
    raise notice 'FAIL 23: النقد الكلي تغير بالترحيل: قبل % بعد %', v_total_before, v_total_after;
  end if;

  -- -------------------------------------------------------------
  -- 24. التأكيد الثاني لا يخلق قيدًا ثانيًا.
  -- -------------------------------------------------------------
  v_err := null;
  begin
    perform api.confirm_handover(v_rem1, 1300, null);
  exception when others then
    v_err := sqlerrm;
  end;

  if v_err is not null and (select count(*) from finance.journal_entries je
     where je.source_type = 'operator_cash_remittance' and je.source_id = v_rem1) = 1 then
    raise notice 'PASS 24: التأكيد الثاني رُفض وبقي قيد النقل واحدًا';
  else
    raise notice 'FAIL 24: التأكيد الثاني لم يُمنع كما يجب: %', coalesce(v_err, 'قُبل بلا سبب');
  end if;

  -- -------------------------------------------------------------
  -- 25. إقرارَي ترحيل مستقلان على الحيازة نفسها: كلاهما صالح فرديًا
  --     لحظة الإقرار (1000 تكفي 600 و700 كلٌّ على حدة).
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_op1::text, true);
  perform api.record_payment(v_well1, v_farmer_account, 1000, 'cash', '[]'::jsonb);
  v_rem2 := api.declare_operator_cash_remittance(v_shift1, 600, null);
  v_rem3 := api.declare_operator_cash_remittance(v_shift1, 700, null);

  if v_rem2 is not null and v_rem3 is not null and v_rem2 <> v_rem3 and exists (
    select 1 from ops.shift_handovers h
    where h.id = v_rem2 and h.status = 'declared'
      and h.declared_amount_minor = 600
      and h.from_cashbox_id = v_custody1 and h.to_cashbox_id = v_main1
  ) and exists (
    select 1 from ops.shift_handovers h
    where h.id = v_rem3 and h.status = 'declared'
      and h.declared_amount_minor = 700
      and h.from_cashbox_id = v_custody1 and h.to_cashbox_id = v_main1
  ) then
    raise notice 'PASS 25: إقرارا ترحيل مستقلان على الحيازة نفسها قُبلا فرديًا';
  else
    raise notice 'FAIL 25: إقرارا الترحيل المستقلان لم يُنشآ كما يجب';
  end if;

  -- -------------------------------------------------------------
  -- 26. تأكيد الأول المطابق: قيد واحد والحيازة تنقص إلى 400.
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  v_ret := api.confirm_handover(v_rem2, 600, null);

  if v_ret = 'confirmed' and exists (
    select 1 from finance.journal_entries je
    where je.source_type = 'operator_cash_remittance'
      and je.source_id = v_rem2 and je.status = 'posted'
  ) and finance.cashbox_balance_minor(v_custody1) = 400 then
    raise notice 'PASS 26: تأكيد أول الترحيلين نشر قيده وخفض الحيازة إلى 400';
  else
    raise notice 'FAIL 26: تأكيد أول الترحيلين لم يتصرف كما يجب (النتيجة: %)', v_ret;
  end if;

  -- -------------------------------------------------------------
  -- 27. تأكيد الثاني صار فوق الحيازة المتبقية: يُرفض بعد قفل
  --     صندوق المصدر، بلا أي قيد، ولا حيازة سالبة أبدًا.
  -- -------------------------------------------------------------
  v_err := null;
  begin
    perform api.confirm_handover(v_rem3, 700, null);
  exception when others then
    v_err := sqlerrm;
  end;

  if v_err like '%أقل من مبلغ الترحيل%'
     and not exists (
       select 1 from finance.journal_entries je
       where je.source_type = 'operator_cash_remittance' and je.source_id = v_rem3
     )
     and finance.cashbox_balance_minor(v_custody1) = 400 then
    raise notice 'PASS 27: التأكيد الثاني فوق المتبقي رُفض: بلا قيد ولا حيازة سالبة';
  else
    raise notice 'FAIL 27: سلوك التأكيد الثاني فوق المتبقي غير سليم: %', coalesce(v_err, 'قُبل!');
  end if;

  -- -------------------------------------------------------------
  -- 28. الترحيل بفرق: يعلق difference_pending بلا أي قيد.
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_op1::text, true);
  v_rem2 := api.declare_operator_cash_remittance(v_shift1, 400, null);

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  v_ret := api.confirm_handover(v_rem2, 300, 'عجز مبلغ موثق بانتظار الحسم');

  if v_ret = 'difference_pending' and exists (
    select 1 from ops.shift_handovers h
    where h.id = v_rem2 and h.status = 'difference_pending'
      and h.difference_minor = -100
  ) and not exists (
    select 1 from finance.journal_entries je
    where je.source_type = 'operator_cash_remittance' and je.source_id = v_rem2
  ) then
    raise notice 'PASS 28: الترحيل بفرق علق difference_pending بلا قيد نقلي';
  else
    raise notice 'FAIL 28: سلوك فرق الترحيل غير سليم (النتيجة: %)', v_ret;
  end if;

  -- -------------------------------------------------------------
  -- 29. حسم فرق الترحيل محجوب: لا محاسبة عجز مختلقة.
  -- -------------------------------------------------------------
  v_err := null;
  begin
    perform api.settle_handover(v_rem2);
  exception when others then
    v_err := sqlerrm;
  end;

  if v_err like '%عقد تسوية مالية مخصص%' then
    raise notice 'PASS 29: حسم فرق الترحيل محجوب برسالة العقد المالي المخصص';
  else
    raise notice 'FAIL 29: حسم فرق الترحيل لم يُحجب: %', coalesce(v_err, 'حُسم!');
  end if;

  -- -------------------------------------------------------------
  -- 30. التسليم الشخصي القائم: بقي شخصيًا وبلا قيد ولا مساس بالصناديق.
  -- -------------------------------------------------------------
  v_main_before := finance.cashbox_balance_minor(v_main1);

  perform set_config('request.jwt.claim.sub', v_op1::text, true);
  v_rem2 := api.declare_handover(v_shift1, 100, null, 'تسليم شخصي خارج النظام', null);

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  v_ret := api.confirm_handover(v_rem2, 100, null);

  if v_ret = 'confirmed' and exists (
    select 1 from ops.shift_handovers h
    where h.id = v_rem2 and h.handover_kind = 'person'
      and h.journal_entry_id is null
  ) and finance.cashbox_balance_minor(v_custody1) = 400
    and finance.cashbox_balance_minor(v_main1) = v_main_before then
    raise notice 'PASS 30: التسليم الشخصي بقي شخصيًا بلا قيد ولا مساس بالصناديق';
  else
    raise notice 'FAIL 30: التسليم الشخصي تغير سلوكه (النتيجة: %)', v_ret;
  end if;

  -- -------------------------------------------------------------
  -- 31-33. الحيازة المقروءة = رصيد الدفتر في العقود الثلاثة.
  -- -------------------------------------------------------------
  select finance.cashbox_balance_minor(v_custody1) into v_balance;

  if (ops.operator_totals(v_op1, v_well1) ->> 'unsettled_minor')::bigint = v_balance then
    raise notice 'PASS 31: unsettled_minor في operator_totals = رصيد الحيازة الدفتري';
  else
    raise notice 'FAIL 31: unsettled_minor لا يطابق رصيد الحيازة الدفتري';
  end if;

  if (ops.operator_totals(v_op1, v_well1) ->> 'custody_minor')::bigint = v_balance then
    raise notice 'PASS 32: custody_minor في operator_totals = الرصيد الدفتري نفسه';
  else
    raise notice 'FAIL 32: custody_minor غائب أو لا يطابق الرصيد الدفتري';
  end if;

  perform set_config('request.jwt.claim.sub', v_op1::text, true);

  if (api.get_my_operator_cash_custody(v_well1) ->> 'balance_minor')::bigint = v_balance then
    raise notice 'PASS 33: عقد قراءة الحيازة يعيد الرصيد الدفتري نفسه';
  else
    raise notice 'FAIL 33: عقد قراءة الحيازة أعاد رصيدًا غير الدفتري';
  end if;

  -- -------------------------------------------------------------
  -- 34. غير المصادَق محجوب عن العقدين الجديدين.
  -- -------------------------------------------------------------
  v_ok := true;
  execute 'set local role anon';
  begin
    perform api.get_my_operator_cash_custody(v_well1);
    v_ok := false;
  exception
    when insufficient_privilege then
      v_ok := true;
    when others then
      v_ok := sqlerrm like '%تسجيل الدخول%';
  end;
  begin
    perform api.declare_operator_cash_remittance(v_shift1, 1, null);
    v_ok := v_ok and false;
  exception
    when insufficient_privilege then
      v_ok := v_ok and true;
    when others then
      v_ok := v_ok and sqlerrm like '%تسجيل الدخول%';
  end;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', v_op1::text, true);

  if v_ok then
    raise notice 'PASS 34: غير المصادَق محجوب عن عقدَي الحيازة والترحيل';
  else
    raise notice 'FAIL 34: أحد العقدين الجديدين متاح لغير المصادَق';
  end if;

  -- -------------------------------------------------------------
  -- 35. حماية الإدخال المباشر كما هي: المصادَق لا ينشئ صناديق (ق-79).
  -- -------------------------------------------------------------
  v_ok := false;
  begin
    insert into finance.cashboxes (tenant_id, well_id, name, cashbox_type)
    values (v_tenant, v_well1, 'صندوق مخالف', 'main_well');
  exception when insufficient_privilege then
    v_ok := true;
  end;

  if v_ok then
    raise notice 'PASS 35: الإدخال المباشر في الصناديق محجوب عن المصادَق كما هو';
  else
    raise notice 'FAIL 35: المصادَق كتب مباشرة في finance.cashboxes — كسر Direct DML';
  end if;

  -- -------------------------------------------------------------
  -- 36. حرس بنيوي: تعريف confirm_handover الحي يقفل صف صناديق
  --     النقد FOR UPDATE — تسلسل التزامن لا يُحذف بالسهو.
  -- -------------------------------------------------------------
  if position('from finance.cashboxes' in pg_get_functiondef(
        to_regprocedure('ops.confirm_handover(uuid, bigint, uuid, text)')
      )) > 0
     and position('for update' in lower(pg_get_functiondef(
        to_regprocedure('ops.confirm_handover(uuid, bigint, uuid, text)')
      ))) > 0
  then
    raise notice 'PASS 36: تعريف confirm_handover الحي يقفل صف finance.cashboxes بقفل FOR UPDATE';
  else
    raise notice 'FAIL 36: قفل صف صندوق الحيازة في confirm_handover سقط من التعريف الحي';
  end if;

  -- -------------------------------------------------------------
  -- 1. (فحص ختامي شامل) صندوق حيازة نشط واحد لكل (بئر، مشغل).
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  select count(*) into v_count
  from (
    select well_id, assigned_profile_id
    from finance.cashboxes
    where cashbox_type = 'operator_custody' and status = 'active'
    group by well_id, assigned_profile_id
    having count(*) > 1
  ) x;

  if v_count = 0 then
    raise notice 'PASS 1: لا تكرار — صندوق حيازة نشط واحد لكل (بئر، مشغل)';
  else
    raise notice 'FAIL 1: وُجدت % مجموعة حيازة نشطة مكررة', v_count;
  end if;
end;
$test$;

rollback;
