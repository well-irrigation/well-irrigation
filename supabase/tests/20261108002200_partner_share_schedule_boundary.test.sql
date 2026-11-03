\set ON_ERROR_STOP on
-- Permanent owner-local regression; authored only, no database execution.
begin;
create function pg_temp.share_check(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL %',label;end if;raise notice 'PASS %',label;end;$$;
do $test$
declare t uuid;w uuid;o uuid:=gen_random_uuid();m uuid:=gen_random_uuid();person uuid;p uuid;r jsonb;future date:=current_date+30;
 old_id uuid;future_id uuid;future_snapshot jsonb;body text;c uuid;
begin
 insert into core.tenants(name) values('share schedule') returning id into t;
 insert into core.wells(tenant_id,name) values(t,'share schedule well') returning id into w;
 insert into auth.users(id,instance_id,aud,role,email,created_at,updated_at)
 values(o,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',o||'@shares.test',now(),now()),
 (m,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',m||'@shares.test',now(),now());
 insert into iam.profiles(id,full_name) values(o,'share owner'),(m,'share manager') on conflict(id) do nothing;
 insert into core.well_assignments(well_id,profile_id,role,status) values(w,o,'owner','active'),(w,m,'manager','active');
 insert into core.persons(tenant_id,full_name,normalized_name) values(t,'share partner','share partner') returning id into person;
 insert into core.well_partners(tenant_id,well_id,person_id,phone,period_start) values(t,w,person,'777777777',date '1970-01-01') returning id into p;
 insert into core.ownership_share_versions(tenant_id,well_id,partner_id,ownership_percentage,profit_percentage,effective_period)
 values(t,w,p,100,100,daterange(date '1970-01-01',future,'[)')) returning id into old_id;
 insert into core.ownership_share_versions(tenant_id,well_id,partner_id,ownership_percentage,profit_percentage,effective_period)
 values(t,w,p,100,100,daterange(future,null,'[)')) returning id into future_id;
 select to_jsonb(v) into future_snapshot from core.ownership_share_versions v where id=future_id;
 perform set_config('request.jwt.claim.sub',o::text,true);
 r:=api.preview_partner_share_change(w,current_date-1);
 perform pg_temp.share_check((r->>'effective_until')::date=future,'future schedule boundary shown before save');
 execute 'set local role authenticated';
 r:=api.set_partner_shares(w,current_date-1,future,jsonb_build_array(jsonb_build_object('partner_id',p,'ownership_percentage',100,'profit_percentage',100)),'explicit owner change');
 execute 'reset role';
 perform pg_temp.share_check(r->>'status'='saved' and future_snapshot=(select to_jsonb(v) from core.ownership_share_versions v where id=future_id),
  'backdated change accepted without overwriting future scheduled version');
 perform pg_temp.share_check((select ownership_percentage=100 and profit_percentage=100 and upper(effective_period)=current_date-1 from core.ownership_share_versions where id=old_id)
  and exists(select 1 from core.partner_share_changes where well_id=w and jsonb_array_length(previous_versions)=1),
  'previous amounts/history retained while old effective interval closes');
 r:=api.set_partner_shares(w,current_date-1,null,jsonb_build_array(jsonb_build_object('partner_id',p,'ownership_percentage',100,'profit_percentage',100)),'wrong expected end');
 perform pg_temp.share_check(r->>'status'='review_again','post-wait prospective end revalidated');
 perform set_config('request.jwt.claim.sub',m::text,true);
 begin perform api.set_partner_shares(w,current_date,future,'[]','manager');raise exception 'EXPECTED_MANAGER_DENIED';exception when insufficient_privilege then null;end;
 perform set_config('request.jwt.claim.sub',o::text,true);
 perform api.update_distribution_settings(w,false);
 c:=finance.calculate_profit_distribution(w,now()-interval '1 hour',now(),o,0);
 r:=api.set_partner_shares(w,current_date-1,future,jsonb_build_array(jsonb_build_object('partner_id',p,'ownership_percentage',100,'profit_percentage',100)),'new accepted share basis');
 begin perform finance.approve_profit_distribution(c,o);raise exception 'EXPECTED_RECALCULATE';exception when check_violation then
  perform pg_temp.share_check(SQLERRM='distribution_shares_changed_recalculate','unapproved cycle requires explicit recalculation after share change');end;
 execute 'set local role authenticated';
 begin update core.ownership_share_versions set ownership_percentage=0 where id=future_id;raise exception 'EXPECTED_DIRECT_DENIED';exception when insufficient_privilege then null;end;
 execute 'reset role';
 select pg_get_functiondef('finance.r6c2_api_set_partner_shares(uuid,date,date,jsonb,text)'::regprocedure) into body;
 perform pg_temp.share_check(position('billing.enter_financial_write' in body)<position('for update' in body),'root first before partner/share locks');
end;$test$;
rollback;
