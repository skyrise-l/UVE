-- task_034_brand_attributes_market_fit_evidence.sql
-- Draft task-level Evidence SQL for beer_factory brand attributes and market fit.

WITH
sales_fact AS (
    SELECT
        t.TransactionID,
        t.CustomerID,
        t.PurchasePrice,
        rb.RootBeerID,
        rb.ContainerType,
        rb.BrandID,
        b.BrandName,
        b.CaneSugar,
        b.CornSyrup,
        b.Honey,
        b.ArtificialSweetener,
        b.Caffeinated,
        b.AvailableInCans,
        b.AvailableInBottles,
        b.WholesaleCost,
        t.PurchasePrice - b.WholesaleCost AS gross_margin_proxy
    FROM "transaction" t
    JOIN rootbeer rb ON t.RootBeerID = rb.RootBeerID
    JOIN rootbeerbrand b ON rb.BrandID = b.BrandID
),
review_by_brand AS (
    SELECT
        BrandID,
        COUNT(*) AS review_count,
        AVG(StarRating) AS avg_rating
    FROM rootbeerreview
    GROUP BY BrandID
),
brand_metrics AS (
    SELECT
        sf.BrandID,
        sf.BrandName,
        MAX(sf.CaneSugar) AS CaneSugar,
        MAX(sf.CornSyrup) AS CornSyrup,
        MAX(sf.Honey) AS Honey,
        MAX(sf.ArtificialSweetener) AS ArtificialSweetener,
        MAX(sf.Caffeinated) AS Caffeinated,
        MAX(sf.AvailableInCans) AS AvailableInCans,
        MAX(sf.AvailableInBottles) AS AvailableInBottles,
        COUNT(*) AS transactions,
        COUNT(DISTINCT sf.CustomerID) AS customers,
        SUM(sf.PurchasePrice) AS revenue,
        SUM(sf.gross_margin_proxy) AS gross_margin_proxy,
        SUM(sf.gross_margin_proxy) / NULLIF(SUM(sf.PurchasePrice), 0) AS gross_margin_proxy_rate,
        COALESCE(MAX(rb.review_count), 0) AS review_count,
        MAX(rb.avg_rating) AS avg_rating
    FROM sales_fact sf
    LEFT JOIN review_by_brand rb ON sf.BrandID = rb.BrandID
    GROUP BY sf.BrandID, sf.BrandName
),
brand_container AS (
    SELECT
        BrandID,
        SUM(CASE WHEN ContainerType = 'Can' THEN 1 ELSE 0 END) AS can_transactions,
        SUM(CASE WHEN ContainerType = 'Bottle' THEN 1 ELSE 0 END) AS bottle_transactions
    FROM sales_fact
    GROUP BY BrandID
),
attribute_brand AS (
    SELECT BrandID, BrandName, 'CaneSugar' AS attribute_name, CaneSugar AS attribute_value, transactions, customers, revenue, gross_margin_proxy, gross_margin_proxy_rate, review_count, avg_rating FROM brand_metrics
    UNION ALL
    SELECT BrandID, BrandName, 'CornSyrup' AS attribute_name, CornSyrup AS attribute_value, transactions, customers, revenue, gross_margin_proxy, gross_margin_proxy_rate, review_count, avg_rating FROM brand_metrics
    UNION ALL
    SELECT BrandID, BrandName, 'Honey' AS attribute_name, Honey AS attribute_value, transactions, customers, revenue, gross_margin_proxy, gross_margin_proxy_rate, review_count, avg_rating FROM brand_metrics
    UNION ALL
    SELECT BrandID, BrandName, 'ArtificialSweetener' AS attribute_name, ArtificialSweetener AS attribute_value, transactions, customers, revenue, gross_margin_proxy, gross_margin_proxy_rate, review_count, avg_rating FROM brand_metrics
    UNION ALL
    SELECT BrandID, BrandName, 'Caffeinated' AS attribute_name, Caffeinated AS attribute_value, transactions, customers, revenue, gross_margin_proxy, gross_margin_proxy_rate, review_count, avg_rating FROM brand_metrics
),
attribute_summary AS (
    SELECT
        attribute_name,
        attribute_value,
        COUNT(*) AS brands,
        SUM(transactions) AS transactions,
        SUM(customers) AS customers,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(revenue), 0) AS gross_margin_proxy_rate,
        SUM(review_count) AS review_count,
        SUM(avg_rating * review_count) / NULLIF(SUM(review_count), 0) AS weighted_avg_rating
    FROM attribute_brand
    GROUP BY attribute_name, attribute_value
),
ranked_attribute AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY attribute_name ORDER BY transactions DESC, attribute_value) AS demand_rank,
        ROW_NUMBER() OVER (PARTITION BY attribute_name ORDER BY weighted_avg_rating DESC NULLS LAST, review_count DESC, attribute_value) AS rating_rank,
        ROW_NUMBER() OVER (PARTITION BY attribute_name ORDER BY gross_margin_proxy_rate DESC NULLS LAST, revenue DESC, attribute_value) AS margin_rank
    FROM attribute_summary
),
ranked_brand_in_attribute AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY attribute_name, attribute_value ORDER BY transactions DESC, BrandName) AS brand_demand_rank_in_group
    FROM attribute_brand
),
availability_alignment AS (
    SELECT
        bm.BrandID,
        bm.BrandName,
        bm.AvailableInCans,
        bm.AvailableInBottles,
        COALESCE(bc.can_transactions, 0) AS can_transactions,
        COALESCE(bc.bottle_transactions, 0) AS bottle_transactions,
        bm.transactions,
        bm.revenue,
        bm.gross_margin_proxy,
        bm.gross_margin_proxy_rate,
        bm.review_count,
        bm.avg_rating
    FROM brand_metrics bm
    LEFT JOIN brand_container bc ON bm.BrandID = bc.BrandID
)
SELECT
    'sweetener_demand_comparison' AS evidence_block,
    'attribute_group' AS grain,
    attribute_name AS item,
    attribute_value AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'demand_rank_within_attribute' AS rank_label,
    CAST(demand_rank AS DOUBLE) AS rank_value,
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
    'Compare attribute groups on transaction demand.' AS notes
FROM ranked_attribute
WHERE attribute_name IN ('CaneSugar', 'CornSyrup', 'Honey', 'ArtificialSweetener')
UNION ALL
SELECT
    'sweetener_rating_comparison' AS evidence_block,
    'attribute_group' AS grain,
    attribute_name AS item,
    attribute_value AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'rating_rank_within_attribute' AS rank_label,
    CAST(rating_rank AS DOUBLE) AS rank_value,
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
    'Compare attribute groups on review acceptance.' AS notes
FROM ranked_attribute
WHERE attribute_name IN ('CaneSugar', 'CornSyrup', 'Honey', 'ArtificialSweetener')
UNION ALL
SELECT
    'caffeine_market_signal' AS evidence_block,
    'attribute_group' AS grain,
    attribute_name AS item,
    attribute_value AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'demand_rank_within_attribute' AS rank_label,
    CAST(demand_rank AS DOUBLE) AS rank_value,
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
    'Test whether caffeine status carries demand, rating, or margin-proxy signal.' AS notes
FROM ranked_attribute
WHERE attribute_name = 'Caffeinated'
UNION ALL
SELECT
    'availability_container_alignment' AS evidence_block,
    'brand' AS grain,
    BrandName AS item,
    AvailableInCans AS item_2,
    AvailableInBottles AS item_3,
    'can_transactions' AS rank_label,
    CAST(can_transactions AS DOUBLE) AS rank_value,
    CAST(transactions AS BIGINT) AS transactions,
    CAST(NULL AS BIGINT) AS customers,
    CAST(1 AS BIGINT) AS brands,
    CAST(review_count AS BIGINT) AS reviews,
    ROUND(revenue, 4) AS revenue,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_rating, 4) AS avg_rating,
    CAST(NULL AS DOUBLE) AS transaction_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Check whether declared package availability aligns with observed container sales.' AS notes
FROM availability_alignment
UNION ALL
SELECT
    'attribute_brand_exception' AS evidence_block,
    'attribute_brand' AS grain,
    BrandName AS item,
    attribute_name AS item_2,
    attribute_value AS item_3,
    'brand_demand_rank_in_group' AS rank_label,
    CAST(brand_demand_rank_in_group AS DOUBLE) AS rank_value,
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
    'Find brands that may drive an attribute-level pattern.' AS notes
FROM ranked_brand_in_attribute
WHERE brand_demand_rank_in_group <= 3
UNION ALL
SELECT
    'attribute_margin_proxy_quality' AS evidence_block,
    'attribute_group' AS grain,
    attribute_name AS item,
    attribute_value AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'margin_rank_within_attribute' AS rank_label,
    CAST(margin_rank AS DOUBLE) AS rank_value,
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
    'Check whether attribute groups differ in gross-margin proxy quality.' AS notes
FROM ranked_attribute
ORDER BY evidence_block, item, rank_value ASC NULLS LAST;
