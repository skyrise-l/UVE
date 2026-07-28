-- task_047_inspection_type_strategy_evidence.sql
-- Final task-level Evidence SQL for food_inspection_2.

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
        CASE WHEN i.followup_to IS NULL THEN 'not_followup' ELSE 'followup' END AS followup_status,
        i.employee_id,
        i.license_no,
        COALESCE(NULLIF(TRIM(e.facility_type), ''), 'unknown') AS facility_type,
        COALESCE(CAST(e.risk_level AS VARCHAR), 'unknown') AS risk_level,
        COALESCE(CAST(e.ward AS VARCHAR), 'unknown') AS ward
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
type_baseline AS (
    SELECT
        inspection_type AS item,
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
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, inspection_type) AS volume_rank
    FROM fact
    GROUP BY inspection_type
),
type_result AS (
    SELECT
        inspection_type AS item,
        result_group AS item_2,
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
        ROW_NUMBER() OVER (PARTITION BY inspection_type ORDER BY COUNT(*) DESC, result_group) AS result_rank
    FROM fact
    GROUP BY inspection_type, result_group
),
type_facility AS (
    SELECT
        inspection_type AS item,
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
        ROW_NUMBER() OVER (PARTITION BY inspection_type ORDER BY COUNT(*) DESC, facility_type) AS facility_rank
    FROM fact
    GROUP BY inspection_type, facility_type
),
type_severity AS (
    SELECT
        f.inspection_type AS item,
        ip.point_level AS item_2,
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
        ROW_NUMBER() OVER (PARTITION BY f.inspection_type ORDER BY COUNT(*) DESC, ip.point_level) AS severity_rank
    FROM fact f
    JOIN violation v ON f.inspection_id = v.inspection_id
    JOIN inspection_point ip ON v.point_id = ip.point_id
    GROUP BY f.inspection_type, ip.point_level
),
type_followup AS (
    SELECT
        inspection_type AS item,
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
        ROW_NUMBER() OVER (PARTITION BY inspection_type ORDER BY COUNT(*) DESC, followup_status) AS followup_rank
    FROM fact
    GROUP BY inspection_type, followup_status
),
type_ward AS (
    SELECT
        inspection_type AS item,
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
        ROW_NUMBER() OVER (PARTITION BY inspection_type ORDER BY COUNT(*) DESC, ward) AS ward_rank
    FROM fact
    GROUP BY inspection_type, ward
)
SELECT
    'inspection_type_baseline' AS evidence_block,
    'inspection_type' AS grain,
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
    'Establish the volume and outcome baseline for each inspection type.' AS notes
FROM type_baseline
UNION ALL
SELECT
    'inspection_type_result_profile', 'inspection_type_result', item, item_2, CAST(NULL AS VARCHAR),
    'result_rank_within_type', CAST(result_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT),
    CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT),
    CAST(total_fine AS DOUBLE), CAST(pass_count AS BIGINT), CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Separate high-volume inspection types from weak-outcome inspection types.'
FROM type_result
UNION ALL
SELECT
    'inspection_type_facility_mix', 'inspection_type_facility_type', item, item_2, CAST(NULL AS VARCHAR),
    'facility_rank_within_type', CAST(facility_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT),
    CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT),
    CAST(total_fine AS DOUBLE), CAST(pass_count AS BIGINT), CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Check whether type differences mainly reflect facility mix.'
FROM type_facility
WHERE facility_rank <= 10
UNION ALL
SELECT
    'inspection_type_severity_profile', 'inspection_type_point_level', item, item_2, CAST(NULL AS VARCHAR),
    'severity_rank_within_type', CAST(severity_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT),
    CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT),
    CAST(total_fine AS DOUBLE), CAST(pass_count AS BIGINT), CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Test whether some inspection types carry a different severity mix.'
FROM type_severity
UNION ALL
SELECT
    'inspection_type_followup_linkage', 'inspection_type_followup_status', item, item_2, CAST(NULL AS VARCHAR),
    'followup_rank_within_type', CAST(followup_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT),
    CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT),
    CAST(total_fine AS DOUBLE), CAST(pass_count AS BIGINT), CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Identify whether inspection types serve initial screening or recovery functions.'
FROM type_followup
UNION ALL
SELECT
    'inspection_type_ward_profile', 'inspection_type_ward', item, item_2, CAST(NULL AS VARCHAR),
    'ward_rank_within_type', CAST(ward_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT),
    CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT),
    CAST(total_fine AS DOUBLE), CAST(pass_count AS BIGINT), CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Look for geographically concentrated inspection-type strategies.'
FROM type_ward
WHERE ward_rank <= 10;
