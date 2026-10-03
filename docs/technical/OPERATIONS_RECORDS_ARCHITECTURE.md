# Operations Records Architecture

**آخر تحديث:** 2026-10-03
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

## 11. Starting from booking (ق-132)

الحجز ليس جلسة، وbooking ≠ session دائمًا.

زر بدء الجلسة:

- يقرأ Booking.
- يملأ Farmer/Farm والمعلومات المسموحة من بيانات الحجز الحاكمة — لا
  إعادة إرسال الهوية والطاقة من العميل بشكل قابل للاختلاف.
- ثم يستخدم Session Start Contract الحالي.
- كل Session ناتجة عن حجز تحمل العلاقة الحاكمة الصريحة إليه؛ لا
  inference زمني.

**أول بدء يدوي ثم انتقال مشروط (ق-132):** أول جلسة في بداية سلسلة
الحجوزات تحتاج فعل بدء صريحًا من المستخدم — حلول موعد أول حجز وحده
لا ينشئ Session تلقائيًا، مع إشعار عند حلوله يعلم المستخدم أن النظام
ينتظر بدءه. بعد البدء اليدوي يجوز الانتقال التلقائي بين الحجوزات
المؤكدة التالية وفق شروط ق-132: نهاية الدور التشغيلي = actual start +
booked duration (لا scheduled_end القديمة لجلسة بدأت متأخرة)،
والحجز التالي المستحق بلا مانع يبدأ تلقائيًا بإشعار، والمستحق المتأخر
أو المستقبل يطلب قرارًا صريحًا (تشغيل الآن/انتظار)، والإيقاف المبكر
لا يبدأ التالي بصمت، والجلسة العابرة أثناء «انتظار» لا تُغلق تلقائيًا
ولا يبدأ فوقها شيء عند استحقاق التالي — إنذار وتدخل بشري والثوابت
252–253 و742–756 في `INVARIANTS.md`.

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

## 26. ق-131 — محاصيل الجلسة والحجوزات (معتمد توثيقيًا — 2026-09-28)

**الحالة:** العقد Adopted + Documented. **محاصيل الجلسة (المرحلة A) =
Implemented + Local Verified + CI Verified + Emulator UX Accepted (2026-09-29)**؛
MR !21 merged to `main` (`275a99f`)؛ Cloud/Production Pending. **الحجوزات (المرحلة B) Pending**. التنفيذ عبر
م-45 مع الإحالة الإلزامية إلى م-28. المصدر الحاكم: `memory/DECISIONS.md` ق-131.

### محاصيل الجلسة المتعددة (المرحلة A)

- جلسة السقي الواحدة قد تحمل **عدة محاصيل**، تُختار أثناء إدخال بيانات
  الجلسة: خيارات سريعة للمحاصيل المستخدمة سابقًا للأرض/المزرعة نفسها،
  وإمكانية إضافة محصول جديد، وتعدد الاختيار.
- الجلسة تحفظ **لقطة محاصيلها التاريخية الخاصة بها**؛ وتغيير المحصول
  الحالي للأرض لاحقًا **لا يعيد كتابة جلسات أو فواتير أو تقارير تاريخية
  أبدًا**.
- **افتراض كفاية `current_crop` وحدها مرفوض**؛ التنفيذ المحلي حسم
  التخزين كلقطة مستقلة خاصة بكل جلسة عبر Migration 105، ولا يحتاج حقل
  «محصول حالي» للمزرعة.
- العقد المنفذ محليًا: صفر/واحد/عدة محاصيل؛ التطبيع يزيل الفراغات
  والقيم الفارغة والتكرار ويحفظ ترتيب أول ظهور؛ والاقتراحات من المحاصيل
  المستخدمة سابقًا في جلسات المزرعة نفسها، والجديد يصبح اقتراحًا لاحقًا.
- لقطة المحاصيل تمر داخل أمر بدء الجلسة الدائم، وتظهر في الجلسة النشطة
  وملخص الإنهاء والتفاصيل التاريخية، ولا تعيد جلسة لاحقة كتابة القديمة.
- **الدليل:** Migration `20260928010001_105_session_crops.sql`
  واختبارها الدائم؛ قاعدة **44/743 PASS**، Flutter **600/600 PASS**
  وتحليل نظيف، وقبول UX من المالك على المحاكي؛ MR !21 merged to `main`
  (`275a99f`)؛ MR pipeline `2887897982` = SUCCESS؛ post-merge pipeline
  `2891224749`: app/database = SUCCESS وproduction = MANUAL لم تُشغَّل.
  **Cloud/Production Pending**.

### الحجوزات (المرحلة B — على أساس ق-98/م-28)

- افتراض المنتج لهذه المرحلة: **مسار مضخة/مورد واحد لكل بئر** لأغراض
  تعارض الحجز.
- الحجز يتطلب: تاريخًا، وبداية مخططة، ونهاية/مدة مخططة، ومزارعًا،
  وأرضًا؛ ومنع أي تداخل بين حجزين مؤكدين لنفس مسار المورد الحالي —
  **والخادم/الBackend سلطة التعارض النهائية**.
- إعادة الجدولة/التأجيل/الإلغاء تحفظ التاريخ؛ والاستبدال/التبديل لا
  يعيد كتابة التاريخ بصمت.
- **البناء على أساس ق-98/م-28 القائم** (جداول الحجز وسجل الحالة والحجز
  الموردي) لا بناء نظام حجز موازٍ؛ الترتيب: توثيق/تصميم الآن، والتنفيذ
  الكامل بعد استقرار وتقبل مسار المشغل الأساسي.

### الحجوزات — أساس المرحلة B (M112) منفذ ومدموج — ق-131 بند 8 / ق-98 م-28

**الحالة: Implemented + Local Verified + CI Verified + Merged /
Cloud + Production Pending** — GitHub **PR #45** إلى merge commit
`db45b7d2957d29f6bf674f61efe2c250b08e8c55` (2026-10-01):

- Migration `20260930230205_booking_contracts.sql` واختبارها الدائم
  (`20261001_112_booking_contracts.test.sql` = 41 PASS / 0 FAIL /
  0 ERROR؛ الحزمة الكاملة 51/892).
- **قيد استبعاد على مستوى القاعدة** يمنع تداخل الحجوزات المؤكدة على
  نفس البئر بفترات نصف مفتوحة `[start,end)` — هو سلطة التزامن
  النهائية لا الفحص العددي القديم؛ وفحص إغلاق فاشل قبل إضافته.
- مورد `well_path` على `ops.resource_reservations` (مورد = البئر،
  التوازي 1) مع حرس تفرّد نشط واحد لكل حجز وملء غير المتعارضة.
- عقود `api.create_booking` / `api.reschedule_booking` /
  `api.cancel_booking` ذات معرّف عملية إلزامي عبر `sync` بالقبول
  والتعارض معًا، والتعارض نتيجة مكتوبة (`status=conflict` /
  `conflict_code=time_overlap`) لا خطأ SQL خام، وعقود قراءة مكتوبة
  `api.list_well_bookings` / `api.get_booking_detail`.
- صلاحيتا `booking.cancel` (مالك+مشغل) و`booking.read` (مالك+مدير+مشغل)
  مع حفظ نطاق المزارع الذاتي من 079 داخل العقود.
- عمودا `pump_id`/`water_line_id` التاريخيان بقيا وبيّنان في الجديد.
- **المرحلة B لم تُغلق وم-28 لم تُغلق**: بقية المرحلة بق-132 (أدناه).

### ق-132 — عقد تنفيذ الحجوزات وجدول اليوم (معتمد — 2026-10-01)

المصدر الحاكم: `memory/DECISIONS.md` ق-132 والثوابت 742–756 في
`technical/INVARIANTS.md`. تلخص نقاطه في هذا المستند:

- **M113 — Booking Execution Contracts (Implementation Pending):**
  علاقة booking→session الحاكمة، مضخة فعالة واحدة للبئر (لا مضختين
  active)، اكتمال بيانات الحجز المؤكد للتشغيل (والناقص لا يصبح
  confirmed/auto-start-ready)، جدول اليوم بمنطقة `Asia/Aden` دون
  cron ولا نقل قسري عبر منتصف الليل، أول بدء يدوي ثم انتقال تلقائي
  مشروط (القسم 11 أعلاه)، نهاية الدور = actual start + booked
  duration، الإيقاف المبكر بقرار صريح، قواعد «انتظار» والجلسة
  العابرة (لا إغلاق تلقائي ولا بدء ثانية فوقها)، وOffline كامل
  البيانات مع `missed exact start / confirmation required` وجاهزية
  جهاز معلنة لا مُدَّعاة، وانتقال نافذة الشمس إلى البديل المختار
  انتقال حالة/محاسبة يشترط اختيار البديل عند إنشاء الحجز الممتد.
- **M114 — Diesel Reference Price History (Implementation Pending):**
  تاريخ سعر اللتر المرجعي على مستوى البئر/المخزون (actor+time+old/new
  وإشعارات التغيير)، والقيمة المعلوماتية لكميات ديزل المزارع —
  **بلا أي دخول في سعر الجلسة أو الفاتورة أو الدين أو المقدم**
  (ق-17/ق-99 نافذان) ولا إعادة تقييم صامتة للتاريخ؛ والتصحيح التاريخي
  مسار صريح مدقق؛ وتقدير الاستهلاك = معدل المضخة × زمن التشغيل
  الفعلي ويبقى estimated ≠ actual بتأكيد بشري.
- Flutter/Offline/Notifications بعد M113/M114 **ضمن المرحلة B نفسها**؛
  وFCM/Push للإشعارات الخادمية جزء تنفيذ لم يُنفَّذ ولا يوصف منفذًا
  بمجرد وجود `ops.notifications`.

### الزمن الفعلي في سجلات العمليات

**الحالة (2026-09-29): Implemented + Local Verified + CI Verified +
Merged / Cloud + Production Pending** عبر Migration 106؛ MR !24 merged to
`main` (`d3255022`)؛ MR pipeline `2891435913` = SUCCESS؛ post-merge
pipeline `2891454890`: app/database = SUCCESS وproduction = MANUAL لم
تُشغَّل.

سجلات العمليات قد تعرض بداية/نهاية الحجز (المخططة) وبداية/نهاية التنفيذ
(الفعلية) معًا **بشرط تمييزهما صراحةً دائمًا**؛ والفواتير والتقارير
بالفعلية وحدها.

- الجلسة المغلقة ذات المقاطع: الزمن الفعلي = مجموع `actual_seconds`
  لمقاطعها كلها، بما فيها التوقفات غير المفوترة.
- الزمن المفوتر يبقى `billable_seconds` مستقلًا، ولا يُعاد تعريفه أو
  استعماله بوصفه زمن التنفيذ.
- الجلسة التاريخية المغلقة بلا مقاطع تستخدم الغلاف المخزن
  `ended_at - started_at` كـ legacy fallback؛ الجلسة الجارية لا يُختلق
  لها زمن تاريخي نهائي.
- عقود `api.list_well_sessions` و`api.get_session_detail` تعيدان
  الفعلي والمفوتر منفصلين. الدليل المحلي: **45/757 PASS** وFlutter
  **611/611 PASS**.

أي تنفيذ يمس القاعدة يأخذ رقم الهجرة التالي من `AGENTS.md` §4 باختباره
الدائم، ضمن حدود ق-78/ق-79.

[DOC-RECOVERY-Q133-2026-10-03]
---

## ق-133 / M113 — عقد المدة المشروطة للجلسة الحرة (استدراك 2026-10-03)

**المرجع الوظيفي:** ق-133 في `docs/memory/DECISIONS.md`، والثوابت 757–760؛ لا ينسخ علاقة booking→session في ق-132 أو إتمام الجلسات المختوم.

**النموذج المحلي المنفّذ:** عمودان nullable على `ops.irrigation_sessions`: `planned_duration_minutes` و`planned_end_at`، يفصلان التخطيط عن `ended_at` الفعلي. `api.start_adhoc_session` يمر عبر `sync.begin_adhoc_session_command` ثم `ops.start_adhoc_session` وفق منح/إيديمبوتنس مستقلة. يبقى `api.start_irrigation_session` القديم متوافقًا عند غياب حجز مؤكد قادم.

**التمييز الحاكم:** إدراج الجلسة المحجوزة يتم مبدئيًا مع `booking_id=NULL`، ثم يُربط داخل المعاملة نفسها. لذلك لم يُستخدم زناد BEFORE INSERT يصنفه حرًا خطأً؛ استُخدم `CONSTRAINT TRIGGER AFTER INSERT DEFERRABLE INITIALLY DEFERRED` باسم `irrigation_sessions_adhoc_duration_guard` يسترجع الحالة النهائية بالمعرف عند الفحص. الجلسة المرتبطة بحجز تُعفى؛ الجلسة الحرة تحتاج مدة صريحة فقط إذا ظهر حجز مؤكد قادم على البئر، وألا تتجاوز النهاية المخططة بدايته. لا يجوز اعتبار قيمة `NEW.booking_id` القديمة حقيقة ختامية.

**حدود البرهان:** ملفات اختبارات SQL ملتفة بــ`ROLLBACK`؛ فُعّل القيد صراحة في حالات EE، ثم أضيفت EE13–EE15b لمسارات البدء الحر القديم والإكمال والفوترة ومنع المفتوحتين. فحص المالك المحلي الأخير = `52 files/1069 PASS`, `889/544/261/49`. اختبارات M113 الأخرى ذات تجهيزات تُطوى دون تفعيل القيد لا تُعد برهانًا على جميع الحالات؛ التزامن والتداخل العكسي عند تعديل الحجز بالتوازي غير محكوم بالكامل بالقراءة بلا قفل. لا يُنسب إلى هذه الجولة إكمال آلي أو تشغيل فيزيائي.

**حالة التسليم:** M113 mutable/local, الاختبار المحلي ناجح، Git commit/PR/CI/Cloud/Production غير مثبتة لهذه التغييرات. لا نشر قبل معالجة التوافق المرئي وحالات Offline المطلوبة في ق-133.
