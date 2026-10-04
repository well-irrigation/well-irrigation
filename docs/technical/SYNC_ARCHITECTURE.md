# Offline and Synchronization Architecture

**آخر تحديث:** 2026-10-03
**القرارات الحاكمة:** ق-75، ق-89، ق-90، ق-91، ق-92، ق-114، ق-115
**الحالة:** الخادم منفذ جزئيًا — idempotency الدورة الميدانية
الأولى موصول ومُثبت بق-114؛ وطابور الهاتف الدائم منفَّذ ومُثبت
بق-115؛ الإرسال الخلفي والشاشات ضمن Stage 7

## 1. لا تخلط بين Concurrency وSynchronization

### Concurrency

منع تشغيل موارد متعارضة في الوقت نفسه، مثل قفل المضخة
وحجوزات الموارد.

هذه قواعد أعمال في `ops`.

### Synchronization

مزامنة أوامر وبيانات الهاتف مع الخادم عند وجود اتصال.

هذه مشكلة مختلفة.

## 2. ما هو منفذ على الخادم

الهجرة 058 أنشأت طبقة `sync`:

- `sync.processed_commands`
- `sync.begin_command`
- `sync.finish_command`
- `sync.sync_conflicts`

الهدف:

- idempotency.
- منع تنفيذ command نفسه مرتين.
- حفظ نتيجة command المكرر.
- وجود سجل تعارضات server/client.

وقد اختُبر سيناريو الأمر المكرر ضمن الاختبارات الدائمة.

**تحديث 2026-08-22 — ق-114 / Migration 083+084:** طبقة 058
كانت مبنية وغير موصولة: لا دالة واحدة على الخادم تستدعيها،
ولا واحدة من 33 دالة `api.*` تقبل معرّف عملية. أُضيفت 4
مُحلِّلات في `sync` تستخرج الجهة من البئر أو الجلسة، وأُعيد
تعريف 8 أغلفة `api.*` بمعرّف عملية اختياري أخير. التفاصيل
في القسم 5.

كذلك سُحبت منح `PUBLIC` الافتراضية عن `sync.begin_command`
و`sync.finish_command`؛ فهما تأخذان `tenant_id` بلا تحقق
فلا يجوز أن تكونا في متناول أي دور عميل.

## 3. ما لم يعتبر منفذًا على الهاتف بعد

لا يوصف أي مما يلي بأنه مكتمل حتى يثبت داخل Flutter:

- ~~Local outbox~~ — **منفَّذ** بق-115 (2026-08-23):
  `apps/mobile/lib/core/sync/` — مرتَّب، بمعرّف عملية ثابت،
  وحلّ مراجع، وتصنيف فشل، ومُثبت بحزمة اختبارات Dart.
- ~~Local durable database~~ — **منفَّذة** بق-115 لنطاق
  الطابور والربط وحالة المزامنة (`sqflite`). البيانات
  المرجعية المُخزَّنة والصلاحيات والجلسات النشطة باقية.
- PowerSync integration.
- ~~retry queue~~ — **منفَّذ** بق-115: عدّاد محاولات وتصنيف
  «يُعاد» مقابل «يحتاج مراجعة». **الجدولة الزمنية للإعادة
  بلا فتح التطبيق باقية.**
- connectivity recovery — **باقٍ.** الإرسال اليوم يجري عندما
  يكون التطبيق مفتوحًا فقط؛ لا مراقب اتصال ولا عامل خلفي.
- device registration.
- `iam.user_devices`.
- `audit_logs.device_id`.
- conflict-resolution UX.
- pending/synced/failed indicators — النصوص والحالات موجودة
  في الطابور (ق-108)، ولا شاشة تعرضها بعد.
- ~~إعادة التشغيل بعد إغلاق التطبيق~~ أو نفاد البطارية —
  **العملية المحفوظة لا تُفقد** ولا تُرسل مرتين؛ مُثبت على
  SQL الحقيقي بإعادة فتح ملف القاعدة. **الإرسال التلقائي عند
  الإقلاع باقٍ** (يحتاج العامل الخلفي).

## 4. علاقة Sync بعقد API

ق-78 وق-79 لا يسقطان عند العمل دون إنترنت.

عند إرسال العمليات المؤجلة من الهاتف:

    Mobile Outbox
        |
        v
    api.*
        |
        v
    Internal business procedure

لا تصبح المزامنة ذريعة لاستدعاء جدول داخلي أو schema داخلي مباشرة.

## 5. Idempotency

كل command محمول يجب أن يحمل معرفًا ثابتًا محليًا
يمكن للخادم استخدامه لمنع التنفيذ المكرر.

**تحديث 2026-08-22 — ق-114 / Migration 083+084:**
`sync.begin_command/finish_command` لم تبق بنية غير موصولة.
الدورة الميدانية الأولى (القسم 13) صارت موصولة فعلًا:

- 8 أغلفة `api.*` تقبل `p_command_id uuid` اختياريًا في
  **آخر** قائمة الوسائط: `start_irrigation_session`،
  `pause_irrigation_session`، `resume_irrigation_session`،
  `change_session_energy_source`،
  `complete_irrigation_session`، `record_payment`،
  `create_farmer`، `create_farm`.
- نفس المعرّف مرتين ⟹ سجل واحد، ونفس النتيجة المُعادة
  حرفيًا. `record_payment` لا يتضاعف إجماليها.
- `p_command_id = null` ⟹ المسار القديم بلا فرق.
- **الجهة تُستخرَج على الخادم** من البئر أو الجلسة عبر 4
  مُحلِّلات في `sync`؛ العميل لا يُرسل `tenant_id` أبدًا.
- الحماية تعمل فقط إذا أرسل العميل معرّفًا **ثابتًا لكل
  عملية ميدانية لا لكل محاولة إرسال**. هذا التزام على
  طبقة الهاتف، وهو بقية م-25.

خارج النطاق حتى الآن: الورديات ونقل الجلسة والحجوزات
(ق-98) والمصروفات والتوزيعات (ق-99) — تُنقل بنفس النمط.

التفاصيل في `DECISIONS.md` / ق-114 و`MIGRATIONS.md` /
083 و084.

## 6. التعارضات

وجود `sync.sync_conflicts` لا يعني أن UX التعارض مكتمل.

Stage 7 يجب أن يحسم:

- من يفوز عند التعارض.
- ما العمليات التي يمكن دمجها.
- ما العمليات المالية التي لا يجوز دمجها تلقائيًا.
- ما الذي يراه المستخدم.
- كيف يعاد الإرسال.

## 7. قاعدة العمليات المالية

لا تعاد العملية المالية مرتين نتيجة retry.

ولا يسمح للعميل بإعادة بناء أجزاء العملية محليًا ثم كتابتها
كجداول منفصلة.

العملية الذرية نفسها هي وحدة المزامنة.

## 8. حالة التنفيذ الحالية

Server-side sync foundation: منفذة.

Mobile offline workflow: **منفَّذ جزئيًا** — ق-115.

| الشق | الحالة |
|---|---|
| حفظ العملية دائمًا على الجهاز | منفَّذ ومُثبت |
| معرّف عملية ثابت لكل عملية ميدانية | منفَّذ ومُثبت |
| الترتيب داخل الجلسة واستقلال الأصول | منفَّذ ومُثبت |
| حلّ معرّفات الأصل عند الإرسال | منفَّذ ومُثبت |
| تصنيف الفشل: إعادة مقابل مراجعة | منفَّذ ومُثبت |
| الإرسال والتطبيق مفتوح | منفَّذ |
| الإرسال بلا فتح التطبيق (Worker) | **غير منفَّذ** |
| الاستعادة التلقائية بعد إقلاع الهاتف | **غير منفَّذ** |
| شاشات الحالة والجاهزية | **غير منفَّذة** |
| أي واجهة ميدانية تُدخل العمليات | **غير منفَّذة** |

PowerSync: مخطط له في Stage 7، وليس baseline مثبتًا حاليًا.
الطابور خلف بوابة مجرَّدة، فالانتقال إليه لا يلمس المنطق.

Field testing: م-21.

## 9. ق-88 — Search Cache والعمل دون اتصال

Smart Lookup يمكن أن يستخدم Local Cache لسرعة عرض
الخيارات.

لكن يجب الفصل بين:

### Cached suggestion

نسخة محلية للعرض والبحث تحمل UUID الخادمي.

### Canonical business record

السجل المعتمد على الخادم.

قواعد الدمج:

- UUID هو مفتاح الدمج.
- وصول النتيجة نفسها من local وserver لا ينتج صفين.
- cache القديم يمكن تحديث label الخاص به.
- البحث المحلي لا يمنح صلاحية غير موجودة.
- cache لا يثبت أن السجل ما زال active إذا كانت
  هذه المعلومة قديمة.

## 10. إنشاء Master Data Offline

إنشاء مزارع أو أرض جديدة Offline ليس معتمدًا لمجرد
وجود نموذج إدخال محلي.

قبل تمكينه يلزم:

- command id ثابت.
- idempotency.
- duplicate resolution.
- conflict UX.
- safe retry.
- canonical server UUID mapping.

حتى ذلك الحين، لا يدعي التطبيق أن سجلًا جديدًا أصبح
معتمدًا إذا لم يصل إلى الخادم.

### 10.1 إنشاء الأرض دون اتصال — Implemented + Local Verified؛ Backend Cloud Verified (Migration 101)

هذا الجزء (إنشاء الأرض مع مرجع كيان قابل للحل ومنع التكرار عند القبول)
منفَّذ محليًا ومُثبت للحزمة الحالية فقط. **لا يُغلق ق-89 كله ولا كامل
معمارية العمل دون اتصال** — بقية العمليات والتعارضات وباقي بنود ق-89 على
حالها. Backend Migration 101 دُمجت إلى `main` ونُشرت وتحققت سحابيًا؛ هذا لا يحوّل بقية ق-89 أو طبقة الهاتف كلها إلى Cloud Verified.

الواقع من الكود الحالي في الفرع (`entity_reference.dart`،
`offline_session_coordinator.dart`، `sync_engine.dart`):

- الكيان المعلَّق محليًا يُمثَّل بـ`EntityReference` من نوعين:
  `PendingLocalEntityReference` (مرجع محلي `{$ref: localId, $kind}` لم
  يُحسم بعد) أو `ServerEntityReference` (UUID خادمي محسوم). العمليات
  اللاحقة التي تعتمد على الأرض تحمل **مرجعًا قابلًا للحل** لا مجرد UUID
  محلي نهائي.
- عند قبول الخادم لـ`create_farm`، يُحلّ المرجع إلى canonical server
  `farm_id` للعمليات التابعة عبر خريطة الهوية المحلية→الخادمية في الطابور
  الدائم. حالة `matched_existing` أيضًا **تحل إلى canonical existing
  farm_id** لا إلى صف جديد.
- إعادة المحاولة أو `matched_existing` **لا تُنتج duplicate**: نفس
  `command_id` يعيد الرد المخزن، والمطابقة تعيد المعرّف القائم.
- حالات التعارض/عدم الحسم (`requires_resolution`،
  `requires_disambiguation`، أو أمر بحالة review) **لا تتحول إلى نجاح
  محلي كاذب**؛ المحرك يتركها معلّقة/للمراجعة ولا يدّعي الحسم.

الحالة: **Mobile integration = Local Implemented/Verified**، و**Backend Migration 101 = Cloud Verified**. هذا الوصف لا يغلق ق-89 كله ولا يدّعي تحققًا سحابيًا لسلوك الهاتف نفسه.

## 11. الدفعة مع بدء الجلسة

إذا نفذت عملية مركبة من بدء الجلسة + دفعة، تصبح
العملية المركبة نفسها وحدة retry منطقية.

لا يسمح أن تؤدي إعادة الإرسال إلى:

- جلستين.
- دفعتين.
- دفع بلا سياق صحيح.
- Session state تختلف عن Payment state.

تفاصيل العقد تحسم في Migration 085+.

## 12. ق-89 — Offline Field Operations

ق-89 ينقل Mobile Offline Workflow من «ميزة تحسين»
إلى متطلب MVP تشغيلي للجلسات الميدانية.

المطلوب:

    Durable local DB
        ↓
    Ordered outbox
        ↓
    Background worker
        ↓
    api.*
        ↓
    idempotent business command
        ↓
    reconciliation

## 13. العمليات الإلزامية Offline

الدورة الميدانية الأولى:

- بدء جلسة.
- Pause.
- Resume.
- تغيير مصدر الطاقة.
- إنهاء الجلسة.
- دفعة الجلسة عند استخدامها.
- إنشاء المزارع/الأرض inline عندما يحتاج Start Session.

الإداريات الأخرى تناقش كل شاشة على حدة ولا تصبح
Offline تلقائيًا من ق-89.

## 14. Background execution

Network recovery لا يعتمد على فتح Flutter UI.

Android scheduler الدائم هو المسؤول عن Wake/Retry
عندما يسمح النظام.

لا يعتمد النظام على Manifest CONNECTIVITY_ACTION
بوصفه آلية تشغيل أساسية.

## 15. Reboot and process death

Outbox والـActive Local Session تبقيان بعد:

- إغلاق التطبيق.
- قتل process.
- إعادة تشغيل الهاتف.

بعد Reboot يعاد جدولة Sync وفق إمكانات النظام.

## 16. Conflict is a state

`sync.sync_conflicts` foundation لا تكفي وحدها.

Flutter يحتاج Conflict State وUX واضحًا.

لا يحذف Pending operation عند التعارض.

## 17. Pricing and time

Offline event timestamps جزء من Command.

Historical pricing يجب أن يستخدم event occurrence time.

Time integrity metadata تحفظ محليًا، وأي انحراف مشبوه
يظهر للمراجعة بدل تعديل المال بصمت.

## 18. Android source

التفاصيل الحاكمة للطبقة الهاتفية:

`technical/ANDROID_OFFLINE_BACKGROUND_SYNC.md`

## 19. ق-90 — Sync UX states

الحالات التي يحتاجها Flutter:

- local_only.
- pending.
- syncing.
- synced.
- failed.
- conflict.

هذه حالات مزامنة وليست حالات أعمال بديلة للجلسة.

مثال:

جلسة يمكن أن تكون:

    business status = running
    sync status = pending

ولا تخلط الحالتان في عمود واحد.

## 20. Retry classification

يجب تصنيف الخطأ قبل إعادة المحاولة.

### Retryable

- network unavailable.
- timeout.
- temporary server unavailable.
- transport interruption.

### Review required

- duplicate ambiguity.
- authorization conflict.
- historical pricing ambiguity.
- impossible session transition.
- time integrity conflict.
- canonical mapping ambiguity.

Review required لا يدخل Retry Loop غير محدود.

## 21. Manual Sync

Manual Sync:

- يوقظ/يجدول المزامنة.
- لا يتجاوز Dependency Graph.
- لا يغير Command IDs.
- لا يكرر أوامر ناجحة.
- لا يتجاوز Conflict دون قرار.

## 22. Readiness does not change business history

تغيير إعداد Android لا يغير:

- وقت حدث سابق.
- Command ID.
- ترتيب الأحداث.
- السعر التاريخي.
- هوية الجلسة.

Device Readiness حالة جهاز، وليست مصدر حقيقة للأعمال.

## 23. UX source

تفاصيل واجهة الحالة:

`design/UX_UI_SPEC.md` / UX-10.

تفاصيل Android:

`technical/ANDROID_OFFLINE_BACKGROUND_SYNC.md`.

## 24. ق-91 — Active Session Event Ordering

داخل Session Aggregate يكون الترتيب إلزاميًا.

مثال:

    START
    PAUSE
    RESUME
    CHANGE_ENERGY
    PAYMENT
    COMPLETE

لا يرسل حدث تابع قبل حسم Dependency السابقة.

Resume With New Energy يمثل Command ذريًا واحدًا
منطقيًا، لا Resume ثم Change منفصلين إذا كان الفصل
سينشئ وقت تشغيل وهميًا.

## 25. Local Payment Visibility

إذا استلم المشغل دفعة Offline وحفظت Durable:

- يمكن عرضها في Active Session.
- تحمل Pending Sync.
- لا تصبح Server Posted حتى ACK.
- Retry يستخدم Command ID نفسه.

## 26. Complete While Pending

يمكن أن تصبح الجلسة:

    business_state = completed
    sync_state = pending

هذا صحيح.

لا يعاد فتح الجلسة محليًا لمجرد أن Server ACK لم يصل.

إذا ظهر Conflict عند Sync:

- تبقى البيانات المحلية محفوظة.
- تنتقل إلى Review.
- لا يخترع Flutter تسوية نهائية.

## 27. Active Session Recovery

عند إعادة تشغيل التطبيق أو الجهاز يعاد تطبيق Event Journal
بالترتيب لإعادة:

- Running/Paused/Completed.
- current source.
- billable elapsed base.
- local payments.
- pending commands.

لا يعتمد Recovery على Timer state في الذاكرة.

## 28. ق-92 — Completion to Settlement Ordering

الجلسة التي انتهت Offline يمكن أن تكون:

    business_state = completed
    settlement_state = pending

التدفق لا يعيد فتح الجلسة.

قبل Settlement يجب حسم Commands الأقدم التابعة لنفس
الجلسة، خصوصًا Payments.

## 29. Settlement Retry

Settlement لها Stable Command ID.

Retry لا يكرر:

- complete effect.
- invoice.
- allocation.
- journal effect.
- notification business event.

إذا كان الخادم قد أكمل العملية، يعيد Canonical Result.

## 30. Settlement Conflict

إذا كانت Dependency سابقة مثل Payment في Conflict:

- لا تحذف.
- لا تتجاهل.
- لا تعتبر الفاتورة «غير مدفوعة» نهائيًا بصمت.

Settlement تصبح Review/Conflict حتى الحسم المناسب.

المصدر التفصيلي:

`technical/SESSION_SETTLEMENT_ARCHITECTURE.md`.

## ق-98 — Bookings, Shifts and Operational Records

### Offline Booking

حفظ طلب الحجز محليًا مسموح.

لكن:

    local saved
        !=
    server confirmed

يظل المستخدم يرى «بانتظار تأكيد الموعد» حتى Server ACK.

### Booking conflict

إذا رفض الخادم المورد/الوقت عند Replay:

- لا يحذف الطلب المحلي.
- لا يضع Confirmed كاذبة.
- ينتقل إلى Conflict/Review.
- يسمح بإعادة الجدولة.

### Shift/Transfer replay

المناوبة ونقل مسؤولية الجلسة يحتاجان:

- Stable Command ID.
- ordered per-well/per-session replay.
- idempotent server acceptance.
- no duplicate transfer.
- no duplicate shift.
- no orphan active session.

### Historical records

Sync لا يحذف Display Context لسجل قديم لمجرد أن
Farmer/Farm/Operator أصبح Inactive.

## ق-99 — Financial Offline and Reconciliation

### Payment

Local Payment Command قد يكون:

- saved locally.
- pending.
- syncing.
- reconciled.
- conflict/review.

لا يوصف Posted Canonical قبل ACK.

### Duplicate protection

Payment Command يحتاج Stable Command ID.

Retry بعد Lost Response يجب أن يعيد نفس النتيجة
Canonical لا Payment ثانية.

### Unknown delivery

إذا لم يعرف التطبيق هل وصل الأمر:

    unknown delivery

فالخطوة التالية:

    reconcile

وليست:

    submit another payment

ولا:

    reverse immediately

### Expenses

المصروف يمكن أن يحفظ Local عند السياسة المسموحة.

لكن:

- approval finality خادمية.
- posting finality خادمية.
- skipped attachment reason يحفظ ضمن الحدث/الأمر.

### Distribution and periods

الأفعال النهائية التالية Online only:

- distribution calculation.
- distribution approval.
- partner payout.
- period close/reopen final action.
- posted financial correction.

يمكن عرض Cached State Offline مع بيان Last Sync.

## ق-100 — Well/Fuel/Report Offline Rules

### Well/Pump configuration

الإعدادات الإدارية الحساسة ليست Offline-first تلقائيًا.

إذا كان التغيير قد يؤثر على Active Operation:

يحتاج Canonical Server validation.

### Fuel

الحركات الميدانية المسموحة Offline تتبع:

- local durable.
- Outbox.
- Stable Command ID.
- retry-safe acceptance.

Physical Count/Adjustment يحتاجان Reconciliation واضحًا.

### Pricing

Trusted cached Price Snapshot يمكن استخدامها وفق
القواعد السابقة.

عدم وجود Trusted Snapshot:

    Pricing Pending

### Reports

Cached Report يجب أن يحمل:

- period.
- generated/as-of time.
- last sync metadata.

### Charts

Chart Cached لا توصف Live.

Chart Data يعاد رسمها من Canonical Cached Report Series
ولا يعاد حساب Business Total بصورة منفصلة.

## ق-101 — Account-scoped Local State

Local durable state يجب أن تربط كل Private Record بـ:

- authenticated account identity.
- well context عند انطباقه.
- command identity.

Logout:

لا يحذف Pending Outbox.

Login بحساب آخر:

لا يكشف Outbox أو Cache الخاصة بالحساب السابق.

Login بالحساب الأصلي:

يعيد ربط Pending State المسموحة بالحساب ثم يستأنف
Reconciliation.

Local Data Wipe لا يسمح بصمت إذا توجد Unacknowledged
Commands.

## ق-102 — Platform Sync Observability

Platform Dashboard يمكنها مراقبة Server-visible Sync State:

- pending acknowledged by server.
- failed server applications.
- conflicts.
- reconciliation states.
- device/app metadata التي وصلت للخادم.

لكن:

عملية محفوظة فقط على جهاز Offline ولم ترسل أي Telemetry
لا يمكن للServer Dashboard معرفتها فورًا.

Realtime Admin UI تستخدم:

- server events/invalidation.
- canonical aggregate refresh.
- fallback refresh.
- stale timestamp.

لا تنشئ Admin Console Business Sync Engine موازية.

## ق-103 — Password Secrets Never Enter Sync

Recoverable Password Vault خارج Offline/Sync Data Plane.

Password plaintext لا تدخل:

- Local Durable DB.
- Outbox.
- WorkManager payload.
- Cached API responses.
- generic retry queues.
- Offline snapshots.
- analytics.
- support diagnostics.

Password Reveal Online-only.

Password Mutation Online-only.

أي retry لخدمة Password يستخدم Operation ID وEncrypted
Pending Vault Version على Server بدل تخزين plaintext
في Mobile Queue.

إذا Vault state غير مؤكدة:

تظهر `stale` أو `unavailable`.

لا تعرض Password قديمة بوصفها Current.

## ق-105 — Password Recovery Outside Sync

ق-105 تنسخ أي Vault-specific Sync wording من ق-103.

Password plaintext أو Password Reset Secret لا تدخل:

- Offline Database.
- Outbox.
- WorkManager payload.
- Cached Reports.
- Support diagnostics.
- generic sync queue.

Force Password Reset وPassword Recovery:

**Online-only.**

Sync subsystem يمكن أن يعرف فقط Business-safe state مثل:

- account reset required.
- session revoked.

ولا يحمل Password نفسها.

No Recoverable Password Vault exists.

## ق-106 — Platform Admin Privileged Writes Are Online-only

PA-03 privileged commands do not enter Mobile/Offline Outbox.

Includes:

- sale.
- entitlement grant.
- entitlement revoke.
- activation correction.
- administrative session closure.
- financial correction.
- accounting-period admin decision.

Retry safety is Server-side through Stable Operation ID.

If connection fails after submission:

Admin Console reconciles by Operation ID before creating
another command.

Monitoring only reports Server-observable Sync Truth.

No recent server update does not automatically mean
field operation failed.

Cached Admin Reads must show Last Update/Stale state.

## ق-107 — Monitoring/Maintenance Interaction with Offline Sync

Platform Monitoring ترى Server-observable Truth فقط.

Maintenance لا تلغي Offline architecture.

إذا كانت العملية Offline-safe حسب ق-89/ق-90:

- يمكن حفظها محليًا.
- تبقى في Outbox.
- تنتظر عودة Server capability.

Online-only operations:

تعرض Maintenance reason/state بوضوح.

Required App Update لا يسمح بأن يمحو أو يحجب
Local Pending Business Data.

Version/maintenance state يجب أن تدخل Reconciliation
بطريقة لا تسبب loss أو duplicate commands.

Technical monitoring لا يدعي معرفة command لم تصل
إلى الخادم.

## ق-108 — Canonical User-facing Sync Semantics

Cross-cutting UI terminology must map consistently to actual
sync state.

### Local durable

The operation is safely stored locally.

User message:

    محفوظ على الجهاز

### Pending

Local operation is not yet server-confirmed.

User message:

    بانتظار المزامنة

### Confirmed

Server accepted/reconciled operation.

User message:

    تمت المزامنة

### Needs review

Server/client reconciliation requires attention.

User message:

    يحتاج مراجعة

### Failed

Known attempt cannot currently succeed without retry/action.

Use understandable explanation.

### Connectivity

`offline` describes connectivity/readiness.

It does not equal `pending`, `failed` or `conflict`.

### UI stability

Short connectivity transitions should not cause repeated
page reflow/banner bouncing.

### Critical record state

Where business impact matters, state can be attached to the
specific Session/Booking/Payment/Command rather than only a
global icon.

### Local reads

Valid local data remains visible during background refresh.

### Pending preservation

Back navigation/logout/context changes cannot silently
destroy pending critical operations.

## ق-109 — Offline Foundation Is W2

Offline/Background Sync implementation is not postponed
until after UI completion.

W2 must establish:

- durable local state.
- Outbox.
- stable operation identity.
- retry.
- reconciliation.
- WorkManager/background execution.
- user-visible canonical sync states.

Critical field features in W4+ build on this foundation.

This ordering prevents UI from being designed around
always-online assumptions that contradict ق-89/ق-90.

## ق-129 — حزمة المزامنة الميدانية والتخزين الدائم (W2-02d / ق-129)

**التاريخ:** 2026-09-16
**الحالة:** مُنجز ومُثبت؛ القبول الميداني مُجتاز بالكامل على الجهاز الحقيقي (Samsung Galaxy A13) وفق 42 بند قبول (42/42 PASS)، وق-129 وم-43 مُغلقتان نهائيًا.

1. **طابور المقدمة الدائم (Durable Foreground Outbox):**
   - استُبدل طابور الذاكرة المؤقتة بالكامل بـ `SqliteOutboxStore` المشترك مع العامل الخلفي عبر مسار ملف قاعدة بيانات موحد (`resolveOutboxDatabasePath`).
   - لا عودة للذاكرة (RAM-only) في الأوامر الميدانية الجديدة؛ وفشل الكتابة الدائمة يُفشل العملية فورًا ولا يخفي العطب.
2. **مراجع الأوامر الخادمية الموحدة (Canonical Command References):**
   - أمر البدء `start_irrigation_session` يحل مرجع جلسته إلى معرّف الجلسة الخادمي الرسمي (Canonical Session ID).
   - كافة الأوامر الميدانية اللاحقة للجلسة (Pause, Resume, Change Energy, Complete) تستند إلى المعرّف الخادمي الرسمي.
3. **الإسقاط الدقيق للجلسة (Exact-Session Projection):**
   - يعمل مسقط الجلسة حصريًا على معرّف الجلسة المطابق، مانعًا أي تداخل أو استعارة بيانات بين الآبار (Prevent cross-well fallback).
4. **صدق المزامنة (ACK Truth):**
   - لا تُعرض شارة «مزامن» إلا بعد استلام ACK خادمي صريح؛ فشل النقل يبقي الأمر بحالة `pending` بنفس المعرّف الثابت `p_command_id`.
   - الطابور الفارغ أو الذي تفرغه مزامنة أخرى متزامنة يعرض حالة محايدة بلا ادعاء كاذب.
5. **سلسلة الإنهاء والسداد المنفصل:**
   - التسلسل المعتمد:
     `START → الأحداث (Pause / Resume / Change Energy) → COMPLETE → السداد الاختياري`
   - أمر الإكمال `complete_irrigation_session` ينتج ربط مرجع الرسوم `sessionCharge`، وعملية السداد الاختيارية التالية تشير صراحة إلى هذا المرجع.

[DOC-RECOVERY-Q133-2026-10-03]
---

## ق-133 — توافق أوامر السقي الحر مع Offline / Outbox (2026-10-03)

**قرار UX/عقد:** ق-133 مع الحفاظ على ق-89 وق-114/115 وثوابت 759–760. لا تنسب حالة الجلسة «مؤكدة خادميًا» إلى مشروع محلي قبل رد الخادم.

**فحص فعلي للكود بتقرير الوكيل:** الإنتاج يسير عبر `operations_screen → OfflineSessionCoordinator.startSession → OutboxRepository.enqueue → SqliteOutboxStore → SyncEngine → SupabaseCommandTransport`. يُولَّد `command_id` مرة واحدة عند enqueue ويحفظ مع JSON قبل الإرسال. الحالات الموجودة: `pending/dispatching/confirmed/review`. الرفض غير العابر يذهب إلى `review`، وتمنع التبعيات من العبور قبل حل مرجع البدء.

**تغيير محلي مُختبر:** نوع `startAdhocSession` يرسل إلى `api.start_adhoc_session` مع `p_planned_duration_minutes` عندما يمرر المنسق مدة صريحة؛ غياب المدة يحتفظ **بالنوع والحمولة القديمين** وبالعقد `api.start_irrigation_session`. `active_session_projector` يدعم النوعين. 12 اختبار انحدار جديد لحمولة الأمر والتخزين وإعادة فتح SQLite وإعادة المحاولة وتبعيات الرفض؛ تقرير الوكيل: `flutter test` 667/667 و`flutter analyze` 0 issues؛ لا تغيير مخطط SQLite (`schemaVersion=1`) لأن الحقل في JSON.

**معلومات غير متاحة للعميل حاليًا:** لا توجد قراءة حجوزات ولا cache للحجوزات في `apps/mobile/lib` وفق التدقيق؛ لا يُفسر غيابها على أنه عدم وجود حجز. شاشة العمليات تعرض الإسقاط المحلي للجلسة دون توضيح `review/pending` بقدر كافٍ؛ تصميم عرض الحالة لا يزال يتطلب موافقة المالك.

**استعادة الأوامر:** إعادة نفس `command_id` والحمولة تعيد الاستجابة المعتمدة إن سبق تنفيذ الأمر. رفض القيد المؤجل `23514` يرجع المعاملة فلا يُثبت أمرًا مستهلكًا، وينتقل القديم محليًا إلى `review` دون حذف أو حلقة إعادة. **لا تُعدَّل حمولة أمر قديم بنفس المعرف؛ ولا يُخلق أمر بديل أو mapping جديد تلقائيًا** حتى مراجعة التوقيت والتوابع والقرار البشري.

**مخاطر مفتوحة:** قراءة إصدار تطبيق أقدم لنوع الأمر الجديد قد ترمي `StateError` (Downgrade غير آمن)؛ لا `reason_code` خادميًا متخصصًا لرفض المدة؛ `p_started_at` قادم من الهاتف بعقد ثقة تاريخي غير محسوم؛ حارس التداخل العكسي والتزامن باتصالين Pending؛ توافق الواجهة ونشر العميل والخادم معًا Pending. لا يوصف تنفيذ منطق الأوامر بأنه تنفيذ واجهات Flutter أو قبول جهاز فعلي.

**تصحيح بصمة البدء الحرّ (PR #47، مدموج):** أُضيف `fuel_owner_person_id` إلى بصمة `sync.begin_adhoc_session_command`؛ لا تكفي مساواة `command_id` وبقية الحقول إذا تغيّر مالك الوقود. إعادة حمولة مطابقة تعيد النتيجة السابقة، أما تغيّر المالك فيُرفض دون جلسة إضافية. لا تعديل لأوامر Outbox القديمة أو شاشة التطبيق. أثبت GitHub Actions #33 نجاح فحص قاعدة البيانات (`1071 PASS`) الذي يشمل EE11b/EE11c. كان فحص مطابقة الفهرس في #33 يفشل لسطر التوقيع الجديد؛ حُفظ السطر المولّد حرفيًا، ثم اجتاز GitHub Actions #34 فحص المطابقة و`c:db` (`1071 PASS`) و`c:app` (`667 PASS`). **الدمج حدث**: PR #47 merged (merge commit `e1d2c689`) وGitHub Actions #36 على `main` = SUCCESS (`1071 DB PASS`، `667 Flutter PASS`، فهرس مطابق). **النشر لم يحدث**: `Deploy to production` عُطّل قبل الدمج، وM113 غير موجودة في سجل migrations السحابي بعد الدمج — فCloud/Production Pending.

---

## ق-134 — سلامة انتقالات الحجوزات بين الخادم وهاتف التشغيل (Adopted / Pending)

- **V1:** مشغّل واحد وهاتف تشغيل واحد للبئر، مع عدم السماح لهاتف أو للمُشغّل الخادمي بكتابة انتقالين متعارضين. لا تكفي حالة متصل أو آخر مزامنة للتحكم المباشر من المالك؛ يجب استجابة هاتف التشغيل وإثبات خلوه من أوامر عالقة أو نسخ قرار أقدم.
- **العمل دون اتصال:** تستمر الأوامر المحلية من بيانات مؤكدة كاملة وبقدر إذن Android؛ `pending` ليس `accepted`، ولا تُسجل بدايات بأثر رجعي. عند الاستيقاظ بعد فوات غير منفذ تُعرض مراجعة جماعية، وتبقى الأوامر الأصلية وأسباب التصحيح. المزامنة آليًا عند الاتصال حيث تسمح المنصة، وForce Stop قد يمنعها حتى فتح التطبيق.
- **التحكم عن بُعد:** أمر المالك أثناء الانقطاع طلب مؤجل فقط؛ بعد العودة لا ينفذ إلا مع إعادة فحص الحالة. تصحيح التاريخ المستقر منفصل عن التحكم الحي ويمكن قبوله خادميًا؛ التعارض المالي/التاريخي للمراجعة والحسم لا «آخر كاتب يفوز».
- **حد النطاق:** هذه قواعد معتمدة ولم تُنفذ بعد؛ لا تعدّل سير Outbox القديم قبل اختبارات التوافق والإيديمبوتنس. التفاصيل وخطة التنفيذ في `BOOKING_AUTOMATION_IMPLEMENTATION_PLAN.md` P4/P5/P7.

## ق-134 / P1-A — دفتر أمر ضبط وضع الانتقال

**الحالة:** Local DB Verified + PR CI Verified + Merged عبر PR #51 (`f63e9c2`)؛ نجاح `main` بحسب تأكيد المالك دون run مستقل؛ Cloud/Production Pending. P1-A-MERGED-PR51-2026-10-04.

يمر `api.set_well_booking_automation` إلى `ops.set_well_booking_automation` المحروسة، التي تقرن بصمة الحمولة بمعرف الأمر ضمن `sync.begin_command`، وتتحقق من التطابق عند التكرار، ثم تقارن `booking_auto_transition_revision` تحت `FOR UPDATE` وتثبّت الرد عبر `sync.finish_command` في المعاملة نفسها. إعادة الحمولة نفسها تعيد الرد السابق دون إعادة كتابة؛ تغيير الحمولة بالمعرف نفسه يُرفض؛ مراجعة قديمة تُرفض دون حفظ أمر مقبول. الاختبارات PA دائمة ضمن اختبار M113.

**حدود مهمة:** حفظ ON لا يعني حدوث انتقال ولا جدولة هاتفية/خادمية. `automation_executor_ready=false`. P1-A دُمجت عبر PR #51 وسجل دمجها مدمج عبر PR #52.

## ق-134 / P1-B — دفتر أمر نواة الانتقال الذرية وإثبات التزامن

**الحالة:** Local DB Verified (`FILES=52 PASS=1119` وفهرس `891/544/265/49`) + Concurrency Proof Verified على الفرع `feat/p1b-atomic-transition`؛ لا CI/Cloud/Production مثبت لهذا التعديل. P1-B-CONCURRENCY-PROOF-VERIFIED-2026-10-04.

تنفذ النواة `ops.execute_booking_transition` دورة أمر موحدة عبر `sync.begin_command` و`sync.finish_command` بالنوع `execute_booking_transition` مع حمولة `{booking_execution_contract_version: 113, well_id, expected_revision}`:
1. **منع التنفيذ المزدوج:** ثبت بالسيناريو أ لـ `scripts/p1b_transition_concurrency_proof.py` (سباق أمرين مختلفين باتصالين مستقلين): حجب الاتصال الثاني على أقفال الأول (`settings → session → chain → booking → pump`)، ثم بعد إيداع الأول يستأنف الثاني ويُرفض رفضًا نظيفًا (`current_not_reached_operational_end`) لأن الحالة تغيرت تحته دون تنفيذ مزدوج أو رسوم مكررة أو جلسة ثانية، وبدفتر أوامر نظيف (أمر واحد مقبول وصفر أسطر للأمر الثاني المرفوض).
2. **الإيديمبوتنس (Idempotency) لنفس command_id:** ثبت بالسيناريو ب لسكربت التزامن: اتصالان بنفس المعرف، الثاني يتحجب على قيد فريدية سجل الأمر، ثم بعد إيداع الأول يعيد الرد المخزن نفسه حرفيًا وسجل أمر واحد في `sync.processed_commands`.
3. **الحدود:** النواة غير مفعلة إنتاجيًا ومسحوبة الصلاحيات (`REVOKE ALL FROM public, anon, authenticated, service_role`) وبلا أي كشف في `api`، ولا استدعاء من تطبيق الهاتف أو المجدول بعد. لا يوجد قرار جديد مطلوب (ق-134 كافٍ ومحكم).
