-- task_008: geographic market expansion quality evidence
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
        f."Customer ID",
        p.Segment,
        p.City,
        p.State,
        f.Region,
        f."Product ID",
        f.Sales,
        f.Quantity,
        f.Discount,
        f.Profit
    FROM all_lines AS f
    LEFT JOIN people AS p
      ON f."Customer ID" = p."Customer ID"
     AND f.Region = p.Region
),
year_bounds AS (
    SELECT
        MIN(order_year) AS min_year,
        MAX(order_year) AS max_year,
        MIN(order_year) + CAST(FLOOR((MAX(order_year) - MIN(order_year)) / 2.0) AS INTEGER) AS split_year
    FROM fact
),
periodized AS (
    SELECT
        f.*,
        CASE WHEN f.order_year <= y.split_year THEN 'early_period' ELSE 'late_period' END AS expansion_period
    FROM fact AS f
    CROSS JOIN year_bounds AS y
),
overall_period_raw AS (
    SELECT
        expansion_period,
        MIN(order_year) AS first_year,
        MAX(order_year) AS last_year,
        COUNT(DISTINCT "Order ID") AS orders,
        COUNT(*) AS order_lines,
        COUNT(DISTINCT "Customer ID") AS customers,
        COUNT(DISTINCT State) AS states,
        COUNT(DISTINCT City) AS cities,
        SUM(Sales) AS sales,
        SUM(Profit) AS profit,
        SUM(CASE WHEN Profit < 0 THEN -Profit ELSE 0 END) AS gross_loss,
        AVG(Discount) AS avg_discount
    FROM periodized
    GROUP BY expansion_period
),
overall_period AS (
    SELECT
        *,
        profit / NULLIF(sales, 0) AS margin,
        sales / NULLIF(SUM(sales) OVER (), 0) AS sales_share,
        profit / NULLIF(SUM(profit) OVER (), 0) AS profit_share,
        gross_loss / NULLIF(SUM(gross_loss) OVER (), 0) AS gross_loss_share
    FROM overall_period_raw
),
state_period AS (
    SELECT
        State,
        Region,
        expansion_period,
        COUNT(DISTINCT "Order ID") AS orders,
        COUNT(*) AS order_lines,
        COUNT(DISTINCT "Customer ID") AS customers,
        SUM(Sales) AS sales,
        SUM(Profit) AS profit,
        SUM(CASE WHEN Profit < 0 THEN -Profit ELSE 0 END) AS gross_loss,
        AVG(Discount) AS avg_discount
    FROM periodized
    GROUP BY State, Region, expansion_period
),
state_compare AS (
    SELECT
        State,
        Region,
        SUM(CASE WHEN expansion_period = 'early_period' THEN sales ELSE 0 END) AS early_sales,
        SUM(CASE WHEN expansion_period = 'late_period' THEN sales ELSE 0 END) AS late_sales,
        SUM(CASE WHEN expansion_period = 'early_period' THEN profit ELSE 0 END) AS early_profit,
        SUM(CASE WHEN expansion_period = 'late_period' THEN profit ELSE 0 END) AS late_profit,
        SUM(CASE WHEN expansion_period = 'early_period' THEN gross_loss ELSE 0 END) AS early_gross_loss,
        SUM(CASE WHEN expansion_period = 'late_period' THEN gross_loss ELSE 0 END) AS late_gross_loss,
        SUM(CASE WHEN expansion_period = 'early_period' THEN orders ELSE 0 END) AS early_orders,
        SUM(CASE WHEN expansion_period = 'late_period' THEN orders ELSE 0 END) AS late_orders,
        SUM(CASE WHEN expansion_period = 'early_period' THEN order_lines ELSE 0 END) AS early_order_lines,
        SUM(CASE WHEN expansion_period = 'late_period' THEN order_lines ELSE 0 END) AS late_order_lines,
        AVG(CASE WHEN expansion_period = 'early_period' THEN avg_discount ELSE NULL END) AS early_avg_discount,
        AVG(CASE WHEN expansion_period = 'late_period' THEN avg_discount ELSE NULL END) AS late_avg_discount
    FROM state_period
    GROUP BY State, Region
),
state_growth AS (
    SELECT
        *,
        late_sales - early_sales AS sales_change,
        late_profit - early_profit AS profit_change,
        late_gross_loss - early_gross_loss AS gross_loss_change,
        early_profit / NULLIF(early_sales, 0) AS early_margin,
        late_profit / NULLIF(late_sales, 0) AS late_margin,
        (late_profit / NULLIF(late_sales, 0)) - (early_profit / NULLIF(early_sales, 0)) AS margin_change,
        (late_sales - early_sales) / NULLIF(early_sales, 0) AS sales_growth_rate,
        (late_profit - early_profit) / NULLIF(ABS(early_profit), 0) AS profit_growth_rate
    FROM state_compare
),
late_overall AS (
    SELECT
        SUM(late_sales) AS late_sales,
        SUM(late_profit) AS late_profit,
        SUM(late_profit) / NULLIF(SUM(late_sales), 0) AS late_margin
    FROM state_growth
),
state_growth_ranked AS (
    SELECT
        s.*,
        ROW_NUMBER() OVER (ORDER BY sales_change DESC, late_sales DESC) AS sales_change_rank,
        ROW_NUMBER() OVER (ORDER BY profit_change DESC, late_profit DESC) AS profit_change_rank,
        ROW_NUMBER() OVER (ORDER BY margin_change DESC, late_sales DESC) AS margin_change_rank,
        ROW_NUMBER() OVER (ORDER BY late_gross_loss DESC, late_sales DESC) AS late_gross_loss_rank,
        CASE
            WHEN sales_change > 0 AND profit_change > 0 AND late_margin >= (SELECT late_margin FROM late_overall) THEN 'healthy_growth'
            WHEN sales_change > 0 AND (profit_change <= 0 OR late_margin < (SELECT late_margin FROM late_overall)) THEN 'scale_without_matching_quality'
            WHEN sales_change <= 0 AND profit_change > 0 THEN 'profit_improved_without_sales_growth'
            ELSE 'weak_or_contracting'
        END AS growth_quadrant
    FROM state_growth AS s
),
growth_quadrant_metrics AS (
    SELECT
        growth_quadrant,
        COUNT(*) AS states,
        SUM(late_sales) AS late_sales,
        SUM(late_profit) AS late_profit,
        SUM(late_gross_loss) AS late_gross_loss,
        SUM(sales_change) AS sales_change,
        SUM(profit_change) AS profit_change,
        AVG(late_avg_discount) AS late_avg_discount
    FROM state_growth_ranked
    GROUP BY growth_quadrant
),
city_period AS (
    SELECT
        City,
        State,
        Region,
        expansion_period,
        COUNT(DISTINCT "Order ID") AS orders,
        COUNT(*) AS order_lines,
        COUNT(DISTINCT "Customer ID") AS customers,
        SUM(Sales) AS sales,
        SUM(Profit) AS profit,
        SUM(CASE WHEN Profit < 0 THEN -Profit ELSE 0 END) AS gross_loss,
        AVG(Discount) AS avg_discount
    FROM periodized
    GROUP BY City, State, Region, expansion_period
),
city_compare AS (
    SELECT
        City,
        State,
        Region,
        SUM(CASE WHEN expansion_period = 'early_period' THEN sales ELSE 0 END) AS early_sales,
        SUM(CASE WHEN expansion_period = 'late_period' THEN sales ELSE 0 END) AS late_sales,
        SUM(CASE WHEN expansion_period = 'early_period' THEN profit ELSE 0 END) AS early_profit,
        SUM(CASE WHEN expansion_period = 'late_period' THEN profit ELSE 0 END) AS late_profit,
        SUM(CASE WHEN expansion_period = 'early_period' THEN gross_loss ELSE 0 END) AS early_gross_loss,
        SUM(CASE WHEN expansion_period = 'late_period' THEN gross_loss ELSE 0 END) AS late_gross_loss,
        SUM(CASE WHEN expansion_period = 'early_period' THEN orders ELSE 0 END) AS early_orders,
        SUM(CASE WHEN expansion_period = 'late_period' THEN orders ELSE 0 END) AS late_orders,
        SUM(CASE WHEN expansion_period = 'early_period' THEN order_lines ELSE 0 END) AS early_order_lines,
        SUM(CASE WHEN expansion_period = 'late_period' THEN order_lines ELSE 0 END) AS late_order_lines,
        AVG(CASE WHEN expansion_period = 'late_period' THEN avg_discount ELSE NULL END) AS late_avg_discount
    FROM city_period
    GROUP BY City, State, Region
),
city_growth AS (
    SELECT
        *,
        late_sales - early_sales AS sales_change,
        late_profit - early_profit AS profit_change,
        late_gross_loss - early_gross_loss AS gross_loss_change,
        early_profit / NULLIF(early_sales, 0) AS early_margin,
        late_profit / NULLIF(late_sales, 0) AS late_margin,
        (late_profit / NULLIF(late_sales, 0)) - (early_profit / NULLIF(early_sales, 0)) AS margin_change,
        (late_sales - early_sales) / NULLIF(early_sales, 0) AS sales_growth_rate
    FROM city_compare
),
city_growth_ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY sales_change DESC, late_sales DESC) AS sales_change_rank,
        ROW_NUMBER() OVER (ORDER BY late_sales DESC, sales_change DESC) AS late_sales_rank,
        ROW_NUMBER() OVER (ORDER BY late_gross_loss DESC, late_sales DESC) AS late_gross_loss_rank,
        ROW_NUMBER() OVER (ORDER BY late_margin ASC, late_sales DESC) AS weak_late_margin_rank
    FROM city_growth
    WHERE late_sales > 0
),
region_period AS (
    SELECT
        Region,
        expansion_period,
        COUNT(DISTINCT "Order ID") AS orders,
        COUNT(*) AS order_lines,
        COUNT(DISTINCT "Customer ID") AS customers,
        COUNT(DISTINCT State) AS states,
        COUNT(DISTINCT City) AS cities,
        SUM(Sales) AS sales,
        SUM(Profit) AS profit,
        SUM(CASE WHEN Profit < 0 THEN -Profit ELSE 0 END) AS gross_loss,
        AVG(Discount) AS avg_discount
    FROM periodized
    GROUP BY Region, expansion_period
),
region_compare AS (
    SELECT
        Region,
        SUM(CASE WHEN expansion_period = 'early_period' THEN sales ELSE 0 END) AS early_sales,
        SUM(CASE WHEN expansion_period = 'late_period' THEN sales ELSE 0 END) AS late_sales,
        SUM(CASE WHEN expansion_period = 'early_period' THEN profit ELSE 0 END) AS early_profit,
        SUM(CASE WHEN expansion_period = 'late_period' THEN profit ELSE 0 END) AS late_profit,
        SUM(CASE WHEN expansion_period = 'early_period' THEN gross_loss ELSE 0 END) AS early_gross_loss,
        SUM(CASE WHEN expansion_period = 'late_period' THEN gross_loss ELSE 0 END) AS late_gross_loss,
        SUM(CASE WHEN expansion_period = 'early_period' THEN orders ELSE 0 END) AS early_orders,
        SUM(CASE WHEN expansion_period = 'late_period' THEN orders ELSE 0 END) AS late_orders,
        AVG(CASE WHEN expansion_period = 'late_period' THEN avg_discount ELSE NULL END) AS late_avg_discount
    FROM region_period
    GROUP BY Region
),
region_growth AS (
    SELECT
        *,
        late_sales - early_sales AS sales_change,
        late_profit - early_profit AS profit_change,
        late_gross_loss - early_gross_loss AS gross_loss_change,
        early_profit / NULLIF(early_sales, 0) AS early_margin,
        late_profit / NULLIF(late_sales, 0) AS late_margin,
        (late_profit / NULLIF(late_sales, 0)) - (early_profit / NULLIF(early_sales, 0)) AS margin_change
    FROM region_compare
)
SELECT
    'overall_expansion_baseline' AS evidence_block,
    'period' AS grain,
    expansion_period AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(first_year AS VARCHAR) || '-' || CAST(last_year AS VARCHAR) AS period,
    CAST(NULL AS VARCHAR) AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
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
    ROUND(sales_share, 4) AS sales_share,
    ROUND(profit_share, 4) AS profit_share,
    ROUND(gross_loss_share, 4) AS gross_loss_share,
    'states' AS extra_metric_1,
    CAST(states AS DOUBLE) AS extra_value_1,
    'cities' AS extra_metric_2,
    CAST(cities AS DOUBLE) AS extra_value_2,
    'Use this block to frame whether the late period is larger and whether margin improves overall.' AS notes
FROM overall_period
UNION ALL
SELECT
    'region_expansion_quality' AS evidence_block,
    'region' AS grain,
    Region AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    'early_to_late' AS period,
    CAST(NULL AS VARCHAR) AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    ROUND(late_sales, 2) AS sales,
    ROUND(late_profit, 2) AS profit,
    ROUND(late_margin, 4) AS margin,
    ROUND(late_gross_loss, 2) AS gross_loss,
    CAST(late_orders AS BIGINT) AS orders,
    CAST(NULL AS BIGINT) AS order_lines,
    CAST(NULL AS BIGINT) AS customers,
    CAST(NULL AS BIGINT) AS products,
    ROUND(late_avg_discount, 4) AS avg_discount,
    CAST(NULL AS DOUBLE) AS quantity,
    ROUND(late_sales / NULLIF((SELECT SUM(late_sales) FROM region_growth), 0), 4) AS sales_share,
    ROUND(late_profit / NULLIF((SELECT SUM(late_profit) FROM region_growth), 0), 4) AS profit_share,
    ROUND(late_gross_loss / NULLIF((SELECT SUM(late_gross_loss) FROM region_growth), 0), 4) AS gross_loss_share,
    'sales_change' AS extra_metric_1,
    ROUND(sales_change, 2) AS extra_value_1,
    'margin_change' AS extra_metric_2,
    ROUND(margin_change, 4) AS extra_value_2,
    'Use this block to compare expansion quality across regions.' AS notes
FROM region_growth
UNION ALL
SELECT
    'state_growth_quality' AS evidence_block,
    'state' AS grain,
    State AS item,
    Region AS item_2,
    'early_to_late' AS period,
    'sales_change_rank' AS rank_label,
    CAST(sales_change_rank AS DOUBLE) AS rank_value,
    ROUND(late_sales, 2) AS sales,
    ROUND(late_profit, 2) AS profit,
    ROUND(late_margin, 4) AS margin,
    ROUND(late_gross_loss, 2) AS gross_loss,
    CAST(late_orders AS BIGINT) AS orders,
    CAST(late_order_lines AS BIGINT) AS order_lines,
    CAST(NULL AS BIGINT) AS customers,
    CAST(NULL AS BIGINT) AS products,
    ROUND(late_avg_discount, 4) AS avg_discount,
    CAST(NULL AS DOUBLE) AS quantity,
    ROUND(late_sales / NULLIF((SELECT SUM(late_sales) FROM state_growth), 0), 4) AS sales_share,
    ROUND(late_profit / NULLIF((SELECT SUM(late_profit) FROM state_growth), 0), 4) AS profit_share,
    ROUND(late_gross_loss / NULLIF((SELECT SUM(late_gross_loss) FROM state_growth), 0), 4) AS gross_loss_share,
    'sales_change' AS extra_metric_1,
    ROUND(sales_change, 2) AS extra_value_1,
    'profit_change' AS extra_metric_2,
    ROUND(profit_change, 2) AS extra_value_2,
    'Use this block to identify states where expansion does or does not convert into profit.' AS notes
FROM state_growth_ranked
UNION ALL
SELECT
    'state_growth_quadrants' AS evidence_block,
    'state_growth_quadrant' AS grain,
    growth_quadrant AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    'late_period' AS period,
    CAST(NULL AS VARCHAR) AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    ROUND(late_sales, 2) AS sales,
    ROUND(late_profit, 2) AS profit,
    ROUND(late_profit / NULLIF(late_sales, 0), 4) AS margin,
    ROUND(late_gross_loss, 2) AS gross_loss,
    CAST(NULL AS BIGINT) AS orders,
    CAST(NULL AS BIGINT) AS order_lines,
    CAST(states AS BIGINT) AS customers,
    CAST(NULL AS BIGINT) AS products,
    ROUND(late_avg_discount, 4) AS avg_discount,
    CAST(NULL AS DOUBLE) AS quantity,
    ROUND(late_sales / NULLIF((SELECT SUM(late_sales) FROM growth_quadrant_metrics), 0), 4) AS sales_share,
    ROUND(late_profit / NULLIF((SELECT SUM(late_profit) FROM growth_quadrant_metrics), 0), 4) AS profit_share,
    ROUND(late_gross_loss / NULLIF((SELECT SUM(late_gross_loss) FROM growth_quadrant_metrics), 0), 4) AS gross_loss_share,
    'states' AS extra_metric_1,
    CAST(states AS DOUBLE) AS extra_value_1,
    'sales_change' AS extra_metric_2,
    ROUND(sales_change, 2) AS extra_value_2,
    'Use this block to summarize whether growing states are healthy or only scaling up.' AS notes
FROM growth_quadrant_metrics
UNION ALL
SELECT
    'city_growth_quality' AS evidence_block,
    'city' AS grain,
    City AS item,
    State AS item_2,
    'early_to_late' AS period,
    'sales_change_rank' AS rank_label,
    CAST(sales_change_rank AS DOUBLE) AS rank_value,
    ROUND(late_sales, 2) AS sales,
    ROUND(late_profit, 2) AS profit,
    ROUND(late_margin, 4) AS margin,
    ROUND(late_gross_loss, 2) AS gross_loss,
    CAST(late_orders AS BIGINT) AS orders,
    CAST(late_order_lines AS BIGINT) AS order_lines,
    CAST(NULL AS BIGINT) AS customers,
    CAST(NULL AS BIGINT) AS products,
    ROUND(late_avg_discount, 4) AS avg_discount,
    CAST(NULL AS DOUBLE) AS quantity,
    ROUND(late_sales / NULLIF((SELECT SUM(late_sales) FROM city_growth), 0), 4) AS sales_share,
    ROUND(late_profit / NULLIF((SELECT SUM(late_profit) FROM city_growth), 0), 4) AS profit_share,
    ROUND(late_gross_loss / NULLIF((SELECT SUM(late_gross_loss) FROM city_growth), 0), 4) AS gross_loss_share,
    'sales_change' AS extra_metric_1,
    ROUND(sales_change, 2) AS extra_value_1,
    'margin_change' AS extra_metric_2,
    ROUND(margin_change, 4) AS extra_value_2,
    'Use this block to calibrate localized city-level growth pockets and underconversion.' AS notes
FROM city_growth_ranked
WHERE sales_change_rank <= 30 OR late_gross_loss_rank <= 30 OR weak_late_margin_rank <= 30
ORDER BY evidence_block, grain, rank_value, item, item_2;
