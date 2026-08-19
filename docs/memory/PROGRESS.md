# سجل التقدم

**آخر تحديث:** 2026-08-18

قاعدة هذا الملف: **لا يُكتب فيه إلا ما تمّ فعلًا وثُبِت بدليل.** النية والخطة مكانهما `RESUME_POINT.md`.

---

## Current verified baseline — 2026-08-18

هذا Snapshot للحالة المثبتة فقط.

### التنفيذ التقني المثبت

لم تشغل اختبارات قاعدة البيانات من جديد في دفعات UX
التوثيقية، لذلك يبقى آخر Baseline تقني مثبت كما هو:

- migrations: 76.
- permanent tests: 17.
- PASS: 217.
- FAIL: 0.
- ERROR: 0.
- Data API RPC: 33.
- Direct DML: 0.
- API SECURITY DEFINER: 0.
- anon API EXECUTE: 0.
- ق-77 إلى ق-82: مغلقة وفق أدلتها السابقة.
- S7-01 Mobile Bootstrap: مغلق.

### التقدم التصميمي والتوثيقي المثبت

حتى 2026-08-18:

- ق-83: الهوية البصرية العامة معتمدة.
- UX-00 إلى UX-12: معتمدة وموثقة.
- ق-84 إلى ق-92: القرارات الجديدة مسجلة حسب حالتها،
  مع فصل المعتمد عن المنفذ.
- ق-93: بروتوكول التوثيق والاستئناف الكامل معتمد.
- ق-94: دمج المناقشات المتبقية إلى UX-13..UX-17 معتمد.
- `AI_HANDOFF_PROTOCOL.md` أضيف كبروتوكول استلام للمشروع.
- Q88/Q89/Q90/Q91/Q92 architecture documents موثقة.
- م-25 وم-26 وم-27 ما تزال مفتوحة.
- لم تبن واجهة Production نتيجة هذه القرارات بعد.

### آخر إغلاق UX مثبت قبل ق-93/ق-94

Commit:

`6420946 — docs: adopt session settlement ux`

أغلق توثيق:

- ق-92.
- UX-12.
- Session Settlement Architecture.

### التالي

UX-13 — Operations, Records & Farmers.

## 2026-08-12 — التحليل والقرارات

* قراءة وثيقة التأسيس كاملة: 11,710 سطرًا.
* قراءة تقرير نقل السياق كاملًا: 2,785 سطرًا.
* ثلاث جولات تحليل وتحقق من النصوص.
* **حسم 47 قرارًا** من المالك: 11 + 22 + 14.
* رصد 7 تناقضات داخلية وحسمها جميعًا.

**الدليل:** `DECISIONS.md` — 293 سطرًا، 47 قرارًا مرقّمًا.

---

## 2026-08-12 — تفكيك الوثائق — ق-31

فُكّك الملف الأول إلى أربع وثائق تحت `reference/`:

* `01_functional_reference.md` — المرجع الوظيفي والمعماري. الأصل 1–2474.
* `02_database_and_finance_design.md` — تصميم قاعدة البيانات والمحرك المالي. الأصل 2475–5612.
* `03_implementation_schema.md` — المخطط التنفيذي لـ PostgreSQL. الأصل 5613–9389.
* `04_erd_and_data_dictionary.md` — مخطط العلاقات وقاموس البيانات. الأصل 9390–11710.

---

## 2026-08-12 — تطبيق القرارات على الوثائق

تعديلات جراحية مُثبَتة ومُتحقّق منها:

1. القسمان 17.3 و17.4: حُذف التقريب وحلّ محله احتساب بالثواني مع مثال مشتغل.
2. القسم 18.6: أُعيدت كتابته على أساس جزء من ألف والرصيد المُرحَّل.
3. `core.well_settings`: حُذفت 3 حقول تقريب، وأُضيف `long_session_alert_minutes` و`session_ending_alert_minutes`.
4. القسم 23: حُذفت `ops.ceil_to_quarter_hour` وحلّت محلها `ops.time_charge_milli`.
5. حُذف `minimum_billable_minutes`.
6. القسم 12.4: قاعدة 100% الحتمية + توثيق ت-01.
7. القسم 15.6: أربعة أقسام فرعية جديدة لحسم يوم الجلسة.
8. القسم 16: الإشعارات الخمسة المعتمدة.
9. ترويسة تحذير في رأس الوثائق الأربع.
10. 13 تصحيحًا لأرقام القرارات المذكورة داخل النص.

---

## 2026-08-12 — بناء مجلد الذاكرة — ق-42

بُني مجلد `docs/` بطبقاته الأربع وملفاته الإدارية زائدًا الوثائق المرجعية الأربع.

**ملاحظة تقنية موثّقة:** حدث تعطّل في بيئة العمل أدى إلى فقدان دفعة ملفات مكتوبة، فأُعيدت كتابتها وتُحقّق من وجودها بالفحص المباشر. الدرس المستفاد: **لا يُعتمد على تقرير النجاح، بل على الفحص بعد الكتابة.**

---

## ما لم يبدأ بعد إطلاقًا

* لا يوجد أي كود Flutter.
* لم تُطبّق أي هجرة على قاعدة بيانات حية.
* لا يوجد Commit واحد في Git.
* لا يوجد مستودع GitHub.
* لا توجد حسابات Supabase أو Firebase أو Google Play.

---

## 2026-08-12 — الدفعة الرابعة: النصوص القانونية

**ما أُنجز:**

* وصل ملف الشروط وسياسة الخصوصية من المالك وحُفظ في `legal/terms_and_privacy_v1_original.pdf`.
* روجع بندًا بندًا مقابل القرارات، وكُتب `legal/LEGAL_REVIEW.md`.
* وافق المالك على تثبيت إلغاء التقريب بعد الإفصاح المالي — ق-48.
* اعتُمدت النصوص كمصدر رسمي وحيد — ق-49.
* فُتحت المسائل م-08 إلى م-12، وأُضيف التذكير ت-05، وحُدّثت حالة ت-03 إلى مُنفَّذ جزئيًا.
* كُتب `INSTALL_INTO_PROJECT.md` — خطوات نقل مجلد الوثائق إلى جهاز المالك.

**الدليل:** 19 ملفًا في `docs/`، و`DECISIONS.md` فيه 49 قرارًا متسلسلًا بلا فجوة.

**درس موثّق:** المالك لم يكن يعرف أين توجد الملفات المكتوبة. **من الآن: كل دفعة ملفات تُسلّم مع جملة واحدة تقول أين هي وكيف تُحمّل.**

## المرحلة صفر — بيئة التطوير: مكتملة بتاريخ 2026-08-13
- اعادة تسمية المشروع الى well-irrigation ونقل مجلد الذاكرة كاملا.
- تثبيت Flutter 3.47.0 و Android SDK كاملا، flutter doctor بلا اي تحذير.
- تشغيل Supabase محليا والتحقق من المخططات والجداول وسجل الترحيلات.
- بناء تطبيق تجريبي وتثبيته وتشغيله على جهاز اندرويد حقيقي بنجاح.
- انشاء مفتاح SSH، تفعيل التحقق بخطوتين، اخفاء البريد الشخصي من تاريخ المشروع.
- انشاء منظمة GitHub ومستودع خاص فارغ، ورفع تاريخ المشروع بنجاح مؤكد.

## 2026-08-13 — مرحلة قاعدة البيانات الكاملة: مكتملة ومُختبرة (25 هجرة)

**المخطط الأساسي (001–013):** تسعة مخططات، وأربعة عشر جدولاً، مبنية بالكامل وفق القرارات النافذة حتى ق-56 — تفصيلها في `technical/MIGRATIONS.md`.

**الأمان على مستوى الصف (014–017):** دالة `iam.has_well_role` + سياسات SELECT/INSERT/UPDATE/DELETE لكل جدول. **الدليل:** اختبار عزل مباشر بأربعة أدوار على بئرين منفصلين، ثمانية فحوصات مطابقة تمامًا للمتوقع. اكتُشف وصُحّح أن `ops.compute_session_charge` كانت `SECURITY INVOKER` ضمنيًا.

**التوفير التلقائي (018، 020):** ملف شخصي تلقائي عند التسجيل، وإعدادات بئر تلقائية عند الإنشاء — كلاهما اكتُشفت الحاجة إليهما باختبار مباشر فشل أولاً ثم صُحّح.

**رصد الجلسات والإشعارات (019، 021، 022):** دالتا رصد الجلسات الطويلة والمقتربة من الحد، وجدول إشعارات معزول بـ RLS. **الدليل:** اختبار ثلاثي مطابق تمامًا، واختبار إشعار مزدوج بعزل تام.

**دورة حياة توزيع الأرباح (023، 024، 025):** حساب صافي تلقائي، توزيع بطريقة أكبر الباقي (ق-21)، قفل نهائي بعد `finalized`، إشعار تلقائي لكل شريك. **الدليل:** اختباران مطابقان تمامًا، واختبار قفل برسالتي خطأ عربيتين واضحتين.

**ملاحظة أمانة موثّقة:** آلية أكبر الباقي نُفّذت واختُبرت بمثال تركيبي لا بمثال حي من بئر حقيقي للمالك، كما يشترط ت-01 حرفيًا. التفاصيل في `DECISIONS.md` (أسفل ق-66) و`REMINDERS.md` (ت-01، ت-09).

**الدليل الإجمالي:** 25 ملف ترحيل، كل واحد مُختبر فور كتابته، بلا أي بقايا بعد كل اختبار.

## 2026-08-13 (الدفعة الثالثة) — إغلاق المرحلة 1 (النواة)
**المواقع، بطاقة الشخص الموحدة، كتالوج الأدوار والصلاحيات (026–028):** مبنية ومختبرة محليًا عبر `npm run db:reset` + فحص مباشر بـ psql. الدليل: 7 جداول، 3 امتدادات، توليد رقم ظاهر فعال، فهارس trigram، 6 أدوار/21 صلاحية، عمود `location_id` بمفتاح خارجي، 15 سياسة RLS مطابقة للتصميم.
**فجوة موثّقة عمدًا:** كتالوج الأدوار غير مربوط بنظام الأدوار الحالي (م-18).
**الحالة:** المرحلة 1 من ترتيب البناء الموثّق مكتملة عمليًا. القرار: ق-68.

## 2026-08-13 (الدفعة الرابعة) — إغلاق المرحلة 2 (التشغيل)
**خطوط المياه، ملفات المزارعين، التسعير، الحجوزات، حجز الموارد، مقاطع الجلسة (029–034):** مبنية ومختبرة محليًا عبر `npm run db:reset` + فحص بنيوي مباشر بـ psql، ثم اختبار وظيفي كامل ببيانات تجريبية ذاتية الاكتفاء داخل معاملة `begin`/`rollback`. الدليل: 10 جداول جديدة، RLS مفعّلة على جميعها بعدد سياسات مطابق للتصميم، الدالتان `reserve_resource`/`validate_session_segment_overlap` والزناد يعملان، وكل حالات الاختبار (حجز صحيح ومرفوض، تعارض حجز موارد، تداخل مقاطع جلسة) أعطت النتيجة المتوقعة تمامًا.
**عطل مُكتشف ومُصحَّح:** `reserve_resource()` كانت تفشل دومًا لعدم إدراج `tenant_id`؛ صُحّحت لتستخرجه تلقائيًا من `core.wells`.
**فجوة موثّقة عمدًا:** `core.pumps` لا يطابق كامل §13.1 (م-19).
**الحالة:** المرحلة 2 من ترتيب البناء الموثّق مكتملة عمليًا. القرار: ق-69.

## 2026-08-13 (الدفعة الخامسة) — إغلاق المرحلة 3 (المال)
**دليل الحسابات، القيود اليومية وأطرافها، الفواتير وبنودها، تخصيص الدفعات (035–038):** مبنية ومختبرة محليًا عبر `npm run db:reset` (38 هجرة) + تحقق بنيوي بـ psql + اختبار وظيفي كامل داخل `begin`/`rollback`.
**الدليل:** 6 جداول جديدة، RLS مفعّلة، 18 سياسة، 4 دوال، زنادَي قفل القيود، و19 حالة اختبار كلها ناجحة — أهمها: دليل حسابات 26 حسابًا بلا تكرار، رفض القيد غير المتوازن، رفض تعديل قيد مُرحّل وأطرافه، رفض فاتورة تُخلّ بمعادلة `paid+outstanding=total`، وسداد جزئي 8000/12000 مع تخصيص صحيح للدفعة.
**تباعد موثّق:** مخطط `billing.payments` المبني يخالف §28 — لم يُمسّ، وسُجّل في م-20 لقرار المالك.
**الحالة:** المرحلة 3 من ترتيب البناء الموثّق مكتملة عمليًا. القرار: ق-70.

---

## المرحلة 4 — الديزل والمصروفات ✅ مكتملة (2026-08-13)

الهجرات 039 الى 046، الاجمالي 46 هجرة و49 جدولا.

- الدفعة الاولى (040-043): صندوق البئر، المناوبات، اقرار وتأكيد التسليم، نقل الجلسات، توسيع الدفعات، 15 نوع اشعار. اختبار 27/27.
- الدفعة الثانية (044-045): انواع المصروفات وزرعها، المصروفات بقيد المرفق، قواعد الاعتماد، ربط الجلسة بالمناوبة، تقرير المناوبة واجمالي المشغل.
- الدفعة الثالثة (046): خزانات الوقود وحركاته العشرة، المتوسط المرجح المتحرك، رصيد ديزل المزارع، جسر الشراء القديم، والمفتاح المؤجل journal_lines.fuel_tank_id.
- الدفعتان الثانية والثالثة: اختبار 25/25.

التالي: المرحلة 5 الشركاء.

---

## المرحلة 5 — الشركاء ✅ مكتملة (2026-08-14)

الهجرات 047 إلى 050، الإجمالي 50 هجرة و53 جدولًا.

- 047: جدول الشركاء مصدرًا وحيدًا للنسب وصلاحية المالك، دورا المدير والشريك، علم المدير العام، ترحيل الحصص القديمة وإسقاط جدولها، إعادة كتابة دالة التوزيع وإشعار الملاك.
- 048: سياسة سقي الشريك (دفع عادي / خصم من الأرباح) وربط المفتاحين المؤجلين.
- 049: الفترات الشهرية والسنوية، الإقفال المباشر، إعادة الفتح بـ 70% من عدد الشركاء ثم موافقة المدير العام، والخطوة 5 المؤجلة.
- 050: 120 سياسة مدير و49 سياسة شريك وُلّدت آليًا، وسياسات تعيين مقيدة للمدير.
- الاختبار الوظيفي: 23/23 بصفر فشل.

التالي: المرحلة 6 — الإدارة (محرك التوزيع الكامل §31، احتياطي الصيانة §32، الأرصدة الافتتاحية §33، الرواتب §29).

---

## المرحلة 6 — الإدارة ✅ مكتملة (2026-08-14)

الهجرات 051 إلى 056، الإجمالي 56 هجرة و60 جدولًا.

- 051: إصدارات نسب الشريك (ملكية/أرباح، تاريخ موثق، مانع تداخل) — تبنّي نموذج المرجع §16.
- 052: محرك التوزيع الكامل بدوراته (§39/§49) واحتياطي الصيانة (§38) ومفتاح الالتزامات المحتجزة؛ حذف جداول التوزيع القديمة.
- 053: إصلاح فحص found + علامتا منع الازدواج بين الدورات.
- 054: الأرصدة الافتتاحية (§41) — اعتماد المالك، قفل، ترحيل بقيد متوازن.
- 055: الرواتب (doc 02 §29) وقيود الديزل التلقائية (§26) وإصلاح توازن الأرصدة ومعامل الشريك في المصروفات.
- 056: حذف ازدواج record_expense وفحص التوازن عند الاعتماد.
- الاختبارات: 19/19 و17/17 بصفر فشل.

**بهذا تكتمل مراحل بناء قاعدة البيانات الست** حسب ترتيب doc 02 §47: النواة، التشغيل، المال، الديزل والمصروفات، الشركاء، الإدارة.

التالي: محطة تطبيق Flutter (أندرويد) — واجهات المالك والمشغل والشريك والمدير العام.

## 2026-08-14 — الدفعة الختامية (057–061) واكتمال محطة قواعد البيانات
- الحصيلة النهائية: 61 هجرة، 64 جدولًا أساسيًا، 5 عروض تقارير؛ المخططات: core و iam و ops و billing و finance و inventory و audit و sync و reporting.
- اكتملت في هذه الدفعة: سجل التدقيق، طبقة المزامنة وعدم تكرار الأوامر، المرفقات العامة، عروض التقارير الخمسة، والإجراءات المالية (ترحيل آلي للدفعات والمصروفات والفواتير + العكس الموثق بالسبب).
- الاختبار المالي الختامي: 17/17 PASS.
- المحطة القادمة: المرحلة 7 — تطبيق أندرويد (Flutter) للمشغل ثم لوحة الإدارة.

## 2026-08-14 — ق-76: سد فجوات التدقيق الشامل (062–063)
- التدقيق الشامل (وثائق ↔ منفذ) أثبت مطابقة 64 جدولًا وكل القرارات، وكشف 4 فجوات غير موثقة فحسب.
- بُني: كشف التكرار عند إنشاء شخص (تطابق = اسم+هاتف، شك = أحدهما، مع بيانات المرشح وخياري دمج/إنشاء) وإجراء الدمج الآمن مع سجل التدقيق، وقفل التشغيل المتزامن للمضخة بقواعد يضبطها المالك (الافتراضي 1).
- تأكد بالدليل الحرفي: قفل المناوبة على البئر مزدوج الحماية (قيد فريد + زناد برسالة عربية).
- وُثّق تأجيل farm_participants و farm_well_links، ومطابقة salary_payments سلوكيًا عبر pay_salary.
- الحصيلة: 63 هجرة، 66 جدولًا، 5 عروض؛ اختبار 062: 13/13 PASS.

## 2026-08-14 — دفعة إصلاحات ق-77 (064–065) عبر Codex
- أُغلقت ثلاث من الملاحظات الحرجة (C-02 لقطة السعر، C-03 يوم التقرير، C-05 إدخال الآبار) وثلاث متوسطة (M-01 شرط الملكية، M-03 عمود التقريب، M-05 تداخل سياسات الشريك).
- أسلوب عمل جديد مثبت: تنفيذ عبر وكيل مستقل + تحقق بقناة مستقلة ثانية قبل الالتزام.

## 2026-08-15 — الهجرة 066: طبقة إجراءات الجلسة الذرية
- دورة الجلسة أصبحت كاملة عبر إجراءات خادم مسماة (بدء/إيقاف/تغيير مصدر/استئناف/إكمال/إصدار فاتورة) — عقد التطبيق الوحيد للمشغل. إغلاق C-04.
- الجلسات المختلطة تُسعّر بمقاطعها المثبتة لحظة كل مقطع، بلا تقريب، مع حركات الوقود والقيد الآلي والتدقيق.
- الحصيلة: 66 هجرة؛ 4 ملفات اختبار دائمة؛ 56 فحصا كلها PASS بقناتين مستقلتين.

## 2026-08-15 — ختام محطة قاعدة البيانات (ق-77 نافذ ومنفذ بالكامل)
- حزمة قبول دائمة: 7 ملفات اختبار، 92 فحصا، تعمل بامر واحد وتفشل عند اول انحراف — معيار القبول الرسمي لاي تغيير مستقبلي.
- اكتملت جميع بنود ق-77: وحدة الريال (توثيقيا)، باقي القسمة لاكبر حصة (توثيقيا)، اصلاحات 064-066 (تنفيذيا بقناتين)، وحزمة الاختبارات.
- الحصيلة النهائية للمحطة: 66 هجرة، 66 جدولا، 5 عروض، 4 قيود منع تداخل، عزل كامل، سجل تدقيق، وتدقيقان مستقلان + 92 فحصا ذاتيا.

## 2026-08-15 — الهجرة 068: أزرار المال الكبرى مكتملة
- تسجيل الدفعة أصبح زرا واحدا ذريا بخطواته الـ13: يقبض، يخصص للفواتير، يحوّل الزيادة لرصيد مقدم، يوثق، ويعيد ايصالا — ويستحيل ان يبقى المال في حالة نصف مكتملة.
- دفع مستحقات الشركاء اصبح اجراء رسميا (جزئي/كامل) يحفظ المدفوع التراكمي ويحجز المتبقي فقط في الدورات اللاحقة.
- الحصيلة: 67 هجرة؛ 8 ملفات اختبار؛ 107 فحصات كلها PASS بقناتين مستقلتين.

## 2026-08-15 — الهجرة 069: اكتمال طبقة الإجراءات كلها (ت-11 مغلق)
- سبعة اجراءات تشغيل ذرية: انشاء مزارع وارض وحجز واعادة جدولة، وشراء وقود واستهلاكه وجرده الفعلي.
- بذلك صار لكل عملية في التطبيق القادم زر خادم واحد ذري ومختبر — مرحلة التطبيق اصبحت واجهة ومزامنة فقط.
- الحصيلة النهائية: 68 هجرة؛ 9 ملفات اختبار دائمة؛ 129 فحصا كلها PASS بقناتين مستقلتين.

## 2026-08-15 — الهجرة 070: حارسا الساعة مبنيان (م-23: المنطق منفذ)
- الملخص اليومي يولد من ارقام العرض الرسمي للمالك والمدير بلا تكرار، ومراقب الدين ينبه عند التجاوز ويصمت تحت الحد ويعود عند تجاوز جديد.
- تبقى من م-23 علامتان موثقتان: شاشة وقناة الاشعارات في المرحلة 7، وبند «تفعيل المجدول» الالزامي عند النشر.
- الحصيلة النهائية لمحطة القاعدة: 69 هجرة؛ 10 ملفات اختبار دائمة؛ 138 فحصا كلها PASS بقناتين مستقلتين.

## 2026-08-16 — ق-78: إغلاق الشرط الأول من بوابة جاهزية المرحلة 7

- أنشئ مخطط `api` كعقد Data API الرسمي لتطبيق Flutter.
- أصبحت Exposed Schemas هي `api` و`graphql_public` فقط؛ `public` و`ops` وبقية مخططات الأعمال ليست مكشوفة مباشرة.
- `api.health()` مسبار تقني SECURITY INVOKER؛ الخادم والمستخدم الموثق فقط يملكان EXECUTE صريحًا، وanon محجوب.
- كشف اختبار القبول خاصية PostgreSQL الخاصة بمنح EXECUTE الافتراضي إلى PUBLIC، وصُحح نمط الحماية إلى CREATE + REVOKE + GRANT داخل المعاملة نفسها مع مسح دائم لكل دوال api.
- الدليل النهائي: 70 هجرة؛ 11 ملف اختبار؛ 145 PASS؛ FAIL=0؛ ERROR=0؛ واختبارات PostgREST الحية ناجحة.
- الشرط الأول API Architecture مغلق. الشرط الثاني RPC-only writes ما زال مستقلًا ولم يُغلق ضمن ق-78.

## 2026-08-16 — ق-79: إغلاق Direct DML بالهجرة 072

- أزيلت جميع صلاحيات الكتابة الجدولية المباشرة من `anon` و`authenticated` على مخططات الأعمال الداخلية.
- نتيجة التدقيق بعد 072: Direct DML = صفر.
- بقيت إجراءات الأعمال الحرجة قابلة للتنفيذ.
- لا توجد SECURITY DEFINER قابلة للتنفيذ بواسطة authenticated بلا search_path صريح.
- حزمة القبول: 71 هجرة، 12 ملف اختبار، 154 PASS، بلا فشل أو خطأ.
- اختبارا 066 و069 فُصلا بين Fixtures الإدارية وسلوك المستخدم بعد ق-79.
- ق-79 لم يغلق كاملًا بعد؛ أغلفة الكتابة داخل api هي الخطوة التالية.

## 2026-08-17 — إغلاق الشرط 2: RPC-only writes

- أُغلق Direct DML بالكامل.
- أُنشئ واستكمل عقد الكتابة الرسمي داخل api.
- سطح api المثبت: 31 RPC.
- baseline: 73 هجرة، 14 اختبارًا، 178 PASS.
- بقي create_farm مؤجلًا إلى حسم م-22.
- التالي: الشرط 3 — تنظيف وتوحيد الوثائق الرسمية.

## 2026-08-17 — إغلاق الشرط 3: Documentation Conformance

- Documentation Acceptance = PASS.
- Cross-sync = PASS.
- baseline موحد: 73 migration / 14 tests / 178 PASS.
- API موحد: 31 RPC / Direct DML=0.
- الوحدة المالية موحدة إلى الريال الكامل وفق ق-77.
- باقي التوزيع موحد إلى صاحب أكبر حصة.
- API/Sync/Decision-Implementation موثقة في ملفات حاكمة مستقلة.
- فُصل Server Sync المنفذ عن Mobile Offline Sync المؤجل.
- التالي: الشرط 4، بدءًا بم-22 ثم م-19.

## 2026-08-17 — ق-80 / 075 محضرة

- حُسم م-22 بنيويًا بق-80.
- أُعدت 075 لتحويل Farm من Login Profile إلى Farmer Well Account.
- أضيف invariant دائم Farm ↔ Farmer Well Account للحجوزات والجلسات.
- أُعد `api.create_farm`.
- عُدلت Fixtures 066 و069 لتستخدم الهوية الميدانية الصحيحة.
- عُدلت Assertions التاريخية في 073/074 حتى تسمح بتوسعات API اللاحقة الآمنة.
- لا تعتبر 075 مطبقة أو مثبتة قبل تحقق المالك.

## 2026-08-17 — إغلاق ق-80 / م-22 / Condition 4A

- Migration 075 أعيد بناؤها بنجاح.
- اختبار 075 = 15 PASS.
- suite = 15 files / 193 PASS / 0 FAIL / 0 ERROR.
- Farm identity انتقلت من Login Profile إلى Farmer Well Account.
- Farm/Account mismatch محمي في Booking وSession.
- `api.create_farm` أصبح جزءًا من العقد.
- API surface = 32.
- Direct DML = 0.
- م-22 مغلقة.
- Condition 4A مغلق.
- التالي مباشرة: Condition 4B / م-19.

## 2026-08-17 — إغلاق ق-81 / م-19 / Condition 4

- `supabase db reset` طبق Migration 076 بنجاح.
- اختبار 076 = 12 PASS.
- suite = 16 files / 205 PASS / 0 FAIL / 0 ERROR.
- Pump model أصبح مطابقًا للنموذج المرجعي.
- reporting للطاقة أصبح مبنيًا على session segments.
- legacy flat fallback بقي متوافقًا.
- reservation concurrency أصبح يستخدم resource concurrency rules.
- م-19 مغلقة.
- Condition 4B مغلق.
- Condition 4 كله مغلق.
- التالي حصريًا: Condition 5 / Final Clean Acceptance.

## 2026-08-17 — Stage 7 Readiness Gate closed

اكتمل Final Clean Acceptance:

- clean reset نجح.
- suite = 16 files / 205 PASS / 0 FAIL / 0 ERROR.
- migrations = 75.
- Data API = 32 RPC.
- Direct DML = 0.
- API SECURITY DEFINER = 0.
- anon API EXECUTE = 0.
- exposed schemas = api + graphql_public فقط.
- final documentation cross-sync = PASS.
- Condition 5 مغلق.
- Stage 7 Readiness Gate مغلق بالكامل.


## 2026-08-17 — ق-82 / عقد تهيئة التطبيق للقراءة

أُضيفت Migration 077 واختبار دائم لعقد
`api.app_bootstrap()`.

أثبت التحقق الفعلي:

- إعادة بناء نظيفة حتى 077.
- اختبار 077 = 12 PASS.
- الحزمة الكاملة = 17 ملفًا / 217 PASS / 0 FAIL / 0 ERROR.
- Data API = 33 RPC.
- `app_bootstrap` ظاهر عبر Data API.
- Direct DML = 0.
- API SECURITY DEFINER = 0.
- anon API EXECUTE = 0.
- authenticated/service_role API EXECUTE = 33.
- API relations = 0.

عُدّل فحص تاريخي في اختبار 075 بحيث يحافظ على baseline
ذلك القرار مع السماح بإضافات API آمنة لاحقة؛ لم تتغير
Migration 075 ولا أي هجرة مطبقة سابقة.

الخطوة التالية قبل أي واجهة جديدة هي بوابة الهوية البصرية.


## 2026-08-17 — ق-83 / الهوية البصرية العامة

أغلق المالك بوابة الهوية البصرية العامة بعد مناقشة واعتماد
ثوابت الشعار المبدئي والألوان والخط والأيقونات والأسطح
والمسافات والصور والرسوم والحركة والحالات وDark Mode
وAccessibility وRTL وقواعد أصول الهوية.

أُنشئ المصدر التفصيلي:

`docs/design/VISUAL_IDENTITY.md`

الشعار الحالي معتمد مبدئيًا وقابل للتطوير لاحقًا.

لا توجد شاشة إنتاجية جديدة ناتجة عن هذا القرار حتى الآن.

الخطوة التالية:
مناقشة الصفحات والأقسام ثم تنفيذ المعتمد منها.

## 2026-08-18 — توثيق منهج العمل نفسه — ق-95 وق-96

**تم وثبت:**

- إضافة `AI_COLLABORATION_PROTOCOL.md`.
- إضافة `TERMINAL_COMMAND_PROTOCOL.md`.
- توثيق أسلوب الحوار والشرح.
- توثيق منهج القرار القابل للمراجعة.
- توثيق Workflow مناقشة/اعتماد/توثيق UX.
- توثيق الفصل بين Adopted/Documented/Implemented/Verified.
- توثيق طريقة قراءة Terminal Output.
- توثيق Shell safety.
- توثيق أسلوب كتابة Command Block.
- توثيق منع Base64 افتراضيًا.
- توثيق منع Nested Markdown Fences.
- توثيق Expected HEAD وWorktree guards.
- توثيق Recovery حسب مرحلة الفشل.
- توثيق Lessons Learned من حوادث الطرفية السابقة.

هذه دفعة توثيقية فقط.

لم تغير أرقام Baseline الخاصة باختبارات قاعدة البيانات.

## 2026-08-18 — بوابة التوثيق الإلزامية — ق-97

**تم في هذه الدفعة التوثيقية:**

- إنشاء `DOCUMENTATION_GATE.md`.
- جعل أسباب القرار جزءًا إلزاميًا من اكتمال التوثيق.
- توثيق شروط Decision/UX/Technical/Open Issue/Progress.
- توثيق شروط Changelog وResume وProject Map وMatrix.
- توثيق شروط Evidence وGit closure.
- توثيق Meta-documentation.
- توثيق Traceability من السبب إلى الاختبار والإنجاز.
- ربط البوابة ببروتوكولات Handoff/Collaboration/Terminal.
- إبقاء UX-13 كنقطة العمل التالية.

لم تشغل اختبارات قاعدة البيانات في هذه الدفعة،
لذلك لا تتغير أرقام Baseline التقنية المثبتة.

## 2026-08-18 — اعتماد وتوثيق UX-13 / ق-98

**المنجز المثبت في هذه الدفعة التوثيقية:**

- اعتماد قرارات UX-13 من 373 إلى 407.
- توثيق سجل جلسات السقي.
- توثيق Farmer/Farm UX.
- توثيق Booking UX.
- توثيق Shift/Handover UX.
- توثيق Offline booking pending confirmation.
- توثيق no-orphan active session rule.
- توثيق فصل Operational Transfer عن Cash Handover.
- إنشاء `OPERATIONS_RECORDS_ARCHITECTURE.md`.
- فتح م-28 للفجوات التنفيذية.
- تحديث API/Sync/Search architecture references.
- الانتقال المخطط إلى UX-14 بعد Documentation Gate.

هذه دفعة توثيقية فقط.

لم تنفذ Migration 078 ولم تشغل اختبارات قاعدة بيانات
جديدة، لذلك يبقى Baseline التقني السابق دون تغيير.

## 2026-08-18 — اعتماد وتوثيق UX-14 / ق-99

**المنجز المثبت في هذه الدفعة التوثيقية:**

- اعتماد UX-14 من القرار 408 إلى 459.
- توثيق Farmer Financial Account UX.
- توثيق فصل Debt عن Advance.
- توثيق Explicit Old Advance Allocation.
- توثيق Payment/Receipt/Offline behavior.
- توثيق Expense/Approval UX.
- توثيق Partner-paid expenses.
- توثيق فصل Ownership عن Profit Percentage.
- توثيق Historical Share Versions.
- توثيق Profit Distribution Review/Approval.
- توثيق Partial/Full Partner Payout.
- توثيق Accounting Period Close/Reopen.
- توثيق Financial Correction/Audit UX.
- إنشاء `MONEY_PARTNERS_ARCHITECTURE.md`.
- فتح م-29.
- تسجيل فجوة Attachment Skip Reason.
- تسجيل مراجعة Maintenance Reserve Rounding.
- تحديث API/Sync/Settlement architecture handoffs.
- تحديد UX-15 كنقطة العمل التالية.

هذه دفعة توثيقية فقط.

لم تنفذ Migration 078 ولم تشغل اختبارات قاعدة بيانات
جديدة، لذلك يبقى Baseline التقني السابق دون تغيير.

## 2026-08-19 — اعتماد وتوثيق UX-15 / ق-100

**المنجز المثبت في هذه الدفعة التوثيقية:**

- اعتماد UX-15 من القرار 460 إلى 526.
- توثيق Well Management UX.
- توثيق Pump Equipment UX.
- إعادة تأكيد Session Segments كمصدر Energy الحديث.
- توثيق Fuel Inventory/Physical Count/Reconciliation UX.
- إعادة تأكيد أن Fuel ليس Farmer Surcharge.
- توثيق Historical Pricing.
- حجب `operation_plus_fuel` عن V1 UX.
- توثيق Reporting UX.
- اعتماد Simple Charts للنسخة الأولى.
- اعتماد Bar وLine فقط في V1.
- اعتماد عدم وضع Chart في Owner Home في V1.
- تحديد Chart Locations.
- توثيق Drill-down وExact Values.
- توثيق Offline/Stale Chart behavior.
- ربط Chart Data بـBackend Aggregation.
- تحديث Visual Identity للرسوم.
- إنشاء `WELL_MANAGEMENT_REPORTING_ARCHITECTURE.md`.
- فتح م-30.
- تحديد UX-16 كنقطة العمل التالية.

هذه دفعة توثيقية فقط.

لم تنفذ Migration 078 ولم تشغل اختبارات قاعدة بيانات
جديدة، لذلك يبقى Baseline التقني السابق دون تغيير.

## 2026-08-19 — اعتماد UX-16A / ق-101

- فصل Account & Settings عن Platform Administration.
- اعتماد البنود 527–541 و543–583 و595–598.
- نقل البند 542 إلى PA.
- نقل كل Platform Administration إلى سلسلة مستقلة.
- اعتماد English digits.
- اعتماد English Date/Time display الثابت.
- اعتماد Forgot Password عبر OTP في V1.
- اعتماد Account-scoped Local State.
- اعتماد Logout دون حذف Pending Outbox.
- إنشاء `ACCOUNT_SETTINGS_ARCHITECTURE.md`.
- فتح م-31.
- تحديد PA-01 كنقطة العمل التالية.

دفعة توثيقية فقط.

Baseline الاختبارات لم يتغير.

## 2026-08-19 — اعتماد PA-01 / ق-102

- تعريف Platform Super Admin كمسؤول منصة مستقل.
- منع خلطه بOwner/Operator/Partner/Farmer.
- اعتماد Console مستقلة Web/Desktop-first.
- اعتماد Sidebar RTL ثابتة على اليمين.
- اعتماد Dashboard رقمية واسعة.
- اعتماد Wells/Accounts/Operations/Sync/Activation/Finance KPIs.
- اعتماد Near-real-time auto refresh.
- اعتماد Last Update عند Stale state.
- اعتماد Drill-down من KPIs.
- اعتماد Bar/Line Charts وفق ق-100.
- اعتماد ثلاثة سياقات Charts أولية للرئيسية.
- اعتماد Global Wells/Accounts/Finance/Operations monitoring.
- اعتماد Support/Audit/System Monitoring sections.
- اعتماد Trusted Backend boundary.
- تسجيل Password Visibility كمتطلب منتج معتمد
  لكنه غير منفذ ويحتاج قرارًا أمنيًا لاحقًا.
- إنشاء `PLATFORM_ADMINISTRATION_ARCHITECTURE.md`.
- فتح م-32.
- تحديد PA-02 كنقطة العمل التالية.

دفعة توثيقية فقط.

Baseline الاختبارات لم يتغير.

## 2026-08-19 — اعتماد PA-02 / ق-103

- اعتماد PA-02-01 إلى PA-02-57.
- اعتماد Global Search.
- اعتماد Global Account Administration.
- اعتماد Identity Resolution.
- اعتماد Account Suspend/Restore.
- اعتماد Session Invalidation.
- اعتماد Global Well Administration.
- اعتماد User Preview Read-only.
- اعتماد Support Case model.
- اعتماد Error References.
- اعتماد Administrative Correction flow.
- إعادة تأكيد Append-only Audit.
- اعتماد Password Option B.
- اعتماد Recoverable Encrypted Password Vault.
- اعتماد Platform Admin Current Password Reveal.
- توثيق أن Supabase Hash الحالية لا تسترجع Legacy Password.
- اعتماد Vault unavailable للحساب القديم حتى Password Rotation.
- اعتماد no plaintext at rest.
- اعتماد no local/outbox password cache.
- اعتماد Trusted Password Orchestrator.
- اعتماد Pending Vault Version قبل Auth Update.
- اعتماد stale/unavailable safety.
- توثيق أن ق-103 ينسخ فقط Password Non-Readability من ق-85.
- إنشاء `PLATFORM_ADMIN_ACCOUNTS_WELLS_SUPPORT_ARCHITECTURE.md`.
- فتح م-33.
- تحديد PA-03 كنقطة العمل التالية.

دفعة توثيقية فقط.

لم تنفذ Password Vault أو Migration 078+ بعد.

Baseline الاختبارات لم يتغير.

## 2026-08-19 — اعتماد ق-104 وق-105

**دفعة Governance + Security Documentation فقط.**

المنجز التوثيقي المثبت:

- اعتماد Research & Standards Gate.
- إنشاء `RESEARCH_STANDARDS_GATE.md`.
- إدخال البوابة في README/Handoff/Collaboration/Documentation Gate.
- اعتماد تصنيف Standards-aligned / Adapted / Exception.
- اعتماد Source of Truth → Standards → Platform → User Feedback → Project Fit.
- اعتماد Sticky Admin Search/Filters عند الحاجة.
- اعتماد Server-side Pagination/Filter/Sort للجداول الإدارية.
- اعتماد عدم استخدام Infinite Scroll كAdmin-table pattern أساسي.
- اعتماد Near-real-time hybrid بدل blind rapid polling.
- اعتماد Symptom-first Monitoring.
- اعتماد WCAG 2.2 AA للAdmin Web.
- اعتماد Platform Admin MFA.
- اعتماد Step-up للأفعال عالية الخطورة.
- اعتماد Secret-safe Audit/Logging.
- نسخ Password Option B من ق-103.
- إلغاء Recoverable Password Vault قبل التنفيذ.
- إلغاء Current Password Reveal.
- اعتماد Admin-triggered Force Reset.
- اعتماد OTP + user-chosen new password.
- تحديث م-33 إلى Password Recovery model.
- PA-03 ما زالت الخطوة التالية.

لم تنفذ:

- Migration 078+.
- Admin MFA.
- Password Recovery API.
- Flutter/Web production changes.

Baseline الاختبارات لم يتغير.

## 2026-08-19 — اعتماد PA-03 / ق-106

**دفعة توثيقية فقط.**

تم:

- اعتماد PA-03-01 إلى PA-03-64.
- اجتياز Research & Standards Gate للمقترحات.
- اعتماد الفصل بين Platform Commerce وWell Finance.
- اعتماد Sale مستقلة عن Entitlement.
- اعتماد Entitlement مستقلة لكل Well مشتراة.
- اعتماد Atomic Sale + Grant.
- اعتماد Idempotent Admin Commands.
- إعادة تأكيد Atomic Well + Entitlement Consumption.
- اعتماد Sale/Activation Correction دون History Rewrite.
- اعتماد Exceptional Consumed Entitlement intervention.
- اعتماد Global Operations Monitoring.
- اعتماد Offline-aware server visibility.
- اعتماد Administrative Session Closure.
- اعتماد Global Finance Read-first.
- إعادة تأكيد ق-99 للتصحيحات المالية.
- رفض Force Reopen bypass في V1.
- اعتماد Step-up وConfirmation integrity.
- اعتماد audited filtered exports.
- اعتماد Server-side Pagination/Filter/Sort.
- اعتماد PA-03 writes Online-only.
- تصحيح تعارض ق-10 مع ق-86/ق-106.
- تصحيح مواضع Password Vault الوثائقية القديمة.
- إنشاء `PLATFORM_ADMIN_SALES_OPERATIONS_FINANCE_ARCHITECTURE.md`.
- فتح م-34.
- تحديد PA-04 كالمناقشة التالية.

لم تنفذ Migration 078+ أو Admin APIs جديدة.

Baseline الاختبارات لم يتغير.

## 2026-08-19 — اعتماد PA-04 / ق-107

**دفعة توثيقية فقط.**

تم:

- اعتماد PA-04-01 إلى PA-04-86.
- اجتياز Research & Standards Gate.
- اعتماد Symptom-first Monitoring.
- اعتماد Actionable Alerting.
- اعتماد Alert dedup/grouping.
- اعتماد Incident Center.
- اعتماد Major Incident Postmortem.
- اعتماد Correlation IDs.
- اعتماد OpenTelemetry readiness دون Full rollout.
- إعادة استخدام `audit.audit_logs`.
- اعتماد Global Audit Admin Projection.
- اعتماد Secret Redaction.
- اعتماد Typed/Versioned Platform Configuration.
- اعتماد Validation + Rollback.
- اعتماد Feature Flags كUX/release لا Authorization.
- اعتماد Scoped Maintenance.
- حماية Offline Field Work أثناء Maintenance.
- اعتماد Recommended/Minimum/Required App Versions.
- اعتماد Release/Config/Migration change tracking.
- اعتماد Dependency Health.
- اعتماد Telemetry Privacy.
- اعتماد Admin Security View.
- رفض ordinary DB dump/one-click restore.
- اعتماد Final 12-section Platform Admin Sidebar.
- تأجيل SIEM/Public Status/Full OTel/Custom Admin Roles.
- إنشاء `PLATFORM_ADMIN_MONITORING_SETTINGS_ARCHITECTURE.md`.
- فتح م-35.
- إغلاق PA-01..PA-04 تصميميًا.
- تحديد UX-17 كالمناقشة التالية.

لم تنفذ Migration 078+ أو Monitoring/Admin APIs جديدة.

Baseline الاختبارات لم يتغير.

## 2026-08-19 — اعتماد UX-17 / ق-108

**دفعة توثيقية فقط.**

تم:

- اعتماد Final Cross-Cutting UX Review.
- اجتياز UX17 Research & Standards Gate.
- تثبيت canonical Offline/Sync user terminology.
- فصل connectivity عن sync state.
- اعتماد honest local/server success messaging.
- اعتماد stable connectivity/status placement.
- اعتماد item-level sync state للسجلات الحرجة.
- اعتماد form preservation.
- اعتماد clear error/confirmation states.
- اعتماد duplicate-submit prevention.
- إعادة تأكيد financial/sensitive review.
- اعتماد Loading/Empty/Error/Denied/Stale separation.
- اعتماد Android 48dp touch targets.
- اعتماد RTL/font scaling/accessibility semantics.
- اعتماد adaptive navigation/layout.
- اعتماد notification/support/privacy consistency.
- اعتماد back/context-switch safety.
- إنشاء `FINAL_CROSS_CUTTING_UX_ARCHITECTURE.md`.
- فتح م-36.
- إصلاح malformed ق-107 text في RESUME_POINT.
- إغلاق UX-00..UX-17 تصميميًا.
- إبقاء PA-01..PA-04 Design Complete.
- تحديد IMPLEMENTATION-01 كنقطة العمل التالية.

لم تنفذ Production UI أو Migration جديدة.

Baseline الاختبارات لم يتغير.

## 2026-08-19 — اعتماد IMPLEMENTATION-01 / ق-109

**دفعة تخطيط/توثيق فقط.**

تم:

- اعتماد W1–W10 implementation sequence.
- اعتماد dependency-based ordering.
- اعتماد coherent migrations بدل Migration عملاقة.
- إعادة تأكيد 071–077 immutable.
- اعتماد 078+ كبداية DB implementation الجديدة.
- اعتماد Vertical Slices بعد Foundations.
- وضع Offline/Background Sync في W2 قبل Critical Field UI.
- وضع Trusted Admin Backend قبل Admin Web.
- إنشاء `V1_IMPLEMENTATION_SEQUENCE.md`.
- فتح م-37.
- نقل Resume Point إلى W1 Backend Foundations.

لم تنفذ Migration 078 بعد.

Baseline الاختبارات لم يتغير.

## 2026-08-19 — W1-01 / ق-110 prepared

تمت كتابة:

- Migration 078 Profile↔Person identity foundation.
- Permanent Test 078.
- ق-110.
- وثائق W1-01.

الحالة:

**Pending Owner Verification.**

لم يشغل AI:

- db:reset.
- db:test.
- Docker verification.

لم يتغير Baseline الرسمي بعد.

التالي:

Owner runs Migration/Test verification.

---

## 2026-08-19 — Supabase Cloud baseline synchronized

ثبت بالدليل:

- المشروع المحلي مرتبط بالمشروع السحابي الصحيح.
- Migrations 001–077 نُشرت إلى Supabase Cloud.
- Remote migration history = 76 migrations through 077.
- Data API exposed schemas صارت `api` + `graphql_public`.
- `public` لم يعد Exposed Schema.
- تغيير Auth غير المقصود أثناء `config push` أُعيد إلى قيم Cloud السابقة بنجاح.
- Migration 078 لم تُنشر ضمن هذه المزامنة.

## 2026-08-19 — W1-01 / ق-110 locally verified

Owner Verification:

- `db:reset` طبق `20260819200401_078_profile_person_identity_links.sql`.
- Permanent Test 078 = 18 PASS / 0 FAIL / 0 ERROR.
- Full DB Suite = 18 files / 235 PASS / 0 FAIL / 0 ERROR.
- Local Applied Baseline صار حتى 078.
- Cloud Applied Baseline بقي حتى 077.

التالي:

Documentation Gate → Commit/Push → Cloud deploy/verify 078 → W1-02.
