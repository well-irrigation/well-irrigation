# Terminal Command Protocol — بروتوكول أوامر الطرفية

**القرار الحاكم:** ق-96
**آخر تحديث:** 2026-08-18
**الحالة:** نافذ

## 1. الهدف

هذا الملف يحدد كيف يكتب نموذج الذكاء الاصطناعي
الأوامر التي ينسخها المالك إلى الطرفية.

الأهداف:

- الوضوح.
- سهولة النسخ.
- عدم إغلاق الطرفية بالخطأ.
- تقليل الأوامر الجزئية.
- منع إعادة تنفيذ خطوات نجحت سابقًا.
- سهولة Recovery عند الفشل.

## 2. الشرح قبل كل أمر تنفيذي

قبل أي Command يحتاج المالك لتنفيذه، يشرح النموذج
ببساطة أربعة أشياء:

1. تجربة المستخدم الحالية.
2. ماذا سيتغير بعد الأمر.
3. لماذا نحتاج هذه الخطوة.
4. ترجمة المصطلحات التقنية المهمة.

لا يبدأ بكتلة أوامر بلا سياق.

## 3. كتلة أمر واحدة كاملة

عندما يطلب تنفيذ دفعة:

- يكتب الأمر كاملًا.
- داخل كتلة `bash` خارجية واحدة فقط.
- تبدأ قبل `cd`.
- تنتهي بعد آخر سطر في الأمر.
- لا يوزع الدفعة على عدة كتل بلا حاجة.

## 4. ممنوع Nested Markdown Fences

داخل Command Block لا تستخدم Triple Backticks أخرى.

السبب:

في تجارب سابقة كسرت Backticks الداخلية كتلة الأمر
الظاهرة وأصبحت عملية النسخ غير آمنة.

إذا احتاج الأمر إنشاء Markdown يحتوي أمثلة Code:

- استخدم Indented Code.
- أو نصًا بلا Triple Fence.

## 5. ممنوع Base64 افتراضيًا

لا تستخدم Base64 لتسليم أوامر طويلة لمجرد اختصارها.

السبب:

تجربة سابقة جعلت الطرفية تغلق أو جعلت الناتج غير سهل
للفحص والنسخ.

الأصل هو Command مقروء.

Base64 لا يستخدم إلا إذا كان هناك سبب تقني حقيقي
ولا يوجد بديل آمن ومقروء.

## 6. Shell Safety

النمط القياسي:

    cd ~/pr/well-irrigation

    (
    set -e
    set -o pipefail

    ...
    )

`set -e` يكون داخل Subshell فقط.

لا يستخدم Top-Level `set -e` في جلسة المستخدم.

السبب:

إذا فشل أمر داخل Subshell تنتهي الدفعة فقط، ولا تتغير
إعدادات Shell الأصلية للمستخدم.

## 7. Full Command Guard

دفعة مهمة تبدأ عادة بفحص:

- Expected HEAD.
- Current HEAD.
- Worktree state.

إذا كان الأمر يعتمد على Commit محدد:

    EXPECTED_HEAD=...

ويجب الإيقاف إذا تغير HEAD بدل تعديل ملفات غير متوقعة.

## 8. Worktree Guard

قبل دفعة كتابة جديدة:

- يجب أن يكون Worktree نظيفًا غالبًا.
- إذا لم يكن نظيفًا، لا تفترض أن التغييرات غير مهمة.
- اعرض الملفات وتوقف.

الاستثناء:

Recovery Command مصمم أصلًا لمتابعة تغييرات موجودة.

## 9. ترتيب دفعة التوثيق القياسية

التسلسل المفضل:

1. Guards.
2. Write/update.
3. `git diff --check`.
4. Expected changed files check.
5. Content/contract check.
6. `git add`.
7. `git diff --cached --check`.
8. Diff stat.
9. Commit.
10. Push.
11. Final worktree check.
12. Final markers.

## 10. Content Checks

فحوص النص يجب أن تكون Robust.

لا تبحث عن جملة طويلة قد تنكسر بسبب Line Wrap إذا لم
تكن بحاجة لذلك.

عند فحص نص متعدد الأسطر:

- يمكن Normalization للـWhitespace.
- أو البحث عن عدة Markers قصيرة مستقلة.

السبب:

حدث فشلان سابقان لأن الفحص كان يبحث عن عبارة صحيحة
لكنها مقسومة على سطرين.

## 11. Unicode وArabic

أوامر كتابة الملفات العربية يجب أن تكون UTF-8.

النمط المقبول حاليًا:

    python3 <<'PY'

مع:

    read_text(encoding="utf-8")
    write_text(..., encoding="utf-8")

يجب الحفاظ على Final Newline واحد.

## 12. Heredoc

Heredoc طويل يستخدم بحذر.

سبق حدوث Paste Corruption في أمر عربي طويل.

لذلك:

- حافظ على الأمر مقروءًا.
- استخدم Delimiter واضحًا ومقتبسًا.
- لا تجعل Shell يوسع المتغيرات داخل محتوى الوثيقة.
- بعد الكتابة افحص المحتوى قبل Commit.

## 13. لا تعاد الدفعة كاملة عند فشل متأخر

إذا نجحت:

    WRITE
    FORMAT CHECK
    FILE CHECK

ثم فشل:

    CONTENT CHECK

فلا تعاد الكتابة تلقائيًا.

بدل ذلك:

- افحص الحالة.
- أصلح الفحص.
- ابدأ Recovery من المرحلة المناسبة.

## 14. Recovery Matrix

### فشل قبل أي كتابة

يمكن إعادة الدفعة الأصلية بعد إصلاح السبب.

### نجحت الكتابة وفشل Validation

لا تعد الكتابة.

نفذ:

- Verify existing files.
- Fix validation if needed.
- Stage.
- Commit.
- Push.

### نجح Commit وفشل Push

لا تنشئ Commit جديدًا.

نفذ Push للـCommit نفسه.

### نجح Push وفشل Final Worktree Check

لا تعيد Push.

افحص الملفات المحلية الجديدة وحدها.

## 15. لا Success قبل آخر خطوة

لا يوصف العمل بأنه مغلق إذا وصل فقط إلى:

    DOCUMENT_WRITE=PASS

الإغلاق يحتاج حسب الدفعة:

- Commit.
- Push.
- Worktree clean.

## 16. Final Markers

يجوز للأمر أن ينتهي بعلامات واضحة مثل:

    Q95_WORKING_PROTOCOL=ADOPTED_AND_DOCUMENTED
    WORKTREE_CLEAN=PASS
    NEXT=UX13...

هذه Markers تسهل قراءة Output.

لكن Marker لا يتغلب على خطأ سابق في الأمر.

## 17. Git Commit

Commit Message يكون:

- قصيرًا.
- وصفيًا.
- يمثل الدفعة.

أمثلة:

    docs: adopt session settlement ux
    docs: establish ai handoff protocol

لا تضع تفاصيل كثيرة في عنوان Commit.

## 18. Git Push

بعد Commit ناجح:

    git push origin main

ثم يجب فحص Worktree.

لا تعتبر Local Commit وحدها حفظًا نهائيًا للمشروع
عندما كانت الدفعة تستهدف `main`.

## 19. الأوامر الخطرة

أي أمر:

- يحذف بيانات.
- يعيد قاعدة البيانات.
- يحذف ملفات.
- يعمل Force.
- يعدل تاريخ Git.

يحتاج تفسيرًا واضحًا ومبررًا أقوى.

لا يستخدم لمجرد الراحة.

## 20. اختبارات المشروع

النموذج لا يشغل Project Tests حسب قاعدة المشروع الحالية.

خاصة:

- `db:test`
- `db:reset`
- Docker verification

عند الحاجة يعطي المالك Block تحقق منفصلًا.

## 21. التعامل مع Output المستخدم

بعد استلام Output:

- اقرأ من البداية حتى أول Failure حقيقي.
- حدد ما تم قبل الفشل.
- لا تعتبر أوامر بعد Failure منفذة.
- استخدم Prompt Git كقرينة إضافية لحالة Worktree.
- إذا كان Output طويلًا، اقرأ الملف المرفوع كاملًا عند الحاجة.

## 22. تقليل طول الأوامر

الأمر يجب أن يكون أصغر ما يمكن **دون التضحية بالأمان**.

لا نكرر:

- ملفات لم تتغير.
- Validation غير ضروري.
- كتابة نفذت بالفعل.

لكن لا نحذف Guards الأساسية لمجرد تقليل الأسطر.

## 23. درس حوادث الطرفية السابقة

الحوادث المعروفة:

1. Heredoc عربي طويل تعرض لتشوه Paste مرة.
2. Base64 أدى إلى تجربة سيئة وأغلق الطرفية.
3. Triple Backticks داخل Command كسرت كتلة النسخ.
4. فحص Exact Phrase فشل بسبب Line Wrap مرتين.

القواعد الحالية وُضعت لمنع تكرار هذه الحوادث.

## 24. Definition of Done للأمر

دفعة Git Documentation تعتبر ناجحة عندما يظهر دليل على:

- write/update success.
- format check success.
- expected files success.
- contract/content success.
- staged check success.
- commit success.
- push success.
- clean worktree.

عند غياب واحدة منها، يحدد النموذج الحالة بدقة بدل
افتراض الإغلاق.
