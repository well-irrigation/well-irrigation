# Platform Administration Architecture

**آخر تحديث:** 2026-08-19
**القرار الحاكم:** ق-102
**المناقشة:** PA-01
**الحالة:** تصميم ملزم؛ التنفيذ الكامل Pending
**المسألة المفتوحة:** م-32

## 1. الهدف

إنشاء Control Plane إدارية مستقلة لمنصة:

**إدارة البئر والسقي**

تستخدم بواسطة Platform Super Admin.

## 2. Actor model

Platform Admin ليس Tenant Role.

لا يحتاج:

- well_owner row.
- operator assignment.
- partner row.
- farmer account.

حتى يدير المنصة.

## 3. Global authority

Platform Admin يستطيع إداريًا الوصول إلى جميع
Business Domains وفق Trusted Admin Contracts.

## 4. Identity preservation

أي Admin Action تحفظ:

- platform admin identity.
- target entity.
- time.
- reason عند الحاجة.
- result.

لا Impersonation كمالك بئر.

## 5. Client boundary

Admin Console لا تحمل Infrastructure Secrets.

لا:

- service_role in browser bundle.
- DB password in frontend.
- private server keys in client.

## 6. Trusted server

عمليات Cross-Tenant الحساسة تمر عبر Trusted Backend.

Backend هو الذي يملك Privileged Credentials عند الحاجة.

## 7. Admin API surface

Target contracts قد تشمل:

- `api.admin_dashboard_*`.
- `api.admin_search_*`.
- `api.admin_well_*`.
- `api.admin_account_*`.
- `api.admin_entitlement_*`.
- `api.admin_support_*`.
- `api.admin_audit_*`.

الأسماء النهائية تحسم أثناء التنفيذ.

## 8. Dashboard aggregates

الخادم يعيد Aggregated Metrics.

لا تحمل الواجهة Raw Rows فقط لتعد الأرقام.

## 9. KPI domains

### Wells

- total.
- active.
- inactive.
- setup/draft.
- new in period.

### Accounts

- total.
- active.
- disabled.
- new in period.

### Relationships

- owners.
- operators.
- partners.
- farmers.
- farms.

### Operations

- live sessions.
- daily sessions.
- bookings.
- open shifts.

### Sync

- pending.
- conflicts.
- failures.
- oldest pending.

### Activation

- available.
- consumed.
- revoked.
- new activations.

### Finance

- collections.
- expenses.
- outstanding aggregates when valid.

## 10. Near-real-time behavior

Preferred pattern:

    backend state change
      ↓
    realtime event / invalidation
      ↓
    refresh affected aggregate
      ↓
    dashboard update

Fallback:

Periodic refresh.

لا يعتمد Admin على reload الصفحة.

## 11. No false live state

إذا توقف Realtime أو الاتصال:

UI تعرض:

- connection state.
- last update.
- stale indicator.

## 12. Sidebar navigation

Desktop RTL:

Sidebar على اليمين.

Sections:

- Dashboard.
- Wells.
- Accounts & Persons.
- Sales & Activation.
- Operations.
- Finance.
- Sync & Devices.
- Problems & Support.
- Audit Log.
- System Monitoring.
- Platform Settings.

## 13. Dashboard charts

ق-100 تحكم Charts.

V1:

- Bar.
- Line.

## 14. Wells/accounts growth chart

Line Chart.

Series يمكن أن تكون:

- new wells.
- new accounts.

كلاهما Count.

## 15. Operations chart

Daily Session Count أو Hours حسب Metric المختارة.

## 16. Health chart

يعرض:

- sync failures.
- conflicts.
- support/system issues.

بـBar/Line مناسب.

## 17. Drill-down

KPI أو Chart يستطيع الانتقال إلى Source List المفلترة.

## 18. Global wells

PA-02 تفصل:

- search.
- view.
- edit.
- suspend.
- recovery.
- exceptional correction.

## 19. Global accounts

PA-02 تفصل:

- person/account search.
- identity.
- phone.
- status.
- auth recovery.
- roles.
- wells.
- support actions.

## 20. Entitlements

يعاد استخدام ق-86.

Platform Admin هو المسؤول الإداري عن:

- grant.
- correction.
- revoke when justified.
- audit.

## 21. Operations monitoring

Admin يستطيع رؤية Operational State على مستوى المنصة.

## 22. Financial monitoring

Admin يستطيع رؤية Global Finance وفق Admin Authority.

Any correction يجب أن يحافظ على Domain Invariants.

## 23. Sync observation

Admin يرى Server-observable truth.

معلومة لم تصل إلى الخادم من جهاز Offline بالكامل لا يمكن
للخادم اختراعها.

لذلك Device Telemetry/Sync design يجب أن توضح حدود
الرؤية.

## 24. Support cases

يلزم نموذج يساعد على ربط:

- user.
- well.
- error reference.
- timestamps.
- issue category.
- resolution.
- admin actions.

## 25. Audit

Audit mandatory لكل Admin Mutation حساس.

## 26. Monitoring

Observability قد تشمل:

- API.
- Auth.
- SMS/OTP.
- notification senders.
- sync.
- DB/app errors.
- version adoption.

## 27. Platform settings

Settings يجب أن تفرق بين:

- business configuration.
- operational platform flags.
- secrets.

Secrets لا تعرض في ordinary Admin UI.

## 28. Password visibility requirement

Product Requirement:

Platform Super Admin يريد رؤية Current Password.

Current implementation status:

**Blocked.**

لا يوجد عقد حالي يعيد Plaintext Current Password.

الحل لا يفترض تلقائيًا.

PA-02 يجب أن يقرر:

- هل نغير requirement إلى reset-only؟
- أو نعتمد architecture مختلفة؟
- وما آثار الأمن والهجرة والخصوصية؟

إلى أن يحسم:

لا Plaintext storage.
لا Reversible password vault.
لا claim بأنه implemented.

## 29. Realtime security

Realtime event لا يجوز أن يصبح Backdoor يتجاوز
Admin authorization.

كل Admin Connection تحتاج Auth موثوقًا.

## 30. Tests

- non-admin cannot open admin APIs.
- admin can cross tenant through approved contract.
- admin action audit preserved.
- admin actor not rewritten to owner.
- KPIs match canonical sources.
- realtime update does not leak unauthorized data.
- stale state visible.
- chart totals match source metrics.
- global search deterministic.
- entitlement mutation audited.
- privileged secrets absent from frontend.
- password visibility remains blocked until resolved.

## 31. Definition of Done

PA-01 لا تعتبر Production Complete حتى:

- م-32 مغلقة.
- Admin Authority implemented.
- Trusted Backend implemented.
- global reads/writes implemented.
- Dashboard metrics implemented.
- realtime/fallback implemented.
- Audit implemented.
- monitoring implemented.
- security tests successful.

## 32. ق-103 / PA-02 — Accounts, Wells, Support & Password Vault

ق-103 تعتمد PA-02 بالكامل.

### Supersession of section 28

Section 28 السابقة سجلت Password Visibility كRequirement
غير محسومة التصميم.

ق-103 تحسمها:

**Option B معتمد.**

Target:

**Recoverable Encrypted Current Password Vault.**

Current status:

- Architecture adopted.
- Implementation Pending.
- م-33 مفتوحة.

### Important boundaries

ق-103 لا يغير:

- Platform Admin مستقل عن Well Roles.
- Trusted Backend.
- لا service_role في Client.
- Audit إلزامي.
- لا Direct Client DML.

### Password boundary

Supabase Auth Hash تبقى Authentication Source.

Vault الإضافية مسؤولة فقط عن Recoverable Secret Copy
المطلوبة من Platform Admin.

Plaintext Password at Rest ممنوعة.

### PA-02 source

المصدر التفصيلي:

`PLATFORM_ADMIN_ACCOUNTS_WELLS_SUPPORT_ARCHITECTURE.md`

### Next

PA-03:

Sales, Activation, Operations & Financial Control.

## 33. ق-104 — Standards Hardening

PA-01/PA-02 تخضع الآن لـResearch & Standards Gate.

### Admin navigation

- right RTL Sidebar remains.
- Global Search remains easy to reach.
- long pages may use Sticky Filter/Search Toolbar.
- reduce unnecessary context switching.

### Admin tables

Large datasets use:

- server-side query.
- filtering.
- sorting.
- pagination.

No Infinite Scroll as the primary V1 admin-table pattern.

### Dashboard refresh

Do not poll every KPI every second.

Use:

- event/realtime invalidation for important changing state.
- refresh affected aggregates.
- slower refresh for large trend/report aggregates.
- stale timestamp when realtime is not healthy.

### Monitoring hierarchy

Admin operational view shows:

    symptom
      ↓
    impacted entity
      ↓
    diagnostic cause

Technical internals belong in Monitoring/Drill-down.

### Accessibility

Admin Console targets WCAG 2.2 AA.

Critical controls target large interaction areas.

Keyboard focus and semantic status messages are required.

### Authentication

Platform Admin MFA mandatory.

High-risk action requires additional recent verification
when defined by policy.

## 34. ق-105 — Password Supersession

ق-105 تنسخ Password Option B من ق-103.

Current:

- no Password Vault.
- no Current Password Reveal.
- no recoverable password copy.

Admin support uses:

    Force Password Reset
        ↓
    OTP identity proof
        ↓
    user chooses new password

Lost phone uses audited Identity Recovery first.

Section 32's Option B description is historical and must not
be implemented.

The non-password PA-02 architecture remains active.
