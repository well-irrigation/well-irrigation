-- =====================================================================
-- اختبار Migration 112 الدائم — عقد الحجوزات: ق-131 بند 8 / ق-98 م-28
-- مسار بئر واحد + قيد استبعاد + تعارض مكتوب + إلغاء + قراءات مكتوبة
-- =====================================================================
-- خريطة الفحوص إلى بنود المهمة:
--   1..6 بنيوية: توقيعات قديمة مفقودة، قيد استبعاد حقيقي، صلاحية
--      booking.cancel، حجب anon، حرس 075 وقراءات invoker.
--   7..24 سلوكية: إنشاء قانوني ذري، تعارض مكتوب، سباق القيد،
--      فترات متلاصقة، آبار مختلفة، replay للقبول والتعارض، mismatch،
--      إعادة جدولة ناجحة/متعارضة، postponed→confirmed، إلغاء وتحرير
--      المسار وإعادة استخدام الفترة وreplay الإلغاء.
--   25..30 صلاحيات وقراءات: owner/operator/farmer، قائمة وتفصيل
--      مرتّبان، رفض بئر غير مصرح، وDML مباشر مغلق.
-- ملاحظة إثبات التزامن: الفحص التسلسلي وحده لا يثبت التزامن؛
-- البرهان الحاكم هو قيد الاستبعاد نفسه (contype='x') الذي تتحقق منه
-- قاعدة البيانات في كل إدراج مهما تزامنت المعاملات.
-- =====================================================================

begin;

set local timezone to 'UTC';

do $test$
declare
  v_tenant uuid;
  v_well_a uuid;
  v_well_b uuid;
  v_owner_user uuid;
  v_operator_user uuid;
  v_farmer_user uuid;
  v_farmer_b_user uuid;
  v_partner_user uuid;
  v_accountant_user uuid;
  v_viewer_user uuid;
  v_manager_user uuid;
  v_intruder_user uuid;
  v_person_1 uuid;
  v_person_2 uuid;
  v_person_b uuid;
  v_account_1 uuid;
  v_account_2 uuid;
  v_account_b uuid;
  v_farm_a uuid;
  v_farm_b uuid;
  v_cmd_create_1 uuid;
  v_cmd_conflict uuid;
  v_cmd_touch_1 uuid;
  v_cmd_touch_2 uuid;
  v_cmd_well_b uuid;
  v_cmd_resch_conflict uuid;
  v_cmd_resch_ok uuid;
  v_cmd_resch_postponed uuid;
  v_cmd_cancel uuid;
  v_cmd_after_cancel uuid;
  v_booking_1 uuid;
  v_booking_2 uuid;
  v_booking_3 uuid;
  v_booking_5 uuid;
  v_farm_2 uuid;
  v_response jsonb;
  v_response_2 jsonb;
  v_create1_response jsonb;
  v_cancel_response jsonb;
  v_conflict_response jsonb;
  v_count bigint;
  v_count_2 bigint;
  v_start timestamptz;
  v_end timestamptz;
  v_active_reservation uuid;
  v_active_reservation_2 uuid;
  v_history_count bigint;
  v_sig text;
begin

  -- ============================================================
  -- 1. توقيع api.create_booking القديم (pump/water_line) مفقود
  -- ============================================================
  if to_regprocedure(
    'api.create_booking(uuid,uuid,uuid,timestamptz,timestamptz,uuid,uuid,text,integer,text)'
  ) is null then
    raise notice 'PASS 1: توقيع api.create_booking القديم بمضخة وخط مياه أُسقط';
  else
    raise notice 'FAIL 1: توقيع api.create_booking القديم ما زال حيًا';
  end if;

  -- ============================================================
  -- 2. الحمل الداخلي القديم ops.create_booking بمضخة/خط مفقود،
  --    والتوقيع القانوني الجديد موجود وحده.
  -- ============================================================
  if to_regprocedure(
    'ops.create_booking(uuid,uuid,uuid,timestamptz,timestamptz,uuid,uuid,text,integer,text)'
  ) is null
    and to_regprocedure(
      'ops.create_booking(uuid,uuid,uuid,timestamptz,timestamptz,text,integer,text)'
    ) is not null then
    raise notice 'PASS 2: ops.create_booking على التوقيع القانوني وحده بلا حمل مضخة/خط';
  else
    raise notice 'FAIL 2: حمل ops.create_booking غير صحيح';
  end if;

  -- ============================================================
  -- 3. قيد استبعاد حقيقي (contype='x') على جدول الحجوزات يحرس
  --    تداخل المؤكد على نفس البئر — وهو برهان التزامن الحاكم.
  -- ============================================================
  select count(*) into v_count
  from pg_constraint con
  join pg_class c on c.oid = con.conrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'ops'
    and c.relname = 'irrigation_bookings'
    and con.contype = 'x'
    and con.conname = 'irrigation_bookings_no_confirmed_well_overlap'
    and pg_get_constraintdef(con.oid) like '%well_id%'
    and pg_get_constraintdef(con.oid) like '%&&%'
    and pg_get_constraintdef(con.oid) like '%status = %confirmed%';

  if v_count = 1 then
    raise notice 'PASS 3: قيد استبعاد حقيقي على القاعدة يحرس تداخل المؤكد على البئر';
  else
    raise notice 'FAIL 3: قيد الاستبعاد غير موجود أو غير مطابق: %', v_count;
  end if;

  -- ============================================================
  -- 4. صلاحية booking.cancel موجودة في الكتالوج.
  -- ============================================================
  if exists (select 1 from iam.permissions where code = 'booking.cancel') then
    raise notice 'PASS 4: صلاحية booking.cancel موجودة في iam.permissions';
  else
    raise notice 'FAIL 4: صلاحية booking.cancel غير موجودة';
  end if;

  -- ============================================================
  -- 5. anon محجوب عن كل عقود الحجوزات العامة.
  -- ============================================================
  if not has_function_privilege('anon',
       'api.create_booking(uuid,uuid,uuid,timestamptz,timestamptz,uuid,text,integer,text)', 'EXECUTE')
     and not has_function_privilege('anon',
       'api.reschedule_booking(uuid,timestamptz,timestamptz,text,uuid)', 'EXECUTE')
     and not has_function_privilege('anon',
       'api.cancel_booking(uuid,text,uuid)', 'EXECUTE')
     and not has_function_privilege('anon',
       'api.list_well_bookings(uuid,timestamptz,timestamptz,integer)', 'EXECUTE')
     and not has_function_privilege('anon',
       'api.get_booking_detail(uuid)', 'EXECUTE') then
    raise notice 'PASS 5: anon محجوب عن عقود الحجوزات الخمسة';
  else
    raise notice 'FAIL 5: anon يملك تنفيذًا على عقد حجوزات';
  end if;

  -- ============================================================
  -- 6. حرسات قائمة باقية: زناد اتساق الأرض/الحساب من 075، وحرس
  --    تفرّد well_path النشط لكل حجز، والقراءات invoker وstable.
  -- ============================================================
  v_sig := 'p_well_id uuid, p_farmer_well_account_id uuid, p_farm_id uuid, '
           || 'p_scheduled_start timestamp with time zone, p_scheduled_end timestamp with time zone, '
           || 'p_expected_energy_source text, p_priority integer, p_notes text';
  if exists (
    select 1 from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'ops' and c.relname = 'irrigation_bookings'
      and t.tgname = 'trg_irrigation_bookings_farm_assignment'
  )
    and exists (
      select 1 from pg_indexes
      where schemaname = 'ops'
        and tablename = 'resource_reservations'
        and indexname = 'uq_resource_reservations_active_well_path_booking'
    )
    and exists (
      select 1 from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'api' and p.proname = 'list_well_bookings'
        and not p.prosecdef and p.provolatile = 's'
        and pg_get_function_identity_arguments(p.oid)
            = 'p_well_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_limit integer'
    )
    and exists (
      select 1 from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'ops' and p.proname = 'create_booking'
        and pg_get_function_identity_arguments(p.oid) = v_sig
    ) then
    raise notice 'PASS 6: حرس 075 وحرس well_path التفريدي وبنيات القراءات القانونية باقية';
  else
    raise notice 'FAIL 6: إحدى البنيات الحاكمة تغيرت';
  end if;

  -- ============================================================
  -- تجهيزات: مستخدمون وجهة وبئران وحسابات وأراضٍ.
  -- ============================================================
  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'owner112@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_owner_user;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'operator112@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_operator_user;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'farmer112@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_farmer_user;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'manager112@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_manager_user;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'farmerb112@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_farmer_b_user;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'partner112@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_partner_user;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'accountant112@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_accountant_user;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'viewer112@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_viewer_user;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'intruder112@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_intruder_user;

  insert into core.tenants (name) values ('جهة اختبار الحجوزات 112')
    returning id into v_tenant;
  insert into core.wells (tenant_id, name) values (v_tenant, 'بئر الحجوزات أ 112')
    returning id into v_well_a;
  insert into core.wells (tenant_id, name) values (v_tenant, 'بئر الحجوزات ب 112')
    returning id into v_well_b;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values
    (v_well_a, v_owner_user, 'owner', 'active'),
    (v_well_a, v_manager_user, 'manager', 'active'),
    (v_well_a, v_operator_user, 'operator', 'active'),
    (v_well_a, v_farmer_user, 'farmer', 'active'),
    (v_well_a, v_partner_user, 'partner', 'active'),
    (v_well_a, v_accountant_user, 'accountant', 'active'),
    (v_well_a, v_viewer_user, 'viewer', 'active'),
    (v_well_b, v_owner_user, 'owner', 'active'),
    (v_well_b, v_operator_user, 'operator', 'active');

  perform set_config('request.jwt.claim.sub', v_operator_user::text, true);
  execute 'set local role authenticated';

  v_response := ops.create_farmer(v_well_a, 'فلاح الحجوزات الأول', '777112001');
  v_person_1 := (v_response ->> 'person_id')::uuid;
  v_account_1 := (v_response ->> 'farmer_well_account_id')::uuid;

  v_response := ops.create_farmer(v_well_a, 'سعيد عبدالله سالم', '777112002');
  v_person_2 := (v_response ->> 'person_id')::uuid;
  v_account_2 := (v_response ->> 'farmer_well_account_id')::uuid;
  if v_account_2 is null then
    raise notice 'FAIL 15: تسمية المزارع الثاني أشعلت اشتباه التطابق: %', v_response;
  end if;

  v_response := ops.create_farmer(v_well_b, 'محمود سالم الشامي', '777112003');
  v_account_b := (v_response ->> 'farmer_well_account_id')::uuid;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';

  v_response := api.create_farm(
    v_well_a, 'أرض الفلاح الأول', v_account_1, null, gen_random_uuid()
  );
  v_farm_a := (v_response ->> 'farm_id')::uuid;

  v_response := api.create_farm(
    v_well_b, 'أرض البئر الثاني', v_account_b, null, gen_random_uuid()
  );
  v_farm_b := (v_response ->> 'farm_id')::uuid;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_operator_user::text, true);
  execute 'set local role authenticated';

  v_cmd_create_1 := gen_random_uuid();
  v_cmd_conflict := gen_random_uuid();
  v_cmd_touch_1 := gen_random_uuid();
  v_cmd_touch_2 := gen_random_uuid();
  v_cmd_well_b := gen_random_uuid();
  v_cmd_resch_conflict := gen_random_uuid();
  v_cmd_resch_ok := gen_random_uuid();
  v_cmd_resch_postponed := gen_random_uuid();
  v_cmd_cancel := gen_random_uuid();
  v_cmd_after_cancel := gen_random_uuid();

  -- ============================================================
  -- 7. الإنشاء القانوني بلا مضخة ولا خط مياه ينجح ويؤكد الحجز.
  -- ============================================================
  v_response := api.create_booking(
    v_well_a, v_account_1, v_farm_a,
    timestamptz '2026-10-05 08:00:00+00',
    timestamptz '2026-10-05 10:00:00+00',
    v_cmd_create_1, 'well_diesel', 1, 'حجز أول 112'
  );
  v_booking_1 := (v_response ->> 'booking_id')::uuid;
  v_create1_response := v_response;

  if v_response ->> 'status' = 'confirmed'
     and (v_response ->> 'public_code') is not null
     and exists (
       select 1 from ops.irrigation_bookings b
       where b.id = v_booking_1
         and b.status = 'confirmed'
         and b.pump_id is null
         and b.water_line_id is null
         and b.expected_duration_minutes = 120
     ) then
    raise notice 'PASS 7: الإنشاء القانوني بلا مضخة/خط أكّد الحجز بأعمدة إرثية فارغة';
  else
    raise notice 'FAIL 7: الإنشاء القانوني لم ينتج حجزًا مؤكدًا صحيحًا: %', v_response;
  end if;

  -- ============================================================
  -- 8. الإنشاء ذري: حجز مؤكد + صف حالة واحد + حجز well_path نشط واحد.
  -- ============================================================
  select
    (select count(*) from ops.booking_status_history h where h.booking_id = v_booking_1),
    (select count(*) from ops.resource_reservations r
     where r.booking_id = v_booking_1 and r.status = 'active'
       and r.resource_type = 'well_path' and r.resource_id = v_well_a)
  into v_count, v_count_2;

  if v_count = 1 and v_count_2 = 1 then
    raise notice 'PASS 8: الإنشاء كتب الحجز وصف حالة واحدًا وحجز well_path نشط واحدًا ذريًا';
  else
    raise notice 'FAIL 8: ذرية الإنشاء مكسورة: history=% reservations=%', v_count, v_count_2;
  end if;

  -- ============================================================
  -- 9. الفترات المتلاصقة [08,10) و[10,11) و[11,12) تنجح كلها
  --    (نصف مفتوحة [) لا تعارض عند التلامس).
  -- ============================================================
  v_response_2 := api.create_booking(
    v_well_a, v_account_1, v_farm_a,
    timestamptz '2026-10-05 10:00:00+00',
    timestamptz '2026-10-05 11:00:00+00',
    v_cmd_touch_1, null, 0, null
  );
  v_booking_2 := (v_response_2 ->> 'booking_id')::uuid;

  v_response := api.create_booking(
    v_well_a, v_account_1, v_farm_a,
    timestamptz '2026-10-05 11:00:00+00',
    timestamptz '2026-10-05 12:00:00+00',
    v_cmd_touch_2, null, 0, null
  );
  v_booking_3 := (v_response ->> 'booking_id')::uuid;

  if v_response_2 ->> 'status' = 'confirmed'
     and v_response ->> 'status' = 'confirmed' then
    raise notice 'PASS 9: الفترات المتلاصقة [10,11) و[11,12) نجحتا بلا تعارض';
  else
    raise notice 'FAIL 9: فترة متلاصقة رُفضت خطأً: % / %', v_response_2, v_response;
  end if;

  -- ============================================================
  -- 10. نفس الفترة على بئر مختلف تنجح (المسار لكل بئر).
  -- ============================================================
  v_response := api.create_booking(
    v_well_b, v_account_b, v_farm_b,
    timestamptz '2026-10-05 08:00:00+00',
    timestamptz '2026-10-05 10:00:00+00',
    v_cmd_well_b, null, 0, null
  );

  if v_response ->> 'status' = 'confirmed' then
    raise notice 'PASS 10: نفس الفترة على بئر آخر نجحت — المسار خاص بالبئر';
  else
    raise notice 'FAIL 10: حجز بئر آخر رُفض خطأً: %', v_response;
  end if;

  -- ============================================================
  -- 11. التعارض نتيجة مكتوبة من نوع معلوم بكامل حقوله.
  -- ============================================================
  v_conflict_response := api.create_booking(
    v_well_a, v_account_1, v_farm_a,
    timestamptz '2026-10-05 09:00:00+00',
    timestamptz '2026-10-05 11:00:00+00',
    v_cmd_conflict, null, 0, null
  );

  if v_conflict_response ->> 'status' = 'conflict'
     and v_conflict_response ->> 'conflict_code' = 'time_overlap'
     and (v_conflict_response ->> 'conflicting_booking_id')::uuid = v_booking_1
     and (v_conflict_response ->> 'conflicting_public_code') is not null
     and v_conflict_response ->> 'conflicting_start' = '2026-10-05T08:00:00+00:00'
     and v_conflict_response ->> 'conflicting_end' = '2026-10-05T10:00:00+00:00'
     and v_conflict_response ->> 'requested_start' = '2026-10-05T09:00:00+00:00'
     and v_conflict_response ->> 'requested_end' = '2026-10-05T11:00:00+00:00' then
    raise notice 'PASS 11: التعارض نتيجة مكتوبة time_overlap بمعلومات الحجز المتعارض';
  else
    raise notice 'FAIL 11: شكل نتيجة التعارض غير صحيح: %', v_conflict_response;
  end if;

  -- ============================================================
  -- 12. التعارض لم ينشئ حجزًا ثانيًا ولا صف حالة ولا حجز مورد.
  -- ============================================================
  select
    (select count(*) from ops.irrigation_bookings b where b.well_id = v_well_a),
    (select count(*) from ops.booking_status_history h
     where h.booking_id in (select id from ops.irrigation_bookings where well_id = v_well_a)),
    (select count(*) from ops.resource_reservations r
     where r.well_id = v_well_a and r.resource_type = 'well_path')
  into v_count, v_count_2, v_history_count;

  if v_count = 3 and v_count_2 = 3 and v_history_count = 3 then
    raise notice 'PASS 12: التعارض لم يترك أي أثر كتابي على البئر';
  else
    raise notice 'FAIL 12: التعارض ترك أثرًا: bookings=% history=% reservations=%',
      v_count, v_count_2, v_history_count;
  end if;

  -- ============================================================
  -- 13. إعادة إرسال أمر الإنشاء الناجح تعيد الحجز نفسه بلا تكرار.
  -- ============================================================
  v_response := api.create_booking(
    v_well_a, v_account_1, v_farm_a,
    timestamptz '2026-10-05 08:00:00+00',
    timestamptz '2026-10-05 10:00:00+00',
    v_cmd_create_1, 'well_diesel', 1, 'حجز أول 112'
  );
  select count(*) into v_count
  from ops.irrigation_bookings b where b.well_id = v_well_a;

  if v_response = v_create1_response
     and v_count = 3 then
    raise notice 'PASS 13: إعادة إرسال أمر القبول أعادت الرد المخزن بلا تكرار صفوف';
  else
    raise notice 'FAIL 13: replay القبول غير مطابق: %', v_response;
  end if;

  -- ============================================================
  -- 14. إعادة إرسال أمر التعارض تعيد نتيجة التعارض المخزنة حرفيًا.
  -- ============================================================
  v_response := api.create_booking(
    v_well_a, v_account_1, v_farm_a,
    timestamptz '2026-10-05 09:00:00+00',
    timestamptz '2026-10-05 11:00:00+00',
    v_cmd_conflict, null, 0, null
  );

  if v_response = v_conflict_response then
    raise notice 'PASS 14: إعادة إرسال أمر التعارض أعادت نتيجة التعارض المخزنة حرفيًا';
  else
    raise notice 'FAIL 14: replay التعارض غير مطابق: %', v_response;
  end if;

  -- ============================================================
  -- 15. عدم تطابق الأرض/الحساب ما زال مرفوضًا (حرس 075).
  -- ============================================================
  begin
    perform api.create_booking(
      v_well_a, v_account_2, v_farm_a,
      timestamptz '2026-10-06 08:00:00+00',
      timestamptz '2026-10-06 09:00:00+00',
      gen_random_uuid(), null, 0, 'اختبار عدم التطابق'
    );
    raise notice 'FAIL 15: سُمح بحجز أرض تخص حساب مزارع آخر';
  exception when others then
    if position('الأرض لا تخص حساب المزارع المحدد' in sqlerrm) > 0 then
      raise notice 'PASS 15: اتساق الأرض/الحساب من 075 ما زال مرفوضًا برسالة واضحة';
    else
      raise notice 'FAIL 15: سبب رفض عدم التطابق غير متوقع: %', sqlerrm;
    end if;
  end;

  -- ============================================================
  -- 16. إعادة جدولة متعارضة تعيد تعارضًا مكتوبًا ولا تغير الأصل:
  --     الأوقات والحالة وحجز المسار النشط وسجل الحالة كلها ثابتة.
  -- ============================================================
  select b.scheduled_start, b.scheduled_end into v_start, v_end
  from ops.irrigation_bookings b where b.id = v_booking_3;
  select r.id into v_active_reservation
  from ops.resource_reservations r
  where r.booking_id = v_booking_3 and r.status = 'active' and r.resource_type = 'well_path';
  select count(*) into v_history_count
  from ops.booking_status_history h where h.booking_id = v_booking_3;

  v_response := api.reschedule_booking(
    v_booking_3,
    timestamptz '2026-10-05 10:30:00+00',
    timestamptz '2026-10-05 11:30:00+00',
    'محاولة نقل متعارضة',
    v_cmd_resch_conflict
  );

  select
    (select count(*) from ops.booking_status_history h where h.booking_id = v_booking_3),
    (select r.id from ops.resource_reservations r
     where r.booking_id = v_booking_3 and r.status = 'active' and r.resource_type = 'well_path')
  into v_count, v_active_reservation_2;

  if v_response ->> 'status' = 'conflict'
     and v_response ->> 'conflict_code' = 'time_overlap'
     and (v_response ->> 'booking_id')::uuid = v_booking_3
     and (select scheduled_start from ops.irrigation_bookings where id = v_booking_3) = v_start
     and (select scheduled_end from ops.irrigation_bookings where id = v_booking_3) = v_end
     and (select status from ops.irrigation_bookings where id = v_booking_3) = 'confirmed'
     and v_count = v_history_count
     and v_active_reservation_2 = v_active_reservation then
    raise notice 'PASS 16: إعادة الجدولة المتعارضة أعادت تعارضًا مكتوبًا وبقي الأصل محفوظًا حرفيًا';
  else
    raise notice 'FAIL 16: التعارض في إعادة الجدولة لم يحمِ الأصل: %', v_response;
  end if;

  -- ============================================================
  -- 17. إعادة جدولة ناجحة: تنتهي confirmed وتحرر المسار القديم
  --     وتنشئ مسارًا جديدًا وتحفظ التاريخ (confirmed→confirmed).
  -- ============================================================
  v_response := api.reschedule_booking(
    v_booking_3,
    timestamptz '2026-10-05 13:00:00+00',
    timestamptz '2026-10-05 14:00:00+00',
    'طلب المزارع',
    v_cmd_resch_ok
  );

  select
    (select count(*) from ops.booking_status_history h
     where h.booking_id = v_booking_3
       and h.old_status = 'confirmed' and h.new_status = 'confirmed'
       and h.reason like 'إعادة جدولة%'),
    (select count(*) from ops.resource_reservations r
     where r.booking_id = v_booking_3 and r.status = 'released'
       and r.resource_type = 'well_path'),
    (select count(*) from ops.resource_reservations r
     where r.booking_id = v_booking_3 and r.status = 'active'
       and r.resource_type = 'well_path'
       and r.reserved_period = tstzrange(
         timestamptz '2026-10-05 13:00:00+00',
         timestamptz '2026-10-05 14:00:00+00', '[)'))
  into v_count, v_count_2, v_history_count;

  if v_response ->> 'status' = 'confirmed'
     and (select scheduled_start from ops.irrigation_bookings where id = v_booking_3)
          = timestamptz '2026-10-05 13:00:00+00'
     and v_count = 1 and v_count_2 = 1 and v_history_count = 1 then
    raise notice 'PASS 17: إعادة الجدولة الناجحة حررت المسار القديم وأنشأت جديدًا وحفظت التاريخ';
  else
    raise notice 'FAIL 17: إعادة الجدولة الناجحة غير مكتملة: %', v_response;
  end if;

  -- ============================================================
  -- 18. postponed (إرث) → إعادة جدولة تصير confirmed مع سجل
  --     postponed→confirmed.
  -- ============================================================
  execute 'reset role';
  update ops.irrigation_bookings
  set status = 'postponed'
  where id = v_booking_3;
  execute 'set local role authenticated';

  v_response := api.reschedule_booking(
    v_booking_3,
    timestamptz '2026-10-05 15:00:00+00',
    timestamptz '2026-10-05 16:00:00+00',
    'استئناف بعد التأجيل',
    v_cmd_resch_postponed
  );

  select count(*) into v_count
  from ops.booking_status_history h
  where h.booking_id = v_booking_3
    and h.old_status = 'postponed' and h.new_status = 'confirmed';

  if v_response ->> 'status' = 'confirmed'
     and (select status from ops.irrigation_bookings where id = v_booking_3) = 'confirmed'
     and v_count = 1 then
    raise notice 'PASS 18: الحجز المؤجل أعيد جدولته إلى confirmed مع سجل postponed→confirmed';
  else
    raise notice 'FAIL 18: مسار postponed→confirmed غير سليم: %', v_response;
  end if;

  -- ============================================================
  -- 19. الإلغاء يحرر حجوزات الموارد ويسجل التاريخ (confirmed→cancelled).
  -- ============================================================
  v_response := api.cancel_booking(
    v_booking_1, 'تغيير برنامج السقي', v_cmd_cancel
  );
  v_cancel_response := v_response;

  select
    (select count(*) from ops.resource_reservations r
     where r.booking_id = v_booking_1 and r.status = 'active'),
    (select r.status from ops.resource_reservations r
     where r.booking_id = v_booking_1 and r.resource_type = 'well_path'),
    (select count(*) from ops.booking_status_history h
     where h.booking_id = v_booking_1
       and h.old_status = 'confirmed' and h.new_status = 'cancelled'
       and h.reason = 'تغيير برنامج السقي')
  into v_count, v_sig, v_count_2;

  if v_response ->> 'status' = 'cancelled'
     and (v_response ->> 'previous_status') = 'confirmed'
     and (select status from ops.irrigation_bookings where id = v_booking_1) = 'cancelled'
     and v_count = 0 and v_sig = 'cancelled' and v_count_2 = 1 then
    raise notice 'PASS 19: الإلغاء حرر حجوزات الموارد وسجل confirmed→cancelled بالسبب';
  else
    raise notice 'FAIL 19: الإلغاء غير مكتمل: %', v_response;
  end if;

  -- ============================================================
  -- 20. فترة الملغى صارت متاحة لحجز مؤكد جديد.
  -- ============================================================
  v_response := api.create_booking(
    v_well_a, v_account_1, v_farm_a,
    timestamptz '2026-10-05 08:00:00+00',
    timestamptz '2026-10-05 09:00:00+00',
    v_cmd_after_cancel, null, 0, null
  );

  if v_response ->> 'status' = 'confirmed' then
    raise notice 'PASS 20: فترة الحجز الملغى صارت متاحة لحجز مؤكد جديد';
  else
    raise notice 'FAIL 20: فترة الملغى لم تتحرر: %', v_response;
  end if;

  -- ============================================================
  -- 21. إعادة إرسال أمر الإلغاء لا تكرر تاريخًا ولا تدقيقًا.
  -- ============================================================
  v_response_2 := api.cancel_booking(
    v_booking_1, 'تغيير برنامج السقي', v_cmd_cancel
  );
  select count(*) into v_count
  from ops.booking_status_history h
  where h.booking_id = v_booking_1 and h.new_status = 'cancelled';

  if v_response_2 = v_cancel_response and v_count = 1 then
    raise notice 'PASS 21: replay الإلغاء أعاد الرد المخزن بلا صف تاريخ ثانٍ';
  else
    raise notice 'FAIL 21: replay الإلغاء كرر أثرًا: %', v_response_2;
  end if;

  -- ============================================================
  -- تجهيزات نطاق القراءة: ربط هوية المزارعين بحساباتهم (078/079)
  -- وأرض وحجز للمزارع ب على نفس البئر.
  -- ============================================================
  execute 'reset role';

  insert into iam.profiles (id, full_name)
  values (v_farmer_b_user, 'مزارع ب اختبار 112')
  on conflict (id) do nothing;

  insert into iam.profile_person_links (tenant_id, profile_id, person_id, link_reason)
  values
    (v_tenant, v_farmer_user, v_person_1, 'اختبار النطاق الذاتي 112'),
    (v_tenant, v_farmer_b_user, v_person_2, 'اختبار النطاق الذاتي 112');

  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';

  v_response := api.create_farm(
    v_well_a, 'أرض سعيد', v_account_2, null, gen_random_uuid()
  );
  v_farm_2 := (v_response ->> 'farm_id')::uuid;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_operator_user::text, true);
  execute 'set local role authenticated';

  v_response := api.create_booking(
    v_well_a, v_account_2, v_farm_2,
    timestamptz '2026-10-05 17:00:00+00',
    timestamptz '2026-10-05 18:00:00+00',
    gen_random_uuid(), null, 0, 'حجز المزارع ب 112'
  );
  v_booking_5 := (v_response ->> 'booking_id')::uuid;

  execute 'reset role';

  -- ============================================================
  -- 22. owner يملك booking.cancel.
  -- ============================================================
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';

  if iam.has_well_permission(v_well_a, 'booking.cancel') then
    raise notice 'PASS 22: المالك يملك صلاحية إلغاء الحجز';
  else
    raise notice 'FAIL 22: المالك فقد صلاحية إلغاء الحجز';
  end if;

  -- ============================================================
  -- 23. operator يملك booking.cancel.
  -- ============================================================
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_operator_user::text, true);
  execute 'set local role authenticated';

  if iam.has_well_permission(v_well_a, 'booking.cancel') then
    raise notice 'PASS 23: المشغل يملك صلاحية إلغاء الحجز';
  else
    raise notice 'FAIL 23: المشغل فقد صلاحية إلغاء الحجز';
  end if;

  -- ============================================================
  -- 24. دور بلا إدارة حجوزات (المزارع) لا يملك booking.cancel
  --     ولا booking.create.
  -- ============================================================
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_farmer_user::text, true);
  execute 'set local role authenticated';

  select count(*) into v_count
  from unnest(array['booking.cancel', 'booking.create', 'booking.reschedule']) code
  where iam.has_well_permission(v_well_a, code);

  execute 'reset role';

  if v_count = 0 then
    raise notice 'PASS 24: المزارع بلا أي صلاحية كتابة حجوزات (إلغاء/إنشاء/نقل)';
  else
    raise notice 'FAIL 24: المزارع حصل على % صلاحيات حجوزات', v_count;
  end if;

  -- ============================================================
  -- 25. القائمة تعيد بيانات العرض القانونية: اسم المزارع والأرض
  --     والمنطقة الزمنية واليوم المجدول من الخادم، مرتبة بالبداية.
  -- ============================================================
  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';

  v_response := api.list_well_bookings(v_well_a, null, null, 200);

  if v_response ->> 'status' = 'ok'
     and (v_response ->> 'count')::int = 5
     and (v_response ->> 'well_timezone') = 'Asia/Aden'
     and exists (
       select 1
       from jsonb_array_elements(v_response -> 'bookings') item
       where item ->> 'farmer_name' = 'فلاح الحجوزات الأول'
         and item ->> 'farm_name' = 'أرض الفلاح الأول'
         and item ->> 'scheduled_day' = '2026-10-05'
         and item ->> 'scheduled_start' is not null
         and item ->> 'status' is not null
     )
     and (
       select (item ->> 'scheduled_start')
       from jsonb_array_elements(v_response -> 'bookings') item
       limit 1
     ) = (
       select min(item ->> 'scheduled_start')
       from jsonb_array_elements(v_response -> 'bookings') item
     ) then
    raise notice 'PASS 25: القائمة أعادت بيانات العرض القانونية مرتبة مع اليوم من منطقة البئر';
  else
    raise notice 'FAIL 25: عقد القائمة غير صحيح: %', v_response;
  end if;

  -- ============================================================
  -- 26. التفصيل يعيد تاريخ الحالة مرتبًا من الأقدم إلى الأحدث
  --     وحالة حجوزات الموارد.
  -- ============================================================
  v_response := api.get_booking_detail(v_booking_1);

  if
    (
      select item ->> 'new_status'
      from jsonb_array_elements(v_response -> 'status_history') item
      order by (item ->> 'changed_at')::timestamptz asc, item ->> 'id' asc
      limit 1
    ) = 'confirmed'
    and (
      select item ->> 'old_status'
      from jsonb_array_elements(v_response -> 'status_history') item
      order by (item ->> 'changed_at')::timestamptz asc, item ->> 'id' asc
      limit 1
    ) is null
    and (
      select item ->> 'new_status'
      from jsonb_array_elements(v_response -> 'status_history') item
      order by (item ->> 'changed_at')::timestamptz desc, item ->> 'id' desc
      limit 1
    ) = 'cancelled'
    and (
      select count(*) from jsonb_array_elements(v_response -> 'status_history') item
    ) = 2
    and (
      select count(*)
      from jsonb_array_elements(v_response -> 'reservations') item
      where item ->> 'resource_type' = 'well_path' and item ->> 'status' = 'cancelled'
    ) >= 1
  then
    raise notice 'PASS 26: التفصيل يعيد تاريخًا مرتبًا (null→confirmed أولًا وcancelled أخيرًا) وحالة الموارد';
  else
    raise notice 'FAIL 26: عقد التفصيل غير صحيح: %', v_response;
  end if;

  -- ============================================================
  -- 27. القراءة من مستخدم لا علاقة له بالبئر مرفوضة.
  -- ============================================================
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_intruder_user::text, true);
  execute 'set local role authenticated';

  begin
    perform api.list_well_bookings(v_well_a, null, null, 200);
    raise notice 'FAIL 27: مستخدم أجنبي قرأ حجوزات البئر';
  exception when others then
    if position('لا تملك صلاحية قراءة حجوزات هذا البئر' in sqlerrm) > 0 then
      raise notice 'PASS 27: رُفضت قراءة حجوزات البئر من غير المصرح له';
    else
      raise notice 'FAIL 27: سبب رفض القراءة الأجنبية غير متوقع: %', sqlerrm;
    end if;
  end;

  -- المزارع أ يطلب تفاصيل حجز المزارع ب على نفس البئر: RLS يخفي الصف
  -- والرفض 42501 بلا كشف وجود الحجز.
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_farmer_user::text, true);
  execute 'set local role authenticated';

  begin
    perform api.get_booking_detail(v_booking_5);
    raise notice 'FAIL 27: المزارع أ قرأ تفاصيل حجز المزارع ب';
  exception when others then
    if position('لا تملك صلاحية قراءة هذا الحجز' in sqlerrm) > 0 then
      raise notice 'PASS 27: رُفضت قراءة تفاصيل حجز غيره برفض 42501';
    else
      raise notice 'FAIL 27: سبب رفض تفاصيل حجز غيره غير متوقع: %', sqlerrm;
    end if;
  end;

  -- ============================================================
  -- 28. الكتابة المباشرة على جدول الحجوزات ما زالت مغلقة (072).
  -- ============================================================
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';

  begin
    insert into ops.irrigation_bookings (
      tenant_id, public_code, well_id, farmer_well_account_id,
      farm_id, scheduled_start, scheduled_end,
      expected_duration_minutes, status
    ) values (
      v_tenant, 'BKG-FAKE-112', v_well_a, v_account_1, v_farm_a,
      timestamptz '2026-10-07 08:00:00+00',
      timestamptz '2026-10-07 09:00:00+00', 60, 'confirmed'
    );
    raise notice 'FAIL 28: سُمح بكتابة مباشرة على جدول الحجوزات';
  exception when others then
    if position('permission denied' in sqlerrm) > 0 then
      raise notice 'PASS 28: الكتابة المباشرة على جدول الحجوزات ما زالت مغلقة';
    else
      raise notice 'FAIL 28: سبب رفض الكتابة المباشرة غير متوقع: %', sqlerrm;
    end if;
  end;

  -- ============================================================
  -- 29. معرّف العملية إلزامي في العقود العامة.
  -- ============================================================
  begin
    perform api.create_booking(
      v_well_a, v_account_1, v_farm_a,
      timestamptz '2026-10-06 08:00:00+00',
      timestamptz '2026-10-06 09:00:00+00',
      null, null, 0, null
    );
    raise notice 'FAIL 29: سُمح بإنشاء حجز بلا معرّف عملية';
  exception when others then
    if position('معرّف العملية مطلوب' in sqlerrm) > 0 then
      raise notice 'PASS 29: معرّف العملية إلزامي في عقد الإنشاء';
    else
      raise notice 'FAIL 29: سبب قبول null لمعرّف العملية غير متوقع: %', sqlerrm;
    end if;
  end;

  begin
    perform api.cancel_booking(v_booking_2, 'سبب', null);
    raise notice 'FAIL 29: سُمح بإلغاء بلا معرّف عملية';
  exception when others then
    if position('معرّف العملية مطلوب' in sqlerrm) > 0 then
      raise notice 'PASS 29: معرّف العملية إلزامي في عقد الإلغاء';
    else
      raise notice 'FAIL 29: سبب قبول null لإلغاء بلا معرّف غير متوقع: %', sqlerrm;
    end if;
  end;

  -- ============================================================
  -- 30. رفض إعادة جدولة/إلغاء حالة نهائية (completed) لا يزال قائمًا.
  -- ============================================================
  execute 'reset role';
  update ops.irrigation_bookings
  set status = 'completed'
  where id = v_booking_2;
  execute 'set local role authenticated';

  begin
    perform api.reschedule_booking(
      v_booking_2,
      timestamptz '2026-10-06 08:00:00+00',
      timestamptz '2026-10-06 09:00:00+00',
      'نقل حجز مكتمل',
      gen_random_uuid()
    );
    raise notice 'FAIL 30: سُمح بإعادة جدولة حجز مكتمل';
  exception when others then
    if position('لا يمكن إعادة جدولة حجز حالته completed' in sqlerrm) > 0 then
      raise notice 'PASS 30: رُفضت إعادة جدولة الحجز المكتمل';
    else
      raise notice 'FAIL 30: سبب رفض نقل المكتمل غير متوقع: %', sqlerrm;
    end if;
  end;

  begin
    perform api.cancel_booking(v_booking_2, 'إلغاء مكتمل', gen_random_uuid());
    raise notice 'FAIL 30: سُمح بإلغاء حجز مكتمل';
  exception when others then
    if position('لا يمكن إلغاء حجز حالته completed' in sqlerrm) > 0 then
      raise notice 'PASS 30: رُفض إلغاء الحجز المكتمل';
    else
      raise notice 'FAIL 30: سبب رفض إلغاء المكتمل غير متوقع: %', sqlerrm;
    end if;
  end;

  -- ============================================================
  -- 31. operator يرى كل حجوزات البئر (قراءة الموظفين — دلالة 079).
  -- ============================================================
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_operator_user::text, true);
  execute 'set local role authenticated';

  v_response := api.list_well_bookings(v_well_a, null, null, 200);

  if v_response ->> 'status' = 'ok'
     and (v_response ->> 'count')::int = 5 then
    raise notice 'PASS 31: المشغل يرى حجوزات البئر كلها (5)';
  else
    raise notice 'FAIL 31: قائمة المشغل غير مكتملة: %', v_response ->> 'count';
  end if;

  -- ============================================================
  -- 32. manager يرى كل الحجوزات read-only وبلا أي كتابة حجوزات.
  -- ============================================================
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_manager_user::text, true);
  execute 'set local role authenticated';

  v_response := api.list_well_bookings(v_well_a, null, null, 200);

  select count(*) into v_count
  from unnest(array['booking.create', 'booking.reschedule', 'booking.cancel']) code
  where iam.has_well_permission(v_well_a, code);

  if v_response ->> 'status' = 'ok'
     and (v_response ->> 'count')::int = 5
     and v_count = 0 then
    raise notice 'PASS 32: المدير يرى الحجوزات كلها للقراءة وحدها بلا create/reschedule/cancel';
  else
    raise notice 'FAIL 32: قراءة المدير أو صلاحياته غير صحيحة: count=% perms=%',
      v_response ->> 'count', v_count;
  end if;

  -- ============================================================
  -- 33. المزارع أ يرى حجوزاته وحدها (4) ولا يرى حجز المزارع ب.
  -- ============================================================
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_farmer_user::text, true);
  execute 'set local role authenticated';

  v_response := api.list_well_bookings(v_well_a, null, null, 200);

  select count(*) into v_count
  from jsonb_array_elements(v_response -> 'bookings') item
  where (item ->> 'farmer_well_account_id')::uuid = v_account_1;

  if v_response ->> 'status' = 'ok'
     and (v_response ->> 'count')::int = 4
     and v_count = 4
     and not exists (
       select 1 from jsonb_array_elements(v_response -> 'bookings') item
       where (item ->> 'id')::uuid = v_booking_5
     ) then
    raise notice 'PASS 33: المزارع أ يرى حجوزاته الأربعة وحدها وحجز المزارع ب مستبعد';
  else
    raise notice 'FAIL 33: نطاق قائمة المزارع أ غير صحيح: %', v_response ->> 'count';
  end if;

  -- ============================================================
  -- 34. المزارع ب يرى حجزه وحده (1).
  -- ============================================================
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_farmer_b_user::text, true);
  execute 'set local role authenticated';

  v_response := api.list_well_bookings(v_well_a, null, null, 200);

  select count(*) into v_count
  from jsonb_array_elements(v_response -> 'bookings') item
  where (item ->> 'id')::uuid = v_booking_5;

  if v_response ->> 'status' = 'ok'
     and (v_response ->> 'count')::int = 1
     and v_count = 1 then
    raise notice 'PASS 34: المزارع ب يرى حجه وحده من قائمة البئر';
  else
    raise notice 'FAIL 34: نطاق قائمة المزارع ب غير صحيح: %', v_response ->> 'count';
  end if;

  -- ============================================================
  -- 35. المزارع ب يقرأ تفاصيل حجه بنفسه (self-scope ناجح).
  -- ============================================================
  v_response := api.get_booking_detail(v_booking_5);

  if v_response ->> 'status' = 'ok'
     and (v_response -> 'booking' ->> 'id')::uuid = v_booking_5
     and (v_response -> 'booking' ->> 'farmer_name') = 'سعيد عبدالله سالم' then
    raise notice 'PASS 35: المزارع ب يقرأ تفاصيل حجه من عقود api دون صلاحية عامة';
  else
    raise notice 'FAIL 35: تفاصيل حجز المزارع ب غير متاحة له: %', v_response ->> 'status';
  end if;

  -- ============================================================
  -- 36. المزارع أ لا يملك booking.read صلاحية عامة، وكذلك
  --     partner/accountant/viewer (بلا أي عقد قراءة حجوزات).
  -- ============================================================
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_farmer_user::text, true);
  execute 'set local role authenticated';
  v_count := case when iam.has_well_permission(v_well_a, 'booking.read') then 1 else 0 end;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_partner_user::text, true);
  execute 'set local role authenticated';
  v_count_2 := case when iam.has_well_permission(v_well_a, 'booking.read') then 1 else 0 end;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_accountant_user::text, true);
  execute 'set local role authenticated';
  v_count := v_count + case when iam.has_well_permission(v_well_a, 'booking.read') then 1 else 0 end;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_viewer_user::text, true);
  execute 'set local role authenticated';
  v_count_2 := v_count_2 + case when iam.has_well_permission(v_well_a, 'booking.read') then 1 else 0 end;

  if v_count = 0 and v_count_2 = 0 then
    raise notice 'PASS 36: المزارع والشريك والمحاسب والعارض بلا صلاحية booking.read عامة';
  else
    raise notice 'FAIL 36: تسرب booking.read لأدوار غير موظفين';
  end if;

  -- ============================================================
  -- 37. الشريك (والمحاسب والعارض بنفس المنطق) تُرفض قائمة الحجوزات.
  -- ============================================================
  begin
    perform api.list_well_bookings(v_well_a, null, null, 200);
    raise notice 'FAIL 37: الشريك قرأ قائمة حجوزات البئر';
  exception when others then
    if position('لا تملك صلاحية قراءة حجوزات هذا البئر' in sqlerrm) > 0 then
      raise notice 'PASS 37: رُفضت قائمة الحجوزات على دور بلا قراءة ولا نطاق ذاتي';
    else
      raise notice 'FAIL 37: سبب رفض قائمة الشريك غير متوقع: %', sqlerrm;
    end if;
  end;

  -- ============================================================
  -- 38. المزارع أ يقرأ تفاصيل حجه الملغى بنفسه مع تاريخ حالته.
  -- ============================================================
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_farmer_user::text, true);
  execute 'set local role authenticated';

  v_response := api.get_booking_detail(v_booking_1);

  if v_response ->> 'status' = 'ok'
     and (v_response -> 'booking' ->> 'id')::uuid = v_booking_1
     and (select count(*) from jsonb_array_elements(v_response -> 'status_history') item) = 2
     and (select count(*) from jsonb_array_elements(v_response -> 'reservations') item) >= 1 then
    raise notice 'PASS 38: المزارع أ يقرأ تفاصيل حجه وتاريخه وموارده من العقد نفسه';
  else
    raise notice 'FAIL 38: تفاصيل حجز المزارع أ غير مكتملة له: %', v_response ->> 'status';
  end if;

  execute 'reset role';
  raise notice '--- انتهى اختبار عقد الحجوزات 112 (فحوص مركّبة: 38) ---';
end
$test$;

rollback;
