-- تنشئ تلقائيا ملفا شخصيا فارغا فور تسجيل اي مستخدم جديد حساب دخول
create or replace function iam.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = iam, pg_temp
as $$
begin
    insert into iam.profiles (id, full_name)
    values (new.id, coalesce(new.raw_user_meta_data->>'full_name', ''));
    return new;
end;
$$;

create trigger on_auth_user_created
    after insert on auth.users
    for each row
    execute function iam.handle_new_user();
