-- تُعلِّم اي جلسة مفتوحة تجاوزت عتبة الانذار الخاصة ببئرها، وتُعيد قائمة بمعرّفات الجلسات المُعلَّمة
-- (لاستخدامها لاحقا من نظام الاشعارات)، دون ان تغلق الجلسة نفسها ابدا
create or replace function ops.flag_long_running_sessions()
returns setof uuid
language plpgsql
security definer
set search_path = ops, core, pg_temp
as $$
begin
    return query
    update ops.irrigation_sessions s
    set long_alert_sent_at = now()
    from core.well_settings ws
    where ws.well_id = s.well_id
      and s.status = 'open'
      and s.long_alert_sent_at is null
      and now() - s.started_at > (ws.long_session_alert_minutes || ' minutes')::interval
    returning s.id;
end;
$$;
