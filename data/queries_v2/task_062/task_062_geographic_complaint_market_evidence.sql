WITH
complaint_fact AS (
    SELECT
        e."Complaint ID" AS complaint_id,
        e.Client_ID AS client_id,
        e."Date received" AS complaint_date,
        try_strptime(CAST(e."Date sent to company" AS VARCHAR), '%Y-%m-%d') AS sent_date,
        e.Product AS product,
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
        l.priority,
        COALESCE(l.type, 'unknown') AS call_type,
        CASE
            WHEN l.ser_time IS NULL OR l.ser_time = '' THEN NULL
            ELSE
                try_cast(split_part(l.ser_time, ':', 1) AS INTEGER) * 3600
                + try_cast(split_part(l.ser_time, ':', 2) AS INTEGER) * 60
                + try_cast(split_part(l.ser_time, ':', 3) AS INTEGER)
        END AS service_seconds,
        date_diff('day', e."Date received", try_strptime(CAST(e."Date sent to company" AS VARCHAR), '%Y-%m-%d')) AS sent_delay_days,
        CASE WHEN COALESCE(e."Consumer disputed?", 'No') = 'Yes' THEN 1 ELSE 0 END AS disputed_flag,
        CASE WHEN COALESCE(e."Timely response?", 'No') <> 'Yes' THEN 1 ELSE 0 END AS untimely_flag,
        CASE WHEN e."Company response to consumer" = 'Closed without relief' THEN 1 ELSE 0 END AS no_relief_flag
    FROM events e
    LEFT JOIN client c ON e.Client_ID = c.client_id
    LEFT JOIN district d ON c.district_id = d.district_id
    LEFT JOIN state s ON d.state_abbrev = s.StateCode
    LEFT JOIN callcenterlogs l ON e."Complaint ID" = l."Complaint ID"
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
region_complaint AS (
    SELECT
        region AS item,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT state_code) AS states,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, region) AS volume_rank
    FROM complaint_fact
    GROUP BY region
),
state_complaint AS (
    SELECT
        region AS item,
        state_code AS item_2,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT state_code) AS states,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, state_code) AS volume_rank
    FROM complaint_fact
    GROUP BY region, state_code
),
district_complaint AS (
    SELECT
        CAST(district_id AS VARCHAR) AS item,
        district_city AS item_2,
        region AS item_3,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT state_code) AS states,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, district_id) AS volume_rank
    FROM complaint_fact
    GROUP BY district_id, district_city, region
),
region_product AS (
    SELECT
        region AS item,
        product AS item_2,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT state_code) AS states,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (PARTITION BY region ORDER BY COUNT(*) DESC, product) AS rank_in_region
    FROM complaint_fact
    GROUP BY region, product
),
district_issue AS (
    SELECT
        CAST(district_id AS VARCHAR) AS item,
        issue AS item_2,
        district_city AS item_3,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT state_code) AS states,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (PARTITION BY district_id ORDER BY COUNT(*) DESC, issue) AS rank_in_district
    FROM complaint_fact
    GROUP BY district_id, district_city, issue
),
review_district AS (
    SELECT
        CAST(district_id AS VARCHAR) AS item,
        district_city AS item_2,
        region AS item_3,
        COUNT(*) AS reviews,
        AVG(stars) AS avg_stars,
        ROW_NUMBER() OVER (ORDER BY AVG(stars) ASC, COUNT(*) DESC, district_id) AS low_rating_rank
    FROM review_fact
    GROUP BY district_id, district_city, region
),
district_alignment AS (
    SELECT
        dc.item,
        dc.item_2,
        dc.item_3,
        dc.complaints,
        dc.clients,
        dc.districts,
        dc.states,
        dc.calls,
        dc.avg_priority,
        dc.avg_service_seconds,
        dc.avg_sent_delay_days,
        dc.disputed_count,
        dc.untimely_count,
        dc.no_relief_count,
        COALESCE(rd.reviews, 0) AS reviews,
        rd.avg_stars,
        ROW_NUMBER() OVER (ORDER BY dc.complaints DESC, dc.item) AS volume_rank
    FROM district_complaint dc
    LEFT JOIN review_district rd ON dc.item = rd.item
)
SELECT
    'region_complaint_quality' AS evidence_block,
    'region' AS grain,
    item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'region_volume_rank' AS rank_label,
    CAST(volume_rank AS DOUBLE) AS rank_value,
    complaints,
    clients,
    districts,
    states,
    calls,
    CAST(NULL AS BIGINT) AS reviews,
    CAST(NULL AS DOUBLE) AS avg_stars,
    ROUND(avg_priority, 4) AS avg_priority,
    ROUND(avg_service_seconds, 4) AS avg_service_seconds,
    ROUND(avg_sent_delay_days, 4) AS avg_sent_delay_days,
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4) AS dispute_rate_pct,
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4) AS untimely_rate_pct,
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4) AS no_relief_rate_pct,
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM complaint_total), 0), 4) AS complaint_share_pct,
    CAST(NULL AS DOUBLE) AS review_share_pct,
    'Compare regional complaint volume with weak outcome and handling signals.' AS notes
FROM region_complaint
UNION ALL
SELECT
    'state_complaint_quality', 'state', item, item_2, CAST(NULL AS VARCHAR),
    'state_volume_rank', CAST(volume_rank AS DOUBLE),
    complaints, clients, districts, states, calls,
    CAST(NULL AS BIGINT), CAST(NULL AS DOUBLE),
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM complaint_total), 0), 4),
    CAST(NULL AS DOUBLE),
    'Identify states where complaint scale and outcome quality diverge.'
FROM state_complaint
WHERE volume_rank <= 20
UNION ALL
SELECT
    'district_complaint_quality', 'district', item, item_2, item_3,
    'district_volume_rank', CAST(volume_rank AS DOUBLE),
    complaints, clients, districts, states, calls,
    CAST(NULL AS BIGINT), CAST(NULL AS DOUBLE),
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM complaint_total), 0), 4),
    CAST(NULL AS DOUBLE),
    'Find local complaint pockets and avoid only reading region totals.'
FROM district_complaint
WHERE volume_rank <= 25
UNION ALL
SELECT
    'region_product_mix', 'region_product', item, item_2, CAST(NULL AS VARCHAR),
    'product_rank_in_region', CAST(rank_in_region AS DOUBLE),
    complaints, clients, districts, states, calls,
    CAST(NULL AS BIGINT), CAST(NULL AS DOUBLE),
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM complaint_total), 0), 4),
    CAST(NULL AS DOUBLE),
    'Check whether regional differences are partly product-mix differences.'
FROM region_product
WHERE rank_in_region <= 5
UNION ALL
SELECT
    'district_issue_mix', 'district_issue', item, item_2, item_3,
    'issue_rank_in_district', CAST(rank_in_district AS DOUBLE),
    complaints, clients, districts, states, calls,
    CAST(NULL AS BIGINT), CAST(NULL AS DOUBLE),
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM complaint_total), 0), 4),
    CAST(NULL AS DOUBLE),
    'Show which local issue types explain district complaint burden.'
FROM district_issue
WHERE rank_in_district <= 3
UNION ALL
SELECT
    'review_district_signal', 'district_review', item, item_2, item_3,
    'low_rating_rank', CAST(low_rating_rank AS DOUBLE),
    CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(1 AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT),
    reviews, ROUND(avg_stars, 4),
    CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE),
    ROUND(100.0 * reviews / NULLIF((SELECT total_reviews FROM review_total), 0), 4),
    'Use review ratings as an external local satisfaction signal.'
FROM review_district
WHERE low_rating_rank <= 25
UNION ALL
SELECT
    'district_review_complaint_alignment', 'district_alignment', item, item_2, item_3,
    'district_complaint_volume_rank', CAST(volume_rank AS DOUBLE),
    complaints, clients, districts, states, calls,
    reviews, ROUND(avg_stars, 4),
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM complaint_total), 0), 4),
    ROUND(100.0 * reviews / NULLIF((SELECT total_reviews FROM review_total), 0), 4),
    'Compare formal complaint burden with local review signal.'
FROM district_alignment
WHERE volume_rank <= 25
