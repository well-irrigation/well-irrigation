-- اختبار 093 — قراءة التسعيرة لمن يشغّل البئر (م-41D7)
--
-- يثبّت: وجود صلاحية price.read ومنحها لثلاثة أدوار بلا توسيع صامت،
-- خصائص أمان القارئ الداخلي وACL، بقاء عقد api على INVOKER، ثم
-- السلوك الفعلي: المشغل يرى السعر نفسه الذي يراه المالك، ولا يكتب،
-- ولا تُفتح له الجداول مباشرة، وغياب الجدول يبقى غيابًا مصرَّحًا.

\set ON_ERROR_STOP on

begin;

do $test$
declare
  v_reader oid := to_regprocedure(
    'ops.read_active_price_schedule(uuid, timestamptz)'
  );
  v_contract oid := to_regprocedure(
    'api.get_active_price_schedule(uuid, timestamptz)'
  );
  v_owner_user uuid;
  v_op_user uuid;
  v_owner_profile uuid;
  v_op_profile uuid;
  v_tenant uuid;
  v_well uuid;
  v_bare_well uuid;
  v_other_well uuid;
  v_owner_payload jsonb;
  v_payload jsonb;
  v_rule jsonb;
  v_src text;
  v_count integer;
  v_count_2 integer;
  v_code text;
  v_denied boolean;
begin

  -- ---------------------------------------------------------------
  -- 1. الصلاحية الجديدة موجودة في الكتالوج
  -- ---------------------------------------------------------------

  select count(*)
  into v_count
  from iam.permissions p
  where p.code = 'price.read';

  if v_count = 1 then
    raise notice 'PASS 1: صلاحية price.read موجودة في الكتالوج';
  else
    raise notice 'FAIL 1: price.read غير موجودة';
  end if;

  -- ---------------------------------------------------------------
  -- 2. المنح لمن يشغّل البئر وحدهم: بلا توسيع صامت
  -- ---------------------------------------------------------------

  select
    count(*) filter (
      where r.code in ('tenant_owner', 'well_manager', 'operator')
    ),
    count(*) filter (
      where r.code not in ('tenant_owner', 'well_manager', 'operator')
    )
  into v_count, v_count_2
  from iam.role_permissions rp
  join iam.permissions p on p.id = rp.permission_id
  join iam.roles r on r.id = rp.role_id
  where p.code = 'price.read';

  if v_count = 3 and v_count_2 = 0 then
    raise notice 'PASS 2: price.read لثلاثة أدوار فقط: مالك ومدير ومشغل';
  else
    raise notice 'FAIL 2: منح price.read غير مطابق (% داخل، % خارج)',
      v_count, v_count_2;
  end if;


  -- ---------------------------------------------------------------
  -- 3. أرقام الكتالوج بعد 093: 42 صلاحية و78 منحًا
  -- ---------------------------------------------------------------

  select count(*) into v_count from iam.permissions;

  select count(*) into v_count_2 from iam.role_permissions;

  if v_count = 42 and v_count_2 = 78 then
    raise notice 'PASS 3: الكتالوج 42 صلاحية وiam.role_permissions 78 منحًا';
  else
    raise notice 'FAIL 3: أرقام السلطة غير متوقعة (% صلاحية، % منحًا)',
      v_count, v_count_2;
  end if;


  -- ---------------------------------------------------------------
  -- 4. القارئ الداخلي: DEFINER وSTABLE وsearch_path مثبت
  -- ---------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  where p.oid = v_reader
    and p.prosecdef
    and p.provolatile = 's'
    and p.proconfig @> array['search_path=pg_catalog, pg_temp'];

  if v_count = 1 then
    raise notice 'PASS 4: القارئ الداخلي DEFINER وSTABLE بـsearch_path مثبت';
  else
    raise notice 'FAIL 4: خاصية أمان مفقودة في ops.read_active_price_schedule';
  end if;


  -- ---------------------------------------------------------------
  -- 5. عقد api يبقى INVOKER وSTABLE — وACL الطرفين مطابق ق-78
  -- ---------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  where p.oid = v_contract
    and p.prosecdef = false
    and p.provolatile = 's'
    and p.proconfig @> array['search_path=pg_catalog, pg_temp'];

  if v_count = 1
     and has_function_privilege('authenticated', v_contract, 'EXECUTE')
     and has_function_privilege('service_role', v_contract, 'EXECUTE')
     and not has_function_privilege('anon', v_contract, 'EXECUTE')
     and has_function_privilege('authenticated', v_reader, 'EXECUTE')
     and has_function_privilege('service_role', v_reader, 'EXECUTE')
     and not has_function_privilege('anon', v_reader, 'EXECUTE')
  then
    raise notice 'PASS 5: العقد INVOKER وACL الطرفين يحجب anon';
  else
    raise notice 'FAIL 5: خاصية أمان أو ACL غير مطابق على طرفي القراءة';
  end if;


  -- ---------------------------------------------------------------
  -- 6. السلطة انتقلت فعليًا: price.read في القارئ، ولا price.manage
  --    في عقد القراءة، ولا قراءة جداول الأسعار من داخل api
  -- ---------------------------------------------------------------

  v_src := pg_get_functiondef(v_contract);

  if pg_get_functiondef(v_reader) like '%price.read%'
     and v_src not like '%price.manage%'
     and v_src not like '%ops.price_schedules%'
     and v_src like '%ops.read_active_price_schedule%'
  then
    raise notice 'PASS 6: سلطة القراءة price.read داخل القارئ وحده';
  else
    raise notice 'FAIL 6: توزيع السلطة بين الغلاف والقارئ غير مطابق';
  end if;

  -- ---------------------------------------------------------------
  -- 7. بيانات اختبار: مالك ومشغل، وثلاثة آبار بأحوال تعيين مختلفة
  -- ---------------------------------------------------------------

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at
  ) values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'price-read-owner-093@test.local',
    crypt('x', gen_salt('bf')),
    now(), now(), now()
  ) returning id into v_owner_user;

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at
  ) values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'price-read-operator-093@test.local',
    crypt('x', gen_salt('bf')),
    now(), now(), now()
  ) returning id into v_op_user;

  select id into v_owner_profile from iam.profiles where id = v_owner_user;
  select id into v_op_profile from iam.profiles where id = v_op_user;

  if v_owner_profile is null or v_op_profile is null then
    raise exception '093: لم يُنشأ iam.profiles للمستخدمين التجريبيين';
  end if;

  insert into core.tenants (name)
  values ('جهة تسعير 093')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name, location)
  values (v_tenant, 'بئر مُسعَّر 093', 'موقع 093')
  returning id into v_well;

  insert into core.wells (tenant_id, name, location)
  values (v_tenant, 'بئر بلا تسعيرة 093', 'موقع 093-ب')
  returning id into v_bare_well;

  insert into core.wells (tenant_id, name, location)
  values (v_tenant, 'بئر غير مُعيَّن 093', 'موقع 093-ج')
  returning id into v_other_well;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values
    (v_well, v_owner_profile, 'owner', 'active'),
    (v_well, v_op_profile, 'operator', 'active'),
    (v_bare_well, v_op_profile, 'operator', 'active');


  -- ---------------------------------------------------------------
  -- 8. المالك يُنشئ جدولًا ويقرأه: ثلاث قواعد وسعر شمسي حقيقي
  -- ---------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';

  perform api.create_price_schedule(
    v_well,
    'تسعيرة 093',
    now() - interval '1 day',
    'اختبار قراءة المشغل',
    4200::bigint,
    6100::bigint,
    7300::bigint
  );

  v_owner_payload := api.get_active_price_schedule(v_well);

  select x.item
  into v_rule
  from jsonb_array_elements(v_owner_payload -> 'rules') as x(item)
  where x.item ->> 'energy_source' = 'solar';

  if v_owner_payload ->> 'contract' = 'get_active_price_schedule'
     and (v_owner_payload -> 'schedule' -> 'id') is not null
     and jsonb_array_length(v_owner_payload -> 'rules') = 3
     and (v_rule ->> 'hourly_rate_minor')::bigint = 4200
  then
    raise notice 'PASS 7: المالك يقرأ الجدول الساري بقواعده الثلاث';
  else
    raise notice 'FAIL 7: قراءة المالك غير مطابقة للجدول المُنشأ';
  end if;


  -- ---------------------------------------------------------------
  -- 9. المشغل يرى ما يراه المالك حرفيًا — لا رفض ولا غياب كاذب
  -- ---------------------------------------------------------------

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_op_user::text, true);
  execute 'set local role authenticated';

  v_payload := api.get_active_price_schedule(v_well);

  if v_payload = v_owner_payload then
    raise notice 'PASS 8: المشغل يقرأ التسعيرة نفسها التي يقرأها المالك';
  else
    raise notice 'FAIL 8: قراءة المشغل تختلف عن قراءة المالك';
  end if;

  select x.item
  into v_rule
  from jsonb_array_elements(v_payload -> 'rules') as x(item)
  where x.item ->> 'energy_source' = 'well_diesel';

  if (v_rule ->> 'hourly_rate_minor')::bigint = 6100
     and (v_rule ->> 'diesel_pricing_model') = 'inclusive_hourly'
  then
    raise notice 'PASS 9: سعر الساعة يصل إلى شاشة المشغل بقيمته الحقيقية';
  else
    raise notice 'FAIL 9: سعر الساعة لا يصل إلى المشغل كما هو';
  end if;

  -- ---------------------------------------------------------------
  -- 10. الجداول نفسها تبقى مغلقة: RLS هجرة 031 لم تُخفَّف
  -- ---------------------------------------------------------------

  select count(*)
  into v_count
  from ops.price_schedules ps
  where ps.well_id = v_well;

  select count(*)
  into v_count_2
  from ops.price_rules pr
  join ops.price_schedules ps on ps.id = pr.price_schedule_id
  where ps.well_id = v_well;

  if v_count = 0 and v_count_2 = 0 then
    raise notice 'PASS 10: المشغل لا يرى الجداول مباشرة — الاطلاع بالعقد وحده';
  else
    raise notice 'FAIL 10: RLS الأسعار انفتحت للمشغل (% جدول، % قاعدة)',
      v_count, v_count_2;
  end if;


  -- ---------------------------------------------------------------
  -- 11. القراءة لا تعني الكتابة: price.manage تبقى للمالك
  -- ---------------------------------------------------------------

  v_code := null;
  begin
    perform api.create_price_schedule(
      v_well,
      'محاولة مشغل 093',
      now() + interval '1 day',
      null,
      9000::bigint,
      null,
      null
    );
  exception
    when others then
      v_code := sqlstate;
  end;

  if v_code = '42501' then
    raise notice 'PASS 11: المشغل يقرأ التسعيرة ولا يعدّلها';
  else
    raise notice 'FAIL 11: كتابة التسعير لم تُرفض للمشغل (%)', v_code;
  end if;


  -- ---------------------------------------------------------------
  -- 12. غياب جدول ساري يبقى غيابًا مصرَّحًا لا خطأ ولا رقمًا ملفَّقًا
  -- ---------------------------------------------------------------

  v_payload := api.get_active_price_schedule(v_bare_well);

  if v_payload -> 'schedule' = 'null'::jsonb
     and v_payload -> 'rules' = '[]'::jsonb
     and (v_payload ->> 'version')::integer = 1
  then
    raise notice 'PASS 12: بئر بلا تسعيرة يُعيد schedule = null بلا خطأ';
  else
    raise notice 'FAIL 12: حالة غياب التسعيرة غير مطابقة للعقد';
  end if;


  -- ---------------------------------------------------------------
  -- 13. الرفض المغلق: بئر بلا تعيين 42501، ومعرّف فارغ 22023
  -- ---------------------------------------------------------------

  v_code := null;
  begin
    perform api.get_active_price_schedule(v_other_well);
  exception
    when others then
      v_code := sqlstate;
  end;

  if v_code = '42501' then
    raise notice 'PASS 13: بئر بلا تعيين يُرفض بـ42501 لا بجدول فارغ';
  else
    raise notice 'FAIL 13: بئر بلا تعيين لم يُرفض كما يجب (%)', v_code;
  end if;

  v_code := null;
  begin
    perform api.get_active_price_schedule(null::uuid);
  exception
    when others then
      v_code := sqlstate;
  end;

  if v_code = '22023' then
    raise notice 'PASS 14: معرّف بئر فارغ يُرفض بـ22023';
  else
    raise notice 'FAIL 14: معرّف فارغ لم يُرفض بـ22023 (%)', v_code;
  end if;


  -- ---------------------------------------------------------------
  -- 14. anon محجوب وقت التنفيذ على طرفي القراءة معًا
  -- ---------------------------------------------------------------

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role anon';

  v_denied := false;
  begin
    perform api.get_active_price_schedule(v_well);
  exception
    when insufficient_privilege then
      v_denied := true;
  end;

  v_count := 0;
  begin
    perform ops.read_active_price_schedule(v_well, now());
  exception
    when insufficient_privilege then
      v_count := 1;
  end;

  execute 'reset role';

  if v_denied and v_count = 1 then
    raise notice 'PASS 15: anon لا ينفّذ العقد ولا القارئ الداخلي';
  else
    raise notice 'FAIL 15: anon نفّذ أحد طرفي قراءة التسعيرة';
  end if;

end;
$test$;

rollback;
