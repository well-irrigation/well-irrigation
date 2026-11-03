-- R6-C3 read model: show eligible current candidates separately from prior
-- sources that are retained for owner review only. No financial rows/effects
-- are created or changed by this projection.
begin;

create index if not exists distribution_sources_well_history_idx
 on finance.distribution_sources(well_id,tenant_id,partner_id,id);
create index if not exists distribution_selections_source_history_idx
 on finance.distribution_source_selections(source_id,cycle_id);

create or replace function finance.r6c2_api_get_partner_distribution_sources(p_cycle_id uuid) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare c finance.profit_distribution_cycles%rowtype;result jsonb;eligible jsonb;historical jsonb;
begin
 select * into strict c from finance.profit_distribution_cycles where id=p_cycle_id;
 if auth.uid() is null or not coalesce(iam.has_well_role(c.well_id,array['owner']),false) then
  raise exception 'distribution_owner_required' using errcode='42501';
 end if;

 with selected as materialized (
  select x.*,finance.distribution_source_availability(x.source_id) as source_state,
   finance.distribution_selection_review_state(x.id) as selection_review,
   case when s.invoice_id is not null then finance.distribution_invoice_selection_state(s.id,c.id) end as invoice_order_state
  from finance.current_distribution_source_selections x
  join finance.distribution_sources s on s.id=x.source_id
  where x.cycle_id=c.id
 ), eligible_rows as materialized (
  select x.* from selected x
  where c.status in ('calculated','under_review')
   and x.source_state->>'status'='available'
   and coalesce((x.source_state->>'available_in_distribution')::boolean,true)
   and coalesce((x.source_state->>'remaining_amount_minor')::bigint,0)>0
 ), source_states as materialized (
  select s.*,finance.distribution_source_availability(s.id) as source_state
  from finance.distribution_sources s
  where s.well_id=c.well_id and s.tenant_id=c.tenant_id
   and (
    exists(select 1 from finance.current_distribution_source_selections current
     where current.cycle_id=c.id and current.source_id=s.id)
    or exists(select 1 from finance.distribution_source_selections previous where previous.source_id=s.id)
    or exists(select 1 from finance.distribution_source_consumptions used where used.source_id=s.id)
    or exists(select 1 from finance.distribution_source_reviews review where review.source_id=s.id)
   )
 ), historical_rows as materialized (
  select s.* from source_states s
  where not exists(select 1 from eligible_rows e where e.source_id=s.id)
   and (s.source_state->>'status'<>'available'
    or not coalesce((s.source_state->>'available_in_distribution')::boolean,true)
    or coalesce((s.source_state->>'remaining_amount_minor')::bigint,0)<=0)
 )
 select
  coalesce((select jsonb_agg((to_jsonb(x)-'source_state'-'selection_review'-'invoice_order_state')||jsonb_build_object(
    'source',x.source_state,'selection_review',x.selection_review,'usage_mode',x.mode,
    'read_only',not(c.status in ('calculated','under_review')),
    'selectable',c.status in ('calculated','under_review')
     and x.source_state->>'status'='available'
     and coalesce((x.source_state->>'available_in_distribution')::boolean,true)
     and coalesce((x.source_state->>'remaining_amount_minor')::bigint,0)>0
     and not coalesce((x.invoice_order_state->>'blocked_by_older_debt')::boolean,false),
    'included_in_totals',x.amount_minor>0
   ) order by x.line_id,x.source_id) from selected x),'[]'::jsonb),
  coalesce((select jsonb_agg((to_jsonb(x)-'source_state'-'selection_review'-'invoice_order_state')||jsonb_build_object(
    'source',x.source_state,'selection_review',x.selection_review,'usage_mode',x.mode,
    'read_only',not(c.status in ('calculated','under_review')),
    'selectable',c.status in ('calculated','under_review')
     and x.source_state->>'status'='available'
     and coalesce((x.source_state->>'available_in_distribution')::boolean,true)
     and coalesce((x.source_state->>'remaining_amount_minor')::bigint,0)>0
     and not coalesce((x.invoice_order_state->>'blocked_by_older_debt')::boolean,false),
    'included_in_totals',x.amount_minor>0
   ) order by x.line_id,x.source_id) from eligible_rows x),'[]'::jsonb),
  coalesce((select jsonb_agg(jsonb_build_object(
   'source_id',s.id,'partner_id',s.partner_id,'source',s.source_state,
   'availability_status',s.source_state->>'status','usage_mode','historical_only',
   'read_only',true,'selectable',false,'automatic_use',false,'included_in_totals',false,
   'related_cycle_ids',(
    select coalesce(jsonb_agg(to_jsonb(ref.cycle_id) order by ref.cycle_id),'[]'::jsonb)
    from (
     select old.cycle_id from finance.distribution_source_selections old where old.source_id=s.id
     union
     select used.cycle_id from finance.distribution_source_consumptions used
      where used.source_id=s.id and used.cycle_id is not null
    ) ref
   ),
   'title',case when s.source_state->>'status' in ('review_required','unavailable')
    then 'يحتاج هذا المبلغ إلى مراجعة'
    when coalesce((s.source_state->>'remaining_amount_minor')::bigint,0)<=0
    then 'تم استخدام هذا المبلغ بالكامل'
    else coalesce(s.source_state->>'title','يحتاج هذا المبلغ إلى مراجعة') end,
   'message',case when s.source_state->>'status' in ('review_required','unavailable')
    then 'هذا المبلغ مرتبط بسجل سابق، لكنه غير متاح للاستخدام حاليًا. لن يدخل في حساب التوزيع حتى تتم مراجعته.'
    else coalesce(s.source_state->>'message','هذا المصدر محفوظ للرجوع إليه فقط.') end,
   'status_label',case when s.source_state->>'status' in ('review_required','unavailable')
    then 'يحتاج مراجعة' else s.source_state->>'status' end,
   'action',case when s.source_state->>'status' in ('review_required','unavailable')
    then 'مراجعة المبلغ' else 'عرض التفاصيل' end
  ) order by s.partner_id,s.id) from historical_rows s),'[]'::jsonb)
 into result,eligible,historical;

 return jsonb_build_object('sources',coalesce(result,'[]'::jsonb),
  'eligible_sources',coalesce(eligible,'[]'::jsonb),'historical_sources',coalesce(historical,'[]'::jsonb),
  'historical_sources_read_only',true,'historical_sources_included_in_totals',false,
  'cycle_status',c.status,'can_change',c.status in ('calculated','under_review'),
  'title',case when c.status in ('approved','partially_paid','paid') then 'تم اعتماد هذا التوزيع' when c.status='cancelled' then 'تحتاج مبالغ التوزيع إلى مراجعة' else 'التوزيع الحالي' end,
  'next_action',case when c.status='cancelled' then 'حساب توزيع جديد' when c.status in ('approved','partially_paid','paid') then 'عرض التفاصيل' else 'مراجعة التوزيع' end,
  'notice',case when c.status='cancelled' then 'تغيّرت مبالغ مرتبطة بهذه الدورة. راجعها واحسب توزيعًا جديدًا.' else 'راجع المبالغ والتعديلات قبل الاعتماد.' end,
  'automatic_notice','سيتم احتساب هذا المبلغ تلقائيًا','manual_action','استخدام مبلغ مختلف',
  'confirm_action','استخدام هذا المبلغ','revert_action','العودة للاحتساب التلقائي',
  'labels',jsonb_build_array('المبلغ الأصلي','المستخدم سابقًا','المتبقي','الحالة','المبلغ الذي تريد استخدامه','السبب'),
  'historical_title','يحتاج هذا المبلغ إلى مراجعة',
  'historical_message','هذا المبلغ مرتبط بسجل سابق، لكنه غير متاح للاستخدام حاليًا. لن يدخل في حساب التوزيع حتى تتم مراجعته.',
  'historical_status_label','يحتاج مراجعة');
end;$$;

commit;
