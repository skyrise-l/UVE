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
subproduct_base AS (
    SELECT
        product AS item,
        sub_product AS item_2,
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
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, product, sub_product) AS volume_rank
    FROM complaint_fact
    GROUP BY product, sub_product
),
subproduct_issue AS (
    SELECT
        product AS item,
        sub_product AS item_2,
        issue AS item_3,
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
        ROW_NUMBER() OVER (PARTITION BY product, sub_product ORDER BY COUNT(*) DESC, issue) AS rank_in_subproduct
    FROM complaint_fact
    GROUP BY product, sub_product, issue
),
subproduct_channel AS (
    SELECT
        product AS item,
        sub_product AS item_2,
        submitted_via AS item_3,
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
        ROW_NUMBER() OVER (PARTITION BY product, sub_product ORDER BY COUNT(*) DESC, submitted_via) AS rank_in_subproduct
    FROM complaint_fact
    GROUP BY product, sub_product, submitted_via
),
subproduct_response AS (
    SELECT
        product AS item,
        sub_product AS item_2,
        company_response AS item_3,
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
        ROW_NUMBER() OVER (PARTITION BY product, sub_product ORDER BY COUNT(*) DESC, company_response) AS rank_in_subproduct
    FROM complaint_fact
    GROUP BY product, sub_product, company_response
),
subproduct_region AS (
    SELECT
        product AS item,
        sub_product AS item_2,
        region AS item_3,
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
        ROW_NUMBER() OVER (PARTITION BY product, sub_product ORDER BY COUNT(*) DESC, region) AS rank_in_subproduct
    FROM complaint_fact
    GROUP BY product, sub_product, region
),
subproduct_call AS (
    SELECT
        product AS item,
        sub_product AS item_2,
        call_type AS item_3,
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
        ROW_NUMBER() OVER (PARTITION BY product, sub_product ORDER BY COUNT(*) DESC, call_type) AS rank_in_subproduct
    FROM complaint_fact
    GROUP BY product, sub_product, call_type
)
SELECT
    'subproduct_baseline' AS evidence_block,
    'product_subproduct' AS grain,
    item,
    item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'subproduct_volume_rank' AS rank_label,
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
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4) AS share_pct,
    'Compare product categories with sub-product detail.' AS notes
FROM subproduct_base
UNION ALL
SELECT
    'subproduct_issue_mix', 'subproduct_issue', item, item_2, item_3,
    'issue_rank_in_subproduct', CAST(rank_in_subproduct AS DOUBLE),
    complaints, clients, districts, regions, calls,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Show leading issues inside each sub-product.'
FROM subproduct_issue
WHERE rank_in_subproduct <= 5
UNION ALL
SELECT
    'subproduct_channel_mix', 'subproduct_channel', item, item_2, item_3,
    'channel_rank_in_subproduct', CAST(rank_in_subproduct AS DOUBLE),
    complaints, clients, districts, regions, calls,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Compare channel mix inside sub-products.'
FROM subproduct_channel
WHERE rank_in_subproduct <= 5
UNION ALL
SELECT
    'subproduct_response_mix', 'subproduct_response', item, item_2, item_3,
    'response_rank_in_subproduct', CAST(rank_in_subproduct AS DOUBLE),
    complaints, clients, districts, regions, calls,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Compare response labels inside sub-products.'
FROM subproduct_response
WHERE rank_in_subproduct <= 5
UNION ALL
SELECT
    'subproduct_region_mix', 'subproduct_region', item, item_2, item_3,
    'region_rank_in_subproduct', CAST(rank_in_subproduct AS DOUBLE),
    complaints, clients, districts, regions, calls,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Compare regional reach inside sub-products.'
FROM subproduct_region
WHERE rank_in_subproduct <= 5
UNION ALL
SELECT
    'subproduct_call_overlay', 'subproduct_call', item, item_2, item_3,
    'call_type_rank_in_subproduct', CAST(rank_in_subproduct AS DOUBLE),
    complaints, clients, districts, regions, calls,
    ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Use call linkage as a sub-product operations layer.'
FROM subproduct_call
WHERE rank_in_subproduct <= 5
