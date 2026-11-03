\set ON_ERROR_STOP on
begin;
create function pg_temp.partner_check(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL %',label;end if;raise notice 'PASS %',label;end;$$;
do $test$
declare t uuid;w uuid;o uuid:=gen_random_uuid();m uuid:=gen_random_uuid();person uuid;p uuid;q uuid;r jsonb;before_shares jsonb;before_j bigint;new_partner uuid;business_day date;
begin
 insert into core.tenants(name) values('partner administration') returning id into t;
 insert into core.wells(tenant_id,name) values(t,'partner administration well') returning id into w;
 business_day:=(clock_timestamp() at time zone core.well_timezone(w))::date;
 insert into auth.users(id,instance_id,aud,role,email,created_at,updated_at)
 values(o,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',o||'@partner.test',now(),now()),
 (m,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',m||'@partner.test',now(),now());
 insert into iam.profiles(id,full_name) values(o,'partner owner'),(m,'partner manager') on conflict(id) do nothing;
 insert into core.well_assignments(well_id,profile_id,role,status) values(w,o,'owner','active'),(w,m,'manager','active');
 insert into core.persons(tenant_id,full_name,normalized_name) values(t,'first partner','first partner') returning id into person;
 perform set_config('request.jwt.claim.sub',o::text,true);
 p:=api.add_well_partner(w,person,'777777777');
 insert into core.persons(tenant_id,full_name,normalized_name) values(t,'second partner','second partner') returning id into person;
 q:=api.add_well_partner(w,person,'777777778');
 new_partner:=api.add_well_partner(w,null,'777777779',null,'شريك جديد دون حساب دخول');
 perform pg_temp.partner_check(exists(select 1 from core.well_partners where id=new_partner),
  'owner can add a genuinely new named partner without fabricating a farmer or Auth account');
 r:=api.set_partner_shares(w,business_day,null,jsonb_build_array(jsonb_build_object('partner_id',p,'ownership_percentage',50,'profit_percentage',50),
  jsonb_build_object('partner_id',q,'ownership_percentage',50,'profit_percentage',50)),'initial complete plan');
 select jsonb_agg(to_jsonb(v) order by id) into before_shares from core.ownership_share_versions v where well_id=w;
 select count(*) into before_j from finance.journal_entries;
 r:=api.set_well_partner_administrative_state(p,'inactive');r:=api.set_well_partner_administrative_state(p,'archived');
 perform pg_temp.partner_check(before_shares=(select jsonb_agg(to_jsonb(v) order by id) from core.ownership_share_versions v where well_id=w)
  and before_j=(select count(*) from finance.journal_entries),'administrative status never changes shares, rights or posts money');
 r:=api.record_partner_departure(p,jsonb_build_array(jsonb_build_object('partner_id',q,'ownership_percentage',100,'profit_percentage',100)),null,'owner records exit');
 perform pg_temp.partner_check(r->>'status'='saved' and(select status='left' and left_at=business_day from core.well_partners where id=p)
  and(select count(*)=1 and sum(profit_percentage)=100 from core.ownership_share_versions where well_id=w and effective_period @> business_day),
  'departure and complete owner-selected remaining shares are atomic');
 perform pg_temp.partner_check(exists(select 1 from audit.audit_logs where entity_type='core.well_partners' and entity_id=p),
  'existing audit continues to record partner changes');
 perform set_config('request.jwt.claim.sub',m::text,true);
 begin perform api.set_well_partner_administrative_state(q,'inactive');raise exception 'EXPECTED_MANAGER_DENIED';exception when insufficient_privilege then null;end;
 perform set_config('request.jwt.claim.sub',o::text,true);
 execute 'set local role authenticated';
 begin update core.well_partners set status='left' where id=q;raise exception 'EXPECTED_DIRECT_DENIED';exception when insufficient_privilege then null;end;
 execute 'reset role';
end;$test$;
rollback;
