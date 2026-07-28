-- task_060_order_size_quality_evidence.sql
-- Draft task-level Evidence SQL for regional_sales.

WITH
sales_fact AS (
    SELECT
        so.OrderNumber,
        so."Sales Channel" AS sales_channel,
        so.WarehouseCode AS warehouse_code,
        st."Sales Team" AS sales_team,
        st.Region AS sales_team_region,
        so._CustomerID AS customer_id,
        c."Customer Names" AS customer_name,
        so._StoreID AS store_id,
        r.Region AS store_region,
        so._ProductID AS product_id,
        p."Product Name" AS product_name,
        so."Order Quantity" AS order_quantity,
        CASE
            WHEN so."Order Quantity" <= 2 THEN 'small_1_2_units'
            WHEN so."Order Quantity" <= 5 THEN 'medium_3_5_units'
            ELSE 'large_6_8_units'
        END AS quantity_bucket,
        so."Discount Applied" AS discount_applied,
        CAST(REPLACE(so."Unit Price", ',', '') AS DOUBLE) AS unit_price,
        CAST(REPLACE(so."Unit Cost", ',', '') AS DOUBLE) AS unit_cost,
        CAST(REPLACE(so."Unit Price", ',', '') AS DOUBLE) * so."Order Quantity" * (1.0 - so."Discount Applied") AS net_sales_proxy,
        (CAST(REPLACE(so."Unit Price", ',', '') AS DOUBLE) - CAST(REPLACE(so."Unit Cost", ',', '') AS DOUBLE))
            * so."Order Quantity" * (1.0 - so."Discount Applied") AS gross_margin_proxy,
        date_diff('day',
            COALESCE(try_strptime(so.OrderDate, '%m/%d/%y'), try_strptime(so.OrderDate, '%m/%d/%Y')),
            COALESCE(try_strptime(so.DeliveryDate, '%m/%d/%y'), try_strptime(so.DeliveryDate, '%m/%d/%Y'))
        ) AS order_to_delivery_days
    FROM Sales_Orders so
    LEFT JOIN Sales_Team st ON so._SalesTeamID = st.SalesTeamID
    LEFT JOIN Customers c ON so._CustomerID = c.CustomerID
    LEFT JOIN Products p ON so._ProductID = p.ProductID
    LEFT JOIN Store_Locations sl ON so._StoreID = sl.StoreID
    LEFT JOIN Regions r ON sl.StateCode = r.StateCode
),
quantity_bucket_metrics AS (
    SELECT
        quantity_bucket,
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT product_id) AS products,
        COUNT(DISTINCT sales_channel) AS channels,
        COUNT(DISTINCT warehouse_code) AS warehouses,
        COUNT(DISTINCT sales_team) AS sales_teams,
        SUM(order_quantity) AS units,
        AVG(unit_price) AS avg_unit_price,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount,
        AVG(order_to_delivery_days) AS avg_delivery_days
    FROM sales_fact
    GROUP BY quantity_bucket
),
large_order_region_channel AS (
    SELECT
        COALESCE(store_region, 'UNKNOWN') AS store_region,
        sales_channel,
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT product_id) AS products,
        COUNT(DISTINCT warehouse_code) AS warehouses,
        COUNT(DISTINCT sales_team) AS sales_teams,
        SUM(order_quantity) AS units,
        AVG(unit_price) AS avg_unit_price,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount,
        AVG(order_to_delivery_days) AS avg_delivery_days,
        ROW_NUMBER() OVER (
            ORDER BY SUM(net_sales_proxy) DESC, COALESCE(store_region, 'UNKNOWN'), sales_channel
        ) AS lane_rank
    FROM sales_fact
    WHERE quantity_bucket = 'large_6_8_units'
    GROUP BY COALESCE(store_region, 'UNKNOWN'), sales_channel
),
large_order_product AS (
    SELECT
        product_name,
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT sales_channel) AS channels,
        COUNT(DISTINCT warehouse_code) AS warehouses,
        COUNT(DISTINCT sales_team) AS sales_teams,
        SUM(order_quantity) AS units,
        AVG(unit_price) AS avg_unit_price,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount,
        AVG(order_to_delivery_days) AS avg_delivery_days,
        ROW_NUMBER() OVER (ORDER BY SUM(net_sales_proxy) DESC, product_name) AS product_rank_in_large_orders
    FROM sales_fact
    WHERE quantity_bucket = 'large_6_8_units'
    GROUP BY product_name
),
large_order_customer AS (
    SELECT
        customer_name,
        COUNT(*) AS orders,
        COUNT(DISTINCT product_id) AS products,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT sales_channel) AS channels,
        COUNT(DISTINCT warehouse_code) AS warehouses,
        COUNT(DISTINCT sales_team) AS sales_teams,
        SUM(order_quantity) AS units,
        AVG(unit_price) AS avg_unit_price,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount,
        AVG(order_to_delivery_days) AS avg_delivery_days,
        ROW_NUMBER() OVER (ORDER BY SUM(net_sales_proxy) DESC, customer_name) AS customer_rank_in_large_orders
    FROM sales_fact
    WHERE quantity_bucket = 'large_6_8_units'
    GROUP BY customer_name
),
large_order_team AS (
    SELECT
        sales_team,
        sales_team_region,
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT product_id) AS products,
        COUNT(DISTINCT sales_channel) AS channels,
        COUNT(DISTINCT warehouse_code) AS warehouses,
        SUM(order_quantity) AS units,
        AVG(unit_price) AS avg_unit_price,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount,
        AVG(order_to_delivery_days) AS avg_delivery_days,
        ROW_NUMBER() OVER (ORDER BY SUM(net_sales_proxy) DESC, sales_team) AS team_rank_in_large_orders
    FROM sales_fact
    WHERE quantity_bucket = 'large_6_8_units'
    GROUP BY sales_team, sales_team_region
),
quantity_price_band AS (
    SELECT
        quantity_bucket,
        CASE
            WHEN unit_price < 1000 THEN 'lower_unit_price'
            WHEN unit_price < 2500 THEN 'mid_unit_price'
            ELSE 'higher_unit_price'
        END AS unit_price_band,
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT product_id) AS products,
        COUNT(DISTINCT sales_channel) AS channels,
        COUNT(DISTINCT warehouse_code) AS warehouses,
        COUNT(DISTINCT sales_team) AS sales_teams,
        SUM(order_quantity) AS units,
        AVG(unit_price) AS avg_unit_price,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount,
        AVG(order_to_delivery_days) AS avg_delivery_days
    FROM sales_fact
    GROUP BY
        quantity_bucket,
        CASE
            WHEN unit_price < 1000 THEN 'lower_unit_price'
            WHEN unit_price < 2500 THEN 'mid_unit_price'
            ELSE 'higher_unit_price'
        END
)
SELECT
    'quantity_bucket_quality' AS evidence_block,
    'quantity_bucket' AS grain,
    quantity_bucket AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'quantity_bucket' AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    orders,
    customers,
    stores,
    products,
    channels,
    warehouses,
    sales_teams,
    units,
    ROUND(avg_unit_price, 4) AS avg_unit_price,
    ROUND(net_sales_proxy, 4) AS net_sales_proxy,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(100.0 * avg_discount, 4) AS avg_discount_pct,
    ROUND(avg_delivery_days, 4) AS avg_delivery_days,
    CAST(NULL AS DOUBLE) AS share_pct,
    'Compare order-size buckets by demand scale, breadth, conversion quality, and fulfillment.' AS notes
FROM quantity_bucket_metrics
UNION ALL
SELECT
    'large_order_region_channel_mix',
    'large_order_region_channel',
    store_region,
    sales_channel,
    CAST(lane_rank AS VARCHAR),
    'lane_rank_in_large_orders',
    CAST(lane_rank AS DOUBLE),
    orders,
    customers,
    stores,
    products,
    CAST(NULL AS BIGINT),
    warehouses,
    sales_teams,
    units,
    ROUND(avg_unit_price, 4),
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(100.0 * avg_discount, 4),
    ROUND(avg_delivery_days, 4),
    CAST(NULL AS DOUBLE),
    'Identify region-channel lanes that dominate large-order demand.'
FROM large_order_region_channel
WHERE lane_rank <= 12
UNION ALL
SELECT
    'large_order_product_mix',
    'large_order_product',
    product_name,
    CAST(product_rank_in_large_orders AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'product_rank_in_large_orders',
    CAST(product_rank_in_large_orders AS DOUBLE),
    orders,
    customers,
    stores,
    CAST(NULL AS BIGINT),
    channels,
    warehouses,
    sales_teams,
    units,
    ROUND(avg_unit_price, 4),
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(100.0 * avg_discount, 4),
    ROUND(avg_delivery_days, 4),
    CAST(NULL AS DOUBLE),
    'Check which products explain large-order demand.'
FROM large_order_product
WHERE product_rank_in_large_orders <= 10
UNION ALL
SELECT
    'large_order_customer_mix',
    'large_order_customer',
    customer_name,
    CAST(customer_rank_in_large_orders AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'customer_rank_in_large_orders',
    CAST(customer_rank_in_large_orders AS DOUBLE),
    orders,
    CAST(NULL AS BIGINT),
    stores,
    products,
    channels,
    warehouses,
    sales_teams,
    units,
    ROUND(avg_unit_price, 4),
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(100.0 * avg_discount, 4),
    ROUND(avg_delivery_days, 4),
    CAST(NULL AS DOUBLE),
    'Check whether large orders are customer-concentrated or broadly distributed.'
FROM large_order_customer
WHERE customer_rank_in_large_orders <= 10
UNION ALL
SELECT
    'large_order_team_mix',
    'large_order_sales_team',
    sales_team,
    sales_team_region,
    CAST(team_rank_in_large_orders AS VARCHAR),
    'team_rank_in_large_orders',
    CAST(team_rank_in_large_orders AS DOUBLE),
    orders,
    customers,
    stores,
    products,
    channels,
    warehouses,
    CAST(NULL AS BIGINT),
    units,
    ROUND(avg_unit_price, 4),
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(100.0 * avg_discount, 4),
    ROUND(avg_delivery_days, 4),
    CAST(NULL AS DOUBLE),
    'Check whether large-order performance is concentrated in specific teams.'
FROM large_order_team
WHERE team_rank_in_large_orders <= 10
UNION ALL
SELECT
    'quantity_price_band_quality',
    'quantity_price_band',
    quantity_bucket,
    unit_price_band,
    CAST(NULL AS VARCHAR),
    'unit_price_band',
    CAST(NULL AS DOUBLE),
    orders,
    customers,
    stores,
    products,
    channels,
    warehouses,
    sales_teams,
    units,
    ROUND(avg_unit_price, 4),
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(100.0 * avg_discount, 4),
    ROUND(avg_delivery_days, 4),
    CAST(NULL AS DOUBLE),
    'Test whether large-order quality is tied to unit-price bands.'
FROM quantity_price_band
