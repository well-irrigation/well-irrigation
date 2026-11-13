#!/usr/bin/env python3
"""Disposable local Supabase only; real psql connections and observed lock waits.

Requires MANUAL_FINANCIAL_DISPOSABLE_DATABASE=yes. Uses local container sockets,
not passwords, dblink, role changes, or auth configuration. Fixtures commit for
cross-connection visibility: RESET THE LOCAL DATABASE AFTER RUNNING THIS FILE.
"""
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]


def require(ok, label):
    if not ok:
        raise AssertionError(label)
    print('PASS ' + label, flush=True)


class Connection:
    def __init__(self, container):
        self.proc = subprocess.Popen(
            ['docker', 'exec', '-i', container, 'psql', '-X', '-Atq', '-U',
             'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, bufsize=1)
        self.lines = queue.Queue()
        def reader():
            for line in self.proc.stdout:
                self.lines.put(line.strip())
            self.lines.put('PROCESS_EXIT')
        threading.Thread(target=reader, daemon=True).start()
        self.send("\\set VERBOSITY verbose\nset statement_timeout='15000ms'; select 'PID:'||pg_backend_pid();\n\\echo READY")
        lines = self.until('READY')
        self.pid = int(next(x[4:] for x in lines if x.startswith('PID:')))

    def send(self, sql):
        self.proc.stdin.write(sql + '\n')
        self.proc.stdin.flush()

    def until(self, marker):
        result = []
        deadline = time.monotonic() + 25
        while True:
            line = self.lines.get(timeout=max(0.1, deadline-time.monotonic()))
            if line == marker:
                return result
            if line == 'PROCESS_EXIT' or 'ERROR:' in line:
                raise RuntimeError('\n'.join(result + [line]))
            result.append(line)

    def run(self, sql):
        marker = 'DONE_' + uuid.uuid4().hex
        self.send(sql + '\n\\echo ' + marker)
        return self.until(marker)

    def close(self):
        if self.proc.poll() is None:
            try:
                self.send('rollback;\n\\q')
                self.proc.wait(timeout=5)
            except (BrokenPipeError, subprocess.TimeoutExpired):
                self.proc.terminate()


def data(lines):
    return json.loads(next(x[5:] for x in reversed(lines) if x.startswith('DATA:')))



def f_recon_worker_races(setup, container):
    """Opt-in queue races reuse the established two-connection lock harness."""
    test = (ROOT/'supabase/tests/20261110000000_session_financial_adjustment.test.sql').read_text()
    setup.run(test[test.index('create function pg_temp.sfa_fixture'):test.index('create function pg_temp.sfa_zero_reads')])
    for scenario in ('manual_first', 'worker_first'):
        f = data(setup.run("begin; set local timezone='UTC'; select 'DATA:'||pg_temp.sfa_fixture(10000,0,true)::text; commit;"))
        sid, actor = f['session'], f['actor']
        correction = data(setup.run(f"begin; select 'DATA:'||to_json(pg_temp.sfa_correct('{json.dumps(f)}'::jsonb,0,8000)); commit;"))
        msg = data(setup.run(f"select 'DATA:'||json_build_object('id',min(msg_id),'count',count(*)) from pgmq.q_session_correction_reconciliation where message=jsonb_build_object('correction_id','{correction}'::uuid);"))
        require(msg['count'] == 1, scenario+' committed correction has exactly one durable message to independent transaction')
        mid = msg['id']
        setup.run("begin; set local role reconciliation_executor; select * from billing.lease_session_correction_reconciliation_messages(100,60); commit;")
        worker_prefix = "begin; set local timezone='UTC'; select set_config('request.jwt.claim.sub','',true); set local role reconciliation_executor;"
        human_prefix = f"begin; set local timezone='UTC'; select set_config('request.jwt.claim.sub','{actor}',true); set local role authenticated;"
        worker = f"billing.process_session_correction_reconciliation_message({mid})"
        manual_cmd = str(uuid.uuid4())
        manual = lambda system: f"api.adjust_session_financial_amount('{sid}','{manual_cmd}',1,{system},0,8500,'worker race manual decision','{f['posting']}')"
        a, b = Connection(container), Connection(container)
        try:
            first_prefix, second_prefix = (human_prefix, worker_prefix) if scenario == 'manual_first' else (worker_prefix, human_prefix)
            first, second = (manual(0), worker) if scenario == 'manual_first' else (worker, manual(0))
            winner = data(a.run(first_prefix+f"select 'DATA:'||({first})::text;"))
            require(winner['status'] == ('accepted' if scenario == 'manual_first' else 'applied'), scenario+' first transaction canonical result before commit')
            if scenario == 'worker_first':
                visible = data(setup.run(f"select 'DATA:'||json_build_object('queue',exists(select 1 from pgmq.q_session_correction_reconciliation where msg_id={mid}),'money',exists(select 1 from billing.session_charge_corrections where correction_id='{correction}'));"))
                require(visible == {'queue': True, 'money': False}, 'worker_first no uncommitted financial or archive visibility')
            b.send(second_prefix+f"select 'DATA:'||({second})::text; commit;\n\\echo F_RECON_SECOND_DONE")
            waited = False
            for _ in range(40):
                if data(setup.run(f"select 'DATA:'||to_json({a.pid}=any(pg_blocking_pids({b.pid})));")):
                    waited = True
                    break
                time.sleep(0.05)
            require(waited, scenario+' observed real two-connection root lock contention')
            a.run('commit;')
            loser = data(b.until('F_RECON_SECOND_DONE'))
            if scenario == 'manual_first':
                require(loser['status']=='applied' and loser['already_completed'], 'manual_first worker preserves explicitly paired approval')
            else:
                require(loser['status']=='conflict_revision', 'worker_first stale manual basis explicitly rejected')
                # A changed revision basis is a new human command, not replay.
                manual_cmd = str(uuid.uuid4())
                accepted = data(setup.run(human_prefix+f"select 'DATA:'||({manual(1)})::text; commit;"))
                require(accepted['status']=='accepted', 'worker_first explicit manual resubmission on current basis accepted')
            proof_sql = f"""select 'DATA:'||json_build_object(
 'system_count',(select count(*) from billing.session_charge_corrections where correction_id='{correction}'),
 'system_revisions',(select count(distinct operational_revision) from billing.session_charge_corrections where session_id='{sid}'),
 'approval_count',(select count(*) from billing.session_financial_adjustments where session_id='{sid}'),
 'approval_revisions',(select count(distinct manual_approval_revision) from billing.session_financial_adjustments where session_id='{sid}'),
 'effective',(select amount_minor from billing.approved_session_charges where session_id='{sid}'),
 'invoice',(select total_minor from billing.effective_invoice_totals where session_id='{sid}'),
 'work',(select status from ops.session_correction_reconciliations where correction_id='{correction}'),
 'queue',(select count(*) from pgmq.q_session_correction_reconciliation where msg_id={mid}),
 'archive',(select count(*) from pgmq.a_session_correction_reconciliation where msg_id={mid}));"""
            proof = data(setup.run(proof_sql))
            require(proof == {'system_count':1,'system_revisions':1,'approval_count':1,'approval_revisions':1,
                              'effective':8500,'invoice':8500,'work':'applied','queue':0,'archive':1},
                    scenario+' no deadlock duplicate system/revision or overwritten manual decision')
            # Force an actual redelivery through the queue, then compare all money.
            duplicate = data(setup.run(f"begin; select 'DATA:'||to_json(pgmq.send('session_correction_reconciliation',jsonb_build_object('correction_id','{correction}'::uuid))); commit;"))
            setup.run("begin; set local role reconciliation_executor; select * from billing.lease_session_correction_reconciliation_messages(100,60); commit;")
            replay = data(setup.run(worker_prefix+f"select 'DATA:'||billing.process_session_correction_reconciliation_message({duplicate})::text; commit;"))
            require(replay['status']=='applied' and replay['already_completed'] and data(setup.run(proof_sql))==proof,
                    scenario+' committed redelivery preserves canonical economic effect')
            print('CASE f_recon_'+scenario+' COMPLETE', flush=True)
        finally:
            a.close()
            b.close()


    # Authorization is read again AFTER the worker waits for the financial root.
    f = data(setup.run("begin; set local timezone='UTC'; select 'DATA:'||pg_temp.sfa_fixture(10000,0,true)::text; commit;"))
    c = data(setup.run(f"begin; select 'DATA:'||to_json(pg_temp.sfa_correct('{json.dumps(f)}'::jsonb,0,8000)); commit;"))
    mid = data(setup.run(f"select 'DATA:'||to_json(msg_id) from pgmq.q_session_correction_reconciliation where message=jsonb_build_object('correction_id','{c}'::uuid);"))
    setup.run("begin; set local role reconciliation_executor; select * from billing.lease_session_correction_reconciliation_messages(100,60); commit;")
    a, b = Connection(container), Connection(container)
    try:
        a.run(f"begin; select billing.lock_customer_credit_well('{f['well']}');")
        b.send(f"begin; set local role reconciliation_executor; select 'DATA:'||billing.process_session_correction_reconciliation_message({mid})::text; commit;\n\\echo REVOKED_DONE")
        waited = False
        for _ in range(40):
            if data(setup.run(f"select 'DATA:'||to_json({a.pid}=any(pg_blocking_pids({b.pid})));")):
                waited = True
                break
            time.sleep(0.05)
        require(waited, 'revoked_actor real worker wait before authorization revalidation')
        a.run(f"update core.well_assignments set status='inactive' where well_id='{f['well']}'; commit;")
        r = data(b.until('REVOKED_DONE'))
        require(r['status']=='financial_review_required' and r['review_code']=='actor_authorization_changed',
                'revoked_actor after-wait assignment change becomes terminal review')
        proof = data(setup.run(f"select 'DATA:'||json_build_object('money',(select count(*) from billing.session_charge_corrections where correction_id='{c}'),'archive',(select count(*) from pgmq.a_session_correction_reconciliation where msg_id={mid}),'effective',(select amount_minor from billing.approved_session_charges where session_id='{f['session']}'));"))
        require(proof == {'money':0,'archive':1,'effective':10000}, 'revoked_actor after-wait no financial effect or actor substitution')
        print('CASE f_recon_revoked_actor_wait COMPLETE', flush=True)
    finally:
        a.close()
        b.close()


def main():
    if os.environ.get('MANUAL_FINANCIAL_DISPOSABLE_DATABASE') != 'yes':
        raise SystemExit('DISPOSABLE_LOCAL_DATABASE_OPT_IN_REQUIRED')
    endpoint = subprocess.check_output(['docker', 'context', 'inspect', '--format', '{{.Endpoints.docker.Host}}'], text=True).strip()
    if not endpoint.startswith('unix://'):
        raise SystemExit('LOCAL_DOCKER_SOCKET_REQUIRED')
    containers = subprocess.check_output(
        ['docker', 'ps', '--filter', 'name=supabase_db_', '--format', '{{.ID}}'], text=True).split()
    if len(containers) != 1:
        raise SystemExit('EXACTLY_ONE_LOCAL_SUPABASE_DB_REQUIRED')
    container = containers[0]
    setup = Connection(container)
    try:
        proof = data(setup.run("select 'DATA:'||json_build_object('db',current_database(),'user',current_user,'local',inet_server_addr() is null);"))
        require(proof == {'db': 'postgres', 'user': 'postgres', 'local': True}, 'local socket database identity')
        if os.environ.get('F_RECON_WORKER_RACE_ONLY') == 'yes':
            f_recon_worker_races(setup, container)
            return
        test = (ROOT/'supabase/tests/20261110000000_session_financial_adjustment.test.sql').read_text()
        fixture = test[test.index('create function pg_temp.sfa_fixture'):test.index('create function pg_temp.sfa_adjust')]
        setup.run(fixture)
        f = data(setup.run("begin; set local timezone='UTC'; select 'DATA:'||pg_temp.sfa_fixture(10000,0,true)::text; commit;"))
        g = data(setup.run(f"begin; set local timezone='UTC'; select 'DATA:'||pg_temp.sfa_fixture(10000,0,true,false,false,3600,'{f['tenant']}','{f['actor']}')::text; commit;"))
        cmd = str(uuid.uuid4())
        counts_sql = f"""select 'DATA:'||json_build_object(
'commands',(select count(*) from sync.processed_commands where tenant_id='{f['tenant']}' and command_id='{cmd}'),
'adjustments',(select count(*) from billing.session_financial_adjustments where tenant_id='{f['tenant']}'),
'invoice_adjustments',(select count(*) from billing.invoice_financial_adjustments x join billing.invoices i on i.id=x.invoice_id where i.tenant_id='{f['tenant']}'),
'invoices',(select count(*) from billing.invoices where tenant_id='{f['tenant']}'),
'journals',(select count(*) from finance.journal_entries where tenant_id='{f['tenant']}'),
'payments',(select count(*) from billing.payments where tenant_id='{f['tenant']}'),
'loser_adjustments',(select count(*) from billing.session_financial_adjustments where session_id='{g['session']}'));
"""
        before = data(setup.run(counts_sql))
        a, b = Connection(container), Connection(container)
        try:
            request = lambda row, amount: f"api.adjust_session_financial_amount('{row['session']}','{cmd}',0,0,0,{amount},'concurrency reason','{row['posting']}')"
            prefix = f"begin; set local timezone='UTC'; select set_config('request.jwt.claim.sub','{f['actor']}',true);"
            winner = data(a.run(prefix+f"select 'DATA:'||({request(f,8500)})::text;"))
            require(winner['status']=='accepted', 'cross_well winner accepted before commit barrier')
            require(data(setup.run(f"select 'DATA:'||to_json(not exists(select 1 from sync.processed_commands where tenant_id='{f['tenant']}' and command_id='{cmd}'));")), 'cross_well uncommitted reservation absent to independent reader')
            b.send(prefix+f"select 'DATA:'||({request(g,9000)})::text; commit;\n\\echo CROSS_WELL_DONE")
            waited = False
            for _ in range(40):
                proof = data(setup.run(f"""select 'DATA:'||json_build_object(
'blocked',{a.pid}=any(pg_blocking_pids({b.pid})),
'reservation_wait',exists(select 1 from pg_locks waiting join pg_locks held
 on held.locktype=waiting.locktype and held.transactionid=waiting.transactionid
 where waiting.pid={b.pid} and not waiting.granted and waiting.locktype='transactionid' and held.pid={a.pid} and held.granted),
'well_lock_granted',exists(select 1 from pg_locks where pid={b.pid} and locktype='advisory' and granted),
'no_well_lock_wait',not exists(select 1 from pg_locks where pid={b.pid} and locktype='advisory' and not granted));"""))
                if all(proof.values()):
                    waited = True
                    break
                time.sleep(0.05)
            require(waited, 'cross_well real command reservation transaction wait not well-root wait')
            a.run('commit;')
            loser = data(b.until('CROSS_WELL_DONE'))
            require(loser == {'contract':'session_financial_adjustment','version':1,'status':'conflict_request',
                             'session_id':g['session'],'command_id':cmd,'retry_authorized':False},
                    'cross_well loser typed conflict_request without winner financial disclosure')
            after = data(setup.run(counts_sql))
            require(after == {**before, 'commands':before['commands']+1, 'adjustments':before['adjustments']+1,
                              'invoice_adjustments':before['invoice_adjustments']+1, 'journals':before['journals']+1},
                    'cross_well exactly one command adjustment and journal no second invoice or payment')
            replay = data(setup.run(prefix+f"select 'DATA:'||({request(f,8500)})::text; commit;"))
            require(replay == winner, 'cross_well winner exact replay retains original stored result')
            require(data(setup.run(counts_sql)) == after, 'cross_well replay adds no economic effect')
            print('CASE cross_well_command COMPLETE', flush=True)
        finally:
            a.close()
            b.close()
        scenarios = [] if os.environ.get('SFA_COMMAND_RACE_ONLY') == 'yes' else ['adjustment', 'payment', 'time', 'period', 'distribution', 'invoice_first', 'adjustment_first']
        for scenario in scenarios:
            f = data(setup.run("begin; set local timezone='UTC'; select 'DATA:'||pg_temp.sfa_fixture()::text; commit;"))
            w, sid, actor = f['well'], f['session'], f['actor']
            # Owner authority permits period closing; manual adjustment still uses its permission.
            setup.run(f"begin; select set_config('request.jwt.claim.sub','{actor}',true); select billing.enter_financial_write('{w}'); update core.well_assignments set role='owner' where well_id='{w}' and profile_id='{actor}'; commit;")
            adj = lambda amount, cmd: f"api.adjust_session_financial_amount('{sid}','{cmd}',0,0,0,{amount},'concurrency reason','{f['posting']}')"
            first = adj(8500, uuid.uuid4())
            second = adj(9000, uuid.uuid4())
            if scenario == 'payment':
                second = f"api.record_payment(p_well_id=>'{w}',p_farmer_well_account_id=>'{f['account']}',p_amount_minor=>4000,p_method=>'cash',p_session_charge_id=>'{f['charge']}',p_command_id=>'{uuid.uuid4()}')"
            elif scenario == 'time':
                second = f"api.correct_irrigation_session('{sid}','{uuid.uuid4()}',0,'time correction','{f['at']}',('{f['at']}'::timestamptz+interval '11000 seconds'),'{f['posting']}')"
            elif scenario == 'period':
                first = f"to_jsonb(finance.close_period((select id from finance.accounting_periods where well_id='{w}' and period_type='monthly' and current_date between starts_at and ends_at),'{actor}'))"
            elif scenario == 'invoice_first':
                first = f"api.issue_session_invoice_result('{sid}')"
            elif scenario == 'adjustment_first':
                second = f"api.issue_session_invoice_result('{sid}')"
            if scenario == 'distribution':
                cycle = data(setup.run(f"""begin; select set_config('request.jwt.claim.sub','{actor}',true);
select billing.enter_financial_write('{w}');
insert into core.well_partners(tenant_id,well_id,person_id,phone,period_start)
select '{f['tenant']}','{w}',fp.person_id,'777777777','1970-01-01'
from ops.farmer_well_accounts fa join ops.farmer_profiles fp on fp.id=fa.farmer_profile_id where fa.id='{f['account']}';
insert into core.ownership_share_versions(tenant_id,well_id,partner_id,ownership_percentage,profit_percentage,effective_period)
select '{f['tenant']}','{w}',id,100,100,daterange('1970-01-01',null,'[)') from core.well_partners where well_id='{w}';
select api.set_partner_irrigation_policy((select id from core.well_partners where well_id='{w}'),'deduct_from_profit');
select api.issue_session_invoice('{sid}');
select finance.record_expense('{w}',(select code from finance.expense_categories where tenant_id='{f['tenant']}' order by id limit 1),20000,'concurrency expense','{actor}',null,true,'partner_paid',null,(select id from core.well_partners where well_id='{w}'),'source proof');
select 'DATA:'||to_json(finance.calculate_profit_distribution('{w}',('{f['at']}'::timestamptz-interval '1 hour'),clock_timestamp()+interval '1 hour','{actor}',0));
commit;"""))
                first = f"to_jsonb(finance.approve_profit_distribution('{cycle}','{actor}'))"
            a, b = Connection(container), Connection(container)
            try:
                prefix = f"begin; set local timezone='UTC'; select set_config('request.jwt.claim.sub','{actor}',true);"
                a.run(prefix+f"select billing.enter_financial_write('{w}');")
                b.send(prefix+f"select 'DATA:'||({second})::text; commit;\n\\echo SECOND_DONE")
                waited = False
                for _ in range(40):
                    v = data(setup.run(f"select 'DATA:'||to_json({a.pid}=any(pg_blocking_pids({b.pid})));"))
                    if v:
                        waited = True
                        break
                    time.sleep(0.05)
                require(waited, scenario+' real serialization contention')
                a.run(f"select 'DATA:'||coalesce(({first})::text,'null'); commit;")
                result = data(b.until('SECOND_DONE'))
                if scenario == 'adjustment':
                    require(result['status']=='conflict_revision', 'second adjustment stale base rejected')
                elif scenario == 'period':
                    require(result['status']=='financial_review_required', 'period closure prevents economic publication')
                elif scenario == 'distribution':
                    require(result['status']=='locked', 'finalized distribution blocks adjustment without mutation')
                elif scenario in ('invoice_first', 'adjustment_first'):
                    require(result['status'] in ('accepted', 'issued'), scenario+' canonical success')
                    proof = data(setup.run(f"begin; select set_config('request.jwt.claim.sub','{actor}',true); select 'DATA:'||json_build_object('effective',(select amount_minor from billing.approved_session_charges where session_id='{sid}'),'invoice',(select total_minor from billing.effective_invoice_totals where session_id='{sid}'),'carry',(select count(*) from billing.invoice_lines l join billing.invoices i on i.id=l.invoice_id where i.session_id='{sid}' and l.line_type='manual_adjustment'),'post',(select count(*) from billing.invoice_financial_adjustments x join billing.invoices i on i.id=x.invoice_id where i.session_id='{sid}')); commit;"))
                    expected = 9000 if scenario == 'invoice_first' else 8500
                    require(proof['effective']==expected and proof['invoice']==expected and proof['carry']+proof['post']==1, scenario+' exactly one economic path')
                elif scenario == 'payment':
                    proof = data(setup.run(f"begin; select set_config('request.jwt.claim.sub','{actor}',true); select 'DATA:'||api.get_session_financial_state('{sid}')::text; commit;"))
                    require(proof['effective_amount_minor']==8500 and proof['paid_amount_minor']==4000 and proof['outstanding_amount_minor']==4500, 'concurrent payment preserves exact legal debt')
                elif scenario == 'time':
                    correction = result['correction_id']
                    reviewed = data(setup.run(f"begin; select set_config('request.jwt.claim.sub','{actor}',true); select 'DATA:'||billing.reconcile_session_correction('{correction}','{uuid.uuid4()}','{f['posting']}')::text; commit;"))
                    require(reviewed['status']=='financial_review_required' and reviewed['review_code']=='manual_approval_reconciliation_required', 'concurrent time correction cannot overwrite approval')
                else:
                    require(result.get('status','accepted')=='accepted', scenario+' existing path succeeds')
                print('CASE '+scenario+' COMPLETE', flush=True)
            finally:
                a.close()
                b.close()
    finally:
        setup.close()
        print('RESET_REQUIRED: committed disposable fixtures remain', flush=True)


if __name__ == '__main__':
    main()
