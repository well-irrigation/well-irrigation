# V1 Implementation Sequence

**آخر تحديث:** 2026-08-23
**القرار الحاكم:** ق-109
**الحالة:** معتمد — التنفيذ جارٍ؛ W2-02a مكتملة بق-115،
وW2-02c مكتملة بق-116، وW2-02b مكتملة بق-117
**المسألة الجامعة:** م-37
**Research & Standards Gate:** PASS

## 1. الهدف

تحويل التصميم الكامل إلى برنامج تنفيذ مرتب حسب:

- dependencies.
- data integrity.
- security.
- Offline foundations.
- user-critical flows.
- testability.

لا ينفذ المشروع حسب ترتيب أرقام UX فقط.

## 2. قواعد التنفيذ

1. الهجرات المختومة immutable (السقف: `AGENTS.md` §4).

2. W1-02 وW1-03 مغلقتان؛ W1-03b مطبقة بق-113 /
   Migration 081+082؛ وW2-01 مطبقة بق-114 /
   Migration 083+084؛ وW2-02a مطبقة بق-115، وW2-02c مطبقة
   بق-116، وW2-02b مطبقة بق-117 — الثلاث بلا أي تغيير على
   قاعدة البيانات؛ أي DB change جديد يبدأ Migration 085+.

3. Migration 078 ليست Migration عملاقة تجمع V1 كلها.

4. كل Domain change منطقي يحصل على Migration مستقلة
   متتابعة عند الحاجة:

   078, 079, 080, 081 ...

5. كل DB change تحتاج Permanent Test مناسب.

6. Assistant/AI لا يشغل db:test/db:reset/Docker verification.

7. مالك المشروع يشغل Verification ويرسل النتائج.

8. لا نغلق Wave قبل Evidence مناسب.

9. لا نعدل Remote Database يدويًا خارج Migration workflow.

    ملفات الترحيل هي المصدر الوحيد. إذا حُجبت قناة `db push`
    شبكيًا، يجوز نقل نفس الملفات بلا تعديل عبر سكربت `psql`
    قابل للاستكمال يسجّل كل migration في
    `supabase_migrations.schema_migrations` — القناة المعتمدة
    موثقة في `MIGRATIONS.md`. هذا نقل، لا تعديل يدوي.

10. لا Production UI بلا Backend Contract حقيقي.

## 3. أسلوب التنفيذ

بعد Foundations نستخدم:

**Vertical Slices.**

أي Feature تنفذ End-to-End قدر الإمكان:

    DB / domain
      ↓
    API
      ↓
    local/offline layer when applicable
      ↓
    application state
      ↓
    UI
      ↓
    verification

لا نبني عشرات الشاشات فوق Contracts غير منفذة.

## 4. W1 — Backend Foundations

الأولوية الأولى.

يشمل الأساس المطلوب لـ:

- canonical identity.
- account/profile/person relationships.
- Farmer RLS corrections.
- role/permission authority wiring.
- Auth/OTP trusted flows.
- phone recovery foundations.
- activation entitlements.
- atomic well activation.
- minimum trusted admin grant capability.
- authorization/security invariants.

المسائل ذات الصلة تشمل:

- م-16.
- م-18.
- أجزاء م-33.
- أجزاء م-34.

### W1-02 — Farmer self-scope

مكتملة ومغلقة:

- Migration 079 Local + Cloud applied.
- Permanent Test 079 = 20 PASS.
- Full DB Suite = 255 PASS.
- Farmer private operational data = Self-only.
- owner/manager/operator regression = PASS.
- Cloud structure/security verification = PASS.
- م-16 مغلقة.

### W1-03 — Role/Permission authority wiring

**مكتملة ومغلقة: م-18 مغلقة بق-113.**

W1-03a وW1-03b مغلقتان (Local + Cloud).

الكتالوج الحالي `iam.roles` / `iam.permissions` /
`iam.role_permissions` تأسيسي فقط منذ Migration 028،
بينما السلطة التشغيلية ما زالت تعتمد
`core.well_assignments.role`.

#### W1-03a — Permission Authority Foundation

مطبقة ومتحققة محليًا بق-112 / Migration 080:

- Permission catalog = 38 code (17 جديدة).
- `iam.well_assignment_role_map` = 6 صفوف؛ `farmer` مستثنى عمدًا.
- `iam.role_permissions` = 70 منح:
  tenant_owner 38 / well_manager 12 / operator 20.
- partner / accountant / viewer = 0 منح — قرار صلاحياتها مؤجل.
- `iam.has_well_permission(uuid, text)` = الدالة القانونية
  الجديدة للصلاحية، SECURITY DEFINER بـ`search_path` مثبت،
  execute لـ`authenticated` فقط.
- Legacy `iam.has_well_role` = 273 policy بلا تغيير.
- Permanent Test 080 = 20 PASS / 0 FAIL / 0 ERROR.
- Full DB Suite = 20 files / 275 PASS / 0 FAIL / 0 ERROR.
- API = 33 authenticated / 0 anon / 0 SECURITY DEFINER.
- Direct DML = 0.
- سلوك المستخدم = بلا تغيير (Additive only).

Cloud = متحقق منها 2026-08-21:
`CLOUD_080_ALL_PASS` (20/20) + `DATA_API_BOUNDARY=OK`.
Remote migration history = 79 through `20260819235001`.

W1-03a مكتملة ومغلقة.

#### W1-03b — Enforcement wiring

مطبقة ومتحققة محليًا وسحابيًا بق-113 /
Migration 081 + 082:

- 28 موضع حرس حي في 27 دالة انتقلت من
  `iam.has_well_role(well_id, array[...])` إلى
  `iam.has_well_permission(well_id, '<code>')`.
- Function-body guards على السلطة القديمة = **0**.
- `session.energy.change` أُنشئت — الفجوة الوحيدة في
  الكتالوج؛ الكتالوج = 39، المنح = 73
  (owner 39 / manager 13 / operator 21).
- برهان تكافؤ قبل الكتابة = 28 EQUIVALENT /
  1 MISSING_CODE / **0 DIFFERS** = `NO_SILENT_DRIFT`.
- حرس الهوية لم يُحوّل: `api.declare_handover` /
  `api.request_session_transfer` /
  `api.respond_session_transfer` وفرع الهوية في
  `api.close_shift`.
- `ops.create_farm` نُقلت من تعريف 075 الحي لا 069 المُسقط.
- Permanent Test 081 = 20 PASS؛ 082 = 20 PASS.
- Full DB Suite = 22 files / 315 PASS / 0 FAIL / 0 ERROR؛
  صفر Regression على 295 فحصًا سابقًا.
- Cloud = `CLOUD_W1_03B_ALL_PASS`؛ Remote history = 81
  through `20260822013001`.
- API = 33 authenticated / 0 anon / 0 SECURITY DEFINER.
- Direct DML = 0.
- سلوك المستخدم = بلا تغيير، مبرهنًا لا مُدّعى.

خارج النطاق عمدًا: 273 RLS policy تبقى على
`has_well_role` كطبقة توافق للقراءة وهي مستهلكها الوحيد؛
نقلها يحتاج دفعة مستقلة.

`partner` / `accountant` / `viewer` بصفر منح بالتصميم،
فلا تعرضها أي واجهة قبل قرار صريح لصلاحياتها.

W1-03 مكتملة ومغلقة. أي DB change جديد يبدأ Migration 085+.

### سبب W1

W2–W9 تعتمد على Backend Truth مستقرة.

## 5. W2 — Offline & Background Sync Foundations

يشمل:

- durable local database.
- Outbox.
- stable operation ids.
- retries.
- idempotent reconciliation.
- connectivity state.
- sync state.
- conflict state.
- WorkManager/background execution.
- Device Readiness.
- canonical user-facing sync semantics.

المسألة الرئيسية:

- م-25.

### W2-01 — Server-side Idempotency

**مكتملة ومغلقة — ق-114 / Migration 083+084 (2026-08-22)،
متحقق منها محليًا وسحابيًا.**

- 4 مُحلِّلات في `sync` تستخرج الجهة من البئر أو الجلسة؛
  العميل لا يُرسل `tenant_id`.
- 8 أغلفة `api.*` للدورة الميدانية الأولى تقبل
  `p_command_id uuid` اختياريًا في آخر الوسائط.
- استبدال التوقيع لا إضافته ⟹ سطح API بقي = 33.
- `p_command_id = null` = المسار القديم حرفيًا.
- Permanent Test 083 = 16 PASS؛ 084 = 23 PASS.
- Full DB Suite = 24 files / 354 PASS / 0 FAIL / 0 ERROR؛
  صفر Regression على 315 فحصًا سابقًا.
- Cloud = `CLOUD_W2_01_ALL_PASS` (39/0/0)؛ Remote history =
  83 through `20260823013001`؛ `DATA_API_BOUNDARY=OK`.
- `record_payment` لا يتضاعف إجماليها عند إعادة الإرسال.
- **م-25 تضيق ولا تُغلق.**

خارج نطاق W2-01 عمدًا: الورديات ونقل الجلسة والحجوزات
(ق-98) والمصروفات والتوزيعات (ق-99) — تُنقل بنفس النمط في
Migration 085+.

### W2-02 — طابور الهاتف

**W2-02a مكتملة — ق-115 (2026-08-23). صفر تغيير على قاعدة
البيانات.**

- durable local database على `sqflite` لنطاق الطابور والربط
  والحالة — `apps/mobile/lib/core/sync/`.
- Outbox مرتّب: تسلسل صارم داخل الجلسة، واستقلال بين الأصول.
- **معرّف العملية يُولَّد مرة واحدة لكل عملية ميدانية** ويُعاد
  إرساله بلا تغيير — مفروض بنيويًا (فريد، ويُكتب في `INSERT`
  فقط، ولا مسار تحديث له).
- **هوية الجلسة محسومة:** الربط الدائم المحلي↔الخادمي، ببرهانه
  من Migration 084.
- حلّ المراجع: الأمر التابع لا يُرسل قبل حسم معرّف أصله.
- وقت الحدث يُرسل صراحة بـUTC لا يُترك لافتراضي الخادم.
- تصنيف الفشل: إعادة مقابل مراجعة؛ الرمز المجهول ⟹ مراجعة.
- حجز شرطي بعمر معروف ⟹ لا إرسال مزدوج، والحجز الميت
  يُستعاد.
- عزل الحساب؛ الخروج لا يحذف الطابور.
- التحقق **نجح 2026-08-23**: `flutter analyze` =
  `No issues found!`؛ `flutter test` = **69 PASS / 0 FAIL** (بلا
  هاتف وبلا شبكة وبلا قاعدة بيانات)، ومنها ملف على SQL حقيقي عبر
  `sqflite_common_ffi`.

**المتبقي في W2-02:**

- **W2-02b — مكتملة. ق-117 (2026-08-23). صفر تغيير على قاعدة
  البيانات.**
  - **قيمة إرجاع العامل هي الحوار كلّه مع النظام**: يُعاد
    بالتراجع المسجَّل أو ينتهي. العامل لا يجدول لنفسه — الجدولة
    على نفس الاسم الفريد من داخله تُلغيه وهو يعمل أو تبني
    سلسلة عمل زائدة.
  - عمل فريد **لكل حساب** بشرط `NetworkType.connected`، بلا
    Expedited Work وبلا Foreground Service.
  - تراجع أُسّي 30ث ← ساعة ثم يثبت؛ **السقف على المدة لا على
    عدد المحاولات** — أمرٌ في الطابور لا يُسقَط أبدًا.
  - **ما ينتظر قرار إنسان لا يُوقظ الهاتف** (بند 20 من ق-90)،
    وما ينتظر الشبكة يُوقظه؛ والتمييز محسوب لا مُسمّى.
  - تفريغ الطابور داخل النافذة الواحدة ما دام هناك تقدّم؛
    وبلا تقدّم تمريرة واحدة فقط.
  - ثلاثة مصادر إيقاظ: فتح التطبيق (لازم لأن Force Stop لا
    يُتجاوَز — بند 10)، ورجوعه إلى الواجهة، وعودة الشبكة؛
    بكبح 20 ثانية على التلقائي لا على اليدوي.
  - **مؤشِّر الشبكة مؤشِّر لا دليل**: لا يُعلِّم أمرًا فاشلًا
    ولا يمسّ عدّاد إعادته.
  - `ACCESS_NETWORK_STATE` وحدها أُضيفت (بند 11)، وما تدمجه
    الحزمة مُسجَّل صراحة للمراجعة قبل النشر.
  - التحقق **نجح 2026-08-23**: `flutter analyze` =
    `No issues found!`؛ `flutter test` = **155 PASS / 0 FAIL**
    (خط الأساس السابق 115).
  - **ما لم يُثبت:** إعادة الجدولة بعد إقلاع الهاتف، وسلوك
    Force Stop، والمانيفست المدموج — **لم تُجرَّب على جهاز**؛
    وبناء Android لم يُجرَّب أصلًا (`androidx.work` غائبة عن
    Gradle cache)؛ وقياسات بند 9 غير موصولة.
- **W2-02c — مكتملة. ق-116 (2026-08-23). صفر تغيير على قاعدة
  البيانات.**
  - سجل الجلسة النشطة **يُشتق من الطابور** لا من جدول موازٍ،
    ولا يعتمد على `Timer` في الذاكرة (بند 16).
  - الأحداث تُحوَّل إلى مقاطع؛ **القسمة على كل مقطع ثم الجمع**
    — نفس Migration 066 حرفيًا.
  - حالة السقي وحالة المزامنة حقلان مستقلان بنيويًا (بند 3).
  - سلامة الزمن بمرساة + قراءة جهاز: تعديل الساعة وإعادة
    الإقلاع والترتيب المستحيل تُكشف بلا تعديل التكلفة بصمت.
  - الدفعة المحلية لا يقال عنها «مُرحَّلة» قبل معرّف خادمي،
    ولا مقاصّة صامتة (ق-99).
  - التحقق **نجح 2026-08-23**: `flutter analyze` =
    `No issues found!`؛ `flutter test` = **115 PASS / 0 FAIL**
    (خط الأساس السابق 69)، والاستعادة مبرهنة على **ملف قرص
    حقيقي** يُفتح من نسخة مخزن جديدة تمامًا.
- **W2-02d — لم يبدأ:** Device Readiness وشاشات حالة المزامنة
  (ق-90 / UX-10)، وعرض التعارض، وعقد قراءة `api.*` لأسماء
  المزارع والأرض والمضخة (بند 20 بند 2)، وقياسات بند 9.

**م-25 تضيق رابعةً ولا تُغلق.**

### Gate

لا نبدأ إنتاج معظم Field Screens قبل إثبات أن
Critical Offline Writes تحفظ محليًا بصورة دائمة.

## 6. W3 — Authentication, Onboarding & Well Creation

End-to-End:

- Splash.
- Login.
- OTP.
- account creation.
- create-well wizard.
- entitlement verification.
- atomic well creation + entitlement consumption.
- app bootstrap.
- role-aware routing.

هذه أول Vertical Slice مكتملة للمستخدم.

## 7. W4 — Core Irrigation Session

يشمل:

- session start.
- active session.
- billable timer.
- pause/resume.
- energy segments.
- offline-safe state.
- completion.
- settlement.
- invoice/payment allocation.
- fuel billing correction.

المسائل:

- م-26.
- م-27.

أي تصحيح لـMigration 066 يكون في Migration 085+
المناسبة ولا تعدل 066.

## 8. W5 — Operations Records & Coordination

يشمل:

- session history.
- farmer/farm records.
- bookings.
- shifts.
- operator handover.
- cash handover separation.
- conflict states.

المسألة:

- م-28.

## 9. W6 — Money & Partners

يشمل:

- farmer accounts.
- payments.
- advances.
- expenses.
- accounting periods.
- partners.
- profit cycles.
- distribution.
- financial corrections.

المسألة:

- م-29.

## 10. W7 — Well Management & Reporting

يشمل:

- well data.
- pumps.
- energy/fuel.
- pricing.
- fuel movements.
- reports.
- aggregates.
- Bar/Line charts.

المسألة:

- م-30.

## 11. W8 — Account, Settings & Notifications

يشمل:

- account settings.
- password recovery.
- phone recovery.
- logout/session management.
- devices.
- sync details.
- notifications.
- appearance.
- help/legal links.

المسائل:

- م-23.
- م-31.
- الأجزاء المتبقية من م-33 الخاصة بالمستخدم.

## 12. W9 — Platform Administration

الترتيب الداخلي:

### W9A — Trusted Admin Backend

ينفذ أولًا:

- global admin authorization.
- account/well admin reads.
- admin mutations.
- support/error references.
- sales/entitlements.
- operations/finance admin reads.
- monitoring/audit/configuration contracts.

### W9B — Admin Web/Desktop UI

بعد توفر Contracts:

- dashboard.
- wells.
- accounts.
- sales/activation.
- operations.
- finance.
- sync/devices.
- support.
- incidents.
- audit.
- monitoring.
- settings.

المسائل:

- م-32.
- م-33.
- م-34.
- م-35.

## 13. W10 — Final Acceptance & Release Readiness

يشمل:

- م-36 Cross-Cutting UX consistency.
- م-21 field testing.
- RTL.
- accessibility.
- font scaling.
- offline/reconnect.
- retry/duplicate-submit.
- security.
- finance invariants.
- admin separation.
- legal/privacy alignment.
- release readiness.

## 14. Dependency Rules

### Rule A

Identity/Auth before user flows.

### Rule B

Entitlement backend before production create-well flow.

### Rule C

Offline/Sync foundation before critical field screens.

### Rule D

Session core before history/reporting.

### Rule E

Settlement before downstream financial reporting.

### Rule F

Business APIs before Platform Admin UI that manages them.

### Rule G

Monitoring reads after the underlying operations exist.

### Rule H

Cross-cutting acceptance runs throughout implementation
and closes finally in W10.

## 15. Migration Strategy

Do not implement V1 in one migration.

Preferred pattern:

- coherent domain migration.
- permanent test.
- owner verification.
- commit.
- next dependent migration.

Migration number alone does not define a Wave.

One Wave may use multiple migrations.

## 16. Verification Gate per Wave

For each implementation batch:

1. code/schema/docs prepared.
2. static checks performed where safe.
3. assistant provides owner verification command.
4. owner runs DB/Docker/device tests.
5. results reviewed.
6. open issue updated.
7. Documentation Gate.
8. Commit/Push.
9. next dependent batch.

## 17. Research basis

### Supabase

Current official guidance supports:

- schema changes tracked as migrations.
- migrations committed to version control.
- applying migrations in order.
- avoiding unmanaged remote schema edits.

### Android

Current official offline-first architecture supports:

- local data source as source for reads.
- queues for deferred work.
- WorkManager for persistent queued work.

Project adaptation:

Offline foundation is implemented before critical
irrigation UI because field operation is core product
behavior.

## 18. Definition of Done

IMPLEMENTATION-01 is complete when:

- ق-109 documented.
- sequence source created.
- م-37 opened.
- RESUME_POINT moves to W1.
- handoff names W1 as next.
- Documentation Gate passes.

Next:

**W2-02d — جاهزية الجهاز وشاشات حالة المزامنة (ق-90 / UX-10)،
وقياسات بند 9 / بقية م-25. أي DB change جديد = Migration 085+.**

## 19. W1-01 — Explicit Account/Person Identity Foundation

أول Slice في W1:

**Migration 078.**

تنشئ Tenant-aware explicit link بين:

- Login Profile.
- Business Person.

سبب ترتيبها أولًا:

Farmer self-scope RLS لا يمكن أن تكون صحيحة إذا لم يعرف
Backend أي Person تخص الحساب الحالي.

### لا يدخل W1-01

- Farmer RLS rewrite.
- Role Catalog wiring.
- Entitlements.
- OTP.

### حالة W1-01

مكتملة ضمن نطاقها المعتمد: Local verification + Cloud structure/security verification.

### التالي — W1-02

Farmer self-scope authorization / م-16 باستخدام الرابط
المثبت في 078.

أي DB change جديد يبدأ Migration 085+.

م-18 روجعت منفردة وأُغلقت بق-113 / Migration 081+082.

م-25 ضُيِّقت بق-114 / Migration 083+084 ولم تُغلق.
