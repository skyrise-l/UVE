WITH business_metrics AS (
    SELECT
        b.business_id,
        b.active,
        b.city,
        b.state,
        b.stars,
        b.review_count,
        COALESCE(r.reviews, 0) AS reviews,
        r.avg_review_stars,
        COALESCE(t.tips, 0) AS tips
    FROM "Business" b
    LEFT JOIN (
        SELECT business_id, COUNT(*) AS reviews, AVG(review_stars) AS avg_review_stars
        FROM "Reviews"
        GROUP BY business_id
    ) r ON b.business_id = r.business_id
    LEFT JOIN (
        SELECT business_id, COUNT(*) AS tips
        FROM "Tips"
        GROUP BY business_id
    ) t ON b.business_id = t.business_id
),
hours_rows AS (
    SELECT
        bh.business_id,
        d.day_of_week,
        bh.opening_time,
        bh.closing_time,
        CASE
            WHEN bh.opening_time IN ('12AM', '1AM', '2AM', '3AM', '4AM', '5AM', '6AM', '7AM') THEN 'early_before_8am'
            WHEN bh.opening_time IN ('8AM', '9AM', '10AM') THEN 'morning_8_to_10am'
            WHEN bh.opening_time IN ('11AM', '12PM', '1PM', '2PM') THEN 'midday_opening'
            ELSE 'late_or_unclear_opening'
        END AS opening_bucket,
        CASE
            WHEN bh.closing_time IN ('12AM', '1AM', '2AM', '3AM', '4AM', '5AM') THEN 'late_night_or_next_day_close'
            WHEN bh.closing_time IN ('10PM', '11PM') THEN 'late_evening_close'
            WHEN bh.closing_time IN ('6PM', '7PM', '8PM', '9PM') THEN 'evening_close'
            ELSE 'daytime_or_unclear_close'
        END AS closing_bucket,
        CASE WHEN d.day_of_week IN ('Saturday', 'Sunday') THEN 'weekend' ELSE 'weekday' END AS weekpart
    FROM "Business_Hours" bh
    JOIN "Days" d ON bh.day_id = d.day_id
),
schedule_by_business AS (
    SELECT
        business_id,
        COUNT(*) AS open_days,
        SUM(CASE WHEN opening_bucket = 'early_before_8am' THEN 1 ELSE 0 END) AS early_days,
        SUM(CASE WHEN closing_bucket IN ('late_night_or_next_day_close', 'late_evening_close') THEN 1 ELSE 0 END) AS late_days,
        SUM(CASE WHEN weekpart = 'weekend' THEN 1 ELSE 0 END) AS weekend_days,
        SUM(CASE WHEN weekpart = 'weekday' THEN 1 ELSE 0 END) AS weekday_days,
        CASE
            WHEN COUNT(*) = 7 THEN 'seven_day_schedule'
            WHEN COUNT(*) BETWEEN 4 AND 6 THEN 'four_to_six_day_schedule'
            ELSE 'one_to_three_day_schedule'
        END AS schedule_breadth,
        CASE
            WHEN SUM(CASE WHEN opening_bucket = 'early_before_8am' THEN 1 ELSE 0 END) > 0 AND SUM(CASE WHEN closing_bucket IN ('late_night_or_next_day_close', 'late_evening_close') THEN 1 ELSE 0 END) > 0 THEN 'early_and_late_schedule'
            WHEN SUM(CASE WHEN opening_bucket = 'early_before_8am' THEN 1 ELSE 0 END) > 0 THEN 'early_opening_schedule'
            WHEN SUM(CASE WHEN closing_bucket IN ('late_night_or_next_day_close', 'late_evening_close') THEN 1 ELSE 0 END) > 0 THEN 'late_closing_schedule'
            ELSE 'standard_or_unclear_schedule'
        END AS schedule_shape
    FROM hours_rows
    GROUP BY business_id
),
business_schedule AS (
    SELECT
        bm.*,
        COALESCE(sb.open_days, 0) AS open_days,
        COALESCE(sb.early_days, 0) AS early_days,
        COALESCE(sb.late_days, 0) AS late_days,
        COALESCE(sb.weekend_days, 0) AS weekend_days,
        COALESCE(sb.weekday_days, 0) AS weekday_days,
        COALESCE(sb.schedule_breadth, 'no_hours_listed') AS schedule_breadth,
        COALESCE(sb.schedule_shape, 'no_hours_listed') AS schedule_shape
    FROM business_metrics bm
    LEFT JOIN schedule_by_business sb ON bm.business_id = sb.business_id
),
checkin_slots AS (
    SELECT c.business_id, d.day_of_week, v.hour_num, v.value_label,
        CASE v.value_label WHEN 'Low' THEN 1 WHEN 'Medium' THEN 2 WHEN 'High' THEN 3 WHEN 'Uber' THEN 4 ELSE 0 END AS slot_score,
        CASE
            WHEN v.hour_num BETWEEN 6 AND 10 THEN 'morning'
            WHEN v.hour_num BETWEEN 11 AND 16 THEN 'afternoon'
            WHEN v.hour_num BETWEEN 17 AND 21 THEN 'evening'
            ELSE 'late_night'
        END AS daypart
    FROM "Checkins" c
    JOIN "Days" d ON c.day_id = d.day_id
    CROSS JOIN LATERAL (VALUES
        (0, c.label_time_0), (1, c.label_time_1), (2, c.label_time_2), (3, c.label_time_3),
        (4, c.label_time_4), (5, c.label_time_5), (6, c.label_time_6), (7, c.label_time_7),
        (8, c.label_time_8), (9, c.label_time_9), (10, c.label_time_10), (11, c.label_time_11),
        (12, c.label_time_12), (13, c.label_time_13), (14, c.label_time_14), (15, c.label_time_15),
        (16, c.label_time_16), (17, c.label_time_17), (18, c.label_time_18), (19, c.label_time_19),
        (20, c.label_time_20), (21, c.label_time_21), (22, c.label_time_22), (23, c.label_time_23)
    ) AS v(hour_num, value_label)
    WHERE v.value_label <> 'None'
),
category_schedule AS (
    SELECT bs.*, c.category_name
    FROM business_schedule bs
    JOIN "Business_Categories" bc ON bs.business_id = bc.business_id
    JOIN "Categories" c ON bc.category_id = c.category_id
),
schedule_coverage AS (
    SELECT
        'schedule_coverage' AS evidence_block,
        'schedule_presence' AS grain,
        CASE WHEN open_days = 0 THEN 'no_hours_listed' ELSE 'has_hours_listed' END AS item,
        '' AS item_2,
        '' AS item_3,
        'schedule_presence_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) AS rank_value,
        COUNT(DISTINCT business_id) AS businesses,
        SUM(reviews) AS reviews,
        SUM(tips) AS tips,
        CAST(NULL AS BIGINT) AS checkin_slots,
        ROUND(AVG(stars), 4) AS avg_business_stars,
        ROUND(AVG(avg_review_stars), 4) AS avg_review_stars,
        ROUND(AVG(open_days), 4) AS avg_open_days,
        ROUND(COUNT(DISTINCT business_id) * 100.0 / NULLIF((SELECT COUNT(*) FROM "Business"), 0), 4) AS share_pct,
        'basic coverage of listed operating schedules' AS notes
    FROM business_schedule
    GROUP BY CASE WHEN open_days = 0 THEN 'no_hours_listed' ELSE 'has_hours_listed' END
),
opening_time_profile AS (
    SELECT
        'opening_time_profile' AS evidence_block,
        'opening_bucket' AS grain,
        opening_bucket AS item,
        '' AS item_2,
        '' AS item_3,
        'opening_bucket_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) AS rank_value,
        COUNT(DISTINCT hr.business_id) AS businesses,
        SUM(bm.reviews) AS reviews,
        SUM(bm.tips) AS tips,
        CAST(NULL AS BIGINT) AS checkin_slots,
        ROUND(AVG(bm.stars), 4) AS avg_business_stars,
        ROUND(AVG(bm.avg_review_stars), 4) AS avg_review_stars,
        ROUND(AVG(CAST(NULL AS DOUBLE)), 4) AS avg_open_days,
        ROUND(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0), 4) AS share_pct,
        'opening time buckets by listed day rows' AS notes
    FROM hours_rows hr
    JOIN business_metrics bm ON hr.business_id = bm.business_id
    GROUP BY opening_bucket
),
closing_time_profile AS (
    SELECT
        'closing_time_profile' AS evidence_block,
        'closing_bucket' AS grain,
        closing_bucket AS item,
        '' AS item_2,
        '' AS item_3,
        'closing_bucket_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) AS rank_value,
        COUNT(DISTINCT hr.business_id) AS businesses,
        SUM(bm.reviews) AS reviews,
        SUM(bm.tips) AS tips,
        CAST(NULL AS BIGINT) AS checkin_slots,
        ROUND(AVG(bm.stars), 4) AS avg_business_stars,
        ROUND(AVG(bm.avg_review_stars), 4) AS avg_review_stars,
        ROUND(AVG(CAST(NULL AS DOUBLE)), 4) AS avg_open_days,
        ROUND(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0), 4) AS share_pct,
        'closing time buckets by listed day rows' AS notes
    FROM hours_rows hr
    JOIN business_metrics bm ON hr.business_id = bm.business_id
    GROUP BY closing_bucket
),
operating_breadth AS (
    SELECT
        'operating_breadth' AS evidence_block,
        'schedule_breadth' AS grain,
        schedule_breadth AS item,
        schedule_shape AS item_2,
        '' AS item_3,
        'schedule_breadth_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT business_id) DESC) AS rank_value,
        COUNT(DISTINCT business_id) AS businesses,
        SUM(reviews) AS reviews,
        SUM(tips) AS tips,
        CAST(NULL AS BIGINT) AS checkin_slots,
        ROUND(AVG(stars), 4) AS avg_business_stars,
        ROUND(AVG(avg_review_stars), 4) AS avg_review_stars,
        ROUND(AVG(open_days), 4) AS avg_open_days,
        ROUND(COUNT(DISTINCT business_id) * 100.0 / NULLIF((SELECT COUNT(*) FROM "Business"), 0), 4) AS share_pct,
        'open-day breadth crossed with early and late schedule shape' AS notes
    FROM business_schedule
    GROUP BY schedule_breadth, schedule_shape
),
schedule_checkin_alignment AS (
    SELECT
        'schedule_checkin_alignment' AS evidence_block,
        'schedule_shape_daypart' AS grain,
        bs.schedule_shape AS item,
        cs.daypart AS item_2,
        '' AS item_3,
        'schedule_daypart_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY SUM(cs.slot_score) DESC) AS rank_value,
        COUNT(DISTINCT bs.business_id) AS businesses,
        SUM(bs.reviews) AS reviews,
        SUM(bs.tips) AS tips,
        SUM(cs.slot_score) AS checkin_slots,
        ROUND(AVG(bs.stars), 4) AS avg_business_stars,
        ROUND(AVG(bs.avg_review_stars), 4) AS avg_review_stars,
        ROUND(AVG(bs.open_days), 4) AS avg_open_days,
        ROUND(SUM(cs.slot_score) * 100.0 / NULLIF(SUM(SUM(cs.slot_score)) OVER (), 0), 4) AS share_pct,
        'listed schedule shape compared with observed check-in daypart intensity' AS notes
    FROM business_schedule bs
    JOIN checkin_slots cs ON bs.business_id = cs.business_id
    GROUP BY bs.schedule_shape, cs.daypart
),
category_schedule_profile AS (
    SELECT
        'category_schedule_profile' AS evidence_block,
        'category_schedule_shape' AS grain,
        category_name AS item,
        schedule_shape AS item_2,
        schedule_breadth AS item_3,
        'category_schedule_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT business_id) DESC) AS rank_value,
        COUNT(DISTINCT business_id) AS businesses,
        SUM(reviews) AS reviews,
        SUM(tips) AS tips,
        CAST(NULL AS BIGINT) AS checkin_slots,
        ROUND(AVG(stars), 4) AS avg_business_stars,
        ROUND(AVG(avg_review_stars), 4) AS avg_review_stars,
        ROUND(AVG(open_days), 4) AS avg_open_days,
        ROUND(COUNT(DISTINCT business_id) * 100.0 / NULLIF((SELECT COUNT(*) FROM "Business"), 0), 4) AS share_pct,
        'category mix of schedule shapes and open-day breadth' AS notes
    FROM category_schedule
    GROUP BY category_name, schedule_shape, schedule_breadth
    QUALIFY ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT business_id) DESC) <= 35
),
active_schedule_gap AS (
    SELECT
        'active_schedule_gap' AS evidence_block,
        'active_schedule_shape' AS grain,
        active AS item,
        schedule_shape AS item_2,
        schedule_breadth AS item_3,
        'active_schedule_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT business_id) DESC) AS rank_value,
        COUNT(DISTINCT business_id) AS businesses,
        SUM(reviews) AS reviews,
        SUM(tips) AS tips,
        CAST(NULL AS BIGINT) AS checkin_slots,
        ROUND(AVG(stars), 4) AS avg_business_stars,
        ROUND(AVG(avg_review_stars), 4) AS avg_review_stars,
        ROUND(AVG(open_days), 4) AS avg_open_days,
        ROUND(COUNT(DISTINCT business_id) * 100.0 / NULLIF((SELECT COUNT(*) FROM "Business"), 0), 4) AS share_pct,
        'active status crossed with schedule shape and listing completeness' AS notes
    FROM business_schedule
    GROUP BY active, schedule_shape, schedule_breadth
)
SELECT * FROM schedule_coverage
UNION ALL SELECT * FROM opening_time_profile
UNION ALL SELECT * FROM closing_time_profile
UNION ALL SELECT * FROM operating_breadth
UNION ALL SELECT * FROM schedule_checkin_alignment
UNION ALL SELECT * FROM category_schedule_profile
UNION ALL SELECT * FROM active_schedule_gap
