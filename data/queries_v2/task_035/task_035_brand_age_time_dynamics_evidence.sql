-- task_035_brand_age_time_dynamics_evidence.sql
-- Draft task-level Evidence SQL for beer_factory brand age and lifecycle dynamics.

WITH
sales_fact AS (
    SELECT
        t.TransactionID,
        t.CustomerID,
        t.TransactionDate,
        CAST(substr(CAST(t.TransactionDate AS VARCHAR), 1, 4) AS INTEGER) AS transaction_year,
        t.PurchasePrice,
        rb.RootBeerID,
        rb.BrandID,
        b.BrandName,
        b.FirstBrewedYear,
        CASE
            WHEN b.FirstBrewedYear < 1950 THEN 'heritage_pre_1950'
            WHEN b.FirstBrewedYear < 1990 THEN 'mid_age_1950_1989'
            ELSE 'newer_1990_plus'
        END AS brand_age_group,
        b.WholesaleCost,
        t.PurchasePrice - b.WholesaleCost AS gross_margin_proxy
    FROM "transaction" t
    JOIN rootbeer rb ON t.RootBeerID = rb.RootBeerID
    JOIN rootbeerbrand b ON rb.BrandID = b.BrandID
),
review_fact AS (
    SELECT
        r.CustomerID,
        r.BrandID,
        CAST(substr(CAST(r.ReviewDate AS VARCHAR), 1, 4) AS INTEGER) AS review_year,
        r.StarRating,
        b.BrandName,
        b.FirstBrewedYear,
        CASE
            WHEN b.FirstBrewedYear < 1950 THEN 'heritage_pre_1950'
            WHEN b.FirstBrewedYear < 1990 THEN 'mid_age_1950_1989'
            ELSE 'newer_1990_plus'
        END AS brand_age_group
    FROM rootbeerreview r
    JOIN rootbeerbrand b ON r.BrandID = b.BrandID
),
brand_sales AS (
    SELECT
        BrandID,
        BrandName,
        FirstBrewedYear,
        brand_age_group,
        COUNT(*) AS transactions,
        COUNT(DISTINCT CustomerID) AS customers,
        SUM(PurchasePrice) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(PurchasePrice), 0) AS gross_margin_proxy_rate,
        MIN(transaction_year) AS first_observed_purchase_year,
        MAX(transaction_year) AS last_observed_purchase_year
    FROM sales_fact
    GROUP BY BrandID, BrandName, FirstBrewedYear, brand_age_group
),
brand_reviews AS (
    SELECT
        BrandID,
        COUNT(*) AS review_count,
        AVG(StarRating) AS avg_rating,
        MIN(review_year) AS first_review_year,
        MAX(review_year) AS last_review_year
    FROM review_fact
    GROUP BY BrandID
),
brand_metrics AS (
    SELECT
        bs.*,
        COALESCE(br.review_count, 0) AS review_count,
        br.avg_rating,
        br.first_review_year,
        br.last_review_year,
        ROW_NUMBER() OVER (ORDER BY bs.transactions DESC, bs.BrandName) AS transaction_rank,
        ROW_NUMBER() OVER (ORDER BY br.avg_rating DESC NULLS LAST, COALESCE(br.review_count, 0) DESC, bs.BrandName) AS rating_rank
    FROM brand_sales bs
    LEFT JOIN brand_reviews br ON bs.BrandID = br.BrandID
),
age_group_summary AS (
    SELECT
        brand_age_group,
        COUNT(*) AS brands,
        SUM(transactions) AS transactions,
        SUM(customers) AS customers,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(revenue), 0) AS gross_margin_proxy_rate,
        SUM(review_count) AS review_count,
        SUM(avg_rating * review_count) / NULLIF(SUM(review_count), 0) AS weighted_avg_rating
    FROM brand_metrics
    GROUP BY brand_age_group
),
purchase_year_summary AS (
    SELECT
        brand_age_group,
        transaction_year,
        COUNT(*) AS transactions,
        COUNT(DISTINCT BrandID) AS brands,
        SUM(PurchasePrice) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(PurchasePrice), 0) AS gross_margin_proxy_rate
    FROM sales_fact
    GROUP BY brand_age_group, transaction_year
),
review_year_summary AS (
    SELECT
        brand_age_group,
        review_year,
        COUNT(*) AS reviews,
        AVG(StarRating) AS avg_rating
    FROM review_fact
    GROUP BY brand_age_group, review_year
)
SELECT
    'brand_age_group_baseline' AS evidence_block,
    'brand_age_group' AS grain,
    brand_age_group AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'brands_in_group' AS rank_label,
    CAST(brands AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(brands AS BIGINT) AS brands,
    CAST(review_count AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(weighted_avg_rating, 4) AS avg_rating,
    CAST(NULL AS DOUBLE) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Establish brand-age groups before interpreting heritage.' AS notes
FROM age_group_summary
UNION ALL
SELECT
    'brand_age_demand_comparison' AS evidence_block,
    'brand_age_group' AS grain,
    brand_age_group AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'transactions' AS rank_label,
    CAST(transactions AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(brands AS BIGINT) AS brands,
    CAST(review_count AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(weighted_avg_rating, 4) AS avg_rating,
    CAST(NULL AS DOUBLE) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Test whether older brand groups actually carry more demand.' AS notes
FROM age_group_summary
UNION ALL
SELECT
    'brand_age_rating_comparison' AS evidence_block,
    'brand_age_group' AS grain,
    brand_age_group AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'weighted_avg_rating' AS rank_label,
    CAST(weighted_avg_rating AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(brands AS BIGINT) AS brands,
    CAST(review_count AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(weighted_avg_rating, 4) AS avg_rating,
    CAST(NULL AS DOUBLE) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Test whether older brand groups also have stronger review acceptance.' AS notes
FROM age_group_summary
UNION ALL
SELECT
    'purchase_review_time_alignment' AS evidence_block,
    'purchase_year' AS grain,
    brand_age_group AS item,
    CAST(transaction_year AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'transactions_by_year' AS rank_label,
    CAST(transactions AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(NULL AS BIGINT) AS customers,
    CAST(brands AS BIGINT) AS brands,
    CAST(NULL AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    CAST(NULL AS DOUBLE) AS avg_rating,
    CAST(NULL AS DOUBLE) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Track whether purchase timing differs by brand-age group.' AS notes
FROM purchase_year_summary
UNION ALL
SELECT
    'review_time_alignment' AS evidence_block,
    'review_year' AS grain,
    brand_age_group AS item,
    CAST(review_year AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'reviews_by_year' AS rank_label,
    CAST(reviews AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS transactions,
    CAST(NULL AS BIGINT) AS customers,
    CAST(NULL AS BIGINT) AS brands,
    CAST(reviews AS BIGINT) AS reviews,
    CAST(NULL AS DOUBLE) AS revenue,
    CAST(NULL AS DOUBLE) AS gross_margin_proxy,
    CAST(NULL AS DOUBLE) AS gross_margin_proxy_rate_pct,
    ROUND(avg_rating, 4) AS avg_rating,
    CAST(NULL AS DOUBLE) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Track whether review timing and rating evidence differ by brand-age group.' AS notes
FROM review_year_summary
UNION ALL
SELECT
    'brand_lifecycle_exception' AS evidence_block,
    'brand' AS grain,
    BrandName AS item,
    brand_age_group AS item_2,
    CAST(FirstBrewedYear AS VARCHAR) AS item_3,
    'transaction_rank' AS rank_label,
    CAST(transaction_rank AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(1 AS BIGINT) AS brands,
    CAST(review_count AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_rating, 4) AS avg_rating,
    CAST(NULL AS DOUBLE) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Identify brands that contradict broad age-group averages.' AS notes
FROM brand_metrics
UNION ALL
SELECT
    'brand_lifecycle_signal_alignment' AS evidence_block,
    'brand' AS grain,
    BrandName AS item,
    brand_age_group AS item_2,
    CAST(transaction_rank AS VARCHAR) || '/' || CAST(rating_rank AS VARCHAR) AS item_3,
    'transaction_rank_minus_rating_rank' AS rank_label,
    CAST(transaction_rank - rating_rank AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(1 AS BIGINT) AS brands,
    CAST(review_count AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_rating, 4) AS avg_rating,
    CAST(NULL AS DOUBLE) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Compare whether heritage, demand, rating, and margin-proxy signals align by brand.' AS notes
FROM brand_metrics
ORDER BY evidence_block, rank_value DESC NULLS LAST, item;
