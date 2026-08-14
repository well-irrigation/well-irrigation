-- 063 — ق-76: اصلاح نطاق البحث في كاشف التكرار
-- similarity من اضافة pg_trgm مثبتة خارج core؛ نوسع search_path لتشمل public و extensions
create or replace function core.find_person_duplicates(p_tenant_id uuid, p_full_name text, p_phone text default null)
returns table (person_id uuid, public_code text, full_name text, match_level text, matched_on text)
language plpgsql
stable
security definer
set search_path = 'core', 'public', 'extensions', 'pg_temp'
as $fn$
declare
  v_name text := core.normalize_arabic(p_full_name);
  v_phone text := core.normalize_phone(p_phone);
begin
  return query
  with cand as (
    select p.id, p.public_code, p.full_name,
      (v_name is not null and (
        core.normalize_arabic(p.full_name) = v_name
        or similarity(core.normalize_arabic(p.full_name), v_name) >= 0.5
      )) as name_hit,
      (v_phone is not null and exists (
        select 1 from core.person_contacts pc
        where pc.person_id = p.id
          and pc.tenant_id = p_tenant_id
          and pc.contact_type in ('mobile','whatsapp','landline')
          and core.normalize_phone(pc.contact_value) = v_phone
      )) as phone_hit
    from core.persons p
    where p.tenant_id = p_tenant_id
      and p.status not in ('merged','archived')
  )
  select c.id, c.public_code, c.full_name,
    case when c.name_hit and c.phone_hit then 'match' else 'suspect' end,
    case
      when c.name_hit and c.phone_hit then 'name+phone'
      when c.phone_hit then 'phone'
      else 'name'
    end
  from cand c
  where c.name_hit or c.phone_hit
  order by (c.name_hit and c.phone_hit) desc, c.phone_hit desc, c.full_name;
end;
$fn$;

grant execute on function core.find_person_duplicates(uuid, text, text) to authenticated;
