begin;

set local timezone to 'UTC';

-- ق-75: اختبارات device_id وoutbox وقواعد PowerSync مؤجلة إلى مرحلة التطبيق.
-- م-21: تعارض تعديل من جهازين اختبار ميداني مؤجل؛ هنا يُختبر عقد منع تكرار أوامر الخادم فقط.

do $$
declare
  v_tenant uuid; v_foreign_tenant uuid; v_well uuid; v_foreign_well uuid;
  v_user uuid; v_profile uuid; v_foreign_user uuid; v_foreign_profile uuid;
  v_person_a uuid; v_person_b uuid; v_fp uuid; v_fwa uuid; v_tank uuid;
  v_farm uuid; v_pump uuid; v_session uuid; v_command uuid := gen_random_uuid();
  v_first jsonb; v_second jsonb; v_count bigint; v_balance bigint; v_avg bigint;
begin
  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'inventory067@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_user;
  select id into v_profile from iam.profiles where id = v_user;
  if not found then
    insert into iam.profiles (id, full_name) values (v_user, 'مالك مخزون 067') returning id into v_profile;
  end if;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'foreign067@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_foreign_user;
  select id into v_foreign_profile from iam.profiles where id = v_foreign_user;
  if not found then
    insert into iam.profiles (id, full_name) values (v_foreign_user, 'مالك أجنبي 067') returning id into v_foreign_profile;
  end if;

  insert into core.tenants (name) values ('جهة مخزون ومزامنة 067') returning id into v_tenant;
  insert into core.wells (tenant_id, name) values (v_tenant, 'بئر مخزون ومزامنة 067') returning id into v_well;
  insert into core.well_assignments (well_id, profile_id, role, status) values (v_well, v_profile, 'owner', 'active');
  select id into v_tank from inventory.fuel_tanks where well_id = v_well and status = 'active' order by created_at limit 1;

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع بلا هاتف', 'مزارع بلا هاتف') returning id into v_person_a;
  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع بلا هاتف', 'مزارع بلا هاتف') returning id into v_person_b;
  if (select count(*) from core.persons
      where tenant_id = v_tenant and normalized_name = 'مزارع بلا هاتف' and status = 'active') = 2
     and not exists (select 1 from core.person_contacts where person_id in (v_person_a, v_person_b)) then
    raise notice 'PASS 1: قُبل مزارع بلا هاتف ومزارعان بالاسم نفسه دون دمج تلقائي';
  else raise notice 'FAIL 1: إنشاء المزارع بلا هاتف أو منع الدمج التلقائي غير صحيح'; end if;

  insert into ops.farmer_profiles (tenant_id, person_id) values (v_tenant, v_person_a) returning id into v_fp;
  insert into ops.farmer_well_accounts (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_fp, v_well, 'FWA-067-INV') returning id into v_fwa;
  insert into ops.farms (well_id, name) values (v_well, 'أرض أولى') returning id into v_farm;
  insert into ops.farms (well_id, name) values (v_well, 'أرض ثانية');
  if (select count(*) from ops.farms where well_id = v_well) = 2 then
    raise notice 'PASS 2: أضيفت عدة أراض للمزارع في البئر نفسه';
  else raise notice 'FAIL 2: لم تُحفظ الأراضي المتعددة'; end if;

  insert into core.pumps (well_id, name, power_source) values (v_well, 'مضخة إضافة أرض', 'solar') returning id into v_pump;
  insert into ops.irrigation_sessions (well_id, pump_id, farm_id, farmer_well_account_id, operator_profile_id)
  values (v_well, v_pump, v_farm, v_fwa, v_profile) returning id into v_session;
  begin
    insert into ops.farms (well_id, name) values (v_well, 'أرض أضيفت أثناء جلسة');
    raise notice 'PASS 3: أضيفت أرض جديدة أثناء بقاء جلسة السقي مفتوحة';
  exception when others then
    raise notice 'FAIL 3: رُفضت إضافة الأرض أثناء الجلسة: %', sqlerrm;
  end;

  insert into inventory.fuel_transactions
    (tenant_id, well_id, fuel_tank_id, transaction_type, ownership_type,
     quantity_ml, direction, measurement_type, unit_cost_per_liter_minor, total_cost_minor, status)
  values
    (v_tenant, v_well, v_tank, 'purchase', 'well', 10000, 'in', 'actual', 1000, 10000, 'posted'),
    (v_tenant, v_well, v_tank, 'purchase', 'well', 10000, 'in', 'actual', 3000, 30000, 'posted');
  select current_balance_ml, avg_cost_per_liter_minor into v_balance, v_avg
  from inventory.fuel_tanks where id = v_tank;
  if v_balance = 20000 and v_avg = 2000 then
    raise notice 'PASS 4: شراءان حدّثا الرصيد إلى 20 لترًا والمتوسط المرجح إلى 2000';
  else raise notice 'FAIL 4: رصيد/متوسط الخزان = %/%', v_balance, v_avg; end if;

  insert into inventory.fuel_transactions
    (tenant_id, well_id, fuel_tank_id, transaction_type, ownership_type,
     quantity_ml, direction, measurement_type, status)
  values
    (v_tenant, v_well, v_tank, 'session_consumption', 'well', 5000, 'out', 'estimated', 'posted');
  if exists (select 1 from inventory.fuel_transactions
             where well_id = v_well and quantity_ml = 5000 and measurement_type = 'estimated'
               and status = 'pending_actual_measurement')
     and (select current_balance_ml from inventory.fuel_tanks where id = v_tank) = 20000 then
    raise notice 'PASS 5: القياس التقديري بقي معلقًا ولم يخصم المخزون';
  else raise notice 'FAIL 5: القياس التقديري أثّر في المخزون أو لم يبق معلقًا'; end if;

  insert into inventory.fuel_transactions
    (tenant_id, well_id, fuel_tank_id, transaction_type, ownership_type,
     quantity_ml, direction, measurement_type, status)
  values
    (v_tenant, v_well, v_tank, 'session_consumption', 'well', 4000, 'out', 'actual', 'posted');
  if (select current_balance_ml from inventory.fuel_tanks where id = v_tank) = 16000 then
    raise notice 'PASS 6: القياس الفعلي اللاحق خصم أربعة لترات فعلية فقط';
  else raise notice 'FAIL 6: القياس الفعلي لم يحدّث الرصيد إلى 16 لترًا'; end if;

  begin
    insert into inventory.fuel_transactions
      (tenant_id, well_id, fuel_tank_id, transaction_type, ownership_type,
       quantity_ml, direction, measurement_type, status)
    values
      (v_tenant, v_well, v_tank, 'session_consumption', 'well', 17000, 'out', 'actual', 'posted');
    raise notice 'FAIL 7: سُمح بمخزون ديزل بئر سالب';
  exception when others then
    if position('رصيد ديزل البئر لا يكفي' in sqlerrm) > 0 then
      raise notice 'PASS 7: رُفض المخزون السالب منعًا باتًا';
    else raise notice 'FAIL 7: سبب رفض السالب غير متوقع: %', sqlerrm; end if;
  end;

  insert into inventory.fuel_transactions
    (tenant_id, well_id, transaction_type, ownership_type, owner_person_id,
     farmer_well_account_id, quantity_ml, direction, measurement_type, status)
  values
    (v_tenant, v_well, 'farmer_deposit', 'farmer', v_person_a, v_fwa, 5000, 'in', 'actual', 'posted'),
    (v_tenant, v_well, 'session_consumption', 'farmer', v_person_a, v_fwa, 3000, 'out', 'actual', 'posted');
  if inventory.farmer_fuel_balance_ml(v_well, v_person_a) = 2000 then
    raise notice 'PASS 8: استُخدم رصيد ديزل المزارع نفسه وبقي له فائض لترين';
  else raise notice 'FAIL 8: رصيد المزارع بعد الاستهلاك غير صحيح'; end if;

  begin
    insert into inventory.fuel_transactions
      (tenant_id, well_id, transaction_type, ownership_type, owner_person_id,
       quantity_ml, direction, measurement_type, status)
    values
      (v_tenant, v_well, 'session_consumption', 'farmer', v_person_b, 1000, 'out', 'actual', 'posted');
    raise notice 'FAIL 9: سُمح لمزارع آخر باستخدام رصيد لا يملكه';
  exception when others then
    if position('رصيد ديزل المزارع لا يكفي' in sqlerrm) > 0 then
      raise notice 'PASS 9: رُفض استخدام رصيد مزارع لمزارع آخر';
    else raise notice 'FAIL 9: سبب رفض رصيد المزارع الآخر غير متوقع: %', sqlerrm; end if;
  end;

  v_first := sync.begin_command(v_tenant, v_command, 'create_person', '{"name":"أثر واحد"}'::jsonb);
  if coalesce((v_first ->> 'duplicate')::boolean, true) = false then
    insert into core.persons (tenant_id, full_name, normalized_name)
    values (v_tenant, 'أثر أمر مزامنة', 'أثر أمر مزامنة');
  end if;
  perform sync.finish_command(v_tenant, v_command, 'accepted', '{"stored":true}'::jsonb);
  v_second := sync.begin_command(v_tenant, v_command, 'create_person', '{"name":"أثر واحد"}'::jsonb);
  if coalesce((v_second ->> 'duplicate')::boolean, false)
     and v_second -> 'response' = '{"stored":true}'::jsonb
     and (select count(*) from core.persons where tenant_id = v_tenant and full_name = 'أثر أمر مزامنة') = 1 then
    raise notice 'PASS 10: الأمر المكرر أعاد الرد المخزن ولم ينفذ الأثر مرتين';
  else raise notice 'FAIL 10: منع تكرار أمر المزامنة أو الرد المخزن غير صحيح'; end if;

  insert into core.tenants (name) values ('جهة أجنبية عن مستخدم العزل 067') returning id into v_foreign_tenant;
  insert into core.wells (tenant_id, name) values (v_foreign_tenant, 'بئر أجنبي 067') returning id into v_foreign_well;
  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_foreign_well, v_foreign_profile, 'owner', 'active');

  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';
  select count(*) into v_count from core.wells where id = v_foreign_well;
  if v_count = 0 then
    raise notice 'PASS 11: عزل الصفوف منع قراءة البئر خارج التعيين';
  else raise notice 'FAIL 11: المستخدم قرأ بئرًا خارج تعيينه'; end if;

  begin
    insert into ops.farms (well_id, name) values (v_foreign_well, 'كتابة غير مصرح بها');
    raise notice 'FAIL 12: سُمح بالكتابة في بئر خارج التعيين';
  exception when insufficient_privilege then
    raise notice 'PASS 12: عزل الصفوف منع الكتابة في البئر خارج التعيين';
  when others then
    raise notice 'FAIL 12: رُفضت الكتابة لسبب غير متوقع: %', sqlerrm;
  end;
  execute 'reset role';

  raise notice '--- انتهى اختبار المخزون والمزامنة والعزل 067 (12 فحصا) ---';
end $$;

rollback;
