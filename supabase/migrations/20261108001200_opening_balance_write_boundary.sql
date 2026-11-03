begin;
-- R6-C2B1: narrow draft preparation only; no change to approval/posting.
-- SELECT policies/grants, accounting triggers and all existing FKs remain.
create function finance.lock_editable_opening_batch(p_batch_id uuid)
returns finance.opening_balance_batches language plpgsql volatile security definer
set search_path=pg_catalog,pg_temp as $$
declare candidate finance.opening_balance_batches%rowtype;b finance.opening_balance_batches%rowtype;
begin
 select x.* into candidate from finance.opening_balance_batches x where x.id=p_batch_id;
 if not found or auth.uid() is null or not coalesce(iam.has_well_role(candidate.well_id,array['owner']),false) then
  raise exception 'opening_balance_forbidden' using errcode='42501';end if;
 perform billing.lock_customer_credit_well(candidate.well_id);
 select x.* into b from finance.opening_balance_batches x where x.id=p_batch_id for update of x;
 if not found then raise exception 'opening_batch_missing' using errcode='22023';end if;
 if (b.tenant_id,b.well_id) is distinct from(candidate.tenant_id,candidate.well_id)
  or not exists(select 1 from core.wells w where w.id=b.well_id and w.tenant_id=b.tenant_id) then
  raise exception 'opening_batch_scope_changed' using errcode='40001';end if;
 if auth.uid() is null or not coalesce(iam.has_well_role(b.well_id,array['owner']),false) then
  raise exception 'opening_balance_forbidden' using errcode='42501';end if;
 if b.status not in ('draft','pending_approval') then
  raise exception 'opening_batch_not_editable' using errcode='23514';end if;
 return b;
end;$$;
revoke all on function finance.lock_editable_opening_batch(uuid) from public,anon,authenticated,service_role;

create function api.create_opening_balance_batch(p_well_id uuid,p_reference_date date,p_notes text default null)
returns uuid language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare tenant uuid;locked_tenant uuid;id uuid;
begin
 select w.tenant_id into tenant from core.wells w where w.id=p_well_id;
 if not found or auth.uid() is null or not coalesce(iam.has_well_role(p_well_id,array['owner']),false) then
  raise exception 'opening_balance_forbidden' using errcode='42501';end if;
 perform billing.lock_customer_credit_well(p_well_id);
 select w.tenant_id into locked_tenant from core.wells w where w.id=p_well_id;
 if not found or locked_tenant is distinct from tenant then
  raise exception 'opening_batch_scope_changed' using errcode='40001';end if;
 if auth.uid() is null or not coalesce(iam.has_well_role(p_well_id,array['owner']),false) then
  raise exception 'opening_balance_forbidden' using errcode='42501';end if;
 if p_reference_date is null or not isfinite(p_reference_date) then
  raise exception 'opening_reference_date_required' using errcode='22023';end if;
 insert into finance.opening_balance_batches(tenant_id,well_id,reference_date,status,created_by,notes)
 values(tenant,p_well_id,p_reference_date,'draft',auth.uid(),p_notes) returning opening_balance_batches.id into id;
 return id;
end;$$;

-- Complete typed desired item, not arbitrary JSON/table update. NULL clears an
-- optional field. Identity, batch, tenant and creation time cannot be edited.
create function finance.write_draft_opening_item(
 p_batch_id uuid,p_item_id uuid,p_item_type text,p_amount_minor bigint,
 p_person_id uuid,p_farmer_well_account_id uuid,p_partner_id uuid,p_cashbox_id uuid,
 p_fuel_tank_id uuid,p_quantity_ml bigint,p_description text)
returns uuid language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare b finance.opening_balance_batches%rowtype;item finance.opening_balance_items%rowtype;id uuid;
begin
 b:=finance.lock_editable_opening_batch(p_batch_id);
 if p_item_id is not null then
  select x.* into item from finance.opening_balance_items x where x.id=p_item_id for update of x;
  if not found or item.batch_id<>b.id or item.tenant_id<>b.tenant_id then
   raise exception 'opening_item_scope_mismatch' using errcode='23514';end if;
 end if;
 -- Existing type/positive-amount validators still run. References must also
 -- belong to the derived scope; the client never selects a tenant or actor.
 if (p_person_id is not null and not exists(select 1 from core.persons x where x.id=p_person_id and x.tenant_id=b.tenant_id))
  or(p_farmer_well_account_id is not null and not exists(select 1 from ops.farmer_well_accounts x
   where x.id=p_farmer_well_account_id and x.well_id=b.well_id and x.tenant_id=b.tenant_id))
  or(p_partner_id is not null and not exists(select 1 from core.well_partners x where x.id=p_partner_id and x.well_id=b.well_id and x.tenant_id=b.tenant_id))
  or(p_cashbox_id is not null and not exists(select 1 from finance.cashboxes x where x.id=p_cashbox_id and x.well_id=b.well_id and x.tenant_id=b.tenant_id))
  or(p_fuel_tank_id is not null and not exists(select 1 from inventory.fuel_tanks x where x.id=p_fuel_tank_id and x.well_id=b.well_id and x.tenant_id=b.tenant_id)) then
  raise exception 'opening_item_reference_scope_mismatch' using errcode='23514';end if;
 if p_item_id is null then
  insert into finance.opening_balance_items(tenant_id,batch_id,item_type,amount_minor,person_id,farmer_well_account_id,
   partner_id,cashbox_id,fuel_tank_id,quantity_ml,description)
  values(b.tenant_id,b.id,p_item_type,p_amount_minor,p_person_id,p_farmer_well_account_id,p_partner_id,
   p_cashbox_id,p_fuel_tank_id,p_quantity_ml,p_description) returning opening_balance_items.id into id;
 else
  update finance.opening_balance_items set item_type=p_item_type,amount_minor=p_amount_minor,person_id=p_person_id,
   farmer_well_account_id=p_farmer_well_account_id,partner_id=p_partner_id,cashbox_id=p_cashbox_id,
   fuel_tank_id=p_fuel_tank_id,quantity_ml=p_quantity_ml,description=p_description where opening_balance_items.id=p_item_id;
  id:=p_item_id;
 end if;
 return id;
end;$$;
revoke all on function finance.write_draft_opening_item(uuid,uuid,text,bigint,uuid,uuid,uuid,uuid,uuid,bigint,text)
 from public,anon,authenticated,service_role;

create function api.add_opening_balance_item(p_batch_id uuid,p_item_type text,p_amount_minor bigint,
 p_person_id uuid default null,p_farmer_well_account_id uuid default null,p_partner_id uuid default null,
 p_cashbox_id uuid default null,p_fuel_tank_id uuid default null,p_quantity_ml bigint default null,p_description text default null)
returns uuid language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
begin
 return finance.write_draft_opening_item(p_batch_id,null,p_item_type,p_amount_minor,
  p_person_id,p_farmer_well_account_id,p_partner_id,p_cashbox_id,p_fuel_tank_id,p_quantity_ml,p_description);
end;$$;

create function api.update_opening_balance_item(p_item_id uuid,p_item_type text,p_amount_minor bigint,
 p_person_id uuid default null,p_farmer_well_account_id uuid default null,p_partner_id uuid default null,
 p_cashbox_id uuid default null,p_fuel_tank_id uuid default null,p_quantity_ml bigint default null,p_description text default null)
returns uuid language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare batch uuid;
begin
 select x.batch_id into batch from finance.opening_balance_items x where x.id=p_item_id;
 if not found then raise exception 'opening_item_missing' using errcode='22023';end if;
 return finance.write_draft_opening_item(batch,p_item_id,p_item_type,p_amount_minor,
  p_person_id,p_farmer_well_account_id,p_partner_id,p_cashbox_id,p_fuel_tank_id,p_quantity_ml,p_description);
end;$$;

-- No DELETE policy/capability was found: do not invent draft deletion.
-- Remove table AND column DML grants, leaving all SELECT privileges intact.
do $acl$
declare rel regclass;col record;
begin
 foreach rel in array array['finance.opening_balance_batches'::regclass,'finance.opening_balance_items'::regclass] loop
  execute format('revoke insert,update,delete,truncate on %s from public,anon,authenticated,service_role',rel);
  for col in select attname from pg_attribute where attrelid=rel and attnum>0 and not attisdropped loop
   execute format('revoke insert (%I),update (%I) on %s from public,anon,authenticated,service_role',col.attname,col.attname,rel);
  end loop;
 end loop;
end;$acl$;
drop policy if exists opening_balance_batches_insert_owner on finance.opening_balance_batches;
drop policy if exists opening_balance_batches_update_owner on finance.opening_balance_batches;
drop policy if exists opening_balance_items_insert_owner on finance.opening_balance_items;
drop policy if exists opening_balance_items_update_owner on finance.opening_balance_items;
revoke all on function api.create_opening_balance_batch(uuid,date,text),
 api.add_opening_balance_item(uuid,text,bigint,uuid,uuid,uuid,uuid,uuid,bigint,text),
 api.update_opening_balance_item(uuid,text,bigint,uuid,uuid,uuid,uuid,uuid,bigint,text)
 from public,anon,authenticated,service_role;
grant execute on function api.create_opening_balance_batch(uuid,date,text),
 api.add_opening_balance_item(uuid,text,bigint,uuid,uuid,uuid,uuid,uuid,bigint,text),
 api.update_opening_balance_item(uuid,text,bigint,uuid,uuid,uuid,uuid,uuid,bigint,text) to authenticated;
-- Existing approve/post routines are unchanged; global root repair is pending.
commit;
