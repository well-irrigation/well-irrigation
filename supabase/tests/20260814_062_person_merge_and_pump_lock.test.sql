begin;

do $$
declare
  v_tenant uuid; v_well uuid; v_pump uuid; v_farm uuid;
  v_user uuid; v_oprof uuid;
  v_a uuid; v_b uuid; v_c uuid; v_d uuid; v_e uuid;
  v_req uuid; v_n integer; v_s1 uuid;
begin
  insert into core.tenants (name) values ('مستأجر اختبار 062') returning id into v_tenant;
  insert into core.wells (tenant_id, name) values (v_tenant, 'بئر اختبار 062') returning id into v_well;

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'op062@test.local', crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_user;
  select id into v_oprof from iam.profiles where id = v_user;
  if v_oprof is null then
    insert into iam.profiles (id, full_name) values (v_user, 'مشغل اختبار 062') returning id into v_oprof;
  end if;

  insert into core.persons (tenant_id, full_name, normalized_name) values (v_tenant, 'محمد صالح', 'محمد صالح') returning id into v_a;
  insert into core.person_contacts (tenant_id, person_id, contact_type, contact_value, normalized_value) values (v_tenant, v_a, 'mobile', '777111222', '777111222');
  insert into core.persons (tenant_id, full_name, normalized_name) values (v_tenant, 'مُحَمَّد صَالِح', 'محمد صالح') returning id into v_b;
  insert into core.persons (tenant_id, full_name, normalized_name) values (v_tenant, 'سالم احمد', 'سالم احمد') returning id into v_c;

  if core.normalize_arabic('مُحَمَّد  صَالِح') = core.normalize_arabic('محمد صالح')
     and core.normalize_phone('+967-777-111-222') = core.normalize_phone('777111222') then
    raise notice 'PASS 1: تطبيع الاسم العربي والهاتف يعمل';
  else raise notice 'FAIL 1'; end if;

  select count(*) into v_n from core.find_person_duplicates(v_tenant, 'محمد صالح', '00967777111222') where match_level = 'match';
  if v_n = 1 then raise notice 'PASS 2: التطابق الكامل (اسم+هاتف) يكشف المزارع الموجود';
  else raise notice 'FAIL 2 (%)', v_n; end if;

  select count(*) into v_n from core.find_person_duplicates(v_tenant, 'سالم احمد', '777111222') where match_level = 'suspect' and matched_on = 'phone';
  if v_n = 1 then raise notice 'PASS 3: الشك بالهاتف فقط يعرض المرشح';
  else raise notice 'FAIL 3 (%)', v_n; end if;

  select count(*) into v_n from core.find_person_duplicates(v_tenant, 'محمد صالح', null) where match_level = 'suspect' and matched_on = 'name';
  if v_n = 2 then raise notice 'PASS 4: الشك بالاسم فقط يعرض كل المرشحين';
  else raise notice 'FAIL 4 (%)', v_n; end if;

  insert into core.person_contacts (tenant_id, person_id, contact_type, contact_value, normalized_value) values (v_tenant, v_b, 'mobile', '700999888', '700999888');

  v_req := core.merge_persons(v_a, v_b, 'دمج مكرر بعد تنبيه التطابق', v_oprof);

  if (select status from core.persons where id = v_b) = 'archived'
     and (select merged_into_person_id from core.persons where id = v_b) = v_a
     and (select person_id from core.person_contacts where contact_value = '700999888') = v_a
  then raise notice 'PASS 5: الدمج نقل المراجع وأرشف المكرر وربطه بالأصلي';
  else raise notice 'FAIL 5'; end if;

  if exists (select 1 from core.person_merge_requests where id = v_req and status = 'merged' and primary_person_id = v_a and duplicate_person_id = v_b)
     and exists (select 1 from audit.audit_logs where action = 'person_merged' and entity_id = v_b)
  then raise notice 'PASS 6: طلب الدمج سُجل وكتب في سجل التدقيق';
  else raise notice 'FAIL 6'; end if;

  begin
    perform core.merge_persons(v_a, v_a, 'x', v_oprof);
    raise notice 'FAIL 7: سُمح بدمج الشخص في نفسه';
  exception when others then
    raise notice 'PASS 7: رُفض دمج الشخص في نفسه';
  end;

  begin
    perform core.merge_persons(v_a, v_b, 'x', v_oprof);
    raise notice 'FAIL 8: سُمح بدمج شخص مؤرشف';
  exception when others then
    raise notice 'PASS 8: رُفض دمج شخص مؤرشف مسبقا';
  end;

  insert into core.persons (tenant_id, full_name, normalized_name) values (v_tenant, 'مزارع دال', 'مزارع دال') returning id into v_d;
  insert into core.persons (tenant_id, full_name, normalized_name) values (v_tenant, 'مزارع هاء', 'مزارع هاء') returning id into v_e;
  insert into ops.farmer_profiles (tenant_id, person_id) values (v_tenant, v_d);
  insert into ops.farmer_profiles (tenant_id, person_id) values (v_tenant, v_e);

  begin
    perform core.merge_persons(v_d, v_e, 'x', v_oprof);
    raise notice 'FAIL 9: سُمح بدمج مزارعين لكل منهما حسابات';
  exception when others then
    raise notice 'PASS 9: رُفض دمج مزارعين لكل منهما ملف — حماية الأرصدة';
  end;

  insert into core.pumps (well_id, name, power_source) values (v_well, 'مضخة 062', 'solar') returning id into v_pump;
  insert into ops.farms (well_id, name) values (v_well, 'مزرعة 062') returning id into v_farm;
  insert into ops.irrigation_sessions (well_id, pump_id, farm_id, operator_profile_id) values (v_well, v_pump, v_farm, v_oprof) returning id into v_s1;

  begin
    insert into ops.irrigation_sessions (well_id, pump_id, farm_id, operator_profile_id) values (v_well, v_pump, v_farm, v_oprof);
    raise notice 'FAIL 10: سُمح بجلستين على نفس المضخة';
  exception when others then
    raise notice 'PASS 10: رُفضت جلسة ثانية على مضخة مشغولة (الافتراضي 1)';
  end;

  insert into ops.resource_concurrency_rules (tenant_id, well_id, resource_type, resource_id, max_parallel_sessions)
  values (v_tenant, v_well, 'pump', v_pump, 2);

  begin
    insert into ops.irrigation_sessions (well_id, pump_id, farm_id, operator_profile_id) values (v_well, v_pump, v_farm, v_oprof);
    raise notice 'PASS 11: قاعدة المالك رفعت الحد الى 2 وسُمح بجلسة ثانية';
  exception when others then
    raise notice 'FAIL 11';
  end;

  begin
    insert into ops.irrigation_sessions (well_id, pump_id, farm_id, operator_profile_id) values (v_well, v_pump, v_farm, v_oprof);
    raise notice 'FAIL 12: سُمح بجلسة ثالثة فوق الحد';
  exception when others then
    raise notice 'PASS 12: رُفضت الجلسة الثالثة عند بلوغ الحد 2';
  end;

  begin
    insert into ops.resource_concurrency_rules (tenant_id, well_id, resource_type, resource_id, max_parallel_sessions)
    values (v_tenant, v_well, 'pump', v_pump, 3);
    raise notice 'FAIL 13: سُمح بقاعدتين نشطتين لنفس المورد';
  exception when unique_violation then
    raise notice 'PASS 13: قاعدة واحدة نشطة فقط لكل مورد';
  end;

  raise notice '--- انتهى اختبار 062 (13 فحصا) ---';
end $$;

rollback;
