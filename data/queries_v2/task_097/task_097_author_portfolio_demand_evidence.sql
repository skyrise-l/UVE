WITH
book_author_count AS (
    SELECT book_id, COUNT(DISTINCT author_id) AS author_count
    FROM book_author
    GROUP BY book_id
),
status_flags AS (
    SELECT oh.order_id,
        MAX(CASE WHEN os.status_value = 'Delivered' THEN 1 ELSE 0 END) AS has_delivered,
        MAX(CASE WHEN os.status_value = 'Cancelled' THEN 1 ELSE 0 END) AS has_cancelled,
        MAX(CASE WHEN os.status_value = 'Returned' THEN 1 ELSE 0 END) AS has_returned,
        COUNT(DISTINCT os.status_value) AS status_count
    FROM order_history oh
    JOIN order_status os ON oh.status_id = os.status_id
    GROUP BY oh.order_id
),
book_catalog AS (
    SELECT b.book_id, b.title, b.num_pages,
        CASE
            WHEN CAST(SUBSTR(CAST(b.publication_date AS VARCHAR), 1, 4) AS INTEGER) >= 2000 THEN '2000_plus'
            WHEN CAST(SUBSTR(CAST(b.publication_date AS VARCHAR), 1, 4) AS INTEGER) >= 1980 THEN '1980_1999'
            ELSE 'pre_1980'
        END AS publication_era,
        bl.language_name, p.publisher_name, ba.author_id, a.author_name,
        COALESCE(bac.author_count, 0) AS book_author_count,
        CASE WHEN COALESCE(bac.author_count, 0) <= 1 THEN 'single_author_book' ELSE 'multi_author_book' END AS collaboration_bucket
    FROM book b
    JOIN book_author ba ON b.book_id = ba.book_id
    JOIN author a ON ba.author_id = a.author_id
    LEFT JOIN book_author_count bac ON b.book_id = bac.book_id
    LEFT JOIN book_language bl ON b.language_id = bl.language_id
    LEFT JOIN publisher p ON b.publisher_id = p.publisher_id
),
line_enriched AS (
    SELECT bc.*, ol.order_id, co.customer_id, CAST(ol.price AS DOUBLE) AS price,
        CASE
            WHEN ol.order_id IS NULL THEN 'no_observed_order'
            WHEN COALESCE(sf.has_cancelled, 0) = 1 THEN 'cancelled_path'
            WHEN COALESCE(sf.has_returned, 0) = 1 THEN 'returned_path'
            WHEN COALESCE(sf.has_delivered, 0) = 1 THEN 'delivered_path'
            WHEN COALESCE(sf.status_count, 0) = 0 THEN 'no_history'
            ELSE 'incomplete_or_in_progress'
        END AS lifecycle_bucket
    FROM book_catalog bc
    LEFT JOIN order_line ol ON bc.book_id = ol.book_id
    LEFT JOIN cust_order co ON ol.order_id = co.order_id
    LEFT JOIN status_flags sf ON ol.order_id = sf.order_id
),
author_base AS (
    SELECT author_id, author_name,
        COUNT(DISTINCT book_id) AS catalog_book_count,
        COUNT(DISTINCT CASE WHEN order_id IS NOT NULL THEN book_id END) AS sold_book_count,
        COUNT(order_id) AS line_count,
        COUNT(DISTINCT order_id) AS order_count,
        COUNT(DISTINCT customer_id) AS customer_count,
        COUNT(DISTINCT publisher_name) AS publisher_count,
        COUNT(DISTINCT language_name) AS language_count,
        SUM(COALESCE(price, 0)) AS total_price,
        AVG(price) AS avg_price,
        AVG(num_pages) AS avg_pages
    FROM line_enriched
    GROUP BY author_id, author_name
),
ranked_author AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY total_price DESC, line_count DESC, author_name) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (), 0) AS share_pct
    FROM author_base
),
author_detail_scope AS (
    SELECT author_id FROM ranked_author WHERE rank_value <= 60
),
author_title AS (
    SELECT le.author_id, le.author_name, le.title AS item_2, le.publisher_name AS item_3,
        COUNT(le.order_id) AS line_count, COUNT(DISTINCT le.order_id) AS order_count, COUNT(DISTINCT le.customer_id) AS customer_count,
        COUNT(DISTINCT le.book_id) AS book_count, SUM(COALESCE(le.price, 0)) AS total_price, AVG(le.price) AS avg_price
    FROM line_enriched le
    JOIN author_detail_scope s ON le.author_id = s.author_id
    GROUP BY le.author_id, le.author_name, le.title, le.publisher_name
),
ranked_author_title AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY author_id ORDER BY total_price DESC, line_count DESC, item_2) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (PARTITION BY author_id), 0) AS share_pct
    FROM author_title
),
author_language AS (
    SELECT le.author_id, le.author_name, le.language_name AS item_2,
        COUNT(le.order_id) AS line_count, COUNT(DISTINCT le.order_id) AS order_count, COUNT(DISTINCT le.book_id) AS book_count,
        SUM(COALESCE(le.price, 0)) AS total_price, AVG(le.price) AS avg_price
    FROM line_enriched le JOIN author_detail_scope s ON le.author_id = s.author_id
    GROUP BY le.author_id, le.author_name, le.language_name
),
ranked_author_language AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY author_id ORDER BY total_price DESC, line_count DESC, item_2) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (PARTITION BY author_id), 0) AS share_pct
    FROM author_language
),
author_publisher AS (
    SELECT le.author_id, le.author_name, le.publisher_name AS item_2,
        COUNT(le.order_id) AS line_count, COUNT(DISTINCT le.order_id) AS order_count, COUNT(DISTINCT le.book_id) AS book_count,
        SUM(COALESCE(le.price, 0)) AS total_price, AVG(le.price) AS avg_price
    FROM line_enriched le JOIN author_detail_scope s ON le.author_id = s.author_id
    GROUP BY le.author_id, le.author_name, le.publisher_name
),
ranked_author_publisher AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY author_id ORDER BY total_price DESC, line_count DESC, item_2) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (PARTITION BY author_id), 0) AS share_pct
    FROM author_publisher
),
author_collab AS (
    SELECT le.author_id, le.author_name, le.collaboration_bucket AS item_2,
        COUNT(DISTINCT le.book_id) AS book_count, COUNT(le.order_id) AS line_count, COUNT(DISTINCT le.order_id) AS order_count,
        SUM(COALESCE(le.price, 0)) AS total_price, AVG(le.price) AS avg_price
    FROM line_enriched le JOIN author_detail_scope s ON le.author_id = s.author_id
    GROUP BY le.author_id, le.author_name, le.collaboration_bucket
),
ranked_author_collab AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY author_id ORDER BY total_price DESC, line_count DESC, item_2) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (PARTITION BY author_id), 0) AS share_pct
    FROM author_collab
),
author_lifecycle AS (
    SELECT le.author_id, le.author_name, le.lifecycle_bucket AS item_2,
        COUNT(le.order_id) AS line_count, COUNT(DISTINCT le.order_id) AS order_count, COUNT(DISTINCT le.book_id) AS book_count,
        SUM(COALESCE(le.price, 0)) AS total_price, AVG(le.price) AS avg_price
    FROM line_enriched le JOIN author_detail_scope s ON le.author_id = s.author_id
    GROUP BY le.author_id, le.author_name, le.lifecycle_bucket
),
ranked_author_lifecycle AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY author_id ORDER BY order_count DESC, total_price DESC, item_2) AS rank_value,
        100.0 * order_count / NULLIF(SUM(order_count) OVER (PARTITION BY author_id), 0) AS share_pct
    FROM author_lifecycle
),
author_era AS (
    SELECT le.author_id, le.author_name, le.publication_era AS item_2,
        COUNT(DISTINCT le.book_id) AS book_count, COUNT(le.order_id) AS line_count, COUNT(DISTINCT le.order_id) AS order_count,
        SUM(COALESCE(le.price, 0)) AS total_price, AVG(le.price) AS avg_price
    FROM line_enriched le JOIN author_detail_scope s ON le.author_id = s.author_id
    GROUP BY le.author_id, le.author_name, le.publication_era
),
ranked_author_era AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY author_id ORDER BY total_price DESC, line_count DESC, item_2) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (PARTITION BY author_id), 0) AS share_pct
    FROM author_era
)
SELECT 'author_catalog_demand' AS evidence_block, 'author' AS grain, author_name AS item, CAST(author_id AS VARCHAR) AS item_2, CAST(NULL AS VARCHAR) AS item_3,
    'author_value_rank' AS rank_label, CAST(rank_value AS DOUBLE) AS rank_value, catalog_book_count, sold_book_count, line_count, order_count, customer_count,
    publisher_count, language_count, ROUND(total_price, 4) AS total_price, ROUND(avg_price, 4) AS avg_price, ROUND(avg_pages, 4) AS avg_pages, ROUND(share_pct, 4) AS share_pct, 'Author catalog breadth and attributed demand.' AS notes
FROM ranked_author WHERE rank_value <= 100
UNION ALL
SELECT 'author_title_concentration', 'author_title', author_name, item_2, item_3, 'title_rank_within_author', CAST(rank_value AS DOUBLE), book_count, book_count, line_count, order_count, customer_count, CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), ROUND(total_price, 4), ROUND(avg_price, 4), CAST(NULL AS DOUBLE), ROUND(share_pct, 4), 'Title concentration inside top author portfolios.' FROM ranked_author_title WHERE rank_value <= 5
UNION ALL
SELECT 'author_language_mix', 'author_language', author_name, item_2, CAST(NULL AS VARCHAR), 'language_rank_within_author', CAST(rank_value AS DOUBLE), book_count, book_count, line_count, order_count, CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), ROUND(total_price, 4), ROUND(avg_price, 4), CAST(NULL AS DOUBLE), ROUND(share_pct, 4), 'Language mix inside top author portfolios.' FROM ranked_author_language WHERE rank_value <= 5
UNION ALL
SELECT 'author_publisher_mix', 'author_publisher', author_name, item_2, CAST(NULL AS VARCHAR), 'publisher_rank_within_author', CAST(rank_value AS DOUBLE), book_count, book_count, line_count, order_count, CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), ROUND(total_price, 4), ROUND(avg_price, 4), CAST(NULL AS DOUBLE), ROUND(share_pct, 4), 'Publisher spread inside top author portfolios.' FROM ranked_author_publisher WHERE rank_value <= 5
UNION ALL
SELECT 'author_collaboration_role', 'author_collaboration', author_name, item_2, CAST(NULL AS VARCHAR), 'collaboration_rank_within_author', CAST(rank_value AS DOUBLE), book_count, book_count, line_count, order_count, CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), ROUND(total_price, 4), ROUND(avg_price, 4), CAST(NULL AS DOUBLE), ROUND(share_pct, 4), 'Single-author versus multi-author demand inside top author portfolios.' FROM ranked_author_collab
UNION ALL
SELECT 'author_lifecycle_mix', 'author_lifecycle', author_name, item_2, CAST(NULL AS VARCHAR), 'lifecycle_rank_within_author', CAST(rank_value AS DOUBLE), book_count, book_count, line_count, order_count, CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), ROUND(total_price, 4), ROUND(avg_price, 4), CAST(NULL AS DOUBLE), ROUND(share_pct, 4), 'Lifecycle outcomes attached to top author demand.' FROM ranked_author_lifecycle
UNION ALL
SELECT 'author_publication_era_mix', 'author_publication_era', author_name, item_2, CAST(NULL AS VARCHAR), 'era_rank_within_author', CAST(rank_value AS DOUBLE), book_count, book_count, line_count, order_count, CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), ROUND(total_price, 4), ROUND(avg_price, 4), CAST(NULL AS DOUBLE), ROUND(share_pct, 4), 'Publication-era mix inside top author portfolios.' FROM ranked_author_era
ORDER BY evidence_block, rank_value, item, item_2
