# Application API Architecture

**آخر تحديث:** 2026-08-18
**القرارات الحاكمة:** ق-78، ق-79، ق-82
**الحالة:** منفذة ومثبتة محليًا

## 1. الحد الرسمي لتطبيق Flutter

المسار المعتمد:

    Flutter
       |
       v
    Supabase Data API
       |
       v
    api.*
       |
       v
    Approved internal business procedures
       |
       v
    Internal business tables

Flutter لا يستدعي جداول أو دوال مخططات الأعمال الداخلية
مباشرة عبر Supabase Data API.

## 2. Exposed Schemas

المكشوف:

- `api`
- `graphql_public`

غير المكشوف كتطبيق أعمال:

- `core`
- `iam`
- `ops`
- `billing`
- `finance`
- `inventory`
- `audit`
- `sync`
- `reporting`
- `public`

## 3. الكتابة

`anon` و`authenticated` لا يملكان Direct DML على
جداول مخططات الأعمال الداخلية.

عمليات Flutter الكتابية تمر عبر RPC داخل `api`.

## 4. Security model

كل دوال `api` الحالية:

- SECURITY INVOKER.
- منحها Opt-in.
- لا EXECUTE لـ`anon`.
- تستدعي إجراءات الأعمال الداخلية بدل تكرار منطقها.

الإجراءات الداخلية التي تحتاج صلاحيات أعلى قد تكون
SECURITY DEFINER، لكن يجب أن:

- تضبط `search_path` صراحة.
- تتحقق من `auth.uid()`.
- تتحقق من دور البئر أو التفويض المطلوب.
- لا تعتمد على معرف منفذ يرسله العميل وحده.

## 5. هوية منفذ العملية

عندما يمكن اشتقاق المنفذ من جلسة المصادقة:

Flutter لا يرسل `actor_profile_id` أو `created_by`
بوصفه مصدر ثقة.

غلاف `api` يستخدم `auth.uid()`.

## 6. السطح الحالي

السطح المثبت بعد ق-82 / 077:

- health.
- 31 عملية أعمال.
- `app_bootstrap` بوصفه أول عقد قراءة.
- الإجمالي = 33 RPC.

يغطي التدفقات الحرجة للـMVP مثل:

- الجلسات.
- الفاتورة.
- الدفع.
- المزارع.
- الحجوزات.
- الوقود.
- إنشاء الجهة والبئر.
- المصروفات.
- المناوبات والتسليم.
- نقل الجلسة.
- الإقفال.
- توزيع الأرباح.
- الرواتب الأساسية.

## 7. العمليات المؤجلة عمدًا

عدم وجود RPC لا يعني السماح بالكتابة المباشرة.

من الأمثلة الحالية:

- `create_farm`: أضيف واعتمد في 075 بعد حسم م-22.
- عمليات الدمج الإداري.
- عكس العمليات المالية الاستثنائي.
- الأرصدة الافتتاحية.
- دورة إعادة فتح الفترة الاستثنائية.

## 8. قاعدة أي شاشة Flutter جديدة

إذا احتاجت الشاشة كتابة ولا توجد RPC معتمدة داخل `api`:

1. لا تستخدم جدولًا داخليًا.
2. لا تكشف schema داخليًا.
3. لا تمنح Direct DML.
4. أضف Migration جديدة لعقد `api`.
5. أضف اختبار قبول دائم.
6. وثق العملية قبل ربط الشاشة بها.

## 9. baseline الأمني المثبت

2026-08-17:

- Direct DML = 0.
- API SECURITY DEFINER = 0.
- anon API EXECUTE = 0.
- authenticated API EXECUTE = 33.
- service_role API EXECUTE = 33.
- Data API RPC = 33.
- المخططات الداخلية غير مكشوفة.

## ق-80 / 075 — منفذ ومثبت

`api.create_farm(uuid,text,uuid)` منفذ ومثبت في 075 بعد حسم م-22.

المعامل الثالث هو `p_farmer_well_account_id`.

نجح التحقق وارتفع السطح المثبت إلى 32 RPC.

الـbaseline الحالي المثبت هو 32 RPC.

### ق-81 / 076 وData API

ق-81 / 076 لم تضف Pump management RPC.

Surface الحالي يبقى:

`Data API RPC = 32`.

إضافة عمليات إنشاء/تعديل/إحالة المضخة للشاشة المستقبلية يجب أن
تتبع ق-78/ق-79 عبر `api.*` SECURITY INVOKER، ولا يجوز Direct DML.


## ق-82 / 077 — عقد القراءة الأولي

أضيف:

`api.app_bootstrap()`

بوصفه أول Read Contract رسمي لتطبيق Stage 7.

الغرض منه أن يحصل التطبيق بعد المصادقة على:

- ملف المستخدم الأساسي.
- قائمة الآبار المتاحة.
- الأدوار الفعالة لكل بئر.

مصدر الدور التشغيلي الحالي هو `core.well_assignments`
مع دعم وصول الشريك الحالي من `core.well_partners`.

لا يستخدم العقد كتالوج `iam.roles` بوصفه مصدر تفويض،
لأن م-18 ما زالت مفتوحة.

الدالة SECURITY INVOKER، وanon محجوب عنها، ولا تضيف
أي جدول أو View إلى مخطط `api`.

الـbaseline المثبت بعد 077:

`Data API RPC = 33`.

## 10. ق-88 — عقود البحث الذكي

ق-88 لا يغير حد Data API.

المسار يبقى:

    Flutter
        ↓
    Data API
        ↓
    api search/read contract
        ↓
    internal data

المطلوب في Migration 078+ حسب الحاجة:

- عقود Search محددة النوع.
- لا Dynamic table/schema parameter.
- SECURITY INVOKER.
- anon محجوب.
- auth scope مشتق من الجلسة.
- result limits/pagination.
- deterministic ranking.
- عدم كشف بيانات من آبار غير مسموحة.
- permanent tests للمنح والنتائج.

`api.app_bootstrap()` وحده لا يغطي هذه المتطلبات.

## 11. ق-88 — فجوات الكتابة المرتبطة بـUX-08

### Create Farmer

العقد موجود ويجب إعادة استخدامه.

### Create Farm

العقد موجود، لكن Business Procedure الحالية owner-only.

UX-08 يسمح للمشغل بإضافة أرض.

لا يغير Flutter هذا القيد مباشرة.

يلزم Migration 078+ لتوسيع التفويض واختباره إذا بقي
UX المعتمد كما هو.

### Start Session + Advance Payment

العقدان الحاليان منفصلان:

- start irrigation session.
- record payment.

قبل تمكين «مبلغ مدفوع الآن» في شاشة بدء الجلسة يجب
إنشاء orchestration آمن أو protocol idempotent مكافئ
يمنع partial success والتكرار.

## 12. قاعدة إغلاق شاشة تعتمد على ق-88

لا تعتبر شاشة Flutter مكتملة إذا كانت تحتاج Search/Create
Contract غير موجود داخل `api`.

التوثيق لا يبرر Direct DML مؤقتًا.

## 13. ق-89 — Offline Commands

Offline لا يغير API Boundary.

المسار:

    Local Outbox
        ↓
    Background Sync Worker
        ↓
    api.*
        ↓
    approved business procedure

العقود التي ستستخدم Offline تحتاج:

- stable command id.
- idempotent replay.
- original occurred_at.
- deterministic result on retry.
- authorization revalidation.
- audit.
- no anon execute.
- no Direct DML.

قد تنفذ هذه المتطلبات عبر typed wrappers جديدة أو
توسعة العقود الحالية في Migration 078+.

لا ينشأ Generic RPC يسمح للعميل بتنفيذ اسم دالة أو
جدول ديناميكي.

## 14. ق-89 — Offline Session Start Gap

العقد الحالي لبدء الجلسة لم يعتبر بعد Offline-idempotent
من جهة الهاتف.

قبل الإنتاج يجب حسم:

- client/server session identity.
- command id.
- historical pricing.
- dependency mapping للمزارع/الأرض الجديدة.
- payment coordination.
- retry after lost response.

التفاصيل في:

`technical/ANDROID_OFFLINE_BACKGROUND_SYNC.md`

## 15. ق-90 — Sync Status and Readiness Boundary

معظم Device Readiness محلي داخل Android.

لا ينشأ Backend API لقراءة إعدادات بطارية أو Permission
خاصة بالهاتف.

إذا احتاج UX-10 بيانات خادمية، مثل:

- server acknowledgement.
- canonical conflict result.
- reconciliation result.
- server-side last accepted command.

فتقرأ عبر typed `api.*` Read Contract عند الحاجة.

القواعد تبقى:

- SECURITY INVOKER.
- anon محجوب.
- least privilege.
- no internal schema exposure.
- no Direct DML.
- permanent acceptance test عند إضافة Contract جديد.

Local pending count يبقى مشتقًا من Local Outbox ولا يحتاج
نسخه إلى جدول خادمي فقط لأجل العرض.

## 16. ق-91 — Active Session Contracts

UX-11 يحتاج Active Session Read Model موحدًا.

Flutter لا يجمع:

- irrigation_sessions.
- session_segments.
- payments.
- pricing.

مباشرة من schemas الداخلية.

إذا العقود الحالية لا تكفي، يضاف Typed Read Contract
داخل `api.*`.

يجب أن يوفر فقط ما يحتاجه المستخدم وفق صلاحياته.

### Write gaps

العقود الحالية يعاد استخدامها متى كانت مطابقة للقرار.

الفجوات التي تحتاج Migration 078+ حسب الفحص:

- Pause Detail Reason.
- Resume With New Energy.
- Offline-idempotent wrappers.
- Active payment coordination.
- Fuel Billing correction وفق ق-17.

### Financial contract

لا يجوز لعقد API جديد إرجاع Farmer Accrued Amount
يتضمن Fuel Charge منفصلًا يخالف ق-17.

Live/Complete/Invoice contracts يجب أن تتفق على نفس
المبلغ والسياسة.

### Security

كل عقد جديد:

- typed.
- SECURITY INVOKER عند Read Contract المناسب.
- write عبر Business Procedure موثوقة.
- anon blocked.
- no Direct DML.
- deterministic authorization.
- permanent tests.

## 17. ق-92 — Session Settlement Contract

Backend الحالي يملك إجراءات منفصلة لإكمال الجلسة،
إصدار الفاتورة، وتسجيل/تخصيص الدفعات.

UX-12 يحتاج Orchestration آمنًا فوق هذه المكونات.

العقد النهائي يجب أن يضمن:

- stable settlement command id.
- idempotent retry.
- one canonical final charge.
- one active invoice.
- one-time session-payment allocation.
- excess remains advance.
- final settlement summary.
- conflict result بدل partial silent success.

Flutter لا يستدعي سلسلة عمليات مالية مستقلة بطريقة
تسمح بنجاح بعضها وفشل بعضها دون Reconciliation.

يمكن التنفيذ عبر:

- Atomic RPC واحدة.
- أو Idempotent orchestration protocol بضمانات مكافئة.

الضمان هو الملزم، لا اسم الدالة.

كل عقد جديد يبقى:

- تحت `api.*`.
- anon blocked.
- no Direct DML.
- least privilege.
- permanent acceptance tests.

## ق-98 — Operations Records and Booking Contracts

UX-13 يحتاج Typed Contracts إضافية داخل `api.*`.

المطلوب حسب الحاجة:

- session history read.
- farmer list/detail.
- farm list/detail.
- booking list/detail.
- create/reschedule/cancel booking.
- booking reconciliation result.
- operational handover summary.
- shift/session-transfer retry-safe contracts.

القواعد:

1. Flutter لا يكتب `ops.irrigation_bookings` مباشرة.
2. Flutter لا يكتب `booking_status_history` مباشرة.
3. تأكيد الحجز النهائي خادمي.
4. Booking + history + reservation يجب أن تتسق ذريًا.
5. Shift Close العادي لا يتجاوز Active Session.
6. Cash Handover وOperational Transfer عقدان مختلفان.
7. كل write حساس يحتاج auth-derived actor وصلاحية.
8. أي عقد جديد يبدأ من Migration 078+.

## ق-99 — Money & Partners Read/Write Contracts

UX-14 يعيد استخدام إجراءات المال الحالية ولا ينشئ
Accounting Logic داخل Flutter.

Typed `api.*` المطلوبة حسب الحاجة تشمل:

- farmer financial summary.
- invoices list/detail.
- payments list/detail.
- advances read/allocation.
- expense list/detail.
- partner financial detail.
- profit distribution list/detail/preview.
- accounting period list/detail.
- financial correction/reversal.
- financial audit history.

القواعد:

1. debt وadvance حقلان/مفهومان منفصلان.
2. old advance لا يستهلك بصمت.
3. payment allocation يراجع قبل الإرسال.
4. Canonical receipt يأتي من Backend.
5. `attachment_skip_reason` يجب أن يصل للعقد عند التخطي.
6. Partner projection تطبق Least Privilege.
7. correction لا تستخدم Direct UPDATE.
8. كل Write حساس يشتق Actor من auth.
9. Flutter لا Direct DML.
10. أي تغيير DB جديد يبدأ من 078+.

## ق-100 — Well, Fuel, Pricing and Reporting Contracts

UX-15 تحتاج Typed Contracts داخل `api.*` لـ:

- well summary/update.
- pump list/detail/update.
- fuel summary/history.
- fuel physical count/adjustment.
- pricing read/version.
- report overview.
- irrigation trend.
- financial trend.
- energy breakdown.
- fuel trend.
- pump usage.
- operator usage.
- partner own-profit trend.

القواعد:

1. Flutter لا تقرأ Reporting Internals مباشرة بوصفها
   عقد UI دائمًا.

2. Flutter لا تجمع Raw Tables لصناعة Total Canonical.

3. Report Aggregation خادمية.

4. Chart Series مشتقة من نفس Report Source of Truth.

5. Partner projection Least Privilege.

6. Pump state mutation تتحقق من Active Session.

7. V1 pricing لا تكشف `operation_plus_fuel`.

8. Actor/role يتحقق منه Backend.

9. لا Direct DML.

10. أي DB change جديد يبدأ من Migration 078+.

## ق-101 — Account & Settings Boundary

UX-16A تحتاج Contracts لـ:

- account summary.
- change phone.
- recover identity.
- reset password.
- role assignment lifecycle.
- notification preferences.
- session invalidation.

القواعد:

1. Phone uniqueness تتحقق خادميًا.
2. Role assignment لا ينشئ Person جديدة.
3. Platform Admin APIs ليست جزءًا من هذه العقود.
4. Auth Admin operations الحساسة تستخدم Trusted Backend.
5. Service secrets لا تدخل Flutter.
6. Any DB change يبدأ من Migration 078+.
