WITH
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
        t.pub_id,
        COUNT(DISTINCT t.title_id) AS title_count,
        COUNT(DISTINCT t.type) AS type_count,
        SUM(COALESCE(sbt.order_count, 0)) AS order_count,
        SUM(COALESCE(sbt.sale_lines, 0)) AS sale_lines,
        SUM(COALESCE(sbt.sample_qty, 0)) AS sample_qty,
        SUM(COALESCE(sbt.sample_qty, 0) * COALESCE(CAST(t.price AS DOUBLE), 0)) AS revenue_proxy
    FROM titles t
    LEFT JOIN sales_by_title sbt ON t.title_id = sbt.title_id
    GROUP BY t.pub_id
),
employee_enriched AS (
    SELECT
        e.emp_id,
        e.pub_id,
        p.pub_name,
        p.country,
        j.job_desc,
        CAST(e.job_lvl AS DOUBLE) AS job_level,
        SUBSTR(CAST(e.hire_date AS VARCHAR), 1, 4) AS hire_year,
        CAST(SUBSTR(CAST(e.hire_date AS VARCHAR), 1, 4) AS DOUBLE) AS hire_year_num
    FROM employee e
    JOIN publishers p ON e.pub_id = p.pub_id
    JOIN jobs j ON e.job_id = j.job_id
),
publisher_hiring AS (
    SELECT
        ee.pub_id,
        ee.pub_name,
        ee.country,
        COUNT(*) AS employee_count,
        COUNT(DISTINCT hire_year) AS hire_year_count,
        SUM(CASE WHEN hire_year_num <= 1990 THEN 1 ELSE 0 END) AS early_hire_count,
        SUM(CASE WHEN hire_year_num >= 1993 THEN 1 ELSE 0 END) AS recent_hire_count,
        MIN(hire_year) AS first_hire_year,
        MAX(hire_year) AS last_hire_year,
        AVG(job_level) AS avg_job_level
    FROM employee_enriched ee
    GROUP BY ee.pub_id, ee.pub_name, ee.country
),
publisher_alignment AS (
    SELECT
        ph.*,
        COALESCE(ps.title_count, 0) AS title_count,
        COALESCE(ps.type_count, 0) AS type_count,
        COALESCE(ps.order_count, 0) AS order_count,
        COALESCE(ps.sale_lines, 0) AS sale_lines,
        COALESCE(ps.sample_qty, 0) AS sample_qty,
        COALESCE(ps.revenue_proxy, 0) AS revenue_proxy,
        CASE WHEN ph.employee_count = 0 THEN NULL ELSE COALESCE(ps.revenue_proxy, 0) / ph.employee_count END AS revenue_per_employee
    FROM publisher_hiring ph
    LEFT JOIN publisher_sales ps ON ph.pub_id = ps.pub_id
),
ranked_publisher AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY revenue_proxy DESC, pub_name) AS revenue_rank,
        ROW_NUMBER() OVER (ORDER BY avg_job_level DESC, pub_name) AS seniority_rank
    FROM publisher_alignment
),
hire_year_output AS (
    SELECT
        ee.hire_year,
        COUNT(*) AS employee_count,
        COUNT(DISTINCT ee.pub_id) AS publisher_count,
        SUM(CASE WHEN COALESCE(ps.revenue_proxy, 0) > 0 THEN 1 ELSE 0 END) AS employees_at_active_publishers,
        AVG(ee.job_level) AS avg_job_level,
        SUM(COALESCE(ps.revenue_proxy, 0)) AS publisher_revenue_proxy
    FROM employee_enriched ee
    LEFT JOIN publisher_sales ps ON ee.pub_id = ps.pub_id
    GROUP BY ee.hire_year
),
ranked_hire_year AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY employee_count DESC, hire_year) AS employee_count_rank
    FROM hire_year_output
),
job_hire_period AS (
    SELECT
        CASE WHEN hire_year_num <= 1990 THEN 'early_1988_1990' WHEN hire_year_num >= 1993 THEN 'late_1993_1994' ELSE 'middle_1991_1992' END AS hire_period,
        COUNT(*) AS employee_count,
        COUNT(DISTINCT pub_id) AS publisher_count,
        AVG(job_level) AS avg_job_level
    FROM employee_enriched
    GROUP BY CASE WHEN hire_year_num <= 1990 THEN 'early_1988_1990' WHEN hire_year_num >= 1993 THEN 'late_1993_1994' ELSE 'middle_1991_1992' END
)
SELECT
    'publisher_hiring_output' AS evidence_block,
    'publisher' AS grain,
    pub_name AS item,
    first_hire_year AS item_2,
    last_hire_year AS item_3,
    'revenue_rank' AS rank_label,
    CAST(revenue_rank AS DOUBLE) AS rank_value,
    employee_count,
    hire_year_count,
    early_hire_count,
    recent_hire_count,
    title_count,
    type_count,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4) AS sample_qty,
    ROUND(revenue_proxy, 4) AS revenue_proxy,
    ROUND(avg_job_level, 4) AS avg_job_level,
    ROUND(revenue_per_employee, 4) AS revenue_per_employee,
    CAST(seniority_rank AS DOUBLE) AS secondary_value,
    'Publisher hiring timeline, seniority, and output baseline.' AS notes
FROM ranked_publisher
UNION ALL
SELECT
    'active_publisher_hiring',
    'publisher',
    pub_name,
    first_hire_year,
    last_hire_year,
    'revenue_rank',
    CAST(revenue_rank AS DOUBLE),
    employee_count,
    hire_year_count,
    early_hire_count,
    recent_hire_count,
    title_count,
    type_count,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(avg_job_level, 4),
    ROUND(revenue_per_employee, 4),
    CAST(seniority_rank AS DOUBLE),
    'Hiring timeline among publishers with linked catalog output.'
FROM ranked_publisher
WHERE revenue_proxy > 0 OR title_count > 0
UNION ALL
SELECT
    'inactive_hiring_mismatch',
    'publisher',
    pub_name,
    first_hire_year,
    last_hire_year,
    'employee_count',
    CAST(employee_count AS DOUBLE),
    employee_count,
    hire_year_count,
    early_hire_count,
    recent_hire_count,
    title_count,
    type_count,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(avg_job_level, 4),
    ROUND(revenue_per_employee, 4),
    CAST(seniority_rank AS DOUBLE),
    'Publishers with hiring footprint but no linked catalog or sales output.'
FROM ranked_publisher
WHERE revenue_proxy = 0 AND title_count = 0
UNION ALL
SELECT
    'hire_year_distribution',
    'hire_year',
    hire_year,
    CAST(publisher_count AS VARCHAR),
    CAST(employees_at_active_publishers AS VARCHAR),
    'employee_count_rank',
    CAST(employee_count_rank AS DOUBLE),
    employee_count,
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS DOUBLE),
    ROUND(publisher_revenue_proxy, 4),
    ROUND(avg_job_level, 4),
    CAST(NULL AS DOUBLE),
    CAST(publisher_count AS DOUBLE),
    'Employee hiring-year distribution and active-output exposure.'
FROM ranked_hire_year
UNION ALL
SELECT
    'hire_period_seniority',
    'hire_period',
    hire_period,
    CAST(publisher_count AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'employee_count',
    CAST(employee_count AS DOUBLE),
    employee_count,
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    ROUND(avg_job_level, 4),
    CAST(NULL AS DOUBLE),
    CAST(publisher_count AS DOUBLE),
    'Seniority distribution across broad hiring periods.'
FROM job_hire_period
ORDER BY evidence_block, rank_value, item;
