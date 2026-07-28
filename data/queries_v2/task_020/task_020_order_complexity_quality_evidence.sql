-- task_020_order_complexity_quality_evidence.sql
-- Evidence SQL for task_020.
-- Public query: Do more complex orders create better business quality, or can multi-product and multi-line orders hide pricing, margin, or fulfillment risk?
-- Note: gross_margin_proxy uses priceEach - buyPrice and is not an accounting profit measure.

WITH
order_lines AS (
    SELECT
        o.orderNumber,
        o.customerNumber,
        c.customerName,
        c.country,
        o.orderDate,
        o.requiredDate,
        o.shippedDate,
        o.status,
        od.productCode,
        p.productLine,
        p.productScale,
        od.quantityOrdered,
        od.priceEach,
        p.buyPrice,
        p.MSRP,
        od.quantityOrdered * od.priceEach AS revenue,
        od.quantityOrdered * (od.priceEach - p.buyPrice) AS gross_margin_proxy,
        od.quantityOrdered * p.MSRP AS msrp_value
    FROM orders AS o
    JOIN customers AS c
      ON o.customerNumber = c.customerNumber
    JOIN orderdetails AS od
      ON o.orderNumber = od.orderNumber
    JOIN products AS p
      ON od.productCode = p.productCode
),
order_value AS (
    SELECT
        orderNumber,
        customerNumber,
        customerName,
        country,
        orderDate,
        requiredDate,
        shippedDate,
        status,
        COUNT(*) AS line_count,
        COUNT(DISTINCT productCode) AS products,
        COUNT(DISTINCT productLine) AS product_lines,
        COUNT(DISTINCT productScale) AS product_scales,
        SUM(quantityOrdered) AS quantity,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(msrp_value) AS msrp_value,
        CASE WHEN shippedDate IS NULL THEN NULL ELSE date_diff('day', orderDate, shippedDate) END AS days_to_ship,
        CASE
            WHEN shippedDate IS NULL THEN 'not_shipped_or_missing_date'
            WHEN shippedDate <= requiredDate THEN 'shipped_on_or_before_required'
            ELSE 'shipped_after_required'
        END AS timeliness_group
    FROM order_lines
    GROUP BY orderNumber, customerNumber, customerName, country, orderDate, requiredDate, shippedDate, status
),
order_classified AS (
    SELECT
        *,
        CASE
            WHEN line_count <= 3 THEN '1-3 lines'
            WHEN line_count <= 6 THEN '4-6 lines'
            WHEN line_count <= 10 THEN '7-10 lines'
            ELSE '11+ lines'
        END AS line_count_bucket,
        CASE
            WHEN product_lines = 1 THEN 'single_product_line'
            WHEN product_lines = 2 THEN 'two_product_lines'
            ELSE 'three_plus_product_lines'
        END AS product_line_count_bucket,
        gross_margin_proxy / NULLIF(revenue, 0) AS gross_margin_rate,
        revenue / NULLIF(msrp_value, 0) AS weighted_msrp_realization,
        ROW_NUMBER() OVER (ORDER BY line_count DESC, revenue DESC, orderNumber) AS complexity_rank,
        ROW_NUMBER() OVER (ORDER BY revenue DESC, orderNumber) AS revenue_rank,
        ROW_NUMBER() OVER (ORDER BY gross_margin_proxy / NULLIF(revenue, 0) ASC NULLS LAST, revenue DESC, orderNumber) AS weak_margin_rank
    FROM order_value
),
line_bucket_summary AS (
    SELECT
        line_count_bucket,
        COUNT(*) AS orders,
        COUNT(DISTINCT customerNumber) AS customers,
        SUM(line_count) AS order_lines,
        SUM(products) AS products,
        SUM(product_lines) AS product_lines,
        SUM(quantity) AS quantity,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(msrp_value) AS msrp_value,
        AVG(days_to_ship) AS avg_days_to_ship,
        SUM(CASE WHEN timeliness_group = 'shipped_after_required' THEN 1 ELSE 0 END) AS late_orders,
        SUM(CASE WHEN status <> 'Shipped' THEN 1 ELSE 0 END) AS non_shipped_orders,
        ROW_NUMBER() OVER (ORDER BY SUM(revenue) DESC, line_count_bucket) AS revenue_rank
    FROM order_classified
    GROUP BY line_count_bucket
),
product_line_count_summary AS (
    SELECT
        product_line_count_bucket,
        COUNT(*) AS orders,
        COUNT(DISTINCT customerNumber) AS customers,
        SUM(line_count) AS order_lines,
        SUM(products) AS products,
        SUM(product_lines) AS product_lines,
        SUM(quantity) AS quantity,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(msrp_value) AS msrp_value,
        AVG(days_to_ship) AS avg_days_to_ship,
        SUM(CASE WHEN timeliness_group = 'shipped_after_required' THEN 1 ELSE 0 END) AS late_orders,
        SUM(CASE WHEN status <> 'Shipped' THEN 1 ELSE 0 END) AS non_shipped_orders,
        ROW_NUMBER() OVER (ORDER BY SUM(revenue) DESC, product_line_count_bucket) AS revenue_rank
    FROM order_classified
    GROUP BY product_line_count_bucket
),
status_complexity AS (
    SELECT
        status,
        line_count_bucket,
        COUNT(*) AS orders,
        COUNT(DISTINCT customerNumber) AS customers,
        SUM(line_count) AS order_lines,
        SUM(products) AS products,
        SUM(product_lines) AS product_lines,
        SUM(quantity) AS quantity,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(msrp_value) AS msrp_value,
        AVG(days_to_ship) AS avg_days_to_ship,
        SUM(CASE WHEN timeliness_group = 'shipped_after_required' THEN 1 ELSE 0 END) AS late_orders,
        SUM(CASE WHEN status <> 'Shipped' THEN 1 ELSE 0 END) AS non_shipped_orders,
        ROW_NUMBER() OVER (PARTITION BY status ORDER BY SUM(revenue) DESC, line_count_bucket) AS bucket_rank_in_status
    FROM order_classified
    GROUP BY status, line_count_bucket
),
customer_complexity AS (
    SELECT
        customerName,
        country,
        COUNT(*) AS orders,
        AVG(line_count) AS avg_line_count,
        AVG(product_lines) AS avg_product_lines,
        SUM(line_count) AS order_lines,
        SUM(products) AS products,
        SUM(product_lines) AS product_lines,
        SUM(quantity) AS quantity,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(msrp_value) AS msrp_value,
        AVG(days_to_ship) AS avg_days_to_ship,
        SUM(CASE WHEN timeliness_group = 'shipped_after_required' THEN 1 ELSE 0 END) AS late_orders,
        SUM(CASE WHEN status <> 'Shipped' THEN 1 ELSE 0 END) AS non_shipped_orders,
        ROW_NUMBER() OVER (ORDER BY AVG(line_count) DESC, SUM(revenue) DESC, customerName) AS complexity_rank,
        ROW_NUMBER() OVER (ORDER BY SUM(revenue) DESC, customerName) AS revenue_rank
    FROM order_classified
    GROUP BY customerName, country
)
SELECT
    'line_count_complexity_summary' AS evidence_block,
    'line_count_bucket' AS grain,
    line_count_bucket AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    'bucket_revenue_rank' AS rank_label,
    CAST(revenue_rank AS DOUBLE) AS rank_value,
    CAST(orders AS BIGINT) AS orders,
    CAST(customers AS BIGINT) AS customers,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(products AS BIGINT) AS products,
    CAST(product_lines AS BIGINT) AS product_lines,
    CAST(quantity AS DOUBLE) AS quantity,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(revenue / NULLIF(msrp_value, 0), 4) AS weighted_msrp_realization,
    ROUND(avg_days_to_ship, 4) AS avg_days_to_ship,
    CAST(late_orders AS BIGINT) AS late_orders,
    CAST(non_shipped_orders AS BIGINT) AS non_shipped_orders,
    ROUND(revenue / NULLIF(SUM(revenue) OVER (), 0), 4) AS share_value,
    'revenue_share' AS share_label,
    'Line-count buckets test whether larger orders actually carry stronger margin and fulfillment quality.' AS notes
FROM line_bucket_summary
UNION ALL
SELECT
    'product_line_count_summary' AS evidence_block,
    'product_line_count_bucket' AS grain,
    product_line_count_bucket AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    'bucket_revenue_rank' AS rank_label,
    CAST(revenue_rank AS DOUBLE) AS rank_value,
    CAST(orders AS BIGINT) AS orders,
    CAST(customers AS BIGINT) AS customers,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(products AS BIGINT) AS products,
    CAST(product_lines AS BIGINT) AS product_lines,
    CAST(quantity AS DOUBLE) AS quantity,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(revenue / NULLIF(msrp_value, 0), 4) AS weighted_msrp_realization,
    ROUND(avg_days_to_ship, 4) AS avg_days_to_ship,
    CAST(late_orders AS BIGINT) AS late_orders,
    CAST(non_shipped_orders AS BIGINT) AS non_shipped_orders,
    ROUND(revenue / NULLIF(SUM(revenue) OVER (), 0), 4) AS share_value,
    'revenue_share' AS share_label,
    'Product-line count distinguishes multi-line breadth from simple order size.' AS notes
FROM product_line_count_summary
UNION ALL
SELECT
    'complex_order_examples' AS evidence_block,
    'order' AS grain,
    CAST(orderNumber AS VARCHAR) AS item,
    customerName AS item_2,
    CASE WHEN complexity_rank <= 20 THEN 'order_complexity_rank' ELSE 'weak_margin_rank' END AS rank_label,
    CAST(CASE WHEN complexity_rank <= 20 THEN complexity_rank ELSE weak_margin_rank END AS DOUBLE) AS rank_value,
    CAST(1 AS BIGINT) AS orders,
    CAST(1 AS BIGINT) AS customers,
    CAST(line_count AS BIGINT) AS order_lines,
    CAST(products AS BIGINT) AS products,
    CAST(product_lines AS BIGINT) AS product_lines,
    CAST(quantity AS DOUBLE) AS quantity,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_rate, 4) AS gross_margin_rate,
    ROUND(weighted_msrp_realization, 4) AS weighted_msrp_realization,
    ROUND(days_to_ship, 4) AS avg_days_to_ship,
    CAST(CASE WHEN timeliness_group = 'shipped_after_required' THEN 1 ELSE 0 END AS BIGINT) AS late_orders,
    CAST(CASE WHEN status <> 'Shipped' THEN 1 ELSE 0 END AS BIGINT) AS non_shipped_orders,
    ROUND(revenue / NULLIF(SUM(revenue) OVER (), 0), 4) AS share_value,
    'selected_order_revenue_share' AS share_label,
    'Order examples connect complexity to specific margin, pricing, and fulfillment outcomes.' AS notes
FROM order_classified
WHERE complexity_rank <= 20 OR weak_margin_rank <= 20 OR revenue_rank <= 20
UNION ALL
SELECT
    'customer_complexity_exposure' AS evidence_block,
    'customer' AS grain,
    customerName AS item,
    country AS item_2,
    CASE WHEN complexity_rank <= 20 THEN 'customer_complexity_rank' ELSE 'customer_revenue_rank' END AS rank_label,
    CAST(CASE WHEN complexity_rank <= 20 THEN complexity_rank ELSE revenue_rank END AS DOUBLE) AS rank_value,
    CAST(orders AS BIGINT) AS orders,
    CAST(1 AS BIGINT) AS customers,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(products AS BIGINT) AS products,
    CAST(product_lines AS BIGINT) AS product_lines,
    CAST(quantity AS DOUBLE) AS quantity,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(revenue / NULLIF(msrp_value, 0), 4) AS weighted_msrp_realization,
    ROUND(avg_days_to_ship, 4) AS avg_days_to_ship,
    CAST(late_orders AS BIGINT) AS late_orders,
    CAST(non_shipped_orders AS BIGINT) AS non_shipped_orders,
    ROUND(revenue / NULLIF(SUM(revenue) OVER (), 0), 4) AS share_value,
    'selected_customer_revenue_share' AS share_label,
    'Customer complexity rows prevent broad order-level patterns from hiding account-level concentration.' AS notes
FROM customer_complexity
WHERE complexity_rank <= 20 OR revenue_rank <= 20
UNION ALL
SELECT
    'status_complexity_mix' AS evidence_block,
    'status_line_bucket' AS grain,
    status AS item,
    line_count_bucket AS item_2,
    'bucket_rank_in_status' AS rank_label,
    CAST(bucket_rank_in_status AS DOUBLE) AS rank_value,
    CAST(orders AS BIGINT) AS orders,
    CAST(customers AS BIGINT) AS customers,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(products AS BIGINT) AS products,
    CAST(product_lines AS BIGINT) AS product_lines,
    CAST(quantity AS DOUBLE) AS quantity,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(revenue / NULLIF(msrp_value, 0), 4) AS weighted_msrp_realization,
    ROUND(avg_days_to_ship, 4) AS avg_days_to_ship,
    CAST(late_orders AS BIGINT) AS late_orders,
    CAST(non_shipped_orders AS BIGINT) AS non_shipped_orders,
    ROUND(revenue / NULLIF(SUM(revenue) OVER (PARTITION BY status), 0), 4) AS share_value,
    'status_revenue_share' AS share_label,
    'Status by complexity checks whether abnormal fulfillment is tied to order structure.' AS notes
FROM status_complexity
WHERE bucket_rank_in_status <= 3;
