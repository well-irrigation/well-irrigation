-- اختبار 096 — تذاكر إعادة تعيين كلمة المرور بإثبات بشري
--
-- يثبّت: الجدول مغلق بلا سياسات ولا منح، والاستهلاك **لمفتاح الخدمة وحده**
-- (لأنه خطوة ما قبل المصادقة، و`anon EXECUTE = 0` حدٌّ مقيس)، والرمز الخاطئ
-- يخصم ويبقى الخصم، واستنفاد المحاولات يُبطل، والمنتهية تُوسم ولا تُستهلك،
-- ورمز واحد صالح لكل حساب، والاستهلاك مرة واحدة، ولا رمز ولا تلبيدة في أي
-- قراءة، ولا كلمة مرور تُكتب في أي موضع من هذه الهجرة.

\set ON_ERROR_STOP on

begin;

do $test$
declare
  v_api_req oid := to_regprocedure(
    'api.request_member_password_reset(uuid, text)'
  );
  v_api_list oid := to_regprocedure(
    'api.list_member_reset_requests(uuid, integer)'
  );
  v_core_req oid := to_regprocedure(
    'core.request_member_password_reset(uuid, text)'
  );
  v_core_consume oid := to_regprocedure(
    'core.consume_password_reset(text, text)'
  );
  v_core_read oid := to_regprocedure(
    'core.read_member_reset_requests(uuid, integer)'
  );
  v_api_consume oid := to_regprocedure(
    'api.consume_password_reset(text, text)'
  );
  v_owner uuid;
  v_member uuid;
  v_other uuid;
  v_tenant uuid;
  v_well uuid;
  v_payload jsonb;
  v_code text;
  v_ticket uuid;
  v_count integer;
  v_count_2 integer;
  v_text text;
begin

  -- ---------------------------------------------------------------
  -- 1. الأهداف موجودة، وخصائص أمانها كما تقتضي ق-78/ق-79
  -- ---------------------------------------------------------------

  if v_api_req is not null and v_api_list is not null
     and v_core_req is not null and v_core_consume is not null
     and v_core_read is not null
  then
    raise notice 'PASS 1: العقدان وثلاثة إجراءات داخلية موجودة';
  else
    raise notice 'FAIL 1: هدف واحد أو أكثر غير موجود';
  end if;

  select
    count(*) filter (where p.oid in (v_api_req, v_api_list)
      and p.prosecdef is false),
    count(*) filter (where p.oid in (v_core_req, v_core_consume, v_core_read)
      and p.prosecdef is true
      and p.proconfig @> array['search_path=pg_catalog, pg_temp'])
  into v_count, v_count_2
  from pg_proc p
  where p.oid in (v_api_req, v_api_list, v_core_req, v_core_consume,
    v_core_read);

  if v_count = 2 and v_count_2 = 3 then
    raise notice 'PASS 2: api INVOKER وcore DEFINER بمسار بحث مثبت';
  else
    raise notice 'FAIL 2: خصائص الأمان غير مطابقة: api=% core=%',
      v_count, v_count_2;
  end if;

  -- أهم فحص في الملف: الاستهلاك لمفتاح الخدمة وحده.
  if not has_function_privilege('anon', v_core_consume, 'EXECUTE')
     and not has_function_privilege('authenticated', v_core_consume, 'EXECUTE')
     and has_function_privilege('service_role', v_core_consume, 'EXECUTE')
  then
    raise notice 'PASS 3: الاستهلاك لـservice_role وحده — لا anon ولا مصدَّق';
  else
    raise notice 'FAIL 3: منح الاستهلاك غير محصور بمفتاح الخدمة';
  end if;

  if not has_function_privilege('anon', v_api_req, 'EXECUTE')
     and not has_function_privilege('anon', v_api_list, 'EXECUTE')
     and has_function_privilege('authenticated', v_api_req, 'EXECUTE')
  then
    raise notice 'PASS 4: anon بلا EXECUTE على عقدَي المالك';
  else
    raise notice 'FAIL 4: منح عقود المالك غير مطابقة';
  end if;

  -- ---------------------------------------------------------------
  -- 2. الجدول مغلق: RLS مفعّلة بلا سياسات، وبلا منح لأي دور تطبيقي
  -- ---------------------------------------------------------------

  select count(*) into v_count
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'core'
    and c.relname = 'password_reset_tickets'
    and c.relrowsecurity;

  select count(*) into v_count_2
  from pg_policies
  where schemaname = 'core'
    and tablename = 'password_reset_tickets';

  if v_count = 1 and v_count_2 = 0 then
    raise notice 'PASS 5: RLS مفعّلة والجدول بلا سياسات';
  else
    raise notice 'FAIL 5: rls=% policies=%', v_count, v_count_2;
  end if;

  select count(*) into v_count
  from information_schema.table_privileges
  where table_schema = 'core'
    and table_name = 'password_reset_tickets'
    and grantee in ('anon', 'authenticated', 'service_role');

  if v_count = 0 then
    raise notice 'PASS 6: لا منح جدول لأي دور تطبيقي — الوصول بالعقود وحدها';
  else
    raise notice 'FAIL 6: بقيت % منحة على الجدول', v_count;
  end if;

  -- لا صلاحية مسمّاة جديدة لهذه الجولة: سلطتها team.manage القائمة.
  select count(*) into v_count
  from iam.permissions p
  where p.code like '%reset%';

  if v_count = 0 then
    raise notice 'PASS 7: لا صلاحية جديدة — السلطة team.manage القائمة';
  else
    raise notice 'FAIL 7: أُضيفت % صلاحية بلا حاجة', v_count;
  end if;

  -- ---------------------------------------------------------------
  -- 3. تجهيز: مالك وعضو وغريب على بئر واحد
  -- ---------------------------------------------------------------

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'reset-owner-096@test.local',
    crypt('x', gen_salt('bf')),
    now(), now(), now(),
    jsonb_build_object('full_name', 'مالك 096', 'phone', '770000096')
  ) returning id into v_owner;

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'reset-member-096@test.local',
    crypt('x', gen_salt('bf')),
    now(), now(), now(),
    jsonb_build_object('full_name', 'مشغّل 096', 'phone', '771000096')
  ) returning id into v_member;

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'reset-outsider-096@test.local',
    crypt('x', gen_salt('bf')),
    now(), now(), now(),
    jsonb_build_object('full_name', 'غريب 096', 'phone', '772000096')
  ) returning id into v_other;

  insert into core.tenants (name)
  values ('جهة إعادة التعيين 096')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name, location)
  values (v_tenant, 'بئر 096', 'موقع 096')
  returning id into v_well;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values
    (v_well, v_owner, 'owner', 'active'),
    (v_well, v_member, 'operator', 'active');

  -- ---------------------------------------------------------------
  -- 4. المالك يُصدر تذكرة: رمز من ستة أرقام، وتذكرة سارية واحدة
  -- ---------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';

  v_payload := api.request_member_password_reset(v_well, '771000096');
  v_code := v_payload ->> 'code';
  v_ticket := (v_payload ->> 'ticket_id')::uuid;

  if v_payload ->> 'outcome' = 'issued'
     and v_code ~ '^[0-9]{6}$'
     and v_ticket is not null
     and v_payload ->> 'full_name' = 'مشغّل 096'
     and (v_payload ->> 'expires_at')::timestamptz > now()
  then
    raise notice 'PASS 8: إصدار التذكرة يعيد رمزًا من ستة أرقام ومدة سارية';
  else
    raise notice 'FAIL 8: حمولة الإصدار غير مطابقة: %', v_payload;
  end if;

  -- إعادة الإصدار تُبطل ما قبلها: سارية واحدة دائمًا.
  v_payload := api.request_member_password_reset(v_well, '771000096');

  execute 'reset role';

  select
    count(*) filter (where status = 'pending'),
    count(*) filter (where status = 'revoked')
  into v_count, v_count_2
  from core.password_reset_tickets
  where well_id = v_well;

  if v_count = 1 and v_count_2 = 1
     and (v_payload ->> 'ticket_id')::uuid <> v_ticket
  then
    raise notice 'PASS 9: إعادة الإصدار تُبطل السابقة — سارية واحدة';
  else
    raise notice 'FAIL 9: pending=% revoked=%', v_count, v_count_2;
  end if;

  v_code := v_payload ->> 'code';
  v_ticket := (v_payload ->> 'ticket_id')::uuid;

  -- رقم لا عضو له على هذا البئر: حالة مُعادة لا استثناء ولا تذكرة.
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';

  v_payload := api.request_member_password_reset(v_well, '779999096');

  execute 'reset role';

  select count(*) into v_count
  from core.password_reset_tickets
  where well_id = v_well
    and status = 'pending';

  if v_payload ->> 'outcome' = 'no_member'
     and (v_payload ->> 'code') is null
     and v_count = 1
  then
    raise notice 'PASS 10: رقم بلا عضو = حالة مُعادة بلا تذكرة ولا رمز';
  else
    raise notice 'FAIL 10: حمولة «لا عضو» غير مطابقة: %', v_payload;
  end if;

  -- ---------------------------------------------------------------
  -- 5. من لا يملك team.manage لا يُصدر ولا يقرأ
  -- ---------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_member::text, true);
  execute 'set local role authenticated';

  begin
    perform api.request_member_password_reset(v_well, '771000096');
    v_text := 'no-error';
  exception
    when others then
      v_text := sqlstate;
  end;

  if v_text = '42501' then
    v_count := 1;
  else
    v_count := 0;
    raise notice 'INFO: الإصدار أعاد % لا 42501', v_text;
  end if;

  begin
    perform api.list_member_reset_requests(v_well);
    v_text := 'no-error';
  exception
    when others then
      v_text := sqlstate;
  end;

  if v_text = '42501' then
    v_count := v_count + 1;
  else
    raise notice 'INFO: القراءة أعادت % لا 42501', v_text;
  end if;

  -- والمصدَّق لا ينفّذ الاستهلاك ولو نادى مباشرة.
  begin
    perform core.consume_password_reset('771000096', v_code);
    v_text := 'no-error';
  exception
    when others then
      v_text := sqlstate;
  end;

  if v_text = '42501' then
    v_count := v_count + 1;
  else
    raise notice 'INFO: الاستهلاك من مصدَّق أعاد % لا 42501', v_text;
  end if;

  execute 'reset role';

  if v_count = 3 then
    raise notice 'PASS 11: العضو لا يُصدر ولا يقرأ ولا يستهلك (42501 ثلاثًا)';
  else
    raise notice 'FAIL 11: % من 3 حدود ردّت 42501', v_count;
  end if;

  -- ---------------------------------------------------------------
  -- 6. الاستهلاك بمفتاح الخدمة: الخطأ يخصم ويبقى، والصحيح يستهلك مرة
  -- ---------------------------------------------------------------

  execute 'set local role service_role';

  v_payload := core.consume_password_reset('771000096', '000000');

  if v_payload ->> 'outcome' = 'wrong_code'
     and (v_payload ->> 'attempts_left')::int = 4
     and (v_payload ->> 'profile_id') is null
  then
    v_count := 1;
  else
    v_count := 0;
    raise notice 'INFO: حمولة الرمز الخاطئ: %', v_payload;
  end if;

  execute 'reset role';

  -- الخصم باقٍ بعد نهاية المعاملة الفرعية: لا استثناء يتراجع عنه.
  select attempts_left into v_count_2
  from core.password_reset_tickets
  where id = v_ticket;

  if v_count = 1 and v_count_2 = 4 then
    raise notice 'PASS 12: الرمز الخاطئ يخصم من العدّاد ويبقى الخصم';
  else
    raise notice 'FAIL 12: العدّاد صار % والحمولة %', v_count_2, v_count;
  end if;

  execute 'set local role service_role';

  v_payload := core.consume_password_reset('771000096', v_code);

  if v_payload ->> 'outcome' = 'ok'
     and (v_payload ->> 'profile_id')::uuid = v_member
     and not (v_payload::text like '%code%hash%')
  then
    v_count := 1;
  else
    v_count := 0;
    raise notice 'INFO: حمولة الاستهلاك: %', v_payload;
  end if;

  -- استهلاك ثانٍ بنفس الرمز لا يعيد شيئًا: التذكرة مستهلكة.
  v_payload := core.consume_password_reset('771000096', v_code);

  execute 'reset role';

  select count(*) into v_count_2
  from core.password_reset_tickets
  where id = v_ticket
    and status = 'consumed'
    and consumed_at is not null;

  if v_count = 1
     and v_count_2 = 1
     and v_payload ->> 'outcome' = 'no_ticket'
  then
    raise notice 'PASS 13: الرمز الصحيح يستهلك مرة واحدة ويعيد الحساب';
  else
    raise notice 'FAIL 13: consumed=% والحمولة الثانية %', v_count_2, v_payload;
  end if;

  -- ---------------------------------------------------------------
  -- 7. المنتهية تُوسم منتهية ولا تُستهلك، واستنفاد المحاولات يُبطل
  -- ---------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';
  v_payload := api.request_member_password_reset(v_well, '771000096');
  execute 'reset role';

  v_code := v_payload ->> 'code';
  v_ticket := (v_payload ->> 'ticket_id')::uuid;

  update core.password_reset_tickets
  set expires_at = now() - interval '1 minute'
  where id = v_ticket;

  execute 'set local role service_role';
  v_payload := core.consume_password_reset('771000096', v_code);
  execute 'reset role';

  select count(*) into v_count
  from core.password_reset_tickets
  where id = v_ticket
    and status = 'expired';

  if v_payload ->> 'outcome' = 'no_ticket' and v_count = 1 then
    raise notice 'PASS 14: المنتهية تُوسم منتهية ولا تُستهلك برمزها الصحيح';
  else
    raise notice 'FAIL 14: حمولة المنتهية % والحالة count=%', v_payload, v_count;
  end if;

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';
  v_payload := api.request_member_password_reset(v_well, '771000096');
  execute 'reset role';

  v_code := v_payload ->> 'code';
  v_ticket := (v_payload ->> 'ticket_id')::uuid;

  update core.password_reset_tickets
  set attempts_left = 1
  where id = v_ticket;

  execute 'set local role service_role';
  v_payload := core.consume_password_reset('771000096', '000000');
  execute 'reset role';

  select count(*) into v_count
  from core.password_reset_tickets
  where id = v_ticket
    and status = 'revoked'
    and attempts_left = 0;

  if (v_payload ->> 'attempts_left')::int = 0 and v_count = 1 then
    raise notice 'PASS 15: استنفاد المحاولات يُبطل التذكرة فورًا';
  else
    raise notice 'FAIL 15: حمولة الاستنفاد % والحالة count=%',
      v_payload, v_count;
  end if;

  -- والرمز الصحيح بعد الإبطال لا يعمل: البطلان نهائي.
  execute 'set local role service_role';
  v_payload := core.consume_password_reset('771000096', v_code);
  execute 'reset role';

  if v_payload ->> 'outcome' = 'no_ticket' then
    raise notice 'PASS 16: الرمز الصحيح على تذكرة مُبطلة لا يعمل';
  else
    raise notice 'FAIL 16: تذكرة مُبطلة قَبِلت رمزها: %', v_payload;
  end if;

  -- ---------------------------------------------------------------
  -- 8. قراءة المالك: الحالة والمحاولات بلا رمز ولا تلبيدة
  -- ---------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';

  v_payload := api.list_member_reset_requests(v_well);

  execute 'reset role';

  select code_hash into v_text
  from core.password_reset_tickets
  where id = v_ticket;

  if v_payload ->> 'contract' = 'list_member_reset_requests'
     and jsonb_array_length(v_payload -> 'requests') >= 4
     and not (v_payload::text like '%' || v_text || '%')
     and not (v_payload::text like '%code%')
     and v_payload -> 'requests' -> 0 ->> 'full_name' = 'مشغّل 096'
  then
    raise notice 'PASS 17: قراءة المالك تعرض الحالة بلا رمز ولا تلبيدة';
  else
    raise notice 'FAIL 17: حمولة القراءة غير مطابقة: %', v_payload;
  end if;

  -- ---------------------------------------------------------------
  -- 9. لا كلمة مرور تُكتب في هذه الهجرة: لا أحد من إجراءاتها يمسّ
  --    مخطط auth. كتابتها تبقى في نظام المصادقة حيث يختارها صاحبها (706).
  -- ---------------------------------------------------------------

  select count(*) into v_count
  from pg_proc p
  where p.oid in (v_core_req, v_core_consume, v_core_read, v_api_req,
    v_api_list)
    and (
      pg_get_functiondef(p.oid) like '%auth.users%'
      or pg_get_functiondef(p.oid) like '%encrypted_password%'
      or pg_get_functiondef(p.oid) like '%crypt(%'
    );

  if v_count = 0 then
    raise notice 'PASS 18: لا إجراء منها يمسّ auth.users ولا كلمة مرور';
  else
    raise notice 'FAIL 18: % إجراء يمسّ نظام المصادقة', v_count;
  end if;

  -- ---------------------------------------------------------------
  -- 10. غلاف الاستهلاك: منحه متناظر (حرس 074) والحدّ في موضعين أقوى —
  --     الإجراء الداخلي لمفتاح الخدمة وحده، والغلاف يرفض كل جلسة مستخدم.
  -- ---------------------------------------------------------------

  v_count := 0;
  if not has_function_privilege('anon', v_api_consume, 'EXECUTE') then
    v_count := v_count + 1;
  end if;
  if has_function_privilege('authenticated', v_api_consume, 'EXECUTE')
     and has_function_privilege('service_role', v_api_consume, 'EXECUTE')
  then
    v_count := v_count + 1;
  end if;

  select count(*) into v_count_2
  from pg_proc p
  where p.oid = v_api_consume
    and p.prosecdef is false;

  -- جلسة مستخدم تُرفض من الغلاف نفسه لا من رسالة تفويض غامضة.
  perform set_config('request.jwt.claim.sub', v_member::text, true);
  execute 'set local role authenticated';

  begin
    perform api.consume_password_reset('771000096', '111111');
    v_text := 'no-error';
  exception
    when others then
      v_text := sqlstate;
  end;

  execute 'reset role';

  if v_count = 2 and v_count_2 = 1 and v_text = '42501' then
    raise notice 'PASS 19: الغلاف INVOKER متناظر المنح ويرفض جلسة المستخدم';
  else
    raise notice 'FAIL 19: منح=% secdef=% وجلسة المستخدم أعادت %',
      v_count, v_count_2, v_text;
  end if;
end;
$test$;

rollback;
