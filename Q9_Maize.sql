/* =====================================================================
   ICT371  QUESTION 9 - Farmer Cooperative Maize Deliveries       [50]
   Rates: grade A K5/kg, B K4/kg, C K3/kg. Values must be calculated the
   same way even for direct INSERTs.
   ===================================================================== */
DROP SCHEMA IF EXISTS q9 CASCADE;
CREATE SCHEMA q9;
SET search_path TO q9, public;
 
-- Test helper (not part of the marked answer)
CREATE PROCEDURE expect_error(p_sql text) LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RAISE NOTICE 'UNEXPECTED: statement succeeded -> %', p_sql;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Rejected as expected -> %', SQLERRM;
END $$;
 
 
/* ---------------------------------------------------------------------
   (a) DATABASE AND SEED DATA                                       [6]
   - weight_kg NUMERIC(10,2); unit_rate NUMERIC(10,2); total_value
     NUMERIC(12,2): exact numeric types for weight and money.
   - unit_rate and total_value are NOT NULL even though inserts do not
     supply them: PostgreSQL runs BEFORE triggers first and checks NOT
     NULL afterwards, so the trigger fills them in time.
   - Deliveries are loaded AFTER the trigger is installed (brief).
   --------------------------------------------------------------------- */
CREATE TABLE farmers (
    farmer_id      INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    farmer_number  VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);
 
CREATE TABLE deliveries (
    delivery_id   INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    farmer_id     INTEGER       NOT NULL REFERENCES farmers (farmer_id),
    grade         CHAR(1)       NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg     NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate     NUMERIC(10,2) NOT NULL,
    total_value   NUMERIC(12,2) NOT NULL,
    delivered_on  DATE          NOT NULL,
    is_paid       BOOLEAN       NOT NULL DEFAULT FALSE
);
 
CREATE TABLE daily_purchases (
    purchase_date  DATE          PRIMARY KEY,
    total_weight   NUMERIC(14,2) NOT NULL CHECK (total_weight >= 0),
    total_value    NUMERIC(14,2) NOT NULL CHECK (total_value  >= 0)
);
 
INSERT INTO farmers (farmer_number, full_name) VALUES
    ('KBW-001', 'Mwila Banda'),
    ('KBW-002', 'Chanda Phiri'),
    ('KBW-003', 'Natasha Zulu');
 
 
/* ---------------------------------------------------------------------
   (b) FUNCTION fn_maize_rate                                       [6]
   - CASE maps the grade to its rate; anything else -> NULL -> exception.
   - upper() accepts 'a' as 'A'.
   - IMMUTABLE: depends only on its input.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_rate NUMERIC(10,2);
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade must not be NULL';
    END IF;
 
    v_rate := CASE upper(trim(p_grade))
                  WHEN 'A' THEN 5.00
                  WHEN 'B' THEN 4.00
                  WHEN 'C' THEN 3.00
              END;
 
    IF v_rate IS NULL THEN
        RAISE EXCEPTION 'Unsupported grade "%": use A, B or C', p_grade;
    END IF;
 
    RETURN v_rate;
END;
$$;
 
 
/* ---------------------------------------------------------------------
   (c) PROCEDURE pr_receive_delivery                                [8]
   - Rejects an unknown farmer, NULL / non-positive weight, NULL or
     future date, and a bad grade (by calling fn_maize_rate, which
     raises for anything other than A/B/C).
   - Inserts ONLY the basic fields with is_paid = FALSE. unit_rate and
     total_value are left out on purpose: the trigger supplies them.
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INTEGER,
    p_grade     TEXT,
    p_weight    NUMERIC,
    p_date      DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer id %', p_farmer_id;
    END IF;
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Invalid weight %: must be greater than zero', p_weight;
    END IF;
    IF p_date IS NULL OR p_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'Invalid delivery date %', p_date;
    END IF;
    PERFORM fn_maize_rate(p_grade);          -- validates the grade
 
    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, upper(trim(p_grade)), p_weight, p_date, FALSE);
END;
$$;
 
 
/* ---------------------------------------------------------------------
   (d) TRIGGER: BEFORE INSERT OR UPDATE, FOR EACH ROW              [8]
   - BEFORE trigger, so it can CHANGE the row (assign to NEW) before it
     is stored; RETURN NEW passes the modified row on.
   - Whatever unit_rate / total_value a direct INSERT or UPDATE supplies
     is OVERWRITTEN with the official calculation, so direct SQL cannot
     bypass the pricing rule.
   - Note: on UPDATE (e.g. marking is_paid) the value is recalculated
     from the same grade and weight, so it stays the same while rates
     are fixed.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION trg_fn_deliveries_pricing()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Invalid weight %: must be greater than zero', NEW.weight_kg;
    END IF;
 
    NEW.grade       := upper(NEW.grade);
    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := round(NEW.weight_kg * NEW.unit_rate, 2);
 
    RETURN NEW;
END;
$$;
 
CREATE TRIGGER trg_deliveries_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_fn_deliveries_pricing();
 
 
-- (a) continued: six deliveries, all grades, paid and unpaid ----------
CALL pr_receive_delivery(1, 'A', 500.00, CURRENT_DATE - 2);
CALL pr_receive_delivery(1, 'B', 300.00, CURRENT_DATE - 1);
CALL pr_receive_delivery(2, 'C', 450.50, CURRENT_DATE - 2);
CALL pr_receive_delivery(2, 'A', 200.00, CURRENT_DATE - 1);
CALL pr_receive_delivery(3, 'B', 150.00, CURRENT_DATE - 1);
-- Direct SQL with a WRONG rate and value: the trigger corrects them
INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid)
VALUES (3, 'C', 100.00, 99.00, 9900.00, CURRENT_DATE - 1, FALSE);
-- Payments: Mwila's B, and all of Natasha's deliveries
UPDATE deliveries SET is_paid = TRUE WHERE delivery_id IN (2, 5, 6);
 
SELECT * FROM deliveries ORDER BY delivery_id;   -- row 6 shows rate 3.00, value 300.00
 
-- Tests for (b)
SELECT fn_maize_rate('A') AS a, fn_maize_rate('b') AS b, fn_maize_rate('C') AS c;
CALL expect_error('SELECT fn_maize_rate(NULL)');
CALL expect_error($q$SELECT fn_maize_rate('D')$q$);
 
-- Tests for (c)
CALL expect_error($q$CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE)$q$);   -- unknown farmer
CALL expect_error($q$CALL pr_receive_delivery(1, 'Z', 10, CURRENT_DATE)$q$);    -- bad grade
CALL expect_error($q$CALL pr_receive_delivery(1, 'A', 0, CURRENT_DATE)$q$);     -- zero weight
 
-- Tests for (d)
CALL expect_error($q$INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on)
                     VALUES (1, 'A', -5, CURRENT_DATE)$q$);                    -- negative weight
UPDATE deliveries SET weight_kg = 520.00 WHERE delivery_id = 1;                -- re-weighed
SELECT delivery_id, weight_kg, unit_rate, total_value
FROM   deliveries WHERE delivery_id = 1;                                       -- 2600.00 recalculated
 
 
/* ---------------------------------------------------------------------
   (e) VIEW v_farmer_amount_due                                     [5]
   - LEFT JOIN from farmers keeps every farmer.
   - "NOT d.is_paid" is placed in the ON clause: in WHERE it would remove
     farmers whose deliveries are all paid.
   - SUM of no rows is NULL -> COALESCE(..., 0) shows 0.
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value), 0)::NUMERIC(14,2) AS amount_due
FROM   farmers f
LEFT JOIN deliveries d
       ON d.farmer_id = f.farmer_id
      AND NOT d.is_paid
GROUP  BY f.farmer_id, f.farmer_number, f.full_name;
 
SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;   -- KBW-003 shows 0
 
 
/* ---------------------------------------------------------------------
   (f) COMPOSITE INDEX                                               [5]
   Query: WHERE farmer_id = ? AND delivered_on BETWEEN ? AND ?
   - (farmer_id, delivered_on): equality first, range second, so one
     farmer's deliveries are stored together in date order and the range
     is read as one contiguous slice of the index.
   - Also indexes the FK column and helps the view's join on farmer_id.
   --------------------------------------------------------------------- */
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);
ANALYZE deliveries;
 
EXPLAIN
SELECT delivery_id, grade, weight_kg, total_value, delivered_on
FROM   deliveries
WHERE  farmer_id = 1
AND    delivered_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
 
SET enable_seqscan = off;     -- tiny table; show the plan used at real volume
EXPLAIN ANALYZE
SELECT delivery_id, grade, weight_kg, total_value, delivered_on
FROM   deliveries
WHERE  farmer_id = 1
AND    delivered_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;
 
 
/* ---------------------------------------------------------------------
   (g) SCHEDULED JOB                                                 [6]
   - Sums that day's weight and value (0 when no deliveries).
   - ON CONFLICT ... DO UPDATE SET col = EXCLUDED.col REPLACES the totals;
     it never adds to them, so reruns do not double-count.
   - '30 1 * * *' = 01:30 daily, for the previous day.
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
SET search_path = q9, public
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;
 
    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day,
           COALESCE(SUM(weight_kg), 0),
           COALESCE(SUM(total_value), 0)
    FROM   deliveries
    WHERE  delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE
    SET    total_weight = EXCLUDED.total_weight,
           total_value  = EXCLUDED.total_value;
END;
$$;
 
CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);     -- rerun: replaced, not doubled
CALL pr_refresh_purchases(CURRENT_DATE - 2);
SELECT * FROM daily_purchases ORDER BY purchase_date;
 
SELECT cron.schedule(
    'q9_refresh_purchases',
    '30 1 * * *',
    $$CALL q9.pr_refresh_purchases(CURRENT_DATE - 1)$$
);
 
SELECT jobid, jobname, schedule, command, active
FROM   cron.job
WHERE  jobname = 'q9_refresh_purchases';
 
