-- task_016_price_concession_margin_tradeoff_evidence.sql
-- Evidence SQL for task_016.
-- Public query: When customers receive lower realized prices, does that appear to buy healthier volume, or mainly compress gross-margin quality?
-- Note: gross_margin_proxy uses priceEach - buyPrice and is not an accounting profit measure.

WITH
line_fact AS (
    SELECT
        o.orderNumber,
        o.customerNumber,
        c.customerName,
        c.country,
        o.orderDate,
        o.status,
        od.productCode,
        p.productName,
        p.productLine,
        p.productScale,
        p.productVendor,
        od.quantityOrdered,
        od.priceEach,
        p.buyPrice,
        p.MSRP,
        od.quantityOrdered * od.priceEach AS revenue,
        od.quantityOrdered * (od.priceEach - p.buyPrice) AS gross_margin_proxy,
        od.quantityOrdered * p.MSRP AS msrp_value,
        od.quantityOrdered * (p.MSRP - od.priceEach) AS msrp_gap_value,
        od.priceEach / NULLIF(p.MSRP, 0) AS line_msrp_realization
    FROM orderdetails AS od
    JOIN orders AS o
      ON od.orderNumber = o.orderNumber
    JOIN customers AS c
      ON o.customerNumber = c.customerNumber
    JOIN products AS p
      ON od.productCode = p.productCode
),
overall AS (
    SELECT
        COUNT(*) AS order_lines,
        COUNT(DISTINCT orderNumber) AS orders,
        COUNT(DISTINCT customerNumber) AS customers,
        COUNT(DISTINCT productCode) AS products,
        SUM(quantityOrdered) AS quantity,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(msrp_value) AS msrp_value,
        SUM(msrp_gap_value) AS msrp_gap_value,
        AVG(quantityOrdered) AS avg_line_quantity
    FROM line_fact
),
price_bucket AS (
    SELECT
        CASE
            WHEN line_msrp_realization >= 0.95 THEN 'near_msrp_95pct_plus'
            WHEN line_msrp_realization >= 0.90 THEN 'moderate_concession_90_95pct'
            WHEN line_msrp_realization >= 0.85 THEN 'deeper_concession_85_90pct'
            ELSE 'deepest_concession_below_85pct'
        END AS price_realization_bucket,
        COUNT(*) AS order_lines,
        COUNT(DISTINCT orderNumber) AS orders,
        COUNT(DISTINCT customerNumber) AS customers,
        COUNT(DISTINCT productCode) AS products,
        SUM(quantityOrdered) AS quantity,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(msrp_value) AS msrp_value,
        SUM(msrp_gap_value) AS msrp_gap_value,
        AVG(quantityOrdered) AS avg_line_quantity,
        ROW_NUMBER() OVER (ORDER BY SUM(revenue) DESC) AS revenue_rank
    FROM line_fact
    GROUP BY price_realization_bucket
),
product_line_price AS (
    SELECT
        productLine,
        COUNT(*) AS order_lines,
        COUNT(DISTINCT orderNumber) AS orders,
        COUNT(DISTINCT customerNumber) AS customers,
        COUNT(DISTINCT productCode) AS products,
        SUM(quantityOrdered) AS quantity,
        SUM(od_revenue) AS revenue,
        SUM(od_gross_margin_proxy) AS gross_margin_proxy,
        SUM(msrp_value) AS msrp_value,
        SUM(msrp_gap_value) AS msrp_gap_value,
        AVG(quantityOrdered) AS avg_line_quantity,
        ROW_NUMBER() OVER (ORDER BY SUM(od_revenue) DESC, productLine) AS revenue_rank,
        ROW_NUMBER() OVER (ORDER BY SUM(od_gross_margin_proxy) / NULLIF(SUM(od_revenue), 0) ASC NULLS LAST, productLine) AS weak_margin_rate_rank
    FROM (
        SELECT
            productLine,
            orderNumber,
            customerNumber,
            productCode,
            quantityOrdered,
            revenue AS od_revenue,
            gross_margin_proxy AS od_gross_margin_proxy,
            msrp_value,
            msrp_gap_value
        FROM line_fact
    ) AS x
    GROUP BY productLine
),
product_pressure AS (
    SELECT
        productName,
        productLine,
        productVendor,
        COUNT(*) AS order_lines,
        COUNT(DISTINCT orderNumber) AS orders,
        COUNT(DISTINCT customerNumber) AS customers,
        SUM(quantityOrdered) AS quantity,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(msrp_value) AS msrp_value,
        SUM(msrp_gap_value) AS msrp_gap_value,
        AVG(quantityOrdered) AS avg_line_quantity,
        ROW_NUMBER() OVER (ORDER BY SUM(revenue) DESC, productName) AS revenue_rank,
        ROW_NUMBER() OVER (ORDER BY SUM(revenue) / NULLIF(SUM(msrp_value), 0) ASC NULLS LAST, SUM(revenue) DESC, productName) AS low_realization_rank
    FROM line_fact
    GROUP BY productName, productLine, productVendor
),
customer_pressure AS (
    SELECT
        customerName,
        country,
        COUNT(*) AS order_lines,
        COUNT(DISTINCT orderNumber) AS orders,
        COUNT(DISTINCT productCode) AS products,
        SUM(quantityOrdered) AS quantity,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(msrp_value) AS msrp_value,
        SUM(msrp_gap_value) AS msrp_gap_value,
        AVG(quantityOrdered) AS avg_line_quantity,
        ROW_NUMBER() OVER (ORDER BY SUM(revenue) DESC, customerName) AS revenue_rank,
        ROW_NUMBER() OVER (ORDER BY SUM(revenue) / NULLIF(SUM(msrp_value), 0) ASC NULLS LAST, SUM(revenue) DESC, customerName) AS low_realization_rank
    FROM line_fact
    GROUP BY customerName, country
)
SELECT
    'overall_price_realization_baseline' AS evidence_block,
    'overall' AS grain,
    'all_order_lines' AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(orders AS BIGINT) AS orders,
    CAST(customers AS BIGINT) AS customers,
    CAST(products AS BIGINT) AS products,
    CAST(quantity AS DOUBLE) AS quantity,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(revenue / NULLIF(msrp_value, 0), 4) AS weighted_msrp_realization,
    ROUND(msrp_gap_value / NULLIF(msrp_value, 0), 4) AS weighted_discount_rate,
    ROUND(avg_line_quantity, 4) AS avg_line_quantity,
    CAST(NULL AS DOUBLE) AS share_value,
    'not_applicable' AS share_label,
    'Start from a price-realization baseline before treating lower realized prices as either growth-positive or margin-negative.' AS notes
FROM overall
UNION ALL
SELECT
    'price_realization_bucket_summary' AS evidence_block,
    'price_realization_bucket' AS grain,
    price_realization_bucket AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    'bucket_revenue_rank' AS rank_label,
    CAST(revenue_rank AS DOUBLE) AS rank_value,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(orders AS BIGINT) AS orders,
    CAST(customers AS BIGINT) AS customers,
    CAST(products AS BIGINT) AS products,
    CAST(quantity AS DOUBLE) AS quantity,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(revenue / NULLIF(msrp_value, 0), 4) AS weighted_msrp_realization,
    ROUND(msrp_gap_value / NULLIF(msrp_value, 0), 4) AS weighted_discount_rate,
    ROUND(avg_line_quantity, 4) AS avg_line_quantity,
    ROUND(revenue / NULLIF(SUM(revenue) OVER (), 0), 4) AS share_value,
    'revenue_share' AS share_label,
    'Compare volume, revenue, and margin proxy across realized-price buckets rather than reading concessions in isolation.' AS notes
FROM price_bucket
UNION ALL
SELECT
    'product_line_price_quality' AS evidence_block,
    'product_line' AS grain,
    productLine AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    'product_line_revenue_rank' AS rank_label,
    CAST(revenue_rank AS DOUBLE) AS rank_value,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(orders AS BIGINT) AS orders,
    CAST(customers AS BIGINT) AS customers,
    CAST(products AS BIGINT) AS products,
    CAST(quantity AS DOUBLE) AS quantity,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(revenue / NULLIF(msrp_value, 0), 4) AS weighted_msrp_realization,
    ROUND(msrp_gap_value / NULLIF(msrp_value, 0), 4) AS weighted_discount_rate,
    ROUND(avg_line_quantity, 4) AS avg_line_quantity,
    ROUND(revenue / NULLIF(SUM(revenue) OVER (), 0), 4) AS share_value,
    'revenue_share' AS share_label,
    'Product-line decomposition identifies whether pricing pressure is broad or concentrated in specific lines.' AS notes
FROM product_line_price
UNION ALL
SELECT
    'product_price_pressure_examples' AS evidence_block,
    'product' AS grain,
    productName AS item,
    productLine AS item_2,
    CASE WHEN revenue_rank <= 15 THEN 'product_revenue_rank' ELSE 'low_realization_rank' END AS rank_label,
    CAST(CASE WHEN revenue_rank <= 15 THEN revenue_rank ELSE low_realization_rank END AS DOUBLE) AS rank_value,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(orders AS BIGINT) AS orders,
    CAST(customers AS BIGINT) AS customers,
    CAST(1 AS BIGINT) AS products,
    CAST(quantity AS DOUBLE) AS quantity,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(revenue / NULLIF(msrp_value, 0), 4) AS weighted_msrp_realization,
    ROUND(msrp_gap_value / NULLIF(msrp_value, 0), 4) AS weighted_discount_rate,
    ROUND(avg_line_quantity, 4) AS avg_line_quantity,
    ROUND(revenue / NULLIF(SUM(revenue) OVER (), 0), 4) AS share_value,
    'selected_product_revenue_share' AS share_label,
    'Selected product rows support whether price pressure is tied to important products or only tail items.' AS notes
FROM product_pressure
WHERE revenue_rank <= 15 OR low_realization_rank <= 15
UNION ALL
SELECT
    'customer_price_pressure_examples' AS evidence_block,
    'customer' AS grain,
    customerName AS item,
    country AS item_2,
    CASE WHEN revenue_rank <= 15 THEN 'customer_revenue_rank' ELSE 'low_realization_rank' END AS rank_label,
    CAST(CASE WHEN revenue_rank <= 15 THEN revenue_rank ELSE low_realization_rank END AS DOUBLE) AS rank_value,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(orders AS BIGINT) AS orders,
    CAST(1 AS BIGINT) AS customers,
    CAST(products AS BIGINT) AS products,
    CAST(quantity AS DOUBLE) AS quantity,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(revenue / NULLIF(msrp_value, 0), 4) AS weighted_msrp_realization,
    ROUND(msrp_gap_value / NULLIF(msrp_value, 0), 4) AS weighted_discount_rate,
    ROUND(avg_line_quantity, 4) AS avg_line_quantity,
    ROUND(revenue / NULLIF(SUM(revenue) OVER (), 0), 4) AS share_value,
    'selected_customer_revenue_share' AS share_label,
    'Customer-level rows show whether concessions are attached to strategically important demand or scattered accounts.' AS notes
FROM customer_pressure
WHERE revenue_rank <= 15 OR low_realization_rank <= 15;
