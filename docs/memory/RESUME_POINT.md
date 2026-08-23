# نقطة الاستئناف — 2026-08-23

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

### قاعدة البيانات — محدَّث 2026-08-23

- migrations = 83 file، آخرها 084؛ 071–084 immutable.
- permanent test files = 24.
- PASS = 354.
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
- Cloud = `CLOUD_W2_01_ALL_PASS`؛ remote history = 83 through
  `20260823013001`؛ `DATA_API_BOUNDARY=OK`.

### كود الهاتف — محدَّث 2026-08-23

- `flutter analyze` = `No issues found!`.
- `flutter test` = **115 PASS / 0 FAIL** (خط الأساس السابق 69).
- بلا هاتف وبلا شبكة وبلا قاعدة بيانات.

الرقم القديم (76 migration / 17 test / 217 PASS) كان لقطة
2026-08-17 ولا يُستخدم كحالة حالية.

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
- م-18: roles/permissions catalog wiring — **مغلقة** بق-113 (2026-08-22).
- م-21: field testing أثناء Stage 7.
- م-23: notification UI/channel + scheduler deployment.
- م-25: Android Offline/Background Sync — **ضُيِّقت ثلاث مرات:**
  بق-114 (2026-08-22) أساس حماية التكرار على الخادم منفَّذ
  ومُثبت، وبق-115 (2026-08-23) طابور الجهاز الدائم ومعرّفات
  العمليات الثابتة منفَّذة، وبق-116 (2026-08-23) سجل الجلسة
  النشطة والاستعادة بعد موت التطبيق منفَّذان ومُثبتان على قرص
  حقيقي. **الإرسال الخلفي والشاشات والواجهات الميدانية تبقى
  مفتوحة وحرجة.**
- القضايا القانونية والنشر كما في `OPEN_ISSUES.md`.

هذه المسائل لا تعيد فتح Stage 7 Readiness Gate.

## Stage 7 — الحالة الحالية

- S7-01 Mobile Bootstrap مغلق ومرفوع إلى GitHub.
- ق-82 / Migration 077 مغلق ومثبت محليًا.
- أول عقد قراءة للتطبيق أصبح جاهزًا.
- **W2-02a / ق-115: أول عقد كتابة دون اتصال أصبح جاهزًا** —
  `apps/mobile/lib/core/sync/`. لا واجهة تستخدمه بعد.
- **W2-02c / ق-116: سجل الجلسة النشطة أصبح جاهزًا** —
  `apps/mobile/lib/core/session/`. نموذج قراءة يُشتق من
  الطابور، مُبرهَنة استعادته على قرص حقيقي. لا شاشة تستخدمه بعد.

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
  أول تغيير قاعدة جديد يجب أن يكون Migration 085+
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
- التنفيذ التقني ما زال مطلوبًا في Migration 085+.

## التالي

**W2-01 مكتملة ومغلقة — حماية التكرار على الخادم (ق-114 /
Migration 083+084)، متحقق منها محليًا وسحابيًا 2026-08-22.
التالي = W2-02 طابور الهاتف (Local durable DB + Outbox +
معرّفات عمليات ثابتة + WorkManager)، أو دفعة RLS مستقلة
لنقل 273 policy، بحسب قرار المالك.**

W2-01 / ق-114 مكتملة ومغلقة — Local + Cloud (2026-08-22):

- Migration 083 = `20260823003001_083_sync_command_resolvers.sql`
  (4 مُحلِّلات + سحب منح `PUBLIC` عن دالتَي 058).
- Migration 084 = `20260823013001_084_api_idempotent_writes.sql`
  (8 أغلفة `api.*` بمعرّف عملية اختياري أخير).
- Permanent Test 083 = 16 PASS؛ 084 = 23 PASS.
- Full DB Suite = **24 files / 354 PASS / 0 FAIL / 0 ERROR**؛
  صفر Regression على 315 فحصًا من جولات سابقة.
- إرسال نفس العملية مرتين ⟹ سجل واحد ونفس النتيجة حرفيًا،
  و`record_payment` **إجماليها لا يتضاعف** (فحص بالمبلغ لا
  بعدد الصفوف).
- `p_command_id = null` ⟹ المسار القديم بلا فرق = توافُق خلفي.
- **الجهة تُستخرَج على الخادم** من البئر أو الجلسة؛ العميل
  لا يُرسل `tenant_id` أبدًا.
- حدّ نطاق المُحلِّل (تعيين نشط) لا قرار صلاحية، ومبرهن أنه
  لا يُحدث انحرافًا لأن `iam.has_well_permission` تشترط
  التعيين النشط نفسه (`080:243`).
- API = 33 authenticated / 0 anon / 0 SECURITY DEFINER؛
  Direct DML = 0 (سطح API بقي 33 لأن التوقيع استُبدل لا أُضيف).
- لا حالة `processing` عالقة ولا مُنظِّف دوري: استدعاء واحد =
  transaction واحدة، والعملية المرفوضة تتراجع بكاملها.
- تعديل اختبار مسموح في موضعين فقط (073 و075) لتوقيعَي
  `api.create_farm` و`api.start_irrigation_session`؛ ملفا
  Migration 073 و075 لم يُمسّا.
- **Cloud = متحقق منه:** `CLOUD_W2_01_ALL_PASS` (39/0/0)؛
  `DATA_API_BOUNDARY=OK`؛ remote history = 83 through
  `20260823013001`.
- **م-25 تضيق ولا تُغلق:** الخادم جاهز لاستقبال إعادة إرسال
  آمنة، وما يعيد الإرسال لم يُبنَ بعد.
- Local baseline = 83 migration file، أعلى رقم 084.

W1-03b / ق-113 مكتملة ومغلقة — Local + Cloud (2026-08-22):

- Migration 081 = `20260822003001_081_permission_enforcement_money.sql`
  (13 موضعًا ماليًا).
- Migration 082 = `20260822013001_082_permission_enforcement_ops.sql`
  (15 موضعًا تشغيليًا).
- Permanent Test 081 = 20 PASS؛ 082 = 20 PASS.
- Full DB Suite = 22 files / 315 PASS / 0 FAIL / 0 ERROR؛
  صفر Regression على 295 فحصًا من جولات سابقة.
- Function-body guards على `has_well_role` = **0**.
- Legacy RLS = 273 policy بلا تغيير، وهي مستهلكها الوحيد.
- Catalog = 39؛ grants = 73 (owner 39 / manager 13 /
  operator 21). الإضافة الوحيدة = `session.energy.change`.
- برهان تكافؤ قبل الكتابة = 28 EQUIVALENT / 1 MISSING_CODE /
  **0 DIFFERS** = `NO_SILENT_DRIFT`.
- حرس الهوية لم يُحوّل في `api.declare_handover` /
  `api.request_session_transfer` /
  `api.respond_session_transfer` وفرع الهوية في
  `api.close_shift`.
- `ops.create_farm` نُقلت من تعريف 075 الحي لا 069 المُسقط.
- **Cloud = متحقق منه:** `CLOUD_W1_03B_ALL_PASS`؛
  remote history = 81 through `20260822013001`.
- سلوك المستخدم = بلا تغيير، مبرهنًا لا مُدّعى.
- Local baseline حينها = 81 migration file، أعلى رقم 082
  (الحالي = 83 وأعلى رقم 084 بعد W2-01).

W1-02 / ق-111 مكتملة ومغلقة:

- Migration 079 = Local + Cloud applied.
- Permanent Test 079 = 20 PASS / 0 FAIL / 0 ERROR.
- Farmer self-scope policies = 19.
- Legacy Farmer broad policies في نطاق W1-02 = 0.
- م-16 مغلقة.

W1-03a / ق-112 مكتملة ومغلقة — Local + Cloud:

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
- **Cloud = متحقق منه:** `CLOUD_080_ALL_PASS` (20/20)
  و`DATA_API_BOUNDARY=OK`؛ remote history = 79 through
  `20260819235001`.

Migration 071–084 immutable.

أي DB change جديد يبدأ Migration 085+.

### حالة البيئة السحابية — 2026-08-22

المشروع السحابي أُعيد بناؤه من الصفر في حساب جديد ومنطقة
South Asia (Mumbai) بعد تعذّر الوصول إلى بريد الحساب السابق.
لم يُفقد شيء: لا بيانات إنتاجية، ولا مستخدمين حقيقيين،
ولا أي مرجع للمشروع القديم في المستودع.

- الـ83 migration مطبقة كلها بالترتيب من 001 إلى 084؛
  remote history = 83 through `20260823013001`.
- Exposed schemas = `api` أولًا ثم `graphql_public`؛
  `public` غير مكشوفة.
- الغرف الداخلية `core` / `iam` / `public` / `audit` /
  `reporting` كلها محجوبة عبر Data API.
- **قناة النشر العاملة الوحيدة = Supavisor transaction mode
  على المنفذ 6543.** المنفذ 5432 والاتصال المباشر IPv6
  لا يصلان من شبكة المالك، لذلك `db push` لا يعمل
  والنشر يجري بسكربت `psql` قابل للاستكمال.

تفاصيل القناة وسبب أمانها في `technical/MIGRATIONS.md`.

### الخطوة التالية بالترتيب

W1 اكتملت: W1-01 وW1-02 وW1-03 كلها مغلقة. وW2-01 (أساس
حماية التكرار على الخادم) اكتملت. وW2-02a (طابور الجهاز
الدائم / ق-115) اكتملت ومُتحقَّق منها. **وW2-02c (سجل الجلسة
النشطة والاستعادة / ق-116) اكتملت ومُتحقَّق منها — 115 PASS.**
الخيارات المطروحة بترتيب أولوية ق-109:

1. **W2-02b — الإرسال الخلفي. الخطوة التالية.** العملية صارت
   محفوظة على الجهاز ولا تُرسل مرتين، والجلسة تُستعاد بعد موت
   التطبيق، **لكن الإرسال ما زال يحتاج أن يكون التطبيق
   مفتوحًا**. المطلوب: WorkManager، ومراقب اتصال، وجدولة
   إعادة زمنية، والتشغيل بعد إقلاع الهاتف، وصلاحيات
   المانيفست. لا تغيير على قاعدة البيانات.

   **محجوبة في بيئة المساعد ولا يمكن تنفيذها منها:**
   `workmanager` و`connectivity_plus` و`permission_handler`
   غائبة عن `~/.pub-cache`، و`androidx.work` غائبة عن Gradle
   cache، وشبكة بيئة المساعد لا تصل pub.dev. **يفتحها المالك
   بأمر واحد:**

       cd apps/mobile && flutter pub add workmanager connectivity_plus

   بعده تصير قابلة للتنفيذ والاختبار بلا حاجة إلى جهاز.
2. **W2-02d — جاهزية الجهاز وشاشات حالة المزامنة** (ق-90 /
   UX-10). النصوص والحالات موجودة في الطابور وفي نموذج
   الجلسة، بلا شاشة تعرضها.
3. **عقد قراءة `api.*` لأسماء العرض** (بند 20 بند 2 من
   `ACTIVE_SESSION_ARCHITECTURE.md`): نموذج الجلسة يحمل
   معرّفات لا أسماء مزارع وأرض ومضخة، ولا يخترع نصًّا.
4. **توسيع نمط ق-114** إلى العقود Offline-capable خارج
   الثماني (ورديات، نقل جلسة، حجوزات، مصروفات، توزيعات) —
   يحتاج Migration 085+ وقد صار النمط مُثبتًا.
5. **دفعة RLS مستقلة (Migration 085+)** لنقل 273 policy
   إلى Permission Codes وإسقاط `has_well_role` بعدها.
   ليست حاجزًا أمام W2 لأن السلطتين تعطيان الجواب نفسه.
6. **قرار صريح لصلاحيات `partner` / `accountant` /
   `viewer`** — يُطلب أول مرة تحتاجها واجهة فعليًا.
7. **قرار في رؤية دفعة الرصيد المقدم** (انظر «مؤجل» أدناه).

### مُتحقَّق منه — W2-02c (2026-08-23)

`flutter analyze` = `No issues found!`
`flutter test` = **115 PASS / 0 FAIL** (خط الأساس السابق 69،
أي 46 اختبارًا جديدًا).

`active_session_projector_test.dart` جرى على **ملف قرص حقيقي**:
الأحداث تُكتب، يُغلق المخزن كأن التطبيق مات، وتُفتح نسخة مخزن
جديدة تمامًا ⟹ الجلسة تعود بحالتها وزمنها المحتسب وتوقفها
ومصدر طاقتها ودفعاتها وحالة مزامنتها متطابقة.

**لا `db:reset` ولا `db:test` ولا Docker ولا نشر سحابي — لا
تغيير في قاعدة البيانات إطلاقًا.**

خلل وُجد وأُصلح داخل الجولة: الصياغة الأولى للمُسقِط كانت تشتق
القراءة التصاعدية من المرساة نفسها، فصارت المقارنة بين الرقم
ونفسه و**استحال رفع علم تعديل الساعة**. كُشف عند كتابة الاختبار
الذي يُبرهنه. صار المُسقِط يستقبل مرساة + قراءة جهاز معًا.

**ما لا يجوز إعادة عمله:** لا جدول حالة جلسة محلي، ولا
`Timer` في الذاكرة يُعتمد عليه، ولا قسمة على مجموع الثواني
(القسمة على كل مقطع — Migration 066)، ولا مطابقة م-26 في
الهاتف بجمع الوقود على المستحق المحلي.

### مُتحقَّق منه — W2-02a (2026-08-23)

`flutter analyze` = `No issues found!`
`flutter test` = **69 PASS / 0 FAIL**.

ملف `sqlite_outbox_store_test.dart` جرى فعلًا على SQL حقيقي عبر
`sqflite_common_ffi` ونجح — أي أن «العملية لا تُفقد» مبرهنة على
ملف قرص لا على مخزن ذاكرة.

**لا `db:reset` ولا `db:test` ولا Docker ولا نشر سحابي — لا
تغيير في قاعدة البيانات إطلاقًا.**

أول تشغيل أسقط اختبارًا واحدًا: مساعد الاختبار كان يبني مولّد
معرّفات جديدًا لكل مستودع، فيعيد الترقيم من أوله بعد إعادة فتح
الملف ويصطدم بشرط الفرادة على `command_id`. **الكود الإنتاجي رفض
المعرّف المعاد — وهو السلوك المطلوب**؛ المولّد الحقيقي
`SecureIdGenerator` لا يعيد معرّفًا أبدًا. صُحِّح المساعد إلى
مولّد واحد لكل اختبار.

### مغلق — جولة تنظيف التوثيق (2026-08-22)

`docs/PROJECT_MAP.md` و`docs/technical/INVARIANTS.md` كانا
مؤجَّلين للتنظيف. نُفِّذت الجولة: قاعدة الترقيم صُحِّحت في
كليهما، وحالة W1-01 في `PROJECT_MAP.md` صُحِّحت من
«Pending Owner Verification» إلى «مكتملة ومغلقة». التفاصيل
في القسم التالي.

### تحذير تشغيلي قائم

`partner` و`accountant` و`viewer` مقبولون في
`core.well_assignments.role` لكن بصفر منح بالتصميم — بلا أي
صلاحية فعلية. لا تعرضهم أي واجهة قبل قرار صريح لصلاحياتهم.
هذا لم يتغير بإغلاق W1-03b.

### عائق بيئي عند المساعد — `git` لا يقرأ إعداداته

اكتُشف 2026-08-23 في نهاية جولة W2-02c. أي أمر `git` يفشل:

    warning: unable to access '.git/config.worktree': Permission denied
    fatal: unknown error occurred while reading the configuration files

السبب: `.git/config.worktree` و`.git/config.lock` بحجم **0
بايت** ومملوكان لـ`nobody` بلا صلاحية قراءة لـ`kali`، وهما
مخلَّفان عن عملية سابقة (تاريخهما 2026-08-21 14:15). و
`.git/config` يحتوي `[extensions] worktreeConfig = true`
فيُلزم `git` بقراءة الملف غير المقروء.

**الأثر:** بوابة التوثيق بند 17 خطوة 1 (`git diff --check`)
**لم تُشغَّل ولم يُدَّع نجاحها**، ولا قائمة ملفات مُغيَّرة
مُستخرجة من `git` في جولة W2-02c.

**الإصلاح عند المالك** (خارج تصريح المساعد):

    sudo rm -f .git/config.lock .git/config.worktree

لا يفقد شيئًا: الملفان فارغان، وإعدادات المستودع الفعلية في
`.git/config` سليمة.

### مؤجل بقرار المالك

لا شيء مؤجَّل حاليًا في التوثيق. جولة تنظيف
`PROJECT_MAP.md` و`INVARIANTS.md` نُفِّذت 2026-08-22.

### مغلق — قاعدة الترقيم القديمة صُحِّحت (2026-08-22)

**نُفِّذت كجولة مستقلة بعد إغلاق W2-01.** كانت قاعدة «أول DB
Migration جديدة: 078 أو أحدث» مكتوبة في **123 موضعًا موزَّعة على
24 ملفًا**، وصارت خاطئة منذ تطبيق 078 فعلًا (لا علاقة لها بجولة
W2-01). الخطر لم يكن تجميليًا: من يقرأ أي موضع منها ويبدأ
Migration 078 يصطدم بملف مختوم موجود.

**أ — قواعد حيّة صُحِّحت إلى 085+ / 071–084:**

- 9 ترويسات «أول DB Migration جديدة» في الوثائق المعمارية:
  `SEARCH_DEDUP` و`ACTIVE_SESSION` و`SESSION_SETTLEMENT` و
  `OPERATIONS_RECORDS` و`MONEY_PARTNERS` و
  `WELL_MANAGEMENT_REPORTING` وثلاث وثائق `PLATFORM_ADMIN_*`
  (و`ANDROID_OFFLINE_BACKGROUND_SYNC` كانت صُحِّحت في W2-01).
- `technical/INVARIANTS.md` — 15 ثابتًا مرقّمًا، والثابت 681 صار
  «Migration 071–084 تبقى immutable».
- `technical/API_ARCHITECTURE.md` — 14 قاعدة.
- `design/UX_UI_SPEC.md` — 20 موضعًا (منها سطران بصيغة
  «Migration 078 أو أحدث»).
- `technical/DECISION_IMPLEMENTATION_MATRIX.md` — 14 خلية
  «Migration 078+ Pending» + خلية «correct in 078+».
- `technical/V1_IMPLEMENTATION_SEQUENCE.md` — قواعد التنفيذ
  وسطر «Next» في نهاية الوثيقة.
- **`memory/AI_HANDOFF_PROTOCOL.md` — الأخطر**، لأنه أول ملف
  يقرأه أي مساعد جديد: «Do not edit migrations 071–084» و
  «New DB changes begin 085+»، ونقطة العمل الحالية صارت W2.
- `docs/README.md` و`docs/PROJECT_MAP.md`.

**تُركت عمدًا — عبارات صحيحة *عن* الملف الحقيقي 078:** الثوابت
678/679/680 في `INVARIANTS.md` و`API_ARCHITECTURE.md:829` و
`SEARCH_DEDUP_ARCHITECTURE.md:702` و
`DECISION_IMPLEMENTATION_MATRIX.md:109` — كلها تصف ما فعلته 078
وما لم تفعله، ولا تُوجِّه أحدًا لبدء رقم.

**ب — سجلات مؤرَّخة تُركت كما هي:** `PROGRESS.md` (19 موضعًا) و
`DOC_CHANGELOG.md` (11) و`DECISIONS.md` (29) وكتل أدلة
`OPEN_ISSUES.md` (9). تصف ما كان صحيحًا في تاريخه.
`RESEARCH_STANDARDS_GATE.md` (قسم مؤرَّخ 2026-08-19) عُولج
بمؤشر تجاوُز لا بتعديل — نفس قاعدة تدقيق W1-03b وW2-01.

**تحقق نهائي:** صفر موضع حيّ باقٍ من `078+` أو `071–077`،
وأعداد السجلات المؤرَّخة لم تتغير (19/11/29/9).

**صُحِّح أيضًا في نفس الجولة:** `PROJECT_MAP.md` كان يقول عن
W1-01 «Prepared / Pending Owner Verification» وهي مكتملة ومغلقة
ومتحقق منها سحابيًا منذ جولات.

### مؤجل — رؤية دفعة الرصيد المقدم

اكتُشف أثناء تحقق W2-01 ولا علاقة له بق-114: دفعة الرصيد
المقدم (بلا فاتورة جلسة) تُكتب بنجاح لكن **لا تُقرأ** عبر
دور التطبيق، لأن سياسة قراءة قديمة (`016:45`) تشترط ارتباط
الدفعة بفاتورة جلسة.

الأثر العملي: المشغّل — وهو من يستلم النقد — لن يرى الدفعة
على شاشته حين تُبنى شاشة الدفعات. سلوك قائم قبل هذه الجولة،
مسجَّل في م-29 (الفجوة 14)، ويحتاج قرارًا صريحًا: هل يرى
المشغّل دفعات مزارعي بئره كلها أم فقط المرتبطة بفاتورة؟

### المسألة الحالية

**م-25 ضُيِّقت ثلاث مرات ولم تُغلق.**

- بق-114: الخادم صار يميّز العملية المكرَّرة ويعيد نفس
  النتيجة بدل تنفيذها ثانية، للدورة الميدانية الأولى (8
  عمليات).
- بق-115: الجهاز صار يحفظ العملية حفظًا دائمًا ويعيد إرسالها
  بمعرّف ثابت لا يتغير، مرتَّبةً وبمراجع محسومة. أي أن حماية
  ق-114 صارت مستعملة فعلًا.
- بق-116: الجلسة الجارية صارت تُستعاد كاملة بعد موت التطبيق
  وبعد إعادة إقلاع الهاتف — من الطابور نفسه لا من جدول موازٍ
  — بزمنها المحتسب ومستحقها المطابق لحساب الخادم مقطعًا
  مقطعًا. وتعديل ساعة الهاتف يُكشف ولا يضخّم المستحق.

الباقي على طبقة الهاتف: **الإرسال بلا فتح التطبيق**
(WorkManager ومراقب اتصال وجدولة إعادة)، وجاهزية الجهاز،
وشاشات الحالة، وعرض التعارض، وعقد قراءة أسماء العرض، وأي
واجهة ميدانية تُدخل العمليات أصلًا.

**م-18 مغلقة** بق-113.

المسألة الجامعة م-37 تبقى مفتوحة حتى W10.

## قاعدة التنفيذ

المساعد لا يشغّل اختبارات المشروع أو `db:test`
أو `db:reset` أو Docker verification.

المالك يشغّل التحقق ويرسل الناتج.
