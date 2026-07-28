-- task_053_sales_team_portfolio_quality_evidence.sql
-- Draft task-level Evidence SQL for regional_sales.

WITH
sales_fact AS (
    SELECT
        so.OrderNumber,
        so."Sales Channel" AS sales_channel,
        so.WarehouseCode,
        so._SalesTeamID AS sales_team_id,
        st."Sales Team" AS sales_team,
        st.Region AS sales_team_region,
        so._CustomerID AS customer_id,
        c."Customer Names" AS customer_name,
        so._StoreID AS store_id,
        sl.State AS state_name,
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
    LEFT JOIN Sales_Team st ON so._SalesTeamID = st.SalesTeamID
    LEFT JOIN Customers c ON so._CustomerID = c.CustomerID
    LEFT JOIN Store_Locations sl ON so._StoreID = sl.StoreID
    LEFT JOIN Regions r ON sl.StateCode = r.StateCode
    LEFT JOIN Products p ON so._ProductID = p.ProductID
),
team_metrics AS (
    SELECT
        sales_team,
        sales_team_region,
        COUNT(*) AS orders,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT store_id) AS stores,
        COUNT(DISTINCT product_id) AS products,
        COUNT(DISTINCT sales_channel) AS channels,
        COUNT(DISTINCT store_region) AS store_regions,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        AVG(discount_applied) AS avg_discount,
        AVG(delivery_lag_days) AS avg_delivery_days
    FROM sales_fact
    GROUP BY sales_team, sales_team_region
),
ranked_team AS (
    SELECT
        *,
        100.0 * net_sales_proxy / NULLIF(SUM(net_sales_proxy) OVER (), 0) AS sales_share_pct,
        ROW_NUMBER() OVER (ORDER BY net_sales_proxy DESC, sales_team) AS sales_rank,
        ROW_NUMBER() OVER (ORDER BY gross_margin_proxy_rate DESC, sales_team) AS margin_rank
    FROM team_metrics
),
team_customer AS (
    SELECT
        sales_team,
        sales_team_region,
        customer_name,
        COUNT(*) AS orders,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        100.0 * SUM(net_sales_proxy) / NULLIF(SUM(SUM(net_sales_proxy)) OVER (PARTITION BY sales_team), 0) AS team_sales_share_pct,
        ROW_NUMBER() OVER (PARTITION BY sales_team ORDER BY SUM(net_sales_proxy) DESC, customer_name) AS customer_rank_in_team
    FROM sales_fact
    GROUP BY sales_team, sales_team_region, customer_name
),
team_product AS (
    SELECT
        sales_team,
        sales_team_region,
        product_name,
        COUNT(*) AS orders,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        100.0 * SUM(net_sales_proxy) / NULLIF(SUM(SUM(net_sales_proxy)) OVER (PARTITION BY sales_team), 0) AS team_sales_share_pct,
        ROW_NUMBER() OVER (PARTITION BY sales_team ORDER BY SUM(net_sales_proxy) DESC, product_name) AS product_rank_in_team
    FROM sales_fact
    GROUP BY sales_team, sales_team_region, product_name
),
team_channel AS (
    SELECT
        sales_team,
        sales_team_region,
        sales_channel,
        COUNT(*) AS orders,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        ROW_NUMBER() OVER (PARTITION BY sales_team ORDER BY SUM(net_sales_proxy) DESC, sales_channel) AS channel_rank_in_team
    FROM sales_fact
    GROUP BY sales_team, sales_team_region, sales_channel
),
team_region_alignment AS (
    SELECT
        sales_team,
        sales_team_region,
        COALESCE(store_region, 'UNKNOWN') AS store_region,
        COUNT(*) AS orders,
        SUM(net_sales_proxy) AS net_sales_proxy,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(gross_margin_proxy) / NULLIF(SUM(net_sales_proxy), 0) AS gross_margin_proxy_rate,
        ROW_NUMBER() OVER (
            PARTITION BY sales_team
            ORDER BY SUM(net_sales_proxy) DESC, COALESCE(store_region, 'UNKNOWN')
        ) AS store_region_rank_in_team
    FROM sales_fact
    GROUP BY sales_team, sales_team_region, COALESCE(store_region, 'UNKNOWN')
),
team_discount AS (
    SELECT
        sales_team,
        sales_team_region,
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
    GROUP BY sales_team, sales_team_region,
        CASE
            WHEN discount_applied <= 0.075 THEN 'low_discount'
            WHEN discount_applied <= 0.150 THEN 'mid_discount'
            ELSE 'high_discount'
        END
)
SELECT
    'sales_team_performance' AS evidence_block,
    'sales_team' AS grain,
    sales_team AS item,
    sales_team_region AS item_2,
    CAST(margin_rank AS VARCHAR) AS item_3,
    'sales_rank' AS rank_label,
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
    ROUND(avg_delivery_days, 4) AS avg_delivery_days,
    ROUND(sales_share_pct, 4) AS share_pct,
    'Compare sales-team scale with margin proxy, discount, delivery, and breadth.' AS notes
FROM ranked_team
UNION ALL
SELECT
    'team_customer_concentration',
    'sales_team_customer',
    sales_team,
    customer_name,
    CAST(customer_rank_in_team AS VARCHAR),
    'customer_rank_in_team',
    CAST(customer_rank_in_team AS DOUBLE),
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
    ROUND(team_sales_share_pct, 4),
    'Check whether team performance depends on a small number of customers.'
FROM team_customer
WHERE customer_rank_in_team <= 3
UNION ALL
SELECT
    'team_product_mix',
    'sales_team_product',
    sales_team,
    product_name,
    CAST(product_rank_in_team AS VARCHAR),
    'product_rank_in_team',
    CAST(product_rank_in_team AS DOUBLE),
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
    ROUND(team_sales_share_pct, 4),
    'Identify product mix as a possible explanation for team-level quality.'
FROM team_product
WHERE product_rank_in_team <= 3
UNION ALL
SELECT
    'team_channel_mix',
    'sales_team_channel',
    sales_team,
    sales_channel,
    CAST(channel_rank_in_team AS VARCHAR),
    'channel_rank_in_team',
    CAST(channel_rank_in_team AS DOUBLE),
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
    'Check whether team performance is channel-mix dependent.'
FROM team_channel
WHERE channel_rank_in_team <= 3
UNION ALL
SELECT
    'team_region_alignment',
    'sales_team_store_region',
    sales_team,
    sales_team_region,
    store_region,
    'store_region_rank_in_team',
    CAST(store_region_rank_in_team AS DOUBLE),
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
    'Compare sales-team home region with the store regions where revenue is observed.'
FROM team_region_alignment
WHERE store_region_rank_in_team <= 3
UNION ALL
SELECT
    'team_discount_exposure',
    'sales_team_discount_bucket',
    sales_team,
    sales_team_region,
    discount_bucket,
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
    'Check whether team quality differences are tied to discount exposure.'
FROM team_discount
