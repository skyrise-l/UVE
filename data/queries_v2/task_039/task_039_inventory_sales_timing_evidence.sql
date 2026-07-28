-- task_039_inventory_sales_timing_evidence.sql
-- Draft task-level Evidence SQL for beer_factory.
-- Light/profile stage only: use the output to screen evidence paths, then recalibrate on full results.

WITH
review_by_brand AS (
    SELECT
        BrandID,
        COUNT(*) AS reviews,
        AVG(StarRating) AS avg_rating
    FROM rootbeerreview
    GROUP BY BrandID
),
sales_fact AS (
    SELECT
        t.TransactionID,
        t.CustomerID,
        t.TransactionDate,
        rb.PurchaseDate,
        DATE_DIFF('day', rb.PurchaseDate, t.TransactionDate) AS sale_lag_days,
        CASE
            WHEN DATE_DIFF('day', rb.PurchaseDate, t.TransactionDate) < 0 THEN 'sold_before_item_purchase_date'
            WHEN DATE_DIFF('day', rb.PurchaseDate, t.TransactionDate) <= 7 THEN 'same_week'
            WHEN DATE_DIFF('day', rb.PurchaseDate, t.TransactionDate) <= 30 THEN 'days_8_to_30'
            WHEN DATE_DIFF('day', rb.PurchaseDate, t.TransactionDate) <= 180 THEN 'days_31_to_180'
            ELSE 'days_181_plus'
        END AS sale_lag_bucket,
        SUBSTR(CAST(t.TransactionDate AS VARCHAR), 1, 4) AS transaction_year,
        t.PurchasePrice,
        l.LocationName,
        rb.RootBeerID,
        rb.ContainerType,
        b.BrandID,
        b.BrandName,
        b.WholesaleCost,
        t.PurchasePrice - b.WholesaleCost AS gross_margin_proxy,
        rbw.reviews AS brand_reviews,
        rbw.avg_rating AS brand_avg_rating
    FROM "transaction" t
    JOIN location l ON t.LocationID = l.LocationID
    JOIN rootbeer rb ON t.RootBeerID = rb.RootBeerID
    JOIN rootbeerbrand b ON rb.BrandID = b.BrandID
    LEFT JOIN review_by_brand rbw ON b.BrandID = rbw.BrandID
),
lag_bucket_metrics AS (
    SELECT
        sale_lag_bucket,
        COUNT(*) AS transactions,
        COUNT(DISTINCT CustomerID) AS customers,
        COUNT(DISTINCT BrandID) AS brands,
        COUNT(DISTINCT LocationName) AS locations,
        AVG(CAST(sale_lag_days AS DOUBLE)) AS avg_sale_lag_days,
        SUM(PurchasePrice) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(PurchasePrice), 0) AS gross_margin_proxy_rate,
        AVG(brand_avg_rating) AS avg_rating
    FROM sales_fact
    GROUP BY sale_lag_bucket
),
ranked_lag_bucket AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY transactions DESC, sale_lag_bucket) AS transaction_rank,
        ROW_NUMBER() OVER (ORDER BY avg_sale_lag_days DESC, sale_lag_bucket) AS lag_rank,
        ROW_NUMBER() OVER (ORDER BY gross_margin_proxy_rate DESC, sale_lag_bucket) AS margin_rank,
        ROW_NUMBER() OVER (ORDER BY avg_rating DESC, sale_lag_bucket) AS rating_rank
    FROM lag_bucket_metrics
),
brand_lag AS (
    SELECT
        BrandName,
        COUNT(*) AS transactions,
        COUNT(DISTINCT CustomerID) AS customers,
        AVG(CAST(sale_lag_days AS DOUBLE)) AS avg_sale_lag_days,
        SUM(PurchasePrice) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(PurchasePrice), 0) AS gross_margin_proxy_rate,
        AVG(brand_avg_rating) AS avg_rating,
        ROW_NUMBER() OVER (ORDER BY AVG(CAST(sale_lag_days AS DOUBLE)) DESC, COUNT(*) DESC, BrandName) AS longest_lag_rank,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, BrandName) AS transaction_rank
    FROM sales_fact
    GROUP BY BrandName
),
container_location_lag AS (
    SELECT
        ContainerType,
        LocationName,
        COUNT(*) AS transactions,
        COUNT(DISTINCT CustomerID) AS customers,
        COUNT(DISTINCT BrandID) AS brands,
        AVG(CAST(sale_lag_days AS DOUBLE)) AS avg_sale_lag_days,
        SUM(PurchasePrice) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(PurchasePrice), 0) AS gross_margin_proxy_rate,
        AVG(brand_avg_rating) AS avg_rating,
        ROW_NUMBER() OVER (ORDER BY AVG(CAST(sale_lag_days AS DOUBLE)) DESC, COUNT(*) DESC, ContainerType, LocationName) AS lag_rank
    FROM sales_fact
    GROUP BY ContainerType, LocationName
),
year_lag AS (
    SELECT
        transaction_year,
        sale_lag_bucket,
        COUNT(*) AS transactions,
        COUNT(DISTINCT CustomerID) AS customers,
        COUNT(DISTINCT BrandID) AS brands,
        AVG(CAST(sale_lag_days AS DOUBLE)) AS avg_sale_lag_days,
        SUM(PurchasePrice) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(PurchasePrice), 0) AS gross_margin_proxy_rate,
        AVG(brand_avg_rating) AS avg_rating,
        ROW_NUMBER() OVER (PARTITION BY transaction_year ORDER BY COUNT(*) DESC, sale_lag_bucket) AS lag_bucket_rank_in_year
    FROM sales_fact
    GROUP BY transaction_year, sale_lag_bucket
),
lag_signal_gap AS (
    SELECT
        *,
        ABS(transaction_rank - lag_rank) AS volume_lag_rank_gap,
        ABS(transaction_rank - margin_rank) AS volume_margin_rank_gap,
        ABS(transaction_rank - rating_rank) AS volume_rating_rank_gap
    FROM ranked_lag_bucket
)
SELECT
    'sales_lag_bucket_baseline' AS evidence_block,
    'sale_lag_bucket' AS grain,
    sale_lag_bucket AS item,
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
    ROUND(avg_rating, 4) AS avg_rating,
    ROUND(avg_sale_lag_days, 4) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Establish sale-lag buckets between item purchase date and customer transaction date.' AS notes
FROM ranked_lag_bucket
UNION ALL
SELECT
    'sales_lag_quality_comparison' AS evidence_block,
    'sale_lag_bucket' AS grain,
    sale_lag_bucket AS item,
    CAST(transaction_rank AS VARCHAR) AS item_2,
    CAST(rating_rank AS VARCHAR) || '/' || CAST(margin_rank AS VARCHAR) AS item_3,
    'max_lag_quality_rank_gap' AS rank_label,
    CAST(
        CASE
            WHEN volume_rating_rank_gap >= volume_margin_rank_gap THEN volume_rating_rank_gap
            ELSE volume_margin_rank_gap
        END AS DOUBLE
    ) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(brands AS BIGINT) AS brands,
    CAST(NULL AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_rating, 4) AS avg_rating,
    ROUND(avg_sale_lag_days, 4) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Check whether slower-moving stock buckets differ in rating or margin proxy quality.' AS notes
FROM lag_signal_gap
UNION ALL
SELECT
    'brand_sales_lag_exception' AS evidence_block,
    'brand' AS grain,
    BrandName AS item,
    CAST(transaction_rank AS VARCHAR) AS item_2,
    CAST(longest_lag_rank AS VARCHAR) AS item_3,
    'longest_lag_rank' AS rank_label,
    CAST(longest_lag_rank AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(1 AS BIGINT) AS brands,
    CAST(NULL AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_rating, 4) AS avg_rating,
    ROUND(avg_sale_lag_days, 4) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Identify brands whose sale-lag behavior differs from their demand scale.' AS notes
FROM brand_lag
UNION ALL
SELECT
    'container_location_lag' AS evidence_block,
    'container_location' AS grain,
    ContainerType AS item,
    LocationName AS item_2,
    CAST(lag_rank AS VARCHAR) AS item_3,
    'avg_sale_lag_days_rank' AS rank_label,
    CAST(lag_rank AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(brands AS BIGINT) AS brands,
    CAST(NULL AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_rating, 4) AS avg_rating,
    ROUND(avg_sale_lag_days, 4) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Check whether sale lag is tied to container and location cells.' AS notes
FROM container_location_lag
UNION ALL
SELECT
    'year_lag_mix' AS evidence_block,
    'transaction_year_lag_bucket' AS grain,
    transaction_year AS item,
    sale_lag_bucket AS item_2,
    CAST(lag_bucket_rank_in_year AS VARCHAR) AS item_3,
    'lag_bucket_rank_in_year' AS rank_label,
    CAST(lag_bucket_rank_in_year AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(brands AS BIGINT) AS brands,
    CAST(NULL AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_rating, 4) AS avg_rating,
    ROUND(avg_sale_lag_days, 4) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Track whether sale-lag composition changes across transaction years.' AS notes
FROM year_lag;
