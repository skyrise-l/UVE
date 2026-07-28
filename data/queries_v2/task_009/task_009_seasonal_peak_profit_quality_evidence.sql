-- task_009: seasonal peak profit quality evidence
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
        EXTRACT(YEAR FROM f."Order Date") AS order_year,
        EXTRACT(QUARTER FROM f."Order Date") AS order_quarter,
        EXTRACT(MONTH FROM f."Order Date") AS order_month,
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
month_raw AS (
    SELECT
        order_month,
        COUNT(DISTINCT "Order ID") AS orders,
        COUNT(*) AS order_lines,
        COUNT(DISTINCT "Customer ID") AS customers,
        COUNT(DISTINCT "Product ID") AS products,
        SUM(Sales) AS sales,
        SUM(Profit) AS profit,
        SUM(CASE WHEN Profit < 0 THEN -Profit ELSE 0 END) AS gross_loss,
        AVG(Discount) AS avg_discount,
        SUM(Quantity) AS quantity
    FROM fact
    GROUP BY order_month
),
month_metrics AS (
    SELECT
        *,
        profit / NULLIF(sales, 0) AS margin,
        sales / NULLIF(SUM(sales) OVER (), 0) AS sales_share,
        profit / NULLIF(SUM(profit) OVER (), 0) AS profit_share,
        gross_loss / NULLIF(SUM(gross_loss) OVER (), 0) AS gross_loss_share,
        ROW_NUMBER() OVER (ORDER BY sales DESC, profit DESC) AS sales_rank,
        ROW_NUMBER() OVER (ORDER BY profit DESC, sales DESC) AS profit_rank,
        ROW_NUMBER() OVER (ORDER BY profit / NULLIF(sales, 0) DESC, sales DESC) AS margin_rank,
        ROW_NUMBER() OVER (ORDER BY gross_loss DESC, sales DESC) AS gross_loss_rank
    FROM month_raw
),
quarter_raw AS (
    SELECT
        order_quarter,
        COUNT(DISTINCT "Order ID") AS orders,
        COUNT(*) AS order_lines,
        COUNT(DISTINCT "Customer ID") AS customers,
        COUNT(DISTINCT "Product ID") AS products,
        SUM(Sales) AS sales,
        SUM(Profit) AS profit,
        SUM(CASE WHEN Profit < 0 THEN -Profit ELSE 0 END) AS gross_loss,
        AVG(Discount) AS avg_discount,
        SUM(Quantity) AS quantity
    FROM fact
    GROUP BY order_quarter
),
quarter_metrics AS (
    SELECT
        *,
        profit / NULLIF(sales, 0) AS margin,
        sales / NULLIF(SUM(sales) OVER (), 0) AS sales_share,
        profit / NULLIF(SUM(profit) OVER (), 0) AS profit_share,
        gross_loss / NULLIF(SUM(gross_loss) OVER (), 0) AS gross_loss_share,
        ROW_NUMBER() OVER (ORDER BY sales DESC, profit DESC) AS sales_rank,
        ROW_NUMBER() OVER (ORDER BY profit DESC, sales DESC) AS profit_rank,
        ROW_NUMBER() OVER (ORDER BY profit / NULLIF(sales, 0) DESC, sales DESC) AS margin_rank,
        ROW_NUMBER() OVER (ORDER BY gross_loss DESC, sales DESC) AS gross_loss_rank
    FROM quarter_raw
),
busy_month_flag AS (
    SELECT
        f.*,
        CASE WHEN m.sales_rank <= 3 THEN 'top_3_sales_months' ELSE 'other_months' END AS busy_bucket
    FROM fact AS f
    JOIN month_metrics AS m
      ON f.order_month = m.order_month
),
busy_bucket_raw AS (
    SELECT
        busy_bucket,
        COUNT(DISTINCT "Order ID") AS orders,
        COUNT(*) AS order_lines,
        COUNT(DISTINCT "Customer ID") AS customers,
        COUNT(DISTINCT "Product ID") AS products,
        SUM(Sales) AS sales,
        SUM(Profit) AS profit,
        SUM(CASE WHEN Profit < 0 THEN -Profit ELSE 0 END) AS gross_loss,
        AVG(Discount) AS avg_discount,
        SUM(Quantity) AS quantity
    FROM busy_month_flag
    GROUP BY busy_bucket
),
busy_bucket AS (
    SELECT
        *,
        profit / NULLIF(sales, 0) AS margin,
        sales / NULLIF(SUM(sales) OVER (), 0) AS sales_share,
        profit / NULLIF(SUM(profit) OVER (), 0) AS profit_share,
        gross_loss / NULLIF(SUM(gross_loss) OVER (), 0) AS gross_loss_share
    FROM busy_bucket_raw
),
category_month_raw AS (
    SELECT
        Category,
        order_month,
        COUNT(DISTINCT "Order ID") AS orders,
        COUNT(*) AS order_lines,
        COUNT(DISTINCT "Product ID") AS products,
        SUM(Sales) AS sales,
        SUM(Profit) AS profit,
        SUM(CASE WHEN Profit < 0 THEN -Profit ELSE 0 END) AS gross_loss,
        AVG(Discount) AS avg_discount
    FROM fact
    GROUP BY Category, order_month
),
category_month_ranked AS (
    SELECT
        *,
        profit / NULLIF(sales, 0) AS margin,
        ROW_NUMBER() OVER (PARTITION BY Category ORDER BY sales DESC, profit DESC) AS category_sales_month_rank,
        ROW_NUMBER() OVER (PARTITION BY Category ORDER BY profit DESC, sales DESC) AS category_profit_month_rank,
        ROW_NUMBER() OVER (PARTITION BY Category ORDER BY profit / NULLIF(sales, 0) DESC, sales DESC) AS category_margin_month_rank,
        ROW_NUMBER() OVER (PARTITION BY Category ORDER BY gross_loss DESC, sales DESC) AS category_gross_loss_month_rank
    FROM category_month_raw
),
region_month_raw AS (
    SELECT
        Region,
        order_month,
        COUNT(DISTINCT "Order ID") AS orders,
        COUNT(*) AS order_lines,
        COUNT(DISTINCT "Customer ID") AS customers,
        SUM(Sales) AS sales,
        SUM(Profit) AS profit,
        SUM(CASE WHEN Profit < 0 THEN -Profit ELSE 0 END) AS gross_loss,
        AVG(Discount) AS avg_discount
    FROM fact
    GROUP BY Region, order_month
),
region_month_ranked AS (
    SELECT
        *,
        profit / NULLIF(sales, 0) AS margin,
        ROW_NUMBER() OVER (PARTITION BY Region ORDER BY sales DESC, profit DESC) AS region_sales_month_rank,
        ROW_NUMBER() OVER (PARTITION BY Region ORDER BY profit DESC, sales DESC) AS region_profit_month_rank,
        ROW_NUMBER() OVER (PARTITION BY Region ORDER BY profit / NULLIF(sales, 0) DESC, sales DESC) AS region_margin_month_rank,
        ROW_NUMBER() OVER (PARTITION BY Region ORDER BY gross_loss DESC, sales DESC) AS region_gross_loss_month_rank
    FROM region_month_raw
),
top_sales_month AS (
    SELECT order_month
    FROM month_metrics
    WHERE sales_rank = 1
),
peak_month_category_mix_raw AS (
    SELECT
        f.Category,
        COUNT(DISTINCT f."Order ID") AS orders,
        COUNT(*) AS order_lines,
        COUNT(DISTINCT f."Product ID") AS products,
        SUM(f.Sales) AS sales,
        SUM(f.Profit) AS profit,
        SUM(CASE WHEN f.Profit < 0 THEN -f.Profit ELSE 0 END) AS gross_loss,
        AVG(f.Discount) AS avg_discount
    FROM fact AS f
    JOIN top_sales_month AS t
      ON f.order_month = t.order_month
    GROUP BY f.Category
),
peak_month_category_mix AS (
    SELECT
        *,
        profit / NULLIF(sales, 0) AS margin,
        sales / NULLIF(SUM(sales) OVER (), 0) AS sales_share,
        profit / NULLIF(SUM(profit) OVER (), 0) AS profit_share,
        gross_loss / NULLIF(SUM(gross_loss) OVER (), 0) AS gross_loss_share
    FROM peak_month_category_mix_raw
)
SELECT
    'monthly_profit_quality' AS evidence_block,
    'month' AS grain,
    CAST(order_month AS VARCHAR) AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    'all_years' AS period,
    'sales_rank' AS rank_label,
    CAST(sales_rank AS DOUBLE) AS rank_value,
    ROUND(sales, 2) AS sales,
    ROUND(profit, 2) AS profit,
    ROUND(margin, 4) AS margin,
    ROUND(gross_loss, 2) AS gross_loss,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(customers AS BIGINT) AS customers,
    CAST(products AS BIGINT) AS products,
    ROUND(avg_discount, 4) AS avg_discount,
    CAST(quantity AS DOUBLE) AS quantity,
    ROUND(sales_share, 4) AS sales_share,
    ROUND(profit_share, 4) AS profit_share,
    ROUND(gross_loss_share, 4) AS gross_loss_share,
    'profit_rank' AS extra_metric_1,
    CAST(profit_rank AS DOUBLE) AS extra_value_1,
    'margin_rank' AS extra_metric_2,
    CAST(margin_rank AS DOUBLE) AS extra_value_2,
    'Use this block to identify sales, profit, margin, and gross-loss seasonal peaks by month.' AS notes
FROM month_metrics
UNION ALL
SELECT
    'quarterly_profit_quality' AS evidence_block,
    'quarter' AS grain,
    'Q' || CAST(order_quarter AS VARCHAR) AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    'all_years' AS period,
    'sales_rank' AS rank_label,
    CAST(sales_rank AS DOUBLE) AS rank_value,
    ROUND(sales, 2) AS sales,
    ROUND(profit, 2) AS profit,
    ROUND(margin, 4) AS margin,
    ROUND(gross_loss, 2) AS gross_loss,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(customers AS BIGINT) AS customers,
    CAST(products AS BIGINT) AS products,
    ROUND(avg_discount, 4) AS avg_discount,
    CAST(quantity AS DOUBLE) AS quantity,
    ROUND(sales_share, 4) AS sales_share,
    ROUND(profit_share, 4) AS profit_share,
    ROUND(gross_loss_share, 4) AS gross_loss_share,
    'profit_rank' AS extra_metric_1,
    CAST(profit_rank AS DOUBLE) AS extra_value_1,
    'margin_rank' AS extra_metric_2,
    CAST(margin_rank AS DOUBLE) AS extra_value_2,
    'Use this block to check whether the seasonal story is clearer by quarter than by month.' AS notes
FROM quarter_metrics
UNION ALL
SELECT
    'busy_vs_other_months' AS evidence_block,
    'month_bucket' AS grain,
    busy_bucket AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    'all_years' AS period,
    CAST(NULL AS VARCHAR) AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    ROUND(sales, 2) AS sales,
    ROUND(profit, 2) AS profit,
    ROUND(margin, 4) AS margin,
    ROUND(gross_loss, 2) AS gross_loss,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(customers AS BIGINT) AS customers,
    CAST(products AS BIGINT) AS products,
    ROUND(avg_discount, 4) AS avg_discount,
    CAST(quantity AS DOUBLE) AS quantity,
    ROUND(sales_share, 4) AS sales_share,
    ROUND(profit_share, 4) AS profit_share,
    ROUND(gross_loss_share, 4) AS gross_loss_share,
    CAST(NULL AS VARCHAR) AS extra_metric_1,
    CAST(NULL AS DOUBLE) AS extra_value_1,
    CAST(NULL AS VARCHAR) AS extra_metric_2,
    CAST(NULL AS DOUBLE) AS extra_value_2,
    'Use this block to compare the top sales months against all other months.' AS notes
FROM busy_bucket
UNION ALL
SELECT
    'category_seasonal_peaks' AS evidence_block,
    'category_month' AS grain,
    Category AS item,
    CAST(order_month AS VARCHAR) AS item_2,
    'all_years' AS period,
    CASE
        WHEN category_sales_month_rank = 1 THEN 'category_sales_peak'
        WHEN category_margin_month_rank = 1 THEN 'category_margin_peak'
        WHEN category_gross_loss_month_rank = 1 THEN 'category_gross_loss_peak'
        ELSE 'selected_category_month'
    END AS rank_label,
    CAST(LEAST(category_sales_month_rank, category_margin_month_rank, category_gross_loss_month_rank) AS DOUBLE) AS rank_value,
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
    CAST(NULL AS DOUBLE) AS sales_share,
    CAST(NULL AS DOUBLE) AS profit_share,
    CAST(NULL AS DOUBLE) AS gross_loss_share,
    'sales_rank_within_category' AS extra_metric_1,
    CAST(category_sales_month_rank AS DOUBLE) AS extra_value_1,
    'margin_rank_within_category' AS extra_metric_2,
    CAST(category_margin_month_rank AS DOUBLE) AS extra_value_2,
    'Use this block to see whether category sales peaks align with category margin or loss peaks.' AS notes
FROM category_month_ranked
WHERE category_sales_month_rank = 1 OR category_margin_month_rank = 1 OR category_gross_loss_month_rank = 1
UNION ALL
SELECT
    'region_seasonal_peaks' AS evidence_block,
    'region_month' AS grain,
    Region AS item,
    CAST(order_month AS VARCHAR) AS item_2,
    'all_years' AS period,
    CASE
        WHEN region_sales_month_rank = 1 THEN 'region_sales_peak'
        WHEN region_margin_month_rank = 1 THEN 'region_margin_peak'
        WHEN region_gross_loss_month_rank = 1 THEN 'region_gross_loss_peak'
        ELSE 'selected_region_month'
    END AS rank_label,
    CAST(LEAST(region_sales_month_rank, region_margin_month_rank, region_gross_loss_month_rank) AS DOUBLE) AS rank_value,
    ROUND(sales, 2) AS sales,
    ROUND(profit, 2) AS profit,
    ROUND(margin, 4) AS margin,
    ROUND(gross_loss, 2) AS gross_loss,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(customers AS BIGINT) AS customers,
    CAST(NULL AS BIGINT) AS products,
    ROUND(avg_discount, 4) AS avg_discount,
    CAST(NULL AS DOUBLE) AS quantity,
    CAST(NULL AS DOUBLE) AS sales_share,
    CAST(NULL AS DOUBLE) AS profit_share,
    CAST(NULL AS DOUBLE) AS gross_loss_share,
    'sales_rank_within_region' AS extra_metric_1,
    CAST(region_sales_month_rank AS DOUBLE) AS extra_value_1,
    'margin_rank_within_region' AS extra_metric_2,
    CAST(region_margin_month_rank AS DOUBLE) AS extra_value_2,
    'Use this block to see whether regional peaks align or diverge.' AS notes
FROM region_month_ranked
WHERE region_sales_month_rank = 1 OR region_margin_month_rank = 1 OR region_gross_loss_month_rank = 1
UNION ALL
SELECT
    'peak_month_category_mix' AS evidence_block,
    'category_in_top_sales_month' AS grain,
    Category AS item,
    CAST((SELECT order_month FROM top_sales_month) AS VARCHAR) AS item_2,
    'top_sales_month' AS period,
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
    ROUND(sales_share, 4) AS sales_share,
    ROUND(profit_share, 4) AS profit_share,
    ROUND(gross_loss_share, 4) AS gross_loss_share,
    CAST(NULL AS VARCHAR) AS extra_metric_1,
    CAST(NULL AS DOUBLE) AS extra_value_1,
    CAST(NULL AS VARCHAR) AS extra_metric_2,
    CAST(NULL AS DOUBLE) AS extra_value_2,
    'Use this block to identify what product mix drives the busiest month.' AS notes
FROM peak_month_category_mix
ORDER BY evidence_block, grain, rank_value, item, item_2;
