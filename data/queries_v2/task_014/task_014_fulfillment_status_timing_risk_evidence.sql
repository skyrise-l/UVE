-- task_014_fulfillment_status_timing_risk_evidence.sql
-- Evidence SQL for task_014.
-- Public query: Are order fulfillment risks concentrated in specific statuses, markets, customers, or product lines rather than being a uniform shipping problem?

WITH
order_value AS (
    SELECT
        o.orderNumber,
        o.customerNumber,
        c.customerName,
        c.country,
        c.city,
        o.orderDate,
        o.requiredDate,
        o.shippedDate,
        o.status,
        COUNT(*) AS order_lines,
        COUNT(DISTINCT od.productCode) AS products,
        SUM(od.quantityOrdered) AS quantity,
        SUM(od.quantityOrdered * od.priceEach) AS revenue,
        SUM(od.quantityOrdered * (od.priceEach - p.buyPrice)) AS gross_margin_proxy,
        CASE WHEN o.shippedDate IS NULL THEN NULL ELSE date_diff('day', o.orderDate, o.shippedDate) END AS days_to_ship,
        CASE WHEN o.shippedDate IS NULL THEN NULL ELSE date_diff('day', o.shippedDate, o.requiredDate) END AS days_before_required,
        CASE
            WHEN o.shippedDate IS NULL THEN 'not_shipped_or_missing_date'
            WHEN o.shippedDate <= o.requiredDate THEN 'shipped_on_or_before_required'
            ELSE 'shipped_after_required'
        END AS timeliness_group
    FROM orders AS o
    JOIN customers AS c
      ON o.customerNumber = c.customerNumber
    JOIN orderdetails AS od
      ON o.orderNumber = od.orderNumber
    JOIN products AS p
      ON od.productCode = p.productCode
    GROUP BY o.orderNumber, o.customerNumber, c.customerName, c.country, c.city,
             o.orderDate, o.requiredDate, o.shippedDate, o.status
),
status_summary AS (
    SELECT
        status,
        COUNT(*) AS orders,
        COUNT(DISTINCT customerNumber) AS customers,
        SUM(order_lines) AS order_lines,
        SUM(products) AS products,
        SUM(quantity) AS quantity,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        AVG(days_to_ship) AS avg_days_to_ship,
        AVG(days_before_required) AS avg_days_before_required,
        SUM(CASE WHEN timeliness_group = 'shipped_after_required' THEN 1 ELSE 0 END) AS late_orders,
        ROW_NUMBER() OVER (ORDER BY SUM(revenue) DESC, status) AS revenue_rank
    FROM order_value
    GROUP BY status
),
timeliness_summary AS (
    SELECT
        timeliness_group,
        COUNT(*) AS orders,
        COUNT(DISTINCT customerNumber) AS customers,
        SUM(order_lines) AS order_lines,
        SUM(products) AS products,
        SUM(quantity) AS quantity,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        AVG(days_to_ship) AS avg_days_to_ship,
        AVG(days_before_required) AS avg_days_before_required,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, timeliness_group) AS order_count_rank
    FROM order_value
    GROUP BY timeliness_group
),
ship_duration_bucket AS (
    SELECT
        CASE
            WHEN days_to_ship IS NULL THEN 'not_shipped_or_missing_date'
            WHEN days_to_ship <= 2 THEN '0-2 days_to_ship'
            WHEN days_to_ship <= 5 THEN '3-5 days_to_ship'
            WHEN days_to_ship <= 10 THEN '6-10 days_to_ship'
            ELSE '11+ days_to_ship'
        END AS ship_duration_bucket,
        COUNT(*) AS orders,
        COUNT(DISTINCT customerNumber) AS customers,
        SUM(order_lines) AS order_lines,
        SUM(products) AS products,
        SUM(quantity) AS quantity,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        AVG(days_to_ship) AS avg_days_to_ship,
        AVG(days_before_required) AS avg_days_before_required,
        SUM(CASE WHEN timeliness_group = 'shipped_after_required' THEN 1 ELSE 0 END) AS late_orders
    FROM order_value
    GROUP BY ship_duration_bucket
),
country_fulfillment AS (
    SELECT
        country,
        COUNT(*) AS orders,
        COUNT(DISTINCT customerNumber) AS customers,
        SUM(order_lines) AS order_lines,
        SUM(products) AS products,
        SUM(quantity) AS quantity,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        AVG(days_to_ship) AS avg_days_to_ship,
        SUM(CASE WHEN timeliness_group = 'shipped_after_required' THEN 1 ELSE 0 END) AS late_orders,
        SUM(CASE WHEN status <> 'Shipped' THEN 1 ELSE 0 END) AS non_shipped_status_orders,
        ROW_NUMBER() OVER (ORDER BY SUM(revenue) DESC, country) AS revenue_rank,
        ROW_NUMBER() OVER (ORDER BY SUM(CASE WHEN status <> 'Shipped' THEN 1 ELSE 0 END) DESC, SUM(revenue) DESC) AS abnormal_status_rank
    FROM order_value
    GROUP BY country
),
customer_fulfillment AS (
    SELECT
        customerName,
        country,
        COUNT(*) AS orders,
        SUM(order_lines) AS order_lines,
        SUM(products) AS products,
        SUM(quantity) AS quantity,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        AVG(days_to_ship) AS avg_days_to_ship,
        SUM(CASE WHEN timeliness_group = 'shipped_after_required' THEN 1 ELSE 0 END) AS late_orders,
        SUM(CASE WHEN status <> 'Shipped' THEN 1 ELSE 0 END) AS non_shipped_status_orders,
        ROW_NUMBER() OVER (ORDER BY SUM(CASE WHEN status <> 'Shipped' THEN 1 ELSE 0 END) DESC, SUM(revenue) DESC, customerName) AS abnormal_customer_rank,
        ROW_NUMBER() OVER (ORDER BY SUM(revenue) DESC, customerName) AS revenue_rank
    FROM order_value
    GROUP BY customerName, country
),
productline_fulfillment AS (
    SELECT
        p.productLine,
        ov.status,
        ov.timeliness_group,
        COUNT(DISTINCT ov.orderNumber) AS orders,
        COUNT(*) AS order_lines,
        COUNT(DISTINCT ov.customerNumber) AS customers,
        SUM(od.quantityOrdered) AS quantity,
        SUM(od.quantityOrdered * od.priceEach) AS revenue,
        SUM(od.quantityOrdered * (od.priceEach - p.buyPrice)) AS gross_margin_proxy,
        AVG(ov.days_to_ship) AS avg_days_to_ship,
        SUM(CASE WHEN ov.timeliness_group = 'shipped_after_required' THEN 1 ELSE 0 END) AS late_order_lines,
        ROW_NUMBER() OVER (PARTITION BY p.productLine ORDER BY SUM(od.quantityOrdered * od.priceEach) DESC, ov.status, ov.timeliness_group) AS line_status_rank
    FROM order_value AS ov
    JOIN orderdetails AS od
      ON ov.orderNumber = od.orderNumber
    JOIN products AS p
      ON od.productCode = p.productCode
    GROUP BY p.productLine, ov.status, ov.timeliness_group
)
SELECT
    'status_baseline' AS evidence_block,
    'order_status' AS grain,
    status AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    'status_revenue_rank' AS rank_label,
    CAST(revenue_rank AS DOUBLE) AS rank_value,
    CAST(orders AS BIGINT) AS orders,
    CAST(customers AS BIGINT) AS customers,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(products AS BIGINT) AS products,
    CAST(quantity AS DOUBLE) AS quantity,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(avg_days_to_ship, 4) AS avg_days_to_ship,
    ROUND(avg_days_before_required, 4) AS avg_days_before_required,
    'late_orders' AS extra_metric_1,
    CAST(late_orders AS DOUBLE) AS extra_value_1,
    'status mix should be checked before assuming all orders are normal shipped orders' AS notes
FROM status_summary
UNION ALL
SELECT
    'timeliness_baseline' AS evidence_block,
    'timeliness_group' AS grain,
    timeliness_group AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    'timeliness_order_count_rank' AS rank_label,
    CAST(order_count_rank AS DOUBLE) AS rank_value,
    CAST(orders AS BIGINT) AS orders,
    CAST(customers AS BIGINT) AS customers,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(products AS BIGINT) AS products,
    CAST(quantity AS DOUBLE) AS quantity,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(avg_days_to_ship, 4) AS avg_days_to_ship,
    ROUND(avg_days_before_required, 4) AS avg_days_before_required,
    'orders' AS extra_metric_1,
    CAST(orders AS DOUBLE) AS extra_value_1,
    'Timeliness compares shippedDate to requiredDate and should not be confused with days-to-ship.' AS notes
FROM timeliness_summary
UNION ALL
SELECT
    'ship_duration_bucket' AS evidence_block,
    'ship_duration_bucket' AS grain,
    ship_duration_bucket AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    CAST(orders AS BIGINT) AS orders,
    CAST(customers AS BIGINT) AS customers,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(products AS BIGINT) AS products,
    CAST(quantity AS DOUBLE) AS quantity,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(avg_days_to_ship, 4) AS avg_days_to_ship,
    ROUND(avg_days_before_required, 4) AS avg_days_before_required,
    'late_orders' AS extra_metric_1,
    CAST(late_orders AS DOUBLE) AS extra_value_1,
    'Days-to-ship buckets explain shipping speed separately from required-date lateness.' AS notes
FROM ship_duration_bucket
UNION ALL
SELECT
    'country_fulfillment_risk' AS evidence_block,
    'country' AS grain,
    country AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    'country_revenue_rank' AS rank_label,
    CAST(revenue_rank AS DOUBLE) AS rank_value,
    CAST(orders AS BIGINT) AS orders,
    CAST(customers AS BIGINT) AS customers,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(products AS BIGINT) AS products,
    CAST(quantity AS DOUBLE) AS quantity,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(avg_days_to_ship, 4) AS avg_days_to_ship,
    CAST(NULL AS DOUBLE) AS avg_days_before_required,
    'non_shipped_status_orders' AS extra_metric_1,
    CAST(non_shipped_status_orders AS DOUBLE) AS extra_value_1,
    'Country-level risk checks whether abnormal status or delay is market-concentrated.' AS notes
FROM country_fulfillment
UNION ALL
SELECT
    'customer_fulfillment_risk' AS evidence_block,
    'customer' AS grain,
    customerName AS item,
    country AS item_2,
    'abnormal_customer_rank' AS rank_label,
    CAST(abnormal_customer_rank AS DOUBLE) AS rank_value,
    CAST(orders AS BIGINT) AS orders,
    CAST(NULL AS BIGINT) AS customers,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(products AS BIGINT) AS products,
    CAST(quantity AS DOUBLE) AS quantity,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(avg_days_to_ship, 4) AS avg_days_to_ship,
    CAST(NULL AS DOUBLE) AS avg_days_before_required,
    'non_shipped_status_orders' AS extra_metric_1,
    CAST(non_shipped_status_orders AS DOUBLE) AS extra_value_1,
    'Customer-level view identifies whether fulfillment risk is concentrated in particular accounts.' AS notes
FROM customer_fulfillment
WHERE abnormal_customer_rank <= 20 OR revenue_rank <= 20
UNION ALL
SELECT
    'productline_fulfillment_mix' AS evidence_block,
    'product_line_status_timeliness' AS grain,
    productLine AS item,
    status || ' / ' || timeliness_group AS item_2,
    'line_status_rank' AS rank_label,
    CAST(line_status_rank AS DOUBLE) AS rank_value,
    CAST(orders AS BIGINT) AS orders,
    CAST(customers AS BIGINT) AS customers,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(NULL AS BIGINT) AS products,
    CAST(quantity AS DOUBLE) AS quantity,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(avg_days_to_ship, 4) AS avg_days_to_ship,
    CAST(NULL AS DOUBLE) AS avg_days_before_required,
    'late_order_lines' AS extra_metric_1,
    CAST(late_order_lines AS DOUBLE) AS extra_value_1,
    'Product-line mix shows whether delayed or abnormal fulfillment is attached to particular merchandise groups.' AS notes
FROM productline_fulfillment
WHERE line_status_rank <= 5;
