WITH business_base AS (
    SELECT business_id, active, city, state, stars, review_count FROM "Business"
),
review_by_business AS (
    SELECT business_id, COUNT(*) AS reviews, AVG(review_stars) AS avg_review_stars
    FROM "Reviews"
    GROUP BY business_id
),
tip_by_business AS (
    SELECT business_id, COUNT(*) AS tips, SUM(likes) AS tip_likes
    FROM "Tips"
    GROUP BY business_id
),
open_days AS (
    SELECT
        business_id,
        COUNT(*) AS open_days,
        MIN(opening_time) AS sample_opening_time,
        MAX(closing_time) AS sample_closing_time
    FROM "Business_Hours"
    GROUP BY business_id
),
checkin_slots AS (
    SELECT c.business_id, c.day_id, d.day_of_week, h.hour_num, h.hour_label, h.value_label,
        CASE h.value_label WHEN 'Low' THEN 1 WHEN 'Medium' THEN 2 WHEN 'High' THEN 3 WHEN 'Uber' THEN 4 ELSE 0 END AS slot_score,
        CASE
            WHEN h.hour_num BETWEEN 6 AND 10 THEN 'morning'
            WHEN h.hour_num BETWEEN 11 AND 16 THEN 'afternoon'
            WHEN h.hour_num BETWEEN 17 AND 21 THEN 'evening'
            ELSE 'late_night'
        END AS daypart
    FROM "Checkins" c
    JOIN "Days" d ON c.day_id = d.day_id
    CROSS JOIN LATERAL (VALUES
        (0, '00', c.label_time_0), (1, '01', c.label_time_1), (2, '02', c.label_time_2), (3, '03', c.label_time_3),
        (4, '04', c.label_time_4), (5, '05', c.label_time_5), (6, '06', c.label_time_6), (7, '07', c.label_time_7),
        (8, '08', c.label_time_8), (9, '09', c.label_time_9), (10, '10', c.label_time_10), (11, '11', c.label_time_11),
        (12, '12', c.label_time_12), (13, '13', c.label_time_13), (14, '14', c.label_time_14), (15, '15', c.label_time_15),
        (16, '16', c.label_time_16), (17, '17', c.label_time_17), (18, '18', c.label_time_18), (19, '19', c.label_time_19),
        (20, '20', c.label_time_20), (21, '21', c.label_time_21), (22, '22', c.label_time_22), (23, '23', c.label_time_23)
    ) AS h(hour_num, hour_label, value_label)
    WHERE h.value_label <> 'None'
),
checkin_by_business AS (
    SELECT business_id, SUM(slot_score) AS checkin_slots, COUNT(DISTINCT day_id) AS checkin_days
    FROM checkin_slots
    GROUP BY business_id
),
business_metrics AS (
    SELECT
        bb.*,
        COALESCE(od.open_days, 0) AS open_days,
        CASE
            WHEN COALESCE(od.open_days, 0) = 0 THEN 'no_hours_listed'
            WHEN od.open_days <= 3 THEN 'one_to_three_days'
            WHEN od.open_days <= 6 THEN 'four_to_six_days'
            ELSE 'seven_days'
        END AS open_days_bucket,
        COALESCE(cb.checkin_slots, 0) AS checkin_slots,
        COALESCE(cb.checkin_days, 0) AS checkin_days,
        COALESCE(rb.reviews, 0) AS reviews,
        rb.avg_review_stars,
        COALESCE(tb.tips, 0) AS tips,
        COALESCE(tb.tip_likes, 0) AS tip_likes
    FROM business_base bb
    LEFT JOIN open_days od ON bb.business_id = od.business_id
    LEFT JOIN checkin_by_business cb ON bb.business_id = cb.business_id
    LEFT JOIN review_by_business rb ON bb.business_id = rb.business_id
    LEFT JOIN tip_by_business tb ON bb.business_id = tb.business_id
),
metric_total AS (SELECT COUNT(*) AS total_businesses FROM business_metrics),
block_hours_coverage AS (
    SELECT
        'hours_coverage_baseline' AS evidence_block,
        'hours_presence' AS grain,
        CASE WHEN open_days = 0 THEN 'no_hours_listed' ELSE 'has_hours_listed' END AS item,
        CAST(NULL AS TEXT) AS item_2,
        CAST(NULL AS TEXT) AS item_3,
        'hours_presence_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) AS rank_value,
        COUNT(*) AS businesses,
        SUM(reviews) AS reviews,
        SUM(tips) AS tips,
        SUM(checkin_slots) AS checkin_slots,
        ROUND(AVG(stars), 4) AS avg_business_stars,
        ROUND(AVG(avg_review_stars), 4) AS avg_review_stars,
        ROUND(AVG(open_days), 4) AS avg_open_days,
        ROUND(100.0 * AVG(CASE WHEN active = 'true' THEN 1.0 ELSE 0.0 END), 4) AS active_rate_pct,
        ROUND(100.0 * COUNT(*) / MAX(mt.total_businesses), 4) AS share_pct,
        'coverage of listed hours before using hours as operating evidence' AS notes
    FROM business_metrics bm CROSS JOIN metric_total mt
    GROUP BY CASE WHEN open_days = 0 THEN 'no_hours_listed' ELSE 'has_hours_listed' END
),
block_open_days AS (
    SELECT
        'open_days_profile' AS evidence_block,
        'open_days_bucket' AS grain,
        open_days_bucket AS item,
        CAST(NULL AS TEXT) AS item_2,
        CAST(NULL AS TEXT) AS item_3,
        'open_days_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, open_days_bucket) AS rank_value,
        COUNT(*) AS businesses,
        SUM(reviews) AS reviews,
        SUM(tips) AS tips,
        SUM(checkin_slots) AS checkin_slots,
        ROUND(AVG(stars), 4) AS avg_business_stars,
        ROUND(AVG(avg_review_stars), 4) AS avg_review_stars,
        ROUND(AVG(open_days), 4) AS avg_open_days,
        ROUND(100.0 * AVG(CASE WHEN active = 'true' THEN 1.0 ELSE 0.0 END), 4) AS active_rate_pct,
        ROUND(100.0 * COUNT(*) / MAX(mt.total_businesses), 4) AS share_pct,
        'listed open-day breadth compared with rating and activity' AS notes
    FROM business_metrics bm CROSS JOIN metric_total mt
    GROUP BY open_days_bucket
),
block_day AS (
    SELECT
        'day_checkin_profile' AS evidence_block,
        'day_of_week' AS grain,
        day_of_week AS item,
        CAST(NULL AS TEXT) AS item_2,
        CAST(NULL AS TEXT) AS item_3,
        'day_checkin_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY SUM(slot_score) DESC, day_of_week) AS rank_value,
        COUNT(DISTINCT cs.business_id) AS businesses,
        CAST(NULL AS BIGINT) AS reviews,
        CAST(NULL AS BIGINT) AS tips,
        SUM(slot_score) AS checkin_slots,
        ROUND(AVG(b.stars), 4) AS avg_business_stars,
        CAST(NULL AS DOUBLE) AS avg_review_stars,
        CAST(NULL AS DOUBLE) AS avg_open_days,
        ROUND(100.0 * AVG(CASE WHEN b.active = 'true' THEN 1.0 ELSE 0.0 END), 4) AS active_rate_pct,
        ROUND(100.0 * SUM(slot_score) / SUM(SUM(slot_score)) OVER (), 4) AS share_pct,
        'check-in intensity by day of week' AS notes
    FROM checkin_slots cs
    JOIN "Business" b ON cs.business_id = b.business_id
    GROUP BY day_of_week
),
block_daypart AS (
    SELECT
        'daypart_checkin_profile' AS evidence_block,
        'daypart' AS grain,
        daypart AS item,
        CAST(NULL AS TEXT) AS item_2,
        CAST(NULL AS TEXT) AS item_3,
        'daypart_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY SUM(slot_score) DESC, daypart) AS rank_value,
        COUNT(DISTINCT cs.business_id) AS businesses,
        CAST(NULL AS BIGINT) AS reviews,
        CAST(NULL AS BIGINT) AS tips,
        SUM(slot_score) AS checkin_slots,
        ROUND(AVG(b.stars), 4) AS avg_business_stars,
        CAST(NULL AS DOUBLE) AS avg_review_stars,
        CAST(NULL AS DOUBLE) AS avg_open_days,
        ROUND(100.0 * AVG(CASE WHEN b.active = 'true' THEN 1.0 ELSE 0.0 END), 4) AS active_rate_pct,
        ROUND(100.0 * SUM(slot_score) / SUM(SUM(slot_score)) OVER (), 4) AS share_pct,
        'check-in intensity by broad daypart' AS notes
    FROM checkin_slots cs
    JOIN "Business" b ON cs.business_id = b.business_id
    GROUP BY daypart
),
block_category_hours AS (
    SELECT * FROM (
        SELECT
            'category_hours_mix' AS evidence_block,
            'category' AS grain,
            c.category_name AS item,
            CAST(NULL AS TEXT) AS item_2,
            CAST(NULL AS TEXT) AS item_3,
            'category_business_rank' AS rank_label,
            ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT bm.business_id) DESC, c.category_name) AS rank_value,
            COUNT(DISTINCT bm.business_id) AS businesses,
            SUM(bm.reviews) AS reviews,
            SUM(bm.tips) AS tips,
            SUM(bm.checkin_slots) AS checkin_slots,
            ROUND(AVG(bm.stars), 4) AS avg_business_stars,
            ROUND(AVG(bm.avg_review_stars), 4) AS avg_review_stars,
            ROUND(AVG(bm.open_days), 4) AS avg_open_days,
            ROUND(100.0 * AVG(CASE WHEN bm.active = 'true' THEN 1.0 ELSE 0.0 END), 4) AS active_rate_pct,
            ROUND(100.0 * COUNT(DISTINCT bm.business_id) / MAX(mt.total_businesses), 4) AS share_pct,
            'category differences in listed hours and check-in activity' AS notes
        FROM business_metrics bm
        JOIN "Business_Categories" bc ON bm.business_id = bc.business_id
        JOIN "Categories" c ON bc.category_id = c.category_id
        CROSS JOIN metric_total mt
        GROUP BY c.category_name
    ) x WHERE rank_value <= 20
),
block_active_hours AS (
    SELECT
        'active_hours_overlay' AS evidence_block,
        'active_open_days_bucket' AS grain,
        active AS item,
        open_days_bucket AS item_2,
        CAST(NULL AS TEXT) AS item_3,
        'active_hours_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY active DESC, COUNT(*) DESC) AS rank_value,
        COUNT(*) AS businesses,
        SUM(reviews) AS reviews,
        SUM(tips) AS tips,
        SUM(checkin_slots) AS checkin_slots,
        ROUND(AVG(stars), 4) AS avg_business_stars,
        ROUND(AVG(avg_review_stars), 4) AS avg_review_stars,
        ROUND(AVG(open_days), 4) AS avg_open_days,
        ROUND(100.0 * AVG(CASE WHEN active = 'true' THEN 1.0 ELSE 0.0 END), 4) AS active_rate_pct,
        ROUND(100.0 * COUNT(*) / MAX(mt.total_businesses), 4) AS share_pct,
        'active status crossed with listed open-day breadth' AS notes
    FROM business_metrics bm CROSS JOIN metric_total mt
    GROUP BY active, open_days_bucket
)
SELECT * FROM block_hours_coverage
UNION ALL SELECT * FROM block_open_days
UNION ALL SELECT * FROM block_day
UNION ALL SELECT * FROM block_daypart
UNION ALL SELECT * FROM block_category_hours
UNION ALL SELECT * FROM block_active_hours
