\set ON_ERROR_STOP on
-- Owner local verification only. Static authoring; fixtures/effects roll back.
begin;
set local timezone='UTC';
create function pg_temp.dist_check(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL %',label;end if;raise notice 'PASS %',label;end;$$;
do $test$
declare tenant uuid;other_tenant uuid;w uuid;w2 uuid;actor uuid:=gen_random_uuid();manager uuid:=gen_random_uuid();person uuid;partner uuid;partner2 uuid;
 cycle uuid;new_cycle uuid;third uuid;line uuid;cfg jsonb;preview jsonb;r jsonb;snapshot jsonb;old_lines jsonb;
 from_at timestamptz:=date_trunc('day',now())-interval '20 days';to_at timestamptz:=date_trunc('day',now())-interval '10 days';
 mode text;before_count bigint;old_approved jsonb;body text;
begin
 insert into core.tenants(name) values('distribution configuration') returning id into tenant;
 insert into auth.users(id,instance_id,aud,role,email,created_at,updated_at)
 values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@dist.test',now(),now()),
 (manager,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',manager||'@dist.test',now(),now());
 insert into iam.profiles(id,full_name) values(actor,'distribution owner'),(manager,'distribution manager') on conflict(id) do nothing;
 insert into core.wells(tenant_id,name) values(tenant,'distribution well') returning id into w;
 insert into core.tenants(name) values('other distribution tenant') returning id into other_tenant;
 insert into core.wells(tenant_id,name) values(other_tenant,'other distribution well') returning id into w2;
 insert into core.well_assignments(well_id,profile_id,role,status) values(w,actor,'owner','active'),(w,manager,'manager','active');
 insert into core.persons(tenant_id,full_name,normalized_name) values(tenant,'first partner','first partner') returning id into person;
 insert into core.well_partners(tenant_id,well_id,person_id,phone,period_start)
 values(tenant,w,person,'777777777',date '1970-01-01') returning id into partner;
 insert into core.ownership_share_versions(tenant_id,well_id,partner_id,ownership_percentage,profit_percentage,effective_period)
 values(tenant,w,partner,100,100,daterange(date '1970-01-01',null,'[)'));
 perform set_config('request.jwt.claim.sub',actor::text,true);
 execute 'set local role authenticated';
 cfg:=api.update_distribution_settings(w,false);
 r:=api.set_maintenance_reserve_rule(w,'fixed_amount',null,100);
 execute 'reset role';
 perform pg_temp.dist_check((cfg->>'withhold_liabilities')::boolean=false and cfg->>'actor_id'=actor::text
  and cfg->>'accepted_at'=cfg->>'effective_from','owner saves authoritative setting/time');
 perform pg_temp.dist_check((select count(*)=3 from finance.distribution_configuration_versions where well_id=w),
  'legacy baseline plus both accepted saves preserved');
 cycle:=finance.calculate_profit_distribution(w,from_at,to_at,actor,0);
 perform pg_temp.dist_check((select maintenance_reserve_minor=100 from finance.profit_distribution_cycles where id=cycle),
  'new calculation uses current policy even for past accounting interval');
 perform pg_temp.dist_check(exists(select 1 from finance.distribution_calculation_history h where h.cycle_id=cycle
  and h.configuration_id=(r->>'id')::uuid),'calculation attributed to exact saved configuration');
 select to_jsonb(c) into snapshot from finance.profit_distribution_cycles c where id=cycle;
 r:=api.set_maintenance_reserve_rule(w,'fixed_amount',null,200);
 perform pg_temp.dist_check(snapshot=(select to_jsonb(c) from finance.profit_distribution_cycles c where id=cycle),
  'settings save never automatically changes existing unapproved cycle');
 preview:=api.recalculate_profit_distribution(cycle);
 perform pg_temp.dist_check(preview->>'status'='confirmation_required'
  and not(preview->>'manual_adjustments_present')::boolean,'clean cycle supports lightweight confirmation');
 r:=api.recalculate_profit_distribution(cycle,false,preview->>'state_token',0,true);new_cycle:=(r->>'cycle_id')::uuid;
 perform pg_temp.dist_check(r->>'status'='recalculated' and new_cycle<>cycle
  and (select maintenance_reserve_minor=200 from finance.profit_distribution_cycles where id=new_cycle),
  'explicit recalculation produces new result with current settings');
 perform pg_temp.dist_check((select status='cancelled' and maintenance_reserve_minor=100 from finance.profit_distribution_cycles where id=cycle)
  and exists(select 1 from finance.distribution_recalculations where previous_cycle_id=cycle and new_cycle_id=new_cycle),
  'old calculation retained and linked, no destructive amount rewrite');
 select id into strict line from finance.profit_distribution_lines where distribution_cycle_id=new_cycle;
 update finance.profit_distribution_lines set other_deductions_minor=7,net_payable_minor=net_payable_minor-7 where id=line;
 select jsonb_agg(to_jsonb(l) order by id) into old_lines from finance.profit_distribution_lines l where distribution_cycle_id=new_cycle;
 select count(*) into before_count from finance.profit_distribution_cycles;
 preview:=api.recalculate_profit_distribution(new_cycle);
 perform pg_temp.dist_check((preview->>'manual_adjustments_present')::boolean and (preview->>'affected_partner_count')::integer=1
  and preview->>'title'='تحتاج هذه الدورة إلى مراجعة قبل إعادة الحساب'
  and (preview->>'manual_adjustments_will_not_be_carried')::boolean,'structured simple warning includes affected partners');
 r:=api.recalculate_profit_distribution(new_cycle,false,preview->>'state_token',0,true);
 perform pg_temp.dist_check(r->>'status'='confirmation_required'
  and before_count=(select count(*) from finance.profit_distribution_cycles),'without confirmation no recalculation');
 -- A changed cycle invalidates an earlier confirmation.
 update finance.profit_distribution_lines set other_deductions_minor=8,net_payable_minor=net_payable_minor-1 where id=line;
 r:=api.recalculate_profit_distribution(new_cycle,true,preview->>'state_token',0,true);
 perform pg_temp.dist_check(r->>'status'='review_again','changed owner-visible facts require a fresh confirmation');
 preview:=api.recalculate_profit_distribution(new_cycle);
 -- Remove previous partner from the effective new ownership set; never reassign
 -- that partner's manual deduction to a new partner.
 update core.ownership_share_versions set effective_period=daterange(date '1970-01-01',from_at::date,'[)') where partner_id=partner;
 insert into core.persons(tenant_id,full_name,normalized_name) values(tenant,'new partner','new partner') returning id into person;
 insert into core.well_partners(tenant_id,well_id,person_id,phone,period_start)
 values(tenant,w,person,'777777778',from_at::date) returning id into partner2;
 insert into core.ownership_share_versions(tenant_id,well_id,partner_id,ownership_percentage,profit_percentage,effective_period)
 values(tenant,w,partner2,100,100,daterange(from_at::date,null,'[)'));
 r:=api.recalculate_profit_distribution(new_cycle,true,preview->>'state_token',0,true);third:=(r->>'cycle_id')::uuid;
 perform pg_temp.dist_check(r->>'status'='recalculated' and jsonb_array_length(r->'removed_partner_adjustments')=1,
  'removed partner adjustment retained as review item');
 perform pg_temp.dist_check((select other_deductions_minor=0 and partner_id=partner2 from finance.profit_distribution_lines where distribution_cycle_id=third),
  'manual deduction neither carried nor reassigned');
 perform pg_temp.dist_check(exists(select 1 from finance.distribution_recalculations h where previous_cycle_id=new_cycle
  and h.manual_adjustments_snapshot->0->>'other_deductions_minor'='8'
  and h.removed_partner_adjustments->0->>'partner_id'=partner::text), 'old manual adjustment remains inspectable in append-only history');
 perform finance.approve_profit_distribution(third,actor);
 select to_jsonb(c) into old_approved from finance.profit_distribution_cycles c where id=third;
 r:=api.disable_maintenance_reserve_rule(w);
 r:=api.recalculate_profit_distribution(third,true,null,0,true);
 perform pg_temp.dist_check(r->>'status'='not_available' and old_approved=(select to_jsonb(c) from finance.profit_distribution_cycles c where id=third),
  'approved result never recalculated or modified by a save');
 foreach mode in array array['percentage_of_collections','percentage_of_profit','fixed_amount','manual_per_cycle','disabled'] loop
  r:=api.set_maintenance_reserve_rule(w,mode,case when mode like 'percentage_%' then 5::numeric end,
   case when mode='fixed_amount' then 50::bigint end);
  perform pg_temp.dist_check(r->>'reserve_type'=mode,'supported reserve policy '||mode);
 end loop;
 r:=api.get_distribution_configuration(w);
 perform pg_temp.dist_check(jsonb_array_length(r->'history')>=9 and r->'current'->>'reserve_type'='disabled',
  'current values and previous settings remain readable');
 perform set_config('request.jwt.claim.sub',manager::text,true);
 begin perform api.update_distribution_settings(w,true);raise exception 'EXPECTED_MANAGER_DENIED';exception when insufficient_privilege then null;end;
 begin perform api.recalculate_profit_distribution(cycle);raise exception 'EXPECTED_MANAGER_DENIED';exception when insufficient_privilege then null;end;
 perform set_config('request.jwt.claim.sub',actor::text,true);
 begin perform api.update_distribution_settings(w2,true);raise exception 'EXPECTED_CROSS_WELL_DENIED';exception when insufficient_privilege then null;end;
 execute 'set local role authenticated';
 begin update finance.distribution_settings set withhold_liabilities=true where well_id=w;raise exception 'EXPECTED_UPDATE_DENIED';exception when insufficient_privilege then null;end;
 begin insert into finance.maintenance_reserve_rules(tenant_id,well_id,reserve_type,effective_period)
 values(tenant,w,'disabled',daterange(current_date,null,'[)'));raise exception 'EXPECTED_INSERT_DENIED';exception when insufficient_privilege then null;end;
 begin delete from finance.maintenance_reserve_rules where well_id=w;raise exception 'EXPECTED_DELETE_DENIED';exception when insufficient_privilege then null;end;
 execute 'reset role';
 begin update finance.distribution_configuration_versions set withhold_liabilities=true where well_id=w;raise exception 'EXPECTED_HISTORY_DENIED';exception when check_violation then null;end;
 select pg_get_functiondef('finance.save_distribution_configuration(uuid,boolean,text,numeric,bigint,boolean)'::regprocedure) into body;
 perform pg_temp.dist_check(position('billing.lock_customer_credit_well' in body)<position('for update' in body),'configuration root before rows');
 select pg_get_functiondef('finance.r6c2_api_recalculate_profit_distribution(uuid,boolean,text,bigint,boolean)'::regprocedure) into body;
 perform pg_temp.dist_check(position('billing.lock_customer_credit_well' in body)<position('for update' in body),'recalculation root before cycle and lines');
end;$test$;
rollback;
