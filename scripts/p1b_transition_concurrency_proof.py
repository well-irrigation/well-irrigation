#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
P1-B — إثبات تزامن نواة الانتقال الذرية باتصالَي PostgreSQL مستقلين.

ق-134 §1 / الثوابت 748–753 و761–764. هذا المصنّ لا يُشغَّل في db:test:
يشغّله المالك يدويًا على قاعدة محلية بعد db:reset، ولا يُشغِّل Docker
أو القاعدة بنفسه. يقبل رابط الاتصال من البيئة:

    DATABASE_URL="postgresql://..." python3 scripts/p1b_transition_concurrency_proof.py

لا يطبع كلمة المرور ولا رابط اتصال غير مُقنَّع في أي مخرَج.

ما يُثبته (سلوك حقيقي عبر اتصالين لا داخل DO واحد):

  السيناريو أ — سباق أمرين مختلفين على الانتقال نفسه:
    اتصال يفتح معاملة وينفّذ النواة (يحمل أقفال settings/session/chain
    بلا إيداع)، وثانٍ ينفّذ بأمر مختلف فيتحجب فعليًا (يُرصد في
    pg_stat_activity عبر wait_event_type='Lock')، وبعد إيداع الأول
    يستأنف فيرفض رفضًا نظيفًا لأن الحالة تغيّرت تحته. النتيجة: تنفيذ
    واحد حصرًا، ولا رسوم مكررة، ولا جلسة ثانية، ودفتر أوامر نظيف.

  السيناريو ب — سباق الأمر نفسه (نفس command_id):
    تنفيذ واحد يقبَل والثاني يتحجب على قيد فريدية سجل الأمر ثم — بعد
    إيداع الأول ومحاولة واحدة — يعيد الرد المخزَّن حرفيًا (دورة
    sync القائمة). النتيجة: ردّان متطابقان وأثر واحد وسجل واحد.

التنظيف: تُحذف بيانات السيناريو التشغيلية بترتيب تبعيات المفاتيح
الأجنبية. تبقى قشور الجهة والبئر والهوية التي تسند سجل التدقيق
الإضافي فقط؛ لكل تشغيل وسم فريد فلا تمنع إعادة التشغيل.

الخروج: كود 0 عند نجاح كل التوكيدات، و1 مع رسالة عربية عند أول فشل.
"""

import os
import sys
import threading
import time
import uuid

import psycopg2
from psycopg2.extras import Json

BLOCK_POLL_SECONDS = 90.0
BLOCK_POLL_INTERVAL = 0.1


def fail(msg):
    print("FAIL: %s" % msg)
    sys.exit(1)


def ok(msg):
    print("PASS: %s" % msg)


def connect(dsn):
    conn = psycopg2.connect(dsn, application_name="p1b-concurrency-proof")
    conn.autocommit = False
    return conn


def set_claim(cur, profile_id):
    cur.execute("select set_config('request.jwt.claim.sub', %s, false)",
                (str(profile_id),))


def fetch_one(cur, sql, args=()):
    cur.execute(sql, args)
    row = cur.fetchone()
    if row is None:
        fail("استعلام التجهيز أعاد لا شيء: %s" % sql)
    return row[0]


def preclean(conn):
    """تنظيف بقايا السيناريوهات القديمة مع حفظ مراجع سجل التدقيق."""
    with conn.cursor() as cur:
        cur.execute("select id from core.tenants"
                    " where name like 'جهة إثبات تزامن P1-B %'")
        for (tenant_id,) in cur.fetchall():
            clean_tenant(cur, tenant_id)
    conn.commit()


def clean_tenant(cur, tenant_id):
    """احذف أبناء الجلسة والحجز فقط؛ audit يحتفظ بالجهة والبئر والمستخدم."""
    sessions = ("select s.id from ops.irrigation_sessions s"
                " join core.wells w on w.id = s.well_id"
                " where w.tenant_id = %s")
    cur.execute("delete from billing.session_charges"
                " where session_id in (" + sessions + ")", (tenant_id,))
    cur.execute("delete from ops.session_segments"
                " where session_id in (" + sessions + ")", (tenant_id,))
    cur.execute("delete from ops.session_crops"
                " where session_id in (" + sessions + ")", (tenant_id,))
    cur.execute("delete from ops.booking_transition_decisions"
                " where tenant_id = %s", (tenant_id,))
    cur.execute("delete from ops.booking_transition_chains"
                " where tenant_id = %s", (tenant_id,))
    cur.execute("delete from ops.irrigation_sessions"
                " where id in (" + sessions + ")", (tenant_id,))
    cur.execute("delete from ops.booking_status_history"
                " where tenant_id = %s", (tenant_id,))
    cur.execute("delete from ops.irrigation_bookings"
                " where tenant_id = %s", (tenant_id,))
    cur.execute("delete from sync.processed_commands"
                " where tenant_id = %s", (tenant_id,))


def setup_scenario(cur, tag):
    """تجهيز بئر كامل: سلسلة مسلّحة بجلسة محجوزة بلغت حدها + تالٍ مستحق."""
    tenant_id = fetch_one(
        cur, "insert into core.tenants (name) values (%s) returning id",
        ("جهة إثبات تزامن P1-B %s" % tag,))
    person_id = fetch_one(
        cur,
        "insert into core.persons (tenant_id, full_name, normalized_name)"
        " values (%s, %s, %s) returning id",
        (tenant_id, "مزارع إثبات", "مزارع إثبات"))
    fprofile_id = fetch_one(
        cur, "insert into ops.farmer_profiles (tenant_id, person_id)"
             " values (%s, %s) returning id", (tenant_id, person_id))

    fx = {"tenant_id": tenant_id}
    for email, full_name in (
        ("op-%s@concurrency-pb.local" % tag, "مشغل إثبات"),
    ):
        # UUID صريح فريد لكل مستخدم؛ لا نحذف ملفًا قد يسنده سجل تدقيق.
        user_id = uuid.uuid4()
        cur.execute("insert into auth.users (id, instance_id, aud, role, email,"
                    " encrypted_password, email_confirmed_at, created_at, updated_at,"
                    " raw_user_meta_data)"
                    " values (%s, '00000000-0000-0000-0000-000000000000',"
                    " 'authenticated', 'authenticated', %s, crypt('x', gen_salt('bf')),"
                    " now(), now(), now(), %s)",
                    (str(user_id), email, Json({"full_name": full_name})))
        # زناد 018 ينشئ البروفايل من بيانات Auth دون إدخال يدوي مكرر.
        profile_name = fetch_one(
            cur, "select full_name from iam.profiles where id = %s",
            (str(user_id),))
        if profile_name != full_name:
            fail("زناد إنشاء ملف المشغل لم يحفظ الاسم المتوقع")
        fx["op_id"] = str(user_id)
    op_id = fx["op_id"]

    well_id = fetch_one(
        cur, "insert into core.wells (tenant_id, name) values (%s, %s) returning id",
        (tenant_id, "بئر إثبات %s" % tag))
    cur.execute(
        "insert into core.well_assignments (well_id, profile_id, role, status)"
        " values (%s, %s, 'operator', 'active')", (well_id, op_id))
    acc_id = fetch_one(
        cur,
        "insert into ops.farmer_well_accounts (tenant_id, farmer_profile_id,"
        " well_id, public_code) values (%s, %s, %s, %s) returning id",
        (tenant_id, fprofile_id, well_id, "FWA-CONC-%s" % tag))
    farm_id = fetch_one(
        cur, "insert into ops.farms (well_id, name, farmer_well_account_id)"
             " values (%s, %s, %s) returning id",
        (well_id, "أرض إثبات %s" % tag, acc_id))
    fetch_one(
        cur, "insert into core.pumps (well_id, name, power_source, status)"
             " values (%s, %s, 'diesel', 'active') returning id",
        (well_id, "مضخة إثبات %s" % tag))
    cur.execute(
        "insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)"
        " values (%s, 5000, date '2026-01-01')", (well_id,))

    booking_a = fetch_one(
        cur,
        "insert into ops.irrigation_bookings (tenant_id, public_code, well_id,"
        " farmer_well_account_id, farm_id, scheduled_start, scheduled_end,"
        " expected_duration_minutes, expected_energy_source, status)"
        " values (%s, %s, %s, %s, %s,"
        " now() - interval '150 minutes', now() - interval '30 minutes',"
        " 120, 'well_diesel', 'confirmed') returning id",
        (tenant_id, "BKG-CONC-A-%s" % tag, well_id, acc_id, farm_id))
    booking_b = fetch_one(
        cur,
        "insert into ops.irrigation_bookings (tenant_id, public_code, well_id,"
        " farmer_well_account_id, farm_id, scheduled_start, scheduled_end,"
        " expected_duration_minutes, expected_energy_source, status)"
        " values (%s, %s, %s, %s, %s,"
        " now() - interval '5 minutes', now() + interval '55 minutes',"
        " 60, 'well_diesel', 'confirmed') returning id",
        (tenant_id, "BKG-CONC-B-%s" % tag, well_id, acc_id, farm_id))

    # تفعيل الإعداد بيد المشغل المخول عبر عقد P1-A — تغيير الإعداد
    # قرار المشغل على هاتف التشغيل (المالك مؤجل إلى P7).
    set_claim(cur, op_id)
    cur.execute("select api.set_well_booking_automation(%s, %s, %s, %s)",
                (well_id, True, 0, str(uuid.uuid4())))
    set_claim(cur, op_id)

    # بدء الجلسة المحجوزة بزمن ماضٍ فعلي: بلغت حدها الموثوق (748).
    started = fetch_one(
        cur, "select ops.start_booking_session_core(%s, %s,"
             " now() - interval '130 minutes')", (booking_a, op_id))
    chain_id = fetch_one(
        cur, "select id from ops.booking_transition_chains where well_id = %s"
             " and status <> 'ended'", (well_id,))
    fx.update({"well_id": well_id, "booking_b": booking_b,
               "session_id": started["session_id"], "chain_id": chain_id})
    return fx


def cleanup(conn, fx):
    """تنظيف بيانات السيناريو التشغيلية؛ تبقى مراجع audit الضرورية."""
    with conn.cursor() as cur:
        clean_tenant(cur, fx["tenant_id"])
    conn.commit()


def final_counts(cur, tenant_id):
    cur.execute(
        "select"
        " (select count(*) from billing.session_charges sc"
        "  join ops.irrigation_sessions s on s.id = sc.session_id"
        "  where s.well_id in (select id from core.wells"
        "  where tenant_id = %s)),"
        " (select count(*) from ops.irrigation_sessions s"
        "  where s.well_id in (select id from core.wells"
        "  where tenant_id = %s) and s.status = 'open'),"
        " (select count(*) from ops.irrigation_sessions s"
        "  where s.well_id in (select id from core.wells"
        "  where tenant_id = %s) and s.booking_id is not null)",
        (tenant_id, tenant_id, tenant_id))
    return cur.fetchone()


def wait_until_blocked(watcher, blocked_pid, blocker_pid, thread):
    """رصد حجب فعلي لاتصال الثاني على قفل الانتقال الأول (دليل تزامن).
    pg_blocking_pids يربط الحجب بالاتصال الأول، وpg_locks يثبت
    وجود قفل غير ممنوح للاتصال الثاني."""
    deadline = time.monotonic() + BLOCK_POLL_SECONDS
    while time.monotonic() < deadline:
        watcher.execute(
            "select exists ("
            "  select 1 from pg_stat_activity a"
            "  where a.pid = %s and %s = any(pg_blocking_pids(a.pid)))"
            " and exists ("
            "  select 1 from pg_locks l"
            "  where l.pid = %s and not l.granted)",
            (blocked_pid, blocker_pid, blocked_pid))
        if watcher.fetchone()[0]:
            return True
        if not thread.is_alive():
            return False
        time.sleep(BLOCK_POLL_INTERVAL)
    return False


def call_transition(cur, well_id, expected_revision, command_id):
    """تنفيذ النواة داخل معاملة الاتصال الحالي؛ (نجاح، رد/رسالة الخطأ)."""
    try:
        cur.execute("select ops.execute_booking_transition(%s, %s, %s)",
                    (well_id, expected_revision, command_id))
        return True, cur.fetchone()[0]
    except psycopg2.Error as exc:
        conn = cur.connection
        conn.rollback()
        return False, exc.diag.message_primary or ""


def scenario_a(dsn, tag):
    """سباق أمرين مختلفين: تنفيذ واحد والآخر يُرفض رفضًا نظيفًا."""
    setup_conn = connect(dsn)
    fx = None
    try:
        with setup_conn.cursor() as cur:
            fx = setup_scenario(cur, tag)
        setup_conn.commit()
    except Exception:
        setup_conn.rollback()
        if fx:
            cleanup(setup_conn, fx)
        setup_conn.close()
        raise
    setup_conn.close()

    c1 = connect(dsn)
    c2 = connect(dsn)
    try:
        with c2.cursor() as cur:
            cur.execute("select pg_backend_pid()")
            c2_pid = cur.fetchone()[0]
        with c1.cursor() as cur:
            cur.execute("select pg_backend_pid()")
            c1_pid = cur.fetchone()[0]

        cmd1 = str(uuid.uuid4())
        cmd2 = str(uuid.uuid4())

        set_claim(c1.cursor(), fx["op_id"])
        cur1 = c1.cursor()
        cur1.execute("select ops.execute_booking_transition(%s, %s, %s)",
                     (fx["well_id"], 0, cmd1))
        res_c1 = cur1.fetchone()[0]  # ناجح وغير مودَع: يحمل الأقفال

        outcome_c2 = {}

        def runner():
            try:
                set_claim(c2.cursor(), fx["op_id"])
                cur2 = c2.cursor()
                outcome_c2["outcome"] = call_transition(cur2, fx["well_id"], 0, cmd2)
            except Exception as exc:  # noqa: BLE001 — يُبلَّغ ويُقيَّم كفشل
                outcome_c2["error"] = str(exc)

        t = threading.Thread(target=runner)
        t.start()
        watcher_conn = connect(dsn)
        with watcher_conn.cursor() as watcher:
            blocked = wait_until_blocked(watcher, c2_pid, c1_pid, t)
        watcher_conn.rollback()
        watcher_conn.close()
        if not blocked:
            c1.rollback()
            t.join(timeout=10)
            fail("الاتصال الثاني لم يُحجب فعليًا على الأقفال — لا برهان تزامن")
        ok("الاتصال الثاني حُجب فعليًا على أقفال الانتقال الأول")
        c1.commit()
        t.join(timeout=30)
        if t.is_alive():
            fail("الاتصال الثاني لم ينتهِ بعد إيداع الأول")

        if outcome_c2.get("error"):
            fail("خطأ غير متوقع في الاتصال الثاني: %s" % outcome_c2["error"][:200])
        ok_c2, res_c2 = outcome_c2.get("outcome", (False, "لا رد"))
        if ok_c2:
            fail("الاتصال الثاني نجح رغم سبق الأول — تنفيذ مزدوج!")
        if "current_not_reached_operational_end" not in res_c2:
            fail("رفض الاتصال الثاني غير نظيف أو غير متوقع: %s" % res_c2[:200])
        ok("الاتصال الثاني استأنف بعد الإيداع ورُفض رفضًا نظيفًا لأن الحالة تغيّرت تحته")

        check = connect(dsn)
        with check.cursor() as cur:
            charges, open_sessions, booked_sessions = final_counts(cur, fx["tenant_id"])
            cur.execute("select status from ops.booking_transition_chains where id = %s",
                        (fx["chain_id"],))
            chain_status = cur.fetchone()[0]
            cur.execute("select count(*) from sync.processed_commands"
                        " where command_id = %s and status = 'accepted'", (cmd1,))
            cmd1_accepted = cur.fetchone()[0]
            cur.execute("select count(*) from sync.processed_commands where command_id = %s",
                        (cmd2,))
            cmd2_rows = cur.fetchone()[0]
        check.rollback()
        check.close()

        if (charges, open_sessions, booked_sessions) != (1, 1, 2):
            fail("الأثر النهائي غير صحيح: رسوم=%d مفتوحة=%d محجوزة=%d"
                 % (charges, open_sessions, booked_sessions))
        if chain_status != "active":
            fail("حالة السلسلة النهائية غير صحيحة: %s" % chain_status)
        if cmd1_accepted != 1 or cmd2_rows != 0:
            fail("دفتر الأوامر غير متسق: المقبول=%d وبقايا المرفوض=%d"
                 % (cmd1_accepted, cmd2_rows))
        ok("السيناريو أ: تنفيذ واحد حصرًا ورفض نظيف وأثر نهائي سليم ودفتر أوامر نظيف")
    finally:
        c1.close()
        c2.close()
        cleanup_conn = connect(dsn)
        cleanup(cleanup_conn, fx)
        cleanup_conn.close()


def scenario_b(dsn, tag):
    """سباق الأمر نفسه: تنفيذ واحد وردّان متطابقان (إعادة الرد المخزَّن)."""
    setup_conn = connect(dsn)
    fx = None
    try:
        with setup_conn.cursor() as cur:
            fx = setup_scenario(cur, tag)
        setup_conn.commit()
    except Exception:
        setup_conn.rollback()
        if fx:
            cleanup(setup_conn, fx)
        setup_conn.close()
        raise
    setup_conn.close()

    same_cmd = str(uuid.uuid4())
    c1 = connect(dsn)
    c2 = connect(dsn)
    try:
        with c1.cursor() as cur:
            cur.execute("select pg_backend_pid()")
            c1_pid = cur.fetchone()[0]
        with c2.cursor() as cur:
            cur.execute("select pg_backend_pid()")
            c2_pid = cur.fetchone()[0]
        set_claim(c1.cursor(), fx["op_id"])
        cur1 = c1.cursor()
        cur1.execute("select ops.execute_booking_transition(%s, %s, %s)",
                     (fx["well_id"], 0, same_cmd))
        res_c1 = cur1.fetchone()[0]  # ناجح وغير مودَع

        outcome_c2 = {}

        def runner():
            try:
                cur2 = c2.cursor()
                # محاولة أولى تتحجب على قيد فريدية سجل الأمر حتى إيداع
                # الأول، فتراجع ثم تعيد فترى الصف المودَع فتعيد الرد
                # المخزَّن حرفيًا (دورة sync القائمة).
                for attempt in range(3):
                    # psycopg2 يفتح معاملة جديدة ضمنيًا بعد كل rollback.
                    c2.rollback()
                    cur2.execute("set local statement_timeout = '180s'")
                    set_claim(cur2, fx["op_id"])
                    outcome = call_transition(cur2, fx["well_id"], 0, same_cmd)
                    if outcome[0]:
                        outcome_c2["outcome"] = outcome
                        break
                    outcome_c2["outcome"] = outcome
                    if attempt < 2 and "duplicate key" in outcome[1]:
                        time.sleep(0.2)
                        continue
                    break
            except Exception as exc:  # noqa: BLE001
                outcome_c2["error"] = str(exc)

        t = threading.Thread(target=runner)
        t.start()
        watcher_conn = connect(dsn)
        with watcher_conn.cursor() as watcher:
            blocked = wait_until_blocked(watcher, c2_pid, c1_pid, t)
        watcher_conn.rollback()
        watcher_conn.close()
        if not blocked:
            c1.rollback()
            t.join(timeout=10)
            fail("السيناريو ب: لم يُرصد حجب الاتصال الثاني على الأمر نفسه")
        ok("السيناريو ب: الاتصال الثاني حُجب فعليًا قبل إيداع الأول")
        c1.commit()
        t.join(timeout=30)
        if t.is_alive():
            fail("السيناريو ب: الاتصال الثاني لم ينتهِ بعد إيداع الأول")

        if outcome_c2.get("error"):
            fail("خطأ غير متوقع في الاتصال الثاني: %s" % outcome_c2["error"][:200])
        ok_c2, res_c2 = outcome_c2.get("outcome", (False, "لا رد"))
        if not ok_c2:
            fail("الاتصال الثاني لم يعُد الرد المخزَّن: %s" % res_c2[:200])
        if res_c1 != res_c2:
            fail("ردّا الاتصالين غير متطابقين — إعادة الرد المخزَّن مكسورة")
        ok("الاتصالان أعادا الرد المخزَّن نفسه حرفيًا")

        check = connect(dsn)
        with check.cursor() as cur:
            charges, open_sessions, booked_sessions = final_counts(cur, fx["tenant_id"])
            cur.execute("select status, command_type, request_payload, response_payload"
                        " from sync.processed_commands where command_id = %s",
                        (same_cmd,))
            commands = cur.fetchall()
        check.rollback()
        check.close()

        if (charges, open_sessions, booked_sessions) != (1, 1, 2):
            fail("الأثر النهائي في السيناريو ب غير صحيح: رسوم=%d مفتوحة=%d محجوزة=%d"
                 % (charges, open_sessions, booked_sessions))
        if len(commands) != 1:
            fail("أمر واحد سُجّل %d مرة — الإيديمبوتنس مكسورة" % len(commands))
        status, command_type, payload, stored_response = commands[0]
        expected_payload = {
            "booking_execution_contract_version": 113,
            "well_id": str(fx["well_id"]),
            "expected_revision": 0,
        }
        if (status != "accepted" or command_type != "execute_booking_transition"
                or payload != expected_payload or stored_response != res_c1):
            fail("سجل الأمر لا يطابق الحالة أو الحمولة أو الرد المخزَّن")
        ok("السيناريو ب: أثر واحد وردّان متطابقان وسجل أمر واحد")
    finally:
        c1.close()
        c2.close()
        cleanup_conn = connect(dsn)
        cleanup(cleanup_conn, fx)
        cleanup_conn.close()


def main():
    dsn = os.environ.get("DATABASE_URL") or os.environ.get("WI_TEST_DB_URL")
    if not dsn:
        fail("اضبط DATABASE_URL (رابط قاعدة محلية بعد db:reset) ثم أعد التشغيل")
    preclean_conn = connect(dsn)
    preclean(preclean_conn)
    preclean_conn.close()
    run_tag = uuid.uuid4().hex[:8]
    scenario_a(dsn, "أ-" + run_tag)
    scenario_b(dsn, "ب-" + run_tag)
    print("CONCURRENCY PROOF SUCCESS")


if __name__ == "__main__":
    main()
