-- ق-130 / م-44: الحساب القائم يقبل الدعوة ثم يؤكد المالك الهوية.
--
-- هذه الهجرة تُعيد تعريف عقود 094 دون تعديل التاريخ المنشور. الدعوة ليست
-- صلاحية، والقبول لا ينشئ Assignment؛ التأكيد وحده يفعّل الدور.

begin;

-- ==============================================================
-- 1. توسيع سجل الدعوة مع الحفاظ على claimed التاريخي
-- ==============================================================

alter table core.well_invitations
  add column if not exists accepted_profile_id uuid
    references iam.profiles(id) on delete set null,
  add column if not exists accepted_at timestamptz,
  add column if not exists confirmed_by uuid
    references iam.profiles(id) on delete set null,
  add column if not exists confirmed_at timestamptz,
  add column if not exists rejected_by uuid
    references iam.profiles(id) on delete set null,
  add column if not exists rejected_at timestamptz;

comment on column core.well_invitations.accepted_profile_id is
  'ق-130: الحساب الذي قبل الدعوة؛ لا يعني وجوده وصولًا نافذًا.';
comment on column core.well_invitations.accepted_at is
  'ق-130: وقت قبول الحساب القائم للدعوة.';
comment on column core.well_invitations.confirmed_by is
  'ق-130: profile المالك الذي أكد الهوية المقصودة.';
comment on column core.well_invitations.confirmed_at is
  'ق-130: وقت تأكيد المالك وإنشاء Assignment.';
comment on column core.well_invitations.rejected_by is
  'ق-130: profile المالك الذي رفض الهوية المقبولة.';
comment on column core.well_invitations.rejected_at is
  'ق-130: وقت الرفض الذي يحفظ مسار التصحيح.';

alter table core.well_invitations
  drop constraint if exists well_invitations_status_check;

alter table core.well_invitations
  add constraint well_invitations_status_check
  check (
    status in (
      'invited', 'accepted_pending_owner', 'confirmed', 'rejected',
      'claimed', 'expired', 'revoked'
    )
  );

alter table core.well_invitations
  drop constraint if exists well_invitations_claim_shape;

alter table core.well_invitations
  add constraint well_invitations_claim_shape
  check (
    (status = 'claimed')
    = (claimed_at is not null and claimed_profile_id is not null)
  );

alter table core.well_invitations
  drop constraint if exists well_invitations_lifecycle_audit_check;

alter table core.well_invitations
  add constraint well_invitations_lifecycle_audit_check
  check (
    (
      status in ('invited', 'expired', 'revoked')
      and accepted_profile_id is null
      and accepted_at is null
      and confirmed_by is null
      and confirmed_at is null
      and rejected_by is null
      and rejected_at is null
    )
    or (
      status = 'claimed'
      and accepted_profile_id is null
      and accepted_at is null
      and confirmed_by is null
      and confirmed_at is null
      and rejected_by is null
      and rejected_at is null
    )
    or (
      status = 'accepted_pending_owner'
      and accepted_profile_id is not null
      and accepted_at is not null
      and confirmed_by is null
      and confirmed_at is null
      and rejected_by is null
      and rejected_at is null
    )
    or (
      status = 'confirmed'
      and accepted_profile_id is not null
      and accepted_at is not null
      and confirmed_by is not null
      and confirmed_at is not null
      and rejected_by is null
      and rejected_at is null
    )
    or (
      status = 'rejected'
      and accepted_profile_id is not null
      and accepted_at is not null
      and confirmed_by is null
      and confirmed_at is null
      and rejected_by is not null
      and rejected_at is not null
    )
  );

-- كان قيد 094 يحمي invited وحدها. دورة ق-130 تعدّ pending_owner دعوة
-- مفتوحة كذلك؛ القيد الجزئي هو حاجز السباق، لا SELECT ... FOR UPDATE فقط.
drop index if exists core.well_invitations_open_uniq;
create unique index well_invitations_open_uniq
  on core.well_invitations (well_id, role, normalized_phone)
  where status in ('invited', 'accepted_pending_owner');

comment on table core.well_invitations is
  'ق-130: الدعوة طلب هوية بصفر صلاحية. الحساب القائم يقبلها، ثم يؤكد مالك البئر الهوية قبل إنشاء Assignment. تبقى أعمدة claimed_* لقراءة تاريخ ق-123.';

revoke all on table core.well_invitations from public, anon, authenticated;

-- ==============================================================
-- 2. الدعوة: Person/Partner تاريخي، بلا auto-link للحساب
-- ==============================================================

create or replace function core.invite_well_member(
  p_well_id uuid,
  p_role text,
  p_full_name text,
  p_phone text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_tenant uuid;
  v_name text := btrim(coalesce(p_full_name, ''));
  v_phone text := btrim(coalesce(p_phone, ''));
  v_norm text;
  v_person uuid;
  v_candidate_person_ids uuid[];
  v_candidate_count integer;
  v_candidate_person_status text;
  v_code text;
  v_salt text;
  v_invitation uuid;
  v_expires timestamptz;
  v_existing core.well_invitations;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل دعوة عضو'
      using errcode = '28000';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  if p_role is null or p_role not in ('operator', 'partner') then
    raise exception 'الدور المدعو غير مقبول: مشغّل أو شريك فقط'
      using errcode = '22023';
  end if;

  if v_name = '' then
    raise exception 'اسم العضو مطلوب'
      using errcode = '22023';
  end if;

  v_norm := core.normalize_phone(v_phone);
  if v_norm is null or v_norm = '' then
    raise exception 'رقم هاتف العضو مطلوب'
      using errcode = '22023';
  end if;

  if not iam.has_well_permission(p_well_id, 'team.manage') then
    raise exception 'إدارة فريق هذا البئر متاحة لمالكه'
      using errcode = '42501';
  end if;

  select w.tenant_id into v_tenant
  from core.wells w
  where w.id = p_well_id;

  if v_tenant is null then
    raise exception 'لا توجد صلاحية على هذا البئر'
      using errcode = '42501';
  end if;

  -- بعد القبول تتجمد الهوية المرشحة حتى يؤكدها المالك أو يرفضها.
  select inv.* into v_existing
  from core.well_invitations inv
  where inv.well_id = p_well_id
    and inv.role = p_role
    and inv.normalized_phone = v_norm
    and inv.status = 'accepted_pending_owner'
  order by inv.accepted_at desc
  limit 1
  for update;

  if v_existing.id is not null then
    return jsonb_build_object(
      'contract', 'invite_well_member',
      'version', 2,
      'outcome', 'accepted_pending_owner',
      'person_id', v_existing.person_id,
      'profile_id', v_existing.accepted_profile_id,
      'invitation_id', v_existing.id,
      'code', null,
      'expires_at', v_existing.expires_at
    );
  end if;

  -- صف confirmed يمنع دعوة جديدة فقط إذا كانت صلاحيته ما زالت فعالة. عند
  -- الإلغاء تبقى الدعوة التاريخية كما هي، وتبدأ دعوة جديدة بصفر وصول.
  select inv.* into v_existing
  from core.well_invitations inv
  join core.well_assignments wa
    on wa.well_id = inv.well_id
   and wa.profile_id = inv.accepted_profile_id
   and wa.role = inv.role
   and wa.status = 'active'
  where inv.well_id = p_well_id
    and inv.role = p_role
    and inv.normalized_phone = v_norm
    and inv.status = 'confirmed'
  order by inv.confirmed_at desc
  limit 1;

  if v_existing.id is not null then
    return jsonb_build_object(
      'contract', 'invite_well_member',
      'version', 2,
      'outcome', 'already_confirmed',
      'person_id', v_existing.person_id,
      'profile_id', v_existing.accepted_profile_id,
      'invitation_id', v_existing.id,
      'code', null,
      'expires_at', null
    );
  end if;

  -- الهاتف التاريخي قد يشير إلى أكثر من Person، بما في ذلك Person غير
  -- فعّال أو مدموج. لا نرتّب المرشحين ولا نعيد إحياء الهوية؛ كل تعارض أو
  -- حالة تاريخية غير فعّالة تحتاج مراجعة بشرية ولا تخلق هوية أو صلاحية.
  select array_agg(distinct candidate.person_id) into v_candidate_person_ids
  from (
    select pc.person_id
    from core.person_contacts pc
    where pc.tenant_id = v_tenant
      and core.normalize_phone(pc.normalized_value) = v_norm
    union all
    select wp.person_id
    from core.well_partners wp
    where wp.well_id = p_well_id
      and core.normalize_phone(wp.phone) = v_norm
  ) candidate
  join core.persons pe on pe.id = candidate.person_id;

  v_candidate_count := coalesce(array_length(v_candidate_person_ids, 1), 0);

  if v_candidate_count = 0 then
    insert into core.persons (
      tenant_id, full_name, normalized_name, created_by, updated_by
    ) values (
      v_tenant, v_name, core.normalize_arabic(v_name), v_actor, v_actor
    ) returning id into v_person;

    insert into core.person_contacts (
      tenant_id, person_id, contact_type, contact_value,
      normalized_value, is_primary
    ) values (
      v_tenant, v_person, 'mobile', v_phone, v_norm, true
    );
  elsif v_candidate_count = 1 then
    v_person := v_candidate_person_ids[1];
    select pe.status into v_candidate_person_status
    from core.persons pe
    where pe.id = v_person;

    if v_candidate_person_status <> 'active' then
      raise exception 'هوية رقم هاتف الدعوة تحتاج مراجعة بشرية'
        using errcode = 'P0001';
    end if;
  else
    raise exception 'هوية رقم هاتف الدعوة تحتاج مراجعة بشرية'
      using errcode = 'P0001';
  end if;

  -- قبل القبول فقط يمكن إعادة الإصدار وإبطال الصف القديم.
  update core.well_invitations
  set status = 'revoked',
      revoked_at = now(),
      updated_at = now()
  where well_id = p_well_id
    and role = p_role
    and normalized_phone = v_norm
    and status = 'invited';

  v_code := core.new_invitation_code();
  v_salt := replace(gen_random_uuid()::text, '-', '');
  v_expires := now() + interval '14 days';

  insert into core.well_invitations (
    tenant_id, well_id, role, person_id, phone, normalized_phone,
    code_salt, code_hash, expires_at, invited_by
  ) values (
    v_tenant, p_well_id, p_role, v_person, v_phone, v_norm,
    v_salt, core.hash_invitation_code(v_code, v_salt), v_expires, v_actor
  ) returning id into v_invitation;

  return jsonb_build_object(
    'contract', 'invite_well_member',
    'version', 2,
    'outcome', 'invited',
    'person_id', v_person,
    'profile_id', null,
    'invitation_id', v_invitation,
    'code', v_code,
    'expires_at', v_expires
  );
end;
$function$;

comment on function core.invite_well_member(uuid, text, text, text) is
  'ق-130: ينشئ أو يعيد استخدام Person بالتطبيع المركزي، ويصدر دعوة بصفر وصول. لا يربط iam.profiles ولا ينشئ well_assignment عند تطابق الهاتف.';

revoke all on function core.invite_well_member(uuid, text, text, text)
  from public, anon, authenticated, service_role;
grant execute on function core.invite_well_member(uuid, text, text, text)
  to authenticated, service_role;

-- ==============================================================
-- 3. قبول الحساب القائم: إثبات الهاتف، بلا Assignment
-- ==============================================================

create or replace function core.accept_well_invitation(
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
  v_norm text;
  v_row core.well_invitations;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قبول الدعوة'
      using errcode = '28000';
  end if;

  select core.normalize_phone(pr.phone) into v_norm
  from iam.profiles pr
  where pr.id = v_actor;

  if v_norm is null or v_norm = '' then
    raise exception 'لا رقم هاتف في بيانات حسابك — تعذر مطابقة الدعوة'
      using errcode = '22023';
  end if;

  select inv.* into v_row
  from core.well_invitations inv
  where inv.id = p_invitation_id
  for update;

  if v_row.id is null then
    raise exception 'الدعوة غير موجودة'
      using errcode = '22023';
  end if;

  if v_row.normalized_phone <> v_norm then
    raise exception 'هذه الدعوة ليست لحسابك'
      using errcode = '42501';
  end if;

  if v_row.status = 'accepted_pending_owner' then
    if v_row.accepted_profile_id = v_actor then
      return jsonb_build_object(
        'contract', 'accept_well_invitation',
        'version', 2,
        'outcome', 'already_accepted',
        'invitation_id', v_row.id,
        'well_id', v_row.well_id,
        'role', v_row.role
      );
    end if;
    raise exception 'الدعوة مقبولة لحساب آخر'
      using errcode = '42501';
  end if;

  if v_row.status = 'confirmed'
     and v_row.accepted_profile_id = v_actor then
    return jsonb_build_object(
      'contract', 'accept_well_invitation',
      'version', 2,
      'outcome', 'already_confirmed',
      'invitation_id', v_row.id,
      'well_id', v_row.well_id,
      'role', v_row.role
    );
  end if;

  if v_row.status = 'invited' and v_row.expires_at <= now() then
    update core.well_invitations
    set status = 'expired', updated_at = now()
    where id = v_row.id;

    return jsonb_build_object(
      'contract', 'accept_well_invitation',
      'version', 2,
      'outcome', 'expired',
      'invitation_id', v_row.id
    );
  end if;

  if v_row.status <> 'invited' then
    raise exception 'الدعوة غير قابلة للقبول في حالتها الحالية'
      using errcode = '42501';
  end if;

  update core.well_invitations
  set status = 'accepted_pending_owner',
      accepted_profile_id = v_actor,
      accepted_at = now(),
      updated_at = now()
  where id = v_row.id;

  return jsonb_build_object(
    'contract', 'accept_well_invitation',
    'version', 2,
    'outcome', 'accepted_pending_owner',
    'invitation_id', v_row.id,
    'well_id', v_row.well_id,
    'role', v_row.role
  );
end;
$function$;

comment on function core.accept_well_invitation(uuid) is
  'ق-130: الحساب القائم يقبل دعوته برقم الجلسة المطبّع. القبول يسجل audit فقط ولا ينشئ Assignment.';

revoke all on function core.accept_well_invitation(uuid)
  from public, anon, authenticated, service_role;
grant execute on function core.accept_well_invitation(uuid)
  to authenticated, service_role;

-- ==============================================================
-- 4. تأكيد المالك: Assignment واحد وربط Partner التاريخي
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

    if v_partner_id is null then
      raise exception 'تعذر قفل Partner الحالي للدعوة'
        using errcode = 'P0001';
    end if;

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
  'ق-130: team.manage للمالك فقط. يؤكد accepted_pending_owner ذريًا، ويعيد تفعيل Assignment الفريد ويربط Partner نفسه دون تعديل Share Versions.';

revoke all on function core.confirm_well_invitation(uuid)
  from public, anon, authenticated, service_role;
grant execute on function core.confirm_well_invitation(uuid)
  to authenticated, service_role;

-- ==============================================================
-- 5. رفض المالك: تدقيق محفوظ ومسار تصحيح بلا وصول
-- ==============================================================

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
      updated_at = now()
  where id = v_row.id;

  return jsonb_build_object(
    'contract', 'reject_well_invitation',
    'version', 2,
    'outcome', 'rejected',
    'invitation_id', v_row.id,
    'well_id', v_row.well_id,
    'role', v_row.role
  );
end;
$function$;

comment on function core.reject_well_invitation(uuid) is
  'ق-130: رفض المالك لحالة accepted_pending_owner يحفظ accepted/rejected audit ويترك Assignment صفرًا؛ إعادة الإصدار لاحقة لا تمحو الصف.';

revoke all on function core.reject_well_invitation(uuid)
  from public, anon, authenticated, service_role;
grant execute on function core.reject_well_invitation(uuid)
  to authenticated, service_role;

-- ==============================================================
-- 6. قراءة الدعوات للحساب وقراءة الفريق للمالك
-- ==============================================================

create or replace function core.list_my_well_invitations()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_norm text;
  v_items jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة دعواتك'
      using errcode = '28000';
  end if;

  select core.normalize_phone(pr.phone) into v_norm
  from iam.profiles pr
  where pr.id = v_actor;

  if v_norm is null or v_norm = '' then
    return jsonb_build_object(
      'contract', 'list_my_well_invitations',
      'version', 2,
      'invitations', '[]'::jsonb
    );
  end if;

  select coalesce(
    jsonb_agg(x.item order by x.invited_at desc), '[]'::jsonb
  ) into v_items
  from (
    select
      inv.invited_at,
      jsonb_build_object(
        'invitation_id', inv.id,
        'well_id', inv.well_id,
        'well_name', w.name,
        'person_id', inv.person_id,
        'full_name', pe.full_name,
        'phone', inv.phone,
        'role', inv.role,
        'status', inv.status,
        'expires_at', inv.expires_at,
        'invited_at', inv.invited_at,
        'accepted_at', inv.accepted_at
      ) as item
    from core.well_invitations inv
    join core.wells w on w.id = inv.well_id
    join core.persons pe on pe.id = inv.person_id
    where inv.normalized_phone = v_norm
      and (
        (inv.status = 'invited' and inv.expires_at > now())
        or inv.status = 'accepted_pending_owner'
      )
  ) x;

  return jsonb_build_object(
    'contract', 'list_my_well_invitations',
    'version', 2,
    'invitations', v_items
  );
end;
$function$;

comment on function core.list_my_well_invitations() is
  'ق-130: قراءة دعوات الحساب الحالي بالهاتف المطبّع فقط، بلا code_hash أو code_salt وبلا أي وصول.';

revoke all on function core.list_my_well_invitations()
  from public, anon, authenticated, service_role;
grant execute on function core.list_my_well_invitations()
  to authenticated, service_role;

create or replace function core.read_well_team(
  p_well_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_members jsonb;
  v_invitations jsonb;
begin
  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  if not iam.has_well_permission(p_well_id, 'team.manage') then
    raise exception 'قراءة فريق هذا البئر متاحة لمالكه'
      using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(x.item order by x.role, x.full_name), '[]'::jsonb)
  into v_members
  from (
    select
      wa.role,
      coalesce(pr.full_name, '') as full_name,
      jsonb_build_object(
        'profile_id', pr.id,
        'full_name', pr.full_name,
        'phone', pr.phone,
        'role', wa.role,
        'status', wa.status,
        'since', wa.created_at
      ) as item
    from core.well_assignments wa
    join iam.profiles pr on pr.id = wa.profile_id
    where wa.well_id = p_well_id
  ) x;

  select coalesce(jsonb_agg(y.item order by y.invited_at desc), '[]'::jsonb)
  into v_invitations
  from (
    select
      inv.invited_at,
      jsonb_build_object(
        'invitation_id', inv.id,
        'person_id', inv.person_id,
        'full_name', pe.full_name,
        'phone', inv.phone,
        'role', inv.role,
        'status', inv.status,
        'expires_at', inv.expires_at,
        'attempts_left', inv.attempts_left,
        'invited_at', inv.invited_at,
        'claimed_at', inv.claimed_at,
        'claimed_profile_id', inv.claimed_profile_id,
        'accepted_profile_id', inv.accepted_profile_id,
        'accepted_at', inv.accepted_at,
        'confirmed_by', inv.confirmed_by,
        'confirmed_at', inv.confirmed_at,
        'rejected_by', inv.rejected_by,
        'rejected_at', inv.rejected_at
      ) as item
    from core.well_invitations inv
    join core.persons pe on pe.id = inv.person_id
    where inv.well_id = p_well_id
  ) y;

  return jsonb_build_object(
    'contract', 'list_well_team',
    'version', 2,
    'members', v_members,
    'invitations', v_invitations
  );
end;
$function$;

comment on function core.read_well_team(uuid) is
  'ق-130: قراءة الفريق تعرض invited/accepted_pending_owner/confirmed/rejected وحوادث التدقيق بلا code_hash أو code_salt.';

revoke all on function core.read_well_team(uuid)
  from public, anon, authenticated, service_role;
grant execute on function core.read_well_team(uuid)
  to authenticated, service_role;

-- ==============================================================
-- 7. Q-123 claim: إبقاء التوقيع، وإغلاق المنح القديم
-- ==============================================================

-- لا نحذف التوقيع القديم كي لا نكسر العميل المنشور، لكن مسار Q-123 صار
-- fail-closed: لا يفحص الرمز ولا يغيّر دعوة ولا ينشئ Assignment. الصفوف
-- claimed التاريخية تبقى مقروءة، أما التفعيل الجديد فيمر accept ثم confirm.
create or replace function core.claim_well_invitation(
  p_code text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول قبل تنشيط الدعوة'
      using errcode = '28000';
  end if;

  return jsonb_build_object(
    'contract', 'claim_well_invitation',
    'version', 2,
    'outcome', 'superseded',
    'well_id', null,
    'role', null
  );
end;
$function$;

comment on function core.claim_well_invitation(text) is
  'ق-130: توقيع Q-123 محفوظ للتوافق، لكنه fail-closed ولا ينشئ Assignment. التفعيل الجديد عبر accept_well_invitation ثم confirm_well_invitation.';

revoke all on function core.claim_well_invitation(text)
  from public, anon, authenticated, service_role;
grant execute on function core.claim_well_invitation(text)
  to authenticated, service_role;

-- ==============================================================
-- 8. أغلفة api: INVOKER ورقيقة، بلا فتح anon
-- ==============================================================

create or replace function api.accept_well_invitation(
  p_invitation_id uuid
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول قبل قبول الدعوة'
      using errcode = '28000';
  end if;

  return core.accept_well_invitation(p_invitation_id);
end;
$function$;

comment on function api.accept_well_invitation(uuid) is
  'ق-130: قبول الحساب القائم لدعوته؛ لا يمنح وصولًا قبل تأكيد المالك.';
revoke all on function api.accept_well_invitation(uuid)
  from public, anon, authenticated, service_role;
grant execute on function api.accept_well_invitation(uuid)
  to authenticated, service_role;

create or replace function api.confirm_well_invitation(
  p_invitation_id uuid
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول قبل تأكيد الدعوة'
      using errcode = '28000';
  end if;

  return core.confirm_well_invitation(p_invitation_id);
end;
$function$;

comment on function api.confirm_well_invitation(uuid) is
  'ق-130: تأكيد team.manage للمالك فقط؛ ينشئ Assignment واحدًا عند accepted_pending_owner.';
revoke all on function api.confirm_well_invitation(uuid)
  from public, anon, authenticated, service_role;
grant execute on function api.confirm_well_invitation(uuid)
  to authenticated, service_role;

create or replace function api.reject_well_invitation(
  p_invitation_id uuid
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول قبل رفض الدعوة'
      using errcode = '28000';
  end if;

  return core.reject_well_invitation(p_invitation_id);
end;
$function$;

comment on function api.reject_well_invitation(uuid) is
  'ق-130: رفض team.manage للمالك فقط؛ يحفظ التدقيق ويترك صفر وصول.';
revoke all on function api.reject_well_invitation(uuid)
  from public, anon, authenticated, service_role;
grant execute on function api.reject_well_invitation(uuid)
  to authenticated, service_role;

create or replace function api.list_my_well_invitations()
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة دعواتك'
      using errcode = '28000';
  end if;

  return core.list_my_well_invitations();
end;
$function$;

comment on function api.list_my_well_invitations() is
  'ق-130: دعوات الحساب القائم بالهاتف المطبّع فقط، بلا أسرار وبلا وصول.';
revoke all on function api.list_my_well_invitations()
  from public, anon, authenticated, service_role;
grant execute on function api.list_my_well_invitations()
  to authenticated, service_role;

create or replace function api.claim_well_invitation(
  p_code text
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول قبل تنشيط الدعوة'
      using errcode = '28000';
  end if;

  return core.claim_well_invitation(p_code);
end;
$function$;

comment on function api.claim_well_invitation(text) is
  'ق-130: عقد Q-123 محفوظ للتوافق ويعيد superseded بلا إنشاء أو تفعيل Assignment.';
revoke all on function api.claim_well_invitation(text)
  from public, anon, authenticated, service_role;
grant execute on function api.claim_well_invitation(text)
  to authenticated, service_role;

-- عقد 094 الموجود يبقى INVOKER؛ إعادة التعليق توضح أن قراءته تعرض حالات ق-130.
comment on function api.list_well_team(uuid) is
  'ق-130: قراءة فريق البئر، بما فيها accepted_pending_owner وrejected، بلا أسرار الدعوة.';

commit;
