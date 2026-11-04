begin;
do $test$
declare
 v_user uuid; v_profile uuid; v_tenant uuid; v_well uuid;
 v_farmer_account_1 uuid; v_farmer_account_2 uuid;
 v_res_1 jsonb; v_res_2 jsonb; v_other uuid; v_role text;
 v_denied boolean; v_page jsonb; v_next jsonb; v_ids uuid[];
begin
  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'm101-owner@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_user;

  -- إدراج auth.users يُطلق محفّز handle_new_user الذي يُنشئ iam.profiles
  -- تلقائيًا، فالإدراج المباشر يصطدم بـ profiles_pkey. نمط 075 المثبت:
  -- نقرأ أولًا، وننشئ فقط إن غاب.
  select id into v_profile
  from iam.profiles
  where id = v_user;

  if not found then
    insert into iam.profiles (id, full_name)
    values (v_user, 'مالك اختبار الفرادة')
    returning id into v_profile;
  end if;

  insert into core.tenants (name)
  values ('جهة اختبار الفرادة')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'بئر اختبار الفرادة')
  returning id into v_well;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_well, v_user, 'owner', 'active');

  -- هوية الفاعل عبر الاتفاقية المثبتة في المشروع، ثم دخول دور التطبيق.
  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  -- حسابا مزارعين عبر المسار العام api.create_farmer (نفس نموذج 069/075):
  -- ops.farmer_well_accounts ليس فيه full_name، والهوية تُبنى داخل العقد
  -- core.persons -> ops.farmer_profiles -> ops.farmer_well_accounts، ونلتقط
  -- المعرّف من الرد بدل تكرار معرفة المخطط في الاختبار.
  v_res_1 := api.create_farmer(v_well, 'المزارع الأول', '700000101');
  v_farmer_account_1 := (v_res_1 ->> 'farmer_well_account_id')::uuid;

  v_res_2 := api.create_farmer(v_well, 'المزارع الثاني', '700000102');
  v_farmer_account_2 := (v_res_2 ->> 'farmer_well_account_id')::uuid;


 execute 'reset role';
 if not iam.has_well_permission(v_well,'farm.create') then raise exception 'owner denied'; end if;
 raise notice 'PASS 1 owner retains farm.create';
 update core.well_assignments set role='operator' where well_id=v_well and profile_id=v_user;
 if not iam.has_well_permission(v_well,'farm.create') then raise exception 'operator denied'; end if;
 raise notice 'PASS 2 operator farm.create';
 execute 'set local role authenticated';
 v_res_1:=api.create_farm(v_well,'ارض البركة',v_farmer_account_1,null,gen_random_uuid());
 v_res_2:=api.create_farm(v_well,'أرض البركه',v_farmer_account_1,null,gen_random_uuid());
 if v_res_2->>'status'!='matched_existing' or v_res_1->>'farm_id'!=v_res_2->>'farm_id' then raise exception 'dedup changed'; end if;
 raise notice 'PASS 3 exact duplicate matched existing';
 perform api.create_farm(v_well,'الوادي',v_farmer_account_1,'الشرقية',gen_random_uuid());
 v_res_2:=api.create_farm(v_well,'الوادي',v_farmer_account_1,null,gen_random_uuid());
 if v_res_2->>'status'!='requires_disambiguation' then raise exception 'disambiguation changed'; end if;
 raise notice 'PASS 4 distinguishing label unchanged';
 perform api.create_farm(v_well,'للمزارع الثاني',v_farmer_account_2,null,gen_random_uuid());
 for i in 1..105 loop
   perform api.create_farm(v_well,'قطعة '||lpad(i::text,3,'0'),v_farmer_account_1,null,gen_random_uuid());
 end loop;
 v_page:=api.search_well_farms(v_well,v_farmer_account_1,'قطعة',50,null);
 if jsonb_array_length(v_page->'items')!=50 or v_page->'next_cursor'='null'::jsonb then raise exception 'page bound'; end if;
 v_next:=api.search_well_farms(v_well,v_farmer_account_1,'قطعة',50,v_page->'next_cursor');
 if jsonb_array_length(v_next->'items')!=50 or v_page->'items'->0->>'id'=v_next->'items'->0->>'id' then raise exception 'cursor'; end if;
 if v_page!=api.search_well_farms(v_well,v_farmer_account_1,'قطعة',50,null) then raise exception 'non deterministic'; end if;
 raise notice 'PASS 5 bounded deterministic pagination';
 v_page:=api.search_well_farms(v_well,v_farmer_account_1,'',999,null);
 if jsonb_array_length(v_page->'items')!=100 then raise exception 'hard maximum'; end if;
 raise notice 'PASS 6 hard maximum';
 v_page:=api.search_well_farms(v_well,v_farmer_account_1,'الوادي',50,null);
 if jsonb_array_length(v_page->'items')!=1 or v_page->'items'->0->>'distinguishing_label'!='الشرقية' then raise exception 'query/label'; end if;
 raise notice 'PASS 7 query and label';
 if exists(select 1 from jsonb_array_elements(api.search_well_farms(v_well,v_farmer_account_1,'',100,null)->'items') x where x->>'farmer_well_account_id'!=v_farmer_account_1::text) then raise exception 'farmer leak'; end if;
 raise notice 'PASS 8 farmer scope';
 perform api.list_well_farms(v_well,v_farmer_account_1);
 raise notice 'PASS 9 old signature works';
 execute 'reset role';
 insert into core.wells(tenant_id,name) values(v_tenant,'بئر آخر') returning id into v_other;
 for v_role in select unnest(array['manager','partner','viewer','farmer']) loop
  update core.well_assignments set role=v_role where well_id=v_well and profile_id=v_user;
  if iam.has_well_permission(v_well,'farm.create') then raise exception 'unauthorized %',v_role; end if;
  execute 'set local role authenticated'; v_denied:=false;
  begin perform api.create_farm(v_well,'ممنوعة',v_farmer_account_1,null,gen_random_uuid()); exception when others then v_denied:=true; end;
  execute 'reset role'; if not v_denied then raise exception 'role bypass %',v_role; end if;
  raise notice 'PASS role % denied',v_role;
 end loop;
 update core.well_assignments set role='operator',status='inactive' where well_id=v_well and profile_id=v_user;
 if iam.has_well_permission(v_well,'farm.create') then raise exception 'inactive'; end if;
 execute 'set local role authenticated';v_denied:=false;
 begin perform api.create_farm(v_well,'ممنوعة للموقوف',v_farmer_account_1,null,gen_random_uuid());exception when others then v_denied:=true;end;
 execute 'reset role';if not v_denied then raise exception 'inactive create';end if;
 raise notice 'PASS 10 inactive denied';
 update core.well_assignments set status='active' where well_id=v_well and profile_id=v_user;
 execute 'set local role authenticated'; v_denied:=false;
 begin perform api.create_farm(v_other,'ممنوعة',v_farmer_account_1,null,gen_random_uuid()); exception when others then v_denied:=true; end;
 if not v_denied then raise exception 'cross well write'; end if;
 raise notice 'PASS 11 cross well create denied';
 v_denied:=false;
 begin perform api.search_well_farms(v_other,v_farmer_account_1,'',50,null); exception when others then v_denied:=true; end;
 if not v_denied then raise exception 'cross well read'; end if;
 raise notice 'PASS 12 cross well read denied';
 execute 'reset role';
 if has_table_privilege('authenticated','ops.farms','INSERT') or has_function_privilege('anon','api.search_well_farms(uuid,uuid,text,integer,jsonb)','EXECUTE') or has_function_privilege('anon','api.create_farm(uuid,text,uuid,text,uuid)','EXECUTE') then raise exception 'grants'; end if;
 if (select prosecdef from pg_proc where oid='api.search_well_farms(uuid,uuid,text,integer,jsonb)'::regprocedure) then raise exception 'definer'; end if;
 raise notice 'PASS 13 invoker and no direct DML or anon';
 -- حساب صالح في بئر آخر لا يجوز ربطه بأرض البئر الحالي.
 insert into core.well_assignments(well_id,profile_id,role,status) values(v_other,v_user,'owner','active');
 execute 'set local role authenticated';
 v_res_2:=api.create_farmer(v_other,'مزارع بئر آخر','700009999');
 v_denied:=false;
 begin perform api.create_farm(v_well,'ربط ممنوع',(v_res_2->>'farmer_well_account_id')::uuid,null,gen_random_uuid()); exception when others then v_denied:=true; end;
 if not v_denied then raise exception 'cross farmer write'; end if;
 raise notice 'PASS 14 farmer well consistency';
 perform api.create_farm(v_well,'الترتيب',v_farmer_account_1,null,gen_random_uuid());
 perform api.create_farm(v_well,'الترتيب الشرقي',v_farmer_account_1,null,gen_random_uuid());
 perform api.create_farm(v_well,'أرض أخرى',v_farmer_account_1,'الترتيب',gen_random_uuid());
 v_page:=api.search_well_farms(v_well,v_farmer_account_1,'الترتيب',50,null);
 if v_page->'items'->0->>'name'!='الترتيب' or v_page->'items'->1->>'name'!='الترتيب الشرقي' or jsonb_array_length(v_page->'items')!=3 then raise exception 'ranking'; end if;
 raise notice 'PASS 15 exact prefix remaining order';
 execute 'reset role';
 alter table ops.farms disable trigger trg_enforce_farm_uniqueness;
 insert into ops.farms(well_id,farmer_well_account_id,name,status) values(v_well,v_farmer_account_1,'عنقود قديم','active'),(v_well,v_farmer_account_1,'عنقود قديم','active');
 alter table ops.farms enable trigger trg_enforce_farm_uniqueness;
 execute 'set local role authenticated';
 v_res_2:=api.create_farm(v_well,'عنقود قديم',v_farmer_account_1,null,gen_random_uuid());
 if v_res_2->>'status'!='requires_resolution' then raise exception 'historical cluster changed'; end if;
 raise notice 'PASS 16 historical resolution preserved';
 execute 'reset role';
 execute 'set local role anon';v_denied:=false;
 begin perform api.search_well_farms(v_well,v_farmer_account_1,'',50,null);exception when others then v_denied:=true;end;
 execute 'reset role';if not v_denied then raise exception 'anon read';end if;
 raise notice 'PASS 17 anon execution denied';
 execute 'set local role authenticated';v_denied:=false;
 begin insert into ops.farms(well_id,farmer_well_account_id,name,status) values(v_well,v_farmer_account_1,'كتابة مباشرة','active');exception when insufficient_privilege then v_denied:=true;end;
 execute 'reset role';if not v_denied then raise exception 'direct DML';end if;
 raise notice 'PASS 18 direct DML denied';
 update ops.farms set status='inactive' where well_id=v_well and name='الترتيب';
 execute 'set local role authenticated';
 v_page:=api.search_well_farms(v_well,v_farmer_account_1,'الترتيب',50,null);
 if exists(select 1 from jsonb_array_elements(v_page->'items') x where x->>'name'='الترتيب' or x->>'status'!='active') then raise exception 'inactive lookup';end if;
 execute 'reset role';
 raise notice 'PASS 19 inactive farms excluded';


end;
$test$;
rollback;
