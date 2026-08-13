-- منح صلاحية القراءة الاساسية على كل الجداول المتبقية دفعة واحدة (التحكم الفعلي بيد RLS)
grant select on all tables in schema core, iam, ops, billing, finance, inventory to authenticated;

-- اعدادات تنبيهات البئر: للمالك والمشغل فقط (لا حاجة للمزارع)
create policy well_settings_select_assigned
    on core.well_settings for select
    using (iam.has_well_role(well_id, array['owner', 'operator']));

-- سجل تعيين الادوار: يراه مالك البئر لادارة فريقه، او الشخص نفسه لسطره الخاص
create policy well_assignments_select_assigned
    on core.well_assignments for select
    using (iam.has_well_role(well_id, array['owner']) or profile_id = auth.uid());

-- حصص الملكية: بيانات مالية حساسة، للمالك فقط
create policy well_ownership_shares_select_owner
    on core.well_ownership_shares for select
    using (iam.has_well_role(well_id, array['owner']));

-- المضخات: بيانات تشغيلية، لكل الادوار الثلاثة
create policy pumps_select_assigned
    on core.pumps for select
    using (iam.has_well_role(well_id, array['owner', 'operator', 'farmer']));

-- المزارع: بيانات تشغيلية، لكل الادوار الثلاثة
create policy farms_select_assigned
    on ops.farms for select
    using (iam.has_well_role(well_id, array['owner', 'operator', 'farmer']));

-- جلسات السقي: لكل الادوار الثلاثة على مستوى البئر
create policy irrigation_sessions_select_assigned
    on ops.irrigation_sessions for select
    using (iam.has_well_role(well_id, array['owner', 'operator', 'farmer']));

-- التسعير: بيانات تجارية حساسة، للمالك فقط
create policy well_pricing_select_owner
    on billing.well_pricing for select
    using (iam.has_well_role(well_id, array['owner']));

-- تكلفة الجلسات: لكل الادوار الثلاثة على مستوى البئر
create policy session_charges_select_assigned
    on billing.session_charges for select
    using (iam.has_well_role(well_id, array['owner', 'operator', 'farmer']));

-- المدفوعات: للمالك والمشغل (من يستلم ويعتمد الدفع)
create policy payments_select_assigned
    on billing.payments for select
    using (
        exists (
            select 1 from billing.session_charges sc
            where sc.id = payments.session_charge_id
              and iam.has_well_role(sc.well_id, array['owner', 'operator'])
        )
    );

-- مشتريات الوقود: للمالك والمشغل
create policy fuel_purchases_select_assigned
    on inventory.fuel_purchases for select
    using (iam.has_well_role(well_id, array['owner', 'operator']));

-- دفعات توزيع الارباح: للمالك فقط (بيانات ربح حساسة)
create policy distribution_batches_select_owner
    on finance.distribution_batches for select
    using (iam.has_well_role(well_id, array['owner']));

-- اسطر توزيع الارباح: لمالكي البئر المرتبط بالدفعة
create policy distribution_lines_select_owner
    on finance.distribution_lines for select
    using (
        exists (
            select 1 from finance.distribution_batches b
            where b.id = distribution_lines.batch_id
              and iam.has_well_role(b.well_id, array['owner'])
        )
    );

-- الملفات الشخصية: يرى الشخص نفسه، او اي زميل يشاركه بئرا واحدا على الاقل
create policy profiles_select_self_or_colleague
    on iam.profiles for select
    using (
        id = auth.uid()
        or exists (
            select 1
            from core.well_assignments mine
            join core.well_assignments theirs on theirs.well_id = mine.well_id
            where mine.profile_id = auth.uid()
              and mine.status = 'active'
              and theirs.profile_id = profiles.id
              and theirs.status = 'active'
        )
    );
