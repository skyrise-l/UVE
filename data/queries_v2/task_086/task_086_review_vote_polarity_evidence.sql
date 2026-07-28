WITH review_enriched AS (
    SELECT
        r.business_id,
        r.user_id,
        r.review_stars,
        r.review_length,
        COALESCE(r.review_votes_useful, 'None') AS review_votes_useful,
        COALESCE(r.review_votes_funny, 'None') AS review_votes_funny,
        COALESCE(r.review_votes_cool, 'None') AS review_votes_cool,
        b.active,
        b.city,
        b.state,
        b.stars AS business_stars,
        b.review_count AS business_review_count,
        u.user_review_count,
        CASE
            WHEN b.stars >= 4.5 THEN '4.5_to_5_star_business'
            WHEN b.stars >= 4.0 THEN '4.0_to_4.49_star_business'
            WHEN b.stars >= 3.0 THEN '3.0_to_3.99_star_business'
            ELSE 'below_3_star_business'
        END AS business_star_bucket,
        CASE
            WHEN r.review_stars >= 4 THEN 'positive_review'
            WHEN r.review_stars = 3 THEN 'middle_review'
            ELSE 'negative_review'
        END AS review_polarity,
        CASE
            WHEN COALESCE(r.review_votes_useful, 'None') <> 'None'
             AND COALESCE(r.review_votes_cool, 'None') <> 'None' THEN 'useful_and_cool'
            WHEN COALESCE(r.review_votes_useful, 'None') <> 'None' THEN 'useful_only_or_useful_led'
            WHEN COALESCE(r.review_votes_funny, 'None') <> 'None' THEN 'funny_without_useful'
            WHEN COALESCE(r.review_votes_cool, 'None') <> 'None' THEN 'cool_without_useful'
            ELSE 'no_vote_label'
        END AS vote_profile
    FROM "Reviews" r
    JOIN "Business" b ON r.business_id = b.business_id
    LEFT JOIN "Users" u ON r.user_id = u.user_id
),
category_reviews AS (
    SELECT
        c.category_name,
        re.*
    FROM review_enriched re
    JOIN "Business_Categories" bc ON re.business_id = bc.business_id
    JOIN "Categories" c ON bc.category_id = c.category_id
),
review_star_vote_baseline AS (
    SELECT
        'review_star_vote_baseline' AS evidence_block,
        'review_polarity' AS grain,
        review_polarity AS item,
        '' AS item_2,
        '' AS item_3,
        'review_polarity_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) AS rank_value,
        COUNT(DISTINCT business_id) AS businesses,
        COUNT(DISTINCT user_id) AS users,
        COUNT(*) AS reviews,
        CAST(NULL AS BIGINT) AS tips,
        CAST(NULL AS BIGINT) AS checkin_slots,
        ROUND(AVG(business_stars), 4) AS avg_business_stars,
        ROUND(AVG(review_stars), 4) AS avg_review_stars,
        ROUND(AVG(CASE WHEN review_length = 'Long' THEN 1.0 ELSE 0.0 END) * 100, 4) AS long_review_rate_pct,
        ROUND(AVG(CASE WHEN review_votes_useful <> 'None' THEN 1.0 ELSE 0.0 END) * 100, 4) AS useful_vote_rate_pct,
        ROUND(AVG(CASE WHEN review_votes_funny <> 'None' THEN 1.0 ELSE 0.0 END) * 100, 4) AS funny_vote_rate_pct,
        ROUND(AVG(CASE WHEN review_votes_cool <> 'None' THEN 1.0 ELSE 0.0 END) * 100, 4) AS cool_vote_rate_pct,
        ROUND(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0), 4) AS share_pct,
        'review polarity compared with vote labels and review length' AS notes
    FROM review_enriched
    GROUP BY review_polarity
),
business_star_review_gap AS (
    SELECT
        'business_star_review_gap' AS evidence_block,
        'business_star_review_polarity' AS grain,
        business_star_bucket AS item,
        review_polarity AS item_2,
        '' AS item_3,
        'business_star_review_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) AS rank_value,
        COUNT(DISTINCT business_id) AS businesses,
        COUNT(DISTINCT user_id) AS users,
        COUNT(*) AS reviews,
        CAST(NULL AS BIGINT) AS tips,
        CAST(NULL AS BIGINT) AS checkin_slots,
        ROUND(AVG(business_stars), 4) AS avg_business_stars,
        ROUND(AVG(review_stars), 4) AS avg_review_stars,
        ROUND(AVG(CASE WHEN review_length = 'Long' THEN 1.0 ELSE 0.0 END) * 100, 4) AS long_review_rate_pct,
        ROUND(AVG(CASE WHEN review_votes_useful <> 'None' THEN 1.0 ELSE 0.0 END) * 100, 4) AS useful_vote_rate_pct,
        ROUND(AVG(CASE WHEN review_votes_funny <> 'None' THEN 1.0 ELSE 0.0 END) * 100, 4) AS funny_vote_rate_pct,
        ROUND(AVG(CASE WHEN review_votes_cool <> 'None' THEN 1.0 ELSE 0.0 END) * 100, 4) AS cool_vote_rate_pct,
        ROUND(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0), 4) AS share_pct,
        'business star bucket crossed with individual review polarity' AS notes
    FROM review_enriched
    GROUP BY business_star_bucket, review_polarity
),
category_review_polarity AS (
    SELECT
        'category_review_polarity' AS evidence_block,
        'category_review_polarity' AS grain,
        category_name AS item,
        review_polarity AS item_2,
        '' AS item_3,
        'category_polarity_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) AS rank_value,
        COUNT(DISTINCT business_id) AS businesses,
        COUNT(DISTINCT user_id) AS users,
        COUNT(*) AS reviews,
        CAST(NULL AS BIGINT) AS tips,
        CAST(NULL AS BIGINT) AS checkin_slots,
        ROUND(AVG(business_stars), 4) AS avg_business_stars,
        ROUND(AVG(review_stars), 4) AS avg_review_stars,
        ROUND(AVG(CASE WHEN review_length = 'Long' THEN 1.0 ELSE 0.0 END) * 100, 4) AS long_review_rate_pct,
        ROUND(AVG(CASE WHEN review_votes_useful <> 'None' THEN 1.0 ELSE 0.0 END) * 100, 4) AS useful_vote_rate_pct,
        ROUND(AVG(CASE WHEN review_votes_funny <> 'None' THEN 1.0 ELSE 0.0 END) * 100, 4) AS funny_vote_rate_pct,
        ROUND(AVG(CASE WHEN review_votes_cool <> 'None' THEN 1.0 ELSE 0.0 END) * 100, 4) AS cool_vote_rate_pct,
        ROUND(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0), 4) AS share_pct,
        'largest category and review-polarity cells' AS notes
    FROM category_reviews
    GROUP BY category_name, review_polarity
    QUALIFY ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) <= 30
),
active_status_polarity AS (
    SELECT
        'active_status_polarity' AS evidence_block,
        'active_review_polarity' AS grain,
        active AS item,
        review_polarity AS item_2,
        '' AS item_3,
        'active_polarity_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) AS rank_value,
        COUNT(DISTINCT business_id) AS businesses,
        COUNT(DISTINCT user_id) AS users,
        COUNT(*) AS reviews,
        CAST(NULL AS BIGINT) AS tips,
        CAST(NULL AS BIGINT) AS checkin_slots,
        ROUND(AVG(business_stars), 4) AS avg_business_stars,
        ROUND(AVG(review_stars), 4) AS avg_review_stars,
        ROUND(AVG(CASE WHEN review_length = 'Long' THEN 1.0 ELSE 0.0 END) * 100, 4) AS long_review_rate_pct,
        ROUND(AVG(CASE WHEN review_votes_useful <> 'None' THEN 1.0 ELSE 0.0 END) * 100, 4) AS useful_vote_rate_pct,
        ROUND(AVG(CASE WHEN review_votes_funny <> 'None' THEN 1.0 ELSE 0.0 END) * 100, 4) AS funny_vote_rate_pct,
        ROUND(AVG(CASE WHEN review_votes_cool <> 'None' THEN 1.0 ELSE 0.0 END) * 100, 4) AS cool_vote_rate_pct,
        ROUND(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0), 4) AS share_pct,
        'active status crossed with review polarity and vote signals' AS notes
    FROM review_enriched
    GROUP BY active, review_polarity
),
user_activity_polarity AS (
    SELECT
        'user_activity_polarity' AS evidence_block,
        'reviewer_activity_polarity' AS grain,
        COALESCE(user_review_count, 'unknown') AS item,
        review_polarity AS item_2,
        '' AS item_3,
        'user_activity_polarity_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) AS rank_value,
        COUNT(DISTINCT business_id) AS businesses,
        COUNT(DISTINCT user_id) AS users,
        COUNT(*) AS reviews,
        CAST(NULL AS BIGINT) AS tips,
        CAST(NULL AS BIGINT) AS checkin_slots,
        ROUND(AVG(business_stars), 4) AS avg_business_stars,
        ROUND(AVG(review_stars), 4) AS avg_review_stars,
        ROUND(AVG(CASE WHEN review_length = 'Long' THEN 1.0 ELSE 0.0 END) * 100, 4) AS long_review_rate_pct,
        ROUND(AVG(CASE WHEN review_votes_useful <> 'None' THEN 1.0 ELSE 0.0 END) * 100, 4) AS useful_vote_rate_pct,
        ROUND(AVG(CASE WHEN review_votes_funny <> 'None' THEN 1.0 ELSE 0.0 END) * 100, 4) AS funny_vote_rate_pct,
        ROUND(AVG(CASE WHEN review_votes_cool <> 'None' THEN 1.0 ELSE 0.0 END) * 100, 4) AS cool_vote_rate_pct,
        ROUND(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0), 4) AS share_pct,
        'reviewer activity label crossed with review polarity' AS notes
    FROM review_enriched
    GROUP BY COALESCE(user_review_count, 'unknown'), review_polarity
),
vote_type_alignment AS (
    SELECT
        'vote_type_alignment' AS evidence_block,
        'vote_profile_review_polarity' AS grain,
        vote_profile AS item,
        review_polarity AS item_2,
        '' AS item_3,
        'vote_profile_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) AS rank_value,
        COUNT(DISTINCT business_id) AS businesses,
        COUNT(DISTINCT user_id) AS users,
        COUNT(*) AS reviews,
        CAST(NULL AS BIGINT) AS tips,
        CAST(NULL AS BIGINT) AS checkin_slots,
        ROUND(AVG(business_stars), 4) AS avg_business_stars,
        ROUND(AVG(review_stars), 4) AS avg_review_stars,
        ROUND(AVG(CASE WHEN review_length = 'Long' THEN 1.0 ELSE 0.0 END) * 100, 4) AS long_review_rate_pct,
        ROUND(AVG(CASE WHEN review_votes_useful <> 'None' THEN 1.0 ELSE 0.0 END) * 100, 4) AS useful_vote_rate_pct,
        ROUND(AVG(CASE WHEN review_votes_funny <> 'None' THEN 1.0 ELSE 0.0 END) * 100, 4) AS funny_vote_rate_pct,
        ROUND(AVG(CASE WHEN review_votes_cool <> 'None' THEN 1.0 ELSE 0.0 END) * 100, 4) AS cool_vote_rate_pct,
        ROUND(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0), 4) AS share_pct,
        'which vote profiles align with positive, middle, or negative reviews' AS notes
    FROM review_enriched
    GROUP BY vote_profile, review_polarity
)
SELECT * FROM review_star_vote_baseline
UNION ALL SELECT * FROM business_star_review_gap
UNION ALL SELECT * FROM category_review_polarity
UNION ALL SELECT * FROM active_status_polarity
UNION ALL SELECT * FROM user_activity_polarity
UNION ALL SELECT * FROM vote_type_alignment
