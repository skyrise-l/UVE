-- task_007: customer repurchase quality evidence
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
        f."Ship Date",
        f."Ship Mode",
        f."Customer ID",
        p."Customer Name",
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
customer_summary AS (
    SELECT
        "Customer ID",
        MIN("Customer Name") AS customer_name,
        MIN(Segment) AS segment,
        COUNT(DISTINCT "Order ID") AS total_orders,
        COUNT(*) AS order_lines,
        MIN("Order Date") AS first_order_date,
        MAX("Order Date") AS last_order_date,
        SUM(Sales) AS sales,
        SUM(Profit) AS profit,
        SUM(CASE WHEN Profit < 0 THEN -Profit ELSE 0 END) AS gross_loss,
        AVG(Discount) AS avg_discount,
        SUM(Quantity) AS quantity
    FROM fact
    GROUP BY "Customer ID"
),
customer_bucketed AS (
    SELECT
        *,
        CASE
            WHEN total_orders = 1 THEN '1_order'
            WHEN total_orders BETWEEN 2 AND 3 THEN '2_3_orders'
            WHEN total_orders BETWEEN 4 AND 6 THEN '4_6_orders'
            ELSE '7_plus_orders'
        END AS frequency_bucket
    FROM customer_summary
),
frequency_metrics_raw AS (
    SELECT
        frequency_bucket,
        COUNT(*) AS customers,
        SUM(total_orders) AS orders,
        SUM(order_lines) AS order_lines,
        SUM(sales) AS sales,
        SUM(profit) AS profit,
        SUM(gross_loss) AS gross_loss,
        SUM(quantity) AS quantity,
        AVG(avg_discount) AS avg_discount,
        SUM(sales) / NULLIF(COUNT(*), 0) AS sales_per_customer,
        SUM(profit) / NULLIF(COUNT(*), 0) AS profit_per_customer
    FROM customer_bucketed
    GROUP BY frequency_bucket
),
frequency_metrics AS (
    SELECT
        *,
        sales / NULLIF(SUM(sales) OVER (), 0) AS sales_share,
        profit / NULLIF(SUM(profit) OVER (), 0) AS profit_share,
        gross_loss / NULLIF(SUM(gross_loss) OVER (), 0) AS gross_loss_share,
        profit / NULLIF(sales, 0) AS margin
    FROM frequency_metrics_raw
),
order_summary AS (
    SELECT
        "Customer ID",
        MIN("Customer Name") AS customer_name,
        MIN(Segment) AS segment,
        "Order ID",
        MIN("Order Date") AS order_date,
        COUNT(*) AS order_lines,
        SUM(Sales) AS sales,
        SUM(Profit) AS profit,
        SUM(CASE WHEN Profit < 0 THEN -Profit ELSE 0 END) AS gross_loss,
        AVG(Discount) AS avg_discount,
        SUM(Quantity) AS quantity
    FROM fact
    GROUP BY "Customer ID", "Order ID"
),
order_sequence AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY "Customer ID" ORDER BY order_date, "Order ID") AS order_seq,
        COUNT(*) OVER (PARTITION BY "Customer ID") AS customer_order_count
    FROM order_summary
),
lifecycle_metrics_raw AS (
    SELECT
        CASE WHEN order_seq = 1 THEN 'first_order' ELSE 'repeat_order' END AS lifecycle_stage,
        COUNT(DISTINCT "Customer ID") AS customers,
        COUNT(DISTINCT "Order ID") AS orders,
        SUM(order_lines) AS order_lines,
        SUM(sales) AS sales,
        SUM(profit) AS profit,
        SUM(gross_loss) AS gross_loss,
        SUM(quantity) AS quantity,
        AVG(avg_discount) AS avg_discount
    FROM order_sequence
    GROUP BY lifecycle_stage
),
lifecycle_metrics AS (
    SELECT
        *,
        sales / NULLIF(SUM(sales) OVER (), 0) AS sales_share,
        profit / NULLIF(SUM(profit) OVER (), 0) AS profit_share,
        gross_loss / NULLIF(SUM(gross_loss) OVER (), 0) AS gross_loss_share,
        profit / NULLIF(sales, 0) AS margin
    FROM lifecycle_metrics_raw
),
repeat_customer_ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY profit DESC, sales DESC, "Customer ID") AS profit_rank_desc,
        ROW_NUMBER() OVER (ORDER BY profit ASC, sales DESC, "Customer ID") AS profit_rank_asc,
        ROW_NUMBER() OVER (ORDER BY sales DESC, profit ASC, "Customer ID") AS sales_rank_desc
    FROM customer_bucketed
    WHERE total_orders >= 2
),
repeat_concentration_raw AS (
    SELECT
        'top10_repeat_profit' AS group_label,
        COUNT(*) AS customers,
        SUM(total_orders) AS orders,
        SUM(order_lines) AS order_lines,
        SUM(sales) AS sales,
        SUM(profit) AS profit,
        SUM(gross_loss) AS gross_loss,
        AVG(avg_discount) AS avg_discount
    FROM repeat_customer_ranked
    WHERE profit_rank_desc <= 10
    UNION ALL
    SELECT
        'bottom10_repeat_profit' AS group_label,
        COUNT(*) AS customers,
        SUM(total_orders) AS orders,
        SUM(order_lines) AS order_lines,
        SUM(sales) AS sales,
        SUM(profit) AS profit,
        SUM(gross_loss) AS gross_loss,
        AVG(avg_discount) AS avg_discount
    FROM repeat_customer_ranked
    WHERE profit_rank_asc <= 10
    UNION ALL
    SELECT
        'top10_repeat_sales' AS group_label,
        COUNT(*) AS customers,
        SUM(total_orders) AS orders,
        SUM(order_lines) AS order_lines,
        SUM(sales) AS sales,
        SUM(profit) AS profit,
        SUM(gross_loss) AS gross_loss,
        AVG(avg_discount) AS avg_discount
    FROM repeat_customer_ranked
    WHERE sales_rank_desc <= 10
),
repeat_concentration AS (
    SELECT
        *,
        sales / NULLIF((SELECT SUM(sales) FROM customer_summary), 0) AS sales_share,
        profit / NULLIF((SELECT SUM(profit) FROM customer_summary), 0) AS profit_share,
        gross_loss / NULLIF((SELECT SUM(gross_loss) FROM customer_summary), 0) AS gross_loss_share,
        profit / NULLIF(sales, 0) AS margin
    FROM repeat_concentration_raw
),
high_volume_customers AS (
    SELECT
        *
    FROM repeat_customer_ranked
    WHERE sales_rank_desc <= 25
),
high_volume_customer_risk AS (
    SELECT
        CASE WHEN profit < 0 THEN 'negative_profit_top_sales_customer' ELSE 'positive_profit_top_sales_customer' END AS risk_label,
        COUNT(*) AS customers,
        SUM(total_orders) AS orders,
        SUM(order_lines) AS order_lines,
        SUM(sales) AS sales,
        SUM(profit) AS profit,
        SUM(gross_loss) AS gross_loss,
        AVG(avg_discount) AS avg_discount
    FROM high_volume_customers
    GROUP BY risk_label
),
segment_frequency_raw AS (
    SELECT
        segment,
        frequency_bucket,
        COUNT(*) AS customers,
        SUM(total_orders) AS orders,
        SUM(order_lines) AS order_lines,
        SUM(sales) AS sales,
        SUM(profit) AS profit,
        SUM(gross_loss) AS gross_loss,
        AVG(avg_discount) AS avg_discount
    FROM customer_bucketed
    GROUP BY segment, frequency_bucket
),
segment_frequency AS (
    SELECT
        *,
        profit / NULLIF(sales, 0) AS margin,
        gross_loss / NULLIF(SUM(gross_loss) OVER (), 0) AS gross_loss_share,
        ROW_NUMBER() OVER (ORDER BY gross_loss DESC, sales DESC) AS gross_loss_rank
    FROM segment_frequency_raw
)
SELECT
    'frequency_value_gradient' AS evidence_block,
    'customer_frequency_bucket' AS grain,
    frequency_bucket AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS period,
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
    CAST(quantity AS DOUBLE) AS quantity,
    ROUND(sales_share, 4) AS sales_share,
    ROUND(profit_share, 4) AS profit_share,
    ROUND(gross_loss_share, 4) AS gross_loss_share,
    'sales_per_customer' AS extra_metric_1,
    ROUND(sales_per_customer, 2) AS extra_value_1,
    'profit_per_customer' AS extra_metric_2,
    ROUND(profit_per_customer, 2) AS extra_value_2,
    'Use this block to decide whether repeat frequency adds profitable value or mainly adds scale.' AS notes
FROM frequency_metrics
UNION ALL
SELECT
    'first_vs_repeat_orders' AS evidence_block,
    'order_lifecycle_stage' AS grain,
    lifecycle_stage AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS period,
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
    CAST(quantity AS DOUBLE) AS quantity,
    ROUND(sales_share, 4) AS sales_share,
    ROUND(profit_share, 4) AS profit_share,
    ROUND(gross_loss_share, 4) AS gross_loss_share,
    CAST(NULL AS VARCHAR) AS extra_metric_1,
    CAST(NULL AS DOUBLE) AS extra_value_1,
    CAST(NULL AS VARCHAR) AS extra_metric_2,
    CAST(NULL AS DOUBLE) AS extra_value_2,
    'Use this block to compare first purchases with retained/repeat orders.' AS notes
FROM lifecycle_metrics
UNION ALL
SELECT
    'repeat_customer_concentration' AS evidence_block,
    'repeat_customer_top_bottom_group' AS grain,
    group_label AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS period,
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
    CAST(NULL AS VARCHAR) AS extra_metric_1,
    CAST(NULL AS DOUBLE) AS extra_value_1,
    CAST(NULL AS VARCHAR) AS extra_metric_2,
    CAST(NULL AS DOUBLE) AS extra_value_2,
    'Use this block to measure whether customer value and customer loss are concentrated in a small repeat-customer tail.' AS notes
FROM repeat_concentration
UNION ALL
SELECT
    'high_volume_customer_risk' AS evidence_block,
    'top_sales_repeat_customers' AS grain,
    risk_label AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS period,
    CAST(NULL AS VARCHAR) AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    ROUND(sales, 2) AS sales,
    ROUND(profit, 2) AS profit,
    ROUND(profit / NULLIF(sales, 0), 4) AS margin,
    ROUND(gross_loss, 2) AS gross_loss,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(customers AS BIGINT) AS customers,
    CAST(NULL AS BIGINT) AS products,
    ROUND(avg_discount, 4) AS avg_discount,
    CAST(NULL AS DOUBLE) AS quantity,
    ROUND(sales / NULLIF((SELECT SUM(sales) FROM customer_summary), 0), 4) AS sales_share,
    ROUND(profit / NULLIF((SELECT SUM(profit) FROM customer_summary), 0), 4) AS profit_share,
    ROUND(gross_loss / NULLIF((SELECT SUM(gross_loss) FROM customer_summary), 0), 4) AS gross_loss_share,
    CAST(NULL AS VARCHAR) AS extra_metric_1,
    CAST(NULL AS DOUBLE) AS extra_value_1,
    CAST(NULL AS VARCHAR) AS extra_metric_2,
    CAST(NULL AS DOUBLE) AS extra_value_2,
    'Use this block to see whether high-sales repeat customers are reliably profitable.' AS notes
FROM high_volume_customer_risk
UNION ALL
SELECT
    'segment_frequency_interaction' AS evidence_block,
    'segment_by_frequency_bucket' AS grain,
    segment AS item,
    frequency_bucket AS item_2,
    CAST(NULL AS VARCHAR) AS period,
    'gross_loss_rank' AS rank_label,
    CAST(gross_loss_rank AS DOUBLE) AS rank_value,
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
    ROUND(sales / NULLIF((SELECT SUM(sales) FROM customer_summary), 0), 4) AS sales_share,
    ROUND(profit / NULLIF((SELECT SUM(profit) FROM customer_summary), 0), 4) AS profit_share,
    ROUND(gross_loss_share, 4) AS gross_loss_share,
    CAST(NULL AS VARCHAR) AS extra_metric_1,
    CAST(NULL AS DOUBLE) AS extra_value_1,
    CAST(NULL AS VARCHAR) AS extra_metric_2,
    CAST(NULL AS DOUBLE) AS extra_value_2,
    'Use this block to calibrate whether repeat quality differs by broad customer segment.' AS notes
FROM segment_frequency
ORDER BY evidence_block, grain, item, item_2;
