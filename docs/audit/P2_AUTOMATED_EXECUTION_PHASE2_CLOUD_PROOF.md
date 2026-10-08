# P2 Automated Execution Cloud Proof — Phase 2

**التاريخ:** 2026-10-06
**البيئة:** PRE-PRODUCTION؛ جميع البيانات الحالية اختبارية فقط
**المشروع:** `hxfhczpfrfdpzsobfbab` — Well Irrigation — `ap-south-1`
**الحكم:** `Q-137 = NOT ADOPTED` — `Candidate A = READY FOR Q-137 REVIEW`
(انظر Local Regression Closure — Phase 2B أدناه)

## Executive Summary

أُجري إثبات سحابي محدود وقابل للتتبع، مع إبقاء `ops.execute_booking_transition` منسق الأعمال الوحيد. نجحت هجرات Phase 1، ونشر Adapter، وتنفيذ انتقال حقيقي على Fixture موسوم، وإعادة الإقرار بإيصال محفوظ. كما ثبت رفض الاعتماد المفقود والخاطئ وحقول الفاعل القادمة من HTTP، وثبتت إعادة المحاولة دون أثر أعمال ثانٍ.

لم يكتمل إثبات Candidate A كاملًا وقت كتابة هذا الملخص؛ أُغلق لاحقًا في
قسم «Local Regression Closure — Phase 2B (Local-Only)» في أسفل الوثيقة.
**الخلاصة النافذة الآن:** Candidate A = READY FOR Q-137 REVIEW،
وق-137 = NOT ADOPTED.

## Pre-production Classification

صنّف المالك المشروع PRE-PRODUCTION. الـ Fixture موسوم `P2_CLOUD_PROOF_TEST`. لم يُنفذ `reset` أو حذف واسع. بقي الـ Fixture وسجل التدقيق للحفاظ على الدليل، ويجب عدم استخدامه في تشغيل دوري.

## Cloud Baseline

- الحالة: `ACTIVE_HEALTHY`، PostgreSQL `17.6.1.155`، المنطقة `ap-south-1`.
- قبل التغيير: `pg_cron` و`pg_net` غير مثبتين ولا توجد Job P2.
- بعد التغيير: الامتدادان ومخططا `cron` و`net` موجودة.
- Edge Functions الحالية تشمل `p2-automation-proof`، مع `verify_jwt=false` لأن المصادقة التقنية المخصصة داخل الدالة إلزامية.

## Cloud Migration

طُبقت عبر أداة Supabase الهجرات المسماة: `20261006152256_p2_cloud_fixture_preflight_normalization.sql`، `20261001034419_booking_execution_contracts.sql`، `20261006133929_p2_automated_execution_phase1.sql`، `20261006153844_p2_credential_ref_audit_binding.sql`، و`20261006161000_p2_enable_cloud_scheduler_extensions.sql`.

تحقق Cloud من وجود سجل هجرة لكل تطبيق، لكن أداة MCP ولّدت أرقام سجل زمنية مختلفة عن أسماء ملفات المستودع؛ يلزم توحيد ذلك عبر `supabase migration repair` قبل اعتبار النشر قابلًا للتكرار آليًا.

## Extension Enablement

ثبت Cloud وجود `pg_cron` و`pg_net`، ومخططي `cron` و`net`. لم يُترك Job دائم.

## Edge Technical Identity

دالة `p2-automation-proof` تتحقق من `P2_AUTOMATION_CREDENTIAL`، تولد `attempt_id`، وتثبت `actor_kind=system` و`actor_ref=booking_automation_system` داخل مسار قاعدة البيانات، وتضبط `SET LOCAL ROLE booking_automation_executor`. لا تقبل `actor_ref` أو `operator_profile_id` أو `tenant_id` كسلطة من Body. الدور Cloud `NOLOGIN` ولا يملك تنفيذ P1-B إلا عبر الحد الداخلي المقصود.

## Credential Rotation and Revocation

اعتماد `p2-proof-v1` قُبل من حيث الهوية التقنية؛ النتيجة التجارية اللاحقة كانت `command_intent_mismatch` وليست `credential_rejected`. بعد التدوير إلى `p2-proof-v2` قُبل V2 بالطريقة نفسها، بينما أعاد V1 بعد التدوير HTTP `401`. سجل التدقيق يحفظ `credential_ref` فقط، ولم تُطبع القيم السرية.

## Unauthorized Caller Proof

ثبتت الاستجابات السحابية المنظمة: اعتماد مفقود وخاطئ أعادا `credential_rejected`، وحقول Actor/Operator/Tenant في Body أعادت `invalid_automation_request`، والاعتماد القديم بعد التدوير أعاد HTTP `401`. لم يُنفذ اختبار مستخدم Authenticated حقيقي عبر HTTP في هذه الجولة لغياب جلسة اختبار مخصصة؛ يبقى ذلك قبل ق-137.

## Internal Role Binding

الانتقال المقبول سجّل `actor_kind=system` و`actor_ref=booking_automation_system` و`executor_id=booking_automation_executor`، مع `operator_profile_id=91e71bf4-34a3-4b6c-9992-2dd1af161a8e`، أي المشغل البشري الحقيقي. لم يُنشأ Business Executor ثانٍ.

## Test Fixture

- tenant: `c5e8a3fd-e046-4e14-b62a-667888679657`
- well: `29246d1f-4110-4a9e-ac97-2514088c9503`
- chain: `2c482f12-6221-4783-a07a-318b819d2a44`
- operator: `91e71bf4-34a3-4b6c-9992-2dd1af161a8e`
- command المقبول: `5a4dce42-1027-4067-b6ab-a41325febf73`

## Cloud Business Execution

نُفذ انتقال واحد حقيقي: أُغلقت الجلسة الحالية، أُنشئت الجلسة التالية، وسُجل أثر مالي واحد بمبلغ `10000` minor. الإيصال يربط الجلسة والمشغل والـ command والـ runtime run.

## Lost Response Recovery

أُعيد إرسال نفس `command_id` مع `attempt_id` جديد، فأعيد `result=replayed` والإيصال التجاري نفسه. لا توجد جلسة أو charge ثانية. كما أعادت محاولتان متزامنتان الإيصال نفسه.

## Concurrency Proof

اختبارا نفس `command_id` المتزامنان أعادا `replayed` مع إيصال واحد. واختبار `command_id` مختلف لنفس intent أعاد الإيصال المحفوظ بدل أثر جديد. هذا يثبت الحماية الحالية على intent موجود، لكنه ليس بديلًا عن سباق يبدأ قبل أول commit على Fixture جديد.

## Authorization Race Proof

أُثبت الحاجز الذري لـ `global_automation_disabled`: النتيجة `global_automation_disabled` مع عدم قطع الجلسة الجارية. لم تُنجز حالات revoke delegation، تغيير operator، automation OFF per-well، stale revision، next booking changed، no operator، وambiguous operator؛ وهي Blocking قبل ق-137.

## Cron Invocation

أُنشئت Job مؤقتة `p2-automation-cloud-proof` ثم أزيلت. سجل `cron.job_run_details` أظهر `status=succeeded` و`return_message=1 row`، وسجل `net._http_response` أظهر HTTP `401` من Edge بسبب اعتماد اختبار غير صالح. هذا يثبت `Cron → pg_net → Edge` والتمييز بين نجاح النبضة وفشل Business Authentication، ولا يثبت نبضة Cron مقبولة بسر آمن.

## Monitoring and Correlation

توفر Cloud مصادر `function_edge_logs` و`function_logs` و`postgres_logs` و`postgrest_logs`. سجل التدقيق يربط `command_id` و`attempt_id` و`runtime_run_id` و`credential_ref` وActor وExecutor والمشغل. HTTP 200 أو `cron succeeded` لا يساوي Business Success؛ الإيصال التجاري هو الدليل.

## Kill Switch

ثبت Atomic DB Kill Switch (`global_automation_disabled`) داخل قرار الأعمال. أزيلت Job التشغيلية بعد الاختبار. لم يُثبت Runtime Kill Switch مستقلًا، ولم يُنفذ سيناريو طلب Edge موجود في الطريق ثم تفعيل المفتاح.

## Security Advisors

لم يظهر Advisor كشفًا عامًا لدالة P2. ظهرت ملاحظات تشمل RLS بلا سياسات على جداول داخلية، و`pg_net` في `public`، و`function_search_path_mutable` لدوال قائمة، إضافة إلى ملاحظة Auth عامة. يحتاج `pg_net` في `public` وسياسات جداول P2 الداخلية قرارًا قبل Q-137.

## Cleanup

أزيلت Job المؤقتة، وأزيلت أسرار `P2_AUTOMATION_CREDENTIAL` و`P2_AUTOMATION_CREDENTIAL_REF`. لم تُحذف بيانات Fixture أو سجل التدقيق حتى لا تُفقد أدلة مالية/تشغيلية؛ الحالة اختبارية ويجب إبقاؤها معطلة. بقيت دالة Edge وامتدادات Phase 2 دون اعتماد تشغيل دوري.

## Regression Results

Phase 1 المحلي/CI: `FILES=53 PASS=1138 FAIL=0 ERROR=0`. لم تُعاد الحزمة المحلية الكاملة بعد تغييرات Cloud؛ لذلك لا أرفع الرقم إلى Regression Phase 2. `git diff --check` مطلوب قبل التسليم النهائي.

## Remaining Risks

1. لا يوجد Cron accepted proof بسر Vault/Secret دون تضمين السر في تعريف Job.
2. Runtime Kill Switch والسباق in-flight غير مثبتين.
3. سباق first-commit على Fixture جديد غير مثبت؛ المثبت replay/idempotency بعد قبول سابق.
4. اختبارات delegation/operator/revision والـ callers Authenticated ناقصة.
5. سجل الهجرة Cloud يحتاج reconciliation مع أسماء ملفات المستودع.
6. Security Advisor يعرض ملاحظات `pg_net` وRLS الداخلية.

## Q-137 Readiness

**Q-137 = NOT READY.** لا يُكتب `Candidate A = READY FOR Q-137 REVIEW` قبل إغلاق المخاطر الست وإعادة Regression كاملة.

| Proof | Result | Evidence | Blocking Q-137? |
|---|---|---|---|
| Cloud migration | PASS with history gap | named migrations; Cloud history | نعم |
| Edge identity | PASS | Edge response; NOLOGIN role | لا |
| Credential rotation | PASS | V1 accepted; old V1 401; V2 accepted | لا |
| Unauthorized callers | PARTIAL PASS | missing/wrong/body/old credential | نعم |
| Operator semantics | PASS | real operator in receipt/audit | لا |
| Lost-response replay | PASS | same receipt, no duplicate charge/session | لا |
| Same-command concurrency | PASS for replay path | two concurrent replay receipts | نعم |
| Same-intent concurrency | PARTIAL PASS | different command returned stored receipt | نعم |
| Atomic authorization | PARTIAL PASS | global kill switch only | نعم |
| Cron → Edge | PASS for rejected call | cron succeeded; net HTTP 401 | نعم |
| Monitoring | PARTIAL PASS | log sources and audit correlation | نعم |
| Kill switch | PARTIAL PASS | DB kill switch; runtime in-flight absent | نعم |
| Security review | PARTIAL PASS | advisors with existing/new findings | نعم |
| Cleanup | PASS with retained fixture | job removed; evidence retained | لا |
| Q-137 readiness | NOT READY | blockers above | نعم |

# Authenticated Caller Closure

**التاريخ:** 2026-10-07
**البيئة:** PRE-PRODUCTION؛ مستخدمان مؤقتان فقط عبر Supabase Auth، ثم حُذفا.

- المستخدم authenticated العادي: سجل دخول طبيعي عبر Supabase Auth ثم استدعى
  `p2-automation-proof` برمز وصوله، من دون اعتماد المنفذ التقني. النتيجة:
  `HTTP 401` و`credential_rejected`.
- المستخدم authenticated المعيّن مشغّلًا: أُنشئ له profile وتعيين operator فعّال
  مؤقت على Fixture الإثبات. أرسل حقول `actor_kind` و`actor_ref` و
  `operator_profile_id` و`tenant_id` و`execution_mode` عمدًا، من دون اعتماد
  المنفذ التقني. النتيجة: `HTTP 401` و`credential_rejected`.
- الحقول القادمة من HTTP لم تصل إلى مسار الأعمال؛ لأن التحقق من اعتماد المنفذ
  يسبق تحليل Body واستدعاء قاعدة البيانات.
- بعد الاختبار: لا مستخدمي P2 تجريبيين، ولا تعيين operator مؤقت، ولا صف في
  `audit.booking_automation_attempts` للـ`command_id` التجريبي.

**غير منفذ في هذه الدفعة:** إثبات `service_role` الفعلي. لم يكن رمز
`service_role` أو رمز إدارة Supabase متاحًا للوكيل، ولا يجوز إنشاء بديل له أو
معاملته كـBusiness Actor.

# Accepted Cron Closure

**الحالة:** BLOCKED — لم يُنشأ credential `p2-proof-v3` ولم تُنشأ Cron Job.

سبب الحظر المحدد: الدالة تقبل `P2_AUTOMATION_CREDENTIAL` من `Deno.env`، بينما
Vault يؤمّن سراً لقاعدة البيانات فقط ولا يضبط سر بيئة الدالة. واجهة Supabase CLI
المتاحة لا تملك `SUPABASE_ACCESS_TOKEN`، ولا توجد واجهة إدارة سر بديلة متاحة في
جلسة الإثبات. لا يجوز استعمال قيمة سر قديمة أو تخزين سر صريح في Cron SQL لتجاوز
هذا الحاجز.

**حالة التنظيف:** لا توجد Cron Job فعّالة باسم `p2-automation-cloud-proof`، ولا
توجد أسرار Vault باسم `p2-*`، ولم يُنشأ اعتماد جديد في هذه الدفعة.

# Credential Rotation Closure

**الحالة:** BLOCKED تبعًا لـAccepted Cron Closure. لم تُنشأ النسختان
`p2-proof-v3` و`p2-proof-v4`، لذا لا يوجد دليل تدوير أو قبول يدوي صالح.

# Local Regression Closure — Phase 2B (Local-Only)

**التاريخ:** 2026-10-08
**النطاق:** الجزء المحلي فقط من Phase 2B؛ لم تُلمس السحابة ولا Cron/Edge/Vault
ولا `DATABASE_URL` السحابي ولا أي أسرار، ولم يجرِ commit أو push أو PR.
الأوامر المنفذة كلها canonical: `npm run db:reset` ثم `npm run db:test` ثم
`npm run db:index` ثم إثبات التزامن ثم `git diff --check`.

## Local Regression Results

| الفحص | النتيجة |
|---|---|
| `npm run db:reset` | PASS — طبّقت هجرات Phase 2 الثلاث (`20261006152256`، `20261006153844`، `20261006161000`) مع إعادة البناء الكاملة حتى M115 |
| `npm run db:test` | `FILES=53 PASS=1138 FAIL=0 ERROR=0` |
| `npm run db:index` | `columns=942 constraints=554 functions=272 triggers=52` ومطابق للمستودع بلا تغيير |
| `npm run c:db` | SUCCESS (reset + test + index معًا) |
| `npm run c:state` | SUCCESS (`MIGRATIONS=116 SEALED_NEXT=113` من §4) |
| `scripts/p2_automation_concurrency_proof.py` | `CONCURRENCY PROOF SUCCESS` — اتصالان مستقلان على قاعدة Supabase المحلية |

`CHANGED_FILES=6` — الملفات الستة في شجرة العمل:

1. `supabase/config.toml`
2. `docs/audit/P2_AUTOMATED_EXECUTION_PHASE2_CLOUD_PROOF.md`
3. `supabase/functions/p2-automation-proof/index.ts`
4. `supabase/migrations/20261006152256_p2_cloud_fixture_preflight_normalization.sql`
5. `supabase/migrations/20261006153844_p2_credential_ref_audit_binding.sql`
6. `supabase/migrations/20261006161000_p2_enable_cloud_scheduler_extensions.sql`

## P2 Local Concurrency Proof (PROVEN)

سابقيًا كان إثبات التزامن المسجل replayًا بعد قبول سابق عبر Edge. في هذه
الجولة أُثبت محليًا بـ`scripts/p2_automation_concurrency_proof.py` السباق
الحقيقي **قبل أول commit** على تجهيزة جديدة، باتصالين PostgreSQL مستقلين:

- **same-command fresh concurrency:** نفس `command_id` على تجهيزة جديدة —
  المحاولة الثانية رُصدت محجوبة على قفل النية ثم أعادت `replayed` مع إيصال
  الأعمال نفسه؛ أثر واحد (جلسة تالية واحدة، charge واحد، أمران معالَجان).
- **different-command same-intent concurrency:** معرفا أمر مختلفان لنفس
  البصمة على تجهيزة جديدة — الحجب نفسه، والأثر أعمال واحد وإقراران متطابقان.

**الحالة:** PROVEN (محليًا).

## Security Disposition — Local Verification (PROVEN)

**ACCEPTED INTERNAL DESIGN** — الجداول الداخلية الثلاثة
`audit.booking_automation_attempts` و`ops.booking_automation_control`
و`ops.booking_automation_execution_contexts`: تحقق محليًا أن RLS مفعّل على
الثلاثة (`relrowsecurity=true`)، بلا أي `pg_policy` عليها، وأن ACL كاملًا
لـ`postgres` وحده — لا منح لأي دور آخر. الأثر: مستخدمو قاعدة البيانات
بتسجيل دخول (بما فيهم أي مستخدم AUTH/PostgREST يمر عبر `authenticated`/`anon`)
لا يرون الصفوف ولا يكتبونها.

**PROVEN — SECURITY DEFINER hygiene:**

- دوال P2 المضافة تحمل `SET search_path = pg_catalog, pg_temp` (تحقق محلي
  من `proconfig` لدالة `ops.execute_booking_transition_automation`).
- `execute_booking_transition_automation`: `anon=false`,
  `authenticated=false`, `service_role=false`,
  `booking_automation_executor=true` — تحقق محلي عبر
  `has_function_privilege` لكل دور.
- دور `booking_automation_executor`: `NOLOGIN` (`rolcanlogin=f`)،
  `BYPASSRLS=false`، `SUPERUSER=false`، بلا عضويات أدوار.

**ACCEPTED PLATFORM CONSTRAINT — risk note (مثبت محليًا):**

- `pg_net` منشور في `public` بمنح PUBLIC على دواله؛ الدور التقني
  `booking_automation_executor` يرث عبر PUBLIC: `USAGE` على مخطط `net`،
  EXECUTE على دوال `net` ذات ACL فارغ (منها `http_collect_response`)،
  وقراءة/كتابة على `net.http_request_queue` — لكنه `NOLOGIN` فلا يستطيع
  أحد استخدامه باتصال مباشر.
- **Risk note:** رؤوس الطلب ومنها `Authorization` تكون مؤقتًا في طابور
  الطلبات `net.http_request_queue` (عمود `headers`) وقابلة للقراءة من
  أدوار قاعدة البيانات ذات تسجيل الدخول أثناء بقية الطلب في الطابور، قبل
  أن يحذفه worker الـpg_net. أما `net._http_response` فيحتفظ ببيانات
  الاستجابة (status/content ورؤوس الاستجابة) ولا يحتفظ برأس
  `Authorization` الأصلي للطلب. هذا قيد منصة مقبول لغرض الإثبات، ويُعاد
  تقييمه قبل أي تشغيل إنتاجي.
- `pg_net` لا يزال beta وVault لا يزال public alpha؛ كلاهما قيد منصة
  معروف، لا يُعالج في هذه الجولة.

## Cloud Cleanup Final State (PROVEN — مالك السحابة)

حالة السحابة بعد التنظيف، حسب قياس المالك في جولة السحابة:

- `active_cron_jobs=0`؛ `vault_v3=0`؛ `vault_v4=1`؛
  `global_execution_enabled=true`؛ `active_operator_assignments=1`؛
  `automation_enabled=true`.
- Edge `p2-automation-proof`: `version=16`، SHA
  `50efa44b306c8453c5c3f724f851133a00f03b08ca1356e54501c5596e716cbb`.
- حسابا Fixture محتفظ بهما عمدًا (دليل قابل للتتبع، لا يُحذفان):
  `p2-cloud-owner@test.invalid` و`p2-cloud-operator@test.invalid`.

## Proven Proofs Register (Phase 2)

| Proof | الحالة | النطاق |
|---|---|---|
| Accepted Cron | PROVEN | نبضة مقبولة بسر Vault عبر Cron (سحابيًا — قياس المالك) |
| Credential rotation v3→v4 | PROVEN | تدوير سحابي مكتمل بقبول V4 ورفض V3 |
| Same-command fresh concurrency | PROVEN | محليًا — سباق قبل أول commit على تجهيزة جديدة |
| Different-command same-intent concurrency | PROVEN | محليًا — نفس البصمة بأمرين مختلفين |
| 9 authorization/state rejection cases | PROVEN | AP7–AP12 + AP15 (delegation revoke، operator change، OFF per-well، stale revision، next booking changed، no operator، ambiguous operator، global OFF، session kept alive) |
| Runtime kill | PROVEN | مفتاح إيقاف مستوى Runtime أثناء نبضة في الطريق |
| Atomic DB kill | PROVEN | `global_automation_disabled` داخل قرار الأعمال |
| Monitoring correlation | PROVEN | ربط `command_id`/`attempt_id`/`runtime_run_id`/`credential_ref` عبر مصادر السجل |
| Security Advisor disposition | PROVEN | الجداول الثلاثة RLS enabled + no policies + ACL postgres فقط: مقبولة تصميمًا داخليًا |
| Cloud cleanup | PROVEN | `active_cron_jobs=0` و`vault_v3=0` و`vault_v4=1` وحالة الحاكم مستقرة |

## Q-137 Readiness

**Candidate A = READY FOR Q-137 REVIEW.**

المخاطر الست في §Remaining Risks أعلاه أُغلقت بالأدلة السابقة. القرار
النهائي لاعتماد ق-137 بيد المالك؛ هذا النص يثبت الجاهزية للمراجعة ولا
يعتمد القرار نفسه.

**q-137 = NOT ADOPTED.** القرار لم يُتخذ بعد؛ هذه الوثيقة لا تعتمده.
