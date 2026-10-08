# خريطة المشروع — مصادر الحقيقة الحالية

**آخر تحديث:** 2026-10-04

هذه الوثيقة تحدد أي ملف يفوز عند التعارض، وتفصل بين
الحالة الحالية والسجل التاريخي.

باب الدخول لأي وكيل ذكاء اصطناعي هو `AGENTS.md` في جذر المستودع
(و`CLAUDE.md` مؤشِّر إليه). وهو **ليس** في ترتيب السلطة أدناه: لا يقرر
شيئًا، بل يدل على من يقرر ويحمل عقد العمل التشغيلي — من ينفّذ الأوامر،
وحقائق القناة السحابية، والحدود النافذة.

## 1. ترتيب السلطة

من الأعلى إلى الأدنى:

1. `memory/DECISIONS.md`
   القرارات المرقمة. القرار الأحدث الناسخ يفوز على القرار الأقدم.

2. `technical/INVARIANTS.md`
   القواعد التقنية الحالية الناتجة عن القرارات النافذة.

3. `technical/API_ARCHITECTURE.md`
   حدود Flutter وSupabase Data API وعقد الكتابة.

4. `technical/SYNC_ARCHITECTURE.md`
   حالة المزامنة والعمل دون اتصال ومنع التكرار.

5. `technical/DECISION_IMPLEMENTATION_MATRIX.md`
   مطابقة القرارات ذات الأثر التنفيذي مع الهجرات والاختبارات والحالة.

6. `design/VISUAL_IDENTITY.md`
   المصدر الحاكم للهوية البصرية بعد القرارات المرقمة.

7. `reference/`
   المرجع الوظيفي والتصميمي، مقيد دائمًا بالقرارات الأحدث أعلاه.

8. بقية الملفات التاريخية مثل `PROGRESS.md` و`DOC_CHANGELOG.md`
   تحفظ تاريخ ما كان صحيحًا في لحظته ولا تتغلب على الحالة الحالية.

### ق-136 وق-135 وق-134 — المرجع السلوكي وعقود الجدولة والهوية (محدّث 2026-10-08)

- **القرارات الحاكمة:** ق-134 سلوكيًا، وق-135/ق-136 معماريًا وحوكميًا. آخر قرار معتمد يبقى ق-136؛ **q-137 = NOT ADOPTED**.
- **P2 Phase 2B:** دُمجت عبر PR #58 إلى `main` (merge `0dc6e3dac6f1307cc83bd2420e0ddc5222127f7d`). أثبتت Candidate A سحابيًا من حيث الجدولة، الهوية التقنية، التنفيذ المأذون، التزامن، إعادة المحاولة، الإيقاف، المراقبة والتنظيف. الدليل الحاكم: `audit/P2_AUTOMATED_EXECUTION_PHASE2_CLOUD_PROOF.md`. الحالة: **Candidate A = READY FOR Q-137 REVIEW**، بلا Production activation وبلا Cron دائم.
- **الهاتف:** Online-first دُمج عبر PR #59 والمصالحة للقراءة فقط عبر PR #60. الجولة المحلية `feat/p2-mobile-offline-local-transition` تضيف انتقالًا تشغيليًا مؤقتًا من cache مؤهل: دليل إغلاق محلي وجلسة محلية ذات معرف مستقل ووقت فعلي ومعرف نية ثابت، ثم مصالحة فقط. لا أثر أعمال أو مال أو جلسة خادم من الهاتف؛ الانتقال التجاري عبر P1-B ما زال محجوبًا (`BLOCKED_CONTRACT_GAP`). إيقاظ Android الدقيق والإشعارات والقبول الميداني لم تنفذ.
- **NEXT الحاكم:** إكمال قبول P2 على الهاتف ثم مراجعة ق-137؛ لا انتقال إلى P3 قبل تجربة السيناريوهات الفعلية المتفق عليها. M114 وم-28 وم-45 تبقى وفق متتبعاتها ولا يغلقها PR #58 وحده.

[DOC-RECOVERY-Q133-2026-10-03]


### استدراك نطاق ق-133 والمرحلة B (2026-10-03)

- **ق-133** أحدث قرار معتمد من المالك: مدة السقي الحر مشروطة بوجود حجز مؤكد قادم، وتحفظ الأوامر القديمة دون محو أو تزوير زمن. التفصيل المرجعي في `memory/DECISIONS.md` ثم `design/UX_UI_SPEC.md`؛ الثوابت 757–760.
- **M113** منفذة جزئيًا ومدموجة: **PR #47 = Merged** (merge commit `e1d2c689`) و**CI Verified** — GitHub Actions #36 على `main` = SUCCESS (`1071 DB PASS`، `667 Flutter PASS`، فهرس `889/544/261/49` مطابق). **Cloud/Production Pending**: عُطّل `Deploy to production` قبل الدمج، وM113 غير موجودة في سجل migrations لمشروع Supabase `hxfhczpfrfdpzsobfbab` بعد الدمج. **M113 ليست مغلقة** (الانتقال الزمني الكامل والتنبيهات والتوقيت الفائت والتزامن Pending).
- **Flutter/Outbox**: شريحة أوامر غير مرئية منفذة مبكرًا لحماية التوافق (`flutter test` 667/667 و`analyze` نظيف بحسب تقرير الوكيل) **رغم الترتيب الأصلي الذي كان يضع Flutter بعد M114**؛ هذه استثناء تنفيذي محدود لا يعني بدء تصميم الواجهات أو إغلاق Phase B. M114 ما زالت Pending.
- **حدود الإنجاز المجمعة:** M112 منفذة ومدموجة (PR #45، `db45b7d`) بحدود Cloud/Production Pending؛ M113 منفذة جزئيًا (Partial Implemented + CI Verified + Merged عبر PR #47 `e1d2c689`، M113 NOT CLOSED)؛ شريحة أوامر Flutter/Outbox منفذة ومدموجة؛ M114 ما تزال Pending؛ Cloud/Production Pending وM113 غير منشورة سحابيًا؛ م-28 وم-45 وPhase B مفتوحة.
- **المصدر الوحيد للعمل التالي:** `memory/RESUME_POINT.md`؛ لا يُعتمد هذا السجل التاريخي لاستنتاج NEXT.


## 2. مصادر الحقيقة حسب الموضوع

### القرارات
`memory/DECISIONS.md`

آخر قرار مرقم حاليًا: ق-134 — العقود **Adopted + Documented** والتنفيذ
جزئي عبر م-45: **البنود المنفذة = 1 و7 و10 و11 و13 و18 وأساس المرحلة B
(M112)** (بأدلتها الموثقة في `memory/RESUME_POINT.md`
و`OPEN_ISSUES.md`)؛ البنود الباقية Pending (ويبقى مؤشر الوقت
المتبقي/العدّاد وحده مؤجلًا مؤقتًا بقرار المالك). المتتبع: م-45
(مفتوحة).

### المستودع والنشر

GitHub هو المستودع الأساسي ومصدر الحقيقة مجددًا منذ 2026-09-29 بعد
استعادة الحساب (قرار ق-126 بالانتقال إلى GitLab انتهى دوره التاريخي).
دليل الاستعادة: أعاد PR #38 التاريخ الكامل بmerge commit `bbc661ac`،
ثم أُغلق PR #39 التوثيقي بmerge commit `9e9ea68` — دليلان تاريخيان لا
رأس حالي؛ الرأس الفعلي يُؤخذ من Git/GitHub مباشرة. المسار النشط: فرع ←
Pull Request ← فحوص GitHub Actions المطلوبة ← دمج. يبقى GitLab سجلًا
تاريخيًا/احتياطيًا، ومسار نشر production اليدوي فيه إرثي منفصل لم يُنقل
تلقائيًا إلى GitHub. حالة النقل والنشر الحالية تؤخذ من
`memory/RESUME_POINT.md`.

### الحالة التشغيلية الحالية — ما بعد ق-127 وق-129

ق-127 أغلق بوابة ق-120.
ق-129 وم-43 أُغلقتا بعد اجتياز القبول الميداني الشامل على جهاز Android الحقيقي (Samsung Galaxy A13) بنجاح تام عبر 42 بند قبول، وصمود مخزن SQLite بعد موت العملية وإعادة التشغيل، وحل مشكلة دورة حياة SQLite، واجتياز فحص التطبيق (505/505 PASS).
رُفع مانع الإصدار الخاص بتلك الحزمة ورُفع الحظر عن الجاهزية التجريبية آنذاك.

في 2026-09-21 اعتمد ق-130 بعد كشف فجوة مستقلة في دورة Auth/دعوات الفريق.
Migration 103 (أول مسار Backend للحساب القائم/الفريق: لا auto-link، وقبول ثم
تأكيد مالك قبل الصلاحية) **مدموجة في `main` (MR !12) + Local Verified +
CI Verified**، وتلتها M104 (MR !14) وواجهات التنشيط وworkspace المشغل
والشريط الحساس للدور (MRs !15–!17) ثم **MR !19 — مشاركة رمز الدعوة**.
آخر رأس وظيفي لمسار MR !19 = `573a657`؛ وبعد MR !20 التوثيقي صار
رأس `main` حينها = `00b780d` (لحظة تاريخية)، وpipeline `2887593840` = manual
لأن production يدوي ولم يُشغَّل — **لا ادعاء نشر إنتاجي جديد**. **المالك أثبت ميدانيًا على جهاز Android حقيقي بعد MR !19
نجاح مسار مشاركة الدعوة (نسخ/مشاركة/واتساب/رسائل)** — أُغلقت هذه الفجوة
الفرعية وحدها. **م-44 تبقى مفتوحة كـProduction Blocker** وق-130 لا يُغلق:
بقية قبول الجهاز لمساري العضو الجديد والحساب القائم وإصلاحات م-44 كلها
Pending. حالة الهجرات ورقمها التالي يُؤخذان من `AGENTS.md` §4 وحده،
وسقف السحابة يبقى 102. هذا لا يعيد فتح ق-129 أو م-43؛ وق-130 مسألة
أحدث ومستقلة.
سجل القبول الميداني الكامل محفوظ في:
`reports/DEVICE_ACCEPTANCE_TEST_LOG.md` (القسم 8).

الحالة والخطوة التالية تؤخذان فقط من:
`memory/RESUME_POINT.md`.

### توسعة عقد التشغيل والمال والحجوزات والتقارير — ق-131 / م-45

في 2026-09-28 اعتمد المالك **ق-131** (23 بندًا: محاصيل الجلسة المتعددة،
الفاتورة الرسمية وقدراتها، توقيت `Asia/Aden`، نافذة الشمس والمصدر البديل
والانتقال التلقائي عند انتهائها، الزمن الفعلي مقابل المخطط، الحجوزات
بمسار مورد واحد، قواعد المال وديزل المزارع وحيازة المشغل والمصروفات
والمدينين، الأجهزة النشطة، مفهوم المنطقة، ولمسات UX شاملة).
**الحالة:** العقد Adopted + Documented؛ **البند 1 (محاصيل الجلسة)
Implemented + Local Verified + CI Verified + Emulator UX Accepted**؛
MR !21 merged to `main` (`275a99f`)؛ Cloud/Production Pending.
**البند 7 (الزمن الفعلي مقابل المفوتر) Implemented + Local Verified +
CI Verified + Merged / Cloud + Production Pending**؛ MR !24 merged to
`main` (`d3255022`). **البند 11 (تحذير حالة المزارع المالي/الوقودي غير
المانع) Implemented + Local Verified + CI Verified + Merged / Cloud +
Production Pending**؛ Migration 107، MR !26 merged to `main`
(`9168ccac`). **البند 10 (التأكيد الصريح قبل تطبيق الرصيد المقدم)
Implemented + Local Verified + CI Verified + Merged / Cloud + Production
Pending**؛ Migration 108، MR !28؛ وثبت GitHub PR #38 الحالة نفسها قبل
الدمج وبعده — بmerge commit استعادته `bbc661ac`، دليل تاريخي لا رأس
حالي. **البندان 18 (حيازة المشغل النقدية والترحيل) و13 (إثبات المصروف
أو سبب عدم الإرفاق) Implemented + Local Verified + CI Verified + Merged
/ Cloud + Production Pending**: البند 18 عبر M109/M110 (PR #41 merge
`4ca0e019` وPR #42 merge `fbd04125`)، والبند 13 عبر M111 (PR #43 merge
`68919e06`). بقية البنود ما تزال Implementation Pending.

- **المتتبع:** **م-45** في `memory/OPEN_ISSUES.md` — متتبع عابر للنطاقات
  بمراحل A–E، **يعتمد ويتنسق مع م-28 وم-29 وم-30 القائمتين ولا يستبدلهما
  ولا ينشئ معمارٍ موازية**.
- **المصادر التقنية:** أقسام ق-131 في `OPERATIONS_RECORDS_ARCHITECTURE.md`
  و`SESSION_SETTLEMENT_ARCHITECTURE.md` و`MONEY_PARTNERS_ARCHITECTURE.md`
  و`WELL_MANAGEMENT_REPORTING_ARCHITECTURE.md`
  و`ACCOUNT_SETTINGS_ARCHITECTURE.md`
  و`FINAL_CROSS_CUTTING_UX_ARCHITECTURE.md`
  و`PLATFORM_ADMINISTRATION_ARCHITECTURE.md`، وملحق ق-131 في
  `design/UX_UI_SPEC.md`.
- **استثناء ضيق وحيد:** الانتقال التلقائي عند انتهاء نافذة الطاقة الشمسية
  لا يُضعف قواعد التأكيد اليدوي (ق-129/FIN-001)، ويعني تغيير الحالة
  الحاكمة للجلسة ومقاطعها ومحاسبتها — لا تبديل مضخة فيزيائيًا.
- **ترتيب التنفيذ الحالي (قرار المالك 2026-09-29):** جولة الشمس/البديل/
  العدّاد/الوقت المتبقي وحدهما **مؤجلة مؤقتًا** وتبقى Pending؛ ونافذة
  الشمس/المصدر البديل/الانتقال التلقائي عادت إلى التنفيذ عبر M113
  بق-132؛ والبند 12 (تقدير ديزل المزارع ثم تأكيده/تصحيحه صراحةً مع
  فصل المقدّر عن الفعلي): **كان مؤجلًا بقرار المالك 2026-09-29، ثم
  أعاده ق-132 بتاريخ 2026-10-01 إلى نطاق التنفيذ الحالي داخل Phase B
  عبر M114 — بعقده الحاكم نفسه**.
  **البندان 18 (حيازة المشغل/الترحيل — M109/M110، PR #41/#42) و13
  (إثبات المصروفات — M111، PR #43) منفَّذان ومدموجان / Cloud +
  Production Pending** بمعناهما الحاكم الثابت: النقد بيد المشغل مال
  البئر في حيازته لا محفظة شخصية، والترحيل نقل حيازة لا إيراد ثاني،
  والرصيد من الدفتر، وإثبات المصروف مرفق أو سبب صريح بلا نظام موازٍ.
  **المرحلة B نشطة: أساس الحجوزات M112 مدموج (PR #45، `db45b7d`) —
  Implemented + Local Verified + CI Verified + Merged / Cloud +
  Production Pending — والمرحلة غير مغلقة وم-28 غير مغلقة.** الترتيب
  داخلها بق-132: **M113** (Booking Execution / جدول اليوم /
  booking→session / solar fallback والانتقال التلقائي) ثم **M114**
  (Diesel reference-price history + valuation معلوماتي) ثم
  Flutter/Offline/Notifications ضمن المرحلة B نفسها؛ وبعدها C للفاتورة
  الرسمية ثم D لبقية العناصر وفق التسلسل الموثق.

- **ق-130/م-44 مستقلة:** ق-131 وم-45 لا تغلقان ق-130 أو م-44، ولا يُقرأ
  منهما أنهما أُغلقتا.

### أين توقف العمل
`memory/RESUME_POINT.md` فقط — وهو منذ 2026-09-03 رأس قصير.

`memory/RESUME_HISTORY.md` أرشيف السرد الزمني، منقول حرفًا بحرف عند
القصّ. يُقرأ للتاريخ وحده، ولا تُؤخذ منه الخطوة التالية.

لا تستخدم snapshot أقدم داخل PROGRESS أو DOC_CHANGELOG لتحديد الخطوة التالية.

### استلام المشروع بواسطة نموذج ذكاء اصطناعي

ابدأ بـ:

`memory/AI_HANDOFF_PROTOCOL.md`

هذا الملف يحدد ترتيب القراءة وعقد تحديث الوثائق.

لا يحل محل مصادر الحقيقة في ترتيب السلطة.

### أسلوب العمل والتعاون

المصدر:

`memory/AI_COLLABORATION_PROTOCOL.md`

القرارات الحاكمة:

ق-95.

يحدد:

- اللغة وطريقة الشرح.
- دور النموذج.
- منهج اتخاذ القرار.
- طريقة عرض التوصيات.
- Workflow UX.
- التعامل مع الاعتماد.
- التعارضات والفجوات.
- التعامل مع Terminal Output.
- الفرق بين حالات الإنجاز الأربع.

### تفويض التنفيذ إلى وكيل محلي — ق-128

المصدر الحاكم:

`memory/LOCAL_AGENT_EXECUTION_PROTOCOL.md`

الوكيل المحلي منفذ كود محدود فقط.
لا يعدل التوثيق أو الحوكمة ولا ينفذ أوامر المالك.
المهندس الرئيسي يحدد النطاق ويراجع النتيجة
ويتولى دورة التوثيق مع المالك.

اقتصاد الرصيد يكون بتقليل القراءة والتكرار،
ولا يسمح بإسقاط التحقق المطلوب.

### أوامر الطرفية والاستعادة

المصدر:

`memory/TERMINAL_COMMAND_PROTOCOL.md`

القرار الحاكم:

ق-96.

يحدد:

- شرح ما قبل الأمر.
- شكل Command Block.
- Subshell safety.
- Expected HEAD.
- Worktree guards.
- Content checks.
- Commit/Push.
- Recovery بعد الفشل.
- الحوادث السابقة والقواعد الناتجة عنها.

### البيئة الفعلية
`technical/ENVIRONMENT.md` فقط.

### الهجرات المطبقة
`technical/MIGRATIONS.md` فقط.

### المال والوقت
`DECISIONS.md` ثم `technical/INVARIANTS.md`.

الحالة الحالية:

- أصغر وحدة مالية = ريال يمني كامل — ق-77.
- الحقول ذات اللاحقة `_minor` تحتفظ باسمها التاريخي، لكن قيمتها بعد ق-77 هي ريال كامل.
- الزمن يحسب بالثانية.
- لا تقريب للوقت.
- لا تقريب مالي.
- كسر الريال الناتج عن القسمة لا يخزن كوحدة مالية مستقلة.

### توزيع الأرباح
ق-77 هو الحاكم.

بعد القسمة الصحيحة، يذهب كامل باقي القسمة إلى صاحب أكبر حصة.
هذا هو الوصف المعتمد، ولا يسمى Largest Remainder Method في التوثيق الحالي.

### Data API والكتابة
ق-78 وق-79 ثم `technical/API_ARCHITECTURE.md`.

- Exposed Schemas: `api` و`graphql_public`.
- مخططات الأعمال الداخلية غير مكشوفة.
- Direct DML لأدوار التطبيق = صفر.
- Flutter يكتب عبر `api.*`.
- سطح Data API المثبت حاليًا = 34 RPC.

### الهوية البصرية

ق-83 ثم `design/VISUAL_IDENTITY.md`.

- الهوية العامة معتمدة مبدئيًا.
- الشعار الحالي معتمد مبدئيًا وقابل للتطوير لاحقًا.
- العربية RTL أصل التصميم.
- الأرقام الإنجليزية 0-9 ثابتة.
- لم تُنفذ واجهة إنتاجية جديدة نتيجة ق-83.
- الخطوة التالية هي مناقشة الصفحات قبل تنفيذها.

### تجربة المستخدم والواجهات

المصدر الحاكم للتفاصيل:

`design/UX_UI_SPEC.md`

المنهج:

- مناقشة الشاشة.
- اعتمادها.
- توثيقها فورًا.
- ثم الانتقال للشاشة التالية.

الحالة الحالية:

- UX-00 / Splash Screen: معتمدة وموثقة.
- UX-01 / App Entry Routing: معتمد وموثق.
- UX-02 / Login Screen: معتمدة وموثقة.
- UX-03 / Create New Well & Setup: معتمد وموثق.
- UX-04 / Unified Account Context: معتمد سلوكيًا.
- UX-05 / Role-Aware Landing: معتمد وموثق.
- UX-06 / Owner Home: معتمد وموثق.
- UX-07 / Role Section Cards: معتمد وموثق.
- UX-08 / Operations Page: معتمد وموثق.
- UX-09 / Session Start Form: معتمد وموثق.
- UX-10 / Device Readiness & Sync Status: معتمد وموثق.
- UX-11 / Active Irrigation Session: معتمد وموثق.
- UX-12 / Session Completion & Settlement: معتمد وموثق.
- UX-13 / Operations, Records & Farmers: معتمد وموثق.
- UX-14 / Money & Partners: معتمد وموثق.
- UX-15 / Well Management & Reports: معتمد وموثق.
- UX-16A / Account & Settings: معتمد وموثق.
- PA-01 / Platform Administration Foundation & Dashboard: معتمد وموثق.
- PA-02 / Accounts, Wells & Support Control: معتمد وموثق.
- ق-88 / Smart Lookup ودعم منع التكرار: معتمد.
- ق-89 / Offline Field Operations وBackground Sync: معتمد.
- ق-90 / Device Readiness وSync Transparency: معتمد.
- ق-91 / Active Session وBilling Consistency: معتمد.
- ق-92 / Session Completion وSettlement Consistency: معتمد.

هذا ترتيب تصميمي تاريخي سابق على ق-120، ولا يحدد NEXT الحالي.
نقطة العمل الحالية تؤخذ حصريًا من `memory/RESUME_POINT.md`.

لا تعتبر أي شاشة إنتاجية منفذة لمجرد اعتماد UX.

### خارطة UX المتبقية — ق-94

- UX-13: Operations, Records & Farmers.
- UX-14: Money & Partners.
- UX-15: Well Management & Reports.
- UX-16: Account, Settings & Administration.
- UX-17: Final Cross-Cutting Review.

هذه الحزم تختصر النقاش ولا تختصر المتطلبات.

### البحث والاختيار الذكي ومنع التكرار

ق-88 ثم:

`technical/SEARCH_DEDUP_ARCHITECTURE.md`

المصدر يحدد:

- Smart Lookup.
- Entity Dedup Profiles.
- إعادة استخدام تطبيع الأشخاص الحالي.
- منع تكرار الأراضي.
- حدود api للبحث.
- local/server search merge.
- عداد المستحق الجاري.
- فجوات Migration 085+ واختبارات القبول.

لا تنشأ طبقة بحث أو هوية موازية لما هو موجود أصلًا.

### الجلسة الجارية والتسعير اللحظي

ق-17 وق-91 ثم:

`technical/ACTIVE_SESSION_ARCHITECTURE.md`

المصدر يحدد:

- Active Session Read Model.
- billable time.
- live accrued amount.
- payment display.
- Pause/Resume.
- Resume With New Energy.
- Energy Segments.
- Fuel Billing consistency.
- Offline event ordering.
- Completion consistency.
- م-26.

بند 16 (الاستعادة المحلية) **منفَّذ ومُبرهن بق-116** في
`apps/mobile/lib/core/session/`؛ وبند 8 (الإرسال الخلفي)
**منفَّذ في منطق القرار بق-117** في
`apps/mobile/lib/core/sync/background_sync_*` بلا إثبات على
جهاز؛ وبقية البنود تصميم ملزم لم يُنفَّذ بعد.

### إنهاء الجلسة والتسوية

ق-92 ثم:

`technical/SESSION_SETTLEMENT_ARCHITECTURE.md`

المصدر يحدد:

- Local Completed مقابل Server Settled.
- Final Charge.
- Automatic Invoice.
- Session-linked Payment Allocation.
- Advance.
- Outstanding.
- Idempotent Settlement Retry.
- Offline reconciliation.
- Correction path.
- م-26 وم-27.

### Android Offline والتشغيل الخلفي

ق-89 وق-90 ثم:

`technical/ANDROID_OFFLINE_BACKGROUND_SYNC.md`

ثم:

`technical/SYNC_ARCHITECTURE.md`

المصدر يحدد:

- Local durable DB.
- Outbox.
- WorkManager/background sync.
- Retry/idempotency.
- Reboot recovery.
- Offline session lifecycle.
- historical pricing.
- time integrity.
- device readiness.
- permissions/settings.
- Android field acceptance.

### المزامنة والعمل دون اتصال
ق-75 ثم `technical/SYNC_ARCHITECTURE.md`.

يوجد مستويان مختلفان:

1. Server idempotency/conflict infrastructure:
   منفذ في قاعدة البيانات.

2. Mobile offline synchronization:

   الطابور المحلي الدائم منفَّذ ومُبرهن بق-115،
   وسجل الجلسة النشطة والاستعادة بعد موت التطبيق بق-116،
   والإرسال الخلفي بلا فتح التطبيق بق-117،
   في `apps/mobile/lib/core/sync/` و`apps/mobile/lib/core/session/`
   — `flutter test` = 155 PASS / 0 FAIL.

   ما زال غير منفَّذ: ربط الجهاز وشاشات المزامنة والتعارض في
   Flutter (W2-02d)، وقياسات بند 9. والإرسال الخلفي مُبرهَن في
   منطق القرار على الحاسوب فقط — لم يُجرَّب على جهاز، وبناء
   Android لم يُجرَّب أصلًا.

   PowerSync لم يُستخدم؛ الأساس المنفَّذ هو Outbox على
   `sqflite` يُرسل عبر `api.*` وفق ق-79.

### الإشعارات
ق-34 إلى ق-36، ثم م-23.

منطق الخادم الدوري مبني ومختبر.
يبقى ظهور الإشعارات في Flutter وتفعيل المجدول عند النشر.

### المسائل المفتوحة
`memory/OPEN_ISSUES.md`.

الفجوات التقنية ذات الأثر على Stage 7 حاليًا:

- م-16: مغلقة بق-111 / 079؛ نطاق farmer RLS = Self-only.
- م-18: مغلقة بق-113 / 081+082؛ الكتالوج مربوط بالسلطة الفعلية.
- م-19: مغلقة بق-81 / 076؛ نموذج المضخة والتقرير والتوازي مصححة.
- م-21: الاختبارات الميدانية.
- م-22: مغلقة بق-80 / 075؛ الأرض ترتبط الآن بـFarmer Well Account.
- م-23: واجهة الإشعارات والمجدول.
- م-25: **ضُيِّقت أربع مرات ولم تُغلق** — بق-114 (تكرار الخادم)
  وق-115 (الطابور الدائم) وق-116 (الاستعادة بعد موت التطبيق)
  وق-117 (الإرسال الخلفي بلا فتح التطبيق).
  الباقي: شاشات المزامنة والجاهزية، وقياسات بند 9،
  والإثبات على جهاز حقيقي.
- م-26 وم-27: تعارض Fuel Billing التاريخي في Migration 066
  صُحّح في Migration 085 وفق ق-17 وق-91؛ تبقى بقية عقود
  Active Session/Settlement المفتوحة كما يحدد `OPEN_ISSUES.md`.

### التدقيق المستقل القديم
`technical/CONFORMANCE_AUDIT_CODEX.md` وثيقة تاريخية.

لا يجوز استخدام نتائجها القديمة كحالة حالية دون قراءة
قسم الحالة التاريخية المضاف إلى بدايتها ومطابقتها مع ق-77 إلى ق-79.

## 3. baseline الحالي المثبت

**لا أرقام هنا.** خط الأساس المثبت — عدد الهجرات وسقفها، وعدد ملفات
الاختبار ونتيجتها، وأحجام الفهرس المولَّد، وأرقام السحابة — **في
`docs/memory/RESUME_POINT.md` §3 وحده**، وسقف الهجرات ورقم التالي في
`AGENTS.md` §4. والسبب أن هذا القسم كان يحمل أرقامًا بتاريخ 2026-08-30
ويُعلن نفسه «الحالي»، فبقي يشهد بـ86 هجرة و25 ملف اختبار و362 نجاحًا بعد
أن تجاوزها الواقع أضعافًا — وهو نجاح كاذب في وثيقة لا في كود.

### الحدود الثابتة التي لا تحمل رقمًا

- Direct DML على مخططات العمل = 0.
- `anon` EXECUTE داخل `api` = 0.
- SECURITY DEFINER داخل `api` = 0.
- الهجرات المختومة لا تُعدَّل، والتراجع بهجرة جديدة.

### قياسات 2026-08-30 — تاريخية، لا تُقرأ كحالة الآن

- Cloud P0 verification:
  authenticated setup PASS؛ anon denied؛
  3500/7000/6000 محفوظة دون ×100؛
  Transaction ROLLED BACK؛ residue = 0.

### كود الهاتف

- `flutter analyze` = `No issues found!`.
- `flutter test` = **222 PASS / 0 FAIL**.
- Create-Well targeted regression = **2/2 PASS**.
- م-40 failure behavior مثبت محليًا.
- المصدر الحاكم للأرقام: `memory/PROGRESS.md`.

### baseline التاريخي — 2026-08-17

يُحفظ للمقارنة فقط ولا يُستخدم كحالة حالية:
76 migration / 17 test file / 217 PASS.

## 4. بوابة Stage 7

- الشرط 1 — API Architecture: مغلق.
- الشرط 2 — RPC-only writes: مغلق.
- الشرط 3 — Documentation Conformance: مغلق — 2026-08-17.
- م-22 مغلقة — 2026-08-17.
- م-19 مغلقة — 2026-08-17.
- الشرط 4 — الفجوات السابقة للشاشات الحساسة: مغلق — 2026-08-17.
- م-22: مغلقة بق-80 / 075 — شاشة الأراضي لم تعد محجوبة بهذه الفجوة.
- م-19: مغلقة ضمن الشرط 4B بق-81 / 076.
- الشرط 5 — Final Clean Acceptance: مغلق — 2026-08-17.

## Stage 7 gate — current after Q81

### Baseline المثبت — 2026-08-17

- migrations = 75.
- permanent database test files = 16.
- PASS = 205.
- FAIL = 0.
- ERROR = 0.
- Data API RPC = 32.
- Direct DML = 0.
- API SECURITY DEFINER = 0.
- anon API EXECUTE = 0.

### Gate

- الشرط 1 — API Architecture: مغلق.
- الشرط 2 — RPC-only writes: مغلق.
- الشرط 3 — Documentation Conformance: مغلق.
- الشرط 4A — م-22 / Farm Farmer Identity: مغلق.
- الشرط 4B — م-19 / Pump Schema: مغلق.
- **الشرط 4: مغلق — 2026-08-17.**
- **الشرط 5 — Final Clean Acceptance: مغلق — 2026-08-17.**

## Stage 7 Readiness Gate — CLOSED

**الحالة:** مغلق — 2026-08-17.

إثبات القبول النهائي النظيف:

- clean rebuild: PASS.
- migrations = 75.
- permanent tests = 16.
- PASS = 205.
- FAIL = 0.
- ERROR = 0.
- Data API RPC = 32.
- Direct DML = 0.
- API SECURITY DEFINER = 0.
- anon API EXECUTE = 0.
- authenticated API EXECUTE = 32.
- service_role API EXECUTE = 32.
- exposed schemas = `api`, `graphql_public`.
- `public` والمخططات الداخلية غير مكشوفة للـData API.

شروط الجاهزية الخمسة مغلقة.


## Stage 7 — current after Q83

### Current verified technical baseline

- migrations = 76.
- permanent tests = 17.
- PASS = 217.
- FAIL = 0.
- ERROR = 0.
- Data API RPC = 33.
- Direct DML = 0.
- API SECURITY DEFINER = 0.
- anon API EXECUTE = 0.
- authenticated API EXECUTE = 33.
- service_role API EXECUTE = 33.

### UX / Visual Design

- S7-01 bootstrap: closed.
- Q82 app bootstrap read contract: closed.
- Q83 visual identity gate: closed provisionally.
- governing visual identity source:
  `design/VISUAL_IDENTITY.md`.
- next step: page-by-page discussion before production UI implementation.

### بوابة اكتمال التوثيق

القرار الحاكم:

ق-97.

المصدر:

`memory/DOCUMENTATION_GATE.md`

تطبق قبل الانتقال من أي موضوع معتمد إلى الموضوع التالي.

تحدد:

- شروط سجل القرار.
- أسباب القرار.
- شروط UX.
- شروط التوثيق التقني.
- Gap tracking.
- Progress.
- Changelog.
- Resume Point.
- Project Map.
- Matrix.
- Invariants.
- Evidence.
- Git closure.
- Meta-documentation.
- Traceability.

### سجلات التشغيل والحجوزات والمناوبات

ق-98 ثم:

`technical/OPERATIONS_RECORDS_ARCHITECTURE.md`

المصدر يحدد:

- Session history.
- Farmer/Farm records.
- Booking server confirmation.
- Offline tentative booking.
- Resource conflicts.
- Shift lifecycle.
- Session responsibility transfer.
- Operational vs Cash Handover.
- no-orphan active session.
- م-28.

### المال والشركاء والتوزيعات

القرار:

ق-99.

المصدر التقني:

`technical/MONEY_PARTNERS_ARCHITECTURE.md`

يغطي:

- Farmer financial accounts.
- invoices/payments/advances.
- explicit advance allocation.
- expenses.
- partner share history.
- profit distributions.
- partner payouts.
- accounting periods.
- financial corrections.
- financial Offline/Reconciliation.
- م-29.

ق-99 تكمل ولا تستبدل ق-92 وم-27 في Session Settlement.

### إدارة البئر والتقارير والرسوم

القرار:

ق-100.

المصدر التقني:

`technical/WELL_MANAGEMENT_REPORTING_ARCHITECTURE.md`

يغطي:

- Well/Pump configuration.
- Session Energy Authority.
- Fuel Inventory.
- Historical Pricing.
- Reporting Read Models.
- V1 Bar/Line Charts.
- chart locations.
- drill-down.
- Offline/Stale reports.
- report authorization.
- م-30.

المصدر البصري للرسوم:

`design/VISUAL_IDENTITY.md`.

### الحساب والإعدادات

القرار:

ق-101 وق-130. ق-123 يبقى تاريخيًا نافذًا فقط فيما لم ينسخه ق-130.

المصدر التقني:

`technical/ACCOUNT_SETTINGS_ARCHITECTURE.md`

يغطي:

- unified account.
- phone change/recovery.
- password recovery.
- team access lifecycle.
- no-orphan account finalization.
- invitation acceptance + owner confirmation.
- separation of partner financial rights from app access.
- historical share-change protection.
- notifications.
- device/sync entry.
- account-scoped local state.
- logout with pending outbox.
- English date/time display.
- م-31.

الحالة الحالية: Migration 103 (أول شريحة Backend للحساب القائم والفريق) الآن
**مدموجة في `main` (MR !12) + Local Verified + CI Verified / Cloud Pending**
(سقف السحابة يبقى 102)؛ م-44 لا تزال Production Blocker إلى أن يكتمل نطاق
ق-130 المتبقي وتتحقق السحابة وFlutter والجهاز.

Platform Administration ليست جزءًا من هذا المصدر.

### Platform Administration

القرار:

ق-102.

المصدر التقني:

`technical/PLATFORM_ADMINISTRATION_ARCHITECTURE.md`

هذه Control Plane مستقلة عن Well Roles.

تغطي PA-01:

- global platform authority.
- separate Admin Console.
- Web/Desktop-first layout.
- right-side RTL navigation.
- live numeric KPI dashboard.
- wells/accounts/operations/sync/activation/finance metrics.
- simple Bar/Line charts.
- drill-down.
- near-real-time refresh.
- global monitoring.
- audit.
- trusted backend.
- password visibility requirement status.
- م-32.

المناقشة التالية:

PA-02.

### PA-02 — الحسابات والآبار والدعم وكلمات المرور

القرار:

ق-103.

المصدر:

`technical/PLATFORM_ADMIN_ACCOUNTS_WELLS_SUPPORT_ARCHITECTURE.md`

يغطي:

- global search.
- global accounts.
- identity resolution.
- account suspend/restore.
- sessions/devices.
- global wells.
- well suspend/restore.
- support cases.
- error references.
- admin corrections.
- audit.
- force password reset.
- OTP/user-chosen password recovery.
- lost-phone identity recovery.
- Platform Admin MFA/Step-up.
- no recoverable password vault.
- no current-password reveal.
- م-33.

ق-103 Password Option B أصبحت تاريخية ومنسوخة بق-105.

Trusted Auth Admin Boundary من ق-85 تبقى نافذة.

### Research & Standards Governance

القرار:

ق-104.

المصدر الحاكم:

`memory/RESEARCH_STANDARDS_GATE.md`

تطبق قبل القرارات الجوهرية ذات الأثر:

- security.
- authentication.
- accessibility.
- admin UX.
- monitoring.
- platform behavior.
- architecture.

التصنيف:

- Standards-aligned.
- Adapted.
- Exception.

أي نموذج جديد يجب أن يقرأ هذا المصدر قبل اتخاذ قرار
معياري جديد.

### Password Current Authority

القرار الحالي:

ق-105.

ينسخ Password Option B فقط من ق-103.

Current rule:

- Supabase/Auth Hash only.
- no Recoverable Password Vault.
- no Current Password Reveal.
- Platform Admin can force reset.
- OTP proves identity.
- user chooses new password.
- Platform Admin MFA mandatory before Production.

PA-02 non-password decisions remain active.

PA-03 / Sales, Activation, Operations & Financial Control:

**معتمدة وموثقة بق-106.**

المصدر:

`technical/PLATFORM_ADMIN_SALES_OPERATIONS_FINANCE_ARCHITECTURE.md`

تغطي:

- Platform Sales.
- one entitlement per purchased well.
- atomic/idempotent grant.
- activation corrections.
- global operations monitoring.
- administrative session correction.
- global financial monitoring.
- correction/reversal.
- accounting reopen admin decision.
- audited export.
- Online-only privileged writes.
- م-34.

المناقشة التالية:

PA-04 / Monitoring, Audit, Platform Settings & Final Admin Review.

PA-04 تخضع لق-104 قبل اعتمادها.

### Platform Sales Current Authority

القرار الحاكم:

ق-106.

ق-106 تثبت ق-86 وتنسخ من ق-10 فقط عبارة:

    النسخة الأولى مجانية بالكامل

Current V1 commerce:

- permanent manual sale.
- no recurring subscription.
- each purchased well = independent entitlement.
- sale history preserved.
- entitlement history preserved.
- corrections are audited.

### PA-04 — Monitoring, Audit, Settings & Incidents

القرار:

ق-107.

المصدر:

`technical/PLATFORM_ADMIN_MONITORING_SETTINGS_ARCHITECTURE.md`

يغطي:

- monitoring.
- alerting.
- incidents.
- postmortems.
- correlation.
- global audit projection.
- typed/versioned configuration.
- rollback.
- scoped maintenance.
- app version policy.
- release tracking.
- dependency health.
- telemetry privacy.
- security view.
- م-35.

### Platform Administration Design Status

- PA-01: معتمدة وموثقة.
- PA-02: معتمدة وموثقة.
- PA-03: معتمدة وموثقة.
- PA-04: معتمدة وموثقة.

**Platform Administration مكتملة تصميميًا.**

التنفيذ ما زال Pending وفق:

- م-32.
- م-33.
- م-34.
- م-35.

### Historical Next — قبل إغلاق ق-120 بق-127

UX-17 / Final Cross-Cutting Review.

UX-17 تخضع لق-104 قبل اعتمادها.

### UX-17 — Final Cross-Cutting Review

القرار:

ق-108.

المصدر:

`technical/FINAL_CROSS_CUTTING_UX_ARCHITECTURE.md`

يغطي:

- terminology consistency.
- role/well context safety.
- Offline/Sync semantics.
- form/error/success consistency.
- financial/sensitive confirmation.
- Smart Lookup consistency.
- loading/empty/error/stale states.
- accessibility.
- RTL/font scaling.
- adaptive layout.
- notification/support/privacy.
- navigation/back/context-switch safety.
- م-36.

### UX Design Status

UX-00..UX-17:

**مكتملة تصميميًا.**

PA-01..PA-04:

**مكتملة تصميميًا.**

هذا لا يعني أن Production UI منفذة.

### Historical Next — قبل إغلاق ق-120 بق-127

IMPLEMENTATION-01 / V1 Implementation Sequencing &
Dependency Plan.

يجب أن يرتب التنفيذ حسب:

- dependency.
- data integrity.
- security.
- Offline foundations.
- user-critical flow.
- testability.

وليس حسب رقم UX فقط.

### IMPLEMENTATION-01 — V1 Sequencing

القرار:

ق-109.

المصدر:

`technical/V1_IMPLEMENTATION_SEQUENCE.md`

الترتيب:

- W1 Backend Foundations.
- W2 Offline & Background Sync.
- W3 Auth/Onboarding/Well Creation.
- W4 Core Irrigation Session.
- W5 Operations Records.
- W6 Money & Partners.
- W7 Well Management & Reports.
- W8 Account/Settings/Notifications.
- W9 Platform Administration.
- W10 Final Acceptance.

المسألة الجامعة:

م-37.

### Current Implementation Point — ق-127

ق-127 أغلق ق-120 بوصفها بوابة مانعة للتوسع.

تم تنفيذ اختبار قبول على جهاز Android حقيقي،
والنتائج محفوظة في:

`reports/DEVICE_ACCEPTANCE_TEST_LOG.md`

الاختبار كشف موانع إصدار فعلية في المزامنة،
والحفظ الدائم، والحساب المالي، وتجربة الجلسة.

لا تستنتج NEXT من هذا القسم أو من التسلسل التاريخي.
المصدر الوحيد للحالة والخطوة التالية هو:

`memory/RESUME_POINT.md`

الهجرات المختومة لا تعدل، ورقم الهجرة التالية
يؤخذ حصريًا من `AGENTS.md` §4.

### W1-01 — Profile ↔ Person Identity Foundation

القرار:

ق-110.

Migration:

078.

الحالة:

**مكتملة ومغلقة — Local + Cloud verified.**

الهدف:

إنشاء Explicit Tenant-aware link بين Login Account
وBusiness Person دون Name/Phone guessing.

لا تحل م-16 بعد.

لا تغير م-18.

بعد نجاح Verification:

W1-02 — Farmer Self-scope Authorization.
