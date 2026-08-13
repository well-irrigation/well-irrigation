# الهجرات

**آخر تحديث:** 2026-08-13

سجل ملفات هجرة قاعدة البيانات، وحالة كل ملف: هل كُتب؟ وهل **طُبّق فعليًا**؟ وهما أمران مختلفان تمامًا.

---

## تحديث جوهري — إعادة بناء كاملة بتاريخ 2026-08-13 (ق-51 وق-57)

حُذف ملفا الترحيل القديمان (001 و002، بتاريخ 2026-08-05) بالكامل، لأنهما سبقا استقرار القرارات الخمسين. استُبدلا بـ 25 ملف ترحيل جديدة، مبنية ومختبرة تباعًا في نفس اليوم، تعكس كل القرارات النافذة حتى ق-66.

**حالة التطبيق الحالية لكل الملفات أدناه:** مُطبّقة ومُختبرة محليًا (بيئة تطوير) عبر تكرار `npx supabase db reset`، مع فحص مباشر بعد كل ملف. **لم تُطبّق بعد على أي بيئة إنتاج أو نشر فعلي.**

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
| 009 | `_009_session_charges.sql` | جدول `billing.session_charges` (جزء من ألف — ق-14) |
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
