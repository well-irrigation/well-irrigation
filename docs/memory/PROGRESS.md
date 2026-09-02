# سجل التقدم

**آخر تحديث:** 2026-09-03

## 2026-08-30 — Audit 1: Flutter Data API Boundary

### م-41A — FinanceRepository API RPC Boundary Repair

- تم توجيه 7 RPC مالية موجودة أصلًا على الخادم إلى
  `schema('api').rpc(...)`.
- العقود: record_expense، decide_expense،
  calculate_profit_distribution، approve_profit_distribution،
  pay_partner_distribution، record_payment، allocate_payment.
- Cloud contract inspection كان قراءة فقط وأثبت وجود العقود
  السبعة وتوافق توقيعاتها مع الاستدعاءات الحالية.
- Known Bare RPC Debt انخفض من **20 إلى 13**.
- Internal-schema debt بقي **9**.
- Dotted-from debt بقي **5**.
- Data API Regression Guard = **3/3 PASS**.
- `flutter analyze` = **No issues found**.
- Full Flutter regression = **225/225 PASS**.
- لا Migration 088.
- لا كتابة على Supabase ضمن م-41A.


### م-41B1 — Physical Fuel Count Repair

- رُبط تسجيل الجرد الفعلي للوقود بالعقد الموجود أصلًا:
  `api.record_physical_fuel_count`.
- التطبيق يرسل البئر والخزان الصحيحين.
- تحويل وحدة القياس يتم عند الحد:
  اللتر في واجهة المستخدم → الملليلتر في عقد الخادم.
- فشل Backend لم يعد يتحول إلى نجاح وهمي في مسار الجرد.
- Targeted M-41B1 tests = **9/9 PASS**.
- `flutter analyze` = **No issues found**.
- Full Flutter regression = **228/228 PASS**.
- Known debt الحالي:
  - internal schemas = **9**.
  - bare RPC = **12**.
  - dotted `from()` = **5**.
- فحص عقد الخادم كان قراءة فقط.
- لا Migration 088.
- لا Cloud write ضمن م-41B1.

- PR #4 دُمج إلى `main` عند
  `7abcb52f3439e9f48b95442f3993571637e45eef`.
- بدأ أول عنصر في Pre-Production Audit Queue.
- Static scan محلي شمل **76 Dart file**.
- وجد **9** internal-schema accesses.
- وجد **20** Bare RPC candidates.
- وجد **5** Dotted `from()` candidates.
- Cloud read-only API inventory أثبت **34 RPC** حالية.
- من أسماء Bare RPC العشرين: **7 موجودة داخل api / 13 غير
  موجودة داخل api بهذا الاسم**.
- `AccountRepository` و`OperationsRepository` و
  `FinanceRepository` و`WellManagementRepository` تحتوي
  انحرافات مؤكدة عن حد Data API المعتمد.
- بعض الانحرافات مخفية حاليًا بـMock fallback أو catch صامت.
- لا يوجد `apps/mobile/test/core/api` كشبكة Regression لهذه
  الحدود.
- لم يُعدل Flutter code.
- لم تُنشأ Migration 088.
- لم تحدث كتابة على Supabase ضمن هذا التدقيق؛ الفحص السحابي
  كان قراءة فقط.
- النتيجة: **م-41 Confirmed Gap / Repair Now**.

### م-41 — Regression Guard

- أضيف `apps/mobile/test/core/api/data_api_boundary_test.dart`.
- الاختبار يثبت Known Debt الحالي بدقة:
  - internal schemas = **9**.
  - bare RPC = **20**.
  - dotted `from()` = **5**.
- أي خرق جديد يفشل الاختبار؛ الدين الموثق لا يجوز إلا أن ينخفض.
- Targeted Data API guard = **3/3 PASS**.
- `flutter analyze` = **No issues found**.
- لم يتغير Flutter production code.
- لم تُنشأ Migration 088.
- لم تحدث كتابة على Supabase.

## 2026-08-30 — P0 Create-Well Correctness — Closed

- PR #3 دُمج بـSquash إلى `main` عند
  `0e3d46e873c4f6b1088b5d98b65c1b65316f17aa`
  بعنوان `fix: stabilize create-well correctness (#3)`.
- **م-38 Verified local + Cloud:** Migration 087 تحافظ على
  `api.setup_well_full` كـSECURITY INVOKER و
  `core.setup_well_full` كـSECURITY DEFINER، وتسمح
  لـ`authenticated` و`service_role` بالمسار المطلوب مع
  بقاء `anon` محجوبًا وDirect DML = 0.
- اختبار DB المستهدف 087 = **8 PASS / 0 FAIL / 0 ERROR**.
- Full DB Suite = **25 files / 362 PASS / 0 FAIL / 0 ERROR**.
- **م-39 Verified local + Cloud:** أزيل ×100؛ التحقق السحابي
  الفعلي أثبت 3500/7000/6000 مخزنة حرفيًا بالقيم نفسها.
- **م-40 Verified local:** فشل Backend لا يؤدي إلى completion
  أو إغلاق ناجح أو ادعاء حفظ Offline؛ Cloud verification
  غير منطبق على سلوك الواجهة.
- Flutter targeted = **2/2 PASS**.
- Full Flutter Suite = **222/222 PASS**.
- `flutter analyze` = **No issues found**.
- التحقق السحابي استخدم مستخدمًا وبئرًا مؤقتين داخل Transaction:
  الاستدعاء كـ`authenticated` نجح، وإنشاء البئر نجح،
  و`anon` رُفض، ثم انتهت المعاملة بـ**ROLLBACK**.
- فحص ما بعد التراجع = **0 residues** في المستخدم والملف
  والجهة والبئر.
- Migration 087 كانت موجودة بالفعل في Remote Migration History
  عند فحص ما بعد الدمج؛ لم تُعد تطبيقها.
- **P0 Create-Well Correctness مغلق.**
  ق-120 تبقى نافذة، وNEXT ينتقل إلى **Pre-Production Audit Queue**.

قاعدة هذا الملف: **لا يُكتب فيه إلا ما تمّ فعلًا وثُبِت بدليل.** النية والخطة مكانهما `RESUME_POINT.md`.

---

## Baseline قبل إغلاق P0 — 2026-08-25 (تاريخي للمقارنة)

هذا Snapshot تاريخي؛ الحالة الحالية المثبتة هي قسم P0 أعلاه و`RESUME_POINT.md`.

### التنفيذ التقني المثبت

- **قاعدة البيانات:**
  - migrations = 85 file (آخرها 086_well_setup_full_and_profile_phone).
  - permanent test files = 24.
  - PASS = 354.
  - FAIL = 0.
  - ERROR = 0.
  - Data API RPC = 34 (إضافة `api.setup_well_full` كعقد تهيئة شامل وذري للبئر ومكوناته).
  - مزامنة رقم الهاتف تلقائياً في `iam.profiles` عبر الزناد المحدث `iam.handle_new_user()`.
  - 8 دوال ميدانية تدعم `p_command_id` لضمان عدم التكرار (Idempotent Writes).

- **تطبيق الهاتف (Flutter):**
  - `flutter analyze` = `No issues found!`.
  - `flutter test` = **220 PASS / 0 FAIL** (شاملة اختبارات إدارة الحساب والملف الشخصي، تغيير كلمة المرور وتفريغها الآمن، إدارة الفريق والمشغلين والتحقق من صلاحية المالك والمشغل، تشخيص الجهاز والمزامنة، تفضيلات المظهر والطباعة الحرارية 58mm/80mm، الدعم وسياق التشخيص الفني الآمن، إدارة البئر والمعدات، المضخات والمواصفات الفنية، تعرفة الطاقة والأسعار التاريخية بالساعة، إدارة الوقود والخزانات والجرد والتسويات، التقارير والمؤشرات العامة والرسوم البيانية البسيطة V1، إدارة المصروفات واعتمادها، هيكل الشركاء وتفكيك الأرباح، دورات التوزيع، الحساب المالي للمزارع وعدم التقاص الصامت ق-99، سجل الجلسات والخط الزمني، دليل المزارعين، منسق الجلسات المتين، استعادة الجلسة والعداد، الطباعة الحرارية 58mm/80mm، البحث الذكي ومبدل الآبار).
  - شاشات المرحلة المعتمدة: SplashScreen, LoginScreen (UX-02), CreateWellWizardScreen (UX-03), HomeScreen (UX-05), OperationsScreen (UX-07/08/10), SessionHistoryScreen (UX-13), SessionDetailScreen (UX-13), FarmersDirectoryScreen (UX-13), FarmerDetailScreen (UX-13), ExpensesScreen (UX-14), PartnersScreen (UX-14), PartnerDetailFinancialScreen (UX-14), ProfitDistributionScreen (UX-14), FarmerFinancialAccountScreen (UX-14), WellManagementHubScreen (UX-15), WellSettingsScreen (UX-15), PumpsManagementScreen (UX-15), PricingTariffScreen (UX-15), FuelInventoryScreen (UX-15), ReportsAnalyticsScreen (UX-15), MoreSettingsScreen (UX-16A), ProfileSecurityScreen (UX-16A), TeamPermissionsScreen (UX-16A), DeviceSyncScreen (UX-16A), AppSettingsScreen (UX-16A), HelpSupportScreen (UX-16A).
  - المكونات المعيارية: `PaymentReceiptDialog` (نافذة سداد واعتماد الفاتورة وسند القبض والطباعة الحرارية الميدانية), `SmartLookupField` (البحث الذكي الموحد والاقتراحات اللحظية والإضافة السريعة), `TopWellSelector` (مبدل الآبار السلس في الشريط العلوي), `CurrencyTextFormField` (فواصل آلاف + تفقيط لحظي), `CurrencyDisplay` (عرض المبالغ رقماً وتفقيطاً), `ArabicToEnglishDigitsFormatter` (توحيد الأرقام 0-9), `Tafqeet` (تفقيط مالي فصيح بالريال اليمني).
  - طبقة الخدمات والبيانات: `AccountRepository` (إدارة الملف الشخصي، الأمان، الفريق والمشغلين، تشخيص المزامنة والجهاز، فحص تسجيل الخروج الآمن ق-578)، `WellManagementRepository` (إدارة بيانات البئر، المضخات، تعرفة الأسعار التاريخية، خزانات الوقود والجرد والتسويات، التقارير والمؤشرات والرسوم البيانية V1)، `FinanceRepository` (المصروفات، الشركاء، دورات الأرباح، حسابات المزارعين)، `OfflineSessionCoordinator` (منسق الجلسات المتين ق-89/ق-90/ق-114)، `ReceiptFormatter` (قوالب الطباعة الحرارية)، `AppBootstrapRepository`، `OperationsRepository`، `AuthRepository`.
  - العداد الميداني اللحظي: يعمل بمؤقت دوري حي مع احتساب المستحق بالثواني دون تقريب وفق ق-17 مع استعادة كاملة لحالة الجلسة والمقاطع بعد إغلاق التطبيق.
  - التحقق من الحصص: منع تجاوز مجموع نسب الشركاء 100% وإظهار الحصص المتبقية لحظياً.

### التقدم التصميمي والتوثيقي المثبت

- ق-83 إلى ق-119: معتمدة وموثقة بالكامل في `DECISIONS.md`.
- UX-00 إلى UX-16A: معتمدة وموثقة ومطبقة في التطبيق بالكامل مع 100% نجاح في الاختبارات (220 PASS).
- ق-101 / القرارات 527–600: الحساب، الملف الشخصي، الفريق والصلاحيات، الجهاز والمزامنة، المظهر والطباعة الحرارية، والدعم الفني.


## 2026-08-12 — التحليل والقرارات

* قراءة وثيقة التأسيس كاملة: 11,710 سطرًا.
* قراءة تقرير نقل السياق كاملًا: 2,785 سطرًا.
* ثلاث جولات تحليل وتحقق من النصوص.
* **حسم 47 قرارًا** من المالك: 11 + 22 + 14.
* رصد 7 تناقضات داخلية وحسمها جميعًا.

**الدليل:** `DECISIONS.md` — 293 سطرًا، 47 قرارًا مرقّمًا.

---

## 2026-08-12 — تفكيك الوثائق — ق-31

فُكّك الملف الأول إلى أربع وثائق تحت `reference/`:

* `01_functional_reference.md` — المرجع الوظيفي والمعماري. الأصل 1–2474.
* `02_database_and_finance_design.md` — تصميم قاعدة البيانات والمحرك المالي. الأصل 2475–5612.
* `03_implementation_schema.md` — المخطط التنفيذي لـ PostgreSQL. الأصل 5613–9389.
* `04_erd_and_data_dictionary.md` — مخطط العلاقات وقاموس البيانات. الأصل 9390–11710.

---

## 2026-08-12 — تطبيق القرارات على الوثائق

تعديلات جراحية مُثبَتة ومُتحقّق منها:

1. القسمان 17.3 و17.4: حُذف التقريب وحلّ محله احتساب بالثواني مع مثال مشتغل.
2. القسم 18.6: أُعيدت كتابته على أساس جزء من ألف والرصيد المُرحَّل.
3. `core.well_settings`: حُذفت 3 حقول تقريب، وأُضيف `long_session_alert_minutes` و`session_ending_alert_minutes`.
4. القسم 23: حُذفت `ops.ceil_to_quarter_hour` وحلّت محلها `ops.time_charge_milli`.
5. حُذف `minimum_billable_minutes`.
6. القسم 12.4: قاعدة 100% الحتمية + توثيق ت-01.
7. القسم 15.6: أربعة أقسام فرعية جديدة لحسم يوم الجلسة.
8. القسم 16: الإشعارات الخمسة المعتمدة.
9. ترويسة تحذير في رأس الوثائق الأربع.
10. 13 تصحيحًا لأرقام القرارات المذكورة داخل النص.

---

## 2026-08-12 — بناء مجلد الذاكرة — ق-42

بُني مجلد `docs/` بطبقاته الأربع وملفاته الإدارية زائدًا الوثائق المرجعية الأربع.

**ملاحظة تقنية موثّقة:** حدث تعطّل في بيئة العمل أدى إلى فقدان دفعة ملفات مكتوبة، فأُعيدت كتابتها وتُحقّق من وجودها بالفحص المباشر. الدرس المستفاد: **لا يُعتمد على تقرير النجاح، بل على الفحص بعد الكتابة.**

---

## ما لم يبدأ بعد إطلاقًا

* لا يوجد أي كود Flutter.
* لم تُطبّق أي هجرة على قاعدة بيانات حية.
* لا يوجد Commit واحد في Git.
* لا يوجد مستودع GitHub.
* لا توجد حسابات Supabase أو Firebase أو Google Play.

---

## 2026-08-12 — الدفعة الرابعة: النصوص القانونية

**ما أُنجز:**

* وصل ملف الشروط وسياسة الخصوصية من المالك وحُفظ في `legal/terms_and_privacy_v1_original.pdf`.
* روجع بندًا بندًا مقابل القرارات، وكُتب `legal/LEGAL_REVIEW.md`.
* وافق المالك على تثبيت إلغاء التقريب بعد الإفصاح المالي — ق-48.
* اعتُمدت النصوص كمصدر رسمي وحيد — ق-49.
* فُتحت المسائل م-08 إلى م-12، وأُضيف التذكير ت-05، وحُدّثت حالة ت-03 إلى مُنفَّذ جزئيًا.
* كُتب `INSTALL_INTO_PROJECT.md` — خطوات نقل مجلد الوثائق إلى جهاز المالك.

**الدليل:** 19 ملفًا في `docs/`، و`DECISIONS.md` فيه 49 قرارًا متسلسلًا بلا فجوة.

**درس موثّق:** المالك لم يكن يعرف أين توجد الملفات المكتوبة. **من الآن: كل دفعة ملفات تُسلّم مع جملة واحدة تقول أين هي وكيف تُحمّل.**

## المرحلة صفر — بيئة التطوير: مكتملة بتاريخ 2026-08-13
- اعادة تسمية المشروع الى well-irrigation ونقل مجلد الذاكرة كاملا.
- تثبيت Flutter 3.47.0 و Android SDK كاملا، flutter doctor بلا اي تحذير.
- تشغيل Supabase محليا والتحقق من المخططات والجداول وسجل الترحيلات.
- بناء تطبيق تجريبي وتثبيته وتشغيله على جهاز اندرويد حقيقي بنجاح.
- انشاء مفتاح SSH، تفعيل التحقق بخطوتين، اخفاء البريد الشخصي من تاريخ المشروع.
- انشاء منظمة GitHub ومستودع خاص فارغ، ورفع تاريخ المشروع بنجاح مؤكد.

## 2026-08-13 — مرحلة قاعدة البيانات الكاملة: مكتملة ومُختبرة (25 هجرة)

**المخطط الأساسي (001–013):** تسعة مخططات، وأربعة عشر جدولاً، مبنية بالكامل وفق القرارات النافذة حتى ق-56 — تفصيلها في `technical/MIGRATIONS.md`.

**الأمان على مستوى الصف (014–017):** دالة `iam.has_well_role` + سياسات SELECT/INSERT/UPDATE/DELETE لكل جدول. **الدليل:** اختبار عزل مباشر بأربعة أدوار على بئرين منفصلين، ثمانية فحوصات مطابقة تمامًا للمتوقع. اكتُشف وصُحّح أن `ops.compute_session_charge` كانت `SECURITY INVOKER` ضمنيًا.

**التوفير التلقائي (018، 020):** ملف شخصي تلقائي عند التسجيل، وإعدادات بئر تلقائية عند الإنشاء — كلاهما اكتُشفت الحاجة إليهما باختبار مباشر فشل أولاً ثم صُحّح.

**رصد الجلسات والإشعارات (019، 021، 022):** دالتا رصد الجلسات الطويلة والمقتربة من الحد، وجدول إشعارات معزول بـ RLS. **الدليل:** اختبار ثلاثي مطابق تمامًا، واختبار إشعار مزدوج بعزل تام.

**دورة حياة توزيع الأرباح (023، 024، 025):** حساب صافي تلقائي، توزيع بطريقة أكبر الباقي (ق-21)، قفل نهائي بعد `finalized`، إشعار تلقائي لكل شريك. **الدليل:** اختباران مطابقان تمامًا، واختبار قفل برسالتي خطأ عربيتين واضحتين.

**ملاحظة أمانة موثّقة:** آلية أكبر الباقي نُفّذت واختُبرت بمثال تركيبي لا بمثال حي من بئر حقيقي للمالك، كما يشترط ت-01 حرفيًا. التفاصيل في `DECISIONS.md` (أسفل ق-66) و`REMINDERS.md` (ت-01، ت-09).

**الدليل الإجمالي:** 25 ملف ترحيل، كل واحد مُختبر فور كتابته، بلا أي بقايا بعد كل اختبار.

## 2026-08-13 (الدفعة الثالثة) — إغلاق المرحلة 1 (النواة)
**المواقع، بطاقة الشخص الموحدة، كتالوج الأدوار والصلاحيات (026–028):** مبنية ومختبرة محليًا عبر `npm run db:reset` + فحص مباشر بـ psql. الدليل: 7 جداول، 3 امتدادات، توليد رقم ظاهر فعال، فهارس trigram، 6 أدوار/21 صلاحية، عمود `location_id` بمفتاح خارجي، 15 سياسة RLS مطابقة للتصميم.
**فجوة موثّقة عمدًا:** كتالوج الأدوار غير مربوط بنظام الأدوار الحالي (م-18).
**الحالة:** المرحلة 1 من ترتيب البناء الموثّق مكتملة عمليًا. القرار: ق-68.

## 2026-08-13 (الدفعة الرابعة) — إغلاق المرحلة 2 (التشغيل)
**خطوط المياه، ملفات المزارعين، التسعير، الحجوزات، حجز الموارد، مقاطع الجلسة (029–034):** مبنية ومختبرة محليًا عبر `npm run db:reset` + فحص بنيوي مباشر بـ psql، ثم اختبار وظيفي كامل ببيانات تجريبية ذاتية الاكتفاء داخل معاملة `begin`/`rollback`. الدليل: 10 جداول جديدة، RLS مفعّلة على جميعها بعدد سياسات مطابق للتصميم، الدالتان `reserve_resource`/`validate_session_segment_overlap` والزناد يعملان، وكل حالات الاختبار (حجز صحيح ومرفوض، تعارض حجز موارد، تداخل مقاطع جلسة) أعطت النتيجة المتوقعة تمامًا.
**عطل مُكتشف ومُصحَّح:** `reserve_resource()` كانت تفشل دومًا لعدم إدراج `tenant_id`؛ صُحّحت لتستخرجه تلقائيًا من `core.wells`.
**فجوة موثّقة عمدًا:** `core.pumps` لا يطابق كامل §13.1 (م-19).
**الحالة:** المرحلة 2 من ترتيب البناء الموثّق مكتملة عمليًا. القرار: ق-69.

## 2026-08-13 (الدفعة الخامسة) — إغلاق المرحلة 3 (المال)
**دليل الحسابات، القيود اليومية وأطرافها، الفواتير وبنودها، تخصيص الدفعات (035–038):** مبنية ومختبرة محليًا عبر `npm run db:reset` (38 هجرة) + تحقق بنيوي بـ psql + اختبار وظيفي كامل داخل `begin`/`rollback`.
**الدليل:** 6 جداول جديدة، RLS مفعّلة، 18 سياسة، 4 دوال، زنادَي قفل القيود، و19 حالة اختبار كلها ناجحة — أهمها: دليل حسابات 26 حسابًا بلا تكرار، رفض القيد غير المتوازن، رفض تعديل قيد مُرحّل وأطرافه، رفض فاتورة تُخلّ بمعادلة `paid+outstanding=total`، وسداد جزئي 8000/12000 مع تخصيص صحيح للدفعة.
**تباعد موثّق:** مخطط `billing.payments` المبني يخالف §28 — لم يُمسّ، وسُجّل في م-20 لقرار المالك.
**الحالة:** المرحلة 3 من ترتيب البناء الموثّق مكتملة عمليًا. القرار: ق-70.

---

## المرحلة 4 — الديزل والمصروفات ✅ مكتملة (2026-08-13)

الهجرات 039 الى 046، الاجمالي 46 هجرة و49 جدولا.

- الدفعة الاولى (040-043): صندوق البئر، المناوبات، اقرار وتأكيد التسليم، نقل الجلسات، توسيع الدفعات، 15 نوع اشعار. اختبار 27/27.
- الدفعة الثانية (044-045): انواع المصروفات وزرعها، المصروفات بقيد المرفق، قواعد الاعتماد، ربط الجلسة بالمناوبة، تقرير المناوبة واجمالي المشغل.
- الدفعة الثالثة (046): خزانات الوقود وحركاته العشرة، المتوسط المرجح المتحرك، رصيد ديزل المزارع، جسر الشراء القديم، والمفتاح المؤجل journal_lines.fuel_tank_id.
- الدفعتان الثانية والثالثة: اختبار 25/25.

التالي: المرحلة 5 الشركاء.

---

## المرحلة 5 — الشركاء ✅ مكتملة (2026-08-14)

الهجرات 047 إلى 050، الإجمالي 50 هجرة و53 جدولًا.

- 047: جدول الشركاء مصدرًا وحيدًا للنسب وصلاحية المالك، دورا المدير والشريك، علم المدير العام، ترحيل الحصص القديمة وإسقاط جدولها، إعادة كتابة دالة التوزيع وإشعار الملاك.
- 048: سياسة سقي الشريك (دفع عادي / خصم من الأرباح) وربط المفتاحين المؤجلين.
- 049: الفترات الشهرية والسنوية، الإقفال المباشر، إعادة الفتح بـ 70% من عدد الشركاء ثم موافقة المدير العام، والخطوة 5 المؤجلة.
- 050: 120 سياسة مدير و49 سياسة شريك وُلّدت آليًا، وسياسات تعيين مقيدة للمدير.
- الاختبار الوظيفي: 23/23 بصفر فشل.

التالي: المرحلة 6 — الإدارة (محرك التوزيع الكامل §31، احتياطي الصيانة §32، الأرصدة الافتتاحية §33، الرواتب §29).

---

## المرحلة 6 — الإدارة ✅ مكتملة (2026-08-14)

الهجرات 051 إلى 056، الإجمالي 56 هجرة و60 جدولًا.

- 051: إصدارات نسب الشريك (ملكية/أرباح، تاريخ موثق، مانع تداخل) — تبنّي نموذج المرجع §16.
- 052: محرك التوزيع الكامل بدوراته (§39/§49) واحتياطي الصيانة (§38) ومفتاح الالتزامات المحتجزة؛ حذف جداول التوزيع القديمة.
- 053: إصلاح فحص found + علامتا منع الازدواج بين الدورات.
- 054: الأرصدة الافتتاحية (§41) — اعتماد المالك، قفل، ترحيل بقيد متوازن.
- 055: الرواتب (doc 02 §29) وقيود الديزل التلقائية (§26) وإصلاح توازن الأرصدة ومعامل الشريك في المصروفات.
- 056: حذف ازدواج record_expense وفحص التوازن عند الاعتماد.
- الاختبارات: 19/19 و17/17 بصفر فشل.

**بهذا تكتمل مراحل بناء قاعدة البيانات الست** حسب ترتيب doc 02 §47: النواة، التشغيل، المال، الديزل والمصروفات، الشركاء، الإدارة.

التالي: محطة تطبيق Flutter (أندرويد) — واجهات المالك والمشغل والشريك والمدير العام.

## 2026-08-14 — الدفعة الختامية (057–061) واكتمال محطة قواعد البيانات
- الحصيلة النهائية: 61 هجرة، 64 جدولًا أساسيًا، 5 عروض تقارير؛ المخططات: core و iam و ops و billing و finance و inventory و audit و sync و reporting.
- اكتملت في هذه الدفعة: سجل التدقيق، طبقة المزامنة وعدم تكرار الأوامر، المرفقات العامة، عروض التقارير الخمسة، والإجراءات المالية (ترحيل آلي للدفعات والمصروفات والفواتير + العكس الموثق بالسبب).
- الاختبار المالي الختامي: 17/17 PASS.
- المحطة القادمة: المرحلة 7 — تطبيق أندرويد (Flutter) للمشغل ثم لوحة الإدارة.

## 2026-08-14 — ق-76: سد فجوات التدقيق الشامل (062–063)
- التدقيق الشامل (وثائق ↔ منفذ) أثبت مطابقة 64 جدولًا وكل القرارات، وكشف 4 فجوات غير موثقة فحسب.
- بُني: كشف التكرار عند إنشاء شخص (تطابق = اسم+هاتف، شك = أحدهما، مع بيانات المرشح وخياري دمج/إنشاء) وإجراء الدمج الآمن مع سجل التدقيق، وقفل التشغيل المتزامن للمضخة بقواعد يضبطها المالك (الافتراضي 1).
- تأكد بالدليل الحرفي: قفل المناوبة على البئر مزدوج الحماية (قيد فريد + زناد برسالة عربية).
- وُثّق تأجيل farm_participants و farm_well_links، ومطابقة salary_payments سلوكيًا عبر pay_salary.
- الحصيلة: 63 هجرة، 66 جدولًا، 5 عروض؛ اختبار 062: 13/13 PASS.

## 2026-08-14 — دفعة إصلاحات ق-77 (064–065) عبر Codex
- أُغلقت ثلاث من الملاحظات الحرجة (C-02 لقطة السعر، C-03 يوم التقرير، C-05 إدخال الآبار) وثلاث متوسطة (M-01 شرط الملكية، M-03 عمود التقريب، M-05 تداخل سياسات الشريك).
- أسلوب عمل جديد مثبت: تنفيذ عبر وكيل مستقل + تحقق بقناة مستقلة ثانية قبل الالتزام.

## 2026-08-15 — الهجرة 066: طبقة إجراءات الجلسة الذرية
- دورة الجلسة أصبحت كاملة عبر إجراءات خادم مسماة (بدء/إيقاف/تغيير مصدر/استئناف/إكمال/إصدار فاتورة) — عقد التطبيق الوحيد للمشغل. إغلاق C-04.
- الجلسات المختلطة تُسعّر بمقاطعها المثبتة لحظة كل مقطع، بلا تقريب، مع حركات الوقود والقيد الآلي والتدقيق.
- الحصيلة: 66 هجرة؛ 4 ملفات اختبار دائمة؛ 56 فحصا كلها PASS بقناتين مستقلتين.

## 2026-08-15 — ختام محطة قاعدة البيانات (ق-77 نافذ ومنفذ بالكامل)
- حزمة قبول دائمة: 7 ملفات اختبار، 92 فحصا، تعمل بامر واحد وتفشل عند اول انحراف — معيار القبول الرسمي لاي تغيير مستقبلي.
- اكتملت جميع بنود ق-77: وحدة الريال (توثيقيا)، باقي القسمة لاكبر حصة (توثيقيا)، اصلاحات 064-066 (تنفيذيا بقناتين)، وحزمة الاختبارات.
- الحصيلة النهائية للمحطة: 66 هجرة، 66 جدولا، 5 عروض، 4 قيود منع تداخل، عزل كامل، سجل تدقيق، وتدقيقان مستقلان + 92 فحصا ذاتيا.

## 2026-08-15 — الهجرة 068: أزرار المال الكبرى مكتملة
- تسجيل الدفعة أصبح زرا واحدا ذريا بخطواته الـ13: يقبض، يخصص للفواتير، يحوّل الزيادة لرصيد مقدم، يوثق، ويعيد ايصالا — ويستحيل ان يبقى المال في حالة نصف مكتملة.
- دفع مستحقات الشركاء اصبح اجراء رسميا (جزئي/كامل) يحفظ المدفوع التراكمي ويحجز المتبقي فقط في الدورات اللاحقة.
- الحصيلة: 67 هجرة؛ 8 ملفات اختبار؛ 107 فحصات كلها PASS بقناتين مستقلتين.

## 2026-08-15 — الهجرة 069: اكتمال طبقة الإجراءات كلها (ت-11 مغلق)
- سبعة اجراءات تشغيل ذرية: انشاء مزارع وارض وحجز واعادة جدولة، وشراء وقود واستهلاكه وجرده الفعلي.
- بذلك صار لكل عملية في التطبيق القادم زر خادم واحد ذري ومختبر — مرحلة التطبيق اصبحت واجهة ومزامنة فقط.
- الحصيلة النهائية: 68 هجرة؛ 9 ملفات اختبار دائمة؛ 129 فحصا كلها PASS بقناتين مستقلتين.

## 2026-08-15 — الهجرة 070: حارسا الساعة مبنيان (م-23: المنطق منفذ)
- الملخص اليومي يولد من ارقام العرض الرسمي للمالك والمدير بلا تكرار، ومراقب الدين ينبه عند التجاوز ويصمت تحت الحد ويعود عند تجاوز جديد.
- تبقى من م-23 علامتان موثقتان: شاشة وقناة الاشعارات في المرحلة 7، وبند «تفعيل المجدول» الالزامي عند النشر.
- الحصيلة النهائية لمحطة القاعدة: 69 هجرة؛ 10 ملفات اختبار دائمة؛ 138 فحصا كلها PASS بقناتين مستقلتين.

## 2026-08-16 — ق-78: إغلاق الشرط الأول من بوابة جاهزية المرحلة 7

- أنشئ مخطط `api` كعقد Data API الرسمي لتطبيق Flutter.
- أصبحت Exposed Schemas هي `api` و`graphql_public` فقط؛ `public` و`ops` وبقية مخططات الأعمال ليست مكشوفة مباشرة.
- `api.health()` مسبار تقني SECURITY INVOKER؛ الخادم والمستخدم الموثق فقط يملكان EXECUTE صريحًا، وanon محجوب.
- كشف اختبار القبول خاصية PostgreSQL الخاصة بمنح EXECUTE الافتراضي إلى PUBLIC، وصُحح نمط الحماية إلى CREATE + REVOKE + GRANT داخل المعاملة نفسها مع مسح دائم لكل دوال api.
- الدليل النهائي: 70 هجرة؛ 11 ملف اختبار؛ 145 PASS؛ FAIL=0؛ ERROR=0؛ واختبارات PostgREST الحية ناجحة.
- الشرط الأول API Architecture مغلق. الشرط الثاني RPC-only writes ما زال مستقلًا ولم يُغلق ضمن ق-78.

## 2026-08-16 — ق-79: إغلاق Direct DML بالهجرة 072

- أزيلت جميع صلاحيات الكتابة الجدولية المباشرة من `anon` و`authenticated` على مخططات الأعمال الداخلية.
- نتيجة التدقيق بعد 072: Direct DML = صفر.
- بقيت إجراءات الأعمال الحرجة قابلة للتنفيذ.
- لا توجد SECURITY DEFINER قابلة للتنفيذ بواسطة authenticated بلا search_path صريح.
- حزمة القبول: 71 هجرة، 12 ملف اختبار، 154 PASS، بلا فشل أو خطأ.
- اختبارا 066 و069 فُصلا بين Fixtures الإدارية وسلوك المستخدم بعد ق-79.
- ق-79 لم يغلق كاملًا بعد؛ أغلفة الكتابة داخل api هي الخطوة التالية.

## 2026-08-17 — إغلاق الشرط 2: RPC-only writes

- أُغلق Direct DML بالكامل.
- أُنشئ واستكمل عقد الكتابة الرسمي داخل api.
- سطح api المثبت: 31 RPC.
- baseline: 73 هجرة، 14 اختبارًا، 178 PASS.
- بقي create_farm مؤجلًا إلى حسم م-22.
- التالي: الشرط 3 — تنظيف وتوحيد الوثائق الرسمية.

## 2026-08-17 — إغلاق الشرط 3: Documentation Conformance

- Documentation Acceptance = PASS.
- Cross-sync = PASS.
- baseline موحد: 73 migration / 14 tests / 178 PASS.
- API موحد: 31 RPC / Direct DML=0.
- الوحدة المالية موحدة إلى الريال الكامل وفق ق-77.
- باقي التوزيع موحد إلى صاحب أكبر حصة.
- API/Sync/Decision-Implementation موثقة في ملفات حاكمة مستقلة.
- فُصل Server Sync المنفذ عن Mobile Offline Sync المؤجل.
- التالي: الشرط 4، بدءًا بم-22 ثم م-19.

## 2026-08-17 — ق-80 / 075 محضرة

- حُسم م-22 بنيويًا بق-80.
- أُعدت 075 لتحويل Farm من Login Profile إلى Farmer Well Account.
- أضيف invariant دائم Farm ↔ Farmer Well Account للحجوزات والجلسات.
- أُعد `api.create_farm`.
- عُدلت Fixtures 066 و069 لتستخدم الهوية الميدانية الصحيحة.
- عُدلت Assertions التاريخية في 073/074 حتى تسمح بتوسعات API اللاحقة الآمنة.
- لا تعتبر 075 مطبقة أو مثبتة قبل تحقق المالك.

## 2026-08-17 — إغلاق ق-80 / م-22 / Condition 4A

- Migration 075 أعيد بناؤها بنجاح.
- اختبار 075 = 15 PASS.
- suite = 15 files / 193 PASS / 0 FAIL / 0 ERROR.
- Farm identity انتقلت من Login Profile إلى Farmer Well Account.
- Farm/Account mismatch محمي في Booking وSession.
- `api.create_farm` أصبح جزءًا من العقد.
- API surface = 32.
- Direct DML = 0.
- م-22 مغلقة.
- Condition 4A مغلق.
- التالي مباشرة: Condition 4B / م-19.

## 2026-08-17 — إغلاق ق-81 / م-19 / Condition 4

- `supabase db reset` طبق Migration 076 بنجاح.
- اختبار 076 = 12 PASS.
- suite = 16 files / 205 PASS / 0 FAIL / 0 ERROR.
- Pump model أصبح مطابقًا للنموذج المرجعي.
- reporting للطاقة أصبح مبنيًا على session segments.
- legacy flat fallback بقي متوافقًا.
- reservation concurrency أصبح يستخدم resource concurrency rules.
- م-19 مغلقة.
- Condition 4B مغلق.
- Condition 4 كله مغلق.
- التالي حصريًا: Condition 5 / Final Clean Acceptance.

## 2026-08-17 — Stage 7 Readiness Gate closed

اكتمل Final Clean Acceptance:

- clean reset نجح.
- suite = 16 files / 205 PASS / 0 FAIL / 0 ERROR.
- migrations = 75.
- Data API = 32 RPC.
- Direct DML = 0.
- API SECURITY DEFINER = 0.
- anon API EXECUTE = 0.
- exposed schemas = api + graphql_public فقط.
- final documentation cross-sync = PASS.
- Condition 5 مغلق.
- Stage 7 Readiness Gate مغلق بالكامل.


## 2026-08-17 — ق-82 / عقد تهيئة التطبيق للقراءة

أُضيفت Migration 077 واختبار دائم لعقد
`api.app_bootstrap()`.

أثبت التحقق الفعلي:

- إعادة بناء نظيفة حتى 077.
- اختبار 077 = 12 PASS.
- الحزمة الكاملة = 17 ملفًا / 217 PASS / 0 FAIL / 0 ERROR.
- Data API = 33 RPC.
- `app_bootstrap` ظاهر عبر Data API.
- Direct DML = 0.
- API SECURITY DEFINER = 0.
- anon API EXECUTE = 0.
- authenticated/service_role API EXECUTE = 33.
- API relations = 0.

عُدّل فحص تاريخي في اختبار 075 بحيث يحافظ على baseline
ذلك القرار مع السماح بإضافات API آمنة لاحقة؛ لم تتغير
Migration 075 ولا أي هجرة مطبقة سابقة.

الخطوة التالية قبل أي واجهة جديدة هي بوابة الهوية البصرية.


## 2026-08-17 — ق-83 / الهوية البصرية العامة

أغلق المالك بوابة الهوية البصرية العامة بعد مناقشة واعتماد
ثوابت الشعار المبدئي والألوان والخط والأيقونات والأسطح
والمسافات والصور والرسوم والحركة والحالات وDark Mode
وAccessibility وRTL وقواعد أصول الهوية.

أُنشئ المصدر التفصيلي:

`docs/design/VISUAL_IDENTITY.md`

الشعار الحالي معتمد مبدئيًا وقابل للتطوير لاحقًا.

لا توجد شاشة إنتاجية جديدة ناتجة عن هذا القرار حتى الآن.

الخطوة التالية:
مناقشة الصفحات والأقسام ثم تنفيذ المعتمد منها.

## 2026-08-18 — توثيق منهج العمل نفسه — ق-95 وق-96

**تم وثبت:**

- إضافة `AI_COLLABORATION_PROTOCOL.md`.
- إضافة `TERMINAL_COMMAND_PROTOCOL.md`.
- توثيق أسلوب الحوار والشرح.
- توثيق منهج القرار القابل للمراجعة.
- توثيق Workflow مناقشة/اعتماد/توثيق UX.
- توثيق الفصل بين Adopted/Documented/Implemented/Verified.
- توثيق طريقة قراءة Terminal Output.
- توثيق Shell safety.
- توثيق أسلوب كتابة Command Block.
- توثيق منع Base64 افتراضيًا.
- توثيق منع Nested Markdown Fences.
- توثيق Expected HEAD وWorktree guards.
- توثيق Recovery حسب مرحلة الفشل.
- توثيق Lessons Learned من حوادث الطرفية السابقة.

هذه دفعة توثيقية فقط.

لم تغير أرقام Baseline الخاصة باختبارات قاعدة البيانات.

## 2026-08-18 — بوابة التوثيق الإلزامية — ق-97

**تم في هذه الدفعة التوثيقية:**

- إنشاء `DOCUMENTATION_GATE.md`.
- جعل أسباب القرار جزءًا إلزاميًا من اكتمال التوثيق.
- توثيق شروط Decision/UX/Technical/Open Issue/Progress.
- توثيق شروط Changelog وResume وProject Map وMatrix.
- توثيق شروط Evidence وGit closure.
- توثيق Meta-documentation.
- توثيق Traceability من السبب إلى الاختبار والإنجاز.
- ربط البوابة ببروتوكولات Handoff/Collaboration/Terminal.
- إبقاء UX-13 كنقطة العمل التالية.

لم تشغل اختبارات قاعدة البيانات في هذه الدفعة،
لذلك لا تتغير أرقام Baseline التقنية المثبتة.

## 2026-08-18 — اعتماد وتوثيق UX-13 / ق-98

**المنجز المثبت في هذه الدفعة التوثيقية:**

- اعتماد قرارات UX-13 من 373 إلى 407.
- توثيق سجل جلسات السقي.
- توثيق Farmer/Farm UX.
- توثيق Booking UX.
- توثيق Shift/Handover UX.
- توثيق Offline booking pending confirmation.
- توثيق no-orphan active session rule.
- توثيق فصل Operational Transfer عن Cash Handover.
- إنشاء `OPERATIONS_RECORDS_ARCHITECTURE.md`.
- فتح م-28 للفجوات التنفيذية.
- تحديث API/Sync/Search architecture references.
- الانتقال المخطط إلى UX-14 بعد Documentation Gate.

هذه دفعة توثيقية فقط.

لم تنفذ Migration 078 ولم تشغل اختبارات قاعدة بيانات
جديدة، لذلك يبقى Baseline التقني السابق دون تغيير.

## 2026-08-18 — اعتماد وتوثيق UX-14 / ق-99

**المنجز المثبت في هذه الدفعة التوثيقية:**

- اعتماد UX-14 من القرار 408 إلى 459.
- توثيق Farmer Financial Account UX.
- توثيق فصل Debt عن Advance.
- توثيق Explicit Old Advance Allocation.
- توثيق Payment/Receipt/Offline behavior.
- توثيق Expense/Approval UX.
- توثيق Partner-paid expenses.
- توثيق فصل Ownership عن Profit Percentage.
- توثيق Historical Share Versions.
- توثيق Profit Distribution Review/Approval.
- توثيق Partial/Full Partner Payout.
- توثيق Accounting Period Close/Reopen.
- توثيق Financial Correction/Audit UX.
- إنشاء `MONEY_PARTNERS_ARCHITECTURE.md`.
- فتح م-29.
- تسجيل فجوة Attachment Skip Reason.
- تسجيل مراجعة Maintenance Reserve Rounding.
- تحديث API/Sync/Settlement architecture handoffs.
- تحديد UX-15 كنقطة العمل التالية.

هذه دفعة توثيقية فقط.

لم تنفذ Migration 078 ولم تشغل اختبارات قاعدة بيانات
جديدة، لذلك يبقى Baseline التقني السابق دون تغيير.

## 2026-08-19 — اعتماد وتوثيق UX-15 / ق-100

**المنجز المثبت في هذه الدفعة التوثيقية:**

- اعتماد UX-15 من القرار 460 إلى 526.
- توثيق Well Management UX.
- توثيق Pump Equipment UX.
- إعادة تأكيد Session Segments كمصدر Energy الحديث.
- توثيق Fuel Inventory/Physical Count/Reconciliation UX.
- إعادة تأكيد أن Fuel ليس Farmer Surcharge.
- توثيق Historical Pricing.
- حجب `operation_plus_fuel` عن V1 UX.
- توثيق Reporting UX.
- اعتماد Simple Charts للنسخة الأولى.
- اعتماد Bar وLine فقط في V1.
- اعتماد عدم وضع Chart في Owner Home في V1.
- تحديد Chart Locations.
- توثيق Drill-down وExact Values.
- توثيق Offline/Stale Chart behavior.
- ربط Chart Data بـBackend Aggregation.
- تحديث Visual Identity للرسوم.
- إنشاء `WELL_MANAGEMENT_REPORTING_ARCHITECTURE.md`.
- فتح م-30.
- تحديد UX-16 كنقطة العمل التالية.

هذه دفعة توثيقية فقط.

لم تنفذ Migration 078 ولم تشغل اختبارات قاعدة بيانات
جديدة، لذلك يبقى Baseline التقني السابق دون تغيير.

## 2026-08-19 — اعتماد UX-16A / ق-101

- فصل Account & Settings عن Platform Administration.
- اعتماد البنود 527–541 و543–583 و595–598.
- نقل البند 542 إلى PA.
- نقل كل Platform Administration إلى سلسلة مستقلة.
- اعتماد English digits.
- اعتماد English Date/Time display الثابت.
- اعتماد Forgot Password عبر OTP في V1.
- اعتماد Account-scoped Local State.
- اعتماد Logout دون حذف Pending Outbox.
- إنشاء `ACCOUNT_SETTINGS_ARCHITECTURE.md`.
- فتح م-31.
- تحديد PA-01 كنقطة العمل التالية.

دفعة توثيقية فقط.

Baseline الاختبارات لم يتغير.

## 2026-08-19 — اعتماد PA-01 / ق-102

- تعريف Platform Super Admin كمسؤول منصة مستقل.
- منع خلطه بOwner/Operator/Partner/Farmer.
- اعتماد Console مستقلة Web/Desktop-first.
- اعتماد Sidebar RTL ثابتة على اليمين.
- اعتماد Dashboard رقمية واسعة.
- اعتماد Wells/Accounts/Operations/Sync/Activation/Finance KPIs.
- اعتماد Near-real-time auto refresh.
- اعتماد Last Update عند Stale state.
- اعتماد Drill-down من KPIs.
- اعتماد Bar/Line Charts وفق ق-100.
- اعتماد ثلاثة سياقات Charts أولية للرئيسية.
- اعتماد Global Wells/Accounts/Finance/Operations monitoring.
- اعتماد Support/Audit/System Monitoring sections.
- اعتماد Trusted Backend boundary.
- تسجيل Password Visibility كمتطلب منتج معتمد
  لكنه غير منفذ ويحتاج قرارًا أمنيًا لاحقًا.
- إنشاء `PLATFORM_ADMINISTRATION_ARCHITECTURE.md`.
- فتح م-32.
- تحديد PA-02 كنقطة العمل التالية.

دفعة توثيقية فقط.

Baseline الاختبارات لم يتغير.

## 2026-08-19 — اعتماد PA-02 / ق-103

- اعتماد PA-02-01 إلى PA-02-57.
- اعتماد Global Search.
- اعتماد Global Account Administration.
- اعتماد Identity Resolution.
- اعتماد Account Suspend/Restore.
- اعتماد Session Invalidation.
- اعتماد Global Well Administration.
- اعتماد User Preview Read-only.
- اعتماد Support Case model.
- اعتماد Error References.
- اعتماد Administrative Correction flow.
- إعادة تأكيد Append-only Audit.
- اعتماد Password Option B.
- اعتماد Recoverable Encrypted Password Vault.
- اعتماد Platform Admin Current Password Reveal.
- توثيق أن Supabase Hash الحالية لا تسترجع Legacy Password.
- اعتماد Vault unavailable للحساب القديم حتى Password Rotation.
- اعتماد no plaintext at rest.
- اعتماد no local/outbox password cache.
- اعتماد Trusted Password Orchestrator.
- اعتماد Pending Vault Version قبل Auth Update.
- اعتماد stale/unavailable safety.
- توثيق أن ق-103 ينسخ فقط Password Non-Readability من ق-85.
- إنشاء `PLATFORM_ADMIN_ACCOUNTS_WELLS_SUPPORT_ARCHITECTURE.md`.
- فتح م-33.
- تحديد PA-03 كنقطة العمل التالية.

دفعة توثيقية فقط.

لم تنفذ Password Vault أو Migration 078+ بعد.

Baseline الاختبارات لم يتغير.

## 2026-08-19 — اعتماد ق-104 وق-105

**دفعة Governance + Security Documentation فقط.**

المنجز التوثيقي المثبت:

- اعتماد Research & Standards Gate.
- إنشاء `RESEARCH_STANDARDS_GATE.md`.
- إدخال البوابة في README/Handoff/Collaboration/Documentation Gate.
- اعتماد تصنيف Standards-aligned / Adapted / Exception.
- اعتماد Source of Truth → Standards → Platform → User Feedback → Project Fit.
- اعتماد Sticky Admin Search/Filters عند الحاجة.
- اعتماد Server-side Pagination/Filter/Sort للجداول الإدارية.
- اعتماد عدم استخدام Infinite Scroll كAdmin-table pattern أساسي.
- اعتماد Near-real-time hybrid بدل blind rapid polling.
- اعتماد Symptom-first Monitoring.
- اعتماد WCAG 2.2 AA للAdmin Web.
- اعتماد Platform Admin MFA.
- اعتماد Step-up للأفعال عالية الخطورة.
- اعتماد Secret-safe Audit/Logging.
- نسخ Password Option B من ق-103.
- إلغاء Recoverable Password Vault قبل التنفيذ.
- إلغاء Current Password Reveal.
- اعتماد Admin-triggered Force Reset.
- اعتماد OTP + user-chosen new password.
- تحديث م-33 إلى Password Recovery model.
- PA-03 ما زالت الخطوة التالية.

لم تنفذ:

- Migration 078+.
- Admin MFA.
- Password Recovery API.
- Flutter/Web production changes.

Baseline الاختبارات لم يتغير.

## 2026-08-19 — اعتماد PA-03 / ق-106

**دفعة توثيقية فقط.**

تم:

- اعتماد PA-03-01 إلى PA-03-64.
- اجتياز Research & Standards Gate للمقترحات.
- اعتماد الفصل بين Platform Commerce وWell Finance.
- اعتماد Sale مستقلة عن Entitlement.
- اعتماد Entitlement مستقلة لكل Well مشتراة.
- اعتماد Atomic Sale + Grant.
- اعتماد Idempotent Admin Commands.
- إعادة تأكيد Atomic Well + Entitlement Consumption.
- اعتماد Sale/Activation Correction دون History Rewrite.
- اعتماد Exceptional Consumed Entitlement intervention.
- اعتماد Global Operations Monitoring.
- اعتماد Offline-aware server visibility.
- اعتماد Administrative Session Closure.
- اعتماد Global Finance Read-first.
- إعادة تأكيد ق-99 للتصحيحات المالية.
- رفض Force Reopen bypass في V1.
- اعتماد Step-up وConfirmation integrity.
- اعتماد audited filtered exports.
- اعتماد Server-side Pagination/Filter/Sort.
- اعتماد PA-03 writes Online-only.
- تصحيح تعارض ق-10 مع ق-86/ق-106.
- تصحيح مواضع Password Vault الوثائقية القديمة.
- إنشاء `PLATFORM_ADMIN_SALES_OPERATIONS_FINANCE_ARCHITECTURE.md`.
- فتح م-34.
- تحديد PA-04 كالمناقشة التالية.

لم تنفذ Migration 078+ أو Admin APIs جديدة.

Baseline الاختبارات لم يتغير.

## 2026-08-19 — اعتماد PA-04 / ق-107

**دفعة توثيقية فقط.**

تم:

- اعتماد PA-04-01 إلى PA-04-86.
- اجتياز Research & Standards Gate.
- اعتماد Symptom-first Monitoring.
- اعتماد Actionable Alerting.
- اعتماد Alert dedup/grouping.
- اعتماد Incident Center.
- اعتماد Major Incident Postmortem.
- اعتماد Correlation IDs.
- اعتماد OpenTelemetry readiness دون Full rollout.
- إعادة استخدام `audit.audit_logs`.
- اعتماد Global Audit Admin Projection.
- اعتماد Secret Redaction.
- اعتماد Typed/Versioned Platform Configuration.
- اعتماد Validation + Rollback.
- اعتماد Feature Flags كUX/release لا Authorization.
- اعتماد Scoped Maintenance.
- حماية Offline Field Work أثناء Maintenance.
- اعتماد Recommended/Minimum/Required App Versions.
- اعتماد Release/Config/Migration change tracking.
- اعتماد Dependency Health.
- اعتماد Telemetry Privacy.
- اعتماد Admin Security View.
- رفض ordinary DB dump/one-click restore.
- اعتماد Final 12-section Platform Admin Sidebar.
- تأجيل SIEM/Public Status/Full OTel/Custom Admin Roles.
- إنشاء `PLATFORM_ADMIN_MONITORING_SETTINGS_ARCHITECTURE.md`.
- فتح م-35.
- إغلاق PA-01..PA-04 تصميميًا.
- تحديد UX-17 كالمناقشة التالية.

لم تنفذ Migration 078+ أو Monitoring/Admin APIs جديدة.

Baseline الاختبارات لم يتغير.

## 2026-08-19 — اعتماد UX-17 / ق-108

**دفعة توثيقية فقط.**

تم:

- اعتماد Final Cross-Cutting UX Review.
- اجتياز UX17 Research & Standards Gate.
- تثبيت canonical Offline/Sync user terminology.
- فصل connectivity عن sync state.
- اعتماد honest local/server success messaging.
- اعتماد stable connectivity/status placement.
- اعتماد item-level sync state للسجلات الحرجة.
- اعتماد form preservation.
- اعتماد clear error/confirmation states.
- اعتماد duplicate-submit prevention.
- إعادة تأكيد financial/sensitive review.
- اعتماد Loading/Empty/Error/Denied/Stale separation.
- اعتماد Android 48dp touch targets.
- اعتماد RTL/font scaling/accessibility semantics.
- اعتماد adaptive navigation/layout.
- اعتماد notification/support/privacy consistency.
- اعتماد back/context-switch safety.
- إنشاء `FINAL_CROSS_CUTTING_UX_ARCHITECTURE.md`.
- فتح م-36.
- إصلاح malformed ق-107 text في RESUME_POINT.
- إغلاق UX-00..UX-17 تصميميًا.
- إبقاء PA-01..PA-04 Design Complete.
- تحديد IMPLEMENTATION-01 كنقطة العمل التالية.

لم تنفذ Production UI أو Migration جديدة.

Baseline الاختبارات لم يتغير.

## 2026-08-19 — اعتماد IMPLEMENTATION-01 / ق-109

**دفعة تخطيط/توثيق فقط.**

تم:

- اعتماد W1–W10 implementation sequence.
- اعتماد dependency-based ordering.
- اعتماد coherent migrations بدل Migration عملاقة.
- إعادة تأكيد 071–077 immutable.
- اعتماد 078+ كبداية DB implementation الجديدة.
- اعتماد Vertical Slices بعد Foundations.
- وضع Offline/Background Sync في W2 قبل Critical Field UI.
- وضع Trusted Admin Backend قبل Admin Web.
- إنشاء `V1_IMPLEMENTATION_SEQUENCE.md`.
- فتح م-37.
- نقل Resume Point إلى W1 Backend Foundations.

لم تنفذ Migration 078 بعد.

Baseline الاختبارات لم يتغير.

## 2026-08-19 — W1-01 / ق-110 prepared

تمت كتابة:

- Migration 078 Profile↔Person identity foundation.
- Permanent Test 078.
- ق-110.
- وثائق W1-01.

الحالة:

**Pending Owner Verification.**

لم يشغل AI:

- db:reset.
- db:test.
- Docker verification.

لم يتغير Baseline الرسمي بعد.

التالي:

Owner runs Migration/Test verification.

---

## 2026-08-19 — Supabase Cloud baseline synchronized

ثبت بالدليل:

- المشروع المحلي مرتبط بالمشروع السحابي الصحيح.
- Migrations 001–077 نُشرت إلى Supabase Cloud.
- Remote migration history = 76 migrations through 077.
- Data API exposed schemas صارت `api` + `graphql_public`.
- `public` لم يعد Exposed Schema.
- تغيير Auth غير المقصود أثناء `config push` أُعيد إلى قيم Cloud السابقة بنجاح.
- Migration 078 لم تُنشر ضمن هذه المزامنة.

## 2026-08-19 — W1-01 / ق-110 locally verified

Owner Verification:

- `db:reset` طبق `20260819200401_078_profile_person_identity_links.sql`.
- Permanent Test 078 = 18 PASS / 0 FAIL / 0 ERROR.
- Full DB Suite = 18 files / 235 PASS / 0 FAIL / 0 ERROR.
- Local Applied Baseline صار حتى 078.
- Cloud Applied Baseline بقي حتى 077.

التالي:

Documentation Gate → Commit/Push → Cloud deploy/verify 078 → W1-02.

---

## 2026-08-19 — W1-01 / ق-110 Cloud verified

- Remote migration history = 77 migrations through 078.
- `iam.profile_person_links` موجودة وRLS enabled.
- Direct client table privileges = none.
- `iam.current_person_id(uuid)` مطابق لق-110.
- API surface = 33 authenticated RPC / 0 anon / 0 SECURITY DEFINER.
- صفوف روابط الهوية أثناء التحقق = 0.
- Local Permanent Test 078 = 18 PASS.
- Full DB Suite = 235 PASS / 0 FAIL / 0 ERROR.

W1-01 مكتملة ضمن نطاقها المعتمد.
التالي: W1-02 / م-16.
Migration 071–078 immutable؛ أي DB change جديد = 079+.

---

## 2026-08-19 — W1-02 / ق-111 locally verified

المالك شغّل التحقق الفعلي بعد إضافة Migration 079:

- `db:reset` طبق 079.
- Permanent Test 079 = 20 PASS / 0 FAIL / 0 ERROR.
- Full DB Suite = 19 files / 255 PASS / 0 FAIL / 0 ERROR.
- Farmer private data = Self-only.
- Farmer account في بئر بلا well_assignment بقي قادرًا على عرض بياناته الذاتية دون صلاحية إدارية.
- Owner/Staff visibility regression = PASS.
- API surface لم تتوسع.
- Direct DML بقي صفرًا.

الحالة: Implemented + Local Verified؛ Cloud pending.

---

## 2026-08-19 — W1-02 / ق-111 Cloud verified

Cloud verification بعد نشر Migration 079:

- Remote migration history = 78 through 079.
- Farmer self-scope policies = 19.
- legacy Farmer broad policies في نطاق W1-02 = 0.
- Target tables with RLS disabled = 0.
- Supporting RLS indexes = 9.
- Farmer self helpers تحمل security mode والمنح والـsearch_path المعتمد.
- API = 33 authenticated / 0 anon / 0 SECURITY DEFINER / 0 relations.
- Direct DML = 0.
- لا Security Advisor warning جديد من Migration 079.

النتيجة:

W1-02 مكتملة.
م-16 مغلقة.
Migration 071–079 immutable.
التالي W1-03 / م-18.

---

## 2026-08-21 — W1-03 / ق-112 locally verified

المالك شغّل التحقق الفعلي بعد إضافة Migration 080:

- `db:reset` طبق 080.
- Permanent Test 080 = 20 PASS / 0 FAIL / 0 ERROR.
- Full DB Suite = 20 files / 275 PASS / 0 FAIL / 0 ERROR.
- Permission catalog = 38؛ new V1 codes = 17.
- Role permissions = 70 (owner 38 / manager 12 / operator 20).
- partner/accountant/viewer write grants = 0.
- Bridge rows = 6؛ farmer map rows = 0.
- `iam.has_well_permission` = STABLE + SECURITY DEFINER + fixed `search_path`؛ authenticated فقط.
- Legacy `has_well_role` policies = 273 دون تغيير.
- manager/operator authority regression = PASS بلا توسع.
- inactive assignment = deny.
- Cross-well permission leak = 0.
- multi-role = Union بلا owner escalation.
- API surface لم تتوسع (33 authenticated / 0 anon / 0 SECURITY DEFINER).
- Direct DML بقي صفرًا.

Local baseline: 79 migration files، أعلى رقم 080، و20 permanent test file.

الحالة: Implemented + Local Verified؛ Cloud pending.

م-18 لم تغلق بـ080 — الإنفاذ انتقل في Migration 081+082 وأُغلقت هناك بق-113.

---

## 2026-08-21 — W1-03a Cloud verification closure

المالك أعاد بناء المشروع السحابي من الصفر ثم شغّل التحقق:

- المشروع السحابي السابق تعذّر الوصول إليه (بريد الحساب)؛
  أُنشئ حساب ومشروع جديدان في South Asia (Mumbai).
- لا شيء فُقد: لا بيانات إنتاجية ولا مستخدمين حقيقيين ولا
  مرجع للمشروع القديم في أي ملف متتبَّع.
- طُبقت الـ79 migration كلها بالترتيب من 001 إلى 080، كلها OK.
- قناة النشر العاملة الوحيدة = Supavisor transaction mode
  (المنفذ 6543)؛ المنفذ 5432 والاتصال المباشر IPv6 لا يصلان
  من شبكة المالك.
- ضُبطت Exposed schemas = `api` أولًا ثم `graphql_public`؛
  `public` غير مكشوفة.

Cloud verification لـ080 = 20 / 20:

- Remote migration history = 79 through `20260819235001`.
- Permission catalog = 38؛ new codes = 17.
- Bridge rows = 6؛ farmer map rows = 0؛ Bridge RLS enabled.
- Role permissions = 70 (38 / 12 / 20)؛
  partner + accountant + viewer = 0.
- `iam.has_well_permission` = SECURITY DEFINER + STABLE +
  fixed `search_path`؛ authenticated فقط؛ anon = no.
- `core.well_assignments` role constraint = مطبق.
- Legacy `has_well_role` policies = 273 دون تغيير.
- API = 33 authenticated / 0 anon / 0 SECURITY DEFINER /
  0 relations.
- Direct DML = 0.
- النتيجة = `CLOUD_080_ALL_PASS`.

Data API boundary من خارج قاعدة البيانات:

- Default exposed schema = `api`؛ anon مرفوض.
- `core` / `iam` / `public` / `audit` / `reporting` = محجوبة.
- جداول عبر `api` = 0.
- النتيجة = `DATA_API_BOUNDARY=OK`.

النتيجة:

W1-03a مكتملة ومغلقة.

## W1-03b — نقل الإنفاذ إلى الصلاحيات (081 + 082 / ق-113)

**مكتملة ومتحقق منها محليًا وسحابيًا — 2026-08-22.**

كل «باب» في النظام كان يسأل «ما مسمّاك الوظيفي؟» بقائمة
مسميات مكتوبة داخل الباب نفسه. صار يسأل «هل تحمل مفتاح هذا
الإجراء؟» والجواب من جدول واحد. تعديل صلاحية صار تعديل صف
يسري في اللحظة بدل تعديل كود وإعادة نشر.

**النقل:** 28 موضع حرس حي في 27 دالة، مقسّمة دفعتين:
081 = 13 موضعًا ماليًا، 082 = 15 موضعًا تشغيليًا.

**البرهان قبل الكتابة:** لكل موضع من الـ29 قُورنت مجموعة
الأدوار المسموح لها الآن بمجموعة ما يمنحه الكتالوج:
28 EQUIVALENT / 1 MISSING_CODE / **0 DIFFERS** =
`NO_SILENT_DRIFT`. ثم diff آلي على الناتج: 27 دالة، صفر
تغيير غير مقصود، خصائص الأمان متطابقة بايتًا ببايت.
ثم تدقيق 283 إشارة عمود مقابل البنية الفعلية = صفر خطأ.

**ما كشفه المسح الآلي ولم يكشفه اليدوي:**

- مواضع الحرس = 29 لا 23؛ ستة مغفلة، منها حرسان في
  `api.close_shift` وحده.
- `ops.change_session_energy_source` بلا permission code
  إطلاقًا؛ أُنشئت `session.energy.change` ومُنحت لـowner +
  manager + operator حرفيًا كما كان الحرس.
- `shift.close_override` موجودة أصلًا وبيد tenant_owner
  وحده — مطابقة لحرسَي `close_shift` بلا منح جديد.
- موضع ميت: 075 تُسقط `ops.create_farm(uuid,text,uuid)` من
  069؛ نقل جسد 069 كان سيُحيي المُسقط ويلغي تحسين 075
  صامتًا. المواضع الحية = 28.
- أربع دوال تفوّض بالهوية لا بالدور؛ تحويلها كان سيمنع
  المشغّل من تسليم نقده أو جلسته.

**دليل التحقق المحلي:**

- Permanent Test 081 = 20 PASS / 0 FAIL / 0 ERROR.
- Permanent Test 082 = 20 PASS / 0 FAIL / 0 ERROR.
- Full DB Suite = 22 files / 315 PASS / 0 FAIL / 0 ERROR.
- **صفر Regression:** 295 فحصًا من جولات سابقة مبنية على
  السلطة القديمة مرّت كلها بعد استبدالها.
- Function-body guards على `has_well_role` = 0.
- Legacy RLS policies = 273 دون تغيير، وهي مستهلكها الوحيد.
- Catalog = 39؛ grants = 73 (owner 39 / manager 13 /
  operator 21).
- owner = الـ13 المالية والـ14 التشغيلية كما قبل النقل؛
  manager = سلطة الجلسة فقط تشغيليًا؛ operator = الميدان
  كاملًا بلا `farm.create` وبلا `shift.close_override`.
- partner / viewer = 0؛ farmer = 0 سلطة تشغيلية مع بقاء
  نطاقه الذاتي؛ inactive assignment = 0.
- Cross-well leak = 0؛ anonymous = 0؛ unknown code = false.
- سحب منح واحد يسري في اللحظة، والدور يبقى، وبقية المنح
  لا تتأثر.
- API = 33 authenticated / 0 anon / 0 SECURITY DEFINER.
- Direct DML = 0.

**دليل التحقق السحابي — 2026-08-22:**

- Remote migration history = 81 through `20260822013001`.
- Cloud Test 081 = 20 PASS؛ Cloud Test 082 = 20 PASS.
- النتيجة = `CLOUD_W1_03B_ALL_PASS`.

**أثر جانبي معالَج:** اختبار 080 كان يؤكد الكتالوج = 38
والمنح = 70؛ حُدّث إلى 39 و73. ملف Migration 080 نفسه لم
يُمسّ — المعدَّل ملف اختباره فقط.

**النتيجة:** **م-18 مغلقة.** W1-03 مكتملة ومغلقة.
Migration 071–082 immutable.
أي DB change جديد يبدأ 083+.
*(هذان السطران يمثلان حالة 2026-08-22 عند إغلاق W1-03b؛
تجاوزهما قسم W2-01 أدناه إلى 071–084 و085+.)*

خارج النطاق عمدًا: نقل 273 RLS policy إلى Permission Codes
يحتاج دفعة مستقلة. `partner` / `accountant` / `viewer`
بصفر منح بالتصميم فلا تعرضها أي واجهة قبل قرار صريح.

## W2-01 — حماية التكرار على الخادم (083 + 084 / ق-114)

**مكتملة ومتحقق منها محليًا وسحابيًا — 2026-08-22.**

### المشكلة التي كانت قائمة فعلًا

مشغّل في المزرعة بلا شبكة يسجّل دفعة 500 من مزارع. ترجع
الشبكة فيرسل التطبيق العملية. الخادم ينفّذها ويردّ «تم»،
**لكن الردّ يضيع** في الشبكة الضعيفة. التطبيق لم يسمع شيئًا
فيعيد الإرسال، والخادم يستقبلها كأنها عملية جديدة تمامًا —
لأنه لم يكن يملك أي وسيلة ليعرف أنها نفسها.

**النتيجة: دفعتان بدل واحدة، والحساب يقول 1000.**

لم يكن هذا احتمالًا نظريًا؛ كان السلوك الحتمي، وضعف الشبكة
هو الحالة الطبيعية في بيئة العمل.

### ما صار عليه الحال

إرسال نفس العملية مرتين ⟹ **سجل واحد، مبلغ واحد، ونفس
النتيجة المُعادة حرفيًا**. إعادة الإرسال صارت آمنة بدل أن
تصبح دفعة ثانية.

الأدوات كانت موجودة في المستودع من الهجرة 058 — جدول
لتسجيل العمليات ودالتان لبدئها وإنهائها — لكن **لا شيء كان
يستدعيها**. ولا واحدة من 33 دالة كتابة تقبل معرّف عملية.
بنية مبنية وغير موصولة. هذه الجولة وصلتها.

**النطاق = الدورة الميدانية الأولى، 8 عمليات:** بدء الجلسة،
الإيقاف المؤقت، الاستئناف، تغيير مصدر الطاقة، الإنهاء،
تسجيل الدفعة، إنشاء مزارع، إنشاء أرض.

خارج النطاق عمدًا: الورديات ونقل الجلسة والحجوزات (ق-98)
والمصروفات والتوزيعات (ق-99) — بنفس النمط بعد إثباته.

### القرارات التي شكّلت التنفيذ

- **العميل لا يُرسل الجهة أبدًا.** تُستخرَج على الخادم من
  البئر أو الجلسة. لو وصلت من العميل لأمكن حجز معرّف عملية
  في جهة أخرى فتبدو عملية الضحية «مكرَّرة» فلا تُنفَّذ.
- **حدّ نطاق لا قرار صلاحية.** المُحلِّل يشترط تعيينًا نشطًا
  على البئر بلا اشتراط دور؛ قرار الصلاحية يبقى في الدوال
  الداخلية (ق-113). والشرط مبرهن أنه لا يرفض شيئًا كانت
  الدالة الداخلية ستقبله، لأن `iam.has_well_permission` نفسها
  تشترط التعيين النشط (`080:243`).
- **توافُق خلفي حرفي.** بلا معرّف عملية = المسار القديم بلا
  أي فرق، فلا يتغير سلوك أي مستخدم حالي.
- **استبدال التوقيع لا إضافته**، لأن سطح `api` مقفل على 33
  دالة بخمسة اختبارات؛ إضافة نسخة ثانية كانت ستجعله 41.
- **لا حالة عالقة ولا مُنظِّف دوري.** استدعاء واحد =
  transaction واحدة؛ العملية المرفوضة تتراجع بكاملها بما
  فيها صفّ الحجز، فلا يبقى أثر وإعادة المحاولة آمنة.
- **تقوية مصاحبة:** دالتا 058 كانتا ممنوحتين لـ`PUBLIC`
  افتراضيًا ولم تُسحبا قط، وهما تأخذان الجهة بلا تحقق؛
  سُحبت المنح.

### دليل التحقق المحلي

- Migration 083 + 084 طُبقتا ضمن `db:reset` بنجاح.
- Permanent Test 083 = 16 PASS / 0 FAIL / 0 ERROR.
- Permanent Test 084 = 23 PASS / 0 FAIL / 0 ERROR.
- Full DB Suite = **24 files / 354 PASS / 0 FAIL / 0 ERROR**.
- **صفر Regression:** 315 فحصًا من جولات سابقة مرّت كلها.
- نفس المعرّف مرتين ⟹ صفّ واحد ونفس النتيجة، للثماني كلها.
- `record_payment`: **الإجمالي لم يتضاعف** — الفحص يقيس
  المبلغ لا عدد الصفوف فقط.
- بلا معرّف ⟹ السلوك القديم حرفيًا؛ بمعرّف مختلف ⟹ عمليتان
  فعلًا (لا حجب زائد).
- معرّف محجوز في جهة أخرى لا يحجب عملية هذه الجهة.
- الغريب وصاحب التعيين غير النشط = ممنوعان؛ و«بئر جهة أخرى»
  و«بئر غير موجود» يعطيان الرسالة نفسها فلا يُكشف وجود
  معرّفات جهات أخرى.
- دالتا 058 = صفر منح لـ`public`/`anon`/`authenticated`.
- المُحلِّلات الأربعة = definer بمسار بحث مثبَّت، لـ
  `authenticated` و`service_role` فقط، و`anon` = صفر؛ ولا
  واحد منها يقبل معامل جهة أو يتخذ قرار صلاحية.
- API = 33 authenticated / 0 anon / 0 SECURITY DEFINER.
- Direct DML = 0.

### دليل التحقق السحابي — 2026-08-22

- Remote migration history = **83 through `20260823013001`**.
- Cloud Test 083 = 16 PASS؛ Cloud Test 084 = 23 PASS.
- النتيجة = **`CLOUD_W2_01_ALL_PASS`** (39 / 0 / 0).
- `API_SURFACE/ANON/DEFINER/DIRECT_DML = 33/0/0/0`.
- `DATA_API_BOUNDARY=OK`.

### أثر جانبي معالَج

اختبارا 073 و075 كانا يؤكدان توقيعي `api.create_farm` و
`api.start_irrigation_session` بعدد الوسائط القديم، فأُضيف
الوسيط الأخير إلى النص المتوقَّع في موضعين محدَّدين فقط.
السطر الذي يرفض توقيعًا زائدًا في 073 بقي كما هو، وموضع
`ops.create_farm` الداخلية في 075 لم يُمسّ. ملفا Migration
073 و075 أنفسهما لم يُمسّا.

### ملاحظة مكتشفة أثناء التحقق — ليست من هذه الجولة

دفعة الرصيد المقدم (بلا فاتورة جلسة) تُكتب بنجاح لكنها
**لا تُقرأ** عبر دور التطبيق، لأن سياسة قراءة قديمة
(`016:45`) تشترط ارتباط الدفعة بفاتورة جلسة. الأثر العملي:
المشغّل — وهو من يستلم النقد — لن يرى الدفعة على شاشته حين
تُبنى شاشة الدفعات. سلوك قائم قبل ق-114 ولا علاقة له بها؛
سُجّل في م-29 ولا يوقف هذه الجولة.

### النتيجة

**م-25 تضيق ولا تُغلق.** الخادم صار جاهزًا لاستقبال إعادة
إرسال آمنة، ولم يُبنَ بعد ما يعيد الإرسال: طابور الهاتف
ومعرّفات العمليات الثابتة والعمل الخلفي وجاهزية الجهاز
وشاشات الحالة وتصنيف التعارض تبقى مفتوحة كلها.

Migration 071–084 immutable.
أي DB change جديد يبدأ 085+.

---

## W2-02a — طابور الجهاز الدائم (ق-115)

**التاريخ:** 2026-08-23.
**التحقق:** **نجح** — `flutter analyze` = `No issues found!`؛
`flutter test` = **69 PASS / 0 FAIL**، ومنها ملف SQL الحقيقي عبر
`sqflite_common_ffi`.
**تغيير قاعدة البيانات:** **صفر.** لا Migration، ولا اختبار
SQL، ولا نشر سحابي.

### المشكلة التي كانت قائمة فعلًا

جولة W2-01 بنَت النصف الخادمي: الخادم صار يميّز العملية
المكرَّرة ويعيد نفس النتيجة بدل تنفيذها ثانية. **لكن لا شيء
في الهاتف كان يُرسل معرّفًا ثابتًا**، فالحماية موجودة وغير
مستعملة.

والتطبيق كان **6 ملفات Dart وشاشة فحص واحدة** لا تحفظ شيئًا
على الجهاز: كل ما يسجّله المشغّل يضيع لحظة إغلاق التطبيق أو
نفاد البطارية.

### ما صار عليه الحال

`apps/mobile/lib/core/sync/` — 13 ملفًا:

- `command_type.dart` — الثماني: اسم دالة `api`، وسيط الجهة،
  وسيط وقت الحدث، مفتاح النتيجة، نوع الكيان المُنتَج.
- `command_envelope.dart` — المغلَّف؛ يرفض في المُنشئ أي
  حمولة تحمل `p_command_id` أو وسيط وقت الحدث (مصدر واحد
  لكل قيمة، فلا مفتاح يُهمَل بصمت).
- `command_reference.dart` — `{"$ref": ..., "kind": ...}`
  وجمعه وحلّه من أي عمق في الحمولة.
- `command_id_generator.dart` — UUIDv4 من `Random.secure()`،
  قابل للحقن.
- `sync_status.dart` — حالات ق-108 بنصوصها العربية المعتمدة.
- `outbox_store.dart` — البوابة المجرَّدة + النماذج.
- `in_memory_outbox_store.dart` + `sqlite_outbox_store.dart`
  — تنفيذان: الاختبار والجهاز.
- `retry_classification.dart` — يُعاد مقابل يحتاج مراجعة.
- `command_transport.dart` + `supabase_command_transport.dart`
  — بوابة الإرسال وتنفيذها فوق `schema('api').rpc(...)`.
- `outbox_repository.dart` — **مسار الإدخال الوحيد**، وهو
  المستدعي الوحيد لمولّد المعرّفات.
- `sync_engine.dart` — حلقة الإرسال المرتَّبة والحجز وحلّ
  المراجع.

`apps/mobile/test/core/sync/` — 7 ملفات اختبار، كلها تعمل
**بلا هاتف وبلا شبكة وبلا قاعدة بيانات**، ومنها ملف يعيد نفس
السلوك على SQL حقيقي عبر `sqflite_common_ffi`.

### الثوابت المفروضة بنيويًا لا بالانتباه

1. **`command_id` فريد على مستوى الجدول، ويُكتب في `INSERT`
   فقط.** لا setter، ولا عمود `command_id` في أي `UPDATE` في
   المستودع كله. توليد معرّف جديد لكل محاولة يُبطل حماية
   ق-114، فجُعل ممتنعًا لا متروكًا للانتباه.
2. **الحجز تحديث شرطي** يُعتمد على عدد الصفوف المتأثرة،
   ويكتب وقت المحاولة. فصار للحجز عمر معروف: حجزٌ جارٍ الآن
   لا يُمَس، وحجزٌ مات التطبيق في منتصفه يُستعاد بعد مهلة
   بنفس المعرّف. هذا نفس الأساس الذي يجعل «المزامنة اليدوية
   لا تكرّر عمل العامل التلقائي» صحيحًا لاحقًا بلا إعادة
   تصميم.
3. **الربط يُكتب قبل التأكيد.** موت التطبيق بين الخطوتين
   يُشفى من نفسه لأن إعادة الإرسال تعيد نفس المعرّف؛ الترتيب
   المعاكس كان سيترك الأوامر التابعة بلا معرّف أصلها للأبد.
4. **الوقت UTC دائمًا** في التخزين والإرسال، فتغيير المنطقة
   الزمنية على الجهاز لا يغيّر وقت حدث محفوظ.

### القرارات التي شكّلت التنفيذ

- **ق-115 — هوية الجلسة:** الربط الدائم المحلي↔الخادمي، لأن
  `api.start_irrigation_session` لا تقبل معرّف جلسة من
  العميل، وإعادة الإرسال تعيد نفس المعرّف حرفيًا. النموذج
  الآخر كان يحتاج Migration 085+ على دالة مختومة.
- **الرمز المجهول يُصنَّف «مراجعة»** لا «إعادة». حلقة إعادة
  لا نهائية على عملية مال مرفوضة أسوأ من انتظار قرار بشري.
- **`sqflite`** لأن الوثيقة تفوّض الاختيار للتنفيذ، ولأنها
  بلا توليد كود فلا خطوة بناء إضافية.
- **لا عمود `depends_on_local_id`** رغم وروده في مخطط الخطة:
  التبعية بين الأصول محسومة بالمراجع، وداخل الأصل بالتسلسل،
  فالعمود آلية ثالثة زائدة تحتاج صيانة بلا مقابل.

### ما تُبرهنه الحزمة

- ثلاث محاولات إرسال ⟹ **معرّف واحد**، وتنفيذ واحد،
  وعدّاد محاولات = 2.
- **ضياع الردّ:** الخادم نفّذ وخزَّن ثم انقطع الردّ ⟹ إعادة
  الإرسال تعيد النتيجة المخزونة ⟹ **سجل واحد، مبلغ واحد،
  محاولتان.**
- **الموت والعودة:** الأمر يُقرأ من ملف قاعدة أُعيد فتحه من
  نسخة مخزن جديدة تمامًا، بنفس المعرّف ونفس التسلسل ونفس وقت
  الحدث.
- `START → PAUSE → RESUME → COMPLETE` تُرسل بهذا الترتيب؛
  وحدثٌ لجلسة لم تُحسم لا يُرسل، وبئر أخرى تكمل بلا انتظار.
- دورة كاملة بلا شبكة (مزارع ⟶ أرض ⟶ جلسة ⟶ دفعة) تُحسم
  مراجعها كلها عند الإرسال، ولا يبقى مرجع غير محسوم في أي
  وسيط مُرسَل.
- `already_exists` ⟹ الربط يشير للكيان القائم بلا إنشاء
  مكرَّر، والأرض ترتبط به.
- رفض عملي ⟹ «يحتاج مراجعة» ولا يُعاد إرساله إطلاقًا.
- حلقتان متزامنتان ⟹ الأمر يُرسل **مرة واحدة**.
- وقت الحدث المُرسل = وقت الميدان لا وقت المزامنة.
- عزل الحساب، وعدّاد ترتيب لكل حساب، والخروج لا يحذف الطابور.

### النتيجة

**م-25 تضيق ثانيةً ولا تُغلق.** العملية المسجَّلة لم تبقَ
معرَّضة للفقدان ولا للتكرار، **لكن الإرسال يحتاج أن يكون
التطبيق مفتوحًا**. الإرسال الخلفي والاستعادة بعد إقلاع الهاتف
وسجل الجلسة النشطة وشاشات الحالة والجاهزية وأي واجهة ميدانية
تبقى مفتوحة.

Migration 071–084 immutable.
أي DB change جديد يبدأ 085+.

---

## W2-02c — سجل الجلسة النشطة والاستعادة (ق-116)

**التاريخ:** 2026-08-23.
**النطاق:** `apps/mobile/lib/core/session/` — 5 ملفات إنتاجية،
و`apps/mobile/test/core/session/` — 4 ملفات اختبار.
**صفر تغيير على قاعدة البيانات.**

### التحقق — نتيجة فعلية (2026-08-23)

`flutter analyze` = `No issues found!`
`flutter test` = **115 PASS / 0 FAIL** (خط الأساس السابق 69).

التشغيل الأول أعاد 3 ملاحظات «استيراد غير مستخدم» فقط
(لا أخطاء)، أُزيلت. ولم يسقط أي اختبار.

### المشكلة

بعد ق-115 صارت العملية الميدانية محفوظة ولا تُفقد ولا تُكرَّر.
لكن لم يكن هناك من يجيب: **ما حالة الجلسة الآن؟** بند 16 من
`ACTIVE_SESSION_ARCHITECTURE.md` يُلزم أن تُستعاد الجلسة بعد
موت التطبيق ويمنع الاعتماد على `Timer` في الذاكرة، ولا يقول
من أين تُستعاد.

### ما صار عليه الحال

الجلسة تُعاد **إعادة تشغيل** من الطابور. لا جدول حالة محلي،
ولا كتابة ثانية، ولا كائن حيّ في الذاكرة يُعتمد عليه. مصدر
الحق واحد: الأحداث المحفوظة.

### الثوابت المفروضة بنيويًا

1. **القسمة على كل مقطع ثم الجمع** — نفس Migration 066
   حرفيًا، فما يراه المستخدم حيًّا يطابق فاتورته.
2. **حالة السقي وحالة المزامنة حقلان لا حقل** — ملف الحالة
   العملية لا يستورد من `core/sync/` شيئًا، فالفصل بنيوي.
3. **لا مدة سالبة ولا مبلغ سالب**: وقتٌ مقلوب يُثبَّت على
   بداية المقطع ويُرفع علمه، ولا يُطرح ريال من مستحق مزارع.
4. **بلا سعر: لا رقم** — نصّ الانتظار المعتمد، والزمن المقاس
   يُعرض على أي حال.

### خلل وُجد وأُصلح داخل الجولة

الصياغة الأولى للمُسقِط كانت تشتق القراءة التصاعدية من
المرساة نفسها، فصارت المقارنة بين الرقم ونفسه و**استحال رفع
علم تعديل الساعة**. كُشف عند كتابة الاختبار الذي يُبرهنه.
صار المُسقِط يستقبل `SessionTimeContext` = مرساة + قراءة
جهاز، فرفع العلم صار ممكنًا واختباره صار حقيقيًا.

### ما تُبرهنه الحزمة (46 اختبارًا جديدًا)

- **الاستعادة على قرص حقيقي:** الأحداث تُكتب في ملف، يُغلق
  المخزن كأن التطبيق مات، وتُفتح **نسخة جديدة تمامًا** ⟹
  الحالة والزمن المحتسب والتوقف ومصدر الطاقة والدفعات
  وحالة المزامنة تعود كلها متطابقة.
- **العدّاد بلا كائن حيّ:** نفس الملف يُقرأ في لحظتين
  فيتقدّم العدّاد 60 ثانية ثم 3600، بلا أي `Timer`.
- **القسمة على المقاطع:** مقطعان 100 ثانية بسعر 3599 ⟹
  **198 لا 199**.
- **الكسر يُقتطع ولا يُقرَّب**، والتوقف لا يضيف ريالًا.
- **تقديم ساعة الهاتف 3 ساعات:** المحتسب يبقى 600 ثانية
  والمستحق 600 ريال، والعلم مرفوع — لا 10800 ريال على
  المزارع.
- **إعادة الإقلاع:** تُعلَن ولا تُخفى، والجلسة تعود جارية.
- **تغيير الطاقة أثناء التوقف لا يستأنف السقي.**
- **الدفعة المحلية لا يقال عنها «مُرحَّلة»** قبل معرّف خادمي،
  والزيادة على المستحق تبقى ظاهرة بلا مقاصّة صامتة (ق-99).
- **محاولة فاشلة واحدة لا ترفع الحالة إلى حرجة**، والسقي
  يبقى جاريًا في كل حالات المزامنة.
- **عزل الحساب** (ق-101)، وجلستان لبئرين تُستعادان مرتَّبتين.
- **حدث بلا أمر بدء لا يخترع جلسة.**
- **أرض أُنشئت بلا اتصال** تُعرض بمعرّفها المحلي لا بمرجع خام.

### النتيجة

**م-25 تضيق ثالثةً ولا تُغلق.** الجلسة صارت تُستعاد كاملة بعد
موت التطبيق وبعد إعادة الإقلاع، **لكن الإرسال ما زال يحتاج أن
يكون التطبيق مفتوحًا** — W2-02b (WorkManager) لم تُنفَّذ،
ومحجوبة في بيئة المساعد لغياب الحزم عن الكاش وانعدام الوصول
إلى pub.dev. ولا واجهة ميدانية بعد: المبني نموذج قراءة لا
شاشة.

Migration 071–084 immutable.
أي DB change جديد يبدأ 085+.

---

## W2-02b — الإرسال الخلفي بلا فتح التطبيق (ق-117)

**التاريخ:** 2026-08-23.
**النطاق:** `apps/mobile/lib/core/sync/` — 10 ملفات إنتاجية
جديدة، وتعديل على `sync_engine.dart` و`main.dart` و
`android/app/src/main/AndroidManifest.xml`؛ و
`apps/mobile/test/core/sync/` — 4 ملفات اختبار.
**صفر تغيير على قاعدة البيانات.**

### التحقق — نتيجة فعلية (2026-08-23)

`flutter analyze` = `No issues found!`
`flutter test` = **155 PASS / 0 FAIL** (خط الأساس السابق 115).

التشغيل الأول أعاد 4 ملاحظات `prefer_initializing_formals`
فقط (لا أخطاء)، أُصلحت. ولم يسقط أي اختبار.

### المشكلة

بعد ق-116 صارت العملية محفوظة والجلسة تُستعاد، لكن الإرسال
كان يبدأ من حلقة يشغّلها التطبيق المفتوح. المشغّل الذي يسجّل
عملياته في حقل بلا تغطية ثم يُغلق التطبيق ويضع الهاتف في جيبه
لا تصل عملياته حتى يفتح التطبيق مرة أخرى تحت التغطية.

وبند 8 من `ANDROID_OFFLINE_BACKGROUND_SYNC.md` يقول
«re-enqueue بينما توجد عناصر Pending» بلا أن يقول **من**
يُعيد الجدولة، ولا ماذا يحدث لعنصرٍ معلَّق لن ينجح أبدًا بلا
قرار إنسان.

### ما صار عليه الحال

عاملٌ خلفي واحد لكل حساب، بشرط شبكة، يستيقظ ويُفرِّغ الطابور
ثم يسكت. **قيمة إرجاعه هي حواره كلّه مع النظام**: يُعاد
بالتراجع المسجَّل أو ينتهي. لا يجدول لنفسه موعدًا — لأن
الجدولة على نفس الاسم الفريد من داخل العامل تُلغيه وهو يعمل
أو تبني سلسلة عمل زائدة. والجدولة من التطبيق فقط، من ثلاثة
أسباب: فتحه، ورجوعه إلى الواجهة، وعودة الشبكة.

### الثوابت المفروضة بنيويًا

1. **السقف على المدة لا على عدد المحاولات** — 30 ثانية تتضاعف
   إلى ساعة ثم تثبت. أمرٌ في الطابور لا يُسقَط أبدًا: إسقاطه
   ضياع مال سقيٍ حقيقي.
2. **ما ينتظر إنسانًا لا يُوقظ الهاتف** (بند 20 من ق-90)،
   وما ينتظر الشبكة يُوقظه — والاثنان يتميّزان في الحساب لا
   في التسمية.
3. **مؤشِّر الشبكة مؤشِّرٌ لا دليل**: لا يُعلِّم أمرًا فاشلًا
   ولا يمسّ عدّاد إعادته أبدًا.
4. **ملفٌ واحد لكل SDK** — WorkManager في ملف،
   و`connectivity_plus` في ملف، وSupabase في ملف. وكل القرار
   في Dart خالص خلف واجهة.
5. **مسار قاعدة الطابور من دالة واحدة** — التطبيق والعامل
   عمليتان تفتحان نفس الملف؛ اختلاف المسار يعني كتابةً في ملف
   وإرسالًا من ملف فارغ آخر، بصمت.

### خلل وُجد وأُصلح داخل الجولة

`SyncRunReport.hasPendingWork` كانت `retryScheduled > 0 ||
skipped > 0`. وأمرٌ يحتاج مراجعة يترك تابعيه `skipped` في
**كل** تشغيل — فكان العامل سيعود إلى الأبد على شيء لن ينجح
بلا إنسان، مخالفةً بند 20 نصًّا. أُضيف `blockedByReview` و
`canRetryWithoutHelp`.

والحالة الأصعب كُشفت عند كتابة اختبارها: مزارعٌ رُفض إنشاؤه
وأرضٌ تشير إليه — **أصلان مختلفان**، فحجب الأصل الواحد لا
يكفي. صار تعذُّر حلّ المرجع يقرأ حالة الأمر المُشار إليه:
للمراجعة ⟹ «بانتظار إنسان»، وغير ذلك ⟹ «عابر».

### ما تُبرهنه الحزمة (40 اختبارًا جديدًا)

- **عملية سُجّلت والتطبيق مغلق تُرسل ثم لا يُوقظ الهاتف.**
- **انقطاع الشبكة يبقي العملية** ويطلب موعدًا لاحقًا؛
  والمحاولة الثالثة تنتظر أطول من الأولى.
- **الشبكة تعود فتصل العملية مرة واحدة:** محاولتان، وتنفيذ
  واحد (حماية ق-114 مستعملة من العامل فعلًا).
- **عشر عمليات تُرسل كلها في تشغيل خلفي واحد.**
- **فشلٌ في منتصف طابور طويل** يُعاد التمرير بعد التقدّم بلا
  انتظار نافذة تراجع جديدة لكل أمر؛ **وبلا تقدّم لا تتكرر
  التمريرة** — لا حلقة مشدودة على هاتف بلا شبكة.
- **رفض عملي لا يُوقظ الهاتف مرة أخرى**، وطابورٌ كله مراجعة
  يبقى بلا موعد في التشغيل التالي أيضًا.
- **مرجعٌ معلَّق خلف أمرٍ للمراجعة لا يُعاد إلى الأبد.**
- **بئرٌ للمراجعة لا تُوقف بئرًا أخرى تنتظر الشبكة.**
- **العامل لا يُرسل ما يُرسله التطبيق الآن:** حلقتان في نفس
  اللحظة ⟹ تنفيذ واحد.
- **حجزٌ مات العامل في منتصفه يُستعاد بلا تنفيذ ثانٍ.**
- **التراجع الأُسّي:** 30ث، 1د، 2د، 4د، … 32د، ثم ساعة ثابتة
  حتى المحاولة الخمسين؛ والمحاولة رقم ألف ما زالت مجدولة.
- **تقدُّمٌ مع بقاء عمل يُرجع الانتظار إلى أوّله.**
- **ثلاثة أسباب في ثانيتين تصير طلبًا واحدًا**، والطلب اليدوي
  لا يُكبح ويستبدل الموعد القائم، والأسباب التلقائية لا
  تستبدله (فلا تُصفَّر مهلة تراجع قائمة).
- **نبضة الشبكة عند العودة وحدها** لا عند كل تغيّر، والبدء
  متصلًا لا يُنتج نبضة كاذبة.

### ما لم يُثبت — بصراحة

- **لم يُجرَّب على جهاز:** إعادة الجدولة بعد إقلاع الهاتف،
  وسلوك Force Stop، والمانيفست المدموج. المُثبت منطق القرار
  في Dart وحده.
- **بناء Android لم يُجرَّب أصلًا** في بيئة المساعد:
  `androidx.work` غائبة عن Gradle cache.
- **قياسات بند 9 غير موصولة:** زمن «عودة الشبكة ← بدء
  العامل»، وزمن «بدء العامل ← تأكيد الخادم»، وعدد المحاولات،
  وعمر أقدم عملية معلَّقة — مطلوبة لـM-21.

### النتيجة

**م-25 تضيق رابعةً ولا تُغلق.** الإرسال لم يبقَ مشروطًا بفتح
التطبيق، **لكن لا شاشة تعرض شيئًا من هذا للمشغّل** — لا حالة
مزامنة، ولا جاهزية جهاز، ولا شرح لـForce Stop، ولا واجهة
ميدانية تُدخل العمليات أصلًا. وكل ما بُني مُبرهَن على الحاسوب
لا على هاتف.

Migration 071–084 immutable.
أي DB change جديد يبدأ 085+.

### م-41B2 — Account Profile Read Boundary Repair

- أصبحت قراءة بيانات الحساب تستخدم عقد القراءة الرسمي الموجود
  `api.app_bootstrap` بدل القراءة المباشرة من `iam.profiles`.
- عند نجاح Backend تظهر بيانات الحساب الحقيقية.
- عند فشل Backend لا تُعرض بيانات حساب تجريبية أو بديلة.
- تظهر للمستخدم حالة واضحة:
  `تعذر تحميل بيانات الحساب` مع `إعادة المحاولة`.
- بقية صفحة الإعدادات تبقى متاحة عند فشل بيانات الحساب.
- Targeted tests = **8/8 PASS**.
- `flutter analyze` = **No issues found**.
- Full Flutter regression = **230/230 PASS**.
- Known debt الحالي:
  - internal schemas = **8**.
  - bare RPC = **12**.
  - dotted `from()` = **5**.
- لا Migration 088.
- لا Cloud write ضمن م-41B2.

### م-41B3A — Profile Name Write Boundary Repair

من منظور المستخدم:
- حفظ الاسم لا يعرض نجاحًا إلا بعد نجاح Backend فعليًا.
- عند فشل Backend تبقى الشاشة متاحة وتظهر رسالة فشل صريحة.
- لم يعد Flutter يكتب مباشرة إلى `iam.profiles`.

العقد:
- Migration 088 تضيف `api.update_profile_name(text)`.
- غلاف `api` = SECURITY INVOKER.
- التنفيذ الداخلي `iam.update_own_profile_name(text)` =
  SECURITY DEFINER ومحصور في `auth.uid()`.
- `authenticated` و`service_role` يملكان traversal المتناظر.
- `anon` محجوب.
- Direct DML لأدوار التطبيق بقي صفرًا.

الإثبات المحلي:
- 088 target = **7/7 PASS**.
- Full DB = **26 files / 369 PASS / 0 FAIL / 0 ERROR**.
- Flutter targeted = **11/11 PASS**.
- `flutter analyze` = **No issues found**.
- Full Flutter = **233/233 PASS**.
- Internal-schema debt = **8 → 7**.
- Bare RPC debt = **12**.
- Dotted-from debt = **5**.
- Cloud Migration History تتضمن **088**.
- Cloud contract/security verification:
  - `api.update_profile_name(text)` موجودة.
  - Data API RPC = **35**.
  - API SECURITY DEFINER = **0**.
  - anon API EXECUTE = **0**.
  - Direct DML = **0**.
  - authenticated/service_role traversal = PASS.
  - verification residue = **0**.
- لم يُنفذ نجاح mutation على حساب Cloud حقيقي؛ النجاح الوظيفي مثبت محليًا.

### نتيجة Mapping الفريق ضمن م-41B3

الفحص الحي أثبت أن الأسماء القديمة التالية ليست عقود `api`
موجودة:
- `get_well_team`
- `add_team_member`
- `set_team_member_status`

كما لا توجد إجراءات داخلية جاهزة مكافئة يمكن إعادة تغليفها
بصورة عمياء.

التصنيف:
- Team read: عقد قراءة Backend مفقود.
- Add member: مرتبط بدورة حياة Account/Auth وربط الهوية
  برقم الهاتف؛ ليس مجرد INSERT أو إعادة تسمية RPC.
- Toggle status: يحتاج حمايات Backend للمالك الوحيد
  وللمشغل المرتبط بجلسة/مناوبة جارية؛ القيود الحالية على
  `core.well_assignments` لا تفرض هذه القواعد وحدها.

لذلك لا تُنشأ RPC سريعة لمجرد مطابقة Flutter القديم.


### م-41B3B — Team Boundary Gap Closure

من منظور المستخدم:
- لم تعد شاشة الفريق تعرض أسماء أو هواتف تجريبية.
- لا يظهر زر إضافة عضو بينما Backend لا يملك عقد إضافة آمنًا.
- لا يظهر تفعيل/تعطيل يوحي بنجاح غير مثبت.
- الشاشة تعرض بوضوح أن إدارة الفريق غير متاحة في هذه النسخة
  حتى يكتمل عقد الخادم الآمن.
- لم تُغيّر الشاشة أي بيانات فريق.

التنفيذ:
- أزيلت `get_well_team`.
- أزيلت `add_team_member`.
- أزيلت `set_team_member_status`.
- أزيل `_getMockTeam`.
- لا Migration جديدة ولا DB/Cloud write.

الإثبات المحلي:
- Targeted Flutter = **12/12 PASS**.
- `flutter analyze` = **No issues found**.
- Full Flutter = **234/234 PASS**.
- Internal-schema debt = **7**.
- Bare RPC debt = **12 → 9**.
- Dotted-from debt = **5**.
- فحص production code أكد صفر Team RPC قديمة وصفر Mock team.

مهم:
م-41B3B تغلق السلوك الكاذب في العميل فقط.
إدارة الفريق الفعلية تبقى فجوة Backend/Auth موثقة، ولا تعتبر
Feature منفذة أو Verified.

NEXT = **م-41C — Operations Read Boundary Repair**.


### م-41C1 — عقود قراءة العمليات (المزارعون / الأراضي / المضخات)

من منظور المستخدم:
- شاشة دليل المزارعين لم تعد تعرض أربعة أسماء تجريبية ثابتة.
- ملف المزارع لم يعد يعرض «محمد علي الحبيشي» عند فشل الخادم.
- شاشة التشغيل لم تعد تعرض مضخة وهمية تسمح ببدء جلسة على
  معرّف غير موجود.
- حقل البحث الذكي لم يعد يعرض قائمة فارغة تبدو «لا نتائج»
  بينما السبب الحقيقي هو فشل الاتصال.
- كل فشل الآن رسالة صريحة مع زر إعادة المحاولة.

الاكتشاف الحاكم:
التوجيه الأصلي كان «مطابقة القراءات مع العقود الموجودة فعلًا»،
لكن الفحص أثبت أن `api` لم تكن تحتوي أي عقد قراءة غير
`app_bootstrap`. القراءة المباشرة من `ops`/`core` كانت ميتة أصلًا
لأن هذه المخططات غير مكشوفة في Data API. لذلك كان لا بد من
عقود جديدة، وهي مصرَّح بها في ق-98.

التنفيذ:
- Migration **089** بثلاث دوال قراءة في `api`.
- اختبار SQL دائم بـ20 تحققًا.
- إعادة توصيل `fetchFarmers`/`fetchFarms`/`fetchPumps` إلى العقود.
- إزالة كل mock fallback في هذا المسار وإزالة النجاح الكاذب في
  `createFarmer`/`createFarm`.
- حالات فشل صريحة في `farmers_directory_screen` و
  `farmer_detail_screen` و`operations_screen` و`smart_lookup_field`.

الإثبات المحلي:
- `flutter analyze` = **No issues found**.
- Full Flutter = **237/237 PASS**.
- Internal-schema debt = **7 → 4**.
- Bare RPC debt = **9**.
- Dotted-from debt = **5**.
- `npm run db:reset` ثم `npm run db:test` (شغّلهما المالك):
  Target 089 = **20 PASS / 0 FAIL / 0 ERROR**، وFull DB =
  **27 files / 389 PASS / 0 FAIL / 0 ERROR** مقابل 369 سابقًا.

ما زال غير مثبت:
النشر السحابي لـ089 لم يجرِ، فالعقود الثلاثة موجودة محليًا فقط.
الحالة = Verified local، وليست Cloud Verified.

NEXT = **م-41C2 — قراءة سجل الجلسات وتفصيلها (Migration 090)**،
وتتضمن تصحيح تخطيط أعمدة `ops.session_segments` وقيم
`energy_source` الإنجليزية مقابل النصوص العربية في الطبقة العميلة.


### م-41C2 — عقدا قراءة الجلسات (السجل / التفصيل)

من منظور المستخدم:
- شاشة سجل الجلسات كانت تعرض دائمًا الجلسات التجريبية نفسها
  بالأسماء والمبالغ نفسها. الآن تعرض جلسات البئر الحقيقية،
  أو رسالة فشل صريحة مع «إعادة المحاولة» — لا شيء بينهما.
- شاشة تفصيل الجلسة كانت تعرض خطًا زمنيًا مخترعًا. الآن تعرض
  مقاطع الجلسة كما سُجّلت: نوع المقطع، ومدته الفعلية، والمدة
  المحسوبة، والتسعيرة المثبتة، والمبلغ المخزّن.
- الجلسة التي لم تُفوتر بعد كانت تظهر «آجل / غير مدفوع» بمبلغ
  صفر، أي كأن على المزارع دَينًا صفريًا محسومًا. الآن تظهر
  «غير مفوترة بعد» بلا مبلغ، ومحاولة طباعة فاتورة لها تُرفض
  برسالة واضحة.
- الترجمة العربية لمصدر الطاقة ونوع المقطع صارت من جدول تخطيط
  صريح؛ أي رمز جديد في القاعدة يظهر كما هو بدل أن يُترجم بالتخمين.

الاكتشاف الحاكم:
القراءة القديمة لم تكن «تقرأ من مخطط محجوب» فقط — كانت تطلب
خمسة أعمدة لا وجود لها في القاعدة إطلاقًا (`segment_index`،
`duration_seconds`، `hourly_rate_minor`، `is_paused`،
`pause_reason`). فحتى كشف المخططات في Data API لم يكن سيجعلها
تعمل. كما تبيّن أن ما سُجّل سابقًا عن أعمدة المقاطع
(`actual_minutes` / `raw_billable_minutes`) ناقص: 066 أضاف
`actual_seconds` و`billable_seconds` وأعمدة المبالغ، وهي التي
يستعملها التسعير فعلًا. صُحّح هذا في `OPEN_ISSUES`.

التنفيذ:
- Migration **090** بعقدين: `api.list_well_sessions` و
  `api.get_session_detail`.
- اختبار SQL دائم بـ25 تحققًا.
- إعادة توصيل `fetchSessionHistory` و`fetchSessionDetail` إلى
  العقدين، مع `historyWindow` تحسب النافذة الزمنية في الجهاز
  وترسلها كوسيطين (عقد حدود اليوم على الخادم ما زال مفتوحًا).
- إزالة `_getMockSessionHistory` و`_getMockSessionDetail`
  و`_applyHistoryFilter`، وإزالة كل حساب مال محلي — ومنه
  التسعيرة الاحتياطية `3500` في معاينة الطباعة.
- تخطيط صريح: `kEnergySourceLabels` و`kSegmentTypeLabels`
  (٩ أنواع)، والرمز المجهول يُعاد كما هو.
- حالات فشل صريحة في `session_history_screen` و
  `session_detail_screen`، وحالة سداد رابعة `not_billed` في
  البطاقات والملخص والمشاركة.

الإثبات المحلي:
- `flutter analyze` = **No issues found**.
- Full Flutter = **258/258 PASS** (كان 237؛ +21 اختبارًا جديدًا:
  عقد الجلسات، النافذة الزمنية، التخطيط الصريح، حالات الفشل).
- Internal-schema debt = **4 → 0**، ويثبّتها اختبار الحدود بقائمة
  فارغة صريحة.
- Bare RPC debt = **9** كما هي؛ Dotted-from debt = **5** كما هي.

ما زال غير مثبت:
- **DB 090 لم يُشغَّل بعد** — `db:reset` + `db:test` بيد المالك،
  فحالة العقدين على القاعدة = مكتوبة لا مُتحقَّقة.
- النشر السحابي لـ089 و090 لم يجرِ.

NEXT = **م-41D1 — Well Management Boundary Repair** (Migration 091).

## م-41D1 — Well Management Boundary Repair (Migration 091)

الحالة: **Verified local** — القاعدة والاختبارات نجحت محليًا؛
النشر السحابي لم يجرِ.

ما أُصلح:
- تسعة نداءات في `well_management_repository` كانت RPC مجرّدة
  بأسماء عقود غير موجودة؛ صارت كلها عبر
  `schema('api').rpc(...)` إلا `get_reports_summary`.
- الوحدات الوهمية في العميل: القدرة كانت رقمًا بالحصان وهي نص حر
  في القاعدة، والتدفق والوقود بوحدات مختلفة، والخزانات باللتر وهي
  بالمليلتر. صارت كلها أسماء القاعدة ووحداتها، والتحويل إلى لتر
  تخطيط عرض وحيد في `fuel_inventory_screen.dart`.
- حالتا مضخة غير موجودتين في القاعدة (`running`، `standby`) كانتا
  تُعرضان؛ أُزيلتا.
- غياب جدول تسعير ساري كان يُعرض كأسعار صفرية؛ صار حالة صريحة.

التنفيذ:
- Migration **091**: أربعة عقود قراءة، وثلاثة أزواج كتابة
  (INVOKER فوق DEFINER يحمل `iam.has_well_permission`)، وثلاثة
  أعمدة جديدة على `core.wells` بقيود عدم سلبية، ورمزا صلاحية
  جديدان لـ`tenant_owner`.
- **تعديل مقصود لثلاثة حرّاس عدد** في اختبارَي الحقبة المقفلة 080
  و081 بسبب رمزَي الصلاحية الجديدين (الفهرس 39→41، الإجمالي
  73→75).
- اختبار SQL دائم بـ34 تحققًا.
- `recordFuelPurchase` ضاق عن قصد: العقد يأخذ البئر لا الخزان ولا
  يقبل مورّدًا ولا ملاحظة، فحُذف الحقلان وشُرح السبب في الشاشة بدل
  تلفيق حفظٍ لا يحدث.

الإثبات المحلي:
- `flutter analyze` = **No issues found**.
- Full Flutter = **258/258 PASS**.
- `db:reset` نجح؛ `db:test` أعطى لـ091 **PASS=34 FAIL=0
  ERROR=0**، والحزمة كلها **29 files / 448 PASS / 0 FAIL**.
- Bare RPC debt = **9 → 1**؛ Internal-schema debt = **0**؛
  Dotted-from debt = **5** كما هي.

ما زال غير مثبت:
- **تصحيح 2026-09-01**: السحابة متزامنة فعلًا — 089 و090 و091
  مطبَّقة هناك (فرق الجانبين صفر). وصلت تلقائيًا عبر تكامل
  `GitHub` (`Deploy to production` = ON، فرع الإنتاج `main`)، لا
  بسكربت يدوي. لكن اختبارات `supabase/tests` تُشغَّل محليًا فقط،
  فحالتها السحابية = مطبَّقة لا مُتحقَّقة.
- `commit ba4176c` دُفع إلى `main` مباشرة، فطبّق على قاعدة
  الإنتاج بلا `PR` ولا مراجعة. حماية فرع `main` مطلوبة.

NEXT = **م-41D2 — Finance Boundary Repair + عقد مؤشرات التقارير**
(1 bare RPC + 5 dotted `from()`).

## م-41D2 — Finance Boundary Repair + عقد التقارير (Migration 092)

الحالة: **مغلق — محليًا وسحابيًا** — `analyze` و`test`
نجحا، و`db:reset` + `db:test` نجحا في 2026-09-02: 092 = 37 PASS،
والحزمة 30 files / 485 PASS / 0 FAIL / 0 ERROR. ثم دُمج الطلب `#13`
مضغوطًا في `main` (`87a0529`) فنُشرت 092 تلقائيًا على الإنتاج، وأكّد
`npm run cloud:verify` أن 91 ملفًا يقابلها 91 صفًا سحابيًا
(`MISSING_IN_CLOUD=0`) وأن عقود `api` الخمسة موجودة هناك.

ما أُصلح:
- خمس قراءات في `finance_repository` كانت
  `from('schema.table')` على مخططات غير مكشوفة، وكل واحدة ملفوفة
  بـ`catch(_)` يعيد بيانات تجريبية. صارت كلها عقود `api`.
- **اثنتان منها كانتا تخاطبان ما لا وجود له أصلًا**:
  `iam.well_memberships` جدول غير موجود في التسعين هجرة، و
  `public.farms` غير موجود، و`billing.invoices.issue_date` عمود
  غير موجود (الحقيقي `invoice_date`). أي أن الدين كان أكبر من
  الموثَّق: لم تكن قراءات تفشل شبكيًا، بل قراءات لأشياء وهمية.
- `get_reports_summary` كان نداء RPC مجرّدًا باسم عقد غير موجود؛
  صار عقدًا حقيقيًا و`_getMockReportSummary` أُزيل.
- **مال مُلفَّق أُزيل من العميل**: هوية المزارع ورصيده المقدَّم
  الثابتان، ومال الشركاء المحشور في كل صف، وأرقام التقارير الخمسة.
- **العلاج كان أصغر من الدين**: مخطط `reporting` يحسب هذه الأرقام
  منذ 060 (`partner_account_summary`، `farmer_account_balances`)،
  و`paid_minor` عمود حقيقي من 068. فالعقود توصيل لا اختراع.
- خطأ تخطيط لم يكن ظاهرًا وقت المحاكاة: ترويسة كرت دورة الأرباح
  تفيض 101 بكسل عند الحالة `calculated`؛ أُصلحت بمقاس مرن
  + `ellipsis`.

التنفيذ:
- Migration **092**: خمسة عقود قراءة، INVOKER + STABLE +
  `search_path` مثبت، fail-closed `28000`/`22023`/`42501`، حدود
  مقصوصة، ترتيب حتمي داخليًا وخارجيًا، anon محجوب.
- استثناء ق-99 واحد معلَن (`remaining_minor` بتعريف 068)، و«صافي
  التدفق» تحسبه الشاشة لا العقد.
- اختبار SQL دائم بـ**37 تحققًا**.
- ست شاشات تعرض فشل العقد نصًّا عربيًا بدل الدوران أو البديل.
- سبعة فحوص Widget/حدود جديدة، ومنها ثلاثة تُسقط المستودع بقصد
  لتثبيت أن الفشل يُعرض ولا يُخفى.

الإثبات المحلي (شغّلتها بنفسي، 2026-09-02):
- `flutter analyze` = **No issues found**.
- Full Flutter = **265/265 PASS** (كان 258؛ +7).
- Bare RPC debt = **1 → 0**؛ Dotted-from debt = **5 → 0**؛
  Internal-schema debt = **0** كما هي. القوائم الثلاث فارغة.

مُثبت في 2026-09-02:
- **DB 092 نجح** — `db:reset` + `db:test` في 2026-09-02: Target 092
  = 37 PASS، والحزمة 30 files / 485 PASS / 0 FAIL / 0 ERROR. خط
  الأساس الجديد = 485. وسبق النجاح تصحيح ستة عيوب في بيانات اختبار
  092 نفسه (تفصيلها في `MIGRATIONS.md`).

ما زال غير مثبت:
- **النشر = الدمج**: `main` موصول بقاعدة الإنتاج، فدمج 092 ينشرها
  تلقائيًا. حماية `main` يجب أن تكون محفوظة وفعّالة قبل ذلك.
- معرّف الدفعة المُلفَّق `'mock-advance-pay'` في زر «استخدام الرصيد
  المقدم» ما زال قائمًا — مسجَّل في `OPEN_ISSUES.md` وإصلاحه توسيع
  تمنعه ق-120.

NEXT ← انظر آخر قسم في هذا الملف.

## 2026-09-02 — قياس أرقام الدين بعد 092 + فهرس المخطط

### قياس الدين — مُثبت (شغّله المساعد)

- مقياسان مستقلان تطابقا: مسح `python3` على 76 ملف Dart بنفس تعابير
  الحرس لكن على كامل نص الملف، ثم حرس الحد نفسه.
- Internal-schema = **0**، Bare-RPC = **0**، Dotted-from = **0**،
  وأي `.from('table')` = **0**.
- عقود `api` المنادى عليها من Flutter = **38** عقدًا مميزًا.
- `flutter analyze` = **No issues found**؛ حرس الحد = **13/13 PASS**؛
  الحزمة الكاملة = **265/265 PASS**.
- لم يُغيَّر سطر واحد من كود التطبيق في هذه الجولة: قياس لا إصلاح.

### فهرس المخطط — مُثبت (شغّله المالك)

`npm run db:index` على القاعدة المحلية أنتج `docs/technical/db`:
`columns.txt` 800 سطرًا، `constraints.txt` 481، `functions.txt` 436،
`triggers.txt` 44. يستبدل قراءة ملفات الهجرات كاملة لإثبات وجود عمود
أو قيد أو دالة.

### ما كشفه القياس ولم يكن معروفًا

الدين المُعلَن صفر، لكن **ثمانية مواضع** تُعلن النجاح بلا نجاح خارج ما
تقيسه القوائم الثلاث — أربعة منها في `AccountRepository` وحده (كلمة
المرور، تشخيص الجهاز، المزامنة اليدوية، حرس الخروج). تفصيلها بمواضعها
في `OPEN_ISSUES.md`. البوابة ق-120 لا تُغلق بأرقام الدين وحدها.

NEXT = فحص الحرس الرابع + إصلاح الثمانية بأولوية 1 ← 5، ثم تقرير إغلاق
ق-120.

## 2026-09-02 — م-41D3: إصلاح النجاح الكاذب في `AccountRepository` + الحرس الرابع

### ما نُفِّذ — مُثبت (شغّله المساعد)

البنود 1–4 من قائمة النجاح الكاذب أُغلقت في الكود، بلا عقد قاعدة جديد
وبلا `W2-02d`، على سابقة م-41B3B: تُزال الكذبة وتُعرض حالة صريحة.

- **كلمة المرور:** لا `catch` ولا `debugPrint` في المسار. بلا جلسة
  مصدَّقة يُرفع `StateError`، ورفض الخادم يصعد. الشاشة لا تعرض نجاحًا
  إلا على نجاح، وتُفرّغ الحقول في الحالتين (ق-118 / القرار 541).
- **تشخيص الجهاز:** يُقرأ من الطابور نفسه (العدد + آخر مزامنة ناجحة +
  نوع المتجر). و`isOnline` و`backgroundSyncActive` بقيا `null` =
  «غير مقيس» ويُكتبان كذلك في الشاشة بلون محايد. فشل القراءة يظهر
  صريحًا مع «إعادة المحاولة» بدل بطاقة أرقام مُلفَّقة.
- **المزامنة اليدوية:** تمر بالمنسق؛ بلا ناقل موصول تُعلن «لم يُرسل
  شيء» عبر `ManualSyncUnavailableException`، وتعمل تلقائيًا يوم يُوصَل
  ناقل (`canSyncNow` / `syncNow` أُضيفا للمنسق).
- **حرس الخروج:** لا يعيد `0` عند الفشل؛ الشاشة تفشل مغلقة بحوار
  «تعذر التحقق قبل الخروج» يطلب موافقة صريحة.

### الحرس الرابع — أُضيف ومُثبت

`data_api_boundary_test.dart` = **17/17 PASS** (كان 13/13). يقيس عائلة
النجاح الكاذب لا باب القاعدة: دين المعرّفات المُلفَّقة = **3** مثبتة
(`mock-session-`، `mock-advance-pay`، `F-NEW`)، ودين `'well-1'` =
**47** موضعًا في **15** ملفًا، وقفلان نصيّان على `AccountRepository`
وعلى شاشات الإعدادات الثلاث.

### التحقق

`flutter analyze` = **No issues found**؛ الحزمة الكاملة =
**278/278 PASS** (خط الأساس انتقل من 265 إلى 278).

### ما زال غير مثبت

- **لا تشغيل على جهاز**: كل ما أعلاه اختبارات وحدة وواجهة. سلوك الشاشة
  على هاتف حقيقي غير مُثبت.
- **الطابور الدائم غير موصول في المقدمة** (`main.dart` بلا
  `SqliteOutboxStore` ولا `BackgroundSyncBinding`)، فالشاشة تُظهر
  الحقيقة: طابور ذاكرة ومزامنة يدوية غير متاحة. توصيلها `W2-02d`
  تمنعه ق-120.
- البنود 5–8 من قائمة النجاح الكاذب باقية؛ الحرس يمنع نموّها لا أكثر.

NEXT = البنود 5–7 (شاشة التشغيل + `operations_repository`)، ثم البند 8،
ثم تقرير إغلاق ق-120.

## 2026-09-02 — م-41D4: إصلاح النجاح الكاذب في مسار التشغيل + المقياس الخامس

### ما نُفِّذ — مُثبت (شغّله المساعد)

النطاق المعلن كان ثلاثة مواضع (البنود 5–7). والمُصلَح خمسة عشر موضعًا من
العائلة نفسها في أربعة ملفات، على سابقة م-41B3B: تُزال الكذبة وتُعرض
حالة صريحة، ولا يُختلق خادم. سبب التوسّع: البند 5 كان واحدًا من خمس
كتابات جلسة تتصرف بالطريقة نفسها — وأخطرها إنهاء الجلسة الذي كان يعيد
فاتورة مكتوبة في العميل — والبندان 6 و7 موضعان من سبعة في الشاشة تبتلع
الاستثناء ثم تُغيّر الحالة المعروضة. إصلاح الثلث كان سيُبقي المسار
كاذبًا: بدء يفشل صراحةً ثم إنهاء ينجح بفاتورة مُلفَّقة.

- **كتابات المستودع الخمس** (بدء / إيقاف / استئناف / تغيير طاقة /
  إنهاء): ترفع `StateError` بلا عميل — نفس استثناء القراءات في الملف
  نفسه، فلا اصطلاح جديد. زال معرّف الجلسة المُلفَّق، وزالت ثلاث عودات
  صامتة، وزالت فاتورة `10500`. القياس: 12 حراسة = 12 استثناء = صفر
  عودة صامتة.
- **شاشة التشغيل**: زالت مصائد الاستثناء الفارغة السبع. كل كتابة تفشل
  تُعرض في `SnackBar` و**لا** تُغيَّر الحالة المعروضة: العداد لا يبدأ،
  والزر لا ينقلب، والمصدر لا يتغيّر، والسند لا يُفتح، والسداد لا
  يُتخطّى صامتًا. وحوارا إضافة المزارع والأرض يرفضان العمل بلا بئر نشط
  بدل تلفيق كيان وإغلاق النافذة كأن الحفظ نجح.
- **الشريط العلوي**: لا `WellSummary` مُلفَّقة بمستأجر وأدوار مُفترضة.
  البئر يُطابَق مع آبار المستخدم، وإن لم يُطابِق فالشريط يقول «لا بئر
  مختار» بدل تسمية بئر العرض التجريبي.
- **زر الطباعة الحرارية**: لا تأخير `600ms` ثم «تم إرسال أمر الطباعة»
  بلا تكامل بلوتوث؛ يعلن عدم التوفر صراحةً.

### المقياس الخامس + اختبارات سلوكية — أُضيفت ومُثبتة

`data_api_boundary_test.dart` = **21/21 PASS** (كان 17/17): قفل نصّي على
الملفات الأربعة، ودين المعرّفات المُلفَّقة انكمش **3 ← 1**، ودين
`'well-1'` انكمش **47/15 ← 45/14**. والقفل النصّي لا يُثبت السلوك، فأُضيف
`operations_write_contract_test.dart` (ستة اختبارات تُنفِّذ الكتابات
فعلًا وتتحقق من الاستثناء ورسالته) و
`operations_failure_paths_test.dart` (ثلاثة اختبارات واجهة بمنسق يفشل:
الرسالة تظهر، والزر لم ينقلب، والجلسة ما زالت جارية، ولا سند يُفتح).

### التحقق

`flutter analyze` = **No issues found**؛ الحزمة الكاملة =
**292/292 PASS** (خط الأساس انتقل من 278 إلى 292).

### ما زال غير مثبت

- **لا تشغيل على جهاز**: كل ما أعلاه اختبارات وحدة وواجهة.
- **البند 8** (`mock-advance-pay`) باقٍ ويحتاج عقد قاعدة (ق-99).
- **تسعيرة الساعة ما زالت في العميل** (3500 / 5000): جُمعت في موضع واحد
  مُسمّى ومُثبتة في الحرس كدين يُسمح له بالانكماش فقط، ولم تُوصل بعقد
  `api.get_active_price_schedule` — جولة مستقلة.
- **دين الهوية**: `'well-1'` = 45/14، و`tenant-1` = 13، و`'active-user'`
  = 8 مواضع.

NEXT = البند 8، ثم جولة التسعيرة الحقيقية، ثم جولة الهوية الحقيقية، ثم
تقرير إغلاق ق-120.

## 2026-09-02 — م-41D5: إغلاق البند 8 (تخصيص الرصيد المقدَّم) + المقياس السادس

### ما نُفِّذ — مُثبت (شغّله المساعد)

آخر موضع في دين المعرّفات المُلفَّقة كان زر «استخدام الرصيد المقدم» في
شاشة الحساب المالي للمزارع: نافذة تُعِد بتسديد فواتير معروضة بأرقامها،
ثم ترسل `paymentId: 'mock-advance-pay'` مع قائمة تخصيصات **فارغة** إلى
عقد كتابة حقيقي، ثم تعلن «تم استخدام الرصيد المقدم في تسديد الفواتير
بنجاح ✅». والوصف نفسه كان يقول «أقدم الفواتير» والعقد يعيدها من الأحدث.

- **النافذة صارت `_AdvanceUnavailableDialog`** — `StatelessWidget` **لا
  تحمل مستودعًا**، فلا مسار كتابة منها أصلًا. تعرض الرصيد كما أعاده
  العقد، وتصرّح بأن التسديد منه غير متاح في هذا الإصدار وأن **لا أمر
  تسديد أُرسل** وأن الرصيد والدين لم يتغيّرا، والفواتير موسومة «عرض
  فقط — لا تُسدَّد من هذه النافذة»، وفيها زر «إغلاق» وحده.
- **الزر** صار «الرصيد المقدم (غير متاح)» بلون محايد، على نمط «طباعة
  حرارية (غير متاحة)» في سند القبض — المشغل يعرف قبل الضغط.
- **`allocateAdvance` بقي في المستودع** عقدًا صادقًا بلا نداء، مع تعليق
  يقول إن لا شاشة تناديه حتى يوجد عقد القراءة.

### لماذا لم يُوصَّل التخصيص الحقيقي

`api.allocate_payment` موجود ويُنادى بصدق، لكنه يطلب معرّف سند ورصيده
غير المخصَّص، و`api.get_farmer_account` يعيد الرصيد المقدَّم رقمًا
**مُجمَّعًا** (مشتقًا في `reporting.farmer_account_balances`) والسندات
بأرقام فواتيرها بلا مبالغ. فلا يعرف العميل أي سند بقي فيه رصيد ولا كم
بقي. واختيار السند في العميل قرار مالي يخترعه العميل لا المشغل — ق-99
تمنعه، والزناد `billing.split_overpayment_to_advance` يؤكد أن المنطق
مملوك للخادم. فالمُتَّبع سابقة م-41B3B.

### المقياس السادس + اختبار سلوكي

`data_api_boundary_test.dart` = **22/22 PASS** (كان 21): قائمة
المعرّفات المُلفَّقة صارت **فارغة** (1 ← 0)، ومقطع النافذة يُفحص فلا
`FinanceRepository` فيه ولا `await`. و
`farmer_financial_account_screen_test.dart` = **5 اختبارات** (كان 4):
الثالث يفتح النافذة ويتحقق من النصوص الصريحة وغياب زر التأكيد ثم يغلق
ويتحقق من غياب أي رسالة نجاح، والرابع يمرّر مستودعًا جاسوسًا ويُثبت أن
عدّاد نداءات التخصيص = **0** — النداء نفسه هو العيب لا نتيجته.

### التحقق

`flutter analyze` = **No issues found**؛ الحزمة الكاملة =
**294/294 PASS** (خط الأساس انتقل من 292 إلى 294).

### ما زال غير مثبت

- **لا تشغيل على جهاز** لأي مما أُصلح في م-41D3 → م-41D5.
- **عقد قراءة سندات الرصيد المقدَّم** غير موجود: بدونه يبقى الزر معلنًا
  عدم التوفر، والقرار 420 مفتوحًا. توسيعٌ تمنعه ق-120.
- ~~**تسعيرة العميل**~~ — أُغلقت في م-41D6 أدناه.
- **دين الهوية**: `'well-1'` = 45/14، و`tenant-1` = 13، و`'active-user'`
  = 8 مواضع.

NEXT = جولة التسعيرة الحقيقية، ثم جولة الهوية الحقيقية، ثم تقرير إغلاق
ق-120.

## 2026-09-02 — م-41D6: تسعيرة شاشة التشغيل من عقد جدول البئر

**النطاق:** الموضعان اللذان كانا يحملان السعر في العميل —
`operations_screen.dart` و`OfflineSessionCoordinator`. لا Migration
جديد: `api.get_active_price_schedule` موجود منذ 091، فالجولة توصيل
قراءة. لا شاشة جديدة — ق-120 نافذة.

### ما كان يراه المشغل

زرّان ثابتان: «طاقة شمسية ☀️ — 3,500 ريال / ساعة» و«ديزل شامل ⛽ —
5,000 ريال / ساعة»، والمستحق الحيّ وسند القبض يُحسبان منهما. فالمبلغ
الذي يُطبع للمزارع لم يُسعّره جدول بئره قط. وتحت ذلك: «ديزل شامل» تجمع
`well_diesel` و`farmer_diesel` بسعرين مختلفين في القاعدة، والنص العربي
كان يُرسل حرفيًّا في `p_energy_source` وهجرة 066 ترفض كل ما ليس
الرموز الثلاثة بـ`22023` — أي أن الكتابة نفسها كانت مرفوضة خادميًّا.
والمنسّق كان يحمل الرقمين في `PricingResolver` الافتراضي، فيُسعّر أي
مقطع بـ3500.

### ما صار

- خيارات مصدر الطاقة = مصادر القاعدة الثلاثة `kSessionEnergySources`
  (وهي بحرفها ما تقبله هجرة 066)، اسم كل خيار من `kEnergySourceLabels`
  ورمزه هو ما يُرسل في الكتابة، وسعره من قاعدة الجدول الساري وحدها.
  المصدر قرار تشغيلي، والسعر وحده يأتي من العقد.
- قاعدة بلا `hourly_rate_minor` تُعرض «التسعيرة غير متوفرة» ولا تُسلَّم
  للمُسقط. غياب الجدول أو فشل القراءة: لافتة فوق الأزرار تقول أيّهما
  جرى مع «إعادة المحاولة»، ولا سعر، والأزرار والتشغيل يبقيان.
- **التسعيرة لا تحجب البدء**: `price.manage` للمالك وحده (هجرات 080
  و091) بينما `session.start` للمشغل، و`ops.start_irrigation_session`
  لا تأخذ سعرًا وتُثبّت السعر خادميًّا. فرفض `42501` يُعرض كحالة صلاحية
  («التسعيرة السارية متاحة لمن يملك إدارة الأسعار») بلا زرّ إعادة
  محاولة، وحرس «لا مصدر طاقة مُسعَّر — تعذر بدء الجلسة» أُزيل لأنه كان
  يمنع عملًا يقبله الخادم: فشل كاذب مقابل النجاح الكاذب المُزال.
- المستحق الحيّ بلا سعر = `SessionStateText.pricingPending` (القرار
  341)، ونهاية الجلسة بلا سعر تُسجَّل الجلسة وتقول إن لا سند من هنا.
- المنسّق بلا أسعار افتراضية (`PricingResolver.none()`) و`updatePricing`
  تُحلّ اللقطات المقروءة وتُعيد بناء المُسقط؛ قائمة فارغة عند الفشل.

### القياس

مقياس الحرس انقلب: من «`_clientSideRateFor` موجودة و3500/5000 موضع
واحد لكل رقم» إلى «لا أثر لأيٍّ منها ولا لـ`'طاقة شمسية'`، وتوجد
`fetchActivePriceSchedule` و`pricingPending` ورسالة الفشل
و`kSessionEnergySources` وفحص `42501`، ولا وجود لرسالة منع البدء».
الحرس = **22/22 PASS**. وأُضيف
`test/features/operations/operations_pricing_test.dart` بستة اختبارات
واجهة (أسعار العقد 4,200 و6,100، قاعدة بلا سعر، غياب الجدول والأزرار
باقية، فشل القراءة وإعادة المحاولة كنداء ثانٍ فعلي، جلسة جارية بلا
تسعيرة، ورفض `42501` كحالة صلاحية لا فشل).

`flutter analyze` = **No issues found**؛ الحزمة = **300/300 PASS**
(خط الأساس انتقل من 294 إلى 300).

### ما زال غير مثبت

- **لا تشغيل على جهاز** لأي مما أُصلح في م-41D3 → م-41D6.
- ~~**المشغل لا يرى التسعيرة**~~ — أُغلق بم-41D7 أدناه (هجرة 093).
- **تسعير الوقود** (`farmer_diesel` بنموذج `fuel_based`) لا رقم ساعي
  له، والعرض يقول ذلك؛ احتسابه مملوك للخادم.
- **عقد قراءة سندات الرصيد المقدَّم** كما هو.
- **دين الهوية**: `'well-1'` = 45/14، و`tenant-1` = 13، و`'active-user'`
  = 8 مواضع.

## 2026-09-02 — م-41D7: سلطة قراءة التسعيرة (هجرة 093)

قرار المالك: **يجب أن يرى المشغل سعر الساعة**. وهو استكمال لجولة
التسعير نفسها، واستثناء مالكي معلَن من ق-120 (هجرة لا شاشة).

**التشخيص:** المنع طبقتان لا طبقة واحدة. العقد يفحص `price.manage`
(للمالك وحده بـ080)، **و** سياسات 031 تحصر `SELECT` على
`ops.price_schedules` و`ops.price_rules` بـ
`iam.has_well_role(well_id, ['owner'])`. فتخفيف الفحص وحده داخل عقد
`INVOKER` كان سيُعيد صفر صفوف → `schedule: null`، أي **غياب كاذب**
يقول «لا تسعيرة» والتسعيرة موجودة. لذلك تحرّكت الطبقتان معًا.

**ما نُفِّذ:**
- صلاحية اطلاع مستقلة `price.read` (لا توسيع لـ`price.manage`)، ممنوحة
  لـ`tenant_owner` و`well_manager` و`operator` — وهي نفس مجموعة الأدوار
  التي تقبلها `ops.start_irrigation_session` في 066: من يبدأ جلسة
  مُسعَّرة يرى السعر الذي ستُسعَّر به.
- قارئ داخلي `ops.read_active_price_schedule(uuid, timestamptz)`:
  `stable` + `security definer` + `search_path` مثبت، يحمل الفحص
  المسمّى ويتجاوز RLS في نقطة واحدة مُراجَعة.
- `api.get_active_price_schedule` يبقى `INVOKER`: جلسة `28000`، مدخل
  `22023`، رؤية البئر عبر RLS 079 `42501`، ثم يفوّض بلا تكرار قرار
  الصلاحية (اختبار 084 PASS 7).
- سياسات RLS على جدولي التسعير **لم تُخفَّف**: الجداول مغلقة على
  المالك، والاطلاع بالعقد وحده.
- أرقام السلطة: كتالوج 41 → **42**، منح 75 → **78** (مالك 42، مدير 14،
  مشغل 22)، وحُدّثت أرقام الحرس في اختباري 080 و081 بتعليق يسمّي 093.
- اختبار دائم جديد بـ**15 تحققًا**، أقواها أن حمولة المشغل تساوي حمولة
  المالك **حرفيًا** مع بقائه على صفر صفوف في القراءة المباشرة وعلى
  رفض `42501` إن حاول الكتابة.
- **صفر تغيير في Flutter**: المسار المرئي كان جاهزًا بعد م-41D6،
  والناقص كان سلطة القراءة في القاعدة.

**مثبت 2026-09-02:** محليًا — هدف 093 = `PASS=15 FAIL=0 ERROR=0`،
والحزمة `FILES=31 PASS=500 FAIL=0 ERROR=0`، و`db:index` أعاد التوليد.
ثم دُمج `PR #20` مضغوطًا في `main` عند `787eee0` فنُشرت الهجرة على
الإنتاج، وسحابيًا: `MISSING_IN_CLOUD=0`، و`FUNCTIONS_MISSING_IN_CLOUD=0`
من أصل 424 دالة في الفهرس مقابل 426 سحابيًا، و`IAM_PERMISSIONS=42` /
`IAM_ROLE_PERMISSIONS=78` — فالمنح وصلت الإنتاج على مستوى البيانات.

**عطب اكتُشف وأُصلح في الأداة:** أول تشغيل سحابي أعلن النجاح بلا أن
يفحص شيئًا من 093، لأن `scripts/cloud_verify.sh` كان يحمل أسماء عقود
092 الخمسة مكتوبة يدويًا. القائمة نُزعت، والفحص صار مشتقًّا من
`docs/technical/db/functions.txt`، ودُمج مضغوطًا في `PR #21` عند
`8123448`. الدرس: ق-113 تنطبق على أدوات التحقق
كما تنطبق على الواجهة، والمشتقّ يبقى صحيحًا حيث يتقادم المكتوب يدويًا.

**غير مثبت:** لا تشغيل على جهاز حقيقي؛ و`supabase/tests` لا تُشغَّل
سحابيًا فالمُثبت هناك وجود الأهداف لا نجاح تحققاتها.

NEXT = جولة الهوية الحقيقية (موقوفة بطلب المالك)، ثم تقرير إغلاق ق-120.

## 2026-09-03 — ق-121: أدوات الفحص المختصرة وثبات الفهرس

### الأدوات الثلاث

- `scripts/check_state.sh` → `npm run c:state`: تسعة أسطر — الفرع،
  والفارق عن `main` و`origin/main`، والتغييرات المتعقَّبة، وعدد الهجرات
  والرقم التالي، وعدد ملفات الاختبار، وطول `RESUME_POINT`، وأحجام الفهرس.
- `scripts/check_app.sh` → `npm run c:app`: `pub get --offline` عند غياب
  `.dart_tool` (مجلد عمل معزول جديد)، ثم `analyze --no-pub` ثم
  `test --no-pub`. يكتشف بنفسه إن كان أمر `flutter` العادي يعمل وإلا نادى
  صورة الأداة (`MODE=cli` أو `MODE=direct`).
- `scripts/check_db.sh` → `npm run c:db`: `db:reset` ثم `db:test` ثم
  `db:index`، وما بعد الفاشلة لا يُشغَّل. حرّاس مسبقة: Docker، وحاوية
  `supabase_db`، وأقرب `node_modules/.bin` يُضاف إلى `PATH` (مجلد العمل
  المعزول لا يحمل `node_modules` خاصًا به).

كلها تكتب سجلها الكامل في `${TMPDIR:-/tmp}/wi-checks/` وتطبع المسار.

**مثبت بتشغيل المالك 2026-09-03:** `c:app` على مسار `cli` =
`analyze issues=0` و**`PASS=300 FAIL=0`**؛ و`c:db` =
`FILES=31 PASS=500 FAIL=0 ERROR=0` مع `db:index` ناجحًا.

**مثبت بتشغيل الوكيل:** `c:state` كامل؛ و`c:app` على مسار `direct`
(`analyze` = `No issues found!` في 16 ثانية)؛ وحرّاس `c:db`؛ ومنطق قراءة
النتائج جرّب على **ثمانية** أمثلة صناعية (نجاح وفشل، للقاعدة وللتطبيق).

### ثبات الفهرس — `db_index.sh`

`functions.txt` كان يُنتج فرقًا بعد كل `db:reset` بلا تغيير حقيقي:
`order by n.nspname, p.proname` لا يفصل بين الدوال المُحمَّلة زائدًا (نفس
الاسم، وسائط مختلفة) فيتبدّل ترتيبها بترتيب الصفوف في الكتالوج. أُضيف
`pg_get_function_identity_arguments(p.oid) collate "C"` كفاصل حاسم —
و(schema, name, identity args) مفتاح فريد بالتعريف. والثلاثة الأخرى
مفاتيحها فريدة أصلًا: `attnum` و`conname` و`tgname` لكل جدول.

**مثبت 2026-09-03:** توليد، ثم `db:reset` كامل + `db:test` + توليد ثانٍ ⟹
`functions.txt` مطابق بايتًا ببايت (شجرة نظيفة = `PROOF=INDEX_STABLE`).
والفرق قبل الإصلاح كان **ترتيبًا لا مضمونًا**: 437 سطرًا قبل وبعد، وفرق
المحتويَين مرتَّبين = صفر.

### قصّ نقطة الاستئناف

`RESUME_POINT.md` من **1383 → 140 سطرًا**. السرد الزمني كله إلى
`RESUME_HISTORY.md` منقولًا حرفًا بحرف — أُثبت بـ`cmp` أن جسم الأرشيف
مطابق للأصل بايتًا ببايت. والقواعد الحيّة وما لا يجوز إعادة عمله
والمؤجَّلات بقيت في الرأس.

### غير مثبت

لا تشغيل على جهاز أندرويد حقيقي، ولا تحقق سحابي — لا شيء في هذه الجولة
يمسّ القاعدة ولا الشبكة ولا سلوك التطبيق. ولا هجرة جديدة: السقف يبقى
071–093 والتالي 094.

NEXT = طابور التدقيق كما في `RESUME_POINT.md` §4؛ وجولة الهوية موقوفة
بطلب المالك.

## 2026-09-03 — م-41D8 جولة الهوية الحقيقية (ق-122)

### ما ثبت بالتشغيل

- `npm run c:app` في مجلد العمل المعزول:
  `STEP 1 analyze OK issues=0` و`STEP 2 test OK PASS=313 FAIL=0` و
  `RESULT=SUCCESS`. كانت 300 قبل الجولة.
- التحليل يغطي `lib` **و**`test` معًا: `No issues found!`.
- **دين الهوية صفر مقيسًا في `lib/`**: `'well-1'` 45 → 0،
  `'tenant-1'` 13 → 0، `'active-user'` 8 → 0، `'بئر الخير الرئيسي'` → 0،
  `'777123456'` → 0، `placeholderAccountKey` → 0.
- **حرس الحد 24/24 PASS** (كان 22/22): المقياس الخامس انقلب إلى
  `expected = []`، ومقياسان جديدان لغياب القيم الجاهزة وبنية الهوية.
- **ثمانية اختبارات جديدة لبوابة الهوية** تُقاس سلوكًا: أربعة لدالة
  `resolveIdentity` الخالصة، وأربعة للبوابة — أهمها أن فشل العقد لا
  يُنادي بانِي المحتوى أصلًا، وأن «إعادة المحاولة» تُنتج قراءة ثانية
  فعلية للعقد.
- **بذر مخزن `sqlite3` أُثبت بالحذف وإعادة التشغيل** لا بالدعوى:
  `STEP 0 sqlite3 OK copied-from-main-checkout` ثم `RESULT=SUCCESS`.

### غير مثبت

لا تشغيل على جهاز أندرويد حقيقي، ولا تحقق سحابي، ولا هجرة جديدة: لا شيء
في هذه الجولة يمسّ القاعدة ولا الشبكة. السقف يبقى 071–093 والتالي 094.
وأرقام القاعدة والسحابة تبقى كما هي: 92 هجرة، `FILES=31 PASS=500`،
`MISSING_IN_CLOUD=0`.

NEXT = مراجعة Auth / OTP / account lifecycle، ثم تقرير إغلاق ق-120.
