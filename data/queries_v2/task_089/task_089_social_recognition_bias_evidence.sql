WITH elite_by_user AS (
    SELECT user_id, COUNT(*) AS elite_years, MIN(y.actual_year) AS first_elite_year, MAX(y.actual_year) AS last_elite_year
    FROM "Elite" e
    JOIN "Years" y ON e.year_id = y.year_id
    GROUP BY user_id
),
compliment_by_user AS (
    SELECT
        uc.user_id,
        COUNT(*) AS compliment_types,
        MAX(CASE uc.number_of_compliments WHEN 'Low' THEN 1 WHEN 'Medium' THEN 2 WHEN 'High' THEN 3 WHEN 'Uber' THEN 4 ELSE 0 END) AS max_compliment_level
    FROM "Users_Compliments" uc
    GROUP BY uc.user_id
),
user_metrics AS (
    SELECT
        u.user_id,
        u.user_yelping_since_year,
        TRY_CAST(u.user_average_stars AS DOUBLE) AS user_average_stars,
        u.user_votes_useful,
        u.user_votes_funny,
        u.user_votes_cool,
        u.user_review_count,
        u.user_fans,
        COALESCE(e.elite_years, 0) AS elite_years,
        COALESCE(c.compliment_types, 0) AS compliment_types,
        COALESCE(c.max_compliment_level, 0) AS max_compliment_level,
        CASE
            WHEN COALESCE(e.elite_years, 0) >= 3 THEN 'multi_year_elite'
            WHEN COALESCE(e.elite_years, 0) BETWEEN 1 AND 2 THEN 'short_elite'
            WHEN u.user_fans IN ('High', 'Uber') THEN 'high_fan_non_elite'
            WHEN COALESCE(c.max_compliment_level, 0) >= 3 THEN 'high_compliment_non_elite'
            ELSE 'ordinary_or_low_recognition'
        END AS recognition_bucket,
        CASE
            WHEN TRY_CAST(u.user_average_stars AS DOUBLE) >= 4.5 THEN 'user_avg_4.5_to_5'
            WHEN TRY_CAST(u.user_average_stars AS DOUBLE) >= 4.0 THEN 'user_avg_4.0_to_4.49'
            WHEN TRY_CAST(u.user_average_stars AS DOUBLE) >= 3.0 THEN 'user_avg_3.0_to_3.99'
            ELSE 'user_avg_below_3'
        END AS user_rating_bucket
    FROM "Users" u
    LEFT JOIN elite_by_user e ON u.user_id = e.user_id
    LEFT JOIN compliment_by_user c ON u.user_id = c.user_id
),
review_voice AS (
    SELECT
        r.business_id,
        r.user_id,
        r.review_stars,
        r.review_length,
        b.city,
        b.state,
        b.active,
        b.stars AS business_stars,
        b.review_count AS business_review_count,
        CASE
            WHEN b.stars >= 4.5 THEN 'business_4.5_to_5'
            WHEN b.stars >= 4.0 THEN 'business_4.0_to_4.49'
            WHEN b.stars >= 3.0 THEN 'business_3.0_to_3.99'
            ELSE 'business_below_3'
        END AS business_star_bucket,
        um.user_yelping_since_year,
        um.user_average_stars,
        um.user_votes_useful,
        um.user_review_count,
        um.user_fans,
        um.elite_years,
        um.compliment_types,
        um.max_compliment_level,
        um.recognition_bucket,
        um.user_rating_bucket
    FROM "Reviews" r
    JOIN "Business" b ON r.business_id = b.business_id
    JOIN user_metrics um ON r.user_id = um.user_id
),
category_voice AS (
    SELECT rv.*, c.category_name
    FROM review_voice rv
    JOIN "Business_Categories" bc ON rv.business_id = bc.business_id
    JOIN "Categories" c ON bc.category_id = c.category_id
),
compliment_voice AS (
    SELECT
        rv.*,
        co.compliment_type,
        uc.number_of_compliments
    FROM review_voice rv
    JOIN "Users_Compliments" uc ON rv.user_id = uc.user_id
    JOIN "Compliments" co ON uc.compliment_id = co.compliment_id
),
social_segment_baseline AS (
    SELECT
        'social_segment_baseline' AS evidence_block,
        'recognition_bucket' AS grain,
        recognition_bucket AS item,
        '' AS item_2,
        '' AS item_3,
        'recognition_review_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) AS rank_value,
        COUNT(DISTINCT user_id) AS users,
        COUNT(*) AS reviews,
        COUNT(DISTINCT business_id) AS businesses,
        ROUND(AVG(user_average_stars), 4) AS avg_user_stars,
        ROUND(AVG(review_stars), 4) AS avg_review_stars,
        ROUND(AVG(business_stars), 4) AS avg_business_stars,
        ROUND(AVG(CASE WHEN review_length = 'Long' THEN 1.0 ELSE 0.0 END) * 100, 4) AS long_review_rate_pct,
        ROUND(AVG(elite_years), 4) AS avg_elite_years,
        ROUND(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0), 4) AS share_pct,
        'review contribution and rating behavior by user recognition bucket' AS notes
    FROM review_voice
    GROUP BY recognition_bucket
),
city_social_voice AS (
    SELECT
        'city_social_voice' AS evidence_block,
        'city_recognition' AS grain,
        city AS item,
        recognition_bucket AS item_2,
        '' AS item_3,
        'city_recognition_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) AS rank_value,
        COUNT(DISTINCT user_id) AS users,
        COUNT(*) AS reviews,
        COUNT(DISTINCT business_id) AS businesses,
        ROUND(AVG(user_average_stars), 4) AS avg_user_stars,
        ROUND(AVG(review_stars), 4) AS avg_review_stars,
        ROUND(AVG(business_stars), 4) AS avg_business_stars,
        ROUND(AVG(CASE WHEN review_length = 'Long' THEN 1.0 ELSE 0.0 END) * 100, 4) AS long_review_rate_pct,
        ROUND(AVG(elite_years), 4) AS avg_elite_years,
        ROUND(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0), 4) AS share_pct,
        'city-level concentration of recognized reviewer voice' AS notes
    FROM review_voice
    GROUP BY city, recognition_bucket
    QUALIFY ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) <= 30
),
category_social_voice AS (
    SELECT
        'category_social_voice' AS evidence_block,
        'category_recognition' AS grain,
        category_name AS item,
        recognition_bucket AS item_2,
        '' AS item_3,
        'category_recognition_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) AS rank_value,
        COUNT(DISTINCT user_id) AS users,
        COUNT(*) AS reviews,
        COUNT(DISTINCT business_id) AS businesses,
        ROUND(AVG(user_average_stars), 4) AS avg_user_stars,
        ROUND(AVG(review_stars), 4) AS avg_review_stars,
        ROUND(AVG(business_stars), 4) AS avg_business_stars,
        ROUND(AVG(CASE WHEN review_length = 'Long' THEN 1.0 ELSE 0.0 END) * 100, 4) AS long_review_rate_pct,
        ROUND(AVG(elite_years), 4) AS avg_elite_years,
        ROUND(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0), 4) AS share_pct,
        'category-level concentration of recognized reviewer voice' AS notes
    FROM category_voice
    GROUP BY category_name, recognition_bucket
    QUALIFY ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) <= 35
),
compliment_type_signal AS (
    SELECT
        'compliment_type_signal' AS evidence_block,
        'compliment_type_level' AS grain,
        compliment_type AS item,
        number_of_compliments AS item_2,
        recognition_bucket AS item_3,
        'compliment_type_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) AS rank_value,
        COUNT(DISTINCT user_id) AS users,
        COUNT(*) AS reviews,
        COUNT(DISTINCT business_id) AS businesses,
        ROUND(AVG(user_average_stars), 4) AS avg_user_stars,
        ROUND(AVG(review_stars), 4) AS avg_review_stars,
        ROUND(AVG(business_stars), 4) AS avg_business_stars,
        ROUND(AVG(CASE WHEN review_length = 'Long' THEN 1.0 ELSE 0.0 END) * 100, 4) AS long_review_rate_pct,
        ROUND(AVG(elite_years), 4) AS avg_elite_years,
        ROUND(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0), 4) AS share_pct,
        'compliment type and level as user-recognition overlay on review voice' AS notes
    FROM compliment_voice
    GROUP BY compliment_type, number_of_compliments, recognition_bucket
    QUALIFY ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) <= 35
),
join_year_social_shift AS (
    SELECT
        'join_year_social_shift' AS evidence_block,
        'join_year_recognition' AS grain,
        CAST(user_yelping_since_year AS VARCHAR) AS item,
        recognition_bucket AS item_2,
        '' AS item_3,
        'join_year_recognition_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) AS rank_value,
        COUNT(DISTINCT user_id) AS users,
        COUNT(*) AS reviews,
        COUNT(DISTINCT business_id) AS businesses,
        ROUND(AVG(user_average_stars), 4) AS avg_user_stars,
        ROUND(AVG(review_stars), 4) AS avg_review_stars,
        ROUND(AVG(business_stars), 4) AS avg_business_stars,
        ROUND(AVG(CASE WHEN review_length = 'Long' THEN 1.0 ELSE 0.0 END) * 100, 4) AS long_review_rate_pct,
        ROUND(AVG(elite_years), 4) AS avg_elite_years,
        ROUND(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0), 4) AS share_pct,
        'reviewer join year crossed with recognition bucket' AS notes
    FROM review_voice
    GROUP BY CAST(user_yelping_since_year AS VARCHAR), recognition_bucket
    QUALIFY ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) <= 35
),
user_rating_profile AS (
    SELECT
        'user_rating_profile' AS evidence_block,
        'user_rating_recognition' AS grain,
        user_rating_bucket AS item,
        recognition_bucket AS item_2,
        '' AS item_3,
        'user_rating_profile_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) AS rank_value,
        COUNT(DISTINCT user_id) AS users,
        COUNT(*) AS reviews,
        COUNT(DISTINCT business_id) AS businesses,
        ROUND(AVG(user_average_stars), 4) AS avg_user_stars,
        ROUND(AVG(review_stars), 4) AS avg_review_stars,
        ROUND(AVG(business_stars), 4) AS avg_business_stars,
        ROUND(AVG(CASE WHEN review_length = 'Long' THEN 1.0 ELSE 0.0 END) * 100, 4) AS long_review_rate_pct,
        ROUND(AVG(elite_years), 4) AS avg_elite_years,
        ROUND(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0), 4) AS share_pct,
        'user average-star bucket compared with recognition and review behavior' AS notes
    FROM review_voice
    GROUP BY user_rating_bucket, recognition_bucket
),
business_rating_by_social AS (
    SELECT
        'business_rating_by_social' AS evidence_block,
        'business_star_recognition' AS grain,
        business_star_bucket AS item,
        recognition_bucket AS item_2,
        '' AS item_3,
        'business_star_recognition_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) AS rank_value,
        COUNT(DISTINCT user_id) AS users,
        COUNT(*) AS reviews,
        COUNT(DISTINCT business_id) AS businesses,
        ROUND(AVG(user_average_stars), 4) AS avg_user_stars,
        ROUND(AVG(review_stars), 4) AS avg_review_stars,
        ROUND(AVG(business_stars), 4) AS avg_business_stars,
        ROUND(AVG(CASE WHEN review_length = 'Long' THEN 1.0 ELSE 0.0 END) * 100, 4) AS long_review_rate_pct,
        ROUND(AVG(elite_years), 4) AS avg_elite_years,
        ROUND(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0), 4) AS share_pct,
        'business rating bucket viewed through reviewer recognition composition' AS notes
    FROM review_voice
    GROUP BY business_star_bucket, recognition_bucket
)
SELECT * FROM social_segment_baseline
UNION ALL SELECT * FROM city_social_voice
UNION ALL SELECT * FROM category_social_voice
UNION ALL SELECT * FROM compliment_type_signal
UNION ALL SELECT * FROM join_year_social_shift
UNION ALL SELECT * FROM user_rating_profile
UNION ALL SELECT * FROM business_rating_by_social
