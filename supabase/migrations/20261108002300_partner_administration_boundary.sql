-- Owner-adopted administrative status does not change economic rights.
begin;
create function api.add_well_partner(p_well_id uuid,p_person_id uuid,p_phone text,p_notes text default null,p_full_name text default null) returns uuid
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare tenant uuid;partner uuid;person uuid:=p_person_id;
begin
 select tenant_id into tenant from core.wells where id=p_well_id;
 if tenant is null or auth.uid() is null or not coalesce(iam.has_well_role(p_well_id,array['owner']),false) then
  raise exception 'partner_owner_required' using errcode='42501';end if;
 perform billing.enter_financial_write(p_well_id,null,array['owner'],tenant);
 if person is null then
  if nullif(btrim(p_full_name),'') is null or nullif(btrim(p_phone),'') is null then
   raise exception 'new_partner_name_phone_required' using errcode='22023';end if;
  -- Explicit NEW person, matching setup_well_full. Shared phone numbers are
  -- allowed by the canonical person model; never auto-merge or auto-link Auth.
  insert into core.persons(tenant_id,full_name,normalized_name,created_by,updated_by)
  values(tenant,btrim(p_full_name),core.normalize_arabic(btrim(p_full_name)),auth.uid(),auth.uid()) returning id into person;
  insert into core.person_contacts(tenant_id,person_id,contact_type,contact_value,normalized_value,is_primary)
  values(tenant,person,'mobile',p_phone,core.normalize_phone(p_phone),true);
 elsif p_full_name is not null then raise exception 'partner_identity_choice_required' using errcode='22023';end if;
 perform 1 from core.persons where id=person and tenant_id=tenant for share;
 if not found
  or not exists(select 1 from core.wells where id=p_well_id and tenant_id=tenant)
  or not coalesce(iam.has_well_role(p_well_id,array['owner']),false) then
  raise exception 'partner_scope_invalid' using errcode='42501';end if;
 if nullif(btrim(p_phone),'') is null then raise exception 'partner_phone_required' using errcode='22023';end if;
 if exists(select 1 from core.well_partners where well_id=p_well_id and person_id=person and period_end is null) then
  raise exception 'partner_already_registered' using errcode='23514';end if;
 insert into core.well_partners(tenant_id,well_id,person_id,phone,notes,period_start,joined_at)
 values(tenant,p_well_id,person,p_phone,p_notes,(clock_timestamp() at time zone core.well_timezone(p_well_id))::date,
  (clock_timestamp() at time zone core.well_timezone(p_well_id))::date) returning id into partner;
 -- Adding a person never invents profit or legal ownership percentages. The
 -- owner submits the complete dated 100% plan via the existing sanctioned API.
 return partner;
end;$$;
create function api.update_well_partner_contact(p_partner_id uuid,p_phone text,p_national_id text,p_notes text) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare candidate core.well_partners%rowtype;p core.well_partners%rowtype;
begin
 select * into candidate from core.well_partners where id=p_partner_id;
 if candidate.id is null or auth.uid() is null or not coalesce(iam.has_well_role(candidate.well_id,array['owner']),false) then
  raise exception 'partner_owner_required' using errcode='42501';end if;
 perform billing.enter_financial_write(candidate.well_id,null,array['owner'],candidate.tenant_id);
 select * into strict p from core.well_partners where id=p_partner_id for update;
 if(p.well_id,p.tenant_id,p.person_id) is distinct from(candidate.well_id,candidate.tenant_id,candidate.person_id)
  or not coalesce(iam.has_well_role(p.well_id,array['owner']),false) then raise exception 'partner_owner_required' using errcode='42501';end if;
 if nullif(btrim(p_phone),'') is null then raise exception 'partner_phone_required' using errcode='22023';end if;
 update core.well_partners set phone=p_phone,national_id=p_national_id,notes=p_notes,updated_at=clock_timestamp() where id=p.id;
 return jsonb_build_object('status','saved','title','تم حفظ بيانات الشريك','action','عرض الشريك');
end;$$;
create function api.set_well_partner_administrative_state(p_partner_id uuid,p_status text) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare candidate core.well_partners%rowtype;p core.well_partners%rowtype;
begin
 select * into candidate from core.well_partners where id=p_partner_id;
 if candidate.id is null or auth.uid() is null or not coalesce(iam.has_well_role(candidate.well_id,array['owner']),false) then
  raise exception 'partner_owner_required' using errcode='42501';end if;
 perform billing.enter_financial_write(candidate.well_id,null,array['owner'],candidate.tenant_id);
 select * into strict p from core.well_partners where id=p_partner_id for update;
 if(p.well_id,p.tenant_id,p.person_id) is distinct from(candidate.well_id,candidate.tenant_id,candidate.person_id)
  or not coalesce(iam.has_well_role(p.well_id,array['owner']),false) then raise exception 'partner_owner_required' using errcode='42501';end if;
 if p_status is null or p_status not in ('active','inactive','archived') then
  raise exception 'partner_administrative_state_invalid' using errcode='22023';end if;
 update core.well_partners set status=p_status,updated_at=clock_timestamp() where id=p.id;
 return jsonb_build_object('status','saved','partner_status',p_status,'title','تم تحديث حالة الشريك',
  'message','لم تتغير نسب الشريك أو مستحقاته. تسجيل خروجه من الأرباح إجراء مستقل.','action','عرض الشريك');
end;$$;
create function api.record_partner_departure(p_partner_id uuid,p_remaining_shares jsonb,p_expected_until date,p_reason text,p_departed_on date default null) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare candidate core.well_partners%rowtype;p core.well_partners%rowtype;day date;r jsonb;stamp timestamptz;
begin
 select * into candidate from core.well_partners where id=p_partner_id;
 if candidate.id is null or auth.uid() is null or not coalesce(iam.has_well_role(candidate.well_id,array['owner']),false) then
  raise exception 'partner_owner_required' using errcode='42501';end if;
 perform billing.enter_financial_write(candidate.well_id,null,array['owner'],candidate.tenant_id);
 -- Same parent row order as share changes. Do not lock one partner then ask
 -- another same-well parent while an un-serialized writer could do the inverse.
 perform 1 from core.well_partners where well_id=candidate.well_id order by id for update;
 select * into strict p from core.well_partners where id=p_partner_id;
 if(p.well_id,p.tenant_id,p.person_id) is distinct from(candidate.well_id,candidate.tenant_id,candidate.person_id)
  or not coalesce(iam.has_well_role(p.well_id,array['owner']),false) then raise exception 'partner_owner_required' using errcode='42501';end if;
 stamp:=clock_timestamp();day:=coalesce(p_departed_on,(stamp at time zone core.well_timezone(p.well_id))::date);
 if not isfinite(day) or day>(stamp at time zone core.well_timezone(p.well_id))::date then raise exception 'partner_departure_date_invalid' using errcode='22023';end if;
 if p.status='left' then raise exception 'partner_departure_already_recorded' using errcode='23514';end if;
 if p_remaining_shares is null or jsonb_typeof(p_remaining_shares)<>'array' or exists(
  select 1 from jsonb_array_elements(p_remaining_shares) x where(x->>'partner_id')::uuid=p.id) then
  raise exception 'departing_partner_must_not_receive_new_shares' using errcode='23514';end if;
 -- A future scheduled return is not silently deleted; owner must explicitly
 -- review/correct the saved plan before recording an open-ended departure.
 if exists(select 1 from core.ownership_share_versions where partner_id=p.id and not isempty(effective_period)
  and(ownership_percentage>0 or profit_percentage>0)
  and(lower(effective_period)>day or(
   (upper_inf(effective_period) or upper(effective_period)>(api.preview_partner_share_change(p.well_id,day)->>'effective_until')::date)
   and(api.preview_partner_share_change(p.well_id,day)->>'effective_until') is not null))) then
  return jsonb_build_object('status','review_required','title','راجع النسب المحفوظة أولًا',
   'message','توجد نسب مستقبلية محفوظة لهذا الشريك. راجعها قبل تسجيل خروجه حتى لا يعود إلى الأرباح دون قصد.','action','مراجعة النسب');end if;
 r:=api.set_partner_shares(p.well_id,day,p_expected_until,p_remaining_shares,p_reason);
 if r->>'status'<>'saved' then return r;end if;
 update core.well_partners set status='left',left_at=day,updated_at=stamp where id=p.id;
 return r||jsonb_build_object('title','تم تسجيل خروج الشريك','message','حُفظت نسب الشركاء الباقين. مستحقات الشريك السابقة لم تتغير.','action','عرض مستحقات الشريك');
end;$$;
revoke all on function api.add_well_partner(uuid,uuid,text,text,text),api.update_well_partner_contact(uuid,text,text,text),
 api.set_well_partner_administrative_state(uuid,text),api.record_partner_departure(uuid,jsonb,date,text,date) from public,anon,authenticated,service_role;
grant execute on function api.add_well_partner(uuid,uuid,text,text,text),api.update_well_partner_contact(uuid,text,text,text),
 api.set_well_partner_administrative_state(uuid,text),api.record_partner_departure(uuid,jsonb,date,text,date) to authenticated;
revoke insert,update,delete,truncate on core.well_partners from public,anon,authenticated,service_role;
do $columns$ declare c record;begin
 for c in select attname from pg_attribute where attrelid='core.well_partners'::regclass and attnum>0 and not attisdropped loop
  execute format('revoke insert (%I),update (%I) on core.well_partners from public,anon,authenticated,service_role',c.attname,c.attname);
 end loop;
end;$columns$;
commit;
