# المسائل المفتوحة

**آخر تحديث:** 2026-08-17

مسائل معروفة لم تُحسم بعد، لكنها **لا تمنع البدء**.
أي مسألة تُحسم تُنقل إلى `DECISIONS.md` برقم جديد ثم تُشطب من هنا.

---

## فهرس الحالة الحالية — 2026-08-17

هذا الفهرس هو المرجع السريع للحالة النهائية.
التحديثات القديمة أسفل الملف تحفظ كسجل زمني.

### مفتوحة فعليًا

- م-08: بيانات الجهة القانونية — قبل النشر.
- م-09: رابط سياسة الخصوصية العام — قبل Google Play.
- م-10: قناة حذف الحساب.
- م-11: تسمية مزودي الخدمة.
- م-12: مواءمة النص القانوني النهائي.
- م-14: صلاحية GitHub integration.
- م-16: Farmer RLS.
- م-18: ربط roles/permissions.
- م-19: مغلقة — ق-81 / 076؛ Pump equipment model/reporting/concurrency مصححة.
- م-21: اختبارات ميدانية.
- م-22: مغلقة — ق-80 / 075؛ Farm → Farmer Well Account.
- م-23: UI الإشعارات + scheduler عند النشر.

### مغلقة ذات صلة مباشرة بالحالة الحالية

- م-02: Supabase المحلي.
- م-03: Flutter/Android environment.
- م-04: إعادة بناء الهجرات.
- م-15: سياسات إدخال tenants/wells.
- م-17: فجوة نطاق قاعدة البيانات العامة.
- م-20: payments schema.
- م-24: Direct DML / RPC-only writes.

### ملاحظة

م-01 لم تعد فجوة قرار؛ ق-48/ق-77 حسمت القاعدة.
يبقى قياس الأثر الميداني في التذكير ت-04.


## م-01 — أثر إلغاء التقريب على الدخل لم يُقس بعد

**تحديث 2026-08-12 — مُغلقة كمسألة إفصاح:** عُرض الأثر المالي على المالك صراحةً ووافق على إبقاء الإلغاء (ق-48). **يبقى القياس الميداني مطلوبًا عبر ت-04.**

**الوصف:** ق-01 وق-12 يلغيان التقريب نهائيًا. هذا قرار عادل تجاه المزارع، لكنه **يخفّض الإيراد**.
**مثال موثّق:** 62 دقيقة شمس + 31 دقيقة ديزل كانت تُفوتر 120 دقيقة، وصارت 93 دقيقة. أي فقدان 27 دقيقة مفوترة في جلسة واحدة.
**لماذا مفتوحة:** النسبة الحقيقية للفقدان غير معروفة، والتقدير الأولي 10% أو أكثر **تخمين لا قياس**.
**ملاحظة أمانة:** لم يُعرض هذا الأثر المالي بوضوح كافٍ قبل اتخاذ ق-01.
**المطلوب:** قياس فعلي في التجربة الميدانية — ت-04.
**تأثيرها على البدء:** لا يوجد. البناء يمضي بلا تقريب.

---

## م-02 — `npx supabase start` لم يُثبت أبدًا

**الوصف:** أداة Supabase CLI مثبتة بالإصدار 2.111.0، وDocker مثبت، لكن **لم يُثبت أن الأمر يعمل فعليًا**.
**لماذا خطيرة:** كل خطة قاعدة البيانات مبنية على فرضية أن البيئة المحلية تعمل. إن لم تعمل، تتعطل 5 إلى 7 أيام من الخطة.
**المطلوب:** إثباته في المرحلة صفر قبل أي عمل آخر.
**الحالة:** مفتوحة — خطوة 4 في `RESUME_POINT.md`.

---

## م-03 — Flutter غير مثبت

**الوصف:** أمرا `flutter` و`dart` غير موجودين. متغيرا `ANDROID_HOME` و`ANDROID_SDK_ROOT` غير مضبوطين.
**المطلوب:** تثبيت كامل وإثبات نجاح `flutter doctor`.
**الحالة:** مفتوحة — خطوتا 2 و3 في `RESUME_POINT.md`.

---

## م-04 — الهجرتان الموجودتان لم يُثبت تطبيقهما

**الوصف:** يوجد ملفا هجرة مكتوبان لكن لا دليل على تطبيقهما على قاعدة بيانات حية.
**تفاصيلهما:** `MIGRATIONS.md`.
**المطلوب:** قرار عند المرحلة صفر: هل تُطبّق كما هي، أم تُعاد كتابتها وفق القرارات الـ 47؟
**الترجيح:** إعادة كتابتهما، لأنهما كُتبتا قبل ق-14 وق-21 وق-26.
**الحالة:** مفتوحة.

---

## م-05 — تنقيات وثائقية متبقية

**الوصف:** بعض المواضع في الوثائق المرجعية ما زالت تحمل نصوصًا قديمة مُعلمة بترويسة التحذير فقط، ولم تُعد صياغتها حرفيًا بعد.
**أمثلة:** قائمة النطاق الأدنى · معايير القبول · قاموس البيانات · مصفوفة مصدر الحقيقة.
**لماذا لا تمنع البدء:** ق-33 يحسم أي تعارض لصالح `DECISIONS.md`، والترويسة تنبّه القارئ.
**المطلوب:** تنظيف تدريجي أثناء البناء، كل قسم عند الوصول إليه.
**الحالة:** مفتوحة.

---

## م-06 — إصدارات أجهزة المشغلين غير معروفة

**الوصف:** ق-45 يحدد `minSdk 26` بناءً على المعقولية العامة، لا على فحص أجهزة المشغلين الفعليين.
**المطلوب:** سؤال المشغلين عن إصدار أندرويد قبل التجربة الميدانية.
**الحالة:** مفتوحة — بلا أثر على البدء.

---

## م-07 — التكلفة الشهرية غير متحققة

**الوصف:** تقدير قديم يذكر Supabase Pro بـ 25 دولارًا وPowerSync Pro بـ 49 دولارًا، أي 74 دولارًا شهريًا، وحساب مطور جوجل بلاي بـ 25 دولارًا مرة واحدة.
**لماذا مفتوحة:** الأرقام لم تُراجع من مصدرها الرسمي، والخطط المجانية قد تكفي النسخة الأولى بالكامل.
**المطلوب:** تحقق قبل دفع أي مبلغ.
**الحالة:** مفتوحة.

---

## م-08 — بيانات الجهة المشغلة غير محددة

**الوصف:** النصان القانونيان فيهما خمسة حقول مكتوب أمامها «يُحدد لاحقًا»: اسم الجهة · البريد · الهاتف · العنوان · تاريخ النفاذ.
**لماذا مفتوحة:** المالك لا يملك اسمًا تجاريًا مسجلًا ولا نطاقًا (إجابة السؤال 30).
**المقترح:** الاسم الشخصي «خالد النجحي» كجهة مشغلة فردية · البريد المخصص للمشروع (ق-44) · رقم واتساب مخصص · العنوان على مستوى المدينة فقط · تاريخ النفاذ = يوم أول رفع.
**الحالة:** مفتوحة — تُحسم قبل النشر، لا قبل البناء.

---

## م-09 — لا يوجد رابط عام لسياسة الخصوصية

**الوصف:** جوجل بلاي تشترط رابطًا عامًا يفتح بلا تسجيل دخول، ويعرض السياسة نفسها المذكورة في لوحة النشر. لا يوجد نطاق.
**المقترح:** صفحة مجانية على **GitHub Pages** باسم المشروع. مجانية دائمًا، تقبلها جوجل، ولا تحتاج نطاقًا مدفوعًا، وتُحدّث من نفس مستودع المشروع. يُربط بالنطاق الخاص لاحقًا إن اشتُري.
**الحالة:** مفتوحة — المستودع موجود، لكن ما زال يلزم رابط عام فعلي لسياسة الخصوصية قبل Google Play.

---

## م-10 — قناة حذف الحساب غير محددة

**الوصف:** البند 22.1 من الخصوصية يقول «وفق الإجراءات المعتمدة» دون تحديد الإجراء. جوجل بلاي تشترط مسارًا داخل التطبيق **ورابطًا خارجيًا** لطلب الحذف.
**المقترح:** زر «طلب حذف الحساب» في شاشة الإعدادات يرسل بريدًا جاهزًا للجهة المشغلة، زائدًا قسمًا في صفحة GitHub Pages نفسها. يُوضّح أن السجلات المحاسبية تُحفظ مجهّلة (مطابق للبند 22.2).
**الحالة:** مفتوحة — ميزة صغيرة تُبنى مع شاشة الإعدادات.

---

## م-11 — مزودو الخدمة غير مسميين في السياسة

**الوصف:** البند 19.3 يقول حرفيًا «سيتم توضيح مزودي الخدمات الرئيسيين في النسخة النهائية».
**ما صار معروفًا:** Supabase (استضافة وقاعدة بيانات ومصادقة وتخزين) · PowerSync (مزامنة) · Firebase (إشعارات وتقارير أعطال). جميعها خارج اليمن.
**لماذا يهم:** نموذج «أمان البيانات» في متجر جوجل يجب أن يطابق السياسة حرفيًا، والتناقض سبب رفض متكرر.
**الحالة:** مفتوحة — تُملأ في النسخة النهائية من النص.

---

## م-12 — تسع نقاط مواءمة بين النص القانوني والقرارات

**الوصف:** ليست أخطاء، لكن النص أعمّ من القرار فيها. التفاصيل الكاملة في `legal/LEGAL_REVIEW.md` قسم 5.
**أهمها ثلاث:** تأكيد السعر عند بداية الجلسة (ق-02) · تجميد السعر بعد البدء (ق-20) · اشتراط مجموع النسب 100% (ق-03).
**وأخطرها واحدة:** البند 16.2.1 قد يُقرأ على أن المزارع يصله إشعار، والنسخة الأولى لا ترسل للمزارع شيئًا (ق-36).
**الحالة:** مفتوحة — تُنفذ دفعةً واحدة عند إعداد النسخة النهائية.

## م-02 — اغلاق بتاريخ 2026-08-13
**الحالة:** مغلقة نهائيا، تشغيل Supabase محليا تحقق منه عمليا، جميع الخدمات عملت والمخططات التسعة موجودة.

## م-03 — اغلاق بتاريخ 2026-08-13
**الحالة:** مغلقة نهائيا، تطبيق فلاتر فعلي بني وثبت وشغل بنجاح على جهاز اندرويد حقيقي SM-A136U، وطرفية flutter doctor نظيفة تماما بلا اي تحذير.

## م-14 — اداة الربط بـ GitHub لا تملك صلاحية العمل داخل منظمات جديدة تلقائيا
**الوصف:** محاولة انشاء مستودع عبر اداة الربط المتصلة فشلت بخطا 403 داخل منظمة well-irrigation رغم ان المالك الفعلي يملك صلاحية كاملة.
**لماذا مفتوحة:** لم يحدد بعد ان كانت اداة الربط تحتاج اذنا اضافيا صريحا لكل منظمة جديدة تنشا مستقبلا.
**المقترح:** عند الحاجة لعمليات مستقبلية عبر الاداة داخل هذه المنظمة، توقع احتمال تكرار نفس الخطا واعتمد الانشاء اليدوي كخطة بديلة جاهزة.
**الحالة:** مفتوحة، بلا اثر عملي حاليا لان الحل البديل نجح فورا.

## م-04 — إغلاق بتاريخ 2026-08-13
**الحالة:** مغلقة نهائيًا. نُفذ الترجيح المذكور فيها حرفيًا (ق-51 وق-57): أُعيد بناء الهجرتين من الصفر بالكامل، وطُبّقت 25 هجرة جديدة محليًا وتحقق منها بالفحص المباشر مرارًا عبر `npx supabase db reset`.

## م-15 — سياسات إدخال مفتوحة مؤقتًا على core.wells وcore.tenants
**الوصف:** سياسة INSERT الحالية على `core.wells` و`core.tenants` مفتوحة لأي مستخدم `authenticated` بلا قيد دور، كتبسيط مؤقت لعدم وجود تدفق تسجيل مستأجر/منظمة فعلي بعد.
**المطلوب:** تضييق هذه السياسة بربطها بتدفق تسجيل منظّم قبل الإطلاق العام.
**الحالة:** مغلقة — 2026-08-14 عبر 064 وق-77؛ أزيلت سياسات الإدخال المفتوحة واستُخدم تدفق التهيئة المقيد.

## م-16 — نطاق رؤية المزارع على مستوى البئر كامل لا مستوى المزرعة
**الوصف:** سياسات RLS الحالية تمنح المزارع رؤية كل مزارع/جلسات البئر الذي يتبعه، لا مزرعته فقط، لأن الفحص الحالي دور على مستوى البئر لا مستوى المزرعة المحدد.
**لماذا مفتوحة:** تبسيط مقصود لتسريع مرحلة قاعدة البيانات (طلب المالك)، وليس سهوًا.
**الحالة:** مفتوحة — بلا أثر على البدء.

---

## م-17 — فجوة موثّقة بين النطاق المعتمد للنسخة الأولى (قسم 55) وما بُني فعليًا في قاعدة البيانات
**التاريخ:** 2026-08-13
**الاكتشاف:** بمقارنة مباشرة بين قسم 55 «النطاق المعتمد للنسخة الأولى MVP» في `01_functional_reference.md` وبين الـ25 هجرة الفعلية (16 جدولًا فقط)، تبيّن أن معظم البنود المعتمدة صراحة للنسخة الأولى **لم تُبنَ بعد**، وهي ليست من بنود التأجيل (قسم 56/60/قسم 54 في ERD).

**مبني فعليًا (16 جدولًا):** الآبار، المضخات، إعدادات البئر، شركاء ونسب ملكية مبسّطة، الأراضي، الجلسات (بلا مقاطع)، التسعير والفوترة المبسّطة، الدفعات، الديزل (مشتريات فقط)، توزيع الأرباح، الإشعارات الجزئية (3 من 5).

**معتمد للنسخة الأولى ولم يُبنَ (فجوة حقيقية):**
1. الحجوزات وجدولة الأدوار (`irrigation_bookings`, `booking_status_history`, `resource_reservations`, تبديل الأدوار).
2. منع تكرار المزارعين (بطاقة شخص موحدة، أسماء بديلة، وسائل تواصل، فحص تكرار).
3. مقاطع الجلسة (تبديل مصدر الطاقة شمس/ديزل/مختلط داخل الجلسة نفسها).
4. الصندوق وحركاته وفرق الجرد.
5. المصروفات وقواعد اعتمادها وموافقاتها (غير الديزل).
6. النوبات وتسليمها بين المشغّلين.
7. الرواتب الأساسية.
8. الديون القديمة والأرصدة الافتتاحية.
9. دفتر الحسابات المزدوج (دليل حسابات، قيود يومية، أطراف قيد).
10. الفواتير الرسمية وتخصيص الدفعات الجزئية.
11. احتياطي الصيانة (خصم تلقائي قبل التوزيع، رغم ذكره في ق-27).
12. الفترات المحاسبية والإقفال الرسمي.
13. سجل التدقيق (`audit_logs`).
14. المزامنة والعمل دون إنترنت (`outbox`, `processed_commands`, `sync_conflicts`).
15. الاشتراك التجاري للمنصة (خطط واشتراكات العملاء).
16. المرفقات (إيصالات وصور).
17. الخطوط المتعددة وربطها بالمضخات (`water_lines`, `pump_line_links`).

**مؤجل رسميًا بقرار موثّق (ليس فجوة، للتوضيح فقط):** حساب دخول مستقل للمزارع، iPhone، SMS آلي، واتساب Business API، الحساسات، عداد المياه الذكي، تشغيل المضخة عن بعد، خرائط متقدمة، التنبؤ بالأعطال، تحليل استهلاك ذكي، عملات متعددة ظاهرة، خصومات يدوية، تكامل محاسبي خارجي، وطريقة توزيع تكلفة التدفق المشترك بين عدة مزارعين (البنية تدعمها والتشغيل المشترك معطل افتراضيًا، وهذا مطابق للمبني فعليًا).

**الحالة:** مغلقة — بتقييمين: تدقيقنا الأول (بنيوي) ثم تدقيق Codex السلوكي 2026-08-14؛ صحّح الأخير مبالغة النص السابق: الجداول والسلوكيات الأساسية بُنيت فعلا، وتبقّت طبقة الإجراءات المسماة والاختبارات الدائمة — حُسمتا في ق-77 (تُبنى في 066 و067).

- 2026-08-14 — تقييم ختامي وإغلاق: بنود م-17 السبعة عشر بُنيت كلها (13 سابقًا + التدقيق والمزامنة والمرفقات والتقارير في 057–060)؛ الاشتراكات مؤجلة بقرار ق-10؛ تُغلق م-17 وتُنقل الاختبارات الميدانية المتبقية إلى م-21.

## تحديث م-17 بتاريخ 2026-08-13 — تقدّم كبير
**الحالة وقت هذا التحديث التاريخي:** نشطة جزئيًا (تراجعت من فجوة شاملة الى فجوة واحدة محددة).
**ما استُكمل:** المرحلة 1 كاملة (persons/roles/permissions/locations) عبر ق-68.
**المتبقي ضمن هذه المسألة:** المراحل 2 الى 6 من ترتيب البناء الموثّق (التشغيل، المال، الديزل والمصروفات، الشركاء المتبقي، الإدارة) — التفاصيل والترتيب في `RESUME_POINT.md`.

## م-18 — كتالوج الأدوار والصلاحيات غير مربوط بنظام الأدوار الحالي
**الوصف:** جداول `iam.roles`/`iam.permissions`/`iam.role_permissions` (ملف الترحيل 028) كتالوج تأسيسي فقط. لا تُستخدم حاليًا في أي سياسة RLS، ولا في فحص الأدوار الفعلي القائم على `core.well_assignments.role` (owner/operator/farmer كنص مباشر).
**لماذا مفتوحة:** ربطها يتطلب مراجعة أكثر من 15 سياسة RLS مطبّقة ومختبرة فعليًا حاليًا — قرار منفصل متعمّد لتجنّب المساس بمنطق يعمل.
**الحالة:** مفتوحة — بلا أثر على البدء أو التجربة الميدانية المحدودة.

## تحديث م-17 بتاريخ 2026-08-13 (بعد المرحلة 2) — تقدّم إضافي
**الحالة وقت هذا التحديث التاريخي:** نشطة جزئيًا (تراجعت أكثر).
**ما استُكمل الآن:** المرحلة 2 كاملة (التشغيل: خطوط المياه، ملفات المزارعين، التسعير، الحجوزات، حجز الموارد، مقاطع الجلسة) عبر ق-69.
**المتبقي ضمن هذه المسألة:** المراحل 3 إلى 6 من ترتيب البناء الموثّق (المال، الديزل والمصروفات، الشركاء المتبقي، الإدارة) — التفاصيل والترتيب في `RESUME_POINT.md`.

## م-19 — جدول core.pumps لا يطابق كامل مخطط §13.1
**الوصف:** جدول `core.pumps` (من الهجرة 005 الأصلية) يحتوي فقط `id`/`well_id`/`name`/`power_source`/`status`/`created_at`/`updated_at`. مخطط §13.1 في `03_implementation_schema.md` يذكر أعمدة إضافية لم تُضف بعد.
**لماذا مفتوحة:** لم تُعدَّل `core.pumps` أثناء بناء المرحلة 2 لتجنّب توسيع نطاق العمل الحالي دون تأكيد المالك؛ الأثر الحالي محدود لأن دالة `ops.reserve_resource()` تُعامل المضخات بحد أقصى توازي 1 دائمًا كإجراء مؤقت.
**الحالة التاريخية عند فتحها:** كانت مفتوحة بانتظار القرار.

## تحديث م-17 بتاريخ 2026-08-13 (بعد المرحلة 3) — تقدّم إضافي
**الحالة وقت هذا التحديث التاريخي:** نشطة جزئيًا.
**ما استُكمل الآن:** المرحلة 3 كاملة (المال: دليل الحسابات، القيود اليومية وأطرافها، الفواتير وبنودها، تخصيص الدفعات) عبر ق-70.
**المتبقي ضمن هذه المسألة:** المراحل 4 إلى 6 (الديزل والمصروفات، الشركاء، الإدارة).

## م-20 — مخطط billing.payments المبني يخالف §28 من الوثيقة التنفيذية
**الوصف:** الجدول المبني (الهجرة 011) يربط الدفعة برسم جلسة واحد (`session_charge_id`, `amount_milli`, ثلاث طرق دفع)، بينما §28 يصفه مربوطًا بحساب المزارع في البئر (`tenant_id`, `public_code`, `well_id`, `farmer_well_account_id`, `payer_person_id`, `amount_minor`, ست طرق دفع، `cashbox_id`, `status`, `reversed_payment_id`).
**الأثر العملي:** الدفعة الحالية لا يمكن أن تُغطي أكثر من جلسة، ولا تدعم الدفع المقدم أو التسوية من أرباح شريك، رغم أن `payment_allocations` (الهجرة 038) يدعم توزيع الدفعة على عدة فواتير.
**لماذا مفتوحة:** الجدول مطبّق ومُختبر ومرفوع وله زناد فعّال مختبَر (`payments_not_exceed_charge_check`)؛ توسيعه أو ترحيل بياناته قرار مالك، لا تعديل صامت.
**الخيارات المطروحة:** (أ) هجرة توسيع تُضيف الأعمدة الناقصة وتُلغي إلزام `session_charge_id` مع تحديث الزناد؛ (ب) إبقاء الجدول للتحصيل على مستوى الجلسة وبناء طبقة دفعات على مستوى الحساب بجدول منفصل؛ (ج) القبول بالوضع الحالي للنسخة الأولى.
**الحالة وقت هذا التحديث التاريخي:** كانت مفتوحة قبل المرحلة 4؛ أُغلقت لاحقًا في تحديث م-20.

---
- 2026-08-14: تصحيح نص الإغلاق — قيم الغرض الفعلية في القيد هي: session و old_debt و advance (وليس session_payment و other كما كُتب خطأ في نص الإغلاق).

## تحديث م-20 — مقفلة (2026-08-13)

كانت: الدفعة مرتبطة الزاميا بجلسة سقي. الحل في الهجرة 043: session_charge_id اختياري، واضيف purpose بقيم session_payment و old_debt و advance و other، مع cashbox_id والمفتاح fk_payment_cashbox وقيد يمنع خلط الدين القديم بجلسة. التحقق: PASS 9 الى PASS 12.

## م-21 — الاختبارات الميدانية المتبقية (مرحلة التطبيق)
- الحالة: مفتوحة.
- دمج الأشخاص المتكررين، تعارض جهازين على نفس البيانات، تصحيح فاتورة بعد إقفال الفترة — تُختبر عند ربط تدفقات التطبيق بها في المرحلة 7.

## م-13 — ملاحظة ترقيم
- الحالة: مغلقة — الرقم لم يُستخدم إطلاقا (تخطٍّ تاريخي غير موثق، اكتشفه تدقيق Codex في 2026-08-14)؛ لا يُعاد استخدامه حفاظا على التسلسل الزمني للسجل.

## م-22: ربط الأرض بملف المزارع الميداني بدل ملف الدخول
- **الحالة:** مفتوحة (2026-08-15) — القرار قبل تصميم شاشة الأراضي في مرحلة التطبيق.
- **الوصف:** حقل مالك الأرض في ops.farms يشير حاليا الى ملف دخول مستخدم، بينما كثير من المزارعين بلا دخول اصلا. المقترح البنيوي (من Codex، غير منفذ): ربط الأرض بحساب المزارع في البئر او بملف المزارع الميداني. اجراء 069 اتبع البنية القائمة حرفيا واشترط تعيينا نشطا بدور مزارع.
- **الأثر الحالي:** غير مانع؛ المسار المباشر في الجدول بقي كما كان، والاختبارات خضراء.

## م-23: مرسلا التنبيهين الدوريين (الملخص اليومي + مراقب حد الدين)
- **تصحيح ترقيم (2026-08-15):** قُيد هذا الموضوع خطأ برقم م-08 المتعارض مع م-08 القانونية (بيانات الجهة المشغلة، ت-03)؛ أُعيد ترقيمه م-23. تعليقات هجرة 070 واختبارها قد تشير للرقم القديم — وهي تعني هذا الموضوع.
- **الحالة:** المنطق منفذ ومختبر بالكامل (070، في 2026-08-15) — تبقى علامتان موثقتان لا نسيان لهما: الظهور للمستخدم في المرحلة 7، والتفعيل الدوري في بند النشر الالزامي «تفعيل المجدول».
- **الوصف:** ثلاثة من تنبيهات ق-34 الخمسة تولد بالاحداث (جلسة منسية، وقود يقترب، توزيع مكتمل)، والباقيان (الملخص اليومي، مراقب حد الدين) يحتاجان ميقاتا دوريا لانهما «حراس ساعة» لا «حراس حدث».
- **القرار (2026-08-15):** بناء المنطق فورا بهجرة 070 مع اختبارات دائمة، وترحيل المجدوُل فقط الى النشر.
- **مواعيد الاقفال الملزمة:** (1) الليلة: المنطق مبني ومختبر. (2) المرحلة 7: شاشة التنبيهات + قناة الاشعارات الفورية تُظهران الاثر للمستخدم. (3) النشر: بند الزامي باسم «تفعيل المجدول» — flag_long_running_sessions كل 30 دقيقة، send_daily_summaries يوميا بعد نهاية اليوم، check_debt_thresholds يوميا — ولا يُعلن النشر مكتملا دون تنفيذه والتحقق منه.

---

## م-24 — إغلاق Direct DML وتطبيق RPC-only writes

**الوصف:** تدقيق الشرط الثاني من بوابة جاهزية المرحلة 7 كشف أن `authenticated` ما زال يملك صلاحيات كتابة مباشرة واسعة على جداول الأعمال الداخلية رغم إغلاقها عن Data API بق-78.

**القرار المرتبط:** ق-79.

**خطة المعالجة:** الهجرة 072 تسحب Direct DML من `anon` و`authenticated` مع إبقاء القراءة وتنفيذ إجراءات الأعمال الحالية.

**الحالة:** مغلقة — 2026-08-17. Direct DML=0 وعقد api الحرج مثبت حتى 074.

## تحديث تاريخي لم-22 — ق-80 / 075 قبل القبول

**الحالة التاريخية في هذه النقطة:** كانت مفتوحة أثناء التحقق.

حُسم القرار البنيوي بق-80:

- الأرض ترتبط بـ`farmer_well_account_id`.
- Login Profile لم يعد هوية المزارع المسؤول عن الأرض.
- Booking/Session يجب أن يطابقا حساب الأرض.
- `api.create_farm` يُكشف فقط ضمن 075.

كان شرط الإغلاق هو إثبات 075 وحزمة الاختبارات وData API؛ تحقق الشرط وأُغلقت م-22 في 2026-08-17.

### الحالة النهائية لم-22 — 2026-08-17

**مغلقة.**

أثبتت 075:

- `ops.farms.farmer_well_account_id` بدل Login Profile.
- المزارع الميداني لا يحتاج حساب دخول.
- Farm/Well/Farmer Account consistency مثبتة بقيود قاعدة البيانات.
- الحجز والجلسة يرفضان Farm/Account mismatch.
- `api.create_farm` أصبح ضمن العقد المعتمد.
- Direct DML بقي صفرًا.
- Surface المعتمد أصبح 32 RPC.

إثبات المالك:
`FILES=15 PASS=193 FAIL=0 ERROR=0`.

## تحديث تاريخي لم-19 — ق-81 / 076 قبل القبول

**الحالة التاريخية في هذه النقطة:** كانت قيد التحقق — 2026-08-17.

كشف التدقيق أن م-19 ليست نقص Metadata فقط:

- `core.pumps` ما زال على النموذج القديم.
- التقرير الحالي يستخدم `pump.power_source` رغم أن الجلسة قد تغير المصدر عدة مرات.
- `reserve_resource()` ما زالت تستخدم حد المضخة الثابت 1 رغم وجود `resource_concurrency_rules`.

حُسم التصميم بق-81 ونُفذ المرشح في Migration 076.

كان شرط الإغلاق نجاح reset والحزمة الكاملة واختبار 076؛ تحقق الشرط وأُغلقت م-19.

### الحالة النهائية لم-19 — 2026-08-17

**مغلقة.**

أثبتت ق-81 / Migration 076:

- `core.pumps` أصبح نموذج بيانات المعدة المرجعي.
- `tenant_id` و`public_code` والـequipment metadata أصبحت ضمن المخطط.
- `maintenance` و`retired` حالتان معتمدتان.
- `power_source` أصبح Legacy compatibility nullable فقط.
- مصدر الطاقة التشغيلي الرسمي هو `ops.session_segments.energy_source`.
- `well_daily_summary` يحسب Solar/Diesel من المقاطع الحديثة.
- الجلسات التاريخية `flat` بلا مقاطع تحتفظ بالـlegacy fallback.
- `reserve_resource()` أصبح يحترم `resource_concurrency_rules`.
- Direct DML بقي صفرًا.

إثبات المالك:

`FILES=16 PASS=205 FAIL=0 ERROR=0`.

العداد:

`75 migrations / 16 permanent tests`.

---

## م-25 — Offline Android Background Sync

**الحالة:** مفتوحة — 2026-08-18
**القرارات الحاكمة:** ق-89، ق-90
**الأولوية:** حرجة لـStage 7 الميداني

### المطلوب

تنفيذ وإثبات:

- Local durable database.
- ordered outbox.
- stable command IDs.
- idempotent API replay.
- Offline irrigation lifecycle.
- Offline advance/payment where used.
- Inline farmer/farm Offline create.
- dependency mapping.
- historical pricing resolution.
- time integrity handling.
- WorkManager/background execution.
- retry/backoff.
- reboot recovery.
- device readiness.
- separate Offline/Background/Notification readiness.
- sync summary and pending queue UX.
- transient vs conflict classification.
- per-session sync badge.
- manual sync as secondary action.
- reminder deduplication.
- Force Stop recovery UX.
- manufacturer guidance only after validation.
- notification integration.
- conflict UX.
- field tests في مناطق ضعيفة أو معدومة التغطية.

### لا يغلق قبل

إثبات سيناريو Offline كامل يبدأ وينتهي ثم يتزامن
دون فتح واجهة التطبيق عند سماح Android، مع عدم وجود
Duplicate أو Data Loss.

Force Stop / Restricted Mode يجب أن يكونا موثقين
ومعروضين للمستخدم بوصفهما حدود منصة لا يمكن تجاوزها
بصورة مضمونة.

---

## م-26 — Active Session Contract and Billing Consistency

**الحالة:** مفتوحة — 2026-08-18
**القرار الحاكم:** ق-91
**UX:** UX-11
**الأولوية:** حرجة قبل تنفيذ شاشة الجلسة الإنتاجية

### التعارض المالي

ق-17 يفرض:

- Diesel inclusive hourly billing.
- الوقود تكلفة/رقابة فقط.
- لا Fuel Billing منفصل للمزارع.

Migration 066 الحالية يمكن أن تجمع `fuel_charge_minor`
داخل إجمالي Session Charge.

يجب تصحيح التنفيذ في Migration 078+ أو أحدث،
ولا تعدل Migration 066 نفسها.

### فجوات العقد

- Active Session Read Contract.
- Pause Detail Reason.
- Atomic Resume With New Energy.
- إثبات Complete While Paused.
- Live Accrued Amount inputs.
- Payment/Advance reconciliation.
- Offline idempotent session actions.

### لا تغلق قبل

- اختبار أن الوقود لا يضاف فوق السعر الشامل.
- اختبار Live Amount = Completion policy.
- اختبار Completion = Invoice policy.
- اختبار Pause/Resume/New Energy.
- اختبار Complete From Pause.
- اختبار Offline replay دون duplicate.
- Android process death/reboot verification.

---

## م-27 — Session Completion and Settlement Orchestration

**الحالة:** مفتوحة — 2026-08-18
**القرار الحاكم:** ق-92
**UX:** UX-12
**الأولوية:** حرجة قبل تنفيذ التسوية الإنتاجية

### المطلوب

- Settlement Orchestration موحد.
- Idempotent settlement command.
- Complete/Charge/Invoice consistency.
- One active invoice per session.
- Session-linked payment association.
- Automatic one-time payment allocation.
- Excess payment remains advance.
- Old unrelated advance not silently consumed.
- Offline completion reconciliation.
- Final settlement read model.
- Conflict handling.
- Notification deduplication.
- Audited correction path.

### الاعتماد على م-26

لا تغلق م-27 قبل إغلاق تعارض Fuel Billing في م-26،
لأن Final Amount وInvoice يجب أن يطبقا ق-17 وق-91.

### لا تغلق قبل

- retry after lost response produces one settlement.
- one invoice only.
- one payment allocation only.
- final amount equals invoice total.
- paid + outstanding equals invoice total.
- overpayment leaves correct advance.
- Offline completion reaches same canonical result.
- no data loss after Process Death/Reboot.
- permanent Backend and Android tests.

---

## م-28 — Operations Records, Booking and Handover Consistency

**الحالة:** مفتوحة — 2026-08-18
**القرار الحاكم:** ق-98
**UX:** UX-13
**الأولوية:** حرجة قبل UX-13 الإنتاجية

### الأساس الموجود

- Booking tables/status history موجودة.
- Resource reservation foundation موجودة.
- Farmer/Farm consistency موجودة بق-80/075.
- Shift/session transfer موجود.
- Shift reports موجودة.
- Critical shift API wrappers موجودة.

### الفجوات

1. لا يوجد حتى الفحص الحالي Booking Contract مكتمل
   ومخصص لـFlutter داخل `api.*`.

2. Booking mutation وStatus History وResource Reservation
   ليست موثقة كعملية ذرية واحدة.

3. Offline Booking Confirmation وConflict Reconciliation
   غير منفذين.

4. Stable Command ID للحجوزات والتغييرات غير مثبت.

5. Session History Read Model المطلوب لـUX-13 غير موجود.

6. Farmer/Farm list/detail typed read contracts المطلوبة
   للواجهة غير مكتملة.

7. Farmer deactivation/archive contract يحتاج فحصًا أو
   تنفيذًا؛ Hard Delete مرفوض.

8. Operational Handover Summary غير موجود كعقد واضح.

9. Cash Handover الحالي يجب ألا يخلط مع Operational
   Responsibility Transfer.

10. `api.close_shift(..., p_allow_open_sessions=true)`
    يسمح للمالك حاليًا بتجاوز الجلسات المفتوحة.

11. هذا التجاوز يتعارض مع ق-98 للمسار العادي ويجب منعه
    عن Flutter في Migration 078+.

12. Shift/session transfer Offline idempotency غير مثبتة.

### لا تغلق قبل

- Booking API contract tests.
- atomic booking/history/reservation tests.
- two-device booking conflict test.
- booking retry/idempotency test.
- historical inactive entity visibility test.
- no-hard-delete behavior.
- no-orphan active session test.
- receiver accept/reject transfer tests.
- no normal owner bypass through app contract.
- Offline process death/retry tests.
- permission tests.
- no Direct DML verification.

---

## م-29 — Money, Partner Distribution and Financial Correction Consistency

**الحالة:** مفتوحة — 2026-08-18
**القرار الحاكم:** ق-99
**UX:** UX-14
**الأولوية:** حرجة قبل UX-14 الإنتاجية

### الأساس الموجود

- Payment/Allocation procedures موجودة.
- Payment API wrappers موجودة.
- Expense/Approval foundation موجودة.
- Partner model موجود.
- Historical ownership/profit shares موجودة.
- Partner irrigation policy موجودة.
- Profit distribution engine موجود.
- Partial/full partner payout موجود.
- Accounting periods/reopen flow موجود.

### الفجوات

1. Farmer financial Read Model المخصص للتطبيق ناقص.

2. Invoice/Payment/Advance typed read contracts المطلوبة
   للـUX غير مكتملة.

3. Payment Offline Command ID/idempotency تعتمد على م-27
   ولم تغلق بعد.

4. عرض Pending Payment ومنع Duplicate collection يحتاج
   عقد Reconciliation واضح.

5. old Advance يجب أن يظل explicit allocation، وليس
   silent netting.

6. `finance.expenses.attachment_skip_reason` موجود،
   لكن `api.record_expense` لا يمرر السبب حاليًا.

7. Expense Offline idempotency غير مثبتة.

8. Partner financial projection يحتاج Least-Privilege
   Read Model.

9. Distribution list/detail/preview typed read models ناقصة.

10. استخدام `round()` في Maintenance Reserve النسبي
    يحتاج مراجعة مقابل السياسة المالية الحاكمة قبل Production.

11. Typed correction/reversal contracts المطلوبة لـFlutter
    غير مكتملة أو تحتاج إثباتًا.

12. Financial Audit Trail للمستخدم يحتاج Read Model.

13. Unknown-delivery financial reconciliation يحتاج عقدًا
    يمنع Retry أو Reversal الخاطئ.

### الاعتماديات

م-29 تعتمد جزئيًا على:

- م-26 عند اتساق Final Session Amount.
- م-27 عند Payment/Settlement idempotency.
- ق-79 عند منع Direct DML.
- ق-89 عند Offline Outbox.
- ق-92 عند Session-linked settlement.

### لا تغلق قبل

- debt/advance separation tests.
- explicit advance allocation tests.
- payment idempotency tests.
- no duplicate collection.
- canonical receipt test.
- attachment skip reason preservation.
- expense approval/rejection tests.
- partner-paid accounting test.
- historical share-version tests.
- partner privacy tests.
- distribution exactness tests.
- no duplicate receivable/deduction tests.
- rounding-policy regression test.
- partial/full partner payout tests.
- closed-period tests.
- correction/reversal audit tests.
- Offline unknown-delivery reconciliation.
- no Direct DML verification.
- Android process-death/retry tests.

---

## م-30 — Well Configuration, Pricing, Fuel & Reporting Consistency

**الحالة:** مفتوحة — 2026-08-19
**القرار الحاكم:** ق-100
**UX:** UX-15
**الأولوية:** حرجة قبل UX-15 الإنتاجية

### الأساس الموجود

- Pump equipment model موجود في 076.
- Session Segments هي Energy Authority الحديثة.
- Fuel Tanks/Transactions موجودة.
- Price Schedules/Rules موجودة.
- Reporting Views موجودة.
- Well Daily Summary موجودة.
- API foundation موجودة.

### الفجوات

1. Well/Pump typed read/write contracts للواجهة تحتاج
   استكمالًا.

2. Safe state transition للبئر والمضخة مع Active Session
   يحتاج عقدًا مثبتًا.

3. `operation_plus_fuel` ما زال موجودًا في Price Rules
   القديمة رغم أن V1 تعتمد Inclusive Hourly.

4. Price version/snapshot contracts المطلوبة للواجهة
   تحتاج إثباتًا أو استكمالًا.

5. Fuel Read Models المطلوبة للواجهة ناقصة.

6. Fuel adjustment/reconciliation typed contract يحتاج
   إثباتًا أو تنفيذًا.

7. Fuel Offline Command Idempotency غير مكتملة.

8. Reporting `api.*` Read Models الخاصة بـFlutter ناقصة.

9. Chart aggregation contracts غير موجودة بعد كعقد عام
   للواجهة.

10. Timezone/Day Boundary في التقارير يحتاج Audit صريحًا.

11. Partner report projection يحتاج Least Privilege.

12. Stale/Offline report metadata يحتاج عقدًا واضحًا.

### الرسوم المطلوبة في V1

- Irrigation hours by day.
- Collections vs expenses.
- Energy hours by source.
- Fuel consumption trend.
- Pump usage.
- Operator usage.
- Partner own-profit trend.

### لا تغلق قبل

- well/pump transition tests.
- modern energy attribution tests.
- legacy fallback tests.
- inclusive diesel contract tests.
- historical price tests.
- fuel balance/reconciliation tests.
- fuel retry/idempotency tests.
- timezone report tests.
- report/source-total reconciliation.
- chart-series tests.
- partner privacy tests.
- Offline/Stale tests.
- no Direct DML verification.
- Android rendering/field tests.

---

## م-31 — Identity, Access, Settings & Local Account Consistency

**الحالة:** مفتوحة — 2026-08-19
**القرار الحاكم:** ق-101
**UX:** UX-16A
**الأولوية:** حرجة قبل UX-16A الإنتاجية

### الفجوات

1. Phone Change contract يحتاج Trusted orchestration.

2. Lost-phone recovery يحتاج Admin/Support flow.

3. Forgot Password V1 يحتاج عقدًا كاملًا.

4. م-18 Role Authority لم تغلق بعد.

5. Operator/Partner access lifecycle يحتاج typed contracts.

6. Local storage يحتاج Account Scope مثبتًا.

7. Logout with Pending Outbox يحتاج Android tests.

8. Global session invalidation يحتاج عقدًا واضحًا.

9. Notification preferences تحتاج persistent contract.

10. English Date/Time formatting يحتاج UI consistency tests.

### لا تغلق قبل

- Auth security tests.
- unique phone tests.
- account isolation tests.
- pending outbox persistence.
- role lifecycle tests.
- lost-phone recovery tests.
- device/session invalidation tests.
- Android rendering tests.
