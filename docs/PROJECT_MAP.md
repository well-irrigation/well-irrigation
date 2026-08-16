# خريطة المشروع — مصادر الحقيقة الحالية

**آخر تحديث:** 2026-08-17

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

6. `reference/`
   المرجع الوظيفي والتصميمي، مقيد دائمًا بالقرارات الأحدث أعلاه.

7. بقية الملفات التاريخية مثل `PROGRESS.md` و`DOC_CHANGELOG.md`
   تحفظ تاريخ ما كان صحيحًا في لحظته ولا تتغلب على الحالة الحالية.

## 2. مصادر الحقيقة حسب الموضوع

### القرارات
`memory/DECISIONS.md`

آخر قرار مرقم حاليًا: ق-79.

### أين توقف العمل
`memory/RESUME_POINT.md` فقط.

لا تستخدم snapshot أقدم داخل PROGRESS أو DOC_CHANGELOG لتحديد الخطوة التالية.

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
- سطح Data API المثبت حاليًا = 32 RPC.

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

- 74 migration.
- 15 permanent database test files.
- 193 PASS.
- 0 FAIL.
- 0 ERROR.
- 32 RPC داخل `api`.
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
