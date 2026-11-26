-- =====================================================================
-- File 09 : Test cases (positive, negative, integrity, transaction, invariants)
-- Run on a freshly loaded database (files 01-04) with:
--        mysql --force -u root -p < sql/09_test_cases.sql
-- --force keeps going after the *expected* errors in the integrity section.
-- Every test prints its id, what it checks, and the EXPECTED result.
-- Concurrency tests: see 06_transactions_concurrency.sql (manual) and
-- app/parking_app.py --concurrency (automated).
-- =====================================================================
USE smart_parking;
SET @d = CAST(CURDATE() + INTERVAL 10 DAY AS DATETIME);

-- ------------------------------ POSITIVE ---------------------------------------
SELECT 'TC01 valid reservation  | EXPECT: SUCCESS' AS test;
CALL sp_reserve_slot(15, 15, 15, @d + INTERVAL 10 HOUR, @d + INTERVAL 12 HOUR, 0, @r01, @m);
SELECT @r01 AS res_id, @m AS result;

SELECT 'TC02 back-to-back 12-14 after 10-12 | EXPECT: SUCCESS' AS test;
CALL sp_reserve_slot(16, 16, 15, @d + INTERVAL 12 HOUR, @d + INTERVAL 14 HOUR, 0, @r02, @m);
SELECT @r02 AS res_id, @m AS result;

SELECT 'TC03 dynamic allocation in zone B | EXPECT: SUCCESS + a slot id' AS test;
CALL sp_allocate_slot(33, 33, 2, @d + INTERVAL 10 HOUR, @d + INTERVAL 12 HOUR, 0, @r03, @s03, @m);
SELECT @r03 AS res_id, @s03 AS slot_id, @m AS result;

SELECT 'TC04 walk-in entry then exit (<=15 min) | EXPECT: SUCCESS, fee 0.00' AS test;
CALL sp_record_entry(45, NULL, NULL, 45, @e04, @m);
SELECT @e04 AS entry_id, @m AS result;
CALL sp_record_exit(@e04, @fee04, @m);
SELECT @fee04 AS fee, @m AS result;

-- ------------------------------ NEGATIVE ----------------------------------------
SELECT 'TC05 overlapping 11-13 against 10-12 | EXPECT: FAILED overlapping interval' AS test;
CALL sp_reserve_slot(17, 17, 15, @d + INTERVAL 11 HOUR, @d + INTERVAL 13 HOUR, 0, @r, @m);
SELECT @r AS res_id, @m AS result;

SELECT 'TC06 booking in the past | EXPECT: FAILED invalid time window' AS test;
CALL sp_reserve_slot(18, 18, 18, NOW() - INTERVAL 2 HOUR, NOW() + INTERVAL 1 HOUR, 0, @r, @m);
SELECT @r AS res_id, @m AS result;

SELECT 'TC07 end before start | EXPECT: FAILED invalid time window' AS test;
CALL sp_reserve_slot(18, 18, 18, @d + INTERVAL 15 HOUR, @d + INTERVAL 14 HOUR, 0, @r, @m);
SELECT @r AS res_id, @m AS result;

SELECT 'TC08 vehicle of another user | EXPECT: FAILED vehicle does not belong' AS test;
CALL sp_reserve_slot(19, 18, 18, @d + INTERVAL 10 HOUR, @d + INTERVAL 11 HOUR, 0, @r, @m);
SELECT @r AS res_id, @m AS result;

SELECT 'TC09 bike into a car slot | EXPECT: FAILED vehicle type does not fit' AS test;
CALL sp_reserve_slot(41, 41, 1, @d + INTERVAL 10 HOUR, @d + INTERVAL 11 HOUR, 0, @r, @m);
SELECT @r AS res_id, @m AS result;

SELECT 'TC10 slot under maintenance (slot 14) | EXPECT: FAILED maintenance' AS test;
CALL sp_reserve_slot(14, 14, 14, @d + INTERVAL 10 HOUR, @d + INTERVAL 11 HOUR, 0, @r, @m);
SELECT @r AS res_id, @m AS result;

SELECT 'TC11 suspended user 60 | EXPECT: FAILED account suspended' AS test;
CALL sp_reserve_slot(60, 60, 60, @d + INTERVAL 10 HOUR, @d + INTERVAL 11 HOUR, 0, @r, @m);
SELECT @r AS res_id, @m AS result;

SELECT 'TC12 cancel someone else''s reservation | EXPECT: FAILED not your reservation' AS test;
CALL sp_cancel_reservation(99, @r01, @m);
SELECT @m AS result;

SELECT 'TC13 owner cancels own future reservation | EXPECT: SUCCESS, status CANCELLED' AS test;
CALL sp_cancel_reservation(15, @r01, @m);
SELECT @m AS result, status FROM reservation WHERE res_id = @r01;

SELECT 'TC14 visitor pass outside visitor zone | EXPECT: FAILED, and NO orphan visitor row' AS test;
SELECT COUNT(*) INTO @v_before FROM visitor;
CALL sp_issue_visitor_pass(1, 'Test Guest', '9999999999', 'DL99ZZ0001', 1,
                           NOW() + INTERVAL 1 HOUR, NOW() + INTERVAL 3 HOUR, @code, @m);
SELECT @m AS result, (SELECT COUNT(*) FROM visitor) - @v_before AS visitor_rows_added;   -- 0

SELECT 'TC15 visitor pass in visitor zone | EXPECT: SUCCESS + 8-char code' AS test;
CALL sp_issue_visitor_pass(1, 'Test Guest', '9999999999', 'DL99ZZ0001', 40,
                           @d + INTERVAL 10 HOUR, @d + INTERVAL 12 HOUR, @code, @m);
SELECT @code AS pass_code, @m AS result;

-- ------------------------------ INTEGRITY (raw SQL; errors expected) -----------------------
SELECT 'TC16 duplicate registration number | EXPECT: ERROR 1062 duplicate entry' AS test;
INSERT INTO vehicle(reg_no, owner_id, vtype_id) VALUES ('DL02CA1007', 1, 1);

SELECT 'TC17 invalid phone number | EXPECT: ERROR 3819 check constraint chk_user_phone' AS test;
INSERT INTO app_user(full_name, email, phone, user_type) VALUES ('Bad Phone', 'bad@campus.edu', '12AB', 'STUDENT');

SELECT 'TC18 reservation for non-existent vehicle | EXPECT: ERROR 1452 foreign key' AS test;
INSERT INTO reservation(vehicle_id, slot_id, start_time, end_time) VALUES (9999, 1, @d, @d + INTERVAL 1 HOUR);

SELECT 'TC19 end_time <= start_time | EXPECT: ERROR 3819 chk_res_window' AS test;
INSERT INTO reservation(vehicle_id, slot_id, start_time, end_time) VALUES (1, 1, @d + INTERVAL 5 HOUR, @d + INTERVAL 4 HOUR);

SELECT 'TC20 reservation longer than 12 h | EXPECT: ERROR 3819 chk_res_max12h' AS test;
INSERT INTO reservation(vehicle_id, slot_id, start_time, end_time) VALUES (1, 1, @d, @d + INTERVAL 13 HOUR);

SELECT 'TC21 raw overlapping insert bypassing the procedure | EXPECT: ERROR 1644 trigger overlap' AS test;
INSERT INTO reservation(vehicle_id, slot_id, start_time, end_time)
VALUES (20, 15, @d + INTERVAL 11 HOUR, @d + INTERVAL 13 HOUR);

SELECT 'TC22 entry with both vehicle and pass | EXPECT: ERROR 3819 chk_entry_actor' AS test;
INSERT INTO entry_log(vehicle_id, pass_id, slot_id, entry_time) VALUES (30, 1, 29, NOW());

SELECT 'TC23 delete a vehicle that has reservations | EXPECT: ERROR 1451 foreign key' AS test;
DELETE FROM vehicle WHERE vehicle_id = 1;

SELECT 'TC24 second exit for the same entry | EXPECT: ERROR 1062 unique entry_id' AS test;
INSERT INTO exit_log(entry_id, exit_time) VALUES (1, NOW());

SELECT 'TC25 walk-in on a slot that is occupied/reserved right now (slot 1) | EXPECT: FAILED, no entry row' AS test;
CALL sp_record_entry(61, NULL, NULL, 1, @e, @m);
SELECT @e AS entry_id, @m AS result;

-- ------------------------------ TRANSACTION / BUSINESS RULES --------------------------------------
SELECT v.violation_id, vt.fine_amount INTO @vid, @fine
  FROM violation v JOIN violation_type vt ON vt.vt_id = v.vt_id
 WHERE v.status = 'OPEN' ORDER BY v.violation_id LIMIT 1;

SELECT 'TC26 overpayment | EXPECT: FAILED amount exceeds outstanding; violation stays OPEN' AS test;
CALL sp_pay_violation(@vid, @fine + 1, 'UPI', 0, @m);
SELECT @m AS result, status FROM violation WHERE violation_id = @vid;

SELECT 'TC27 exact payment | EXPECT: SUCCESS, status PAID (trigger), 1 payment row' AS test;
CALL sp_pay_violation(@vid, @fine, 'UPI', 0, @m);
SELECT @m AS result, status, (SELECT COUNT(*) FROM payment WHERE violation_id = @vid) AS payments
  FROM violation WHERE violation_id = @vid;

SELECT 'TC28 pay an already settled violation | EXPECT: FAILED already settled' AS test;
CALL sp_pay_violation(@vid, @fine, 'CARD', 0, @m);
SELECT @m AS result, (SELECT COUNT(*) FROM payment WHERE violation_id = @vid) AS payments;   -- still 1

SELECT 'TC29 rollback leaves nothing behind | EXPECT: 0 rows' AS test;
START TRANSACTION;
INSERT INTO reservation(vehicle_id, slot_id, start_time, end_time) VALUES (26, 26, @d + INTERVAL 20 HOUR, @d + INTERVAL 21 HOUR);
ROLLBACK;
SELECT COUNT(*) AS rows_found FROM reservation WHERE vehicle_id = 26 AND start_time = @d + INTERVAL 20 HOUR;

SELECT 'TC30 audit trail written by triggers | EXPECT: > 0 rows' AS test;
SELECT COUNT(*) AS audit_rows FROM audit_log WHERE table_name = 'reservation' AND changed_at >= NOW() - INTERVAL 10 MINUTE;

SELECT 'TC31 no-show batch job (cursor) | EXPECT: returns a count (0 on fresh data)' AS test;
CALL sp_mark_no_shows(@n);
SELECT @n AS marked_no_show;

-- ------------------------------ GLOBAL INVARIANTS (must all be 0) ---------------------------------
SELECT 'INV1 no two CONFIRMED reservations overlap on any slot | EXPECT: 0' AS test;
SELECT COUNT(*) AS overlapping_pairs
  FROM reservation a JOIN reservation b
    ON a.slot_id = b.slot_id AND a.res_id < b.res_id
   AND a.status = 'CONFIRMED' AND b.status = 'CONFIRMED'
   AND a.start_time < b.end_time AND a.end_time > b.start_time;

SELECT 'INV2 every late exit has an OVERSTAY violation | EXPECT: 0' AS test;
SELECT COUNT(*) AS missing_overstay
  FROM exit_log x
  JOIN entry_log e   ON e.entry_id = x.entry_id
  JOIN reservation r ON r.res_id = e.reservation_id
 WHERE x.exit_time > r.end_time + INTERVAL 15 MINUTE
   AND NOT EXISTS (SELECT 1 FROM violation v
                    WHERE v.vehicle_id = e.vehicle_id AND v.vt_id = 1 AND v.violation_time = x.exit_time);

SELECT 'INV3 PAID violations are fully covered by payments | EXPECT: 0' AS test;
SELECT COUNT(*) AS underpaid
  FROM violation v JOIN violation_type vt ON vt.vt_id = v.vt_id
 WHERE v.status = 'PAID'
   AND (SELECT COALESCE(SUM(p.amount),0) FROM payment p WHERE p.violation_id = v.violation_id AND p.status='SUCCESS') < vt.fine_amount;

SELECT 'INV4 at most one open entry per slot | EXPECT: 0' AS test;
SELECT COUNT(*) AS slots_with_2_open FROM (
  SELECT e.slot_id FROM entry_log e LEFT JOIN exit_log x ON x.entry_id = e.entry_id
   WHERE x.entry_id IS NULL GROUP BY e.slot_id HAVING COUNT(*) > 1) t;
