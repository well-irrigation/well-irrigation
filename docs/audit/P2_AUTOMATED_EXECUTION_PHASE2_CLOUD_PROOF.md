# P2 Automated Execution Cloud Proof — Phase 2

**التاريخ:** 2026-10-06 (مُصحَّح: 2026-10-08)
**البيئة:** PRE-PRODUCTION؛ جميع البيانات الحالية اختبارية فقط
**المشروع:** `hxfhczpfrfdpzsobfbab` — Well Irrigation — `ap-south-1`
**الحكم:** `q-137 = NOT ADOPTED` — `Candidate A = READY FOR Q-137 REVIEW`

## Executive Summary

أُجري إثبات سحابي محدود وقابل للتتبع، مع إبقاء `ops.execute_booking_transition` منسق الأعمال الوحيد. نجحت هجرات Phase 1، ونشر Adapter، وتنفيذ انتقال حقيقي على Fixture موسوم، وإعادة الإقرار بإيصال محفوظ. كما ثبت رفض الاعتماد المفقود والخاطئ وحقول الفاعل القادمة من HTTP، وثبتت إعادة المحاولة دون أثر أعمال ثانٍ.

Phase 2B أُغلقت لاحقًا: أثبتت نبضة Cron مقبولة بسر Vault، وتدوير الاعتماد v3→v4، وسباق أول commit محليًا في الحالتين، والحالات التسع للرفض الإداري، وRuntime kill عبر unschedule، وMonitoring correlation كاملة، وتصريف Security Advisors، والتنظيف السحابي، وRegression النهائي كاملًا. الخلاصة النافذة:

**Candidate A = READY FOR Q-137 REVIEW**
**q-137 = NOT ADOPTED**

## Pre-production Classification

صنّف المالك المشروع PRE-PRODUCTION. الـ Fixture موسوم `P2_CLOUD_PROOF_TEST`. لم يُنفذ `reset` أو حذف واسع. بقي الـ Fixture وسجل التدقيق للحفاظ على الدليل، ويجب عدم استخدامه في تشغيل دوري.

## Cloud Baseline

- الحالة: `ACTIVE_HEALTHY`، PostgreSQL `17.6.1.155`، المنطقة `ap-south-1`.
- قبل التغيير: `pg_cron` و`pg_net` غير مثبتين ولا توجد Job P2.
- بعد التغيير: الامتدادان ومخططا `cron` و`net` موجودة.
- Edge Functions الحالية تشمل `p2-automation-proof`، مع `verify_jwt=false` لأن المصادقة التقنية المخصصة داخل الدالة إلزامية.

## Cloud Migration

طُبقت عبر أداة Supabase الهجرات المسماة: `20261006152256_p2_cloud_fixture_preflight_normalization.sql`، `20261001034419_booking_execution_contracts.sql`، `20261006133929_p2_automated_execution_phase1.sql`، `20261006153844_p2_credential_ref_audit_binding.sql`، و`20261006161000_p2_enable_cloud_scheduler_extensions.sql`.

أُصلحت لاحقًا metadata سجل الهجرات السحابي **فقط**؛ لم تُعد أي schema migration أثناء الإصلاح. الإصدارات البعيدة أصبحت مطابقة للإصدارات المقصودة في المستودع:

- `20261006152256`
- `20261001034419`
- `20261006133929`
- `20261006153844`
- `20261006161000`

## Extension Enablement

ثبت Cloud وجود `pg_cron` و`pg_net`، ومخططي `cron` و`net`. لم يُترك Job دائم.

## Edge Technical Identity

دالة `p2-automation-proof` تتحقق من `P2_AUTOMATION_CREDENTIAL`، تولد `attempt_id`، وتثبت `actor_kind=system` و`actor_ref=booking_automation_system` داخل مسار قاعدة البيانات، وتضبط `SET LOCAL ROLE booking_automation_executor`. لا تقبل `actor_ref` أو `operator_profile_id` أو `tenant_id` كسلطة من Body. الدور Cloud `NOLOGIN` ولا يملك تنفيذ P1-B إلا عبر الحد الداخلي المقصود.

## Credential Rotation and Revocation

اعتماد `p2-proof-v1` قُبل من حيث الهوية التقنية؛ النتيجة التجارية اللاحقة كانت `command_intent_mismatch` وليست `credential_rejected`. بعد التدوير إلى `p2-proof-v2` قُبل V2 بالطريقة نفسها، بينما أعاد V1 بعد التدوير HTTP `401`. سجل التدقيق يحفظ `credential_ref` فقط، ولم تُطبع القيم السرية.

## Unauthorized Caller Proof

ثبتت الاستجابات السحابية المنظمة: اعتماد مفقود وخاطئ أعادا `credential_rejected`، وحقول Actor/Operator/Tenant في Body أعادت `invalid_automation_request`، والاعتماد القديم بعد التدوير أعاد HTTP `401`. واستُكمل لاحقًا (انظر Authenticated Caller Closure):

- ordinary authenticated caller → `HTTP 401 credential_rejected`.
- authenticated operator caller → `HTTP 401 credential_rejected`.
- حقول actor/operator القادمة من العميل لم تصل إلى مسار الأعمال.
- `service_role` لم يُختبر برمزه فعليًا عبر HTTP، لكن
  `has_function_privilege(service_role, execute_booking_transition_automation, EXECUTE) = false`،
  و`service_role` ليس Business Actor.

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

أُثبت السباق قبل أول commit على تجهيزة جديدة، في الحالتين:

**SAME command / fresh first-commit** — `command_id`:
`31fee202-7251-4ab5-bb93-115c512376bf`

- النتيجة: `accepted` + `replayed`.
- الأثر: next session = 1، session charge = 1، segment = 1،
  processed command row = 1.

**DIFFERENT command IDs / SAME intent** —
`65cda2cd-7de0-4295-b9e2-4073ca5dc537` و
`bba04f79-439b-40b0-8b6c-506e123ca3af`:

- النتيجة: `accepted` + `replayed`.
- الأثر: business effect واحد، next session = 1، session charge = 1،
  processed command rows = 2، وcanonical receipt واحد.

الإثبات المحلي المكافئ سباق حقيقي باتصالين مستقلين (انظر Local Regression Closure أدناه).

## Authorization Race Proof

أُثبت الحاجز الذري، والحالات التسع المثبتة كلها أعادت
`business_receipt = null`:

- `revoked_delegation`
- `operator_changed_pending_confirmation`
- `booking_auto_transition_disabled`
- `next_booking_changed`
- `stale_decision_revision`
- `stale_automation_revision`
- `operator_unassigned`
- `ambiguous_responsible_operator`
- `authorization_revision_stale`

`global_automation_disabled` ليس ضمن هذه التسع؛ هو دليل kill-switch مستقل (انظر Kill Switch).

## Cron Invocation

`Cron → pg_net → Edge → DB = PROVEN`.

- `runtime_run_id`: `d8f524e8-7820-4660-8f15-61ff30a906d0`.
- `cron.job_run_details` = `succeeded`.
- Edge logs: `user_agent = pg_net/0.20.4`، HTTP `200`.
- audit: `result = replayed`، والإيصال التجاري صحيح.
- بعدها أزيلت Cron.

## Monitoring and Correlation

**PROVEN.** سلسلة الربط كاملة:
`cron.job_run_details` → Edge logs → `runtime_run_id` → `attempt_id` →
`command_id` → `credential_ref` → `result` → `business_receipt`.
مصادر Cloud: `function_edge_logs` و`function_logs` و`postgres_logs` و`postgrest_logs`. HTTP 200 أو `cron succeeded` لا يساوي Business Success؛ الإيصال التجاري هو الدليل.

## Kill Switch

**Runtime kill:**

- `cron.unschedule` يمنع بدء نبضات جديدة بعد وقت الإيقاف.
- `stopped_at`: `2026-10-08 10:18:56.929117+00`؛
  `last_start`: `2026-10-08 10:18:48.807987+00`.
- none started after stop؛ `active_cron_jobs=0`.

**Atomic DB kill:**

- `command_id`: `c2e5e690-a686-4bfc-b15a-adacf0221193`
- `attempt_id`: `f44768c1-961c-4f95-9fe4-553f1615e140`
- `runtime_run_id`: `88f4805b-6ed2-4847-999f-e6cf3fd5d86c`
- `result`: `rejected`، `failure_reason`: `global_automation_disabled`،
  `business_receipt`: `null`.
- البعدها: أُعيد `global execution` إلى `true`، وبقيت الجلسة الجارية
  مفتوحة، ولم تُنشأ جلسة الحجز التالي، ولا charge على الجلسة الحالية.

## Security Advisors

- **PASS:** دوال P2 ذات `SECURITY DEFINER` تستخدم
  `search_path = pg_catalog, pg_temp`.
- **PASS:** `execute_booking_transition_automation`:
  `anon=false`، `authenticated=false`، `service_role=false`،
  `booking_automation_executor=true`.
- **PASS:** دور `booking_automation_executor`: `NOLOGIN` و`BYPASSRLS=false`.
- **ACCEPTED INTERNAL DESIGN:** `audit.booking_automation_attempts` و
  `ops.booking_automation_control` و
  `ops.booking_automation_execution_contexts` — RLS enabled، no policies،
  ACL only postgres.
- **ACCEPTED PLATFORM CONSTRAINT:** منح `pg_net` على `net.*`. رؤوس
  Authorization الخاصة بالطلب توجد مؤقتًا في `net.http_request_queue`
  (وليس في `net._http_response` الذي يخزن بيانات الاستجابة فقط).

## Cleanup

أزيلت Job المؤقتة، وأزيلت أسرار `P2_AUTOMATION_CREDENTIAL` و`P2_AUTOMATION_CREDENTIAL_REF`. لم تُحذف بيانات Fixture أو سجل التدقيق حتى لا تُفقد أدلة مالية/تشغيلية؛ الحالة اختبارية ويجب إبقاؤها معطلة. بقيت دالة Edge وامتدادات Phase 2 دون اعتماد تشغيل دوري.

## Regression Results

Phase 2 regression النهائية: `FILES=53 PASS=1138 FAIL=0 ERROR=0`.

## Remaining Notes (Non-blocking, pre-production)

- `pg_net` beta.
- Vault public alpha.
- رؤوس Authorization للطلب موجودة مؤقتًا في `net.http_request_queue`.
- تجهيزات PRE-PRODUCTION المحتفظ بها ليست بيانات إنتاج.
- ق-137 ما يزال يتطلب مراجعة واعتمادًا صريحين من المالك.

## Q-137 Readiness

**Candidate A = READY FOR Q-137 REVIEW.**

**q-137 = NOT ADOPTED.** القرار لم يُتخذ بعد؛ هذه الوثيقة لا تعتمده،
والمراجعة والاعتماد النهائي بيد المالك.

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

**service_role:** لم يُختبر برمزه فعليًا عبر HTTP. فحص
`has_function_privilege(service_role, execute_booking_transition_automation, EXECUTE)`
أعاد `false`، و`service_role` ليس Business Actor.

# Accepted Cron Closure

**الحالة:** PROVEN.

`Cron → pg_net → Edge → DB = PROVEN`.

- `runtime_run_id`: `d8f524e8-7820-4660-8f15-61ff30a906d0`.
- `cron.job_run_details` = `succeeded`.
- Edge logs: `user_agent = pg_net/0.20.4`، HTTP = `200`.
- audit: `result = replayed` مع إيصال أعمال صحيح.
- ثم أزيلت Cron.

# Credential Rotation Closure

**الحالة:** PROVEN — التدوير `v3 → v4` مكتمل.

- الاعتماد القديم `v3` بعد التدوير: HTTP `401` و`credential_rejected`.
- `v4`: أعاد `replayed` بنجاح.
- `attempt_id`: `9ee5b2f2-9ff2-49e7-be2a-a198f4fcbcdc`.
- `runtime_run_id`: `c7a42487-96f9-4a0a-af70-a5c9d98eccfe`.

# Local Regression Closure — Phase 2B (Local-Only)

**التاريخ:** 2026-10-08
**النطاق:** الجزء المحلي فقط من Phase 2B؛ لم تُلمس السحابة ولا Cron/Edge/Vault
ولا `DATABASE_URL` السحابي ولا أي أسرار. الأوامر المنفذة كلها canonical:
`npm run db:reset` ثم `npm run db:test` ثم `npm run db:index` ثم إثبات
التزامن ثم `git diff --check`.

## Local Regression Results

| الفحص | النتيجة |
|---|---|
| `npm run db:reset` | PASS — طبّقت هجرات Phase 2 الثلاث (`20261006152256`، `20261006153844`، `20261006161000`) مع إعادة البناء الكاملة |
| `npm run db:test` | `FILES=53 PASS=1138 FAIL=0 ERROR=0` |
| `npm run db:index` | `columns=942 constraints=554 functions=272 triggers=52` ومطابق للمستودع بلا تغيير |
| `npm run c:db` | SUCCESS (reset + test + index معًا) |
| `npm run c:state` | SUCCESS (`MIGRATIONS=116 SEALED_NEXT=113` من §4) |
| `scripts/p2_automation_concurrency_proof.py` | `CONCURRENCY PROOF SUCCESS` — اتصالان مستقلان على قاعدة Supabase المحلية |

## P2 Local Concurrency Proof (PROVEN)

أُثبت محليًا بـ`scripts/p2_automation_concurrency_proof.py` السباق الحقيقي
**قبل أول commit** على تجهيزة جديدة، باتصالين PostgreSQL مستقلين:

- **same-command fresh concurrency:** نفس `command_id` على تجهيزة جديدة —
  المحاولة الثانية رُصدت محجوبة على قفل النية ثم أعادت `replayed` مع إيصال
  الأعمال نفسه؛ أثر أعمال واحد وإيصالان متطابقان accepted/replayed. أثبت
  الـCloud evidence للنمط نفسه `processed command row = 1` لنفس
  `command_id`.
- **different-command same-intent concurrency:** معرفا أمر مختلفان لنفس
  البصمة على تجهيزة جديدة — الحجب نفسه، والأثر أعمال واحد وإقراران متطابقان.

**الحالة:** PROVEN (محليًا).

## Security Disposition — Local Verification (PROVEN)

**ACCEPTED INTERNAL DESIGN** — الجداول الداخلية الثلاثة
`audit.booking_automation_attempts` و`ops.booking_automation_control`
و`ops.booking_automation_execution_contexts`: تحقق محليًا أن RLS مفعّل على
الثلاثة (`relrowsecurity=true`)، بلا أي `pg_policy` عليها، وأن ACL كاملًا
لـ`postgres` وحده — لا منح لأي دور آخر.

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
| 9 authorization/state rejection cases | PROVEN | revoked_delegation، operator_changed_pending_confirmation، booking_auto_transition_disabled، next_booking_changed، stale_decision_revision، stale_automation_revision، operator_unassigned، ambiguous_responsible_operator، authorization_revision_stale — كلها `business_receipt=null` |
| Runtime kill | PROVEN | `cron.unschedule` يمنع بدء نبضات جديدة بعد وقت الإيقاف؛ none started after stop؛ `active_cron_jobs=0` |
| Atomic DB kill | PROVEN | `global_automation_disabled` داخل قرار الأعمال |
| Monitoring correlation | PROVEN | ربط `cron.job_run_details` → Edge logs → `runtime_run_id` → `attempt_id` → `command_id` → `credential_ref` → `result` → `business_receipt` |
| Security Advisor disposition | PROVEN | الجداول الثلاثة RLS enabled + no policies + ACL postgres فقط: مقبولة تصميمًا داخليًا |
| Cloud cleanup | PROVEN | `active_cron_jobs=0` و`vault_v3=0` و`vault_v4=1` وحالة الحاكم مستقرة |

## Q-137 Readiness

**Candidate A = READY FOR Q-137 REVIEW.**

المخاطر السابقة أُغلقت بالأدلة المثبتة أعلاه. القرار النهائي لاعتماد
ق-137 بيد المالك؛ هذا النص يثبت الجاهزية للمراجعة ولا يعتمد القرار نفسه.

**q-137 = NOT ADOPTED.** القرار لم يُتخذ بعد؛ هذه الوثيقة لا تعتمده.

ملاحظات غير حاجبة قبل production:

- `pg_net` لا يزال beta.
- Vault لا يزال public alpha.
- رؤوس Authorization للطلب توجد مؤقتًا في `net.http_request_queue`.
- تجهيزات PRE-PRODUCTION المحتفظ بها ليست بيانات إنتاج.
- ق-137 ما يزال يتطلب مراجعة واعتمادًا صريحين من المالك.
