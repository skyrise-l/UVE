-- task_018_market_coverage_sales_org_alignment_evidence.sql
-- Evidence SQL for task_018.
-- Public query: Are strong country markets adequately covered by the sales organization, or are there mismatches between market value, territory coverage, and payment quality?
-- Note: payments are customer-level signals; they are not order-level repayment timing.

WITH
order_fact AS (
    SELECT
        o.orderNumber,
        o.customerNumber,
        c.customerName,
        c.country AS customer_country,
        c.city AS customer_city,
        c.salesRepEmployeeNumber,
        c.creditLimit,
        e.firstName || ' ' || e.lastName AS sales_rep,
        e.officeCode,
        off.city AS office_city,
        off.country AS office_country,
        off.territory,
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
    LEFT JOIN employees AS e
      ON c.salesRepEmployeeNumber = e.employeeNumber
    LEFT JOIN offices AS off
      ON e.officeCode = off.officeCode
    JOIN orderdetails AS od
      ON o.orderNumber = od.orderNumber
    JOIN products AS p
      ON od.productCode = p.productCode
),
customer_orders AS (
    SELECT
        c.customerNumber,
        c.customerName,
        c.country AS customer_country,
        c.city AS customer_city,
        c.salesRepEmployeeNumber,
        c.creditLimit,
        e.firstName || ' ' || e.lastName AS sales_rep,
        e.officeCode,
        off.city AS office_city,
        off.country AS office_country,
        off.territory,
        COUNT(DISTINCT ofa.orderNumber) AS orders,
        COUNT(ofa.productCode) AS order_lines,
        COUNT(DISTINCT ofa.productCode) AS products,
        COUNT(DISTINCT ofa.productLine) AS product_lines,
        COALESCE(SUM(ofa.revenue), 0) AS revenue,
        COALESCE(SUM(ofa.gross_margin_proxy), 0) AS gross_margin_proxy
    FROM customers AS c
    LEFT JOIN employees AS e
      ON c.salesRepEmployeeNumber = e.employeeNumber
    LEFT JOIN offices AS off
      ON e.officeCode = off.officeCode
    LEFT JOIN order_fact AS ofa
      ON c.customerNumber = ofa.customerNumber
    GROUP BY c.customerNumber, c.customerName, c.country, c.city, c.salesRepEmployeeNumber,
             c.creditLimit, e.firstName, e.lastName, e.officeCode, off.city, off.country, off.territory
),
customer_payments AS (
    SELECT
        customerNumber,
        COUNT(*) AS payment_count,
        SUM(amount) AS payment_amount
    FROM payments
    GROUP BY customerNumber
),
customer_value AS (
    SELECT
        co.*,
        COALESCE(cp.payment_count, 0) AS payment_count,
        COALESCE(cp.payment_amount, 0) AS payment_amount,
        COALESCE(cp.payment_amount, 0) / NULLIF(co.revenue, 0) AS payment_coverage,
        co.revenue / NULLIF(co.creditLimit, 0) AS credit_utilization_proxy,
        co.gross_margin_proxy / NULLIF(co.revenue, 0) AS gross_margin_rate
    FROM customer_orders AS co
    LEFT JOIN customer_payments AS cp
      ON co.customerNumber = cp.customerNumber
),
country_market AS (
    SELECT
        customer_country,
        COUNT(*) AS customers,
        SUM(CASE WHEN orders > 0 THEN 1 ELSE 0 END) AS active_order_customers,
        COUNT(DISTINCT salesRepEmployeeNumber) FILTER (WHERE salesRepEmployeeNumber IS NOT NULL) AS sales_reps,
        COUNT(DISTINCT officeCode) FILTER (WHERE officeCode IS NOT NULL) AS offices,
        SUM(CASE WHEN salesRepEmployeeNumber IS NULL THEN 1 ELSE 0 END) AS unassigned_customers,
        SUM(orders) AS orders,
        SUM(order_lines) AS order_lines,
        SUM(products) AS products,
        SUM(product_lines) AS product_lines,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(payment_amount) AS payment_amount,
        SUM(creditLimit) AS credit_limit,
        ROW_NUMBER() OVER (ORDER BY SUM(revenue) DESC, customer_country) AS revenue_rank,
        ROW_NUMBER() OVER (ORDER BY SUM(CASE WHEN salesRepEmployeeNumber IS NULL THEN 1 ELSE 0 END) DESC, SUM(revenue) DESC, customer_country) AS unassigned_rank
    FROM customer_value
    GROUP BY customer_country
),
office_market AS (
    SELECT
        COALESCE(office_city, 'No assigned office') AS office_city,
        COALESCE(territory, 'No assigned territory') AS territory,
        COUNT(*) AS customers,
        COUNT(DISTINCT customer_country) AS countries,
        COUNT(DISTINCT salesRepEmployeeNumber) FILTER (WHERE salesRepEmployeeNumber IS NOT NULL) AS sales_reps,
        SUM(orders) AS orders,
        SUM(order_lines) AS order_lines,
        SUM(products) AS products,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(payment_amount) AS payment_amount,
        SUM(creditLimit) AS credit_limit,
        ROW_NUMBER() OVER (ORDER BY SUM(revenue) DESC, COALESCE(office_city, 'No assigned office')) AS revenue_rank
    FROM customer_value
    GROUP BY COALESCE(office_city, 'No assigned office'), COALESCE(territory, 'No assigned territory')
),
rep_span AS (
    SELECT
        COALESCE(sales_rep, 'No assigned sales rep') AS sales_rep,
        COALESCE(office_city, 'No assigned office') AS office_city,
        COUNT(*) AS customers,
        COUNT(DISTINCT customer_country) AS countries,
        SUM(orders) AS orders,
        SUM(order_lines) AS order_lines,
        SUM(products) AS products,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(payment_amount) AS payment_amount,
        SUM(creditLimit) AS credit_limit,
        ROW_NUMBER() OVER (ORDER BY SUM(revenue) DESC, COALESCE(sales_rep, 'No assigned sales rep')) AS revenue_rank
    FROM customer_value
    GROUP BY COALESCE(sales_rep, 'No assigned sales rep'), COALESCE(office_city, 'No assigned office')
),
country_office_pair AS (
    SELECT
        customer_country,
        COALESCE(office_city, 'No assigned office') AS office_city,
        COALESCE(territory, 'No assigned territory') AS territory,
        COUNT(*) AS customers,
        COUNT(DISTINCT salesRepEmployeeNumber) FILTER (WHERE salesRepEmployeeNumber IS NOT NULL) AS sales_reps,
        SUM(orders) AS orders,
        SUM(order_lines) AS order_lines,
        SUM(products) AS products,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(payment_amount) AS payment_amount,
        SUM(creditLimit) AS credit_limit,
        ROW_NUMBER() OVER (PARTITION BY customer_country ORDER BY SUM(revenue) DESC, COALESCE(office_city, 'No assigned office')) AS office_rank_in_country
    FROM customer_value
    GROUP BY customer_country, COALESCE(office_city, 'No assigned office'), COALESCE(territory, 'No assigned territory')
),
unassigned AS (
    SELECT
        customer_country,
        COUNT(*) AS customers,
        SUM(CASE WHEN orders > 0 THEN 1 ELSE 0 END) AS active_order_customers,
        SUM(orders) AS orders,
        SUM(order_lines) AS order_lines,
        SUM(products) AS products,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(payment_amount) AS payment_amount,
        SUM(creditLimit) AS credit_limit,
        ROW_NUMBER() OVER (ORDER BY SUM(revenue) DESC, customer_country) AS revenue_rank
    FROM customer_value
    WHERE salesRepEmployeeNumber IS NULL
    GROUP BY customer_country
)
SELECT
    'country_market_coverage' AS evidence_block,
    'country' AS grain,
    customer_country AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    'country_revenue_rank' AS rank_label,
    CAST(revenue_rank AS DOUBLE) AS rank_value,
    CAST(customers AS BIGINT) AS customers,
    CAST(active_order_customers AS BIGINT) AS active_order_customers,
    CAST(sales_reps AS BIGINT) AS sales_reps,
    CAST(offices AS BIGINT) AS offices,
    CAST(1 AS BIGINT) AS countries,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(products AS BIGINT) AS products,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(payment_amount, 2) AS payment_amount,
    ROUND(payment_amount / NULLIF(revenue, 0), 4) AS payment_coverage,
    ROUND(credit_limit, 2) AS credit_limit,
    ROUND(revenue / NULLIF(credit_limit, 0), 4) AS credit_utilization_proxy,
    ROUND(revenue / NULLIF(SUM(revenue) OVER (), 0), 4) AS share_value,
    'revenue_share' AS share_label,
    'Country rows combine demand value, organization coverage, payment coverage, and credit exposure.' AS notes
FROM country_market
UNION ALL
SELECT
    'office_territory_coverage' AS evidence_block,
    'office' AS grain,
    office_city AS item,
    territory AS item_2,
    'office_revenue_rank' AS rank_label,
    CAST(revenue_rank AS DOUBLE) AS rank_value,
    CAST(customers AS BIGINT) AS customers,
    CAST(NULL AS BIGINT) AS active_order_customers,
    CAST(sales_reps AS BIGINT) AS sales_reps,
    CAST(1 AS BIGINT) AS offices,
    CAST(countries AS BIGINT) AS countries,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(products AS BIGINT) AS products,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(payment_amount, 2) AS payment_amount,
    ROUND(payment_amount / NULLIF(revenue, 0), 4) AS payment_coverage,
    ROUND(credit_limit, 2) AS credit_limit,
    ROUND(revenue / NULLIF(credit_limit, 0), 4) AS credit_utilization_proxy,
    ROUND(revenue / NULLIF(SUM(revenue) OVER (), 0), 4) AS share_value,
    'revenue_share' AS share_label,
    'Office aggregation checks whether territory structure changes the market-quality interpretation.' AS notes
FROM office_market
UNION ALL
SELECT
    'sales_rep_market_span' AS evidence_block,
    'sales_rep' AS grain,
    sales_rep AS item,
    office_city AS item_2,
    'sales_rep_revenue_rank' AS rank_label,
    CAST(revenue_rank AS DOUBLE) AS rank_value,
    CAST(customers AS BIGINT) AS customers,
    CAST(NULL AS BIGINT) AS active_order_customers,
    CAST(1 AS BIGINT) AS sales_reps,
    CAST(NULL AS BIGINT) AS offices,
    CAST(countries AS BIGINT) AS countries,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(products AS BIGINT) AS products,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(payment_amount, 2) AS payment_amount,
    ROUND(payment_amount / NULLIF(revenue, 0), 4) AS payment_coverage,
    ROUND(credit_limit, 2) AS credit_limit,
    ROUND(revenue / NULLIF(credit_limit, 0), 4) AS credit_utilization_proxy,
    ROUND(revenue / NULLIF(SUM(revenue) OVER (), 0), 4) AS share_value,
    'selected_rep_revenue_share' AS share_label,
    'Sales-rep span reveals whether market value is concentrated under a few reps or distributed across coverage.' AS notes
FROM rep_span
UNION ALL
SELECT
    'country_office_alignment' AS evidence_block,
    'country_office_pair' AS grain,
    customer_country AS item,
    office_city AS item_2,
    'office_rank_in_country' AS rank_label,
    CAST(office_rank_in_country AS DOUBLE) AS rank_value,
    CAST(customers AS BIGINT) AS customers,
    CAST(NULL AS BIGINT) AS active_order_customers,
    CAST(sales_reps AS BIGINT) AS sales_reps,
    CAST(1 AS BIGINT) AS offices,
    CAST(1 AS BIGINT) AS countries,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(products AS BIGINT) AS products,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(payment_amount, 2) AS payment_amount,
    ROUND(payment_amount / NULLIF(revenue, 0), 4) AS payment_coverage,
    ROUND(credit_limit, 2) AS credit_limit,
    ROUND(revenue / NULLIF(credit_limit, 0), 4) AS credit_utilization_proxy,
    ROUND(revenue / NULLIF(SUM(revenue) OVER (PARTITION BY customer_country), 0), 4) AS share_value,
    'country_revenue_share_in_office_pair' AS share_label,
    'Country-office pair rows make cross-territory coverage visible.' AS notes
FROM country_office_pair
WHERE office_rank_in_country <= 3
UNION ALL
SELECT
    'unassigned_customer_market_exposure' AS evidence_block,
    'unassigned_country' AS grain,
    customer_country AS item,
    'No assigned sales rep' AS item_2,
    'unassigned_revenue_rank' AS rank_label,
    CAST(revenue_rank AS DOUBLE) AS rank_value,
    CAST(customers AS BIGINT) AS customers,
    CAST(active_order_customers AS BIGINT) AS active_order_customers,
    CAST(0 AS BIGINT) AS sales_reps,
    CAST(0 AS BIGINT) AS offices,
    CAST(1 AS BIGINT) AS countries,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(products AS BIGINT) AS products,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_proxy / NULLIF(revenue, 0), 4) AS gross_margin_rate,
    ROUND(payment_amount, 2) AS payment_amount,
    ROUND(payment_amount / NULLIF(revenue, 0), 4) AS payment_coverage,
    ROUND(credit_limit, 2) AS credit_limit,
    ROUND(revenue / NULLIF(credit_limit, 0), 4) AS credit_utilization_proxy,
    ROUND(revenue / NULLIF(SUM(revenue) OVER (), 0), 4) AS share_value,
    'unassigned_revenue_share' AS share_label,
    'Unassigned customers are separated so coverage gaps are not hidden in country totals.' AS notes
FROM unassigned;
