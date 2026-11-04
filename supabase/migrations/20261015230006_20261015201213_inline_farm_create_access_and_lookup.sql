begin;

-- تفويض إنشاء الأرض للمشغّل وحده، دون تغيير قواعد الهوية أو الإنشاء.
insert into iam.role_permissions(role_id,permission_id)
select r.id,p.id from iam.roles r cross join iam.permissions p
where r.code='operator' and p.code='farm.create'
on conflict do nothing;

create index if not exists farms_selection_scope_idx
on ops.farms(well_id,farmer_well_account_id,core.normalize_arabic(name),id)
where status='active';

-- عقد قراءة مستقل؛ يبقى list_well_farms(uuid,uuid) كما هو.
create function api.search_well_farms(
 p_well_id uuid,
 p_farmer_well_account_id uuid,
 p_query text default '',
 p_limit integer default 50,
 p_after jsonb default null
)
returns jsonb
language plpgsql stable security invoker
set search_path=pg_catalog,pg_temp
as $function$
declare
 v_query text:=coalesce(core.normalize_arabic(nullif(btrim(p_query),'')),'');
 v_limit integer:=least(greatest(coalesce(p_limit,50),1),100);
 v_items jsonb; v_cursor jsonb; v_more boolean;
begin
 if auth.uid() is null then raise exception 'يجب تسجيل الدخول' using errcode='28000'; end if;
 if p_well_id is null or p_farmer_well_account_id is null then
   raise exception 'البئر والمزارع مطلوبان' using errcode='22023';
 end if;
 if not exists(select 1 from core.wells w where w.id=p_well_id)
 or not exists(select 1 from ops.farmer_well_accounts a where a.id=p_farmer_well_account_id and a.well_id=p_well_id and a.status='active') then
   raise exception 'لا توجد صلاحية على بيانات المزارع' using errcode='42501';
 end if;
 if p_after is not null and (jsonb_typeof(p_after)!='object'
   or p_after->>'well_id' is distinct from p_well_id::text
   or p_after->>'farmer_id' is distinct from p_farmer_well_account_id::text
   or p_after->>'query' is distinct from v_query
   or not (p_after ?& array['rank','name','id'])) then
   raise exception 'أعد البحث عن الأرض' using errcode='22023';
 end if;
 with matched as (
  select f.*,coalesce(core.normalize_arabic(f.name),'') as normalized_name,
   case when core.normalize_arabic(f.name)=v_query then 0
        when starts_with(core.normalize_arabic(f.name),v_query) then 1 else 2 end as match_rank
  from ops.farms f
  where f.well_id=p_well_id and f.farmer_well_account_id=p_farmer_well_account_id and f.status='active'
    and (v_query='' or strpos(core.normalize_arabic(f.name),v_query)>0
      or strpos(coalesce(core.normalize_arabic(f.distinguishing_label),''),v_query)>0)
 ), page as (
  select * from matched
  where p_after is null or (match_rank,normalized_name,id) > ((p_after->>'rank')::integer,p_after->>'name',(p_after->>'id')::uuid)
  order by match_rank,normalized_name,id limit v_limit+1
 ), numbered as (
  select *,row_number() over(order by match_rank,normalized_name,id) as n from page
 )
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'well_id',well_id,'farmer_well_account_id',farmer_well_account_id,'name',name,'distinguishing_label',distinguishing_label,'status',status) order by n) filter(where n<=v_limit),'[]'::jsonb),
   (jsonb_agg(jsonb_build_object('well_id',p_well_id,'farmer_id',p_farmer_well_account_id,'query',v_query,'rank',match_rank,'name',normalized_name,'id',id) order by n) filter(where n=v_limit))->0,
   count(*)>v_limit
 into v_items,v_cursor,v_more from numbered;
 return jsonb_build_object('contract','search_well_farms','version',1,'items',v_items,'has_more',v_more,'next_cursor',case when v_more then v_cursor else null end);
end;
$function$;
revoke all on function api.search_well_farms(uuid,uuid,text,integer,jsonb) from public,anon,authenticated,service_role;
grant execute on function api.search_well_farms(uuid,uuid,text,integer,jsonb) to authenticated,service_role;
commit;
