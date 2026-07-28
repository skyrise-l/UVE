-- task_043_followup_reinspection_recovery_evidence.sql
-- Draft task-level Evidence SQL for food_inspection_2.

WITH
inspection_base AS (
    SELECT
        i.inspection_id,
        i.followup_to,
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
        CASE WHEN ib.followup_to IS NULL THEN 'not_followup' ELSE 'followup' END AS followup_status,
        COALESCE(vs.violations, 0) AS violations,
        COALESCE(vs.critical_violations, 0) AS critical_violations,
        COALESCE(vs.serious_violations, 0) AS serious_violations,
        COALESCE(vs.minor_violations, 0) AS minor_violations,
        COALESCE(vs.total_fine, 0) AS total_fine
    FROM inspection_base ib
    LEFT JOIN violation_summary vs ON ib.inspection_id = vs.inspection_id
),
followup_baseline AS (
    SELECT
        followup_status AS item,
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
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, followup_status) AS volume_rank
    FROM fact
    GROUP BY followup_status
),
parent_child AS (
    SELECT
        c.inspection_id AS child_inspection_id,
        c.followup_to AS parent_inspection_id,
        c.license_no,
        c.result_group AS child_result_group,
        p.result_group AS parent_result_group,
        c.inspection_type AS child_inspection_type,
        p.inspection_type AS parent_inspection_type,
        c.facility_type,
        c.risk_level,
        c.ward,
        COALESCE(cv.violations, 0) AS child_violations,
        COALESCE(cv.critical_violations, 0) AS child_critical_violations,
        COALESCE(cv.serious_violations, 0) AS child_serious_violations,
        COALESCE(cv.minor_violations, 0) AS child_minor_violations,
        COALESCE(cv.total_fine, 0) AS child_total_fine,
        COALESCE(pv.violations, 0) AS parent_violations,
        COALESCE(pv.critical_violations, 0) AS parent_critical_violations,
        COALESCE(pv.serious_violations, 0) AS parent_serious_violations,
        COALESCE(pv.minor_violations, 0) AS parent_minor_violations,
        COALESCE(pv.total_fine, 0) AS parent_total_fine
    FROM inspection_base c
    JOIN inspection_base p ON c.followup_to = p.inspection_id
    LEFT JOIN violation_summary cv ON c.inspection_id = cv.inspection_id
    LEFT JOIN violation_summary pv ON p.inspection_id = pv.inspection_id
),
transition_summary AS (
    SELECT
        parent_result_group AS item,
        child_result_group AS item_2,
        COUNT(*) AS inspections,
        COUNT(DISTINCT license_no) AS establishments,
        SUM(child_violations) AS violations,
        SUM(child_critical_violations) AS critical_violations,
        SUM(child_serious_violations) AS serious_violations,
        SUM(child_minor_violations) AS minor_violations,
        SUM(child_total_fine) AS total_fine,
        SUM(parent_violations) AS parent_violations,
        SUM(parent_total_fine) AS parent_total_fine,
        ROW_NUMBER() OVER (PARTITION BY parent_result_group ORDER BY COUNT(*) DESC, child_result_group) AS child_result_rank
    FROM parent_child
    GROUP BY parent_result_group, child_result_group
),
facility_followup_summary AS (
    SELECT
        CAST(license_no AS VARCHAR) AS item,
        facility_type AS item_2,
        risk_level AS item_3,
        COUNT(*) AS inspections,
        SUM(CASE WHEN child_result_group = 'pass' THEN 1 ELSE 0 END) AS pass_count,
        SUM(CASE WHEN child_result_group = 'conditional_pass' THEN 1 ELSE 0 END) AS conditional_count,
        SUM(CASE WHEN child_result_group = 'fail' THEN 1 ELSE 0 END) AS fail_count,
        SUM(child_violations) AS violations,
        SUM(child_critical_violations) AS critical_violations,
        SUM(child_serious_violations) AS serious_violations,
        SUM(child_minor_violations) AS minor_violations,
        SUM(child_total_fine) AS total_fine,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, SUM(child_total_fine) DESC, license_no) AS followup_rank
    FROM parent_child
    GROUP BY license_no, facility_type, risk_level
),
ward_followup_summary AS (
    SELECT
        ward AS item,
        COUNT(*) AS inspections,
        COUNT(DISTINCT license_no) AS establishments,
        SUM(CASE WHEN child_result_group = 'pass' THEN 1 ELSE 0 END) AS pass_count,
        SUM(CASE WHEN child_result_group = 'conditional_pass' THEN 1 ELSE 0 END) AS conditional_count,
        SUM(CASE WHEN child_result_group = 'fail' THEN 1 ELSE 0 END) AS fail_count,
        SUM(child_violations) AS violations,
        SUM(child_critical_violations) AS critical_violations,
        SUM(child_serious_violations) AS serious_violations,
        SUM(child_minor_violations) AS minor_violations,
        SUM(child_total_fine) AS total_fine,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, ward) AS followup_rank
    FROM parent_child
    GROUP BY ward
),
severity_change_summary AS (
    SELECT
        parent_result_group AS item,
        child_result_group AS item_2,
        COUNT(*) AS inspections,
        COUNT(DISTINCT license_no) AS establishments,
        SUM(child_violations) AS violations,
        SUM(child_critical_violations) AS critical_violations,
        SUM(child_serious_violations) AS serious_violations,
        SUM(child_minor_violations) AS minor_violations,
        SUM(child_total_fine) AS total_fine,
        SUM(parent_violations) AS parent_violations,
        SUM(parent_total_fine) AS parent_total_fine,
        AVG(child_total_fine - parent_total_fine) AS avg_fine_change,
        AVG(child_violations - parent_violations) AS avg_violation_change
    FROM parent_child
    GROUP BY parent_result_group, child_result_group
),
parent_category AS (
    SELECT DISTINCT
        pc.parent_inspection_id,
        pc.child_inspection_id,
        ip.category
    FROM parent_child pc
    JOIN violation v ON pc.parent_inspection_id = v.inspection_id
    JOIN inspection_point ip ON v.point_id = ip.point_id
),
child_category AS (
    SELECT DISTINCT
        pc.parent_inspection_id,
        pc.child_inspection_id,
        ip.category
    FROM parent_child pc
    JOIN violation v ON pc.child_inspection_id = v.inspection_id
    JOIN inspection_point ip ON v.point_id = ip.point_id
),
persistent_category AS (
    SELECT
        pc.category AS item,
        COUNT(*) AS repeated_pairs,
        COUNT(DISTINCT pc.child_inspection_id) AS inspections,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, pc.category) AS persistence_rank
    FROM parent_category pc
    JOIN child_category cc
      ON pc.parent_inspection_id = cc.parent_inspection_id
     AND pc.child_inspection_id = cc.child_inspection_id
     AND pc.category = cc.category
    GROUP BY pc.category
)
SELECT
    'followup_baseline' AS evidence_block,
    'followup_status' AS grain,
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
    CAST(NULL AS DOUBLE) AS parent_violations,
    CAST(NULL AS DOUBLE) AS parent_total_fine,
    CAST(NULL AS DOUBLE) AS avg_violation_change,
    CAST(NULL AS DOUBLE) AS avg_fine_change,
    ROUND(100.0 * pass_count / NULLIF(inspections, 0), 4) AS pass_rate_pct,
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4) AS issue_rate_pct,
    'Compare follow-up activity with non-follow-up inspections before inferring recovery.' AS notes
FROM followup_baseline
UNION ALL
SELECT
    'parent_child_result_transition', 'parent_to_child_result', item, item_2, CAST(NULL AS VARCHAR),
    'child_result_rank_within_parent_result', CAST(child_result_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT),
    CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT),
    CAST(total_fine AS DOUBLE), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT),
    CAST(parent_violations AS DOUBLE), CAST(parent_total_fine AS DOUBLE), CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE),
    'Audit whether follow-up outcomes improve, remain conditional, or fail.'
FROM transition_summary
UNION ALL
SELECT
    'facility_followup_concentration', 'facility', item, item_2, item_3,
    'followup_volume_rank', CAST(followup_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(NULL AS BIGINT), CAST(violations AS BIGINT),
    CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT),
    CAST(total_fine AS DOUBLE), CAST(pass_count AS BIGINT), CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT),
    CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE),
    ROUND(100.0 * pass_count / NULLIF(inspections, 0), 4),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    'Locate facilities with concentrated follow-up activity.'
FROM facility_followup_summary
WHERE followup_rank <= 30
UNION ALL
SELECT
    'ward_followup_profile', 'ward', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'followup_volume_rank', CAST(followup_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT),
    CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT),
    CAST(total_fine AS DOUBLE), CAST(pass_count AS BIGINT), CAST(conditional_count AS BIGINT), CAST(fail_count AS BIGINT),
    CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE),
    ROUND(100.0 * pass_count / NULLIF(inspections, 0), 4),
    ROUND(100.0 * (conditional_count + fail_count) / NULLIF(inspections, 0), 4),
    'Check whether follow-up activity is geographically concentrated.'
FROM ward_followup_summary
WHERE followup_rank <= 30
UNION ALL
SELECT
    'followup_severity_change', 'parent_to_child_result', item, item_2, CAST(NULL AS VARCHAR),
    'transition_group', CAST(NULL AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(establishments AS BIGINT), CAST(violations AS BIGINT),
    CAST(critical_violations AS BIGINT), CAST(serious_violations AS BIGINT), CAST(minor_violations AS BIGINT),
    CAST(total_fine AS DOUBLE), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT),
    CAST(parent_violations AS DOUBLE), CAST(parent_total_fine AS DOUBLE),
    ROUND(avg_violation_change, 4), ROUND(avg_fine_change, 4),
    CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE),
    'Compare severity burden on the child inspection with its parent inspection.'
FROM severity_change_summary
UNION ALL
SELECT
    'persistent_violation_category', 'violation_category', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'persistence_rank', CAST(persistence_rank AS DOUBLE),
    CAST(inspections AS BIGINT), CAST(NULL AS BIGINT), CAST(repeated_pairs AS BIGINT),
    CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT),
    CAST(NULL AS DOUBLE), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT),
    CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE),
    'Identify violation categories that recur across parent and follow-up inspections.'
FROM persistent_category
WHERE persistence_rank <= 20;
