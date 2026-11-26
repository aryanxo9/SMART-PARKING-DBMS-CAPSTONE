-- =====================================================================
-- File 02 : Functions, Stored Procedures, Cursor, Triggers   (CO3)
-- Run with the mysql client (uses DELIMITER).
--
-- DESIGN RULES (each routine solves a business rule, not a checklist):
--  R1  A slot can never have two overlapping bookings (reservation OR visitor pass).
--  R2  Only the vehicle owner can book / cancel; vehicle type must fit slot type.
--  R3  Allocation / cancellation / payment are atomic (all-or-nothing).
--  R4  Entry only inside the reservation window (15 min early grace).
--  R5  Overstay > 15 min after reservation end => automatic OVERSTAY violation.
--  R6  Fee = ceil(hours) * zone rate, first 15 minutes free.
--  R7  A violation becomes PAID automatically once successful payments cover the fine.
--  R8  Every important change leaves an audit record.
--
-- CONCURRENCY STRATEGY: pessimistic locking. Every write procedure first takes
-- a row lock (SELECT ... FOR UPDATE) on the parking_slot row (or the violation
-- row), so competing sessions are serialised on the resource they fight over.
-- Dynamic allocation uses FOR UPDATE SKIP LOCKED so a second user is handed the
-- next free slot instead of waiting.  READ COMMITTED guarantees that, after the
-- lock is granted, the overlap check sees the other session's committed row.
-- =====================================================================
USE smart_parking;

DROP FUNCTION  IF EXISTS fn_is_slot_free;
DROP FUNCTION  IF EXISTS fn_parking_fee;
DROP PROCEDURE IF EXISTS sp_reserve_slot;
DROP PROCEDURE IF EXISTS sp_allocate_slot;
DROP PROCEDURE IF EXISTS sp_cancel_reservation;
DROP PROCEDURE IF EXISTS sp_issue_visitor_pass;
DROP PROCEDURE IF EXISTS sp_record_entry;
DROP PROCEDURE IF EXISTS sp_record_exit;
DROP PROCEDURE IF EXISTS sp_pay_violation;
DROP PROCEDURE IF EXISTS sp_mark_no_shows;
DROP TRIGGER IF EXISTS trg_reservation_bi;
DROP TRIGGER IF EXISTS trg_reservation_bu;
DROP TRIGGER IF EXISTS trg_reservation_ai;
DROP TRIGGER IF EXISTS trg_reservation_au;
DROP TRIGGER IF EXISTS trg_pass_bi;
DROP TRIGGER IF EXISTS trg_entry_bi;
DROP TRIGGER IF EXISTS trg_exit_bi;
DROP TRIGGER IF EXISTS trg_exit_ai;
DROP TRIGGER IF EXISTS trg_payment_ai;

DELIMITER $$

-- ---------------------------------------------------------------------
-- FUNCTION 1: is the slot free for [p_start, p_end) ?  (1 = free, 0 = busy)
-- Two intervals overlap  <=>  start1 < end2 AND end1 > start2
-- So 10-12 vs 11-13 overlaps, but 10-12 vs 12-14 does NOT.
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_is_slot_free(p_slot INT, p_start DATETIME, p_end DATETIME, p_exclude_res INT)
RETURNS TINYINT(1)
READS SQL DATA
BEGIN
  DECLARE v_cnt INT DEFAULT 0;

  SELECT COUNT(*) INTO v_cnt
    FROM reservation
   WHERE slot_id = p_slot
     AND status = 'CONFIRMED'
     AND start_time < p_end AND end_time > p_start
     AND res_id <> IFNULL(p_exclude_res, 0);
  IF v_cnt > 0 THEN RETURN 0; END IF;

  SELECT COUNT(*) INTO v_cnt
    FROM visitor_pass
   WHERE slot_id = p_slot
     AND status = 'ACTIVE'
     AND valid_from < p_end AND valid_to > p_start;
  IF v_cnt > 0 THEN RETURN 0; END IF;

  RETURN 1;
END$$

-- ---------------------------------------------------------------------
-- FUNCTION 2: parking fee  (R6)
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_parking_fee(p_entry DATETIME, p_exit DATETIME, p_slot INT)
RETURNS DECIMAL(8,2)
READS SQL DATA
BEGIN
  DECLARE v_rate DECIMAL(6,2);
  DECLARE v_min  INT;

  SELECT z.hourly_rate INTO v_rate
    FROM parking_slot s JOIN parking_zone z ON z.zone_id = s.zone_id
   WHERE s.slot_id = p_slot;

  SET v_min = TIMESTAMPDIFF(MINUTE, p_entry, p_exit);
  IF v_min <= 15 THEN RETURN 0; END IF;          -- grace period
  RETURN CEIL(v_min / 60) * v_rate;
END$$

-- ---------------------------------------------------------------------
-- PROCEDURE 1: reserve a SPECIFIC slot (atomic, conflict-safe)
-- p_demo_delay (seconds) keeps the lock held so two terminals can demo
-- blocking; use 0 in production.
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_reserve_slot(
  IN  p_user_id INT, IN p_vehicle_id INT, IN p_slot_id INT,
  IN  p_start DATETIME, IN p_end DATETIME, IN p_demo_delay INT,
  OUT p_res_id INT, OUT p_msg VARCHAR(200))
BEGIN
  DECLARE v_slot_status VARCHAR(20);
  DECLARE v_slot_vtype  INT;
  DECLARE v_owner       INT;
  DECLARE v_veh_vtype   INT;
  DECLARE v_user_status VARCHAR(20);
  DECLARE v_cnt         INT DEFAULT 0;
  DECLARE v_err         VARCHAR(200);

  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
    ROLLBACK;
    SET p_res_id = NULL;
    SET p_msg = CONCAT('FAILED: ', v_err);
  END;

  SET p_res_id = NULL;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;   -- must be called outside a transaction
  START TRANSACTION;

  -- STEP 1: lock the slot row. Competing sessions queue here.
  SELECT status, vtype_id INTO v_slot_status, v_slot_vtype
    FROM parking_slot WHERE slot_id = p_slot_id FOR UPDATE;

  IF v_slot_status IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Slot does not exist';
  END IF;
  IF v_slot_status <> 'ACTIVE' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Slot is under maintenance';
  END IF;
  IF p_demo_delay > 0 THEN DO SLEEP(p_demo_delay); END IF;   -- demo only

  -- STEP 2: validate request (R2)
  IF p_start < NOW() OR p_end <= p_start THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid time window (past or end<=start)';
  END IF;

  SELECT owner_id, vtype_id INTO v_owner, v_veh_vtype FROM vehicle WHERE vehicle_id = p_vehicle_id;
  IF v_owner IS NULL OR v_owner <> p_user_id THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Vehicle does not belong to this user';
  END IF;
  IF v_veh_vtype <> v_slot_vtype THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Vehicle type does not fit this slot';
  END IF;

  SELECT status INTO v_user_status FROM app_user WHERE user_id = p_user_id;
  IF v_user_status <> 'ACTIVE' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'User account is suspended';
  END IF;

  SELECT COUNT(*) INTO v_cnt FROM reservation
   WHERE vehicle_id = p_vehicle_id AND status = 'CONFIRMED'
     AND start_time < p_end AND end_time > p_start;
  IF v_cnt > 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Vehicle already has an overlapping reservation';
  END IF;

  -- STEP 3: conflict check (R1) -- safe because we hold the slot lock
  IF fn_is_slot_free(p_slot_id, p_start, p_end, NULL) = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Slot already booked for an overlapping interval';
  END IF;

  INSERT INTO reservation(vehicle_id, slot_id, start_time, end_time)
  VALUES (p_vehicle_id, p_slot_id, p_start, p_end);
  SET p_res_id = LAST_INSERT_ID();

  COMMIT;
  SET p_msg = 'SUCCESS: reservation confirmed';
END$$

-- ---------------------------------------------------------------------
-- PROCEDURE 2: DYNAMIC ALLOCATION -- system picks a free slot in a zone.
-- FOR UPDATE SKIP LOCKED: rows locked by another session are skipped, so two
-- simultaneous users can never receive the same slot and never block each other.
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_allocate_slot(
  IN  p_user_id INT, IN p_vehicle_id INT, IN p_zone_id INT,
  IN  p_start DATETIME, IN p_end DATETIME, IN p_demo_delay INT,
  OUT p_res_id INT, OUT p_slot_id INT, OUT p_msg VARCHAR(200))
BEGIN
  DECLARE v_owner     INT;
  DECLARE v_veh_vtype INT;
  DECLARE v_slot      INT;
  DECLARE v_err       VARCHAR(200);

  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
    ROLLBACK;
    SET p_res_id = NULL; SET p_slot_id = NULL;
    SET p_msg = CONCAT('FAILED: ', v_err);
  END;

  SET p_res_id = NULL; SET p_slot_id = NULL;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;

  SELECT owner_id, vtype_id INTO v_owner, v_veh_vtype FROM vehicle WHERE vehicle_id = p_vehicle_id;
  IF v_owner IS NULL OR v_owner <> p_user_id THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Vehicle does not belong to this user';
  END IF;
  IF p_start < NOW() OR p_end <= p_start THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid time window (past or end<=start)';
  END IF;

  -- pick + lock the first free, compatible, unlocked slot
  SELECT s.slot_id INTO v_slot
    FROM parking_slot s
   WHERE s.zone_id = p_zone_id
     AND s.status = 'ACTIVE'
     AND s.vtype_id = v_veh_vtype
     AND fn_is_slot_free(s.slot_id, p_start, p_end, NULL) = 1
   ORDER BY s.slot_id
   LIMIT 1
   FOR UPDATE SKIP LOCKED;

  IF v_slot IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No free slot in this zone for the requested interval';
  END IF;
  IF p_demo_delay > 0 THEN DO SLEEP(p_demo_delay); END IF;   -- demo only

  INSERT INTO reservation(vehicle_id, slot_id, start_time, end_time)
  VALUES (p_vehicle_id, v_slot, p_start, p_end);
  SET p_res_id  = LAST_INSERT_ID();
  SET p_slot_id = v_slot;

  COMMIT;
  SET p_msg = 'SUCCESS: slot allocated';
END$$

-- ---------------------------------------------------------------------
-- PROCEDURE 3: cancel a reservation (owner only, before start)
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_cancel_reservation(IN p_user_id INT, IN p_res_id INT, OUT p_msg VARCHAR(200))
BEGIN
  DECLARE v_status VARCHAR(20);
  DECLARE v_start  DATETIME;
  DECLARE v_owner  INT;
  DECLARE v_err    VARCHAR(200);

  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
    ROLLBACK;
    SET p_msg = CONCAT('FAILED: ', v_err);
  END;

  START TRANSACTION;
  SELECT r.status, r.start_time, v.owner_id INTO v_status, v_start, v_owner
    FROM reservation r JOIN vehicle v ON v.vehicle_id = r.vehicle_id
   WHERE r.res_id = p_res_id
     FOR UPDATE OF r;

  IF v_status IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Reservation not found'; END IF;
  IF v_owner <> p_user_id THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Not your reservation'; END IF;
  IF v_status <> 'CONFIRMED' THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only CONFIRMED reservations can be cancelled'; END IF;
  IF v_start <= NOW() THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cannot cancel after the start time'; END IF;

  UPDATE reservation SET status = 'CANCELLED', cancelled_at = NOW() WHERE res_id = p_res_id;
  COMMIT;
  SET p_msg = 'SUCCESS: reservation cancelled';
END$$

-- ---------------------------------------------------------------------
-- PROCEDURE 4: issue a visitor pass (visitor zone only)
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_issue_visitor_pass(
  IN p_host INT, IN p_name VARCHAR(80), IN p_phone CHAR(10), IN p_reg VARCHAR(15),
  IN p_slot INT, IN p_from DATETIME, IN p_to DATETIME,
  OUT p_code CHAR(8), OUT p_msg VARCHAR(200))
BEGIN
  DECLARE v_status VARCHAR(20);
  DECLARE v_vis    INT;
  DECLARE v_err    VARCHAR(200);

  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
    ROLLBACK;
    SET p_code = NULL;
    SET p_msg = CONCAT('FAILED: ', v_err);
  END;

  SET p_code = NULL;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;

  SELECT status INTO v_status FROM parking_slot WHERE slot_id = p_slot FOR UPDATE;
  IF v_status IS NULL OR v_status <> 'ACTIVE' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Slot unavailable';
  END IF;
  IF p_from < NOW() - INTERVAL 5 MINUTE OR p_to <= p_from THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid pass window';
  END IF;

  INSERT INTO visitor(full_name, phone, vehicle_reg, host_user_id)
  VALUES (p_name, p_phone, p_reg, p_host);
  SET v_vis = LAST_INSERT_ID();

  -- trigger trg_pass_bi enforces VISITOR zone + no overlap
  INSERT INTO visitor_pass(pass_code, visitor_id, slot_id, valid_from, valid_to)
  VALUES (UPPER(SUBSTRING(MD5(CONCAT(v_vis, RAND(), NOW(6))), 1, 8)), v_vis, p_slot, p_from, p_to);

  SELECT pass_code INTO p_code FROM visitor_pass WHERE pass_id = LAST_INSERT_ID();
  COMMIT;
  SET p_msg = 'SUCCESS: visitor pass issued';
END$$

-- ---------------------------------------------------------------------
-- PROCEDURE 5: gate ENTRY  (reservation holder, visitor pass or walk-in)  (R4)
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_record_entry(
  IN p_vehicle_id INT, IN p_res_id INT, IN p_pass_id INT, IN p_slot_id INT,
  OUT p_entry_id INT, OUT p_msg VARCHAR(200))
BEGIN
  DECLARE v_slot   INT;
  DECLARE v_status VARCHAR(20);
  DECLARE v_start  DATETIME;
  DECLARE v_end    DATETIME;
  DECLARE v_vid    INT;
  DECLARE v_lock   INT;
  DECLARE v_err    VARCHAR(200);

  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
    ROLLBACK;
    SET p_entry_id = NULL;
    SET p_msg = CONCAT('FAILED: ', v_err);
  END;

  SET p_entry_id = NULL;
  START TRANSACTION;

  IF p_res_id IS NOT NULL THEN
    SELECT slot_id, status, start_time, end_time, vehicle_id
      INTO v_slot, v_status, v_start, v_end, v_vid
      FROM reservation WHERE res_id = p_res_id FOR UPDATE;
    IF v_slot IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Reservation not found'; END IF;
    IF v_vid <> p_vehicle_id THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Reservation belongs to another vehicle'; END IF;
    IF v_status <> 'CONFIRMED' THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Reservation is not active'; END IF;
    IF NOW() < v_start - INTERVAL 15 MINUTE OR NOW() > v_end THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Outside reservation window';
    END IF;

  ELSEIF p_pass_id IS NOT NULL THEN
    SELECT slot_id, status, valid_from, valid_to INTO v_slot, v_status, v_start, v_end
      FROM visitor_pass WHERE pass_id = p_pass_id FOR UPDATE;
    IF v_slot IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Pass not found'; END IF;
    IF v_status <> 'ACTIVE' THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Pass is not active'; END IF;
    IF NOW() < v_start OR NOW() > v_end THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Pass not valid now'; END IF;

  ELSE   -- walk-in: slot must be active and free for the next hour
    SELECT slot_id INTO v_slot FROM parking_slot
     WHERE slot_id = p_slot_id AND status = 'ACTIVE' FOR UPDATE;
    IF v_slot IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Slot unavailable'; END IF;
    IF fn_is_slot_free(v_slot, NOW(), NOW() + INTERVAL 1 HOUR, NULL) = 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Slot is reserved for someone else';
    END IF;
  END IF;

  SELECT slot_id INTO v_lock FROM parking_slot WHERE slot_id = v_slot FOR UPDATE;   -- serialise gate events per slot

  INSERT INTO entry_log(vehicle_id, pass_id, reservation_id, slot_id, entry_time)
  VALUES (IF(p_pass_id IS NULL, p_vehicle_id, NULL), p_pass_id, p_res_id, v_slot, NOW());
  SET p_entry_id = LAST_INSERT_ID();

  COMMIT;
  SET p_msg = 'SUCCESS: entry recorded';
END$$

-- ---------------------------------------------------------------------
-- PROCEDURE 6: gate EXIT  (fee + overstay handled by triggers)
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_record_exit(IN p_entry_id INT, OUT p_fee DECIMAL(8,2), OUT p_msg VARCHAR(200))
BEGIN
  DECLARE v_e   INT;
  DECLARE v_err VARCHAR(200);

  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
    ROLLBACK;
    SET p_fee = NULL;
    SET p_msg = CONCAT('FAILED: ', v_err);
  END;

  SET p_fee = NULL;
  START TRANSACTION;
  SELECT entry_id INTO v_e FROM entry_log WHERE entry_id = p_entry_id FOR UPDATE;
  IF v_e IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Entry record not found'; END IF;
  IF EXISTS (SELECT 1 FROM exit_log WHERE entry_id = p_entry_id) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Vehicle has already exited';
  END IF;

  INSERT INTO exit_log(entry_id, exit_time) VALUES (p_entry_id, NOW());   -- triggers: fee, overstay, completion
  SELECT fee_charged INTO p_fee FROM exit_log WHERE entry_id = p_entry_id;

  COMMIT;
  SET p_msg = 'SUCCESS: exit recorded';
END$$

-- ---------------------------------------------------------------------
-- PROCEDURE 7: pay a violation (lock violation row, SAVEPOINT, audit)  (R3, R7)
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_pay_violation(
  IN p_violation_id INT, IN p_amount DECIMAL(8,2), IN p_method VARCHAR(10),
  IN p_demo_delay INT, OUT p_msg VARCHAR(200))
BEGIN
  DECLARE v_status VARCHAR(10);
  DECLARE v_fine   DECIMAL(8,2);
  DECLARE v_paid   DECIMAL(8,2);
  DECLARE v_err    VARCHAR(200);

  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
    ROLLBACK;
    SET p_msg = CONCAT('FAILED: ', v_err);
  END;

  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;

  -- lock ONLY the violation row (not the shared violation_type row)
  SELECT v.status, vt.fine_amount INTO v_status, v_fine
    FROM violation v JOIN violation_type vt ON vt.vt_id = v.vt_id
   WHERE v.violation_id = p_violation_id
     FOR UPDATE OF v;

  IF v_status IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Violation not found'; END IF;
  IF v_status <> 'OPEN' THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Violation already settled'; END IF;
  IF p_demo_delay > 0 THEN DO SLEEP(p_demo_delay); END IF;     -- demo only

  SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM payment WHERE violation_id = p_violation_id AND status = 'SUCCESS';
  IF p_amount <= 0 OR p_amount > v_fine - v_paid THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Amount must be >0 and not exceed the outstanding fine';
  END IF;

  INSERT INTO audit_log(table_name, action, record_id, details, changed_by)
  VALUES ('payment', 'PAYMENT_ATTEMPT', p_violation_id, CONCAT('amount=', p_amount, ', method=', p_method), CURRENT_USER());

  SAVEPOINT after_attempt;                     -- the attempt stays logged even if payment is undone

  INSERT INTO payment(violation_id, amount, method) VALUES (p_violation_id, p_amount, p_method);

  -- defensive post-condition: a full payment must have flipped status to PAID (trigger trg_payment_ai)
  IF p_amount = v_fine - v_paid
     AND (SELECT status FROM violation WHERE violation_id = p_violation_id) <> 'PAID' THEN
    ROLLBACK TO SAVEPOINT after_attempt;
    COMMIT;
    SET p_msg = 'FAILED: payment reversed (status not updated); attempt logged';
  ELSE
    COMMIT;
    SET p_msg = 'SUCCESS: payment recorded';
  END IF;
END$$

-- ---------------------------------------------------------------------
-- PROCEDURE 8: CURSOR -- batch job: confirmed reservations that ended with no entry => NO_SHOW
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_mark_no_shows(OUT p_count INT)
BEGIN
  DECLARE v_done INT DEFAULT 0;
  DECLARE v_res  INT;
  DECLARE cur CURSOR FOR
    SELECT r.res_id FROM reservation r
     WHERE r.status = 'CONFIRMED' AND r.end_time < NOW()
       AND NOT EXISTS (SELECT 1 FROM entry_log e WHERE e.reservation_id = r.res_id);
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

  SET p_count = 0;
  OPEN cur;
  read_loop: LOOP
    FETCH cur INTO v_res;
    IF v_done = 1 THEN LEAVE read_loop; END IF;
    UPDATE reservation SET status = 'NO_SHOW' WHERE res_id = v_res;
    SET p_count = p_count + 1;
  END LOOP;
  CLOSE cur;
END$$

-- =====================================================================
-- TRIGGERS
-- =====================================================================

-- T1: second line of defence against double booking (R1) -------------
CREATE TRIGGER trg_reservation_bi BEFORE INSERT ON reservation
FOR EACH ROW
BEGIN
  IF NEW.status = 'CONFIRMED' AND fn_is_slot_free(NEW.slot_id, NEW.start_time, NEW.end_time, NULL) = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Trigger: overlapping booking for this slot';
  END IF;
END$$

-- T2: same rule when a reservation is rescheduled / re-activated ------
CREATE TRIGGER trg_reservation_bu BEFORE UPDATE ON reservation
FOR EACH ROW
BEGIN
  IF NEW.status = 'CONFIRMED'
     AND (NEW.slot_id <> OLD.slot_id OR NEW.start_time <> OLD.start_time
          OR NEW.end_time <> OLD.end_time OR OLD.status <> 'CONFIRMED') THEN
    IF fn_is_slot_free(NEW.slot_id, NEW.start_time, NEW.end_time, OLD.res_id) = 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Trigger: reschedule would overlap another booking';
    END IF;
  END IF;
END$$

-- T3: audit trail for reservations (R8) --------------------------------
CREATE TRIGGER trg_reservation_ai AFTER INSERT ON reservation
FOR EACH ROW
BEGIN
  INSERT INTO audit_log(table_name, action, record_id, details, changed_by)
  VALUES ('reservation', 'INSERT', NEW.res_id,
          CONCAT('slot=', NEW.slot_id, ', ', NEW.start_time, ' -> ', NEW.end_time), CURRENT_USER());
END$$

CREATE TRIGGER trg_reservation_au AFTER UPDATE ON reservation
FOR EACH ROW
BEGIN
  IF OLD.status <> NEW.status THEN
    INSERT INTO audit_log(table_name, action, record_id, details, changed_by)
    VALUES ('reservation', 'STATUS_CHANGE', NEW.res_id,
            CONCAT(OLD.status, ' -> ', NEW.status), CURRENT_USER());
  END IF;
END$$

-- T4: visitor pass rules ----------------------------------------------
CREATE TRIGGER trg_pass_bi BEFORE INSERT ON visitor_pass
FOR EACH ROW
BEGIN
  DECLARE v_cat VARCHAR(20);
  SELECT z.zone_category INTO v_cat
    FROM parking_slot s JOIN parking_zone z ON z.zone_id = s.zone_id
   WHERE s.slot_id = NEW.slot_id;
  IF v_cat IS NULL OR v_cat <> 'VISITOR' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Visitor passes are only valid for the VISITOR zone';
  END IF;
  IF NEW.status = 'ACTIVE' AND fn_is_slot_free(NEW.slot_id, NEW.valid_from, NEW.valid_to, NULL) = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Trigger: visitor pass overlaps an existing booking/pass';
  END IF;
END$$

-- T5: entry rules: no two open entries on one slot / vehicle / pass ---
-- (@seeding = 1 lets the bulk-load script insert history; it is never set in production)
CREATE TRIGGER trg_entry_bi BEFORE INSERT ON entry_log
FOR EACH ROW
BEGIN
  DECLARE v_open     INT DEFAULT 0;
  DECLARE v_res_slot INT;

  IF IFNULL(@seeding, 0) = 0 THEN
    SELECT COUNT(*) INTO v_open
      FROM entry_log e LEFT JOIN exit_log x ON x.entry_id = e.entry_id
     WHERE x.entry_id IS NULL
       AND (e.slot_id = NEW.slot_id
            OR (NEW.vehicle_id IS NOT NULL AND e.vehicle_id = NEW.vehicle_id)
            OR (NEW.pass_id    IS NOT NULL AND e.pass_id    = NEW.pass_id));
    IF v_open > 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Slot or vehicle already has an open entry (not yet exited)';
    END IF;

    IF NEW.reservation_id IS NOT NULL THEN
      SELECT slot_id INTO v_res_slot FROM reservation WHERE res_id = NEW.reservation_id;
      IF v_res_slot <> NEW.slot_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Entry slot differs from the reserved slot';
      END IF;
    END IF;
  END IF;
END$$

-- T6: exit validation + automatic fee (R6) ---------------------------
CREATE TRIGGER trg_exit_bi BEFORE INSERT ON exit_log
FOR EACH ROW
BEGIN
  DECLARE v_entry DATETIME;
  DECLARE v_slot  INT;
  SELECT entry_time, slot_id INTO v_entry, v_slot FROM entry_log WHERE entry_id = NEW.entry_id;
  IF NEW.exit_time <= v_entry THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Exit time must be after entry time';
  END IF;
  SET NEW.fee_charged = fn_parking_fee(v_entry, NEW.exit_time, v_slot);
END$$

-- T7: after exit -> complete reservation, auto OVERSTAY violation (R5) -
CREATE TRIGGER trg_exit_ai AFTER INSERT ON exit_log
FOR EACH ROW
BEGIN
  DECLARE v_res     INT;
  DECLARE v_vehicle INT;
  DECLARE v_slot    INT;
  DECLARE v_end     DATETIME;
  DECLARE v_vt      INT;

  SELECT reservation_id, vehicle_id, slot_id INTO v_res, v_vehicle, v_slot
    FROM entry_log WHERE entry_id = NEW.entry_id;

  IF v_res IS NOT NULL THEN
    SELECT end_time INTO v_end FROM reservation WHERE res_id = v_res;
    UPDATE reservation SET status = 'COMPLETED' WHERE res_id = v_res AND status = 'CONFIRMED';

    IF NEW.exit_time > v_end + INTERVAL 15 MINUTE THEN
      SELECT vt_id INTO v_vt FROM violation_type WHERE type_code = 'OVERSTAY';
      INSERT INTO violation(vehicle_id, slot_id, vt_id, violation_time, recorded_by, remarks)
      VALUES (v_vehicle, v_slot, v_vt, NEW.exit_time, NULL,
              CONCAT('Auto: overstayed by ', TIMESTAMPDIFF(MINUTE, v_end, NEW.exit_time), ' min'));
    END IF;
  END IF;
END$$

-- T8: payment -> settle violation + audit (R7, R8) --------------------
CREATE TRIGGER trg_payment_ai AFTER INSERT ON payment
FOR EACH ROW
BEGIN
  DECLARE v_fine DECIMAL(8,2);
  DECLARE v_paid DECIMAL(8,2);

  IF NEW.status = 'SUCCESS' THEN
    SELECT vt.fine_amount INTO v_fine
      FROM violation v JOIN violation_type vt ON vt.vt_id = v.vt_id
     WHERE v.violation_id = NEW.violation_id;
    SELECT COALESCE(SUM(amount), 0) INTO v_paid
      FROM payment WHERE violation_id = NEW.violation_id AND status = 'SUCCESS';
    IF v_paid >= v_fine THEN
      UPDATE violation SET status = 'PAID' WHERE violation_id = NEW.violation_id;
    END IF;
  END IF;

  INSERT INTO audit_log(table_name, action, record_id, details, changed_by)
  VALUES ('payment', 'INSERT', NEW.payment_id,
          CONCAT('violation=', NEW.violation_id, ', amount=', NEW.amount, ', ', NEW.status), CURRENT_USER());
END$$

DELIMITER ;
