alter table ops.notifications drop constraint notifications_type_check;
alter table ops.notifications add constraint notifications_type_check
    check (type in ('long_session', 'approaching_long_session', 'distribution_finalized'));

-- عند تحويل دفعة توزيع الى finalized، يصل لكل شريك اشعار بمبلغه بالضبط تلقائيا
create or replace function finance.notify_distribution_finalized()
returns trigger
language plpgsql
security definer
set search_path = finance, ops, pg_temp
as $$
declare
    v_line record;
begin
    if new.status = 'finalized' and old.status <> 'finalized' then
        for v_line in
            select profile_id, amount_milli from finance.distribution_lines where batch_id = new.id
        loop
            insert into ops.notifications (recipient_profile_id, well_id, type, message)
            values (v_line.profile_id, new.well_id, 'distribution_finalized',
                    format('اكتملت دفعة توزيع للفترة من %s الى %s بمبلغ %s مللي لك', new.period_start, new.period_end, v_line.amount_milli));
        end loop;
    end if;
    return new;
end;
$$;

create trigger distribution_batches_notify_finalized
    after update on finance.distribution_batches
    for each row
    execute function finance.notify_distribution_finalized();
