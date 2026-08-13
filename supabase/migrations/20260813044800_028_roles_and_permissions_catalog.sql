-- كتالوج الادوار والصلاحيات النظامي (القسم 9 من المخطط التنفيذي)
-- ملاحظة صريحة: هذا كتالوج تأسيسي فقط في هذه الدفعة، غير مربوط بعد بجدول core.well_assignments.role
-- الحالي (النص المباشر owner/operator/farmer) ولا بسياسات RLS الحالية.
-- الربط الفعلي قرار منفصل قادم لانه يتطلب مراجعة اكثر من 15 سياسة RLS مطبقة ومختبرة فعليا حاليا.
create table iam.roles (
    id uuid primary key default gen_random_uuid(),
    code text not null unique,
    name_ar text not null,
    name_en text,
    is_system_role boolean not null default true
);

alter table iam.roles enable row level security;

create table iam.permissions (
    id uuid primary key default gen_random_uuid(),
    code text not null unique,
    description_ar text not null
);

alter table iam.permissions enable row level security;

create table iam.role_permissions (
    role_id uuid not null references iam.roles(id),
    permission_id uuid not null references iam.permissions(id),
    primary key (role_id, permission_id)
);

alter table iam.role_permissions enable row level security;

-- الادوار الاساسية (القسم 9.1)
insert into iam.roles (code, name_ar, name_en) values
    ('tenant_owner', 'مالك حساب المنصة', 'Tenant Owner'),
    ('well_manager', 'مدير البئر', 'Well Manager'),
    ('operator', 'المشغل الميداني', 'Operator'),
    ('accountant', 'المحاسب', 'Accountant'),
    ('partner', 'الشريك', 'Partner'),
    ('viewer', 'المراقب', 'Viewer');

-- الصلاحيات الاساسية كامثلة (القسم 9.2)
insert into iam.permissions (code, description_ar) values
    ('farmer.create', 'إنشاء مزارع'),
    ('farmer.update', 'تعديل بيانات مزارع'),
    ('farmer.merge', 'دمج بطاقتي مزارع مكررتين'),
    ('farm.create', 'إنشاء أرض'),
    ('booking.create', 'إنشاء حجز'),
    ('booking.reschedule', 'إعادة جدولة حجز'),
    ('session.start', 'بدء جلسة سقي'),
    ('session.pause', 'إيقاف جلسة سقي مؤقتا'),
    ('session.complete', 'إنهاء جلسة سقي'),
    ('session.correct', 'تصحيح جلسة سقي'),
    ('payment.create', 'تسجيل دفعة'),
    ('payment.reverse', 'عكس دفعة'),
    ('expense.create', 'تسجيل مصروف'),
    ('expense.approve', 'اعتماد مصروف'),
    ('price.manage', 'إدارة الأسعار'),
    ('ownership.manage', 'إدارة نسب الملكية'),
    ('period.close', 'إقفال فترة محاسبية'),
    ('period.reopen', 'إعادة فتح فترة محاسبية'),
    ('distribution.calculate', 'حساب توزيع الأرباح'),
    ('distribution.approve', 'اعتماد توزيع الأرباح'),
    ('audit.view', 'عرض سجل التدقيق');

-- القراءة: كتالوج عام، يراه كل مستخدم مسجل دخوله (لا بيانات حساسة فيه)
create policy roles_select_authenticated on iam.roles for select using (auth.uid() is not null);
create policy permissions_select_authenticated on iam.permissions for select using (auth.uid() is not null);
create policy role_permissions_select_authenticated on iam.role_permissions for select using (auth.uid() is not null);

-- عمدا: لا سياسة كتابة لاي مستخدم عادي - كتالوج نظامي يدار من قاعدة البيانات مباشرة فقط
grant select on iam.roles, iam.permissions, iam.role_permissions to authenticated;
