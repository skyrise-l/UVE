-- task_017_customer_lifecycle_repurchase_quality_evidence.sql
-- Evidence SQL for task_017.
-- Public query: Do repeat customers become better customers, or do they mainly increase scale without improving payment and gross-margin quality?
-- Note: payments join only at customer level; this SQL does not infer payment timing for individual orders.

WITH
order_fact AS (
    SELECT
        o.orderNumber,
        o.customerNumber,
        c.customerName,
        c.country,
        c.city,
        c.salesRepEmployeeNumber,
        c.creditLimit,
        o.orderDate,
        od.productCode,
        p.productLine,
        od.quantityOrdered,
        od.priceEach,
        p.buyPrice,
        od.quantityOrdered * od.priceEach AS revenue,
        od.quantityOrdered * (od.priceEach - p.buyPrice) AS gross_margin_proxy
    FROM orders AS o
    JOIN customers AS c
      ON o.customerNumber = c.customerNumber
    JOIN orderdetails AS od
      ON o.orderNumber = od.orderNumber
    JOIN products AS p
      ON od.productCode = p.productCode
),
customer_orders AS (
    SELECT
        c.customerNumber,
        c.customerName,
        c.country,
        c.city,
        c.salesRepEmployeeNumber,
        c.creditLimit,
        MIN(ofa.orderDate) AS first_order_date,
        MAX(ofa.orderDate) AS last_order_date,
        COUNT(DISTINCT ofa.orderNumber) AS orders,
        COUNT(ofa.productCode) AS order_lines,
        COUNT(DISTINCT ofa.productCode) AS products,
        COUNT(DISTINCT ofa.productLine) AS product_lines,
        COALESCE(SUM(ofa.revenue), 0) AS revenue,
        COALESCE(SUM(ofa.gross_margin_proxy), 0) AS gross_margin_proxy
    FROM customers AS c
    LEFT JOIN order_fact AS ofa
      ON c.customerNumber = ofa.customerNumber
    GROUP BY c.customerNumber, c.customerName, c.country, c.city, c.salesRepEmployeeNumber, c.creditLimit
),
customer_payments AS (
    SELECT
        customerNumber,
        COUNT(*) AS payment_count,
        SUM(amount) AS payment_amount,
        MIN(paymentDate) AS first_payment_date,
        MAX(paymentDate) AS last_payment_date
    FROM payments
    GROUP BY customerNumber
),
customer_value AS (
    SELECT
        co.*,
        COALESCE(cp.payment_count, 0) AS payment_count,
        COALESCE(cp.payment_amount, 0) AS payment_amount,
        co.gross_margin_proxy / NULLIF(co.revenue, 0) AS gross_margin_rate,
        COALESCE(cp.payment_amount, 0) / NULLIF(co.revenue, 0) AS payment_coverage,
        co.revenue / NULLIF(co.creditLimit, 0) AS credit_utilization_proxy,
        CASE
            WHEN co.orders = 0 THEN 'no_observed_orders'
            WHEN co.orders = 1 THEN 'one_order'
            WHEN co.orders = 2 THEN 'two_orders'
            WHEN co.orders BETWEEN 3 AND 4 THEN 'three_to_four_orders'
            ELSE 'five_plus_orders'
        END AS order_count_bucket,
        CASE WHEN co.first_order_date IS NULL THEN 'no_observed_orders' ELSE CAST(EXTRACT(year FROM co.first_order_date) AS VARCHAR) END AS first_order_year,
        ROW_NUMBER() OVER (ORDER BY co.revenue DESC, co.customerName) AS revenue_rank,
        ROW_NUMBER() OVER (ORDER BY co.orders DESC, co.revenue DESC, co.customerName) AS repeat_rank,
        ROW_NUMBER() OVER (ORDER BY COALESCE(cp.payment_amount, 0) / NULLIF(co.revenue, 0) ASC NULLS LAST, co.revenue DESC) AS low_coverage_rank
    FROM customer_orders AS co
    LEFT JOIN customer_payments AS cp
      ON co.customerNumber = cp.customerNumber
),
lifecycle_bucket AS (
    SELECT
        order_count_bucket,
        COUNT(*) AS customers,
        SUM(orders) AS orders,
        SUM(order_lines) AS order_lines,
        SUM(products) AS products,
        SUM(product_lines) AS product_lines,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(payment_amount) AS payment_amount,
        SUM(creditLimit) AS credit_limit,
        AVG(orders) AS avg_orders_per_customer,
        ROW_NUMBER() OVER (ORDER BY SUM(revenue) DESC, order_count_bucket) AS revenue_rank
    FROM customer_value
    GROUP BY order_count_bucket
),
cohort_year AS (
    SELECT
        first_order_year,
        COUNT(*) AS customers,
        SUM(orders) AS orders,
        SUM(order_lines) AS order_lines,
        SUM(products) AS products,
        SUM(product_lines) AS product_lines,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(payment_amount) AS payment_amount,
        SUM(creditLimit) AS credit_limit,
        AVG(orders) AS avg_orders_per_customer,
        ROW_NUMBER() OVER (ORDER BY SUM(revenue) DESC, first_order_year) AS revenue_rank
    FROM customer_value
    GROUP BY first_order_year
),
country_repeat AS (
    SELECT
        country,
        COUNT(*) AS customers,
        SUM(CASE WHEN orders > 1 THEN 1 ELSE 0 END) AS repeat_customers,
        SUM(orders) AS orders,
        SUM(order_lines) AS order_lines,
        SUM(products) AS products,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(payment_amount) AS payment_amount,
        SUM(creditLimit) AS credit_limit,
        AVG(orders) AS avg_orders_per_customer,
        ROW_NUMBER() OVER (ORDER BY SUM(revenue) DESC, country) AS revenue_rank
    FROM customer_value
    GROUP BY country
),
rep_repeat AS (
    SELECT
        COALESCE(e.firstName || ' ' || e.lastName, 'No assigned sales rep') AS sales_rep,
        COUNT(*) AS customers,
        SUM(CASE WHEN cv.orders > 1 THEN 1 ELSE 0 END) AS repeat_customers,
        SUM(cv.orders) AS orders,
        SUM(cv.order_lines) AS order_lines,
        SUM(cv.products) AS products,
        SUM(cv.revenue) AS revenue,
        SUM(cv.gross_margin_proxy) AS gross_margin_proxy,
        SUM(cv.payment_amount) AS payment_amount,
        SUM(cv.creditLimit) AS credit_limit,
        AVG(cv.orders) AS avg_orders_per_customer,
        ROW_NUMBER() OVER (ORDER BY SUM(cv.revenue) DESC, COALESCE(e.firstName || ' ' || e.lastName, 'No assigned sales rep')) AS revenue_rank
    FROM customer_value AS cv
    LEFT JOIN employees AS e
      ON cv.salesRepEmployeeNumber = e.employeeNumber
    GROUP BY sales_rep
)
SELECT
    'repeat_lifecycle_bucket_summary' AS evidence_block,
    'order_count_bucket' AS grain,
    order_count_bucket AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    'bucket_revenue_rank' AS rank_label,
    CAST(revenue_rank AS DOUBLE) AS rank_value,
    CAST(customers AS BIGINT) AS customers,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(products AS BIGINT) AS products,
    CAST(product_lines AS BIGINT) AS product_lines,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(payment_amount, 2) AS payment_amount,
    ROUND(payment_amount / NULLIF(revenue, 0), 4) AS payment_coverage,
    ROUND(credit_limit, 2) AS credit_limit,
    ROUND(revenue / NULLIF(credit_limit, 0), 4) AS credit_utilization_proxy,
    ROUND(avg_orders_per_customer, 4) AS avg_orders_per_customer,
    ROUND(revenue / NULLIF(SUM(revenue) OVER (), 0), 4) AS share_value,
    'revenue_share' AS share_label,
    'Compare order-frequency buckets before assuming repeat behavior improves customer quality.' AS notes
FROM lifecycle_bucket
UNION ALL
SELECT
    'first_order_cohort_summary' AS evidence_block,
    'first_order_year' AS grain,
    first_order_year AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    'cohort_revenue_rank' AS rank_label,
    CAST(revenue_rank AS DOUBLE) AS rank_value,
    CAST(customers AS BIGINT) AS customers,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(products AS BIGINT) AS products,
    CAST(product_lines AS BIGINT) AS product_lines,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(payment_amount, 2) AS payment_amount,
    ROUND(payment_amount / NULLIF(revenue, 0), 4) AS payment_coverage,
    ROUND(credit_limit, 2) AS credit_limit,
    ROUND(revenue / NULLIF(credit_limit, 0), 4) AS credit_utilization_proxy,
    ROUND(avg_orders_per_customer, 4) AS avg_orders_per_customer,
    ROUND(revenue / NULLIF(SUM(revenue) OVER (), 0), 4) AS share_value,
    'revenue_share' AS share_label,
    'First-order cohort helps separate older customer accumulation from current quality.' AS notes
FROM cohort_year
UNION ALL
SELECT
    'repeat_customer_examples' AS evidence_block,
    'customer' AS grain,
    customerName AS item,
    country AS item_2,
    CASE WHEN repeat_rank <= 20 THEN 'repeat_rank' ELSE 'low_coverage_rank' END AS rank_label,
    CAST(CASE WHEN repeat_rank <= 20 THEN repeat_rank ELSE low_coverage_rank END AS DOUBLE) AS rank_value,
    CAST(1 AS BIGINT) AS customers,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(products AS BIGINT) AS products,
    CAST(product_lines AS BIGINT) AS product_lines,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_rate, 4) AS gross_margin_rate,
    ROUND(payment_amount, 2) AS payment_amount,
    ROUND(payment_coverage, 4) AS payment_coverage,
    ROUND(creditLimit, 2) AS credit_limit,
    ROUND(credit_utilization_proxy, 4) AS credit_utilization_proxy,
    CAST(orders AS DOUBLE) AS avg_orders_per_customer,
    ROUND(revenue / NULLIF(SUM(revenue) OVER (), 0), 4) AS share_value,
    'selected_customer_revenue_share' AS share_label,
    'Customer rows reveal whether high repeat depth coincides with payment coverage and margin quality.' AS notes
FROM customer_value
WHERE repeat_rank <= 20 OR low_coverage_rank <= 20 OR revenue_rank <= 20
UNION ALL
SELECT
    'country_repeat_profile' AS evidence_block,
    'country' AS grain,
    country AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    'country_revenue_rank' AS rank_label,
    CAST(revenue_rank AS DOUBLE) AS rank_value,
    CAST(customers AS BIGINT) AS customers,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(products AS BIGINT) AS products,
    CAST(NULL AS BIGINT) AS product_lines,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(payment_amount, 2) AS payment_amount,
    ROUND(payment_amount / NULLIF(revenue, 0), 4) AS payment_coverage,
    ROUND(credit_limit, 2) AS credit_limit,
    ROUND(revenue / NULLIF(credit_limit, 0), 4) AS credit_utilization_proxy,
    ROUND(avg_orders_per_customer, 4) AS avg_orders_per_customer,
    ROUND(repeat_customers / NULLIF(customers, 0), 4) AS share_value,
    'repeat_customer_share' AS share_label,
    'Country profile checks whether repeat value is concentrated in specific markets.' AS notes
FROM country_repeat
UNION ALL
SELECT
    'sales_rep_repeat_exposure' AS evidence_block,
    'sales_rep' AS grain,
    sales_rep AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    'sales_rep_revenue_rank' AS rank_label,
    CAST(revenue_rank AS DOUBLE) AS rank_value,
    CAST(customers AS BIGINT) AS customers,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(products AS BIGINT) AS products,
    CAST(NULL AS BIGINT) AS product_lines,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(payment_amount, 2) AS payment_amount,
    ROUND(payment_amount / NULLIF(revenue, 0), 4) AS payment_coverage,
    ROUND(credit_limit, 2) AS credit_limit,
    ROUND(revenue / NULLIF(credit_limit, 0), 4) AS credit_utilization_proxy,
    ROUND(avg_orders_per_customer, 4) AS avg_orders_per_customer,
    ROUND(repeat_customers / NULLIF(customers, 0), 4) AS share_value,
    'repeat_customer_share' AS share_label,
    'Sales-rep exposure shows whether repeat demand is concentrated under particular account owners.' AS notes
FROM rep_repeat;
