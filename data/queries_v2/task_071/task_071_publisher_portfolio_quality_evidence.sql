WITH
title_base AS (
    SELECT
        title_id,
        title,
        type,
        pub_id,
        price,
        advance,
        royalty,
        ytd_sales,
        CASE WHEN price IS NULL THEN NULL ELSE CAST(price AS DOUBLE) END AS price_num,
        COALESCE(CAST(ytd_sales AS DOUBLE), 0) AS ytd_sales_num
    FROM titles
),
sales_by_title AS (
    SELECT
        title_id,
        COUNT(*) AS sale_lines,
        COUNT(DISTINCT ord_num) AS order_count,
        SUM(CAST(qty AS DOUBLE)) AS sample_qty
    FROM sales
    GROUP BY title_id
),
title_enriched AS (
    SELECT
        tb.pub_id,
        tb.title_id,
        tb.title,
        tb.type,
        tb.price_num,
        tb.ytd_sales_num,
        COALESCE(sbt.sale_lines, 0) AS sale_lines,
        COALESCE(sbt.order_count, 0) AS order_count,
        COALESCE(sbt.sample_qty, 0) AS sample_qty,
        COALESCE(sbt.sample_qty, 0) * COALESCE(tb.price_num, 0) AS revenue_proxy,
        tb.ytd_sales_num * COALESCE(tb.price_num, 0) AS ytd_revenue_proxy
    FROM title_base tb
    LEFT JOIN sales_by_title sbt ON tb.title_id = sbt.title_id
),
publisher_sales AS (
    SELECT
        pub_id,
        COUNT(DISTINCT title_id) AS title_count,
        COUNT(DISTINCT type) AS type_count,
        SUM(order_count) AS order_count,
        SUM(sale_lines) AS sale_lines,
        SUM(sample_qty) AS sample_qty,
        SUM(revenue_proxy) AS revenue_proxy,
        SUM(ytd_sales_num) AS ytd_sales,
        SUM(ytd_revenue_proxy) AS ytd_revenue_proxy,
        SUM(CASE WHEN price_num IS NULL THEN 1 ELSE 0 END) AS missing_price_titles
    FROM title_enriched
    GROUP BY pub_id
),
publisher_staff AS (
    SELECT
        pub_id,
        COUNT(*) AS employee_count,
        AVG(CAST(job_lvl AS DOUBLE)) AS avg_job_level,
        COUNT(DISTINCT job_id) AS job_role_count
    FROM employee
    GROUP BY pub_id
),
publisher_quality AS (
    SELECT
        p.pub_id,
        p.pub_name,
        p.country,
        COALESCE(ps.title_count, 0) AS title_count,
        COALESCE(ps.type_count, 0) AS type_count,
        COALESCE(ps.order_count, 0) AS order_count,
        COALESCE(ps.sale_lines, 0) AS sale_lines,
        COALESCE(ps.sample_qty, 0) AS sample_qty,
        COALESCE(ps.revenue_proxy, 0) AS revenue_proxy,
        COALESCE(ps.ytd_sales, 0) AS ytd_sales,
        COALESCE(ps.ytd_revenue_proxy, 0) AS ytd_revenue_proxy,
        COALESCE(ps.missing_price_titles, 0) AS missing_price_titles,
        COALESCE(st.employee_count, 0) AS employee_count,
        st.avg_job_level,
        COALESCE(st.job_role_count, 0) AS job_role_count,
        CASE
            WHEN COALESCE(st.employee_count, 0) = 0 THEN NULL
            ELSE COALESCE(ps.revenue_proxy, 0) / st.employee_count
        END AS revenue_per_employee
    FROM publishers p
    LEFT JOIN publisher_sales ps ON p.pub_id = ps.pub_id
    LEFT JOIN publisher_staff st ON p.pub_id = st.pub_id
),
ranked_publishers AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY revenue_proxy DESC, pub_name) AS revenue_rank,
        ROW_NUMBER() OVER (ORDER BY sample_qty DESC, pub_name) AS qty_rank,
        ROW_NUMBER() OVER (ORDER BY ytd_revenue_proxy DESC, pub_name) AS ytd_revenue_rank,
        100.0 * revenue_proxy / NULLIF(SUM(revenue_proxy) OVER (), 0) AS revenue_share_pct
    FROM publisher_quality
),
title_rank AS (
    SELECT
        te.*,
        p.pub_name,
        SUM(te.revenue_proxy) OVER (PARTITION BY te.pub_id) AS publisher_revenue_proxy,
        ROW_NUMBER() OVER (
            PARTITION BY te.pub_id
            ORDER BY te.revenue_proxy DESC, te.title
        ) AS title_rank_in_publisher
    FROM title_enriched te
    JOIN publishers p ON te.pub_id = p.pub_id
)
SELECT
    'publisher_portfolio_baseline' AS evidence_block,
    'publisher' AS grain,
    pub_name AS item,
    country AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'revenue_rank' AS rank_label,
    CAST(revenue_rank AS DOUBLE) AS rank_value,
    title_count,
    type_count,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4) AS sample_qty,
    ROUND(revenue_proxy, 4) AS revenue_proxy,
    ROUND(ytd_sales, 4) AS ytd_sales,
    ROUND(ytd_revenue_proxy, 4) AS ytd_revenue_proxy,
    employee_count,
    ROUND(avg_job_level, 4) AS avg_job_level,
    ROUND(revenue_share_pct, 4) AS share_pct,
    ROUND(revenue_per_employee, 4) AS secondary_value,
    'Publisher-level catalog, sales, ytd demand, and staffing baseline.' AS notes
FROM ranked_publishers
UNION ALL
SELECT
    'active_publisher_conversion',
    'publisher',
    pub_name,
    country,
    CAST(NULL AS VARCHAR),
    'qty_rank',
    CAST(qty_rank AS DOUBLE),
    title_count,
    type_count,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(ytd_sales, 4),
    ROUND(ytd_revenue_proxy, 4),
    employee_count,
    ROUND(avg_job_level, 4),
    ROUND(revenue_share_pct, 4),
    ROUND(revenue_per_employee, 4),
    'Compare sales quantity, revenue proxy, and staff scale among active publishers.'
FROM ranked_publishers
WHERE revenue_proxy > 0 OR sample_qty > 0
UNION ALL
SELECT
    'catalog_breadth_vs_revenue',
    'publisher',
    pub_name,
    country,
    CAST(type_count AS VARCHAR),
    'type_count',
    CAST(type_count AS DOUBLE),
    title_count,
    type_count,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(ytd_sales, 4),
    ROUND(ytd_revenue_proxy, 4),
    employee_count,
    ROUND(avg_job_level, 4),
    ROUND(revenue_share_pct, 4),
    ROUND(revenue_per_employee, 4),
    'Check whether broader publisher catalogs translate into stronger revenue proxy.'
FROM ranked_publishers
WHERE title_count > 0
UNION ALL
SELECT
    'ytd_vs_sample_demand',
    'publisher',
    pub_name,
    country,
    CAST(ytd_revenue_rank AS VARCHAR),
    'ytd_revenue_rank',
    CAST(ytd_revenue_rank AS DOUBLE),
    title_count,
    type_count,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(ytd_sales, 4),
    ROUND(ytd_revenue_proxy, 4),
    employee_count,
    ROUND(avg_job_level, 4),
    ROUND(revenue_share_pct, 4),
    ROUND(revenue_per_employee, 4),
    'Compare current sample sales proxy with title-level ytd demand proxy.'
FROM ranked_publishers
WHERE title_count > 0
UNION ALL
SELECT
    'staff_without_active_catalog',
    'publisher',
    pub_name,
    country,
    CAST(job_role_count AS VARCHAR),
    'employee_count',
    CAST(employee_count AS DOUBLE),
    title_count,
    type_count,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(ytd_sales, 4),
    ROUND(ytd_revenue_proxy, 4),
    employee_count,
    ROUND(avg_job_level, 4),
    CAST(NULL AS DOUBLE),
    ROUND(revenue_per_employee, 4),
    'Identify publishers that carry staffing but no linked title sales in the available tables.'
FROM ranked_publishers
WHERE employee_count > 0 AND title_count = 0
UNION ALL
SELECT
    'top_title_dependence',
    'publisher_title',
    pub_name,
    title,
    type,
    'title_rank_in_publisher',
    CAST(title_rank_in_publisher AS DOUBLE),
    CAST(1 AS BIGINT),
    CAST(NULL AS BIGINT),
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(ytd_sales_num, 4),
    ROUND(ytd_revenue_proxy, 4),
    CAST(NULL AS BIGINT),
    CAST(NULL AS DOUBLE),
    ROUND(100.0 * revenue_proxy / NULLIF(publisher_revenue_proxy, 0), 4),
    ROUND(publisher_revenue_proxy, 4),
    'Top title share within each active publisher.'
FROM title_rank
WHERE title_rank_in_publisher <= 3 AND publisher_revenue_proxy > 0;
