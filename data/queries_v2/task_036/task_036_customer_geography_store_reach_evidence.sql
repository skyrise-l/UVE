-- task_036_customer_geography_store_reach_evidence.sql
-- Draft task-level Evidence SQL for beer_factory.
-- Light/profile stage only: use the output to screen evidence paths, then recalibrate on full results.

WITH
sales_fact AS (
    SELECT
        t.TransactionID,
        t.CustomerID,
        c.City AS customer_city,
        c.ZipCode AS customer_zip,
        l.LocationName,
        t.TransactionDate,
        t.PurchasePrice,
        rb.RootBeerID,
        rb.ContainerType,
        b.BrandID,
        b.BrandName,
        b.WholesaleCost,
        t.PurchasePrice - b.WholesaleCost AS gross_margin_proxy
    FROM "transaction" t
    JOIN customers c ON t.CustomerID = c.CustomerID
    JOIN location l ON t.LocationID = l.LocationID
    JOIN rootbeer rb ON t.RootBeerID = rb.RootBeerID
    JOIN rootbeerbrand b ON rb.BrandID = b.BrandID
),
review_by_city AS (
    SELECT
        c.City AS customer_city,
        COUNT(*) AS reviews,
        COUNT(DISTINCT r.CustomerID) AS review_customers,
        COUNT(DISTINCT r.BrandID) AS reviewed_brands,
        AVG(r.StarRating) AS avg_rating
    FROM rootbeerreview r
    JOIN customers c ON r.CustomerID = c.CustomerID
    GROUP BY c.City
),
city_sales AS (
    SELECT
        customer_city,
        COUNT(*) AS transactions,
        COUNT(DISTINCT CustomerID) AS customers,
        COUNT(DISTINCT customer_zip) AS zips,
        COUNT(DISTINCT BrandID) AS brands,
        COUNT(DISTINCT LocationName) AS locations,
        SUM(PurchasePrice) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(PurchasePrice), 0) AS gross_margin_proxy_rate
    FROM sales_fact
    GROUP BY customer_city
),
city_metrics AS (
    SELECT
        cs.*,
        COALESCE(rc.reviews, 0) AS reviews,
        COALESCE(rc.review_customers, 0) AS review_customers,
        COALESCE(rc.reviewed_brands, 0) AS reviewed_brands,
        rc.avg_rating
    FROM city_sales cs
    LEFT JOIN review_by_city rc ON cs.customer_city = rc.customer_city
),
totals AS (
    SELECT
        SUM(transactions) AS total_transactions,
        SUM(revenue) AS total_revenue,
        SUM(reviews) AS total_reviews
    FROM city_metrics
),
ranked_city AS (
    SELECT
        cm.*,
        100.0 * cm.transactions / NULLIF(t.total_transactions, 0) AS transaction_share_pct,
        100.0 * cm.revenue / NULLIF(t.total_revenue, 0) AS revenue_share_pct,
        100.0 * cm.reviews / NULLIF(t.total_reviews, 0) AS review_share_pct,
        ROW_NUMBER() OVER (ORDER BY cm.transactions DESC, cm.customer_city) AS transaction_rank,
        ROW_NUMBER() OVER (ORDER BY cm.reviews DESC, cm.customer_city) AS review_rank,
        ROW_NUMBER() OVER (ORDER BY cm.avg_rating DESC, cm.reviews DESC, cm.customer_city) AS rating_rank,
        ROW_NUMBER() OVER (ORDER BY cm.gross_margin_proxy_rate DESC, cm.revenue DESC, cm.customer_city) AS margin_rank
    FROM city_metrics cm
    CROSS JOIN totals t
),
top_city_concentration AS (
    SELECT
        SUM(CASE WHEN transaction_rank <= 5 THEN transactions ELSE 0 END) AS top5_transactions,
        SUM(transactions) AS all_transactions,
        COUNT(*) AS city_count
    FROM ranked_city
),
city_location AS (
    SELECT
        customer_city,
        LocationName,
        COUNT(*) AS transactions,
        COUNT(DISTINCT CustomerID) AS customers,
        COUNT(DISTINCT BrandID) AS brands,
        SUM(PurchasePrice) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(PurchasePrice), 0) AS gross_margin_proxy_rate,
        ROW_NUMBER() OVER (PARTITION BY customer_city ORDER BY COUNT(*) DESC, LocationName) AS location_rank_in_city
    FROM sales_fact
    GROUP BY customer_city, LocationName
),
city_brand AS (
    SELECT
        customer_city,
        BrandName,
        COUNT(*) AS transactions,
        COUNT(DISTINCT CustomerID) AS customers,
        SUM(PurchasePrice) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(PurchasePrice), 0) AS gross_margin_proxy_rate,
        ROW_NUMBER() OVER (PARTITION BY customer_city ORDER BY COUNT(*) DESC, BrandName) AS brand_rank_in_city
    FROM sales_fact
    GROUP BY customer_city, BrandName
),
city_signal_gap AS (
    SELECT
        *,
        ABS(transaction_rank - review_rank) AS purchase_review_rank_gap,
        ABS(transaction_rank - rating_rank) AS purchase_rating_rank_gap,
        ABS(transaction_rank - margin_rank) AS purchase_margin_rank_gap
    FROM ranked_city
)
SELECT
    'city_market_baseline' AS evidence_block,
    'customer_city' AS grain,
    customer_city AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'transaction_rank' AS rank_label,
    CAST(transaction_rank AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(brands AS BIGINT) AS brands,
    CAST(reviews AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_rating, 4) AS avg_rating,
    ROUND(transaction_share_pct, 4) AS transaction_share_pct,
    ROUND(review_share_pct, 4) AS review_share_pct,
    'Establish customer geography scale before interpreting local reach.' AS notes
FROM ranked_city
UNION ALL
SELECT
    'city_transaction_concentration' AS evidence_block,
    'portfolio' AS grain,
    'top_5_customer_cities_by_transactions' AS item,
    CAST(city_count AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'top5_city_transaction_share' AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    CAST(top5_transactions AS BIGINT) AS transactions,
    CAST(NULL AS BIGINT) AS customers,
    CAST(city_count AS BIGINT) AS brands,
    CAST(NULL AS BIGINT) AS reviews,
    CAST(NULL AS DOUBLE) AS revenue,
    CAST(NULL AS DOUBLE) AS gross_margin_proxy,
    CAST(NULL AS DOUBLE) AS gross_margin_proxy_rate_pct,
    CAST(NULL AS DOUBLE) AS avg_rating,
    ROUND(100.0 * top5_transactions / NULLIF(all_transactions, 0), 4) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Check whether customer geography is broad or concentrated in a few cities.' AS notes
FROM top_city_concentration
UNION ALL
SELECT
    'city_location_affinity' AS evidence_block,
    'customer_city_location' AS grain,
    customer_city AS item,
    LocationName AS item_2,
    CAST(location_rank_in_city AS VARCHAR) AS item_3,
    'location_rank_in_city' AS rank_label,
    CAST(location_rank_in_city AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(brands AS BIGINT) AS brands,
    CAST(NULL AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    CAST(NULL AS DOUBLE) AS avg_rating,
    CAST(NULL AS DOUBLE) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Test whether customer cities lean toward different selling locations.' AS notes
FROM city_location
WHERE location_rank_in_city <= 2
UNION ALL
SELECT
    'city_brand_preference' AS evidence_block,
    'customer_city_brand' AS grain,
    customer_city AS item,
    BrandName AS item_2,
    CAST(brand_rank_in_city AS VARCHAR) AS item_3,
    'brand_rank_in_city' AS rank_label,
    CAST(brand_rank_in_city AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(1 AS BIGINT) AS brands,
    CAST(NULL AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    CAST(NULL AS DOUBLE) AS avg_rating,
    CAST(NULL AS DOUBLE) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Identify whether city-level demand is driven by different leading brands.' AS notes
FROM city_brand
WHERE brand_rank_in_city <= 3
UNION ALL
SELECT
    'city_review_participation' AS evidence_block,
    'customer_city' AS grain,
    customer_city AS item,
    CAST(transaction_rank AS VARCHAR) AS item_2,
    CAST(review_rank AS VARCHAR) AS item_3,
    'purchase_review_rank_gap' AS rank_label,
    CAST(purchase_review_rank_gap AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(brands AS BIGINT) AS brands,
    CAST(reviews AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_rating, 4) AS avg_rating,
    ROUND(transaction_share_pct, 4) AS transaction_share_pct,
    ROUND(review_share_pct, 4) AS review_share_pct,
    'Compare purchase scale with review participation by customer city.' AS notes
FROM city_signal_gap
UNION ALL
SELECT
    'city_quality_mismatch' AS evidence_block,
    'customer_city' AS grain,
    customer_city AS item,
    CAST(transaction_rank AS VARCHAR) AS item_2,
    CAST(rating_rank AS VARCHAR) || '/' || CAST(margin_rank AS VARCHAR) AS item_3,
    'max_purchase_quality_rank_gap' AS rank_label,
    CAST(
        CASE
            WHEN purchase_rating_rank_gap >= purchase_margin_rank_gap THEN purchase_rating_rank_gap
            ELSE purchase_margin_rank_gap
        END AS DOUBLE
    ) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(brands AS BIGINT) AS brands,
    CAST(reviews AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_rating, 4) AS avg_rating,
    ROUND(transaction_share_pct, 4) AS transaction_share_pct,
    ROUND(review_share_pct, 4) AS review_share_pct,
    'Find customer cities where purchase scale, ratings, and margin proxy diverge.' AS notes
FROM city_signal_gap;
