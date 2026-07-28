WITH
complaint_fact AS (
    SELECT
        e."Complaint ID" AS complaint_id,
        e.Client_ID AS client_id,
        e.Product AS product,
        COALESCE(e."Sub-product", 'unknown_sub_product') AS sub_product,
        e.Issue AS issue,
        COALESCE(e."Submitted via", 'unknown') AS submitted_via,
        COALESCE(e."Company response to consumer", 'unknown') AS company_response,
        date_diff('day', e."Date received", try_strptime(CAST(e."Date sent to company" AS VARCHAR), '%Y-%m-%d')) AS sent_delay_days,
        CASE
            WHEN date_diff('day', e."Date received", try_strptime(CAST(e."Date sent to company" AS VARCHAR), '%Y-%m-%d')) IS NULL THEN 'unknown_delay'
            WHEN date_diff('day', e."Date received", try_strptime(CAST(e."Date sent to company" AS VARCHAR), '%Y-%m-%d')) <= 0 THEN 'same_day'
            WHEN date_diff('day', e."Date received", try_strptime(CAST(e."Date sent to company" AS VARCHAR), '%Y-%m-%d')) <= 2 THEN 'one_to_two_days'
            WHEN date_diff('day', e."Date received", try_strptime(CAST(e."Date sent to company" AS VARCHAR), '%Y-%m-%d')) <= 7 THEN 'three_to_seven_days'
            ELSE 'over_seven_days'
        END AS delay_bucket,
        CASE WHEN COALESCE(e."Consumer disputed?", 'No') = 'Yes' THEN 1 ELSE 0 END AS disputed_flag,
        CASE WHEN COALESCE(e."Timely response?", 'No') <> 'Yes' THEN 1 ELSE 0 END AS untimely_flag,
        CASE WHEN e."Company response to consumer" = 'Closed without relief' THEN 1 ELSE 0 END AS no_relief_flag,
        c.district_id,
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
        END AS service_seconds
    FROM events e
    LEFT JOIN client c ON e.Client_ID = c.client_id
    LEFT JOIN district d ON c.district_id = d.district_id
    LEFT JOIN state s ON d.state_abbrev = s.StateCode
    LEFT JOIN callcenterlogs l ON e."Complaint ID" = l."Complaint ID"
),
total AS (
    SELECT COUNT(*) AS total_complaints FROM complaint_fact
),
channel_base AS (
    SELECT
        submitted_via AS item,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS regions,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, submitted_via) AS volume_rank
    FROM complaint_fact
    GROUP BY submitted_via
),
channel_product AS (
    SELECT
        submitted_via AS item,
        product AS item_2,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS regions,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (PARTITION BY submitted_via ORDER BY COUNT(*) DESC, product) AS rank_in_channel
    FROM complaint_fact
    GROUP BY submitted_via, product
),
channel_issue AS (
    SELECT
        submitted_via AS item,
        issue AS item_2,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS regions,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (PARTITION BY submitted_via ORDER BY COUNT(*) DESC, issue) AS rank_in_channel
    FROM complaint_fact
    GROUP BY submitted_via, issue
),
channel_response AS (
    SELECT
        submitted_via AS item,
        company_response AS item_2,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS regions,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (PARTITION BY submitted_via ORDER BY COUNT(*) DESC, company_response) AS rank_in_channel
    FROM complaint_fact
    GROUP BY submitted_via, company_response
),
channel_delay AS (
    SELECT
        submitted_via AS item,
        delay_bucket AS item_2,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS regions,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (PARTITION BY submitted_via ORDER BY COUNT(*) DESC, delay_bucket) AS rank_in_channel
    FROM complaint_fact
    GROUP BY submitted_via, delay_bucket
),
channel_region AS (
    SELECT
        submitted_via AS item,
        region AS item_2,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS regions,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (PARTITION BY submitted_via ORDER BY COUNT(*) DESC, region) AS rank_in_channel
    FROM complaint_fact
    GROUP BY submitted_via, region
),
channel_call AS (
    SELECT
        submitted_via AS item,
        call_type AS item_2,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS regions,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (PARTITION BY submitted_via ORDER BY COUNT(*) DESC, call_type) AS rank_in_channel
    FROM complaint_fact
    GROUP BY submitted_via, call_type
)
SELECT
    'channel_baseline' AS evidence_block,
    'submitted_via' AS grain,
    item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'channel_volume_rank' AS rank_label,
    CAST(volume_rank AS DOUBLE) AS rank_value,
    complaints,
    clients,
    districts,
    regions,
    calls,
    ROUND(avg_priority, 4) AS avg_priority,
    ROUND(avg_service_seconds, 4) AS avg_service_seconds,
    ROUND(avg_sent_delay_days, 4) AS avg_sent_delay_days,
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4) AS dispute_rate_pct,
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4) AS untimely_rate_pct,
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4) AS no_relief_rate_pct,
    ROUND(100.0 * calls / NULLIF(complaints, 0), 4) AS call_link_rate_pct,
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4) AS share_pct,
    'Compare intake channels by scale and outcomes.' AS notes
FROM channel_base
UNION ALL
SELECT
    'channel_product_mix', 'channel_product', item, item_2, CAST(NULL AS VARCHAR),
    'product_rank_in_channel', CAST(rank_in_channel AS DOUBLE),
    complaints, clients, districts, regions, calls,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * calls / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Show product mix inside each channel.'
FROM channel_product
WHERE rank_in_channel <= 3
UNION ALL
SELECT
    'channel_issue_mix', 'channel_issue', item, item_2, CAST(NULL AS VARCHAR),
    'issue_rank_in_channel', CAST(rank_in_channel AS DOUBLE),
    complaints, clients, districts, regions, calls,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * calls / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Show leading issue types inside each channel.'
FROM channel_issue
WHERE rank_in_channel <= 5
UNION ALL
SELECT
    'channel_response_mix', 'channel_response', item, item_2, CAST(NULL AS VARCHAR),
    'response_rank_in_channel', CAST(rank_in_channel AS DOUBLE),
    complaints, clients, districts, regions, calls,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * calls / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Show response categories inside each channel.'
FROM channel_response
WHERE rank_in_channel <= 6
UNION ALL
SELECT
    'channel_delay_mix', 'channel_delay', item, item_2, CAST(NULL AS VARCHAR),
    'delay_rank_in_channel', CAST(rank_in_channel AS DOUBLE),
    complaints, clients, districts, regions, calls,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * calls / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Show sent-delay mix inside each channel.'
FROM channel_delay
WHERE rank_in_channel <= 5
UNION ALL
SELECT
    'channel_region_mix', 'channel_region', item, item_2, CAST(NULL AS VARCHAR),
    'region_rank_in_channel', CAST(rank_in_channel AS DOUBLE),
    complaints, clients, districts, regions, calls,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * calls / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Show regional mix inside each channel.'
FROM channel_region
WHERE rank_in_channel <= 5
UNION ALL
SELECT
    'channel_call_overlay', 'channel_call', item, item_2, CAST(NULL AS VARCHAR),
    'call_type_rank_in_channel', CAST(rank_in_channel AS DOUBLE),
    complaints, clients, districts, regions, calls,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * calls / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Compare call linkage inside each channel.'
FROM channel_call
WHERE rank_in_channel <= 5
