begin;

-- يثبت أن Default Privileges لا تعيد الكتابة المباشرة إلى جدول جديد.
create table ops.__q79_default_table_probe (
  id integer primary key
);

do $test$
declare
  v_count integer;
  v_bad_definers integer;
begin
  select count(*)
  into v_count
  from information_schema.table_privileges
  where grantee = 'authenticated'
    and privilege_type in (
      'INSERT',
      'UPDATE',
      'DELETE',
      'TRUNCATE',
      'REFERENCES',
      'TRIGGER'
    )
    and table_schema in (
      'core',
      'iam',
      'ops',
      'billing',
      'finance',
      'inventory',
      'audit',
      'sync',
      'reporting'
    );

  if v_count = 0 then
    raise notice 'PASS 1: authenticated لا يملك أي كتابة مباشرة على الجداول الداخلية';
  else
    raise notice 'FAIL 1: بقيت % صلاحية كتابة مباشرة لـauthenticated', v_count;
  end if;


  select count(*)
  into v_count
  from information_schema.table_privileges
  where grantee = 'anon'
    and privilege_type in (
      'INSERT',
      'UPDATE',
      'DELETE',
      'TRUNCATE',
      'REFERENCES',
      'TRIGGER'
    )
    and table_schema in (
      'core',
      'iam',
      'ops',
      'billing',
      'finance',
      'inventory',
      'audit',
      'sync',
      'reporting'
    );

  if v_count = 0 then
    raise notice 'PASS 2: anon لا يملك أي كتابة مباشرة على الجداول الداخلية';
  else
    raise notice 'FAIL 2: بقيت % صلاحية كتابة مباشرة لـanon', v_count;
  end if;


  if not has_table_privilege(
       'authenticated',
       'ops.__q79_default_table_probe',
       'INSERT'
     )
     and not has_table_privilege(
       'authenticated',
       'ops.__q79_default_table_probe',
       'UPDATE'
     )
     and not has_table_privilege(
       'authenticated',
       'ops.__q79_default_table_probe',
       'DELETE'
     )
     and not has_table_privilege(
       'anon',
       'ops.__q79_default_table_probe',
       'INSERT'
     ) then
    raise notice 'PASS 3: الجدول الداخلي الجديد يبدأ بلا Direct DML لأدوار التطبيق';
  else
    raise notice 'FAIL 3: Default Privileges أعادت كتابة مباشرة لجدول جديد';
  end if;


  if
    has_function_privilege(
      'authenticated',
      'ops.start_irrigation_session(uuid,uuid,uuid,uuid,uuid,text,timestamptz,uuid)',
      'EXECUTE'
    )
    and has_function_privilege(
      'authenticated',
      'ops.pause_irrigation_session(uuid,text,timestamptz)',
      'EXECUTE'
    )
    and has_function_privilege(
      'authenticated',
      'ops.change_session_energy_source(uuid,text,timestamptz,bigint,text,uuid)',
      'EXECUTE'
    )
    and has_function_privilege(
      'authenticated',
      'ops.resume_irrigation_session(uuid,timestamptz)',
      'EXECUTE'
    )
    and has_function_privilege(
      'authenticated',
      'ops.complete_irrigation_session(uuid,timestamptz,bigint,text,uuid)',
      'EXECUTE'
    )
    and has_function_privilege(
      'authenticated',
      'billing.issue_session_invoice(uuid,uuid)',
      'EXECUTE'
    )
  then
    raise notice 'PASS 4: إجراءات دورة جلسة السقي الحرجة بقيت قابلة للتنفيذ';
  else
    raise notice 'FAIL 4: فُقد EXECUTE لإجراء حرج من دورة جلسة السقي';
  end if;


  if
    has_function_privilege(
      'authenticated',
      'billing.allocate_payment(uuid,jsonb)',
      'EXECUTE'
    )
    and has_function_privilege(
      'authenticated',
      'billing.record_payment(uuid,uuid,bigint,text,jsonb,uuid,uuid,uuid,timestamptz,text,text)',
      'EXECUTE'
    )
    and has_function_privilege(
      'authenticated',
      'finance.pay_partner_distribution(uuid,bigint,uuid,timestamptz)',
      'EXECUTE'
    )
  then
    raise notice 'PASS 5: إجراءات الدفع والتوزيع الحرجة بقيت قابلة للتنفيذ';
  else
    raise notice 'FAIL 5: فُقد EXECUTE لإجراء مالي حرج';
  end if;


  if
    has_function_privilege(
      'authenticated',
      'ops.create_farmer(uuid,text,text,text,text,bigint)',
      'EXECUTE'
    )
    and has_function_privilege(
      'authenticated',
      'ops.create_farm(uuid,text,uuid)',
      'EXECUTE'
    )
    and has_function_privilege(
      'authenticated',
      'ops.create_booking(uuid,uuid,uuid,timestamptz,timestamptz,uuid,uuid,text,integer,text)',
      'EXECUTE'
    )
    and has_function_privilege(
      'authenticated',
      'ops.reschedule_booking(uuid,timestamptz,timestamptz,text)',
      'EXECUTE'
    )
  then
    raise notice 'PASS 6: إجراءات المزارع والأرض والحجز بقيت قابلة للتنفيذ';
  else
    raise notice 'FAIL 6: فُقد EXECUTE لإجراء تشغيل حرج';
  end if;


  if
    has_function_privilege(
      'authenticated',
      'inventory.purchase_fuel(uuid,numeric,bigint,timestamptz,uuid)',
      'EXECUTE'
    )
    and has_function_privilege(
      'authenticated',
      'inventory.record_fuel_consumption(uuid,bigint,text,text,uuid,uuid,uuid,uuid,timestamptz,uuid,uuid)',
      'EXECUTE'
    )
    and has_function_privilege(
      'authenticated',
      'inventory.record_physical_fuel_count(uuid,uuid,bigint,timestamptz,uuid,text)',
      'EXECUTE'
    )
  then
    raise notice 'PASS 7: إجراءات الوقود الحرجة بقيت قابلة للتنفيذ';
  else
    raise notice 'FAIL 7: فُقد EXECUTE لإجراء وقود حرج';
  end if;


  select count(*)
  into v_bad_definers
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where p.prokind = 'f'
    and n.nspname in (
      'core',
      'iam',
      'ops',
      'billing',
      'finance',
      'inventory',
      'audit',
      'sync',
      'reporting'
    )
    and p.prosecdef
    and has_function_privilege(
      'authenticated',
      p.oid,
      'EXECUTE'
    )
    and not exists (
      select 1
      from unnest(
        coalesce(
          p.proconfig,
          array[]::text[]
        )
      ) setting
      where setting like 'search_path=%'
         or setting like 'search_path =%'
    );

  if v_bad_definers = 0 then
    raise notice 'PASS 8: كل SECURITY DEFINER القابل للتنفيذ يحمل search_path صريحا';
  else
    raise notice 'FAIL 8: توجد % دالة SECURITY DEFINER بلا search_path صريح',
      v_bad_definers;
  end if;


  select count(*)
  into v_count
  from information_schema.table_privileges
  where grantee in ('anon', 'authenticated')
    and table_schema = 'api'
    and privilege_type in (
      'INSERT',
      'UPDATE',
      'DELETE',
      'TRUNCATE',
      'REFERENCES',
      'TRIGGER'
    );

  if v_count = 0 then
    raise notice 'PASS 9: مخطط api لا يحتوي مسار كتابة جدولي مباشر لأدوار التطبيق';
  else
    raise notice 'FAIL 9: يوجد Direct DML على كائن جدولي داخل api';
  end if;
end;
$test$;

rollback;
