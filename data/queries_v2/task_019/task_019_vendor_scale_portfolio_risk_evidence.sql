-- task_019_vendor_scale_portfolio_risk_evidence.sql
-- Evidence SQL for task_019.
-- Public query: Do product vendors and model scales reveal portfolio risks that are hidden by product-line averages?
-- Note: gross_margin_proxy uses priceEach - buyPrice and is not an accounting profit measure.

WITH
line_fact AS (
    SELECT
        od.orderNumber,
        o.customerNumber,
        od.productCode,
        p.productName,
        p.productLine,
        p.productScale,
        p.productVendor,
        p.quantityInStock,
        p.buyPrice,
        p.MSRP,
        od.quantityOrdered,
        od.priceEach,
        od.quantityOrdered * od.priceEach AS revenue,
        od.quantityOrdered * (od.priceEach - p.buyPrice) AS gross_margin_proxy,
        od.quantityOrdered * p.MSRP AS msrp_value
    FROM orderdetails AS od
    JOIN orders AS o
      ON od.orderNumber = o.orderNumber
    JOIN products AS p
      ON od.productCode = p.productCode
),
product_base AS (
    SELECT
        p.productCode,
        p.productName,
        p.productLine,
        p.productScale,
        p.productVendor,
        p.quantityInStock,
        p.buyPrice,
        p.MSRP,
        COUNT(DISTINCT lf.orderNumber) AS orders,
        COUNT(DISTINCT lf.customerNumber) AS customers,
        COUNT(lf.orderNumber) AS order_lines,
        COALESCE(SUM(lf.quantityOrdered), 0) AS quantity,
        COALESCE(SUM(lf.revenue), 0) AS revenue,
        COALESCE(SUM(lf.gross_margin_proxy), 0) AS gross_margin_proxy,
        COALESCE(SUM(lf.msrp_value), 0) AS msrp_value
    FROM products AS p
    LEFT JOIN line_fact AS lf
      ON p.productCode = lf.productCode
    GROUP BY p.productCode, p.productName, p.productLine, p.productScale, p.productVendor,
             p.quantityInStock, p.buyPrice, p.MSRP
),
vendor_summary AS (
    SELECT
        productVendor,
        COUNT(*) AS products,
        SUM(CASE WHEN revenue > 0 THEN 1 ELSE 0 END) AS ordered_products,
        SUM(orders) AS orders,
        SUM(customers) AS customers_non_distinct,
        SUM(order_lines) AS order_lines,
        SUM(quantity) AS quantity,
        SUM(quantityInStock) AS inventory,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(msrp_value) AS msrp_value,
        ROW_NUMBER() OVER (ORDER BY SUM(revenue) DESC, productVendor) AS revenue_rank,
        ROW_NUMBER() OVER (ORDER BY SUM(quantity) / NULLIF(SUM(quantityInStock), 0) ASC NULLS LAST, SUM(revenue) DESC, productVendor) AS low_turnover_rank
    FROM product_base
    GROUP BY productVendor
),
scale_summary AS (
    SELECT
        productScale,
        COUNT(*) AS products,
        SUM(CASE WHEN revenue > 0 THEN 1 ELSE 0 END) AS ordered_products,
        SUM(orders) AS orders,
        SUM(order_lines) AS order_lines,
        SUM(quantity) AS quantity,
        SUM(quantityInStock) AS inventory,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(msrp_value) AS msrp_value,
        ROW_NUMBER() OVER (ORDER BY SUM(revenue) DESC, productScale) AS revenue_rank,
        ROW_NUMBER() OVER (ORDER BY SUM(gross_margin_proxy) / NULLIF(SUM(revenue), 0) DESC NULLS LAST, productScale) AS margin_rate_rank
    FROM product_base
    GROUP BY productScale
),
vendor_scale_summary AS (
    SELECT
        productVendor,
        productScale,
        COUNT(*) AS products,
        SUM(CASE WHEN revenue > 0 THEN 1 ELSE 0 END) AS ordered_products,
        SUM(orders) AS orders,
        SUM(order_lines) AS order_lines,
        SUM(quantity) AS quantity,
        SUM(quantityInStock) AS inventory,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(msrp_value) AS msrp_value,
        ROW_NUMBER() OVER (PARTITION BY productVendor ORDER BY SUM(revenue) DESC, productScale) AS scale_rank_in_vendor,
        ROW_NUMBER() OVER (ORDER BY SUM(revenue) DESC, productVendor, productScale) AS global_revenue_rank
    FROM product_base
    GROUP BY productVendor, productScale
),
product_ranked AS (
    SELECT
        pb.*,
        pb.quantity / NULLIF(pb.quantityInStock, 0) AS stock_turnover_proxy,
        pb.gross_margin_proxy / NULLIF(pb.revenue, 0) AS gross_margin_rate,
        pb.revenue / NULLIF(pb.msrp_value, 0) AS weighted_msrp_realization,
        ROW_NUMBER() OVER (PARTITION BY pb.productVendor ORDER BY pb.revenue DESC, pb.productName) AS product_rank_in_vendor,
        ROW_NUMBER() OVER (ORDER BY pb.quantityInStock DESC, pb.productName) AS inventory_rank,
        ROW_NUMBER() OVER (ORDER BY pb.quantity / NULLIF(pb.quantityInStock, 0) ASC NULLS FIRST, pb.quantityInStock DESC, pb.productName) AS low_turnover_rank
    FROM product_base AS pb
),
top_product_share AS (
    SELECT
        pr.productVendor,
        pr.productName,
        pr.productLine,
        pr.revenue,
        pr.gross_margin_proxy,
        pr.quantity,
        pr.quantityInStock,
        pr.product_rank_in_vendor,
        pr.stock_turnover_proxy,
        pr.gross_margin_rate,
        pr.weighted_msrp_realization,
        pr.revenue / NULLIF(vs.revenue, 0) AS vendor_revenue_share
    FROM product_ranked AS pr
    JOIN vendor_summary AS vs
      ON pr.productVendor = vs.productVendor
    WHERE pr.product_rank_in_vendor <= 3
)
SELECT
    'vendor_portfolio_baseline' AS evidence_block,
    'vendor' AS grain,
    productVendor AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    'vendor_revenue_rank' AS rank_label,
    CAST(revenue_rank AS DOUBLE) AS rank_value,
    CAST(products AS BIGINT) AS products,
    CAST(ordered_products AS BIGINT) AS ordered_products,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(quantity AS DOUBLE) AS quantity,
    CAST(inventory AS DOUBLE) AS inventory,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(quantity / NULLIF(inventory, 0), 4) AS stock_turnover_proxy,
    ROUND(revenue / NULLIF(msrp_value, 0), 4) AS weighted_msrp_realization,
    ROUND(revenue / NULLIF(SUM(revenue) OVER (), 0), 4) AS share_value,
    'revenue_share' AS share_label,
    'Vendor baseline separates supplier scale, inventory exposure, and margin proxy.' AS notes
FROM vendor_summary
UNION ALL
SELECT
    'scale_portfolio_baseline' AS evidence_block,
    'product_scale' AS grain,
    productScale AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    'scale_revenue_rank' AS rank_label,
    CAST(revenue_rank AS DOUBLE) AS rank_value,
    CAST(products AS BIGINT) AS products,
    CAST(ordered_products AS BIGINT) AS ordered_products,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(quantity AS DOUBLE) AS quantity,
    CAST(inventory AS DOUBLE) AS inventory,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(quantity / NULLIF(inventory, 0), 4) AS stock_turnover_proxy,
    ROUND(revenue / NULLIF(msrp_value, 0), 4) AS weighted_msrp_realization,
    ROUND(revenue / NULLIF(SUM(revenue) OVER (), 0), 4) AS share_value,
    'revenue_share' AS share_label,
    'Scale rows check whether model-size mix explains portfolio quality beyond product line.' AS notes
FROM scale_summary
UNION ALL
SELECT
    'vendor_scale_mix' AS evidence_block,
    'vendor_scale' AS grain,
    productVendor AS item,
    productScale AS item_2,
    'scale_rank_in_vendor' AS rank_label,
    CAST(scale_rank_in_vendor AS DOUBLE) AS rank_value,
    CAST(products AS BIGINT) AS products,
    CAST(ordered_products AS BIGINT) AS ordered_products,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(quantity AS DOUBLE) AS quantity,
    CAST(inventory AS DOUBLE) AS inventory,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(quantity / NULLIF(inventory, 0), 4) AS stock_turnover_proxy,
    ROUND(revenue / NULLIF(msrp_value, 0), 4) AS weighted_msrp_realization,
    ROUND(revenue / NULLIF(SUM(revenue) OVER (PARTITION BY productVendor), 0), 4) AS share_value,
    'vendor_revenue_share' AS share_label,
    'Vendor-scale mix prevents supplier-level averages from hiding weak scale segments.' AS notes
FROM vendor_scale_summary
WHERE scale_rank_in_vendor <= 3 OR global_revenue_rank <= 20
UNION ALL
SELECT
    'top_product_concentration_by_vendor' AS evidence_block,
    'product_in_vendor' AS grain,
    productVendor AS item,
    productName AS item_2,
    'product_rank_in_vendor' AS rank_label,
    CAST(product_rank_in_vendor AS DOUBLE) AS rank_value,
    CAST(1 AS BIGINT) AS products,
    CAST(CASE WHEN revenue > 0 THEN 1 ELSE 0 END AS BIGINT) AS ordered_products,
    CAST(NULL AS BIGINT) AS orders,
    CAST(NULL AS BIGINT) AS order_lines,
    CAST(quantity AS DOUBLE) AS quantity,
    CAST(quantityInStock AS DOUBLE) AS inventory,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_rate, 4) AS gross_margin_rate,
    ROUND(stock_turnover_proxy, 4) AS stock_turnover_proxy,
    ROUND(weighted_msrp_realization, 4) AS weighted_msrp_realization,
    ROUND(vendor_revenue_share, 4) AS share_value,
    'vendor_revenue_share' AS share_label,
    'Top product share shows whether vendor performance is broad-based or product-concentrated.' AS notes
FROM top_product_share
UNION ALL
SELECT
    'high_inventory_low_turnover_products' AS evidence_block,
    'product' AS grain,
    productName AS item,
    productVendor AS item_2,
    CASE WHEN inventory_rank <= 20 THEN 'inventory_rank' ELSE 'low_turnover_rank' END AS rank_label,
    CAST(CASE WHEN inventory_rank <= 20 THEN inventory_rank ELSE low_turnover_rank END AS DOUBLE) AS rank_value,
    CAST(1 AS BIGINT) AS products,
    CAST(CASE WHEN revenue > 0 THEN 1 ELSE 0 END AS BIGINT) AS ordered_products,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(quantity AS DOUBLE) AS quantity,
    CAST(quantityInStock AS DOUBLE) AS inventory,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_rate, 4) AS gross_margin_rate,
    ROUND(stock_turnover_proxy, 4) AS stock_turnover_proxy,
    ROUND(weighted_msrp_realization, 4) AS weighted_msrp_realization,
    ROUND(revenue / NULLIF(SUM(revenue) OVER (), 0), 4) AS share_value,
    'selected_product_revenue_share' AS share_label,
    'High-inventory and low-turnover product rows identify supplier/scale portfolio risks hidden in averages.' AS notes
FROM product_ranked
WHERE inventory_rank <= 20 OR low_turnover_rank <= 20;
