# Decision ↔ Implementation Matrix

**آخر تحديث:** 2026-08-30

هذه المصفوفة تتبع القرارات التي لها أثر مباشر على
الكود أو المعمارية أو الاختبارات.

`DECISIONS.md` يبقى المصدر الكامل لكل القرارات.

> **قاعدة الترقيم الحالية — 2026-08-30:** Migration 071–087
> immutable؛ أي DB change جديد يبدأ 088+. أي خلية أقدم تشير
> إلى 085+ بوصفها «الهجرة التالية» هي سجل تخطيط تاريخي تجاوزته
> الهجرات 085–087 ولا تحدد الرقم الحالي.

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
| م-41 | **مفتوحة — Confirmed Gap**؛ Flutter Data API boundary drift: 9 internal-schema accesses + 20 bare RPC + 5 dotted from؛ live API check = 7 names exist / 13 missing؛ Regression Guard وrepair مطلوبان الآن |

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
`technical/MIGRATIONS.md` (86 migration / 25 test file /
362 PASS).

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
| ق-88 | Smart Lookup + Entity Dedup Profiles + live accrued amount | أساس 026/027/062/069/075 وsession APIs موجود؛ عقود البحث/farm dedup/operator farm/payment orchestration Pending | acceptance contract في `SEARCH_DEDUP_ARCHITECTURE.md` | معتمد؛ Migration 085+ وFlutter Pending |
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
| Farm dedup | غير مكتمل | scope + discriminator + DB/API enforcement |
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
