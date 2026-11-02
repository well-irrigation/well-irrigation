begin;
-- R6-B: استعادة النتيجة الأصلية قراءة فقط؛ لا تفويض إعادة إرسال.
-- لا تغيير لكاتب R6-A أو هويته أو ربطه أو التواقيع القديمة.
create function sync.get_operational_start_receipt_read(
 p_well_id uuid,p_command_id uuid,p_expected_command_type text default 'start_operational_session')
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,pg_temp as $function$
declare
 actor uuid:=auth.uid(); tenant uuid; c sync.processed_commands%rowtype;
 o ops.operational_occurrences%rowtype; has_occurrence boolean;
 r jsonb; absence jsonb; scope_proven boolean:=false; req jsonb; receipt jsonb; sid uuid; session_well uuid;
 original_start timestamptz; original_actor uuid; source_booking uuid; parsed_uuid uuid; key text;
begin
 if actor is null then
  raise exception 'operational_start_receipt_requires_authentication' using errcode='28000';
 end if;
 if p_well_id is null or p_command_id is null or p_expected_command_type is null
  or p_expected_command_type not in ('start_operational_session','start_irrigation_session','start_adhoc_session') then
  raise exception 'operational_start_receipt_invalid_inputs' using errcode='22023';
 end if;
 select w.tenant_id into tenant from core.wells w where w.id=p_well_id
  and exists(select 1 from core.well_assignments wa where wa.well_id=w.id
    and wa.profile_id=actor and wa.status='active');
 if tenant is null or not coalesce(iam.has_well_permission(p_well_id,'session.start'),false) then
  raise exception 'operational_start_receipt_forbidden' using errcode='42501';
 end if;
 r:=jsonb_build_object('contract','get_operational_start_receipt','version',1,
   'well_id',p_well_id,'command_id',p_command_id,'command_type',p_expected_command_type,'status','unresolved',
   'receipt',null,'retry_authorized',false);
 -- لا يكشف النوع القديم وجود صف غير مسند: الغياب والدليل الناقص لهما الحالة نفسها.
 absence:=case when p_expected_command_type='start_operational_session'
  then r||jsonb_build_object('status','not_found') else r end;
 select pc.* into c from sync.processed_commands pc
  where pc.tenant_id=tenant and pc.command_id=p_command_id;
 if not found then return absence;end if;
 select x.* into o from ops.operational_occurrences x
  where x.tenant_id=tenant and x.occurrence_command_id=p_command_id;
 has_occurrence:=found;
 req:=c.request_payload;receipt:=c.response_payload;
 -- احجب الأمر المعروف أنه لبئر آخر بالنتيجة نفسها التي تعني غيابه في النطاق.
 -- الصف القديم غير القابل للإسناد يبقى unresolved بلا نتيجة أو حقائق مخترعة.
 if has_occurrence then
  if o.well_id<>p_well_id then return absence;end if;
  scope_proven:=true;
 elsif c.command_type in ('start_operational_session','start_adhoc_session') and c.entity_id is not null then
  if c.entity_id<>p_well_id then return absence;end if;
  scope_proven:=true;
 elsif jsonb_typeof(req->'well_id')='string' then
  if req->>'well_id'<>p_well_id::text then return absence;end if;
  scope_proven:=true;
 elsif jsonb_typeof(receipt->'id')='string' then
  begin
   sid:=(receipt->>'id')::uuid;
  exception when invalid_text_representation then return absence;
  end;
  select s.well_id into session_well from ops.irrigation_sessions s where s.id=sid;
  if found then
   if session_well<>p_well_id then return absence;end if;
   scope_proven:=true;
  end if;
 elsif jsonb_typeof(receipt->'well_id')='string' then
  if receipt->>'well_id'<>p_well_id::text then return absence;end if;
  scope_proven:=true;
 end if;
 if not scope_proven then return absence;end if;
 if c.command_type is distinct from p_expected_command_type then return r;end if;
 -- أغلفة الخطأ التالية تخص فساد بيانات الأصل فقط، لا تخفي رفض الصلاحيات.
 begin
  if c.command_type='start_irrigation_session' then
   -- هذا التوقيع المختوم يحفظ SQL NULL بالفعل؛ لا نخترع طلبًا أو وقتًا له.
   if c.entity_id is not null or req is not null then return r;end if;
  else
   if c.entity_id is distinct from p_well_id or jsonb_typeof(req) is distinct from 'object'
    or req->>'well_id' is distinct from p_well_id::text
    or not (req ?& array['well_id','pump_id','farm_id','farmer_well_account_id','energy_source',
      'started_at','crops','fuel_owner_person_id']) then return r;end if;
   foreach key in array array['well_id','pump_id','farm_id','farmer_well_account_id'] loop
    if jsonb_typeof(req->key) is distinct from 'string' then return r;end if;
    parsed_uuid:=(req->>key)::uuid;
   end loop;
   if not coalesce(req->>'energy_source' in ('solar','well_diesel','farmer_diesel'),false)
    or not coalesce(jsonb_typeof(req->'crops') in ('array','null'),false)
    or not coalesce(jsonb_typeof(req->'fuel_owner_person_id') in ('string','null'),false)
    or jsonb_typeof(req->'started_at') is distinct from 'string'
    or (req->>'started_at') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$' then return r;end if;
   parsed_uuid:=(req->>'fuel_owner_person_id')::uuid;
   original_start:=(req->>'started_at')::timestamptz;
   if not isfinite(original_start) then return r;end if;
   if c.command_type='start_operational_session' then
    if not (req ?& array['actor_id','source_booking_id'])
     or jsonb_typeof(req->'actor_id') is distinct from 'string'
     or not coalesce(jsonb_typeof(req->'source_booking_id') in ('string','null'),false) then return r;end if;
    original_actor:=(req->>'actor_id')::uuid;
    source_booking:=(req->>'source_booking_id')::uuid;
   elsif req->'booking_execution_contract_version' is distinct from '113'::jsonb
     or not (req ? 'planned_duration_minutes') then return r;
   end if;
  end if;
  if c.status='processing' then
   if receipt is null and not has_occurrence and c.command_type<>'start_irrigation_session' then
    return r||jsonb_build_object('status','processing');
   end if;
   return r;
  end if;
  -- الكتّاب الحاليون يتراجعون عند الخطأ؛ لا يثبت غياب صفٍ رفضًا محفوظًا.
  -- لا نعيد rejected إلا إذا وُجدت نتيجة رفض صريحة محفوظة بنطاق طلب مثبت.
  if c.status='rejected' then
   if c.command_type='start_irrigation_session' or has_occurrence
    or jsonb_typeof(receipt) is distinct from 'object'
    or receipt->>'status' is distinct from 'rejected'
    or jsonb_typeof(receipt->'reason') is distinct from 'string'
    or nullif(btrim(receipt->>'reason'),'') is null
    or receipt ?| array['id','session_id']
    or (receipt ? 'tenant_id' and receipt->>'tenant_id' is distinct from tenant::text)
    or (receipt ? 'well_id' and receipt->>'well_id' is distinct from p_well_id::text)
    or (receipt ? 'command_id' and receipt->>'command_id' is distinct from p_command_id::text)
    or (receipt ? 'occurrence_command_id' and receipt->>'occurrence_command_id' is distinct from p_command_id::text)
    or (receipt ? 'command_type' and receipt->>'command_type' is distinct from c.command_type) then return r;end if;
   return r||jsonb_build_object('status','rejected','receipt',receipt);
  end if;
  if c.status<>'accepted' or jsonb_typeof(receipt) is distinct from 'object'
    or jsonb_typeof(receipt->'id') is distinct from 'string' then return r;end if;
  -- الاسم الكَنوني في الأوامر الحرة هو id، وليس session_id الخاص بالحجز.
  sid:=(receipt->>'id')::uuid;
  if c.command_type='start_operational_session' then
   if receipt is distinct from jsonb_build_object('id',sid,'occurrence_command_id',p_command_id)
     or not has_occurrence then return r;end if;
  elsif receipt is distinct from jsonb_build_object('id',sid) then return r;
  end if;
  -- حالة الجلسة وطابع بدايتها وحقولها القابلة للتصحيح ليست دليلًا بديلًا
  -- لما أعاده الأمر الأصلي. نتحقق من ربط الهوية ونطاق البئر فقط.
  if not exists(select 1 from ops.irrigation_sessions s join core.wells w on w.id=s.well_id
    where s.id=sid and s.well_id=p_well_id and w.tenant_id=tenant) then return r;end if;
  if has_occurrence then
   if o.status<>'accepted' or o.provenance<>'accepted_start'
    or o.original_request_id<>p_command_id or o.server_session_id is distinct from sid
    or o.original_facts is distinct from jsonb_build_object('request',req,'result',receipt) then return r;end if;
   if c.command_type='start_operational_session' and
     (o.started_at is distinct from original_start or o.original_operator_id is distinct from original_actor
      or o.source_booking_id is distinct from source_booking) then return r;end if;
   if c.command_type='start_adhoc_session' and o.started_at is distinct from original_start then return r;end if;
  elsif exists(select 1 from ops.operational_occurrences x where x.server_session_id=sid) then
   -- لا نتبنى أمرًا قديمًا تشير نتيجته إلى جلسة مثبتة لأمر آخر.
   return r;
  end if;
  return r||jsonb_build_object('status','accepted','receipt',receipt);
 exception when invalid_text_representation or invalid_datetime_format or datetime_field_overflow
   or numeric_value_out_of_range then return r;
 end;
end;
$function$;
revoke all on function sync.get_operational_start_receipt_read(uuid,uuid,text)
 from public,anon,authenticated,service_role;
grant execute on function sync.get_operational_start_receipt_read(uuid,uuid,text) to authenticated,service_role;

create function api.get_operational_start_receipt(
 p_well_id uuid,p_command_id uuid,p_expected_command_type text default 'start_operational_session')
returns jsonb language sql stable security invoker
set search_path=pg_catalog,pg_temp as $function$
 select sync.get_operational_start_receipt_read(p_well_id,p_command_id,p_expected_command_type);
$function$;
revoke all on function api.get_operational_start_receipt(uuid,uuid,text)
 from public,anon,authenticated,service_role;
grant execute on function api.get_operational_start_receipt(uuid,uuid,text) to authenticated,service_role;
comment on function api.get_operational_start_receipt(uuid,uuid,text) is
 'R6-B: قراءة النتيجة الأصلية المحفوظة لبدء حر محدد؛ ليست بيانات الجلسة المصححة. retry_authorized=false دائمًا؛ إقرار البدء من حجز عقد منفصل.';
commit;
