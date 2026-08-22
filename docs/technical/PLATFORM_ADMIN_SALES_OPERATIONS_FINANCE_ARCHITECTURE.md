# Platform Admin Sales, Operations & Finance Architecture

**آخر تحديث:** 2026-08-19
**القرار الحاكم:** ق-106
**المناقشة:** PA-03
**الحالة:** تصميم ملزم؛ التنفيذ الكامل Pending
**المسألة المفتوحة:** م-34
**Research & Standards Gate:** PASS
**أول DB change جديد:** Migration 085+

## 1. الهدف

تحديد Control Plane لـ:

- Platform Sales.
- Well Activation Entitlements.
- Sale/Activation corrections.
- Global Operations Monitoring.
- Administrative Session Corrections.
- Global Financial Monitoring.
- Financial Corrections.
- Accounting-period admin approval.
- Export.
- Audit.
- privileged-command safety.

## 2. Commerce Boundary

مال المنصة منفصل عن Well Business Finance.

Platform Commerce:

- sale amount.
- purchase.
- entitlement.
- correction/refund/void context.

Well Finance:

- irrigation invoices.
- farmer payments.
- expenses.
- partner distributions.
- accounting periods.

لا Canonical Total يدمج المجالين.

## 3. Sale model

Target Sale record يحتاج على الأقل:

- stable sale id.
- purchaser phone/account when available.
- rights quantity.
- amount in whole YER.
- payment date/time.
- payment/admin method when needed.
- note.
- state.
- created by Platform Admin.
- server timestamps.
- operation/idempotency id.

الأسماء النهائية للجداول تحسم في Migration 085+.

## 4. Entitlement model

كل Entitlement تمثل حق Well واحدة.

Core attributes:

- entitlement id.
- purchaser/account/phone association.
- source sale.
- state.
- consumed well.
- consumed time.
- revoked time/reason.
- correction lineage.
- audit metadata.

## 5. Entitlement states

V1:

- available.
- consumed.
- revoked.

لا recurring expiry.

## 6. One purchased well = one entitlement

إذا اشترى العميل 5 آبار:

ينشأ 5 Entitlements.

لا نستخدم Counter وحيدًا يخفي تاريخ كل Well.

## 7. Atomic sale grant

Create Sale + N Entitlements:

يجب أن تكون Transaction ذرية أو Trusted Orchestration
بضمان مماثل.

Partial grant غير مقبول.

## 8. Idempotency

كل Create/Correction/Revoke Admin Command يحتاج
Stable Operation ID.

Retry:

لا ينشئ أثرًا ثانيًا.

## 9. Well activation consumption

ق-86 يبقى حاكمًا:

- OTP does not consume.
- account creation does not consume.
- wizard does not consume.
- successful Well creation consumes.

## 10. Atomic well creation

Target:

    validate entitlement
      ↓
    create well
      ↓
    create owner/required setup
      ↓
    consume entitlement
      ↓
    commit

إما الكل أو لا شيء.

## 11. Double-spend prevention

يلزم Database/Service guard يمنع:

- concurrent consumption.
- repeated retry.
- two wells consuming one entitlement.

## 12. Entitlement follows well

بعد Consumption:

الحق مرتبط بالWell.

Ownership change لا يجعله reusable.

## 13. Sale correction

Sale الأصلية لا Hard Delete.

Target correction concepts:

- void.
- correction.
- administrative cancellation.

تحفظ original sale reference.

## 14. Activation correction

Consumed entitlement لا تعدل تاريخيًا إلى Available.

يستخدم Correction Record/Event.

## 15. Replacement entitlement

إذا استحق العميل حقًا بديلًا:

ينشأ Entitlement جديد.

يحتفظ lineage إلى التصحيح.

## 16. Available revocation

Requires:

- Platform Admin.
- reason.
- current state validation.
- impact preview.
- Step-up.
- confirmation.
- audit.

## 17. Consumed entitlement intervention

عملية استثنائية.

لا Normal Toggle.

Target behavior قد يكون:

- activation hold.
- administrative suspension.
- correction case.

لا يحذف Well.

## 18. Operation monitoring read model

يلزم Admin Read Model يعيد على مستوى المنصة:

- live sessions.
- latest server activity.
- shifts.
- booking conflicts.
- server-known sync issues.
- conflicts.
- review flags.

## 19. Offline-aware monitoring

Server لا يدعي معرفة Command لم تصل إليه.

UI تفرق بين:

- server-known problem.
- no recent server update.
- explicit conflict.
- stale/unknown state.

## 20. Session admin detail

Admin Session Read Model تجمع Timeline من Canonical
operations.

Flutter/Web لا تعيد بناء Truth من عدة جداول بطريقة
قد تختلف عن Backend.

## 21. No generic session editor

Admin mutation surface تعرض Domain Actions فقط.

لا Raw Row Editor.

## 22. Administrative session closure

Exceptional closure needs:

- session id.
- known last event.
- actual end time.
- reason.
- support/evidence reference.
- expected billing impact.
- Platform Admin actor.
- Step-up.
- confirmation.

## 23. Session history

Administrative closure/correction تضاف إلى Timeline.

لا تمحو Original History.

## 24. No hardware fiction

لا Remote Pump Stop Action إلا عند وجود Hardware Control
مطبق ومثبت.

## 25. Global finance read model

Admin finance monitoring needs typed reads for:

- invoices.
- payments.
- expenses.
- distributions.
- accounting periods.
- exceptions/review states.

## 26. Finance read-first

Default Admin experience:

Inspect/Filter/Drill-down.

لا Editable Spreadsheet behavior.

## 27. Financial correction

Posted data تتبع ق-99:

- reversal.
- correction.
- adjustment.

لا direct overwrite.

## 28. Payment correction

Payment الأصلية تبقى.

Reversal/Correction هي سجل جديد مرتبط بها.

## 29. Expense correction

Posted Expense لا تعدل Amount بصمت.

## 30. Distribution correction

Approved distribution لا تعدل Inline.

## 31. Accounting period reopen

قاعدة المشروع الحالية تبقى:

- reopen request.
- reason.
- partner approvals by current threshold rule.
- Platform Admin final approval.
- audit.

لا Break-glass bypass في V1.

## 32. Authorization integrity

High-risk action confirmation binds to:

- target.
- current version/state.
- requested values.
- amount where relevant.
- reason.

تغير البيانات المهمة يتطلب Re-authorization.

## 33. Step-up

High-risk PA-03 actions need recent Platform Admin
verification according to ق-104/ق-105.

## 34. Audit

Every sensitive mutation logs:

- actor.
- action.
- target.
- before.
- after.
- reason.
- support case.
- operation id.
- server time.
- result.

## 35. Secret-safe audit

Never log:

- passwords.
- OTP secrets.
- access/refresh tokens.
- service keys.
- encryption keys.

## 36. Export

Admin exports are:

- typed.
- filtered.
- business-scoped.

Not raw DB dump.

Sensitive export event is audited.

## 37. Table contracts

Large admin lists use Server-side:

- search.
- filter.
- sort.
- pagination.

## 38. Admin write state machine

    ready
      ↓
    confirming
      ↓
    processing
      ↓
    succeeded / failed / needs_review

No optimistic final success for privileged writes.

## 39. Server acknowledgment

Final UI success requires trusted Backend ACK.

## 40. Retry

Retry uses same idempotency/operation key.

Unknown result after connection loss:

reconcile by Operation ID before creating a new command.

## 41. Online-only

PA-03 privileged writes are Online-only.

No local privileged Outbox.

## 42. Read staleness

Cached admin reads may be shown only if:

- timestamp visible.
- stale state visible.
- no claim of Live.

## 43. API direction

Target Admin contracts may include:

- platform sale list/detail/create.
- sale correction.
- entitlement list/detail.
- entitlement revoke/correct.
- activation reconciliation.
- global operations.
- admin session detail.
- administrative session closure.
- global finance.
- payment/expense/distribution correction.
- accounting reopen decision.
- export request.

Names finalized during implementation.

## 44. Security boundary

Admin Client never receives:

- service_role.
- DB credentials.
- privileged internal secrets.

Cross-tenant writes go through Trusted Backend.

## 45. Research classification

### Standards-aligned

- idempotency.
- explicit transaction authorization.
- audit.
- immutable-history correction.
- Step-up.
- online privileged writes.
- server-side pagination.

### Adapted

- one entitlement per purchased well.
- permanent manual V1 sale.
- partner-vote + Platform Admin reopen decision.

### Rejected V1

- raw SQL console.
- direct finance edit.
- force-reopen bypass.
- offline admin writes.
- infinite-scroll primary tables.
- fake hardware controls.

## 46. Research evidence

Reviewed 2026-08-19:

- OWASP Transaction Authorization.
- OWASP Logging.
- GitHub Sudo Mode.
- GitHub Audit Log.
- Stripe Entitlements.
- Stripe Idempotency.
- Stripe Refund object model.

Stripe is evidence for patterns only.

No Stripe dependency is adopted.

## 47. Acceptance tests — Sales

- same command retry creates one sale.
- N rights creates exactly N entitlements.
- partial grant cannot commit.
- amount/quantity validation.
- audit actor correct.

## 48. Acceptance tests — Entitlements

- available consumes once.
- concurrent double consume rejected.
- failed well creation leaves right available.
- consumed right links one well.
- ownership change does not free right.
- revoked right cannot consume.
- replacement creates new id.

## 49. Acceptance tests — Corrections

- sale original preserved.
- void/correction linked.
- consumed entitlement history preserved.
- no direct state rewrite bypass.
- correction audited.

## 50. Acceptance tests — Operations

- non-admin denied.
- offline silence not labeled server-known failure.
- admin closure requires reason/end time.
- closure adds history.
- no raw edit.
- changed target state invalidates old confirmation.

## 51. Acceptance tests — Finance

- posted payment cannot direct-edit.
- posted expense cannot direct-edit.
- approved distribution cannot direct-edit.
- reversal/correction preserves original.
- period reopen still needs required partner approvals.
- Platform Admin decision audited.

## 52. Acceptance tests — Admin UX/backend

- privileged write Online-only.
- retry uses same idempotency key.
- unknown result reconciles.
- success waits server ACK.
- pagination/filter/sort query whole dataset.
- sensitive export audited.
- no secrets in logs.

## 53. Definition of Done

PA-03 لا تعتبر Production Complete حتى:

- م-34 مغلقة.
- sale model implemented.
- entitlement model implemented.
- atomic grant proven.
- idempotency proven.
- activation double-spend prevention proven.
- corrections implemented.
- operations read models implemented.
- admin session closure implemented.
- finance read/correction contracts implemented.
- reopen approval verified.
- step-up verified.
- audit verified.
- exports verified.
- pagination verified.
- online-only enforcement verified.
- permanent tests successful.
