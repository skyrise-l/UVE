-- task_052_channel_discount_fulfillment_evidence.sql
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
        so._CustomerID AS customer_id,
        so._StoreID AS store_id,
        sl.State AS state_name,
        r.Region AS store_region,
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
            COALESCE(try_strptime(so.ShipDate, '%m/%d/%y'), try_strptime(so.ShipDate, '%m/%d/%Y'))
        ) AS ship_lag_days,
        date_diff('day',
            COALESCE(try_strptime(so.OrderDate, '%m/%d/%y'), try_strptime(so.OrderDate, '%m/%d/%Y')),
            COALESCE(try_strptime(so.DeliveryDate, '%m/%d/%y'), try_strptime(so.DeliveryDate, '%m/%d/%Y'))
        ) AS delivery_lag_days
    FROM Sales_Orders so
    LEFT JOIN Store_Locations sl ON so._StoreID = sl.StoreID
    LEFT JOIN Regions r ON sl.StateCode = r.StateCode
    LEFT JOIN Products p ON so._ProductID = p.ProductID
),
channel_metrics AS (
    SELECT
        sales_channel,
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT product_id) AS products,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount,
        AVG(delivery_lag_days) AS avg_delivery_days
    FROM sales_fact
    GROUP BY sales_channel
),
ranked_channel AS (
    SELECT
        *,
        100.0 * net_sales_proxy / NULLIF(SUM(net_sales_proxy) OVER (), 0) AS sales_share_pct,
        ROW_NUMBER() OVER (ORDER BY net_sales_proxy DESC, sales_channel) AS sales_rank,
        ROW_NUMBER() OVER (ORDER BY gross_margin_proxy_rate DESC, sales_channel) AS margin_rank
    FROM channel_metrics
),
channel_discount AS (
    SELECT
        sales_channel,
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
    GROUP BY sales_channel,
        CASE
            WHEN discount_applied <= 0.075 THEN 'low_discount'
            WHEN discount_applied <= 0.150 THEN 'mid_discount'
            ELSE 'high_discount'
        END
),
delivery_bucket AS (
    SELECT
        sales_channel,
        CASE
            WHEN delivery_lag_days <= 10 THEN 'fast_0_10_days'
            WHEN delivery_lag_days <= 20 THEN 'medium_11_20_days'
            ELSE 'slow_21_plus_days'
        END AS delivery_bucket,
        COUNT(*) AS orders,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(delivery_lag_days) AS avg_delivery_days
    FROM sales_fact
    GROUP BY sales_channel,
        CASE
            WHEN delivery_lag_days <= 10 THEN 'fast_0_10_days'
            WHEN delivery_lag_days <= 20 THEN 'medium_11_20_days'
            ELSE 'slow_21_plus_days'
        END
),
warehouse_metrics AS (
    SELECT
        WarehouseCode,
        COUNT(*) AS orders,
        COUNT(DISTINCT sales_channel) AS channels,
        COUNT(DISTINCT store_region) AS store_regions,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount,
        AVG(delivery_lag_days) AS avg_delivery_days
    FROM sales_fact
    GROUP BY WarehouseCode
),
channel_warehouse AS (
    SELECT
        sales_channel,
        WarehouseCode,
        COUNT(*) AS orders,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(delivery_lag_days) AS avg_delivery_days,
        ROW_NUMBER() OVER (
            PARTITION BY sales_channel
            ORDER BY COUNT(*) DESC, WarehouseCode
        ) AS warehouse_rank_in_channel
    FROM sales_fact
    GROUP BY sales_channel, WarehouseCode
),
channel_product AS (
    SELECT
        sales_channel,
        product_name,
        COUNT(*) AS orders,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        ROW_NUMBER() OVER (
            PARTITION BY sales_channel
            ORDER BY SUM(net_sales_proxy) DESC, product_name
        ) AS product_rank_in_channel
    FROM sales_fact
    GROUP BY sales_channel, product_name
)
SELECT
    'channel_business_quality' AS evidence_block,
    'sales_channel' AS grain,
    sales_channel AS item,
    CAST(sales_rank AS VARCHAR) AS item_2,
    CAST(margin_rank AS VARCHAR) AS item_3,
    'sales_rank' AS rank_label,
    CAST(sales_rank AS DOUBLE) AS rank_value,
    orders,
    customers,
    stores,
    products,
    CAST(NULL AS BIGINT) AS warehouses,
    ROUND(net_sales_proxy, 4) AS net_sales_proxy,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(100.0 * avg_discount, 4) AS avg_discount_pct,
    ROUND(avg_delivery_days, 4) AS avg_delivery_days,
    ROUND(sales_share_pct, 4) AS share_pct,
    'Compare channel scale with margin proxy, discount, and delivery signals.' AS notes
FROM ranked_channel
UNION ALL
SELECT
    'channel_discount_mix',
    'sales_channel_discount_bucket',
    sales_channel,
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
    'Check whether channel quality is explained by discount exposure.'
FROM channel_discount
UNION ALL
SELECT
    'channel_delivery_mix',
    'sales_channel_delivery_bucket',
    sales_channel,
    delivery_bucket,
    CAST(NULL AS VARCHAR),
    'delivery_bucket',
    CAST(NULL AS DOUBLE),
    orders,
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    CAST(NULL AS DOUBLE),
    ROUND(avg_delivery_days, 4),
    CAST(NULL AS DOUBLE),
    'Separate fulfillment speed from channel sales quality.'
FROM delivery_bucket
UNION ALL
SELECT
    'warehouse_performance',
    'warehouse',
    WarehouseCode,
    CAST(channels AS VARCHAR),
    CAST(store_regions AS VARCHAR),
    'warehouse_sales',
    CAST(NULL AS DOUBLE),
    orders,
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    channels,
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(100.0 * avg_discount, 4),
    ROUND(avg_delivery_days, 4),
    CAST(NULL AS DOUBLE),
    'Use warehouse as a fulfillment and mix lens rather than a standalone quality label.'
FROM warehouse_metrics
UNION ALL
SELECT
    'channel_warehouse_mix',
    'sales_channel_warehouse',
    sales_channel,
    WarehouseCode,
    CAST(warehouse_rank_in_channel AS VARCHAR),
    'warehouse_rank_in_channel',
    CAST(warehouse_rank_in_channel AS DOUBLE),
    orders,
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    CAST(NULL AS DOUBLE),
    ROUND(avg_delivery_days, 4),
    CAST(NULL AS DOUBLE),
    'Identify whether channel patterns are tied to a few warehouse lanes.'
FROM channel_warehouse
WHERE warehouse_rank_in_channel <= 3
UNION ALL
SELECT
    'channel_product_mix',
    'sales_channel_product',
    sales_channel,
    product_name,
    CAST(product_rank_in_channel AS VARCHAR),
    'product_rank_in_channel',
    CAST(product_rank_in_channel AS DOUBLE),
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
    'Check whether product mix, not channel alone, explains channel quality.'
FROM channel_product
WHERE product_rank_in_channel <= 5
