-- task_058_warehouse_network_resilience_evidence.sql
-- Draft task-level Evidence SQL for regional_sales.

WITH
sales_fact AS (
    SELECT
        so.OrderNumber,
        so."Sales Channel" AS sales_channel,
        so.WarehouseCode AS warehouse_code,
        COALESCE(try_strptime(so.OrderDate, '%m/%d/%y'), try_strptime(so.OrderDate, '%m/%d/%Y')) AS order_date,
        COALESCE(try_strptime(so.DeliveryDate, '%m/%d/%y'), try_strptime(so.DeliveryDate, '%m/%d/%Y')) AS delivery_date,
        so._CustomerID AS customer_id,
        so._StoreID AS store_id,
        r.Region AS store_region,
        so._ProductID AS product_id,
        p."Product Name" AS product_name,
        so."Order Quantity" AS order_quantity,
        so."Discount Applied" AS discount_applied,
        CAST(REPLACE(so."Unit Price", ',', '') AS DOUBLE) * so."Order Quantity" * (1.0 - so."Discount Applied") AS net_sales_proxy,
        (CAST(REPLACE(so."Unit Price", ',', '') AS DOUBLE) - CAST(REPLACE(so."Unit Cost", ',', '') AS DOUBLE))
            * so."Order Quantity" * (1.0 - so."Discount Applied") AS gross_margin_proxy,
        date_diff('day',
            COALESCE(try_strptime(so.OrderDate, '%m/%d/%y'), try_strptime(so.OrderDate, '%m/%d/%Y')),
            COALESCE(try_strptime(so.DeliveryDate, '%m/%d/%y'), try_strptime(so.DeliveryDate, '%m/%d/%Y'))
        ) AS order_to_delivery_days
    FROM Sales_Orders so
    LEFT JOIN Store_Locations sl ON so._StoreID = sl.StoreID
    LEFT JOIN Regions r ON sl.StateCode = r.StateCode
    LEFT JOIN Products p ON so._ProductID = p.ProductID
),
warehouse_metrics AS (
    SELECT
        warehouse_code,
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT product_id) AS products,
        COUNT(DISTINCT sales_channel) AS channels,
        COUNT(DISTINCT store_region) AS regions,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount,
        AVG(order_to_delivery_days) AS avg_delivery_days,
        100.0 * SUM(CASE WHEN order_to_delivery_days > 20 THEN net_sales_proxy ELSE 0 END) / NULLIF(SUM(net_sales_proxy), 0) AS slow_sales_share_pct
    FROM sales_fact
    GROUP BY warehouse_code
),
ranked_warehouse AS (
    SELECT
        *,
        100.0 * net_sales_proxy / NULLIF(SUM(net_sales_proxy) OVER (), 0) AS sales_share_pct,
        ROW_NUMBER() OVER (ORDER BY net_sales_proxy DESC, warehouse_code) AS sales_rank,
        ROW_NUMBER() OVER (ORDER BY gross_margin_proxy_rate DESC, warehouse_code) AS margin_rank,
        ROW_NUMBER() OVER (ORDER BY slow_sales_share_pct DESC, warehouse_code) AS slow_exposure_rank
    FROM warehouse_metrics
),
warehouse_concentration AS (
    SELECT
        SUM(CASE WHEN sales_rank <= 2 THEN net_sales_proxy ELSE 0 END) AS top2_sales,
        SUM(net_sales_proxy) AS all_sales,
        COUNT(*) AS warehouse_count
    FROM ranked_warehouse
),
warehouse_channel AS (
    SELECT
        warehouse_code,
        sales_channel,
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT product_id) AS products,
        COUNT(DISTINCT store_region) AS regions,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount,
        AVG(order_to_delivery_days) AS avg_delivery_days,
        ROW_NUMBER() OVER (
            PARTITION BY warehouse_code
            ORDER BY SUM(net_sales_proxy) DESC, sales_channel
        ) AS channel_rank_in_warehouse
    FROM sales_fact
    GROUP BY warehouse_code, sales_channel
),
warehouse_region AS (
    SELECT
        warehouse_code,
        COALESCE(store_region, 'UNKNOWN') AS store_region,
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT product_id) AS products,
        COUNT(DISTINCT sales_channel) AS channels,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount,
        AVG(order_to_delivery_days) AS avg_delivery_days,
        ROW_NUMBER() OVER (
            PARTITION BY warehouse_code
            ORDER BY SUM(net_sales_proxy) DESC, COALESCE(store_region, 'UNKNOWN')
        ) AS region_rank_in_warehouse
    FROM sales_fact
    GROUP BY warehouse_code, COALESCE(store_region, 'UNKNOWN')
),
warehouse_product AS (
    SELECT
        warehouse_code,
        product_name,
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT sales_channel) AS channels,
        COUNT(DISTINCT store_region) AS regions,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount,
        AVG(order_to_delivery_days) AS avg_delivery_days,
        ROW_NUMBER() OVER (
            PARTITION BY warehouse_code
            ORDER BY SUM(net_sales_proxy) DESC, product_name
        ) AS product_rank_in_warehouse
    FROM sales_fact
    GROUP BY warehouse_code, product_name
)
SELECT
    'warehouse_sales_concentration' AS evidence_block,
    'warehouse_portfolio' AS grain,
    'top_2_warehouses_by_sales' AS item,
    CAST(warehouse_count AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'top2_warehouse_sales_share' AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS orders,
    CAST(NULL AS BIGINT) AS customers,
    CAST(NULL AS BIGINT) AS stores,
    CAST(NULL AS BIGINT) AS products,
    CAST(NULL AS BIGINT) AS channels,
    CAST(NULL AS BIGINT) AS regions,
    ROUND(top2_sales, 4) AS net_sales_proxy,
    CAST(NULL AS DOUBLE) AS gross_margin_proxy,
    CAST(NULL AS DOUBLE) AS gross_margin_proxy_rate_pct,
    CAST(NULL AS DOUBLE) AS avg_discount_pct,
    CAST(NULL AS DOUBLE) AS avg_delivery_days,
    ROUND(100.0 * top2_sales / NULLIF(all_sales, 0), 4) AS share_pct,
    'Check whether warehouse dependence is concentrated in a small head.' AS notes
FROM warehouse_concentration
UNION ALL
SELECT
    'warehouse_performance_profile',
    'warehouse',
    warehouse_code,
    CAST(sales_rank AS VARCHAR),
    CAST(margin_rank AS VARCHAR),
    'warehouse_sales_rank',
    CAST(sales_rank AS DOUBLE),
    orders,
    customers,
    stores,
    products,
    channels,
    regions,
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(100.0 * avg_discount, 4),
    ROUND(avg_delivery_days, 4),
    ROUND(sales_share_pct, 4),
    'Compare warehouse scale, breadth, conversion quality, and slow-delivery exposure.'
FROM ranked_warehouse
UNION ALL
SELECT
    'warehouse_slow_exposure',
    'warehouse',
    warehouse_code,
    CAST(slow_exposure_rank AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'slow_sales_share_rank',
    CAST(slow_exposure_rank AS DOUBLE),
    orders,
    customers,
    stores,
    products,
    channels,
    regions,
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(100.0 * avg_discount, 4),
    ROUND(avg_delivery_days, 4),
    ROUND(slow_sales_share_pct, 4),
    'Rank warehouses by the share of sales tied to slow delivery.'
FROM ranked_warehouse
UNION ALL
SELECT
    'warehouse_channel_mix',
    'warehouse_channel',
    warehouse_code,
    sales_channel,
    CAST(channel_rank_in_warehouse AS VARCHAR),
    'channel_rank_in_warehouse',
    CAST(channel_rank_in_warehouse AS DOUBLE),
    orders,
    customers,
    stores,
    products,
    CAST(NULL AS BIGINT),
    regions,
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(100.0 * avg_discount, 4),
    ROUND(avg_delivery_days, 4),
    CAST(NULL AS DOUBLE),
    'Check whether warehouse dependence is tied to specific sales channels.'
FROM warehouse_channel
WHERE channel_rank_in_warehouse <= 3
UNION ALL
SELECT
    'warehouse_region_mix',
    'warehouse_region',
    warehouse_code,
    store_region,
    CAST(region_rank_in_warehouse AS VARCHAR),
    'region_rank_in_warehouse',
    CAST(region_rank_in_warehouse AS DOUBLE),
    orders,
    customers,
    stores,
    products,
    channels,
    CAST(NULL AS BIGINT),
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(100.0 * avg_discount, 4),
    ROUND(avg_delivery_days, 4),
    CAST(NULL AS DOUBLE),
    'Check whether warehouse volume is geographically diversified or region-heavy.'
FROM warehouse_region
WHERE region_rank_in_warehouse <= 3
UNION ALL
SELECT
    'warehouse_product_mix',
    'warehouse_product',
    warehouse_code,
    product_name,
    CAST(product_rank_in_warehouse AS VARCHAR),
    'product_rank_in_warehouse',
    CAST(product_rank_in_warehouse AS DOUBLE),
    orders,
    customers,
    stores,
    CAST(NULL AS BIGINT),
    channels,
    regions,
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(100.0 * avg_discount, 4),
    ROUND(avg_delivery_days, 4),
    CAST(NULL AS DOUBLE),
    'Identify product cells that dominate individual warehouse lanes.'
FROM warehouse_product
WHERE product_rank_in_warehouse <= 5
