WITH
order_value AS (
    SELECT order_id, COUNT(*) AS line_count, COUNT(DISTINCT book_id) AS book_count, SUM(CAST(price AS DOUBLE)) AS order_value
    FROM order_line
    GROUP BY order_id
),
status_flags AS (
    SELECT oh.order_id,
        COUNT(*) AS history_rows,
        COUNT(DISTINCT os.status_value) AS status_count,
        MAX(CASE WHEN os.status_value = 'Delivered' THEN 1 ELSE 0 END) AS has_delivered,
        MAX(CASE WHEN os.status_value = 'Cancelled' THEN 1 ELSE 0 END) AS has_cancelled,
        MAX(CASE WHEN os.status_value = 'Returned' THEN 1 ELSE 0 END) AS has_returned
    FROM order_history oh
    JOIN order_status os ON oh.status_id = os.status_id
    GROUP BY oh.order_id
),
order_base AS (
    SELECT co.order_id, co.customer_id, c.first_name || ' ' || c.last_name AS customer_name,
        SUBSTR(CAST(co.order_date AS VARCHAR), 1, 7) AS order_month,
        sm.method_name, COALESCE(ov.line_count, 0) AS line_count, COALESCE(ov.book_count, 0) AS book_count,
        COALESCE(ov.order_value, 0) AS order_value,
        COALESCE(sf.status_count, 0) AS status_count,
        COALESCE(sf.has_delivered, 0) AS has_delivered,
        COALESCE(sf.has_cancelled, 0) AS has_cancelled,
        COALESCE(sf.has_returned, 0) AS has_returned,
        CASE
            WHEN COALESCE(sf.has_cancelled, 0) = 1 THEN 'cancelled_path'
            WHEN COALESCE(sf.has_returned, 0) = 1 THEN 'returned_path'
            WHEN COALESCE(sf.has_delivered, 0) = 1 THEN 'delivered_path'
            WHEN COALESCE(sf.status_count, 0) = 0 THEN 'no_history'
            ELSE 'incomplete_or_in_progress'
        END AS lifecycle_bucket
    FROM cust_order co
    JOIN customer c ON co.customer_id = c.customer_id
    LEFT JOIN order_value ov ON co.order_id = ov.order_id
    LEFT JOIN status_flags sf ON co.order_id = sf.order_id
    LEFT JOIN shipping_method sm ON co.shipping_method_id = sm.method_id
),
line_base AS (
    SELECT ob.*, ol.book_id, CAST(ol.price AS DOUBLE) AS line_price, bl.language_name, p.publisher_name
    FROM order_base ob
    LEFT JOIN order_line ol ON ob.order_id = ol.order_id
    LEFT JOIN book b ON ol.book_id = b.book_id
    LEFT JOIN book_language bl ON b.language_id = bl.language_id
    LEFT JOIN publisher p ON b.publisher_id = p.publisher_id
),
customer_metrics AS (
    SELECT c.customer_id, c.first_name || ' ' || c.last_name AS customer_name,
        COUNT(ob.order_id) AS order_count,
        COUNT(DISTINCT ob.order_month) AS active_month_count,
        MIN(ob.order_month) AS first_order_month,
        MAX(ob.order_month) AS last_order_month,
        COALESCE(SUM(ob.line_count), 0) AS line_count,
        COALESCE(SUM(ob.book_count), 0) AS book_count,
        COALESCE(SUM(ob.order_value), 0) AS total_price,
        AVG(ob.order_value) AS avg_order_value,
        SUM(ob.has_delivered) AS delivered_orders,
        SUM(ob.has_cancelled) AS cancelled_orders,
        SUM(ob.has_returned) AS returned_orders,
        CASE
            WHEN COUNT(ob.order_id) >= 10 THEN 'heavy_repeat_customer'
            WHEN COUNT(ob.order_id) >= 3 THEN 'repeat_customer'
            WHEN COUNT(ob.order_id) = 2 THEN 'two_order_customer'
            WHEN COUNT(ob.order_id) = 1 THEN 'single_order_customer'
            ELSE 'no_observed_orders'
        END AS frequency_bucket
    FROM customer c
    LEFT JOIN order_base ob ON c.customer_id = ob.customer_id
    GROUP BY c.customer_id, c.first_name, c.last_name
),
frequency_baseline AS (
    SELECT frequency_bucket AS item, COUNT(*) AS customer_count, SUM(order_count) AS order_count,
        SUM(line_count) AS line_count, SUM(book_count) AS book_count, SUM(total_price) AS total_price,
        SUM(total_price) / NULLIF(SUM(order_count), 0) AS avg_order_value,
        SUM(delivered_orders) AS delivered_orders, SUM(cancelled_orders) AS cancelled_orders, SUM(returned_orders) AS returned_orders
    FROM customer_metrics
    GROUP BY frequency_bucket
),
ranked_frequency AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY total_price DESC, order_count DESC, item) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (), 0) AS share_pct
    FROM frequency_baseline
),
freq_language AS (
    SELECT cm.frequency_bucket AS item, COALESCE(lb.language_name, 'unknown_language') AS item_2,
        COUNT(DISTINCT cm.customer_id) AS customer_count, COUNT(DISTINCT lb.order_id) AS order_count,
        COUNT(*) AS line_count, COUNT(DISTINCT lb.book_id) AS book_count, SUM(lb.line_price) AS total_price, AVG(lb.line_price) AS avg_price
    FROM line_base lb
    JOIN customer_metrics cm ON lb.customer_id = cm.customer_id
    GROUP BY cm.frequency_bucket, COALESCE(lb.language_name, 'unknown_language')
),
ranked_freq_language AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY item ORDER BY total_price DESC, line_count DESC, item_2) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (PARTITION BY item), 0) AS share_pct
    FROM freq_language
),
freq_publisher AS (
    SELECT cm.frequency_bucket AS item, COALESCE(lb.publisher_name, 'unknown_publisher') AS item_2,
        COUNT(DISTINCT cm.customer_id) AS customer_count, COUNT(DISTINCT lb.order_id) AS order_count,
        COUNT(*) AS line_count, COUNT(DISTINCT lb.book_id) AS book_count, SUM(lb.line_price) AS total_price, AVG(lb.line_price) AS avg_price
    FROM line_base lb
    JOIN customer_metrics cm ON lb.customer_id = cm.customer_id
    GROUP BY cm.frequency_bucket, COALESCE(lb.publisher_name, 'unknown_publisher')
),
ranked_freq_publisher AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY item ORDER BY total_price DESC, line_count DESC, item_2) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (PARTITION BY item), 0) AS share_pct
    FROM freq_publisher
),
freq_lifecycle AS (
    SELECT cm.frequency_bucket AS item, ob.lifecycle_bucket AS item_2,
        COUNT(DISTINCT cm.customer_id) AS customer_count, COUNT(*) AS order_count, SUM(ob.line_count) AS line_count,
        SUM(ob.book_count) AS book_count, SUM(ob.order_value) AS total_price, AVG(ob.order_value) AS avg_order_value,
        SUM(ob.has_delivered) AS delivered_orders, SUM(ob.has_cancelled) AS cancelled_orders, SUM(ob.has_returned) AS returned_orders
    FROM order_base ob
    JOIN customer_metrics cm ON ob.customer_id = cm.customer_id
    GROUP BY cm.frequency_bucket, ob.lifecycle_bucket
),
ranked_freq_lifecycle AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY item ORDER BY order_count DESC, total_price DESC, item_2) AS rank_value,
        100.0 * order_count / NULLIF(SUM(order_count) OVER (PARTITION BY item), 0) AS share_pct
    FROM freq_lifecycle
),
freq_shipping AS (
    SELECT cm.frequency_bucket AS item, ob.method_name AS item_2,
        COUNT(DISTINCT cm.customer_id) AS customer_count, COUNT(*) AS order_count, SUM(ob.line_count) AS line_count,
        SUM(ob.book_count) AS book_count, SUM(ob.order_value) AS total_price, AVG(ob.order_value) AS avg_order_value
    FROM order_base ob
    JOIN customer_metrics cm ON ob.customer_id = cm.customer_id
    GROUP BY cm.frequency_bucket, ob.method_name
),
ranked_freq_shipping AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY item ORDER BY total_price DESC, order_count DESC, item_2) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (PARTITION BY item), 0) AS share_pct
    FROM freq_shipping
),
cohort_month AS (
    SELECT first_order_month AS item, frequency_bucket AS item_2, COUNT(*) AS customer_count, SUM(order_count) AS order_count,
        SUM(line_count) AS line_count, SUM(book_count) AS book_count, SUM(total_price) AS total_price, AVG(avg_order_value) AS avg_order_value
    FROM customer_metrics
    WHERE first_order_month IS NOT NULL
    GROUP BY first_order_month, frequency_bucket
),
ranked_cohort AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY total_price DESC, customer_count DESC, item, item_2) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (), 0) AS share_pct
    FROM cohort_month
),
ranked_top_customer AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY total_price DESC, order_count DESC, customer_name) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (), 0) AS share_pct
    FROM customer_metrics
    WHERE order_count > 0
)
SELECT 'customer_frequency_baseline' AS evidence_block, 'frequency_bucket' AS grain, item, CAST(NULL AS VARCHAR) AS item_2, CAST(NULL AS VARCHAR) AS item_3,
    'frequency_value_rank' AS rank_label, CAST(rank_value AS DOUBLE) AS rank_value, customer_count, order_count, line_count, book_count,
    ROUND(total_price, 4) AS total_price, ROUND(avg_order_value, 4) AS avg_order_value, CAST(NULL AS DOUBLE) AS avg_unit_price,
    delivered_orders, cancelled_orders, returned_orders, ROUND(share_pct, 4) AS share_pct, CAST(NULL AS DOUBLE) AS secondary_value,
    'Customer frequency buckets and their demand contribution.' AS notes
FROM ranked_frequency
UNION ALL
SELECT 'frequency_language_mix', 'frequency_language', item, item_2, CAST(NULL AS VARCHAR), 'language_rank_within_frequency', CAST(rank_value AS DOUBLE), customer_count, order_count, line_count, book_count, ROUND(total_price, 4), CAST(NULL AS DOUBLE), ROUND(avg_price, 4), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), ROUND(share_pct, 4), CAST(NULL AS DOUBLE), 'Language mix by customer frequency bucket.' FROM ranked_freq_language WHERE rank_value <= 8
UNION ALL
SELECT 'frequency_publisher_mix', 'frequency_publisher', item, item_2, CAST(NULL AS VARCHAR), 'publisher_rank_within_frequency', CAST(rank_value AS DOUBLE), customer_count, order_count, line_count, book_count, ROUND(total_price, 4), CAST(NULL AS DOUBLE), ROUND(avg_price, 4), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), ROUND(share_pct, 4), CAST(NULL AS DOUBLE), 'Publisher mix by customer frequency bucket.' FROM ranked_freq_publisher WHERE rank_value <= 8
UNION ALL
SELECT 'frequency_lifecycle_mix', 'frequency_lifecycle', item, item_2, CAST(NULL AS VARCHAR), 'lifecycle_rank_within_frequency', CAST(rank_value AS DOUBLE), customer_count, order_count, line_count, book_count, ROUND(total_price, 4), ROUND(avg_order_value, 4), CAST(NULL AS DOUBLE), delivered_orders, cancelled_orders, returned_orders, ROUND(share_pct, 4), CAST(NULL AS DOUBLE), 'Lifecycle outcome mix by customer frequency bucket.' FROM ranked_freq_lifecycle
UNION ALL
SELECT 'frequency_shipping_mix', 'frequency_shipping', item, item_2, CAST(NULL AS VARCHAR), 'shipping_rank_within_frequency', CAST(rank_value AS DOUBLE), customer_count, order_count, line_count, book_count, ROUND(total_price, 4), ROUND(avg_order_value, 4), CAST(NULL AS DOUBLE), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), ROUND(share_pct, 4), CAST(NULL AS DOUBLE), 'Shipping method mix by customer frequency bucket.' FROM ranked_freq_shipping
UNION ALL
SELECT 'customer_cohort_month_profile', 'first_order_month', item, item_2, CAST(NULL AS VARCHAR), 'cohort_value_rank', CAST(rank_value AS DOUBLE), customer_count, order_count, line_count, book_count, ROUND(total_price, 4), ROUND(avg_order_value, 4), CAST(NULL AS DOUBLE), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), ROUND(share_pct, 4), CAST(NULL AS DOUBLE), 'First observed order month profile for customer demand.' FROM ranked_cohort WHERE rank_value <= 40
UNION ALL
SELECT 'top_customer_profile', 'customer', customer_name, CAST(customer_id AS VARCHAR), frequency_bucket, 'customer_value_rank', CAST(rank_value AS DOUBLE), 1 AS customer_count, order_count, line_count, book_count, ROUND(total_price, 4), ROUND(avg_order_value, 4), CAST(NULL AS DOUBLE), delivered_orders, cancelled_orders, returned_orders, ROUND(share_pct, 4), CAST(active_month_count AS DOUBLE), 'Top customers by observed order value and activity depth.' FROM ranked_top_customer WHERE rank_value <= 25
ORDER BY evidence_block, rank_value, item, item_2
