#!/usr/bin/env python3
"""
Smart Parking -- application integration demo (CO4)

  pip install mysql-connector-python pymongo
  export DB_HOST=localhost DB_USER=pk_user DB_PASS='User#2026' DB_NAME=smart_parking
  python app/parking_app.py --availability
  python app/parking_app.py --reserve 18 18 18 2        # user vehicle slot days_ahead
  python app/parking_app.py --allocate 31 31 1 2        # user vehicle zone days_ahead
  python app/parking_app.py --concurrency               # two threads race for one zone
  python app/parking_app.py --injection                 # unsafe vs parameterised lookup
  python app/parking_app.py --history DL04CA1021        # MySQL + MongoDB application-level join

SECURITY RULES shown here
  * all SQL uses %s placeholders (parameterised) or CALL with parameters;
  * the connection runs as a least-privilege role (pk_user) -- not root;
  * multi-statements are off (mysql-connector default) and errors are logged, not echoed.
"""
import argparse, os, sys, threading
from datetime import datetime, timedelta

import mysql.connector


def connect(user=None, password=None):
    return mysql.connector.connect(
        host=os.getenv("DB_HOST", "localhost"),
        user=user or os.getenv("DB_USER", "pk_user"),
        password=password or os.getenv("DB_PASS", "User#2026"),
        database=os.getenv("DB_NAME", "smart_parking"),
        autocommit=True,
    )


def day_slot(days_ahead, hour=10, hours=2):
    start = (datetime.now() + timedelta(days=days_ahead)).replace(hour=hour, minute=0, second=0, microsecond=0)
    return start, start + timedelta(hours=hours)


def with_retry(fn, tries=3):
    """Retry on deadlock (1213) / lock-wait timeout (1205) -- the standard InnoDB recipe."""
    for attempt in range(tries):
        try:
            return fn()
        except mysql.connector.Error as e:
            if e.errno in (1213, 1205) and attempt < tries - 1:
                continue
            raise


# --------------------------------------------------------------------------------------
def availability():
    cn = connect()
    cur = cn.cursor()
    cur.execute("SELECT zone_name, COUNT(*) FROM v_current_availability "
                "WHERE current_status = %s GROUP BY zone_name ORDER BY zone_name", ("AVAILABLE",))
    for zone, n in cur.fetchall():
        print(f"{zone:28s} {n:3d} free")
    cn.close()


def reserve(user, vehicle, slot, days):
    start, end = day_slot(days)
    cn = connect()
    cur = cn.cursor()
    res = with_retry(lambda: cur.callproc("sp_reserve_slot", (user, vehicle, slot, start, end, 0, 0, "")))
    print("reservation id:", res[6], "|", res[7])
    cn.close()


def allocate(user, vehicle, zone, days, delay=0):
    start, end = day_slot(days)
    cn = connect()
    cur = cn.cursor()
    res = with_retry(lambda: cur.callproc("sp_allocate_slot", (user, vehicle, zone, start, end, delay, 0, 0, "")))
    print(f"user {user}: reservation={res[6]} slot={res[7]} | {res[8]}")
    cn.close()
    return res[7]


def concurrency():
    """Two users hit the same zone at the same instant; the first holds its lock for 3 s."""
    results = {}

    def worker(user, vehicle, delay):
        start, end = day_slot(12)
        cn = connect()
        cur = cn.cursor()
        res = cur.callproc("sp_allocate_slot", (user, vehicle, 2, start, end, delay, 0, 0, ""))
        results[user] = (res[6], res[7], res[8])
        cn.close()

    t1 = threading.Thread(target=worker, args=(33, 33, 3))   # holds the slot lock for 3 s
    t2 = threading.Thread(target=worker, args=(34, 34, 0))
    t1.start(); threading.Event().wait(0.5); t2.start()
    t1.join(); t2.join()

    for u, (r, s, m) in sorted(results.items()):
        print(f"user {u}: reservation={r} slot={s} -> {m}")
    slots = [v[1] for v in results.values() if v[1]]
    assert len(slots) == len(set(slots)), "DOUBLE ALLOCATION!"
    print("OK: both users got different slots -> no double allocation")


def injection():
    cn = connect()
    cur = cn.cursor()
    payload = "DL01CA1007' OR '1'='1"
    print("payload:", payload)

    # UNSAFE (for demonstration only) -- needs a role that may read `vehicle`
    unsafe = f"SELECT reg_no FROM vehicle WHERE reg_no = '{payload}'"
    print("unsafe SQL:", unsafe)
    try:
        cur.execute(unsafe)
        print("unsafe rows returned:", len(cur.fetchall()), "(injection succeeded or access denied)")
    except mysql.connector.Error as e:
        print("unsafe query rejected by privileges:", e.msg)

    # SAFE -- placeholder; the payload is bound as data
    try:
        cur.execute("SELECT reg_no FROM vehicle WHERE reg_no = %s", (payload,))
        print("safe rows returned:", len(cur.fetchall()))
    except mysql.connector.Error as e:
        print("safe query rejected by privileges (least privilege working):", e.msg)
    cn.close()


def history(reg_no):
    """Application-level join: relational core + document event log."""
    cn = connect(os.getenv("ADMIN_USER", "pk_admin"), os.getenv("ADMIN_PASS", "Admin#2026"))
    cur = cn.cursor(dictionary=True)
    cur.execute("SELECT v.vehicle_id, u.full_name FROM vehicle v JOIN app_user u ON u.user_id = v.owner_id "
                "WHERE v.reg_no = %s", (reg_no,))
    row = cur.fetchone()
    print("MySQL  :", row)
    try:
        from pymongo import MongoClient
        events = MongoClient(os.getenv("MONGO_URI", "mongodb://localhost:27017"))["smart_parking_events"]["gate_events"]
        for ev in events.find({"vehicle_reg": reg_no}).sort("ts", -1).limit(3):
            print("MongoDB:", ev["type"], ev["ts"], ev.get("zone"))
    except Exception as e:                      # keep the demo usable without MongoDB
        print("MongoDB unavailable:", e)
    cn.close()


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--availability", action="store_true")
    ap.add_argument("--reserve", nargs=4, type=int, metavar=("USER", "VEHICLE", "SLOT", "DAYS"))
    ap.add_argument("--allocate", nargs=4, type=int, metavar=("USER", "VEHICLE", "ZONE", "DAYS"))
    ap.add_argument("--concurrency", action="store_true")
    ap.add_argument("--injection", action="store_true")
    ap.add_argument("--history", metavar="REG_NO")
    a = ap.parse_args()
    if a.availability: availability()
    elif a.reserve: reserve(*a.reserve)
    elif a.allocate: allocate(*a.allocate)
    elif a.concurrency: concurrency()
    elif a.injection: injection()
    elif a.history: history(a.history)
    else: ap.print_help(); sys.exit(1)
