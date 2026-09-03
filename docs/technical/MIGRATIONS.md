# الهجرات

**آخر تحديث:** 2026-09-02

سجل ملفات هجرة قاعدة البيانات، وحالة كل ملف: هل كُتب؟ وهل **طُبّق فعليًا**؟ وهما أمران مختلفان تمامًا.

---

## الحالة الحالية الحاكمة — 2026-09-01

- Local: **90 migration file** مطبقة حتى الرقم 091؛ الرقم 067
  غير مستخدم (الترقيم يقفز 066 → 068)، فالعدد 90 لا 91.
- Cloud: **متزامنة تمامًا — 90 صفًا في
  `supabase_migrations.schema_migrations`، وفرق الجانبين صفر**
  (تحقق 2026-09-01 بمقارنة صفحة `Migrations` بملفات المستودع).
- **سبب المزامنة مُثبت بالدليل**: تكامل `GitHub` مفعَّل في
  `Settings → Integrations`، `Deploy to production` = ON،
  وفرع الإنتاج = `main`. أي أن **كل دفع أو دمج في `main`
  يطبَّق على قاعدة الإنتاج تلقائيًا**، بلا تشغيل اختبارات
  `supabase/tests` هناك.
- فروع المعاينة لكل `PR` تحتاج خطة `Pro`؛ والمشروع على `FREE`،
  فلا قاعدة تجريبية للمراجعة ولا نسخ احتياطي تلقائي. الحاجز
  الوحيد = `db:reset` + `db:test` محليًا ثم مراجعة `PR`.
- لذلك سكربت `psql` اليدوي صار مسارًا احتياطيًا لا المسار
  الأساسي؛ يفيد حين يُطبَّق ملف خارج `main` أو حين يتعطل التكامل.

- 071: ق-78 — Data API boundary.
- 072: إغلاق Direct DML.
- 073+074: عقد الكتابة داخل `api`.
- 080: ق-112 — Permission Authority Foundation.
- 081+082: ق-113 — Permission Enforcement Wiring.
- 083+084: ق-114 — Server-side Idempotency.
- 085: إصلاح Backend gaps، ومنها Fuel Billing وسياسة قراءة
  الدفعات وسحب PUBLIC من الدوال الداخلية وإزالة
  `operation_plus_fuel`.
- 086: حفظ هاتف الملف الشخصي + عقد التهيئة الشاملة
  `setup_well_full`.
- 087: إصلاح صلاحيات عبور `api.setup_well_full` إلى `core`.
- 088: عقد تحديث اسم الملف الشخصي عبر `api.update_profile_name`؛
  **Verified local + Cloud contract/security**.
- Cloud 087 verification:
  authenticated call = PASS؛ anon denied = PASS؛
  prices = 3500/7000/6000؛ ROLLBACK؛ residue = 0.

- 089: ق-98 — عقود قراءة العمليات (مزارعون/أراضٍ/مضخات).
- 090: عقود قراءة الجلسة.
- 091: عقود إدارة البئر قراءةً وكتابةً + أول توسيع لكتالوج
  الصلاحيات بعد 081 (`well.update` و`pump.manage`).

Migration 071–088 immutable؛ أي DB change تالٍ يبدأ 089+.

**مهم:** الجداول أدناه تسجل ما فعلته كل هجرة في وقتها.
لذلك قد يظهر في هجرة قديمة وصف منسوخ لاحقًا، مثل
milli-riyal في 009. هذا وصف تاريخي للهجرة وليس القاعدة الحالية.

المعنى المالي الحالي يحكمه ق-77: الريال الكامل.

## 088 — Profile Name API — Local + Cloud Contract Verified

الملف:
`20260830013000_088_update_profile_name_api.sql`

يضيف:
- `iam.update_own_profile_name(text)` كإجراء داخلي
  SECURITY DEFINER محصور في `auth.uid()`.
- `api.update_profile_name(text)` كغلاف SECURITY INVOKER.
- منحًا متناظرة لـauthenticated/service_role على مسار العقد.
- حجب anon.
- بلا أي Direct DML جديد لأدوار التطبيق.

التحقق المحلي:
- Target 088 = **7 PASS / 0 FAIL / 0 ERROR**.
- Full suite = **26 files / 369 PASS / 0 FAIL / 0 ERROR**.
- اختبار 074 بقي PASS بعد إضافة العقد.
- Cloud Migration History تتضمن 088.
- Cloud Data API RPC = **35**.
- Cloud API SECURITY DEFINER = **0**.
- Cloud anon API EXECUTE = **0**.
- Cloud Direct DML = **0**.
- authenticated/service_role traversal = PASS.
- verification residue = **0**.
- لم يُنفذ success mutation على حساب Cloud حقيقي؛ النجاح الوظيفي مثبت محليًا.

## 085–087 — إغلاق فجوات Backend وCreate-Well

### 085 — Backend Gap Fixes

الملف `20260823200001_085_backend_gap_fixes.sql` عالج أربع
فجوات قائمة:

1. سياسة قراءة الدفعات المقدمة والديون القديمة.
2. تصحيح Fuel Billing وفق ق-17 وق-91 بحيث الوقود رقابي ولا
   يضاف كسعر مستقل على المزارع.
3. سحب EXECUTE الافتراضي من PUBLIC على الدوال الداخلية.
4. إزالة نموذج التسعير الملغى `operation_plus_fuel`.

### 086 — Well Setup Full + Profile Phone

الملف `20260825040001_086_well_setup_full_and_profile_phone.sql`:

- يحدّث `iam.handle_new_user()` لحفظ الهاتف في `iam.profiles`.
- يبني `core.setup_well_full(jsonb)` كتهيئة ذرية للبئر
  والمضخة والتسعير والمالك والشركاء والمشغلين.
- يضيف عقد `api.setup_well_full` الذي يستخدمه Flutter.

### 087 — setup_well_full permissions

الملف `20260830010001_087_setup_well_full_permissions.sql`
يعالج فجوة الصلاحية بين غلاف `api` الـINVOKER والدالة
الداخلية، مع إبقاء حدود الأمان وDirect DML كما هي.

### التحقق

- 087 local target = **8 PASS / 0 FAIL / 0 ERROR**.
- Full local suite = **25 files / 362 PASS / 0 FAIL / 0 ERROR**.
- Cloud: 087 موجودة في Remote Migration History.
- Cloud authenticated `api.setup_well_full` = PASS.
- Cloud anon invocation = denied.
- Cloud prices = **3500 / 7000 / 6000** دون ×100.
- Cloud verification transaction = **ROLLED BACK**.
- Residue after rollback = **0**.

Migration 071–087 أصبحت immutable.
أي تغيير DB لاحق يبدأ **088+**.

---

## تحديث جوهري — إعادة بناء كاملة بتاريخ 2026-08-13 (ق-51 وق-57)

حُذف ملفا الترحيل القديمان (001 و002، بتاريخ 2026-08-05) بالكامل، لأنهما سبقا استقرار القرارات الخمسين. استُبدلا بـ 25 ملف ترحيل جديدة، مبنية ومختبرة تباعًا في نفس اليوم، تعكس كل القرارات النافذة حتى ق-66.

**ملاحظة تاريخية:** هذا القسم كُتب أولًا عندما كان التطبيق محليًا فقط. الحالة الحالية الحاكمة هي الملخص أعلى الملف: 001–079 موجودة على Supabase Cloud، و079 متحققة محليًا وسحابيًا.

---

## الملفات (001–013) — المخطط الأساسي

| # | الملف | المحتوى |
| --- | --- | --- |
| 001 | `_001_extensions_and_schemas.sql` | تفعيل الإضافات وإنشاء المخططات التسعة |
| 002 | `_002_tenants.sql` | جدول `core.tenants` |
| 003 | `_003_wells.sql` | جدول `core.wells` |
| 004 | `_004_people_and_ownership.sql` | `iam.profiles`، `core.well_assignments`، `core.well_ownership_shares` (نسب بمليون جزء — ق-21) |
| 005 | `_005_pumps.sql` | جدول `core.pumps` |
| 006 | `_006_farms.sql` | جدول `ops.farms` |
| 007 | `_007_irrigation_sessions.sql` | جدول `ops.irrigation_sessions` (يوم النهاية — ق-27) |
| 008 | `_008_well_pricing.sql` | جدول `billing.well_pricing` |
| 009 | `_009_session_charges.sql` | جدول `billing.session_charges` — كان جزءًا من ألف وقت 009؛ حُوّل لاحقًا إلى الريال الكامل في 039 وحُسم نهائيًا بق-77 |
| 010 | `_010_profit_distributions.sql` | `finance.distribution_batches` و`finance.distribution_lines` |
| 011 | `_011_payments.sql` | جدول `billing.payments` |
| 012 | `_012_fuel_purchases.sql` | جدول `inventory.fuel_purchases` |
| 013 | `_013_auto_compute_session_charge.sql` | زناد الحساب التلقائي للرسوم عند إغلاق الجلسة |

**حالة التطبيق:** مُطبّقة ومُختبرة — ق-57.

---

## الملفات (014–017) — الأمان على مستوى الصف (RLS)

| # | الملف | المحتوى |
| --- | --- | --- |
| 014 | `_014_rls_foundations.sql` | دالة `iam.has_well_role` وتفعيل RLS |
| 015 | `_015_grants_for_authenticated.sql` | منح صلاحيات القراءة الأساسية لـ `authenticated` |
| 016 | `_016_rls_select_all_remaining.sql` | سياسات SELECT لكل الجداول الخمسة عشر |
| 017 | `_017_rls_write_policies.sql` | سياسات INSERT/UPDATE/DELETE + تصحيح `ops.compute_session_charge` إلى `SECURITY DEFINER` |

**حالة التطبيق:** مُطبّقة ومُختبرة (اختبار عزل بأربعة أدوار على بئرين) — ق-58 وق-59.

---

## الملفات (018–022) — التوفير التلقائي والإشعارات التشغيلية

| # | الملف | المحتوى |
| --- | --- | --- |
| 018 | `_018_auto_create_profile.sql` | إنشاء الملف الشخصي تلقائيًا عند التسجيل |
| 019 | `_019_flag_long_sessions.sql` | `ops.flag_long_running_sessions()` |
| 020 | `_020_auto_create_well_settings.sql` | إنشاء إعدادات البئر تلقائيًا |
| 021 | `_021_flag_approaching_long_sessions.sql` | `ops.flag_approaching_long_sessions()` |
| 022 | `_022_notifications.sql` | جدول `ops.notifications` + ربطه بالدالتين أعلاه |

**حالة التطبيق:** مُطبّقة ومُختبرة — ق-60 إلى ق-62.

---

## الملفات (023–025) — دورة حياة توزيع الأرباح

| # | الملف | المحتوى |
| --- | --- | --- |
| 023 | `_023_generate_distribution_batch.sql` | `finance.generate_distribution_batch()` — حساب الصافي وتوزيعه بطريقة أكبر الباقي |
| 024 | `_024_lock_finalized_distribution.sql` | قفل الدفعة وبنودها نهائيًا بعد `finalized` |
| 025 | `_025_notify_distribution_finalized.sql` | إشعار كل شريك تلقائيًا عند اكتمال الدفعة |

**حالة التطبيق:** مُطبّقة ومُختبرة (بما فيها اختبار تصحيح باقي القسمة) — ق-63 إلى ق-66.
**تنبيه مرتبط:** آلية أكبر الباقي هنا لم تُغلق بعد بالحرف الكامل لشرط ت-01 — انظر `REMINDERS.md`.

---

## قواعد الهجرات

1. كل هجرة لها رقم تسلسلي وطابع زمني في اسمها.
2. **لا تُعدّل هجرة طُبّقت أبدًا**؛ يُكتب ملف جديد يُصححها.
3. بعد تطبيق أي هجرة يُحدّث هذا الملف فورًا مع **دليل التطبيق**.
4. `PROGRESS.md` يسجل تاريخ التطبيق ونتيجته.

---

## الملفات (026–028) — إغلاق المرحلة 1 (النواة): المواقع، الأشخاص، كتالوج الأدوار

| # | الملف | المحتوى |
| --- | --- | --- |
| 026 | `_026_locations.sql` | امتدادات pg_trgm/btree_gist/citext، `core.generate_public_code()`، `core.locations`، عمود `core.wells.location_id` |
| 027 | `_027_persons_and_contacts.sql` | `core.persons`، `core.person_contacts`، `core.person_aliases`، فهارس trigram |
| 028 | `_028_roles_and_permissions_catalog.sql` | `iam.roles`، `iam.permissions`، `iam.role_permissions` (كان كتالوجًا تأسيسيًا؛ صار مصدر الإنفاذ لأجساد الدوال بق-113 / 081+082) |

**حالة التطبيق:** مُطبّقة ومُختبرة محليًا — ق-68.

---

## الملفات (029–034) — إغلاق المرحلة 2 (التشغيل): خطوط المياه، المزارعون، التسعير، الحجوزات، حجز الموارد، مقاطع الجلسة

| # | الملف | المحتوى |
| --- | --- | --- |
| 029 | `_029_water_lines_and_pump_links.sql` | `core.water_lines`، `core.pump_line_links` |
| 030 | `_030_farmer_profiles_and_well_accounts.sql` | `ops.farmer_profiles`، `ops.farmer_well_accounts` |
| 031 | `_031_price_schedules_and_rules.sql` | `ops.price_schedules`، `ops.price_rules` (استُخدم iam.profiles بدل iam.users) |
| 032 | `_032_irrigation_bookings.sql` | `ops.irrigation_bookings`، `ops.booking_status_history` (تحديث يدوي من التطبيق، بلا زناد) |
| 033 | `_033_resource_reservations.sql` | `ops.resource_reservations`، دالة `ops.reserve_resource()` (صُحّحت لإدراج tenant_id بعد فشل أول اختبار) |
| 034 | `_034_session_segments.sql` | `ops.session_segments`، دالة وزناد `ops.validate_session_segment_overlap()` |

**حالة التطبيق:** مُطبّقة ومُختبرة محليًا (بنيويًا ووظيفيًا، بيانات تجريبية ذاتية الاكتفاء) — ق-69.

---

## الملفات (035–038) — إغلاق المرحلة 3 (المال): الدفتر المزدوج، الفواتير، تخصيص الدفعات

| # | الملف | المحتوى |
| --- | --- | --- |
| 035 | `_035_ledger_accounts.sql` | `finance.ledger_accounts` + دالة `finance.create_default_ledger_accounts()` (26 حسابًا نظاميًا لكل بئر — §30.1) |
| 036 | `_036_journal_entries_and_lines.sql` | `finance.journal_entries`، `finance.journal_lines`، دالة `finance.post_journal_entry()`، زنادَي منع تعديل القيد المُرحّل وأطرافه |
| 037 | `_037_invoices_and_lines.sql` | `billing.invoices` (قيد `paid+outstanding=total`)، `billing.invoice_lines` |
| 038 | `_038_payment_allocations.sql` | `billing.payment_allocations` (مرتبط بـ `billing.payments` القائم — انظر م-20) |

**حالة التطبيق:** مُطبّقة ومُختبرة محليًا (تحقق بنيوي + 19 حالة اختبار وظيفي ناجحة) — ق-70.

## الملفات (039–046) — إغلاق المرحلة 4 (الديزل والمصروفات): الصندوق، المناوبات، المصروفات، الوقود

| # | الملف | المحتوى |
| --- | --- | --- |
| 039 | `_039_unify_money_unit_to_minor.sql` | توحيد وحدة المال إلى الريال الكامل `_minor` وإعادة كتابة 5 دوال (ق-71) |
| 040 | `_040_notifications_extend_and_helper.sql` | توسيع الإشعارات إلى 15 نوعًا + `ops.notify_well_owners` و`ops.notify_profile` |
| 041 | `_041_cashboxes.sql` | صندوق عام لكل بئر يُنشأ تلقائيًا (`finance.cashboxes`) |
| 042 | `_042_shifts_handovers_transfers.sql` | المناوبات والتسليم ونقل الجلسات (`ops.shifts`, `shift_handovers`, `session_shift_transfers`) |
| 043 | `_043_payments_expansion.sql` | توسيع `billing.payments` والتحصيل بلا جلسة (م-20) |
| 044 | `_044_expenses.sql` | `finance.expenses` وأنواعها التسعة وقواعد الاعتماد وقراراته |
| 045 | `_045_shift_reports.sql` | `ops.shift_report` و`ops.operator_totals` وربط الجلسة بالمناوبة تلقائيًا |
| 046 | `_046_fuel_tanks_and_transactions.sql` | `inventory.fuel_tanks` و`fuel_transactions` والمتوسط المرجح المتحرك وجسر الشراء القديم |

**حالة التطبيق:** مُطبّقة ومُختبرة محليًا (تحقق بنيوي + 27/27 ثم 25/25 حالة اختبار وظيفي) — ق-71، ق-72.

## الملفات (047–050) — إغلاق المرحلة 5 (الشركاء): الشركاء، الفترات المحاسبية، الصلاحيات

| # | الملف | المحتوى |
| --- | --- | --- |
| 047 | `_047_partners_and_roles.sql` | `core.well_partners` مصدرًا وحيدًا للنِّسب، دورا `manager`/`partner`، `iam.profiles.is_platform_admin`، ترحيل بيانات الحصص القديمة وإسقاط جدولها، إعادة كتابة `generate_distribution_batch` و`notify_well_owners` |
| 048 | `_048_partner_irrigation_policies.sql` | `core.partner_irrigation_policies` (دفع عادي / خصم من الأرباح) + ربط `invoices.partner_policy_id` و`journal_lines.partner_id` |
| 049 | `_049_accounting_periods.sql` | `finance.accounting_periods` و`period_reopen_requests` و`period_reopen_approvals`، دوال الإقفال والتصويت والبت، الخطوة 5 من §32 في `post_journal_entry` |
| 050 | `_050_manager_partner_access.sql` | توليد 120 سياسة «مدير» و49 سياسة «شريك» آليًا + سياسات التعيين المقيدة للمدير |

**حالة التطبيق:** مُطبّقة ومُختبرة محليًا (تحقق بنيوي + 23/23 حالة اختبار وظيفي) — ق-73.

## الملفات (051–056) — إغلاق المرحلة 6 (الإدارة): إصدارات النسب، محرك التوزيع الكامل، الاحتياطي، الأرصدة الافتتاحية، الرواتب، قيود الديزل

| # | الملف | المحتوى |
| --- | --- | --- |
| 051 | `_051_share_versions.sql` | `core.ownership_share_versions` (فصل نسبة الملكية عن نسبة الأرباح + مانع تداخل + المُعتمد)، ترحيل النسب من `share_ppm` وحذفه، حالات الشريك الأربع، توحيد مسميات سياسة السقي |
| 052 | `_052_distribution_engine.sql` | `finance.profit_distribution_cycles/lines` (§39)، `calculate_profit_distribution` و`approve_profit_distribution` (§49 بخطواته)، `maintenance_reserve_rules` (§38)، `distribution_settings` بمفتاح الالتزامات، `expenses.partner_id`، حذف جداول ودوال التوزيع القديمة |
| 053 | `_053_distribution_fixes.sql` | إصلاح فحص `found` للاحتياطي، علامتا التسوية `settled_in_cycle_id` و`deducted_in_cycle_id` ضد ازدواج الدورات |
| 054 | `_054_opening_balances.sql` | `finance.opening_balance_batches/items` (§41) بتسعة أنواع، اعتماد المالك، القفل، الترحيل، حركة مخزون للوقود الافتتاحي |
| 055 | `_055_payroll_and_fuel_journal.sql` | إصلاح توازن الأرصدة (الأصول = الالتزامات + رأس المال)، `record_expense` بمعامل الشريك، `worker_compensation_rules` و`payroll_accruals` و`accrue_payroll`/`pay_salary` (doc 02 §29)، زناد قيود الديزل (§26)، الالتزامات مع الرواتب |
| 056 | `_056_record_expense_overload_and_opening_approve_check.sql` | حذف ازدواج `record_expense` القديم، فحص توازن الأرصدة عند الاعتماد أيضًا |

**حالة التطبيق:** مُطبّقة ومُختبرة محليًا (تحقق بنيوي + 19/19 ثم 17/17 حالة اختبار وظيفي) — ق-74.

## الملفات (057–061) — الدفعة الختامية لمحطة قواعد البيانات (ق-75)
- 20260814030001_057_audit_log.sql — مخطط audit + جدول audit_logs إلحاقي فقط + audit.log و track_changes موصولة على 6 جداول حساسة.
- 20260814030002_058_sync_layer.sql — sync.processed_commands (begin_command/finish_command، الأمر المكرر يعيد المخزن) + sync.sync_conflicts.
- 20260814030003_059_attachments.sql — core.attachments العامة (upload_status الافتراضي pending).
- 20260814030004_060_reporting_views.sql — مخطط reporting + 5 عروض security_invoker (أرصدة المزارعين، الصناديق، الوقود، ملخص الشريك، التقرير اليومي).
- 20260814031001_061_money_procedures.sql — فهرس فاتورة واحدة نشطة لكل جلسة؛ journal_entry_id للدفعات والفواتير؛ تحويل زيادة الدفعة لرصيد مقدم (حذف الرفض القديم)؛ ترحيل آلي للدفعات والمصروفات والفواتير؛ قيد شراء الديزل يحمل الصندوق الرئيسي؛ reverse_journal_entry و reverse_payment؛ إصلاح cashbox_balances ليحتسب المرحل والمعكوس.

**حالة التطبيق:** مطبقة ومختبرة 2026-08-14 — الفحص البنيوي (4 زنادات + 6 دوال + فهرس + غياب القديم) والاختبار المالي 17/17 PASS.

## الملفات (062–063) — ق-76: دمج الأشخاص المكررين وقفل المضخة
- 20260814040001_062_person_merge_and_pump_lock.sql — جدول person_merge_requests (الوثيقة 02 قسم 7.5) + normalize_arabic و normalize_phone + find_person_duplicates (تطابق/شك) + merge_persons (نقل 12 مرجعًا، حارسا الأرصدة والشراكات، أرشفة المكرر، تسجيل التدقيق) + resource_concurrency_rules (قسم 10.4) + زناد قفل المضخة (الافتراضي جلسة واحدة).
- 20260814041001_063_find_duplicates_search_path_fix.sql — توسيع search_path لكاشف التكرار (similarity من pg_trgm خارج نطاق core).

**حالة التطبيق:** مطبقة ومختبرة 2026-08-14 — الاختبار الوظيفي 13/13 PASS.

## الملفات (064–065) — ق-77: إصلاحات التدقيق المستقل (نفذها Codex وتحققنا منها بقناة مستقلة)
- 20260814042001_064_price_snapshot_ownership_rls_policy_overlap.sql — لقطة سعر الجلسة عند البدء (عمود price_per_hour_minor_snapshot + زناد + إعادة كتابة compute_session_charge لتستخدم اللقطة فقط)؛ فرض مجموع الملكية 100% مثل الأرباح؛ إغلاق م-15 (حذف سياساتي الإدخال المفتوحتين + create_tenant_with_well + سياسة مالك-في-الجهة)؛ قيد منع تداخل سياسات سقي الشريك؛ حذف rounding_minor.
- 20260814042002_065_daily_view_end_day.sql — العرض اليومي reporting.well_daily_summary بيوم النهاية واستبعاد الجلسات الجارية من كل المجاميع (open_sessions معلوماتي فقط).

**حالة التطبيق:** مطبقة ومختبرة 2026-08-14 — 65 هجرة نظيفة، والاختبارات 17/17 و13/13 و12/12 بقناتين مستقلتين.

## الملف (066) — ق-77: طبقة إجراءات الجلسة الذرية (نفذها Codex وتحققنا بقناة مستقلة)
- 20260814043001_066_session_procedures.sql — الإجراءات الستة: start_irrigation_session و pause_irrigation_session و change_session_energy_source و resume_irrigation_session و complete_irrigation_session (خطوات الوثيقة 03 قسم 47: مقاطع بلا تقريب، تسعير مختلط بلقطات مثبتة، حركات وقود، تدقيق، ملخص JSONB) و billing.issue_session_invoice. أعمدة جديدة: sessions.farmer_well_account_id، حقول الثواني والمبالغ في session_segments، و session_charges.pricing_mode (flat/segments) مع تحيين قيد المعادلة لجلسات المقاطع؛ compute_session_charge أصبحت شبكة أمان للجلسات البسيطة فقط.

**حالة التطبيق:** مطبقة ومختبرة 2026-08-15 — 66 هجرة نظيفة؛ الاختبارات الأربعة 17/17 و13/13 و12/12 و14/14.

## الحزمة (067) — ق-77 البند 5: حزمة الاختبارات الدائمة (بنية اختبار فقط، بلا هجرة)
- ثلاثة ملفات: 20260814_067_finance_time.test.sql (16 فحصا) و 20260814_067_inventory_sync_rls.test.sql (12) و 20260814_067_partners_distribution.test.sql (8)، مع scripts/db_test.sh وربط npm run db:test. البنود الملغاة بقرار (ق-12 التقريب، ق-75 الاجهزة وPowerSync، م-21 الميدانية) موثقة بتعليق بدل تنفيذها.

**حالة التطبيق:** مختبرة 2026-08-15 بقناتين — 7 ملفات، 92 فحصا PASS، FAIL=0 ERROR=0؛ المشغل يتوقف عند اول ملف فاشل (اثبت ذلك فعليا اثناء التطوير).

## الملف (068) — ت-11/الدفعة الأولى: إجراءات المال الذرية (نفذها Codex وتحققنا بقناة مستقلة)
- 20260815023001_068_money_procedures.sql — ثلاثة إجراءات: billing.record_payment (خطوات الوثيقة 03 قسم 48 الثلاث عشرة: قفل حساب المزارع، ادخال عادي يشغل الزنادات القائمة، تخصيص للفواتير بلا تجاوز، تحويل المتبقي لرصيد مقدم مستقل بسند وقيد، تحقق من ترحيل القيود، تحديث الفواتير، تدقيق، وايصال JSONB) و billing.allocate_payment (توزيع دفعة او رصيد مقدم على فواتير مفتوحة مع تسوية 2000/1100) و finance.pay_partner_distribution (دفع جزئي او كامل من دورة معتمدة فقط، بعمود paid_minor تراكمي، واحتجاز الالتزامات للمتبقي فقط).

**حالة التطبيق:** مطبقة ومختبرة 2026-08-15 — 67 هجرة نظيفة؛ الحزمة 8 ملفات و107 فحصات كلها PASS.

## الملف (069) — ت-11/الدفعة الثانية: إجراءات التشغيل الذرية (نفذها Codex وتحققنا بقناة مستقلة)
- 20260815033001_069_ops_procedures.sql — سبعة إجراءات: ops.create_farmer (شخص وملف وحساب ذريا؛ التطابق الكامل يعيد الموجود بعلم «موجود سابقا» بلا دمج ولا تكرار؛ الاشتباه الجزئي ينشئ ويعيد المرشحين) و ops.create_farm (مسموح اثناء الجلسات المفتوحة) و ops.create_booking (تحقق وحجز موارد ذري) و ops.reschedule_booking (حالات ما قبل البدء فقط مع تحرير وحجز الموارد) و inventory.purchase_fuel و inventory.record_fuel_consumption (تقديري معلق بلا خصم / فعلي يخصم ويستبدل التقديري) و inventory.record_physical_fuel_count (فرق الجرد بقيده؛ بلا قيد صفري عند متوسط صفري).
- ملاحظة تاريخية: كان حقل مالك الأرض مرتبطًا بملف دخول المستخدم؛ أُغلقت م-22 لاحقًا بق-80 / 075 وتحول الارتباط إلى Farmer Well Account.

**حالة التطبيق:** مطبقة ومختبرة 2026-08-15 — 68 هجرة نظيفة؛ الحزمة 9 ملفات و129 فحصا كلها PASS بقناتين مستقلتين.

## الملف (070) — م-23: مرسلا التنبيهين الدوريين (نفذها Codex وتحققنا بقناة مستقلة)
- 20260815043001_070_notification_senders.sql — دالتان: ops.send_daily_summaries(p_day) (تقرأ من reporting.well_daily_summary حصرا، ترسل للمالك والمدير النشط، بلا تنبيه لبئر بلا نشاط) و ops.check_debt_thresholds() (الذمة = الرصيد الموثق ناقص المقدم وبحد ادنى صفر، مقارنة بالحقل القائم credit_limit_minor، تنبيه عند التجاوز). اضيف نوعا تنبيه جديدان: daily_summary و debt_threshold_exceeded، ومفتاح deduplication_key مع فهرس فريد جزئي يمنع تكرار التنبيه ذريا (مرة لكل مستلم في اليوم، ويعاد في يوم لاحق عند تجاوز جديد). النداء اليدوي مقصور على آبار المالك/المدير، ومستدعي النظام يعالج الكل.

**حالة التطبيق:** مطبقة ومختبرة 2026-08-15 — 69 هجرة نظيفة؛ الحزمة 10 ملفات و138 فحصا كلها PASS. ملاحظة: اصلاح تجهيز الاختبار (خلع قناع الانتحال قبل تجهيزات الدفعات) تم دون لمس الهجرة.

## الملف (071) — ق-78: حد Data API المخصص للتطبيق

- `20260816231501_071_api_boundary.sql` — إنشاء مخطط `api` بوصفه عقد Data API؛ حجب `anon`؛ منح `authenticated` و`service_role` استخدام المخطط بلا CREATE؛ إنشاء `api.health()` كمسبار تقني SECURITY INVOKER مع منح EXECUTE صريح؛ وضبط `supabase/config.toml` لتكون Exposed Schemas هي `api` و`graphql_public` فقط.
- ملاحظة PostgreSQL مثبتة بالاختبار: REVOKE المحدود بمخطط في ALTER DEFAULT PRIVILEGES لا يستطيع إلغاء EXECUTE العالمي الافتراضي للدوال؛ لذلك الحماية المعتمدة للدوال هي CREATE + REVOKE + GRANT داخل المعاملة نفسها مع فحص قبول يمنع أي دالة api قابلة للتنفيذ من anon.

**حالة التطبيق:** مطبقة ومختبرة 2026-08-16 — 70 هجرة نظيفة؛ 11 ملف اختبار دائم؛ 145 فحص PASS؛ FAIL=0؛ ERROR=0. تحقق PostgREST: api يعمل، anon مرفوض، وops/public غير مكشوفين.

## الملف (072) — ق-79: إغلاق Direct DML

- `20260816233301_072_rpc_only_writes.sql`
- يسحب INSERT وUPDATE وDELETE وTRUNCATE وREFERENCES وTRIGGER من `anon` و`authenticated` على جداول مخططات الأعمال الداخلية.
- يضبط Default Privileges للجداول المستقبلية كي لا تستعيد الكتابة المباشرة.
- لا يسحب SELECT أو USAGE أو EXECUTE في هذه الخطوة.
- التحقق الفعلي: Direct DML = 0؛ الإجراءات الحرجة ما زالت قابلة للتنفيذ؛ SECURITY DEFINER بلا search_path = 0.
- baseline المثبت: 71 هجرة، 12 ملف اختبار، 154 PASS، FAIL=0، ERROR=0.
- الحالة: مطبقة ومختبرة 2026-08-16.

## الملف (073) — عقد الكتابة داخل api

- `20260816234501_073_api_write_contract.sql`
- يضيف 15 غلاف كتابة معتمد داخل `api`.
- الأغلفة SECURITY INVOKER ولا تحتوي منطق أعمال مستقلًا.
- معاملات هوية المنفذ الحساسة مشتقة من `auth.uid()` ولا تأتي من Flutter.
- تاريخيًا في هذه المرحلة كان `api.create_farm` مؤجلًا بسبب م-22؛ أضيف لاحقًا في 075.
- الحالة: مكتوبة وقيد تحقق المالك؛ لا تسجل كـ baseline مثبت قبل نتائج reset/tests.

## الملف (074) — استكمال التدفقات الحرجة في api

- `20260816235001_074_api_critical_flows.sql`
- يضيف 15 غلافًا جديدًا لتدفقات MVP الحرجة.
- لا يعيد Direct DML.
- هوية المستخدم مشتقة من جلسة المصادقة.
- تاريخيًا كان `create_farm` مؤجلًا بسبب م-22؛ حُسم وأضيف إلى `api` في 075.
- الحالة: مكتوبة وقيد تحقق المالك.

## الملف (074) — مثبت ومغلق

- `20260816235001_074_api_critical_flows.sql`
- استكمل عقد الكتابة الحرج للـMVP داخل `api`.
- baseline المثبت: 73 هجرة، 14 ملف اختبار، 178 PASS، FAIL=0، ERROR=0.
- Data API: 31 RPC معتمدًا.
- Direct DML: صفر.
- الحالة: مطبقة ومختبرة 2026-08-17.

### 076 — Pump Model / Reporting / Concurrency — ق-81

الملف:

`20260817011001_076_pump_model_reporting.sql`

**الحالة: مطبقة ومثبتة محليًا — 2026-08-17.**

المنجز:

- توسيع `core.pumps` إلى نموذج المعدة المرجعي.
- إضافة `tenant_id`, `public_code`, `pump_type`, `power_rating`.
- إضافة بيانات استهلاك الوقود والتدفق والتركيب والملاحظات.
- حالات `maintenance` و`retired`.
- `power_source` أصبح Legacy compatibility nullable.
- مصدر الطاقة الحديث للتقرير هو `ops.session_segments`.
- Solar/Diesel reporting أصبح مبنيًا على `billable_seconds`.
- `reserve_resource()` أصبح يحترم `resource_concurrency_rules`.

الاختبار:

`20260817_076_pump_model_reporting.test.sql`

النتيجة:

`PASS=12 FAIL=0 ERROR=0`.

الحزمة الكاملة:

`FILES=16 PASS=205 FAIL=0 ERROR=0`.


### 077 — App Bootstrap Read Contract — ق-82

الملف:

`20260817023001_077_app_bootstrap_read_contract.sql`

**الحالة: مطبقة ومثبتة محليًا — 2026-08-17.**

المنجز:

- إضافة `api.app_bootstrap()`.
- قراءة ملف المستخدم من هوية جلسة الدخول.
- إرجاع الآبار ذات الوصول الفعلي فقط.
- تجميع الأدوار النشطة لكل بئر.
- دعم وصول الشريك الحالي من `core.well_partners`.
- إبقاء `iam.roles` خارج مصدر التفويض الحالي حتى حسم م-18.
- SECURITY INVOKER.
- anon محجوب.
- لا Direct DML جديد.
- لا علاقات جدولية داخل `api`.

الاختبار:

`20260817_077_app_bootstrap_read_contract.test.sql`

النتيجة:

`PASS=12 FAIL=0 ERROR=0`.

الحزمة الكاملة:

`FILES=17 PASS=217 FAIL=0 ERROR=0`.

Data API:

`RPC=33`.

---

## 078 — W1-01 / Explicit Profile ↔ Person Identity Link

**الحالة الحالية:** منفذة ومتحقق منها محليًا؛
دخلت Local Applied Baseline وCloud Applied Baseline حتى 078.

الملف:

`20260819200401_078_profile_person_identity_links.sql`

الاختبار:

`20260819_078_profile_person_identity_links.test.sql`

تضيف:

- `iam.profile_person_links`.
- Tenant-aware explicit identity mapping.
- active uniqueness.
- historical link protection.
- `iam.current_person_id(uuid)`.

لا تضيف:

- `api.*` RPC.
- Farmer RLS rewrite.
- Role Catalog wiring.
- Entitlement model.
- Backfill تخميني.

**دليل التحقق المحلي:** `db:reset` طبق 078 فعليًا؛
Permanent Test 078 = 18 PASS / 0 FAIL / 0 ERROR؛
Full DB Suite = 18 files / 235 PASS / 0 FAIL / 0 ERROR.

**دليل التحقق السحابي لـ078:**

- Remote migration history = 77 migrations؛ last = `20260819200401`.
- `iam.profile_person_links` موجودة وRLS مفعلة.
- لا Direct SELECT/INSERT/UPDATE/DELETE لأدوار التطبيق.
- `iam.current_person_id(uuid)` متاحة لـauthenticated وليست لـanon.
- الفهارس الفعالة مطابقة ولا يوجد الفهرس الزائد المحذوف.
- `api` بقي 33 authenticated RPC؛ anon = 0؛ SECURITY DEFINER = 0.
- عدد روابط الأشخاص أثناء التحقق السحابي = 0.
- Permanent Test 078 المحلي = 18 PASS / 0 FAIL / 0 ERROR.

---

## Migration 079 — Farmer self-scope authorization

**الملف:** `20260819224401_079_farmer_self_scope_rls.sql`

**المرحلة:** W1-02 / م-16 / ق-111.

**الحالة:** مطبقة ومتحقق منها محليًا وسحابيًا؛ م-16 مغلقة.

### ما تغير

- أزيل Farmer well-wide SELECT القديم.
- أضيفت Farmer self helpers في `iam`.
- Person/Contacts/Aliases أصبحت Self-only للمزارع.
- Farmer Profiles/Accounts/Farms/Bookings/Sessions وتوابعها أصبحت Self-only.
- Staff access للـowner/manager/operator بقي محفوظًا.
- `api.*` surface لم تتغير.
- Direct DML بقي صفرًا.

### دليل التحقق

- Permanent Test 079 = 20 PASS / 0 FAIL / 0 ERROR.
- Full DB Suite = 19 files / 255 PASS / 0 FAIL / 0 ERROR.

**دليل Cloud لـ079:**

- Remote migration history = 78 migrations through `20260819224401`.
- Farmer self-scope policies = 19.
- Legacy Farmer broad policies in W1-02 scope = 0.
- Target tables with RLS disabled = 0.
- Supporting indexes = 9.
- API = 33 authenticated / 0 anon / 0 SECURITY DEFINER / 0 relations.
- Direct DML = 0.
- لا Security Advisor warning جديد من 079.

Migration 071–084 immutable.
أي DB change جديد يبدأ Migration 085+.

---

## Migration 080 — Permission authority foundation

**الملف:** `20260819235001_080_permission_authority_foundation.sql`

**المرحلة:** W1-03 / م-18 / ق-112.

**الحالة:** مطبقة ومتحقق منها محليًا وسحابيًا.
م-18 لم تغلق بـ080 — الإنفاذ انتقل في 081+082 وأُغلقت هناك.

### ما تغير

- Permission catalog توسع من 21 إلى 38 code لتغطية تدفقات
  V1 المنفذة في 073/074 (session.resume، invoice.issue،
  payment.allocate، distribution.pay، fuel.*، shift.*،
  handover.*، session.transfer.*، payroll.*).
- أضيف `iam.well_assignment_role_map` كـCanonical bridge من
  `core.well_assignments.role` إلى `iam.roles`؛ 6 صفوف،
  و`farmer` مستثنى عمدًا.
- `core.well_assignments_role_check` وسّع ليقبل `accountant`
  و`viewer` دون إبطال أي قيمة قائمة.
- `iam.role_permissions` seed محافظ = 70 صف:
  tenant_owner 38 / well_manager 12 / operator 20.
- partner / accountant / viewer = صفر write grants.
- أضيفت `iam.has_well_permission(uuid, text)` كدالة الفحص
  الـCanonical؛ STABLE + SECURITY DEFINER + fixed `search_path`؛
  EXECUTE لـauthenticated فقط.
- `iam.has_well_role` و273 RLS policy بقيت Compatibility Layer
  دون تعديل.
- `api.*` surface لم تتغير.
- Direct DML بقي صفرًا.

### ما لم تفعله 080 عمدًا

- لا نقل إنفاذ إلى Permission Codes — ذلك Migration 081.
- لا تعديل على أي RLS policy قائمة.
- لا Tenant-wide access؛ النطاق يبقى `well_id`.
- لا توسع ولا تضييق لصلاحيات أي مستخدم حالي.
- لا أثر على Farmer self-scope من 079.

### دليل التحقق

- Permanent Test 080 = 20 PASS / 0 FAIL / 0 ERROR.
- Full DB Suite = 20 files / 275 PASS / 0 FAIL / 0 ERROR.
- Permission catalog = 38؛ new codes = 17.
- Role permissions = 70؛ partner/accountant/viewer = 0.
- Bridge rows = 6؛ farmer map rows = 0.
- Legacy `has_well_role` policies = 273 دون تغيير.
- inactive assignment = deny.
- Cross-well permission leak = 0.
- multi-role = Union بلا owner escalation.
- unknown permission code = false.
- API = 33 authenticated / 0 anon / 0 SECURITY DEFINER.
- Direct DML = 0.

**دليل Cloud لـ080:**

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
- النتيجة = `CLOUD_080_ALL_PASS` (20 / 20).

**دليل Data API boundary من خارج قاعدة البيانات:**

- Default exposed schema = `api`؛ anon مرفوض.
- `core` / `iam` / `public` / `audit` / `reporting` = محجوبة.
- جداول عبر `api` = 0.
- النتيجة = `DATA_API_BOUNDARY=OK`.

Migration 071–084 immutable.
أي DB change جديد يبدأ Migration 085+.

---

## Migration 081 — Permission enforcement: money domain

**الملف:** `20260822003001_081_permission_enforcement_money.sql`

**المرحلة:** W1-03b / م-18 / ق-113.

**الحالة:** مطبقة ومتحقق منها محليًا وسحابيًا.

### ما تغير

- أُنشئت `session.energy.change` — الفجوة الوحيدة في الكتالوج:
  `ops.change_session_energy_source` كانت بلا permission code
  إطلاقًا. مُنحت لـtenant_owner + well_manager + operator
  حرفيًا كما كان الحرس النصي. الكتالوج = 39؛ المنح = 73.
- 13 موضع حرس في 13 دالة مالية انتقلت من
  `iam.has_well_role(well_id, array[...])` إلى
  `iam.has_well_permission(well_id, '<code>')`:

  | الدالة | الصلاحية |
  |---|---|
  | `billing.issue_session_invoice` | `invoice.issue` |
  | `billing.record_payment` | `payment.create` |
  | `billing.allocate_payment` | `payment.allocate` |
  | `finance.pay_partner_distribution` | `distribution.pay` |
  | `api.record_expense` | `expense.create` |
  | `api.decide_expense` | `expense.approve` |
  | `api.confirm_handover` | `handover.confirm` |
  | `api.settle_handover` | `handover.settle` |
  | `api.close_period` | `period.close` |
  | `api.calculate_profit_distribution` | `distribution.calculate` |
  | `api.approve_profit_distribution` | `distribution.approve` |
  | `api.accrue_payroll` | `payroll.accrue` |
  | `api.pay_salary` | `payroll.pay` |

- فحوص الهوية وفحص تسجيل الدخول محفوظة في الـ13 كلها.
- المنح محفوظة بـ`create or replace function` بلا إعادة إصدار.

### ما لم تفعله 081 عمدًا

- لا تعديل على أي RLS policy — 273 policy تبقى على
  `has_well_role` كطبقة توافق.
- لا توسيع ولا تضييق لأي دور.
- لا تحويل لحرس الهوية.
- لا إضافة `api.*` جديدة؛ Direct DML يبقى صفرًا.

### دليل التحقق

- Permanent Test 081 = 20 PASS / 0 FAIL / 0 ERROR.
- Cloud Test 081 = 20 PASS / 0 FAIL / 0 ERROR.
- 13 دالة على السلطة الجديدة / 0 على القديمة.
- owner = الـ13 كلها؛ manager = 7؛ operator = 4 —
  مطابقة للحرس النصي قبل النقل.
- partner / viewer = 0.
- سحب منح واحد يسري في اللحظة والدور يبقى.

---

## Migration 082 — Permission enforcement: operations domain

**الملف:** `20260822013001_082_permission_enforcement_ops.sql`

**المرحلة:** W1-03b / م-18 / ق-113.

**الحالة:** مطبقة ومتحقق منها محليًا وسحابيًا.
**م-18 تغلق بهذه الهجرة.**

### ما تغير

- 15 موضع حرس في 14 دالة تشغيلية انتقلت إلى
  `iam.has_well_permission`:

  | الدالة | الصلاحية |
  |---|---|
  | `ops.start_irrigation_session` | `session.start` |
  | `ops.pause_irrigation_session` | `session.pause` |
  | `ops.resume_irrigation_session` | `session.resume` |
  | `ops.complete_irrigation_session` | `session.complete` |
  | `ops.change_session_energy_source` | `session.energy.change` |
  | `ops.create_farmer` | `farmer.create` |
  | `ops.create_farm` | `farm.create` |
  | `ops.create_booking` | `booking.create` |
  | `ops.reschedule_booking` | `booking.reschedule` |
  | `inventory.purchase_fuel` | `fuel.purchase` |
  | `inventory.record_fuel_consumption` | `fuel.consume` |
  | `inventory.record_physical_fuel_count` | `fuel.count` |
  | `api.open_shift` | `shift.open` |
  | `api.close_shift` (حرسان) | `shift.close_override` |

- `ops.create_farm` نُقلت من تعريف **075** لا 069:
  075 تُسقط `ops.create_farm(uuid, text, uuid)`، فنقل جسد 069
  كان سيُحيي التعريف المُسقط ويلغي تحسين 075 صامتًا.
  التوقيع الحي = `(p_well_id, p_name, p_farmer_well_account_id)`.
- `api.close_shift` يحمل حرسين: فرع الهوية
  (`v_actor is distinct from v_operator_profile_id`) بقي كما هو،
  وفرع التجاوز الإداري (`p_allow_open_sessions`) انتقل إلى
  `shift.close_override` — وهي بيد tenant_owner وحده أصلًا،
  فلا منح جديد.

### ما لم تفعله 082 عمدًا

- `api.declare_handover` / `api.request_session_transfer` /
  `api.respond_session_transfer` بقيت بلا حرس دور — تفوّض
  بالهوية وحدها. تحويلها كان سيمنع المشغّل من تسليم نقده أو
  جلسته: عطل ميداني لا يوجد اليوم.
- لا تعديل على أي RLS policy.
- لا توسيع ولا تضييق لأي دور.

### دليل التحقق

- Permanent Test 082 = 20 PASS / 0 FAIL / 0 ERROR.
- Cloud Test 082 = 20 PASS / 0 FAIL / 0 ERROR.
- Full DB Suite = 22 files / 315 PASS / 0 FAIL / 0 ERROR —
  صفر Regression على 295 فحصًا من جولات سابقة.
- Function-body guards على `has_well_role` = **0** في
  api/ops/billing/finance/inventory/core/reporting.
- Legacy RLS policies = 273 دون تغيير، وهي المستهلك الوحيد.
- owner = الـ14 كلها؛ manager = سلطة الجلسة الخمس فقط؛
  operator = 12 (الميدان كاملًا بلا `farm.create` وبلا
  `shift.close_override`).
- `ops.create_farm` = توقيع 075 وحده، تعريف واحد.
- api.* invoker = 2؛ الدوال الداخلية definer = 12.
- API = 33 authenticated / 0 anon / 0 SECURITY DEFINER.
- Direct DML = 0.
- Remote migration history = 81 through `20260822013001`.
- النتيجة السحابية = `CLOUD_W1_03B_ALL_PASS`.

### أثر جانبي على اختبار 080

اختبار 080 كان يؤكد الكتالوج = 38 والمنح = 70. إضافة
`session.energy.change` تجعله يفشل، فحُدّث إلى 39 و73
(owner 39 / manager 13 / operator 21). **ملف Migration 080
نفسه لم يُمسّ** — المعدَّل هو ملف اختباره فقط، وهذا تعديل
اختبار مسموح لا تعديل هجرة مختومة.

Migration 071–084 immutable.
أي DB change جديد يبدأ Migration 085+.

### ملاحظة ترقيم

عدد ملفات الترحيل المحلية = 83 بينما أعلى رقم = 084.
السبب أن الرقم 067 لم يُستخدم أصلًا؛ فجوة ترقيم تاريخية
وليست ملفًا ناقصًا.

---

## Migration 083 — Sync command resolvers

**الملف:** `20260823003001_083_sync_command_resolvers.sql`

**المرحلة:** W2-01 / م-25 / ق-114.

**الحالة:** مطبقة ومتحقق منها محليًا وسحابيًا.

### لماذا لزمت

`sync.processed_commands` و`sync.begin_command` /
`sync.finish_command` موجودة من 058، لكن **لا دالة واحدة على
الخادم كانت تستدعيها**، ولا واحدة من 33 دالة `api.*` تقبل
معرّف عملية. البنية كانت مبنية وغير موصولة.

و`sync.begin_command` تأخذ `p_tenant_id` من المتصل بلا تحقق
(`058:26`)، فلا يجوز أن يصل هذا المعامل إلى العميل: تمرير
tenant غير مملوك يسمح بحجز `command_id` سلفًا فتبدو عملية
الضحية «مكرَّرة» فلا تُنفَّذ.

### ما تغير

- سُحبت منح `PUBLIC` الافتراضية عن مُنفِّذي 058:

  | الدالة | ما سُحب |
  |---|---|
  | `sync.begin_command(uuid,uuid,text,jsonb,uuid)` | `public`, `anon`, `authenticated` |
  | `sync.finish_command(uuid,uuid,text,jsonb)` | `public`, `anon`, `authenticated` |

  لا ثقب حيًّا كان قائمًا لأن `sync` غير مكشوف عبر Data API
  (`config.toml` يكشف `api` و`graphql_public` فقط)، لكن بقاء
  المنح يخالف Least Privilege في ق-89 بند 22 ويجعل الأمان
  معتمدًا على إعداد خارجي وحده لا على منح قاعدة البيانات.

- أُضيفت 4 مُحلِّلات تستخرج الجهة على الخادم ثم تنادي
  مُنفِّذي 058 القائمين (إعادة استخدام لا استبدال، وفق ق-89
  بند 10):

  | المُحلِّل | مصدر الجهة | يُستخدم في |
  |---|---|---|
  | `sync.begin_well_command(uuid,uuid,text,jsonb)` | `core.wells` | بدء جلسة، دفعة، مزارع، أرض |
  | `sync.finish_well_command(uuid,uuid,text,jsonb)` | `core.wells` | تثبيت نتائج الأربع أعلاه |
  | `sync.begin_session_command(uuid,uuid,text,jsonb)` | `ops.irrigation_sessions` ← `core.wells` | Pause / Resume / تغيير الطاقة / الإنهاء |
  | `sync.finish_session_command(uuid,uuid,text,jsonb)` | `ops.irrigation_sessions` ← `core.wells` | تثبيت نتائج الأربع أعلاه |

- كلها `security definer` + `volatile` +
  `set search_path = pg_catalog, pg_temp`، وEXECUTE مسحوبة
  ثم ممنوحة صراحة لـ`authenticated` و`service_role` فقط —
  وهما بالضبط مستفيدو أغلفة `api` الثمانية، فلا توجد هوية
  تستطيع بدء العملية ولا تستطيع إتمامها. `anon` = صفر.
- `security definer` لازم لأن 072 سحبت DML من `authenticated`
  على كل المخططات الداخلية بما فيها `sync`، وأغلفة `api`
  تبقى `security invoker` وفق ق-78.

### Scope is not Authority

المُحلِّل يشترط تعيينًا نشطًا على البئر
(`core.well_assignments` بـ`profile_id = auth.uid()` و
`status = 'active'`) **بلا اشتراط دور**. هذا حدّ نطاق لا
قرار صلاحية؛ القرار يبقى في الدوال الداخلية عبر
`iam.has_well_permission` (ق-113).

**البرهان على غياب Silent Drift:** الشرط لا يرفض عملية كانت
الدالة الداخلية ستقبلها، لأن `iam.has_well_permission` نفسها
تشترط `wa.profile_id = auth.uid() and wa.status = 'active'`
(`080:243`). فالعضوية النشطة شرط لازم لكل واحدة من العمليات
الثماني، ومن يجتاز فحص الصلاحية الداخلي يجتازها حتمًا.

### لا كشف للوجود

«بئر جهة أخرى» و«بئر غير موجود» يعطيان الرسالة نفسها
حرفيًا، فلا يصلح المُحلِّل أداة استكشاف لمعرّفات جهات أخرى.
نفس القاعدة للجلسة.

### ما لم تفعله 083 عمدًا

- لا جدول جديد ولا عمود جديد ولا RLS policy واحدة.
- لا تعديل على `sync.begin_command` / `finish_command`
  أنفسهما — 058 مختومة وهما المُنفِّذ الفعلي كما هما.
- لا قرار صلاحية داخل أي مُحلِّل؛ صفر إشارة إلى
  `has_well_permission` أو `has_well_role`.
- لا كشف لـ`sync` عبر Data API؛ المُحلِّلات ليست عقدًا للعميل.

### دليل التحقق

- Permanent Test 083 = 16 PASS / 0 FAIL / 0 ERROR.
- Cloud Test 083 = 16 PASS / 0 FAIL / 0 ERROR.
- المُحلِّلات = 4 definer بمسار بحث مثبَّت وتوقيعات مطابقة
  لما تتوقعه أغلفة `api` بالضبط.
- صفر مُحلِّل يقبل معامل جهة؛ صفر مُحلِّل يتخذ قرار صلاحية.
- `authenticated` = 4 / `service_role` = 4 / `anon` = 0.
- مُنفِّذو 058 في متناول أدوار العميل = **0**.
- الغريب مُنع، والتعيين غير النشط مُنع، ونفس الرسالة
  للحالتين، ومعرّف العملية مطلوب.
- تكرار المعرّف يعيد النتيجة المخزَّنة بصفّ واحد.
- Direct DML = 0 بعد 083.

---

## Migration 084 — Idempotent api writes

**الملف:** `20260823013001_084_api_idempotent_writes.sql`

**المرحلة:** W2-01 / م-25 / ق-114.

**الحالة:** مطبقة ومتحقق منها محليًا وسحابيًا.

### ما تغير

الأغلفة الثمانية للدورة الميدانية الأولى أُعيد تعريفها
بوسيط أخير اختياري `p_command_id uuid default null`:

| غلاف `api` | عدد الوسائط بعد التغيير | الإرجاع | المُحلِّل المستخدم |
|---|---|---|---|
| `start_irrigation_session` | 8 | `uuid` | well |
| `pause_irrigation_session` | 4 | `uuid` | session |
| `change_session_energy_source` | 7 | `uuid` | session |
| `resume_irrigation_session` | 3 | `uuid` | session |
| `complete_irrigation_session` | 6 | `jsonb` | session |
| `record_payment` | 12 | `jsonb` | well |
| `create_farmer` | 7 | `jsonb` | well |
| `create_farm` | 4 | `jsonb` | well |

المنطق في كل غلاف:

1. `p_command_id is null` ⟹ المسار القديم حرفيًا، بلا فرق.
2. وإلا: حجز عبر `sync.begin_*_command`.
3. إن كان الحجز `duplicate` وحالته `accepted` ⟹ تُعاد
   النتيجة الأولى المخزَّنة كما هي.
4. إن كان `duplicate` بحالة أخرى ⟹ رفض صريح.
5. وإلا: تُنفَّذ الدالة الداخلية، ثم
   `sync.finish_*_command(..., 'accepted', ...)`.

للدوال `returns uuid` تُخزَّن النتيجة
`jsonb_build_object('id', v_id)` وتُعاد
`(response ->> 'id')::uuid`.

### قيود التصميم التي فرضت الشكل

- **استبدال لا إضافة.** سطح `api` مقفل على 33 دالة بخمسة
  اختبارات (`078:570`، `079:114`، `080:227`، `081:262`،
  `082:304`)؛ إضافة overload كانت ستجعله 41 وتُسقط الخمسة.
  لذلك `drop function` ثم `create function` بنفس الاسم.
- **المنح تُفقد بالحذف** فأُعيد إصدارها صراحة: سحب من
  `public`/`anon` ثم منح لـ`authenticated` و`service_role`.
- **الأغلفة تبقى `security invoker`** مع `search_path` مثبَّت
  وفق ق-78؛ صفر SECURITY DEFINER في `api` محفوظ.
- **`create_farm` أُخذ من تعريف 075 الحي** لا 073 — نفس سبب
  ق-113 في `ops.create_farm`.
- **فحص التبعيات أُجري قبل الحذف:** لا view ولا trigger ولا
  دالة أخرى تستدعي أيًّا من الأغلفة الثمانية، فـ`drop` آمن.

### لا تسجيل للرفض ولا حالة عالقة

استدعاء RPC واحد = transaction واحدة. عند رفض العملية لسبب
عمل تتراجع الـtransaction كلها **بما فيها صفّ
`begin_command`**، فلا يبقى أثر وإعادة المحاولة تُنفَّذ من
جديد بأمان بلا «تلويث» لمعرّف العملية.

ولنفس السبب **حالة `processing` العالقة مستحيلة** ولا تحتاج
مُنظِّفًا دوريًا: الإدراج والإنهاء يُثبَّتان أو يتراجعان معًا.

### ما لم تفعله 084 عمدًا

- لا تعديل على أي دالة داخلية في 081/082 — الأغلفة فقط.
- لا تغيير على ترتيب الوسائط القائمة؛ الإضافة في الآخر
  حصرًا، فكل نداء قائم يبقى صحيحًا موضعيًا.
- خارج النطاق: الورديات ونقل الجلسة والحجوزات (ق-98)
  والمصروفات والتوزيعات (ق-99) — تُنقل بنفس النمط بعد
  إثباته على الثماني.

### دليل التحقق

- Permanent Test 084 = 23 PASS / 0 FAIL / 0 ERROR.
- Cloud Test 084 = 23 PASS / 0 FAIL / 0 ERROR.
- Full DB Suite = **24 files / 354 PASS / 0 FAIL / 0 ERROR** —
  صفر Regression على 315 فحصًا من جولات سابقة.
- الأغلفة الثمانية كلها تقبل `p_command_id` أخيرًا، وكلها
  invoker بمسار بحث مثبَّت، ولـ`authenticated` و
  `service_role` بلا `anon`.
- نفس `command_id` مرتين ⟹ صفّ واحد، ونفس المعرّف/النتيجة.
- `record_payment`: **الإجمالي لم يتضاعف** — قياس مبلغ لا
  عدد صفوف فقط.
- `p_command_id = null` ⟹ السلوك القديم حرفيًا.
- `command_id` مختلف ⟹ عمليتان فعلًا؛ لا حجب زائد.
- معرّف عملية محجوز في جهة أخرى لا يحجب عملية هذه الجهة.
- API = 33 authenticated / 0 anon / 0 SECURITY DEFINER.
- Direct DML = 0.
- Remote migration history = 83 through `20260823013001`.
- النتيجة السحابية = **`CLOUD_W2_01_ALL_PASS`**
  (39 PASS / 0 FAIL / 0 ERROR)، و`DATA_API_BOUNDARY=OK`،
  و`API_SURFACE/ANON/DEFINER/DIRECT_DML = 33/0/0/0`.

### أثر جانبي على اختبارَي 073 و075

الاختباران كانا يؤكدان توقيعات `api.create_farm` و
`api.start_irrigation_session` بعدد الوسائط القديم، فأُضيف
`p_command_id uuid` إلى النص المتوقَّع في موضعين محدَّدين
فقط. **السطر الذي يرفض توقيعًا زائدًا في 073 بقي كما هو** —
ما زال يجب ألّا يوجد. وموضع `ops.create_farm` الداخلية في
075 لم يُمسّ. ملفا Migration 073 و075 أنفسهما لم يُمسّا؛
المعدَّل ملفا الاختبار، وهذا تعديل اختبار مسموح.

### ملاحظة مكتشفة أثناء التحقق — ليست من هذه الجولة

دفعة الرصيد المقدم (بلا فاتورة جلسة) لا تُقرأ عبر
`authenticated`، لأن `payments_select_assigned` (`016:45`)
تشترط ارتباط الدفعة بفاتورة جلسة. الكتابة تنجح والقراءة
تُحجب. سلوك قائم قبل ق-114 ولا علاقة له بها؛ لذلك يعدّ
اختبار 084 الدفعات كـ`postgres` لقياس ما كُتب فعلًا، بنفس
أسلوب الخروج المؤقت من الدور في اختبار 075 فحص 8.

الأثر المستقبلي: المشغّل — وهو من يستلم النقد — لن يرى
الدفعة على شاشته حين تُبنى شاشة الدفعات. يُحسم مع عقد قراءة
المال (م-29).

Migration 071–084 immutable.
أي DB change جديد يبدأ Migration 085+.

---

## حدث تشغيلي — إعادة بناء المشروع السحابي 2026-08-21

**السبب:** تعذّر الوصول إلى البريد الإلكتروني المرتبط
بحساب Supabase السابق. أنشأ المالك حسابًا جديدًا ومشروعًا
جديدًا في منطقة South Asia (Mumbai).

**ما فُقد:** لا شيء له قيمة.

- المشروع السابق كان Schema فقط بلا بيانات إنتاجية
  وبلا مستخدمين حقيقيين.
- لا ملف متتبَّع في المستودع يذكر المشروع السابق؛
  إعداد التطبيق يقرأ `SUPABASE_URL` و
  `SUPABASE_PUBLISHABLE_KEY` من البيئة ولا يخزّن شيئًا.
- لا مفاتيح ولا كلمات مرور في المستودع.

**ما أُعيد بناؤه:** الـ79 migration كلها بالترتيب الزمني
من 001 إلى 080، ثم أُعيد ضبط Exposed schemas.

### قناة النشر السحابي المثبتة

`db push` عبر Supavisor session mode (المنفذ 5432) والاتصال
المباشر IPv6 كلاهما لا يصل من شبكة المالك:

- direct IPv6 `db.<ref>.supabase.co:5432` = فشل.
- pooler `aws-0`/`aws-1` port 5432 = فشل المصادقة/المهلة.
- pooler `aws-0` **port 6543** (transaction mode) = **يعمل**.

القناة العاملة الوحيدة = Supavisor transaction mode / 6543.

لذلك النشر السحابي يجري بسكربت `psql` قابل للاستكمال:

1. ينشئ `supabase_migrations.schema_migrations` إن لم يوجد.
2. يقرأ ما طُبق فعلًا ويتخطاه.
3. يطبق كل migration داخل معاملة واحدة ويسجّل صفها.
4. يتوقف عند أول فشل ويطبع الخطأ، وإعادة التشغيل تكمل
   من موضع التوقف.

الحقائق التي تسمح بذلك: مجموع الـ79 ملفًا = 0.52 MB،
وصفر أوامر `concurrently` / `vacuum` / `reindex`،
وترتيب أسماء الملفات = الترتيب الزمني.

هذه القناة لا تغيّر أي قاعدة حاكمة: لا تعديل يدوي على
Remote Database خارج Migration workflow، ولا استخدام
`config push` لنشر DB migrations. الملفات هي المصدر،
والسكربت مجرد ناقل بديل عن `db push` المحجوب شبكيًا.

### إعداد Data API بعد إعادة البناء

`api` schema تُنشأ في Migration 071، فلا تظهر في
Exposed schemas قبل تطبيق الترحيلات. الترتيب الصحيح:

login → build → set Exposed schemas → verify.

القيمة المعتمدة = `api` **أولًا** ثم `graphql_public`.
`api` يجب أن تكون الأولى لأنها الـschema الافتراضية
لأي طلب بلا ترويسة صريحة. `public` غير مكشوفة.

## 085 — 20260823200001_085_backend_gap_fixes.sql

**الهدف:** إغلاق الفجوات الخلفية في RLS والوقود ونموذج التسعير وحماية الدوال الداخلية.

**ما تفعله:**
1. **تصحيح RLS الدفعات:** تحديث سياسة `billing.payments` (`payments_select_assigned`) لتسمح للمشغل/المالك بقراءة الدفعات المقدمة والديون القديمة عبر `well_id` حين يكون `session_charge_id IS NULL`.
2. **تصحيح احتساب الوقود (ق-17 / ق-91):** قصر `total_charge_minor` على `time_charge_minor` فقط في جدول `ops.session_segments` وإلغاء إضافة الوقود كرسوم على المزارع مع إبقائه كقيد رقابي في `fuel_charge_minor`.
3. **سحب صلاحية التنفيذ:** سحب `EXECUTE` على كافة دوال المخططات الداخلية الحالية والمستقبلية من دور `anon` وحمايتها عبر `alter default privileges`.
4. **إلغاء نموذج التسعير المتقاعد:** إلغاء `operation_plus_fuel` وحصر نموذج الديزل على `inclusive_hourly` فقط في قيود جدول `ops.price_rules`.

## 089 — 20260831010001_089_operations_read_contracts.sql

**الهدف:** إضافة أول عقود قراءة للعمليات في `api` وإغلاق سبب
اعتماد شاشات المزارعين والأراضي والمضخات على بيانات تجريبية.

**السبب:** المخططات الداخلية (`ops` / `core`) غير مكشوفة في
Data API، فكل قراءة مباشرة منها تفشل ويستبدلها العميل بـmock.

**ما تفعله:**
1. `api.list_well_farmers(uuid, text, integer)` — مزارعو البئر
   النشطون، مع بحث اختياري بالاسم أو الرمز أو رقم الاتصال
   (`contact_value` و`normalized_value`)، وحد نتائج مثبت.
2. `api.list_well_farms(uuid, uuid)` — أراضي البئر النشطة، مع
   تصفية اختيارية بحساب المزارع.
3. `api.list_well_pumps(uuid)` — مضخات البئر النشطة.

**الخصائص:** الثلاثة `security invoker` + `stable` +
`set search_path = pg_catalog, pg_temp`، لا `SECURITY DEFINER`،
لا وسيط جدول/مخطط ديناميكي، التفويض من RLS القائمة، fail-closed
بـ`42501` على بئر غير مرئي و`22023` على معرّف فارغ، ترتيب حتمي،
`revoke` شامل ثم `grant execute` لـ`authenticated`/`service_role`
فقط. لا جدول ولا View جديد، ولا توسيع Direct DML.

**الاختبار:** `supabase/tests/20260831_089_operations_read_contracts.test.sql`.

**التحقق المحلي (2026-08-31، بعد `db:reset` + `db:test`):**
- Target 089 = **20 PASS / 0 FAIL / 0 ERROR**.
- Full suite = **27 files / 389 PASS / 0 FAIL / 0 ERROR**
  (خط الأساس السابق 369، بلا أي انحدار).
- `api` SECURITY DEFINER = **0**؛ `api` بلا جداول/Views؛
  Direct DML = **0** بعد إضافة العقود.
- anon مرفوض على العقود الثلاثة؛ البئر غير المرئي مرفوض بـ`42501`.
- Cloud: **غير منشورة** — النشر السحابي خطوة مستقلة لاحقة.

## 091 — 20260831030001_091_well_management_contracts.sql

**الهدف:** إغلاق حدود إدارة البئر: أربعة عقود قراءة وثلاثة أزواج
كتابة في `api`، بدل قراءات مباشرة من `core`/`ops`/`inventory` كانت
تفشل ويستبدلها العميل ببيانات تجريبية.

**السبب:** شاشات إعدادات البئر والمضخات والتسعير والوقود كانت آخر
كتلة تعتمد mock في المستودع، ولم يكن في القاعدة عمود لموقع البئر
ولا عمقه ولا منسوب ماءه الساكن.

**ما تفعله:**
1. `core.wells` + ثلاثة أعمدة: `location text`,
   `depth_meters numeric`, `static_water_level_meters numeric`،
   مع قيدَي تحقق يمنعان السالب.
2. كتالوج الصلاحيات: `well.update` و`pump.manage`، ممنوحتان
   لـ`tenant_owner` وحده.
3. قراءة: `api.get_well_details(uuid)`,
   `api.list_well_pumps_detail(uuid, boolean)`,
   `api.get_active_price_schedule(uuid, timestamptz)`,
   `api.list_well_fuel_tanks(uuid, boolean)`.
4. كتابة كأزواج (ق-79): `core.update_well_details`,
   `core.save_well_pump`, `ops.create_price_schedule` إجراءات
   `security definer` تحمل فحص `iam.has_well_permission`، يتقدمها
   ثلاثة أغلفة `api.*` رقيقة `security invoker` لا تفعل إلا بناء
   المظروف.

**لماذا أزواج ولا كتابة مباشرة من `api`:** Migration 072 سحبت
`insert/update/delete` على كل جداول المخططات الداخلية من
`authenticated`، فدالة `security invoker` لا تستطيع الكتابة أصلًا.
الفحص الاسمي يسكن الإجراء الداخلي لأن `security definer` يتجاوز
RLS، فهو التفويض الفعلي لا تحسينًا.

**أثر على ملفات اختبار محسومة سابقًا:** ثلاثة عدّادات صلاحيات
حُدِّثت بقصد، كل تحديث بتعليق يسمّي 091 سببًا:
- `20260819_080…`: الكتالوج 39 → 41، والإجمالي 73 → 75،
  ونصيب `tenant_owner` 39 → 41.
- `20260822_081…`: الكتالوج 39 → 41، و`role_permissions` 73 → 75.

**الاختبار:** `supabase/tests/20260831_091_well_management_contracts.test.sql`.

**التحقق المحلي (2026-09-01، بعد `db:reset` + `db:test`):**
- Target 091 = **34 PASS / 0 FAIL / 0 ERROR**.
- Full suite = **29 files / 448 PASS / 0 FAIL / 0 ERROR**.
- `api` SECURITY DEFINER = **0**؛ الأغلفة كلها INVOKER؛ الإجراءات
  الداخلية الثلاثة DEFINER بـ`search_path` مثبت.
- `iam.has_well_role` في أجساد الدوال = **0** (م-18 محفوظة).
- Cloud: **مطبَّقة** — وصلت تلقائيًا عبر تكامل `GitHub` عند دفع
  `ba4176c` إلى `main` (2026-09-01)، لا بسكربت يدوي. واختبارات
  091 لم تُشغَّل على السحابة، فحالتها هناك = مطبَّقة لا مُتحقَّقة.

## 092 — 20260902010001_092_finance_read_contracts.sql

**الهدف:** خمسة عقود قراءة في `api` تغلق آخر حدّ مكسور: أربع قراءات
مالية ومؤشرات التقارير. بها ينتهي الدين المعلَن كله (bare RPC
ودotted-from وinternal-schema) إلى صفر.

**السبب:** الشاشات المالية لم تقرأ بيانات حقيقية ولا مرة. خمس
قراءات كانت `from('schema.table')` على مخططات غير مكشوفة، وكل
واحدة ملفوفة بـ`catch(_)` يعيد بيانات تجريبية — فالفشل يظهر
للمستخدم نجاحًا، وأرقام مال ثابتة تُعرض كأنها حساب.

**أدلة جُمعت قبل كتابة أي سطر (لا Blind Remap):**
1. `iam.well_memberships` الذي تقرأه شاشة الشركاء **لا وجود له**
   في أي من التسعين هجرة. المصدر الحقيقي `core.well_partners`،
   والنِسَب `core.ownership_share_versions`، والمال أسطر
   `finance.profit_distribution_lines`.
2. `billing.invoices` **لا تحتوي** `issue_date`؛ العمود
   `invoice_date`.
3. **لا يوجد** `public.farms`؛ الأراضي `ops.farms`، وربطها
   بالفاتورة عبر `ops.irrigation_sessions.farm_id`.
4. محلّلات العميل تنتظر مفاتيح لا ينتجها جدول خام
   (`category_name`، `partner_name`، `distributable_profit_minor`،
   `invoice_number`، `farm_name`، `allocated_invoices`…) — أي أنها
   كُتبت لعقد لم يُبنَ قط. هذه الهجرة تبنيه بالأسماء نفسها فوق
   أعمدة موجودة.
5. الأرقام التي كان العميل يلفّقها **محسوبة أصلًا** في `reporting`
   منذ 060 (`partner_account_summary`، `farmer_account_balances`)،
   والمدفوع للشريك عمود حقيقي `paid_minor` من 068. فالعلاج أصغر
   من الدين: توصيل لا اختراع.

**العقود:**

| العقد | الوسائط | الحد | الترتيب |
|---|---|---|---|
| `api.list_well_expenses` | `p_well_id uuid`, `p_status text`, `p_limit integer default 100` | 1..500 | `spent_at desc, id desc` |
| `api.list_well_partners` | `p_well_id uuid`, `p_limit integer default 100` | 1..200 | `full_name, id` |
| `api.list_well_profit_cycles` | `p_well_id uuid`, `p_limit integer default 24` | 1..120 | `period_start desc, id desc` |
| `api.get_farmer_account` | `p_farmer_well_account_id uuid`, `p_limit integer default 50` | 1..200 | `invoice_date desc` / `paid_at desc` |
| `api.get_reports_summary` | `p_well_id uuid`, `p_period text default 'this_month'`, `p_start timestamptz`, `p_end timestamptz` | 92 يومًا للفترة المخصصة | `day` / `week_start` / `energy_source` |

**الخصائص:** الخمسة `security invoker` + `stable` +
`set search_path = pg_catalog, pg_temp`، لا `SECURITY DEFINER`
داخل `api`، ولا جدول ولا View. التفويض من RLS القائمة على
`core.wells` و`ops.farmer_well_accounts` — ولم يُخترع رمز صلاحية
للقراءة. fail-closed: `28000` بلا جلسة، `22023` لكل مدخل غير صالح،
`42501` على بئر أو حساب غير مرئي بدل قائمة فارغة غامضة. الترتيب
حتمي في كل قائمة **وفي كل قائمة داخلية** (أسطر الشركاء، تخصيصات
السند). `revoke all` ثم `grant execute` لـ`authenticated` و
`service_role` وحدهما.

**ق-99 داخل عقد قراءة:** لا حساب مال جديد. كل مبلغ يُقرأ من عمود
أو من عرض `reporting` قائم. والتحويل إلى ليتر أو ساعة أو نسبة
مئوية أو تسمية عربية مسؤولية طبقة العرض وحدها.

**استثناء واحد مقصود:** `remaining_minor` في سطر توزيع الشريك
يُعاد كفرق `net_payable_minor − paid_minor`، وهو التعريف نفسه الذي
تفرضه 068 داخل `finance.pay_partner_distribution` وتبني عليه قبول
الدفعة أو رفضها — ثابت مجالي لا تجميل عرض. أما «صافي التدفق»
(المحصَّل ناقص المصروف) فلا يُعاد: تحسبه الشاشة من رقمين مُعادين،
لأنه تجميع عرضي لا ثابت مجالي.

**حدّ معروف ومسجَّل:** لا عمود منطقة زمنية في `core.wells`، فحدود
اليوم تُحسب بـ`date_trunc` على UTC تمامًا كما في عرض
`well_daily_summary` القائم. وأسبوع التقارير يبدأ **السبت**
(العُرف المحلي) محسوبًا صريحًا `((dow + 1) % 7)` لا متروكًا
لـ`date_trunc('week')` الذي يبدأ الاثنين. توحيد حدود اليوم على
منطقة البئر بند مفتوح مستقل في `OPEN_ISSUES.md`.

**الاختبار:** `supabase/tests/20260902_092_finance_read_contracts.test.sql`
(**37 تحققًا**: وجود الخمسة وتوقيعاتها، STABLE+INVOKER+search_path،
ACL بلا anon، صفر DEFINER وصفر كائن علائقي في `api`، الرموز الثلاثة
للرفض، عزل بئرين، الأسماء مقابل أعمدة موجودة، الأسبوع السبتي،
الحدود المقصوصة، وأن كل رقم يعود محسوبًا من القاعدة لا من ثابت).

**التحقق المحلي:** **نجح في 2026-09-02** — المالك شغّل `db:reset` ثم
`db:test`: Target 092 = **37 PASS / 0 FAIL / 0 ERROR**، والحزمة كلها
**30 files / 485 PASS / 0 FAIL / 0 ERROR** (448 + 37). فحالة 092 على
القاعدة المحلية = **مطبَّقة ومُتحقَّقة**.

**التحقق السحابي:** **نجح في 2026-09-02** — دُمج الطلب `#13` مضغوطًا في
`main` بالالتزام `87a0529`، فنشر تكامل `GitHub` هجرة 092 على قاعدة
الإنتاج تلقائيًا. وأثبته `npm run cloud:verify` (سكربت قراءة فقط عبر
القناة 6543): 91 ملفًا على القرص مقابل 91 صفًا في
`supabase_migrations.schema_migrations`، `MISSING_IN_CLOUD=0`، وعقود
`api` الخمسة موجودة في مخطط `api` هناك. ويبقى أن ملفات
`supabase/tests` لا تُشغَّل سحابيًا، فالحالة الأدق سحابيًا = **مطبَّقة
ومُثبتة الوجود، غير مُتحقَّقة سلوكيًا**.

**تصحيح بيانات الاختبار قبل نجاحه:** ملف اختبار 092 نفسه حمل ستة
عيوب في بيانات التهيئة لا في العقود: `ops.farms.farmer_profile_id`
أسقطته 075، و`core.well_partners.share_ppm` أسقطته 051، ونسبة أرباح
الشريك الوحيد يجب أن تكون 100 لا 35 (زناد مجموع الأنصبة)، وسطر
التوزيع لا يُدخَل في دورة حالتها `approved`، ومجموع `gross_share_minor`
يجب أن يساوي `distributable_amount_minor`، وصرف الديزل يحتاج واردًا
قبله لأن خزان البئر يُنشأ تلقائيًا برصيد صفر (046). الدرس المُعمَّم:
هجرة تُطبَّق بنجاح لا تُثبت أن عقودها تشير إلى أعمدة حقيقية، لأن
`plpgsql` يؤجّل حل الأسماء إلى وقت التنفيذ — الاختبار السلوكي هو
البرهان الوحيد، وهذا يشمل بيانات الاختبار نفسها.

**تحذير النشر:** فرع `main` موصول بقاعدة الإنتاج عبر تكامل
`GitHub` (`Deploy to production` = ON). فدمج هذه الهجرة في `main`
**ينشرها على الإنتاج تلقائيًا** بلا تشغيل اختبارات هناك. حماية
الفرع يجب أن تكون فعّالة قبل الدمج.

## 093 — 20260902020001_093_price_read_for_operators.sql

**الهدف:** أن يرى **المشغل** سعر الساعة على شاشته قبل بدء السقي، بلا
فتح جداول التسعير للقراءة المباشرة وبلا تحويل صلاحية التعديل إلى
صلاحية اطلاع.

**السبب:** بعد م-41D6 صارت الشاشة تأخذ السعر من العقد لا من ثابت في
العميل — لكن العقد نفسه (091) يفحص `price.manage`، وهي ممنوحة لحزمة
`tenant_owner` وحدها (080). فالمشغل، وهو من يبدأ الجلسة فعلًا، يتلقى
`42501` وتظهر شاشته بلا تسعيرة. القرار المالكي: يجب أن يراها.

**أدلة جُمعت قبل كتابة أي سطر:**
1. `ops.start_irrigation_session` (066) **لا تأخذ سعرًا** إطلاقًا،
   وتفوّض على `iam.has_well_role(['owner','manager','operator'])`،
   والتسعير يجري في `ops.create_priced_session_segment`. فمن يحق له
   بدء جلسة مُسعَّرة يحق له رؤية السعر الذي ستُسعَّر به.
2. `price.manage` صلاحية **تعديل**: 080 تمنحها للمالك عبر `cross join`،
   ولا تظهر في قائمة منح `operator` ولا `well_manager`.
3. **الطبقة الثانية الحاسمة:** سياسات 031
   (`price_schedules_select_owner` / `price_rules_select_owner`) تحصر
   `SELECT` بـ`iam.has_well_role(well_id, array['owner'])`. فتخفيف
   الفحص المسمّى **وحده** داخل عقد `INVOKER` يُعيد صفر صفوف، أي
   `schedule = null`: **غياب كاذب** أسوأ من الرفض الصريح. الطبقتان
   تتحركان معًا أو لا تتحرك أي منهما — وهذا ما يجعل الحل هجرة لا
   تعديل سطر.
4. لا سياسة `SELECT` أخرى على جدولي التسعير في أي هجرة بعد 031: أُثبت
   بمسح كامل لـ`on ops.price_schedules` و`on ops.price_rules`.

**التصميم:**

| الطبقة | ما فيها |
|---|---|
| صلاحية جديدة | `price.read` — اطلاع، مستقلة عن `price.manage` |
| المنح | `tenant_owner` + `well_manager` + `operator` فقط |
| قارئ داخلي | `ops.read_active_price_schedule(uuid, timestamptz)` — `stable` + `security definer` + `search_path` مثبت، يحمل `iam.has_well_permission(p_well_id,'price.read')` |
| غلاف عام | `api.get_active_price_schedule` يبقى `INVOKER`: جلسة (`28000`)، مدخل (`22023`)، رؤية البئر عبر RLS 079 (`42501`)، ثم يفوّض |

**ما لم يتغيّر:** سياسات RLS على `ops.price_schedules` و
`ops.price_rules` كما هي — الجداول تبقى مغلقة على المالك، والاطلاع
يمر عبر العقد المُراجَع وحده. والمغلّف ومفاتيحه و`version = 1` كما
هي، فما تغيّر **مَن يُسمح له بالقراءة لا شكل ما يُقرأ**. و`price.manage`
تبقى وحدها بوابة الكتابة.

**لماذا الفحص في القارئ لا في الغلاف:** اختبار 084 (PASS 7) يثبّت أن
الغلاف لا يكرّر قرار الصلاحية. فالقرار في نقطة واحدة: الإجراء الذي
يتجاوز RLS هو نفسه الذي يحمل الفحص المسمّى — نفس نمط الكتابة في
084/091 مقلوبًا على القراءة.

**أثر مقصود على أرقام السلطة:** `iam.permissions` 41 → **42**،
و`iam.role_permissions` 75 → **78** (`tenant_owner` 41 → 42،
`well_manager` 13 → 14، `operator` 21 → 22). حُدّثت أرقام الحرس في
`20260819_080_…test.sql` و`20260822_081_…test.sql` بتعليق يسمّي 093،
كما فعلت 091 قبلها. `partner`/`accountant`/`viewer` تبقى بصفر منح
(حرس 081 PASS 4)، و`farmer` خارج خريطة الأدوار أصلًا في 080.

**الاختبار:** `supabase/tests/20260902_093_price_read_for_operators.test.sql`
(**15 تحققًا**: وجود الصلاحية ومنحها لثلاثة أدوار بلا توسيع صامت،
أرقام الكتالوج، خصائص القارئ الداخلي، بقاء العقد `INVOKER`، ACL يحجب
`anon` على الطرفين، انتقال السلطة داخل الأجساد، ثم السلوك: **المشغل
يقرأ المغلّف نفسه الذي يقرأه المالك حرفيًا** بسعر ساعة حقيقي، ولا يرى
الجداول مباشرة، ولا يكتب تسعيرة، وبئر بلا جدول يُعيد `schedule = null`
بلا خطأ، وبئر بلا تعيين `42501`، ومعرّف فارغ `22023`).

**لا تغيير في Flutter:** شاشة العمليات بعد م-41D6 تعرض التسعيرة حين
تتوفر وتعرض حالة الصلاحية حين `42501`، و`_loadPriceSchedule` تُنفَّذ
بلا فحص دور في العميل. فالمسار المرئي كان جاهزًا، وما كان ناقصًا هو
سلطة القراءة في القاعدة.

**التحقق المحلي:** ✅ **مثبت 2026-09-02** — `npm run db:reset` ثم
`npm run db:test` عند المالك: Target 093 = **PASS=15 FAIL=0 ERROR=0**،
والحزمة **FILES=31 PASS=500 FAIL=0 ERROR=0** (485 + 15) بلا تغيير في
عدد تحققات 080/081 (الأرقام المتوقعة داخلها تغيّرت لا عددها). و
`npm run db:index` أعاد التوليد فكسب `functions.txt` القارئ الجديد
والعقد (`columns 800` / `constraints 481` / `triggers 44` /
`functions 437`).

**التحقق السحابي:** ✅ **مثبت 2026-09-02** بعد دمج `PR #20` مضغوطًا
(`main` عند `787eee0`) — `npm run cloud:verify`:
`MIGRATIONS_LOCAL=92` / `MIGRATIONS_CLOUD=92` / `MISSING_IN_CLOUD=0`
(الملفات 92 لأن الترقيم 001–093 بفجوة عند 067)، و
`FUNCTIONS_INDEX=424` / `FUNCTIONS_CLOUD=426` /
`FUNCTIONS_MISSING_IN_CLOUD=0` — أي أن `ops.read_active_price_schedule`
والعقد المستبدل موجودان سحابيًا؛ و`IAM_PERMISSIONS=42` /
`IAM_ROLE_PERMISSIONS=78` تُثبت أن المنح وصلت الإنتاج على مستوى
البيانات لا الملفات. الزائدان سحابيًا (`public.max` / `public.min`)
مجموعتا تجميع تأتي بهما إضافة مثبَّتة سحابيًا لا محليًا، لا كود تطبيقي،
فتُطبعان كانحراف بلا إفشال.

**تحذير النشر:** كما في 092 — دمج هذه الهجرة في `main` ينشرها على
الإنتاج تلقائيًا. وأثرها على الإنتاج **توسيع اطلاع**: كل مشغل ومدير
مُعيَّن نشط على بئر سيرى تسعيرته السارية بعد الدمج.

## 094 — 20260903010001_094_team_invitations.sql

**القرار الحاكم:** ق-123 · **الجولة:** م-41E المرحلة 2 · **الثوابت:** 706–715

**السبب:** دور المشغّل كان غير قابل للاستخدام أصلًا. إضافة مشغّل في 086
تُنشئ شخصًا في دفاتر المالك لا حساب دخول، ولا مسار في التطبيق لإنشاء حساب
لمشغّل، والربط يجري لحظة إنشاء البئر وحدها. فلا أحد يضع كلمة المرور الأولى
لأنه لا حساب ولا كلمة مرور.

**لماذا جدول جديد لا عمود حالة:** `core.well_assignments.profile_id`
إلزامي و`status` محصور بـ`active`/`inactive`، فلا يقبل صفًّا «بانتظار
التنشيط» بلا حساب.

**ما أُنشئ:**

- `core.well_invitations` — 19 عمودًا، وأربع حالات
  (`invited`/`claimed`/`expired`/`revoked`)، وتلبيدة الرمز بملح صفّه،
  ومدة 14 يومًا، وعدّاد 5 محاولات. **RLS مفعّلة بلا سياسات وكل الصلاحيات
  مسحوبة** — بلا Direct DML ولا قراءة مباشرة لأدوار التطبيق.
- **فهرس فريد جزئي** على (well_id, role, normalized_phone) حيث
  `status='invited'`: رمز واحد صالح، وإعادة الدعوة تُبطل ما قبلها — فلا
  دالة إعادة إصدار منفصلة.
- `core.new_invitation_code()` — ستة أرقام من `gen_random_uuid()`
  (عشوائية نظام التشغيل) لا من `random()`، ومع `abs` لأن تحويل `bit(32)`
  قد يعطي سالبًا.
- `core.hash_invitation_code(text, text)` — `sha256` من `pg_catalog`
  وحده، **بلا اعتماد على مخطط إضافة**. الحماية الفعلية عدّاد المحاولات
  وحصر البحث برقم صاحب الحساب المُصدَّق، لا بطء دالة التلبيد.
- `core.invite_well_member` / `core.claim_well_invitation` /
  `core.revoke_well_member` / `core.read_well_team` — `DEFINER`
  بـ`search_path` مثبت، وكلها تحمل `iam.has_well_permission` عدا
  المطالبة التي سلطتها ملكية الرقم نفسه.
- أربعة أغلفة `api` بـ`SECURITY INVOKER` لا تكرّر قرار الصلاحية.
- صلاحية `team.manage` **للمالك وحده**: الكتالوج 42 → **43**، والمنح
  78 → **79**.

**قرار تصميمي مسجَّل:** الرمز الخاطئ **حالة مُعادة**
(`outcome='wrong_code'` ومعها المتبقّي) لا استثناء — لأن
`raise exception` كان سيتراجع عن خصم العدّاد في نفس المعاملة فيصير
العدّاد بلا معنى ويُفتح التخمين بلا حدّ. والاستثناءات محصورة بالجلسة
(`28000`) والمدخل (`22023`) والصلاحية (`42501`).

**حروس حُدّثت:** 080 و081 **و093** — ثلاثتها تحمل أرقام السلطة. (093 لم
يكن في حساب الجولة أولًا فأسقطته الصلاحية الجديدة، ثم أُصلح.)

**الاختبار:** `supabase/tests/20260903_094_team_invitations.test.sql`
بـ**22 تحققًا**.

**الإثبات المحلي (تشغيل المالك 2026-09-03):** `db:reset OK`، ثم
`FILES=32 PASS=522 FAIL=0 ERROR=0` (كانت 31/500)، ثم `db:index OK`
بنمو مطابق للتصميم: columns 800 → **819**، constraints 481 → **491**،
functions 437 → **447**، triggers **44 بلا تغيير**.

**الإثبات السحابي (2026-09-03 بعد دمج PR #27):**
`MIGRATIONS_LOCAL=93` / `MIGRATIONS_CLOUD=93` / `MISSING_IN_CLOUD=0`؛
و`FUNCTIONS_INDEX=434` / `FUNCTIONS_CLOUD=436` /
`FUNCTIONS_MISSING_IN_CLOUD=0` (الزائدتان `public.max`/`public.min`
مجموعتا تجميع من إضافة مثبَّتة سحابيًا لا محليًا، تُطبعان كانحراف بلا
إفشال)؛ و**`IAM_PERMISSIONS=43` / `IAM_ROLE_PERMISSIONS=79`** — وهما
الدليل على أن `team.manage` ومنحتها وصلتا الإنتاج على مستوى البيانات لا
على مستوى صفّ الهجرة.

**تحذير النشر:** أثرها على الإنتاج **إضافة قدرة لا توسيع اطلاع**: جدول
جديد مغلق وعقود لا يناديها التطبيق بعد (شاشاتها في المرحلة 3). ولا تمسّ
بيانات قائمة ولا صلاحية قائمة.

## 095 — 20260903020001_095_partner_read_scope.sql

**م-41E المرحلة 4 / ق-123 §8 / الثوابت 713 و714.** نطاق قراءة الشريك:
تضييق ما كان مكشوفًا، وإضافة ما لم يكن له عقد.

**المشكلة:** الشريك يدخل فعلًا بعد المرحلة 3، وهجرة 050 §3 تولّد سياسة
اطلاع له على كل جدول أساسي يحمل `well_id` أو `tenant_id`. فعقود 090
(INVOKER تفوّض على RLS) كانت تعيد له **الجلسة الجارية بأرقامها**، وعقد
المصروفات يعيد `recorded_by_name` — وكلاهما ممنوع في §26.

**ما فيها:**

1. **سياسة `irrigation_sessions_select_partner`** أُعيدت بشرط
   `status <> 'open'`. التضييق في طبقة الصفوف يسري على كل عقد قائم أو
   قادم، والسياسات تُجمع بـ`OR` فمن له دور تشغيلي يبقى يرى الجارية.
2. **سياسة `session_segments_select_partner`** أُعيدت مقصورة على مقاطع
   جلسات آبار شراكته وغير الجارية. الجدول بلا `well_id` فوقعت سياسة 050
   على فرع `tenant_id` وكانت تكشف مقاطع كل آبار المستأجر — والمقطع يحمل
   `applied_hourly_rate_minor` و`raw_billable_minutes`، أي أساس المستحق.
3. **`iam.is_partner_only(uuid)`** — `DEFINER` تعيد `true` حين تكون سلطة
   المتصل على البئر شراكةً وحدها. لا تُفصح عن غير المتصل نفسه.
4. **`api.list_well_expenses`** أُعيدت: `recorded_by_name` = `null`
   للشريك وحده، ومفتاح `partner_scope` يُعلن الحدّ. المفاتيح والإصدار
   (`version = 1`، يثبّتها اختبار 092 PASS 11) والترتيب بلا تغيير.
5. **`finance.read_partner_overview(uuid)`** — `DEFINER` سلطته **شراكة
   سارية على البئر وحدها** (`iam.is_well_partner`)، بلا مصفوفة أدوار
   نصية. التجاوز لغرض واحد: **عدّ** الجلسات الجارية للحضور، لأن السياسة
   الجديدة تحجب صفّها فيصير العدّ صفرًا دائمًا — وذلك غياب كاذب. ولا تعيد
   معرّف جلسة ولا مستحقًّا ولا مدة ولا مضخة. ومعها الفترة المفتوحة موسومة
   `is_final = false` بمجاميع أعمدة مخزَّنة من
   `reporting.well_daily_summary` بلا صافٍ محسوب.
6. **`api.read_partner_overview(uuid)`** — غلاف INVOKER رقيق: `28000`
   بلا جلسة، `22023` للمدخل، `42501` لبئر لا يراه المتصل.
7. **`api.list_well_farmer_balances(uuid, integer)`** — INVOKER يقرأ
   `reporting.farmer_account_balances` كما هي: «المزارعون وديونهم» في §26
   لم يكن لها عقد يعيدها في قائمة (089 بلا رصيد، و092 لمزارع واحد
   بمعرّفه)، وبناء الدين في العميل تلفيقٌ لا توصيل.

**ما ليس فيها بقصد:** لا صلاحية مسمّاة جديدة ولا منحة — الاطلاع قائم من
050، والمطلوب تضييقه. فأرقام الكتالوج تبقى `iam.permissions = 43` و
`iam.role_permissions = 79`. ولا تكرار لدورات التوزيع: النسبة التاريخية
مخزَّنة في `profit_distribution_lines.profit_percentage_snapshot` ويعيدها
`api.list_well_profit_cycles` من 092.

**الاختبار:** `supabase/tests/20260903_095_partner_read_scope.test.sql`
بـ**26 تحققًا**: الجارية محجوبة والمقفلة مقروءة، وتفصيل الجارية مرفوض
`42501` والمقفلة يعمل، والمقاطع كذلك، واسم المسجِّل مفرَّغ للشريك موجود
للمالك، والحضور يُعلَن رغم حجب الصف، والحمولة بلا معرّف جلسة ولا مضخة،
والفترة موسومة، وأرصدة المزارعين تُقرأ، وثلاثة عقود كتابة تردّ `42501`،
ولا DML مباشرة، والشريك المشغّل لا يُقيَّد، والمالك بلا انحدار في اطلاعه،
والغريب و`anon` والمالك بلا سطر شراكة مرفوضون من العقد، **وحرس م-18 يبقى
صفرًا**.

**عطب أُصلح بعد أول تشغيل:** أول `c:db` أسقط **اختبار 082 التحقق 5**
(«صفر حرس دالة على مصفوفات الأدوار النصية»، وهو ما أغلق م-18): القارئ
الداخلي كان يقبل أيضًا `iam.has_well_role(well, ['owner','manager'])` ليرى
المالك ما يراه شريكه. الفرع حُذف لا نُقل: للمالك عقوده هو وفيها الجلسة
الجارية بأرقامها، فحصر العقد بالشريك لا يمنعه من بيانة. وأُضيف التحقق 26
في اختبار 095 نفسه ليُكتشف العود في موضعه لا في ملف آخر. **الدرس نفسه
المتكرر:** الحرس الذي يحمل قاعدة معمارية يعيش في ملف بعيد عن الجولة، ولا
يكفي أن تتذكّر الجولة السابقة أيَّ الحروس مسّته.

**وعطب ثانٍ في التشغيل الثاني:** الحرس بقي يعدّ الدالة **بسبب التعليق الذي
يشرح الحذف**: `pg_get_functiondef` يعيد نصّ التعريف كاملًا بتعليقاته، فذكرُ
اسم النمط الممنوع داخل جسم الدالة يُقرأ كالنمط نفسه. الشرح انتقل إلى تعليق
**فوق** الدالة — حيث لا يبلغه `pg_get_functiondef` — وبقي في جسمها سطرٌ بلا
اسم النمط. **وهذا رابع ظهور لنفس العائلة** بعد «لا بئر مختار» و«تم إرسال
رمز التحقق» و«إدارة الفريق غير متاحة» في طبقة الهاتف: كل مقياس نصّي على
نمط مُلغى يصطدم بالتعليق الذي يشرحه — والقاعدة الآن تسري على **جسم دالة
PostgreSQL** كما تسري على شجرة عرض Flutter.

**الإثبات المحلي (تشغيل المالك 2026-09-03):** `db:reset OK` ثم
`FILES=33 PASS=548 FAIL=0 ERROR=0` (كانت 32/522)، ثم `db:index OK`:
functions 447 → **451**، و**columns 819 وconstraints 491 وtriggers 44 بلا
تغيير** — تطابق النمو مع التصميم دليل مستقل على أن ما وصل القاعدة هو ما
كُتب: أربع دوال، ولا جدول ولا عمود ولا قيد.

**الإثبات السحابي (2026-09-03 بعد دمج PR #29):** `MIGRATIONS_LOCAL=94` /
`MIGRATIONS_CLOUD=94` / `MISSING_IN_CLOUD=0`؛ و`FUNCTIONS_INDEX=438` /
`FUNCTIONS_CLOUD=440` / `FUNCTIONS_MISSING_IN_CLOUD=0` (الزائدتان
`public.max`/`public.min` ضجيج إضافة معلوم)؛ و**`IAM_PERMISSIONS=43` /
`IAM_ROLE_PERMISSIONS=79` بلا تغيير** — وهذا الثبات هو الدليل على أن
الجولة تضييق اطلاع لا توسيع سلطة.

**ملاحظة قياس:** أول `cloud:verify` بعد الدمج بثوانٍ أظهر
`MISSING_IN_CLOUD=1` (سطر تسجيل 095) و`FUNCTIONS_MISSING_IN_CLOUD=0` معًا —
أي أن مضمون الهجرة كان قد نُفِّذ وسطرها لم يُسجَّل بعد. القياس يُعاد بعد
دقيقتين، ولا يُقرأ التعارض عطبًا في الهجرة.

**تحذير النشر:** أثرها على الإنتاج **تضييق اطلاع + إضافة عقود قراءة**.
لا مستخدمين حقيقيين بعد، ولا شريك مربوط بحساب في الإنتاج، فلا اطلاع
قائمًا يُسحب من أحد فعلًا. والتراجع — إن لزم — بهجرة جديدة تعيد السياستين
إلى صيغة 050، لا بتعديل هجرة منشورة.

## 096 — 20260903030001_096_password_reset_tickets.sql

**م-41F / ق-105 §Admin-triggered / الثوابت 706 و710 و711.** إعادة تعيين
كلمة المرور بإثبات بشري، بلا مزوّد رسائل وبلا كلفة.

**القيد الذي حدّد الشكل:** الاستعادة تحدث **قبل** المصادقة، وحدّ
`anon EXECUTE = 0` مقيس بحرس دائم (اختبار 071). فلا يمكن لأي عقد في
القاعدة أن يخدم من لا جلسة له — أيًّا كان تصميمه. ولذلك خطوة الاستهلاك
ممنوحة لـ`service_role` **وحده**، ويناديها طرف خادمي
(`supabase/functions/reset-password`) هو الوحيد الذي يطلب من نظام المصادقة
تعيين كلمة المرور **التي كتبها صاحب الحساب**.

**ما فيها:**

1. **`core.password_reset_tickets`** — تذكرة سارية واحدة لكل حساب (فهرس
   فريد جزئي)، أربع حالات، مدة 24 ساعة، خمس محاولات، تلبيدة بملح صفّها
   ولا نصّ رمز (708). RLS مفعّلة **بلا سياسات** وكل المنح مسحوبة.
2. **`core.request_member_password_reset`** — سلطته `team.manage` القائمة
   (لا صلاحية جديدة، فالكتالوج يبقى 43/79). يُبطل ما قبلها ويعيد الرمز
   مرة واحدة. و«لا عضو بهذا الرقم» حالة مُعادة لا استثناء.
3. **`core.consume_password_reset`** — لمفتاح الخدمة وحده. الرمز الخاطئ
   يخصم ويبقى الخصم (لا استثناء يتراجع عنه)، والمنتهية تُوسم منتهية،
   واستنفاد المحاولات يُبطل، والجواب موحَّد لمن لا تذكرة له ولمن لا حساب
   له (710). يعيد `profile_id` ولا يكتب كلمة مرور ولا يعرفها.
4. **`core.read_member_reset_requests`** + غلافا `api` للمالك، و
   **`api.consume_password_reset`** ممنوحًا لـ`service_role` وحده — لأن
   مخطط `core` غير مكشوف عبر PostgREST (ق-78) والطرف الخادمي يناديه هناك.

**ما ليس فيها بقصد:** لا كتابة في مخطط `auth` ولا لمس كلمة مرور — مقيس
بتحقق يفحص نصّ التعريف بحثًا عن `auth.users` و`encrypted_password` و
`crypt(`. ولا طابور رسائل: بلا مزوّد لا مستهلك له، وجدولٌ كل صفوفه «لم
يُرسل» نصف ميزة تُبنى يوم يُختار المزوّد.

**الاختبار:** `supabase/tests/20260903_096_password_reset_tickets.test.sql`
بـ**19 تحققًا**، أقواها: الاستهلاك محجوب عن `anon` وعن المستخدم المصدَّق
وممنوح لـ`service_role` وحده؛ والجدول بلا سياسات وبلا منح؛ والخصم يبقى بعد
المعاملة؛ والرمز الصحيح على تذكرة مُبطلة لا يعمل.

**الأثر على الفهرس (مثبت بتشغيل المالك 2026-09-03):**
`FILES=34 PASS=567 FAIL=0 ERROR=0`، وcolumns 819 → **833** (أعمدة جدول
التذاكر)، constraints 491 → **501**، functions 451 → **457** (خمس دوال
داخلية وغلافان في `api`)، وtriggers **44 بلا تغيير**. وتطابق النمو مع
التصميم دليل مستقل على أن ما وصل القاعدة هو ما كُتب.

**تحذير النشر:** الدمج ينشر الجدول والعقود، **ولا تعمل الاستعادة حتى
تُنشر الدالة الحافة** (`npx supabase functions deploy reset-password`).
وحتى ذلك تبقى الشاشة تُعلن «غير متاح» صريحًا ولا تدّعي نجاحًا.

**الإثبات السحابي (2026-09-03 بعد دمج PR #31):** `MIGRATIONS_LOCAL=95` /
`MIGRATIONS_CLOUD=95` / `MISSING_IN_CLOUD=0`؛ و`FUNCTIONS_INDEX=444` /
`FUNCTIONS_CLOUD=446` / `FUNCTIONS_MISSING_IN_CLOUD=0` (نمو ست دوال في
الطرفين، والزائدتان `public.max`/`public.min` ضجيج معلوم)؛ و
`IAM_PERMISSIONS=43` / `IAM_ROLE_PERMISSIONS=79` **بلا تغيير**.
**والدالة الحافة نُشرت بنجاح من أول محاولة** (حجم الحزمة 104kB).

**ما لم يُثبت:** المسار من طرف إلى طرف لم يُجرَّب مرة واحدة على الإنتاج —
لا إصدار تذكرة حقيقية ولا إعادة تعيين فعلية. كل طبقة مُختبرة وحدها،
والمجموع **منشور لا مُبرهن عمليًّا**.

## 097 — 20260904010001_097_advance_receipt_reads.sql

**م-41G / البند المفتوح من م-41D5 (القرار 420).** عقد قراءة سندات الرصيد
المقدَّم — به عاد زرّ «استخدام الرصيد المقدم» إلى العمل.

**المشكلة:** `api.get_farmer_account` يعيد الرصيد المقدَّم **رقمًا مُجمَّعًا**
والسندات بلا مبالغ، فلا يُعرف أي سند بقي فيه رصيد ولا كم — وأي اختيار في
العميل قرارٌ ماليّ مُختلَق تمنعه ق-99. فكانت الشاشة تُعلن «غير متاح» منذ
م-41D5.

**فرضية سقطت في أول تشغيل — وهي أهم ما في هذه الهجرة:** كُتب التصميم أولًا
بإجراء داخلي `SECURITY DEFINER` يتجاوز RLS، لأن الوثائق تسجّل أن سياسة 016
تحجب دفعة المقدَّم (تشترط ارتباطها بتكلفة جلسة). والاختبار كان يُثبت الحجب
أولًا ليُبرهن أن التجاوز لازم — **فأعاد ثلاثة سندات**: هجرة 085 القسم 1
أعادت السياسة بحالتين (بجلسة، أو بلا جلسة مربوطة بـ`well_id`) للمالك
والمشغّل. فحُذف التجاوز من التصميم، وصار العقد `SECURITY INVOKER` يقرأ تحت
RLS المتصل نفسه. **الدرس:** الوثيقة القديمة كانت ستُنتج صلاحية أوسع من
اللازم، والاختبار الذي يُثبت الفرضية قبل البناء عليها هو ما منعها.

**ما فيها:** دالة واحدة — `api.list_advance_receipts(uuid, integer)` —
تعيد لكل سند مقدَّم `payment_id` و`public_code` و`paid_at` و`method` و
`amount_minor` و`allocated_minor` و`remaining_minor` و`is_exhausted`،
مرتَّبة بالأقدم أولًا. والمتبقّي = مبلغ مخزَّن ناقص مجموع تخصيصات مخزَّنة،
بلا حساب جديد. وسلطتها `payment.allocate` القائمة (لا صلاحية جديدة، والكتالوج
43/79): من يخصّص يرى ما يخصّصه، والفحص المسمّى هو ما يمنع **الشريك** (سياسة
050 تفتح له صفوف الدفعات، ونطاقه في §26 لا يشملها).

**ما ليس فيها بقصد:** لا عقد كتابة جديد. التخصيص يبقى على `api.allocate_payment`
(068/073/081) بمبالغ **يكتبها إنسان** ويتحقق منها الخادم — وهذا مقيس في
الاختبار بفحص أن لا دالة `api` جديدة متغيّرة الحالة تحمل `advance`.

**الاختبار:** `supabase/tests/20260904_097_advance_receipt_reads.test.sql`
بـ**10 تحققات**: خصائص العقد وغياب أي إجراء متجاوز، وأرقام السندات الثلاثة
(جزئي/مستنفَد/بلا تخصيص)، والترتيب، وقراءة المشغّل، ورفض الشريك، ورفض حسابٍ
مجهول و`anon` بنفس الرسالة، وبقاء عقد الكتابة القائم وحده.

**الإثبات المحلي (تشغيل المالك 2026-09-04):**
`FILES=35 PASS=577 FAIL=0 ERROR=0`، والفهرس functions 457 → **458**، و
columns 833 وconstraints 501 وtriggers 44 **بلا تغيير** — قراءة صافية بلا
بنية جديدة.

**تحذير النشر:** أثرها **إضافة قراءة** لمن يملك `payment.allocate` سلفًا،
بلا توسيع صلاحية ولا تغيير بيانات.
