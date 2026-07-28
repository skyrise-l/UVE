WITH review_by_business AS (
    SELECT
        business_id,
        COUNT(*) AS reviews,
        AVG(review_stars) AS avg_review_stars,
        AVG(CASE WHEN review_length = 'Long' THEN 1.0 ELSE 0.0 END) AS long_review_rate,
        AVG(CASE WHEN COALESCE(review_votes_useful, 'None') <> 'None' THEN 1.0 ELSE 0.0 END) AS useful_vote_rate
    FROM "Reviews"
    GROUP BY business_id
),
tip_by_business AS (
    SELECT
        business_id,
        COUNT(*) AS tips,
        SUM(likes) AS tip_likes,
        AVG(CASE WHEN tip_length = 'Long' THEN 1.0 ELSE 0.0 END) AS long_tip_rate,
        AVG(CASE WHEN likes > 0 THEN 1.0 ELSE 0.0 END) AS liked_tip_rate
    FROM "Tips"
    GROUP BY business_id
),
checkin_by_business AS (
    SELECT
        business_id,
        SUM(
            CASE WHEN label_time_0 <> 'None' THEN 1 ELSE 0 END + CASE WHEN label_time_1 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN label_time_2 <> 'None' THEN 1 ELSE 0 END + CASE WHEN label_time_3 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN label_time_4 <> 'None' THEN 1 ELSE 0 END + CASE WHEN label_time_5 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN label_time_6 <> 'None' THEN 1 ELSE 0 END + CASE WHEN label_time_7 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN label_time_8 <> 'None' THEN 1 ELSE 0 END + CASE WHEN label_time_9 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN label_time_10 <> 'None' THEN 1 ELSE 0 END + CASE WHEN label_time_11 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN label_time_12 <> 'None' THEN 1 ELSE 0 END + CASE WHEN label_time_13 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN label_time_14 <> 'None' THEN 1 ELSE 0 END + CASE WHEN label_time_15 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN label_time_16 <> 'None' THEN 1 ELSE 0 END + CASE WHEN label_time_17 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN label_time_18 <> 'None' THEN 1 ELSE 0 END + CASE WHEN label_time_19 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN label_time_20 <> 'None' THEN 1 ELSE 0 END + CASE WHEN label_time_21 <> 'None' THEN 1 ELSE 0 END +
            CASE WHEN label_time_22 <> 'None' THEN 1 ELSE 0 END + CASE WHEN label_time_23 <> 'None' THEN 1 ELSE 0 END
        ) AS checkin_slots
    FROM "Checkins"
    GROUP BY business_id
),
business_signal AS (
    SELECT
        b.business_id,
        b.active,
        b.city,
        b.state,
        b.stars,
        b.review_count,
        COALESCE(rb.reviews, 0) AS reviews,
        rb.avg_review_stars,
        COALESCE(rb.long_review_rate, 0) AS long_review_rate,
        COALESCE(rb.useful_vote_rate, 0) AS useful_vote_rate,
        COALESCE(tb.tips, 0) AS tips,
        COALESCE(tb.tip_likes, 0) AS tip_likes,
        COALESCE(tb.long_tip_rate, 0) AS long_tip_rate,
        COALESCE(tb.liked_tip_rate, 0) AS liked_tip_rate,
        COALESCE(cb.checkin_slots, 0) AS checkin_slots,
        CASE
            WHEN COALESCE(rb.reviews, 0) > 0 AND COALESCE(tb.tips, 0) > 0 THEN 'reviews_and_tips'
            WHEN COALESCE(rb.reviews, 0) > 0 THEN 'reviews_without_tips'
            WHEN COALESCE(tb.tips, 0) > 0 THEN 'tips_without_reviews'
            ELSE 'no_review_or_tip'
        END AS review_tip_coverage,
        CASE
            WHEN COALESCE(tb.tips, 0) >= 50 THEN 'high_tip_depth'
            WHEN COALESCE(tb.tips, 0) >= 10 THEN 'medium_tip_depth'
            WHEN COALESCE(tb.tips, 0) > 0 THEN 'low_tip_depth'
            ELSE 'no_tips'
        END AS tip_depth_bucket,
        CASE
            WHEN COALESCE(cb.checkin_slots, 0) >= 100 THEN 'high_checkin_signal'
            WHEN COALESCE(cb.checkin_slots, 0) > 0 THEN 'some_checkin_signal'
            ELSE 'no_checkin_signal'
        END AS checkin_signal_bucket
    FROM "Business" b
    LEFT JOIN review_by_business rb ON b.business_id = rb.business_id
    LEFT JOIN tip_by_business tb ON b.business_id = tb.business_id
    LEFT JOIN checkin_by_business cb ON b.business_id = cb.business_id
),
tip_rows AS (
    SELECT
        t.business_id,
        t.user_id,
        t.likes,
        t.tip_length,
        u.user_review_count,
        u.user_fans,
        CASE WHEN t.likes > 0 THEN 'has_likes' ELSE 'zero_likes' END AS like_bucket,
        CASE WHEN r.business_id IS NOT NULL THEN 'tip_with_matching_review' ELSE 'tip_without_matching_review' END AS tip_review_pair_status
    FROM "Tips" t
    LEFT JOIN "Reviews" r ON t.business_id = r.business_id AND t.user_id = r.user_id
    LEFT JOIN "Users" u ON t.user_id = u.user_id
),
category_signal AS (
    SELECT bs.*, c.category_name
    FROM business_signal bs
    JOIN "Business_Categories" bc ON bs.business_id = bc.business_id
    JOIN "Categories" c ON bc.category_id = c.category_id
),
tip_review_coverage AS (
    SELECT
        'tip_review_coverage' AS evidence_block,
        'review_tip_coverage' AS grain,
        review_tip_coverage AS item,
        tip_depth_bucket AS item_2,
        '' AS item_3,
        'coverage_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT business_id) DESC) AS rank_value,
        COUNT(DISTINCT business_id) AS businesses,
        CAST(NULL AS BIGINT) AS users,
        SUM(reviews) AS reviews,
        SUM(tips) AS tips,
        SUM(checkin_slots) AS checkin_slots,
        ROUND(AVG(stars), 4) AS avg_business_stars,
        ROUND(AVG(avg_review_stars), 4) AS avg_review_stars,
        ROUND(AVG(long_review_rate) * 100, 4) AS long_review_rate_pct,
        ROUND(AVG(long_tip_rate) * 100, 4) AS long_tip_rate_pct,
        ROUND(AVG(liked_tip_rate) * 100, 4) AS liked_tip_rate_pct,
        ROUND(COUNT(DISTINCT business_id) * 100.0 / NULLIF((SELECT COUNT(*) FROM "Business"), 0), 4) AS share_pct,
        'business-level coverage of formal reviews and lightweight tips' AS notes
    FROM business_signal
    GROUP BY review_tip_coverage, tip_depth_bucket
),
tip_length_like_baseline AS (
    SELECT
        'tip_length_like_baseline' AS evidence_block,
        'tip_length_like' AS grain,
        tip_length AS item,
        like_bucket AS item_2,
        '' AS item_3,
        'tip_length_like_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) AS rank_value,
        COUNT(DISTINCT business_id) AS businesses,
        COUNT(DISTINCT user_id) AS users,
        CAST(NULL AS BIGINT) AS reviews,
        COUNT(*) AS tips,
        CAST(NULL AS BIGINT) AS checkin_slots,
        ROUND(AVG(CAST(NULL AS DOUBLE)), 4) AS avg_business_stars,
        ROUND(AVG(CAST(NULL AS DOUBLE)), 4) AS avg_review_stars,
        ROUND(AVG(CAST(NULL AS DOUBLE)), 4) AS long_review_rate_pct,
        ROUND(AVG(CASE WHEN tip_length = 'Long' THEN 1.0 ELSE 0.0 END) * 100, 4) AS long_tip_rate_pct,
        ROUND(AVG(CASE WHEN likes > 0 THEN 1.0 ELSE 0.0 END) * 100, 4) AS liked_tip_rate_pct,
        ROUND(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0), 4) AS share_pct,
        'tip text length and like presence' AS notes
    FROM tip_rows
    GROUP BY tip_length, like_bucket
),
tip_review_pairing AS (
    SELECT
        'tip_review_pairing' AS evidence_block,
        'tip_review_pair_status' AS grain,
        tip_review_pair_status AS item,
        COALESCE(user_review_count, 'unknown') AS item_2,
        COALESCE(user_fans, 'unknown') AS item_3,
        'pairing_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) AS rank_value,
        COUNT(DISTINCT business_id) AS businesses,
        COUNT(DISTINCT user_id) AS users,
        CAST(NULL AS BIGINT) AS reviews,
        COUNT(*) AS tips,
        CAST(NULL AS BIGINT) AS checkin_slots,
        ROUND(AVG(CAST(NULL AS DOUBLE)), 4) AS avg_business_stars,
        ROUND(AVG(CAST(NULL AS DOUBLE)), 4) AS avg_review_stars,
        ROUND(AVG(CAST(NULL AS DOUBLE)), 4) AS long_review_rate_pct,
        ROUND(AVG(CASE WHEN tip_length = 'Long' THEN 1.0 ELSE 0.0 END) * 100, 4) AS long_tip_rate_pct,
        ROUND(AVG(CASE WHEN likes > 0 THEN 1.0 ELSE 0.0 END) * 100, 4) AS liked_tip_rate_pct,
        ROUND(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0), 4) AS share_pct,
        'whether tip authors also have matching review rows for the same business' AS notes
    FROM tip_rows
    GROUP BY tip_review_pair_status, COALESCE(user_review_count, 'unknown'), COALESCE(user_fans, 'unknown')
    QUALIFY ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) <= 30
),
category_tip_alignment AS (
    SELECT
        'category_tip_alignment' AS evidence_block,
        'category_tip_depth' AS grain,
        category_name AS item,
        tip_depth_bucket AS item_2,
        review_tip_coverage AS item_3,
        'category_tip_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY SUM(tips) DESC) AS rank_value,
        COUNT(DISTINCT business_id) AS businesses,
        CAST(NULL AS BIGINT) AS users,
        SUM(reviews) AS reviews,
        SUM(tips) AS tips,
        SUM(checkin_slots) AS checkin_slots,
        ROUND(AVG(stars), 4) AS avg_business_stars,
        ROUND(AVG(avg_review_stars), 4) AS avg_review_stars,
        ROUND(AVG(long_review_rate) * 100, 4) AS long_review_rate_pct,
        ROUND(AVG(long_tip_rate) * 100, 4) AS long_tip_rate_pct,
        ROUND(AVG(liked_tip_rate) * 100, 4) AS liked_tip_rate_pct,
        ROUND(SUM(tips) * 100.0 / NULLIF(SUM(SUM(tips)) OVER (), 0), 4) AS share_pct,
        'category-level alignment of tips, reviews, ratings, and check-ins' AS notes
    FROM category_signal
    GROUP BY category_name, tip_depth_bucket, review_tip_coverage
    QUALIFY ROW_NUMBER() OVER (ORDER BY SUM(tips) DESC) <= 35
),
city_tip_alignment AS (
    SELECT
        'city_tip_alignment' AS evidence_block,
        'city_tip_depth' AS grain,
        city AS item,
        tip_depth_bucket AS item_2,
        review_tip_coverage AS item_3,
        'city_tip_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY SUM(tips) DESC) AS rank_value,
        COUNT(DISTINCT business_id) AS businesses,
        CAST(NULL AS BIGINT) AS users,
        SUM(reviews) AS reviews,
        SUM(tips) AS tips,
        SUM(checkin_slots) AS checkin_slots,
        ROUND(AVG(stars), 4) AS avg_business_stars,
        ROUND(AVG(avg_review_stars), 4) AS avg_review_stars,
        ROUND(AVG(long_review_rate) * 100, 4) AS long_review_rate_pct,
        ROUND(AVG(long_tip_rate) * 100, 4) AS long_tip_rate_pct,
        ROUND(AVG(liked_tip_rate) * 100, 4) AS liked_tip_rate_pct,
        ROUND(SUM(tips) * 100.0 / NULLIF(SUM(SUM(tips)) OVER (), 0), 4) AS share_pct,
        'city-level alignment of tips, reviews, ratings, and check-ins' AS notes
    FROM business_signal
    GROUP BY city, tip_depth_bucket, review_tip_coverage
    QUALIFY ROW_NUMBER() OVER (ORDER BY SUM(tips) DESC) <= 30
),
checkin_tip_overlay AS (
    SELECT
        'checkin_tip_overlay' AS evidence_block,
        'checkin_tip_depth' AS grain,
        checkin_signal_bucket AS item,
        tip_depth_bucket AS item_2,
        review_tip_coverage AS item_3,
        'checkin_tip_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT business_id) DESC) AS rank_value,
        COUNT(DISTINCT business_id) AS businesses,
        CAST(NULL AS BIGINT) AS users,
        SUM(reviews) AS reviews,
        SUM(tips) AS tips,
        SUM(checkin_slots) AS checkin_slots,
        ROUND(AVG(stars), 4) AS avg_business_stars,
        ROUND(AVG(avg_review_stars), 4) AS avg_review_stars,
        ROUND(AVG(long_review_rate) * 100, 4) AS long_review_rate_pct,
        ROUND(AVG(long_tip_rate) * 100, 4) AS long_tip_rate_pct,
        ROUND(AVG(liked_tip_rate) * 100, 4) AS liked_tip_rate_pct,
        ROUND(COUNT(DISTINCT business_id) * 100.0 / NULLIF((SELECT COUNT(*) FROM "Business"), 0), 4) AS share_pct,
        'tip depth compared with check-in signal and review coverage' AS notes
    FROM business_signal
    GROUP BY checkin_signal_bucket, tip_depth_bucket, review_tip_coverage
)
SELECT * FROM tip_review_coverage
UNION ALL SELECT * FROM tip_length_like_baseline
UNION ALL SELECT * FROM tip_review_pairing
UNION ALL SELECT * FROM category_tip_alignment
UNION ALL SELECT * FROM city_tip_alignment
UNION ALL SELECT * FROM checkin_tip_overlay
