WITH
sales_enriched AS (
    SELECT
        s.stor_id,
        st.stor_name,
        st.state,
        s.ord_num,
        s.payterms,
        t.title_id,
        t.title,
        t.type,
        CAST(s.qty AS DOUBLE) AS qty,
        CAST(t.price AS DOUBLE) AS price_num,
        CAST(s.qty AS DOUBLE) * COALESCE(CAST(t.price AS DOUBLE), 0) AS revenue_proxy
    FROM sales s
    JOIN stores st ON s.stor_id = st.stor_id
    JOIN titles t ON s.title_id = t.title_id
),
type_metrics AS (
    SELECT
        type,
        COUNT(DISTINCT state) AS state_count,
        COUNT(DISTINCT stor_id) AS store_count,
        COUNT(DISTINCT payterms) AS payterm_count,
        COUNT(DISTINCT title_id) AS title_count,
        COUNT(DISTINCT ord_num) AS order_count,
        COUNT(*) AS sale_lines,
        SUM(qty) AS sample_qty,
        SUM(revenue_proxy) AS revenue_proxy
    FROM sales_enriched
    GROUP BY type
),
ranked_type AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY revenue_proxy DESC, type) AS type_revenue_rank,
        100.0 * revenue_proxy / NULLIF(SUM(revenue_proxy) OVER (), 0) AS revenue_share_pct
    FROM type_metrics
),
state_type AS (
    SELECT
        state,
        type,
        COUNT(DISTINCT stor_id) AS store_count,
        COUNT(DISTINCT payterms) AS payterm_count,
        COUNT(DISTINCT title_id) AS title_count,
        COUNT(DISTINCT ord_num) AS order_count,
        COUNT(*) AS sale_lines,
        SUM(qty) AS sample_qty,
        SUM(revenue_proxy) AS revenue_proxy
    FROM sales_enriched
    GROUP BY state, type
),
ranked_state_type AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY type ORDER BY revenue_proxy DESC, state) AS state_rank_in_type,
        100.0 * revenue_proxy / NULLIF(SUM(revenue_proxy) OVER (PARTITION BY type), 0) AS type_revenue_share_pct
    FROM state_type
),
payterms_type AS (
    SELECT
        payterms,
        type,
        COUNT(DISTINCT state) AS state_count,
        COUNT(DISTINCT stor_id) AS store_count,
        COUNT(DISTINCT title_id) AS title_count,
        COUNT(DISTINCT ord_num) AS order_count,
        COUNT(*) AS sale_lines,
        SUM(qty) AS sample_qty,
        SUM(revenue_proxy) AS revenue_proxy
    FROM sales_enriched
    GROUP BY payterms, type
),
ranked_payterms_type AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY payterms ORDER BY revenue_proxy DESC, type) AS type_rank_in_payterms,
        100.0 * revenue_proxy / NULLIF(SUM(revenue_proxy) OVER (PARTITION BY payterms), 0) AS payterms_revenue_share_pct
    FROM payterms_type
),
store_type AS (
    SELECT
        stor_name,
        state,
        type,
        COUNT(DISTINCT title_id) AS title_count,
        COUNT(DISTINCT ord_num) AS order_count,
        COUNT(*) AS sale_lines,
        SUM(qty) AS sample_qty,
        SUM(revenue_proxy) AS revenue_proxy
    FROM sales_enriched
    GROUP BY stor_name, state, type
),
ranked_store_type AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY type ORDER BY revenue_proxy DESC, stor_name) AS store_rank_in_type,
        100.0 * revenue_proxy / NULLIF(SUM(revenue_proxy) OVER (PARTITION BY type), 0) AS type_revenue_share_pct
    FROM store_type
),
discount_context AS (
    SELECT
        d.discounttype,
        COALESCE(st.stor_name, 'ALL_STORES') AS stor_name,
        COALESCE(st.state, 'ALL') AS state,
        CAST(d.lowqty AS DOUBLE) AS lowqty,
        CAST(d.highqty AS DOUBLE) AS highqty,
        CAST(d.discount AS DOUBLE) AS discount
    FROM discounts d
    LEFT JOIN stores st ON d.stor_id = st.stor_id
)
SELECT
    'type_channel_baseline' AS evidence_block,
    'title_type' AS grain,
    type AS item,
    CAST(state_count AS VARCHAR) AS item_2,
    CAST(payterm_count AS VARCHAR) AS item_3,
    'type_revenue_rank' AS rank_label,
    CAST(type_revenue_rank AS DOUBLE) AS rank_value,
    store_count,
    state_count,
    payterm_count,
    title_count,
    CAST(NULL AS BIGINT) AS type_count,
    order_count,
    sale_lines,
    ROUND(sample_qty, 4) AS sample_qty,
    ROUND(revenue_proxy, 4) AS revenue_proxy,
    ROUND(revenue_share_pct, 4) AS share_pct,
    CAST(NULL AS DOUBLE) AS secondary_value,
    'Type-level demand across states, stores, and payment terms.' AS notes
FROM ranked_type
UNION ALL
SELECT
    'state_type_fit',
    'state_type',
    state,
    type,
    CAST(store_count AS VARCHAR),
    'state_rank_in_type',
    CAST(state_rank_in_type AS DOUBLE),
    store_count,
    CAST(NULL AS BIGINT),
    payterm_count,
    title_count,
    CAST(NULL AS BIGINT),
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(type_revenue_share_pct, 4),
    CAST(NULL AS DOUBLE),
    'State-by-type fit and concentration.'
FROM ranked_state_type
UNION ALL
SELECT
    'payterms_type_fit',
    'payterms_type',
    payterms,
    type,
    CAST(store_count AS VARCHAR),
    'type_rank_in_payterms',
    CAST(type_rank_in_payterms AS DOUBLE),
    store_count,
    state_count,
    CAST(NULL AS BIGINT),
    title_count,
    CAST(NULL AS BIGINT),
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(payterms_revenue_share_pct, 4),
    CAST(NULL AS DOUBLE),
    'Payment-term demand mix by title type.'
FROM ranked_payterms_type
UNION ALL
SELECT
    'type_store_dependence',
    'store_type',
    type,
    stor_name,
    state,
    'store_rank_in_type',
    CAST(store_rank_in_type AS DOUBLE),
    CAST(1 AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    title_count,
    CAST(NULL AS BIGINT),
    order_count,
    sale_lines,
    ROUND(sample_qty, 4),
    ROUND(revenue_proxy, 4),
    ROUND(type_revenue_share_pct, 4),
    CAST(NULL AS DOUBLE),
    'Top store dependence within each title type.'
FROM ranked_store_type
WHERE store_rank_in_type <= 3
UNION ALL
SELECT
    'discount_channel_context',
    'discount_rule',
    discounttype,
    stor_name,
    state,
    'discount_pct',
    discount,
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    COALESCE(lowqty, 0),
    'Discount rule context for interpreting channel and type demand.'
FROM discount_context
ORDER BY evidence_block, rank_value, item;
