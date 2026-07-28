WITH
title_base AS (
    SELECT
        t.title_id,
        t.title,
        t.type,
        p.pub_name,
        SUBSTR(CAST(t.pubdate AS VARCHAR), 1, 4) AS pub_year,
        CAST(t.price AS DOUBLE) AS price_num,
        CAST(t.advance AS DOUBLE) AS advance_num,
        CAST(t.royalty AS DOUBLE) AS royalty_num,
        COALESCE(CAST(t.ytd_sales AS DOUBLE), 0) AS ytd_sales_num
    FROM titles t
    LEFT JOIN publishers p ON t.pub_id = p.pub_id
),
sales_by_title AS (
    SELECT
        title_id,
        COUNT(DISTINCT ord_num) AS order_count,
        COUNT(*) AS sale_lines,
        SUM(CAST(qty AS DOUBLE)) AS sample_qty,
        MIN(SUBSTR(CAST(ord_date AS VARCHAR), 1, 4)) AS first_sale_year,
        MAX(SUBSTR(CAST(ord_date AS VARCHAR), 1, 4)) AS last_sale_year
    FROM sales
    GROUP BY title_id
),
royalty_schedule AS (
    SELECT
        title_id,
        COUNT(*) AS royalty_tiers,
        MAX(CAST(royalty AS DOUBLE)) AS max_schedule_royalty
    FROM roysched
    GROUP BY title_id
),
title_metrics AS (
    SELECT
        tb.*,
        COALESCE(sbt.order_count, 0) AS order_count,
        COALESCE(sbt.sale_lines, 0) AS sale_lines,
        COALESCE(sbt.sample_qty, 0) AS sample_qty,
        sbt.first_sale_year,
        sbt.last_sale_year,
        COALESCE(sbt.sample_qty, 0) * COALESCE(tb.price_num, 0) AS revenue_proxy,
        tb.ytd_sales_num * COALESCE(tb.price_num, 0) AS ytd_revenue_proxy,
        COALESCE(rs.royalty_tiers, 0) AS royalty_tiers,
        COALESCE(rs.max_schedule_royalty, 0) AS max_schedule_royalty,
        CASE
            WHEN sbt.first_sale_year IS NULL THEN NULL
            ELSE CAST(sbt.first_sale_year AS DOUBLE) - CAST(tb.pub_year AS DOUBLE)
        END AS first_sale_lag_years
    FROM title_base tb
    LEFT JOIN sales_by_title sbt ON tb.title_id = sbt.title_id
    LEFT JOIN royalty_schedule rs ON tb.title_id = rs.title_id
),
ranked_title AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY revenue_proxy DESC, title) AS revenue_rank,
        ROW_NUMBER() OVER (ORDER BY ytd_revenue_proxy DESC, title) AS ytd_rank,
        100.0 * revenue_proxy / NULLIF(SUM(revenue_proxy) OVER (), 0) AS revenue_share_pct
    FROM title_metrics
),
cohort AS (
    SELECT
        pub_year,
        COUNT(*) AS title_count,
        COUNT(CASE WHEN sample_qty > 0 THEN 1 END) AS sold_title_count,
        COUNT(CASE WHEN price_num IS NULL OR ytd_sales_num = 0 THEN 1 END) AS incomplete_title_count,
        SUM(order_count) AS order_count,
        SUM(sale_lines) AS sale_lines,
        SUM(sample_qty) AS sample_qty,
        SUM(revenue_proxy) AS revenue_proxy,
        SUM(ytd_sales_num) AS ytd_sales,
        SUM(ytd_revenue_proxy) AS ytd_revenue_proxy,
        AVG(first_sale_lag_years) AS avg_first_sale_lag_years
    FROM title_metrics
    GROUP BY pub_year
),
ranked_cohort AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY revenue_proxy DESC, pub_year) AS cohort_revenue_rank,
        100.0 * revenue_proxy / NULLIF(SUM(revenue_proxy) OVER (), 0) AS revenue_share_pct
    FROM cohort
)
SELECT
    'publication_cohort_baseline' AS evidence_block,
    'publication_year' AS grain,
    pub_year AS item,
    CAST(sold_title_count AS VARCHAR) AS item_2,
    CAST(incomplete_title_count AS VARCHAR) AS item_3,
    'cohort_revenue_rank' AS rank_label,
    CAST(cohort_revenue_rank AS DOUBLE) AS rank_value,
    title_count,
    sold_title_count AS item_count,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4) AS sample_qty,
    ROUND(revenue_proxy, 4) AS revenue_proxy,
    ROUND(ytd_sales, 4) AS ytd_sales,
    ROUND(ytd_revenue_proxy, 4) AS ytd_revenue_proxy,
    CAST(NULL AS DOUBLE) AS price_value,
    CAST(NULL AS DOUBLE) AS advance_value,
    CAST(NULL AS DOUBLE) AS royalty_tiers,
    ROUND(revenue_share_pct, 4) AS share_pct,
    ROUND(avg_first_sale_lag_years, 4) AS secondary_value,
    'Publication-year cohort baseline for catalog lifecycle and demand.' AS notes
FROM ranked_cohort
UNION ALL
SELECT
    'title_lifecycle_baseline',
    'title',
    title,
    type,
    pub_name,
    'sample_revenue_rank',
    CAST(revenue_rank AS DOUBLE),
    CAST(1 AS BIGINT),
    CASE WHEN sample_qty > 0 THEN 1 ELSE 0 END,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(ytd_sales_num, 4),
    ROUND(ytd_revenue_proxy, 4),
    ROUND(price_num, 4),
    ROUND(advance_num, 4),
    ROUND(royalty_tiers, 4),
    ROUND(revenue_share_pct, 4),
    ROUND(first_sale_lag_years, 4),
    'Title-level lifecycle, current sales, and ytd catalog demand.'
FROM ranked_title
UNION ALL
SELECT
    'current_vs_ytd_title_momentum',
    'title',
    title,
    type,
    pub_name,
    'rank_gap_current_minus_ytd',
    CAST(revenue_rank - ytd_rank AS DOUBLE),
    CAST(1 AS BIGINT),
    CASE WHEN sample_qty > 0 THEN 1 ELSE 0 END,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(ytd_sales_num, 4),
    ROUND(ytd_revenue_proxy, 4),
    ROUND(price_num, 4),
    ROUND(advance_num, 4),
    ROUND(royalty_tiers, 4),
    ROUND(revenue_share_pct, 4),
    ROUND(CAST(ytd_rank AS DOUBLE), 4),
    'Compare current sample revenue rank with ytd catalog-demand rank.'
FROM ranked_title
WHERE sample_qty > 0 OR ytd_revenue_proxy > 0
UNION ALL
SELECT
    'unsold_or_incomplete_titles',
    'title',
    title,
    type,
    pub_name,
    'sample_qty',
    sample_qty,
    CAST(1 AS BIGINT),
    CASE WHEN sample_qty > 0 THEN 1 ELSE 0 END,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(ytd_sales_num, 4),
    ROUND(ytd_revenue_proxy, 4),
    ROUND(price_num, 4),
    ROUND(advance_num, 4),
    ROUND(royalty_tiers, 4),
    ROUND(revenue_share_pct, 4),
    ROUND(first_sale_lag_years, 4),
    'Titles with no observed sales or incomplete economics.'
FROM ranked_title
WHERE sample_qty = 0 OR price_num IS NULL OR ytd_sales_num = 0
UNION ALL
SELECT
    'chronology_exception',
    'title',
    title,
    type,
    pub_name,
    'first_sale_lag_years',
    ROUND(first_sale_lag_years, 4),
    CAST(1 AS BIGINT),
    CASE WHEN sample_qty > 0 THEN 1 ELSE 0 END,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(ytd_sales_num, 4),
    ROUND(ytd_revenue_proxy, 4),
    ROUND(price_num, 4),
    ROUND(advance_num, 4),
    ROUND(royalty_tiers, 4),
    ROUND(revenue_share_pct, 4),
    CAST(pub_year AS DOUBLE),
    'Titles whose observed first sale year predates the recorded publication year.'
FROM ranked_title
WHERE first_sale_lag_years < 0
UNION ALL
SELECT
    'royalty_lifecycle_context',
    'title',
    title,
    type,
    pub_name,
    'royalty_tiers',
    CAST(royalty_tiers AS DOUBLE),
    CAST(1 AS BIGINT),
    CASE WHEN sample_qty > 0 THEN 1 ELSE 0 END,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(ytd_sales_num, 4),
    ROUND(ytd_revenue_proxy, 4),
    ROUND(price_num, 4),
    ROUND(advance_num, 4),
    ROUND(royalty_tiers, 4),
    ROUND(revenue_share_pct, 4),
    ROUND(max_schedule_royalty, 4),
    'Royalty schedule depth viewed alongside lifecycle and demand.'
FROM ranked_title
WHERE royalty_tiers > 0
ORDER BY evidence_block, rank_value, item;
