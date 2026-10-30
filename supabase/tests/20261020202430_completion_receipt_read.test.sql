-- ق-137: بيانات اختبار محلية مباشرة؛ لا استدعاء لأي عقد إكمال.
begin;
set local timezone to 'UTC';
set local row_security = on;

create function pg_temp.receipt_check(ok boolean, label text)
returns void language plpgsql as $$
begin
  if ok is distinct from true then raise exception 'FAIL %', label; end if;
  raise notice 'PASS %', label;
end $$;

create function pg_temp.read_receipt(w uuid, s uuid, c uuid,
  t text default 'complete_irrigation_session')
returns jsonb language plpgsql as $$
declare result jsonb;
begin
  execute 'set local role authenticated';
  result := api.get_completion_receipt(w, s, c, t);
  if result->'retry_authorized' is distinct from 'false'::jsonb then
    raise exception 'FAIL reading a receipt must never authorize retry';
  end if;
  execute 'reset role';
  return result;
exception when others then
  execute 'reset role';
  raise;
end $$;

create function pg_temp.receipt_denied(w uuid, s uuid, c uuid)
returns boolean language plpgsql as $$
begin
  perform pg_temp.read_receipt(w, s, c);
  return false;
exception when insufficient_privilege or invalid_authorization_specification then
  return true;
end $$;

-- مقارنة القيم الكاملة، لا عدد الصفوف وحده، لكشف أي كتابة أثناء القراءة.
create function pg_temp.receipt_snapshot()
returns jsonb language sql as $$
  select jsonb_build_object(
    'sessions', (select jsonb_agg(to_jsonb(s) order by s.id) from ops.irrigation_sessions s),
    'commands', (select jsonb_agg(to_jsonb(c) order by c.id) from sync.processed_commands c),
    'charges', (select jsonb_agg(to_jsonb(c) order by c.id) from billing.session_charges c),
    'invoices', (select jsonb_agg(to_jsonb(i) order by i.id) from billing.invoices i),
    'segments', (select jsonb_agg(to_jsonb(s) order by s.id) from ops.session_segments s)
  );
$$;

do $tests$
declare
  tenant_a uuid; tenant_b uuid;
  actor uuid := gen_random_uuid(); viewer uuid := gen_random_uuid();
  stranger uuid := gen_random_uuid(); owner_id uuid := gen_random_uuid();
  wells uuid[] := array[gen_random_uuid(), gen_random_uuid(), gen_random_uuid()];
  sessions uuid[] := array[gen_random_uuid(), gen_random_uuid(), gen_random_uuid()];
  second_session uuid := gen_random_uuid(); orphan uuid := gen_random_uuid();
  manual uuid := gen_random_uuid(); booked uuid := gen_random_uuid();
  pending uuid := gen_random_uuid(); absent uuid := gen_random_uuid();
  other_session uuid := gen_random_uuid(); other_well uuid := gen_random_uuid();
  other_tenant uuid := gen_random_uuid(); wrong_type uuid := gen_random_uuid();
  person uuid; farmer uuid; account_id uuid; farm uuid; pump uuid;
  response jsonb; expected jsonb; original jsonb; before_read jsonb; denied boolean;
  payload jsonb; bad jsonb; k text; i integer; function_id oid;
  visible_count bigint;
  removed_permission iam.role_permissions%rowtype;
  ended timestamptz := '2026-10-01 07:00:00+00';
begin
  insert into core.tenants(name) values ('q137 receipt A') returning id into tenant_a;
  insert into core.tenants(name) values ('q137 receipt B') returning id into tenant_b;
  insert into auth.users(id, instance_id, aud, role, email,
    email_confirmed_at, created_at, updated_at)
  select id, '00000000-0000-0000-0000-000000000000'::uuid,
    'authenticated', 'authenticated', id::text || '@receipt.test', now(), now(), now()
  from unnest(array[actor, viewer, stranger, owner_id]) as u(id);
  insert into iam.profiles(id, full_name) values
    (actor, 'مشغل الإقرار'), (viewer, 'قارئ بلا إكمال'), (stranger, 'بلا تعيين'),
    (owner_id, 'مالك اختبار الإقرار')
  on conflict (id) do nothing;

  for i in 1..3 loop
    insert into core.wells(id, tenant_id, name)
    values (wells[i], case when i=3 then tenant_b else tenant_a end, 'receipt '||i);
    insert into core.well_assignments(well_id, profile_id, role, status)
    values(wells[i], actor, 'operator', case when i=3 then 'inactive' else 'active' end);
    insert into core.persons(tenant_id, full_name, normalized_name)
    values(case when i=3 then tenant_b else tenant_a end, 'مزارع إقرار '||i, 'مزارع إقرار '||i)
    returning id into person;
    insert into ops.farmer_profiles(tenant_id, person_id)
    values(case when i=3 then tenant_b else tenant_a end, person) returning id into farmer;
    insert into ops.farmer_well_accounts(tenant_id, well_id, farmer_profile_id, public_code)
    values(case when i=3 then tenant_b else tenant_a end, wells[i], farmer, 'RECEIPT-'||i)
    returning id into account_id;
    insert into ops.farms(well_id, name, farmer_well_account_id)
    values(wells[i], 'أرض الإقرار', account_id) returning id into farm;
    insert into core.pumps(well_id, name, power_source, status)
    values(wells[i], 'مضخة الإقرار', 'diesel', 'active') returning id into pump;
    -- إدراج واقعة تاريخية مغلقة لا يستدعي الإكمال أو حساب الرسوم.
    insert into ops.irrigation_sessions(id, well_id, pump_id, farm_id,
      farmer_well_account_id, operator_profile_id, started_at, ended_at, status)
    values(sessions[i], wells[i], pump, farm, account_id, actor,
      ended-interval '1 hour', ended, 'closed');
    if i=1 then
      insert into ops.irrigation_sessions(id, well_id, pump_id, farm_id,
        farmer_well_account_id, operator_profile_id, started_at, ended_at, status)
      values(second_session, wells[1], pump, farm, account_id, actor,
        ended-interval '3 hours', ended-interval '2 hours', 'closed');
    end if;
  end loop;
  insert into core.well_assignments(well_id, profile_id, role, status)
  values(wells[1], viewer, 'viewer', 'active'), (wells[1], owner_id, 'owner', 'active');
  perform set_config('request.jwt.claim.sub', actor::text, true);
  perform pg_temp.receipt_check(iam.has_well_permission(wells[1], 'session.complete'),
    'المشغل يملك صلاحية الإكمال القائمة دون منح جديد');

  expected := jsonb_build_object('session_id', sessions[1],
    'session_charge_id', gen_random_uuid(), 'status', 'closed', 'ended_at', ended,
    'actual_seconds', 3600, 'billable_seconds', 3540,
    'weighted_price_per_hour_minor', 3600, 'amount_minor', 3540,
    'segments', jsonb_build_array(jsonb_build_object('fuel_quantity_ml', 1234)));
  payload := jsonb_build_object('booking_execution_contract_version', 113,
    'session_id', sessions[1], 'ended_at', ended, 'fuel_quantity_ml', null,
    'fuel_measurement_type', null, 'fuel_tank_id', null);
  insert into sync.processed_commands(tenant_id, command_id, command_type,
    entity_id, status, request_payload, response_payload) values
    (tenant_a, manual, 'complete_irrigation_session', sessions[1], 'accepted', null, expected),
    (tenant_a, booked, 'complete_booking_session', sessions[1], 'accepted', payload, expected),
    (tenant_a, pending, 'complete_irrigation_session', sessions[1], 'processing', null, null),
    (tenant_a, wrong_type, 'pause_irrigation_session', sessions[1], 'accepted', null, expected),
    (tenant_a, other_session, 'complete_irrigation_session', second_session, 'accepted', null,
      expected||jsonb_build_object('session_id', second_session)),
    (tenant_a, other_well, 'complete_irrigation_session', sessions[2], 'accepted', null,
      expected||jsonb_build_object('session_id', sessions[2])),
    (tenant_b, other_tenant, 'complete_irrigation_session', sessions[3], 'accepted', null,
      expected||jsonb_build_object('session_id', sessions[3])),
    (tenant_a, orphan, 'complete_irrigation_session', orphan, 'accepted', null,
      expected||jsonb_build_object('session_id', orphan));

  before_read := pg_temp.receipt_snapshot();
  -- اختبار سلوكي تحت دور المستخدم الفعلي: لا مالك ولا مدير ولا BYPASSRLS.
  execute 'set local role authenticated';
  perform pg_temp.receipt_check(current_user='authenticated' and
    pg_catalog.row_security_active('sync.processed_commands'::regclass) and
    not exists(select 1 from pg_catalog.pg_roles
      where rolname=current_user and (rolsuper or rolbypassrls)) and
    not exists(select 1 from core.well_assignments
      where profile_id=actor and role in ('owner','manager')),
    'سياق مشغل فقط مع RLS فعلي دون صلاحيات تجاوز');
  select count(*) into visible_count from sync.processed_commands
    where tenant_id=tenant_a and command_id=manual;
  perform pg_temp.receipt_check(visible_count=0,
    'سياسة الجدول تحجب إقرار المشغل عند SELECT المباشر');
  response := api.get_completion_receipt(wells[1],sessions[1],manual);
  perform pg_temp.receipt_check(response->>'status'='accepted' and
    response->'receipt'=expected and response->'retry_authorized'='false'::jsonb,
    'المشغل نفسه يقرأ الإقرار عبر العقد الضيق رغم حجب SELECT المباشر');
  execute 'reset role';

  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  execute 'set local role authenticated';
  select count(*) into visible_count from sync.processed_commands
    where tenant_id=tenant_a and command_id=manual;
  response := api.get_completion_receipt(wells[1],sessions[1],manual);
  perform pg_temp.receipt_check(visible_count=1 and response->>'status'='accepted'
    and response->'receipt'=expected and response->'retry_authorized'='false'::jsonb,
    'مالك البئر المخول يرى الإقرار وفق السياسة والعقد القائمين');
  execute 'reset role';
  perform pg_temp.receipt_check(pg_temp.receipt_denied(wells[2],sessions[2],other_well),
    'الملكية على بئر لا تمنح قراءة عقد بئر آخر');
  perform set_config('request.jwt.claim.sub',actor::text,true);

  response := pg_temp.read_receipt(wells[1], sessions[1], manual);
  perform pg_temp.receipt_check(response->>'status'='accepted' and
    response->'receipt'=expected and response->>'retry_authorized'='false',
    'إقرار يدوي أصلي كامل رغم غياب حمولة الطلب');
  perform pg_temp.receipt_check(response=pg_temp.read_receipt(wells[1], sessions[1], manual),
    'تكرار القراءة يعيد النتيجة نفسها');
  response := pg_temp.read_receipt(wells[1], sessions[1], booked, 'complete_booking_session');
  perform pg_temp.receipt_check(response->>'status'='accepted' and response->'receipt'=expected,
    'إقرار إكمال حجز أصلي');
  response := pg_temp.read_receipt(wells[1], sessions[1], pending);
  perform pg_temp.receipt_check(response->>'status'='processing' and response->'receipt'='null'::jsonb,
    'أمر مسجل دون نتيجة نهائية');
  response := pg_temp.read_receipt(wells[1], sessions[1], absent);
  perform pg_temp.receipt_check(response->>'status'='not_found' and
    response->>'retry_authorized'='false' and response->'receipt'='null'::jsonb,
    'عدم العثور ليس إذن إعادة إرسال ولا إثبات عدم التنفيذ');
  foreach k in array array[wrong_type::text, other_session::text, other_well::text] loop
    response := pg_temp.read_receipt(wells[1], sessions[1], k::uuid);
    perform pg_temp.receipt_check(response->>'status'='unresolved' and
      response->'receipt'='null'::jsonb, 'حجب تعارض النوع أو الجلسة أو البئر: '||k);
  end loop;
  response := pg_temp.read_receipt(wells[1], sessions[1], other_tenant);
  perform pg_temp.receipt_check(response->>'status'='not_found' and
    response->'receipt'='null'::jsonb, 'عدم كشف أمر الحساب المستقل الآخر');
  perform pg_temp.receipt_check(pg_temp.receipt_denied(wells[1], sessions[2], other_well),
    'رفض جلسة لا تنتمي إلى البئر قبل قراءة الأمر');
  perform pg_temp.receipt_check(pg_temp.receipt_denied(wells[3], sessions[3], other_tenant),
    'رفض البئر في الحساب الآخر');
  perform pg_temp.receipt_check(pg_temp.receipt_denied(wells[1], orphan, orphan),
    'إقرار تاريخي بلا جلسة متاحة لا يمنح سلطة قراءة');
  perform pg_temp.receipt_check(before_read=pg_temp.receipt_snapshot(),
    'كل القراءات السابقة بلا كتابة للجلسات والأوامر والرسوم والفواتير والمقاطع');

  -- عزل الصلاحية عن اسم الدور: المشغل يبقى معيّنًا ونشطًا لكن يفقد session.complete.
  -- الحذف والاستعادة محليان لهذه المعاملة فقط، والتنظيف النهائي ROLLBACK.
  delete from iam.role_permissions rp using iam.roles r, iam.permissions p
  where rp.role_id=r.id and rp.permission_id=p.id
    and r.code='operator' and p.code='session.complete'
  returning rp.* into removed_permission;
  perform pg_temp.receipt_check(found and exists(select 1 from core.well_assignments
    where well_id=wells[1] and profile_id=actor and role='operator' and status='active')
    and not iam.has_well_permission(wells[1],'session.complete'),
    'تهيئة مشغل نشط بلا صلاحية إكمال دون تغيير دوره');
  perform pg_temp.receipt_check(pg_temp.receipt_denied(wells[1],sessions[1],manual),
    'المشغل النشط بلا session.complete ممنوع من الإقرار');
  insert into iam.role_permissions(role_id,permission_id)
    values(removed_permission.role_id,removed_permission.permission_id);
  perform pg_temp.receipt_check(iam.has_well_permission(wells[1],'session.complete'),
    'استعادة صلاحية الاختبار قبل متابعة الحالات');

  foreach k in array array[viewer::text, stranger::text, ''::text] loop
    perform set_config('request.jwt.claim.sub', k, true);
    perform pg_temp.receipt_check(pg_temp.receipt_denied(wells[1], sessions[1], manual),
      'رفض فاقد الصلاحية أو التعيين أو المصادقة: '||k);
  end loop;
  perform set_config('request.jwt.claim.sub', actor::text, true);
  update core.well_assignments set status='inactive'
    where well_id=wells[1] and profile_id=actor;
  perform pg_temp.receipt_check(pg_temp.receipt_denied(wells[1], sessions[1], manual),
    'سحب التعيين نافذ فورًا');
  update core.well_assignments set status='active'
    where well_id=wells[1] and profile_id=actor;

  select to_jsonb(c) into original from sync.processed_commands c
    where tenant_id=tenant_a and command_id=manual;
  foreach k in array array['ended_at','actual_seconds','billable_seconds',
    'weighted_price_per_hour_minor','amount_minor','session_charge_id','status'] loop
    update sync.processed_commands set response_payload=expected-k
      where tenant_id=tenant_a and command_id=manual;
    before_read := pg_temp.receipt_snapshot();
    response := pg_temp.read_receipt(wells[1], sessions[1], manual);
    perform pg_temp.receipt_check(response->>'status'='unresolved' and
      response->'receipt'='null'::jsonb and before_read=pg_temp.receipt_snapshot(),
      'إقرار ناقص بلا إصلاح أو تسريب: '||k);
  end loop;
  for bad in select value from jsonb_array_elements(jsonb_build_array(
    expected||jsonb_build_object('session_id', second_session),
    expected||jsonb_build_object('session_id', null),
    expected||jsonb_build_object('well_id', wells[2]),
    expected||jsonb_build_object('tenant_id', tenant_b),
    expected||jsonb_build_object('command_id', absent),
    expected||jsonb_build_object('command_type', 'complete_booking_session'),
    expected||jsonb_build_object('status', 'open'),
    expected||jsonb_build_object('ended_at', 'not-a-date'),
    expected||jsonb_build_object('ended_at', ended-interval '1 second'),
    expected||jsonb_build_object('ended_at', '2026-10-01T07:00:00'),
    expected||jsonb_build_object('session_charge_id', 'invalid-uuid'),
    expected||jsonb_build_object('amount_minor', -1),
    expected||jsonb_build_object('billable_seconds', 3601),
    expected||jsonb_build_object('amount_minor', '3540'),
    expected||jsonb_build_object('amount_minor', 3.5),
    expected||jsonb_build_object('amount_minor', 9223372036854775808::numeric),
    expected||jsonb_build_object('segments', 'invalid'),
    '[]'::jsonb, 'null'::jsonb)) loop
    update sync.processed_commands set response_payload=bad
      where tenant_id=tenant_a and command_id=manual;
    response := pg_temp.read_receipt(wells[1], sessions[1], manual);
    perform pg_temp.receipt_check(response->>'status'='unresolved' and
      response->'receipt'='null'::jsonb, 'رفض إقرار متعارض أو مشوه: '||bad::text);
  end loop;
  update sync.processed_commands set response_payload=expected-'session_id'
    where tenant_id=tenant_a and command_id=manual;
  before_read := pg_temp.receipt_snapshot();
  response := pg_temp.read_receipt(wells[1], sessions[1], manual);
  perform pg_temp.receipt_check(response->>'status'='unresolved' and
    response->'receipt'='null'::jsonb and response->'retry_authorized'='false'::jsonb
    and before_read=pg_temp.receipt_snapshot(),
    'إقرار accepted يفتقد session_id: unresolved دون كتابة أو إذن إعادة إرسال');
  update sync.processed_commands set response_payload=expected-'segments'
    where tenant_id=tenant_a and command_id=manual;
  before_read := pg_temp.receipt_snapshot();
  response := pg_temp.read_receipt(wells[1], sessions[1], manual);
  perform pg_temp.receipt_check(response->>'status'='unresolved' and
    response->'receipt'='null'::jsonb and response->'retry_authorized'='false'::jsonb
    and before_read=pg_temp.receipt_snapshot(),
    'إقرار accepted يفتقد segments: unresolved دون كتابة أو إذن إعادة إرسال');
  update sync.processed_commands set response_payload=expected
    where tenant_id=tenant_a and command_id=manual;
  perform pg_temp.receipt_check(original=(select to_jsonb(c) from sync.processed_commands c
    where tenant_id=tenant_a and command_id=manual), 'الإقرار الأصلي محفوظ حرفيًا بعد القراءة');

  update sync.processed_commands set response_payload=expected||jsonb_build_object(
    'amount_minor',9007199254740993::bigint)
    where tenant_id=tenant_a and command_id=manual;
  response := pg_temp.read_receipt(wells[1],sessions[1],manual);
  perform pg_temp.receipt_check(response->'receipt'->'amount_minor'='9007199254740993'::jsonb,
    'حفظ دقة bigint دون إعادة حساب أو تقريب');
  update sync.processed_commands set response_payload=expected
    where tenant_id=tenant_a and command_id=manual;

  -- تفويض الدالة الداخلية ليس تجاوزًا لحارسها عند استدعائها مباشرة.
  perform set_config('request.jwt.claim.sub',stranger::text,true);
  execute 'set local role authenticated';
  denied := false;
  begin
    perform sync.get_completion_receipt_read(wells[1],sessions[1],manual);
  exception when insufficient_privilege then denied := true;
  end;
  execute 'reset role';
  perform pg_temp.receipt_check(denied,'القارئ الداخلي يمنع تجاوز تفويض البئر');
  perform set_config('request.jwt.claim.sub',actor::text,true);
  execute 'set local role anon';
  denied := false;
  begin
    perform api.get_completion_receipt(wells[1],sessions[1],manual);
  exception when insufficient_privilege then denied := true;
  end;
  execute 'reset role';
  perform pg_temp.receipt_check(denied,'تنفيذ anon مرفوض حتى مع sub مخول');

  denied := false;
  begin
    perform pg_temp.read_receipt(wells[1],sessions[1],manual,'pause_irrigation_session');
  exception when invalid_parameter_value then denied := true;
  end;
  perform pg_temp.receipt_check(denied,'رفض نوع متوقع خارج عقد الإكمال');

  update sync.processed_commands set request_payload=payload||jsonb_build_object('session_id', second_session)
    where tenant_id=tenant_a and command_id=booked;
  response := pg_temp.read_receipt(wells[1], sessions[1], booked, 'complete_booking_session');
  perform pg_temp.receipt_check(response->>'status'='unresolved' and response->'receipt'='null'::jsonb,
    'تعارض حمولة إكمال الحجز لا يعيد نجاحًا');
  update sync.processed_commands set request_payload=null where command_id=booked and tenant_id=tenant_a;
  response := pg_temp.read_receipt(wells[1], sessions[1], booked, 'complete_booking_session');
  perform pg_temp.receipt_check(response->>'status'='unresolved', 'حمولة الحجز المفقودة تتطلب مراجعة');
  update sync.processed_commands set response_payload=expected where command_id=pending and tenant_id=tenant_a;
  response := pg_temp.read_receipt(wells[1], sessions[1], pending);
  perform pg_temp.receipt_check(response->>'status'='unresolved', 'processing مع نتيجة نهائية حالة متعارضة');
  update sync.processed_commands set status='rejected' where command_id=pending and tenant_id=tenant_a;
  response := pg_temp.read_receipt(wells[1], sessions[1], pending);
  perform pg_temp.receipt_check(response->>'status'='unresolved' and response->'receipt'='null'::jsonb,
    'الرفض السابق لا يتحول إلى إكمال مقبول');

  -- تصادم UUID بين حسابين: المفتاح المركب هو سلطة البحث الوحيدة.
  insert into sync.processed_commands(tenant_id,command_id,command_type,entity_id,status,response_payload)
  values(tenant_b,manual,'complete_irrigation_session',sessions[3],'accepted',
    expected||jsonb_build_object('amount_minor',9007199254740993::bigint));
  response := pg_temp.read_receipt(wells[1],sessions[1],manual);
  perform pg_temp.receipt_check(response->'receipt'=expected, 'تصادم معرّف الأمر لا يعبر الحسابات');

  for function_id in select unnest(array[
    'api.get_completion_receipt(uuid,uuid,uuid,text)'::regprocedure::oid,
    'sync.get_completion_receipt_read(uuid,uuid,uuid,text)'::regprocedure::oid]) loop
    perform pg_temp.receipt_check(not has_function_privilege('anon',function_id,'execute') and
      has_function_privilege('authenticated',function_id,'execute') and
      has_function_privilege('service_role',function_id,'execute') and
      not exists(select 1 from pg_proc p,
        lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        where p.oid=function_id and a.grantee=0 and a.privilege_type='EXECUTE'),
      'منح authenticated ضمن service_role مع حظر anon وPUBLIC: '||function_id);
    perform pg_temp.receipt_check(exists(select 1 from pg_proc p where p.oid=function_id
      and p.provolatile='s' and p.proconfig @> array['search_path=pg_catalog, pg_temp']
      and p.prosecdef=(function_id='sync.get_completion_receipt_read(uuid,uuid,uuid,text)'::regprocedure::oid)),
      'قارئ stable ومسار أسماء ثابت مع بقاء api invoker: '||function_id);
  end loop;
end $tests$;
rollback;
