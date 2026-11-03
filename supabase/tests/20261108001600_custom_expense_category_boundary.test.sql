\set ON_ERROR_STOP on
-- Owner local regression only; STATIC authoring, all effects roll back.
begin;
set local timezone='UTC';
create function pg_temp.cat_check(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL %',label;end if;raise notice 'PASS %',label;end;$$;
do $test$
declare t uuid;w uuid;other_w uuid;owner_id uuid:=gen_random_uuid();operator_id uuid:=gen_random_uuid();stranger uuid:=gen_random_uuid();
 r jsonb;z jsonb;cat uuid;code text;expense uuid;prior jsonb;body text;role_name text;legacy uuid;journals bigint;
begin
 insert into core.tenants(name) values('custom categories') returning id into t;
 insert into core.wells(tenant_id,name) values(t,'category well A') returning id into w;
 insert into core.wells(tenant_id,name) values(t,'category well B') returning id into other_w;
 insert into auth.users(id,instance_id,aud,role,email,created_at,updated_at)
 values(owner_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',owner_id||'@cat.test',now(),now()),
 (operator_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',operator_id||'@cat.test',now(),now()),
 (stranger,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',stranger||'@cat.test',now(),now());
 insert into iam.profiles(id,full_name) values(owner_id,'category owner'),(operator_id,'category operator'),(stranger,'other operator') on conflict(id) do nothing;
 insert into core.well_assignments(well_id,profile_id,role,status) values(w,owner_id,'owner','active'),(w,operator_id,'operator','active'),(other_w,stranger,'operator','active');
 perform set_config('request.jwt.claim.sub',owner_id::text,true);
 execute 'set local role authenticated';
 r:=api.create_custom_expense_category(w,'تصنيف قديم الاسم');
 execute 'reset role';cat:=(r->>'category_id')::uuid;code:=r->>'code';
 perform pg_temp.cat_check((select well_id=w and tenant_id=t and created_by=owner_id and ledger_account_code is null
  from finance.expense_categories where id=cat),'owner creates well-local category with server-only mapping');
 select id into legacy from finance.expense_categories where tenant_id=t and well_id is null order by id limit 1;
 begin perform api.rename_custom_expense_category(legacy,'not assigned');raise exception 'EXPECTED_LEGACY_DENIAL';exception when insufficient_privilege then null;end;
 -- Use the real existing expense evidence validation and scope path.
 expense:=finance.record_expense(w,code,100,'category history fixture',owner_id,null,true,'other',null,null,'لا يوجد سند للاختبار');
 select to_jsonb(e) into prior from finance.expenses e where id=expense;
 select count(*) into journals from finance.journal_entries;
 r:=api.rename_custom_expense_category(cat,'تصنيف جديد الاسم');
 perform pg_temp.cat_check((select name_ar='تصنيف جديد الاسم' from finance.expense_categories where id=cat),'owner rename supported');
 z:=api.list_well_expenses(w);
 perform pg_temp.cat_check(exists(select 1 from jsonb_array_elements(z->'expenses') e where e->>'id'=expense::text
  and e->>'category_name'='تصنيف قديم الاسم'),'historical display uses captured expense-time name');
 r:=api.set_custom_expense_category_active(cat,false);
 perform pg_temp.cat_check((select not is_active from finance.expense_categories where id=cat),'deactivate supported');
 z:=api.list_expense_categories(w);
 perform pg_temp.cat_check(not exists(select 1 from jsonb_array_elements(z->'categories') c where c->>'code'=code),'inactive category absent from new expense choices');
 begin perform finance.record_expense(w,code,100,'inactive denied',owner_id,null,true,'other',null,null,'لا يوجد سند للاختبار');
  raise exception 'EXPECTED_INACTIVE_DENIAL';exception when raise_exception then
  if SQLERRM='EXPECTED_INACTIVE_DENIAL' then raise;end if;
  perform pg_temp.cat_check(SQLERRM like 'نوع المصروف % غير معروف','inactive rejected by real write');end;
 r:=api.set_custom_expense_category_active(cat,true);
 perform pg_temp.cat_check(r->>'is_active'='true','reactivate same identity');
 perform pg_temp.cat_check(prior=(select to_jsonb(e) from finance.expenses e where id=expense)
  and journals=(select count(*) from finance.journal_entries),'rename/deactivation do not rewrite expense or create accounting effects');
 perform set_config('request.jwt.claim.sub',operator_id::text,true);
 execute 'set local role authenticated';
 r:=api.create_custom_expense_category(w,'تصنيف المشغل');
 r:=api.rename_custom_expense_category(cat,'اسم المشغل');
 r:=api.set_custom_expense_category_active(cat,false);
 r:=api.set_custom_expense_category_active(cat,true);
 execute 'reset role';
 perform pg_temp.cat_check(r->>'name'='اسم المشغل','authorized operator manages names and activation');
 z:=api.get_custom_expense_categories(w);
 perform pg_temp.cat_check(z->>'title'='تصنيفات المصروفات' and z->>'save_action'='حفظ'
  and z->>'deactivate_action'='إيقاف التصنيف' and not(z->'categories'->0 ? 'ledger_account_code'),'simple UI read contract, no mapping fields');
 perform set_config('request.jwt.claim.sub',stranger::text,true);
 begin perform api.rename_custom_expense_category(cat,'wrong well');raise exception 'EXPECTED_SCOPE_DENIAL';exception when insufficient_privilege then null;end;
 begin perform api.create_custom_expense_category(w,'wrong well');raise exception 'EXPECTED_SCOPE_DENIAL';exception when insufficient_privilege then null;end;
 execute 'set local role authenticated';
 z:=api.list_expense_categories(other_w);
 perform pg_temp.cat_check(not exists(select 1 from jsonb_array_elements(z->'categories') c where c->>'code'=code),'well B does not list A category');
 perform pg_temp.cat_check(not exists(select 1 from finance.expense_categories where id=cat),'direct SELECT also respects well scope');
 execute 'reset role';
 begin perform finance.record_expense(other_w,code,100,'wrong scope',stranger,null,true,'other',null,null,'لا يوجد سند للاختبار');
  raise exception 'EXPECTED_CODE_SCOPE_DENIAL';exception when raise_exception then
  if SQLERRM='EXPECTED_CODE_SCOPE_DENIAL' then raise;end if;
  perform pg_temp.cat_check(SQLERRM like 'نوع المصروف % غير معروف','foreign well category code rejected');end;
 perform set_config('request.jwt.claim.sub',operator_id::text,true);
 update core.well_assignments set role='manager' where profile_id=operator_id and well_id=w;
 begin perform api.create_custom_expense_category(w,'manager denied');raise exception 'EXPECTED_MANAGER_DENIAL';exception when insufficient_privilege then null;end;
 -- Accountant capability is never consulted; only exact owner or authorized
 -- operator assignment passes. Do not invent an unsupported assignment role.
 update core.well_assignments set role='operator',status='inactive' where profile_id=operator_id and well_id=w;
 begin perform api.rename_custom_expense_category(cat,'inactive');raise exception 'EXPECTED_INACTIVE_ACTOR_DENIAL';exception when insufficient_privilege then null;end;
 perform set_config('request.jwt.claim.sub',owner_id::text,true);
 execute 'set local role authenticated';
 begin insert into finance.expense_categories(tenant_id,well_id,code,name_ar) values(t,w,'unsafe','unsafe');raise exception 'EXPECTED_INSERT_DENIED';exception when insufficient_privilege then null;end;
 begin update finance.expense_categories set ledger_account_code='1000' where id=cat;raise exception 'EXPECTED_UPDATE_DENIED';exception when insufficient_privilege then null;end;
 begin delete from finance.expense_categories where id=cat;raise exception 'EXPECTED_DELETE_DENIED';exception when insufficient_privilege then null;end;
 execute 'reset role';
 perform pg_temp.cat_check(not has_any_column_privilege('authenticated','finance.expense_categories','UPDATE')
  and to_regprocedure('api.delete_custom_expense_category(uuid)') is null,'no raw mutation or hard delete API');
 perform pg_temp.cat_check((select ledger_account_code is null from finance.expense_categories where id=cat),'mapping preserved through every edit');
 perform pg_temp.cat_check((select count(*)>=7 from finance.custom_expense_category_history where category_id=cat),'all name/state changes recorded');
 select pg_get_functiondef('finance.mutate_custom_expense_category(uuid,uuid,text,boolean,text)'::regprocedure) into body;
 perform pg_temp.cat_check(position('billing.lock_customer_credit_well' in body)<position('for update of x' in body)
  and position('if not finance.can_manage_custom_expense_category(p_well)' in body)>0,'root precedes category locks with revalidation');
end;$test$;
rollback;
