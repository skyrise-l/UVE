-- task_001_profit_leakage_evidence.sql
-- Whole-task Evidence SQL for Superstore profit-leakage EDA.
-- The output is a tall evidence table split by insight_id / evidence_block.
-- Construction logic:
--   G1 establishes the sales-to-profit baseline.
--   G2-G3 test whether discount creates a clear profit break and concentrated loss exposure.
--   G4-G5 locate product-category and sub-category leakage.
--   G6-G7 compare regional conversion and regional discount/loss exposure.
--   G8 checks the key region x product interaction so the Gold does not miss cross-dimensional structure.

WITH
-- ---------- Base grain: regional order lines ----------
order_lines AS (
    SELECT 'central_superstore' AS source_table, * FROM central_superstore
    UNION ALL
    SELECT 'east_superstore' AS source_table, * FROM east_superstore
    UNION ALL
    SELECT 'south_superstore' AS source_table, * FROM south_superstore
    UNION ALL
    SELECT 'west_superstore' AS source_table, * FROM west_superstore
),
-- Product table should be unique by Product ID + Region in the full BIRD data.
-- The CASE fallback keeps the bundled lightweight sample executable even when product sample rows are not exhaustive.
product_dim AS (
    SELECT
        "Product ID",
        Region,
        MAX(Category) AS Category,
        MAX("Sub-Category") AS "Sub-Category"
    FROM product
    GROUP BY 1, 2
),
enriched_lines AS (
    SELECT
        o.*,
        COALESCE(
            p.Category,
            CASE split_part(o."Product ID", '-', 1)
                WHEN 'FUR' THEN 'Furniture'
                WHEN 'OFF' THEN 'Office Supplies'
                WHEN 'TEC' THEN 'Technology'
                ELSE 'Unknown'
            END
        ) AS category,
        COALESCE(
            p."Sub-Category",
            CASE split_part(o."Product ID", '-', 2)
                WHEN 'BO' THEN 'Bookcases'
                WHEN 'CH' THEN 'Chairs'
                WHEN 'FU' THEN 'Furnishings'
                WHEN 'TA' THEN 'Tables'
                WHEN 'AP' THEN 'Appliances'
                WHEN 'AR' THEN 'Art'
                WHEN 'BI' THEN 'Binders'
                WHEN 'EN' THEN 'Envelopes'
                WHEN 'FA' THEN 'Fasteners'
                WHEN 'LA' THEN 'Labels'
                WHEN 'PA' THEN 'Paper'
                WHEN 'ST' THEN 'Storage'
                WHEN 'SU' THEN 'Supplies'
                WHEN 'AC' THEN 'Accessories'
                WHEN 'CO' THEN 'Copiers'
                WHEN 'MA' THEN 'Machines'
                WHEN 'PH' THEN 'Phones'
                ELSE 'Unknown'
            END
        ) AS sub_category,
        CASE WHEN o.Discount <= 0.2 THEN '<=0.2' ELSE '>0.2' END AS discount_group
    FROM order_lines o
    LEFT JOIN product_dim p
      ON o."Product ID" = p."Product ID"
     AND o.Region = p.Region
),
totals AS (
    SELECT
        COUNT(*) AS total_rows,
        SUM(Sales) AS total_sales,
        SUM(Profit) AS total_profit,
        SUM(CASE WHEN Profit < 0 THEN Profit ELSE 0 END) AS total_gross_loss
    FROM enriched_lines
),
overall_summary AS (
    SELECT
        COUNT(*) AS row_count,
        100.0 AS row_share_pct,
        SUM(Sales) AS sales,
        100.0 AS sales_share_pct,
        SUM(Profit) AS profit,
        100.0 * SUM(Profit) / NULLIF(SUM(Sales), 0) AS profit_margin_pct,
        AVG(Discount) AS avg_discount,
        SUM(CASE WHEN Profit < 0 THEN 1 ELSE 0 END) AS loss_line_count,
        SUM(CASE WHEN Profit < 0 THEN Profit ELSE 0 END) AS gross_loss,
        100.0 AS gross_loss_share_pct
    FROM enriched_lines
),
discount_group_summary AS (
    SELECT
        discount_group,
        COUNT(*) AS row_count,
        100.0 * COUNT(*) / MAX(t.total_rows) AS row_share_pct,
        SUM(Sales) AS sales,
        100.0 * SUM(Sales) / MAX(t.total_sales) AS sales_share_pct,
        SUM(Profit) AS profit,
        100.0 * SUM(Profit) / NULLIF(SUM(Sales), 0) AS profit_margin_pct,
        AVG(Discount) AS avg_discount,
        SUM(CASE WHEN Profit < 0 THEN 1 ELSE 0 END) AS loss_line_count,
        SUM(CASE WHEN Profit < 0 THEN Profit ELSE 0 END) AS gross_loss,
        100.0 * SUM(CASE WHEN Profit < 0 THEN Profit ELSE 0 END) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct
    FROM enriched_lines
    CROSS JOIN totals t
    GROUP BY discount_group
),
discount_exact_summary AS (
    SELECT
        CAST(Discount AS VARCHAR) AS discount_label,
        Discount,
        COUNT(*) AS row_count,
        100.0 * COUNT(*) / MAX(t.total_rows) AS row_share_pct,
        SUM(Sales) AS sales,
        100.0 * SUM(Sales) / MAX(t.total_sales) AS sales_share_pct,
        SUM(Profit) AS profit,
        100.0 * SUM(Profit) / NULLIF(SUM(Sales), 0) AS profit_margin_pct,
        AVG(Discount) AS avg_discount,
        SUM(CASE WHEN Profit < 0 THEN 1 ELSE 0 END) AS loss_line_count,
        SUM(CASE WHEN Profit < 0 THEN Profit ELSE 0 END) AS gross_loss,
        100.0 * SUM(CASE WHEN Profit < 0 THEN Profit ELSE 0 END) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct
    FROM enriched_lines
    CROSS JOIN totals t
    GROUP BY Discount
),
category_summary AS (
    SELECT
        category,
        COUNT(*) AS row_count,
        100.0 * COUNT(*) / MAX(t.total_rows) AS row_share_pct,
        SUM(Sales) AS sales,
        100.0 * SUM(Sales) / MAX(t.total_sales) AS sales_share_pct,
        SUM(Profit) AS profit,
        100.0 * SUM(Profit) / NULLIF(SUM(Sales), 0) AS profit_margin_pct,
        AVG(Discount) AS avg_discount,
        SUM(CASE WHEN Profit < 0 THEN 1 ELSE 0 END) AS loss_line_count,
        SUM(CASE WHEN Profit < 0 THEN Profit ELSE 0 END) AS gross_loss,
        100.0 * SUM(CASE WHEN Profit < 0 THEN Profit ELSE 0 END) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct
    FROM enriched_lines
    CROSS JOIN totals t
    GROUP BY category
),
subcategory_summary AS (
    SELECT
        category,
        sub_category,
        COUNT(*) AS row_count,
        100.0 * COUNT(*) / MAX(t.total_rows) AS row_share_pct,
        SUM(Sales) AS sales,
        100.0 * SUM(Sales) / MAX(t.total_sales) AS sales_share_pct,
        SUM(Profit) AS profit,
        100.0 * SUM(Profit) / NULLIF(SUM(Sales), 0) AS profit_margin_pct,
        AVG(Discount) AS avg_discount,
        SUM(CASE WHEN Profit < 0 THEN 1 ELSE 0 END) AS loss_line_count,
        SUM(CASE WHEN Profit < 0 THEN Profit ELSE 0 END) AS gross_loss,
        100.0 * SUM(CASE WHEN Profit < 0 THEN Profit ELSE 0 END) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct,
        ROW_NUMBER() OVER (ORDER BY SUM(Profit) ASC) AS profit_rank_ascending
    FROM enriched_lines
    CROSS JOIN totals t
    GROUP BY category, sub_category
),
region_summary AS (
    SELECT
        Region,
        COUNT(*) AS row_count,
        100.0 * COUNT(*) / MAX(t.total_rows) AS row_share_pct,
        SUM(Sales) AS sales,
        100.0 * SUM(Sales) / MAX(t.total_sales) AS sales_share_pct,
        SUM(Profit) AS profit,
        100.0 * SUM(Profit) / NULLIF(SUM(Sales), 0) AS profit_margin_pct,
        AVG(Discount) AS avg_discount,
        SUM(CASE WHEN Profit < 0 THEN 1 ELSE 0 END) AS loss_line_count,
        SUM(CASE WHEN Profit < 0 THEN Profit ELSE 0 END) AS gross_loss,
        100.0 * SUM(CASE WHEN Profit < 0 THEN Profit ELSE 0 END) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct,
        RANK() OVER (ORDER BY SUM(Sales) DESC) AS sales_rank_desc,
        RANK() OVER (ORDER BY 100.0 * SUM(Profit) / NULLIF(SUM(Sales), 0) DESC) AS margin_rank_desc,
        RANK() OVER (ORDER BY AVG(Discount) DESC) AS discount_rank_desc,
        RANK() OVER (ORDER BY SUM(CASE WHEN Profit < 0 THEN Profit ELSE 0 END) ASC) AS gross_loss_rank_desc
    FROM enriched_lines
    CROSS JOIN totals t
    GROUP BY Region
),
region_category_summary AS (
    SELECT
        Region,
        category,
        COUNT(*) AS row_count,
        100.0 * COUNT(*) / MAX(t.total_rows) AS row_share_pct,
        SUM(Sales) AS sales,
        100.0 * SUM(Sales) / MAX(t.total_sales) AS sales_share_pct,
        SUM(Profit) AS profit,
        100.0 * SUM(Profit) / NULLIF(SUM(Sales), 0) AS profit_margin_pct,
        AVG(Discount) AS avg_discount,
        SUM(CASE WHEN Profit < 0 THEN 1 ELSE 0 END) AS loss_line_count,
        SUM(CASE WHEN Profit < 0 THEN Profit ELSE 0 END) AS gross_loss,
        100.0 * SUM(CASE WHEN Profit < 0 THEN Profit ELSE 0 END) / NULLIF(MAX(t.total_gross_loss), 0) AS gross_loss_share_pct,
        ROW_NUMBER() OVER (ORDER BY SUM(Profit) ASC) AS profit_rank_ascending
    FROM enriched_lines
    CROSS JOIN totals t
    GROUP BY Region, category
),
evidence AS (
    SELECT
        'G1' AS insight_id,
        'overall_profit_baseline' AS evidence_block,
        'overall' AS entity_level,
        'All regions' AS entity,
        CAST(NULL AS VARCHAR) AS parent_entity,
        row_count,
        row_share_pct,
        sales,
        sales_share_pct,
        profit,
        profit_margin_pct,
        avg_discount,
        loss_line_count,
        gross_loss,
        gross_loss_share_pct,
        'Baseline: total sales are much larger than net profit, and loss-making rows offset profitable rows.' AS note,
        1 AS sort_order
    FROM overall_summary

    UNION ALL
    SELECT
        'G2',
        'discount_profit_threshold',
        'discount_group',
        discount_group,
        CAST(NULL AS VARCHAR),
        row_count,
        row_share_pct,
        sales,
        sales_share_pct,
        profit,
        profit_margin_pct,
        avg_discount,
        loss_line_count,
        gross_loss,
        gross_loss_share_pct,
        'Discount sign-flip comparison: <=0.2 remains profitable overall, while >0.2 is loss-making.',
        CASE WHEN discount_group = '<=0.2' THEN 2 ELSE 3 END
    FROM discount_group_summary

    UNION ALL
    SELECT
        'G3',
        'discount_loss_concentration',
        'discount_group',
        discount_group,
        CAST(NULL AS VARCHAR),
        row_count,
        row_share_pct,
        sales,
        sales_share_pct,
        profit,
        profit_margin_pct,
        avg_discount,
        loss_line_count,
        gross_loss,
        gross_loss_share_pct,
        'Discount concentration comparison: high-discount rows are a minority of rows but carry almost all gross loss.',
        CASE WHEN discount_group = '<=0.2' THEN 4 ELSE 5 END
    FROM discount_group_summary

    UNION ALL
    SELECT
        'G3',
        'discount_loss_concentration',
        'exact_discount',
        discount_label,
        CAST(NULL AS VARCHAR),
        row_count,
        row_share_pct,
        sales,
        sales_share_pct,
        profit,
        profit_margin_pct,
        avg_discount,
        loss_line_count,
        gross_loss,
        gross_loss_share_pct,
        'Exact discount profile: every observed discount level above 0.2 is loss-making overall.',
        10 + CAST(ROUND(Discount * 100) AS INTEGER)
    FROM discount_exact_summary

    UNION ALL
    SELECT
        'G4',
        'category_profit_structure',
        'category',
        category,
        CAST(NULL AS VARCHAR),
        row_count,
        row_share_pct,
        sales,
        sales_share_pct,
        profit,
        profit_margin_pct,
        avg_discount,
        loss_line_count,
        gross_loss,
        gross_loss_share_pct,
        'Category comparison: only Furniture is net loss-making; the other top-level categories remain profitable.',
        CASE category WHEN 'Furniture' THEN 101 WHEN 'Office Supplies' THEN 102 WHEN 'Technology' THEN 103 ELSE 109 END
    FROM category_summary

    UNION ALL
    SELECT
        'G5',
        'subcategory_loss_concentration',
        'subcategory',
        sub_category,
        category,
        row_count,
        row_share_pct,
        sales,
        sales_share_pct,
        profit,
        profit_margin_pct,
        avg_discount,
        loss_line_count,
        gross_loss,
        gross_loss_share_pct,
        'Sub-category comparison ordered by net profit, showing concentrated product leakage rather than broad underperformance.',
        200 + profit_rank_ascending
    FROM subcategory_summary

    UNION ALL
    SELECT
        'G6',
        'region_conversion_divergence',
        'region',
        Region,
        CAST(NULL AS VARCHAR),
        row_count,
        row_share_pct,
        sales,
        sales_share_pct,
        profit,
        profit_margin_pct,
        avg_discount,
        loss_line_count,
        gross_loss,
        gross_loss_share_pct,
        'Regional conversion comparison: sales rank and margin rank do not align.',
        300 + sales_rank_desc
    FROM region_summary

    UNION ALL
    SELECT
        'G7',
        'region_discount_loss_exposure',
        'region',
        Region,
        CAST(NULL AS VARCHAR),
        row_count,
        row_share_pct,
        sales,
        sales_share_pct,
        profit,
        profit_margin_pct,
        avg_discount,
        loss_line_count,
        gross_loss,
        gross_loss_share_pct,
        'Regional exposure comparison: discount and gross-loss concentration help explain conversion differences.',
        400 + gross_loss_rank_desc
    FROM region_summary

    UNION ALL
    SELECT
        'G8',
        'region_category_interaction',
        'region_category',
        Region || ' / ' || category,
        category,
        row_count,
        row_share_pct,
        sales,
        sales_share_pct,
        profit,
        profit_margin_pct,
        avg_discount,
        loss_line_count,
        gross_loss,
        gross_loss_share_pct,
        'Region x category comparison: Furniture leakage is concentrated in specific regions rather than uniform across all regions.',
        500 + profit_rank_ascending
    FROM region_category_summary
)
SELECT
    insight_id,
    evidence_block,
    entity_level,
    entity,
    parent_entity,
    row_count,
    ROUND(row_share_pct, 2) AS row_share_pct,
    ROUND(sales, 2) AS sales,
    ROUND(sales_share_pct, 2) AS sales_share_pct,
    ROUND(profit, 2) AS profit,
    ROUND(profit_margin_pct, 2) AS profit_margin_pct,
    ROUND(avg_discount, 3) AS avg_discount,
    loss_line_count,
    ROUND(gross_loss, 2) AS gross_loss,
    ROUND(gross_loss_share_pct, 2) AS gross_loss_share_pct,
    note
FROM evidence
ORDER BY sort_order, entity;
