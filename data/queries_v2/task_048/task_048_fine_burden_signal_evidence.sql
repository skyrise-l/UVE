-- task_048_fine_burden_signal_evidence.sql
-- Final task-level Evidence SQL for food_inspection_2.

WITH
inspection_base AS (
    SELECT
        i.inspection_id,
        i.inspection_type,
        i.results,
        CASE
            WHEN i.results = 'Pass' THEN 'pass'
            WHEN i.results = 'Pass w/ Conditions' THEN 'conditional_pass'
            WHEN i.results = 'Fail' THEN 'fail'
            ELSE 'other_result'
        END AS result_group,
        i.license_no,
        COALESCE(NULLIF(TRIM(e.facility_type), ''), 'unknown') AS facility_type,
        COALESCE(CAST(e.risk_level AS VARCHAR), 'unknown') AS risk_level,
        COALESCE(CAST(e.ward AS VARCHAR), 'unknown') AS ward
    FROM inspection i
    JOIN establishment e ON i.license_no = e.license_no
),
violation_fact AS (
    SELECT
        ib.inspection_id,
        ib.inspection_type,
        ib.result_group,
        ib.license_no,
        ib.facility_type,
        ib.risk_level,
        ib.ward,
        v.point_id,
        v.fine AS violation_fine,
        ip.category,
        TRIM(ip.point_level) AS point_level,
        ip.code,
        ip."Description" AS point_description
    FROM inspection_base ib
    JOIN violation v ON ib.inspection_id = v.inspection_id
    JOIN inspection_point ip ON v.point_id = ip.point_id
),
inspection_fines AS (
    SELECT
        ib.inspection_id,
        ib.inspection_type,
        ib.result_group,
        ib.license_no,
        ib.facility_type,
        ib.risk_level,
        ib.ward,
        COUNT(vf.point_id) AS violations,
        SUM(CASE WHEN vf.point_level = 'Critical' THEN 1 ELSE 0 END) AS critical_violations,
        SUM(CASE WHEN vf.point_level = 'Serious' THEN 1 ELSE 0 END) AS serious_violations,
        SUM(CASE WHEN vf.point_level = 'Minor' THEN 1 ELSE 0 END) AS minor_violations,
        COALESCE(SUM(vf.violation_fine), 0) AS total_fine
    FROM inspection_base ib
    LEFT JOIN violation_fact vf ON ib.inspection_id = vf.inspection_id
    GROUP BY ib.inspection_id, ib.inspection_type, ib.result_group, ib.license_no, ib.facility_type, ib.risk_level, ib.ward
),
inspection_fine_bucket AS (
    SELECT
        CASE
            WHEN total_fine = 0 THEN 'no_recorded_fine'
            WHEN total_fine <= 500 THEN 'low_fine'
            WHEN total_fine <= 1500 THEN 'medium_fine'
            ELSE 'high_fine'
        END AS item,
        COUNT(*) AS inspections,
        COUNT(DISTINCT license_no) AS establishments,
        SUM(violations) AS violations,
        SUM(critical_violations) AS critical_violations,
        SUM(serious_violations) AS serious_violations,
        SUM(minor_violations) AS minor_violations,
        SUM(total_fine) AS total_fine,
        SUM(CASE WHEN result_group = 'pass' THEN 1 ELSE 0 END) AS pass_count,
        SUM(CASE WHEN result_group = 'conditional_pass' THEN 1 ELSE 0 END) AS conditional_count,
        SUM(CASE WHEN result_group = 'fail' THEN 1 ELSE 0 END) AS fail_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, item) AS bucket_rank
    FROM inspection_fines
    GROUP BY item
),
fine_amount AS (
    SELECT
        CAST(violation_fine AS VARCHAR) AS item,
        COUNT(*) AS inspections,
        COUNT(DISTINCT license_no) AS establishments,
        COUNT(*) AS violations,
        SUM(CASE WHEN point_level = 'Critical' THEN 1 ELSE 0 END) AS critical_violations,
        SUM(CASE WHEN point_level = 'Serious' THEN 1 ELSE 0 END) AS serious_violations,
        SUM(CASE WHEN point_level = 'Minor' THEN 1 ELSE 0 END) AS minor_violations,
        SUM(violation_fine) AS total_fine,
        SUM(CASE WHEN result_group = 'pass' THEN 1 ELSE 0 END) AS pass_count,
        SUM(CASE WHEN result_group = 'conditional_pass' THEN 1 ELSE 0 END) AS conditional_count,
        SUM(CASE WHEN result_group = 'fail' THEN 1 ELSE 0 END) AS fail_count,
        ROW_NUMBER() OVER (ORDER BY SUM(violation_fine) DESC, violation_fine DESC) AS fine_rank
    FROM violation_fact
    GROUP BY violation_fine
),
category_fine AS (
    SELECT
        category AS item,
        COUNT(*) AS inspections,
        COUNT(DISTINCT license_no) AS establishments,
        COUNT(*) AS violations,
        SUM(CASE WHEN point_level = 'Critical' THEN 1 ELSE 0 END) AS critical_violations,
        SUM(CASE WHEN point_level = 'Serious' THEN 1 ELSE 0 END) AS serious_violations,
        SUM(CASE WHEN point_level = 'Minor' THEN 1 ELSE 0 END) AS minor_violations,
        SUM(violation_fine) AS total_fine,
        SUM(CASE WHEN result_group = 'pass' THEN 1 ELSE 0 END) AS pass_count,
        SUM(CASE WHEN result_group = 'conditional_pass' THEN 1 ELSE 0 END) AS conditional_count,
        SUM(CASE WHEN result_group = 'fail' THEN 1 ELSE 0 END) AS fail_count,
        ROW_NUMBER() OVER (ORDER BY SUM(violation_fine) DESC, category) AS fine_rank
    FROM violation_fact
    GROUP BY category
),
point_fine AS (
    SELECT
        CAST(point_id AS VARCHAR) AS item,
        category AS item_2,
        point_level AS item_3,
        COUNT(*) AS inspections,
        COUNT(DISTINCT license_no) AS establishments,
        COUNT(*) AS violations,
        SUM(CASE WHEN point_level = 'Critical' THEN 1 ELSE 0 END) AS critical_violations,
        SUM(CASE WHEN point_level = 'Serious' THEN 1 ELSE 0 END) AS serious_violations,
        SUM(CASE WHEN point_level = 'Minor' THEN 1 ELSE 0 END) AS minor_violations,
        SUM(violation_fine) AS total_fine,
        SUM(CASE WHEN result_group = 'pass' THEN 1 ELSE 0 END) AS pass_count,
        SUM(CASE WHEN result_group = 'conditional_pass' THEN 1 ELSE 0 END) AS conditional_count,
        SUM(CASE WHEN result_group = 'fail' THEN 1 ELSE 0 END) AS fail_count,
        ROW_NUMBER() OVER (ORDER BY SUM(violation_fine) DESC, COUNT(*) DESC, point_id) AS fine_rank
    FROM violation_fact
    GROUP BY point_id, category, point_level
),
segment_fine AS (
    SELECT
        facility_type AS item,
        risk_level AS item_2,
        COUNT(*) AS inspections,
        COUNT(DISTINCT license_no) AS establishments,
        SUM(violations) AS violations,
        SUM(critical_violations) AS critical_violations,
        SUM(serious_violations) AS serious_violations,
        SUM(minor_violations) AS minor_violations,
        SUM(total_fine) AS total_fine,
        SUM(CASE WHEN result_group = 'pass' THEN 1 ELSE 0 END) AS pass_count,
        SUM(CASE WHEN result_group = 'conditional_pass' THEN 1 ELSE 0 END) AS conditional_count,
        SUM(CASE WHEN result_group = 'fail' THEN 1 ELSE 0 END) AS fail_count,
        ROW_NUMBER() OVER (ORDER BY SUM(total_fine) DESC, COUNT(*) DESC, facility_type, risk_level) AS fine_rank
    FROM inspection_fines
    GROUP BY facility_type, risk_level
)
SELECT
    'inspection_fine_bucket' AS evidence_block,
    'inspection_fine_bucket' AS grain,
    item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'bucket_volume_rank' AS rank_label,
    CAST(bucket_rank AS DOUBLE) AS rank_value,
    CAST(inspections AS BIGINT) AS inspections,
    CAST(establishments AS BIGINT) AS establishments,
    CAST(violations AS BIGINT) AS violations,
    CAST(critical_violations AS BIGINT) AS critical_violations,
    CAST(serious_violations AS BIGINT) AS serious_violations,
    CAST(minor_violations AS BIGINT) AS minor_violations,
    CAST(total_fine AS DOUBLE) AS total_fine,
    CAST(pass_count AS BIGINT) AS pass_count,
    CAST(conditional_count AS BIGINT) AS conditional_count,
    CAST(fail_count AS BIGINT) AS fail_count,
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4) AS issue_rate_pct,
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4) AS avg_violations_per_inspection,
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4) AS avg_fine_per_inspection,
    'Separate no-fine, low-fine, and high-fine inspections before interpreting penalty burden.' AS notes
FROM inspection_fine_bucket
UNION ALL
SELECT
    'fine_amount_profile', 'violation_fine_amount', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'fine_burden_rank', CAST(fine_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT),
    CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT),
    CAST(total_fine AS DOUBLE), CAST(pass_count AS BIGINT), CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Check how recorded fine amounts map to violation volume and severity.'
FROM fine_amount
UNION ALL
SELECT
    'category_fine_efficiency', 'violation_category', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'fine_burden_rank', CAST(fine_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT),
    CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT),
    CAST(total_fine AS DOUBLE), CAST(pass_count AS BIGINT), CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Identify categories where fine burden is larger or smaller than simple violation frequency suggests.'
FROM category_fine
UNION ALL
SELECT
    'point_fine_concentration', 'inspection_point', item, item_2, item_3,
    'fine_burden_rank', CAST(fine_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT),
    CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT),
    CAST(total_fine AS DOUBLE), CAST(pass_count AS BIGINT), CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Find whether the penalty burden is concentrated in a small set of inspection points.'
FROM point_fine
WHERE fine_rank <= 30
UNION ALL
SELECT
    'facility_risk_fine_profile', 'facility_type_risk_level', item, item_2, CAST(NULL AS VARCHAR),
    'fine_burden_rank', CAST(fine_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT),
    CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT),
    CAST(total_fine AS DOUBLE), CAST(pass_count AS BIGINT), CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Connect penalty burden back to operating segments rather than only violation labels.'
FROM segment_fine
WHERE fine_rank <= 30;
