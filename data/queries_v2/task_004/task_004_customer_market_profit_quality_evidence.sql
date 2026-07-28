-- task_004_customer_market_profit_quality_evidence.sql
-- Final evidence SQL for task_004.
-- Public query: Some customer markets generate demand but do not seem to turn it into healthy profit. Identify where the uneven conversion comes from and which customer or geographic pockets matter most.

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
        COALESCE(p."Customer Name", 'Unknown') AS customer_name,
        COALESCE(p.Segment, 'Unknown') AS segment,
        COALESCE(p.Country, 'Unknown') AS country,
        COALESCE(p.City, 'Unknown') AS city,
        COALESCE(p.State, 'Unknown') AS state,
        CASE WHEN ol.Profit < 0 THEN ol.Profit ELSE 0 END AS line_gross_loss,
        CASE WHEN ol.Profit < 0 THEN 1 ELSE 0 END AS loss_line_flag
    FROM order_lines ol
    LEFT JOIN people p
        ON ol."Customer ID" = p."Customer ID"
       AND ol.Region = p.Region
),
totals AS (
    SELECT
        COUNT(*) AS total_rows,
        COUNT(DISTINCT "Order ID" || '|' || Region) AS total_orders,
        COUNT(DISTINCT "Customer ID" || '|' || Region) AS total_customers,
        SUM(Sales) AS total_sales,
        SUM(Profit) AS total_profit,
        SUM(line_gross_loss) AS total_gross_loss
    FROM base
),
segment_summary AS (
    SELECT
        segment AS entity,
        NULL AS parent_entity,
        COUNT(*) AS row_count,
        COUNT(DISTINCT "Order ID" || '|' || Region) AS order_count,
        COUNT(DISTINCT "Customer ID" || '|' || Region) AS customer_count,
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
    GROUP BY segment
),
state_summary AS (
    SELECT
        state AS entity,
        Region AS parent_entity,
        COUNT(*) AS row_count,
        COUNT(DISTINCT "Order ID" || '|' || Region) AS order_count,
        COUNT(DISTINCT "Customer ID" || '|' || Region) AS customer_count,
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
    GROUP BY state, Region
),
state_ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY sales DESC) AS rank_by_sales,
        ROW_NUMBER() OVER (ORDER BY profit DESC) AS rank_by_profit,
        ROW_NUMBER() OVER (ORDER BY gross_loss ASC) AS rank_by_gross_loss
    FROM state_summary
),
city_summary AS (
    SELECT
        city || ', ' || state AS entity,
        Region AS parent_entity,
        COUNT(*) AS row_count,
        COUNT(DISTINCT "Order ID" || '|' || Region) AS order_count,
        COUNT(DISTINCT "Customer ID" || '|' || Region) AS customer_count,
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
    GROUP BY city, state, Region
),
city_ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY sales DESC) AS rank_by_sales,
        ROW_NUMBER() OVER (ORDER BY profit DESC) AS rank_by_profit,
        ROW_NUMBER() OVER (ORDER BY gross_loss ASC) AS rank_by_gross_loss
    FROM city_summary
),
customer_summary AS (
    SELECT
        "Customer ID" || ' / ' || customer_name AS entity,
        segment || ' / ' || state || ' / ' || Region AS parent_entity,
        COUNT(*) AS row_count,
        COUNT(DISTINCT "Order ID" || '|' || Region) AS order_count,
        1 AS customer_count,
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
    GROUP BY "Customer ID", customer_name, segment, state, Region
),
customer_ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY sales DESC) AS rank_by_sales,
        ROW_NUMBER() OVER (ORDER BY profit DESC) AS rank_by_profit,
        ROW_NUMBER() OVER (ORDER BY gross_loss ASC) AS rank_by_gross_loss,
        ROW_NUMBER() OVER (ORDER BY profit ASC) AS rank_by_negative_profit
    FROM customer_summary
),
customer_concentration AS (
    SELECT
        'top_10_profit_customers' AS entity,
        'customer_concentration' AS parent_entity,
        SUM(CASE WHEN rank_by_profit <= 10 THEN row_count ELSE 0 END) AS row_count,
        SUM(CASE WHEN rank_by_profit <= 10 THEN order_count ELSE 0 END) AS order_count,
        10 AS customer_count,
        SUM(CASE WHEN rank_by_profit <= 10 THEN sales ELSE 0 END) AS sales,
        100.0 * SUM(CASE WHEN rank_by_profit <= 10 THEN sales ELSE 0 END) / NULLIF(MAX(t.total_sales), 0) AS sales_share_pct,
        SUM(CASE WHEN rank_by_profit <= 10 THEN profit ELSE 0 END) AS profit,
        100.0 * SUM(CASE WHEN rank_by_profit <= 10 THEN profit ELSE 0 END) / NULLIF(SUM(CASE WHEN rank_by_profit <= 10 THEN sales ELSE 0 END), 0) AS profit_margin_pct,
        SUM(CASE WHEN rank_by_profit <= 10 THEN avg_discount * row_count ELSE 0 END) / NULLIF(SUM(CASE WHEN rank_by_profit <= 10 THEN row_count ELSE 0 END), 0) AS avg_discount,
        SUM(CASE WHEN rank_by_profit <= 10 THEN loss_line_count ELSE 0 END) AS loss_line_count,
        SUM(CASE WHEN rank_by_profit <= 10 THEN gross_loss ELSE 0 END) AS gross_loss,
        100.0 * SUM(CASE WHEN rank_by_profit <= 10 THEN gross_loss ELSE 0 END) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct,
        10 AS rank_by_sales,
        10 AS rank_by_profit,
        NULL AS rank_by_gross_loss
    FROM customer_ranked
    CROSS JOIN totals t
    UNION ALL
    SELECT
        'bottom_10_profit_customers' AS entity,
        'customer_concentration' AS parent_entity,
        SUM(CASE WHEN rank_by_negative_profit <= 10 THEN row_count ELSE 0 END) AS row_count,
        SUM(CASE WHEN rank_by_negative_profit <= 10 THEN order_count ELSE 0 END) AS order_count,
        10 AS customer_count,
        SUM(CASE WHEN rank_by_negative_profit <= 10 THEN sales ELSE 0 END) AS sales,
        100.0 * SUM(CASE WHEN rank_by_negative_profit <= 10 THEN sales ELSE 0 END) / NULLIF(MAX(t.total_sales), 0) AS sales_share_pct,
        SUM(CASE WHEN rank_by_negative_profit <= 10 THEN profit ELSE 0 END) AS profit,
        100.0 * SUM(CASE WHEN rank_by_negative_profit <= 10 THEN profit ELSE 0 END) / NULLIF(SUM(CASE WHEN rank_by_negative_profit <= 10 THEN sales ELSE 0 END), 0) AS profit_margin_pct,
        SUM(CASE WHEN rank_by_negative_profit <= 10 THEN avg_discount * row_count ELSE 0 END) / NULLIF(SUM(CASE WHEN rank_by_negative_profit <= 10 THEN row_count ELSE 0 END), 0) AS avg_discount,
        SUM(CASE WHEN rank_by_negative_profit <= 10 THEN loss_line_count ELSE 0 END) AS loss_line_count,
        SUM(CASE WHEN rank_by_negative_profit <= 10 THEN gross_loss ELSE 0 END) AS gross_loss,
        100.0 * SUM(CASE WHEN rank_by_negative_profit <= 10 THEN gross_loss ELSE 0 END) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct,
        NULL AS rank_by_sales,
        NULL AS rank_by_profit,
        10 AS rank_by_gross_loss
    FROM customer_ranked
    CROSS JOIN totals t
),
segment_state_summary AS (
    SELECT
        segment || ' / ' || state AS entity,
        Region AS parent_entity,
        COUNT(*) AS row_count,
        COUNT(DISTINCT "Order ID" || '|' || Region) AS order_count,
        COUNT(DISTINCT "Customer ID" || '|' || Region) AS customer_count,
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
    GROUP BY segment, state, Region
),
segment_state_ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY sales DESC) AS rank_by_sales,
        ROW_NUMBER() OVER (ORDER BY profit DESC) AS rank_by_profit,
        ROW_NUMBER() OVER (ORDER BY gross_loss ASC) AS rank_by_gross_loss
    FROM segment_state_summary
)
SELECT
    'G1' AS evidence_group_id,
    'segment_profit_quality' AS evidence_block,
    'segment' AS entity_level,
    entity,
    parent_entity,
    row_count,
    order_count,
    customer_count,
    ROUND(sales, 2) AS sales,
    ROUND(sales_share_pct, 2) AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    loss_line_count,
    ROUND(gross_loss, 2) AS gross_loss,
    ROUND(gross_loss_share_pct, 2) AS gross_loss_share_pct,
    NULL AS rank_by_sales,
    NULL AS rank_by_profit,
    NULL AS rank_by_gross_loss,
    'Segment baseline: determine whether segment is a primary profit-quality driver or mainly a scale lens.' AS note
FROM segment_summary
UNION ALL
SELECT
    'G2' AS evidence_group_id,
    'state_conversion_heterogeneity' AS evidence_block,
    'state' AS entity_level,
    entity,
    parent_entity,
    row_count,
    order_count,
    customer_count,
    ROUND(sales, 2) AS sales,
    ROUND(sales_share_pct, 2) AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    loss_line_count,
    ROUND(gross_loss, 2) AS gross_loss,
    ROUND(gross_loss_share_pct, 2) AS gross_loss_share_pct,
    rank_by_sales,
    rank_by_profit,
    rank_by_gross_loss,
    'State comparison: identify whether high-demand states also convert demand into profit, and which states are the main exceptions.' AS note
FROM state_ranked
UNION ALL
SELECT
    'G3' AS evidence_group_id,
    'city_loss_pockets' AS evidence_block,
    'city' AS entity_level,
    entity,
    parent_entity,
    row_count,
    order_count,
    customer_count,
    ROUND(sales, 2) AS sales,
    ROUND(sales_share_pct, 2) AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    loss_line_count,
    ROUND(gross_loss, 2) AS gross_loss,
    ROUND(gross_loss_share_pct, 2) AS gross_loss_share_pct,
    rank_by_sales,
    rank_by_profit,
    rank_by_gross_loss,
    'City pocket screen: retain top sales, top profit, and highest gross-loss cities to separate broad geography from local pockets.' AS note
FROM city_ranked
WHERE rank_by_sales <= 15 OR rank_by_profit <= 15 OR rank_by_gross_loss <= 15
UNION ALL
SELECT
    'G4' AS evidence_group_id,
    'customer_profit_concentration' AS evidence_block,
    'customer_concentration' AS entity_level,
    entity,
    parent_entity,
    row_count,
    order_count,
    customer_count,
    ROUND(sales, 2) AS sales,
    ROUND(sales_share_pct, 2) AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    loss_line_count,
    ROUND(gross_loss, 2) AS gross_loss,
    ROUND(gross_loss_share_pct, 2) AS gross_loss_share_pct,
    rank_by_sales,
    rank_by_profit,
    rank_by_gross_loss,
    'Customer concentration aggregate: compare whether the most profitable and least profitable customers are large enough to shape the answer.' AS note
FROM customer_concentration
UNION ALL
SELECT
    'G4' AS evidence_group_id,
    'customer_profit_concentration' AS evidence_block,
    'customer' AS entity_level,
    entity,
    parent_entity,
    row_count,
    order_count,
    customer_count,
    ROUND(sales, 2) AS sales,
    ROUND(sales_share_pct, 2) AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    loss_line_count,
    ROUND(gross_loss, 2) AS gross_loss,
    ROUND(gross_loss_share_pct, 2) AS gross_loss_share_pct,
    rank_by_sales,
    rank_by_profit,
    rank_by_gross_loss,
    'Customer concentration details: selected customers by top sales, top profit, and most negative profit.' AS note
FROM customer_ranked
WHERE rank_by_sales <= 10 OR rank_by_profit <= 10 OR rank_by_negative_profit <= 10
UNION ALL
SELECT
    'G5' AS evidence_group_id,
    'segment_state_interaction' AS evidence_block,
    'segment_state' AS entity_level,
    entity,
    parent_entity,
    row_count,
    order_count,
    customer_count,
    ROUND(sales, 2) AS sales,
    ROUND(sales_share_pct, 2) AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    loss_line_count,
    ROUND(gross_loss, 2) AS gross_loss,
    ROUND(gross_loss_share_pct, 2) AS gross_loss_share_pct,
    rank_by_sales,
    rank_by_profit,
    rank_by_gross_loss,
    'Segment-state interaction: check whether weak conversion is explained by segment alone or by segment embedded in specific states.' AS note
FROM segment_state_ranked
WHERE rank_by_sales <= 20 OR rank_by_profit <= 20 OR rank_by_gross_loss <= 20
ORDER BY evidence_group_id, evidence_block, entity_level, rank_by_gross_loss NULLS LAST, rank_by_sales NULLS LAST, entity;
