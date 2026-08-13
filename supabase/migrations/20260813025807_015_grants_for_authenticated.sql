-- RLS وحدها لا تكفي: يجب ايضا منح صلاحية الوصول الاساسية على مستوى المخطط والجدول
-- للمستخدمين المسجلين دخولهم، والتحكم الفعلي بالصفوف يبقى بيد سياسات RLS
grant usage on schema core, iam, ops, billing, finance, inventory to authenticated;
grant select on core.wells, core.tenants to authenticated;
