#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P2 Phase 1: إثبات تزامن المدخل الآلي عبر اتصالين مستقلين."""

import os
import sys
import threading
import uuid

import psycopg2

import p1b_transition_concurrency_proof as p1


def fail(message):
    print("FAIL: %s" % message)
    raise SystemExit(1)


def ok(message):
    print("PASS: %s" % message)


def setup(dsn, tag):
    conn = p1.connect(dsn)
    try:
        with conn.cursor() as cur:
            fx = p1.setup_scenario(cur, tag)
            # الشخص نفسه قد يحمل دور المالك والمشغل؛ هوية المشغل الميداني
            # تبقى تعيين operator المربوط بحالة ON.
            cur.execute(
                "insert into core.well_assignments"
                " (well_id, profile_id, role, status)"
                " values (%s, %s, 'owner', 'active')",
                (fx["well_id"], fx["op_id"]),
            )
            cur.execute(
                "update ops.booking_automation_control"
                " set execution_enabled = true,"
                " policy_version = policy_version + 1,"
                " updated_at = clock_timestamp()"
                " where control_key = 'global'"
            )
            cur.execute(
                "select ws.booking_auto_transition_revision,"
                " ctl.policy_version, wa.id, wa.authorization_revision"
                " from core.well_settings ws"
                " cross join ops.booking_automation_control ctl"
                " join core.well_assignments wa"
                " on wa.id = ws.booking_auto_transition_operator_assignment_id"
                " where ws.well_id = %s and ctl.control_key = 'global'",
                (fx["well_id"],),
            )
            auto_revision, policy_version, assignment_id, auth_revision = (
                cur.fetchone()
            )
            fx.update(
                {
                    "automation_revision": auto_revision,
                    "policy_version": policy_version,
                    "assignment_id": assignment_id,
                    "authorization_revision": auth_revision,
                }
            )
        conn.commit()
        return fx
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def call(cur, fx, command_id, attempt_id, run_id):
    cur.execute("set local role booking_automation_executor")
    cur.execute(
        "select ops.execute_booking_transition_automation("
        "%s,%s,%s,%s,0,%s,%s,%s,%s,%s)",
        (
            fx["well_id"],
            fx["chain_id"],
            fx["session_id"],
            fx["booking_b"],
            fx["automation_revision"],
            fx["policy_version"],
            command_id,
            attempt_id,
            run_id,
        ),
    )
    return cur.fetchone()[0]


def verify_effect(dsn, fx, command_ids, expected_rows):
    conn = p1.connect(dsn)
    try:
        with conn.cursor() as cur:
            cur.execute(
                "select"
                " (select count(*) from billing.session_charges"
                "  where session_id = %s),"
                " (select count(*) from ops.irrigation_sessions"
                "  where booking_id = %s),"
                " (select count(*) from audit.booking_automation_attempts"
                "  where command_id = any(%s::uuid[])),"
                " (select count(*) from sync.processed_commands"
                "  where command_id = any(%s::uuid[]))",
                (
                    fx["session_id"],
                    fx["booking_b"],
                    command_ids,
                    command_ids,
                ),
            )
            charges, sessions, attempts, commands = cur.fetchone()
        if (charges, sessions, attempts, commands) != (
            1,
            1,
            2,
            expected_rows,
        ):
            fail(
                "أثر غير صحيح: رسوم=%d جلسات=%d محاولات=%d أوامر=%d"
                % (charges, sessions, attempts, commands)
            )
    finally:
        conn.rollback()
        conn.close()


def run_race(dsn, fx, command_a, command_b, label, expected_rows):
    c1 = p1.connect(dsn)
    c2 = p1.connect(dsn)
    try:
        with c1.cursor() as cur:
            cur.execute("select pg_backend_pid()")
            pid1 = cur.fetchone()[0]
            receipt1 = call(
                cur, fx, command_a, str(uuid.uuid4()), str(uuid.uuid4())
            )

        with c2.cursor() as cur:
            cur.execute("select pg_backend_pid()")
            pid2 = cur.fetchone()[0]

        outcome = {}

        def runner():
            try:
                with c2.cursor() as cur:
                    outcome["receipt"] = call(
                        cur,
                        fx,
                        command_b,
                        str(uuid.uuid4()),
                        str(uuid.uuid4()),
                    )
                c2.commit()
            except Exception as exc:  # noqa: BLE001
                c2.rollback()
                outcome["error"] = str(exc)

        thread = threading.Thread(target=runner)
        thread.start()
        watcher_conn = p1.connect(dsn)
        with watcher_conn.cursor() as watcher:
            blocked = p1.wait_until_blocked(watcher, pid2, pid1, thread)
        watcher_conn.rollback()
        watcher_conn.close()
        if not blocked:
            c1.rollback()
            thread.join(timeout=10)
            fail("%s: لم يُرصد حجب المحاولة الثانية" % label)
        ok("%s: المحاولة الثانية حُجبت على قفل النية" % label)

        c1.commit()
        thread.join(timeout=30)
        if thread.is_alive():
            fail("%s: المحاولة الثانية لم تنته بعد الإيداع" % label)
        if outcome.get("error"):
            fail("%s: %s" % (label, outcome["error"][:240]))

        receipt2 = outcome.get("receipt")
        if receipt1.get("result") != "accepted":
            fail("%s: المحاولة الأولى لم تُقبل" % label)
        if receipt2 is None or receipt2.get("result") != "replayed":
            fail("%s: المحاولة الثانية لم تعد الإقرار" % label)
        if receipt1.get("business_receipt") != receipt2.get("business_receipt"):
            fail("%s: الإقراران لا يحملان إيصال الأعمال نفسه" % label)

        verify_effect(dsn, fx, [command_a, command_b], expected_rows)
        ok("%s: أثر أعمال واحد وإقراران متطابقان" % label)
    finally:
        c1.close()
        c2.close()


def cleanup(dsn, fx):
    conn = p1.connect(dsn)
    try:
        p1.cleanup(conn, fx)
    finally:
        conn.close()


def main():
    dsn = os.environ.get("DATABASE_URL") or os.environ.get("WI_TEST_DB_URL")
    if not dsn:
        fail("اضبط DATABASE_URL لقاعدة Supabase المحلية")

    run_tag = uuid.uuid4().hex[:8]
    fx_same = setup(dsn, "P2-SAME-" + run_tag)
    same_command = str(uuid.uuid4())
    try:
        run_race(
            dsn,
            fx_same,
            same_command,
            same_command,
            "نفس command_id",
            1,
        )
    finally:
        cleanup(dsn, fx_same)

    fx_distinct = setup(dsn, "P2-INTENT-" + run_tag)
    command_a = str(uuid.uuid4())
    command_b = str(uuid.uuid4())
    try:
        run_race(
            dsn,
            fx_distinct,
            command_a,
            command_b,
            "معرفان لنفس النية",
            2,
        )
    finally:
        cleanup(dsn, fx_distinct)

    print("CONCURRENCY PROOF SUCCESS")


if __name__ == "__main__":
    main()
