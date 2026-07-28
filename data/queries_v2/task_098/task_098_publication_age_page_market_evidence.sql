WITH
status_flags AS (
    SELECT oh.order_id,
        MAX(CASE WHEN os.status_value = 'Delivered' THEN 1 ELSE 0 END) AS has_delivered,
        MAX(CASE WHEN os.status_value = 'Cancelled' THEN 1 ELSE 0 END) AS has_cancelled,
        MAX(CASE WHEN os.status_value = 'Returned' THEN 1 ELSE 0 END) AS has_returned,
        COUNT(DISTINCT os.status_value) AS status_count
    FROM order_history oh JOIN order_status os ON oh.status_id = os.status_id
    GROUP BY oh.order_id
),
book_base AS (
    SELECT b.book_id, b.title, b.num_pages, bl.language_name, p.publisher_name,
        CASE
            WHEN b.num_pages < 200 THEN 'short_book'
            WHEN b.num_pages < 400 THEN 'mid_length_book'
            WHEN b.num_pages < 700 THEN 'long_book'
            ELSE 'very_long_book'
        END AS page_band,
        CASE
            WHEN CAST(SUBSTR(CAST(b.publication_date AS VARCHAR), 1, 4) AS INTEGER) >= 2000 THEN '2000_plus'
            WHEN CAST(SUBSTR(CAST(b.publication_date AS VARCHAR), 1, 4) AS INTEGER) >= 1980 THEN '1980_1999'
            ELSE 'pre_1980'
        END AS publication_era
    FROM book b
    LEFT JOIN book_language bl ON b.language_id = bl.language_id
    LEFT JOIN publisher p ON b.publisher_id = p.publisher_id
),
line_enriched AS (
    SELECT bb.*, ol.order_id, co.customer_id, COALESCE(sm.method_name, 'unknown_shipping') AS method_name, COALESCE(c.country_name, 'unknown_destination') AS country_name, CAST(ol.price AS DOUBLE) AS price,
        CASE
            WHEN ol.order_id IS NULL THEN 'no_observed_order'
            WHEN COALESCE(sf.has_cancelled, 0) = 1 THEN 'cancelled_path'
            WHEN COALESCE(sf.has_returned, 0) = 1 THEN 'returned_path'
            WHEN COALESCE(sf.has_delivered, 0) = 1 THEN 'delivered_path'
            WHEN COALESCE(sf.status_count, 0) = 0 THEN 'no_history'
            ELSE 'incomplete_or_in_progress'
        END AS lifecycle_bucket
    FROM book_base bb
    LEFT JOIN order_line ol ON bb.book_id = ol.book_id
    LEFT JOIN cust_order co ON ol.order_id = co.order_id
    LEFT JOIN shipping_method sm ON co.shipping_method_id = sm.method_id
    LEFT JOIN address a ON co.dest_address_id = a.address_id
    LEFT JOIN country c ON a.country_id = c.country_id
    LEFT JOIN status_flags sf ON ol.order_id = sf.order_id
),
era_page AS (
    SELECT publication_era AS item, page_band AS item_2, COUNT(DISTINCT book_id) AS catalog_book_count,
        COUNT(DISTINCT CASE WHEN order_id IS NOT NULL THEN book_id END) AS sold_book_count,
        COUNT(order_id) AS line_count, COUNT(DISTINCT order_id) AS order_count, COUNT(DISTINCT customer_id) AS customer_count,
        SUM(COALESCE(price, 0)) AS total_price, AVG(price) AS avg_price, AVG(num_pages) AS avg_pages
    FROM line_enriched GROUP BY publication_era, page_band
),
ranked_era_page AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY total_price DESC, line_count DESC, item, item_2) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (), 0) AS share_pct FROM era_page
),
era_language AS (
    SELECT publication_era AS item, language_name AS item_2, COUNT(DISTINCT book_id) AS catalog_book_count,
        COUNT(DISTINCT CASE WHEN order_id IS NOT NULL THEN book_id END) AS sold_book_count,
        COUNT(order_id) AS line_count, COUNT(DISTINCT order_id) AS order_count, SUM(COALESCE(price, 0)) AS total_price, AVG(price) AS avg_price
    FROM line_enriched GROUP BY publication_era, language_name
),
ranked_era_language AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY item ORDER BY total_price DESC, line_count DESC, item_2) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (PARTITION BY item), 0) AS share_pct FROM era_language
),
era_destination AS (
    SELECT publication_era AS item, country_name AS item_2, COUNT(DISTINCT book_id) AS sold_book_count,
        COUNT(order_id) AS line_count, COUNT(DISTINCT order_id) AS order_count, COUNT(DISTINCT customer_id) AS customer_count,
        SUM(COALESCE(price, 0)) AS total_price, AVG(price) AS avg_price
    FROM line_enriched GROUP BY publication_era, country_name
),
ranked_era_destination AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY item ORDER BY total_price DESC, line_count DESC, item_2) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (PARTITION BY item), 0) AS share_pct FROM era_destination
),
era_lifecycle AS (
    SELECT publication_era AS item, lifecycle_bucket AS item_2, COUNT(DISTINCT book_id) AS sold_book_count,
        COUNT(order_id) AS line_count, COUNT(DISTINCT order_id) AS order_count, SUM(COALESCE(price, 0)) AS total_price, AVG(price) AS avg_price
    FROM line_enriched GROUP BY publication_era, lifecycle_bucket
),
ranked_era_lifecycle AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY item ORDER BY order_count DESC, total_price DESC, item_2) AS rank_value,
        100.0 * order_count / NULLIF(SUM(order_count) OVER (PARTITION BY item), 0) AS share_pct FROM era_lifecycle
),
page_shipping AS (
    SELECT page_band AS item, method_name AS item_2, COUNT(DISTINCT book_id) AS sold_book_count,
        COUNT(order_id) AS line_count, COUNT(DISTINCT order_id) AS order_count, SUM(COALESCE(price, 0)) AS total_price, AVG(price) AS avg_price
    FROM line_enriched GROUP BY page_band, method_name
),
ranked_page_shipping AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY item ORDER BY total_price DESC, line_count DESC, item_2) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (PARTITION BY item), 0) AS share_pct FROM page_shipping
),
era_title AS (
    SELECT publication_era AS item, title AS item_2, publisher_name AS item_3, COUNT(order_id) AS line_count,
        COUNT(DISTINCT order_id) AS order_count, SUM(COALESCE(price, 0)) AS total_price, AVG(price) AS avg_price
    FROM line_enriched GROUP BY publication_era, title, publisher_name
),
ranked_era_title AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY item ORDER BY total_price DESC, line_count DESC, item_2) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (PARTITION BY item), 0) AS share_pct FROM era_title
),
era_publisher AS (
    SELECT publication_era AS item, publisher_name AS item_2, COUNT(DISTINCT book_id) AS catalog_book_count,
        COUNT(DISTINCT CASE WHEN order_id IS NOT NULL THEN book_id END) AS sold_book_count,
        COUNT(order_id) AS line_count, COUNT(DISTINCT order_id) AS order_count, SUM(COALESCE(price, 0)) AS total_price, AVG(price) AS avg_price
    FROM line_enriched GROUP BY publication_era, publisher_name
),
ranked_era_publisher AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY item ORDER BY total_price DESC, line_count DESC, item_2) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (PARTITION BY item), 0) AS share_pct FROM era_publisher
)
SELECT 'era_page_demand' AS evidence_block, 'era_page_band' AS grain, item, item_2, CAST(NULL AS VARCHAR) AS item_3,
    'era_page_value_rank' AS rank_label, CAST(rank_value AS DOUBLE) AS rank_value, catalog_book_count, sold_book_count, line_count, order_count, customer_count,
    ROUND(total_price, 4) AS total_price, ROUND(avg_price, 4) AS avg_price, ROUND(avg_pages, 4) AS secondary_value, ROUND(share_pct, 4) AS share_pct,
    'Publication era and page-length interaction baseline.' AS notes FROM ranked_era_page
UNION ALL
SELECT 'era_language_mix', 'era_language', item, item_2, CAST(NULL AS VARCHAR), 'language_rank_within_era', CAST(rank_value AS DOUBLE), catalog_book_count, sold_book_count, line_count, order_count, CAST(NULL AS BIGINT), ROUND(total_price, 4), ROUND(avg_price, 4), CAST(NULL AS DOUBLE), ROUND(share_pct, 4), 'Language mix within publication eras.' FROM ranked_era_language WHERE rank_value <= 8
UNION ALL
SELECT 'era_destination_mix', 'era_destination', item, item_2, CAST(NULL AS VARCHAR), 'country_rank_within_era', CAST(rank_value AS DOUBLE), CAST(NULL AS BIGINT), sold_book_count, line_count, order_count, customer_count, ROUND(total_price, 4), ROUND(avg_price, 4), CAST(NULL AS DOUBLE), ROUND(share_pct, 4), 'Destination-country mix within publication eras.' FROM ranked_era_destination WHERE rank_value <= 10
UNION ALL
SELECT 'era_lifecycle_mix', 'era_lifecycle', item, item_2, CAST(NULL AS VARCHAR), 'lifecycle_rank_within_era', CAST(rank_value AS DOUBLE), CAST(NULL AS BIGINT), sold_book_count, line_count, order_count, CAST(NULL AS BIGINT), ROUND(total_price, 4), ROUND(avg_price, 4), CAST(NULL AS DOUBLE), ROUND(share_pct, 4), 'Lifecycle outcomes within publication eras.' FROM ranked_era_lifecycle
UNION ALL
SELECT 'page_band_shipping_mix', 'page_band_shipping', item, item_2, CAST(NULL AS VARCHAR), 'shipping_rank_within_page_band', CAST(rank_value AS DOUBLE), CAST(NULL AS BIGINT), sold_book_count, line_count, order_count, CAST(NULL AS BIGINT), ROUND(total_price, 4), ROUND(avg_price, 4), CAST(NULL AS DOUBLE), ROUND(share_pct, 4), 'Shipping mix by page-length band.' FROM ranked_page_shipping
UNION ALL
SELECT 'top_titles_by_era', 'era_title', item, item_2, item_3, 'title_rank_within_era', CAST(rank_value AS DOUBLE), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), line_count, order_count, CAST(NULL AS BIGINT), ROUND(total_price, 4), ROUND(avg_price, 4), CAST(NULL AS DOUBLE), ROUND(share_pct, 4), 'Top titles inside each publication era.' FROM ranked_era_title WHERE rank_value <= 10
UNION ALL
SELECT 'publisher_era_role', 'era_publisher', item, item_2, CAST(NULL AS VARCHAR), 'publisher_rank_within_era', CAST(rank_value AS DOUBLE), catalog_book_count, sold_book_count, line_count, order_count, CAST(NULL AS BIGINT), ROUND(total_price, 4), ROUND(avg_price, 4), CAST(NULL AS DOUBLE), ROUND(share_pct, 4), 'Publisher roles within each publication era.' FROM ranked_era_publisher WHERE rank_value <= 10
ORDER BY evidence_block, item, rank_value
