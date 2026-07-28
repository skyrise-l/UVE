-- task_032_customer_lifecycle_loyalty_evidence.sql
-- Draft task-level Evidence SQL for beer_factory customer lifecycle and loyalty.

WITH
sales_fact AS (
    SELECT
        t.TransactionID,
        t.CustomerID,
        c.FirstPurchaseDate,
        CASE
            WHEN CAST(substr(CAST(c.FirstPurchaseDate AS VARCHAR), 6, 2) AS INTEGER) <= 6 THEN 'first_half_first_purchase'
            ELSE 'second_half_first_purchase'
        END AS tenure_bucket,
        t.TransactionDate,
        t.PurchasePrice,
        rb.BrandID,
        b.BrandName,
        t.PurchasePrice - b.WholesaleCost AS gross_margin_proxy
    FROM "transaction" t
    JOIN customers c ON t.CustomerID = c.CustomerID
    JOIN rootbeer rb ON t.RootBeerID = rb.RootBeerID
    JOIN rootbeerbrand b ON rb.BrandID = b.BrandID
),
review_by_customer AS (
    SELECT
        CustomerID,
        COUNT(*) AS review_count,
        COUNT(DISTINCT BrandID) AS reviewed_brands,
        AVG(StarRating) AS avg_rating_given
    FROM rootbeerreview
    GROUP BY CustomerID
),
customer_metrics AS (
    SELECT
        sf.CustomerID,
        MAX(sf.tenure_bucket) AS tenure_bucket,
        MIN(sf.FirstPurchaseDate) AS first_purchase_date,
        COUNT(*) AS transactions,
        COUNT(DISTINCT sf.BrandID) AS purchased_brands,
        SUM(sf.PurchasePrice) AS revenue,
        SUM(sf.gross_margin_proxy) AS gross_margin_proxy,
        SUM(sf.gross_margin_proxy) / NULLIF(SUM(sf.PurchasePrice), 0) AS gross_margin_proxy_rate,
        COALESCE(MAX(rc.review_count), 0) AS review_count,
        COALESCE(MAX(rc.reviewed_brands), 0) AS reviewed_brands,
        MAX(rc.avg_rating_given) AS avg_rating_given
    FROM sales_fact sf
    LEFT JOIN review_by_customer rc ON sf.CustomerID = rc.CustomerID
    GROUP BY sf.CustomerID
),
totals AS (
    SELECT
        COUNT(*) AS total_customers,
        SUM(transactions) AS total_transactions,
        SUM(revenue) AS total_revenue,
        SUM(review_count) AS total_reviews
    FROM customer_metrics
),
ranked AS (
    SELECT
        cm.*,
        100.0 * transactions / NULLIF(t.total_transactions, 0) AS transaction_share_pct,
        100.0 * revenue / NULLIF(t.total_revenue, 0) AS revenue_share_pct,
        100.0 * review_count / NULLIF(t.total_reviews, 0) AS review_share_pct,
        ROW_NUMBER() OVER (ORDER BY transactions DESC, CustomerID) AS transaction_rank,
        ROW_NUMBER() OVER (ORDER BY review_count DESC, transactions DESC, CustomerID) AS review_rank
    FROM customer_metrics cm
    CROSS JOIN totals t
),
tenure_summary AS (
    SELECT
        tenure_bucket,
        COUNT(*) AS customers,
        SUM(transactions) AS transactions,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(revenue), 0) AS gross_margin_proxy_rate,
        SUM(review_count) AS review_count,
        AVG(avg_rating_given) AS avg_rating_given
    FROM customer_metrics
    GROUP BY tenure_bucket
),
top_customer_summary AS (
    SELECT
        SUM(CASE WHEN transaction_rank <= 10 THEN transactions ELSE 0 END) AS top10_transactions,
        SUM(CASE WHEN transaction_rank <= 10 THEN revenue ELSE 0 END) AS top10_revenue,
        SUM(transactions) AS all_transactions,
        SUM(revenue) AS all_revenue
    FROM ranked
),
customer_brand_preference AS (
    SELECT
        sf.CustomerID,
        sf.BrandName,
        COUNT(*) AS brand_transactions,
        ROW_NUMBER() OVER (PARTITION BY sf.CustomerID ORDER BY COUNT(*) DESC, sf.BrandName) AS brand_rank
    FROM sales_fact sf
    GROUP BY sf.CustomerID, sf.BrandName
)
SELECT
    'customer_value_baseline' AS evidence_block,
    'customer' AS grain,
    CAST(CustomerID AS VARCHAR) AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'transaction_rank' AS rank_label,
    CAST(transaction_rank AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(1 AS BIGINT) AS customers,
    CAST(purchased_brands AS BIGINT) AS brands,
    CAST(review_count AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_rating_given, 4) AS avg_rating,
    ROUND(transaction_share_pct, 4) AS transaction_share_pct,
    ROUND(review_share_pct, 4) AS review_share_pct,
    'Rank customer value before interpreting loyalty.' AS notes
FROM ranked
UNION ALL
SELECT
    'tenure_cohort_value' AS evidence_block,
    'tenure_bucket' AS grain,
    tenure_bucket AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'cohort_revenue' AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(NULL AS BIGINT) AS brands,
    CAST(review_count AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_rating_given, 4) AS avg_rating,
    CAST(NULL AS DOUBLE) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Compare earlier and later first-purchase cohorts.' AS notes
FROM tenure_summary
UNION ALL
SELECT
    'repeat_purchase_concentration' AS evidence_block,
    'portfolio' AS grain,
    'top_10_customers_by_transactions' AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'top10_customer_transaction_share' AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    CAST(top10_transactions AS BIGINT) AS transactions,
    CAST(10 AS BIGINT) AS customers,
    CAST(NULL AS BIGINT) AS brands,
    CAST(NULL AS BIGINT) AS reviews,
    ROUND(top10_revenue, 4) AS revenue,
    CAST(NULL AS DOUBLE) AS gross_margin_proxy,
    CAST(NULL AS DOUBLE) AS gross_margin_proxy_rate_pct,
    CAST(NULL AS DOUBLE) AS avg_rating,
    ROUND(100.0 * top10_transactions / NULLIF(all_transactions, 0), 4) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Check whether repeat value is concentrated in a customer head.' AS notes
FROM top_customer_summary
UNION ALL
SELECT
    'purchase_review_participation' AS evidence_block,
    'customer' AS grain,
    CAST(CustomerID AS VARCHAR) AS item,
    CAST(transaction_rank AS VARCHAR) AS item_2,
    CAST(review_rank AS VARCHAR) AS item_3,
    'purchase_review_rank_gap' AS rank_label,
    CAST(transaction_rank - review_rank AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(1 AS BIGINT) AS customers,
    CAST(purchased_brands AS BIGINT) AS brands,
    CAST(review_count AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_rating_given, 4) AS avg_rating,
    ROUND(transaction_share_pct, 4) AS transaction_share_pct,
    ROUND(review_share_pct, 4) AS review_share_pct,
    'Frequent buyers and frequent reviewers may be different customers.' AS notes
FROM ranked
UNION ALL
SELECT
    'customer_brand_preference' AS evidence_block,
    'customer_brand' AS grain,
    CAST(r.CustomerID AS VARCHAR) AS item,
    cb.BrandName AS item_2,
    CAST(cb.brand_transactions AS VARCHAR) AS item_3,
    'customer_transaction_rank' AS rank_label,
    CAST(r.transaction_rank AS DOUBLE) AS rank_value,
    CAST(r.transactions AS BIGINT) AS transactions,
    CAST(1 AS BIGINT) AS customers,
    CAST(r.purchased_brands AS BIGINT) AS brands,
    CAST(r.review_count AS BIGINT) AS reviews,
    ROUND(r.revenue, 4) AS revenue,
    ROUND(r.gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * r.gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(r.avg_rating_given, 4) AS avg_rating,
    ROUND(r.transaction_share_pct, 4) AS transaction_share_pct,
    ROUND(r.review_share_pct, 4) AS review_share_pct,
    'Identify top customers and their leading brand preference.' AS notes
FROM ranked r
JOIN customer_brand_preference cb
  ON r.CustomerID = cb.CustomerID
 AND cb.brand_rank = 1
UNION ALL
SELECT
    'customer_signal_alignment' AS evidence_block,
    'customer' AS grain,
    CAST(CustomerID AS VARCHAR) AS item,
    CAST(transaction_rank AS VARCHAR) AS item_2,
    CAST(review_rank AS VARCHAR) AS item_3,
    'transaction_rank_minus_review_rank' AS rank_label,
    CAST(transaction_rank - review_rank AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(1 AS BIGINT) AS customers,
    CAST(purchased_brands AS BIGINT) AS brands,
    CAST(review_count AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_rating_given, 4) AS avg_rating,
    ROUND(transaction_share_pct, 4) AS transaction_share_pct,
    ROUND(review_share_pct, 4) AS review_share_pct,
    'Audit whether value, review participation, and breadth point to the same customers.' AS notes
FROM ranked
ORDER BY evidence_block, rank_value ASC NULLS LAST, item;
