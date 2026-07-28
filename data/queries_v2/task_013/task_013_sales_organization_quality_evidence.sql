-- task_013_sales_organization_quality_evidence.sql
-- Evidence SQL for task_013.
-- Public query: Which sales representatives or offices create strong business, and where might performance depend too much on customer concentration or product mix?
-- Note: gross_margin_proxy uses priceEach - buyPrice and is not an accounting profit measure.

WITH
line_fact AS (
    SELECT
        od.orderNumber,
        o.customerNumber,
        c.customerName,
        c.country AS customer_country,
        c.city AS customer_city,
        c.salesRepEmployeeNumber,
        COALESCE(e.firstName || ' ' || e.lastName, 'No assigned sales rep') AS sales_rep,
        COALESCE(e.employeeNumber, -1) AS sales_rep_id,
        COALESCE(off.city, 'No office') AS office_city,
        COALESCE(off.country, 'No office country') AS office_country,
        COALESCE(off.territory, 'No territory') AS territory,
        p.productLine,
        p.productCode,
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
customer_totals AS (
    SELECT
        sales_rep_id,
        sales_rep,
        office_city,
        territory,
        customerNumber,
        MIN(customerName) AS customerName,
        COUNT(DISTINCT orderNumber) AS orders,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy
    FROM line_fact
    GROUP BY sales_rep_id, sales_rep, office_city, territory, customerNumber
),
rep_raw AS (
    SELECT
        sales_rep_id,
        sales_rep,
        office_city,
        territory,
        COUNT(DISTINCT customerNumber) AS active_customers,
        COUNT(DISTINCT orderNumber) AS orders,
        COUNT(*) AS order_lines,
        COUNT(DISTINCT productCode) AS products,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(quantityOrdered) AS quantity
    FROM line_fact
    GROUP BY sales_rep_id, sales_rep, office_city, territory
),
rep_top_customer AS (
    SELECT
        sales_rep_id,
        sales_rep,
        customerName,
        revenue AS top_customer_revenue,
        gross_margin_proxy AS top_customer_margin_proxy,
        ROW_NUMBER() OVER (PARTITION BY sales_rep_id ORDER BY revenue DESC, customerName) AS rn
    FROM customer_totals
),
payments_by_rep AS (
    SELECT
        COALESCE(e.employeeNumber, -1) AS sales_rep_id,
        COALESCE(e.firstName || ' ' || e.lastName, 'No assigned sales rep') AS sales_rep,
        SUM(pay.amount) AS payment_amount
    FROM customers AS c
    LEFT JOIN employees AS e
      ON c.salesRepEmployeeNumber = e.employeeNumber
    JOIN payments AS pay
      ON c.customerNumber = pay.customerNumber
    GROUP BY sales_rep_id, sales_rep
),
rep_metrics AS (
    SELECT
        rr.*,
        COALESCE(pbr.payment_amount, 0) AS payment_amount,
        rr.gross_margin_proxy / NULLIF(rr.revenue, 0) AS gross_margin_rate,
        COALESCE(pbr.payment_amount, 0) / NULLIF(rr.revenue, 0) AS payment_coverage,
        rtc.customerName AS top_customer_name,
        rtc.top_customer_revenue,
        rtc.top_customer_margin_proxy,
        rtc.top_customer_revenue / NULLIF(rr.revenue, 0) AS top_customer_revenue_share,
        ROW_NUMBER() OVER (ORDER BY rr.revenue DESC, rr.sales_rep) AS revenue_rank,
        ROW_NUMBER() OVER (ORDER BY rr.gross_margin_proxy / NULLIF(rr.revenue, 0) DESC NULLS LAST, rr.revenue DESC) AS margin_rate_rank,
        ROW_NUMBER() OVER (ORDER BY rtc.top_customer_revenue / NULLIF(rr.revenue, 0) DESC NULLS LAST, rr.revenue DESC) AS concentration_rank
    FROM rep_raw AS rr
    LEFT JOIN payments_by_rep AS pbr
      ON rr.sales_rep_id = pbr.sales_rep_id
    LEFT JOIN rep_top_customer AS rtc
      ON rr.sales_rep_id = rtc.sales_rep_id AND rtc.rn = 1
),
office_raw AS (
    SELECT
        office_city,
        office_country,
        territory,
        COUNT(DISTINCT sales_rep_id) AS reps,
        COUNT(DISTINCT customerNumber) AS active_customers,
        COUNT(DISTINCT orderNumber) AS orders,
        COUNT(*) AS order_lines,
        COUNT(DISTINCT productCode) AS products,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(quantityOrdered) AS quantity
    FROM line_fact
    GROUP BY office_city, office_country, territory
),
office_metrics AS (
    SELECT
        *,
        gross_margin_proxy / NULLIF(revenue, 0) AS gross_margin_rate,
        ROW_NUMBER() OVER (ORDER BY revenue DESC, office_city) AS revenue_rank,
        ROW_NUMBER() OVER (ORDER BY gross_margin_proxy / NULLIF(revenue, 0) DESC NULLS LAST, revenue DESC) AS margin_rate_rank
    FROM office_raw
),
rep_line_raw AS (
    SELECT
        sales_rep_id,
        sales_rep,
        productLine,
        COUNT(DISTINCT orderNumber) AS orders,
        COUNT(*) AS order_lines,
        COUNT(DISTINCT customerNumber) AS customers,
        COUNT(DISTINCT productCode) AS products,
        SUM(revenue) AS revenue,
        SUM(gross_margin_proxy) AS gross_margin_proxy,
        SUM(quantityOrdered) AS quantity
    FROM line_fact
    GROUP BY sales_rep_id, sales_rep, productLine
),
rep_line_metrics AS (
    SELECT
        *,
        gross_margin_proxy / NULLIF(revenue, 0) AS gross_margin_rate,
        revenue / NULLIF(SUM(revenue) OVER (PARTITION BY sales_rep_id), 0) AS rep_revenue_share,
        ROW_NUMBER() OVER (PARTITION BY sales_rep_id ORDER BY revenue DESC, productLine) AS line_mix_rank
    FROM rep_line_raw
),
unassigned AS (
    SELECT * FROM rep_metrics WHERE sales_rep_id = -1
)
SELECT
    'sales_rep_performance_baseline' AS evidence_block,
    'sales_rep' AS grain,
    sales_rep AS item,
    office_city AS item_2,
    'revenue_rank' AS rank_label,
    CAST(revenue_rank AS DOUBLE) AS rank_value,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_rate, 4) AS gross_margin_rate,
    ROUND(payment_amount, 2) AS payment_amount,
    ROUND(payment_coverage, 4) AS payment_coverage,
    CAST(active_customers AS BIGINT) AS customers,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(products AS BIGINT) AS products,
    CAST(quantity AS DOUBLE) AS quantity,
    'top_customer_revenue_share' AS extra_metric_1,
    ROUND(top_customer_revenue_share, 4) AS extra_value_1,
    'margin_rate_rank' AS extra_metric_2,
    CAST(margin_rate_rank AS DOUBLE) AS extra_value_2,
    'Use this block to compare sales rep scale, margin proxy, payment coverage, and concentration.' AS notes
FROM rep_metrics
UNION ALL
SELECT
    'rep_customer_concentration' AS evidence_block,
    'sales_rep_top_customer' AS grain,
    sales_rep AS item,
    top_customer_name AS item_2,
    'top_customer_share_rank' AS rank_label,
    CAST(concentration_rank AS DOUBLE) AS rank_value,
    ROUND(top_customer_revenue, 2) AS revenue,
    ROUND(top_customer_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(top_customer_margin_proxy / NULLIF(top_customer_revenue, 0), 4) AS gross_margin_rate,
    ROUND(payment_amount, 2) AS payment_amount,
    ROUND(payment_coverage, 4) AS payment_coverage,
    CAST(active_customers AS BIGINT) AS customers,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(products AS BIGINT) AS products,
    CAST(quantity AS DOUBLE) AS quantity,
    'top_customer_revenue_share' AS extra_metric_1,
    ROUND(top_customer_revenue_share, 4) AS extra_value_1,
    'rep_total_revenue' AS extra_metric_2,
    ROUND(revenue, 2) AS extra_value_2,
    'High-performing reps should be checked for dependence on one large customer.' AS notes
FROM rep_metrics
UNION ALL
SELECT
    'office_territory_performance' AS evidence_block,
    'office_territory' AS grain,
    office_city AS item,
    territory AS item_2,
    'office_revenue_rank' AS rank_label,
    CAST(revenue_rank AS DOUBLE) AS rank_value,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_rate, 4) AS gross_margin_rate,
    CAST(NULL AS DOUBLE) AS payment_amount,
    CAST(NULL AS DOUBLE) AS payment_coverage,
    CAST(active_customers AS BIGINT) AS customers,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(products AS BIGINT) AS products,
    CAST(quantity AS DOUBLE) AS quantity,
    'reps' AS extra_metric_1,
    CAST(reps AS DOUBLE) AS extra_value_1,
    'office_margin_rate_rank' AS extra_metric_2,
    CAST(margin_rate_rank AS DOUBLE) AS extra_value_2,
    'Office and territory view avoids over-interpreting individual rep performance.' AS notes
FROM office_metrics
UNION ALL
SELECT
    'rep_product_line_mix' AS evidence_block,
    'sales_rep_product_line' AS grain,
    sales_rep AS item,
    productLine AS item_2,
    'line_mix_rank_within_rep' AS rank_label,
    CAST(line_mix_rank AS DOUBLE) AS rank_value,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_rate, 4) AS gross_margin_rate,
    CAST(NULL AS DOUBLE) AS payment_amount,
    CAST(NULL AS DOUBLE) AS payment_coverage,
    CAST(customers AS BIGINT) AS customers,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(products AS BIGINT) AS products,
    CAST(quantity AS DOUBLE) AS quantity,
    'rep_revenue_share' AS extra_metric_1,
    ROUND(rep_revenue_share, 4) AS extra_value_1,
    'not_applicable' AS extra_metric_2,
    CAST(NULL AS DOUBLE) AS extra_value_2,
    'Product-line mix helps explain why similar revenue reps can have different business quality.' AS notes
FROM rep_line_metrics
WHERE line_mix_rank <= 3
UNION ALL
SELECT
    'unassigned_customer_exposure' AS evidence_block,
    'sales_rep' AS grain,
    sales_rep AS item,
    office_city AS item_2,
    'unassigned_exposure' AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    ROUND(revenue, 2) AS revenue,
    ROUND(gross_margin_proxy, 2) AS gross_margin_proxy,
    ROUND(gross_margin_rate, 4) AS gross_margin_rate,
    ROUND(payment_amount, 2) AS payment_amount,
    ROUND(payment_coverage, 4) AS payment_coverage,
    CAST(active_customers AS BIGINT) AS customers,
    CAST(orders AS BIGINT) AS orders,
    CAST(order_lines AS BIGINT) AS order_lines,
    CAST(products AS BIGINT) AS products,
    CAST(quantity AS DOUBLE) AS quantity,
    'top_customer_revenue_share' AS extra_metric_1,
    ROUND(top_customer_revenue_share, 4) AS extra_value_1,
    'not_applicable' AS extra_metric_2,
    CAST(NULL AS DOUBLE) AS extra_value_2,
    'Customers without an assigned sales rep should be audited separately if present.' AS notes
FROM unassigned;
