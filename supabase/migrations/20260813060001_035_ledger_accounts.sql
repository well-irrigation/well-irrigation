-- دليل الحسابات (وثيقة 03 القسم 30)
-- تصحيح موثّق: لا يوجد check على status في النص الحرفي، فلم يُضف (التزام بالنص).
create table finance.ledger_accounts (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references core.tenants(id),
    well_id uuid references core.wells(id),
    account_code text not null,
    name_ar text not null,
    name_en text,
    account_type text not null
        check (account_type in ('asset', 'liability', 'equity', 'revenue', 'expense')),
    normal_balance text not null
        check (normal_balance in ('debit', 'credit')),
    parent_account_id uuid references finance.ledger_accounts(id),
    is_system_account boolean not null default false,
    is_postable boolean not null default true,
    status text not null default 'active',
    created_at timestamptz not null default now(),
    unique (tenant_id, well_id, account_code)
);
alter table finance.ledger_accounts enable row level security;

create index ledger_accounts_well_idx on finance.ledger_accounts (well_id, account_code);

-- الحسابات الأساسية لكل بئر (وثيقة 03 القسم 30.1 — الأسماء والأرقام حرفيًا)
-- تنبيه: الدالة نفسها غير موجودة في الوثائق، صياغتها استنتاج من قائمة القسم 30.1.
create or replace function finance.create_default_ledger_accounts(p_well_id uuid)
returns integer
language plpgsql
security definer
set search_path = finance, core, public
as $$
declare
    v_tenant_id uuid;
    v_count integer := 0;
begin
    select tenant_id into v_tenant_id from core.wells where id = p_well_id;
    if v_tenant_id is null then
        raise exception 'البئر غير موجود: %', p_well_id;
    end if;

    insert into finance.ledger_accounts
        (tenant_id, well_id, account_code, name_ar, account_type, normal_balance, is_system_account)
    select v_tenant_id, p_well_id, a.code, a.name_ar, a.acct_type, a.nb, true
    from (values
        ('1000', 'النقد والصناديق',        'asset',     'debit'),
        ('1100', 'ديون المزارعين',         'asset',     'debit'),
        ('1200', 'مخزون ديزل البئر',       'asset',     'debit'),
        ('2000', 'أرصدة مقدمة للمزارعين',  'liability', 'credit'),
        ('2100', 'مستحقات الشركاء',        'liability', 'credit'),
        ('2200', 'رواتب مستحقة',           'liability', 'credit'),
        ('2300', 'مصروفات مستحقة',         'liability', 'credit'),
        ('2400', 'مبالغ مستحقة لشركاء',    'liability', 'credit'),
        ('2500', 'احتياطي الصيانة',        'liability', 'credit'),
        ('3000', 'رأس المال',              'equity',    'credit'),
        ('3100', 'أرباح متراكمة',          'equity',    'credit'),
        ('3200', 'أرباح قابلة للتوزيع',    'equity',    'credit'),
        ('4000', 'إيراد سقي شمسي',         'revenue',   'credit'),
        ('4100', 'إيراد تشغيل ديزل',       'revenue',   'credit'),
        ('4200', 'إيراد وقود',             'revenue',   'credit'),
        ('4300', 'إيرادات أخرى',           'revenue',   'credit'),
        ('5000', 'تكلفة ديزل مستهلك',      'expense',   'debit'),
        ('5100', 'مصروف صيانة',            'expense',   'debit'),
        ('5200', 'مصروف زيت',              'expense',   'debit'),
        ('5300', 'قطع غيار',               'expense',   'debit'),
        ('5400', 'رواتب',                  'expense',   'debit'),
        ('5500', 'نقل',                    'expense',   'debit'),
        ('5600', 'حراسة',                  'expense',   'debit'),
        ('5700', 'مصروفات إدارية',         'expense',   'debit'),
        ('5800', 'فروقات مخزون',           'expense',   'debit'),
        ('5900', 'مصروفات أخرى',           'expense',   'debit')
    ) as a(code, name_ar, acct_type, nb)
    on conflict (tenant_id, well_id, account_code) do nothing;

    get diagnostics v_count = row_count;
    return v_count;
end;
$$;

-- الدفتر المالي بيانات حساسة: للمالك فقط (نفس منطق التسعير)
-- فجوة موثّقة: حسابات على مستوى العميل (well_id فارغ) غير مرئية بهذه السياسات.
create policy ledger_accounts_select_owner on finance.ledger_accounts for select using (
    well_id is not null and iam.has_well_role(well_id, array['owner'])
);
create policy ledger_accounts_insert_owner on finance.ledger_accounts for insert with check (
    well_id is not null and iam.has_well_role(well_id, array['owner'])
);
create policy ledger_accounts_update_owner on finance.ledger_accounts for update using (
    well_id is not null and iam.has_well_role(well_id, array['owner'])
);

grant select, insert, update on finance.ledger_accounts to authenticated;
grant execute on function finance.create_default_ledger_accounts(uuid) to authenticated;
