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
        t.title_id,
        t.title,
        t.type,
        p.pub_name,
        CAST(t.price AS DOUBLE) AS price_num,
        COALESCE(sbt.order_count, 0) AS order_count,
        COALESCE(sbt.sale_lines, 0) AS sale_lines,
        COALESCE(sbt.sample_qty, 0) AS sample_qty,
        COALESCE(sbt.sample_qty, 0) * COALESCE(CAST(t.price AS DOUBLE), 0) AS revenue_proxy,
        COALESCE(rs.royalty_tiers, 0) AS royalty_tiers,
        COALESCE(rs.max_schedule_royalty, 0) AS max_schedule_royalty
    FROM titles t
    LEFT JOIN publishers p ON t.pub_id = p.pub_id
    LEFT JOIN sales_by_title sbt ON t.title_id = sbt.title_id
    LEFT JOIN royalty_schedule rs ON t.title_id = rs.title_id
),
title_split AS (
    SELECT
        tm.title_id,
        tm.title,
        tm.type,
        tm.pub_name,
        tm.order_count,
        tm.sale_lines,
        tm.sample_qty,
        tm.revenue_proxy,
        tm.royalty_tiers,
        tm.max_schedule_royalty,
        COUNT(ta.au_id) AS author_count,
        SUM(CAST(ta.royaltyper AS DOUBLE)) AS royaltyper_sum,
        MIN(CAST(ta.royaltyper AS DOUBLE)) AS royaltyper_min,
        MAX(CAST(ta.royaltyper AS DOUBLE)) AS royaltyper_max,
        CASE
            WHEN COUNT(ta.au_id) = 0 THEN 'no_author'
            WHEN COUNT(ta.au_id) = 1 THEN 'single_author'
            WHEN MIN(CAST(ta.royaltyper AS DOUBLE)) = MAX(CAST(ta.royaltyper AS DOUBLE)) THEN 'equal_split'
            ELSE 'lead_weighted_split'
        END AS split_pattern
    FROM title_metrics tm
    LEFT JOIN titleauthor ta ON tm.title_id = ta.title_id
    GROUP BY tm.title_id, tm.title, tm.type, tm.pub_name, tm.order_count, tm.sale_lines, tm.sample_qty, tm.revenue_proxy, tm.royalty_tiers, tm.max_schedule_royalty
),
ranked_title_split AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY revenue_proxy DESC, title) AS revenue_rank,
        100.0 * revenue_proxy / NULLIF(SUM(revenue_proxy) OVER (), 0) AS revenue_share_pct
    FROM title_split
),
author_order_share AS (
    SELECT
        tm.title,
        tm.type,
        tm.pub_name,
        a.au_lname || ', ' || a.au_fname AS author_name,
        CAST(ta.au_ord AS DOUBLE) AS au_ord,
        CAST(ta.royaltyper AS DOUBLE) AS royaltyper,
        tm.sample_qty,
        tm.revenue_proxy,
        tm.revenue_proxy * CAST(ta.royaltyper AS DOUBLE) / 100.0 AS attributed_revenue_proxy,
        tm.royalty_tiers,
        tm.max_schedule_royalty
    FROM title_metrics tm
    JOIN titleauthor ta ON tm.title_id = ta.title_id
    JOIN authors a ON ta.au_id = a.au_id
),
ranked_author_order AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY attributed_revenue_proxy DESC, author_name, title) AS attributed_rank
    FROM author_order_share
),
order_contribution AS (
    SELECT
        CAST(au_ord AS VARCHAR) AS author_order,
        COUNT(*) AS title_author_links,
        SUM(attributed_revenue_proxy) AS attributed_revenue_proxy,
        AVG(royaltyper) AS avg_royaltyper
    FROM author_order_share
    GROUP BY au_ord
),
split_summary AS (
    SELECT
        split_pattern,
        COUNT(*) AS title_count,
        COUNT(CASE WHEN revenue_proxy > 0 THEN 1 END) AS sold_title_count,
        SUM(sample_qty) AS sample_qty,
        SUM(revenue_proxy) AS revenue_proxy,
        AVG(royalty_tiers) AS avg_royalty_tiers
    FROM title_split
    GROUP BY split_pattern
)
SELECT
    'title_split_baseline' AS evidence_block,
    'title' AS grain,
    title AS item,
    split_pattern AS item_2,
    pub_name AS item_3,
    'title_revenue_rank' AS rank_label,
    CAST(revenue_rank AS DOUBLE) AS rank_value,
    CAST(1 AS BIGINT) AS title_count,
    author_count,
    CAST(NULL AS DOUBLE) AS order_value,
    ROUND(royaltyper_sum, 4) AS royaltyper_sum,
    ROUND(royaltyper_min, 4) AS royaltyper_min,
    ROUND(royaltyper_max, 4) AS royaltyper_max,
    ROUND(sample_qty, 4) AS sample_qty,
    ROUND(revenue_proxy, 4) AS revenue_proxy,
    CAST(NULL AS DOUBLE) AS attributed_revenue_proxy,
    ROUND(revenue_share_pct, 4) AS share_pct,
    ROUND(royalty_tiers, 4) AS secondary_value,
    'Title-level royalty split, author count, and sales baseline.' AS notes
FROM ranked_title_split
UNION ALL
SELECT
    'author_order_share',
    'author_title',
    author_name,
    title,
    type,
    'attributed_revenue_rank',
    CAST(attributed_rank AS DOUBLE),
    CAST(1 AS BIGINT),
    CAST(NULL AS BIGINT),
    ROUND(au_ord, 4),
    ROUND(royaltyper, 4),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(attributed_revenue_proxy, 4),
    CAST(NULL AS DOUBLE),
    ROUND(royalty_tiers, 4),
    'Author order and royalty share within each title.'
FROM ranked_author_order
UNION ALL
SELECT
    'author_order_contribution',
    'author_order',
    author_order,
    CAST(title_author_links AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'author_order',
    CAST(author_order AS DOUBLE),
    title_author_links,
    CAST(NULL AS BIGINT),
    CAST(author_order AS DOUBLE),
    ROUND(avg_royaltyper, 4),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    ROUND(attributed_revenue_proxy, 4),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    'Aggregate attributed revenue by author order.'
FROM order_contribution
UNION ALL
SELECT
    'split_pattern_summary',
    'split_pattern',
    split_pattern,
    CAST(sold_title_count AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'title_count',
    CAST(title_count AS DOUBLE),
    title_count,
    CAST(NULL AS BIGINT),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    ROUND(avg_royalty_tiers, 4),
    'Summary of split patterns across titles.'
FROM split_summary
UNION ALL
SELECT
    'high_revenue_split_titles',
    'title',
    title,
    split_pattern,
    pub_name,
    'title_revenue_rank',
    CAST(revenue_rank AS DOUBLE),
    CAST(1 AS BIGINT),
    author_count,
    CAST(NULL AS DOUBLE),
    ROUND(royaltyper_sum, 4),
    ROUND(royaltyper_min, 4),
    ROUND(royaltyper_max, 4),
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    CAST(NULL AS DOUBLE),
    ROUND(revenue_share_pct, 4),
    ROUND(royalty_tiers, 4),
    'Highest-revenue titles and their royalty split patterns.'
FROM ranked_title_split
WHERE revenue_rank <= 8
UNION ALL
SELECT
    'schedule_split_interaction',
    'title',
    title,
    split_pattern,
    type,
    'royalty_tiers',
    CAST(royalty_tiers AS DOUBLE),
    CAST(1 AS BIGINT),
    author_count,
    CAST(NULL AS DOUBLE),
    ROUND(royaltyper_sum, 4),
    ROUND(royaltyper_min, 4),
    ROUND(royaltyper_max, 4),
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    CAST(NULL AS DOUBLE),
    ROUND(revenue_share_pct, 4),
    ROUND(max_schedule_royalty, 4),
    'Royalty schedule depth interacted with author split pattern.'
FROM ranked_title_split
WHERE royalty_tiers > 0
ORDER BY evidence_block, rank_value, item;
