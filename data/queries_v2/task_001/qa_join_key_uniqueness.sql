-- QA only: verify composite-key uniqueness for joined dimension tables.
-- This supports audit of Product ID + Region and Customer ID + Region grains; it is not Gold evidence.
WITH product_keys AS (
    SELECT
        'product' AS table_name,
        COUNT(*) AS row_count,
        COUNT(DISTINCT COALESCE("Product ID", '') || '\u001F' || COALESCE(Region, '')) AS distinct_composite_keys
    FROM product
),
people_keys AS (
    SELECT
        'people' AS table_name,
        COUNT(*) AS row_count,
        COUNT(DISTINCT COALESCE("Customer ID", '') || '\u001F' || COALESCE(Region, '')) AS distinct_composite_keys
    FROM people
)
SELECT
    table_name,
    row_count,
    distinct_composite_keys,
    row_count - distinct_composite_keys AS duplicate_key_rows,
    CASE WHEN row_count = distinct_composite_keys THEN 'pass' ELSE 'check_duplicates' END AS qa_status
FROM product_keys
UNION ALL
SELECT
    table_name,
    row_count,
    distinct_composite_keys,
    row_count - distinct_composite_keys AS duplicate_key_rows,
    CASE WHEN row_count = distinct_composite_keys THEN 'pass' ELSE 'check_duplicates' END AS qa_status
FROM people_keys
ORDER BY table_name;
