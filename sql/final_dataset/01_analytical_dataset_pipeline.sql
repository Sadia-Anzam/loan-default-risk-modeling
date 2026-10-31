-- 01_analytical_dataset_pipeline.sql
-- Sanitized representation of the final v4 dataset workflow.
-- Source names, identifiers and operational codes have been generalized.

-- 1. Define loans with enough observed lifecycle for an early prediction.
DROP TABLE IF EXISTS eligible_loan_scope;

CREATE TABLE eligible_loan_scope AS
SELECT
    l.loan_key,
    l.member_key,
    l.office_key,
    l.project_key,
    l.product_key,
    l.disbursement_date,
    l.original_duration_days,
    l.original_installment_count,
    l.disbursed_amount,
    l.installment_amount,
    l.interest_rate,
    l.repayment_frequency,
    ROUND(l.original_installment_count / 3.0) AS observation_installment_no,
    (l.original_installment_count / 3.0) * l.installment_amount
        AS scheduled_amount_at_observation
FROM source_loan l
JOIN source_loan_eligibility e
  ON e.loan_key = l.loan_key
WHERE l.disbursement_date >= DATE '2022-01-01'
  AND l.is_valid_record = TRUE
  AND l.is_one_time_product = FALSE
  AND l.is_special_scope = FALSE
  AND l.current_installment_no >=
      ROUND(l.original_installment_count / 3.0);

-- 2. Remove populations outside the study definition.
DROP TABLE IF EXISTS excluded_loan_scope;

CREATE TABLE excluded_loan_scope AS
SELECT DISTINCT loan_key
FROM source_transaction_event
WHERE is_valid_record = TRUE
  AND event_category = 'OUT_OF_SCOPE_MEMBER_EVENT';

INSERT INTO excluded_loan_scope
SELECT DISTINCT s.loan_key
FROM eligible_loan_scope s
JOIN source_member_event m
  ON m.member_key = s.member_key
WHERE s.disbursement_date < m.event_date
  AND s.original_duration_days + s.disbursement_date > m.event_date
  AND m.event_category = 'RELEVANT_INCIDENT';

INSERT INTO excluded_loan_scope
SELECT DISTINCT s.loan_key
FROM eligible_loan_scope s
WHERE s.interest_rate = 0;

DELETE FROM eligible_loan_scope s
USING excluded_loan_scope x
WHERE s.loan_key = x.loan_key;

CREATE INDEX eligible_loan_scope_loan_key_idx
    ON eligible_loan_scope (loan_key);

-- 3. Identify the scheduled collection dates within each loan.
DROP TABLE IF EXISTS scoped_collection_dates;

CREATE TABLE scoped_collection_dates AS
SELECT
    c.loan_key,
    c.collection_date,
    s.disbursement_date,
    s.observation_installment_no,
    DENSE_RANK() OVER (
        PARTITION BY c.loan_key
        ORDER BY c.collection_date
    ) AS collection_sequence
FROM source_collection_schedule c
JOIN eligible_loan_scope s
  ON s.loan_key = c.loan_key
WHERE c.is_scheduled_collection_date = TRUE
  AND c.is_valid_record = TRUE;

CREATE INDEX scoped_collection_dates_loan_date_idx
    ON scoped_collection_dates (loan_key, collection_date);

-- 4. Find the transaction state at the observation boundary.
DROP TABLE IF EXISTS observation_transaction_ids;

CREATE TABLE observation_transaction_ids AS
SELECT
    t.loan_key,
    MAX(c.collection_date) AS observation_date,
    MAX(t.transaction_key) FILTER (
        WHERE c.collection_sequence = s.observation_installment_no
    ) AS observation_transaction_key,
    MAX(t.transaction_key) FILTER (
        WHERE c.collection_sequence = s.observation_installment_no
          AND t.transaction_category = 'PROVISION'
    ) AS observation_provision_key
FROM source_loan_transaction t
JOIN scoped_collection_dates c
  ON c.loan_key = t.loan_key
 AND c.collection_date = t.transaction_date
JOIN eligible_loan_scope s
  ON s.loan_key = t.loan_key
WHERE t.is_valid_record = TRUE
GROUP BY t.loan_key, s.observation_installment_no;

CREATE INDEX observation_transaction_ids_loan_idx
    ON observation_transaction_ids (loan_key);

DROP TABLE IF EXISTS early_lifecycle_snapshot;

CREATE TABLE early_lifecycle_snapshot AS
SELECT
    t.loan_key,
    MAX(t.office_key) FILTER (
        WHERE t.transaction_key = ids.observation_transaction_key
    ) AS office_key,
    MAX(t.project_key) FILTER (
        WHERE t.transaction_key = ids.observation_transaction_key
    ) AS project_key,
    MAX(t.transaction_date) FILTER (
        WHERE t.transaction_key = ids.observation_transaction_key
    ) AS observation_date,
    MAX(t.outstanding_balance) FILTER (
        WHERE t.transaction_key = ids.observation_transaction_key
    ) AS outstanding_balance_at_observation,
    MAX(t.principal_outstanding) FILTER (
        WHERE t.transaction_key = ids.observation_transaction_key
    ) AS principal_outstanding_at_observation,
    MAX(t.overdue_amount) FILTER (
        WHERE t.transaction_key = ids.observation_transaction_key
    ) AS overdue_at_observation,
    MAX(t.accrued_interest) FILTER (
        WHERE t.transaction_key = ids.observation_provision_key
    ) AS accrued_interest_at_observation
FROM source_loan_transaction t
JOIN observation_transaction_ids ids
  ON ids.loan_key = t.loan_key
WHERE t.transaction_key IN (
    ids.observation_transaction_key,
    ids.observation_provision_key
)
GROUP BY t.loan_key;

-- 5. Remove loans closed or rectified before the intended prediction point.
DROP TABLE IF EXISTS early_closed_scope;

CREATE TABLE early_closed_scope AS
SELECT DISTINCT t.loan_key
FROM source_loan_transaction t
JOIN early_lifecycle_snapshot s
  ON s.loan_key = t.loan_key
JOIN eligible_loan_scope l
  ON l.loan_key = t.loan_key
WHERE t.transaction_date BETWEEN l.disbursement_date AND s.observation_date
  AND (
      t.transaction_category = 'EARLY_SETTLEMENT'
      OR t.loan_state = 'CLOSED'
  );

DELETE FROM eligible_loan_scope l
USING early_closed_scope x
WHERE l.loan_key = x.loan_key;

DELETE FROM early_lifecycle_snapshot s
USING early_closed_scope x
WHERE s.loan_key = x.loan_key;

-- 6. Aggregate early advance collections and collection activity.
DROP TABLE IF EXISTS early_collection_features;

CREATE TABLE early_collection_features AS
WITH transaction_changes AS (
    SELECT
        t.loan_key,
        t.transaction_key,
        t.collection_amount,
        t.advance_collection_amount,
        t.advance_collection_amount
          - COALESCE(
                LAG(t.advance_collection_amount) OVER (
                    PARTITION BY t.loan_key
                    ORDER BY t.transaction_key
                ),
                0
            ) AS advance_collection_change
    FROM source_loan_transaction t
    JOIN early_lifecycle_snapshot s
      ON s.loan_key = t.loan_key
    WHERE t.transaction_date BETWEEN
          (SELECT disbursement_date FROM eligible_loan_scope l
           WHERE l.loan_key = t.loan_key)
          AND s.observation_date
      AND t.is_valid_record = TRUE
)
SELECT
    loan_key,
    SUM(collection_amount) AS total_collection_amount,
    SUM(GREATEST(advance_collection_change, 0))
        AS total_advance_collection_amount
FROM transaction_changes
GROUP BY loan_key;

-- 7. Derive overdue increases and missed-installment events.
DROP TABLE IF EXISTS early_overdue_features;

CREATE TABLE early_overdue_features AS
WITH overdue_changes AS (
    SELECT
        t.loan_key,
        t.transaction_key,
        t.overdue_amount,
        t.overdue_amount
          - COALESCE(
                LAG(t.overdue_amount) OVER (
                    PARTITION BY t.loan_key
                    ORDER BY t.transaction_key
                ),
                0
            ) AS overdue_change
    FROM source_loan_transaction t
    JOIN early_lifecycle_snapshot s
      ON s.loan_key = t.loan_key
    JOIN eligible_loan_scope l
      ON l.loan_key = t.loan_key
    WHERE t.transaction_date BETWEEN l.disbursement_date AND s.observation_date
      AND t.is_valid_record = TRUE
      AND t.transaction_category = 'PROVISION'
)
SELECT
    loan_key,
    COUNT(*) FILTER (WHERE overdue_change > 0)
        AS missed_installment_count,
    SUM(GREATEST(overdue_change, 0))
        AS total_overdue_increase
FROM overdue_changes
GROUP BY loan_key;

-- 8. Repeat the overdue calculation on month-end observations.
DROP TABLE IF EXISTS month_end_overdue_features;

CREATE TABLE month_end_overdue_features AS
WITH month_end_rows AS (
    SELECT
        t.loan_key,
        t.transaction_key,
        t.transaction_date,
        t.overdue_amount,
        ROW_NUMBER() OVER (
            PARTITION BY t.loan_key, DATE_TRUNC('month', t.transaction_date)
            ORDER BY t.transaction_key DESC
        ) AS month_row
    FROM source_loan_transaction t
    JOIN early_lifecycle_snapshot s
      ON s.loan_key = t.loan_key
    WHERE t.transaction_date <= s.observation_date
      AND t.is_valid_record = TRUE
      AND t.is_month_end_snapshot = TRUE
),
month_end_changes AS (
    SELECT
        loan_key,
        overdue_amount
          - COALESCE(
                LAG(overdue_amount) OVER (
                    PARTITION BY loan_key
                    ORDER BY transaction_date, transaction_key
                ),
                0
            ) AS overdue_change
    FROM month_end_rows
    WHERE month_row = 1
)
SELECT
    loan_key,
    COUNT(*) FILTER (WHERE overdue_change > 0)
        AS month_end_missed_count,
    SUM(GREATEST(overdue_change, 0))
        AS month_end_overdue_increase
FROM month_end_changes
GROUP BY loan_key;

-- 9. Attach a generalized geographic hierarchy.
DROP TABLE IF EXISTS loan_geography;

CREATE TABLE loan_geography AS
SELECT
    s.loan_key,
    g.admin_level_1,
    g.admin_level_2,
    g.admin_level_3,
    g.admin_level_4,
    g.locality,
    g.latitude,
    g.longitude,
    s.office_key,
    s.project_key
FROM early_lifecycle_snapshot s
LEFT JOIN source_geographic_mapping g
  ON g.office_key = s.office_key
 AND g.project_key = s.project_key;

CREATE INDEX loan_geography_loan_idx
    ON loan_geography (loan_key);

-- 10. Assemble the loan-level analytical table.
DROP TABLE IF EXISTS early_loan_model_base;

CREATE TABLE early_loan_model_base AS
SELECT
    l.loan_key,
    l.member_key,
    l.product_key,
    l.repayment_frequency,
    l.disbursement_date,
    s.observation_date,
    l.original_duration_days,
    l.original_installment_count,
    l.observation_installment_no,
    l.disbursed_amount,
    l.installment_amount,
    l.interest_rate,
    s.outstanding_balance_at_observation,
    s.principal_outstanding_at_observation,
    s.accrued_interest_at_observation,
    s.overdue_at_observation,
    COALESCE(c.total_collection_amount, 0) AS total_collection_amount,
    COALESCE(c.total_advance_collection_amount, 0)
        AS total_advance_collection_amount,
    COALESCE(o.missed_installment_count, 0) AS missed_installment_count,
    COALESCE(o.total_overdue_increase, 0) AS total_overdue_increase,
    COALESCE(m.month_end_missed_count, 0) AS month_end_missed_count,
    COALESCE(m.month_end_overdue_increase, 0)
        AS month_end_overdue_increase,
    g.admin_level_1,
    g.admin_level_2,
    g.admin_level_3,
    g.admin_level_4,
    g.locality,
    g.latitude,
    g.longitude
FROM eligible_loan_scope l
JOIN early_lifecycle_snapshot s
  ON s.loan_key = l.loan_key
LEFT JOIN early_collection_features c
  ON c.loan_key = l.loan_key
LEFT JOIN early_overdue_features o
  ON o.loan_key = l.loan_key
LEFT JOIN month_end_overdue_features m
  ON m.loan_key = l.loan_key
LEFT JOIN loan_geography g
  ON g.loan_key = l.loan_key;

CREATE INDEX early_loan_model_base_loan_idx
    ON early_loan_model_base (loan_key);

-- 11. Add savings aggregates observed within the same early-life window.
DROP TABLE IF EXISTS early_savings_features;

CREATE TABLE early_savings_features AS
SELECT
    b.member_key,
    SUM(
        CASE WHEN t.transaction_direction = 'DEPOSIT'
             THEN t.transaction_amount ELSE 0 END
    ) AS savings_deposit_amount,
    SUM(
        CASE WHEN t.transaction_direction = 'WITHDRAWAL'
             THEN t.transaction_amount ELSE 0 END
    ) AS savings_withdrawal_amount
FROM early_loan_model_base b
JOIN source_savings_account a
  ON a.member_key = b.member_key
JOIN source_savings_transaction t
  ON t.account_key = a.account_key
WHERE t.transaction_date BETWEEN b.disbursement_date AND b.observation_date
  AND a.is_in_scope = TRUE
  AND t.is_valid_record = TRUE
GROUP BY b.member_key;

-- 12. Reconstruct overdue episodes from transaction-state changes.
DROP TABLE IF EXISTS early_overdue_duration_features;

CREATE TABLE early_overdue_duration_features AS
WITH ordered_states AS (
    SELECT
        t.loan_key,
        t.transaction_date,
        t.overdue_amount,
        LAG(t.overdue_amount) OVER (
            PARTITION BY t.loan_key ORDER BY t.transaction_key
        ) AS previous_overdue,
        LEAD(t.overdue_amount) OVER (
            PARTITION BY t.loan_key ORDER BY t.transaction_key
        ) AS next_overdue
    FROM source_loan_transaction t
    JOIN early_lifecycle_snapshot s
      ON s.loan_key = t.loan_key
    WHERE t.transaction_date <= s.observation_date
      AND t.is_valid_record = TRUE
),
episode_flags AS (
    SELECT
        *,
        CASE WHEN COALESCE(previous_overdue, 0) = 0
                   AND overdue_amount > 0
             THEN 1 ELSE 0 END AS episode_start,
        CASE WHEN overdue_amount > 0
                   AND (COALESCE(next_overdue, 0) = 0 OR next_overdue IS NULL)
             THEN 1 ELSE 0 END AS episode_end
    FROM ordered_states
),
sequenced AS (
    SELECT
        *,
        SUM(episode_start) OVER (
            PARTITION BY loan_key ORDER BY transaction_date
        ) AS start_sequence,
        SUM(episode_end) OVER (
            PARTITION BY loan_key ORDER BY transaction_date
        ) AS end_sequence
    FROM episode_flags
),
starts AS (
    SELECT loan_key, start_sequence, MIN(transaction_date) AS start_date
    FROM sequenced
    WHERE episode_start = 1
    GROUP BY loan_key, start_sequence
),
ends AS (
    SELECT loan_key, end_sequence, MIN(transaction_date) AS end_date
    FROM sequenced
    WHERE episode_end = 1
    GROUP BY loan_key, end_sequence
),
durations AS (
    SELECT
        s.loan_key,
        EXTRACT(DAY FROM e.end_date - s.start_date) AS overdue_days
    FROM starts s
    JOIN ends e
      ON e.loan_key = s.loan_key
     AND e.end_sequence = s.start_sequence
)
SELECT
    loan_key,
    MAX(overdue_days) AS max_overdue_days,
    AVG(overdue_days) AS average_overdue_days,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY overdue_days)
        AS median_overdue_days
FROM durations
GROUP BY loan_key;

-- 13. Estimate consecutive missed scheduled collections.
DROP TABLE IF EXISTS consecutive_missed_features;

CREATE TABLE consecutive_missed_features AS
WITH scheduled_days AS (
    SELECT
        b.loan_key,
        c.collection_date,
        b.installment_amount
    FROM early_loan_model_base b
    JOIN source_collection_schedule c
      ON c.loan_key = b.loan_key
    WHERE c.collection_date <= b.observation_date
      AND c.is_scheduled_collection_date = TRUE
      AND c.is_valid_record = TRUE
),
daily_collections AS (
    SELECT
        s.loan_key,
        s.collection_date,
        s.installment_amount,
        COALESCE(SUM(t.collection_amount), 0) AS collected_amount,
        MAX(t.transaction_key) AS last_transaction_key
    FROM scheduled_days s
    LEFT JOIN source_loan_transaction t
      ON t.loan_key = s.loan_key
     AND t.transaction_date = s.collection_date
     AND t.is_valid_record = TRUE
    GROUP BY s.loan_key, s.collection_date, s.installment_amount
),
miss_flags AS (
    SELECT
        *,
        CASE WHEN collected_amount < installment_amount THEN 1 ELSE 0 END
            AS missed_flag
    FROM daily_collections
),
miss_groups AS (
    SELECT
        *,
        SUM(CASE WHEN missed_flag = 0 THEN 1 ELSE 0 END) OVER (
            PARTITION BY loan_key ORDER BY collection_date
        ) AS group_no
    FROM miss_flags
),
streaks AS (
    SELECT loan_key, group_no, COUNT(*) AS missed_streak
    FROM miss_groups
    WHERE missed_flag = 1
    GROUP BY loan_key, group_no
)
SELECT
    loan_key,
    MAX(missed_streak) AS maximum_consecutive_misses
FROM streaks
GROUP BY loan_key;

-- 14. Compare loan terms against configured product/policy values.
DROP TABLE IF EXISTS product_policy_diagnostics;

CREATE TABLE product_policy_diagnostics AS
SELECT
    b.loan_key,
    b.disbursed_amount,
    p.minimum_amount,
    p.maximum_amount,
    CASE
        WHEN p.maximum_amount > p.minimum_amount
        THEN (
            (b.disbursed_amount - (p.maximum_amount + p.minimum_amount) / 2.0)
            / (p.maximum_amount - p.minimum_amount)
        ) + 0.5
    END AS disbursed_amount_policy_score,
    CASE
        WHEN b.disbursed_amount > p.maximum_amount
            THEN b.disbursed_amount - p.maximum_amount
        WHEN b.disbursed_amount < p.minimum_amount
            THEN b.disbursed_amount - p.minimum_amount
        ELSE 0
    END AS amount_policy_deviation
FROM early_loan_model_base b
LEFT JOIN source_product_policy p
  ON p.product_key = b.product_key;

-- 15. Add outcome only after the predictor snapshot has been fixed.
-- Map the validated business outcome into a strict binary label:
-- 0 = good; 1 = default. Do not copy internal status codes into public SQL.
DROP TABLE IF EXISTS loan_modeling_dataset;

CREATE TABLE loan_modeling_dataset AS
SELECT
    b.*,
    COALESCE(s.savings_deposit_amount, 0) AS savings_deposit_amount,
    COALESCE(s.savings_withdrawal_amount, 0) AS savings_withdrawal_amount,
    COALESCE(d.max_overdue_days, 0) AS max_overdue_days,
    COALESCE(d.average_overdue_days, 0) AS average_overdue_days,
    COALESCE(d.median_overdue_days, 0) AS median_overdue_days,
    COALESCE(cm.maximum_consecutive_misses, 0)
        AS maximum_consecutive_misses,
    pp.disbursed_amount_policy_score,
    pp.amount_policy_deviation,
    o.binary_outcome AS is_good_or_bad
FROM early_loan_model_base b
LEFT JOIN early_savings_features s
  ON s.member_key = b.member_key
LEFT JOIN early_overdue_duration_features d
  ON d.loan_key = b.loan_key
LEFT JOIN consecutive_missed_features cm
  ON cm.loan_key = b.loan_key
LEFT JOIN product_policy_diagnostics pp
  ON pp.loan_key = b.loan_key
LEFT JOIN source_validated_loan_outcome o
  ON o.loan_key = b.loan_key;

-- Final checks: row grain, missing labels and class definition.
SELECT COUNT(*) AS dataset_rows,
       COUNT(DISTINCT loan_key) AS distinct_loans
FROM loan_modeling_dataset;

SELECT
    COUNT(*) FILTER (WHERE is_good_or_bad IS NULL) AS missing_outcomes,
    COUNT(*) FILTER (WHERE is_good_or_bad NOT IN (0, 1)) AS invalid_outcomes
FROM loan_modeling_dataset;
