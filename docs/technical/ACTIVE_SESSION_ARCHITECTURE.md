# Active Irrigation Session Architecture

**آخر تحديث:** 2026-08-23
**القرار الحاكم:** ق-91؛ ونموذج القراءة المحلي والاستعادة بق-116
**UX:** UX-11
**الحالة:** تصميم تقني ملزم؛ **بند 16 منفَّذ ومُبرهن بق-116**،
وبقية التنفيذ (الشاشة والعقود الخادمية) Pending
**أول DB Migration جديدة:** 085 أو أحدث

## 1. الهدف

توحيد ما تعرضه شاشة الجلسة الجارية مع:

- مصدر الحقيقة التشغيلي.
- التسعير.
- الدفعات.
- Offline state.
- Sync state.
- نتيجة الإنهاء النهائية.

لا يجوز بناء Live Counter بمنطق مالي مختلف عن Backend.

## 2. المصادر الحالية التي يعاد استخدامها

الموجود حاليًا:

- `ops.irrigation_sessions`.
- `ops.session_segments`.
- `billing.session_charges`.
- `billing.payments`.
- `ops.start_irrigation_session`.
- `ops.pause_irrigation_session`.
- `ops.resume_irrigation_session`.
- `ops.change_session_energy_source`.
- `ops.complete_irrigation_session`.
- `sync` idempotency foundation.
- Local Outbox المطلوب في ق-89.

لا تنشأ Session Model موازية.

## 3. حالتان مستقلتان

كل جلسة لها منطقيًا:

### Business state

مثل:

- running.
- paused.
- completed.

### Sync state

مثل:

- local_only.
- pending.
- syncing.
- synced.
- failed.
- conflict.

مثال صالح:

    business_state = running
    sync_state = pending

لا يدمجان في Status واحد.

## 4. Active Session Read Model

Flutter يحتاج نموذج قراءة موحدًا يحتوي حسب الصلاحية:

- session ID.
- well ID.
- farmer identity/display.
- farm identity/display.
- pump identity/display.
- started_at.
- current business state.
- current segment type.
- current energy source.
- current segment started_at.
- closed billable seconds.
- current billable state.
- pause started_at إذا كانت Paused.
- applied current time rate.
- pricing pending flag.
- payments received/posted/pending as appropriate.
- sync status.
- conflict status.
- server reconciliation marker.

إذا كان المطلوب غير متاح من العقود الحالية، يضاف
Typed Read Contract في `api.*`.

Flutter لا يجمع جداول داخلية عبر Data API.

## 5. Billable time

الوقت المعروض الرئيسي:

    closed billable seconds
        +
    current running segment elapsed seconds

Pause segment:

    billable = false

لذلك لا يزيد عداد السقي أثناء Pause.

Wall-clock elapsed يمكن عرضه كتفصيل فقط.

## 6. Live accrued amount

وفق ق-17 وق-91:

### Closed running segments

تجمع Time Charge المعتمدة فقط.

### Current running segment

إذا كان applied inclusive hourly rate معلومًا:

    running_charge =
      elapsed_billable_seconds * applied_hourly_rate / 3600

القسمة عددية صحيحة مرة واحدة وفق قواعد المشروع.

### Pause

لا تضيف Time Charge.

### Pricing Pending

لا يحسب Flutter رقمًا وهميًا.

يعرض:

    التكلفة بانتظار المزامنة

## 7. Fuel billing consistency

ق-17:

- diesel billing = inclusive hourly.
- fuel quantity = cost/control only.
- no separate farmer fuel billing.

Migration 066 الحالية تحتوي:

- fuel_charge_minor.
- total_charge_minor = time_charge_minor + fuel_charge_minor.
- aggregation of total_charge_minor into session charge.

هذه Gap تنفيذية.

في Migration 085+ يجب توحيد التنفيذ مع ق-17.

الهدف بعد التصحيح:

    farmer billed amount
        =
    approved time-based inclusive charge

ولا يضاف Fuel Cost مرة أخرى.

يمكن الاحتفاظ بقياس الوقود لأغراض:

- inventory.
- operating cost.
- audit.
- profitability.

لكن ليس كدين إضافي على المزارع.

## 8. Payment display

ثلاث حقائق منفصلة:

### Accrued

ما استحق من تشغيل حتى الآن.

### Received locally

مبلغ استلمه المشغل وحفظه Durable Offline.

### Posted

دفعة قبلها Backend وأصبحت جزءًا من السجل المالي
الخادمي.

في شاشة العمل يمكن عرض المبلغ المستلم محليًا فورًا،
لكن يجب تمييز Pending Sync.

في التقارير الخادمية لا يصبح Posted قبل ACK.

## 9. Remaining and advance

للعرض اللحظي:

    remaining = accrued - received

إذا كانت النتيجة موجبة:

    المتبقي حتى الآن

إذا كانت سالبة:

    رصيد مقدم = received - accrued

لا يستخدم رقم سالب في واجهة المستخدم.

التسوية النهائية تحسم بعد Completion.

## 10. Pause reason model

Backend الحالي يمثل نوع Pause الأساسي.

المطلوب إضافة Detail Reason منفصل.

المقترح المنطقي:

### pause_type

- operator_pause.
- farmer_requested_pause.

### detail_reason

قيم أعمال مستقلة قابلة للتوسعة مثل:

- pump_failure.
- power_unavailable.
- waiting.
- maintenance.
- other.

### note

مطلوبة عند `other` إذا اعتمد ذلك أثناء التنفيذ.

لا تحول detail_reason إلى Session Status.

## 11. Resume normal

Resume العادي:

- يغلق Pause.
- يعيد آخر running energy source.
- يعيد السعر المثبت للمقطع السابق.
- لا يلتقط سعرًا جديدًا.

هذا يطابق الأساس الحالي.

## 12. Resume with new energy

مطلوب Contract ذري جديد أو توسعة آمنة للعقد.

العملية المنطقية:

    lock session
        ↓
    verify paused state
        ↓
    close pause at resumed_at
        ↓
    create new running segment
        ↓
    new energy source
        ↓
    historical pricing at resumed_at
        ↓
    one atomic result

لا يسمح بإنشاء Running Segment وهمي بالمصدر السابق.

## 13. Change energy while running

يعاد استخدام العقد الحالي بعد توحيد التسعير مع ق-17.

العملية:

    close current running segment
        ↓
    open new running segment
        ↓
    same session
        ↓
    capture new source rate

## 14. Complete while paused

UX يسمح بإنهاء الجلسة وهي Paused.

يجب أن يكون السلوك النهائي:

- close pause at completion time.
- no new billable segment.
- billable seconds remain unchanged after pause began.
- finalize approved time charges.
- no fake resume.

إذا كان العقد الحالي يحقق ذلك، يثبت باختبار دائم.

إذا لا، يصلح في Migration 085+.

## 15. Offline commands

كل عملية:

- pause.
- resume.
- resume with new energy.
- change energy.
- record payment.
- complete.

تحتاج:

- stable command ID.
- occurred_at.
- sequence.
- durable local commit.
- ordered replay.
- idempotent server result.

## 16. Local recovery

بعد Process Death أو Reboot يعاد بناء:

- current business state.
- billable duration.
- current pause duration.
- energy source.
- received local payments.
- sync status.
- pending commands.

لا يعتمد على Timer object قديم في RAM.

### 16أ. منفَّذ — ق-116 (2026-08-23)

البنود السبعة أعلاه **كلها منفَّذة ومُبرهنة** في
`apps/mobile/lib/core/session/`، ومصدر الاستعادة محسوم:
**طابور ق-116 نفسه، لا جدول حالة محلي موازٍ.** جدول موازٍ يعني
كتابتين لكل حدث، وانقطاعٌ بينهما يترك حالة تخالف الأحداث
المحفوظة وتُعرض كأنها صحيحة.

البرهان يجري على **ملف قرص حقيقي**: تُكتب الأحداث، يُغلق
المخزن كأن التطبيق مات، وتُفتح **نسخة مخزن جديدة تمامًا** من
نفس الملف ⟹ السبعة تعود متطابقة.
`flutter test` = 115 PASS / 0 FAIL.

قواعد التنفيذ التي لا يجوز كسرها:

1. الأحداث تُحوَّل إلى **مقاطع**، والقسمة على كل مقطع ثم
   تُجمع — نفس بند 5 وبند 19 و`Migration 066`.
2. **حالة السقي وحالة المزامنة حقلان** (بند 3): ملف الحالة
   العملية لا يستورد من طبقة المزامنة شيئًا، فالفصل بنيوي.
3. **سلامة الزمن بمرساة + قراءة جهاز** لا بأحدهما (بند 19):
   اشتقاق القراءة من المرساة يجعل المقارنة بين الرقم ونفسه
   فيستحيل رفع العلم.
4. **الدفعة المحلية ليست «مُرحَّلة»** قبل معرّف خادمي محسوم.
5. **بلا لقطة تسعير: نصّ الانتظار بلا رقم** (القرار 341)،
   والزمن المقاس يُعرض على أي حال.

باقٍ على هذه الطبقة: أسماء المزارع والأرض والمضخة تحتاج بند 20
بند 2، فالنموذج يحمل معرّفات ولا يخترع نصًّا معروضًا.

## 17. Double tap

UI disable وحده غير كافٍ.

الحماية:

1. UI temporary disable.
2. stable local command ID.
3. durable outbox uniqueness.
4. server idempotency.

## 18. Session exit

Navigation away لا يغير Business State.

الجلسة تبقى Running/Paused حتى Command صريح.

## 19. Financial consistency chain

يجب أن تكون السياسة نفسها في:

    Active live amount
        ↓
    Completion result
        ↓
    Session charge
        ↓
    Invoice
        ↓
    Farmer balance

أي اختلاف في Fuel Billing أو Rate Snapshot يعتبر
Defect يمنع الإغلاق التقني.

## 20. Required Migration 085+ work

حسب الحاجة وبعد فحص العقود الحالية:

1. Correct fuel billing conflict with Q17.
2. Active session typed read contract.
3. Pause detail reason model/API.
4. Atomic resume-with-new-energy contract.
5. Complete-from-pause proof/fix.
6. Live accrued amount read inputs.
7. Active payment/advance coordination.
8. Offline idempotent wrappers.
9. reconciliation responses.
10. permanent acceptance tests.

Migrations 071–084 لا تعدل.

## 21. Acceptance tests

### Time

- running counter increases.
- pause freezes billable counter.
- resume continues.
- repeated pauses produce correct total.
- no rounding.

### Money

- live hourly amount uses integer formula.
- payment does not reduce accrued value itself.
- remaining is correct.
- overpayment displays advance.
- no payment line when none exists.
- Pricing Pending does not display zero.
- fuel quantity never increases farmer billed amount beyond inclusive rate.

### Energy

- running source change creates one new segment.
- normal resume uses previous source/rate.
- resume-with-new-energy creates no phantom old-source runtime.

### Completion

- complete while running.
- complete while paused.
- billable seconds stop at pause.
- final amount matches live policy.
- invoice amount follows same policy.

### Offline

- pause Offline.
- resume Offline.
- energy change Offline.
- payment Offline.
- complete Offline.
- process death.
- reboot.
- ordered replay.
- duplicate retry has one server effect.

### Permissions

- unauthorized user cannot operate session.
- Flutter has no Direct DML.
- anon has no new execute permission.

## 22. Definition of Done

UX-11 لا تعتبر Production Complete إلا عندما:

- ق-17 وBackend متطابقان.
- Active Read Contract موجود.
- Live amount صحيح.
- Pause detail موجود.
- Resume with new energy آمن.
- Complete from Pause مثبت.
- Offline actions idempotent.
- payment reconciliation صحيح.
- Android recovery مثبت.
- permanent tests ناجحة.

## 23. ق-92 — Handoff إلى Settlement

عند Complete لا تنتهي مسؤولية النظام عند تغيير
`irrigation_sessions.status`.

بعد UX-11 ينتقل التدفق إلى:

`technical/SESSION_SETTLEMENT_ARCHITECTURE.md`

وهو المصدر الحاكم لـ:

- Final Charge.
- Invoice.
- Payment Allocation.
- Advance.
- Outstanding.
- Settlement Retry.
- Offline reconciliation.

Active Session Live Amount لا يعتبر بديلًا عن Settlement
Result النهائي.
