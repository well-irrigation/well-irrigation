# اقرأني أولًا

**المشروع:** إدارة البئر والسقي
**الاسم التقني:** well-irrigation
**معرّف الحزمة:** com.wellirrigation.app
**آخر تحديث توثيقي:** 2026-08-19

## ما هذا المشروع؟

تطبيق Android لإدارة آبار المياه والسقي في اليمن.

يغطي بصورة مترابطة:

- تشغيل الآبار وجلسات السقي.
- المزارعين والأراضي والحجوزات.
- المضخات ومصادر الطاقة والوقود.
- الأسعار والفواتير والمدفوعات.
- المصروفات والحسابات.
- الشركاء والأرباح والتوزيعات.
- المستخدمين والأدوار والصلاحيات.
- التقارير والإشعارات.
- العمل دون إنترنت والمزامنة اللاحقة.

العمل الميداني Offline جزء أساسي من التصميم.

## الغرض من مجلد docs

هذا هو نظام الذاكرة الرسمي للمشروع.

الهدف أن يستطيع:

- مطور جديد.
- نموذج ذكاء اصطناعي جديد.
- المالك بعد انقطاع طويل.

فهم المشروع واستئناف العمل دون الاعتماد على ذاكرة
محادثة سابقة.

## نقطة البداية الإلزامية

اقرأ بهذا الترتيب:

1. `README.md`
2. `PROJECT_MAP.md`
3. `memory/AI_HANDOFF_PROTOCOL.md`
4. `memory/AI_COLLABORATION_PROTOCOL.md`
5. `memory/RESEARCH_STANDARDS_GATE.md`
6. `memory/TERMINAL_COMMAND_PROTOCOL.md`
7. `memory/DOCUMENTATION_GATE.md`
8. `memory/RESUME_POINT.md`
9. `memory/DECISIONS.md`
10. `technical/INVARIANTS.md`
11. الوثائق التقنية التي يشير إليها `PROJECT_MAP.md`
12. `design/UX_UI_SPEC.md` عند العمل على الواجهات
13. `memory/OPEN_ISSUES.md`
14. `memory/REMINDERS.md`

للتاريخ فقط:

- `memory/PROGRESS.md`
- `memory/DOC_CHANGELOG.md`

لا تستخدم ملفًا تاريخيًا لتحديد الحالة الحالية إذا كان
المصدر الحاكم يقول غير ذلك.

## أين توجد الحالة الحالية؟

### أين توقفنا؟

`memory/RESUME_POINT.md`

هو المصدر الوحيد لنقطة التوقف والخطوة التالية.

### القرارات

`memory/DECISIONS.md`

القرار المرقم الأحدث الناسخ هو الحاكم.

### ما تم تنفيذه فعلًا؟

`memory/PROGRESS.md`

لا يسجل إلا ما تم وثبت بدليل.

### أين توجد الفجوات؟

`memory/OPEN_ISSUES.md`

### ما الذي تغير في الوثائق؟

`memory/DOC_CHANGELOG.md`

### أين توجد مصادر الحقيقة لكل موضوع؟

`PROJECT_MAP.md`

### كيف يستلم نموذج ذكاء اصطناعي المشروع؟

`memory/AI_HANDOFF_PROTOCOL.md`

### كيف نتناقش ونتخذ القرارات؟

`memory/AI_COLLABORATION_PROTOCOL.md`

### كيف نتحقق من المعايير وأفضل الممارسات؟

`memory/RESEARCH_STANDARDS_GATE.md`

هي البوابة الإلزامية للقرارات الجوهرية التي تحتاج:

- معيارًا أمنيًا.
- Platform guidance.
- Accessibility guidance.
- mature-product evidence.
- real-user feedback.
- Project Fit.

تطبق قبل الاعتماد عندما ينطبق البحث.

### كيف تكتب أوامر الطرفية؟

`memory/TERMINAL_COMMAND_PROTOCOL.md`

## قاعدة مهمة

الاعتماد أو التوثيق لا يعني التنفيذ.

مثال:

    UX معتمد وموثق

لا يعني:

    Flutter production implementation complete

وكذلك:

    Backend requirement documented

لا يعني:

    Migration applied

حالة التنفيذ يجب أن تأتي من الدليل الفعلي.

## قاعدة عدم التكرار

المعلومة الأساسية لها مصدر حاكم واحد.

بقية الوثائق:

- تلخص.
- تشير.
- تسجل تاريخًا.

ولا تنشئ حقيقة موازية متعارضة.

## قواعد التنفيذ الحالية

- Flutter لا ينفذ Direct DML على Business Schemas.
- Data API العام يمر عبر `api.*`.
- migrations 071–077 المقبولة لا تعدل.
- أي DB change جديد يبدأ من Migration 078+.
- المساعد لا يشغل اختبارات المشروع أو db reset أو Docker verification.
- المالك يشغل اختبارات قاعدة البيانات ويرسل النتائج.

التفاصيل الحاكمة موجودة في `PROJECT_MAP.md`.

## بوابة التوثيق

قبل الانتقال بين دفعات العمل المعتمدة، المصدر الحاكم هو:

`memory/DOCUMENTATION_GATE.md`

هذه البوابة تتحقق من اكتمال القرار والسبب والسجلات
والفجوات ونقطة الاستئناف وإغلاق Git.

أي نموذج جديد يجب أن يطبقها قبل الانتقال إلى موضوع جديد.
