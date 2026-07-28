-- QA only: report how many order lines find an exact Product ID + Region match in product.
-- The bundled lightweight sample is not necessarily exhaustive, so the evidence SQL has an ID-prefix fallback for sample execution.
WITH order_lines AS (
    SELECT 'central_superstore' AS source_table, * FROM central_superstore
    UNION ALL
    SELECT 'east_superstore' AS source_table, * FROM east_superstore
    UNION ALL
    SELECT 'south_superstore' AS source_table, * FROM south_superstore
    UNION ALL
    SELECT 'west_superstore' AS source_table, * FROM west_superstore
),
product_dim AS (
    SELECT "Product ID", Region
    FROM product
    GROUP BY 1, 2
),
joined AS (
    SELECT
        o.Region,
        o."Product ID",
        CASE WHEN p."Product ID" IS NULL THEN 0 ELSE 1 END AS has_product_match
    FROM order_lines o
    LEFT JOIN product_dim p
      ON o."Product ID" = p."Product ID"
     AND o.Region = p.Region
)
SELECT
    Region,
    COUNT(*) AS order_line_count,
    SUM(has_product_match) AS matched_order_lines,
    COUNT(*) - SUM(has_product_match) AS unmatched_order_lines,
    ROUND(100.0 * SUM(has_product_match) / NULLIF(COUNT(*), 0), 2) AS product_join_coverage_pct
FROM joined
GROUP BY Region
UNION ALL
SELECT
    'ALL' AS Region,
    COUNT(*) AS order_line_count,
    SUM(has_product_match) AS matched_order_lines,
    COUNT(*) - SUM(has_product_match) AS unmatched_order_lines,
    ROUND(100.0 * SUM(has_product_match) / NULLIF(COUNT(*), 0), 2) AS product_join_coverage_pct
FROM joined
ORDER BY Region;
