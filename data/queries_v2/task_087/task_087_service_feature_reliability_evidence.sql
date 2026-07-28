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
        COALESCE(r.long_review_rate, 0) AS long_review_rate,
        COALESCE(t.tips, 0) AS tips,
        COALESCE(t.tip_likes, 0) AS tip_likes,
        COALESCE(c.checkin_slots, 0) AS checkin_slots
    FROM "Business" b
    LEFT JOIN (
        SELECT business_id, COUNT(*) AS reviews, AVG(review_stars) AS avg_review_stars, AVG(CASE WHEN review_length = 'Long' THEN 1.0 ELSE 0.0 END) AS long_review_rate
        FROM "Reviews"
        GROUP BY business_id
    ) r ON b.business_id = r.business_id
    LEFT JOIN (
        SELECT business_id, COUNT(*) AS tips, SUM(likes) AS tip_likes
        FROM "Tips"
        GROUP BY business_id
    ) t ON b.business_id = t.business_id
    LEFT JOIN (
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
    ) c ON b.business_id = c.business_id
),
attribute_rows AS (
    SELECT
        bm.*,
        a.attribute_name,
        ba.attribute_value,
        CASE WHEN LOWER(COALESCE(ba.attribute_value, 'none')) IN ('none', 'no', 'false') THEN 'none_no_false_value' ELSE 'positive_or_specific_value' END AS value_group,
        CASE
            WHEN a.attribute_name IN ('Accepts Credit Cards', 'Price Range') THEN 'payment_price'
            WHEN a.attribute_name IN ('Wheelchair Accessible', 'Good for Kids') THEN 'access_family'
            WHEN a.attribute_name IN ('Take-out', 'Delivery', 'Drive-Thru', 'Waiter Service', 'Takes Reservations') THEN 'service_channel'
            WHEN a.attribute_name IN ('Outdoor Seating', 'Good For Groups', 'Noise Level', 'Attire', 'Alcohol') THEN 'experience_setting'
            WHEN a.attribute_name LIKE 'parking_%' THEN 'parking'
            WHEN a.attribute_name IN ('Open 24 Hours') THEN 'availability'
            ELSE 'other_attribute'
        END AS attribute_family
    FROM business_metrics bm
    JOIN "Business_Attributes" ba ON bm.business_id = ba.business_id
    JOIN "Attributes" a ON ba.attribute_id = a.attribute_id
),
category_attribute AS (
    SELECT ar.*, c.category_name
    FROM attribute_rows ar
    JOIN "Business_Categories" bc ON ar.business_id = bc.business_id
    JOIN "Categories" c ON bc.category_id = c.category_id
),
attribute_family_coverage AS (
    SELECT
        'attribute_family_coverage' AS evidence_block,
        'attribute_family' AS grain,
        attribute_family AS item,
        value_group AS item_2,
        '' AS item_3,
        'attribute_family_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT business_id) DESC) AS rank_value,
        COUNT(DISTINCT business_id) AS businesses,
        CAST(NULL AS BIGINT) AS users,
        SUM(reviews) AS reviews,
        SUM(tips) AS tips,
        SUM(checkin_slots) AS checkin_slots,
        ROUND(AVG(stars), 4) AS avg_business_stars,
        ROUND(AVG(avg_review_stars), 4) AS avg_review_stars,
        ROUND(AVG(long_review_rate) * 100, 4) AS long_review_rate_pct,
        ROUND(COUNT(DISTINCT business_id) * 100.0 / NULLIF((SELECT COUNT(*) FROM "Business"), 0), 4) AS share_pct,
        'coverage of attribute families and value groups' AS notes
    FROM attribute_rows
    GROUP BY attribute_family, value_group
),
selected_feature_quality AS (
    SELECT
        'selected_feature_quality' AS evidence_block,
        'selected_feature' AS grain,
        attribute_name AS item,
        attribute_value AS item_2,
        '' AS item_3,
        'selected_feature_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT business_id) DESC) AS rank_value,
        COUNT(DISTINCT business_id) AS businesses,
        CAST(NULL AS BIGINT) AS users,
        SUM(reviews) AS reviews,
        SUM(tips) AS tips,
        SUM(checkin_slots) AS checkin_slots,
        ROUND(AVG(stars), 4) AS avg_business_stars,
        ROUND(AVG(avg_review_stars), 4) AS avg_review_stars,
        ROUND(AVG(long_review_rate) * 100, 4) AS long_review_rate_pct,
        ROUND(COUNT(DISTINCT business_id) * 100.0 / NULLIF((SELECT COUNT(*) FROM "Business"), 0), 4) AS share_pct,
        'specific service features compared with rating and activity' AS notes
    FROM attribute_rows
    WHERE attribute_name IN ('Open 24 Hours', 'Drive-Thru', 'Delivery', 'Take-out', 'Outdoor Seating', 'Good for Kids', 'Alcohol', 'Wheelchair Accessible')
    GROUP BY attribute_name, attribute_value
    QUALIFY ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT business_id) DESC) <= 30
),
value_absence_contrast AS (
    SELECT
        'value_absence_contrast' AS evidence_block,
        'attribute_value_group' AS grain,
        attribute_name AS item,
        value_group AS item_2,
        '' AS item_3,
        'value_group_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT business_id) DESC) AS rank_value,
        COUNT(DISTINCT business_id) AS businesses,
        CAST(NULL AS BIGINT) AS users,
        SUM(reviews) AS reviews,
        SUM(tips) AS tips,
        SUM(checkin_slots) AS checkin_slots,
        ROUND(AVG(stars), 4) AS avg_business_stars,
        ROUND(AVG(avg_review_stars), 4) AS avg_review_stars,
        ROUND(AVG(long_review_rate) * 100, 4) AS long_review_rate_pct,
        ROUND(COUNT(DISTINCT business_id) * 100.0 / NULLIF((SELECT COUNT(*) FROM "Business"), 0), 4) AS share_pct,
        'positive or specific values contrasted with none/no/false values' AS notes
    FROM attribute_rows
    WHERE attribute_name IN ('Accepts Credit Cards', 'Wheelchair Accessible', 'Good for Kids', 'Outdoor Seating', 'Alcohol', 'parking_lot', 'parking_valet', 'parking_validated')
    GROUP BY attribute_name, value_group
),
category_feature_mix AS (
    SELECT
        'category_feature_mix' AS evidence_block,
        'category_attribute_family' AS grain,
        category_name AS item,
        attribute_family AS item_2,
        value_group AS item_3,
        'category_feature_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT business_id) DESC) AS rank_value,
        COUNT(DISTINCT business_id) AS businesses,
        CAST(NULL AS BIGINT) AS users,
        SUM(reviews) AS reviews,
        SUM(tips) AS tips,
        SUM(checkin_slots) AS checkin_slots,
        ROUND(AVG(stars), 4) AS avg_business_stars,
        ROUND(AVG(avg_review_stars), 4) AS avg_review_stars,
        ROUND(AVG(long_review_rate) * 100, 4) AS long_review_rate_pct,
        ROUND(COUNT(DISTINCT business_id) * 100.0 / NULLIF((SELECT COUNT(*) FROM "Business"), 0), 4) AS share_pct,
        'category composition of service-feature families' AS notes
    FROM category_attribute
    GROUP BY category_name, attribute_family, value_group
    QUALIFY ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT business_id) DESC) <= 35
),
city_feature_mix AS (
    SELECT
        'city_feature_mix' AS evidence_block,
        'city_attribute_family' AS grain,
        city AS item,
        attribute_family AS item_2,
        value_group AS item_3,
        'city_feature_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT business_id) DESC) AS rank_value,
        COUNT(DISTINCT business_id) AS businesses,
        CAST(NULL AS BIGINT) AS users,
        SUM(reviews) AS reviews,
        SUM(tips) AS tips,
        SUM(checkin_slots) AS checkin_slots,
        ROUND(AVG(stars), 4) AS avg_business_stars,
        ROUND(AVG(avg_review_stars), 4) AS avg_review_stars,
        ROUND(AVG(long_review_rate) * 100, 4) AS long_review_rate_pct,
        ROUND(COUNT(DISTINCT business_id) * 100.0 / NULLIF((SELECT COUNT(*) FROM "Business"), 0), 4) AS share_pct,
        'city composition of service-feature families' AS notes
    FROM attribute_rows
    GROUP BY city, attribute_family, value_group
    QUALIFY ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT business_id) DESC) <= 30
),
activity_by_feature AS (
    SELECT
        'activity_by_feature' AS evidence_block,
        'feature_activity' AS grain,
        attribute_family AS item,
        value_group AS item_2,
        '' AS item_3,
        'feature_activity_rank' AS rank_label,
        ROW_NUMBER() OVER (ORDER BY SUM(checkin_slots) DESC) AS rank_value,
        COUNT(DISTINCT business_id) AS businesses,
        CAST(NULL AS BIGINT) AS users,
        SUM(reviews) AS reviews,
        SUM(tips) AS tips,
        SUM(checkin_slots) AS checkin_slots,
        ROUND(AVG(stars), 4) AS avg_business_stars,
        ROUND(AVG(avg_review_stars), 4) AS avg_review_stars,
        ROUND(AVG(long_review_rate) * 100, 4) AS long_review_rate_pct,
        ROUND(COUNT(DISTINCT business_id) * 100.0 / NULLIF((SELECT COUNT(*) FROM "Business"), 0), 4) AS share_pct,
        'attribute family compared on review, tip, and check-in activity' AS notes
    FROM attribute_rows
    GROUP BY attribute_family, value_group
)
SELECT * FROM attribute_family_coverage
UNION ALL SELECT * FROM selected_feature_quality
UNION ALL SELECT * FROM value_absence_contrast
UNION ALL SELECT * FROM category_feature_mix
UNION ALL SELECT * FROM city_feature_mix
UNION ALL SELECT * FROM activity_by_feature
