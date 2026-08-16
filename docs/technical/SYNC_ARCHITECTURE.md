# Offline and Synchronization Architecture

**آخر تحديث:** 2026-08-17
**القرار الحاكم:** ق-75
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
