# الهجرات

**آخر تحديث:** 2026-08-19

سجل ملفات هجرة قاعدة البيانات، وحالة كل ملف: هل كُتب؟ وهل **طُبّق فعليًا**؟ وهما أمران مختلفان تمامًا.

---

## الحالة الحالية الحاكمة — 2026-08-19

- Local: 78 migration file مطبقة حتى 079؛ الترقيم التاريخي لا يحتوي Migration 067.
- Cloud: 77 migration مطبقة حتى 078؛ Migration 079 pending Cloud deployment.
- 19 ملف اختبار دائم.
- 255 PASS / 0 FAIL / 0 ERROR محليًا.
- 071: ق-78 — Data API boundary.
- 072: إغلاق Direct DML.
- 073: عقد الكتابة الأساسي داخل api.
- 074: استكمال تدفقات MVP الحرجة داخل api.

**مهم:** الجداول أدناه تسجل ما فعلته كل هجرة في وقتها.
لذلك قد يظهر في هجرة قديمة وصف منسوخ لاحقًا، مثل
milli-riyal في 009. هذا وصف تاريخي للهجرة وليس القاعدة الحالية.

المعنى المالي الحالي يحكمه ق-77: الريال الكامل.

## تحديث جوهري — إعادة بناء كاملة بتاريخ 2026-08-13 (ق-51 وق-57)

حُذف ملفا الترحيل القديمان (001 و002، بتاريخ 2026-08-05) بالكامل، لأنهما سبقا استقرار القرارات الخمسين. استُبدلا بـ 25 ملف ترحيل جديدة، مبنية ومختبرة تباعًا في نفس اليوم، تعكس كل القرارات النافذة حتى ق-66.

**ملاحظة تاريخية:** هذا القسم كُتب أولًا عندما كان التطبيق محليًا فقط. الحالة الحالية الحاكمة هي الملخص أعلى الملف: 001–078 موجودة على Supabase Cloud، بينما 079 متحققة محليًا وتنتظر Cloud deployment/verification.

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
| 028 | `_028_roles_and_permissions_catalog.sql` | `iam.roles`، `iam.permissions`، `iam.role_permissions` (كتالوج تأسيسي، غير مربوط بعد — انظر م-18) |

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

**الحالة:** مطبقة ومتحقق منها محليًا؛ Cloud pending.

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
