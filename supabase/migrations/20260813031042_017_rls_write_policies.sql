-- تصحيح: يجب ان تعمل دالة حساب التكلفة التلقائي بصلاحيات معرّفها (security definer)
-- والا سترفض RLS ادخال المستخدم العادي للتكلفة عند اغلاقه جلسة حقيقية
create or replace function ops.compute_session_charge()
returns trigger
language plpgsql
security definer
set search_path = ops, billing, pg_temp
as $$
declare
    v_duration_seconds integer;
    v_price_per_hour_milli bigint;
    v_amount_milli bigint;
begin
    if new.status in ('closed', 'forgotten') and new.ended_at is not null
       and old.status = 'open' then

        v_duration_seconds := extract(epoch from (new.ended_at - new.started_at))::integer;

        select price_per_hour_milli into v_price_per_hour_milli
        from billing.well_pricing
        where well_id = new.well_id
          and period_start <= new.ended_at
          and (period_end is null or period_end > new.ended_at)
        order by period_start desc
        limit 1;

        if v_price_per_hour_milli is null then
            raise exception 'لا يوجد سعر فعال للبئر % في وقت اغلاق الجلسة %، لا يمكن حساب التكلفة ولا اغلاق الجلسة', new.well_id, new.id;
        end if;

        v_amount_milli := (v_duration_seconds::bigint * v_price_per_hour_milli) / 3600;

        insert into billing.session_charges (session_id, well_id, duration_seconds, price_per_hour_milli, amount_milli)
        values (new.id, new.well_id, v_duration_seconds, v_price_per_hour_milli, v_amount_milli);
    end if;

    return new;
end;
$$;
-- عمدا: لا توجد اي قاعدة كتابة على billing.session_charges لأي مستخدم عادي - فقط الدالة اعلاه تكتب فيه

grant insert, update, delete on all tables in schema core, iam, ops, billing, finance, inventory to authenticated;

-- core.wells: الانشاء متاح لاي مستخدم مسجل دخوله حاليا (سيُقيَّد اكثر عند بناء تدفق التسجيل لاحقا)، والتعديل حصرا للمالك
create policy wells_insert_authenticated on core.wells for insert with check (auth.uid() is not null);
create policy wells_update_owner on core.wells for update using (iam.has_well_role(id, array['owner']));

-- core.tenants: نفس منطق الانشاء المؤقت، والتعديل حصرا لمالك اي بئر ضمنه
create policy tenants_insert_authenticated on core.tenants for insert with check (auth.uid() is not null);
create policy tenants_update_owner on core.tenants for update using (
    exists (select 1 from core.wells w where w.tenant_id = tenants.id and iam.has_well_role(w.id, array['owner']))
);

-- core.well_settings: المالك فقط يضبط اعدادات التنبيهات
create policy well_settings_insert_owner on core.well_settings for insert with check (iam.has_well_role(well_id, array['owner']));
create policy well_settings_update_owner on core.well_settings for update using (iam.has_well_role(well_id, array['owner']));

-- core.well_assignments: المالك فقط يدير فريقه بالكامل
create policy well_assignments_insert_owner on core.well_assignments for insert with check (iam.has_well_role(well_id, array['owner']));
create policy well_assignments_update_owner on core.well_assignments for update using (iam.has_well_role(well_id, array['owner']));
create policy well_assignments_delete_owner on core.well_assignments for delete using (iam.has_well_role(well_id, array['owner']));

-- core.well_ownership_shares: المالك فقط يدير هيكل الملكية (الحارس الرياضي للمجموع يبقى فعالا دوما)
create policy well_ownership_shares_insert_owner on core.well_ownership_shares for insert with check (iam.has_well_role(well_id, array['owner']));
create policy well_ownership_shares_update_owner on core.well_ownership_shares for update using (iam.has_well_role(well_id, array['owner']));

-- core.pumps: المالك فقط يضيف/يعدل/يحذف المعدات
create policy pumps_insert_owner on core.pumps for insert with check (iam.has_well_role(well_id, array['owner']));
create policy pumps_update_owner on core.pumps for update using (iam.has_well_role(well_id, array['owner']));
create policy pumps_delete_owner on core.pumps for delete using (iam.has_well_role(well_id, array['owner']));

-- ops.farms: المالك فقط يضيف/يعدل (لا حذف، تُعطَّل بالحالة بدل الحذف)
create policy farms_insert_owner on ops.farms for insert with check (iam.has_well_role(well_id, array['owner']));
create policy farms_update_owner on ops.farms for update using (iam.has_well_role(well_id, array['owner']));

-- ops.irrigation_sessions: المالك او المشغل فقط يفتحون ويغلقون الجلسات (لا حذف ابدا، سجل تدقيق دائم)
create policy irrigation_sessions_insert_operator on ops.irrigation_sessions for insert with check (iam.has_well_role(well_id, array['owner', 'operator']));
create policy irrigation_sessions_update_operator on ops.irrigation_sessions for update using (iam.has_well_role(well_id, array['owner', 'operator']));

-- billing.well_pricing: المالك فقط (لا حذف، الاسعار القديمة تُغلق بتاريخ نهاية فقط)
create policy well_pricing_insert_owner on billing.well_pricing for insert with check (iam.has_well_role(well_id, array['owner']));
create policy well_pricing_update_owner on billing.well_pricing for update using (iam.has_well_role(well_id, array['owner']));

-- billing.payments: المالك او المشغل فقط يسجلون استلام الدفعة (لا تعديل ولا حذف ابدا، سجل مالي ثابت)
create policy payments_insert_operator on billing.payments for insert with check (
    exists (select 1 from billing.session_charges sc where sc.id = session_charge_id and iam.has_well_role(sc.well_id, array['owner', 'operator']))
);

-- inventory.fuel_purchases: المالك او المشغل فقط
create policy fuel_purchases_insert_operator on inventory.fuel_purchases for insert with check (iam.has_well_role(well_id, array['owner', 'operator']));
create policy fuel_purchases_update_operator on inventory.fuel_purchases for update using (iam.has_well_role(well_id, array['owner', 'operator']));

-- finance.distribution_batches / distribution_lines: المالك فقط (الحارس الرياضي للتطابق يبقى فعالا دوما)
create policy distribution_batches_insert_owner on finance.distribution_batches for insert with check (iam.has_well_role(well_id, array['owner']));
create policy distribution_batches_update_owner on finance.distribution_batches for update using (iam.has_well_role(well_id, array['owner']));
create policy distribution_lines_insert_owner on finance.distribution_lines for insert with check (
    exists (select 1 from finance.distribution_batches b where b.id = batch_id and iam.has_well_role(b.well_id, array['owner']))
);

-- iam.profiles: كل شخص يعدل ملفه الشخصي فقط، ولا يمكنه ابدا تعديل ملف شخص اخر
create policy profiles_update_self on iam.profiles for update using (id = auth.uid());
