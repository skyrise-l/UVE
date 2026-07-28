-- task_038_payment_method_basket_quality_evidence.sql
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
        t.CreditCardType,
        t.TransactionDate,
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
card_metrics AS (
    SELECT
        CreditCardType,
        COUNT(*) AS transactions,
        COUNT(DISTINCT CustomerID) AS customers,
        COUNT(DISTINCT BrandID) AS brands,
        COUNT(DISTINCT LocationName) AS locations,
        SUM(PurchasePrice) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(PurchasePrice), 0) AS gross_margin_proxy_rate,
        AVG(brand_avg_rating) AS avg_rating,
        COUNT(*) * 1.0 / NULLIF(COUNT(DISTINCT CustomerID), 0) AS transactions_per_customer
    FROM sales_fact
    GROUP BY CreditCardType
),
totals AS (
    SELECT
        SUM(transactions) AS total_transactions,
        SUM(revenue) AS total_revenue
    FROM card_metrics
),
ranked_card AS (
    SELECT
        cm.*,
        100.0 * cm.transactions / NULLIF(t.total_transactions, 0) AS transaction_share_pct,
        100.0 * cm.revenue / NULLIF(t.total_revenue, 0) AS revenue_share_pct,
        ROW_NUMBER() OVER (ORDER BY cm.transactions DESC, cm.CreditCardType) AS transaction_rank,
        ROW_NUMBER() OVER (ORDER BY cm.transactions_per_customer DESC, cm.CreditCardType) AS repeat_intensity_rank,
        ROW_NUMBER() OVER (ORDER BY cm.gross_margin_proxy_rate DESC, cm.CreditCardType) AS margin_rank,
        ROW_NUMBER() OVER (ORDER BY cm.avg_rating DESC, cm.CreditCardType) AS rating_rank
    FROM card_metrics cm
    CROSS JOIN totals t
),
card_location AS (
    SELECT
        CreditCardType,
        LocationName,
        COUNT(*) AS transactions,
        COUNT(DISTINCT CustomerID) AS customers,
        COUNT(DISTINCT BrandID) AS brands,
        SUM(PurchasePrice) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(PurchasePrice), 0) AS gross_margin_proxy_rate,
        ROW_NUMBER() OVER (PARTITION BY CreditCardType ORDER BY COUNT(*) DESC, LocationName) AS location_rank_in_card
    FROM sales_fact
    GROUP BY CreditCardType, LocationName
),
card_container AS (
    SELECT
        CreditCardType,
        ContainerType,
        COUNT(*) AS transactions,
        COUNT(DISTINCT CustomerID) AS customers,
        COUNT(DISTINCT BrandID) AS brands,
        SUM(PurchasePrice) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(PurchasePrice), 0) AS gross_margin_proxy_rate,
        AVG(PurchasePrice) AS avg_purchase_price
    FROM sales_fact
    GROUP BY CreditCardType, ContainerType
),
card_brand AS (
    SELECT
        CreditCardType,
        BrandName,
        COUNT(*) AS transactions,
        COUNT(DISTINCT CustomerID) AS customers,
        SUM(PurchasePrice) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(PurchasePrice), 0) AS gross_margin_proxy_rate,
        AVG(brand_avg_rating) AS avg_rating,
        ROW_NUMBER() OVER (PARTITION BY CreditCardType ORDER BY COUNT(*) DESC, BrandName) AS brand_rank_in_card
    FROM sales_fact
    GROUP BY CreditCardType, BrandName
),
card_price_band AS (
    SELECT
        CreditCardType,
        CASE
            WHEN PurchasePrice <= 1.0 THEN 'low_price'
            ELSE 'premium_price'
        END AS price_band,
        COUNT(*) AS transactions,
        COUNT(DISTINCT CustomerID) AS customers,
        COUNT(DISTINCT BrandID) AS brands,
        SUM(PurchasePrice) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(PurchasePrice), 0) AS gross_margin_proxy_rate
    FROM sales_fact
    GROUP BY CreditCardType, price_band
),
card_signal_gap AS (
    SELECT
        *,
        ABS(transaction_rank - repeat_intensity_rank) AS volume_repeat_rank_gap,
        ABS(transaction_rank - margin_rank) AS volume_margin_rank_gap,
        ABS(transaction_rank - rating_rank) AS volume_rating_rank_gap
    FROM ranked_card
)
SELECT
    'payment_method_baseline' AS evidence_block,
    'credit_card_type' AS grain,
    CreditCardType AS item,
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
    ROUND(transaction_share_pct, 4) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Establish payment-method transaction scale before interpreting behavior.' AS notes
FROM ranked_card
UNION ALL
SELECT
    'payment_repeat_intensity' AS evidence_block,
    'credit_card_type' AS grain,
    CreditCardType AS item,
    CAST(transaction_rank AS VARCHAR) AS item_2,
    CAST(repeat_intensity_rank AS VARCHAR) AS item_3,
    'transactions_per_customer_rank' AS rank_label,
    CAST(repeat_intensity_rank AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(brands AS BIGINT) AS brands,
    CAST(NULL AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_rating, 4) AS avg_rating,
    ROUND(transactions_per_customer, 4) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Check whether high-volume payment methods also represent repeat-heavy customers.' AS notes
FROM card_signal_gap
UNION ALL
SELECT
    'payment_location_mix' AS evidence_block,
    'card_location' AS grain,
    CreditCardType AS item,
    LocationName AS item_2,
    CAST(location_rank_in_card AS VARCHAR) AS item_3,
    'location_rank_in_card' AS rank_label,
    CAST(location_rank_in_card AS DOUBLE) AS rank_value,
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
    'Test whether payment-method differences are partly location mix.' AS notes
FROM card_location
WHERE location_rank_in_card <= 2
UNION ALL
SELECT
    'payment_container_mix' AS evidence_block,
    'card_container' AS grain,
    CreditCardType AS item,
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
    'Separate payment behavior from can/bottle and price mix.' AS notes
FROM card_container
UNION ALL
SELECT
    'payment_brand_preference' AS evidence_block,
    'card_brand' AS grain,
    CreditCardType AS item,
    BrandName AS item_2,
    CAST(brand_rank_in_card AS VARCHAR) AS item_3,
    'brand_rank_in_card' AS rank_label,
    CAST(brand_rank_in_card AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(1 AS BIGINT) AS brands,
    CAST(NULL AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_rating, 4) AS avg_rating,
    CAST(NULL AS DOUBLE) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Identify leading brands within each payment method.' AS notes
FROM card_brand
WHERE brand_rank_in_card <= 5
UNION ALL
SELECT
    'payment_price_band_mix' AS evidence_block,
    'card_price_band' AS grain,
    CreditCardType AS item,
    price_band AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'transactions' AS rank_label,
    CAST(transactions AS DOUBLE) AS rank_value,
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
    'Check whether payment method differences are driven by price bands.' AS notes
FROM card_price_band
UNION ALL
SELECT
    'payment_quality_mismatch' AS evidence_block,
    'credit_card_type' AS grain,
    CreditCardType AS item,
    CAST(transaction_rank AS VARCHAR) AS item_2,
    CAST(rating_rank AS VARCHAR) || '/' || CAST(margin_rank AS VARCHAR) AS item_3,
    'max_volume_quality_rank_gap' AS rank_label,
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
    ROUND(transaction_share_pct, 4) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Find whether payment-method volume diverges from margin proxy or rating quality.' AS notes
FROM card_signal_gap;
