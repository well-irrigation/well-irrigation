-- 087 — إصلاح صلاحية غلاف إنشاء البئر دون كشف مخطط core
-- api.* تبقى SECURITY INVOKER؛ الدالة الداخلية SECURITY DEFINER وتتحقق من auth.uid().

grant usage on schema core to authenticated;
grant execute on function core.setup_well_full(jsonb) to authenticated;

revoke execute on function core.setup_well_full(jsonb) from anon, public;
revoke all on function api.setup_well_full(jsonb) from public, anon;
grant execute on function api.setup_well_full(jsonb) to authenticated, service_role;
