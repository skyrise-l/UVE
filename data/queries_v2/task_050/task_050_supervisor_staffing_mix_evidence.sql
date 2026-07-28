-- task_050_supervisor_staffing_mix_evidence.sql
-- Final task-level Evidence SQL for food_inspection_2.

WITH
employee_base AS (
    SELECT
        e.employee_id,
        e.first_name || ' ' || e.last_name AS employee_name,
        COALESCE(e.title, 'unknown') AS title,
        COALESCE(e.city, 'unknown') AS employee_city,
        e.salary,
        CASE
            WHEN e.salary IS NULL THEN 'unknown_salary'
            WHEN e.salary < 50000 THEN 'lower_salary_band'
            WHEN e.salary < 80000 THEN 'middle_salary_band'
            ELSE 'higher_salary_band'
        END AS salary_band,
        e.supervisor,
        COALESCE(s.first_name || ' ' || s.last_name, 'no_supervisor') AS supervisor_name
    FROM employee e
    LEFT JOIN employee s ON e.supervisor = s.employee_id
),
inspection_base AS (
    SELECT
        i.inspection_id,
        i.employee_id,
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
        COALESCE(CAST(est.ward AS VARCHAR), 'unknown') AS ward
    FROM inspection i
    JOIN establishment est ON i.license_no = est.license_no
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
        eb.employee_name,
        eb.title,
        eb.employee_city,
        eb.salary_band,
        eb.supervisor_name,
        COALESCE(vs.violations, 0) AS violations,
        COALESCE(vs.critical_violations, 0) AS critical_violations,
        COALESCE(vs.serious_violations, 0) AS serious_violations,
        COALESCE(vs.minor_violations, 0) AS minor_violations,
        COALESCE(vs.total_fine, 0) AS total_fine
    FROM inspection_base ib
    JOIN employee_base eb ON ib.employee_id = eb.employee_id
    LEFT JOIN violation_summary vs ON ib.inspection_id = vs.inspection_id
),
supervisor_base AS (
    SELECT supervisor_name AS item, COUNT(*) AS inspections, COUNT(DISTINCT employee_id) AS establishments,
        SUM(violations) AS violations, SUM(critical_violations) AS critical_violations,
        SUM(serious_violations) AS serious_violations, SUM(minor_violations) AS minor_violations,
        SUM(total_fine) AS total_fine,
        SUM(CASE WHEN result_group = 'pass' THEN 1 ELSE 0 END) AS pass_count,
        SUM(CASE WHEN result_group = 'conditional_pass' THEN 1 ELSE 0 END) AS conditional_count,
        SUM(CASE WHEN result_group = 'fail' THEN 1 ELSE 0 END) AS fail_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, supervisor_name) AS volume_rank
    FROM fact GROUP BY supervisor_name
),
salary_base AS (
    SELECT salary_band AS item, COUNT(*) AS inspections, COUNT(DISTINCT employee_id) AS establishments,
        SUM(violations) AS violations, SUM(critical_violations) AS critical_violations,
        SUM(serious_violations) AS serious_violations, SUM(minor_violations) AS minor_violations,
        SUM(total_fine) AS total_fine,
        SUM(CASE WHEN result_group = 'pass' THEN 1 ELSE 0 END) AS pass_count,
        SUM(CASE WHEN result_group = 'conditional_pass' THEN 1 ELSE 0 END) AS conditional_count,
        SUM(CASE WHEN result_group = 'fail' THEN 1 ELSE 0 END) AS fail_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, salary_band) AS volume_rank
    FROM fact GROUP BY salary_band
),
supervisor_facility AS (
    SELECT supervisor_name AS item, facility_type AS item_2, COUNT(*) AS inspections, COUNT(DISTINCT employee_id) AS establishments,
        SUM(violations) AS violations, SUM(critical_violations) AS critical_violations,
        SUM(serious_violations) AS serious_violations, SUM(minor_violations) AS minor_violations,
        SUM(total_fine) AS total_fine,
        SUM(CASE WHEN result_group = 'pass' THEN 1 ELSE 0 END) AS pass_count,
        SUM(CASE WHEN result_group = 'conditional_pass' THEN 1 ELSE 0 END) AS conditional_count,
        SUM(CASE WHEN result_group = 'fail' THEN 1 ELSE 0 END) AS fail_count,
        ROW_NUMBER() OVER (PARTITION BY supervisor_name ORDER BY COUNT(*) DESC, facility_type) AS rank_in_supervisor
    FROM fact GROUP BY supervisor_name, facility_type
),
supervisor_risk AS (
    SELECT supervisor_name AS item, risk_level AS item_2, COUNT(*) AS inspections, COUNT(DISTINCT employee_id) AS establishments,
        SUM(violations) AS violations, SUM(critical_violations) AS critical_violations,
        SUM(serious_violations) AS serious_violations, SUM(minor_violations) AS minor_violations,
        SUM(total_fine) AS total_fine,
        SUM(CASE WHEN result_group = 'pass' THEN 1 ELSE 0 END) AS pass_count,
        SUM(CASE WHEN result_group = 'conditional_pass' THEN 1 ELSE 0 END) AS conditional_count,
        SUM(CASE WHEN result_group = 'fail' THEN 1 ELSE 0 END) AS fail_count,
        ROW_NUMBER() OVER (PARTITION BY supervisor_name ORDER BY COUNT(*) DESC, risk_level) AS rank_in_supervisor
    FROM fact GROUP BY supervisor_name, risk_level
),
supervisor_category AS (
    SELECT f.supervisor_name AS item, ip.category AS item_2, COUNT(*) AS inspections, COUNT(DISTINCT f.employee_id) AS establishments,
        COUNT(*) AS violations,
        SUM(CASE WHEN TRIM(ip.point_level) = 'Critical' THEN 1 ELSE 0 END) AS critical_violations,
        SUM(CASE WHEN TRIM(ip.point_level) = 'Serious' THEN 1 ELSE 0 END) AS serious_violations,
        SUM(CASE WHEN TRIM(ip.point_level) = 'Minor' THEN 1 ELSE 0 END) AS minor_violations,
        SUM(v.fine) AS total_fine,
        SUM(CASE WHEN f.result_group = 'pass' THEN 1 ELSE 0 END) AS pass_count,
        SUM(CASE WHEN f.result_group = 'conditional_pass' THEN 1 ELSE 0 END) AS conditional_count,
        SUM(CASE WHEN f.result_group = 'fail' THEN 1 ELSE 0 END) AS fail_count,
        ROW_NUMBER() OVER (PARTITION BY f.supervisor_name ORDER BY COUNT(*) DESC, ip.category) AS rank_in_supervisor
    FROM fact f
    JOIN violation v ON f.inspection_id = v.inspection_id
    JOIN inspection_point ip ON v.point_id = ip.point_id
    GROUP BY f.supervisor_name, ip.category
)
SELECT
    'supervisor_baseline' AS evidence_block, 'supervisor' AS grain, item, CAST(NULL AS VARCHAR) AS item_2, CAST(NULL AS VARCHAR) AS item_3,
    'inspection_volume_rank' AS rank_label, CAST(volume_rank AS DOUBLE) AS rank_value,
    CAST(inspections AS BIGINT) AS inspections, CAST(establishments AS BIGINT) AS inspectors,
    CAST(violations AS BIGINT) AS violations, CAST(critical_violations AS BIGINT) AS critical_violations,
    CAST(serious_violations AS BIGINT) AS serious_violations, CAST(minor_violations AS BIGINT) AS minor_violations,
    CAST(total_fine AS DOUBLE) AS total_fine, CAST(pass_count AS BIGINT) AS pass_count,
    CAST(conditional_count AS BIGINT) AS conditional_count, CAST(fail_count AS BIGINT) AS fail_count,
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4) AS issue_rate_pct,
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4) AS avg_violations_per_inspection,
    ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4) AS avg_fine_per_inspection,
    'Establish whether supervisor groups differ materially before interpreting team quality.' AS notes
FROM supervisor_base
UNION ALL
SELECT 'salary_band_profile', 'salary_band', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), 'inspection_volume_rank', CAST(volume_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT), CAST(critical_violations AS BIGINT),
    CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT), CAST(total_fine AS DOUBLE), CAST(pass_count AS BIGINT),
    CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4), ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Check whether staff compensation bands explain observed outcome differences.'
FROM salary_base
UNION ALL
SELECT 'supervisor_facility_mix', 'supervisor_facility_type', item, item_2, CAST(NULL AS VARCHAR), 'facility_rank_within_supervisor', CAST(rank_in_supervisor AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT), CAST(critical_violations AS BIGINT),
    CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT), CAST(total_fine AS DOUBLE), CAST(pass_count AS BIGINT),
    CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4), ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Separate team outcome differences from facility assignment mix.'
FROM supervisor_facility WHERE rank_in_supervisor <= 8
UNION ALL
SELECT 'supervisor_risk_mix', 'supervisor_risk_level', item, item_2, CAST(NULL AS VARCHAR), 'risk_rank_within_supervisor', CAST(rank_in_supervisor AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT), CAST(critical_violations AS BIGINT),
    CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT), CAST(total_fine AS DOUBLE), CAST(pass_count AS BIGINT),
    CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4), ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Check whether supervisor differences are mainly driven by risk-level assignment.'
FROM supervisor_risk
UNION ALL
SELECT 'supervisor_violation_category', 'supervisor_violation_category', item, item_2, CAST(NULL AS VARCHAR), 'category_rank_within_supervisor', CAST(rank_in_supervisor AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT), CAST(critical_violations AS BIGINT),
    CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT), CAST(total_fine AS DOUBLE), CAST(pass_count AS BIGINT),
    CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    ROUND(1.0 * violations / NULLIF(inspections, 0), 4), ROUND(1.0 * total_fine / NULLIF(inspections, 0), 4),
    'Look for content differences in the violations surfaced by each supervisor group.'
FROM supervisor_category WHERE rank_in_supervisor <= 8;
