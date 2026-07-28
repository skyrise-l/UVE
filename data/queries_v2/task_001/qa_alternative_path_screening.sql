-- qa_alternative_path_screening.sql
-- Non-Gold screening SQL for paths considered but not included in core Gold.
-- Purpose: audit whether excluded original-schema directions are obvious missing core paths.
-- Gold already covers Sales/Profit/Discount, Product hierarchy, Region, and Region x Product.
-- This QA screens remaining plausible fields: people dimension, time, ship mode, ship delay, quantity, and order-level aggregation.

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
people_dim AS (
    SELECT
        "Customer ID",
        Region,
        MAX(Segment) AS Segment,
        MAX(State) AS State,
        MAX(City) AS City
    FROM people
    GROUP BY 1, 2
),
base AS (
    SELECT
        o.*,
        p.Segment,
        p.State,
        p.City,
        DATE_PART('year', o."Order Date") AS order_year,
        DATE_DIFF('day', o."Order Date", o."Ship Date") AS ship_days,
        CASE
            WHEN o.Quantity = 1 THEN '1'
            WHEN o.Quantity = 2 THEN '2'
            WHEN o.Quantity = 3 THEN '3'
            WHEN o.Quantity BETWEEN 4 AND 5 THEN '4-5'
            ELSE '6+'
        END AS quantity_group,
        CASE WHEN o.Profit < 0 THEN o.Profit ELSE 0 END AS line_gross_loss
    FROM order_lines o
    LEFT JOIN people_dim p
      ON o."Customer ID" = p."Customer ID"
     AND o.Region = p.Region
),
totals AS (
    SELECT
        COUNT(*) AS total_rows,
        SUM(Sales) AS total_sales,
        SUM(CASE WHEN Profit < 0 THEN Profit ELSE 0 END) AS total_gross_loss
    FROM base
),
ship_mode_summary AS (
    SELECT
        'ship_mode' AS screened_path,
        "Ship Mode" AS entity,
        COUNT(*) AS row_count,
        SUM(Sales) AS sales,
        SUM(Profit) AS profit,
        100.0 * SUM(Profit) / NULLIF(SUM(Sales), 0) AS profit_margin_pct,
        AVG(Discount) AS avg_discount,
        SUM(CASE WHEN Profit < 0 THEN Profit ELSE 0 END) AS gross_loss,
        100.0 * SUM(CASE WHEN Profit < 0 THEN Profit ELSE 0 END) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct,
        'reasonable supplement, not core: Standard Class carries most loss exposure, but it also dominates row/sales volume and is weaker as a structural mechanism than discount/product/region' AS screening_decision
    FROM base
    CROSS JOIN totals t
    GROUP BY "Ship Mode"
),
ship_days_summary AS (
    SELECT
        'ship_days' AS screened_path,
        CAST(ship_days AS VARCHAR) AS entity,
        COUNT(*) AS row_count,
        SUM(Sales) AS sales,
        SUM(Profit) AS profit,
        100.0 * SUM(Profit) / NULLIF(SUM(Sales), 0) AS profit_margin_pct,
        AVG(Discount) AS avg_discount,
        SUM(CASE WHEN Profit < 0 THEN Profit ELSE 0 END) AS gross_loss,
        100.0 * SUM(CASE WHEN Profit < 0 THEN Profit ELSE 0 END) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct,
        'not core: shipping delay varies, but the table has no explicit shipping cost and the pattern is less directly tied to profit leakage than discount/product/region' AS screening_decision
    FROM base
    CROSS JOIN totals t
    GROUP BY ship_days
),
year_summary AS (
    SELECT
        'time_year' AS screened_path,
        CAST(order_year AS VARCHAR) AS entity,
        COUNT(*) AS row_count,
        SUM(Sales) AS sales,
        SUM(Profit) AS profit,
        100.0 * SUM(Profit) / NULLIF(SUM(Sales), 0) AS profit_margin_pct,
        AVG(Discount) AS avg_discount,
        SUM(CASE WHEN Profit < 0 THEN Profit ELSE 0 END) AS gross_loss,
        100.0 * SUM(CASE WHEN Profit < 0 THEN Profit ELSE 0 END) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct,
        'not core in lightweight sample: all bundled order lines are in the same year, so no temporal trend can be validated' AS screening_decision
    FROM base
    CROSS JOIN totals t
    GROUP BY order_year
),
quantity_summary AS (
    SELECT
        'quantity_group' AS screened_path,
        quantity_group AS entity,
        COUNT(*) AS row_count,
        SUM(Sales) AS sales,
        SUM(Profit) AS profit,
        100.0 * SUM(Profit) / NULLIF(SUM(Sales), 0) AS profit_margin_pct,
        AVG(Discount) AS avg_discount,
        SUM(CASE WHEN Profit < 0 THEN Profit ELSE 0 END) AS gross_loss,
        100.0 * SUM(CASE WHEN Profit < 0 THEN Profit ELSE 0 END) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct,
        'reasonable supplement, not core: quantity/volume shows conversion differences, but it is confounded with product mix and discount, so it should not displace the main structural mechanisms' AS screening_decision
    FROM base
    CROSS JOIN totals t
    GROUP BY quantity_group
),
order_level AS (
    SELECT
        "Order ID",
        Region,
        COUNT(*) AS line_count,
        SUM(Sales) AS sales,
        SUM(Profit) AS profit,
        AVG(Discount) AS avg_discount,
        MAX(Discount) AS max_discount,
        SUM(line_gross_loss) AS gross_loss
    FROM base
    GROUP BY "Order ID", Region
),
order_discount_summary AS (
    SELECT
        'order_level_discount' AS screened_path,
        CASE WHEN max_discount <= 0.2 THEN '<=0.2 max discount' ELSE '>0.2 max discount' END AS entity,
        COUNT(*) AS row_count,
        SUM(sales) AS sales,
        SUM(profit) AS profit,
        100.0 * SUM(profit) / NULLIF(SUM(sales), 0) AS profit_margin_pct,
        AVG(avg_discount) AS avg_discount,
        SUM(gross_loss) AS gross_loss,
        100.0 * SUM(gross_loss) / NULLIF((SELECT total_gross_loss FROM totals), 0) AS gross_loss_share_pct,
        'confirms discount mechanism at order level, but not a separate Gold path because it repeats the line-level discount finding' AS screening_decision
    FROM order_level
    GROUP BY CASE WHEN max_discount <= 0.2 THEN '<=0.2 max discount' ELSE '>0.2 max discount' END
),
people_coverage AS (
    SELECT
        'people_join_coverage' AS screened_path,
        'Customer ID + Region' AS entity,
        COUNT(*) AS row_count,
        SUM(CASE WHEN Segment IS NOT NULL THEN 1 ELSE 0 END) AS sales,
        SUM(CASE WHEN Segment IS NULL THEN 1 ELSE 0 END) AS profit,
        100.0 * SUM(CASE WHEN Segment IS NOT NULL THEN 1 ELSE 0 END) / COUNT(*) AS profit_margin_pct,
        NULL AS avg_discount,
        NULL AS gross_loss,
        NULL AS gross_loss_share_pct,
        'not core for current lightweight build: people table covers only a small share of order lines, so customer segment/city/state findings would be unstable' AS screening_decision
    FROM base
)
SELECT
    screened_path,
    entity,
    row_count,
    ROUND(sales, 2) AS sales_or_matched_rows,
    ROUND(profit, 2) AS profit_or_unmatched_rows,
    ROUND(profit_margin_pct, 2) AS margin_or_coverage_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    ROUND(gross_loss, 2) AS gross_loss,
    ROUND(gross_loss_share_pct, 2) AS gross_loss_share_pct,
    screening_decision
FROM ship_mode_summary
UNION ALL
SELECT screened_path, entity, row_count, ROUND(sales, 2), ROUND(profit, 2), ROUND(profit_margin_pct, 2), ROUND(avg_discount, 3), ROUND(gross_loss, 2), ROUND(gross_loss_share_pct, 2), screening_decision FROM ship_days_summary
UNION ALL
SELECT screened_path, entity, row_count, ROUND(sales, 2), ROUND(profit, 2), ROUND(profit_margin_pct, 2), ROUND(avg_discount, 3), ROUND(gross_loss, 2), ROUND(gross_loss_share_pct, 2), screening_decision FROM year_summary
UNION ALL
SELECT screened_path, entity, row_count, ROUND(sales, 2), ROUND(profit, 2), ROUND(profit_margin_pct, 2), ROUND(avg_discount, 3), ROUND(gross_loss, 2), ROUND(gross_loss_share_pct, 2), screening_decision FROM quantity_summary
UNION ALL
SELECT screened_path, entity, row_count, ROUND(sales, 2), ROUND(profit, 2), ROUND(profit_margin_pct, 2), ROUND(avg_discount, 3), ROUND(gross_loss, 2), ROUND(gross_loss_share_pct, 2), screening_decision FROM order_discount_summary
UNION ALL
SELECT screened_path, entity, row_count, ROUND(sales, 2), ROUND(profit, 2), ROUND(profit_margin_pct, 2), ROUND(avg_discount, 3), ROUND(gross_loss, 2), ROUND(gross_loss_share_pct, 2), screening_decision FROM people_coverage
ORDER BY screened_path, entity;
