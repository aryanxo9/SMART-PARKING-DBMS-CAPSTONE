-- =====================================================================
-- File 06 : Transactions (COMMIT / ROLLBACK / SAVEPOINT) and
--           two-session concurrency demonstrations               (CO3)
-- Part A runs in ONE session.  Part B needs TWO terminals (Session A / B).
-- Demo dates use CURDATE()+N so the script is re-runnable on any day.
-- =====================================================================
USE smart_parking;

-- =====================================================================
-- PART A  --  TRANSACTION SCENARIOS (single session)
-- =====================================================================

-- ---- T1: successful atomic booking -> COMMIT --------------------------------
SET @t1 = CAST(CURDATE() + INTERVAL 5 DAY AS DATETIME) + INTERVAL 9 HOUR;
SELECT COUNT(*) AS before_cnt FROM reservation;
CALL sp_reserve_slot(21, 21, 21, @t1, @t1 + INTERVAL 2 HOUR, 0, @res, @msg);
SELECT @res AS res_id, @msg AS message;                           -- SUCCESS
SELECT COUNT(*) AS after_cnt FROM reservation;                    -- +1
SELECT * FROM audit_log WHERE table_name='reservation' ORDER BY audit_id DESC LIMIT 2;  -- trigger audit

-- ---- T2: failure -> everything ROLLED BACK -------------------------------------
-- user 22 tries to book with vehicle 21 (owned by user 21)
CALL sp_reserve_slot(22, 21, 22, @t1, @t1 + INTERVAL 2 HOUR, 0, @res, @msg);
SELECT @res AS res_id, @msg AS message;                           -- FAILED: Vehicle does not belong...
SELECT COUNT(*) AS cnt_unchanged FROM reservation;                -- same as after_cnt above

-- manual version: explicit ROLLBACK after a trigger rejects the row
START TRANSACTION;
  INSERT INTO reservation(vehicle_id, slot_id, start_time, end_time)
  VALUES (23, 23, @t1, @t1 + INTERVAL 2 HOUR);                    -- OK
  SELECT COUNT(*) AS inside_txn FROM reservation WHERE vehicle_id = 23 AND start_time = @t1;
ROLLBACK;
SELECT COUNT(*) AS after_rollback FROM reservation WHERE vehicle_id = 23 AND start_time = @t1;  -- 0

-- ---- T3: SAVEPOINT -- keep the first step, undo the second ------------------------
START TRANSACTION;
  INSERT INTO reservation(vehicle_id, slot_id, start_time, end_time)
  VALUES (24, 24, @t1, @t1 + INTERVAL 2 HOUR);                    -- step 1 (keep)
  SAVEPOINT after_first_booking;
  INSERT INTO reservation(vehicle_id, slot_id, start_time, end_time)
  VALUES (25, 24, @t1 + INTERVAL 1 HOUR, @t1 + INTERVAL 3 HOUR);  -- step 2 -> trigger error 1644 (overlap)
  -- the statement above fails; the transaction is still open, so:
  ROLLBACK TO SAVEPOINT after_first_booking;
  INSERT INTO reservation(vehicle_id, slot_id, start_time, end_time)
  VALUES (25, 25, @t1 + INTERVAL 1 HOUR, @t1 + INTERVAL 3 HOUR);  -- step 2 retried on a free slot
COMMIT;
SELECT res_id, vehicle_id, slot_id FROM reservation WHERE start_time IN (@t1, @t1 + INTERVAL 1 HOUR) AND vehicle_id IN (24,25);

-- ---- T4: payment transaction with SAVEPOINT inside the procedure ---------------------
SELECT violation_id, status FROM violation WHERE status='OPEN' ORDER BY violation_id LIMIT 1 INTO @vid, @vst;
CALL sp_pay_violation(@vid, 100, 'UPI', 0, @msg);                 -- may be partial or full depending on fine
SELECT @msg;
SELECT violation_id, status FROM violation WHERE violation_id = @vid;
SELECT * FROM audit_log WHERE table_name='payment' ORDER BY audit_id DESC LIMIT 3;

-- ---- T5: the headline business rule: 10-12 booked, 11-13 rejected, 12-14 accepted ------
SET @d = CAST(CURDATE() + INTERVAL 6 DAY AS DATETIME);
CALL sp_reserve_slot(15, 15, 15, @d + INTERVAL 10 HOUR, @d + INTERVAL 12 HOUR, 0, @r1, @m1);  -- SUCCESS
CALL sp_reserve_slot(16, 16, 15, @d + INTERVAL 11 HOUR, @d + INTERVAL 13 HOUR, 0, @r2, @m2);  -- FAILED overlap
CALL sp_reserve_slot(17, 17, 15, @d + INTERVAL 12 HOUR, @d + INTERVAL 14 HOUR, 0, @r3, @m3);  -- SUCCESS (back-to-back)
SELECT @m1 AS "10-12", @m2 AS "11-13", @m3 AS "12-14";

-- =====================================================================
-- PART B  --  TWO-SESSION CONCURRENCY (open two mysql terminals)
-- =====================================================================
-- Isolation: procedures run at READ COMMITTED. Correctness does NOT rely on the
-- isolation level alone; it relies on the row lock taken on parking_slot, which
-- serialises everybody competing for that slot.  Under plain REPEATABLE READ the
-- check-then-insert pattern WITHOUT a lock would allow a double booking
-- (both sessions see "free", both insert).  That is the lost-update / write-skew
-- anomaly this design prevents.

-- ---------- SCENARIO 1 : same slot, overlapping times (blocking) ---------------
-- Session A:
--   SET @d = CAST(CURDATE() + INTERVAL 7 DAY AS DATETIME);
--   CALL sp_reserve_slot(18,18,18, @d+INTERVAL 10 HOUR, @d+INTERVAL 12 HOUR, 15, @r, @m);  -- holds lock 15 s
--   SELECT @r, @m;                                  -- SUCCESS
-- Session B (start within the 15 seconds; it BLOCKS on the slot lock):
--   SET @d = CAST(CURDATE() + INTERVAL 7 DAY AS DATETIME);
--   CALL sp_reserve_slot(19,19,18, @d+INTERVAL 11 HOUR, @d+INTERVAL 13 HOUR, 0, @r, @m);
--   SELECT @r, @m;   -- after A commits: FAILED: Slot already booked for an overlapping interval
-- Session B again with 12-14 -> SUCCESS.
-- Observe the wait from a third terminal:
--   SELECT * FROM performance_schema.data_lock_waits;   -- or: SHOW ENGINE INNODB STATUS\G

-- ---------- SCENARIO 2 : dynamic allocation, no double assignment --------------
-- Session A:
--   SET @d = CAST(CURDATE() + INTERVAL 8 DAY AS DATETIME);
--   CALL sp_allocate_slot(31,31, 1, @d+INTERVAL 10 HOUR, @d+INTERVAL 12 HOUR, 15, @r, @s, @m);
--   SELECT @r, @s, @m;                              -- slot 1
-- Session B (within 15 s):
--   SET @d = CAST(CURDATE() + INTERVAL 8 DAY AS DATETIME);
--   CALL sp_allocate_slot(32,32, 1, @d+INTERVAL 10 HOUR, @d+INTERVAL 12 HOUR, 0, @r, @s, @m);
--   SELECT @r, @s, @m;                              -- slot 2  (slot 1 was skipped: SKIP LOCKED)
-- Verify:  SELECT slot_id, COUNT(*) FROM reservation WHERE start_time = @d+INTERVAL 10 HOUR GROUP BY slot_id HAVING COUNT(*)>1;  -- 0 rows

-- ---------- SCENARIO 3 : zone full -> failure case + ROLLBACK -------------------
-- Zone 5 (EV) has 10 slots.  Fill them all for one interval, then request the 11th:
--   CALL sp_allocate_slot(51,51,5, ...);  ... x10 with users/vehicles 51..60
--   CALL sp_allocate_slot(1,61,5, ...);   -- FAILED: vehicle type mismatch / no free slot; nothing inserted

-- ---------- SCENARIO 4 : two payments for the same fine (lost update) -------------
-- Session A:  CALL sp_pay_violation(<open id>, <full fine>, 'UPI', 15, @m); SELECT @m;   -- SUCCESS
-- Session B (within 15 s): CALL sp_pay_violation(<same id>, <full fine>, 'CARD', 0, @m); SELECT @m;
--             blocks on the violation row, then: FAILED: Violation already settled
-- Verify: SELECT COUNT(*) FROM payment WHERE violation_id = <id>;   -- exactly 1

-- ---------- SCENARIO 5 : DEADLOCK and how it is avoided ---------------------------
-- Session A:  START TRANSACTION;  UPDATE parking_slot SET status='ACTIVE' WHERE slot_id = 30;
-- Session B:  START TRANSACTION;  UPDATE parking_slot SET status='ACTIVE' WHERE slot_id = 31;
-- Session A:  UPDATE parking_slot SET status='ACTIVE' WHERE slot_id = 31;   -- waits for B
-- Session B:  UPDATE parking_slot SET status='ACTIVE' WHERE slot_id = 30;   -- ERROR 1213 Deadlock found;
--             InnoDB rolls back one victim automatically; the other proceeds.
-- Prevention used in this project:
--   1. every routine locks ONE resource first (slot / violation / reservation row);
--   2. multi-slot operations must lock in ascending slot_id order;
--   3. transactions are short (no user interaction while locks are held);
--   4. the application retries a transaction that fails with error 1213 / 1205.
-- Session A and B:  ROLLBACK;

-- ---------- SCENARIO 6 : SERIALIZABLE vs READ COMMITTED (optional comparison) -----
-- Session A: SET SESSION TRANSACTION ISOLATION LEVEL SERIALIZABLE; START TRANSACTION;
--            SELECT COUNT(*) FROM reservation WHERE slot_id=40;      -- takes shared next-key locks
-- Session B: INSERT INTO reservation(...) for slot 40;               -- blocks until A ends
-- Compare: SERIALIZABLE is safe but reduces concurrency; the lock-first design gets the
-- same safety with a lock on ONE slot row only.
