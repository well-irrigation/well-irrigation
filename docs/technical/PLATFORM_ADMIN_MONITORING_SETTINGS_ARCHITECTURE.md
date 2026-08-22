# Platform Admin Monitoring & Settings Architecture

**آخر تحديث:** 2026-08-19
**القرار الحاكم:** ق-107
**المناقشة:** PA-04
**الحالة:** تصميم ملزم؛ التنفيذ الكامل Pending
**المسألة المفتوحة:** م-35
**Research & Standards Gate:** PASS
**أول DB change جديد:** Migration 085+

## 1. الهدف

تحديد Control Plane لـ:

- system health.
- alerts.
- incidents.
- postmortems.
- telemetry correlation.
- audit administration.
- platform configuration.
- maintenance.
- application-version management.
- release/change tracking.
- dependency health.
- security monitoring.

## 2. Monitoring versus Business Dashboard

Business Dashboard:

- wells.
- accounts.
- sessions.
- sales.
- operational/business issues.

System Monitoring:

- service health.
- latency.
- errors.
- saturation.
- integrations.
- releases.

## 3. Overall health

Admin UI يجب أن تستطيع حساب/عرض Overall Health
من Canonical monitoring data.

لا تعتمد على Client Guessing.

## 4. Golden signals

الأساس:

- availability.
- latency.
- errors.
- saturation.

المشروع يضيف:

- sync health.
- auth/OTP health.
- notification health.
- application stability.

## 5. Symptom-first

الواجهة التشغيلية تعرض User/Business Impact أولًا.

Technical Cause بعد Drill-down.

## 6. Alert model

Target fields قد تشمل:

- alert id.
- fingerprint.
- severity.
- service.
- category.
- status.
- first seen.
- last seen.
- occurrence count.
- affected entities.
- linked incident.
- acknowledgement metadata.

## 7. Alert fingerprint

Dedup تعتمد Fingerprint مستقرة للسبب/السياق.

لا Alert مستقلة لكل occurrence.

## 8. Alert status

V1:

- open.
- acknowledged.
- investigating.
- resolved.

## 9. Alert severity

- critical.
- high.
- warning.
- info.

## 10. Incident model

Incident مستقلة عن Support Case.

Target fields:

- incident id.
- severity.
- status.
- started/detected/resolved timestamps.
- impacted services.
- impact summary.
- assigned admin.
- current diagnosis.
- timeline.
- linked alerts.

## 11. Incident states

- investigating.
- identified.
- monitoring.
- resolved.

## 12. Incident timeline

Timeline Append-style للأحداث المهمة.

لا يعاد كتابة تاريخ التحقيق.

## 13. Postmortem

للحوادث الكبيرة.

يمكن أن يحفظ كRecord أو Document Reference حسب
التنفيذ النهائي.

## 14. Postmortem content

- impact.
- timeline.
- detection.
- root/contributing causes.
- resolution.
- follow-up actions.

## 15. Correlation IDs

كل Business/Technical Operation المهمة يجب أن تكون
قابلة للربط عبر Correlation/Operation ID.

## 16. Error Reference

User-visible Error Reference لا تكشف معلومات داخلية.

Admin تستطيع Resolve إلى Correlation Context.

## 17. OpenTelemetry readiness

لا Full OTel requirement في V1.

لكن:

- correlation id.
- trace-ready metadata.
- structured logs.

لا تمنع Integration مستقبلًا.

## 18. Existing Audit Authority

Migration 057 `audit.audit_logs` هي foundation الحالية.

لا ننشئ Audit Log ثانية بدون سبب حاكم جديد.

## 19. Current Audit gap

Audit الحالية Well/Tenant-oriented.

Platform Admin تحتاج Global Read Projection محكومة
بPlatform Authority.

## 20. Audit Admin Read Model

تعرض:

- actor.
- action.
- entity.
- target context.
- time.
- result.
- reason.
- before/after summary.
- support/incident references.

## 21. Audit redaction

قبل كتابة/عرض payload:

Sensitive fields redacted.

Never persist secrets intentionally.

## 22. Audit access

Export/privileged audit access يمكن أن يولد Audit event.

## 23. Audit retention

Business audit وtechnical telemetry ليسا Policy واحدة.

Retention النهائية تحتاج:

- legal.
- privacy.
- operational.
- cost.

## 24. Configuration architecture

Platform Config ليست Generic key/value playground.

كل Setting لها:

- identifier.
- type.
- validation.
- default.
- scope.
- sensitivity.
- version semantics.

## 25. Configuration groups

V1:

- application versions.
- maintenance.
- support contacts.
- legal URLs.
- safe feature flags.

## 26. Config version

كل Change Set حساس ينتج Version ثابتة.

## 27. Config history

يحفظ:

- old.
- new.
- actor.
- reason.
- server time.
- result.

## 28. Rollback

Rollback تنشئ Version جديدة مشتقة من نسخة سابقة.

لا تمحو History.

## 29. Validation

Config apply يحتاج:

- type validation.
- value/range validation.
- compatibility validation where required.

## 30. Secrets boundary

Business Config لا تحتوي:

- service role.
- DB password.
- SMS secret.
- FCM private credential.
- infrastructure private keys.

## 31. Provider configured state

UI يمكن أن تعرض Boolean/Health State عن Provider.

لا تعرض Secret.

## 32. Feature flags

Feature Flag:

- UX/release tool.
- ليست Authorization authority.

Backend permissions لا تعتمد عليها وحدها.

## 33. Safe defaults

Client لديها Defaults آمنة عندما لا تستطيع قراءة Config.

## 34. Maintenance model

Maintenance هي Capability State وليست Global App Off switch.

## 35. Maintenance scopes

Target scopes يمكن أن تشمل:

- server.
- admin writes.
- activation.
- financial finalization.

الأسماء النهائية تحسم أثناء التنفيذ.

## 36. Offline preservation

Maintenance لا تلغي ق-89/ق-90.

Offline-safe Field Operations تظل محليًا متاحة.

## 37. Maintenance expiry

Emergency Maintenance يمكن أن تحتاج Expiry تلقائية.

## 38. App version model

يلزم Contract يعرف:

- current app version.
- recommended version.
- minimum supported version.
- compatibility state.

## 39. Required update rule

Required فقط لأسباب موثقة مثل:

- security.
- API incompatibility.
- data-integrity risk.

## 40. Offline update behavior

لا يمنع Local Safe Work بسبب عدم قدرة الجهاز Offline
على تنزيل إصدار جديد.

## 41. Release identity

Monitoring تربط الأحداث بـ:

- app version/build.
- backend release.
- migration version.
- config version.

## 42. Change timeline

يلزم View لآخر:

- deploy.
- migration.
- configuration.
- feature flag.

## 43. Dependency health

Provider health لا يستنتج من Error واحد.

تعرض:

- local connectivity evidence.
- provider status evidence when available.
- uncertainty explicitly.

## 44. Telemetry privacy

Telemetry تجمع الحد الأدنى الضروري.

Prefer internal identifiers.

## 45. Crash reporting

عند استخدام Crashlytics أو بديل:

- no passwords.
- no auth tokens.
- no unnecessary financial payload.
- no full phone as primary identifier.

## 46. Security monitoring

Admin Security Panel يمكن أن يعرض:

- MFA posture.
- sessions.
- failed admin authentication.
- privileged actions.
- security anomalies.

## 47. Backup visibility

Backup Status read-only عند وجود Reliable Provider Data.

## 48. Disaster recovery boundary

No ordinary:

- database dump button.
- restore production button.

Disaster Recovery لها Runbook منفصلة مستقبلًا.

## 49. Final navigation

PA V1 Sections:

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

## 50. Deferred

- public status page.
- SIEM product.
- full OTel rollout.
- experimentation platform.
- custom admin role hierarchy.

## 51. Tests — Monitoring

Required:

- correct overall state.
- error aggregation.
- stale state.
- alert dedup.
- alert grouping.
- incident linking.
- no false provider-down claim.
- symptom drill-down.

## 52. Tests — Audit

Required:

- non-admin denied.
- global admin projection correct.
- append-only source remains.
- secrets redacted.
- before/after correct.
- export access audited when required.

## 53. Tests — Configuration

Required:

- invalid type rejected.
- invalid range rejected.
- config version created.
- rollback preserves history.
- feature flag cannot grant permission.
- secrets absent.
- maintenance expiry.

## 54. Tests — Offline/version behavior

Required:

- maintenance does not break Offline-safe work.
- required update does not blindly erase local access.
- incompatible Online operations blocked clearly.
- stale config uses safe defaults.

## 55. Tests — Security/Privacy

Required:

- telemetry excludes secrets.
- internal account id preferred.
- admin MFA state visible correctly.
- sensitive endpoints stay trusted.
- provider credentials absent from client.

## 56. Definition of Done

PA-04 لا تعتبر Production Complete حتى:

- م-35 مغلقة.
- monitoring implemented.
- alerts implemented.
- incident flow implemented.
- audit projection implemented.
- redaction implemented.
- retention decided.
- configuration versioning implemented.
- rollback implemented.
- maintenance implemented.
- app version policy implemented.
- release tracking implemented.
- privacy controls implemented.
- permanent tests successful.

## 57. Platform Administration Design Completion

بعد ق-107:

PA-01..PA-04 مكتملة **تصميميًا فقط**.

لا تحول إلى Implemented دون أدلة Backend/Web/Security.
