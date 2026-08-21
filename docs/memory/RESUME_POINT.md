# نقطة الاستئناف — 2026-08-21

## Stage 7 Readiness Gate

**مغلق بالكامل — 2026-08-17.**

### الشرط 1 — API Architecture
**مغلق.**

### الشرط 2 — RPC-only writes
**مغلق.**

### الشرط 3 — Documentation Conformance
**مغلق.**

### الشرط 4 — Pre-screen structural gaps
**مغلق.**

- 4A / م-22: مغلق بق-80 / 075.
- 4B / م-19: مغلق بق-81 / 076.

### الشرط 5 — Final Clean Acceptance
**مغلق — 2026-08-17.**

## Final verified baseline

- migrations = 76.
- permanent test files = 17.
- PASS = 217.
- FAIL = 0.
- ERROR = 0.
- Data API RPC = 33.
- Direct DML = 0.
- API SECURITY DEFINER = 0.
- anon API EXECUTE = 0.
- authenticated API EXECUTE = 33.
- service_role API EXECUTE = 33.
- exposed schemas = `api`, `graphql_public`.
- `public` and internal business schemas are not exposed.

## القرارات الأخيرة

- ق-77: whole YER / no financial rounding.
- ق-78: dedicated application API boundary.
- ق-79: RPC-only writes.
- ق-80: Farm → Farmer Well Account.
- ق-81: Pump equipment model / session energy source / concurrency authority.
- ق-82: App Bootstrap Read Contract للمستخدم والآبار والأدوار.
- ق-83: الهوية البصرية العامة وثوابت تصميم Stage 7.
- ق-84: هوية موحدة؛ رقم هاتف واحد = شخص واحد = حساب واحد،
  مع جمع جميع الأدوار و«بياناتي كمزارع».
- ق-85: السوبر أدمن سلطة إدارية عليا على مستوى المنصة.
- ق-86: كل شراء يدوي يمنح حق تفعيل بئر واحد؛ التحقق
  تلقائي وخادمي، ومشاركة APK لا تمنح حق إنشاء بئر.
- ق-87: التوجيه بعد الدخول حسب الدور؛ المالك إلى الرئيسية،
  المشغل فقط إلى التشغيل، والشريك فقط إلى صفحته.
- ق-88: Smart Lookup موحد لكل حقول اختيار الكيانات،
  مع Prefix من حرفين وFuzzy من ثلاثة أحرف، وإعادة استخدام
  التطبيع الحالي ومنع التكرار في UX/API/Database.
- ق-88: بيانات الكيان تحفظ مرة واحدة ويعاد استخدامها بالـUUID؛
  نص البحث لا ينشئ سجلًا تلقائيًا.
- ق-88: المستحق حتى الآن يتحدث مع عداد الجلسة عند وجود
  تسعير زمني قابل للحساب؛ Backend هو المرجع النهائي.
- ق-89: بدء الجلسة ودورة التشغيل الميدانية الحرجة تعمل
  Offline وتدخل Outbox محليًا دائمًا.
- ق-89: عند عودة الاتصال تبدأ المزامنة الخلفية في أقرب
  فرصة يسمح بها Android دون اشتراط فتح واجهة التطبيق.
- ق-89: Force Stop/Restricted Mode حدود منصة يجب شرحها،
  وDevice Readiness جزء إلزامي من التطبيق.
- ق-90: Offline readiness وBackground Sync readiness
  وNotification readiness حالات مستقلة.
- ق-90: لا يمنع التشغيل بسبب الشبكة أو الإشعارات أو قيود
  البطارية؛ المنع فقط عند خطر حقيقي على حفظ/صلاحية العملية.
- ق-90: Sync Status وPending/Conflict وDevice Setup
  يجب أن تكون واضحة وقابلة للإجراء.
- ق-91: الجلسة الجارية تعرض billable time والمستحق ومصدر
  الطاقة والدفع وحالة Sync بصورة موحدة.
- ق-91: ق-17 يبقى حاكمًا؛ الوقود تكلفة/رقابة ولا يضاف
  Fuel Charge منفصل إلى مستحق المزارع.
- ق-91: Migration 066 تحتوي تعارض Fuel Billing معروفًا
  ويجب تصحيحه في Migration 078+ دون تعديل 066.
- ق-92: إنهاء الجلسة والتكلفة والفاتورة والدفعات والرصيد
  يجب أن تكون Settlement واحدة متسقة وآمنة للـRetry.
- ق-92: دفعات سياق الجلسة تطبق تلقائيًا على فاتورتها،
  والزيادة تبقى Advance؛ الرصيد القديم لا يستهلك بصمت.
- ق-93: كل سياق لازم للاستئناف يجب أن يكون في المستودع،
  و`AI_HANDOFF_PROTOCOL.md` يحدد طريقة تسليم المشروع لأي AI.
- ق-93: PROGRESS للمنجز المثبت فقط، DOC_CHANGELOG لتاريخ
  التوثيق، وRESUME_POINT وحده يحدد أين توقفنا.
- ق-94: ما تبقى من UX دمج في خمس مناقشات فقط UX-13
  إلى UX-17 دون إسقاط أي متطلب.
- ق-95: `AI_COLLABORATION_PROTOCOL.md` يحكم طريقة الحوار،
  منهج اتخاذ القرار، العرض، الاعتماد، واكتشاف الفجوات.
- ق-96: `TERMINAL_COMMAND_PROTOCOL.md` يحكم كتابة الأوامر،
  Shell safety، Git closure، وRecovery بعد الفشل.
- ق-97: `DOCUMENTATION_GATE.md` بوابة إلزامية؛ لا انتقال
  لأي موضوع جديد قبل اكتمال القرار والسبب والفجوات والسجلات
  ونقطة الاستئناف وGit closure.
- ق-98: UX-13 توحد سجل الجلسات والمزارعين والأراضي
  والحجوزات والمناوبات والتسليم التشغيلي.
- ق-98: Booking Offline يبقى «بانتظار تأكيد الموعد» حتى
  قبول Backend؛ Local save لا يساوي Confirmed.
- ق-98: لا Normal Close Shift مع جلسة جارية غير محسومة،
  ونقل المسؤولية يحتاج قبول المشغل المستلم.
- ق-98: Operational Transfer منفصل عن Cash Handover.
- م-28: Booking/History/Reservation atomicity وOffline booking
  وno-orphan shift contracts مفتوحة قبل UX-13 الإنتاجية.
- ق-99: UX-14 توحد Farmer Accounts والدفعات والمصروفات
  والشركاء ودورات الأرباح والتصحيحات المالية.
- ق-99: debt وadvance يعرضان منفصلين ولا يوجد Silent Netting.
- ق-99: old advance لا يستهلك دون فعل صريح.
- ق-99: Distribution Calculation منفصل عن Approval.
- ق-99: Posted Financial Records لا تعدل مباشرة.
- ق-99: Final Financial Actions Online only.
- م-29: Financial Reads/Idempotency/Expense Skip Reason/
  Partner Privacy/Rounding/Corrections مفتوحة قبل Production.
- ق-100: UX-15 توحد Well/Pumps/Energy/Fuel/Pricing/Reports.
- ق-100: Modern Energy Source تأتي من Session Segments.
- ق-100: Diesel V1 = Inclusive Hourly ولا يظهر
  `operation_plus_fuel`.
- ق-100: الرسوم في V1 = Bar/Line فقط ولا Chart في Home.
- ق-100: Reports وCharts تأتي من Backend Aggregation.
- م-30: Well/Pump/Pricing/Fuel/Reporting/Chart contracts
  مفتوحة قبل Production.
- م-25: تنفيذ Android Offline/Background Sync مفتوح وحرج.
- م-26: Active Session Contract وFuel Billing consistency
  مفتوحة وحرجة قبل UX-11/UX-12 الإنتاجية.
- م-27: Session Completion/Settlement Orchestration مفتوحة
  وحرجة قبل UX-12 الإنتاجية.

- ق-104: Research & Standards Gate إلزامية قبل القرارات
  الجوهرية المنطبقة على الأمن/UX/Platform/Accessibility.
- ق-104: Admin Tables = Server-side Filter/Sort/Pagination،
  وAdmin MFA/Step-up/WCAG 2.2 AA متطلبات معتمدة.
- ق-105: Password Option B من ق-103 منسوخة.
- ق-105: لا Recoverable Password Vault ولا Current Password Reveal.
- ق-105: Platform Admin يفرض Reset؛ المستخدم يتحقق بـOTP
  ويختار Password الجديدة بنفسه.
- ق-105: Password الجديدة لا يعرفها Platform Admin.

- ق-106: PA-03 معتمدة؛ Platform Sale وWell Finance منفصلتان.
- ق-106: V1 بيع دائم يدوي؛ عبارة «مجانية بالكامل» من ق-10
  منسوخة، بينما Subscription الدورية تبقى مؤجلة.
- ق-106: كل Well مشتراة لها Entitlement مستقلة.
- ق-106: Sale/Grant/Consumption تحتاج Atomicity + Idempotency.
- ق-106: Platform Admin financial control لا يتجاوز ق-99.
- ق-106: Privileged PA-03 writes Online-only.
- م-34: Platform Sales/Entitlement/Admin Control Pending.

## المسائل المفتوحة المعروفة بعد بوابة الجاهزية

- م-16: Farmer RLS well-wide.
- م-18: roles/permissions catalog wiring.
- م-21: field testing أثناء Stage 7.
- م-23: notification UI/channel + scheduler deployment.
- القضايا القانونية والنشر كما في `OPEN_ISSUES.md`.

هذه المسائل لا تعيد فتح Stage 7 Readiness Gate.

## Stage 7 — الحالة الحالية

- S7-01 Mobile Bootstrap مغلق ومرفوع إلى GitHub.
- ق-82 / Migration 077 مغلق ومثبت محليًا.
- أول عقد قراءة للتطبيق أصبح جاهزًا.

## الهوية البصرية

**بوابة الهوية البصرية العامة مغلقة مبدئيًا بق-83.**

المصدر الحاكم:

`docs/design/VISUAL_IDENTITY.md`

الشعار الحالي معتمد مبدئيًا وقابل للتطوير لاحقًا.

لم تُبن أي واجهة إنتاجية جديدة نتيجة ق-83.

## تجربة المستخدم الحالية

المصدر التفصيلي:

`docs/design/UX_UI_SPEC.md`

- UX-00 / Splash Screen: معتمدة وموثقة.
- UX-01 / App Entry Routing: معتمد وموثق.
- UX-02 / Login Screen: معتمدة وموثقة.
- UX-03 / Create New Well & Setup: معتمد وموثق.
- UX-04 / Unified Account Context: معتمد سلوكيًا.
- UX-05 / Role-Aware Landing: معتمد وموثق.
- UX-06 / Owner Home: معتمد وموثق.
- UX-07 / Role Section Cards: معتمد وموثق.
- UX-08 / Operations Page: معتمد وموثق حتى القرار 293.
- UX-09 / Session Start Form: معتمد وموثق حتى القرار 316.
- UX-09: غياب الإنترنت لا يمنع بدء الجلسة؛ Local Durable
  Save ثم Background Sync وفق ق-89.
- UX-10 / Device Readiness & Sync Status: معتمد وموثق
  حتى القرار 336.
- UX-10: حالة Offline وBackground Sync والإشعارات منفصلة،
  والمزامنة اليدوية إجراء مساعد فقط.
- UX-11 / Active Irrigation Session: معتمد وموثق
  حتى القرار 360.
- UX-11: billable timer + accrued amount + payments +
  energy + Pause/Resume + Offline/Sync status معتمدة.
- UX-12 / Session Completion & Settlement: معتمد وموثق
  حتى القرار 372.
- UX-12: Local Completion منفصل عن Server Settlement،
  والفاتورة والتخصيص والتحديث المالي تتم تلقائيًا بعد Sync.
- التشغيل يغطي المناوبة، بدء/إيقاف/استئناف/إنهاء الجلسة،
  تغيير مصدر الطاقة، التسليم، عداد الزمن والمستحق الجاري.
- Smart Lookup قاعدة عامة وليست مكونًا خاصًا بصفحة التشغيل.
- شبكة الأقسام = 3 أعمدة مبدئيًا، ترتيب ثابت حسب الدور،
  والبطاقات غير المسموحة تختفي بدل إظهارها معطلة.
- «المزيد» آخر بطاقة، والشارات تقتصر على رقم أو حالة
  قصيرة أو تنبيه واحد.
- الرئيسية = رأس + بطاقة بئر + شريط معلومات + شبكة أقسام
  + شريط سفلي متكيف حسب الدور.
- الحسابات تشمل أيضًا سجل المشغلين/المناوبين وسجل الشركاء.
- لا يوجد صف إجراءات سريعة مستقل في الرئيسية.
- المالك → الرئيسية.
- المشغل فقط → صفحة التشغيل.
- الشريك فقط → الصفحة المخصصة للشريك.
- الأدوار المركبة دون owner → الرئيسية الموحدة.
- لا توجد شاشة «اختر دورك».
- الدخول اليومي = رقم الهاتف + كلمة المرور.
- لا يوجد تسجيل ذاتي عام؛ يوجد مسار «إنشاء بئر جديد».
- مالك جديد يتحقق بـOTP أثناء إنشاء الحساب.
- حساب الشريك/المشغل ينشئه المالك مباشرة، ويؤجل OTP
  إلى أول استخدام فعلي للحساب.
- المالك هو المشغل/المناوب الافتراضي الأول، ويمكن إضافة
  مشغلين آخرين.
- رقم الهاتف فريد عالميًا لهوية التطبيق وفق ق-84.
- حساب واحد يجمع جميع الآبار والأدوار.
- «بياناتي كمزارع» معتمدة للمستخدم صاحب الحساب إذا كانت
  له بيانات مزارع مرتبطة بهويته صراحة.
- حساب دخول المزارع العادي مؤجل إلى نسخة لاحقة.
- لا تزال هناك متطلبات Backend/Mobile ناتجة عن
  UX-02/03/08/09/10/11/12/13/14/15/16A
  وق-84/ق-86/ق-88/ق-89/ق-90/ق-91/ق-92/ق-98/ق-99/ق-100/ق-101/ق-102/ق-103/ق-104/ق-105/ق-106/ق-107/ق-108 غير منفذة؛
  أول تغيير قاعدة جديد يجب أن يكون Migration 078+
  إذا احتاجت المتطلبات تغيير DB.
- م-26 تسجل تعارض Fuel Billing في 066 وفجوات Active Session.
- م-27 تسجل فجوة Settlement Orchestration والفاتورة
  والتخصيص التلقائي والـRetry.
- التفاصيل الملزمة لفجوات البحث ومنع التكرار والعداد المالي
  في `technical/SEARCH_DEDUP_ARCHITECTURE.md`.
- لم تُبن شاشة إنتاجية نتيجة هذه القرارات حتى الآن.
- منهج العمل: مناقشة → اعتماد → توثيق → انتقال للتالي.

## ضبط الانتشار العشوائي

**مغلق ومعتمد — ق-86 / 2026-08-18.**

- النسخة الأولى بيع دائم يدوي وليست اشتراكًا.
- كل شراء = حق تفعيل بئر واحد.
- رقم الهاتف يربط بالحق قبل إنشاء البئر.
- التحقق تلقائي ولا يسأل المستخدم عن وجود التفعيل.
- غير المفعل يرى رسالة واضحة مع واتساب واتصال هاتفي.
- مشاركة APK لا تمنح حق إنشاء بئر.
- الشركاء والمشغلون لا يحتاجون شراءً مستقلًا.
- لا يوجد ربط جهاز أو DRM معقد.
- التنفيذ التقني ما زال مطلوبًا في Migration 078+.

## التالي

**Cloud deploy + verify لـMigration 080.**

W1-02 / ق-111 مكتملة ومغلقة:

- Migration 079 = Local + Cloud applied.
- Permanent Test 079 = 20 PASS / 0 FAIL / 0 ERROR.
- Cloud migration history = 78 through 079.
- Farmer self-scope policies = 19.
- Legacy Farmer broad policies في نطاق W1-02 = 0.
- م-16 مغلقة.

W1-03a / ق-112 مطبقة ومتحققة محليًا:

- Migration 080 = `20260819235001_080_permission_authority_foundation.sql`.
- Permanent Test 080 = 20 PASS / 0 FAIL / 0 ERROR.
- Full DB Suite = 20 files / 275 PASS / 0 FAIL / 0 ERROR.
- Local baseline = 79 migration files، أعلى رقم 080
  (الرقم 067 غير مستخدم تاريخيًا).
- Permission catalog = 38 code (17 جديدة).
- `iam.well_assignment_role_map` = 6 صفوف؛ `farmer` مستثنى عمدًا.
- `iam.role_permissions` = 70 منح:
  tenant_owner 38 / well_manager 12 / operator 20.
- partner / accountant / viewer = 0 منح.
- `iam.has_well_permission(uuid, text)` = دالة الصلاحية القانونية الجديدة.
- Legacy `iam.has_well_role` = 273 policy بلا تغيير.
- API = 33 authenticated / 0 anon / 0 SECURITY DEFINER.
- Direct DML = 0.
- سلوك المستخدم = بلا تغيير.
- **Cloud = Pending عند 079.**

Migration 071–080 immutable.

أي DB change جديد يبدأ Migration 081+.

### الخطوة التالية بالترتيب

1. `db push` لـMigration 080 إلى Supabase Cloud.
2. Cloud verification: migration history = 79 through 080،
   catalog = 38، bridge = 6، grants = 70،
   `iam.has_well_permission` موجودة بـSECURITY DEFINER و
   `search_path` مثبت وexecute لـ`authenticated` فقط،
   API = 33 authenticated / 0 anon، Direct DML = 0.
3. Migration 081 — W1-03b Enforcement wiring:
   استهلاك `iam.has_well_permission` داخل RLS/RPC بدل
   مصفوفات الأدوار النصية. م-18 تغلق هناك فقط.

### تحذير تشغيلي قائم

`accountant` و`viewer` صارا مقبولين في
`core.well_assignments.role` لكن بلا أي صلاحية فعلية،
فلا يُعرضان في أي واجهة قبل W1-03b.

### مؤجل بقرار المالك

جولة تنظيف توثيق مستقلة لملفين متأخرين عن الواقع:

- `docs/PROJECT_MAP.md`.
- `docs/technical/INVARIANTS.md`.

### المسألة الحالية

م-18 — مفتوحة ومحصورة الآن في Enforcement wiring:
جعل RLS/RPC تستهلك مصدر الصلاحية بدل مصفوفات
الأدوار النصية. الكتالوج نفسه لم يبق تأسيسيًا.

## قاعدة التنفيذ

المساعد لا يشغّل اختبارات المشروع أو `db:test`
أو `db:reset` أو Docker verification.

المالك يشغّل التحقق ويرسل الناتج.
