WITH
complaint_fact AS (
    SELECT
        e."Complaint ID" AS complaint_id,
        e.Client_ID AS client_id,
        e."Date received" AS complaint_date,
        e.Product AS product,
        e.Issue AS issue,
        COALESCE(e."Submitted via", 'unknown') AS submitted_via,
        COALESCE(e."Company response to consumer", 'unknown') AS company_response,
        COALESCE(e."Timely response?", 'unknown') AS timely_response,
        COALESCE(e."Consumer disputed?", 'unknown') AS consumer_disputed,
        COALESCE(c.sex, 'unknown') AS sex,
        c.age,
        CASE
            WHEN c.age IS NULL THEN 'unknown_age'
            WHEN c.age < 30 THEN 'under_30'
            WHEN c.age < 45 THEN 'age_30_44'
            WHEN c.age < 65 THEN 'age_45_64'
            ELSE 'age_65_plus'
        END AS age_group,
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
        END AS service_seconds,
        date_diff('day', e."Date received", try_strptime(CAST(e."Date sent to company" AS VARCHAR), '%Y-%m-%d')) AS sent_delay_days,
        CASE WHEN COALESCE(e."Consumer disputed?", 'No') = 'Yes' THEN 1 ELSE 0 END AS disputed_flag,
        CASE WHEN COALESCE(e."Timely response?", 'No') <> 'Yes' THEN 1 ELSE 0 END AS untimely_flag,
        CASE WHEN e."Company response to consumer" = 'Closed without relief' THEN 1 ELSE 0 END AS no_relief_flag,
        CASE WHEN e."Company response to consumer" = 'Closed with relief' THEN 1 ELSE 0 END AS relief_flag
    FROM events e
    LEFT JOIN client c ON e.Client_ID = c.client_id
    LEFT JOIN district d ON c.district_id = d.district_id
    LEFT JOIN state s ON d.state_abbrev = s.StateCode
    LEFT JOIN callcenterlogs l ON e."Complaint ID" = l."Complaint ID"
),
client_counts AS (
    SELECT
        client_id,
        COUNT(*) AS client_complaints
    FROM complaint_fact
    GROUP BY client_id
),
fact AS (
    SELECT
        cf.*,
        cc.client_complaints,
        CASE
            WHEN cc.client_complaints = 1 THEN 'single_complaint_client'
            WHEN cc.client_complaints <= 3 THEN 'two_to_three_complaints'
            ELSE 'four_plus_complaints'
        END AS repeat_bucket
    FROM complaint_fact cf
    LEFT JOIN client_counts cc ON cf.client_id = cc.client_id
),
total AS (
    SELECT COUNT(*) AS total_complaints FROM fact
),
age_quality AS (
    SELECT
        age_group AS item,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS regions,
        AVG(age) AS avg_age,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        SUM(relief_flag) AS relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, age_group) AS volume_rank
    FROM fact
    GROUP BY age_group
),
sex_quality AS (
    SELECT
        sex AS item,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS regions,
        AVG(age) AS avg_age,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        SUM(relief_flag) AS relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, sex) AS volume_rank
    FROM fact
    GROUP BY sex
),
age_product AS (
    SELECT
        age_group AS item,
        product AS item_2,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS regions,
        AVG(age) AS avg_age,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        SUM(relief_flag) AS relief_count,
        ROW_NUMBER() OVER (PARTITION BY age_group ORDER BY COUNT(*) DESC, product) AS rank_in_group
    FROM fact
    GROUP BY age_group, product
),
age_issue AS (
    SELECT
        age_group AS item,
        issue AS item_2,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS regions,
        AVG(age) AS avg_age,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        SUM(relief_flag) AS relief_count,
        ROW_NUMBER() OVER (PARTITION BY age_group ORDER BY COUNT(*) DESC, issue) AS rank_in_group
    FROM fact
    GROUP BY age_group, issue
),
age_region AS (
    SELECT
        age_group AS item,
        region AS item_2,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS regions,
        AVG(age) AS avg_age,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        SUM(relief_flag) AS relief_count,
        ROW_NUMBER() OVER (PARTITION BY age_group ORDER BY COUNT(*) DESC, region) AS rank_in_group
    FROM fact
    GROUP BY age_group, region
),
repeat_quality AS (
    SELECT
        repeat_bucket AS item,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS regions,
        AVG(age) AS avg_age,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        SUM(relief_flag) AS relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, repeat_bucket) AS volume_rank
    FROM fact
    GROUP BY repeat_bucket
),
client_profile AS (
    SELECT
        client_id AS item,
        age_group AS item_2,
        sex AS item_3,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS regions,
        AVG(age) AS avg_age,
        AVG(priority) AS avg_priority,
        AVG(service_seconds) AS avg_service_seconds,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        SUM(relief_flag) AS relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, client_id) AS volume_rank
    FROM fact
    GROUP BY client_id, age_group, sex
)
SELECT
    'age_group_quality' AS evidence_block,
    'age_group' AS grain,
    item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'age_group_volume_rank' AS rank_label,
    CAST(volume_rank AS DOUBLE) AS rank_value,
    complaints,
    clients,
    districts,
    regions,
    ROUND(avg_age, 4) AS avg_age,
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
    'Compare complaint outcome quality across age groups without using names or contact fields.' AS notes
FROM age_quality
UNION ALL
SELECT
    'sex_quality', 'sex', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'sex_volume_rank', CAST(volume_rank AS DOUBLE),
    complaints, clients, districts, regions,
    ROUND(avg_age, 4), ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    disputed_count, untimely_count, no_relief_count, relief_count,
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Check whether broad customer sex groups differ after reviewing outcome and mix signals.'
FROM sex_quality
UNION ALL
SELECT
    'age_product_mix', 'age_product', item, item_2, CAST(NULL AS VARCHAR),
    'product_rank_in_age_group', CAST(rank_in_group AS DOUBLE),
    complaints, clients, districts, regions,
    ROUND(avg_age, 4), ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    disputed_count, untimely_count, no_relief_count, relief_count,
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Separate age-group differences from product mix.'
FROM age_product
WHERE rank_in_group <= 4
UNION ALL
SELECT
    'age_issue_mix', 'age_issue', item, item_2, CAST(NULL AS VARCHAR),
    'issue_rank_in_age_group', CAST(rank_in_group AS DOUBLE),
    complaints, clients, districts, regions,
    ROUND(avg_age, 4), ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    disputed_count, untimely_count, no_relief_count, relief_count,
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Separate age-group differences from issue mix.'
FROM age_issue
WHERE rank_in_group <= 5
UNION ALL
SELECT
    'age_region_mix', 'age_region', item, item_2, CAST(NULL AS VARCHAR),
    'region_rank_in_age_group', CAST(rank_in_group AS DOUBLE),
    complaints, clients, districts, regions,
    ROUND(avg_age, 4), ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    disputed_count, untimely_count, no_relief_count, relief_count,
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Check whether customer exposure differs by age group and region together.'
FROM age_region
WHERE rank_in_group <= 4
UNION ALL
SELECT
    'repeat_client_quality', 'repeat_client_bucket', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'repeat_bucket_volume_rank', CAST(volume_rank AS DOUBLE),
    complaints, clients, districts, regions,
    ROUND(avg_age, 4), ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    disputed_count, untimely_count, no_relief_count, relief_count,
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Compare single-complaint and repeat-complaint customer journeys.'
FROM repeat_quality
UNION ALL
SELECT
    'high_repeat_client_profile', 'anonymous_client', item, item_2, item_3,
    'client_complaint_volume_rank', CAST(volume_rank AS DOUBLE),
    complaints, clients, districts, regions,
    ROUND(avg_age, 4), ROUND(avg_priority, 4), ROUND(avg_service_seconds, 4), ROUND(avg_sent_delay_days, 4),
    disputed_count, untimely_count, no_relief_count, relief_count,
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Use anonymous client identifiers only to test repeat-complaint concentration.'
FROM client_profile
WHERE volume_rank <= 20
