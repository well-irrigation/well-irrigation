-- دالة مساعدة: هل للمستخدم الحالي المسجل دخوله اي دور نشط من قائمة محددة على بئر معين
-- security definer لتفادي حلقة تحقق لا نهائية حين تُفعَّل الصلاحيات لاحقا على جدول الادوار نفسه
create or replace function iam.has_well_role(p_well_id uuid, p_roles text[])
returns boolean
language sql
security definer
stable
set search_path = core, pg_temp
as $$
    select exists (
        select 1
        from core.well_assignments wa
        where wa.well_id = p_well_id
          and wa.profile_id = auth.uid()
          and wa.status = 'active'
          and wa.role = any(p_roles)
    );
$$;

-- core.wells: لا يظهر البئر الا لمن له اي دور نشط عليه
create policy wells_select_assigned
    on core.wells for select
    using (iam.has_well_role(id, array['owner', 'operator', 'farmer']));

-- core.tenants: لا يظهر المستاجر الا لمن له دور نشط على اي بئر ضمنه
create policy tenants_select_assigned
    on core.tenants for select
    using (
        exists (
            select 1
            from core.wells w
            where w.tenant_id = tenants.id
              and iam.has_well_role(w.id, array['owner', 'operator', 'farmer'])
        )
    );
