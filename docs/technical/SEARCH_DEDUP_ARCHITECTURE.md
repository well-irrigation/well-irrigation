# Smart Lookup, Deduplication, and Live Session Amount Architecture

**آخر تحديث:** 2026-08-18
**القرار الحاكم:** ق-88
**الحالة:** تصميم تقني ملزم؛ بعض الأساس موجود والتنفيذ الكامل ما زال Pending
**أول Migration جديدة:** 085 أو أحدث

هذه الوثيقة لا تنشئ تنفيذًا بحد ذاتها.

هدفها منع ثلاثة أنواع من الأخطاء:

1. بناء بحث مختلف في كل شاشة.
2. إنشاء بيانات مكررة لأن الواجهة لم تعرض الموجود.
3. إنشاء حلول جديدة تتعارض مع جداول وإجراءات موجودة أصلًا.

---

## 1. حدود السلطة

إذا تعارضت هذه الوثيقة مع قرار مرقم أحدث في
`DECISIONS.md` فالقرار الأحدث يفوز.

حد Flutter يبقى:

    Flutter
        ↓
    Supabase Data API
        ↓
    api.*
        ↓
    Approved business procedures
        ↓
    Internal schemas

لا Direct DML.

---

## 2. الأساس الموجود الذي يجب إعادة استخدامه

### الأشخاص

موجود:

- `core.persons`.
- `core.person_contacts`.
- `core.person_aliases`.
- `core.normalize_arabic(text)`.
- `core.normalize_phone(text)`.
- `core.find_person_duplicates(...)`.
- `core.merge_persons(...)`.
- Trigram indexes للأسماء.
- `pg_trgm`.

لا ينشأ Person Search Model موازٍ.

### المزارع

موجود:

- `ops.farmer_profiles`.
- `ops.farmer_well_accounts`.
- `ops.create_farmer`.
- `api.create_farmer`.

`ops.create_farmer` يسمح حاليًا للمالك أو المشغل.

### الأرض

المصدر الحالي:

    ops.farms
        ↓
    farmer_well_account_id

Migration 075 تثبت أن Farm/Account/Well يجب أن تكون
متسقة.

`api.create_farm` موجود، لكن إجراء الأعمال الحالي
يقصر الإنشاء على owner.

### الجلسة

موجود:

- `api.start_irrigation_session`.
- `api.pause_irrigation_session`.
- `api.resume_irrigation_session`.
- `api.change_session_energy_source`.
- `api.complete_irrigation_session`.

وموجود نموذج `session_segments` للتسعير حسب المقاطع.

### الدفع

موجود:

- `api.record_payment`.

لكن بدء الجلسة والدفع عمليتان منفصلتان حاليًا.

---

## 3. Smart Lookup Component

يكون في Flutter مكوّن واحد قابل لإعادة الاستخدام.

المكوّن لا يعرف أسماء جداول PostgreSQL.

يستقبل مفهومًا مثل:

- entity type.
- well context.
- parent entity إذا وجد.
- current selection.
- permission to create.
- query text.

ويعيد:

- stable UUID.
- primary label.
- secondary disambiguation label.
- optional status.
- optional recent marker.
- create-new action عند السماح.

---

## 4. مراحل البحث

### Focus بدون كتابة

يعرض:

- recent choices.
- context-relevant choices.
- active choices only عندما يكون النشاط شرطًا.

### حرف واحد

يفلتر cache/local results سريعًا.

لا يرسل بالضرورة طلبًا خادميًا ثقيلًا لكل ضغطة.

### حرفان

يبدأ Prefix search.

### ثلاثة أحرف فأكثر

يجمع:

- exact normalized.
- prefix.
- alias.
- substring/word search عند الحاجة.
- trigram similarity.

### الهاتف

له مسار تطبيع منفصل عن النص.

---

## 5. Ranking

الترتيب الحاكم:

1. Exact canonical match.
2. Exact alias match.
3. Prefix canonical.
4. Prefix alias.
5. Word/contains.
6. Fuzzy similarity.
7. Recency/context tie-breaker.

لا تستخدم recency لتقديم نتيجة بعيدة على تطابق تام.

الترتيب داخل نفس المستوى Deterministic.

---

## 6. Entity Dedup Profile

أي كيان يسمح بـSearch + Create لا يعتبر جاهزًا قبل
تعريف هذا الملف المنطقي له:

- Canonical scope.
- Canonical identity fields.
- Normalization functions.
- Exact-match rule.
- Suspect-match rule.
- Disambiguation fields.
- Same-name-distinct rule.
- Database constraint or lock strategy.
- API pre-create check.
- Concurrent-create behavior.
- Merge/archive strategy إذا كانت مطلوبة.
- Offline/retry behavior.

هذه القاعدة تمنع فرض uniqueness غير صحيح على كيان
تجاري مختلف.

---

## 7. Farmer / Person Dedup Profile

### النطاق

هوية الشخص تعتمد على نموذج ق-84 وق-76.

### الموجود

`core.find_person_duplicates` موجود بالفعل.

### المطلوب

عند التنفيذ النهائي:

- exact identity لا تنشئ Person ثانيًا.
- exact identity يعاد استخدامها.
- suspect قوي لا ينشئ سجلًا بصمت.
- يعرض للمستخدم Candidate resolution.
- إذا كان «شخص مختلف» يجب وجود بيانات تمييز حقيقية.
- هاتف هوية التطبيق لا يمكن أن يكون نفسه للشخصين.

### ملاحظة phone

`core.person_contacts` جدول اتصال عام وتاريخي.

لا يوضع Unique شامل عليه دون تصميم هوية ق-84.

يجب تنفيذ Global Identity Phone في الطبقة الصحيحة
مع explicit profile↔person link.

---

## 8. Farm Dedup Profile

### النطاق

الأرض داخل:

- well.
- farmer_well_account.

### الاسم

يجب وجود normalized representation مناسب للبحث.

### Exact duplicate

إذا كان:

- نفس البئر.
- نفس Farmer Well Account.
- نفس الاسم المطبع.
- ولا يوجد distinguishing label حقيقي.

فلا يسمح بإنشاء نسخة ثانية بلا حسم.

### Same name / different farmer

مسموح.

العرض:

    أرض الوادي — محمد علي
    أرض الوادي — أحمد صالح

ولا يغير الاسم الأساسي المخزن.

### Same farmer / two real farms / same name

يسمح فقط ببيان تمييز مستقل مثل:

- الشرقية.
- الغربية.
- عند البيت.
- بجانب الطريق.

يجب أن تدخل قاعدة التفرد الجديدة التمييز في حسابها
دون خلطه عشوائيًا بالاسم.

### Permission gap

UX-08 يسمح للمشغل بإضافة أرض.

Backend الحالي owner-only.

يجب توسيع `ops.create_farm`/العقد المناسب في Migration
085+ مع اختبار صلاحيات دائم.

---

## 9. بقية الكيانات

لا تستخدم قاعدة الأرض تلقائيًا للمضخات أو الآبار
أو الشركاء.

قبل إضافة Create من Smart Lookup لكل كيان يجب تعريف
Dedup Profile خاص به.

أمثلة:

### Pump

يفحص نموذج المضخة الحالي في ق-81 قبل تحديد uniqueness.

### Well

لا يقرر duplicate من الاسم وحده؛ الاسم قد يتكرر.

### Partner / Operator

هوية الشخص لا تنسخ؛ يعاد استخدام Person/App Identity
ثم تنشأ العلاقة المناسبة بالبئر.

### Booking

ليس Master Data؛ لا يعامل ككيان اسم فريد.

---

## 10. Disambiguation

Primary label يبقى اسم الكيان الحقيقي.

Secondary label يشتق من العلاقات.

أمثلة:

    أرض الوادي
    محمد علي — بئر النور

أو:

    محمد علي
    771234567 — مزارع في بئر الوادي

لا نحفظ الجملة المركبة كاسم الكيان.

سبب ذلك:

إذا تغير اسم المزارع أو البئر، يتغير العرض تلقائيًا
دون تعديل اسم الأرض.

---

## 11. Save Once / Reuse Everywhere

بعد اختيار كيان موجود:

- يحفظ UUID في العملية.
- تعرض بياناته الحالية.
- تملأ العلاقات المعروفة تلقائيًا.

لا تنسخ `farmer_name` أو `farm_name` كنصوص أعمال
عندما يوجد FK رسمي يغطي العلاقة.

Search text نفسه لا يحفظ.

---

## 12. API Read Contracts

ق-82 أضاف `api.app_bootstrap`.

ق-88 يحتاج Read Contracts إضافية.

الأسماء النهائية تحسم عند Migration، لكن يجب أن تكون
محددة النوع، لا Dynamic Table Search.

أمثلة مفهومية:

- `api.search_farmers`.
- `api.search_farms`.
- `api.search_pumps`.
- `api.search_people`.

القواعد:

- SECURITY INVOKER.
- `anon` لا EXECUTE.
- access scope من auth context.
- no schema/table name parameter.
- query length limits.
- result limits.
- deterministic ranking.
- no sensitive over-disclosure.
- indexes suitable for actual query plan.
- permanent acceptance tests.

---

## 13. Create Contracts

إضافة الجديد لا تتم من Flutter Direct DML.

التدفق:

    Search
        ↓
    Show candidates
        ↓
    User explicitly chooses Add New
        ↓
    API pre-create validation
        ↓
    Business procedure
        ↓
    DB constraint / lock
        ↓
    Return canonical UUID
        ↓
    Select created entity automatically

أي failure يعيد المستخدم إلى نفس السياق دون فقد
الحقول الآمنة التي أدخلها.

---

## 14. Concurrency

التحقق قبل الضغط لا يكفي.

إذا أرسل جهازان Create للكيان نفسه تقريبًا في الوقت
نفسه:

- يجب أن تمنع قاعدة البيانات duplicate الحتمي.
- أو يستخدم lock/transaction مناسب.
- API يجب أن تعيد existing canonical record عندما
  يكون ذلك آمنًا.
- لا تعتمد النتيجة على من سبق بـ50ms فقط.

---

## 15. Offline Lookup

Local cache هدفه السرعة.

يمكنه تخزين:

- UUID.
- display labels.
- normalized search representation عند الحاجة.
- last used.
- sync metadata.

لكن:

- Server remains authoritative.
- result merge by UUID.
- stale local display may refresh.
- local record لا يصبح canonical فقط لأنه ظهر أولًا.

إنشاء Master Data جديد Offline لا يعد جاهزًا قبل
توفير idempotent command + conflict handling.

---

## 16. Live Session Amount

### Hourly pricing

إذا كان هناك hourly rate مثبت ومقطع billable جارٍ:

    elapsed billable seconds
        ↓
    current time charge

Flutter يمكن أن يعيد حساب العرض كل ثانية.

### Payment independent

المستحق لا يتوقف بسبب الدفع.

تعرض حقائق مستقلة:

- المستحق حتى الآن.
- المدفوع.
- المتبقي حتى الآن.

أو:

- رصيد مقدم.

### Pause

لا يزداد الجزء الزمني القابل للفوترة أثناء pause وفق
قواعد المقاطع.

### Energy change

الحساب الجاري:

    closed segment charges
        +
    current segment running estimate

لا يبدأ من الصفر.

### Fuel-dependent pricing

إذا كان model يحتاج كمية وقود فعلية لم تسجل بعد:

- لا نسمي الرقم الإجمالي «نهائي».
- نفصل time/operation known component.
- نظهر estimated component فقط إذا توجد قاعدة صريحة.
- final amount يبقى Backend result.

---

## 17. Start Session + Advance Payment Gap

العقود الحالية:

- start session.
- record payment.

منفصلة.

UX يسمح بإدخال دفعة عند البداية.

قبل التنفيذ الإنتاجي يجب اختيار حل يضمن:

- no duplicate session on retry.
- no duplicate payment on retry.
- no orphan advance payment.
- no session marked paid when payment failed.
- traceable association between advance and correct farmer/session context.
- safe retry after network interruption.

الحل قد يكون:

- atomic orchestration RPC.
- أو idempotent multi-step protocol بضمانات مكافئة.

لا يحسم اسم الدالة في هذه الوثيقة.

لكن **الضمان نفسه إلزامي**.

---

## 18. Required Migration 085+ Work

القائمة الحالية، ولا تعتبر نهائية إذا أضاف UX متطلبات
لاحقة:

1. Smart Lookup read contracts.
2. Search indexes المطلوبة حسب query plans.
3. Strong duplicate-resolution contract للأشخاص.
4. Global identity phone implementation وفق ق-84.
5. explicit profile↔person link وفق ق-84.
6. Farm normalized search fields/indexes عند الحاجة.
7. Farm duplicate constraint/transaction logic.
8. Farm distinguishing label model.
9. Operator create-farm authorization through API.
10. Safe return-and-select create flow.
11. Session+advance-payment coordination contract.
12. Read data needed for live amount counter.
13. Idempotency integration for new writes.
14. Audit events for new sensitive operations.
15. Permanent acceptance tests.
16. No edits to sealed migrations (ceiling: `AGENTS.md` §4).

---

## 19. Acceptance Test Contract

ق-88 لا يغلق تقنيًا قبل اختبار ما يلي.

### Search

- focus shows context choices.
- 2-char prefix returns expected records.
- 3+ fuzzy returns Arabic near-match.
- Arabic normalized variants match.
- phone normalized forms match.
- alias matches.
- exact result ranks above fuzzy.
- unauthorized well data never appears.
- anon cannot execute search contracts.

### Farmer dedup

- exact identity cannot create duplicate.
- exact identity returns/reuses canonical person.
- suspect match requires resolution.
- Q84 identity phone cannot represent two app identities.
- concurrent exact creates do not create two persons.

### Farm dedup

- same farmer + same canonical farm identity is blocked/reused.
- same farm name for different farmers is allowed.
- display differentiates equal names by farmer.
- same farmer can create two genuinely different same-name farms
  only with distinguishing data.
- concurrent duplicate farm creates are safe.

### Inline create

- operator can create farmer.
- operator can create farm only after new permission contract exists.
- created entity returns to start-session form selected.
- existing form context is preserved.

### Live amount

- hourly amount follows billable seconds.
- pause stops growth.
- resume restarts growth.
- energy change preserves cumulative total.
- payment does not change accrued amount.
- balance switches between remaining and advance correctly.
- no payment line when no payment exists.
- final backend result is source of truth.
- no float/double money math.

### Retry / Sync

- retry cannot create duplicate entity.
- retry cannot create duplicate payment.
- local/server search merge by UUID.
- offline unsupported write never pretends to be committed.

---

## 20. Implementation Gate

لا توصف أي شاشة بأنها Production Complete إذا كانت
تعتمد على ق-88 بينما واحد من متطلباتها الحرجة ما زال
Pending.

يجب أن تربط كل شاشة قبل تنفيذها بهذه الوثيقة وتحدد:

- search contracts المطلوبة.
- create contracts المطلوبة.
- dedup profiles المطلوبة.
- permissions.
- offline behavior.
- acceptance tests.

هذا هو حاجز «لا فجوات» لق-88.

## 21. ق-89 — Offline Create and Dedup

ق-89 يجعل Inline Create للمزارع والأرض جزءًا من
Offline Start Session عند الحاجة.

هذا لا يلغي ق-88.

التدفق عند Sync:

    local create command
        ↓
    server duplicate search/resolution
        ↓
    reuse canonical entity OR create once
        ↓
    persist local/server mapping
        ↓
    unblock dependent command

إذا وجد الخادم Person/Farm مطابقًا:

- لا ينشئ نسخة جديدة بسبب أن الهاتف كان Offline.
- يعيد canonical UUID.
- تحدث Dependencies المحلية.

إذا كان التشابه Suspect ولا يمكن حسمه آليًا:

- Command يصبح Conflict.
- لا تنشأ هوية ثانية بصمت.
- Session dependent تبقى محفوظة ولا تضيع.

كل Offline create يحتاج Command ID ثابتًا أيضًا.

## ق-98 / UX-13 — إعادة استخدام Smart Lookup

UX-13 لا تنشئ Search Engine جديدًا.

نفس قواعد ق-88 تستخدم في:

- farmer list/select.
- farm select.
- session history filters.
- booking filters.
- operator filters.

قواعد إضافية:

- inactive entities لا تظهر افتراضيًا للاختيار الجديد.
- لكنها تبقى قابلة للعرض في التاريخ.
- Search text لا ينشئ كيانًا.
- Merge يحفظ جميع الروابط التاريخية.

## ق-110 — Explicit Profile ↔ Person Foundation

W1-01 تنشئ Migration 078 لتطبيق prerequisite المذكورة
سابقًا في هذه الوثيقة:

`explicit profile↔person link`.

الرابط:

- Tenant-aware.
- explicit.
- fail-closed.
- لا يستخدم Name/Phone guessing.
- لا يعيد استخدام Search result كIdentity تلقائيًا.

الحالة:

Migration مكتوبة وتنتظر Owner Verification.

م-16 تبقى مفتوحة حتى Migration لاحقة تستخدم الرابط في
Farmer self-scope RLS.
