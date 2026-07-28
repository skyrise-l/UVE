-- task_005_product_portfolio_sku_concentration_evidence.sql
-- Final evidence SQL for task_005.
-- Public query: Is product performance genuinely broad-based, or is the portfolio being carried and dragged by a small set of products? Identify where portfolio averages hide product-level risk.

WITH
order_lines AS (
    SELECT 'central_superstore' AS source_table, * FROM central_superstore
    UNION ALL
    SELECT 'east_superstore' AS source_table, * FROM east_superstore
    UNION ALL
    SELECT 'south_superstore' AS source_table, * FROM south_superstore
    UNION ALL
    SELECT 'west_superstore' AS source_table, * FROM west_superstore
),
base AS (
    SELECT
        ol.*,
        COALESCE(p."Product Name", 'Unknown') AS product_name,
        COALESCE(p.Category, 'Unknown') AS category,
        COALESCE(p."Sub-Category", 'Unknown') AS sub_category,
        CASE WHEN ol.Profit < 0 THEN ol.Profit ELSE 0 END AS line_gross_loss,
        CASE WHEN ol.Profit < 0 THEN 1 ELSE 0 END AS loss_line_flag
    FROM order_lines ol
    LEFT JOIN product p
        ON ol."Product ID" = p."Product ID"
       AND ol.Region = p.Region
),
totals AS (
    SELECT
        COUNT(*) AS total_rows,
        COUNT(DISTINCT "Order ID" || '|' || Region) AS total_orders,
        COUNT(DISTINCT "Product ID" || '|' || Region) AS total_product_region_pairs,
        COUNT(DISTINCT "Product ID") AS total_products,
        SUM(Sales) AS total_sales,
        SUM(Profit) AS total_profit,
        SUM(line_gross_loss) AS total_gross_loss
    FROM base
),
product_region_summary AS (
    SELECT
        "Product ID" AS product_id,
        product_name,
        category,
        sub_category,
        Region AS region,
        COUNT(*) AS row_count,
        COUNT(DISTINCT "Order ID" || '|' || Region) AS order_count,
        SUM(Sales) AS sales,
        100.0 * SUM(Sales) / NULLIF(MAX(t.total_sales), 0) AS sales_share_pct,
        SUM(Profit) AS profit,
        100.0 * SUM(Profit) / NULLIF(SUM(Sales), 0) AS profit_margin_pct,
        AVG(Discount) AS avg_discount,
        SUM(loss_line_flag) AS loss_line_count,
        SUM(line_gross_loss) AS gross_loss,
        100.0 * SUM(line_gross_loss) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct
    FROM base
    CROSS JOIN totals t
    GROUP BY "Product ID", product_name, category, sub_category, Region
),
product_global_summary AS (
    SELECT
        product_id,
        product_name,
        category,
        sub_category,
        COUNT(DISTINCT region) AS region_count,
        SUM(row_count) AS row_count,
        SUM(order_count) AS order_count,
        SUM(sales) AS sales,
        100.0 * SUM(sales) / NULLIF(MAX(t.total_sales), 0) AS sales_share_pct,
        SUM(profit) AS profit,
        100.0 * SUM(profit) / NULLIF(SUM(sales), 0) AS profit_margin_pct,
        SUM(avg_discount * row_count) / NULLIF(SUM(row_count), 0) AS avg_discount,
        SUM(loss_line_count) AS loss_line_count,
        SUM(gross_loss) AS gross_loss,
        100.0 * SUM(gross_loss) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct
    FROM product_region_summary
    CROSS JOIN totals t
    GROUP BY product_id, product_name, category, sub_category
),
product_ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY sales DESC) AS rank_by_sales,
        ROW_NUMBER() OVER (ORDER BY profit DESC) AS rank_by_profit,
        ROW_NUMBER() OVER (ORDER BY profit ASC) AS rank_by_negative_profit,
        ROW_NUMBER() OVER (ORDER BY gross_loss ASC) AS rank_by_gross_loss
    FROM product_global_summary
),
category_summary AS (
    SELECT
        category AS entity,
        NULL AS parent_entity,
        COUNT(*) AS product_count,
        SUM(CASE WHEN profit > 0 THEN 1 ELSE 0 END) AS positive_product_count,
        SUM(CASE WHEN profit < 0 THEN 1 ELSE 0 END) AS negative_product_count,
        SUM(row_count) AS row_count,
        SUM(order_count) AS order_count,
        SUM(sales) AS sales,
        100.0 * SUM(sales) / NULLIF(MAX(t.total_sales), 0) AS sales_share_pct,
        SUM(profit) AS profit,
        100.0 * SUM(profit) / NULLIF(SUM(sales), 0) AS profit_margin_pct,
        SUM(avg_discount * row_count) / NULLIF(SUM(row_count), 0) AS avg_discount,
        SUM(loss_line_count) AS loss_line_count,
        SUM(gross_loss) AS gross_loss,
        100.0 * SUM(gross_loss) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct,
        MIN(profit_margin_pct) AS min_product_margin_pct,
        MAX(profit_margin_pct) AS max_product_margin_pct
    FROM product_global_summary
    CROSS JOIN totals t
    GROUP BY category
),
portfolio_status AS (
    SELECT
        'all_products' AS entity,
        'portfolio' AS parent_entity,
        COUNT(*) AS product_count,
        SUM(CASE WHEN profit > 0 THEN 1 ELSE 0 END) AS positive_product_count,
        SUM(CASE WHEN profit < 0 THEN 1 ELSE 0 END) AS negative_product_count,
        SUM(row_count) AS row_count,
        SUM(order_count) AS order_count,
        SUM(sales) AS sales,
        100.0 * SUM(sales) / NULLIF(MAX(t.total_sales), 0) AS sales_share_pct,
        SUM(profit) AS profit,
        100.0 * SUM(profit) / NULLIF(SUM(sales), 0) AS profit_margin_pct,
        SUM(avg_discount * row_count) / NULLIF(SUM(row_count), 0) AS avg_discount,
        SUM(loss_line_count) AS loss_line_count,
        SUM(gross_loss) AS gross_loss,
        100.0 * SUM(gross_loss) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct,
        MIN(profit_margin_pct) AS min_product_margin_pct,
        MAX(profit_margin_pct) AS max_product_margin_pct
    FROM product_global_summary
    CROSS JOIN totals t
),
product_concentration AS (
    SELECT
        'top_10_profit_products' AS entity,
        'product_profit_concentration' AS parent_entity,
        10 AS product_count,
        SUM(CASE WHEN rank_by_profit <= 10 AND profit > 0 THEN 1 ELSE 0 END) AS positive_product_count,
        SUM(CASE WHEN rank_by_profit <= 10 AND profit < 0 THEN 1 ELSE 0 END) AS negative_product_count,
        SUM(CASE WHEN rank_by_profit <= 10 THEN row_count ELSE 0 END) AS row_count,
        SUM(CASE WHEN rank_by_profit <= 10 THEN order_count ELSE 0 END) AS order_count,
        SUM(CASE WHEN rank_by_profit <= 10 THEN sales ELSE 0 END) AS sales,
        100.0 * SUM(CASE WHEN rank_by_profit <= 10 THEN sales ELSE 0 END) / NULLIF(MAX(t.total_sales), 0) AS sales_share_pct,
        SUM(CASE WHEN rank_by_profit <= 10 THEN profit ELSE 0 END) AS profit,
        100.0 * SUM(CASE WHEN rank_by_profit <= 10 THEN profit ELSE 0 END) / NULLIF(SUM(CASE WHEN rank_by_profit <= 10 THEN sales ELSE 0 END), 0) AS profit_margin_pct,
        SUM(CASE WHEN rank_by_profit <= 10 THEN avg_discount * row_count ELSE 0 END) / NULLIF(SUM(CASE WHEN rank_by_profit <= 10 THEN row_count ELSE 0 END), 0) AS avg_discount,
        SUM(CASE WHEN rank_by_profit <= 10 THEN loss_line_count ELSE 0 END) AS loss_line_count,
        SUM(CASE WHEN rank_by_profit <= 10 THEN gross_loss ELSE 0 END) AS gross_loss,
        100.0 * SUM(CASE WHEN rank_by_profit <= 10 THEN gross_loss ELSE 0 END) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct
    FROM product_ranked
    CROSS JOIN totals t
    UNION ALL
    SELECT
        'top_20_profit_products' AS entity,
        'product_profit_concentration' AS parent_entity,
        20 AS product_count,
        SUM(CASE WHEN rank_by_profit <= 20 AND profit > 0 THEN 1 ELSE 0 END) AS positive_product_count,
        SUM(CASE WHEN rank_by_profit <= 20 AND profit < 0 THEN 1 ELSE 0 END) AS negative_product_count,
        SUM(CASE WHEN rank_by_profit <= 20 THEN row_count ELSE 0 END) AS row_count,
        SUM(CASE WHEN rank_by_profit <= 20 THEN order_count ELSE 0 END) AS order_count,
        SUM(CASE WHEN rank_by_profit <= 20 THEN sales ELSE 0 END) AS sales,
        100.0 * SUM(CASE WHEN rank_by_profit <= 20 THEN sales ELSE 0 END) / NULLIF(MAX(t.total_sales), 0) AS sales_share_pct,
        SUM(CASE WHEN rank_by_profit <= 20 THEN profit ELSE 0 END) AS profit,
        100.0 * SUM(CASE WHEN rank_by_profit <= 20 THEN profit ELSE 0 END) / NULLIF(SUM(CASE WHEN rank_by_profit <= 20 THEN sales ELSE 0 END), 0) AS profit_margin_pct,
        SUM(CASE WHEN rank_by_profit <= 20 THEN avg_discount * row_count ELSE 0 END) / NULLIF(SUM(CASE WHEN rank_by_profit <= 20 THEN row_count ELSE 0 END), 0) AS avg_discount,
        SUM(CASE WHEN rank_by_profit <= 20 THEN loss_line_count ELSE 0 END) AS loss_line_count,
        SUM(CASE WHEN rank_by_profit <= 20 THEN gross_loss ELSE 0 END) AS gross_loss,
        100.0 * SUM(CASE WHEN rank_by_profit <= 20 THEN gross_loss ELSE 0 END) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct
    FROM product_ranked
    CROSS JOIN totals t
    UNION ALL
    SELECT
        'bottom_10_profit_products' AS entity,
        'product_loss_concentration' AS parent_entity,
        10 AS product_count,
        SUM(CASE WHEN rank_by_negative_profit <= 10 AND profit > 0 THEN 1 ELSE 0 END) AS positive_product_count,
        SUM(CASE WHEN rank_by_negative_profit <= 10 AND profit < 0 THEN 1 ELSE 0 END) AS negative_product_count,
        SUM(CASE WHEN rank_by_negative_profit <= 10 THEN row_count ELSE 0 END) AS row_count,
        SUM(CASE WHEN rank_by_negative_profit <= 10 THEN order_count ELSE 0 END) AS order_count,
        SUM(CASE WHEN rank_by_negative_profit <= 10 THEN sales ELSE 0 END) AS sales,
        100.0 * SUM(CASE WHEN rank_by_negative_profit <= 10 THEN sales ELSE 0 END) / NULLIF(MAX(t.total_sales), 0) AS sales_share_pct,
        SUM(CASE WHEN rank_by_negative_profit <= 10 THEN profit ELSE 0 END) AS profit,
        100.0 * SUM(CASE WHEN rank_by_negative_profit <= 10 THEN profit ELSE 0 END) / NULLIF(SUM(CASE WHEN rank_by_negative_profit <= 10 THEN sales ELSE 0 END), 0) AS profit_margin_pct,
        SUM(CASE WHEN rank_by_negative_profit <= 10 THEN avg_discount * row_count ELSE 0 END) / NULLIF(SUM(CASE WHEN rank_by_negative_profit <= 10 THEN row_count ELSE 0 END), 0) AS avg_discount,
        SUM(CASE WHEN rank_by_negative_profit <= 10 THEN loss_line_count ELSE 0 END) AS loss_line_count,
        SUM(CASE WHEN rank_by_negative_profit <= 10 THEN gross_loss ELSE 0 END) AS gross_loss,
        100.0 * SUM(CASE WHEN rank_by_negative_profit <= 10 THEN gross_loss ELSE 0 END) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct
    FROM product_ranked
    CROSS JOIN totals t
    UNION ALL
    SELECT
        'bottom_20_profit_products' AS entity,
        'product_loss_concentration' AS parent_entity,
        20 AS product_count,
        SUM(CASE WHEN rank_by_negative_profit <= 20 AND profit > 0 THEN 1 ELSE 0 END) AS positive_product_count,
        SUM(CASE WHEN rank_by_negative_profit <= 20 AND profit < 0 THEN 1 ELSE 0 END) AS negative_product_count,
        SUM(CASE WHEN rank_by_negative_profit <= 20 THEN row_count ELSE 0 END) AS row_count,
        SUM(CASE WHEN rank_by_negative_profit <= 20 THEN order_count ELSE 0 END) AS order_count,
        SUM(CASE WHEN rank_by_negative_profit <= 20 THEN sales ELSE 0 END) AS sales,
        100.0 * SUM(CASE WHEN rank_by_negative_profit <= 20 THEN sales ELSE 0 END) / NULLIF(MAX(t.total_sales), 0) AS sales_share_pct,
        SUM(CASE WHEN rank_by_negative_profit <= 20 THEN profit ELSE 0 END) AS profit,
        100.0 * SUM(CASE WHEN rank_by_negative_profit <= 20 THEN profit ELSE 0 END) / NULLIF(SUM(CASE WHEN rank_by_negative_profit <= 20 THEN sales ELSE 0 END), 0) AS profit_margin_pct,
        SUM(CASE WHEN rank_by_negative_profit <= 20 THEN avg_discount * row_count ELSE 0 END) / NULLIF(SUM(CASE WHEN rank_by_negative_profit <= 20 THEN row_count ELSE 0 END), 0) AS avg_discount,
        SUM(CASE WHEN rank_by_negative_profit <= 20 THEN loss_line_count ELSE 0 END) AS loss_line_count,
        SUM(CASE WHEN rank_by_negative_profit <= 20 THEN gross_loss ELSE 0 END) AS gross_loss,
        100.0 * SUM(CASE WHEN rank_by_negative_profit <= 20 THEN gross_loss ELSE 0 END) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct
    FROM product_ranked
    CROSS JOIN totals t
),
subcategory_summary AS (
    SELECT
        sub_category AS entity,
        category AS parent_entity,
        COUNT(*) AS product_count,
        SUM(CASE WHEN profit > 0 THEN 1 ELSE 0 END) AS positive_product_count,
        SUM(CASE WHEN profit < 0 THEN 1 ELSE 0 END) AS negative_product_count,
        SUM(row_count) AS row_count,
        SUM(order_count) AS order_count,
        SUM(sales) AS sales,
        100.0 * SUM(sales) / NULLIF(MAX(t.total_sales), 0) AS sales_share_pct,
        SUM(profit) AS profit,
        100.0 * SUM(profit) / NULLIF(SUM(sales), 0) AS profit_margin_pct,
        SUM(avg_discount * row_count) / NULLIF(SUM(row_count), 0) AS avg_discount,
        SUM(loss_line_count) AS loss_line_count,
        SUM(gross_loss) AS gross_loss,
        100.0 * SUM(gross_loss) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct,
        MIN(profit_margin_pct) AS min_product_margin_pct,
        MAX(profit_margin_pct) AS max_product_margin_pct
    FROM product_global_summary
    CROSS JOIN totals t
    GROUP BY category, sub_category
),
product_region_sign AS (
    SELECT
        product_id,
        product_name,
        category,
        sub_category,
        COUNT(*) AS region_count,
        SUM(CASE WHEN profit > 0 THEN 1 ELSE 0 END) AS positive_region_count,
        SUM(CASE WHEN profit < 0 THEN 1 ELSE 0 END) AS negative_region_count,
        SUM(row_count) AS row_count,
        SUM(order_count) AS order_count,
        SUM(sales) AS sales,
        SUM(profit) AS profit,
        100.0 * SUM(profit) / NULLIF(SUM(sales), 0) AS profit_margin_pct,
        SUM(avg_discount * row_count) / NULLIF(SUM(row_count), 0) AS avg_discount,
        SUM(loss_line_count) AS loss_line_count,
        SUM(gross_loss) AS gross_loss,
        MIN(profit_margin_pct) AS min_region_margin_pct,
        MAX(profit_margin_pct) AS max_region_margin_pct
    FROM product_region_summary
    GROUP BY product_id, product_name, category, sub_category
),
region_sign_ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY (max_region_margin_pct - min_region_margin_pct) DESC) AS rank_by_margin_spread,
        ROW_NUMBER() OVER (ORDER BY profit DESC) AS rank_by_profit,
        ROW_NUMBER() OVER (ORDER BY profit ASC) AS rank_by_negative_profit
    FROM product_region_sign
    WHERE region_count >= 2
),
region_sign_summary AS (
    SELECT
        'multi_region_products' AS entity,
        'region_consistency' AS parent_entity,
        COUNT(*) AS product_count,
        SUM(CASE WHEN positive_region_count > 0 AND negative_region_count > 0 THEN 1 ELSE 0 END) AS mixed_region_product_count,
        SUM(CASE WHEN positive_region_count = region_count THEN 1 ELSE 0 END) AS all_positive_region_product_count,
        SUM(CASE WHEN negative_region_count = region_count THEN 1 ELSE 0 END) AS all_negative_region_product_count,
        SUM(row_count) AS row_count,
        SUM(order_count) AS order_count,
        SUM(sales) AS sales,
        SUM(profit) AS profit,
        100.0 * SUM(profit) / NULLIF(SUM(sales), 0) AS profit_margin_pct,
        SUM(avg_discount * row_count) / NULLIF(SUM(row_count), 0) AS avg_discount,
        SUM(loss_line_count) AS loss_line_count,
        SUM(gross_loss) AS gross_loss,
        MIN(min_region_margin_pct) AS min_region_margin_pct,
        MAX(max_region_margin_pct) AS max_region_margin_pct
    FROM product_region_sign
    WHERE region_count >= 2
)
SELECT
    'G1' AS evidence_group_id,
    'portfolio_breadth_baseline' AS evidence_block,
    'portfolio' AS entity_level,
    entity,
    parent_entity,
    NULL AS region,
    row_count,
    order_count,
    product_count,
    positive_product_count,
    negative_product_count,
    NULL AS mixed_region_product_count,
    ROUND(sales, 2) AS sales,
    ROUND(sales_share_pct, 2) AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    loss_line_count,
    ROUND(gross_loss, 2) AS gross_loss,
    ROUND(gross_loss_share_pct, 2) AS gross_loss_share_pct,
    ROUND(min_product_margin_pct, 2) AS min_margin_pct,
    ROUND(max_product_margin_pct, 2) AS max_margin_pct,
    NULL AS rank_by_sales,
    NULL AS rank_by_profit,
    NULL AS rank_by_loss,
    'Portfolio baseline: compare product breadth, positive/negative product counts, and category-level profit quality.' AS note
FROM portfolio_status
UNION ALL
SELECT
    'G1' AS evidence_group_id,
    'portfolio_breadth_baseline' AS evidence_block,
    'category' AS entity_level,
    entity,
    parent_entity,
    NULL AS region,
    row_count,
    order_count,
    product_count,
    positive_product_count,
    negative_product_count,
    NULL AS mixed_region_product_count,
    ROUND(sales, 2) AS sales,
    ROUND(sales_share_pct, 2) AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    loss_line_count,
    ROUND(gross_loss, 2) AS gross_loss,
    ROUND(gross_loss_share_pct, 2) AS gross_loss_share_pct,
    ROUND(min_product_margin_pct, 2) AS min_margin_pct,
    ROUND(max_product_margin_pct, 2) AS max_margin_pct,
    NULL AS rank_by_sales,
    NULL AS rank_by_profit,
    NULL AS rank_by_loss,
    'Portfolio baseline: compare product breadth, positive/negative product counts, and category-level profit quality.' AS note
FROM category_summary
UNION ALL
SELECT
    'G2' AS evidence_group_id,
    'top_product_profit_concentration' AS evidence_block,
    'product_concentration' AS entity_level,
    entity,
    parent_entity,
    NULL AS region,
    row_count,
    order_count,
    product_count,
    positive_product_count,
    negative_product_count,
    NULL AS mixed_region_product_count,
    ROUND(sales, 2) AS sales,
    ROUND(sales_share_pct, 2) AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    loss_line_count,
    ROUND(gross_loss, 2) AS gross_loss,
    ROUND(gross_loss_share_pct, 2) AS gross_loss_share_pct,
    NULL AS min_margin_pct,
    NULL AS max_margin_pct,
    NULL AS rank_by_sales,
    NULL AS rank_by_profit,
    NULL AS rank_by_loss,
    'Top-product concentration aggregate: quantify how much profit comes from the leading products.' AS note
FROM product_concentration
WHERE parent_entity = 'product_profit_concentration'
UNION ALL
SELECT
    'G2' AS evidence_group_id,
    'top_product_profit_concentration' AS evidence_block,
    'product' AS entity_level,
    product_id || ' / ' || product_name AS entity,
    category || ' / ' || sub_category AS parent_entity,
    NULL AS region,
    row_count,
    order_count,
    1 AS product_count,
    CASE WHEN profit > 0 THEN 1 ELSE 0 END AS positive_product_count,
    CASE WHEN profit < 0 THEN 1 ELSE 0 END AS negative_product_count,
    NULL AS mixed_region_product_count,
    ROUND(sales, 2) AS sales,
    ROUND(sales_share_pct, 2) AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    loss_line_count,
    ROUND(gross_loss, 2) AS gross_loss,
    ROUND(gross_loss_share_pct, 2) AS gross_loss_share_pct,
    NULL AS min_margin_pct,
    NULL AS max_margin_pct,
    rank_by_sales,
    rank_by_profit,
    rank_by_gross_loss AS rank_by_loss,
    'Top-product concentration details: selected products by top profit and top sales.' AS note
FROM product_ranked
WHERE rank_by_profit <= 15 OR rank_by_sales <= 15
UNION ALL
SELECT
    'G3' AS evidence_group_id,
    'bottom_product_loss_concentration' AS evidence_block,
    'product_concentration' AS entity_level,
    entity,
    parent_entity,
    NULL AS region,
    row_count,
    order_count,
    product_count,
    positive_product_count,
    negative_product_count,
    NULL AS mixed_region_product_count,
    ROUND(sales, 2) AS sales,
    ROUND(sales_share_pct, 2) AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    loss_line_count,
    ROUND(gross_loss, 2) AS gross_loss,
    ROUND(gross_loss_share_pct, 2) AS gross_loss_share_pct,
    NULL AS min_margin_pct,
    NULL AS max_margin_pct,
    NULL AS rank_by_sales,
    NULL AS rank_by_profit,
    NULL AS rank_by_loss,
    'Bottom-product concentration aggregate: quantify how much loss comes from the weakest products.' AS note
FROM product_concentration
WHERE parent_entity = 'product_loss_concentration'
UNION ALL
SELECT
    'G3' AS evidence_group_id,
    'bottom_product_loss_concentration' AS evidence_block,
    'product' AS entity_level,
    product_id || ' / ' || product_name AS entity,
    category || ' / ' || sub_category AS parent_entity,
    NULL AS region,
    row_count,
    order_count,
    1 AS product_count,
    CASE WHEN profit > 0 THEN 1 ELSE 0 END AS positive_product_count,
    CASE WHEN profit < 0 THEN 1 ELSE 0 END AS negative_product_count,
    NULL AS mixed_region_product_count,
    ROUND(sales, 2) AS sales,
    ROUND(sales_share_pct, 2) AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    loss_line_count,
    ROUND(gross_loss, 2) AS gross_loss,
    ROUND(gross_loss_share_pct, 2) AS gross_loss_share_pct,
    NULL AS min_margin_pct,
    NULL AS max_margin_pct,
    rank_by_sales,
    rank_by_profit,
    rank_by_gross_loss AS rank_by_loss,
    'Bottom-product concentration details: selected products by most negative profit and highest gross-loss exposure.' AS note
FROM product_ranked
WHERE rank_by_negative_profit <= 15 OR rank_by_gross_loss <= 15
UNION ALL
SELECT
    'G4' AS evidence_group_id,
    'subcategory_sku_dispersion' AS evidence_block,
    'sub_category' AS entity_level,
    entity,
    parent_entity,
    NULL AS region,
    row_count,
    order_count,
    product_count,
    positive_product_count,
    negative_product_count,
    NULL AS mixed_region_product_count,
    ROUND(sales, 2) AS sales,
    ROUND(sales_share_pct, 2) AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    loss_line_count,
    ROUND(gross_loss, 2) AS gross_loss,
    ROUND(gross_loss_share_pct, 2) AS gross_loss_share_pct,
    ROUND(min_product_margin_pct, 2) AS min_margin_pct,
    ROUND(max_product_margin_pct, 2) AS max_margin_pct,
    NULL AS rank_by_sales,
    NULL AS rank_by_profit,
    NULL AS rank_by_loss,
    'Subcategory dispersion: compare subcategory-level margin with the count and range of positive and negative SKUs inside it.' AS note
FROM subcategory_summary
UNION ALL
SELECT
    'G5' AS evidence_group_id,
    'cross_region_sku_consistency' AS evidence_block,
    'region_consistency_summary' AS entity_level,
    entity,
    parent_entity,
    NULL AS region,
    row_count,
    order_count,
    product_count,
    all_positive_region_product_count AS positive_product_count,
    all_negative_region_product_count AS negative_product_count,
    mixed_region_product_count,
    ROUND(sales, 2) AS sales,
    NULL AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    loss_line_count,
    ROUND(gross_loss, 2) AS gross_loss,
    NULL AS gross_loss_share_pct,
    ROUND(min_region_margin_pct, 2) AS min_margin_pct,
    ROUND(max_region_margin_pct, 2) AS max_margin_pct,
    NULL AS rank_by_sales,
    NULL AS rank_by_profit,
    NULL AS rank_by_loss,
    'Cross-region summary: test whether the same product IDs are consistently profitable or region-sensitive.' AS note
FROM region_sign_summary
UNION ALL
SELECT
    'G5' AS evidence_group_id,
    'cross_region_sku_consistency' AS evidence_block,
    'multi_region_product' AS entity_level,
    product_id || ' / ' || product_name AS entity,
    category || ' / ' || sub_category AS parent_entity,
    NULL AS region,
    row_count,
    order_count,
    region_count AS product_count,
    positive_region_count AS positive_product_count,
    negative_region_count AS negative_product_count,
    CASE WHEN positive_region_count > 0 AND negative_region_count > 0 THEN 1 ELSE 0 END AS mixed_region_product_count,
    ROUND(sales, 2) AS sales,
    NULL AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    loss_line_count,
    ROUND(gross_loss, 2) AS gross_loss,
    NULL AS gross_loss_share_pct,
    ROUND(min_region_margin_pct, 2) AS min_margin_pct,
    ROUND(max_region_margin_pct, 2) AS max_margin_pct,
    NULL AS rank_by_sales,
    rank_by_profit,
    rank_by_negative_profit AS rank_by_loss,
    'Cross-region details: selected multi-region products with mixed signs or large regional margin spreads.' AS note
FROM region_sign_ranked
WHERE (positive_region_count > 0 AND negative_region_count > 0)
   OR rank_by_margin_spread <= 20
ORDER BY evidence_group_id, evidence_block, entity_level, rank_by_loss NULLS LAST, rank_by_profit NULLS LAST, entity;
