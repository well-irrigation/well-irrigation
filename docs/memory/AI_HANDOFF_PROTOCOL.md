# AI Handoff Protocol — بروتوكول تسليم المشروع

**القرارات الحاكمة:** ق-93، ق-95، ق-96، ق-97، ق-104
**آخر تحديث:** 2026-08-19
**الحالة:** نافذ

## 1. الهدف

هذا الملف يحدد كيف يستلم أي نموذج ذكاء اصطناعي المشروع
من المستودع وحده دون الحاجة إلى محادثة سابقة.

لا يعتبر هذا الملف مصدر حقيقة بديلًا عن ملفات المشروع
الحاكمة.

وظيفته تحديد:

- ماذا يقرأ.
- بأي ترتيب.
- أين يجد الحقيقة.
- كيف يعرف آخر نقطة توقف.
- ماذا يجب أن يحدث عند إنهاء كل دفعة عمل.

## 2. ترتيب القراءة الإلزامي

أي نموذج جديد يبدأ هكذا:

1. `docs/README.md`
2. `docs/PROJECT_MAP.md`
3. `docs/memory/AI_HANDOFF_PROTOCOL.md`
4. `docs/memory/AI_COLLABORATION_PROTOCOL.md`
5. `docs/memory/RESEARCH_STANDARDS_GATE.md`
6. `docs/memory/TERMINAL_COMMAND_PROTOCOL.md`
7. `docs/memory/DOCUMENTATION_GATE.md`
8. `docs/memory/RESUME_POINT.md`
9. `docs/memory/DECISIONS.md`
10. `docs/technical/INVARIANTS.md`
11. `docs/technical/API_ARCHITECTURE.md`
12. `docs/technical/SYNC_ARCHITECTURE.md`
13. `docs/technical/DECISION_IMPLEMENTATION_MATRIX.md`
14. الوثيقة التقنية الخاصة بالموضوع الحالي
15. القسم الحالي من `docs/design/UX_UI_SPEC.md`
16. `docs/memory/OPEN_ISSUES.md`
17. `docs/memory/REMINDERS.md`

بعد ذلك فقط تستخدم:

- `PROGRESS.md` لفهم ما أنجز تاريخيًا.
- `DOC_CHANGELOG.md` لفهم كيف تغير التوثيق.
- `reference/` للمرجع القديم المقيد بالقرارات الأحدث.

## 3. قاعدة نقطة التوقف

المصدر الوحيد لما يجب فعله بعد ذلك هو:

`docs/memory/RESUME_POINT.md`

لا تستنتج الخطوة التالية من:

- آخر Commit فقط.
- PROGRESS.
- DOC_CHANGELOG.
- Reference documents.
- محادثة قديمة.

## 4. قاعدة السلطة

ترتيب السلطة موجود في:

`docs/PROJECT_MAP.md`

إذا تعارضت معلومتان:

- لا تخمن.
- لا تختار الملف الأحدث تلقائيًا.
- طبق ترتيب السلطة.
- إذا بقي التعارض، سجله كمسألة مفتوحة.

## 5. عقد التوثيق لكل دفعة عمل

قبل الانتقال من دفعة إلى التالية يجب تحديث الملفات
المنطبقة التالية.

### قرار جديد أو تغيير سياسة

`memory/DECISIONS.md`

ويجب أن يتضمن:

- القرار.
- السبب.
- الحالة.
- الأثر.
- ما ينسخه إن وجد.
- متطلبات التنفيذ إن وجدت.

### UX معتمد

`design/UX_UI_SPEC.md`

ويجب أن يتضمن:

- السلوك.
- الحالات.
- الأزرار.
- الصلاحيات.
- Offline/Sync عند الانطباق.
- الأخطاء.
- الحالات الفارغة.
- متطلبات Backend.
- ما لم ينفذ بعد.

### قاعدة تقنية

تحدث الوثيقة التقنية الحاكمة المناسبة.

### Gap أو تعارض أو عمل مطلوب

`memory/OPEN_ISSUES.md`

ولا يجوز دفن Gap داخل فقرة UX فقط.

### تنفيذ ثبت فعليًا

`memory/PROGRESS.md`

ولا يكتب فيه Planned أو Intended.

### تغيير في الوثائق

`memory/DOC_CHANGELOG.md`

يسجل:

- التاريخ.
- الملفات أو المجال.
- ماذا تغير.
- لماذا.
- القرار المبرر.

### نقطة التوقف

`memory/RESUME_POINT.md`

تحدث في كل دفعة تغير ما تم إنجازه أو ما هو التالي.

### تغير مصدر حقيقة أو خريطة قراءة

`PROJECT_MAP.md`

### تغير مطابقة القرار بالتنفيذ

`technical/DECISION_IMPLEMENTATION_MATRIX.md`

## 6. تعريف «موثق بالكامل»

الموضوع لا يعتبر موثقًا بالكامل إذا غاب واحد مما ينطبق:

- ماذا قررنا.
- لماذا قررناه.
- حالة القرار.
- تجربة المستخدم.
- مصدر الحقيقة التقني.
- ما الموجود حاليًا.
- ما المفقود.
- التعارضات.
- الصلاحيات.
- Offline/Sync.
- اختبارات القبول.
- Migration/API المطلوبة.
- المسألة المفتوحة عند وجود Gap.
- نقطة الاستئناف.

## 7. الفرق بين الأنواع الأربعة للحالة

يجب عدم خلط:

### Adopted

قرار معتمد.

### Documented

القرار مكتوب في مصادره الصحيحة.

### Implemented

الكود أو قاعدة البيانات موجودة.

### Verified

التنفيذ اختبر وثبت بالدليل.

لا تحول Adopted إلى Implemented لمجرد وجود وثيقة.

## 8. الأدلة

عند وصف شيء بأنه Verified يجب وجود دليل مثل:

- نتيجة اختبار.
- فحص بنيوي.
- Commit.
- Migration مطبقة.
- نتيجة جهاز حقيقي.
- قياس ميداني.

ولا تختلق أرقام اختبار لم تشغل.

## 9. Git closure

قبل إغلاق دفعة توثيق أو تنفيذ:

- `git diff --check`
- فحص الملفات المتوقعة.
- Commit واضح.
- Push إلى `main` أو الفرع المتفق عليه.
- Worktree نظيف.

بعد ذلك فقط تحدث نقطة العمل إلى الدفعة التالية.

## 10. قاعدة منع فقدان السياق

إذا كانت معلومة مهمة موجودة فقط داخل المحادثة وليست
في المستودع، فالتوثيق غير مكتمل.

يجب نقلها إلى المصدر الصحيح قبل الاعتماد على المحادثة
كمصدر وحيد.

هذه القاعدة هي الغرض الأساسي من ق-93.

## 11. كيف يعمل النموذج بعد الاستلام

بعد قراءة هذا الملف يجب قراءة:

`AI_COLLABORATION_PROTOCOL.md`

لفهم:

- أسلوب الحوار.
- منهج القرار.
- طريقة عرض التوصيات.
- Workflow الاعتماد والتوثيق.
- طريقة التعامل مع التعارض والفجوات.
- الفرق بين Adopted/Documented/Implemented/Verified.

ثم يقرأ:

`TERMINAL_COMMAND_PROTOCOL.md`

قبل كتابة أي أمر للمالك.

هذا يمنع أن يعرف النموذج «ماذا يفعل» لكنه يجهل
«كيف نعمل».

## 12. Documentation Gate قبل الانتقال

قبل أن يعتبر النموذج أي دفعة مكتملة، يقرأ ويطبق:

`DOCUMENTATION_GATE.md`

القاعدة:

    لا انتقال إلى الموضوع التالي
    قبل DOCUMENTATION_GATE=PASS

وتطبق البوابة أيضًا إذا كانت الدفعة تعدل طريقة التوثيق
أو بروتوكول AI نفسه.

## 13. Research & Standards Gate قبل القرار

ق-104 تضيف بوابة إلزامية:

`RESEARCH_STANDARDS_GATE.md`

إذا كان القرار جوهريًا ويحتاج External Evidence:

    Source of Truth
        ↓
    Research & Standards Gate
        ↓
    Recommendation
        ↓
    Adoption
        ↓
    Documentation Gate

أي AI جديد يجب ألا يفترض أن:

    ممكن تقنيًا = أفضل ممارسة

وعندما يفوض المالك AI باختيار «الأفضل للمشروع»:

يطبق ق-104 ويختار Standards-aligned أو Adapted بصورة
موثقة دون إعادة سؤال غير ضروري.

## UX Design Closure — ق-108

حالة التصميم الحالية:

- UX-00..UX-17 Design Complete.
- PA-01..PA-04 Design Complete.

لا تعني Implemented.

أي AI يستلم المشروع بعد ق-108:

لا يبدأ UX discussion جديدة تلقائيًا.

يقرأ:

- `design/UX_UI_SPEC.md`
- `design/VISUAL_IDENTITY.md`
- `technical/FINAL_CROSS_CUTTING_UX_ARCHITECTURE.md`
- architecture الخاصة بالمجال الجاري تنفيذه.

ثم ينتقل إلى:

`IMPLEMENTATION-01 — V1 Implementation Sequencing &
Dependency Plan`

ما لم يطلب المالك صراحة إعادة فتح قرار تصميم.

Research & Standards Gate وDocumentation Gate تبقيان
نافذتين أثناء التنفيذ.

## Implementation Program — ق-109

UX/PA design is complete.

The project is now in implementation.

Governing sequence:

`technical/V1_IMPLEMENTATION_SEQUENCE.md`

Current point:

**W2 — Offline & Background Sync. W1 مكتملة ومغلقة، وW2-01 (حماية التكرار على الخادم) مكتملة؛ التالي W2-02 طابور الهاتف.**

Do not start arbitrary screens.

Do not edit migrations 071–084.

New DB changes begin 085+.

Use coherent domain-sized migrations and permanent tests.

After foundations, prefer vertical end-to-end slices.

Project DB/Docker verification remains owner-run.
