-- task_045_establishment_recurring_risk_evidence.sql
-- Draft task-level Evidence SQL for food_inspection_2.

WITH
inspection_base AS (
    SELECT
        i.inspection_id,
        i.inspection_date,
        i.inspection_type,
        i.results,
        CASE
            WHEN i.results = 'Pass' THEN 'pass'
            WHEN i.results = 'Pass w/ Conditions' THEN 'conditional_pass'
            WHEN i.results = 'Fail' THEN 'fail'
            ELSE 'other_result'
        END AS result_group,
        i.license_no,
        COALESCE(e.dba_name, CAST(i.license_no AS VARCHAR)) AS dba_name,
        COALESCE(NULLIF(TRIM(e.facility_type), ''), 'unknown') AS facility_type,
        COALESCE(CAST(e.risk_level AS VARCHAR), 'unknown') AS risk_level,
        COALESCE(CAST(e.ward AS VARCHAR), 'unknown') AS ward,
        COALESCE(CAST(e.zip AS VARCHAR), 'unknown') AS zip
    FROM inspection i
    JOIN establishment e ON i.license_no = e.license_no
),
violation_summary AS (
    SELECT
        v.inspection_id,
        COUNT(*) AS violations,
        SUM(CASE WHEN ip.point_level = 'Critical' THEN 1 ELSE 0 END) AS critical_violations,
        SUM(CASE WHEN ip.point_level = 'Serious' THEN 1 ELSE 0 END) AS serious_violations,
        SUM(CASE WHEN ip.point_level = 'Minor' THEN 1 ELSE 0 END) AS minor_violations,
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
facility_summary AS (
    SELECT
        CAST(license_no AS VARCHAR) AS item,
        dba_name AS item_2,
        facility_type AS item_3,
        facility_type,
        risk_level,
        ward,
        zip,
        COUNT(*) AS inspections,
        SUM(CASE WHEN result_group = 'pass' THEN 1 ELSE 0 END) AS pass_count,
        SUM(CASE WHEN result_group = 'conditional_pass' THEN 1 ELSE 0 END) AS conditional_count,
        SUM(CASE WHEN result_group = 'fail' THEN 1 ELSE 0 END) AS fail_count,
        SUM(CASE WHEN result_group IN ('conditional_pass', 'fail') THEN 1 ELSE 0 END) AS issue_inspections,
        SUM(violations) AS violations,
        SUM(critical_violations) AS critical_violations,
        SUM(serious_violations) AS serious_violations,
        SUM(minor_violations) AS minor_violations,
        SUM(total_fine) AS total_fine,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, SUM(total_fine) DESC, license_no) AS inspection_rank,
        ROW_NUMBER() OVER (ORDER BY SUM(CASE WHEN result_group IN ('conditional_pass', 'fail') THEN 1 ELSE 0 END) DESC, COUNT(*) DESC, license_no) AS issue_rank,
        ROW_NUMBER() OVER (ORDER BY SUM(total_fine) DESC, SUM(critical_violations) DESC, license_no) AS severity_rank
    FROM fact
    GROUP BY license_no, dba_name, facility_type, risk_level, ward, zip
),
risk_summary AS (
    SELECT
        risk_level AS item,
        SUM(inspections) AS inspections,
        COUNT(*) AS establishments,
        SUM(issue_inspections) AS issue_inspections,
        SUM(violations) AS violations,
        SUM(critical_violations) AS critical_violations,
        SUM(serious_violations) AS serious_violations,
        SUM(minor_violations) AS minor_violations,
        SUM(total_fine) AS total_fine,
        ROW_NUMBER() OVER (ORDER BY SUM(inspections) DESC, risk_level) AS volume_rank
    FROM facility_summary
    GROUP BY risk_level
),
facility_type_summary AS (
    SELECT
        facility_type AS item,
        COUNT(*) AS establishments,
        SUM(inspections) AS inspections,
        SUM(issue_inspections) AS issue_inspections,
        SUM(violations) AS violations,
        SUM(critical_violations) AS critical_violations,
        SUM(serious_violations) AS serious_violations,
        SUM(minor_violations) AS minor_violations,
        SUM(total_fine) AS total_fine,
        ROW_NUMBER() OVER (ORDER BY SUM(issue_inspections) DESC, SUM(inspections) DESC, facility_type) AS issue_rank
    FROM facility_summary
    GROUP BY facility_type
),
ward_summary AS (
    SELECT
        ward AS item,
        COUNT(*) AS establishments,
        SUM(inspections) AS inspections,
        SUM(issue_inspections) AS issue_inspections,
        SUM(violations) AS violations,
        SUM(critical_violations) AS critical_violations,
        SUM(serious_violations) AS serious_violations,
        SUM(minor_violations) AS minor_violations,
        SUM(total_fine) AS total_fine,
        ROW_NUMBER() OVER (ORDER BY SUM(issue_inspections) DESC, SUM(inspections) DESC, ward) AS issue_rank
    FROM facility_summary
    GROUP BY ward
),
facility_category AS (
    SELECT
        CAST(f.license_no AS VARCHAR) AS item,
        f.dba_name AS item_2,
        ip.category AS item_3,
        COUNT(*) AS violations,
        COUNT(DISTINCT f.inspection_id) AS inspections,
        SUM(CASE WHEN ip.point_level = 'Critical' THEN 1 ELSE 0 END) AS critical_violations,
        SUM(CASE WHEN ip.point_level = 'Serious' THEN 1 ELSE 0 END) AS serious_violations,
        SUM(CASE WHEN ip.point_level = 'Minor' THEN 1 ELSE 0 END) AS minor_violations,
        SUM(v.fine) AS total_fine,
        ROW_NUMBER() OVER (PARTITION BY f.license_no ORDER BY COUNT(*) DESC, ip.category) AS category_rank_in_facility
    FROM fact f
    JOIN violation v ON f.inspection_id = v.inspection_id
    JOIN inspection_point ip ON v.point_id = ip.point_id
    GROUP BY f.license_no, f.dba_name, ip.category
),
stable_facility_contrast AS (
    SELECT
        item,
        item_2,
        item_3,
        risk_level,
        ward,
        inspections,
        issue_inspections,
        violations,
        critical_violations,
        total_fine,
        ROW_NUMBER() OVER (ORDER BY inspections DESC, item) AS stable_rank
    FROM facility_summary
    WHERE issue_inspections = 0
)
SELECT
    'facility_inspection_frequency' AS evidence_block,
    'facility' AS grain,
    item,
    item_2,
    item_3,
    'inspection_rank' AS rank_label,
    CAST(inspection_rank AS DOUBLE) AS rank_value,
    CAST(inspections AS BIGINT) AS inspections,
    CAST(1 AS BIGINT) AS establishments,
    CAST(issue_inspections AS BIGINT) AS issue_inspections,
    CAST(violations AS BIGINT) AS violations,
    CAST(critical_violations AS BIGINT) AS critical_violations,
    CAST(serious_violations AS BIGINT) AS serious_violations,
    CAST(minor_violations AS BIGINT) AS minor_violations,
    CAST(total_fine AS DOUBLE) AS total_fine,
    CAST(pass_count AS BIGINT) AS pass_count,
    CAST(conditional_count AS BIGINT) AS conditional_count,
    CAST(fail_count AS BIGINT) AS fail_count,
    ROUND(100.0 * issue_inspections / NULLIF(inspections, 0), 4) AS issue_rate_pct,
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4) AS avg_violations_per_inspection,
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4) AS avg_fine_per_inspection,
    'Identify repeatedly inspected establishments before interpreting recurring concern.' AS notes
FROM facility_summary
WHERE inspection_rank <= 30
UNION ALL
SELECT
    'facility_repeat_issue_profile', 'facility', item, item_2, item_3,
    'issue_inspection_rank', CAST(issue_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(1 AS BIGINT), CAST(issue_inspections AS BIGINT),
    CAST(violations AS BIGINT), CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT),
    CAST(minor_violations AS BIGINT), CAST(total_fine AS DOUBLE),
    CAST(pass_count AS BIGINT), CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT),
    ROUND(100.0 * issue_inspections / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Locate establishments where conditional or failed outcomes recur.'
FROM facility_summary
WHERE issue_rank <= 30
UNION ALL
SELECT
    'facility_severity_profile', 'facility', item, item_2, item_3,
    'severity_rank', CAST(severity_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(1 AS BIGINT), CAST(issue_inspections AS BIGINT),
    CAST(violations AS BIGINT), CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT),
    CAST(minor_violations AS BIGINT), CAST(total_fine AS DOUBLE),
    CAST(pass_count AS BIGINT), CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT),
    ROUND(100.0 * issue_inspections / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Separate repeat concern from severity burden at establishment level.'
FROM facility_summary
WHERE severity_rank <= 30
UNION ALL
SELECT
    'risk_repeat_profile', 'risk_level', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'inspection_volume_rank', CAST(volume_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(issue_inspections AS BIGINT),
    CAST(violations AS BIGINT), CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT),
    CAST(minor_violations AS BIGINT), CAST(total_fine AS DOUBLE),
    CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT),
    ROUND(100.0 * issue_inspections / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Test whether recurring concern is concentrated by risk level.'
FROM risk_summary
UNION ALL
SELECT
    'facility_type_repeat_profile', 'facility_type', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'issue_rank', CAST(issue_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(issue_inspections AS BIGINT),
    CAST(violations AS BIGINT), CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT),
    CAST(minor_violations AS BIGINT), CAST(total_fine AS DOUBLE),
    CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT),
    ROUND(100.0 * issue_inspections / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Test whether recurring concern is concentrated by facility type.'
FROM facility_type_summary
WHERE issue_rank <= 30
UNION ALL
SELECT
    'ward_repeat_profile', 'ward', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'issue_rank', CAST(issue_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(issue_inspections AS BIGINT),
    CAST(violations AS BIGINT), CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT),
    CAST(minor_violations AS BIGINT), CAST(total_fine AS DOUBLE),
    CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT),
    ROUND(100.0 * issue_inspections / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Test whether recurring concern is geographically concentrated.'
FROM ward_summary
WHERE issue_rank <= 30
UNION ALL
SELECT
    'facility_violation_category_profile', 'facility_category', item, item_2, item_3,
    'category_rank_in_facility', CAST(category_rank_in_facility AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT),
    CAST(violations AS BIGINT), CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT),
    CAST(minor_violations AS BIGINT), CAST(total_fine AS DOUBLE),
    CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT),
    CAST(NULL AS DOUBLE),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Retain the leading violation categories for repeatedly concerning establishments.'
FROM facility_category
WHERE category_rank_in_facility <= 3
UNION ALL
SELECT
    'stable_facility_contrast', 'facility', item, item_2, item_3,
    'stable_high_inspection_rank', CAST(stable_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(1 AS BIGINT), CAST(issue_inspections AS BIGINT),
    CAST(violations AS BIGINT), CAST(critical_violations AS BIGINT), CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT), CAST(total_fine AS DOUBLE),
    CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT),
    CAST(0 AS DOUBLE),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Keep a contrast group of frequently inspected facilities without conditional or failed outcomes.'
FROM stable_facility_contrast
WHERE stable_rank <= 20;
