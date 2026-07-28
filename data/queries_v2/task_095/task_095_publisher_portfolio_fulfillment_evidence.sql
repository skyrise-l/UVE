WITH
order_status_flags AS (
    SELECT
        oh.order_id,
        MAX(CASE WHEN os.status_value = 'Delivered' THEN 1 ELSE 0 END) AS has_delivered,
        MAX(CASE WHEN os.status_value = 'Cancelled' THEN 1 ELSE 0 END) AS has_cancelled,
        MAX(CASE WHEN os.status_value = 'Returned' THEN 1 ELSE 0 END) AS has_returned
    FROM order_history oh
    JOIN order_status os ON oh.status_id = os.status_id
    GROUP BY oh.order_id
),
author_count AS (
    SELECT
        book_id,
        COUNT(DISTINCT author_id) AS author_count
    FROM book_author
    GROUP BY book_id
),
line_enriched AS (
    SELECT
        ol.line_id,
        ol.order_id,
        ol.book_id,
        CAST(ol.price AS DOUBLE) AS price,
        p.publisher_name,
        b.title,
        bl.language_name,
        COALESCE(ac.author_count, 0) AS author_count,
        CASE
            WHEN SUBSTR(CAST(b.publication_date AS VARCHAR), 1, 4) < '1980' THEN 'pre_1980'
            WHEN SUBSTR(CAST(b.publication_date AS VARCHAR), 1, 4) < '2000' THEN '1980_1999'
            ELSE '2000_plus'
        END AS publication_era,
        sm.method_name,
        COALESCE(osf.has_delivered, 0) AS has_delivered,
        COALESCE(osf.has_cancelled, 0) AS has_cancelled,
        COALESCE(osf.has_returned, 0) AS has_returned
    FROM order_line ol
    LEFT JOIN book b ON ol.book_id = b.book_id
    LEFT JOIN publisher p ON b.publisher_id = p.publisher_id
    LEFT JOIN book_language bl ON b.language_id = bl.language_id
    LEFT JOIN author_count ac ON b.book_id = ac.book_id
    LEFT JOIN cust_order co ON ol.order_id = co.order_id
    LEFT JOIN shipping_method sm ON co.shipping_method_id = sm.method_id
    LEFT JOIN order_status_flags osf ON ol.order_id = osf.order_id
),
book_base AS (
    SELECT
        b.book_id,
        b.title,
        p.publisher_name,
        bl.language_name,
        COALESCE(ac.author_count, 0) AS author_count,
        CASE
            WHEN SUBSTR(CAST(b.publication_date AS VARCHAR), 1, 4) < '1980' THEN 'pre_1980'
            WHEN SUBSTR(CAST(b.publication_date AS VARCHAR), 1, 4) < '2000' THEN '1980_1999'
            ELSE '2000_plus'
        END AS publication_era
    FROM book b
    LEFT JOIN publisher p ON b.publisher_id = p.publisher_id
    LEFT JOIN book_language bl ON b.language_id = bl.language_id
    LEFT JOIN author_count ac ON b.book_id = ac.book_id
),
sales_by_book AS (
    SELECT
        book_id,
        COUNT(*) AS line_count,
        COUNT(DISTINCT order_id) AS order_count,
        SUM(price) AS total_price,
        AVG(price) AS avg_price,
        SUM(has_delivered) AS delivered_lines,
        SUM(has_cancelled) AS cancelled_lines,
        SUM(has_returned) AS returned_lines
    FROM line_enriched
    GROUP BY book_id
),
book_metrics AS (
    SELECT
        bb.*,
        COALESCE(sbb.line_count, 0) AS line_count,
        COALESCE(sbb.order_count, 0) AS order_count,
        COALESCE(sbb.total_price, 0) AS total_price,
        sbb.avg_price,
        COALESCE(sbb.delivered_lines, 0) AS delivered_lines,
        COALESCE(sbb.cancelled_lines, 0) AS cancelled_lines,
        COALESCE(sbb.returned_lines, 0) AS returned_lines
    FROM book_base bb
    LEFT JOIN sales_by_book sbb ON bb.book_id = sbb.book_id
),
publisher_portfolio AS (
    SELECT
        publisher_name AS item,
        COUNT(*) AS book_count,
        COUNT(CASE WHEN line_count > 0 THEN 1 END) AS sold_book_count,
        COUNT(DISTINCT language_name) AS language_count,
        AVG(author_count) AS avg_author_count,
        SUM(line_count) AS line_count,
        SUM(order_count) AS order_count,
        SUM(total_price) AS total_price,
        AVG(avg_price) AS avg_price,
        SUM(delivered_lines) AS delivered_lines,
        SUM(cancelled_lines) AS cancelled_lines,
        SUM(returned_lines) AS returned_lines
    FROM book_metrics
    GROUP BY publisher_name
),
publisher_language AS (
    SELECT
        publisher_name AS item,
        language_name AS item_2,
        COUNT(*) AS book_count,
        COUNT(CASE WHEN line_count > 0 THEN 1 END) AS sold_book_count,
        SUM(line_count) AS line_count,
        SUM(order_count) AS order_count,
        SUM(total_price) AS total_price,
        AVG(avg_price) AS avg_price,
        AVG(author_count) AS avg_author_count
    FROM book_metrics
    GROUP BY publisher_name, language_name
),
publisher_author AS (
    SELECT
        publisher_name AS item,
        CASE
            WHEN author_count = 0 THEN 'no_author_link'
            WHEN author_count = 1 THEN 'single_author'
            ELSE 'multi_author'
        END AS item_2,
        COUNT(*) AS book_count,
        COUNT(CASE WHEN line_count > 0 THEN 1 END) AS sold_book_count,
        SUM(line_count) AS line_count,
        SUM(order_count) AS order_count,
        SUM(total_price) AS total_price,
        AVG(avg_price) AS avg_price,
        AVG(author_count) AS avg_author_count
    FROM book_metrics
    GROUP BY
        publisher_name,
        CASE
            WHEN author_count = 0 THEN 'no_author_link'
            WHEN author_count = 1 THEN 'single_author'
            ELSE 'multi_author'
        END
),
publisher_shipping AS (
    SELECT
        publisher_name AS item,
        method_name AS item_2,
        COUNT(*) AS line_count,
        COUNT(DISTINCT order_id) AS order_count,
        COUNT(DISTINCT book_id) AS sold_book_count,
        SUM(price) AS total_price,
        AVG(price) AS avg_price,
        SUM(has_delivered) AS delivered_lines,
        SUM(has_cancelled) AS cancelled_lines,
        SUM(has_returned) AS returned_lines
    FROM line_enriched
    GROUP BY publisher_name, method_name
),
publisher_lifecycle AS (
    SELECT
        publisher_name AS item,
        CASE
            WHEN has_cancelled = 1 THEN 'cancelled_path'
            WHEN has_returned = 1 THEN 'returned_path'
            WHEN has_delivered = 1 THEN 'delivered_path'
            ELSE 'no_terminal_or_unmatched_path'
        END AS item_2,
        COUNT(*) AS line_count,
        COUNT(DISTINCT order_id) AS order_count,
        COUNT(DISTINCT book_id) AS sold_book_count,
        SUM(price) AS total_price,
        AVG(price) AS avg_price
    FROM line_enriched
    GROUP BY
        publisher_name,
        CASE
            WHEN has_cancelled = 1 THEN 'cancelled_path'
            WHEN has_returned = 1 THEN 'returned_path'
            WHEN has_delivered = 1 THEN 'delivered_path'
            ELSE 'no_terminal_or_unmatched_path'
        END
),
publisher_era AS (
    SELECT
        publisher_name AS item,
        publication_era AS item_2,
        COUNT(*) AS book_count,
        COUNT(CASE WHEN line_count > 0 THEN 1 END) AS sold_book_count,
        SUM(line_count) AS line_count,
        SUM(order_count) AS order_count,
        SUM(total_price) AS total_price,
        AVG(avg_price) AS avg_price,
        AVG(author_count) AS avg_author_count
    FROM book_metrics
    GROUP BY publisher_name, publication_era
),
ranked_title AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY publisher_name ORDER BY total_price DESC, line_count DESC, title) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (PARTITION BY publisher_name), 0) AS share_pct
    FROM book_metrics
),
ranked_portfolio AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY total_price DESC, book_count DESC, item) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (), 0) AS share_pct
    FROM publisher_portfolio
),
ranked_language AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY item ORDER BY total_price DESC, book_count DESC, item_2) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (PARTITION BY item), 0) AS share_pct
    FROM publisher_language
),
ranked_author AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY item ORDER BY total_price DESC, book_count DESC, item_2) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (PARTITION BY item), 0) AS share_pct
    FROM publisher_author
),
ranked_shipping AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY item ORDER BY total_price DESC, line_count DESC, item_2) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (PARTITION BY item), 0) AS share_pct
    FROM publisher_shipping
),
ranked_lifecycle AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY item ORDER BY total_price DESC, line_count DESC, item_2) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (PARTITION BY item), 0) AS share_pct
    FROM publisher_lifecycle
),
ranked_era AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY item ORDER BY total_price DESC, book_count DESC, item_2) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (PARTITION BY item), 0) AS share_pct
    FROM publisher_era
)
SELECT
    'publisher_portfolio_baseline' AS evidence_block,
    'publisher' AS grain,
    item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'publisher_value_rank' AS rank_label,
    CAST(rank_value AS DOUBLE) AS rank_value,
    CAST(1 AS BIGINT) AS publisher_count,
    book_count,
    sold_book_count,
    ROUND(avg_author_count, 4) AS author_count,
    language_count,
    line_count,
    order_count,
    ROUND(total_price, 4) AS total_price,
    ROUND(avg_price, 4) AS avg_price,
    delivered_lines,
    cancelled_lines,
    returned_lines,
    ROUND(share_pct, 4) AS share_pct,
    CAST(NULL AS DOUBLE) AS secondary_value,
    'Publisher catalog breadth and order-value baseline.' AS notes
FROM ranked_portfolio
UNION ALL
SELECT
    'publisher_language_mix',
    'publisher_language',
    item,
    item_2,
    CAST(NULL AS VARCHAR),
    'language_rank_within_publisher',
    CAST(rank_value AS DOUBLE),
    CAST(1 AS BIGINT),
    book_count,
    sold_book_count,
    ROUND(avg_author_count, 4),
    CAST(1 AS BIGINT),
    line_count,
    order_count,
    ROUND(total_price, 4),
    ROUND(avg_price, 4),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    ROUND(share_pct, 4),
    CAST(NULL AS DOUBLE),
    'Language mix within each publisher portfolio.'
FROM ranked_language
UNION ALL
SELECT
    'publisher_author_collaboration',
    'publisher_author_bucket',
    item,
    item_2,
    CAST(NULL AS VARCHAR),
    'author_bucket_rank_within_publisher',
    CAST(rank_value AS DOUBLE),
    CAST(1 AS BIGINT),
    book_count,
    sold_book_count,
    ROUND(avg_author_count, 4),
    CAST(NULL AS BIGINT),
    line_count,
    order_count,
    ROUND(total_price, 4),
    ROUND(avg_price, 4),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    ROUND(share_pct, 4),
    CAST(NULL AS DOUBLE),
    'Author-collaboration shape within publisher portfolios.'
FROM ranked_author
UNION ALL
SELECT
    'publisher_shipping_mix',
    'publisher_shipping',
    item,
    item_2,
    CAST(NULL AS VARCHAR),
    'shipping_rank_within_publisher',
    CAST(rank_value AS DOUBLE),
    CAST(1 AS BIGINT),
    CAST(NULL AS BIGINT),
    sold_book_count,
    CAST(NULL AS DOUBLE),
    CAST(NULL AS BIGINT),
    line_count,
    order_count,
    ROUND(total_price, 4),
    ROUND(avg_price, 4),
    delivered_lines,
    cancelled_lines,
    returned_lines,
    ROUND(share_pct, 4),
    CAST(NULL AS DOUBLE),
    'Publisher demand by shipping method.'
FROM ranked_shipping
UNION ALL
SELECT
    'publisher_lifecycle_mix',
    'publisher_lifecycle',
    item,
    item_2,
    CAST(NULL AS VARCHAR),
    'lifecycle_rank_within_publisher',
    CAST(rank_value AS DOUBLE),
    CAST(1 AS BIGINT),
    CAST(NULL AS BIGINT),
    sold_book_count,
    CAST(NULL AS DOUBLE),
    CAST(NULL AS BIGINT),
    line_count,
    order_count,
    ROUND(total_price, 4),
    ROUND(avg_price, 4),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    ROUND(share_pct, 4),
    CAST(NULL AS DOUBLE),
    'Publisher demand by order lifecycle outcome.'
FROM ranked_lifecycle
UNION ALL
SELECT
    'publisher_recency_mix',
    'publisher_publication_era',
    item,
    item_2,
    CAST(NULL AS VARCHAR),
    'era_rank_within_publisher',
    CAST(rank_value AS DOUBLE),
    CAST(1 AS BIGINT),
    book_count,
    sold_book_count,
    ROUND(avg_author_count, 4),
    CAST(NULL AS BIGINT),
    line_count,
    order_count,
    ROUND(total_price, 4),
    ROUND(avg_price, 4),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    ROUND(share_pct, 4),
    CAST(NULL AS DOUBLE),
    'Publication-era mix within publisher portfolios.'
FROM ranked_era
UNION ALL
SELECT
    'publisher_title_concentration',
    'publisher_title',
    publisher_name,
    title,
    language_name,
    'title_rank_within_publisher',
    CAST(rank_value AS DOUBLE),
    CAST(1 AS BIGINT),
    CAST(1 AS BIGINT),
    CASE WHEN line_count > 0 THEN 1 ELSE 0 END,
    CAST(author_count AS DOUBLE),
    CAST(1 AS BIGINT),
    line_count,
    order_count,
    ROUND(total_price, 4),
    ROUND(avg_price, 4),
    delivered_lines,
    cancelled_lines,
    returned_lines,
    ROUND(share_pct, 4),
    CAST(NULL AS DOUBLE),
    'Title-level concentration inside publisher portfolios.'
FROM ranked_title
WHERE line_count > 0 OR rank_value <= 3
ORDER BY evidence_block, item, rank_value;
