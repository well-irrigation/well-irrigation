


## ملاحظة تنفيذية حاكمة — 2026-08-17

المخطط التنفيذي الحالي مقيد بق-77 وق-78 وق-79.

- المال ريال كامل.
- rounding fields الملغاة ليست جزءًا من المخطط الحالي.
- Flutter لا يكتب الجداول مباشرة.
- schema `api` هو حد التطبيق.
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

* **core.well_settings** — حُذفت 3 حقول تقريب، وأُضيف حقلا تنبيه (ق-12، ق-34، ق-40).
* **§23** دالة ops.ceil_to_quarter_hour — ❌ محذوفة، حلّت محلها ops.time_charge_milli (ق-12).
* **minimum_billable_minutes** — ❌ محذوف (ق-16).
* **core.subscription_plans / core.subscriptions** — ❌ التسمية ملغاة. المعتمد هو `billing.*` المبني فعلًا (ق-26). وهذا يحسم التناقض رقم 4.
* **ownership_percentage / profit_percentage** — ❌ نوع numeric(9,6) ملغى، والمعتمد عدد صحيح من مليون جزء (ق-21).
* **جميع حقول _minor** — وحدتها صارت جزءًا من ألف من الريال (ق-14).

---

# المخطط التنفيذي لقاعدة بيانات PostgreSQL والمحرك المالي

**المشروع:** منصة إدارة آبار المياه والري
**الإصدار:** 1.0
**حالة الوثيقة:** مخطط تنفيذي أولي قابل للتحويل إلى ملفات Migration
**قاعدة البيانات المركزية:** PostgreSQL عبر Supabase
**قاعدة الهاتف:** SQLite عبر PowerSync
**لغة الواجهة الأولى:** العربية
**الأرقام:** إنجليزية دائمًا `0–9`
**العملة الأولى:** `YER`
**المنطقة الزمنية الافتراضية:** `Asia/Aden`

تعتمد هذه الوثيقة على المتطلبات التي تثبت تشغيل الآبار بالطاقة الشمسية أو الديزل أو كليهما، ووجود عدة شركاء ومشغلين ومزارعين وحسابات مالية مترابطة. كما تدعم النظام الميداني للمشغل ولوحة المراقبة المالية للشركاء ضمن قاعدة بيانات واحدة وصلاحيات مختلفة.

---

# 1. القرارات المعمارية النهائية

## 1.1 قاعدة بيانات مركزية واحدة

لن توجد قاعدة بيانات مستقلة للمشغل وأخرى للمالك.

جميع البيانات تحفظ في قاعدة واحدة، ويحدد نظام الصلاحيات ما يستطيع كل مستخدم:

* رؤيته.
* إضافته.
* تعديله.
* اعتماده.
* إلغاؤه.
* تصديره.

## 1.2 كل عميل معزول عن غيره

كل حساب تجاري داخل المنصة يسمى:

```text
Tenant
```

وهو العميل أو المؤسسة التي تدير بئرًا أو عدة آبار.

كل سجل مهم يحتوي على:

```text
tenant_id
```

وبذلك يستحيل على مستخدم تابع لعميل الوصول إلى بيانات عميل آخر.

## 1.3 استخدام UUID

كل سجل يحصل على معرف ثابت من نوع:

```sql
uuid
```

ينشأ داخل الهاتف حتى عند عدم وجود الإنترنت.

مثال:

```text
45bb2b33-8ea8-4d2a-a840-f39775dcb820
```

## 1.4 الرقم الظاهر للمستخدم

إلى جانب UUID، يمكن عرض رمز مفهوم:

```text
FAR-26-A7K9P
INV-26-P83DZ
PAY-26-W91LC
SES-26-B3M8R
```

يجب أن يكون الرمز قابلاً للإنشاء دون إنترنت، وألا يعتمد على رقم تسلسلي مركزي فقط.

بعد المزامنة يمكن للخادم إضافة رقم تسلسلي اختياري للتقارير الرسمية:

```text
Invoice No. 1527
```

## 1.5 عدم حذف العمليات المالية

العمليات المالية لا تحذف نهائيًا.

المسموح:

* إلغاء.
* عكس.
* تصحيح.
* إنشاء عملية بديلة.
* أرشفة البيانات غير المالية.

## 1.6 الأرقام المالية

تخزن مبالغ الريال اليمني كعدد صحيح:

```sql
bigint
```

مثال:

```text
15000
```

ولا يستخدم:

```sql
float
double precision
real
```

في أي حساب مالي.

## 1.7 كميات الوقود

تخزن بالملليلتر:

```text
1 لتر = 1000 ml
1 جالون محلي = 20000 ml
```

مثال:

```text
20.5 لتر = 20500 ml
```

## 1.8 الوقت

يخزن التاريخ والوقت باستخدام:

```sql
timestamptz
```

وتعرض القيمة للمستخدم حسب منطقة البئر الزمنية.

## 1.9 النسب

تخزن النسب باستخدام:

```sql
numeric(9,6)
```

مثال:

```text
25.500000%
```

---

# 2. تقسيم قاعدة البيانات إلى Schemas

التقسيم المقترح:

```text
iam        الهوية والمستخدمون والصلاحيات
core       العملاء والأشخاص والآبار والمواقع
ops        المزارعون والأراضي والحجوزات والجلسات
inventory  الوقود والمخزون
billing    الفواتير والدفعات
finance    الحسابات والقيود والمصروفات والأرباح
audit      سجل التدقيق
sync       المزامنة والتعارضات
reporting  العروض والتقارير المحسوبة
```

هذا التقسيم يمنع تحول قاعدة البيانات إلى مجموعة جداول عشوائية.

---

# 3. الإضافات المطلوبة في PostgreSQL

```sql
create extension if not exists pgcrypto;
create extension if not exists pg_trgm;
create extension if not exists btree_gist;
create extension if not exists citext;
```

## وظيفة كل إضافة

### `pgcrypto`

لإنشاء UUID:

```sql
gen_random_uuid()
```

### `pg_trgm`

للبحث التقريبي في أسماء المزارعين ومنع التكرار.

### `btree_gist`

لمنع تداخل الفترات الزمنية، مثل:

* نسب الشركاء.
* الأسعار.
* الحجوزات.
* استخدام المضخات والخطوط.

### `citext`

للتعامل مع النصوص الإنجليزية دون حساسية لحالة الأحرف، مثل البريد واسم المستخدم.

---

# 4. إنشاء الـSchemas

```sql
create schema if not exists iam;
create schema if not exists core;
create schema if not exists ops;
create schema if not exists inventory;
create schema if not exists billing;
create schema if not exists finance;
create schema if not exists audit;
create schema if not exists sync;
create schema if not exists reporting;
```

---

# 5. الحقول القياسية

تستخدم غالبية الجداول الحقول التالية:

```sql
id uuid primary key default gen_random_uuid(),
tenant_id uuid not null,
created_at timestamptz not null default now(),
created_by uuid,
updated_at timestamptz not null default now(),
updated_by uuid,
archived_at timestamptz,
version bigint not null default 1,
origin_device_id uuid,
client_created_at timestamptz,
server_received_at timestamptz not null default now()
```

## وظيفة `version`

عند تعديل سجل:

```text
version = version + 1
```

إذا حاول جهاز تعديل سجل بناءً على نسخة قديمة، يكتشف النظام وجود تعارض.

---

# 6. العملاء والاشتراكات

## 6.1 جدول العملاء

```sql
create table core.tenants (
    id uuid primary key default gen_random_uuid(),

    public_code text not null unique,
    name text not null,
    legal_name text,

    status text not null default 'trial'
        check (status in (
            'trial',
            'active',
            'past_due',
            'suspended',
            'cancelled',
            'archived'
        )),

    default_currency char(3) not null default 'YER',
    default_timezone text not null default 'Asia/Aden',

    trial_started_at timestamptz,
    trial_ends_at timestamptz,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    archived_at timestamptz
);
```

## 6.2 خطط الاشتراك

```sql
create table core.subscription_plans (
    id uuid primary key default gen_random_uuid(),

    code text not null unique,
    name_ar text not null,
    name_en text,

    max_wells integer,
    max_users integer,
    max_storage_bytes bigint,

    monthly_price_minor bigint not null default 0,
    annual_price_minor bigint not null default 0,
    currency_code char(3) not null default 'USD',

    features jsonb not null default '{}'::jsonb,

    is_active boolean not null default true,
    created_at timestamptz not null default now()
);
```

## 6.3 اشتراك العميل

```sql
create table core.subscriptions (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    plan_id uuid not null
        references core.subscription_plans(id),

    status text not null
        check (status in (
            'trial',
            'active',
            'past_due',
            'cancelled',
            'expired'
        )),

    billing_source text not null
        check (billing_source in (
            'google_play',
            'manual',
            'activation_code',
            'reseller',
            'direct_invoice'
        )),

    external_subscription_id text,

    started_at timestamptz not null,
    current_period_start timestamptz,
    current_period_end timestamptz,
    trial_ends_at timestamptz,
    cancelled_at timestamptz,

    created_at timestamptz not null default now()
);
```

---

# 7. بطاقة الشخص الموحدة

## 7.1 الأشخاص

```sql
create table core.persons (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    public_code text not null,

    full_name text not null,
    normalized_name text not null,

    preferred_name text,
    father_name text,
    family_name text,
    nickname text,

    notes text,

    status text not null default 'active'
        check (status in (
            'active',
            'inactive',
            'merged',
            'archived'
        )),

    merged_into_person_id uuid
        references core.persons(id),

    created_at timestamptz not null default now(),
    created_by uuid,
    updated_at timestamptz not null default now(),
    updated_by uuid,
    archived_at timestamptz,

    version bigint not null default 1,

    unique (tenant_id, public_code)
);
```

## 7.2 وسائل التواصل

```sql
create table core.person_contacts (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    person_id uuid not null
        references core.persons(id),

    contact_type text not null
        check (contact_type in (
            'mobile',
            'whatsapp',
            'landline',
            'email',
            'other'
        )),

    contact_value text not null,
    normalized_value text not null,

    is_primary boolean not null default false,

    belongs_to_person boolean not null default true,
    contact_owner_name text,

    verified_at timestamptz,

    created_at timestamptz not null default now()
);
```

يجب ألا يكون رقم الهاتف فريدًا عالميًا؛ لأن أكثر من شخص قد يستخدم الرقم نفسه.

لكن ينشأ فهرس للمساعدة في اكتشاف التكرار:

```sql
create index idx_person_contacts_normalized
on core.person_contacts (
    tenant_id,
    normalized_value
);
```

## 7.3 الأسماء البديلة

```sql
create table core.person_aliases (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    person_id uuid not null
        references core.persons(id),

    alias text not null,
    normalized_alias text not null,

    alias_type text not null default 'known_as'
        check (alias_type in (
            'known_as',
            'nickname',
            'old_name',
            'local_name',
            'other'
        )),

    created_at timestamptz not null default now()
);
```

## 7.4 فهارس البحث العربي

```sql
create index idx_persons_normalized_name
on core.persons (
    tenant_id,
    normalized_name
);

create index idx_persons_name_trgm
on core.persons
using gin (normalized_name gin_trgm_ops);

create index idx_person_aliases_trgm
on core.person_aliases
using gin (normalized_alias gin_trgm_ops);
```

---

# 8. حسابات المستخدمين

Supabase يدير كلمات المرور داخل:

```text
auth.users
```

ولا يجوز إنشاء جدول كلمات مرور خاص بنا.

## 8.1 ملف المستخدم

```sql
create table iam.users (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    person_id uuid not null
        references core.persons(id),

    auth_user_id uuid not null unique
        references auth.users(id),

    username citext,
    status text not null default 'active'
        check (status in (
            'invited',
            'active',
            'suspended',
            'revoked'
        )),

    last_login_at timestamptz,

    created_at timestamptz not null default now(),

    unique (tenant_id, person_id)
);
```

## 8.2 الأجهزة

```sql
create table iam.user_devices (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    user_id uuid not null
        references iam.users(id),

    device_uuid text not null,
    device_name text,
    platform text not null default 'android',
    android_version text,
    app_version text,

    is_trusted boolean not null default false,
    last_seen_at timestamptz,
    revoked_at timestamptz,

    created_at timestamptz not null default now(),

    unique (user_id, device_uuid)
);
```

---

# 9. الأدوار والصلاحيات

## 9.1 الأدوار

```sql
create table iam.roles (
    id uuid primary key default gen_random_uuid(),

    code text not null unique,
    name_ar text not null,
    name_en text,

    is_system_role boolean not null default true
);
```

الأدوار الأساسية:

```text
tenant_owner
well_manager
operator
accountant
partner
viewer
```

## 9.2 الصلاحيات

```sql
create table iam.permissions (
    id uuid primary key default gen_random_uuid(),

    code text not null unique,
    description_ar text not null
);
```

أمثلة:

```text
farmer.create
farmer.update
farmer.merge
farm.create
booking.create
booking.reschedule
session.start
session.pause
session.complete
session.correct
payment.create
payment.reverse
expense.create
expense.approve
price.manage
ownership.manage
period.close
period.reopen
distribution.calculate
distribution.approve
audit.view
```

## 9.3 ربط الدور بالصلاحية

```sql
create table iam.role_permissions (
    role_id uuid not null
        references iam.roles(id),

    permission_id uuid not null
        references iam.permissions(id),

    primary key (role_id, permission_id)
);
```

---

# 10. المواقع

```sql
create table core.locations (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    country text not null default 'Yemen',
    governorate text not null,
    district text,
    subdistrict text,
    village text,
    valley text,
    local_area text,

    access_description text,

    latitude numeric(10,7),
    longitude numeric(10,7),

    created_at timestamptz not null default now(),

    check (
        latitude is null
        or latitude between -90 and 90
    ),

    check (
        longitude is null
        or longitude between -180 and 180
    )
);
```

---

# 11. الآبار

```sql
create table core.wells (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    public_code text not null,
    name text not null,
    description text,

    location_id uuid
        references core.locations(id),

    status text not null default 'setup'
        check (status in (
            'setup',
            'active',
            'inactive',
            'maintenance',
            'suspended',
            'archived'
        )),

    timezone text not null default 'Asia/Aden',
    currency_code char(3) not null default 'YER',

    commissioned_at date,

    created_at timestamptz not null default now(),
    created_by uuid,
    updated_at timestamptz not null default now(),
    archived_at timestamptz,

    unique (tenant_id, public_code)
);
```

## 11.1 إعدادات البئر

```sql
create table core.well_settings (
    well_id uuid primary key
        references core.wells(id),

    tenant_id uuid not null
        references core.tenants(id),

    -- ❌ حُذفت ثلاثة حقول بالقرار ق-12:
    -- time_rounding_mode / rounding_scope / money_rounding_mode
    -- لا يوجد تقريب للوقت ولا للمال إطلاقًا.

    -- ➕ حقل جديد بالقرار ق-40 (الجلسة المنسية):
    long_session_alert_minutes integer not null default 360
        check (long_session_alert_minutes > 0),

    -- ➕ حقل جديد بالقرار ق-34 (تنبيه قرب الانتهاء):
    session_ending_alert_minutes integer not null default 10
        check (session_ending_alert_minutes >= 0),

    default_partner_policy text not null
        default 'deduct_from_profit',

    phone_required boolean not null default false,
    gps_required boolean not null default false,

    allow_negative_well_fuel boolean not null default false,
    allow_shared_farmer_phone boolean not null default true,

    default_distribution_cycle text not null default 'monthly'
        check (default_distribution_cycle in (
            'daily',
            'weekly',
            'monthly',
            'quarterly',
            'annual',
            'custom'
        )),

    session_end_alert_minutes integer not null default 10
        check (session_end_alert_minutes >= 0),

    next_farmer_alert_minutes integer not null default 30
        check (next_farmer_alert_minutes >= 0),

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);
```

---

# 12. ربط المستخدمين بالآبار

```sql
create table iam.well_user_roles (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    well_id uuid not null
        references core.wells(id),

    user_id uuid not null
        references iam.users(id),

    role_id uuid not null
        references iam.roles(id),

    effective_from timestamptz not null default now(),
    effective_to timestamptz,

    is_active boolean not null default true,

    created_at timestamptz not null default now(),

    check (
        effective_to is null
        or effective_to > effective_from
    )
);
```

---

# 13. المضخات والخطوط

## 13.1 المضخات

```sql
create table core.pumps (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    well_id uuid not null
        references core.wells(id),

    public_code text not null,
    name text not null,

    pump_type text,
    power_rating text,

    status text not null default 'active'
        check (status in (
            'active',
            'inactive',
            'maintenance',
            'retired'
        )),

    estimated_fuel_ml_per_hour bigint
        check (
            estimated_fuel_ml_per_hour is null
            or estimated_fuel_ml_per_hour >= 0
        ),

    estimated_water_flow_liters_per_minute numeric(14,3),

    installed_at date,
    notes text,

    created_at timestamptz not null default now(),

    unique (well_id, public_code)
);
```

## 13.2 خطوط المياه

```sql
create table core.water_lines (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    well_id uuid not null
        references core.wells(id),

    public_code text not null,
    name text not null,

    status text not null default 'active'
        check (status in (
            'active',
            'inactive',
            'maintenance',
            'retired'
        )),

    allows_parallel_use boolean not null default false,
    max_parallel_sessions integer not null default 1
        check (max_parallel_sessions >= 1),

    notes text,

    created_at timestamptz not null default now(),

    unique (well_id, public_code)
);
```

## 13.3 ربط المضخة بالخط

```sql
create table core.pump_line_links (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    pump_id uuid not null
        references core.pumps(id),

    water_line_id uuid not null
        references core.water_lines(id),

    effective_from timestamptz not null default now(),
    effective_to timestamptz,

    is_primary boolean not null default false,

    check (
        effective_to is null
        or effective_to > effective_from
    )
);
```

---

# 14. ملفات المزارعين

## 14.1 ملف المزارع

```sql
create table ops.farmer_profiles (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    person_id uuid not null
        references core.persons(id),

    status text not null default 'active'
        check (status in (
            'active',
            'inactive',
            'blocked',
            'archived'
        )),

    notes text,

    created_at timestamptz not null default now(),

    unique (tenant_id, person_id)
);
```

## 14.2 حساب المزارع في البئر

```sql
create table ops.farmer_well_accounts (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    farmer_profile_id uuid not null
        references ops.farmer_profiles(id),

    well_id uuid not null
        references core.wells(id),

    public_code text not null,

    status text not null default 'active'
        check (status in (
            'active',
            'inactive',
            'blocked',
            'archived'
        )),

    credit_limit_minor bigint,
    notes text,

    created_at timestamptz not null default now(),

    unique (farmer_profile_id, well_id),
    unique (well_id, public_code)
);
```

المزارع نفسه يمكن أن يمتلك حسابًا في أكثر من بئر دون تكرار بطاقة الشخص.

---

# 15. الأراضي والمواضع الزراعية

## 15.1 الأرض

```sql
create table ops.farms (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    public_code text not null,

    name text not null,
    normalized_name text not null,
    local_name text,

    location_id uuid
        references core.locations(id),

    area_value numeric(16,4),
    area_unit text,

    current_crop text,

    status text not null default 'active'
        check (status in (
            'active',
            'inactive',
            'archived'
        )),

    notes text,

    created_at timestamptz not null default now(),

    unique (tenant_id, public_code)
);
```

## 15.2 علاقة الشخص بالأرض

```sql
create table ops.farm_person_roles (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    farm_id uuid not null
        references ops.farms(id),

    person_id uuid not null
        references core.persons(id),

    relationship_type text not null
        check (relationship_type in (
            'owner',
            'tenant',
            'manager',
            'beneficiary',
            'other'
        )),

    is_primary boolean not null default false,

    effective_from date not null default current_date,
    effective_to date,

    check (
        effective_to is null
        or effective_to >= effective_from
    )
);
```

## 15.3 علاقة الأرض بالبئر

```sql
create table ops.farm_well_links (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    farm_id uuid not null
        references ops.farms(id),

    well_id uuid not null
        references core.wells(id),

    preferred_water_line_id uuid
        references core.water_lines(id),

    status text not null default 'active'
        check (status in (
            'active',
            'inactive'
        )),

    notes text,

    unique (farm_id, well_id)
);
```

---

# 16. الشركاء والملكية

## 16.1 الشريك

```sql
create table core.well_partners (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    well_id uuid not null
        references core.wells(id),

    person_id uuid not null
        references core.persons(id),

    status text not null default 'active'
        check (status in (
            'active',
            'inactive',
            'left',
            'archived'
        )),

    joined_at date,
    left_at date,

    notes text,

    created_at timestamptz not null default now(),

    unique (well_id, person_id)
);
```

## 16.2 تاريخ نسب الشريك

```sql
create table core.ownership_share_versions (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    well_id uuid not null
        references core.wells(id),

    partner_id uuid not null
        references core.well_partners(id),

    ownership_percentage numeric(9,6) not null
        check (
            ownership_percentage >= 0
            and ownership_percentage <= 100
        ),

    profit_percentage numeric(9,6) not null
        check (
            profit_percentage >= 0
            and profit_percentage <= 100
        ),

    effective_period daterange not null,

    approved_by uuid
        references iam.users(id),

    approval_notes text,

    created_at timestamptz not null default now()
);
```

منع تداخل فترتين للشريك نفسه:

```sql
alter table core.ownership_share_versions
add constraint no_partner_share_period_overlap
exclude using gist (
    partner_id with =,
    effective_period with &&
);
```

## 16.3 سياسة سقي الشريك

```sql
create table core.partner_irrigation_policies (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    well_id uuid not null
        references core.wells(id),

    partner_id uuid not null
        references core.well_partners(id),

    policy_type text not null
        check (policy_type in (
            'normal_customer',
            'deduct_from_profit',
            'free_hours',
            'special_price',
            'operating_cost_only',
            'fuel_only',
            'ownership_entitlement',
            'custom'
        )),

    effective_period daterange not null,

    free_minutes_per_cycle integer,
    special_solar_hour_rate_minor bigint,
    special_diesel_hour_rate_minor bigint,

    deduct_from_profit boolean not null default false,
    charge_fuel_only boolean not null default false,
    charge_operation_only boolean not null default false,

    custom_settings jsonb not null default '{}'::jsonb,

    approved_by uuid
        references iam.users(id),

    created_at timestamptz not null default now()
);
```

منع تداخل سياسات الشريك:

```sql
alter table core.partner_irrigation_policies
add constraint no_partner_policy_period_overlap
exclude using gist (
    partner_id with =,
    effective_period with &&
);
```

---

# 17. الأسعار

## 17.1 مجموعة الأسعار

```sql
create table ops.price_schedules (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    well_id uuid not null
        references core.wells(id),

    name text not null,

    effective_period tstzrange not null,

    status text not null default 'active'
        check (status in (
            'draft',
            'active',
            'expired',
            'cancelled'
        )),

    reason text,

    approved_by uuid
        references iam.users(id),

    created_at timestamptz not null default now()
);
```

## 17.2 قواعد السعر

```sql
create table ops.price_rules (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    price_schedule_id uuid not null
        references ops.price_schedules(id),

    energy_source text not null
        check (energy_source in (
            'solar',
            'well_diesel',
            'farmer_diesel'
        )),

    diesel_pricing_model text
        check (
            diesel_pricing_model is null
            or diesel_pricing_model in (
                'inclusive_hourly',
                'operation_plus_fuel'
            )
        ),

    hourly_rate_minor bigint
        check (
            hourly_rate_minor is null
            or hourly_rate_minor >= 0
        ),

    operation_hourly_rate_minor bigint
        check (
            operation_hourly_rate_minor is null
            or operation_hourly_rate_minor >= 0
        ),

    fuel_price_per_liter_minor bigint
        check (
            fuel_price_per_liter_minor is null
            or fuel_price_per_liter_minor >= 0
        ),

    -- ❌ حُذف minimum_billable_minutes بالقرار ق-16.
    -- السبب: شكل مقنّع من التقريب (فوترة وقت لم يُستهلك).

    created_at timestamptz not null default now(),

    unique (price_schedule_id, energy_source)
);
```

---

# 18. الحجوزات

```sql
create table ops.irrigation_bookings (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    public_code text not null,

    well_id uuid not null
        references core.wells(id),

    farmer_well_account_id uuid not null
        references ops.farmer_well_accounts(id),

    farm_id uuid
        references ops.farms(id),

    pump_id uuid
        references core.pumps(id),

    water_line_id uuid
        references core.water_lines(id),

    scheduled_start timestamptz not null,
    scheduled_end timestamptz not null,

    expected_duration_minutes integer not null
        check (expected_duration_minutes > 0),

    expected_energy_source text
        check (
            expected_energy_source is null
            or expected_energy_source in (
                'solar',
                'well_diesel',
                'farmer_diesel',
                'mixed'
            )
        ),

    status text not null default 'draft'
        check (status in (
            'draft',
            'pending',
            'confirmed',
            'waiting',
            'ready',
            'started',
            'completed',
            'postponed',
            'cancelled',
            'no_show'
        )),

    priority integer not null default 0,
    notes text,

    created_at timestamptz not null default now(),
    created_by uuid,

    check (scheduled_end > scheduled_start),

    unique (well_id, public_code)
);
```

## 18.1 تاريخ حالة الحجز

```sql
create table ops.booking_status_history (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    booking_id uuid not null
        references ops.irrigation_bookings(id),

    old_status text,
    new_status text not null,

    reason text,

    changed_at timestamptz not null default now(),
    changed_by uuid
        references iam.users(id)
);
```

---

# 19. حجز الموارد ومنع التعارض

لأن الحجز قد يستخدم مضخة أو خطًا، ننشئ جدولًا موحدًا لحجز الموارد:

```sql
create table ops.resource_reservations (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    well_id uuid not null
        references core.wells(id),

    resource_type text not null
        check (resource_type in (
            'pump',
            'water_line'
        )),

    resource_id uuid not null,

    booking_id uuid
        references ops.irrigation_bookings(id),

    session_id uuid,

    reserved_period tstzrange not null,

    status text not null
        check (status in (
            'active',
            'released',
            'cancelled'
        )),

    created_at timestamptz not null default now()
);
```

إذا كان المورد لا يسمح إلا بجلسة واحدة، يمنع التداخل عبر إجراء خادم قبل الاعتماد.

لا يفضل وضع قيد Exclusion ثابت على جميع الموارد؛ لأن بعض الخطوط قد تسمح بأكثر من جلسة مستقبلًا.

تتم إدارة التزامن من خلال دالة:

```text
reserve_resource(...)
```

تقرأ:

```text
max_parallel_sessions
```

ثم تقرر قبول الحجز أو رفضه.

---

# 20. جلسات السقي

```sql
create table ops.irrigation_sessions (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    public_code text not null,

    well_id uuid not null
        references core.wells(id),

    booking_id uuid
        references ops.irrigation_bookings(id),

    farmer_well_account_id uuid not null
        references ops.farmer_well_accounts(id),

    farm_id uuid
        references ops.farms(id),

    pump_id uuid
        references core.pumps(id),

    water_line_id uuid
        references core.water_lines(id),

    operator_user_id uuid not null
        references iam.users(id),

    status text not null default 'draft'
        check (status in (
            'draft',
            'running',
            'paused',
            'completed',
            'pending_review',
            'approved',
            'cancelled',
            'corrected'
        )),

    actual_started_at timestamptz,
    actual_ended_at timestamptz,

    actual_duration_minutes integer,
    raw_billable_minutes integer,
    final_billable_minutes integer,

    billing_status text not null default 'not_billed'
        check (billing_status in (
            'not_billed',
            'draft_invoice',
            'billed',
            'corrected'
        )),

    notes text,

    created_at timestamptz not null default now(),
    created_by uuid,

    updated_at timestamptz not null default now(),
    version bigint not null default 1,

    check (
        actual_ended_at is null
        or actual_started_at is null
        or actual_ended_at > actual_started_at
    ),

    unique (well_id, public_code)
);
```

---

# 21. مقاطع الجلسة

```sql
create table ops.session_segments (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    session_id uuid not null
        references ops.irrigation_sessions(id),

    sequence_number integer not null
        check (sequence_number > 0),

    segment_type text not null
        check (segment_type in (
            'solar_run',
            'well_diesel_run',
            'farmer_diesel_run',
            'billable_stop',
            'non_billable_stop',
            'breakdown',
            'operator_pause',
            'farmer_requested_pause',
            'source_change_pause'
        )),

    energy_source text
        check (
            energy_source is null
            or energy_source in (
                'solar',
                'well_diesel',
                'farmer_diesel'
            )
        ),

    started_at timestamptz not null,
    ended_at timestamptz,

    actual_minutes integer,
    raw_billable_minutes integer,

    is_billable boolean not null,

    fuel_owner_person_id uuid
        references core.persons(id),

    fuel_actual_ml bigint
        check (
            fuel_actual_ml is null
            or fuel_actual_ml >= 0
        ),

    fuel_estimated_ml bigint
        check (
            fuel_estimated_ml is null
            or fuel_estimated_ml >= 0
        ),

    fuel_measurement_type text
        check (
            fuel_measurement_type is null
            or fuel_measurement_type in (
                'actual',
                'estimated'
            )
        ),

    applied_price_rule_id uuid
        references ops.price_rules(id),

    applied_hourly_rate_minor bigint,
    applied_operation_rate_minor bigint,
    applied_fuel_price_per_liter_minor bigint,

    notes text,

    created_at timestamptz not null default now(),

    unique (session_id, sequence_number),

    check (
        ended_at is null
        or ended_at > started_at
    )
);
```

## 21.1 قاعدة عدم تداخل المقاطع

قبل حفظ أي مقطع، يتحقق الخادم من عدم تداخله مع مقطع آخر داخل الجلسة نفسها.

يمكن استخدام دالة:

```text
validate_session_segment_overlap(...)
```

---

# 22. ملخص حساب الجلسة

بدل إعادة الحساب عشوائيًا في كل شاشة، يتم إنشاء ملخص رسمي:

```sql
create table ops.session_billing_breakdowns (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    session_id uuid not null
        references ops.irrigation_sessions(id),

    energy_source text not null
        check (energy_source in (
            'solar',
            'well_diesel',
            'farmer_diesel'
        )),

    raw_minutes integer not null
        check (raw_minutes >= 0),

    rounded_minutes integer not null
        check (rounded_minutes >= 0),

    hourly_rate_minor bigint,
    operation_rate_minor bigint,
    fuel_quantity_ml bigint,
    fuel_price_per_liter_minor bigint,

    time_charge_minor bigint not null default 0,
    fuel_charge_minor bigint not null default 0,
    total_charge_minor bigint not null,

    price_rule_id uuid
        references ops.price_rules(id),

    calculated_at timestamptz not null default now(),

    unique (session_id, energy_source)
);
```

---

# 23. دالة حساب قيمة الوقت — بلا تقريب

> ❌ **حُذفت الدالة ops.ceil_to_quarter_hour بالكامل بالقرار ق-12.**

حلّت محلها دالة تحسب القيمة مباشرة من الثواني، بوحدة الجزء من الألف من الريال:

```sql
create or replace function ops.time_charge_milli(
    billable_seconds bigint,
    hourly_rate_milli bigint
)
returns bigint
language sql
immutable
as $$
    select case
        when billable_seconds <= 0 or hourly_rate_milli <= 0 then 0
        else (billable_seconds * hourly_rate_milli) / 3600
    end;
$$;
```

أمثلة (سعر الساعة 5,000 ريال = 5000000 جزء من الألف):

```sql
-- 62 دقيقة = 3720 ثانية
select ops.time_charge_milli(3720, 5000000);  -- 5166666  أي 5166.666 ريال

-- 93 دقيقة = 5580 ثانية
select ops.time_charge_milli(5580, 5000000);  -- 7750000  أي 7750.000 ريال

-- ثانية واحدة
select ops.time_charge_milli(1, 5000000);     -- 1388     أي 1.388 ريال
```

القسمة تتم **مرة واحدة في النهاية** وليس على مراحل، لمنع تراكم فقد الكسور.

---

# 24. خزانات الوقود

```sql
create table inventory.fuel_tanks (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    well_id uuid not null
        references core.wells(id),

    public_code text not null,
    name text not null,

    capacity_ml bigint
        check (
            capacity_ml is null
            or capacity_ml > 0
        ),

    measurement_method text not null default 'manual'
        check (measurement_method in (
            'manual',
            'dipstick',
            'meter',
            'estimated'
        )),

    status text not null default 'active'
        check (status in (
            'active',
            'inactive',
            'maintenance',
            'retired'
        )),

    created_at timestamptz not null default now(),

    unique (well_id, public_code)
);
```

---

# 25. حركات الوقود

```sql
create table inventory.fuel_transactions (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    public_code text not null,

    well_id uuid not null
        references core.wells(id),

    fuel_tank_id uuid
        references inventory.fuel_tanks(id),

    transaction_type text not null
        check (transaction_type in (
            'purchase',
            'farmer_deposit',
            'session_consumption',
            'farmer_return',
            'adjustment_in',
            'adjustment_out',
            'leakage',
            'loss',
            'opening_balance',
            'physical_count'
        )),

    ownership_type text not null
        check (ownership_type in (
            'well',
            'farmer'
        )),

    owner_person_id uuid
        references core.persons(id),

    farmer_well_account_id uuid
        references ops.farmer_well_accounts(id),

    quantity_ml bigint not null
        check (quantity_ml > 0),

    direction text not null
        check (direction in (
            'in',
            'out'
        )),

    measurement_type text not null
        check (measurement_type in (
            'actual',
            'estimated'
        )),

    unit_cost_per_liter_minor bigint,
    total_cost_minor bigint,

    session_segment_id uuid
        references ops.session_segments(id),

    expense_id uuid,

    occurred_at timestamptz not null,

    status text not null default 'posted'
        check (status in (
            'draft',
            'pending_actual_measurement',
            'posted',
            'reversed'
        )),

    notes text,

    created_at timestamptz not null default now(),
    created_by uuid,

    unique (well_id, public_code),

    check (
        ownership_type = 'well'
        or owner_person_id is not null
    )
);
```

---

# 26. التصحيح المحاسبي لشراء الديزل

شراء الديزل ليس مصروفًا مباشرًا بالكامل عند الشراء.

عند شراء `1000` لتر:

```text
يزيد مخزون الديزل
ينخفض الصندوق
```

القيد:

```text
مدين: مخزون ديزل البئر
دائن: صندوق البئر
```

عند استهلاك الديزل:

```text
مدين: تكلفة ديزل مستهلك
دائن: مخزون ديزل البئر
```

هذا يسمح بمعرفة:

* قيمة المخزون المتبقي.
* تكلفة الديزل المستخدم.
* الربح الحقيقي من التشغيل بالديزل.

## 26.1 طريقة تقييم المخزون

التوصية للنسخة الأولى:

> المتوسط المرجح المتحرك.

مثال:

```text
المخزون القديم:
100 لتر × 500 ريال = 50,000

شراء جديد:
100 لتر × 700 ريال = 70,000

المجموع:
200 لتر بقيمة 120,000

متوسط اللتر:
600 ريال
```

كل استهلاك تالٍ يستخدم تكلفة `600 ريال` للتر حتى تتم عملية شراء جديدة.

---

# 27. الفواتير

```sql
create table billing.invoices (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    public_code text not null,
    sequence_number bigint,

    well_id uuid not null
        references core.wells(id),

    farmer_well_account_id uuid not null
        references ops.farmer_well_accounts(id),

    session_id uuid
        references ops.irrigation_sessions(id),

    invoice_date timestamptz not null,

    status text not null default 'draft'
        check (status in (
            'draft',
            'issued',
            'partially_paid',
            'paid',
            'overdue',
            'cancelled',
            'reversed'
        )),

    currency_code char(3) not null default 'YER',

    subtotal_minor bigint not null default 0,
    total_minor bigint not null default 0,

    paid_minor bigint not null default 0,
    outstanding_minor bigint not null default 0,

    settlement_method text not null default 'normal'
        check (settlement_method in (
            'normal',
            'partner_profit_offset',
            'free_entitlement',
            'special_policy'
        )),

    partner_policy_id uuid
        references core.partner_irrigation_policies(id),

    issued_at timestamptz,
    issued_by uuid
        references iam.users(id),

    reversed_invoice_id uuid
        references billing.invoices(id),

    notes text,

    created_at timestamptz not null default now(),

    unique (well_id, public_code),

    check (subtotal_minor >= 0),
    check (total_minor >= 0),
    check (paid_minor >= 0),
    check (outstanding_minor >= 0),
    check (paid_minor + outstanding_minor = total_minor)
);
```

## 27.1 بنود الفاتورة

```sql
create table billing.invoice_lines (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    invoice_id uuid not null
        references billing.invoices(id),

    line_number integer not null
        check (line_number > 0),

    line_type text not null
        check (line_type in (
            'solar_irrigation',
            'diesel_operation',
            'diesel_fuel',
            'partner_adjustment',
            'additional_fee',
            'opening_balance',
            'manual_adjustment'
        )),

    description text not null,

    quantity numeric(18,6) not null,
    unit text not null,
    unit_price_minor bigint not null,

    amount_minor bigint not null,

    session_segment_id uuid
        references ops.session_segments(id),

    created_at timestamptz not null default now(),

    unique (invoice_id, line_number)
);
```

---

# 28. الدفعات

```sql
create table billing.payments (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    public_code text not null,

    well_id uuid not null
        references core.wells(id),

    farmer_well_account_id uuid not null
        references ops.farmer_well_accounts(id),

    payer_person_id uuid
        references core.persons(id),

    amount_minor bigint not null
        check (amount_minor > 0),

    currency_code char(3) not null default 'YER',

    payment_method text not null
        check (payment_method in (
            'cash',
            'bank_transfer',
            'mobile_wallet',
            'advance_balance',
            'partner_profit_offset',
            'other'
        )),

    cashbox_id uuid,

    payment_date timestamptz not null,

    status text not null default 'posted'
        check (status in (
            'draft',
            'posted',
            'reversed'
        )),

    reference text,
    notes text,

    received_by uuid
        references iam.users(id),

    reversed_payment_id uuid
        references billing.payments(id),

    created_at timestamptz not null default now(),

    unique (well_id, public_code)
);
```

## 28.1 تخصيص الدفعات للفواتير

```sql
create table billing.payment_allocations (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    payment_id uuid not null
        references billing.payments(id),

    invoice_id uuid not null
        references billing.invoices(id),

    allocated_minor bigint not null
        check (allocated_minor > 0),

    created_at timestamptz not null default now(),

    unique (payment_id, invoice_id)
);
```

## 28.2 الرصيد المقدم

الرصيد المقدم لا يحتاج جدول رصيد يدوي.

يحسب من:

```text
إجمالي دفعات المزارع
-
إجمالي المبالغ المخصصة لفواتيره
-
المبالغ المعادة له
```

إذا كانت النتيجة موجبة، فهذا رصيد مقدم.

---

# 29. الصناديق

```sql
create table finance.cashboxes (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    well_id uuid not null
        references core.wells(id),

    public_code text not null,
    name text not null,

    cashbox_type text not null
        check (cashbox_type in (
            'main_well',
            'operator_custody',
            'shift_cashbox',
            'petty_cash'
        )),

    assigned_user_id uuid
        references iam.users(id),

    status text not null default 'active'
        check (status in (
            'active',
            'inactive',
            'closed'
        )),

    created_at timestamptz not null default now(),

    unique (well_id, public_code)
);
```

بعد إنشاء الجدول، يضاف المفتاح إلى الدفعات:

```sql
alter table billing.payments
add constraint fk_payment_cashbox
foreign key (cashbox_id)
references finance.cashboxes(id);
```

---

# 30. دليل الحسابات

```sql
create table finance.ledger_accounts (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    well_id uuid
        references core.wells(id),

    account_code text not null,
    name_ar text not null,
    name_en text,

    account_type text not null
        check (account_type in (
            'asset',
            'liability',
            'equity',
            'revenue',
            'expense'
        )),

    normal_balance text not null
        check (normal_balance in (
            'debit',
            'credit'
        )),

    parent_account_id uuid
        references finance.ledger_accounts(id),

    is_system_account boolean not null default false,
    is_postable boolean not null default true,
    status text not null default 'active',

    created_at timestamptz not null default now(),

    unique (tenant_id, well_id, account_code)
);
```

## 30.1 الحسابات الأساسية لكل بئر

```text
1000 النقد والصناديق
1100 ديون المزارعين
1200 مخزون ديزل البئر
2000 أرصدة مقدمة للمزارعين
2100 مستحقات الشركاء
2200 رواتب مستحقة
2300 مصروفات مستحقة
2400 مبالغ مستحقة لشركاء
2500 احتياطي الصيانة
3000 رأس المال
3100 أرباح متراكمة
3200 أرباح قابلة للتوزيع
4000 إيراد سقي شمسي
4100 إيراد تشغيل ديزل
4200 إيراد وقود
4300 إيرادات أخرى
5000 تكلفة ديزل مستهلك
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

# 31. القيود اليومية

```sql
create table finance.journal_entries (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    public_code text not null,

    well_id uuid not null
        references core.wells(id),

    entry_date timestamptz not null,

    status text not null default 'draft'
        check (status in (
            'draft',
            'posted',
            'reversed'
        )),

    source_type text not null,
    source_id uuid not null,

    description text not null,

    idempotency_key text not null,

    posted_at timestamptz,
    posted_by uuid
        references iam.users(id),

    reversal_of_entry_id uuid
        references finance.journal_entries(id),

    created_at timestamptz not null default now(),

    unique (tenant_id, idempotency_key),
    unique (well_id, source_type, source_id)
);
```

## 31.1 أطراف القيد

```sql
create table finance.journal_lines (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    journal_entry_id uuid not null
        references finance.journal_entries(id),

    ledger_account_id uuid not null
        references finance.ledger_accounts(id),

    entry_side text not null
        check (entry_side in (
            'debit',
            'credit'
        )),

    amount_minor bigint not null
        check (amount_minor > 0),

    person_id uuid
        references core.persons(id),

    farmer_well_account_id uuid
        references ops.farmer_well_accounts(id),

    partner_id uuid
        references core.well_partners(id),

    cashbox_id uuid
        references finance.cashboxes(id),

    fuel_tank_id uuid
        references inventory.fuel_tanks(id),

    description text,

    created_at timestamptz not null default now()
);
```

---

# 32. قاعدة توازن القيد

لا يسمح بترحيل القيد إذا:

```text
مجموع المدين ≠ مجموع الدائن
```

يجب بناء دالة:

```text
finance.post_journal_entry(entry_id)
```

تقوم بالآتي داخل Transaction واحدة:

1. التأكد أن القيد مسودة.
2. جمع المدين.
3. جمع الدائن.
4. التأكد من التطابق.
5. التأكد من عدم إغلاق الفترة.
6. ضبط الحالة إلى `posted`.
7. منع أي تعديل لاحق.

لا ينبغي أن يسمح تطبيق الهاتف بترحيل القيود مباشرة؛ بل يستدعي إجراءً آمنًا على الخادم.

---

# 33. أمثلة القيود

## 33.1 إصدار فاتورة سقي بقيمة `20,000`

```text
مدين:
ديون المزارعين             20,000

دائن:
إيراد السقي                20,000
```

## 33.2 دفع `8,000` نقدًا

```text
مدين:
صندوق البئر                 8,000

دائن:
ديون المزارعين              8,000
```

## 33.3 دفع مقدم

```text
مدين:
صندوق البئر                10,000

دائن:
أرصدة مقدمة للمزارعين      10,000
```

## 33.4 استخدام الرصيد المقدم

```text
مدين:
أرصدة مقدمة للمزارعين      10,000

دائن:
ديون المزارعين             10,000
```

## 33.5 شراء ديزل

```text
مدين:
مخزون ديزل البئر           70,000

دائن:
صندوق البئر                70,000
```

## 33.6 استهلاك ديزل تكلفته `15,000`

```text
مدين:
تكلفة ديزل مستهلك          15,000

دائن:
مخزون ديزل البئر           15,000
```

## 33.7 مصروف دفعه شريك

```text
مدين:
مصروف الصيانة              15,000

دائن:
مستحق للشريك               15,000
```

---

# 34. المصروفات

```sql
create table finance.expense_categories (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    code text not null,
    name_ar text not null,

    ledger_account_id uuid not null
        references finance.ledger_accounts(id),

    is_active boolean not null default true,

    unique (tenant_id, code)
);
```

```sql
create table finance.expenses (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    public_code text not null,

    well_id uuid not null
        references core.wells(id),

    category_id uuid not null
        references finance.expense_categories(id),

    expense_date timestamptz not null,

    description text not null,

    amount_minor bigint not null
        check (amount_minor > 0),

    payment_source text not null
        check (payment_source in (
            'cashbox',
            'partner_paid',
            'unpaid_payable',
            'other'
        )),

    cashbox_id uuid
        references finance.cashboxes(id),

    paid_by_person_id uuid
        references core.persons(id),

    status text not null default 'draft'
        check (status in (
            'draft',
            'pending_approval',
            'approved',
            'rejected',
            'posted',
            'reversed'
        )),

    requires_approval boolean not null default true,
    attachment_required boolean not null default false,

    created_by uuid
        references iam.users(id),

    created_at timestamptz not null default now(),

    unique (well_id, public_code)
);
```

---

# 35. اعتماد المصروفات

## 35.1 قواعد الاعتماد

```sql
create table finance.expense_approval_rules (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    well_id uuid not null
        references core.wells(id),

    category_id uuid
        references finance.expense_categories(id),

    minimum_amount_minor bigint not null default 0,
    maximum_amount_minor bigint,

    required_approval_count integer not null default 1
        check (required_approval_count >= 0),

    required_role_code text,

    attachment_required boolean not null default false,

    effective_period daterange not null,

    created_at timestamptz not null default now(),

    check (
        maximum_amount_minor is null
        or maximum_amount_minor >= minimum_amount_minor
    )
);
```

## 35.2 قرارات الاعتماد

```sql
create table finance.expense_approvals (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    expense_id uuid not null
        references finance.expenses(id),

    approver_user_id uuid not null
        references iam.users(id),

    decision text not null
        check (decision in (
            'approved',
            'rejected'
        )),

    notes text,

    decided_at timestamptz not null default now(),

    unique (expense_id, approver_user_id)
);
```

---

# 36. النوبات وتسليم الصندوق

## 36.1 النوبة

```sql
create table ops.shifts (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    public_code text not null,

    well_id uuid not null
        references core.wells(id),

    operator_user_id uuid not null
        references iam.users(id),

    cashbox_id uuid
        references finance.cashboxes(id),

    started_at timestamptz not null,
    ended_at timestamptz,

    status text not null default 'open'
        check (status in (
            'open',
            'handover_pending',
            'closed',
            'cancelled'
        )),

    opening_cash_minor bigint not null default 0,
    expected_closing_cash_minor bigint,
    actual_closing_cash_minor bigint,
    cash_difference_minor bigint,

    created_at timestamptz not null default now(),

    unique (well_id, public_code),

    check (
        ended_at is null
        or ended_at > started_at
    )
);
```

## 36.2 التسليم والاستلام

```sql
create table ops.shift_handovers (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    shift_id uuid not null
        references ops.shifts(id),

    from_user_id uuid not null
        references iam.users(id),

    to_user_id uuid
        references iam.users(id),

    expected_cash_minor bigint not null,
    actual_cash_minor bigint not null,
    cash_difference_minor bigint not null,

    fuel_balance_ml bigint,

    open_sessions_count integer not null default 0,
    pending_operations_count integer not null default 0,

    status text not null default 'draft'
        check (status in (
            'draft',
            'submitted',
            'accepted',
            'accepted_with_difference',
            'rejected'
        )),

    notes text,

    submitted_at timestamptz,
    accepted_at timestamptz,

    created_at timestamptz not null default now()
);
```

---

# 37. الفترات المحاسبية

```sql
create table finance.accounting_periods (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    well_id uuid not null
        references core.wells(id),

    period_type text not null
        check (period_type in (
            'daily',
            'weekly',
            'monthly',
            'quarterly',
            'annual',
            'custom'
        )),

    starts_at timestamptz not null,
    ends_at timestamptz not null,

    status text not null default 'open'
        check (status in (
            'open',
            'reviewing',
            'closed',
            'reopened'
        )),

    closed_at timestamptz,
    closed_by uuid
        references iam.users(id),

    reopened_at timestamptz,
    reopened_by uuid
        references iam.users(id),

    reopening_reason text,

    created_at timestamptz not null default now(),

    check (ends_at > starts_at)
);
```

لا يسمح بترحيل قيد داخل فترة مغلقة إلا عبر:

* إعادة فتح الفترة بصلاحية خاصة.
* أو تسجيل قيد تصحيح في فترة جديدة.

---

# 38. احتياطي الصيانة

```sql
create table finance.maintenance_reserve_rules (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    well_id uuid not null
        references core.wells(id),

    reserve_type text not null
        check (reserve_type in (
            'percentage_of_collections',
            'percentage_of_profit',
            'fixed_amount',
            'manual_per_cycle',
            'disabled'
        )),

    reserve_percentage numeric(9,6),
    fixed_amount_minor bigint,

    effective_period daterange not null,

    created_at timestamptz not null default now()
);
```

---

# 39. دورات توزيع الأرباح

```sql
create table finance.profit_distribution_cycles (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    public_code text not null,

    well_id uuid not null
        references core.wells(id),

    period_start timestamptz not null,
    period_end timestamptz not null,

    status text not null default 'draft'
        check (status in (
            'draft',
            'calculated',
            'under_review',
            'approved',
            'partially_paid',
            'paid',
            'cancelled'
        )),

    eligible_collections_minor bigint not null default 0,
    eligible_cash_expenses_minor bigint not null default 0,
    reserved_liabilities_minor bigint not null default 0,
    maintenance_reserve_minor bigint not null default 0,

    distributable_amount_minor bigint not null default 0,

    calculated_at timestamptz,
    calculated_by uuid
        references iam.users(id),

    approved_at timestamptz,
    approved_by uuid
        references iam.users(id),

    created_at timestamptz not null default now(),

    unique (well_id, public_code),

    check (period_end > period_start)
);
```

## 39.1 تفاصيل كل شريك

```sql
create table finance.profit_distribution_lines (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    distribution_cycle_id uuid not null
        references finance.profit_distribution_cycles(id),

    partner_id uuid not null
        references core.well_partners(id),

    profit_percentage_snapshot numeric(9,6) not null,

    gross_share_minor bigint not null default 0,

    partner_receivables_minor bigint not null default 0,
    irrigation_deductions_minor bigint not null default 0,
    other_deductions_minor bigint not null default 0,

    net_payable_minor bigint not null default 0,

    status text not null default 'calculated'
        check (status in (
            'calculated',
            'approved',
            'partially_paid',
            'paid',
            'carried_forward'
        )),

    created_at timestamptz not null default now(),

    unique (distribution_cycle_id, partner_id)
);
```

---

# 40. معادلة المال القابل للتوزيع

لا يستخدم النظام جميع الإيرادات المستحقة.

يستخدم الأموال المحصلة فقط:

```text
المبلغ القابل للتوزيع =
المبالغ المحصلة المؤهلة
- المصروفات النقدية المؤهلة
- الالتزامات المحتجزة
- احتياطي الصيانة
- مستحقات واجبة قبل التوزيع
```

ثم:

```text
حصة الشريك =
المبلغ القابل للتوزيع
× نسبة أرباح الشريك
```

ثم:

```text
صافي مستحق الشريك =
الحصة الإجمالية
+ مبالغ مستحقة له
- قيمة سقيه
- الاستقطاعات الأخرى
```

---

# 41. الأرصدة الافتتاحية

## 41.1 مجموعة إدخال أرصدة

```sql
create table finance.opening_balance_batches (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    well_id uuid not null
        references core.wells(id),

    reference_date date not null,

    status text not null default 'draft'
        check (status in (
            'draft',
            'pending_approval',
            'approved',
            'posted',
            'reversed'
        )),

    notes text,

    created_by uuid
        references iam.users(id),

    approved_by uuid
        references iam.users(id),

    created_at timestamptz not null default now()
);
```

## 41.2 عناصر الرصيد

```sql
create table finance.opening_balance_items (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    batch_id uuid not null
        references finance.opening_balance_batches(id),

    item_type text not null
        check (item_type in (
            'farmer_debt',
            'farmer_advance',
            'cashbox_balance',
            'fuel_tank_balance',
            'partner_payable',
            'partner_receivable',
            'salary_payable',
            'expense_payable',
            'capital_balance'
        )),

    person_id uuid
        references core.persons(id),

    farmer_well_account_id uuid
        references ops.farmer_well_accounts(id),

    partner_id uuid
        references core.well_partners(id),

    cashbox_id uuid
        references finance.cashboxes(id),

    fuel_tank_id uuid
        references inventory.fuel_tanks(id),

    amount_minor bigint,
    quantity_ml bigint,

    description text,

    created_at timestamptz not null default now()
);
```

---

# 42. المرفقات

```sql
create table core.attachments (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    well_id uuid
        references core.wells(id),

    entity_type text not null,
    entity_id uuid not null,

    storage_bucket text not null,
    storage_path text not null,

    original_file_name text,
    mime_type text,
    file_size_bytes bigint,

    upload_status text not null default 'pending'
        check (upload_status in (
            'pending',
            'uploaded',
            'failed',
            'deleted'
        )),

    created_at timestamptz not null default now(),
    created_by uuid
        references iam.users(id)
);
```

---

# 43. سجل التدقيق

```sql
create table audit.audit_logs (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    well_id uuid
        references core.wells(id),

    user_id uuid
        references iam.users(id),

    device_id uuid
        references iam.user_devices(id),

    action text not null,
    entity_type text not null,
    entity_id uuid not null,

    old_values jsonb,
    new_values jsonb,

    reason text,

    client_timestamp timestamptz,
    server_timestamp timestamptz not null default now(),

    ip_address inet,
    app_version text
);
```

سجل التدقيق يجب أن يكون:

* Append-Only.
* ممنوع التعديل.
* ممنوع الحذف من المستخدمين.
* قابلًا للقراءة فقط لمن يملك صلاحية.

---

# 44. أوامر المزامنة ومنع التكرار

```sql
create table sync.processed_commands (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    command_id uuid not null,
    command_type text not null,

    entity_id uuid,

    status text not null
        check (status in (
            'processing',
            'accepted',
            'rejected',
            'conflict'
        )),

    request_payload jsonb,
    response_payload jsonb,

    processed_at timestamptz not null default now(),

    unique (tenant_id, command_id)
);
```

إذا أرسل الهاتف الأمر نفسه عدة مرات:

```text
command_id = نفسه
```

يعيد الخادم النتيجة السابقة، ولا ينفذ العملية مرة أخرى.

---

# 45. تعارضات المزامنة

```sql
create table sync.sync_conflicts (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references core.tenants(id),

    well_id uuid
        references core.wells(id),

    entity_type text not null,
    entity_id uuid not null,

    server_version bigint not null,
    client_version bigint not null,

    server_data jsonb not null,
    client_data jsonb not null,

    status text not null default 'open'
        check (status in (
            'open',
            'resolved_server',
            'resolved_client',
            'merged',
            'discarded'
        )),

    resolved_by uuid
        references iam.users(id),

    resolved_at timestamptz,
    resolution_notes text,

    created_at timestamptz not null default now()
);
```

---

# 46. أهم إجراءات الخادم

يجب ألا يعتمد النظام على إضافة وتعديل الصفوف مباشرة في العمليات الحساسة.

يجب بناء إجراءات آمنة مثل:

```text
create_farmer(...)
merge_persons(...)
create_farm(...)
create_booking(...)
reschedule_booking(...)
start_irrigation_session(...)
pause_irrigation_session(...)
change_session_energy_source(...)
resume_irrigation_session(...)
complete_irrigation_session(...)
calculate_session_billing(...)
issue_session_invoice(...)
record_payment(...)
allocate_payment(...)
reverse_payment(...)
create_expense(...)
approve_expense(...)
post_expense(...)
purchase_fuel(...)
record_fuel_consumption(...)
record_physical_fuel_count(...)
close_shift(...)
handover_shift(...)
close_accounting_period(...)
reopen_accounting_period(...)
calculate_profit_distribution(...)
approve_profit_distribution(...)
pay_partner_distribution(...)
reverse_journal_entry(...)
```

كل إجراء يجب أن يعمل داخل:

```sql
begin;
...
commit;
```

أو يتراجع بالكامل:

```sql
rollback;
```

إذا حدث خطأ.

---

# 47. إجراء إنهاء جلسة السقي

الإجراء:

```text
complete_irrigation_session(...)
```

ينفذ بالترتيب:

1. يتأكد أن الجلسة تعمل أو متوقفة.
2. يغلق آخر مقطع مفتوح.
3. يتحقق من ترتيب المقاطع.
4. يمنع تداخل المقاطع.
5. يحسب مدة كل مقطع.
6. يستبعد التوقفات غير المحتسبة.
7. يجمع الدقائق حسب مصدر الطاقة.
8. يقرب كل مصدر إلى الربع الأعلى.
9. يبحث عن السعر الساري لكل مقطع.
10. يحسب الشمس.
11. يحسب تشغيل الديزل.
12. يحسب الوقود.
13. يطبق سياسة الشريك.
14. ينشئ ملخص الحساب.
15. ينشئ فاتورة مسودة.
16. يخصم الوقود المستهلك من المخزون.
17. يثبت زمن النهاية.
18. يحرر المضخة والخط.
19. يسجل العملية في Audit Log.
20. يعيد ملخصًا للمشغل للمراجعة.

بعد تأكيد المشغل:

```text
issue_session_invoice(...)
```

يصدر الفاتورة ويرحل القيد المالي.

---

# 48. إجراء تسجيل دفعة

الإجراء:

```text
record_payment(...)
```

ينفذ:

1. يتحقق من صلاحية المستخدم.
2. يتحقق من البئر والمزارع.
3. يتحقق من أن المبلغ أكبر من صفر.
4. يتحقق من الصندوق عند الدفع النقدي.
5. ينشئ الدفعة.
6. يخصصها للفواتير المختارة.
7. يرفض تخصيص مبلغ أكبر من قيمة الدفعة.
8. يرفض تخصيص مبلغ أكبر من الدين.
9. يحول المتبقي إلى رصيد مقدم.
10. ينشئ القيد المالي.
11. يحدث حالات الفواتير.
12. يسجل Audit Log.
13. يصدر إيصالًا.

---

# 49. إجراء توزيع الأرباح

الإجراء:

```text
calculate_profit_distribution(...)
```

ينفذ:

1. يتحقق من الفترة.
2. يمنع وجود فترة متداخلة غير مغلقة.
3. يجمع المقبوضات المؤهلة.
4. يستبعد الأرصدة المقدمة غير المستخدمة.
5. يجمع المصروفات النقدية المؤهلة.
6. يحسب الالتزامات.
7. يحسب احتياطي الصيانة.
8. يحسب المال القابل للتوزيع.
9. يستخرج نسب الشركاء الفعالة.
10. يتحقق أن مجموع نسب الأرباح `100%`.
11. ينسخ النسب داخل أسطر التوزيع.
12. يحسب حصة كل شريك.
13. يجلب استقطاعات سقي الشريك.
14. يجلب المبالغ المستحقة للشريك.
15. يحسب الصافي.
16. يمنع اعتماد التوزيع إذا كانت هناك مشكلة.
17. يعرض مسودة للمراجعة.

بعد الاعتماد:

```text
approve_profit_distribution(...)
```

ينشئ قيود مستحقات الشركاء.

---

# 50. سياسات RLS

يجب تفعيل RLS على جميع جداول البيانات الحساسة:

```sql
alter table core.wells enable row level security;
alter table core.persons enable row level security;
alter table ops.irrigation_sessions enable row level security;
alter table billing.invoices enable row level security;
alter table finance.journal_entries enable row level security;
```

## 50.1 قاعدة العميل

المستخدم لا يرى إلا سجلات عميله:

```text
record.tenant_id = current_user.tenant_id
```

## 50.2 قاعدة البئر

المستخدم لا يرى البئر إلا إذا كان عضوًا فيه.

## 50.3 قاعدة الصلاحية

الرؤية لا تعني التعديل.

مثال:

* الشريك يشاهد التوزيع.
* المشغل لا يغيره.
* المحاسب ينشئه.
* المدير يعتمده.

## 50.4 دالة مساعدة

يجب إنشاء دالة مثل:

```text
iam.has_well_permission(
    well_id,
    permission_code
)
```

وتستخدم في سياسات RLS وإجراءات الخادم.

---

# 51. التقارير المحسوبة

يجب بناء Views، وليس تخزين أرصدة نهائية يدويًا.

## 51.1 رصيد المزارع

```text
reporting.farmer_account_balances
```

يعرض:

* إجمالي الفواتير.
* إجمالي الدفعات المستخدمة.
* الدين المتبقي.
* الرصيد المقدم.
* صافي الرصيد.

## 51.2 رصيد الصندوق

```text
reporting.cashbox_balances
```

يعتمد على القيود المرتبطة بالصندوق.

## 51.3 رصيد الوقود

```text
reporting.fuel_balances
```

يعرض:

* وقود البئر.
* رصيد كل مزارع.
* الفعلي.
* التقديري.
* الفروقات.

## 51.4 حساب الشريك

```text
reporting.partner_account_summary
```

يعرض:

* الأرباح.
* استقطاعات السقي.
* مصروفات دفعها.
* المدفوع.
* المتبقي.

## 51.5 التقرير اليومي

```text
reporting.well_daily_summary
```

يعرض:

* عدد الجلسات.
* ساعات الشمس.
* ساعات الديزل.
* الإيرادات المستحقة.
* المقبوضات.
* الديون.
* المصروفات.
* الصندوق.
* الوقود.
* التوقفات.

---

# 52. الفهارس الأساسية

```sql
create index idx_persons_tenant_name
on core.persons (tenant_id, normalized_name);

create index idx_farmer_accounts_well
on ops.farmer_well_accounts (well_id, status);

create index idx_farms_tenant_name
on ops.farms (tenant_id, normalized_name);

create index idx_bookings_well_start
on ops.irrigation_bookings (
    well_id,
    scheduled_start
);

create index idx_sessions_well_status
on ops.irrigation_sessions (
    well_id,
    status
);

create index idx_segments_session_sequence
on ops.session_segments (
    session_id,
    sequence_number
);

create index idx_invoices_farmer_status
on billing.invoices (
    farmer_well_account_id,
    status
);

create index idx_payments_farmer_date
on billing.payments (
    farmer_well_account_id,
    payment_date
);

create index idx_fuel_transactions_tank_date
on inventory.fuel_transactions (
    fuel_tank_id,
    occurred_at
);

create index idx_journal_entries_well_date
on finance.journal_entries (
    well_id,
    entry_date
);

create index idx_journal_lines_account
on finance.journal_lines (
    ledger_account_id
);

create index idx_audit_entity
on audit.audit_logs (
    entity_type,
    entity_id,
    server_timestamp
);
```

---

# 53. قواعد لا يجوز تنفيذها في الواجهة فقط

القواعد التالية يجب أن يفرضها الخادم وقاعدة البيانات:

1. منع تكرار العملية عبر `command_id`.
2. منع ترحيل قيد غير متوازن.
3. منع تعديل قيد مرحل.
4. منع إصدار فاتورتين للجلسة نفسها.
5. منع تخصيص دفعة بأكثر من قيمتها.
6. منع دفع فاتورة ملغاة.
7. منع استخدام ديزل مزارع لمزارع آخر.
8. منع تجاوز `100%` في نسب الشركاء.
9. منع توزيع الأرباح دون نسب مكتملة.
10. منع التعديل داخل فترة مغلقة.
11. منع حذف دفعة أو مصروف.
12. منع تعديل السعر القديم بصمت.
13. منع تداخل سياسة شريك مع سياسة أخرى.
14. منع تداخل نسبة شريك تاريخيًا.
15. منع تداخل مقاطع الجلسة.
16. منع تشغيل مورد غير متاح.
17. منع مخزون وقود سالب دون صلاحية.
18. منع المستخدم من الوصول إلى بئر غير مصرح له.

---

# 54. ترتيب بناء قاعدة البيانات

## المرحلة الأولى: الأساس

1. Extensions.
2. Schemas.
3. Tenants.
4. Persons.
5. Contacts.
6. Users.
7. Roles.
8. Permissions.
9. Locations.
10. Wells.
11. Well Settings.
12. User-Well Roles.

## المرحلة الثانية: التشغيل

1. Pumps.
2. Water Lines.
3. Farmer Profiles.
4. Farmer Well Accounts.
5. Farms.
6. Farm-Person Relations.
7. Partners.
8. Ownership Versions.
9. Partner Policies.
10. Price Schedules.
11. Bookings.
12. Sessions.
13. Segments.

## المرحلة الثالثة: المخزون

1. Fuel Tanks.
2. Fuel Transactions.
3. Weighted Average Cost Function.
4. Fuel Balance Views.
5. Farmer Fuel Balance Views.

## المرحلة الرابعة: المال

1. Ledger Accounts.
2. Journal Entries.
3. Journal Lines.
4. Cashboxes.
5. Invoices.
6. Invoice Lines.
7. Payments.
8. Payment Allocations.
9. Posting Procedures.

## المرحلة الخامسة: الإدارة المالية

1. Expenses.
2. Expense Approvals.
3. Shifts.
4. Handovers.
5. Accounting Periods.
6. Reserves.
7. Distributions.
8. Opening Balances.

## المرحلة السادسة: الأمان والمزامنة

1. RLS.
2. Audit Log.
3. Processed Commands.
4. Sync Conflicts.
5. Attachments.
6. Reporting Views.
7. PowerSync Sync Rules.

---

# 55. اختبارات قاعدة البيانات الإلزامية

يجب إنشاء اختبارات تلقائية للحالات التالية:

1. إنشاء مزارع دون هاتف.
2. إنشاء مزارعين بالاسم نفسه.
3. منع دمج تلقائي.
4. إضافة عدة أراضٍ للمزارع.
5. إضافة أرض أثناء جلسة.
6. جلسة تبدأ قبل منتصف الليل وتنتهي بعده.
7. مدة `1` دقيقة تصبح `15`.
8. مدة `15` تبقى `15`.
9. مدة `16` تصبح `30`.
10. توقف غير محسوب.
11. جلسة شمس وديزل.
12. تغيير المصدر عدة مرات.
13. لا تقريب لأي مصدر أو مقطع؛ الحساب يعتمد الزمن الفعلي.
14. ديزل فعلي وتقديري.
15. استخدام رصيد ديزل المزارع نفسه.
16. رفض استخدامه لمزارع آخر.
17. شراء وقود وتحديث المتوسط المرجح.
18. دفع كامل.
19. دفع جزئي.
20. دفع زائد وتحويل الفرق إلى مقدم.
21. دفع شخص عن مزارع.
22. عكس دفعة.
23. مصروف نقدي.
24. مصروف دفعه شريك.
25. قيد غير متوازن.
26. إرسال العملية نفسها مرتين.
27. تغيير نسبة شريك بتاريخ جديد.
28. منع تداخل النسب.
29. سياسة خصم السقي من الأرباح.
30. أرباح أقل من استقطاعات الشريك.
31. إغلاق فترة.
32. رفض التعديل بعد الإغلاق.
33. إعادة فتح فترة بصلاحية.
34. حساب مال محصل فقط للتوزيع.
35. احتياطي صيانة.
36. فرق صندوق في النوبة.
37. تعارض تعديل من جهازين.
38. مستخدم يحاول الوصول إلى بئر غير مصرح له.

---

# 56. النتيجة المعمارية

بهذا التصميم يصبح لدينا نظام يحافظ على:

* هوية المزارع دون تكرار.
* تعدد أراضي المزارع.
* تاريخ ملكية الشركاء.
* تاريخ الأسعار.
* سياسات سقي الشركاء.
* جلسات شمسية وديزل ومختلطة.
* التوقفات المحسوبة وغير المحسوبة.
* مخزون وقود مالي وكمي.
* أرصدة وقود مستقلة للمزارعين.
* فواتير ودفعات مستقلة.
* دفع جزئي ومقدم.
* دفتر مالي متوازن.
* صندوق كل بئر أو مشغل.
* مصروفات معتمدة.
* إقفال فترات.
* توزيع أموال محصلة فقط.
* منع تكرار العمليات دون إنترنت.
* سجل تدقيق كامل.
* عزل بيانات العملاء.
* صلاحيات دقيقة لكل بئر.

# 57. الخطوة التنفيذية التالية

بعد اعتماد هذا المخطط، يتم إنشاء ملفات Migrations فعلية بهذا الترتيب:

```text
001_extensions_and_schemas.sql
002_tenants_and_subscriptions.sql
003_persons_and_identity.sql
004_users_roles_permissions.sql
005_wells_locations_resources.sql
006_farmers_and_farms.sql
007_partners_and_ownership.sql
008_pricing.sql
009_bookings_and_sessions.sql
010_fuel_inventory.sql
011_ledger_and_cashboxes.sql
012_invoices_and_payments.sql
013_expenses_and_approvals.sql
014_shifts_and_handovers.sql
015_periods_and_distributions.sql
016_audit_and_sync.sql
017_functions_and_triggers.sql
018_rls_policies.sql
019_reporting_views.sql
020_seed_system_accounts.sql
```

ثم يبنى **المحرك المالي التطبيقي** فوق هذه الجداول على شكل إجراءات PostgreSQL ودوال Backend واختبارات تلقائية، وليس مجرد حسابات داخل شاشات Flutter.

## ق-80 — Farm / Farmer identity override

الحالة الحالية المنفذة بعد Migration 075:

- الأرض لا ترتبط بـ`iam.profiles`.
- العلاقة الحالية هي `ops.farms.farmer_well_account_id`.
- Farmer Well Account يحدد المزارع داخل البئر.
- أي وصف تاريخي يربط `ops.farms.farmer_profile_id`
  بحساب دخول أصبح منسوخًا بق-80.
- Booking/Session يجب أن يطابقا حساب المزارع المرتبط بالأرض.

## ق-81 — Pump model override

الحالة المنفذة بعد Migration 076:

- `core.pumps` هو Equipment Metadata.
- `power_source` ليس مصدر الحقيقة التشغيلي الحديث.
- مصدر الطاقة للجلسات الحديثة هو `ops.session_segments.energy_source`.
- Solar/Diesel reporting يعتمد المقاطع.
- الجلسات `flat` التاريخية بلا مقاطع تستخدم legacy fallback فقط.
- قواعد توازي المضخة تؤخذ من `ops.resource_concurrency_rules`.
