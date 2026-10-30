-- =====================================================================
-- اختبار الدائم: إلغاء سلاسل الانتقال التلقائي واعتماد التشغيل اليدوي المستقل
--
-- 1. بدء الحجز اليدوي ينجح بالكامل دون إنشاء أو تحديث أي سلسلة انتقال.
-- 2. إكمال الجلسة المحجوزة ينجح دون اشتراط عضوية السلسلة، ولا يعيد decision_required.
-- 3. إعادة إرسال أمر الإكمال بالمعرف نفسه تعيد نفس الإقرار المخزن (إيديمبوتنس).
-- 4. منع الجلسات المتنافسة المفتوحة على نفس البئر قائم وصارم.
-- 5. نقاط الدخول القديمة للانتقال التلقائي ترفض الاستدعاء دون أي آثار جانبية.
-- =====================================================================

\set ON_ERROR_STOP on
begin;

set local timezone to 'UTC';

create function pg_temp.test_check(ok boolean, label text)
returns void language plpgsql as $$
begin
  if ok is distinct from true then raise exception 'FAIL %', label; end if;
  raise notice 'PASS %', label;
end $$;

do $test_suite$
declare
  v_tenant uuid;
  v_person uuid;
  v_profile uuid;
  v_op uuid;
  v_well uuid;
  v_acc uuid;
  v_farm uuid;
  v_pump uuid;
  v_booking uuid;
  v_start_res jsonb;
  v_session_id uuid;
  v_complete_res jsonb;
  v_replay_res jsonb;
  v_cmd_id uuid := gen_random_uuid();
  v_start_cmd uuid := gen_random_uuid();
  v_free uuid;
  v_rejected_cmd uuid := gen_random_uuid();
  v_receipt_before jsonb;
  v_count bigint;
  v_old_cmd uuid := gen_random_uuid();
  v_old_row jsonb;
  v_denied uuid := gen_random_uuid();
  v_denied_cmd uuid := gen_random_uuid();
  v_now timestamptz := date_trunc('minute', clock_timestamp()) - interval '40 minutes';
  v_end timestamptz := v_now + interval '30 minutes';
begin
  -- تجهيز الكيانات الأساسية
  insert into core.tenants (name) values ('جهة اختبار إلغاء السلاسل') returning id into v_tenant;
  insert into core.persons (tenant_id, full_name, normalized_name)
    values (v_tenant, 'مزارع يدوي', 'مزارع يدوي') returning id into v_person;
  insert into ops.farmer_profiles (tenant_id, person_id)
    values (v_tenant, v_person) returning id into v_profile;

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
    values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'op-manual@test.local', crypt('pass', gen_salt('bf')), now(), now(), now())
    returning id into v_op;
  insert into iam.profiles (id, full_name) values (v_op, 'مشغل يدوي') on conflict (id) do nothing;

  insert into core.wells (tenant_id, name) values (v_tenant, 'بئر الاختبار اليدوي') returning id into v_well;
  insert into core.well_assignments (well_id, profile_id, role, status)
    values (v_well, v_op, 'operator', 'active');

  insert into ops.farmer_well_accounts (tenant_id, farmer_profile_id, well_id, public_code)
    values (v_tenant, v_profile, v_well, 'FWA-MANUAL-01') returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
    values (v_well, 'أرض تجربة', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
    values (v_well, 'مضخة ديزل', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
    values (v_well, 6000, date '2026-01-01');

  -- إنشاء حجز مؤكد
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end,
    expected_duration_minutes, expected_energy_source,
    status, priority, created_by
  ) values (
    v_tenant, 'BKG-TEST-01', v_well, v_acc, v_farm,
    v_now, v_end,
    30, 'well_diesel',
    'confirmed', 1, v_op
  ) returning id into v_booking;

  -- 1. التأكد من عدم وجود أي سلاسل قبل البدء
  perform pg_temp.test_check(
    (select count(*) from ops.booking_transition_chains where well_id = v_well) = 0,
    'T1: لا توجد سلاسل انتقال سابقة على البئر'
  );

  -- 2. تنفيذ بدء الحجز اليدوي عبر ops.start_booking_session_core
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  v_start_res := api.start_irrigation_session_from_booking(
    v_booking, v_now, v_start_cmd, array['نخيل']);
  v_replay_res := api.start_irrigation_session_from_booking(
    v_booking, v_now, v_start_cmd, array['نخيل']);
  execute 'reset role';
  perform pg_temp.test_check(v_start_res = v_replay_res,
    'T2b: authenticated operator manual start replays the exact original receipt');
  v_session_id := (v_start_res ->> 'session_id')::uuid;

  perform pg_temp.test_check(
    v_session_id is not null and (v_start_res ->> 'session_status') = 'open',
    'T2: بدء الجلسة المحجوزة تم بنجاح وأنتج جلسة مفتوحة'
  );

  -- التأكد من عدم إنشاء أي سلسلة انتقال جديدة في جدول ops.booking_transition_chains
  perform pg_temp.test_check(
    (select count(*) from ops.booking_transition_chains where well_id = v_well) = 0,
    'T3: بدء الحجز لم ينشئ أي سلسلة انتقال في جدول ops.booking_transition_chains'
  );

  -- 3. التحقق من منع جلسة ثانية متنافسة فوق الجلسة المفتوحة
  declare
    v_b2 uuid;
    v_caught_competing boolean := false;
  begin
    insert into ops.irrigation_bookings (
      tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
      scheduled_start, scheduled_end,
      expected_duration_minutes, expected_energy_source,
      status, priority, created_by
    ) values (
      v_tenant, 'BKG-TEST-02', v_well, v_acc, v_farm,
      v_end, v_end + interval '30 minutes',
      30, 'well_diesel',
      'confirmed', 2, v_op
    ) returning id into v_b2;

    begin
      execute 'set local role authenticated';
      perform api.start_irrigation_session_from_booking(v_b2,v_now,gen_random_uuid(),null);
    exception when others then
      v_caught_competing := SQLERRM like '%جلسة مفتوحة%' or SQLSTATE='23505';
    end;

    execute 'reset role';
    perform pg_temp.test_check(v_caught_competing and
      (select count(*) from ops.irrigation_sessions where well_id=v_well and status='open')=1, 'T4: منع بدء جلسة ثانية أثناء وجود جلسة مفتوحة');
  end;

  -- 4. إكمال الجلسة عبر api.complete_booking_session
  execute 'set local role authenticated';
  v_complete_res := api.complete_booking_session(
    v_session_id,
    v_end,
    v_cmd_id,
    null,
    null,
    null
  );

  perform pg_temp.test_check(
    (v_complete_res ->> 'status') = 'closed',
    'T5: إكمال الجلسة نجح دون اشتراط عضوية السلسلة'
  );

  execute 'reset role';
  -- التأكد من عدم إنشاء أو تعديل أي صف في booking_transition_chains ليكون decision_required
  perform pg_temp.test_check(
    (select count(*) from ops.booking_transition_chains where well_id = v_well) = 0,
    'T6: إغلاق الجلسة لم ينشئ decision_required'
  );

  -- 5. اختبار الإيديمبوتنس وتكرار أمر الإكمال بالمعرف نفسه
  execute 'set local role authenticated';
  v_replay_res := api.complete_booking_session(
    v_session_id,
    v_end,
    v_cmd_id,
    null,
    null,
    null
  );

  perform pg_temp.test_check(
    v_replay_res = v_complete_res,
    'T7: إعادة إرسال نفس الأمر تعيد نفس الإقرار دون تكرار المحاسبة'
  );

  execute 'reset role';
  select to_jsonb(pc) into v_receipt_before from sync.processed_commands pc
    where pc.tenant_id = v_tenant and pc.command_id = v_cmd_id;
  select count(*) into v_count from sync.processed_commands;
  -- 6. اختبار إبطال نقاط الدخول القديمة للانتقال التلقائي
  declare
    v_err_trans boolean := false;
    v_err_dec boolean := false;
    v_err_pending boolean := false;
  begin
    begin
      execute 'reset role';
      perform ops.execute_booking_transition(v_well, 0::bigint, gen_random_uuid());
    exception when feature_not_supported then
      v_err_trans := true;
    end;

    begin
      execute 'set local role authenticated';
      perform api.record_booking_transition_decision(gen_random_uuid(), v_session_id, v_booking, 'run_now', 0::bigint, gen_random_uuid());
    exception when feature_not_supported then
      v_err_dec := true;
    end;

    begin
      execute 'set local role authenticated';
      perform api.execute_pending_booking_start(gen_random_uuid(), 0::bigint, gen_random_uuid());
    exception when feature_not_supported then
      v_err_pending := true;
    end;

    perform pg_temp.test_check(v_err_trans, 'T8: execute_booking_transition ملغى نهائيًا');
    perform pg_temp.test_check(v_err_dec, 'T9: record_booking_transition_decision ملغى نهائيًا');
    perform pg_temp.test_check(v_err_pending, 'T10: execute_pending_booking_start ملغى نهائيًا');
  end;

  execute 'reset role';
  perform pg_temp.test_check((select count(*) from sync.processed_commands) = v_count,
    'T11: disabled real signatures create zero commands');
  perform pg_temp.test_check((select to_jsonb(pc) from sync.processed_commands pc
    where pc.tenant_id=v_tenant and pc.command_id=v_cmd_id) = v_receipt_before,
    'T12: original accepted receipt identity/payload/fingerprint preserved');
  perform pg_temp.test_check((select count(*) from billing.session_charges sc
    where sc.session_id=v_session_id)=1,
    'T13: one original charge, never recalculated on replay');
  perform pg_temp.test_check(not exists (
    select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
    where n.nspname='api' and p.proname in ('record_booking_transition_decision','execute_pending_booking_start')
      and (p.prosecdef or has_function_privilege('anon',p.oid,'EXECUTE')
        or not has_function_privilege('authenticated',p.oid,'EXECUTE')
        or not has_function_privilege('service_role',p.oid,'EXECUTE')
        or exists (select 1 from pg_catalog.aclexplode(coalesce(p.proacl,
          pg_catalog.acldefault('f',p.proowner))) a where a.grantee=0 and a.privilege_type='EXECUTE'))),
    'T14: API remains invoker, auth/service grants explicit, anon/PUBLIC blocked');
  begin
    perform ops.execute_booking_transition_automation(v_well,gen_random_uuid(),v_session_id,
      v_booking,0::bigint,0::bigint,1::bigint,gen_random_uuid(),gen_random_uuid(),gen_random_uuid());
    raise exception 'FAIL T15: real P2 automation executed';
  exception when feature_not_supported then
    perform pg_temp.test_check(true,'T15: real scheduled/Edge P2 executor cannot execute');
  end;
  begin
    perform ops.execute_pending_booking_start(gen_random_uuid(),0::bigint,v_op);
    raise exception 'FAIL T16: internal pending executor executed';
  exception when feature_not_supported then
    perform pg_temp.test_check(true,'T16: direct internal pending executor blocked');
  end;
  begin
    perform ops.record_booking_transition_decision(gen_random_uuid(),v_session_id,v_booking,
      'run_now',0::bigint,v_op,gen_random_uuid());
    raise exception 'FAIL T17: internal decision executed';
  exception when feature_not_supported then
    perform pg_temp.test_check(true,'T17: direct internal decision writer blocked');
  end;

  execute 'set local role service_role';
  begin
    perform ops.execute_booking_transition_automation(v_well,gen_random_uuid(),v_session_id,
      v_booking,0::bigint,0::bigint,1::bigint,gen_random_uuid(),gen_random_uuid(),gen_random_uuid());
    raise exception 'FAIL T31: service caller executed P2';
  exception when insufficient_privilege then
    perform pg_temp.test_check(true,'T31: scheduled service role has no executor grant');
  end;
  execute 'reset role';
  execute 'set local role anon';
  begin
    perform api.execute_pending_booking_start(gen_random_uuid(),0::bigint,gen_random_uuid());
    raise exception 'FAIL T32: anonymous caller executed API';
  exception when insufficient_privilege then
    perform pg_temp.test_check(true,'T32: real anonymous invocation denied');
  end;
  execute 'reset role';

  -- A historical accepted manual completion may have no saved request payload.
  insert into sync.processed_commands(tenant_id,command_id,command_type,entity_id,status,response_payload)
    values(v_tenant,v_old_cmd,'complete_irrigation_session',v_session_id,'accepted',v_complete_res);
  select to_jsonb(pc) into v_old_row from sync.processed_commands pc
    where pc.tenant_id=v_tenant and pc.command_id=v_old_cmd;
  execute 'set local role authenticated';
  v_replay_res := api.get_completion_receipt(v_well,v_session_id,v_old_cmd,'complete_irrigation_session');
  perform pg_temp.test_check(v_replay_res->>'status'='accepted'
    and v_replay_res->'receipt'=v_complete_res and v_replay_res->>'retry_authorized'='false',
    'T18: old NULL-request receipt read returns original values, never retry authority');
  execute 'reset role';
  perform pg_temp.test_check((select to_jsonb(pc) from sync.processed_commands pc
    where pc.tenant_id=v_tenant and pc.command_id=v_old_cmd)=v_old_row,
    'T19: historical accepted command unchanged by read');

  -- Remove only the unused competing fixture booking from execution eligibility.
  update ops.irrigation_bookings set status='cancelled'
    where well_id=v_well and id<>v_booking;
  execute 'set local role authenticated';
  v_free := api.start_irrigation_session(v_well,v_pump,v_farm,v_acc,'well_diesel',
    v_end+interval '1 minute',null,gen_random_uuid(),null);
  begin
    perform api.complete_booking_session(v_free,v_end+interval '2 minutes',v_rejected_cmd,null,null,null);
    raise exception 'FAIL T20: booking completion accepted a free session';
  exception when invalid_parameter_value then
    perform pg_temp.test_check(true,'T20: free session rejected by booking completion');
  end;
  execute 'reset role';
  perform pg_temp.test_check(not exists(select 1 from sync.processed_commands where command_id=v_rejected_cmd),
    'T21: refused free completion creates no command or charge');
  execute 'set local role authenticated';
  v_replay_res := api.complete_irrigation_session(v_free,v_end+interval '2 minutes',null,null,null,gen_random_uuid());
  execute 'reset role';
  perform pg_temp.test_check(v_replay_res->>'status'='closed',
    'T22: normal explicit free-session completion still works without chains');

  insert into auth.users(id,raw_user_meta_data) values(v_denied,'{"full_name":"غير مخول"}');
  insert into core.well_assignments(well_id,profile_id,role,status)
    values(v_well,v_denied,'partner','active');
  perform set_config('request.jwt.claim.sub',v_denied::text,true);
  execute 'set local role authenticated';
  begin
    perform api.start_irrigation_session_from_booking(v_booking,v_now,v_denied_cmd,null);
    raise exception 'FAIL T25: unauthorized role started booking';
  exception when others then
    if SQLERRM like 'FAIL %' then raise; end if;
    perform pg_temp.test_check(SQLSTATE='42501' or SQLERRM like '%صلاحية%',
      'T25: authenticated role without session.start is denied for authorization');
  end;
  begin
    perform api.complete_booking_session(v_session_id,v_end,v_denied_cmd,null,null,null);
    raise exception 'FAIL T26: unauthorized role completed booking';
  exception when others then
    if SQLERRM like 'FAIL %' then raise; end if;
    perform pg_temp.test_check(SQLSTATE='42501' or SQLERRM like '%صلاحية%',
      'T26: authenticated role without session.complete is denied for authorization');
  end;
  execute 'reset role';
  perform pg_temp.test_check(not exists(select 1 from sync.processed_commands where command_id=v_denied_cmd),
    'T27: permission failures create no command');
  perform set_config('request.jwt.claim.sub',v_op::text,true);
  begin
    perform ops.start_booking_session_core(v_booking,v_denied,v_now,null);
    raise exception 'FAIL T28: caller supplied another operator';
  exception when others then
    if SQLERRM like 'FAIL %' then raise; end if;
    perform pg_temp.test_check(SQLERRM like '%المشغل%','T28: operator identity must match auth.uid');
  end;
  execute 'set local role authenticated';
  begin
    perform api.complete_booking_session(v_session_id,v_end,v_old_cmd,null,null,null);
    raise exception 'FAIL T29: historical command identity reused for a different type';
  exception when others then
    if SQLERRM like 'FAIL %' then raise; end if;
    perform pg_temp.test_check(SQLERRM like '%محتوى مختلف%',
      'T29: accepted historical command cannot be rewritten as another completion type');
  end;
  execute 'reset role';
  perform pg_temp.test_check((select to_jsonb(pc) from sync.processed_commands pc
    where pc.tenant_id=v_tenant and pc.command_id=v_old_cmd)=v_old_row,
    'T30: conflicting replay leaves original receipt and financial identity intact');

  -- Retired settings/terminal contracts are replay-only, never new writes.
  perform set_config('request.jwt.claim.sub',v_op::text,true);
  execute 'set local role authenticated';
  begin
    perform api.set_well_booking_automation(v_well,true,0,gen_random_uuid());
    raise exception 'FAIL R1: automation reactivated';
  exception when feature_not_supported then
    perform pg_temp.test_check(true,'R1: real API refuses new activation');
  end;
  begin
    perform ops.set_well_booking_automation(v_well,true,0,v_op,gen_random_uuid());
    raise exception 'FAIL R2: internal setter reactivated automation';
  exception when feature_not_supported then
    perform pg_temp.test_check(true,'R2: internal setter refuses new activation');
  end;
  begin
    perform api.end_booking_transition_chain(v_session_id,gen_random_uuid());
    raise exception 'FAIL R3: terminal contract wrote a new effect';
  exception when feature_not_supported then
    perform pg_temp.test_check(true,'R3: real terminal API refuses new effects');
  end;
  execute 'reset role';
  v_denied_cmd := gen_random_uuid();
  v_rejected_cmd := gen_random_uuid();
  insert into sync.processed_commands(tenant_id,command_id,command_type,entity_id,
    request_payload,status,response_payload) values
    (v_tenant,v_denied_cmd,'set_well_booking_automation',v_well,
      jsonb_build_object('well_settings_contract_version',113,'well_id',v_well,
        'enabled',true,'expected_revision',null),'accepted',
      '{"setting_saved":true,"booking_auto_transition_enabled":true}'),
    (v_tenant,v_rejected_cmd,'end_booking_transition_chain',v_session_id,
      jsonb_build_object('version',1,'session_id',v_session_id),'accepted',
      jsonb_build_object('status','ended','session_id',v_session_id));
  select count(*) into v_count from sync.processed_commands;
  select to_jsonb(pc) into v_old_row from sync.processed_commands pc
    where tenant_id=v_tenant and command_id=v_denied_cmd;
  select to_jsonb(ws) into v_receipt_before from core.well_settings ws where well_id=v_well;
  execute 'set local role authenticated';
  v_replay_res := api.set_well_booking_automation(v_well,true,null,v_denied_cmd);
  perform pg_temp.test_check(v_replay_res='{"setting_saved":true,"booking_auto_transition_enabled":true}'::jsonb,
    'R4: exact historical activation returns original response only');
  v_replay_res := api.end_booking_transition_chain(v_session_id,v_rejected_cmd);
  perform pg_temp.test_check(v_replay_res=jsonb_build_object('status','ended','session_id',v_session_id),
    'R5: historical terminal result replays exactly');
  begin
    perform api.set_well_booking_automation(v_well,false,null,v_denied_cmd);
    raise exception 'FAIL R6: historical request identity overwritten';
  exception when invalid_parameter_value then
    perform pg_temp.test_check(true,'R6: historical payload mismatch rejected');
  end;
  execute 'reset role';
  perform pg_temp.test_check((select count(*) from sync.processed_commands)=v_count
    and (select to_jsonb(ws) from core.well_settings ws where well_id=v_well)
      is not distinct from v_receipt_before
    and (select to_jsonb(pc) from sync.processed_commands pc
      where tenant_id=v_tenant and command_id=v_denied_cmd)=v_old_row,
    'R7: replay changes neither settings, command count nor original receipt');
  execute 'set local role authenticated';
  begin
    perform api.set_well_booking_automation(v_well,false,0,gen_random_uuid());
    raise exception 'FAIL R8: retired disable command wrote new settings';
  exception when feature_not_supported then
    perform pg_temp.test_check(true,'R8: new disable also remains replay-only');
  end;
  execute 'reset role';
  perform set_config('request.jwt.claim.sub',v_denied::text,true);
  execute 'set local role authenticated';
  begin
    perform api.set_well_booking_automation(v_well,true,null,v_denied_cmd);
    raise exception 'FAIL R9: unauthorized user read activation receipt';
  exception when insufficient_privilege then
    perform pg_temp.test_check(true,'R9: historical activation requires current operator permission');
  end;
  begin
    perform api.end_booking_transition_chain(v_session_id,v_rejected_cmd);
    raise exception 'FAIL R10: unauthorized user read terminal receipt';
  exception when insufficient_privilege then
    perform pg_temp.test_check(true,'R10: historical terminal receipt requires current permission');
  end;
  execute 'reset role';
  perform set_config('request.jwt.claim.sub',v_op::text,true);
  perform pg_temp.test_check(not exists(
    select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
    where (n.nspname,p.proname) in (
      ('api','set_well_booking_automation'),('ops','set_well_booking_automation'),
      ('api','end_booking_transition_chain'),('ops','end_booking_transition_chain'),
      ('sync','end_booking_transition_chain_command'))
    and (pg_catalog.has_function_privilege('anon',p.oid,'EXECUTE')
      or exists(select 1 from pg_catalog.aclexplode(coalesce(p.proacl,
        pg_catalog.acldefault('f',p.proowner))) a where a.grantee=0 and a.privilege_type='EXECUTE')
      or (n.nspname='api' and p.prosecdef)
      or (pg_catalog.has_function_privilege('authenticated',p.oid,'EXECUTE')
        and not pg_catalog.has_function_privilege('service_role',p.oid,'EXECUTE')))),
    'R11: replay API invoker/grants preserve anon/PUBLIC denial and service symmetry');
  -- Restore the previous historical receipt variable for the authorization test.
  select to_jsonb(pc) into v_old_row from sync.processed_commands pc
    where tenant_id=v_tenant and command_id=v_old_cmd;

  -- Authorization comes from an active assignment, including on accepted replay.
  update core.well_assignments set status='inactive' where well_id=v_well and profile_id=v_op;
  execute 'set local role authenticated';
  begin
    perform api.get_completion_receipt(v_well,v_session_id,v_old_cmd,'complete_irrigation_session');
    raise exception 'FAIL T23: revoked operator read old receipt';
  exception when insufficient_privilege then
    perform pg_temp.test_check(true,'T23: revoked assignment cannot read receipt');
  end;
  execute 'reset role';
  perform pg_temp.test_check((select count(*) from ops.booking_transition_chains where well_id=v_well)=0,
    'T24: manual booked and free start/complete never create transition chains');

end $test_suite$;

rollback;
