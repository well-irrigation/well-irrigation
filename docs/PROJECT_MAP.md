# خريطة المشروع — مصادر الحقيقة الحالية

**آخر تحديث:** 2026-08-18

هذه الوثيقة تحدد أي ملف يفوز عند التعارض، وتفصل بين
الحالة الحالية والسجل التاريخي.

## 1. ترتيب السلطة

من الأعلى إلى الأدنى:

1. `memory/DECISIONS.md`
   القرارات المرقمة. القرار الأحدث الناسخ يفوز على القرار الأقدم.

2. `technical/INVARIANTS.md`
   القواعد التقنية الحالية الناتجة عن القرارات النافذة.

3. `technical/API_ARCHITECTURE.md`
   حدود Flutter وSupabase Data API وعقد الكتابة.

4. `technical/SYNC_ARCHITECTURE.md`
   حالة المزامنة والعمل دون اتصال ومنع التكرار.

5. `technical/DECISION_IMPLEMENTATION_MATRIX.md`
   مطابقة القرارات ذات الأثر التنفيذي مع الهجرات والاختبارات والحالة.

6. `design/VISUAL_IDENTITY.md`
   المصدر الحاكم للهوية البصرية بعد القرارات المرقمة.

7. `reference/`
   المرجع الوظيفي والتصميمي، مقيد دائمًا بالقرارات الأحدث أعلاه.

8. بقية الملفات التاريخية مثل `PROGRESS.md` و`DOC_CHANGELOG.md`
   تحفظ تاريخ ما كان صحيحًا في لحظته ولا تتغلب على الحالة الحالية.

## 2. مصادر الحقيقة حسب الموضوع

### القرارات
`memory/DECISIONS.md`

آخر قرار مرقم حاليًا: ق-101.

### أين توقف العمل
`memory/RESUME_POINT.md` فقط.

لا تستخدم snapshot أقدم داخل PROGRESS أو DOC_CHANGELOG لتحديد الخطوة التالية.

### استلام المشروع بواسطة نموذج ذكاء اصطناعي

ابدأ بـ:

`memory/AI_HANDOFF_PROTOCOL.md`

هذا الملف يحدد ترتيب القراءة وعقد تحديث الوثائق.

لا يحل محل مصادر الحقيقة في ترتيب السلطة.

### أسلوب العمل والتعاون

المصدر:

`memory/AI_COLLABORATION_PROTOCOL.md`

القرارات الحاكمة:

ق-95.

يحدد:

- اللغة وطريقة الشرح.
- دور النموذج.
- منهج اتخاذ القرار.
- طريقة عرض التوصيات.
- Workflow UX.
- التعامل مع الاعتماد.
- التعارضات والفجوات.
- التعامل مع Terminal Output.
- الفرق بين حالات الإنجاز الأربع.

### أوامر الطرفية والاستعادة

المصدر:

`memory/TERMINAL_COMMAND_PROTOCOL.md`

القرار الحاكم:

ق-96.

يحدد:

- شرح ما قبل الأمر.
- شكل Command Block.
- Subshell safety.
- Expected HEAD.
- Worktree guards.
- Content checks.
- Commit/Push.
- Recovery بعد الفشل.
- الحوادث السابقة والقواعد الناتجة عنها.

### البيئة الفعلية
`technical/ENVIRONMENT.md` فقط.

### الهجرات المطبقة
`technical/MIGRATIONS.md` فقط.

### المال والوقت
`DECISIONS.md` ثم `technical/INVARIANTS.md`.

الحالة الحالية:

- أصغر وحدة مالية = ريال يمني كامل — ق-77.
- الحقول ذات اللاحقة `_minor` تحتفظ باسمها التاريخي، لكن قيمتها بعد ق-77 هي ريال كامل.
- الزمن يحسب بالثانية.
- لا تقريب للوقت.
- لا تقريب مالي.
- كسر الريال الناتج عن القسمة لا يخزن كوحدة مالية مستقلة.

### توزيع الأرباح
ق-77 هو الحاكم.

بعد القسمة الصحيحة، يذهب كامل باقي القسمة إلى صاحب أكبر حصة.
هذا هو الوصف المعتمد، ولا يسمى Largest Remainder Method في التوثيق الحالي.

### Data API والكتابة
ق-78 وق-79 ثم `technical/API_ARCHITECTURE.md`.

- Exposed Schemas: `api` و`graphql_public`.
- مخططات الأعمال الداخلية غير مكشوفة.
- Direct DML لأدوار التطبيق = صفر.
- Flutter يكتب عبر `api.*`.
- سطح Data API المثبت حاليًا = 33 RPC.

### الهوية البصرية

ق-83 ثم `design/VISUAL_IDENTITY.md`.

- الهوية العامة معتمدة مبدئيًا.
- الشعار الحالي معتمد مبدئيًا وقابل للتطوير لاحقًا.
- العربية RTL أصل التصميم.
- الأرقام الإنجليزية 0-9 ثابتة.
- لم تُنفذ واجهة إنتاجية جديدة نتيجة ق-83.
- الخطوة التالية هي مناقشة الصفحات قبل تنفيذها.

### تجربة المستخدم والواجهات

المصدر الحاكم للتفاصيل:

`design/UX_UI_SPEC.md`

المنهج:

- مناقشة الشاشة.
- اعتمادها.
- توثيقها فورًا.
- ثم الانتقال للشاشة التالية.

الحالة الحالية:

- UX-00 / Splash Screen: معتمدة وموثقة.
- UX-01 / App Entry Routing: معتمد وموثق.
- UX-02 / Login Screen: معتمدة وموثقة.
- UX-03 / Create New Well & Setup: معتمد وموثق.
- UX-04 / Unified Account Context: معتمد سلوكيًا.
- UX-05 / Role-Aware Landing: معتمد وموثق.
- UX-06 / Owner Home: معتمد وموثق.
- UX-07 / Role Section Cards: معتمد وموثق.
- UX-08 / Operations Page: معتمد وموثق.
- UX-09 / Session Start Form: معتمد وموثق.
- UX-10 / Device Readiness & Sync Status: معتمد وموثق.
- UX-11 / Active Irrigation Session: معتمد وموثق.
- UX-12 / Session Completion & Settlement: معتمد وموثق.
- UX-13 / Operations, Records & Farmers: معتمد وموثق.
- UX-14 / Money & Partners: معتمد وموثق.
- UX-15 / Well Management & Reports: معتمد وموثق.
- UX-16A / Account & Settings: معتمد وموثق.
- ق-88 / Smart Lookup ودعم منع التكرار: معتمد.
- ق-89 / Offline Field Operations وBackground Sync: معتمد.
- ق-90 / Device Readiness وSync Transparency: معتمد.
- ق-91 / Active Session وBilling Consistency: معتمد.
- ق-92 / Session Completion وSettlement Consistency: معتمد.

الخطوة التالية:

PA-01 / Platform Administration.

إدارة المنصة أصبحت سلسلة مستقلة عن UX-16A.

لا تعتبر أي شاشة إنتاجية منفذة لمجرد اعتماد UX.

### خارطة UX المتبقية — ق-94

- UX-13: Operations, Records & Farmers.
- UX-14: Money & Partners.
- UX-15: Well Management & Reports.
- UX-16: Account, Settings & Administration.
- UX-17: Final Cross-Cutting Review.

هذه الحزم تختصر النقاش ولا تختصر المتطلبات.

### البحث والاختيار الذكي ومنع التكرار

ق-88 ثم:

`technical/SEARCH_DEDUP_ARCHITECTURE.md`

المصدر يحدد:

- Smart Lookup.
- Entity Dedup Profiles.
- إعادة استخدام تطبيع الأشخاص الحالي.
- منع تكرار الأراضي.
- حدود api للبحث.
- local/server search merge.
- عداد المستحق الجاري.
- فجوات Migration 078+ واختبارات القبول.

لا تنشأ طبقة بحث أو هوية موازية لما هو موجود أصلًا.

### الجلسة الجارية والتسعير اللحظي

ق-17 وق-91 ثم:

`technical/ACTIVE_SESSION_ARCHITECTURE.md`

المصدر يحدد:

- Active Session Read Model.
- billable time.
- live accrued amount.
- payment display.
- Pause/Resume.
- Resume With New Energy.
- Energy Segments.
- Fuel Billing consistency.
- Offline event ordering.
- Completion consistency.
- م-26.

### إنهاء الجلسة والتسوية

ق-92 ثم:

`technical/SESSION_SETTLEMENT_ARCHITECTURE.md`

المصدر يحدد:

- Local Completed مقابل Server Settled.
- Final Charge.
- Automatic Invoice.
- Session-linked Payment Allocation.
- Advance.
- Outstanding.
- Idempotent Settlement Retry.
- Offline reconciliation.
- Correction path.
- م-26 وم-27.

### Android Offline والتشغيل الخلفي

ق-89 وق-90 ثم:

`technical/ANDROID_OFFLINE_BACKGROUND_SYNC.md`

ثم:

`technical/SYNC_ARCHITECTURE.md`

المصدر يحدد:

- Local durable DB.
- Outbox.
- WorkManager/background sync.
- Retry/idempotency.
- Reboot recovery.
- Offline session lifecycle.
- historical pricing.
- time integrity.
- device readiness.
- permissions/settings.
- Android field acceptance.

### المزامنة والعمل دون اتصال
ق-75 ثم `technical/SYNC_ARCHITECTURE.md`.

يوجد مستويان مختلفان:

1. Server idempotency/conflict infrastructure:
   منفذ في قاعدة البيانات.

2. Mobile offline synchronization:
   outbox المحلي وPowerSync وربط الجهاز وتجربة التعارض في Flutter
   ما زالت ضمن مرحلة التطبيق ولم تعتبر منجزة.

### الإشعارات
ق-34 إلى ق-36، ثم م-23.

منطق الخادم الدوري مبني ومختبر.
يبقى ظهور الإشعارات في Flutter وتفعيل المجدول عند النشر.

### المسائل المفتوحة
`memory/OPEN_ISSUES.md`.

الفجوات التقنية ذات الأثر على Stage 7 حاليًا:

- م-16: نطاق farmer RLS.
- م-18: كتالوج الأدوار غير مربوط بالنظام الفعلي.
- م-19: مغلقة بق-81 / 076؛ نموذج المضخة والتقرير والتوازي مصححة.
- م-21: الاختبارات الميدانية.
- م-22: مغلقة بق-80 / 075؛ الأرض ترتبط الآن بـFarmer Well Account.
- م-23: واجهة الإشعارات والمجدول.

### التدقيق المستقل القديم
`technical/CONFORMANCE_AUDIT_CODEX.md` وثيقة تاريخية.

لا يجوز استخدام نتائجها القديمة كحالة حالية دون قراءة
قسم الحالة التاريخية المضاف إلى بدايتها ومطابقتها مع ق-77 إلى ق-79.

## 3. baseline الحالي المثبت

اعتبارًا من 2026-08-17:

- 76 migration.
- 17 permanent database test files.
- 217 PASS.
- 0 FAIL.
- 0 ERROR.
- 33 RPC داخل `api`.
- Direct DML = 0.
- `anon` EXECUTE داخل `api` = 0.
- SECURITY DEFINER داخل `api` = 0.

## 4. بوابة Stage 7

- الشرط 1 — API Architecture: مغلق.
- الشرط 2 — RPC-only writes: مغلق.
- الشرط 3 — Documentation Conformance: مغلق — 2026-08-17.
- م-22 مغلقة — 2026-08-17.
- م-19 مغلقة — 2026-08-17.
- الشرط 4 — الفجوات السابقة للشاشات الحساسة: مغلق — 2026-08-17.
- م-22: مغلقة بق-80 / 075 — شاشة الأراضي لم تعد محجوبة بهذه الفجوة.
- م-19: مغلقة ضمن الشرط 4B بق-81 / 076.
- الشرط 5 — Final Clean Acceptance: مغلق — 2026-08-17.

## Stage 7 gate — current after Q81

### Baseline المثبت — 2026-08-17

- migrations = 75.
- permanent database test files = 16.
- PASS = 205.
- FAIL = 0.
- ERROR = 0.
- Data API RPC = 32.
- Direct DML = 0.
- API SECURITY DEFINER = 0.
- anon API EXECUTE = 0.

### Gate

- الشرط 1 — API Architecture: مغلق.
- الشرط 2 — RPC-only writes: مغلق.
- الشرط 3 — Documentation Conformance: مغلق.
- الشرط 4A — م-22 / Farm Farmer Identity: مغلق.
- الشرط 4B — م-19 / Pump Schema: مغلق.
- **الشرط 4: مغلق — 2026-08-17.**
- **الشرط 5 — Final Clean Acceptance: مغلق — 2026-08-17.**

## Stage 7 Readiness Gate — CLOSED

**الحالة:** مغلق — 2026-08-17.

إثبات القبول النهائي النظيف:

- clean rebuild: PASS.
- migrations = 75.
- permanent tests = 16.
- PASS = 205.
- FAIL = 0.
- ERROR = 0.
- Data API RPC = 32.
- Direct DML = 0.
- API SECURITY DEFINER = 0.
- anon API EXECUTE = 0.
- authenticated API EXECUTE = 32.
- service_role API EXECUTE = 32.
- exposed schemas = `api`, `graphql_public`.
- `public` والمخططات الداخلية غير مكشوفة للـData API.

شروط الجاهزية الخمسة مغلقة.


## Stage 7 — current after Q83

### Current verified technical baseline

- migrations = 76.
- permanent tests = 17.
- PASS = 217.
- FAIL = 0.
- ERROR = 0.
- Data API RPC = 33.
- Direct DML = 0.
- API SECURITY DEFINER = 0.
- anon API EXECUTE = 0.
- authenticated API EXECUTE = 33.
- service_role API EXECUTE = 33.

### UX / Visual Design

- S7-01 bootstrap: closed.
- Q82 app bootstrap read contract: closed.
- Q83 visual identity gate: closed provisionally.
- governing visual identity source:
  `design/VISUAL_IDENTITY.md`.
- next step: page-by-page discussion before production UI implementation.

### بوابة اكتمال التوثيق

القرار الحاكم:

ق-97.

المصدر:

`memory/DOCUMENTATION_GATE.md`

تطبق قبل الانتقال من أي موضوع معتمد إلى الموضوع التالي.

تحدد:

- شروط سجل القرار.
- أسباب القرار.
- شروط UX.
- شروط التوثيق التقني.
- Gap tracking.
- Progress.
- Changelog.
- Resume Point.
- Project Map.
- Matrix.
- Invariants.
- Evidence.
- Git closure.
- Meta-documentation.
- Traceability.

### سجلات التشغيل والحجوزات والمناوبات

ق-98 ثم:

`technical/OPERATIONS_RECORDS_ARCHITECTURE.md`

المصدر يحدد:

- Session history.
- Farmer/Farm records.
- Booking server confirmation.
- Offline tentative booking.
- Resource conflicts.
- Shift lifecycle.
- Session responsibility transfer.
- Operational vs Cash Handover.
- no-orphan active session.
- م-28.

### المال والشركاء والتوزيعات

القرار:

ق-99.

المصدر التقني:

`technical/MONEY_PARTNERS_ARCHITECTURE.md`

يغطي:

- Farmer financial accounts.
- invoices/payments/advances.
- explicit advance allocation.
- expenses.
- partner share history.
- profit distributions.
- partner payouts.
- accounting periods.
- financial corrections.
- financial Offline/Reconciliation.
- م-29.

ق-99 تكمل ولا تستبدل ق-92 وم-27 في Session Settlement.

### إدارة البئر والتقارير والرسوم

القرار:

ق-100.

المصدر التقني:

`technical/WELL_MANAGEMENT_REPORTING_ARCHITECTURE.md`

يغطي:

- Well/Pump configuration.
- Session Energy Authority.
- Fuel Inventory.
- Historical Pricing.
- Reporting Read Models.
- V1 Bar/Line Charts.
- chart locations.
- drill-down.
- Offline/Stale reports.
- report authorization.
- م-30.

المصدر البصري للرسوم:

`design/VISUAL_IDENTITY.md`.

### الحساب والإعدادات

القرار:

ق-101.

المصدر التقني:

`technical/ACCOUNT_SETTINGS_ARCHITECTURE.md`

يغطي:

- unified account.
- phone change/recovery.
- password recovery.
- team access lifecycle.
- notifications.
- device/sync entry.
- account-scoped local state.
- logout with pending outbox.
- English date/time display.
- م-31.

Platform Administration ليست جزءًا من هذا المصدر.
