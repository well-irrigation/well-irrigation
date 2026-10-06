# P2 Automated Execution Phase 1 Proof

**الحالة:** Local Proof ناجح · Cloud/Production غير منفذ · **التاريخ:** 2026-10-06

# Scope

هذه الجولة تثبت محليًا أقل تعديل يسمح لهوية تنفيذ تقنية مخصصة بطلب انتقال
حجز، من دون `auth.uid()` مزيف، ومن دون ملف بشري وهمي، ومن دون تحويل
`service_role` إلى فاعل أعمال. بقيت `ops.execute_booking_transition` منسق
الإغلاق والبدء الوحيد، ولم يُضف أي مسار هاتف أو Edge Function أو Scheduler.

أنشئت الهجرة بواسطة Supabase CLI باسم:

`supabase/migrations/20261006133929_p2_automated_execution_phase1.sql`

# Existing Data Model Findings

النموذج السابق كان يمثل:

- ملكية التشغيل بتعيين نشط في `core.well_assignments` ودور `owner`.
- المشغل بتعيين نشط في الجدول نفسه ودور `operator`.
- حالة التشغيل والمراجعة في
  `core.well_settings.booking_auto_transition_enabled` و
  `booking_auto_transition_revision`.
- الجلسة الحالية والسلسلة ومراجعة القرار في
  `ops.irrigation_sessions` و`ops.booking_transition_chains`.
- منع إعادة `command_id` نفسه بقيد `(tenant_id, command_id)` في
  `sync.processed_commands`.

لكن النموذج لم يكن يثبت مشغلًا وحيدًا للبئر، ولم يربط ON بتعيين المشغل
ونسخة تفويضه، ولم يملك نسخة إبطال تصاعدية، ولم يملك مفتاح إيقاف أعمال
عامًا، وكانت بصمة P1-B السابقة تحتوي `well_id` و`expected_revision` فقط.

لم يُنشأ جدول delegation جديد. امتُد النموذج القائم بأقل حقول لازمة:

- `core.well_assignments.authorization_revision`.
- ربط إعداد ON بمعرف تعيين المشغل ونسخة تفويضه.
- زناد يرفع نسخة التفويض عند تغيير الشخص أو الدور أو الحالة.
- إعادة تفعيل ON بعد تغيير المشغل تعيد الربط صراحة بالمشغل الحالي.

لا يوجد invariant عام يفرض مشغلًا وحيدًا لكل استعمالات النظام؛ الأتمتة
تفرض `exactly one` ذريًا وقت التنفيذ وتفشل مغلقًا عند الغموض.

# Minimal Delta

| العنصر | النوع الفعلي | سبب الضرورة |
|---|---|---|
| المدخل الداخلي | دالة + دور `NOLOGIN` | فصل التنفيذ التقني عن API وأدوار البشر |
| السياق الموثوق | جدول خاص قصير العمر + دوال خاصة | تمرير المشغل المشتق داخل المعاملة بلا تزوير Auth |
| تفويض الأتمتة | دالة خاصة | قفل وإعادة فحص المالك والمشغل والتفويض والحالة |
| ربط التفويض | 3 أعمدة + زنادان | كشف السحب والاستبدال وإعادة التفعيل القديمة |
| المفتاح الذري | جدول singleton | منع الطلبات الموجودة بالفعل في الطريق |
| بصمة النية | عمود `jsonb` + فهرس فريد جزئي | منع أثر ثانٍ بمعرف أمر مختلف |
| تدقيق المحاولة | جدول append-only + فهرسان | حفظ الرفض والإعادة وفصل الهويات الثلاث |
| توافق P1-B | تعديل محدود لمصدر actor في 4 دوال | إبقاء المعاملة والمنطق القائمين بلا منفذ أعمال ثانٍ |

تعديل الدوال المختومة محروس داخل الهجرة: إن غاب موضع الاستبدال المتوقع
تفشل الهجرة بدل تطبيق refactor جزئي صامت.

# Identity Boundary

الحدود المثبتة هي:

- **Technical Executor:** دور PostgreSQL `booking_automation_executor`،
  `NOLOGIN`، ولا عضوية له في `anon` أو `authenticated` أو `service_role`.
- **Business Actor:** ثابت داخل الدالة:
  `actor_kind=system` و`actor_ref=booking_automation_system`.
- **Responsible Operator:** ملف المشغل البشري الوحيد المستخرج من تعيين
  نشط ومربوط بنسخة التفويض؛ هو الذي يحفظ في `operator_profile_id`.
- **Credential Reference:** القيمة غير السرية
  `vault:p2-booking-automation:v1` للتدقيق فقط؛ لا يوجد سر في قاعدة الأعمال.

التوقيع الداخلي لا يقبل actor أو operator أو executor. ولا يملك
`service_role` حق EXECUTE عليه.

# Human Path Preservation

بقي توقيع `ops.execute_booking_transition(uuid,bigint,uuid)` كما هو، وبقي
المسار البشري يأخذ هوية المستخدم من `auth.uid()`. دالة
`ops.current_execution_operator()` تعيد `auth.uid()` أولًا، ولا تستخدم
السياق الداخلي إلا عندما تكون هوية Auth غائبة ويوجد صف سياق صحيح للمعاملة
والاتصال الحاليين.

أثبت AP1 أن الرد البشري القديم بقي كما هو وأن `executed_by` هو المستخدم
البشري. كما نجحت الحزمة السابقة كاملة ضمن `db:test`.

# Automation Authorization Path

المسار المنفذ محليًا:

`booking_automation_executor`
→ `ops.execute_booking_transition_automation`
→ قفل بصمة النية
→ `ops.authorize_booking_transition_automation`
→ سياق معاملة خاص
→ `ops.execute_booking_transition`
→ دالتي الإكمال والبدء القائمتين.

يعاد تحت الأقفال فحص: المفتاح العام ونسخة السياسة، البئر النشط، وجود مالك
نشط، مشغل نشط وحيد، تطابق تعيين ON ونسخة التفويض، حالة ON ومراجعتها،
الجلسة المفتوحة الوحيدة، السلسلة الحالية ومراجعتها، الحجز التالي الفعلي
واستحقاقه. أي نقص أو اختلاف يرفض مغلقًا.

المدخل الداخلي لا يستدعي `ops.complete_irrigation_session` ولا
`ops.start_booking_session_core` مباشرة؛ الاستدعاء الوحيد لهما بقي داخل
P1-B.

# Kill Switch

أضيف `ops.booking_automation_control` بصف `global` واحد، وافتراضه OFF.
يُقفل الصف `FOR SHARE` داخل قرار الأعمال، وتحديثه يتعارض مع التنفيذ الجاري
قبل نقطة الحسم. يحمل `policy_version` تصاعدية يرسلها Discovery وتُقارن
ذريًا.

هذا هو مستوى Business Kill Switch. مستوى Runtime Kill Switch يبقى خارج
هذه الجولة ويجب أن يوقف نبضات Scheduler الجديدة. تعطيل Cron وحده لا يمنع
طلبًا خرج بالفعل، لذلك لا يغني عن المفتاح داخل المعاملة.

# Command Fingerprint

أضيفت `sync.processed_commands.intent_fingerprint` مع فهرس فريد جزئي على:

`(tenant_id, command_type, intent_fingerprint)`

وتضم البصمة: tenant، well، chain، current session، next booking، مراجعة
القرار، مراجعة الأتمتة، نسخة السياسة، المشغل، تعيينه، نسخة تفويضه، ونوعي
Actor الثابتين.

أصبحت `sync.begin_command` تستخدم `INSERT ... ON CONFLICT DO NOTHING`
ثم تصالح الصف الكنوني، بدل نمط select-then-insert القابل للسباق. المسار
البشري الذي لا يحمل سياق P2 يبقي `intent_fingerprint=NULL` وسلوكه السابق.

# Concurrency and Replay Proof

أضيف `scripts/p2_automation_concurrency_proof.py` واختُبر فعليًا باتصالين
PostgreSQL مستقلين. في الحالتين رُصد الاتصال الثاني محجوبًا على قفل النية:

- نفس `command_id`: Accepted واحد، Replayed واحد، جلسة تالية واحدة، ورسم
  واحد للجلسة المغلقة.
- معرفا أمر مختلفان لنفس البصمة: الأثر نفسه مرة واحدة وإقرار تاريخي مطابق.

قفل النية advisory للتسلسل فقط ولا يمنح أي تفويض. بعد استيقاظ المحاولة
الثانية تقرأ الإقرار المودع على لقطة `Read Committed` جديدة. Replay لأمر
مقبول لا يعيد فحص التفويض الحالي ولا ينفذ P1-B؛ يعيد `business_receipt`
المخزن فقط. أما أمر جديد بلا إقرار سابق فيمر دائمًا بإعادة التفويض الذرية.

# Audit Proof

أضيف `audit.booking_automation_attempts` كسجل append-only. يحفظ الحقول
المنطقية للـActor والمنفذ والمشغل ومصدر التفويض ومعرفات النية والمحاولة
والنبضة والمراجعات والأزمنة والنتيجة والسبب والإيصال.

أثبت AP18 أن السجل الواحد يحمل:

- `actor_kind=system`.
- `actor_ref=booking_automation_system`.
- `executor_id=booking_automation_executor`.
- `operator_profile_id` للمشغل البشري الحقيقي.

كما أصبح سجل إكمال الجلسة القديم لا يضع المشغل في `user_id` عند التنفيذ
الآلي، كي لا يبدو المشغل فاعل التنفيذ. الإسناد الكامل موجود في سجل P2.

# Test Results

الاختبار الدائم:

`supabase/tests/20261006_p2_automated_execution_phase1.test.sql`

يغطي AP1–AP19، مع AP13 مثبت فعليًا في مصنّف الاتصالين. النتيجة النهائية
للبوابة الكاملة:

| الفحص | النتيجة |
|---|---|
| `npm run db:reset` | PASS |
| `npm run db:test` | FILES=53 PASS=1138 FAIL=0 ERROR=0 |
| `npm run db:index` | columns=942 constraints=554 functions=272 triggers=52 |
| `scripts/p2_automation_concurrency_proof.py` | CONCURRENCY PROOF SUCCESS |
| مصفوفة EXECUTE المحلية | المدخل للدور التقني فقط؛ P1-B غير ممنوح للأدوار الأربعة |
| `git diff --check` | PASS |

لم تُشغّل أي هجرة سحابية أو Edge Function أو Cron أو pg_net.

# Remaining Cloud Proof

المتبقي قبل اعتماد Runtime:

1. إثبات كيف تُحوّل مصادقة Edge Function التقنية إلى دور التنفيذ
   `booking_automation_executor` في Supabase الفعلي، من دون منح
   `service_role` المدخل ومن دون JWT بشري.
2. إثبات Vault/secret rotation و`credential_ref` الفعليين.
3. نشر الهجرة لاحقًا وفق قرار مستقل ثم إعادة اختبارات الصلاحيات والتزامن
   على بيئة Cloud غير إنتاجية أو مسار معتمد.
4. تنفيذ Edge adapter وDiscovery وإثبات أن body لا يحدد actor/operator.
5. إثبات Runtime Kill Switch، السجلات، التنبيه، والمصالحة بعد انقطاع الرد.
6. عدم تفعيل Cron أو pg_net قبل اكتمال هذه الأدلة.

# Q-137 Readiness

تعارض `auth.uid()` حُل محليًا من دون منفذ أعمال ثانٍ، وبقي P1-B المنسق
الوحيد. نموذج البيانات احتاج migration فعلية؛ لم يكن function-only كافيًا
لأن نسخة التفويض وربط ON وبصمة النية والتدقيق والمفتاح الذري حالات دائمة.

Phase 1 جاهزة محليًا. Q-137 غير جاهز للاعتماد النهائي أو التفعيل؛ المانع
هو إثبات ربط هوية Edge التقنية بالدور الداخلي في Cloud، ثم إثبات التشغيل
والمراقبة والمصالحة هناك. Candidate A يبقى مرشحًا اجتاز المنصة وLocal DB
Proof، لا Runtime معتمدًا.

| Proof | Result | Remaining Risk |
|-------|--------|----------------|
| Human compatibility | PASS — المسار والتوقيع والرد البشري محفوظة | Cloud regression لم يُشغّل |
| Automated identity | PASS محليًا — Actor ثابت ودور تقني منفصل | ربط Edge بالدور في Cloud غير مثبت |
| Atomic authorization | PASS | Cloud lock behavior غير مثبت |
| Kill switch | PASS داخل قاعدة الأعمال | Runtime kill switch غير منفذ |
| Same-command retry | PASS متزامن | Cloud latency/failure injection باقٍ |
| Different-command duplicate intent | PASS متزامن | Cloud proof باقٍ |
| Unknown outcome recovery | PASS محليًا — stored receipt فقط | قطع شبكة حقيقي عبر Edge غير مثبت |
| Audit attribution | PASS | تصدير/مراقبة السجلات غير منفذين |
| Cloud runtime | NOT RUN | Blocking Q-137 |
| Q-137 readiness | NOT READY | يلزم Identity wiring وCloud runtime proof |
