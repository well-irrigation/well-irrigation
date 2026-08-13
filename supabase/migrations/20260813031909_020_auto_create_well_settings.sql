-- تنشئ تلقائيا سطر اعدادات (بالقيم الافتراضية) فور انشاء اي بئر جديد
-- بحيث لا يمكن لبئر ان يوجد ابدا بلا اعدادات تنبيهات
create or replace function core.handle_new_well()
returns trigger
language plpgsql
security definer
set search_path = core, pg_temp
as $$
begin
    insert into core.well_settings (well_id) values (new.id);
    return new;
end;
$$;

create trigger on_well_created
    after insert on core.wells
    for each row
    execute function core.handle_new_well();
