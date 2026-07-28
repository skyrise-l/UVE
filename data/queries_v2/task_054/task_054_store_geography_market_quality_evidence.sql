-- task_054_store_geography_market_quality_evidence.sql
-- Draft task-level Evidence SQL for regional_sales.

WITH
sales_fact AS (
    SELECT
        so.OrderNumber,
        so."Sales Channel" AS sales_channel,
        so._CustomerID AS customer_id,
        so._StoreID AS store_id,
        sl."City Name" AS city_name,
        sl.StateCode AS state_code,
        sl.State AS state_name,
        r.Region AS store_region,
        sl.Type AS store_type,
        sl.Population AS population,
        sl."Median Income" AS median_income,
        sl."Household Income" AS household_income,
        sl."Land Area" AS land_area,
        sl."Water Area" AS water_area,
        sl."Time Zone" AS time_zone,
        so._ProductID AS product_id,
        so."Discount Applied" AS discount_applied,
        CAST(REPLACE(so."Unit Price", ',', '') AS DOUBLE) * so."Order Quantity" * (1.0 - so."Discount Applied") AS net_sales_proxy,
        (CAST(REPLACE(so."Unit Price", ',', '') AS DOUBLE) - CAST(REPLACE(so."Unit Cost", ',', '') AS DOUBLE))
            * so."Order Quantity" * (1.0 - so."Discount Applied") AS gross_margin_proxy,
        date_diff('day',
            COALESCE(try_strptime(so.OrderDate, '%m/%d/%y'), try_strptime(so.OrderDate, '%m/%d/%Y')),
            COALESCE(try_strptime(so.DeliveryDate, '%m/%d/%y'), try_strptime(so.DeliveryDate, '%m/%d/%Y'))
        ) AS delivery_lag_days
    FROM Sales_Orders so
    LEFT JOIN Store_Locations sl ON so._StoreID = sl.StoreID
    LEFT JOIN Regions r ON sl.StateCode = r.StateCode
),
region_geo AS (
    SELECT
        COALESCE(store_region, 'UNKNOWN') AS store_region,
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT product_id) AS products,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(population) AS avg_population,
        AVG(median_income) AS avg_median_income,
        AVG(discount_applied) AS avg_discount,
        AVG(delivery_lag_days) AS avg_delivery_days
    FROM sales_fact
    GROUP BY COALESCE(store_region, 'UNKNOWN')
),
ranked_region_geo AS (
    SELECT
        *,
        100.0 * net_sales_proxy / NULLIF(SUM(net_sales_proxy) OVER (), 0) AS sales_share_pct,
        ROW_NUMBER() OVER (ORDER BY net_sales_proxy DESC, store_region) AS sales_rank,
        ROW_NUMBER() OVER (ORDER BY gross_margin_proxy_rate DESC, store_region) AS margin_rank
    FROM region_geo
),
state_geo AS (
    SELECT
        COALESCE(store_region, 'UNKNOWN') AS store_region,
        COALESCE(state_name, 'UNKNOWN') AS state_name,
        COUNT(*) AS orders,
        COUNT(DISTINCT store_id) AS stores,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(population) AS avg_population,
        AVG(median_income) AS avg_median_income,
        ROW_NUMBER() OVER (PARTITION BY COALESCE(store_region, 'UNKNOWN') ORDER BY SUM(net_sales_proxy) DESC, COALESCE(state_name, 'UNKNOWN')) AS state_rank_in_region
    FROM sales_fact
    GROUP BY COALESCE(store_region, 'UNKNOWN'), COALESCE(state_name, 'UNKNOWN')
),
store_type_quality AS (
    SELECT
        COALESCE(store_type, 'UNKNOWN') AS store_type,
        COUNT(*) AS orders,
        COUNT(DISTINCT store_id) AS stores,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(population) AS avg_population,
        AVG(median_income) AS avg_median_income,
        AVG(discount_applied) AS avg_discount
    FROM sales_fact
    GROUP BY COALESCE(store_type, 'UNKNOWN')
),
income_bucket AS (
    SELECT
        CASE
            WHEN median_income IS NULL THEN 'unknown_income'
            WHEN median_income >= 70000 THEN 'high_income'
            WHEN median_income >= 50000 THEN 'mid_income'
            ELSE 'lower_income'
        END AS income_bucket,
        COUNT(*) AS orders,
        COUNT(DISTINCT store_id) AS stores,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(median_income) AS avg_median_income,
        AVG(discount_applied) AS avg_discount
    FROM sales_fact
    GROUP BY
        CASE
            WHEN median_income IS NULL THEN 'unknown_income'
            WHEN median_income >= 70000 THEN 'high_income'
            WHEN median_income >= 50000 THEN 'mid_income'
            ELSE 'lower_income'
        END
),
population_bucket AS (
    SELECT
        CASE
            WHEN population IS NULL THEN 'unknown_population'
            WHEN population >= 500000 THEN 'large_population'
            WHEN population >= 200000 THEN 'mid_population'
            ELSE 'smaller_population'
        END AS population_bucket,
        COUNT(*) AS orders,
        COUNT(DISTINCT store_id) AS stores,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(population) AS avg_population,
        AVG(discount_applied) AS avg_discount
    FROM sales_fact
    GROUP BY
        CASE
            WHEN population IS NULL THEN 'unknown_population'
            WHEN population >= 500000 THEN 'large_population'
            WHEN population >= 200000 THEN 'mid_population'
            ELSE 'smaller_population'
        END
),
city_pockets AS (
    SELECT
        COALESCE(city_name, 'UNKNOWN') AS city_name,
        COALESCE(state_name, 'UNKNOWN') AS state_name,
        COALESCE(store_region, 'UNKNOWN') AS store_region,
        COUNT(*) AS orders,
        COUNT(DISTINCT store_id) AS stores,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(population) AS avg_population,
        AVG(median_income) AS avg_median_income,
        ROW_NUMBER() OVER (ORDER BY SUM(net_sales_proxy) DESC, COALESCE(city_name, 'UNKNOWN')) AS city_sales_rank
    FROM sales_fact
    GROUP BY COALESCE(city_name, 'UNKNOWN'), COALESCE(state_name, 'UNKNOWN'), COALESCE(store_region, 'UNKNOWN')
),
timezone_mix AS (
    SELECT
        COALESCE(time_zone, 'UNKNOWN') AS time_zone,
        COUNT(*) AS orders,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT store_region) AS regions,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate
    FROM sales_fact
    GROUP BY COALESCE(time_zone, 'UNKNOWN')
)
SELECT
    'store_region_market_quality' AS evidence_block,
    'store_region' AS grain,
    store_region AS item,
    CAST(sales_rank AS VARCHAR) AS item_2,
    CAST(margin_rank AS VARCHAR) AS item_3,
    'sales_rank' AS rank_label,
    CAST(sales_rank AS DOUBLE) AS rank_value,
    orders,
    customers,
    stores,
    products,
    CAST(NULL AS BIGINT) AS regions,
    ROUND(net_sales_proxy, 4) AS net_sales_proxy,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_population, 4) AS avg_population,
    ROUND(avg_median_income, 4) AS avg_median_income,
    ROUND(sales_share_pct, 4) AS share_pct,
    'Establish whether store geography changes demand scale and conversion quality.' AS notes
FROM ranked_region_geo
UNION ALL
SELECT
    'state_sales_concentration',
    'store_region_state',
    store_region,
    state_name,
    CAST(state_rank_in_region AS VARCHAR),
    'state_rank_in_region',
    CAST(state_rank_in_region AS DOUBLE),
    orders,
    CAST(NULL AS BIGINT),
    stores,
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(avg_population, 4),
    ROUND(avg_median_income, 4),
    CAST(NULL AS DOUBLE),
    'Check whether regional demand is concentrated in a few states.'
FROM state_geo
WHERE state_rank_in_region <= 5
UNION ALL
SELECT
    'store_type_quality',
    'store_type',
    store_type,
    CAST(NULL AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'store_type',
    CAST(NULL AS DOUBLE),
    orders,
    CAST(NULL AS BIGINT),
    stores,
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(avg_population, 4),
    ROUND(avg_median_income, 4),
    CAST(NULL AS DOUBLE),
    'Compare store type with sales and margin proxy quality.'
FROM store_type_quality
UNION ALL
SELECT
    'income_bucket_quality',
    'median_income_bucket',
    income_bucket,
    CAST(NULL AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'income_bucket',
    CAST(NULL AS DOUBLE),
    orders,
    CAST(NULL AS BIGINT),
    stores,
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    CAST(NULL AS DOUBLE),
    ROUND(avg_median_income, 4),
    CAST(NULL AS DOUBLE),
    'Check whether local income bands align with healthier conversion.'
FROM income_bucket
UNION ALL
SELECT
    'population_bucket_quality',
    'population_bucket',
    population_bucket,
    CAST(NULL AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'population_bucket',
    CAST(NULL AS DOUBLE),
    orders,
    CAST(NULL AS BIGINT),
    stores,
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(avg_population, 4),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    'Check whether city population scale is a demand or quality driver.'
FROM population_bucket
UNION ALL
SELECT
    'city_store_pockets',
    'city_state',
    city_name,
    state_name,
    store_region,
    'city_sales_rank',
    CAST(city_sales_rank AS DOUBLE),
    orders,
    CAST(NULL AS BIGINT),
    stores,
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(avg_population, 4),
    ROUND(avg_median_income, 4),
    CAST(NULL AS DOUBLE),
    'Expose city-level pockets that may be hidden by state or regional averages.'
FROM city_pockets
WHERE city_sales_rank <= 20
UNION ALL
SELECT
    'timezone_mix',
    'time_zone',
    time_zone,
    CAST(regions AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'time_zone',
    CAST(NULL AS DOUBLE),
    orders,
    CAST(NULL AS BIGINT),
    stores,
    CAST(NULL AS BIGINT),
    regions,
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    'Use time zone as a coarse geography-mix check, not as a causal driver.'
FROM timezone_mix
