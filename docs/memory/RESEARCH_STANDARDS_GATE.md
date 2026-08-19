# Research & Standards Gate — بوابة البحث والمعايير

**القرار الحاكم:** ق-104
**آخر تحديث:** 2026-08-19
**الحالة:** إلزامية ونافذة

## 1. الهدف

هذه البوابة تمنع اعتماد قرار مهم اعتمادًا على:

- رأي غير مدعوم.
- عادة شخصية.
- تجربة منتج واحد.
- نصيحة منتدى قديمة.
- إمكانية تقنية فقط.

القاعدة:

**القرار المهم يجب أن يكون مناسبًا للمشروع ومبنيًا على
أفضل دليل عملي متاح، لا على مجرد كونه ممكنًا.**

## 2. متى تطبق؟

تطبق قبل اعتماد قرار جوهري في:

- Security.
- Authentication.
- Authorization.
- Platform Administration.
- Financial UX.
- Financial Architecture.
- Offline/Sync.
- Monitoring/Observability.
- Accessibility.
- UX patterns ذات أثر كبير.
- Android platform behavior.
- Supabase/Auth/API behavior.
- Sensitive data.
- High-risk admin actions.
- Architecture choices ذات تكلفة رجوع مرتفعة.

لا يلزم Web Research لكل:

- تغيير نص صغير.
- تعديل تنسيق.
- قرار ثابت حسمه Source of Truth الداخلي.
- Recovery operation لا يغير قرار المنتج.

## 3. ترتيب الأدلة

الترتيب الإلزامي:

1. Source of Truth داخل المشروع.
2. Standards أو Guidance رسمية معترف بها.
3. Official Platform Documentation.
4. Mature Product Design/Operations Guidance.
5. Real-world user/practitioner feedback.
6. Project-specific fit and constraints.
7. Recommendation.

لا يسمح لمصدر منخفض السلطة أن ينسخ معيارًا رسميًا
دون سبب موثق.

## 4. Source of Truth أولًا

قبل البحث الخارجي:

- اقرأ القرار الحالي.
- اقرأ Architecture الحالية.
- اقرأ Migration/API عندما تحدد الواقع.
- اعرف ما هو Implemented وما هو Pending.
- اعرف إن كان التغيير سيحتاج Supersession.

البحث الخارجي لا يستبدل حقيقة المشروع.

## 5. Standards الرسمية

حسب المجال تستخدم مصادر مثل:

- NIST.
- OWASP.
- W3C / WCAG.
- Platform vendor official documentation.
- Android official documentation.
- PostgreSQL official documentation.
- Supabase official documentation.

## 6. Mature Products

يمكن الاستفادة من منتجات ناضجة مثل:

- Grafana.
- GitHub.
- Supabase Dashboard.
- Government Design Systems.
- established admin consoles.

لكن لا تنسخ UI حرفيًا.

نستخرج:

- pattern.
- rationale.
- usability lesson.
- failure mode.

ثم نلائمها للمشروع.

## 7. Real User Feedback

Forums وGitHub Discussions وتجارب المستخدمين تستخدم
لاكتشاف:

- friction.
- excessive clicks.
- navigation pain.
- confusing terminology.
- hidden filters.
- dashboard overload.
- operational failure modes.

هذه المصادر:

**Experiential Evidence**

وليست Standards Authority.

## 8. تصنيف أي توصية

كل توصية جوهرية تصنف عند الحاجة إلى:

### Standards-aligned

متوافقة مباشرة مع المعايير والمشروع.

### Adapted

الأصل قياسي لكن عدل لقيود المشروع.

يجب توثيق:

- ماذا عدلنا؟
- لماذا؟

### Exception

المشروع اختار عمدًا شيئًا يخالف الاتجاه القياسي.

يجب:

- قول ذلك صراحة.
- عدم تسميته Best Practice.
- توثيق السبب.
- توثيق الخطر.
- تحديد Trigger لإعادة المراجعة.

## 9. قيود مشروعنا عند الملاءمة

تقييم Project Fit يجب أن يراعي:

- اليمن.
- اتصال ضعيف أو متقطع.
- Android-first للميدان.
- Web/Desktop-first لإدارة المنصة.
- مشغلين بمستويات تقنية متفاوتة.
- Arabic RTL.
- English digits/date-time policy.
- العمل تحت الشمس.
- V1 يجب أن تبقى بسيطة.
- Offline operation أساسي.
- Backend هو authority النهائية.
- Supabase هو Auth/Data foundation الحالي.
- الأمن المالي والتاريخ غير القابل للمحو.

## 10. الأمن مقابل سهولة الاستخدام

لا تعني Security:

- إضافة Confirm في كل نقرة.
- MFA لكل فعل منخفض المخاطر.
- Password rules معقدة بلا فائدة.

ولا تعني Ease of Use:

- حذف Audit.
- كشف Secrets.
- تجاوز Authorization.
- تعديل سجل مالي مرحل مباشرة.

يبحث المشروع عن:

**أقل احتكاك يحقق مستوى الأمان المطلوب.**

## 11. تغيّر المصادر مع الزمن

أي قرار يعتمد على:

- Software platform.
- API.
- Security standard.
- browser behavior.
- Android behavior.
- current guidance.

يجب التحقق من المصدر الحالي وقت القرار.

لا تعتمد ذاكرة نموذج قديمة إذا كان المصدر قد يتغير.

## 12. سجل الأدلة

عند قرار مهم يحفظ ما يكفي لفهمه لاحقًا:

- source.
- accessed/reviewed date.
- what it supports.
- whether authoritative or experiential.
- decision impact.

لا يلزم نسخ المقال أو الوثيقة كاملة.

## 13. قاعدة تفويض الاختيار

إذا قال المالك بوضوح:

    اختر الأفضل لنا
    بدون الرجوع إلي

فالنموذج:

1. يطبق هذه البوابة.
2. يختار Standards-aligned option ما لم يوجد سبب مشروع
   موثق لاعتماد Adapted option.
3. لا يختار Exception بلا ضرورة حقيقية.
4. ينسخ قرارًا سابقًا إذا ثبت أنه أقل أمانًا أو أقل ملاءمة
   وكان المالك قد فوّض الاختيار.
5. يوثق سبب النسخ ومصدره.

## 14. Research Gate PASS

قبل اعتماد حزمة جوهرية منطبق عليها البحث يجب أن يمكن
الإجابة عن:

- ما الواقع الحالي؟
- ما المعيار؟
- ماذا تقول المنصة الرسمية؟
- ما الدروس العملية؟
- ما مخاطر الخيارات؟
- ما الأنسب للمشروع؟
- هل الاقتراح Standards-aligned أم Adapted أم Exception؟

علامة داخلية مقترحة:

    RESEARCH_STANDARDS_GATE=PASS

ثم فقط تنتقل الحزمة إلى الاعتماد والتوثيق.

## 15. العلاقة مع Documentation Gate

الترتيب:

    Research & Standards Gate
        ↓
    Decision / Adoption
        ↓
    Documentation Gate
        ↓
    Commit + Push
        ↓
    Next Topic

Research Gate لا تستبدل Documentation Gate.

## 16. Baseline sources reviewed — 2026-08-19

### NIST SP 800-63B

URL:

https://pages.nist.gov/800-63-4/sp800-63b.html

يدعم:

- modern password verifier requirements.
- salted hashing.
- password length guidance.
- no arbitrary composition rules.
- authentication assurance concepts.

Authority:

Official standard/guidance.

### OWASP Password Storage Cheat Sheet

URL:

https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html

يدعم:

- password hashing instead of reversible encryption
  in normal authentication systems.
- modern password storage practices.

Authority:

Security industry guidance.

### OWASP Authentication Cheat Sheet

URL:

https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html

يدعم:

- reauthentication for sensitive actions.
- MFA.
- secure password recovery.
- avoid unnecessary periodic password rotation.

Authority:

Security industry guidance.

### OWASP Multifactor Authentication Cheat Sheet

URL:

https://cheatsheetseries.owasp.org/cheatsheets/Multifactor_Authentication_Cheat_Sheet.html

يدعم:

- MFA for privileged/high-value accounts.
- additional verification for sensitive actions.

Authority:

Security industry guidance.

### OWASP Transaction Authorization Cheat Sheet

URL:

https://cheatsheetseries.owasp.org/cheatsheets/Transaction_Authorization_Cheat_Sheet.html

يدعم:

- confirm significant transaction data.
- sequential authorization flow.
- restart authorization if protected transaction data changes.

Authority:

Security industry guidance.

### OWASP Logging Cheat Sheet

URL:

https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html

يدعم:

- logging privileged administrative actions.
- not logging passwords, tokens, encryption keys or
  primary secrets.

Authority:

Security industry guidance.

### W3C WCAG 2.2

URL:

https://www.w3.org/TR/WCAG22/

يدعم:

- WCAG 2.2 AA.
- target size minimum.
- keyboard/focus behavior.
- status messages.
- accessible authentication.

Authority:

Web standard.

### Supabase Auth — Passwords

URL:

https://supabase.com/docs/guides/auth/passwords

يدعم:

- password-based auth.
- phone+password behavior.
- reset flows.
- phone-number risk considerations.

Authority:

Official platform documentation.

### Supabase Auth — MFA

URL:

https://supabase.com/docs/guides/auth/auth-mfa

يدعم:

- TOTP/phone MFA.
- AAL1/AAL2.
- mandatory MFA by application policy.

Authority:

Official platform documentation.

### Supabase API Keys

URL:

https://supabase.com/docs/guides/getting-started/api-keys

يدعم:

- elevated secret keys server-side only.
- client/server credential boundary.

Authority:

Official platform documentation.

### Supabase Auth Admin Update User

URL:

https://supabase.com/docs/reference/javascript/auth-admin-updateuserbyid

يدعم:

- Auth Admin changes are server-side operations.
- elevated credentials must not be exposed in browser.

Authority:

Official platform documentation.

### Grafana Dashboard Best Practices

URL:

https://grafana.com/docs/grafana/latest/visualizations/dashboards/build-dashboards/best-practices/

يدعم:

- dashboard should answer a question.
- reduce cognitive load.
- avoid unnecessary refresh.
- directed drill-down/navigation.
- careful aggregation.

Authority:

Mature product official guidance.

### Grafana Dashboard Troubleshooting

URL:

https://grafana.com/docs/grafana/latest/visualizations/dashboards/troubleshoot-dashboards/

يدعم:

- excessive refresh/query volume can overload dashboard/backend.

Authority:

Mature product official guidance.

### Grafana Navigation Feedback

URL:

https://github.com/grafana/grafana/discussions/58910

يدعم تجربياً:

- too many front-page elements create noise.
- extra clicks create context switching.
- filters/variables scrolling out of view creates repeated
  up/down navigation friction.

Authority:

Experiential user feedback only.

### GOV.UK Pagination

URL:

https://design-system.service.gov.uk/components/pagination/

يدعم:

- pagination for long result sets.
- filtering/sorting entire dataset.
- avoid infinite scroll where it harms accessibility/usability.

Authority:

Mature government design guidance.

### Google SRE — Monitoring Distributed Systems

URL:

https://sre.google/sre-book/monitoring-distributed-systems/

يدعم:

- symptom versus cause separation.
- monitoring should maximize signal and reduce noise.

Authority:

Mature operations guidance.

## 17. Definition of Done

هذه البوابة تعتبر نافذة عندما:

- يقرأها كل AI جديد.
- تظهر في README/Handoff.
- Documentation Gate تشير إليها.
- AI Collaboration Protocol يطبقها.
- القرارات الجوهرية المستقبلية تسجل Evidence عند الانطباق.
- Exceptions لا تختبئ تحت اسم Best Practice.

## 18. PA-03 Evidence Review — 2026-08-19

### Stripe Entitlements

Reviewed as a mature-product pattern for separating:

- commercial product/sale context.
- access/entitlement context.

Project adaptation:

Sale واحدة يمكن أن تنتج عدة Well Entitlements مستقلة.

لا Stripe dependency adopted.

### Stripe Idempotency

Reviewed for:

- retry-safe financial/admin API commands.
- avoiding duplicate effects after network uncertainty.

Project decision:

Sensitive PA-03 mutation تحتاج Stable Idempotency ID.

### Stripe Refund Object Pattern

Reviewed as evidence that financial correction can be
modeled as a linked new record rather than rewriting the
original transaction.

Project mapping:

ق-99 remains authoritative for reversal/correction.

### OWASP Transaction Authorization

Supports:

- clear significant transaction data.
- explicit authorization.
- invalidating authorization when protected values change.

Applied to:

- entitlement revoke.
- admin session correction.
- financial correction.
- accounting exceptional approval.

### OWASP Logging

Supports:

- logging privileged administrative actions.
- avoiding passwords/tokens/keys in logs.

### GitHub Sudo Mode

Reviewed as mature-product evidence for:

- recent reauthentication before sensitive actions.

Project mapping:

ق-104/ق-105 Step-up.

### GitHub Audit Log

Reviewed as mature-product evidence for:

- actor.
- action.
- target/context.
- event time.
- searchable privileged history.

### PA-03 classification

Standards-aligned:

- idempotency.
- audit.
- transaction confirmation.
- Step-up.
- immutable-history correction.
- online privileged mutations.

Adapted:

- one entitlement per purchased well.
- permanent manual V1 sale.
- platform-specific activation correction.

Rejected V1:

- SQL console.
- direct posted-finance edit.
- force reopen bypass.
- offline privileged write.
- infinite-scroll admin tables.

Result:

    PA03_RESEARCH_STANDARDS_GATE=PASS

## 19. PA-04 Evidence Review — 2026-08-19

### Google SRE — Monitoring Distributed Systems

يدعم:

- symptom versus cause.
- latency/errors/saturation/traffic-style health signals.
- actionable high-signal monitoring.

### Google SRE — On-call / Alerting

يدعم:

- actionable alerts.
- reducing alert noise.
- avoiding repeated unactionable paging.

### Google SRE — Postmortem Culture

يدعم:

- impact/timeline/root-cause/follow-up learning.

### Google SRE — Configuration Design

يدعم:

- limited configuration complexity.
- validation.
- versioning.
- rollback.
- change traceability.

### OWASP Logging

يدعم:

- privileged action logging.
- secret-safe logs.
- log-access protection.
- appropriate retention.

### OpenTelemetry

يدعم:

- correlation across logs/traces/metrics.
- Trace/Span-compatible context.

Project adaptation:

Full OTel rollout deferred.
Correlation readiness adopted.

### Supabase Monitoring

يدعم:

- Logs/Reports/Metrics as available platform signals.

Project rule:

لا نعتمد Provider-specific Metrics API كشرط معماري وحيد.

### Firebase Crashlytics

Reviewed as optional mature crash-reporting capability.

No dependency adopted merely by documentation.

### Firebase Remote Config

Reviewed as evidence for safe defaults/remote overrides.

Project decision:

Business Configuration remains Backend-owned in V1.

### Android In-App Updates

يدعم:

- Flexible.
- Immediate.

Project adaptation:

Immediate only for high-risk compatibility/security cases.

### PA-04 classification

Standards-aligned:

- actionable monitoring.
- alert dedup/grouping.
- incidents.
- postmortems.
- secret-safe audit.
- configuration versioning/rollback.

Adapted:

- scoped maintenance.
- Offline-safe version behavior.
- Backend-owned config.
- OTel-ready IDs without full rollout.

Deferred/rejected V1:

- custom SIEM.
- generic JSON config editor.
- global field-work kill switch.
- public status page.
- full OTel rollout.

Result:

    PA04_RESEARCH_STANDARDS_GATE=PASS

## 20. UX-17 Evidence Review — 2026-08-19

### Android Offline-first Architecture

URL:

https://developer.android.com/topic/architecture/data-layer/offline-first

Supports:

- local source for offline-first reads.
- explicit write-strategy classification.
- durable local writes for critical offline behavior.
- synchronization/reconciliation.

### Android Data Layer

URL:

https://developer.android.com/topic/architecture/data-layer

Supports:

- explicit source of truth.
- separation of data/business logic from UI.

### Android Accessibility

URL:

https://developer.android.com/guide/topics/ui/accessibility/apps

Supports:

- minimum 48×48dp touch targets.
- accessible semantic descriptions.

### Android Adaptive Navigation

URL:

https://developer.android.com/design/ui/mobile/guides/layout-and-content/layout-and-nav-patterns

Supports:

- navigation adapting to available window size.

### WCAG 2.2

URL:

https://www.w3.org/TR/WCAG22/

Supports:

- predictable navigation.
- financial/data error prevention.
- review/confirm/correct.
- focus/status/accessibility requirements.

### GOV.UK Confirmation Pattern

URL:

https://design-system.service.gov.uk/patterns/confirmation-pages/

Supports:

- explicit completion.
- reference when relevant.
- what happens next.

### ONS Error/Status Pattern

URL:

https://service-manual.ons.gov.uk/design-system/patterns/error-status-pages

Supports:

- clear problem explanation.
- next action.
- no technical jargon/user blame.

### Real User Feedback — Nextcloud Android

URLs:

https://github.com/nextcloud/android/issues/208
https://github.com/nextcloud/android/issues/3349

Observed:

- unclear sync icons/terminology.
- users could not tell offline/download/sync state.
- stale/out-of-sync state could be misinterpreted.

### Real User Feedback — Element X Android

URL:

https://github.com/element-hq/element-x-android/issues/5567

Observed:

- repeatedly appearing offline/status UI can be
  distracting and move page content.

### UX-17 project adaptation

Therefore:

- explicit Arabic sync text.
- connectivity separated from sync.
- stable status placement.
- local-save versus server-confirmation language.
- record-level state for critical records.
- no blocking refresh when valid local data exists.

Result:

    UX17_RESEARCH_STANDARDS_GATE=PASS

## 21. IMPLEMENTATION-01 Evidence Review — 2026-08-19

### Supabase Local Development / Migrations

Current official guidance supports:

- schema migration files.
- version-controlled schema evolution.
- ordered migration application.
- local verification before deployment.
- avoiding unmanaged production schema edits.

Project decision:

071–077 remain immutable.

New work begins 078+ and continues in coherent
domain-sized migrations.

### Android Offline-first

Current Android guidance supports:

- local source for offline-first reads.
- queued deferred writes/reads.
- WorkManager for persistent work.

Project decision:

Offline/Background Sync foundations precede production
critical irrigation flows.

### Project dependency analysis

Internal architecture shows:

- Auth/Identity/Entitlement are prerequisites for onboarding.
- Offline/Sync is prerequisite for field reliability.
- Session core is prerequisite for records/finance/reports.
- trusted Admin APIs are prerequisite for Admin Web.

Result:

    IMPLEMENTATION01_RESEARCH_STANDARDS_GATE=PASS
