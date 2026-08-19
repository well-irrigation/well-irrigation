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

## 18. Password architecture reality

Supabase Auth يبقى Authentication provider.

Supabase Current Password نفسها ليست مسترجعة من Hash.

ق-103 لذلك يضيف Vault منفصلة.

## 19. Recoverable Password Vault

Target internal model يمكن أن يحتوي:

- user_id.
- vault_version.
- state.
- ciphertext.
- nonce/iv.
- wrapped_data_key.
- algorithm_version.
- source_operation_id.
- created_at.
- activated_at.
- retired_at.
- stale_reason.

لا exposed table للClient.

## 20. Vault states

الحالات الأساسية:

- unavailable.
- pending.
- active.
- stale.
- retired.

`active` فقط يمكن عرضه بوصفه Current Password.

## 21. Existing users

عند إطلاق Vault:

الحسابات الحالية تبدأ:

    unavailable

إلا إذا مرت Password حديثًا عبر Orchestrator الجديد.

لا توجد محاولة لفك bcrypt hash.

## 22. Encryption

لا Plaintext Password at Rest.

Target:

Authenticated Encryption.

الاختيار المبدئي:

AES-256-GCM أو Primitive رسمي مكافئ معتمد في
بيئة التنفيذ.

## 23. Envelope Encryption

لكل Password Version:

- Data Encryption Key منفصل أو derivation آمن.
- ciphertext في Database.
- wrapped data key في Database.
- Key Encryption Key خارج Database.

KEK لا تحفظ في نفس جدول Vault.

## 24. Key Management

يلزم:

- secret manager/KMS suitable to deployment.
- key identifiers.
- rotation.
- access control.
- backup/recovery policy.
- compromise rotation procedure.

## 25. Password Set Orchestrator

كل إنشاء أو تغيير Password supported يمر:

    authorize
      ↓
    validate policy
      ↓
    encrypt candidate
      ↓
    save pending vault version
      ↓
    update Supabase Auth
      ↓
    promote vault version
      ↓
    retire previous version
      ↓
    audit metadata

## 26. Why pending-before-auth

إذا خزنا Vault بعد Auth فقط وانهارت العملية بين الخطوتين:

قد تصبح Supabase Password جديدة بينما Vault قديمة.

لذلك encrypted candidate تحفظ أولًا كPending.

## 27. Failure before Auth update

إذا فشل Supabase Auth Update:

- pending version لا تصبح active.
- يمكن إلغاؤها/retire.
- current vault version تبقى كما كانت.

## 28. Failure after Auth update

إذا نجح Auth update ثم انقطع الطلب:

pending encrypted candidate موجودة بالفعل.

يستخدم Operation ID للمصالحة والترقية إلى Active.

لا نحتاج إعادة plaintext من المستخدم بسبب crash.

## 29. Supported mutation paths

يجب دمج Vault مع:

- account creation.
- first password creation.
- user password change.
- forgot-password reset.
- admin reset.

## 30. Direct client password mutation

Flutter/Web user UI لا تستخدم Direct Password Mutation
كـSupported Product Path بعد تطبيق ق-103.

كل تغيير معتمد يذهب إلى Trusted Password Orchestrator.

## 31. Bypass consistency risk

Production closure تتطلب إثبات أن Password لا يمكن
تغييرها ضمن المسارات المدعومة دون تحديث Vault.

إذا وقع External/Out-of-band change ولا نستطيع إثبات
التطابق:

Vault تتحول Stale/Unavailable.

لا تعرض النسخة السابقة بوصفها Current.

## 32. Reveal endpoint

Admin Reveal endpoint:

- authenticates Platform Admin.
- checks active vault state.
- decrypts server-side.
- returns secret for short-lived display.
- audits reveal event without secret value.

## 33. Reveal UI

Default:

    ••••••••••••

Action:

    عرض كلمة المرور

بعد العرض:

- لا تحفظ في Local Storage.
- لا تحفظ في IndexedDB.
- لا تحفظ في Service Worker cache.
- لا تدخل analytics.
- لا تدخل support notes.

## 34. Reauthentication

قبل Reveal يمكن أن يطلب النظام إعادة تحقق حديثة من
Platform Admin أو MFA عند اعتمادها أثناء التنفيذ.

هذا لا يقلل Authority؛ هو حماية لعملية كشف Secret.

## 35. Password logs

Forbidden:

- request-body logging.
- debug logging.
- audit plaintext.
- tracing plaintext.
- exception plaintext.
- analytics plaintext.

## 36. Password transport

Password لا تنتقل إلا عبر TLS إلى Trusted Backend.

لا ترسل عبر notification أو support message.

## 37. Supabase password

Supabase Auth تظل تملك Hash اللازمة لتسجيل الدخول.

Vault لا تستبدل Auth Hash.

هي Secret Recovery Store موازية لأغراض Platform Admin.

## 38. Password reset by admin

Platform Admin يستطيع:

- reveal current vault password when active.
- set a new password.
- see the new password.

Admin Reset يمر عبر نفس Orchestrator.

## 39. Vault deletion/history

لا نحتاج الاحتفاظ بنصوص Password قديمة قابلة للاسترجاع
بعد Rotation العادية لأغراض المنتج.

عند تفعيل Version جديدة:

القديمة تصبح Retired وتخضع لسياسة إزالة Secret Material
المعتمدة.

Audit يحتفظ بالحدث دون Password.

## 40. Database exposure

Vault internal schema لا تدخل Exposed Schemas.

لا Direct Select للAuthenticated role.

لا Direct Client DML.

## 41. Trusted backend

فقط Trusted Backend يمتلك:

- Auth Admin credential.
- decryption capability.
- KEK/KMS permission.
- admin orchestration.

## 42. Support access

Support Case يمكن أن تسجل أن Password Reveal حدث.

لا تسجل Password نفسها.

## 43. Tests — accounts

- global account read requires Platform Admin.
- non-admin denied.
- phone correction unique.
- duplicate merge no history loss.
- suspension blockers.
- restore audit.
- session invalidation behavior.

## 44. Tests — wells

- global well read requires Platform Admin.
- admin not inserted as owner.
- suspend warns on active session.
- history preserved.
- correction audited.
- preview is read-only.

## 45. Tests — support

- case lifecycle.
- direct references.
- error lookup.
- internal notes.
- no secrets accepted/logged where prohibited.
- audit linking.

## 46. Tests — password vault

- plaintext absent at rest.
- ciphertext decrypts only through trusted service.
- wrong key fails.
- tamper detection works.
- nonce uniqueness.
- key rotation.
- pending-before-auth.
- failed auth does not activate vault version.
- crash-after-auth reconciliation.
- previous secret retirement.
- unavailable legacy user.
- stale vault never shown as current.
- non-admin reveal denied.
- reveal audited without plaintext.
- no browser persistent cache.
- no logs/analytics plaintext.

## 47. Definition of Done

PA-02 لا تعتبر Production Complete حتى:

- م-33 مغلقة.
- global account/well APIs موجودة.
- support model موجود.
- error references موجودة.
- admin corrections موجودة.
- Password Vault موجودة.
- key management موجود.
- password orchestration موجود.
- vault consistency مثبتة.
- legacy coverage state مثبتة.
- reveal flow مثبت.
- audit مثبت.
- permanent security tests ناجحة.
