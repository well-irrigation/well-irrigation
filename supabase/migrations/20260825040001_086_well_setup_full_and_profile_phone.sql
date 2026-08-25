-- =====================================================================
-- 086 — ق-85: تهيئة البئر الشاملة وحفظ الشركاء والمشغلين والتسعير والمضخة ورقم الهاتف
-- =====================================================================

-- 1) تحديث محرك إنشاء الملف الشخصي لحفظ رقم الهاتف تلقائياً في iam.profiles
create or replace function iam.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = iam, pg_temp
as $$
begin
    insert into iam.profiles (id, full_name, phone)
    values (
      new.id,
      coalesce(new.raw_user_meta_data->>'full_name', ''),
      coalesce(new.raw_user_meta_data->>'phone', new.phone)
    )
    on conflict (id) do update
    set full_name = excluded.full_name,
        phone = coalesce(excluded.phone, iam.profiles.phone);
    return new;
end;
$$;

-- معالجة السجلات السابقة التي كان حقل الهاتف فيها فارغاً
update iam.profiles p
set phone = coalesce(u.raw_user_meta_data->>'phone', u.phone)
from auth.users u
where p.id = u.id and p.phone is null and (u.raw_user_meta_data->>'phone' is not null or u.phone is not null);


-- 2) دالة التهيئة الشاملة للبئر بكل تفاصيله ومكوناته ذرّياً
create or replace function core.setup_well_full(
  p_setup_data jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'core', 'ops', 'iam', 'pg_temp'
as $function$
declare
  v_user_id uuid := auth.uid();
  v_owner_profile record;
  v_tenant_id uuid;
  v_well_id uuid;
  v_well_name text;
  v_location text;
  v_pump_name text;
  v_power_source text;
  v_ps_id uuid;
  v_solar_rate bigint;
  v_well_diesel_rate bigint;
  v_farmer_diesel_rate bigint;
  v_owner_equity numeric;
  v_owner_profit numeric;
  v_owner_person_id uuid;
  v_owner_partner_id uuid;
  v_partner jsonb;
  v_partner_person_id uuid;
  v_partner_id uuid;
  v_operator jsonb;
  v_op_person_id uuid;
  v_op_profile_id uuid;
begin
  if v_user_id is null then
    raise exception 'يجب تسجيل الدخول قبل إنشاء وتجهيز البئر' using errcode = '28000';
  end if;

  select * into v_owner_profile
  from iam.profiles
  where id = v_user_id;

  if v_owner_profile is null then
    raise exception 'لا يوجد ملف مستخدم صالح للحساب المسجل' using errcode = 'P0002';
  end if;

  v_well_name := btrim(coalesce(p_setup_data->>'well_name', ''));
  if v_well_name = '' then
    raise exception 'اسم البئر مطلوب' using errcode = '22023';
  end if;

  v_location := nullif(btrim(coalesce(p_setup_data->>'location', '')), '');

  -- 1) إنشاء الجهة والبئر
  insert into core.tenants (name)
  values (v_well_name)
  returning id into v_tenant_id;

  insert into core.wells (tenant_id, name, location)
  values (v_tenant_id, v_well_name, v_location)
  returning id into v_well_id;

  -- 2) تعيين المالك على البئر
  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_well_id, v_user_id, 'owner', 'active');

  -- 3) إضافة المضخة الأساسية
  v_pump_name := coalesce(nullif(btrim(p_setup_data->>'pump_name'), ''), 'المضخة الرئيسية');
  v_power_source := coalesce(nullif(btrim(p_setup_data->>'pump_power_source'), ''), 'diesel');
  if v_power_source not in ('diesel', 'electric', 'solar') then
    v_power_source := 'diesel';
  end if;

  insert into core.pumps (well_id, name, power_source, status)
  values (v_well_id, v_pump_name, v_power_source, 'active');

  -- 4) جدول التسعير الافتراضي
  v_solar_rate := (p_setup_data->'pricing'->>'solar_rate_minor')::bigint;
  v_well_diesel_rate := (p_setup_data->'pricing'->>'well_diesel_rate_minor')::bigint;
  v_farmer_diesel_rate := (p_setup_data->'pricing'->>'farmer_diesel_rate_minor')::bigint;

  insert into ops.price_schedules (
    tenant_id, well_id, name, effective_period, status, approved_by
  ) values (
    v_tenant_id, v_well_id, 'الجدول الافتراضي للتسعير',
    tstzrange(now() - interval '1 hour', null), 'active', v_user_id
  ) returning id into v_ps_id;

  if v_solar_rate is not null and v_solar_rate > 0 then
    insert into ops.price_rules (
      tenant_id, price_schedule_id, energy_source, hourly_rate_minor
    ) values (
      v_tenant_id, v_ps_id, 'solar', v_solar_rate
    );
  end if;

  if v_well_diesel_rate is not null and v_well_diesel_rate > 0 then
    insert into ops.price_rules (
      tenant_id, price_schedule_id, energy_source, diesel_pricing_model, hourly_rate_minor
    ) values (
      v_tenant_id, v_ps_id, 'well_diesel', 'inclusive_hourly', v_well_diesel_rate
    );
  end if;

  if v_farmer_diesel_rate is not null and v_farmer_diesel_rate > 0 then
    insert into ops.price_rules (
      tenant_id, price_schedule_id, energy_source, hourly_rate_minor
    ) values (
      v_tenant_id, v_ps_id, 'farmer_diesel', v_farmer_diesel_rate
    );
  end if;

  -- 5) إنشاء سجل شخص وشريك للمالك وحصته
  v_owner_equity := coalesce((p_setup_data->>'owner_equity_share')::numeric, 100.0);
  v_owner_profit := coalesce((p_setup_data->>'owner_profit_share')::numeric, v_owner_equity);

  insert into core.persons (
    tenant_id, full_name, normalized_name, created_by, updated_by
  ) values (
    v_tenant_id, v_owner_profile.full_name, v_owner_profile.full_name, v_user_id, v_user_id
  ) returning id into v_owner_person_id;

  if v_owner_profile.phone is not null and v_owner_profile.phone <> '' then
    insert into core.person_contacts (
      tenant_id, person_id, contact_type, contact_value, normalized_value, is_primary
    ) values (
      v_tenant_id, v_owner_person_id, 'mobile', v_owner_profile.phone, v_owner_profile.phone, true
    );
  end if;

  insert into core.well_partners (
    tenant_id, well_id, person_id, profile_id, phone, status, period_start
  ) values (
    v_tenant_id, v_well_id, v_owner_person_id, v_user_id,
    coalesce(v_owner_profile.phone, ''), 'active', current_date
  ) returning id into v_owner_partner_id;

  insert into core.ownership_share_versions (
    tenant_id, well_id, partner_id, ownership_percentage, profit_percentage,
    effective_period, approved_by
  ) values (
    v_tenant_id, v_well_id, v_owner_partner_id, v_owner_equity, v_owner_profit,
    daterange(current_date, null), v_user_id
  );

  -- 6) الشركاء الإضافيون
  if p_setup_data->'partners' is not null and jsonb_typeof(p_setup_data->'partners') = 'array' then
    for v_partner in select * from jsonb_array_elements(p_setup_data->'partners') loop
      declare
        v_p_name text := btrim(coalesce(v_partner->>'full_name', ''));
        v_p_phone text := btrim(coalesce(v_partner->>'phone', ''));
        v_p_equity numeric := coalesce((v_partner->>'equity_share')::numeric, 0);
        v_p_profit numeric := coalesce((v_partner->>'profit_share')::numeric, v_p_equity);
      begin
        if v_p_name <> '' and v_p_equity > 0 then
          insert into core.persons (
            tenant_id, full_name, normalized_name, created_by, updated_by
          ) values (
            v_tenant_id, v_p_name, v_p_name, v_user_id, v_user_id
          ) returning id into v_partner_person_id;

          if v_p_phone <> '' then
            insert into core.person_contacts (
              tenant_id, person_id, contact_type, contact_value, normalized_value, is_primary
            ) values (
              v_tenant_id, v_partner_person_id, 'mobile', v_p_phone, v_p_phone, true
            );
          end if;

          insert into core.well_partners (
            tenant_id, well_id, person_id, phone, status, period_start
          ) values (
            v_tenant_id, v_well_id, v_partner_person_id, v_p_phone, 'active', current_date
          ) returning id into v_partner_id;

          insert into core.ownership_share_versions (
            tenant_id, well_id, partner_id, ownership_percentage, profit_percentage,
            effective_period, approved_by
          ) values (
            v_tenant_id, v_well_id, v_partner_id, v_p_equity, v_p_profit,
            daterange(current_date, null), v_user_id
          );
        end if;
      end;
    end loop;
  end if;

  -- 7) المشغلون
  if p_setup_data->'operators' is not null and jsonb_typeof(p_setup_data->'operators') = 'array' then
    for v_operator in select * from jsonb_array_elements(p_setup_data->'operators') loop
      declare
        v_op_name text := btrim(coalesce(v_operator->>'full_name', ''));
        v_op_phone text := btrim(coalesce(v_operator->>'phone', ''));
      begin
        if v_op_name <> '' then
          insert into core.persons (
            tenant_id, full_name, normalized_name, created_by, updated_by
          ) values (
            v_tenant_id, v_op_name, v_op_name, v_user_id, v_user_id
          ) returning id into v_op_person_id;

          if v_op_phone <> '' then
            insert into core.person_contacts (
              tenant_id, person_id, contact_type, contact_value, normalized_value, is_primary
            ) values (
              v_tenant_id, v_op_person_id, 'mobile', v_op_phone, v_op_phone, true
            );

            -- فحص إذا كان للمشغل حساب دخول مسبق لربطه في well_assignments
            select id into v_op_profile_id
            from iam.profiles
            where phone = v_op_phone
            limit 1;

            if v_op_profile_id is not null then
              insert into core.well_assignments (
                well_id, profile_id, role, status
              ) values (
                v_well_id, v_op_profile_id, 'operator', 'active'
              ) on conflict do nothing;
            end if;
          end if;
        end if;
      end;
    end loop;
  end if;

  return jsonb_build_object(
    'tenant_id', v_tenant_id,
    'well_id', v_well_id,
    'well_name', v_well_name,
    'status', 'success'
  );
end;
$function$;

create or replace function api.setup_well_full(
  p_setup_data jsonb
)
returns jsonb
language sql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
  select core.setup_well_full(p_setup_data);
$function$;

revoke all on function core.setup_well_full(jsonb) from public;

revoke all on function api.setup_well_full(jsonb) from public;
grant execute on function api.setup_well_full(jsonb) to authenticated;
grant execute on function api.setup_well_full(jsonb) to service_role;


