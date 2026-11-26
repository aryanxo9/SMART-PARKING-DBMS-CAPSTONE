-- =====================================================================
-- File 03 : Realistic sample data (500+ rows incl. auto-generated audit/violations)
-- Run AFTER 02 so triggers generate overstay violations, fees and audit rows.
-- @seeding=1 only relaxes the "open entry" check for historical inserts.
-- Temp tables are used wherever a statement would read a table that its own
-- trigger modifies (MySQL error 1442).
-- =====================================================================
USE smart_parking;
SET @seeding = 1;

-- helper number table (1..200)
CREATE TABLE seq (n INT PRIMARY KEY);
INSERT INTO seq
WITH RECURSIVE g(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM g WHERE n < 200)
SELECT n FROM g;

-- reference data -------------------------------------------------------
INSERT INTO department(dept_name) VALUES
 ('Computer Science'),('Electrical Engineering'),('Mechanical Engineering'),
 ('Civil Engineering'),('Management Studies'),('Administration');

INSERT INTO vehicle_type(type_name, wheels) VALUES ('CAR',4),('BIKE',2),('EV',4);

INSERT INTO parking_zone(zone_name, zone_category, hourly_rate) VALUES
 ('Zone A - Student Lot','GENERAL',10.00),
 ('Zone B - Staff Lot','STAFF',20.00),
 ('Zone C - Visitor Lot','VISITOR',30.00),
 ('Zone D - Two Wheeler Bay','TWO_WHEELER',5.00),
 ('Zone E - EV Charging','EV',40.00);

INSERT INTO security_staff(full_name, shift) VALUES
 ('Ramesh Yadav','MORNING'),('Suresh Chauhan','EVENING'),
 ('Mahesh Pal','NIGHT'),('Dinesh Rawat','MORNING');

INSERT INTO violation_type(vt_id, type_code, description, fine_amount) VALUES
 (1,'OVERSTAY','Stayed beyond reserved time',100),
 (2,'NO_PERMIT','Parked without permit or reservation',200),
 (3,'WRONG_ZONE','Parked in a wrong zone',150),
 (4,'BLOCKING','Blocking another vehicle or the lane',300),
 (5,'ILLEGAL_PARKING','Parked outside designated slot',250),
 (6,'EXPIRED_PASS','Visitor pass expired',120);

-- 60 slots: A 1-14, B 15-28, C 29-40 (CAR) | D 41-50 (BIKE) | E 51-60 (EV)
INSERT INTO parking_slot(zone_id, slot_code, vtype_id)
SELECT CASE WHEN n<=14 THEN 1 WHEN n<=28 THEN 2 WHEN n<=40 THEN 3 WHEN n<=50 THEN 4 ELSE 5 END,
       CONCAT(CASE WHEN n<=14 THEN 'A' WHEN n<=28 THEN 'B' WHEN n<=40 THEN 'C' WHEN n<=50 THEN 'D' ELSE 'E' END,
              '-', LPAD(CASE WHEN n<=14 THEN n WHEN n<=28 THEN n-14 WHEN n<=40 THEN n-28
                             WHEN n<=50 THEN n-40 ELSE n-50 END, 2, '0')),
       CASE WHEN n<=40 THEN 1 WHEN n<=50 THEN 2 ELSE 3 END
  FROM seq WHERE n <= 60 ORDER BY n;
UPDATE parking_slot SET status = 'MAINTENANCE' WHERE slot_id = 14;

-- 60 users ---------------------------------------------------------------
INSERT INTO app_user(full_name, email, phone, user_type, dept_id)
SELECT CONCAT(ELT(1+MOD(n,10),'Aarav','Vivaan','Aditya','Ishaan','Ananya','Diya','Saanvi','Kavya','Rohan','Meera'),
              ' ',
              ELT(1+MOD(n*3,10),'Sharma','Verma','Gupta','Singh','Kumar','Mehta','Reddy','Nair','Joshi','Khan')),
       CONCAT('user', n, '@campus.edu'),
       CONCAT('9', LPAD(100000000 + n*7919, 9, '0')),
       ELT(1+MOD(n,3),'STUDENT','EMPLOYEE','RESIDENT'),
       CASE WHEN MOD(n,3) = 2 THEN NULL ELSE 1 + MOD(n,6) END
  FROM seq WHERE n <= 60 ORDER BY n;
UPDATE app_user SET status = 'SUSPENDED' WHERE user_id = 60;

-- 70 vehicles: 1-40 CAR, 41-50 BIKE, 51-60 EV, 61-70 second CAR of users 1-10 ------
INSERT INTO vehicle(reg_no, owner_id, vtype_id, make_model)
SELECT CONCAT('DL', LPAD(1+MOD(n,14),2,'0'), IF(n BETWEEN 41 AND 50,'SB','CA'), LPAD(1000+n*7,4,'0')),
       IF(n <= 60, n, n - 60),
       CASE WHEN n BETWEEN 41 AND 50 THEN 2 WHEN n BETWEEN 51 AND 60 THEN 3 ELSE 1 END,
       CASE WHEN n BETWEEN 41 AND 50 THEN ELT(1+MOD(n,3),'Honda Activa','TVS Jupiter','Bajaj Pulsar')
            WHEN n BETWEEN 51 AND 60 THEN ELT(1+MOD(n,2),'Tata Nexon EV','MG ZS EV')
            ELSE ELT(1+MOD(n,5),'Maruti Swift','Hyundai i20','Tata Nexon','Honda City','Mahindra XUV300') END
  FROM seq WHERE n <= 70 ORDER BY n;

-- 120 historical reservations (slot n, vehicle n, 1-2 days ago; never overlapping) ----
INSERT INTO reservation(vehicle_id, slot_id, start_time, end_time)
SELECT 1+MOD(n-1,60), 1+MOD(n-1,60), s, s + INTERVAL (2 + MOD(n,3)) HOUR
  FROM (SELECT n,
               CAST(CURDATE() - INTERVAL (1 + (n-1) DIV 60) DAY AS DATETIME) + INTERVAL (8 + MOD(n,8)) HOUR AS s
          FROM seq WHERE n <= 120) t
 ORDER BY n;
UPDATE reservation SET status = 'COMPLETED' WHERE res_id <= 100;
UPDATE reservation SET status = 'CANCELLED', cancelled_at = start_time - INTERVAL 1 DAY WHERE res_id BETWEEN 101 AND 110;
UPDATE reservation SET status = 'NO_SHOW' WHERE res_id BETWEEN 111 AND 120;

-- 6 reservations running right now (res 121-126) and 10 for tomorrow (127-136) ----
INSERT INTO reservation(vehicle_id, slot_id, start_time, end_time)
SELECT n, n, NOW() - INTERVAL 1 HOUR, NOW() + INTERVAL 2 HOUR FROM seq WHERE n <= 6 ORDER BY n;
INSERT INTO reservation(vehicle_id, slot_id, start_time, end_time)
SELECT 20 + n, 20 + n,
       CAST(CURDATE() + INTERVAL 1 DAY AS DATETIME) + INTERVAL (9 + MOD(n,3)) HOUR,
       CAST(CURDATE() + INTERVAL 1 DAY AS DATETIME) + INTERVAL (11 + MOD(n,3)) HOUR
  FROM seq WHERE n <= 10 ORDER BY n;

-- visitors and passes (visitor zone = slots 29-40) ---------------------------
INSERT INTO visitor(full_name, phone, vehicle_reg, host_user_id)
SELECT CONCAT('Visitor ', n), CONCAT('8', LPAD(200000000 + n*104729, 9, '0')),
       CONCAT('UP16VX', LPAD(2000 + n*11, 4, '0')), 1 + MOD(n*5, 60)
  FROM seq WHERE n <= 15 ORDER BY n;

INSERT INTO visitor_pass(pass_code, visitor_id, slot_id, valid_from, valid_to)
SELECT UPPER(SUBSTRING(MD5(CONCAT('pass', n)), 1, 8)), n, 29 + MOD(n-1, 12),
       CAST(CURDATE() AS DATETIME) + INTERVAL IF(n <= 12, 9, 14) HOUR,
       CAST(CURDATE() AS DATETIME) + INTERVAL IF(n <= 12, 13, 18) HOUR
  FROM seq WHERE n <= 15 ORDER BY n;
UPDATE visitor_pass SET status = 'EXPIRED' WHERE pass_id IN (3, 4);

-- gate movements for the 100 completed reservations ---------------------------
INSERT INTO entry_log(vehicle_id, slot_id, reservation_id, entry_time)
SELECT vehicle_id, slot_id, res_id, start_time + INTERVAL MOD(res_id,5) MINUTE
  FROM reservation WHERE res_id <= 100 ORDER BY res_id;

CREATE TEMPORARY TABLE tmp_exit AS
SELECT e.entry_id, r.end_time + INTERVAL ((MOD(r.res_id,7) - 2) * 10) MINUTE AS exit_time
  FROM entry_log e JOIN reservation r ON r.res_id = e.reservation_id;
INSERT INTO exit_log(entry_id, exit_time)          -- triggers: fee + auto OVERSTAY violations
SELECT entry_id, exit_time FROM tmp_exit ORDER BY entry_id;
DROP TEMPORARY TABLE tmp_exit;

-- 6 vehicles currently inside (open entries)
INSERT INTO entry_log(vehicle_id, slot_id, reservation_id, entry_time)
SELECT vehicle_id, slot_id, res_id, start_time + INTERVAL 5 MINUTE
  FROM reservation WHERE res_id BETWEEN 121 AND 126 ORDER BY res_id;

-- manual patrol violations: vehicles 3 and 7 are repeat offenders --------------
INSERT INTO violation(vehicle_id, slot_id, vt_id, violation_time, recorded_by, remarks)
SELECT v, v, 2 + MOD(n,4), NOW() - INTERVAL (n*29) HOUR, 1 + MOD(n,4), 'Recorded during patrol'
  FROM (SELECT n, CASE WHEN n<=6 THEN 3 WHEN n<=10 THEN 7 ELSE 1 + MOD(n*13,60) END AS v
          FROM seq WHERE n <= 24) t
 ORDER BY n;

-- payments for every 3rd violation (full fine) -> trigger marks them PAID --------
CREATE TEMPORARY TABLE tmp_pay AS
SELECT v.violation_id, vt.fine_amount, ELT(1 + MOD(v.violation_id,3), 'UPI','CARD','CASH') AS method,
       v.violation_time + INTERVAL 2 DAY AS paid_at
  FROM violation v JOIN violation_type vt ON vt.vt_id = v.vt_id
 WHERE MOD(v.violation_id, 3) = 0;
INSERT INTO payment(violation_id, amount, method, paid_at)
SELECT violation_id, fine_amount, method, paid_at FROM tmp_pay ORDER BY violation_id;
DROP TEMPORARY TABLE tmp_pay;

DROP TABLE seq;
SET @seeding = 0;

-- sanity report ------------------------------------------------------------------
SELECT 'department' t, COUNT(*) c FROM department UNION ALL SELECT 'app_user', COUNT(*) FROM app_user
UNION ALL SELECT 'vehicle', COUNT(*) FROM vehicle UNION ALL SELECT 'parking_zone', COUNT(*) FROM parking_zone
UNION ALL SELECT 'parking_slot', COUNT(*) FROM parking_slot UNION ALL SELECT 'reservation', COUNT(*) FROM reservation
UNION ALL SELECT 'visitor', COUNT(*) FROM visitor UNION ALL SELECT 'visitor_pass', COUNT(*) FROM visitor_pass
UNION ALL SELECT 'entry_log', COUNT(*) FROM entry_log UNION ALL SELECT 'exit_log', COUNT(*) FROM exit_log
UNION ALL SELECT 'violation', COUNT(*) FROM violation UNION ALL SELECT 'payment', COUNT(*) FROM payment
UNION ALL SELECT 'audit_log', COUNT(*) FROM audit_log;
