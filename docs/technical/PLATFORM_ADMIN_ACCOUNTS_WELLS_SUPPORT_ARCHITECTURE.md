# Platform Admin Accounts, Wells & Support Architecture

**آخر تحديث:** 2026-08-19
**القرار الحاكم:** ق-103
**المناقشة:** PA-02
**الحالة:** تصميم ملزم؛ التنفيذ الكامل Pending
**المسألة المفتوحة:** م-33
**أول DB change جديد:** Migration 078+

## 1. الهدف

تحديد Control Plane لإدارة:

- global accounts.
- persons.
- wells.
- identities.
- devices/sessions.
- support.
- error references.
- administrative corrections.
- recoverable current passwords.

## 2. Authority

Platform Admin Authority مستقلة عن Well Roles.

لا يحتاج أن يكون Owner أو Operator أو Partner.

## 3. Global Search

يلزم Typed Admin Search يستطيع البحث حسب:

- phone.
- name.
- account id.
- person id.
- well name.
- public code.
- business references.
- support/error references.

النتائج مصنفة حسب Entity Type.

## 4. Account Read Model

يعيد:

- profile identity.
- canonical person links.
- phone.
- status.
- platform-admin flag.
- wells.
- roles.
- devices.
- last activity.
- open support issues.
- password-vault state.

## 5. Profile and Person

Login Profile وBusiness Person مفهومان منفصلان.

Admin UI تستطيع إظهار العلاقة.

لا تستخدم Name Similarity لإنشاء Relation.

## 6. Identity Correction

Phone correction تحتاج:

- target account.
- uniqueness check.
- conflict detection.
- reason.
- confirmation.
- trusted auth update.
- canonical profile/person reconciliation.
- audit.

## 7. Duplicate Resolution

Merge يحتاج:

- side-by-side comparison.
- canonical person selection.
- relationship migration plan.
- financial/history safety.
- audit.

No automatic merge.

## 8. Account Suspension

قبل Suspend:

يفحص Backend:

- active sessions.
- open shifts.
- unresolved transfers.
- critical ownership/admin dependencies.

Suspend لا يمحو التاريخ.

## 9. Session Invalidation

Admin يستطيع إبطال:

- one device/session.
- all sessions.

لا تحذف Business Outbox/history بسبب Auth invalidation.

## 10. Global Wells

Admin Well Read Model يعيد:

- identity/public code.
- status.
- owners/users.
- activation.
- live sessions.
- sync health.
- support state.
- recent activity.

## 11. Well Administration

Admin يستطيع:

- correct metadata.
- suspend.
- restore.
- inspect all business domains.

لا Impersonation مطلوب.

## 12. User Preview

يمكن Read-only projection لما يراه:

- owner.
- operator.
- partner.

لا ينفذ Action باسم المستخدم.

## 13. Historical Records

Admin Full Authority لا تعني Direct History Rewrite.

Financial/Operational corrections تحترم:

- immutable posted records.
- reversal/correction.
- domain audit.
- historical snapshots.

## 14. Support Case Model

Target model يحتاج:

- case id.
- public/reference number.
- category.
- priority.
- status.
- account.
- person.
- well.
- linked entity.
- error reference.
- assigned admin.
- description.
- internal notes.
- timestamps.

## 15. Support Timeline

Timeline يجمع:

- case creation.
- user report.
- admin actions.
- system events.
- resolution.
- close/reopen.

## 16. Error Reference

كل relevant error يستطيع إنتاج Reference ثابت.

Admin lookup يعيد:

- request/correlation id.
- actor.
- well.
- action.
- app version.
- server error class.
- sync context.
- time.

## 17. Audit

كل Admin Mutation حساس يسجل:

- actor.
- target.
- before.
- after.
- reason.
- support case.
- result.
- server time.

Password plaintext لا تدخل Audit.

## 18. Password standard — ق-105

ق-105 تنسخ Recoverable Password Vault التي كانت موثقة
في ق-103.

Current architecture:

- Supabase Auth remains Password Verifier.
- no recoverable password copy.
- no current-password reveal.
- no reversible password encryption store.

## 19. Why no recoverable vault

المشروع لا يحتاج Current Password plaintext لتحقيق
Support.

الحاجة الحقيقية هي:

- recover account.
- verify identity.
- reset password.
- invalidate compromised sessions.

هذه تحقق دون Secret Recovery Store.

## 20. Admin password action

Platform Admin يستطيع:

    force password reset

لا يستطيع:

    reveal current password

ولا:

    retrieve old password

## 21. Reset-required state

Target Account Security Model يحتاج حالة واضحة مثل:

- normal.
- reset_required.
- disabled/locked حسب العقد النهائي.

Admin-triggered Reset يضع الحساب في Reset Required
ويولد Audit event.

## 22. Session handling

في Security Recovery عالي الخطورة:

- existing risky sessions invalidate.
- refresh/session policy تطبق خادميًا.
- new trusted session تصدر بعد إكمال Recovery.

التفصيل النهائي يعتمد Supabase Session Contracts وقت التنفيذ.

## 23. OTP recovery

المسار المستهدف:

    reset requested
      ↓
    OTP to verified phone
      ↓
    OTP verification
      ↓
    user chooses new password
      ↓
    Auth password update
      ↓
    reset flag cleared

Admin لا يقرأ New Password.

## 24. Lost-phone flow

إذا الهاتف غير متاح:

- Support Case.
- human identity verification policy.
- Admin changes phone through Trusted Backend.
- new phone verification.
- OTP.
- user chooses password.

No password reveal bypass.

## 25. Password policy

Target V1 policy:

- minimum 15 characters for normal single-factor password use.
- allow long passphrases.
- support at least 64 characters where platform allows.
- spaces allowed.
- Unicode allowed.
- no required mixture of uppercase/lowercase/numbers/symbols.
- common/compromised passwords blocked when capability is implemented.
- no arbitrary periodic password expiration.
- reset on compromise/recovery/security event.

## 26. Platform Admin MFA

Platform Admin authentication requires MFA.

V1 preferred available factor:

TOTP.

Trusted Admin APIs must validate the required assurance level
before privileged operations.

## 27. Step-up authentication

High-risk actions can require recent verification.

Examples:

- phone correction.
- force password reset.
- account suspend.
- well suspend.
- identity merge.
- entitlement revoke/correction.
- financial correction.
- exceptional accounting action.
- session invalidation.

## 28. Sensitive transaction confirmation

Before executing a high-risk mutation:

- identify target.
- show current state.
- show requested state.
- show important impact.
- collect reason when required.
- perform required reauthentication.
- confirm.
- execute.
- audit.

If significant transaction data changes between
confirmation and execution:

authorization must restart.

## 29. No password secrets in platform data

Forbidden:

- password plaintext in Database.
- recoverable password ciphertext.
- password in audit.
- password in logs.
- password in analytics.
- password in Support Notes.
- password in Local Storage.
- password in IndexedDB.
- password in Offline DB.
- password in Outbox.

## 30. Auth Admin boundary

Auth Admin operations execute from Trusted Backend.

Elevated Supabase credentials remain server-side.

Browser/Admin Console never receives:

- service_role.
- secret API key.
- database credentials.

## 31. Account administration tests

Required:

- non-admin denied.
- global account read requires Platform Admin.
- phone correction unique.
- duplicate merge preserves history.
- suspend blockers.
- restore audit.
- session invalidation.
- force reset authorization.
- reset-required lifecycle.
- OTP recovery.
- lost-phone recovery.
- admin cannot retrieve password.
- no recoverable password storage.

## 32. Well administration tests

Required:

- global well read requires Platform Admin.
- admin not inserted as owner.
- suspend warns on active session.
- history preserved.
- correction audited.
- preview read-only.

## 33. Support tests

Required:

- case lifecycle.
- direct references.
- error lookup.
- internal notes.
- no secrets in support payloads.
- audit linking.

## 34. Platform Admin security tests

Required:

- MFA enforced.
- assurance level checked.
- step-up enforced for selected actions.
- authorization cannot be bypassed.
- changed transaction data invalidates old confirmation.
- audit does not contain secrets.
- elevated key absent from frontend.
- session invalidation works.

## 35. Definition of Done

PA-02 لا تعتبر Production Complete حتى:

- م-33 مغلقة.
- global account/well APIs موجودة.
- support model موجود.
- error references موجودة.
- admin corrections موجودة.
- force-password-reset موجود.
- OTP recovery موجود.
- lost-phone recovery موجود.
- Platform Admin MFA موجودة.
- step-up rules موجودة.
- current-password reveal غير موجود.
- recoverable password vault غير موجودة.
- password policy مثبتة.
- audit مثبت.
- permanent security tests ناجحة.
