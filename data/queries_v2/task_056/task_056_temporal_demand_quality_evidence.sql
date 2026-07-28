-- task_056_temporal_demand_quality_evidence.sql
-- Draft task-level Evidence SQL for regional_sales.

WITH
sales_fact AS (
    SELECT
        so.OrderNumber,
        so."Sales Channel" AS sales_channel,
        so.WarehouseCode AS warehouse_code,
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
            * so."Order Quantity" * (1.0 - so."Discount Applied") AS gross_margin_proxy,
        date_diff('day',
            COALESCE(try_strptime(so.OrderDate, '%m/%d/%y'), try_strptime(so.OrderDate, '%m/%d/%Y')),
            COALESCE(try_strptime(so.ShipDate, '%m/%d/%y'), try_strptime(so.ShipDate, '%m/%d/%Y'))
        ) AS order_to_ship_days,
        date_diff('day',
            COALESCE(try_strptime(so.ShipDate, '%m/%d/%y'), try_strptime(so.ShipDate, '%m/%d/%Y')),
            COALESCE(try_strptime(so.DeliveryDate, '%m/%d/%y'), try_strptime(so.DeliveryDate, '%m/%d/%Y'))
        ) AS ship_to_delivery_days,
        date_diff('day',
            COALESCE(try_strptime(so.OrderDate, '%m/%d/%y'), try_strptime(so.OrderDate, '%m/%d/%Y')),
            COALESCE(try_strptime(so.DeliveryDate, '%m/%d/%y'), try_strptime(so.DeliveryDate, '%m/%d/%Y'))
        ) AS order_to_delivery_days
    FROM Sales_Orders so
    LEFT JOIN Store_Locations sl ON so._StoreID = sl.StoreID
    LEFT JOIN Regions r ON sl.StateCode = r.StateCode
    LEFT JOIN Products p ON so._ProductID = p.ProductID
),
fact_with_time AS (
    SELECT
        *,
        strftime(order_date, '%Y-%m') AS order_month,
        CAST(strftime(order_date, '%Y') AS VARCHAR) || '-Q' || CAST(quarter(order_date) AS VARCHAR) AS order_quarter
    FROM sales_fact
),
monthly_metrics AS (
    SELECT
        order_month,
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT product_id) AS products,
        COUNT(DISTINCT sales_channel) AS channels,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount,
        AVG(order_to_ship_days) AS avg_order_to_ship_days,
        AVG(ship_to_delivery_days) AS avg_ship_to_delivery_days,
        AVG(order_to_delivery_days) AS avg_order_to_delivery_days
    FROM fact_with_time
    GROUP BY order_month
),
ranked_month AS (
    SELECT
        *,
        100.0 * net_sales_proxy / NULLIF(SUM(net_sales_proxy) OVER (), 0) AS sales_share_pct,
        ROW_NUMBER() OVER (ORDER BY net_sales_proxy DESC, order_month) AS sales_rank,
        ROW_NUMBER() OVER (ORDER BY gross_margin_proxy_rate DESC, order_month) AS margin_rank
    FROM monthly_metrics
),
quarter_region AS (
    SELECT
        order_quarter,
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
        AVG(order_to_ship_days) AS avg_order_to_ship_days,
        AVG(ship_to_delivery_days) AS avg_ship_to_delivery_days,
        AVG(order_to_delivery_days) AS avg_order_to_delivery_days,
        ROW_NUMBER() OVER (
            PARTITION BY order_quarter
            ORDER BY SUM(net_sales_proxy) DESC, COALESCE(store_region, 'UNKNOWN')
        ) AS region_rank_in_quarter
    FROM fact_with_time
    GROUP BY order_quarter, COALESCE(store_region, 'UNKNOWN')
),
month_channel AS (
    SELECT
        order_month,
        sales_channel,
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT product_id) AS products,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount,
        AVG(order_to_ship_days) AS avg_order_to_ship_days,
        AVG(ship_to_delivery_days) AS avg_ship_to_delivery_days,
        AVG(order_to_delivery_days) AS avg_order_to_delivery_days,
        ROW_NUMBER() OVER (
            PARTITION BY order_month
            ORDER BY SUM(net_sales_proxy) DESC, sales_channel
        ) AS channel_rank_in_month
    FROM fact_with_time
    GROUP BY order_month, sales_channel
),
month_product AS (
    SELECT
        order_month,
        product_name,
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT sales_channel) AS channels,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount,
        AVG(order_to_ship_days) AS avg_order_to_ship_days,
        AVG(ship_to_delivery_days) AS avg_ship_to_delivery_days,
        AVG(order_to_delivery_days) AS avg_order_to_delivery_days,
        ROW_NUMBER() OVER (
            PARTITION BY order_month
            ORDER BY SUM(net_sales_proxy) DESC, product_name
        ) AS product_rank_in_month
    FROM fact_with_time
    GROUP BY order_month, product_name
),
month_discount AS (
    SELECT
        order_month,
        CASE
            WHEN discount_applied <= 0.075 THEN 'low_discount'
            WHEN discount_applied <= 0.150 THEN 'mid_discount'
            ELSE 'high_discount'
        END AS discount_bucket,
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT product_id) AS products,
        COUNT(DISTINCT sales_channel) AS channels,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount,
        AVG(order_to_ship_days) AS avg_order_to_ship_days,
        AVG(ship_to_delivery_days) AS avg_ship_to_delivery_days,
        AVG(order_to_delivery_days) AS avg_order_to_delivery_days
    FROM fact_with_time
    GROUP BY
        order_month,
        CASE
            WHEN discount_applied <= 0.075 THEN 'low_discount'
            WHEN discount_applied <= 0.150 THEN 'mid_discount'
            ELSE 'high_discount'
        END
)
SELECT
    'monthly_demand_quality' AS evidence_block,
    'order_month' AS grain,
    order_month AS item,
    CAST(sales_rank AS VARCHAR) AS item_2,
    CAST(margin_rank AS VARCHAR) AS item_3,
    'month_sales_rank' AS rank_label,
    CAST(sales_rank AS DOUBLE) AS rank_value,
    orders,
    customers,
    stores,
    products,
    channels,
    ROUND(net_sales_proxy, 4) AS net_sales_proxy,
    ROUND(gross_margin_proxy, 4) AS gross_margin_proxy,
    ROUND(100.0 * gross_margin_proxy_rate, 4) AS gross_margin_proxy_rate_pct,
    ROUND(100.0 * avg_discount, 4) AS avg_discount_pct,
    ROUND(avg_order_to_ship_days, 4) AS avg_order_to_ship_days,
    ROUND(avg_ship_to_delivery_days, 4) AS avg_ship_to_delivery_days,
    ROUND(avg_order_to_delivery_days, 4) AS avg_order_to_delivery_days,
    ROUND(sales_share_pct, 4) AS share_pct,
    'Compare demand seasonality with conversion quality and fulfillment timing.' AS notes
FROM ranked_month
UNION ALL
SELECT
    'quarter_region_mix',
    'order_quarter_region',
    order_quarter,
    store_region,
    CAST(region_rank_in_quarter AS VARCHAR),
    'region_rank_in_quarter',
    CAST(region_rank_in_quarter AS DOUBLE),
    orders,
    customers,
    stores,
    products,
    channels,
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(100.0 * avg_discount, 4),
    ROUND(avg_order_to_ship_days, 4),
    ROUND(avg_ship_to_delivery_days, 4),
    ROUND(avg_order_to_delivery_days, 4),
    CAST(NULL AS DOUBLE),
    'Check whether seasonal demand peaks are geographically concentrated.'
FROM quarter_region
WHERE region_rank_in_quarter <= 4
UNION ALL
SELECT
    'monthly_channel_mix',
    'order_month_channel',
    order_month,
    sales_channel,
    CAST(channel_rank_in_month AS VARCHAR),
    'channel_rank_in_month',
    CAST(channel_rank_in_month AS DOUBLE),
    orders,
    customers,
    stores,
    products,
    CAST(NULL AS BIGINT),
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(100.0 * avg_discount, 4),
    ROUND(avg_order_to_ship_days, 4),
    ROUND(avg_ship_to_delivery_days, 4),
    ROUND(avg_order_to_delivery_days, 4),
    CAST(NULL AS DOUBLE),
    'Check whether channel mix shifts across demand months.'
FROM month_channel
WHERE channel_rank_in_month <= 3
UNION ALL
SELECT
    'monthly_product_leaders',
    'order_month_product',
    order_month,
    product_name,
    CAST(product_rank_in_month AS VARCHAR),
    'product_rank_in_month',
    CAST(product_rank_in_month AS DOUBLE),
    orders,
    customers,
    stores,
    CAST(NULL AS BIGINT),
    channels,
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(100.0 * avg_discount, 4),
    ROUND(avg_order_to_ship_days, 4),
    ROUND(avg_ship_to_delivery_days, 4),
    ROUND(avg_order_to_delivery_days, 4),
    CAST(NULL AS DOUBLE),
    'Identify products that drive or explain monthly demand spikes.'
FROM month_product
WHERE product_rank_in_month <= 5
UNION ALL
SELECT
    'monthly_discount_timing',
    'order_month_discount_bucket',
    order_month,
    discount_bucket,
    CAST(NULL AS VARCHAR),
    'discount_bucket',
    CAST(NULL AS DOUBLE),
    orders,
    customers,
    stores,
    products,
    channels,
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(100.0 * avg_discount, 4),
    ROUND(avg_order_to_ship_days, 4),
    ROUND(avg_ship_to_delivery_days, 4),
    ROUND(avg_order_to_delivery_days, 4),
    CAST(NULL AS DOUBLE),
    'Check whether seasonal peaks are supported by discounting or slower fulfillment.'
FROM month_discount
