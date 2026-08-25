begin;

set local timezone to 'UTC';

do $test$
declare
  v_count bigint;

  v_user_1 uuid;
  v_user_2 uuid;

  v_tenant_1 uuid;
  v_tenant_2 uuid;

  v_person_1 uuid;
  v_person_2 uuid;
  v_person_3 uuid;
  v_person_4 uuid;

  v_link_1 uuid;
  v_link_2 uuid;
  v_link_3 uuid;

  v_resolved uuid;
begin

  -- ============================================================
  -- 1. الجدول موجود وRLS مفعلة
  -- ============================================================

  if exists (
    select 1
    from pg_class c
    join pg_namespace n
      on n.oid = c.relnamespace
    where n.nspname = 'iam'
      and c.relname = 'profile_person_links'
      and c.relkind = 'r'
      and c.relrowsecurity
  ) then
    raise notice
      'PASS 1: profile_person_links موجود وRLS مفعلة';
  else
    raise notice
      'FAIL 1: جدول رابط الهوية مفقود أو RLS غير مفعلة';
  end if;


  -- ============================================================
  -- 2. Tenant/Person integrity مثبتة بقاعدة البيانات
  -- ============================================================

  select count(*)
  into v_count
  from pg_constraint c
  where c.conname = any(array[
    'persons_tenant_id_id_key',
    'profile_person_links_tenant_person_fkey'
  ]);

  if v_count = 2 then
    raise notice
      'PASS 2: Tenant/Person integrity مثبتة بقيود قاعدة البيانات';
  else
    raise notice
      'FAIL 2: عدد قيود Tenant/Person = % بدل 2',
      v_count;
  end if;


  -- ============================================================
  -- 3. Active uniqueness
  -- ============================================================

  select count(*)
  into v_count
  from pg_indexes
  where schemaname = 'iam'
    and tablename = 'profile_person_links'
    and indexname = any(array[
      'profile_person_links_active_profile_tenant_unique',
      'profile_person_links_active_person_unique'
    ]);

  if v_count = 2 then
    raise notice
      'PASS 3: Active profile/person uniqueness موجودة';
  else
    raise notice
      'FAIL 3: Active uniqueness indexes = % بدل 2',
      v_count;
  end if;


  -- ============================================================
  -- 4. لا Direct Client Table Access
  -- ============================================================

  if not has_table_privilege(
       'authenticated',
       'iam.profile_person_links',
       'SELECT'
     )
     and not has_table_privilege(
       'authenticated',
       'iam.profile_person_links',
       'INSERT'
     )
     and not has_table_privilege(
       'authenticated',
       'iam.profile_person_links',
       'UPDATE'
     )
     and not has_table_privilege(
       'authenticated',
       'iam.profile_person_links',
       'DELETE'
     )
     and not has_table_privilege(
       'anon',
       'iam.profile_person_links',
       'SELECT'
     )
  then
    raise notice
      'PASS 4: لا Direct Client Access على رابط الهوية';
  else
    raise notice
      'FAIL 4: توجد صلاحية مباشرة غير مسموحة على رابط الهوية';
  end if;


  -- ============================================================
  -- 5. Helper آمنة وفي Internal Schema
  -- ============================================================

  if exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'iam'
      and p.proname = 'current_person_id'
      and pg_get_function_identity_arguments(p.oid)
          = 'p_tenant_id uuid'
      and p.prosecdef
      and has_function_privilege(
        'authenticated',
        p.oid,
        'EXECUTE'
      )
      and not has_function_privilege(
        'anon',
        p.oid,
        'EXECUTE'
      )
      and exists (
        select 1
        from unnest(
          coalesce(p.proconfig, array[]::text[])
        ) cfg
        where cfg = 'search_path=iam, core, pg_temp'
      )
  ) then
    raise notice
      'PASS 5: current_person_id Definer آمنة وبمنح صريح';
  else
    raise notice
      'FAIL 5: أمان أو منح current_person_id غير صحيح';
  end if;


  -- ============================================================
  -- Setup
  -- ============================================================

  insert into auth.users (
    id,
    instance_id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    raw_user_meta_data,
    created_at,
    updated_at
  )
  values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'q110-user-1@test.local',
    crypt('x', gen_salt('bf')),
    now(),
    jsonb_build_object(
      'full_name',
      'شخص مطابق ظاهريًا'
    ),
    now(),
    now()
  )
  returning id into v_user_1;


  insert into auth.users (
    id,
    instance_id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    raw_user_meta_data,
    created_at,
    updated_at
  )
  values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'q110-user-2@test.local',
    crypt('x', gen_salt('bf')),
    now(),
    jsonb_build_object(
      'full_name',
      'حساب اختبار ثان'
    ),
    now(),
    now()
  )
  returning id into v_user_2;


  update iam.profiles
  set
    full_name = 'شخص مطابق ظاهريًا',
    phone = '777000110'
  where id = v_user_1;


  insert into core.tenants (name)
  values ('Tenant اختبار ق-110 الأول')
  returning id into v_tenant_1;


  insert into core.tenants (name)
  values ('Tenant اختبار ق-110 الثاني')
  returning id into v_tenant_2;


  insert into core.persons (
    tenant_id,
    full_name,
    normalized_name
  )
  values (
    v_tenant_1,
    'شخص مطابق ظاهريًا',
    'شخص مطابق ظاهريا'
  )
  returning id into v_person_1;


  insert into core.person_contacts (
    tenant_id,
    person_id,
    contact_type,
    contact_value,
    normalized_value,
    is_primary,
    verified_at
  )
  values (
    v_tenant_1,
    v_person_1,
    'mobile',
    '777000110',
    '777000110',
    true,
    now()
  );


  insert into core.persons (
    tenant_id,
    full_name,
    normalized_name
  )
  values (
    v_tenant_2,
    'الشخص نفسه في Tenant آخر',
    'الشخص نفسه في tenant اخر'
  )
  returning id into v_person_2;


  insert into core.persons (
    tenant_id,
    full_name,
    normalized_name
  )
  values (
    v_tenant_1,
    'شخص بديل للاختبار',
    'شخص بديل للاختبار'
  )
  returning id into v_person_3;


  -- شخص مستقل في Tenant الثاني لا يملك أي Login Link.
  -- يستخدم فقط لعزل اختبار Tenant mismatch.
  insert into core.persons (
    tenant_id,
    full_name,
    normalized_name
  )
  values (
    v_tenant_2,
    'شخص مستقل في Tenant الثاني',
    'شخص مستقل في tenant الثاني'
  )
  returning id into v_person_4;


  -- ============================================================
  -- 6. لا تخمين حتى مع تطابق الاسم والهاتف
  -- ============================================================

  perform set_config(
    'request.jwt.claim.sub',
    v_user_1::text,
    true
  );

  execute 'set local role authenticated';

  v_resolved := iam.current_person_id(v_tenant_1);

  execute 'reset role';

  if v_resolved is null then
    raise notice
      'PASS 6: لا Name/Phone guessing قبل وجود رابط صريح';
  else
    raise notice
      'FAIL 6: تم استنتاج Person دون رابط صريح';
  end if;


  -- ============================================================
  -- إنشاء الروابط الصريحة
  -- ============================================================

  insert into iam.profile_person_links (
    tenant_id,
    profile_id,
    person_id,
    linked_by,
    link_reason
  )
  values (
    v_tenant_1,
    v_user_1,
    v_person_1,
    v_user_1,
    'اختبار ربط صريح داخل Tenant الأول'
  )
  returning id into v_link_1;


  insert into iam.profile_person_links (
    tenant_id,
    profile_id,
    person_id,
    linked_by,
    link_reason
  )
  values (
    v_tenant_2,
    v_user_1,
    v_person_2,
    v_user_1,
    'اختبار أن الحساب العالمي يمكن ربطه بشخص Tenant-scoped آخر'
  )
  returning id into v_link_2;


  -- ============================================================
  -- 7. نفس Account يمكن أن يحل Person الصحيحة لكل Tenant
  -- ============================================================

  perform set_config(
    'request.jwt.claim.sub',
    v_user_1::text,
    true
  );

  execute 'set local role authenticated';

  if iam.current_person_id(v_tenant_1) = v_person_1
     and iam.current_person_id(v_tenant_2) = v_person_2
  then
    raise notice
      'PASS 7: Account العالمية تحل Person الصحيحة لكل Tenant';
  else
    raise notice
      'FAIL 7: Tenant-scoped identity resolution غير صحيح';
  end if;

  execute 'reset role';


  -- ============================================================
  -- 8. لا شخصان فعالان لنفس Account داخل Tenant واحدة
  -- ============================================================

  begin
    insert into iam.profile_person_links (
      tenant_id,
      profile_id,
      person_id,
      link_reason
    )
    values (
      v_tenant_1,
      v_user_1,
      v_person_3,
      'يجب أن يرفض'
    );

    raise notice
      'FAIL 8: سُمح بربط Account بشخصين فعالين داخل Tenant واحدة';

  exception
    when unique_violation then
      raise notice
        'PASS 8: رُفض شخص فعال ثان لنفس Account/Tenant';
  end;


  -- ============================================================
  -- 9. Person واحدة لا ترتبط بحسابين فعالين
  -- ============================================================

  begin
    insert into iam.profile_person_links (
      tenant_id,
      profile_id,
      person_id,
      link_reason
    )
    values (
      v_tenant_1,
      v_user_2,
      v_person_1,
      'يجب أن يرفض'
    );

    raise notice
      'FAIL 9: سُمح بربط Person نفسها بحسابين فعالين';

  exception
    when unique_violation then
      raise notice
        'PASS 9: رُفض حساب دخول فعال ثان لنفس Person';
  end;


  -- ============================================================
  -- 10. Tenant mismatch مرفوض بFK
  -- ============================================================

  begin
    insert into iam.profile_person_links (
      tenant_id,
      profile_id,
      person_id,
      link_reason
    )
    values (
      v_tenant_1,
      v_user_2,
      v_person_4,
      'Person من Tenant أخرى — يجب أن يرفض'
    );

    raise notice
      'FAIL 10: سُمح بربط Person من Tenant مختلفة';

  exception
    when foreign_key_violation then
      raise notice
        'PASS 10: رُفض Tenant/Person mismatch';
  end;


  -- ============================================================
  -- 11. الرابط القائم لا يعاد توجيهه
  -- ============================================================

  begin
    update iam.profile_person_links
    set person_id = v_person_3
    where id = v_link_1;

    raise notice
      'FAIL 11: سُمح بإعادة توجيه رابط الهوية تاريخيًا';

  exception
    when others then
      if position(
        'لا يمكن إعادة توجيه رابط هوية قائم'
        in sqlerrm
      ) > 0 then
        raise notice
          'PASS 11: Retarget لرابط الهوية مرفوض';
      else
        raise notice
          'FAIL 11: سبب رفض Retarget غير متوقع: %',
          sqlerrm;
      end if;
  end;


  -- ============================================================
  -- 12. Hard Delete مرفوض
  -- ============================================================

  begin
    delete from iam.profile_person_links
    where id = v_link_2;

    raise notice
      'FAIL 12: سُمح بحذف رابط هوية تاريخي';

  exception
    when others then
      if position(
        'لا يمكن حذف رابط الهوية'
        in sqlerrm
      ) > 0 then
        raise notice
          'PASS 12: Hard Delete لرابط الهوية مرفوض';
      else
        raise notice
          'FAIL 12: سبب رفض Delete غير متوقع: %',
          sqlerrm;
      end if;
  end;


  -- ============================================================
  -- 13. حدود api الحالية لم تتغير
  -- ============================================================

  if (
       select count(*)
       from pg_proc p
       join pg_namespace n
         on n.oid = p.pronamespace
       where n.nspname = 'api'
         and has_function_privilege(
           'authenticated',
           p.oid,
           'EXECUTE'
         )
     ) >= 33
     and (
       select count(*)
       from pg_proc p
       join pg_namespace n
         on n.oid = p.pronamespace
       where n.nspname = 'api'
         and has_function_privilege(
           'anon',
           p.oid,
           'EXECUTE'
         )
     ) = 0
     and (
       select count(*)
       from pg_proc p
       join pg_namespace n
         on n.oid = p.pronamespace
       where n.nspname = 'api'
         and p.prosecdef
     ) = 0
     and (
       select count(*)
       from pg_class c
       join pg_namespace n
         on n.oid = c.relnamespace
       where n.nspname = 'api'
         and c.relkind in ('r', 'v', 'm', 'f', 'p')
     ) = 0
  then
    raise notice
      'PASS 13: Data API surface آمن ومطابق وanon/Definer exposure = 0';
  else
    raise notice
      'FAIL 13: Data API security surface تغير بصورة غير متوقعة';
  end if;



  -- ============================================================
  -- 14. Revoke يجعل الرابط غير فعال ويحفظ metadata متماسكة
  -- ============================================================

  update iam.profile_person_links
  set
    revoked_at = now(),
    revoked_by = v_user_1,
    revoke_reason = 'تصحيح رابط الهوية للاختبار'
  where id = v_link_1;

  perform set_config(
    'request.jwt.claim.sub',
    v_user_1::text,
    true
  );

  execute 'set local role authenticated';

  v_resolved := iam.current_person_id(v_tenant_1);

  execute 'reset role';

  if v_resolved is null
     and exists (
       select 1
       from iam.profile_person_links
       where id = v_link_1
         and revoked_at is not null
         and revoked_by = v_user_1
         and revoke_reason = 'تصحيح رابط الهوية للاختبار'
     )
  then
    raise notice
      'PASS 14: Revoke عطّل الرابط وحفظ metadata التاريخية';
  else
    raise notice
      'FAIL 14: Revoke أو identity resolution بعده غير صحيح';
  end if;


  -- ============================================================
  -- 15. التصحيح المعتمد = Revoke old + Explicit New Link
  -- ============================================================

  insert into iam.profile_person_links (
    tenant_id,
    profile_id,
    person_id,
    linked_by,
    link_reason
  )
  values (
    v_tenant_1,
    v_user_1,
    v_person_3,
    v_user_1,
    'رابط صريح بديل بعد إلغاء الرابط السابق'
  )
  returning id into v_link_3;

  perform set_config(
    'request.jwt.claim.sub',
    v_user_1::text,
    true
  );

  execute 'set local role authenticated';

  v_resolved := iam.current_person_id(v_tenant_1);

  execute 'reset role';

  if v_resolved = v_person_3 then
    raise notice
      'PASS 15: Revoke old + Explicit New Link يعمل كما يفرض ق-110';
  else
    raise notice
      'FAIL 15: الرابط البديل لم يصبح الهوية الفعالة';
  end if;


  -- ============================================================
  -- 16. الرابط الملغى لا يمكن إعادة تفعيله
  -- ============================================================

  begin
    update iam.profile_person_links
    set
      revoked_at = null,
      revoked_by = null,
      revoke_reason = null
    where id = v_link_1;

    raise notice
      'FAIL 16: سُمح بإعادة تفعيل رابط هوية تاريخي';

  exception
    when others then
      if position(
        'لا يمكن تعديل بيانات إلغاء رابط هوية تاريخي'
        in sqlerrm
      ) > 0 then
        raise notice
          'PASS 16: إعادة تفعيل الرابط التاريخي مرفوضة';
      else
        raise notice
          'FAIL 16: سبب رفض إعادة التفعيل غير متوقع: %',
          sqlerrm;
      end if;
  end;


  -- ============================================================
  -- 17. Revocation metadata لا تعدل بعد تثبيتها
  -- ============================================================

  begin
    update iam.profile_person_links
    set revoke_reason = 'محاولة تغيير التاريخ'
    where id = v_link_1;

    raise notice
      'FAIL 17: سُمح بتعديل revoke metadata تاريخية';

  exception
    when others then
      if position(
        'لا يمكن تعديل بيانات إلغاء رابط هوية تاريخي'
        in sqlerrm
      ) > 0 then
        raise notice
          'PASS 17: revoke metadata التاريخية غير قابلة للتعديل';
      else
        raise notice
          'FAIL 17: سبب رفض تعديل revoke metadata غير متوقع: %',
          sqlerrm;
      end if;
  end;


  -- ============================================================
  -- 18. الرابط الفعال لا يحمل Revocation metadata مسبقة
  -- ============================================================

  begin
    update iam.profile_person_links
    set revoke_reason = 'سبب بلا إلغاء'
    where id = v_link_3;

    raise notice
      'FAIL 18: سُمح بـrevocation metadata على رابط فعال';

  exception
    when check_violation then
      raise notice
        'PASS 18: الرابط الفعال لا يقبل revocation metadata مسبقة';
  end;

end;
$test$;

rollback;
