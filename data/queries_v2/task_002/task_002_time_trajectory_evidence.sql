-- task_002_time_trajectory_evidence.sql
-- Evidence SQL for task_002.
-- Public query: Analyze how sales and profitability changed over time, and whether growth reflects margin improvement or scale expansion.

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
        DATE_PART('year', "Order Date") AS order_year,
        CASE WHEN Profit < 0 THEN Profit ELSE 0 END AS line_gross_loss
    FROM order_lines
),
totals AS (
    SELECT
        COUNT(*) AS total_rows,
        SUM(Sales) AS total_sales,
        SUM(Profit) AS total_profit,
        SUM(line_gross_loss) AS total_gross_loss
    FROM base
),
year_summary AS (
    SELECT
        order_year,
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
    GROUP BY order_year
),
year_with_lag AS (
    SELECT
        order_year,
        row_count,
        sales,
        profit,
        profit_margin_pct,
        avg_discount,
        LAG(order_year) OVER (ORDER BY order_year) AS prev_year,
        LAG(row_count) OVER (ORDER BY order_year) AS prev_row_count,
        LAG(sales) OVER (ORDER BY order_year) AS prev_sales,
        LAG(profit) OVER (ORDER BY order_year) AS prev_profit,
        LAG(profit_margin_pct) OVER (ORDER BY order_year) AS prev_margin
    FROM year_summary
),
yoy_summary AS (
    SELECT
        order_year,
        prev_year,
        row_count,
        sales,
        profit,
        profit_margin_pct,
        avg_discount,
        100.0 * (row_count - prev_row_count) / NULLIF(prev_row_count, 0) AS row_growth_pct,
        100.0 * (sales - prev_sales) / NULLIF(prev_sales, 0) AS sales_growth_pct,
        100.0 * (profit - prev_profit) / NULLIF(prev_profit, 0) AS profit_growth_pct,
        profit_margin_pct - prev_margin AS margin_delta_pp
    FROM year_with_lag
    WHERE prev_year IS NOT NULL
)
SELECT
    'G1' AS insight_id,
    'yearly_trajectory_baseline' AS evidence_block,
    'year' AS entity_level,
    CAST(order_year AS VARCHAR) AS entity,
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
    NULL AS prev_entity,
    NULL AS row_growth_pct,
    NULL AS sales_growth_pct,
    NULL AS profit_growth_pct,
    NULL AS margin_delta_pp,
    'Yearly baseline: use this block to identify the peak year and whether later years remain positive.' AS note
FROM year_summary
UNION ALL
SELECT
    'G2' AS insight_id,
    'scale_step_change' AS evidence_block,
    'year_over_year' AS entity_level,
    CAST(order_year AS VARCHAR) AS entity,
    NULL AS parent_entity,
    row_count,
    NULL AS row_share_pct,
    ROUND(sales, 2) AS sales,
    NULL AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    NULL AS gross_loss,
    NULL AS gross_loss_share_pct,
    CAST(prev_year AS VARCHAR) AS prev_entity,
    ROUND(row_growth_pct, 2) AS row_growth_pct,
    ROUND(sales_growth_pct, 2) AS sales_growth_pct,
    ROUND(profit_growth_pct, 2) AS profit_growth_pct,
    ROUND(margin_delta_pp, 2) AS margin_delta_pp,
    'Year-over-year comparison: check whether the key jump is scale-driven or margin-driven.' AS note
FROM yoy_summary
UNION ALL
SELECT
    'G3' AS insight_id,
    'margin_stability_after_scaleup' AS evidence_block,
    'year' AS entity_level,
    CAST(order_year AS VARCHAR) AS entity,
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
    NULL AS prev_entity,
    NULL AS row_growth_pct,
    NULL AS sales_growth_pct,
    NULL AS profit_growth_pct,
    NULL AS margin_delta_pp,
    'Margin stability block: compare margins after the 2015 scale-up rather than treating every sales change as margin improvement.' AS note
FROM year_summary
WHERE order_year >= 2015
UNION ALL
SELECT
    'G4' AS insight_id,
    'early_underconversion_check' AS evidence_block,
    'year' AS entity_level,
    CAST(order_year AS VARCHAR) AS entity,
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
    NULL AS prev_entity,
    NULL AS row_growth_pct,
    NULL AS sales_growth_pct,
    NULL AS profit_growth_pct,
    NULL AS margin_delta_pp,
    'Early-year conversion check: identify the weakest year-level margin while verifying that every year remains net profitable.' AS note
FROM year_summary
UNION ALL
SELECT
    'G5' AS insight_id,
    'gross_loss_timing' AS evidence_block,
    'year' AS entity_level,
    CAST(order_year AS VARCHAR) AS entity,
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
    NULL AS prev_entity,
    NULL AS row_growth_pct,
    NULL AS sales_growth_pct,
    NULL AS profit_growth_pct,
    NULL AS margin_delta_pp,
    'Gross-loss timing block: compare loss exposure with the years that have the most sales and profit.' AS note
FROM year_summary
UNION ALL
SELECT
    'G6' AS insight_id,
    'discount_stability_over_time' AS evidence_block,
    'year' AS entity_level,
    CAST(order_year AS VARCHAR) AS entity,
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
    NULL AS prev_entity,
    NULL AS row_growth_pct,
    NULL AS sales_growth_pct,
    NULL AS profit_growth_pct,
    NULL AS margin_delta_pp,
    'Discount stability block: if average discount is flat across years, temporal growth should not be explained mainly by year-level discount shifts.' AS note
FROM year_summary
ORDER BY insight_id, entity_level, entity;
