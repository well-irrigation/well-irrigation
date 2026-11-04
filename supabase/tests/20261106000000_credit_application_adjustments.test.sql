\set ON_ERROR_STOP on
-- اختبار محلي ملغى؛ لم يشغله الوكيل. لا تعديل أوقات جلسة أو مبلغ فاتورة إنتاجيًا.
begin isolation level read committed;
set local timezone='UTC';
create function pg_temp.c01_check(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL %',label;end if;
 raise notice 'PASS %',label;end;$$;
create function pg_temp.c01_fixture(p_total bigint default 10000,p_paid bigint default 10000)
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
create function pg_temp.c01_release(f jsonb,amount bigint,source uuid,revision bigint default 1) returns jsonb
language sql as $$select billing.release_payment_allocation((f->>'allocation')::uuid,amount,source,revision,
 'سبب اختبار محفوظ  ',(f->>'at')::timestamptz);$$;
create function pg_temp.c01_apply(credit uuid,invoice uuid,amount bigint,source uuid,at_time timestamptz) returns jsonb
language sql as $$select billing.apply_account_credit(credit,invoice,amount,source,1,'تطبيق رصيد',at_time);$$;
create function pg_temp.c01_cash_snapshot(w uuid) returns jsonb language sql as $$
 select jsonb_build_object('payments',(select jsonb_agg(to_jsonb(p) order by id) from billing.payments p where p.well_id=w),
 'cash',(select jsonb_agg(to_jsonb(l) order by l.id) from finance.journal_lines l join finance.journal_entries e on e.id=l.journal_entry_id
 where e.well_id=w and l.cashbox_id is not null),'receipts',(select jsonb_agg(to_jsonb(c) order by c.id) from sync.processed_commands c
 where c.tenant_id=(select tenant_id from core.wells where id=w)));
$$;
create function pg_temp.c01_invoice(f jsonb,amount bigint) returns uuid language plpgsql as $$
declare i uuid;
begin
 insert into billing.invoices(tenant_id,public_code,well_id,farmer_well_account_id,invoice_date,status,
 subtotal_minor,total_minor,paid_minor,outstanding_minor)
 values((f->>'tenant')::uuid,core.generate_public_code('INV'),(f->>'well')::uuid,(f->>'account')::uuid,
 (f->>'at')::timestamptz,'draft',amount,amount,0,amount) returning id into i;
 update billing.invoices set status='issued' where id=i;return i;
end;$$;
-- تجهيز تصحيح مالي مستقل للجداول والقيود؛ ليس API إنتاجيًا أو تعديل جلسة.
create function pg_temp.c01_debt_fixture(f jsonb,new_total bigint) returns void language plpgsql as $$
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
-- إنشاء تطبيق أصلي صحيح عبر أدوات C0؛ لا تلاعب بتاريخ الدفع/التطبيق.
create function pg_temp.c01_applied() returns jsonb language plpgsql as $$
declare f jsonb;r jsonb;i uuid;a jsonb;
begin
 f:=pg_temp.c01_fixture();r:=pg_temp.c01_release(f,2000,gen_random_uuid());
 i:=pg_temp.c01_invoice(f,2000);
 a:=pg_temp.c01_apply((r->>'credit_id')::uuid,i,2000,gen_random_uuid(),(f->>'at')::timestamptz);
 return f||jsonb_build_object('original_invoice',f->'invoice','invoice',i,'credit',r->'credit_id','application',a->'application_id');
end;$$;
create function pg_temp.c01_adjust(f jsonb,operation text,amount bigint,source uuid) returns jsonb language sql as $$
 select billing.adjust_credit_application((f->>'application')::uuid,operation,amount,source,1,
 'سبب محفوظ  ',(f->>'at')::timestamptz);
$$;
do $test$
declare f jsonb;g jsonb;r jsonb;s jsonb;b jsonb;raw jsonb;cash jsonb;posting jsonb;original_credit jsonb;
 src uuid:=gen_random_uuid();restore_src uuid:=gen_random_uuid();invoice uuid;j uuid;cycle uuid;cash_payment uuid;
 n bigint;denied boolean;original_period uuid;
begin
 f:=pg_temp.c01_applied();
 raw:=(select to_jsonb(a) from billing.account_credit_applications a where id=(f->>'application')::uuid);
 original_credit:=(select to_jsonb(c) from billing.account_credits c where id=(f->>'credit')::uuid);
 cash:=pg_temp.c01_cash_snapshot((f->>'well')::uuid);
 posting:=(select jsonb_agg(to_jsonb(e) order by e.id) from finance.journal_entries e where well_id=(f->>'well')::uuid);
 perform pg_temp.c01_debt_fixture(f,1000);
 r:=pg_temp.c01_adjust(f,'release',1000,src);
 perform pg_temp.c01_check(r->>'status'='accepted','B release accepted');
 perform pg_temp.c01_check(raw=(select to_jsonb(a) from billing.account_credit_applications a where id=(f->>'application')::uuid),'A J original application history unchanged');
 perform pg_temp.c01_check((select amount_minor=2000 and released_minor=1000 and restored_minor=0 and effective_amount_minor=1000
  from billing.effective_account_credit_applications where id=(f->>'application')::uuid),'B canonical effective application');
 perform pg_temp.c01_check((select used_minor=1000 and available_minor=1000 from billing.account_credit_balances where id=(f->>'credit')::uuid),'C released value available exactly once');
 perform pg_temp.c01_check(original_credit=(select to_jsonb(c) from billing.account_credits c where id=(f->>'credit')::uuid)
  and (select available_minor=0 from billing.payment_available_balances where payment_id=(f->>'payment')::uuid),
  'credit source unchanged and original payment reservation not released twice');
 perform pg_temp.c01_check((select paid_minor=1000 and outstanding_minor=0 from billing.invoices where id=(f->>'invoice')::uuid),'K L effective invoice not overpaid by raw history');
 perform pg_temp.c01_check(pg_temp.c01_adjust(f,'release',1000,src)=r,'E release exact replay');
 perform pg_temp.c01_check((select count(*)=1 from billing.account_credit_application_adjustments where source_id=src)
  and (select count(*)=1 from finance.journal_entries where source_type='customer_credit' and source_id=(r->>'event_id')::uuid),
  'E AK replay creates one adjustment and one correcting entry');
 perform pg_temp.c01_check(finance.compute_reserved_liabilities((f->>'well')::uuid)=1000,
  'Z released value contributes customer liability exactly once');
 denied:=false;begin perform pg_temp.c01_adjust(f,'release',999,src);exception when invalid_parameter_value then denied:=true;end;
 perform pg_temp.c01_check(denied,'F changed release replay rejected');
 denied:=false;begin perform pg_temp.c01_adjust(f,'release',1001,gen_random_uuid());exception when check_violation then denied:=true;end;
 perform pg_temp.c01_check(denied,'D cannot over release');
 execute 'set local role authenticated';
 b:=api.get_available_customer_credit((f->>'account')::uuid);
 execute 'reset role';
 perform pg_temp.c01_check(b->>'noncash_credit_minor'='1000','M available API inherits effective usage');
 invoice:=pg_temp.c01_invoice(f,1500);
 execute 'set local role authenticated';
 b:=api.get_customer_credit_proposal((f->>'account')::uuid,invoice,'account_credit',(f->>'credit')::uuid);
 execute 'reset role';
 perform pg_temp.c01_check(b->>'proposed_minor'='1000','N proposal uses released value');
 perform pg_temp.c01_check((select noncash_credit_minor=1000 from reporting.farmer_account_balances where farmer_well_account_id=(f->>'account')::uuid),'O account balances inherit effective credit');
 select journal_entry_id into j from billing.customer_credit_events where id=(r->>'event_id')::uuid;
 perform pg_temp.c01_check((select count(*)=2 and sum(amount_minor)=2000 and bool_and(cashbox_id is null)
  from finance.journal_lines where journal_entry_id=j)
  and exists(select 1 from finance.journal_lines l join finance.ledger_accounts a on a.id=l.ledger_account_id
   where l.journal_entry_id=j and a.account_code='1100' and l.entry_side='debit' and l.amount_minor=1000)
  and exists(select 1 from finance.journal_lines l join finance.ledger_accounts a on a.id=l.ledger_account_id
   where l.journal_entry_id=j and a.account_code='2000' and l.entry_side='credit' and l.amount_minor=1000),'I exact proportional inverse without cash');
 perform pg_temp.c01_debt_fixture(f,1500);
 s:=pg_temp.c01_adjust(f,'restore',500,restore_src);
 perform pg_temp.c01_check(s->>'status'='accepted' and (select effective_amount_minor=1500 from billing.effective_account_credit_applications
  where id=(f->>'application')::uuid),'S restore within prior release');
 perform pg_temp.c01_check((select available_minor=500 from billing.account_credit_balances where id=(f->>'credit')::uuid),'T restore consumes availability');
 perform pg_temp.c01_check(pg_temp.c01_adjust(f,'restore',500,restore_src)=s,'W restore replay');
 perform pg_temp.c01_check((select count(*)=1 from billing.account_credit_application_adjustments where source_id=restore_src)
  and finance.compute_reserved_liabilities((f->>'well')::uuid)=500,'W Z restore unique and liability reduced once');
 denied:=false;begin perform pg_temp.c01_adjust(f,'restore',501,restore_src);exception when invalid_parameter_value then denied:=true;end;
 perform pg_temp.c01_check(denied,'X changed restore replay rejected');
 denied:=false;begin perform pg_temp.c01_adjust(f,'restore',501,gen_random_uuid());exception when check_violation then denied:=true;end;
 perform pg_temp.c01_check(denied,'U restore cannot inflate original application');
 perform pg_temp.c01_check(cash=pg_temp.c01_cash_snapshot((f->>'well')::uuid),'G H Y no payment cashbox or receipt changes');
 perform pg_temp.c01_check(posting=(select jsonb_agg(to_jsonb(e) order by e.id) from finance.journal_entries e
  where e.id in(select (value->>'id')::uuid from jsonb_array_elements(posting))),'AA original posted entries preserved');
 -- استخدام المتاح في مكان آخر يمنع الاستعادة الصامتة.
 perform pg_temp.c01_apply((f->>'credit')::uuid,invoice,500,gen_random_uuid(),(f->>'at')::timestamptz);
 perform pg_temp.c01_debt_fixture(f,2000);
 s:=pg_temp.c01_adjust(f,'restore',500,gen_random_uuid());
 perform pg_temp.c01_check(s->>'status'='financial_review_required' and s->>'reason'='credit_unavailable'
  and (select effective_amount_minor=1500 from billing.effective_account_credit_applications where id=(f->>'application')::uuid),'V spent credit not restored or made negative');
 -- عكس المصدر بعد التحرير يستعمل الصافي ويمنع صرف القيمة مرتين.
 g:=pg_temp.c01_applied();perform pg_temp.c01_adjust(g,'release',1000,gen_random_uuid());
 s:=billing.reverse_account_credit((g->>'credit')::uuid,1000,gen_random_uuid(),1,'عكس المصدر',(g->>'at')::timestamptz);
 perform pg_temp.c01_check(s->>'restored_minor'='1000' and (select used_minor=1000 and available_minor=0
  from billing.account_credit_balances where id=(g->>'credit')::uuid),'Q R source reversal sees effective applications');
 s:=pg_temp.c01_adjust(g,'restore',500,gen_random_uuid());
 perform pg_temp.c01_check(s->>'status'='financial_review_required' and s->>'reason'='credit_unavailable',
  'source-restored value cannot be spent again by application restore');
 -- عكس قيمة مستهلكة سابقًا: التحرير اللاحق محفوظ للمراجعة ولا يحيي رصيدًا.
 g:=pg_temp.c01_applied();
 s:=billing.reverse_account_credit((g->>'credit')::uuid,1000,gen_random_uuid(),1,'عكس مستهلك',(g->>'at')::timestamptz);
 perform pg_temp.c01_check(s->>'receivable_review_minor'='1000','source reversal fixture has consumed review');
 s:=pg_temp.c01_adjust(g,'release',1000,gen_random_uuid());
 perform pg_temp.c01_check(s->>'status'='financial_review_required' and s->>'reason'='source_reversal_review_required'
  and (select available_minor=0 and used_minor=2000 from billing.account_credit_balances where id=(g->>'credit')::uuid),
  'R release after consumed source reversal cannot resurrect credit');
 -- تقارير النقد والتوزيع تبقى من القبض الحقيقي بعد التحرير والاستعادة.
 perform set_config('request.jwt.claim.sub',f->>'operator',true);
 execute 'set local role authenticated';
 b:=api.get_reports_summary((f->>'well')::uuid,'custom',(f->>'at')::timestamptz-interval '1 day',
  (f->>'at')::timestamptz+interval '1 day');
 execute 'reset role';
 perform pg_temp.c01_check((select sum((value->>'collected_minor')::bigint) from jsonb_array_elements(b->'financial_trends'))=10000,
  'Y actual cash report unchanged by release and restore');
 cycle:=finance.calculate_profit_distribution((f->>'well')::uuid,(f->>'at')::timestamptz-interval '1 hour',
  (f->>'at')::timestamptz+interval '1 hour',(f->>'operator')::uuid,0);
 perform pg_temp.c01_check((select eligible_collections_minor=10000 from finance.profit_distribution_cycles where id=cycle),
  'Z noncash adjustments never become distribution collection');
 g:=pg_temp.c01_fixture(10000,12000);
 select id into cash_payment from billing.payments where farmer_well_account_id=(g->>'account')::uuid and purpose='advance';
 invoice:=pg_temp.c01_invoice(g,1000);
 execute 'set local role authenticated';
 b:=api.get_advance_allocation_proposal(cash_payment,invoice);
 perform api.allocate_payment(cash_payment,jsonb_build_array(jsonb_build_object('invoice_id',invoice,'amount_minor',500)));
 s:=api.get_available_customer_credit((g->>'account')::uuid);
 execute 'reset role';
 perform pg_temp.c01_check(b->>'advance_remaining_minor'='2000' and s->>'cash_advance_minor'='1500'
  and s->>'noncash_credit_minor'='0','P cash advance proposal and allocation remain unchanged');
 -- الفترة الأصلية مغلقة؛ أثر جديد في فترة مفتوحة، ثم محاولة مغلقة محفوظة للمراجعة.
 g:=pg_temp.c01_applied();perform finance.ensure_periods((g->>'well')::uuid,((g->>'at')::timestamptz)::date);
 update finance.accounting_periods set status='closed' where well_id=(g->>'well')::uuid;
 src:=gen_random_uuid();s:=pg_temp.c01_adjust(g,'release',500,src);
 perform pg_temp.c01_check(s->>'status'='financial_review_required' and s->>'reason'='accounting_period_closed'
  and (select effective_amount_minor=2000 from billing.effective_account_credit_applications where id=(g->>'application')::uuid),
  'closed posting returns durable review without partial release');
 perform pg_temp.c01_check(pg_temp.c01_adjust(g,'release',500,src)=s,'closed review replay exact');
 r:=billing.release_credit_application((g->>'application')::uuid,500,gen_random_uuid(),1,'سياق مفتوح',
  (date_trunc('year',(g->>'at')::timestamptz)+interval '2 years')::timestamptz);
 perform pg_temp.c01_check(r->>'status'='accepted' and exists(select 1 from finance.journal_entries e
  where e.id=(select journal_entry_id from billing.customer_credit_events where id=(r->>'event_id')::uuid)
  and e.entry_date::date>=((date_trunc('year',(g->>'at')::timestamptz)+interval '2 years')::date)),
  'AB correction can post in allowed context without reopening historical period');
 perform pg_temp.c01_check(not exists(select 1 from finance.accounting_periods where well_id=(g->>'well')::uuid
  and ((g->>'at')::timestamptz)::date between starts_at and ends_at and status<>'closed'),'AA closed historical period remains closed');
 -- الصلاحيات والنطاق وحفظ الآثار.
 perform set_config('request.jwt.claim.sub',f->>'operator',true);
 denied:=false;begin perform pg_temp.c01_adjust(g,'release',1,gen_random_uuid());exception when insufficient_privilege then denied:=true;end;
 perform pg_temp.c01_check(denied,'AF cross tenant account denied');
 execute 'set local role authenticated';denied:=false;
 begin perform pg_temp.c01_adjust(f,'release',1,gen_random_uuid());exception when insufficient_privilege then denied:=true;end;
 perform pg_temp.c01_check(denied,'AC client cannot call arbitrary adjustment');
 denied:=false;begin insert into billing.account_credit_application_adjustments(id) values(gen_random_uuid());exception when insufficient_privilege then denied:=true;end;
 perform pg_temp.c01_check(denied,'AD direct INSERT denied');execute 'reset role';execute 'set local role anon';denied:=false;
 begin perform billing.release_credit_application((f->>'application')::uuid,1,gen_random_uuid(),1,'ممنوع',(f->>'at')::timestamptz);
 exception when insufficient_privilege then denied:=true;end;
 execute 'reset role';perform pg_temp.c01_check(denied,'AE anon denied');
 perform pg_temp.c01_check(not has_table_privilege('authenticated','billing.account_credit_application_adjustments','UPDATE')
  and not has_table_privilege('authenticated','billing.account_credit_application_adjustments','DELETE'),'AD no update delete grants');
 denied:=false;begin update billing.account_credit_applications set amount_minor=1 where id=(f->>'application')::uuid;
 exception when check_violation then denied:=true;end;
 perform pg_temp.c01_check(denied,'A original application immutable');
 denied:=false;begin delete from billing.account_credit_application_adjustments where status='accepted';exception when check_violation then denied:=true;end;
 perform pg_temp.c01_check(denied,'adjustments append only');
 perform pg_temp.c01_check(not exists(select 1 from billing.customer_credit_events group by tenant_id,source_id,source_revision having count(*)>1),'AK source revision uniqueness');
 denied:=false;begin perform pg_temp.c01_adjust(f,'release',1,null);exception when invalid_parameter_value then denied:=true;end;
 perform pg_temp.c01_check(denied,'mandatory original source identity without fallback');
 denied:=false;begin perform billing.release_credit_application((f->>'application')::uuid,1,gen_random_uuid(),null,
  'سبب',(f->>'at')::timestamptz);exception when invalid_parameter_value then denied:=true;end;
 perform pg_temp.c01_check(denied,'source revision mandatory');
 denied:=false;begin perform billing.restore_credit_application((f->>'application')::uuid,1,gen_random_uuid(),1,
  '   ',(f->>'at')::timestamptz);exception when invalid_parameter_value then denied:=true;end;
 perform pg_temp.c01_check(denied,'whitespace reason rejected');
 perform pg_temp.c01_check((select reason='سبب محفوظ  ' from billing.account_credit_application_adjustments
  where application_id=(f->>'application')::uuid and operation='release' and status='accepted' limit 1),
  'exact reason retained with original whitespace');
end;$test$;
set constraints all immediate;
rollback;
