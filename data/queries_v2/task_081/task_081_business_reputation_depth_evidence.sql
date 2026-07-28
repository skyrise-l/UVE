WITH business_base AS (
    SELECT
        b.business_id,
        b.active,
        b.city,
        b.state,
        b.stars,
        b.review_count,
        CASE b.review_count
            WHEN 'Low' THEN 1
            WHEN 'Medium' THEN 2
            WHEN 'High' THEN 3
            WHEN 'Uber' THEN 4
            ELSE 0
        END AS review_count_level,
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
        AVG(CASE WHEN r.review_length = 'Long' THEN 1.0 ELSE 0.0 END) AS long_review_rate,
        AVG(CASE WHEN COALESCE(r.review_votes_useful, 'None') <> 'None' THEN 1.0 ELSE 0.0 END) AS useful_vote_rate
    FROM "Reviews" r
    GROUP BY r.business_id
),
tip_by_business AS (
    SELECT
        t.business_id,
        COUNT(*) AS tips,
        AVG(t.likes) AS avg_tip_likes,
        AVG(CASE WHEN t.tip_length = 'Long' THEN 1.0 ELSE 0.0 END) AS long_tip_rate
    FROM "Tips" t
    GROUP BY t.business_id
),
checkin_by_business AS (
    SELECT
        c.business_id,
        SUM(
            CASE WHEN c.label_time_0 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_1 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_2 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_3 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_4 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_5 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_6 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_7 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_8 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_9 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_10 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_11 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_12 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_13 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_14 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_15 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_16 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_17 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_18 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_19 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_20 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_21 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_22 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN c.label_time_23 <> 'None' THEN 1 ELSE 0 END
        ) AS checkin_slots
    FROM "Checkins" c
    GROUP BY c.business_id
),
business_metrics AS (
    SELECT
        bb.*,
        COALESCE(rb.reviews, 0) AS reviews,
        rb.avg_review_stars,
        COALESCE(rb.long_review_rate, 0) AS long_review_rate,
        COALESCE(rb.useful_vote_rate, 0) AS useful_vote_rate,
        COALESCE(tb.tips, 0) AS tips,
        COALESCE(tb.avg_tip_likes, 0) AS avg_tip_likes,
        COALESCE(tb.long_tip_rate, 0) AS long_tip_rate,
        COALESCE(cb.checkin_slots, 0) AS checkin_slots
    FROM business_base bb
    LEFT JOIN review_by_business rb ON bb.business_id = rb.business_id
    LEFT JOIN tip_by_business tb ON bb.business_id = tb.business_id
    LEFT JOIN checkin_by_business cb ON bb.business_id = cb.business_id
),
metric_total AS (
    SELECT COUNT(*) AS total_businesses FROM business_metrics
),
block_rating_depth AS (
    SELECT
        'rating_review_depth' AS evidence_block,
        'star_bucket_review_depth' AS grain,
        star_bucket AS item,
        review_count AS item_2,
        CAST(NULL AS TEXT) AS item_3,
        'business_volume_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, star_bucket, review_count) AS rank_value,
        COUNT(*) AS businesses,
        SUM(reviews) AS reviews,
        SUM(tips) AS tips,
        SUM(checkin_slots) AS checkin_slots,
        ROUND(AVG(stars), 4) AS avg_business_stars,
        ROUND(AVG(avg_review_stars), 4) AS avg_review_stars,
        ROUND(100.0 * AVG(CASE WHEN active = 'true' THEN 1.0 ELSE 0.0 END), 4) AS active_rate_pct,
        ROUND(100.0 * AVG(long_review_rate), 4) AS long_review_rate_pct,
        ROUND(100.0 * AVG(long_tip_rate), 4) AS long_tip_rate_pct,
        ROUND(100.0 * COUNT(*) / MAX(mt.total_businesses), 4) AS share_pct,
        'business star bucket crossed with platform review-count label' AS notes
    FROM business_metrics bm CROSS JOIN metric_total mt
    GROUP BY star_bucket, review_count
),
block_city AS (
    SELECT * FROM (
        SELECT
            'city_market_quality' AS evidence_block,
            'city' AS grain,
            city AS item,
            state AS item_2,
            CAST(NULL AS TEXT) AS item_3,
            'city_business_rank' AS rank_label,
            ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, city) AS rank_value,
            COUNT(*) AS businesses,
            SUM(reviews) AS reviews,
            SUM(tips) AS tips,
            SUM(checkin_slots) AS checkin_slots,
            ROUND(AVG(stars), 4) AS avg_business_stars,
            ROUND(AVG(avg_review_stars), 4) AS avg_review_stars,
            ROUND(100.0 * AVG(CASE WHEN active = 'true' THEN 1.0 ELSE 0.0 END), 4) AS active_rate_pct,
            ROUND(100.0 * AVG(long_review_rate), 4) AS long_review_rate_pct,
            ROUND(100.0 * AVG(long_tip_rate), 4) AS long_tip_rate_pct,
            ROUND(100.0 * COUNT(*) / MAX(mt.total_businesses), 4) AS share_pct,
            'largest city markets with quality and activity overlays' AS notes
        FROM business_metrics bm CROSS JOIN metric_total mt
        GROUP BY city, state
    ) x WHERE rank_value <= 15
),
block_category AS (
    SELECT * FROM (
        SELECT
            'category_quality' AS evidence_block,
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
            ROUND(100.0 * AVG(CASE WHEN bm.active = 'true' THEN 1.0 ELSE 0.0 END), 4) AS active_rate_pct,
            ROUND(100.0 * AVG(bm.long_review_rate), 4) AS long_review_rate_pct,
            ROUND(100.0 * AVG(bm.long_tip_rate), 4) AS long_tip_rate_pct,
            ROUND(100.0 * COUNT(DISTINCT bm.business_id) / MAX(mt.total_businesses), 4) AS share_pct,
            'largest categories compared on rating, activity, and active status' AS notes
        FROM business_metrics bm
        JOIN "Business_Categories" bc ON bm.business_id = bc.business_id
        JOIN "Categories" c ON bc.category_id = c.category_id
        CROSS JOIN metric_total mt
        GROUP BY c.category_name
    ) x WHERE rank_value <= 20
),
block_alignment AS (
    SELECT
        'review_depth_alignment' AS evidence_block,
        'review_count_label' AS grain,
        review_count AS item,
        CAST(NULL AS TEXT) AS item_2,
        CAST(NULL AS TEXT) AS item_3,
        'review_depth_order' AS rank_label,
        MIN(review_count_level) AS rank_value,
        COUNT(*) AS businesses,
        SUM(reviews) AS reviews,
        SUM(tips) AS tips,
        SUM(checkin_slots) AS checkin_slots,
        ROUND(AVG(stars), 4) AS avg_business_stars,
        ROUND(AVG(avg_review_stars), 4) AS avg_review_stars,
        ROUND(100.0 * AVG(CASE WHEN active = 'true' THEN 1.0 ELSE 0.0 END), 4) AS active_rate_pct,
        ROUND(100.0 * AVG(long_review_rate), 4) AS long_review_rate_pct,
        ROUND(100.0 * AVG(long_tip_rate), 4) AS long_tip_rate_pct,
        ROUND(100.0 * COUNT(*) / MAX(mt.total_businesses), 4) AS share_pct,
        'whether higher platform review-depth labels carry different average star levels' AS notes
    FROM business_metrics bm CROSS JOIN metric_total mt
    GROUP BY review_count
),
block_review_voice AS (
    SELECT
        'review_voice_overlay' AS evidence_block,
        'linked_review_star_bucket' AS grain,
        CASE
            WHEN avg_review_stars >= 4.5 THEN 'linked_reviews_4.5_to_5'
            WHEN avg_review_stars >= 4.0 THEN 'linked_reviews_4.0_to_4.49'
            WHEN avg_review_stars >= 3.0 THEN 'linked_reviews_3.0_to_3.99'
            WHEN avg_review_stars IS NULL THEN 'no_linked_review_rows'
            ELSE 'linked_reviews_below_3'
        END AS item,
        CAST(NULL AS TEXT) AS item_2,
        CAST(NULL AS TEXT) AS item_3,
        'linked_review_bucket_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) AS rank_value,
        COUNT(*) AS businesses,
        SUM(reviews) AS reviews,
        SUM(tips) AS tips,
        SUM(checkin_slots) AS checkin_slots,
        ROUND(AVG(stars), 4) AS avg_business_stars,
        ROUND(AVG(avg_review_stars), 4) AS avg_review_stars,
        ROUND(100.0 * AVG(CASE WHEN active = 'true' THEN 1.0 ELSE 0.0 END), 4) AS active_rate_pct,
        ROUND(100.0 * AVG(long_review_rate), 4) AS long_review_rate_pct,
        ROUND(100.0 * AVG(long_tip_rate), 4) AS long_tip_rate_pct,
        ROUND(100.0 * COUNT(*) / MAX(mt.total_businesses), 4) AS share_pct,
        'business stars compared with linked review-row star averages' AS notes
    FROM business_metrics bm CROSS JOIN metric_total mt
    GROUP BY CASE
            WHEN avg_review_stars >= 4.5 THEN 'linked_reviews_4.5_to_5'
            WHEN avg_review_stars >= 4.0 THEN 'linked_reviews_4.0_to_4.49'
            WHEN avg_review_stars >= 3.0 THEN 'linked_reviews_3.0_to_3.99'
            WHEN avg_review_stars IS NULL THEN 'no_linked_review_rows'
            ELSE 'linked_reviews_below_3'
        END
),
block_active AS (
    SELECT
        'active_status_quality' AS evidence_block,
        'active_status' AS grain,
        active AS item,
        review_count AS item_2,
        CAST(NULL AS TEXT) AS item_3,
        'active_review_depth_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY active DESC, COUNT(*) DESC) AS rank_value,
        COUNT(*) AS businesses,
        SUM(reviews) AS reviews,
        SUM(tips) AS tips,
        SUM(checkin_slots) AS checkin_slots,
        ROUND(AVG(stars), 4) AS avg_business_stars,
        ROUND(AVG(avg_review_stars), 4) AS avg_review_stars,
        ROUND(100.0 * AVG(CASE WHEN active = 'true' THEN 1.0 ELSE 0.0 END), 4) AS active_rate_pct,
        ROUND(100.0 * AVG(long_review_rate), 4) AS long_review_rate_pct,
        ROUND(100.0 * AVG(long_tip_rate), 4) AS long_tip_rate_pct,
        ROUND(100.0 * COUNT(*) / MAX(mt.total_businesses), 4) AS share_pct,
        'active status crossed with platform review-depth label' AS notes
    FROM business_metrics bm CROSS JOIN metric_total mt
    GROUP BY active, review_count
)
SELECT * FROM block_rating_depth
UNION ALL SELECT * FROM block_city
UNION ALL SELECT * FROM block_category
UNION ALL SELECT * FROM block_alignment
UNION ALL SELECT * FROM block_review_voice
UNION ALL SELECT * FROM block_active
