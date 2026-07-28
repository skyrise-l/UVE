-- task_049_geographic_facility_interaction_evidence.sql
-- Final task-level Evidence SQL for food_inspection_2.

WITH
inspection_base AS (
    SELECT
        i.inspection_id,
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
        COALESCE(CAST(e.ward AS VARCHAR), 'unknown') AS ward,
        COALESCE(CAST(e.zip AS VARCHAR), 'unknown') AS zip_code,
        COALESCE(e.city, 'unknown') AS city
    FROM inspection i
    JOIN establishment e ON i.license_no = e.license_no
),
violation_summary AS (
    SELECT
        v.inspection_id,
        COUNT(*) AS violations,
        SUM(CASE WHEN TRIM(ip.point_level) = 'Critical' THEN 1 ELSE 0 END) AS critical_violations,
        SUM(CASE WHEN TRIM(ip.point_level) = 'Serious' THEN 1 ELSE 0 END) AS serious_violations,
        SUM(CASE WHEN TRIM(ip.point_level) = 'Minor' THEN 1 ELSE 0 END) AS minor_violations,
        SUM(v.fine) AS total_fine
    FROM violation v
    JOIN inspection_point ip ON v.point_id = ip.point_id
    GROUP BY v.inspection_id
),
fact AS (
    SELECT
        ib.*,
        COALESCE(vs.violations, 0) AS violations,
        COALESCE(vs.critical_violations, 0) AS critical_violations,
        COALESCE(vs.serious_violations, 0) AS serious_violations,
        COALESCE(vs.minor_violations, 0) AS minor_violations,
        COALESCE(vs.total_fine, 0) AS total_fine
    FROM inspection_base ib
    LEFT JOIN violation_summary vs ON ib.inspection_id = vs.inspection_id
),
city_base AS (
    SELECT city AS item, COUNT(*) AS inspections, COUNT(DISTINCT license_no) AS establishments,
        SUM(violations) AS violations, SUM(critical_violations) AS critical_violations,
        SUM(serious_violations) AS serious_violations, SUM(minor_violations) AS minor_violations,
        SUM(total_fine) AS total_fine,
        SUM(CASE WHEN result_group = 'pass' THEN 1 ELSE 0 END) AS pass_count,
        SUM(CASE WHEN result_group = 'conditional_pass' THEN 1 ELSE 0 END) AS conditional_count,
        SUM(CASE WHEN result_group = 'fail' THEN 1 ELSE 0 END) AS fail_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, city) AS volume_rank
    FROM fact GROUP BY city
),
zip_base AS (
    SELECT zip_code AS item, COUNT(*) AS inspections, COUNT(DISTINCT license_no) AS establishments,
        SUM(violations) AS violations, SUM(critical_violations) AS critical_violations,
        SUM(serious_violations) AS serious_violations, SUM(minor_violations) AS minor_violations,
        SUM(total_fine) AS total_fine,
        SUM(CASE WHEN result_group = 'pass' THEN 1 ELSE 0 END) AS pass_count,
        SUM(CASE WHEN result_group = 'conditional_pass' THEN 1 ELSE 0 END) AS conditional_count,
        SUM(CASE WHEN result_group = 'fail' THEN 1 ELSE 0 END) AS fail_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, zip_code) AS volume_rank
    FROM fact GROUP BY zip_code
),
ward_facility AS (
    SELECT ward AS item, facility_type AS item_2, COUNT(*) AS inspections, COUNT(DISTINCT license_no) AS establishments,
        SUM(violations) AS violations, SUM(critical_violations) AS critical_violations,
        SUM(serious_violations) AS serious_violations, SUM(minor_violations) AS minor_violations,
        SUM(total_fine) AS total_fine,
        SUM(CASE WHEN result_group = 'pass' THEN 1 ELSE 0 END) AS pass_count,
        SUM(CASE WHEN result_group = 'conditional_pass' THEN 1 ELSE 0 END) AS conditional_count,
        SUM(CASE WHEN result_group = 'fail' THEN 1 ELSE 0 END) AS fail_count,
        ROW_NUMBER() OVER (PARTITION BY ward ORDER BY COUNT(*) DESC, facility_type) AS rank_in_ward
    FROM fact GROUP BY ward, facility_type
),
ward_risk AS (
    SELECT ward AS item, risk_level AS item_2, COUNT(*) AS inspections, COUNT(DISTINCT license_no) AS establishments,
        SUM(violations) AS violations, SUM(critical_violations) AS critical_violations,
        SUM(serious_violations) AS serious_violations, SUM(minor_violations) AS minor_violations,
        SUM(total_fine) AS total_fine,
        SUM(CASE WHEN result_group = 'pass' THEN 1 ELSE 0 END) AS pass_count,
        SUM(CASE WHEN result_group = 'conditional_pass' THEN 1 ELSE 0 END) AS conditional_count,
        SUM(CASE WHEN result_group = 'fail' THEN 1 ELSE 0 END) AS fail_count,
        ROW_NUMBER() OVER (PARTITION BY ward ORDER BY COUNT(*) DESC, risk_level) AS rank_in_ward
    FROM fact GROUP BY ward, risk_level
),
geo_category AS (
    SELECT f.ward AS item, ip.category AS item_2, COUNT(*) AS inspections, COUNT(DISTINCT f.license_no) AS establishments,
        COUNT(*) AS violations,
        SUM(CASE WHEN TRIM(ip.point_level) = 'Critical' THEN 1 ELSE 0 END) AS critical_violations,
        SUM(CASE WHEN TRIM(ip.point_level) = 'Serious' THEN 1 ELSE 0 END) AS serious_violations,
        SUM(CASE WHEN TRIM(ip.point_level) = 'Minor' THEN 1 ELSE 0 END) AS minor_violations,
        SUM(v.fine) AS total_fine,
        SUM(CASE WHEN f.result_group = 'pass' THEN 1 ELSE 0 END) AS pass_count,
        SUM(CASE WHEN f.result_group = 'conditional_pass' THEN 1 ELSE 0 END) AS conditional_count,
        SUM(CASE WHEN f.result_group = 'fail' THEN 1 ELSE 0 END) AS fail_count,
        ROW_NUMBER() OVER (PARTITION BY f.ward ORDER BY COUNT(*) DESC, ip.category) AS rank_in_ward
    FROM fact f
    JOIN violation v ON f.inspection_id = v.inspection_id
    JOIN inspection_point ip ON v.point_id = ip.point_id
    GROUP BY f.ward, ip.category
)
SELECT
    'city_baseline' AS evidence_block, 'city' AS grain, item, CAST(NULL AS VARCHAR) AS item_2, CAST(NULL AS VARCHAR) AS item_3,
    'inspection_volume_rank' AS rank_label, CAST(volume_rank AS DOUBLE) AS rank_value,
    CAST(inspections AS BIGINT) AS inspections, CAST(establishments AS BIGINT) AS establishments,
    CAST(violations AS BIGINT) AS violations, CAST(critical_violations AS BIGINT) AS critical_violations,
    CAST(serious_violations AS BIGINT) AS serious_violations, CAST(minor_violations AS BIGINT) AS minor_violations,
    CAST(total_fine AS DOUBLE) AS total_fine, CAST(pass_count AS BIGINT) AS pass_count,
    CAST(conditional_count AS BIGINT) AS conditional_count, CAST(fail_count AS BIGINT) AS fail_count,
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4) AS issue_rate_pct,
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4) AS avg_violations_per_inspection,
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4) AS avg_fine_per_inspection,
    'Start with city-level exposure and outcome differences.' AS notes
FROM city_base
UNION ALL
SELECT 'zip_baseline', 'zip_code', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), 'inspection_volume_rank', CAST(volume_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT), CAST(critical_violations AS BIGINT),
    CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT), CAST(total_fine AS DOUBLE), CAST(pass_count AS BIGINT),
    CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4), ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Use zip-level rows to detect within-city concentration.'
FROM zip_base WHERE volume_rank <= 40
UNION ALL
SELECT 'ward_facility_type_interaction', 'ward_facility_type', item, item_2, CAST(NULL AS VARCHAR), 'facility_rank_within_ward', CAST(rank_in_ward AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT), CAST(critical_violations AS BIGINT),
    CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT), CAST(total_fine AS DOUBLE), CAST(pass_count AS BIGINT),
    CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4), ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Test whether geography is really a facility-format interaction.'
FROM ward_facility WHERE rank_in_ward <= 8
UNION ALL
SELECT 'ward_risk_interaction', 'ward_risk_level', item, item_2, CAST(NULL AS VARCHAR), 'risk_rank_within_ward', CAST(rank_in_ward AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT), CAST(critical_violations AS BIGINT),
    CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT), CAST(total_fine AS DOUBLE), CAST(pass_count AS BIGINT),
    CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4), ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Check whether local weak pockets are simply high-risk facility exposure.'
FROM ward_risk
UNION ALL
SELECT 'ward_violation_category_mix', 'ward_violation_category', item, item_2, CAST(NULL AS VARCHAR), 'category_rank_within_ward', CAST(rank_in_ward AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT), CAST(critical_violations AS BIGINT),
    CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT), CAST(total_fine AS DOUBLE), CAST(pass_count AS BIGINT),
    CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4), ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Identify whether local issues differ by violation content, not just outcome rate.'
FROM geo_category WHERE rank_in_ward <= 6;
