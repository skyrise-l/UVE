-- task_012_customer_value_payment_coverage_evidence.sql
-- Evidence SQL for task_012.
-- Public query: Which customers look valuable from orders, but may need closer review when payment coverage and credit exposure are considered?
-- Note: payments join only at customer level; this SQL does not infer payment timing for individual orders.

WITH
order_fact AS (
    SELECT
        o.orderNumber,
        o.customerNumber,
        o.orderDate,
        c.customerName,
        c.country,
        c.city,
        c.salesRepEmployeeNumber,
        c.creditLimit,
        od.productCode,
        od.quantityOrdered,
        od.priceEach,
        p.buyPrice,
        od.quantityOrdered * od.priceEach AS order_revenue,
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
        COUNT(DISTINCT ofa.orderNumber) AS orders,
        COUNT(ofa.productCode) AS order_lines,
        COUNT(DISTINCT ofa.productCode) AS products,
        COALESCE(SUM(ofa.order_revenue), 0) AS order_revenue,
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
        cp.first_payment_date,
        cp.last_payment_date,
        COALESCE(cp.payment_amount, 0) / NULLIF(co.order_revenue, 0) AS payment_coverage,
        co.order_revenue / NULLIF(co.creditLimit, 0) AS credit_utilization_proxy,
        co.gross_margin_proxy / NULLIF(co.order_revenue, 0) AS gross_margin_rate,
        ROW_NUMBER() OVER (ORDER BY co.order_revenue DESC, co.customerName) AS revenue_rank,
        ROW_NUMBER() OVER (ORDER BY COALESCE(cp.payment_amount, 0) DESC, co.customerName) AS payment_rank,
        ROW_NUMBER() OVER (ORDER BY COALESCE(cp.payment_amount, 0) / NULLIF(co.order_revenue, 0) ASC NULLS LAST, co.order_revenue DESC) AS low_coverage_rank,
        ROW_NUMBER() OVER (ORDER BY co.order_revenue / NULLIF(co.creditLimit, 0) DESC NULLS LAST, co.order_revenue DESC) AS credit_utilization_rank
    FROM customer_orders AS co
    LEFT JOIN customer_payments AS cp
      ON co.customerNumber = cp.customerNumber
),
totals AS (
    SELECT
        SUM(order_revenue) AS total_order_revenue,
        SUM(payment_amount) AS total_payment_amount,
        SUM(gross_margin_proxy) AS total_gross_margin_proxy,
        COUNT(*) AS total_customers,
        SUM(CASE WHEN orders > 0 THEN 1 ELSE 0 END) AS active_order_customers,
        SUM(CASE WHEN payment_amount > 0 THEN 1 ELSE 0 END) AS paying_customers
    FROM customer_value
),
country_value AS (
    SELECT
        country,
        COUNT(*) AS customers,
        SUM(CASE WHEN orders > 0 THEN 1 ELSE 0 END) AS active_order_customers,
        SUM(orders) AS orders,
        SUM(order_lines) AS order_lines,
        SUM(order_revenue) AS order_revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(payment_amount) AS payment_amount,
        SUM(creditLimit) AS credit_limit,
        SUM(payment_amount) / NULLIF(SUM(order_revenue), 0) AS payment_coverage,
        SUM(order_revenue) / NULLIF(SUM(creditLimit), 0) AS credit_utilization_proxy,
        ROW_NUMBER() OVER (ORDER BY SUM(order_revenue) DESC, country) AS country_revenue_rank,
        ROW_NUMBER() OVER (ORDER BY SUM(payment_amount) / NULLIF(SUM(order_revenue), 0) ASC NULLS LAST, SUM(order_revenue) DESC) AS low_coverage_rank
    FROM customer_value
    GROUP BY country
),
coverage_group AS (
    SELECT
        CASE
            WHEN order_revenue = 0 AND payment_amount > 0 THEN 'payment_without_observed_orders'
            WHEN order_revenue > 0 AND payment_amount = 0 THEN 'orders_without_observed_payments'
            WHEN payment_coverage < 0.75 THEN 'payment_coverage_below_75pct'
            WHEN payment_coverage <= 1.25 THEN 'payment_coverage_near_orders'
            WHEN payment_coverage > 1.25 THEN 'payment_coverage_above_orders'
            ELSE 'unclassified'
        END AS coverage_bucket,
        COUNT(*) AS customers,
        SUM(orders) AS orders,
        SUM(order_lines) AS order_lines,
        SUM(order_revenue) AS order_revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(payment_amount) AS payment_amount,
        AVG(payment_coverage) AS avg_payment_coverage,
        AVG(credit_utilization_proxy) AS avg_credit_utilization_proxy
    FROM customer_value
    GROUP BY coverage_bucket
),
rep_value AS (
    SELECT
        COALESCE(e.firstName || ' ' || e.lastName, 'No assigned sales rep') AS sales_rep,
        COUNT(*) AS customers,
        SUM(CASE WHEN orders > 0 THEN 1 ELSE 0 END) AS active_order_customers,
        SUM(orders) AS orders,
        SUM(order_revenue) AS order_revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(payment_amount) AS payment_amount,
        SUM(creditLimit) AS credit_limit,
        SUM(payment_amount) / NULLIF(SUM(order_revenue), 0) AS payment_coverage,
        SUM(order_revenue) / NULLIF(SUM(creditLimit), 0) AS credit_utilization_proxy,
        ROW_NUMBER() OVER (ORDER BY SUM(order_revenue) DESC, COALESCE(e.firstName || ' ' || e.lastName, 'No assigned sales rep')) AS revenue_rank
    FROM customer_value AS cv
    LEFT JOIN employees AS e
      ON cv.salesRepEmployeeNumber = e.employeeNumber
    GROUP BY sales_rep
)
SELECT
    'overall_customer_payment_baseline' AS evidence_block,
    'overall' AS grain,
    'all_customers' AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    ROUND(total_order_revenue, 2) AS order_revenue,
    ROUND(total_payment_amount, 2) AS payment_amount,
    ROUND(total_payment_amount / NULLIF(total_order_revenue, 0), 4) AS payment_coverage,
    ROUND(total_gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(total_gross_margin_proxy / NULLIF(total_order_revenue, 0), 4) AS gross_margin_rate,
    CAST(total_customers AS BIGINT) AS customers,
    CAST(active_order_customers AS BIGINT) AS active_order_customers,
    CAST(paying_customers AS BIGINT) AS paying_customers,
    CAST(NULL AS BIGINT) AS orders,
    CAST(NULL AS BIGINT) AS order_lines,
    CAST(NULL AS DOUBLE) AS credit_limit,
    CAST(NULL AS DOUBLE) AS credit_utilization_proxy,
    'customer-level payment table; do not infer order-level repayment timing' AS notes
FROM totals
UNION ALL
SELECT
    'high_value_customer_coverage' AS evidence_block,
    'customer' AS grain,
    customerName AS item,
    country AS item_2,
    'order_revenue_rank' AS rank_label,
    CAST(revenue_rank AS DOUBLE) AS rank_value,
    ROUND(order_revenue, 2) AS order_revenue,
    ROUND(payment_amount, 2) AS payment_amount,
    ROUND(payment_coverage, 4) AS payment_coverage,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_rate, 4) AS gross_margin_rate,
    CAST(1 AS BIGINT) AS customers,
    CAST(CASE WHEN orders > 0 THEN 1 ELSE 0 END AS BIGINT) AS active_order_customers,
    CAST(CASE WHEN payment_amount > 0 THEN 1 ELSE 0 END AS BIGINT) AS paying_customers,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    ROUND(creditLimit, 2) AS credit_limit,
    ROUND(credit_utilization_proxy, 4) AS credit_utilization_proxy,
    'Top order-value customers should be checked against payment coverage and credit exposure.' AS notes
FROM customer_value
WHERE revenue_rank <= 20 OR low_coverage_rank <= 20 OR credit_utilization_rank <= 20
UNION ALL
SELECT
    'coverage_bucket_summary' AS evidence_block,
    'coverage_bucket' AS grain,
    coverage_bucket AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    ROUND(order_revenue, 2) AS order_revenue,
    ROUND(payment_amount, 2) AS payment_amount,
    ROUND(avg_payment_coverage, 4) AS payment_coverage,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(order_revenue, 0), 4) AS gross_margin_rate,
    CAST(customers AS BIGINT) AS customers,
    CAST(NULL AS BIGINT) AS active_order_customers,
    CAST(NULL AS BIGINT) AS paying_customers,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(NULL AS DOUBLE) AS credit_limit,
    ROUND(avg_credit_utilization_proxy, 4) AS credit_utilization_proxy,
    'Coverage buckets separate revenue value from cash collection signal.' AS notes
FROM coverage_group
UNION ALL
SELECT
    'country_payment_quality' AS evidence_block,
    'country' AS grain,
    country AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    'country_order_revenue_rank' AS rank_label,
    CAST(country_revenue_rank AS DOUBLE) AS rank_value,
    ROUND(order_revenue, 2) AS order_revenue,
    ROUND(payment_amount, 2) AS payment_amount,
    ROUND(payment_coverage, 4) AS payment_coverage,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(order_revenue, 0), 4) AS gross_margin_rate,
    CAST(customers AS BIGINT) AS customers,
    CAST(active_order_customers AS BIGINT) AS active_order_customers,
    CAST(NULL AS BIGINT) AS paying_customers,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    ROUND(credit_limit, 2) AS credit_limit,
    ROUND(credit_utilization_proxy, 4) AS credit_utilization_proxy,
    'Country-level view shows whether customer value and payment coverage differ by market.' AS notes
FROM country_value
UNION ALL
SELECT
    'sales_rep_payment_exposure' AS evidence_block,
    'sales_rep' AS grain,
    sales_rep AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    'rep_order_revenue_rank' AS rank_label,
    CAST(revenue_rank AS DOUBLE) AS rank_value,
    ROUND(order_revenue, 2) AS order_revenue,
    ROUND(payment_amount, 2) AS payment_amount,
    ROUND(payment_coverage, 4) AS payment_coverage,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(order_revenue, 0), 4) AS gross_margin_rate,
    CAST(customers AS BIGINT) AS customers,
    CAST(active_order_customers AS BIGINT) AS active_order_customers,
    CAST(NULL AS BIGINT) AS paying_customers,
    CAST(orders AS BIGINT) AS orders,
    CAST(NULL AS BIGINT) AS order_lines,
    ROUND(credit_limit, 2) AS credit_limit,
    ROUND(credit_utilization_proxy, 4) AS credit_utilization_proxy,
    'Rep-level exposure is useful context, but customer-level payments remain the grain of payment evidence.' AS notes
FROM rep_value;
