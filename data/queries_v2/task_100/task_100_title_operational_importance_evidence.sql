WITH
book_author_count AS (
    SELECT book_id, COUNT(DISTINCT author_id) AS author_count
    FROM book_author GROUP BY book_id
),
status_flags AS (
    SELECT oh.order_id,
        MAX(CASE WHEN os.status_value = 'Delivered' THEN 1 ELSE 0 END) AS has_delivered,
        MAX(CASE WHEN os.status_value = 'Cancelled' THEN 1 ELSE 0 END) AS has_cancelled,
        MAX(CASE WHEN os.status_value = 'Returned' THEN 1 ELSE 0 END) AS has_returned,
        COUNT(DISTINCT os.status_value) AS status_count
    FROM order_history oh JOIN order_status os ON oh.status_id = os.status_id
    GROUP BY oh.order_id
),
line_enriched AS (
    SELECT b.book_id, b.title, p.publisher_name, bl.language_name, COALESCE(bac.author_count, 0) AS author_count,
        b.num_pages,
        CASE WHEN b.num_pages < 200 THEN 'short_book' WHEN b.num_pages < 400 THEN 'mid_length_book' WHEN b.num_pages < 700 THEN 'long_book' ELSE 'very_long_book' END AS page_band,
        CASE WHEN CAST(SUBSTR(CAST(b.publication_date AS VARCHAR), 1, 4) AS INTEGER) >= 2000 THEN '2000_plus' WHEN CAST(SUBSTR(CAST(b.publication_date AS VARCHAR), 1, 4) AS INTEGER) >= 1980 THEN '1980_1999' ELSE 'pre_1980' END AS publication_era,
        ol.order_id, co.customer_id, COALESCE(sm.method_name, 'unknown_shipping') AS method_name, COALESCE(c.country_name, 'unknown_destination') AS country_name, CAST(ol.price AS DOUBLE) AS price,
        CASE WHEN ol.order_id IS NULL THEN 'no_observed_order' WHEN COALESCE(sf.has_cancelled, 0) = 1 THEN 'cancelled_path' WHEN COALESCE(sf.has_returned, 0) = 1 THEN 'returned_path' WHEN COALESCE(sf.has_delivered, 0) = 1 THEN 'delivered_path' WHEN COALESCE(sf.status_count, 0) = 0 THEN 'no_history' ELSE 'incomplete_or_in_progress' END AS lifecycle_bucket
    FROM book b
    LEFT JOIN publisher p ON b.publisher_id = p.publisher_id
    LEFT JOIN book_language bl ON b.language_id = bl.language_id
    LEFT JOIN book_author_count bac ON b.book_id = bac.book_id
    LEFT JOIN order_line ol ON b.book_id = ol.book_id
    LEFT JOIN cust_order co ON ol.order_id = co.order_id
    LEFT JOIN shipping_method sm ON co.shipping_method_id = sm.method_id
    LEFT JOIN address a ON co.dest_address_id = a.address_id
    LEFT JOIN country c ON a.country_id = c.country_id
    LEFT JOIN status_flags sf ON ol.order_id = sf.order_id
),
title_base AS (
    SELECT book_id, title, publisher_name, language_name, publication_era, page_band, author_count, num_pages,
        COUNT(order_id) AS line_count, COUNT(DISTINCT order_id) AS order_count, COUNT(DISTINCT customer_id) AS customer_count,
        SUM(COALESCE(price, 0)) AS total_price, AVG(price) AS avg_price,
        COUNT(DISTINCT method_name) AS shipping_method_count, COUNT(DISTINCT country_name) AS country_count
    FROM line_enriched GROUP BY book_id, title, publisher_name, language_name, publication_era, page_band, author_count, num_pages
),
ranked_title AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY total_price DESC, line_count DESC, title) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (), 0) AS share_pct
    FROM title_base
),
top_scope AS (SELECT book_id FROM ranked_title WHERE rank_value <= 100),
title_lifecycle AS (
    SELECT le.book_id, le.title AS item, le.lifecycle_bucket AS item_2, COUNT(le.order_id) AS order_count, COUNT(DISTINCT le.customer_id) AS customer_count,
        SUM(COALESCE(le.price, 0)) AS total_price, AVG(le.price) AS avg_price
    FROM line_enriched le JOIN top_scope s ON le.book_id = s.book_id
    GROUP BY le.book_id, le.title, le.lifecycle_bucket
),
ranked_title_lifecycle AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY book_id ORDER BY order_count DESC, total_price DESC, item_2) AS rank_value,
        100.0 * order_count / NULLIF(SUM(order_count) OVER (PARTITION BY book_id), 0) AS share_pct FROM title_lifecycle
),
title_shipping AS (
    SELECT le.book_id, le.title AS item, le.method_name AS item_2, COUNT(le.order_id) AS order_count, COUNT(DISTINCT le.customer_id) AS customer_count,
        SUM(COALESCE(le.price, 0)) AS total_price, AVG(le.price) AS avg_price
    FROM line_enriched le JOIN top_scope s ON le.book_id = s.book_id
    GROUP BY le.book_id, le.title, le.method_name
),
ranked_title_shipping AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY book_id ORDER BY total_price DESC, order_count DESC, item_2) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (PARTITION BY book_id), 0) AS share_pct FROM title_shipping
),
title_country AS (
    SELECT le.book_id, le.title AS item, le.country_name AS item_2, COUNT(le.order_id) AS order_count, COUNT(DISTINCT le.customer_id) AS customer_count,
        SUM(COALESCE(le.price, 0)) AS total_price, AVG(le.price) AS avg_price
    FROM line_enriched le JOIN top_scope s ON le.book_id = s.book_id
    GROUP BY le.book_id, le.title, le.country_name
),
ranked_title_country AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY book_id ORDER BY total_price DESC, order_count DESC, item_2) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (PARTITION BY book_id), 0) AS share_pct FROM title_country
),
metadata_profile AS (
    SELECT language_name AS item, publication_era AS item_2, page_band AS item_3, COUNT(DISTINCT book_id) AS catalog_book_count,
        COUNT(DISTINCT CASE WHEN order_count > 0 THEN book_id END) AS sold_book_count, SUM(line_count) AS line_count, SUM(order_count) AS order_count,
        SUM(customer_count) AS customer_count, SUM(total_price) AS total_price, AVG(avg_price) AS avg_price
    FROM title_base GROUP BY language_name, publication_era, page_band
),
ranked_metadata AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY total_price DESC, line_count DESC, item, item_2, item_3) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (), 0) AS share_pct FROM metadata_profile
),
author_complexity AS (
    SELECT CASE WHEN author_count = 0 THEN 'no_author_link' WHEN author_count = 1 THEN 'single_author_title' WHEN author_count <= 3 THEN 'small_team_title' ELSE 'large_team_title' END AS item,
        COUNT(DISTINCT book_id) AS catalog_book_count, COUNT(DISTINCT CASE WHEN order_count > 0 THEN book_id END) AS sold_book_count,
        SUM(line_count) AS line_count, SUM(order_count) AS order_count, SUM(customer_count) AS customer_count, SUM(total_price) AS total_price, AVG(avg_price) AS avg_price
    FROM title_base GROUP BY 1
),
ranked_author_complexity AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY total_price DESC, line_count DESC, item) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (), 0) AS share_pct FROM author_complexity
),
customer_breadth_bucket AS (
    SELECT CASE WHEN customer_count >= 5 THEN 'broad_customer_reach' WHEN customer_count >= 2 THEN 'some_repeat_or_multi_customer_reach' WHEN customer_count = 1 THEN 'single_customer_reach' ELSE 'no_observed_customer' END AS item,
        COUNT(DISTINCT book_id) AS catalog_book_count, COUNT(DISTINCT CASE WHEN order_count > 0 THEN book_id END) AS sold_book_count,
        SUM(line_count) AS line_count, SUM(order_count) AS order_count, SUM(customer_count) AS customer_count, SUM(total_price) AS total_price, AVG(avg_price) AS avg_price
    FROM title_base GROUP BY 1
),
ranked_customer_breadth AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY total_price DESC, line_count DESC, item) AS rank_value,
        100.0 * total_price / NULLIF(SUM(total_price) OVER (), 0) AS share_pct FROM customer_breadth_bucket
)
SELECT 'title_operational_baseline' AS evidence_block, 'title' AS grain, title AS item, publisher_name AS item_2, language_name AS item_3,
    'title_value_rank' AS rank_label, CAST(rank_value AS DOUBLE) AS rank_value, 1 AS catalog_book_count, CASE WHEN order_count > 0 THEN 1 ELSE 0 END AS sold_book_count,
    line_count, order_count, customer_count, ROUND(total_price, 4) AS total_price, ROUND(avg_price, 4) AS avg_price, CAST(num_pages AS DOUBLE) AS secondary_value,
    ROUND(share_pct, 4) AS share_pct, 'Top titles by observed order value with catalog metadata.' AS notes FROM ranked_title WHERE rank_value <= 100
UNION ALL
SELECT 'title_lifecycle_mix', 'title_lifecycle', item, item_2, CAST(NULL AS VARCHAR), 'lifecycle_rank_within_title', CAST(rank_value AS DOUBLE), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), order_count, order_count, customer_count, ROUND(total_price, 4), ROUND(avg_price, 4), CAST(NULL AS DOUBLE), ROUND(share_pct, 4), 'Lifecycle mix for top observed titles.' FROM ranked_title_lifecycle
UNION ALL
SELECT 'title_shipping_mix', 'title_shipping', item, item_2, CAST(NULL AS VARCHAR), 'shipping_rank_within_title', CAST(rank_value AS DOUBLE), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), order_count, order_count, customer_count, ROUND(total_price, 4), ROUND(avg_price, 4), CAST(NULL AS DOUBLE), ROUND(share_pct, 4), 'Shipping mix for top observed titles.' FROM ranked_title_shipping
UNION ALL
SELECT 'title_country_mix', 'title_country', item, item_2, CAST(NULL AS VARCHAR), 'country_rank_within_title', CAST(rank_value AS DOUBLE), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), order_count, order_count, customer_count, ROUND(total_price, 4), ROUND(avg_price, 4), CAST(NULL AS DOUBLE), ROUND(share_pct, 4), 'Destination-country mix for top observed titles.' FROM ranked_title_country WHERE rank_value <= 5
UNION ALL
SELECT 'metadata_demand_profile', 'metadata_profile', item, item_2, item_3, 'metadata_value_rank', CAST(rank_value AS DOUBLE), catalog_book_count, sold_book_count, line_count, order_count, customer_count, ROUND(total_price, 4), ROUND(avg_price, 4), CAST(NULL AS DOUBLE), ROUND(share_pct, 4), 'Language, publication-era, and page-band context for title demand.' FROM ranked_metadata WHERE rank_value <= 40
UNION ALL
SELECT 'author_complexity_profile', 'author_complexity', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), 'author_complexity_value_rank', CAST(rank_value AS DOUBLE), catalog_book_count, sold_book_count, line_count, order_count, customer_count, ROUND(total_price, 4), ROUND(avg_price, 4), CAST(NULL AS DOUBLE), ROUND(share_pct, 4), 'Title demand by number of linked authors.' FROM ranked_author_complexity
UNION ALL
SELECT 'customer_breadth_profile', 'customer_breadth', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), 'customer_breadth_value_rank', CAST(rank_value AS DOUBLE), catalog_book_count, sold_book_count, line_count, order_count, customer_count, ROUND(total_price, 4), ROUND(avg_price, 4), CAST(NULL AS DOUBLE), ROUND(share_pct, 4), 'Whether title demand comes from broad or narrow customer reach.' FROM ranked_customer_breadth
ORDER BY evidence_block, rank_value, item, item_2
