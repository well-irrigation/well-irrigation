# Session Completion and Settlement Architecture

**آخر تحديث:** 2026-08-18
**القرار الحاكم:** ق-92
**UX:** UX-12
**الحالة:** تصميم تقني ملزم؛ التنفيذ الكامل Pending
**أول DB Migration جديدة:** 078 أو أحدث

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

## 21. Required Migration 078+ work

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

لا تعدل migrations 071–077.

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
