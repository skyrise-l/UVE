-- task_041_inspection_outcome_structure_evidence.sql
-- Draft task-level Evidence SQL for food_inspection_2.
-- Use full results to calibrate final named objects, rankings, and numeric anchors.

WITH
inspection_base AS (
    SELECT
        i.inspection_id,
        i.inspection_date,
        SUBSTR(CAST(i.inspection_date AS VARCHAR), 1, 4) AS inspection_year,
        i.inspection_type,
        i.results,
        CASE
            WHEN i.results = 'Pass' THEN 'pass'
            WHEN i.results = 'Pass w/ Conditions' THEN 'conditional_pass'
            WHEN i.results = 'Fail' THEN 'fail'
            ELSE 'other_result'
        END AS result_group,
        CASE WHEN i.followup_to IS NULL THEN 'initial_or_unlinked' ELSE 'followup' END AS followup_group,
        i.employee_id,
        i.license_no,
        COALESCE(NULLIF(TRIM(e.facility_type), ''), 'unknown') AS facility_type,
        COALESCE(CAST(e.risk_level AS VARCHAR), 'unknown') AS risk_level,
        COALESCE(CAST(e.ward AS VARCHAR), 'unknown') AS ward,
        COALESCE(e.city, 'unknown') AS city
    FROM inspection i
    JOIN establishment e ON i.license_no = e.license_no
),
violation_by_inspection AS (
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
        COALESCE(vbi.violations, 0) AS violations,
        COALESCE(vbi.critical_violations, 0) AS critical_violations,
        COALESCE(vbi.serious_violations, 0) AS serious_violations,
        COALESCE(vbi.minor_violations, 0) AS minor_violations,
        COALESCE(vbi.total_fine, 0) AS total_fine
    FROM inspection_base ib
    LEFT JOIN violation_by_inspection vbi ON ib.inspection_id = vbi.inspection_id
),
result_summary AS (
    SELECT
        result_group AS item,
        COUNT(*) AS inspections,
        COUNT(DISTINCT license_no) AS establishments,
        SUM(violations) AS violations,
        SUM(critical_violations) AS critical_violations,
        SUM(serious_violations) AS serious_violations,
        SUM(minor_violations) AS minor_violations,
        SUM(total_fine) AS total_fine,
        SUM(CASE WHEN violations > 0 THEN 1 ELSE 0 END) AS inspections_with_violations,
        SUM(CASE WHEN result_group = 'pass' THEN 1 ELSE 0 END) AS pass_count,
        SUM(CASE WHEN result_group = 'conditional_pass' THEN 1 ELSE 0 END) AS conditional_count,
        SUM(CASE WHEN result_group = 'fail' THEN 1 ELSE 0 END) AS fail_count,
        SUM(CASE WHEN result_group = 'other_result' THEN 1 ELSE 0 END) AS other_count
    FROM fact
    GROUP BY result_group
),
risk_summary AS (
    SELECT
        risk_level AS item,
        COUNT(*) AS inspections,
        COUNT(DISTINCT license_no) AS establishments,
        SUM(violations) AS violations,
        SUM(critical_violations) AS critical_violations,
        SUM(serious_violations) AS serious_violations,
        SUM(minor_violations) AS minor_violations,
        SUM(total_fine) AS total_fine,
        SUM(CASE WHEN violations > 0 THEN 1 ELSE 0 END) AS inspections_with_violations,
        SUM(CASE WHEN result_group = 'pass' THEN 1 ELSE 0 END) AS pass_count,
        SUM(CASE WHEN result_group = 'conditional_pass' THEN 1 ELSE 0 END) AS conditional_count,
        SUM(CASE WHEN result_group = 'fail' THEN 1 ELSE 0 END) AS fail_count,
        SUM(CASE WHEN result_group = 'other_result' THEN 1 ELSE 0 END) AS other_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, risk_level) AS volume_rank
    FROM fact
    GROUP BY risk_level
),
facility_type_summary AS (
    SELECT
        facility_type AS item,
        COUNT(*) AS inspections,
        COUNT(DISTINCT license_no) AS establishments,
        SUM(violations) AS violations,
        SUM(critical_violations) AS critical_violations,
        SUM(serious_violations) AS serious_violations,
        SUM(minor_violations) AS minor_violations,
        SUM(total_fine) AS total_fine,
        SUM(CASE WHEN violations > 0 THEN 1 ELSE 0 END) AS inspections_with_violations,
        SUM(CASE WHEN result_group = 'pass' THEN 1 ELSE 0 END) AS pass_count,
        SUM(CASE WHEN result_group = 'conditional_pass' THEN 1 ELSE 0 END) AS conditional_count,
        SUM(CASE WHEN result_group = 'fail' THEN 1 ELSE 0 END) AS fail_count,
        SUM(CASE WHEN result_group = 'other_result' THEN 1 ELSE 0 END) AS other_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, facility_type) AS volume_rank
    FROM fact
    GROUP BY facility_type
),
ward_summary AS (
    SELECT
        ward AS item,
        COUNT(*) AS inspections,
        COUNT(DISTINCT license_no) AS establishments,
        SUM(violations) AS violations,
        SUM(critical_violations) AS critical_violations,
        SUM(serious_violations) AS serious_violations,
        SUM(minor_violations) AS minor_violations,
        SUM(total_fine) AS total_fine,
        SUM(CASE WHEN violations > 0 THEN 1 ELSE 0 END) AS inspections_with_violations,
        SUM(CASE WHEN result_group = 'pass' THEN 1 ELSE 0 END) AS pass_count,
        SUM(CASE WHEN result_group = 'conditional_pass' THEN 1 ELSE 0 END) AS conditional_count,
        SUM(CASE WHEN result_group = 'fail' THEN 1 ELSE 0 END) AS fail_count,
        SUM(CASE WHEN result_group = 'other_result' THEN 1 ELSE 0 END) AS other_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, ward) AS volume_rank
    FROM fact
    GROUP BY ward
),
followup_summary AS (
    SELECT
        followup_group AS item,
        inspection_type AS item_2,
        COUNT(*) AS inspections,
        COUNT(DISTINCT license_no) AS establishments,
        SUM(violations) AS violations,
        SUM(critical_violations) AS critical_violations,
        SUM(serious_violations) AS serious_violations,
        SUM(minor_violations) AS minor_violations,
        SUM(total_fine) AS total_fine,
        SUM(CASE WHEN violations > 0 THEN 1 ELSE 0 END) AS inspections_with_violations,
        SUM(CASE WHEN result_group = 'pass' THEN 1 ELSE 0 END) AS pass_count,
        SUM(CASE WHEN result_group = 'conditional_pass' THEN 1 ELSE 0 END) AS conditional_count,
        SUM(CASE WHEN result_group = 'fail' THEN 1 ELSE 0 END) AS fail_count,
        SUM(CASE WHEN result_group = 'other_result' THEN 1 ELSE 0 END) AS other_count,
        ROW_NUMBER() OVER (PARTITION BY followup_group ORDER BY COUNT(*) DESC, inspection_type) AS type_rank
    FROM fact
    GROUP BY followup_group, inspection_type
)
SELECT
    'result_baseline' AS evidence_block,
    'inspection_result' AS grain,
    item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'inspection_volume_rank' AS rank_label,
    CAST(ROW_NUMBER() OVER (ORDER BY inspections DESC, item) AS DOUBLE) AS rank_value,
    CAST(inspections AS BIGINT) AS inspections,
    CAST(establishments AS BIGINT) AS establishments,
    CAST(violations AS BIGINT) AS violations,
    CAST(critical_violations AS BIGINT) AS critical_violations,
    CAST(serious_violations AS BIGINT) AS serious_violations,
    CAST(minor_violations AS BIGINT) AS minor_violations,
    CAST(total_fine AS DOUBLE) AS total_fine,
    CAST(inspections_with_violations AS BIGINT) AS inspections_with_violations,
    CAST(pass_count AS BIGINT) AS pass_count,
    CAST(conditional_count AS BIGINT) AS conditional_count,
    CAST(fail_count AS BIGINT) AS fail_count,
    CAST(other_count AS BIGINT) AS other_count,
    ROUND(100.0 * pass_count / NULLIF(inspections, 0), 4) AS pass_rate_pct,
    ROUND(100.0 * conditional_count / NULLIF(inspections, 0), 4) AS conditional_rate_pct,
    ROUND(100.0 * fail_count / NULLIF(inspections, 0), 4) AS fail_rate_pct,
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4) AS issue_rate_pct,
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4) AS avg_violations_per_inspection,
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4) AS avg_fine_per_inspection,
    'Establish the outcome baseline before explaining weak inspection results.' AS notes
FROM result_summary
UNION ALL
SELECT
    'risk_result_profile', 'risk_level', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'inspection_volume_rank', CAST(volume_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT),
    CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT),
    CAST(total_fine AS DOUBLE), CAST(inspections_with_violations AS BIGINT),
    CAST(pass_count AS BIGINT), CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT), CAST(other_count AS BIGINT),
    ROUND(100.0 * pass_count / NULLIF(inspections, 0), 4),
    ROUND(100.0 * conditional_count / NULLIF(inspections, 0), 4),
    ROUND(100.0 * fail_count / NULLIF(inspections, 0), 4),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Test whether facility risk level actually aligns with weaker outcomes.'
FROM risk_summary
UNION ALL
SELECT
    'facility_type_result_profile', 'facility_type', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'inspection_volume_rank', CAST(volume_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT),
    CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT),
    CAST(total_fine AS DOUBLE), CAST(inspections_with_violations AS BIGINT),
    CAST(pass_count AS BIGINT), CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT), CAST(other_count AS BIGINT),
    ROUND(100.0 * pass_count / NULLIF(inspections, 0), 4),
    ROUND(100.0 * conditional_count / NULLIF(inspections, 0), 4),
    ROUND(100.0 * fail_count / NULLIF(inspections, 0), 4),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Identify high-volume facility types whose outcomes or severity burden diverge from the baseline.'
FROM facility_type_summary
WHERE volume_rank <= 30
UNION ALL
SELECT
    'ward_result_profile', 'ward', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'inspection_volume_rank', CAST(volume_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT),
    CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT),
    CAST(total_fine AS DOUBLE), CAST(inspections_with_violations AS BIGINT),
    CAST(pass_count AS BIGINT), CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT), CAST(other_count AS BIGINT),
    ROUND(100.0 * pass_count / NULLIF(inspections, 0), 4),
    ROUND(100.0 * conditional_count / NULLIF(inspections, 0), 4),
    ROUND(100.0 * fail_count / NULLIF(inspections, 0), 4),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Check whether weak outcomes are geographically localized rather than citywide.'
FROM ward_summary
WHERE volume_rank <= 30
UNION ALL
SELECT
    'followup_type_profile', 'followup_status_and_type', item, item_2, CAST(NULL AS VARCHAR),
    'type_rank_within_followup_status', CAST(type_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT),
    CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT),
    CAST(total_fine AS DOUBLE), CAST(inspections_with_violations AS BIGINT),
    CAST(pass_count AS BIGINT), CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT), CAST(other_count AS BIGINT),
    ROUND(100.0 * pass_count / NULLIF(inspections, 0), 4),
    ROUND(100.0 * conditional_count / NULLIF(inspections, 0), 4),
    ROUND(100.0 * fail_count / NULLIF(inspections, 0), 4),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Separate initial inspections from follow-up and re-inspection activity.'
FROM followup_summary
WHERE type_rank <= 15;
