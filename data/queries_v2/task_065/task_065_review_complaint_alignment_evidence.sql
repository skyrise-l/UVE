WITH
complaint_fact AS (
    SELECT
        e."Complaint ID" AS complaint_id,
        e.Client_ID AS client_id,
        e."Date received" AS complaint_date,
        e.Product AS complaint_product,
        e.Issue AS issue,
        COALESCE(e."Submitted via", 'unknown') AS submitted_via,
        COALESCE(e."Company response to consumer", 'unknown') AS company_response,
        COALESCE(e."Timely response?", 'unknown') AS timely_response,
        COALESCE(e."Consumer disputed?", 'unknown') AS consumer_disputed,
        c.district_id,
        COALESCE(d.city, 'unknown') AS district_city,
        COALESCE(d.state_abbrev, 'unknown') AS state_code,
        COALESCE(d.division, 'unknown') AS division,
        COALESCE(s.Region, 'unknown') AS region,
        date_diff('day', e."Date received", try_strptime(CAST(e."Date sent to company" AS VARCHAR), '%Y-%m-%d')) AS sent_delay_days,
        CASE WHEN COALESCE(e."Consumer disputed?", 'No') = 'Yes' THEN 1 ELSE 0 END AS disputed_flag,
        CASE WHEN COALESCE(e."Timely response?", 'No') <> 'Yes' THEN 1 ELSE 0 END AS untimely_flag,
        CASE WHEN e."Company response to consumer" = 'Closed without relief' THEN 1 ELSE 0 END AS no_relief_flag
    FROM events e
    LEFT JOIN client c ON e.Client_ID = c.client_id
    LEFT JOIN district d ON c.district_id = d.district_id
    LEFT JOIN state s ON d.state_abbrev = s.StateCode
),
review_fact AS (
    SELECT
        r."Date" AS review_date,
        r.Stars AS stars,
        r.Product AS review_product,
        r.district_id,
        COALESCE(d.city, 'unknown') AS district_city,
        COALESCE(d.state_abbrev, 'unknown') AS state_code,
        COALESCE(d.division, 'unknown') AS division,
        COALESCE(s.Region, 'unknown') AS region
    FROM reviews r
    LEFT JOIN district d ON r.district_id = d.district_id
    LEFT JOIN state s ON d.state_abbrev = s.StateCode
),
complaint_total AS (
    SELECT COUNT(*) AS total_complaints FROM complaint_fact
),
review_total AS (
    SELECT COUNT(*) AS total_reviews FROM review_fact
),
review_product AS (
    SELECT
        review_product AS item,
        COUNT(*) AS reviews,
        COUNT(DISTINCT district_id) AS districts,
        AVG(stars) AS avg_stars,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, review_product) AS volume_rank
    FROM review_fact
    GROUP BY review_product
),
complaint_product AS (
    SELECT
        complaint_product AS item,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, complaint_product) AS volume_rank
    FROM complaint_fact
    GROUP BY complaint_product
),
district_review AS (
    SELECT
        CAST(district_id AS VARCHAR) AS item,
        district_city AS item_2,
        region AS item_3,
        COUNT(*) AS reviews,
        COUNT(DISTINCT review_product) AS review_products,
        AVG(stars) AS avg_stars,
        ROW_NUMBER() OVER (ORDER BY AVG(stars) ASC, COUNT(*) DESC, district_id) AS low_rating_rank
    FROM review_fact
    GROUP BY district_id, district_city, region
),
district_complaint AS (
    SELECT
        CAST(district_id AS VARCHAR) AS item,
        district_city AS item_2,
        region AS item_3,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT complaint_product) AS complaint_products,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, district_id) AS volume_rank
    FROM complaint_fact
    GROUP BY district_id, district_city, region
),
district_alignment AS (
    SELECT
        dc.item,
        dc.item_2,
        dc.item_3,
        dc.complaints,
        dc.clients,
        dc.complaint_products,
        dc.avg_sent_delay_days,
        dc.disputed_count,
        dc.untimely_count,
        dc.no_relief_count,
        COALESCE(dr.reviews, 0) AS reviews,
        dr.avg_stars,
        dr.review_products,
        ROW_NUMBER() OVER (ORDER BY dc.complaints DESC, dc.item) AS complaint_rank
    FROM district_complaint dc
    LEFT JOIN district_review dr ON dc.item = dr.item
),
region_review AS (
    SELECT
        region AS item,
        COUNT(*) AS reviews,
        COUNT(DISTINCT district_id) AS districts,
        AVG(stars) AS avg_stars
    FROM review_fact
    GROUP BY region
),
region_complaint AS (
    SELECT
        region AS item,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count
    FROM complaint_fact
    GROUP BY region
),
region_alignment AS (
    SELECT
        rc.item,
        rc.complaints,
        rc.clients,
        rc.districts,
        rc.avg_sent_delay_days,
        rc.disputed_count,
        rc.untimely_count,
        rc.no_relief_count,
        COALESCE(rr.reviews, 0) AS reviews,
        rr.avg_stars,
        ROW_NUMBER() OVER (ORDER BY rc.complaints DESC, rc.item) AS complaint_rank
    FROM region_complaint rc
    LEFT JOIN region_review rr ON rc.item = rr.item
),
low_review_district AS (
    SELECT item
    FROM district_review
    WHERE low_rating_rank <= 25
),
low_review_issue AS (
    SELECT
        cf.issue AS item,
        COUNT(*) AS complaints,
        COUNT(DISTINCT cf.client_id) AS clients,
        COUNT(DISTINCT cf.district_id) AS districts,
        AVG(cf.sent_delay_days) AS avg_sent_delay_days,
        SUM(cf.disputed_flag) AS disputed_count,
        SUM(cf.untimely_flag) AS untimely_count,
        SUM(cf.no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, cf.issue) AS volume_rank
    FROM complaint_fact cf
    JOIN low_review_district lrd ON CAST(cf.district_id AS VARCHAR) = lrd.item
    GROUP BY cf.issue
),
low_review_product AS (
    SELECT
        cf.complaint_product AS item,
        COUNT(*) AS complaints,
        COUNT(DISTINCT cf.client_id) AS clients,
        COUNT(DISTINCT cf.district_id) AS districts,
        AVG(cf.sent_delay_days) AS avg_sent_delay_days,
        SUM(cf.disputed_flag) AS disputed_count,
        SUM(cf.untimely_flag) AS untimely_count,
        SUM(cf.no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, cf.complaint_product) AS volume_rank
    FROM complaint_fact cf
    JOIN low_review_district lrd ON CAST(cf.district_id AS VARCHAR) = lrd.item
    GROUP BY cf.complaint_product
)
SELECT
    'review_product_baseline' AS evidence_block,
    'review_product' AS grain,
    item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'review_product_volume_rank' AS rank_label,
    CAST(volume_rank AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS complaints,
    CAST(NULL AS BIGINT) AS clients,
    reviews,
    districts,
    ROUND(avg_stars, 4) AS avg_stars,
    CAST(NULL AS DOUBLE) AS avg_sent_delay_days,
    CAST(NULL AS DOUBLE) AS dispute_rate_pct,
    CAST(NULL AS DOUBLE) AS untimely_rate_pct,
    CAST(NULL AS DOUBLE) AS no_relief_rate_pct,
    CAST(NULL AS DOUBLE) AS complaint_share_pct,
    ROUND(100.0 * reviews / NULLIF((SELECT total_reviews FROM review_total), 0), 4) AS review_share_pct,
    'Describe review-side product signal without assuming it matches complaint product names.' AS notes
FROM review_product
UNION ALL
SELECT
    'complaint_product_baseline', 'complaint_product', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'complaint_product_volume_rank', CAST(volume_rank AS DOUBLE),
    complaints, clients, CAST(NULL AS BIGINT), districts,
    CAST(NULL AS DOUBLE), ROUND(avg_sent_delay_days, 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM complaint_total), 0), 4),
    CAST(NULL AS DOUBLE),
    'Describe formal complaint product mix and weak outcome signals.'
FROM complaint_product
UNION ALL
SELECT
    'district_review_signal', 'district_review', item, item_2, item_3,
    'low_rating_rank', CAST(low_rating_rank AS DOUBLE),
    CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), reviews, CAST(1 AS BIGINT),
    ROUND(avg_stars, 4), CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    ROUND(100.0 * reviews / NULLIF((SELECT total_reviews FROM review_total), 0), 4),
    'Identify local review satisfaction pockets.'
FROM district_review
WHERE low_rating_rank <= 25
UNION ALL
SELECT
    'district_complaint_signal', 'district_complaint', item, item_2, item_3,
    'complaint_volume_rank', CAST(volume_rank AS DOUBLE),
    complaints, clients, CAST(NULL AS BIGINT), CAST(1 AS BIGINT),
    CAST(NULL AS DOUBLE), ROUND(avg_sent_delay_days, 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM complaint_total), 0), 4),
    CAST(NULL AS DOUBLE),
    'Identify local formal complaint burden.'
FROM district_complaint
WHERE volume_rank <= 25
UNION ALL
SELECT
    'district_review_complaint_alignment', 'district_alignment', item, item_2, item_3,
    'complaint_volume_rank', CAST(complaint_rank AS DOUBLE),
    complaints, clients, reviews, CAST(1 AS BIGINT),
    ROUND(avg_stars, 4), ROUND(avg_sent_delay_days, 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM complaint_total), 0), 4),
    ROUND(100.0 * reviews / NULLIF((SELECT total_reviews FROM review_total), 0), 4),
    'Compare local review signal with local formal complaint signal.'
FROM district_alignment
WHERE complaint_rank <= 25
UNION ALL
SELECT
    'region_review_complaint_alignment', 'region_alignment', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'region_complaint_volume_rank', CAST(complaint_rank AS DOUBLE),
    complaints, clients, reviews, districts,
    ROUND(avg_stars, 4), ROUND(avg_sent_delay_days, 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM complaint_total), 0), 4),
    ROUND(100.0 * reviews / NULLIF((SELECT total_reviews FROM review_total), 0), 4),
    'Check whether review and complaint signals align at broad region level.'
FROM region_alignment
UNION ALL
SELECT
    'low_review_district_issue_mix', 'low_review_issue', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'issue_volume_rank_in_low_review_districts', CAST(volume_rank AS DOUBLE),
    complaints, clients, CAST(NULL AS BIGINT), districts,
    CAST(NULL AS DOUBLE), ROUND(avg_sent_delay_days, 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM complaint_total), 0), 4),
    CAST(NULL AS DOUBLE),
    'Show which complaint issues appear inside low-review local markets.'
FROM low_review_issue
WHERE volume_rank <= 15
UNION ALL
SELECT
    'low_review_district_product_mix', 'low_review_complaint_product', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'product_volume_rank_in_low_review_districts', CAST(volume_rank AS DOUBLE),
    complaints, clients, CAST(NULL AS BIGINT), districts,
    CAST(NULL AS DOUBLE), ROUND(avg_sent_delay_days, 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM complaint_total), 0), 4),
    CAST(NULL AS DOUBLE),
    'Show which formal complaint products appear inside low-review local markets.'
FROM low_review_product
WHERE volume_rank <= 10
