# Account & Settings Architecture

**آخر تحديث:** 2026-09-21
**القرار الحاكم:** ق-101 وق-130 · **ويُفصِّله:** ق-122 وق-124؛ ق-123 نافذ تاريخيًا فيما لم ينسخه ق-130
**UX:** UX-02 / UX-03 / UX-16A
**الحالة:** ق-130 معتمد وموثق؛ Migration 103 نفذت وتحقق محليًا من أول شريحة
Backend. ق-130/م-44 Partial وما زالا مفتوحين.
**المسألة المفتوحة:** م-31 · م-44

## 1. النطاق

هذه الوثيقة تحكم Account & Settings لمستخدمي الآبار.

Platform Administration خارج النطاق كليًا.

## 2. Unified Account

المبدأ:

    one phone
      ↓
    one person
      ↓
    one account
      ↓
    multiple wells
      ↓
    multiple well roles

لا Account لكل Role.

## 3. Phone identity

Phone تغيير حساس.

لا Direct Edit.

يلزم Trusted Flow مع:

- current authenticated user.
- verification.
- new unique phone.
- OTP.
- canonical identity update.
- Auth/Profile/Person consistency.

## 4. Lost old phone

Recovery يحتاج Support/Trusted Path.

لا يسمح بربط رقم جديد بناء على Name Similarity.

## 5. Password recovery

V1 تستهدف Forgot Password عبر:

- phone.
- OTP.
- new password.

لا يعتمد العميل دائمًا على تدخل يدوي لمجرد نسيان
Password.

## 6. Team roles

Well Team administration تعيد استخدام Canonical Person.

Role Assignment لا ينشئ Identity جديدة.

## 7. Role authority

Role Catalog ليس Authority وحده.

Backend Relationship/Authorization هو المرجع.

تحديث بق-113 (2026-08-22): م-18 مغلقة. الكتالوج صار مصدر
الإنفاذ لأجساد الدوال، فمنح صلاحية في `iam.role_permissions`
يغيّر الصلاحية فعليًا وفورًا. طبقة RLS تبقى على
`iam.has_well_role` كطبقة توافق للقراءة.

## 8. Operator deactivation

لا يسمح Deactivate إذا سيترك:

- open shift.
- active session.
- unresolved transfer.

دون معالجة.

## 9. Partner access

Access removal لا يمحو Historical Partnership Data.

## 10. Notifications

App Preference وAndroid Permission حالتان منفصلتان.

Notification denial لا يمنع Offline operation.

## 11. Device readiness

تستخدم نفس Architecture المعتمدة في ق-89 وق-90.

لا تنشئ Settings نظام Sync جديدًا.

## 12. Local account isolation

Local database/cache/outbox يجب أن تعرف Account Scope.

الحساب B لا يقرأ Cached Private State للحساب A.

## 13. Logout

إذا توجد Pending Commands:

لا تحذف.

Logout State وPending Business Commands مفهومان منفصلان.

## 14. Return of original account

عند تسجيل الحساب الأصلي:

يمكن استعادة Pending Commands التابعة له ومتابعة
Reconciliation.

## 15. Local wipe

أي Wipe Action:

- Support/Advanced only.
- checks pending commands.
- warns explicitly.
- must not silently destroy unacknowledged business work.

## 16. Appearance

V1:

- light.
- dark.
- system.

No custom palette.

## 17. Language

UI V1:

Arabic RTL.

Numbers:

English digits.

## 18. Date/Time display

User-facing date/time uses English presentation.

Examples:

    19/08/2026
    05:25 PM
    19/08/2026 05:25 PM

هذه قاعدة عرض فقط.

Server timestamp semantics تبقى في Backend contracts.

## 19. Platform boundary

هذه الوثيقة لا تمنح أي Platform Admin Authority.

Platform Administration لها:

`PLATFORM_ADMINISTRATION_ARCHITECTURE.md`

بعد اعتمادها.

## 20. Required backend work

Migration 085+ أو Trusted Server work قد تحتاج:

- change-phone orchestration.
- recover-phone orchestration.
- forgot-password endpoint.
- account/session invalidation.
- role lifecycle APIs.
- notification preference APIs.
- identity consistency checks.

## 21. Required Android work

- account-scoped local DB/cache.
- account-scoped outbox.
- safe logout.
- restore original pending context.
- device readiness entry.
- English date/time formatter.
- Android accessibility handling.

## 22. Tests

- duplicate phone rejected.
- role change does not duplicate person.
- logout keeps pending command.
- second account cannot read first account local data.
- return to original account restores own pending state.
- lost-phone recovery cannot hijack identity.
- date/time rendering remains English.
- permissions remain backend-enforced.

## 23. Definition of Done

UX-16A لا تعتبر Production Complete حتى:

- م-31 مغلقة.
- م-18 applicable gap مغلقة.
- Auth flows مثبتة.
- local account isolation مثبت.
- pending logout behavior مثبت.
- notification settings مثبتة.
- Backend tests ناجحة.
- Android tests ناجحة.

## 24. ق-105 — Password Recovery Current Rule

القسم السابق الخاص بتكامل Password Vault بق-103
منسوخ في جانب Vault بق-105.

User Account V1:

- password remains inside Supabase Auth verifier model.
- no recoverable password copy.
- no Platform Admin reveal.
- no password in Local Data.
- no password in Outbox.

Self password change:

- requires appropriate reauthentication.
- updates Auth password.
- does not create recoverable copy.

Forgot Password:

    OTP
      ↓
    verified identity
      ↓
    user chooses new password

Admin-triggered reset:

    reset-required
      ↓
    OTP
      ↓
    user chooses new password

Lost phone:

Identity Recovery first, then verified new phone and OTP.

Password policy follows ق-105.

## 25. دورة حياة الدعوة والحساب — ق-130

### 25.0 حالة التنفيذ — Migration 103 (مدموجة في `main`)

Migration 103 نفذت أول شريحة Backend للحساب القائم/الفريق: لا auto-link
ولا وصول عند الدعوة، ثم قبول الحساب القائم إلى `accepted_pending_owner`
بصفر وصول، ثم تأكيد المالك كتحول الصلاحية الوحيد. الرفض يحفظ التدقيق
ويترك صفر وصول، وتنشيط Partner لا يغير تاريخه المالي.

هذه الشريحة الآن **Merged to main (MR !12) + Local Verified + CI Verified**؛
لكنها **Cloud/Production Pending** (سقف السحابة يبقى 102، لا نشر) و**Flutter
Pending** ولا قبول جهاز. تغطية Acceptance **لا تتوسع** بهذا الدمج: بندا
new/no-Auth trusted finalization (#1 و#2 في §25.14) يبقيان **Pending**،
وهما الشريحة الخلفية التالية **M104 — new/no-Auth trusted finalization**
(المعمارية المستهدفة موثقة في §25.4 أدناه؛ ورقم الهجرة التالي = 104 وفق
`AGENTS.md` §4؛ لكن تفاصيل RPC/الدوال/Edge Function الملموسة لم تُختَر ولم
تُنفَّذ في جولة التوثيق هذه). ما تبقى أدناه هو Target Architecture حتى يكتمل
نطاق ق-130 وتغلق م-44.

### 25.1 الواقع المنفذ قبل ق-130

هجرة 094 ومسار `MemberActivationScreen` حلا فجوة ق-123 الأصلية، لكنهما
اختارا ترتيبًا صار الآن منسوخًا جزئيًا:

    signUpMember
      ↓
    Auth/Profile
      ↓
    claim_well_invitation

هذا الترتيب يستطيع ترك Auth بلا دور إذا لم تنجح المطالبة. كما أن
`core.invite_well_member` يربط الحساب الموجود مباشرة إذا وجد رقمًا
مطابقًا، بلا قبول صاحب الحساب ولا تأكيد المالك.

الدليل الميداني في 2026-09-21 أثبت الحالة الأولى فعليًا في بيئة الاختبار.
لذلك **م-41E تبقى مغلقة تاريخيًا وفق عقد ق-123 الذي نفذته، لكن ق-130 يفتح
م-44 كعقد أحدث؛ لا يعاد وصف 094/095 بأنها مطابقة للعقد الجديد.**

### 25.2 مصادر الحقيقة

- **الهوية البشرية:** `core.persons` + رابط حتمي إلى `iam.profiles` عند
  وجود حساب.
- **الشراكة والحقوق المالية:** `core.well_partners` +
  `core.ownership_share_versions`.
- **الوصول النافذ:** `core.well_assignments`.
- **الطلب قبل الوصول:** دعوة/طلب تنشيط؛ ليست صلاحية ولا حسابًا بالضرورة.
- **Auth:** هوية دخول فقط؛ لا يمثل الملكية ولا الأرباح.

### 25.3 الحالات التجارية المرئية

    بانتظار التنشيط
        ↓
    بانتظار تأكيد المالك
        ↓
    مفعّل

    انتهت الدعوة / أُلغي الوصول / يحتاج تصحيحًا

هذه **حالات UX**. أسماء enum الفيزيائية في DB لا تُخترع قبل التنفيذ،
لكن يجب أن تستطيع البنية تمثيل `accepted_pending_owner` أو مكافئها
بلا إنشاء Auth جديد عديم الدور.

### 25.4 عضو جديد بلا Auth

    Owner adds person + phone + role
        ↓
    Invitation exists, zero access
        ↓
    Member enters phone + 6-digit code
        ↓
    Trusted pre-auth validation
        ↓
    Accepted pending owner, still zero access and no new Auth
        ↓
    Owner confirms intended identity
        ↓
    Member chooses password
        ↓
    Trusted finalization
        ↓
    Auth/Profile ↔ Person + well_assignment become valid together

فشل الرمز أو انتهاء الدعوة أو رفض المالك = **لا Auth جديد**.

طريقة حفظ كلمة المرور قبل Finalization ليست سؤال UX ولا يجوز حلها
بتخزين plaintext أو hash موازٍ في جداولنا؛ لذلك لا تُطلب كلمة المرور
إلا عندما يصبح Finalization مسموحًا.

### 25.5 حساب قائم

    Invitation
        ↓
    Existing authenticated account accepts
        ↓
    accepted_pending_owner
        ↓
    Owner confirms this is the intended account
        ↓
    well_assignment active

لا رمز جديد مطلوب لإثبات هوية حساب مسجّل الدخول بالفعل ما دام القبول
يجري داخل جلسته الصحيحة، لكن **القبول وحده لا يمنح الوصول**. تأكيد المالك
إلزامي لأن خطأ رقم واحد عند الإدخال قد يشير إلى حساب شخص آخر.

### 25.6 الشريك قبل التنشيط

الشريك قد يكون:

    Partner active financially
    Auth = absent
    Invitation = waiting
    well_assignment(partner) = absent

وهذه حالة صحيحة. حقوقه وتوزيعاته وتقاريره التاريخية تتبع Partner +
Share Versions لا Auth. عند التنشيط لا ينشأ Partner ثانٍ ولا تبدأ الأرقام
من الصفر؛ يربط الحساب بالسجل نفسه.

### 25.7 المشغّل قبل التنشيط

Person + Invitation يجوز وجودهما، لكن لا تشغيل ولا بدء جلسة قبل
`well_assignment(operator, active)`. قبول الدعوة وتأكيد المالك هما
بوابة الوصول الجديدة.

### 25.8 الإلغاء والحساب التاريخي

- إلغاء الوصول يوقف Assignment ولا يحذف Auth شرعيًا حمل دورًا سابقًا.
- حساب كان له دور ثم انتهى وصوله **ليس orphan**.
- orphan الممنوع هو Auth جديد لم يحمل دورًا قط بسبب فشل إنشاء/تنشيط.

### 25.9 الهاتف ومنع التكرار

كل مسار يقارن الهاتف بالقيمة المطبّعة المركزية. لا تُحفظ صيغة خام في
`normalized_value`. إذا وجدت بيانات تاريخية متعارضة، لا يدمجها النظام
تلقائيًا؛ تدخل مسار مراجعة بشرية وفق ق-88.

### 25.10 حدود الأمن

- لا Direct DML من Flutter.
- لا فتح `anon EXECUTE` على المخططات الداخلية للتحايل على مرحلة ما قبل
  Auth.
- التحقق السابق لإنشاء المستخدم يمر Trusted Backend / Auth Hook أو حدًا
  خادميًا مكافئًا.
- Supabase Before User Created Hook **مرشح مثبت رسميًا** لرفض Signup قبل
  الإدراج، لكنه ليس إلزام التنفيذ الوحيد.
- أي Finalization يجب أن تكون idempotent؛ إعادة الطلب لا تنتج حسابين أو
  تعيينين أو شريكين.
- إن تعذر تحقيق ذرية حقيقية بين Auth وقاعدة الأعمال، يجب تصميم تعويض
  خادمي fail-closed مثبت بالاختبار؛ لا يترك Auth جديدًا عديم الدور.

### 25.11 إنشاء بئر وعضوية الفريق

بعد نجاح إنشاء البئر:
- الشريك التجاري موجود وحقوقه نافذة من تاريخها.
- دعوات الشركاء والمشغلين تُنشأ تلقائيًا.
- صفحة النجاح تعرض من ينتظر التنشيط ولا تدعي أنهم «مفعّلون».
- صاحب حساب قائم يخضع لنفس قبول الدعوة + تأكيد المالك؛ لا auto-link.

أما المالك الجديد، فFinalization إنشاء حسابه وبئره يجب ألا تنتهي إلى
Auth بلا owner assignment عند فشل خطوة لاحقة. حق التفعيل يبقى محكومًا
بق-106.

### 25.12 حماية تاريخ الشريك

- تصحيح الاسم/الهاتف للشخص نفسه لا يغير Partner ولا Share History.
- استبدال الهوية بعد أثر مالي يحتاج مراجعة إدارية موثقة.
- تخفيض نسبة أو إنهاء شراكة شريك مفعّل يحتاج موافقته، أو مسارًا إداريًا
  استثنائيًا موثقًا عند تعذرها.
- زيادة حصة شخص تحتاج موافقة كل من تنقص حصته بسببها.
- التغيير المالي = Effective Version جديدة، بلا Rewrite تاريخي.

### 25.13 Offline وUX

التنشيط متصل بطبيعته. لا نجاح Offline ولا حساب محلي مؤقت. الرمز اليدوي
يقلل الاعتماد على SMS لكنه لا يلغي الحاجة إلى الخادم عند القبول.

الواجهة تستخدم المقاصد الثلاثة فقط: «تسجيل الدخول»، «إنشاء بئر جديد»،
«لدي دعوة للانضمام إلى بئر»، وتخفي مصطلحات Auth/SQL/enum عن المستخدم.

### 25.14 Acceptance

إغلاق م-44 يحتاج على الأقل:
1. رمز خاطئ/منتهٍ/ملغى لا يغيّر عدد Auth.
2. حساب جديد لا يثبت نهائيًا بلا دور.
3. الحساب القائم لا يحصل على دور بمجرد أن كتبه المالك.
4. قبول الحساب القائم + عدم تأكيد المالك = صفر وصول.
5. تأكيد المالك = Assignment واحد فقط، idempotent.
6. «ليس الشخص الصحيح» = صفر وصول + مسار تصحيح/دعوة جديدة.
7. الشريك غير المنشط تستمر أرباحه ونسبه، وبعد التنشيط يرى التاريخ السابق.
8. إلغاء آخر دور يحفظ Auth الشرعي والتاريخ.
9. صيغ الهاتف المختلفة لا تنشئ Person/Profile مكررًا.
10. إنشاء البئر ينشئ دعوات الفريق تلقائيًا دون ادعاء تفعيلهم.
11. تغييرات النسب لا تعدّل الماضي، وتطبق موافقات المتضررين.
12. Regression يثبت أن شاشة Login لا تنشئ حسابًا.

**تغطية Migration 103 المحلية، لا إغلاق Acceptance كامل:**

- منفذ محليًا: #3 (لا دور لحساب قائم لمجرد إدخال هاتفه)، #4 (قبول بلا
  تأكيد = صفر وصول)، و#5 (تأكيد المالك = Assignment واحد idempotent).
- #6 له تغطية Backend جوهرية للرفض أو الحساب الخطأ بصفر وصول، لكن UX
  التصحيح/إعادة الإصدار الكامل غير مغلق.
- #7 له فصل Backend بين تاريخ Partner والوصول، مع بقاء UX الأوسع وقبول
  الجهاز مفتوحين؛ و#8 يحفظ Auth/Profile الشرعي عند الإلغاء وإعادة الدعوة.
- #9 مغطى في مسار الدعوة هذا وحده: صيغ الهاتف المتكافئة تُطبَّع عبر
  `core.normalize_phone` وتتحلّ إلى الهوية نفسها متى كانت غير ملتبسة؛ أما
  الالتباس التاريخي أو وجود Person غير نشط فيفشل مغلقًا إلى مراجعة بشرية،
  بلا دمج تلقائي ولا إحياء تلقائي ولا إنشاء هوية بديلة. هذا لا يدّعي اكتمال
  التطبيع عبر كل مسارات ق-130.
- ما زال #1 و#2 (new/no-Auth trusted finalization)، والباقي من #6، و#10
  (دعوات إعداد البئر)، و#11 (موافقات تغيير الحصص)، و#12 (Flutter Login
  regression)، والقبول على جهاز حقيقي Pending.

## 26. نطاق قراءة الشريك — ق-123 §8

قرار المالك. المبدأ المكتوب: **الشريك يرى ما يُشتقّ منه نصيبه**، والحدّ
الوحيد الباقي هو الأرقام غير النهائية.

| البند | الشريك |
| --- | --- |
| إيراد الفترة ومصروفاتها وصافيها | يرى |
| حصته ومدفوعاته ورصيده | يرى |
| أسماء الشركاء ونِسبهم | يرى |
| المصروفات بنودًا (تاريخ/نوع/مبلغ/وصف) | يرى |
| من اعتمد المصروف وملاحظاته الداخلية | لا يرى |
| المزارعون وديونهم | **يرى** — قراءة فقط |
| الوقود والجرد | **يرى** — قراءة فقط |
| **حضور** جلسة جارية الآن وعددها | يرى |
| **بيانات** الجلسة الجارية: المستحق، المدة، المضخة | **لا يرى** |
| أي كتابة | لا يملك في هذه الجولة |

**سبب الحدّ الأخير مبدئي لا ذوقي:** الجلسة غير المقفلة لا تدخل مجاميع أي
يوم (ق-37)، فرقمها غير نهائي وسيتغيّر — الثابت 713.

**الفترة المفتوحة** تُعرض **بلافتة صريحة** «غير مُقفلة — أرقام غير
نهائية»: إخفاؤها يُقرأ إخفاءً، ووسمُها يقول الحقيقة.

**النِسب التاريخية:** كل فترة بالنسبة السارية فيها (ق-23)، وإلا لم تتوازن
الأرقام.

**حساب الشريك اختياري:** الشريك قائم بنصيبه استعمل التطبيق أو لا، والدعوة
قد لا يُطالِب بها أبدًا.

**`accountant` و`viewer`:** صفر صلاحيات، ولا يظهران في أي واجهة.

**التنفيذ (هجرة 095 / م-41E المرحلة 4):** الحدّ في **طبقة الصفوف** لا في
عقد واحد — سياستا اطلاع الشريك على `ops.irrigation_sessions` و
`ops.session_segments` تستثنيان `status='open'`، فكل عقد يفوّض على RLS
يستفيد. والحضور يأتي من `api.read_partner_overview` (فوق قارئ
`SECURITY DEFINER` سلطته **شراكة سارية وحدها** وغرض تجاوزه العدّ فقط) بلا
معرّف جلسة ولا مستحق ولا مدة ولا مضخة. و«من اعتمد المصروف» يُفرَّغ في
`api.list_well_expenses` لمن سلطته شراكة وحدها (`iam.is_partner_only`) مع
مفتاح `partner_scope` يُعلن الحدّ. و«المزارعون وديونهم» عقدها
`api.list_well_farmer_balances`. والنِسب التاريخية من
`api.list_well_profit_cycles` كما هي مخزَّنة، والفترة المفتوحة موسومة
`is_final = false` بلا صافٍ محسوب. والشاشة
`lib/features/finance/partner_overview_screen.dart` بلا زرّ كتابة ولا حقل
إدخال — مقيس في حرس الحد. **والمالك ليس ضمن سلطة هذا العقد**: عقوده هو
تعرض الجلسة الجارية بأرقامها، فحصره بالشريك حصرُ نطاق لا حجب معلومة.

## 27. حدّ هذه الجولة — ما ليس فيها ولماذا

**لا استعادة لكلمة المرور.** جلسة المالك لا تستطيع تغيير كلمة مرور شخص
آخر بالتصميم، فأي استعادة — بالمالك أو بالرسائل — تحتاج طرفًا خادميًّا.
وشكلها حين تُبنى هو شكل ق-105 §Admin-triggered: **«مطلوب إعادة تعيين» ←
إثبات هوية ← الشخص يختار كلمة مروره**، لا كلمة مرور يكتبها المالك. ونفس
آلية رمز الدعوة تخدمها.

**✅ بُنيت في م-41F (هجرة 096) — 2026-09-03.** بالشكل المكتوب أعلاه حرفًا:
المالك يُثبت الهوية أمامه ويُصدر تذكرة، ويقرأ الرمز شفويًّا، ويكتب صاحب
الحساب كلمة مروره بنفسه. والطرف الخادمي `supabase/functions/reset-password`
هو الوحيد الذي يطلب من نظام المصادقة التعيين، لأن الاستهلاك ممنوح
لـ`service_role` وحده — والسبب أن `anon EXECUTE = 0` يمنع أي عقد قاعدة
يخدم من لا جلسة له. **والأثر المعلَن:** الاستعادة لا تعمل حتى تُنشر الدالة
الحافة، و**المالك الوحيد** الذي ينسى كلمته يبقى بلا مسار (لا أحد فوقه
يُصدر له تذكرة).

**الأثر المعلَن حتى ذلك البند:** من ينسى كلمة مروره لا سبيل له للعودة.

**ولا تسجيل للهاتف في نظام المصادقة** ولا تحقّق مدمج منه — انظر ق-124.

**ثغرة احتلال الرقم ومسار Auth-before-claim لم يعودا مقايضة مقبولة:** ق-130
ينسخ هذا الجزء من ق-123، وإغلاقهما داخل م-44 شرط قبل اعتبار دورة الحياة
الجديدة منفذة.

## 28. ق-131 — الأجهزة والجلسات النشطة (معتمد توثيقيًا — 2026-09-28)

**الحالة:** Adopted + Documented فقط؛ **غير منفذ**. التنفيذ عبر م-45
(المرحلة D). المصدر الحاكم الكامل: `memory/DECISIONS.md` ق-131.

- مطلب أمني للحساب: عرض الأجهزة/الجلسات التي الحساب نشط عليها بمعلومات
  كافية للتمييز بينها، ودعم إبطال/تسجيل خروج جهاز/جلسة بعينها **حيث
  يسمح عقد المصادقة** — دون ادعاء قدرة لا يوفرها نظام المصادقة الحالي؛
  حدّ القدرة يثبت عند التصميم.
- **دلالات «النشاط» بدليل:** «نشط/آخر نشاط/متصل الآن» تعكس دليلًا: حالة
  جلسة غير ملغاة، و`last_seen` حيث يتوفر، وحضورًا حيًّا فقط إذا أثبتته
  تِلي متري فعلية. **لا يُوصف جهاز «متصل الآن» لمجرد صلاحية جلسته**
  (عائلة لا نجاح كاذب — ق-113).
- لا أسماء جداول أو RPC تُختار هنا؛ أي تنفيذ عبر رقم الهجرة التالي من
  `AGENTS.md` §4 وحدود ق-78/ق-79.
