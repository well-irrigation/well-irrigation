# Android Offline Field Operations and Background Sync Architecture

**آخر تحديث:** 2026-08-23
**القرار الحاكم:** ق-89؛ وق-114 لشق idempotency الخادمي؛
وق-115 لهوية الجلسة وطابور الجهاز؛ وق-117 للإرسال الخلفي
**الحالة:** تصميم تقني ملزم؛ التنفيذ جزئي —
Server-side idempotency منفَّذ (Migration 083+084)،
والطابور المحلي الدائم منفَّذ (`apps/mobile/lib/core/sync/`)،
وسجل الجلسة النشطة منفَّذ (`apps/mobile/lib/core/session/`)،
والإرسال الخلفي منفَّذ في منطق القرار
(`background_sync_*`) بلا إثبات على جهاز، وقياسات بند 9
والشاشات Pending
**أول DB Migration جديدة:** 085 أو أحدث

## 1. الهدف

التطبيق يعمل في آبار ومناطق قد لا توجد فيها تغطية.

لذلك لا يجوز ربط تشغيل البئر بتوفر الإنترنت.

الهدف:

    User action
        ↓
    Durable local commit
        ↓
    Immediate local UX
        ↓
    Persistent outbox
        ↓
    Network becomes available
        ↓
    Background sync
        ↓
    api.*
        ↓
    Business procedure
        ↓
    Idempotent server commit
        ↓
    Local reconciliation
        ↓
    Notifications

## 2. ما لا يجوز

لا يجوز:

- حفظ جلسة حرجة في RAM فقط.
- انتظار الإنترنت قبل بدء السقي.
- تنفيذ Direct DML.
- إعادة إنشاء Command ID في كل Retry.
- الاعتماد على Connectivity Broadcast فقط.
- تشغيل خدمة دائمة فقط لمنع Android من إيقاف التطبيق.
- اعتبار local success = server success.
- حذف Pending command قبل server acknowledgement.
- استخدام سعر وقت Sync بدل سعر وقت الحدث بلا حسم تاريخي.

## 3. Local durable database

Stage 7 يحتاج قاعدة محلية دائمة.

يجب أن تحفظ على الأقل:

- cached master data.
- cached permissions/context.
- active local sessions.
- local session events.
- payments pending sync.
- outbox commands.
- command dependencies.
- local/server ID mapping إذا لزم.
- sync status.
- last server time anchor.
- last successful sync.
- conflicts.
- retry metadata.

اختيار المكتبة النهائي يحسم أثناء التنفيذ، لكن العقد
لا يعتمد على ذاكرة التطبيق.

**محسوم بق-115 (2026-08-23): `sqflite`** — بلا توليد كود.
المنفَّذ من القائمة أعلاه: outbox commands، command
dependencies (عبر المراجع)، local/server ID mapping، sync
status، last successful sync، retry metadata. الباقي —
cached master data، cached permissions، active local
sessions وأحداثها، conflicts، last server time anchor —
جولات تالية. التنفيذ خلف بوابة `OutboxStore` المجرَّدة،
فاستبدال المكتبة لا يلمس المنطق.

## 4. Local command envelope

كل أمر Offline يحتاج Envelope منطقيًا يحتوي:

- command_id UUID.
- command_type.
- aggregate/session local ID.
- well_id.
- actor/profile ID.
- occurred_at.
- sequence number.
- payload.
- created_local_at.
- status.
- retry_count.
- last_error.
- server_result reference.
- idempotency state.

لا يسمح للعميل بإرسال actor مختلف عن الهوية التي
يستطيع الخادم التحقق منها عند Sync.

## 5. Session identity

قبل الاتصال يجب أن تمتلك الجلسة هوية مستقرة.

الحل التنفيذي يجب أن يختار أحد نموذجين فقط:

### Canonical client-generated UUID

UUID الجلسة يولد على الهاتف ويصبح نفسه في الخادم.

### Durable local-to-server mapping

الجلسة تحمل Local UUID، وعند نجاح Start يحتفظ التطبيق
بServer UUID في Mapping دائم وتستخدمه الأحداث اللاحقة.

لا يسمح بمزيج غير حتمي بين النموذجين.

الاختيار النهائي يحتاج Migration/API tests.

### محسوم — ق-115 (2026-08-23)

**النموذج الثاني: Durable local-to-server mapping.**

البرهان من العقد المنشور فعلًا لا من تفضيل:
`api.start_irrigation_session` في Migration 084 **لا تقبل**
معرّف جلسة من العميل — الخادم يولّده ويعيده؛ وإعادة الإرسال
بنفس `p_command_id` تعيد **نفس** المعرّف حرفيًا
(`v_guard -> 'response' ->> 'id'`).

⟹ النموذج الأول يحتاج Migration 085+ لتغيير توقيع دالة
مختومة (071–084 immutable)، أي تعديل عقد مالي مبرهَن مقابل
راحة في الهاتف. مرفوض.

وحماية ق-114 هي ما يجعل الربط بلا لبس: كل إعادة إرسال تعيد
نفس المعرّف الخادمي، فيستحيل ربطان متضاربان لنفس المعرّف
المحلي.

التنفيذ: الحمولة تحمل مرجعًا
`{"$ref": "<local_id>", "kind": "..."}` يُحَل من جدول الربط
عند الإرسال — `apps/mobile/lib/core/sync/command_reference.dart`.

## 6. Command ordering

أحداث جلسة واحدة مرتبة.

مثال:

    START
    PAUSE
    RESUME
    ENERGY_CHANGE
    COMPLETE

لا يرسل COMPLETE قبل نجاح أو حسم START.

يمكن مزامنة Aggregate مختلف بالتوازي إذا لم توجد
علاقة أعمال تمنع ذلك.

## 7. Idempotency

الـServer foundation الحالي في `sync` يعاد استخدامه.

كل Command ID:

- يقبل مرة واحدة.
- يعيد نفس النتيجة عند Retry عندما يكون قد نجح.
- لا يكرر الأثر المالي أو التشغيلي.

**تحديث 2026-08-22 — ق-114 / Migration 083+084:** الثلاثة
أعلاه صارت **منفَّذة ومُثبتة خادميًا** للدورة الميدانية
الأولى (8 عمليات). الأغلفة تقبل `p_command_id uuid` أخيرًا،
والجهة تُستخرَج على الخادم لا من العميل، و`p_command_id =
null` يعطي المسار القديم حرفيًا.

الباقي على طبقة Android:

- توليد Command ID **مرة واحدة لكل عملية ميدانية** وتخزينه
  في الطابور المحلي، وإعادة إرساله بلا تغيير عبر كل
  محاولة. توليد معرّف جديد لكل محاولة يُبطل الحماية كلها.
- تمرير نفس المعرّف مع كل Retry من WorkManager.
- بقية العقود Offline-capable خارج الثماني (ورديات، نقل
  جلسة، حجوزات، مصروفات، توزيعات) لم تدمج idempotency بعد
  ولا تُعتبر جاهزة قبل ذلك.

## 8. Automatic background synchronization

Android implementation يجب أن يستخدم Persistent Work.

المسار الافتراضي:

- One-time WorkManager request عند وجود Pending Outbox.
- NetworkType.CONNECTED constraint.
- Unique Work لمنع عدة Sync Workers متضاربة.
- Retry with backoff.
- re-enqueue بينما توجد عناصر Pending.
- enqueue عند App Start/Resume.
- schedule survives process death.
- recover/reschedule after reboot عبر المنصة.

Expedited Work يمكن استخدامه عند الحاجة، مع fallback
إلى العمل العادي إذا انتهت الحصة.

لا يعتمد التصميم على تشغيل التطبيق في الواجهة.

### محسوم — ق-117 (2026-08-23)

منفَّذ في `apps/mobile/lib/core/sync/background_sync_*` بصفر
تغيير على قاعدة البيانات، ومُتحقَّق منه: 155 PASS / 0 FAIL.

البند كان يقول «re-enqueue بينما توجد عناصر Pending» بلا أن
يحدد **من** يُعيد الجدولة، ولا ماذا يحدث لعنصرٍ معلَّق لن
ينجح أبدًا بلا قرار إنسان. حُسم الأمران:

1. **العامل لا يجدول لنفسه.** قيمة إرجاعه `Future<bool>` هي
   الحوار كلّه مع النظام: `false` ⟹ أعِد بالتراجع المسجَّل
   عند الجدولة، `true` ⟹ انتهى. الجدولة من التطبيق فقط.
   السبب: الجدولة على نفس الاسم الفريد من داخل عامل يعمل
   إما تُلغيه (`replace`) أو تبني سلسلة عمل زائدة (`append`).
2. **«عناصر Pending» ليست كلها قابلة للنجاح.** يُميَّز
   «ينتظر الشبكة» من «ينتظر إنسانًا»: طابور موقوف كله على
   مراجعة **لا يُوقظ الهاتف** (بند 20 من ق-90)، وموقوف بعضه
   على مراجعة وبعضه على الشبكة يُوقظه. والحالة العابرة
   للأصول (أمرٌ يشير إلى أمرٍ مرفوض في أصلٍ آخر) مُغلقة
   بقراءة حالة الأمر المُشار إليه.
3. **الاسم الفريد لكل حساب** لا للتطبيق:
   `well_irrigation_outbox_sync::<accountId>`.
4. **التراجع 30ث ← ساعة ثم يثبت، والسقف على المدة لا على
   عدد المحاولات.** إسقاط أمر من الطابور ضياع مال سقيٍ
   حقيقي؛ ولا استسلام على ما يمكن أن ينجح.
5. **تقدُّمٌ يُصفّر الانتظار**، وتفريغ الطابور داخل النافذة
   الواحدة ما دام هناك تقدّم (بحد أقصى 5 تمريرات)؛ وبلا
   تقدّم تمريرة واحدة فقط.
6. **ثلاثة مصادر إيقاظ:** فتح التطبيق، ورجوعه إلى الواجهة،
   وعودة الشبكة — بكبح 20 ثانية على التلقائي، ولا كبح على
   اليدوي ولا على فتح التطبيق. فتحُ التطبيق **مصدر لازم** لا
   زائد، لأن Force Stop يمنع كل عمل خلفي (بند 10).
7. **لا Expedited Work ولا Foreground Service** في التنفيذ
   الحالي: البند يسمح بها «عند الحاجة» ولا يُلزم، وإرسال
   طابور لا يحتاج حصة معجَّلة ولا إشعارًا دائمًا.
8. **إعادة الجدولة بعد إقلاع الهاتف** يتولاها
   `androidx.work` بمستقبِل الإقلاع الخاص به، فلا مستقبِل
   إقلاع مكتوب في التطبيق ولا صلاحية `RECEIVE_BOOT_COMPLETED`
   مُعلَنة يدويًا.

**غير مُثبت:** التشغيل على جهاز حقيقي (الإقلاع، وForce Stop،
والمانيفست المدموج). المُثبت منطق القرار في Dart وحده.

## 9. Android timing limitation

Android لا يقدم ضمان «نفس الثانية» لمهمة خلفية عادية.

لذلك SLA المنتج الداخلي:

**ابدأ Sync في أقرب فرصة يسمح بها النظام بعد تحقق الشبكة.**

يجب قياس:

- network_available_to_worker_start latency.
- worker_start_to_server_ack latency.
- retry count.
- oldest pending command age.

تستخدم القياسات في M-21 Field Testing.

**حالة التنفيذ — 2026-08-23:** القياسات الأربعة **غير
موصولة**. أسباب الإيقاظ مُعدَّدة في `SyncTriggerReason`
لتصلح للقياس، ورقم المحاولة يُمرَّر إلى العامل ويعود في
`BackgroundSyncDecision`، لكن لا شيء يسجّل الأزمنة ولا عمر
أقدم عملية معلَّقة. مطلوبة قبل M-21.

## 10. Force Stop وRestricted mode

إذا قام المستخدم بForce Stop قد يمنع النظام Background
Work حتى يفتح المستخدم التطبيق مرة أخرى.

بعض الأجهزة تضيف Battery/Auto-start restrictions.

لا يمكن تجاوزها خلسة.

الحل:

- Device Readiness.
- تعليمات واضحة.
- Deep Link إلى إعداد النظام عندما يكون متاحًا.
- إعادة فحص عند كل فتح للتطبيق.
- manufacturer-specific guidance فقط بعد الاختبار.

**حالة التنفيذ — ق-117 (2026-08-23):** الجانب البرمجي منفَّذ:
**فتح التطبيق مصدر إيقاظ لازم** يجدول الإرسال فورًا بلا كبح،
لأنه المخرج الوحيد بعد Force Stop. أما شرح ذلك للمستخدم
وDevice Readiness والـDeep Link فتبقى في W2-02d. وسلوك Force
Stop نفسه **لم يُجرَّب على جهاز**.

## 11. Permissions

### Manifest / platform capabilities

يضاف فقط ما يحتاجه التنفيذ النهائي.

المتوقع عادة:

- INTERNET.
- ACCESS_NETWORK_STATE.
- ما يحتاجه WorkManager عبر تبعياته.
- notification declarations.
- foreground service permission فقط إذا استخدم Flow فعليًا.

### Runtime

Android 13+ يحتاج Notification Runtime Permission
لإشعارات التطبيق غير المعفاة.

### Special settings

Battery optimization/background restrictions لا تعامل
كRuntime Permission عادية.

يفتح التطبيق شاشة النظام ويشرح السبب.

### ممنوع افتراضيًا

لا نطلب للمزامنة وحدها:

- Background Location.
- Exact Alarm.
- Accessibility.
- SYSTEM_ALERT_WINDOW.
- MANAGE_EXTERNAL_STORAGE.

### حالة التنفيذ — ق-117 (2026-08-23)

المعلَن يدويًا في `AndroidManifest.xml`:

- `INTERNET` (كان قائمًا قبل الجولة).
- `ACCESS_NETWORK_STATE` — أُضيفت في هذه الجولة لمؤشِّر
  الاتصال.

ولا شيء غيرهما. الممنوعات الخمس أعلاه غير مُعلَنة، ولا
`RECEIVE_BOOT_COMPLETED` (تُعلنها مكتبة `androidx.work`
لمستقبِل الإقلاع الخاص بها).

**مُسجَّل صراحة ولا يُخفى:** حزمة `workmanager` تدمج في
المانيفست النهائي `POST_NOTIFICATIONS` و`FOREGROUND_SERVICE`
و`FOREGROUND_SERVICE_SHORT_SERVICE`. الأخيرتان يستعملهما
Expedited Work، وهو **غير مستعمل** في التنفيذ الحالي. يُراجَع
هذا على **المانيفست المدموج الحقيقي** قبل النشر على المتجر،
ولم يُراجَع بعد لأن بناء Android لم يُجرَّب أصلًا في بيئة
التطوير الحالية (`androidx.work` غائبة عن Gradle cache).

## 12. Battery optimization

WorkManager هو المسار الأول.

لا يطلب التطبيق Direct Ignore Battery Optimization
بشكل افتراضي.

إذا أثبتت الاختبارات أن وظيفة المزامنة الأساسية تتعطل
على فئة أجهزة محددة:

- يوثق السبب.
- يراجع توافق Google Play.
- يستخدم المسار الأقل صلاحية أولًا.
- يقدم تعليمات يدوية إذا كانت كافية.

## 13. Device Readiness model

يحفظ التطبيق Snapshot غير حساس لحالة الجاهزية:

- notifications_enabled.
- background_execution_restricted.
- battery_optimization_state when detectable.
- background_data_state when detectable.
- last_check_at.
- manufacturer guidance version.

UI تعرض:

- جاهز.
- يحتاج إعداد.
- غير قابل للفحص تلقائيًا.

لا تعرض «جاهز» إذا كانت حالة حرجة Unknown دون توضيح.

## 14. Reminder policy

عند أول تشغيل ميداني:

- شرح كامل.

بعد ذلك:

- Indicator ثابت داخل «المزيد».
- Reminder داخل التطبيق بحد افتراضي مرة كل 24 ساعة
  عندما توجد مشكلة حرجة.
- Reminder مختصر قبل Offline Field Work عند الحاجة.
- لا نكرر System Permission Dialog بلا سبب.

إذا رفض المستخدم Permission:

- نحترم القرار.
- نشرح الأثر.
- نوفر فتح Settings عندما يكون ذلك مناسبًا.

## 15. Offline start

Start Session ينجح محليًا عندما:

- البيانات الأساسية القابلة للتحقق محليًا موجودة.
- local durable write نجح.

عدم وجود شبكة ليس Failure.

تعرض:

    تم بدء الجلسة
    محفوظ محليًا
    بانتظار المزامنة

## 16. Offline pause/resume/energy/complete

كل Event:

- يحفظ أولًا.
- يحدث UX المحلي.
- يدخل Outbox.
- يحصل على sequence.

إذا فشل الحفظ المحلي:

- لا يدعي التطبيق نجاح العملية.
- يظهر خطأ محلي واضح.

## 17. Pricing snapshots

عند كل Sync ناجح يجب تنزيل بيانات التسعير اللازمة
للعمل المتوقع Offline.

Pricing Snapshot يحتاج:

- pricing rule identifier.
- effective period.
- billing model.
- hourly rate أو الحقول المطلوبة.
- energy source context.
- version/update marker.

إذا وجد Snapshot صالح:

- يستخدم للعرض الجاري.

إذا لم يوجد:

- التشغيل لا يمنع.
- amount counter لا يدعي رقمًا غير موثوق.
- يظهر Pricing Pending.

## 18. Historical price resolution

عند Sync يجب أن يحسم Backend السعر باستخدام Event Time.

اختبار القبول يجب أن يغطي:

- session started Offline.
- price changed on server later.
- sync happened after price change.
- session still receives rule effective at original start time.

إذا البنية الحالية تحقق ذلك، يثبت الاختبار.

إذا لا تحقق ذلك، تصلح في Migration 085+.

## 19. Time integrity

أثناء آخر اتصال يحتفظ التطبيق:

- server timestamp.
- local wall-clock timestamp.
- monotonic elapsed anchor.
- boot/session marker.

أثناء نفس Boot يفضل حساب elapsed duration من Monotonic
Clock لا من تغييرات Wall Clock.

إذا اكتشف:

- تعديل كبير في ساعة الهاتف.
- reboot مع timeline غير موثوق.
- event ordering impossible.

يضع Time Integrity Flag.

لا يعدل التكلفة بصمت.

## 20. Offline payment

الدفعة الميدانية Offline:

- تحفظ محليًا.
- تحصل على Command ID ثابت.
- يظهر Receipt Local/Pending.
- لا يقال Posted قبل Server ACK.
- Retry لا يكررها.

عند server success:

- يستبدل/يربط receipt المحلي بالمرجع الخادمي.
- تحدث حالة الدفع.
- تنفذ القيود المالية الحالية مرة واحدة.

## 21. Farmer/Farm inline Offline create

لضمان أن Start Session لا يتعطل أمام مزارع جديد:

- create farmer inline يجب أن يدعم Offline.
- create farm inline يجب أن يدعم Offline بعد تنفيذ
  صلاحية المشغل المعتمدة.

كل كيان يحتاج Local UUID/Command ID وDedup Profile ق-88.

عند Sync:

- Search/Dedup server-side أولًا.
- exact existing يعاد استخدامه.
- لا ينشأ duplicate بسبب Offline create.
- mapping يحدث قبل إرسال Session التي تعتمد على الكيان.

## 22. Dependency graph

مثال مزارع وأرض وجلسة جديدة بالكامل Offline:

    CREATE_FARMER
        ↓
    CREATE_FARM
        ↓
    START_SESSION
        ↓
    PAYMENT
        ↓
    COMPLETE_SESSION

Worker لا يرسل Child Command قبل حسم Parent IDs.

## 23. Conflict handling

أنواع أولية:

- permission revoked.
- farmer duplicate resolved to existing.
- farm duplicate resolved to existing.
- pump conflict.
- pricing ambiguity.
- time integrity issue.
- server state already completed.
- payment conflict.

Conflict لا يحذف الأمر.

يعرض للمستخدم/المالك وفق حساسية الحالة.

## 24. Notifications after Sync

بعد قبول الخادم للأوامر:

- notification events تنشأ مرة واحدة.
- M-23 هو مرجع قنوات الإشعار الحالية.
- Android push transport يدمج مع المنظومة المعتمدة
  عند تنفيذ M-23.
- عدم وجود Notification Permission لا يمنع مزامنة
  البيانات نفسها.

## 25. Security

لا يخزن محليًا:

- service_role.
- admin secret.
- plaintext password.

Local database تحمى بوسائل المنصة المناسبة.

Offline command لا يمنح صلاحية جديدة.

Server revalidates authorization عند Sync وفق العقد
المحدد، مع سياسة Conflict واضحة إذا تغيرت الصلاحية
بعد وقوع حدث Offline مشروع.

## 26. Permission revocation while Offline

إذا كان المستخدم مصرحًا عند آخر Sync ثم سحبت الصلاحية
أثناء عدم اتصاله:

لا يوجد حل آمن بالتخمين.

يجب أن يعرف Backend:

- event occurred_at.
- last_authorization_snapshot.
- current authorization.

وقاعدة الأعمال تحدد هل يقبل الحدث التاريخي أو يحوله
للمراجعة.

لا يرفض/يقبل بصمت دون سياسة موثقة.

## 27. Sync status model

UI تحتاج حالات:

- Local only.
- Pending.
- Syncing.
- Synced.
- Failed.
- Conflict.

وتعرض:

- آخر مزامنة ناجحة.
- عدد Pending.
- أقدم Pending.
- الخطأ القابل للإجراء.
- زر إعادة المحاولة اليدوية.

## 28. Acceptance tests

قبل إغلاق ق-89 يجب إثبات على جهاز/محاكي Android:

- start session airplane mode.
- pause/resume Offline.
- energy change Offline.
- complete Offline.
- advance payment Offline.
- kill app process.
- network returns with app UI closed.
- background sync occurs when OS schedules it.
- reboot with Pending outbox.
- retry after mid-request network loss.
- duplicate retry produces one server effect.
- price changes before delayed sync.
- device clock changes.
- notification permission denied.
- battery restricted mode.
- manufacturer-specific field test where available.
- no data loss after process death.

## 29. Definition of Done

ق-89 يغلق تقنيًا فقط إذا:

- ~~Local DB موجودة~~ — **موجودة** بق-115 لنطاق الطابور
  والربط والحالة؛ البيانات المرجعية المُخزَّنة والجلسات
  النشطة باقية.
- ~~Outbox موجود~~ — **موجود** بق-115: مرتَّب، دائم على
  القرص، بمعرّف عملية ثابت، وبحجز شرطي.
- Worker موجود — **باقٍ.** الإرسال اليوم يجري عندما يكون
  التطبيق مفتوحًا فقط.
- ~~api idempotency مربوط~~ — **مربوط خادميًا** بق-114 /
  Migration 083+084 للدورة الميدانية الأولى (8 عمليات)،
  **ومربوط من الطابور** بق-115: المعرّف الثابت يُرسل فعلًا
  ويُبرهن باختبار «أُرسل مرتين، نُفِّذ مرة». يبقى توسيع
  النمط لبقية العقود Offline-capable.
- critical Offline commands موجودة — الثماني مُغلَّفة في
  الطابور؛ لا واجهة تُدخلها بعد.
- conflicts لها UX.
- permissions/readiness لها UX.
- notifications مدمجة.
- tests دائمة ناجحة.
- M-21 field tests تشمل مناطق ضعيفة التغطية.

## 30. ق-90 — Device Readiness UI Contract

Device Readiness لا يختصر في Boolean واحد.

النموذج المنطقي يحتوي على الأقل:

### Offline capability

- local database writable.
- outbox writable.
- active session recoverable.
- command ID persistence healthy.
- required local master data availability.

### Background sync capability

- worker scheduling available.
- app restriction state when detectable.
- battery/background restriction state when detectable.
- pending work age.
- worker last result.

### Notifications

- permission state.
- channel state where applicable.

لا تستخدم Notification failure لتغيير Offline capability.

## 31. Sync Summary Model

واجهة UX-10 تحتاج Summary محليًا على الأقل:

- last_successful_sync_at.
- pending_count.
- oldest_pending_at.
- syncing_count.
- failed_transient_count.
- conflict_count.
- local_only_count.
- last_worker_attempt_at.
- last_worker_result.
- readiness severity.

إذا احتاج بعضها Server Confirmation، يضاف عقد api
محدد بدل قراءة جدول داخلي.

## 32. Severity Priority

الأولوية:

1. Conflict يحتاج تدخلًا.
2. Permanent/Actionable failure.
3. Device setting يحتاج تدخلًا.
4. Pending/Syncing طبيعي.
5. Ready.

Transient network retry لا يصعد إلى حالة حرجة بمجرد
محاولة فاشلة واحدة.

## 33. Blocking Policy

### Warning only

- no network.
- notifications denied.
- battery restriction.
- background restriction.
- ordinary pending commands.
- delayed WorkManager execution.

### Blocking

- durable local DB write failed.
- outbox write failed.
- stable command identity cannot be persisted.
- required local session data invalid.
- operation would certainly corrupt local session state.
- documented critical conflict affects the exact operation.

كل Block يحتاج رسالة قابلة للإجراء.

## 34. Reminder Deduplication

Reminder record يحتاج منطقًا محليًا يضمن:

- نفس المشكلة لا تظهر مرارًا خلال أقل من 24 ساعة
  أثناء الاستخدام العادي.
- critical pre-field warning يمكن أن يظهر قبل عملية
  ميدانية حساسة عند الحاجة.
- حل المشكلة يلغي حالة reminder.
- رفض permission لا يسبب loop يفتح System Dialog
  بصورة متكررة.

## 35. UX-10 Acceptance Tests

يجب اختبار:

- notifications denied + Offline start still works.
- notifications denied + data sync still works.
- background restricted + local session still works.
- battery restricted + local session still works.
- local DB unwritable blocks Offline start.
- outbox failure blocks unsafe command.
- pending count survives process death.
- oldest pending age remains correct.
- manual sync does not duplicate automatic worker.
- transient failure retries automatically.
- conflict stops blind retry and appears as Review.
- per-session sync badge reflects state.
- Force Stop then reopen preserves pending commands.
- reboot preserves pending commands.
- 24-hour reminder deduplication.
- manufacturer guidance absent when not validated.
- status is understandable without color.
