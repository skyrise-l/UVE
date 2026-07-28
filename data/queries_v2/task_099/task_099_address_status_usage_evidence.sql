WITH
status_flags AS (
    SELECT oh.order_id,
        MAX(CASE WHEN os.status_value = 'Delivered' THEN 1 ELSE 0 END) AS has_delivered,
        MAX(CASE WHEN os.status_value = 'Cancelled' THEN 1 ELSE 0 END) AS has_cancelled,
        MAX(CASE WHEN os.status_value = 'Returned' THEN 1 ELSE 0 END) AS has_returned,
        COUNT(DISTINCT os.status_value) AS status_count
    FROM order_history oh JOIN order_status os ON oh.status_id = os.status_id
    GROUP BY oh.order_id
),
order_value AS (
    SELECT order_id, COUNT(*) AS line_count, COUNT(DISTINCT book_id) AS book_count, SUM(CAST(price AS DOUBLE)) AS order_value
    FROM order_line GROUP BY order_id
),
order_base AS (
    SELECT co.order_id, co.customer_id, co.dest_address_id, a.city, cn.country_name, sm.method_name, CAST(sm.cost AS DOUBLE) AS shipping_cost,
        COALESCE(ast.address_status, 'not_saved_for_customer') AS destination_address_status,
        CASE WHEN ca.address_id IS NULL THEN 'not_saved_for_customer' ELSE 'saved_for_customer' END AS address_match_bucket,
        COALESCE(ov.line_count, 0) AS line_count, COALESCE(ov.book_count, 0) AS book_count, COALESCE(ov.order_value, 0) AS order_value,
        COALESCE(sf.has_delivered, 0) AS has_delivered, COALESCE(sf.has_cancelled, 0) AS has_cancelled, COALESCE(sf.has_returned, 0) AS has_returned,
        CASE
            WHEN COALESCE(sf.has_cancelled, 0) = 1 THEN 'cancelled_path'
            WHEN COALESCE(sf.has_returned, 0) = 1 THEN 'returned_path'
            WHEN COALESCE(sf.has_delivered, 0) = 1 THEN 'delivered_path'
            WHEN COALESCE(sf.status_count, 0) = 0 THEN 'no_history'
            ELSE 'incomplete_or_in_progress'
        END AS lifecycle_bucket
    FROM cust_order co
    LEFT JOIN order_value ov ON co.order_id = ov.order_id
    LEFT JOIN customer_address ca ON co.customer_id = ca.customer_id AND co.dest_address_id = ca.address_id
    LEFT JOIN address_status ast ON ca.status_id = ast.status_id
    LEFT JOIN address a ON co.dest_address_id = a.address_id
    LEFT JOIN country cn ON a.country_id = cn.country_id
    LEFT JOIN shipping_method sm ON co.shipping_method_id = sm.method_id
    LEFT JOIN status_flags sf ON co.order_id = sf.order_id
),
customer_saved_counts AS (
    SELECT c.customer_id,
        COUNT(DISTINCT ca.address_id) AS saved_address_count,
        COUNT(DISTINCT CASE WHEN ast.address_status = 'Active' THEN ca.address_id END) AS active_address_count,
        COUNT(DISTINCT CASE WHEN ast.address_status = 'Inactive' THEN ca.address_id END) AS inactive_address_count
    FROM customer c
    LEFT JOIN customer_address ca ON c.customer_id = ca.customer_id
    LEFT JOIN address_status ast ON ca.status_id = ast.status_id
    GROUP BY c.customer_id
),
customer_order_metrics AS (
    SELECT customer_id,
        COUNT(DISTINCT order_id) AS order_count,
        SUM(order_value) AS total_price
    FROM order_base
    GROUP BY customer_id
),
customer_address_profile AS (
    SELECT csc.customer_id, csc.saved_address_count, csc.active_address_count, csc.inactive_address_count,
        COALESCE(com.order_count, 0) AS order_count,
        COALESCE(com.total_price, 0) AS total_price
    FROM customer_saved_counts csc
    LEFT JOIN customer_order_metrics com ON csc.customer_id = com.customer_id
),
address_status_base AS (
    SELECT destination_address_status AS item, COUNT(*) AS order_count, COUNT(DISTINCT customer_id) AS customer_count,
        SUM(line_count) AS line_count, SUM(book_count) AS book_count, SUM(order_value) AS total_price, AVG(order_value) AS avg_order_value,
        AVG(shipping_cost) AS avg_shipping_cost, SUM(has_delivered) AS delivered_orders, SUM(has_cancelled) AS cancelled_orders, SUM(has_returned) AS returned_orders
    FROM order_base GROUP BY destination_address_status
),
ranked_address_status AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY total_price DESC, order_count DESC, item) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (), 0) AS share_pct FROM address_status_base
),
match_base AS (
    SELECT address_match_bucket AS item, COUNT(*) AS order_count, COUNT(DISTINCT customer_id) AS customer_count,
        SUM(line_count) AS line_count, SUM(book_count) AS book_count, SUM(order_value) AS total_price, AVG(order_value) AS avg_order_value,
        AVG(shipping_cost) AS avg_shipping_cost
    FROM order_base GROUP BY address_match_bucket
),
ranked_match AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY total_price DESC, order_count DESC, item) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (), 0) AS share_pct FROM match_base
),
status_lifecycle AS (
    SELECT destination_address_status AS item, lifecycle_bucket AS item_2, COUNT(*) AS order_count, COUNT(DISTINCT customer_id) AS customer_count,
        SUM(line_count) AS line_count, SUM(book_count) AS book_count, SUM(order_value) AS total_price, AVG(order_value) AS avg_order_value
    FROM order_base GROUP BY destination_address_status, lifecycle_bucket
),
ranked_status_lifecycle AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY item ORDER BY order_count DESC, total_price DESC, item_2) AS rank_value,
        100.0 * order_count / NULLIF(SUM(order_count) OVER (PARTITION BY item), 0) AS share_pct FROM status_lifecycle
),
status_shipping AS (
    SELECT destination_address_status AS item, method_name AS item_2, COUNT(*) AS order_count, COUNT(DISTINCT customer_id) AS customer_count,
        SUM(line_count) AS line_count, SUM(book_count) AS book_count, SUM(order_value) AS total_price, AVG(order_value) AS avg_order_value,
        AVG(shipping_cost) AS avg_shipping_cost
    FROM order_base GROUP BY destination_address_status, method_name
),
ranked_status_shipping AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY item ORDER BY total_price DESC, order_count DESC, item_2) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (PARTITION BY item), 0) AS share_pct FROM status_shipping
),
status_country AS (
    SELECT destination_address_status AS item, country_name AS item_2, COUNT(*) AS order_count, COUNT(DISTINCT customer_id) AS customer_count,
        SUM(line_count) AS line_count, SUM(book_count) AS book_count, SUM(order_value) AS total_price, AVG(order_value) AS avg_order_value
    FROM order_base GROUP BY destination_address_status, country_name
),
ranked_status_country AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY item ORDER BY total_price DESC, order_count DESC, item_2) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (PARTITION BY item), 0) AS share_pct FROM status_country
),
profile_bucket AS (
    SELECT CASE
            WHEN inactive_address_count > 0 AND active_address_count > 0 THEN 'mixed_active_inactive_saved_addresses'
            WHEN inactive_address_count > 0 THEN 'inactive_only_saved_addresses'
            WHEN active_address_count > 1 THEN 'multiple_active_saved_addresses'
            WHEN active_address_count = 1 THEN 'one_active_saved_address'
            ELSE 'no_saved_address'
        END AS item,
        COUNT(*) AS customer_count, SUM(order_count) AS order_count, SUM(total_price) AS total_price,
        AVG(saved_address_count) AS avg_saved_address_count, AVG(active_address_count) AS avg_active_address_count, AVG(inactive_address_count) AS avg_inactive_address_count
    FROM customer_address_profile GROUP BY 1
),
ranked_profile_bucket AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY total_price DESC, customer_count DESC, item) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (), 0) AS share_pct FROM profile_bucket
),
city_country AS (
    SELECT destination_address_status AS item, country_name AS item_2, city AS item_3, COUNT(*) AS order_count, COUNT(DISTINCT customer_id) AS customer_count,
        SUM(order_value) AS total_price, AVG(order_value) AS avg_order_value
    FROM order_base GROUP BY destination_address_status, country_name, city
),
ranked_city_country AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY item ORDER BY total_price DESC, order_count DESC, item_2, item_3) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (PARTITION BY item), 0) AS share_pct FROM city_country
)
SELECT 'destination_address_status_baseline' AS evidence_block, 'destination_address_status' AS grain, item, CAST(NULL AS VARCHAR) AS item_2, CAST(NULL AS VARCHAR) AS item_3,
    'address_status_value_rank' AS rank_label, CAST(rank_value AS DOUBLE) AS rank_value, customer_count, order_count, line_count, book_count,
    ROUND(total_price, 4) AS total_price, ROUND(avg_order_value, 4) AS avg_order_value, ROUND(avg_shipping_cost, 4) AS secondary_value,
    delivered_orders, cancelled_orders, returned_orders, ROUND(share_pct, 4) AS share_pct, 'Demand by whether destination address is active, inactive, or unsaved for the customer.' AS notes FROM ranked_address_status
UNION ALL
SELECT 'order_address_match_profile', 'address_match_bucket', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), 'match_value_rank', CAST(rank_value AS DOUBLE), customer_count, order_count, line_count, book_count, ROUND(total_price, 4), ROUND(avg_order_value, 4), ROUND(avg_shipping_cost, 4), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), ROUND(share_pct, 4), 'Saved-versus-unsaved destination address usage.' FROM ranked_match
UNION ALL
SELECT 'address_status_lifecycle_mix', 'address_status_lifecycle', item, item_2, CAST(NULL AS VARCHAR), 'lifecycle_rank_within_address_status', CAST(rank_value AS DOUBLE), customer_count, order_count, line_count, book_count, ROUND(total_price, 4), ROUND(avg_order_value, 4), CAST(NULL AS DOUBLE), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), ROUND(share_pct, 4), 'Lifecycle outcomes by destination address status.' FROM ranked_status_lifecycle
UNION ALL
SELECT 'address_status_shipping_mix', 'address_status_shipping', item, item_2, CAST(NULL AS VARCHAR), 'shipping_rank_within_address_status', CAST(rank_value AS DOUBLE), customer_count, order_count, line_count, book_count, ROUND(total_price, 4), ROUND(avg_order_value, 4), ROUND(avg_shipping_cost, 4), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), ROUND(share_pct, 4), 'Shipping methods by destination address status.' FROM ranked_status_shipping
UNION ALL
SELECT 'address_status_country_mix', 'address_status_country', item, item_2, CAST(NULL AS VARCHAR), 'country_rank_within_address_status', CAST(rank_value AS DOUBLE), customer_count, order_count, line_count, book_count, ROUND(total_price, 4), ROUND(avg_order_value, 4), CAST(NULL AS DOUBLE), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), ROUND(share_pct, 4), 'Destination countries by address status.' FROM ranked_status_country WHERE rank_value <= 12
UNION ALL
SELECT 'customer_saved_address_profile', 'customer_address_profile', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), 'profile_value_rank', CAST(rank_value AS DOUBLE), customer_count, order_count, CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), ROUND(total_price, 4), CAST(NULL AS DOUBLE), ROUND(avg_saved_address_count, 4), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), ROUND(share_pct, 4), 'Customer saved-address profile compared with observed demand.' FROM ranked_profile_bucket
UNION ALL
SELECT 'top_status_city_destinations', 'address_status_city', item, item_2, item_3, 'city_rank_within_address_status', CAST(rank_value AS DOUBLE), customer_count, order_count, CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), ROUND(total_price, 4), ROUND(avg_order_value, 4), CAST(NULL AS DOUBLE), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), ROUND(share_pct, 4), 'Top city-country destinations within each address-status bucket.' FROM ranked_city_country WHERE rank_value <= 10
ORDER BY evidence_block, item, rank_value
