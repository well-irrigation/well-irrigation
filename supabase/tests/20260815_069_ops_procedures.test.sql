begin;

set local timezone to 'UTC';

do $$
declare
  v_tenant uuid;
  v_well uuid;
  v_owner_user uuid;
  v_owner_profile uuid;
  v_farmer_user uuid;
  v_farmer_login_profile uuid;
  v_intruder_user uuid;
  v_intruder_profile uuid;
  v_person uuid;
  v_person_2 uuid;
  v_farmer_profile uuid;
  v_account uuid;
  v_account_2 uuid;
  v_farm_seed uuid;
  v_farm uuid;
  v_session_pump uuid;
  v_booking_pump uuid;
  v_water_line uuid;
  v_session uuid;
  v_booking uuid;
  v_tank uuid;
  v_estimated_transaction uuid;
  v_summary jsonb;
  v_summary_2 jsonb;
  v_before_count bigint;
begin
  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'owner069@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_owner_user;
  select id into v_owner_profile from iam.profiles where id = v_owner_user;
  if not found then
    insert into iam.profiles (id, full_name)
    values (v_owner_user, 'مالك اختبار 069') returning id into v_owner_profile;
  end if;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'farmer069@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_farmer_user;
  select id into v_farmer_login_profile from iam.profiles where id = v_farmer_user;
  if not found then
    insert into iam.profiles (id, full_name)
    values (v_farmer_user, 'مزارع متصل اختبار 069') returning id into v_farmer_login_profile;
  end if;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'intruder069@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_intruder_user;
  select id into v_intruder_profile from iam.profiles where id = v_intruder_user;
  if not found then
    insert into iam.profiles (id, full_name)
    values (v_intruder_user, 'مستخدم بلا صلاحية 069') returning id into v_intruder_profile;
  end if;

  insert into core.tenants (name)
  values ('جهة اختبار التشغيل 069') returning id into v_tenant;
  insert into core.wells (tenant_id, name)
  values (v_tenant, 'بئر اختبار التشغيل 069') returning id into v_well;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values
    (v_well, v_owner_profile, 'owner', 'active'),
    (v_well, v_farmer_login_profile, 'farmer', 'active');

  insert into core.pumps (well_id, name, power_source)
  values (v_well, 'مضخة جلسة مفتوحة 069', 'solar')
  returning id into v_session_pump;
  insert into core.pumps (well_id, name, power_source)
  values (v_well, 'مضخة حجوزات 069', 'diesel')
  returning id into v_booking_pump;

  insert into core.water_lines (
    tenant_id, well_id, public_code, name,
    allows_parallel_use, max_parallel_sessions
  ) values (
    v_tenant, v_well, 'WL-069', 'خط حجوزات 069', false, 1
  ) returning id into v_water_line;

  insert into core.pump_line_links (
    tenant_id, pump_id, water_line_id, effective_from, is_primary
  ) values (
    v_tenant, v_booking_pump, v_water_line,
    timestamptz '2026-01-01 00:00:00+00', true
  );

  select id into v_tank
  from inventory.fuel_tanks
  where well_id = v_well and status = 'active'
  order by created_at, id limit 1;

  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';

  -- 1) إنشاء المزارع الجديد ذريًا.
  v_summary := ops.create_farmer(
    v_well, 'أحمد علي', '777 111 222', 'أحمد', 'مزارع الاختبار', 5000
  );
  v_person := (v_summary ->> 'person_id')::uuid;
  v_farmer_profile := (v_summary ->> 'farmer_profile_id')::uuid;
  v_account := (v_summary ->> 'farmer_well_account_id')::uuid;
  if coalesce((v_summary ->> 'already_exists')::boolean, true) = false
     and exists (select 1 from core.persons where id = v_person and status = 'active')
     and exists (select 1 from ops.farmer_profiles where id = v_farmer_profile)
     and exists (select 1 from ops.farmer_well_accounts where id = v_account and well_id = v_well) then
    raise notice 'PASS 1: إنشاء المزارع أنشأ الشخص والملف وحساب البئر ذريًا';
  else
    raise notice 'FAIL 1: نتيجة إنشاء المزارع الجديد غير صحيحة: %', v_summary;
  end if;

  -- Fixture تمهيدي للجلسة المفتوحة.
  -- بعد ق-80 يجب أن تحمل الأرض Farmer Well Account الحقيقي.
  execute 'reset role';

  insert into ops.farms (
    well_id,
    name,
    farmer_well_account_id
  )
  values (
    v_well,
    'أرض تمهيدية للجلسة',
    v_account
  )
  returning id into v_farm_seed;

  execute 'set local role authenticated';

  -- التطابق الكامل يعيد الشخص نفسه ولا ينشئ مكررًا.
  select count(*) into v_before_count from core.persons where tenant_id = v_tenant;
  v_summary_2 := ops.create_farmer(v_well, 'أحمد علي', '00967-777111222');
  if (v_summary_2 ->> 'already_exists')::boolean
     and (v_summary_2 ->> 'person_id')::uuid = v_person
     and (select count(*) from core.persons where tenant_id = v_tenant) = v_before_count then
    raise notice 'PASS 2: التطابق الكامل أعاد المزارع الموجود دون دمج أو تكرار';
  else
    raise notice 'FAIL 2: قاعدة التطابق الكامل لم تعمل: %', v_summary_2;
  end if;

  -- التشابه الجزئي ينشئ عاديًا ويعيد المرشحين للتطبيق.
  v_summary_2 := ops.create_farmer(v_well, 'أحمد علي', '733444555');
  v_person_2 := (v_summary_2 ->> 'person_id')::uuid;
  v_account_2 := (v_summary_2 ->> 'farmer_well_account_id')::uuid;
  if not (v_summary_2 ->> 'already_exists')::boolean
     and v_person_2 <> v_person
     and jsonb_array_length(v_summary_2 -> 'duplicate_candidates') >= 1 then
    raise notice 'PASS 3: الاشتباه الجزئي أنشأ مزارعًا جديدًا وأعاد مرشحي التشابه';
  else
    raise notice 'FAIL 3: سلوك الاشتباه الجزئي غير صحيح: %', v_summary_2;
  end if;

  -- جلسة Fixture لإثبات أن إنشاء الأرض لا يتوقف أثناء التشغيل.
  -- ق-79 يمنع تطبيق العميل من إنشاء الجلسة مباشرة.
  execute 'reset role';

  insert into ops.irrigation_sessions (
    well_id, pump_id, farm_id, farmer_well_account_id,
    operator_profile_id, started_at, status
  ) values (
    v_well, v_session_pump, v_farm_seed, v_account,
    v_owner_profile, timestamptz '2026-09-01 05:00:00+00', 'open'
  ) returning id into v_session;

  execute 'set local role authenticated';

  v_summary := ops.create_farm(v_well, 'أرض أحمد الجديدة', v_account);
  v_farm := (v_summary ->> 'farm_id')::uuid;
  if exists (select 1 from ops.farms where id = v_farm and status = 'active')
     and exists (select 1 from ops.irrigation_sessions where id = v_session and status = 'open') then
    raise notice 'PASS 4: أُنشئت الأرض بنجاح أثناء بقاء جلسة سقي مفتوحة';
  else
    raise notice 'FAIL 4: إنشاء الأرض أثناء الجلسة المفتوحة لم ينجح';
  end if;

  -- الحجز السعيد يحجز المضخة والخط معًا.
  v_summary := ops.create_booking(
    v_well, v_account, v_farm,
    timestamptz '2026-09-02 06:00:00+00',
    timestamptz '2026-09-02 08:00:00+00',
    v_booking_pump, v_water_line, 'well_diesel', 1, 'حجز اختبار'
  );
  v_booking := (v_summary ->> 'booking_id')::uuid;
  if v_summary ->> 'status' = 'confirmed'
     and (select count(*) from ops.resource_reservations
          where booking_id = v_booking and status = 'active') = 2
     and exists (select 1 from ops.booking_status_history
                 where booking_id = v_booking and new_status = 'confirmed') then
    raise notice 'PASS 5: إنشاء الحجز أكد الموعد وحجز المضخة وخط المياه ذريًا';
  else
    raise notice 'FAIL 5: الحجز أو موارده أو تاريخ حالته غير مكتمل';
  end if;

  begin
    perform ops.create_booking(
      v_well, v_account, v_farm,
      timestamptz '2026-09-02 07:00:00+00',
      timestamptz '2026-09-02 09:00:00+00',
      v_booking_pump, v_water_line, 'well_diesel'
    );
    raise notice 'FAIL 6: سُمح بحجز متعارض على المورد نفسه';
  exception when others then
    if position('المورد محجوز بالكامل' in sqlerrm) > 0 then
      raise notice 'PASS 6: رُفض الحجز المتعارض على المورد المحجوز';
    else
      raise notice 'FAIL 6: سبب رفض تعارض الحجز غير متوقع: %', sqlerrm;
    end if;
  end;

  v_summary := ops.reschedule_booking(
    v_booking,
    timestamptz '2026-09-03 09:00:00+00',
    timestamptz '2026-09-03 11:30:00+00',
    'طلب المزارع تغيير الموعد'
  );
  if (select scheduled_start from ops.irrigation_bookings where id = v_booking)
       = timestamptz '2026-09-03 09:00:00+00'
     and (select count(*) from ops.resource_reservations
          where booking_id = v_booking and status = 'released') = 2
     and (select count(*) from ops.resource_reservations
          where booking_id = v_booking and status = 'active') = 2 then
    raise notice 'PASS 7: إعادة الجدولة حررت الموارد القديمة وحجزت الفترة الجديدة';
  else
    raise notice 'FAIL 7: إعادة الجدولة أو تبديل حجوزات الموارد غير صحيح';
  end if;

  begin
    perform ops.create_booking(
      v_well, v_account, v_farm,
      timestamptz '2026-09-04 10:00:00+00',
      timestamptz '2026-09-04 09:00:00+00',
      v_booking_pump, v_water_line
    );
    raise notice 'FAIL 8: سُمح بحجز نهايته قبل بدايته';
  exception when others then
    if position('فترة الحجز غير صالحة' in sqlerrm) > 0 then
      raise notice 'PASS 8: رُفضت فترة حجز غير صالحة';
    else
      raise notice 'FAIL 8: سبب رفض فترة الحجز غير متوقع: %', sqlerrm;
    end if;
  end;

  -- تغيير الحالة إلى completed هو إعداد إداري لاختبار الرفض اللاحق.
  execute 'reset role';

  update ops.irrigation_bookings
  set status = 'completed'
  where id = v_booking;

  execute 'set local role authenticated';

  begin
    perform ops.reschedule_booking(
      v_booking,
      timestamptz '2026-09-05 09:00:00+00',
      timestamptz '2026-09-05 10:00:00+00',
      'محاولة نقل حجز مكتمل'
    );
    raise notice 'FAIL 9: سُمح بإعادة جدولة حجز مكتمل';
  exception when others then
    if position('لا يمكن إعادة جدولة حجز حالته completed' in sqlerrm) > 0 then
      raise notice 'PASS 9: رُفضت إعادة جدولة الحجز المكتمل';
    else
      raise notice 'FAIL 9: سبب رفض نقل الحجز المكتمل غير متوقع: %', sqlerrm;
    end if;
  end;

  -- شراء 10 لترات بمبلغ 20000: الرصيد 10000 مل والمتوسط 2000.
  v_summary := inventory.purchase_fuel(
    v_well, 10.00, 20000,
    timestamptz '2026-09-01 12:00:00+00', v_owner_profile
  );
  if (v_summary ->> 'balance_ml')::bigint = 10000
     and (v_summary ->> 'avg_cost_per_liter_minor')::bigint = 2000
     and (v_summary ->> 'journal_entry_id')::uuid is not null then
    raise notice 'PASS 10: شراء الديزل حدّث الرصيد والمتوسط المرجح ورحّل القيد';
  else
    raise notice 'FAIL 10: ملخص شراء الديزل غير صحيح: %', v_summary;
  end if;

  begin
    perform inventory.purchase_fuel(v_well, 5.00, 0);
    raise notice 'FAIL 11: سُمح بشراء ديزل بمبلغ غير موجب';
  exception when others then
    if position('مبلغ شراء الديزل يجب أن يكون أكبر من صفر' in sqlerrm) > 0 then
      raise notice 'PASS 11: رُفض شراء الديزل ببيانات مالية ناقصة أو غير موجبة';
    else
      raise notice 'FAIL 11: سبب رفض مبلغ الشراء غير متوقع: %', sqlerrm;
    end if;
  end;

  v_summary := inventory.record_fuel_consumption(
    v_well, 1000, 'well', 'estimated',
    null, null, v_tank, null,
    timestamptz '2026-09-01 13:00:00+00', v_owner_profile
  );
  v_estimated_transaction := (v_summary ->> 'fuel_transaction_id')::uuid;
  if v_summary ->> 'status' = 'pending_actual_measurement'
     and (v_summary ->> 'balance_ml')::bigint = 10000
     and v_summary ->> 'journal_entry_id' is null then
    raise notice 'PASS 12: القياس التقديري بقي معلقًا بلا خصم أو قيد مالي';
  else
    raise notice 'FAIL 12: القياس التقديري أثّر في الرصيد أو لم يبق معلقًا: %', v_summary;
  end if;

  v_summary := inventory.record_fuel_consumption(
    v_well, 2000, 'well', 'actual',
    null, null, v_tank, null,
    timestamptz '2026-09-01 14:00:00+00', v_owner_profile,
    v_estimated_transaction
  );
  if (v_summary ->> 'balance_ml')::bigint = 8000
     and (v_summary ->> 'journal_entry_id')::uuid is not null
     and (select status from inventory.fuel_transactions
          where id = v_estimated_transaction) = 'reversed' then
    raise notice 'PASS 13: القياس الفعلي استبدل التقديري وخصم الوقود ورحّل تكلفته';
  else
    raise notice 'FAIL 13: تسجيل القياس الفعلي أو استبدال التقديري غير صحيح: %', v_summary;
  end if;

  begin
    perform inventory.record_fuel_consumption(
      v_well, 9000, 'well', 'actual', null, null, v_tank
    );
    raise notice 'FAIL 14: سُمح باستهلاك يتجاوز رصيد ديزل البئر';
  exception when others then
    if position('رصيد ديزل البئر لا يكفي' in sqlerrm) > 0 then
      raise notice 'PASS 14: رُفض استهلاك يتجاوز رصيد ديزل البئر';
    else
      raise notice 'FAIL 14: سبب رفض تجاوز رصيد البئر غير متوقع: %', sqlerrm;
    end if;
  end;

  -- إيداع ديزل المزارع هنا Fixture تمهيدي للاختبار.
  -- الاستهلاك نفسه أدناه يبقى عملية المستخدم عبر الإجراء المعتمد.
  execute 'reset role';

  insert into inventory.fuel_transactions (
    tenant_id, well_id, fuel_tank_id, transaction_type,
    ownership_type, owner_person_id, farmer_well_account_id,
    quantity_ml, direction, measurement_type, status, created_by
  ) values (
    v_tenant, v_well, v_tank, 'farmer_deposit',
    'farmer', v_person, v_account,
    3000, 'in', 'actual', 'posted', v_owner_profile
  );

  execute 'set local role authenticated';

  v_summary := inventory.record_fuel_consumption(
    v_well, 1000, 'farmer', 'actual',
    v_person, v_account, v_tank, null,
    timestamptz '2026-09-01 15:00:00+00', v_owner_profile
  );
  if (v_summary ->> 'balance_ml')::bigint = 2000
     and v_summary ->> 'journal_entry_id' is null then
    raise notice 'PASS 15: استهلاك ديزل المزارع خُصم من رصيده الخاص فقط';
  else
    raise notice 'FAIL 15: رصيد ديزل المزارع بعد الاستهلاك غير صحيح: %', v_summary;
  end if;

  begin
    perform inventory.record_fuel_consumption(
      v_well, 100, 'farmer', 'actual',
      v_person, v_account_2, v_tank
    );
    raise notice 'FAIL 16: سُمح باستخدام حساب مزارع آخر لسحب الوقود';
  exception when others then
    if position('لا يخص حساب المزارع المحدد' in sqlerrm) > 0 then
      raise notice 'PASS 16: رُفض استخدام رصيد مزارع عبر حساب مزارع آخر';
    else
      raise notice 'FAIL 16: سبب رفض خلط رصيد المزارعين غير متوقع: %', sqlerrm;
    end if;
  end;

  -- الرصيد المحاسبي 8000، والقياس 7000: عجز 1000 وقيمته 2000.
  v_summary := inventory.record_physical_fuel_count(
    v_well, v_tank, 7000,
    timestamptz '2026-09-01 18:00:00+00', v_owner_profile,
    'جرد نهاية اليوم'
  );
  if (v_summary ->> 'difference_ml')::bigint = -1000
     and (v_summary ->> 'balance_ml')::bigint = 7000
     and exists (
       select 1 from finance.journal_entries je
       where je.id = (v_summary ->> 'journal_entry_id')::uuid
         and je.status = 'posted' and je.source_type = 'fuel_physical_count'
         and exists (
           select 1 from finance.journal_lines jl
           where jl.journal_entry_id = je.id
             and jl.entry_side = 'debit' and jl.amount_minor = 2000
             and jl.ledger_account_id = finance.ledger_account_id(v_well, '5800')
         )
     ) then
    raise notice 'PASS 17: الجرد الفعلي سجل عجز 1000 مل وحدّث الرصيد ورحّل فرق المخزون';
  else
    raise notice 'FAIL 17: فرق الجرد أو قيده غير صحيح: %', v_summary;
  end if;

  begin
    perform inventory.record_physical_fuel_count(v_well, v_tank, -1);
    raise notice 'FAIL 18: سُمح برصيد جرد سالب';
  exception when others then
    if position('لا يجوز أن يكون سالبًا' in sqlerrm) > 0 then
      raise notice 'PASS 18: رُفض رصيد الجرد السالب';
    else
      raise notice 'FAIL 18: سبب رفض الجرد السالب غير متوقع: %', sqlerrm;
    end if;
  end;

  -- مستخدم موثق بلا تعيين لا يملك تنفيذ إجراءات البئر.
  perform set_config('request.jwt.claim.sub', v_intruder_user::text, true);
  begin
    perform ops.create_farmer(v_well, 'مزارع بلا صلاحية', '700000069');
    raise notice 'FAIL 19: سُمح لمستخدم بلا صلاحية بإنشاء مزارع';
  exception when others then
    if position('لا تملك صلاحية' in sqlerrm) > 0 then
      raise notice 'PASS 19: رُفض المستخدم الموثق الذي لا يملك صلاحية على البئر';
    else
      raise notice 'FAIL 19: سبب رفض المستخدم بلا صلاحية غير متوقع: %', sqlerrm;
    end if;
  end;
  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);

  begin
    perform ops.create_farmer(v_well, '   ', '711111111');
    raise notice 'FAIL 20: سُمح بإنشاء مزارع بلا اسم';
  exception when others then
    if position('اسم المزارع مطلوب' in sqlerrm) > 0 then
      raise notice 'PASS 20: رُفض إنشاء مزارع ببيانات ناقصة';
    else
      raise notice 'FAIL 20: سبب رفض اسم المزارع المفقود غير متوقع: %', sqlerrm;
    end if;
  end;

  begin
    perform ops.create_farm(v_well, '   ', v_account);
    raise notice 'FAIL 21: سُمح بإنشاء أرض بلا اسم';
  exception when others then
    if position('اسم الأرض مطلوب' in sqlerrm) > 0 then
      raise notice 'PASS 21: رُفض إنشاء أرض ببيانات ناقصة';
    else
      raise notice 'FAIL 21: سبب رفض اسم الأرض المفقود غير متوقع: %', sqlerrm;
    end if;
  end;

  if (select count(distinct action) from audit.audit_logs
      where well_id = v_well and action in (
        'create_farmer', 'create_farm', 'create_booking', 'reschedule_booking',
        'purchase_fuel', 'record_fuel_consumption', 'record_physical_fuel_count'
      )) = 7 then
    raise notice 'PASS 22: الإجراءات السبعة تركت آثار تدقيق مستقلة';
  else
    raise notice 'FAIL 22: سجل التدقيق لا يحتوي آثار الإجراءات السبعة كاملة';
  end if;

  execute 'reset role';
  raise notice '--- انتهى اختبار إجراءات التشغيل الذرية 069 (22 فحصًا) ---';
end $$;

rollback;
