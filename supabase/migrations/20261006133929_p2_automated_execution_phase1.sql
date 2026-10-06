-- P2 Automated Execution Proof — Phase 1 (LOCAL ONLY)
-- ق-135 / ق-136: فصل هوية التنفيذ التقنية عن فاعل الأعمال والمشغل.

begin;

-- هوية PostgreSQL تقنية، بلا LOGIN وبلا عضوية في أدوار التطبيق.
do $role$
begin
  if not exists (
    select 1 from pg_catalog.pg_roles
    where rolname = 'booking_automation_executor'
  ) then
    create role booking_automation_executor
      nologin noinherit nosuperuser nocreatedb nocreaterole noreplication;
  end if;
end;
$role$;

-- مالك الهجرات يستطيع محاكاة الهوية التقنية في الإثبات المحلي؛ لا تُمنح
-- العضوية لأي دور API أو مستخدم تطبيق.
grant booking_automation_executor to postgres;

alter table core.well_assignments
  add column authorization_revision bigint not null default 1;

comment on column core.well_assignments.authorization_revision is
  'P2: نسخة تفويض تصاعدية تتغير عند تغيير الشخص أو الدور أو الحالة؛ تمنع إعادة إحياء ON قديم بعد سحب التعيين أو استبداله.';

create function core.bump_well_assignment_authorization_revision()
returns trigger
language plpgsql
set search_path = pg_catalog, pg_temp
as $function$
begin
  if new.profile_id is distinct from old.profile_id
     or new.role is distinct from old.role
     or new.status is distinct from old.status then
    new.authorization_revision := old.authorization_revision + 1;
  else
    new.authorization_revision := old.authorization_revision;
  end if;
  return new;
end;
$function$;

create trigger well_assignments_authorization_revision
before update on core.well_assignments
for each row
execute function core.bump_well_assignment_authorization_revision();

alter table core.well_settings
  add column booking_auto_transition_operator_assignment_id uuid,
  add column booking_auto_transition_authorization_revision bigint;

comment on column core.well_settings.booking_auto_transition_operator_assignment_id is
  'P2: التعيين البشري الذي منح ON. بلا FK عمدًا كي يبقى الحذف قابلاً للرصد كتفويض مسحوب ويفشل التنفيذ مغلقًا.';

comment on column core.well_settings.booking_auto_transition_authorization_revision is
  'P2: نسخة تفويض التعيين عند منح ON؛ أي تغيير لاحق يتطلب إعادة تأكيد ON.';

create function core.bind_booking_automation_to_human_operator()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_assignment core.well_assignments%rowtype;
begin
  if new.booking_auto_transition_enabled then
    if v_actor is null then
      raise exception 'automation_binding_requires_human_actor'
        using errcode = '28000';
    end if;

    select wa.* into v_assignment
    from core.well_assignments wa
    where wa.well_id = new.well_id
      and wa.profile_id = v_actor
      and wa.role = 'operator'
      and wa.status = 'active'
    for share;

    if not found then
      raise exception 'automation_binding_requires_active_operator'
        using errcode = '42501';
    end if;

    new.booking_auto_transition_operator_assignment_id := v_assignment.id;
    new.booking_auto_transition_authorization_revision :=
      v_assignment.authorization_revision;
  else
    new.booking_auto_transition_operator_assignment_id := null;
    new.booking_auto_transition_authorization_revision := null;
  end if;
  return new;
end;
$function$;

create trigger well_settings_bind_booking_automation_operator
before insert or update of booking_auto_transition_enabled,
  booking_auto_transition_revision
on core.well_settings
for each row
execute function core.bind_booking_automation_to_human_operator();

-- الصف الوحيد هو المفتاح الذري داخل قاعدة الأعمال. افتراضه OFF مقصود.
create table ops.booking_automation_control (
  control_key text primary key check (control_key = 'global'),
  execution_enabled boolean not null default false,
  policy_version bigint not null default 1 check (policy_version > 0),
  updated_at timestamptz not null default clock_timestamp()
);

insert into ops.booking_automation_control (
  control_key, execution_enabled, policy_version
) values ('global', false, 1);

alter table ops.booking_automation_control enable row level security;
revoke all on ops.booking_automation_control
  from public, anon, authenticated, service_role,
       booking_automation_executor;

-- سياق قصير العمر مربوط بالمعاملة والاتصال. لا يحمل سرًا ولا يقبل Actor.
create table ops.booking_automation_execution_contexts (
  context_id uuid primary key default gen_random_uuid(),
  transaction_id bigint not null,
  backend_pid integer not null,
  tenant_id uuid not null,
  well_id uuid not null,
  chain_id uuid not null,
  current_session_id uuid not null,
  next_booking_id uuid not null,
  decision_revision bigint not null,
  automation_revision bigint not null,
  policy_version bigint not null,
  operator_profile_id uuid not null,
  operator_assignment_id uuid not null,
  authorization_revision bigint not null,
  intent_fingerprint jsonb not null,
  command_replayed boolean not null default false,
  created_at timestamptz not null default clock_timestamp()
);

alter table ops.booking_automation_execution_contexts enable row level security;
revoke all on ops.booking_automation_execution_contexts
  from public, anon, authenticated, service_role,
       booking_automation_executor;

create function ops.current_booking_automation_context()
returns ops.booking_automation_execution_contexts
language plpgsql
stable
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_context ops.booking_automation_execution_contexts%rowtype;
  v_context_id uuid;
begin
  begin
    v_context_id := nullif(
      current_setting('well_irrigation.booking_automation_context', true), ''
    )::uuid;
  exception when invalid_text_representation then
    return null;
  end;

  if v_context_id is null then
    return null;
  end if;

  select c.* into v_context
  from ops.booking_automation_execution_contexts c
  where c.context_id = v_context_id
    and c.transaction_id = txid_current()
    and c.backend_pid = pg_backend_pid();

  if not found then
    return null;
  end if;
  return v_context;
end;
$function$;

create function ops.current_execution_operator()
returns uuid
language plpgsql
stable
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_context ops.booking_automation_execution_contexts%rowtype;
begin
  if v_actor is not null then
    return v_actor;
  end if;
  v_context := ops.current_booking_automation_context();
  return v_context.operator_profile_id;
end;
$function$;

create function ops.execution_is_booking_automation()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, pg_temp
as $function$
  select auth.uid() is null
     and (ops.current_booking_automation_context()).context_id is not null;
$function$;

revoke all on function ops.current_booking_automation_context()
  from public, anon, authenticated, service_role,
       booking_automation_executor;
revoke all on function ops.current_execution_operator()
  from public, anon, authenticated, service_role,
       booking_automation_executor;
revoke all on function ops.execution_is_booking_automation()
  from public, anon, authenticated, service_role,
       booking_automation_executor;

-- التفويض الكنوني يبقى قائمًا على مشغل بشري، لكن مصدره قد يكون سياق P2
-- الداخلي الموثوق بدل auth.uid(). لا يسمح NULL ولا يمنح صلاحية جديدة.
create or replace function iam.has_well_permission(
  p_well_id uuid,
  p_permission_code text
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, pg_temp
as $function$
  select exists (
    select 1
    from core.well_assignments wa
    join iam.well_assignment_role_map arm
      on arm.assignment_role = wa.role
    join iam.role_permissions rp
      on rp.role_id = arm.role_id
    join iam.permissions perm
      on perm.id = rp.permission_id
    where wa.well_id = p_well_id
      and wa.profile_id = ops.current_execution_operator()
      and wa.status = 'active'
      and perm.code = p_permission_code
  );
$function$;

revoke all on function iam.has_well_permission(uuid, text)
  from public, anon, authenticated, service_role,
       booking_automation_executor;
grant execute on function iam.has_well_permission(uuid, text)
  to authenticated;

-- أقل refactor: استبدال مصدر actor فقط في الدوال الحالية، مع فشل الهجرة
-- إذا تغير نص أي دالة مختومة بدل تطبيق تعديل جزئي صامت.
do $refactor$
declare
  v_oid regprocedure;
  v_definition text;
  v_changed text;
begin
  foreach v_oid in array array[
    'ops.complete_irrigation_session(uuid,timestamptz,bigint,text,uuid)'::regprocedure,
    'ops.start_irrigation_session(uuid,uuid,uuid,uuid,uuid,text,timestamptz,uuid,text[])'::regprocedure,
    'ops.start_booking_session_core(uuid,uuid,timestamptz,text[],boolean)'::regprocedure,
    'ops.execute_booking_transition(uuid,bigint,uuid)'::regprocedure
  ] loop
    select pg_get_functiondef(v_oid) into v_definition;
    v_changed := replace(
      v_definition,
      'v_actor uuid := auth.uid();',
      'v_actor uuid := ops.current_execution_operator();'
    );
    v_changed := replace(
      v_changed,
      'v_actor := auth.uid()',
      'v_actor := ops.current_execution_operator()'
    );
    if v_changed = v_definition then
      raise exception 'P2 refactor anchor missing in %', v_oid;
    end if;
    execute v_changed;
  end loop;
end;
$refactor$;

-- لا يُنسب سجل الإكمال القديم إلى مستخدم نفّذ الفعل آليًا. يبقى المشغل
-- الحقيقي مثبتًا في سجل محاولة P2 وفي الجلسة الجديدة.
do $audit_refactor$
declare
  v_oid regprocedure :=
    'ops.complete_irrigation_session(uuid,timestamptz,bigint,text,uuid)'::regprocedure;
  v_definition text;
  v_changed text;
begin
  select pg_get_functiondef(v_oid) into v_definition;
  v_changed := replace(
    v_definition,
    'v_tenant_id, v_well_id, v_actor, ''session_completed'',',
    'v_tenant_id, v_well_id, case when ops.execution_is_booking_automation() then null else v_actor end, ''session_completed'','
  );
  if v_changed = v_definition then
    raise exception 'P2 audit refactor anchor missing in %', v_oid;
  end if;
  execute v_changed;
end;
$audit_refactor$;

-- بصمة مستقلة عن command_id، وتفردها يمنع معرفين لأثر الأعمال نفسه.
alter table sync.processed_commands
  add column intent_fingerprint jsonb;

create unique index processed_commands_automation_intent_unique
  on sync.processed_commands (tenant_id, command_type, intent_fingerprint)
  where intent_fingerprint is not null;

create or replace function sync.begin_command(
  p_tenant_id uuid,
  p_command_id uuid,
  p_command_type text,
  p_payload jsonb default null,
  p_entity_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_existing sync.processed_commands%rowtype;
  v_context ops.booking_automation_execution_contexts%rowtype;
  v_fingerprint jsonb;
begin
  v_context := ops.current_booking_automation_context();
  if v_context.context_id is not null
     and p_command_type = 'execute_booking_transition'
     and p_tenant_id = v_context.tenant_id
     and p_entity_id = v_context.well_id then
    v_fingerprint := v_context.intent_fingerprint;
  end if;

  insert into sync.processed_commands (
    tenant_id, command_id, command_type, entity_id, status,
    request_payload, intent_fingerprint
  ) values (
    p_tenant_id, p_command_id, p_command_type, p_entity_id, 'processing',
    p_payload, v_fingerprint
  )
  on conflict do nothing
  returning * into v_existing;

  if found then
    return jsonb_build_object('duplicate', false);
  end if;

  select pc.* into v_existing
  from sync.processed_commands pc
  where pc.tenant_id = p_tenant_id
    and pc.command_id = p_command_id;

  if not found and v_fingerprint is not null then
    select pc.* into v_existing
    from sync.processed_commands pc
    where pc.tenant_id = p_tenant_id
      and pc.command_type = p_command_type
      and pc.intent_fingerprint = v_fingerprint;

    if found and v_existing.status = 'accepted' then
      insert into sync.processed_commands (
        tenant_id, command_id, command_type, entity_id, status,
        request_payload, response_payload, processed_at,
        intent_fingerprint
      ) values (
        p_tenant_id, p_command_id, p_command_type, p_entity_id,
        v_existing.status, p_payload, v_existing.response_payload,
        clock_timestamp(), null
      )
      on conflict (tenant_id, command_id) do nothing;

      select pc.* into v_existing
      from sync.processed_commands pc
      where pc.tenant_id = p_tenant_id
        and pc.command_id = p_command_id;
    end if;
  end if;

  if not found then
    raise exception 'تعذر مصالحة الأمر المتزامن'
      using errcode = '40001';
  end if;

  if v_context.context_id is not null then
    update ops.booking_automation_execution_contexts
    set command_replayed = true
    where context_id = v_context.context_id;
  end if;

  return jsonb_build_object(
    'duplicate', true,
    'status', v_existing.status,
    'response', v_existing.response_payload,
    'canonical_command_id', v_existing.command_id
  );
end;
$function$;

revoke all on function sync.begin_command(uuid, uuid, text, jsonb, uuid)
  from public, anon, authenticated, service_role,
       booking_automation_executor;

-- تدقيق المحاولة مستقل عن audit_logs البشرية، وإضافي فقط.
create table audit.booking_automation_attempts (
  id uuid primary key default gen_random_uuid(),
  actor_kind text not null check (actor_kind = 'system'),
  actor_ref text not null check (actor_ref = 'booking_automation_system'),
  executor_id text not null,
  credential_ref text not null,
  authorization_source text,
  tenant_id uuid,
  well_id uuid,
  chain_id uuid,
  operator_profile_id uuid,
  operator_assignment_id uuid,
  current_session_id uuid,
  next_booking_id uuid,
  command_id uuid not null,
  attempt_id uuid not null unique,
  runtime_run_id uuid not null,
  decision_revision bigint,
  automation_revision bigint,
  authorization_revision bigint,
  policy_version bigint,
  observed_at timestamptz not null,
  attempted_at timestamptz not null,
  decided_at timestamptz not null,
  result text not null check (result in ('accepted', 'replayed', 'rejected')),
  failure_reason text,
  business_receipt jsonb,
  check ((result = 'rejected') = (failure_reason is not null))
);

create index booking_automation_attempts_command_idx
  on audit.booking_automation_attempts (command_id, attempted_at desc);
create index booking_automation_attempts_well_idx
  on audit.booking_automation_attempts (well_id, attempted_at desc);

alter table audit.booking_automation_attempts enable row level security;
revoke all on audit.booking_automation_attempts
  from public, anon, authenticated, service_role,
       booking_automation_executor;

create trigger booking_automation_attempts_append_only
before update or delete on audit.booking_automation_attempts
for each row execute function audit.prevent_audit_modification();

-- كل حكم هنا يقع تحت قفل ويبقى حتى نهاية معاملة P1-B نفسها.
create function ops.authorize_booking_transition_automation(
  p_well_id uuid,
  p_chain_id uuid,
  p_current_session_id uuid,
  p_next_booking_id uuid,
  p_decision_revision bigint,
  p_automation_revision bigint,
  p_policy_version bigint
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_control ops.booking_automation_control%rowtype;
  v_well core.wells%rowtype;
  v_settings core.well_settings%rowtype;
  v_operator_count integer;
  v_operator core.well_assignments%rowtype;
  v_bound core.well_assignments%rowtype;
  v_session record;
  v_chain ops.booking_transition_chains%rowtype;
  v_next record;
  v_open_count integer;
begin
  select ctl.* into v_control
  from ops.booking_automation_control ctl
  where ctl.control_key = 'global'
  for share;
  if not found or not v_control.execution_enabled then
    raise exception 'global_automation_disabled' using errcode = '22023';
  end if;
  if p_policy_version is distinct from v_control.policy_version then
    raise exception 'stale_policy_version' using errcode = '40001';
  end if;

  select w.* into v_well
  from core.wells w
  where w.id = p_well_id
  for update;
  if not found or v_well.status <> 'active' then
    raise exception 'well_unavailable' using errcode = '22023';
  end if;

  select ws.* into v_settings
  from core.well_settings ws
  where ws.well_id = p_well_id
  for update;
  if not found then
    raise exception 'booking_auto_transition_disabled' using errcode = '22023';
  end if;

  -- قفل جميع تعيينات البئر بعد قفل البئر يمنع إدخال تعيين جديد عبر FK
  -- حتى نهاية المعاملة، كما يمنع تغيير حالة تعيين مقفول.
  perform 1
  from core.well_assignments wa
  where wa.well_id = p_well_id
  order by wa.id
  for share;

  if not exists (
    select 1 from core.well_assignments wa
    where wa.well_id = p_well_id
      and wa.role = 'owner'
      and wa.status = 'active'
  ) then
    raise exception 'well_owner_missing' using errcode = '42501';
  end if;

  if not v_settings.booking_auto_transition_enabled then
    raise exception 'booking_auto_transition_disabled'
      using errcode = '22023';
  end if;

  select count(*) into v_operator_count
  from core.well_assignments wa
  where wa.well_id = p_well_id
    and wa.role = 'operator'
    and wa.status = 'active';

  select wa.* into v_bound
  from core.well_assignments wa
  where wa.id = v_settings.booking_auto_transition_operator_assignment_id;

  if v_operator_count = 0 then
    if v_bound.id is not null then
      raise exception 'revoked_delegation' using errcode = '42501';
    end if;
    raise exception 'operator_unassigned' using errcode = '42501';
  end if;
  if v_operator_count > 1 then
    raise exception 'ambiguous_responsible_operator' using errcode = '42501';
  end if;

  select wa.* into v_operator
  from core.well_assignments wa
  where wa.well_id = p_well_id
    and wa.role = 'operator'
    and wa.status = 'active';

  if v_bound.id is null or v_bound.id is distinct from v_operator.id then
    raise exception 'operator_changed_pending_confirmation'
      using errcode = '42501';
  end if;
  if v_settings.booking_auto_transition_authorization_revision
       is distinct from v_operator.authorization_revision then
    raise exception 'authorization_revision_stale' using errcode = '40001';
  end if;
  if p_automation_revision
       is distinct from v_settings.booking_auto_transition_revision then
    raise exception 'stale_automation_revision' using errcode = '40001';
  end if;

  select s.id, s.booking_id, s.started_at,
         b.expected_duration_minutes
    into v_session
  from ops.irrigation_sessions s
  left join ops.irrigation_bookings b on b.id = s.booking_id
  where s.well_id = p_well_id
    and s.status = 'open'
  order by s.started_at desc
  for update of s;

  select count(*) into v_open_count
  from ops.irrigation_sessions s
  where s.well_id = p_well_id and s.status = 'open';
  if v_open_count = 0 then
    raise exception 'no_open_session_to_close' using errcode = '22023';
  end if;
  if v_open_count > 1 then
    raise exception 'ambiguous_open_sessions' using errcode = '22023';
  end if;
  if v_session.id is distinct from p_current_session_id then
    raise exception 'current_session_changed' using errcode = '40001';
  end if;
  if v_session.booking_id is null
     or v_session.expected_duration_minutes is null then
    raise exception 'transient_or_free_session_blocked'
      using errcode = '22023';
  end if;
  if clock_timestamp() < v_session.started_at
       + make_interval(mins => v_session.expected_duration_minutes) then
    raise exception 'current_not_reached_operational_end'
      using errcode = '22023';
  end if;

  select c.* into v_chain
  from ops.booking_transition_chains c
  where c.well_id = p_well_id and c.status <> 'ended'
  for update;
  if not found or v_chain.id is distinct from p_chain_id then
    raise exception 'chain_changed' using errcode = '40001';
  end if;
  if v_chain.status <> 'active' then
    raise exception 'chain_state_blocked' using errcode = '22023';
  end if;
  if v_chain.current_session_id is distinct from v_session.id then
    raise exception 'chain_session_mismatch' using errcode = '40001';
  end if;
  if p_decision_revision is distinct from v_chain.decision_revision then
    raise exception 'stale_decision_revision' using errcode = '40001';
  end if;

  select b.id, b.scheduled_start
    into v_next
  from ops.irrigation_bookings b
  where b.well_id = p_well_id
    and b.status = 'confirmed'
    and not exists (
      select 1 from ops.irrigation_sessions s where s.booking_id = b.id
    )
  order by b.scheduled_start asc, b.priority desc, b.public_code asc
  limit 1
  for update;
  if not found then
    raise exception 'no_confirmed_next_booking' using errcode = '22023';
  end if;
  if v_next.id is distinct from p_next_booking_id then
    raise exception 'next_booking_changed' using errcode = '40001';
  end if;
  if v_next.scheduled_start > clock_timestamp() then
    raise exception 'next_booking_not_due' using errcode = '22023';
  end if;

  return jsonb_build_object(
    'tenant_id', v_well.tenant_id,
    'operator_profile_id', v_operator.profile_id,
    'operator_assignment_id', v_operator.id,
    'authorization_revision', v_operator.authorization_revision,
    'authorization_source', 'core.well_assignments',
    'policy_version', v_control.policy_version
  );
end;
$function$;

revoke all on function ops.authorize_booking_transition_automation(
  uuid, uuid, uuid, uuid, bigint, bigint, bigint
) from public, anon, authenticated, service_role,
       booking_automation_executor;

-- المدخل الوحيد الممنوح للمنفذ التقني. actor/executor/credential ثوابت
-- خادمية ولا توجد في التوقيع، والمشغل مشتق من التفويض المقفول.
create function ops.execute_booking_transition_automation(
  p_well_id uuid,
  p_chain_id uuid,
  p_current_session_id uuid,
  p_next_booking_id uuid,
  p_decision_revision bigint,
  p_automation_revision bigint,
  p_policy_version bigint,
  p_command_id uuid,
  p_attempt_id uuid,
  p_runtime_run_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_observed_at timestamptz := clock_timestamp();
  v_attempted_at timestamptz := clock_timestamp();
  v_tenant_id uuid;
  v_authorization jsonb;
  v_operator_profile_id uuid;
  v_operator_assignment_id uuid;
  v_authorization_revision bigint;
  v_context_id uuid;
  v_intent jsonb;
  v_business_receipt jsonb;
  v_result text;
  v_failure_reason text;
  v_replayed boolean := false;
  v_existing sync.processed_commands%rowtype;
  v_stored_intent jsonb;
begin
  if p_command_id is null or p_attempt_id is null
     or p_runtime_run_id is null then
    raise exception 'command_attempt_and_runtime_ids_required'
      using errcode = '22023';
  end if;

  select w.tenant_id into v_tenant_id
  from core.wells w where w.id = p_well_id;

  -- تسلسل كل المحاولات للنية المرشحة نفسها قبل قراءة دفتر الأوامر.
  -- القفل لا يمنح تفويضًا؛ يمنع فقط أن يقرأ retry متزامن الدفتر قبل
  -- إيداع المنفذ الأول ثم يصل إلى حالة أعمال تغيرت بالفعل.
  perform pg_advisory_xact_lock(hashtextextended(concat_ws(
    '|',
    v_tenant_id::text,
    p_well_id::text,
    p_chain_id::text,
    p_current_session_id::text,
    p_next_booking_id::text,
    p_decision_revision::text,
    p_automation_revision::text,
    p_policy_version::text,
    'system',
    'booking_automation_system'
  ), 0));

  -- Replay مقبول سابقًا: مقارنة المرشحات بالبصمة المخزنة ثم إعادة الإقرار
  -- بلا إعادة تفويض حالي وبلا تنفيذ أعمال جديد.
  select pc.* into v_existing
  from sync.processed_commands pc
  where pc.tenant_id = v_tenant_id
    and pc.command_id = p_command_id;

  if found then
    v_stored_intent := coalesce(
      v_existing.intent_fingerprint,
      v_existing.request_payload -> 'automation_intent'
    );
  else
    -- معرف جديد للنية نفسها لا يعيد قرار الأعمال بعد تغير الحالة؛ يجد
    -- الإقرار الكنوني بالبصمة المنطقية الكاملة المخزنة.
    select pc.* into v_existing
    from sync.processed_commands pc
    where pc.tenant_id = v_tenant_id
      and pc.command_type = 'execute_booking_transition'
      and pc.status = 'accepted'
      and pc.intent_fingerprint @> jsonb_build_object(
        'tenant_id', v_tenant_id,
        'well_id', p_well_id,
        'chain_id', p_chain_id,
        'current_session_id', p_current_session_id,
        'next_booking_id', p_next_booking_id,
        'decision_revision', p_decision_revision,
        'automation_revision', p_automation_revision,
        'policy_version', p_policy_version,
        'actor_kind', 'system',
        'actor_ref', 'booking_automation_system'
      )
    limit 1;

    if found then
      v_stored_intent := v_existing.intent_fingerprint;
      insert into sync.processed_commands (
        tenant_id, command_id, command_type, entity_id, status,
        request_payload, response_payload, processed_at
      ) values (
        v_tenant_id, p_command_id, 'execute_booking_transition',
        p_well_id, 'accepted',
        jsonb_build_object(
          'automation_intent', v_stored_intent,
          'canonical_command_id', v_existing.command_id
        ),
        v_existing.response_payload, clock_timestamp()
      )
      on conflict (tenant_id, command_id) do nothing;
    end if;
  end if;

  if v_existing.id is not null and v_existing.status = 'accepted'
     and v_existing.command_type = 'execute_booking_transition'
     and v_stored_intent ->> 'actor_kind' = 'system'
     and v_stored_intent ->> 'actor_ref'
       = 'booking_automation_system' then
    if (v_stored_intent ->> 'well_id')::uuid
         is distinct from p_well_id
       or (v_stored_intent ->> 'chain_id')::uuid
         is distinct from p_chain_id
       or (v_stored_intent ->> 'current_session_id')::uuid
         is distinct from p_current_session_id
       or (v_stored_intent ->> 'next_booking_id')::uuid
         is distinct from p_next_booking_id
       or (v_stored_intent ->> 'decision_revision')::bigint
         is distinct from p_decision_revision
       or (v_stored_intent ->> 'automation_revision')::bigint
         is distinct from p_automation_revision
       or (v_stored_intent ->> 'policy_version')::bigint
         is distinct from p_policy_version then
      v_result := 'rejected';
      v_failure_reason := 'command_intent_mismatch';
    else
      v_result := 'replayed';
      v_business_receipt := v_existing.response_payload;
      v_operator_profile_id :=
        (v_stored_intent ->> 'operator_profile_id')::uuid;
      v_operator_assignment_id :=
        (v_stored_intent ->> 'operator_assignment_id')::uuid;
      v_authorization_revision :=
        (v_stored_intent ->> 'authorization_revision')::bigint;
    end if;
  else
    begin
      v_authorization := ops.authorize_booking_transition_automation(
        p_well_id, p_chain_id, p_current_session_id, p_next_booking_id,
        p_decision_revision, p_automation_revision, p_policy_version
      );
      v_tenant_id := (v_authorization ->> 'tenant_id')::uuid;
      v_operator_profile_id :=
        (v_authorization ->> 'operator_profile_id')::uuid;
      v_operator_assignment_id :=
        (v_authorization ->> 'operator_assignment_id')::uuid;
      v_authorization_revision :=
        (v_authorization ->> 'authorization_revision')::bigint;

      v_intent := jsonb_build_object(
        'contract_version', 1,
        'tenant_id', v_tenant_id,
        'well_id', p_well_id,
        'chain_id', p_chain_id,
        'current_session_id', p_current_session_id,
        'next_booking_id', p_next_booking_id,
        'decision_revision', p_decision_revision,
        'automation_revision', p_automation_revision,
        'policy_version', p_policy_version,
        'operator_profile_id', v_operator_profile_id,
        'operator_assignment_id', v_operator_assignment_id,
        'authorization_revision', v_authorization_revision,
        'actor_kind', 'system',
        'actor_ref', 'booking_automation_system'
      );

      insert into ops.booking_automation_execution_contexts (
        transaction_id, backend_pid, tenant_id, well_id, chain_id,
        current_session_id, next_booking_id, decision_revision,
        automation_revision, policy_version, operator_profile_id,
        operator_assignment_id, authorization_revision,
        intent_fingerprint
      ) values (
        txid_current(), pg_backend_pid(), v_tenant_id, p_well_id, p_chain_id,
        p_current_session_id, p_next_booking_id, p_decision_revision,
        p_automation_revision, p_policy_version, v_operator_profile_id,
        v_operator_assignment_id, v_authorization_revision, v_intent
      ) returning context_id into v_context_id;

      perform set_config(
        'well_irrigation.booking_automation_context',
        v_context_id::text,
        true
      );

      -- P1-B هو المنسق الوحيد؛ لا استدعاء مباشر للإكمال أو البدء هنا.
      v_business_receipt := ops.execute_booking_transition(
        p_well_id, p_decision_revision, p_command_id
      );

      select c.command_replayed into v_replayed
      from ops.booking_automation_execution_contexts c
      where c.context_id = v_context_id;

      v_result := case when v_replayed then 'replayed' else 'accepted' end;
      delete from ops.booking_automation_execution_contexts
      where context_id = v_context_id;
      perform set_config('well_irrigation.booking_automation_context', '', true);
    exception when others then
      perform set_config('well_irrigation.booking_automation_context', '', true);
      v_result := 'rejected';
      v_failure_reason := sqlerrm;
      v_business_receipt := null;
    end;
  end if;

  insert into audit.booking_automation_attempts (
    actor_kind, actor_ref, executor_id, credential_ref,
    authorization_source, tenant_id, well_id, chain_id,
    operator_profile_id, operator_assignment_id, current_session_id,
    next_booking_id, command_id, attempt_id, runtime_run_id,
    decision_revision, automation_revision, authorization_revision,
    policy_version, observed_at, attempted_at, decided_at,
    result, failure_reason, business_receipt
  ) values (
    'system', 'booking_automation_system',
    'booking_automation_executor', 'vault:p2-booking-automation:v1',
    case when v_operator_assignment_id is null then null
      else 'core.well_assignments' end,
    v_tenant_id, p_well_id, p_chain_id,
    v_operator_profile_id, v_operator_assignment_id,
    p_current_session_id, p_next_booking_id,
    p_command_id, p_attempt_id, p_runtime_run_id,
    p_decision_revision, p_automation_revision,
    v_authorization_revision, p_policy_version,
    v_observed_at, v_attempted_at, clock_timestamp(),
    v_result, v_failure_reason, v_business_receipt
  );

  return jsonb_build_object(
    'contract', 'execute_booking_transition_automation',
    'version', 1,
    'result', v_result,
    'failure_reason', v_failure_reason,
    'actor_kind', 'system',
    'actor_ref', 'booking_automation_system',
    'executor_id', 'booking_automation_executor',
    'operator_profile_id', v_operator_profile_id,
    'command_id', p_command_id,
    'attempt_id', p_attempt_id,
    'runtime_run_id', p_runtime_run_id,
    'business_receipt', v_business_receipt
  );
end;
$function$;

comment on function ops.execute_booking_transition_automation(
  uuid, uuid, uuid, uuid, bigint, bigint, bigint, uuid, uuid, uuid
) is
  'P2 Phase 1: مدخل داخلي تقني ثابت الهوية، يعيد التحقق ذريًا، ويستدعي P1-B وحده. لا يقبل actor أو operator، وإعادة command مقبول تعيد الإقرار التاريخي.';

revoke all on function ops.execute_booking_transition_automation(
  uuid, uuid, uuid, uuid, bigint, bigint, bigint, uuid, uuid, uuid
) from public, anon, authenticated, service_role;
grant execute on function ops.execute_booking_transition_automation(
  uuid, uuid, uuid, uuid, bigint, bigint, bigint, uuid, uuid, uuid
) to booking_automation_executor;
grant usage on schema ops to booking_automation_executor;

-- بعد الاستبدال أعلاه تبقى نواة P1-B غير ممنوحة لأي دور تطبيقي.
revoke all on function ops.execute_booking_transition(uuid, bigint, uuid)
  from public, anon, authenticated, service_role,
       booking_automation_executor;

commit;
