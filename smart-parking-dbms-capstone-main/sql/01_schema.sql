-- =====================================================================
-- PROJECT 6 : SMART PARKING MANAGEMENT & ALLOCATION SYSTEM
-- File 01 : Schema (DDL) -- MySQL 8.0.31+ (InnoDB)
-- Covers  : CO1 (keys, integrity constraints, normalised design), CO2 (DDL)
-- =====================================================================
DROP DATABASE IF EXISTS smart_parking;
CREATE DATABASE smart_parking CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE smart_parking;

-- 1. DEPARTMENT ------------------------------------------------------
CREATE TABLE department (
  dept_id    INT AUTO_INCREMENT PRIMARY KEY,
  dept_name  VARCHAR(60) NOT NULL UNIQUE
) ENGINE=InnoDB;

-- 2. APP_USER (student / employee / resident) -----------------------
CREATE TABLE app_user (
  user_id    INT AUTO_INCREMENT PRIMARY KEY,
  full_name  VARCHAR(80)  NOT NULL,
  email      VARCHAR(100) NOT NULL UNIQUE,
  phone      CHAR(10)     NOT NULL,
  user_type  ENUM('STUDENT','EMPLOYEE','RESIDENT') NOT NULL,
  dept_id    INT NULL,
  status     ENUM('ACTIVE','SUSPENDED') NOT NULL DEFAULT 'ACTIVE',
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT chk_user_phone CHECK (phone REGEXP '^[0-9]{10}$'),
  CONSTRAINT fk_user_dept FOREIGN KEY (dept_id) REFERENCES department(dept_id)
      ON UPDATE CASCADE ON DELETE SET NULL
) ENGINE=InnoDB;

-- 3. VEHICLE_TYPE ----------------------------------------------------
CREATE TABLE vehicle_type (
  vtype_id   INT AUTO_INCREMENT PRIMARY KEY,
  type_name  VARCHAR(20) NOT NULL UNIQUE,
  wheels     TINYINT NOT NULL,
  CONSTRAINT chk_wheels CHECK (wheels IN (2,4))
) ENGINE=InnoDB;

-- 4. VEHICLE ---------------------------------------------------------
CREATE TABLE vehicle (
  vehicle_id INT AUTO_INCREMENT PRIMARY KEY,
  reg_no     VARCHAR(15) NOT NULL UNIQUE,
  owner_id   INT NOT NULL,
  vtype_id   INT NOT NULL,
  make_model VARCHAR(40),
  CONSTRAINT fk_veh_owner FOREIGN KEY (owner_id) REFERENCES app_user(user_id)
      ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_veh_type  FOREIGN KEY (vtype_id) REFERENCES vehicle_type(vtype_id)
) ENGINE=InnoDB;

-- 5. PARKING_ZONE ----------------------------------------------------
CREATE TABLE parking_zone (
  zone_id       INT AUTO_INCREMENT PRIMARY KEY,
  zone_name     VARCHAR(40) NOT NULL UNIQUE,
  zone_category ENUM('GENERAL','STAFF','VISITOR','TWO_WHEELER','EV') NOT NULL,
  hourly_rate   DECIMAL(6,2) NOT NULL,
  CONSTRAINT chk_rate CHECK (hourly_rate >= 0)
) ENGINE=InnoDB;

-- 6. PARKING_SLOT ----------------------------------------------------
CREATE TABLE parking_slot (
  slot_id   INT AUTO_INCREMENT PRIMARY KEY,
  zone_id   INT NOT NULL,
  slot_code VARCHAR(10) NOT NULL,
  vtype_id  INT NOT NULL,                       -- type of vehicle the slot fits
  status    ENUM('ACTIVE','MAINTENANCE') NOT NULL DEFAULT 'ACTIVE',
  CONSTRAINT uq_zone_slot UNIQUE (zone_id, slot_code),
  CONSTRAINT fk_slot_zone FOREIGN KEY (zone_id)  REFERENCES parking_zone(zone_id) ON DELETE CASCADE,
  CONSTRAINT fk_slot_type FOREIGN KEY (vtype_id) REFERENCES vehicle_type(vtype_id)
) ENGINE=InnoDB;

-- 7. SECURITY_STAFF --------------------------------------------------
CREATE TABLE security_staff (
  staff_id  INT AUTO_INCREMENT PRIMARY KEY,
  full_name VARCHAR(80) NOT NULL,
  shift     ENUM('MORNING','EVENING','NIGHT') NOT NULL
) ENGINE=InnoDB;

-- 8. RESERVATION -----------------------------------------------------
-- The booker is always the vehicle owner, so user_id is NOT stored here (3NF).
CREATE TABLE reservation (
  res_id       INT AUTO_INCREMENT PRIMARY KEY,
  vehicle_id   INT NOT NULL,
  slot_id      INT NOT NULL,
  start_time   DATETIME NOT NULL,
  end_time     DATETIME NOT NULL,
  status       ENUM('CONFIRMED','CANCELLED','COMPLETED','NO_SHOW') NOT NULL DEFAULT 'CONFIRMED',
  created_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  cancelled_at DATETIME NULL,
  CONSTRAINT chk_res_window CHECK (end_time > start_time),
  CONSTRAINT chk_res_max12h CHECK (TIMESTAMPDIFF(MINUTE, start_time, end_time) <= 720),
  CONSTRAINT fk_res_vehicle FOREIGN KEY (vehicle_id) REFERENCES vehicle(vehicle_id),
  CONSTRAINT fk_res_slot    FOREIGN KEY (slot_id)    REFERENCES parking_slot(slot_id)
) ENGINE=InnoDB;

-- 9. VISITOR ---------------------------------------------------------
CREATE TABLE visitor (
  visitor_id   INT AUTO_INCREMENT PRIMARY KEY,
  full_name    VARCHAR(80) NOT NULL,
  phone        CHAR(10)    NOT NULL,
  vehicle_reg  VARCHAR(15) NOT NULL,
  host_user_id INT NOT NULL,
  CONSTRAINT fk_visitor_host FOREIGN KEY (host_user_id) REFERENCES app_user(user_id)
) ENGINE=InnoDB;

-- 10. VISITOR_PASS ---------------------------------------------------
CREATE TABLE visitor_pass (
  pass_id    INT AUTO_INCREMENT PRIMARY KEY,
  pass_code  CHAR(8) NOT NULL UNIQUE,
  visitor_id INT NOT NULL,
  slot_id    INT NOT NULL,
  valid_from DATETIME NOT NULL,
  valid_to   DATETIME NOT NULL,
  status     ENUM('ACTIVE','EXPIRED','REVOKED') NOT NULL DEFAULT 'ACTIVE',
  CONSTRAINT chk_pass_window CHECK (valid_to > valid_from),
  CONSTRAINT fk_pass_visitor FOREIGN KEY (visitor_id) REFERENCES visitor(visitor_id) ON DELETE CASCADE,
  CONSTRAINT fk_pass_slot    FOREIGN KEY (slot_id)    REFERENCES parking_slot(slot_id)
) ENGINE=InnoDB;

-- 11. ENTRY_LOG ------------------------------------------------------
-- Exactly one of vehicle_id (residents) / pass_id (visitors) identifies who entered.
CREATE TABLE entry_log (
  entry_id       INT AUTO_INCREMENT PRIMARY KEY,
  vehicle_id     INT NULL,
  pass_id        INT NULL,
  reservation_id INT NULL,
  slot_id        INT NOT NULL,
  entry_time     DATETIME NOT NULL,
  CONSTRAINT chk_entry_actor CHECK ((vehicle_id IS NULL) + (pass_id IS NULL) = 1),
  CONSTRAINT chk_entry_res   CHECK (reservation_id IS NULL OR vehicle_id IS NOT NULL),
  CONSTRAINT fk_entry_vehicle FOREIGN KEY (vehicle_id)     REFERENCES vehicle(vehicle_id),
  CONSTRAINT fk_entry_pass    FOREIGN KEY (pass_id)        REFERENCES visitor_pass(pass_id),
  CONSTRAINT fk_entry_res     FOREIGN KEY (reservation_id) REFERENCES reservation(res_id),
  CONSTRAINT fk_entry_slot    FOREIGN KEY (slot_id)        REFERENCES parking_slot(slot_id)
) ENGINE=InnoDB;

-- 12. EXIT_LOG (1:1 with ENTRY_LOG) ----------------------------------
CREATE TABLE exit_log (
  exit_id      INT AUTO_INCREMENT PRIMARY KEY,
  entry_id     INT NOT NULL UNIQUE,
  exit_time    DATETIME NOT NULL,
  fee_charged  DECIMAL(8,2) NOT NULL DEFAULT 0,
  CONSTRAINT fk_exit_entry FOREIGN KEY (entry_id) REFERENCES entry_log(entry_id)
) ENGINE=InnoDB;

-- 13. VIOLATION_TYPE -------------------------------------------------
CREATE TABLE violation_type (
  vt_id       INT AUTO_INCREMENT PRIMARY KEY,
  type_code   VARCHAR(20)  NOT NULL UNIQUE,
  description VARCHAR(100) NOT NULL,
  fine_amount DECIMAL(8,2) NOT NULL,
  CONSTRAINT chk_fine CHECK (fine_amount > 0)
) ENGINE=InnoDB;

-- 14. VIOLATION ------------------------------------------------------
CREATE TABLE violation (
  violation_id   INT AUTO_INCREMENT PRIMARY KEY,
  vehicle_id     INT NOT NULL,
  slot_id        INT NULL,
  vt_id          INT NOT NULL,
  violation_time DATETIME NOT NULL,
  recorded_by    INT NULL,                       -- NULL = auto-generated by trigger
  status         ENUM('OPEN','PAID','WAIVED') NOT NULL DEFAULT 'OPEN',
  remarks        VARCHAR(150),
  CONSTRAINT fk_viol_vehicle FOREIGN KEY (vehicle_id)  REFERENCES vehicle(vehicle_id),
  CONSTRAINT fk_viol_slot    FOREIGN KEY (slot_id)     REFERENCES parking_slot(slot_id),
  CONSTRAINT fk_viol_type    FOREIGN KEY (vt_id)       REFERENCES violation_type(vt_id),
  CONSTRAINT fk_viol_staff   FOREIGN KEY (recorded_by) REFERENCES security_staff(staff_id)
) ENGINE=InnoDB;

-- 15. PAYMENT --------------------------------------------------------
CREATE TABLE payment (
  payment_id   INT AUTO_INCREMENT PRIMARY KEY,
  violation_id INT NOT NULL,
  amount       DECIMAL(8,2) NOT NULL,
  method       ENUM('UPI','CARD','CASH') NOT NULL,
  paid_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  status       ENUM('SUCCESS','FAILED') NOT NULL DEFAULT 'SUCCESS',
  CONSTRAINT chk_pay_amt CHECK (amount > 0),
  CONSTRAINT fk_pay_viol FOREIGN KEY (violation_id) REFERENCES violation(violation_id)
) ENGINE=InnoDB;

-- 16. AUDIT_LOG ------------------------------------------------------
CREATE TABLE audit_log (
  audit_id   BIGINT AUTO_INCREMENT PRIMARY KEY,
  table_name VARCHAR(40)  NOT NULL,
  action     VARCHAR(20)  NOT NULL,
  record_id  INT          NOT NULL,
  details    VARCHAR(255),
  changed_by VARCHAR(100) NOT NULL,
  changed_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;
