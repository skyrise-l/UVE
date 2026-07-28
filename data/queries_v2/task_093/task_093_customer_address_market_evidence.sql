WITH
order_value AS (
    SELECT
        order_id,
        COUNT(*) AS line_count,
        SUM(CAST(price AS DOUBLE)) AS order_value
    FROM order_line
    GROUP BY order_id
),
customer_address_profile AS (
    SELECT
        ca.customer_id,
        COUNT(DISTINCT ca.address_id) AS address_count,
        SUM(CASE WHEN ast.address_status = 'Active' THEN 1 ELSE 0 END) AS active_address_count,
        SUM(CASE WHEN ast.address_status = 'Inactive' THEN 1 ELSE 0 END) AS inactive_address_count,
        COUNT(DISTINCT c.country_name) AS address_country_count
    FROM customer_address ca
    LEFT JOIN address_status ast ON ca.status_id = ast.status_id
    LEFT JOIN address a ON ca.address_id = a.address_id
    LEFT JOIN country c ON a.country_id = c.country_id
    GROUP BY ca.customer_id
),
customer_order_profile AS (
    SELECT
        co.customer_id,
        COUNT(DISTINCT co.order_id) AS order_count,
        COUNT(DISTINCT c.country_name) AS destination_country_count,
        SUM(COALESCE(ov.line_count, 0)) AS line_count,
        SUM(COALESCE(ov.order_value, 0)) AS total_order_value,
        AVG(COALESCE(ov.order_value, 0)) AS avg_order_value,
        AVG(CAST(sm.cost AS DOUBLE)) AS avg_shipping_cost
    FROM cust_order co
    LEFT JOIN order_value ov ON co.order_id = ov.order_id
    LEFT JOIN shipping_method sm ON co.shipping_method_id = sm.method_id
    LEFT JOIN address a ON co.dest_address_id = a.address_id
    LEFT JOIN country c ON a.country_id = c.country_id
    GROUP BY co.customer_id
),
customer_profile AS (
    SELECT
        cu.customer_id,
        cu.first_name || ' ' || cu.last_name AS customer_name,
        COALESCE(cap.address_count, 0) AS address_count,
        COALESCE(cap.active_address_count, 0) AS active_address_count,
        COALESCE(cap.inactive_address_count, 0) AS inactive_address_count,
        COALESCE(cap.address_country_count, 0) AS address_country_count,
        COALESCE(cop.order_count, 0) AS order_count,
        COALESCE(cop.destination_country_count, 0) AS destination_country_count,
        COALESCE(cop.line_count, 0) AS line_count,
        COALESCE(cop.total_order_value, 0) AS total_order_value,
        COALESCE(cop.avg_order_value, 0) AS avg_order_value,
        COALESCE(cop.avg_shipping_cost, 0) AS avg_shipping_cost
    FROM customer cu
    LEFT JOIN customer_address_profile cap ON cu.customer_id = cap.customer_id
    LEFT JOIN customer_order_profile cop ON cu.customer_id = cop.customer_id
),
address_bucket AS (
    SELECT
        CASE
            WHEN address_count = 0 THEN 'no_address'
            WHEN address_count = 1 THEN 'single_address'
            WHEN address_count <= 3 THEN 'multi_address'
            ELSE 'high_address_count'
        END AS address_bucket,
        COUNT(*) AS customer_count,
        SUM(address_count) AS address_count,
        SUM(active_address_count) AS active_address_count,
        SUM(inactive_address_count) AS inactive_address_count,
        SUM(order_count) AS order_count,
        SUM(line_count) AS line_count,
        SUM(total_order_value) AS total_order_value,
        AVG(avg_order_value) AS avg_order_value,
        AVG(avg_shipping_cost) AS avg_shipping_cost,
        AVG(address_country_count) AS avg_address_country_count,
        AVG(destination_country_count) AS avg_destination_country_count
    FROM customer_profile
    GROUP BY address_bucket
),
active_bucket AS (
    SELECT
        CASE
            WHEN active_address_count = 0 THEN 'no_active_address'
            WHEN active_address_count = 1 THEN 'one_active_address'
            ELSE 'multiple_active_addresses'
        END AS active_bucket,
        COUNT(*) AS customer_count,
        SUM(address_count) AS address_count,
        SUM(active_address_count) AS active_address_count,
        SUM(inactive_address_count) AS inactive_address_count,
        SUM(order_count) AS order_count,
        SUM(line_count) AS line_count,
        SUM(total_order_value) AS total_order_value,
        AVG(avg_order_value) AS avg_order_value,
        AVG(avg_shipping_cost) AS avg_shipping_cost,
        AVG(address_country_count) AS avg_address_country_count,
        AVG(destination_country_count) AS avg_destination_country_count
    FROM customer_profile
    GROUP BY active_bucket
),
destination_country AS (
    SELECT
        c.country_name,
        COUNT(DISTINCT co.customer_id) AS customer_count,
        COUNT(DISTINCT co.order_id) AS order_count,
        SUM(COALESCE(ov.line_count, 0)) AS line_count,
        SUM(COALESCE(ov.order_value, 0)) AS total_order_value,
        AVG(COALESCE(ov.order_value, 0)) AS avg_order_value,
        AVG(CAST(sm.cost AS DOUBLE)) AS avg_shipping_cost
    FROM cust_order co
    LEFT JOIN order_value ov ON co.order_id = ov.order_id
    LEFT JOIN shipping_method sm ON co.shipping_method_id = sm.method_id
    LEFT JOIN address a ON co.dest_address_id = a.address_id
    LEFT JOIN country c ON a.country_id = c.country_id
    GROUP BY c.country_name
),
shipping_destination AS (
    SELECT
        sm.method_name,
        c.country_name,
        COUNT(DISTINCT co.customer_id) AS customer_count,
        COUNT(DISTINCT co.order_id) AS order_count,
        SUM(COALESCE(ov.line_count, 0)) AS line_count,
        SUM(COALESCE(ov.order_value, 0)) AS total_order_value,
        AVG(COALESCE(ov.order_value, 0)) AS avg_order_value,
        AVG(CAST(sm.cost AS DOUBLE)) AS avg_shipping_cost
    FROM cust_order co
    LEFT JOIN order_value ov ON co.order_id = ov.order_id
    LEFT JOIN shipping_method sm ON co.shipping_method_id = sm.method_id
    LEFT JOIN address a ON co.dest_address_id = a.address_id
    LEFT JOIN country c ON a.country_id = c.country_id
    GROUP BY sm.method_name, c.country_name
),
repeat_customer AS (
    SELECT
        CASE
            WHEN order_count = 0 THEN 'no_observed_orders'
            WHEN order_count = 1 THEN 'single_order_customer'
            ELSE 'repeat_customer'
        END AS repeat_bucket,
        COUNT(*) AS customer_count,
        SUM(address_count) AS address_count,
        SUM(active_address_count) AS active_address_count,
        SUM(inactive_address_count) AS inactive_address_count,
        SUM(order_count) AS order_count,
        SUM(line_count) AS line_count,
        SUM(total_order_value) AS total_order_value,
        AVG(avg_order_value) AS avg_order_value,
        AVG(avg_shipping_cost) AS avg_shipping_cost,
        AVG(address_country_count) AS avg_address_country_count,
        AVG(destination_country_count) AS avg_destination_country_count
    FROM customer_profile
    GROUP BY repeat_bucket
),
top_customers AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY total_order_value DESC, order_count DESC, customer_name) AS rank_value,
        100.0 * total_order_value / NULLIF(SUM(total_order_value) OVER (), 0) AS share_pct
    FROM customer_profile
),
ranked_address_bucket AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY total_order_value DESC, customer_count DESC, address_bucket) AS rank_value,
        100.0 * total_order_value / NULLIF(SUM(total_order_value) OVER (), 0) AS share_pct
    FROM address_bucket
),
ranked_active_bucket AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY total_order_value DESC, customer_count DESC, active_bucket) AS rank_value,
        100.0 * total_order_value / NULLIF(SUM(total_order_value) OVER (), 0) AS share_pct
    FROM active_bucket
),
ranked_country AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY total_order_value DESC, order_count DESC, country_name) AS rank_value,
        100.0 * total_order_value / NULLIF(SUM(total_order_value) OVER (), 0) AS share_pct
    FROM destination_country
),
ranked_shipping_destination AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY method_name ORDER BY total_order_value DESC, order_count DESC, country_name) AS rank_value,
        100.0 * total_order_value / NULLIF(SUM(total_order_value) OVER (PARTITION BY method_name), 0) AS share_pct
    FROM shipping_destination
),
ranked_repeat AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY total_order_value DESC, customer_count DESC, repeat_bucket) AS rank_value,
        100.0 * total_order_value / NULLIF(SUM(total_order_value) OVER (), 0) AS share_pct
    FROM repeat_customer
)
SELECT
    'customer_address_baseline' AS evidence_block,
    'address_bucket' AS grain,
    address_bucket AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'address_bucket_value_rank' AS rank_label,
    CAST(rank_value AS DOUBLE) AS rank_value,
    customer_count,
    address_count,
    active_address_count,
    inactive_address_count,
    order_count,
    line_count,
    ROUND(total_order_value, 4) AS total_order_value,
    ROUND(avg_order_value, 4) AS avg_order_value,
    ROUND(avg_shipping_cost, 4) AS shipping_cost,
    ROUND(avg_address_country_count, 4) AS country_count,
    ROUND(share_pct, 4) AS share_pct,
    ROUND(avg_destination_country_count, 4) AS secondary_value,
    'Customer address complexity checked against order value.' AS notes
FROM ranked_address_bucket
UNION ALL
SELECT
    'active_address_coverage',
    'active_address_bucket',
    active_bucket,
    CAST(NULL AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'active_bucket_value_rank',
    CAST(rank_value AS DOUBLE),
    customer_count,
    address_count,
    active_address_count,
    inactive_address_count,
    order_count,
    line_count,
    ROUND(total_order_value, 4),
    ROUND(avg_order_value, 4),
    ROUND(avg_shipping_cost, 4),
    ROUND(avg_address_country_count, 4),
    ROUND(share_pct, 4),
    ROUND(avg_destination_country_count, 4),
    'Active address coverage compared with ordering footprint.'
FROM ranked_active_bucket
UNION ALL
SELECT
    'destination_country_customer_mix',
    'destination_country',
    country_name,
    CAST(NULL AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'country_value_rank',
    CAST(rank_value AS DOUBLE),
    customer_count,
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    order_count,
    line_count,
    ROUND(total_order_value, 4),
    ROUND(avg_order_value, 4),
    ROUND(avg_shipping_cost, 4),
    CAST(NULL AS DOUBLE),
    ROUND(share_pct, 4),
    CAST(NULL AS DOUBLE),
    'Destination country concentration by customers, orders, and value.'
FROM ranked_country
UNION ALL
SELECT
    'shipping_destination_mix',
    'shipping_destination',
    method_name,
    country_name,
    CAST(NULL AS VARCHAR),
    'country_rank_within_shipping',
    CAST(rank_value AS DOUBLE),
    customer_count,
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    order_count,
    line_count,
    ROUND(total_order_value, 4),
    ROUND(avg_order_value, 4),
    ROUND(avg_shipping_cost, 4),
    CAST(NULL AS DOUBLE),
    ROUND(share_pct, 4),
    CAST(NULL AS DOUBLE),
    'Shipping method and destination-country interaction.'
FROM ranked_shipping_destination
UNION ALL
SELECT
    'repeat_customer_profile',
    'repeat_bucket',
    repeat_bucket,
    CAST(NULL AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'repeat_bucket_value_rank',
    CAST(rank_value AS DOUBLE),
    customer_count,
    address_count,
    active_address_count,
    inactive_address_count,
    order_count,
    line_count,
    ROUND(total_order_value, 4),
    ROUND(avg_order_value, 4),
    ROUND(avg_shipping_cost, 4),
    ROUND(avg_address_country_count, 4),
    ROUND(share_pct, 4),
    ROUND(avg_destination_country_count, 4),
    'Repeat ordering and address footprint relationship.'
FROM ranked_repeat
UNION ALL
SELECT
    'top_customer_address_value',
    'customer',
    customer_name,
    CAST(customer_id AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'customer_value_rank',
    CAST(rank_value AS DOUBLE),
    CAST(1 AS BIGINT),
    address_count,
    active_address_count,
    inactive_address_count,
    order_count,
    line_count,
    ROUND(total_order_value, 4),
    ROUND(avg_order_value, 4),
    ROUND(avg_shipping_cost, 4),
    CAST(address_country_count AS DOUBLE),
    ROUND(share_pct, 4),
    CAST(destination_country_count AS DOUBLE),
    'Customer-level address and order-value evidence for top or mismatched customers.'
FROM top_customers
WHERE order_count > 0 OR rank_value <= 20
ORDER BY evidence_block, rank_value, item;
