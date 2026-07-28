WITH
order_value AS (
    SELECT
        order_id,
        COUNT(*) AS line_count,
        SUM(CAST(price AS DOUBLE)) AS order_value
    FROM order_line
    GROUP BY order_id
),
latest_status AS (
    SELECT
        order_id,
        status_value AS latest_status_value,
        status_id AS latest_status_id,
        status_date AS latest_status_date
    FROM (
        SELECT
            oh.order_id,
            os.status_value,
            os.status_id,
            oh.status_date,
            ROW_NUMBER() OVER (PARTITION BY oh.order_id ORDER BY oh.status_date DESC, os.status_id DESC) AS rn
        FROM order_history oh
        JOIN order_status os ON oh.status_id = os.status_id
    ) x
    WHERE rn = 1
),
history_agg AS (
    SELECT
        oh.order_id,
        COUNT(*) AS history_rows,
        COUNT(DISTINCT os.status_value) AS status_count,
        MIN(os.status_id) AS min_status_id,
        MAX(os.status_id) AS max_status_id,
        MAX(CASE WHEN os.status_value = 'Delivered' THEN 1 ELSE 0 END) AS has_delivered,
        MAX(CASE WHEN os.status_value = 'Cancelled' THEN 1 ELSE 0 END) AS has_cancelled,
        MAX(CASE WHEN os.status_value = 'Returned' THEN 1 ELSE 0 END) AS has_returned
    FROM order_history oh
    JOIN order_status os ON oh.status_id = os.status_id
    GROUP BY oh.order_id
),
order_base AS (
    SELECT
        co.order_id,
        co.customer_id,
        sm.method_name,
        CAST(sm.cost AS DOUBLE) AS shipping_cost,
        c.country_name,
        COALESCE(ov.line_count, 0) AS line_count,
        COALESCE(ov.order_value, 0) AS order_value,
        COALESCE(ha.history_rows, 0) AS history_rows,
        COALESCE(ha.status_count, 0) AS status_count,
        COALESCE(ha.min_status_id, 0) AS min_status_id,
        COALESCE(ha.max_status_id, 0) AS max_status_id,
        COALESCE(ha.has_delivered, 0) AS has_delivered,
        COALESCE(ha.has_cancelled, 0) AS has_cancelled,
        COALESCE(ha.has_returned, 0) AS has_returned,
        COALESCE(ls.latest_status_value, 'no_history') AS latest_status_value,
        CASE
            WHEN COALESCE(ha.has_cancelled, 0) = 1 THEN 'cancelled_path'
            WHEN COALESCE(ha.has_returned, 0) = 1 THEN 'returned_path'
            WHEN COALESCE(ha.has_delivered, 0) = 1 THEN 'delivered_path'
            WHEN COALESCE(ha.status_count, 0) = 0 THEN 'no_history'
            ELSE 'incomplete_or_in_progress'
        END AS lifecycle_bucket
    FROM cust_order co
    LEFT JOIN order_value ov ON co.order_id = ov.order_id
    LEFT JOIN history_agg ha ON co.order_id = ha.order_id
    LEFT JOIN latest_status ls ON co.order_id = ls.order_id
    LEFT JOIN shipping_method sm ON co.shipping_method_id = sm.method_id
    LEFT JOIN address a ON co.dest_address_id = a.address_id
    LEFT JOIN country c ON a.country_id = c.country_id
),
order_base_ranked AS (
    SELECT
        *,
        CASE
            WHEN NTILE(3) OVER (ORDER BY order_value DESC, order_id) = 1 THEN 'high_value_tertile'
            WHEN NTILE(3) OVER (ORDER BY order_value DESC, order_id) = 2 THEN 'mid_value_tertile'
            ELSE 'low_value_tertile'
        END AS value_bucket
    FROM order_base
),
history_depth AS (
    SELECT
        CAST(status_count AS VARCHAR) AS item,
        COUNT(*) AS order_count,
        SUM(line_count) AS line_count,
        SUM(order_value) AS total_order_value,
        AVG(order_value) AS avg_order_value,
        AVG(history_rows) AS avg_history_rows,
        AVG(min_status_id) AS avg_min_status_id,
        AVG(max_status_id) AS avg_max_status_id,
        SUM(has_delivered) AS delivered_orders,
        SUM(has_cancelled) AS cancelled_orders,
        SUM(has_returned) AS returned_orders
    FROM order_base_ranked
    GROUP BY status_count
),
latest_status_profile AS (
    SELECT
        latest_status_value AS item,
        COUNT(*) AS order_count,
        SUM(line_count) AS line_count,
        SUM(order_value) AS total_order_value,
        AVG(order_value) AS avg_order_value,
        AVG(history_rows) AS avg_history_rows,
        AVG(status_count) AS avg_status_count,
        SUM(has_delivered) AS delivered_orders,
        SUM(has_cancelled) AS cancelled_orders,
        SUM(has_returned) AS returned_orders
    FROM order_base_ranked
    GROUP BY latest_status_value
),
lifecycle_profile AS (
    SELECT
        lifecycle_bucket AS item,
        COUNT(*) AS order_count,
        SUM(line_count) AS line_count,
        SUM(order_value) AS total_order_value,
        AVG(order_value) AS avg_order_value,
        AVG(history_rows) AS avg_history_rows,
        AVG(status_count) AS avg_status_count,
        SUM(has_delivered) AS delivered_orders,
        SUM(has_cancelled) AS cancelled_orders,
        SUM(has_returned) AS returned_orders
    FROM order_base_ranked
    GROUP BY lifecycle_bucket
),
shipping_lifecycle AS (
    SELECT
        method_name AS item,
        lifecycle_bucket AS item_2,
        COUNT(*) AS order_count,
        SUM(line_count) AS line_count,
        SUM(order_value) AS total_order_value,
        AVG(order_value) AS avg_order_value,
        AVG(history_rows) AS avg_history_rows,
        AVG(status_count) AS avg_status_count,
        SUM(has_delivered) AS delivered_orders,
        SUM(has_cancelled) AS cancelled_orders,
        SUM(has_returned) AS returned_orders,
        AVG(shipping_cost) AS avg_shipping_cost
    FROM order_base_ranked
    GROUP BY method_name, lifecycle_bucket
),
value_lifecycle AS (
    SELECT
        value_bucket AS item,
        lifecycle_bucket AS item_2,
        COUNT(*) AS order_count,
        SUM(line_count) AS line_count,
        SUM(order_value) AS total_order_value,
        AVG(order_value) AS avg_order_value,
        AVG(history_rows) AS avg_history_rows,
        AVG(status_count) AS avg_status_count,
        SUM(has_delivered) AS delivered_orders,
        SUM(has_cancelled) AS cancelled_orders,
        SUM(has_returned) AS returned_orders
    FROM order_base_ranked
    GROUP BY value_bucket, lifecycle_bucket
),
country_lifecycle AS (
    SELECT
        country_name AS item,
        lifecycle_bucket AS item_2,
        COUNT(*) AS order_count,
        SUM(line_count) AS line_count,
        SUM(order_value) AS total_order_value,
        AVG(order_value) AS avg_order_value,
        AVG(history_rows) AS avg_history_rows,
        AVG(status_count) AS avg_status_count,
        SUM(has_delivered) AS delivered_orders,
        SUM(has_cancelled) AS cancelled_orders,
        SUM(has_returned) AS returned_orders
    FROM order_base_ranked
    GROUP BY country_name, lifecycle_bucket
),
ranked_history_depth AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY order_count DESC, total_order_value DESC, item) AS rank_value,
        100.0 * order_count / NULLIF(SUM(order_count) OVER (), 0) AS share_pct
    FROM history_depth
),
ranked_latest AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY order_count DESC, total_order_value DESC, item) AS rank_value,
        100.0 * order_count / NULLIF(SUM(order_count) OVER (), 0) AS share_pct
    FROM latest_status_profile
),
ranked_lifecycle AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY order_count DESC, total_order_value DESC, item) AS rank_value,
        100.0 * order_count / NULLIF(SUM(order_count) OVER (), 0) AS share_pct
    FROM lifecycle_profile
),
ranked_shipping_lifecycle AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY item ORDER BY order_count DESC, total_order_value DESC, item_2) AS rank_value,
        100.0 * order_count / NULLIF(SUM(order_count) OVER (PARTITION BY item), 0) AS share_pct
    FROM shipping_lifecycle
),
ranked_value_lifecycle AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY item ORDER BY order_count DESC, total_order_value DESC, item_2) AS rank_value,
        100.0 * order_count / NULLIF(SUM(order_count) OVER (PARTITION BY item), 0) AS share_pct
    FROM value_lifecycle
),
ranked_country_lifecycle AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY item ORDER BY order_count DESC, total_order_value DESC, item_2) AS rank_value,
        100.0 * order_count / NULLIF(SUM(order_count) OVER (PARTITION BY item), 0) AS share_pct
    FROM country_lifecycle
)
SELECT
    'order_history_depth' AS evidence_block,
    'status_count' AS grain,
    item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'status_count_order_rank' AS rank_label,
    CAST(rank_value AS DOUBLE) AS rank_value,
    order_count,
    line_count,
    ROUND(total_order_value, 4) AS total_order_value,
    ROUND(avg_order_value, 4) AS avg_order_value,
    ROUND(avg_history_rows, 4) AS history_rows,
    CAST(item AS DOUBLE) AS status_count,
    ROUND(avg_min_status_id, 4) AS min_status_id,
    ROUND(avg_max_status_id, 4) AS max_status_id,
    delivered_orders,
    cancelled_orders,
    returned_orders,
    ROUND(share_pct, 4) AS share_pct,
    CAST(NULL AS DOUBLE) AS secondary_value,
    'History-depth coverage for order lifecycle analysis.' AS notes
FROM ranked_history_depth
UNION ALL
SELECT
    'latest_status_profile',
    'latest_status',
    item,
    CAST(NULL AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'latest_status_order_rank',
    CAST(rank_value AS DOUBLE),
    order_count,
    line_count,
    ROUND(total_order_value, 4),
    ROUND(avg_order_value, 4),
    ROUND(avg_history_rows, 4),
    ROUND(avg_status_count, 4),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    delivered_orders,
    cancelled_orders,
    returned_orders,
    ROUND(share_pct, 4),
    CAST(NULL AS DOUBLE),
    'Latest observed status distribution.'
FROM ranked_latest
UNION ALL
SELECT
    'terminal_outcome_profile',
    'lifecycle_bucket',
    item,
    CAST(NULL AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'lifecycle_order_rank',
    CAST(rank_value AS DOUBLE),
    order_count,
    line_count,
    ROUND(total_order_value, 4),
    ROUND(avg_order_value, 4),
    ROUND(avg_history_rows, 4),
    ROUND(avg_status_count, 4),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    delivered_orders,
    cancelled_orders,
    returned_orders,
    ROUND(share_pct, 4),
    CAST(NULL AS DOUBLE),
    'Delivered, cancelled, returned, incomplete, and no-history lifecycle buckets.'
FROM ranked_lifecycle
UNION ALL
SELECT
    'lifecycle_by_shipping',
    'shipping_lifecycle',
    item,
    item_2,
    CAST(NULL AS VARCHAR),
    'lifecycle_rank_within_shipping',
    CAST(rank_value AS DOUBLE),
    order_count,
    line_count,
    ROUND(total_order_value, 4),
    ROUND(avg_order_value, 4),
    ROUND(avg_history_rows, 4),
    ROUND(avg_status_count, 4),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    delivered_orders,
    cancelled_orders,
    returned_orders,
    ROUND(share_pct, 4),
    ROUND(avg_shipping_cost, 4),
    'Lifecycle buckets compared across shipping methods.'
FROM ranked_shipping_lifecycle
UNION ALL
SELECT
    'lifecycle_by_value_bucket',
    'value_lifecycle',
    item,
    item_2,
    CAST(NULL AS VARCHAR),
    'lifecycle_rank_within_value',
    CAST(rank_value AS DOUBLE),
    order_count,
    line_count,
    ROUND(total_order_value, 4),
    ROUND(avg_order_value, 4),
    ROUND(avg_history_rows, 4),
    ROUND(avg_status_count, 4),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    delivered_orders,
    cancelled_orders,
    returned_orders,
    ROUND(share_pct, 4),
    CAST(NULL AS DOUBLE),
    'Lifecycle buckets checked separately for order-value tiers.'
FROM ranked_value_lifecycle
UNION ALL
SELECT
    'lifecycle_by_country',
    'country_lifecycle',
    item,
    item_2,
    CAST(NULL AS VARCHAR),
    'lifecycle_rank_within_country',
    CAST(rank_value AS DOUBLE),
    order_count,
    line_count,
    ROUND(total_order_value, 4),
    ROUND(avg_order_value, 4),
    ROUND(avg_history_rows, 4),
    ROUND(avg_status_count, 4),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    delivered_orders,
    cancelled_orders,
    returned_orders,
    ROUND(share_pct, 4),
    CAST(NULL AS DOUBLE),
    'Lifecycle buckets by destination country.'
FROM ranked_country_lifecycle
ORDER BY evidence_block, rank_value, item;
