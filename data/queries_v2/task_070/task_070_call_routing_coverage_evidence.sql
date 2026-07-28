WITH
call_fact AS (
    SELECT
        l.call_id,
        l."Complaint ID" AS complaint_id,
        COALESCE(e.Client_ID, l."rand client") AS client_id,
        COALESCE(l."vru+line", 'unknown_line') AS vru_line,
        COALESCE(CAST(l.priority AS VARCHAR), 'unknown_priority') AS priority_bucket,
        l.priority,
        COALESCE(l.type, 'unknown_type') AS call_type,
        COALESCE(l.outcome, 'unknown_outcome') AS call_outcome,
        COALESCE(l.server, 'unknown_server') AS server,
        l."Date received" AS call_date,
        CASE
            WHEN l.ser_time IS NULL OR l.ser_time = '' THEN NULL
            ELSE
                try_cast(split_part(l.ser_time, ':', 1) AS INTEGER) * 3600
                + try_cast(split_part(l.ser_time, ':', 2) AS INTEGER) * 60
                + try_cast(split_part(l.ser_time, ':', 3) AS INTEGER)
        END AS service_seconds,
        CASE WHEN e."Complaint ID" IS NOT NULL THEN 1 ELSE 0 END AS linked_flag,
        COALESCE(e.Product, 'no_linked_product') AS product,
        COALESCE(e.Issue, 'no_linked_issue') AS issue,
        date_diff('day', e."Date received", try_strptime(CAST(e."Date sent to company" AS VARCHAR), '%Y-%m-%d')) AS sent_delay_days,
        CASE WHEN COALESCE(e."Consumer disputed?", 'No') = 'Yes' THEN 1 ELSE 0 END AS disputed_flag,
        CASE WHEN COALESCE(e."Timely response?", 'No') <> 'Yes' AND e."Complaint ID" IS NOT NULL THEN 1 ELSE 0 END AS untimely_flag,
        CASE WHEN e."Company response to consumer" = 'Closed without relief' THEN 1 ELSE 0 END AS no_relief_flag,
        c.district_id,
        COALESCE(d.division, 'unknown') AS division,
        COALESCE(s.Region, 'unknown') AS region
    FROM callcenterlogs l
    LEFT JOIN events e ON l."Complaint ID" = e."Complaint ID"
    LEFT JOIN client c ON COALESCE(e.Client_ID, l."rand client") = c.client_id
    LEFT JOIN district d ON c.district_id = d.district_id
    LEFT JOIN state s ON d.state_abbrev = s.StateCode
),
total AS (
    SELECT COUNT(*) AS total_calls FROM call_fact
),
linkage_base AS (
    SELECT
        CASE WHEN linked_flag = 1 THEN 'linked_to_complaint' ELSE 'not_linked_to_complaint' END AS item,
        COUNT(*) AS calls,
        SUM(linked_flag) AS linked_complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS regions,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, item) AS volume_rank
    FROM call_fact
    GROUP BY item
),
call_type_base AS (
    SELECT
        call_type AS item,
        COUNT(*) AS calls,
        SUM(linked_flag) AS linked_complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS regions,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, call_type) AS volume_rank
    FROM call_fact
    GROUP BY call_type
),
priority_base AS (
    SELECT
        priority_bucket AS item,
        COUNT(*) AS calls,
        SUM(linked_flag) AS linked_complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS regions,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, priority_bucket) AS volume_rank
    FROM call_fact
    GROUP BY priority_bucket
),
line_base AS (
    SELECT
        vru_line AS item,
        COUNT(*) AS calls,
        SUM(linked_flag) AS linked_complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS regions,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, vru_line) AS volume_rank
    FROM call_fact
    GROUP BY vru_line
),
server_base AS (
    SELECT
        server AS item,
        COUNT(*) AS calls,
        SUM(linked_flag) AS linked_complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS regions,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, server) AS volume_rank
    FROM call_fact
    GROUP BY server
),
service_bucket AS (
    SELECT
        CASE
            WHEN service_seconds IS NULL THEN 'unknown_service_time'
            WHEN service_seconds <= 180 THEN 'short_0_3_min'
            WHEN service_seconds <= 600 THEN 'medium_3_10_min'
            WHEN service_seconds <= 1200 THEN 'long_10_20_min'
            ELSE 'very_long_20_plus_min'
        END AS item,
        COUNT(*) AS calls,
        SUM(linked_flag) AS linked_complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS regions,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, item) AS volume_rank
    FROM call_fact
    GROUP BY item
),
product_overlay AS (
    SELECT
        product AS item,
        call_type AS item_2,
        COUNT(*) AS calls,
        SUM(linked_flag) AS linked_complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS regions,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (PARTITION BY product ORDER BY COUNT(*) DESC, call_type) AS rank_in_product
    FROM call_fact
    GROUP BY product, call_type
),
issue_overlay AS (
    SELECT
        issue AS item,
        call_type AS item_2,
        COUNT(*) AS calls,
        SUM(linked_flag) AS linked_complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS regions,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (PARTITION BY issue ORDER BY COUNT(*) DESC, call_type) AS rank_in_issue
    FROM call_fact
    GROUP BY issue, call_type
)
SELECT
    'call_linkage_baseline' AS evidence_block,
    'call_linkage' AS grain,
    item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'linkage_volume_rank' AS rank_label,
    CAST(volume_rank AS DOUBLE) AS rank_value,
    calls,
    linked_complaints,
    clients,
    districts,
    regions,
    ROUND(avg_priority, 4) AS avg_priority,
    ROUND(avg_service_seconds, 4) AS avg_service_seconds,
    ROUND(avg_sent_delay_days, 4) AS avg_sent_delay_days,
    ROUND(100.0 * disputed_count / NULLIF(linked_complaints, 0), 4) AS dispute_rate_pct,
    ROUND(100.0 * untimely_count / NULLIF(linked_complaints, 0), 4) AS untimely_rate_pct,
    ROUND(100.0 * no_relief_count / NULLIF(linked_complaints, 0), 4) AS no_relief_rate_pct,
    ROUND(100.0 * linked_complaints / NULLIF(calls, 0), 4) AS linked_rate_pct,
    ROUND(100.0 * calls / NULLIF((SELECT total_calls FROM total), 0), 4) AS share_pct,
    'Compare calls that do and do not join to formal complaints.' AS notes
FROM linkage_base
UNION ALL
SELECT
    'call_type_routing', 'call_type', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'call_type_volume_rank', CAST(volume_rank AS DOUBLE),
    calls, linked_complaints, clients, districts, regions,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    ROUND(100.0 * disputed_count / NULLIF(linked_complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(linked_complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(linked_complaints, 0), 4),
    ROUND(100.0 * linked_complaints / NULLIF(calls, 0), 4),
    ROUND(100.0 * calls / NULLIF((SELECT total_calls FROM total), 0), 4),
    'Compare call types by scale and linkage.'
FROM call_type_base
UNION ALL
SELECT
    'priority_routing', 'priority', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'priority_volume_rank', CAST(volume_rank AS DOUBLE),
    calls, linked_complaints, clients, districts, regions,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    ROUND(100.0 * disputed_count / NULLIF(linked_complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(linked_complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(linked_complaints, 0), 4),
    ROUND(100.0 * linked_complaints / NULLIF(calls, 0), 4),
    ROUND(100.0 * calls / NULLIF((SELECT total_calls FROM total), 0), 4),
    'Compare priority buckets by call linkage and outcomes.'
FROM priority_base
UNION ALL
SELECT
    'line_routing', 'vru_line', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'line_volume_rank', CAST(volume_rank AS DOUBLE),
    calls, linked_complaints, clients, districts, regions,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    ROUND(100.0 * disputed_count / NULLIF(linked_complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(linked_complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(linked_complaints, 0), 4),
    ROUND(100.0 * linked_complaints / NULLIF(calls, 0), 4),
    ROUND(100.0 * calls / NULLIF((SELECT total_calls FROM total), 0), 4),
    'Compare line routing patterns.'
FROM line_base
WHERE volume_rank <= 30
UNION ALL
SELECT
    'server_volume_quality', 'server', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'server_volume_rank', CAST(volume_rank AS DOUBLE),
    calls, linked_complaints, clients, districts, regions,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    ROUND(100.0 * disputed_count / NULLIF(linked_complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(linked_complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(linked_complaints, 0), 4),
    ROUND(100.0 * linked_complaints / NULLIF(calls, 0), 4),
    ROUND(100.0 * calls / NULLIF((SELECT total_calls FROM total), 0), 4),
    'Compare server-level call volume and linked outcomes.'
FROM server_base
WHERE volume_rank <= 30
UNION ALL
SELECT
    'service_time_routing', 'service_time_bucket', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'service_time_volume_rank', CAST(volume_rank AS DOUBLE),
    calls, linked_complaints, clients, districts, regions,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    ROUND(100.0 * disputed_count / NULLIF(linked_complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(linked_complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(linked_complaints, 0), 4),
    ROUND(100.0 * linked_complaints / NULLIF(calls, 0), 4),
    ROUND(100.0 * calls / NULLIF((SELECT total_calls FROM total), 0), 4),
    'Compare service-time buckets in call records.'
FROM service_bucket
UNION ALL
SELECT
    'call_product_overlay', 'product_call_type', item, item_2, CAST(NULL AS VARCHAR),
    'call_type_rank_in_product', CAST(rank_in_product AS DOUBLE),
    calls, linked_complaints, clients, districts, regions,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    ROUND(100.0 * disputed_count / NULLIF(linked_complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(linked_complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(linked_complaints, 0), 4),
    ROUND(100.0 * linked_complaints / NULLIF(calls, 0), 4),
    ROUND(100.0 * calls / NULLIF((SELECT total_calls FROM total), 0), 4),
    'Check product mix within call types.'
FROM product_overlay
WHERE rank_in_product <= 5
UNION ALL
SELECT
    'call_issue_overlay', 'issue_call_type', item, item_2, CAST(NULL AS VARCHAR),
    'call_type_rank_in_issue', CAST(rank_in_issue AS DOUBLE),
    calls, linked_complaints, clients, districts, regions,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    ROUND(100.0 * disputed_count / NULLIF(linked_complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(linked_complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(linked_complaints, 0), 4),
    ROUND(100.0 * linked_complaints / NULLIF(calls, 0), 4),
    ROUND(100.0 * calls / NULLIF((SELECT total_calls FROM total), 0), 4),
    'Check issue mix within call types.'
FROM issue_overlay
WHERE rank_in_issue <= 3
