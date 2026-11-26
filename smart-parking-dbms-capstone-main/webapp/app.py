"""Smart Parking - backend (Flask REST API). Run: python app.py  ->  http://127.0.0.1:5000
All SQL is parameterised; all booking logic stays in the MySQL procedures."""
import os
from datetime import datetime
from flask import Flask, jsonify, render_template, request
import mysql.connector

app = Flask(__name__)


def db():
    # least-privilege account created by sql/07_security_rbac.sql
    return mysql.connector.connect(
        host=os.getenv("DB_HOST", "localhost"), port=int(os.getenv("DB_PORT", "3306")), user=os.getenv("DB_USER", "pk_user"),
        password=os.getenv("DB_PASS", "User#2026"), database=os.getenv("DB_NAME", "smart_parking"),
        autocommit=True)


def parse(s):
    return datetime.fromisoformat(s).replace(second=0, microsecond=0)


def rows(sql, args=()):
    cn = db(); cur = cn.cursor(dictionary=True)
    cur.execute(sql, args)
    out = [{k: (str(v) if v is not None else None) for k, v in r.items()} for r in cur.fetchall()]
    cn.close()
    return out


def call(proc, args):
    cn = db(); cur = cn.cursor()
    res = cur.callproc(proc, args)
    cn.close()
    return res


@app.get("/health")
def health():
    return "ok"


@app.get("/")
def home():
    return render_template("index.html")


@app.get("/api/availability")
def availability():
    return jsonify(rows("SELECT zone_id, zone_name, slot_code, current_status FROM v_current_availability "
                        "ORDER BY zone_id, slot_id"))


@app.get("/api/reservations")
def reservations():
    uid = request.args.get("user_id", type=int)
    return jsonify(rows("SELECT res_id, reg_no, zone_name, slot_code, start_time, end_time, status "
                        "FROM v_reservation_details WHERE user_id = %s ORDER BY start_time DESC LIMIT 20", (uid,)))


@app.post("/api/reserve")
def reserve():
    d = request.get_json()
    try:
        r = call("sp_reserve_slot", (int(d["user_id"]), int(d["vehicle_id"]), int(d["slot_id"]),
                                     parse(d["start"]), parse(d["end"]), 0, 0, ""))
        return jsonify(res_id=r[6], message=r[7])
    except (KeyError, ValueError):
        return jsonify(message="FAILED: invalid input"), 400


@app.post("/api/allocate")
def allocate():
    d = request.get_json()
    try:
        r = call("sp_allocate_slot", (int(d["user_id"]), int(d["vehicle_id"]), int(d["zone_id"]),
                                      parse(d["start"]), parse(d["end"]), 0, 0, 0, ""))
        return jsonify(res_id=r[6], slot_id=r[7], message=r[8])
    except (KeyError, ValueError):
        return jsonify(message="FAILED: invalid input"), 400


@app.post("/api/cancel")
def cancel():
    d = request.get_json()
    r = call("sp_cancel_reservation", (int(d["user_id"]), int(d["res_id"]), ""))
    return jsonify(message=r[2])


if __name__ == "__main__":
    app.run(debug=True)
