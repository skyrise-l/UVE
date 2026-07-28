-- task_037_email_subscription_engagement_evidence.sql
-- Draft task-level Evidence SQL for beer_factory.
-- Light/profile stage only: use the output to screen evidence paths, then recalibrate on full results.

WITH
sales_fact AS (
    SELECT
        t.TransactionID,
        t.CustomerID,
        c.SubscribedToEmailList,
        c.Gender,
        c.City AS customer_city,
        c.FirstPurchaseDate,
        CASE
            WHEN c.FirstPurchaseDate < '2013-07-01' THEN 'early_first_purchase'
            ELSE 'later_first_purchase'
        END AS tenure_bucket,
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
    JOIN rootbeer rb ON t.RootBeerID = rb.RootBeerID
    JOIN rootbeerbrand b ON rb.BrandID = b.BrandID
),
review_by_customer AS (
    SELECT
        CustomerID,
        COUNT(*) AS reviews,
        COUNT(DISTINCT BrandID) AS reviewed_brands,
        AVG(StarRating) AS avg_rating
    FROM rootbeerreview
    GROUP BY CustomerID
),
customer_metrics AS (
    SELECT
        sf.CustomerID,
        MAX(sf.SubscribedToEmailList) AS SubscribedToEmailList,
        MAX(sf.Gender) AS Gender,
        MAX(sf.customer_city) AS customer_city,
        MAX(sf.tenure_bucket) AS tenure_bucket,
        COUNT(*) AS transactions,
        COUNT(DISTINCT sf.BrandID) AS brands,
        COUNT(DISTINCT sf.ContainerType) AS containers,
        SUM(sf.PurchasePrice) AS revenue,
        SUM(sf.gross_margin_proxy) AS gross_margin_proxy,
        SUM(sf.gross_margin_proxy) / NULLIF(SUM(sf.PurchasePrice), 0) AS gross_margin_proxy_rate,
        COALESCE(MAX(rc.reviews), 0) AS reviews,
        COALESCE(MAX(rc.reviewed_brands), 0) AS reviewed_brands,
        MAX(rc.avg_rating) AS avg_rating
    FROM sales_fact sf
    LEFT JOIN review_by_customer rc ON sf.CustomerID = rc.CustomerID
    GROUP BY sf.CustomerID
),
subscription_metrics AS (
    SELECT
        SubscribedToEmailList,
        COUNT(*) AS customers,
        SUM(transactions) AS transactions,
        SUM(brands) AS customer_brand_instances,
        SUM(reviews) AS reviews,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(revenue), 0) AS gross_margin_proxy_rate,
        AVG(avg_rating) AS avg_rating,
        AVG(CAST(transactions AS DOUBLE)) AS avg_transactions_per_customer,
        AVG(CAST(reviews AS DOUBLE)) AS avg_reviews_per_customer
    FROM customer_metrics
    GROUP BY SubscribedToEmailList
),
subscription_ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY transactions DESC, SubscribedToEmailList) AS transaction_rank,
        ROW_NUMBER() OVER (ORDER BY reviews DESC, SubscribedToEmailList) AS review_rank,
        ROW_NUMBER() OVER (ORDER BY avg_rating DESC, SubscribedToEmailList) AS rating_rank,
        ROW_NUMBER() OVER (ORDER BY gross_margin_proxy_rate DESC, SubscribedToEmailList) AS margin_rank
    FROM subscription_metrics
),
subscription_gender AS (
    SELECT
        SubscribedToEmailList,
        Gender,
        COUNT(*) AS customers,
        SUM(transactions) AS transactions,
        SUM(reviews) AS reviews,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(revenue), 0) AS gross_margin_proxy_rate,
        AVG(avg_rating) AS avg_rating
    FROM customer_metrics
    GROUP BY SubscribedToEmailList, Gender
),
subscription_tenure AS (
    SELECT
        SubscribedToEmailList,
        tenure_bucket,
        COUNT(*) AS customers,
        SUM(transactions) AS transactions,
        SUM(reviews) AS reviews,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(revenue), 0) AS gross_margin_proxy_rate,
        AVG(avg_rating) AS avg_rating
    FROM customer_metrics
    GROUP BY SubscribedToEmailList, tenure_bucket
),
subscription_brand AS (
    SELECT
        SubscribedToEmailList,
        BrandName,
        COUNT(*) AS transactions,
        COUNT(DISTINCT CustomerID) AS customers,
        SUM(PurchasePrice) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(PurchasePrice), 0) AS gross_margin_proxy_rate,
        ROW_NUMBER() OVER (PARTITION BY SubscribedToEmailList ORDER BY COUNT(*) DESC, BrandName) AS brand_rank_in_subscription
    FROM sales_fact
    GROUP BY SubscribedToEmailList, BrandName
),
subscription_container AS (
    SELECT
        SubscribedToEmailList,
        ContainerType,
        COUNT(*) AS transactions,
        COUNT(DISTINCT CustomerID) AS customers,
        COUNT(DISTINCT BrandID) AS brands,
        SUM(PurchasePrice) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(PurchasePrice), 0) AS gross_margin_proxy_rate,
        AVG(PurchasePrice) AS avg_purchase_price
    FROM sales_fact
    GROUP BY SubscribedToEmailList, ContainerType
),
subscription_signal_gap AS (
    SELECT
        *,
        ABS(transaction_rank - review_rank) AS purchase_review_rank_gap,
        ABS(transaction_rank - rating_rank) AS purchase_rating_rank_gap,
        ABS(transaction_rank - margin_rank) AS purchase_margin_rank_gap
    FROM subscription_ranked
)
SELECT
    'subscription_value_baseline' AS evidence_block,
    'subscription_group' AS grain,
    SubscribedToEmailList AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'transaction_rank' AS rank_label,
    CAST(transaction_rank AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(NULL AS BIGINT) AS brands,
    CAST(reviews AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_rating, 4) AS avg_rating,
    ROUND(avg_transactions_per_customer, 4) AS transaction_share_pct,
    ROUND(avg_reviews_per_customer, 4) AS review_share_pct,
    'Compare subscriber and non-subscriber value before treating email reach as engagement.' AS notes
FROM subscription_ranked
UNION ALL
SELECT
    'subscription_review_engagement' AS evidence_block,
    'subscription_group' AS grain,
    SubscribedToEmailList AS item,
    CAST(transaction_rank AS VARCHAR) AS item_2,
    CAST(review_rank AS VARCHAR) AS item_3,
    'purchase_review_rank_gap' AS rank_label,
    CAST(purchase_review_rank_gap AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(NULL AS BIGINT) AS brands,
    CAST(reviews AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_rating, 4) AS avg_rating,
    ROUND(avg_transactions_per_customer, 4) AS transaction_share_pct,
    ROUND(avg_reviews_per_customer, 4) AS review_share_pct,
    'Check whether subscription status aligns with review participation.' AS notes
FROM subscription_signal_gap
UNION ALL
SELECT
    'subscription_gender_mix' AS evidence_block,
    'subscription_gender' AS grain,
    SubscribedToEmailList AS item,
    Gender AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'customers_in_group' AS rank_label,
    CAST(customers AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(NULL AS BIGINT) AS brands,
    CAST(reviews AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_rating, 4) AS avg_rating,
    CAST(NULL AS DOUBLE) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Audit whether subscription effects are actually gender-composition effects.' AS notes
FROM subscription_gender
UNION ALL
SELECT
    'subscription_tenure_mix' AS evidence_block,
    'subscription_tenure' AS grain,
    SubscribedToEmailList AS item,
    tenure_bucket AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'customers_in_group' AS rank_label,
    CAST(customers AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(NULL AS BIGINT) AS brands,
    CAST(reviews AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_rating, 4) AS avg_rating,
    CAST(NULL AS DOUBLE) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Check whether subscription status is confounded with customer tenure.' AS notes
FROM subscription_tenure
UNION ALL
SELECT
    'subscription_brand_preference' AS evidence_block,
    'subscription_brand' AS grain,
    SubscribedToEmailList AS item,
    BrandName AS item_2,
    CAST(brand_rank_in_subscription AS VARCHAR) AS item_3,
    'brand_rank_in_subscription' AS rank_label,
    CAST(brand_rank_in_subscription AS DOUBLE) AS rank_value,
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
    'Identify whether subscriber and non-subscriber demand is led by different brands.' AS notes
FROM subscription_brand
WHERE brand_rank_in_subscription <= 5
UNION ALL
SELECT
    'subscription_container_price_mix' AS evidence_block,
    'subscription_container' AS grain,
    SubscribedToEmailList AS item,
    ContainerType AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'avg_purchase_price' AS rank_label,
    CAST(avg_purchase_price AS DOUBLE) AS rank_value,
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
    'Separate subscription behavior from container and price mix.' AS notes
FROM subscription_container
UNION ALL
SELECT
    'subscription_quality_mismatch' AS evidence_block,
    'subscription_group' AS grain,
    SubscribedToEmailList AS item,
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
    CAST(NULL AS BIGINT) AS brands,
    CAST(reviews AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_rating, 4) AS avg_rating,
    ROUND(avg_transactions_per_customer, 4) AS transaction_share_pct,
    ROUND(avg_reviews_per_customer, 4) AS review_share_pct,
    'Find whether subscriber purchase scale diverges from rating or margin proxy quality.' AS notes
FROM subscription_signal_gap;
