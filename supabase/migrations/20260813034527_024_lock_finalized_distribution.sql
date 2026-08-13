-- بمجرد ان تصبح الدفعة finalized، يُمنع تعديل اي من حقولها نهائيا
create or replace function finance.prevent_finalized_batch_update()
returns trigger
language plpgsql
as $$
begin
    if old.status = 'finalized' then
        raise exception 'لا يمكن تعديل دفعة توزيع مكتملة (finalized): %', old.id;
    end if;
    return new;
end;
$$;

create trigger distribution_batches_prevent_finalized_update
    before update on finance.distribution_batches
    for each row
    execute function finance.prevent_finalized_batch_update();

-- وبمجرد ان تصبح الدفعة finalized، يُمنع اضافة/تعديل/حذف اي من بنودها
create or replace function finance.prevent_finalized_batch_lines_change()
returns trigger
language plpgsql
security definer
set search_path = finance, pg_temp
as $$
declare
    v_status text;
begin
    select status into v_status from finance.distribution_batches where id = coalesce(new.batch_id, old.batch_id);
    if v_status = 'finalized' then
        raise exception 'لا يمكن تعديل بنود دفعة توزيع مكتملة (finalized)';
    end if;
    if tg_op = 'DELETE' then
        return old;
    end if;
    return new;
end;
$$;

create trigger distribution_lines_prevent_finalized_change
    before insert or update or delete on finance.distribution_lines
    for each row
    execute function finance.prevent_finalized_batch_lines_change();
