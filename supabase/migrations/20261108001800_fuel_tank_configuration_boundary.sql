begin;
-- Owner-adopted metadata administration only. Quantities/costs remain internal.
create table inventory.fuel_tank_configuration_history(
 id uuid primary key default gen_random_uuid(),
 tenant_id uuid not null references core.tenants(id),well_id uuid not null references core.wells(id),
 fuel_tank_id uuid not null references inventory.fuel_tanks(id),
 before_configuration jsonb,after_configuration jsonb not null,
 actor_id uuid not null references iam.profiles(id),accepted_at timestamptz not null default clock_timestamp()
);
alter table inventory.fuel_tank_configuration_history enable row level security;
revoke all on inventory.fuel_tank_configuration_history from public,anon,authenticated,service_role;
grant select on inventory.fuel_tank_configuration_history to authenticated;
create policy fuel_tank_configuration_read on inventory.fuel_tank_configuration_history for select to authenticated
 using(iam.has_well_role(well_id,array['owner','manager','operator']) or iam.is_well_partner(well_id));
create function inventory.reject_fuel_tank_configuration_history_mutation() returns trigger
language plpgsql set search_path=pg_catalog,pg_temp as $$
begin raise exception 'fuel_tank_configuration_history_append_only' using errcode='23514';end;$$;
create trigger fuel_tank_configuration_history_immutable before update or delete on inventory.fuel_tank_configuration_history
 for each row execute function inventory.reject_fuel_tank_configuration_history_mutation();
revoke all on function inventory.reject_fuel_tank_configuration_history_mutation() from public,anon,authenticated,service_role;

create function api.create_fuel_tank(p_well_id uuid,p_name text,p_capacity_ml bigint default null,p_measurement_method text default 'manual')
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare tenant uuid;ft inventory.fuel_tanks%rowtype;snapshot jsonb;
begin
 select tenant_id into tenant from core.wells where id=p_well_id;
 if tenant is null or auth.uid() is null or not coalesce(iam.has_well_role(p_well_id,array['owner','manager']),false) then
  raise exception 'fuel_tank_configuration_forbidden' using errcode='42501';end if;
 perform billing.lock_customer_credit_well(p_well_id);
 if not exists(select 1 from core.wells where id=p_well_id and tenant_id=tenant)
  or not coalesce(iam.has_well_role(p_well_id,array['owner','manager']),false) then
  raise exception 'fuel_tank_configuration_forbidden' using errcode='42501';end if;
 if nullif(btrim(p_name),'') is null or (p_capacity_ml is not null and p_capacity_ml<=0)
  or p_measurement_method is null or p_measurement_method not in ('manual','dipstick','meter','estimated') then
  raise exception 'fuel_tank_configuration_invalid' using errcode='22023';end if;
 insert into inventory.fuel_tanks(tenant_id,well_id,name,capacity_ml,measurement_method)
 values(tenant,p_well_id,p_name,p_capacity_ml,p_measurement_method) returning * into ft;
 snapshot:=jsonb_build_object('name',ft.name,'capacity_ml',ft.capacity_ml,'measurement_method',ft.measurement_method,'status',ft.status);
 insert into inventory.fuel_tank_configuration_history(tenant_id,well_id,fuel_tank_id,after_configuration,actor_id)
 values(tenant,p_well_id,ft.id,snapshot,auth.uid());
 return jsonb_build_object('status','saved','fuel_tank_id',ft.id,'configuration',snapshot,'title','تم حفظ الخزان','action','عرض الخزانات');
end;$$;

-- Complete desired metadata, no nullable patch convention. Capacity NULL keeps
-- its existing schema meaning of unknown capacity, rather than unchanged.
create function api.configure_fuel_tank(p_fuel_tank_id uuid,p_name text,p_capacity_ml bigint,p_measurement_method text,p_status text)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare candidate inventory.fuel_tanks%rowtype;ft inventory.fuel_tanks%rowtype;before_value jsonb;after_value jsonb;
begin
 select * into candidate from inventory.fuel_tanks where id=p_fuel_tank_id;
 if candidate.id is null or auth.uid() is null or not coalesce(iam.has_well_role(candidate.well_id,array['owner','manager','operator']),false) then
  raise exception 'fuel_tank_configuration_forbidden' using errcode='42501';end if;
 perform billing.lock_customer_credit_well(candidate.well_id);
 select * into ft from inventory.fuel_tanks where id=p_fuel_tank_id for update;
 if ft.id is null or(ft.well_id,ft.tenant_id) is distinct from(candidate.well_id,candidate.tenant_id)
  or not exists(select 1 from core.wells where id=ft.well_id and tenant_id=ft.tenant_id)
  or not coalesce(iam.has_well_role(ft.well_id,array['owner','manager','operator']),false) then
  raise exception 'fuel_tank_configuration_forbidden' using errcode='42501';end if;
 if nullif(btrim(p_name),'') is null or(p_capacity_ml is not null and p_capacity_ml<=0)
  or p_measurement_method is null or p_measurement_method not in ('manual','dipstick','meter','estimated')
  or p_status is null or p_status not in ('active','inactive','maintenance','retired') then
  raise exception 'fuel_tank_configuration_invalid' using errcode='22023';end if;
 before_value:=jsonb_build_object('name',ft.name,'capacity_ml',ft.capacity_ml,'measurement_method',ft.measurement_method,'status',ft.status);
 after_value:=jsonb_build_object('name',p_name,'capacity_ml',p_capacity_ml,'measurement_method',p_measurement_method,'status',p_status);
 update inventory.fuel_tanks set name=p_name,capacity_ml=p_capacity_ml,measurement_method=p_measurement_method,status=p_status where id=ft.id;
 insert into inventory.fuel_tank_configuration_history(tenant_id,well_id,fuel_tank_id,before_configuration,after_configuration,actor_id)
 values(ft.tenant_id,ft.well_id,ft.id,before_value,after_value,auth.uid());
 return jsonb_build_object('status','saved','fuel_tank_id',ft.id,'configuration',after_value,
  'title','تم حفظ إعدادات الخزان','message',case when p_status='inactive' then 'تم إيقاف الخزان. بقي رصيده وسجله محفوظين.' else 'تم حفظ التغييرات.' end,'action','عرض الخزان');
end;$$;
revoke all on function api.create_fuel_tank(uuid,text,bigint,text),api.configure_fuel_tank(uuid,text,bigint,text,text)
 from public,anon,authenticated,service_role;
grant execute on function api.create_fuel_tank(uuid,text,bigint,text),api.configure_fuel_tank(uuid,text,bigint,text,text) to authenticated;

-- These remain available to SECURITY DEFINER stock/purchase/count functions.
-- Clients retain SELECT and use narrow metadata APIs instead of raw mutation.
revoke insert,update,delete,truncate on inventory.fuel_tanks from public,anon,authenticated,service_role;
do $acl$ declare c record;begin
 for c in select attname from pg_attribute where attrelid='inventory.fuel_tanks'::regclass and attnum>0 and not attisdropped loop
  execute format('revoke insert (%I),update (%I) on inventory.fuel_tanks from public,anon,authenticated,service_role',c.attname,c.attname);
 end loop;
end;$acl$;
drop policy if exists fuel_tanks_insert_owner on inventory.fuel_tanks;
drop policy if exists fuel_tanks_update_owner_operator on inventory.fuel_tanks;
drop policy if exists fuel_tanks_insert_owner_manager on inventory.fuel_tanks;
drop policy if exists fuel_tanks_update_owner_operator_manager on inventory.fuel_tanks;
commit;
