-- اختبار 097 — قراءة سندات الرصيد المقدَّم (م-41G)
--
-- يثبّت أولًا **أن العقد لازم**: قراءة `billing.payments` مباشرة بدور المالك
-- تُعيد صفر سندات مقدَّم، لأن سياسة 016 تشترط ارتباط الدفعة بتكلفة جلسة.
-- ثم يثبّت الحمولة: معرّف كل سند ومبلغه والمخصَّص منه والمتبقّي والوسم،
-- والترتيب بالأقدم أولًا، وأن السلطة `payment.allocate` القائمة وحدها،
-- وأن من لا يملكها يُرفض صريحًا لا بقائمة فارغة.

\set ON_ERROR_STOP on

begin;

do $test$
declare
  v_api oid := to_regprocedure('api.list_advance_receipts(uuid, integer)');
  v_owner uuid;
  v_operator uuid;
  v_partner_user uuid;
  v_tenant uuid;
  v_well uuid;
  v_pump uuid;
  v_farmer_person uuid;
  v_partner_person uuid;
  v_farmer_profile uuid;
  v_account uuid;
  v_farm uuid;
  v_session uuid;
  v_charge uuid;
  v_invoice uuid;
  v_pay_partial uuid;
  v_pay_full uuid;
  v_pay_untouched uuid;
  v_started timestamptz := now() - interval '5 days';
  v_payload jsonb;
  v_item jsonb;
  v_count integer;
  v_count_2 integer;
  v_text text;
begin

  -- ---------------------------------------------------------------
  -- 1. خصائص الأمان
  -- ---------------------------------------------------------------

  select count(*) into v_count
  from pg_proc p
  where p.oid = v_api
    and p.prosecdef is false
    and p.proconfig @> array['search_path=pg_catalog, pg_temp'];

  -- ولا إجراء داخلي مصاحب: الجولة لا تتجاوز RLS في أي موضع.
  select count(*) into v_count_2
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'billing'
    and p.proname = 'read_advance_receipts';

  if v_api is not null and v_count = 1 and v_count_2 = 0
     and not has_function_privilege('anon', v_api, 'EXECUTE')
     and has_function_privilege('authenticated', v_api, 'EXECUTE')
  then
    raise notice 'PASS 1: عقد INVOKER بمسار مثبت، بلا تجاوز، وanon محجوب';
  else
    raise notice 'FAIL 1: خصائص العقد أو المنح غير مطابقة';
  end if;

  -- لا صلاحية جديدة: السلطة payment.allocate القائمة.
  select count(*) into v_count
  from iam.permissions p
  where p.code like '%advance%';

  if v_count = 0 then
    raise notice 'PASS 2: لا صلاحية جديدة للرصيد المقدَّم في الكتالوج';
  else
    raise notice 'FAIL 2: أُضيفت % صلاحية بلا حاجة', v_count;
  end if;

  -- ---------------------------------------------------------------
  -- 2. تجهيز: بئر ومزارع وثلاثة سندات مقدَّم بحالات مختلفة
  -- ---------------------------------------------------------------

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'adv-owner-097@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now(),
    jsonb_build_object('full_name', 'مالك 097', 'phone', '770000097')
  ) returning id into v_owner;

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'adv-operator-097@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now(),
    jsonb_build_object('full_name', 'مشغّل 097', 'phone', '771000097')
  ) returning id into v_operator;

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'adv-partner-097@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now(),
    jsonb_build_object('full_name', 'شريك 097', 'phone', '772000097')
  ) returning id into v_partner_user;

  insert into core.tenants (name)
  values ('جهة المقدَّم 097')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name, location)
  values (v_tenant, 'بئر 097', 'موقع 097')
  returning id into v_well;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values
    (v_well, v_owner, 'owner', 'active'),
    (v_well, v_operator, 'operator', 'active');

  insert into core.pumps (well_id, name, status, pump_type, power_rating)
  values (v_well, 'مضخة 097', 'active', 'submersible', '30 HP')
  returning id into v_pump;

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع 097', 'مزارع 097')
  returning id into v_farmer_person;

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'شريك 097', 'شريك 097')
  returning id into v_partner_person;

  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_farmer_person)
  returning id into v_farmer_profile;

  insert into ops.farmer_well_accounts (
    tenant_id, farmer_profile_id, well_id, public_code
  ) values (v_tenant, v_farmer_profile, v_well, 'FWA-097')
  returning id into v_account;

  -- شريك سارٍ بحصة 100 ليكون له اطلاع بلا payment.allocate.
  insert into core.well_partners (
    tenant_id, well_id, person_id, profile_id, phone, status, period_start
  ) values (
    v_tenant, v_well, v_partner_person, v_partner_user, '772000097',
    'active', current_date - 10
  );

  insert into ops.farms (well_id, name, farmer_well_account_id, status)
  values (v_well, 'أرض 097', v_account, 'active')
  returning id into v_farm;

  insert into ops.irrigation_sessions (
    well_id, pump_id, farm_id, farmer_well_account_id,
    operator_profile_id, started_at, ended_at, status
  ) values (
    v_well, v_pump, v_farm, v_account, v_operator,
    v_started, v_started + interval '2 hours', 'closed'
  ) returning id into v_session;

  insert into billing.session_charges (
    session_id, well_id, duration_seconds, price_per_hour_minor, amount_minor
  ) values (v_session, v_well, 7200, 100000, 200000)
  returning id into v_charge;

  insert into billing.invoices (
    tenant_id, public_code, well_id, farmer_well_account_id,
    session_id, invoice_date, status, subtotal_minor,
    total_minor, paid_minor, outstanding_minor
  ) values (
    v_tenant, 'INV-097', v_well, v_account, v_session, v_started,
    'partially_paid', 200000, 200000, 30000, 170000
  ) returning id into v_invoice;

  -- ثلاثة سندات مقدَّم: أقدمها مخصَّص جزئيًّا، ثم مستنفَد، ثم بلا تخصيص.
  insert into billing.payments (
    tenant_id, well_id, farmer_well_account_id, purpose,
    amount_minor, method, paid_at, status, collected_by_profile_id
  ) values (
    v_tenant, v_well, v_account, 'advance',
    100000, 'cash', v_started - interval '3 days', 'posted', v_operator
  ) returning id into v_pay_partial;

  insert into billing.payments (
    tenant_id, well_id, farmer_well_account_id, purpose,
    amount_minor, method, paid_at, status, collected_by_profile_id
  ) values (
    v_tenant, v_well, v_account, 'advance',
    20000, 'cash', v_started - interval '2 days', 'posted', v_operator
  ) returning id into v_pay_full;

  insert into billing.payments (
    tenant_id, well_id, farmer_well_account_id, purpose,
    amount_minor, method, paid_at, status, collected_by_profile_id
  ) values (
    v_tenant, v_well, v_account, 'advance',
    50000, 'cash', v_started - interval '1 day', 'posted', v_operator
  ) returning id into v_pay_untouched;

  insert into billing.payment_allocations (
    tenant_id, payment_id, invoice_id, allocated_minor
  ) values
    (v_tenant, v_pay_partial, v_invoice, 10000),
    (v_tenant, v_pay_full, v_invoice, 20000);

  -- ---------------------------------------------------------------
  -- 3. الأساس الذي يقوم عليه عقد INVOKER: صفوف المقدَّم **مقروءة** تحت RLS
  --    بعد هجرة 085 (حالة «دفعة بلا جلسة مربوطة بـwell_id»). الوثيقة كانت
  --    تقول إنها محجوبة، وأول تشغيل أسقط ذلك الفحص فصُحّح التصميم وحُذف
  --    التجاوز — لا العكس.
  -- ---------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';

  select count(*) into v_count
  from billing.payments p
  where p.farmer_well_account_id = v_account
    and p.purpose = 'advance';

  if v_count = 3 then
    raise notice 'PASS 3: سندات المقدَّم مقروءة تحت RLS، فلا حاجة إلى تجاوز';
  else
    raise notice 'FAIL 3: القراءة المباشرة أعادت % من 3', v_count;
  end if;

  -- ---------------------------------------------------------------
  -- 4. الحمولة: ترتيب بالأقدم، والمتبقّي = المبلغ ناقص المخصَّص
  -- ---------------------------------------------------------------

  v_payload := api.list_advance_receipts(v_account);
  v_item := v_payload -> 'receipts' -> 0;

  if v_payload ->> 'contract' = 'list_advance_receipts'
     and (v_payload ->> 'version')::int = 1
     and v_payload ->> 'farmer_well_account_id' = v_account::text
     and jsonb_array_length(v_payload -> 'receipts') = 3
     and v_item ->> 'payment_id' = v_pay_partial::text
  then
    raise notice 'PASS 4: الغلاف صحيح وثلاثة سندات مرتبة بالأقدم أولًا';
  else
    raise notice 'FAIL 4: غلاف أو ترتيب السندات غير مطابق: %', v_payload;
  end if;

  if (v_item ->> 'amount_minor')::bigint = 100000
     and (v_item ->> 'allocated_minor')::bigint = 10000
     and (v_item ->> 'remaining_minor')::bigint = 90000
     and (v_item ->> 'is_exhausted')::boolean is false
     and (v_item ->> 'public_code') is not null
  then
    raise notice 'PASS 5: المتبقّي = المبلغ ناقص المخصَّص، بلا حساب مخترع';
  else
    raise notice 'FAIL 5: أرقام السند الجزئي غير مطابقة: %', v_item;
  end if;

  v_item := v_payload -> 'receipts' -> 1;

  if (v_item ->> 'payment_id') = v_pay_full::text
     and (v_item ->> 'remaining_minor')::bigint = 0
     and (v_item ->> 'is_exhausted')::boolean is true
  then
    raise notice 'PASS 6: السند المستنفَد موسوم ومتبقّيه صفر ولا يُحذف';
  else
    raise notice 'FAIL 6: السند المستنفَد غير مطابق: %', v_item;
  end if;

  v_item := v_payload -> 'receipts' -> 2;

  if (v_item ->> 'payment_id') = v_pay_untouched::text
     and (v_item ->> 'allocated_minor')::bigint = 0
     and (v_item ->> 'remaining_minor')::bigint = 50000
  then
    raise notice 'PASS 7: سند بلا تخصيص متبقّيه مبلغه كاملًا';
  else
    raise notice 'FAIL 7: السند غير المخصَّص غير مطابق: %', v_item;
  end if;

  -- ---------------------------------------------------------------
  -- 5. السلطة: المشغّل يقرأ (يخصّص فيرى)، والشريك يُرفض صريحًا
  -- ---------------------------------------------------------------

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_operator::text, true);
  execute 'set local role authenticated';

  v_payload := api.list_advance_receipts(v_account);

  if jsonb_array_length(v_payload -> 'receipts') = 3 then
    v_count := 1;
  else
    v_count := 0;
    raise notice 'INFO: حمولة المشغّل: %', v_payload;
  end if;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_partner_user::text, true);
  execute 'set local role authenticated';

  begin
    perform api.list_advance_receipts(v_account);
    v_text := 'no-error';
  exception
    when others then
      v_text := sqlstate;
  end;

  execute 'reset role';

  if v_count = 1 and v_text = '42501' then
    raise notice 'PASS 8: المشغّل يقرأ بسلطة payment.allocate والشريك يُرفض';
  else
    raise notice 'FAIL 8: المشغّل=% والشريك أعاد %', v_count, v_text;
  end if;

  -- ---------------------------------------------------------------
  -- 6. حساب غير موجود = نفس الرفض (لا إفشاء)، وanon محجوب بالمنح
  -- ---------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';

  begin
    perform api.list_advance_receipts(gen_random_uuid());
    v_text := 'no-error';
  exception
    when others then
      v_text := sqlstate;
  end;

  if v_text = '42501' then
    v_count := 1;
  else
    v_count := 0;
    raise notice 'INFO: حساب غير موجود أعاد %', v_text;
  end if;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role anon';

  begin
    perform api.list_advance_receipts(v_account);
    v_text := 'no-error';
  exception
    when others then
      v_text := sqlstate;
  end;

  execute 'reset role';

  if v_count = 1 and v_text = '42501' then
    raise notice 'PASS 9: حساب مجهول وanon يُردّان بنفس الرفض الصريح';
  else
    raise notice 'FAIL 9: مجهول=% وanon أعاد %', v_count, v_text;
  end if;

  -- ---------------------------------------------------------------
  -- 7. عقد الكتابة القائم لم يُلمس: التخصيص يبقى api.allocate_payment
  -- ---------------------------------------------------------------

  if to_regprocedure('api.allocate_payment(uuid, jsonb)') is not null
     and not exists (
       select 1
       from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'api'
         and p.proname like '%advance%'
         and p.provolatile = 'v'
     )
  then
    raise notice 'PASS 10: لا عقد كتابة جديد — التخصيص على العقد القائم';
  else
    raise notice 'FAIL 10: أُضيف عقد كتابة للمقدَّم أو فُقد عقد التخصيص';
  end if;
end;
$test$;

rollback;
