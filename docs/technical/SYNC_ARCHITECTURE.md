# Offline and Synchronization Architecture

**آخر تحديث:** 2026-08-18
**القرارات الحاكمة:** ق-75، ق-89
**الحالة:** الخادم منفذ جزئيًا؛ طبقة الهاتف ضمن Stage 7

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

وجود `sync.begin_command/finish_command` هو البنية الخادمة،
لكن دمجه مع جميع RPC داخل Flutter لم يُعتبر منجزًا بعد.

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
