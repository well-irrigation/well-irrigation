# R6-C0.2 — سلطة اقتصادية واحدة لقيمة الدفع

> الحالة الحاكمة الحالية: ADOPTED + DOCUMENTED + IMPLEMENTED + VERIFIED LOCAL + COMMITTED في `9b1885a331083a4e4b1828c6ffb6744e5598e383`. تحقق المالك السابق ثم انحدار C2/C3؛ Pending أدناه تاريخي. المرجع الحالي: `../memory/RESUME_POINT.md`.

الحالة: Implemented / Static reviewed / Owner DB Verification Pending.
HEAD: `2478c4eb0698e243c09883051352684724c54f5c`.
الفرع: `reconcile/q137-local-20261030`.
ملفات البداية الأربعة المتسخة متوقعة ومحفوظة؛ لا تعديل للهجرات المتحققة.
لا DB أو Docker أو Supabase أو شبكة أو نشر أو Git mutation من الوكيل.

## القرار الحاكم وحدود الحزمة

قرار المالك: PAYMENT_VALUE_HAS_ONE_ECONOMIC_AUTHORITY=YES.
رابط session_charge_id هو الوجهة الأصلية الافتراضية؛ allocation نقل
صريح من القيمة نفسها، وليس قيمة ثانية. الروابط التاريخية المزدوجة
صالحة وتفسر بالمعادلة الجديدة دون UPDATE/DELETE للقبض أو التخصيص.
هذا ينسخ مانع اختيار السلطة السابق توثيقيًا؛ لا يعني DB Verified.
لا session_corrections/revision/time API أو إعادة تسعير/مقاطع/رسوم أو
فروق توزيع جلسة، ولا Flutter أو SQLite.

## الأصل الدائم والهوية

payments.id هو أصل كل مبلغ قبض. purpose=session مع session_charge_id
يشير إلى charge واحد، ومنها session_id. amount_minor هو الجزء الفعلي
بعد التقسيم الأصلي إلى session/advance؛ ليس بالضرورة كل مبلغ أمر القبض.
payment_allocations يحدد مكونات النقل إلى فواتير، ويمكن أن تستهدف جلسات
أخرى في البئر/الحساب نفسيهما. لا ندّعي انتماء كامل السند لدين واحد.
السند/تاريخه/مبلغه ونتيجة processed_commands الأصلية لا تعاد كتابتها.
هوية الوجهة والجهة والبئر والحساب والغرض تُحمى بعد الترحيل؛ charge لا
يعاد ربطه بجلسة أخرى بعد أن أشار إليه قبض تاريخي.

## المعادلة المركزية

الطبقات، كلها SECURITY INVOKER:

1. invoice_explicit_settlements: تسديد صريح من التخصيص الفعال وتطبيق
   الائتمان الفعال ومكون C0 التاريخي nonallocation_paid_minor؛ لا يجمع
   الدفع الخام مرة أخرى. تخصيص دفع معكوس لا يبقى تسديدًا حاليًا.
2. default_session_debts: الدين الحالي من فاتورة سارية صادرة إن وجدت،
   وإلا charge؛ يطرح التسديد الصريح قبل حساب الوجهة الافتراضية.
3. payment_partition_inputs: E للتخصيص الفعال، C للرصيد الصادر المحجوز
   من السند (amount - reversed، بما فيه مستخدمه/محجوزه)، والسعة P-E-C.
4. payment_economic_applications: يوزع سعة الدفع على الوجهة الافتراضية
   ضمن متبقي الدين، ويعرض المتبقي غير المستخدم منفصلًا.
5. session_economic_settlements وinvoice_effective_balances ثم عرض
   farmer_account_balances: التسديد والدين الحاليان من تلك الطبقات فقط.

لكل سند posted:

`P = E + D + C + R`، وكل مكون >=0.

E=explicit_allocated_minor، D=effective_direct_minor،
C=credit_backed_minor، R=remaining_minor.
C ليس مبلغًا إضافيًا: يظل محجوزًا من الأصل حتى لو استُخدم رصيده في
فاتورة أخرى؛ لا يجوز صرفه أيضًا من السند الأصلي. C0 يعرض المستخدم
والمتاح والمراجعة داخل الرصيد نفسه، دون خصمه مرة ثانية من P.

الهوية الافتراضية من payment/charge، لا من مبلغ دين قابل للتصحيح.
D=min(سعة السند، متبقي دين الوجهة بعد التسديدات الصريحة والسعات السابقة).
إذا اشترك أكثر من قبض في الوجهة، يكون الترتيب paid_at ثم payment_id
ثابتًا (الأقدم أولًا)، لا ترتيب تنفيذ/updated_at. السعة غير اللازمة
تبقى R بهوية السند الأصلي، ولا تنشئ نقدًا أو سند advance جديدًا.
هوية فاتورة الجلسة من session_id، ويُفحص اتساق invoice_lines المرتبطة
بمقاطعها؛ غياب/تناقض هذا الربط لا يبرر اختراع وجهة من العميل.
لا نغطي مكونات سالبة بـgreatest؛ require_valid_payment_partition يرفض
scope غير الصحيح أو تجاوز سعة الأصل. greatest لمتبقي الدين فقط، لا
لإخفاء تجاوز تطبيقات السند. تعدد الفواتير السارية أو عبور الجهة/الحساب
يفشل مغلقًا؛ لا نقل صامت للقيمة.

المسودة غير الصادرة لا تضيف دينًا ثانيًا فوق charge؛ الحساب الجاري
يحسب charge حتى الإصدار، والفاتورة الصادرة بعدها تحل محله مرة واحدة.

## الأدوات والآثار والهوية

جدول جديد واحد: billing.payment_repartition_events.
هو دليل آثار مرتبط بنفس billing.customer_credit_events، وليس دفتر
رصيد بديلًا. يحفظ payment/tenant/well/account، والنمط والمرجع الأصلي
للتخصيص/تعديله، والرصيد/القيد والمقدار والحالة/المراجعة، وربط الأب.
الطلب الكامل والسبب الحرفي والفاعل والزمن والنتيجة الأصلية من حدث C0
الذي يرتبط به بالمفتاح؛ التاريخ append-only وDML العميل صفر.

الأدوات الخاصة:

- release_payment_allocation بالتوقيع المتحقق نفسه.
- restore_payment_allocation(allocation, amount, source, revision, reason,
  posted_at, origin_id DEFAULT NULL).
- rebalance_payment_capacity(payment, source, revision, reason, posted_at,
  origin_id DEFAULT NULL): مقدار إعادة التصنيف يشتق خادميًا من R.
- reverse_account_credit بالتوقيع نفسه؛ وrepartition_payment_internal
  كاتب خاص مشترك للآثار، لا API عام.

هوية المصدر/المراجعة والطلب الكامل من C0؛ لا tenant من العميل.
مطابقة طلب release/reverse القديمة محفوظة كي يعيد مصدر قديم نتيجته
المخزنة بالضبط، ولا يعاد تحجيم قبول تاريخي أو receipt قديم.
إذا كان للسند رصيد قديم صادر من C0، يبقى حجزه C ضمن المعادلة؛ لا نعطي
أي جزء منه أيضًا لوجهة direct تلقائيًا. التسوية اللاحقة أثر جديد صريح.

### التحرير

يضاف release إلى payment_allocation_adjustments دون تعديل الأصل.
تتغير E في المعادلة، فتستعيد الوجهة الافتراضية سعتها ضمن الدين الحالي.
تُقاس زيادة تسديد الوجهة الافتراضية ككل تحت القفل؛ ما تبقى من قيمة
التحرير فقط يصبح account_credit. إذا كان قبض آخر قد سد الدين بالفعل،
لا يزيحه المحرر ليخلق له متبقيًا بدلًا منه؛ يحجز الفائض من السند المحرر
نفسه. ما كان R قبل العملية يظل مصدرًا أصليًا غير مستخدم، ويمكن تصنيفه
بأمر rebalance مستقل.

الأمثلة P=10000 وE المحرر=2000:

- دين A=10000: D من 8000 إلى 10000، credit=0.
- دين A=8000: D يبقى 8000، credit=2000.
- دين A=9000: D من 8000 إلى 9000، credit=1000.

لا credit بكمية صفر. المصدر الجديد يستخدم account_credits نفسه بنوع
payment_repartition وrepartition_event_id؛ مصدر allocation_release
يبقى للتخصيصات غير session حيث التحرير كله رصيد كما في C0.
لا fake invoice/allocation/payment من أي أداة إعادة توزيع.

### الاستعادة والمستخدم سابقًا

سعة الاستعادة <= original allocation - effective allocation.
يُشتق الجزء الباقي المحجوز كرصيد من مصادر التحرير التابعة للتخصيص نفسه،
والمتبقي هو الجزء الذي عاد إلى direct/السعة غير المحجوزة. تُنقل حصة
الدفع غير المحجوزة أولًا، وتُسحب حصة الائتمان من مصادرها المرتبطة.
لا تستخدم أرصدة غير مرتبطة لإخفاء نقص مصدر التحرير.

سحب عدة أرصدة يستعمل account_credit_reversals نفسه، بحدث فرعي ثابت
الهوية مشتق من source/revision/credit وأصل جامع origin_source_id.
كل طفل مرتبط بالأب، وكل أثر/قيد فريد؛ ليست هذه هوية أمر بديلة.
إذا كانت الحصة مستخدمة في فاتورة أخرى، لا نفكها آليًا وننشئ دينًا جديدًا
هناك دون أساس أعمال: تحفظ financial_review_required بلا استعادة جزئية.
يمكن للمعاملة المخولة تحرير التطبيق عبر C0.1 ثم تنفيذ استعادة جديدة
صريحة؛ التطبيق الأصلي لا يتغير، ولا توجد إعادة إرسال عمياء.

عكس مصدر غير session القديم يحتفظ بنتيجة C0 الجزئية held/receivable_review
والطلب القديم؛ ترتيب الآثار داخل المعاملة يجعل سحب الائتمان يسبق restore
حتى لا تظهر سعة سالبة عابرة للقراء الداخليين. أصل الجلسة المزدوج أو
المصدر الجديد يمر بالتسوية الخاصة للقرار الجديد، مع مراجعة صريحة عند
نقص المتاح/الدين أو تسوية توزيع سابقة. مصدر rebalance بلا allocation
يرجع للوجهة الافتراضية فقط إذا استوعبت الدين قيمته، وإلا يحفظ للمراجعة.

المقدم النقدي الأصلي لا يمر بـrebalance لإصدار التزام ثانٍ؛ يظل مصدر
cash_advance بماله وقيده الأصليين. تحرير تخصيص مقدم سبق استخدامه يعكس
استخدامه بالقدر الصحيح وفق C0، لا يعيد تسجيل قبض.

## المحاسبة والفترات والتوزيع

القبض الأصلي في المصدر: مدين 1000 ودائن 1100 لغير advance، أو 2000
للمقدم. نقل التطبيق بين ديون الحساب نفسه يبقى داخل ذمته 1100، فلا
يحتاج حركة نقد أو قيد صفري مصطنع.
إنشاء credit من الفائض: مدين 1100، دائن 2000 بالجزء الفائض فقط.
سحبه/استخدام مقدم نقدي: مدين 2000، دائن 1100 بالجزء المستخدم فقط.
القيود تمر بـpost_customer_credit_entry وfinance.post_journal_entry،
ومرجعها الحدث/السند/التخصيص، بلا cashbox أو حساب جديد.

الفترة المغلقة لا تفتح؛ السياق الداخلي posted_at جزء من الطلب الثابت.
إذا احتاج الأثر قيدًا ورفضته الفترة، تتراجع المعاملة الفرعية وآثارها
وأطفالها كلها، ثم يحفظ الأب للمراجعة. النقل المحض داخل ذمة الحساب
بلا أثر محاسبي ليس تعديلًا لقيد تاريخي، ولا ينشئ قيدًا وهميًا لتجاوز
الحد. لا catch عام يخفي فشلًا آخر.

حساب التوزيع يبقى من SUM payments posted غير advance مرة واحدة؛
الرصيد الصادر يمر بـcompute_reserved_liabilities الحالي. تغيّر الوجهة
لا يضاف إلى collected أو cash/refund. غير المعتمد يبطل بعقد C0،
والمعتمد/المدفوع لا يعاد كتابته. لا توزيع delta خاص بالجلسة هنا.

## الأقفال والتزامن والصلاحيات

READ COMMITTED مطلوب بالقفل المتحقق في C0.1. الترتيب: قفل البئر المالي،
هوية المصدر، الحساب ثم الدفع/التخصيص/الرصيد/الفواتير حسب العملية.
record_payment/allocate_payment/issue_session_invoice تأخذ القفل المشترك
قبل أقفالها المالية القائمة منعًا لدورة انتظار account→well/well→account.
تغيير دين charge أو حقول دين/نطاق الفاتورة يُسلسل بالقفل نفسه؛ الكاتب
المستقبلي يأخذه قبل أقفال الصفوف، ولا يفترض أن updated_at نسخة سلطة.
C0 apply وC0.1 adjustments يحتفظان بهوية الأمر ويحدثان العدادات المشتقة
عند الأثر الجديد فقط؛ replay يعود قبل أي تحديث.

permission للآثار الجديدة session.correct مع auth.uid ونطاق مشتق من
الأصل. التخصيص العادي يبقى عملًا عامًا كاملًا مخولًا بـpayment.allocate؛
لا واجهة arbitrary repartition/credit جديدة للهاتف. API القراءات تبقى
INVOKER، وجميع الأدوات الجديدة DEFINER بمسار pg_catalog,pg_temp، مع
PUBLIC/anon/authenticated/service_role EXECUTE مسحوب من الكتّاب.
العروض INVOKER، والجدول الجديد SELECT scoped بالحساب وRLS وبلا DML.

اختبار المالك OWNER ONLY بقاعدة قابلة للمحو واتصالين dblink عبر Unix
socket. حاجز داخل الأثر وpg_blocking_pids يثبتان الانتظار، ولا يُستبدل
بتتابع استدعاءات. يغطي السباقات الخمسة المطلوبة؛ سباق تغير الدين يستخدم تجهيز مالك
داخل معاملة تأخذ القفل قبل UPDATE للـcharge، لا API تصحيح جلسة. ويزيد
سباقي الإفراط
في التحرير والاستعادة. لا نتيجة تزامن مدعاة؛ بعده يعاد بناء قاعدة الاختبار.

## خريطة المستهلكين الدقيقة

| المستهلك الأصلي | خط الأساس | المشكلة/التكامل |
|---|---|---|
| billing.record_payment | 20260929133348_operator_cash_custody.sql:244 | كان remaining رسوم الجلسة من raw SUM على charge؛ أصبح من session_economic_settlements، وقفل مشترك قبل الحساب. إدراجات القبض الأصلية لم تزد. |
| billing.split_overpayment_to_advance | 061_money_procedures.sql:22 | نفس مسار استقبال قبض جديد فقط؛ المتبقي الفعال بدل raw SUM، لا INSERT من تحرير/استعادة. |
| billing.allocate_payment | C0 consumers:4 | التخصيص يستهلك capacity وينقص direct، مع سماح إسقاط نفس الجلسة دون عد مرتين، وتحديث الفواتير مشتقًا. |
| release_payment_allocation / reverse_account_credit | C0 foundation:231 /303 | التحرير يوجه السعة أولًا ويفصل credit الحقيقي؛ عكس المصدر/الاستعادة يستهلك الحصة المرتبطة أو يحفظ مراجعة. |
| effective_payment_allocations | C0 foundation:81 | المصدر الفعال نفسه، الأصل لا يتغير. |
| account_credit_balances / effective_account_credit_applications | C0/C0.1 | دفتر الرصيد والتطبيق الفعال نفسهما، يدخل الحجز C وتبقى القراءة مميزة. |
| invoice_effective_balances | C0.1:66 | تسديد صريح + حصة direct الفعلية، لا raw link إضافي. |
| reporting.farmer_account_balances | C0 consumers:355 | الفواتير السارية مرة، والرسوم غير المفوترة مرة، والدين/المتاح من النماذج الحاكمة. |
| api.get_farmer_account | C0 consumers:368 | قائمة تاريخ الدفع والتخصيص محفوظة، مع economic_application منفصل ومبالغ الفاتورة الحالية من العرض. |
| api.get_farmer_selection_status / list_well_farmer_directory / list_well_farmer_balances | C0 consumers:526 /593 /763 | ترث عرض الحساب الحاكم؛ لا معادلة مستقلة جديدة. |
| api.list_well_sessions / get_session_detail | 106_actual_execution_time_contracts.sql:26 /196 | موضعا العد المزدوج المباشر: inv.paid وإلا SUM p على charge؛ استبدلا بتسديد الجلسة الاقتصادي الموحد. |
| billing.get_available_customer_credit_read | C0 consumers:930 | cash_advance / account_credit / payment_remaining مصادر منفصلة؛ التفاصيل تبين credit_origin. |
| billing.get_customer_credit_proposal_read / api.get_advance_allocation_proposal | C0 consumers:963 /193 | الاقتراح من المتاح والدين الفعال؛ لا DML ولا سند نقد جديد. |
| billing.apply_account_credit / adjust_credit_application | C0/C0.1 | تحديث عدادات الفواتير من النماذج بعد التحرك المالي، دون تعديل تطبيق أصلي. |
| billing.issue_session_invoice | 081_permission_enforcement_money.sql:63 | لا إصدار تلقائي جديد؛ الإصدار المطلوب يأخذ القفل ويدمج direct مرة واحدة في paid/current debt. |
| billing.reverse_payment | 061:349 | فعل العكس القديم فقط، مع القفل وتحديث العدادات؛ لا عكس دفع من عملية repartition. |
| ops.check_debt_thresholds | C0 consumers:837 | يرث available_credit_minor والدين الحاليين من عرض الحساب. |
| get_reports_summary/operator_totals/shift_report/well_daily_summary | 106/حيازة المشغل/045/076 | النقد من مصدره الفعلي؛ لا جمع direct مع allocation كتحصيلين. لم تضف حركة قبض. |
| calculate_profit_distribution / generate_distribution_batch | C0 consumers:1033 /047 | التحصيل من payments الأصلي؛ لا تعديل لأساس النقد بسبب وجهة التطبيق. |
| compute_reserved_liabilities / approve_profit_distribution | C0 consumers:1000 /1181 | الحجز من دفتر الائتمان نفسه، والقفل المتحقق نفسه؛ لا إعادة كتابة لقطة معتمدة. |
| processed_commands / إيصال record_payment / list_advance_receipts | 084/109/C0 | النتيجة الأصلية والتاريخ محفوظان؛ مصدر advance يبقى نقدًا أصليًا، لا credit مولدًا كقبض. |

## الاختبارات والتسليم

الاختبار الدائم يغطي A–AN عدا إثبات السباقات الذي يقع في ملف المالك،
بأمثلة الدين 10000/8000/9000، والتطبيق المستخدم ثم تحريره بـC0.1،
والحالة نفسها/جلسة أخرى، ومصدر allocation-only/direct-only، والفترة
المغلقة/سياق مفتوح، وعزل النطاق والمنح. خصائص حتمية بقيم 8400/8800/
9200/9600/10000 تعطي credit 1600/1200/800/400/0 دون إعادة استخدام دالة
الإنتاج كـexpected. الـcharge المعدل تجهيز اختبار فقط، لا API تصحيح.

الهجرتان مرتبطتان بالاختبار الدائم نفسه: الأولى لقواعد المصدر والتحرير،
والثانية لقراءات الحساب/الجلسة/الاقتراح والإصدار/التخصيص والتقارير.
لا تعديل اختبارات أو هجرات متحققة لتمرير نتيجة؛ على المالك إعادة تشغيل
انحدار C0/C0.1 أيضًا. لا compilation/DB/concurrency نفذه الوكيل.

المسارات:

- supabase/migrations/20261107000000_payment_economic_partition.sql
- supabase/migrations/20261107001000_payment_partition_consumers.sql
- supabase/tests/20261107000000_payment_economic_partition.test.sql
- supabase/tests/20261107_payment_partition_concurrency.sql

### حصيلة الفحص الساكن

فُحصت 240 نقطة استدعاء معروفة التوقيع دون تعارض في عدد الوسائط أو
أسماء الوسائط المسماة، و7 إدراجات من حيث تطابق الأعمدة والقيم. هذا فحص
مصدر محدود، وليس تحليلًا نحويًا كاملًا أو compilation من PostgreSQL.
الاختبار الدائم يحتوي 48 موضع assertion، وملف التزامن 9 مواضع ضمن
7 سباقات؛ هذه أعداد مواضع مكتوبة، وليست نتائج نجاح تنفيذ.

المسارات المتغيرة 11: هجرتان جديدتان واختباران و7 وثائق. حُفظ محتوى
وثائق البداية الأربع، ولم تتغير إدراجات القبض الأصلية الأربع المنسوخة
إلى هجرة المستهلكين. لا مسار غير متوقع ولا ملف staged. نجح
`git diff --check`؛ وفُحصت أيضًا مسافات نهاية السطر وحدود dollar-quote
لملفات SQL الجديدة غير المتعقبة. لم تُشغّل قاعدة أو اختبارات أو شبكة.
