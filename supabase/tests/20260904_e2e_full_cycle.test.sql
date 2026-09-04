-- اختبار المسار الكامل — دورة سقي من التسجيل إلى إقفال الفاتورة (ق-120/4)
--
-- ما يفرّقه عن الـ35 اختبارًا الأخرى: تلك تُثبت عقدًا واحدًا معزولًا، وتُجهّز
-- حالتها بإدخال صفوف مباشرة بدور `postgres` — أي تتجاوز RLS في التجهيز.
-- هذا الملف لا يُدخل صفًّا واحدًا بيده إلا في `auth.users` (فالتسجيل يجري في
-- Supabase Auth خارج SQL). كل ما بعد ذلك يمرّ عبر عقود `api` وحدها وبدور
-- `authenticated`، فمخرَج كل عقد هو مدخل التالي. هكذا يُقاس ما لا يقيسه أي
-- اختبار وحدة: أن السلسلة **موصولة**، لا أن كل حلقة سليمة وحدها.
--
-- والتصميم يمسك خطأ كل خطوة ويطبعه بنصّ الخادم بدل أن ينهار الملف عند أول
-- رفض: شرطٌ خفيّ واحد يوقف عشر خطوات، فيصير سبب الوقوف مقروءًا في تشغيل
-- واحد. الإخفاء ممنوع: كل خطوة تُعلن PASS أو FAIL باسمها.

\set ON_ERROR_STOP on

begin;

do $test$
declare
  -- الفاعلون
  v_owner            uuid;
  v_owner_email      text := 'e2e-owner@test.local';

  -- ما تعيده العقود، خطوة بعد خطوة
  v_well             uuid;
  v_schedule         jsonb;
  v_pump_res         jsonb;
  v_pump             uuid;
  v_farmer_res       jsonb;
  v_account          uuid;
  v_farm_res         jsonb;
  v_farm             uuid;
  v_session          uuid;
  v_invoice          uuid;
  v_pay_res          jsonb;
  v_payment          uuid;
  v_receipts         jsonb;
  v_receipt          jsonb;
  v_account_view     jsonb;

  -- أرقام القصة: ساعتان على الشمس بسعر معلوم، فالتكلفة معروفة سلفًا
  v_rate_solar       bigint := 50000;
  v_started          timestamptz := date_trunc('hour', now()) - interval '3 days';
  v_ended            timestamptz := date_trunc('hour', now()) - interval '3 days' + interval '2 hours';
  v_effective_from   timestamptz := date_trunc('hour', now()) - interval '5 days';
  v_expected_charge  bigint := 100000;   -- 2 ساعة × 50000
  v_payment_amount   bigint := 150000;   -- أكبر من الفاتورة: الفرق رصيد مقدَّم
  v_expected_left    bigint := 50000;    -- 150000 − 100000

  v_charge_amount    bigint;
  v_count            integer;
begin

  -- ===============================================================
  -- 0. مالك جديد في auth.users — الحدّ الوحيد الذي لا عقد له في SQL
  -- ===============================================================

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_user_meta_data
  ) values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', v_owner_email,
    crypt('x', gen_salt('bf')), now(), now(), now(),
    jsonb_build_object('full_name', 'مالك المسار الكامل', 'phone', '770000900')
  ) returning id into v_owner;

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';

  -- ===============================================================
  -- 1. جهة وبئر — أول عقد يلمسه مستخدم لا يملك شيئًا بعد
  -- ===============================================================
  begin
    v_well := api.create_tenant_with_well('جهة المسار الكامل', 'بئر المسار الكامل');
    if v_well is not null then
      raise notice 'PASS 1: المالك الجديد أنشأ جهته وبئره بعقد واحد';
    else
      raise notice 'FAIL 1: العقد لم يُعِد معرّف البئر';
    end if;
  exception when others then
    raise notice 'FAIL 1: إنشاء الجهة والبئر رُفض — %', sqlerrm;
  end;

  -- ===============================================================
  -- 2. سعر نافذ قبل البدء — بلا سعر مثبت لا تُحسب تكلفة (شرط 066)
  -- ===============================================================
  begin
    v_schedule := api.create_price_schedule(
      v_well, 'تسعيرة المسار الكامل', v_effective_from, 'تجهيز اختبار',
      v_rate_solar, v_rate_solar * 2, v_rate_solar
    );
    if (v_schedule ->> 'schedule_id') is not null then
      raise notice 'PASS 2: تسعيرة نافذة قبل الجلسة بسعر شمس %', v_rate_solar;
    else
      raise notice 'FAIL 2: العقد لم يُعِد معرّف التسعيرة — %', v_schedule::text;
    end if;
  exception when others then
    raise notice 'FAIL 2: إنشاء التسعيرة رُفض — %', sqlerrm;
  end;

  -- ===============================================================
  -- 3. مضخة البئر
  -- ===============================================================
  begin
    v_pump_res := api.save_well_pump(
      v_well, 'مضخة المسار الكامل', null, 'submersible', '30 HP',
      null, null, 'active', null, null
    );
    v_pump := (v_pump_res ->> 'pump_id')::uuid;
    if v_pump is not null then
      raise notice 'PASS 3: المضخة أُنشئت بعقد الحفظ';
    else
      raise notice 'FAIL 3: العقد لم يُعِد معرّف المضخة — %', v_pump_res::text;
    end if;
  exception when others then
    raise notice 'FAIL 3: حفظ المضخة رُفض — %', sqlerrm;
  end;

  -- ===============================================================
  -- 4. مزارع وحسابه في البئر
  -- ===============================================================
  begin
    v_farmer_res := api.create_farmer(
      v_well, 'مزارع المسار الكامل', '771000900', null, null, null, null
    );
    v_account := (v_farmer_res ->> 'farmer_well_account_id')::uuid;
    if v_account is not null then
      raise notice 'PASS 4: المزارع وحسابه في البئر أُنشئا ذرّيًّا';
    else
      raise notice 'FAIL 4: العقد لم يُعِد معرّف حساب المزارع — %', v_farmer_res::text;
    end if;
  exception when others then
    raise notice 'FAIL 4: إنشاء المزارع رُفض — %', sqlerrm;
  end;

  -- ===============================================================
  -- 5. مزرعة مربوطة بحساب المزارع
  -- ===============================================================
  begin
    v_farm_res := api.create_farm(v_well, 'مزرعة المسار الكامل', v_account, null);
    v_farm := (v_farm_res ->> 'farm_id')::uuid;
    if v_farm is not null then
      raise notice 'PASS 5: المزرعة أُنشئت ومربوطة بحساب المزارع';
    else
      raise notice 'FAIL 5: العقد لم يُعِد معرّف المزرعة — %', v_farm_res::text;
    end if;
  exception when others then
    raise notice 'FAIL 5: إنشاء المزرعة رُفض — %', sqlerrm;
  end;

  -- ===============================================================
  -- 6. بدء جلسة سقي على الشمس
  -- ===============================================================
  begin
    v_session := api.start_irrigation_session(
      v_well, v_pump, v_farm, v_account, 'solar', v_started, null, null
    );
    if v_session is not null then
      raise notice 'PASS 6: الجلسة بدأت والسعر يُثبَّت لحظة البدء';
    else
      raise notice 'FAIL 6: العقد لم يُعِد معرّف الجلسة';
    end if;
  exception when others then
    raise notice 'FAIL 6: بدء الجلسة رُفض — %', sqlerrm;
  end;

  -- ===============================================================
  -- 7. إتمام الجلسة بعد ساعتين — بلا وقود لأن المصدر شمس
  -- ===============================================================
  begin
    perform api.complete_irrigation_session(
      v_session, v_ended, null, null, null, null
    );
    raise notice 'PASS 7: الجلسة أُتمّت بمدة ساعتين';
  exception when others then
    raise notice 'FAIL 7: إتمام الجلسة رُفض — %', sqlerrm;
  end;

  -- ===============================================================
  -- 8. التكلفة تُحسب على الخادم = المدة × السعر ÷ ٣٦٠٠، لا رقم من العميل
  --    وتُقرأ بحقيقة البيانات: غيابها بسياسة ليس خطأً في الحساب.
  -- ===============================================================
  begin
    execute 'reset role';

    select sc.amount_minor into v_charge_amount
    from billing.session_charges sc
    where sc.session_id = v_session;

    if v_charge_amount = v_expected_charge then
      raise notice 'PASS 8: التكلفة % مطابقة للصيغة بلا حساب في العميل', v_charge_amount;
    elsif v_charge_amount is null then
      raise notice 'FAIL 8: لا تكلفة محسوبة للجلسة — الإتمام لم يُنتج سطر تكلفة';
    else
      raise notice 'FAIL 8: التكلفة % والمتوقَّع %', v_charge_amount, v_expected_charge;
    end if;

    perform set_config('request.jwt.claim.sub', v_owner::text, true);
    execute 'set local role authenticated';
  exception when others then
    raise notice 'FAIL 8: قراءة التكلفة تعذّرت — %', sqlerrm;
  end;

  -- ===============================================================
  -- 9. إصدار فاتورة الجلسة
  -- ===============================================================
  begin
    v_invoice := api.issue_session_invoice(v_session);
    if v_invoice is not null then
      raise notice 'PASS 9: فاتورة الجلسة أُصدرت';
    else
      raise notice 'FAIL 9: العقد لم يُعِد معرّف الفاتورة';
    end if;
  exception when others then
    raise notice 'FAIL 9: إصدار الفاتورة رُفض — %', sqlerrm;
  end;

  -- ===============================================================
  -- 10. دفعة عامة أكبر من الفاتورة وبلا تخصيص — هذا هو الرصيد المقدَّم
  -- ===============================================================
  begin
    v_pay_res := api.record_payment(
      v_well, v_account, v_payment_amount, 'cash', '[]'::jsonb,
      null, null, null, now(), 'دفعة مقدَّمة في اختبار المسار', null, null
    );
    raise notice 'PASS 10: دفعة % سُجِّلت بلا تخصيص', v_payment_amount;
  exception when others then
    raise notice 'FAIL 10: تسجيل الدفعة رُفض — %', sqlerrm;
  end;

  -- ===============================================================
  -- 11. السند يُقرأ بالعقد — ومنه يأخذ الإنسانُ معرّفه ورصيده (م-41G)
  -- ===============================================================
  begin
    v_receipts := api.list_advance_receipts(v_account, 50);
    v_receipt := v_receipts -> 'receipts' -> 0;
    v_payment := (v_receipt ->> 'payment_id')::uuid;

    if jsonb_array_length(v_receipts -> 'receipts') = 1
       and (v_receipt ->> 'amount_minor')::bigint = v_payment_amount
       and (v_receipt ->> 'allocated_minor')::bigint = 0
       and (v_receipt ->> 'remaining_minor')::bigint = v_payment_amount
       and (v_receipt ->> 'is_exhausted')::boolean is false
    then
      raise notice 'PASS 11: السند يظهر بمبلغه كاملًا غير مخصَّص';
    else
      raise notice 'FAIL 11: حمولة السند غير متوقَّعة — %', v_receipts::text;
    end if;
  exception when others then
    raise notice 'FAIL 11: قراءة السندات رُفضت — %', sqlerrm;
  end;

  -- ===============================================================
  -- 12. التخصيص: الإنسان يختار السند والفاتورة والمبلغ، والخادم يتحقق
  -- ===============================================================
  begin
    perform api.allocate_payment(
      v_payment,
      jsonb_build_array(
        jsonb_build_object('invoice_id', v_invoice, 'amount_minor', v_expected_charge)
      )
    );
    raise notice 'PASS 12: % من السند خُصِّصت على الفاتورة', v_expected_charge;
  exception when others then
    raise notice 'FAIL 12: التخصيص رُفض — %', sqlerrm;
  end;

  -- ===============================================================
  -- 13. السند بعد التخصيص: المخصَّص والمتبقّي يتغيّران فعلًا
  -- ===============================================================
  begin
    v_receipts := api.list_advance_receipts(v_account, 50);
    v_receipt := v_receipts -> 'receipts' -> 0;

    if (v_receipt ->> 'allocated_minor')::bigint = v_expected_charge
       and (v_receipt ->> 'remaining_minor')::bigint = v_expected_left
       and (v_receipt ->> 'is_exhausted')::boolean is false
    then
      raise notice 'PASS 13: بقي % في السند بعد تسديد الفاتورة', v_expected_left;
    else
      raise notice 'FAIL 13: رصيد السند بعد التخصيص غير متوقَّع — %', v_receipts::text;
    end if;
  exception when others then
    raise notice 'FAIL 13: إعادة قراءة السند رُفضت — %', sqlerrm;
  end;

  -- ===============================================================
  -- 14. أثر التخصيص على الفاتورة نفسها — لا على السند وحده
  --     يُقرأ بحقيقة البيانات لا بعين المالك: لو حجبته سياسةٌ لقرأنا
  --     صفرًا وسمّيناه «لم يُكتب» — وذلك غياب كاذب لا فشل تخصيص.
  -- ===============================================================
  begin
    execute 'reset role';

    select count(*) into v_count
    from billing.payment_allocations pa
    where pa.payment_id = v_payment
      and pa.invoice_id = v_invoice
      and pa.allocated_minor = v_expected_charge;

    if v_count = 1 then
      raise notice 'PASS 14: التخصيص مكتوب على الفاتورة بمبلغه';
    else
      raise notice 'FAIL 14: صفوف التخصيص % والمتوقَّع 1', v_count;
    end if;

    perform set_config('request.jwt.claim.sub', v_owner::text, true);
    execute 'set local role authenticated';
  exception when others then
    raise notice 'FAIL 14: قراءة التخصيص تعذّرت — %', sqlerrm;
  end;

  -- ===============================================================
  -- 15. حساب المزارع يُقرأ بالعقد بعد كل ما سبق
  -- ===============================================================
  begin
    v_account_view := api.get_farmer_account(v_account, 50);
    if v_account_view is not null and v_account_view ? 'contract' then
      raise notice 'PASS 15: حساب المزارع يُقرأ بعقده — %', v_account_view ->> 'contract';
    else
      raise notice 'FAIL 15: مغلَّف حساب المزارع غير متوقَّع — %', v_account_view::text;
    end if;
  exception when others then
    raise notice 'FAIL 15: قراءة حساب المزارع رُفضت — %', sqlerrm;
  end;

  -- ===============================================================
  -- 16. السلسلة كلها محجوبة عن غير المصدَّق — رفض صريح لا قائمة فارغة
  -- ===============================================================
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role anon';

  begin
    perform api.list_advance_receipts(v_account, 50);
    raise notice 'FAIL 16: غير المصدَّق قرأ السندات';
  exception when insufficient_privilege then
    raise notice 'PASS 16: غير المصدَّق مرفوض على مسار السندات';
  when others then
    raise notice 'PASS 16: غير المصدَّق مرفوض — %', sqlerrm;
  end;

  execute 'reset role';
end;
$test$;

rollback;
