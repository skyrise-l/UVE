-- task_003_fulfillment_order_shape_evidence.sql
-- Evidence SQL for task_003.
-- Public query: Assess whether fulfillment choices and order size explain profitability differences.

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
        *,
        DATE_DIFF('day', "Order Date", "Ship Date") AS ship_days,
        CASE
            WHEN Quantity = 1 THEN '1'
            WHEN Quantity = 2 THEN '2'
            WHEN Quantity = 3 THEN '3'
            WHEN Quantity BETWEEN 4 AND 5 THEN '4-5'
            ELSE '6+'
        END AS quantity_group,
        CASE WHEN Profit < 0 THEN Profit ELSE 0 END AS line_gross_loss
    FROM order_lines
),
totals AS (
    SELECT
        COUNT(*) AS total_rows,
        SUM(Sales) AS total_sales,
        SUM(line_gross_loss) AS total_gross_loss
    FROM base
),
ship_mode_summary AS (
    SELECT
        "Ship Mode" AS entity,
        COUNT(*) AS row_count,
        100.0 * COUNT(*) / MAX(t.total_rows) AS row_share_pct,
        SUM(Sales) AS sales,
        100.0 * SUM(Sales) / MAX(t.total_sales) AS sales_share_pct,
        SUM(Profit) AS profit,
        100.0 * SUM(Profit) / NULLIF(SUM(Sales), 0) AS profit_margin_pct,
        AVG(Discount) AS avg_discount,
        SUM(line_gross_loss) AS gross_loss,
        100.0 * SUM(line_gross_loss) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct
    FROM base
    CROSS JOIN totals t
    GROUP BY "Ship Mode"
),
ship_days_summary AS (
    SELECT
        CAST(ship_days AS VARCHAR) AS entity,
        COUNT(*) AS row_count,
        100.0 * COUNT(*) / MAX(t.total_rows) AS row_share_pct,
        SUM(Sales) AS sales,
        100.0 * SUM(Sales) / MAX(t.total_sales) AS sales_share_pct,
        SUM(Profit) AS profit,
        100.0 * SUM(Profit) / NULLIF(SUM(Sales), 0) AS profit_margin_pct,
        AVG(Discount) AS avg_discount,
        SUM(line_gross_loss) AS gross_loss,
        100.0 * SUM(line_gross_loss) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct
    FROM base
    CROSS JOIN totals t
    GROUP BY ship_days
),
quantity_summary AS (
    SELECT
        quantity_group AS entity,
        CASE quantity_group WHEN '1' THEN 1 WHEN '2' THEN 2 WHEN '3' THEN 3 WHEN '4-5' THEN 4 ELSE 6 END AS quantity_sort,
        COUNT(*) AS row_count,
        100.0 * COUNT(*) / MAX(t.total_rows) AS row_share_pct,
        SUM(Sales) AS sales,
        100.0 * SUM(Sales) / MAX(t.total_sales) AS sales_share_pct,
        SUM(Profit) AS profit,
        100.0 * SUM(Profit) / NULLIF(SUM(Sales), 0) AS profit_margin_pct,
        AVG(Discount) AS avg_discount,
        SUM(line_gross_loss) AS gross_loss,
        100.0 * SUM(line_gross_loss) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct
    FROM base
    CROSS JOIN totals t
    GROUP BY quantity_group
)
SELECT
    'G1' AS insight_id,
    'ship_mode_margin_band' AS evidence_block,
    'ship_mode' AS entity_level,
    entity,
    NULL AS parent_entity,
    row_count,
    ROUND(row_share_pct, 2) AS row_share_pct,
    ROUND(sales, 2) AS sales,
    ROUND(sales_share_pct, 2) AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    ROUND(gross_loss, 2) AS gross_loss,
    ROUND(gross_loss_share_pct, 2) AS gross_loss_share_pct,
    'Ship-mode margin band: check whether ship modes are net loss-making or only modestly different in conversion.' AS note
FROM ship_mode_summary
UNION ALL
SELECT
    'G2' AS insight_id,
    'standard_class_scale_exposure' AS evidence_block,
    'ship_mode' AS entity_level,
    entity,
    NULL AS parent_entity,
    row_count,
    ROUND(row_share_pct, 2) AS row_share_pct,
    ROUND(sales, 2) AS sales,
    ROUND(sales_share_pct, 2) AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    ROUND(gross_loss, 2) AS gross_loss,
    ROUND(gross_loss_share_pct, 2) AS gross_loss_share_pct,
    'Scale-exposure block: Standard Class should be interpreted against its row and sales volume, not as a standalone net-loss channel.' AS note
FROM ship_mode_summary
UNION ALL
SELECT
    'G3' AS insight_id,
    'fast_shipping_comparison' AS evidence_block,
    'ship_mode' AS entity_level,
    entity,
    NULL AS parent_entity,
    row_count,
    ROUND(row_share_pct, 2) AS row_share_pct,
    ROUND(sales, 2) AS sales,
    ROUND(sales_share_pct, 2) AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    ROUND(gross_loss, 2) AS gross_loss,
    ROUND(gross_loss_share_pct, 2) AS gross_loss_share_pct,
    'Fast-shipping comparison: compare First Class and Same Day against slower modes before treating speed as the driver.' AS note
FROM ship_mode_summary
UNION ALL
SELECT
    'G4' AS insight_id,
    'ship_delay_nonmonotonicity' AS evidence_block,
    'ship_days' AS entity_level,
    entity,
    NULL AS parent_entity,
    row_count,
    ROUND(row_share_pct, 2) AS row_share_pct,
    ROUND(sales, 2) AS sales,
    ROUND(sales_share_pct, 2) AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    ROUND(gross_loss, 2) AS gross_loss,
    ROUND(gross_loss_share_pct, 2) AS gross_loss_share_pct,
    'Ship-delay comparison: margin should be read as a non-monotonic pattern, not as a simple longer-delay penalty.' AS note
FROM ship_days_summary
UNION ALL
SELECT
    'G5' AS insight_id,
    'four_day_loss_exposure' AS evidence_block,
    'ship_days' AS entity_level,
    entity,
    NULL AS parent_entity,
    row_count,
    ROUND(row_share_pct, 2) AS row_share_pct,
    ROUND(sales, 2) AS sales,
    ROUND(sales_share_pct, 2) AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    ROUND(gross_loss, 2) AS gross_loss,
    ROUND(gross_loss_share_pct, 2) AS gross_loss_share_pct,
    'Ship-delay exposure block: the largest gross-loss bucket must be interpreted together with its volume and positive net margin.' AS note
FROM ship_days_summary
UNION ALL
SELECT
    'G6' AS insight_id,
    'quantity_scale_conversion_drag' AS evidence_block,
    'quantity_group' AS entity_level,
    entity,
    NULL AS parent_entity,
    row_count,
    ROUND(row_share_pct, 2) AS row_share_pct,
    ROUND(sales, 2) AS sales,
    ROUND(sales_share_pct, 2) AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    ROUND(gross_loss, 2) AS gross_loss,
    ROUND(gross_loss_share_pct, 2) AS gross_loss_share_pct,
    'Quantity block: compare sales concentration and margin for larger quantity orders without overclaiming quantity as the primary mechanism.' AS note
FROM quantity_summary
ORDER BY insight_id, entity_level, entity;
