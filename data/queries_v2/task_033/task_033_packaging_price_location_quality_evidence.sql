-- task_033_packaging_price_location_quality_evidence.sql
-- Draft task-level Evidence SQL for packaging, price, and location quality in beer_factory.

WITH
sales_fact AS (
    SELECT
        t.TransactionID,
        t.CustomerID,
        t.LocationID,
        COALESCE(l.LocationName, 'Unknown') AS LocationName,
        t.PurchasePrice,
        rb.RootBeerID,
        rb.ContainerType,
        rb.BrandID,
        b.BrandName,
        b.CurrentRetailPrice,
        b.WholesaleCost,
        t.PurchasePrice / NULLIF(b.CurrentRetailPrice, 0) AS price_realization,
        t.PurchasePrice - b.WholesaleCost AS gross_margin_proxy
    FROM "transaction" t
    JOIN rootbeer rb ON t.RootBeerID = rb.RootBeerID
    JOIN rootbeerbrand b ON rb.BrandID = b.BrandID
    LEFT JOIN location l ON t.LocationID = l.LocationID
),
totals AS (
    SELECT
        COUNT(*) AS total_transactions,
        SUM(PurchasePrice) AS total_revenue,
        SUM(gross_margin_proxy) AS total_gross_margin_proxy
    FROM sales_fact
),
container_summary AS (
    SELECT
        ContainerType,
        COUNT(*) AS transactions,
        COUNT(DISTINCT CustomerID) AS customers,
        COUNT(DISTINCT BrandID) AS brands,
        SUM(PurchasePrice) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(PurchasePrice), 0) AS gross_margin_proxy_rate,
        AVG(price_realization) AS avg_price_realization
    FROM sales_fact
    GROUP BY ContainerType
),
location_summary AS (
    SELECT
        LocationName,
        COUNT(*) AS transactions,
        COUNT(DISTINCT CustomerID) AS customers,
        COUNT(DISTINCT BrandID) AS brands,
        SUM(PurchasePrice) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(PurchasePrice), 0) AS gross_margin_proxy_rate,
        AVG(price_realization) AS avg_price_realization
    FROM sales_fact
    GROUP BY LocationName
),
container_location AS (
    SELECT
        ContainerType,
        LocationName,
        COUNT(*) AS transactions,
        SUM(PurchasePrice) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(PurchasePrice), 0) AS gross_margin_proxy_rate,
        AVG(price_realization) AS avg_price_realization
    FROM sales_fact
    GROUP BY ContainerType, LocationName
),
ranked_container AS (
    SELECT
        cs.*,
        100.0 * cs.transactions / NULLIF(t.total_transactions, 0) AS transaction_share_pct,
        ROW_NUMBER() OVER (ORDER BY cs.transactions DESC, cs.ContainerType) AS transaction_rank,
        ROW_NUMBER() OVER (ORDER BY cs.gross_margin_proxy_rate DESC, cs.ContainerType) AS margin_rate_rank
    FROM container_summary cs
    CROSS JOIN totals t
),
ranked_location AS (
    SELECT
        ls.*,
        100.0 * ls.transactions / NULLIF(t.total_transactions, 0) AS transaction_share_pct,
        ROW_NUMBER() OVER (ORDER BY ls.transactions DESC, ls.LocationName) AS transaction_rank,
        ROW_NUMBER() OVER (ORDER BY ls.gross_margin_proxy_rate DESC, ls.LocationName) AS margin_rate_rank
    FROM location_summary ls
    CROSS JOIN totals t
)
SELECT
    'container_transaction_baseline' AS evidence_block,
    'container' AS grain,
    ContainerType AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'transaction_rank' AS rank_label,
    CAST(transaction_rank AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(brands AS BIGINT) AS brands,
    CAST(NULL AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_price_realization, 4) AS avg_rating,
    ROUND(transaction_share_pct, 4) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Establish packaging demand baseline.' AS notes
FROM ranked_container
UNION ALL
SELECT
    'container_margin_proxy_quality' AS evidence_block,
    'container' AS grain,
    ContainerType AS item,
    CAST(transaction_rank AS VARCHAR) AS item_2,
    CAST(margin_rate_rank AS VARCHAR) AS item_3,
    'margin_rate_rank' AS rank_label,
    CAST(margin_rate_rank AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(brands AS BIGINT) AS brands,
    CAST(NULL AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_price_realization, 4) AS avg_rating,
    ROUND(transaction_share_pct, 4) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Compare packaging on margin proxy, not only volume.' AS notes
FROM ranked_container
UNION ALL
SELECT
    'price_realization_baseline' AS evidence_block,
    'container' AS grain,
    ContainerType AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'avg_price_realization' AS rank_label,
    CAST(avg_price_realization AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(brands AS BIGINT) AS brands,
    CAST(NULL AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_price_realization, 4) AS avg_rating,
    ROUND(transaction_share_pct, 4) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Check whether realized purchase price aligns with listed retail price.' AS notes
FROM ranked_container
UNION ALL
SELECT
    'location_margin_proxy_quality' AS evidence_block,
    'location' AS grain,
    LocationName AS item,
    CAST(transaction_rank AS VARCHAR) AS item_2,
    CAST(margin_rate_rank AS VARCHAR) AS item_3,
    'location_margin_rate_rank' AS rank_label,
    CAST(margin_rate_rank AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(brands AS BIGINT) AS brands,
    CAST(NULL AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_price_realization, 4) AS avg_rating,
    ROUND(transaction_share_pct, 4) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Separate location business quality from volume.' AS notes
FROM ranked_location
UNION ALL
SELECT
    'location_container_mix' AS evidence_block,
    'location_container' AS grain,
    LocationName AS item,
    ContainerType AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'transactions' AS rank_label,
    CAST(transactions AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(NULL AS BIGINT) AS customers,
    CAST(NULL AS BIGINT) AS brands,
    CAST(NULL AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_price_realization, 4) AS avg_rating,
    CAST(NULL AS DOUBLE) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Inspect whether container patterns are location mix effects.' AS notes
FROM container_location
UNION ALL
SELECT
    'container_location_quality_mismatch' AS evidence_block,
    'location_container' AS grain,
    LocationName AS item,
    ContainerType AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'margin_proxy_rate_pct' AS rank_label,
    CAST(100.0 * gross_margin_proxy_rate AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(NULL AS BIGINT) AS customers,
    CAST(NULL AS BIGINT) AS brands,
    CAST(NULL AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_price_realization, 4) AS avg_rating,
    CAST(NULL AS DOUBLE) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Find container-location cells where quality differs from simple transaction volume.' AS notes
FROM container_location
ORDER BY evidence_block, rank_value DESC NULLS LAST, item;
