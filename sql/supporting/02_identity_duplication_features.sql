-- 02_identity_duplication_features.sql
-- Derive privacy-preserving identity-duplication indicators.
-- Raw identity values must never be included in the public modeling dataset.

DROP TABLE IF EXISTS normalized_identity_reference;

CREATE TABLE normalized_identity_reference AS
SELECT
    member_key,
    NULLIF(
        REGEXP_REPLACE(identity_value, '[^0-9]', '', 'g'),
        ''
    ) AS normalized_identity,
    NULLIF(
        REGEXP_REPLACE(alternate_identity_value, '[^0-9]', '', 'g'),
        ''
    ) AS normalized_alternate_identity,
    branch_key
FROM source_member_identity
WHERE is_active_member = TRUE;

-- Count the number of member records associated with each normalized value.
DROP TABLE IF EXISTS identity_reference_counts;

CREATE TABLE identity_reference_counts AS
SELECT
    identity_value,
    COUNT(*) AS record_count,
    COUNT(DISTINCT branch_key) AS branch_count
FROM (
    SELECT
        normalized_identity AS identity_value,
        member_key,
        branch_key
    FROM normalized_identity_reference
    WHERE normalized_identity IS NOT NULL

    UNION ALL

    SELECT
        normalized_alternate_identity AS identity_value,
        member_key,
        branch_key
    FROM normalized_identity_reference
    WHERE normalized_alternate_identity IS NOT NULL
      AND normalized_alternate_identity
          IS DISTINCT FROM normalized_identity
) identity_values
GROUP BY identity_value;

-- Classify potential duplication without retaining raw identity values.
DROP TABLE IF EXISTS member_identity_quality_features;

CREATE TABLE member_identity_quality_features AS
SELECT
    i.member_key,
    COALESCE(primary_count.record_count, 0) AS primary_match_count,
    COALESCE(alternate_count.record_count, 0) AS alternate_match_count,
    CASE
        WHEN COALESCE(primary_count.record_count, 0) > 1
          OR COALESCE(alternate_count.record_count, 0) > 1
            THEN 1
        WHEN primary_count.record_count = 1
          OR alternate_count.record_count = 1
            THEN 0
        ELSE 2
    END AS potential_duplicate_flag,
    CASE
        WHEN COALESCE(primary_count.record_count, 0) > 1
         AND COALESCE(primary_count.branch_count, 0) > 1
            THEN 'MULTIPLE_BRANCHES'
        WHEN COALESCE(primary_count.record_count, 0) > 1
            THEN 'SAME_BRANCH'
        WHEN COALESCE(alternate_count.record_count, 0) > 1
         AND COALESCE(alternate_count.branch_count, 0) > 1
            THEN 'MULTIPLE_BRANCHES'
        WHEN COALESCE(alternate_count.record_count, 0) > 1
            THEN 'SAME_BRANCH'
        ELSE 'NO_MATCH'
    END AS duplication_pattern
FROM normalized_identity_reference i
LEFT JOIN identity_reference_counts primary_count
  ON primary_count.identity_value = i.normalized_identity
LEFT JOIN identity_reference_counts alternate_count
  ON alternate_count.identity_value = i.normalized_alternate_identity;

CREATE INDEX member_identity_quality_features_member_idx
    ON member_identity_quality_features (member_key);

-- Attach only derived indicators, never identity values.
ALTER TABLE loan_modeling_dataset
    ADD COLUMN IF NOT EXISTS potential_duplicate_flag INTEGER,
    ADD COLUMN IF NOT EXISTS duplication_pattern TEXT;

UPDATE loan_modeling_dataset d
SET
    potential_duplicate_flag = q.potential_duplicate_flag,
    duplication_pattern = q.duplication_pattern
FROM member_identity_quality_features q
WHERE d.member_key = q.member_key;

-- Review the resulting indicator distribution.
SELECT
    potential_duplicate_flag,
    duplication_pattern,
    COUNT(*) AS loan_count
FROM loan_modeling_dataset
GROUP BY potential_duplicate_flag, duplication_pattern
ORDER BY potential_duplicate_flag, duplication_pattern;
