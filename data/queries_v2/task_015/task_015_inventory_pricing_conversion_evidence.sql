-- task_015_inventory_pricing_conversion_evidence.sql
-- Evidence SQL for task_015.
-- Public query: Which products have inventory or pricing patterns that do not match actual sales conversion quality?
-- Note: stock-turn and margin metrics are proxies based on available order and product fields.

WITH
product_sales AS (
    SELECT
        p.productCode,
        p.productName,
        p.productLine,
        p.productScale,
        p.productVendor,
        p.quantityInStock,
        p.buyPrice,
        p.MSRP,
        COUNT(DISTINCT od.orderNumber) AS orders,
        COUNT(od.orderNumber) AS order_lines,
        COUNT(DISTINCT o.customerNumber) AS customers,
        COALESCE(SUM(od.quantityOrdered), 0) AS quantity_ordered,
        COALESCE(SUM(od.quantityOrdered * od.priceEach), 0) AS revenue,
        COALESCE(SUM(od.quantityOrdered * (od.priceEach - p.buyPrice)), 0) AS gross_margin_proxy,
        COALESCE(SUM(od.quantityOrdered * (p.MSRP - od.priceEach)), 0) AS msrp_gap_value,
        AVG(od.priceEach) AS avg_price_each,
        MIN(od.priceEach) AS min_price_each,
        MAX(od.priceEach) AS max_price_each
    FROM products AS p
    LEFT JOIN orderdetails AS od
      ON p.productCode = od.productCode
    LEFT JOIN orders AS o
      ON od.orderNumber = o.orderNumber
    GROUP BY p.productCode, p.productName, p.productLine, p.productScale, p.productVendor,
             p.quantityInStock, p.buyPrice, p.MSRP
),
product_metrics AS (
    SELECT
        *,
        gross_margin_proxy / NULLIF(revenue, 0) AS gross_margin_rate,
        quantity_ordered / NULLIF(quantityInStock, 0) AS stock_turn_proxy,
        revenue / NULLIF(quantityInStock, 0) AS revenue_per_stock_unit,
        avg_price_each / NULLIF(MSRP, 0) AS avg_msrp_realization,
        (avg_price_each - buyPrice) / NULLIF(buyPrice, 0) AS avg_markup_vs_buy_price,
        ROW_NUMBER() OVER (ORDER BY revenue DESC, productName) AS revenue_rank,
        ROW_NUMBER() OVER (ORDER BY quantityInStock DESC, productName) AS stock_rank,
        ROW_NUMBER() OVER (ORDER BY quantity_ordered / NULLIF(quantityInStock, 0) ASC NULLS FIRST, quantityInStock DESC) AS low_turn_rank,
        ROW_NUMBER() OVER (ORDER BY quantity_ordered / NULLIF(quantityInStock, 0) DESC NULLS LAST, revenue DESC) AS high_turn_rank,
        ROW_NUMBER() OVER (ORDER BY (avg_price_each - buyPrice) / NULLIF(buyPrice, 0) ASC NULLS FIRST, revenue DESC) AS weak_markup_rank
    FROM product_sales
),
product_line_raw AS (
    SELECT
        productLine,
        COUNT(*) AS products,
        SUM(quantityInStock) AS stock_quantity,
        SUM(quantity_ordered) AS quantity_ordered,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(msrp_gap_value) AS msrp_gap_value,
        AVG(avg_msrp_realization) AS avg_msrp_realization,
        AVG(avg_markup_vs_buy_price) AS avg_markup_vs_buy_price,
        SUM(quantity_ordered) / NULLIF(SUM(quantityInStock), 0) AS stock_turn_proxy,
        ROW_NUMBER() OVER (ORDER BY SUM(revenue) DESC, productLine) AS revenue_rank,
        ROW_NUMBER() OVER (ORDER BY SUM(quantity_ordered) / NULLIF(SUM(quantityInStock), 0) ASC NULLS LAST, SUM(quantityInStock) DESC) AS low_turn_rank
    FROM product_metrics
    GROUP BY productLine
),
vendor_raw AS (
    SELECT
        productVendor,
        COUNT(*) AS products,
        SUM(quantityInStock) AS stock_quantity,
        SUM(quantity_ordered) AS quantity_ordered,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        AVG(avg_msrp_realization) AS avg_msrp_realization,
        AVG(avg_markup_vs_buy_price) AS avg_markup_vs_buy_price,
        SUM(quantity_ordered) / NULLIF(SUM(quantityInStock), 0) AS stock_turn_proxy,
        ROW_NUMBER() OVER (ORDER BY SUM(revenue) DESC, productVendor) AS revenue_rank,
        ROW_NUMBER() OVER (ORDER BY SUM(quantityInStock) DESC, productVendor) AS stock_rank
    FROM product_metrics
    GROUP BY productVendor
),
stock_bucket AS (
    SELECT
        CASE
            WHEN orders = 0 THEN 'never_observed_in_orders'
            WHEN stock_turn_proxy IS NULL THEN 'stock_turn_unknown'
            WHEN stock_turn_proxy < 0.02 THEN 'very_low_stock_turn_proxy'
            WHEN stock_turn_proxy < 0.05 THEN 'low_stock_turn_proxy'
            WHEN stock_turn_proxy < 0.10 THEN 'mid_stock_turn_proxy'
            ELSE 'higher_stock_turn_proxy'
        END AS stock_conversion_bucket,
        COUNT(*) AS products,
        SUM(quantityInStock) AS stock_quantity,
        SUM(quantity_ordered) AS quantity_ordered,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        AVG(stock_turn_proxy) AS avg_stock_turn_proxy,
        AVG(avg_msrp_realization) AS avg_msrp_realization,
        AVG(avg_markup_vs_buy_price) AS avg_markup_vs_buy_price
    FROM product_metrics
    GROUP BY stock_conversion_bucket
),
price_risk_products AS (
    SELECT *
    FROM product_metrics
    WHERE revenue > 0
      AND (avg_markup_vs_buy_price IS NULL OR avg_markup_vs_buy_price < 0.20 OR avg_msrp_realization < 0.80)
)
SELECT
    'product_line_inventory_baseline' AS evidence_block,
    'product_line' AS grain,
    productLine AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    'product_line_revenue_rank' AS rank_label,
    CAST(revenue_rank AS DOUBLE) AS rank_value,
    CAST(products AS BIGINT) AS products,
    CAST(stock_quantity AS DOUBLE) AS stock_quantity,
    CAST(quantity_ordered AS DOUBLE) AS quantity_ordered,
    ROUND(stock_turn_proxy, 4) AS stock_turn_proxy,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(avg_msrp_realization, 4) AS avg_msrp_realization,
    ROUND(avg_markup_vs_buy_price, 4) AS avg_markup_vs_buy_price,
    'low_turn_rank' AS extra_metric_1,
    CAST(low_turn_rank AS DOUBLE) AS extra_value_1,
    'Product-line baseline compares stock, observed demand, revenue, and proxy margin quality.' AS notes
FROM product_line_raw
UNION ALL
SELECT
    'product_inventory_conversion' AS evidence_block,
    'product' AS grain,
    productName AS item,
    productLine AS item_2,
    'product_revenue_rank' AS rank_label,
    CAST(revenue_rank AS DOUBLE) AS rank_value,
    CAST(1 AS BIGINT) AS products,
    CAST(quantityInStock AS DOUBLE) AS stock_quantity,
    CAST(quantity_ordered AS DOUBLE) AS quantity_ordered,
    ROUND(stock_turn_proxy, 4) AS stock_turn_proxy,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_rate, 4) AS gross_margin_rate,
    ROUND(avg_msrp_realization, 4) AS avg_msrp_realization,
    ROUND(avg_markup_vs_buy_price, 4) AS avg_markup_vs_buy_price,
    'stock_rank' AS extra_metric_1,
    CAST(stock_rank AS DOUBLE) AS extra_value_1,
    'Product-level evidence separates high stock, high demand, and healthy pricing conversion.' AS notes
FROM product_metrics
WHERE revenue_rank <= 20 OR stock_rank <= 20 OR low_turn_rank <= 20 OR high_turn_rank <= 20
UNION ALL
SELECT
    'stock_conversion_bucket' AS evidence_block,
    'stock_conversion_bucket' AS grain,
    stock_conversion_bucket AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    CAST(products AS BIGINT) AS products,
    CAST(stock_quantity AS DOUBLE) AS stock_quantity,
    CAST(quantity_ordered AS DOUBLE) AS quantity_ordered,
    ROUND(avg_stock_turn_proxy, 4) AS stock_turn_proxy,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(avg_msrp_realization, 4) AS avg_msrp_realization,
    ROUND(avg_markup_vs_buy_price, 4) AS avg_markup_vs_buy_price,
    'products' AS extra_metric_1,
    CAST(products AS DOUBLE) AS extra_value_1,
    'Stock conversion buckets prevent over-focusing on individual products.' AS notes
FROM stock_bucket
UNION ALL
SELECT
    'price_realization_risk' AS evidence_block,
    'product' AS grain,
    productName AS item,
    productLine AS item_2,
    'weak_markup_rank' AS rank_label,
    CAST(weak_markup_rank AS DOUBLE) AS rank_value,
    CAST(1 AS BIGINT) AS products,
    CAST(quantityInStock AS DOUBLE) AS stock_quantity,
    CAST(quantity_ordered AS DOUBLE) AS quantity_ordered,
    ROUND(stock_turn_proxy, 4) AS stock_turn_proxy,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_rate, 4) AS gross_margin_rate,
    ROUND(avg_msrp_realization, 4) AS avg_msrp_realization,
    ROUND(avg_markup_vs_buy_price, 4) AS avg_markup_vs_buy_price,
    'buy_price' AS extra_metric_1,
    ROUND(buyPrice, 4) AS extra_value_1,
    'Weak price realization identifies products where observed sales may not translate into quality margin.' AS notes
FROM price_risk_products
UNION ALL
SELECT
    'vendor_inventory_pricing_exposure' AS evidence_block,
    'vendor' AS grain,
    productVendor AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    'vendor_revenue_rank' AS rank_label,
    CAST(revenue_rank AS DOUBLE) AS rank_value,
    CAST(products AS BIGINT) AS products,
    CAST(stock_quantity AS DOUBLE) AS stock_quantity,
    CAST(quantity_ordered AS DOUBLE) AS quantity_ordered,
    ROUND(stock_turn_proxy, 4) AS stock_turn_proxy,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(avg_msrp_realization, 4) AS avg_msrp_realization,
    ROUND(avg_markup_vs_buy_price, 4) AS avg_markup_vs_buy_price,
    'vendor_stock_rank' AS extra_metric_1,
    CAST(stock_rank AS DOUBLE) AS extra_value_1,
    'Vendor-level view shows whether inventory and pricing exposure is structurally concentrated.' AS notes
FROM vendor_raw;
