-- ==========================================
-- ICT371 QUESTION 7: Water Meter Readings and Billing
-- ==========================================

-- Clean up existing tables
DROP TABLE IF EXISTS receivable_snapshot, bills, readings, customers CASCADE;

-- ---------------------------------------------------------
-- (a) Database and seed data [6 marks]
-- ---------------------------------------------------------
CREATE TABLE customers (
  customer_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
  reading_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id      INT NOT NULL REFERENCES customers(customer_id),
  reading_month    DATE NOT NULL,
  previous_reading NUMERIC(12,2) NOT NULL CHECK (previous_reading >= 0),
  current_reading  NUMERIC(12,2) NOT NULL CHECK (current_reading >= 0),
  UNIQUE (customer_id, reading_month),
  CONSTRAINT chk_month_start_reading CHECK (reading_month = DATE_TRUNC('month', reading_month)::date)
);

CREATE TABLE bills (
  bill_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  reading_id  INT NOT NULL UNIQUE REFERENCES readings(reading_id),
  charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
  amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (amount_paid >= 0),
  due_on      DATE NOT NULL,
  -- amount_paid between zero and charge
  CONSTRAINT chk_paid_le_charge CHECK (amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
  snapshot_date DATE PRIMARY KEY,
  total_due     NUMERIC(14,2) NOT NULL DEFAULT 0
);

-- ---------------------------------------------------------
-- (b) Function [6 marks]
-- ---------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC) RETURNS NUMERIC
LANGUAGE plpgsql AS $$
BEGIN
  IF p_units IS NULL OR p_units < 0 THEN RAISE EXCEPTION 'Units must be >= 0'; END IF;
  
  -- First 10 units = K5 each, above 10 = K8 each. Zero consumption = zero.
  IF p_units <= 10 THEN 
    RETURN ROUND(p_units * 5, 2);
  ELSE 
    RETURN ROUND((10 * 5) + ((p_units - 10) * 8), 2);
  END IF;
END $$;

-- ---------------------------------------------------------
-- (c) Procedure [8 marks]
-- ---------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE) LANGUAGE plpgsql AS $$
DECLARE v_units NUMERIC;
BEGIN
  SELECT current_reading - previous_reading INTO v_units
  FROM readings WHERE reading_id = p_reading_id;
  
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown reading'; END IF;
  
  IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
    RAISE EXCEPTION 'Bill already exists for reading %', p_reading_id;
  END IF;
  
  -- Insert bill with amount_paid = 0
  INSERT INTO bills(reading_id, charge, amount_paid, due_on)
  VALUES (p_reading_id, fn_water_charge(v_units), 0, p_due_on);
END $$;

-- ---------------------------------------------------------
-- (d) Trigger [8 marks]
-- ---------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_reading_check() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.current_reading < NEW.previous_reading THEN
    RAISE EXCEPTION 'current_reading cannot be below previous_reading';
  END IF;
  RETURN NEW;
END $$;

-- BEFORE INSERT OR UPDATE trigger on readings
CREATE TRIGGER trg_readings_check 
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW EXECUTE FUNCTION trg_reading_check();

-- ---------------------------------------------------------
-- (e) View [5 marks]
-- ---------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name, b.due_on, (b.charge - b.amount_paid) AS outstanding
FROM bills b
JOIN readings r USING (reading_id)
JOIN customers c USING (customer_id)
WHERE b.due_on < CURRENT_DATE AND b.amount_paid < b.charge;

-- ---------------------------------------------------------
-- (f) Index [5 marks]
-- ---------------------------------------------------------
-- Partial index optimizes unpaid bill searches by date
CREATE INDEX idx_bills_due_unpaid ON bills(due_on) WHERE amount_paid < charge;
-- EXPLAIN SELECT * FROM bills WHERE due_on < CURRENT_DATE AND amount_paid < charge;

-- ---------------------------------------------------------
-- (g) Scheduled job [6 marks]
-- ---------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_receivables() LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO receivable_snapshot(snapshot_date, total_due)
  SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid),0)
  FROM bills WHERE amount_paid < charge
  ON CONFLICT (snapshot_date) DO UPDATE 
    SET total_due = EXCLUDED.total_due;
END $$;

-- SELECT cron.schedule('water-daily','30 0 * * *',$$CALL pr_refresh_receivables()$$);

-- ==========================================
-- SEED DATA & TESTING
-- ==========================================

-- 1. Insert customers
INSERT INTO customers(full_name) VALUES ('Alice'),('Bob'),('Charlie');

-- 2. Insert readings (zero, exactly 10, above 10 units)
INSERT INTO readings(customer_id, reading_month, previous_reading, current_reading) VALUES
 (1,'2025-01-01', 0, 0),        -- zero units
 (1,'2025-02-01', 0, 10),       -- exactly 10 units
 (2,'2025-01-01', 0, 15),       -- 15 units
 (2,'2025-02-01', 15, 30),      -- 15 units
 (3,'2025-01-01', 0, 9),        -- 9 units
 (3,'2025-02-01', 9, 25);       -- 16 units

-- 3. Generate bills (Due 30 days ago to make them overdue immediately)
CALL pr_generate_bill(1, CURRENT_DATE-30);
CALL pr_generate_bill(2, CURRENT_DATE-30);
CALL pr_generate_bill(3, CURRENT_DATE-30);
CALL pr_generate_bill(4, CURRENT_DATE-30);
CALL pr_generate_bill(5, CURRENT_DATE-30);
CALL pr_generate_bill(6, CURRENT_DATE-30);

-- 4. Pay one bill fully so it disappears from overdue view
UPDATE bills SET amount_paid = charge WHERE bill_id = 1;
-- Pay another partially
UPDATE bills SET amount_paid = 50 WHERE bill_id = 3;

-- 5. Check the overdue view
SELECT * FROM v_overdue_bills;

-- 6. Check the generated bills
SELECT * FROM bills;

-- 7. Refresh receivables and check
CALL pr_refresh_receivables();
SELECT * FROM receivable_snapshot;