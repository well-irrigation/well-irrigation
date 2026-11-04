\set ON_ERROR_STOP on
-- Owner local regression, STATIC authoring only. Everything rolls back.
begin;
set local timezone='UTC';
create function pg_temp.eac_check(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL %',label;end if;raise notice 'PASS %',label;end;$$;
do $test$
declare t uuid;w uuid;w2 uuid;owner_id uuid:=gen_random_uuid();manager_id uuid:=gen_random_uuid();operator_id uuid:=gen_random_uuid();other_manager uuid:=gen_random_uuid();accountant_id uuid:=gen_random_uuid();
 category uuid;code text;old_pending uuid;new_posted uuid;new_pending uuid;r jsonb;z jsonb;old_context jsonb;pending_context jsonb;old_row jsonb;approved_row jsonb;body text;
begin
 insert into core.tenants(name) values('expense approval configuration') returning id into t;
 insert into core.wells(tenant_id,name) values(t,'approval well A') returning id into w;
 insert into core.wells(tenant_id,name) values(t,'approval well B') returning id into w2;
 insert into auth.users(id,instance_id,aud,role,email,created_at,updated_at)
 values(owner_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',owner_id||'@eac.test',now(),now()),
 (manager_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',manager_id||'@eac.test',now(),now()),
 (operator_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',operator_id||'@eac.test',now(),now()),
 (other_manager,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',other_manager||'@eac.test',now(),now()),
 (accountant_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',accountant_id||'@eac.test',now(),now());
 insert into iam.profiles(id,full_name) values(owner_id,'owner'),(manager_id,'manager'),(operator_id,'operator'),(other_manager,'other manager'),(accountant_id,'accountant') on conflict(id) do nothing;
 insert into core.well_assignments(well_id,profile_id,role,status)
 values(w,owner_id,'owner','active'),(w,manager_id,'manager','active'),(w,operator_id,'operator','active'),(w2,other_manager,'manager','active'),(w,accountant_id,'accountant','active');
 select id,expense_categories.code into category,code from finance.expense_categories where tenant_id=t and well_id is null order by id limit 1;
 -- Legacy shared rule deliberately remains unassigned and is never migrated
 -- to a guessed well. Its matching snapshot is preserved for the old expense.
 insert into finance.expense_approval_rules(tenant_id,min_amount_minor,requires_approval) values(t,100,true);
 perform set_config('request.jwt.claim.sub',owner_id::text,true);
 old_pending:=finance.record_expense(w,code,200,'old pending expense',owner_id,null,true,'other',null,null,'لا يوجد سند للاختبار');
 select to_jsonb(e) into old_row from finance.expenses e where id=old_pending;
 select to_jsonb(c) into old_context from finance.expense_approval_contexts c where expense_id=old_pending;
 perform pg_temp.eac_check(old_row->>'status'='pending_approval' and old_context->>'source'='legacy_rules_snapshot','legacy pending context captured honestly');
 execute 'set local role authenticated';
 r:=api.set_expense_approval_configuration(w,'[]');
 execute 'reset role';
 perform pg_temp.eac_check(r->>'status'='saved' and r->>'effective_from' is not null,'owner activates a server-timed version');
 perform pg_temp.eac_check(old_row=(select to_jsonb(e) from finance.expenses e where id=old_pending)
  and old_context=(select to_jsonb(c) from finance.expense_approval_contexts c where expense_id=old_pending),'new settings do not reclassify/rewrite pending expense or context');
 new_posted:=finance.record_expense(w,code,200,'new automatically accepted',owner_id,null,true,'other',null,null,'لا يوجد سند للاختبار');
 perform pg_temp.eac_check((select status='posted' from finance.expenses where id=new_posted)
  and (select configuration_id=(r->>'configuration_id')::uuid and not requires_approval from finance.expense_approval_contexts where expense_id=new_posted),
  'new expense uses exact active configuration');
 perform pg_temp.eac_check((finance.expense_approval_context(w2,category,200)->>'requires_approval')::boolean,
  'well B continues to use its prior shared rule, unaffected by A');
 perform set_config('request.jwt.claim.sub',manager_id::text,true);
 execute 'set local role authenticated';
 r:=api.set_expense_approval_configuration(w,jsonb_build_array(jsonb_build_object('category_id',category,'min_amount_minor',100,'requires_approval',true)));
 execute 'reset role';
 -- Configuring approval does not grant the manager expense.create.
 perform set_config('request.jwt.claim.sub',operator_id::text,true);
 new_pending:=finance.record_expense(w,code,200,'new pending under manager version',operator_id,null,true,'other',null,null,'لا يوجد سند للاختبار');
 select to_jsonb(c) into pending_context from finance.expense_approval_contexts c where expense_id=new_pending;
 perform pg_temp.eac_check((select status='pending_approval' from finance.expenses where id=new_pending)
  and pending_context->>'configuration_id'=r->>'configuration_id','manager is authorized, matching category/threshold preserved');
 perform set_config('request.jwt.claim.sub',manager_id::text,true);
 r:=api.set_expense_approval_configuration(w,'[]');
 perform pg_temp.eac_check((select status='pending_approval' from finance.expenses where id=new_pending)
  and pending_context=(select to_jsonb(c) from finance.expense_approval_contexts c where expense_id=new_pending),'pending not automatically approved or rejected');
 perform set_config('request.jwt.claim.sub',owner_id::text,true);
 perform finance.decide_expense(old_pending,owner_id,true,'existing explicit decision');
 select to_jsonb(e) into approved_row from finance.expenses e where id=old_pending;
 r:=api.set_expense_approval_configuration(w,jsonb_build_array(jsonb_build_object('min_amount_minor',0,'requires_approval',true)));
 perform pg_temp.eac_check(approved_row=(select to_jsonb(e) from finance.expenses e where id=old_pending)
  and old_context=(select to_jsonb(c) from finance.expense_approval_contexts c where expense_id=old_pending),'later settings preserve existing approval decision and original workflow context');
 z:=api.get_expense_approval_configuration(w);
 perform pg_temp.eac_check(z->>'title'='اعتماد المصروفات' and z->>'save_action'='حفظ الإعدادات'
  and z->>'save_notice'='سيطبق هذا التغيير على المصروفات الجديدة فقط. المصروفات المنتظرة حاليًا لن تتغير.'
  and jsonb_array_length(z->'history')=4,'current/history and simple UX notice exposed');
 perform set_config('request.jwt.claim.sub',operator_id::text,true);
 begin perform api.set_expense_approval_configuration(w,'[]');raise exception 'EXPECTED_OPERATOR_DENIED';exception when insufficient_privilege then null;end;
 perform set_config('request.jwt.claim.sub',accountant_id::text,true);
 begin perform api.set_expense_approval_configuration(w,'[]');raise exception 'EXPECTED_ACCOUNTANT_DENIED';exception when insufficient_privilege then null;end;
 -- Only explicit active owner/manager assignments authorize configuration;
 -- accountant/generic financial permission is not an alternative authority.
 perform set_config('request.jwt.claim.sub',other_manager::text,true);
 begin perform api.set_expense_approval_configuration(w,'[]');raise exception 'EXPECTED_CROSS_WELL_DENIED';exception when insufficient_privilege then null;end;
 perform set_config('request.jwt.claim.sub',owner_id::text,true);
 begin perform api.set_expense_approval_configuration(w2,'[]');raise exception 'EXPECTED_CROSS_WELL_DENIED';exception when insufficient_privilege then null;end;
 update core.well_assignments set status='inactive' where well_id=w and profile_id=manager_id;
 perform set_config('request.jwt.claim.sub',manager_id::text,true);
 begin perform api.set_expense_approval_configuration(w,'[]');raise exception 'EXPECTED_INACTIVE_MANAGER_DENIED';exception when insufficient_privilege then null;end;
 perform set_config('request.jwt.claim.sub',owner_id::text,true);
 execute 'set local role authenticated';
 begin insert into finance.expense_approval_rules(tenant_id,well_id) values(t,w);raise exception 'EXPECTED_INSERT_DENIED';exception when insufficient_privilege then null;end;
 begin update finance.expense_approval_rules set requires_approval=false where tenant_id=t;raise exception 'EXPECTED_UPDATE_DENIED';exception when insufficient_privilege then null;end;
 begin delete from finance.expense_approval_rules where tenant_id=t;raise exception 'EXPECTED_DELETE_DENIED';exception when insufficient_privilege then null;end;
 execute 'reset role';
 begin update finance.expense_approval_configurations set rules='[]' where well_id=w;raise exception 'EXPECTED_HISTORY_DENIED';exception when check_violation then null;end;
 perform pg_temp.eac_check((select count(*)=1 from finance.expense_approval_rules where tenant_id=t and well_id is null),'legacy shared rows not reassigned or rewritten');
 select pg_get_functiondef('finance.r6c2_api_set_expense_approval_configuration(uuid,jsonb)'::regprocedure) into body;
 perform pg_temp.eac_check(position('billing.lock_customer_credit_well' in body)<position('for update' in body)
  and position('iam.has_well_role(p_well_id,array[''owner'',''manager''])' in body)>0,'root before rule lock; same-well owner/manager authorization');
end;$test$;
rollback;
