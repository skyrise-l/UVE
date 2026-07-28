WITH user_base AS (
    SELECT
        u.user_id,
        u.user_yelping_since_year,
        TRY_CAST(u.user_average_stars AS DOUBLE) AS user_average_stars,
        u.user_votes_funny,
        u.user_votes_useful,
        u.user_votes_cool,
        u.user_review_count,
        u.user_fans,
        CASE u.user_review_count WHEN 'Low' THEN 1 WHEN 'Medium' THEN 2 WHEN 'High' THEN 3 WHEN 'Uber' THEN 4 ELSE 0 END AS review_count_level,
        CASE u.user_fans WHEN 'Low' THEN 1 WHEN 'Medium' THEN 2 WHEN 'High' THEN 3 WHEN 'Uber' THEN 4 ELSE 0 END AS fan_level,
        CASE u.user_votes_useful WHEN 'Low' THEN 1 WHEN 'Medium' THEN 2 WHEN 'High' THEN 3 WHEN 'Uber' THEN 4 ELSE 0 END AS useful_vote_level
    FROM "Users" u
),
elite_by_user AS (
    SELECT e.user_id, COUNT(*) AS elite_years, MIN(y.actual_year) AS first_elite_year, MAX(y.actual_year) AS last_elite_year
    FROM "Elite" e
    JOIN "Years" y ON e.year_id = y.year_id
    GROUP BY e.user_id
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
        ub.*,
        COALESCE(eb.elite_years, 0) AS elite_years,
        CASE WHEN COALESCE(eb.elite_years, 0) > 0 THEN 'elite_user' ELSE 'non_elite_user' END AS elite_bucket,
        COALESCE(cb.compliment_types, 0) AS compliment_types,
        COALESCE(cb.max_compliment_level, 0) AS max_compliment_level
    FROM user_base ub
    LEFT JOIN elite_by_user eb ON ub.user_id = eb.user_id
    LEFT JOIN compliment_by_user cb ON ub.user_id = cb.user_id
),
review_fact AS (
    SELECT
        r.business_id,
        r.user_id,
        r.review_stars,
        r.review_length,
        r.review_votes_useful,
        b.stars AS business_stars,
        b.active,
        um.user_yelping_since_year,
        um.user_average_stars,
        um.user_review_count,
        um.user_fans,
        um.user_votes_useful,
        um.elite_bucket,
        um.elite_years,
        um.compliment_types,
        um.max_compliment_level,
        um.useful_vote_level
    FROM "Reviews" r
    JOIN "Business" b ON r.business_id = b.business_id
    JOIN user_metrics um ON r.user_id = um.user_id
),
block_tenure AS (
    SELECT
        'user_tenure_baseline' AS evidence_block,
        'yelping_since_year' AS grain,
        CAST(user_yelping_since_year AS TEXT) AS item,
        CAST(NULL AS TEXT) AS item_2,
        CAST(NULL AS TEXT) AS item_3,
        'user_join_year_order' AS rank_label,
        user_yelping_since_year AS rank_value,
        COUNT(DISTINCT user_id) AS users,
        COUNT(*) AS reviews,
        COUNT(DISTINCT business_id) AS businesses,
        ROUND(AVG(user_average_stars), 4) AS avg_user_stars,
        ROUND(AVG(review_stars), 4) AS avg_review_stars,
        ROUND(AVG(business_stars), 4) AS avg_business_stars,
        ROUND(100.0 * AVG(CASE WHEN elite_bucket = 'elite_user' THEN 1.0 ELSE 0.0 END), 4) AS elite_review_rate_pct,
        ROUND(100.0 * AVG(CASE WHEN review_length = 'Long' THEN 1.0 ELSE 0.0 END), 4) AS long_review_rate_pct,
        ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 4) AS share_pct,
        'review contribution by reviewer join year' AS notes
    FROM review_fact
    GROUP BY user_yelping_since_year
),
block_activity AS (
    SELECT
        'reviewer_activity_rating' AS evidence_block,
        'user_review_count_label' AS grain,
        user_review_count AS item,
        CAST(NULL AS TEXT) AS item_2,
        CAST(NULL AS TEXT) AS item_3,
        'review_count_label_order' AS rank_label,
        CASE user_review_count WHEN 'Low' THEN 1 WHEN 'Medium' THEN 2 WHEN 'High' THEN 3 WHEN 'Uber' THEN 4 ELSE 0 END AS rank_value,
        COUNT(DISTINCT user_id) AS users,
        COUNT(*) AS reviews,
        COUNT(DISTINCT business_id) AS businesses,
        ROUND(AVG(user_average_stars), 4) AS avg_user_stars,
        ROUND(AVG(review_stars), 4) AS avg_review_stars,
        ROUND(AVG(business_stars), 4) AS avg_business_stars,
        ROUND(100.0 * AVG(CASE WHEN elite_bucket = 'elite_user' THEN 1.0 ELSE 0.0 END), 4) AS elite_review_rate_pct,
        ROUND(100.0 * AVG(CASE WHEN review_length = 'Long' THEN 1.0 ELSE 0.0 END), 4) AS long_review_rate_pct,
        ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 4) AS share_pct,
        'review volume and rating by reviewer activity label' AS notes
    FROM review_fact
    GROUP BY user_review_count
),
block_elite AS (
    SELECT
        'elite_review_overlay' AS evidence_block,
        'elite_bucket' AS grain,
        elite_bucket AS item,
        CASE WHEN elite_years >= 3 THEN 'multi_year_elite' WHEN elite_years > 0 THEN 'one_or_two_year_elite' ELSE 'not_elite' END AS item_2,
        CAST(NULL AS TEXT) AS item_3,
        'elite_bucket_rank' AS rank_label,
        ROW_NUMBER() OVER (
            ORDER BY
                COUNT(*) DESC,
                elite_bucket,
                CASE
                    WHEN elite_years >= 3 THEN 'multi_year_elite'
                    WHEN elite_years > 0 THEN 'one_or_two_year_elite'
                    ELSE 'not_elite'
                END
        ) AS rank_value,
        COUNT(DISTINCT user_id) AS users,
        COUNT(*) AS reviews,
        COUNT(DISTINCT business_id) AS businesses,
        ROUND(AVG(user_average_stars), 4) AS avg_user_stars,
        ROUND(AVG(review_stars), 4) AS avg_review_stars,
        ROUND(AVG(business_stars), 4) AS avg_business_stars,
        ROUND(100.0 * AVG(CASE WHEN elite_bucket = 'elite_user' THEN 1.0 ELSE 0.0 END), 4) AS elite_review_rate_pct,
        ROUND(100.0 * AVG(CASE WHEN review_length = 'Long' THEN 1.0 ELSE 0.0 END), 4) AS long_review_rate_pct,
        ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 4) AS share_pct,
        'elite status and duration as a review-source overlay' AS notes
    FROM review_fact
    GROUP BY elite_bucket, CASE WHEN elite_years >= 3 THEN 'multi_year_elite' WHEN elite_years > 0 THEN 'one_or_two_year_elite' ELSE 'not_elite' END
),
block_fans AS (
    SELECT
        'fan_segment_overlay' AS evidence_block,
        'user_fans_label' AS grain,
        COALESCE(user_fans, 'None') AS item,
        CAST(NULL AS TEXT) AS item_2,
        CAST(NULL AS TEXT) AS item_3,
        'fan_label_order' AS rank_label,
        CASE COALESCE(user_fans, 'None') WHEN 'Low' THEN 1 WHEN 'Medium' THEN 2 WHEN 'High' THEN 3 WHEN 'Uber' THEN 4 ELSE 0 END AS rank_value,
        COUNT(DISTINCT user_id) AS users,
        COUNT(*) AS reviews,
        COUNT(DISTINCT business_id) AS businesses,
        ROUND(AVG(user_average_stars), 4) AS avg_user_stars,
        ROUND(AVG(review_stars), 4) AS avg_review_stars,
        ROUND(AVG(business_stars), 4) AS avg_business_stars,
        ROUND(100.0 * AVG(CASE WHEN elite_bucket = 'elite_user' THEN 1.0 ELSE 0.0 END), 4) AS elite_review_rate_pct,
        ROUND(100.0 * AVG(CASE WHEN review_length = 'Long' THEN 1.0 ELSE 0.0 END), 4) AS long_review_rate_pct,
        ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 4) AS share_pct,
        'fan label compared with review contribution and ratings' AS notes
    FROM review_fact
    GROUP BY COALESCE(user_fans, 'None')
),
block_votes AS (
    SELECT
        'vote_segment_overlay' AS evidence_block,
        'user_useful_vote_label' AS grain,
        COALESCE(user_votes_useful, 'None') AS item,
        CAST(NULL AS TEXT) AS item_2,
        CAST(NULL AS TEXT) AS item_3,
        'useful_vote_label_order' AS rank_label,
        CASE COALESCE(user_votes_useful, 'None') WHEN 'Low' THEN 1 WHEN 'Medium' THEN 2 WHEN 'High' THEN 3 WHEN 'Uber' THEN 4 ELSE 0 END AS rank_value,
        COUNT(DISTINCT user_id) AS users,
        COUNT(*) AS reviews,
        COUNT(DISTINCT business_id) AS businesses,
        ROUND(AVG(user_average_stars), 4) AS avg_user_stars,
        ROUND(AVG(review_stars), 4) AS avg_review_stars,
        ROUND(AVG(business_stars), 4) AS avg_business_stars,
        ROUND(100.0 * AVG(CASE WHEN elite_bucket = 'elite_user' THEN 1.0 ELSE 0.0 END), 4) AS elite_review_rate_pct,
        ROUND(100.0 * AVG(CASE WHEN review_length = 'Long' THEN 1.0 ELSE 0.0 END), 4) AS long_review_rate_pct,
        ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 4) AS share_pct,
        'review-source useful-vote label compared with review behavior' AS notes
    FROM review_fact
    GROUP BY COALESCE(user_votes_useful, 'None')
),
block_compliments AS (
    SELECT
        'compliment_type_overlay' AS evidence_block,
        'compliment_type' AS grain,
        c.compliment_type AS item,
        uc.number_of_compliments AS item_2,
        CAST(NULL AS TEXT) AS item_3,
        'compliment_row_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT uc.user_id) DESC, c.compliment_type, uc.number_of_compliments) AS rank_value,
        COUNT(DISTINCT uc.user_id) AS users,
        COUNT(r.user_id) AS reviews,
        COUNT(DISTINCT r.business_id) AS businesses,
        ROUND(AVG(um.user_average_stars), 4) AS avg_user_stars,
        ROUND(AVG(r.review_stars), 4) AS avg_review_stars,
        ROUND(AVG(b.stars), 4) AS avg_business_stars,
        ROUND(100.0 * AVG(CASE WHEN um.elite_bucket = 'elite_user' THEN 1.0 ELSE 0.0 END), 4) AS elite_review_rate_pct,
        ROUND(100.0 * AVG(CASE WHEN r.review_length = 'Long' THEN 1.0 ELSE 0.0 END), 4) AS long_review_rate_pct,
        ROUND(100.0 * COUNT(DISTINCT uc.user_id) / SUM(COUNT(DISTINCT uc.user_id)) OVER (), 4) AS share_pct,
        'compliment recognition types joined back to review behavior' AS notes
    FROM "Users_Compliments" uc
    JOIN "Compliments" c ON uc.compliment_id = c.compliment_id
    JOIN user_metrics um ON uc.user_id = um.user_id
    LEFT JOIN "Reviews" r ON uc.user_id = r.user_id
    LEFT JOIN "Business" b ON r.business_id = b.business_id
    GROUP BY c.compliment_type, uc.number_of_compliments
),
block_category AS (
    SELECT * FROM (
        SELECT
            'category_influence_overlay' AS evidence_block,
            'category' AS grain,
            cat.category_name AS item,
            CAST(NULL AS TEXT) AS item_2,
            CAST(NULL AS TEXT) AS item_3,
            'category_review_rank' AS rank_label,
            ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, cat.category_name) AS rank_value,
            COUNT(DISTINCT rf.user_id) AS users,
            COUNT(*) AS reviews,
            COUNT(DISTINCT rf.business_id) AS businesses,
            ROUND(AVG(rf.user_average_stars), 4) AS avg_user_stars,
            ROUND(AVG(rf.review_stars), 4) AS avg_review_stars,
            ROUND(AVG(rf.business_stars), 4) AS avg_business_stars,
            ROUND(100.0 * AVG(CASE WHEN rf.elite_bucket = 'elite_user' THEN 1.0 ELSE 0.0 END), 4) AS elite_review_rate_pct,
            ROUND(100.0 * AVG(CASE WHEN rf.review_length = 'Long' THEN 1.0 ELSE 0.0 END), 4) AS long_review_rate_pct,
            ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 4) AS share_pct,
            'largest categories viewed through reviewer influence composition' AS notes
        FROM review_fact rf
        JOIN "Business_Categories" bc ON rf.business_id = bc.business_id
        JOIN "Categories" cat ON bc.category_id = cat.category_id
        GROUP BY cat.category_name
    ) x WHERE rank_value <= 20
)
SELECT * FROM block_tenure
UNION ALL SELECT * FROM block_activity
UNION ALL SELECT * FROM block_elite
UNION ALL SELECT * FROM block_fans
UNION ALL SELECT * FROM block_votes
UNION ALL SELECT * FROM block_compliments
UNION ALL SELECT * FROM block_category
