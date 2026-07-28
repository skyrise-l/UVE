WITH
complaint_fact AS (
    SELECT
        e."Complaint ID" AS complaint_id,
        e.Client_ID AS client_id,
        e."Date received" AS complaint_date,
        try_strptime(CAST(e."Date sent to company" AS VARCHAR), '%Y-%m-%d') AS sent_date,
        e.Product AS product,
        COALESCE(e."Sub-product", 'unknown') AS sub_product,
        e.Issue AS issue,
        COALESCE(e."Submitted via", 'unknown') AS submitted_via,
        COALESCE(e."Company response to consumer", 'unknown') AS company_response,
        COALESCE(e."Timely response?", 'unknown') AS timely_response,
        COALESCE(e."Consumer disputed?", 'unknown') AS consumer_disputed,
        c.district_id,
        d.division,
        s.Region AS region,
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
        CASE WHEN e."Company response to consumer" = 'Closed with relief' THEN 1 ELSE 0 END AS relief_flag,
        CASE WHEN e."Company response to consumer" = 'Closed without relief' THEN 1 ELSE 0 END AS no_relief_flag,
        CASE WHEN e."Company response to consumer" = 'Closed with explanation' THEN 1 ELSE 0 END AS explanation_flag
    FROM events e
    LEFT JOIN client c ON e.Client_ID = c.client_id
    LEFT JOIN district d ON c.district_id = d.district_id
    LEFT JOIN state s ON d.state_abbrev = s.StateCode
    LEFT JOIN callcenterlogs l ON e."Complaint ID" = l."Complaint ID"
),
overall AS (
    SELECT
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS states,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(relief_flag) AS relief_count,
        SUM(no_relief_flag) AS no_relief_count,
        SUM(explanation_flag) AS explanation_count
    FROM complaint_fact
),
product_quality AS (
    SELECT
        product AS item,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS states,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(relief_flag) AS relief_count,
        SUM(no_relief_flag) AS no_relief_count,
        SUM(explanation_flag) AS explanation_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, product) AS volume_rank
    FROM complaint_fact
    GROUP BY product
),
issue_quality AS (
    SELECT
        issue AS item,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS states,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(relief_flag) AS relief_count,
        SUM(no_relief_flag) AS no_relief_count,
        SUM(explanation_flag) AS explanation_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, issue) AS volume_rank
    FROM complaint_fact
    GROUP BY issue
),
channel_quality AS (
    SELECT
        submitted_via AS item,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS states,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(relief_flag) AS relief_count,
        SUM(no_relief_flag) AS no_relief_count,
        SUM(explanation_flag) AS explanation_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, submitted_via) AS volume_rank
    FROM complaint_fact
    GROUP BY submitted_via
),
response_quality AS (
    SELECT
        company_response AS item,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS states,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(relief_flag) AS relief_count,
        SUM(no_relief_flag) AS no_relief_count,
        SUM(explanation_flag) AS explanation_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, company_response) AS volume_rank
    FROM complaint_fact
    GROUP BY company_response
),
product_issue AS (
    SELECT
        product AS item,
        issue AS item_2,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS states,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(relief_flag) AS relief_count,
        SUM(no_relief_flag) AS no_relief_count,
        SUM(explanation_flag) AS explanation_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, product, issue) AS volume_rank
    FROM complaint_fact
    GROUP BY product, issue
),
call_type_quality AS (
    SELECT
        call_type AS item,
        call_outcome AS item_2,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS states,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(relief_flag) AS relief_count,
        SUM(no_relief_flag) AS no_relief_count,
        SUM(explanation_flag) AS explanation_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, call_type, call_outcome) AS volume_rank
    FROM complaint_fact
    WHERE call_type <> 'unknown'
    GROUP BY call_type, call_outcome
),
total AS (
    SELECT COUNT(*) AS total_complaints FROM complaint_fact
)
SELECT
    'overall_complaint_baseline' AS evidence_block,
    'portfolio' AS grain,
    'all_complaints' AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'overall' AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    complaints,
    clients,
    districts,
    states,
    calls,
    ROUND(avg_priority, 4) AS avg_priority,
    ROUND(avg_service_seconds, 4) AS avg_service_seconds,
    ROUND(avg_sent_delay_days, 4) AS avg_sent_delay_days,
    disputed_count,
    untimely_count,
    relief_count,
    no_relief_count,
    explanation_count,
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4) AS dispute_rate_pct,
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4) AS untimely_rate_pct,
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4) AS no_relief_rate_pct,
    CAST(100.0 AS DOUBLE) AS share_pct,
    'Establish complaint volume, dispute, response, relief, and handling baseline.' AS notes
FROM overall
UNION ALL
SELECT
    'product_outcome_quality', 'product', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'product_volume_rank', CAST(volume_rank AS DOUBLE),
    complaints, clients, districts, states, calls,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    disputed_count, untimely_count, relief_count, no_relief_count, explanation_count,
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Compare complaint volume with dispute and relief quality by product.'
FROM product_quality
UNION ALL
SELECT
    'issue_outcome_quality', 'issue', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'issue_volume_rank', CAST(volume_rank AS DOUBLE),
    complaints, clients, districts, states, calls,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    disputed_count, untimely_count, relief_count, no_relief_count, explanation_count,
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Identify issue types that dominate weak complaint journeys.'
FROM issue_quality
WHERE volume_rank <= 15
UNION ALL
SELECT
    'submission_channel_quality', 'submitted_via', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'channel_volume_rank', CAST(volume_rank AS DOUBLE),
    complaints, clients, districts, states, calls,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    disputed_count, untimely_count, relief_count, no_relief_count, explanation_count,
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Check whether intake channel changes outcome quality.'
FROM channel_quality
UNION ALL
SELECT
    'company_response_quality', 'company_response', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'response_volume_rank', CAST(volume_rank AS DOUBLE),
    complaints, clients, districts, states, calls,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    disputed_count, untimely_count, relief_count, no_relief_count, explanation_count,
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Separate formal response outcomes from dispute and timing signals.'
FROM response_quality
UNION ALL
SELECT
    'product_issue_risk_pockets', 'product_issue', item, item_2, CAST(NULL AS VARCHAR),
    'product_issue_volume_rank', CAST(volume_rank AS DOUBLE),
    complaints, clients, districts, states, calls,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    disputed_count, untimely_count, relief_count, no_relief_count, explanation_count,
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Find product and issue intersections that may explain weak outcomes.'
FROM product_issue
WHERE volume_rank <= 20
UNION ALL
SELECT
    'call_type_outcome_overlay', 'call_type_outcome', item, item_2, CAST(NULL AS VARCHAR),
    'call_type_volume_rank', CAST(volume_rank AS DOUBLE),
    complaints, clients, districts, states, calls,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    disputed_count, untimely_count, relief_count, no_relief_count, explanation_count,
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Overlay call handling type with complaint outcome signals.'
FROM call_type_quality
WHERE volume_rank <= 12
