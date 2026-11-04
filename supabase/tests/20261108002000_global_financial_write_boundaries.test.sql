\set ON_ERROR_STOP on
-- Static-authored owner test; no database execution by agent.
begin;
create function pg_temp.root_check(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL %',label;end if;raise notice 'PASS %',label;end;$$;
do $test$
declare signature regprocedure;body text;root_pos integer;lock_pos integer;name text;t uuid;w uuid;actor uuid:=gen_random_uuid();box uuid;snapshot jsonb;r jsonb;
begin
 foreach signature in array array[
 'finance.pay_partner_distribution(uuid,bigint,uuid,timestamptz)'::regprocedure,
 'finance.decide_expense(uuid,uuid,boolean,text)'::regprocedure,
 'finance.pay_salary(uuid,uuid)'::regprocedure,
 'finance.post_opening_balance_batch(uuid,uuid)'::regprocedure,
 'finance.approve_opening_balance_batch(uuid,uuid)'::regprocedure,
 'ops.respond_session_transfer(uuid,boolean,uuid)'::regprocedure,
 'ops.close_shift(uuid,boolean)'::regprocedure,
 'ops.confirm_handover(uuid,bigint,uuid,text)'::regprocedure,
 'ops.complete_irrigation_session(uuid,timestamptz,bigint,text,uuid)'::regprocedure,
 'ops.settle_operational_occurrence(uuid,uuid,jsonb)'::regprocedure,
 'inventory.purchase_fuel(uuid,numeric,bigint,timestamptz,uuid)'::regprocedure,
 'inventory.record_physical_fuel_count(uuid,uuid,bigint,timestamptz,uuid,text)'::regprocedure
 ] loop
  body:=lower(pg_get_functiondef(signature));root_pos:=position('billing.enter_financial_write' in body);lock_pos:=position('for update' in body);
  perform pg_temp.root_check(root_pos>0 and(lock_pos=0 or root_pos<lock_pos),'root before child lock: '||signature::text);
 end loop;
 select lower(pg_get_functiondef('finance.pay_partner_distribution(uuid,bigint,uuid,timestamptz)'::regprocedure)) into body;
 perform pg_temp.root_check(position('select * into strict v_cycle' in body)<position('select * into strict v_line' in body),
  'distribution payment locks cycle before line');
 foreach signature in array array['finance.reverse_journal_entry(uuid,text,uuid)'::regprocedure,'finance.post_journal_entry(uuid,uuid)'::regprocedure,'finance.ensure_periods(uuid,date)'::regprocedure,
  'ops.finalize_session_from_closed_segments(uuid,timestamptz,uuid)'::regprocedure] loop
  body:=pg_get_functiondef(signature);
  perform pg_temp.root_check(position('billing.require_customer_credit_well_lock' in body)>0
   and position('billing.lock_customer_credit_well' in body)=0,'helper asserts and does not first-acquire root: '||signature::text);
  perform pg_temp.root_check(not has_function_privilege('authenticated',signature,'EXECUTE')
   and not has_function_privilege('anon',signature,'EXECUTE'),'helper is internal: '||signature::text);
 end loop;
 foreach name in array array['billing.payments','billing.payment_allocations','billing.invoices','billing.invoice_lines','billing.session_charges',
  'billing.account_credits','billing.account_credit_applications','finance.journal_entries','finance.journal_lines','finance.expenses',
  'finance.expense_approvals','finance.payroll_accruals','finance.profit_distribution_cycles','finance.profit_distribution_lines',
  'inventory.fuel_purchases','inventory.fuel_transactions','ops.shifts','ops.session_shift_transfers','ops.shift_handovers'] loop
  perform pg_temp.root_check(not has_table_privilege('authenticated',name,'INSERT') and not has_table_privilege('authenticated',name,'UPDATE')
   and not has_table_privilege('authenticated',name,'DELETE') and not has_any_column_privilege('authenticated',name,'UPDATE'),
   'unsafe direct table/column financial DML denied: '||name);
 end loop;
 perform pg_temp.root_check(not has_function_privilege('authenticated','core.merge_persons(uuid,uuid,text,uuid)','EXECUTE'),
  'multi-well merge is maintenance-only');
 foreach signature in array array['ops.flag_long_running_sessions()'::regprocedure,'ops.flag_approaching_long_sessions()'::regprocedure] loop
  body:=pg_get_functiondef(signature);
  perform pg_temp.root_check(position('ops.lock_operational_scope' in body)>0
   and position('ops.lock_operational_scope' in body)<position('update ops.irrigation_sessions' in body),
   'notification job protects well before session update and well FK');
 end loop;
 foreach name in array array['create_farmer','resolve_farmer_identity'] loop
  select pg_get_functiondef(p.oid) into body from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='ops' and p.proname=name limit 1;
  perform pg_temp.root_check(position('billing.enter_financial_write' in body)>0
   and position('billing.enter_financial_write' in body)<position('for update' in body),
   'farmer account scope established before shared person lock: '||name);
 end loop;
 body:=pg_get_functiondef('sync.begin_well_command(uuid,uuid,text,jsonb)'::regprocedure);
 perform pg_temp.root_check(position('''create_farmer''' in body)>0 and position('''resolve_farmer_identity''' in body)>0
  and position('billing.enter_financial_write' in body)<position('sync.begin_command' in body),
  'financial account commands establish root before well/command reservation');
 perform pg_temp.root_check(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='api' and p.prosecdef),'public API remains invoker-only; protected code is internal');
 insert into core.tenants(name) values('root assertion test') returning id into t;
 insert into core.wells(tenant_id,name) values(t,'root assertion well') returning id into w;
 begin perform finance.ensure_periods(gen_random_uuid(),current_date);raise exception 'EXPECTED_ROOT_REQUIRED';
 exception when object_not_in_prerequisite_state then
  perform pg_temp.root_check(SQLERRM='financial_well_boundary_required','period helper cannot become a standalone mutation');end;
 perform billing.lock_customer_credit_well(w);
 perform billing.lock_customer_credit_well(w);
 perform billing.require_customer_credit_well_lock(w);
 perform finance.ensure_periods(w,current_date);
 perform pg_temp.root_check((select count(*)=2 from finance.accounting_periods where well_id=w),
  'canonical root is reentrant and sanctioned parent permits period creation');
 insert into auth.users(id,instance_id,aud,role,email,created_at,updated_at)
 values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@cashbox.test',now(),now());
 insert into iam.profiles(id,full_name) values(actor,'cashbox owner') on conflict(id) do nothing;
 insert into core.well_assignments(well_id,profile_id,role,status) values(w,actor,'owner','active');
 perform set_config('request.jwt.claim.sub',actor::text,true);
 select id,to_jsonb(c)-'name' into box,snapshot from finance.cashboxes c where well_id=w and cashbox_type='main_well';
 execute 'set local role authenticated';
 r:=api.rename_cashbox(box,'اسم الصندوق الجديد');
 begin update finance.cashboxes set status='inactive' where id=box;raise exception 'EXPECTED_STATUS_DENIED';exception when insufficient_privilege then null;end;
 begin insert into finance.cashboxes(tenant_id,well_id,name,cashbox_type) values(t,w,'extra','petty_cash');raise exception 'EXPECTED_CREATE_DENIED';exception when insufficient_privilege then null;end;
 execute 'reset role';
 insert into sync.processed_commands(tenant_id,command_id,command_type,entity_id,status,request_payload,response_payload)
 values(t,actor,'accept_session_correction',w,'accepted','{}'::jsonb,'{"not_a_payment":true}'::jsonb);
 execute 'set local role authenticated';
 begin perform sync.begin_well_command(w,actor,'record_payment',null);raise exception 'EXPECTED_COMMAND_TYPE_CONFLICT';
 exception when invalid_parameter_value then
  perform pg_temp.root_check(SQLERRM='command_identity_conflict','financial command cannot replay another operation receipt');end;
 execute 'reset role';
 perform pg_temp.root_check(r->>'status'='saved' and snapshot=(select to_jsonb(c)-'name' from finance.cashboxes c where id=box)
  and exists(select 1 from finance.cashbox_name_history where cashbox_id=box and new_name='اسم الصندوق الجديد'),
  'system cashbox supports owner rename/history without status, custody or balance mutation');
 perform pg_temp.root_check(exists(select 1 from pg_trigger where tgrelid='finance.accounting_periods'::regclass and tgname='track_accounting_periods')
  and exists(select 1 from pg_constraint where conrelid='audit.audit_logs'::regclass and confrelid='core.wells'::regclass and contype='f'),
  'audit trigger and well FK preserved');
end;$test$;
rollback;
