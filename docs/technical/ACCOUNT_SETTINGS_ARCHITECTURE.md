# Account & Settings Architecture

**آخر تحديث:** 2026-08-19
**القرار الحاكم:** ق-101
**UX:** UX-16A
**الحالة:** تصميم ملزم؛ التنفيذ الكامل Pending
**المسألة المفتوحة:** م-31

## 1. النطاق

هذه الوثيقة تحكم Account & Settings لمستخدمي الآبار.

Platform Administration خارج النطاق كليًا.

## 2. Unified Account

المبدأ:

    one phone
      ↓
    one person
      ↓
    one account
      ↓
    multiple wells
      ↓
    multiple well roles

لا Account لكل Role.

## 3. Phone identity

Phone تغيير حساس.

لا Direct Edit.

يلزم Trusted Flow مع:

- current authenticated user.
- verification.
- new unique phone.
- OTP.
- canonical identity update.
- Auth/Profile/Person consistency.

## 4. Lost old phone

Recovery يحتاج Support/Trusted Path.

لا يسمح بربط رقم جديد بناء على Name Similarity.

## 5. Password recovery

V1 تستهدف Forgot Password عبر:

- phone.
- OTP.
- new password.

لا يعتمد العميل دائمًا على تدخل يدوي لمجرد نسيان
Password.

## 6. Team roles

Well Team administration تعيد استخدام Canonical Person.

Role Assignment لا ينشئ Identity جديدة.

## 7. Role authority

Role Catalog ليس Authority وحده.

Backend Relationship/Authorization هو المرجع.

تحديث بق-113 (2026-08-22): م-18 مغلقة. الكتالوج صار مصدر
الإنفاذ لأجساد الدوال، فمنح صلاحية في `iam.role_permissions`
يغيّر الصلاحية فعليًا وفورًا. طبقة RLS تبقى على
`iam.has_well_role` كطبقة توافق للقراءة.

## 8. Operator deactivation

لا يسمح Deactivate إذا سيترك:

- open shift.
- active session.
- unresolved transfer.

دون معالجة.

## 9. Partner access

Access removal لا يمحو Historical Partnership Data.

## 10. Notifications

App Preference وAndroid Permission حالتان منفصلتان.

Notification denial لا يمنع Offline operation.

## 11. Device readiness

تستخدم نفس Architecture المعتمدة في ق-89 وق-90.

لا تنشئ Settings نظام Sync جديدًا.

## 12. Local account isolation

Local database/cache/outbox يجب أن تعرف Account Scope.

الحساب B لا يقرأ Cached Private State للحساب A.

## 13. Logout

إذا توجد Pending Commands:

لا تحذف.

Logout State وPending Business Commands مفهومان منفصلان.

## 14. Return of original account

عند تسجيل الحساب الأصلي:

يمكن استعادة Pending Commands التابعة له ومتابعة
Reconciliation.

## 15. Local wipe

أي Wipe Action:

- Support/Advanced only.
- checks pending commands.
- warns explicitly.
- must not silently destroy unacknowledged business work.

## 16. Appearance

V1:

- light.
- dark.
- system.

No custom palette.

## 17. Language

UI V1:

Arabic RTL.

Numbers:

English digits.

## 18. Date/Time display

User-facing date/time uses English presentation.

Examples:

    19/08/2026
    05:25 PM
    19/08/2026 05:25 PM

هذه قاعدة عرض فقط.

Server timestamp semantics تبقى في Backend contracts.

## 19. Platform boundary

هذه الوثيقة لا تمنح أي Platform Admin Authority.

Platform Administration لها:

`PLATFORM_ADMINISTRATION_ARCHITECTURE.md`

بعد اعتمادها.

## 20. Required backend work

Migration 078+ أو Trusted Server work قد تحتاج:

- change-phone orchestration.
- recover-phone orchestration.
- forgot-password endpoint.
- account/session invalidation.
- role lifecycle APIs.
- notification preference APIs.
- identity consistency checks.

## 21. Required Android work

- account-scoped local DB/cache.
- account-scoped outbox.
- safe logout.
- restore original pending context.
- device readiness entry.
- English date/time formatter.
- Android accessibility handling.

## 22. Tests

- duplicate phone rejected.
- role change does not duplicate person.
- logout keeps pending command.
- second account cannot read first account local data.
- return to original account restores own pending state.
- lost-phone recovery cannot hijack identity.
- date/time rendering remains English.
- permissions remain backend-enforced.

## 23. Definition of Done

UX-16A لا تعتبر Production Complete حتى:

- م-31 مغلقة.
- م-18 applicable gap مغلقة.
- Auth flows مثبتة.
- local account isolation مثبت.
- pending logout behavior مثبت.
- notification settings مثبتة.
- Backend tests ناجحة.
- Android tests ناجحة.

## 24. ق-105 — Password Recovery Current Rule

القسم السابق الخاص بتكامل Password Vault بق-103
منسوخ في جانب Vault بق-105.

User Account V1:

- password remains inside Supabase Auth verifier model.
- no recoverable password copy.
- no Platform Admin reveal.
- no password in Local Data.
- no password in Outbox.

Self password change:

- requires appropriate reauthentication.
- updates Auth password.
- does not create recoverable copy.

Forgot Password:

    OTP
      ↓
    verified identity
      ↓
    user chooses new password

Admin-triggered reset:

    reset-required
      ↓
    OTP
      ↓
    user chooses new password

Lost phone:

Identity Recovery first, then verified new phone and OTP.

Password policy follows ق-105.
