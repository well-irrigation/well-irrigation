\set ON_ERROR_STOP on
-- Owner local verification only; authoring is STATIC. All fixtures roll back.
begin;
set local timezone='UTC';
create function pg_temp.comp_check(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL %',label;end if;raise notice 'PASS %',label;end;$$;
do $test$
declare t uuid;w uuid;w2 uuid;actor uuid:=gen_random_uuid();manager uuid:=gen_random_uuid();person uuid;daily_person uuid;
 r jsonb;z jsonb;old_id uuid;new_id uuid;daily_id uuid;d date;effective date;pay uuid;old_pay uuid;snapshot jsonb;name text;body text;
begin
 insert into core.tenants(name,timezone) values('compensation boundary','Asia/Aden') returning id into t;
 insert into core.wells(tenant_id,name) values(t,'compensation well') returning id into w;
 insert into core.wells(tenant_id,name) values(t,'other well') returning id into w2;
 insert into auth.users(id,instance_id,aud,role,email,created_at,updated_at)
 values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@comp.test',now(),now()),
 (manager,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',manager||'@comp.test',now(),now());
 insert into iam.profiles(id,full_name) values(actor,'compensation owner'),(manager,'compensation manager') on conflict(id) do nothing;
 insert into core.well_assignments(well_id,profile_id,role,status) values(w,actor,'owner','active'),(w,manager,'manager','active');
 insert into core.persons(tenant_id,full_name,normalized_name) values(t,'monthly worker','monthly worker') returning id into person;
 insert into core.persons(tenant_id,full_name,normalized_name) values(t,'daily worker','daily worker') returning id into daily_person;
 perform set_config('request.jwt.claim.sub',actor::text,true);
 d:=(clock_timestamp() at time zone core.well_timezone(w))::date;
 effective:=(date_trunc('month',d::timestamp)+interval '1 month')::date;
 execute 'set local role authenticated';
 z:=api.preview_worker_compensation_effective_date(w,'monthly');
 r:=api.create_worker_compensation_rule(w,person,'monthly',10000,(z->>'effective_from')::date);
 execute 'reset role';old_id:=(r->>'rule_id')::uuid;
 perform pg_temp.comp_check((r->>'effective_from')::date=effective and r->>'timezone'='Asia/Aden','monthly next month date server-derived');
 perform pg_temp.comp_check(finance.compensation_effective_date('daily','Asia/Aden','2026-05-15 22:00+00')=date '2026-05-17',
  'business timezone, not connection/device calendar');
 begin perform api.create_worker_compensation_rule(w,person,'monthly',20000);raise exception 'EXPECTED_DUPLICATE_DENIAL';
 exception when check_violation then null;end;
 begin perform api.create_worker_compensation_rule(w,daily_person,'daily',100,d);raise exception 'EXPECTED_RETROACTIVE_DENIAL';
 exception when serialization_failure then null;end;
 begin perform api.create_worker_compensation_rule(w,daily_person,'hourly',100);raise exception 'EXPECTED_TYPE_DENIAL';
 exception when invalid_parameter_value then null;end;
 r:=api.create_worker_compensation_rule(w,daily_person,'daily',100);daily_id:=(r->>'rule_id')::uuid;
 perform pg_temp.comp_check((r->>'effective_from')::date=d+1,'daily next calendar day');
 perform set_config('request.jwt.claim.sub',manager::text,true);
 begin perform api.create_worker_compensation_rule(w,person,'monthly',1);raise exception 'EXPECTED_MANAGER_DENIAL';
 exception when insufficient_privilege then null;end;
 begin perform api.update_worker_compensation_rule(old_id,'monthly',1);raise exception 'EXPECTED_MANAGER_DENIAL';
 exception when insufficient_privilege then null;end;
 begin perform api.deactivate_worker_compensation_rule(old_id);raise exception 'EXPECTED_MANAGER_DENIAL';
 exception when insufficient_privilege then null;end;
 perform set_config('request.jwt.claim.sub',actor::text,true);
 begin perform api.create_worker_compensation_rule(w2,person,'monthly',1);raise exception 'EXPECTED_SCOPE_DENIAL';
 exception when insufficient_privilege then null;end;
 -- Replace a scheduled rule at the same effective boundary, retaining its row
 -- and immutable before/after history, rather than deleting a prior version.
 r:=api.update_worker_compensation_rule(old_id,'monthly',12000,effective);new_id:=(r->>'rule_id')::uuid;
 perform pg_temp.comp_check(new_id<>old_id and (select rate_amount_minor=10000 and compensation_type='monthly'
  and isempty(effective_period) and replaced_at is not null and replacement_rule_id=new_id
  from finance.worker_compensation_rules where id=old_id),'old amount/type/identity retained, scheduled successor separate');
 perform pg_temp.comp_check((select count(*)=1 from finance.worker_compensation_rules where well_id=w and person_id=person
  and effective_period @> effective),'one effective rule after change');
 perform pg_temp.comp_check((select accepted_by=actor and accepted_at is not null and lower(effective_period)=effective
  from finance.worker_compensation_rules where id=new_id),'actor, timestamp and server date recorded');
 -- Historical fixture represents a real previously accepted rule, not a
 -- retroactive API. Its accrued result must remain unchanged through edits.
 insert into finance.worker_compensation_rules(tenant_id,well_id,person_id,compensation_type,rate_amount_minor,effective_period)
 values(t,w,person,'monthly',8000,daterange(d-90,effective,'[)'));
 old_pay:=finance.accrue_payroll(w,person,d-2,d-1,null,0,actor);
 select to_jsonb(x) into snapshot from finance.payroll_accruals x where id=old_pay;
 pay:=finance.accrue_payroll(w,person,effective,effective+1,null,0,actor);
 perform pg_temp.comp_check((select gross_amount_minor=12000 from finance.payroll_accruals where id=pay),'future accrual uses new monthly amount unchanged formula');
 begin perform finance.accrue_payroll(w,person,effective-1,effective,null,0,actor);raise exception 'EXPECTED_SPLIT_DENIAL';
 exception when check_violation then perform pg_temp.comp_check(SQLERRM='payroll_period_crosses_compensation_boundary_split_required','cross boundary requires split');end;
 perform pg_temp.comp_check((select gross_amount_minor=8000 from finance.payroll_accruals where id=old_pay),'before boundary uses old rule');
 begin perform api.update_worker_compensation_rule(new_id,'monthly',14000);raise exception 'EXPECTED_ACCRUED_CONFLICT';
 exception when check_violation then null;end;
 perform pg_temp.comp_check(snapshot=(select to_jsonb(x) from finance.payroll_accruals x where id=old_pay),'already accrued row never recomputed');
 begin update finance.payroll_accruals set gross_amount_minor=1 where id=old_pay;raise exception 'EXPECTED_IMMUTABLE';
 exception when check_violation then null;end;
 perform pg_temp.comp_check(finance.compensation_effective_date('monthly','Asia/Aden','2026-05-15 12:00+00')=date '2026-06-01'
  and finance.compensation_effective_date('daily','Asia/Aden','2026-05-15 12:00+00')=date '2026-05-16','adopted effective-date examples');
 r:=api.deactivate_worker_compensation_rule(daily_id,d+1);
 perform pg_temp.comp_check((select rate_amount_minor=100 and replaced_at is not null and isempty(effective_period)
  from finance.worker_compensation_rules where id=daily_id),'prospective deactivation retains original facts');
 begin perform finance.accrue_payroll(w,daily_person,d+1,d+2,null,0,actor);raise exception 'EXPECTED_NO_RULE';
 exception when check_violation then perform pg_temp.comp_check(SQLERRM='payroll_single_compensation_rule_required','deactivated future rule not usable');end;
 z:=api.get_worker_compensation_history(w,person);
 perform pg_temp.comp_check(jsonb_array_length(z->'versions')=3 and jsonb_array_length(z->'changes')=2
  and exists(select 1 from jsonb_array_elements(z->'versions') x where x->>'id'=new_id::text
   and x->>'effective_from'=effective::text),'read model exposes original/pending/history and exact effective date');
 execute 'set local role authenticated';
 begin insert into finance.worker_compensation_rules(tenant_id,well_id,person_id,compensation_type,rate_amount_minor,effective_period)
 values(t,w,person,'daily',1,daterange(d,d+1,'[)'));raise exception 'EXPECTED_INSERT_DENIED';exception when insufficient_privilege then null;end;
 begin update finance.worker_compensation_rules set rate_amount_minor=1 where id=new_id;raise exception 'EXPECTED_UPDATE_DENIED';exception when insufficient_privilege then null;end;
 begin delete from finance.worker_compensation_rules where id=old_id;raise exception 'EXPECTED_DELETE_DENIED';exception when insufficient_privilege then null;end;
 execute 'reset role';
 perform pg_temp.comp_check(not has_any_column_privilege('authenticated','finance.worker_compensation_rules','UPDATE')
  and to_regprocedure('api.delete_worker_compensation_rule(uuid)') is null,'no direct update or delete API');
 perform pg_temp.comp_check(exists(select 1 from pg_constraint where conrelid='finance.worker_compensation_rules'::regclass
  and conname='no_worker_rule_period_overlap' and contype='x'),'database exclusion protects concurrent range uniqueness');
 select pg_get_functiondef('finance.mutate_worker_compensation(uuid,uuid,text,uuid,text,bigint,date)'::regprocedure) into body;
 perform pg_temp.comp_check(position('billing.lock_customer_credit_well' in body)<position('for share of a' in body)
  and position('billing.lock_customer_credit_well' in body)<position('for update of x' in body),'root acquired before actor/worker/rule locks');
 insert into core.persons(tenant_id,full_name,normalized_name) values(t,'daily accrual worker','daily accrual worker') returning id into daily_person;
 r:=api.create_worker_compensation_rule(w,daily_person,'daily',100);
 pay:=finance.accrue_payroll(w,daily_person,d+1,d+3,null,0,actor);
 perform pg_temp.comp_check((select gross_amount_minor=300 from finance.payroll_accruals where id=pay),'daily existing inclusive days formula preserved');
 perform pg_temp.comp_check((select count(*)=0 from finance.worker_compensation_changes c join finance.worker_compensation_rules x
  on x.id=c.new_rule_id where x.compensation_type not in ('monthly','daily')),'new types limited to monthly/daily');
end;$test$;
rollback;
