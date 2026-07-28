-- task_044_inspector_workload_mix_evidence.sql
-- Draft task-level Evidence SQL for food_inspection_2.

WITH
inspection_base AS (
    SELECT
        i.inspection_id,
        i.employee_id,
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
        COALESCE(NULLIF(TRIM(est.facility_type), ''), 'unknown') AS facility_type,
        COALESCE(CAST(est.risk_level AS VARCHAR), 'unknown') AS risk_level,
        COALESCE(CAST(est.ward AS VARCHAR), 'unknown') AS ward,
        emp.first_name || ' ' || emp.last_name AS inspector_name,
        emp.title AS inspector_title,
        COALESCE(CAST(emp.supervisor AS VARCHAR), 'no_supervisor') AS supervisor_id,
        COALESCE(sup.first_name || ' ' || sup.last_name, 'no_supervisor') AS supervisor_name
    FROM inspection i
    JOIN establishment est ON i.license_no = est.license_no
    JOIN employee emp ON i.employee_id = emp.employee_id
    LEFT JOIN employee sup ON emp.supervisor = sup.employee_id
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
inspector_summary AS (
    SELECT
        CAST(employee_id AS VARCHAR) AS item,
        inspector_name AS item_2,
        inspector_title AS item_3,
        COUNT(*) AS inspections,
        COUNT(DISTINCT license_no) AS establishments,
        COUNT(DISTINCT facility_type) AS facility_types,
        COUNT(DISTINCT risk_level) AS risk_levels,
        SUM(violations) AS violations,
        SUM(critical_violations) AS critical_violations,
        SUM(serious_violations) AS serious_violations,
        SUM(minor_violations) AS minor_violations,
        SUM(total_fine) AS total_fine,
        SUM(CASE WHEN result_group = 'pass' THEN 1 ELSE 0 END) AS pass_count,
        SUM(CASE WHEN result_group = 'conditional_pass' THEN 1 ELSE 0 END) AS conditional_count,
        SUM(CASE WHEN result_group = 'fail' THEN 1 ELSE 0 END) AS fail_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, employee_id) AS workload_rank,
        ROW_NUMBER() OVER (ORDER BY SUM(CASE WHEN result_group IN ('conditional_pass', 'fail') THEN 1 ELSE 0 END) DESC, COUNT(*) DESC, employee_id) AS issue_volume_rank
    FROM fact
    GROUP BY employee_id, inspector_name, inspector_title
),
inspector_risk_mix AS (
    SELECT
        CAST(employee_id AS VARCHAR) AS item,
        inspector_name AS item_2,
        risk_level AS item_3,
        COUNT(*) AS inspections,
        COUNT(DISTINCT license_no) AS establishments,
        SUM(violations) AS violations,
        SUM(critical_violations) AS critical_violations,
        SUM(serious_violations) AS serious_violations,
        SUM(minor_violations) AS minor_violations,
        SUM(total_fine) AS total_fine,
        ROW_NUMBER() OVER (PARTITION BY employee_id ORDER BY COUNT(*) DESC, risk_level) AS risk_rank_in_inspector
    FROM fact
    GROUP BY employee_id, inspector_name, risk_level
),
inspector_facility_mix AS (
    SELECT
        CAST(employee_id AS VARCHAR) AS item,
        inspector_name AS item_2,
        facility_type AS item_3,
        COUNT(*) AS inspections,
        COUNT(DISTINCT license_no) AS establishments,
        SUM(violations) AS violations,
        SUM(critical_violations) AS critical_violations,
        SUM(serious_violations) AS serious_violations,
        SUM(minor_violations) AS minor_violations,
        SUM(total_fine) AS total_fine,
        ROW_NUMBER() OVER (PARTITION BY employee_id ORDER BY COUNT(*) DESC, facility_type) AS facility_rank_in_inspector
    FROM fact
    GROUP BY employee_id, inspector_name, facility_type
),
supervisor_summary AS (
    SELECT
        supervisor_id AS item,
        supervisor_name AS item_2,
        COUNT(*) AS inspections,
        COUNT(DISTINCT employee_id) AS inspectors,
        COUNT(DISTINCT license_no) AS establishments,
        SUM(violations) AS violations,
        SUM(critical_violations) AS critical_violations,
        SUM(serious_violations) AS serious_violations,
        SUM(minor_violations) AS minor_violations,
        SUM(total_fine) AS total_fine,
        SUM(CASE WHEN result_group = 'pass' THEN 1 ELSE 0 END) AS pass_count,
        SUM(CASE WHEN result_group = 'conditional_pass' THEN 1 ELSE 0 END) AS conditional_count,
        SUM(CASE WHEN result_group = 'fail' THEN 1 ELSE 0 END) AS fail_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, supervisor_id) AS workload_rank
    FROM fact
    GROUP BY supervisor_id, supervisor_name
),
title_summary AS (
    SELECT
        inspector_title AS item,
        COUNT(*) AS inspections,
        COUNT(DISTINCT employee_id) AS inspectors,
        COUNT(DISTINCT license_no) AS establishments,
        SUM(violations) AS violations,
        SUM(critical_violations) AS critical_violations,
        SUM(serious_violations) AS serious_violations,
        SUM(minor_violations) AS minor_violations,
        SUM(total_fine) AS total_fine,
        SUM(CASE WHEN result_group = 'pass' THEN 1 ELSE 0 END) AS pass_count,
        SUM(CASE WHEN result_group = 'conditional_pass' THEN 1 ELSE 0 END) AS conditional_count,
        SUM(CASE WHEN result_group = 'fail' THEN 1 ELSE 0 END) AS fail_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, inspector_title) AS workload_rank
    FROM fact
    GROUP BY inspector_title
)
SELECT
    'inspector_workload_baseline' AS evidence_block,
    'inspector' AS grain,
    item,
    item_2,
    item_3,
    'workload_rank' AS rank_label,
    CAST(workload_rank AS DOUBLE) AS rank_value,
    CAST(inspections AS BIGINT) AS inspections,
    CAST(establishments AS BIGINT) AS establishments,
    CAST(facility_types AS BIGINT) AS facility_types,
    CAST(risk_levels AS BIGINT) AS risk_levels,
    CAST(violations AS BIGINT) AS violations,
    CAST(critical_violations AS BIGINT) AS critical_violations,
    CAST(serious_violations AS BIGINT) AS serious_violations,
    CAST(minor_violations AS BIGINT) AS minor_violations,
    CAST(total_fine AS DOUBLE) AS total_fine,
    CAST(pass_count AS BIGINT) AS pass_count,
    CAST(conditional_count AS BIGINT) AS conditional_count,
    CAST(fail_count AS BIGINT) AS fail_count,
    ROUND(100.0 * pass_count / NULLIF(inspections, 0), 4) AS pass_rate_pct,
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4) AS issue_rate_pct,
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4) AS avg_violations_per_inspection,
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4) AS avg_fine_per_inspection,
    'Establish inspection workload before comparing outcome patterns across inspectors.' AS notes
FROM inspector_summary
WHERE workload_rank <= 30 OR issue_volume_rank <= 30
UNION ALL
SELECT
    'inspector_risk_mix', 'inspector_risk_level', item, item_2, item_3,
    'risk_rank_in_inspector', CAST(risk_rank_in_inspector AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT),
    CAST(violations AS BIGINT), CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT),
    CAST(minor_violations AS BIGINT), CAST(total_fine AS DOUBLE),
    CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT),
    CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Separate inspector outcomes from the risk mix of assigned facilities.'
FROM inspector_risk_mix
WHERE risk_rank_in_inspector <= 3
UNION ALL
SELECT
    'inspector_facility_mix', 'inspector_facility_type', item, item_2, item_3,
    'facility_rank_in_inspector', CAST(facility_rank_in_inspector AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT),
    CAST(violations AS BIGINT), CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT),
    CAST(minor_violations AS BIGINT), CAST(total_fine AS DOUBLE),
    CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT),
    CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Separate inspector outcomes from the facility-type mix of assigned facilities.'
FROM inspector_facility_mix
WHERE facility_rank_in_inspector <= 3
UNION ALL
SELECT
    'supervisor_team_profile', 'supervisor_team', item, item_2, CAST(NULL AS VARCHAR),
    'workload_rank', CAST(workload_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(inspectors AS BIGINT), CAST(NULL AS BIGINT),
    CAST(violations AS BIGINT), CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT),
    CAST(minor_violations AS BIGINT), CAST(total_fine AS DOUBLE),
    CAST(pass_count AS BIGINT), CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT),
    ROUND(100.0 * pass_count / NULLIF(inspections, 0), 4),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Check whether inspector patterns cluster at supervisor-team level.'
FROM supervisor_summary
UNION ALL
SELECT
    'title_profile', 'employee_title', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'workload_rank', CAST(workload_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(inspectors AS BIGINT), CAST(NULL AS BIGINT),
    CAST(violations AS BIGINT), CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT),
    CAST(minor_violations AS BIGINT), CAST(total_fine AS DOUBLE),
    CAST(pass_count AS BIGINT), CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT),
    ROUND(100.0 * pass_count / NULLIF(inspections, 0), 4),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4),
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Compare work and outcome mix by employee title without treating it as direct staff performance.'
FROM title_summary;
