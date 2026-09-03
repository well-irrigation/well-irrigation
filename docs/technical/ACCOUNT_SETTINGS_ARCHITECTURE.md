# Account & Settings Architecture

**آخر تحديث:** 2026-09-03
**القرار الحاكم:** ق-101 · **ويُفصِّله:** ق-122 وق-123 وق-124
**UX:** UX-16A
**الحالة:** تصميم ملزم؛ التنفيذ الكامل Pending
**المسألة المفتوحة:** م-31 · **الجولة النافذة:** م-41E

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

## 25. دورة حياة الدعوة والتنشيط — ق-123

**الواقع قبل هذه الجولة:** إضافة مشغّل تُنشئ **شخصًا في دفاتر المالك**
(`core.persons` + `core.person_contacts`) لا حساب دخول، ثم تبحث عن ملف
بنفس الهاتف وتربطه إن وُجد. ولا مسار في التطبيق لإنشاء حساب لمشغّل، فدور
المشغّل **غير قابل للاستخدام عمليًّا**، والربط يجري لحظة إنشاء البئر
وحدها.

**العقد المستهدف — خمس حالات لا سادسة:**

    invited          دعوة قائمة، صفر صلاحية، لها انتهاء
      ↓
    claimed          طُولب بها ورُبطت بحساب حقيقي
      ↓
    active           تعيين نافذ بصلاحيات دوره

    expired          انتهت مدتها بلا مطالبة
    revoked          أُلغيت بيد المالك

**ما يُنشأ:** جدول دعوات جديد، **لأن `core.well_assignments.profile_id`
إلزامي** فلا يقبل صفًّا بلا حساب. يحمل: البئر، والدور، والشخص، والهاتف،
و**تلبيدة الرمز**، وتاريخ الانتهاء، وعدّاد المحاولات، ومن دعا، ووقت
المطالبة، والحساب الذي طالَب.

**ما يُعاد استخدامه:** `core.persons` هوية الميدان (ق-80)،
و`core.well_assignments` للتعيين النافذ، و`core.well_partners` الذي
**يحمل أصلًا** `phone` و`profile_id` قابلًا للإفراغ و`invited_at` و
`activated_at` — فنموذج الدعوة للشريك مُهيَّأ في التصميم من مرحلة سابقة.

**ما لا يجوز تكراره:** لا هوية جديدة عند إسناد دور (ق-101 §6)، ولا جدول
أشخاص موازٍ، ولا كلمة مرور يكتبها المالك، ولا ربط بتشابه الأسماء (ق-80).

**حدود الأمن:** الرمز مُلبَّد لا نصًّا؛ وصفر صلاحية قبل المطالبة **مُثبتًا
على الخادم**؛ وشاشة الرقم لا تفشي من هو مسجَّل ولا تُرسل رسالة إلا لرقم
مسجَّل؛ والأرقام النافذة في ق-123 §13.

**مصدر الحقيقة:** التعيين النافذ في `core.well_assignments` وحده. الدعوة
ليست صلاحية.

**حالات الخطأ:** رمز خاطئ (بعدّاد معلَن للمتبقّي) · منتهٍ · مستهلَك ·
مُلغى · رقم غيّره المالك فبطل الربط. كلها **رفض صريح**، ولا واحدة منها
تُعرض «حاول لاحقًا».

**Idempotency:** المطالبة بالرمز نفسه مرتين تُنتج تعيينًا واحدًا. وإعادة
إصدار الرمز تُبطل ما قبله.

**Offline:** التنشيط عمل متصل بطبيعته (يقرأ الخادم). الرمز اليدوي يعمل
بلا رسائل لكنه لا يعمل بلا شبكة.

**Acceptance:** انظر «ما يحتاج اختبارًا» في ق-123.

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

**الأثر المعلَن حتى ذلك البند:** من ينسى كلمة مروره لا سبيل له للعودة.

**ولا تسجيل للهاتف في نظام المصادقة** ولا تحقّق مدمج منه — انظر ق-124.

**وثغرة احتلال الرقم** مقبولة ومسجَّلة في ق-123، وتُغلق مع البند نفسه.
