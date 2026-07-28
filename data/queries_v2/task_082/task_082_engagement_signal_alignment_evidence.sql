WITH business_base AS (
    SELECT
        b.business_id,
        b.active,
        b.city,
        b.state,
        b.stars,
        b.review_count,
        CASE
            WHEN b.stars >= 4.5 THEN '4.5_to_5_star'
            WHEN b.stars >= 4.0 THEN '4.0_to_4.49_star'
            WHEN b.stars >= 3.0 THEN '3.0_to_3.99_star'
            ELSE 'below_3_star'
        END AS star_bucket
    FROM "Business" b
),
review_by_business AS (
    SELECT
        r.business_id,
        COUNT(*) AS reviews,
        AVG(r.review_stars) AS avg_review_stars,
        AVG(CASE WHEN COALESCE(r.review_votes_useful, 'None') <> 'None' THEN 1.0 ELSE 0.0 END) AS useful_vote_rate,
        AVG(CASE WHEN COALESCE(r.review_votes_cool, 'None') <> 'None' THEN 1.0 ELSE 0.0 END) AS cool_vote_rate,
        AVG(CASE WHEN r.review_length = 'Long' THEN 1.0 ELSE 0.0 END) AS long_review_rate
    FROM "Reviews" r
    GROUP BY r.business_id
),
tip_by_business AS (
    SELECT business_id, COUNT(*) AS tips, SUM(likes) AS tip_likes, AVG(CASE WHEN tip_length = 'Long' THEN 1.0 ELSE 0.0 END) AS long_tip_rate
    FROM "Tips"
    GROUP BY business_id
),
checkin_by_business AS (
    SELECT
        c.business_id,
        SUM(
            CASE WHEN c.label_time_0 <> 'None' THEN 1 ELSE 0 END + CASE WHEN c.label_time_1 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_2 <> 'None' THEN 1 ELSE 0 END + CASE WHEN c.label_time_3 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_4 <> 'None' THEN 1 ELSE 0 END + CASE WHEN c.label_time_5 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_6 <> 'None' THEN 1 ELSE 0 END + CASE WHEN c.label_time_7 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_8 <> 'None' THEN 1 ELSE 0 END + CASE WHEN c.label_time_9 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_10 <> 'None' THEN 1 ELSE 0 END + CASE WHEN c.label_time_11 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_12 <> 'None' THEN 1 ELSE 0 END + CASE WHEN c.label_time_13 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_14 <> 'None' THEN 1 ELSE 0 END + CASE WHEN c.label_time_15 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_16 <> 'None' THEN 1 ELSE 0 END + CASE WHEN c.label_time_17 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_18 <> 'None' THEN 1 ELSE 0 END + CASE WHEN c.label_time_19 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_20 <> 'None' THEN 1 ELSE 0 END + CASE WHEN c.label_time_21 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_22 <> 'None' THEN 1 ELSE 0 END + CASE WHEN c.label_time_23 <> 'None' THEN 1 ELSE 0 END
        ) AS checkin_slots
    FROM "Checkins" c
    GROUP BY c.business_id
),
business_metrics AS (
    SELECT
        bb.*,
        COALESCE(rb.reviews, 0) AS reviews,
        rb.avg_review_stars,
        COALESCE(rb.useful_vote_rate, 0) AS useful_vote_rate,
        COALESCE(rb.cool_vote_rate, 0) AS cool_vote_rate,
        COALESCE(rb.long_review_rate, 0) AS long_review_rate,
        COALESCE(tb.tips, 0) AS tips,
        COALESCE(tb.tip_likes, 0) AS tip_likes,
        COALESCE(tb.long_tip_rate, 0) AS long_tip_rate,
        COALESCE(cb.checkin_slots, 0) AS checkin_slots,
        CASE
            WHEN COALESCE(rb.reviews, 0) > 0 AND COALESCE(tb.tips, 0) > 0 AND COALESCE(cb.checkin_slots, 0) > 0 THEN 'reviews_tips_checkins'
            WHEN COALESCE(rb.reviews, 0) > 0 AND COALESCE(tb.tips, 0) > 0 THEN 'reviews_and_tips'
            WHEN COALESCE(rb.reviews, 0) > 0 AND COALESCE(cb.checkin_slots, 0) > 0 THEN 'reviews_and_checkins'
            WHEN COALESCE(rb.reviews, 0) > 0 THEN 'reviews_only'
            WHEN COALESCE(tb.tips, 0) > 0 OR COALESCE(cb.checkin_slots, 0) > 0 THEN 'non_review_activity_only'
            ELSE 'no_linked_activity'
        END AS engagement_bucket
    FROM business_base bb
    LEFT JOIN review_by_business rb ON bb.business_id = rb.business_id
    LEFT JOIN tip_by_business tb ON bb.business_id = tb.business_id
    LEFT JOIN checkin_by_business cb ON bb.business_id = cb.business_id
),
metric_total AS (SELECT COUNT(*) AS total_businesses FROM business_metrics),
checkin_slots AS (
    SELECT c.business_id, d.day_of_week, h.hour_label, h.value_label,
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
block_coverage AS (
    SELECT
        'engagement_coverage_baseline' AS evidence_block,
        'engagement_bucket' AS grain,
        engagement_bucket AS item,
        CAST(NULL AS TEXT) AS item_2,
        CAST(NULL AS TEXT) AS item_3,
        'engagement_bucket_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, engagement_bucket) AS rank_value,
        COUNT(*) AS businesses,
        SUM(reviews) AS reviews,
        SUM(tips) AS tips,
        SUM(checkin_slots) AS checkin_slots,
        ROUND(AVG(stars), 4) AS avg_business_stars,
        ROUND(AVG(avg_review_stars), 4) AS avg_review_stars,
        ROUND(100.0 * AVG(useful_vote_rate), 4) AS useful_vote_rate_pct,
        ROUND(100.0 * AVG(long_review_rate), 4) AS long_review_rate_pct,
        ROUND(100.0 * AVG(long_tip_rate), 4) AS long_tip_rate_pct,
        ROUND(100.0 * COUNT(*) / MAX(mt.total_businesses), 4) AS share_pct,
        'coverage of review, tip, and check-in signals at business level' AS notes
    FROM business_metrics bm CROSS JOIN metric_total mt
    GROUP BY engagement_bucket
),
block_star_gradient AS (
    SELECT
        'star_engagement_gradient' AS evidence_block,
        'star_bucket' AS grain,
        star_bucket AS item,
        CAST(NULL AS TEXT) AS item_2,
        CAST(NULL AS TEXT) AS item_3,
        'star_bucket_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY AVG(stars) DESC) AS rank_value,
        COUNT(*) AS businesses,
        SUM(reviews) AS reviews,
        SUM(tips) AS tips,
        SUM(checkin_slots) AS checkin_slots,
        ROUND(AVG(stars), 4) AS avg_business_stars,
        ROUND(AVG(avg_review_stars), 4) AS avg_review_stars,
        ROUND(100.0 * AVG(useful_vote_rate), 4) AS useful_vote_rate_pct,
        ROUND(100.0 * AVG(long_review_rate), 4) AS long_review_rate_pct,
        ROUND(100.0 * AVG(long_tip_rate), 4) AS long_tip_rate_pct,
        ROUND(100.0 * COUNT(*) / MAX(mt.total_businesses), 4) AS share_pct,
        'whether higher star buckets also carry more engagement signals' AS notes
    FROM business_metrics bm CROSS JOIN metric_total mt
    GROUP BY star_bucket
),
block_category AS (
    SELECT * FROM (
        SELECT
            'category_engagement' AS evidence_block,
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
            ROUND(100.0 * AVG(bm.useful_vote_rate), 4) AS useful_vote_rate_pct,
            ROUND(100.0 * AVG(bm.long_review_rate), 4) AS long_review_rate_pct,
            ROUND(100.0 * AVG(bm.long_tip_rate), 4) AS long_tip_rate_pct,
            ROUND(100.0 * COUNT(DISTINCT bm.business_id) / MAX(mt.total_businesses), 4) AS share_pct,
            'category-level engagement and rating comparison' AS notes
        FROM business_metrics bm
        JOIN "Business_Categories" bc ON bm.business_id = bc.business_id
        JOIN "Categories" c ON bc.category_id = c.category_id
        CROSS JOIN metric_total mt
        GROUP BY c.category_name
    ) x WHERE rank_value <= 20
),
block_user_activity AS (
    SELECT
        'user_activity_overlay' AS evidence_block,
        'reviewer_review_count_label' AS grain,
        u.user_review_count AS item,
        CAST(NULL AS TEXT) AS item_2,
        CAST(NULL AS TEXT) AS item_3,
        'reviewer_label_order' AS rank_label,
        CASE u.user_review_count WHEN 'Low' THEN 1 WHEN 'Medium' THEN 2 WHEN 'High' THEN 3 WHEN 'Uber' THEN 4 ELSE 0 END AS rank_value,
        COUNT(DISTINCT r.business_id) AS businesses,
        COUNT(*) AS reviews,
        CAST(NULL AS BIGINT) AS tips,
        CAST(NULL AS BIGINT) AS checkin_slots,
        ROUND(AVG(b.stars), 4) AS avg_business_stars,
        ROUND(AVG(r.review_stars), 4) AS avg_review_stars,
        ROUND(100.0 * AVG(CASE WHEN COALESCE(r.review_votes_useful, 'None') <> 'None' THEN 1.0 ELSE 0.0 END), 4) AS useful_vote_rate_pct,
        ROUND(100.0 * AVG(CASE WHEN r.review_length = 'Long' THEN 1.0 ELSE 0.0 END), 4) AS long_review_rate_pct,
        CAST(NULL AS DOUBLE) AS long_tip_rate_pct,
        ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 4) AS share_pct,
        'reviewer activity label compared with review stars and review vote signals' AS notes
    FROM "Reviews" r
    JOIN "Users" u ON r.user_id = u.user_id
    JOIN "Business" b ON r.business_id = b.business_id
    GROUP BY u.user_review_count
),
block_tip_like AS (
    SELECT
        'tip_like_signal' AS evidence_block,
        'tip_length_likes' AS grain,
        t.tip_length AS item,
        CASE WHEN t.likes = 0 THEN 'zero_likes' ELSE 'has_likes' END AS item_2,
        CAST(NULL AS TEXT) AS item_3,
        'tip_group_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, t.tip_length, CASE WHEN t.likes = 0 THEN 'zero_likes' ELSE 'has_likes' END) AS rank_value,
        COUNT(DISTINCT t.business_id) AS businesses,
        CAST(NULL AS BIGINT) AS reviews,
        COUNT(*) AS tips,
        CAST(NULL AS BIGINT) AS checkin_slots,
        ROUND(AVG(b.stars), 4) AS avg_business_stars,
        CAST(NULL AS DOUBLE) AS avg_review_stars,
        CAST(NULL AS DOUBLE) AS useful_vote_rate_pct,
        CAST(NULL AS DOUBLE) AS long_review_rate_pct,
        ROUND(100.0 * AVG(CASE WHEN t.tip_length = 'Long' THEN 1.0 ELSE 0.0 END), 4) AS long_tip_rate_pct,
        ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 4) AS share_pct,
        'tip length and like presence as lightweight engagement signal' AS notes
    FROM "Tips" t
    JOIN "Business" b ON t.business_id = b.business_id
    GROUP BY t.tip_length, CASE WHEN t.likes = 0 THEN 'zero_likes' ELSE 'has_likes' END
),
block_daypart AS (
    SELECT
        'checkin_daypart_signal' AS evidence_block,
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
        CAST(NULL AS DOUBLE) AS useful_vote_rate_pct,
        CAST(NULL AS DOUBLE) AS long_review_rate_pct,
        CAST(NULL AS DOUBLE) AS long_tip_rate_pct,
        ROUND(100.0 * SUM(slot_score) / SUM(SUM(slot_score)) OVER (), 4) AS share_pct,
        'check-in timing intensity by broad daypart' AS notes
    FROM checkin_slots cs
    JOIN "Business" b ON cs.business_id = b.business_id
    GROUP BY daypart
)
SELECT * FROM block_coverage
UNION ALL SELECT * FROM block_star_gradient
UNION ALL SELECT * FROM block_category
UNION ALL SELECT * FROM block_user_activity
UNION ALL SELECT * FROM block_tip_like
UNION ALL SELECT * FROM block_daypart
