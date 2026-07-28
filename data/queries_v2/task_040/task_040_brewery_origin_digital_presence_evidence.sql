-- task_040_brewery_origin_digital_presence_evidence.sql
-- Draft task-level Evidence SQL for beer_factory.
-- Light/profile stage only: use the output to screen evidence paths, then recalibrate on full results.

WITH
review_by_brand AS (
    SELECT
        BrandID,
        COUNT(*) AS reviews,
        COUNT(DISTINCT CustomerID) AS review_customers,
        AVG(StarRating) AS avg_rating
    FROM rootbeerreview
    GROUP BY BrandID
),
brand_base AS (
    SELECT
        b.BrandID,
        b.BrandName,
        b.BreweryName,
        b.City AS brewery_city,
        b.State AS brewery_state,
        b.Country AS brewery_country,
        CASE
            WHEN b.Country = 'United States' AND b.State = 'CA' THEN 'california_brewery'
            WHEN b.Country = 'United States' THEN 'other_us_brewery'
            ELSE 'non_us_brewery'
        END AS origin_group,
        CASE
            WHEN b.Website IS NOT NULL AND b.Website <> '' THEN 1 ELSE 0
        END
        + CASE
            WHEN b.FacebookPage IS NOT NULL AND b.FacebookPage <> '' THEN 1 ELSE 0
        END
        + CASE
            WHEN b.Twitter IS NOT NULL AND b.Twitter <> '' THEN 1 ELSE 0
        END AS digital_channel_count,
        CASE
            WHEN (
                CASE WHEN b.Website IS NOT NULL AND b.Website <> '' THEN 1 ELSE 0 END
                + CASE WHEN b.FacebookPage IS NOT NULL AND b.FacebookPage <> '' THEN 1 ELSE 0 END
                + CASE WHEN b.Twitter IS NOT NULL AND b.Twitter <> '' THEN 1 ELSE 0 END
            ) >= 2 THEN 'multi_channel_presence'
            WHEN b.Website IS NOT NULL AND b.Website <> '' THEN 'website_only_presence'
            ELSE 'limited_or_no_presence'
        END AS digital_presence_group,
        CASE WHEN b.AvailableInCans = 'TRUE' THEN 1 ELSE 0 END
        + CASE WHEN b.AvailableInBottles = 'TRUE' THEN 1 ELSE 0 END
        + CASE WHEN b.AvailableInKegs = 'TRUE' THEN 1 ELSE 0 END AS declared_package_options,
        b.WholesaleCost,
        b.CurrentRetailPrice
    FROM rootbeerbrand b
),
sales_fact AS (
    SELECT
        t.TransactionID,
        t.CustomerID,
        t.PurchasePrice,
        rb.RootBeerID,
        rb.ContainerType,
        bb.*,
        t.PurchasePrice - bb.WholesaleCost AS gross_margin_proxy
    FROM "transaction" t
    JOIN rootbeer rb ON t.RootBeerID = rb.RootBeerID
    JOIN brand_base bb ON rb.BrandID = bb.BrandID
),
brand_metrics AS (
    SELECT
        sf.BrandID,
        sf.BrandName,
        MAX(sf.BreweryName) AS BreweryName,
        MAX(sf.brewery_city) AS brewery_city,
        MAX(sf.brewery_state) AS brewery_state,
        MAX(sf.brewery_country) AS brewery_country,
        MAX(sf.origin_group) AS origin_group,
        MAX(sf.digital_presence_group) AS digital_presence_group,
        MAX(sf.digital_channel_count) AS digital_channel_count,
        MAX(sf.declared_package_options) AS declared_package_options,
        COUNT(*) AS transactions,
        COUNT(DISTINCT sf.CustomerID) AS customers,
        COUNT(DISTINCT sf.ContainerType) AS containers,
        SUM(sf.PurchasePrice) AS revenue,
        SUM(sf.gross_margin_proxy) AS gross_margin_proxy,
        SUM(sf.gross_margin_proxy) / NULLIF(SUM(sf.PurchasePrice), 0) AS gross_margin_proxy_rate,
        COALESCE(MAX(rb.reviews), 0) AS reviews,
        COALESCE(MAX(rb.review_customers), 0) AS review_customers,
        MAX(rb.avg_rating) AS avg_rating
    FROM sales_fact sf
    LEFT JOIN review_by_brand rb ON sf.BrandID = rb.BrandID
    GROUP BY sf.BrandID, sf.BrandName
),
origin_customer_counts AS (
    SELECT
        origin_group,
        COUNT(DISTINCT CustomerID) AS customers
    FROM sales_fact
    GROUP BY origin_group
),
state_customer_counts AS (
    SELECT
        COALESCE(brewery_state, 'unknown') AS brewery_state,
        COUNT(DISTINCT CustomerID) AS customers
    FROM sales_fact
    GROUP BY COALESCE(brewery_state, 'unknown')
),
digital_customer_counts AS (
    SELECT
        digital_presence_group,
        COUNT(DISTINCT CustomerID) AS customers
    FROM sales_fact
    GROUP BY digital_presence_group
),
origin_package_customer_counts AS (
    SELECT
        origin_group,
        declared_package_options,
        COUNT(DISTINCT CustomerID) AS customers
    FROM sales_fact
    GROUP BY origin_group, declared_package_options
),
origin_metrics AS (
    SELECT
        bm.origin_group,
        COUNT(*) AS brands,
        SUM(transactions) AS transactions,
        MAX(occ.customers) AS customers,
        SUM(reviews) AS reviews,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(revenue), 0) AS gross_margin_proxy_rate,
        AVG(avg_rating) AS avg_rating,
        AVG(CAST(declared_package_options AS DOUBLE)) AS avg_declared_package_options
    FROM brand_metrics bm
    JOIN origin_customer_counts occ ON bm.origin_group = occ.origin_group
    GROUP BY bm.origin_group
),
ranked_origin AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY transactions DESC, origin_group) AS transaction_rank,
        ROW_NUMBER() OVER (ORDER BY avg_rating DESC, origin_group) AS rating_rank,
        ROW_NUMBER() OVER (ORDER BY gross_margin_proxy_rate DESC, origin_group) AS margin_rank
    FROM origin_metrics
),
state_metrics AS (
    SELECT
        COALESCE(bm.brewery_state, 'unknown') AS brewery_state,
        COUNT(*) AS brands,
        SUM(transactions) AS transactions,
        MAX(scc.customers) AS customers,
        SUM(reviews) AS reviews,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(revenue), 0) AS gross_margin_proxy_rate,
        AVG(avg_rating) AS avg_rating,
        ROW_NUMBER() OVER (ORDER BY SUM(transactions) DESC, COALESCE(bm.brewery_state, 'unknown')) AS state_transaction_rank
    FROM brand_metrics bm
    JOIN state_customer_counts scc ON COALESCE(bm.brewery_state, 'unknown') = scc.brewery_state
    GROUP BY COALESCE(bm.brewery_state, 'unknown')
),
digital_metrics AS (
    SELECT
        bm.digital_presence_group,
        COUNT(*) AS brands,
        SUM(transactions) AS transactions,
        MAX(dcc.customers) AS customers,
        SUM(reviews) AS reviews,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(revenue), 0) AS gross_margin_proxy_rate,
        AVG(avg_rating) AS avg_rating,
        AVG(CAST(digital_channel_count AS DOUBLE)) AS avg_digital_channels,
        ROW_NUMBER() OVER (ORDER BY SUM(transactions) DESC, bm.digital_presence_group) AS transaction_rank,
        ROW_NUMBER() OVER (ORDER BY AVG(avg_rating) DESC, bm.digital_presence_group) AS rating_rank,
        ROW_NUMBER() OVER (ORDER BY SUM(gross_margin_proxy) / NULLIF(SUM(revenue), 0) DESC, bm.digital_presence_group) AS margin_rank
    FROM brand_metrics bm
    JOIN digital_customer_counts dcc ON bm.digital_presence_group = dcc.digital_presence_group
    GROUP BY bm.digital_presence_group
),
origin_package AS (
    SELECT
        bm.origin_group,
        bm.declared_package_options,
        COUNT(*) AS brands,
        SUM(transactions) AS transactions,
        MAX(opcc.customers) AS customers,
        SUM(reviews) AS reviews,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(revenue), 0) AS gross_margin_proxy_rate,
        AVG(avg_rating) AS avg_rating
    FROM brand_metrics bm
    JOIN origin_package_customer_counts opcc
        ON bm.origin_group = opcc.origin_group
        AND bm.declared_package_options = opcc.declared_package_options
    GROUP BY bm.origin_group, bm.declared_package_options
),
ranked_brand AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY transactions DESC, BrandName) AS transaction_rank,
        ROW_NUMBER() OVER (ORDER BY avg_rating DESC, reviews DESC, BrandName) AS rating_rank,
        ROW_NUMBER() OVER (ORDER BY gross_margin_proxy_rate DESC, revenue DESC, BrandName) AS margin_rank
    FROM brand_metrics
)
SELECT
    'origin_group_baseline' AS evidence_block,
    'origin_group' AS grain,
    origin_group AS item,
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
    ROUND(avg_declared_package_options, 4) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Compare local, other-US, and non-US brewery origins on demand scale.' AS notes
FROM ranked_origin
UNION ALL
SELECT
    'origin_quality_comparison' AS evidence_block,
    'origin_group' AS grain,
    origin_group AS item,
    CAST(transaction_rank AS VARCHAR) AS item_2,
    CAST(rating_rank AS VARCHAR) || '/' || CAST(margin_rank AS VARCHAR) AS item_3,
    'origin_rating_margin_rank' AS rank_label,
    CAST(
        CASE
            WHEN ABS(transaction_rank - rating_rank) >= ABS(transaction_rank - margin_rank)
                THEN ABS(transaction_rank - rating_rank)
            ELSE ABS(transaction_rank - margin_rank)
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
    ROUND(avg_declared_package_options, 4) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Check whether brewery origin strength is demand, rating, or margin-proxy strength.' AS notes
FROM ranked_origin
UNION ALL
SELECT
    'brewery_state_concentration' AS evidence_block,
    'brewery_state' AS grain,
    brewery_state AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'state_transaction_rank' AS rank_label,
    CAST(state_transaction_rank AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(brands AS BIGINT) AS brands,
    CAST(reviews AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_rating, 4) AS avg_rating,
    CAST(NULL AS DOUBLE) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Inspect whether brewery state origin is concentrated in a few states.' AS notes
FROM state_metrics
UNION ALL
SELECT
    'digital_presence_baseline' AS evidence_block,
    'digital_presence_group' AS grain,
    digital_presence_group AS item,
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
    ROUND(avg_digital_channels, 4) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Compare demand by brand digital presence group.' AS notes
FROM digital_metrics
UNION ALL
SELECT
    'digital_presence_quality' AS evidence_block,
    'digital_presence_group' AS grain,
    digital_presence_group AS item,
    CAST(transaction_rank AS VARCHAR) AS item_2,
    CAST(rating_rank AS VARCHAR) || '/' || CAST(margin_rank AS VARCHAR) AS item_3,
    'digital_rating_margin_rank' AS rank_label,
    CAST(
        CASE
            WHEN ABS(transaction_rank - rating_rank) >= ABS(transaction_rank - margin_rank)
                THEN ABS(transaction_rank - rating_rank)
            ELSE ABS(transaction_rank - margin_rank)
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
    ROUND(avg_digital_channels, 4) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Check whether digital presence aligns with ratings or margin proxy quality.' AS notes
FROM digital_metrics
UNION ALL
SELECT
    'origin_package_mix' AS evidence_block,
    'origin_package_options' AS grain,
    origin_group AS item,
    CAST(declared_package_options AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'declared_package_options' AS rank_label,
    CAST(declared_package_options AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(brands AS BIGINT) AS brands,
    CAST(reviews AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_rating, 4) AS avg_rating,
    CAST(NULL AS DOUBLE) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Separate origin effects from declared package breadth.' AS notes
FROM origin_package
UNION ALL
SELECT
    'origin_brand_exception' AS evidence_block,
    'brand' AS grain,
    BrandName AS item,
    origin_group AS item_2,
    CAST(transaction_rank AS VARCHAR) || '/' || CAST(rating_rank AS VARCHAR) || '/' || CAST(margin_rank AS VARCHAR) AS item_3,
    'transaction_rank' AS rank_label,
    CAST(transaction_rank AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(customers AS BIGINT) AS customers,
    CAST(1 AS BIGINT) AS brands,
    CAST(reviews AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_rating, 4) AS avg_rating,
    CAST(NULL AS DOUBLE) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Retain brand-level exceptions when origin-group averages hide individual brands.' AS notes
FROM ranked_brand;
