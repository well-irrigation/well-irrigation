# نقطة الاستئناف — 2026-08-17

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

## التالي

**بوابة الهوية البصرية قبل أي بناء واجهة تشغيلية جديدة.**

يجب مناقشة واعتماد الهوية البصرية وتجربة العرض بالتفصيل
قبل بناء شاشة اختيار البئر أو شاشة اليوم أو أي واجهة فعلية.

بعد اعتماد الهوية البصرية يبدأ ربط واجهات التطبيق بعقود
القراءة المعتمدة.

لا تُغيّر أرقام الـbaseline إلا بدليل تحقق جديد.

## قاعدة التنفيذ

المساعد لا يشغّل اختبارات المشروع أو `db:test`
أو `db:reset` أو Docker verification.

المالك يشغّل التحقق ويرسل الناتج.
