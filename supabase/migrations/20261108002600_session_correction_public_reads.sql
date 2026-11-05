begin;

-- R6-C2A: read-only access through api. Business schemas stay unexposed.
alter table ops.session_corrections enable row level security;
alter table ops.session_correction_reconciliations enable row level security;

create policy session_corrections_read_authorized
on ops.session_corrections for select to authenticated
using (
 exists (
  select 1 from ops.irrigation_sessions s
  join core.wells w on w.id=s.well_id
  join core.well_assignments a on a.well_id=w.id
  where s.id=session_corrections.session_id
   and w.id=session_corrections.well_id
   and w.tenant_id=session_corrections.tenant_id
   and a.profile_id=(select auth.uid()) and a.status='active'
 ) and coalesce(iam.has_well_permission(well_id,'session.correct'),false)
);

create policy session_correction_reconciliations_read_authorized
on ops.session_correction_reconciliations for select to authenticated
using (
 exists (
  select 1 from ops.session_corrections c
  where c.id=session_correction_reconciliations.correction_id
   and c.session_id=session_correction_reconciliations.session_id
   and c.new_revision=session_correction_reconciliations.operational_revision
 )
);

revoke all on ops.session_corrections,ops.session_correction_reconciliations
 from public,anon,authenticated;
grant select on ops.session_corrections,ops.session_correction_reconciliations
 to authenticated;

create function api.get_session_corrections(p_session_id uuid)
returns jsonb language plpgsql stable security invoker
set search_path=pg_catalog,pg_temp as $function$
declare items jsonb;well uuid;
begin
 if auth.uid() is null then
  raise exception 'يجب تسجيل الدخول لقراءة التصحيحات' using errcode='28000';
 end if;
 if p_session_id is null then
  raise exception 'معرّف الجلسة مطلوب' using errcode='22023';
 end if;
 select s.well_id into well from ops.irrigation_sessions s
 where s.id=p_session_id;
 if well is null or not exists(select 1 from core.well_assignments a
   where a.well_id=well and a.profile_id=auth.uid() and a.status='active')
   or not coalesce(iam.has_well_permission(well,'session.correct'),false) then
  raise exception 'لا توجد صلاحية لقراءة تصحيحات هذه الجلسة' using errcode='42501';
 end if;
 select coalesce(jsonb_agg(jsonb_build_object(
  'correction_id',c.id,'session_id',c.session_id,
  'previous_revision',c.previous_revision,'new_revision',c.new_revision,
  'operational_revision',c.new_revision,
  'before_started_at',c.before_started_at,'before_ended_at',c.before_ended_at,
  'after_started_at',c.after_started_at,'after_ended_at',c.after_ended_at,
  'reason',c.reason,'requested_at',c.requested_at,'accepted_at',c.accepted_at,
  'financial_status',coalesce(work.status,'pending'),
  'financial_review_required',coalesce(work.status='financial_review_required',false),
  'financial_review_reason',case when work.status='financial_review_required'
    then 'يحتاج الأثر المالي إلى مراجعة' else null end
 ) order by c.new_revision),'[]'::jsonb) into items
 from ops.session_corrections c
 left join ops.session_correction_reconciliations work on work.correction_id=c.id
 where c.session_id=p_session_id;
 return jsonb_build_object('contract','get_session_corrections','version',1,
  'session_id',p_session_id,'items',items);
end;$function$;

create function api.get_session_correction_status(p_session_id uuid)
returns jsonb language plpgsql stable security invoker
set search_path=pg_catalog,pg_temp as $function$
declare history jsonb;revision bigint;item jsonb;
begin
 -- Reuse authentication and authorization, including the empty-history case.
 history:=api.get_session_corrections(p_session_id);
 select s.operational_revision into revision from ops.irrigation_sessions s
 where s.id=p_session_id;
 if revision=0 then
  return jsonb_build_object('contract','get_session_correction_status','version',1,
   'session_id',p_session_id,'operational_revision',0,
   'status','not_corrected','financial_status','not_applicable');
 end if;
 select value into item from jsonb_array_elements(history->'items')
 where (value->>'new_revision')::bigint=revision;
 if item is null then
  raise exception 'سجل تصحيح الجلسة غير مكتمل' using errcode='55000';
 end if;
 return jsonb_build_object('contract','get_session_correction_status','version',1,
  'session_id',p_session_id,'correction_id',item->'correction_id',
  'operational_revision',revision,'status',item->'financial_status',
  'financial_status',item->'financial_status',
  'financial_review_required',item->'financial_review_required',
  'financial_review_reason',item->'financial_review_reason');
end;$function$;

revoke all on function api.get_session_corrections(uuid),api.get_session_correction_status(uuid)
 from public,anon,authenticated,service_role;
grant execute on function api.get_session_corrections(uuid),api.get_session_correction_status(uuid)
 to authenticated,service_role;

commit;
