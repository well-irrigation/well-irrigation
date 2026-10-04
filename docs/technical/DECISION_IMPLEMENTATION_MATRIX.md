# Decision ↔ Implementation Matrix

**آخر تحديث:** 2026-10-03

هذه المصفوفة تتبع القرارات التي لها أثر مباشر على
الكود أو المعمارية أو الاختبارات.

`DECISIONS.md` يبقى المصدر الكامل لكل القرارات.

> **قاعدة الترقيم:** الهجرات المختومة immutable، وأي DB change جديد يبدأ
> من الرقم التالي لها. **والسقف ورقم التالي في `AGENTS.md` §4 وحده** — لا
> يُكتب رقم في هذه الوثيقة، فالرقم المنسوخ يتقادم بلا أن يُلاحظ. وأي خلية
> تشير إلى رقمٍ بوصفه «الهجرة التالية» هي سجل تخطيط تاريخي لا تحدد الرقم
> الحالي.

| القرار | القاعدة الحالية | التنفيذ | الإثبات | الحالة |
| --- | --- | --- | --- | --- |
| ق-01 / ق-12 | لا تقريب للوقت | 064/066 وما بعدها | 064/065 + 066 + 067 tests | منفذ |
| ق-13 | الزمن يحسب بالثانية | 066 | session procedure tests | منفذ |
| ق-14 | منسوخ في وحدة المال بق-77 | 039 + ق-77 | finance/time tests | منسوخ |
| ق-15 | منسوخ في الكسور المالية بق-77 | 039 + ق-77 | finance/time tests | منسوخ |
| ق-21 / ق-67 | وصف Largest Remainder منسوخ بق-77 | 052 | distribution tests | منسوخ |
| ق-22 | مجموع الملكية 100% | 064 | 064/065 test | منفذ |
| ق-27 / ق-37 / ق-39 | التقرير حسب يوم النهاية والجارية خارج المجاميع | 065 | 064/065 test | منفذ |
| ق-34..ق-36 | منظومة الإشعارات المعتمدة | 019/021/022/070 | 070 test | منطق الخادم منفذ؛ UI/نشر في م-23 |
| ق-51 / ق-57 | إعادة بناء قاعدة الهجرات | migrations الحالية | clean reset | منفذ |
| ق-75 | منع التكرار + أساس Sync؛ عناصر الهاتف في Stage 7 | 058 | inventory/sync test | خادم منفذ؛ Mobile Sync مؤجل |
| ق-76 | دمج الأشخاص وقفل المضخة وتأجيلات موثقة | 062 | 062 test | منفذ مع مسائل مؤجلة موثقة |
| ق-77 | ريال كامل + باقي القسمة لأكبر حصة + إجراءات ذرية | 039/052/064-069 | permanent suite | منفذ بالكامل |
| ق-78 | `api` عقد Data API وعزل schemas الداخلية | 071 + config | 071 + live PostgREST | مغلق |
| ق-79 | RPC-only writes وDirect DML=0 | 072-074 | 072-074 + live audit | مغلق |
| ق-120 / م-38..م-40 | بوابة صحة إنشاء البئر: صلاحية API، وحدات السعر، وفشل صريح | 087 + Flutter wizard | DB 087 = 8 PASS؛ full DB = 25/362؛ Flutter = 2/2 targeted + 222/222 full + analyze clean؛ Cloud authenticated setup PASS؛ anon denied؛ الأسعار 3500/7000/6000؛ ROLLBACK + residue 0 | **P0 مغلق؛ م-38/م-39 Verified local + Cloud؛ م-40 Verified local (Cloud N/A). ق-120 Audit Gate مستمرة** |
| ق-98 / م-41C1 | عقود قراءة العمليات: المزارعون والأراضي والمضخات عبر `api` بدل المخططات الداخلية | 089 + `OperationsRepository` + 4 نقاط واجهة | DB 089 = 20 PASS؛ full DB = **27 files / 389 PASS / 0 FAIL / 0 ERROR** (خط الأساس 369، بلا انحدار)؛ Flutter = 237/237 full + analyze clean؛ Internal-schema debt 7 → 4؛ صفر mock fallback في هذا المسار؛ anon مرفوض والبئر غير المرئي مرفوض بـ42501 | **Implemented + Verified local؛ Cloud غير منشورة**. م-41C2 يغلق الوصولات الأربعة المتبقية |
| ق-99 / م-41D2 | عقود القراءة المالية ومؤشرات التقارير عبر `api`: المصروفات والشركاء ودورات الأرباح وحساب المزارع والتقارير | 092 (خمسة عقود) + `FinanceRepository` + `fetchReportsSummary` + 6 شاشات تُظهر الفشل | Flutter = 265/265 PASS + analyze clean؛ Bare RPC 1 → 0؛ Dotted-from 5 → 0؛ Internal-schema = 0؛ مولّدات المحاكاة الأربع = 0؛ مال مُلفَّق = 0؛ لا `catch` في المستودعات؛ اختبار SQL دائم بـ37 تحققًا **غير مُشغَّل بعد** | **Implemented + Flutter Verified local؛ DB مكتوبة لا مُتحقَّقة** (`db:reset` + `db:test` بيد المالك). بند مفتوح واحد: `'mock-advance-pay'` في مسار كتابة الرصيد المقدَّم |
| ق-122 / م-41D8 | الهوية وحدة واحدة من `api.app_bootstrap()`: لا شاشة تُخمّن صاحبها ولا بئرها ولا دورها، ومفتاح الطابور هو `auth.uid()` نفسه | بلا هجرة — `core/identity/app_identity.dart` + `app/identity_gate.dart` + `app/authenticated_shell.dart` + 15 شاشة تستقبل `identity` | analyze (`lib`+`test`) = No issues؛ الحزمة **313/313 PASS** (كانت 300)؛ حرس الحد **24/24** ودين الهوية = صفر (`'well-1'` 45→0، `'tenant-1'` 13→0، `'active-user'` 8→0)؛ 8 اختبارات سلوكية لبوابة الهوية | Implemented + Verified local 2026-09-03؛ **غير مثبت على جهاز حقيقي**؛ تخزين الهوية محليًا مؤجَّل بق-120 |
| ق-123 / م-41E | حساب الفريق يُهيَّأ بالدعوة ويُطالِب به صاحبه: لا كلمة مرور يكتبها المالك، وصفر صلاحية قبل المطالبة، والرمز باليد أساسًا | **المراحل 1 و2 و3 منفَّذة:** (1) إزالة أربع كِذبات في المصادقة بلا هجرة — الحزمة 317 والحرس 26؛ (2) **هجرة 094** = جدول الدعوات + 10 دوال + `team.manage`، هدفها 22/22 والقاعدة `FILES=32 PASS=522`، والفهرس 819/491/447/44. (3) شاشة الفريق ومسار التنشيط — `TeamRepository` + `MemberActivationScreen` + زرّ التنشيط في الدخول وفي بوابة الهوية؛ الحزمة **328** والحرس **27**. **(4) مكتوبة 2026-09-03:** **هجرة 095** = تضييق سياستَي اطلاع الشريك على الجلسات ومقاطعها (الجارية لا تُقرأ)، و`iam.is_partner_only`، وعقد `api.read_partner_overview` بحضور الجلسة الجارية بلا أرقامها، وعقد `api.list_well_farmer_balances`، وتفريغ `recorded_by_name` للشريك — هدفها 26 تحققًا **مثبتة محليًّا** (`FILES=33 PASS=548`، والفهرس functions 447 → 451)؛ وشاشة `PartnerOverviewScreen` بلا زرّ كتابة، الحزمة **342** والحرس **28** | الأدلة المطلوبة للإغلاق: دعوة غير مُطالَب بها = صفر صلاحية مُثبتًا خادميًّا؛ رمز خاطئ/منتهٍ/مستهلَك يُرفض؛ مطالبتان بالرمز نفسه = تعيين واحد؛ من له حساب قائم يُربط بلا رمز؛ شاشة الرقم لا تفشي من هو مسجَّل؛ الشريك لا يرى بيانات الجلسة الجارية ويرى حضورها | Verified (القاعدة والعميل محليًّا، وسحابيًّا 94/94 و43/79 بعد دمج PR #29) — استثناء معلَن من ق-120 للمراحل 2–4؛ **الاستعادة خارج الجولة** (تحتاج طرفًا خادميًّا بالتصميم) |
| ق-124 | التحقّق والإشعارات بالرسائل النصية: مقرَّرة، والربط مؤجَّل | اتجاه معتمد؛ التطوير بالرمز اليدوي وبرمز ثابت محليًّا (`auth.sms.test_otp`)؛ القناة مجرَّدة وخطّاف الإرسال المخصّص شرط معماري | الكلفة المقيسة ≈$0.24 للرسالة إلى اليمن دوليًّا، والمحلي $0.04–0.13 بلا واجهة معلنة؛ لا رسائل ثنائية الاتجاه؛ العربية 70 حرفًا للمقطع؛ تسليم >85% يُعدّ جيدًا | Decided + Deferred — يُبنى مع الاستعادة وإغلاق ثغرة احتلال الرقم في بند واحد |


## القواعد النهائية التي تنسخ نصوصًا أقدم

### المال

ق-77 يفوز على أي نص سابق يصف الوحدة بأنها milli-riyal.

الوحدة الحالية = ريال يمني كامل.

### باقي التوزيع

ق-77 يفوز على الاسم القديم Largest Remainder Method.

السلوك الحالي:

كل باقي القسمة يضاف لصاحب أكبر حصة.

### API

ق-78 يحدد أين يتصل Flutter.

ق-79 يحدد كيف يكتب Flutter.

## فجوات ليست منجزات

| المسألة | الحالة |
| --- | --- |
| م-16 | مفتوحة |
| م-18 | مغلقة بق-113 / 081+082 — function-body enforcement on permission codes |
| م-19 | مغلقة بق-81 / 076 — Pump schema/reporting/concurrency corrected |
| م-21 | مفتوحة؛ اختبار ميداني |
| م-22 | مغلقة بق-80 / 075 — Farm → Farmer Well Account |
| م-23 | منطق الخادم منجز، UI/scheduler متبقيان |
| م-24 | مغلقة |
| م-25 | مفتوحة — **ضُيِّقت أربع مرات:** بق-114 / 083+084 (الأساس الخادمي للـidempotency موصول ومُثبت)، وبق-115 (طابور الجهاز الدائم وstable command IDs منفَّذان ومُثبتان)، وبق-116 (سجل الجلسة النشطة والاستعادة بعد موت التطبيق منفَّذان ومُثبتان على قرص حقيقي)، وبق-117 (الإرسال الخلفي بلا فتح التطبيق منفَّذ ومُثبت في منطق القرار) — كلها **بلا أي تغيير على قاعدة البيانات**؛ شاشات الحالة والجاهزية وعرض التعارض وعقد أسماء العرض والواجهة الميدانية متبقية، وقياسات بند 9 غير موصولة، والإثبات على جهاز حقيقي (الإقلاع وForce Stop والمانيفست المدموج) باقٍ |
| م-38 | **مغلقة — Verified local + Cloud**؛ Migration 087؛ authenticated call PASS؛ anon denied؛ Direct DML=0؛ ROLLBACK بلا بقايا |
| م-39 | **مغلقة — Verified local + Cloud**؛ ×100 أزيل؛ 3500/7000/6000 ثبتت محليًا وسحابيًا بالقيم نفسها |
| م-40 | **مغلقة — Verified local**؛ Backend failure لا يتحول إلى نجاح/حفظ محلي؛ Cloud verification غير منطبق على سلوك الواجهة |
| م-41 | **مفتوحة — Repair in progress**؛ initial debt = 9 internal + 20 bare RPC + 5 dotted from؛ م-41A أصلحت 7 finance RPC؛ م-41B1 أصلحت physical fuel count؛ م-41B2 أصلحت account profile read؛ م-41B3A أضافت 088 وapi.update_profile_name ومنعت false-success في حفظ الاسم؛ 088 موجودة Cloud وعقدها الأمني Verified؛ م-41B3B أزالت Team RPC/Mock غير المدعومة وجعلت الشاشة fail-closed؛ current debt = 7 internal + 9 bare + 5 dotted؛ DB = 26/369 PASS؛ Flutter = 234/234 PASS؛ Team management الفعلية تبقى Backend/Auth Gap؛ **تحديث 2026-09-02: الدين المعلَن كله = 0** (م-41C2 أغلقت internal-schema بـ090، وم-41D1 أغلقت bare RPC إلى 1 بـ091، وم-41D2 أغلقت الباقي بـ092: 0 internal + 0 bare + 0 dotted)؛ Flutter = 265/265 PASS؛ NEXT = تحقق DB لـ092 ثم حماية `main` ثم الدمج |

| م-41H / 099 | دليل المزارعين من عقد خادمي واحد: لا ترتيب ولا حساب مال ولا عدّ أرض في Flutter | 099 + `OperationsRepository.fetchFarmerDirectory` + `FarmersDirectoryScreen` | DB `FILES=38 PASS=615 FAIL=0 ERROR=0`؛ الفهرس 833/501/197/44؛ Flutter analyze نظيف و`370/370 PASS`؛ حرس نسخة العقد والأرقام الناقصة وسباق تبديل البئر | **Implemented + Verified local + Cloud Verified** (مدموج ومنشور سحابيًا عبر GitLab CI MR !1) |

## baseline المرجعي

## ق-120 — بوابة التدقيق والتثبيت

مجموعة P0 م-38/م-39/م-40 أُغلقت بالأدلة المطلوبة.
ق-120 نفسها لا تُغلق بذلك؛ تستمر بوابة Pre-Production Audit
على التنفيذ الموجود قبل أي توسع وظيفي جديد.

### Audit Queue التالية

| العنصر | الحالة |
| --- | --- |
| مطابقة Flutter مع `api.*` وعدم الاعتماد على internal schemas | **Confirmed Gap — م-41 / Repair Now** |
| إزالة silent production mock fallbacks | Audit Queue — مفتوحة |
| مراجعة Auth/OTP/account lifecycle | Audit Queue — مفتوحة |
| مراجعة settings false-success | Audit Queue — مفتوحة |
| تحديث Integration/E2E tests | Audit Queue — مفتوحة |
| مراجعة CI/branch protection | Audit Queue — مفتوحة |

**لقطة Stage 7 Readiness Gate — 2026-08-17. ليست الحالة
الحالية.** الأرقام الحاكمة الآن في
`technical/MIGRATIONS.md` (87 migration / 26 test file /
369 PASS).

- migrations = 76
- permanent tests = 17
- PASS = 217
- FAIL = 0
- ERROR = 0
- Data API RPC = 33
- Direct DML = 0

| ق-80 | Farm → Farmer Well Account بدل Login Profile؛ Farm/Account consistency | 075 مطبقة ومثبتة | 075 = 15 PASS؛ suite = 193 PASS | مغلق — 2026-08-17 |
| ق-81 | Pump equipment model؛ session segments هي مصدر الطاقة؛ concurrency rules هي المرجع | 076 مطبقة ومثبتة | 076 = 12 PASS؛ suite = 205 PASS | مغلق — 2026-08-17 |

| ق-82 | App Bootstrap Read Contract: المستخدم + الآبار + الأدوار الفعالة عبر `api` فقط | 077 مطبقة ومثبتة | 077 = 12 PASS؛ suite = 217 PASS؛ Data API = 33 RPC | مغلق — 2026-08-17 |

| ق-83 | الهوية البصرية العامة وثوابت Stage 7 | `docs/design/VISUAL_IDENTITY.md`؛ التنفيذ المرئي في الشاشات القادمة | اعتماد المالك وتوثيق المصدر الحاكم | معتمد كمرجع؛ UI الإنتاجي لم يبدأ بعد |
| ق-84 | هاتف هوية عالمي + حساب موحد + explicit profile↔person link | الأساس موثق؛ الربط والتفرد النهائي Pending | اختبارات Migration 085+ مطلوبة | معتمد؛ Backend غير مكتمل |
| ق-85 | Super Admin عبر حدود خادم موثوقة | Auth Admin/service role trusted boundary مطلوب | اختبارات صلاحيات وتدقيق مطلوبة | معتمد؛ تنفيذ UI/backend التفصيلي Pending |
| ق-86 | حق تفعيل بئر دائم لكل شراء واستهلاك ذري | Model/API غير منفذ بعد | اختبارات entitlement/double-spend مطلوبة | معتمد؛ Migration 085+ Pending |
| ق-87 | التوجيه بعد الدخول حسب الدور | `api.app_bootstrap` أساس جزئي؛ UI routing Pending | UX-05 موثق | معتمد؛ Flutter Pending |
| ق-88 | Smart Lookup + Entity Dedup Profiles + live accrued amount | أساس 026/027/062/069/075 وsession APIs موجود؛ **Farm dedup منفَّذ ومُثبت محليًا وسحابيًا (backend + API + تكامل الهاتف) عبر Migration 101 = Implemented + Local Verified + Cloud Verified**؛ عقود البحث/الترتيب/operator farm/payment orchestration وباقي ق-88 لا تزال Pending | acceptance contract في `SEARCH_DEDUP_ARCHITECTURE.md`؛ اختبار دائم 101 = PASS 19/0/0؛ Cloud: MR !6 + Pipeline 2863219601 + production job 16601058583 + Supabase verification | معتمد؛ **Partial** — Farm dedup مكتمل محليًا وسحابيًا، وبقية ق-88 Pending |
| ق-89 | Offline field operations + Android persistent background sync | Server sync foundation موجود؛ Mobile DB/outbox/worker/idempotent offline contracts غير منفذة | `ANDROID_OFFLINE_BACKGROUND_SYNC.md` + permanent/backend/Android field tests مطلوبة | معتمد؛ Stage 7 implementation Pending |
| ق-90 | Device Readiness + sync transparency + non-blocking field UX | UX-10 موثق؛ local evaluator/status UI/reminders غير منفذة | Android integration + readiness/sync acceptance tests مطلوبة | معتمد؛ Flutter/Android Pending |
| ق-91 | Active session UX + live amount + fuel-billing consistency | Session/segments backend foundation موجود؛ Fuel billing conflict تم حله في 085؛ active read/pause detail/resume-new-energy Pending | `ACTIVE_SESSION_ARCHITECTURE.md` + م-26 + backend/Android tests | معتمد؛ Backend Fuel conflict مغلق في 085؛ Flutter Pending |
| ق-92 | Session completion + invoice + payment settlement consistency | Complete/invoice/payment procedures موجودة منفصلة؛ orchestration وoffline settlement Pending | `SESSION_SETTLEMENT_ARCHITECTURE.md` + م-26 + م-27 | معتمد؛ Migration 085+ وFlutter Pending |
| ق-93 | Documentation continuity + AI handoff protocol | `AI_HANDOFF_PROTOCOL.md` + تحديث مصادر الذاكرة | Git/doc consistency checks | نافذ؛ لا Migration |
| ق-94 | Consolidated remaining UX discussions UX-13..UX-17 | UX roadmap + RESUME_POINT | اكتمال مناقشة كل حزمة قبل Production UI | معتمد؛ لا Migration بحد ذاته |
| ق-95 | AI collaboration/work method protocol | `AI_COLLABORATION_PROTOCOL.md` + handoff/map updates | Documentation contract checks | نافذ؛ لا Migration |
| ق-96 | Terminal command + recovery protocol | `TERMINAL_COMMAND_PROTOCOL.md` + invariants | Git/recovery contract checks | نافذ؛ لا Migration |
| ق-97 | Mandatory documentation completeness gate | `DOCUMENTATION_GATE.md` + governance protocol integration | documentation contract + Git closure | نافذ؛ لا Migration |
| ق-98 | Operations records + farmers/farms + booking confirmation + shift handover consistency | 032/033/042/045/074/075 foundations موجودة؛ typed booking/history/handover/offline contracts ناقصة | `OPERATIONS_RECORDS_ARCHITECTURE.md` + م-28 + Backend/Android tests | معتمد؛ Migration 085+ وFlutter Pending |
| ق-99 | Money + farmer accounts + expenses + partners + distributions + corrections | 035/044/047–053/056/061/068/073/074 foundations موجودة؛ financial reads/idempotency/corrections/rounding gaps باقية | `MONEY_PARTNERS_ARCHITECTURE.md` + م-27 + م-29 + Backend/Android tests | معتمد؛ Migration 085+ وFlutter Pending |
| ق-100 | Well/Pump/Fuel/Pricing/Reports + V1 charts | 031/046/058/060/064/065/073/076 foundations موجودة؛ typed management/report/chart contracts ناقصة | `WELL_MANAGEMENT_REPORTING_ARCHITECTURE.md` + م-30 + Backend/Android tests | معتمد؛ Migration 085+ وFlutter Pending |
| ق-101 | Account + identity + settings + local account isolation | Q84/Q85/Q89/Q90 foundations موجودة؛ phone recovery/role lifecycle/account-scoped local state gaps باقية | `ACCOUNT_SETTINGS_ARCHITECTURE.md` + م-18 + م-31 + Auth/Android tests | معتمد؛ Platform Administration مفصولة إلى PA |
| ق-102 | Independent Platform Admin + live global dashboard + control plane | activation/admin foundations متفرقة؛ global admin APIs/metrics/realtime/audit/observability ناقصة | `PLATFORM_ADMINISTRATION_ARCHITECTURE.md` + م-32 + trusted backend/security tests | PA-01 معتمد؛ PA-02 التالي |
| ق-103 | Global accounts/wells/support؛ Password Vault portion historical | `is_platform_admin` + Auth/Audit foundations موجودة؛ admin control غير مكتمل | `PLATFORM_ADMIN_ACCOUNTS_WELLS_SUPPORT_ARCHITECTURE.md` + م-32 + م-33 | PA-02 core معتمد؛ Password Option B منسوخة بق-105 |
| ق-104 | Mandatory Research & Standards Gate + admin UX/security hardening | Governance documented؛ implementation requirements موزعة على PA gaps | `RESEARCH_STANDARDS_GATE.md` + Collaboration/Documentation/Handoff updates | نافذ كGovernance Rule؛ implementation items Pending |
| ق-105 | Hash-only passwords + admin-triggered reset + OTP/user-chosen password + Admin MFA | Supabase Auth foundation موجودة؛ reset/admin MFA/recovery orchestration Pending | PA-02 architecture + م-33 + Auth/security tests | معتمد؛ ق-103 Password Vault منسوخة؛ Migration 085+ / Trusted Backend Pending |
| ق-106 | Platform sales + per-well entitlements + operations/financial admin control | ق-86 foundation موثقة؛ sale/entitlement/admin-control contracts غير منفذة | `PLATFORM_ADMIN_SALES_OPERATIONS_FINANCE_ARCHITECTURE.md` + م-34 + security/finance/idempotency tests | PA-03 معتمد؛ Migration 085+ / Trusted Backend Pending |
| ق-107 | Platform monitoring + incidents + global audit + typed/versioned config + maintenance/version control | 057 Audit foundation موجودة؛ global monitoring/incidents/config/read models غير منفذة | `PLATFORM_ADMIN_MONITORING_SETTINGS_ARCHITECTURE.md` + م-35 + observability/security/web tests | PA-04 معتمد؛ Platform Administration design complete؛ Migration 085+ / Trusted Backend Pending |
| ق-108 | Final cross-cutting UX consistency + design closure | all UX/PA design foundations documented؛ implementation remains distributed across open gaps | `FINAL_CROSS_CUTTING_UX_ARCHITECTURE.md` + م-36 + Android/Web acceptance | UX design complete؛ implementation sequencing next |
| ق-109 | V1 dependency-based implementation sequence W1–W10 | Design complete؛ implementation gaps م-16..م-36 remain | `V1_IMPLEMENTATION_SEQUENCE.md` + م-37 | Implementation plan adopted؛ W1 Backend Foundations next |
| ق-110 | Explicit Tenant-aware Profile↔Person identity link | Migration 078 implemented؛ local 18/235 PASS؛ Cloud structure/security verified | W1-02 Farmer RLS / م-16 | Implemented + Local Verified + Cloud Verified |

## Stage 7 — التزامات UX-08 / ق-88

| المتطلب | الموجود | المتبقي قبل وصفه منفذًا |
| --- | --- | --- |
| البحث العربي | normalize + pg_trgm موجودان | Read Contracts داخل api + ranking tests |
| بحث الهاتف | normalize_phone موجود | ربطه بق-84 والهوية العالمية |
| Farmer dedup | ق-76 + create_farmer موجود | منع suspect duplicate الصامت + concurrency test |
| Farm ownership | ق-80/075 منفذ | لا تغيير |
| Farm search | جدول العلاقة موجود | normalized search/index/read contract |
| Farm dedup | منفَّذ ومُثبت محليًا وسحابيًا (Migration 101) | scope=implemented؛ discriminator=`distinguishing_label`؛ DB/API enforcement=implemented (advisory lock + trigger + 23505)؛ permanent test 101 PASS 19؛ **Cloud Verified** عبر MR !6 / Pipeline 2863219601 / production job 16601058583 |
| Operator add farmer | موجود | ربط UX واختباره |
| Operator add farm | Backend owner-only حاليًا | Migration 085+ لتفويض operator |
| Inline return/select | غير منفذ | API/Flutter flow يحفظ السياق |
| Live time counter | يمكن اشتقاقه من session times | Flutter display + reconciliation |
| Live accrued amount | session pricing foundation موجود | read/calculation contract + Flutter display |
| Pause/resume amount | session APIs موجودة | UI + acceptance test |
| Energy change amount | segments موجودة | cumulative live display |
| Advance payment at start | payment API منفصل | atomic/idempotent coordination |
| Offline lookup | sync server foundation موجود | local cache merge by UUID |
| Offline create | غير مكتمل | لا يفعل قبل idempotency/conflict UX |

### قاعدة الإغلاق

لا تحول أي خلية Pending إلى «منفذ» إلا بدليل:

- Migration مطبقة عند الحاجة.
- Permanent test.
- API contract.
- Flutter integration.
- Permission test.
- Offline behavior محسوم عند انطباقه.

## Stage 7 — التزامات ق-89

| المتطلب | الحالة الحالية | شرط الإغلاق |
| --- | --- | --- |
| Durable local DB | غير منفذ | survives process death/reboot |
| Outbox | غير منفذ على الهاتف | ordered persistent commands |
| Server idempotency foundation | موجود في sync | دمجه مع كل Offline RPC |
| Offline start session | غير منفذ | airplane-mode acceptance |
| Offline pause/resume | غير منفذ | ordered replay |
| Offline energy change | غير منفذ | correct segment replay |
| Offline complete | غير منفذ | final result after delayed sync |
| Offline payment | غير منفذ | one payment after retries |
| Offline farmer/farm create | غير منفذ | Q88 dedup + dependency mapping |
| Background worker | غير منفذ | sync without UI open when OS schedules |
| Reboot recovery | غير منفذ | pending queue preserved |
| Historical pricing | يحتاج إثبات/توسعة | original event time test |
| Time integrity | غير منفذ | clock-change/reboot behavior |
| Device readiness | غير منفذ | permission/settings UX |
| Notification integration | م-23 Pending جزئيًا | post-sync delivery |
| Field test | م-21 | weak/no coverage scenarios |

لا يغلق ق-89 بوحدة اختبار DB فقط؛ يلزم Android
integration + field verification.

## Stage 7 — التزامات UX-10 / ق-90

| المتطلب | الحالة الحالية | شرط الإغلاق |
| --- | --- | --- |
| Offline readiness evaluator | غير منفذ | local DB/outbox/session health |
| Background sync readiness | غير منفذ | restriction/worker state UX |
| Notification readiness | غير منفذ | permission/channel state UX |
| Sync summary | غير منفذ | last success + pending + oldest pending |
| Pending operations list | غير منفذ | human-readable local queue |
| Per-session sync badge | غير منفذ | local_only/pending/synced/conflict |
| Manual sync | غير منفذ | safe enqueue without duplication |
| Automatic retry classification | غير منفذ | transient vs review-required |
| Conflict review | غير منفذ | no blind retry loop |
| Device setup flow | غير منفذ | only necessary settings |
| Reminder dedup | غير منفذ | default 24h per unresolved issue |
| Manufacturer guidance | غير منفذ | only tested guidance |
| Force Stop recovery UX | غير منفذ | preserved queue on reopen |
| Accessibility | غير منفذ | text+icon+color |
| Field test | م-21 | battery/background/OEM scenarios |

ق-90 لا يغلق إذا كانت الشاشة شكلية ولا تعكس الحالة
الفعلية للـLocal DB وOutbox وWorker.

## Stage 7 — التزامات UX-11 / ق-91

| المتطلب | الحالة الحالية | شرط الإغلاق |
| --- | --- | --- |
| Active Session Read Model | غير مكتمل | typed api read contract |
| Billable timer | backend segments foundation موجود | Flutter + reconciliation test |
| Live accrued amount | foundation موجود | same policy as completion |
| Pricing Pending | موثق | no fake zero/estimate |
| Active payment display | جزئي | local pending vs server posted |
| Pause | موجود | UX + Offline integration |
| Pause detail reason | غير موجود | Migration 085+ |
| Resume | موجود | preserve previous source/rate |
| Resume with new energy | غير موجود ذريًا | Migration 085+ |
| Change energy | موجود | q17-consistent pricing |
| Complete while paused | يحتاج إثبات | permanent test/fix |
| Fuel billing | **متعارض مع ق-17 في 066** | correct in 085+ |
| Offline actions | server foundation جزئي | mobile outbox + idempotent contracts |
| Process death/reboot recovery | غير منفذ | Android acceptance |
| Double-tap protection | غير منفذ end-to-end | local + server idempotency |
| Financial chain consistency | غير مثبت | live=complete=invoice policy |
| Open issue | م-26 | must close before production UX-11 |

وجود Migration 066 لا يعني أن Fuel Billing الحالية
مقبولة؛ DECISIONS.md وق-17 وق-91 هي السلطة الحاكمة.

## Stage 7 — التزامات UX-12 / ق-92

| المتطلب | الحالة الحالية | شرط الإغلاق |
| --- | --- | --- |
| Session complete | موجود أساسًا | ق-91/M-26 consistency |
| Session charge | موجود | Q17-correct final amount |
| Automatic invoice | الإجراء موجود منفصلًا | settlement orchestration |
| Invoice uniqueness | حماية موجودة جزئيًا | idempotent retry test |
| Session payment allocation | إجراءات موجودة | automatic linked allocation |
| Excess advance | foundation موجود | settlement test |
| Old unrelated advance | موجود كرصيد | no silent consumption |
| Offline completion | Mobile Pending | ordered reconciliation |
| Settlement idempotency | غير مكتمل | stable command + canonical replay |
| Final settlement read model | غير موجود | typed api contract |
| Conflict handling | foundation جزئي | UX + server result |
| Correction path | غير مكتمل | audited non-destructive flow |
| Fuel billing consistency | م-26 مفتوحة | must close first |
| Settlement orchestration | م-27 مفتوحة | must close |
| Android tests | غير منفذة | Offline/retry/process-death |

UX-12 لا تغلق تقنيًا بمجرد وجود `complete` و
`issue_session_invoice` كدالتين منفصلتين.

## Stage 7 — التزامات UX-13 / ق-98

| المتطلب | الموجود | المتبقي قبل Production |
| --- | --- | --- |
| Session history | session foundation موجود | typed history read model |
| Farmer identity | ق-80/075 | list/detail UI contracts |
| Farm archive | active/inactive موجود | API + UX behavior |
| Farmer archive | يحتاج تحقق | explicit non-destructive contract |
| Booking table/status | 032 | typed API |
| Booking history | موجود منفصلًا | atomic transition contract |
| Resource conflict | 033 | booking orchestration + concurrency tests |
| Offline booking | غير منفذ | pending-confirmation + reconciliation |
| Shift foundation | 042 | Mobile UX/read state |
| Shift API | 074 موجود | retry/idempotency improvements |
| Session transfer | accept/reject موجود | Offline idempotency |
| Shift close bypass | owner override موجود | block from normal app contract |
| Cash handover | موجود/owner-confirmed | keep separate from operational transfer |
| Shift report | 045 موجود | reuse where applicable |
| M-28 | مفتوحة | must close |

## Stage 7 — التزامات UX-14 / ق-99

| المتطلب | الموجود | المتبقي قبل Production |
| --- | --- | --- |
| Farmer financial account | invoices/payments foundation | typed summary/read models |
| Payment | 068 + api wrappers | offline idempotency/reconciliation |
| Old advance | allocation foundation | explicit UX/read contract |
| Receipt | record_payment summary | canonical UI/read handling |
| Expenses | 044/056/074 | reads + skip reason + offline idempotency |
| Partner model | 047/051 | typed partner financial projection |
| Partner irrigation | 048/051 | UX/read contract |
| Distribution | 052/053/068 | preview/read models + rounding audit |
| Partner payout | 068 | UI + retry/permission tests |
| Periods | 049/074 | read UX + closure/reopen tests |
| Corrections | audit/accounting foundation | typed reversal/correction contracts |
| Partner privacy | internal RLS foundation | least-privilege public projection |
| M-29 | مفتوحة | must close |

## Stage 7 — التزامات UX-15 / ق-100

| المتطلب | الموجود | المتبقي قبل Production |
| --- | --- | --- |
| Well | core model | typed read/write + safe state transition |
| Pumps | 076 equipment model | typed management contracts |
| Energy | session segments | report/API projection |
| Fuel | 046/055/061/073 | UI reads + reconciliation/idempotency |
| Pricing | 031 + session pricing foundation | typed versioning + diesel conflict fix |
| Daily reports | 060/065/076 | public typed report contracts |
| Timezone | partial historical rules | explicit day-boundary contract |
| Irrigation chart | source data exists | aggregated API series |
| Financial chart | collections/expenses exist | aggregated API series |
| Energy chart | segment data exists | aggregated API series |
| Fuel chart | transactions exist | aggregated API series |
| Pump/operator charts | underlying records exist | aggregated API series |
| Partner chart | distribution data exists | private partner projection |
| M-30 | مفتوحة | must close |
| ق-111 | Farmer self-scope authorization / م-16 | Migration 079؛ local 20 PASS؛ full suite 255 PASS؛ Cloud verified | W1-03 / م-18 | Implemented + Local Verified + Cloud Verified; م-16 closed |
| ق-112 | Permission Authority Foundation / م-18 | Migration 080؛ local 20 PASS؛ full suite 275 PASS؛ catalog 38؛ grants 70؛ legacy policies 273 unchanged | Cloud 20/20 `CLOUD_080_ALL_PASS`؛ `DATA_API_BOUNDARY=OK` | Implemented + Local Verified + Cloud Verified; superseded on enforcement by ق-113 |
| ق-113 | Permission Enforcement Wiring / م-18 | Migration 081+082؛ 28 live guards in 27 functions moved to `has_well_permission`؛ function-body legacy guards = 0؛ equivalence proof 28 EQUIVALENT / 1 MISSING_CODE / 0 DIFFERS = `NO_SILENT_DRIFT`؛ local 20+20 PASS؛ full suite 22 files / 315 PASS / 0 FAIL / 0 ERROR (zero regression on 295 prior checks)؛ catalog 39؛ grants 73؛ legacy policies 273 unchanged | Cloud 20+20 PASS `CLOUD_W1_03B_ALL_PASS`؛ remote history 81 through `20260822013001` | Implemented + Local Verified + Cloud Verified; **م-18 closed** |
| ق-114 | Server-side Idempotency / م-25 | Migration 083+084؛ 4 tenant resolvers in `sync` (server-derived tenant, active-assignment scope gate, no authority decision — drift-free by `080:243`)؛ 8 `api.*` first-field-cycle wrappers take trailing optional `p_command_id`؛ signature replacement keeps api surface = 33؛ `p_command_id = null` = literal legacy path؛ `PUBLIC` grants revoked from 058 executors؛ local 16+23 PASS؛ full suite 24 files / 354 PASS / 0 FAIL / 0 ERROR (zero regression on 315 prior checks) | Cloud 16+23 PASS `CLOUD_W2_01_ALL_PASS` (39/0/0)؛ `DATA_API_BOUNDARY=OK`؛ `API_SURFACE/ANON/DEFINER/DIRECT_DML = 33/0/0/0`؛ remote history 83 through `20260823013001`؛ payment total does not double on replay | Implemented + Local Verified + Cloud Verified; **م-25 narrowed, not closed** — server foundation wired, mobile outbox/stable command IDs still open |
| ق-115 | Session identity + durable device outbox / م-25 | No DB change — `apps/mobile/lib/core/sync/` (13 files)؛ session identity resolved to **durable local-to-server mapping**, proven from `084` (`start_irrigation_session` takes no client session id; replay returns `v_guard -> 'response' ->> 'id'`)؛ stable `command_id` per field operation enforced structurally (table-level UNIQUE, written on INSERT only, no UPDATE path)؛ ordered outbox (strict intra-aggregate sequence + inter-aggregate independence via reference resolution)؛ explicit UTC event time on every dispatch (never the `clock_timestamp()` default)؛ retry-vs-review classification with unknown codes defaulting to review؛ conditional claim carrying attempt age (concurrent loops dispatch once; dead claim recovered after `staleClaimTimeout`)؛ mapping written before confirmation؛ per-account isolation, logout preserves the queue؛ `sqflite` chosen (no code generation) behind abstract `OutboxStore`/`CommandTransport` gates | `flutter analyze` = `No issues found!` + `flutter test` = **69 PASS / 0 FAIL** — no phone, no network, no DB؛ 7 test files incl. real-SQL mirror via `sqflite_common_ffi` (reopened DB file after simulated app death)؛ headline proof «sent twice, executed once»: 2 attempts / 1 execution / 1 row / one amount | Implemented + Verified 2026-08-23; **م-25 narrowed a second time, not closed** — background dispatch, reboot recovery, status/readiness screens and all field UI still open |
| ق-116 | Active session record + local recovery / م-25 | No DB change — `apps/mobile/lib/core/session/` (5 files)؛ active session **re-derived from the ق-115 outbox**, no parallel local state table and no in-RAM `Timer` (§16 forbids it)؛ events replayed into typed segments (one kind + one energy source each)؛ **integer division per segment then sum, mirroring Migration 066 exactly** — proven by test (two 100s segments @ 3599 ⟹ 198, not 199)؛ truncation never rounds (ق-77)؛ energy change closes a segment and preserves its kind (changing energy while paused does not resume)؛ `business_state` and `sync_state` are two independent fields — the business-state file imports nothing from `core/sync/`, so §3's separation is structural؛ time integrity takes **anchor + device reading** (an earlier draft derived the reading from the anchor, making clock-change detection impossible — found and fixed in-round)؛ local payments are never labelled Posted without a resolved server id (§20)؛ overpayment stays visible, no silent netting (ق-99)؛ missing pricing snapshot ⟹ approved pending text, no invented number (decision 341), measured time still shown | `flutter analyze` = `No issues found!` + `flutter test` = **115 PASS / 0 FAIL** (prior baseline 69, i.e. 46 new) — no phone, no network, no DB؛ recovery proven **on a real disk file**: events written, store closed as if the app died, a brand-new store instance opened on the same path ⟹ business state, billable seconds, current pause + reason, energy source, local payments, sync state and pending count all identical؛ clock pushed +3h ⟹ billable stays 600s / accrued stays 600 with `deviceClockChanged` raised؛ reboot ⟹ `rebootTimelineUnverified` announced, session still running | Implemented + Verified 2026-08-23; **م-25 narrowed a third time, not closed** — W2-02b background dispatch (WorkManager) still open and **blocked in the assistant environment**: `workmanager`/`connectivity_plus` absent from `~/.pub-cache`, `androidx.work` absent from the Gradle cache, pub.dev unreachable (**superseded 2026-08-23:** the owner installed both and ق-117 implemented it); readiness/status screens, conflict UX, the `api.*` display-name read contract and all field UI still open. Local accrued follows ق-17 (time only) while Migration 066 still sums `fuel_charge_minor` — divergence documented in `session_segment.dart`, closes with م-26 in Migration 085+; the bug was **not** mirrored into the phone to force agreement |
| ق-117 | Background dispatch: the worker's return value is the whole decision / م-25 | No DB change — `apps/mobile/lib/core/sync/` (10 new files + `sync_engine.dart`, `main.dart`, `AndroidManifest.xml`)؛ **the worker schedules nothing** — its `Future<bool>` is the entire conversation with the OS (`false` ⟹ retry with the registered exponential backoff); re-enqueueing the same unique name from inside a running worker would either cancel it (`replace`) or build a needless work chain (`append`)؛ unique work name **per account** (`well_irrigation_outbox_sync::<accountId>`) so two accounts never cancel each other and one account never gets two parallel workers؛ `NetworkType.connected` constraint, one-off work, **no expedited work and no foreground service**؛ backoff 30s→1h then flat — **the cap is on duration, never on attempt count**, because dropping a queued command loses real irrigation revenue؛ **`blockedByReview` / `canRetryWithoutHelp` added to `SyncRunReport`** to separate "waiting on the network" from "waiting on a human" (§20 of ق-90); progress resets the delay to `firstDelay`; the queue drains within one window while progress continues (max 5 passes), and stops after one pass with no progress؛ three wake sources — app start, app resume, connectivity restored — app start being **required** because Force Stop blocks all background work (§10) and cannot be bypassed؛ 20s debounce on automatic reasons, never on manual or app start; only manual sets `replaceExisting` so automatic reasons never reset a live backoff؛ **connectivity is a hint, never proof** — nothing is marked failed and no retry counter is touched from it؛ one file per platform SDK (`workmanager_sync_scheduler.dart`, `connectivity_plus_watcher.dart`, `supabase_command_transport.dart`), every decision in pure Dart behind an interface؛ single `resolveOutboxDatabasePath()` because app and worker are separate isolates on the same file؛ `ACCESS_NETWORK_STATE` only (§11), with the plugin's merged `POST_NOTIFICATIONS`/`FOREGROUND_SERVICE`/`FOREGROUND_SERVICE_SHORT_SERVICE` recorded openly as pending pre-release review | `flutter analyze` = `No issues found!` + `flutter test` = **155 PASS / 0 FAIL** (prior baseline 115, i.e. 40 new) — no phone, no emulator, no network, no DB؛ end-to-end against the real outbox store and a ق-114-faithful transport fake: operation recorded with the app closed ⟹ sent, then the phone is not woken again؛ network drop keeps the command (`retryCount == 1`) and asks for a later slot؛ network returns ⟹ **2 requests / 1 execution**؛ ten payments drain in **one** worker execution؛ a mid-queue failure drains in >1 pass, no progress ⟹ exactly 1 pass؛ business rejection ⟹ `awaitsHumanDecision`, nothing scheduled, and still nothing on the next run؛ a `create_farm` blocked behind a rejected `create_farmer` (**a different aggregate**) does not retry forever؛ a review-blocked well does not stop another well that is only waiting on the network؛ concurrent app loop ⟹ worker gets `alreadyRunning`, 1 execution؛ claim killed mid-flight ⟹ recovered after `staleClaimTimeout`, still 1 execution, final status `confirmed` | Implemented + Verified 2026-08-23; **م-25 narrowed a fourth time, not closed** — **not device-verified:** reboot rescheduling, Force Stop behaviour and the merged manifest are unproven, and an Android build has never been attempted in the assistant environment (`androidx.work` absent from the Gradle cache); **§9 field measurements are not instrumented** (`network_available_to_worker_start`, `worker_start_to_server_ack`, retry count, oldest-pending age) and are required for M-21; readiness/status screens, conflict UX, the `api.*` display-name read contract and all field UI still open |

## ق-128 — تتبع تنفيذ الحوكمة

- القاعدة: نموذج تنفيذ ثلاثي.
- الوكيل المحلي منفذ كود محدود.
- البروتوكول الحاكم:
  `LOCAL_AGENT_EXECUTION_PROTOCOL.md`.
- الثوابت: 716–718.
- لا تغيير في التطبيق أو القاعدة.
- الإثبات: اتساق الوثائق وGit closure.
- الحالة: Adopted؛ يكتمل التوثيق بوصول هذه الدفعة إلى Git closure.

## ق-129 — تتبع القبول الميداني

- المصدر: `reports/DEVICE_ACCEPTANCE_TEST_LOG.md`.
- UX الحاكم: ملحق ق-129 في `design/UX_UI_SPEC.md`.
- المعمارية الحاكمة: `ACTIVE_SESSION_ARCHITECTURE.md`، `SYNC_ARCHITECTURE.md`، و`SESSION_SETTLEMENT_ARCHITECTURE.md`.
- الهجرة المرتبطة: الهجرة 100 (`20260916010001_100_paused_energy_source_change.sql`) مع اختبارها الدائم (PASS=7/0/0) — **منشورة ومتحقق منها سحابيًا ومحليًا عبر GitLab CI (MR !3 / Job 16548801073)**.
- الفجوة التنفيذية: أُغلقت بالكامل — م-43 مغلقة (**CLOSED / RESOLVED**) بعد اجتياز بنود القبول الميداني الـ 42 على الهاتف الفعلي (Samsung Galaxy A13 / Android 12) وثبات وصمود مخزن SQLite بعد Process Death وReboot، وحل مشكلة دورة حياة SQLite، والمزامنة التلقائية.
- تسوية حادثة الـ 13 عملية القديمة: فُقدت محليًا بزوال العملية القديمة، ولم يظهر في المطابقة السحابية ما يثبت وصولها إلى الخادم، وزال مانع الحفاظ على العملية القديمة.
- NEXT: أُغلقت ق-129 وم-43 بنجاح؛ المتابعة مع البند التالي المفتوح في خارطة طريق المشروع.
- الدليل الحالي:
  - قاعدة البيانات محليًا وسحابيًا: **39 ملفًا / 622 PASS / 0 FAIL / 0 ERROR** محليًا؛ وسحابيًا 99/99 هجرة مطبقة ومتحقق منها، 195/195 دالة، و43/79 صلاحيات.
  - تطبيق الهاتف محليًا: `flutter analyze` نظيف (0 ملاحظات)؛ واختبارات فلاتر: **505 PASS / 0 FAIL**؛ وفحص الشجرة `git diff --check` نظيف.
  - أدلة الجهاز الحقيقي: 42/42 بند قبول مجتاز بنجاح تام على Samsung Galaxy A13 (Android 12)، وتنفيذ ناجح لعامل WorkManager، وتصفير طابور المعلقات، وإغلاق جلسة الاختبار على الخادم.
- الحالة: **CLOSED / DEVICE RE-ACCEPTANCE PASSED**
  استوفى القرار كافة متطلباته التقنية والميدانية والسحابية والتجريبية، واجتاز فحص التطبيق الكامل (505/505 PASS)، وتم إغلاقه رسميًا مع إغلاق موانع الإصدار م-43 ورفع الحظر عن جاهزية الإطلاق التجريبي (Pilot Readiness = UNBLOCKED).

## ق-130 — دورة الحساب والدعوة وحقوق الشريك

- **المصدر الحاكم:** `memory/DECISIONS.md` ق-130.
- **المعمارية:** `ACCOUNT_SETTINGS_ARCHITECTURE.md` §25.
- **UX:** UX-02 / UX-03 / UX-16A.
- **المسألة:** م-44 — **OPEN / Production Blocker**.
- **التنفيذ الحالي:** Migration 103 هي أول شريحة Backend للحساب القائم/
  الفريق، **مدموجة في `main` عبر MR !12** (**merge commit لـM103 = `c5e7f7a`**،
  commit التنفيذ المصدر = `239b8ae`؛ ودمج فرع التوثيق سيغيّر رأس `main`
  لاحقًا): دعوة بلا auto-link أو وصول، قبول صريح بلا صلاحية، ثم تأكيد مالك
  idempotent كتحول الصلاحية. هجرة 095 لنطاق قراءة الشريك تبقى صحيحة وغير
  منسوخة؛ ووصف 094/Q-123 يبقى تاريخيًا لما كان قبله.
- **دمجات لاحقة (MRs !14–!17):** **M104 — member finalization** عبر MR !14
  (merge `f229256`) = التثبيت الموثوق للعضو الجديد بلا Auth (ملف
  `20260922010001_104_member_finalization.sql` واختبارها الدائم)؛ وتكامل
  **واجهة تنشيط الحساب** عبر MR !15 (merge `0e8a898`)؛ و**workspace
  المشغل في Home** عبر MR !16 (merge `e9b9afa`) — وكشف القبول الميداني أن
  شريط الإعلانات مفقود للمشغل؛ ثم **استعادة الشريط الحساس للدور** عبر
  MR !17 — **رأس `main` الحالي = merge commit `b64e43e`**. شريط !17 تغيير
  Flutter فقط: آبار المالك بأربع بطاقات كاملة، وآبار المشغل بثلاث بطاقات
  مسموحة (كرت التقارير/الأرباح مخفي عن المشغل)، وتبديل الدور يعيد بناء
  حالة السلايدر بأمان — بلا Backend ولا Schema ولا Supabase.
- **المعتمد المستهدف:** لا Auth جديد بلا Finalization لدور؛ الدعوة بصفر
  وصول؛ قبول صاحب الهوية ثم تأكيد المالك؛ حقوق الشريك المالية مستقلة عن
  App Access؛ حساب واحد لكل الأدوار؛ Farmer العادي بلا Auth.
- **الدليل المحلي وCI (حتى M103 — تاريخي):** Test 103 = `33/0/0`؛
  Test 094 = `23/0/0`؛ حزمة DB =
  `FILES=42 PASS=707 FAIL=0 ERROR=0`؛ والفهرس = `845/507/210/45`
  (columns/constraints/functions/triggers). MR pipeline `2869239530`
  (database/app success) وmain pipeline `2869249068` (database/app success).
- **الدليل الحالي على رأس `main` (`b64e43e`):** حالة الهجرات وصلت إلى 104؛
  اختبارات القاعدة الدائمة = **43 ملفًا / 728 PASS**؛ وCI main pipeline:
  app = SUCCESS وdatabase = SUCCESS؛ **production بقيت MANUAL ولم تُشغَّل**،
  ولا تحقق سحابي جديد (السحابة على الحالة الموثقة في `AGENTS.md` §4).
- **M104 (كانت الشريحة التالية): نُفِّذت ودُمجت عبر MR !14** — لم تعد
  الخطوة التالية؛ معماريتها كانت موثقة تحت ق-130 §25.4.
- **Pending:** finalization المالك/البئر الجديد؛ دعوات إعداد البئر؛
  تطبيع الهاتف المركزي عبر كل المسارات؛ بقية correction/reissue UX؛ موافقات
  تغيير الشراكة؛ **قبول الجهاز الحقيقي لمساري العضو الجديد والحساب القائم
  (NEXT — ق-130 لا يُغلق)**؛ **فجوة UX لمشاركة رمز الدعوة** — استبدال
  المشاركة الشفهية بفلول Share صريح والتحقق من رحلة الدعوة مالك/مشغل؛
  وتنظيف ما قبل الإطلاق عند الحاجة. (من Flutter دُمج: واجهة تنشيط الحساب
  MR !15، وworkspace المشغل MR !16، والشريط الحساس للدور MR !17.)
- **MR !19 (2026-09-27):** `feat: complete m44 invitation ux flow` دُمج
  في `main` — **رأس `main` الحالي = `573a657`**؛ MR pipeline
  `2886135900` = SUCCESS، وlatest main pipeline `2886143435` = manual
  (production يدوي لم يُشغَّل — **لا ادعاء نشر إنتاجي لـ!19**).
  وفجوة UX لمشاركة رمز الدعوة أعلاه أُغلقت فرعيًا بالبند التالي.
- **إثبات ميداني (بعد MR !19):** نجاح مسار مشاركة رمز الدعوة (نسخ/
  مشاركة/فتح مباشر لواتساب والرسائل) على جهاز Android حقيقي بإثبات
  المالك. **هذه الفجوة الفرعية أُغلقت وحدها؛ ولا يُستنتج إغلاق بقية
  بنود قبول ق-130.**
- **الاختبارات المتبقية:** قائمة م-44 المتبقية، Regression Flutter، وقبول
  جهاز حقيقي لمساري العضو الجديد والحساب القائم.
- **الحالة:** **Adopted + Documented / Partial Implementation / Backend
  (M103 + M104) Merged to main + CI Verified / Cloud Pending / Flutter:
  activation UI + operator workspace + role-aware strip + invitation
  share Merged (MRs !15–!17، !19) / Device Acceptance: invitation-share
  flow device-verified؛ الباقي Pending**. لا تُوصف Closed قبل الأدلة
  الكاملة، وم-44 تبقى OPEN / Production Blocker، وق-130 لا يُغلق.

## ق-131 — توسعة عقد التشغيل والمال والحجوزات والتقارير

- **المصدر الحاكم:** `memory/DECISIONS.md` ق-131 (23 بندًا معتمدة
  2026-09-28).
- **المعمارية:** أقسام ق-131 في الوثائق التقنية السبع
  (`OPERATIONS_RECORDS` و`SESSION_SETTLEMENT` و`MONEY_PARTNERS`
  و`WELL_MANAGEMENT_REPORTING` و`ACCOUNT_SETTINGS`
  و`FINAL_CROSS_CUTTING_UX` و`PLATFORM_ADMINISTRATION`) + ملحق ق-131 في
  `design/UX_UI_SPEC.md`.
- **المسألة:** م-45 (tracker) — **مع الإحالة الإلزامية إلى م-28 وم-29
  وم-30** بوصفها بيوت التنفيذ القائمة؛ لا معمارٍ موازية.
- **التنفيذ الحالي:** **البند 1 — محاصيل الجلسة — Implemented + Local
  Verified + CI Verified + Emulator UX Accepted (2026-09-29)**. يشمل Migration
  105 واختبارها الدائم، لقطة مستقلة لكل جلسة، الاقتراحات من جلسات
  المزرعة نفسها، وظهور اللقطة في الجلسة النشطة وملخص الإنهاء والتفاصيل
  التاريخية. الدليل المحلي: قاعدة **44 ملفًا / 743 PASS**، Flutter
  **600/600 PASS** وتحليل نظيف، وقبول المالك على المحاكي. GitLab:
  MR !21 merged to `main` (`275a99f`)؛ MR pipeline `2887897982` = SUCCESS؛
  post-merge pipeline `2891224749`: app/database = SUCCESS وproduction
  = MANUAL لم تُشغَّل. **Cloud/Production Pending**.
  **البند 7 — الزمن الفعلي مقابل المفوتر — Implemented + Local Verified +
  CI Verified + Merged / Cloud + Production Pending (2026-09-29)**:
  Migration 106، قاعدة **45/757 PASS**، Flutter **611/611 PASS**،
  MR !24 merged to `main` (`d3255022`)؛ MR pipeline `2891435913` =
  SUCCESS؛ post-merge pipeline `2891454890`: app/database = SUCCESS
  وproduction = MANUAL لم تُشغَّل.
  **البند 11 — تحذير حالة المزارع المالي/الوقودي غير المانع — Implemented
  + Local Verified + CI Verified + Merged / Cloud + Production Pending
  (2026-09-29)**: Migration 107؛ Test 107 = **13/0/0**؛ قاعدة
  **46 ملفًا / 770 PASS**؛ Flutter **621/621 PASS** وتحليل نظيف؛ MR !26
  merged to `main` (`9168ccac`)؛ MR pipeline `2891694253` = SUCCESS؛
  post-merge pipeline `2891702168`: app/database = SUCCESS وproduction =
  MANUAL لم تُشغَّل.
  **البند 10 — التأكيد الصريح قبل تطبيق الرصيد المقدم — Implemented +
  Local Verified + CI Verified + Merged / Cloud + Production Pending
  (2026-09-29)**: Migration 108
  (`20260929030001_108_advance_allocation_proposal.sql`) واختبارها الدائم
  (`20260929_108_advance_allocation_proposal.test.sql`). اقتراح الخادم
  للقراءة فقط يأخذ مبلغ الدفعة المخزّن ناقص التخصيصات المخزّنة، ويأخذ
  متبقي الفاتورة من `outstanding_minor` الحاكم، ثم يقترح الأصغر. تعرضه
  الواجهة وتسمح بتعديله، ولا كتابة مالية قبل «تأكيد التسديد من المقدم»؛
  التطبيق الفعلي يبقى على `api.allocate_payment` بلا صلاحية جديدة أو
  توسيع RLS أو نموذج محاسبي موازٍ، وبلا تغيير تنسيق تسوية نهاية الجلسة/
  العمل دون اتصال. الدليل المحلي: Test 108 = **12/0/0**؛ القاعدة =
  **47 ملفًا / 782 PASS / 0 FAIL / 0 ERROR**؛ الفهرس =
  **854/514/221/45** (columns/constraints/functions/triggers)؛ Flutter
  المستهدف **40/40 PASS** والكامل **627/627 PASS**؛ التحليل 0 issues؛
  `c:db` = SUCCESS. MR !28 source
  `1d83371187c7b8d2dad9d1a8dd5090ded9526745`؛ pipeline `2891865738`:
  database/app = SUCCESS؛ merge `5446bcfa5c0d48ebe09307313a207160516d8cf7`.
  post-merge pipeline `2891873719` وسم app/database/production بالفشل
  فورًا بسبب `ci_quota_exceeded` قبل تنفيذها؛ هذا سجل تاريخي لحجب الحصة،
  لا فشل اختبار. أعاد GitHub PR #38 التحقق من حالة المشروع نفسها: workflow
  `36524544084` قبل الدمج وpost-merge workflow `36524928657` بعده =
  app/database SUCCESS، مع نجاح `c:app` و`c:db` ومطابقة الفهرس؛ عند
  merge commit PR #38
  `bbc661ac7a58e944b64af36c5ebc704a0f642c7c` — دليل استعادة تاريخي لا
  رأس حالي. لم يجرِ نشر
  production أو تحقق سحابي جديد.
  **البند 18 — حيازة المشغل النقدية والترحيل — Implemented + Local
  Verified + CI Verified + Merged / Cloud + Production Pending
  (2026-09-29)**: M109 (`20260929133348_operator_cash_custody.sql`)
  وM110 (`20260929151336_operator_cash_custody_well_bridge.sql`) — حيازة
  واحدة نشطة لكل (بئر، مشغل) من دفتر الحسابات، تحصيل نقد المشغل إلى
  حيازته، ترحيل صريح بلا نوبة مختلقة، تأكيد المالك عبر `api.confirm_handover`
  بقيد نقل 1000→1000 وقفل صف صندوق المصدر نقطة تسلسل، وقراءة الحيازة
  من الدفتر (`api.get_my_operator_cash_custody`). الدليل: اختبارات
  109/110 دائمة (36 و13 فحصًا)؛ PR #41 merge `4ca0e019` وPR #42 merge
  `fbd04125`.
  **البند 13 — إثبات المصروف أو سبب عدم الإرفاق — Implemented + Local
  Verified + CI Verified + Merged / Cloud + Production Pending
  (2026-09-29)**: M111
  (`20260929193502_expense_evidence_skip_reason.sql`) — `attachment_skip_reason`
  عقد صريح مستقل عن `note`، قيد جدولي للحالات الإثباتية الصالحة، توقيع
  `record_expense` وحيد بلا overload، فئات من الخادم
  (`api.list_expense_categories`)، دلو خاص `expense-evidence` بسياسات
  موسوَّرة ومرجع `storage://` مستقر بلا signed URL مخزَّن. الدليل:
  اختبار 111 دائم (20 فحصًا)؛ PR #43 merge `68919e06`.
  آخر بوابة مدموجة: DB **FILES=50 PASS=851** وفهرس
  **858/519/231/45** وFlutter **655/655** و`c:db`/`c:app` SUCCESS.
  بقية البنود عدا 1 و7 و10 و11 و13 و18 Pending.
  الأساسات السابقة لا تُحسب تنفيذًا لبنود ق-131.
- **المراحل:** A) المحاصيل المتعددة، نافذة الشمس والبديل والانتقال
  التلقائي، الزمن الفعلي، تحذير المزارع، تأكيد تطبيق المقدم، تقدير ديزل
  المزارع، حيازة المشغل، مرفقات المصروفات — قبل قبول نهائي متجدد لمسار
  المشغل.
- **ترتيب الاستئناف (قرار المالك 2026-09-29 ثم ق-132 بتاريخ
  2026-10-01):** قرار المالك كان يؤجل جولة نافذة الشمس/البديل/العدّاد/
  الانتقال التلقائي دون إسقاطها من المرحلة A، ويؤجل أيضًا **البند 12**
  (تقدير استهلاك ديزل المزارع، ثم تأكيد أو تصحيح صريح من المشغّل قبل
  أن يصبح فعليًا/نهائيًا، مع فصل المقدّر عن الفعلي) مؤقتًا دون إلغائه
  ودون تغيير عقده الحاكم. **ثم أعادت ق-132 (2026-10-01) إلى نطاق
  التنفيذ الحالي داخل Phase B**: نافذة الشمس/البديل/الانتقال التلقائي
  عبر **M113**، والبند 12 عبر **M114** بعقده الحاكم نفسه — ويبقى الوقت
  المتبقي/العدّاد وحده مؤجلًا مؤقتًا.
  **البندان 18 (حيازة المشغل/الترحيل — M109/M110) و13 (إثبات المصروفات —
  M111) منفَّذان ومدموجان / Cloud + Production Pending** كما في قسم
  التنفيذ أعلاه.
  **المرحلة B نشطة: أساس الحجوزات M112 مدموج (PR #45، `db45b7d`) —
  Implemented + Local Verified + CI Verified + Merged / Cloud +
  Production Pending — والمرحلة غير مغلقة وم-28 غير مغلقة.** الترتيب
  بق-132: **M113** (Booking Execution / جدول اليوم / booking→session /
  solar fallback والانتقال التلقائي) ثم **M114** (Diesel reference-price
  history + valuation معلوماتي) ثم Flutter/Offline/Notifications ضمن
  المرحلة B نفسها. بعدها C) الفاتورة الرسمية: PDF/حفظ/طباعة/مشاركة.
  D) المنطقة والمدينون وتصفية التقارير والأجهزة النشطة ولمسات
  التحديث/الحفظ. E) الإشعارات الواسعة منفصلة ومؤجلة.
- **الدليل المطلوب للإغلاق:** للبند الذي يتطلب تغييرًا في القاعدة —
  هجرة برقم §4 من `AGENTS.md` واختبارها الدائم؛ والبنود UI-only لا
  تفرض هجرة قاعدة بيانات بذاتها. الكتابة والقراءة عبر عقود `api` حصرًا،
  واختبارات Flutter عند الانطباق، وقبول جهاز حقيقي للبنود الحرجة.
  **لا رقم هجرة مُنسوخ في هذه الوثيقة.**
- **الحالة:** **Adopted + Documented / Partial Implementation (م-45):
  Item 1 Implemented + Local Verified + CI Verified + Emulator UX Accepted؛
  Item 7 Implemented + Local Verified + CI Verified + Merged / Cloud +
  Production Pending؛ Item 10 Implemented + Local Verified + CI Verified +
  Merged / Cloud + Production Pending؛ Item 11 Implemented + Local Verified +
  CI Verified +
  Merged / Cloud + Production Pending؛ Item 18 Implemented + Local Verified +
  CI Verified + Merged / Cloud + Production Pending؛ Item 13 Implemented +
  Local Verified + CI Verified + Merged / Cloud + Production Pending؛
  بقية البنود Pending**.

## ق-132 — عقد تنفيذ الحجوزات وجدول اليوم وسعر الديزل المرجعي

- **المصدر الحاكم:** `memory/DECISIONS.md` ق-132 (2026-10-01).
- **المعمارية:** أقسام ق-132 في `OPERATIONS_RECORDS_ARCHITECTURE.md`
  (§11 وقسم 26) و`SESSION_SETTLEMENT_ARCHITECTURE.md`
  و`MONEY_PARTNERS_ARCHITECTURE.md`، والثوابت 252–253 المعدلة
  و742–756 في `INVARIANTS.md`.

| البند | الحالة |
| --- | --- |
| ق-132 ككل | **Adopted + Documented (2026-10-01)** |
| أساس الحجوزات (M112 — قيد الاستبعاد وwell_path وعقود api والقراءات) | **Implemented + Local Verified + CI Verified + Merged (PR #45، `db45b7d`) / Cloud + Production Pending** |
| M113 — Booking Execution / جدول اليوم / booking→session / solar fallback والانتقال التلقائي | Partial Implemented + Local DB Verified (`FILES=52 PASS=1069`), CI / Merged / Cloud / Production Pending؛ auto transition / Offline timing / notifications remain pending؛ M113 NOT CLOSED |
| M114 — Diesel reference-price history + valuation معلوماتي | Implementation Pending |
| Flutter / Offline / Notifications | بعد M113/M114 **ضمن المرحلة B نفسها** |

- **لا يُقرأ** M112 إغلاقًا لم-28 ولا لم-45 ولا لبنود الحجوزات؛
  وFCM/Push جزء تنفيذ Phase B لم يُنفَّذ ولا يوصف منفذًا بمجرد
  وجود `ops.notifications`.
- **المتتبع:** م-45 (مفتوحة) بإحالة إلزامية إلى م-28.

[DOC-RECOVERY-Q133-2026-10-03]
## ق-133 — المدة المشروطة للسقي الحر وتوافق Offline (استدراك 2026-10-03)

| المجال | التنفيذ/الدليل المحلي | الباقي/حالة Git |
| --- | --- | --- |
| السلوك المعتمد | لا مدة دون حجز قادم؛ مدة صريحة لا تتجاوز بداية الحجز المؤكد القادم؛ لا إكمال/تشغيل فوق جلسة مفتوحة | Adopted من المالك 2026-10-02؛ موثق ومدموج عبر PR #47 (`e1d2c689`) |
| M113 backend | عمودا التخطيط، قيد مؤجل، عقد `api.start_adhoc_session`، وسد نقص مالك الوقود في بصمة replay + EE11b/EE11c | **Merged + CI Verified**: PR #47 merged (`e1d2c689`) وGitHub Actions #36 على `main` = SUCCESS (`1071 DB PASS`, `667 Flutter PASS`, فهرس مطابق)؛ Cloud/Production Pending — M113 غير منشورة سحابيًا |
| Flutter command layer | نوع `startAdhocSession`، وسيط اختياري، دعم projector وOutbox القديم | مدموج؛ CI #36 على `main` = SUCCESS (`667 Flutter PASS`)؛ لا تصميم شاشات |
| Flutter UX / booking awareness | لا معلومات حجز محلية ولا عرض `pending/review` في الشاشة بعد | Requires owner UI design approval |
| Offline recovery | مراجعة أوامر review وتوابعها؛ Downgrade؛ زمن الهاتف؛ reason_code لرفض المدة | Pending — لا تلقائية صامتة، لا فقدان بيانات |
| M113 باقي ق-132 / M114 | توقيت الانتقال، التنبيهات، التزامن؛ التاريخ المرجعي للديزل | Pending؛ لا إغلاق Phase B أو م-28 أو م-45 |

---

## ق-134 — التشغيل المتتابع والتصحيحات المدققة (2026-10-04)

**الحالة:** Adopted + Documented؛ P0 مدمجة PR #49؛ P1-A Implemented + Local DB Verified + PR CI Verified + Merged عبر PR #51 (`f63e9c2`). نجاح فحوص `main` أكدّه المالك؛ Cloud/Production Pending، وبقية ق-134 Implementation Pending. P1-A-MERGED-PR51-2026-10-04.

| مجال ق-134 | القائم في main | الفجوة المطلوبة |
| --- | --- | --- |
| زر الانتقال الآلي لكل بئر، انتهاء المحجوزة وبدء التالية | M113 سلاسل حالات وCAS و`run_now/wait` (PR #47 مدمج). P1-A أضافت ON/OFF محروسًا لكل بئر؛ 1103 PASS محليًا، واجتازت CI على الفرع ودُمجت عبر PR #51. لا زر Flutter أو منفّذ. | المتبقي: واجهة المشغل، إغلاق محاسبي ذري ثم بدء التالي، جدولة مستقلة، اختبار سباق الاتصالين |
| التمديد والتأخير والانتظار | عقود حجز ومنع تداخل M112 | إزاحة الحجوزات، تأخير محدد/مفتوح، تذكير، التزام مدة كل مزارع |
| Offline واستعادة الفائت | Flutter Outbox وWorkManager للمزامنة، لا ساعة انتقال مضمونة | حجوزات محلية، توقيت آمن، إشعارات محلية، مراجعة الفائت، تحقق Android |
| تصحيح مجموعات جلسات ومبالغها فورًا | قاعدة تسوية تاريخية غير قابلة للمحو | Correction API واختبارات وفروق مالية مدققة وحسم المالك |
| ضوابط تحكم المالك | صلاحيات عقود حالية، لا إثبات استجابة هاتف التشغيل | طلب/تنفيذ مؤكد، كشف معلّقات، طلب مؤجل بلا صلاحية مزامنة قديمة |
| الطوارئ ومصادر الطاقة | مقاطع الطاقة والتوقف الأساسية | تجميد السلسلة والمتبقي والجدولة والبديل والإشعارات |
| الإشعارات | كتاب إشعار وdedup | Local/Push والتسليم/التأخير حسب الدور والجاهزية |
| الإطلاق | GitHub Actions #38 SUCCESS بعد PR #48؛ M113 ليست مغلقة | اختبار شامل/نشر صريح، M114 منفصلة، م-28 وم-45 باقيتان |

**خطة التنفيذ والترتيب:** `BOOKING_AUTOMATION_IMPLEMENTATION_PLAN.md`، P0→P8؛ لا يرقى Pending إلى Implemented بالوصف.
