-- ق-130 / م-44: Trusted pre-auth member finalization بلا Auth يتيم.
-- هذا اختبار DB فقط؛ إنشاء auth.users fixture يحاكي نتيجة Admin createUser
-- لا استدعاء شبكة Auth، وكل التغييرات تتراجع في النهاية.

\set ON_ERROR_STOP on

begin;

do $test$
declare
  v_api_validate oid := to_regprocedure(
    'api.validate_member_finalization(text, text)'
  );
  v_api_prepare oid := to_regprocedure(
    'api.prepare_member_finalization(text)'
  );
  v_api_complete oid := to_regprocedure(
    'api.complete_member_finalization(text, uuid)'
  );
  v_core_validate oid := to_regprocedure(
    'core.validate_member_finalization(text, text)'
  );
  v_core_prepare oid := to_regprocedure(
    'core.prepare_member_finalization(text)'
  );
  v_core_complete oid := to_regprocedure(
    'core.complete_member_finalization(text, uuid)'
  );
  v_owner uuid;
  v_existing uuid;
  v_wrong_phone_profile uuid;
  v_conflict_profile uuid;
  v_final_profile uuid;
  v_partner_profile uuid;
  v_tenant uuid;
  v_well uuid;
  v_operator_invitation uuid;
  v_expired_invitation uuid;
  v_revoked_invitation uuid;
  v_existing_invitation uuid;
  v_existing_reject_invitation uuid;
  v_wrong_phone_invitation uuid;
  v_conflict_invitation uuid;
  v_partner_invitation uuid;
  v_inactive_partner_invitation uuid;
  v_inactive_person_invitation uuid;
  v_partner_person uuid;
  v_partner_id uuid;
  v_inactive_partner_person uuid;
  v_inactive_partner_id uuid;
  v_conflict_person uuid;
  v_inactive_person uuid;
  v_payload jsonb;
  v_prepare jsonb;
  v_code text;
  v_wrong_code text;
  v_token text;
  v_first_token text;
  v_wrong_phone_token text;
  v_conflict_token text;
  v_partner_token text;
  v_inactive_partner_token text;
  v_person_id uuid;
  v_count integer;
  v_count_2 integer;
  v_count_3 integer;
  v_assignment_count integer;
  v_auth_before integer;
  v_share_count integer;
  v_denied boolean;
  v_status text;
  v_src text;
begin
  -- -------------------------------------------------------------
  -- 1. البنية والصلاحيات: العقود الخدمية فقط، ولا تخزين plaintext.
  -- -------------------------------------------------------------
  select count(*) into v_count
  from information_schema.columns c
  where c.table_schema = 'core'
    and c.table_name = 'well_invitations'
    and c.column_name in (
      'acceptance_kind', 'continuation_token_salt',
      'continuation_token_hash', 'continuation_expires_at'
    );

  select count(*) into v_count_2
  from pg_constraint c
  join pg_class t on t.oid = c.conrelid
  join pg_namespace n on n.oid = t.relnamespace
  where n.nspname = 'core'
    and t.relname = 'well_invitations'
    and c.conname = 'well_invitations_status_check'
    and pg_get_constraintdef(c.oid) like '%owner_confirmed_pending_account%';

  if v_count = 4 and v_count_2 = 1 then
    raise notice 'PASS 1: حالة new/no-Auth وأسرار الاستمرار الملبدة موجودة';
  else
    raise notice 'FAIL 1: بنية Migration 104 ناقصة: % / %', v_count, v_count_2;
  end if;

  select count(*) into v_count
  from pg_index i
  where i.indrelid = 'core.well_invitations'::regclass
    and i.indisunique
    and pg_get_expr(i.indpred, i.indrelid) like '%owner_confirmed_pending_account%'
    and pg_get_expr(i.indpred, i.indrelid) like '%accepted_pending_owner%'
    and pg_get_expr(i.indpred, i.indrelid) like '%invited%';

  select pg_get_functiondef(v_core_complete) into v_src;
  if v_count = 1
     and not has_function_privilege('anon', v_api_validate, 'EXECUTE')
     and not has_function_privilege('authenticated', v_api_validate, 'EXECUTE')
     and not has_function_privilege('anon', v_api_prepare, 'EXECUTE')
     and not has_function_privilege('authenticated', v_api_prepare, 'EXECUTE')
     and not has_function_privilege('anon', v_api_complete, 'EXECUTE')
     and not has_function_privilege('authenticated', v_api_complete, 'EXECUTE')
     and has_function_privilege('service_role', v_api_validate, 'EXECUTE')
     and has_function_privilege('service_role', v_api_prepare, 'EXECUTE')
     and has_function_privilege('service_role', v_api_complete, 'EXECUTE')
     and (select prosecdef from pg_proc where oid = v_core_validate)
     and (select prosecdef from pg_proc where oid = v_core_prepare)
     and (select prosecdef from pg_proc where oid = v_core_complete)
     and not (select prosecdef from pg_proc where oid = v_api_validate)
     and not (select prosecdef from pg_proc where oid = v_api_prepare)
     and not (select prosecdef from pg_proc where oid = v_api_complete)
     and exists (
       select 1 from pg_proc p, unnest(coalesce(p.proconfig, array[]::text[])) cfg
       where p.oid = v_core_validate and cfg like 'search_path=%'
     )
     and exists (
       select 1 from pg_proc p, unnest(coalesce(p.proconfig, array[]::text[])) cfg
       where p.oid = v_core_prepare and cfg like 'search_path=%'
     )
     and exists (
       select 1 from pg_proc p, unnest(coalesce(p.proconfig, array[]::text[])) cfg
       where p.oid = v_core_complete and cfg like 'search_path=%'
     )
  then
    raise notice 'PASS 2: حارس الدعوات المفتوحة وعقود service_role فقط صحيحان';
  else
    raise notice 'FAIL 2: الحارس أو صلاحيات finalization غير آمنة';
  end if;

  -- -------------------------------------------------------------
  -- 2. Fixture: مالك وحساب قائم فقط؛ لا حسابات لأرقام new/no-Auth.
  -- -------------------------------------------------------------
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'm104-owner@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now(),
    jsonb_build_object('full_name', 'مالك 104', 'phone', '770104001')
  ) returning id into v_owner;

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'm104-existing@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now(),
    jsonb_build_object('full_name', 'حساب قائم 104', 'phone', '777104090')
  ) returning id into v_existing;

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'm104-wrong-phone@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now(),
    jsonb_build_object('full_name', 'هاتف خاطئ 104', 'phone', '777104091')
  ) returning id into v_wrong_phone_profile;

  update iam.profiles set phone = '770104001' where id = v_owner;
  update iam.profiles set phone = '777104090' where id = v_existing;
  update iam.profiles set phone = '777104091' where id = v_wrong_phone_profile;

  insert into core.tenants (name) values ('جهة finalization 104')
  returning id into v_tenant;
  insert into core.wells (tenant_id, name, location)
  values (v_tenant, 'بئر finalization 104', 'موقع 104')
  returning id into v_well;
  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_well, v_owner, 'owner', 'active');

  select count(*) into v_auth_before from auth.users;

  -- -------------------------------------------------------------
  -- 3. رمز خاطئ، منتهية، وملغاة: لا قبول ولا Auth ولا وصول.
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';
  v_payload := api.invite_well_member(
    v_well, 'operator', 'عضو رمز خاطئ 104', '777104001'
  );
  v_operator_invitation := (v_payload ->> 'invitation_id')::uuid;
  v_code := v_payload ->> 'code';
  v_wrong_code := case when v_code = '000000' then '000001' else '000000' end;

  execute 'reset role';
  execute 'set local role service_role';
  v_payload := api.validate_member_finalization('777104001', v_wrong_code);
  execute 'reset role';

  select count(*) into v_count
  from core.well_invitations
  where id = v_operator_invitation
    and status = 'invited'
    and attempts_left = 4
    and accepted_at is null;
  select count(*) into v_count_2 from auth.users;
  select count(*) into v_count_3 from core.well_assignments
  where well_id = v_well and role = 'operator';

  if v_payload ->> 'outcome' = 'wrong_code'
     and v_count = 1 and v_count_2 = v_auth_before and v_count_3 = 0
  then
    raise notice 'PASS 3: الرمز الخاطئ يخصم محاولة ولا يقبل أو ينشئ Auth';
  else
    raise notice 'FAIL 3: الرمز الخاطئ غيّر حالة غير آمنة: % / % / % / %',
      v_payload, v_count, v_count_2, v_count_3;
  end if;

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';
  v_payload := api.invite_well_member(
    v_well, 'operator', 'عضو منتهي 104', '777104002'
  );
  v_expired_invitation := (v_payload ->> 'invitation_id')::uuid;
  v_code := v_payload ->> 'code';
  execute 'reset role';
  update core.well_invitations
  set expires_at = now() - interval '1 second'
  where id = v_expired_invitation;
  execute 'set local role service_role';
  v_payload := api.validate_member_finalization('777104002', v_code);
  execute 'reset role';
  select count(*) into v_count
  from core.well_invitations
  where id = v_expired_invitation and status = 'expired' and accepted_at is null;

  if v_payload ->> 'outcome' = 'expired' and v_count = 1 then
    raise notice 'PASS 4: الدعوة المنتهية لا تدخل مسار new/no-Auth';
  else
    raise notice 'FAIL 4: الدعوة المنتهية قبلت أو لم توسّم: % / %', v_payload, v_count;
  end if;

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';
  v_payload := api.invite_well_member(
    v_well, 'operator', 'عضو ملغى 104', '777104003'
  );
  v_revoked_invitation := (v_payload ->> 'invitation_id')::uuid;
  v_code := v_payload ->> 'code';
  execute 'reset role';
  update core.well_invitations
  set status = 'revoked', revoked_at = now()
  where id = v_revoked_invitation;
  execute 'set local role service_role';
  v_payload := api.validate_member_finalization('777104003', v_code);
  execute 'reset role';
  select count(*) into v_count
  from core.well_invitations
  where id = v_revoked_invitation and status = 'revoked' and accepted_at is null;

  if v_payload ->> 'outcome' in ('revoked', 'no_invitation') and v_count = 1 then
    raise notice 'PASS 5: الدعوة الملغاة لا تدخل مسار new/no-Auth';
  else
    raise notice 'FAIL 5: الدعوة الملغاة قبلت: % / %', v_payload, v_count;
  end if;

  -- -------------------------------------------------------------
  -- 4. مسار member الجديد: قبول بلا Profile ثم تأكيد مالك بلا Assignment.
  -- -------------------------------------------------------------
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';
  v_payload := api.invite_well_member(
    v_well, 'operator', 'عضو جديد 104', '+967 777-104-010'
  );
  v_operator_invitation := (v_payload ->> 'invitation_id')::uuid;
  v_code := v_payload ->> 'code';
  execute 'reset role';
  execute 'set local role service_role';
  v_payload := api.validate_member_finalization('777104010', v_code);
  v_token := v_payload ->> 'continuation_token';
  execute 'reset role';

  select count(*) into v_count
  from core.well_invitations inv
  where inv.id = v_operator_invitation
    and inv.status = 'accepted_pending_owner'
    and inv.acceptance_kind = 'new_no_auth'
    and inv.accepted_profile_id is null
    and inv.accepted_at is not null
    and inv.continuation_token_hash is not null
    and inv.continuation_token_salt is not null
    and inv.continuation_token_hash <> v_token
    and inv.continuation_token_salt <> v_token;
  select count(*) into v_count_2
  from core.well_assignments wa
  where wa.well_id = v_well and wa.role = 'operator'
    and wa.profile_id not in (v_owner, v_existing, v_wrong_phone_profile);

  if v_payload ->> 'outcome' = 'accepted_pending_owner'
     and length(v_token) >= 48 and v_count = 1 and v_count_2 = 0
  then
    raise notice 'PASS 6: pre-auth الصحيح يقبل new/no-Auth بلا Profile أو Assignment ولا token plaintext';
  else
    raise notice 'FAIL 6: pre-auth الصحيح ترك أثر وصول أو سرًا صريحًا: % / % / %',
      v_payload, v_count, v_count_2;
  end if;

  -- بعد القبول يحكم token القصير المسار، لا expires_at الأصلي للدعوة.
  v_first_token := v_token;
  update core.well_invitations
  set expires_at = now() - interval '1 second'
  where id = v_operator_invitation;

  v_wrong_code := case
    when v_code = '000000' then '000001'
    else '000000'
  end;
  execute 'set local role service_role';
  v_payload := api.validate_member_finalization(
    '777104010',
    v_wrong_code
  );
  execute 'reset role';

  select count(*) into v_count
  from core.well_invitations inv
  where inv.id = v_operator_invitation
    and inv.status = 'accepted_pending_owner'
    and inv.attempts_left = 4
    and inv.continuation_token_hash =
      core.hash_member_finalization_token(
        v_first_token,
        inv.continuation_token_salt
      );

  if v_payload ->> 'outcome' = 'wrong_code' and v_count = 1 then
    raise notice 'PASS 6A: الرمز الخطأ بعد القبول يخصم محاولة ولا يدور token';
  else
    raise notice 'FAIL 6A: حماية المحاولات تعطلت بعد انتهاء الدعوة: % / %',
      v_payload, v_count;
  end if;

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';
  v_payload := api.confirm_well_invitation(v_operator_invitation);
  execute 'reset role';
  select count(*) into v_count
  from core.well_invitations inv
  where inv.id = v_operator_invitation
    and inv.status = 'owner_confirmed_pending_account'
    and inv.acceptance_kind = 'new_no_auth'
    and inv.accepted_profile_id is null
    and inv.confirmed_by = v_owner
    and inv.confirmed_at is not null;
  select count(*) into v_count_2 from core.well_assignments
  where well_id = v_well and role = 'operator';
  select count(*) into v_count_3 from iam.profile_person_links l
  join core.well_invitations inv on inv.person_id = l.person_id
  where inv.id = v_operator_invitation and l.revoked_at is null;

  if v_payload ->> 'outcome' = 'owner_confirmed_pending_account'
     and v_count = 1 and v_count_2 = 0 and v_count_3 = 0
  then
    raise notice 'PASS 7: تأكيد المالك يبقي new/no-Auth بلا Assignment أو Profile';
  else
    raise notice 'FAIL 7: تأكيد المالك فعّل الوصول مبكرًا: % / % / %',
      v_payload, v_count, v_count_2;
  end if;

  execute 'set local role service_role';
  v_payload := api.validate_member_finalization('777104010', v_code);
  v_token := v_payload ->> 'continuation_token';
  execute 'reset role';

  select count(*) into v_count
  from core.well_invitations inv
  where inv.id = v_operator_invitation
    and inv.status = 'owner_confirmed_pending_account'
    and inv.acceptance_kind = 'new_no_auth'
    and inv.expires_at <= now()
    and inv.continuation_expires_at > now()
    and inv.continuation_token_hash =
      core.hash_member_finalization_token(
        v_token,
        inv.continuation_token_salt
      );

  if v_payload ->> 'outcome' = 'owner_confirmed_pending_account'
     and v_token is not null
     and v_token <> v_first_token
     and v_count = 1
  then
    raise notice 'PASS 7A: confirmed lifecycle يدور token بعد انتهاء الدعوة';
  else
    raise notice 'FAIL 7A: انتهاء الدعوة قتل lifecycle المؤكد: % / %',
      v_payload, v_count;
  end if;

  execute 'set local role service_role';
  v_prepare := api.prepare_member_finalization(v_token);
  execute 'reset role';
  if v_prepare ->> 'outcome' = 'ready'
     and (v_prepare ->> 'person_id') is not null
     and v_prepare::text not like '%' || v_token || '%'
     and v_prepare::text not like '%continuation_token_hash%'
  then
    raise notice 'PASS 8: preparation تعيد binding الأدنى بلا سر continuation';
  else
    raise notice 'FAIL 8: preparation غير مقيدة أو سرّبت سرًا: %', v_prepare;
  end if;

  -- يمثل هذا insert نتيجة Admin createUser بعد preparation، لا API شبكة.
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', '777104010@phone.wellirrigation.app',
    crypt('x', gen_salt('bf')), now(), now(), now(),
    jsonb_build_object('full_name', 'عضو جديد 104', 'phone', '777104010')
  ) returning id into v_final_profile;
  update iam.profiles set phone = '777104010' where id = v_final_profile;

  execute 'set local role service_role';
  v_payload := api.complete_member_finalization(v_token, v_final_profile);
  execute 'reset role';
  select person_id into v_person_id from core.well_invitations where id = v_operator_invitation;
  select count(*) into v_count from iam.profile_person_links l
  where l.tenant_id = v_tenant and l.profile_id = v_final_profile
    and l.person_id = v_person_id and l.revoked_at is null;
  select count(*) into v_count_2 from core.well_assignments wa
  where wa.well_id = v_well and wa.profile_id = v_final_profile
    and wa.role = 'operator' and wa.status = 'active';

  if v_payload ->> 'outcome' = 'confirmed'
     and v_count = 1 and v_count_2 = 1
     and exists (
       select 1 from core.well_invitations inv
       where inv.id = v_operator_invitation and inv.status = 'confirmed'
         and inv.accepted_profile_id = v_final_profile
         and inv.continuation_token_hash is null
         and inv.continuation_token_salt is null
     )
  then
    raise notice 'PASS 9: completion تربط Person صراحة وتفعّل Assignment واحدًا وتستهلك token';
  else
    raise notice 'FAIL 9: completion لم تحفظ الربط أو الصلاحية الصحيحة: % / % / %',
      v_payload, v_count, v_count_2;
  end if;

  execute 'set local role service_role';
  v_payload := api.complete_member_finalization(v_token, v_final_profile);
  execute 'reset role';
  select count(*) into v_count from iam.profile_person_links
  where profile_id = v_final_profile and revoked_at is null;
  select count(*) into v_count_2 from core.well_assignments
  where well_id = v_well and profile_id = v_final_profile and role = 'operator';
  if v_payload ->> 'outcome' = 'already_completed' and v_count = 1 and v_count_2 = 1 then
    raise notice 'PASS 10: completion المكرر idempotent بلا رابط أو Assignment ثانٍ';
  else
    raise notice 'FAIL 10: completion المكرر غيّر الأثر: % / % / %', v_payload, v_count, v_count_2;
  end if;

  -- -------------------------------------------------------------
  -- 5. حساب قائم لا يسلك new/no-Auth، وM103 يبقى كما هو.
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';
  v_payload := api.invite_well_member(
    v_well, 'operator', 'حساب قائم 104', '777104090'
  );
  v_existing_invitation := (v_payload ->> 'invitation_id')::uuid;
  v_code := v_payload ->> 'code';
  execute 'reset role';
  execute 'set local role service_role';
  v_payload := api.validate_member_finalization('777104090', v_code);
  execute 'reset role';
  select status into v_status from core.well_invitations where id = v_existing_invitation;

  if v_payload ->> 'outcome' = 'existing_account' and v_status = 'invited' then
    raise notice 'PASS 11: حساب قائم لا يتحول إلى new/no-Auth';
  else
    raise notice 'FAIL 11: حساب قائم دخل مسار finalization: % / %', v_payload, v_status;
  end if;

  perform set_config('request.jwt.claim.sub', v_existing::text, true);
  execute 'set local role authenticated';
  perform api.accept_well_invitation(v_existing_invitation);
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';
  v_payload := api.confirm_well_invitation(v_existing_invitation);
  execute 'reset role';
  select count(*) into v_count from core.well_assignments
  where well_id = v_well and profile_id = v_existing
    and role = 'operator' and status = 'active';
  if v_payload ->> 'outcome' = 'confirmed' and v_count = 1 then
    raise notice 'PASS 12: قبول/تأكيد الحساب القائم في M103 بقي دون تغيير';
  else
    raise notice 'FAIL 12: M103 existing-account انكسر: % / %', v_payload, v_count;
  end if;

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';
  v_payload := api.invite_well_member(
    v_well, 'operator', 'رفض حساب قائم 104', '777104091'
  );
  v_existing_reject_invitation := (v_payload ->> 'invitation_id')::uuid;
  execute 'reset role';

  perform set_config('request.jwt.claim.sub', v_wrong_phone_profile::text, true);
  execute 'set local role authenticated';
  perform api.accept_well_invitation(v_existing_reject_invitation);
  execute 'reset role';

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';
  v_payload := api.reject_well_invitation(v_existing_reject_invitation);
  execute 'reset role';

  select count(*) into v_count
  from core.well_assignments wa
  where wa.well_id = v_well
    and wa.profile_id = v_wrong_phone_profile
    and wa.role = 'operator';
  select status into v_status
  from core.well_invitations
  where id = v_existing_reject_invitation;

  if v_payload ->> 'contract' = 'reject_well_invitation'
     and (v_payload ->> 'version')::integer = 2
     and v_payload ->> 'outcome' = 'rejected'
     and v_status = 'rejected'
     and v_count = 0
  then
    raise notice 'PASS 12A: رفض existing_auth يحافظ على عقد M103 version=2';
  else
    raise notice 'FAIL 12A: إصدار رفض existing_auth أو أثره تغير: % / % / %',
      v_payload, v_status, v_count;
  end if;

  -- -------------------------------------------------------------
  -- 6. completion يرفض هاتف Profile الخاطئ ورابط Person المتعارض.
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';
  v_payload := api.invite_well_member(
    v_well, 'operator', 'هاتف completion خاطئ 104', '777104020'
  );
  v_wrong_phone_invitation := (v_payload ->> 'invitation_id')::uuid;
  v_code := v_payload ->> 'code';
  execute 'reset role';
  execute 'set local role service_role';
  v_payload := api.validate_member_finalization('777104020', v_code);
  v_wrong_phone_token := v_payload ->> 'continuation_token';
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';
  perform api.confirm_well_invitation(v_wrong_phone_invitation);
  execute 'reset role';
  execute 'set local role service_role';
  v_denied := false;
  begin
    perform api.complete_member_finalization(v_wrong_phone_token, v_wrong_phone_profile);
  exception when others then
    v_denied := sqlstate = '42501';
  end;
  execute 'reset role';
  select count(*) into v_count from core.well_assignments
  where well_id = v_well and profile_id = v_wrong_phone_profile and role = 'operator';
  select status into v_status from core.well_invitations where id = v_wrong_phone_invitation;
  if v_denied and v_count = 0 and v_status = 'owner_confirmed_pending_account' then
    raise notice 'PASS 13: Profile صاحب الهاتف الخطأ لا يكمل ولا ينال وصولًا';
  else
    raise notice 'FAIL 13: Profile الخطأ أكمل finalization: % / % / %', v_denied, v_count, v_status;
  end if;

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';
  v_payload := api.invite_well_member(
    v_well, 'operator', 'رابط متعارض 104', '777104021'
  );
  v_conflict_invitation := (v_payload ->> 'invitation_id')::uuid;
  v_code := v_payload ->> 'code';
  execute 'reset role';
  execute 'set local role service_role';
  v_payload := api.validate_member_finalization('777104021', v_code);
  v_conflict_token := v_payload ->> 'continuation_token';
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';
  perform api.confirm_well_invitation(v_conflict_invitation);
  execute 'reset role';
  execute 'set local role service_role';
  perform api.prepare_member_finalization(v_conflict_token);
  execute 'reset role';
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', '777104021@phone.wellirrigation.app',
    crypt('x', gen_salt('bf')), now(), now(), now(),
    jsonb_build_object('full_name', 'رابط متعارض 104', 'phone', '777104021')
  ) returning id into v_conflict_profile;
  update iam.profiles set phone = '777104021' where id = v_conflict_profile;
  insert into core.persons (tenant_id, full_name, normalized_name, created_by, updated_by)
  values (v_tenant, 'Person متعارض 104', 'person متعارض 104', v_owner, v_owner)
  returning id into v_conflict_person;
  insert into iam.profile_person_links (
    tenant_id, profile_id, person_id, linked_by, link_reason
  ) values (
    v_tenant, v_conflict_profile, v_conflict_person, v_owner, 'fixture_conflict_104'
  );
  execute 'set local role service_role';
  v_denied := false;
  begin
    perform api.complete_member_finalization(v_conflict_token, v_conflict_profile);
  exception when others then
    v_denied := sqlstate in ('42501', 'P0001');
  end;
  execute 'reset role';
  select count(*) into v_count from core.well_assignments
  where well_id = v_well and profile_id = v_conflict_profile and role = 'operator';
  if v_denied and v_count = 0 then
    raise notice 'PASS 14: رابط Profile/Person المتعارض يفشل مغلقًا';
  else
    raise notice 'FAIL 14: رابط الهوية المتعارض منح وصولًا: % / %', v_denied, v_count;
  end if;

  -- -------------------------------------------------------------
  -- 7. Partner: نفس السجل المالي النشط فقط؛ غير النشط يفشل مغلقًا.
  -- -------------------------------------------------------------
  insert into core.persons (tenant_id, full_name, normalized_name, created_by, updated_by)
  values (v_tenant, 'شريك جديد 104', 'شريك جديد 104', v_owner, v_owner)
  returning id into v_partner_person;
  insert into core.person_contacts (
    tenant_id, person_id, contact_type, contact_value, normalized_value, is_primary
  ) values (v_tenant, v_partner_person, 'mobile', '+967 777-104-030', '+967 777-104-030', true);
  insert into core.well_partners (
    tenant_id, well_id, person_id, phone, status, period_start
  ) values (
    v_tenant, v_well, v_partner_person, '+967 777-104-030', 'active', current_date
  ) returning id into v_partner_id;
  insert into core.ownership_share_versions (
    tenant_id, well_id, partner_id, ownership_percentage, profit_percentage,
    effective_period, approved_by
  ) values (
    v_tenant, v_well, v_partner_id, 100, 100, daterange(current_date, null), v_owner
  );

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';
  v_payload := api.invite_well_member(
    v_well, 'partner', 'شريك جديد 104', '777104030'
  );
  v_partner_invitation := (v_payload ->> 'invitation_id')::uuid;
  v_code := v_payload ->> 'code';
  execute 'reset role';
  execute 'set local role service_role';
  v_payload := api.validate_member_finalization('777104030', v_code);
  v_partner_token := v_payload ->> 'continuation_token';
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';
  perform api.confirm_well_invitation(v_partner_invitation);
  execute 'reset role';
  execute 'set local role service_role';
  perform api.prepare_member_finalization(v_partner_token);
  execute 'reset role';
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', '777104030@phone.wellirrigation.app',
    crypt('x', gen_salt('bf')), now(), now(), now(),
    jsonb_build_object('full_name', 'شريك جديد 104', 'phone', '777104030')
  ) returning id into v_partner_profile;
  update iam.profiles set phone = '777104030' where id = v_partner_profile;
  execute 'set local role service_role';
  v_payload := api.complete_member_finalization(v_partner_token, v_partner_profile);
  execute 'reset role';
  select count(*) into v_count from core.well_partners wp
  where wp.id = v_partner_id and wp.profile_id = v_partner_profile
    and wp.status = 'active' and wp.period_end is null;
  select count(*) into v_count_2 from core.well_assignments wa
  where wa.well_id = v_well and wa.profile_id = v_partner_profile
    and wa.role = 'partner' and wa.status = 'active';
  select count(*) into v_share_count from core.ownership_share_versions
  where partner_id = v_partner_id and ownership_percentage = 100 and profit_percentage = 100;
  select count(*) into v_count_3 from core.well_partners wp
  where wp.well_id = v_well and wp.person_id = v_partner_person;
  if v_payload ->> 'outcome' = 'confirmed'
     and v_count = 1 and v_count_2 = 1 and v_count_3 = 1
     and v_share_count = 1
  then
    raise notice 'PASS 15: Partner النشط يربط السجل نفسه ويحفظ تاريخه المالي';
  else
    raise notice 'FAIL 15: finalization الشريك غيّر Partner أو المال: % / % / % / % / %',
      v_payload, v_count, v_count_2, v_count_3, v_share_count;
  end if;

  insert into core.persons (tenant_id, full_name, normalized_name, created_by, updated_by)
  values (v_tenant, 'شريك غير فعال 104', 'شريك غير فعال 104', v_owner, v_owner)
  returning id into v_inactive_partner_person;
  insert into core.person_contacts (
    tenant_id, person_id, contact_type, contact_value, normalized_value, is_primary
  ) values (v_tenant, v_inactive_partner_person, 'mobile', '777104031', '777104031', true);
  insert into core.well_partners (
    tenant_id, well_id, person_id, phone, status, period_start
  ) values (
    v_tenant, v_well, v_inactive_partner_person, '777104031', 'inactive', current_date
  ) returning id into v_inactive_partner_id;
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';
  v_payload := api.invite_well_member(
    v_well, 'partner', 'شريك غير فعال 104', '777104031'
  );
  v_inactive_partner_invitation := (v_payload ->> 'invitation_id')::uuid;
  v_code := v_payload ->> 'code';
  execute 'reset role';
  execute 'set local role service_role';
  v_payload := api.validate_member_finalization('777104031', v_code);
  v_inactive_partner_token := v_payload ->> 'continuation_token';
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';
  perform api.confirm_well_invitation(v_inactive_partner_invitation);
  execute 'reset role';
  execute 'set local role service_role';
  v_denied := false;
  begin
    perform api.prepare_member_finalization(v_inactive_partner_token);
  exception when others then
    v_denied := sqlstate = 'P0001';
  end;
  execute 'reset role';
  select count(*) into v_count from core.well_assignments wa
  where wa.well_id = v_well and wa.role = 'partner'
    and wa.profile_id = coalesce((select accepted_profile_id from core.well_invitations where id = v_inactive_partner_invitation), gen_random_uuid());
  if v_denied
     and v_count = 0
     and exists (
       select 1 from core.well_partners wp
       where wp.id = v_inactive_partner_id and wp.status = 'inactive'
         and wp.period_end is null and wp.profile_id is null
     )
  then
    raise notice 'PASS 16: Partner غير النشط لا يعاد تنشيطه ولا يكمل';
  else
    raise notice 'FAIL 16: Partner غير النشط مرّ finalization: % / %', v_denied, v_count;
  end if;

  -- -------------------------------------------------------------
  -- 8. Person غير نشط والحارس الفريد في owner_confirmed_pending_account.
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';
  v_payload := api.invite_well_member(
    v_well, 'operator', 'Person غير نشط 104', '777104040'
  );
  v_inactive_person_invitation := (v_payload ->> 'invitation_id')::uuid;
  v_code := v_payload ->> 'code';
  execute 'reset role';
  select person_id into v_inactive_person from core.well_invitations where id = v_inactive_person_invitation;
  select count(*) into v_assignment_count from core.well_assignments where well_id = v_well;
  update core.persons set status = 'inactive' where id = v_inactive_person;
  execute 'set local role service_role';
  v_denied := false;
  begin
    perform api.validate_member_finalization('777104040', v_code);
  exception when others then
    v_denied := sqlstate = 'P0001';
  end;
  execute 'reset role';
  select count(*) into v_count from core.persons where id = v_inactive_person and status = 'inactive';
  select count(*) into v_count_2 from core.well_assignments where well_id = v_well;
  if v_denied and v_count = 1 and v_count_2 = v_assignment_count then
    raise notice 'PASS 17: Person غير النشط لا يدمج أو يحيى أو يمنح وصولًا';
  else
    raise notice 'FAIL 17: Person غير النشط غيّر الهوية أو الوصول: % / % / %',
      v_denied, v_count, v_count_2;
  end if;

  -- الحارس في الحالة الجديدة لا يعتمد على ترتيب استدعاءات API.
  v_denied := false;
  begin
    insert into core.well_invitations (
      tenant_id, well_id, role, person_id, phone, normalized_phone,
      code_salt, code_hash, expires_at, invited_by, status
    )
    select tenant_id, well_id, role, person_id, phone, normalized_phone,
           'race-104', core.hash_invitation_code('123456', 'race-104'),
           now() + interval '1 day', invited_by, 'invited'
    from core.well_invitations
    where id = v_wrong_phone_invitation;
  exception when unique_violation then
    v_denied := true;
  end;
  if v_denied then
    raise notice 'PASS 18: owner_confirmed_pending_account داخل حارس الدعوات المفتوحة';
  else
    raise notice 'FAIL 18: أمكن فتح دعوة موازية للحالة pending account';
  end if;

  raise notice '104 DONE';
end;
$test$;

rollback;
