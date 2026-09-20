-- =====================================================================
-- Migration 102 — Farmer Identity Resolution Data-Safety Contract
-- القرارات الحاكمة: ق-84، ق-88، ق-89، ق-113، ق-114
--
-- هذه الدفعة توقف إنشاء هوية مزارع بصمت عند وجود مرشح يحتاج حسمًا.
-- واجهة الحسم البشري وحل المرجع المحلي مؤجلان عمدًا إلى الدفعة الثانية.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. قفل هوية المزارع
--
-- ترتيب الأقفال ثابت في كل استدعاء: الاسم أولًا، ثم الهاتف إن وُجد.
-- تفصل بادئة المجال مفاتيح الاسم عن الهاتف، وتدخل الجهة في كليهما.
-- الأقفال معاملية وتزول تلقائيًا عند COMMIT/ROLLBACK.
-- ---------------------------------------------------------------------

create or replace function ops.lock_farmer_identity(
  p_tenant_id uuid,
  p_normalized_name text,
  p_normalized_phone text default null
)
returns void
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_name_material text;
  v_phone_material text;
  v_name_key bigint;
  v_phone_key bigint;
begin
  if p_tenant_id is null then
    raise exception 'معرّف الجهة مطلوب لقفل هوية المزارع';
  end if;

  if nullif(btrim(p_normalized_name), '') is null then
    raise exception 'الاسم المطبع مطلوب لقفل هوية المزارع';
  end if;

  v_name_material :=
    'farmer_identity:name:' || p_tenant_id::text || ':' || p_normalized_name;
  v_name_key :=
    ('x' || substr(md5(v_name_material), 1, 16))::bit(64)::bigint;

  perform pg_advisory_xact_lock(v_name_key);

  if nullif(btrim(p_normalized_phone), '') is not null then
    v_phone_material :=
      'farmer_identity:phone:' || p_tenant_id::text || ':' || p_normalized_phone;
    v_phone_key :=
      ('x' || substr(md5(v_phone_material), 1, 16))::bit(64)::bigint;

    perform pg_advisory_xact_lock(v_phone_key);
  end if;
end;
$function$;

comment on function ops.lock_farmer_identity(uuid, text, text) is
  'ق-84/ق-88: قفل معاملي داخلي ومتسق الترتيب على اسم وهوية هاتف المزارع المطبعين داخل الجهة.';

revoke all on function ops.lock_farmer_identity(uuid, text, text)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2. عقد الأعمال: created / matched_existing / requires_resolution
-- ---------------------------------------------------------------------

create or replace function ops.create_farmer(
  p_well_id uuid,
  p_full_name text,
  p_phone text default null,
  p_preferred_name text default null,
  p_notes text default null,
  p_credit_limit_minor bigint default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_name text;
  v_phone text;
  v_person_id uuid;
  v_farmer_profile_id uuid;
  v_account_id uuid;
  v_exact_ids uuid[] := '{}'::uuid[];
  v_exact_total integer := 0;
  v_exact_active integer := 0;
  v_status text;
  v_candidates jsonb := '[]'::jsonb;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إنشاء مزارع';
  end if;

  if not iam.has_well_permission(p_well_id, 'farmer.create') then
    raise exception 'لا تملك صلاحية إنشاء مزارع في هذا البئر';
  end if;

  select w.tenant_id
  into v_tenant_id
  from core.wells w
  where w.id = p_well_id;

  if not found then
    raise exception 'البئر غير موجود: %', p_well_id;
  end if;

  v_name := core.normalize_arabic(p_full_name);
  v_phone := core.normalize_phone(p_phone);

  if v_name is null then
    raise exception 'اسم المزارع مطلوب';
  end if;

  if p_credit_limit_minor is not null and p_credit_limit_minor < 0 then
    raise exception 'حد الدين لا يجوز أن يكون سالبًا';
  end if;

  -- لا يُجرى أي فحص قرار قبل القفل. كل الفحوص التالية ترى الحالة
  -- بعد تسلسل الطلبات التي تتشارك الاسم أو الهاتف المطبع داخل الجهة.
  perform ops.lock_farmer_identity(v_tenant_id, v_name, v_phone);

  select
    coalesce(array_agg(p.id order by p.created_at, p.id), '{}'::uuid[]),
    count(*)::integer,
    count(*) filter (where p.status = 'active')::integer
  into v_exact_ids, v_exact_total, v_exact_active
  from core.persons p
  where v_phone is not null
    and p.tenant_id = v_tenant_id
    and p.status not in ('merged', 'archived')
    and core.normalize_arabic(p.full_name) = v_name
    and exists (
      select 1
      from core.person_contacts pc
      where pc.person_id = p.id
        and pc.tenant_id = v_tenant_id
        and pc.contact_type in ('mobile', 'whatsapp', 'landline')
        and core.normalize_phone(pc.contact_value) = v_phone
    );

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'person_id', d.person_id,
        'public_code', d.public_code,
        'full_name', d.full_name,
        'match_level', d.match_level,
        'matched_on', d.matched_on
      )
      order by
        case when d.match_level = 'match' then 0 else 1 end,
        case
          when d.matched_on = 'name+phone' then 0
          when d.matched_on = 'phone' then 1
          else 2
        end,
        d.public_code,
        d.person_id
    ),
    '[]'::jsonb
  )
  into v_candidates
  from core.find_person_duplicates(v_tenant_id, p_full_name, p_phone) d;

  -- أكثر من هوية تاريخية مطابقة تمامًا لا تُختزل إلى أول صف.
  if v_exact_total > 1 then
    return jsonb_build_object(
      'status', 'requires_resolution',
      'person_id', null,
      'farmer_profile_id', null,
      'farmer_well_account_id', null,
      'already_exists', false,
      'duplicate_candidates', v_candidates
    );
  end if;

  -- هوية مطابقة وحيدة غير فعالة ليست إعادة استخدام آمنة تلقائيًا.
  if v_exact_total = 1 and v_exact_active <> 1 then
    return jsonb_build_object(
      'status', 'requires_resolution',
      'person_id', null,
      'farmer_profile_id', null,
      'farmer_well_account_id', null,
      'already_exists', false,
      'duplicate_candidates', v_candidates
    );
  end if;

  if v_exact_total = 1 then
    v_person_id := v_exact_ids[1];
    v_status := 'matched_existing';

    -- يثبت الشخص أثناء استكمال ملف المزارع وحساب البئر.
    perform 1
    from core.persons p
    where p.id = v_person_id
    for update;

    select fp.id
    into v_farmer_profile_id
    from ops.farmer_profiles fp
    where fp.tenant_id = v_tenant_id
      and fp.person_id = v_person_id;

    if not found then
      insert into ops.farmer_profiles (tenant_id, person_id, notes)
      values (v_tenant_id, v_person_id, p_notes)
      returning id into v_farmer_profile_id;
    end if;

    select fwa.id
    into v_account_id
    from ops.farmer_well_accounts fwa
    where fwa.farmer_profile_id = v_farmer_profile_id
      and fwa.well_id = p_well_id;

    if not found then
      insert into ops.farmer_well_accounts (
        tenant_id,
        farmer_profile_id,
        well_id,
        public_code,
        credit_limit_minor,
        notes
      ) values (
        v_tenant_id,
        v_farmer_profile_id,
        p_well_id,
        core.generate_public_code('FWA'),
        p_credit_limit_minor,
        p_notes
      )
      returning id into v_account_id;
    end if;
  elsif jsonb_array_length(v_candidates) > 0 then
    -- أي مرشح غير محسوم يوقف الإنشاء كليًا.
    return jsonb_build_object(
      'status', 'requires_resolution',
      'person_id', null,
      'farmer_profile_id', null,
      'farmer_well_account_id', null,
      'already_exists', false,
      'duplicate_candidates', v_candidates
    );
  else
    v_status := 'created';

    insert into core.persons (
      tenant_id,
      full_name,
      normalized_name,
      preferred_name,
      notes,
      created_by,
      updated_by
    ) values (
      v_tenant_id,
      btrim(p_full_name),
      v_name,
      nullif(btrim(p_preferred_name), ''),
      p_notes,
      v_actor,
      v_actor
    )
    returning id into v_person_id;

    if v_phone is not null then
      insert into core.person_contacts (
        tenant_id,
        person_id,
        contact_type,
        contact_value,
        normalized_value,
        is_primary
      ) values (
        v_tenant_id,
        v_person_id,
        'mobile',
        btrim(p_phone),
        v_phone,
        true
      );
    end if;

    insert into ops.farmer_profiles (tenant_id, person_id, notes)
    values (v_tenant_id, v_person_id, p_notes)
    returning id into v_farmer_profile_id;

    insert into ops.farmer_well_accounts (
      tenant_id,
      farmer_profile_id,
      well_id,
      public_code,
      credit_limit_minor,
      notes
    ) values (
      v_tenant_id,
      v_farmer_profile_id,
      p_well_id,
      core.generate_public_code('FWA'),
      p_credit_limit_minor,
      p_notes
    )
    returning id into v_account_id;
  end if;

  perform audit.log(
    v_tenant_id,
    p_well_id,
    'create_farmer',
    'core.persons',
    v_person_id,
    null,
    jsonb_build_object(
      'status', v_status,
      'person_id', v_person_id,
      'farmer_profile_id', v_farmer_profile_id,
      'farmer_well_account_id', v_account_id,
      'already_exists', v_status = 'matched_existing',
      'duplicate_candidates', '[]'::jsonb
    ),
    case
      when v_status = 'matched_existing'
        then 'إعادة الشخص المطابق دون إنشاء مكرر'
      else 'إنشاء مزارع وحساب بئر'
    end
  );

  return jsonb_build_object(
    'status', v_status,
    'person_id', v_person_id,
    'farmer_profile_id', v_farmer_profile_id,
    'farmer_well_account_id', v_account_id,
    'already_exists', v_status = 'matched_existing',
    'duplicate_candidates', '[]'::jsonb
  );
end;
$function$;

comment on function ops.create_farmer(uuid, text, text, text, text, bigint) is
  'ق-84/ق-88: ينشئ هوية مزارع عند غياب المرشحين، أو يعيد مطابقًا حتميًا وحيدًا، أو يوقف الإنشاء بـ requires_resolution.';

-- نحافظ على حدود التنفيذ القائمة دون توسيع.
revoke all on function ops.create_farmer(uuid, text, text, text, text, bigint)
  from public, anon;
grant execute on function ops.create_farmer(uuid, text, text, text, text, bigint)
  to authenticated;

-- ---------------------------------------------------------------------
-- 3. الغلاف العام: accepted للنجاح وconflict للحسم البشري
-- ---------------------------------------------------------------------

create or replace function api.create_farmer(
  p_well_id uuid,
  p_full_name text,
  p_phone text default null,
  p_preferred_name text default null,
  p_notes text default null,
  p_credit_limit_minor bigint default null,
  p_command_id uuid default null
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_guard jsonb;
  v_result jsonb;
  v_command_status text;
begin
  if p_command_id is not null then
    v_guard := sync.begin_well_command(
      p_well_id,
      p_command_id,
      'create_farmer',
      null
    );

    if coalesce((v_guard ->> 'duplicate')::boolean, false) then
      if v_guard ->> 'status' in ('accepted', 'conflict') then
        return v_guard -> 'response';
      end if;

      raise exception 'العملية نفسها قيد المعالجة أو تحتاج مراجعة';
    end if;
  end if;

  v_result := ops.create_farmer(
    p_well_id,
    p_full_name,
    p_phone,
    p_preferred_name,
    p_notes,
    p_credit_limit_minor
  );

  if v_result ->> 'status' in ('created', 'matched_existing') then
    v_command_status := 'accepted';
  elsif v_result ->> 'status' = 'requires_resolution' then
    v_command_status := 'conflict';
  else
    raise exception
      'حالة غير متوقعة لإنشاء المزارع: %',
      coalesce(v_result ->> 'status', 'null');
  end if;

  if p_command_id is not null then
    perform sync.finish_well_command(
      p_well_id,
      p_command_id,
      v_command_status,
      v_result
    );
  end if;

  return v_result;
end;
$function$;

comment on function api.create_farmer(
  uuid, text, text, text, text, bigint, uuid
) is
  'ق-88/ق-114: غلاف invoker يحفظ created/matched_existing كـ accepted ويحفظ requires_resolution كـ conflict ويعيد الرد المخزن عند إعادة المحاولة.';

revoke all on function api.create_farmer(
  uuid, text, text, text, text, bigint, uuid
) from public, anon, authenticated, service_role;

grant execute on function api.create_farmer(
  uuid, text, text, text, text, bigint, uuid
) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 4. حسم هوية المزارع: use_existing أو different_person
-- ---------------------------------------------------------------------

create or replace function ops.resolve_farmer_identity(
  p_well_id uuid,
  p_original_command_id uuid,
  p_resolution_action text,
  p_selected_person_id uuid default null,
  p_full_name text default null,
  p_phone text default null,
  p_preferred_name text default null,
  p_notes text default null,
  p_credit_limit_minor bigint default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_orig_tenant_id uuid;
  v_orig_status text;
  v_orig_response jsonb;
  v_candidate_found boolean := false;
  v_person_id uuid;
  v_farmer_profile_id uuid;
  v_account_id uuid;
  v_name text;
  v_phone text;
  v_candidates jsonb := '[]'::jsonb;
  v_result jsonb;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل حسم هوية المزارع';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب لحسم هوية المزارع';
  end if;

  if p_original_command_id is null then
    raise exception 'معرّف العملية الأصلية مطلوب لحسم هوية المزارع';
  end if;

  if not iam.has_well_permission(p_well_id, 'farmer.create') then
    raise exception 'لا تملك صلاحية إنشاء مزارع في هذا البئر';
  end if;

  select w.tenant_id
  into v_tenant_id
  from core.wells w
  where w.id = p_well_id;

  if not found then
    raise exception 'البئر غير موجود: %', p_well_id;
  end if;

  if p_credit_limit_minor is not null and p_credit_limit_minor < 0 then
    raise exception 'حد الدين لا يجوز أن يكون سالبًا';
  end if;

  -- التحقق من الأمر الأصلي وحالته وردّه
  select pc.tenant_id, pc.status, pc.response_payload
  into v_orig_tenant_id, v_orig_status, v_orig_response
  from sync.processed_commands pc
  where pc.command_id = p_original_command_id;

  if not found then
    raise exception 'أمر إنشاء المزارع الأصلي غير موجود: %', p_original_command_id;
  end if;

  if v_orig_tenant_id <> v_tenant_id then
    raise exception 'الأمر الأصلي يتبع جهة أخرى';
  end if;

  if v_orig_status <> 'conflict' then
    raise exception 'حالة الأمر الأصلي ليست تعارضًا: %', v_orig_status;
  end if;

  if coalesce(v_orig_response ->> 'status', '') <> 'requires_resolution' then
    raise exception 'رد الأمر الأصلي لا يتطلب حسمًا: %', v_orig_response ->> 'status';
  end if;

  if p_resolution_action = 'use_existing' then
    if p_selected_person_id is null then
      raise exception 'معرّف الشخص المختار مطلوب عند استخدام مزارع قائم';
    end if;

    -- التحقق من أن الشخص المختار كان ضمن مرشحي التعارض للأمر الأصلي
    select exists (
      select 1
      from jsonb_array_elements(v_orig_response -> 'duplicate_candidates') c
      where (c ->> 'person_id')::uuid = p_selected_person_id
    ) into v_candidate_found;

    if not v_candidate_found then
      raise exception 'الشخص المحدد لم يكن ضمن مرشحي التعارض للأمر الأصلي';
    end if;

    -- إعادة التحقق من أن الشخص ما زال فعالًا وقانونيًا لنفس الجهة
    select p.id
    into v_person_id
    from core.persons p
    where p.id = p_selected_person_id
      and p.tenant_id = v_tenant_id
      and p.status = 'active'
    for update;

    if not found then
      raise exception 'الشخص المحدد غير موجود أو غير فعال في هذه الجهة';
    end if;

    -- إنشاء أو إعادة استخدام farmer_profile
    select fp.id
    into v_farmer_profile_id
    from ops.farmer_profiles fp
    where fp.tenant_id = v_tenant_id
      and fp.person_id = v_person_id;

    if not found then
      insert into ops.farmer_profiles (tenant_id, person_id, notes)
      values (v_tenant_id, v_person_id, p_notes)
      returning id into v_farmer_profile_id;
    end if;

    -- إنشاء أو إعادة استخدام farmer_well_account
    select fwa.id
    into v_account_id
    from ops.farmer_well_accounts fwa
    where fwa.farmer_profile_id = v_farmer_profile_id
      and fwa.well_id = p_well_id;

    if not found then
      insert into ops.farmer_well_accounts (
        tenant_id,
        farmer_profile_id,
        well_id,
        public_code,
        credit_limit_minor,
        notes
      ) values (
        v_tenant_id,
        v_farmer_profile_id,
        p_well_id,
        core.generate_public_code('FWA'),
        p_credit_limit_minor,
        p_notes
      )
      returning id into v_account_id;
    end if;

    v_result := jsonb_build_object(
      'status', 'matched_existing',
      'person_id', v_person_id,
      'farmer_profile_id', v_farmer_profile_id,
      'farmer_well_account_id', v_account_id,
      'already_exists', true,
      'duplicate_candidates', '[]'::jsonb
    );

    perform audit.log(
      v_tenant_id,
      p_well_id,
      'resolve_farmer_identity',
      'core.persons',
      v_person_id,
      null,
      v_result,
      'حسم هوية مزارع باختيار شخص قائم'
    );

    return v_result;

  elsif p_resolution_action = 'different_person' then
    v_name := core.normalize_arabic(p_full_name);
    v_phone := core.normalize_phone(p_phone);

    if v_name is null then
      raise exception 'اسم المزارع مطلوب لحسم الشخص المختلف';
    end if;

    -- قفل معاملي على الاسم والهاتف إن وجد
    perform ops.lock_farmer_identity(v_tenant_id, v_name, v_phone);

    -- ق-88: نفس الهاتف المطبع لأي مرشح قائم لا يمكن تجاوزه أبدًا كشخص مختلف
    if v_phone is not null and exists (
      select 1
      from jsonb_array_elements(v_orig_response -> 'duplicate_candidates') c
      join core.person_contacts pc on pc.person_id = (c ->> 'person_id')::uuid
      where pc.tenant_id = v_tenant_id
        and pc.contact_type in ('mobile', 'whatsapp', 'landline')
        and core.normalize_phone(pc.contact_value) = v_phone
    ) then
      raise exception 'لا يمكن حسم الهوية كشخص مختلف بنفس رقم هاتف مرشح قائم';
    end if;

    -- هاتف مطابق لأي شخص موجود في الجهة لا يمكن تجاوزه
    if v_phone is not null and exists (
      select 1
      from core.person_contacts pc
      where pc.tenant_id = v_tenant_id
        and pc.contact_type in ('mobile', 'whatsapp', 'landline')
        and core.normalize_phone(pc.contact_value) = v_phone
    ) then
      raise exception 'رقم الهاتف مستخدم بالفعل لشخص آخر في هذه الجهة';
    end if;

    -- فحص المرشحين للهوية المقترحة
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'person_id', d.person_id,
          'public_code', d.public_code,
          'full_name', d.full_name,
          'match_level', d.match_level,
          'matched_on', d.matched_on
        )
        order by
          case when d.match_level = 'match' then 0 else 1 end,
          case
            when d.matched_on = 'name+phone' then 0
            when d.matched_on = 'phone' then 1
            else 2
          end,
          d.public_code,
          d.person_id
      ),
      '[]'::jsonb
    )
    into v_candidates
    from core.find_person_duplicates(v_tenant_id, p_full_name, p_phone) d;

    -- غياب الهاتف مع وجود اشتباه/مرشحين يعني نقص بيانات التمييز ويفشل مغلقًا
    if v_phone is null and jsonb_array_length(v_candidates) > 0 then
      return jsonb_build_object(
        'status', 'requires_resolution',
        'person_id', null,
        'farmer_profile_id', null,
        'farmer_well_account_id', null,
        'already_exists', false,
        'duplicate_candidates', v_candidates
      );
    end if;

    -- إذا كانت البيانات مميزة قانونيًا (هاتف مختلف حقيقي وغير مستخدم)، يُنشأ شخص واحد فقط
    insert into core.persons (
      tenant_id,
      full_name,
      normalized_name,
      preferred_name,
      notes,
      created_by,
      updated_by
    ) values (
      v_tenant_id,
      btrim(p_full_name),
      v_name,
      nullif(btrim(p_preferred_name), ''),
      p_notes,
      v_actor,
      v_actor
    )
    returning id into v_person_id;

    if v_phone is not null then
      insert into core.person_contacts (
        tenant_id,
        person_id,
        contact_type,
        contact_value,
        normalized_value,
        is_primary
      ) values (
        v_tenant_id,
        v_person_id,
        'mobile',
        btrim(p_phone),
        v_phone,
        true
      );
    end if;

    insert into ops.farmer_profiles (tenant_id, person_id, notes)
    values (v_tenant_id, v_person_id, p_notes)
    returning id into v_farmer_profile_id;

    insert into ops.farmer_well_accounts (
      tenant_id,
      farmer_profile_id,
      well_id,
      public_code,
      credit_limit_minor,
      notes
    ) values (
      v_tenant_id,
      v_farmer_profile_id,
      p_well_id,
      core.generate_public_code('FWA'),
      p_credit_limit_minor,
      p_notes
    )
    returning id into v_account_id;

    v_result := jsonb_build_object(
      'status', 'created',
      'person_id', v_person_id,
      'farmer_profile_id', v_farmer_profile_id,
      'farmer_well_account_id', v_account_id,
      'already_exists', false,
      'duplicate_candidates', '[]'::jsonb
    );

    perform audit.log(
      v_tenant_id,
      p_well_id,
      'resolve_farmer_identity',
      'core.persons',
      v_person_id,
      null,
      v_result,
      'حسم هوية مزارع كشخص مختلف ومميز قانونيًا'
    );

    return v_result;
  else
    raise exception 'إجراء حسم الهوية غير معروف: %', p_resolution_action;
  end if;
end;
$function$;

comment on function ops.resolve_farmer_identity(
  uuid, uuid, text, uuid, text, text, text, text, bigint
) is
  'ق-88/ق-114: ينفذ حسم هوية المزارع باختيار مرشح قائم أو توثيق شخص مميز قانونيًا بهاتف مختلف حقيقي.';

revoke all on function ops.resolve_farmer_identity(
  uuid, uuid, text, uuid, text, text, text, text, bigint
) from public, anon;

grant execute on function ops.resolve_farmer_identity(
  uuid, uuid, text, uuid, text, text, text, text, bigint
) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 5. الغلاف العام لحسم هوية المزارع: api.resolve_farmer_identity
-- ---------------------------------------------------------------------

create or replace function api.resolve_farmer_identity(
  p_well_id uuid,
  p_original_command_id uuid,
  p_resolution_action text,
  p_command_id uuid,
  p_selected_person_id uuid default null,
  p_full_name text default null,
  p_phone text default null,
  p_preferred_name text default null,
  p_notes text default null,
  p_credit_limit_minor bigint default null
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_guard jsonb;
  v_result jsonb;
  v_command_status text;
begin
  if p_command_id is null then
    raise exception 'معرّف عملية الحسم مطلوب';
  end if;

  v_guard := sync.begin_well_command(
    p_well_id,
    p_command_id,
    'resolve_farmer_identity',
    null
  );

  if coalesce((v_guard ->> 'duplicate')::boolean, false) then
    if v_guard ->> 'status' in ('accepted', 'conflict') then
      return v_guard -> 'response';
    end if;

    raise exception 'العملية نفسها قيد المعالجة أو تحتاج مراجعة';
  end if;

  v_result := ops.resolve_farmer_identity(
    p_well_id,
    p_original_command_id,
    p_resolution_action,
    p_selected_person_id,
    p_full_name,
    p_phone,
    p_preferred_name,
    p_notes,
    p_credit_limit_minor
  );

  if v_result ->> 'status' in ('created', 'matched_existing') then
    v_command_status := 'accepted';
  elsif v_result ->> 'status' = 'requires_resolution' then
    v_command_status := 'conflict';
  else
    raise exception
      'حالة غير متوقعة لحسم هوية المزارع: %',
      coalesce(v_result ->> 'status', 'null');
  end if;

  perform sync.finish_well_command(
    p_well_id,
    p_command_id,
    v_command_status,
    v_result
  );

  return v_result;
end;
$function$;

comment on function api.resolve_farmer_identity(
  uuid, uuid, text, uuid, uuid, text, text, text, text, bigint
) is
  'ق-88/ق-114: غلاف invoker لحسم هوية المزارع يحفظ created/matched_existing كـ accepted ويحفظ requires_resolution كـ conflict ويعيد الرد المخزن عند إعادة المحاولة.';

revoke all on function api.resolve_farmer_identity(
  uuid, uuid, text, uuid, uuid, text, text, text, text, bigint
) from public, anon, authenticated, service_role;

grant execute on function api.resolve_farmer_identity(
  uuid, uuid, text, uuid, uuid, text, text, text, text, bigint
) to authenticated, service_role;

commit;
