-- task_057_end_to_end_cycle_risk_evidence.sql
-- Draft task-level Evidence SQL for regional_sales.

WITH
sales_fact AS (
    SELECT
        so.OrderNumber,
        so."Sales Channel" AS sales_channel,
        so.WarehouseCode AS warehouse_code,
        COALESCE(try_strptime(so.ProcuredDate, '%m/%d/%y'), try_strptime(so.ProcuredDate, '%m/%d/%Y')) AS procured_date,
        COALESCE(try_strptime(so.OrderDate, '%m/%d/%y'), try_strptime(so.OrderDate, '%m/%d/%Y')) AS order_date,
        COALESCE(try_strptime(so.ShipDate, '%m/%d/%y'), try_strptime(so.ShipDate, '%m/%d/%Y')) AS ship_date,
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
            * so."Order Quantity" * (1.0 - so."Discount Applied") AS gross_margin_proxy
    FROM Sales_Orders so
    LEFT JOIN Store_Locations sl ON so._StoreID = sl.StoreID
    LEFT JOIN Regions r ON sl.StateCode = r.StateCode
    LEFT JOIN Products p ON so._ProductID = p.ProductID
),
cycle_fact AS (
    SELECT
        *,
        date_diff('day', procured_date, order_date) AS procure_to_order_days,
        date_diff('day', order_date, ship_date) AS order_to_ship_days,
        date_diff('day', ship_date, delivery_date) AS ship_to_delivery_days,
        date_diff('day', order_date, delivery_date) AS order_to_delivery_days,
        CASE
            WHEN date_diff('day', order_date, delivery_date) <= 10 THEN 'fast_0_10_days'
            WHEN date_diff('day', order_date, delivery_date) <= 20 THEN 'medium_11_20_days'
            ELSE 'slow_21_plus_days'
        END AS delivery_bucket
    FROM sales_fact
),
overall AS (
    SELECT
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT product_id) AS products,
        COUNT(DISTINCT sales_channel) AS channels,
        COUNT(DISTINCT warehouse_code) AS warehouses,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(procure_to_order_days) AS avg_procure_to_order_days,
        AVG(order_to_ship_days) AS avg_order_to_ship_days,
        AVG(ship_to_delivery_days) AS avg_ship_to_delivery_days,
        AVG(order_to_delivery_days) AS avg_order_to_delivery_days
    FROM cycle_fact
),
channel_cycle AS (
    SELECT
        sales_channel,
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT product_id) AS products,
        COUNT(DISTINCT warehouse_code) AS warehouses,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(procure_to_order_days) AS avg_procure_to_order_days,
        AVG(order_to_ship_days) AS avg_order_to_ship_days,
        AVG(ship_to_delivery_days) AS avg_ship_to_delivery_days,
        AVG(order_to_delivery_days) AS avg_order_to_delivery_days,
        ROW_NUMBER() OVER (ORDER BY AVG(order_to_delivery_days) DESC, sales_channel) AS slow_rank
    FROM cycle_fact
    GROUP BY sales_channel
),
warehouse_cycle AS (
    SELECT
        warehouse_code,
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT product_id) AS products,
        COUNT(DISTINCT sales_channel) AS channels,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(procure_to_order_days) AS avg_procure_to_order_days,
        AVG(order_to_ship_days) AS avg_order_to_ship_days,
        AVG(ship_to_delivery_days) AS avg_ship_to_delivery_days,
        AVG(order_to_delivery_days) AS avg_order_to_delivery_days,
        ROW_NUMBER() OVER (ORDER BY AVG(order_to_delivery_days) DESC, warehouse_code) AS slow_rank
    FROM cycle_fact
    GROUP BY warehouse_code
),
region_cycle AS (
    SELECT
        COALESCE(store_region, 'UNKNOWN') AS store_region,
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT product_id) AS products,
        COUNT(DISTINCT sales_channel) AS channels,
        COUNT(DISTINCT warehouse_code) AS warehouses,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(procure_to_order_days) AS avg_procure_to_order_days,
        AVG(order_to_ship_days) AS avg_order_to_ship_days,
        AVG(ship_to_delivery_days) AS avg_ship_to_delivery_days,
        AVG(order_to_delivery_days) AS avg_order_to_delivery_days,
        ROW_NUMBER() OVER (ORDER BY AVG(order_to_delivery_days) DESC, COALESCE(store_region, 'UNKNOWN')) AS slow_rank
    FROM cycle_fact
    GROUP BY COALESCE(store_region, 'UNKNOWN')
),
bucket_quality AS (
    SELECT
        delivery_bucket,
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT product_id) AS products,
        COUNT(DISTINCT sales_channel) AS channels,
        COUNT(DISTINCT warehouse_code) AS warehouses,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(procure_to_order_days) AS avg_procure_to_order_days,
        AVG(order_to_ship_days) AS avg_order_to_ship_days,
        AVG(ship_to_delivery_days) AS avg_ship_to_delivery_days,
        AVG(order_to_delivery_days) AS avg_order_to_delivery_days
    FROM cycle_fact
    GROUP BY delivery_bucket
),
slow_product AS (
    SELECT
        product_name,
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT sales_channel) AS channels,
        COUNT(DISTINCT warehouse_code) AS warehouses,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(procure_to_order_days) AS avg_procure_to_order_days,
        AVG(order_to_ship_days) AS avg_order_to_ship_days,
        AVG(ship_to_delivery_days) AS avg_ship_to_delivery_days,
        AVG(order_to_delivery_days) AS avg_order_to_delivery_days,
        ROW_NUMBER() OVER (ORDER BY SUM(net_sales_proxy) DESC, product_name) AS product_rank_in_slow_bucket
    FROM cycle_fact
    WHERE delivery_bucket = 'slow_21_plus_days'
    GROUP BY product_name
)
SELECT
    'overall_cycle_baseline' AS evidence_block,
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
    channels,
    warehouses,
    ROUND(net_sales_proxy, 4) AS net_sales_proxy,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(avg_procure_to_order_days, 4) AS avg_procure_to_order_days,
    ROUND(avg_order_to_ship_days, 4) AS avg_order_to_ship_days,
    ROUND(avg_ship_to_delivery_days, 4) AS avg_ship_to_delivery_days,
    ROUND(avg_order_to_delivery_days, 4) AS avg_order_to_delivery_days,
    CAST(NULL AS DOUBLE) AS share_pct,
    'Establish end-to-end operating-cycle baseline before diagnosing slow lanes.' AS notes
FROM overall
UNION ALL
SELECT
    'channel_cycle_quality',
    'sales_channel',
    sales_channel,
    CAST(slow_rank AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'slowest_channel_rank',
    CAST(slow_rank AS DOUBLE),
    orders,
    customers,
    stores,
    products,
    CAST(NULL AS BIGINT),
    warehouses,
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(avg_procure_to_order_days, 4),
    ROUND(avg_order_to_ship_days, 4),
    ROUND(avg_ship_to_delivery_days, 4),
    ROUND(avg_order_to_delivery_days, 4),
    CAST(NULL AS DOUBLE),
    'Compare channel cycle length with conversion quality.'
FROM channel_cycle
UNION ALL
SELECT
    'warehouse_cycle_quality',
    'warehouse',
    warehouse_code,
    CAST(slow_rank AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'slowest_warehouse_rank',
    CAST(slow_rank AS DOUBLE),
    orders,
    customers,
    stores,
    products,
    channels,
    CAST(NULL AS BIGINT),
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(avg_procure_to_order_days, 4),
    ROUND(avg_order_to_ship_days, 4),
    ROUND(avg_ship_to_delivery_days, 4),
    ROUND(avg_order_to_delivery_days, 4),
    CAST(NULL AS DOUBLE),
    'Check whether slow fulfillment concentrates in specific warehouses.'
FROM warehouse_cycle
UNION ALL
SELECT
    'region_cycle_quality',
    'store_region',
    store_region,
    CAST(slow_rank AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'slowest_region_rank',
    CAST(slow_rank AS DOUBLE),
    orders,
    customers,
    stores,
    products,
    channels,
    warehouses,
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(avg_procure_to_order_days, 4),
    ROUND(avg_order_to_ship_days, 4),
    ROUND(avg_ship_to_delivery_days, 4),
    ROUND(avg_order_to_delivery_days, 4),
    CAST(NULL AS DOUBLE),
    'Check whether geographic demand also carries different cycle risk.'
FROM region_cycle
UNION ALL
SELECT
    'delivery_bucket_quality',
    'delivery_bucket',
    delivery_bucket,
    CAST(NULL AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'delivery_bucket',
    CAST(NULL AS DOUBLE),
    orders,
    customers,
    stores,
    products,
    channels,
    warehouses,
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(avg_procure_to_order_days, 4),
    ROUND(avg_order_to_ship_days, 4),
    ROUND(avg_ship_to_delivery_days, 4),
    ROUND(avg_order_to_delivery_days, 4),
    CAST(NULL AS DOUBLE),
    'Compare fast, medium, and slow delivery buckets with conversion quality.'
FROM bucket_quality
UNION ALL
SELECT
    'slow_lane_product_mix',
    'slow_delivery_product',
    product_name,
    CAST(product_rank_in_slow_bucket AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'product_rank_in_slow_bucket',
    CAST(product_rank_in_slow_bucket AS DOUBLE),
    orders,
    customers,
    stores,
    CAST(NULL AS BIGINT),
    channels,
    warehouses,
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(avg_procure_to_order_days, 4),
    ROUND(avg_order_to_ship_days, 4),
    ROUND(avg_ship_to_delivery_days, 4),
    ROUND(avg_order_to_delivery_days, 4),
    CAST(NULL AS DOUBLE),
    'Identify products that dominate the slow-delivery revenue pool.'
FROM slow_product
WHERE product_rank_in_slow_bucket <= 10
