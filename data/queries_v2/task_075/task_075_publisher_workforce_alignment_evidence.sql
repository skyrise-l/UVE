WITH
title_base AS (
    SELECT
        title_id,
        pub_id,
        type,
        CASE WHEN price IS NULL THEN NULL ELSE CAST(price AS DOUBLE) END AS price_num,
        COALESCE(CAST(ytd_sales AS DOUBLE), 0) AS ytd_sales_num
    FROM titles
),
sales_by_title AS (
    SELECT
        title_id,
        COUNT(DISTINCT ord_num) AS order_count,
        COUNT(*) AS sale_lines,
        SUM(CAST(qty AS DOUBLE)) AS sample_qty
    FROM sales
    GROUP BY title_id
),
publisher_sales AS (
    SELECT
        tb.pub_id,
        COUNT(DISTINCT tb.title_id) AS title_count,
        COUNT(DISTINCT tb.type) AS type_count,
        SUM(COALESCE(sbt.order_count, 0)) AS order_count,
        SUM(COALESCE(sbt.sale_lines, 0)) AS sale_lines,
        SUM(COALESCE(sbt.sample_qty, 0)) AS sample_qty,
        SUM(COALESCE(sbt.sample_qty, 0) * COALESCE(tb.price_num, 0)) AS revenue_proxy,
        SUM(tb.ytd_sales_num) AS ytd_sales,
        SUM(tb.ytd_sales_num * COALESCE(tb.price_num, 0)) AS ytd_revenue_proxy
    FROM title_base tb
    LEFT JOIN sales_by_title sbt ON tb.title_id = sbt.title_id
    GROUP BY tb.pub_id
),
publisher_staff AS (
    SELECT
        e.pub_id,
        COUNT(*) AS employee_count,
        COUNT(DISTINCT e.job_id) AS job_role_count,
        AVG(CAST(e.job_lvl AS DOUBLE)) AS avg_job_level,
        MIN(CAST(e.job_lvl AS DOUBLE)) AS min_job_level,
        MAX(CAST(e.job_lvl AS DOUBLE)) AS max_job_level,
        MIN(e.hire_date) AS first_hire_date,
        MAX(e.hire_date) AS latest_hire_date
    FROM employee e
    GROUP BY e.pub_id
),
publisher_alignment AS (
    SELECT
        p.pub_id,
        p.pub_name,
        p.country,
        COALESCE(ps.employee_count, 0) AS employee_count,
        COALESCE(ps.job_role_count, 0) AS job_role_count,
        ps.avg_job_level,
        ps.min_job_level,
        ps.max_job_level,
        ps.first_hire_date,
        ps.latest_hire_date,
        COALESCE(s.title_count, 0) AS title_count,
        COALESCE(s.type_count, 0) AS type_count,
        COALESCE(s.order_count, 0) AS order_count,
        COALESCE(s.sale_lines, 0) AS sale_lines,
        COALESCE(s.sample_qty, 0) AS sample_qty,
        COALESCE(s.revenue_proxy, 0) AS revenue_proxy,
        COALESCE(s.ytd_sales, 0) AS ytd_sales,
        COALESCE(s.ytd_revenue_proxy, 0) AS ytd_revenue_proxy,
        CASE
            WHEN COALESCE(ps.employee_count, 0) = 0 THEN NULL
            ELSE COALESCE(s.revenue_proxy, 0) / ps.employee_count
        END AS revenue_per_employee,
        CASE
            WHEN COALESCE(ps.employee_count, 0) = 0 THEN NULL
            ELSE COALESCE(s.title_count, 0) * 1.0 / ps.employee_count
        END AS titles_per_employee
    FROM publishers p
    LEFT JOIN publisher_staff ps ON p.pub_id = ps.pub_id
    LEFT JOIN publisher_sales s ON p.pub_id = s.pub_id
),
ranked_alignment AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY revenue_proxy DESC, pub_name) AS revenue_rank,
        ROW_NUMBER() OVER (ORDER BY employee_count DESC, pub_name) AS staff_rank,
        ROW_NUMBER() OVER (ORDER BY avg_job_level DESC NULLS LAST, pub_name) AS avg_level_rank,
        100.0 * revenue_proxy / NULLIF(SUM(revenue_proxy) OVER (), 0) AS revenue_share_pct
    FROM publisher_alignment
),
job_distribution AS (
    SELECT
        j.job_id,
        j.job_desc,
        j.min_lvl,
        j.max_lvl,
        COUNT(e.emp_id) AS employee_count,
        COUNT(DISTINCT e.pub_id) AS publisher_count,
        AVG(CAST(e.job_lvl AS DOUBLE)) AS avg_job_level,
        MIN(CAST(e.job_lvl AS DOUBLE)) AS observed_min_level,
        MAX(CAST(e.job_lvl AS DOUBLE)) AS observed_max_level
    FROM jobs j
    LEFT JOIN employee e ON j.job_id = e.job_id
    GROUP BY j.job_id, j.job_desc, j.min_lvl, j.max_lvl
),
publisher_job_mix AS (
    SELECT
        p.pub_name,
        j.job_desc,
        COUNT(e.emp_id) AS employee_count,
        AVG(CAST(e.job_lvl AS DOUBLE)) AS avg_job_level
    FROM publishers p
    JOIN employee e ON p.pub_id = e.pub_id
    JOIN jobs j ON e.job_id = j.job_id
    GROUP BY p.pub_name, j.job_desc
)
SELECT
    'publisher_staffing_baseline' AS evidence_block,
    'publisher' AS grain,
    pub_name AS item,
    country AS item_2,
    CAST(job_role_count AS VARCHAR) AS item_3,
    'revenue_rank' AS rank_label,
    CAST(revenue_rank AS DOUBLE) AS rank_value,
    employee_count,
    job_role_count,
    title_count,
    type_count,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4) AS sample_qty,
    ROUND(revenue_proxy, 4) AS revenue_proxy,
    ROUND(ytd_revenue_proxy, 4) AS ytd_revenue_proxy,
    ROUND(avg_job_level, 4) AS avg_job_level,
    ROUND(revenue_per_employee, 4) AS revenue_per_employee,
    ROUND(titles_per_employee, 4) AS titles_per_employee,
    ROUND(revenue_share_pct, 4) AS share_pct,
    'Publisher staffing, catalog, sales, and productivity baseline.' AS notes
FROM ranked_alignment
UNION ALL
SELECT
    'staff_without_current_catalog',
    'publisher',
    pub_name,
    country,
    CAST(job_role_count AS VARCHAR),
    'employee_count',
    CAST(employee_count AS DOUBLE),
    employee_count,
    job_role_count,
    title_count,
    type_count,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(ytd_revenue_proxy, 4),
    ROUND(avg_job_level, 4),
    ROUND(revenue_per_employee, 4),
    ROUND(titles_per_employee, 4),
    CAST(NULL AS DOUBLE),
    'Publishers with staff but no linked current catalog or sales.'
FROM ranked_alignment
WHERE employee_count > 0 AND title_count = 0
UNION ALL
SELECT
    'role_breadth_by_output',
    'publisher',
    pub_name,
    CASE WHEN title_count > 0 OR revenue_proxy > 0 THEN 'active_output' ELSE 'no_current_output' END,
    country,
    'job_role_count',
    CAST(job_role_count AS DOUBLE),
    employee_count,
    job_role_count,
    title_count,
    type_count,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(ytd_revenue_proxy, 4),
    ROUND(avg_job_level, 4),
    ROUND(revenue_per_employee, 4),
    ROUND(titles_per_employee, 4),
    ROUND(revenue_share_pct, 4),
    'Compare job-role breadth with whether the publisher has linked active output.'
FROM ranked_alignment
WHERE employee_count > 0
UNION ALL
SELECT
    'staff_level_vs_output',
    'publisher',
    pub_name,
    country,
    CAST(avg_level_rank AS VARCHAR),
    'avg_level_rank',
    CAST(avg_level_rank AS DOUBLE),
    employee_count,
    job_role_count,
    title_count,
    type_count,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(ytd_revenue_proxy, 4),
    ROUND(avg_job_level, 4),
    ROUND(revenue_per_employee, 4),
    ROUND(titles_per_employee, 4),
    ROUND(revenue_share_pct, 4),
    'Compare seniority signal with active publishing output.'
FROM ranked_alignment
WHERE employee_count > 0
UNION ALL
SELECT
    'job_role_distribution',
    'job_role',
    job_desc,
    CAST(publisher_count AS VARCHAR),
    CAST(min_lvl AS VARCHAR) || '-' || CAST(max_lvl AS VARCHAR),
    'employee_count',
    CAST(employee_count AS DOUBLE),
    employee_count,
    publisher_count,
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    ROUND(avg_job_level, 4),
    ROUND(observed_min_level, 4),
    ROUND(observed_max_level, 4),
    CAST(NULL AS DOUBLE),
    'Distribution of staff roles and observed job levels.'
FROM job_distribution
UNION ALL
SELECT
    'publisher_job_mix',
    'publisher_job',
    pub_name,
    job_desc,
    CAST(NULL AS VARCHAR),
    'employee_count',
    CAST(employee_count AS DOUBLE),
    employee_count,
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    ROUND(avg_job_level, 4),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    'Publisher-specific job role coverage.'
FROM publisher_job_mix;
