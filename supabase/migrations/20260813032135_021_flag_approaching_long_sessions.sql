-- تُعلِّم الجلسات المفتوحة التي اقتربت من عتبة "الجلسة الطويلة" (ضمن نافذة التنبيه الاستباقي)
-- ولم تتجاوزها بعد، لتنبيه المشغل قبل فوات الأوان بدل بعده فقط
create or replace function ops.flag_approaching_long_sessions()
returns setof uuid
language plpgsql
security definer
set search_path = ops, core, pg_temp
as $$
begin
    return query
    update ops.irrigation_sessions s
    set ending_alert_sent_at = now()
    from core.well_settings ws
    where ws.well_id = s.well_id
      and s.status = 'open'
      and s.ending_alert_sent_at is null
      and now() - s.started_at > ((ws.long_session_alert_minutes - ws.session_ending_alert_minutes) || ' minutes')::interval
      and now() - s.started_at <= (ws.long_session_alert_minutes || ' minutes')::interval
    returning s.id;
end;
$$;
