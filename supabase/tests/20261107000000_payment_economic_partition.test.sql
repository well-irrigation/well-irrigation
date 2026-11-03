\set ON_ERROR_STOP on
-- اختبارات محلية ملغاة؛ لا ينفذها الوكيل.
begin isolation level read committed;
set local timezone='UTC';
create function pg_temp.pp_check(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL %',label;end if;raise notice 'PASS %',label;end;$$;
create function pg_temp.pp_base(p_tenant uuid default null,p_actor uuid default null)
returns jsonb language plpgsql as $$
declare t uuid:=p_tenant; op uuid:=coalesce(p_actor,gen_random_uuid()); p uuid; fp uuid;
 w uuid; a uuid; f uuid; pump uuid; b uuid; cmd uuid:=gen_random_uuid();
 at_time timestamptz:=date_trunc('day',transaction_timestamp())-interval '4 hours';
begin
 if t is null then insert into core.tenants(name) values('إقرار تشغيل') returning id into t;end if;
 insert into auth.users(id,instance_id,aud,role,email,email_confirmed_at,created_at,updated_at)
 values(op,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',op||'@r6b.test',now(),now(),now())
 on conflict(id) do nothing;
 insert into iam.profiles(id,full_name) values(op,'مشغل إقرار') on conflict(id) do nothing;
 insert into core.wells(tenant_id,name) values(t,'بئر إقرار') returning id into w;
 insert into core.well_assignments(well_id,profile_id,role,status) values(w,op,'operator','active');
 insert into core.persons(tenant_id,full_name,normalized_name) values(t,'مزارع إقرار','مزارع إقرار') returning id into p;
 insert into ops.farmer_profiles(tenant_id,person_id) values(t,p) returning id into fp;
 insert into ops.farmer_well_accounts(tenant_id,farmer_profile_id,well_id,public_code)
 values(t,fp,w,'RB-'||substr(cmd::text,1,8)) returning id into a;
 insert into ops.farms(well_id,name,farmer_well_account_id) values(w,'أرض الإقرار',a) returning id into f;
 insert into core.pumps(well_id,name,power_source,status) values(w,'مضخة الإقرار','diesel','active') returning id into pump;
 insert into billing.well_pricing(well_id,price_per_hour_minor,period_start) values(w,3600,date '1970-01-01');
 insert into ops.shifts(tenant_id,well_id,operator_profile_id,started_at,status)
 values(t,w,op,at_time-interval '1 hour','open');
 insert into ops.irrigation_bookings(tenant_id,public_code,well_id,farmer_well_account_id,farm_id,
 scheduled_start,scheduled_end,expected_duration_minutes,expected_energy_source,status,created_by)
 values(t,'RB-'||substr(cmd::text,1,8),w,a,f,at_time+interval '30 minutes',at_time+interval '60 minutes',30,'well_diesel','confirmed',op)
 returning id into b;
 return jsonb_build_object('tenant',t,'operator',op,'well',w,'account',a,'farm',f,'pump',pump,
   'booking',b,'at',at_time,'command',cmd);
end;$$;
create function pg_temp.pp_start(f jsonb,kind text default 'start_operational_session',
 booking uuid default null,identified boolean default true) returns uuid language plpgsql as $$
declare sid uuid; cmd uuid:=case when identified then (f->>'command')::uuid end;
begin
 perform set_config('request.jwt.claim.sub',f->>'operator',true);
 execute 'set local role authenticated';
 if kind='start_operational_session' then
  sid:=api.start_operational_session((f->>'well')::uuid,(f->>'pump')::uuid,(f->>'farm')::uuid,
   (f->>'account')::uuid,'well_diesel',(f->>'at')::timestamptz,cmd,null,array['قمح'],booking);
 elsif kind='start_irrigation_session' then
  sid:=api.start_irrigation_session((f->>'well')::uuid,(f->>'pump')::uuid,(f->>'farm')::uuid,
   (f->>'account')::uuid,'well_diesel',(f->>'at')::timestamptz,null,cmd,array['قمح']);
 elsif kind='start_adhoc_session' then
  sid:=api.start_adhoc_session((f->>'well')::uuid,(f->>'pump')::uuid,(f->>'farm')::uuid,
   (f->>'account')::uuid,'well_diesel',null,(f->>'at')::timestamptz,null,cmd,array['قمح']);
 else raise exception 'unknown test start';end if;
 execute 'reset role';return sid;
exception when others then execute 'reset role';raise;
end;$$;
create function pg_temp.pp_cash(w uuid) returns jsonb language sql as $$
 select jsonb_build_object('payments',(select jsonb_agg(to_jsonb(p) order by id) from billing.payments p where p.well_id=w),
 'cash',(select jsonb_agg(to_jsonb(l) order by l.id) from finance.journal_lines l join finance.journal_entries e on e.id=l.journal_entry_id
 where e.well_id=w and l.cashbox_id is not null),'receipts',(select jsonb_agg(to_jsonb(c) order by c.id) from sync.processed_commands c
 where c.tenant_id=(select tenant_id from core.wells where id=w)));
$$;

create function pg_temp.pp_fixture(amount bigint default 10000,allocated bigint default 2000) returns jsonb language plpgsql as $$
declare f jsonb;g jsonb;sida uuid;sidb uuid;ra jsonb;rb jsonb;pay jsonb;invoice uuid;allocation uuid;person uuid;partner uuid;
begin
 f:=pg_temp.pp_base();f:=f||jsonb_build_object('at',(f->>'at')::timestamptz-interval '1 day');
 update ops.shifts set started_at=(f->>'at')::timestamptz-interval '1 hour' where well_id=(f->>'well')::uuid;
 sida:=pg_temp.pp_start(f);
 execute 'set local role authenticated';
 ra:=api.complete_irrigation_session(p_session_id=>sida,p_ended_at=>(f->>'at')::timestamptz+(amount::text||' seconds')::interval,p_command_id=>gen_random_uuid());
 execute 'reset role';
 g:=f||jsonb_build_object('command',gen_random_uuid(),'at',(f->>'at')::timestamptz+interval '4 hours');
 sidb:=pg_temp.pp_start(g);
 execute 'set local role authenticated';
 rb:=api.complete_irrigation_session(p_session_id=>sidb,p_ended_at=>(g->>'at')::timestamptz+(amount::text||' seconds')::interval,p_command_id=>gen_random_uuid());
 invoice:=api.issue_session_invoice(sidb);
 pay:=api.record_payment(p_well_id=>(f->>'well')::uuid,p_farmer_well_account_id=>(f->>'account')::uuid,
  p_amount_minor=>amount,p_method=>'cash',p_session_charge_id=>(ra->>'session_charge_id')::uuid,
  p_paid_at=>(g->>'at')::timestamptz+(amount::text||' seconds')::interval,p_command_id=>gen_random_uuid());
 if allocated>0 then
  perform api.allocate_payment((pay->>'payment_id')::uuid,jsonb_build_array(jsonb_build_object('invoice_id',invoice,'amount_minor',allocated)));
 end if;
 execute 'reset role';
 select id into allocation from billing.payment_allocations where payment_id=(pay->>'payment_id')::uuid and invoice_id=invoice;
 select fp.person_id into person from ops.farmer_profiles fp join ops.farmer_well_accounts a on a.farmer_profile_id=fp.id where a.id=(f->>'account')::uuid;
 insert into core.well_partners(tenant_id,well_id,person_id,phone,period_start)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,person,'777777777',date '1970-01-01') returning id into partner;
 insert into core.ownership_share_versions(tenant_id,well_id,partner_id,ownership_percentage,profit_percentage,effective_period)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,partner,100,100,daterange(date '1970-01-01',null,'[)'));
 return f||jsonb_build_object('session_a',sida,'session_b',sidb,'charge_a',ra->'session_charge_id','charge_b',rb->'session_charge_id',
  'invoice_b',invoice,'payment',pay->'payment_id','allocation',allocation,'receipt',pay);
exception when others then execute 'reset role';raise;
end;$$;
create function pg_temp.pp_release(f jsonb,amount bigint,source uuid) returns jsonb language sql as $$
 select billing.release_payment_allocation((f->>'allocation')::uuid,amount,source,1,'سبب محفوظ  ',(f->>'at')::timestamptz);
$$;
create function pg_temp.pp_restore(f jsonb,amount bigint,source uuid) returns jsonb language sql as $$
 select billing.restore_payment_allocation((f->>'allocation')::uuid,amount,source,1,'استعادة نقل',(f->>'at')::timestamptz);
$$;
create function pg_temp.pp_debt(f jsonb,amount bigint) returns void language sql as $$
 -- تجهيز دين مصحح فقط؛ لا مسار تصحيح جلسة في الإنتاج.
 update billing.session_charges set amount_minor=amount where id=(f->>'charge_a')::uuid;
$$;
create function pg_temp.pp_conserved(f jsonb) returns boolean language sql as $$
 select least(explicit_allocated_minor,effective_direct_minor,credit_backed_minor,remaining_minor)>=0
  and explicit_allocated_minor+effective_direct_minor+credit_backed_minor+remaining_minor=amount_minor
 from billing.payment_economic_applications where payment_id=(f->>'payment')::uuid;
$$;
do $tests$
declare f jsonb;g jsonb;r jsonb;z jsonb;b jsonb;cash jsonb;original jsonb;allocation jsonb;credit uuid;app uuid;invoice uuid;cycle uuid;
 source uuid:=gen_random_uuid();restore_source uuid:=gen_random_uuid();denied boolean;raw_credit jsonb;raw_app jsonb;posting jsonb;n integer;
begin
 f:=pg_temp.pp_fixture(10000,3000);
 cash:=pg_temp.pp_cash((f->>'well')::uuid);
 original:=(select to_jsonb(p) from billing.payments p where id=(f->>'payment')::uuid);
 allocation:=(select to_jsonb(a) from billing.payment_allocations a where id=(f->>'allocation')::uuid);
 perform pg_temp.pp_check((select explicit_allocated_minor=3000 and direct_capacity_minor=7000 and effective_direct_minor=7000
  from billing.payment_economic_applications where payment_id=(f->>'payment')::uuid),'C D canonical dual link transfers 3000 and settles default 7000');
 perform pg_temp.pp_check(pg_temp.pp_conserved(f),'no monetary unit appears twice');
 execute 'set local role authenticated';b:=api.get_session_detail((f->>'session_a')::uuid);execute 'reset role';
 perform pg_temp.pp_check(b->'session'->>'paid_amount_minor'='7000','AB current session read uses partition');
 perform pg_temp.pp_check((select debt_minor=10000 from reporting.farmer_account_balances where farmer_well_account_id=(f->>'account')::uuid),
  'AA A debt 3000 plus B debt 7000 exactly once');
 r:=pg_temp.pp_release(f,3000,source);
 perform pg_temp.pp_check(r->>'status'='accepted' and r->>'credit_amount_minor'='0'
  and (select effective_direct_minor=10000 and explicit_allocated_minor=0 from billing.payment_economic_applications where payment_id=(f->>'payment')::uuid),
  'J K full original debt receives released value before credit');
 perform pg_temp.pp_check(not exists(select 1 from billing.account_credits where payment_id=(f->>'payment')::uuid),'K no credit for value restored directly');
 perform pg_temp.pp_check(pg_temp.pp_release(f,3000,source)=r,'exact release replay unchanged');
 denied:=false;begin perform pg_temp.pp_release(f,2999,source);exception when invalid_parameter_value then denied:=true;end;
 perform pg_temp.pp_check(denied,'changed release replay rejected');
 z:=pg_temp.pp_restore(f,3000,restore_source);
 perform pg_temp.pp_check(z->>'status'='accepted' and (select effective_direct_minor=7000 and explicit_allocated_minor=3000
  from billing.payment_economic_applications where payment_id=(f->>'payment')::uuid),'O restore transfers direct value away again');
 perform pg_temp.pp_check(pg_temp.pp_restore(f,3000,restore_source)=z and pg_temp.pp_conserved(f),'restore replay no duplicate value');
 perform pg_temp.pp_check(original=(select to_jsonb(p) from billing.payments p where id=(f->>'payment')::uuid)
  and allocation=(select to_jsonb(a) from billing.payment_allocations a where id=(f->>'allocation')::uuid)
  and cash=pg_temp.pp_cash((f->>'well')::uuid),'F H T V payment receipt raw allocation and cash unchanged');
 execute 'set local role authenticated';
 z:=api.record_payment(p_well_id=>(f->>'well')::uuid,p_farmer_well_account_id=>(f->>'account')::uuid,
  p_amount_minor=>1000,p_method=>'cash',p_allocations=>jsonb_build_array(jsonb_build_object('invoice_id',(f->>'invoice_b')::uuid,'amount_minor',1000)),
  p_command_id=>gen_random_uuid());execute 'reset role';
 perform pg_temp.pp_check((select explicit_allocated_minor=1000 and effective_direct_minor=0 from billing.payment_economic_applications
  where payment_id=(z->>'payment_id')::uuid),'B allocation only payment is used once');
 -- الدين الأصغر: فائض كامل إلى دفتر الائتمان القائم.
 g:=pg_temp.pp_fixture();perform pg_temp.pp_debt(g,8000);
 r:=pg_temp.pp_release(g,2000,gen_random_uuid());credit:=(r->>'credit_id')::uuid;
 perform pg_temp.pp_check(r->>'credit_amount_minor'='2000' and (select effective_direct_minor=8000 and credit_backed_minor=2000 and remaining_minor=0
  from billing.payment_economic_applications where payment_id=(g->>'payment')::uuid),'L N smaller debt issues only genuine excess credit');
 perform pg_temp.pp_check((select amount_minor=2000 and source_type='payment_repartition' from billing.account_credits where id=credit),
  'AC existing credit ledger retains explicit repartition origin');
 z:=pg_temp.pp_restore(g,2000,gen_random_uuid());
 perform pg_temp.pp_check(z->>'status'='accepted' and (select available_minor=0 and reversed_minor=2000 from billing.account_credit_balances where id=credit)
  and (select explicit_allocated_minor=2000 and effective_direct_minor=8000 from billing.payment_economic_applications where payment_id=(g->>'payment')::uuid),
  'P restore withdraws released credit instead of duplicating it');
 perform pg_temp.pp_check(pg_temp.pp_conserved(g),'restoration and live credit conserve source');
 -- الحالة الجزئية 9000: 1000 يرجع مباشرة و1000 رصيد، ثم عكس متناسب.
 g:=pg_temp.pp_fixture();perform pg_temp.pp_debt(g,9000);
 r:=pg_temp.pp_release(g,2000,gen_random_uuid());credit:=(r->>'credit_id')::uuid;
 perform pg_temp.pp_check(r->>'credit_amount_minor'='1000' and (select effective_direct_minor=9000 and credit_backed_minor=1000
  from billing.payment_economic_applications where payment_id=(g->>'payment')::uuid),'M partial split 1000 direct and 1000 credit');
 z:=pg_temp.pp_restore(g,2000,gen_random_uuid());
 perform pg_temp.pp_check(z->>'status'='accepted' and (select effective_direct_minor=8000 and explicit_allocated_minor=2000 and credit_backed_minor=0
  from billing.payment_economic_applications where payment_id=(g->>'payment')::uuid),'O P partial restore takes direct portion and withdraws credit portion');
 -- المستهلك سابقًا: لا تحرير آلي لدين آخر دون أساس أعمال؛ مراجعة محفوظة.
 g:=pg_temp.pp_fixture();perform pg_temp.pp_debt(g,8000);r:=pg_temp.pp_release(g,2000,gen_random_uuid());credit:=(r->>'credit_id')::uuid;
 raw_credit:=(select to_jsonb(c) from billing.account_credits c where id=credit);
 z:=billing.apply_account_credit(credit,(g->>'invoice_b')::uuid,2000,gen_random_uuid(),1,'استخدام رصيد',(g->>'at')::timestamptz);
 app:=(z->>'application_id')::uuid;raw_app:=(select to_jsonb(a) from billing.account_credit_applications a where id=app);
 source:=gen_random_uuid();z:=pg_temp.pp_restore(g,2000,source);
 perform pg_temp.pp_check(z->>'status'='financial_review_required' and z->>'reason'='credit_already_used_requires_reconciliation'
  and (select effective_direct_minor=8000 and explicit_allocated_minor=0 from billing.payment_economic_applications where payment_id=(g->>'payment')::uuid),
  'Q R spent credit cannot be duplicated by restore');
 perform pg_temp.pp_check(pg_temp.pp_restore(g,2000,source)=z,'review replay exact');
 perform billing.release_credit_application(app,2000,gen_random_uuid(),1,'تحرير تطبيق مصرح',(g->>'at')::timestamptz);
 z:=pg_temp.pp_restore(g,2000,gen_random_uuid());
 perform pg_temp.pp_check(z->>'status'='accepted' and raw_app=(select to_jsonb(a) from billing.account_credit_applications a where id=app)
  and raw_credit=(select to_jsonb(c) from billing.account_credits c where id=credit),'Q U C0.1 release enables explicit later restore without rewriting history');
 perform pg_temp.pp_check(pg_temp.pp_conserved(g),'value conserved after already-used credit reconciliation');
 -- رابط الجلسة نفسه: تحويل وليس تسديدًا ثانيًا.
 g:=pg_temp.pp_fixture(10000,0);
 perform pg_temp.pp_check((select effective_direct_minor=10000 and explicit_allocated_minor=0 from billing.payment_economic_applications
  where payment_id=(g->>'payment')::uuid),'A direct only payment once');
 execute 'set local role authenticated';invoice:=api.issue_session_invoice((g->>'session_a')::uuid);
 perform api.allocate_payment((g->>'payment')::uuid,jsonb_build_array(jsonb_build_object('invoice_id',invoice,'amount_minor',3000)));
 execute 'reset role';
 perform pg_temp.pp_check((select paid_minor=10000 and outstanding_minor=0 from billing.invoice_effective_balances where invoice_id=invoice)
  and (select explicit_allocated_minor=3000 and effective_direct_minor=7000 from billing.payment_economic_applications where payment_id=(g->>'payment')::uuid),
  'E S same-session dual link settles once');
 -- متبقّ نقدي أصلي، لا سند قبض جديد عند إعادة تصنيفه إلى credit.
 g:=pg_temp.pp_fixture(10000,0);perform pg_temp.pp_debt(g,8000);cash:=pg_temp.pp_cash((g->>'well')::uuid);
 execute 'set local role authenticated';b:=api.get_available_customer_credit((g->>'account')::uuid);execute 'reset role';
 perform pg_temp.pp_check(b->>'unapplied_payment_minor'='2000','AC original unapplied value remains a distinct source');
 source:=gen_random_uuid();r:=billing.rebalance_payment_capacity((g->>'payment')::uuid,source,1,'تصنيف فرق الدين',(g->>'at')::timestamptz);
 perform pg_temp.pp_check(r->>'credit_amount_minor'='2000' and billing.rebalance_payment_capacity((g->>'payment')::uuid,source,1,'تصنيف فرق الدين',(g->>'at')::timestamptz)=r,
  'rebalance direct correction uses original source once');
 perform pg_temp.pp_check(cash=pg_temp.pp_cash((g->>'well')::uuid)
  and not exists(select 1 from billing.invoices where session_id=(g->>'session_a')::uuid)
  and not exists(select 1 from billing.payment_allocations where payment_id=(g->>'payment')::uuid),'V W X no fake payment invoice or allocation for direct rebalance');
 -- قبض ثانٍ سدّد العجز: التحرير لا يزيح تسديده ويصدر credit للجزء الزائد فقط.
 b:=pg_temp.pp_fixture();execute 'set local role authenticated';
 z:=api.record_payment(p_well_id=>(b->>'well')::uuid,p_farmer_well_account_id=>(b->>'account')::uuid,
  p_amount_minor=>2000,p_method=>'cash',p_session_charge_id=>(b->>'charge_a')::uuid,
  p_paid_at=>(b->>'at')::timestamptz+interval '8 hours',p_command_id=>gen_random_uuid());execute 'reset role';
 z:=pg_temp.pp_release(b,2000,gen_random_uuid());
 perform pg_temp.pp_check(z->>'credit_amount_minor'='2000' and (select effective_direct_minor=8000
  from billing.payment_economic_applications where payment_id=(b->>'payment')::uuid)
  and (select direct_settled_minor=10000 from billing.session_economic_settlements where session_charge_id=(b->>'charge_a')::uuid),
  'release first satisfies unmet default debt and never displaces another valid payment');
 -- أمثلة حدود/خصائص حتمية: كل نتيجة جزء من المقبوض الأصلي.
 for n in 1..5 loop
  b:=pg_temp.pp_fixture();perform pg_temp.pp_debt(b,8000+n*400);
  z:=pg_temp.pp_release(b,2000,gen_random_uuid());
  perform pg_temp.pp_check((z->>'credit_amount_minor')::bigint=2000-n*400 and pg_temp.pp_conserved(b),
   'boundary routing property independently expected 1600 1200 800 400 0');
 end loop;
 perform set_config('request.jwt.claim.sub',g->>'operator',true);
 -- النقد والتوزيع لا يعيدان تصنيف الوجهة كقبض جديد.
 execute 'set local role authenticated';b:=api.get_reports_summary((g->>'well')::uuid,'custom',
  (g->>'at')::timestamptz-interval '1 day',(g->>'at')::timestamptz+interval '2 days');execute 'reset role';
 perform pg_temp.pp_check((select sum((value->>'collected_minor')::bigint) from jsonb_array_elements(b->'financial_trends'))=10000,'G cash reporting unchanged');
 cycle:=finance.calculate_profit_distribution((g->>'well')::uuid,(g->>'at')::timestamptz-interval '1 day',
  (g->>'at')::timestamptz+interval '2 days',(g->>'operator')::uuid,0);
 perform pg_temp.pp_check((select eligible_collections_minor=10000 from finance.profit_distribution_cycles where id=cycle),'AD one payment contributes one collection');
 perform pg_temp.pp_check(billing.rebalance_payment_capacity((g->>'payment')::uuid,source,1,'تصنيف فرق الدين',(g->>'at')::timestamptz)=r
  and (select status='calculated' from finance.profit_distribution_cycles where id=cycle),
  'exact replay returns original result and does not invalidate a newer cycle');
 -- التحرير بلا سياق مفتوح يرفض ذريًا؛ التصحيح بتاريخ مفتوح مستقل أدناه.
 g:=pg_temp.pp_fixture();perform pg_temp.pp_debt(g,8000);
 posting:=(select jsonb_agg(to_jsonb(j) order by id) from finance.journal_entries j where well_id=(g->>'well')::uuid);
 perform finance.ensure_periods((g->>'well')::uuid,((g->>'at')::timestamptz)::date);
 update finance.accounting_periods set status='closed' where well_id=(g->>'well')::uuid;
 cash:=pg_temp.pp_cash((g->>'well')::uuid);
 n:=(select count(*) from billing.customer_credit_events where well_id=(g->>'well')::uuid);
 denied:=false;begin perform pg_temp.pp_release(g,2000,gen_random_uuid());
 exception when raise_exception then
  denied:=SQLERRM like 'لا يمكن ترحيل القيد: الفترة المحاسبية المحتوية للتاريخ % مغلقة';end;
 perform pg_temp.pp_check(denied and not exists(select 1 from billing.account_credits where payment_id=(g->>'payment')::uuid)
  and not exists(select 1 from billing.payment_allocation_adjustments where allocation_id=(g->>'allocation')::uuid)
  and not exists(select 1 from billing.payment_repartition_events where payment_id=(g->>'payment')::uuid)
  and n=(select count(*) from billing.customer_credit_events where well_id=(g->>'well')::uuid)
  and cash=pg_temp.pp_cash((g->>'well')::uuid)
  and posting=(select jsonb_agg(to_jsonb(j) order by id) from finance.journal_entries j where well_id=(g->>'well')::uuid)
  and (select effective_allocated_minor=2000 from billing.effective_payment_allocations where id=(g->>'allocation')::uuid),'Z closed accounting rejects with no release or review effect');
 perform pg_temp.pp_check(posting=(select jsonb_agg(to_jsonb(j) order by id) from finance.journal_entries j
  where id in(select (value->>'id')::uuid from jsonb_array_elements(posting))),'Z original posted history immutable');
 z:=billing.release_payment_allocation((g->>'allocation')::uuid,2000,gen_random_uuid(),1,'فترة مفتوحة',
  date_trunc('year',(g->>'at')::timestamptz)+interval '2 years');
 perform pg_temp.pp_check(z->>'status'='accepted' and not exists(select 1 from finance.accounting_periods where well_id=(g->>'well')::uuid
  and ((g->>'at')::timestamptz)::date between starts_at and ends_at and status<>'closed'),'closed history stays closed while new correction posts in open context');
 perform pg_temp.pp_check(not exists(select 1 from finance.journal_lines l join finance.journal_entries j on j.id=l.journal_entry_id
  join finance.ledger_accounts a on a.id=l.ledger_account_id where j.source_type='customer_credit' and a.account_code not in ('1100','2000')),
  'Y transfer and reclassification never post cash');
 -- فشل ترحيل طفل سحب الائتمان يعيد كل الأطفال ويحفظ مراجعة الأب فقط.
 g:=pg_temp.pp_fixture();perform pg_temp.pp_debt(g,8000);r:=pg_temp.pp_release(g,2000,gen_random_uuid());credit:=(r->>'credit_id')::uuid;
 update finance.accounting_periods set status='closed' where well_id=(g->>'well')::uuid;
 z:=pg_temp.pp_restore(g,2000,gen_random_uuid());
 perform pg_temp.pp_check(z->>'status'='financial_review_required' and z->>'reason'='accounting_period_closed'
  and (select available_minor=2000 and reversed_minor=0 from billing.account_credit_balances where id=credit)
  and not exists(select 1 from billing.payment_repartition_events where parent_event_id=(z->>'event_id')::uuid),
  'Z closed child posting leaves no partial credit reversal or restore');
 z:=billing.restore_payment_allocation((g->>'allocation')::uuid,2000,gen_random_uuid(),1,'سياق تسوية مفتوح',
  date_trunc('year',(g->>'at')::timestamptz)+interval '2 years');
 perform pg_temp.pp_check(z->>'status'='accepted' and pg_temp.pp_conserved(g),'new explicit open-context restore posts complete child effect set');
 -- مصدر آخر/بئر آخر/حقوق العميل.
 perform set_config('request.jwt.claim.sub',f->>'operator',true);denied:=false;
 begin perform pg_temp.pp_release(g,1,gen_random_uuid());exception when insufficient_privilege then denied:=true;end;
 perform pg_temp.pp_check(denied,'AH cross tenant account well denied');
 execute 'set local role authenticated';denied:=false;
 begin perform billing.rebalance_payment_capacity((f->>'payment')::uuid,gen_random_uuid(),1,'ممنوع',(f->>'at')::timestamptz);
 exception when insufficient_privilege then denied:=true;end;
 perform pg_temp.pp_check(denied,'AE no arbitrary client repartition');
 denied:=false;begin insert into billing.payment_repartition_events(event_id) values(gen_random_uuid());exception when insufficient_privilege then denied:=true;end;
 perform pg_temp.pp_check(denied,'AF Direct DML denied');execute 'reset role';execute 'set local role anon';denied:=false;
 begin perform billing.restore_payment_allocation((f->>'allocation')::uuid,1,gen_random_uuid(),1,'ممنوع',(f->>'at')::timestamptz);
 exception when insufficient_privilege then denied:=true;end;execute 'reset role';
 perform pg_temp.pp_check(denied,'AG anon denied');
 update core.well_assignments set status='inactive' where well_id=(f->>'well')::uuid and profile_id=(f->>'operator')::uuid;
 denied:=false;begin perform billing.rebalance_payment_capacity((f->>'payment')::uuid,gen_random_uuid(),1,'اختبار الصلاحية',(f->>'at')::timestamptz);
 exception when insufficient_privilege then denied:=true;end;
 perform pg_temp.pp_check(denied,'AE inactive assignment cannot invoke even internal business boundary');
 update core.well_assignments set status='active' where well_id=(f->>'well')::uuid and profile_id=(f->>'operator')::uuid;
 execute 'set local role authenticated';
 z:=api.record_payment((f->>'well')::uuid,(f->>'account')::uuid,2000,'cash','[]'::jsonb,p_command_id=>gen_random_uuid());
 b:=api.get_available_customer_credit((f->>'account')::uuid);
 r:=api.get_advance_allocation_proposal((z->>'payment_id')::uuid,(f->>'invoice_b')::uuid);execute 'reset role';
 perform pg_temp.pp_check(b->>'cash_advance_minor'='2000' and r->>'proposed_minor'='2000','AC legitimate cash advance stays a distinct available source');
 denied:=false;begin perform billing.rebalance_payment_capacity((z->>'payment_id')::uuid,gen_random_uuid(),1,'تصنيف غير لازم',(f->>'at')::timestamptz);
 exception when invalid_parameter_value then denied:=true;end;
 perform pg_temp.pp_check(denied,'cash advance cannot be reissued as duplicate credit liability');
 denied:=false;begin perform billing.rebalance_payment_capacity((f->>'payment')::uuid,null,1,'هوية لازمة',(f->>'at')::timestamptz);
 exception when invalid_parameter_value then denied:=true;end;
 perform pg_temp.pp_check(denied,'mandatory original source identity without fallback');
 denied:=false;begin
  insert into billing.payment_allocations(tenant_id,payment_id,invoice_id,allocated_minor)
   values((f->>'tenant')::uuid,(f->>'payment')::uuid,(g->>'invoice_b')::uuid,1);
  perform explicit_allocated_minor from billing.payment_economic_applications where payment_id=(f->>'payment')::uuid;
 exception when check_violation then denied:=true;end;
 perform pg_temp.pp_check(denied,'AH inconsistent historical allocation scope fails closed without normalization');
 perform pg_temp.pp_check(not exists(select 1 from billing.customer_credit_events group by tenant_id,source_id,source_revision having count(*)>1),
  'AN stable source revision unique across parent and child effects');
end;$tests$;
set constraints all immediate;
rollback;
