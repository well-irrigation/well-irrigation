-- اختبار 099 — دليل المزارعين: الترتيب بآخر سقي، والحمولة، والحدود
--
-- يمتحن ما لم يكن ممكنًا قبله: أن ترتيب القائمة **من الخادم** بآخر جلسة
-- منتهية، ومن لم يسقِ قطّ في آخر القائمة لا في أولها. وأن الحمولة تحمل عدد
-- الأراضي والأرصدة وآخر سقي — فلا يشتقّ العميل شيئًا (ق-99).
--
-- ويثبّت اتساقه مع 098: آخر سقي = آخر **نهاية** جلسة (ق-27)، والجلسة الجارية
-- لا تُعدّ نهايةً (ق-37) لكن حضورها معلَن في حقله. واليوم المحلي بمنطقة الجهة.

\set ON_ERROR_STOP on

begin;

do $test$
declare
  v_owner uuid;
  v_other uuid;
  v_tenant uuid;
  v_well uuid;
  v_pump uuid;
  v_farm_a uuid;
  v_farm_b uuid;
  v_farm_open uuid;
  v_acc_recent uuid;   -- سقى أمس
  v_acc_older uuid;    -- سقى قبل أسبوع، وعليه دين
  v_acc_never uuid;    -- لم يسقِ قطّ
  v_acc_open uuid;     -- جلسته جارية لم تنتهِ
  v_person uuid;
  v_profile uuid;
  v_session uuid;
  v_invoice uuid;
  v_payload jsonb;
  v_payload_2 jsonb;
  v_items jsonb;
  v_item jsonb;
  v_day_bounds tstzrange;
  v_count integer;
  v_api oid := to_regprocedure(
    'api.list_well_farmer_directory(uuid, text, integer)'
  );
begin

  -- ---------------------------------------------------------------
  -- 1. خصائص العقد: INVOKER بمسار مثبت، وanon محجوب
  -- ---------------------------------------------------------------

  select count(*) into v_count
  from pg_proc p
  where p.oid = v_api
    and p.prosecdef is false
    and p.proconfig @> array['search_path=pg_catalog, pg_temp'];

  if v_api is not null and v_count = 1
     and not has_function_privilege('anon', v_api, 'EXECUTE')
     and has_function_privilege('authenticated', v_api, 'EXECUTE')
  then
    raise notice 'PASS 1: عقد INVOKER بمسار مثبت وanon محجوب';
  else
    raise notice 'FAIL 1: خصائص العقد أو المنح غير مطابقة';
  end if;

  -- لا صلاحية جديدة في الكتالوج: الحمولة من مصادر يراها من يرى البئر.
  select count(*) into v_count
  from iam.permissions p
  where p.code like '%directory%';

  if v_count = 0 then
    raise notice 'PASS 2: لا صلاحية جديدة للدليل في الكتالوج';
  else
    raise notice 'FAIL 2: أُضيفت % صلاحية بلا حاجة', v_count;
  end if;

  -- ---------------------------------------------------------------
  -- تجهيز: بئر وأربعة مزارعين بحالات سقي مختلفة
  -- ---------------------------------------------------------------

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'dir-owner-099@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now(),
    jsonb_build_object('full_name', 'مالك 099', 'phone', '770000099')
  ) returning id into v_owner;

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'dir-other-099@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now(),
    jsonb_build_object('full_name', 'غريب 099', 'phone', '771000099')
  ) returning id into v_other;

  insert into core.tenants (name)
  values ('جهة الدليل 099')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name, location)
  values (v_tenant, 'بئر 099', 'موقع 099')
  returning id into v_well;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_well, v_owner, 'owner', 'active');

  insert into core.pumps (well_id, name, status, pump_type, power_rating)
  values (v_well, 'مضخة 099', 'active', 'submersible', '30 HP')
  returning id into v_pump;

  -- أربعة مزارعين. الأسماء مرتّبة أبجديًّا **عكس** ترتيب آخر السقي المتوقَّع،
  -- فلو بقي الترتيب أبجديًّا لظهر الفرق فورًا.
  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'أحمد القديم', 'أحمد القديم')
  returning id into v_person;
  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person) returning id into v_profile;
  insert into ops.farmer_well_accounts (
    tenant_id, farmer_profile_id, well_id, public_code
  ) values (v_tenant, v_profile, v_well, 'FWA-099-OLD')
  returning id into v_acc_older;

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'بشير الحديث', 'بشير الحديث')
  returning id into v_person;
  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person) returning id into v_profile;
  insert into ops.farmer_well_accounts (
    tenant_id, farmer_profile_id, well_id, public_code
  ) values (v_tenant, v_profile, v_well, 'FWA-099-NEW')
  returning id into v_acc_recent;

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'جميل الجاري', 'جميل الجاري')
  returning id into v_person;
  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person) returning id into v_profile;
  insert into ops.farmer_well_accounts (
    tenant_id, farmer_profile_id, well_id, public_code
  ) values (v_tenant, v_profile, v_well, 'FWA-099-OPEN')
  returning id into v_acc_open;

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'خالد بلا سقي', 'خالد بلا سقي')
  returning id into v_person;
  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person) returning id into v_profile;
  insert into ops.farmer_well_accounts (
    tenant_id, farmer_profile_id, well_id, public_code
  ) values (v_tenant, v_profile, v_well, 'FWA-099-NONE')
  returning id into v_acc_never;

  -- أرضان لصاحب الجلسة الحديثة، وواحدة للقديم، وواحدة لصاحب الجلسة الجارية،
  -- وصفر للرابع. **ولكل جلسة أرضُ صاحبها:** حرسٌ في القاعدة يرفض جلسةً على
  -- أرض لا تخصّ حساب المزارع المحدَّد («الأرض لا تخص حساب المزارع المحدد») —
  -- وهو حرس صحيح كشف خطأ التجهيز في أول تشغيل.
  insert into ops.farms (well_id, name, farmer_well_account_id, status)
  values (v_well, 'أرض ب-1', v_acc_recent, 'active')
  returning id into v_farm_a;
  insert into ops.farms (well_id, name, farmer_well_account_id, status)
  values (v_well, 'أرض ب-2', v_acc_recent, 'active');
  insert into ops.farms (well_id, name, farmer_well_account_id, status)
  values (v_well, 'أرض أ-1', v_acc_older, 'active')
  returning id into v_farm_b;
  insert into ops.farms (well_id, name, farmer_well_account_id, status)
  values (v_well, 'أرض ج-1', v_acc_open, 'active')
  returning id into v_farm_open;

  -- جلسات: القديم قبل أسبوع، والحديث أمس، والجاري بلا نهاية، والرابع لا شيء.
  insert into ops.irrigation_sessions (
    well_id, pump_id, farm_id, farmer_well_account_id,
    operator_profile_id, started_at, ended_at, status
  ) values (
    v_well, v_pump, v_farm_b, v_acc_older, v_owner,
    now() - interval '7 days', now() - interval '7 days' + interval '2 hours',
    'closed'
  ) returning id into v_session;

  insert into ops.irrigation_sessions (
    well_id, pump_id, farm_id, farmer_well_account_id,
    operator_profile_id, started_at, ended_at, status
  ) values (
    v_well, v_pump, v_farm_a, v_acc_recent, v_owner,
    now() - interval '1 day', now() - interval '1 day' + interval '1 hour',
    'closed'
  );

  insert into ops.irrigation_sessions (
    well_id, pump_id, farm_id, farmer_well_account_id,
    operator_profile_id, started_at, ended_at, status
  ) values (
    v_well, v_pump, v_farm_open, v_acc_open, v_owner,
    now() - interval '2 hours', null, 'open'
  );

  -- دين على القديم: فاتورة مُصدَرة غير مسددة. الحالة `issued` من القيم
  -- المسموحة، والعرض يعدّ كل ما ليس `cancelled`/`reversed`.
  insert into billing.invoices (
    tenant_id, public_code, well_id, farmer_well_account_id,
    session_id, invoice_date, status, subtotal_minor,
    total_minor, paid_minor, outstanding_minor
  ) values (
    v_tenant, 'INV-099', v_well, v_acc_older, v_session,
    now() - interval '7 days', 'issued', 90000, 90000, 0, 90000
  ) returning id into v_invoice;

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';

  -- ---------------------------------------------------------------
  -- 3. الترتيب: آخر سقي أولًا، ومن لم يسقِ في الآخر
  -- ---------------------------------------------------------------
  begin
    v_payload := api.list_well_farmer_directory(v_well, null, 200);
    v_items := v_payload -> 'items';

    if jsonb_array_length(v_items) = 4
       and (v_items -> 0 ->> 'id') = v_acc_recent::text
       and (v_items -> 1 ->> 'id') = v_acc_older::text
       and (v_items -> 3 ->> 'id') = v_acc_never::text
    then
      raise notice 'PASS 3: الحديث أولًا، ثم القديم، ومن لا سقي له آخرًا';
    else
      raise notice 'FAIL 3: ترتيب غير متوقَّع — %',
        (select jsonb_agg(i ->> 'full_name') from jsonb_array_elements(v_items) i)::text;
    end if;
  exception when others then
    raise notice 'FAIL 3: قراءة الدليل رُفضت — %', sqlerrm;
  end;

  -- ---------------------------------------------------------------
  -- 4. الترتيب ليس أبجديًّا — الأسماء مرتّبة عكس ترتيب السقي بقصد
  -- ---------------------------------------------------------------
  begin
    v_items := api.list_well_farmer_directory(v_well, null, 200) -> 'items';

    if (v_items -> 0 ->> 'full_name') <> 'أحمد القديم' then
      raise notice 'PASS 4: القائمة لم تعد أبجدية — الترتيب بآخر سقي';
    else
      raise notice 'FAIL 4: أول عنصر أبجدي، فالترتيب لم يتغيّر';
    end if;
  exception when others then
    raise notice 'FAIL 4: تحقق الترتيب تعذّر — %', sqlerrm;
  end;

  -- ---------------------------------------------------------------
  -- 5. عدد الأراضي حقيقي لكل مزارع — لا رقم مُجمَّع ولا صفر افتراضي
  -- ---------------------------------------------------------------
  begin
    v_items := api.list_well_farmer_directory(v_well, null, 200) -> 'items';

    select count(*) into v_count
    from jsonb_array_elements(v_items) i
    where (i ->> 'id') = v_acc_recent::text
      and (i ->> 'farms_count')::int = 2;

    v_item := (
      select i from jsonb_array_elements(v_items) i
      where (i ->> 'id') = v_acc_never::text
    );

    if v_count = 1 and (v_item ->> 'farms_count')::int = 0 then
      raise notice 'PASS 5: أرضان لصاحبهما وصفر لمن لا أرض له';
    else
      raise notice 'FAIL 5: عدد الأراضي غير مطابق — %', v_items::text;
    end if;
  exception when others then
    raise notice 'FAIL 5: قراءة عدد الأراضي تعذّرت — %', sqlerrm;
  end;

  -- ---------------------------------------------------------------
  -- 6. الدين من عرض الأرصدة كما هو — بلا حساب في العقد
  -- ---------------------------------------------------------------
  begin
    v_items := api.list_well_farmer_directory(v_well, null, 200) -> 'items';

    v_item := (
      select i from jsonb_array_elements(v_items) i
      where (i ->> 'id') = v_acc_older::text
    );

    if (v_item ->> 'debt_minor')::bigint = 90000
       and (v_item ->> 'invoiced_minor')::bigint = 90000
       and (v_item ->> 'advance_minor')::bigint = 0
    then
      raise notice 'PASS 6: الدين 90000 مقروءًا من عرض الأرصدة';
    else
      raise notice 'FAIL 6: أرقام الدين غير مطابقة — %', v_item::text;
    end if;
  exception when others then
    raise notice 'FAIL 6: قراءة الدين تعذّرت — %', sqlerrm;
  end;

  -- ---------------------------------------------------------------
  -- 7. ق-37: الجلسة الجارية لا تُعدّ «آخر سقي» — وحضورها معلَن
  -- ---------------------------------------------------------------
  begin
    v_items := api.list_well_farmer_directory(v_well, null, 200) -> 'items';

    v_item := (
      select i from jsonb_array_elements(v_items) i
      where (i ->> 'id') = v_acc_open::text
    );

    if (v_item ->> 'last_session_at') is null
       and (v_item ->> 'has_open_session')::boolean is true
       and (v_item ->> 'sessions_count')::int = 0
    then
      raise notice 'PASS 7: الجارية بلا تاريخ نهاية، وحضورها معلَن صريحًا';
    else
      raise notice 'FAIL 7: الجلسة الجارية عُدّت آخر سقي — %', v_item::text;
    end if;
  exception when others then
    raise notice 'FAIL 7: تحقق الجلسة الجارية تعذّر — %', sqlerrm;
  end;

  -- ---------------------------------------------------------------
  -- 8. اليوم المحلي بمنطقة الجهة، والمغلَّف يُعلن أساسه
  -- ---------------------------------------------------------------
  begin
    v_payload := api.list_well_farmer_directory(v_well, null, 200);
    v_item := (
      select i from jsonb_array_elements(v_payload -> 'items') i
      where (i ->> 'id') = v_acc_recent::text
    );

    v_day_bounds := core.period_bounds(v_well, 'today');

    if v_payload ->> 'contract' = 'list_well_farmer_directory'
       and (v_payload ->> 'version')::int = 1
       and v_payload ->> 'timezone' = 'Asia/Aden'
       and (v_payload ->> 'current_day')::date
           = (lower(v_day_bounds) at time zone 'Asia/Aden')::date
       and (lower(v_day_bounds) at time zone 'Asia/Aden')::time
           = time '00:00:00'
       and upper(v_day_bounds) - lower(v_day_bounds) = interval '1 day'
       and v_payload ->> 'session_day_basis' = 'ended_at'
       and (v_payload ->> 'sort') is not null
       and (v_item ->> 'last_session_day')::date
           = ((v_item ->> 'last_session_at')::timestamptz
              at time zone 'Asia/Aden')::date
    then
      raise notice 'PASS 8: المغلَّف يعلن أساسه واليوم بمنطقة الجهة';
    else
      raise notice 'FAIL 8: مغلَّف أو يوم غير متوقَّع — %',
        (v_payload - 'items')::text;
    end if;
  exception when others then
    raise notice 'FAIL 8: قراءة المغلَّف تعذّرت — %', sqlerrm;
  end;

  -- ---------------------------------------------------------------
  -- 9. يوم البئر لا يتغيّر بتغيير منطقة جلسة قاعدة البيانات
  -- ---------------------------------------------------------------
  begin
    execute 'set local timezone to ''UTC''';
    v_payload := api.list_well_farmer_directory(v_well, null, 200);
    execute 'set local timezone to ''America/New_York''';
    v_payload_2 := api.list_well_farmer_directory(v_well, null, 200);
    execute 'reset timezone';

    if v_payload ->> 'current_day' = v_payload_2 ->> 'current_day'
       and v_payload ->> 'timezone' = v_payload_2 ->> 'timezone'
    then
      raise notice 'PASS 9: يوم البئر ثابت مهما كانت منطقة جلسة القاعدة';
    else
      raise notice 'FAIL 9: يوم البئر تغيّر: % مقابل %',
        v_payload ->> 'current_day', v_payload_2 ->> 'current_day';
    end if;
  exception when others then
    execute 'reset timezone';
    raise notice 'FAIL 9: مقارنة يوم البئر تعذّرت — %', sqlerrm;
  end;

  -- ---------------------------------------------------------------
  -- 10. البحث يصفّي بالاسم وبالكود وبالهاتف
  -- ---------------------------------------------------------------
  begin
    v_items := api.list_well_farmer_directory(v_well, 'بشير', 200) -> 'items';
    select jsonb_array_length(v_items) into v_count;

    if v_count = 1 and (v_items -> 0 ->> 'id') = v_acc_recent::text then
      raise notice 'PASS 10: البحث بالاسم يعيد المطابق وحده';
    else
      raise notice 'FAIL 10: نتيجة البحث % عنصرًا', v_count;
    end if;
  exception when others then
    raise notice 'FAIL 10: البحث رُفض — %', sqlerrm;
  end;

  -- ---------------------------------------------------------------
  -- 11. من لا صلاحية له: رفض صريح لا قائمة فارغة
  -- ---------------------------------------------------------------
  begin
    execute 'reset role';
    perform set_config('request.jwt.claim.sub', v_other::text, true);
    execute 'set local role authenticated';

    perform api.list_well_farmer_directory(v_well, null, 200);
      raise notice 'FAIL 11: غريبٌ عن البئر قرأ الدليل';
  exception when insufficient_privilege then
      raise notice 'PASS 11: من لا صلاحية له مرفوض صريحًا';
  when others then
    if sqlstate = '42501' then
        raise notice 'PASS 11: من لا صلاحية له مرفوض صريحًا';
    else
        raise notice 'FAIL 11: رفض بسبب غير متوقَّع — % / %', sqlstate, sqlerrm;
    end if;
  end;

  -- ---------------------------------------------------------------
  -- 12. غير المصدَّق مرفوض كذلك
  -- ---------------------------------------------------------------
  begin
    execute 'reset role';
    perform set_config('request.jwt.claim.sub', '', true);
    execute 'set local role anon';

    perform api.list_well_farmer_directory(v_well, null, 200);
    raise notice 'FAIL 12: غير المصدَّق قرأ الدليل';
  exception when insufficient_privilege then
    raise notice 'PASS 12: غير المصدَّق مرفوض على الدليل';
  when others then
    if sqlstate = '42501' then
      raise notice 'PASS 12: غير المصدَّق مرفوض — %', sqlerrm;
    else
      raise notice 'FAIL 12: رفض بسبب غير متوقَّع — % / %',
        sqlstate, sqlerrm;
    end if;
  end;

  execute 'reset role';

end;
$test$;

rollback;
