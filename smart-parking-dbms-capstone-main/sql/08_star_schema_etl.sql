-- =====================================================================
-- File 08 : Analytics star schema + ETL (CO4)
-- Operational (OLTP, 3NF) tables -> reporting (OLAP) star schema.
-- Grain of the fact table: ONE completed parking session (entry + exit).
-- =====================================================================
USE smart_parking;
SET SQL_SAFE_UPDATES = 0;   -- Workbench safe-update mode (error 1175) blocks the ETL's full-table DELETEs

DROP TABLE IF EXISTS fact_parking_session;
DROP TABLE IF EXISTS dim_date;
DROP TABLE IF EXISTS dim_hour;
DROP TABLE IF EXISTS dim_zone;
DROP TABLE IF EXISTS dim_user_type;

CREATE TABLE dim_date (
  date_key   INT PRIMARY KEY,                -- yyyymmdd
  full_date  DATE NOT NULL,
  day_name   VARCHAR(10) NOT NULL,
  month_no   TINYINT NOT NULL,
  year_no    SMALLINT NOT NULL,
  is_weekend TINYINT(1) NOT NULL
) ENGINE=InnoDB;

CREATE TABLE dim_hour (
  hour_key   TINYINT PRIMARY KEY,            -- 0..23
  day_part   VARCHAR(10) NOT NULL            -- NIGHT / MORNING / AFTERNOON / EVENING
) ENGINE=InnoDB;

CREATE TABLE dim_zone (
  zone_key      INT PRIMARY KEY,
  zone_name     VARCHAR(40) NOT NULL,
  zone_category VARCHAR(20) NOT NULL,
  hourly_rate   DECIMAL(6,2) NOT NULL,
  slot_count    INT NOT NULL
) ENGINE=InnoDB;

CREATE TABLE dim_user_type (
  user_type_key TINYINT PRIMARY KEY,
  user_type     VARCHAR(20) NOT NULL
) ENGINE=InnoDB;

CREATE TABLE fact_parking_session (
  session_key   INT PRIMARY KEY,             -- = entry_id
  date_key      INT NOT NULL,
  hour_key      TINYINT NOT NULL,
  zone_key      INT NOT NULL,
  user_type_key TINYINT NOT NULL,
  duration_min  INT NOT NULL,
  fee_charged   DECIMAL(8,2) NOT NULL,
  overstay_flag TINYINT(1) NOT NULL,
  CONSTRAINT fk_f_date FOREIGN KEY (date_key)      REFERENCES dim_date(date_key),
  CONSTRAINT fk_f_hour FOREIGN KEY (hour_key)      REFERENCES dim_hour(hour_key),
  CONSTRAINT fk_f_zone FOREIGN KEY (zone_key)      REFERENCES dim_zone(zone_key),
  CONSTRAINT fk_f_ut   FOREIGN KEY (user_type_key) REFERENCES dim_user_type(user_type_key)
) ENGINE=InnoDB;

DROP PROCEDURE IF EXISTS sp_etl_load_star;
DELIMITER $$
CREATE PROCEDURE sp_etl_load_star()
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;
  -- full reload (simple, idempotent)
  DELETE FROM fact_parking_session;
  DELETE FROM dim_date;
  DELETE FROM dim_hour;
  DELETE FROM dim_zone;
  DELETE FROM dim_user_type;

  -- EXTRACT + TRANSFORM + LOAD : dimensions
  INSERT INTO dim_date
  SELECT DISTINCT CAST(DATE_FORMAT(e.entry_time, '%Y%m%d') AS UNSIGNED), DATE(e.entry_time),
         DAYNAME(e.entry_time), MONTH(e.entry_time), YEAR(e.entry_time),
         DAYOFWEEK(e.entry_time) IN (1, 7)
    FROM entry_log e JOIN exit_log x ON x.entry_id = e.entry_id;

  INSERT INTO dim_hour
  WITH RECURSIVE h(n) AS (SELECT 0 UNION ALL SELECT n + 1 FROM h WHERE n < 23)
  SELECT n, CASE WHEN n < 6 THEN 'NIGHT' WHEN n < 12 THEN 'MORNING' WHEN n < 17 THEN 'AFTERNOON' ELSE 'EVENING' END FROM h;

  INSERT INTO dim_zone
  SELECT z.zone_id, z.zone_name, z.zone_category, z.hourly_rate, COUNT(s.slot_id)
    FROM parking_zone z LEFT JOIN parking_slot s ON s.zone_id = z.zone_id
   GROUP BY z.zone_id, z.zone_name, z.zone_category, z.hourly_rate;

  INSERT INTO dim_user_type VALUES (1,'STUDENT'),(2,'EMPLOYEE'),(3,'RESIDENT'),(4,'VISITOR');

  -- fact table
  INSERT INTO fact_parking_session
  SELECT e.entry_id,
         CAST(DATE_FORMAT(e.entry_time, '%Y%m%d') AS UNSIGNED),
         HOUR(e.entry_time),
         s.zone_id,
         CASE COALESCE(u.user_type, 'VISITOR')
              WHEN 'STUDENT' THEN 1 WHEN 'EMPLOYEE' THEN 2 WHEN 'RESIDENT' THEN 3 ELSE 4 END,
         TIMESTAMPDIFF(MINUTE, e.entry_time, x.exit_time),
         x.fee_charged,
         COALESCE(x.exit_time > r.end_time + INTERVAL 15 MINUTE, 0)
    FROM entry_log e
    JOIN exit_log x          ON x.entry_id   = e.entry_id
    JOIN parking_slot s      ON s.slot_id    = e.slot_id
    LEFT JOIN vehicle ve     ON ve.vehicle_id = e.vehicle_id
    LEFT JOIN app_user u     ON u.user_id    = ve.owner_id
    LEFT JOIN reservation r  ON r.res_id     = e.reservation_id;

  COMMIT;
END$$
DELIMITER ;

CALL sp_etl_load_star();
SELECT 'fact rows' AS what, COUNT(*) AS n FROM fact_parking_session;

-- ---------------- OLAP queries on the star schema ----------------------------------------------
-- A1  Revenue and sessions by zone and day-part with ROLLUP (subtotals + grand total)
SELECT COALESCE(z.zone_name, 'ALL ZONES') AS zone, COALESCE(h.day_part, 'ALL DAY') AS day_part,
       COUNT(*) AS sessions, SUM(f.fee_charged) AS revenue
  FROM fact_parking_session f
  JOIN dim_zone z ON z.zone_key = f.zone_key
  JOIN dim_hour h ON h.hour_key = f.hour_key
 GROUP BY z.zone_name, h.day_part WITH ROLLUP;

-- A2  Overstay rate by user type
SELECT ut.user_type, COUNT(*) AS sessions, SUM(f.overstay_flag) AS overstays,
       ROUND(100 * SUM(f.overstay_flag) / COUNT(*), 1) AS overstay_pct
  FROM fact_parking_session f JOIN dim_user_type ut ON ut.user_type_key = f.user_type_key
 GROUP BY ut.user_type ORDER BY overstay_pct DESC;

-- A3  Weekday vs weekend average duration
SELECT d.is_weekend, ROUND(AVG(f.duration_min), 1) AS avg_min
  FROM fact_parking_session f JOIN dim_date d ON d.date_key = f.date_key
 GROUP BY d.is_weekend;
