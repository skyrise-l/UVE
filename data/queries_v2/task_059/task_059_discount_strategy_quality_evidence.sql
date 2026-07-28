-- task_059_discount_strategy_quality_evidence.sql
-- Draft task-level Evidence SQL for regional_sales.

WITH
sales_fact AS (
    SELECT
        so.OrderNumber,
        so."Sales Channel" AS sales_channel,
        so.WarehouseCode AS warehouse_code,
        so._CustomerID AS customer_id,
        c."Customer Names" AS customer_name,
        so._StoreID AS store_id,
        r.Region AS store_region,
        so._ProductID AS product_id,
        p."Product Name" AS product_name,
        so."Order Quantity" AS order_quantity,
        so."Discount Applied" AS discount_applied,
        CASE
            WHEN so."Discount Applied" <= 0.075 THEN 'low_discount'
            WHEN so."Discount Applied" <= 0.150 THEN 'mid_discount'
            ELSE 'high_discount'
        END AS discount_bucket,
        CAST(REPLACE(so."Unit Price", ',', '') AS DOUBLE) * so."Order Quantity" * (1.0 - so."Discount Applied") AS net_sales_proxy,
        (CAST(REPLACE(so."Unit Price", ',', '') AS DOUBLE) - CAST(REPLACE(so."Unit Cost", ',', '') AS DOUBLE))
            * so."Order Quantity" * (1.0 - so."Discount Applied") AS gross_margin_proxy,
        date_diff('day',
            COALESCE(try_strptime(so.OrderDate, '%m/%d/%y'), try_strptime(so.OrderDate, '%m/%d/%Y')),
            COALESCE(try_strptime(so.DeliveryDate, '%m/%d/%y'), try_strptime(so.DeliveryDate, '%m/%d/%Y'))
        ) AS order_to_delivery_days
    FROM Sales_Orders so
    LEFT JOIN Customers c ON so._CustomerID = c.CustomerID
    LEFT JOIN Products p ON so._ProductID = p.ProductID
    LEFT JOIN Store_Locations sl ON so._StoreID = sl.StoreID
    LEFT JOIN Regions r ON sl.StateCode = r.StateCode
),
discount_baseline AS (
    SELECT
        discount_bucket,
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT product_id) AS products,
        COUNT(DISTINCT sales_channel) AS channels,
        COUNT(DISTINCT warehouse_code) AS warehouses,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount,
        AVG(order_to_delivery_days) AS avg_delivery_days
    FROM sales_fact
    GROUP BY discount_bucket
),
product_discount AS (
    SELECT
        product_name,
        discount_bucket,
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT sales_channel) AS channels,
        COUNT(DISTINCT warehouse_code) AS warehouses,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount,
        AVG(order_to_delivery_days) AS avg_delivery_days,
        ROW_NUMBER() OVER (
            PARTITION BY discount_bucket
            ORDER BY SUM(net_sales_proxy) DESC, product_name
        ) AS product_rank_in_discount_bucket
    FROM sales_fact
    GROUP BY product_name, discount_bucket
),
customer_discount AS (
    SELECT
        customer_name,
        discount_bucket,
        COUNT(*) AS orders,
        COUNT(DISTINCT product_id) AS products,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT sales_channel) AS channels,
        COUNT(DISTINCT warehouse_code) AS warehouses,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount,
        AVG(order_to_delivery_days) AS avg_delivery_days,
        ROW_NUMBER() OVER (
            PARTITION BY discount_bucket
            ORDER BY SUM(net_sales_proxy) DESC, customer_name
        ) AS customer_rank_in_discount_bucket
    FROM sales_fact
    GROUP BY customer_name, discount_bucket
),
channel_discount AS (
    SELECT
        sales_channel,
        discount_bucket,
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT product_id) AS products,
        COUNT(DISTINCT warehouse_code) AS warehouses,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount,
        AVG(order_to_delivery_days) AS avg_delivery_days
    FROM sales_fact
    GROUP BY sales_channel, discount_bucket
),
region_discount AS (
    SELECT
        COALESCE(store_region, 'UNKNOWN') AS store_region,
        discount_bucket,
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT product_id) AS products,
        COUNT(DISTINCT sales_channel) AS channels,
        COUNT(DISTINCT warehouse_code) AS warehouses,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount,
        AVG(order_to_delivery_days) AS avg_delivery_days
    FROM sales_fact
    GROUP BY COALESCE(store_region, 'UNKNOWN'), discount_bucket
),
high_discount_pair AS (
    SELECT
        customer_name,
        product_name,
        COUNT(*) AS orders,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT sales_channel) AS channels,
        COUNT(DISTINCT warehouse_code) AS warehouses,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount,
        AVG(order_to_delivery_days) AS avg_delivery_days,
        ROW_NUMBER() OVER (ORDER BY SUM(net_sales_proxy) DESC, customer_name, product_name) AS pair_rank
    FROM sales_fact
    WHERE discount_bucket = 'high_discount'
    GROUP BY customer_name, product_name
)
SELECT
    'discount_bucket_baseline' AS evidence_block,
    'discount_bucket' AS grain,
    discount_bucket AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'discount_bucket' AS rank_label,
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
    ROUND(100.0 * avg_discount, 4) AS avg_discount_pct,
    ROUND(avg_delivery_days, 4) AS avg_delivery_days,
    CAST(NULL AS DOUBLE) AS share_pct,
    'Establish whether discount tiers differ in scale, breadth, and conversion quality.' AS notes
FROM discount_baseline
UNION ALL
SELECT
    'product_discount_pockets',
    'discount_product',
    discount_bucket,
    product_name,
    CAST(product_rank_in_discount_bucket AS VARCHAR),
    'product_rank_in_discount_bucket',
    CAST(product_rank_in_discount_bucket AS DOUBLE),
    orders,
    customers,
    stores,
    CAST(NULL AS BIGINT),
    channels,
    warehouses,
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(100.0 * avg_discount, 4),
    ROUND(avg_delivery_days, 4),
    CAST(NULL AS DOUBLE),
    'Identify products that dominate each discount tier.'
FROM product_discount
WHERE product_rank_in_discount_bucket <= 8
UNION ALL
SELECT
    'customer_discount_pockets',
    'discount_customer',
    discount_bucket,
    customer_name,
    CAST(customer_rank_in_discount_bucket AS VARCHAR),
    'customer_rank_in_discount_bucket',
    CAST(customer_rank_in_discount_bucket AS DOUBLE),
    orders,
    CAST(NULL AS BIGINT),
    stores,
    products,
    channels,
    warehouses,
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(100.0 * avg_discount, 4),
    ROUND(avg_delivery_days, 4),
    CAST(NULL AS DOUBLE),
    'Identify customers that dominate each discount tier.'
FROM customer_discount
WHERE customer_rank_in_discount_bucket <= 8
UNION ALL
SELECT
    'channel_discount_quality',
    'channel_discount_bucket',
    sales_channel,
    discount_bucket,
    CAST(NULL AS VARCHAR),
    'discount_bucket',
    CAST(NULL AS DOUBLE),
    orders,
    customers,
    stores,
    products,
    CAST(NULL AS BIGINT),
    warehouses,
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(100.0 * avg_discount, 4),
    ROUND(avg_delivery_days, 4),
    CAST(NULL AS DOUBLE),
    'Check whether discount quality differs by sales channel.'
FROM channel_discount
UNION ALL
SELECT
    'region_discount_quality',
    'region_discount_bucket',
    store_region,
    discount_bucket,
    CAST(NULL AS VARCHAR),
    'discount_bucket',
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
    ROUND(100.0 * avg_discount, 4),
    ROUND(avg_delivery_days, 4),
    CAST(NULL AS DOUBLE),
    'Check whether discount quality differs by store region.'
FROM region_discount
UNION ALL
SELECT
    'high_discount_customer_product_pockets',
    'customer_product_high_discount',
    customer_name,
    product_name,
    CAST(pair_rank AS VARCHAR),
    'pair_rank_in_high_discount',
    CAST(pair_rank AS DOUBLE),
    orders,
    CAST(NULL AS BIGINT),
    stores,
    CAST(NULL AS BIGINT),
    channels,
    warehouses,
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(100.0 * avg_discount, 4),
    ROUND(avg_delivery_days, 4),
    CAST(NULL AS DOUBLE),
    'Find high-discount customer-product pockets that may need separate interpretation.'
FROM high_discount_pair
WHERE pair_rank <= 20
