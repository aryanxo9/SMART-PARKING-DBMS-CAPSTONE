-- =====================================================================
-- File 05 : Complex SQL query set                                (CO2)
-- Joins (INNER/LEFT/SELF/CROSS), subqueries, set operations, CTEs,
-- window functions, views.   INTERSECT / EXCEPT need MySQL >= 8.0.31.
-- =====================================================================
USE smart_parking;

-- Q1  Currently available slots by zone (view) ----------------------------------
SELECT zone_name, COUNT(*) AS available_slots
  FROM v_current_availability
 WHERE current_status = 'AVAILABLE'
 GROUP BY zone_name
 ORDER BY zone_name;

-- Q2  Dashboard: occupancy per zone right now (view over view) ------------------
SELECT * FROM v_zone_occupancy_now ORDER BY busy_pct DESC;

-- Q3  Average parking duration per zone (INNER JOINs) ---------------------------
SELECT z.zone_name,
       COUNT(*)                                              AS sessions,
       ROUND(AVG(TIMESTAMPDIFF(MINUTE, e.entry_time, x.exit_time)), 1) AS avg_minutes
  FROM entry_log e
  JOIN exit_log x      ON x.entry_id = e.entry_id
  JOIN parking_slot s  ON s.slot_id  = e.slot_id
  JOIN parking_zone z  ON z.zone_id  = s.zone_id
 GROUP BY z.zone_id, z.zone_name
 ORDER BY avg_minutes DESC;

-- Q4  Rank zones by utilisation, last 7 days (CTE + RANK window) -----------------
WITH zone_usage AS (
  SELECT z.zone_id, z.zone_name,
         COUNT(DISTINCT s.slot_id) AS slots,
         COALESCE(SUM(TIMESTAMPDIFF(MINUTE, e.entry_time, x.exit_time)) / 60, 0) AS used_hours
    FROM parking_zone z
    JOIN parking_slot s       ON s.zone_id = z.zone_id
    LEFT JOIN entry_log e     ON e.slot_id = s.slot_id AND e.entry_time >= NOW() - INTERVAL 7 DAY
    LEFT JOIN exit_log  x     ON x.entry_id = e.entry_id
   GROUP BY z.zone_id, z.zone_name
)
SELECT zone_name, slots, ROUND(used_hours, 1) AS used_hours,
       ROUND(100 * used_hours / (slots * 24 * 7), 2) AS utilisation_pct,
       RANK() OVER (ORDER BY used_hours / slots DESC) AS util_rank
  FROM zone_usage;

-- Q5  Peak parking hours (CTE + DENSE_RANK) ----------------------------------------
WITH hourly AS (
  SELECT HOUR(entry_time) AS hr, COUNT(*) AS entries
    FROM entry_log GROUP BY HOUR(entry_time)
)
SELECT hr, entries, DENSE_RANK() OVER (ORDER BY entries DESC) AS peak_rank
  FROM hourly
 ORDER BY peak_rank, hr
 LIMIT 5;

-- Q6  Hourly demand for yesterday (RECURSIVE CTE generates 0..23, LEFT JOIN) ------
WITH RECURSIVE hrs(h) AS (SELECT 0 UNION ALL SELECT h + 1 FROM hrs WHERE h < 23)
SELECT hrs.h AS hour_of_day, COUNT(r.res_id) AS active_reservations
  FROM hrs
  LEFT JOIN reservation r
    ON r.status IN ('COMPLETED','CONFIRMED')
   AND r.start_time < CAST(CURDATE() - INTERVAL 1 DAY AS DATETIME) + INTERVAL (hrs.h + 1) HOUR
   AND r.end_time   > CAST(CURDATE() - INTERVAL 1 DAY AS DATETIME) + INTERVAL hrs.h HOUR
 GROUP BY hrs.h
 ORDER BY hrs.h;

-- Q7  Repeat violators -- CORRELATED subquery ---------------------------------------
SELECT ve.reg_no,
       (SELECT COUNT(*) FROM violation v2 WHERE v2.vehicle_id = ve.vehicle_id) AS total_violations
  FROM vehicle ve
 WHERE (SELECT COUNT(*) FROM violation v2 WHERE v2.vehicle_id = ve.vehicle_id) >= 3
 ORDER BY total_violations DESC;

-- Q8  Repeat violators in the last 90 days (view) -----------------------------------
SELECT * FROM v_repeat_violators ORDER BY violations_90d DESC;

-- Q9  Users with more violations than the average violating user (subquery in HAVING)
SELECT u.user_id, u.full_name, COUNT(*) AS violations
  FROM violation vi
  JOIN vehicle ve  ON ve.vehicle_id = vi.vehicle_id
  JOIN app_user u  ON u.user_id     = ve.owner_id
 GROUP BY u.user_id, u.full_name
HAVING COUNT(*) > (SELECT AVG(cnt) FROM (SELECT COUNT(*) AS cnt
                                           FROM violation v3 JOIN vehicle ve3 ON ve3.vehicle_id = v3.vehicle_id
                                          GROUP BY ve3.owner_id) t)
 ORDER BY violations DESC;

-- Q10 Users who reserved but never entered (SET OPERATION: EXCEPT) --------------------
SELECT DISTINCT ve.owner_id AS user_id
  FROM reservation r JOIN vehicle ve ON ve.vehicle_id = r.vehicle_id
 WHERE r.start_time < NOW()
EXCEPT
SELECT DISTINCT ve.owner_id
  FROM entry_log e JOIN vehicle ve ON ve.vehicle_id = e.vehicle_id
 WHERE e.reservation_id IS NOT NULL;
-- (older MySQL: ... WHERE owner_id NOT IN (SELECT ...) )

-- Q11 Every no-show reservation with the user (LEFT JOIN anti-join) -----------------------
SELECT u.full_name, ve.reg_no, r.res_id, r.start_time
  FROM reservation r
  JOIN vehicle ve  ON ve.vehicle_id = r.vehicle_id
  JOIN app_user u  ON u.user_id     = ve.owner_id
  LEFT JOIN entry_log e ON e.reservation_id = r.res_id
 WHERE e.entry_id IS NULL AND r.status = 'NO_SHOW'
 ORDER BY r.start_time;

-- Q12 Vehicles that had BOTH a reservation and a violation (INTERSECT) --------------------
SELECT vehicle_id FROM reservation
INTERSECT
SELECT vehicle_id FROM violation;

-- Q13 UNION: all contact numbers to notify (owners with open fines + hosts of visitors) ------
SELECT phone, 'Open fine' AS reason
  FROM v_open_violations
UNION
SELECT u.phone, 'Visitor host'
  FROM visitor vi JOIN app_user u ON u.user_id = vi.host_user_id;

-- Q14 Daily revenue with running total and day-over-day change (window functions) ------------
WITH daily AS (
  SELECT DATE(exit_time) AS d, SUM(fee_charged) AS fees
    FROM exit_log GROUP BY DATE(exit_time)
)
SELECT d, fees,
       SUM(fees) OVER (ORDER BY d)                AS running_total,
       LAG(fees) OVER (ORDER BY d)                AS previous_day,
       fees - LAG(fees) OVER (ORDER BY d)         AS change_vs_prev
  FROM daily;

-- Q15 Revenue share per zone (aggregate over aggregate window) -------------------------------
SELECT z.zone_name, SUM(x.fee_charged) AS revenue,
       ROUND(100 * SUM(x.fee_charged) / SUM(SUM(x.fee_charged)) OVER (), 1) AS share_pct
  FROM exit_log x
  JOIN entry_log e     ON e.entry_id = x.entry_id
  JOIN parking_slot s  ON s.slot_id  = e.slot_id
  JOIN parking_zone z  ON z.zone_id  = s.zone_id
 GROUP BY z.zone_id, z.zone_name
 ORDER BY revenue DESC;

-- Q16 Top-2 violators per violation type (ROW_NUMBER with PARTITION BY) ------------------------
SELECT * FROM (
  SELECT vt.type_code, ve.reg_no, COUNT(*) AS cnt,
         ROW_NUMBER() OVER (PARTITION BY vt.type_code ORDER BY COUNT(*) DESC, ve.reg_no) AS rn
    FROM violation vi
    JOIN violation_type vt ON vt.vt_id = vi.vt_id
    JOIN vehicle ve        ON ve.vehicle_id = vi.vehicle_id
   GROUP BY vt.type_code, ve.reg_no
) ranked
WHERE rn <= 2
ORDER BY type_code, rn;

-- Q17 SELF JOIN: owners with more than one registered vehicle --------------------------------------
SELECT u.full_name, v1.reg_no AS vehicle_1, v2.reg_no AS vehicle_2
  FROM vehicle v1
  JOIN vehicle v2 ON v1.owner_id = v2.owner_id AND v1.vehicle_id < v2.vehicle_id
  JOIN app_user u ON u.user_id = v1.owner_id;

-- Q18 CROSS JOIN: zone x violation-type matrix (zeros included) ---------------------------------------
SELECT z.zone_name, vt.type_code, COUNT(vi.violation_id) AS cnt
  FROM parking_zone z
  CROSS JOIN violation_type vt
  LEFT JOIN parking_slot s ON s.zone_id = z.zone_id
  LEFT JOIN violation vi   ON vi.slot_id = s.slot_id AND vi.vt_id = vt.vt_id
 GROUP BY z.zone_name, vt.type_code
 ORDER BY z.zone_name, vt.type_code;

-- Q19 Slots never used (LEFT JOIN + IS NULL) ------------------------------------------------------------
SELECT s.slot_id, z.zone_name, s.slot_code
  FROM parking_slot s
  JOIN parking_zone z ON z.zone_id = s.zone_id
  LEFT JOIN entry_log e ON e.slot_id = s.slot_id
 WHERE e.entry_id IS NULL;

-- Q20 Unpaid fines above a threshold, oldest first (view) --------------------------------------------------
SELECT * FROM v_open_violations WHERE fine_amount >= 200 ORDER BY days_pending DESC;

-- Q21 Reservations whose actual stay exceeded the booked window (join of 3 tables) ---------------------------
SELECT r.res_id, ve.reg_no, r.end_time AS booked_until, x.exit_time,
       TIMESTAMPDIFF(MINUTE, r.end_time, x.exit_time) AS overstay_min
  FROM reservation r
  JOIN vehicle ve   ON ve.vehicle_id = r.vehicle_id
  JOIN entry_log e  ON e.reservation_id = r.res_id
  JOIN exit_log x   ON x.entry_id = e.entry_id
 WHERE x.exit_time > r.end_time
 ORDER BY overstay_min DESC
 LIMIT 10;
