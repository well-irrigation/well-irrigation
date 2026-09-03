-- اختبار 094 — دعوات الفريق والتنشيط (م-41E المرحلة 2 / ق-123)
--
-- يثبّت: صلاحية team.manage ومنحها للمالك وحده، وأن الجدول الجديد بلا
-- Direct DML، وخصائص أمان الإجراءات وACL، وبقاء أغلفة api على INVOKER،
-- ثم السلوك الفعلي: دعوة بصفر صلاحية، ورمز خاطئ يخصم من العدّاد،
-- ومطالبة مرتين = تعيين واحد، ومن له حساب قائم يُربط بلا رمز، وإلغاء
-- الوصول لا يحذف، والرمز لا يُقرأ من أي عقد.

\set ON_ERROR_STOP on

begin;

do $test$
declare
  v_invite oid := to_regprocedure(
    'core.invite_well_member(uuid, text, text, text)'
  );
  v_claim oid := to_regprocedure('core.claim_well_invitation(text)');
  v_api_invite oid := to_regprocedure(
    'api.invite_well_member(uuid, text, text, text)'
  );
  v_api_claim oid := to_regprocedure('api.claim_well_invitation(text)');
  v_owner_user uuid;
  v_op_user uuid;
  v_op2_user uuid;
  v_other_user uuid;
  v_tenant uuid;
  v_well uuid;
  v_other_well uuid;
  v_payload jsonb;
  v_payload2 jsonb;
  v_code text;
  v_count integer;
  v_count_2 integer;
  v_src text;
  v_denied boolean;
begin

  -- ---------------------------------------------------------------
  -- 1. الصلاحية الجديدة موجودة، وممنوحة للمالك وحده
  -- ---------------------------------------------------------------

  select count(*) into v_count
  from iam.permissions p
  where p.code = 'team.manage';

  if v_count = 1 then
    raise notice 'PASS 1: صلاحية team.manage موجودة في الكتالوج';
  else
    raise notice 'FAIL 1: team.manage غير موجودة';
  end if;

  select
    count(*) filter (where r.code = 'tenant_owner'),
    count(*) filter (where r.code <> 'tenant_owner')
  into v_count, v_count_2
  from iam.role_permissions rp
  join iam.roles r on r.id = rp.role_id
  join iam.permissions p on p.id = rp.permission_id
  where p.code = 'team.manage';

  if v_count = 1 and v_count_2 = 0 then
    raise notice 'PASS 2: team.manage للمالك وحده بلا توسيع صامت';
  else
    raise notice 'FAIL 2: منح team.manage غير مطابق (owner=% others=%)',
      v_count, v_count_2;
  end if;

  -- ---------------------------------------------------------------
  -- 3. الجدول الجديد يبدأ بلا Direct DML ولا قراءة لأدوار التطبيق
  -- ---------------------------------------------------------------

  select count(*) into v_count
  from information_schema.role_table_grants g
  where g.table_schema = 'core'
    and g.table_name = 'well_invitations'
    and lower(g.grantee) in ('anon', 'authenticated', 'public');

  if v_count = 0 then
    raise notice 'PASS 3: صفر صلاحيات جدولية لأدوار التطبيق على الدعوات';
  else
    raise notice 'FAIL 3: الجدول مكشوف لأدوار التطبيق (% منحة)', v_count;
  end if;

  select count(*) into v_count
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'core'
    and c.relname = 'well_invitations'
    and c.relrowsecurity;

  if v_count = 1 then
    raise notice 'PASS 4: RLS مفعّلة على core.well_invitations';
  else
    raise notice 'FAIL 4: RLS غير مفعّلة على جدول الدعوات';
  end if;

  -- ---------------------------------------------------------------
  -- 5. خصائص الأمان: الداخلي DEFINER بـsearch_path مثبت، وapi INVOKER
  -- ---------------------------------------------------------------

  select count(*) into v_count
  from pg_proc p
  where p.oid in (v_invite, v_claim)
    and p.prosecdef
    and exists (
      select 1
      from unnest(coalesce(p.proconfig, array[]::text[])) as cfg(v)
      where cfg.v like 'search_path=%'
    );

  if v_count = 2 then
    raise notice 'PASS 5: الإجراءان الداخليان DEFINER بـsearch_path مثبت';
  else
    raise notice 'FAIL 5: خصائص الأمان الداخلية ناقصة (%)', v_count;
  end if;

  select count(*) into v_count
  from pg_proc p
  where p.oid in (v_api_invite, v_api_claim)
    and p.prosecdef;

  if v_count = 0 then
    raise notice 'PASS 6: أغلفة api تبقى SECURITY INVOKER';
  else
    raise notice 'FAIL 6: غلاف api صار DEFINER — خلاف ق-78';
  end if;

  select count(*) into v_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'api'
    and p.proname in (
      'invite_well_member', 'claim_well_invitation',
      'revoke_well_member', 'list_well_team'
    )
    and has_function_privilege('anon', p.oid, 'EXECUTE');

  if v_count = 0 then
    raise notice 'PASS 7: anon لا ينفّذ أي عقد من عقود الفريق';
  else
    raise notice 'FAIL 7: anon ينفّذ % من عقود الفريق', v_count;
  end if;

  -- ---------------------------------------------------------------
  -- 8. الغلاف لا يكرّر قرار الصلاحية: القرار حيث يقع التجاوز
  -- ---------------------------------------------------------------

  select pg_get_functiondef(v_api_invite) into v_src;

  if v_src not like '%has_well_permission%' then
    raise notice 'PASS 8: غلاف الدعوة لا يكرّر فحص الصلاحية';
  else
    raise notice 'FAIL 8: الغلاف يكرّر قرار الصلاحية';
  end if;

  select pg_get_functiondef(v_claim) into v_src;

  select count(*) into v_count
  from information_schema.columns c
  where c.table_schema = 'core'
    and c.table_name = 'well_invitations'
    and c.column_name in ('code', 'code_plain', 'plain_code');

  if v_count = 0 and v_src like '%hash_invitation_code%' then
    raise notice 'PASS 9: لا عمود رمز نصّي، والمطالبة تقارن التلبيدة';
  else
    raise notice 'FAIL 9: الرمز مخزَّن نصًّا أو المقارنة غير مُلبَّدة';
  end if;

  -- ---------------------------------------------------------------
  -- 10. بيانات اختبار: مالك، ومشغّل بحساب ورقم، وآخر بلا دعوة
  -- ---------------------------------------------------------------

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'team-owner-094@test.local',
    crypt('x', gen_salt('bf')),
    now(), now(), now(),
    jsonb_build_object('full_name', 'مالك الفريق 094', 'phone', '770000094')
  ) returning id into v_owner_user;

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'team-operator-094@test.local',
    crypt('x', gen_salt('bf')),
    now(), now(), now(),
    jsonb_build_object('full_name', 'مشغّل مدعو 094', 'phone', '771000094')
  ) returning id into v_op_user;

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'team-operator2-094@test.local',
    crypt('x', gen_salt('bf')),
    now(), now(), now(),
    jsonb_build_object('full_name', 'مشغّل قائم 094', 'phone', '772000094')
  ) returning id into v_op2_user;

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'team-outsider-094@test.local',
    crypt('x', gen_salt('bf')),
    now(), now(), now(),
    jsonb_build_object('full_name', 'غريب 094', 'phone', '773000094')
  ) returning id into v_other_user;

  insert into core.tenants (name)
  values ('جهة الفريق 094')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name, location)
  values (v_tenant, 'بئر الفريق 094', 'موقع 094')
  returning id into v_well;

  insert into core.wells (tenant_id, name, location)
  values (v_tenant, 'بئر آخر 094', 'موقع 094-ب')
  returning id into v_other_well;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_well, v_owner_user, 'owner', 'active');

  -- ---------------------------------------------------------------
  -- 11. المالك يدعو رقمًا بلا حساب: outcome = invited ومعه رمز
  -- ---------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';

  v_payload := api.invite_well_member(
    v_well, 'operator', 'صالح المدعو 094', '774000094'
  );
  v_code := v_payload ->> 'code';

  if v_payload ->> 'outcome' = 'invited'
     and v_code ~ '^[0-9]{6}$'
     and (v_payload ->> 'invitation_id') is not null
  then
    raise notice 'PASS 10: دعوة رقم بلا حساب تُصدر رمزًا من ستة أرقام';
  else
    raise notice 'FAIL 10: حمولة الدعوة غير مطابقة: %', v_payload;
  end if;

  -- الدعوة صفر صلاحية: لا تعيين نافذ قبل المطالبة
  select count(*) into v_count
  from core.well_assignments wa
  where wa.well_id = v_well
    and wa.role = 'operator';

  if v_count = 0 then
    raise notice 'PASS 11: الدعوة بصفر صلاحية — لا تعيين قبل المطالبة';
  else
    raise notice 'FAIL 11: الدعوة أنشأت تعيينًا نافذًا قبل المطالبة';
  end if;

  -- ---------------------------------------------------------------
  -- 12. من له حساب بنفس الرقم يُربط فورًا بلا رمز
  -- ---------------------------------------------------------------

  v_payload := api.invite_well_member(
    v_well, 'operator', 'مشغّل قائم 094', '772000094'
  );

  select count(*) into v_count
  from core.well_assignments wa
  where wa.well_id = v_well
    and wa.profile_id = v_op2_user
    and wa.role = 'operator'
    and wa.status = 'active';

  if v_payload ->> 'outcome' = 'linked'
     and (v_payload ->> 'code') is null
     and v_count = 1
  then
    raise notice 'PASS 12: صاحب حساب قائم يُربط بلا رمز';
  else
    raise notice 'FAIL 12: ربط الحساب القائم غير مطابق: %', v_payload;
  end if;

  -- ---------------------------------------------------------------
  -- 13. المشغّل المدعو يُطالِب برقمه: التعيين يصير نافذًا
  -- ---------------------------------------------------------------

  execute 'reset role';
  update iam.profiles set phone = '774000094' where id = v_op_user;
  perform set_config('request.jwt.claim.sub', v_op_user::text, true);
  execute 'set local role authenticated';

  v_payload := api.claim_well_invitation(v_code);

  select count(*) into v_count
  from core.well_assignments wa
  where wa.well_id = v_well
    and wa.profile_id = v_op_user
    and wa.role = 'operator'
    and wa.status = 'active';

  if v_payload ->> 'outcome' = 'claimed'
     and (v_payload ->> 'well_id')::uuid = v_well
     and v_count = 1
  then
    raise notice 'PASS 13: المطالبة الصحيحة تُنشئ التعيين النافذ';
  else
    raise notice 'FAIL 13: المطالبة لم تُنشئ التعيين: %', v_payload;
  end if;

  -- ---------------------------------------------------------------
  -- 14. المطالبة بالرمز نفسه مرتين = تعيين واحد (Idempotency)
  -- ---------------------------------------------------------------

  v_payload2 := api.claim_well_invitation(v_code);

  select count(*) into v_count
  from core.well_assignments wa
  where wa.well_id = v_well
    and wa.profile_id = v_op_user
    and wa.role = 'operator';

  if v_payload2 ->> 'outcome' = 'already_claimed' and v_count = 1 then
    raise notice 'PASS 14: مطالبتان بالرمز نفسه تُنتجان تعيينًا واحدًا';
  else
    raise notice 'FAIL 14: التكرار أنتج أثرًا ثانيًا: % / %',
      v_payload2 ->> 'outcome', v_count;
  end if;

  -- ---------------------------------------------------------------
  -- 15. رمز خاطئ: يُعاد كحالة، ويخصم من العدّاد فعلًا (يبقى الخصم)
  -- ---------------------------------------------------------------

  execute 'reset role';

  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';

  v_payload := api.invite_well_member(
    v_well, 'partner', 'شريك مدعو 094', '775000094'
  );
  v_code := v_payload ->> 'code';

  execute 'reset role';
  update iam.profiles set phone = '775000094' where id = v_other_user;
  perform set_config('request.jwt.claim.sub', v_other_user::text, true);
  execute 'set local role authenticated';

  -- رمز مختلف حتمًا عن الصحيح: '000000' قد يصادفه باحتمال ضعيف.
  v_payload := api.claim_well_invitation(
    lpad(mod(v_code::bigint + 1, 1000000)::text, 6, '0')
  );

  execute 'reset role';
  select inv.attempts_left into v_count
  from core.well_invitations inv
  where inv.normalized_phone = core.normalize_phone('775000094')
    and inv.status = 'invited';

  if v_payload ->> 'outcome' = 'wrong_code'
     and (v_payload ->> 'attempts_left')::integer = 4
     and v_count = 4
  then
    raise notice 'PASS 15: الرمز الخاطئ حالة معلنة والخصم يبقى محفوظًا';
  else
    raise notice 'FAIL 15: الخصم لم يبقَ أو الحالة غير مطابقة: % / %',
      v_payload, v_count;
  end if;

  -- ---------------------------------------------------------------
  -- 16. رقم بلا دعوة: حالة معلنة لا تعيين ولا تسريب لحالة غيره
  -- ---------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_op2_user::text, true);
  execute 'set local role authenticated';

  v_payload := api.claim_well_invitation('123456');

  if v_payload ->> 'outcome' = 'no_invitation'
     and (v_payload ->> 'well_id') is null
  then
    raise notice 'PASS 16: رقم بلا دعوة سارية يُعلن الحالة بلا تفاصيل';
  else
    raise notice 'FAIL 16: حمولة «لا دعوة» غير مطابقة: %', v_payload;
  end if;

  -- ---------------------------------------------------------------
  -- 17. من لا يملك team.manage لا يدعو ولا يقرأ الفريق
  -- ---------------------------------------------------------------

  v_denied := false;
  begin
    perform api.invite_well_member(
      v_well, 'operator', 'دعوة ممنوعة 094', '776000094'
    );
  exception
    when others then
      v_denied := (sqlstate = '42501');
  end;

  if v_denied then
    raise notice 'PASS 17: المشغّل لا يدعو أعضاء (42501)';
  else
    raise notice 'FAIL 17: الدعوة نجحت لمن لا يملك team.manage';
  end if;

  v_denied := false;
  begin
    perform api.list_well_team(v_well);
  exception
    when others then
      v_denied := (sqlstate = '42501');
  end;

  if v_denied then
    raise notice 'PASS 18: المشغّل لا يقرأ قائمة الفريق (42501)';
  else
    raise notice 'FAIL 18: قراءة الفريق نجحت لمن لا يملكها';
  end if;

  -- ---------------------------------------------------------------
  -- 19. قراءة الفريق للمالك: أعضاء ودعوات، ولا رمز ولا تلبيدة
  -- ---------------------------------------------------------------

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';

  v_payload := api.list_well_team(v_well);

  if v_payload ->> 'contract' = 'list_well_team'
     and jsonb_array_length(v_payload -> 'members') >= 3
     and jsonb_array_length(v_payload -> 'invitations') >= 2
     and v_payload::text not like '%code_hash%'
     and v_payload::text not like '%code_salt%'
  then
    raise notice 'PASS 19: قراءة الفريق تعيد الأعضاء والدعوات بلا رمز';
  else
    raise notice 'FAIL 19: حمولة الفريق غير مطابقة: %',
      left(v_payload::text, 300);
  end if;

  -- ---------------------------------------------------------------
  -- 20. إعادة الدعوة تُبطل ما قبلها: رمز واحد صالح لكل (بئر، دور، رقم)
  -- ---------------------------------------------------------------

  perform api.invite_well_member(
    v_well, 'partner', 'شريك بلا حساب 094', '778000094'
  );
  perform api.invite_well_member(
    v_well, 'partner', 'شريك بلا حساب 094', '778000094'
  );

  execute 'reset role';
  select
    count(*) filter (where inv.status = 'invited'),
    count(*) filter (where inv.status = 'revoked')
  into v_count, v_count_2
  from core.well_invitations inv
  where inv.well_id = v_well
    and inv.role = 'partner'
    and inv.normalized_phone = core.normalize_phone('778000094');

  if v_count = 1 and v_count_2 = 1 then
    raise notice 'PASS 20: إعادة الدعوة تُبطل السابقة وتُبقي رمزًا واحدًا';
  else
    raise notice 'FAIL 20: حالة الدعوات بعد الإعادة: invited=% revoked=%',
      v_count, v_count_2;
  end if;

  -- ---------------------------------------------------------------
  -- 21. إلغاء الوصول: التعيين inactive والدعوة revoked بلا حذف
  -- ---------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';

  v_payload := api.revoke_well_member(v_well, 'operator', '774000094');

  execute 'reset role';
  select count(*) into v_count
  from core.well_assignments wa
  where wa.well_id = v_well
    and wa.profile_id = v_op_user
    and wa.role = 'operator'
    and wa.status = 'inactive';

  select count(*) into v_count_2
  from core.well_assignments wa
  where wa.well_id = v_well
    and wa.profile_id = v_op_user;

  if v_count = 1 and v_count_2 = 1
     and (v_payload ->> 'deactivated_assignments')::integer = 1
  then
    raise notice 'PASS 21: إلغاء الوصول يوقف التعيين ولا يحذف صفًّا';
  else
    raise notice 'FAIL 21: الإلغاء حذف أو لم يوقف: % / % / %',
      v_count, v_count_2, v_payload;
  end if;

  -- ---------------------------------------------------------------
  -- 22. الدعوة المنتهية لا تُطالَب بها
  -- ---------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';

  v_payload := api.invite_well_member(
    v_well, 'operator', 'دعوة منتهية 094', '777000094'
  );
  v_code := v_payload ->> 'code';

  execute 'reset role';
  update core.well_invitations
  set expires_at = now() - interval '1 day'
  where normalized_phone = core.normalize_phone('777000094')
    and status = 'invited';

  update iam.profiles set phone = '777000094' where id = v_op2_user;
  perform set_config('request.jwt.claim.sub', v_op2_user::text, true);
  execute 'set local role authenticated';

  v_payload := api.claim_well_invitation(v_code);

  execute 'reset role';
  select count(*) into v_count
  from core.well_invitations inv
  where inv.normalized_phone = core.normalize_phone('777000094')
    and inv.status = 'expired';

  if v_payload ->> 'outcome' = 'no_invitation' and v_count = 1 then
    raise notice 'PASS 22: الدعوة المنتهية تُوسم منتهية ولا تُطالَب بها';
  else
    raise notice 'FAIL 22: المنتهية قُبلت أو لم تُوسم: % / %',
      v_payload ->> 'outcome', v_count;
  end if;

  raise notice '094 DONE';
end;
$test$;

rollback;
