# Offline and Synchronization Architecture

**آخر تحديث:** 2026-08-22
**القرارات الحاكمة:** ق-75، ق-89، ق-90، ق-91، ق-92، ق-114
**الحالة:** الخادم منفذ جزئيًا — idempotency الدورة الميدانية
الأولى موصول ومُثبت بق-114؛ طبقة الهاتف ضمن Stage 7

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

- Local outbox.
- Local durable database.
- PowerSync integration.
- retry queue.
- connectivity recovery.
- device registration.
- `iam.user_devices`.
- `audit_logs.device_id`.
- conflict-resolution UX.
- pending/synced/failed indicators.
- إعادة التشغيل بعد إغلاق التطبيق أو نفاد البطارية.

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

Mobile offline workflow: غير منفذ/غير مثبت بعد.

PowerSync: مخطط له في Stage 7، وليس baseline مثبتًا حاليًا.

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

## 11. الدفعة مع بدء الجلسة

إذا نفذت عملية مركبة من بدء الجلسة + دفعة، تصبح
العملية المركبة نفسها وحدة retry منطقية.

لا يسمح أن تؤدي إعادة الإرسال إلى:

- جلستين.
- دفعتين.
- دفع بلا سياق صحيح.
- Session state تختلف عن Payment state.

تفاصيل العقد تحسم في Migration 078+.

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
