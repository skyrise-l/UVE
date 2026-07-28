-- task_046_temporal_inspection_shift_evidence.sql
-- Final task-level Evidence SQL for food_inspection_2.
-- Finalized with full results named years, seasonal pockets, rankings, and numeric anchors.

WITH
inspection_base AS (
    SELECT
        i.inspection_id,
        i.inspection_date,
        SUBSTR(CAST(i.inspection_date AS VARCHAR), 1, 4) AS inspection_year,
        CASE
            WHEN CAST(SUBSTR(CAST(i.inspection_date AS VARCHAR), 6, 2) AS INTEGER) BETWEEN 1 AND 3 THEN 'Q1'
            WHEN CAST(SUBSTR(CAST(i.inspection_date AS VARCHAR), 6, 2) AS INTEGER) BETWEEN 4 AND 6 THEN 'Q2'
            WHEN CAST(SUBSTR(CAST(i.inspection_date AS VARCHAR), 6, 2) AS INTEGER) BETWEEN 7 AND 9 THEN 'Q3'
            ELSE 'Q4'
        END AS inspection_quarter,
        i.inspection_type,
        i.results,
        CASE
            WHEN i.results = 'Pass' THEN 'pass'
            WHEN i.results = 'Pass w/ Conditions' THEN 'conditional_pass'
            WHEN i.results = 'Fail' THEN 'fail'
            ELSE 'other_result'
        END AS result_group,
        CASE WHEN i.followup_to IS NULL THEN 'not_followup' ELSE 'followup' END AS followup_status,
        i.employee_id,
        i.license_no,
        COALESCE(NULLIF(TRIM(e.facility_type), ''), 'unknown') AS facility_type,
        COALESCE(CAST(e.risk_level AS VARCHAR), 'unknown') AS risk_level,
        COALESCE(CAST(e.ward AS VARCHAR), 'unknown') AS ward,
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
annual AS (
    SELECT
        inspection_year AS item,
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
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, inspection_year) AS volume_rank
    FROM fact
    GROUP BY inspection_year
),
quarterly AS (
    SELECT
        inspection_year AS item,
        inspection_quarter AS item_2,
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
        ROW_NUMBER() OVER (PARTITION BY inspection_year ORDER BY COUNT(*) DESC, inspection_quarter) AS quarter_rank
    FROM fact
    GROUP BY inspection_year, inspection_quarter
),
year_facility AS (
    SELECT
        inspection_year AS item,
        facility_type AS item_2,
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
        ROW_NUMBER() OVER (PARTITION BY inspection_year ORDER BY COUNT(*) DESC, facility_type) AS facility_rank
    FROM fact
    GROUP BY inspection_year, facility_type
),
year_category AS (
    SELECT
        f.inspection_year AS item,
        ip.category AS item_2,
        COUNT(*) AS inspections,
        COUNT(DISTINCT f.license_no) AS establishments,
        COUNT(*) AS violations,
        SUM(CASE WHEN TRIM(ip.point_level) = 'Critical' THEN 1 ELSE 0 END) AS critical_violations,
        SUM(CASE WHEN TRIM(ip.point_level) = 'Serious' THEN 1 ELSE 0 END) AS serious_violations,
        SUM(CASE WHEN TRIM(ip.point_level) = 'Minor' THEN 1 ELSE 0 END) AS minor_violations,
        SUM(v.fine) AS total_fine,
        SUM(CASE WHEN f.result_group = 'pass' THEN 1 ELSE 0 END) AS pass_count,
        SUM(CASE WHEN f.result_group = 'conditional_pass' THEN 1 ELSE 0 END) AS conditional_count,
        SUM(CASE WHEN f.result_group = 'fail' THEN 1 ELSE 0 END) AS fail_count,
        ROW_NUMBER() OVER (PARTITION BY f.inspection_year ORDER BY COUNT(*) DESC, ip.category) AS category_rank
    FROM fact f
    JOIN violation v ON f.inspection_id = v.inspection_id
    JOIN inspection_point ip ON v.point_id = ip.point_id
    GROUP BY f.inspection_year, ip.category
),
ward_year AS (
    SELECT
        inspection_year AS item,
        ward AS item_2,
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
        ROW_NUMBER() OVER (PARTITION BY inspection_year ORDER BY COUNT(*) DESC, ward) AS ward_rank
    FROM fact
    GROUP BY inspection_year, ward
),
followup_year AS (
    SELECT
        inspection_year AS item,
        followup_status AS item_2,
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
        ROW_NUMBER() OVER (PARTITION BY inspection_year ORDER BY COUNT(*) DESC, followup_status) AS followup_rank
    FROM fact
    GROUP BY inspection_year, followup_status
)
SELECT
    'annual_result_trend' AS evidence_block,
    'year' AS grain,
    item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'inspection_volume_rank' AS rank_label,
    CAST(volume_rank AS DOUBLE) AS rank_value,
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
    'Establish whether inspection weakness changes over calendar years.' AS notes
FROM annual
UNION ALL
SELECT
    'quarter_seasonality_profile', 'year_quarter', item, item_2, CAST(NULL AS VARCHAR),
    'quarter_volume_rank_within_year', CAST(quarter_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT),
    CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT),
    CAST(total_fine AS DOUBLE), CAST(pass_count AS BIGINT), CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Check whether seasonal volume and weak outcomes move together.'
FROM quarterly
UNION ALL
SELECT
    'year_facility_type_shift', 'year_facility_type', item, item_2, CAST(NULL AS VARCHAR),
    'facility_volume_rank_within_year', CAST(facility_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT),
    CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT),
    CAST(total_fine AS DOUBLE), CAST(pass_count AS BIGINT), CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Separate time movement from facility-type mix changes.'
FROM year_facility
WHERE facility_rank <= 10
UNION ALL
SELECT
    'year_violation_category_shift', 'year_violation_category', item, item_2, CAST(NULL AS VARCHAR),
    'category_volume_rank_within_year', CAST(category_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT),
    CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT),
    CAST(total_fine AS DOUBLE), CAST(pass_count AS BIGINT), CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Identify whether the violation mix changes over time.'
FROM year_category
WHERE category_rank <= 10
UNION ALL
SELECT
    'ward_year_hotspots', 'year_ward', item, item_2, CAST(NULL AS VARCHAR),
    'ward_volume_rank_within_year', CAST(ward_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT),
    CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT),
    CAST(total_fine AS DOUBLE), CAST(pass_count AS BIGINT), CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Look for geography-specific temporal weak spots.'
FROM ward_year
WHERE ward_rank <= 10
UNION ALL
SELECT
    'followup_year_profile', 'year_followup_status', item, item_2, CAST(NULL AS VARCHAR),
    'followup_volume_rank_within_year', CAST(followup_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT),
    CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT),
    CAST(total_fine AS DOUBLE), CAST(pass_count AS BIGINT), CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Test whether follow-up activity changes the interpretation of annual trends.'
FROM followup_year;
