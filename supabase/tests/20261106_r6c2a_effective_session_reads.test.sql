\set ON_ERROR_STOP on
-- OWNER ONLY / local disposable database. Read-contract gate for R6-C4.
begin;
set local timezone='UTC';

create function pg_temp.r6c2a_check(ok boolean,label text) returns void language plpgsql as $$
begin
 if ok is distinct from true then raise exception 'FAIL %',label;end if;
 raise notice 'PASS %',label;
end;$$;

do $tests$
declare detail_oid oid;list_oid oid;history_oid oid;status_oid oid;obj text;
 writer_oid oid;acceptance_oid oid;
 rls_enabled boolean;select_policy_count integer;
begin
 -- Fail with the missing contract name, rather than invoking a nonexistent RPC.
 detail_oid:=to_regprocedure('api.get_session_detail(uuid)');
 perform pg_temp.r6c2a_check(detail_oid is not null,'01 api.get_session_detail(uuid) exists');
 list_oid:=to_regprocedure('api.list_well_sessions(uuid,uuid,timestamptz,timestamptz,boolean,integer)');
 perform pg_temp.r6c2a_check(list_oid is not null,'02 api.list_well_sessions signature exists');
 history_oid:=to_regprocedure('api.get_session_corrections(uuid)');
 perform pg_temp.r6c2a_check(history_oid is not null,'03 missing public correction history contract: api.get_session_corrections(uuid)');
 status_oid:=to_regprocedure('api.get_session_correction_status(uuid)');
 perform pg_temp.r6c2a_check(status_oid is not null,'04 missing isolated correction status contract: api.get_session_correction_status(uuid)');

 -- All client reads must be exposed through api, with authenticated access
 -- and no anonymous access. Internal correction storage and routines stay private.
 perform pg_temp.r6c2a_check(has_function_privilege('authenticated',detail_oid,'EXECUTE')
   and not has_function_privilege('anon',detail_oid,'EXECUTE')
   and not (select prosecdef from pg_proc where oid=detail_oid),
   '05 session detail is authenticated SECURITY INVOKER api read');
 perform pg_temp.r6c2a_check(has_function_privilege('authenticated',list_oid,'EXECUTE')
   and not has_function_privilege('anon',list_oid,'EXECUTE')
   and not (select prosecdef from pg_proc where oid=list_oid),
   '06 session history is authenticated SECURITY INVOKER api read');
 perform pg_temp.r6c2a_check(has_function_privilege('authenticated',history_oid,'EXECUTE')
   and not has_function_privilege('anon',history_oid,'EXECUTE')
   and not (select prosecdef from pg_proc where oid=history_oid),
   '07 correction history is authenticated SECURITY INVOKER api read');
 perform pg_temp.r6c2a_check(has_function_privilege('authenticated',status_oid,'EXECUTE')
   and not has_function_privilege('anon',status_oid,'EXECUTE')
   and not (select prosecdef from pg_proc where oid=status_oid),
   '08 correction status is authenticated SECURITY INVOKER api read');
 -- Phase transition: C2B activates precisely the intended INVOKER wrapper,
 -- without exposing business schemas or enabling direct table writes.
 writer_oid:=to_regprocedure('api.correct_irrigation_session(uuid,uuid,bigint,text,timestamptz,timestamptz,timestamptz)');
 acceptance_oid:=to_regprocedure('ops.accept_session_correction(uuid,uuid,bigint,text,timestamptz,timestamptz,timestamptz)');
 perform pg_temp.r6c2a_check(writer_oid is not null
   and (select not prosecdef from pg_proc where oid=writer_oid)
   and has_function_privilege('authenticated',writer_oid,'EXECUTE')
   and has_function_privilege('service_role',writer_oid,'EXECUTE')
   and not has_function_privilege('anon',writer_oid,'EXECUTE')
   and not exists(select 1 from pg_proc p,
     lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) acl
     where p.oid=writer_oid and acl.grantee=0 and acl.privilege_type='EXECUTE')
   and not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='api' and p.proname in ('correct_irrigation_session','correct_session',
       'accept_session_correction','reconcile_session_correction') and p.oid<>writer_oid),
   '09 intended public correction wrapper only; INVOKER, role parity, no anon/PUBLIC or reconciliation');
 perform pg_temp.r6c2a_check(acceptance_oid is not null
   and has_function_privilege('authenticated',acceptance_oid,'EXECUTE')
   and has_function_privilege('service_role',acceptance_oid,'EXECUTE')
   and not has_function_privilege('anon',acceptance_oid,'EXECUTE')
   and not exists(select 1 from pg_proc p,
     lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) acl
     where p.oid=acceptance_oid and acl.grantee=0 and acl.privilege_type='EXECUTE'),
   '10 internal acceptance bridge limited to authenticated/service_role; no anon/PUBLIC');
 perform pg_temp.r6c2a_check(not has_function_privilege('authenticated',
   'billing.reconcile_session_correction(uuid,uuid,timestamptz)','EXECUTE'),
   '11 authenticated cannot execute internal financial reconciliation');
 foreach obj in array array['ops.session_corrections','ops.session_correction_reconciliations'] loop
  select c.relrowsecurity into rls_enabled
  from pg_class c where c.oid=to_regclass(obj);
  select count(*) into select_policy_count from pg_policies p
  where p.schemaname=split_part(obj,'.',1) and p.tablename=split_part(obj,'.',2)
    and p.cmd in ('SELECT','ALL') and p.qual is not null;
  perform pg_temp.r6c2a_check(rls_enabled and select_policy_count>0,
   '12 RLS SELECT policy scopes '||obj);
  perform pg_temp.r6c2a_check(has_table_privilege('authenticated',obj,'SELECT')
    and not has_table_privilege('anon',obj,'SELECT'),
   '13 authenticated SELECT is row-scoped; anon cannot read '||obj);
  perform pg_temp.r6c2a_check(not has_table_privilege('authenticated',obj,'INSERT')
    and not has_table_privilege('authenticated',obj,'UPDATE')
    and not has_table_privilege('authenticated',obj,'DELETE')
    and not has_table_privilege('authenticated',obj,'TRUNCATE')
    and not has_table_privilege('authenticated',obj,'REFERENCES')
    and not has_table_privilege('authenticated',obj,'TRIGGER')
    and not has_table_privilege('anon',obj,'INSERT')
    and not has_table_privilege('anon',obj,'UPDATE')
    and not has_table_privilege('anon',obj,'DELETE')
    and not has_table_privilege('anon',obj,'TRUNCATE')
    and not has_table_privilege('anon',obj,'REFERENCES')
    and not has_table_privilege('anon',obj,'TRIGGER'),
   '14 no direct write or object-control privileges on '||obj);
 end loop;
end;$tests$;

-- Real operational commands build the fixture, including the original charge
-- and receipts. Expected timestamps below are independent of read-model code.
create function pg_temp.r6c2a_fixture(fractional_boundary boolean default false) returns jsonb language plpgsql as $$
declare tenant uuid;well uuid;actor uuid:=gen_random_uuid();person uuid;farmer uuid;
 account uuid;farm uuid;pump uuid;sid uuid;completion jsonb;
 started timestamptz:=date_trunc('day',transaction_timestamp())-interval '3 days'+interval '8 hours';
 start_command uuid:=gen_random_uuid();end_command uuid:=gen_random_uuid();
begin
 insert into core.tenants(name) values('R6C2A effective reads') returning id into tenant;
 insert into auth.users(id,instance_id,aud,role,email,email_confirmed_at,created_at,updated_at)
 values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
  actor||'@r6c2a.test',now(),now(),now());
 insert into iam.profiles(id,full_name) values(actor,'مشغل اختبار التصحيح') on conflict(id) do nothing;
 insert into core.wells(tenant_id,name) values(tenant,'R6C2A well') returning id into well;
 insert into core.well_assignments(well_id,profile_id,role,status) values(well,actor,'operator','active');
 insert into core.persons(tenant_id,full_name,normalized_name)
 values(tenant,'R6C2A farmer','R6C2A farmer') returning id into person;
 insert into ops.farmer_profiles(tenant_id,person_id) values(tenant,person) returning id into farmer;
 insert into ops.farmer_well_accounts(tenant_id,farmer_profile_id,well_id,public_code)
 values(tenant,farmer,well,'R6C2A-'||substr(actor::text,1,8)) returning id into account;
 insert into ops.farms(well_id,name,farmer_well_account_id) values(well,'R6C2A farm',account) returning id into farm;
 insert into core.pumps(well_id,name,power_source,status) values(well,'R6C2A pump','diesel','active') returning id into pump;
 insert into billing.well_pricing(well_id,price_per_hour_minor,period_start)
 values(well,3600,date '1970-01-01');
 insert into ops.shifts(tenant_id,well_id,operator_profile_id,started_at,status)
 values(tenant,well,actor,started-interval '1 hour','open');
 perform set_config('request.jwt.claim.sub',actor::text,true);
 execute 'set local role authenticated';
 sid:=api.start_operational_session(well,pump,farm,account,'solar',started,start_command);
 if fractional_boundary then
  -- A real pause creates a second, contiguous segment, retaining subsecond
  -- timestamps. Complete while paused rather than manufacturing segment rows.
  perform api.pause_irrigation_session(sid,'operator_pause',
   started+interval '30 minutes 0.4 seconds',gen_random_uuid());
 end if;
 completion:=api.complete_irrigation_session(sid,started+interval '2 hours',null,null,null,end_command);
 execute 'reset role';
 return jsonb_build_object('actor',actor,'well',well,'session',sid,'at',started,
  'pump',pump,'farm',farm,'account',account,'start_command',start_command,'end_command',end_command,
  'charge',completion->'session_charge_id');
exception when others then execute 'reset role';raise;
end;$$;

-- Calls are made as authenticated, never as the fixture owner/bypass-RLS role.
create function pg_temp.r6c2a_detail(sid uuid) returns jsonb language plpgsql as $$
declare result jsonb;
begin
 execute 'set local role authenticated';
 result:=api.get_session_detail(sid);
 execute 'reset role';return result;
exception when others then execute 'reset role';raise;
end;$$;

create function pg_temp.r6c2a_list(well uuid,from_time timestamptz default null,to_time timestamptz default null)
returns jsonb language plpgsql as $$
declare result jsonb;
begin
 execute 'set local role authenticated';
 result:=api.list_well_sessions(well,null,from_time,to_time,false,200);
 execute 'reset role';return result;
exception when others then execute 'reset role';raise;
end;$$;

-- `segments` is the current timeline consumed by SessionDetailScreen. Original
-- execution evidence remains in storage (and may be exposed separately), but
-- cannot silently occupy the existing current-timeline field after correction.
create function pg_temp.r6c2a_timeline_matches(detail jsonb) returns boolean language sql as $$
 select coalesce(
  jsonb_typeof(detail->'segments')='array'
  and jsonb_array_length(detail->'segments')>0
  and (detail->'segments'->0->>'started_at')::timestamptz=
      (detail->'session'->>'effective_started_at')::timestamptz
  and (detail->'segments'->-1->>'ended_at')::timestamptz=
      (detail->'session'->>'effective_ended_at')::timestamptz
  and not exists (
   select 1 from (
    select value,lag((value->>'ended_at')::timestamptz) over(order by ordinal) as prior_end
    from jsonb_array_elements(detail->'segments') with ordinality as e(value,ordinal)
   ) timeline
   where (value->>'started_at')::timestamptz is null
    or (value->>'ended_at')::timestamptz is null
    or (value->>'started_at')::timestamptz >= (value->>'ended_at')::timestamptz
    or (prior_end is not null and prior_end is distinct from (value->>'started_at')::timestamptz)
    or (value->>'actual_seconds')::bigint is distinct from
       extract(epoch from ((value->>'ended_at')::timestamptz-(value->>'started_at')::timestamptz))::bigint
  )
  and (select sum((value->>'actual_seconds')::bigint)
       from jsonb_array_elements(detail->'segments'))=(detail->'session'->>'actual_seconds')::bigint,
 false);
$$;

-- Only confirmed financial presentation is compared here: operational times may
-- advance while these values still belong to the last financially applied revision.
create function pg_temp.r6c2a_segment_money(detail jsonb) returns jsonb language sql as $$
 select jsonb_agg(jsonb_build_object('sequence_number',value->'sequence_number',
  'billable_seconds',value->'billable_seconds','applied_rate_minor',value->'applied_rate_minor',
  'time_charge_minor',value->'time_charge_minor','fuel_charge_minor',value->'fuel_charge_minor',
  'total_charge_minor',value->'total_charge_minor') order by ordinal)
 from jsonb_array_elements(detail->'segments') with ordinality as e(value,ordinal);
$$;

do $effective_facts$
declare f jsonb;foreign_fixture jsonb;sid uuid;other_sid uuid;well uuid;actor uuid;
 t timestamptz;before_detail jsonb;detail jsonb;session_data jsonb;listing jsonb;item jsonb;
 correction jsonb;correction2 jsonb;history jsonb;status_read jsonb;
 original_session jsonb;original_charge jsonb;original_segments jsonb;original_receipts jsonb;
 denied boolean;status_denied boolean;detail_error text;list_error text;
 foreign_correction jsonb;foreign_history_rows bigint;foreign_work_rows bigint;own_rows bigint;
 money_fixture jsonb;money_sid uuid;money_well uuid;money_t timestamptz;
 money_correction jsonb;review_correction jsonb;applied_result jsonb;review_result jsonb;
 applied_detail jsonb;review_detail jsonb;money_snapshot jsonb;money_after jsonb;
begin
 f:=pg_temp.r6c2a_fixture();sid:=(f->>'session')::uuid;well:=(f->>'well')::uuid;
 actor:=(f->>'actor')::uuid;t:=(f->>'at')::timestamptz;
 select to_jsonb(s)-'operational_revision' into original_session from ops.irrigation_sessions s where id=sid;
 select to_jsonb(c) into original_charge from billing.session_charges c where session_id=sid;
 select jsonb_agg(to_jsonb(s) order by sequence_number) into original_segments from ops.session_segments s where session_id=sid;
 select jsonb_agg(to_jsonb(c) order by command_id) into original_receipts from sync.processed_commands c
 where command_id in ((f->>'start_command')::uuid,(f->>'end_command')::uuid);

 before_detail:=pg_temp.r6c2a_detail(sid);session_data:=before_detail->'session';
 perform pg_temp.r6c2a_check(
  (session_data->>'original_started_at')::timestamptz=t
  and (session_data->>'original_ended_at')::timestamptz=t+interval '2 hours'
  and (session_data->>'effective_started_at')::timestamptz=t
  and (session_data->>'effective_ended_at')::timestamptz=t+interval '2 hours'
  and (session_data->>'operational_revision')::bigint=0
  and (session_data->>'started_at')::timestamptz=t
  and (session_data->>'ended_at')::timestamptz=t+interval '2 hours',
  '15 revision 0 detail explicitly preserves original and effective 08:00-10:00 facts');

 -- A second real session at 11:00-12:00 supplies an ordering counterexample.
 execute 'set local role authenticated';
 other_sid:=api.start_operational_session(well,(f->>'pump')::uuid,(f->>'farm')::uuid,
  (f->>'account')::uuid,'solar',t+interval '3 hours',gen_random_uuid());
 perform api.complete_irrigation_session(other_sid,t+interval '4 hours',null,null,null,gen_random_uuid());
 execute 'reset role';
 correction:=ops.accept_session_correction(sid,gen_random_uuid(),0,'تصحيح وقت السجل',
  t+interval '15 minutes',t+interval '2 hours 30 minutes',transaction_timestamp());
 perform pg_temp.r6c2a_check(correction->>'status'='accepted'
  and (correction->>'operational_revision')::bigint=1,'16 operational correction accepted as revision 1');

 detail:=pg_temp.r6c2a_detail(sid);session_data:=detail->'session';
 perform pg_temp.r6c2a_check(
  (session_data->>'original_started_at')::timestamptz=t
  and (session_data->>'original_ended_at')::timestamptz=t+interval '2 hours'
  and (session_data->>'effective_started_at')::timestamptz=t+interval '15 minutes'
  and (session_data->>'effective_ended_at')::timestamptz=t+interval '2 hours 30 minutes'
  and (session_data->>'operational_revision')::bigint=1
  and (session_data->>'started_at')::timestamptz=t+interval '15 minutes'
  and (session_data->>'ended_at')::timestamptz=t+interval '2 hours 30 minutes',
  '17 corrected detail keeps original 08:00-10:00 and displays effective 08:15-10:30');
 perform pg_temp.r6c2a_check((session_data->>'actual_seconds')::bigint=8100,
  '18 corrected actual elapsed duration is 8100 seconds, independently of billed duration');

 perform pg_temp.r6c2a_check(pg_temp.r6c2a_timeline_matches(detail),
  '18a current segments must match corrected 08:15-10:30 summary, not silently retain 08:00-10:00');
 perform pg_temp.r6c2a_check(original_segments=(select jsonb_agg(to_jsonb(s) order by sequence_number)
  from ops.session_segments s where session_id=sid),
  '18b effective timeline is a read projection; original segment evidence remains immutable');

 listing:=pg_temp.r6c2a_list(well);
 select value into item from jsonb_array_elements(listing->'items') where value->>'id'=sid::text;
 perform pg_temp.r6c2a_check((item->>'started_at')::timestamptz=t+interval '15 minutes'
  and (item->>'ended_at')::timestamptz=t+interval '2 hours 30 minutes'
  and (item->>'operational_revision')::bigint=1,'19 list displays corrected time and revision');
 listing:=pg_temp.r6c2a_list(well,t+interval '10 minutes',t+interval '20 minutes');
 perform pg_temp.r6c2a_check(jsonb_array_length(listing->'items')=1
  and listing->'items'->0->>'id'=sid::text,'20 list filter includes effective start absent from original-time window');
 listing:=pg_temp.r6c2a_list(well,t,t+interval '10 minutes');
 perform pg_temp.r6c2a_check(jsonb_array_length(listing->'items')=0,
  '21 original-only start window excludes corrected session');

 execute 'set local role authenticated';
 history:=api.get_session_corrections(sid);status_read:=api.get_session_correction_status(sid);
 execute 'reset role';
 perform pg_temp.r6c2a_check(history->'items'->0->>'reason'='تصحيح وقت السجل'
  and history->'items'->0->>'accepted_at' is not null
  and status_read->>'financial_status'='pending'
  and session_data->>'financial_status'='pending'
  and session_data->'total_amount_minor'=before_detail->'session'->'total_amount_minor'
  and session_data->'billable_seconds'=before_detail->'session'->'billable_seconds',
  '22 operational correction remains financially pending with original authoritative charge');

 -- Move the full interval past the 11:00 session: original ordering now differs
 -- from effective ordering, so sorting by the old timestamp cannot pass.
 correction2:=ops.accept_session_correction(sid,gen_random_uuid(),1,'نقل الوقت الفعلي الصحيح',
  t+interval '5 hours',t+interval '7 hours 15 minutes',transaction_timestamp());
 perform pg_temp.r6c2a_check((correction2->>'operational_revision')::bigint=2,'23 second correction accepted');
 listing:=pg_temp.r6c2a_list(well);
 perform pg_temp.r6c2a_check(listing->'items'->0->>'id'=sid::text
  and listing->'items'->1->>'id'=other_sid::text,'24 list orders by effective start, not original start');
 listing:=pg_temp.r6c2a_list(well,t+interval '4 hours 30 minutes',t+interval '5 hours 30 minutes');
 perform pg_temp.r6c2a_check(jsonb_array_length(listing->'items')=1
  and listing->'items'->0->>'id'=sid::text,'25 moved session is filtered by latest effective start');
 execute 'set local role authenticated';history:=api.get_session_corrections(sid);execute 'reset role';
 perform pg_temp.r6c2a_check(jsonb_array_length(history->'items')=2
  and (history->'items'->0->>'new_revision')::bigint=1
  and (history->'items'->1->>'new_revision')::bigint=2
  and (history->'items'->0->>'after_started_at')::timestamptz=t+interval '15 minutes'
  and (history->'items'->0->>'after_ended_at')::timestamptz=t+interval '2 hours 30 minutes',
  '26 correction history remains ordered and preserves the first correction');
 perform pg_temp.r6c2a_check(original_session=(select to_jsonb(s)-'operational_revision' from ops.irrigation_sessions s where id=sid)
  and original_charge=(select to_jsonb(c) from billing.session_charges c where session_id=sid)
  and original_segments=(select jsonb_agg(to_jsonb(s) order by sequence_number) from ops.session_segments s where session_id=sid)
  and original_receipts=(select jsonb_agg(to_jsonb(c) order by command_id) from sync.processed_commands c
   where command_id in ((f->>'start_command')::uuid,(f->>'end_command')::uuid)),
  '27 original execution facts, segments, charge and receipts are immutable');

 -- Independent real financial fixture: unchanged start pins the historical
 -- pricing event, so extending only the end can be financially applied.
 money_fixture:=pg_temp.r6c2a_fixture();money_sid:=(money_fixture->>'session')::uuid;
 money_well:=(money_fixture->>'well')::uuid;money_t:=(money_fixture->>'at')::timestamptz;
 perform finance.ensure_periods(money_well,money_t::date);
 money_correction:=ops.accept_session_correction(money_sid,gen_random_uuid(),0,'تمديد وقت النهاية المثبت',
  money_t,money_t+interval '2 hours 30 minutes',transaction_timestamp());
 applied_result:=billing.reconcile_session_correction((money_correction->>'correction_id')::uuid,
  gen_random_uuid(),money_t+interval '6 hours');
 perform pg_temp.r6c2a_check(applied_result->>'status'='applied'
  and (applied_result->>'financial_applied_revision')::bigint=1
  and (applied_result->>'new_amount_minor')::bigint<>(select amount_minor
   from billing.session_charges where session_id=money_sid),
  '27a fixture has a real applied reconciliation with a changed authoritative amount');
 applied_detail:=pg_temp.r6c2a_detail(money_sid);
 perform pg_temp.r6c2a_check(applied_detail->'session'->>'financial_status'='applied'
  and applied_detail->'session'->'total_amount_minor'=applied_result->'new_amount_minor'
  and (applied_detail->'session'->>'financial_applied_revision')::bigint=1,
  '27b applied detail total comes from the persisted reconciliation result');
 perform pg_temp.r6c2a_check(
  (select sum((value->>'total_charge_minor')::bigint) from jsonb_array_elements(applied_detail->'segments'))=
   (applied_result->>'new_amount_minor')::bigint
  and (select sum((value->>'billable_seconds')::bigint) from jsonb_array_elements(applied_detail->'segments'))=
   (applied_detail->'session'->>'billable_seconds')::bigint
  and (select sum((value->>'time_charge_minor')::bigint+coalesce((value->>'fuel_charge_minor')::bigint,0))
       from jsonb_array_elements(applied_detail->'segments'))=(applied_result->>'new_amount_minor')::bigint,
  '27c current segment financial amounts and billed duration agree with applied total, not original evidence');

 -- A changed current tariff must not replace accepted historical pricing.
 update billing.well_pricing set price_per_hour_minor=99999 where well_id=money_well;
 select jsonb_build_object('charge',(select to_jsonb(c) from billing.session_charges c where session_id=money_sid),
  'corrections',(select jsonb_agg(to_jsonb(c) order by operational_revision)
   from billing.session_charge_corrections c where session_id=money_sid),
  'work',(select jsonb_agg(to_jsonb(w) order by operational_revision)
   from ops.session_correction_reconciliations w where session_id=money_sid)) into money_snapshot;
 detail:=pg_temp.r6c2a_detail(money_sid);
 select jsonb_build_object('charge',(select to_jsonb(c) from billing.session_charges c where session_id=money_sid),
  'corrections',(select jsonb_agg(to_jsonb(c) order by operational_revision)
   from billing.session_charge_corrections c where session_id=money_sid),
  'work',(select jsonb_agg(to_jsonb(w) order by operational_revision)
   from ops.session_correction_reconciliations w where session_id=money_sid)) into money_after;
 perform pg_temp.r6c2a_check(detail->'session'->'total_amount_minor'=applied_result->'new_amount_minor'
  and pg_temp.r6c2a_segment_money(detail)=pg_temp.r6c2a_segment_money(applied_detail)
  and money_snapshot=money_after,
  '27d reads ignore the current tariff and do not mutate accepted charge/reconciliation evidence');

 -- Moving the billed start lacks proof of a historical pricing event. Exercise
 -- the real review path, without fabricating reconciliation rows or status.
 review_correction:=ops.accept_session_correction(money_sid,gen_random_uuid(),1,'تعديل البداية يحتاج دليل سعر',
  money_t+interval '15 minutes',money_t+interval '3 hours',transaction_timestamp());
 review_result:=billing.reconcile_session_correction((review_correction->>'correction_id')::uuid,
  gen_random_uuid(),money_t+interval '6 hours');
 perform pg_temp.r6c2a_check(review_result->>'status'='financial_review_required'
  and review_result->>'review_code'='historical_price_unproven',
  '27e fixture reaches genuine financial_review_required');
 review_detail:=pg_temp.r6c2a_detail(money_sid);
 execute 'set local role authenticated';
 status_read:=api.get_session_correction_status(money_sid);
 history:=api.get_session_corrections(money_sid);
 execute 'reset role';
 perform pg_temp.r6c2a_check(review_detail->'session'->>'financial_status'='financial_review_required'
  and status_read->>'status'='financial_review_required'
  and (status_read->>'financial_review_required')::boolean
  and history->'items'->1->>'financial_status'='financial_review_required',
  '27f detail/status/history explicitly preserve financial review rather than ordinary success');
 perform pg_temp.r6c2a_check((review_detail->'session'->>'operational_revision')::bigint=2
  and (review_detail->'session'->>'financial_applied_revision')::bigint=1
  and review_detail->'session'->'total_amount_minor'=applied_result->'new_amount_minor'
  and review_detail->'session'->'billable_seconds'=applied_detail->'session'->'billable_seconds'
  and pg_temp.r6c2a_segment_money(review_detail)=pg_temp.r6c2a_segment_money(applied_detail)
  and not exists(select 1 from billing.session_charge_corrections
   where session_id=money_sid and operational_revision=2),
  '27g review keeps the last confirmed total and segment amounts; no revision-2 financial presentation');

 foreign_fixture:=pg_temp.r6c2a_fixture();
 -- The forbidden target has a durable correction and pending work before the
 -- caller changes. A missing/empty fixture can no longer satisfy isolation.
 foreign_correction:=ops.accept_session_correction((foreign_fixture->>'session')::uuid,gen_random_uuid(),0,
  'تصحيح موجود في بئر أجنبي',(foreign_fixture->>'at')::timestamptz,
  (foreign_fixture->>'at')::timestamptz+interval '2 hours 30 minutes',transaction_timestamp());
 perform pg_temp.r6c2a_check(exists(select 1 from ops.session_corrections
  where id=(foreign_correction->>'correction_id')::uuid)
  and exists(select 1 from ops.session_correction_reconciliations
   where correction_id=(foreign_correction->>'correction_id')::uuid),
  '27h foreign fixture really contains correction history and financial work');
 perform set_config('request.jwt.claim.sub',actor::text,true);
 denied:=false;
 begin
  execute 'set local role authenticated';
  perform api.get_session_corrections((foreign_fixture->>'session')::uuid);
 exception when insufficient_privilege then denied:=true;
 end;
 execute 'reset role';
 perform pg_temp.r6c2a_check(denied,'28 correction history refuses another tenant/well');
 status_denied:=false;
 begin
  execute 'set local role authenticated';
  -- The existing status RPC takes a SESSION id, not a correction id.
  perform api.get_session_correction_status((foreign_fixture->>'session')::uuid);
 exception when insufficient_privilege then status_denied:=true;
 end;
 execute 'reset role';
 perform pg_temp.r6c2a_check(status_denied,'28a correction status refuses a session with a real foreign correction');
 execute 'set local role authenticated';
 select count(*) into foreign_history_rows from ops.session_corrections
 where id=(foreign_correction->>'correction_id')::uuid;
 select count(*) into foreign_work_rows from ops.session_correction_reconciliations
 where correction_id=(foreign_correction->>'correction_id')::uuid;
 select count(*) into own_rows from ops.session_corrections where id=(correction->>'correction_id')::uuid;
 execute 'reset role';
 perform pg_temp.r6c2a_check(foreign_history_rows=0 and foreign_work_rows=0 and own_rows=1,
  '28b RLS itself hides real foreign history/work while retaining the authorized correction');

 -- Deliberate corrupt fixture only: bypass this single revision guard as owner,
 -- then restore it before calling public reads. All DDL/data roll back below.
 set constraints all immediate;
 alter table ops.irrigation_sessions disable trigger session_correction_revision_private;
 update ops.irrigation_sessions set operational_revision=3 where id=sid;
 alter table ops.irrigation_sessions enable trigger session_correction_revision_private;
 perform pg_temp.r6c2a_check(not exists(select 1 from ops.session_corrections
  where session_id=sid and new_revision=3),'29 corrupt fixture has positive revision without matching history');
 begin
  perform pg_temp.r6c2a_detail(sid);
 exception when others then detail_error:=SQLSTATE;
 end;
 begin
  perform pg_temp.r6c2a_list(well);
 exception when others then list_error:=SQLSTATE;
 end;
 perform pg_temp.r6c2a_check(detail_error in ('55000','23514'),
  '30 inconsistent detail explicitly fails closed; permission or missing-function error is not evidence');
 perform pg_temp.r6c2a_check(list_error in ('55000','23514'),
  '31 inconsistent list explicitly fails closed instead of silently omitting or using original facts');
end;$effective_facts$;

do $fractional_segments$
declare f jsonb;sid uuid;t timestamptz;boundary_at timestamptz;effective_start timestamptz;effective_end timestamptz;
 original_session jsonb;original_segments jsonb;original_charge jsonb;original_receipts jsonb;
 result jsonb;detail jsonb;again jsonb;read_error text;financial_before jsonb;financial_after jsonb;
 first_segment jsonb;last_segment jsonb;first_duration numeric;last_duration numeric;
begin
 f:=pg_temp.r6c2a_fixture(true);sid:=(f->>'session')::uuid;t:=(f->>'at')::timestamptz;
 boundary_at:=t+interval '30 minutes 0.4 seconds';
 effective_start:=t+interval '15 minutes 0.1 seconds';
 effective_end:=t+interval '2 hours 30 minutes 0.8 seconds';
 select to_jsonb(s)-'operational_revision' into original_session from ops.irrigation_sessions s where id=sid;
 select jsonb_agg(to_jsonb(s) order by sequence_number) into original_segments from ops.session_segments s where session_id=sid;
 select to_jsonb(c) into original_charge from billing.session_charges c where session_id=sid;
 select jsonb_agg(to_jsonb(c) order by command_id) into original_receipts from sync.processed_commands c
 where tenant_id=(select tenant_id from core.wells where id=(f->>'well')::uuid);
 perform pg_temp.r6c2a_check(jsonb_array_length(original_segments)=2
  and (original_segments->0->>'ended_at')::timestamptz=boundary_at
  and (original_segments->1->>'started_at')::timestamptz=boundary_at,
  '32a fractional fixture has two real contiguous segments with exact 08:30:00.400 boundary');

 result:=ops.accept_session_correction(sid,gen_random_uuid(),0,'تصحيح دقيق لمقطعين متصلين',
  effective_start,effective_end,transaction_timestamp());
 perform pg_temp.r6c2a_check(result->>'status'='accepted'
  and (result->>'operational_revision')::bigint=1,'32b valid fractional correction accepted');
 select jsonb_build_object('charge',to_jsonb(c),
  'work',(select to_jsonb(w) from ops.session_correction_reconciliations w
   where correction_id=(result->>'correction_id')::uuid),
  'financial_history',(select jsonb_agg(to_jsonb(h) order by operational_revision)
   from billing.session_charge_corrections h where session_id=sid)) into financial_before
 from billing.session_charges c where session_id=sid;

 begin
  detail:=pg_temp.r6c2a_detail(sid);
 exception when others then read_error:=SQLSTATE;
 end;
 perform pg_temp.r6c2a_check(read_error is null,
  '32c valid contiguous fractional timeline must be readable, not rejected for independently rounded seconds; SQLSTATE='
  ||coalesce(read_error,'none'));

 first_segment:=detail->'segments'->0;last_segment:=detail->'segments'->1;
 perform pg_temp.r6c2a_check(jsonb_array_length(detail->'segments')=2
  and (detail->'session'->>'effective_started_at')::timestamptz=effective_start
  and (detail->'session'->>'effective_ended_at')::timestamptz=effective_end
  and (first_segment->>'started_at')::timestamptz=effective_start
  and (first_segment->>'ended_at')::timestamptz=boundary_at
  and (last_segment->>'started_at')::timestamptz=boundary_at
  and (last_segment->>'ended_at')::timestamptz=effective_end,
  '32d exact fractional boundaries remain unchanged, connected, gap-free and overlap-free');
 first_duration:=extract(epoch from ((first_segment->>'ended_at')::timestamptz-(first_segment->>'started_at')::timestamptz));
 last_duration:=extract(epoch from ((last_segment->>'ended_at')::timestamptz-(last_segment->>'started_at')::timestamptz));
 perform pg_temp.r6c2a_check(first_duration=900.3::numeric and last_duration=7200.4::numeric
  and first_duration+last_duration=8100.7::numeric
  and first_duration+last_duration=extract(epoch from (effective_end-effective_start)),
  '32e exact durations sum to the exact session span before any integer presentation conversion');

 -- Existing actual_seconds contracts use numeric epoch ::bigint. Keep this
 -- conversion independently for each displayed duration; do NOT assert that
 -- independently converted segment seconds must sum to converted session seconds.
 perform pg_temp.r6c2a_check((first_segment->>'actual_seconds')::bigint=900
  and (last_segment->>'actual_seconds')::bigint=7200
  and (detail->'session'->>'actual_seconds')::bigint=8101,
  '32f displayed seconds follow existing bigint conversion: 900, 7200, 8101 without a false equality constraint');
 again:=pg_temp.r6c2a_detail(sid);
 perform pg_temp.r6c2a_check(again=detail,'32g fractional presentation is deterministic across repeated reads');

 select jsonb_build_object('charge',to_jsonb(c),
  'work',(select to_jsonb(w) from ops.session_correction_reconciliations w
   where correction_id=(result->>'correction_id')::uuid),
  'financial_history',(select jsonb_agg(to_jsonb(h) order by operational_revision)
   from billing.session_charge_corrections h where session_id=sid)) into financial_after
 from billing.session_charges c where session_id=sid;
 perform pg_temp.r6c2a_check(original_session=(select to_jsonb(s)-'operational_revision' from ops.irrigation_sessions s where id=sid)
  and original_segments=(select jsonb_agg(to_jsonb(s) order by sequence_number) from ops.session_segments s where session_id=sid)
  and original_charge=(select to_jsonb(c) from billing.session_charges c where session_id=sid)
  and original_receipts=(select jsonb_agg(to_jsonb(c) order by command_id) from sync.processed_commands c
   where tenant_id=(select tenant_id from core.wells where id=(f->>'well')::uuid)
    and command_type<>'correct_irrigation_session'),
  '32h original fractional execution, financial evidence and receipts remain immutable');
 perform pg_temp.r6c2a_check(financial_before=financial_after
  and detail->'session'->>'financial_status'='pending'
  and (detail->'session'->>'financial_applied_revision')::bigint=0
  and detail->'session'->'total_amount_minor'=original_charge->'amount_minor'
  and detail->'session'->'billable_seconds'=original_charge->'duration_seconds',
  '32i fractional operational projection does not change confirmed money or apply a financial revision');
end;$fractional_segments$;

rollback;
