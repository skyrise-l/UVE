WITH
order_value AS (
    SELECT
        order_id,
        COUNT(*) AS line_count,
        COUNT(DISTINCT book_id) AS book_count,
        SUM(CAST(price AS DOUBLE)) AS order_value
    FROM order_line
    GROUP BY order_id
),
status_flags AS (
    SELECT
        oh.order_id,
        COUNT(*) AS history_rows,
        COUNT(DISTINCT os.status_value) AS status_count,
        MAX(CASE WHEN os.status_value = 'Delivered' THEN 1 ELSE 0 END) AS has_delivered,
        MAX(CASE WHEN os.status_value = 'Cancelled' THEN 1 ELSE 0 END) AS has_cancelled,
        MAX(CASE WHEN os.status_value = 'Returned' THEN 1 ELSE 0 END) AS has_returned,
        MAX(SUBSTR(CAST(oh.status_date AS VARCHAR), 1, 10)) AS latest_status_date
    FROM order_history oh
    JOIN order_status os ON oh.status_id = os.status_id
    GROUP BY oh.order_id
),
order_base AS (
    SELECT
        co.order_id,
        co.customer_id,
        SUBSTR(CAST(co.order_date AS VARCHAR), 1, 7) AS order_month,
        sm.method_name,
        CAST(sm.cost AS DOUBLE) AS shipping_cost,
        c.country_name,
        COALESCE(ov.line_count, 0) AS line_count,
        COALESCE(ov.book_count, 0) AS book_count,
        COALESCE(ov.order_value, 0) AS order_value,
        COALESCE(sf.history_rows, 0) AS history_rows,
        COALESCE(sf.status_count, 0) AS status_count,
        COALESCE(sf.has_delivered, 0) AS has_delivered,
        COALESCE(sf.has_cancelled, 0) AS has_cancelled,
        COALESCE(sf.has_returned, 0) AS has_returned
    FROM cust_order co
    LEFT JOIN order_value ov ON co.order_id = ov.order_id
    LEFT JOIN status_flags sf ON co.order_id = sf.order_id
    LEFT JOIN shipping_method sm ON co.shipping_method_id = sm.method_id
    LEFT JOIN address a ON co.dest_address_id = a.address_id
    LEFT JOIN country c ON a.country_id = c.country_id
),
shipping_summary AS (
    SELECT
        method_name,
        COUNT(*) AS order_count,
        COUNT(DISTINCT customer_id) AS customer_count,
        SUM(line_count) AS line_count,
        SUM(book_count) AS book_count,
        SUM(order_value) AS total_order_value,
        AVG(order_value) AS avg_order_value,
        AVG(shipping_cost) AS shipping_cost,
        AVG(status_count) AS avg_status_count,
        SUM(has_delivered) AS delivered_orders,
        SUM(has_cancelled) AS cancelled_orders,
        SUM(has_returned) AS returned_orders
    FROM order_base
    GROUP BY method_name
),
ranked_shipping AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY total_order_value DESC, order_count DESC, method_name) AS rank_value,
        100.0 * total_order_value / NULLIF(SUM(total_order_value) OVER (), 0) AS share_pct
    FROM shipping_summary
),
status_outcome AS (
    SELECT
        outcome,
        COUNT(*) AS order_count,
        SUM(order_value) AS total_order_value
    FROM (
        SELECT
            order_value,
            CASE
                WHEN has_cancelled = 1 THEN 'cancelled'
                WHEN has_returned = 1 THEN 'returned'
                WHEN has_delivered = 1 THEN 'delivered'
                ELSE 'no_terminal_status'
            END AS outcome
        FROM order_base
    ) outcome_base
    GROUP BY outcome
),
ranked_status AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY order_count DESC, outcome) AS rank_value,
        100.0 * order_count / NULLIF(SUM(order_count) OVER (), 0) AS share_pct
    FROM status_outcome
),
shipping_status AS (
    SELECT
        method_name,
        CASE
            WHEN has_cancelled = 1 THEN 'cancelled'
            WHEN has_returned = 1 THEN 'returned'
            WHEN has_delivered = 1 THEN 'delivered'
            ELSE 'no_terminal_status'
        END AS outcome,
        COUNT(*) AS order_count,
        COUNT(DISTINCT customer_id) AS customer_count,
        SUM(order_value) AS total_order_value,
        AVG(order_value) AS avg_order_value,
        AVG(status_count) AS avg_status_count
    FROM order_base
    GROUP BY method_name, outcome
),
ranked_shipping_status AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY method_name ORDER BY order_count DESC, total_order_value DESC, outcome) AS rank_value,
        100.0 * order_count / NULLIF(SUM(order_count) OVER (PARTITION BY method_name), 0) AS share_pct
    FROM shipping_status
),
order_value_tertile AS (
    SELECT
        *,
        NTILE(3) OVER (ORDER BY order_value DESC, order_id) AS value_tertile
    FROM order_base
),
country_mix AS (
    SELECT
        country_name,
        COUNT(*) AS order_count,
        COUNT(DISTINCT customer_id) AS customer_count,
        SUM(line_count) AS line_count,
        SUM(book_count) AS book_count,
        SUM(order_value) AS total_order_value,
        AVG(order_value) AS avg_order_value,
        SUM(has_delivered) AS delivered_orders,
        SUM(has_cancelled) AS cancelled_orders,
        SUM(has_returned) AS returned_orders
    FROM order_base
    GROUP BY country_name
),
ranked_country AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY total_order_value DESC, order_count DESC, country_name) AS rank_value,
        100.0 * total_order_value / NULLIF(SUM(total_order_value) OVER (), 0) AS share_pct
    FROM country_mix
),
value_bucket AS (
    SELECT
        CASE
            WHEN value_tertile = 1 THEN 'high_value_tertile'
            WHEN value_tertile = 2 THEN 'mid_value_tertile'
            ELSE 'low_value_tertile'
        END AS value_bucket,
        COUNT(*) AS order_count,
        COUNT(DISTINCT customer_id) AS customer_count,
        SUM(line_count) AS line_count,
        SUM(book_count) AS book_count,
        SUM(order_value) AS total_order_value,
        AVG(order_value) AS avg_order_value,
        SUM(has_delivered) AS delivered_orders,
        SUM(has_cancelled) AS cancelled_orders,
        SUM(has_returned) AS returned_orders,
        AVG(status_count) AS avg_status_count
    FROM order_value_tertile
    GROUP BY value_bucket
),
ranked_value_bucket AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY total_order_value DESC, order_count DESC, value_bucket) AS rank_value,
        100.0 * total_order_value / NULLIF(SUM(total_order_value) OVER (), 0) AS share_pct
    FROM value_bucket
),
month_profile AS (
    SELECT
        order_month,
        COUNT(*) AS order_count,
        COUNT(DISTINCT customer_id) AS customer_count,
        SUM(line_count) AS line_count,
        SUM(book_count) AS book_count,
        SUM(order_value) AS total_order_value,
        AVG(order_value) AS avg_order_value,
        SUM(has_delivered) AS delivered_orders,
        SUM(has_cancelled) AS cancelled_orders,
        SUM(has_returned) AS returned_orders,
        AVG(status_count) AS avg_status_count
    FROM order_base
    GROUP BY order_month
),
ranked_month AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY total_order_value DESC, order_count DESC, order_month) AS rank_value,
        100.0 * total_order_value / NULLIF(SUM(total_order_value) OVER (), 0) AS share_pct
    FROM month_profile
)
SELECT
    'shipping_method_order_baseline' AS evidence_block,
    'shipping_method' AS grain,
    method_name AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'shipping_value_rank' AS rank_label,
    CAST(rank_value AS DOUBLE) AS rank_value,
    order_count,
    customer_count,
    line_count,
    book_count,
    ROUND(total_order_value, 4) AS total_order_value,
    ROUND(avg_order_value, 4) AS avg_order_value,
    ROUND(shipping_cost, 4) AS shipping_cost,
    ROUND(avg_status_count, 4) AS status_count,
    delivered_orders,
    cancelled_orders,
    returned_orders,
    ROUND(share_pct, 4) AS share_pct,
    CAST(NULL AS DOUBLE) AS secondary_value,
    'Order value, customer reach, and status exposure by shipping method.' AS notes
FROM ranked_shipping
UNION ALL
SELECT
    'status_outcome_baseline',
    'status_outcome',
    outcome,
    CAST(NULL AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'outcome_order_rank',
    CAST(rank_value AS DOUBLE),
    order_count,
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    ROUND(total_order_value, 4),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    ROUND(share_pct, 4),
    CAST(NULL AS DOUBLE),
    'Terminal and unresolved fulfillment outcomes across orders.'
FROM ranked_status
UNION ALL
SELECT
    'shipping_status_interaction',
    'shipping_method_status',
    method_name,
    outcome,
    CAST(NULL AS VARCHAR),
    'outcome_rank_within_shipping',
    CAST(rank_value AS DOUBLE),
    order_count,
    customer_count,
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    ROUND(total_order_value, 4),
    ROUND(avg_order_value, 4),
    CAST(NULL AS DOUBLE),
    ROUND(avg_status_count, 4),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    ROUND(share_pct, 4),
    CAST(NULL AS DOUBLE),
    'Interaction between selected shipping method and fulfillment outcome.'
FROM ranked_shipping_status
UNION ALL
SELECT
    'destination_country_order_mix',
    'destination_country',
    country_name,
    CAST(NULL AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'country_value_rank',
    CAST(rank_value AS DOUBLE),
    order_count,
    customer_count,
    line_count,
    book_count,
    ROUND(total_order_value, 4),
    ROUND(avg_order_value, 4),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    delivered_orders,
    cancelled_orders,
    returned_orders,
    ROUND(share_pct, 4),
    CAST(NULL AS DOUBLE),
    'Destination-country concentration of order value and fulfillment exposure.'
FROM ranked_country
UNION ALL
SELECT
    'order_value_bucket_status',
    'order_value_bucket',
    value_bucket,
    CAST(NULL AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'value_bucket_rank',
    CAST(rank_value AS DOUBLE),
    order_count,
    customer_count,
    line_count,
    book_count,
    ROUND(total_order_value, 4),
    ROUND(avg_order_value, 4),
    CAST(NULL AS DOUBLE),
    ROUND(avg_status_count, 4),
    delivered_orders,
    cancelled_orders,
    returned_orders,
    ROUND(share_pct, 4),
    CAST(NULL AS DOUBLE),
    'High- and low-value order buckets checked against status exposure.'
FROM ranked_value_bucket
UNION ALL
SELECT
    'order_month_profile',
    'order_month',
    order_month,
    CAST(NULL AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'month_value_rank',
    CAST(rank_value AS DOUBLE),
    order_count,
    customer_count,
    line_count,
    book_count,
    ROUND(total_order_value, 4),
    ROUND(avg_order_value, 4),
    CAST(NULL AS DOUBLE),
    ROUND(avg_status_count, 4),
    delivered_orders,
    cancelled_orders,
    returned_orders,
    ROUND(share_pct, 4),
    CAST(NULL AS DOUBLE),
    'Order timing profile for demand and fulfillment context.'
FROM ranked_month
ORDER BY evidence_block, rank_value, item;
