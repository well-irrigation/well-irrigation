
**مشروع:** إدارة البئر والسقي
**حالة الوثيقة:** مرجعية منقّحة — الإصدار 2.0
**تاريخ التنقيح:** 2026-08-12
**مصدر التنقيح:** 47 قرارًا موثّقًا في `memory/DECISIONS.md`

> ⚠️ **اقرأ هذا أولًا**
>
> هذه الوثيقة جزء من أربع وثائق كانت مدموجة في ملف واحد، وقد فُصلت.
>
> عند أي تعارض بين هذه الوثيقة وملف `memory/DECISIONS.md`، **سجل القرارات هو الحاكم**.
>
> المقاطع المعلّمة بـ ❌ ملغاة ولا يجوز البناء عليها.
> المقاطع المعلّمة بـ ➕ مضافة بقرار لاحق.

---
### الأقسام المعدّلة في هذه الوثيقة

* **17.3** التقريب إلى الربع الأعلى — ❌ ملغى (ق-12).
* **17.4** التقريب في الجلسة المختلطة — ❌ ملغى (ق-12). وهذا يحسم التناقض رقم 1.
* **18.6** كسور الريال — أُعيدت كتابته بالكامل (ق-14 وق-15).
* **13.3** التحقق من النسب — صار = 100% حتمًا لا <= 100% (ق-03).
* **جداول الأسعار** price_schedules و price_rules — ❌ ملغاة (ق-18).
* **§46 و §49** القرارات المفتوحة الخمسة — حُسمت كلها؛ انظر سجل القرارات.

---

# وثيقة تصميم قاعدة البيانات والمحرك المالي لمنصة إدارة الآبار

**الإصدار:** 1.0
**الحالة:** تصميم معماري مرجعي
**قاعدة البيانات المركزية المقترحة:** PostgreSQL
**قاعدة الهاتف:** SQLite عبر PowerSync
**العملة الأولى:** الريال اليمني
**المنطقة الزمنية الافتراضية:** Asia/Aden
**قاعدة الأرقام:** الأرقام الإنجليزية دائمًا `0-9`
**طريقة التشغيل:** Offline-First
**نوع النظام المالي:** دفتر مزدوج مبسط للمستخدم، كامل داخليًا

---

# 1. الهدف من التصميم

يجب أن تستطيع قاعدة البيانات والمحرك المالي تمثيل الواقع الكامل للبئر، بما في ذلك:

* العميل الذي يمتلك حساب المنصة.
* بئر واحد أو عدة آبار.
* موقع كل بئر.
* الملاك والشركاء ونسبهم المتغيرة تاريخيًا.
* المشغلون والمحاسبون والمديرون.
* المزارعون.
* تعدد الأراضي والمواضع الزراعية للمزارع الواحد.
* الحجوزات المستقبلية.
* جلسات السقي الفعلية.
* التشغيل بالطاقة الشمسية.
* التشغيل بالديزل.
* الجلسة المختلطة.
* التوقفات والأعطال.
* مخزون ديزل البئر.
* رصيد ديزل كل مزارع.
* الفواتير.
* الدفع الكامل والجزئي والمقدم.
* الديون السابقة والجديدة.
* المصروفات.
* الصناديق والنوبات.
* رواتب المشغلين.
* مستحقات الشركاء.
* خصم سقي الشريك من أرباحه.
* الإقفال المالي.
* توزيع الأموال المحصلة.
* سجل التدقيق.
* العمل دون إنترنت والمزامنة.

هذا يعكس طبيعة المشروع الواردة في الدراسة: وجود تشغيل شمسي وديزل أو الجمع بينهما، ووجود عدة ملاك ومشغلين بعيدين عن الملاك. كما أن المنظومة يجب أن تفصل بين أدوات المشغل اليومية وتقارير المالك والشفافية المالية.

---

# 2. المبادئ المعمارية الأساسية

## 2.1 قاعدة بيانات واحدة موحدة

يجب ألا توجد قاعدة مستقلة للمشغل وقاعدة أخرى للمالك.

جميع المستخدمين يتعاملون مع البيانات نفسها، لكن كل مستخدم يرى ما تسمح به صلاحياته.

```text
قاعدة البيانات المركزية
├── بيانات التشغيل
├── البيانات المالية
├── الشركاء
├── المزارعون
├── التقارير
└── الصلاحيات
```

---

## 2.2 كل عميل معزول عن العملاء الآخرين

لأن التطبيق منتج تجاري عام، يجب أن يحتوي كل سجل تقريبًا على:

```text
tenant_id
```

وهو معرف العميل أو المؤسسة المالكة للحساب.

مثال:

```text
العميل A
├── بئر الوادي
└── بئر القاع

العميل B
├── بئر السائلة
└── بئر الروضة
```

لا يستطيع العميل A رؤية أي بيانات تخص العميل B.

---

## 2.3 استخدام معرفات ثابتة وغير قابلة للتغيير

كل سجل رئيسي يحصل على معرف عالمي ثابت من نوع UUID.

مثال:

```text
id = 9c81c5c1-...
```

يستخدم النظام أيضًا رقم عرض بشريًا، مثل:

```text
F-000142   مزارع
W-000012   بئر
IR-000251  جلسة ري
INV-000384 فاتورة
PAY-000592 دفعة
```

رقم العرض يسهل القراءة، لكن العلاقات الداخلية تعتمد على UUID.

### سبب استخدام UUID

الهاتف قد ينشئ العملية دون إنترنت. لذلك يجب أن يستطيع إنشاء معرف فريد قبل الاتصال بالخادم، دون انتظار رقم تسلسلي من الخادم.

---

## 2.4 عدم الاعتماد على الاسم أو الهاتف كمعرف

اسم المزارع ورقم هاتفه بيانات قابلة للتغيير أو التكرار.

المعرف الحقيقي هو:

```text
person_id
```

أما الهاتف والاسم فيستخدمان للبحث ومنع التكرار.

---

## 2.5 عدم الحذف النهائي للعمليات المالية

أي دفعة أو مصروف أو فاتورة أو توزيع أرباح:

* لا يحذف نهائيًا.
* يمكن إلغاؤه.
* يمكن عكسه.
* يمكن تصحيحه.
* يبقى السجل الأصلي محفوظًا.

---

## 2.6 حفظ التاريخ الكامل للتغييرات

البيانات التي تتغير مع الوقت يجب ألا يستبدل سجلها القديم، مثل:

* أسعار الري.
* نسب الشركاء.
* سياسات سقي الشركاء.
* صلاحيات المستخدمين.
* قواعد اعتماد المصروفات.

يجب إنشاء سجل جديد بتاريخ بداية جديد.

---

## 2.7 الحسابات لا تعتمد على أرقام محفوظة يدويًا

لا يكون هناك حقل يدوي موثوق باسم:

```text
farmer.current_debt
partner.current_profit
cashbox.current_balance
```

لأن هذه الأرقام قد تصبح غير متطابقة مع العمليات.

المصدر الحقيقي هو:

* الفواتير.
* الدفعات.
* القيود المالية.
* المصروفات.
* التوزيعات.

يمكن إنشاء أرصدة محسوبة ومخزنة مؤقتًا لسرعة العرض، لكنها ليست المصدر النهائي.

---

# 3. طريقة حفظ المبالغ والكميات

## 3.1 المبالغ المالية

الريال اليمني لا يحتاج كسورًا عادةً، لذلك يحفظ كعدد صحيح من نوع:

```text
BIGINT
```

مثال:

```text
15000
```

ولا يخزن كـ:

```text
15000.00
```

ولا يستخدم نوع `float` إطلاقًا في الحسابات المالية.

---

## 3.2 دعم عملات مستقبلية

كل عملية مالية تحتوي على:

```text
currency_code = YER
amount_minor = 15000
```

رغم أن العملة الوحيدة الظاهرة في النسخة الأولى هي الريال اليمني، هذا يمنع إعادة تصميم قاعدة البيانات إذا أضيفت عملات لاحقًا.

---

## 3.3 كمية الوقود

يتم التخزين داخليًا بالملليلتر:

```text
1 لتر = 1000 ملليلتر
1 جالون محلي = 20000 ملليلتر
```

مثال:

```text
20.5 لتر = 20500 ملليلتر
```

هذا يسمح بتسجيل كميات دقيقة دون أخطاء الكسور العشرية.

---

## 3.4 الوقت

يتم حفظ:

* تاريخ ووقت البداية الكامل.
* تاريخ ووقت النهاية الكامل.
* مدة التشغيل الفعلية بالثواني أو الدقائق.
* مدة الفوترة بالدقائق.

مثال:

```text
actual_duration_minutes = 122
billable_duration_minutes = 135
```

حيث `122` دقيقة يتم تقريبها إلى `135` دقيقة، أي `2:15`.

---

## 3.5 النسب

النسب تحفظ بدقة ثابتة، مثل:

```text
25.5000%
```

باستخدام نوع رقمي دقيق، وليس `float`.

---

# 4. الحقول المشتركة في الجداول

معظم الجداول تحتوي على:

```text
id
tenant_id
created_at
created_by
updated_at
updated_by
archived_at
version
origin_device_id
client_created_at
server_received_at
```

## وظيفة الحقول

### `id`

المعرف العالمي الثابت.

### `tenant_id`

العميل الذي يملك السجل.

### `created_at`

وقت إنشاء السجل المعتمد على الخادم.

### `client_created_at`

الوقت الذي سجله الهاتف عند العمل دون إنترنت.

### `server_received_at`

وقت استلام الخادم للعملية.

### `version`

رقم نسخة السجل، يستخدم لكشف التعارضات.

### `origin_device_id`

الجهاز الذي أنشأ العملية.

### `archived_at`

أرشفة السجل دون حذفه.

---

# 5. التقسيم العام لقاعدة البيانات

```text
1. حسابات العملاء والاشتراكات
2. الأشخاص والمستخدمون والصلاحيات
3. الآبار والمواقع والمعدات
4. المزارعون والأراضي
5. الشركاء والملكية
6. الأسعار وسياسات الحساب
7. الحجوزات والجلسات
8. الديزل والمخزون
9. الفواتير والدفعات
10. دفتر الحسابات والقيود
11. الصناديق والنوبات
12. المصروفات والرواتب
13. الإقفال وتوزيع الأرباح
14. الإشعارات والمرفقات
15. التدقيق والمزامنة
```

---

# 6. حسابات العملاء والاشتراكات

## 6.1 جدول العملاء `tenants`

يمثل كل عميل أو مؤسسة مشتركة في المنصة.

الحقول الأساسية:

```text
id
display_code
name
legal_name
owner_person_id
status
default_currency
default_timezone
trial_started_at
trial_ends_at
created_at
```

الحالات:

```text
trial
active
past_due
suspended
cancelled
archived
```

---

## 6.2 جدول الخطط `subscription_plans`

يحتوي على:

```text
id
name
max_wells
max_users
max_storage
features_json
monthly_price
annual_price
is_active
```

---

## 6.3 جدول اشتراكات العملاء `subscriptions`

```text
id
tenant_id
plan_id
status
started_at
trial_ends_at
current_period_start
current_period_end
billing_source
external_subscription_id
cancelled_at
```

مصادر الاشتراك:

```text
google_play
manual
activation_code
reseller
direct_invoice
```

---

# 7. بطاقة الشخص الموحدة

## 7.1 جدول الأشخاص `persons`

هذا من أهم الجداول.

```text
id
tenant_id
display_code
full_name
preferred_name
father_name
family_name
nickname
gender
notes
status
created_at
```

لا نجعل كل أجزاء الاسم إلزامية؛ لأن الأسماء المحلية قد تسجل بطرق مختلفة.

---

## 7.2 وسائل التواصل `person_contacts`

يمكن للشخص امتلاك أكثر من رقم.

```text
id
person_id
contact_type
value
is_primary
belongs_to_person
contact_owner_name
verified_at
```

أنواع التواصل:

```text
mobile
whatsapp
landline
email
other
```

الحقل:

```text
belongs_to_person
```

يبين هل الرقم يخص المزارع نفسه أو قريبًا له.

---

## 7.3 الأسماء البديلة `person_aliases`

يساعد في البحث ومنع التكرار.

```text
id
person_id
alias
alias_type
```

مثال:

```text
الاسم الكامل: أحمد محمد صالح
الاسم المتعارف عليه: أحمد الوادي
```

---

## 7.4 فحص التكرار

قبل إنشاء شخص جديد، ينفذ النظام بحثًا حسب:

* الهاتف المطابق.
* الاسم الكامل المطابق.
* الاسم القريب.
* اسم الأب.
* القرية.
* اللقب.
* الأسماء البديلة.

ويعطي كل نتيجة درجة تشابه.

مثال:

```text
95% احتمال تطابق
75% احتمال تطابق
40% احتمال تطابق
```

النظام لا يدمج تلقائيًا.

---

## 7.5 طلبات الدمج `person_merge_requests`

```text
id
tenant_id
primary_person_id
duplicate_person_id
requested_by
status
reviewed_by
reviewed_at
reason
```

بعد الدمج:

* يبقى معرف الشخص الرئيسي.
* تنقل العلاقات.
* يؤرشف السجل المكرر.
* يسجل كل شيء في سجل التدقيق.

---

# 8. المستخدمون وتسجيل الدخول

## 8.1 جدول المستخدمين `users`

يربط حساب تسجيل الدخول ببطاقة الشخص.

```text
id
tenant_id
person_id
auth_user_id
username
status
last_login_at
```

قد يكون الشخص موجودًا دون حساب دخول، مثل المزارع في النسخة الأولى.

---

## 8.2 الأجهزة `user_devices`

```text
id
user_id
device_uuid
device_name
platform
app_version
last_seen_at
is_trusted
revoked_at
```

---

## 8.3 الأدوار `roles`

أمثلة:

```text
tenant_owner
well_manager
operator
accountant
partner
viewer
```

---

## 8.4 الصلاحيات `permissions`

أمثلة:

```text
farmer.create
farmer.merge
session.start
session.complete
payment.create
expense.approve
price.change
ownership.change
period.close
distribution.approve
audit.view
```

---

## 8.5 عضوية المستخدم في البئر `well_user_roles`

```text
id
tenant_id
well_id
user_id
role_id
starts_at
ends_at
is_active
```

يمكن أن يمتلك المستخدم أكثر من دور.

---

# 9. الآبار والمواقع

## 9.1 جدول الآبار `wells`

```text
id
tenant_id
display_code
name
description
status
timezone
default_currency
location_id
commissioned_at
settings_json
created_at
```

الحالات:

```text
setup
active
inactive
maintenance
suspended
archived
```

---

## 9.2 المواقع `locations`

```text
id
country
governorate
district
subdistrict
village
valley
local_area
access_description
latitude
longitude
```

---

## 9.3 إعدادات البئر `well_settings`

بدل وضع جميع الإعدادات داخل حقل واحد غير منظم، يجب فصل الإعدادات المهمة.

أمثلة:

```text
billing_rounding_mode = ceil_quarter_hour
default_partner_policy = deduct_from_profit
phone_required = false
gps_required = false
allow_negative_fuel = false
default_distribution_cycle = monthly
```

---

# 10. المضخات والخطوط والخزانات

## 10.1 المضخات `pumps`

```text
id
well_id
display_code
name
pump_type
power_rating
status
estimated_fuel_ml_per_hour
estimated_water_flow
installed_at
notes
```

---

## 10.2 خطوط المياه `water_lines`

```text
id
well_id
display_code
name
status
allows_parallel_use
notes
```

---

## 10.3 علاقة المضخة بالخط `pump_line_links`

```text
id
pump_id
water_line_id
is_primary
starts_at
ends_at
```

---

## 10.4 قواعد التزامن `resource_concurrency_rules`

تحدد هل يمكن تشغيل أكثر من جلسة.

```text
id
well_id
resource_type
resource_id
max_parallel_sessions
rule_status
```

القيمة الافتراضية:

```text
max_parallel_sessions = 1
```

---

## 10.5 خزانات الديزل `fuel_tanks`

```text
id
well_id
display_code
name
capacity_ml
status
measurement_method
```

طرق القياس:

```text
manual
dipstick
meter
estimated
```

---

# 11. المزارعون

## 11.1 ملف المزارع `farmer_profiles`

يمثل كون الشخص مزارعًا.

```text
id
tenant_id
person_id
status
general_notes
created_at
```

الشخص نفسه لا يتكرر إذا كان شريكًا ومزارعًا.

---

## 11.2 علاقة المزارع بالبئر `farmer_well_accounts`

لأن المزارع قد يتعامل مع أكثر من بئر.

```text
id
tenant_id
farmer_profile_id
well_id
customer_code
status
opening_balance_status
credit_limit
notes
```

يمكن أن يكون للمزارع كشف مستقل في كل بئر.

---

# 12. الأراضي والمواضع الزراعية

## 12.1 جدول الأراضي `farms`

```text
id
tenant_id
display_code
name
local_name
location_id
area_value
area_unit
current_crop
status
notes
```

---

## 12.2 علاقة الشخص بالأرض `farm_participants`

بدل ربط الأرض بمزارع واحد فقط، ندعم حالات مستقبلية مثل:

* مالك.
* مستأجر.
* مدير.
* مستخدم.

```text
id
farm_id
person_id
relationship_type
starts_at
ends_at
is_primary
```

أنواع العلاقة:

```text
owner
tenant
manager
beneficiary
other
```

---

## 12.3 علاقة الأرض بالبئر `farm_well_links`

```text
id
farm_id
well_id
preferred_water_line_id
status
notes
```

---

## 12.4 منع تكرار الأرض

قبل الإضافة، يبحث النظام في:

* الاسم.
* الاسم المحلي.
* المالك.
* القرية.
* الوادي.
* الإحداثيات.

ويظهر تحذيرًا، دون منع نهائي.

---

# 13. الشركاء والملكية

## 13.1 علاقة الشريك بالبئر `well_partners`

```text
id
well_id
person_id
status
joined_at
left_at
profit_payment_method
notes
```

---

## 13.2 إصدارات نسب الملكية `ownership_share_versions`

```text
id
well_id
partner_id
ownership_percentage
profit_percentage
effective_from
effective_to
approved_by
approval_reference
```

لا تعدل النسبة القديمة.

عند تغيير النسبة:

1. يغلق السجل القديم.
2. ينشأ سجل جديد.
3. يسجل تاريخ البداية.
4. يحفظ المعتمد.

---

## 13.3 التحقق من النسب

لكل تاريخ، يجب:

```text
مجموع نسب الأرباح <= 100%
```

ولا يسمح بالتوزيع النهائي إلا إذا:

```text
مجموع نسب الأرباح = 100%
```

أو وجدت قاعدة معتمدة للنسبة غير الموزعة.

---

## 13.4 سياسات سقي الشركاء `partner_irrigation_policies`

```text
id
well_id
partner_id
policy_type
effective_from
effective_to
free_minutes_per_cycle
special_solar_hour_price
special_diesel_hour_price
deduct_from_profit
charge_fuel_only
charge_operation_only
settings_json
approved_by
```

أنواع السياسة:

```text
normal_customer
deduct_from_profit
free_hours
special_price
operating_cost_only
fuel_only
ownership_entitlement
custom
```

السياسة الافتراضية:

```text
deduct_from_profit
```

---

# 14. نظام الأسعار

## 14.1 جداول الأسعار `price_schedules`

```text
id
well_id
name
status
effective_from
effective_to
approved_by
reason
```

---

## 14.2 قواعد الأسعار `price_rules`

```text
id
price_schedule_id
energy_source
diesel_pricing_model
hourly_rate
operation_hourly_rate
fuel_price_per_liter
rounding_rule
minimum_billable_minutes
```

مصادر الطاقة:

```text
solar
well_diesel
farmer_diesel
```

نماذج الديزل:

```text
inclusive_hourly
operation_plus_fuel
```

---

## 14.3 لقطة السعر داخل الجلسة

عند بدء الجلسة، لا نعتمد لاحقًا على السعر الحالي فقط.

يجب حفظ نسخة السعر المستخدم داخل الجلسة:

```text
applied_price_rule_id
applied_hourly_rate
applied_fuel_price
applied_rounding_rule
```

بهذا لا تتغير الجلسة القديمة عند تعديل الأسعار.

---

# 15. الحجوزات

## 15.1 جدول الحجوزات `irrigation_bookings`

```text
id
tenant_id
well_id
farmer_well_account_id
farm_id
pump_id
water_line_id
scheduled_start
scheduled_end
expected_duration_minutes
expected_energy_source
status
priority
notes
created_by
```

الحالات:

```text
draft
pending
confirmed
waiting
ready
started
completed
postponed
cancelled
no_show
```

---

## 15.2 تاريخ حالات الحجز `booking_status_history`

```text
id
booking_id
old_status
new_status
changed_at
changed_by
reason
```

---

## 15.3 تبديل الأدوار

عند تبديل دورين، لا تعدل المواعيد بصمت.

يسجل النظام:

```text
booking_swap_id
first_booking_id
second_booking_id
requested_by
approved_by
reason
created_at
```

---

# 16. جلسات السقي

## 16.1 جدول الجلسات `irrigation_sessions`

```text
id
tenant_id
display_code
well_id
booking_id
farmer_well_account_id
farm_id
pump_id
water_line_id
operator_user_id
status
actual_started_at
actual_ended_at
actual_duration_minutes
billable_duration_minutes
billing_status
invoice_id
notes
```

الحالات:

```text
draft
running
paused
completed
pending_review
approved
cancelled
corrected
```

---

## 16.2 مقاطع الجلسة `session_segments`

كل فترة متصلة تسجل كمقطع.

```text
id
session_id
sequence_number
segment_type
started_at
ended_at
actual_minutes
billable_minutes
energy_source
fuel_source
fuel_owner_person_id
fuel_actual_ml
fuel_estimated_ml
is_billable
stop_reason_id
applied_price_rule_id
calculated_amount
```

أنواع المقطع:

```text
solar_run
well_diesel_run
farmer_diesel_run
billable_stop
non_billable_stop
breakdown
operator_pause
farmer_requested_pause
source_change_pause
```

---

## 16.3 قواعد المقاطع

يجب أن:

* تكون داخل زمن الجلسة.
* لا تتداخل.
* يكون ترتيبها صحيحًا.
* لا توجد فجوات غير مفسرة.
* لا يكون وقت النهاية قبل البداية.
* لا يبقى مقطعان مفتوحان معًا للمورد نفسه.

---

# 17. حساب الوقت

## 17.1 الزمن الفعلي

```text
actual_minutes =
ended_at - started_at
```

## 17.2 الزمن القابل للفوترة

```text
billable_raw_minutes =
مجموع دقائق المقاطع التي تحمل is_billable = true
```

## 17.3 الاحتساب الدقيق — لا تقريب

> ❌ **أُلغي قسم «التقريب إلى الربع الأعلى» بالقرار ق-12.**

لا يوجد أي تقريب للوقت. الزمن يُقاس ويُحتسب **بالثانية**.

```text
billable_seconds =
مجموع ثواني المقاطع التي تحمل is_billable = true
```

أمثلة (القاعدة الجديدة):

```text
60 ثانية   → 60 ثانية
900 ثانية  → 900 ثانية
7320 ثانية → 7320 ثانية
```

العرض للمستخدم بصيغة ساعات ودقائق، والتخزين والحساب بالثانية.

---

## 17.4 الجلسة المختلطة — لا نطاق تقريب

> ❌ **أُلغي قسم «التقريب في الجلسة المختلطة» بالقرار ق-12.**

السؤال القديم (هل نقرّب كل مقطع أم كل مصدر أم الجلسة كاملة؟) **سقط تمامًا**، لأنه لم يعد هناك تقريب أصلًا.

تُجمع ثواني كل مصدر طاقة على حدة، بلا أي معالجة إضافية.

مثال بالأرقام الحقيقية:

```text
شمس: 62 دقيقة → 62 دقيقة  (كانت 75 بالقاعدة الملغاة)
ديزل: 31 دقيقة → 31 دقيقة  (كانت 45 بالقاعدة الملغاة)
الإجمالي: 93 دقيقة            (كان 120 بالقاعدة الملغاة)
```

الفارق 27 دقيقة في جلسة واحدة، كلها لصالح المزارع.

❌ الحقل **rounding_scope** محذوف من إعدادات البئر.

---

# 18. حساب قيمة الجلسة

## 18.1 الشمس

```text
solar_amount =
solar_billable_minutes ÷ 60 × solar_hourly_rate
```

لمنع الكسور:

```text
solar_amount =
solar_billable_minutes × solar_hourly_rate ÷ 60
```

وبما أن الوقت مضاعفات `15` دقيقة، تكون النتائج قابلة للضبط.

---

## 18.2 ديزل شامل

```text
diesel_amount =
diesel_billable_minutes × diesel_inclusive_hourly_rate ÷ 60
```

---

## 18.3 تشغيل ووقود منفصلان

```text
operation_amount =
diesel_billable_minutes × operation_hourly_rate ÷ 60

fuel_amount =
actual_fuel_ml × fuel_price_per_liter ÷ 1000

diesel_total =
operation_amount + fuel_amount
```

---

## 18.4 ديزل المزارع

```text
farmer_diesel_amount =
billable_minutes × operation_hourly_rate ÷ 60
```

لا تضاف قيمة الوقود؛ لأنه ملك للمزارع.

---

## 18.5 الجلسة المختلطة

```text
session_total =
solar_amount
+ well_diesel_amount
+ farmer_diesel_operation_amount
+ approved_additional_fees
```

---

## 18.6 كسور الريال — وحدة التخزين المالية

> ❌ **أُلغيت قاعدة التقريب المالي ceil_to_whole_yer بالقرارين ق-12 وق-14.**

مع إلغاء التقريب صارت الكسور **حتمية** ولا مهرب منها.

مثال: 62 دقيقة بسعر 5,000 ريال للساعة = 5,166.666... ريال.

### القاعدة المعتمدة

تُخزَّن كل المبالغ كأعداد صحيحة، لكن وحدتها **جزء من ألف من الريال** (milli-riyal) بدل الريال الكامل.

```text
5,166.667 ريال  ←  يُخزَّن كـ  5166667
```

المبلغ يُحسب **مرة واحدة** من إجمالي الثواني مباشرة، ولا يُحسب سعر دقيقة ثم يُضرب:

```text
amount_milli = (billable_seconds × hourly_rate_milli) / 3600
```

أقصى فارق ممكن = جزء من ألف من الريال في الجلسة الواحدة، أي صفر عمليًا.

السبب في اختيار العدد الصحيح بدل العدد العشري: الأرقام العشرية (Floating point) تُنتج قيمًا مثل 5166.66666666667 وتُفسد المطابقة المحاسبية.

### 18.6.1 التحصيل النقدي

النقد لا يقبل الكسور، والمزارع لا يستطيع دفع 5,166.667 ريال.

**المبلغ المستحق يبقى دقيقًا كما هو**، والفرق بين المستحق والمدفوع نقدًا يُسجَّل **رصيدًا مُرحَّلًا** (Carried-over balance) على حساب المزارع.

لا يُسمى «تسوية تقريب» ولا يُعامل معاملتها. الرصيد يتراكم ويُسوَّى تلقائيًا في الجلسة التالية.

النتيجة: لا يضيع مال، ولا يُخترع مال.

❌ الحقول المحذوفة: **rounding_amount** و **money_rounding_mode** و **rounding_adjustment_minor** و **rounding_minor**.

---

# 19. محرك الفواتير

## 19.1 الفاتورة `invoices`

```text
id
tenant_id
display_code
well_id
farmer_well_account_id
session_id
invoice_date
due_date
status
subtotal_amount
rounding_amount
total_amount
paid_amount
outstanding_amount
settlement_method
approved_at
```

الحالات:

```text
draft
issued
partially_paid
paid
overdue
cancelled
reversed
```

---

## 19.2 بنود الفاتورة `invoice_lines`

```text
id
invoice_id
line_type
description
quantity
unit
unit_price
amount
source_segment_id
```

أنواع البنود:

```text
solar_irrigation
diesel_operation
diesel_fuel
partner_adjustment
additional_fee
opening_balance
manual_adjustment
```

---

## 19.3 إصدار الفاتورة

عند إنهاء الجلسة:

1. يحسب الوقت.
2. تطبق قواعد التقريب.
3. تطبق الأسعار.
4. تطبق سياسة الشريك.
5. تنشأ مسودة فاتورة.
6. يراجع المشغل الملخص.
7. تصدر الفاتورة.
8. ينشأ القيد المالي.

---

# 20. الدفعات

## 20.1 جدول الدفعات `payments`

```text
id
tenant_id
display_code
well_id
payer_person_id
farmer_well_account_id
payment_date
amount
currency_code
payment_method
cashbox_id
status
reference
notes
received_by
```

طرق الدفع:

```text
cash
bank_transfer
mobile_wallet
advance_balance
partner_profit_offset
other
```

---

## 20.2 توزيع الدفعة `payment_allocations`

الدفعة الواحدة قد تسدد أكثر من فاتورة.

```text
id
payment_id
invoice_id
allocated_amount
created_at
```

---

## 20.3 الدفع الجزئي

مثال:

```text
الفاتورة: 20,000
الدفعة: 8,000
المتبقي: 12,000
```

حالة الفاتورة:

```text
partially_paid
```

---

## 20.4 الدفع الزائد

إذا دفع المزارع:

```text
الدين: 15,000
المدفوع: 20,000
```

يعرض النظام:

```text
سيتم تسديد 15,000
وسيتحول 5,000 إلى رصيد مقدم.
```

ولا ينفذ إلا بعد التأكيد.

---

# 21. الرصيد المقدم

## 21.1 أرصدة العملاء المقدمة

لا يحفظ الرصيد كحقل يدوي فقط، بل يسجل في دفتر الحسابات كالتزام على البئر للمزارع.

عند استلام مقدم:

```text
الصندوق يزيد
التزام رصيد المزارع المقدم يزيد
```

عند استخدامه:

```text
التزام الرصيد المقدم ينخفض
دين الفاتورة ينخفض
```

---

# 22. دفتر الحسابات المالي

## 22.1 لماذا نستخدم الدفتر المزدوج؟

كل حركة مالية يجب أن تؤثر في حسابين على الأقل.

بهذا يمكن دائمًا الإجابة:

* من أين جاء المال؟
* إلى أين ذهب؟
* لمن هو مستحق؟
* لماذا تغير الرصيد؟

---

## 22.2 دليل الحسابات `ledger_accounts`

الحسابات الرئيسية المقترحة:

### الأصول

```text
1000 الصناديق والنقد
1010 صندوق البئر
1020 عهدة مشغل
1100 ديون المزارعين
1200 مخزون ديزل البئر
1300 دفعات مقدمة لموردين
```

### الالتزامات

```text
2000 أرصدة مقدمة للمزارعين
2100 مستحقات الشركاء
2200 رواتب مستحقة
2300 مصروفات مستحقة
2400 مبالغ مستحقة لشركاء دفعوا مصروفات
2500 احتياطي صيانة
```

### حقوق الملكية

```text
3000 رأس المال
3100 أرباح متراكمة
3200 أرباح قابلة للتوزيع
```

### الإيرادات

```text
4000 إيراد سقي شمسي
4100 إيراد تشغيل ديزل
4200 إيراد وقود
4300 إيرادات أخرى
```

### المصروفات

```text
5000 مصروف ديزل
5100 مصروف صيانة
5200 مصروف زيت
5300 قطع غيار
5400 رواتب
5500 نقل
5600 حراسة
5700 مصروفات إدارية
5800 فروقات مخزون
5900 مصروفات أخرى
```

---

## 22.3 القيود اليومية `journal_entries`

```text
id
tenant_id
display_code
well_id
entry_date
status
source_type
source_id
description
posted_at
posted_by
reversal_of_entry_id
idempotency_key
```

الحالات:

```text
draft
posted
reversed
```

---

## 22.4 أطراف القيد `journal_lines`

```text
id
journal_entry_id
ledger_account_id
debit_amount
credit_amount
person_id
farmer_well_account_id
partner_id
cashbox_id
fuel_tank_id
description
```

قاعدة أساسية:

```text
مجموع المدين = مجموع الدائن
```

لا يسمح بترحيل القيد إذا لم يتحقق التوازن.

---

# 23. أمثلة القيود المالية

## 23.1 إصدار فاتورة ري بقيمة `20,000`

```text
مدين:
ديون المزارعين                 20,000

دائن:
إيراد السقي                    20,000
```

---

## 23.2 دفع المزارع `8,000` نقدًا

```text
مدين:
صندوق البئر                     8,000

دائن:
ديون المزارعين                  8,000
```

يبقى الدين:

```text
12,000
```

---

## 23.3 دفع مقدم بقيمة `10,000`

```text
مدين:
صندوق البئر                    10,000

دائن:
أرصدة مقدمة للمزارعين          10,000
```

الرصيد المقدم ليس إيرادًا بعد.

---

## 23.4 استخدام المقدم لسداد فاتورة

```text
مدين:
أرصدة مقدمة للمزارعين          10,000

دائن:
ديون المزارعين                 10,000
```

---

## 23.5 مصروف صيانة نقدي `15,000`

```text
مدين:
مصروف الصيانة                  15,000

دائن:
صندوق البئر                    15,000
```

---

## 23.6 مصروف دفعه شريك من ماله

```text
مدين:
مصروف الصيانة                  15,000

دائن:
مبلغ مستحق للشريك              15,000
```

لا يتغير صندوق البئر؛ لأن المال لم يخرج منه.

---

## 23.7 سداد المبلغ للشريك لاحقًا

```text
مدين:
مبلغ مستحق للشريك              15,000

دائن:
صندوق البئر                    15,000
```

---

# 24. سقي الشريك والخصم من الأرباح

## 24.1 عند إصدار فاتورة للشريك

تعامل الجلسة ماليًا مثل أي جلسة:

```text
مدين:
دين الشريك                     20,000

دائن:
إيراد السقي                    20,000
```

لكن تسجل الفاتورة بطريقة تسوية:

```text
settlement_method = partner_profit_offset
```

---

## 24.2 عند إعلان أرباح الشريك

إذا أصبح للشريك مستحق توزيع `150,000`:

```text
مدين:
الأرباح القابلة للتوزيع       150,000

دائن:
مستحقات الشريك                150,000
```

---

## 24.3 خصم جلسات الشريك

```text
مدين:
مستحقات الشريك                 20,000

دائن:
دين الشريك                     20,000
```

المتبقي له:

```text
130,000
```

---

## 24.4 إذا لم تكف أرباح الشريك

مثال:

```text
مستحق الأرباح: 10,000
دين السقي: 20,000
```

يتم تسوية:

```text
10,000
```

ويبقى عليه:

```text
10,000 دين
```

---

# 25. المصروفات

## 25.1 جدول المصروفات `expenses`

```text
id
tenant_id
display_code
well_id
category_id
expense_date
description
amount
payment_status
payment_source
cashbox_id
paid_by_person_id
status
requires_approval
attachment_required
created_by
```

---

## 25.2 موافقات المصروف `expense_approvals`

```text
id
expense_id
approval_level
required_role
approver_user_id
decision
decision_at
notes
```

القرارات:

```text
pending
approved
rejected
```

---

## 25.3 قواعد اعتماد المصروف `expense_approval_rules`

```text
id
well_id
category_id
minimum_amount
maximum_amount
required_approvals
required_roles
attachment_required
effective_from
effective_to
```

---

## 25.4 توقيت القيد المالي

المصروف الذي يحتاج اعتمادًا:

* لا يرحل نهائيًا قبل الاعتماد.
* يظهر كعملية معلقة.
* بعد الاعتماد ينشأ القيد.

إذا دفع نقدًا بالفعل قبل الاعتماد، يجب تسجيله كعهدة أو مبلغ معلق حتى تتم المراجعة.

---

# 26. مخزون الديزل

## 26.1 حركات الوقود `fuel_transactions`

```text
id
tenant_id
well_id
fuel_tank_id
transaction_type
quantity_ml
occurred_at
source_person_id
farmer_well_account_id
session_segment_id
expense_id
unit_cost
total_cost
status
measurement_type
created_by
```

أنواع الحركة:

```text
purchase
farmer_deposit
session_consumption
farmer_return
adjustment_in
adjustment_out
leakage
loss
opening_balance
physical_count
```

---

## 26.2 القياس الفعلي والتقديري

```text
measurement_type:
actual
estimated
```

إذا كان تقديريًا:

```text
status = pending_actual_measurement
```

---

## 26.3 رصيد ديزل المزارع

لا نحتاج جدول رصيد يدوي مستقل باعتباره المصدر النهائي.

يتم حساب رصيد المزارع من:

```text
إيداعات المزارع
-
استهلاكه
-
الكميات المعادة له
+
التصحيحات
```

يمكن إنشاء جدول ملخص سريع:

```text
farmer_fuel_balance_cache
```

لكنه يعاد بناؤه من الحركات عند الحاجة.

---

## 26.4 منع استخدام رصيد مزارع لغيره

كل استهلاك من ديزل المزارع يجب أن يحمل:

```text
fuel_owner_person_id
```

ويتحقق الخادم أن صاحب الجلسة هو نفسه صاحب الرصيد، إلا إذا كانت الحركة إعادة أو تصحيحًا إداريًا.

---

# 27. الصناديق

## 27.1 جدول الصناديق `cashboxes`

```text
id
well_id
display_code
name
cashbox_type
assigned_user_id
status
```

الأنواع:

```text
main_well
operator_custody
shift_cashbox
petty_cash
```

---

## 27.2 حركات الصندوق

لا يحتاج جدول منفصل كمصدر مالي إذا كانت كل الحركات مسجلة في دفتر القيود.

يمكن إنشاء عرض:

```text
cashbox_transactions_view
```

يعرض القيود المرتبطة بالصندوق.

---

## 27.3 رصيد الصندوق

```text
الرصيد =
مجموع المدين
-
مجموع الدائن
```

لحساب الصندوق، لأن حساب النقد طبيعته مدينة.

---

# 28. النوبات وتسليم الصندوق

## 28.1 جدول النوبات `shifts`

```text
id
well_id
operator_user_id
cashbox_id
started_at
ended_at
status
opening_cash_amount
expected_closing_cash
actual_closing_cash
cash_difference
```

---

## 28.2 تسليم النوبة `shift_handovers`

```text
id
shift_id
from_user_id
to_user_id
handed_over_at
expected_cash
actual_cash
fuel_balance_ml
open_sessions_count
pending_operations_count
status
notes
```

الحالات:

```text
draft
submitted
accepted
accepted_with_difference
rejected
```

---

## 28.3 فرق الصندوق

إذا ظهر فرق:

```text
cash_difference =
actual_cash - expected_cash
```

لا يصحح تلقائيًا.

يجب:

* تسجيل السبب.
* طلب اعتماد.
* إنشاء قيد فروقات عند الموافقة.

---

# 29. الرواتب

## 29.1 إعداد راتب الموظف `worker_compensation_rules`

```text
id
well_id
person_id
compensation_type
rate_amount
effective_from
effective_to
settings_json
```

الأنواع:

```text
monthly
daily
hourly
per_shift
fixed_plus_bonus
custom
```

---

## 29.2 مستحقات الرواتب `payroll_accruals`

```text
id
well_id
person_id
period_start
period_end
gross_amount
deductions
net_amount
status
```

---

## 29.3 دفع الراتب `salary_payments`

يرتبط بجدول الدفعات أو حركة مالية مستقلة، وينشئ:

```text
مدين:
رواتب مستحقة

دائن:
صندوق البئر
```

---

# 30. الإقفال المالي

يجب الفصل بين أربعة أنواع من الإقفال.

## 30.1 إقفال الجلسة

يعني:

* انتهى التشغيل.
* تم حساب الوقت.
* صدرت الفاتورة.
* لا تعدل إلا بتصحيح.

---

## 30.2 إقفال النوبة

يعني:

* تمت مراجعة الصندوق.
* تم تسليم العمليات.
* حددت الفروقات.

---

## 30.3 إقفال الفترة المحاسبية

جدول:

```text
accounting_periods
```

الحقول:

```text
id
well_id
period_type
starts_at
ends_at
status
closed_at
closed_by
reopened_at
reopened_by
```

الحالات:

```text
open
reviewing
closed
reopened
```

---

## 30.4 إقفال دورة التوزيع

يعني:

* مراجعة الأموال المحصلة.
* مراجعة المصروفات.
* تحديد الاحتياطي.
* احتساب المبلغ القابل للتوزيع.
* تثبيت نسب الشركاء للفترة.
* إنشاء مستحقات الشركاء.

---

# 31. محرك توزيع الأرباح

## 31.1 الفرق بين الربح المحاسبي والمال القابل للتوزيع

### الربح المحاسبي

```text
الإيرادات المستحقة
-
المصروفات المستحقة
```

قد يشمل ديونًا لم تدفع بعد.

### المال القابل للتوزيع

يعتمد على الأموال المحصلة فعليًا.

```text
المقبوضات المؤهلة
-
المصروفات النقدية المؤهلة
-
الالتزامات الواجب حجزها
-
احتياطي الصيانة
-
توزيعات سابقة غير مسلمة
=
المبلغ القابل للتوزيع
```

المعتمد في المشروع هو الثاني.

---

## 31.2 جدول دورات التوزيع `profit_distribution_cycles`

```text
id
well_id
period_start
period_end
status
eligible_collections
eligible_cash_expenses
reserved_liabilities
maintenance_reserve
distributable_amount
approved_at
approved_by
```

---

## 31.3 تفاصيل الشركاء `profit_distribution_lines`

```text
id
distribution_cycle_id
partner_id
profit_percentage
gross_share
partner_receivables
irrigation_deductions
other_deductions
net_payable
status
```

---

## 31.4 تثبيت النسب وقت التوزيع

يجب نسخ النسبة المعتمدة إلى سطر التوزيع.

لا يعتمد التقرير لاحقًا على النسبة الحالية.

مثال:

```text
profit_percentage_snapshot = 25.0000
```

---

## 31.5 تسليم الأرباح

حالات السطر:

```text
calculated
approved
partially_paid
paid
carried_forward
```

---

# 32. احتياطي الصيانة

## 32.1 إعداد الاحتياطي

```text
maintenance_reserve_rules
```

الحقول:

```text
well_id
reserve_type
reserve_value
effective_from
effective_to
```

الأنواع:

```text
percentage_of_collections
percentage_of_profit
fixed_amount
manual_per_cycle
disabled
```

---

## 32.2 قيد تكوين الاحتياطي

```text
مدين:
الأرباح القابلة للتوزيع

دائن:
احتياطي الصيانة
```

عند استخدام الاحتياطي للصيانة، يسجل الاستخدام بوضوح.

---

# 33. الأرصدة الافتتاحية

## 33.1 جلسة إدخال الأرصدة `opening_balance_batches`

```text
id
well_id
reference_date
status
created_by
approved_by
notes
```

---

## 33.2 عناصر الرصيد الافتتاحي

```text
opening_balance_items
```

أنواعها:

```text
farmer_debt
farmer_advance
cashbox_balance
fuel_tank_balance
partner_payable
partner_receivable
salary_payable
expense_payable
capital_balance
```

لا تصبح فعالة إلا بعد الاعتماد.

---

# 34. التصحيح والإلغاء

## 34.1 الفاتورة الخاطئة

لا تعدل الفاتورة المعتمدة مباشرة.

يتم:

1. إنشاء فاتورة عكسية أو إشعار إلغاء.
2. عكس القيد الأصلي.
3. إنشاء فاتورة صحيحة.
4. ربط السجلات ببعضها.
5. تسجيل السبب.

---

## 34.2 الدفعة الخاطئة

إذا سجلت دفعة مرتين:

* لا تحذف.
* تعكس الدفعة المكررة.
* ينشأ قيد معاكس.
* يبقى أثر الخطأ والتصحيح.

---

## 34.3 تعديل وقت جلسة معتمدة

يحتاج:

* صلاحية.
* سبب.
* إعادة حساب.
* إصدار فاتورة تصحيح.
* مراجعة أثر الدفعات.
* تسجيل في التدقيق.

---

# 35. سجل التدقيق

## 35.1 جدول `audit_logs`

```text
id
tenant_id
well_id
user_id
device_id
action
entity_type
entity_id
old_values_json
new_values_json
reason
client_timestamp
server_timestamp
ip_address
app_version
```

---

## 35.2 الأحداث الحساسة

يجب تسجيل:

* تغيير الأسعار.
* تغيير نسب الشركاء.
* تغيير سياسة الشريك.
* تعديل جلسة.
* إلغاء فاتورة.
* عكس دفعة.
* اعتماد مصروف.
* تعديل مخزون.
* إقفال فترة.
* إعادة فتح فترة.
* توزيع أرباح.
* تغيير صلاحية.
* دمج أشخاص.

---

# 36. المزامنة والعمل دون إنترنت

## 36.1 قاعدة الهاتف

يحتفظ الهاتف بنسخة محلية من البيانات المسموح للمستخدم بها.

لا يحتاج المشغل إلى تنزيل بيانات جميع العملاء والآبار.

---

## 36.2 صندوق الأوامر المحلي `outbox`

كل عملية ينشئها الهاتف تسجل محليًا:

```text
operation_id
operation_type
entity_id
payload
created_at
retry_count
status
```

الحالات:

```text
pending
sending
accepted
rejected
conflict
```

---

## 36.3 منع التكرار

كل عملية تحمل:

```text
idempotency_key
```

الخادم يحفظ هذا المفتاح.

إذا استقبل العملية نفسها عدة مرات، ينفذها مرة واحدة فقط.

---

## 36.4 أمثلة العمليات الحساسة

```text
start_session
complete_session
issue_invoice
record_payment
approve_expense
close_period
create_distribution
```

هذه العمليات لا تنفذ كحفظ صف عادي فقط، بل كأوامر يتحقق منها الخادم.

---

## 36.5 التحقق على الهاتف والخادم

الهاتف:

* يعرض الحساب بسرعة.
* يمنع الأخطاء الواضحة.
* يعمل دون اتصال.

الخادم:

* يعيد الحساب.
* يتحقق من السعر.
* يتحقق من الصلاحية.
* يتحقق من الإقفال.
* يتحقق من التكرار.
* يعتمد النتيجة النهائية.

---

# 37. معالجة التعارضات

## 37.1 تعارضات يمكن دمجها

* إضافة ملاحظة.
* إضافة مرفق.
* إضافة أرض جديدة مختلفة.
* إضافة حجز مختلف.

---

## 37.2 تعارضات تحتاج مراجعة

* تعديل وقت جلسة.
* تعديل دفعة.
* تعديل سعر.
* تعديل نسبة.
* تعديل رصيد وقود.
* تعديل صندوق مغلق.
* تعديل عملية بعد الإقفال.

---

## 37.3 سجل التعارضات `sync_conflicts`

```text
id
tenant_id
entity_type
entity_id
server_version
client_version
server_data_json
client_data_json
status
resolved_by
resolved_at
resolution
```

---

# 38. القيود وقواعد سلامة البيانات

يجب تطبيق قواعد مباشرة في قاعدة البيانات، وليس داخل الواجهة فقط.

## 38.1 القيود المالية

* مجموع المدين يساوي مجموع الدائن.
* المبالغ أكبر من صفر.
* العملة موجودة.
* القيد المرحل لا يعدل.
* لا يكرر `source_type + source_id`.
* لا يكرر `idempotency_key`.

---

## 38.2 قيود الدفعات

* مجموع التوزيعات لا يتجاوز قيمة الدفعة.
* لا يخصص مبلغ لفاتورة عميل آخر.
* لا تخصص دفعة ملغاة.
* لا تدفع فاتورة ملغاة.

---

## 38.3 قيود الجلسة

* النهاية بعد البداية.
* المقاطع لا تتداخل.
* المورد متاح.
* المزارع والأرض مرتبطان بالبئر.
* الجلسة المكتملة لها مقطع واحد على الأقل.
* الفاتورة لا تصدر مرتين.

---

## 38.4 قيود الوقود

* الكمية أكبر من صفر.
* الاستهلاك مرتبط بجلسة أو سبب.
* رصيد مزارع لا يستخدم لغيره.
* المخزون لا يصبح سالبًا إلا بصلاحية استثنائية.
* التصحيح يحتاج سببًا.

---

## 38.5 قيود الشركاء

* النسبة لا تكون سالبة.
* مجموع النسب لا يتجاوز `100%`.
* لا تتداخل نسختان لنسبة الشريك في الفترة نفسها.
* لا ينفذ توزيع إذا لم تكن النسب مكتملة.

---

# 39. الفهارس اللازمة للأداء

يجب إنشاء فهارس على:

```text
tenant_id
well_id
person_id
farmer_well_account_id
session_id
invoice_id
payment_id
created_at
status
effective_from
effective_to
idempotency_key
```

فهارس بحث إضافية:

* الاسم المبسط.
* رقم الهاتف.
* رمز المزارع.
* رمز الفاتورة.
* رمز الجلسة.

---

# 40. البحث العربي ومنع التكرار

يجب إنشاء نسخة بحث مبسطة من الأسماء:

```text
normalized_name
```

قد تتضمن:

* إزالة المسافات الزائدة.
* توحيد بعض أشكال الألف.
* إزالة التشكيل.
* توحيد الياء والألف المقصورة وفق سياسة واضحة.
* تحويل الأرقام إلى الشكل الإنجليزي.
* الإبقاء على الاسم الأصلي دون تعديل.

مثال:

```text
الاسم الأصلي: عبد الله محمد
نسخة البحث: عبدالله محمد
```

لا تستخدم نسخة البحث في العرض الرسمي.

---

# 41. الصلاحيات على مستوى البيانات

يجب تطبيق Row Level Security.

أمثلة:

## المشغل

يستطيع:

* رؤية مزارعي البئر.
* إضافة جلسة.
* إضافة دفعة.
* إضافة مصروف.

لا يستطيع:

* رؤية بئر آخر.
* تعديل نسبة شريك.
* تغيير سعر.
* اعتماد توزيع أرباح.

## الشريك

يستطيع:

* رؤية بيانات البئر المسموح بها.
* رؤية حصته.
* رؤية تقريره.

لا يستطيع:

* رؤية بيانات شخصية حساسة لشريك آخر، إلا إذا سمحت سياسة البئر.
* تعديل العمليات.

---

# 42. العروض والتقارير المحسوبة

يجب إنشاء Views أو Materialized Views مثل:

```text
farmer_account_summary
well_daily_summary
cashbox_balance_summary
fuel_tank_balance_summary
partner_balance_summary
distribution_summary
operator_shift_summary
```

هذه العروض تجمع البيانات دون أن تصبح مصدرًا ماليًا مستقلًا.

---

# 43. تقرير حساب المزارع

يحسب من:

```text
الفواتير
-
الدفعات المخصصة
-
الأرصدة المقدمة المستخدمة
-
الاستقطاعات
+
الأرصدة الافتتاحية
```

ويعرض:

* رصيد بداية الفترة.
* جلسات الفترة.
* قيمة كل جلسة.
* الدفعات.
* الرصيد المقدم.
* الدين المتبقي.
* رصيد ديزله.
* الأراضي التي تم ريها.

---

# 44. تقرير الشريك

يعرض:

* نسبة الملكية الحالية.
* النسب السابقة.
* إجمالي الأرباح.
* سقي الشريك.
* المبالغ المخصومة.
* مصروفات دفعها.
* مستحقاته.
* ما تم دفعه.
* ما تم ترحيله.

---

# 45. التقرير اليومي للبئر

يعرض:

* عدد الجلسات.
* ساعات الشمس.
* ساعات الديزل.
* التوقفات.
* المبالغ المستحقة.
* المبالغ المحصلة.
* الديون الجديدة.
* الديون المحصلة.
* المصروفات.
* رصيد الصندوق.
* رصيد الوقود.
* الجلسات المفتوحة.
* العمليات غير المتزامنة.

---

# 46. القرارات المعمارية النهائية

## 46.1 المزارع

* شخص موحد.
* ملف مزارع.
* حساب مستقل في كل بئر.
* عدة أراضٍ.
* هاتف اختياري.
* لا تكرار تلقائي.
* قابل للربط بحساب دخول مستقبلًا.

## 46.2 الجلسات

* حجز منفصل عن التشغيل.
* الجلسة تحتوي على مقاطع.
* الشمس والديزل والمختلط مدعومة.
* التوقفات محفوظة.
* التقريب إلى الربع الأعلى.
* الوقت الفعلي محفوظ.

## 46.3 المال

* فاتورة مستقلة عن الدفعة.
* دعم الدفع الجزئي.
* دعم الرصيد المقدم.
* الديون منفصلة عن النقد.
* الدفتر المالي مزدوج.
* لا حذف للعمليات.

## 46.4 الشركاء

* النسب تاريخية.
* سياسات السقي متعددة.
* الافتراضي خصم السقي من الأرباح.
* المال المحصل فقط يدخل التوزيع.
* الديون لا توزع.

## 46.5 الديزل

* المخزون بالملليلتر.
* الجالون المحلي `20` لترًا.
* الفعلي هو المعتمد.
* التقديري للمقارنة.
* رصيد المزارع مستقل.

---

# 47. ترتيب تنفيذ قاعدة البيانات

## المرحلة 1: النواة

* tenants
* persons
* users
* roles
* permissions
* wells
* locations

## المرحلة 2: التشغيل

* farmers
* farms
* pumps
* water_lines
* bookings
* sessions
* segments
* prices

## المرحلة 3: المال

* invoices
* invoice_lines
* payments
* payment_allocations
* ledger_accounts
* journal_entries
* journal_lines

## المرحلة 4: الديزل والمصروفات

* fuel_tanks
* fuel_transactions
* expenses
* approvals
* cashboxes
* shifts

## المرحلة 5: الشركاء

* partners
* ownership_versions
* partner_policies
* distribution_cycles
* distribution_lines

## المرحلة 6: الإدارة

* audit_logs
* sync_conflicts
* notifications
* attachments
* subscriptions

---

# 48. اختبارات المحرك المالي الإلزامية

قبل قبول النظام يجب اختبار:

1. جلسة شمس مدتها `1:01`.
2. جلسة شمس مدتها `1:15`.
3. جلسة مختلطة.
4. توقف غير محسوب.
5. سعر ساعة لا يقبل القسمة على `4`.
6. دفع كامل.
7. دفع جزئي.
8. دفع زائد.
9. رصيد مقدم.
10. دفع شخص عن مزارع.
11. مصروف نقدي.
12. مصروف دفعه شريك.
13. ديزل مزارع مع فائض.
14. قياس تقديري ثم فعلي.
15. شريك يخصم من أرباحه.
16. أرباح لا تكفي لدين الشريك.
17. تغير نسبة شريك.
18. إقفال فترة.
19. تصحيح فاتورة بعد الإقفال.
20. إرسال دفعة مرتين من هاتف غير متصل.
21. تعارض تعديل من جهازين.
22. فرق صندوق في تسليم نوبة.
23. احتياطي صيانة.
24. توزيع أموال محصلة فقط.
25. إدخال أرصدة قديمة.

---

# 49. النقاط التي سيحتاج تنفيذها إلى قرار عند البرمجة

هذه ليست عيوبًا في التصميم، بل إعدادات يجب تثبيتها أثناء التنفيذ:

1. هل يتم تقريب كل مصدر طاقة منفصلًا أم الجلسة كاملة؟
   **التوصية:** كل مصدر منفصلًا بعد جمع مقاطعه.

2. كيف نقرب كسور الريال؟
   **التوصية:** إلى الريال الأعلى.

3. هل يسمح بمخزون ديزل سالب مؤقتًا؟
   **التوصية:** لا، إلا بصلاحية استثنائية مع سبب.

4. هل يطبق السعر عند بداية الجلسة أم على كل مقطع حسب وقته؟
   **التوصية:** السعر الساري عند بداية كل مقطع، مع حفظ لقطة السعر.

5. هل يسمح بتعديل جلسة بعد إصدار فاتورة؟
   **التوصية:** فقط من خلال عملية تصحيح معتمدة.

---

# 50. النتيجة النهائية

هذا التصميم يضمن أن:

* المزارع لا يتكرر بسبب تغيير الهاتف أو اختلاف الاسم.
* كل أرض تبقى مرتبطة بصاحبها.
* يمكن للمزارع امتلاك عدة أراضٍ.
* الجلسة الشمسية والديزل والمختلطة تحسب بدقة.
* التوقفات لا تضيع.
* الدفعة لا تتكرر عند ضعف الإنترنت.
* الدين لا يختلط بالنقد.
* رصيد الديزل لا يختلط بين المزارعين.
* الشريك لا يفقد حقه عند تغير النسبة.
* المصروف الذي يدفعه الشريك يظهر كمستحق له.
* الأرباح توزع من الأموال المحصلة فقط.
* جميع الأرقام قابلة للمراجعة.
* كل تعديل حساس يمكن تتبعه.
* النظام قابل للتوسع إلى أي عدد من الآبار والعملاء.
