# Final Cross-Cutting UX Architecture

**آخر تحديث:** 2026-08-19
**القرار الحاكم:** ق-108
**UX:** UX-17
**الحالة:** Design Complete; implementation Pending
**المسألة المفتوحة:** م-36
**Research & Standards Gate:** PASS

## 1. الهدف

هذه الوثيقة لا تنشئ Feature جديدة.

وظيفتها ضمان أن كل Features المعتمدة تعمل كتجربة منتج
واحدة متسقة عبر:

- roles.
- wells.
- offline/online.
- operations.
- finance.
- account/security.
- platform administration.

## 2. UX authority

UI لا تخترع Business Rule.

Business authority تبقى في Backend/Domain Contracts.

## 3. State model

كل شاشة مهمة يجب أن تفرق بين:

- local durable state.
- pending sync.
- server-confirmed state.
- conflict.
- needs review.
- failure.

## 4. Offline-first mobile

Field app reads from local durable data where architecture
supports it.

Network refresh updates local state.

UI consumes consistent local/UI state rather than waiting
on direct network calls for every screen.

## 5. Write classification

Each write is explicitly one of:

- offline-safe durable write.
- online-only write.

UI messaging follows the actual class.

## 6. Offline-safe write UX

After durable local save:

    تم الحفظ على الجهاز

If not server confirmed:

    بانتظار المزامنة

Never claim server success early.

## 7. Online-only write UX

No final success until trusted Backend ACK.

## 8. Retry

Retry must reuse stable operation identity where required.

UI prevents accidental duplicate submission.

## 9. Sync terminology

Canonical user-facing terms:

- محفوظ على الجهاز.
- بانتظار المزامنة.
- تمت المزامنة.
- يحتاج مراجعة.
- تعذر الإرسال/المزامنة.

Terms may be shortened only when meaning remains explicit.

## 10. Connectivity

Connectivity state is not Sync state.

Connectivity UI must not flicker/reflow the whole page
during unstable networks.

## 11. Conflict

Conflict UI provides:

- affected record.
- current state.
- reason/category when safe.
- action available.

## 12. Form preservation

Validation/server/network failure should not destroy
valid entered data.

## 13. Form errors

Error belongs as near as practical to the field/action.

Provide corrective instruction.

## 14. Success

Important success response includes:

- outcome.
- reference when available.
- resulting state.
- next step when meaningful.

## 15. Error Reference

Technical error details remain server/admin-side.

User sees safe Reference + useful guidance.

## 16. Empty/loading/error

These are distinct UI states.

Do not display empty state while actually loading.

Do not display generic error for access denial.

## 17. Refresh

Background refresh should not block readable local data.

Stale important data shows freshness.

## 18. Financial presentation

Amounts use whole YER.

Debt/advance/paid/expense/profit meanings are textual,
not sign/color-only.

## 19. Sensitive operation review

High-impact action needs review of significant data before
final submission.

## 20. Historical records

Posted/settled history is not presented as ordinary
editable form fields.

## 21. Search

Smart Lookup is consistent across eligible entity selectors.

Search text is not entity identity.

## 22. Identity

Canonical UUID selection.

No automatic identity merge from fuzzy/name similarity.

## 23. Navigation

Navigation remains role-aware and context-aware.

No separate role-selection screen.

## 24. Well context

Current Well must be visible where cross-well confusion
could cause incorrect action.

## 25. Context change

Unsaved/critical operation must be resolved or explicitly
handled before context switch.

## 26. Mobile accessibility

Interactive touch targets:

minimum 48×48dp.

Critical field controls may be larger.

## 27. Accessibility semantics

Interactive icon-only elements need semantic labels.

Meaning does not rely on color alone.

## 28. RTL

Arabic RTL is native layout direction.

Use directional semantics that mirror correctly.

## 29. Typography

Respect Android font scaling.

Critical content should reflow instead of truncate.

## 30. Adaptive layout

Compact/medium/expanded windows can use different
navigation/layout patterns.

Do not force a phone Bottom Navigation pattern onto
large screens.

## 31. Admin separation

Platform Admin Web/Desktop architecture remains
independent from Well-user navigation.

## 32. Notifications

Push notification is a delivery channel.

It is not Business Source of Truth.

## 33. Support

Support context exposes only safe diagnostic identifiers.

## 34. Privacy

Minimize display of phone/financial/sensitive data where
not required by the task.

## 35. No placeholder actions

Production action requires a real contract and meaningful
result.

## 36. Deferred features

Deferred features do not pollute critical V1 workflows.

## 37. Visual consistency

Use shared:

- typography.
- spacing.
- status semantics.
- button hierarchy.
- error semantics.
- confirmation patterns.

## 38. Primary action

Each critical screen should have one visually clear primary
action.

## 39. Dangerous actions

Dangerous/corrective actions visually separated from
routine primary save/continue actions.

## 40. Back behavior

Back does not silently destroy critical work.

## 41. Acceptance matrix

Before a screen is Production Complete verify:

- role.
- permissions.
- well context.
- offline.
- reconnect.
- retry.
- duplicate tap.
- stale data.
- empty state.
- error state.
- accessibility.
- RTL.
- font scale.
- financial confirmation if applicable.
- server authorization.
- telemetry/privacy.

## 42. Research basis

Reviewed/current guidance includes:

- Android Offline-first architecture.
- Android accessibility/touch targets.
- Android adaptive navigation/window size classes.
- WCAG 2.2.
- government service confirmation/error patterns.
- public offline/sync product feedback.

## 43. Definition of Done

UX Design phase is complete when:

- ق-108 documented.
- UX-17 documented.
- م-36 opened.
- Project Map updated.
- Resume Point moves to Implementation sequencing.
- Documentation Gate passes.

Implementation is separate and remains Pending.
