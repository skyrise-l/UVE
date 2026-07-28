-- task_042_violation_severity_burden_evidence.sql
-- Draft task-level Evidence SQL for food_inspection_2.

WITH
violation_fact AS (
    SELECT
        v.inspection_id,
        v.point_id,
        v.fine AS violation_fine,
        ip.category,
        ip.code,
        ip.point_level,
        ip."Description" AS point_description,
        i.results,
        CASE
            WHEN i.results = 'Pass' THEN 'pass'
            WHEN i.results = 'Pass w/ Conditions' THEN 'conditional_pass'
            WHEN i.results = 'Fail' THEN 'fail'
            ELSE 'other_result'
        END AS result_group,
        i.inspection_type,
        i.license_no,
        COALESCE(NULLIF(TRIM(e.facility_type), ''), 'unknown') AS facility_type,
        COALESCE(CAST(e.risk_level AS VARCHAR), 'unknown') AS risk_level,
        COALESCE(CAST(e.ward AS VARCHAR), 'unknown') AS ward
    FROM violation v
    JOIN inspection_point ip ON v.point_id = ip.point_id
    JOIN inspection i ON v.inspection_id = i.inspection_id
    JOIN establishment e ON i.license_no = e.license_no
),
totals AS (
    SELECT
        COUNT(*) AS all_violations,
        SUM(violation_fine) AS all_fine
    FROM violation_fact
),
level_summary AS (
    SELECT
        point_level AS item,
        COUNT(DISTINCT inspection_id) AS inspections,
        COUNT(DISTINCT license_no) AS establishments,
        COUNT(*) AS violations,
        SUM(CASE WHEN point_level = 'Critical' THEN 1 ELSE 0 END) AS critical_violations,
        SUM(CASE WHEN point_level = 'Serious' THEN 1 ELSE 0 END) AS serious_violations,
        SUM(CASE WHEN point_level = 'Minor' THEN 1 ELSE 0 END) AS minor_violations,
        SUM(violation_fine) AS total_fine,
        ROW_NUMBER() OVER (ORDER BY SUM(violation_fine) DESC, point_level) AS fine_rank
    FROM violation_fact
    GROUP BY point_level
),
category_summary AS (
    SELECT
        category AS item,
        COUNT(DISTINCT inspection_id) AS inspections,
        COUNT(DISTINCT license_no) AS establishments,
        COUNT(*) AS violations,
        SUM(CASE WHEN point_level = 'Critical' THEN 1 ELSE 0 END) AS critical_violations,
        SUM(CASE WHEN point_level = 'Serious' THEN 1 ELSE 0 END) AS serious_violations,
        SUM(CASE WHEN point_level = 'Minor' THEN 1 ELSE 0 END) AS minor_violations,
        SUM(violation_fine) AS total_fine,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, category) AS violation_rank,
        ROW_NUMBER() OVER (ORDER BY SUM(violation_fine) DESC, category) AS fine_rank
    FROM violation_fact
    GROUP BY category
),
point_summary AS (
    SELECT
        CAST(point_id AS VARCHAR) AS item,
        category AS item_2,
        point_level AS item_3,
        COUNT(DISTINCT inspection_id) AS inspections,
        COUNT(DISTINCT license_no) AS establishments,
        COUNT(*) AS violations,
        SUM(CASE WHEN point_level = 'Critical' THEN 1 ELSE 0 END) AS critical_violations,
        SUM(CASE WHEN point_level = 'Serious' THEN 1 ELSE 0 END) AS serious_violations,
        SUM(CASE WHEN point_level = 'Minor' THEN 1 ELSE 0 END) AS minor_violations,
        SUM(violation_fine) AS total_fine,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, point_id) AS violation_rank,
        ROW_NUMBER() OVER (ORDER BY SUM(violation_fine) DESC, point_id) AS fine_rank
    FROM violation_fact
    GROUP BY point_id, category, point_level
),
top_point_concentration AS (
    SELECT
        SUM(CASE WHEN violation_rank <= 10 THEN violations ELSE 0 END) AS top10_violations,
        SUM(violations) AS all_violations,
        SUM(CASE WHEN fine_rank <= 10 THEN total_fine ELSE 0 END) AS top10_fine,
        SUM(total_fine) AS all_fine,
        COUNT(*) AS point_count
    FROM point_summary
),
result_summary AS (
    SELECT
        result_group AS item,
        COUNT(DISTINCT inspection_id) AS inspections,
        COUNT(DISTINCT license_no) AS establishments,
        COUNT(*) AS violations,
        SUM(CASE WHEN point_level = 'Critical' THEN 1 ELSE 0 END) AS critical_violations,
        SUM(CASE WHEN point_level = 'Serious' THEN 1 ELSE 0 END) AS serious_violations,
        SUM(CASE WHEN point_level = 'Minor' THEN 1 ELSE 0 END) AS minor_violations,
        SUM(violation_fine) AS total_fine,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, result_group) AS violation_rank
    FROM violation_fact
    GROUP BY result_group
),
risk_category_summary AS (
    SELECT
        risk_level AS item,
        category AS item_2,
        COUNT(DISTINCT inspection_id) AS inspections,
        COUNT(DISTINCT license_no) AS establishments,
        COUNT(*) AS violations,
        SUM(CASE WHEN point_level = 'Critical' THEN 1 ELSE 0 END) AS critical_violations,
        SUM(CASE WHEN point_level = 'Serious' THEN 1 ELSE 0 END) AS serious_violations,
        SUM(CASE WHEN point_level = 'Minor' THEN 1 ELSE 0 END) AS minor_violations,
        SUM(violation_fine) AS total_fine,
        ROW_NUMBER() OVER (PARTITION BY risk_level ORDER BY COUNT(*) DESC, category) AS category_rank_in_risk
    FROM violation_fact
    GROUP BY risk_level, category
),
facility_category_summary AS (
    SELECT
        facility_type AS item,
        category AS item_2,
        COUNT(DISTINCT inspection_id) AS inspections,
        COUNT(DISTINCT license_no) AS establishments,
        COUNT(*) AS violations,
        SUM(CASE WHEN point_level = 'Critical' THEN 1 ELSE 0 END) AS critical_violations,
        SUM(CASE WHEN point_level = 'Serious' THEN 1 ELSE 0 END) AS serious_violations,
        SUM(CASE WHEN point_level = 'Minor' THEN 1 ELSE 0 END) AS minor_violations,
        SUM(violation_fine) AS total_fine,
        ROW_NUMBER() OVER (PARTITION BY facility_type ORDER BY COUNT(*) DESC, category) AS category_rank_in_facility_type
    FROM violation_fact
    GROUP BY facility_type, category
)
SELECT
    'severity_level_baseline' AS evidence_block,
    'point_level' AS grain,
    item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'fine_rank' AS rank_label,
    CAST(fine_rank AS DOUBLE) AS rank_value,
    CAST(inspections AS BIGINT) AS inspections,
    CAST(establishments AS BIGINT) AS establishments,
    CAST(violations AS BIGINT) AS violations,
    CAST(critical_violations AS BIGINT) AS critical_violations,
    CAST(serious_violations AS BIGINT) AS serious_violations,
    CAST(minor_violations AS BIGINT) AS minor_violations,
    CAST(total_fine AS DOUBLE) AS total_fine,
    ROUND(100.0 * violations / NULLIF(t.all_violations, 0), 4) AS violation_share_pct,
    ROUND(100.0 * total_fine / NULLIF(t.all_fine, 0), 4) AS fine_share_pct,
    ROUND(1.0 * total_fine / NULLIF(violations, 0), 4) AS avg_fine_per_violation,
    'Separate violation volume from severity burden by point level.' AS notes
FROM level_summary
CROSS JOIN totals t
UNION ALL
SELECT
    'category_burden_profile', 'violation_category', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'violation_rank', CAST(violation_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT),
    CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT),
    CAST(total_fine AS DOUBLE),
    ROUND(100.0 * violations / NULLIF(t.all_violations, 0), 4),
    ROUND(100.0 * total_fine / NULLIF(t.all_fine, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(violations, 0), 4),
    'Identify which violation categories carry the main burden.'
FROM category_summary
CROSS JOIN totals t
UNION ALL
SELECT
    'inspection_point_concentration', 'portfolio', 'top_10_inspection_points', CAST(point_count AS VARCHAR), CAST(NULL AS VARCHAR),
    'top10_point_violation_share', CAST(NULL AS DOUBLE),
    CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(top10_violations AS BIGINT),
    CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT),
    CAST(top10_fine AS DOUBLE),
    ROUND(100.0 * top10_violations / NULLIF(all_violations, 0), 4),
    ROUND(100.0 * top10_fine / NULLIF(all_fine, 0), 4),
    CAST(NULL AS DOUBLE),
    'Check whether severity is broad-based or concentrated in a small set of inspection points.'
FROM top_point_concentration
UNION ALL
SELECT
    'inspection_point_profile', 'inspection_point', item, item_2, item_3,
    'violation_rank', CAST(violation_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT),
    CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT),
    CAST(total_fine AS DOUBLE),
    ROUND(100.0 * violations / NULLIF(t.all_violations, 0), 4),
    ROUND(100.0 * total_fine / NULLIF(t.all_fine, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(violations, 0), 4),
    'Retain point-level evidence for named severe or high-volume requirements.'
FROM point_summary
CROSS JOIN totals t
WHERE violation_rank <= 25 OR fine_rank <= 25
UNION ALL
SELECT
    'result_severity_profile', 'inspection_result', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'violation_rank', CAST(violation_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT),
    CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT),
    CAST(total_fine AS DOUBLE),
    ROUND(100.0 * violations / NULLIF(t.all_violations, 0), 4),
    ROUND(100.0 * total_fine / NULLIF(t.all_fine, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(violations, 0), 4),
    'Connect violation severity back to inspection outcomes.'
FROM result_summary
CROSS JOIN totals t
UNION ALL
SELECT
    'risk_category_profile', 'risk_level_category', item, item_2, CAST(NULL AS VARCHAR),
    'category_rank_in_risk', CAST(category_rank_in_risk AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT),
    CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT),
    CAST(total_fine AS DOUBLE),
    ROUND(100.0 * violations / NULLIF(t.all_violations, 0), 4),
    ROUND(100.0 * total_fine / NULLIF(t.all_fine, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(violations, 0), 4),
    'Check whether risk levels differ in the kinds of violations they carry.'
FROM risk_category_summary
CROSS JOIN totals t
WHERE category_rank_in_risk <= 5
UNION ALL
SELECT
    'facility_category_profile', 'facility_type_category', item, item_2, CAST(NULL AS VARCHAR),
    'category_rank_in_facility_type', CAST(category_rank_in_facility_type AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT),
    CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT),
    CAST(total_fine AS DOUBLE),
    ROUND(100.0 * violations / NULLIF(t.all_violations, 0), 4),
    ROUND(100.0 * total_fine / NULLIF(t.all_fine, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(violations, 0), 4),
    'Check whether facility-type patterns explain category-level burden.'
FROM facility_category_summary
CROSS JOIN totals t
WHERE category_rank_in_facility_type <= 3;
