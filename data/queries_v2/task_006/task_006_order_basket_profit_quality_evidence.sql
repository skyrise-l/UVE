-- task_006_order_basket_profit_quality_evidence.sql
-- Final evidence SQL for task_006.
-- Public query: Do larger or more complex customer baskets reliably turn sales into profit, or do some order patterns hide profit-quality risk?

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
        COALESCE(p.Category, 'Unknown') AS category,
        COALESCE(p."Sub-Category", 'Unknown') AS sub_category,
        CASE WHEN ol.Profit < 0 THEN ol.Profit ELSE 0 END AS line_gross_loss,
        CASE WHEN ol.Profit < 0 THEN 1 ELSE 0 END AS loss_line_flag,
        CASE WHEN ol.Profit > 0 THEN 1 ELSE 0 END AS profit_line_flag
    FROM order_lines ol
    LEFT JOIN product p
        ON ol."Product ID" = p."Product ID"
       AND ol.Region = p.Region
),
order_summary AS (
    SELECT
        "Order ID",
        Region,
        MIN("Customer ID") AS customer_id,
        MIN("Order Date") AS order_date,
        COUNT(*) AS line_count,
        COUNT(DISTINCT category) AS category_count,
        COUNT(DISTINCT sub_category) AS subcategory_count,
        COUNT(DISTINCT "Product ID") AS product_count,
        SUM(Quantity) AS total_quantity,
        SUM(Sales) AS sales,
        SUM(Profit) AS profit,
        100.0 * SUM(Profit) / NULLIF(SUM(Sales), 0) AS profit_margin_pct,
        AVG(Discount) AS avg_discount,
        MAX(Discount) AS max_discount,
        SUM(loss_line_flag) AS loss_line_count,
        SUM(profit_line_flag) AS profit_line_count,
        SUM(line_gross_loss) AS gross_loss,
        CASE WHEN SUM(Profit) < 0 THEN 1 ELSE 0 END AS net_loss_order_flag,
        CASE WHEN SUM(loss_line_flag) > 0 THEN 1 ELSE 0 END AS has_loss_line_flag,
        CASE
            WHEN COUNT(*) = 1 THEN '1 line'
            WHEN COUNT(*) = 2 THEN '2 lines'
            WHEN COUNT(*) = 3 THEN '3 lines'
            ELSE '4+ lines'
        END AS line_count_group,
        CASE
            WHEN COUNT(DISTINCT category) = 1 THEN 'single-category order'
            ELSE 'multi-category order'
        END AS category_mix_group,
        CASE
            WHEN SUM(loss_line_flag) = 0 THEN 'only profitable lines'
            WHEN SUM(profit_line_flag) = 0 THEN 'only loss-making lines'
            ELSE 'mixed profit/loss lines'
        END AS line_sign_mix_group,
        CASE
            WHEN SUM(Sales) < 100 THEN '<100 sales'
            WHEN SUM(Sales) < 500 THEN '100-499 sales'
            WHEN SUM(Sales) < 1000 THEN '500-999 sales'
            ELSE '1000+ sales'
        END AS order_sales_group
    FROM base
    GROUP BY "Order ID", Region
),
totals AS (
    SELECT
        COUNT(*) AS total_orders,
        SUM(line_count) AS total_rows,
        SUM(sales) AS total_sales,
        SUM(profit) AS total_profit,
        SUM(gross_loss) AS total_gross_loss,
        SUM(net_loss_order_flag) AS total_net_loss_orders,
        SUM(has_loss_line_flag) AS total_orders_with_loss_lines
    FROM order_summary
),
overall_order_quality AS (
    SELECT
        'all_orders' AS entity,
        'order_baseline' AS parent_entity,
        COUNT(*) AS order_count,
        SUM(line_count) AS row_count,
        SUM(CASE WHEN profit > 0 THEN 1 ELSE 0 END) AS profitable_order_count,
        SUM(net_loss_order_flag) AS net_loss_order_count,
        SUM(has_loss_line_flag) AS orders_with_loss_lines,
        SUM(CASE WHEN line_sign_mix_group = 'mixed profit/loss lines' THEN 1 ELSE 0 END) AS mixed_line_order_count,
        SUM(sales) AS sales,
        100.0 * SUM(sales) / NULLIF(MAX(t.total_sales), 0) AS sales_share_pct,
        SUM(profit) AS profit,
        100.0 * SUM(profit) / NULLIF(SUM(sales), 0) AS profit_margin_pct,
        AVG(avg_discount) AS avg_discount,
        AVG(max_discount) AS avg_max_discount,
        SUM(gross_loss) AS gross_loss,
        100.0 * SUM(gross_loss) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct,
        AVG(line_count) AS avg_line_count,
        AVG(category_count) AS avg_category_count
    FROM order_summary
    CROSS JOIN totals t
),
net_loss_order_comparison AS (
    SELECT
        CASE WHEN net_loss_order_flag = 1 THEN 'net-loss orders' ELSE 'net-profitable orders' END AS entity,
        'net_order_sign' AS parent_entity,
        COUNT(*) AS order_count,
        SUM(line_count) AS row_count,
        SUM(CASE WHEN profit > 0 THEN 1 ELSE 0 END) AS profitable_order_count,
        SUM(net_loss_order_flag) AS net_loss_order_count,
        SUM(has_loss_line_flag) AS orders_with_loss_lines,
        SUM(CASE WHEN line_sign_mix_group = 'mixed profit/loss lines' THEN 1 ELSE 0 END) AS mixed_line_order_count,
        SUM(sales) AS sales,
        100.0 * SUM(sales) / NULLIF(MAX(t.total_sales), 0) AS sales_share_pct,
        SUM(profit) AS profit,
        100.0 * SUM(profit) / NULLIF(SUM(sales), 0) AS profit_margin_pct,
        AVG(avg_discount) AS avg_discount,
        AVG(max_discount) AS avg_max_discount,
        SUM(gross_loss) AS gross_loss,
        100.0 * SUM(gross_loss) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct,
        AVG(line_count) AS avg_line_count,
        AVG(category_count) AS avg_category_count
    FROM order_summary
    CROSS JOIN totals t
    GROUP BY net_loss_order_flag
),
line_count_summary AS (
    SELECT
        line_count_group AS entity,
        'line_count_group' AS parent_entity,
        COUNT(*) AS order_count,
        SUM(line_count) AS row_count,
        SUM(CASE WHEN profit > 0 THEN 1 ELSE 0 END) AS profitable_order_count,
        SUM(net_loss_order_flag) AS net_loss_order_count,
        SUM(has_loss_line_flag) AS orders_with_loss_lines,
        SUM(CASE WHEN line_sign_mix_group = 'mixed profit/loss lines' THEN 1 ELSE 0 END) AS mixed_line_order_count,
        SUM(sales) AS sales,
        100.0 * SUM(sales) / NULLIF(MAX(t.total_sales), 0) AS sales_share_pct,
        SUM(profit) AS profit,
        100.0 * SUM(profit) / NULLIF(SUM(sales), 0) AS profit_margin_pct,
        AVG(avg_discount) AS avg_discount,
        AVG(max_discount) AS avg_max_discount,
        SUM(gross_loss) AS gross_loss,
        100.0 * SUM(gross_loss) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct,
        AVG(line_count) AS avg_line_count,
        AVG(category_count) AS avg_category_count
    FROM order_summary
    CROSS JOIN totals t
    GROUP BY line_count_group
),
category_mix_summary AS (
    SELECT
        category_mix_group AS entity,
        'category_mix_group' AS parent_entity,
        COUNT(*) AS order_count,
        SUM(line_count) AS row_count,
        SUM(CASE WHEN profit > 0 THEN 1 ELSE 0 END) AS profitable_order_count,
        SUM(net_loss_order_flag) AS net_loss_order_count,
        SUM(has_loss_line_flag) AS orders_with_loss_lines,
        SUM(CASE WHEN line_sign_mix_group = 'mixed profit/loss lines' THEN 1 ELSE 0 END) AS mixed_line_order_count,
        SUM(sales) AS sales,
        100.0 * SUM(sales) / NULLIF(MAX(t.total_sales), 0) AS sales_share_pct,
        SUM(profit) AS profit,
        100.0 * SUM(profit) / NULLIF(SUM(sales), 0) AS profit_margin_pct,
        AVG(avg_discount) AS avg_discount,
        AVG(max_discount) AS avg_max_discount,
        SUM(gross_loss) AS gross_loss,
        100.0 * SUM(gross_loss) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct,
        AVG(line_count) AS avg_line_count,
        AVG(category_count) AS avg_category_count
    FROM order_summary
    CROSS JOIN totals t
    GROUP BY category_mix_group
),
line_sign_mix_summary AS (
    SELECT
        line_sign_mix_group AS entity,
        'line_sign_mix_group' AS parent_entity,
        COUNT(*) AS order_count,
        SUM(line_count) AS row_count,
        SUM(CASE WHEN profit > 0 THEN 1 ELSE 0 END) AS profitable_order_count,
        SUM(net_loss_order_flag) AS net_loss_order_count,
        SUM(has_loss_line_flag) AS orders_with_loss_lines,
        SUM(CASE WHEN line_sign_mix_group = 'mixed profit/loss lines' THEN 1 ELSE 0 END) AS mixed_line_order_count,
        SUM(sales) AS sales,
        100.0 * SUM(sales) / NULLIF(MAX(t.total_sales), 0) AS sales_share_pct,
        SUM(profit) AS profit,
        100.0 * SUM(profit) / NULLIF(SUM(sales), 0) AS profit_margin_pct,
        AVG(avg_discount) AS avg_discount,
        AVG(max_discount) AS avg_max_discount,
        SUM(gross_loss) AS gross_loss,
        100.0 * SUM(gross_loss) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct,
        AVG(line_count) AS avg_line_count,
        AVG(category_count) AS avg_category_count
    FROM order_summary
    CROSS JOIN totals t
    GROUP BY line_sign_mix_group
),
sales_size_summary AS (
    SELECT
        order_sales_group AS entity,
        'order_sales_group' AS parent_entity,
        COUNT(*) AS order_count,
        SUM(line_count) AS row_count,
        SUM(CASE WHEN profit > 0 THEN 1 ELSE 0 END) AS profitable_order_count,
        SUM(net_loss_order_flag) AS net_loss_order_count,
        SUM(has_loss_line_flag) AS orders_with_loss_lines,
        SUM(CASE WHEN line_sign_mix_group = 'mixed profit/loss lines' THEN 1 ELSE 0 END) AS mixed_line_order_count,
        SUM(sales) AS sales,
        100.0 * SUM(sales) / NULLIF(MAX(t.total_sales), 0) AS sales_share_pct,
        SUM(profit) AS profit,
        100.0 * SUM(profit) / NULLIF(SUM(sales), 0) AS profit_margin_pct,
        AVG(avg_discount) AS avg_discount,
        AVG(max_discount) AS avg_max_discount,
        SUM(gross_loss) AS gross_loss,
        100.0 * SUM(gross_loss) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct,
        AVG(line_count) AS avg_line_count,
        AVG(category_count) AS avg_category_count
    FROM order_summary
    CROSS JOIN totals t
    GROUP BY order_sales_group
),
order_ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY sales DESC) AS rank_by_sales,
        ROW_NUMBER() OVER (ORDER BY profit DESC) AS rank_by_profit,
        ROW_NUMBER() OVER (ORDER BY profit ASC) AS rank_by_loss,
        ROW_NUMBER() OVER (ORDER BY gross_loss ASC) AS rank_by_gross_loss
    FROM order_summary
)
SELECT
    'G1' AS evidence_group_id,
    'order_profit_baseline' AS evidence_block,
    'order_baseline' AS entity_level,
    entity,
    parent_entity,
    order_count,
    row_count,
    profitable_order_count,
    net_loss_order_count,
    orders_with_loss_lines,
    mixed_line_order_count,
    ROUND(sales, 2) AS sales,
    ROUND(sales_share_pct, 2) AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    ROUND(avg_max_discount, 3) AS avg_max_discount,
    ROUND(gross_loss, 2) AS gross_loss,
    ROUND(gross_loss_share_pct, 2) AS gross_loss_share_pct,
    ROUND(avg_line_count, 2) AS avg_line_count,
    ROUND(avg_category_count, 2) AS avg_category_count,
    NULL AS rank_by_sales,
    NULL AS rank_by_profit,
    NULL AS rank_by_loss,
    'Order baseline: establish whether order-level net losses are a minority and how much sales/loss exposure they carry.' AS note
FROM overall_order_quality
UNION ALL
SELECT
    'G1' AS evidence_group_id,
    'order_profit_baseline' AS evidence_block,
    'net_order_sign' AS entity_level,
    entity,
    parent_entity,
    order_count,
    row_count,
    profitable_order_count,
    net_loss_order_count,
    orders_with_loss_lines,
    mixed_line_order_count,
    ROUND(sales, 2) AS sales,
    ROUND(sales_share_pct, 2) AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    ROUND(avg_max_discount, 3) AS avg_max_discount,
    ROUND(gross_loss, 2) AS gross_loss,
    ROUND(gross_loss_share_pct, 2) AS gross_loss_share_pct,
    ROUND(avg_line_count, 2) AS avg_line_count,
    ROUND(avg_category_count, 2) AS avg_category_count,
    NULL AS rank_by_sales,
    NULL AS rank_by_profit,
    NULL AS rank_by_loss,
    'Order baseline: compare net-loss orders with net-profitable orders.' AS note
FROM net_loss_order_comparison
UNION ALL
SELECT
    'G2' AS evidence_group_id,
    'line_count_order_complexity' AS evidence_block,
    'line_count_group' AS entity_level,
    entity,
    parent_entity,
    order_count,
    row_count,
    profitable_order_count,
    net_loss_order_count,
    orders_with_loss_lines,
    mixed_line_order_count,
    ROUND(sales, 2) AS sales,
    ROUND(sales_share_pct, 2) AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    ROUND(avg_max_discount, 3) AS avg_max_discount,
    ROUND(gross_loss, 2) AS gross_loss,
    ROUND(gross_loss_share_pct, 2) AS gross_loss_share_pct,
    ROUND(avg_line_count, 2) AS avg_line_count,
    ROUND(avg_category_count, 2) AS avg_category_count,
    NULL AS rank_by_sales,
    NULL AS rank_by_profit,
    NULL AS rank_by_loss,
    'Line-count complexity: test whether larger baskets by line count carry different profit quality than small orders.' AS note
FROM line_count_summary
UNION ALL
SELECT
    'G3' AS evidence_group_id,
    'category_mix_order_structure' AS evidence_block,
    'category_mix_group' AS entity_level,
    entity,
    parent_entity,
    order_count,
    row_count,
    profitable_order_count,
    net_loss_order_count,
    orders_with_loss_lines,
    mixed_line_order_count,
    ROUND(sales, 2) AS sales,
    ROUND(sales_share_pct, 2) AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    ROUND(avg_max_discount, 3) AS avg_max_discount,
    ROUND(gross_loss, 2) AS gross_loss,
    ROUND(gross_loss_share_pct, 2) AS gross_loss_share_pct,
    ROUND(avg_line_count, 2) AS avg_line_count,
    ROUND(avg_category_count, 2) AS avg_category_count,
    NULL AS rank_by_sales,
    NULL AS rank_by_profit,
    NULL AS rank_by_loss,
    'Category-mix structure: compare single-category and multi-category orders without assuming mixed baskets are automatically healthier.' AS note
FROM category_mix_summary
UNION ALL
SELECT
    'G4' AS evidence_group_id,
    'line_sign_mixing' AS evidence_block,
    'line_sign_mix_group' AS entity_level,
    entity,
    parent_entity,
    order_count,
    row_count,
    profitable_order_count,
    net_loss_order_count,
    orders_with_loss_lines,
    mixed_line_order_count,
    ROUND(sales, 2) AS sales,
    ROUND(sales_share_pct, 2) AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    ROUND(avg_max_discount, 3) AS avg_max_discount,
    ROUND(gross_loss, 2) AS gross_loss,
    ROUND(gross_loss_share_pct, 2) AS gross_loss_share_pct,
    ROUND(avg_line_count, 2) AS avg_line_count,
    ROUND(avg_category_count, 2) AS avg_category_count,
    NULL AS rank_by_sales,
    NULL AS rank_by_profit,
    NULL AS rank_by_loss,
    'Line-sign mixing: check whether order-level net profit hides loss-making lines inside the same basket.' AS note
FROM line_sign_mix_summary
UNION ALL
SELECT
    'G5' AS evidence_group_id,
    'large_order_sales_conversion' AS evidence_block,
    'order_sales_group' AS entity_level,
    entity,
    parent_entity,
    order_count,
    row_count,
    profitable_order_count,
    net_loss_order_count,
    orders_with_loss_lines,
    mixed_line_order_count,
    ROUND(sales, 2) AS sales,
    ROUND(sales_share_pct, 2) AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    ROUND(avg_max_discount, 3) AS avg_max_discount,
    ROUND(gross_loss, 2) AS gross_loss,
    ROUND(gross_loss_share_pct, 2) AS gross_loss_share_pct,
    ROUND(avg_line_count, 2) AS avg_line_count,
    ROUND(avg_category_count, 2) AS avg_category_count,
    NULL AS rank_by_sales,
    NULL AS rank_by_profit,
    NULL AS rank_by_loss,
    'Large-order conversion: test whether larger revenue orders reliably produce stronger margins.' AS note
FROM sales_size_summary
UNION ALL
SELECT
    'G5' AS evidence_group_id,
    'large_order_sales_conversion' AS evidence_block,
    'selected_order' AS entity_level,
    "Order ID" || ' / ' || Region AS entity,
    line_count_group || ' / ' || category_mix_group || ' / ' || line_sign_mix_group AS parent_entity,
    1 AS order_count,
    line_count AS row_count,
    CASE WHEN profit > 0 THEN 1 ELSE 0 END AS profitable_order_count,
    net_loss_order_flag AS net_loss_order_count,
    has_loss_line_flag AS orders_with_loss_lines,
    CASE WHEN line_sign_mix_group = 'mixed profit/loss lines' THEN 1 ELSE 0 END AS mixed_line_order_count,
    ROUND(sales, 2) AS sales,
    NULL AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    ROUND(max_discount, 3) AS avg_max_discount,
    ROUND(gross_loss, 2) AS gross_loss,
    NULL AS gross_loss_share_pct,
    line_count AS avg_line_count,
    category_count AS avg_category_count,
    rank_by_sales,
    rank_by_profit,
    rank_by_loss,
    'Selected high-impact orders: compare top-sales, top-profit, and worst-profit orders to avoid equating revenue with profit.' AS note
FROM order_ranked
WHERE rank_by_sales <= 15 OR rank_by_profit <= 15 OR rank_by_loss <= 15
ORDER BY evidence_group_id, evidence_block, entity_level, rank_by_loss NULLS LAST, rank_by_sales NULLS LAST, entity;
