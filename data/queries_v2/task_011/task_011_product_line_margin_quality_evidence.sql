-- task_011_product_line_margin_quality_evidence.sql
-- Evidence SQL for task_011.
-- Public query: Which product lines sell well but do not reliably turn revenue into healthy gross margin, and where are the weak spots inside the product portfolio?
-- Note: gross_margin_proxy uses priceEach - buyPrice and is not an accounting profit measure.

WITH
line_fact AS (
    SELECT
        od.orderNumber,
        o.customerNumber,
        o.orderDate,
        p.productCode,
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
        od.quantityOrdered * (p.MSRP - od.priceEach) AS msrp_gap_value
    FROM orderdetails AS od
    JOIN orders AS o
      ON od.orderNumber = o.orderNumber
    JOIN products AS p
      ON od.productCode = p.productCode
),
product_line_raw AS (
    SELECT
        productLine,
        COUNT(DISTINCT productCode) AS ordered_products,
        COUNT(DISTINCT orderNumber) AS orders,
        COUNT(DISTINCT customerNumber) AS customers,
        COUNT(*) AS order_lines,
        SUM(quantityOrdered) AS quantity,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(msrp_gap_value) AS msrp_gap_value,
        AVG(priceEach) AS avg_price_each,
        AVG(buyPrice) AS avg_buy_price,
        AVG(MSRP) AS avg_msrp,
        SUM(priceEach * quantityOrdered) / NULLIF(SUM(MSRP * quantityOrdered), 0) AS weighted_msrp_realization
    FROM line_fact
    GROUP BY productLine
),
product_line_ranked AS (
    SELECT
        *,
        gross_margin_proxy / NULLIF(revenue, 0) AS gross_margin_rate,
        revenue / NULLIF(SUM(revenue) OVER (), 0) AS revenue_share,
        gross_margin_proxy / NULLIF(SUM(gross_margin_proxy) OVER (), 0) AS margin_proxy_share,
        ROW_NUMBER() OVER (ORDER BY revenue DESC, productLine) AS revenue_rank,
        ROW_NUMBER() OVER (ORDER BY gross_margin_proxy / NULLIF(revenue, 0) DESC NULLS LAST, revenue DESC) AS margin_rate_rank,
        ROW_NUMBER() OVER (ORDER BY gross_margin_proxy DESC, revenue DESC) AS margin_proxy_rank
    FROM product_line_raw
),
product_raw AS (
    SELECT
        p.productLine,
        p.productCode,
        p.productName,
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
        COALESCE(SUM(lf.msrp_gap_value), 0) AS msrp_gap_value,
        AVG(lf.priceEach) AS avg_price_each
    FROM products AS p
    LEFT JOIN line_fact AS lf
      ON p.productCode = lf.productCode
    GROUP BY p.productLine, p.productCode, p.productName, p.productScale, p.productVendor,
             p.quantityInStock, p.buyPrice, p.MSRP
),
product_ranked AS (
    SELECT
        pr.*,
        pr.gross_margin_proxy / NULLIF(pr.revenue, 0) AS gross_margin_rate,
        pr.revenue / NULLIF(pl.revenue, 0) AS line_revenue_share,
        pr.gross_margin_proxy / NULLIF(pl.gross_margin_proxy, 0) AS line_margin_proxy_share,
        ROW_NUMBER() OVER (PARTITION BY pr.productLine ORDER BY pr.revenue DESC, pr.productName) AS revenue_rank_in_line,
        ROW_NUMBER() OVER (PARTITION BY pr.productLine ORDER BY pr.gross_margin_proxy DESC, pr.productName) AS margin_proxy_rank_in_line,
        ROW_NUMBER() OVER (PARTITION BY pr.productLine ORDER BY pr.gross_margin_proxy / NULLIF(pr.revenue, 0) ASC NULLS LAST, pr.revenue DESC) AS weak_margin_rank_in_line
    FROM product_raw AS pr
    LEFT JOIN product_line_raw AS pl
      ON pr.productLine = pl.productLine
),
scale_raw AS (
    SELECT
        productLine,
        productScale,
        COUNT(DISTINCT productCode) AS products,
        COUNT(DISTINCT orderNumber) AS orders,
        COUNT(*) AS order_lines,
        SUM(quantityOrdered) AS quantity,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        AVG(priceEach) AS avg_price_each,
        AVG(MSRP) AS avg_msrp
    FROM line_fact
    GROUP BY productLine, productScale
),
scale_ranked AS (
    SELECT
        *,
        gross_margin_proxy / NULLIF(revenue, 0) AS gross_margin_rate,
        ROW_NUMBER() OVER (PARTITION BY productLine ORDER BY revenue DESC, productScale) AS scale_revenue_rank
    FROM scale_raw
),
low_margin_products AS (
    SELECT *
    FROM product_ranked
    WHERE revenue > 0
      AND (gross_margin_proxy <= 0 OR gross_margin_proxy / NULLIF(revenue, 0) <= 0.15)
)
SELECT
    'product_line_baseline' AS evidence_block,
    'product_line' AS grain,
    productLine AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    'revenue_rank' AS rank_label,
    CAST(revenue_rank AS DOUBLE) AS rank_value,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_rate, 4) AS gross_margin_rate,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(customers AS BIGINT) AS customers,
    CAST(ordered_products AS BIGINT) AS products,
    CAST(quantity AS DOUBLE) AS quantity,
    ROUND(revenue_share, 4) AS share_value,
    'revenue_share' AS share_label,
    'margin_rate_rank' AS extra_metric_1,
    CAST(margin_rate_rank AS DOUBLE) AS extra_value_1,
    'weighted_msrp_realization' AS extra_metric_2,
    ROUND(weighted_msrp_realization, 4) AS extra_value_2,
    'Compare scale and gross-margin proxy before treating the highest-revenue product line as the healthiest line.' AS notes
FROM product_line_ranked
UNION ALL
SELECT
    'product_line_rank_mismatch' AS evidence_block,
    'product_line' AS grain,
    productLine AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    'revenue_rank_minus_margin_rate_rank' AS rank_label,
    CAST(revenue_rank - margin_rate_rank AS DOUBLE) AS rank_value,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_rate, 4) AS gross_margin_rate,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(customers AS BIGINT) AS customers,
    CAST(ordered_products AS BIGINT) AS products,
    CAST(quantity AS DOUBLE) AS quantity,
    ROUND(margin_proxy_share, 4) AS share_value,
    'margin_proxy_share' AS share_label,
    'revenue_rank' AS extra_metric_1,
    CAST(revenue_rank AS DOUBLE) AS extra_value_1,
    'margin_proxy_rank' AS extra_metric_2,
    CAST(margin_proxy_rank AS DOUBLE) AS extra_value_2,
    'Rank mismatch highlights product lines where sales scale and margin quality diverge.' AS notes
FROM product_line_ranked
UNION ALL
SELECT
    'top_product_concentration' AS evidence_block,
    'product_in_line' AS grain,
    productLine AS item,
    productName AS item_2,
    'revenue_rank_in_line' AS rank_label,
    CAST(revenue_rank_in_line AS DOUBLE) AS rank_value,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_rate, 4) AS gross_margin_rate,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(customers AS BIGINT) AS customers,
    CAST(1 AS BIGINT) AS products,
    CAST(quantity AS DOUBLE) AS quantity,
    ROUND(line_revenue_share, 4) AS share_value,
    'line_revenue_share' AS share_label,
    'margin_proxy_rank_in_line' AS extra_metric_1,
    CAST(margin_proxy_rank_in_line AS DOUBLE) AS extra_value_1,
    'line_margin_proxy_share' AS extra_metric_2,
    ROUND(line_margin_proxy_share, 4) AS extra_value_2,
    'Use this block to check whether each line is broad-based or pulled by a few products.' AS notes
FROM product_ranked
WHERE revenue_rank_in_line <= 3 OR margin_proxy_rank_in_line <= 3
UNION ALL
SELECT
    'low_margin_product_screen' AS evidence_block,
    'product_in_line' AS grain,
    productLine AS item,
    productName AS item_2,
    'weak_margin_rank_in_line' AS rank_label,
    CAST(weak_margin_rank_in_line AS DOUBLE) AS rank_value,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_rate, 4) AS gross_margin_rate,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(customers AS BIGINT) AS customers,
    CAST(1 AS BIGINT) AS products,
    CAST(quantity AS DOUBLE) AS quantity,
    ROUND(line_revenue_share, 4) AS share_value,
    'line_revenue_share' AS share_label,
    'buy_price' AS extra_metric_1,
    ROUND(buyPrice, 4) AS extra_value_1,
    'msrp' AS extra_metric_2,
    ROUND(MSRP, 4) AS extra_value_2,
    'Low or negative proxy margin products are weak spots even inside otherwise healthy product lines.' AS notes
FROM low_margin_products
UNION ALL
SELECT
    'product_scale_mix' AS evidence_block,
    'product_line_scale' AS grain,
    productLine AS item,
    productScale AS item_2,
    'scale_revenue_rank' AS rank_label,
    CAST(scale_revenue_rank AS DOUBLE) AS rank_value,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_rate, 4) AS gross_margin_rate,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(NULL AS BIGINT) AS customers,
    CAST(products AS BIGINT) AS products,
    CAST(quantity AS DOUBLE) AS quantity,
    CAST(NULL AS DOUBLE) AS share_value,
    'not_applicable' AS share_label,
    'avg_price_each' AS extra_metric_1,
    ROUND(avg_price_each, 4) AS extra_value_1,
    'avg_msrp' AS extra_metric_2,
    ROUND(avg_msrp, 4) AS extra_value_2,
    'Product scale mix helps explain whether line-level performance is driven by a specific scale segment.' AS notes
FROM scale_ranked;
