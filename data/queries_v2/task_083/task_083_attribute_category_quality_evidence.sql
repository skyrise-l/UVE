WITH business_base AS (
    SELECT business_id, active, city, state, stars, review_count FROM "Business"
),
review_by_business AS (
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
    SELECT business_id, COUNT(*) AS tips, SUM(likes) AS tip_likes, AVG(CASE WHEN tip_length = 'Long' THEN 1.0 ELSE 0.0 END) AS long_tip_rate
    FROM "Tips"
    GROUP BY business_id
),
business_metrics AS (
    SELECT
        bb.*,
        COALESCE(rb.reviews, 0) AS reviews,
        rb.avg_review_stars,
        COALESCE(rb.long_review_rate, 0) AS long_review_rate,
        COALESCE(rb.useful_vote_rate, 0) AS useful_vote_rate,
        COALESCE(tb.tips, 0) AS tips,
        COALESCE(tb.tip_likes, 0) AS tip_likes,
        COALESCE(tb.long_tip_rate, 0) AS long_tip_rate
    FROM business_base bb
    LEFT JOIN review_by_business rb ON bb.business_id = rb.business_id
    LEFT JOIN tip_by_business tb ON bb.business_id = tb.business_id
),
attribute_flags AS (
    SELECT
        ba.business_id,
        a.attribute_name,
        ba.attribute_value,
        CASE WHEN LOWER(COALESCE(ba.attribute_value, 'none')) IN ('none', 'no', 'false') THEN 0 ELSE 1 END AS positive_attribute
    FROM "Business_Attributes" ba
    JOIN "Attributes" a ON ba.attribute_id = a.attribute_id
),
metric_total AS (SELECT COUNT(*) AS total_businesses FROM business_metrics),
block_category AS (
    SELECT * FROM (
        SELECT
            'category_baseline' AS evidence_block,
            'category' AS grain,
            c.category_name AS item,
            CAST(NULL AS TEXT) AS item_2,
            CAST(NULL AS TEXT) AS item_3,
            'category_business_rank' AS rank_label,
            ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT bm.business_id) DESC, c.category_name) AS rank_value,
            COUNT(DISTINCT bm.business_id) AS businesses,
            SUM(bm.reviews) AS reviews,
            SUM(bm.tips) AS tips,
            ROUND(AVG(bm.stars), 4) AS avg_business_stars,
            ROUND(AVG(bm.avg_review_stars), 4) AS avg_review_stars,
            ROUND(100.0 * AVG(CASE WHEN bm.active = 'true' THEN 1.0 ELSE 0.0 END), 4) AS active_rate_pct,
            ROUND(100.0 * AVG(bm.long_review_rate), 4) AS long_review_rate_pct,
            ROUND(100.0 * COUNT(DISTINCT bm.business_id) / MAX(mt.total_businesses), 4) AS share_pct,
            'category size and rating context before reading attributes' AS notes
        FROM business_metrics bm
        JOIN "Business_Categories" bc ON bm.business_id = bc.business_id
        JOIN "Categories" c ON bc.category_id = c.category_id
        CROSS JOIN metric_total mt
        GROUP BY c.category_name
    ) x WHERE rank_value <= 20
),
block_attribute_coverage AS (
    SELECT * FROM (
        SELECT
            'attribute_coverage' AS evidence_block,
            'attribute' AS grain,
            af.attribute_name AS item,
            CAST(NULL AS TEXT) AS item_2,
            CAST(NULL AS TEXT) AS item_3,
            'attribute_business_rank' AS rank_label,
            ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT af.business_id) DESC, af.attribute_name) AS rank_value,
            COUNT(DISTINCT af.business_id) AS businesses,
            SUM(bm.reviews) AS reviews,
            SUM(bm.tips) AS tips,
            ROUND(AVG(bm.stars), 4) AS avg_business_stars,
            ROUND(AVG(bm.avg_review_stars), 4) AS avg_review_stars,
            ROUND(100.0 * AVG(CASE WHEN bm.active = 'true' THEN 1.0 ELSE 0.0 END), 4) AS active_rate_pct,
            ROUND(100.0 * AVG(bm.long_review_rate), 4) AS long_review_rate_pct,
            ROUND(100.0 * COUNT(DISTINCT af.business_id) / MAX(mt.total_businesses), 4) AS share_pct,
            'most common listed business attributes regardless of value' AS notes
        FROM attribute_flags af
        JOIN business_metrics bm ON af.business_id = bm.business_id
        CROSS JOIN metric_total mt
        GROUP BY af.attribute_name
    ) x WHERE rank_value <= 25
),
block_attribute_value AS (
    SELECT * FROM (
        SELECT
            'attribute_value_quality' AS evidence_block,
            'attribute_value' AS grain,
            af.attribute_name AS item,
            af.attribute_value AS item_2,
            CAST(NULL AS TEXT) AS item_3,
            'attribute_value_rank' AS rank_label,
            ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT af.business_id) DESC, af.attribute_name, af.attribute_value) AS rank_value,
            COUNT(DISTINCT af.business_id) AS businesses,
            SUM(bm.reviews) AS reviews,
            SUM(bm.tips) AS tips,
            ROUND(AVG(bm.stars), 4) AS avg_business_stars,
            ROUND(AVG(bm.avg_review_stars), 4) AS avg_review_stars,
            ROUND(100.0 * AVG(CASE WHEN bm.active = 'true' THEN 1.0 ELSE 0.0 END), 4) AS active_rate_pct,
            ROUND(100.0 * AVG(bm.long_review_rate), 4) AS long_review_rate_pct,
            ROUND(100.0 * COUNT(DISTINCT af.business_id) / MAX(mt.total_businesses), 4) AS share_pct,
            'attribute values compared on rating and review voice' AS notes
        FROM attribute_flags af
        JOIN business_metrics bm ON af.business_id = bm.business_id
        CROSS JOIN metric_total mt
        WHERE af.positive_attribute = 1
        GROUP BY af.attribute_name, af.attribute_value
    ) x WHERE rank_value <= 25
),
block_category_attribute AS (
    SELECT * FROM (
        SELECT
            'category_attribute_interaction' AS evidence_block,
            'category_attribute' AS grain,
            c.category_name AS item,
            af.attribute_name AS item_2,
            CAST(NULL AS TEXT) AS item_3,
            'category_attribute_rank' AS rank_label,
            ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT bm.business_id) DESC, c.category_name, af.attribute_name) AS rank_value,
            COUNT(DISTINCT bm.business_id) AS businesses,
            SUM(bm.reviews) AS reviews,
            SUM(bm.tips) AS tips,
            ROUND(AVG(bm.stars), 4) AS avg_business_stars,
            ROUND(AVG(bm.avg_review_stars), 4) AS avg_review_stars,
            ROUND(100.0 * AVG(CASE WHEN bm.active = 'true' THEN 1.0 ELSE 0.0 END), 4) AS active_rate_pct,
            ROUND(100.0 * AVG(bm.long_review_rate), 4) AS long_review_rate_pct,
            ROUND(100.0 * COUNT(DISTINCT bm.business_id) / MAX(mt.total_businesses), 4) AS share_pct,
            'large category-attribute overlaps to avoid treating attributes as universal' AS notes
        FROM business_metrics bm
        JOIN "Business_Categories" bc ON bm.business_id = bc.business_id
        JOIN "Categories" c ON bc.category_id = c.category_id
        JOIN attribute_flags af ON bm.business_id = af.business_id AND af.positive_attribute = 1
        CROSS JOIN metric_total mt
        GROUP BY c.category_name, af.attribute_name
    ) x WHERE rank_value <= 30
),
block_review_voice AS (
    SELECT * FROM (
        SELECT
            'attribute_review_voice' AS evidence_block,
            'attribute' AS grain,
            af.attribute_name AS item,
            CASE WHEN af.positive_attribute = 1 THEN 'positive_or_specific_value' ELSE 'none_no_false_value' END AS item_2,
            CAST(NULL AS TEXT) AS item_3,
            'attribute_voice_rank' AS rank_label,
            ROW_NUMBER() OVER (
                ORDER BY
                    COUNT(DISTINCT bm.business_id) DESC,
                    af.attribute_name,
                    CASE
                        WHEN af.positive_attribute = 1 THEN 'positive_or_specific_value'
                        ELSE 'none_no_false_value'
                    END
            ) AS rank_value,
            COUNT(DISTINCT bm.business_id) AS businesses,
            SUM(bm.reviews) AS reviews,
            SUM(bm.tips) AS tips,
            ROUND(AVG(bm.stars), 4) AS avg_business_stars,
            ROUND(AVG(bm.avg_review_stars), 4) AS avg_review_stars,
            ROUND(100.0 * AVG(CASE WHEN bm.active = 'true' THEN 1.0 ELSE 0.0 END), 4) AS active_rate_pct,
            ROUND(100.0 * AVG(bm.long_review_rate), 4) AS long_review_rate_pct,
            ROUND(100.0 * COUNT(DISTINCT bm.business_id) / MAX(mt.total_businesses), 4) AS share_pct,
            'review length and star evidence by attribute presence value' AS notes
        FROM attribute_flags af
        JOIN business_metrics bm ON af.business_id = bm.business_id
        CROSS JOIN metric_total mt
        GROUP BY
            af.attribute_name,
            CASE
                WHEN af.positive_attribute = 1 THEN 'positive_or_specific_value'
                ELSE 'none_no_false_value'
            END
    ) x WHERE rank_value <= 30
),
block_active_mix AS (
    SELECT
        'active_attribute_mix' AS evidence_block,
        'active_attribute_presence' AS grain,
        bm.active AS item,
        CASE WHEN af.positive_attribute = 1 THEN 'positive_or_specific_value' ELSE 'none_no_false_value' END AS item_2,
        CAST(NULL AS TEXT) AS item_3,
        'active_attribute_rank' AS rank_label,
        ROW_NUMBER() OVER (
            ORDER BY
                bm.active DESC,
                CASE
                    WHEN af.positive_attribute = 1 THEN 'positive_or_specific_value'
                    ELSE 'none_no_false_value'
                END
        ) AS rank_value,
        COUNT(DISTINCT bm.business_id) AS businesses,
        SUM(bm.reviews) AS reviews,
        SUM(bm.tips) AS tips,
        ROUND(AVG(bm.stars), 4) AS avg_business_stars,
        ROUND(AVG(bm.avg_review_stars), 4) AS avg_review_stars,
        ROUND(100.0 * AVG(CASE WHEN bm.active = 'true' THEN 1.0 ELSE 0.0 END), 4) AS active_rate_pct,
        ROUND(100.0 * AVG(bm.long_review_rate), 4) AS long_review_rate_pct,
        ROUND(100.0 * COUNT(DISTINCT bm.business_id) / MAX(mt.total_businesses), 4) AS share_pct,
        'whether attribute value coverage differs between active and inactive businesses' AS notes
    FROM business_metrics bm
    JOIN attribute_flags af ON bm.business_id = af.business_id
    CROSS JOIN metric_total mt
    GROUP BY
        bm.active,
        CASE
            WHEN af.positive_attribute = 1 THEN 'positive_or_specific_value'
            ELSE 'none_no_false_value'
        END
)
SELECT * FROM block_category
UNION ALL SELECT * FROM block_attribute_coverage
UNION ALL SELECT * FROM block_attribute_value
UNION ALL SELECT * FROM block_category_attribute
UNION ALL SELECT * FROM block_review_voice
UNION ALL SELECT * FROM block_active_mix
