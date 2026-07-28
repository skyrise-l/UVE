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
        l.priority,
        COALESCE(l.type, 'unknown') AS call_type,
        COALESCE(l.outcome, 'unknown') AS call_outcome,
        COALESCE(l.server, 'unknown') AS server,
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
        CASE WHEN e."Company response to consumer" = 'Closed without relief' THEN 1 ELSE 0 END AS no_relief_flag,
        CASE WHEN e."Company response to consumer" = 'Closed with relief' THEN 1 ELSE 0 END AS relief_flag
    FROM events e
    LEFT JOIN callcenterlogs l ON e."Complaint ID" = l."Complaint ID"
),
fact AS (
    SELECT
        *,
        CASE
            WHEN sent_delay_days IS NULL THEN 'unknown_delay'
            WHEN sent_delay_days <= 0 THEN 'same_day'
            WHEN sent_delay_days <= 2 THEN 'one_to_two_days'
            WHEN sent_delay_days <= 7 THEN 'three_to_seven_days'
            ELSE 'over_seven_days'
        END AS delay_bucket,
        CASE
            WHEN service_seconds IS NULL THEN 'unknown_service_time'
            WHEN service_seconds <= 180 THEN 'short_0_3_min'
            WHEN service_seconds <= 600 THEN 'medium_3_10_min'
            WHEN service_seconds <= 1200 THEN 'long_10_20_min'
            ELSE 'very_long_20_plus_min'
        END AS service_time_bucket,
        COALESCE(CAST(priority AS VARCHAR), 'unknown_priority') AS priority_bucket
    FROM complaint_fact
),
total AS (
    SELECT COUNT(*) AS total_complaints FROM fact
),
delay_bucket AS (
    SELECT
        delay_bucket AS item,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        SUM(relief_flag) AS relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, delay_bucket) AS volume_rank
    FROM fact
    GROUP BY delay_bucket
),
priority_quality AS (
    SELECT
        priority_bucket AS item,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        SUM(relief_flag) AS relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, priority_bucket) AS volume_rank
    FROM fact
    GROUP BY priority_bucket
),
service_time_quality AS (
    SELECT
        service_time_bucket AS item,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        SUM(relief_flag) AS relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, service_time_bucket) AS volume_rank
    FROM fact
    GROUP BY service_time_bucket
),
call_type_quality AS (
    SELECT
        call_type AS item,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        SUM(relief_flag) AS relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, call_type) AS volume_rank
    FROM fact
    WHERE call_type <> 'unknown'
    GROUP BY call_type
),
call_outcome_quality AS (
    SELECT
        call_outcome AS item,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        SUM(relief_flag) AS relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, call_outcome) AS volume_rank
    FROM fact
    WHERE call_outcome <> 'unknown'
    GROUP BY call_outcome
),
server_quality AS (
    SELECT
        server AS item,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        SUM(relief_flag) AS relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, server) AS volume_rank
    FROM fact
    WHERE server <> 'unknown'
    GROUP BY server
),
delay_product AS (
    SELECT
        delay_bucket AS item,
        product AS item_2,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        SUM(relief_flag) AS relief_count,
        ROW_NUMBER() OVER (PARTITION BY delay_bucket ORDER BY COUNT(*) DESC, product) AS rank_in_bucket
    FROM fact
    GROUP BY delay_bucket, product
),
delay_issue AS (
    SELECT
        delay_bucket AS item,
        issue AS item_2,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        SUM(relief_flag) AS relief_count,
        ROW_NUMBER() OVER (PARTITION BY delay_bucket ORDER BY COUNT(*) DESC, issue) AS rank_in_bucket
    FROM fact
    GROUP BY delay_bucket, issue
)
SELECT
    'delay_bucket_quality' AS evidence_block,
    'sent_delay_bucket' AS grain,
    item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'delay_bucket_volume_rank' AS rank_label,
    CAST(volume_rank AS DOUBLE) AS rank_value,
    complaints,
    clients,
    calls,
    ROUND(avg_priority, 4) AS avg_priority,
    ROUND(avg_service_seconds, 4) AS avg_service_seconds,
    ROUND(avg_sent_delay_days, 4) AS avg_sent_delay_days,
    disputed_count,
    untimely_count,
    no_relief_count,
    relief_count,
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4) AS dispute_rate_pct,
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4) AS untimely_rate_pct,
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4) AS no_relief_rate_pct,
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4) AS share_pct,
    'Compare company-sent delay buckets with dispute and relief outcomes.' AS notes
FROM delay_bucket
UNION ALL
SELECT
    'priority_quality', 'priority', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'priority_volume_rank', CAST(volume_rank AS DOUBLE),
    complaints, clients, calls,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    disputed_count, untimely_count, no_relief_count, relief_count,
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Check whether priority level corresponds to harder complaint journeys.'
FROM priority_quality
UNION ALL
SELECT
    'service_time_quality', 'service_time_bucket', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'service_time_volume_rank', CAST(volume_rank AS DOUBLE),
    complaints, clients, calls,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    disputed_count, untimely_count, no_relief_count, relief_count,
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Test whether longer service time is a complexity signal or only volume noise.'
FROM service_time_quality
UNION ALL
SELECT
    'call_type_quality', 'call_type', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'call_type_volume_rank', CAST(volume_rank AS DOUBLE),
    complaints, clients, calls,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    disputed_count, untimely_count, no_relief_count, relief_count,
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Separate call handling type from formal complaint result quality.'
FROM call_type_quality
UNION ALL
SELECT
    'call_outcome_quality', 'call_outcome', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'call_outcome_volume_rank', CAST(volume_rank AS DOUBLE),
    complaints, clients, calls,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    disputed_count, untimely_count, no_relief_count, relief_count,
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Compare call outcome labels with downstream complaint quality.'
FROM call_outcome_quality
UNION ALL
SELECT
    'server_workload_quality', 'server', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'server_volume_rank', CAST(volume_rank AS DOUBLE),
    complaints, clients, calls,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    disputed_count, untimely_count, no_relief_count, relief_count,
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Identify whether handler workload differs from outcome quality.'
FROM server_quality
WHERE volume_rank <= 25
UNION ALL
SELECT
    'delay_product_mix', 'delay_product', item, item_2, CAST(NULL AS VARCHAR),
    'product_rank_in_delay_bucket', CAST(rank_in_bucket AS DOUBLE),
    complaints, clients, calls,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    disputed_count, untimely_count, no_relief_count, relief_count,
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Check whether delay buckets are driven by different product mix.'
FROM delay_product
WHERE rank_in_bucket <= 3
UNION ALL
SELECT
    'delay_issue_mix', 'delay_issue', item, item_2, CAST(NULL AS VARCHAR),
    'issue_rank_in_delay_bucket', CAST(rank_in_bucket AS DOUBLE),
    complaints, clients, calls,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    disputed_count, untimely_count, no_relief_count, relief_count,
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Check whether delay buckets are driven by different issue mix.'
FROM delay_issue
WHERE rank_in_bucket <= 5
