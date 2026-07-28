-- task_051_regional_margin_conversion_evidence.sql
-- Draft task-level Evidence SQL for regional_sales.

WITH
sales_fact AS (
    SELECT
        so.OrderNumber,
        so."Sales Channel" AS sales_channel,
        so.WarehouseCode,
        COALESCE(try_strptime(so.OrderDate, '%m/%d/%y'), try_strptime(so.OrderDate, '%m/%d/%Y')) AS order_date,
        COALESCE(try_strptime(so.ShipDate, '%m/%d/%y'), try_strptime(so.ShipDate, '%m/%d/%Y')) AS ship_date,
        COALESCE(try_strptime(so.DeliveryDate, '%m/%d/%y'), try_strptime(so.DeliveryDate, '%m/%d/%Y')) AS delivery_date,
        so._SalesTeamID AS sales_team_id,
        st."Sales Team" AS sales_team,
        st.Region AS sales_team_region,
        so._CustomerID AS customer_id,
        so._StoreID AS store_id,
        sl."City Name" AS city_name,
        sl.StateCode AS state_code,
        sl.State AS state_name,
        r.Region AS store_region,
        sl.Type AS store_type,
        so._ProductID AS product_id,
        p."Product Name" AS product_name,
        so."Order Quantity" AS order_quantity,
        so."Discount Applied" AS discount_applied,
        CAST(REPLACE(so."Unit Price", ',', '') AS DOUBLE) AS unit_price,
        CAST(REPLACE(so."Unit Cost", ',', '') AS DOUBLE) AS unit_cost,
        CAST(REPLACE(so."Unit Price", ',', '') AS DOUBLE) * so."Order Quantity" * (1.0 - so."Discount Applied") AS net_sales_proxy,
        (CAST(REPLACE(so."Unit Price", ',', '') AS DOUBLE) - CAST(REPLACE(so."Unit Cost", ',', '') AS DOUBLE))
            * so."Order Quantity" * (1.0 - so."Discount Applied") AS gross_margin_proxy,
        date_diff('day',
            COALESCE(try_strptime(so.OrderDate, '%m/%d/%y'), try_strptime(so.OrderDate, '%m/%d/%Y')),
            COALESCE(try_strptime(so.DeliveryDate, '%m/%d/%y'), try_strptime(so.DeliveryDate, '%m/%d/%Y'))
        ) AS delivery_lag_days
    FROM Sales_Orders so
    LEFT JOIN Sales_Team st ON so._SalesTeamID = st.SalesTeamID
    LEFT JOIN Store_Locations sl ON so._StoreID = sl.StoreID
    LEFT JOIN Regions r ON sl.StateCode = r.StateCode
    LEFT JOIN Products p ON so._ProductID = p.ProductID
),
overall AS (
    SELECT
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT product_id) AS products,
        COUNT(DISTINCT sales_team_id) AS sales_teams,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount,
        AVG(delivery_lag_days) AS avg_delivery_days
    FROM sales_fact
),
region_metrics AS (
    SELECT
        COALESCE(store_region, 'UNKNOWN') AS store_region,
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT product_id) AS products,
        COUNT(DISTINCT sales_team_id) AS sales_teams,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount,
        AVG(delivery_lag_days) AS avg_delivery_days
    FROM sales_fact
    GROUP BY COALESCE(store_region, 'UNKNOWN')
),
ranked_region AS (
    SELECT
        rm.*,
        100.0 * rm.net_sales_proxy / NULLIF(SUM(rm.net_sales_proxy) OVER (), 0) AS sales_share_pct,
        ROW_NUMBER() OVER (ORDER BY rm.net_sales_proxy DESC, rm.store_region) AS sales_rank,
        ROW_NUMBER() OVER (ORDER BY rm.gross_margin_proxy_rate DESC, rm.store_region) AS margin_rate_rank
    FROM region_metrics rm
),
region_channel AS (
    SELECT
        COALESCE(store_region, 'UNKNOWN') AS store_region,
        sales_channel,
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT product_id) AS products,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount,
        ROW_NUMBER() OVER (
            PARTITION BY COALESCE(store_region, 'UNKNOWN')
            ORDER BY SUM(net_sales_proxy) DESC, sales_channel
        ) AS channel_rank_in_region
    FROM sales_fact
    GROUP BY COALESCE(store_region, 'UNKNOWN'), sales_channel
),
region_discount AS (
    SELECT
        COALESCE(store_region, 'UNKNOWN') AS store_region,
        CASE
            WHEN discount_applied <= 0.075 THEN 'low_discount'
            WHEN discount_applied <= 0.150 THEN 'mid_discount'
            ELSE 'high_discount'
        END AS discount_bucket,
        COUNT(*) AS orders,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount
    FROM sales_fact
    GROUP BY
        COALESCE(store_region, 'UNKNOWN'),
        CASE
            WHEN discount_applied <= 0.075 THEN 'low_discount'
            WHEN discount_applied <= 0.150 THEN 'mid_discount'
            ELSE 'high_discount'
        END
),
region_product AS (
    SELECT
        COALESCE(store_region, 'UNKNOWN') AS store_region,
        product_name,
        COUNT(*) AS orders,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        ROW_NUMBER() OVER (
            PARTITION BY COALESCE(store_region, 'UNKNOWN')
            ORDER BY SUM(net_sales_proxy) DESC, product_name
        ) AS product_rank_in_region
    FROM sales_fact
    GROUP BY COALESCE(store_region, 'UNKNOWN'), product_name
),
state_metrics AS (
    SELECT
        COALESCE(store_region, 'UNKNOWN') AS store_region,
        COALESCE(state_name, 'UNKNOWN') AS state_name,
        COUNT(*) AS orders,
        COUNT(DISTINCT store_id) AS stores,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount,
        ROW_NUMBER() OVER (
            PARTITION BY COALESCE(store_region, 'UNKNOWN')
            ORDER BY SUM(net_sales_proxy) DESC, COALESCE(state_name, 'UNKNOWN')
        ) AS state_rank_in_region
    FROM sales_fact
    GROUP BY COALESCE(store_region, 'UNKNOWN'), COALESCE(state_name, 'UNKNOWN')
)
SELECT
    'overall_conversion_baseline' AS evidence_block,
    'portfolio' AS grain,
    'all_orders' AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'overall' AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    orders,
    customers,
    stores,
    products,
    sales_teams,
    ROUND(net_sales_proxy, 4) AS net_sales_proxy,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(100.0 * avg_discount, 4) AS avg_discount_pct,
    ROUND(avg_delivery_days, 4) AS avg_delivery_days,
    CAST(NULL AS DOUBLE) AS share_pct,
    'Establish overall sales-to-gross-margin proxy conversion before diagnosing regional gaps.' AS notes
FROM overall
UNION ALL
SELECT
    'region_conversion_quality',
    'store_region',
    store_region,
    CAST(sales_rank AS VARCHAR),
    CAST(margin_rate_rank AS VARCHAR),
    'sales_rank',
    CAST(sales_rank AS DOUBLE),
    orders,
    customers,
    stores,
    products,
    sales_teams,
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(100.0 * avg_discount, 4),
    ROUND(avg_delivery_days, 4),
    ROUND(sales_share_pct, 4),
    'Compare regional scale with gross-margin proxy conversion and discount exposure.'
FROM ranked_region
UNION ALL
SELECT
    'region_channel_mix',
    'store_region_channel',
    store_region,
    sales_channel,
    CAST(channel_rank_in_region AS VARCHAR),
    'channel_rank_in_region',
    CAST(channel_rank_in_region AS DOUBLE),
    orders,
    customers,
    CAST(NULL AS BIGINT),
    products,
    CAST(NULL AS BIGINT),
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(100.0 * avg_discount, 4),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    'Check whether regional conversion is partly explained by channel mix.'
FROM region_channel
WHERE channel_rank_in_region <= 3
UNION ALL
SELECT
    'region_discount_exposure',
    'store_region_discount_bucket',
    store_region,
    discount_bucket,
    CAST(NULL AS VARCHAR),
    'discount_bucket',
    CAST(NULL AS DOUBLE),
    orders,
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(100.0 * avg_discount, 4),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    'Test whether discount intensity changes gross-margin proxy conversion inside regions.'
FROM region_discount
UNION ALL
SELECT
    'region_product_mix',
    'store_region_product',
    store_region,
    product_name,
    CAST(product_rank_in_region AS VARCHAR),
    'product_rank_in_region',
    CAST(product_rank_in_region AS DOUBLE),
    orders,
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    'Identify top product contributors inside each region to separate mix from regional effects.'
FROM region_product
WHERE product_rank_in_region <= 5
UNION ALL
SELECT
    'state_pockets_within_region',
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
    ROUND(100.0 * avg_discount, 4),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    'Check whether state-level pockets inside a region drive the regional conversion story.'
FROM state_metrics
WHERE state_rank_in_region <= 5
