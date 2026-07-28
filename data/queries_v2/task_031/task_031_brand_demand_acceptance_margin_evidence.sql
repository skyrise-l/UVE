-- task_031_brand_demand_acceptance_margin_evidence.sql
-- Draft task-level Evidence SQL for beer_factory.
-- Light/profile stage only: use the output to screen evidence paths, then recalibrate on full results.

WITH
sales_fact AS (
    SELECT
        t.TransactionID,
        t.CustomerID,
        t.TransactionDate,
        t.PurchasePrice,
        rb.RootBeerID,
        rb.BrandID,
        b.BrandName,
        b.WholesaleCost,
        b.CurrentRetailPrice,
        t.PurchasePrice - b.WholesaleCost AS gross_margin_proxy
    FROM "transaction" t
    JOIN rootbeer rb ON t.RootBeerID = rb.RootBeerID
    JOIN rootbeerbrand b ON rb.BrandID = b.BrandID
),
review_by_brand AS (
    SELECT
        BrandID,
        COUNT(*) AS review_count,
        COUNT(DISTINCT CustomerID) AS review_customers,
        AVG(StarRating) AS avg_rating
    FROM rootbeerreview
    GROUP BY BrandID
),
brand_metrics AS (
    SELECT
        sf.BrandID,
        sf.BrandName,
        COUNT(*) AS transactions,
        COUNT(DISTINCT sf.CustomerID) AS customers,
        SUM(sf.PurchasePrice) AS revenue,
        SUM(sf.gross_margin_proxy) AS gross_margin_proxy,
        SUM(sf.gross_margin_proxy) / NULLIF(SUM(sf.PurchasePrice), 0) AS gross_margin_proxy_rate,
        COALESCE(MAX(rb.review_count), 0) AS review_count,
        COALESCE(MAX(rb.review_customers), 0) AS review_customers,
        MAX(rb.avg_rating) AS avg_rating
    FROM sales_fact sf
    LEFT JOIN review_by_brand rb ON sf.BrandID = rb.BrandID
    GROUP BY sf.BrandID, sf.BrandName
),
totals AS (
    SELECT
        SUM(transactions) AS total_transactions,
        SUM(revenue) AS total_revenue,
        SUM(gross_margin_proxy) AS total_gross_margin_proxy,
        SUM(review_count) AS total_reviews
    FROM brand_metrics
),
ranked AS (
    SELECT
        bm.*,
        100.0 * bm.transactions / NULLIF(t.total_transactions, 0) AS transaction_share_pct,
        100.0 * bm.revenue / NULLIF(t.total_revenue, 0) AS revenue_share_pct,
        100.0 * bm.review_count / NULLIF(t.total_reviews, 0) AS review_share_pct,
        ROW_NUMBER() OVER (ORDER BY bm.transactions DESC, bm.BrandName) AS transaction_rank,
        ROW_NUMBER() OVER (ORDER BY bm.avg_rating DESC NULLS LAST, bm.review_count DESC, bm.BrandName) AS rating_rank,
        ROW_NUMBER() OVER (ORDER BY bm.gross_margin_proxy_rate DESC NULLS LAST, bm.revenue DESC, bm.BrandName) AS margin_rate_rank
    FROM brand_metrics bm
    CROSS JOIN totals t
),
top10 AS (
    SELECT
        SUM(CASE WHEN transaction_rank <= 10 THEN transactions ELSE 0 END) AS top10_transactions,
        SUM(transactions) AS all_transactions
    FROM ranked
)
SELECT
    'brand_demand_baseline' AS evidence_block,
    'brand' AS grain,
    BrandName AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
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
    ROUND(transaction_share_pct, 4) AS transaction_share_pct,
    ROUND(review_share_pct, 4) AS review_share_pct,
    'Establish brand demand scale before judging brand quality.' AS notes
FROM ranked
UNION ALL
SELECT
    'brand_demand_concentration' AS evidence_block,
    'portfolio' AS grain,
    'top_10_brands_by_transactions' AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'top10_transaction_share' AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    CAST(top10_transactions AS BIGINT) AS transactions,
    CAST(NULL AS BIGINT) AS customers,
    CAST(10 AS BIGINT) AS brands,
    CAST(NULL AS BIGINT) AS reviews,
    CAST(NULL AS DOUBLE) AS revenue,
    CAST(NULL AS DOUBLE) AS gross_margin_proxy,
    CAST(NULL AS DOUBLE) AS gross_margin_proxy_rate_pct,
    CAST(NULL AS DOUBLE) AS avg_rating,
    ROUND(100.0 * top10_transactions / NULLIF(all_transactions, 0), 4) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Check whether demand is broad or concentrated in the head.' AS notes
FROM top10
UNION ALL
SELECT
    'brand_sales_rating_alignment' AS evidence_block,
    'brand' AS grain,
    BrandName AS item,
    CAST(transaction_rank AS VARCHAR) AS item_2,
    CAST(rating_rank AS VARCHAR) AS item_3,
    'sales_rank_vs_rating_rank' AS rank_label,
    CAST(transaction_rank - rating_rank AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(1 AS BIGINT) AS brands,
    CAST(review_count AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_rating, 4) AS avg_rating,
    ROUND(transaction_share_pct, 4) AS transaction_share_pct,
    ROUND(review_share_pct, 4) AS review_share_pct,
    'Compare transaction strength with review acceptance.' AS notes
FROM ranked
WHERE review_count > 0
UNION ALL
SELECT
    'brand_margin_proxy_quality' AS evidence_block,
    'brand' AS grain,
    BrandName AS item,
    CAST(transaction_rank AS VARCHAR) AS item_2,
    CAST(margin_rate_rank AS VARCHAR) AS item_3,
    'margin_rate_rank' AS rank_label,
    CAST(margin_rate_rank AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(1 AS BIGINT) AS brands,
    CAST(review_count AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_rating, 4) AS avg_rating,
    ROUND(transaction_share_pct, 4) AS transaction_share_pct,
    ROUND(review_share_pct, 4) AS review_share_pct,
    'Separate revenue scale from gross-margin proxy quality.' AS notes
FROM ranked
UNION ALL
SELECT
    'brand_quality_mismatch' AS evidence_block,
    'brand' AS grain,
    BrandName AS item,
    CAST(transaction_rank AS VARCHAR) AS item_2,
    CAST(rating_rank AS VARCHAR) || '/' || CAST(margin_rate_rank AS VARCHAR) AS item_3,
    'absolute_rank_gap' AS rank_label,
    CAST(ABS(transaction_rank - COALESCE(rating_rank, transaction_rank)) AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(1 AS BIGINT) AS brands,
    CAST(review_count AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_rating, 4) AS avg_rating,
    ROUND(transaction_share_pct, 4) AS transaction_share_pct,
    ROUND(review_share_pct, 4) AS review_share_pct,
    'Find demand, rating, and margin-proxy mismatches for candidate insights.' AS notes
FROM ranked
WHERE review_count > 0
UNION ALL
SELECT
    'review_coverage_baseline' AS evidence_block,
    'brand' AS grain,
    BrandName AS item,
    CAST(transaction_rank AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'review_count' AS rank_label,
    CAST(review_count AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(1 AS BIGINT) AS brands,
    CAST(review_count AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_rating, 4) AS avg_rating,
    ROUND(transaction_share_pct, 4) AS transaction_share_pct,
    ROUND(review_share_pct, 4) AS review_share_pct,
    'Audit whether brand acceptance evidence is well covered by reviews.' AS notes
FROM ranked
ORDER BY evidence_block, rank_value DESC NULLS LAST, item;
