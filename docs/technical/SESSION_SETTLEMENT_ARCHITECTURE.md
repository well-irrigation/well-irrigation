# Session Completion and Settlement Architecture

**آخر تحديث:** 2026-08-18
**القرار الحاكم:** ق-92
**UX:** UX-12
**الحالة:** تصميم تقني ملزم؛ التنفيذ الكامل Pending
**أول DB Migration جديدة:** 085 أو أحدث

## 1. الهدف

إنشاء تدفق واحد متسق من نهاية جلسة السقي إلى:

- التكلفة النهائية.
- الفاتورة.
- الدفعات.
- التخصيصات.
- الرصيد المقدم.
- رصيد المزارع.
- الإشعارات.

مع دعم Online وOffline وRetry دون Duplicate.

## 2. الأساس الموجود

الموجود حاليًا:

- `ops.complete_irrigation_session`.
- `billing.session_charges`.
- `billing.issue_session_invoice`.
- `billing.record_payment`.
- `billing.allocate_payment`.
- `billing.invoices`.
- `billing.payment_allocations`.
- `sync` idempotency foundation.

يجب البناء فوق هذه المكونات لا إنشاء Accounting Model
موازٍ.

## 3. الفجوة الحالية

الإجراءات الحالية منفصلة منطقيًا:

    complete session
        ↓
    issue invoice
        ↓
    allocate payment

هذا مناسب كأساس داخلي لكنه لا يكفي وحده لتجربة Offline
قابلة لإعادة المحاولة بأمان.

يلزم Orchestration Contract موحد أو Protocol يحقق
ضمانات مكافئة.

## 4. حالات التسوية

الحالات المنطقية المقترحة:

- local_completed.
- settlement_pending.
- settling.
- settled.
- conflict.

Business Session Status وSettlement/Sync Status لا
يدمجان في حقل واحد لمجرد سهولة Flutter.

## 5. Online flow

التدفق المستهدف:

    lock/canonicalize session
        ↓
    complete if not already completed
        ↓
    obtain canonical session charge
        ↓
    ensure one active invoice
        ↓
    apply session-linked payments
        ↓
    leave excess as advance
        ↓
    calculate final summary
        ↓
    acknowledge one settlement result

إذا نجحت خطوة ثم انقطع رد الشبكة، تعاد المحاولة بنفس
Settlement Command ID وتستعاد النتيجة بدل التكرار.

## 6. Offline flow

على الهاتف:

    COMPLETE command
        ↓
    durable local commit
        ↓
    local business state = completed
        ↓
    settlement status = pending
        ↓
    background sync

بعد وصول الخادم:

- تعاد أحداث الجلسة بالترتيب.
- تحسم الدفعات السابقة التابعة للجلسة.
- تنفذ التسوية.
- تحدث Local State إلى settled.
- تحفظ المراجع الخادمية.

## 7. Dependency graph

إذا سجلت دفعة قبل الإنهاء Offline:

    START
        ↓
    PAYMENT
        ↓
    COMPLETE / SETTLEMENT

لا يسمح للتسوية أن تنسى Payment Command أقدم يخص
الجلسة.

إذا كانت الدفعة في Conflict، لا يختلق النظام حالة
«غير مدفوع» نهائية ويتجاهلها.

## 8. Session-linked payment policy

الدفعة التي ينشئها المستخدم من شاشة الجلسة تحمل
Session Context واضحًا حتى لو كانت لحظة التسجيل
محاسبيًا Advance لعدم وجود فاتورة بعد.

عند إصدار فاتورة الجلسة:

    amount_to_apply =
      min(session-linked available payment, invoice outstanding)

تخصص هذه القيمة مرة واحدة فقط.

أي زيادة تبقى Advance.

## 9. Existing old advances

رصيد مقدم قديم غير مرتبط بسياق الجلسة الحالية لا
يستهلك تلقائيًا بصمت.

سبب ذلك:

- قد تكون له غاية أخرى.
- قد توجد فواتير أقدم.
- ترتيب تخصيص الأرصدة القديمة سياسة أعمال مستقلة.

يمكن لاحقًا اعتماد:

- manual allocation.
- oldest-debt policy.
- explicit automatic policy.

لكن لا يفترض أي منها ضمن ق-92.

## 10. Payment states

يجب التفريق بين:

### Received locally

المشغل استلم المال وحفظه الجهاز.

### Server posted

Backend قبل الدفعة ورحلها ماليًا.

### Allocated

جزء من الدفعة خصص لفاتورة محددة.

### Advance remaining

جزء غير مخصص يبقى رصيدًا مقدمًا.

لا يخلط UX هذه الحالات.

## 11. Invoice uniqueness

لكل Session يجب أن توجد فاتورة سارية واحدة كحد أقصى.

Retry يجب أن:

- يعيد invoice الموجودة.
- أو يكمل إنشاء الناقص.
- لا ينشئ Invoice ثانية.

أي Cancel/Reversal يخضع لعقود التدقيق الحالية ولا
يعني أن Flutter يستطيع إنشاء بديل عشوائيًا.

## 12. Fuel billing gate

م-26 يجب أن تغلق قبل اعتماد Settlement Amount إنتاجيًا.

ق-17 وق-91:

- Diesel inclusive hourly.
- Fuel tracking = inventory/cost/control.
- No extra farmer fuel billing.

يجب ألا تنتقل Fuel Charge المتعارضة من Migration 066
إلى Final Invoice.

## 13. Final summary contract

Settlement Result يحتاج على الأقل:

- session_id.
- business status.
- settlement status.
- ended_at.
- billable_seconds.
- final_amount_minor.
- invoice_id.
- invoice public code إذا كان مسموحًا.
- invoice status.
- invoice total.
- paid_minor.
- outstanding_minor.
- session-linked applied payment total.
- remaining advance total الناتج من العملية.
- sync/reconciliation marker.
- conflict marker إذا وجد.

لا يعيد Flutter بناء هذه النتيجة من تخمينات.

## 14. Financial consistency

يجب أن يتحقق:

    session final amount
        =
    invoice total

وبالنسبة للفاتورة:

    paid + outstanding
        =
    invoice total

ولا يسمح بقيم سالبة.

## 15. Immutable settlement

بعد Settlement ناجحة:

لا تعدل مباشرة:

- session start/end.
- farmer/farm identity.
- applied price.
- final charge.
- issued invoice amounts.

التصحيح يحتاج Command منفصلًا ومدققًا.

## 16. Correction path requirement

المسار التفصيلي يناقش لاحقًا، لكن العقد يجب أن يدعم:

- original value preserved.
- correction reason.
- actor.
- occurred_at.
- audit reference.
- financial adjustment or reversal when required.

لا تستخدم Update عاديًا لمحو الحقيقة السابقة.

## 17. Permissions

### Operator

بحسب صلاحياته يمكنه:

- complete.
- see operational result.
- collect payment when authorized.
- see allowed financial summary.

### Owner/Manager

يمكنه رؤية:

- full settlement.
- invoice.
- payment allocations.
- advance.
- conflict.
- correction trail.

الخادم يعيد التحقق من الصلاحية.

## 18. Notifications

بعد Server Settlement فقط يمكن إنشاء أحداث مثل:

- invoice issued.
- payment applied.
- outstanding balance.
- settlement conflict.

النقل والقنوات تدمج مع م-23.

Retry لا يولد Notification Business Event مكررًا.

## 19. Conflict cases

أمثلة:

- historical price ambiguity.
- fuel billing policy conflict.
- unresolved Offline payment.
- duplicate invoice ambiguity.
- payment allocation mismatch.
- authorization changed.
- session already settled with incompatible data.
- time integrity issue.

Conflict يبقي البيانات ولا يحذفها.

## 20. Idempotency requirements

Settlement Command يحتاج Stable Command ID.

الخادم يجب أن يستطيع:

- معرفة أن الأمر نفذ.
- إعادة النتيجة السابقة.
- منع duplicate invoice.
- منع duplicate allocation.
- منع duplicate financial journal effect.
- منع duplicate notification event.

## 21. Required Migration 085+ work

بعد فحص التنفيذ الحالي:

1. إغلاق م-26 Fuel Billing conflict.
2. Settlement orchestration contract.
3. settlement idempotency.
4. session-linked prepayment association.
5. automatic allocation once.
6. final settlement read model.
7. correction/audit command foundation عند الحاجة.
8. notification event deduplication.
9. permanent acceptance tests.

لا تعدل الهجرات المختومة (السقف: `AGENTS.md` §4).

## 22. Acceptance tests

### Completion

- complete running session.
- complete paused session.
- second retry returns same logical result.

### Invoice

- exactly one active invoice.
- invoice total equals session final amount.
- retry does not create duplicate invoice.

### Payment

- no payment => full outstanding.
- partial session payment => partial outstanding.
- exact session payment => paid.
- overpayment => invoice paid + remaining advance.
- allocation retry occurs once.
- old unrelated advance is not silently consumed.

### Offline

- complete Offline.
- payment Offline before complete.
- process death.
- network return.
- ordered replay.
- settlement succeeds.
- retry after lost server response.
- same final result with no duplicate.

### Conflict

- unresolved payment does not disappear.
- unexplained financial mismatch becomes conflict.
- historical pricing ambiguity becomes review.

### Fuel

- fuel quantity does not add extra farmer charge.
- invoice contains no separate farmer fuel charge under Q17.

### Security

- unauthorized settlement rejected.
- no Direct DML.
- anon has no new execute access.

## 23. Definition of Done

UX-12 لا تعتبر Production Complete حتى:

- M-26 مغلقة.
- M-27 مغلقة.
- settlement contract idempotent.
- invoice uniqueness مثبتة.
- payment allocation مثبت مرة واحدة.
- excess advance صحيح.
- Offline flow مثبت.
- final read model موجود.
- correction path غير destructive.
- permanent tests ناجحة.

## ق-99 / UX-14 — Farmer Account Handoff

ق-99 تكمل ق-92 بعد إصدار الفاتورة والتسوية.

القواعد المشتركة:

- Session-linked payment تطبق على سياق الجلسة حسب ق-92.
- Excess يبقى Advance.
- Existing old Advance لا يستهلك بصمت.
- استخدام old Advance لاحقًا فعل مالي صريح.
- Farmer account يعرض debt وadvance منفصلين.
- لا يظهر Net Zero قبل وجود Allocation Canonical.
- Offline payment لا تصبح Posted قبل ACK.
- Payment idempotency تبقى ضمن م-27 وم-29 معًا.

## ق-129 / FIN-001 — تسوية الجلسة متعددة المصادر وفصل السداد

**التاريخ:** 2026-09-16
**الحالة:** مُنجز ومُثبت؛ القبول الميداني مُجتاز بالكامل على الجهاز الحقيقي (Samsung Galaxy A13) وفق 42 بند قبول (42/42 PASS)، وق-129 وم-43 مُغلقتان نهائيًا.

### 1. حساب المقاطع المستقلة واقتطاع كل مقطع (FIN-001)

- تكلفة الجلسة = مجموع مبالغ مقاطع التشغيل المستقلة:
  `final_amount = sum((segment_seconds * hourly_rate) ~/ 3600)`
- كل مقطع يحتفظ بمصدر طاقته وسعره المعتمد وقت تشغيله؛ وتغيير المصدر لا يعيد تسعير المقاطع التاريخية إطلاقًا.
- البرهان الميداني الحقيقي المعتمد:
  - مقطع الشمس: 2386 ثانية @ 5000 ريال/ساعة = 3313 ريال.
  - مقطع ديزل البئر: 65 ثانية @ 10000 ريال/ساعة = 180 ريال.
  - الإجمالي النهائي الصحيح: `3313 + 180 = 3493 ريال` (رُفض نهائيًا الرقم 6808 ريال).

### 2. فصل الإنهاء والسداد وربط مرجع الرسوم

- إنهاء الجلسة عبر `ops.complete_irrigation_session` هو خطوة الإغلاق الرسمية التي تثبت المقاطع وتنتج قيد الرسوم `billing.session_charges` (`sessionCharge`).
- تسجيل السداد مرحلة اختيارية منفصلة تمامًا، سواء تمت مباشرة بعد الإغلاق أو أُجلت لوقت لاحق.
- أمر تسجيل السداد يستند صراحة إلى مرجع `sessionCharge` الناتج عن أمر الإكمال.
- امتناع المزارع عن السداد أو تأجيل الدفع لا يعطل اكتمال الجلسة ولا يلغي أمر الإغلاق.

## ق-131 — الفاتورة الرسمية ونافذة الشمس والانتقال التلقائي (معتمد توثيقيًا — 2026-09-28)

**الحالة:** Adopted + Documented؛ **شريحة الزمن الفعلي مقابل المفوتر
منفذة ومتحققة محليًا في م-45/A (Migration 106 / commit `400bd98`)؛
قدرات الفاتورة الرسمية الكاملة ونافذة الشمس ما تزال Pending**. التنفيذ عبر
م-45 (المرحلتان A وC) على الأساس القائم لمقاطع الطاقة (سلطة الطاقة
التشغيلية من ق-81/076) وقواعد FIN-001 أعلاه. المصدر الحاكم الكامل:
`memory/DECISIONS.md` ق-131.

### الفاتورة المالية الرسمية

- فاتورة جلسة السقي **وثيقة مالية رسمية قابلة للتدقيق**، بوضوح عملي قريب
  من فاتورة التجزئة موافقًا للسقي. تعرض على الأقل: اسم البئر، مرجع
  الفاتورة/المرجع العام، مرجع الجلسة، اسم المشغل، المزارع، الأرض/المزرعة،
  **كل محاصيل الجلسة**، بداية التنفيذ ونهايته ومدته **الفعلية**، مقاطع
  مصادر الطاقة ومددها، المبالغ والمسدد والمتبقي، معلومات المقدم المنطبقة،
  وبقية تفاصيل الجلسة/التسوية الحاكمة اللازمة للتدقيق.
- **الزمن الفعلي للتنفيذ هو المصدر** لا أوقات الحجز المخططة؛ ويجوز عرض
  المخطط مع الفعلي بشرط تمييزهما الصريح الدائم.
- **تنفيذ 2026-09-29:** العرض الحالي للسجل/التفصيل/المشاركة والإيصال
  يستخدم مدة التنفيذ الفعلية، ويعرض الزمن المفوتر بعنوان صريح فقط؛
  الحساب المالي نفسه بقي على `billable_seconds`. هذا لا يعني اكتمال
  PDF/الحفظ/الطباعة/المشاركة الرسمية المطلوبة في المرحلة C.
- القدرات المطلوبة للوثيقة: PDF، حفظ محلي، طباعة Android، مشاركة النظام،
  واتساب، وتمثيل نصي للرسائل حيث ينطبق. **وجودُ المتطلب في المرجع
  الوظيفي لا يجعله منفذًا — كلها Pending عبر م-45 مرحلة C.**

### نافذة الشمس والمصدر البديل والانتقال التلقائي

- المنطقة الزمنية التشغيلية للمنصة كلها `Asia/Aden` حصرًا لهذا المنتج
  اليمني؛ **لا تُشتق قواعد الوقت التشغيلية من منطقة الهاتف** (اتساقًا
  مع أساس ق-125/هجرة 098 لحدود اليوم).
- نافذة التشغيل الشمسي الافتراضية على مستوى المنصة: `06:00 <= الوقت
  اليمني < 18:00`. لا يعدّلها مالك/مشغل عادي؛ التعديل لـPlatform Admin
  حصرًا عبر إعدادات إدارة المنصة بوصفها إعدادًا منمَّطًا مُتحققًا قابلًا
  للتدقيق والإصدار وفق معمارية إعدادات PA القائمة — والتنفيذ Pending
  (معماريا الإعدادات الممنهجة نفسها غير منفذة وفق م-35). بيت الإعداد
  الإداري في `PLATFORM_ADMINISTRATION_ARCHITECTURE.md` قسم ق-131.
- عند اختيار الشمس لجلسة يختار المشغل أيضًا **المصدر البديل بعد انتهاء نافذة الطاقة الشمسية**
  من البدائل الفعلية المؤهلة لذلك البئر/الجلسة (ديزل البئر، ديزل
  المزارع) وفق قواعد الطاقة الحاكمة وتوفرها، وتعرض الواجهة الزمن
  الشمسي المتبقي قبل البدء.
- **الانتقال التلقائي عند انتهاء نافذة الطاقة الشمسية:** عند الوقت المُعدَّل يُغلق مقطع
  الشمس ويبدأ مقطع البديل المختار **تلقائيًا — بلا انتظار تأكيد
  المشغل**، بالوقت المحدد نفسه، وبلا إعادة تسعير الزمن الشمسي السابق
  بسعر البديل؛ وسعر/لقطة البديل يتبع قواعد التسعير التاريخية الحاكمة
  القائمة؛ والانتقال متوافق مع قواعد Offline/Outbox الدائمة: إن لم
  يتوفر سعر بديل موثوق دون اتصال تبقى حقيقة الزمن والمصدر محفوظة وتبقى
  الإجمالية المالية بانتظار التسعير (`Pending`) لا تخمينًا — ذات سلوك
  pricing-pending الموثق في FIN-001 أعلاه.
- **هذا استثناء ضيق وحيد من قاعدة التأكيد اليدوي لتغيير المصدر**: قواعد
  ق-129/FIN-001 للتغيير اليدوي — ومنها نية المصدر أثناء التوقف ومنع
  إعادة تسعير المقاطع السابقة — تبقى كاملة بلا تخفيف. و«التغيير
  التلقائي» في V1 يعني تغيير الحالة الحاكمة للجلسة ومقاطعها ومحاسبتها
  في التطبيق — **لا تبديلًا فيزيائيًا للمضخة**؛ الأتمتة الفيزيائية
  تتطلب تكامل وحدات تحكم مستقبلية وقرارًا مستقلًا.
- تذكير محلي للمشغل قبل انتهاء نافذة الطاقة الشمسية بالزمن الشمسي المتبقي جزء من هذا
  العقد؛ **توقيت التذكير وقناته سؤال تنفيذ مفتوح لا يُقرر هنا**،
  والإشعارات اللحظية الواسعة تبقى مؤجلة (بند 23 من ق-131) مع ترك خطافات
  أحداث نظيفة لعمل الإشعارات اللاحق.
