-- كل مستاجر يمثل حساب مالك ابار مستقل داخل التطبيق
create table core.tenants (
    id uuid primary key default gen_random_uuid(),
    name text not null,
    timezone text not null default 'Asia/Aden',
    status text not null default 'active' check (status in ('active', 'suspended')),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

-- تفعيل الحماية على مستوى الصف الان، بلا سياسات بعد، ستضاف لاحقا مع نظام الصلاحيات
alter table core.tenants enable row level security;
