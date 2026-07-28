WITH
title_base AS (
    SELECT
        title_id,
        title,
        type,
        pub_id,
        CASE WHEN price IS NULL THEN NULL ELSE CAST(price AS DOUBLE) END AS price_num
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
title_sales AS (
    SELECT
        tb.title_id,
        tb.title,
        tb.type,
        p.pub_name,
        tb.price_num,
        COALESCE(sbt.order_count, 0) AS order_count,
        COALESCE(sbt.sale_lines, 0) AS sale_lines,
        COALESCE(sbt.sample_qty, 0) AS sample_qty,
        COALESCE(sbt.sample_qty, 0) * COALESCE(tb.price_num, 0) AS revenue_proxy
    FROM title_base tb
    LEFT JOIN publishers p ON tb.pub_id = p.pub_id
    LEFT JOIN sales_by_title sbt ON tb.title_id = sbt.title_id
),
title_author_split AS (
    SELECT
        ts.title_id,
        ts.title,
        ts.type,
        ts.pub_name,
        ts.order_count,
        ts.sale_lines,
        ts.sample_qty,
        ts.revenue_proxy,
        COUNT(ta.au_id) AS author_count,
        SUM(CAST(ta.royaltyper AS DOUBLE)) AS royaltyper_sum
    FROM title_sales ts
    LEFT JOIN titleauthor ta ON ts.title_id = ta.title_id
    GROUP BY ts.title_id, ts.title, ts.type, ts.pub_name, ts.order_count, ts.sale_lines, ts.sample_qty, ts.revenue_proxy
),
author_contribution AS (
    SELECT
        a.au_id,
        a.au_lname || ', ' || a.au_fname AS author_name,
        a.state,
        a.contract,
        COUNT(DISTINCT ta.title_id) AS title_count,
        SUM(CAST(ta.royaltyper AS DOUBLE)) AS royaltyper_sum,
        SUM(ts.sample_qty) AS sample_qty,
        SUM(ts.revenue_proxy * CAST(ta.royaltyper AS DOUBLE) / 100.0) AS attributed_revenue_proxy,
        SUM(CASE WHEN ts.sample_qty = 0 THEN 1 ELSE 0 END) AS unsold_title_count
    FROM authors a
    JOIN titleauthor ta ON a.au_id = ta.au_id
    JOIN title_sales ts ON ta.title_id = ts.title_id
    GROUP BY a.au_id, author_name, a.state, a.contract
),
ranked_author AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY attributed_revenue_proxy DESC, author_name) AS author_revenue_rank,
        100.0 * attributed_revenue_proxy / NULLIF(SUM(attributed_revenue_proxy) OVER (), 0) AS author_revenue_share_pct
    FROM author_contribution
),
author_state AS (
    SELECT
        state,
        COUNT(DISTINCT au_id) AS author_count,
        SUM(title_count) AS author_title_links,
        SUM(sample_qty) AS sample_qty,
        SUM(attributed_revenue_proxy) AS attributed_revenue_proxy
    FROM author_contribution
    GROUP BY state
),
ranked_state AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY attributed_revenue_proxy DESC, state) AS state_revenue_rank,
        100.0 * attributed_revenue_proxy / NULLIF(SUM(attributed_revenue_proxy) OVER (), 0) AS state_revenue_share_pct
    FROM author_state
),
royalty_schedule AS (
    SELECT
        title_id,
        COUNT(*) AS royalty_tiers,
        MIN(CAST(royalty AS DOUBLE)) AS min_schedule_royalty,
        MAX(CAST(royalty AS DOUBLE)) AS max_schedule_royalty
    FROM roysched
    GROUP BY title_id
),
author_schedule_exposure AS (
    SELECT
        a.au_id,
        a.au_lname || ', ' || a.au_fname AS author_name,
        COUNT(DISTINCT ta.title_id) AS scheduled_title_count,
        AVG(COALESCE(rs.royalty_tiers, 0)) AS avg_royalty_tiers,
        MAX(COALESCE(rs.max_schedule_royalty, 0)) AS max_schedule_royalty
    FROM authors a
    JOIN titleauthor ta ON a.au_id = ta.au_id
    JOIN royalty_schedule rs ON ta.title_id = rs.title_id
    GROUP BY a.au_id, author_name
)
SELECT
    'author_contribution_rank' AS evidence_block,
    'author' AS grain,
    author_name AS item,
    state AS item_2,
    contract AS item_3,
    'author_revenue_rank' AS rank_label,
    CAST(author_revenue_rank AS DOUBLE) AS rank_value,
    title_count,
    CAST(NULL AS BIGINT) AS author_count,
    ROUND(royaltyper_sum, 4) AS royaltyper_sum,
    ROUND(sample_qty, 4) AS sample_qty,
    ROUND(attributed_revenue_proxy, 4) AS revenue_proxy,
    ROUND(author_revenue_share_pct, 4) AS share_pct,
    ROUND(unsold_title_count, 4) AS secondary_value,
    'Author-level attributed revenue proxy based on title sales and royalty share.' AS notes
FROM ranked_author
UNION ALL
SELECT
    'multi_title_author_breadth',
    'author',
    author_name,
    state,
    contract,
    'title_count',
    CAST(title_count AS DOUBLE),
    title_count,
    CAST(NULL AS BIGINT),
    ROUND(royaltyper_sum, 4),
    ROUND(sample_qty, 4),
    ROUND(attributed_revenue_proxy, 4),
    ROUND(author_revenue_share_pct, 4),
    ROUND(unsold_title_count, 4),
    'Check whether broader author portfolios translate into stronger attributed demand.'
FROM ranked_author
WHERE title_count >= 2
UNION ALL
SELECT
    'title_author_split_integrity',
    'title',
    title,
    type,
    pub_name,
    'author_count',
    CAST(author_count AS DOUBLE),
    CAST(1 AS BIGINT),
    author_count,
    ROUND(royaltyper_sum, 4),
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    CASE WHEN royaltyper_sum IS NULL THEN NULL ELSE ROUND(royaltyper_sum, 4) END,
    CAST(NULL AS DOUBLE),
    'Verify author count and royalty-share totals by title.'
FROM title_author_split
UNION ALL
SELECT
    'author_state_concentration',
    'author_state',
    state,
    CAST(author_count AS VARCHAR),
    CAST(author_title_links AS VARCHAR),
    'state_revenue_rank',
    CAST(state_revenue_rank AS DOUBLE),
    author_title_links,
    author_count,
    CAST(NULL AS DOUBLE),
    ROUND(sample_qty, 4),
    ROUND(attributed_revenue_proxy, 4),
    ROUND(state_revenue_share_pct, 4),
    CAST(NULL AS DOUBLE),
    'Geographic concentration of authors and attributed demand.'
FROM ranked_state
UNION ALL
SELECT
    'collaboration_vs_sales',
    'title',
    title,
    type,
    pub_name,
    'author_count',
    CAST(author_count AS DOUBLE),
    CAST(1 AS BIGINT),
    author_count,
    ROUND(royaltyper_sum, 4),
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    'Compare multi-author and single-author titles against sample sales proxy.'
FROM title_author_split
WHERE author_count >= 2 OR revenue_proxy > 0
UNION ALL
SELECT
    'author_royalty_schedule_exposure',
    'author',
    author_name,
    CAST(scheduled_title_count AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'avg_royalty_tiers',
    ROUND(avg_royalty_tiers, 4),
    scheduled_title_count,
    CAST(NULL AS BIGINT),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    ROUND(max_schedule_royalty, 4),
    ROUND(avg_royalty_tiers, 4),
    'Author exposure to deeper title royalty schedules.'
FROM author_schedule_exposure;
