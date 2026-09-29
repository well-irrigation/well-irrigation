-- ق-130 / م-44: دورة دعوة الحساب القائم ثم قبول صاحب الحساب وتأكيد المالك.
-- هذا اختبار دائم للهجرة 103؛ لا يقرأ أسرار الدعوة ولا يمنح القبول وصولًا.

\set ON_ERROR_STOP on

begin;

do $test$
declare
  v_core_invite oid := to_regprocedure(
    'core.invite_well_member(uuid, text, text, text)'
  );
  v_core_claim oid := to_regprocedure('core.claim_well_invitation(text)');
  v_core_accept oid := to_regprocedure(
    'core.accept_well_invitation(uuid)'
  );
  v_core_confirm oid := to_regprocedure(
    'core.confirm_well_invitation(uuid)'
  );
  v_core_reject oid := to_regprocedure(
    'core.reject_well_invitation(uuid)'
  );
  v_core_list_my oid := to_regprocedure(
    'core.list_my_well_invitations()'
  );
  v_core_read oid := to_regprocedure('core.read_well_team(uuid)');
  v_api_invite oid := to_regprocedure(
    'api.invite_well_member(uuid, text, text, text)'
  );
  v_api_claim oid := to_regprocedure('api.claim_well_invitation(text)');
  v_api_accept oid := to_regprocedure(
    'api.accept_well_invitation(uuid)'
  );
  v_api_confirm oid := to_regprocedure(
    'api.confirm_well_invitation(uuid)'
  );
  v_api_reject oid := to_regprocedure(
    'api.reject_well_invitation(uuid)'
  );
  v_api_list_my oid := to_regprocedure(
    'api.list_my_well_invitations()'
  );
  v_api_team oid := to_regprocedure('api.list_well_team(uuid)');
  v_owner_user uuid;
  v_member_user uuid;
  v_other_user uuid;
  v_partner_user uuid;
  v_reject_user uuid;
  v_tenant uuid;
  v_well uuid;
  v_partner_person uuid;
  v_partner_id uuid;
  v_ended_partner_id uuid;
  v_ended_partner_activated_at timestamptz;
  v_operator_invitation uuid;
  v_partner_invitation uuid;
  v_reject_invitation uuid;
  v_reuse_invitation uuid;
  v_legacy_invitation uuid;
  v_historical_invitation uuid;
  v_inactive_person uuid;
  v_ambiguous_person_a uuid;
  v_ambiguous_person_b uuid;
  v_payload jsonb;
  v_revoke_payload jsonb;
  v_team jsonb;
  v_code text;
  v_norm text;
  v_count integer;
  v_count_2 integer;
  v_partner_count integer;
  v_ended_partner_count integer;
  v_assignment_count integer;
  v_share_count integer;
  v_share_ownership numeric;
  v_share_profit numeric;
  v_src text;
  v_denied boolean;
  v_historical_person uuid;
begin
  -- ---------------------------------------------------------------
  -- 1. بنية الهجرة: الحالات، التدقيق، العزل، وخصائص الأمن.
  -- ---------------------------------------------------------------

  select count(*) into v_count
  from information_schema.columns c
  where c.table_schema = 'core'
    and c.table_name = 'well_invitations'
    and c.column_name in (
      'accepted_profile_id', 'accepted_at', 'confirmed_by', 'confirmed_at',
      'rejected_by', 'rejected_at'
    );

  if v_count = 6 then
    raise notice 'PASS 1: أعمدة قبول وتأكيد ورفض المالك موجودة';
  else
    raise notice 'FAIL 1: أعمدة دورة الدعوة ناقصة (%)', v_count;
  end if;

  select count(*) into v_count
  from pg_constraint c
  join pg_class t on t.oid = c.conrelid
  join pg_namespace n on n.oid = t.relnamespace
  where n.nspname = 'core'
    and t.relname = 'well_invitations'
    and c.conname = 'well_invitations_status_check'
    and pg_get_constraintdef(c.oid) like '%accepted_pending_owner%'
    and pg_get_constraintdef(c.oid) like '%confirmed%'
    and pg_get_constraintdef(c.oid) like '%rejected%'
    and pg_get_constraintdef(c.oid) like '%claimed%';

  if v_count = 1 then
    raise notice 'PASS 2: نموذج الحالات يحافظ على claimed ويدعم دورة ق-130';
  else
    raise notice 'FAIL 2: قيد الحالات لا يمثل دورة ق-130';
  end if;

  select count(*) into v_count
  from pg_index i
  where i.indrelid = 'core.well_invitations'::regclass
    and i.indisunique
    and pg_get_indexdef(i.indexrelid) like '%(well_id, role, normalized_phone)%'
    and pg_get_expr(i.indpred, i.indrelid) like '%accepted_pending_owner%'
    and pg_get_expr(i.indpred, i.indrelid) like '%invited%';

  if v_count = 1 then
    raise notice 'PASS 2B: قيد قاعدة البيانات يغطي invited وaccepted_pending_owner';
  else
    raise notice 'FAIL 2B: قيد الدعوات المفتوحة غير فريد أو ناقص (%)', v_count;
  end if;

  select count(*) into v_count
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'core'
    and c.relname = 'well_invitations'
    and c.relrowsecurity;

  if v_count = 1 then
    raise notice 'PASS 3: RLS مفعّلة على core.well_invitations';
  else
    raise notice 'FAIL 3: RLS غير مفعّلة على جدول الدعوات';
  end if;

  select count(*) into v_count
  from information_schema.role_table_grants g
  where g.table_schema = 'core'
    and g.table_name = 'well_invitations'
    and lower(g.grantee) in ('anon', 'authenticated', 'public');

  if v_count = 0 then
    raise notice 'PASS 4: لا Direct DML لأدوار التطبيق على الدعوات';
  else
    raise notice 'FAIL 4: جدول الدعوات مكشوف لأدوار التطبيق (%)', v_count;
  end if;

  select count(*) into v_count
  from pg_proc p
  where p.oid in (
    v_core_invite, v_core_claim, v_core_accept, v_core_confirm, v_core_reject,
    v_core_list_my, v_core_read
  )
    and p.prosecdef
    and exists (
      select 1
      from unnest(coalesce(p.proconfig, array[]::text[])) as cfg(v)
      where cfg.v like 'search_path=%'
    );

  if v_count = 7 then
    raise notice 'PASS 5: الوظائف الداخلية Privileged ثابتة search_path';
  else
    raise notice 'FAIL 5: خصائص الوظائف الداخلية ناقصة (%)', v_count;
  end if;

  select count(*) into v_count
  from pg_proc p
  where p.oid in (
    v_api_invite, v_api_claim, v_api_accept, v_api_confirm,
    v_api_reject, v_api_list_my, v_api_team
  )
    and not p.prosecdef;

  if v_count = 7 then
    raise notice 'PASS 6: أغلفة api كلها SECURITY INVOKER';
  else
    raise notice 'FAIL 6: غلاف api صار SECURITY DEFINER (%)', 7 - v_count;
  end if;

  select count(*) into v_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'api'
    and p.proname in (
      'accept_well_invitation', 'confirm_well_invitation',
      'reject_well_invitation', 'list_my_well_invitations'
    )
    and has_function_privilege('anon', p.oid, 'EXECUTE');

  if v_count = 0 then
    raise notice 'PASS 7: anon لا ينفّذ عقود ق-130 الجديدة';
  else
    raise notice 'FAIL 7: anon ينفّذ % من عقود ق-130', v_count;
  end if;

  select pg_get_functiondef(v_core_invite) into v_src;
  if v_src not like '%insert into core.well_invitations%'
     or v_src like '%insert into core.well_assignments%' then
    raise notice 'FAIL 8: دعوة العضو لا تزال قد تمنح Assignment';
  else
    raise notice 'PASS 8: invite لا ينشئ Assignment ولا يربط الحساب تلقائيًا';
  end if;

  select pg_get_functiondef(v_core_claim) into v_src;
  if v_src like '%insert into core.well_assignments%'
     or v_src like '%status = ''active''%' then
    raise notice 'FAIL 9: claim القديم قد يمنح وصولًا';
  else
    raise notice 'PASS 9: claim القديم مغلق منحيًا مع بقاء العقد';
  end if;

  -- ---------------------------------------------------------------
  -- 2. بيانات اختبار: حساب قائم، شريك مالي قائم، وحسابات أخرى.
  -- ---------------------------------------------------------------

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'm44-owner@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now(),
    jsonb_build_object('full_name', 'مالك 103', 'phone', '770103103')
  ) returning id into v_owner_user;

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'm44-member@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now(),
    jsonb_build_object('full_name', 'عضو قائم 103', 'phone', '777111230')
  ) returning id into v_member_user;

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'm44-other@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now(),
    jsonb_build_object('full_name', 'حساب آخر 103', 'phone', '777111231')
  ) returning id into v_other_user;

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'm44-partner@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now(),
    jsonb_build_object('full_name', 'شريك قائم 103', 'phone', '+967777111222')
  ) returning id into v_partner_user;

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'm44-reject@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now(),
    jsonb_build_object('full_name', 'حساب مرفوض 103', 'phone', '777111233')
  ) returning id into v_reject_user;

  update iam.profiles
  set phone = '770103103', full_name = 'مالك 103'
  where id = v_owner_user;
  update iam.profiles
  set phone = '777111230', full_name = 'عضو قائم 103'
  where id = v_member_user;
  update iam.profiles
  set phone = '777111231', full_name = 'حساب آخر 103'
  where id = v_other_user;
  update iam.profiles
  set phone = '+967777111222', full_name = 'شريك قائم 103'
  where id = v_partner_user;
  update iam.profiles
  set phone = '777111233', full_name = 'حساب مرفوض 103'
  where id = v_reject_user;

  insert into core.tenants (name)
  values ('جهة دورة الحساب 103')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name, location)
  values (v_tenant, 'بئر دورة الحساب 103', 'موقع 103')
  returning id into v_well;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_well, v_owner_user, 'owner', 'active');

  -- شريك موجود من قبل بصيغة هاتف تاريخية، مع نسخة مالية لا يجوز تعديلها.
  insert into core.persons (
    tenant_id, full_name, normalized_name, created_by, updated_by
  ) values (
    v_tenant, 'شريك قائم 103', 'شريك قائم 103', v_owner_user, v_owner_user
  ) returning id into v_partner_person;

  insert into core.person_contacts (
    tenant_id, person_id, contact_type, contact_value,
    normalized_value, is_primary
  ) values (
    v_tenant, v_partner_person, 'mobile', '+967 777-111-222',
    '+967 777-111-222', true
  );

  insert into core.well_partners (
    tenant_id, well_id, person_id, phone, status, period_start
  ) values (
    v_tenant, v_well, v_partner_person, '+967 777-111-222', 'active', current_date
  ) returning id into v_partner_id;

  v_ended_partner_activated_at := now() - interval '2 days';
  insert into core.well_partners (
    tenant_id, well_id, person_id, profile_id, phone, status,
    period_start, period_end, activated_at
  ) values (
    v_tenant, v_well, v_partner_person, v_other_user, '+967 777-111-222', 'left',
    current_date - 2, current_date - 1, v_ended_partner_activated_at
  ) returning id into v_ended_partner_id;

  insert into core.ownership_share_versions (
    tenant_id, well_id, partner_id, ownership_percentage, profit_percentage,
    effective_period, approved_by
  ) values (
    v_tenant, v_well, v_partner_id, 100, 100,
    daterange(current_date, null), v_owner_user
  );

  select count(*), max(ownership_percentage), max(profit_percentage)
  into v_share_count, v_share_ownership, v_share_profit
  from core.ownership_share_versions
  where partner_id = v_partner_id;

  -- ---------------------------------------------------------------
  -- 3. الدعوة لحساب قائم: لا Assignment ولا auto-link.
  -- ---------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';

  v_payload := api.invite_well_member(
    v_well, 'operator', 'عضو قائم 103', '777111230'
  );
  v_operator_invitation := (v_payload ->> 'invitation_id')::uuid;
  v_code := v_payload ->> 'code';

  execute 'reset role';
  select count(*) into v_count
  from core.well_assignments
  where well_id = v_well
    and profile_id = v_member_user
    and role = 'operator';

  if v_payload ->> 'outcome' = 'invited'
     and v_code ~ '^[0-9]{6}$'
     and v_count = 0
  then
    raise notice 'PASS 10: حساب قائم تلقى دعوة بلا Assignment وبلا ربط تلقائي';
  else
    raise notice 'FAIL 10: الدعوة لحساب قائم غير مغلقة: % / %', v_payload, v_count;
  end if;

  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';
  v_payload := api.invite_well_member(
    v_well, 'partner', 'شريك قائم 103', '+967 777-111-222'
  );
  v_partner_invitation := (v_payload ->> 'invitation_id')::uuid;

  execute 'reset role';
  select count(*) into v_count
  from core.well_partners
  where id = v_partner_id
    and profile_id is null;

  select count(distinct pc.person_id) into v_partner_count
  from core.person_contacts pc
  where pc.tenant_id = v_tenant
    and core.normalize_phone(pc.normalized_value) =
      core.normalize_phone('777111222');

  if v_payload ->> 'outcome' = 'invited'
     and v_count = 1
     and v_partner_count = 1
  then
    raise notice 'PASS 11: الصيغ المكافئة أعادت Person/Partner نفسيهما دون auto-link';
  else
    raise notice 'FAIL 11: تطبيع الهاتف أو هوية الشريك غير مطابق: % / % / %',
      v_payload, v_count, v_partner_count;
  end if;

  -- ---------------------------------------------------------------
  -- 4. اكتشاف الحساب القائم والقبول المرفوض لحساب آخر.
  -- ---------------------------------------------------------------

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_member_user::text, true);
  execute 'set local role authenticated';
  v_payload := api.list_my_well_invitations();

  if v_payload ->> 'contract' = 'list_my_well_invitations'
     and jsonb_array_length(v_payload -> 'invitations') = 1
     and v_payload::text like '%' || v_operator_invitation::text || '%'
     and v_payload::text not like '%code_hash%'
     and v_payload::text not like '%code_salt%'
  then
    raise notice 'PASS 12: الحساب القائم يرى دعوته وحدها بلا أسرار';
  else
    raise notice 'FAIL 12: اكتشاف الدعوة غير معزول: %', v_payload;
  end if;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_other_user::text, true);
  execute 'set local role authenticated';
  v_payload := api.list_my_well_invitations();

  if jsonb_array_length(v_payload -> 'invitations') = 0 then
    raise notice 'PASS 13: حساب آخر لا يرى دعوة الهاتف المختلف';
  else
    raise notice 'FAIL 13: تسريب دعوة إلى حساب آخر: %', v_payload;
  end if;

  v_denied := false;
  begin
    perform api.accept_well_invitation(v_operator_invitation);
  exception
    when others then
      v_denied := (sqlstate = '42501');
  end;

  if v_denied then
    raise notice 'PASS 14: حساب آخر لا يستطيع قبول دعوة الحساب القائم';
  else
    raise notice 'FAIL 14: قبول الحساب الآخر نجح أو أعاد خطأ غير مغلق';
  end if;

  -- الحساب الصحيح يقبل، لكن access يبقى صفرًا.
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_member_user::text, true);
  execute 'set local role authenticated';
  v_payload := api.accept_well_invitation(v_operator_invitation);

  execute 'reset role';
  select count(*) into v_count
  from core.well_assignments
  where well_id = v_well
    and profile_id = v_member_user
    and role = 'operator';

  if v_payload ->> 'outcome' = 'accepted_pending_owner' and v_count = 0 then
    raise notice 'PASS 15: القبول الصحيح يثبت pending_owner بصفر وصول';
  else
    raise notice 'FAIL 15: القبول منح وصولًا أو حالة خاطئة: % / %', v_payload, v_count;
  end if;

  if not iam.has_well_role(v_well, array['operator']) then
    raise notice 'PASS 16: accepted_pending_owner لا يمنح دور التشغيل';
  else
    raise notice 'FAIL 16: accepted_pending_owner منح دور التشغيل';
  end if;

  -- إعادة الطلب للحساب نفسه idempotent، ولا يغيّر الصفر قبل التأكيد.
  perform set_config('request.jwt.claim.sub', v_member_user::text, true);
  execute 'set local role authenticated';
  v_payload := api.accept_well_invitation(v_operator_invitation);
  execute 'reset role';
  select count(*) into v_count
  from core.well_assignments
  where well_id = v_well
    and profile_id = v_member_user
    and role = 'operator';

  if v_payload ->> 'outcome' = 'already_accepted' and v_count = 0 then
    raise notice 'PASS 17: قبول الحساب نفسه idempotent وبلا Assignment';
  else
    raise notice 'FAIL 17: تكرار القبول غير آمن: % / %', v_payload, v_count;
  end if;

  -- لا يكفي استدعاء invite متسلسل لإثبات سباق القبول؛ نحاول إدخال صف
  -- invited موازٍ مباشرةً ونطلب من القيد الفريد رفضه وهو pending.
  execute 'reset role';
  v_denied := false;
  begin
    insert into core.well_invitations (
      tenant_id, well_id, role, person_id, phone, normalized_phone,
      code_salt, code_hash, expires_at, invited_by, status
    )
    select
      inv.tenant_id, inv.well_id, inv.role, inv.person_id, inv.phone,
      inv.normalized_phone, 'open-race-guard-103',
      core.hash_invitation_code('123456', 'open-race-guard-103'),
      now() + interval '1 day', inv.invited_by, 'invited'
    from core.well_invitations inv
    where inv.id = v_operator_invitation;
  exception
    when unique_violation then
      v_denied := true;
  end;

  if v_denied then
    raise notice 'PASS 17B: قيد قاعدة البيانات يرفض invited موازية مع pending_owner';
  else
    raise notice 'FAIL 17B: أمكن إدخال دعوة مفتوحة موازية رغم pending_owner';
  end if;

  -- ---------------------------------------------------------------
  -- 5. قراءة المالك ثم التأكيد وإنشاء Assignment واحد.
  -- ---------------------------------------------------------------

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';
  v_team := api.list_well_team(v_well);

  if v_team::text like '%accepted_pending_owner%'
     and v_team::text like '%accepted_at%'
     and v_team::text not like '%code_hash%'
     and v_team::text not like '%code_salt%'
  then
    raise notice 'PASS 18: قراءة الفريق تميّز انتظار تأكيد المالك بلا سر';
  else
    raise notice 'FAIL 18: قراءة الفريق لا تعرض حالة pending_owner: %', v_team;
  end if;

  v_payload := api.confirm_well_invitation(v_operator_invitation);

  execute 'reset role';
  select count(*) into v_count
  from core.well_assignments
  where well_id = v_well
    and profile_id = v_member_user
    and role = 'operator'
    and status = 'active';

  select count(*) into v_count_2
  from core.well_invitations
  where id = v_operator_invitation
    and status = 'confirmed'
    and accepted_profile_id = v_member_user
    and confirmed_by = v_owner_user
    and accepted_at is not null
    and confirmed_at is not null;

  if v_payload ->> 'outcome' = 'confirmed' and v_count = 1 and v_count_2 = 1 then
    raise notice 'PASS 19: تأكيد المالك أنشأ Assignment واحدًا وسجل التدقيق';
  else
    raise notice 'FAIL 19: التأكيد غير ذري أو ناقص: % / % / %',
      v_payload, v_count, v_count_2;
  end if;

  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';
  v_payload := api.confirm_well_invitation(v_operator_invitation);
  execute 'reset role';
  select count(*) into v_count
  from core.well_assignments
  where well_id = v_well
    and profile_id = v_member_user
    and role = 'operator';

  if v_payload ->> 'outcome' = 'already_confirmed' and v_count = 1 then
    raise notice 'PASS 20: تكرار تأكيد المشغّل idempotent';
  else
    raise notice 'FAIL 20: تكرار التأكيد أنشأ أثرًا ثانيًا: % / %', v_payload, v_count;
  end if;

  -- الحساب القائم الذي أُلغي وصوله يبقى حسابًا مشروعًا، لكنه يعود إلى دورة
  -- دعوة كاملة؛ لا يعاد تنشيطه تلقائيًا من صف confirmed التاريخي.
  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';
  v_revoke_payload := api.revoke_well_member(
    v_well, 'operator', '777111230'
  );

  execute 'reset role';
  select count(*) into v_count
  from core.well_assignments
  where well_id = v_well
    and profile_id = v_member_user
    and role = 'operator'
    and status = 'inactive';

  select count(*) into v_count_2
  from iam.profiles
  where id = v_member_user;

  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';
  v_payload := api.invite_well_member(
    v_well, 'operator', 'عضو قائم 103 بعد الإلغاء', '+967 777-111-230'
  );
  v_reuse_invitation := (v_payload ->> 'invitation_id')::uuid;

  execute 'reset role';
  select count(*) into v_assignment_count
  from core.well_assignments
  where well_id = v_well
    and profile_id = v_member_user
    and role = 'operator'
    and status = 'active';

  if v_revoke_payload ->> 'contract' = 'revoke_well_member'
     and v_count = 1
     and v_count_2 = 1
     and v_payload ->> 'outcome' = 'invited'
     and v_reuse_invitation <> v_operator_invitation
     and v_assignment_count = 0
  then
    raise notice 'PASS 20B: الحساب الملغى يتلقى دعوة جديدة بصفر وصول';
  else
    raise notice 'FAIL 20B: إعادة دعوة الحساب الملغى غير آمنة: % / % / %',
      v_revoke_payload, v_payload, v_assignment_count;
  end if;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_member_user::text, true);
  execute 'set local role authenticated';
  perform api.accept_well_invitation(v_reuse_invitation);

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';
  v_payload := api.confirm_well_invitation(v_reuse_invitation);

  execute 'reset role';
  select
    count(*) filter (where status = 'active'),
    count(*)
  into v_count, v_count_2
  from core.well_assignments
  where well_id = v_well
    and profile_id = v_member_user
    and role = 'operator';

  if v_payload ->> 'outcome' = 'confirmed'
     and v_count = 1
     and v_count_2 = 1
  then
    raise notice 'PASS 20C: إعادة القبول والتأكيد تعيد Assignment واحدًا فقط';
  else
    raise notice 'FAIL 20C: إعادة التأكيد أنشأت أثرًا زائدًا: % / % / %',
      v_payload, v_count, v_count_2;
  end if;

  -- ---------------------------------------------------------------
  -- 6. قبول الشريك وتجميد الدعوة ثم ربط Partner التاريخي نفسه.
  -- ---------------------------------------------------------------

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_partner_user::text, true);
  execute 'set local role authenticated';
  v_payload := api.accept_well_invitation(v_partner_invitation);

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';
  v_payload := api.invite_well_member(
    v_well, 'partner', 'تصحيح اسم لا يستبدل pending', '777111222'
  );

  execute 'reset role';
  select count(*) into v_count
  from core.well_invitations
  where well_id = v_well
    and role = 'partner'
    and normalized_phone = core.normalize_phone('777111222')
    and status = 'invited';

  if v_payload ->> 'outcome' = 'accepted_pending_owner'
     and (v_payload ->> 'invitation_id')::uuid = v_partner_invitation
     and v_count = 0
  then
    raise notice 'PASS 21: pending_owner مجمّدة ولا تستبدلها دعوة صامتة';
  else
    raise notice 'FAIL 21: إعادة الدعوة بدّلت قبول الشريك: % / %', v_payload, v_count;
  end if;

  -- علاقة مالية غير فعّالة لا تتحول إلى وصول من تأكيد الحساب. تبقى الدعوة
  -- pending، ويمتنع الإجراء عن إحياء Partner أو تعديل تاريخه المالي.
  update core.well_partners
  set status = 'inactive'
  where id = v_partner_id;

  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';
  v_denied := false;
  begin
    perform api.confirm_well_invitation(v_partner_invitation);
  exception
    when others then
      v_denied := (sqlstate = 'P0001');
  end;

  execute 'reset role';
  select count(*) into v_count
  from core.well_assignments
  where well_id = v_well
    and profile_id = v_partner_user
    and role = 'partner'
    and status = 'active';

  select count(*) into v_count_2
  from core.well_partners
  where id = v_partner_id
    and profile_id is null
    and status = 'inactive'
    and period_start = current_date
    and period_end is null;

  select count(*) into v_partner_count
  from core.well_invitations
  where id = v_partner_invitation
    and status = 'accepted_pending_owner';

  select count(*), max(ownership_percentage), max(profit_percentage)
  into v_share_count, v_share_ownership, v_share_profit
  from core.ownership_share_versions
  where partner_id = v_partner_id;

  if v_denied
     and v_count = 0
     and v_count_2 = 1
     and v_partner_count = 1
     and v_share_count = 1
     and v_share_ownership = 100
     and v_share_profit = 100
  then
    raise notice 'PASS 21B: Partner المالي غير الفعّال لا يتنشط بحساب أو Assignment';
  else
    raise notice 'FAIL 21B: تأكيد Partner غير فعّال غيّر الوصول أو التاريخ: % / % / %',
      v_denied, v_count, v_count_2;
  end if;

  -- استعادة fixture فقط؛ الدالة لا تستعيد الحالة المالية بنفسها.
  update core.well_partners
  set status = 'active'
  where id = v_partner_id;

  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';

  v_payload := api.confirm_well_invitation(v_partner_invitation);

  execute 'reset role';
  select count(*) into v_count
  from core.well_assignments
  where well_id = v_well
    and profile_id = v_partner_user
    and role = 'partner'
    and status = 'active';

  select count(*) into v_count_2
  from core.well_partners
  where id = v_partner_id
    and person_id = v_partner_person
    and well_id = v_well
    and profile_id = v_partner_user
    and status = 'active'
    and period_end is null;

  select count(*) into v_partner_count
  from core.well_partners
  where well_id = v_well
    and person_id = v_partner_person;

  select count(*) into v_ended_partner_count
  from core.well_partners
  where id = v_ended_partner_id
    and well_id = v_well
    and person_id = v_partner_person
    and profile_id = v_other_user
    and status = 'left'
    and period_end = current_date - 1
    and activated_at = v_ended_partner_activated_at;

  select count(*), max(ownership_percentage), max(profit_percentage)
  into v_share_count, v_share_ownership, v_share_profit
  from core.ownership_share_versions
  where partner_id = v_partner_id;

  if v_payload ->> 'outcome' = 'confirmed'
     and v_count = 1
     and v_count_2 = 1
     and v_partner_count = 2
     and v_ended_partner_count = 1
     and v_share_count = 1
     and v_share_ownership = 100
     and v_share_profit = 100
  then
    raise notice 'PASS 22: التأكيد ربط Partner الحالي فقط وحفظ السجل المنتهي والنسخ المالية';
  else
    raise notice 'FAIL 22: ربط الشريك أو التاريخ المالي تغيّر: % / % / % / % / %',
      v_payload, v_count, v_count_2, v_partner_count, v_ended_partner_count;
  end if;

  -- ---------------------------------------------------------------
  -- 7. الرفض: تدقيق محفوظ وصفر Assignment، ثم حالة read_well_team.
  -- ---------------------------------------------------------------

  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';
  v_payload := api.invite_well_member(
    v_well, 'operator', 'حساب مرفوض 103', '777111233'
  );
  v_reject_invitation := (v_payload ->> 'invitation_id')::uuid;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_reject_user::text, true);
  execute 'set local role authenticated';
  perform api.accept_well_invitation(v_reject_invitation);

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';
  v_payload := api.reject_well_invitation(v_reject_invitation);

  execute 'reset role';
  select count(*) into v_count
  from core.well_assignments
  where well_id = v_well
    and profile_id = v_reject_user
    and role = 'operator'
    and status = 'active';

  select count(*) into v_count_2
  from core.well_invitations
  where id = v_reject_invitation
    and status = 'rejected'
    and accepted_profile_id = v_reject_user
    and rejected_by = v_owner_user
    and accepted_at is not null
    and rejected_at is not null;

  if v_payload ->> 'outcome' = 'rejected' and v_count = 0 and v_count_2 = 1 then
    raise notice 'PASS 23: الرفض يحفظ التدقيق ويترك صفر وصول';
  else
    raise notice 'FAIL 23: الرفض منح وصولًا أو حذف التاريخ: % / % / %',
      v_payload, v_count, v_count_2;
  end if;

  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';
  v_team := api.list_well_team(v_well);
  if v_team::text like '%rejected%'
     and v_team::text like '%rejected_at%'
     and v_team::text not like '%code_hash%'
     and v_team::text not like '%code_salt%'
  then
    raise notice 'PASS 24: read_well_team يميّز الرفض/التصحيح بلا أسرار';
  else
    raise notice 'FAIL 24: قراءة الرفض غير مطابقة: %', v_team;
  end if;

  -- ---------------------------------------------------------------
  -- 8. العقد القديم لا يمنح Assignment، وصف claimed التاريخي يبقى صالحًا.
  -- ---------------------------------------------------------------

  v_payload := api.invite_well_member(
    v_well, 'operator', 'دعوة قديمة مغلقة 103', '777111299'
  );
  v_legacy_invitation := (v_payload ->> 'invitation_id')::uuid;
  v_code := v_payload ->> 'code';

  execute 'reset role';
  update iam.profiles set phone = '777111299' where id = v_other_user;
  perform set_config('request.jwt.claim.sub', v_other_user::text, true);
  execute 'set local role authenticated';
  v_payload := api.claim_well_invitation(v_code);

  execute 'reset role';
  select count(*) into v_count
  from core.well_assignments
  where well_id = v_well
    and profile_id = v_other_user
    and role = 'operator';

  select status into v_code
  from core.well_invitations
  where id = v_legacy_invitation;

  if v_payload ->> 'outcome' = 'superseded'
     and v_count = 0
     and v_code = 'invited'
  then
    raise notice 'PASS 25: claim القديم fail-closed ولا يمنح Assignment';
  else
    raise notice 'FAIL 25: claim القديم غيّر الوصول: % / % / %',
      v_payload, v_count, v_code;
  end if;

  execute 'reset role';
  insert into core.persons (
    tenant_id, full_name, normalized_name, created_by, updated_by
  ) values (
    v_tenant, 'دعوة تاريخية 103', 'دعوة تاريخية 103', v_owner_user, v_owner_user
  ) returning id into v_historical_person;

  insert into core.well_invitations (
    tenant_id, well_id, role, person_id, phone, normalized_phone,
    code_salt, code_hash, expires_at, invited_by,
    status, claimed_at, claimed_profile_id
  ) values (
    v_tenant, v_well, 'operator', v_historical_person, '777111298',
    core.normalize_phone('777111298'),
    'historical-salt-103',
    core.hash_invitation_code('123456', 'historical-salt-103'),
    now() + interval '1 day', v_owner_user,
    'claimed', now(), v_member_user
  ) returning id into v_historical_invitation;

  select count(*) into v_count
  from core.well_invitations
  where id = v_historical_invitation
    and status = 'claimed'
    and claimed_at is not null
    and claimed_profile_id = v_member_user
    and accepted_profile_id is null
    and accepted_at is null;

  if v_count = 1 then
    raise notice 'PASS 26: صف claimed التاريخي بقي صالحًا وقابلًا للقراءة';
  else
    raise notice 'FAIL 26: صف claimed التاريخي لم يعد صالحًا';
  end if;

  -- Person تاريخي غير فعّال لا يعاد إحياؤه ولا ينشئ دعوة أو Person بديلًا.
  insert into core.persons (
    tenant_id, full_name, normalized_name, status, created_by, updated_by
  ) values (
    v_tenant, 'هاتف غير فعّال 103', 'هاتف غير فعّال 103', 'inactive',
    v_owner_user, v_owner_user
  ) returning id into v_inactive_person;

  insert into core.person_contacts (
    tenant_id, person_id, contact_type, contact_value,
    normalized_value, is_primary
  ) values (
    v_tenant, v_inactive_person, 'mobile', '777111287', '777111287', true
  );

  select count(*) into v_assignment_count
  from core.well_assignments
  where well_id = v_well;

  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';
  v_denied := false;
  begin
    perform api.invite_well_member(
      v_well, 'operator', 'محاولة هاتف غير فعّال 103', '+967 777-111-287'
    );
  exception
    when others then
      v_denied := (sqlstate = 'P0001' and sqlerrm like '%مراجعة بشرية%');
  end;

  execute 'reset role';
  select count(distinct pc.person_id) into v_count
  from core.person_contacts pc
  where pc.tenant_id = v_tenant
    and core.normalize_phone(pc.normalized_value) =
      core.normalize_phone('777111287');

  select count(*) into v_count_2
  from core.well_invitations inv
  where inv.well_id = v_well
    and inv.role = 'operator'
    and inv.normalized_phone = core.normalize_phone('777111287');

  select count(*) into v_partner_count
  from core.well_assignments
  where well_id = v_well;

  if v_denied
     and v_count = 1
     and v_count_2 = 0
     and v_partner_count = v_assignment_count
  then
    raise notice 'PASS 27: Person غير فعّال للهاتف يفشل مغلقًا بلا بديل أو Assignment';
  else
    raise notice 'FAIL 27: Person غير فعّال أنشأ أثرًا جديدًا: % / % / % / %',
      v_denied, v_count, v_count_2, v_partner_count;
  end if;

  -- تاريخ الهاتف قد يحمل Personين مختلفين. ق-130 يطلب مراجعة بشرية لا
  -- اختيار أحدهما بالترتيب ولا إنشاء Person ثالث عند الدعوة.
  insert into core.persons (
    tenant_id, full_name, normalized_name, created_by, updated_by
  ) values (
    v_tenant, 'تعارض هاتف أ 103', 'تعارض هاتف أ 103', v_owner_user, v_owner_user
  ) returning id into v_ambiguous_person_a;

  insert into core.persons (
    tenant_id, full_name, normalized_name, created_by, updated_by
  ) values (
    v_tenant, 'تعارض هاتف ب 103', 'تعارض هاتف ب 103', v_owner_user, v_owner_user
  ) returning id into v_ambiguous_person_b;

  insert into core.person_contacts (
    tenant_id, person_id, contact_type, contact_value,
    normalized_value, is_primary
  ) values
    (v_tenant, v_ambiguous_person_a, 'mobile', '777111288', '777111288', true),
    (v_tenant, v_ambiguous_person_b, 'mobile', '+967 777-111-288',
      '+967 777-111-288', true);

  select count(*) into v_assignment_count
  from core.well_assignments
  where well_id = v_well;

  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';
  v_denied := false;
  begin
    perform api.invite_well_member(
      v_well, 'operator', 'محاولة هاتف متعارض 103', '+967 777-111-288'
    );
  exception
    when others then
      v_denied := (sqlstate = 'P0001' and sqlerrm like '%مراجعة بشرية%');
  end;

  execute 'reset role';
  select count(distinct pc.person_id) into v_count
  from core.person_contacts pc
  where pc.tenant_id = v_tenant
    and core.normalize_phone(pc.normalized_value) =
      core.normalize_phone('777111288');

  select count(*) into v_count_2
  from core.well_invitations inv
  where inv.well_id = v_well
    and inv.role = 'operator'
    and inv.normalized_phone = core.normalize_phone('777111288');

  select count(*) into v_partner_count
  from core.well_assignments
  where well_id = v_well;

  if v_denied
     and v_count = 2
     and v_count_2 = 0
     and v_partner_count = v_assignment_count
  then
    raise notice 'PASS 28: تعارض Person للهاتف يفشل مغلقًا بلا Person أو Assignment جديد';
  else
    raise notice 'FAIL 28: تعارض الهاتف اختير أو خلّف أثرًا: % / % / % / %',
      v_denied, v_count, v_count_2, v_partner_count;
  end if;

  raise notice '103 DONE';
end;
$test$;

rollback;
