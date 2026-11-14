# تدقيق قفل SQLite بين المقدمة والعامل الخلفي

**القرار الحاكم:** ق-138
**التاريخ:** 2026-11-13
**المعرّف الداخلي للمرحلة:** F-SYNC
**الحالة:** CLOSED / IMPLEMENTED + LOCAL VERIFIED + DEVICE ACCEPTED +
CI VERIFIED + MERGED

**إغلاق Git (2026-11-13):** PR #70 (`fix/android-sqlite-ownership`) ·
PR HEAD `656f73d407861a71ae728c56066ac54d621ac322` · CI workflow
`checks`، run `43482437255`، conclusion `success` (2 successful /
0 failing / 1 skipped) · merge commit
`b7736d18cdffd89b39b776392256e2598a62f834` · وقت الدمج
`2026-11-13T18:36:21Z`. الحالة السابقة `GIT CLOSEOUT PENDING` صارت
**تاريخًا**. الإغلاق في Git ليس نشرًا سحابيًا، ولا يغيّر عقد `api` ولا
دلالات المال، ولا يغلق F-RECON.

هذه الوثيقة هي **المصدر التقني التفصيلي** لعطل تعليق SQLite على Android
وللرقعة الإنتاجية التي أعالجته. أي وثيقة أخرى تذكر أرقامًا أو آلية أو
دليلًا لهذا العطل فتشير إلى هنا ولا تنسخ التفصيل.

---

## 1. حدود الدليل

الأدلة أدناه كلها من جهاز فعلي واحد:

```text
Samsung SM-A136U · Android 12 · API 31 · ADB serial RFCR509CBWW
```

لا تُعمَّم النتائج على كل الأجهزة أو على كل إصدارات أندرويد. ولا يُستنتج
غياب العطل من نجاح `sqflite_common_ffi` على المضيف، لأن البيئة المضيفة
لا تنفذ تجمع عمال Android ولا أقفاله.

**ما لا تدّعيه هذه الوثيقة:** لا تدّعي ملكية عامة لملف SQLite، ولا حلًّا
عامًّا لأي تعارض كتابة، ولا إصلاحًا لعطل مستقل آخر اسمه F-RECON
(القسم 12).

---

## 2. المشكلة كما ظهرت للمستخدم

تجمّد التطبيق دقائق عند وصوله للمقدمة، وأحيانًا بقي واقفًا على شاشة
البدء. الشاشات المتأثرة بالتتابع: البداية، المزارعون، الأراضي، حجز
الجلسة والملاحة، سجل الجلسات، تفاصيل الجلسة. ثم تعود الشاشات للعمل
دفعةً واحدة بعد فترة قصيرة من نفس اللحظة، لا واحدة بعد أخرى ببطء طبيعي.

هذا النمط — إغلاق متزامن ثم فتح متزامن — هو ما وجّه التشخيص إلى مورد
واحد محتجز لا إلى بطء شبكة أو استعلام.

---

## 3. الأدلة المقيسة قبل الإصلاح

أُضيف تشخيص `SQLITE_TX_DIAG` ذو الأسماء الثابتة فقط: اسم المعاملة،
المرحلة (`queued`/`begin`/`commit`/`rollback`)، `elapsed_ms`، `wait_ms`،
علامتا `over_100ms` و`over_10s`، وأصل `foreground`/`background`. لا مسار
قاعدة ولا IDs ولا حمولة ولا رسائل استثناء.

قيم الجهاز المسجلة:

| الواقعة | المقياس |
| --- | --- |
| `SqliteOutboxStore._bookingTransaction` · `origin=background` | `elapsed_ms=132841` ≈ 2m13s |
| `SqliteNotificationEventStore.recoverScheduleLeases` · `origin=foreground` | `elapsed_ms=263242` ≈ 4m23s |
| `SqliteOutboxStore.openDatabase` | `elapsed_ms=87541` · `open_failed` |
| `SqliteOutboxStore.sessionSnapshot` | `wait_ms=82644` |

كان مسار `_bookingTransaction` المرصود مرتبطًا بـ
`_recoverBookingRegistrations`.

### 3.1 المفتاح: توقيت تحرير المعاملة

```text
recoverScheduleLeases commit   18:40:17.496
sessionSnapshot begin          18:40:17.508
```

بدأت قراءة الواجهة بعد تحرير المعاملة المقابلة بنحو **12ms** فقط. أي أن
القراءة كانت تنتظر طويلًا ثم تقدّمت لحظة تحرير القفل، لا لحظة تحسّن
الشبكة أو الحرارة. هذا وحده يستبعد بطء الخادم والشبكة وحجم البيانات
كسبب رئيسي.

---

## 4. استبعاد Supabase

قياسان مستقلان لعمليتين ماليتين قبل الإصلاح:

```text
financial adjustment
requested        ≈ 14:40:19
local attempt    ≈ 14:40:22
Supabase ingress  14:44:48.811Z
server processing ≈ 517ms

session correction
requested        ≈ 14:52:56
local attempt    ≈ 14:52:59
Supabase ingress  14:57:28.333Z
server processing ≈ 654ms
```

المسافة بين `local attempt` و`Supabase ingress` تقارب أربع دقائق، بينما
المعالجة على الخادم نصف ثانية إلى ثلثي ثانية. إذن **التأخير يحدث قبل
وصول HTTP إلى Supabase**، ولا يمكن أن يكون Supabase أو الخادم سببًا
للتعليق. الخادم كان يستجيب بسرعة طبيعية كلما وصل الطلب.

---

## 5. عنصر Outbox بالتسلسل 55 ليس السبب

وجد في المخزن عنصران متتاليان:

```text
sequence 54  startIrrigationSession    status=review
sequence 55  completeIrrigationSession status=pending
             command_id=d338d8d9-d0ea-4eb7-b218-a5c2ce368e73
```

العنصر 55 تابع للجذر 54 الموجود في `review`، ولم يكن له
`last_attempt_at`. هذا يعني أنه **لم يُحاول إرساله أصلًا**، فلا يمكن أن
يكون هو المعاملة التي تحمل قفل الملف أثناء التعليق.

التصنيف المعتمد: `separate historical recovery/cleanup debt` — دَين
تنظيف تاريخي مستقل عن F-SYNC. **لا يُحذف** ولم يُحذف.

---

## 6. آلية العطل: starvation بعامل واحد

### 6.1 ما يقوله مصدر التبعية وقت العطل

في `sqflite_android 2.4.3`:

```java
// SqflitePlugin.java
static private int THREAD_COUNT = 1;
```

المصدر يبين:

- تجمع عمال (`DatabaseWorkerPool`) **ساكن ومشترك** على مستوى العملية.
- عدد العمال الافتراضي **واحد**، فيُنفَّذ كل عمل قاعدة على مؤشر واحد.
- `Database.java` يحرس `transactionId` داخل الاتصال الواحد؛ **اتصال
  مستقل للملف نفسه لا يشترك في هذا الحارس**.

### 6.2 النمط المثبت

```text
connection A begins transaction and holds SQLite lock
connection B waits for that lock on the only Android worker
connection A needs the same worker to continue/commit
=> starvation / deadlock-like long wait
```

لهذا فُقد الاتصال المفتوح للتطبيق (المقدمة) والعامل الخلفي
(`WorkManager` isolate) يتنافسان على **عامل واحد** بينما اتصال A يحمل
قفل الملف. كلاهما يملك اتصاله الخاص إلى `resolveOutboxDatabasePath`
نفسه، فلا يوجد مالك تصريف مشترك بين العازلين.

### 6.3 الصياغة المعتمدة

```text
Android sqflite single-worker starvation under competing same-file connections
```

**لا** يوصف بأنه `Dart logical deadlock` قطعي: لا يوجد إثبات على مستوى
Dart بأن حلقة انتظار مغلقة، بل إثبات على مستوى جدولة العامل الأصلي
على Android.

### 6.4 ما لم يُقلب ولماذا

لم يُقلب `singleInstance` إلى `true`: مسار `recoveredInTransaction` في
`sqflite_common/database_mixin.dart` قد يرسل `ROLLBACK` عند إعادة فتح
اتصال موجود، فلا يصلح إصلاحًا تخمينيًا للتزامن بين المحركين. و
`RandomAccessFile.lock` في Dart على Linux/Android قفل على مستوى
العملية، لا يفصل عازلين داخل العملية نفسها.

---

## 7. لماذا انتشر العطل إلى شاشات كثيرة

`main` ينتظر فتح مخزن الإشعارات قبل `runApp`. وبعد نجاح bootstrap تنتظر
`IdentityGate.reload` حفظ `BootstrapIdentityCache`. وقراءات الحجوزات
تستخدم الملف نفسه، وبعضها يستعيد تسجيل الحجوزات داخل معاملة.

فيصحّ أن **قفل ملف واحد يعطّل البداية والشاشات مع نجاح HTTP تمامًا**؛
وهذا هو الانتشار المرئي. لم تُضف مهلة ولا `workaround` في الواجهات
لإخفاء ذلك، لأن إخفاؤه كان سيجعل العطل يبدو بطئًا في الشبكة.

---

## 8. اختبار A/B: إثبات أن العامل الأحادي هو الشرط

استُخدم مؤقتًا لإغلاق التشخيص فقط:

```dart
final sqfliteOptions = SqfliteOptions()
  ..androidThreadCount = 2;

await Sqflite.devSetOptions(sqfliteOptions);
```

في المقدمة والخلفية قبل فتح SQLite. النتيجة على **نفس الهاتف ونفس
البيانات**:

```text
startup          no long stall
farmers          no long stall
lands            no long stall
session list     no long stall
session details  no long stall
```

ثم العملية المالية `financial adjustment 57 -> 56` وصلت وقُبلت في نحو
`3.8s` بدل نحو `4m30s`.

هذا يثبت أن العامل الأحادي هو **الشرط التنفيذي** للعطل مع بقاء كل شيء
آخر ثابتًا، ويستبعد تغيّر بيانات أو شبكة أو نسخة خادم كتفسير. لم يكن
هذا هو الحل الإنتاجي، لأنه يعتمد على واجهة `Deprecated('Dev only')`.

---

## 9. الإصلاح الإنتاجي: نسخة vendored

لا يوجد `devSetOptions` في الحل النهائي.

اعتُمدت نسخة محلية مثبتة من الحزمة داخل المستودع:

```text
third_party/sqflite_android/        (sqflite_android 2.4.3)
```

التغيير الإنتاجي الوحيد عن الأصل:

```diff
-static private int THREAD_COUNT = 1;
+static private int THREAD_COUNT = 2;
```

ويشير `apps/mobile/pubspec.yaml` إلى المسار المحلي عبر
`dependency_overrides`، وقد انعكس ذلك في `pubspec.lock` كمصدر `path`
بدل `hosted`. الإصدار يبقى **`2.4.3`**، ولا توجد ترقية عامة لبقية
dependencies.

تفصيل الرقعة ومصدرها وتجزئتها وحدود ضمانها في
`third_party/sqflite_android/PATCHES.md`.

القيمة تُقرأ عند إنشاء تجمع العمال، قبل أول فتح قاعدة. المقدمة ومحرك
`WorkManager` الخلفي يستخدمان الإضافة نفسها، والعملية المنفصلة تحصل على
القيمة الابتدائية نفسها من ملف الإضافة المجمّع. لا تغيير في
`singleInstance` ولا في دورة حياة الاتصالات ولا في المعاملات ولا في
مخزن الأوامر ولا في مخطط SQLite.

---

## 10. البدائل المستبعدة

| البديل | سبب الاستبعاد |
| --- | --- |
| `Sqflite.devSetOptions` كاعتماد إنتاجي | موسوم `Deprecated('Dev only')`؛ صالح لإثبات A/B فقط |
| ترقية إلى `2.4.6` | المراجعة أثبتت أن العدد الافتراضي بقي `1`، ولا يوجد دليل upstream يثبت إصلاح هذا العطل تلقائيًا |
| زيادة busy timeout أو إطالة retry | لا تزيل starvation، وقد تُطيل مدة الانتظار فقط |
| تعطيل `WorkManager` | يكسر ضمانات العمل دون اتصال والخلفية (ق-89/ق-90) |
| تنظيف Outbox وحذف العنصر 55 | العنصر ليس السبب؛ الحذف يمحو أثرًا تاريخيًا بلا أساس |
| إضافة إضافة أصلية خاصة بالملكية | لم يعد الخيار الأول لأن الرقعة الأصغر أثبتت نجاحًا فعليًا على الجهاز |

---

## 11. الاختبارات المحلية للإصلاح الإنتاجي

| المجموعة | PASS | FAIL | SKIP | LOAD_FAILURE |
| --- | ---: | ---: | ---: | ---: |
| Android الأصلية | 11 | 0 | 0 | 0 |
| المركزة | 53 | 0 | 0 | 0 |
| sync/recovery/notifications | 2144 | 0 | 0 | 0 |
| full mobile package | 3359 | 0 | 0 | 0 |

وأيضًا:

```text
flutter analyze   = 0 issues
git diff --check  = PASS
```

### 11.1 RED/GREEN لاختبار تقدم مالك المعاملة

الاختبار المضاف إلى `DatabaseWorkerPoolTest.java` يحاكي اتصالًا يحمل
معاملة واتصالًا آخر ينتظر قفل SQLite، ويتحقق من إمكان تشغيل استمرار
المالك دون إنهاء مهمة الانتظار:

- `worker=1` → **FAIL**
- `worker=2` → **PASS**

**حدّ الدليل:** هذا الاختبار يستخدم عمالًا وهميين وجدولة حتمية. **لا
يحاكي أقفال SQLite الفعلية ولا Flutter engines**، ولا يغني عن قبول
الجهاز.

---

## 12. قبول الجهاز للإصلاح الإنتاجي

بعد بناء التطبيق باستخدام النسخة vendored الحقيقية:

```text
startup                          PASS
farmers                          PASS
lands                            PASS
bookings / session navigation    PASS
session history                  PASS
session detail                   PASS
no long SQLite/UI stall observed
```

`WorkManager` بقي نشطًا ولم يتوقف مع الرقعة:

```text
19:40:02 BackgroundWorker start
19:40:05 SUCCESS
```

وجولة كاملة مع إعادة محاولة:

```text
19:41:38 start
19:41:43 RETRY
19:42:13 retry starts
19:42:16 SUCCESS
```

وبعد force-stop:

```text
19:42:34 BackgroundWorker start
19:42:37 SUCCESS
```

**`RETRY` هنا ليس فشلًا**: المحاولة التالية انتهت `SUCCESS`. والقراءة
المعتمدة أن ظهور `WorkManager` لم يعد متزامنًا مع تجمّد التطبيق بالدقائق.

### 12.1 التعديل المالي النهائي بعد الرقعة

الجلسة التجريبية `3ff580e6-bfa4-423f-82c3-8114119a7e97`، والاختبار
الأخير `56 -> 55`:

```text
command_id             = 89422cd8-af66-493c-81be-d0a535297d07
status                 = accepted
previous_effective_minor = 56
approved_amount_minor  = 55
delta_minor            = -1

requested_at = 2026-11-13 16:41:38.111097+00
accepted_at  = 2026-11-13 16:41:42.734034+00
=> ≈ 4.62 seconds
```

Canonical بعد القبول:

```text
approved_amount_minor      = 55
manual_approval_revision   = 3
row count for last command = 1
```

أي `canonical readback PASS` و`no duplicate PASS`.

---

## 13. المخاطر والصيانة المستقبلية

1. **الرقعة ليست ضمانًا عامًّا.** يبقى ترتيب كل اتصال وارتباط معاملته
   بالعامل كما في upstream. الرقعة ترفع عدد العمال، ولا تنشئ قفل ملكية
   عامًّا ولا تجعل كتابات SQLite متوازية. SQLite ما زال يحكم تعارض
   الكتابة، وحجز الأوامر وreceipt-first يظلان مسؤولية core الحالي.
2. **الانحراف عن upstream مقصود ومحدود.** الرقعة سطر واحد، وآثارها
   موثقة في `third_party/sqflite_android/PATCHES.md`.
3. **كل ترقية مستقبلية لـ`sqflite`/`sqflite_android` تُبطل دليل القبول.**
   يجب مراجعة العدد الافتراضي في الإصدار الجديد upstream أولًا، ثم
   إعادة إنشاء الرقعة، ثم إعادة قبول الجهاز.
4. **إعادة الحزمة إلى مصدر hosted تلغي الرقعة صامتة** إن لم تُراجع
   `dependency_overrides`. لذلك جُعل هذا فحصًا ثابتًا (الثوابت 769–773).
5. **لا ضمان جدولة مطلق لكل عدد من الاتصالات.** زيادة العدد إلى قيم
   أكبر أو إضافة اتصالات جديدة تحتاج قياسًا لا افتراضًا.
6. **دَين مستقل غير مغلق:** `sequence 55` وتصفية التصحيحات (F-RECON)
   مسألتان منفصلتان عن هذا العطل، ولا يُستنتج إغلاقهما من إغلاق F-SYNC.

---

## 14. الحالة النهائية المعلنة

```text
F-SYNC:
CLOSED
IMPLEMENTED
LOCAL VERIFIED
DEVICE ACCEPTED
CI VERIFIED
MERGED
```

**دليل الإغلاق (2026-11-13):** PR #70 · PR HEAD
`656f73d407861a71ae728c56066ac54d621ac322` · CI workflow `checks`،
run `43482437255`، `success` (2 successful / 0 failing / 1 skipped) ·
merge commit `b7736d18cdffd89b39b776392256e2598a62f834` ·
`2026-11-13T18:36:21Z`.

**التاريخ المحفوظ:** حتى دمج PR #70 كانت الحالة
`IMPLEMENTED + LOCAL VERIFIED + DEVICE ACCEPTED + GIT CLOSEOUT PENDING`
(لا commit ولا push ولا PR ولا CI ولا merge). ذلك الوصف صحيح زمانه فقط
ولا يُقرأ كحالة اليوم.

**ولا تعني هذه الحالة:** نشرًا سحابيًا، ولا تغييرًا في عقد `api`
أو في دلالات المال، ولا إغلاق F-RECON **من هذه الرقعة**، ولا ضمان ملكية
عامة لملف SQLite. **إحالة أمامية (2026-11-14):** تلقت F-RECON قرارها
ق-139 ومستهلكها التلقائي، وحالتها الآن `CLOSED / PASS` — التنفيذ مغلق
والتفعيل السحابي مثبت، والمسار التلقائي الإنتاجي تحقق كاملًا في
`2026-11-14` بتصحيح شرعي واحد بلا نداء يدوي؛ عنصر `F-RECON-E2E` أغلق
في `../memory/OPEN_ISSUES.md`. لا يُعاد هنا أي استنتاج من F-SYNC.
إعادة Device Acceptance شرط دائم عند أي ترقية أو إزالة `third_party/`
أو تغيير worker count (الثوابت 769–773).
