begin;

set local timezone to 'UTC';

do $test$
declare
  v_count bigint;
  v_count_2 bigint;
  v_count_3 bigint;

  v_owner uuid;
  v_user_1 uuid;
  v_user_2 uuid;
  v_tenant uuid;
  v_location_1 uuid;
  v_location_2 uuid;
  v_location_3 uuid;
  v_well_1 uuid;
  v_well_2 uuid;
  v_well_3 uuid;
  v_pump_1 uuid;
  v_pump_2 uuid;
  v_pump_3 uuid;
  v_pump_4 uuid;
  v_person_1 uuid;
  v_person_2 uuid;
  v_farmer_profile_1 uuid;
  v_farmer_profile_2 uuid;
  v_account_1_well_1 uuid;
  v_account_1_well_2 uuid;
  v_account_2_well_1 uuid;
  v_farm_1_well_1 uuid;
  v_farm_1_well_2 uuid;
  v_farm_2_well_1 uuid;
  v_booking_1_well_1 uuid;
  v_booking_1_well_2 uuid;
  v_booking_2_well_1 uuid;
  v_session_1 uuid;
  v_session_2 uuid;
begin

  select count(*) into v_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'iam'
    and (
      (p.proname = 'current_farmer_well_account_id'
       and pg_get_function_identity_arguments(p.oid) = 'p_well_id uuid'
       and p.prosecdef)
      or
      (p.proname = 'has_farmer_self_access'
       and pg_get_function_identity_arguments(p.oid) = 'p_well_id uuid'
       and not p.prosecdef)
      or
      (p.proname = 'can_staff_read_profile'
       and pg_get_function_identity_arguments(p.oid) = 'p_profile_id uuid'
       and p.prosecdef)
    )
    and has_function_privilege('authenticated', p.oid, 'EXECUTE')
    and not has_function_privilege('anon', p.oid, 'EXECUTE')
    and exists (
      select 1
      from unnest(coalesce(p.proconfig, array[]::text[])) cfg
      where cfg = 'search_path=pg_catalog, pg_temp'
    );

  if v_count = 3 then
    raise notice 'PASS 1: Farmer self helpers آمنة وممنوحة صراحة';
  else
    raise notice 'FAIL 1: Farmer self helper contracts = % بدل 3', v_count;
  end if;

  select count(*) into v_count
  from pg_policies p
  where p.cmd = 'SELECT'
    and (p.schemaname || '.' || p.tablename) = any(array[
      'iam.profiles','core.wells','core.tenants','core.locations',
      'core.pumps','core.water_lines','core.pump_line_links',
      'core.persons','core.person_contacts','core.person_aliases',
      'ops.farmer_profiles','ops.farmer_well_accounts','ops.farms',
      'ops.irrigation_bookings','ops.booking_status_history',
      'ops.resource_reservations','ops.irrigation_sessions',
      'ops.session_segments','billing.session_charges'
    ])
    and position('''farmer''::text' in coalesce(p.qual, '')) > 0;

  if v_count = 0 then
    raise notice 'PASS 2: role=farmer لم يعد يفتح Select واسعًا في نطاق W1-02';
  else
    raise notice 'FAIL 2: بقيت % Select policies تعتمد farmer role القديم', v_count;
  end if;

  select count(*) into v_count
  from pg_indexes
  where indexname = any(array[
    'idx_wells_tenant_id','idx_wells_location_id',
    'idx_person_aliases_person','idx_person_contacts_person',
    'idx_pump_line_links_pump','idx_irrigation_bookings_farmer_account',
    'idx_booking_status_history_booking','idx_resource_reservations_booking',
    'idx_resource_reservations_session'
  ]);

  if v_count = 9 then
    raise notice 'PASS 3: فهارس Farmer self-scope التسعة موجودة';
  else
    raise notice 'FAIL 3: فهارس Farmer self-scope = % بدل 9', v_count;
  end if;

  if (
       select count(*)
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'api'
         and has_function_privilege('authenticated', p.oid, 'EXECUTE')
     ) >= 33
     and (
       select count(*)
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'api'
         and has_function_privilege('anon', p.oid, 'EXECUTE')
     ) = 0
     and (
       select count(*)
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'api' and p.prosecdef
     ) = 0
     and (
       select count(*)
       from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'api' and c.relkind in ('r','v','m','f','p')
     ) = 0
  then
    raise notice 'PASS 4: Data API surface آمن ومطابق وanon/Definer exposure = 0';
  else
    raise notice 'FAIL 4: Data API surface تغيرت';
  end if;


  select count(*) into v_count
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname in ('core','iam','ops','billing','finance','inventory','audit','sync','reporting')
    and c.relkind in ('r','p')
    and (
      has_table_privilege('authenticated', c.oid, 'INSERT')
      or has_table_privilege('authenticated', c.oid, 'UPDATE')
      or has_table_privilege('authenticated', c.oid, 'DELETE')
      or has_table_privilege('anon', c.oid, 'INSERT')
      or has_table_privilege('anon', c.oid, 'UPDATE')
      or has_table_privilege('anon', c.oid, 'DELETE')
    );

  if v_count = 0 then
    raise notice 'PASS 5: Direct DML بقي صفرًا';
  else
    raise notice 'FAIL 5: Direct DML ظهر على % جدول/جداول', v_count;
  end if;

  insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values (gen_random_uuid(),'00000000-0000-0000-0000-000000000000','authenticated','authenticated','q111-owner@test.local',crypt('x',gen_salt('bf')),now(),now(),now())
  returning id into v_owner;

  insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values (gen_random_uuid(),'00000000-0000-0000-0000-000000000000','authenticated','authenticated','q111-farmer-1@test.local',crypt('x',gen_salt('bf')),now(),now(),now())
  returning id into v_user_1;

  insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values (gen_random_uuid(),'00000000-0000-0000-0000-000000000000','authenticated','authenticated','q111-farmer-2@test.local',crypt('x',gen_salt('bf')),now(),now(),now())
  returning id into v_user_2;

  update iam.profiles set full_name = 'مالك اختبار W1-02' where id = v_owner;
  update iam.profiles set full_name = 'مزارع اختبار أول' where id = v_user_1;
  update iam.profiles set full_name = 'مزارع اختبار ثان' where id = v_user_2;

  insert into core.tenants (name) values ('جهة اختبار W1-02') returning id into v_tenant;

  insert into core.locations (tenant_id,governorate,local_area)
  values (v_tenant,'صنعاء','موقع البئر الأول') returning id into v_location_1;
  insert into core.locations (tenant_id,governorate,local_area)
  values (v_tenant,'صنعاء','موقع البئر الثاني') returning id into v_location_2;
  insert into core.locations (tenant_id,governorate,local_area)
  values (v_tenant,'صنعاء','موقع البئر الثالث') returning id into v_location_3;

  insert into core.wells (tenant_id,name,location_id)
  values (v_tenant,'بئر W1-02 الأول',v_location_1) returning id into v_well_1;
  insert into core.wells (tenant_id,name,location_id)
  values (v_tenant,'بئر W1-02 الثاني',v_location_2) returning id into v_well_2;
  insert into core.wells (tenant_id,name,location_id)
  values (v_tenant,'بئر W1-02 الثالث',v_location_3) returning id into v_well_3;

  insert into core.well_assignments (well_id,profile_id,role,status) values
    (v_well_1,v_owner,'owner','active'),
    (v_well_2,v_owner,'owner','active'),
    (v_well_3,v_owner,'owner','active');

  insert into core.well_assignments (well_id,profile_id,role,status) values
    (v_well_1,v_user_1,'farmer','active'),
    (v_well_1,v_user_2,'farmer','active');

  insert into core.pumps (well_id,name,power_source) values (v_well_1,'مضخة 1','solar') returning id into v_pump_1;
  insert into core.pumps (well_id,name,power_source) values (v_well_1,'مضخة 2','solar') returning id into v_pump_2;
  insert into core.pumps (well_id,name,power_source) values (v_well_2,'مضخة 3','solar') returning id into v_pump_3;
  insert into core.pumps (well_id,name,power_source) values (v_well_3,'مضخة 4','solar') returning id into v_pump_4;

  insert into core.persons (tenant_id,full_name,normalized_name)
  values (v_tenant,'المزارع الأول','المزارع الاول') returning id into v_person_1;
  insert into core.persons (tenant_id,full_name,normalized_name)
  values (v_tenant,'المزارع الثاني','المزارع الثاني') returning id into v_person_2;

  insert into core.person_contacts (tenant_id,person_id,contact_type,contact_value,normalized_value,is_primary) values
    (v_tenant,v_person_1,'mobile','700001111','700001111',true),
    (v_tenant,v_person_2,'mobile','700002222','700002222',true);

  insert into core.person_aliases (tenant_id,person_id,alias,normalized_alias) values
    (v_tenant,v_person_1,'المزارع الأول المعروف','المزارع الاول المعروف'),
    (v_tenant,v_person_2,'المزارع الثاني المعروف','المزارع الثاني المعروف');

  insert into iam.profile_person_links (tenant_id,profile_id,person_id,linked_by,link_reason) values
    (v_tenant,v_user_1,v_person_1,v_owner,'W1-02 explicit test identity'),
    (v_tenant,v_user_2,v_person_2,v_owner,'W1-02 explicit test identity');

  insert into ops.farmer_profiles (tenant_id,person_id)
  values (v_tenant,v_person_1) returning id into v_farmer_profile_1;
  insert into ops.farmer_profiles (tenant_id,person_id)
  values (v_tenant,v_person_2) returning id into v_farmer_profile_2;

  insert into ops.farmer_well_accounts (tenant_id,farmer_profile_id,well_id,public_code)
  values (v_tenant,v_farmer_profile_1,v_well_1,'FWA-1-W1') returning id into v_account_1_well_1;
  insert into ops.farmer_well_accounts (tenant_id,farmer_profile_id,well_id,public_code)
  values (v_tenant,v_farmer_profile_1,v_well_2,'FWA-1-W2') returning id into v_account_1_well_2;
  insert into ops.farmer_well_accounts (tenant_id,farmer_profile_id,well_id,public_code)
  values (v_tenant,v_farmer_profile_2,v_well_1,'FWA-2-W1') returning id into v_account_2_well_1;

  insert into ops.farms (well_id,name,farmer_well_account_id)
  values (v_well_1,'أرض المزارع الأول - البئر الأول',v_account_1_well_1) returning id into v_farm_1_well_1;
  insert into ops.farms (well_id,name,farmer_well_account_id)
  values (v_well_2,'أرض المزارع الأول - البئر الثاني',v_account_1_well_2) returning id into v_farm_1_well_2;
  insert into ops.farms (well_id,name,farmer_well_account_id)
  values (v_well_1,'أرض المزارع الثاني',v_account_2_well_1) returning id into v_farm_2_well_1;

  insert into ops.irrigation_bookings
    (tenant_id,public_code,well_id,farmer_well_account_id,farm_id,pump_id,scheduled_start,scheduled_end,expected_duration_minutes,expected_energy_source,status,created_by)
  values
    (v_tenant,'BOOK-1-W1',v_well_1,v_account_1_well_1,v_farm_1_well_1,v_pump_1,'2031-01-01 06:00:00+00','2031-01-01 07:00:00+00',60,'solar','confirmed',v_owner)
  returning id into v_booking_1_well_1;

  insert into ops.irrigation_bookings
    (tenant_id,public_code,well_id,farmer_well_account_id,farm_id,pump_id,scheduled_start,scheduled_end,expected_duration_minutes,expected_energy_source,status,created_by)
  values
    (v_tenant,'BOOK-1-W2',v_well_2,v_account_1_well_2,v_farm_1_well_2,v_pump_3,'2031-01-02 06:00:00+00','2031-01-02 07:00:00+00',60,'solar','confirmed',v_owner)
  returning id into v_booking_1_well_2;

  insert into ops.irrigation_bookings
    (tenant_id,public_code,well_id,farmer_well_account_id,farm_id,pump_id,scheduled_start,scheduled_end,expected_duration_minutes,expected_energy_source,status,created_by)
  values
    (v_tenant,'BOOK-2-W1',v_well_1,v_account_2_well_1,v_farm_2_well_1,v_pump_2,'2031-01-01 06:00:00+00','2031-01-01 07:00:00+00',60,'solar','confirmed',v_owner)
  returning id into v_booking_2_well_1;

  insert into ops.booking_status_history (tenant_id,booking_id,new_status,changed_by) values
    (v_tenant,v_booking_1_well_1,'confirmed',v_owner),
    (v_tenant,v_booking_1_well_2,'confirmed',v_owner),
    (v_tenant,v_booking_2_well_1,'confirmed',v_owner);

  insert into ops.irrigation_sessions
    (well_id,pump_id,farm_id,operator_profile_id,started_at,status,price_per_hour_minor_snapshot,farmer_well_account_id)
  values
    (v_well_1,v_pump_1,v_farm_1_well_1,v_owner,'2031-02-01 06:00:00+00','open',3600,v_account_1_well_1)
  returning id into v_session_1;

  insert into ops.irrigation_sessions
    (well_id,pump_id,farm_id,operator_profile_id,started_at,status,price_per_hour_minor_snapshot,farmer_well_account_id)
  values
    (v_well_1,v_pump_2,v_farm_2_well_1,v_owner,'2031-02-01 06:00:00+00','open',3600,v_account_2_well_1)
  returning id into v_session_2;

  insert into ops.session_segments
    (tenant_id,session_id,sequence_number,segment_type,energy_source,started_at,is_billable)
  values
    (v_tenant,v_session_1,1,'solar_run','solar','2031-02-01 06:00:00+00',true),
    (v_tenant,v_session_2,1,'solar_run','solar','2031-02-01 06:00:00+00',true);

  insert into billing.session_charges
    (session_id,well_id,duration_seconds,price_per_hour_minor,amount_minor)
  values
    (v_session_1,v_well_1,3600,3600,3600),
    (v_session_2,v_well_1,3600,3600,3600);

  insert into ops.resource_reservations
    (tenant_id,well_id,resource_type,resource_id,booking_id,reserved_period,status)
  values
    (v_tenant,v_well_1,'pump',v_pump_1,v_booking_1_well_1,tstzrange('2031-01-01 06:00:00+00','2031-01-01 07:00:00+00','[)'),'active'),
    (v_tenant,v_well_1,'pump',v_pump_2,v_booking_2_well_1,tstzrange('2031-01-01 06:00:00+00','2031-01-01 07:00:00+00','[)'),'active');

  perform set_config('request.jwt.claim.sub', v_user_1::text, true);
  execute 'set local role authenticated';

  if iam.current_farmer_well_account_id(v_well_1) = v_account_1_well_1
     and iam.current_farmer_well_account_id(v_well_2) = v_account_1_well_2
     and iam.current_farmer_well_account_id(v_well_3) is null then
    raise notice 'PASS 6: الحساب يحل Farmer Well Account الصحيحة لكل بئر';
  else
    raise notice 'FAIL 6: Farmer Well Account resolution غير صحيح';
  end if;

  if not iam.has_well_role(v_well_2,array['owner','manager','operator','farmer'])
     and iam.has_farmer_self_access(v_well_2)
     and exists (select 1 from core.wells where id = v_well_2) then
    raise notice 'PASS 7: بياناتي كمزارع تعمل دون منح صلاحية إدارية للبئر';
  else
    raise notice 'FAIL 7: Self Farmer access يعتمد خطأ على well_assignment';
  end if;

  select count(*) into v_count from core.wells where tenant_id = v_tenant;
  select count(*) into v_count_2 from core.locations where tenant_id = v_tenant;
  select count(*) into v_count_3 from core.pumps where well_id in (v_well_1,v_well_2,v_well_3);
  if v_count = 2 and v_count_2 = 2 and v_count_3 = 3 then
    raise notice 'PASS 8: Shared well references محصورة في الآبار الذاتية';
  else
    raise notice 'FAIL 8: shared counts wells=% locations=% pumps=%', v_count,v_count_2,v_count_3;
  end if;

  select count(*) into v_count from core.persons where tenant_id = v_tenant;
  if v_count = 1
     and exists (select 1 from core.persons where id = v_person_1)
     and not exists (select 1 from core.persons where id = v_person_2) then
    raise notice 'PASS 9: Farmer يرى Person الخاصة به فقط';
  else
    raise notice 'FAIL 9: Person self-scope count=%', v_count;
  end if;

  select count(*) into v_count from core.person_contacts where tenant_id = v_tenant;
  select count(*) into v_count_2 from core.person_aliases where tenant_id = v_tenant;
  if v_count = 1 and v_count_2 = 1 then
    raise notice 'PASS 10: وسائل الاتصال والأسماء البديلة Self-only';
  else
    raise notice 'FAIL 10: contacts=% aliases=%', v_count,v_count_2;
  end if;

  select count(*) into v_count from iam.profiles where id in (v_owner,v_user_1,v_user_2);
  if v_count = 1 and exists (select 1 from iam.profiles where id = v_user_1) then
    raise notice 'PASS 11: Farmer-only لا يرى Login Profiles للزملاء';
  else
    raise notice 'FAIL 11: visible login profiles=% بدل 1', v_count;
  end if;

  select count(*) into v_count from ops.farmer_profiles where tenant_id = v_tenant;
  if v_count = 1 and exists (select 1 from ops.farmer_profiles where id = v_farmer_profile_1) then
    raise notice 'PASS 12: Farmer Profile محصورة في Self';
  else
    raise notice 'FAIL 12: Farmer Profile visible count=%', v_count;
  end if;

  select count(*) into v_count from ops.farmer_well_accounts where tenant_id = v_tenant;
  if v_count = 2
     and exists (select 1 from ops.farmer_well_accounts where id = v_account_1_well_1)
     and exists (select 1 from ops.farmer_well_accounts where id = v_account_1_well_2)
     and not exists (select 1 from ops.farmer_well_accounts where id = v_account_2_well_1) then
    raise notice 'PASS 13: Farmer Well Accounts الذاتية فقط ظاهرة';
  else
    raise notice 'FAIL 13: visible Farmer Well Accounts=% بدل 2', v_count;
  end if;

  select count(*) into v_count from ops.farms where well_id in (v_well_1,v_well_2,v_well_3);
  if v_count = 2 and not exists (select 1 from ops.farms where id = v_farm_2_well_1) then
    raise notice 'PASS 14: Farmer يرى أراضيه فقط';
  else
    raise notice 'FAIL 14: visible farms=% بدل 2', v_count;
  end if;

  select count(*) into v_count from ops.irrigation_bookings where tenant_id = v_tenant;
  if v_count = 2 and not exists (select 1 from ops.irrigation_bookings where id = v_booking_2_well_1) then
    raise notice 'PASS 15: Farmer يرى حجوزاته فقط';
  else
    raise notice 'FAIL 15: visible bookings=% بدل 2', v_count;
  end if;

  select count(*) into v_count from ops.booking_status_history where tenant_id = v_tenant;
  if v_count = 2 then
    raise notice 'PASS 16: Farmer يرى تاريخ حجوزاته فقط';
  else
    raise notice 'FAIL 16: visible booking history=% بدل 2', v_count;
  end if;

  select count(*) into v_count from ops.irrigation_sessions where well_id = v_well_1;
  if v_count = 1
     and exists (select 1 from ops.irrigation_sessions where id = v_session_1)
     and not exists (select 1 from ops.irrigation_sessions where id = v_session_2) then
    raise notice 'PASS 17: Farmer يرى جلساته فقط';
  else
    raise notice 'FAIL 17: visible sessions=% بدل 1', v_count;
  end if;

  select count(*) into v_count from ops.session_segments where tenant_id = v_tenant;
  select count(*) into v_count_2 from billing.session_charges where well_id = v_well_1;
  if v_count = 1 and v_count_2 = 1 then
    raise notice 'PASS 18: تفاصيل ورسوم الجلسة محصورة في جلسة Farmer الذاتية';
  else
    raise notice 'FAIL 18: segments=% charges=%', v_count,v_count_2;
  end if;

  select count(*) into v_count from ops.resource_reservations where well_id = v_well_1;
  if v_count = 1 then
    raise notice 'PASS 19: Farmer يرى Resource Reservation الخاصة به فقط';
  else
    raise notice 'FAIL 19: visible reservations=% بدل 1', v_count;
  end if;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';

  select count(*) into v_count from core.persons where tenant_id = v_tenant;
  select count(*) into v_count_2 from ops.farmer_well_accounts where tenant_id = v_tenant;
  select count(*) into v_count_3 from ops.farms where well_id in (v_well_1,v_well_2,v_well_3);

  if v_count = 2
     and v_count_2 = 3
     and v_count_3 = 3
     and (select count(*) from ops.irrigation_bookings where tenant_id = v_tenant) = 3
     and (select count(*) from ops.irrigation_sessions where well_id = v_well_1) = 2
     and (select count(*) from iam.profiles where id in (v_owner,v_user_1,v_user_2)) = 3 then
    raise notice 'PASS 20: Owner/Staff visibility بقيت كاملة بعد Farmer self-scope';
  else
    raise notice 'FAIL 20: Staff regression persons=% accounts=% farms=%', v_count,v_count_2,v_count_3;
  end if;

  execute 'reset role';
end;
$test$;

rollback;
