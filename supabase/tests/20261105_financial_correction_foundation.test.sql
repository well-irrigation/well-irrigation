\set ON_ERROR_STOP on
-- اختبار محلي ملغى؛ لم يشغله الوكيل. لا تعديل أوقات جلسة أو مبلغ فاتورة إنتاجيًا.
begin;
set local timezone='UTC';
create function pg_temp.c0_check(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL %',label;end if;
 raise notice 'PASS %',label;end;$$;
create function pg_temp.c0_fixture(p_total bigint default 10000,p_paid bigint default 10000)
returns jsonb language plpgsql as $$
declare t uuid; person uuid; fp uuid; actor uuid:=gen_random_uuid();w uuid;a uuid;i uuid;payment uuid;allocation uuid;
 cmd uuid:=gen_random_uuid();r jsonb;partner uuid;at_time timestamptz:=transaction_timestamp();
begin
 insert into core.tenants(name) values('أساس تصحيح مالي') returning id into t;
 insert into auth.users(id,instance_id,aud,role,email,email_confirmed_at,created_at,updated_at)
 values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@c0.test',now(),now(),now());
 insert into iam.profiles(id,full_name) values(actor,'مالك اختبار') on conflict(id) do nothing;
 insert into core.wells(tenant_id,name) values(t,'بئر أساس مالي') returning id into w;
 insert into core.well_assignments(well_id,profile_id,role,status) values(w,actor,'owner','active');
 insert into core.persons(tenant_id,full_name,normalized_name) values(t,'مزارع مالي','مزارع مالي') returning id into person;
 insert into ops.farmer_profiles(tenant_id,person_id) values(t,person) returning id into fp;
 insert into ops.farmer_well_accounts(tenant_id,well_id,farmer_profile_id,public_code)
 values(t,w,fp,'C0-'||substr(actor::text,1,8)) returning id into a;
 insert into core.well_partners(tenant_id,well_id,person_id,phone,period_start)
 values(t,w,person,'777777777',date '1970-01-01') returning id into partner;
 insert into core.ownership_share_versions(tenant_id,well_id,partner_id,ownership_percentage,profit_percentage,effective_period)
 values(t,w,partner,100,100,daterange(date '1970-01-01',null,'[)'));
 insert into billing.invoices(tenant_id,public_code,well_id,farmer_well_account_id,invoice_date,status,
 subtotal_minor,total_minor,paid_minor,outstanding_minor)
 values(t,'C0-'||substr(actor::text,1,8),w,a,at_time,'draft',p_total,p_total,0,p_total) returning id into i;
 update billing.invoices set status='issued' where id=i;
 perform set_config('request.jwt.claim.sub',actor::text,true);
 execute 'set local role authenticated';
 r:=api.record_payment(p_well_id=>w,p_farmer_well_account_id=>a,p_amount_minor=>p_paid,
 p_method=>'cash',p_allocations=>jsonb_build_array(jsonb_build_object('invoice_id',i,'amount_minor',least(p_total,p_paid))),
 p_command_id=>cmd);
 execute 'reset role';
 select pa.id,pa.payment_id into allocation,payment from billing.payment_allocations pa where pa.invoice_id=i;
 return jsonb_build_object('tenant',t,'well',w,'account',a,'operator',actor,'invoice',i,'payment',payment,
 'allocation',allocation,'payment_command',cmd,'at',at_time);
exception when others then execute 'reset role';raise;
end;$$;
create function pg_temp.c0_release(f jsonb,amount bigint,source uuid,revision bigint default 1) returns jsonb
language sql as $$select billing.release_payment_allocation((f->>'allocation')::uuid,amount,source,revision,
 'سبب اختبار محفوظ  ',(f->>'at')::timestamptz);$$;
create function pg_temp.c0_apply(credit uuid,invoice uuid,amount bigint,source uuid,at_time timestamptz) returns jsonb
language sql as $$select billing.apply_account_credit(credit,invoice,amount,source,1,'تطبيق رصيد',at_time);$$;
create function pg_temp.c0_cash_snapshot(w uuid) returns jsonb language sql as $$
 select jsonb_build_object('payments',(select jsonb_agg(to_jsonb(p) order by id) from billing.payments p where p.well_id=w),
 'cash',(select jsonb_agg(to_jsonb(l) order by l.id) from finance.journal_lines l join finance.journal_entries e on e.id=l.journal_entry_id
 where e.well_id=w and l.cashbox_id is not null),'receipts',(select jsonb_agg(to_jsonb(c) order by c.id) from sync.processed_commands c
 where c.tenant_id=(select tenant_id from core.wells where id=w)));
$$;
create function pg_temp.c0_invoice(f jsonb,amount bigint) returns uuid language plpgsql as $$
declare i uuid;
begin
 insert into billing.invoices(tenant_id,public_code,well_id,farmer_well_account_id,invoice_date,status,
 subtotal_minor,total_minor,paid_minor,outstanding_minor)
 values((f->>'tenant')::uuid,core.generate_public_code('INV'),(f->>'well')::uuid,(f->>'account')::uuid,
 (f->>'at')::timestamptz,'draft',amount,amount,0,amount) returning id into i;
 update billing.invoices set status='issued' where id=i;return i;
end;$$;
-- تجهيز تصحيح مالي مستقل للجداول والقيود؛ ليس API إنتاجيًا أو تعديل جلسة.
create function pg_temp.c0_debt_fixture(f jsonb,new_total bigint) returns void language plpgsql as $$
declare old_total bigint;j uuid;delta bigint;
begin
 select total_minor into old_total from billing.invoices where id=(f->>'invoice')::uuid;
 delta:=abs(new_total-old_total);
 update billing.invoices set total_minor=new_total,subtotal_minor=new_total,
 paid_minor=least(paid_minor,new_total),outstanding_minor=new_total-least(paid_minor,new_total)
 where id=(f->>'invoice')::uuid;
 if delta=0 then return;end if;
 insert into finance.journal_entries(tenant_id,well_id,public_code,entry_date,source_type,source_id,description,idempotency_key)
 values((f->>'tenant')::uuid,(f->>'well')::uuid,core.generate_public_code('JE'),(f->>'at')::timestamptz,
 'fixture_debt_correction',gen_random_uuid(),'تجهيز حقيقة مالية مصححة','FIXTURE-'||gen_random_uuid()::text) returning id into j;
 insert into finance.journal_lines(tenant_id,journal_entry_id,ledger_account_id,entry_side,amount_minor,farmer_well_account_id)
 values((f->>'tenant')::uuid,j,finance.ledger_account_id((f->>'well')::uuid,'1100'),
 case when new_total>old_total then 'debit' else 'credit' end,delta,(f->>'account')::uuid),
 ((f->>'tenant')::uuid,j,finance.ledger_account_id((f->>'well')::uuid,'4000'),
 case when new_total>old_total then 'credit' else 'debit' end,delta,(f->>'account')::uuid);
 perform finance.post_journal_entry(j,(f->>'operator')::uuid);
end;$$;
do $test$
declare f jsonb;g jsonb;h jsonb;r jsonb;replay jsonb;src uuid:=gen_random_uuid();appsrc uuid:=gen_random_uuid();
 credit uuid;invoice uuid;small_invoice uuid;cash_payment uuid;cycle uuid;entry uuid;reverse_source uuid:=gen_random_uuid();
 cycle_snapshot jsonb;policy_id uuid;before_state jsonb;original_allocation jsonb;original_posting jsonb;original_lines jsonb;
 origin uuid:=gen_random_uuid();effect1 uuid:=gen_random_uuid();effect2 uuid:=gen_random_uuid();
 invalid_reason text;invalid_amount bigint;advance_allocation uuid;balances jsonb;denied boolean;baseline jsonb;
begin
 f:=pg_temp.c0_fixture();
 original_allocation:=(select to_jsonb(a) from billing.payment_allocations a where id=(f->>'allocation')::uuid);
 original_posting:=(select jsonb_agg(to_jsonb(j) order by id) from finance.journal_entries j where well_id=(f->>'well')::uuid);
 original_lines:=(select jsonb_agg(to_jsonb(l) order by l.id) from finance.journal_lines l
  join finance.journal_entries j on j.id=l.journal_entry_id where j.well_id=(f->>'well')::uuid);
 before_state:=pg_temp.c0_cash_snapshot((f->>'well')::uuid);
 cycle:=finance.calculate_profit_distribution((f->>'well')::uuid,(f->>'at')::timestamptz-interval '1 hour',
  (f->>'at')::timestamptz+interval '1 hour',(f->>'operator')::uuid,0);
 -- تجهيز الحقيقة المالية المصححة فقط؛ الأساس لا يغيّر total_minor في الإنتاج.
 perform pg_temp.c0_debt_fixture(f,8000);
 r:=pg_temp.c0_release(f,2000,src);credit:=(r->>'credit_id')::uuid;
 perform pg_temp.c0_check((select status='cancelled' from finance.profit_distribution_cycles where id=cycle)
  and r->'invalidated_distribution_cycles' @> to_jsonb(array[cycle]),
  'distribution derived cache invalidated with causal source reference');
 perform pg_temp.c0_check((select effective_allocated_minor=8000 and released_minor=2000 from billing.effective_payment_allocations
   where id=(f->>'allocation')::uuid),'B Z effective allocation includes release once');
 perform pg_temp.c0_check(original_allocation=(select to_jsonb(a) from billing.payment_allocations a where id=(f->>'allocation')::uuid),
   'A original allocation byte value stable');
 perform pg_temp.c0_check(before_state=pg_temp.c0_cash_snapshot((f->>'well')::uuid),'G H T X Y credit adds no cash payment refund or receipt mutation');
 perform pg_temp.c0_check((select paid_minor=8000 and outstanding_minor=0 from billing.invoices where id=(f->>'invoice')::uuid)
   and (select available_minor=2000 from billing.account_credit_balances where id=credit),
   'AA corrected debt 8000 has 2000 noncash credit');
 perform pg_temp.c0_check((select available_minor=0 from billing.payment_available_balances where payment_id=(f->>'payment')::uuid),
   'released payment cannot be spent again alongside issued credit');
 perform pg_temp.c0_check(finance.compute_reserved_liabilities((f->>'well')::uuid)=2000,
  'AH released nonadvance collection becomes reserved customer liability once');
 perform pg_temp.c0_check(pg_temp.c0_release(f,2000,src)=r,'D I exact release and credit replay');

 execute 'set local role authenticated';
 balances:=api.get_farmer_account((f->>'account')::uuid);
 perform pg_temp.c0_check(balances->'account'->>'noncash_credit_minor'='2000'
  and balances->'account'->>'available_credit_minor'='2000'
  and balances->'payments'->0->'effective_allocations'->0->>'effective_minor'='8000',
  'Z account API shows effective allocation and separate customer credit');
 balances:=api.list_well_farmer_balances((f->>'well')::uuid);
 perform pg_temp.c0_check(balances->'items'->0->>'debt_minor'='0'
  and balances->'items'->0->>'noncash_credit_minor'='2000','AG balance API consumes effective debt once');
 balances:=api.list_well_farmer_directory((f->>'well')::uuid);
 perform pg_temp.c0_check(balances->'items'->0->>'noncash_credit_minor'='2000','directory exposes customer credit separately');
 balances:=api.get_reports_summary((f->>'well')::uuid,'custom',(f->>'at')::timestamptz-interval '1 day',
  (f->>'at')::timestamptz+interval '1 day');
 execute 'reset role';
 perform pg_temp.c0_check((select sum((item->>'collected_minor')::bigint) from
  jsonb_array_elements(balances->'financial_trends') as t(item))=10000,
  'S actual cash report excludes noncash credit issuance');

 select journal_entry_id into entry from billing.customer_credit_events where id=(r->>'event_id')::uuid;
 denied:=false;begin perform finance.reverse_journal_entry(entry,'عكس عام غير صالح',(f->>'operator')::uuid);
 exception when check_violation then denied:=true;end;
 perform pg_temp.c0_check(denied and (select status='posted' from finance.journal_entries where id=entry),
  'credit posting cannot be reversed without domain ledger reconciliation');
 denied:=false;begin perform billing.reverse_payment((f->>'payment')::uuid,'إبطال رصيد قائم',(f->>'operator')::uuid);
 exception when check_violation then denied:=true;end;
 perform pg_temp.c0_check(denied and before_state=pg_temp.c0_cash_snapshot((f->>'well')::uuid),
  'original payment cannot be reversed while backing active credit');

 denied:=false;begin perform pg_temp.c0_release(f,2001,src);exception when invalid_parameter_value then denied:=true;end;
 perform pg_temp.c0_check(denied,'E J changed source payload rejected');
 denied:=false;begin perform billing.release_payment_allocation((f->>'allocation')::uuid,2000,src,1,
  'سبب اختبار محفوظ  ',(f->>'at')::timestamptz,gen_random_uuid());exception when invalid_parameter_value then denied:=true;end;
 perform pg_temp.c0_check(denied,'source ancestry cannot change on replay');
 denied:=false;begin perform pg_temp.c0_release(f,8001,gen_random_uuid());exception when check_violation then denied:=true;end;
 perform pg_temp.c0_check(denied,'C release cannot exceed effective allocation');
 denied:=false;begin update billing.payment_allocations set allocated_minor=1 where id=(f->>'allocation')::uuid;
 exception when check_violation then denied:=true;end;
 perform pg_temp.c0_check(denied,'original allocation update blocked');
 invoice:=pg_temp.c0_invoice(f,3000);
 execute 'set local role authenticated';
 balances:=api.get_available_customer_credit((f->>'account')::uuid);
 replay:=api.get_customer_credit_proposal((f->>'account')::uuid,invoice,'account_credit',credit);
 execute 'reset role';
 perform pg_temp.c0_check(balances->>'total_available_minor'='2000' and replay->>'proposed_minor'='2000','K R unified source availability and proposal');
 r:=pg_temp.c0_apply(credit,invoice,1000,appsrc,(f->>'at')::timestamptz);
 perform pg_temp.c0_check((select available_minor=1000 and used_minor=1000 from billing.account_credit_balances where id=credit)
   and (select paid_minor=1000 and outstanding_minor=2000 from billing.invoices where id=invoice),'L credit application updates debt once');
 perform pg_temp.c0_check(pg_temp.c0_apply(credit,invoice,1000,appsrc,(f->>'at')::timestamptz)=r,'application exact replay');
 denied:=false;begin perform pg_temp.c0_apply(credit,invoice,1001,appsrc,(f->>'at')::timestamptz);
 exception when invalid_parameter_value then denied:=true;end;
 perform pg_temp.c0_check(denied,'application changed replay rejected');
 denied:=false;begin perform pg_temp.c0_apply(credit,invoice,1001,gen_random_uuid(),(f->>'at')::timestamptz);
 exception when check_violation then denied:=true;end;
 perform pg_temp.c0_check(denied,'M credit over application rejected');
 small_invoice:=pg_temp.c0_invoice(f,10);denied:=false;
 begin perform pg_temp.c0_apply(credit,small_invoice,11,gen_random_uuid(),(f->>'at')::timestamptz);
 exception when check_violation then denied:=true;end;
 perform pg_temp.c0_check(denied,'cannot apply more than eligible outstanding debt');
 g:=pg_temp.c0_fixture();perform set_config('request.jwt.claim.sub',f->>'operator',true);
 denied:=false;begin perform pg_temp.c0_apply(credit,(g->>'invoice')::uuid,1,gen_random_uuid(),(f->>'at')::timestamptz);
 exception when check_violation then denied:=true;end;
 perform pg_temp.c0_check(denied,'N cross account well tenant application rejected');
 denied:=false;begin perform pg_temp.c0_release(g,1,gen_random_uuid());exception when insufficient_privilege then denied:=true;end;
 perform pg_temp.c0_check(denied,'cross well allocation release denied even at private business boundary');
 -- زيادة الدين الصحيحة تجهيز فقط؛ التراجع يعيد غير المستهلك إلى التخصيص الأصلي.
 perform pg_temp.c0_debt_fixture(f,10000);
 r:=billing.reverse_account_credit(credit,2000,reverse_source,1,'تصحيح لاحق',(f->>'at')::timestamptz);
 perform pg_temp.c0_check(r->>'status'='financial_review_required' and r->>'restored_minor'='1000'
   and r->>'receivable_review_minor'='1000' and (select available_minor=0 from billing.account_credit_balances where id=credit),
   'U V consumed credit preserved with explicit receivable review');
 perform pg_temp.c0_check((select effective_allocated_minor=9000 from billing.effective_payment_allocations where id=(f->>'allocation')::uuid)
   and (select outstanding_minor=1000 from billing.invoices where id=(f->>'invoice')::uuid),'reversal restores only unused allocation value');
 perform pg_temp.c0_check(billing.reverse_account_credit(credit,2000,reverse_source,1,'تصحيح لاحق',(f->>'at')::timestamptz)=r,
   'reversal replay no duplicate restore or review');
 perform pg_temp.c0_check(before_state=pg_temp.c0_cash_snapshot((f->>'well')::uuid),'S credit issue apply reverse never adds collected cash');
 cycle:=finance.calculate_profit_distribution((f->>'well')::uuid,(f->>'at')::timestamptz-interval '1 hour',
 (f->>'at')::timestamptz+interval '1 hour',(f->>'operator')::uuid,0);
 perform pg_temp.c0_check((select eligible_collections_minor=10000 from finance.profit_distribution_cycles where id=cycle),
   'AH distribution actual collection remains original 10000');
 perform pg_temp.c0_release(f,2000,src);
 perform pg_temp.c0_check((select status='calculated' from finance.profit_distribution_cycles where id=cycle),
  'replayed source does not invalidate a newer calculated cycle');
 perform pg_temp.c0_check((select jsonb_agg(to_jsonb(j) order by id) from finance.journal_entries j
   where j.id in (select (value->>'id')::uuid from jsonb_array_elements(original_posting)))=original_posting,'posted original journal history preserved');
 perform pg_temp.c0_check(original_lines=(select jsonb_agg(to_jsonb(l) order by l.id) from finance.journal_lines l
  where l.id in (select (value->>'id')::uuid from jsonb_array_elements(original_lines))),
  'posted original journal lines remain byte value stable');
 g:=pg_temp.c0_fixture();
 perform billing.release_payment_allocation((g->>'allocation')::uuid,1000,effect1,1,'عنصر أول',(g->>'at')::timestamptz,origin);
 perform billing.release_payment_allocation((g->>'allocation')::uuid,1000,effect2,1,'عنصر ثان',(g->>'at')::timestamptz,origin);
 perform pg_temp.c0_check((select count(*)=2 and sum(amount_minor)=2000 from billing.account_credits
  where tenant_id=(g->>'tenant')::uuid and origin_source_id=origin),
  'distinct stable effects retain one original financial source');
 -- متبقي الدين يرتفع دون تعديل سند أو تخصيص؛ تثبيت حالة أصلية في اختبار مستقل.
 g:=pg_temp.c0_fixture(8000,8000);baseline:=pg_temp.c0_cash_snapshot((g->>'well')::uuid);
 perform pg_temp.c0_debt_fixture(g,10000);
 perform billing.refresh_effective_invoice((g->>'invoice')::uuid);
 perform pg_temp.c0_check((select paid_minor=8000 and outstanding_minor=2000 from billing.invoices where id=(g->>'invoice')::uuid)
   and baseline=pg_temp.c0_cash_snapshot((g->>'well')::uuid),'AB debt rises without payment mutation');
 g:=pg_temp.c0_fixture();r:=pg_temp.c0_release(g,1000,gen_random_uuid());credit:=(r->>'credit_id')::uuid;
 r:=billing.reverse_account_credit(credit,1000,gen_random_uuid(),1,'رد غير المستهلك',(g->>'at')::timestamptz);
 perform pg_temp.c0_check(r->>'status'='accepted' and r->>'restored_minor'='1000'
  and (select effective_allocated_minor=10000 from billing.effective_payment_allocations where id=(g->>'allocation')::uuid),
  'U unused credit reverses through append only restoration');
 g:=pg_temp.c0_fixture();
 perform pg_temp.c0_debt_fixture(g,9000);
 r:=pg_temp.c0_release(g,1000,gen_random_uuid());credit:=(r->>'credit_id')::uuid;
 r:=billing.reverse_account_credit(credit,1000,gen_random_uuid(),1,'لا يوجد دين يستقبل الرد',(g->>'at')::timestamptz);
 perform pg_temp.c0_check(r->>'status'='financial_review_required' and r->>'held_minor'='1000'
  and (select held_minor=1000 and available_minor=0 from billing.account_credit_balances where id=credit),
  'V unavailable restoration context explicitly holds credit for review');
 invoice:=pg_temp.c0_invoice(g,1);denied:=false;
 begin perform pg_temp.c0_apply(credit,invoice,1,gen_random_uuid(),(g->>'at')::timestamptz);
 exception when check_violation then denied:=true;end;
 perform pg_temp.c0_check(denied and finance.compute_reserved_liabilities((g->>'well')::uuid)=1000,
  'held credit cannot be spent and remains a customer liability');
 perform pg_temp.c0_check((select reason='سبب اختبار محفوظ  ' from billing.account_credits where id=credit),
  'exact reason whitespace preserved');
 perform pg_temp.c0_check(not exists(select 1 from finance.journal_lines l join finance.journal_entries j on j.id=l.journal_entry_id
  join finance.ledger_accounts a on a.id=l.ledger_account_id where j.source_type='customer_credit' and a.account_code not in ('1100','2000')),
  'noncash accounting uses existing receivable and liability accounts only');
 -- رصيد نقدي حقيقي؛ يظل مصدرًا منفصلًا ويستهلك بالكاتب القديم نفسه.
 g:=pg_temp.c0_fixture(10000,12000);
 select id into cash_payment from billing.payments where farmer_well_account_id=(g->>'account')::uuid and purpose='advance';
 r:=pg_temp.c0_release(g,1000,gen_random_uuid());
 invoice:=pg_temp.c0_invoice(g,3000);
 execute 'set local role authenticated';
 replay:=api.get_advance_allocation_proposal(cash_payment,invoice);
 perform api.allocate_payment(cash_payment,jsonb_build_array(jsonb_build_object('invoice_id',invoice,'amount_minor',1000)));
 balances:=api.get_available_customer_credit((g->>'account')::uuid);
 execute 'reset role';
 perform pg_temp.c0_check(replay->>'advance_remaining_minor'='2000' and balances->>'cash_advance_minor'='1000'
  and balances->>'noncash_credit_minor'='1000' and balances->>'total_available_minor'='2000',
  'P Q cash advance compatibility and distinguishable noncash source');
 perform pg_temp.c0_check((select advance_minor=1000 and noncash_credit_minor=1000 and available_credit_minor=2000
  from reporting.farmer_account_balances where farmer_well_account_id=(g->>'account')::uuid),'AG account balances do not double count sources');
 select id into advance_allocation from billing.payment_allocations where payment_id=cash_payment and invoice_id=invoice;
 perform billing.release_payment_allocation(advance_allocation,500,gen_random_uuid(),1,'تحرير مقدم نقدي',(g->>'at')::timestamptz);
 perform pg_temp.c0_check((select available_minor=1000 from billing.payment_available_balances where payment_id=cash_payment)
  and finance.compute_reserved_liabilities((g->>'well')::uuid)=1000,
  'cash advance backed credit is not reserved twice in distribution inputs');

 -- لا يمكن تخصيص رصيد مرتبط بالتحرير ثانيةً من سند الدفع الأصلي.
 denied:=false;begin perform billing.allocate_payment((g->>'payment')::uuid,
  jsonb_build_array(jsonb_build_object('invoice_id',invoice,'amount_minor',1)));exception when raise_exception then denied:=true;end;
 perform pg_temp.c0_check(denied,'source payment reserved value cannot double spend');
 -- تسوية من أرباح معتمدة فعلًا: لا يخمّن الأساس فرق توزيع تاريخيًا.
 h:=pg_temp.c0_fixture(10000,8000);
 insert into core.partner_irrigation_policies(tenant_id,well_id,partner_id,policy_type,period_start)
 select (h->>'tenant')::uuid,(h->>'well')::uuid,id,'deduct_from_profit',date '1970-01-01'
 from core.well_partners where well_id=(h->>'well')::uuid returning id into policy_id;
 update billing.invoices set partner_policy_id=policy_id,settlement_method='partner_profit_offset'
 where id=(h->>'invoice')::uuid;
 cycle:=finance.calculate_profit_distribution((h->>'well')::uuid,(h->>'at')::timestamptz-interval '1 hour',
  (h->>'at')::timestamptz+interval '1 hour',(h->>'operator')::uuid,0);
 perform finance.approve_profit_distribution(cycle,(h->>'operator')::uuid);
 perform pg_temp.c0_check((select sum(amount_minor)=2000 from finance.distribution_source_consumptions
  where invoice_id=(h->>'invoice')::uuid and cycle_id=cycle)
  and (select collectible_minor=0 from billing.invoice_effective_balances where invoice_id=(h->>'invoice')::uuid),
  'fixture uses real approved partner deduction');
 cycle_snapshot:=(select jsonb_build_object('cycle',to_jsonb(c),'lines',
  (select jsonb_agg(to_jsonb(l) order by l.id) from finance.profit_distribution_lines l where distribution_cycle_id=cycle))
  from finance.profit_distribution_cycles c where c.id=cycle);
 denied:=false;begin perform pg_temp.c0_release(h,1000,gen_random_uuid());
 exception when check_violation then denied:=SQLERRM='allocation_release_requires_distribution_review';end;
 perform pg_temp.c0_check(denied and cycle_snapshot=(select jsonb_build_object('cycle',to_jsonb(c),'lines',
  (select jsonb_agg(to_jsonb(l) order by l.id) from finance.profit_distribution_lines l where distribution_cycle_id=cycle))
  from finance.profit_distribution_cycles c where c.id=cycle),'approved distribution requires separate reconciliation without history rewrite');
 perform set_config('request.jwt.claim.sub',g->>'operator',true);
 -- الفترة المغلقة تحبط الحدث المالي كله دون إعفاء حرس الترحيل.
 perform finance.ensure_periods((g->>'well')::uuid,((g->>'at')::timestamptz)::date);
 update finance.accounting_periods set status='closed' where well_id=(g->>'well')::uuid;
 baseline:=(select to_jsonb(a) from billing.effective_payment_allocations a where id=(g->>'allocation')::uuid);
 denied:=false;begin perform pg_temp.c0_release(g,1,gen_random_uuid());exception when raise_exception then denied:=true;end;
 perform pg_temp.c0_check(denied and baseline=(select to_jsonb(a) from billing.effective_payment_allocations a
  where id=(g->>'allocation')::uuid),'W closed period guard preserved atomic release rollback');
 foreach invalid_reason in array array[null::text,'','   '] loop
  denied:=false;begin perform billing.release_payment_allocation((g->>'allocation')::uuid,1,gen_random_uuid(),1,
   invalid_reason,(g->>'at')::timestamptz);exception when invalid_parameter_value then denied:=true;end;
  perform pg_temp.c0_check(denied,'blank or absent reason rejected before financial posting');
 end loop;
 foreach invalid_amount in array array[0::bigint,-1::bigint] loop
  denied:=false;begin perform pg_temp.c0_release(g,invalid_amount,gen_random_uuid());
  exception when invalid_parameter_value then denied:=true;end;
  perform pg_temp.c0_check(denied,'nonpositive amount rejected');
 end loop;
 denied:=false;begin perform pg_temp.c0_release(g,9223372036854775807,gen_random_uuid());
 exception when check_violation then denied:=true;end;
 perform pg_temp.c0_check(denied,'BIGINT boundary cannot over release');
 denied:=false;begin perform pg_temp.c0_release(g,1,null);
 exception when invalid_parameter_value then denied:=true;end;
 perform pg_temp.c0_check(denied,'original financial source identity is mandatory');
 denied:=false;begin perform pg_temp.c0_release(g,1,gen_random_uuid(),null);
 exception when invalid_parameter_value then denied:=true;end;
 perform pg_temp.c0_check(denied,'financial source revision is mandatory');
 -- EXPLICIT execute denial: الوظائف الخاصة لا تصبح API سك رصيد.
 execute 'set local role authenticated';denied:=false;
 begin perform billing.release_payment_allocation((g->>'allocation')::uuid,1,gen_random_uuid(),1,'ممنوع',(g->>'at')::timestamptz);
 exception when insufficient_privilege then denied:=true;end;
 perform pg_temp.c0_check(denied,'AC authorized operator cannot mint through private primitive');
 denied:=false;begin insert into billing.account_credits(tenant_id) values((g->>'tenant')::uuid);
 exception when insufficient_privilege then denied:=true;end;
 perform pg_temp.c0_check(denied,'AD Direct DML denied');
 execute 'reset role';execute 'set local role anon';denied:=false;
 begin perform api.get_available_customer_credit((g->>'account')::uuid);exception when insufficient_privilege then denied:=true;end;
 execute 'reset role';perform pg_temp.c0_check(denied,'AE anon read denied');
 perform set_config('request.jwt.claim.sub',f->>'operator',true);execute 'set local role authenticated';denied:=false;
 begin perform api.get_available_customer_credit((g->>'account')::uuid);exception when insufficient_privilege then denied:=true;end;
 execute 'reset role';perform pg_temp.c0_check(denied,'AF cross tenant unified read denied');
 perform pg_temp.c0_check(not has_function_privilege('authenticated',
  'billing.apply_account_credit(uuid,uuid,bigint,uuid,bigint,text,timestamptz,uuid)','EXECUTE')
  and not has_function_privilege('service_role','billing.reverse_account_credit(uuid,bigint,uuid,bigint,text,timestamptz,uuid)','EXECUTE'),
  'private application and reversal cannot be called by client roles');
 denied:=false;begin update billing.payments set amount_minor=amount_minor+1 where id=(f->>'payment')::uuid;
 exception when check_violation then denied:=true;end;
 perform pg_temp.c0_check(denied,'Y posted payment amount cannot be rewritten');
 perform pg_temp.c0_check(not exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='billing' and c.relname in ('account_credits','account_credit_applications','account_credit_reversals',
   'payment_allocation_adjustments','customer_credit_events') and
   (has_table_privilege('authenticated',c.oid,'INSERT') or has_table_privilege('authenticated',c.oid,'UPDATE')
    or has_table_privilege('authenticated',c.oid,'DELETE'))),'AD all foundation Direct DML grants zero');
 denied:=false;begin update billing.account_credits set amount_minor=amount_minor+1 where id=credit;
 exception when check_violation then denied:=true;end;
 perform pg_temp.c0_check(denied,'U credit source cannot be destructively edited');
 denied:=false;begin delete from billing.account_credit_applications where credit_id in
  (select id from billing.account_credits where well_id=(f->>'well')::uuid);
 exception when check_violation then denied:=true;end;
 perform pg_temp.c0_check(denied,'V consumed credit application history cannot be removed');
 perform pg_temp.c0_check(original_allocation=(select to_jsonb(a) from billing.payment_allocations a where id=(f->>'allocation')::uuid),
  'A original allocation unchanged after full release application reversal sequence');
 perform pg_temp.c0_check(not (select prosecdef from pg_proc where oid='api.get_available_customer_credit(uuid)'::regprocedure)
  and not (select prosecdef from pg_proc where oid='api.get_customer_credit_proposal(uuid,uuid,text,uuid)'::regprocedure),
  'public credit read APIs remain security invoker');
 perform pg_temp.c0_check(not exists(select 1 from billing.customer_credit_events group by tenant_id,source_id,source_revision having count(*)>1),
  'AI stable source revision uniqueness');
end;$test$;
set constraints all immediate;
rollback;
