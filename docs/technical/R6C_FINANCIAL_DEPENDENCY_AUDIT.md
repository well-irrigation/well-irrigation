# R6-C — خريطة التبعيات ومانع النموذج المالي

## النتيجة وحدود الجولة

STATUS: BLOCKED
BLOCKER: BLOCKED_R6C_FINANCIAL_MODEL_GAP
HEAD: 595ad67e596d51cae7fddec7114d029fd433a16c
BRANCH: reconcile/q137-local-20261030
WORKTREE_START: CLEAN

هذا تقرير تدقيق مصدر قبل التنفيذ. لم تُنشأ هجرة أو جداول أو API تصحيح
أو اختبارات تنفيذ. لم تُعدّل الهجرات المختومة أو الهاتف أو SQLite.
لم يُشغّل DB أو Docker أو شبكة أو Supabase أو نشر أو Git mutation.
R6-A وR6-B متحققان وفق إفادة المالك؛ لا يضيف هذا التقرير تحقق تشغيل جديدًا.

## المانع المحدد

نموذج التخصيص الحالي لا يمثل تحرير تخصيص سابق أو رصيد تصحيح غير نقدي
قابلًا للاستخدام عبر مسار المقدم القائم، مع حفظ الدفعة والتخصيص الأصليين.
ولا يكفي إضافة قيد محاسبي متوازن: مصادر رصيد المزارع والتخصيص لا تقرأ
قيود اليومية لتحديد المتاح؛ تقرأ payments وpayment_allocations مباشرة.

الأدلة النافذة:

1. `supabase/migrations/20260822003001_081_permission_enforcement_money.sql:578`
   — billing.allocate_payment يقفل الدفعة ثم الفواتير؛ يقبل مبلغ تخصيص
   موجبًا فقط؛ والمتاح = مبلغ الدفعة ناقص SUM للتخصيصات المخزنة (654–659).
   يدرج تخصيصًا ويزيد paid_minor وينقص outstanding_minor، ولا توجد هنا
   حركة تحرير/عكس تخصيص مستقلة.
2. `docs/technical/db/constraints.txt:38` و`:41`
   — allocated_minor > 0، وUNIQUE(payment_id, invoice_id).
   `docs/technical/db/columns.txt:80` — صف التخصيص يحمل payment_id وinvoice_id
   والمبلغ والتوقيت، بلا أصل عكس أو ربط مراجعة تصحيح.
3. `supabase/migrations/20260929030001_108_advance_allocation_proposal.sql:74`
   — المقدم المتاح للاقتراح يجب أن يكون billing.payments مرحّلًا بغرض advance؛
   والمتبقي يشتق من مبلغ هذا السند ناقص مجموع تخصيصاته (101–107).
4. `supabase/migrations/20260904010001_097_advance_receipt_reads.sql:97`
   — قائمة سندات المقدم تعرض المصدر نفسه، وليست سجل أرصدة تصحيح عامة.
5. `supabase/migrations/20260814031001_061_money_procedures.sql:96`
   — journalize_payment يرحّل أي دفعة posted بلا journal_entry_id سابق
   بمدين حساب النقد 1000؛ لا يغير ذلك اختيار method=offset_credit.
   إدراج advance جديد بالطريق العادي لتغطية فرق التصحيح سيولد تحصيلًا
   جديدًا، ولا يمثل إعادة تصنيف غير نقدية بأمان.
6. `supabase/migrations/20260929133348_operator_cash_custody.sql:484`
   — كاتب الدفع النافذ يسجل فائض الدفع الجديد كسند advance جديد ويتحقق
   من قيده المرحّل؛ هذه آلية استقبال دفعة أصلية، وليست رصيد تصحيح لاحق.
7. `supabase/migrations/20260814031001_061_money_procedures.sql:22`
   — split_overpayment_to_advance يعمل BEFORE INSERT للدفعة فقط؛ لا يعمل
   عند خفض تكلفة جلسة لاحقًا، ويقسم قيمة الدفعة الجديدة عند استقبالها.
8. `supabase/migrations/20260814030004_060_reporting_views.sql:8`
   — farmer_account_balances يجمع إجمالي الفواتير والتخصيصات والمدفوعات
   advance مباشرة؛ لا قناة فعالة لائتمان تصحيح أو عكس تخصيص.

مثال المالك: إبقاء سند وتخصيص الدين المسدد كما هما بعد خفض الدين لا
يحرر مبلغًا في صيغة المتاح الحالية. إضافة daily journal correction
فقط لا تغير هذه الصيغة، وتسجيل advance جديد بالطريق العادي يضيف نقدًا
مصطنعًا. تعديل/حذف الأصل مخالف صريح للعقد المطلوب.

هذا نقص تمثيل وتناغم مالي، وليس نقص موافقة أو قرار سياسة: سياسة المالك
للفائض محسومة. ينطبق شرط التوقف الخاص بنموذج الدفع/التخصيص؛ لذلك لا
يُسلّم جزء تشغيلي يعلن تسوية مالية لا تستطيع العقود الحالية تمثيلها.

## خريطة التبعيات المصنفة

التصنيف يصف عقد الحفظ المطلوب عند التصحيح، ولا يثبت وجود إعادة احتساب
جاهزة. قد يحمل الكائن جزءًا مشتقًا وجزءًا تاريخيًا، لذلك تُفصل أدواره.

| التبعية | التصنيف | دليل المصدر وما يلزم حفظه |
|---|---|---|
| الجلسة الحالية ومدتها الفعلية | DERIVED_RECALCULABLE | صف ops.irrigation_sessions هو هوية التشغيل الحالية. لا revision تصحيح صريح قائم في هذه العقود؛ updated_at لا يكفي. يلزم قبول مراجعة جديدة لنفس الهوية دون جلسة بديلة. |
| وقائع المقاطع الأصلية وتوقفاتها ومصادر الطاقة | IMMUTABLE_HISTORY | invoice_lines يرتبط بـsession_segment_id؛ لا يجوز حذف دليل قديم أو استنتاج توقف/طاقة من تعديل طرفي الزمن وحدهما. |
| تكلفة المقاطع الحالية | DERIVED_RECALCULABLE | 066_session_procedures: create_priced_session_segment يثبت سعر الحدث وفق effective_period، ثم R4 finalize_session_from_closed_segments يحسب كل مقطع ويجمع. لا يوجد مسار مراجعة مقاطع مستقل حاليًا. |
| جداول التسعير ولقطات السعر السابقة | IMMUTABLE_HISTORY | 066: اختيار التعرفة عند p_started_at وتخزين applied_*؛ يجب الاحتفاظ بلقطة الأصل، واختيار تعرفة زمن الحدث المصحح للنسخة الجديدة دون آخر سعر عشوائي. |
| الملخص الحالي billing.session_charges | DERIVED_RECALCULABLE | UNIQUE(session_id) في الفهرس؛ FK المدفوعات إلى charge؛ R4 finalizer يدرج الملخص ويتحقق من عدم وجوده مسبقًا. التصحيح يحتاج تاريخًا سابقًا ونتيجة حالية واحدة، ولا يعاد تشغيل الإكمال. |
| فاتورة مسودة بلا ترحيل | DERIVED_RECALCULABLE | 081 issue_session_invoice يبني draft وبنوده من المقاطع، ثم يصدره. لا يعني وجود draft وجود API تصحيح آمن لها؛ يجب التحقق من خلوها من أثر سابق. |
| الفاتورة الصادرة وبنودها وأثرها المرحّل | POSTED_REQUIRES_ADJUSTMENT | 081 issue_session_invoice يرفض فاتورة سارية ثانية؛ 061 journalize_invoice ينشئ قيد المصدر invoice. تغيير charge وحده لا يعدل الفاتورة أو قيدها تلقائيًا. |
| سندات الدفع الأصلية | IMMUTABLE_HISTORY | 081/ملف operator_cash_custody: دفعات تحمل مبلغًا وتاريخًا وقيدًا؛ لا يحولها التصحيح إلى قبض أو استرداد جديد. |
| التخصيص الأصلي | IMMUTABLE_HISTORY | payment_allocations موجب وفريد بالدفعة والفاتورة؛ يلزم سجل تعديل مستقل ولا حذف صامت. |
| صافي أثر التخصيص والمتاح بعد التصحيح | POSTED_REQUIRES_ADJUSTMENT | 081 allocate_payment و108 proposal لا يستهلكان عكس تخصيص أو credit غير نقدي؛ هذه الفجوة الحاجبة. |
| رصيد المزارع والمقدم واستهلاكه المستقبلي | DERIVED_RECALCULABLE | reporting.farmer_account_balances و097 و108 تقرأ الدفعات والتخصيصات؛ قيد اليومية وحده لا يكفي لتحديث هذه الحقيقة. |
| القيود والأطراف المرحّلة | POSTED_REQUIRES_ADJUSTMENT | 036 prevent_posted_entry_change/prevent_posted_line_change يمنعان تحرير الأصل؛ 061 reverse_journal_entry يضيف قيدًا معاكسًا ويعلم الحالة وفق العقد القائم. هذا لا يعكس التخصيص أو يولد مصدر ائتمان بذاته. |
| الفترة المحاسبية المغلقة | IMMUTABLE_HISTORY | 049 post_journal_entry يضمن فترات ويرفض الترحيل في closed. يمكن بحث قيد فرق في سياق مفتوح جديد، ولا توجد ضرورة لإعادة فتح التاريخ. لم يُنفذ تنسيق accepted operational / financial_review_required. |
| استهلاك الديزل الفعلي وقيده الأصلي | POSTED_REQUIRES_ADJUSTMENT | R4 finalizer يدرج استهلاك المقاطع كاملًا؛ 046 apply_fuel_transaction يغير مخزون البئر عند الإدراج؛ 069 journalize_fuel_transaction يرحّل الاستهلاك. إعادة الإكمال تكرر هذا الأثر. |
| قياس ديزل تقديري غير مخصوم | DERIVED_RECALCULABLE | 082 record_fuel_consumption يسمح استبدال pending_actual_measurement بقياس actual؛ ليس عكسًا عامًا لاستهلاك actual مرحّل. |
| حركة جرد الديزل | UNRELATED | physical_count يسجل فرق جرد ومعالجة حساب 5800؛ ليس بديلًا لتصحيح تاريخ استهلاك جلسة. وجود adjustment_in/out في enum لا يكفي لإثبات ربط وقيد تصحيح جلسة جاهز. |
| أصل سقي الشريك وسياسة الخصم | IMMUTABLE_HISTORY | partner_irrigation_policies تختارها الفاتورة حسب زمن نهاية الجلسة في 081؛ نسخة السياسة والأثر السابق لا تعاد كتابتهما صامتًا. |
| دورة توزيع غير معتمدة | DERIVED_RECALCULABLE | 053 calculate_profit_distribution يعتمد النقد المحصل غير advance والمصروفات والالتزامات والحصص وخصم فواتير غير deducted_in_cycle_id؛ لا يستقبل دفتر فروق تصحيح حاليًا. |
| لقطات دورة التوزيع المعتمدة/المدفوعة | IMMUTABLE_HISTORY | 052 prevent_approved_cycle_change/prevent_approved_line_change يقفل المبالغ المحسوبة؛ paid_minor ليس حصة جديدة قابلة لإعادة الحساب. |
| فرق تصحيح توزيع لاحق | POSTED_REQUIRES_ADJUSTMENT | 053 يضع deducted_in_cycle_id للفواتير، ويبدأ other_deductions_minor بصفر؛ لا يوجد هنا مصدر دلتا جلسة مرتبط بالتصحيح وقابل للتطبيق مرة واحدة في دورة لاحقة. حالة carried_forward القائمة للمستحقات ليست دليلًا على دفتر فروق تصحيحات. |
| سداد مستحق الشريك السابق | IMMUTABLE_HISTORY | 081 pay_partner_distribution يستهلك مستحق السطر ويولد أثر السداد؛ لا يُستخدم لإعادة كتابة حصة مدفوعة أو إدراج تسوية تصحيح وهمية. |
| القوائم والتفاصيل والتقارير الحالية | DERIVED_RECALCULABLE | 106 list_well_sessions/get_session_detail/get_reports_summary يقرأ الجلسة والملخص ويجمع المقاطع كلها حسب session_id. إضافة نسخ مقاطع دون تصفية النسخة الحالية تسبب ازدواجًا. |
| الأصل التشغيلي R4 | IMMUTABLE_HISTORY | guard_operational_schedule_write في R6-A يحفظ هوية الواقعة وربطها؛ جلسة historical_settlement مقيدة بوقتي الأصل. يلزم مسار مراجعة مفوض صريح، لا تعطيل الزناد أو تغيير الواقعة. |
| إشعارات وتدقيق سابقان | IMMUTABLE_HISTORY | audit_logs append-only؛ 053 approve_profit_distribution يولد إشعار الاعتماد؛ R4 finalizer يولد تدقيق الإكمال. لا يعاد تشغيلهما لتوليد تصحيح؛ لم يكتشف التدقيق منتج إشعار تصحيح قائمًا. |
| جدول الحجز والانتقالات | UNRELATED | يظل تخطيطًا ومنشأً فقط؛ لا يتحكم بزمن التصحيح ولا يعاد جدولته أو إحياء الانتقالات بسببه. |

## اعتماد الإقرارات الذي يجب معالجته عند استئناف R6-C

- إقرار البدء الحر R6-B يطابق original_facts والنتيجة الأصلية ولا يطابق
  وقت الجلسة الحالي: `20261104000000_operational_start_receipt.sql:137`.
- إقرار البدء من حجز ما زال يتحقق من s.started_at الحالي:
  `20261028033000_booking_start_receipt_read.sql:113`.
- إقرار الإكمال ما زال يتحقق من v_session.ended_at الحالي:
  `20261020202430_completion_receipt_read.sql:150`.

لذلك لا يكفي تحديث صف الجلسة: يجب أن تستند قراءات الحجز والإكمال بعد
التصحيح إلى دليل الأصل المحفوظ ونسخ التاريخ الموثوقة، مع إبقاء
response_payload الأصلي كما هو. لم تُغيّر هذه الجولة أي قارئ أو إقرار.

## الصلاحيات

الصلاحية session.correct موجودة في كتالوج 028. المصدر الحاكم للتعيين
080_permission_authority_foundation: owner يطابق tenant_owner الذي
يحصل على كامل كتالوج الصلاحيات؛ manager يطابق well_manager؛ والمنح
الصريحة session.correct للمدير والمشغل في السطرين 173 و190.
لا حاجة لقرار دور جديد أو موافقة إضافية بسبب قدم الجلسة أو سدادها.
التعيين النشط ونطاق البئر لازمان؛ لم يُنشأ غلاف تصحيح بهذه الجولة.

## أصغر متطلب سابق للاستئناف

تأسيس عقد محاسبي لا ربط جلسة منفردًا:

- مصدر ائتمان تصحيح غير نقدي مرجعه التصحيح والجلسة والحساب والدفعة/التخصيص
  الأصلي، بلا billing.payment جديد يوحي بقبض نقدي.
- حركات عكس/تحرير تخصيص إضافية تحفظ التخصيص الأصلي، وتدخل في صافي المتاح
  والمدفوع والدين؛ uniqueness على التصحيح/المراجعة والأثر يمنع التكرار.
- استهلاك هذا المصدر عبر قواعد المقدم الحاكمة، مع مواءمة allocator
  والاقتراح وقائمة المقدم وأرصدة المزارع والفواتير وقراءات الجلسة.
- ربط الفرق بقيد تعديل/إعادة تصنيف مرحّل في فترة مسموحة، دون إحياء
  النقد أو عكس قبض كامل غير مطلوب. يظل closed محميًا.
- مصدر فروق توزيع مستقل مرتبط بالأصل وبالشريك، مع استهلاك مرة واحدة في
  دورة لاحقة أو حالة تسوية مستحق/ذمة صريحة؛ لا تغيير للقطة المدفوعة.

هذا المتطلب يغيّر نموذج التمثيل المالي المشترك ومستهلكيه، وليس مجرد
إضافة session_corrections واستدعاء finalizer قديم. لا يُختزل إلى مسار
يعلن القبول المالي أو يضيف رصيدًا غير مرئي للعقود الحالية.

## ما لم يُنفذ

CORRECTION_MODEL: NOT_IMPLEMENTED
NEW_TABLES: NONE
SESSION_REVISION_MODEL: NOT_IMPLEMENTED
CORRECTION_API: NOT_IMPLEMENTED
CORRECTION_RECEIPT_API: NOT_IMPLEMENTED
CORRECTION_HISTORY_API: NOT_IMPLEMENTED
FINANCIAL_DEPENDENCY_IMPLEMENTED: NONE
CHARGE/INVOICE/PAYMENT/ALLOCATION/FUEL/DISTRIBUTION_RECONCILIATION: NONE
TEST_CASES_AUTHORED: NONE
CONCURRENCY_TEST_REQUIRED: YES
MIGRATION_PATHS: NONE
TEST_PATHS: NONE

بعد حل النموذج المالي، يلزم قفل حقيقي وتسلسل أقفال متوافق مع كاتبي
الدفع والتخصيص، وفحص base_revision تحت القفل، ثم اختبار اتصالين مستقلين.
لم تُكتب محاكاة متتابعة ولم تُدّع نتيجة تزامن.

سيظل عقد التصحيح المطلوب: سبب دقيق محفوظ، وهوية جلسة وواقعة ثابتتان،
ومراجعة جديدة مقبولة لا last-write-wins؛ لكن هذه متطلبات لا تنفيذ قائم.
كل الأرصدة والمدفوعات والتخصيصات والتوزيعات والإقرارات الأصلية بقيت دون تعديل.


## متابعة R6-C0 — 2026-11-02

الخريطة أعلاه تصف خط الأساس قبل R6-C0 وتبقى دليلًا تاريخيًا للمانع.
كُتب الآن أساس التحرير الإضافي للتخصيص، والرصيد غير النقدي وتطبيقه
وتراجعه، والعروض والمستهلكون والاختبارات. الحالة Implemented / Static
reviewed / DB Verification Pending. لا يرفع هذا المانع إجرائيًا قبل
تحقق المالك، ولا يبدأ تصحيح الجلسات أو فروق توزيعاتها التاريخية.
العقد والحدود وخريطة التكامل:
`R6C0_FINANCIAL_CORRECTION_FOUNDATION.md`.
