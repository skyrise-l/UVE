-- task_055_product_customer_portfolio_health_evidence.sql
-- Draft task-level Evidence SQL for regional_sales.

WITH
sales_fact AS (
    SELECT
        so.OrderNumber,
        so."Sales Channel" AS sales_channel,
        so._CustomerID AS customer_id,
        c."Customer Names" AS customer_name,
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
        ) AS delivery_lag_days
    FROM Sales_Orders so
    LEFT JOIN Customers c ON so._CustomerID = c.CustomerID
    LEFT JOIN Products p ON so._ProductID = p.ProductID
    LEFT JOIN Store_Locations sl ON so._StoreID = sl.StoreID
    LEFT JOIN Regions r ON sl.StateCode = r.StateCode
),
product_metrics AS (
    SELECT
        product_name,
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT sales_channel) AS channels,
        SUM(order_quantity) AS units,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount,
        AVG(delivery_lag_days) AS avg_delivery_days
    FROM sales_fact
    GROUP BY product_name
),
ranked_product AS (
    SELECT
        *,
        100.0 * net_sales_proxy / NULLIF(SUM(net_sales_proxy) OVER (), 0) AS sales_share_pct,
        ROW_NUMBER() OVER (ORDER BY net_sales_proxy DESC, product_name) AS sales_rank,
        ROW_NUMBER() OVER (ORDER BY gross_margin_proxy_rate DESC, product_name) AS margin_rank
    FROM product_metrics
),
top_product_concentration AS (
    SELECT
        SUM(CASE WHEN sales_rank <= 10 THEN net_sales_proxy ELSE 0 END) AS top10_sales,
        SUM(net_sales_proxy) AS all_sales,
        COUNT(*) AS product_count
    FROM ranked_product
),
product_channel AS (
    SELECT
        product_name,
        sales_channel,
        COUNT(*) AS orders,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        ROW_NUMBER() OVER (PARTITION BY product_name ORDER BY SUM(net_sales_proxy) DESC, sales_channel) AS channel_rank_in_product
    FROM sales_fact
    GROUP BY product_name, sales_channel
),
product_region AS (
    SELECT
        product_name,
        COALESCE(store_region, 'UNKNOWN') AS store_region,
        COUNT(*) AS orders,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        ROW_NUMBER() OVER (PARTITION BY product_name ORDER BY SUM(net_sales_proxy) DESC, COALESCE(store_region, 'UNKNOWN')) AS region_rank_in_product
    FROM sales_fact
    GROUP BY product_name, COALESCE(store_region, 'UNKNOWN')
),
customer_metrics AS (
    SELECT
        customer_name,
        COUNT(*) AS orders,
        COUNT(DISTINCT product_id) AS products,
        COUNT(DISTINCT store_region) AS store_regions,
        COUNT(DISTINCT sales_channel) AS channels,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount,
        AVG(delivery_lag_days) AS avg_delivery_days
    FROM sales_fact
    GROUP BY customer_name
),
ranked_customer AS (
    SELECT
        *,
        100.0 * net_sales_proxy / NULLIF(SUM(net_sales_proxy) OVER (), 0) AS sales_share_pct,
        ROW_NUMBER() OVER (ORDER BY net_sales_proxy DESC, customer_name) AS sales_rank,
        ROW_NUMBER() OVER (ORDER BY gross_margin_proxy_rate DESC, customer_name) AS margin_rank
    FROM customer_metrics
),
top_customer_concentration AS (
    SELECT
        SUM(CASE WHEN sales_rank <= 10 THEN net_sales_proxy ELSE 0 END) AS top10_sales,
        SUM(net_sales_proxy) AS all_sales,
        COUNT(*) AS customer_count
    FROM ranked_customer
),
customer_product AS (
    SELECT
        customer_name,
        product_name,
        COUNT(*) AS orders,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        100.0 * SUM(net_sales_proxy) / NULLIF(SUM(SUM(net_sales_proxy)) OVER (PARTITION BY customer_name), 0) AS customer_sales_share_pct,
        ROW_NUMBER() OVER (PARTITION BY customer_name ORDER BY SUM(net_sales_proxy) DESC, product_name) AS product_rank_in_customer
    FROM sales_fact
    GROUP BY customer_name, product_name
)
SELECT
    'product_sales_concentration' AS evidence_block,
    'portfolio' AS grain,
    'top_10_products_by_sales' AS item,
    CAST(product_count AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'top10_product_sales_share' AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS orders,
    CAST(NULL AS BIGINT) AS customers,
    CAST(NULL AS BIGINT) AS stores,
    product_count AS products,
    CAST(NULL AS BIGINT) AS channels,
    ROUND(top10_sales, 4) AS net_sales_proxy,
    CAST(NULL AS DOUBLE) AS gross_margin_proxy,
    CAST(NULL AS DOUBLE) AS gross_margin_proxy_rate_pct,
    CAST(NULL AS DOUBLE) AS avg_discount_pct,
    CAST(NULL AS DOUBLE) AS avg_delivery_days,
    ROUND(100.0 * top10_sales / NULLIF(all_sales, 0), 4) AS share_pct,
    'Check whether product demand is broad or top-heavy.' AS notes
FROM top_product_concentration
UNION ALL
SELECT
    'product_performance_baseline',
    'product',
    product_name,
    CAST(sales_rank AS VARCHAR),
    CAST(margin_rank AS VARCHAR),
    'product_sales_rank',
    CAST(sales_rank AS DOUBLE),
    orders,
    customers,
    stores,
    CAST(NULL AS BIGINT),
    channels,
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(100.0 * avg_discount, 4),
    ROUND(avg_delivery_days, 4),
    ROUND(sales_share_pct, 4),
    'Compare product demand scale with margin proxy quality, discount, and breadth.'
FROM ranked_product
UNION ALL
SELECT
    'product_channel_mix',
    'product_channel',
    product_name,
    sales_channel,
    CAST(channel_rank_in_product AS VARCHAR),
    'channel_rank_in_product',
    CAST(channel_rank_in_product AS DOUBLE),
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
    'Check whether product performance is tied to specific sales channels.'
FROM product_channel
WHERE channel_rank_in_product <= 3
UNION ALL
SELECT
    'product_region_mix',
    'product_region',
    product_name,
    store_region,
    CAST(region_rank_in_product AS VARCHAR),
    'region_rank_in_product',
    CAST(region_rank_in_product AS DOUBLE),
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
    'Check whether product strength is geographically broad or localized.'
FROM product_region
WHERE region_rank_in_product <= 3
UNION ALL
SELECT
    'customer_sales_concentration',
    'portfolio',
    'top_10_customers_by_sales',
    CAST(customer_count AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'top10_customer_sales_share',
    CAST(NULL AS DOUBLE),
    CAST(NULL AS BIGINT),
    customer_count,
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    ROUND(top10_sales, 4),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    ROUND(100.0 * top10_sales / NULLIF(all_sales, 0), 4),
    'Check whether customer value is concentrated in a small head.'
FROM top_customer_concentration
UNION ALL
SELECT
    'customer_value_breadth',
    'customer',
    customer_name,
    CAST(sales_rank AS VARCHAR),
    CAST(margin_rank AS VARCHAR),
    'customer_sales_rank',
    CAST(sales_rank AS DOUBLE),
    orders,
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    products,
    channels,
    ROUND(net_sales_proxy, 4),
    ROUND(gross_margin_proxy, 4),
    ROUND(100.0 * gross_margin_proxy_rate, 4),
    ROUND(100.0 * avg_discount, 4),
    ROUND(avg_delivery_days, 4),
    ROUND(sales_share_pct, 4),
    'Compare customer value with product breadth, channel breadth, and quality signals.'
FROM ranked_customer
UNION ALL
SELECT
    'customer_product_preference',
    'customer_product',
    customer_name,
    product_name,
    CAST(product_rank_in_customer AS VARCHAR),
    'product_rank_in_customer',
    CAST(product_rank_in_customer AS DOUBLE),
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
    ROUND(customer_sales_share_pct, 4),
    'Check whether high-value customers are broad buyers or concentrated around one product.'
FROM customer_product
WHERE product_rank_in_customer <= 3
