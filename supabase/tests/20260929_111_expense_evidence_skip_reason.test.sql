-- ق-131 البند 13 / م-45 المرحلة A: إثباتات المصروفات — مرفق صريح
-- أو سبب تخطٍ صريح. هذا اختبار DB فقط؛ كل التغييرات تتراجع في النهاية.
--
-- ما يثبه هذا الملف (مطابق لأبنود عقد الهجرة 111):
--   1.  توقيع api.record_expense الحي = التوقيع العشري الجديد، ولا
--       توقيع قديم غامض باقٍ.
--   2-6. مسار المرفق ومسار التخطي يكتبان الحقول الحاكمية الصحيحة
--       (attachment_url / attachment_skipped / attachment_skip_reason)
--       والتطبيع يفرّغ السلاسل البيضاء إلى NULL.
--   7-11. كل حالة إثبات متناقضة تُرفض: تخطٍ بلا سبب، سبب أبيض، مرفق
--       مع تخطٍ، مرفق مع سبب، ولا شيء من الاثنين.
--   12. `note` ملاحظة عمل مستقلة — السبب لا يُطوى فيها.
--   13. التحقق الشريكي partner_paid سليم.
--   14. مسار صندوق المشغل (م109) باقٍ لمصروف cashbox بمشغل نشط.
--   15-16. الفئات من كتالوج الخادم الحي (diesel/salaries...) لا الأكواد
--       الملفقة، والموقوفة مستبعدة.
--   17-18. البئر غير المصرح به وanon مرفوضان.
--   19-20. الدلو خاص وسياساته موسوَّرة بسلطة الصلاحيات لا بمصادقة
--       شاملة، سلوكيًا وبيئويًا.
--   21. حماية Direct DML على جدول المصروفات باقية.
--
-- لا تضعيف لاختبارات 081/092/095/109/110؛ تعديل 074 الوحيد تطوّر
-- عقد التوقيع المشروع (وسيط السبب) لا إضعافًا.

\set ON_ERROR_STOP on

begin;

set local timezone to 'UTC';

do $test$
declare
  v_owner uuid;
  v_op1 uuid;
  v_outsider uuid;
  v_tenant uuid;
  v_well1 uuid;
  v_well2 uuid;
  v_tenant2 uuid;
  v_custody1 uuid;
  v_expense_id uuid;
  v_cat_row record;
  v_err text;
  v_cats jsonb;
  v_count bigint;
  v_ok boolean;
  v_bucket_private boolean;
begin
  -- -------------------------------------------------------------
  -- التجهيز: جهة وبئر بمالك ومشغل، وبئر آخر بجهة أخرى للحرمان.
  -- -------------------------------------------------------------
  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q131-evidence-owner@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_owner;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q131-evidence-op@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_op1;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q131-evidence-outsider@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_outsider;

  insert into core.tenants (name)
  values ('جهة اختبار الإثباتات 111')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'بئر الإثباتات 111')
  returning id into v_well1;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_well1, v_owner, 'owner', 'active'),
         (v_well1, v_op1, 'operator', 'active');

  -- جهة وبئر آخران لا علاقة لأحد من أعلاه بهما.
  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q131-evidence-other@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_outsider; -- يُعاد استعماله كمالك البئر الثاني

  insert into core.tenants (name)
  values ('جهة اختبار الإثباتات 111 - أخرى')
  returning id into v_tenant2;

  insert into core.wells (tenant_id, name)
  values (v_tenant2, 'بئر الإثباتات 111 - الآخر')
  returning id into v_well2;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_well2, v_outsider, 'owner', 'active');

  -- فئة موقوفة لتثبيت استبعاد الموقوف من العقد.
  insert into finance.expense_categories
    (tenant_id, code, name_ar, is_active)
  values (v_tenant, 'legacy_arch', 'أرشيف موقوف', false);

  -- خصوصية الدلو تُلتقط بسلطة الإعداد (RLS على buckets تمنع المصادَق).
  v_bucket_private := (select public from storage.buckets where id = 'expense-evidence') = false;

  v_custody1 := finance.ensure_operator_custody_cashbox(v_well1, v_op1);

  -- -------------------------------------------------------------
  -- 1. التوقيع الحي: عشري جديد للـAPI والداخلي، ولا توقيع قديم غامض
  --    باقٍ (درس overload م-056 لا يعود).
  -- -------------------------------------------------------------
  if to_regprocedure(
       'api.record_expense(uuid,text,bigint,text,text,boolean,text,text,uuid,text)'
     ) is not null
     and to_regprocedure(
       'api.record_expense(uuid,text,bigint,text,text,boolean,text,text,uuid)'
     ) is null
     and to_regprocedure(
       'finance.record_expense(uuid,text,bigint,text,uuid,text,boolean,text,text,uuid,text)'
     ) is not null
     and to_regprocedure(
       'finance.record_expense(uuid,text,bigint,text,uuid,text,boolean,text,text,uuid)'
     ) is null
  then
    raise notice 'PASS 1: توقيع record_expense الحي وحده صالح بوسيط السبب (API والداخلي)';
  else
    raise notice 'FAIL 1: توقيع record_expense غير مقصوص (قديم أو غامض)';
  end if;

  -- -------------------------------------------------------------
  -- 2-4. مسار المرفق: url + skipped=false ينجح، المرجع المستقر يُكتب،
  --      والسبب NULL.
  -- -------------------------------------------------------------
  v_expense_id := finance.record_expense(
    v_well1, 'diesel', 1000, 'تعبئة برميل',
    v_owner,
    'storage://expense-evidence/' || v_well1::text || '/' || v_owner::text || '/r1.pdf',
    false,
    'cashbox',
    null,
    null,
    null
  );

  if v_expense_id is not null then
    raise notice 'PASS 2: مرفق مع skipped=false يُقبل';
  else
    raise notice 'FAIL 2: مرفق مع skipped=false رُفض ظلمًا';
  end if;

  select e.attachment_url, e.attachment_skip_reason
  into v_cat_row
  from finance.expenses e where e.id = v_expense_id;

  if v_cat_row.attachment_url = 'storage://expense-evidence/'
       || v_well1::text || '/' || v_owner::text || '/r1.pdf' then
    raise notice 'PASS 3: المرجع المستقر storage:// كُتب في attachment_url';
  else
    raise notice 'FAIL 3: مرجع المرفق المخزَّن ليس المرجع المستقر المرسل';
  end if;

  if v_cat_row.attachment_skip_reason is null then
    raise notice 'PASS 4: سبب التخطي NULL مع مرفق مُقدَّم';
  else
    raise notice 'FAIL 4: سبب التخطي لم يكن NULL مع مرفق';
  end if;

  -- -------------------------------------------------------------
  -- 5-6. مسار التخطي: skipped=true بسبب صريح ينجح ويُخزَّن حاكميًا،
  --      والبياض يُطبَّع إلى NULL.
  -- -------------------------------------------------------------
  v_expense_id := finance.record_expense(
    v_well1, 'maintenance', 500, 'إصلاح لوحة',
    v_owner,
    null,
    true,
    'cashbox',
    null,
    null,
    '  المحل لا يصدر فواتير ورقية  '
  );

  select e.attachment_url, e.attachment_skipped,
         e.attachment_skip_reason, e.note
  into v_cat_row
  from finance.expenses e where e.id = v_expense_id;

  if v_cat_row.attachment_skipped
     and v_cat_row.attachment_skip_reason = 'المحل لا يصدر فواتير ورقية' then
    raise notice 'PASS 5: التخطي بسبب صريح يُقبل';
  else
    raise notice 'FAIL 5: التخطي بسبب صريح لم يُقبل كما يجب';
  end if;

  if v_cat_row.attachment_url is null
     and btrim(v_cat_row.attachment_skip_reason) <> '' then
    raise notice 'PASS 6: السبب مخزَّن في attachment_skip_reason الحاكم مُطبَّعًا';
  else
    raise notice 'FAIL 6: السبب لم يُخزَّن في العمود الحاكم مُطبَّعًا';
  end if;

  -- -------------------------------------------------------------
  -- 7. تخطٍ بلا سبب مرفوض.
  -- -------------------------------------------------------------
  v_err := null;
  begin
    perform finance.record_expense(
      v_well1, 'other', 100, 'بلا سبب',
      v_owner, null, true, 'other', null, null, null
    );
  exception when others then
    v_err := sqlerrm;
  end;

  if v_err like '%سبب التخطي إلزامي%' then
    raise notice 'PASS 7: تخطٍ بلا سبب رُفض صراحة';
  else
    raise notice 'FAIL 7: تخطٍ بلا سبب لم يُرفض: %', coalesce(v_err, 'قُبل!');
  end if;

  -- -------------------------------------------------------------
  -- 8. تخطٍ بسبب أبيض/فراغات مرفوض.
  -- -------------------------------------------------------------
  v_err := null;
  begin
    perform finance.record_expense(
      v_well1, 'other', 100, 'سبب أبيض',
      v_owner, null, true, 'other', null, null, '   '
    );
  exception when others then
    v_err := sqlerrm;
  end;

  if v_err like '%سبب التخطي إلزامي%' then
    raise notice 'PASS 8: سبب التخطي الأبيض رُفض (الفراغ ليس سببًا)';
  else
    raise notice 'FAIL 8: سبب أبيض تسلل كسبب صالح: %', coalesce(v_err, 'قُبل!');
  end if;

  -- -------------------------------------------------------------
  -- 9. مرفق مع تخطٍ مرفوض.
  -- -------------------------------------------------------------
  v_err := null;
  begin
    perform finance.record_expense(
      v_well1, 'other', 100, 'مرفق مع تخطٍ',
      v_owner, 'storage://expense-evidence/x/y/z.pdf', true, 'other',
      null, null, 'سبب'
    );
  exception when others then
    v_err := sqlerrm;
  end;

  if v_err like '%إرفاق السند مع تخطي المرفق%' then
    raise notice 'PASS 9: مرفق مع تخطٍ رُفض';
  else
    raise notice 'FAIL 9: مرفق مع تخطٍ لم يُرفض: %', coalesce(v_err, 'قُبل!');
  end if;

  -- -------------------------------------------------------------
  -- 10. مرفق مع سبب تخطٍ مرفوض.
  -- -------------------------------------------------------------
  v_err := null;
  begin
    perform finance.record_expense(
      v_well1, 'other', 100, 'مرفق مع سبب',
      v_owner, 'storage://expense-evidence/x/y/z.pdf', false, 'other',
      null, null, 'سبب زائد'
    );
  exception when others then
    v_err := sqlerrm;
  end;

  if v_err like '%إرفاق السند مع تدوين سبب تخطٍ%' then
    raise notice 'PASS 10: مرفق مع سبب تخطٍ رُفض';
  else
    raise notice 'FAIL 10: مرفق مع سبب لم يُرفض: %', coalesce(v_err, 'قُبل!');
  end if;

  -- -------------------------------------------------------------
  -- 11. لا مرفق ولا تخطٍ مرفوض — العقد الأصرع باقٍ.
  -- -------------------------------------------------------------
  v_err := null;
  begin
    perform finance.record_expense(
      v_well1, 'other', 100, 'بلا إثبات',
      v_owner, null, false, 'other', null, null, null
    );
  exception when others then
    v_err := sqlerrm;
  end;

  if v_err like '%إرفاق صورة السند/الفاتورة أو التخطي الصريح%' then
    raise notice 'PASS 11: لا مرفق ولا تخطٍ رُفض — invariant الإثبات باقٍ';
  else
    raise notice 'FAIL 11: مصروف بلا إثبات تسلل: %', coalesce(v_err, 'قُبل!');
  end if;

  -- -------------------------------------------------------------
  -- 12. note مستقلة: السبب في عموده لا مطويًا في الملاحظة.
  -- -------------------------------------------------------------
  if v_cat_row.note is null then
    raise notice 'PASS 12: note بقيت مستقلة ولم يُطوَ السبب فيها';
  else
    raise notice 'FAIL 12: الملاحظة حوت سبب التخطي أو شيئًا من جهة الإثبات';
  end if;

  -- -------------------------------------------------------------
  -- 13. تحقق partner_paid باقٍ.
  -- -------------------------------------------------------------
  v_err := null;
  begin
    perform finance.record_expense(
      v_well1, 'other', 200, 'شريك بلا هوية',
      v_owner, null, true, 'partner_paid', null, null, 'دفعها الشريك كاش'
    );
  exception when others then
    v_err := sqlerrm;
  end;

  if v_err like '%يلزم تحديد الشريك%' then
    raise notice 'PASS 13: partner_paid بلا شريك ما زال مرفوضًا';
  else
    raise notice 'FAIL 13: تحقق الشريك تآكل: %', coalesce(v_err, 'قُبل!');
  end if;

  -- -------------------------------------------------------------
  -- 14. مصروف cashbox بمشغل نشط يُوجَّه إلى حيازته (م109).
  -- -------------------------------------------------------------
  v_expense_id := finance.record_expense(
    v_well1, 'salaries', 300, 'أجور من حيازة المشغل',
    v_op1,
    null,
    true,
    'cashbox',
    null,
    null,
    'أجور نقدية بلا فاتورة'
  );

  if exists (
    select 1 from finance.expenses e
    where e.id = v_expense_id and e.cashbox_id = v_custody1
  ) then
    raise notice 'PASS 14: مصروف cashbox للمشغل ما زال يخفض حيازته (م109)';
  else
    raise notice 'FAIL 14: مسار حيازة المشغل في المصروف تغير';
  end if;

  -- -------------------------------------------------------------
  -- 15-16. الفئات من كتالوج الخادم: الأكواد الحية، والموقوف مستبعد.
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';

  v_cats := api.list_expense_categories(v_well1);

  select count(*) into v_count
  from jsonb_array_elements(v_cats -> 'categories') x
  where x ->> 'code' in ('diesel', 'salaries');

  if v_count = 2 then
    select count(*) into v_count
    from jsonb_array_elements(v_cats -> 'categories') x
    where x ->> 'code' in ('fuel', 'electricity', 'payroll', 'legacy_arch');
  end if;

  if v_count = 0
     and (v_cats -> 'categories' -> 0) ? 'attachment_required'
     and (v_cats -> 'categories' -> 0) ? 'requires_approval' then
    raise notice 'PASS 15: عقد الفئات يعيد أكواد الخادم الحية بحقولها كاملة';
  else
    raise notice 'FAIL 15: عقد الفئات لم يعد كتالوج الخادم كما يجب';
  end if;

  -- -------------------------------------------------------------
  -- 17. بئر بلا صلاحية: مرفوض.
  -- -------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_op1::text, true);

  v_err := null;
  begin
    perform api.list_expense_categories(v_well2);
  exception when others then
    v_err := sqlerrm;
  end;

  if v_err like '%صلاحية المصروفات%' then
    raise notice 'PASS 17: قراءة فئات بئر بلا صلاحية رُفضت';
  else
    raise notice 'FAIL 17: قراءة فئات بئر أجنبي لم تُحجب: %', coalesce(v_err, 'قُبلت!');
  end if;

  -- -------------------------------------------------------------
  -- 18. anon محجوب عن العقدَين الجديدين/المتغيرين.
  -- -------------------------------------------------------------
  v_ok := true;
  execute 'set local role anon';
  begin
    perform api.list_expense_categories(v_well1);
    v_ok := false;
  exception
    when insufficient_privilege then
      v_ok := true;
    when others then
      v_ok := v_ok and sqlerrm like '%تسجيل الدخول%';
  end;
  begin
    perform api.record_expense(
      v_well1, 'other', 1, 'x', null, true, 'other', null, null, 'سبب'
    );
    v_ok := v_ok and false;
  exception
    when insufficient_privilege then
      v_ok := v_ok and true;
    when others then
      v_ok := v_ok and sqlerrm like '%تسجيل الدخول%';
  end;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', v_op1::text, true);

  if v_ok then
    raise notice 'PASS 18: anon محجوب عن record_expense وlist_expense_categories';
  else
    raise notice 'FAIL 18: أحد العقدَين متاح لـanon';
  end if;

  -- -------------------------------------------------------------
  -- 19. الدلو خاص.
  -- -------------------------------------------------------------
  if v_bucket_private then
    raise notice 'PASS 19: دلو الإثباتات خاص (public=false)';
  else
    raise notice 'FAIL 19: دلو الإثباتات عام — كشف إثباتات مالية';
  end if;

  -- -------------------------------------------------------------
  -- 20. السياسات موسوَّرة سلوكيًا: رفع المشغل لمجلده ينجح، ومجلد
  --     غيره أو بئر أجنبي يُرفض، والقراءة للمرخَّص، والحذف مرفوض.
  -- -------------------------------------------------------------
  insert into storage.objects (bucket_id, name, metadata)
  values (
    'expense-evidence',
    v_well1::text || '/' || v_op1::text || '/receipt-1.pdf',
    '{"size": 10}'::jsonb
  );

  v_err := null;
  begin
    insert into storage.objects (bucket_id, name, metadata)
    values (
      'expense-evidence',
      v_well1::text || '/' || v_owner::text || '/hijack.pdf',
      '{"size": 10}'::jsonb
    );
  exception
    when insufficient_privilege then
      v_err := 'RLS';
    when others then
      v_err := sqlerrm;
  end;

  v_ok := v_err is not null;

  perform set_config('request.jwt.claim.sub', v_outsider::text, true);
  begin
    insert into storage.objects (bucket_id, name, metadata)
    values (
      'expense-evidence',
      v_well1::text || '/' || v_outsider::text || '/stranger.pdf',
      '{"size": 10}'::jsonb
    );
    v_ok := false;
  exception
    when insufficient_privilege then
      v_ok := v_ok and true;
    when others then
      v_ok := v_ok and sqlerrm like '%row-level security%';
  end;

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  select count(*) into v_count
  from storage.objects
  where bucket_id = 'expense-evidence'
    and name = v_well1::text || '/' || v_op1::text || '/receipt-1.pdf';

  v_ok := v_ok and v_count = 1;

  perform set_config('request.jwt.claim.sub', v_op1::text, true);
  v_err := null;
  begin
    delete from storage.objects
    where bucket_id = 'expense-evidence'
      and name = v_well1::text || '/' || v_op1::text || '/receipt-1.pdf';
  exception when others then
    v_err := sqlerrm;
  end;

  select count(*) into v_count
  from storage.objects
  where bucket_id = 'expense-evidence'
    and name = v_well1::text || '/' || v_op1::text || '/receipt-1.pdf';

  if v_ok and v_count = 1 then
    raise notice 'PASS 20: سياسات الدلو موسوَّرة: رفع للمجلد المصرح فقط، وقراءة للمرخَّص، ولا حذف';
  else
    raise notice 'FAIL 20: سلوك سياسات الدلو ليس موسوَّرًا كما يجب';
  end if;

  -- -------------------------------------------------------------
  -- 21. حماية Direct DML على جدول المصروفات باقية (ق-79).
  -- -------------------------------------------------------------
  v_ok := false;
  begin
    insert into finance.expenses (
      tenant_id, well_id, category_id, amount_minor, description,
      attachment_url, attachment_skipped
    )
    select v_tenant, v_well1, c.id, 1, 'تجاوز مباشر',
           null, true
    from finance.expense_categories c
    where c.tenant_id = v_tenant and c.code = 'other';
  exception when insufficient_privilege then
    v_ok := true;
  end;

  if v_ok then
    raise notice 'PASS 21: الإدخال المباشر في finance.expenses محجوب كما هو';
  else
    raise notice 'FAIL 21: المصادَق كتب مباشرة في جدول المصروفات — كسر ق-79';
  end if;
end;
$test$;

rollback;
