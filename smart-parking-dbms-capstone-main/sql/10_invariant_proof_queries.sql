-- =====================================================================
-- File 10 : Proof queries -- integrity invariants + no double booking
-- Run after 09_test_cases.sql. Result 1: every number must be 0.
-- Result 2: shows the bookings made by the tests (e.g. 10-12 and 12-14
-- on the same slot, and NO 11-13 booking). Change the 10 to the day offset
-- used in 09 (@d) if you changed it there.
-- =====================================================================
USE smart_parking;

SELECT 'INV1 overlapping bookings (must be 0)' AS check_name, COUNT(*) AS violations
FROM reservation a JOIN reservation b
  ON a.slot_id = b.slot_id AND a.res_id < b.res_id
 AND a.status = 'CONFIRMED' AND b.status = 'CONFIRMED'
 AND a.start_time < b.end_time AND a.end_time > b.start_time
UNION ALL
SELECT 'INV2 late exit without overstay fine (must be 0)', COUNT(*)
FROM exit_log x JOIN entry_log e ON e.entry_id = x.entry_id
JOIN reservation r ON r.res_id = e.reservation_id
WHERE x.exit_time > r.end_time + INTERVAL 15 MINUTE
  AND NOT EXISTS (SELECT 1 FROM violation v WHERE v.vehicle_id = e.vehicle_id
                  AND v.vt_id = 1 AND v.violation_time = x.exit_time)
UNION ALL
SELECT 'INV3 PAID but underpaid (must be 0)', COUNT(*)
FROM violation v JOIN violation_type vt ON vt.vt_id = v.vt_id
WHERE v.status = 'PAID'
  AND (SELECT COALESCE(SUM(p.amount),0) FROM payment p
       WHERE p.violation_id = v.violation_id AND p.status = 'SUCCESS') < vt.fine_amount
UNION ALL
SELECT 'INV4 slots with 2 open entries (must be 0)', COUNT(*)
FROM (SELECT e.slot_id FROM entry_log e LEFT JOIN exit_log x ON x.entry_id = e.entry_id
      WHERE x.entry_id IS NULL GROUP BY e.slot_id HAVING COUNT(*) > 1) t;

SELECT res_id, vehicle_id, slot_id, start_time, end_time, status
FROM reservation
WHERE start_time >= CURDATE() + INTERVAL 10 DAY
ORDER BY slot_id, start_time;
