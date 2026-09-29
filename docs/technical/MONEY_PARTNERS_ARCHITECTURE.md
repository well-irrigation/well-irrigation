# Money & Partners Architecture

**آخر تحديث:** 2026-08-18
**القرار الحاكم:** ق-99
**UX:** UX-14 / 408–459
**الحالة:** تصميم تقني ملزم؛ التنفيذ الكامل Pending
**المسألة المفتوحة:** م-29
**أول DB Migration جديدة:** 085 أو أحدث

## 1. الهدف

تحديد الحقيقة المالية التي تستخدمها Flutter في:

- Farmer accounts.
- invoices.
- payments.
- advances.
- expenses.
- partners.
- ownership/profit shares.
- profit distributions.
- accounting periods.
- corrections.
- audit views.

دون إنشاء Accounting Engine داخل Flutter.

## 2. قاعدة السلطة

الواجهة تعرض المال.

Backend يحسم المال.

Flutter لا يقرر بنفسه:

- Posting.
- Invoice balance.
- Allocation finality.
- Distribution approval.
- Partner payable.
- Accounting-period state.
- Final correction result.

## 3. الأساس الموجود — الدفعات

الموجود حاليًا:

- `billing.record_payment`.
- `billing.allocate_payment`.
- `api.record_payment`.
- `api.allocate_payment`.
- Payment allocations.
- Advance payments.
- posted journal entries.
- receipt summary.
- audit logging.

هذا الأساس يعاد استخدامه.

لا ينشأ Payment subsystem جديد.

## 4. Farmer financial account Read Model

Flutter يحتاج Typed Read Contract يعيد حسب الصلاحية:

- farmer identity.
- Farmer Well Account.
- total unpaid invoices.
- advance balance.
- invoice list.
- payment history.
- pending/reconciliation indicators.
- recent allocations.

يجب أن يعرض:

    debt
    advance

كمقدارين منفصلين.

لا يعيد فقط:

    debt - advance

بوصفه الحقيقة الوحيدة.

## 5. Invoice Read Model

لكل Invoice:

- public code.
- date.
- source/session.
- total.
- paid.
- outstanding.
- status.
- payment allocations.
- correction indicators عند وجودها.

لا تعتمد Flutter على Join مباشر بين الجداول الداخلية.

## 6. Payment allocation UX

في التحصيل العام:

التطبيق يستطيع اقتراح:

    oldest outstanding invoice first

الاقتراح يجب أن يكون:

- deterministic.
- visible.
- editable before submit.

Backend يتحقق دائمًا من:

- same well.
- same farmer account.
- valid invoice status.
- available payment.
- invoice outstanding.

## 7. Session-linked payment

عند الدخول من Session/Invoice محددة:

تستخدم كDefault Target وفق ق-92.

هذه القاعدة لا تعني استهلاك Existing Old Advance.

## 8. Existing Advance

الرصيد المقدم القديم يبقى Liability للمزارع حتى
تسجيل Allocation فعلية.

الاستخدام:

    choose advance
        ↓
    choose invoice(s)
        ↓
    confirm
        ↓
    allocate_payment
        ↓
    journal/audit
        ↓
    updated balances

لا Silent Advance Consumption.

## 9. Overpayment

إذا تجاوز التحصيل المبلغ المخصص:

المتبقي يتحول إلى Advance وفق العقد الحالي.

الواجهة تعرض هذا قبل Confirmation.

## 10. Receipt authority

Local device يستطيع إنشاء Local Reference للـCommand.

لكن Receipt Canonical النهائي لا يعرض بوصفه نهائيًا
إلا بعد Server ACK.

العقد النهائي يجب أن يعيد:

- payment id.
- public code.
- paid time.
- amount.
- method.
- allocation summary.
- advance created.
- canonical status.

## 11. Offline payment

وفق ق-89 وق-92:

    local durable command
        ↓
    pending
        ↓
    outbox
        ↓
    server idempotent command
        ↓
    ACK / conflict
        ↓
    canonical receipt

وجود Payment Pending يجب أن يظهر في الحساب لتقليل
خطر التحصيل المكرر.

## 12. Payment idempotency dependency

`api.record_payment` الحالي لا يمثل بعد عقد Offline
Command ID الكامل المطلوب.

إغلاق هذه النقطة يعتمد أيضًا على م-27.

م-29 لا تنشئ سياسة منافسة؛ بل تربط UX-14 بعقد
التسوية النهائي.

## 13. الأساس الموجود — المصروفات

الموجود:

- expense categories.
- expenses.
- approval rules.
- approval decisions.
- payment source.
- partner-paid expenses.
- attachments.
- `api.record_expense`.
- `api.decide_expense`.

## 14. Expense attachment gap

جدول `finance.expenses` يحتوي:

    attachment_skip_reason

لكن عقد `api.record_expense` الحالي يمرر:

- attachment URL.
- attachment skipped boolean.

ولا يمرر سبب التخطي صراحة.

UX-14 يفرض:

إذا كان التخطي مسموحًا ومطلوبًا تفسيره، يحفظ السبب.

الحل في Migration 085+ بعد فحص التوقيع النهائي:

- إضافة السبب إلى Business Procedure.
- إضافته إلى `api.*`.
- Audit it.
- permanent test.

## 15. Expense status

لا تخلط الواجهة:

    local saved
    pending approval
    approved
    posted
    rejected
    reversed

مع Sync State.

قد يكون:

    business status = pending approval
    sync status = synced

وهما حالتان مستقلتان.

## 16. Partner-paid expense

إذا:

    payment_source = partner_paid

يجب وجود Partner Canonical.

لا يخصم من Cashbox البئر كما لو كان دفعًا نقديًا من
الصندوق.

المبلغ يصبح جزءًا من مستحقات الشريك وفق محرك التوزيع.

## 17. Partner identity

`core.well_partners` هو المصدر الحالي للشريك.

لا تستخدم Login Profile وحدها كهوية الشريك المالية.

Profile رابط دخول عند وجوده.

Partner ID هو المرجع المالي للشراكة.

## 18. Ownership vs Profit

لا تخلط:

- ownership_percentage.
- profit_percentage.

`ownership_share_versions` تحفظ التاريخ.

أي شاشة تعديل مستقبلية يجب أن تنشئ Effective Version
صحيحة بدل تعديل تاريخ قديم.

## 19. Historical shares

دورة توزيع تستخدم Snapshot.

بعد اعتماد دورة:

تغيير النسبة المستقبلية لا يغير:

- gross share.
- profit percentage snapshot.
- net payable.
- previous accounting history.

## 20. Partner irrigation policy

السياسة الحالية:

- normal_customer.
- deduct_from_profit.

الواجهة تعرض معنى بشريًا.

Backend يحسم الاستقطاع.

لا تحسب Flutter الدين المستقطع بنفسها.

## 21. Profit distribution foundation

الموجود حاليًا:

- distribution settings.
- maintenance reserve rules.
- profit distribution cycles.
- profit distribution lines.
- calculate procedure.
- approve procedure.
- partner distribution payment.
- journal posting.
- notifications.

هذا يعاد استخدامه.

## 22. Distribution preview

قبل Approval تعرض Flutter Read Model يحتوي:

- period.
- eligible collections.
- eligible expenses.
- reserved liabilities.
- maintenance reserve.
- distributable amount.

ولكل Partner:

- profit percentage snapshot.
- gross share.
- receivables.
- irrigation deductions.
- other deductions.
- net payable.

## 23. Calculation vs Approval

الحالتان منفصلتان:

    calculated
        ↓
    review
        ↓
    approved

لا تجعل UI كلمة «احتساب» مساوية لـ«اعتماد».

## 24. Approved lock

بعد Approval:

لا Direct Editing للمبالغ المحتسبة.

أي خطأ لاحق يذهب إلى Correction/Audit path.

## 25. Partner payments

العقد الحالي يدعم:

- partial payment.
- full payment.
- paid total.
- remaining amount.
- cycle status.

يجب توفير Read Contract يعرض هذه الحقيقة دون Join
مباشر من Flutter.

## 26. Duplicate settlement prevention

المحرك الحالي يستخدم علامات مثل:

- `settled_in_cycle_id`.
- `deducted_in_cycle_id`.

لمنع إعادة احتساب:

- Partner-paid expense.
- irrigation deduction.

أي إعادة كتابة في 085+ يجب الحفاظ على هذا invariant.

## 27. Partner visibility

Partner-only Read Model لا يجب أن يعيد تفاصيل مالية
شخصية لشريك آخر لمجرد أن Internal RLS يسمح بقراءة
سجل أوسع.

المطلوب:

- share structure المسموح.
- own distribution line.
- own payments.
- own deductions.
- own receivables.

Owner يحصل على العرض الكامل.

## 28. Maintenance reserve rounding review

التنفيذ الحالي يستخدم `round()` عندما تكون قاعدة
الاحتياطي نسبة من Collections أو Profit.

قبل Production يجب إجراء Audit مقابل السياسة المالية
الحاكمة للدقة والتقريب.

القاعدة:

Flutter لا تصحح هذا محليًا.

إذا كان التنفيذ يحتاج تعديلًا:

- Migration 085+.
- permanent regression test.
- توثيق واضح لسياسة التقريب/الباقي.

## 29. Accounting periods

الموجود:

- monthly/yearly periods.
- close.
- reopen request.
- partner approvals.
- platform-admin final decision.
- posting guard for closed periods.

UI يعرض الحالة ولا ينشئ State Machine موازية.

## 30. Reopen

إعادة الفتح ليست Direct Toggle.

تسلسلها الحاكم يبقى:

    closed
      ↓
    reopen request + reason
      ↓
    required partner approvals
      ↓
    platform administration decision
      ↓
    reopened OR rejected

## 31. Financial correction model

Posted Financial Record لا يعدل مباشرة.

نحتاج Typed Contract حسب نوع العملية لـ:

- reversal.
- adjustment.
- correction.
- correction reason.
- original reference.
- actor.
- timestamp.
- resulting financial effect.

لا يجب أن تستخدم Flutter Direct UPDATE.

## 32. Unknown delivery state

إذا فقد الاتصال بعد إرسال أمر مالي:

لا تفترض:

    failed

ولا تفترض:

    success

الحالة:

    unknown / reconciling

ثم:

- query canonical state.
- resolve by Command ID أو canonical reference.
- only then retry/reverse.

## 33. Audit Trail

Owner-facing Audit Read Model يعرض:

- action.
- entity/public code.
- actor.
- time.
- reason.
- original record.
- resulting state.

لا يحتاج المستخدم رؤية Journal Line IDs إلا في
Diagnostic/Admin contexts.

## 34. Money display

UX يعرض:

- YER.
- English digits.
- integer riyal values.

Backend precision policy تبقى المصدر الحاكم.

Flutter لا تنفذ rounding مالي مستقل.

## 35. Required API work

Migration 085+ أو أحدث قد تحتاج:

1. farmer financial summary.
2. invoice list/detail.
3. payment list/detail.
4. advance balance/history.
5. suggested outstanding invoice ordering إذا قرر
   تنفيذه خادميًا.
6. explicit advance allocation support.
7. payment idempotent command wrapper.
8. expense list/detail.
9. expense skip reason input.
10. partner financial list/detail.
11. distribution list/detail/preview.
12. accounting-period read contracts.
13. correction/reversal contracts.
14. financial audit read model.

## 36. Permissions

Backend يعيد التحقق.

### Owner

Financial administration كاملة وفق الدور.

### Operator

الحد الأدنى اللازم لـ:

- collection.
- expense recording.
- status/result needed for own field work.

### Partner

بيانات الشراكة والمال الخاص به فقط، إضافة إلى الشفافية
المعتمدة للنسب.

إخفاء الزر في Flutter ليس Authorization.

## 37. Required tests

### Farmer account

- debt and advance shown separately.
- no silent netting.
- explicit old advance allocation only.
- allocation cannot exceed payment.
- allocation cannot exceed invoice outstanding.
- invoice and payment belong to same farmer/well.

### Payment

- overpayment creates correct advance.
- receipt matches canonical payment.
- lost response retry does not duplicate payment.
- Pending Offline survives process death.
- second device does not hide Pending/reconciled truth.

### Expense

- attachment skip requires preserved reason.
- approval state correct.
- rejected expense not treated posted.
- partner-paid expense does not reduce cashbox incorrectly.
- partner-paid amount settled only once.

### Shares

- ownership and profit percentages independent.
- historical effective versions preserved.
- active profit total invariant enforced.
- old distribution snapshot unchanged after future share change.

### Distribution

- calculation separate from approval.
- approved numbers locked.
- line totals consistent.
- partner receivable not duplicated.
- irrigation deduction not duplicated.
- maintenance reserve rounding follows adopted policy.
- partial payment updates remaining.
- full payment closes line/cycle as appropriate.

### Periods

- closed period blocks posting.
- reopen requires correct workflow.
- unauthorized approval rejected.

### Corrections

- posted record cannot ordinary-edit.
- correction references original.
- audit records actor and reason.
- unknown delivery state reconciles before reversal.

### Security

- no Direct DML.
- Partner cannot read another partner's private financial
  details through public API.
- Operator cannot access profit-distribution administration.

## 38. Definition of Done

UX-14 لا تعتبر Production Complete حتى:

- م-29 مغلقة.
- م-27 dependencies المالية مغلقة حيث تنطبق.
- typed financial reads موجودة.
- payments retry-safe.
- explicit advance behavior مثبت.
- expenses audit/skip reason مثبت.
- partner privacy مثبتة.
- distribution review/approval flow مثبت.
- rounding policy مثبتة.
- corrections/reversals مثبتة.
- periods protections مثبتة.
- Backend permanent tests ناجحة.
- Android Offline tests ناجحة.

## ق-106 — Platform Admin Financial Control Boundary

Platform Admin لديه Global Financial Visibility لأغراض:

- monitoring.
- support.
- reconciliation.
- correction.

لكن ق-106 لا تنشئ Direct Edit bypass.

تظل القواعد:

- posted payment immutable.
- posted expense immutable.
- approved distribution immutable.
- correction via reversal/adjustment/correction.
- audit mandatory.

إعادة فتح Accounting Period:

تظل وفق المسار الحاكم الحالي:

- reason.
- required partner approvals.
- Platform Admin final decision.

لا يوجد Force Reopen bypass في V1.

Platform Commerce Sale Amount لا تدمج مع Well Finance
Totals.

## ق-131 — الحيازة والمقدم وديزل المزارع والمصروفات والمدينون (معتمد توثيقيًا — 2026-09-28)

**الحالة:** Adopted + Documented / **Partial Implementation** عبر
م-45 (المرحلتان A وD) مع الإحالة الإلزامية إلى م-29. ضمن هذا النطاق
المالي تحديدًا: **البند 10 (التأكيد الصريح قبل تطبيق الرصيد المقدم)
منفذ ومدمج ومتحقق محليًا وفي CI**؛ **البند 11 (تحذير حالة المزارع
المالي/الوقودي غير المانع) منفذ ومدمج ومتحقق CI**؛ **البند 12 (تقدير
ديزل المزارع ثم تأكيده/تصحيحه صراحةً) مؤجَّل مؤقتًا بقرار المالك
2026-09-29 — ليس ملغى وعقده الحاكم لم يتغير**؛ **البند 18 (حيازة
المشغل النقدية والترحيل) هو NEXT وما يزال Pending لم يُنفَّذ** —
بنى الصندوق/النوبات/دفتر الحسابات القائمة أساساتٌ يُبنى عليها ولا
تُحسب تنفيذًا للبند 18. المصدر الحاكم
الكامل: `memory/DECISIONS.md` ق-131. قواعد ق-99 القائمة تبقى كاملة بلا
تخفيف.

- **فصل المال عن ديزل المزارع:** المال يُحفظ ويُحاسب ريالًا يمنيًا كاملًا
  بسلطة المال القائمة؛ وديزل المزارع كمية تُتتبع بوصفها كمية ولا يُحوَّل
  صمتًا إلى مال، ولا مقاصلة بين الاثنين.
- **تطبيق المقدم:** المقدم القديم لا يُستهلك صمتًا. يجوز للنظام أن يحسب
  ويقترح آليًا كم مقدَّم يمكن تطبيقه على التسوية الجارية، لكنه يعرض
  التسوية المقترحة ويشترط **تأكيدًا صريحًا من المستخدم قبل التخصيص/
  القيد** — حفاظًا على قاعدة لا مقاصلة صامتة.
- **حيازة المشغل النقدية:** النقد المحصَّل من مزارع بيد مشغل يبقى مال
  البئر/العمل **في حيازة ذلك المشغل** لذلك البئر؛ وعند الترحيل ينتقل من
  حيازة المشغل إلى صندوق البئر/أمواله العامة — **الترحيل نقل حيازة لا
  يُنشئ إيرادًا ثانيًا**. رصيد المشغل ليس محفظته الشخصية الاقتصادية.
  المصروف مصروف البئر اقتصاديًا دائمًا: إن دُفع فعليًا من نقد في حيازة
  المشغل جاز للحركة المحاسبية أن تخفض رصيد الحيازة مع بقاء التصنيف
  مصروف بئر؛ وإن دُفع من مصدر دفع صالح آخر لا تُخفض حيازة المشغل لمجرد
  أن المشغل سجّل المصروف. تُعاد استخدام بنى الصندوق/النوبات/دفتر
  الحسابات القائمة حيث تفي بالعقد — لا نظام حيازة موازٍ.
- **تحذير حالة المزارع:** عند اختيار مزارع لجلسة أو حجز بيد مشغل مصرَّح
  له، يظهر ملخص تحذيري مختصر **غير مانع** بمقدار ما تسمح به صلاحية
  الخادم: مديونية المزارع، ورصيد مقدمه، وكمية ديزله المملوكة. المعلومة
  إخبارية ولا تحجب بدء السقي آليًا. الدلالات نصية صريحة («عليه
  مديونية»، «له رصيد مقدم») لا إشارات +/- ولا لون وحده.
- **قياس ديزل المزارع:** حيث يتوفر تقدير يجوز حساب كمية استهلاك
  **تقديرية** لديزل المزارع، وقبل اعتبارها فعلية/نهائية يؤكدها المشغل
  أو يصححها؛ والتقديري والفعلي يبقيان متمايزين دائمًا.
- **إثبات المصروفات:** تسجيل المصروف تدفق مالي جوهري قابل للتدقيق:
  مبلغ، ونوع/فئة، ووصف/ملاحظات، ومصدر دفع، ومرفق إيصال/فاتورة/صورة حيث
  يلزم؛ وعند تعذر المرفق سبب صريح لعدم الإرفاق. يُستكمل عقد
  `attachment_skip_reason` القائم (الفجوة 6 من م-29: `api.record_expense`
  لا يمرر السبب بعد) ولا يُبنى نظام موازٍ.
- **دقة المحاسبة:** سلامة المحاسبة ميزة منتج؛ سلطة دفتر الحسابات القائمة
  هي المصدر، ولا أرصدة يدوية موازية مصدرًا منافسًا للحقيقة. التاريخ
  المالي المقيد/المسوَّى يُصحح بنموذج العكس/التسوية/التصحيح القائم لا
  بتعديل صامت.
- **شاشة المدينين:** عرض مصرَّح به لمدينين **البئر الحالي**: إجمالي
  مستحق، وعدد المدينين حيث يناسب، وصفوف مزارعين بمبالغهم، وانتقال إلى
  التفصيل المالي للمزارع. المشغل المصرَّح له يرى جميع مدينين البئر وفق
  الصلاحية المعتمدة. إجراءات تذكير واتساب/رسائل نصية بهاتف المزارع
  المعتمد حيث يُسمح؛ التطبيق يعد رسالة التذكير، ويُسجل حدث تذكير
  ببياناته (المزارع، البئر، الوقت، القناة، الفاعل) — **ولا يُخزَّن جسد
  المحادثة الخارجية أو تاريخها** لأن التطبيق لا يتحكم فيها.
- **توضيحات النطاق:** شبكة آبار بمالكين متعددين؛ المزارع الواحد يتعامل
  مع عدة آبار والعلاقة المالية محسوبة **لكل بئر** وإن كانت الهوية
  مشتركة؛ الشريك شريك في بئر بعينه وقد يشارك في عدة آبار؛ المشغل قد
  يعمل على عدة آبار؛ والحقيقة المالية للأعمال محسوبة لكل بئر.
