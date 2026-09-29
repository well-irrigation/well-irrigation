# توافق المهارات بين ZCode وClaude Code

**الدور:** فهرس إرشادي فقط. لا ينسخ قرارات المشروع ولا يتغلب على
`AGENTS.md` أو `docs/PROJECT_MAP.md`.

## القاعدة

كل مهارة موجودة تحت `.agents/skills/` تبقى محفوظة باسمها ومحتواها للوكيل
الذي يستطيع تشغيلها. عدم توفر أداة في ZCode لا يبرر حذف مهارة Claude Code
أو تعديلها خلسة، والعكس صحيح. يقرأ كل وكيل قسم `compatibility` إن وُجد،
ويستخدم fallback صريحًا بدل ادعاء تنفيذ أداة غير متاحة.

## المهارات المشتركة

هذه تعتمد أساسًا على قراءة الملفات أو كتابة الكود ويمكن لـZCode وClaude
Code استخدامها بأدوات مكافئة، مع بقاء `AGENTS.md` حاكمًا:

- مهارات Dart وFlutter للاختبارات والتحليل والمعمارية والتخطيط المتجاوب.
- `well-android-ui` و`m3-expressive` و`arabic-financial-ui`.
- `well-conformance-gate` و`offline-sync-auditor` و`owasp-security`.
- مهارات Supabase بوصفها منهجًا؛ اختبار الشبكة يحتاج تفويضًا، وأوامر
  القاعدة والسحابة ينفذها المالك في هذا المشروع.
- المهارات العشر الجديدة المذكورة أدناه.

## مهارات محفوظة لـClaude Code أو claude-mem

لا تُحذف ولا تُعاد كتابتها لمجرد أن أدواتها ليست ظاهرة في ZCode:

- `cloud-sync`
- `how-it-works`
- `knowledge-agent`
- `mem-search`
- `mode-creator`
- `timeline-report`
- `weekly-digests`
- `task-observer`

إذا لم تتوفر أدوات `claude-mem`، يستخدم ZCode ذاكرته الملفية وفق عقد
الجلسة و`zcode-project-memory-governance`، ولا يدعي أنه نفذ بحث
`claude-mem`.

## مهارات تعتمد على وكلاء فرعيين

هذه تبقى متاحة لـClaude Code، لكن `AGENTS.md` يمنع الوكلاء الفرعيين في هذا
المشروع إلا بطلب صريح من المالك:

- `code-review`
- `do`
- `make-plan`
- `pathfinder`
- `standup`

في ZCode يُستخدم مسار الوكيل الواحد أو المهارة الجديدة
`well-secure-code-review`. لا تُعدّل المهارات الأصلية لتجاوز هذا الحد.

## إضافات ZCode الخارجية

قد يحمّل ZCode مهارات plugins خارج `.agents/skills/` مثل:

- `android-dev` لأدوات Android Emulator.
- `control-browser` و`web-gui-tester`.
- مهارات المستندات `docx` و`pdf` و`pptx` و`xlsx`.

هذه إضافات للبيئة وليست بدائل لمهارات Claude Code، ولا ينبغي نسخها إلى
المستودع أو افتراض توفرها في وكيل آخر. المهارات الداخلية الجديدة توفر
fallback يدويًا أو بأدوات مكافئة.

## المهارات الجديدة المشتركة

1. `well-secure-code-review`
2. `flutter-mobile-security-masvs`
3. `well-db-migration-review`
4. `well-financial-property-tests`
5. `well-device-acceptance`
6. `flutter-accessibility-audit`
7. `flutter-visual-regression`
8. `mobile-supply-chain-security`
9. `well-performance-profile`
10. `zcode-project-memory-governance`

كل واحدة:

- داخلية ومخصصة لقيود المشروع.
- لا تجعل الوكلاء الفرعيين شرطًا.
- تفصل بين أفعال الوكيل وأوامر المالك.
- تحتوي بوابة تحقق قبل التسليم.
- تحتوي `evals/evals.json` لاختبار السلوك وحدود الأمان.

## قرار الأداة عند التعارض

1. طبّق `AGENTS.md` وتعليمات النظام الأعلى.
2. استخدم مهارة المشروع الأكثر تخصيصًا للمهمة.
3. استدعِ المهارة العامة مرجعًا مساعدًا إذا لم تتعارض.
4. إذا احتاجت المهارة أداة غير متاحة، أعلن القيد واستخدم fallback موثقًا.
5. لا تحذف أو تحرّف مهارة بيئة أخرى لجعل القائمة تبدو متوافقة.
