-- task_010: cross-category bundle quality evidence
-- Final evidence SQL. Gold claims calibrated from full CSV results.

WITH all_lines AS (
    SELECT * FROM central_superstore
    UNION ALL
    SELECT * FROM east_superstore
    UNION ALL
    SELECT * FROM south_superstore
    UNION ALL
    SELECT * FROM west_superstore
),
fact AS (
    SELECT
        f."Row ID",
        f."Order ID",
        f."Order Date",
        f."Customer ID",
        f.Region,
        f."Product ID",
        p.Category,
        p."Sub-Category",
        f.Sales,
        f.Quantity,
        f.Discount,
        f.Profit
    FROM all_lines AS f
    LEFT JOIN product AS p
      ON f."Product ID" = p."Product ID"
     AND f.Region = p.Region
),
order_category AS (
    SELECT
        "Order ID",
        Category,
        COUNT(*) AS category_lines,
        COUNT(DISTINCT "Product ID") AS category_products,
        SUM(Sales) AS category_sales,
        SUM(Profit) AS category_profit,
        SUM(CASE WHEN Profit < 0 THEN -Profit ELSE 0 END) AS category_gross_loss,
        AVG(Discount) AS category_avg_discount,
        SUM(Quantity) AS category_quantity
    FROM fact
    GROUP BY "Order ID", Category
),
order_combo_raw AS (
    SELECT
        "Order ID",
        COUNT(DISTINCT Category) AS category_count,
        MAX(CASE WHEN Category = 'Furniture' THEN 1 ELSE 0 END) AS has_furniture,
        MAX(CASE WHEN Category = 'Office Supplies' THEN 1 ELSE 0 END) AS has_office_supplies,
        MAX(CASE WHEN Category = 'Technology' THEN 1 ELSE 0 END) AS has_technology,
        SUM(category_lines) AS order_lines,
        SUM(category_products) AS products,
        SUM(category_sales) AS sales,
        SUM(category_profit) AS profit,
        SUM(category_gross_loss) AS gross_loss,
        SUM(category_quantity) AS quantity,
        AVG(category_avg_discount) AS avg_discount,
        SUM(CASE WHEN category_profit > 0 THEN 1 ELSE 0 END) AS positive_categories,
        SUM(CASE WHEN category_profit < 0 THEN 1 ELSE 0 END) AS negative_categories
    FROM order_category
    GROUP BY "Order ID"
),
order_combo AS (
    SELECT
        *,
        CASE
            WHEN has_furniture = 1 AND has_office_supplies = 0 AND has_technology = 0 THEN 'Furniture only'
            WHEN has_furniture = 0 AND has_office_supplies = 1 AND has_technology = 0 THEN 'Office Supplies only'
            WHEN has_furniture = 0 AND has_office_supplies = 0 AND has_technology = 1 THEN 'Technology only'
            WHEN has_furniture = 1 AND has_office_supplies = 1 AND has_technology = 0 THEN 'Furniture + Office Supplies'
            WHEN has_furniture = 1 AND has_office_supplies = 0 AND has_technology = 1 THEN 'Furniture + Technology'
            WHEN has_furniture = 0 AND has_office_supplies = 1 AND has_technology = 1 THEN 'Office Supplies + Technology'
            WHEN has_furniture = 1 AND has_office_supplies = 1 AND has_technology = 1 THEN 'Furniture + Office Supplies + Technology'
            ELSE 'Unclassified'
        END AS combo_label,
        CASE WHEN category_count = 1 THEN 'single_category' ELSE 'multi_category' END AS combo_width,
        profit / NULLIF(sales, 0) AS margin
    FROM order_combo_raw
),
combo_metrics_raw AS (
    SELECT
        combo_label,
        combo_width,
        MIN(category_count) AS category_count,
        MAX(has_furniture) AS has_furniture,
        MAX(has_office_supplies) AS has_office_supplies,
        MAX(has_technology) AS has_technology,
        COUNT(*) AS orders,
        SUM(order_lines) AS order_lines,
        SUM(products) AS products,
        SUM(sales) AS sales,
        SUM(profit) AS profit,
        SUM(gross_loss) AS gross_loss,
        SUM(quantity) AS quantity,
        AVG(avg_discount) AS avg_discount,
        SUM(CASE WHEN profit < 0 THEN 1 ELSE 0 END) AS net_loss_orders,
        SUM(CASE WHEN positive_categories > 0 AND negative_categories > 0 THEN 1 ELSE 0 END) AS mixed_category_sign_orders
    FROM order_combo
    GROUP BY combo_label, combo_width
),
combo_metrics AS (
    SELECT
        *,
        profit / NULLIF(sales, 0) AS margin,
        sales / NULLIF(SUM(sales) OVER (), 0) AS sales_share,
        profit / NULLIF(SUM(profit) OVER (), 0) AS profit_share,
        gross_loss / NULLIF(SUM(gross_loss) OVER (), 0) AS gross_loss_share,
        net_loss_orders * 1.0 / NULLIF(orders, 0) AS net_loss_order_rate,
        mixed_category_sign_orders * 1.0 / NULLIF(orders, 0) AS mixed_category_sign_rate,
        ROW_NUMBER() OVER (ORDER BY sales DESC, profit DESC) AS sales_rank,
        ROW_NUMBER() OVER (ORDER BY profit / NULLIF(sales, 0) DESC, sales DESC) AS margin_rank,
        ROW_NUMBER() OVER (ORDER BY gross_loss DESC, sales DESC) AS gross_loss_rank
    FROM combo_metrics_raw
),
single_category_metrics AS (
    SELECT
        CASE
            WHEN combo_label = 'Furniture only' THEN 'Furniture'
            WHEN combo_label = 'Office Supplies only' THEN 'Office Supplies'
            WHEN combo_label = 'Technology only' THEN 'Technology'
            ELSE NULL
        END AS Category,
        sales AS single_sales,
        profit AS single_profit,
        margin AS single_margin,
        gross_loss AS single_gross_loss
    FROM combo_metrics
    WHERE combo_width = 'single_category'
),
combo_components AS (
    SELECT combo_label, combo_width, 'Furniture' AS Category FROM combo_metrics WHERE has_furniture = 1
    UNION ALL
    SELECT combo_label, combo_width, 'Office Supplies' AS Category FROM combo_metrics WHERE has_office_supplies = 1
    UNION ALL
    SELECT combo_label, combo_width, 'Technology' AS Category FROM combo_metrics WHERE has_technology = 1
),
combo_vs_single AS (
    SELECT
        c.combo_label,
        c.combo_width,
        c.category_count,
        c.sales,
        c.profit,
        c.margin,
        c.gross_loss,
        c.orders,
        c.order_lines,
        c.avg_discount,
        MIN(s.single_margin) AS lowest_component_single_margin,
        MAX(s.single_margin) AS highest_component_single_margin,
        AVG(s.single_margin) AS avg_component_single_margin,
        c.margin - AVG(s.single_margin) AS margin_vs_avg_single_component
    FROM combo_metrics AS c
    JOIN combo_components AS cc
      ON c.combo_label = cc.combo_label
    LEFT JOIN single_category_metrics AS s
      ON cc.Category = s.Category
    GROUP BY c.combo_label, c.combo_width, c.category_count, c.sales, c.profit, c.margin, c.gross_loss, c.orders, c.order_lines, c.avg_discount
),
combo_category_contribution_raw AS (
    SELECT
        oc.combo_label,
        cat.Category,
        COUNT(DISTINCT cat."Order ID") AS orders,
        SUM(cat.category_lines) AS order_lines,
        SUM(cat.category_products) AS products,
        SUM(cat.category_sales) AS sales,
        SUM(cat.category_profit) AS profit,
        SUM(cat.category_gross_loss) AS gross_loss,
        AVG(cat.category_avg_discount) AS avg_discount
    FROM order_combo AS oc
    JOIN order_category AS cat
      ON oc."Order ID" = cat."Order ID"
    GROUP BY oc.combo_label, cat.Category
),
combo_category_contribution AS (
    SELECT
        cc.*,
        cc.profit / NULLIF(cc.sales, 0) AS margin,
        cm.sales AS combo_sales,
        cm.profit AS combo_profit,
        cm.gross_loss AS combo_gross_loss,
        cc.sales / NULLIF(cm.sales, 0) AS combo_sales_share,
        cc.profit / NULLIF(cm.profit, 0) AS combo_profit_share,
        cc.gross_loss / NULLIF(cm.gross_loss, 0) AS combo_gross_loss_share
    FROM combo_category_contribution_raw AS cc
    JOIN combo_metrics AS cm
      ON cc.combo_label = cm.combo_label
),
combo_sign_metrics AS (
    SELECT
        combo_label,
        combo_width,
        CASE
            WHEN positive_categories > 0 AND negative_categories > 0 THEN 'mixed_positive_negative_categories'
            WHEN negative_categories > 0 AND positive_categories = 0 THEN 'only_negative_categories'
            WHEN positive_categories > 0 AND negative_categories = 0 THEN 'only_positive_categories'
            ELSE 'zero_profit_categories_only'
        END AS category_sign_pattern,
        COUNT(*) AS orders,
        SUM(order_lines) AS order_lines,
        SUM(products) AS products,
        SUM(sales) AS sales,
        SUM(profit) AS profit,
        SUM(gross_loss) AS gross_loss,
        AVG(avg_discount) AS avg_discount
    FROM order_combo
    GROUP BY combo_label, combo_width, category_sign_pattern
),
combo_loss_examples AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY gross_loss DESC, sales DESC, "Order ID") AS gross_loss_rank
    FROM order_combo
    WHERE combo_width = 'multi_category'
)
SELECT
    'combo_performance_baseline' AS evidence_block,
    'category_combo' AS grain,
    combo_label AS item,
    combo_width AS item_2,
    CAST(NULL AS VARCHAR) AS period,
    'sales_rank' AS rank_label,
    CAST(sales_rank AS DOUBLE) AS rank_value,
    ROUND(sales, 2) AS sales,
    ROUND(profit, 2) AS profit,
    ROUND(margin, 4) AS margin,
    ROUND(gross_loss, 2) AS gross_loss,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(NULL AS BIGINT) AS customers,
    CAST(products AS BIGINT) AS products,
    ROUND(avg_discount, 4) AS avg_discount,
    CAST(quantity AS DOUBLE) AS quantity,
    ROUND(sales_share, 4) AS sales_share,
    ROUND(profit_share, 4) AS profit_share,
    ROUND(gross_loss_share, 4) AS gross_loss_share,
    'net_loss_order_rate' AS extra_metric_1,
    ROUND(net_loss_order_rate, 4) AS extra_value_1,
    'mixed_category_sign_rate' AS extra_metric_2,
    ROUND(mixed_category_sign_rate, 4) AS extra_value_2,
    'Use this block to compare specific category combinations, not just single vs multi-category orders.' AS notes
FROM combo_metrics
UNION ALL
SELECT
    'combo_vs_single_baseline' AS evidence_block,
    'category_combo_vs_single_components' AS grain,
    combo_label AS item,
    combo_width AS item_2,
    CAST(NULL AS VARCHAR) AS period,
    CAST(NULL AS VARCHAR) AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    ROUND(sales, 2) AS sales,
    ROUND(profit, 2) AS profit,
    ROUND(margin, 4) AS margin,
    ROUND(gross_loss, 2) AS gross_loss,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(NULL AS BIGINT) AS customers,
    CAST(NULL AS BIGINT) AS products,
    ROUND(avg_discount, 4) AS avg_discount,
    CAST(NULL AS DOUBLE) AS quantity,
    CAST(NULL AS DOUBLE) AS sales_share,
    CAST(NULL AS DOUBLE) AS profit_share,
    CAST(NULL AS DOUBLE) AS gross_loss_share,
    'avg_component_single_margin' AS extra_metric_1,
    ROUND(avg_component_single_margin, 4) AS extra_value_1,
    'margin_vs_avg_single_component' AS extra_metric_2,
    ROUND(margin_vs_avg_single_component, 4) AS extra_value_2,
    'Use this block to assess whether combining categories improves or dilutes the margin relative to single-category baselines.' AS notes
FROM combo_vs_single
UNION ALL
SELECT
    'combo_category_contribution' AS evidence_block,
    'category_inside_combo' AS grain,
    combo_label AS item,
    Category AS item_2,
    CAST(NULL AS VARCHAR) AS period,
    CAST(NULL AS VARCHAR) AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    ROUND(sales, 2) AS sales,
    ROUND(profit, 2) AS profit,
    ROUND(margin, 4) AS margin,
    ROUND(gross_loss, 2) AS gross_loss,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(NULL AS BIGINT) AS customers,
    CAST(products AS BIGINT) AS products,
    ROUND(avg_discount, 4) AS avg_discount,
    CAST(NULL AS DOUBLE) AS quantity,
    ROUND(combo_sales_share, 4) AS sales_share,
    ROUND(combo_profit_share, 4) AS profit_share,
    ROUND(combo_gross_loss_share, 4) AS gross_loss_share,
    CAST(NULL AS VARCHAR) AS extra_metric_1,
    CAST(NULL AS DOUBLE) AS extra_value_1,
    CAST(NULL AS VARCHAR) AS extra_metric_2,
    CAST(NULL AS DOUBLE) AS extra_value_2,
    'Use this block to identify which category inside each combination carries profit or loss.' AS notes
FROM combo_category_contribution
UNION ALL
SELECT
    'combo_category_sign_patterns' AS evidence_block,
    'combo_by_category_profit_sign' AS grain,
    combo_label AS item,
    category_sign_pattern AS item_2,
    CAST(NULL AS VARCHAR) AS period,
    CAST(NULL AS VARCHAR) AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    ROUND(sales, 2) AS sales,
    ROUND(profit, 2) AS profit,
    ROUND(profit / NULLIF(sales, 0), 4) AS margin,
    ROUND(gross_loss, 2) AS gross_loss,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(NULL AS BIGINT) AS customers,
    CAST(products AS BIGINT) AS products,
    ROUND(avg_discount, 4) AS avg_discount,
    CAST(NULL AS DOUBLE) AS quantity,
    CAST(NULL AS DOUBLE) AS sales_share,
    CAST(NULL AS DOUBLE) AS profit_share,
    CAST(NULL AS DOUBLE) AS gross_loss_share,
    CAST(NULL AS VARCHAR) AS extra_metric_1,
    CAST(NULL AS DOUBLE) AS extra_value_1,
    CAST(NULL AS VARCHAR) AS extra_metric_2,
    CAST(NULL AS DOUBLE) AS extra_value_2,
    'Use this block to separate clean category combinations from combinations where one category subsidizes another.' AS notes
FROM combo_sign_metrics
UNION ALL
SELECT
    'top_multicategory_loss_examples' AS evidence_block,
    'multi_category_order_example' AS grain,
    "Order ID" AS item,
    combo_label AS item_2,
    CAST(NULL AS VARCHAR) AS period,
    'gross_loss_rank' AS rank_label,
    CAST(gross_loss_rank AS DOUBLE) AS rank_value,
    ROUND(sales, 2) AS sales,
    ROUND(profit, 2) AS profit,
    ROUND(margin, 4) AS margin,
    ROUND(gross_loss, 2) AS gross_loss,
    CAST(1 AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(NULL AS BIGINT) AS customers,
    CAST(products AS BIGINT) AS products,
    ROUND(avg_discount, 4) AS avg_discount,
    CAST(quantity AS DOUBLE) AS quantity,
    CAST(NULL AS DOUBLE) AS sales_share,
    CAST(NULL AS DOUBLE) AS profit_share,
    CAST(NULL AS DOUBLE) AS gross_loss_share,
    'category_count' AS extra_metric_1,
    CAST(category_count AS DOUBLE) AS extra_value_1,
    'negative_categories' AS extra_metric_2,
    CAST(negative_categories AS DOUBLE) AS extra_value_2,
    'Use this block only as supporting examples for high-loss multi-category combinations.' AS notes
FROM combo_loss_examples
WHERE gross_loss_rank <= 25
ORDER BY evidence_block, grain, rank_value, item, item_2;
