WITH
title_base AS (
    SELECT
        title_id,
        title,
        type,
        CASE WHEN price IS NULL THEN NULL ELSE CAST(price AS DOUBLE) END AS price_num
    FROM titles
),
sales_enriched AS (
    SELECT
        s.stor_id,
        st.stor_name,
        st.city,
        st.state,
        s.ord_num,
        s.ord_date,
        s.payterms,
        s.title_id,
        tb.title,
        tb.type,
        CAST(s.qty AS DOUBLE) AS qty,
        tb.price_num,
        CAST(s.qty AS DOUBLE) * COALESCE(tb.price_num, 0) AS revenue_proxy
    FROM sales s
    JOIN stores st ON s.stor_id = st.stor_id
    JOIN title_base tb ON s.title_id = tb.title_id
),
store_metrics AS (
    SELECT
        stor_id,
        stor_name,
        city,
        state,
        COUNT(DISTINCT ord_num) AS order_count,
        COUNT(*) AS sale_lines,
        COUNT(DISTINCT title_id) AS title_count,
        COUNT(DISTINCT type) AS type_count,
        SUM(qty) AS sample_qty,
        SUM(revenue_proxy) AS revenue_proxy
    FROM sales_enriched
    GROUP BY stor_id, stor_name, city, state
),
ranked_store AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY revenue_proxy DESC, stor_name) AS store_revenue_rank,
        100.0 * revenue_proxy / NULLIF(SUM(revenue_proxy) OVER (), 0) AS revenue_share_pct
    FROM store_metrics
),
state_metrics AS (
    SELECT
        state,
        COUNT(DISTINCT stor_id) AS store_count,
        COUNT(DISTINCT ord_num) AS order_count,
        COUNT(*) AS sale_lines,
        COUNT(DISTINCT title_id) AS title_count,
        COUNT(DISTINCT type) AS type_count,
        SUM(qty) AS sample_qty,
        SUM(revenue_proxy) AS revenue_proxy
    FROM sales_enriched
    GROUP BY state
),
ranked_state AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY revenue_proxy DESC, state) AS state_revenue_rank,
        100.0 * revenue_proxy / NULLIF(SUM(revenue_proxy) OVER (), 0) AS revenue_share_pct
    FROM state_metrics
),
payterms_metrics AS (
    SELECT
        payterms,
        COUNT(DISTINCT ord_num) AS order_count,
        COUNT(*) AS sale_lines,
        COUNT(DISTINCT stor_id) AS store_count,
        COUNT(DISTINCT title_id) AS title_count,
        COUNT(DISTINCT type) AS type_count,
        SUM(qty) AS sample_qty,
        SUM(revenue_proxy) AS revenue_proxy
    FROM sales_enriched
    GROUP BY payterms
),
ranked_payterms AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY revenue_proxy DESC, payterms) AS payterms_revenue_rank,
        100.0 * revenue_proxy / NULLIF(SUM(revenue_proxy) OVER (), 0) AS revenue_share_pct
    FROM payterms_metrics
),
order_size_bucket AS (
    SELECT
        CASE
            WHEN qty < 10 THEN 'small_<10'
            WHEN qty < 40 THEN 'mid_10_39'
            ELSE 'large_40_plus'
        END AS qty_bucket,
        COUNT(DISTINCT ord_num) AS order_count,
        COUNT(*) AS sale_lines,
        COUNT(DISTINCT stor_id) AS store_count,
        COUNT(DISTINCT title_id) AS title_count,
        COUNT(DISTINCT type) AS type_count,
        SUM(qty) AS sample_qty,
        SUM(revenue_proxy) AS revenue_proxy
    FROM sales_enriched
    GROUP BY
        CASE
            WHEN qty < 10 THEN 'small_<10'
            WHEN qty < 40 THEN 'mid_10_39'
            ELSE 'large_40_plus'
        END
),
ranked_bucket AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY revenue_proxy DESC, qty_bucket) AS bucket_revenue_rank,
        100.0 * revenue_proxy / NULLIF(SUM(revenue_proxy) OVER (), 0) AS revenue_share_pct
    FROM order_size_bucket
),
store_title_rank AS (
    SELECT
        stor_name,
        state,
        title,
        type,
        SUM(qty) AS sample_qty,
        SUM(revenue_proxy) AS revenue_proxy,
        SUM(SUM(revenue_proxy)) OVER (PARTITION BY stor_name) AS store_revenue_proxy,
        ROW_NUMBER() OVER (
            PARTITION BY stor_name
            ORDER BY SUM(revenue_proxy) DESC, title
        ) AS title_rank_in_store
    FROM sales_enriched
    GROUP BY stor_name, state, title, type
),
discount_context AS (
    SELECT
        d.discounttype,
        COALESCE(st.stor_name, 'ALL_STORES') AS stor_name,
        COALESCE(st.state, 'ALL') AS state,
        d.lowqty,
        d.highqty,
        d.discount
    FROM discounts d
    LEFT JOIN stores st ON d.stor_id = st.stor_id
)
SELECT
    'store_demand_concentration' AS evidence_block,
    'store' AS grain,
    stor_name AS item,
    state AS item_2,
    city AS item_3,
    'store_revenue_rank' AS rank_label,
    CAST(store_revenue_rank AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS store_count,
    title_count,
    type_count,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4) AS sample_qty,
    ROUND(revenue_proxy, 4) AS revenue_proxy,
    ROUND(revenue_share_pct, 4) AS share_pct,
    CAST(NULL AS DOUBLE) AS secondary_value,
    'Store-level concentration of order, title breadth, and revenue proxy.' AS notes
FROM ranked_store
UNION ALL
SELECT
    'state_store_rollup',
    'state',
    state,
    CAST(store_count AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'state_revenue_rank',
    CAST(state_revenue_rank AS DOUBLE),
    store_count,
    title_count,
    type_count,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(revenue_share_pct, 4),
    CAST(NULL AS DOUBLE),
    'Roll up store demand by state.'
FROM ranked_state
UNION ALL
SELECT
    'store_mix_breadth',
    'store',
    stor_name,
    state,
    city,
    'type_count',
    CAST(type_count AS DOUBLE),
    CAST(NULL AS BIGINT),
    title_count,
    type_count,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(revenue_share_pct, 4),
    CAST(NULL AS DOUBLE),
    'Compare store demand with title and type breadth.'
FROM ranked_store
UNION ALL
SELECT
    'payterms_demand_quality',
    'payterms',
    payterms,
    CAST(store_count AS VARCHAR),
    CAST(type_count AS VARCHAR),
    'payterms_revenue_rank',
    CAST(payterms_revenue_rank AS DOUBLE),
    store_count,
    title_count,
    type_count,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(revenue_share_pct, 4),
    CAST(NULL AS DOUBLE),
    'Payment terms as a channel-like demand and mix signal.'
FROM ranked_payterms
UNION ALL
SELECT
    'order_size_concentration',
    'qty_bucket',
    qty_bucket,
    CAST(store_count AS VARCHAR),
    CAST(type_count AS VARCHAR),
    'bucket_revenue_rank',
    CAST(bucket_revenue_rank AS DOUBLE),
    store_count,
    title_count,
    type_count,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(revenue_share_pct, 4),
    CAST(NULL AS DOUBLE),
    'Check whether larger order lines drive a disproportionate share of revenue proxy.'
FROM ranked_bucket
UNION ALL
SELECT
    'store_title_dependence',
    'store_title',
    stor_name,
    title,
    type,
    'title_rank_in_store',
    CAST(title_rank_in_store AS DOUBLE),
    CAST(NULL AS BIGINT),
    CAST(1 AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(100.0 * revenue_proxy / NULLIF(store_revenue_proxy, 0), 4),
    ROUND(store_revenue_proxy, 4),
    'Top title dependence within each store.'
FROM store_title_rank
WHERE title_rank_in_store <= 3
UNION ALL
SELECT
    'discount_rule_context',
    'discount_rule',
    discounttype,
    stor_name,
    state,
    'discount_pct',
    CAST(discount AS DOUBLE),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    COALESCE(CAST(lowqty AS DOUBLE), 0),
    'Discount rules are sparse and should be checked against store and order-size patterns.'
FROM discount_context;
