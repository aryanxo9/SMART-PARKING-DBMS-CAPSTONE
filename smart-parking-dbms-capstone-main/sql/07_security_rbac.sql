-- =====================================================================
-- File 07 : Security -- RBAC, least privilege, SQL-injection prevention  (CO3)
-- Run as root / an admin account.
-- =====================================================================
USE smart_parking;

DROP ROLE IF EXISTS 'parking_admin', 'parking_security', 'parking_user', 'parking_analyst';
CREATE ROLE 'parking_admin', 'parking_security', 'parking_user', 'parking_analyst';

-- ---- ADMIN: full control of the schema ---------------------------------------
GRANT ALL PRIVILEGES ON smart_parking.* TO 'parking_admin';

-- ---- SECURITY STAFF: gate operations + violations, read-only on the rest ---------
GRANT SELECT ON smart_parking.v_current_availability TO 'parking_security';
GRANT SELECT ON smart_parking.v_open_violations      TO 'parking_security';
GRANT SELECT ON smart_parking.v_repeat_violators     TO 'parking_security';
GRANT SELECT ON smart_parking.vehicle                TO 'parking_security';
GRANT SELECT, INSERT ON smart_parking.violation      TO 'parking_security';
GRANT EXECUTE ON PROCEDURE smart_parking.sp_record_entry   TO 'parking_security';
GRANT EXECUTE ON PROCEDURE smart_parking.sp_record_exit    TO 'parking_security';
GRANT EXECUTE ON PROCEDURE smart_parking.sp_pay_violation  TO 'parking_security';
GRANT EXECUTE ON PROCEDURE smart_parking.sp_issue_visitor_pass TO 'parking_security';

-- ---- NORMAL USER: only through procedures and own-data views ----------------------
GRANT SELECT ON smart_parking.v_current_availability TO 'parking_user';
GRANT SELECT ON smart_parking.v_reservation_details  TO 'parking_user';
GRANT EXECUTE ON PROCEDURE smart_parking.sp_reserve_slot       TO 'parking_user';
GRANT EXECUTE ON PROCEDURE smart_parking.sp_allocate_slot      TO 'parking_user';
GRANT EXECUTE ON PROCEDURE smart_parking.sp_cancel_reservation TO 'parking_user';

-- ---- ANALYST: reports only, no personal tables ---------------------------------------
GRANT SELECT ON smart_parking.v_zone_occupancy_now TO 'parking_analyst';
GRANT SELECT ON smart_parking.v_repeat_violators   TO 'parking_analyst';

-- ---- Accounts (change the passwords!) -------------------------------------------------
DROP USER IF EXISTS 'pk_admin'@'localhost', 'pk_guard'@'localhost', 'pk_user'@'localhost', 'pk_analyst'@'localhost';
CREATE USER 'pk_admin'@'localhost'   IDENTIFIED BY 'Admin#2026';
CREATE USER 'pk_guard'@'localhost'   IDENTIFIED BY 'Guard#2026';
CREATE USER 'pk_user'@'localhost'    IDENTIFIED BY 'User#2026';
CREATE USER 'pk_analyst'@'localhost' IDENTIFIED BY 'Analyst#2026';
GRANT 'parking_admin'   TO 'pk_admin'@'localhost';
GRANT 'parking_security' TO 'pk_guard'@'localhost';
GRANT 'parking_user'    TO 'pk_user'@'localhost';
GRANT 'parking_analyst' TO 'pk_analyst'@'localhost';
SET DEFAULT ROLE ALL TO 'pk_admin'@'localhost', 'pk_guard'@'localhost', 'pk_user'@'localhost', 'pk_analyst'@'localhost';

-- Procedures/triggers run with the DEFINER's rights (SQL SECURITY DEFINER, the default),
-- so a user who may only EXECUTE sp_reserve_slot can still create a reservation
-- through it, but cannot touch the reservation table directly.

SHOW GRANTS FOR 'pk_user'@'localhost' USING 'parking_user';

-- ---------------------------------------------------------------------------------------
-- NEGATIVE TESTS (run each in a session logged in as the named user; all must FAIL)
--   mysql -u pk_user -p smart_parking
--     SELECT * FROM payment;                         -- ERROR 1142 SELECT denied
--     DELETE FROM reservation;                       -- ERROR 1142 DELETE denied
--     SELECT * FROM app_user;                        -- ERROR 1142 (personal data hidden)
--     CALL sp_pay_violation(1,100,'UPI',0,@m);       -- ERROR 1370 EXECUTE denied
--   mysql -u pk_guard -p smart_parking
--     DELETE FROM violation WHERE violation_id=1;    -- ERROR 1142
--     UPDATE parking_zone SET hourly_rate = 0;       -- ERROR 1142
--   mysql -u pk_analyst -p smart_parking
--     SELECT * FROM vehicle;                         -- ERROR 1142
-- POSITIVE TESTS
--   pk_user:  SELECT * FROM v_current_availability LIMIT 5;  -- OK
--   pk_user:  CALL sp_reserve_slot(...);                      -- OK
--   pk_guard: CALL sp_record_exit(...);                       -- OK
-- ---------------------------------------------------------------------------------------

-- =====================================================================
-- SQL-INJECTION DEMONSTRATION (server-side prepared statements)
-- =====================================================================
-- VULNERABLE: string concatenation -----------------------------------------------------------
SET @input = "DL01CA1007' OR '1'='1";                        -- attacker-controlled text
SET @bad   = CONCAT("SELECT reg_no, owner_id FROM vehicle WHERE reg_no = '", @input, "'");
SELECT @bad AS generated_sql;                                -- ... WHERE reg_no = 'DL01CA1007' OR '1'='1'
PREPARE s_bad FROM @bad;
EXECUTE s_bad;                                               -- returns ALL 70 vehicles  (injection works)
DEALLOCATE PREPARE s_bad;

-- SAFE: parameterised query -------------------------------------------------------------------
PREPARE s_ok FROM 'SELECT reg_no, owner_id FROM vehicle WHERE reg_no = ?';
EXECUTE s_ok USING @input;                                   -- 0 rows: the whole string is treated as DATA
DEALLOCATE PREPARE s_ok;

-- Second example: tautology / UNION attack on a user lookup ---------------------------------------
SET @input2 = "x' UNION SELECT email, phone FROM app_user -- ";
SET @bad2   = CONCAT("SELECT reg_no, owner_id FROM vehicle WHERE reg_no = '", @input2, "'");
-- PREPARE s FROM @bad2; EXECUTE s;     -- would leak e-mails and phone numbers
PREPARE s_ok2 FROM 'SELECT reg_no, owner_id FROM vehicle WHERE reg_no = ?';
EXECUTE s_ok2 USING @input2;                                 -- 0 rows
DEALLOCATE PREPARE s_ok2;

-- DEFENCE IN DEPTH used in this project:
--  1. parameterised queries / CALL with parameters only (see app/parking_app.py);
--  2. least-privilege roles: even a successful injection by pk_user cannot read app_user/payment;
--  3. stored procedures validate every input and use typed parameters (INT, DATETIME);
--  4. multi-statement execution is disabled in the application connector;
--  5. DB errors are logged, never echoed to the end user.
