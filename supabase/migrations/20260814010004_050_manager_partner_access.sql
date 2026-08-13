-- المرحلة 5 - الملف 050 (ق-73): المدير ياخذ صلاحيات المالك التشغيلية (نسخ آلي للسياسات
-- المالكة مع استثناء: الشركاء وسياساتهم والفترات والتوزيعات والتعيينات)،
-- والشريك يطلع على كل بيانات البئر قراءة فقط.

-- 1) نسخ سياسات المالك التشغيلية الى المدير آليا
do $$
declare
  r record;
  v_qual text;
  v_check text;
  v_name text;
  v_made int := 0;
begin
  for r in
    select schemaname, tablename, policyname, cmd, qual, with_check
    from pg_policies
    where schemaname in ('core', 'iam', 'ops', 'billing', 'finance', 'inventory')
      and (coalesce(qual, '') || ' ' || coalesce(with_check, '')) like '%''owner''::text%'
      and (coalesce(qual, '') || ' ' || coalesce(with_check, '')) not like '%manager%'
      and tablename not in (
        'well_partners', 'partner_irrigation_policies', 'accounting_periods',
        'period_reopen_requests', 'period_reopen_approvals',
        'distribution_batches', 'distribution_lines', 'well_assignments'
      )
  loop
    v_name := r.policyname || '_manager';
    if exists (select 1 from pg_policies p
               where p.schemaname = r.schemaname and p.tablename = r.tablename and p.policyname = v_name) then
      continue;
    end if;
    v_qual := nullif(replace(coalesce(r.qual, ''), '''owner''::text', '''manager''::text'), '');
    v_check := nullif(replace(coalesce(r.with_check, ''), '''owner''::text', '''manager''::text'), '');
    execute format(
      'create policy %I on %I.%I for %s to authenticated %s %s',
      v_name, r.schemaname, r.tablename, r.cmd,
      case when v_qual is not null then 'using (' || v_qual || ')' else '' end,
      case when v_check is not null then 'with check (' || v_check || ')' else '' end
    );
    v_made := v_made + 1;
  end loop;
  raise notice 'manager policies created: %', v_made;
end $$;

-- 2) المدير يدير التعيينات التشغيلية فقط (لا يعين مالكا او مديرا)
create policy well_assignments_select_manager on core.well_assignments for select
  using (iam.has_well_role(well_id, array['manager']));
create policy well_assignments_insert_manager on core.well_assignments for insert
  with check (iam.has_well_role(well_id, array['manager']) and role in ('operator', 'farmer', 'partner'));
create policy well_assignments_update_manager on core.well_assignments for update
  using (iam.has_well_role(well_id, array['manager']) and role in ('operator', 'farmer', 'partner'));
create policy well_assignments_delete_manager on core.well_assignments for delete
  using (iam.has_well_role(well_id, array['manager']) and role in ('operator', 'farmer', 'partner'));

-- 3) سياسات اطلاع الشريك: توليد آلي لكل جدول له well_id او tenant_id
do $$
declare
  r record;
  v_name text;
  v_has_well boolean;
  v_has_tenant boolean;
  v_made int := 0;
begin
  for r in
    select t.table_schema, t.table_name
    from information_schema.tables t
    where t.table_schema in ('core', 'iam', 'ops', 'billing', 'finance', 'inventory')
      and t.table_type = 'BASE TABLE'
      and t.table_name not in ('tenants', 'wells', 'notifications')
  loop
    v_name := r.table_name || '_select_partner';
    if exists (select 1 from pg_policies p
               where p.schemaname = r.table_schema and p.tablename = r.table_name and p.policyname = v_name) then
      continue;
    end if;
    select exists (select 1 from information_schema.columns c
                   where c.table_schema = r.table_schema and c.table_name = r.table_name
                     and c.column_name = 'well_id') into v_has_well;
    select exists (select 1 from information_schema.columns c
                   where c.table_schema = r.table_schema and c.table_name = r.table_name
                     and c.column_name = 'tenant_id') into v_has_tenant;
    if v_has_well then
      execute format('create policy %I on %I.%I for select using (iam.is_well_partner(well_id))',
                     v_name, r.table_schema, r.table_name);
      v_made := v_made + 1;
    elsif v_has_tenant then
      execute format('create policy %I on %I.%I for select using (exists (select 1 from core.wells w where w.tenant_id = %I.tenant_id and iam.is_well_partner(w.id)))',
                     v_name, r.table_schema, r.table_name, r.table_name);
      v_made := v_made + 1;
    end if;
  end loop;
  raise notice 'partner select policies created: %', v_made;
end $$;

-- 4) سياسات شريك يدوية للجداول بلا عمود well_id او tenant_id
create policy wells_select_partner on core.wells for select
  using (iam.is_well_partner(id));
create policy tenants_select_partner on core.tenants for select
  using (exists (select 1 from core.wells w where w.tenant_id = tenants.id and iam.is_well_partner(w.id)));
create policy distribution_lines_select_partner on finance.distribution_lines for select
  using (exists (select 1 from finance.distribution_batches b
                 where b.id = distribution_lines.batch_id and iam.is_well_partner(b.well_id)));
create policy profiles_select_partner_colleague on iam.profiles for select
  using (exists (
    select 1 from core.well_partners mine
    join core.well_partners theirs on theirs.well_id = mine.well_id
    where mine.profile_id = auth.uid() and theirs.profile_id = profiles.id
      and mine.status = 'active' and theirs.status = 'active'));
