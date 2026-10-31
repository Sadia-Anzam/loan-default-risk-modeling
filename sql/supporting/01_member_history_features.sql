-- 01_member_history_features.sql
-- Build member-level historical loan-risk features.

-- Combine historical provision records from the available periods.
DROP TABLE IF EXISTS member_loan_history;

CREATE TABLE member_loan_history AS
SELECT
    h.member_key,
    h.loan_key,
    h.product_key,
    h.disbursement_date,
    h.disbursed_amount,
    MAX(h.days_past_due) AS historical_days_past_due,
    MAX(h.provision_rate) AS historical_provision_rate,
    CASE
        WHEN MAX(h.days_past_due) BETWEEN 0 AND 10 THEN 0
        WHEN MAX(h.days_past_due) BETWEEN 11 AND 100 THEN 1
        WHEN MAX(h.days_past_due) BETWEEN 101 AND 200 THEN 2
        WHEN MAX(h.days_past_due) BETWEEN 201 AND 300 THEN 3
        ELSE 5
    END AS historical_risk_band
FROM (
    SELECT * FROM source_loan_provision_current
    UNION
    SELECT * FROM source_loan_provision_archive
) h
JOIN eligible_member_scope s
  ON s.member_key = h.member_key
GROUP BY
    h.member_key,
    h.loan_key,
    h.product_key,
    h.disbursement_date,
    h.disbursed_amount;

CREATE INDEX member_loan_history_member_loan_idx
    ON member_loan_history (member_key, loan_key);

-- Add a fallback for closed loans without a provision-history record.
DROP TABLE IF EXISTS closed_loan_history_fallback;

CREATE TABLE closed_loan_history_fallback AS
SELECT
    l.member_key,
    l.loan_key,
    l.product_key,
    l.disbursement_date,
    l.disbursed_amount,
    CURRENT_DATE - l.last_overdue_date AS historical_days_past_due,
    100.0 AS historical_provision_rate,
    5 AS historical_risk_band
FROM source_loan_account l
LEFT JOIN member_loan_history h
  ON h.loan_key = l.loan_key
 AND h.member_key = l.member_key
WHERE l.is_closed = TRUE
  AND h.loan_key IS NULL;

INSERT INTO member_loan_history
SELECT *
FROM closed_loan_history_fallback;

-- For each loan, summarize only the member's earlier loan history.
DROP TABLE IF EXISTS member_prior_loan_features;

CREATE TABLE member_prior_loan_features AS
SELECT
    h.member_key,
    h.loan_key,
    h.disbursement_date,
    h.historical_days_past_due,
    h.historical_risk_band,
    MAX(h.historical_days_past_due) OVER (
        PARTITION BY h.member_key
        ORDER BY h.disbursement_date, h.loan_key
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
    ) AS prior_max_days_past_due,
    COUNT(h.loan_key) OVER (
        PARTITION BY h.member_key
        ORDER BY h.disbursement_date, h.loan_key
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
    ) AS prior_loan_count
FROM member_loan_history h;

CREATE INDEX member_prior_loan_features_member_loan_idx
    ON member_prior_loan_features (member_key, loan_key);

-- Attach the historical features to the modeling population.
ALTER TABLE loan_modeling_dataset
    ADD COLUMN IF NOT EXISTS current_loan_days_past_due INTEGER,
    ADD COLUMN IF NOT EXISTS prior_max_days_past_due INTEGER,
    ADD COLUMN IF NOT EXISTS prior_loan_count INTEGER,
    ADD COLUMN IF NOT EXISTS historical_risk_band INTEGER;

UPDATE loan_modeling_dataset d
SET
    current_loan_days_past_due = h.historical_days_past_due,
    prior_max_days_past_due = h.prior_max_days_past_due,
    prior_loan_count = h.prior_loan_count,
    historical_risk_band = h.historical_risk_band
FROM member_prior_loan_features h
WHERE d.member_key = h.member_key
  AND d.loan_key = h.loan_key;

-- Check coverage after the update.
SELECT
    COUNT(*) AS dataset_rows,
    COUNT(*) FILTER (
        WHERE prior_loan_count IS NULL
    ) AS rows_without_prior_history
FROM loan_modeling_dataset;
