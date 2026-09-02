# خريطة المشروع — مصادر الحقيقة الحالية

**آخر تحديث:** 2026-09-02

هذه الوثيقة تحدد أي ملف يفوز عند التعارض، وتفصل بين
الحالة الحالية والسجل التاريخي.

باب الدخول لأي وكيل ذكاء اصطناعي هو `AGENTS.md` في جذر المستودع
(و`CLAUDE.md` مؤشِّر إليه). وهو **ليس** في ترتيب السلطة أدناه: لا يقرر
شيئًا، بل يدل على من يقرر ويحمل عقد العمل التشغيلي — من ينفّذ الأوامر،
وحقائق القناة السحابية، والحدود النافذة.

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

آخر قرار مرقم حاليًا: ق-120.

### الحالة التشغيلية الحالية — ق-120

المشروع **Pre-Production**، ولا يوجد استخدام حقيقي حالي أو بيانات
عملاء/تشغيل مالية حقيقية. المرحلة الحالية:

**Audit → Inspection → Evaluation → Repair → Gap Closing**

لا يبدأ أي Screen أو Feature أو وظيفة جديدة حتى اجتياز بوابة
التثبيت. الاعتمادات السابقة لا تُلغى؛ التنفيذ الجديد مؤجل فقط.

P0 م-38/م-39/م-40 أُغلقت بالأدلة المطلوبة:
م-38 وم-39 Verified local + Cloud، وم-40 Verified local
(Cloud غير منطبق). الأولوية الحالية هي **Pre-Production Audit Queue**
المحددة في `memory/RESUME_POINT.md`.

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
- سطح Data API المثبت حاليًا = 34 RPC.

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
- PA-01 / Platform Administration Foundation & Dashboard: معتمد وموثق.
- PA-02 / Accounts, Wells & Support Control: معتمد وموثق.
- ق-88 / Smart Lookup ودعم منع التكرار: معتمد.
- ق-89 / Offline Field Operations وBackground Sync: معتمد.
- ق-90 / Device Readiness وSync Transparency: معتمد.
- ق-91 / Active Session وBilling Consistency: معتمد.
- ق-92 / Session Completion وSettlement Consistency: معتمد.

هذا ترتيب تصميمي تاريخي سابق على ق-120، ولا يحدد NEXT الحالي.
نقطة العمل الحالية تؤخذ حصريًا من `memory/RESUME_POINT.md`.

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
- فجوات Migration 085+ واختبارات القبول.

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

بند 16 (الاستعادة المحلية) **منفَّذ ومُبرهن بق-116** في
`apps/mobile/lib/core/session/`؛ وبند 8 (الإرسال الخلفي)
**منفَّذ في منطق القرار بق-117** في
`apps/mobile/lib/core/sync/background_sync_*` بلا إثبات على
جهاز؛ وبقية البنود تصميم ملزم لم يُنفَّذ بعد.

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

   الطابور المحلي الدائم منفَّذ ومُبرهن بق-115،
   وسجل الجلسة النشطة والاستعادة بعد موت التطبيق بق-116،
   والإرسال الخلفي بلا فتح التطبيق بق-117،
   في `apps/mobile/lib/core/sync/` و`apps/mobile/lib/core/session/`
   — `flutter test` = 155 PASS / 0 FAIL.

   ما زال غير منفَّذ: ربط الجهاز وشاشات المزامنة والتعارض في
   Flutter (W2-02d)، وقياسات بند 9. والإرسال الخلفي مُبرهَن في
   منطق القرار على الحاسوب فقط — لم يُجرَّب على جهاز، وبناء
   Android لم يُجرَّب أصلًا.

   PowerSync لم يُستخدم؛ الأساس المنفَّذ هو Outbox على
   `sqflite` يُرسل عبر `api.*` وفق ق-79.

### الإشعارات
ق-34 إلى ق-36، ثم م-23.

منطق الخادم الدوري مبني ومختبر.
يبقى ظهور الإشعارات في Flutter وتفعيل المجدول عند النشر.

### المسائل المفتوحة
`memory/OPEN_ISSUES.md`.

الفجوات التقنية ذات الأثر على Stage 7 حاليًا:

- م-16: مغلقة بق-111 / 079؛ نطاق farmer RLS = Self-only.
- م-18: مغلقة بق-113 / 081+082؛ الكتالوج مربوط بالسلطة الفعلية.
- م-19: مغلقة بق-81 / 076؛ نموذج المضخة والتقرير والتوازي مصححة.
- م-21: الاختبارات الميدانية.
- م-22: مغلقة بق-80 / 075؛ الأرض ترتبط الآن بـFarmer Well Account.
- م-23: واجهة الإشعارات والمجدول.
- م-25: **ضُيِّقت أربع مرات ولم تُغلق** — بق-114 (تكرار الخادم)
  وق-115 (الطابور الدائم) وق-116 (الاستعادة بعد موت التطبيق)
  وق-117 (الإرسال الخلفي بلا فتح التطبيق).
  الباقي: شاشات المزامنة والجاهزية، وقياسات بند 9،
  والإثبات على جهاز حقيقي.
- م-26 وم-27: تعارض Fuel Billing التاريخي في Migration 066
  صُحّح في Migration 085 وفق ق-17 وق-91؛ تبقى بقية عقود
  Active Session/Settlement المفتوحة كما يحدد `OPEN_ISSUES.md`.

### التدقيق المستقل القديم
`technical/CONFORMANCE_AUDIT_CODEX.md` وثيقة تاريخية.

لا يجوز استخدام نتائجها القديمة كحالة حالية دون قراءة
قسم الحالة التاريخية المضاف إلى بدايتها ومطابقتها مع ق-77 إلى ق-79.

## 3. baseline الحالي المثبت

اعتبارًا من 2026-08-30:

### قاعدة البيانات

- **86** ملف migration — آخرها 087؛ 071–087 immutable.
- **25** permanent database test file.
- **362 PASS / 0 FAIL / 0 ERROR**.
- **34 RPC** داخل `api`.
- Direct DML = 0.
- `anon` EXECUTE داخل `api` = 0.
- SECURITY DEFINER داخل `api` = 0.
- Remote history يتضمن 087.
- Cloud P0 verification:
  authenticated setup PASS؛ anon denied؛
  3500/7000/6000 محفوظة دون ×100؛
  Transaction ROLLED BACK؛ residue = 0.

### كود الهاتف

- `flutter analyze` = `No issues found!`.
- `flutter test` = **222 PASS / 0 FAIL**.
- Create-Well targeted regression = **2/2 PASS**.
- م-40 failure behavior مثبت محليًا.
- المصدر الحاكم للأرقام: `memory/PROGRESS.md`.

### baseline التاريخي — 2026-08-17

يُحفظ للمقارنة فقط ولا يُستخدم كحالة حالية:
76 migration / 17 test file / 217 PASS.

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

### Platform Administration

القرار:

ق-102.

المصدر التقني:

`technical/PLATFORM_ADMINISTRATION_ARCHITECTURE.md`

هذه Control Plane مستقلة عن Well Roles.

تغطي PA-01:

- global platform authority.
- separate Admin Console.
- Web/Desktop-first layout.
- right-side RTL navigation.
- live numeric KPI dashboard.
- wells/accounts/operations/sync/activation/finance metrics.
- simple Bar/Line charts.
- drill-down.
- near-real-time refresh.
- global monitoring.
- audit.
- trusted backend.
- password visibility requirement status.
- م-32.

المناقشة التالية:

PA-02.

### PA-02 — الحسابات والآبار والدعم وكلمات المرور

القرار:

ق-103.

المصدر:

`technical/PLATFORM_ADMIN_ACCOUNTS_WELLS_SUPPORT_ARCHITECTURE.md`

يغطي:

- global search.
- global accounts.
- identity resolution.
- account suspend/restore.
- sessions/devices.
- global wells.
- well suspend/restore.
- support cases.
- error references.
- admin corrections.
- audit.
- force password reset.
- OTP/user-chosen password recovery.
- lost-phone identity recovery.
- Platform Admin MFA/Step-up.
- no recoverable password vault.
- no current-password reveal.
- م-33.

ق-103 Password Option B أصبحت تاريخية ومنسوخة بق-105.

Trusted Auth Admin Boundary من ق-85 تبقى نافذة.

### Research & Standards Governance

القرار:

ق-104.

المصدر الحاكم:

`memory/RESEARCH_STANDARDS_GATE.md`

تطبق قبل القرارات الجوهرية ذات الأثر:

- security.
- authentication.
- accessibility.
- admin UX.
- monitoring.
- platform behavior.
- architecture.

التصنيف:

- Standards-aligned.
- Adapted.
- Exception.

أي نموذج جديد يجب أن يقرأ هذا المصدر قبل اتخاذ قرار
معياري جديد.

### Password Current Authority

القرار الحالي:

ق-105.

ينسخ Password Option B فقط من ق-103.

Current rule:

- Supabase/Auth Hash only.
- no Recoverable Password Vault.
- no Current Password Reveal.
- Platform Admin can force reset.
- OTP proves identity.
- user chooses new password.
- Platform Admin MFA mandatory before Production.

PA-02 non-password decisions remain active.

PA-03 / Sales, Activation, Operations & Financial Control:

**معتمدة وموثقة بق-106.**

المصدر:

`technical/PLATFORM_ADMIN_SALES_OPERATIONS_FINANCE_ARCHITECTURE.md`

تغطي:

- Platform Sales.
- one entitlement per purchased well.
- atomic/idempotent grant.
- activation corrections.
- global operations monitoring.
- administrative session correction.
- global financial monitoring.
- correction/reversal.
- accounting reopen admin decision.
- audited export.
- Online-only privileged writes.
- م-34.

المناقشة التالية:

PA-04 / Monitoring, Audit, Platform Settings & Final Admin Review.

PA-04 تخضع لق-104 قبل اعتمادها.

### Platform Sales Current Authority

القرار الحاكم:

ق-106.

ق-106 تثبت ق-86 وتنسخ من ق-10 فقط عبارة:

    النسخة الأولى مجانية بالكامل

Current V1 commerce:

- permanent manual sale.
- no recurring subscription.
- each purchased well = independent entitlement.
- sale history preserved.
- entitlement history preserved.
- corrections are audited.

### PA-04 — Monitoring, Audit, Settings & Incidents

القرار:

ق-107.

المصدر:

`technical/PLATFORM_ADMIN_MONITORING_SETTINGS_ARCHITECTURE.md`

يغطي:

- monitoring.
- alerting.
- incidents.
- postmortems.
- correlation.
- global audit projection.
- typed/versioned configuration.
- rollback.
- scoped maintenance.
- app version policy.
- release tracking.
- dependency health.
- telemetry privacy.
- security view.
- م-35.

### Platform Administration Design Status

- PA-01: معتمدة وموثقة.
- PA-02: معتمدة وموثقة.
- PA-03: معتمدة وموثقة.
- PA-04: معتمدة وموثقة.

**Platform Administration مكتملة تصميميًا.**

التنفيذ ما زال Pending وفق:

- م-32.
- م-33.
- م-34.
- م-35.

### Next (مؤجل مؤقتًا بق-120)

UX-17 / Final Cross-Cutting Review.

UX-17 تخضع لق-104 قبل اعتمادها.

### UX-17 — Final Cross-Cutting Review

القرار:

ق-108.

المصدر:

`technical/FINAL_CROSS_CUTTING_UX_ARCHITECTURE.md`

يغطي:

- terminology consistency.
- role/well context safety.
- Offline/Sync semantics.
- form/error/success consistency.
- financial/sensitive confirmation.
- Smart Lookup consistency.
- loading/empty/error/stale states.
- accessibility.
- RTL/font scaling.
- adaptive layout.
- notification/support/privacy.
- navigation/back/context-switch safety.
- م-36.

### UX Design Status

UX-00..UX-17:

**مكتملة تصميميًا.**

PA-01..PA-04:

**مكتملة تصميميًا.**

هذا لا يعني أن Production UI منفذة.

### Next (بعد بوابة التثبيت بق-120)

IMPLEMENTATION-01 / V1 Implementation Sequencing &
Dependency Plan.

يجب أن يرتب التنفيذ حسب:

- dependency.
- data integrity.
- security.
- Offline foundations.
- user-critical flow.
- testability.

وليس حسب رقم UX فقط.

### IMPLEMENTATION-01 — V1 Sequencing

القرار:

ق-109.

المصدر:

`technical/V1_IMPLEMENTATION_SEQUENCE.md`

الترتيب:

- W1 Backend Foundations.
- W2 Offline & Background Sync.
- W3 Auth/Onboarding/Well Creation.
- W4 Core Irrigation Session.
- W5 Operations Records.
- W6 Money & Partners.
- W7 Well Management & Reports.
- W8 Account/Settings/Notifications.
- W9 Platform Administration.
- W10 Final Acceptance.

المسألة الجامعة:

م-37.

### Current Implementation Point — محدّث بق-120

**Stabilization / Audit Gate.**

W1 مكتملة ومغلقة (W1-01 / W1-02 / W1-03a / W1-03b).

W2-01 مغلقة بق-114 / Migration 083+084.

W2-02a مغلقة بق-115 — طابور الهاتف الدائم، صفر تغيير DB.

W2-02c مغلقة بق-116 — سجل الجلسة النشطة يُشتق من الطابور
والاستعادة بعد موت التطبيق، صفر تغيير DB.

W2-02b مغلقة بق-117 — الإرسال الخلفي بلا فتح التطبيق
(`background_sync_*`)، صفر تغيير DB؛ مُبرهَن في منطق القرار
لا على جهاز.

لا يعود W2-02d هو NEXT الحالي حتى إغلاق م-38 وم-39 وم-40
والتحقق منها. بعد ذلك تعود خطة W2-02d وقياسات بند 9 إلى المسار.

الترتيب الحالي:

1. إصلاح صلاحيات `setup_well_full` وفق `api.*`.
2. إصلاح ×100 وإضافة Regression Test.
3. إزالة False Offline Success أو إثبات الحفظ المحلي.
4. التحقق ثم استئناف Audit Queue.

Migration 071–084 immutable.

أول DB change جديد:

**Migration 085+**.

### W1-01 — Profile ↔ Person Identity Foundation

القرار:

ق-110.

Migration:

078.

الحالة:

**مكتملة ومغلقة — Local + Cloud verified.**

الهدف:

إنشاء Explicit Tenant-aware link بين Login Account
وBusiness Person دون Name/Phone guessing.

لا تحل م-16 بعد.

لا تغير م-18.

بعد نجاح Verification:

W1-02 — Farmer Self-scope Authorization.
