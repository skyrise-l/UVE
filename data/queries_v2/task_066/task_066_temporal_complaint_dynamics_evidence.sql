WITH
complaint_fact AS (
    SELECT
        e."Complaint ID" AS complaint_id,
        e.Client_ID AS client_id,
        e."Date received" AS complaint_date,
        EXTRACT(year FROM e."Date received") AS year_value,
        EXTRACT(month FROM e."Date received") AS month_value,
        e.Product AS product,
        e.Issue AS issue,
        COALESCE(e."Submitted via", 'unknown') AS submitted_via,
        COALESCE(e."Company response to consumer", 'unknown') AS company_response,
        date_diff('day', e."Date received", try_strptime(CAST(e."Date sent to company" AS VARCHAR), '%Y-%m-%d')) AS sent_delay_days,
        CASE WHEN COALESCE(e."Consumer disputed?", 'No') = 'Yes' THEN 1 ELSE 0 END AS disputed_flag,
        CASE WHEN COALESCE(e."Timely response?", 'No') <> 'Yes' THEN 1 ELSE 0 END AS untimely_flag,
        CASE WHEN e."Company response to consumer" = 'Closed without relief' THEN 1 ELSE 0 END AS no_relief_flag,
        CASE WHEN NULLIF(TRIM(COALESCE(e."Consumer complaint narrative", '')), '') IS NOT NULL THEN 1 ELSE 0 END AS narrative_flag,
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
    LEFT JOIN callcenterlogs l ON e."Complaint ID" = l."Complaint ID"
),
review_fact AS (
    SELECT
        EXTRACT(year FROM r."Date") AS year_value,
        EXTRACT(month FROM r."Date") AS month_value,
        r.Product AS review_product,
        r.Stars AS stars,
        d.division,
        COALESCE(s.Region, 'unknown') AS region
    FROM reviews r
    LEFT JOIN district d ON r.district_id = d.district_id
    LEFT JOIN state s ON d.state_abbrev = s.StateCode
),
complaint_total AS (
    SELECT COUNT(*) AS total_complaints FROM complaint_fact
),
year_base AS (
    SELECT
        CAST(year_value AS VARCHAR) AS item,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        AVG(service_seconds) AS avg_service_seconds,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        SUM(narrative_flag) AS narrative_count,
        ROW_NUMBER() OVER (ORDER BY year_value) AS year_rank
    FROM complaint_fact
    GROUP BY year_value
),
year_product AS (
    SELECT
        CAST(year_value AS VARCHAR) AS item,
        product AS item_2,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        AVG(service_seconds) AS avg_service_seconds,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        SUM(narrative_flag) AS narrative_count,
        ROW_NUMBER() OVER (PARTITION BY year_value ORDER BY COUNT(*) DESC, product) AS rank_in_year
    FROM complaint_fact
    GROUP BY year_value, product
),
year_issue AS (
    SELECT
        CAST(year_value AS VARCHAR) AS item,
        issue AS item_2,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        AVG(service_seconds) AS avg_service_seconds,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        SUM(narrative_flag) AS narrative_count,
        ROW_NUMBER() OVER (PARTITION BY year_value ORDER BY COUNT(*) DESC, issue) AS rank_in_year
    FROM complaint_fact
    GROUP BY year_value, issue
),
year_channel AS (
    SELECT
        CAST(year_value AS VARCHAR) AS item,
        submitted_via AS item_2,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        AVG(service_seconds) AS avg_service_seconds,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        SUM(narrative_flag) AS narrative_count,
        ROW_NUMBER() OVER (PARTITION BY year_value ORDER BY COUNT(*) DESC, submitted_via) AS rank_in_year
    FROM complaint_fact
    GROUP BY year_value, submitted_via
),
month_base AS (
    SELECT
        CAST(month_value AS VARCHAR) AS item,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        AVG(service_seconds) AS avg_service_seconds,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        SUM(narrative_flag) AS narrative_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, month_value) AS month_rank
    FROM complaint_fact
    GROUP BY month_value
),
review_year AS (
    SELECT
        CAST(year_value AS VARCHAR) AS item,
        review_product AS item_2,
        COUNT(*) AS reviews,
        AVG(stars) AS avg_stars,
        ROW_NUMBER() OVER (PARTITION BY year_value ORDER BY COUNT(*) DESC, review_product) AS rank_in_year
    FROM review_fact
    GROUP BY year_value, review_product
)
SELECT
    'yearly_complaint_baseline' AS evidence_block,
    'year' AS grain,
    item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'year_order' AS rank_label,
    CAST(year_rank AS DOUBLE) AS rank_value,
    complaints,
    clients,
    calls,
    CAST(NULL AS BIGINT) AS reviews,
    CAST(NULL AS DOUBLE) AS avg_stars,
    ROUND(avg_sent_delay_days, 4) AS avg_sent_delay_days,
    ROUND(avg_service_seconds, 4) AS avg_service_seconds,
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4) AS dispute_rate_pct,
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4) AS untimely_rate_pct,
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4) AS no_relief_rate_pct,
    ROUND(100.0 * narrative_count / NULLIF(complaints, 0), 4) AS narrative_rate_pct,
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM complaint_total), 0), 4) AS share_pct,
    'Track complaint volume and outcome rates by year.' AS notes
FROM year_base
UNION ALL
SELECT
    'yearly_product_mix', 'year_product', item, item_2, CAST(NULL AS VARCHAR),
    'product_rank_in_year', CAST(rank_in_year AS DOUBLE),
    complaints, clients, calls, CAST(NULL AS BIGINT), CAST(NULL AS DOUBLE),
    ROUND(avg_sent_delay_days, 4), ROUND(avg_service_seconds, 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * narrative_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM complaint_total), 0), 4),
    'Show whether product mix changes over time.'
FROM year_product
WHERE rank_in_year <= 3
UNION ALL
SELECT
    'yearly_issue_mix', 'year_issue', item, item_2, CAST(NULL AS VARCHAR),
    'issue_rank_in_year', CAST(rank_in_year AS DOUBLE),
    complaints, clients, calls, CAST(NULL AS BIGINT), CAST(NULL AS DOUBLE),
    ROUND(avg_sent_delay_days, 4), ROUND(avg_service_seconds, 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * narrative_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM complaint_total), 0), 4),
    'Show leading issue types in each year.'
FROM year_issue
WHERE rank_in_year <= 5
UNION ALL
SELECT
    'yearly_channel_mix', 'year_channel', item, item_2, CAST(NULL AS VARCHAR),
    'channel_rank_in_year', CAST(rank_in_year AS DOUBLE),
    complaints, clients, calls, CAST(NULL AS BIGINT), CAST(NULL AS DOUBLE),
    ROUND(avg_sent_delay_days, 4), ROUND(avg_service_seconds, 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * narrative_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM complaint_total), 0), 4),
    'Show intake channel mix by year.'
FROM year_channel
WHERE rank_in_year <= 5
UNION ALL
SELECT
    'monthly_seasonality', 'month', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'month_volume_rank', CAST(month_rank AS DOUBLE),
    complaints, clients, calls, CAST(NULL AS BIGINT), CAST(NULL AS DOUBLE),
    ROUND(avg_sent_delay_days, 4), ROUND(avg_service_seconds, 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * narrative_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM complaint_total), 0), 4),
    'Compare month-level complaint seasonality.'
FROM month_base
UNION ALL
SELECT
    'yearly_review_signal', 'year_review_product', item, item_2, CAST(NULL AS VARCHAR),
    'review_product_rank_in_year', CAST(rank_in_year AS DOUBLE),
    CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), reviews,
    ROUND(avg_stars, 4),
    CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE),
    CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE),
    'Compare public review timing with complaint timing.'
FROM review_year
WHERE rank_in_year <= 5
