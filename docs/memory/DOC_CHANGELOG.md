# سجل تغييرات الوثائق

**آخر تحديث:** 2026-08-21

يُوثّق هنا كل تغيير يطرأ على الوثائق المرجعية، حتى يُعرف لماذا اختلف النص عن الأصل.

---

## الإصدار 1.0 — الأصل الموروث

**المصدر:** ملفان نصيان قدّمهما المالك.

* وثيقة تأسيس تطبيق البئر — 11,710 سطرًا، 249,325 حرفًا. تحتوي أربع وثائق مدمجة.
* تقرير نقل السياق — 2,785 سطرًا، 66,780 حرفًا، 37 قسمًا.

**الحالة:** محفوظ كمرجع تاريخي. **لا يُستشهد به في البناء.**

---

## الإصدار 2.0 — 2026-08-12

### أولًا: التفكيك — ق-31

فُصل الملف الأول إلى أربع وثائق مستقلة بحدود متحقق منها سطرًا بسطر:

* الأسطر 1–2474 إلى `reference/01_functional_reference.md`.
* الأسطر 2475–5612 إلى `reference/02_database_and_finance_design.md`.
* الأسطر 5613–9389 إلى `reference/03_implementation_schema.md`.
* الأسطر 9390–11710 إلى `reference/04_erd_and_data_dictionary.md`.

**التحقق:** مجموع الأسطر بعد التفكيك يساوي الأصل زائدًا أسطر الترويسات المضافة.

### ثانيًا: التعديلات الجراحية الثمانية

كلها تطبيق مباشر لقرارات موثّقة، وكلها أعادت حالة نجاح:

1. القسمان 17.3 و17.4 في الوثيقة 2 — إلغاء التقريب، وإحلال الاحتساب بالثواني مع مثال 93 دقيقة. ق-01، ق-12، ق-13.
2. القسم 18.6 في الوثيقة 2 — إعادة كتابة كاملة على أساس جزء من ألف والرصيد المُرحَّل. ق-14، ق-15.
3. `core.well_settings` في الوثيقة 3 — حذف ثلاثة حقول تقريب، وإضافة `long_session_alert_minutes` و`session_ending_alert_minutes`. ق-12، ق-34، ق-40.
4. القسم 23 في الوثيقة 3 — حذف `ops.ceil_to_quarter_hour` وإحلال `ops.time_charge_milli`. ق-12، ق-14.
5. الوثيقة 3 — حذف `minimum_billable_minutes`. ق-16.
6. القسم 12.4 في الوثيقة 1 — قاعدة 100% الحتمية وتوثيق ت-01. ق-03، ق-21، ق-22.
7. القسم 15.6 في الوثيقة 1 — أربعة أقسام فرعية جديدة لحسم يوم الجلسة. ق-27، ق-37 إلى ق-40.
8. القسم 16 في الوثيقة 1 — الإشعارات الخمسة المعتمدة. ق-34، ق-35، ق-36.

### ثالثًا: ترويسات التحذير

أُضيفت ترويسة في رأس كل وثيقة من الأربع، تذكر أن الوثيقة مُعدّلة وتلخّص الملغى والمضاف، وتحيل إلى `DECISIONS.md` عند أي تعارض.

### رابعًا: تصحيح أرقام القرارات

طُبّقت 13 تصحيحًا لمراجع داخلية كانت تشير إلى أرقام قرارات خاطئة، كلها بمطابقة واحدة دقيقة.

**السبب:** أثناء التعديل كانت أرقام الجولة الثالثة لمّا تُثبَّت بعد، فاختلف الترقيم المؤقت عن النهائي.

---

## قاعدة التحديث من الآن فصاعدًا

أي تعديل لاحق على وثيقة مرجعية يُكتب هنا بـ: التاريخ · الملف · القسم · ما تغيّر · رقم القرار المبرر.
تعديل بلا رقم قرار = مخالفة.

---

## 2026-08-12 — إضافة المجلد القانوني

**الملفات الجديدة:**

* `legal/terms_and_privacy_v1_original.pdf` — النص الرسمي كما أرسله المالك. المبرر: ق-49.
* `legal/LEGAL_REVIEW.md` — مراجعة النص مقابل القرارات ومتطلبات المتجر. المبرر: ق-49.
* `INSTALL_INTO_PROJECT.md` — طريقة نقل مجلد الوثائق إلى جهاز المالك. المبرر: ق-42.

**الملفات المُعدّلة:**

* `memory/DECISIONS.md` — أُضيف ق-48 وق-49، وحُدّث قسم الترقيم التالي.
* `memory/REMINDERS.md` — حُدّثت حالة ت-03، وأُضيف ت-05.
* `memory/OPEN_ISSUES.md` — أُغلقت م-01 كمسألة إفصاح، وأُضيفت م-08 إلى م-12.
* `README.md` و`PROJECT_MAP.md` و`memory/RESUME_POINT.md` — أُضيف المجلد القانوني وحُدّث عدد القرارات إلى 49.

**ما لم يتغير:** الوثائق المرجعية الأربع في `reference/` لم تُمس في هذه الدفعة.

## تحديث 2026-08-13
**التاريخ:** 2026-08-13
**الملف:** DECISIONS.md, REMINDERS.md, OPEN_ISSUES.md, PROGRESS.md, RESUME_POINT.md, ENVIRONMENT.md
**القسم:** اغلاق المرحلة صفر، بيئة التطوير و GitHub
**ما تغير:** اضافة القرارات ق-50 الى ق-56، تحديث حالة ت-08، اغلاق م-02 و م-03، اضافة م-14، تحديث نقطة الاستئناف وسجل التقدم، تصحيح مسار قديم في ENVIRONMENT.md.
**رقم القرار المبرر:** ق-42.

## تحديث 2026-08-13 (الدفعة الثانية) — مرحلة قاعدة البيانات الكاملة
**التاريخ:** 2026-08-13
**الملف:** DECISIONS.md، REMINDERS.md، OPEN_ISSUES.md، PROGRESS.md، RESUME_POINT.md، technical/MIGRATIONS.md
**القسم:** إغلاق مرحلة قاعدة البيانات الكاملة (25 هجرة) وتوثيق دورة حياة التوزيع المالي
**ما تغيّر:** إضافة القرارات ق-57 إلى ق-66، تحديث حالة ت-01 وإضافة ت-09، إغلاق م-04 وإضافة م-15 وم-16، إعادة كتابة `technical/MIGRATIONS.md` بالكامل، تحديث `PROGRESS.md` و`RESUME_POINT.md` بالأدلة الفعلية.
**رقم القرار المبرر:** ق-42.

## تحديث 2026-08-13 (الدفعة الثالثة) — إغلاق ت-01 نهائيًا
**التاريخ:** 2026-08-13
**الملف:** DECISIONS.md، REMINDERS.md
**القسم:** التأكيد النهائي على آلية أكبر الباقي بمثال حي من بئر حقيقي
**ما تغيّر:** إضافة ق-67 بالرد الحرفي للمالك، تحديث حالتي ت-01 وت-09 إلى منفّذ ومغلق.
**رقم القرار المبرر:** ق-67.

## تحديث 2026-08-13 (الدفعة الرابعة) — تسجيل فجوة النطاق المعتمد م-17
**التاريخ:** 2026-08-13
**الملف:** OPEN_ISSUES.md
**ما تغيّر:** إضافة م-17 موثّقة بمقارنة دقيقة بين قسم 55 (النطاق المعتمد) وقسم 56/60 (المؤجل رسميًا) في الوثائق المرجعية، مقابل ما بُني فعليًا في 25 هجرة. حُصرت 17 بندًا معتمدًا غير مبني، وميّزت عمّا هو مؤجل رسميًا فلا يُعامل كفجوة.
**رقم المسألة المرجعي:** م-17.

## تحديث 2026-08-13 (الدفعة الثالثة) — إغلاق المرحلة 1 (النواة)
**التاريخ:** 2026-08-13
**الملف:** DECISIONS.md، OPEN_ISSUES.md، PROGRESS.md، RESUME_POINT.md، technical/MIGRATIONS.md
**القسم:** إغلاق المرحلة 1 من ترتيب البناء الموثّق (persons/roles/permissions/locations)
**ما تغيّر:** إضافة ق-68، تحديث م-17، فتح م-18 (فجوة ربط كتالوج الأدوار)، تحديث PROGRESS/RESUME_POINT، إضافة سجل الهجرات 026-028 في MIGRATIONS.md.
**رقم القرار المبرر:** ق-42.

## تحديث 2026-08-13 (الدفعة الخامسة) — إغلاق المرحلة 2 (التشغيل)
**التاريخ:** 2026-08-13
**الملف:** DECISIONS.md، OPEN_ISSUES.md، PROGRESS.md، RESUME_POINT.md، technical/MIGRATIONS.md
**القسم:** إغلاق المرحلة 2 من ترتيب البناء الموثّق (water_lines/farmer_profiles/price_schedules/irrigation_bookings/resource_reservations/session_segments)
**ما تغيّر:** إضافة ق-69، تحديث م-17، فتح م-19 (فجوة مخطط core.pumps)، تحديث PROGRESS/RESUME_POINT، إضافة سجل الهجرات 029-034 في MIGRATIONS.md.
**رقم القرار المبرر:** ق-42.

## تحديث 2026-08-13 (الدفعة السادسة) — إغلاق المرحلة 3 (المال)
**التاريخ:** 2026-08-13
**الملف:** DECISIONS.md، OPEN_ISSUES.md، PROGRESS.md، RESUME_POINT.md، technical/MIGRATIONS.md
**القسم:** إغلاق المرحلة 3 من ترتيب البناء الموثّق (ledger_accounts/journal_entries/journal_lines/invoices/invoice_lines/payment_allocations)
**ما تغيّر:** إضافة ق-70، تحديث م-17، فتح م-20 (تباعد مخطط billing.payments عن §28)، تحديث PROGRESS/RESUME_POINT، إضافة سجل الهجرات 035-038 في MIGRATIONS.md.
**رقم القرار المبرر:** ق-42.

## 2026-08-13 — إقفال المرحلة 4
- DECISIONS.md: اضافة ق-71 و ق-72.
- OPEN_ISSUES.md: اقفال م-20.
- PROGRESS.md: تسجيل المرحلة 4 بدفعاتها الثلاث.
- RESUME_POINT.md: اعادة كتابة كاملة (46 هجرة، 49 جدولا، خطة المرحلة 5).
- MIGRATIONS.md: الصفوف 039 الى 046.

## تحديث 2026-08-14 — اعتماد قرارات المرحلة 5 (ق-73)
**التاريخ:** 2026-08-14
**الملف:** DECISIONS.md، DOC_CHANGELOG.md
**القسم:** قرارات المرحلة 5 (الشركاء والفترات المحاسبية والمدير العام)
**ما تغيّر:** إضافة ق-73 معتمدًا من المالك قبل كتابة أي هجرة: توحيد مصدر النِّسب في جدول الشركاء، إلزامية اكتمال 100%، سياسة سقي الشريك بقيمتين فقط (دفع عادي أو خصم من الأرباح)، دورا «مدير» و«شريك»، علم المدير العام للتطبيق، الفترات الشهرية والسنوية، تنفيذ الخطوة 5 المؤجلة، الإقفال بلا تصويت، إعادة الفتح بموافقة 70% من عدد الشركاء ثم المدير العام، والربط المؤجل للعمودين.
**رقم القرار المبرر:** ق-73.

## تحديث 2026-08-14 — إقفال المرحلة 5 (الشركاء)
**التاريخ:** 2026-08-14
**الملف:** DECISIONS.md، PROGRESS.md، RESUME_POINT.md، technical/MIGRATIONS.md، DOC_CHANGELOG.md
**القسم:** إقفال المرحلة 5 من ترتيب البناء الموثّق (well_partners / partner_irrigation_policies / accounting_periods / دورة إعادة الفتح / صلاحيات المدير والشريك)
**ما تغيّر:** تحويل ق-73 إلى «نافذ ومنفذ» مع نتائج التحقق البنيوي والوظيفي (23/23)، تسجيل الهجرات 039–046 و047–050 في السجل التاريخي docs/technical/MIGRATIONS.md وحذف الملف المكرر في docs/memory/، تحديث PROGRESS وRESUME_POINT بخطة المرحلة 6.
**رقم القرار المبرر:** ق-73.

## تحديث 2026-08-14 (الدفعة الثانية) — اعتماد قرارات المرحلة 6 (ق-74)
**التاريخ:** 2026-08-14
**الملف:** DECISIONS.md، DOC_CHANGELOG.md
**القسم:** قرارات المرحلة 6 (الإدارة)
**ما تغيّر:** إضافة ق-74 بعشرة بنود معتمدة من إجابات المالك: تبنّي إصدارات نسب الشريك من المرجع، استبدال جداول التوزيع بجداول الدورات الكاملة، الالتزامات المحتجزة بمفتاح تشغيل/تعطيل، احتياطي الصيانة بخمسة أنواع، اعتماد الأرصدة الافتتاحية للمالك، بناء الرواتب، قيود الديزل التلقائية، آلية خصم الشريك، إجراء §49، وترتيب التنفيذ بثلاث دفعات.
**رقم القرار المبرر:** ق-74.

## تحديث 2026-08-14 (الدفعة الثالثة) — إقفال المرحلة 6 ومحطة قاعدة البيانات
**التاريخ:** 2026-08-14
**الملف:** DECISIONS.md، PROGRESS.md، RESUME_POINT.md، technical/MIGRATIONS.md، DOC_CHANGELOG.md
**القسم:** إقفال المرحلة 6 (الإدارة) واكتمال مراحل قاعدة البيانات الست
**ما تغيّر:** تحويل ق-74 إلى «نافذ ومنفذ» مع نتائج التحقق (19/19 و17/17) وتوثيق الأعطال الثلاثة المكتشفة والمصححة أثناء التنفيذ، تسجيل الهجرات 051–056 في السجل التاريخي، تحديث PROGRESS وإعادة كتابة RESUME_POINT لتعكس اكتمال محطة قاعدة البيانات وبدء محطة تطبيق Flutter.
**رقم القرار المبرر:** ق-74.

## تحديث 2026-08-14 (الدفعة الرابعة) — اعتماد ق-75 (الدفعة الختامية لقاعدة البيانات)
**التاريخ:** 2026-08-14
**الملف:** DECISIONS.md، DOC_CHANGELOG.md
**القسم:** الدفعة الختامية بعد المطابقة الحرفية مع المرجعين
**ما تغيّر:** إضافة ق-75: بناء سجل التدقيق وطبقة المزامنة والمرفقات وعروض التقارير واستكمال الإجراءات الآن، قبول الدفع الزائد وتحويله لرصيد مقدم، الإبقاء على منع المخزون السالب كانحراف موثق، فرض فاتورة واحدة لكل جلسة، وتأجيلات موثقة داخل النطاق (الأجهزة، outbox، PowerSync).
**رقم القرار المبرر:** ق-75.

## 2026-08-14 — إقفال محطة قواعد البيانات
- DECISIONS: ق-75 → نافذ ومنفذ مع نص التحقق (17/17).
- MIGRATIONS (technical): صفوف 057–061 بحالة التطبيق.
- PROGRESS: الدفعة الختامية واكتمال المحطة.
- RESUME_POINT: إعادة كتابة كاملة — الوضع الحالي وخارطة المرحلة 7 والمؤجلات.
- OPEN_ISSUES: إغلاق م-17 بتقييم ختامي، وفتح م-21 للاختبارات الميدانية.

## 2026-08-14 — ق-76: سد فجوات التدقيق الشامل
- DECISIONS: إضافة ق-76 (دمج الأشخاص + قفل المضخة + تأجيلات موثقة + ملاحظة ترقيم ق-71)؛ تصحيح حالة ق-51 إلى نافذ ومنفذ؛ إحالة ق-63 إلى محرك التوزيع الجديد؛ توحيد تنسيق ق-72.
- OPEN_ISSUES: عنوان م-17 إلى مغلقة.

## 2026-08-14 — إقفال ق-76 (نافذ ومنفذ)
- DECISIONS: ق-76 → نافذ ومنفذ مع نص التحقق (13/13).
- MIGRATIONS (technical): صفوف 062–063 بحالة التطبيق.
- PROGRESS: سد فجوات التدقيق الشامل.
- RESUME_POINT: إعادة كتابة — 63 هجرة و66 جدولًا، توجيهات المرحلة 7 (Flutter) بما فيها استدعاء كاشف التكرار.

## 2026-08-14 — ق-77: حسم تعارضات تدقيق Codex
- DECISIONS: إعادة بناء ق-71 المفقود (وحدة المال = الريال الكامل)؛ ملاحظات نسخ على ق-14 وق-15 وق-21 وق-48 وق-67؛ حسم ق-18 وق-69 (مصدر التسعير)؛ إضافة ق-77.
- OPEN_ISSUES: ملاحظة م-13؛ تصحيح نص إغلاق م-17 (بعد تدقيق Codex) ونص م-20 (قيم الغرض الفعلية).
- technical: حفظ تقرير التدقيق المستقل CONFORMANCE_AUDIT_CODEX.md كوثيقة مشروع.

## 2026-08-14 — تحقق 064-065
- DECISIONS: ق-77 محدثة بالتحقق الجزئي (قناتان مستقلتان).
- MIGRATIONS/PROGRESS: صفوف 064-065.

## 2026-08-15 — تحقق 066
- DECISIONS: ق-77 محدثة (البند 3 منفذ) مع نص التحقق والتسويات الواعية.
- MIGRATIONS/PROGRESS: صف 066 ونتائجه.

## 2026-08-15 — ختام ق-77
- DECISIONS: ق-77 «نافذ ومنفذ بالكامل» مع نص تحقق 067 وتصحيح توقع فحص الشريك.
- INVARIANTS/GLOSSARY: ملحق توحيد وحدة المال (نسخ milli نهائيا).
- MIGRATIONS/PROGRESS/RESUME_POINT: صف 067 وختام المحطة وقاعدة عمل الوكيل الجديدة.

## 2026-08-15 — ت-11 مغلق
- RESUME_POINT: قرار بناء الاجراءات المتبقية الان على دفعتين 068 و069.

## 2026-08-15 — تحقق 068
- MIGRATIONS/PROGRESS: صف 068 ونتائجه (107 فحصا PASS بقناتين).

## 2026-08-15 — تحقق 069 واغلاق ت-11
- MIGRATIONS/PROGRESS: صف 069 ونتائجه (129 فحصا PASS بقناتين).
- OPEN_ISSUES: فتح م-22 (مالك الأرض مرتبط بملف الدخول).
- RESUME_POINT: ت-11 منجز بالكامل والباب التالي المرحلة 7.

## 2026-08-15 — قرار م-23
- OPEN_ISSUES: قيد م-23 بقراره ومواعيد اقفاله الثلاثة (منطق الليلة، ظهور في المرحلة 7، تفعيل عند النشر).
- RESUME_POINT: سجل القرار.

## 2026-08-15 — تحقق 070 وختام م-23 برمجيا
- MIGRATIONS/PROGRESS: صف 070 ونتائجه (138 فحصا PASS بقناتين).
- OPEN_ISSUES: م-08 — المنطق منفذ؛ العلامتان الباقيتان موثقتان (المرحلة 7 + بند النشر).
- RESUME_POINT: اكتمال محطة القاعدة.

## 2026-08-15 — تصحيح وجهة ملحق وحدة المال
- اكتشف مسح التوثيق ان ملحق ق-77 كُتب في ملفي reference الفارغين؛ نُسخ الان الى technical/INVARIANTS.md و technical/GLOSSARY.md حيث يعيش نص milli الفعلي — زال التناقض من موضعه الصحيح.

## 2026-08-15 — تصحيح تعارض ترقيم
- مرسلا التنبيهات الدوريين اعيد ترقيمهما من م-08 الى م-23 (م-08 محجوزة اصلا لبند قانوني في ت-03). عولجت السجلات الحية؛ تعليقات هجرة 070 تبقى كما هي (هجرات مطبقة لا تعدل).

## 2026-08-16 — اعتماد ق-78 وحد Data API

- `DECISIONS.md`: إضافة ق-78 مع السياق والأسباب والحد المعماري وشروط الإغلاق.
- `technical/INVARIANTS.md`: إضافة قواعد ثابتة لحد Data API ومبدأ Opt-in.
- `PROJECT_MAP.md`: تحديد مصدر الحقيقة لعقد Flutter مع قاعدة البيانات.
- `supabase/migrations/071`: إعداد التنفيذ الفني للحد.
- `supabase/tests/071`: إضافة اختبار قبول دائم لمنح مخطط api وDefault Privileges.
- `supabase/config.toml`: إعداد api كمخطط التطبيق المكشوف بدل الاعتماد على public.
- لا يسجل التنفيذ «مكتملًا» في PROGRESS قبل تشغيل التحقق الفعلي بواسطة المالك.
- المبرر: ق-78.

## 2026-08-16 — تصحيح فرضية Default Privileges في ق-78

كشف اختبار القبول 071 أن PostgreSQL يمنح EXECUTE على الدوال الجديدة إلى PUBLIC افتراضيًا، وأن REVOKE المحدود بمخطط عبر ALTER DEFAULT PRIVILEGES لا يستطيع إلغاء المنح العالمي الافتراضي للدوال. لم تُعدّل الهجرة 071 بعد تطبيقها التزامًا بقاعدة عدم تعديل الهجرات المطبقة. صُحح ق-78 وINVARIANTS ليعتمدا النمط الصحيح: CREATE FUNCTION ثم REVOKE ثم GRANT الصريح داخل المعاملة نفسها، مع اختبار دائم يفشل إذا أصبحت أي دالة داخل api قابلة للتنفيذ من anon.

## 2026-08-16 — إغلاق ق-78

- DECISIONS: ق-78 إلى نافذ ومنفذ ومغلق مع دليل إعادة البناء والاختبارات وPostgREST.
- INVARIANTS: تصحيح قاعدة دوال api لتطابق Default Privileges الفعلية في PostgreSQL.
- PROJECT_MAP: تثبيت api كعقد Flutter مع قاعدة البيانات.
- README: تحديث مرجع القرارات حتى ق-78.
- ENVIRONMENT: تسجيل Exposed Schemas الفعلية بعد ق-78.
- MIGRATIONS: تسجيل 071 وحالة 70 هجرة / 11 اختبار / 145 PASS.
- PROGRESS وRESUME_POINT: إغلاق الشرط الأول API Architecture وتثبيت نقطة الاستئناف.
- config.toml: api وgraphql_public فقط ضمن Exposed Schemas.
- لم تُعدّل الهجرة 071 بعد تطبيقها؛ التصحيح الناتج عن اختبار Default Privileges تم في القواعد والاختبار الدائم وفق قاعدة عدم تعديل الهجرات المطبقة.

## 2026-08-16 — اعتماد ق-79 وإعداد الهجرة 072

- `DECISIONS.md`: إضافة ق-79 الخاص بـ RPC-only writes.
- `technical/INVARIANTS.md`: منع Direct DML على مخططات الأعمال الداخلية.
- `OPEN_ISSUES.md`: إضافة م-24 حتى اكتمال التحقق.
- `RESUME_POINT.md`: تثبيت أن 072 قيد التحقق.
- `supabase/migrations/072`: سحب الكتابة المباشرة من أدوار تطبيق العميل.
- `supabase/tests/072`: اختبار دائم للمنع واستمرار إجراءات الأعمال.
- لا يسجل ق-79 كمنجز في `PROGRESS.md` قبل إثبات المالك.

## 2026-08-16 — إثبات الهجرة 072

- ثبتت إعادة البناء النظيفة مع 072.
- ثبت Direct DML = صفر لأدوار تطبيق العميل.
- ثبت استمرار EXECUTE لإجراءات الأعمال الحرجة.
- ثبت عدم وجود SECURITY DEFINER قابلة للتنفيذ بلا search_path.
- أصبح baseline: 71 هجرة، 12 اختبارًا دائمًا، 154 PASS.
- عدل اختبارا 066 و069 لفصل Fixtures الإدارية عن مسارات المستخدم بعد ق-79.
- لم يغلق ق-79 كاملًا؛ أغلفة api الكتابية هي العمل التالي.

## 2026-08-16 — إعداد 073 لعقد الكتابة

- إضافة 15 غلاف كتابة SECURITY INVOKER داخل api.
- عدم تكرار منطق الأعمال داخل api.
- إزالة معاملات هوية المنفذ من عقد Flutter واستخدام auth.uid().
- إبقاء create_farm خارج العقد بسبب م-22.
- إضافة اختبار دائم لسطح api والمنح وDirect DML وتشغيل api.create_farmer فعليًا.
- التنفيذ ما زال قيد تحقق المالك.

## 2026-08-16 — إعداد 074

- إضافة عقد api لإنشاء البئر.
- إضافة المصروفات والاعتماد.
- إضافة المناوبات والتسليم ونقل الجلسة.
- إضافة الإقفال وتوزيع الأرباح والرواتب الأساسية.
- منع إرسال معرف المنفذ من Flutter في هذه التدفقات.
- إبقاء create_farm خارج العقد بسبب م-22.

## 2026-08-17 — إغلاق ق-79 والشرط الثاني

- تصحيح اختبار 073 ليبقى مختصًا بعقد 073 ولا يعتمد على الهجرات اللاحقة.
- ثبتت 074 مع كامل الحزمة.
- baseline: 73 هجرة / 14 اختبارًا / 178 PASS.
- Direct DML = صفر.
- Data API = 31 RPC.
- تصنيف الدوال المتبقية: 14 داخلية / 9 مؤجلة / 0 غير مصنفة.
- أُغلق م-24.

## 2026-08-17 — مصالحة توثيقية شاملة للشرط 3

- إعادة بناء PROJECT_MAP ليعكس ترتيب السلطة الحالي.
- إعادة بناء RESUME_POINT كحالة حالية فقط بدل تراكم snapshots قديمة.
- إنشاء API_ARCHITECTURE.md.
- إنشاء SYNC_ARCHITECTURE.md.
- إنشاء DECISION_IMPLEMENTATION_MATRIX.md.
- تصحيح INVARIANTS وGLOSSARY إلى الريال الكامل وقاعدة الباقي الحالية.
- تصحيح النصوص المرجعية النشطة المتعلقة بالتقريب ووحدة المال.
- تمييز CONFORMANCE_AUDIT_CODEX بوضوح كـsnapshot تاريخي.
- توحيد حالة البيئة وFlutter وSupabase والـbaseline.
- إضافة فهرس حالة حالية للمسائل المفتوحة وإغلاق م-15 توثيقيًا.
- الفصل بين Server Sync المنفذ وMobile Offline Sync المؤجل.
- الحالة: التعديلات مكتوبة؛ بانتظار التحقق الساكن للمالك قبل إغلاق الشرط 3.

## 2026-08-17 — إغلاق الشرط 3 رسميًا

- Documentation Acceptance = PASS.
- Cross-sync = PASS.
- لا أخطاء static diff.
- أُغلق Documentation Conformance رسميًا.
- PROJECT_MAP وRESUME_POINT انتقلا إلى الشرط 4.
- الخطوة التالية: م-22 قبل شاشة الأراضي.

## 2026-08-17 — إعداد ق-80 / 075

- إضافة ق-80.
- م-22 انتقلت من انتظار القرار إلى التنفيذ قيد التحقق.
- إعداد Migration/Test 075.
- baseline المثبت لم يتغير بعد:
  73 migration مطبقة / 14 tests / 178 PASS / 31 RPC.

## 2026-08-17 — إغلاق ق-80 وم-22

- ق-80 أصبحت نافذة ومنفذة ومغلقة.
- 075 أصبحت migration مطبقة ومثبتة.
- baseline الرسمي أصبح:
  74 migrations / 15 tests / 193 PASS / 32 RPC.
- وثائق Farm identity انتقلت إلى Farmer Well Account.
- نقطة الاستئناف انتقلت إلى م-19.

## 2026-08-17 — إغلاق ق-81 وم-19 والشرط 4

- ق-81 أصبحت نافذة ومنفذة ومغلقة.
- Migration 076 أصبحت مطبقة ومثبتة.
- م-19 مغلقة.
- Condition 4 مغلق.
- baseline الرسمي:
  75 migrations / 16 tests / 205 PASS / 32 RPC.
- نقطة الاستئناف انتقلت إلى Condition 5.

## 2026-08-17 — Final Clean Acceptance / Stage 7 gate

- إغلاق Condition 5.
- إغلاق Stage 7 Readiness Gate.
- baseline النهائي:
  75 migrations / 16 tests / 205 PASS / 32 RPC.
- لا توجد FAIL أو ERROR.
- Direct DML بقي صفرًا.
- نقطة الاستئناف انتقلت إلى بدء Stage 7 implementation.


## تحديث 2026-08-17 — ق-82

**الملفات:** DECISIONS.md، INVARIANTS.md، PROGRESS.md،
RESUME_POINT.md، ENVIRONMENT.md، MIGRATIONS.md،
API_ARCHITECTURE.md، DECISION_IMPLEMENTATION_MATRIX.md.

**القسم:** Stage 7 App Bootstrap Read Contract.

**ما تغيّر:** توثيق Migration 077 وعقد `api.app_bootstrap()`،
وتحديث baseline المثبت إلى 76 migrations و17 اختبارًا دائمًا
و217 PASS و33 Data API RPC، وتثبيت بوابة الهوية البصرية
كخطوة تسبق بناء أي واجهة تشغيلية جديدة.

**القرار المبرر:** ق-82.


## تحديث 2026-08-17 — ق-83

**الملفات:** `design/VISUAL_IDENTITY.md`، DECISIONS.md،
PROGRESS.md، RESUME_POINT.md، README.md، PROJECT_MAP.md،
DECISION_IMPLEMENTATION_MATRIX.md.

**القسم:** الهوية البصرية العامة لـStage 7.

**ما تغيّر:** اعتماد وتوثيق الشعار المبدئي ونظام الألوان
والخط والأيقونات والأسطح والمسافات والصور والرسوم والحركة
ولغة الحالات وأيقونة التطبيق والوضع الداكن وAccessibility
وRTL والأرقام وقواعد استخدام الشعار وأصول الهوية.

**الحالة:** بوابة الهوية البصرية العامة مغلقة مبدئيًا.
لم يبدأ تنفيذ واجهات إنتاجية نتيجة هذا القرار.

**القرار المبرر:** ق-83.

## تحديث 2026-08-18 — Stage 7 UX وOffline والتسوية

**المجال:** توثيق UX-00 إلى UX-12 والقرارات حتى ق-92.

**ما تغير:**

- اعتماد وتوثيق هوية Stage 7.
- توثيق Splash/Login/Onboarding/Role routing/Home.
- توثيق Operations وSmart Lookup ومنع التكرار.
- توثيق Offline Field Operations وAndroid Background Sync.
- توثيق Device Readiness وSync Status.
- توثيق Active Irrigation Session.
- توثيق Session Completion & Settlement.
- إضافة معماريات تقنية منفصلة للبحث وOffline والجلسة
  الجارية والتسوية.
- فتح م-25 وم-26 وم-27 للفجوات التي لا يجوز نسيانها.
- إبقاء Migration 078+ كنقطة أول تغيير DB جديد.

**السبب:** القرارات ق-83 إلى ق-92 ومنهج
مناقشة → اعتماد → توثيق → انتقال.

**ملاحظة:** دفعات UX كانت توثيقية؛ لم تغير Baseline
اختبارات قاعدة البيانات المثبت سابقًا.

## تحديث 2026-08-18 — ق-93 وق-94

**الملفات الرئيسية:**

- `README.md`
- `PROJECT_MAP.md`
- `memory/AI_HANDOFF_PROTOCOL.md`
- `memory/DECISIONS.md`
- `memory/PROGRESS.md`
- `memory/DOC_CHANGELOG.md`
- `memory/RESUME_POINT.md`
- `design/UX_UI_SPEC.md`
- `technical/INVARIANTS.md`
- `technical/DECISION_IMPLEMENTATION_MATRIX.md`

**ما تغير:**

- إنشاء بروتوكول رسمي لتسليم المشروع لأي نموذج AI.
- إزالة Snapshot المتقادم من README وتحويله إلى مدخل ثابت.
- تحديث سجل التقدم إلى 2026-08-18.
- تسجيل الإنجازات التصميمية دون وصفها كتنفيذ.
- تثبيت أن RESUME_POINT هو نقطة التوقف الوحيدة.
- تثبيت Contract لتحديث ملفات الذاكرة في كل دفعة.
- دمج المناقشات المتبقية إلى UX-13..UX-17.

**السبب:** ق-93 وق-94.

## تحديث 2026-08-18 — ق-95 وق-96 / توثيق طريقة العمل

**السبب:** المالك طلب ألا يقتصر تسليم المشروع على
القرارات والملفات، بل يشمل طريقة التفكير القابلة
للمراجعة، العرض، أسلوب الحوار، وطريقة كتابة الأوامر.

**الملفات الجديدة:**

- `memory/AI_COLLABORATION_PROTOCOL.md`
- `memory/TERMINAL_COMMAND_PROTOCOL.md`

**الملفات المحدثة:**

- `README.md`
- `PROJECT_MAP.md`
- `memory/AI_HANDOFF_PROTOCOL.md`
- `memory/DECISIONS.md`
- `memory/PROGRESS.md`
- `memory/RESUME_POINT.md`
- `technical/INVARIANTS.md`
- `technical/DECISION_IMPLEMENTATION_MATRIX.md`
- `memory/DOC_CHANGELOG.md`

**ما تم تثبيته:**

- دور النموذج في المشروع.
- مستوى الشرح واللغة.
- منهج اتخاذ القرار.
- تسجيل الأسباب والأدلة.
- UX workflow.
- دلالة «اعتمد».
- الانتقال المباشر بعد الإغلاق.
- الفصل بين UX numbers وQ decisions.
- التعامل مع التعارضات والفجوات.
- التعامل مع مخرجات الطرفية.
- أسلوب كتابة الأوامر.
- Subshell و`set -e`.
- منع Base64 الافتراضي.
- منع Nested Code Fences.
- Recovery بعد الفشل.
- Lessons Learned من الحوادث السابقة.

**القرارات المبررة:** ق-95، ق-96.

## تحديث 2026-08-18 — ق-97 / بوابة اكتمال التوثيق

**السبب:** اشتراط ألا يضيع أي قرار أو سبب أو تحديث أو
سجل أو إنجاز أو Gap أو طريقة عمل عند تسليم المشروع
لنموذج ذكاء اصطناعي جديد.

**الملف الجديد:**

- `memory/DOCUMENTATION_GATE.md`

**الملفات المحدثة:**

- `README.md`
- `PROJECT_MAP.md`
- `memory/AI_HANDOFF_PROTOCOL.md`
- `memory/AI_COLLABORATION_PROTOCOL.md`
- `memory/TERMINAL_COMMAND_PROTOCOL.md`
- `memory/DECISIONS.md`
- `memory/PROGRESS.md`
- `memory/RESUME_POINT.md`
- `memory/DOC_CHANGELOG.md`
- `technical/INVARIANTS.md`
- `technical/DECISION_IMPLEMENTATION_MATRIX.md`

**ما تغير:**

- فرض Documentation Gate قبل الانتقال.
- فرض توثيق أسباب القرار المهمة.
- تحديد Checklist لكل نوع توثيق.
- فرض Traceability.
- إخضاع قواعد التوثيق نفسها لنفس البوابة.
- ربط Gate بإغلاق Git.

**القرار المبرر:** ق-97.

**نوع الدفعة:** توثيقية فقط؛ لا تغيير في Baseline
اختبارات قاعدة البيانات.

## تحديث 2026-08-18 — UX-13 / ق-98

**المجال:** التشغيل والسجلات والمزارعون والحجوزات والمناوبات.

**السبب:**

اعتماد UX-13 من القرار 373 إلى 407، مع الحاجة إلى حفظ
الأسباب والتعارضات الحالية وفق Documentation Gate ق-97.

**الملف الجديد:**

- `technical/OPERATIONS_RECORDS_ARCHITECTURE.md`

**الملفات المحدثة:**

- `design/UX_UI_SPEC.md`
- `memory/DECISIONS.md`
- `memory/OPEN_ISSUES.md`
- `memory/PROGRESS.md`
- `memory/RESUME_POINT.md`
- `PROJECT_MAP.md`
- `technical/API_ARCHITECTURE.md`
- `technical/SYNC_ARCHITECTURE.md`
- `technical/SEARCH_DEDUP_ARCHITECTURE.md`
- `technical/INVARIANTS.md`
- `technical/DECISION_IMPLEMENTATION_MATRIX.md`

**قرارات/قواعد مهمة موثقة:**

- حفظ التاريخ وعدم Hard Delete للسجلات المستخدمة.
- Booking Offline غير Confirmed حتى Backend.
- Backend يحسم Resource Conflict.
- Smart Lookup يعاد استخدامه.
- Transfer يحتاج قبول المستلم.
- Shift لا يغلق عاديًا مع Active Session غير محسومة.
- Cash Handover منفصل عن Operational Responsibility.
- تسجيل تعارض `p_allow_open_sessions` الحالي في م-28.

**القرار المبرر:** ق-98.

**نوع الدفعة:** توثيقية فقط؛ Baseline الاختبارات لم يتغير.

## تحديث 2026-08-18 — UX-14 / ق-99

**المجال:** المال والشركاء والتوزيعات والتصحيحات.

**السبب:**

اعتماد القرارات 408–459 مع ضرورة حفظ السياسات المالية
والفجوات الحالية بصورة يمكن تتبعها حسب ق-97.

**الملف الجديد:**

- `technical/MONEY_PARTNERS_ARCHITECTURE.md`

**الملفات المحدثة:**

- `design/UX_UI_SPEC.md`
- `memory/DECISIONS.md`
- `memory/OPEN_ISSUES.md`
- `memory/PROGRESS.md`
- `memory/RESUME_POINT.md`
- `PROJECT_MAP.md`
- `technical/API_ARCHITECTURE.md`
- `technical/SYNC_ARCHITECTURE.md`
- `technical/SESSION_SETTLEMENT_ARCHITECTURE.md`
- `technical/INVARIANTS.md`
- `technical/DECISION_IMPLEMENTATION_MATRIX.md`

**أهم ما ثبت:**

- Debt وAdvance منفصلان.
- No Silent Netting.
- Old Advance Allocation فعل صريح.
- Oldest invoices مجرد Default Suggestion.
- Receipt النهائي خادمي.
- Offline Payment ليست Posted قبل ACK.
- Attachment Skip Reason إلزامي عند التخطي.
- Ownership وProfit Percentage مستقلتان.
- Share History لا يعاد كتابتها.
- Calculation منفصل عن Approval.
- Approved Distribution مقفلة.
- Partner private financial projection مطلوبة.
- Final Financial Actions Online only.
- Corrections لا تستخدم Direct Edit.
- Rounding الحالي للاحتياطي يحتاج Audit.
- م-29 فتحت للفجوات التنفيذية.

**القرار المبرر:** ق-99.

**نوع الدفعة:** توثيقية فقط؛ Baseline الاختبارات لم يتغير.

## تحديث 2026-08-19 — UX-15 / ق-100

**المجال:** إدارة البئر والمضخات والطاقة والوقود والتسعير
والتقارير والرسوم البيانية.

**السبب:**

اعتماد القرارات 460–510، ثم طلب المالك دراسة وتوظيف
رسوم بيانية بسيطة تناسب النسخة الأولى وتحديد أماكنها،
فأضيفت القرارات 511–526.

**الملف الجديد:**

- `technical/WELL_MANAGEMENT_REPORTING_ARCHITECTURE.md`

**الملفات المحدثة:**

- `design/UX_UI_SPEC.md`
- `design/VISUAL_IDENTITY.md`
- `memory/DECISIONS.md`
- `memory/OPEN_ISSUES.md`
- `memory/PROGRESS.md`
- `memory/RESUME_POINT.md`
- `PROJECT_MAP.md`
- `technical/API_ARCHITECTURE.md`
- `technical/SYNC_ARCHITECTURE.md`
- `technical/INVARIANTS.md`
- `technical/DECISION_IMPLEMENTATION_MATRIX.md`

**أهم ما ثبت:**

- Pump = Equipment.
- Modern Energy = Session Segments.
- Well Fuel وFarmer Fuel منفصلان.
- Fuel ليس Farmer Surcharge.
- Pricing تاريخية.
- Diesel V1 = Inclusive Hourly.
- `operation_plus_fuel` لا يظهر في Flutter V1.
- Reports تعتمد Backend Read Models.
- V1 Charts = Bar + Line.
- لا Chart في Owner Home V1.
- Chart رئيسية واحدة في Reports.
- Fuel Mini Chart فقط في سياق الوقود.
- Partner Chart تعرض بيانات الشريك نفسه.
- Chart تسمح Exact Value وDrill-down.
- Offline Chart تعرض Last Sync.
- لا Fake Zero Chart.
- م-30 فتحت للفجوات التنفيذية.

**القرار المبرر:** ق-100.

**نوع الدفعة:** توثيقية فقط؛ Baseline الاختبارات لم يتغير.

## تحديث 2026-08-19 — UX-16A / ق-101

**المجال:** الحساب والإعدادات.

**التغيير الأساسي:**

فصل Platform Administration عن UX-16A بصورة رسمية.

**الملف الجديد:**

- `technical/ACCOUNT_SETTINGS_ARCHITECTURE.md`

**أهم القرارات:**

- Account موحد.
- Phone Change حساس.
- Forgot Password عبر OTP في V1.
- Role lifecycle لا يكرر الهوية.
- Platform Admin خارج UX-16A.
- Local State مرتبطة بالحساب.
- Logout لا يحذف Pending.
- Date/Time تظهر بالإنجليزية دائمًا.
- فتح م-31.

**نوع الدفعة:** توثيقية فقط.

## تحديث 2026-08-19 — PA-01 / ق-102

**المجال:** Platform Administration.

**السبب:**

تم تعريف مسؤول المنصة بأنه مدير المنتج العام وليس
مستخدم بئر، ثم اعتماد Dashboard مستقلة بإحصاءات رقمية
واسعة وتحديث تلقائي وقائمة جانبية ورسوم بسيطة.

**الملف الجديد:**

- `technical/PLATFORM_ADMINISTRATION_ARCHITECTURE.md`

**أهم القرارات:**

- Platform Admin مستقل عن Well Roles.
- Global Administration Authority.
- Admin Console مستقلة.
- Web/Desktop-first.
- RTL Sidebar يمين.
- Numeric KPIs أولًا.
- Near-real-time refresh.
- Bar/Line charts فقط.
- Drill-down.
- Operations/Finance/Sync/System monitoring.
- Audit mandatory.
- Trusted Backend mandatory.
- Password visibility requirement adopted but blocked.
- فتح م-32.

**نوع الدفعة:** توثيقية فقط.

## تحديث 2026-08-19 — PA-02 / ق-103

**المجال:**

Platform Admin Accounts, Wells, Support and Password Control.

**السبب:**

اعتماد PA-02 بالكامل، واختيار المالك Option B لكلمات المرور:
Platform Super Admin يستطيع عرض Current Password عبر
Recoverable Encrypted Password Vault.

**الملف الجديد:**

- `technical/PLATFORM_ADMIN_ACCOUNTS_WELLS_SUPPORT_ARCHITECTURE.md`

**أهم التحديثات:**

- Global Search.
- Account/Person Administration.
- Identity Resolution.
- Account Suspend/Restore.
- Well Administration.
- Support Cases.
- Error References.
- Admin Correction.
- Append-only Audit.
- Password Option B.
- Encrypted Recoverable Vault.
- Vault lifecycle.
- legacy unavailable state.
- Password Reveal.
- Password Orchestrator.
- no plaintext at rest.
- no password in local sync/cache/logs.
- key management requirements.
- ق-103 supersedes Password Non-Readability portion of ق-85.
- فتح م-33.

**نوع الدفعة:** توثيقية فقط.

## تحديث 2026-08-19 — ق-104 / ق-105

**المجال:**

Research Governance + Platform Admin Security + Password Recovery.

**السبب:**

طلب المالك تثبيت قاعدة تمنع اتخاذ القرارات المهمة دون
مراجعة المعايير العالمية وتجارب المنتجات والمستخدمين،
وفوض النموذج باختيار أفضل Password Architecture للمشروع.

**الملف الجديد:**

- `memory/RESEARCH_STANDARDS_GATE.md`

**أهم التغييرات:**

- Research & Standards Gate أصبحت إلزامية.
- README/Handoff/Collaboration/Documentation Gate حدثت.
- External Evidence hierarchy وثقت.
- Standards-aligned/Adapted/Exception ثبتت.
- Admin Dashboard usability hardening وثق.
- Pagination بدل Infinite Scroll للجداول الكبيرة.
- Sticky Search/Filters عند الحاجة.
- Hybrid Near-real-time.
- Symptom-first Monitoring.
- WCAG 2.2 AA.
- Platform Admin MFA.
- Step-up high-risk actions.
- Secret-safe logging.
- Password Vault Option B نُسخت.
- Current Password Reveal نُسخت.
- Password reset أصبح Admin-triggered + OTP +
  User-chosen new password.
- م-33 أعيدت صياغتها وفق ق-105.

**Supersession:**

ق-105 تنسخ فقط Password/Vault portion من ق-103.

PA-02 core تبقى معتمدة.

**نوع الدفعة:** توثيقية فقط.

Baseline الاختبارات لم يتغير.

## تحديث 2026-08-19 — PA-03 / ق-106

**المجال:**

Platform Sales, Entitlements, Operations and Financial Control.

**السبب:**

اعتماد PA-03 بعد تطبيق Research & Standards Gate.

**الملف الجديد:**

- `technical/PLATFORM_ADMIN_SALES_OPERATIONS_FINANCE_ARCHITECTURE.md`

**أهم القرارات:**

- Platform Commerce ≠ Well Finance.
- permanent manual V1 sale.
- one entitlement per purchased well.
- atomic/idempotent sale and grant.
- atomic entitlement consumption.
- no double consumption.
- sale/activation correction preserves history.
- operations monitoring respects Offline uncertainty.
- no generic session editor.
- admin session closure is audited correction.
- financial monitoring Read-first.
- posted finance correction follows ق-99.
- no Force Reopen bypass.
- Step-up and transaction confirmation integrity.
- filtered audited export.
- server-side pagination/filter/sort.
- privileged writes Online-only.
- م-34 opened.
- PA-04 next.

**Supersession:**

ق-106 تنسخ من ق-10 فقط مجانية V1.

Subscription deferral remains.

**Documentation repairs:**

- stale Password Vault references corrected in active UX/Map.
- legal review updated for permanent manual sale model.

**نوع الدفعة:** توثيقية فقط.

Baseline الاختبارات لم يتغير.

## تحديث 2026-08-19 — PA-04 / ق-107

**المجال:**

Platform Monitoring, Audit, Configuration and Incidents.

**الملف الجديد:**

- `technical/PLATFORM_ADMIN_MONITORING_SETTINGS_ARCHITECTURE.md`

**أهم القرارات:**

- symptom-first monitoring.
- actionable/deduplicated alerts.
- incident lifecycle.
- postmortems.
- correlation/error references.
- reuse existing append-only audit foundation.
- global admin audit projection.
- secret redaction.
- typed/versioned config.
- validation/rollback.
- scoped maintenance.
- Offline field continuity.
- version policies.
- release tracking.
- telemetry privacy.
- final admin navigation.
- م-35 opened.

**الحالة:**

Platform Administration PA-01..PA-04 مكتملة تصميميًا.

**التالي:**

UX-17.

**نوع الدفعة:** توثيقية فقط.

Baseline الاختبارات لم يتغير.

## تحديث 2026-08-19 — UX-17 / ق-108

**المجال:**

Final Cross-Cutting UX Consistency.

**الملف الجديد:**

- `technical/FINAL_CROSS_CUTTING_UX_ARCHITECTURE.md`

**أهم القرارات:**

- canonical terminology.
- explicit Offline/Sync states.
- local-save vs server-confirmation honesty.
- stable status UI.
- form/error/success consistency.
- duplicate-submit protection.
- financial/sensitive review.
- loading/empty/error/stale distinction.
- 48dp Android targets.
- RTL/accessibility/adaptive layout.
- notification/support/privacy consistency.
- navigation/back/context safety.
- م-36 opened.

**الحالة:**

UX-00..UX-17 Design Complete.

PA-01..PA-04 Design Complete.

**التالي:**

IMPLEMENTATION-01.

**نوع الدفعة:** توثيقية فقط.

Baseline الاختبارات لم يتغير.

## تحديث 2026-08-19 — IMPLEMENTATION-01 / ق-109

**المجال:**

V1 implementation sequencing and dependency planning.

**الملف الجديد:**

- `technical/V1_IMPLEMENTATION_SEQUENCE.md`

**اعتمد:**

- W1–W10.
- backend foundations first.
- Offline foundation second.
- vertical slices.
- domain-sized migrations.
- permanent tests.
- Trusted Admin Backend before Admin Web.
- owner-run DB/Docker verification.
- م-37.

**التالي:**

W1 — Backend Foundations.

**نوع الدفعة:** توثيقية فقط.

Baseline الاختبارات لم يتغير.

## تحديث 2026-08-19 — W1-01 / ق-110

**المجال:**

Canonical Login Profile ↔ Business Person identity.

**التنفيذ المحضر:**

- Migration 078.
- Permanent Test 078.
- Internal identity resolver.

**لا يشمل:**

- Farmer RLS rewrite.
- Role Catalog wiring.
- Entitlements.
- OTP.

**الحالة:**

Prepared / Pending Owner Verification.

لا Commit/Push قبل دليل الاختبار.

---

## 2026-08-19 — W1-01 local verification + Cloud baseline sync

- سجلت مزامنة Supabase Cloud baseline حتى Migration 077.
- سجلت Data API boundary السحابية: `api` + `graphql_public`.
- سجلت استعادة Auth config بعد التغيير غير المقصود.
- سجلت Owner Verification الحقيقي لـMigration 078.
- Local baseline: 77 migration files / 18 tests / 235 PASS.
- Cloud baseline: through 077؛ Migration 078 pending cloud deployment.

---

## 2026-08-19 — W1-01 Cloud verification closure

- صححت Cloud baseline إلى applied-through-078.
- سجلت Cloud structural/security verification لق-110.
- ثبتت Migration 071–078 immutable.
- نقلت RESUME_POINT إلى W1-02 / م-16.
- أي DB change جديد يبدأ Migration 079+.

---

## 2026-08-19 — W1-02 local verification

- وثقت ق-111 / Farmer self-scope.
- وثقت Migration 079 وPermanent Test.
- Local baseline صار 78 migration files through 079.
- Permanent tests = 19 files.
- Full DB Suite = 255 PASS / 0 FAIL / 0 ERROR.
- Cloud baseline بقي through 078؛ 079 pending.
- RESUME_POINT انتقل إلى Cloud deploy/verify لـ079.

---

## 2026-08-19 — W1-02 Cloud verification closure

- ثبتت Cloud baseline = 78 migrations through 079.
- سجلت 19 Farmer self-scope policies وغياب legacy broad Farmer policies.
- سجلت API/Direct DML invariants بعد 079.
- أغلقت م-16.
- ثبتت Migration 071–079 immutable.
- نقلت RESUME_POINT إلى W1-03 / م-18.
- أي DB change جديد يبدأ 080+.

---

## 2026-08-21 — W1-03a local verification / ق-112

- وثقت ق-112 / Permission Authority Foundation في DECISIONS.
- وثقت Migration 080 والاختبار الدائم في MIGRATIONS.
- سجلت توسيع Permission catalog من 21 إلى 38 code.
- سجلت `iam.well_assignment_role_map` = 6 صفوف مع استثناء `farmer` عمدًا.
- سجلت `iam.role_permissions` = 70 منح:
  tenant_owner 38 / well_manager 12 / operator 20.
- سجلت partner / accountant / viewer = 0 منح كقرار مؤجل صريح.
- سجلت `iam.has_well_permission` كدالة الصلاحية القانونية الجديدة.
- سجلت أن 273 policy على `iam.has_well_role` لم تتغير.
- Local baseline = 79 migration files through 080؛ 067 رقم غير مستخدم تاريخيًا.
- Permanent tests = 20 files.
- Permanent Test 080 = 20 PASS / 0 FAIL / 0 ERROR.
- Full DB Suite = 275 PASS / 0 FAIL / 0 ERROR.
- API = 33 authenticated / 0 anon / 0 SECURITY DEFINER؛ Direct DML = 0.
- حدّثت م-18 كمفتوحة ومحصورة في Enforcement wiring بدل الكتالوج.
- سجلت تحذير تشغيلي: `accountant` و`viewer` قابلان للتعيين بلا صلاحية فعلية،
  فلا يعرضان في أي واجهة قبل Migration 081.
- ثبتت Migration 071–080 immutable.
- Cloud baseline بقي through 079؛ 080 pending.
- نقلت RESUME_POINT إلى Cloud deploy/verify لـ080.
- أي DB change جديد يبدأ 081+.
- مؤجل بقرار المالك إلى جولة تنظيف مستقلة:
  `PROJECT_MAP.md` و`INVARIANTS.md`.

---

## 2026-08-21 — W1-03a Cloud verification closure

- سجلت Cloud verification لـ080: `CLOUD_080_ALL_PASS` = 20/20.
- سجلت remote migration history = 79 through `20260819235001`.
- سجلت `DATA_API_BOUNDARY=OK` من خارج قاعدة البيانات:
  default exposed schema = `api` وanon مرفوض،
  و`core`/`iam`/`public`/`audit`/`reporting` محجوبة،
  وجداول عبر `api` = 0.
- وثقت حدث إعادة بناء المشروع السحابي في `MIGRATIONS.md`:
  حساب جديد، منطقة South Asia (Mumbai)، 79 migration بالترتيب،
  ولا شيء فُقد لأن المشروع السابق كان Schema بلا بيانات.
- وثقت قناة النشر السحابي المثبتة: Supavisor transaction mode
  على المنفذ 6543 هي القناة العاملة الوحيدة؛ المنفذ 5432
  والاتصال المباشر IPv6 لا يصلان، فـ`db push` لا يعمل.
- وثقت أن النشر يجري بسكربت `psql` قابل للاستكمال ينقل نفس
  الملفات بلا تعديل ويسجّلها في
  `supabase_migrations.schema_migrations`.
- وضّحت في `V1_IMPLEMENTATION_SEQUENCE.md` القاعدة 9 أن هذا
  نقل لا تعديل يدوي، والملفات تبقى المصدر الوحيد.
- وثقت أن `api` تُنشأ في Migration 071، فترتيب العمل الصحيح =
  login → build → set Exposed schemas → verify، و`api` أولًا.
- حدّثت م-18 بدليل التحقق السحابي مع بقائها مفتوحة.
- حدّثت ق-112 إلى Cloud Verified في DECISIONS والمصفوفة.
- أغلقت W1-03a في PROGRESS و`V1_IMPLEMENTATION_SEQUENCE`.
- نقلت RESUME_POINT إلى Migration 081 / W1-03b Enforcement wiring.
- ثبتت Migration 071–080 immutable؛ أي DB change جديد يبدأ 081+.
- التحذير التشغيلي لـ`accountant` و`viewer` ما زال قائمًا.
