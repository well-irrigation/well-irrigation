-- ق-131 البند 11 / م-45 المرحلة A: تحذير حالة المزارع عند اختياره.
-- هذا اختبار DB فقط؛ كل التغييرات تتراجع في النهاية.
--
-- ما يثبه هذا الملف:
--   1. العقد والقارئ الغرضي: وجودهما وتوقيعهما وإصدارَيهما وسلطة
--      api INVOKER والقارئ DEFINER بحقيقة مسمّاة واحدة.
--   2. مشغّل مصرَّح له (والمدير والمالك) يقرأ الحالة الكاملة لمزارع
--      بئره: الدين من عرض الأرصدة الحاكم، والمقدم عنه منفصلًا،
--      وديزل المزارع بالمللتر من الحركات المرحّلة.
--   3. القيم الثلاث متمايزة بلا مقاصلة: مال لا يمسّ كمية ولا العكس.
--   4. الصفر حقيقي لا غياب مُصطنع لمزارع بلا أي سجل.
--   5. حساب بئر غير مصرَّح به، ومعرّف فارغ، وحساب غير موجود: رفض صريح.
--   6. anon محجوب، وRLS الوقود والأرصدة بلا إضعاف ولا منح كتابة جديد.
--   7. إغلاق الفجوة الإرثية: منح EXECUTE الافتراضي عبر PUBLIC على
--      الدالة الأصلية inventory.farmer_fuel_balance_ml (046) سحبته
--      107 من public وanon وauthenticated مع بقاء service_role —
--      فحصًا فعليًا وسلوكًا، ومنحُا المصادَق المجاورة باقٍ بلا سحب
--      زائد، والمستدعيان الإنتاجيان داخل إجراء DEFINER فلا يتأثران.
--
-- والتجهيز كله بسلطة الإعداد قبل دخول دور المصادَق (نمط 106): المصادَق
-- يقرأ العقود ولا يكتب الجداول مباشرة (ق-79).

\set ON_ERROR_STOP on

begin;

set local timezone to 'UTC';

do $test$
declare
  v_owner uuid;
  v_manager uuid;
  v_operator uuid;
  v_stranger uuid;
  v_tenant uuid;
  v_other_tenant uuid;
  v_well uuid;
  v_other_well uuid;
  v_person uuid;
  v_zero_person uuid;
  v_other_person uuid;
  v_farmer_profile uuid;
  v_zero_farmer_profile uuid;
  v_other_farmer_profile uuid;
  v_account uuid;
  v_zero_account uuid;
  v_other_account uuid;
  v_status jsonb;
  v_count bigint;
  v_count_2 bigint;
  v_denied boolean;
begin
  -- -------------------------------------------------------------
  -- 1. التجهيز بسلطة الإعداد: بئر بمالك ومدير ومشغل، ومزارعان (أ عليه
  --    دين ومقدم وديزل، وثانٍ بلا أي سجل)، وبئر آخر بجهة أخرى.
  -- -------------------------------------------------------------
  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q131-status-owner@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_owner;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q131-status-manager@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_manager;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q131-status-operator@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_operator;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q131-status-stranger@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_stranger;

  insert into core.tenants (name)
  values ('جهة اختبار حالة المزارع 107')
  returning id into v_tenant;

  insert into core.tenants (name)
  values ('جهة أخرى لحالة المزارع 107')
  returning id into v_other_tenant;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'بئر حالة المزارع 107')
  returning id into v_well;

  insert into core.wells (tenant_id, name)
  values (v_other_tenant, 'بئر الجهة الأخرى 107')
  returning id into v_other_well;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values
    (v_well, v_owner, 'owner', 'active'),
    (v_well, v_manager, 'manager', 'active'),
    (v_well, v_operator, 'operator', 'active');

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_other_well, v_stranger, 'owner', 'active');

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع عليه دين 107', 'مزارع عليه دين 107')
  returning id into v_person;

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع بلا سجل 107', 'مزارع بلا سجل 107')
  returning id into v_zero_person;

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_other_tenant, 'مزارع الجهة الأخرى 107', 'مزارع الجهة الأخرى 107')
  returning id into v_other_person;

  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person)
  returning id into v_farmer_profile;

  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_zero_person)
  returning id into v_zero_farmer_profile;

  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_other_tenant, v_other_person)
  returning id into v_other_farmer_profile;

  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_farmer_profile, v_well, 'FWA-107-A')
  returning id into v_account;

  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_zero_farmer_profile, v_well, 'FWA-107-Z')
  returning id into v_zero_account;

  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_other_tenant, v_other_farmer_profile, v_other_well, 'FWA-107-OTHER')
  returning id into v_other_account;

  -- مصدر الدين الحاكم: فاتورة غير ملغاة 5000 بلا مخصص.
  insert into billing.invoices (
    tenant_id, public_code, well_id, farmer_well_account_id,
    invoice_date, status, subtotal_minor, total_minor,
    paid_minor, outstanding_minor
  ) values (
    v_tenant, 'INV-107', v_well, v_account,
    timestamptz '2026-09-20 08:00:00+03', 'issued',
    5000, 5000, 0, 5000
  );

  -- مصدر المقدم الحاكم: دفعة advance مرحّلة 2000 (لا تُقاص مع الدين).
  insert into billing.payments (
    tenant_id, well_id, farmer_well_account_id,
    purpose, amount_minor, method, paid_at, status
  ) values (
    v_tenant, v_well, v_account,
    'advance', 2000, 'cash', timestamptz '2026-09-21 09:00:00+03', 'posted'
  );

  -- مصدر الكمية الحاكم: حركات ديزل مزارع مرحّلة — شراء 12000 وصرف
  -- 4500 = رصيد 7500 مل. كمية لا مال (ق-131 البند 9).
  insert into inventory.fuel_transactions (
    tenant_id, well_id, transaction_type, ownership_type,
    owner_person_id, farmer_well_account_id, quantity_ml, direction,
    occurred_at, status, created_by
  ) values
    (v_tenant, v_well, 'purchase', 'farmer',
     v_person, v_account, 12000, 'in',
     timestamptz '2026-09-19 07:00:00+03', 'posted', v_owner),
    (v_tenant, v_well, 'session_consumption', 'farmer',
     v_person, v_account, 4500, 'out',
     timestamptz '2026-09-20 10:00:00+03', 'posted', v_owner);

  -- -------------------------------------------------------------
  -- 2. سطح العقد والقارئ: الوجود والنوع والسلطة والمنح.
  -- -------------------------------------------------------------
  if to_regprocedure('api.get_farmer_selection_status(uuid)') is not null
     and to_regprocedure('inventory.farmer_selection_fuel_ml(uuid)')
         is not null
     and exists (
      select 1 from pg_proc p
      where p.oid = to_regprocedure('api.get_farmer_selection_status(uuid)')
        and p.prorettype = 'jsonb'::regtype
        and p.prolang = (
          select oid from pg_language where lanname = 'plpgsql'
        )
        and not p.prosecdef
        and p.proconfig @> array['search_path=pg_catalog, pg_temp']
    )
     and exists (
      select 1 from pg_proc p
      where p.oid = to_regprocedure('inventory.farmer_selection_fuel_ml(uuid)')
        and p.prorettype = 'bigint'::regtype
        and p.prosecdef
        and position('has_well_permission' in pg_get_functiondef(p.oid)) > 0
        and position('has_well_role' in pg_get_functiondef(p.oid)) = 0
    )
     and has_function_privilege(
      'authenticated',
      to_regprocedure('api.get_farmer_selection_status(uuid)'),
      'EXECUTE'
    )
     and has_function_privilege(
      'service_role',
      to_regprocedure('api.get_farmer_selection_status(uuid)'),
      'EXECUTE'
    )
     and has_function_privilege(
      'authenticated',
      to_regprocedure('inventory.farmer_selection_fuel_ml(uuid)'),
      'EXECUTE'
    )
     and not has_function_privilege(
      'anon',
      to_regprocedure('api.get_farmer_selection_status(uuid)'),
      'EXECUTE'
    )
     and not has_function_privilege(
      'anon',
      to_regprocedure('inventory.farmer_selection_fuel_ml(uuid)'),
      'EXECUTE'
    )
     -- إغلاق الفجوة الإرثية (فحص فعّال يشمل ميراث PUBLIC): بعد سحب
     -- 107 لا للauthenticated ولا لanon تنفيذ الدالة الأصلية،
     -- وservice_role بقى بمنحه الصريح لقناة العمليات الخلفية.
     and not has_function_privilege(
      'authenticated',
      to_regprocedure('inventory.farmer_fuel_balance_ml(uuid, uuid)'),
      'EXECUTE'
    )
     and not has_function_privilege(
      'anon',
      to_regprocedure('inventory.farmer_fuel_balance_ml(uuid, uuid)'),
      'EXECUTE'
    )
     and has_function_privilege(
      'service_role',
      to_regprocedure('inventory.farmer_fuel_balance_ml(uuid, uuid)'),
      'EXECUTE'
    )
  then
    raise notice 'PASS 1: العقد INVOKER والقارئ DEFINER بحقيقة مسمّاة، والفجوة الإرثية عبر PUBLIC على الدالة الأصلية مغلقة وservice_role باقٍ';
  else
    raise notice 'FAIL 1: سطح العقد أو القارئ أو المنح أو إغلاق الفجوة غير مطابق';
  end if;

  -- -------------------------------------------------------------
  -- 3. المشغل يقرأ الحالة الكاملة: الثلاثة من الخادم ومتمايزة.
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_operator::text, true);
  execute 'set local role authenticated';

  v_status := api.get_farmer_selection_status(v_account);

  if v_status ->> 'contract' = 'get_farmer_selection_status'
     and (v_status ->> 'version')::int = 1
     and (v_status ->> 'farmer_well_account_id')::uuid = v_account
     and (v_status ->> 'well_id')::uuid = v_well
  then
    raise notice 'PASS 2: مغلَّف العقد يعيد اسمه وإصداره والحساب والبئر';
  else
    raise notice 'FAIL 2: مغلَّف غير متوقع: %', v_status;
  end if;

  if (v_status ->> 'debt_minor')::bigint = 5000
     and (v_status ->> 'advance_minor')::bigint = 2000
     and (v_status ->> 'farmer_fuel_balance_ml')::bigint = 7500
  then
    raise notice 'PASS 3: المشغل يقرأ دين 5000 ومقدم 2000 وديزل 7500 من مصادرها الحاكمة';
  else
    raise notice 'FAIL 3: حالة المزارع: %', v_status;
  end if;

  if (v_status ->> 'debt_minor')::bigint
       <> (v_status ->> 'advance_minor')::bigint
     and (v_status ->> 'advance_minor')::bigint
       <> (v_status ->> 'farmer_fuel_balance_ml')::bigint
  then
    raise notice 'PASS 4: القيم متمايزة بلا مقاصلة — المال مال والديزل كمية';
  else
    raise notice 'FAIL 4: تقارب القيم يوحي بمقاصلة: %', v_status;
  end if;

  -- -------------------------------------------------------------
  -- 4. المدير يقرأها أيضًا: session.start يفتح الحالة حتى لو أخفت
  --    سياسات الوقود صفوفه عن دور المدير — لا صفر كاذب (ق-113).
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_manager::text, true);
  execute 'set local role authenticated';

  v_status := api.get_farmer_selection_status(v_account);

  if (v_status ->> 'farmer_fuel_balance_ml')::bigint = 7500
     and (v_status ->> 'debt_minor')::bigint = 5000
  then
    raise notice 'PASS 5: المدير المصرَّح له يقرأ الحالة كاملة بلا صفر وقود كاذب';
  else
    raise notice 'FAIL 5: حالة المدير: %', v_status;
  end if;

  -- -------------------------------------------------------------
  -- 5. الصفر حقيقي: مزارع بلا أي فاتورة أو دفعة أو حركة.
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_operator::text, true);
  execute 'set local role authenticated';

  v_status := api.get_farmer_selection_status(v_zero_account);

  -- الصفر حقيقي: القيمة موجودة برقم لا null ولا مفتاح غائب —
  -- jsonb_typeof يحسم النوع و->>::bigint يحسم القيمة (نمط العقود).
  if jsonb_typeof(v_status -> 'debt_minor') = 'number'
     and jsonb_typeof(v_status -> 'advance_minor') = 'number'
     and jsonb_typeof(v_status -> 'farmer_fuel_balance_ml') = 'number'
     and (v_status ->> 'debt_minor')::bigint = 0
     and (v_status ->> 'advance_minor')::bigint = 0
     and (v_status ->> 'farmer_fuel_balance_ml')::bigint = 0
  then
    raise notice 'PASS 6: المزارع بلا سجل يعود بأصفار حقيقية لا null';
  else
    raise notice 'FAIL 6: حالة المزارع بلا سجل: %', v_status;
  end if;

  -- -------------------------------------------------------------
  -- 6. الرفض الصريح: بئر غير مصرَّح به، ومعرّف فارغ، وحساب غير موجود.
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_stranger::text, true);
  execute 'set local role authenticated';

  v_denied := false;
  begin
    perform api.get_farmer_selection_status(v_account);
  exception when insufficient_privilege then
    v_denied := true;
  end;

  if v_denied then
    raise notice 'PASS 7: مالك بئر آخر مرفوض على حساب بئر غيره';
  else
    raise notice 'FAIL 7: حساب بئر آخر قُرئ من غير مصرَّح له';
  end if;

  perform set_config('request.jwt.claim.sub', v_operator::text, true);
  execute 'set local role authenticated';

  v_denied := false;
  begin
    perform api.get_farmer_selection_status(null);
  exception when invalid_parameter_value then
    v_denied := true;
  end;

  if v_denied then
    raise notice 'PASS 8: المعرّف الفارغ مرفوض بـ22023';
  else
    raise notice 'FAIL 8: معرّف فارغ لم يُرفض';
  end if;

  v_denied := false;
  begin
    perform api.get_farmer_selection_status(gen_random_uuid());
  exception when insufficient_privilege then
    v_denied := true;
  end;

  if v_denied then
    raise notice 'PASS 9: الحساب غير الموجود رفض صريح بلا تسريب وجود';
  else
    raise notice 'FAIL 9: حساب غير موجود أعاد بيانات';
  end if;

  -- -------------------------------------------------------------
  -- 7. anon محجوب على العقد والقارئ.
  -- -------------------------------------------------------------
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role anon';

  v_denied := false;
  begin
    perform api.get_farmer_selection_status(v_account);
  exception when insufficient_privilege then
    v_denied := true;
  end;

  if v_denied then
    raise notice 'PASS 10: anon مرفوض على عقد حالة المزارع';
  else
    raise notice 'FAIL 10: anon قرأ حالة المزارع';
  end if;

  -- -------------------------------------------------------------
  -- 8. الحدود القائمة باقية: RLS الوقود يخفي بئر غيره، وعرض الأرصدة
  --    يركّب RLS فلا يفتح جهة أخرى، ولا منح كتابة جديد هنا.
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_operator::text, true);
  execute 'set local role authenticated';

  select count(*) into v_count
  from inventory.fuel_transactions
  where well_id = v_other_well;

  select count(*) into v_count_2
  from reporting.farmer_account_balances
  where well_id = v_other_well;

  if v_count = 0 and v_count_2 = 0
     and not has_table_privilege(
       'authenticated', 'inventory.fuel_transactions', 'DELETE'
     )
     and not has_table_privilege(
       'authenticated', 'reporting.farmer_account_balances', 'INSERT'
     )
  then
    raise notice 'PASS 11: RLS الوقود والأرصدة يركّب رؤية الجهة ولا منح كتابة جديد';
  else
    raise notice 'FAIL 11: تسرب رؤية أو منح: وقود=% أرصدة=%',
      v_count, v_count_2;
  end if;

  -- -------------------------------------------------------------
  -- 9. الإغلاق السلوكي للفجوة الإرثية والحدود المجاورة سليمة:
  --    المصادَق لا يستطيع استدعاء الدالة القديمة مباشرةً حتى لو مرّ
  --    بمنح PUBLIC إرثيًا (فحص فعّال لا ACL فقط)، ومنحُا المجاورة
  --    غير المنطوقة باقٍ بلا سحب زائد.
  -- -------------------------------------------------------------
  v_denied := false;
  begin
    perform inventory.farmer_fuel_balance_ml(v_well, v_person);
  exception when insufficient_privilege then
    v_denied := true;
  end;

  if v_denied then
    raise notice 'PASS 12: استدعاء الدالة القديمة مباشرةً بمصادَق مرفوض — لا أزواج بئر/شخص اعتباطية';
  else
    raise notice 'FAIL 12: مصادَق استدعى الدالة القديمة مباشرة — الفجوة لم تُغلق';
  end if;

  if has_function_privilege(
       'authenticated',
       to_regprocedure(
         'inventory.purchase_fuel(uuid, numeric, bigint, timestamptz, uuid)'
       ),
       'EXECUTE'
     )
     and has_function_privilege(
       'authenticated',
       to_regprocedure('iam.has_well_permission(uuid, text)'),
       'EXECUTE'
     )
  then
    raise notice 'PASS 13: منحُا المصادَق المجاورة (إجراءات الوقود وحاملات الهوية) باقية بلا سحب زائد';
  else
    raise notice 'FAIL 13: سحب الفجوة أصاب منحًا مجاورة مشروعة';
  end if;
end;
$test$;

rollback;
