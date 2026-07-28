WITH
complaint_fact AS (
    SELECT
        e."Complaint ID" AS complaint_id,
        e.Client_ID AS client_id,
        e.Product AS product,
        COALESCE(e."Sub-product", 'unknown') AS sub_product,
        e.Issue AS issue,
        COALESCE(e.Tags, 'untagged') AS tags,
        COALESCE(e."Consumer consent provided?", 'unknown') AS consent_status,
        COALESCE(e."Submitted via", 'unknown') AS submitted_via,
        COALESCE(e."Company response to consumer", 'unknown') AS company_response,
        date_diff('day', e."Date received", try_strptime(CAST(e."Date sent to company" AS VARCHAR), '%Y-%m-%d')) AS sent_delay_days,
        CASE WHEN NULLIF(TRIM(COALESCE(e."Consumer complaint narrative", '')), '') IS NOT NULL THEN 1 ELSE 0 END AS narrative_flag,
        CASE WHEN COALESCE(e.Tags, '') <> '' THEN 1 ELSE 0 END AS tagged_flag,
        CASE WHEN COALESCE(e."Consumer consent provided?", '') NOT IN ('', 'N/A') THEN 1 ELSE 0 END AS consent_flag,
        CASE WHEN COALESCE(e."Consumer disputed?", 'No') = 'Yes' THEN 1 ELSE 0 END AS disputed_flag,
        CASE WHEN COALESCE(e."Timely response?", 'No') <> 'Yes' THEN 1 ELSE 0 END AS untimely_flag,
        CASE WHEN e."Company response to consumer" = 'Closed without relief' THEN 1 ELSE 0 END AS no_relief_flag,
        c.district_id,
        COALESCE(d.division, 'unknown') AS division,
        COALESCE(s.Region, 'unknown') AS region,
        COALESCE(l.type, 'unknown') AS call_type
    FROM events e
    LEFT JOIN client c ON e.Client_ID = c.client_id
    LEFT JOIN district d ON c.district_id = d.district_id
    LEFT JOIN state s ON d.state_abbrev = s.StateCode
    LEFT JOIN callcenterlogs l ON e."Complaint ID" = l."Complaint ID"
),
total AS (
    SELECT COUNT(*) AS total_complaints FROM complaint_fact
),
visibility_bucket AS (
    SELECT
        CASE
            WHEN narrative_flag = 1 THEN 'has_narrative'
            ELSE 'no_narrative'
        END AS item,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS regions,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(narrative_flag) AS narrative_count,
        SUM(tagged_flag) AS tagged_count,
        SUM(consent_flag) AS consent_count,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, item) AS volume_rank
    FROM complaint_fact
    GROUP BY item
),
product_visibility AS (
    SELECT
        product AS item,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS regions,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(narrative_flag) AS narrative_count,
        SUM(tagged_flag) AS tagged_count,
        SUM(consent_flag) AS consent_count,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, product) AS volume_rank
    FROM complaint_fact
    GROUP BY product
),
issue_visibility AS (
    SELECT
        issue AS item,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS regions,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(narrative_flag) AS narrative_count,
        SUM(tagged_flag) AS tagged_count,
        SUM(consent_flag) AS consent_count,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, issue) AS volume_rank
    FROM complaint_fact
    GROUP BY issue
),
consent_visibility AS (
    SELECT
        consent_status AS item,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS regions,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(narrative_flag) AS narrative_count,
        SUM(tagged_flag) AS tagged_count,
        SUM(consent_flag) AS consent_count,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, consent_status) AS volume_rank
    FROM complaint_fact
    GROUP BY consent_status
),
tag_visibility AS (
    SELECT
        tags AS item,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS regions,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(narrative_flag) AS narrative_count,
        SUM(tagged_flag) AS tagged_count,
        SUM(consent_flag) AS consent_count,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, tags) AS volume_rank
    FROM complaint_fact
    GROUP BY tags
),
channel_visibility AS (
    SELECT
        submitted_via AS item,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS regions,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(narrative_flag) AS narrative_count,
        SUM(tagged_flag) AS tagged_count,
        SUM(consent_flag) AS consent_count,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, submitted_via) AS volume_rank
    FROM complaint_fact
    GROUP BY submitted_via
),
region_visibility AS (
    SELECT
        region AS item,
        COUNT(*) AS complaints,
        COUNT(DISTINCT client_id) AS clients,
        COUNT(DISTINCT district_id) AS districts,
        COUNT(DISTINCT region) AS regions,
        COUNT(DISTINCT complaint_id) FILTER (WHERE call_type <> 'unknown') AS calls,
        AVG(sent_delay_days) AS avg_sent_delay_days,
        SUM(narrative_flag) AS narrative_count,
        SUM(tagged_flag) AS tagged_count,
        SUM(consent_flag) AS consent_count,
        SUM(disputed_flag) AS disputed_count,
        SUM(untimely_flag) AS untimely_count,
        SUM(no_relief_flag) AS no_relief_count,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, region) AS volume_rank
    FROM complaint_fact
    GROUP BY region
)
SELECT
    'narrative_coverage_baseline' AS evidence_block,
    'narrative_bucket' AS grain,
    item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'bucket_volume_rank' AS rank_label,
    CAST(volume_rank AS DOUBLE) AS rank_value,
    complaints,
    clients,
    districts,
    regions,
    calls,
    ROUND(avg_sent_delay_days, 4) AS avg_sent_delay_days,
    narrative_count,
    tagged_count,
    consent_count,
    ROUND(100.0 * narrative_count / NULLIF(complaints, 0), 4) AS narrative_rate_pct,
    ROUND(100.0 * tagged_count / NULLIF(complaints, 0), 4) AS tagged_rate_pct,
    ROUND(100.0 * consent_count / NULLIF(complaints, 0), 4) AS consent_rate_pct,
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4) AS dispute_rate_pct,
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4) AS untimely_rate_pct,
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4) AS no_relief_rate_pct,
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4) AS share_pct,
    'Compare complaints with and without written narratives.' AS notes
FROM visibility_bucket
UNION ALL
SELECT
    'product_visibility', 'product', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'product_volume_rank', CAST(volume_rank AS DOUBLE),
    complaints, clients, districts, regions, calls,
    ROUND(avg_sent_delay_days, 4), narrative_count, tagged_count, consent_count,
    ROUND(100.0 * narrative_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * tagged_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * consent_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Compare visibility by product.'
FROM product_visibility
UNION ALL
SELECT
    'issue_visibility', 'issue', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'issue_volume_rank', CAST(volume_rank AS DOUBLE),
    complaints, clients, districts, regions, calls,
    ROUND(avg_sent_delay_days, 4), narrative_count, tagged_count, consent_count,
    ROUND(100.0 * narrative_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * tagged_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * consent_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Compare visibility by issue type.'
FROM issue_visibility
WHERE volume_rank <= 20
UNION ALL
SELECT
    'consent_status_visibility', 'consent_status', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'consent_volume_rank', CAST(volume_rank AS DOUBLE),
    complaints, clients, districts, regions, calls,
    ROUND(avg_sent_delay_days, 4), narrative_count, tagged_count, consent_count,
    ROUND(100.0 * narrative_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * tagged_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * consent_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Compare consent categories with narrative availability.'
FROM consent_visibility
UNION ALL
SELECT
    'tag_visibility', 'tag', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'tag_volume_rank', CAST(volume_rank AS DOUBLE),
    complaints, clients, districts, regions, calls,
    ROUND(avg_sent_delay_days, 4), narrative_count, tagged_count, consent_count,
    ROUND(100.0 * narrative_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * tagged_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * consent_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Compare tag categories with complaint outcomes.'
FROM tag_visibility
UNION ALL
SELECT
    'channel_visibility', 'submitted_via', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'channel_volume_rank', CAST(volume_rank AS DOUBLE),
    complaints, clients, districts, regions, calls,
    ROUND(avg_sent_delay_days, 4), narrative_count, tagged_count, consent_count,
    ROUND(100.0 * narrative_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * tagged_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * consent_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Compare intake channels with narrative availability.'
FROM channel_visibility
UNION ALL
SELECT
    'region_visibility', 'region', item, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    'region_volume_rank', CAST(volume_rank AS DOUBLE),
    complaints, clients, districts, regions, calls,
    ROUND(avg_sent_delay_days, 4), narrative_count, tagged_count, consent_count,
    ROUND(100.0 * narrative_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * tagged_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * consent_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * disputed_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * untimely_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * no_relief_count / NULLIF(complaints, 0), 4),
    ROUND(100.0 * complaints / NULLIF((SELECT total_complaints FROM total), 0), 4),
    'Compare visibility patterns across regions.'
FROM region_visibility
