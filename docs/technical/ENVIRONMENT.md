# بيئة العمل

**آخر تحقق فعلي:** 2026-08-17

هذا الملف وحده هو مصدر حقيقة البيئة الحالية.

## الجهاز والنظام

- نظام التشغيل: Kali Linux.
- مسار المشروع: `/home/kali/pr/well-irrigation`.
- Git branch: `main`.

## الأدوات المثبتة والمثبت عملها

- Docker: 28.5.2+dfsg4.
- Node.js: v24.18.0.
- npm: 11.16.0.
- PostgreSQL client `psql`: 18.4.
- Supabase CLI: 2.111.0.
- Git: مثبت.
- Flutter: مثبت ومثبت العمل.
- Dart: متاح عبر بيئة Flutter.
- Android SDK: مثبت ومثبت العمل.
- `flutter doctor`: تحقق سابقًا بلا تحذيرات.
- تطبيق Flutter شُغل سابقًا على جهاز Android حقيقي SM-A136U.

## Supabase المحلي

Supabase المحلي يعمل فعليًا.

آخر إعادة بناء نظيفة مثبتة وصلت إلى:

- migration 074.
- 75 migration.
- 16 permanent test files.
- 205 PASS.
- 0 FAIL.
- 0 ERROR.

## Data API

Exposed Schemas:

- `api`
- `graphql_public`

غير مكشوفة:

- `public`
- `core`
- `iam`
- `ops`
- `billing`
- `finance`
- `inventory`
- `audit`
- `sync`
- `reporting`

السطح الحالي:

- 32 RPC داخل `api`.
- Direct DML = 0.
- API SECURITY DEFINER = 0.
- anon API EXECUTE = 0.

## GitHub

المستودع موجود داخل منظمة `well-irrigation`.

أداة التكامل التي حاولت الكتابة أعادت 403
`Resource not accessible by integration`.

لذلك لا تعتبر قدرة المساعد على الكتابة إلى GitHub مثبتة.

## Flutter / Android

بيئة Flutter لم تعد مسألة مفتوحة.

المسألة م-03 مغلقة.

بدء Stage 7 لا يتطلب إعادة تثبيت Flutter من الصفر.

## Firebase / Google Play / Production

لا توجد في هذا baseline شهادة تحقق من نشر Production فعلي.

FCM وجدولة الإشعارات والنشر في Google Play تبقى عناصر
مرحلة التطبيق/النشر إلى أن يتم التحقق منها صراحة.

لا يُستنتج اكتمالها من اكتمال قاعدة البيانات.

## قاعدة التحقق

لا تُحدّث أرقام هذا الملف اعتمادًا على خطة أو نية.

يجب أن يكون كل ادعاء هنا ناتجًا عن تحقق فعلي.

## Baseline بعد ق-81 / 076

تم التحقق محليًا بواسطة المالك في 2026-08-17:

- 75 migration مطبقة.
- 16 permanent test files.
- 205 PASS.
- 0 FAIL.
- 0 ERROR.
- Data API RPC = 32.
- Direct DML = 0.
- API SECURITY DEFINER = 0.
- anon API EXECUTE = 0.

Migration 076 نجحت ضمن `supabase db reset` كامل.

## Final Clean Acceptance — 2026-08-17

أعيد بناء البيئة المحلية من الصفر وقُبلت نهائيًا:

- 75 migrations.
- 16 permanent tests.
- 205 PASS.
- 0 FAIL.
- 0 ERROR.
- Data API RPC = 32.
- Direct DML = 0.
- API SECURITY DEFINER = 0.
- anon API EXECUTE = 0.
- authenticated API EXECUTE = 32.
- service_role API EXECUTE = 32.
- exposed schemas = api + graphql_public فقط.

Stage 7 Readiness Gate مغلق.
