# R6-B — إقرار البدء التشغيلي الحر

> الحالة الحاكمة الحالية: ADOPTED + DOCUMENTED + IMPLEMENTED + VERIFIED LOCAL + CI VERIFIED + COMMITTED في `595ad67e596d51cae7fddec7114d029fd433a16c`، ومدفوع في PR #68. تحقق المالك السابق مع انحدار C2/C3؛ Pending أدناه تاريخي. **الواجهة:** إقرار البدء من الهاتف منفذ ومدمج في `main` عبر PR #67؛ **القبول الجهازي جزئي** وغير مغلق. المرجع الحالي: `../memory/RESUME_POINT.md`.

**HISTORICAL:** الحالة التالية تصف لحظة تأليف الهجرة فقط.

الحالة: Implemented محليًا / Static reviewed / DB Verification Pending.
خط الأساس: `reconcile/q137-local-20261030` عند
`f8c6e353685ac47cb6b6633a146264aa5b1e0b48` وشجرة نظيفة.
R6-A متحقق ومحفوظ وفق إفادة المالك؛ لم يغيّر هذا العمل أي هجرة قديمة.
لم تُشغّل قاعدة أو Docker أو شبكة أو سحابة، ولا Git mutation.

## خريطة التخزين قبل التعديل

المصدر `sync.processed_commands`، ومفتاحه الفريد `(tenant_id, command_id)`.
نوع الحالات المخزن: processing / accepted / rejected / conflict.
البدء العادي الحالي لا يحفظ رفض SQL عند فشل المعاملة: يتراجع الأمر والبدء
معًا؛ لذلك غياب الصف ليس رفضًا محفوظًا ولا إذنًا بإعادة الإرسال.

| command_type | entity_id | request_payload | response_payload المقبول | دليل النطاق والنقص التاريخي |
|---|---|---|---|---|
| start_operational_session | البئر | actor، well، pump، farm، farmer account، energy، original started_at بصيغة UTC، fuel owner، crops، source booking الاختياري | {id, occurrence_command_id} | tenant من البئر، والطلب والأمر والواقعة والجلسة متطابقة. original_facts في الواقعة يحفظ الطلب والنتيجة. |
| start_irrigation_session | SQL NULL | SQL NULL | {id} | R4 يربط الواقعة، لكن ما قبله قد يفتقدها. الربط الفعلي للجلسة بالبئر والجهة يكفي لإعادة UUID الأصلي فقط؛ لا يستنتج وقتًا أو بصمة مفقودة. |
| start_adhoc_session | البئر | v113: well، pump، farm، account، energy، planned duration، original started_at، crops، fuel owner | {id} | الطلب يثبت البئر، وR4 يضيف الواقعة. طلب غائب أو ناقص أو مخالف لا يعاد بناؤه؛ الدعم جزئي للسجل القديم. |
| start_irrigation_session_from_booking | الحجز | v113: booking، started_at، crops | session_id، booking_id، well_id، started_at، booked_duration_minutes، operational_end_at وحقول الحجز القائمة | عقد مستقل وقارئ مستقل؛ لا يعتمد عليه القارئ الحر. |

المصادر النافذة:

- `supabase/migrations/20261103000000_operational_start_separation.sql`:
  ops/api.start_operational_session، الحمولة الكاملة وربط الأصل.
- `supabase/migrations/20261102000000_operational_occurrence_contract.sql`:
  أغلفة البدء القديمة ووضع bind_accepted_start في accept_delay_start_group،
  وتخزين original_facts وإقرارات المجموعة/التسوية.
- `supabase/migrations/20261001034419_booking_execution_contracts.sql`:
  sync.begin_adhoc_session_command وsync.begin_booking_session_command.
- `supabase/migrations/20260823003001_083_sync_command_resolvers.sql`:
  begin_well_command يحفظ entity_id=NULL؛ لا تخلط هذا بمعنى البئر في النوعين الآخرين.
- `supabase/migrations/20261028033000_booking_start_receipt_read.sql`:
  إقرار البدء من حجز منفصل، لم يُعدّل.

## سطح القراءة

`api.get_operational_start_receipt(p_well_id uuid, p_command_id uuid,
p_expected_command_type text DEFAULT 'start_operational_session') RETURNS jsonb`.

البئر والأمر إلزاميان. النوع المتوقع اختياري للحالي، ويُرسل صراحة عند
قراءة أحد النوعين القديمين؛ يتبع نمط قارئ الإكمال القائم. لا tenant أو
server session id أو طابع جلسة من العميل، ولا request fingerprint مصطنع.
هوية الجذر المحلي تبقى لدى العميل مرتبطة بأمره الأصلي؛ R6-A لا يحفظ
root_local_id في هذا العقد، ولا ينشئ هذا القارئ هوية جذر أو واقعة بديلة.

الغلاف العام SECURITY INVOKER، والقارئ sync.get_operational_start_receipt_read
هو SECURITY DEFINER / STABLE، مع search_path=pg_catalog,pg_temp.
التعيين النشط وصلاحية session.start يُفحصان قبل قراءة الأمر، والجهة تحل
من البئر؛ لا صلاحية من معرفة UUID وحده، ولا تجاوز للفاعل عبر service_role.
PUBLIC وanon مسحوبان، والمنح متناظرة لـauthenticated وservice_role
في الغلاف والقارئ الداخلي، دون منح جداول أو تغيير RLS.

الغلاف:
`contract`, `version`, `well_id`, `command_id`, `command_type` المتوقع،
`status`, `receipt`, `retry_authorized=false`.

## الحالات وعدم كشف الوجود

- accepted: النتيجة الأصلية كاملة كما خُزنت؛ لا إعادة بناء من الجلسة الحالية.
- rejected: نتيجة رفض صريحة محفوظة فعلًا، ذات reason ونطاق طلب مثبت،
  بلا واقعة مقبولة أو هوية جلسة تناقض الرفض. لا يحوّل القارئ exception
  إلى رفض، ولا يدّعي أن كاتب R6-A الحالي ينتج هذه السجلات؛ الاختبار
  يدرج سجل رفض مضبوطًا لتوصيف دعم التخزين فقط.
- processing: طلب محدد النطاق مثبت، واستجابة SQL NULL، ولا واقعة مقبولة.
  نتيجة تبدو نهائية أثناء processing تُعاد unresolved.
- not_found: غياب أمر R6-A في النطاق، أو أمر معروف أنه في بئر آخر،
  أو صف لا يمكن إسناده للنطاق عند طلب النوع الحالي. ليس إثبات عدم التنفيذ.
- unresolved: نوع أو شكل أو ربط غير صالح؛ وكذلك غياب/نقص الدليل عند
  طلب النوع القديم. absent قديم وunattributable قديم لهما الغلاف نفسه
  حتى لا يكشف اختلاف الحالة وجود أمر مجهول البئر.

الحالة المتوقعة القديمة لا تميّز not_found من نقص الدليل؛ هذا مقصود
أمنيًا ويستخدم unresolved وفق العقد. لا تمنح أي حالة حق إعادة الإرسال.
الأوامر في جهة أخرى لا تقرأ أصلًا؛ والأمر المعروف لبئر آخر يعيد غلاف
الغياب نفسه للنوع المتوقع دون النتيجة أو النوع المخزن أو أي هوية خادمية.

## إثبات القبول واستقلال التصحيح

للحالي: نوع وهوية الأمر، entity_id وطلبه ضمن البئر؛ شكل النتيجة الكَنوني
`{id, occurrence_command_id}`؛ واقعة accepted_start مقبولة ذات مفتاح
الأمر الأصلي؛ server_session_id؛ original_request_id؛ original_facts
مطابق للطلب والنتيجة المحفوظين؛ ووقت الأصل وفاعله ومنشأ الحجز من الطلب
مطابقة لحقول الواقعة المختومة. الجلسة موجودة في البئر والجهة نفسهما.

لا يقارن القارئ started_at أو status أو حقول الجلسة القابلة للتصحيح مع
الأصل، ولا يضيفها إلى الإقرار. هوية الجلسة ونطاقها فقط يؤخذان من صفها
الحالي. إذا تغير وقت الجلسة لاحقًا، يبقى الإقرار مرتبطًا بالدليل الأصلي.

للقديم العادي: يقبل SQL NULL الأصلي كما هو، ويعيد {id} الأصلي إذا ثبت
الربط الفعلي بالبئر والجهة. إذا وُجدت واقعة يجب أن تطابق الأمر ونتيجته؛
وإذا غابت فلا تُقبل جلسة مثبتة لواقعة أمر آخر. لا تُختلق واقعة للصف القديم.
لـadhoc يلزم طلب v113 المثبت، والنطاق والنتيجة والواقعة إن وجدت.
كل تناقض يرجع unresolved؛ لا إصلاح أو كتابة في مسار القراءة.

لا يحتاج القارئ موعد حجز أو مدته أو حالة جدول أو operational_end_at.
منشأ الحجز في R6-A يُطابق الدليل الأصلي، ولا يعاد تقييم حالته الحالية.

## الاختبارات المؤلفة

`supabase/tests/20261104_operational_start_receipt.test.sql` داخل
BEGIN/ROLLBACK؛ لا استدعاء DB أجراه الوكيل. أغلفة البدء الفعلية تجهز
حالات القبول، والقراءات تمر تحت authenticated. كل قراءة ناجحة تقارن
بصمات جميع جداول الأعمال في core/ops/sync/billing/audit/finance/inventory/iam
قبلها وبعدها، وتفحص retry_authorized=false؛ لا نكتفي بعدّ الصفوف.

| البنود | التغطية |
|---|---|
| A B C D | بدء R6-A حقيقي، فقد الاستجابة، الاستعادة بهوية الأمر فقط، وإعادة القراءة بلا تغيير |
| E F | not_found وprocessing دون إذن إعادة؛ processing مع استجابة نهائية غير صالح |
| G H | نوع مخالف، آبار وجهات مستقلة، UUID مشترك بين جهتين، وحجب وجود الصف القديم غير المسند |
| I J K | تعيين معطل، دور نشط بلا صلاحية، anon، وهوية أمر إلزامية |
| L M | غياب id أو occurrence_command_id، UUID غير صالح، نتيجة scalar/array/JSON null، جلسة بجهة أخرى، تعارض وقائع الأصل، أو غياب الواقعة المطلوبة |
| N O P | النوعان القديمان الحقيقيان، صف تاريخي بلا طلب/واقعة يدعم UUID فقط، وطلب adhoc ناقص ودليل غير كافٍ لا يعاد بناؤهما |
| Q R | تغيير started_at للجلسة فقط دون المساس بالواقعة أو الأمر، وتغيير الحجز دون تغيير الإقرار؛ لا مدة أو نهاية تشغيلية جديدة |
| S T | إقرار الحجز منفصل ويظل مقروءًا، والانتقال والقرار والبدء المعلق تظل متقاعدة |
| إضافية | الرفض الأصلي المحفوظ مقابل الرفض المفقود؛ INVOKER/STABLE ومنح الأدوار وسحب PUBLIC |

تعديل وقت الجلسة تجهيز مضبوط داخل الاختبار؛ لا يعطّل زنادًا أو قيدًا،
ولا يضيف API تصحيح أو يضعف عقدًا إنتاجيًا. لا تغيير للهاتف أو SQLite.
لا توجد نتائج تشغيل لهذه الاختبارات بعد؛ الجاهزية هنا للتسليم إلى
تحقق المالك المحلي فقط، وليس DB/Cloud/Production Verified.

## الملفات

- `supabase/migrations/20261104000000_operational_start_receipt.sql`
- `supabase/tests/20261104_operational_start_receipt.test.sql`
- هذا التقرير، وRESUME_POINT وDOC_CHANGELOG للتسليم الحاكم.
