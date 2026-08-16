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
  v_farm uuid;
  v_pump uuid;
  v_simple_pump uuid;
  v_busy_pump uuid;
  v_tank uuid;
  v_schedule uuid;
  v_solar_rule uuid;
  v_session uuid;
  v_simple_session uuid;
  v_busy_session uuid;
  v_invoice uuid;
  v_summary jsonb;
  v_count bigint;
  v_amount bigint;
  v_price bigint;
  v_tank_balance bigint;
begin
  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'session066@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_user;

  select id into v_profile from iam.profiles where id = v_user;
  if not found then
    insert into iam.profiles (id, full_name)
    values (v_user, 'مشغل اختبار 066')
    returning id into v_profile;
  end if;

  insert into core.tenants (name)
  values ('جهة اختبار إجراءات الجلسة 066')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'بئر اختبار إجراءات الجلسة 066')
  returning id into v_well;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_well, v_profile, 'owner', 'active');

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع اختبار الجلسة', 'مزارع اختبار الجلسة')
  returning id into v_person;

  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person)
  returning id into v_farmer_profile;

  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_farmer_profile, v_well, 'FWA-066')
  returning id into v_farmer_account;

  insert into ops.farms (
    well_id,
    name,
    farmer_well_account_id
  )
  values (
    v_well,
    'مزرعة اختبار 066',
    v_farmer_account
  )
  returning id into v_farm;

  insert into core.pumps (well_id, name, power_source)
  values (v_well, 'مضخة الدورة السعيدة', 'solar')
  returning id into v_pump;

  insert into core.pumps (well_id, name, power_source)
  values (v_well, 'مضخة الجلسة البسيطة', 'solar')
  returning id into v_simple_pump;

  insert into core.pumps (well_id, name, power_source)
  values (v_well, 'مضخة اختبار القفل', 'solar')
  returning id into v_busy_pump;

  select id into v_tank
  from inventory.fuel_tanks
  where well_id = v_well and status = 'active'
  order by created_at
  limit 1;

  insert into billing.well_pricing
    (well_id, price_per_hour_minor, period_start)
  values (v_well, 5000, date '2026-08-01');

  insert into ops.price_schedules
    (tenant_id, well_id, name, effective_period, status, approved_by)
  values (
    v_tenant, v_well, 'تسعير اختبار المقاطع',
    tstzrange(
      timestamptz '2026-08-01 00:00:00+00',
      timestamptz '2026-09-01 00:00:00+00',
      '[)'
    ),
    'active', v_profile
  )
  returning id into v_schedule;

  insert into ops.price_rules
    (tenant_id, price_schedule_id, energy_source, hourly_rate_minor)
  values (v_tenant, v_schedule, 'solar', 3600)
  returning id into v_solar_rule;

  insert into ops.price_rules (
    tenant_id, price_schedule_id, energy_source, diesel_pricing_model,
    operation_hourly_rate_minor, fuel_price_per_liter_minor
  ) values (
    v_tenant, v_schedule, 'well_diesel', 'operation_plus_fuel',
    7200, 1000
  );

  insert into ops.price_rules
    (tenant_id, price_schedule_id, energy_source, hourly_rate_minor)
  values (v_tenant, v_schedule, 'farmer_diesel', 6500);

  insert into inventory.fuel_transactions (
    tenant_id, well_id, fuel_tank_id, transaction_type, ownership_type,
    quantity_ml, direction, measurement_type,
    unit_cost_per_liter_minor, total_cost_minor, status, created_by
  ) values (
    v_tenant, v_well, v_tank, 'purchase', 'well',
    5000, 'in', 'actual', 1000, 5000, 'posted', v_profile
  );

  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  v_session := ops.start_irrigation_session(
    v_well, v_pump, v_farm, v_farmer_account, v_profile, 'solar',
    timestamptz '2026-08-10 08:00:00+00'
  );

  if exists (
    select 1
    from ops.irrigation_sessions s
    join ops.session_segments ss on ss.session_id = s.id
    where s.id = v_session
      and s.status = 'open'
      and s.price_per_hour_minor_snapshot = 5000
      and ss.sequence_number = 1
      and ss.segment_type = 'solar_run'
      and ss.energy_source = 'solar'
      and ss.applied_hourly_rate_minor = 3600
      and ss.ended_at is null
  ) then
    raise notice 'PASS 1: بدء الجلسة شغّل زنادات الأمان وفتح أول مقطع بسعر مثبت';
  else
    raise notice 'FAIL 1: لم تُنشأ الجلسة أو لقطة المقطع الأول كما هو متوقع';
  end if;

  -- ق-79: تغيير السعر هنا إعداد إداري للاختبار، وليس Direct DML من المستخدم.
  -- نرجع مؤقتًا إلى مالك القاعدة ثم نعيد دور المستخدم قبل متابعة السيناريو.
  execute 'reset role';

  update ops.price_rules
  set hourly_rate_minor = 9999
  where id = v_solar_rule;

  execute 'set local role authenticated';

  perform ops.pause_irrigation_session(
    v_session, 'operator_pause', timestamptz '2026-08-10 09:00:00+00'
  );

  perform ops.resume_irrigation_session(
    v_session, timestamptz '2026-08-10 09:15:00+00'
  );

  if (select count(*) from ops.session_segments where session_id = v_session) = 3
     and exists (
       select 1 from ops.session_segments
       where session_id = v_session and sequence_number = 2
         and segment_type = 'operator_pause' and not is_billable
         and started_at = timestamptz '2026-08-10 09:00:00+00'
         and ended_at = timestamptz '2026-08-10 09:15:00+00'
     ) then
    raise notice 'PASS 2: الإيقاف والاستئناف أنشآ مقطع توقف غير مفوتر ومقطع تشغيل جديدًا';
  else
    raise notice 'FAIL 2: تسلسل الإيقاف والاستئناف أو مقطع التوقف غير صحيح';
  end if;

  if (select count(*) from ops.session_segments
      where session_id = v_session and energy_source = 'solar'
        and applied_hourly_rate_minor = 3600) = 2
     and not exists (
       select 1 from ops.session_segments
       where session_id = v_session and energy_source = 'solar'
         and applied_hourly_rate_minor = 9999
     ) then
    raise notice 'PASS 3: تغيير السعر أثناء الجلسة لم يغيّر المقطع الجاري أو المقطع المستأنف';
  else
    raise notice 'FAIL 3: أُعيد تسعير مقطع شمسي بعد تغيير السعر';
  end if;

  perform ops.change_session_energy_source(
    v_session, 'well_diesel', timestamptz '2026-08-10 10:15:00+00'
  );

  if exists (
    select 1 from ops.session_segments
    where session_id = v_session and sequence_number = 4
      and segment_type = 'well_diesel_run'
      and energy_source = 'well_diesel'
      and applied_operation_rate_minor = 7200
      and applied_fuel_price_per_liter_minor = 1000
      and ended_at is null
  ) then
    raise notice 'PASS 4: تغيير المصدر فتح مقطع ديزل بلقطتي التشغيل والوقود الجديدتين';
  else
    raise notice 'FAIL 4: مقطع الديزل أو أسعارُه المثبتة غير صحيحة';
  end if;

  v_summary := ops.complete_irrigation_session(
    v_session, timestamptz '2026-08-10 11:15:00+00',
    1000, 'actual', v_tank
  );

  if exists (
    select 1
    from billing.session_charges sc
    where sc.session_id = v_session
      and sc.pricing_mode = 'segments'
      and sc.duration_seconds = 10800
      and sc.price_per_hour_minor = 4800
      and sc.amount_minor = 15400
  )
  and (v_summary ->> 'amount_minor')::bigint = 15400
  and (select sum(total_charge_minor) from ops.session_segments
       where session_id = v_session) = 15400
  and exists (
    select 1 from ops.session_segments
    where session_id = v_session and sequence_number = 1
      and billable_seconds = 3600 and time_charge_minor = 3600
      and fuel_charge_minor = 0 and total_charge_minor = 3600
  )
  and exists (
    select 1 from ops.session_segments
    where session_id = v_session and sequence_number = 2
      and actual_seconds = 900 and billable_seconds = 0
      and total_charge_minor = 0
  )
  and exists (
    select 1 from ops.session_segments
    where session_id = v_session and sequence_number = 3
      and billable_seconds = 3600 and time_charge_minor = 3600
      and total_charge_minor = 3600
  )
  and exists (
    select 1 from ops.session_segments
    where session_id = v_session and sequence_number = 4
      and billable_seconds = 3600 and time_charge_minor = 7200
      and fuel_charge_minor = 1000 and total_charge_minor = 8200
  ) then
    raise notice 'PASS 5: الإكمال حسب المقاطع أعطى 3600 + 3600 + 7200 + 1000 = 15400';
  else
    raise notice 'FAIL 5: مبالغ المقاطع أو ملخص الجلسة المختلطة غير صحيحة';
  end if;

  select current_balance_ml into v_tank_balance
  from inventory.fuel_tanks where id = v_tank;

  if v_tank_balance = 4000
     and exists (
       select 1
       from inventory.fuel_transactions ft
       join ops.session_segments ss on ss.id = ft.session_segment_id
       where ss.session_id = v_session
         and ss.sequence_number = 4
         and ft.transaction_type = 'session_consumption'
         and ft.ownership_type = 'well'
         and ft.direction = 'out'
         and ft.quantity_ml = 1000
         and ft.status = 'posted'
     )
     and exists (
       select 1 from finance.journal_entries je
       join inventory.fuel_transactions ft on ft.id = je.source_id
       where ft.session_segment_id in (
         select id from ops.session_segments where session_id = v_session
       )
         and je.source_type = 'fuel_consumption'
         and je.status = 'posted'
     )
     and exists (
       select 1 from audit.audit_logs al
       where al.action = 'session_completed' and al.entity_id = v_session
     ) then
    raise notice 'PASS 6: الإكمال خصم وقود البئر ورحّل قيده وسجل العملية في التدقيق';
  else
    raise notice 'FAIL 6: حركة الوقود أو قيدها أو سجل التدقيق غير مكتمل';
  end if;

  v_invoice := billing.issue_session_invoice(v_session, v_profile);

  if exists (
    select 1 from billing.invoices i
    where i.id = v_invoice and i.session_id = v_session
      and i.status = 'issued' and i.total_minor = 15400
      and i.outstanding_minor = 15400 and i.journal_entry_id is not null
  )
  and (select count(*) from billing.invoice_lines
       where invoice_id = v_invoice) = 4
  and (select sum(amount_minor) from billing.invoice_lines
       where invoice_id = v_invoice) = 15400
  and (select count(*) from billing.invoice_lines
       where invoice_id = v_invoice and line_type = 'solar_irrigation') = 2
  and (select count(*) from billing.invoice_lines
       where invoice_id = v_invoice and line_type = 'diesel_operation') = 1
  and (select count(*) from billing.invoice_lines
       where invoice_id = v_invoice and line_type = 'diesel_fuel') = 1 then
    raise notice 'PASS 7: أُصدرت فاتورة بأربعة بنود صحيحة من المقاطع ومجموع 15400';
  else
    raise notice 'FAIL 7: الفاتورة أو أنواع بنودها أو مجموعها غير صحيح';
  end if;

  if exists (
    select 1
    from billing.invoices i
    join finance.journal_entries je on je.id = i.journal_entry_id
    where i.id = v_invoice and je.status = 'posted'
      and exists (
        select 1 from finance.journal_lines jl
        join finance.ledger_accounts la on la.id = jl.ledger_account_id
        where jl.journal_entry_id = je.id and jl.entry_side = 'debit'
          and la.account_code = '1100' and jl.amount_minor = 15400
      )
      and exists (
        select 1 from finance.journal_lines jl
        join finance.ledger_accounts la on la.id = jl.ledger_account_id
        where jl.journal_entry_id = je.id and jl.entry_side = 'credit'
          and la.account_code = '4000' and jl.amount_minor = 7200
      )
      and exists (
        select 1 from finance.journal_lines jl
        join finance.ledger_accounts la on la.id = jl.ledger_account_id
        where jl.journal_entry_id = je.id and jl.entry_side = 'credit'
          and la.account_code = '4100' and jl.amount_minor = 7200
      )
      and exists (
        select 1 from finance.journal_lines jl
        join finance.ledger_accounts la on la.id = jl.ledger_account_id
        where jl.journal_entry_id = je.id and jl.entry_side = 'credit'
          and la.account_code = '4200' and jl.amount_minor = 1000
      )
  ) then
    raise notice 'PASS 8: زناد الفاتورة رحّل قيد 1100 مقابل 4000 و4100 و4200';
  else
    raise notice 'FAIL 8: القيد المرحل للفاتورة المختلطة غير صحيح';
  end if;

  begin
    perform ops.complete_irrigation_session(
      v_session, timestamptz '2026-08-10 12:00:00+00'
    );
    raise notice 'FAIL 9: سُمح بإكمال جلسة مغلقة';
  exception
    when others then
      if position('جلسة مغلقة' in sqlerrm) > 0 then
        raise notice 'PASS 9: رُفض إكمال جلسة مغلقة';
      else
        raise notice 'FAIL 9: سبب رفض إكمال المغلقة غير متوقع: %', sqlerrm;
      end if;
  end;

  begin
    perform ops.change_session_energy_source(
      v_session, 'solar', timestamptz '2026-08-10 12:00:00+00'
    );
    raise notice 'FAIL 10: سُمح بتغيير مصدر جلسة مغلقة';
  exception
    when others then
      if position('جلسة غير مفتوحة' in sqlerrm) > 0 then
        raise notice 'PASS 10: رُفض تغيير مصدر جلسة مغلقة';
      else
        raise notice 'FAIL 10: سبب رفض تغيير المصدر غير متوقع: %', sqlerrm;
      end if;
  end;

  begin
    perform billing.issue_session_invoice(v_session, v_profile);
    raise notice 'FAIL 11: سُمح بإصدار فاتورة ثانية للجلسة';
  exception
    when others then
      if position('فاتورة سارية مسبقًا' in sqlerrm) > 0 then
        raise notice 'PASS 11: رُفض إصدار فاتورة ثانية للجلسة';
      else
        raise notice 'FAIL 11: سبب رفض الفاتورة الثانية غير متوقع: %', sqlerrm;
      end if;
  end;

  -- الجلسة البسيطة هنا Fixture لاختبار شبكة الأمان القديمة.
  -- ليست مسار إنشاء مسموحًا لتطبيق العميل بعد ق-79.
  execute 'reset role';

  insert into ops.irrigation_sessions (
    well_id, pump_id, farm_id, farmer_well_account_id,
    operator_profile_id, started_at
  ) values (
    v_well, v_simple_pump, v_farm, v_farmer_account,
    v_profile, timestamptz '2026-08-10 12:00:00+00'
  )
  returning id into v_simple_session;

  execute 'set local role authenticated';

  begin
    perform ops.pause_irrigation_session(
      v_simple_session, 'operator_pause',
      timestamptz '2026-08-10 12:30:00+00'
    );
    raise notice 'FAIL 12: سُمح بإيقاف جلسة بلا مقطع مفتوح';
  exception
    when others then
      if position('لا يوجد مقطع تشغيل مفتوح' in sqlerrm) > 0 then
        raise notice 'PASS 12: رُفض إيقاف جلسة بلا مقطع مفتوح';
      else
        raise notice 'FAIL 12: سبب رفض الإيقاف غير متوقع: %', sqlerrm;
      end if;
  end;

  -- إغلاق الجلسة البسيطة مباشرة مطلوب فقط لاختبار الزناد القديم.
  -- تطبيق العميل لا يملك هذا المسار بعد ق-79.
  execute 'reset role';

  update ops.irrigation_sessions
  set ended_at = timestamptz '2026-08-10 13:00:00+00', status = 'closed'
  where id = v_simple_session;

  execute 'set local role authenticated';

  select amount_minor, price_per_hour_minor
  into v_amount, v_price
  from billing.session_charges
  where session_id = v_simple_session and pricing_mode = 'flat';

  if v_amount = 5000 and v_price = 5000
     and not exists (
       select 1 from ops.session_segments where session_id = v_simple_session
     ) then
    raise notice 'PASS 13: الجلسة البسيطة بلا مقاطع بقيت على زناد السعر الواحد بقيمة 5000';
  else
    raise notice 'FAIL 13: زناد الجلسة البسيطة لم يحسب السعر الواحد كما كان';
  end if;

  v_busy_session := ops.start_irrigation_session(
    v_well, v_busy_pump, v_farm, v_farmer_account, v_profile, 'solar',
    timestamptz '2026-08-10 14:00:00+00'
  );

  begin
    perform ops.start_irrigation_session(
      v_well, v_busy_pump, v_farm, v_farmer_account, v_profile, 'solar',
      timestamptz '2026-08-10 14:15:00+00'
    );
    raise notice 'FAIL 14: سُمح ببدء جلسة ثانية على المضخة المشغولة';
  exception
    when others then
      if position('المضخة مشغولة' in sqlerrm) > 0 then
        raise notice 'PASS 14: قفل المضخة رفض بدء جلسة ثانية عبر الإجراء الجديد';
      else
        raise notice 'FAIL 14: سبب رفض الجلسة الثانية غير متوقع: %', sqlerrm;
      end if;
  end;

  execute 'reset role';

  raise notice '--- انتهى اختبار إجراءات الجلسة 066 (14 فحصا) ---';
end $$;

rollback;
