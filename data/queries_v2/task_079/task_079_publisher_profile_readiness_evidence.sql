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
title_publisher AS (
    SELECT
        t.pub_id,
        COUNT(DISTINCT t.title_id) AS title_count,
        COUNT(DISTINCT t.type) AS type_count,
        COUNT(CASE WHEN t.price IS NULL OR t.ytd_sales IS NULL OR t.royalty IS NULL THEN 1 END) AS missing_econ_titles,
        SUM(COALESCE(sbt.order_count, 0)) AS order_count,
        SUM(COALESCE(sbt.sale_lines, 0)) AS sale_lines,
        SUM(COALESCE(sbt.sample_qty, 0)) AS sample_qty,
        SUM(COALESCE(sbt.sample_qty, 0) * COALESCE(CAST(t.price AS DOUBLE), 0)) AS revenue_proxy,
        SUM(COALESCE(CAST(t.ytd_sales AS DOUBLE), 0) * COALESCE(CAST(t.price AS DOUBLE), 0)) AS ytd_revenue_proxy
    FROM titles t
    LEFT JOIN sales_by_title sbt ON t.title_id = sbt.title_id
    GROUP BY t.pub_id
),
staff AS (
    SELECT pub_id, COUNT(*) AS employee_count
    FROM employee
    GROUP BY pub_id
),
publisher_profile AS (
    SELECT
        p.pub_id,
        p.pub_name,
        p.country,
        CASE WHEN pi.pub_id IS NULL THEN 0 ELSE 1 END AS has_pub_info,
        LENGTH(pi.pr_info) AS profile_length,
        COALESCE(st.employee_count, 0) AS employee_count,
        COALESCE(tp.title_count, 0) AS title_count,
        COALESCE(tp.type_count, 0) AS type_count,
        COALESCE(tp.missing_econ_titles, 0) AS missing_econ_titles,
        COALESCE(tp.order_count, 0) AS order_count,
        COALESCE(tp.sale_lines, 0) AS sale_lines,
        COALESCE(tp.sample_qty, 0) AS sample_qty,
        COALESCE(tp.revenue_proxy, 0) AS revenue_proxy,
        COALESCE(tp.ytd_revenue_proxy, 0) AS ytd_revenue_proxy
    FROM publishers p
    LEFT JOIN pub_info pi ON p.pub_id = pi.pub_id
    LEFT JOIN staff st ON p.pub_id = st.pub_id
    LEFT JOIN title_publisher tp ON p.pub_id = tp.pub_id
),
ranked_profile AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY revenue_proxy DESC, pub_name) AS revenue_rank,
        ROW_NUMBER() OVER (ORDER BY profile_length DESC, pub_name) AS profile_length_rank,
        100.0 * revenue_proxy / NULLIF(SUM(revenue_proxy) OVER (), 0) AS revenue_share_pct
    FROM publisher_profile
),
country_profile AS (
    SELECT
        country,
        COUNT(*) AS publisher_count,
        SUM(has_pub_info) AS profiled_publisher_count,
        SUM(employee_count) AS employee_count,
        SUM(title_count) AS title_count,
        SUM(missing_econ_titles) AS missing_econ_titles,
        SUM(order_count) AS order_count,
        SUM(sale_lines) AS sale_lines,
        SUM(sample_qty) AS sample_qty,
        SUM(revenue_proxy) AS revenue_proxy,
        SUM(ytd_revenue_proxy) AS ytd_revenue_proxy
    FROM publisher_profile
    GROUP BY country
),
ranked_country AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY revenue_proxy DESC, country) AS country_revenue_rank,
        100.0 * revenue_proxy / NULLIF(SUM(revenue_proxy) OVER (), 0) AS revenue_share_pct
    FROM country_profile
)
SELECT
    'publisher_profile_baseline' AS evidence_block,
    'publisher' AS grain,
    pub_name AS item,
    country AS item_2,
    CAST(has_pub_info AS VARCHAR) AS item_3,
    'revenue_rank' AS rank_label,
    CAST(revenue_rank AS DOUBLE) AS rank_value,
    has_pub_info,
    profile_length,
    employee_count,
    title_count,
    missing_econ_titles,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4) AS sample_qty,
    ROUND(revenue_proxy, 4) AS revenue_proxy,
    ROUND(ytd_revenue_proxy, 4) AS ytd_revenue_proxy,
    ROUND(revenue_share_pct, 4) AS share_pct,
    CAST(type_count AS DOUBLE) AS secondary_value,
    'Publisher profile, catalog, staff, and sales readiness baseline.' AS notes
FROM ranked_profile
UNION ALL
SELECT
    'active_profile_gap',
    'publisher',
    pub_name,
    country,
    CAST(has_pub_info AS VARCHAR),
    'has_pub_info',
    CAST(has_pub_info AS DOUBLE),
    has_pub_info,
    profile_length,
    employee_count,
    title_count,
    missing_econ_titles,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(ytd_revenue_proxy, 4),
    ROUND(revenue_share_pct, 4),
    CAST(type_count AS DOUBLE),
    'Commercially active publishers checked for pub_info coverage.'
FROM ranked_profile
WHERE revenue_proxy > 0 OR title_count > 0
UNION ALL
SELECT
    'inactive_profile_assets',
    'publisher',
    pub_name,
    country,
    CAST(has_pub_info AS VARCHAR),
    'profile_length_rank',
    CAST(profile_length_rank AS DOUBLE),
    has_pub_info,
    profile_length,
    employee_count,
    title_count,
    missing_econ_titles,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(ytd_revenue_proxy, 4),
    ROUND(revenue_share_pct, 4),
    CAST(type_count AS DOUBLE),
    'Profile assets that do not currently connect to catalog or sales output.'
FROM ranked_profile
WHERE revenue_proxy = 0 AND title_count = 0 AND has_pub_info = 1
UNION ALL
SELECT
    'metadata_completion_by_publisher',
    'publisher',
    pub_name,
    country,
    CAST(missing_econ_titles AS VARCHAR),
    'missing_econ_titles',
    CAST(missing_econ_titles AS DOUBLE),
    has_pub_info,
    profile_length,
    employee_count,
    title_count,
    missing_econ_titles,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(ytd_revenue_proxy, 4),
    ROUND(revenue_share_pct, 4),
    CAST(type_count AS DOUBLE),
    'Publisher-level title metadata completion and sales readiness.'
FROM ranked_profile
WHERE title_count > 0 OR missing_econ_titles > 0
UNION ALL
SELECT
    'country_profile_output',
    'country',
    country,
    CAST(profiled_publisher_count AS VARCHAR),
    CAST(publisher_count AS VARCHAR),
    'country_revenue_rank',
    CAST(country_revenue_rank AS DOUBLE),
    CAST(profiled_publisher_count AS BIGINT),
    CAST(NULL AS BIGINT),
    employee_count,
    title_count,
    missing_econ_titles,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(ytd_revenue_proxy, 4),
    ROUND(revenue_share_pct, 4),
    CAST(publisher_count AS DOUBLE),
    'Country-level contrast between profile coverage and active publishing output.'
FROM ranked_country
ORDER BY evidence_block, rank_value, item;
