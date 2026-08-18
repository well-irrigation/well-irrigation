# Decision ↔ Implementation Matrix

**آخر تحديث:** 2026-08-18

هذه المصفوفة تتبع القرارات التي لها أثر مباشر على
الكود أو المعمارية أو الاختبارات.

`DECISIONS.md` يبقى المصدر الكامل لكل القرارات.

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
| م-18 | مفتوحة |
| م-19 | مغلقة بق-81 / 076 — Pump schema/reporting/concurrency corrected |
| م-21 | مفتوحة؛ اختبار ميداني |
| م-22 | مغلقة بق-80 / 075 — Farm → Farmer Well Account |
| م-23 | منطق الخادم منجز، UI/scheduler متبقيان |
| م-24 | مغلقة |

## baseline المرجعي

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
| ق-84 | هاتف هوية عالمي + حساب موحد + explicit profile↔person link | الأساس موثق؛ الربط والتفرد النهائي Pending | اختبارات Migration 078+ مطلوبة | معتمد؛ Backend غير مكتمل |
| ق-85 | Super Admin عبر حدود خادم موثوقة | Auth Admin/service role trusted boundary مطلوب | اختبارات صلاحيات وتدقيق مطلوبة | معتمد؛ تنفيذ UI/backend التفصيلي Pending |
| ق-86 | حق تفعيل بئر دائم لكل شراء واستهلاك ذري | Model/API غير منفذ بعد | اختبارات entitlement/double-spend مطلوبة | معتمد؛ Migration 078+ Pending |
| ق-87 | التوجيه بعد الدخول حسب الدور | `api.app_bootstrap` أساس جزئي؛ UI routing Pending | UX-05 موثق | معتمد؛ Flutter Pending |
| ق-88 | Smart Lookup + Entity Dedup Profiles + live accrued amount | أساس 026/027/062/069/075 وsession APIs موجود؛ عقود البحث/farm dedup/operator farm/payment orchestration Pending | acceptance contract في `SEARCH_DEDUP_ARCHITECTURE.md` | معتمد؛ Migration 078+ وFlutter Pending |

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
| Operator add farm | Backend owner-only حاليًا | Migration 078+ لتفويض operator |
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
