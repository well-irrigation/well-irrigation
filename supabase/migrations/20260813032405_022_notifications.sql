-- سجل الاشعارات الموجهة لشخص معين
create table ops.notifications (
    id uuid primary key default gen_random_uuid(),
    recipient_profile_id uuid not null references iam.profiles(id) on delete cascade,
    well_id uuid not null references core.wells(id) on delete cascade,
    session_id uuid references ops.irrigation_sessions(id) on delete cascade,
    type text not null check (type in ('long_session', 'approaching_long_session')),
    message text not null,
    read_at timestamptz,
    created_at timestamptz not null default now()
);

alter table ops.notifications enable row level security;

-- كل شخص يرى اشعاراته الخاصة فقط، ويستطيع تعليمها كمقروءة
create policy notifications_select_self on ops.notifications for select using (recipient_profile_id = auth.uid());
create policy notifications_update_self on ops.notifications for update using (recipient_profile_id = auth.uid());
grant select, update on ops.notifications to authenticated;
-- عمدا: لا قاعدة INSERT لأي مستخدم عادي - الاشعارات تُنشأ فقط تلقائيا من الدالتين ادناه

-- تحديث الدالة: تُعلِّم الجلسة، وترسل اشعارا فعليا لكل من له دور مالك او مشغل على ذلك البئر
create or replace function ops.flag_long_running_sessions()
returns setof uuid
language plpgsql
security definer
set search_path = ops, core, iam, pg_temp
as $$
declare
    v_session record;
begin
    for v_session in
        update ops.irrigation_sessions s
        set long_alert_sent_at = now()
        from core.well_settings ws
        where ws.well_id = s.well_id
          and s.status = 'open'
          and s.long_alert_sent_at is null
          and now() - s.started_at > (ws.long_session_alert_minutes || ' minutes')::interval
        returning s.id, s.well_id
    loop
        insert into ops.notifications (recipient_profile_id, well_id, session_id, type, message)
        select wa.profile_id, v_session.well_id, v_session.id, 'long_session',
               'جلسة سقي مفتوحة منذ فترة طويلة تجاوزت الحد المسموح'
        from core.well_assignments wa
        where wa.well_id = v_session.well_id and wa.status = 'active' and wa.role in ('owner', 'operator');

        return next v_session.id;
    end loop;
end;
$$;

-- تحديث الدالة: نفس المنطق للتنبيه الاستباقي
create or replace function ops.flag_approaching_long_sessions()
returns setof uuid
language plpgsql
security definer
set search_path = ops, core, iam, pg_temp
as $$
declare
    v_session record;
begin
    for v_session in
        update ops.irrigation_sessions s
        set ending_alert_sent_at = now()
        from core.well_settings ws
        where ws.well_id = s.well_id
          and s.status = 'open'
          and s.ending_alert_sent_at is null
          and now() - s.started_at > ((ws.long_session_alert_minutes - ws.session_ending_alert_minutes) || ' minutes')::interval
          and now() - s.started_at <= (ws.long_session_alert_minutes || ' minutes')::interval
        returning s.id, s.well_id
    loop
        insert into ops.notifications (recipient_profile_id, well_id, session_id, type, message)
        select wa.profile_id, v_session.well_id, v_session.id, 'approaching_long_session',
               'جلسة سقي تقترب من أن تصبح جلسة طويلة، يُرجى المتابعة'
        from core.well_assignments wa
        where wa.well_id = v_session.well_id and wa.status = 'active' and wa.role in ('owner', 'operator');

        return next v_session.id;
    end loop;
end;
$$;
