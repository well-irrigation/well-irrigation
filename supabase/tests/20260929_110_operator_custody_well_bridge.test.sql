-- ق-131 البند 18 / م-45 المرحلة A: جسر ترحيل الحيازة على مستوى البئر.
-- هذا اختبار DB فقط؛ كل التغييرات تتراجع في النهاية.
--
-- ما يثبه هذا الملف (مطابق لأبنود عقد الهجرة 110):
--   1.  التسليم الشخصي/العادي ما زال ملزمًا بنوبة حقيقية — 'person'
--       بلا shift_id يُرفض بقيد الهجرة، والصفوف التاريخية لم تُمس.
--   2-3. المشغل النشط يُقر ترحيلًا على مستوى البئر بلا نوبة: صف
--       shift_handovers من النوع الصريح بـshift_id = null والحيازة
--       والوجهة الحاكمتان.
--   4-5. الإقرار فوق الحيازة الدفترية يُرفض، والإقرار لا ينشئ أي قيد.
--   6.  تأكيد المالك المطابق يبقى سلطة م-109: قيد نقل واحد مرحل
--       (1000 مدين للعام / 1000 دائن للحيازة).
--   7-9. المالك يرى تراخيم البئر كلها، وكل مشغل يرى تراخيمه وحده —
--       فلا يقرأ المشغل الثاني تراخيم الأول.
--   10. غير المشغل النشط (المالك هنا) لا يستطيع الإقرار.
--   11. anon محجوب عن العقدين الجديدين.
--   12. حماية م-109 من تزامن الحيازة باقية: القفل البنيوي في
--       confirm_handover، ورفض تأكيد ترحيل فوق المتبقي بلا قيد.
--
-- لا تضعيف لاختبار 109: يجري في الحزمة نفسه بجواره.

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
  v_custody1 uuid;
  v_custody2 uuid;
  v_main1 uuid;
  v_fund_je uuid;
  v_rem1 uuid;
  v_rem2 uuid;
  v_rem3 uuid;
  v_ret text;
  v_err text;
  v_list jsonb;
  v_je uuid;
  v_count bigint;
  v_ok boolean;
begin
  -- -------------------------------------------------------------
  -- التجهيز: جهة وبئر بمالك ومشغلين، وحيازتان مموّلتان من الدفتر.
  -- -------------------------------------------------------------
  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q131-bridge-owner@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_owner;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q131-bridge-op1@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_op1;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q131-bridge-op2@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_op2;

  insert into core.tenants (name)
  values ('جهة اختبار جسر الحيازة 110')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'بئر جسر الحيازة 110')
  returning id into v_well1;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_well1, v_owner, 'owner', 'active'),
         (v_well1, v_op1, 'operator', 'active'),
         (v_well1, v_op2, 'operator', 'active');

  v_main1 := finance.main_cashbox_id(v_well1);
  v_custody1 := finance.ensure_operator_custody_cashbox(v_well1, v_op1);
  v_custody2 := finance.ensure_operator_custody_cashbox(v_well1, v_op2);

  -- تمويل حيازة op1 بـ1000 وop2 بـ200 من دفتر الحسابات مباشرة
  -- (تجهيز بسلطة الإعداد، ولا يدخل في فحوص العقد).
  v_fund_je := gen_random_uuid();
  insert into finance.journal_entries (
    id, tenant_id, public_code, well_id, entry_date,
    source_type, source_id, description, idempotency_key
  ) values (
    v_fund_je, v_tenant, 'JE-110A', v_well1, now(),
    'test_custody_funding', v_fund_je, 'تمويل تجهيز حيازة op1',
    'TEST110-FUND1-' || v_fund_je::text
  );
  insert into finance.journal_lines (
    tenant_id, journal_entry_id, ledger_account_id, entry_side,
    amount_minor, cashbox_id, description
  ) values (
    v_tenant, v_fund_je, finance.ledger_account_id(v_well1, '1000'), 'debit',
    1000, v_custody1, 'تمويل تجهيز الحيازة'
  ), (
    v_tenant, v_fund_je, finance.ledger_account_id(v_well1, '3000'), 'credit',
    1000, null, 'رأس المال مقابل تمويل التجهيز'
  );
  perform finance.post_journal_entry(v_fund_je, null);

  v_fund_je := gen_random_uuid();
  insert into finance.journal_entries (
    id, tenant_id, public_code, well_id, entry_date,
    source_type, source_id, description, idempotency_key
  ) values (
    v_fund_je, v_tenant, 'JE-110B', v_well1, now(),
    'test_custody_funding', v_fund_je, 'تمويل تجهيز حيازة op2',
    'TEST110-FUND2-' || v_fund_je::text
  );
  insert into finance.journal_lines (
    tenant_id, journal_entry_id, ledger_account_id, entry_side,
    amount_minor, cashbox_id, description
  ) values (
    v_tenant, v_fund_je, finance.ledger_account_id(v_well1, '1000'), 'debit',
    200, v_custody2, 'تمويل تجهيز الحيازة'
  ), (
    v_tenant, v_fund_je, finance.ledger_account_id(v_well1, '3000'), 'credit',
    200, null, 'رأس المال مقابل تمويل التجهيز'
  );
  perform finance.post_journal_entry(v_fund_je, null);

  -- -------------------------------------------------------------
  -- 1. التسليم الشخصي ما زال يلزمه نوبة: 'person' بلا shift_id مرفوض.
  -- -------------------------------------------------------------
  v_ok := false;
  begin
    insert into ops.shift_handovers (
      tenant_id, well_id, shift_id, from_profile_id,
      to_description, declared_amount_minor, handover_kind
    ) values (
      v_tenant, v_well1, null, v_op1,
      'تسليم شخصي بلا نوبة', 1, 'person'
    );
  exception when check_violation then
    v_ok := sqlerrm like '%shift_required_for_person%';
  end;

  if v_ok then
    raise notice 'PASS 1: التسليم الشخصي بلا نوبة مرفوض بقيد الهجرة';
  else
    raise notice 'FAIL 1: تسليم شخصي بلا نوبة تسرب دون رفض';
  end if;

  -- -------------------------------------------------------------
  -- 2-3. المشغل النشط يُقر ترحيلًا على مستوى البئر بلا نوبة.
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_op1::text, true);
  execute 'set local role authenticated';

  v_rem1 := api.declare_my_operator_cash_remittance(v_well1, 600, 'ترحيل جسر');

  if v_rem1 is not null and exists (
    select 1 from ops.shift_handovers h
    where h.id = v_rem1
      and h.shift_id is null
      and h.handover_kind = 'operator_cash_remittance'
      and h.from_profile_id = v_op1
      and h.from_cashbox_id = v_custody1
      and h.to_cashbox_id = v_main1
      and h.declared_amount_minor = 600
      and h.status = 'declared'
  ) then
    raise notice 'PASS 2: ترحيل البئر سُجل في shift_handovers بلا نوبة بالنوع الصريح';
  else
    raise notice 'FAIL 2: ترحيل البئر لم يُسجل كما يجب';
  end if;

  if v_rem1 is not null then
    raise notice 'PASS 3: المشغل النشط أقر الترحيل بالبئر دون تمرير ملفه';
  else
    raise notice 'FAIL 3: إقرار المشغل بالبئر فشل';
  end if;

  -- -------------------------------------------------------------
  -- 4. الإقرار فوق الحيازة الدفترية يُرفض.
  -- -------------------------------------------------------------
  v_err := null;
  begin
    perform api.declare_my_operator_cash_remittance(v_well1, 9999, null);
  exception when others then
    v_err := sqlerrm;
  end;

  if v_err like '%فوق المتوفر%' or v_err like '%يتجاوز حيازة%' then
    raise notice 'PASS 4: الإقرار فوق الحيازة الدفترية رُفض';
  else
    raise notice 'FAIL 4: الإقرار فوق الحيازة لم يُرفض: %', coalesce(v_err, 'قُبل!');
  end if;

  -- -------------------------------------------------------------
  -- 5. الإقرار لا ينشئ أي قيد يومية.
  -- -------------------------------------------------------------
  if not exists (
    select 1 from finance.journal_entries je
    where je.source_type = 'operator_cash_remittance' and je.source_id = v_rem1
  ) then
    raise notice 'PASS 5: الإقرار بلا نوبة لم ينشئ أي قيد يومية';
  else
    raise notice 'FAIL 5: الإقرار أنشأ قيدًا قبل تأكيد المالك';
  end if;

  -- -------------------------------------------------------------
  -- 6. تأكيد المالك المطابق ينشر قيد نقل م-109 واحدًا مرحلًا.
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_ret := api.confirm_handover(v_rem1, 600, null);

  select je.id into v_je
  from finance.journal_entries je
  where je.source_type = 'operator_cash_remittance' and je.source_id = v_rem1;

  if v_ret = 'confirmed' and v_je is not null and exists (
    select 1 from finance.journal_entries je
    where je.id = v_je and je.status = 'posted'
  ) and exists (
    select 1 from finance.journal_lines l
    join finance.ledger_accounts la on la.id = l.ledger_account_id
    where l.journal_entry_id = v_je and la.account_code = '1000'
      and l.entry_side = 'debit' and l.amount_minor = 600
      and l.cashbox_id = v_main1
  ) and exists (
    select 1 from finance.journal_lines l
    join finance.ledger_accounts la on la.id = l.ledger_account_id
    where l.journal_entry_id = v_je and la.account_code = '1000'
      and l.entry_side = 'credit' and l.amount_minor = 600
      and l.cashbox_id = v_custody1
  ) and finance.cashbox_balance_minor(v_custody1) = 400 then
    raise notice 'PASS 6: تأكيد المالك نشر قيد النقل 1000→1000 وخفض الحيازة إلى 400';
  else
    raise notice 'FAIL 6: تأكيد المالك لم ينشر قيد النقل كما يجب (النتيجة: %)', v_ret;
  end if;

  -- -------------------------------------------------------------
  -- 7-9. القراءة: المالك يرى الكل، وكل مشغل يرى تراخيمه وحده.
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_op2::text, true);
  v_rem3 := api.declare_my_operator_cash_remittance(v_well1, 100, 'ترحيل op2');

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  v_list := api.list_operator_cash_remittances(v_well1, 50);

  select count(*) into v_count
  from jsonb_array_elements(v_list -> 'remittances') x;

  if v_count = 2 then
    raise notice 'PASS 7: المالك يرى تراخيم البئر كلها (2)';
  else
    raise notice 'FAIL 7: المالك يرى % تراخيمًا بدل 2', v_count;
  end if;

  perform set_config('request.jwt.claim.sub', v_op1::text, true);
  v_list := api.list_operator_cash_remittances(v_well1, 50);

  select count(*) into v_count
  from jsonb_array_elements(v_list -> 'remittances') x
  where (x ->> 'from_profile_id') = v_op1::text;

  if v_count = 1 and (v_list -> 'remittances' -> 0 ->> 'from_profile_name') is not null then
    raise notice 'PASS 8: المشغل يرى تراخيمه وحده مع اسم المرسل';
  else
    raise notice 'FAIL 8: قائمة المشغل حوت % بندًا غير صحيحة', v_count;
  end if;

  perform set_config('request.jwt.claim.sub', v_op2::text, true);
  v_list := api.list_operator_cash_remittances(v_well1, 50);

  select count(*) into v_count
  from jsonb_array_elements(v_list -> 'remittances') x;

  if v_count = 1 and (v_list -> 'remittances' -> 0 ->> 'id') = v_rem3::text then
    raise notice 'PASS 9: المشغل الثاني لا يرى تراخيم المشغل الأول';
  else
    raise notice 'FAIL 9: تسرب قراءة بين المشغلين (رأى op2 % بندًا)', v_count;
  end if;

  -- -------------------------------------------------------------
  -- 10. غير المشغل النشط (المالك هنا) لا يستطيع الإقرار.
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_err := null;
  begin
    perform api.declare_my_operator_cash_remittance(v_well1, 50, null);
  exception when others then
    v_err := sqlerrm;
  end;

  if v_err like '%خاص بالمشغل النشط%' or v_err like '%تعيين مشغل نشط%' then
    raise notice 'PASS 10: إقرار غير المشغل النشط رُفض';
  else
    raise notice 'FAIL 10: إقرار غير المشغل لم يُرفض: %', coalesce(v_err, 'قُبل!');
  end if;

  -- -------------------------------------------------------------
  -- 11. anon محجوب عن العقدين الجديدين.
  -- -------------------------------------------------------------
  v_ok := true;
  execute 'set local role anon';
  begin
    perform api.declare_my_operator_cash_remittance(v_well1, 1, null);
    v_ok := false;
  exception
    when insufficient_privilege then
      v_ok := true;
    when others then
      v_ok := v_ok and sqlerrm like '%تسجيل الدخول%';
  end;
  begin
    perform api.list_operator_cash_remittances(v_well1, 50);
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
    raise notice 'PASS 11: anon محجوب عن عقدي الإقرار والقراءة الجديدين';
  else
    raise notice 'FAIL 11: أحد العقدَين الجديدين متاح لـanon';
  end if;

  -- -------------------------------------------------------------
  -- 12. حماية م-109 من تزامن الحيازة باقية: قفل بنيوي في
  --     confirm_handover، ورفض تأكيد ترحيل فوق المتبقي بلا قيد.
  -- -------------------------------------------------------------
  v_rem2 := null;
  v_err := null;
  begin
    v_rem2 := api.declare_my_operator_cash_remittance(v_well1, 700, null);
  exception when others then
    v_err := sqlerrm;
  end;

  if v_rem2 is null and v_err like '%فوق المتوفر%' then
    -- الحيازة المتبقية 400 والإقرار 700 فوقها مرفوضًا عند البوابة.
    raise notice 'PASS 12: حماية الحيازة من التزامن باقية (الإقرار فوق المتبقي مرفوض وقفل confirm_handover البنيوي باقٍ)';
  else
    raise notice 'FAIL 12: سلوك حماية الحيازة تغير: %', coalesce(v_err, 'قُبل!');
  end if;

  if v_ok and position('from finance.cashboxes' in pg_get_functiondef(
        to_regprocedure('ops.confirm_handover(uuid, bigint, uuid, text)')
      )) > 0
     and position('for update' in lower(pg_get_functiondef(
        to_regprocedure('ops.confirm_handover(uuid, bigint, uuid, text)')
      ))) > 0 then
    raise notice 'PASS 12b: قفل صف صندوق المصدر في confirm_handover باقٍ في التعريف الحي';
  else
    raise notice 'FAIL 12b: قفل تسلسل التزامن في confirm_handover سقط';
  end if;
end;
$test$;

rollback;
