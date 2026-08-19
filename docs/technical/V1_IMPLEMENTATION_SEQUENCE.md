# V1 Implementation Sequence

**آخر تحديث:** 2026-08-19
**القرار الحاكم:** ق-109
**الحالة:** معتمد — التنفيذ يبدأ بعد Documentation Gate
**المسألة الجامعة:** م-37
**Research & Standards Gate:** PASS

## 1. الهدف

تحويل التصميم الكامل إلى برنامج تنفيذ مرتب حسب:

- dependencies.
- data integrity.
- security.
- Offline foundations.
- user-critical flows.
- testability.

لا ينفذ المشروع حسب ترتيب أرقام UX فقط.

## 2. قواعد التنفيذ

1. Migration 071–077 immutable.

2. أول DB change جديد = Migration 078.

3. Migration 078 ليست Migration عملاقة تجمع V1 كلها.

4. كل Domain change منطقي يحصل على Migration مستقلة
   متتابعة عند الحاجة:

   078, 079, 080 ...

5. كل DB change تحتاج Permanent Test مناسب.

6. Assistant/AI لا يشغل db:test/db:reset/Docker verification.

7. مالك المشروع يشغل Verification ويرسل النتائج.

8. لا نغلق Wave قبل Evidence مناسب.

9. لا نعدل Remote Database يدويًا خارج Migration workflow.

10. لا Production UI بلا Backend Contract حقيقي.

## 3. أسلوب التنفيذ

بعد Foundations نستخدم:

**Vertical Slices.**

أي Feature تنفذ End-to-End قدر الإمكان:

    DB / domain
      ↓
    API
      ↓
    local/offline layer when applicable
      ↓
    application state
      ↓
    UI
      ↓
    verification

لا نبني عشرات الشاشات فوق Contracts غير منفذة.

## 4. W1 — Backend Foundations

الأولوية الأولى.

يشمل الأساس المطلوب لـ:

- canonical identity.
- account/profile/person relationships.
- Farmer RLS corrections.
- role/permission authority wiring.
- Auth/OTP trusted flows.
- phone recovery foundations.
- activation entitlements.
- atomic well activation.
- minimum trusted admin grant capability.
- authorization/security invariants.

المسائل ذات الصلة تشمل:

- م-16.
- م-18.
- أجزاء م-33.
- أجزاء م-34.

### سبب W1

W2–W9 تعتمد على Backend Truth مستقرة.

## 5. W2 — Offline & Background Sync Foundations

يشمل:

- durable local database.
- Outbox.
- stable operation ids.
- retries.
- idempotent reconciliation.
- connectivity state.
- sync state.
- conflict state.
- WorkManager/background execution.
- Device Readiness.
- canonical user-facing sync semantics.

المسألة الرئيسية:

- م-25.

### Gate

لا نبدأ إنتاج معظم Field Screens قبل إثبات أن
Critical Offline Writes تحفظ محليًا بصورة دائمة.

## 6. W3 — Authentication, Onboarding & Well Creation

End-to-End:

- Splash.
- Login.
- OTP.
- account creation.
- create-well wizard.
- entitlement verification.
- atomic well creation + entitlement consumption.
- app bootstrap.
- role-aware routing.

هذه أول Vertical Slice مكتملة للمستخدم.

## 7. W4 — Core Irrigation Session

يشمل:

- session start.
- active session.
- billable timer.
- pause/resume.
- energy segments.
- offline-safe state.
- completion.
- settlement.
- invoice/payment allocation.
- fuel billing correction.

المسائل:

- م-26.
- م-27.

أي تصحيح لـMigration 066 يكون في Migration 078+
المناسبة ولا تعدل 066.

## 8. W5 — Operations Records & Coordination

يشمل:

- session history.
- farmer/farm records.
- bookings.
- shifts.
- operator handover.
- cash handover separation.
- conflict states.

المسألة:

- م-28.

## 9. W6 — Money & Partners

يشمل:

- farmer accounts.
- payments.
- advances.
- expenses.
- accounting periods.
- partners.
- profit cycles.
- distribution.
- financial corrections.

المسألة:

- م-29.

## 10. W7 — Well Management & Reporting

يشمل:

- well data.
- pumps.
- energy/fuel.
- pricing.
- fuel movements.
- reports.
- aggregates.
- Bar/Line charts.

المسألة:

- م-30.

## 11. W8 — Account, Settings & Notifications

يشمل:

- account settings.
- password recovery.
- phone recovery.
- logout/session management.
- devices.
- sync details.
- notifications.
- appearance.
- help/legal links.

المسائل:

- م-23.
- م-31.
- الأجزاء المتبقية من م-33 الخاصة بالمستخدم.

## 12. W9 — Platform Administration

الترتيب الداخلي:

### W9A — Trusted Admin Backend

ينفذ أولًا:

- global admin authorization.
- account/well admin reads.
- admin mutations.
- support/error references.
- sales/entitlements.
- operations/finance admin reads.
- monitoring/audit/configuration contracts.

### W9B — Admin Web/Desktop UI

بعد توفر Contracts:

- dashboard.
- wells.
- accounts.
- sales/activation.
- operations.
- finance.
- sync/devices.
- support.
- incidents.
- audit.
- monitoring.
- settings.

المسائل:

- م-32.
- م-33.
- م-34.
- م-35.

## 13. W10 — Final Acceptance & Release Readiness

يشمل:

- م-36 Cross-Cutting UX consistency.
- م-21 field testing.
- RTL.
- accessibility.
- font scaling.
- offline/reconnect.
- retry/duplicate-submit.
- security.
- finance invariants.
- admin separation.
- legal/privacy alignment.
- release readiness.

## 14. Dependency Rules

### Rule A

Identity/Auth before user flows.

### Rule B

Entitlement backend before production create-well flow.

### Rule C

Offline/Sync foundation before critical field screens.

### Rule D

Session core before history/reporting.

### Rule E

Settlement before downstream financial reporting.

### Rule F

Business APIs before Platform Admin UI that manages them.

### Rule G

Monitoring reads after the underlying operations exist.

### Rule H

Cross-cutting acceptance runs throughout implementation
and closes finally in W10.

## 15. Migration Strategy

Do not implement V1 in one migration.

Preferred pattern:

- coherent domain migration.
- permanent test.
- owner verification.
- commit.
- next dependent migration.

Migration number alone does not define a Wave.

One Wave may use multiple migrations.

## 16. Verification Gate per Wave

For each implementation batch:

1. code/schema/docs prepared.
2. static checks performed where safe.
3. assistant provides owner verification command.
4. owner runs DB/Docker/device tests.
5. results reviewed.
6. open issue updated.
7. Documentation Gate.
8. Commit/Push.
9. next dependent batch.

## 17. Research basis

### Supabase

Current official guidance supports:

- schema changes tracked as migrations.
- migrations committed to version control.
- applying migrations in order.
- avoiding unmanaged remote schema edits.

### Android

Current official offline-first architecture supports:

- local data source as source for reads.
- queues for deferred work.
- WorkManager for persistent queued work.

Project adaptation:

Offline foundation is implemented before critical
irrigation UI because field operation is core product
behavior.

## 18. Definition of Done

IMPLEMENTATION-01 is complete when:

- ق-109 documented.
- sequence source created.
- م-37 opened.
- RESUME_POINT moves to W1.
- handoff names W1 as next.
- Documentation Gate passes.

Next:

**W1 — Backend Foundations / Migration 078+ planning and implementation.**

## 19. W1-01 — Explicit Account/Person Identity Foundation

أول Slice في W1:

**Migration 078.**

تنشئ Tenant-aware explicit link بين:

- Login Profile.
- Business Person.

سبب ترتيبها أولًا:

Farmer self-scope RLS لا يمكن أن تكون صحيحة إذا لم يعرف
Backend أي Person تخص الحساب الحالي.

### لا يدخل W1-01

- Farmer RLS rewrite.
- Role Catalog wiring.
- Entitlements.
- OTP.

### حالة W1-01

مكتملة ضمن نطاقها المعتمد: Local verification + Cloud structure/security verification.

### التالي — W1-02

Farmer self-scope authorization / م-16 باستخدام الرابط
المثبت في 078.

أي DB change جديد يبدأ Migration 079+.

م-18 تراجع منفردة بعد تثبيت Identity Foundation.
