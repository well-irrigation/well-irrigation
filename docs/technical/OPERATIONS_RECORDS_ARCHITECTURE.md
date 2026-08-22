# Operations Records Architecture

**آخر تحديث:** 2026-08-18
**القرار الحاكم:** ق-98
**UX:** UX-13
**الحالة:** تصميم تقني ملزم؛ التنفيذ الكامل Pending
**المسألة المفتوحة:** م-28
**أول DB Migration جديدة:** 085 أو أحدث

## 1. الهدف

توحيد قراءة وكتابة:

- Session history.
- Farmer/Farm records.
- Bookings.
- Resource reservations.
- Shifts.
- Session responsibility transfers.
- Operational handover state.

دون إنشاء نماذج موازية في Flutter.

## 2. الأساس الموجود

### جلسات السقي

العقود الحالية للجلسة والتسوية تبقى مصدر الحقيقة.

لا تعاد كتابة منطق الجلسة داخل هذه المعمارية.

### المزارع والأراضي

ق-80 / Migration 075 يفرض:

    Farmer Well Account
        ↓
    Farm
        ↓
    Booking / Session

ولا يجوز الرجوع إلى Login Profile بوصفه هوية المزارع.

### الحجوزات

Migration 032 تحتوي:

- `ops.irrigation_bookings`.
- Business status.
- `booking_status_history`.

الحالة الحالية تتطلب من التطبيق إدخال سجل تغير الحالة
بصورة منفصلة.

هذه نقطة يجب عدم نقلها كما هي إلى Flutter Production.

### حجز الموارد

Migration 033 تحتوي:

- `ops.resource_reservations`.
- `ops.reserve_resource`.
- overlap checking.
- pump/water-line reservation foundation.

### المناوبات والتسليم

Migration 042 تحتوي:

- `ops.shifts`.
- `ops.shift_handovers`.
- `ops.session_shift_transfers`.
- open/close shift.
- session transfer request/response.

Migration 045 تحتوي:

- auto session attachment to open shift.
- shift report.
- operator totals.

Migration 074 تحتوي أغلفة `api.*` الحرجة للمناوبات
والتسليم ونقل الجلسة.

## 3. Session History Read Model

Flutter لا يجمع Timeline مباشرة من جداول متعددة.

يلزم Typed Read Contract يعيد حسب الصلاحية:

- session identity/public code.
- farmer.
- farm.
- operator/current responsibility.
- start/end.
- billable duration.
- business status.
- settlement status.
- energy timeline.
- pause/resume timeline.
- final amount.
- invoice/payment summary.
- sync/conflict indicator where relevant.

المال التفصيلي يبقى ضمن UX-14.

## 4. Historical identity preservation

إذا أصبح Farmer/Farm/Operator غير نشط لاحقًا:

- السجل التاريخي لا يختفي.
- الجلسة القديمة تبقى قابلة للفهم.
- لا Hard Delete لمرجع تاريخي مستخدم.

`ops.farms.status = active/inactive` يعاد استخدامه
للأرض.

أي Deactivation Contract للمزارع يجب فحصه وبناؤه
صراحة إذا كان ناقصًا.

## 5. Farmer and Farm read contracts

نحتاج عقودًا للـ:

- farmer list.
- farmer detail.
- farmer farms.
- farmer recent sessions.
- farmer bookings.
- farm detail.

كلها تعيد Canonical IDs وDisplay Data.

Smart Lookup من ق-88 يعاد استخدامه.

## 6. Booking business state vs sync state

لا تدمج الحالتان.

مثال Local:

    business_intent = pending confirmation
    sync_state = pending

بعد Backend acceptance:

    booking business status = confirmed
    sync_state = synced

النص الموجه للمستخدم لا يحتاج إظهار أسماء الحقول.

## 7. Offline booking rule

Local Device يمكنه حفظ Booking Intent بصورة Durable.

لكن لا يملك سلطة تأكيد المورد النهائي أثناء Offline.

السبب:

جهازان قد يريان نفس Cached Availability ثم يحجزان
الفترة نفسها.

لذلك:

    Local save
        ↓
    waiting for server confirmation
        ↓
    server conflict/resource validation
        ↓
    confirmed OR conflict/review

## 8. Booking command contract

يلزم Migration 085+ عقد typed داخل `api.*` مثل
مفهوم:

- create booking.
- reschedule booking.
- cancel booking.
- confirm/transition booking when authorized.

الأسماء النهائية تحسم عند التنفيذ.

المهم هو الضمانات:

- auth-derived actor.
- well authorization.
- farmer/farm consistency.
- server time/range validation.
- resource availability.
- status history.
- stable command id.
- idempotent retry.
- audit.

## 9. Atomic booking mutation

المطلوب ألا يحدث:

    Booking updated
    BUT
    status history missing

أو:

    Booking confirmed
    BUT
    reservation missing

أو العكس.

لذلك يجب أن تنفذ العملية داخل Transaction واحدة أو
Orchestration بضمانات مكافئة.

## 10. Resource conflict

Backend هو المرجع النهائي.

إذا تعارض Booking Offline عند المزامنة:

- لا يؤكد بصمت.
- لا يختفي.
- يصبح Conflict/Needs Review.
- يعرض الموعد المطلوب.
- يعرض أن المورد لم يعد متاحًا.
- يسمح بإعادة الجدولة وفق الصلاحية.

## 11. Starting from booking

الحجز ليس جلسة.

زر بدء الجلسة:

- يقرأ Booking.
- يملأ Farmer/Farm والمعلومات المسموحة.
- ثم يستخدم Session Start Contract الحالي.

لا ينشئ Session تلقائيًا لمجرد حلول `scheduled_start`.

## 12. Shift state

إغلاق التطبيق لا يغير Shift Business State.

حالة المناوبة تستعاد من Backend/Local Durable State.

إذا كانت هناك مناوبة مفتوحة:

- تظهر بوضوح.
- لا ينشأ Shift جديد موازٍ.

## 13. No orphan active session

العقد المعتمد:

لا يوجد Normal Close Shift مع Active Session
غير منتهية أو غير منقولة.

الحل المسموح:

1. Complete Session.
2. أو Request Transfer.
3. Receiver Accepts.
4. ثم Close Shift.

## 14. Current close-shift implementation conflict

`api.close_shift` الحالي يقبل:

    p_allow_open_sessions

ويسمح للمالك باستخدامه.

هذا تعارض تنفيذي معروف مع ق-98 للمسار العادي.

لا تعدل Migration 074.

يجب في Migration 085+:

- إزالة هذا التجاوز من عقد التطبيق العادي.
- أو جعله غير متاح للتطبيق.
- وعدم استخدامه في Flutter.

إذا احتجنا مستقبلًا Break-glass إداريًا حقيقيًا،
يحتاج قرارًا مستقلًا وتدقيقًا واضحًا.

## 15. Session responsibility transfer

الموجود الحالي جيد كأساس:

- current operator requests transfer.
- target operator accepts/rejects.
- accepted transfer updates responsibility.
- rejected transfer leaves responsibility with sender.

يجب إضافة Idempotency/Offline guarantees عند تنفيذ
الموبايل.

## 16. Operational handover vs cash handover

هذه نقطة حاسمة.

### Operational responsibility

تعني:

- من يدير الجلسة.
- من يستلم مسؤوليتها.
- من قبل النقل.
- ما الحالة التشغيلية.

### Cash handover

تعني:

- مبلغ معلن.
- مبلغ مؤكد.
- فرق.
- تأكيد/تسوية مالية.

Migration 042 الحالية تجعل Cash Handover بتأكيد المالك.

لا نغير هذا ضمن UX-13.

قبول المشغل في القرار 399 يتعلق بالمسؤولية التشغيلية،
وليس اعتماد مبلغ النقد.

## 17. Operational handover summary

يلزم Read Model أو Composition typed يعرض عند التسليم:

- current shift.
- from operator.
- intended receiving operator.
- active session.
- pending session transfer.
- upcoming bookings.
- important operational notes.
- sync/conflict warnings.

لا يشترط إنشاء جدول جديد إذا أمكن بناؤه من الحقيقة
الحالية بأمان.

## 18. Shift history

قائمة المناوبات تقرأ:

- shift public code.
- operator.
- start/end.
- status.
- sessions count.
- handover status.
- unresolved indicators.

التقرير المالي الكامل للمناوبة يناقش مع UX-14.

## 19. Offline shift and transfer actions

وفق ق-89:

- local durable first when action is allowed Offline.
- persistent Outbox.
- stable Command ID.
- ordered replay.
- retry-safe server acceptance.

لا يجوز أن ينتج Retry:

- shift duplicate.
- transfer duplicate.
- second acceptance.
- orphan responsibility.

## 20. Permissions

Flutter hiding is not authorization.

Backend يعيد التحقق.

على الأقل:

- session history read حسب well role.
- booking mutations للمالك/المشغل المخول.
- operational transfer فقط للأطراف المخولة.
- correction path لصلاحية أعلى حسب القرار النهائي.
- account/role administration مؤجل UX-16.

## 21. Search

ق-88 هو السلطة.

لا يوجد Search implementation جديد خاص بـUX-13.

نحتاج فقط Context Filters لـ:

- sessions.
- farmers.
- farms.
- bookings.
- operators/shifts.

## 22. Conflict classes

Conflict يحتاج Review إذا كان يمس:

- booking resource collision.
- farmer identity.
- farm ownership.
- duplicate entity.
- active-session responsibility.
- transfer accepted on incompatible state.
- server authorization change.
- historical record mismatch.

## 23. Required Migration 085+ work

بعد فحص التنفيذ الحالي:

1. Booking typed `api.*` contracts.
2. Booking idempotency.
3. Atomic booking/status-history/reservation flow.
4. Booking reconciliation/read contract.
5. Session history read contract.
6. Farmer/Farm list/detail read contracts.
7. Farmer deactivation/archive contract if missing.
8. Operational handover summary/read contract.
9. Remove normal app access to open-session shift-close bypass.
10. Shift/transfer idempotency for Offline replay.
11. Required audit hooks.
12. permanent acceptance tests.

## 24. Acceptance tests

### Historical records

- inactive farm remains visible in old session.
- inactive operator remains identifiable in history.
- closed session cannot ordinary-edit.
- correction preserves original.

### Farmer/Farm

- same farm name across different farmers accepted.
- wrong farmer/farm relationship rejected.
- duplicate farmer suspect does not autosave.
- inactive farm excluded from ordinary new selection but
  remains visible historically.

### Booking

- online booking confirms only after server validation.
- Offline booking shows waiting confirmation.
- two devices attempt same resource/time.
- one succeeds, other becomes conflict.
- retry does not duplicate booking.
- retry does not duplicate reservation.
- status history matches canonical transition.
- cancel/reschedule preserve history.

### Shift

- one open shift per well.
- normal close rejected with unresolved active session.
- accepted transfer allows responsibility change.
- rejected transfer preserves old responsibility.
- retry does not duplicate transfer.

### Offline

- booking survives process death.
- shift action survives process death.
- transfer replay ordered.
- network loss after server success returns same result.

### Security

- unauthorized booking mutation rejected.
- unauthorized transfer rejected.
- no Direct DML.
- new contracts only through `api.*`.

## 25. Definition of Done

UX-13 لا تعتبر Production Complete حتى:

- م-28 مغلقة.
- typed contracts موجودة.
- booking server confirmation مثبت.
- booking conflict/retry مثبت.
- historical preservation مثبت.
- no-orphan shift rule مثبت.
- transfer acceptance مثبت.
- Offline replay مثبت.
- permissions مثبتة.
- Backend permanent tests ناجحة.
- Android tests ناجحة.
