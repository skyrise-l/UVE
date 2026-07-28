WITH
sales_by_book AS (
    SELECT
        book_id,
        COUNT(*) AS line_count,
        COUNT(DISTINCT order_id) AS order_count,
        SUM(CAST(price AS DOUBLE)) AS total_price,
        AVG(CAST(price AS DOUBLE)) AS avg_price
    FROM order_line
    GROUP BY book_id
),
author_count AS (
    SELECT
        book_id,
        COUNT(DISTINCT author_id) AS author_count
    FROM book_author
    GROUP BY book_id
),
book_base AS (
    SELECT
        b.book_id,
        b.title,
        p.publisher_name,
        bl.language_name,
        CAST(b.num_pages AS DOUBLE) AS num_pages,
        SUBSTR(CAST(b.publication_date AS VARCHAR), 1, 4) AS pub_year,
        CASE
            WHEN CAST(b.num_pages AS DOUBLE) < 200 THEN 'short_book'
            WHEN CAST(b.num_pages AS DOUBLE) < 400 THEN 'mid_length_book'
            WHEN CAST(b.num_pages AS DOUBLE) < 700 THEN 'long_book'
            ELSE 'very_long_book'
        END AS page_band,
        CASE
            WHEN SUBSTR(CAST(b.publication_date AS VARCHAR), 1, 4) < '1980' THEN 'pre_1980'
            WHEN SUBSTR(CAST(b.publication_date AS VARCHAR), 1, 4) < '2000' THEN '1980_1999'
            ELSE '2000_plus'
        END AS publication_era,
        COALESCE(ac.author_count, 0) AS author_count,
        COALESCE(sbb.line_count, 0) AS line_count,
        COALESCE(sbb.order_count, 0) AS order_count,
        COALESCE(sbb.total_price, 0) AS total_price,
        sbb.avg_price
    FROM book b
    LEFT JOIN publisher p ON b.publisher_id = p.publisher_id
    LEFT JOIN book_language bl ON b.language_id = bl.language_id
    LEFT JOIN author_count ac ON b.book_id = ac.book_id
    LEFT JOIN sales_by_book sbb ON b.book_id = sbb.book_id
),
language_summary AS (
    SELECT
        language_name AS item,
        COUNT(*) AS catalog_book_count,
        COUNT(CASE WHEN line_count > 0 THEN 1 END) AS sold_book_count,
        SUM(line_count) AS line_count,
        SUM(order_count) AS order_count,
        SUM(total_price) AS total_price,
        AVG(avg_price) AS avg_price,
        AVG(num_pages) AS avg_pages,
        AVG(author_count) AS avg_author_count,
        COUNT(DISTINCT publisher_name) AS publisher_count
    FROM book_base
    GROUP BY language_name
),
publisher_summary AS (
    SELECT
        publisher_name AS item,
        COUNT(*) AS catalog_book_count,
        COUNT(CASE WHEN line_count > 0 THEN 1 END) AS sold_book_count,
        SUM(line_count) AS line_count,
        SUM(order_count) AS order_count,
        SUM(total_price) AS total_price,
        AVG(avg_price) AS avg_price,
        AVG(num_pages) AS avg_pages,
        AVG(author_count) AS avg_author_count,
        COUNT(DISTINCT language_name) AS language_count
    FROM book_base
    GROUP BY publisher_name
),
era_summary AS (
    SELECT
        publication_era AS item,
        COUNT(*) AS catalog_book_count,
        COUNT(CASE WHEN line_count > 0 THEN 1 END) AS sold_book_count,
        SUM(line_count) AS line_count,
        SUM(order_count) AS order_count,
        SUM(total_price) AS total_price,
        AVG(avg_price) AS avg_price,
        AVG(num_pages) AS avg_pages,
        AVG(author_count) AS avg_author_count
    FROM book_base
    GROUP BY publication_era
),
page_summary AS (
    SELECT
        page_band AS item,
        COUNT(*) AS catalog_book_count,
        COUNT(CASE WHEN line_count > 0 THEN 1 END) AS sold_book_count,
        SUM(line_count) AS line_count,
        SUM(order_count) AS order_count,
        SUM(total_price) AS total_price,
        AVG(avg_price) AS avg_price,
        AVG(num_pages) AS avg_pages,
        AVG(author_count) AS avg_author_count
    FROM book_base
    GROUP BY page_band
),
author_summary AS (
    SELECT
        CAST(author_count AS VARCHAR) AS item,
        COUNT(*) AS catalog_book_count,
        COUNT(CASE WHEN line_count > 0 THEN 1 END) AS sold_book_count,
        SUM(line_count) AS line_count,
        SUM(order_count) AS order_count,
        SUM(total_price) AS total_price,
        AVG(avg_price) AS avg_price,
        AVG(num_pages) AS avg_pages,
        AVG(author_count) AS avg_author_count
    FROM book_base
    GROUP BY author_count
),
coverage_summary AS (
    SELECT
        CASE WHEN line_count > 0 THEN 'ordered_catalog' ELSE 'unordered_catalog' END AS item,
        COUNT(*) AS catalog_book_count,
        COUNT(CASE WHEN line_count > 0 THEN 1 END) AS sold_book_count,
        SUM(line_count) AS line_count,
        SUM(order_count) AS order_count,
        SUM(total_price) AS total_price,
        AVG(avg_price) AS avg_price,
        AVG(num_pages) AS avg_pages,
        AVG(author_count) AS avg_author_count,
        COUNT(DISTINCT publisher_name) AS publisher_count,
        COUNT(DISTINCT language_name) AS language_count
    FROM book_base
    GROUP BY CASE WHEN line_count > 0 THEN 'ordered_catalog' ELSE 'unordered_catalog' END
),
ranked_title AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY total_price DESC, line_count DESC, title) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (), 0) AS share_pct
    FROM book_base
),
ranked_language AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY total_price DESC, catalog_book_count DESC, item) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (), 0) AS share_pct
    FROM language_summary
),
ranked_publisher AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY total_price DESC, catalog_book_count DESC, item) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (), 0) AS share_pct
    FROM publisher_summary
),
ranked_era AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY total_price DESC, catalog_book_count DESC, item) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (), 0) AS share_pct
    FROM era_summary
),
ranked_page AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY total_price DESC, catalog_book_count DESC, item) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (), 0) AS share_pct
    FROM page_summary
),
ranked_author AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY total_price DESC, catalog_book_count DESC, item) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (), 0) AS share_pct
    FROM author_summary
),
ranked_coverage AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY catalog_book_count DESC, total_price DESC, item) AS rank_value,
        100.0 * catalog_book_count / NULLIF(SUM(catalog_book_count) OVER (), 0) AS share_pct
    FROM coverage_summary
)
SELECT
    'catalog_language_baseline' AS evidence_block,
    'language' AS grain,
    item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'language_value_rank' AS rank_label,
    CAST(rank_value AS DOUBLE) AS rank_value,
    catalog_book_count,
    sold_book_count,
    line_count,
    order_count,
    ROUND(total_price, 4) AS total_price,
    ROUND(avg_price, 4) AS avg_price,
    ROUND(avg_pages, 4) AS avg_pages,
    ROUND(avg_author_count, 4) AS author_count,
    publisher_count,
    CAST(NULL AS BIGINT) AS language_count,
    ROUND(share_pct, 4) AS share_pct,
    CAST(NULL AS DOUBLE) AS secondary_value,
    'Catalog and order-value baseline by language.' AS notes
FROM ranked_language
UNION ALL
SELECT
    'publisher_catalog_demand',
    'publisher',
    item,
    CAST(NULL AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'publisher_value_rank',
    CAST(rank_value AS DOUBLE),
    catalog_book_count,
    sold_book_count,
    line_count,
    order_count,
    ROUND(total_price, 4),
    ROUND(avg_price, 4),
    ROUND(avg_pages, 4),
    ROUND(avg_author_count, 4),
    CAST(NULL AS BIGINT),
    language_count,
    ROUND(share_pct, 4),
    CAST(NULL AS DOUBLE),
    'Publisher catalog breadth checked against order value.'
FROM ranked_publisher
UNION ALL
SELECT
    'publication_era_demand',
    'publication_era',
    item,
    CAST(NULL AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'era_value_rank',
    CAST(rank_value AS DOUBLE),
    catalog_book_count,
    sold_book_count,
    line_count,
    order_count,
    ROUND(total_price, 4),
    ROUND(avg_price, 4),
    ROUND(avg_pages, 4),
    ROUND(avg_author_count, 4),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    ROUND(share_pct, 4),
    CAST(NULL AS DOUBLE),
    'Publication-era demand and catalog mix.'
FROM ranked_era
UNION ALL
SELECT
    'page_band_demand',
    'page_band',
    item,
    CAST(NULL AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'page_band_value_rank',
    CAST(rank_value AS DOUBLE),
    catalog_book_count,
    sold_book_count,
    line_count,
    order_count,
    ROUND(total_price, 4),
    ROUND(avg_price, 4),
    ROUND(avg_pages, 4),
    ROUND(avg_author_count, 4),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    ROUND(share_pct, 4),
    CAST(NULL AS DOUBLE),
    'Page-count band checked against order value and coverage.'
FROM ranked_page
UNION ALL
SELECT
    'author_count_demand',
    'author_count',
    item,
    CAST(NULL AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'author_count_value_rank',
    CAST(rank_value AS DOUBLE),
    catalog_book_count,
    sold_book_count,
    line_count,
    order_count,
    ROUND(total_price, 4),
    ROUND(avg_price, 4),
    ROUND(avg_pages, 4),
    ROUND(avg_author_count, 4),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    ROUND(share_pct, 4),
    CAST(NULL AS DOUBLE),
    'Single-author and multi-author catalog demand comparison.'
FROM ranked_author
UNION ALL
SELECT
    'sold_unsold_catalog_coverage',
    'coverage_bucket',
    item,
    CAST(NULL AS VARCHAR),
    CAST(NULL AS VARCHAR),
    'coverage_book_rank',
    CAST(rank_value AS DOUBLE),
    catalog_book_count,
    sold_book_count,
    line_count,
    order_count,
    ROUND(total_price, 4),
    ROUND(avg_price, 4),
    ROUND(avg_pages, 4),
    ROUND(avg_author_count, 4),
    publisher_count,
    language_count,
    ROUND(share_pct, 4),
    CAST(NULL AS DOUBLE),
    'Ordered versus unordered catalog coverage.'
FROM ranked_coverage
UNION ALL
SELECT
    'top_title_demand',
    'title',
    title,
    publisher_name,
    language_name,
    'title_value_rank',
    CAST(rank_value AS DOUBLE),
    CAST(1 AS BIGINT),
    CASE WHEN line_count > 0 THEN 1 ELSE 0 END,
    line_count,
    order_count,
    ROUND(total_price, 4),
    ROUND(avg_price, 4),
    ROUND(num_pages, 4),
    CAST(author_count AS DOUBLE),
    CAST(NULL AS BIGINT),
    CAST(NULL AS BIGINT),
    ROUND(share_pct, 4),
    CAST(pub_year AS DOUBLE),
    'Title-level demand for identifying concentrated or anomalous catalog pockets.'
FROM ranked_title
WHERE line_count > 0 OR rank_value <= 20
ORDER BY evidence_block, rank_value, item;
