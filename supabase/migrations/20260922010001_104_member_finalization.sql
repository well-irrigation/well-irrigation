-- ق-130 / م-44: trusted finalization للعضو الجديد بلا Auth مسبق.
-- لا ينشأ Auth داخل PostgreSQL. Edge Function تتحقق أولًا، ثم تنشئ Auth
-- بمفتاح الخدمة، ثم تستدعي completion الذرية. عند فشل completion تحذف
-- Edge Function معرّف Auth الذي أنشأته هي وحدها.

begin;

-- ==============================================================
-- 1. نموذج lifecycle: فصل existing_auth عن new_no_auth
-- ==============================================================

alter table core.well_invitations
  add column if not exists acceptance_kind text,
  add column if not exists continuation_token_salt text,
  add column if not exists continuation_token_hash text,
  add column if not exists continuation_expires_at timestamptz;

alter table core.well_invitations
  drop constraint if exists well_invitations_acceptance_kind_check;

alter table core.well_invitations
  add constraint well_invitations_acceptance_kind_check
  check (
    acceptance_kind is null
    or acceptance_kind in ('existing_auth', 'new_no_auth')
  );

alter table core.well_invitations
  drop constraint if exists well_invitations_status_check;

alter table core.well_invitations
  add constraint well_invitations_status_check
  check (
    status in (
      'invited', 'accepted_pending_owner',
      'owner_confirmed_pending_account', 'confirmed', 'rejected',
      'claimed', 'expired', 'revoked'
    )
  );

alter table core.well_invitations
  drop constraint if exists well_invitations_lifecycle_audit_check;

alter table core.well_invitations
  add constraint well_invitations_lifecycle_audit_check
  check (
    (
      status in ('invited', 'expired', 'revoked', 'claimed')
      and acceptance_kind is null
      and accepted_profile_id is null
      and accepted_at is null
      and confirmed_by is null
      and confirmed_at is null
      and rejected_by is null
      and rejected_at is null
      and continuation_token_salt is null
      and continuation_token_hash is null
      and continuation_expires_at is null
    )
    or (
      status = 'accepted_pending_owner'
      and accepted_at is not null
      and confirmed_by is null
      and confirmed_at is null
      and rejected_by is null
      and rejected_at is null
      and (
        (
          coalesce(acceptance_kind, 'existing_auth') = 'existing_auth'
          and accepted_profile_id is not null
          and continuation_token_salt is null
          and continuation_token_hash is null
          and continuation_expires_at is null
        )
        or (
          acceptance_kind = 'new_no_auth'
          and accepted_profile_id is null
          and continuation_token_salt is not null
          and continuation_token_hash is not null
          and continuation_expires_at is not null
        )
      )
    )
    or (
      status = 'owner_confirmed_pending_account'
      and acceptance_kind = 'new_no_auth'
      and accepted_profile_id is null
      and accepted_at is not null
      and confirmed_by is not null
      and confirmed_at is not null
      and rejected_by is null
      and rejected_at is null
      and continuation_token_salt is not null
      and continuation_token_hash is not null
      and continuation_expires_at is not null
    )
    or (
      status = 'confirmed'
      and accepted_profile_id is not null
      and accepted_at is not null
      and confirmed_by is not null
      and confirmed_at is not null
      and rejected_by is null
      and rejected_at is null
      and continuation_token_salt is null
      and continuation_token_hash is null
      and continuation_expires_at is null
      and coalesce(acceptance_kind, 'existing_auth')
        in ('existing_auth', 'new_no_auth')
    )
    or (
      status = 'rejected'
      and accepted_at is not null
      and confirmed_by is null
      and confirmed_at is null
      and rejected_by is not null
      and rejected_at is not null
      and continuation_token_salt is null
      and continuation_token_hash is null
      and continuation_expires_at is null
      and (
        (
          coalesce(acceptance_kind, 'existing_auth') = 'existing_auth'
          and accepted_profile_id is not null
        )
        or (
          acceptance_kind = 'new_no_auth'
          and accepted_profile_id is null
        )
      )
    )
  );

comment on column core.well_invitations.acceptance_kind is
  'ق-130: existing_auth أو new_no_auth. الصفوف السابقة ذات accepted_profile_id وNULL تعامل existing_auth.';
comment on column core.well_invitations.continuation_token_salt is
  'ق-130: ملح token الاستمرار؛ لا يخزن token نصًا.';
comment on column core.well_invitations.continuation_token_hash is
  'ق-130: SHA-256 مملح لـtoken الاستمرار؛ يستهلك عند completion.';
comment on column core.well_invitations.continuation_expires_at is
  'ق-130: انتهاء token الاستمرار القصير المستقل بعد قبول الدعوة.';

drop index if exists core.well_invitations_open_uniq;
create unique index well_invitations_open_uniq
  on core.well_invitations (well_id, role, normalized_phone)
  where status in (
    'invited', 'accepted_pending_owner',
    'owner_confirmed_pending_account'
  );

revoke all on table core.well_invitations
  from public, anon, authenticated, service_role;

-- ==============================================================
-- 2. تلبيد token الاستمرار وتحقق pre-auth
-- ==============================================================

create or replace function core.hash_member_finalization_token(
  p_token text,
  p_salt text
)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $function$
  select encode(
    sha256(convert_to(p_salt || ':' || p_token, 'utf8')),
    'hex'
  );
$function$;

revoke all on function core.hash_member_finalization_token(text, text)
  from public, anon, authenticated, service_role;

create or replace function core.validate_member_finalization(
  p_phone text,
  p_code text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_phone text := btrim(coalesce(p_phone, ''));
  v_code text := btrim(coalesce(p_code, ''));
  v_norm text;
  v_candidate_ids uuid[];
  v_candidate_count integer;
  v_inv core.well_invitations;
  v_wrong_count integer;
  v_attempts_left integer;
  v_profile_count integer;
  v_person_status text;
  v_token text;
  v_salt text;
  v_token_expires timestamptz;
begin
  if v_phone = '' then
    raise exception 'رقم الهاتف مطلوب'
      using errcode = '22023';
  end if;

  v_norm := core.normalize_phone(v_phone);
  if v_norm is null or v_norm = '' then
    raise exception 'رقم الهاتف غير صالح'
      using errcode = '22023';
  end if;

  if v_code !~ '^[0-9]{6}$' then
    raise exception 'رمز الدعوة يجب أن يكون ستة أرقام'
      using errcode = '22023';
  end if;

  update core.well_invitations
  set status = 'expired',
      updated_at = now()
  where normalized_phone = v_norm
    and status = 'invited'
    and expires_at <= now();

  select array_agg(inv.id order by inv.invited_at desc)
  into v_candidate_ids
  from core.well_invitations inv
  where inv.normalized_phone = v_norm
    and inv.attempts_left > 0
    and (
      (
        inv.status = 'invited'
        and inv.expires_at > now()
      )
      or (
        inv.acceptance_kind = 'new_no_auth'
        and inv.status in (
          'accepted_pending_owner',
          'owner_confirmed_pending_account'
        )
      )
    )
    and inv.code_hash = core.hash_invitation_code(v_code, inv.code_salt);

  v_candidate_count := coalesce(cardinality(v_candidate_ids), 0);

  if v_candidate_count > 1 then
    raise exception 'تعذر تحديد دعوة وحيدة لهذا الرمز'
      using errcode = 'P0001';
  end if;

  if v_candidate_count = 0 then
    update core.well_invitations
    set attempts_left = attempts_left - 1,
        updated_at = now()
    where normalized_phone = v_norm
      and attempts_left > 0
      and (
        (
          status = 'invited'
          and expires_at > now()
        )
        or (
          acceptance_kind = 'new_no_auth'
          and status in (
            'accepted_pending_owner',
            'owner_confirmed_pending_account'
          )
        )
      );
    get diagnostics v_wrong_count = row_count;

    if v_wrong_count > 0 then
      select min(inv.attempts_left) into v_attempts_left
      from core.well_invitations inv
      where inv.normalized_phone = v_norm
        and (
          (
            inv.status = 'invited'
            and inv.expires_at > now()
          )
          or (
            inv.acceptance_kind = 'new_no_auth'
            and inv.status in (
              'accepted_pending_owner',
              'owner_confirmed_pending_account'
            )
          )
        );

      return jsonb_build_object(
        'contract', 'validate_member_finalization',
        'version', 1,
        'outcome', 'wrong_code',
        'attempts_left', v_attempts_left
      );
    end if;

    if exists (
      select 1
      from core.well_invitations inv
      where inv.normalized_phone = v_norm
        and inv.status = 'expired'
        and inv.code_hash =
          core.hash_invitation_code(v_code, inv.code_salt)
    ) then
      return jsonb_build_object(
        'contract', 'validate_member_finalization',
        'version', 1,
        'outcome', 'expired'
      );
    end if;

    if exists (
      select 1
      from core.well_invitations inv
      where inv.normalized_phone = v_norm
        and inv.status = 'revoked'
        and inv.code_hash = core.hash_invitation_code(v_code, inv.code_salt)
    ) then
      return jsonb_build_object(
        'contract', 'validate_member_finalization',
        'version', 1,
        'outcome', 'revoked'
      );
    end if;

    return jsonb_build_object(
      'contract', 'validate_member_finalization',
      'version', 1,
      'outcome', 'no_invitation'
    );
  end if;

  select inv.* into v_inv
  from core.well_invitations inv
  where inv.id = v_candidate_ids[1]
  for update;

  if v_inv.id is null
     or (
       v_inv.status = 'invited'
       and v_inv.expires_at <= now()
     )
     or v_inv.attempts_left <= 0
     or v_inv.code_hash <>
       core.hash_invitation_code(v_code, v_inv.code_salt)
  then
    return jsonb_build_object(
      'contract', 'validate_member_finalization',
      'version', 1,
      'outcome', 'no_invitation'
    );
  end if;

  select pe.status into v_person_status
  from core.persons pe
  where pe.id = v_inv.person_id
    and pe.tenant_id = v_inv.tenant_id;

  if v_person_status is distinct from 'active' then
    raise exception 'هوية الدعوة تحتاج مراجعة بشرية'
      using errcode = 'P0001';
  end if;

  select count(*) into v_profile_count
  from iam.profiles pr
  where core.normalize_phone(pr.phone) = v_inv.normalized_phone;

  if v_profile_count > 0 then
    return jsonb_build_object(
      'contract', 'validate_member_finalization',
      'version', 1,
      'outcome', 'existing_account'
    );
  end if;

  if v_inv.status <> 'invited'
     and (v_inv.acceptance_kind <> 'new_no_auth'
        or v_inv.status not in (
          'accepted_pending_owner',
          'owner_confirmed_pending_account'
        ))
  then
    raise exception 'الدعوة ليست في مسار عضو جديد'
      using errcode = '42501';
  end if;

  -- UUIDان مستقلان = token عالي entropy؛ لا يخزن النص بعد هذا return.
  v_token := replace(gen_random_uuid()::text, '-', '')
    || replace(gen_random_uuid()::text, '-', '');
  v_salt := replace(gen_random_uuid()::text, '-', '');
  v_token_expires := now() + interval '30 minutes';

  -- انتقال القبول وتخزين hash الـ token يحدثان في UPDATE واحد حتى يبقى
  -- قيد اتساق دورة الحياة صحيحًا في كل لحظة.
  update core.well_invitations
  set status = case
        when status = 'invited' then 'accepted_pending_owner'
        else status
      end,
      acceptance_kind = 'new_no_auth',
      accepted_profile_id = null,
      accepted_at = case
        when status = 'invited' then now()
        else accepted_at
      end,
      continuation_token_salt = v_salt,
      continuation_token_hash =
        core.hash_member_finalization_token(v_token, v_salt),
      continuation_expires_at = v_token_expires,
      updated_at = now()
  where id = v_inv.id;

  if v_inv.status = 'invited' then
    v_inv.status := 'accepted_pending_owner';
  end if;

  return jsonb_build_object(
    'contract', 'validate_member_finalization',
    'version', 1,
    'outcome', v_inv.status,
    'continuation_token', v_token,
    'continuation_expires_at', v_token_expires
  );
end;
$function$;

comment on function core.validate_member_finalization(text, text) is
  'ق-130: service_role فقط؛ يتحقق من الهاتف والرمز ويقبل new_no_auth بصفر Auth وصفر وصول، ويعيد token مرة واحدة دون تخزين plaintext.';

revoke all on function core.validate_member_finalization(text, text)
  from public, anon, authenticated, service_role;
grant execute on function core.validate_member_finalization(text, text)
  to service_role;

-- ==============================================================
-- 3. تأكيد المالك: existing_auth كما في 103، new_no_auth بلا وصول
-- ==============================================================

create or replace function core.confirm_well_invitation(
  p_invitation_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_well_id uuid;
  v_row core.well_invitations;
  v_profile uuid;
  v_profile_count integer;
  v_partner_id uuid;
  v_partner_profile uuid;
  v_partner_count integer;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل تأكيد الدعوة'
      using errcode = '28000';
  end if;

  select inv.well_id into v_well_id
  from core.well_invitations inv
  where inv.id = p_invitation_id;

  if v_well_id is null then
    raise exception 'الدعوة غير موجودة'
      using errcode = '22023';
  end if;

  if not iam.has_well_permission(v_well_id, 'team.manage') then
    raise exception 'تأكيد أعضاء هذا البئر متاح لمالكه'
      using errcode = '42501';
  end if;

  select inv.* into v_row
  from core.well_invitations inv
  where inv.id = p_invitation_id
  for update;

  if v_row.status = 'confirmed' then
    return jsonb_build_object(
      'contract', 'confirm_well_invitation',
      'version', 2,
      'outcome', 'already_confirmed',
      'invitation_id', v_row.id,
      'well_id', v_row.well_id,
      'role', v_row.role
    );
  end if;

  if v_row.acceptance_kind = 'new_no_auth' then
    if v_row.status = 'owner_confirmed_pending_account' then
      return jsonb_build_object(
        'contract', 'confirm_well_invitation',
        'version', 3,
        'outcome', 'owner_confirmed_pending_account',
        'invitation_id', v_row.id,
        'well_id', v_row.well_id,
        'role', v_row.role
      );
    end if;

    if v_row.status <> 'accepted_pending_owner'
       or v_row.accepted_profile_id is not null
    then
      raise exception 'دعوة العضو الجديد ليست بانتظار تأكيد المالك'
        using errcode = '42501';
    end if;

    select count(*) into v_profile_count
    from iam.profiles pr
    where core.normalize_phone(pr.phone) = v_row.normalized_phone;

    if v_profile_count > 0 then
      raise exception 'ظهر حساب لهذا الهاتف؛ استخدم مسار الحساب القائم'
        using errcode = '42501';
    end if;

    update core.well_invitations
    set status = 'owner_confirmed_pending_account',
        confirmed_by = v_actor,
        confirmed_at = now(),
        updated_at = now()
    where id = v_row.id;

    return jsonb_build_object(
      'contract', 'confirm_well_invitation',
      'version', 3,
      'outcome', 'owner_confirmed_pending_account',
      'invitation_id', v_row.id,
      'well_id', v_row.well_id,
      'role', v_row.role
    );
  end if;

  -- المسار التالي هو سلوك M103 للحساب القائم دون تغيير.
  if v_row.status <> 'accepted_pending_owner' then
    raise exception 'لا يمكن تأكيد دعوة غير مقبولة من الحساب'
      using errcode = '42501';
  end if;

  select pr.id into v_profile
  from iam.profiles pr
  where pr.id = v_row.accepted_profile_id
    and core.normalize_phone(pr.phone) = v_row.normalized_phone;

  if v_profile is null then
    raise exception 'الحساب المقبول لم يعد يطابق هوية الدعوة'
      using errcode = '42501';
  end if;

  if v_row.role = 'partner' then
    select count(*) into v_partner_count
    from core.well_partners wp
    where wp.well_id = v_row.well_id
      and wp.person_id = v_row.person_id
      and wp.status = 'active'
      and wp.period_end is null;

    if v_partner_count <> 1 then
      raise exception 'تعذر تحديد Partner الحالي الوحيد للدعوة'
        using errcode = 'P0001';
    end if;

    select wp.id, wp.profile_id into v_partner_id, v_partner_profile
    from core.well_partners wp
    where wp.well_id = v_row.well_id
      and wp.person_id = v_row.person_id
      and wp.status = 'active'
      and wp.period_end is null
    for update;

    if v_partner_profile is not null and v_partner_profile <> v_profile then
      raise exception 'Partner التاريخي مربوط بحساب آخر'
        using errcode = '42501';
    end if;
  end if;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_row.well_id, v_profile, v_row.role, 'active')
  on conflict (well_id, profile_id, role)
  do update set status = 'active', updated_at = now();

  if v_row.role = 'partner' then
    update core.well_partners wp
    set profile_id = v_profile,
        activated_at = coalesce(wp.activated_at, now()),
        updated_at = now()
    where wp.id = v_partner_id
      and wp.status = 'active'
      and wp.period_end is null;
  end if;

  update core.well_invitations
  set status = 'confirmed',
      confirmed_by = v_actor,
      confirmed_at = now(),
      updated_at = now()
  where id = v_row.id;

  return jsonb_build_object(
    'contract', 'confirm_well_invitation',
    'version', 2,
    'outcome', 'confirmed',
    'invitation_id', v_row.id,
    'well_id', v_row.well_id,
    'profile_id', v_profile,
    'role', v_row.role
  );
end;
$function$;

comment on function core.confirm_well_invitation(uuid) is
  'ق-130: existing_auth يحافظ على M103؛ new_no_auth ينتقل إلى owner_confirmed_pending_account بلا Auth/Profile/Assignment.';

revoke all on function core.confirm_well_invitation(uuid)
  from public, anon, authenticated, service_role;
grant execute on function core.confirm_well_invitation(uuid)
  to authenticated, service_role;

-- الرفض قبل التأكيد يمحو token القابل للاستخدام، لا سجل القبول/الرفض.
create or replace function core.reject_well_invitation(
  p_invitation_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_well_id uuid;
  v_row core.well_invitations;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل رفض الدعوة'
      using errcode = '28000';
  end if;

  select inv.well_id into v_well_id
  from core.well_invitations inv
  where inv.id = p_invitation_id;

  if v_well_id is null then
    raise exception 'الدعوة غير موجودة'
      using errcode = '22023';
  end if;

  if not iam.has_well_permission(v_well_id, 'team.manage') then
    raise exception 'رفض أعضاء هذا البئر متاح لمالكه'
      using errcode = '42501';
  end if;

  select inv.* into v_row
  from core.well_invitations inv
  where inv.id = p_invitation_id
  for update;

  if v_row.status <> 'accepted_pending_owner' then
    raise exception 'لا يمكن رفض دعوة ليست بانتظار تأكيد المالك'
      using errcode = '42501';
  end if;

  update core.well_invitations
  set status = 'rejected',
      rejected_by = v_actor,
      rejected_at = now(),
      continuation_token_salt = null,
      continuation_token_hash = null,
      continuation_expires_at = null,
      updated_at = now()
  where id = v_row.id;

  return jsonb_build_object(
    'contract', 'reject_well_invitation',
    'version', case
      when v_row.acceptance_kind = 'new_no_auth' then 3
      else 2
    end,
    'outcome', 'rejected',
    'invitation_id', v_row.id,
    'well_id', v_row.well_id,
    'role', v_row.role
  );
end;
$function$;

revoke all on function core.reject_well_invitation(uuid)
  from public, anon, authenticated, service_role;
grant execute on function core.reject_well_invitation(uuid)
  to authenticated, service_role;

-- ==============================================================
-- 4. Preparation وCompletion: service_role فقط عبر api.*
-- ==============================================================

create or replace function core.prepare_member_finalization(
  p_continuation_token text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_token text := btrim(coalesce(p_continuation_token, ''));
  v_ids uuid[];
  v_inv core.well_invitations;
  v_profile_count integer;
  v_link_count integer;
  v_partner_count integer;
  v_partner_profile uuid;
  v_full_name text;
begin
  if length(v_token) < 48 or length(v_token) > 256 then
    raise exception 'token الاستمرار غير صالح'
      using errcode = '42501';
  end if;

  select array_agg(inv.id) into v_ids
  from core.well_invitations inv
  where inv.status = 'owner_confirmed_pending_account'
    and inv.acceptance_kind = 'new_no_auth'
    and inv.accepted_profile_id is null
    and inv.continuation_expires_at > now()
    and inv.continuation_token_hash =
      core.hash_member_finalization_token(
        v_token,
        inv.continuation_token_salt
      );

  if coalesce(cardinality(v_ids), 0) <> 1 then
    raise exception 'token الاستمرار غير صالح أو ملتبس'
      using errcode = '42501';
  end if;

  select inv.* into v_inv
  from core.well_invitations inv
  where inv.id = v_ids[1];

  select pe.full_name into v_full_name
  from core.persons pe
  where pe.id = v_inv.person_id
    and pe.tenant_id = v_inv.tenant_id
    and pe.status = 'active';

  if v_full_name is null then
    raise exception 'هوية الدعوة تحتاج مراجعة بشرية'
      using errcode = 'P0001';
  end if;

  select count(*) into v_profile_count
  from iam.profiles pr
  where core.normalize_phone(pr.phone) = v_inv.normalized_phone;

  if v_profile_count <> 0 then
    raise exception 'ظهر حساب لهذا الهاتف؛ استخدم مسار الحساب القائم'
      using errcode = '42501';
  end if;

  select count(*) into v_link_count
  from iam.profile_person_links l
  where l.person_id = v_inv.person_id
    and l.revoked_at is null;

  if v_link_count <> 0 then
    raise exception 'Person الدعوة مرتبط بحساب قائم'
      using errcode = '42501';
  end if;

  if v_inv.role = 'partner' then
    select count(*)
    into v_partner_count
    from core.well_partners wp
    where wp.well_id = v_inv.well_id
      and wp.person_id = v_inv.person_id
      and wp.status = 'active'
      and wp.period_end is null;

    if v_partner_count = 1 then
      select wp.profile_id
      into v_partner_profile
      from core.well_partners wp
      where wp.well_id = v_inv.well_id
        and wp.person_id = v_inv.person_id
        and wp.status = 'active'
        and wp.period_end is null;
    end if;

    if v_partner_count <> 1 or v_partner_profile is not null then
      raise exception 'تعذر تحديد Partner المالي الحالي غير المرتبط'
        using errcode = 'P0001';
    end if;
  end if;

  return jsonb_build_object(
    'contract', 'prepare_member_finalization',
    'version', 1,
    'outcome', 'ready',
    'invitation_id', v_inv.id,
    'tenant_id', v_inv.tenant_id,
    'well_id', v_inv.well_id,
    'person_id', v_inv.person_id,
    'role', v_inv.role,
    'normalized_phone', v_inv.normalized_phone,
    'full_name', v_full_name
  );
end;
$function$;

comment on function core.prepare_member_finalization(text) is
  'ق-130: service_role فقط؛ يتحقق من token والحالة والهوية وPartner، ويعيد أقل binding لازم لـAdmin createUser.';

revoke all on function core.prepare_member_finalization(text)
  from public, anon, authenticated, service_role;
grant execute on function core.prepare_member_finalization(text)
  to service_role;

create or replace function core.complete_member_finalization(
  p_continuation_token text,
  p_profile_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_token text := btrim(coalesce(p_continuation_token, ''));
  v_ids uuid[];
  v_inv core.well_invitations;
  v_completed core.well_invitations;
  v_profile_count integer;
  v_link_count integer;
  v_partner_count integer;
  v_partner_id uuid;
  v_partner_profile uuid;
  v_rows integer;
begin
  if p_profile_id is null then
    raise exception 'profile الجديد مطلوب'
      using errcode = '22023';
  end if;

  -- idempotency بعد استهلاك token: لا أثر جديد، ويقبل profile المكتمل نفسه.
  select inv.* into v_completed
  from core.well_invitations inv
  where inv.status = 'confirmed'
    and inv.acceptance_kind = 'new_no_auth'
    and inv.accepted_profile_id = p_profile_id
    and exists (
      select 1
      from iam.profile_person_links l
      where l.tenant_id = inv.tenant_id
        and l.profile_id = p_profile_id
        and l.person_id = inv.person_id
        and l.revoked_at is null
    )
    and exists (
      select 1
      from core.well_assignments wa
      where wa.well_id = inv.well_id
        and wa.profile_id = p_profile_id
        and wa.role = inv.role
        and wa.status = 'active'
    )
  order by inv.updated_at desc
  limit 1;

  if v_completed.id is not null then
    return jsonb_build_object(
      'contract', 'complete_member_finalization',
      'version', 1,
      'outcome', 'already_completed'
    );
  end if;

  if length(v_token) < 48 or length(v_token) > 256 then
    raise exception 'token الاستمرار غير صالح'
      using errcode = '42501';
  end if;

  select array_agg(inv.id) into v_ids
  from core.well_invitations inv
  where inv.status = 'owner_confirmed_pending_account'
    and inv.acceptance_kind = 'new_no_auth'
    and inv.accepted_profile_id is null
    and inv.continuation_expires_at > now()
    and inv.continuation_token_hash =
      core.hash_member_finalization_token(
        v_token,
        inv.continuation_token_salt
      );

  if coalesce(cardinality(v_ids), 0) <> 1 then
    raise exception 'token الاستمرار غير صالح أو ملتبس'
      using errcode = '42501';
  end if;

  select inv.* into v_inv
  from core.well_invitations inv
  where inv.id = v_ids[1]
  for update;

  if v_inv.status <> 'owner_confirmed_pending_account'
     or v_inv.acceptance_kind <> 'new_no_auth'
     or v_inv.accepted_profile_id is not null
     or v_inv.continuation_expires_at <= now()
     or v_inv.continuation_token_hash <>
       core.hash_member_finalization_token(
         v_token,
         v_inv.continuation_token_salt
       )
  then
    -- قد تكون معاملة متزامنة أكملت الصف أثناء انتظار القفل.
    select inv.* into v_completed
    from core.well_invitations inv
    where inv.status = 'confirmed'
      and inv.acceptance_kind = 'new_no_auth'
      and inv.accepted_profile_id = p_profile_id
    order by inv.updated_at desc
    limit 1;

    if v_completed.id is not null then
      return jsonb_build_object(
        'contract', 'complete_member_finalization',
        'version', 1,
        'outcome', 'already_completed'
      );
    end if;

    raise exception 'حالة finalization تغيرت'
      using errcode = '40001';
  end if;

  perform 1
  from core.persons pe
  where pe.id = v_inv.person_id
    and pe.tenant_id = v_inv.tenant_id
    and pe.status = 'active'
  for update;

  if not found then
    raise exception 'هوية الدعوة تحتاج مراجعة بشرية'
      using errcode = 'P0001';
  end if;

  perform 1
  from iam.profiles pr
  where pr.id = p_profile_id
  for update;

  if not found then
    raise exception 'ملف Auth الجديد غير موجود'
      using errcode = '42501';
  end if;

  select count(*) into v_profile_count
  from iam.profiles pr
  where core.normalize_phone(pr.phone) = v_inv.normalized_phone;

  if v_profile_count <> 1
     or not exists (
       select 1
       from iam.profiles pr
       where pr.id = p_profile_id
         and core.normalize_phone(pr.phone) = v_inv.normalized_phone
     )
  then
    raise exception 'Profile الجديد لا يطابق هاتف الدعوة أو الهاتف مكرر'
      using errcode = '42501';
  end if;

  select count(*) into v_link_count
  from iam.profile_person_links l
  where l.revoked_at is null
    and (
      l.profile_id = p_profile_id
      or l.person_id = v_inv.person_id
    );

  if v_link_count <> 0 then
    raise exception 'يوجد رابط Profile/Person متعارض'
      using errcode = '42501';
  end if;

  if v_inv.role = 'partner' then
    select count(*) into v_partner_count
    from core.well_partners wp
    where wp.well_id = v_inv.well_id
      and wp.person_id = v_inv.person_id
      and wp.status = 'active'
      and wp.period_end is null;

    if v_partner_count <> 1 then
      raise exception 'تعذر تحديد Partner المالي الحالي الوحيد'
        using errcode = 'P0001';
    end if;

    select wp.id, wp.profile_id into v_partner_id, v_partner_profile
    from core.well_partners wp
    where wp.well_id = v_inv.well_id
      and wp.person_id = v_inv.person_id
      and wp.status = 'active'
      and wp.period_end is null
    for update;

    if v_partner_profile is not null then
      raise exception 'Partner المالي الحالي مربوط بحساب آخر'
        using errcode = '42501';
    end if;
  end if;

  insert into iam.profile_person_links (
    tenant_id, profile_id, person_id,
    linked_by, link_reason
  ) values (
    v_inv.tenant_id, p_profile_id, v_inv.person_id,
    v_inv.confirmed_by, 'm104_member_finalization'
  );

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_inv.well_id, p_profile_id, v_inv.role, 'active')
  on conflict (well_id, profile_id, role)
  do update set status = 'active', updated_at = now();

  if v_inv.role = 'partner' then
    update core.well_partners wp
    set profile_id = p_profile_id,
        activated_at = coalesce(wp.activated_at, now()),
        updated_at = now()
    where wp.id = v_partner_id
      and wp.status = 'active'
      and wp.period_end is null
      and wp.profile_id is null;
    get diagnostics v_rows = row_count;

    if v_rows <> 1 then
      raise exception 'Partner المالي تغير أثناء finalization'
        using errcode = '40001';
    end if;
  end if;

  update core.well_invitations
  set accepted_profile_id = p_profile_id,
      status = 'confirmed',
      continuation_token_salt = null,
      continuation_token_hash = null,
      continuation_expires_at = null,
      updated_at = now()
  where id = v_inv.id
    and status = 'owner_confirmed_pending_account'
    and acceptance_kind = 'new_no_auth';
  get diagnostics v_rows = row_count;

  if v_rows <> 1 then
    raise exception 'الدعوة تغيرت أثناء finalization'
      using errcode = '40001';
  end if;

  return jsonb_build_object(
    'contract', 'complete_member_finalization',
    'version', 1,
    'outcome', 'confirmed'
  );
end;
$function$;

comment on function core.complete_member_finalization(text, uuid) is
  'ق-130: يعيد قفل الحالة، يربط Profile الجديد بالـPerson صراحة، ويفعل Assignment وPartner نفسه ذريًا ثم يستهلك token.';

revoke all on function core.complete_member_finalization(text, uuid)
  from public, anon, authenticated, service_role;
grant execute on function core.complete_member_finalization(text, uuid)
  to service_role;

create or replace function api.validate_member_finalization(
  p_phone text,
  p_code text
)
returns jsonb
language sql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
  select core.validate_member_finalization(p_phone, p_code);
$function$;

create or replace function api.prepare_member_finalization(
  p_continuation_token text
)
returns jsonb
language sql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
  select core.prepare_member_finalization(p_continuation_token);
$function$;

create or replace function api.complete_member_finalization(
  p_continuation_token text,
  p_profile_id uuid
)
returns jsonb
language sql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
  select core.complete_member_finalization(
    p_continuation_token,
    p_profile_id
  );
$function$;

revoke all on function api.validate_member_finalization(text, text)
  from public, anon, authenticated, service_role;
revoke all on function api.prepare_member_finalization(text)
  from public, anon, authenticated, service_role;
revoke all on function api.complete_member_finalization(text, uuid)
  from public, anon, authenticated, service_role;

grant execute on function api.validate_member_finalization(text, text)
  to service_role;
grant execute on function api.prepare_member_finalization(text)
  to service_role;
grant execute on function api.complete_member_finalization(text, uuid)
  to service_role;

comment on function api.validate_member_finalization(text, text) is
  'ق-130: service_role-only pre-auth validation؛ لا Auth ولا وصول.';
comment on function api.prepare_member_finalization(text) is
  'ق-130: service_role-only trusted binding قبل Admin createUser.';
comment on function api.complete_member_finalization(text, uuid) is
  'ق-130: service_role-only completion بعد Admin createUser؛ client لا يرسل profile/person/well/role.';

commit;
