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
        pubdate,
        CASE WHEN price IS NULL THEN NULL ELSE CAST(price AS DOUBLE) END AS price_num,
        CASE WHEN advance IS NULL THEN NULL ELSE CAST(advance AS DOUBLE) END AS advance_num,
        CASE WHEN royalty IS NULL THEN NULL ELSE CAST(royalty AS DOUBLE) END AS royalty_num,
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
royalty_schedule AS (
    SELECT
        title_id,
        COUNT(*) AS royalty_tiers,
        MIN(CAST(royalty AS DOUBLE)) AS min_schedule_royalty,
        MAX(CAST(royalty AS DOUBLE)) AS max_schedule_royalty,
        MAX(CAST(hirange AS DOUBLE)) AS max_schedule_range
    FROM roysched
    GROUP BY title_id
),
author_by_title AS (
    SELECT
        title_id,
        COUNT(*) AS author_count,
        SUM(CAST(royaltyper AS DOUBLE)) AS royaltyper_sum
    FROM titleauthor
    GROUP BY title_id
),
title_metrics AS (
    SELECT
        tb.title_id,
        tb.title,
        tb.type,
        p.pub_name,
        tb.price_num,
        tb.advance_num,
        tb.royalty_num,
        tb.ytd_sales_num,
        tb.ytd_sales_num * COALESCE(tb.price_num, 0) AS ytd_revenue_proxy,
        COALESCE(sbt.sale_lines, 0) AS sale_lines,
        COALESCE(sbt.order_count, 0) AS order_count,
        COALESCE(sbt.sample_qty, 0) AS sample_qty,
        COALESCE(sbt.sample_qty, 0) * COALESCE(tb.price_num, 0) AS revenue_proxy,
        COALESCE(rs.royalty_tiers, 0) AS royalty_tiers,
        rs.min_schedule_royalty,
        rs.max_schedule_royalty,
        rs.max_schedule_range,
        COALESCE(abt.author_count, 0) AS author_count,
        COALESCE(abt.royaltyper_sum, 0) AS royaltyper_sum
    FROM title_base tb
    LEFT JOIN publishers p ON tb.pub_id = p.pub_id
    LEFT JOIN sales_by_title sbt ON tb.title_id = sbt.title_id
    LEFT JOIN royalty_schedule rs ON tb.title_id = rs.title_id
    LEFT JOIN author_by_title abt ON tb.title_id = abt.title_id
),
type_metrics AS (
    SELECT
        type,
        COUNT(*) AS title_count,
        SUM(CASE WHEN price_num IS NULL THEN 1 ELSE 0 END) AS missing_price_titles,
        COUNT(CASE WHEN sample_qty > 0 THEN 1 END) AS sold_title_count,
        SUM(order_count) AS order_count,
        SUM(sale_lines) AS sale_lines,
        SUM(sample_qty) AS sample_qty,
        SUM(revenue_proxy) AS revenue_proxy,
        SUM(ytd_sales_num) AS ytd_sales,
        SUM(ytd_revenue_proxy) AS ytd_revenue_proxy,
        AVG(price_num) AS avg_price,
        AVG(advance_num) AS avg_advance,
        AVG(royalty_num) AS avg_royalty,
        AVG(royalty_tiers) AS avg_royalty_tiers
    FROM title_metrics
    GROUP BY type
),
ranked_type AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY revenue_proxy DESC, type) AS sample_revenue_rank,
        ROW_NUMBER() OVER (ORDER BY ytd_revenue_proxy DESC, type) AS ytd_revenue_rank,
        100.0 * revenue_proxy / NULLIF(SUM(revenue_proxy) OVER (), 0) AS sample_revenue_share_pct
    FROM type_metrics
),
ranked_title AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY revenue_proxy DESC, title) AS title_revenue_rank,
        ROW_NUMBER() OVER (ORDER BY advance_num DESC NULLS LAST, title) AS advance_rank,
        100.0 * revenue_proxy / NULLIF(SUM(revenue_proxy) OVER (), 0) AS title_revenue_share_pct
    FROM title_metrics
)
SELECT
    'type_sales_ytd_baseline' AS evidence_block,
    'title_type' AS grain,
    type AS item,
    CAST(sample_revenue_rank AS VARCHAR) AS item_2,
    CAST(ytd_revenue_rank AS VARCHAR) AS item_3,
    'sample_revenue_rank' AS rank_label,
    CAST(sample_revenue_rank AS DOUBLE) AS rank_value,
    title_count,
    sold_title_count AS item_count,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4) AS sample_qty,
    ROUND(revenue_proxy, 4) AS revenue_proxy,
    ROUND(ytd_sales, 4) AS ytd_sales,
    ROUND(ytd_revenue_proxy, 4) AS ytd_revenue_proxy,
    ROUND(avg_price, 4) AS avg_price,
    ROUND(avg_advance, 4) AS advance_value,
    ROUND(avg_royalty, 4) AS royalty_value,
    ROUND(sample_revenue_share_pct, 4) AS share_pct,
    ROUND(avg_royalty_tiers, 4) AS secondary_value,
    'Compare title-type current sample sales with catalog ytd demand and economics.' AS notes
FROM ranked_type
UNION ALL
SELECT
    'sample_vs_ytd_type_mismatch',
    'title_type',
    type,
    CAST(sample_revenue_rank AS VARCHAR),
    CAST(ytd_revenue_rank AS VARCHAR),
    'rank_gap_sample_minus_ytd',
    CAST(sample_revenue_rank - ytd_revenue_rank AS DOUBLE),
    title_count,
    sold_title_count,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(ytd_sales, 4),
    ROUND(ytd_revenue_proxy, 4),
    ROUND(avg_price, 4),
    ROUND(avg_advance, 4),
    ROUND(avg_royalty, 4),
    ROUND(sample_revenue_share_pct, 4),
    ROUND(avg_royalty_tiers, 4),
    'Identify type-level divergence between sample sales proxy and ytd catalog demand.'
FROM ranked_type
UNION ALL
SELECT
    'title_revenue_leaders',
    'title',
    title,
    type,
    pub_name,
    'title_revenue_rank',
    CAST(title_revenue_rank AS DOUBLE),
    CAST(1 AS BIGINT),
    author_count,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(ytd_sales_num, 4),
    ROUND(ytd_revenue_proxy, 4),
    ROUND(price_num, 4),
    ROUND(advance_num, 4),
    ROUND(royalty_num, 4),
    ROUND(title_revenue_share_pct, 4),
    ROUND(royalty_tiers, 4),
    'Highest sample revenue proxy titles and their economics.'
FROM ranked_title
WHERE title_revenue_rank <= 10
UNION ALL
SELECT
    'high_advance_low_sample_sales',
    'title',
    title,
    type,
    pub_name,
    'advance_rank',
    CAST(advance_rank AS DOUBLE),
    CAST(1 AS BIGINT),
    author_count,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(ytd_sales_num, 4),
    ROUND(ytd_revenue_proxy, 4),
    ROUND(price_num, 4),
    ROUND(advance_num, 4),
    ROUND(royalty_num, 4),
    ROUND(title_revenue_share_pct, 4),
    ROUND(royalty_tiers, 4),
    'High advance titles can have weak current sample sales proxy.'
FROM ranked_title
WHERE advance_rank <= 8
UNION ALL
SELECT
    'metadata_or_unsold_title_risk',
    'title',
    title,
    type,
    pub_name,
    'sample_qty',
    sample_qty,
    CAST(1 AS BIGINT),
    author_count,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(ytd_sales_num, 4),
    ROUND(ytd_revenue_proxy, 4),
    ROUND(price_num, 4),
    ROUND(advance_num, 4),
    ROUND(royalty_num, 4),
    ROUND(title_revenue_share_pct, 4),
    ROUND(royalty_tiers, 4),
    'Titles with missing economics, undecided type, no author allocation, or no sample sales.'
FROM ranked_title
WHERE sample_qty = 0 OR price_num IS NULL OR type = 'UNDECIDED' OR author_count = 0
UNION ALL
SELECT
    'royalty_schedule_depth',
    'title',
    title,
    type,
    pub_name,
    'royalty_tiers',
    CAST(royalty_tiers AS DOUBLE),
    CAST(1 AS BIGINT),
    author_count,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(ytd_sales_num, 4),
    ROUND(ytd_revenue_proxy, 4),
    ROUND(price_num, 4),
    ROUND(advance_num, 4),
    ROUND(max_schedule_royalty, 4),
    ROUND(title_revenue_share_pct, 4),
    ROUND(max_schedule_range, 4),
    'Compare royalty schedule depth with observed sample sales.'
FROM ranked_title
WHERE royalty_tiers > 0;
