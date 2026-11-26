-- =====================================================================
-- File 04 : Views and Indexes (with EXPLAIN justification)      (CO2)
-- =====================================================================
USE smart_parking;

-- VIEW 1: real-time status of every slot ---------------------------------
CREATE OR REPLACE VIEW v_current_availability AS
SELECT s.slot_id, z.zone_id, z.zone_name, s.slot_code,
       CASE
         WHEN s.status <> 'ACTIVE' THEN 'MAINTENANCE'
         WHEN EXISTS (SELECT 1 FROM entry_log e
                       WHERE e.slot_id = s.slot_id
                         AND NOT EXISTS (SELECT 1 FROM exit_log x WHERE x.entry_id = e.entry_id)) THEN 'OCCUPIED'
         WHEN EXISTS (SELECT 1 FROM reservation r
                       WHERE r.slot_id = s.slot_id AND r.status = 'CONFIRMED'
                         AND NOW() BETWEEN r.start_time AND r.end_time)
           OR EXISTS (SELECT 1 FROM visitor_pass p
                       WHERE p.slot_id = s.slot_id AND p.status = 'ACTIVE'
                         AND NOW() BETWEEN p.valid_from AND p.valid_to) THEN 'RESERVED'
         ELSE 'AVAILABLE'
       END AS current_status
  FROM parking_slot s
  JOIN parking_zone z ON z.zone_id = s.zone_id;

-- VIEW 2: zone occupancy dashboard -----------------------------------------
CREATE OR REPLACE VIEW v_zone_occupancy_now AS
SELECT zone_id, zone_name,
       COUNT(*)                                         AS total_slots,
       SUM(current_status = 'AVAILABLE')                AS available,
       SUM(current_status = 'RESERVED')                 AS reserved,
       SUM(current_status = 'OCCUPIED')                 AS occupied,
       SUM(current_status = 'MAINTENANCE')              AS maintenance,
       ROUND(100 * SUM(current_status IN ('OCCUPIED','RESERVED')) / COUNT(*), 1) AS busy_pct
  FROM v_current_availability
 GROUP BY zone_id, zone_name;

-- VIEW 3: unpaid violations with owner contact (for security / admin) -------
CREATE OR REPLACE VIEW v_open_violations AS
SELECT vi.violation_id, ve.reg_no, u.full_name AS owner_name, u.phone,
       vt.type_code, vt.fine_amount, vi.violation_time,
       DATEDIFF(CURDATE(), DATE(vi.violation_time)) AS days_pending
  FROM violation vi
  JOIN vehicle ve        ON ve.vehicle_id = vi.vehicle_id
  JOIN app_user u        ON u.user_id     = ve.owner_id
  JOIN violation_type vt ON vt.vt_id      = vi.vt_id
 WHERE vi.status = 'OPEN';

-- VIEW 4: repeat violators (3+ violations in last 90 days) ----------------------
CREATE OR REPLACE VIEW v_repeat_violators AS
SELECT ve.vehicle_id, ve.reg_no, u.full_name, COUNT(*) AS violations_90d, SUM(vt.fine_amount) AS total_fines
  FROM violation vi
  JOIN vehicle ve        ON ve.vehicle_id = vi.vehicle_id
  JOIN app_user u        ON u.user_id     = ve.owner_id
  JOIN violation_type vt ON vt.vt_id      = vi.vt_id
 WHERE vi.violation_time >= NOW() - INTERVAL 90 DAY
 GROUP BY ve.vehicle_id, ve.reg_no, u.full_name
HAVING COUNT(*) >= 3;

-- VIEW 5: safe, self-service view for a normal user (no other users' data) ----
CREATE OR REPLACE VIEW v_reservation_details AS
SELECT r.res_id, ve.owner_id AS user_id, ve.reg_no, z.zone_name, s.slot_code,
       r.start_time, r.end_time, r.status
  FROM reservation r
  JOIN vehicle ve      ON ve.vehicle_id = r.vehicle_id
  JOIN parking_slot s  ON s.slot_id     = r.slot_id
  JOIN parking_zone z  ON z.zone_id     = s.zone_id;

-- =====================================================================
-- INDEXES  (InnoDB already indexes every FK column; these add what the
--           queries really need)
-- =====================================================================

-- BEFORE: range scan on start_time has no usable index -> full table scan
EXPLAIN SELECT res_id, slot_id FROM reservation
 WHERE start_time >= NOW() - INTERVAL 2 DAY AND start_time < NOW() + INTERVAL 2 DAY;

-- INDEX 1: supports the overlap test used in every booking (slot + time window)
CREATE INDEX idx_res_slot_time  ON reservation(slot_id, status, start_time, end_time);
-- INDEX 2: time-range reports / hourly demand
CREATE INDEX idx_res_start      ON reservation(start_time);
-- INDEX 3: "who is inside now?" and per-slot history
CREATE INDEX idx_entry_slot_time ON entry_log(slot_id, entry_time);
-- INDEX 4: repeat-violator lookups
CREATE INDEX idx_viol_vehicle_time ON violation(vehicle_id, violation_time);
-- INDEX 5: open-violation dashboard
CREATE INDEX idx_viol_status ON violation(status);
-- INDEX 6: visitor-pass overlap test
CREATE INDEX idx_pass_slot_time ON visitor_pass(slot_id, status, valid_from, valid_to);

-- AFTER: same query now uses a range access on idx_res_start
EXPLAIN SELECT res_id, slot_id FROM reservation
 WHERE start_time >= NOW() - INTERVAL 2 DAY AND start_time < NOW() + INTERVAL 2 DAY;

-- Overlap check for one slot -> uses idx_res_slot_time (type=range, key=idx_res_slot_time)
EXPLAIN SELECT COUNT(*) FROM reservation
 WHERE slot_id = 20 AND status = 'CONFIRMED'
   AND start_time < NOW() + INTERVAL 3 HOUR AND end_time > NOW();

-- Cost of indexing: every INSERT/UPDATE maintains each index, so only
-- columns used in real predicates are indexed (see report section 7).
SHOW INDEX FROM reservation;
