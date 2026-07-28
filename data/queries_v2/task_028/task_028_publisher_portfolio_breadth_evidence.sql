-- task_028_publisher_portfolio_breadth_evidence.sql
-- Draft evidence SQL for task_028.
-- Public query: Which publishers have broad, balanced portfolios across regions, genres, and platforms, and which are narrowly specialized?
-- Note: reported_sales_volume uses region_sales.num_sales; one unit equals 100,000 reported copies.

WITH
base_fact AS (
    SELECT
        rs.region_id,
        COALESCE(r.region_name, 'Unknown') AS region_name,
        rs.game_platform_id,
        COALESCE(CAST(gp.id AS VARCHAR), 'unknown_game_platform_' || CAST(rs.game_platform_id AS VARCHAR)) AS game_platform_key,
        gp.release_year,
        gp.platform_id,
        COALESCE(p.platform_name, 'Unknown') AS platform_name,
        COALESCE(CAST(gpub.game_id AS VARCHAR), 'unknown_game_' || CAST(rs.game_platform_id AS VARCHAR)) AS game_key,
        COALESCE(g.game_name, 'Unknown Game') AS game_name,
        g.genre_id,
        COALESCE(ge.genre_name, 'Unknown Genre') AS genre_name,
        gpub.publisher_id,
        COALESCE(pub.publisher_name, 'Unknown Publisher') AS publisher_name,
        CAST(rs.num_sales AS DOUBLE) AS reported_sales_volume
    FROM region_sales AS rs
    LEFT JOIN region AS r
      ON rs.region_id = r.id
    LEFT JOIN game_platform AS gp
      ON rs.game_platform_id = gp.id
    LEFT JOIN platform AS p
      ON gp.platform_id = p.id
    LEFT JOIN game_publisher AS gpub
      ON gp.game_publisher_id = gpub.id
    LEFT JOIN publisher AS pub
      ON gpub.publisher_id = pub.id
    LEFT JOIN game AS g
      ON gpub.game_id = g.id
    LEFT JOIN genre AS ge
      ON g.genre_id = ge.id
),
total_sales AS (
    SELECT SUM(reported_sales_volume) AS total_sales
    FROM base_fact
),
publisher_total AS (
    SELECT
        publisher_name,
        COUNT(DISTINCT game_key) AS games,
        COUNT(DISTINCT game_platform_key) AS game_platforms,
        COUNT(DISTINCT genre_name) AS genres,
        COUNT(DISTINCT platform_name) AS platforms,
        COUNT(DISTINCT region_name) FILTER (WHERE reported_sales_volume > 0) AS regions,
        SUM(reported_sales_volume) AS sales
    FROM base_fact
    GROUP BY publisher_name
),
publisher_region AS (
    SELECT publisher_name, region_name, SUM(reported_sales_volume) AS sales
    FROM base_fact
    GROUP BY publisher_name, region_name
),
publisher_region_leader AS (
    SELECT
        pr.publisher_name,
        pr.region_name,
        pr.sales,
        pt.sales AS publisher_sales,
        pr.sales / NULLIF(pt.sales, 0) AS dominant_region_share
    FROM publisher_region AS pr
    JOIN publisher_total AS pt ON pr.publisher_name = pt.publisher_name
    QUALIFY ROW_NUMBER() OVER (PARTITION BY pr.publisher_name ORDER BY pr.sales DESC, pr.region_name) = 1
),
publisher_genre AS (
    SELECT publisher_name, genre_name, SUM(reported_sales_volume) AS sales
    FROM base_fact
    GROUP BY publisher_name, genre_name
),
publisher_genre_leader AS (
    SELECT
        pg.publisher_name,
        pg.genre_name,
        pg.sales,
        pt.sales AS publisher_sales,
        pg.sales / NULLIF(pt.sales, 0) AS dominant_genre_share
    FROM publisher_genre AS pg
    JOIN publisher_total AS pt ON pg.publisher_name = pt.publisher_name
    QUALIFY ROW_NUMBER() OVER (PARTITION BY pg.publisher_name ORDER BY pg.sales DESC, pg.genre_name) = 1
),
publisher_platform AS (
    SELECT publisher_name, platform_name, SUM(reported_sales_volume) AS sales
    FROM base_fact
    GROUP BY publisher_name, platform_name
),
publisher_platform_leader AS (
    SELECT
        pp.publisher_name,
        pp.platform_name,
        pp.sales,
        pt.sales AS publisher_sales,
        pp.sales / NULLIF(pt.sales, 0) AS dominant_platform_share
    FROM publisher_platform AS pp
    JOIN publisher_total AS pt ON pp.publisher_name = pt.publisher_name
    QUALIFY ROW_NUMBER() OVER (PARTITION BY pp.publisher_name ORDER BY pp.sales DESC, pp.platform_name) = 1
),
publisher_profile AS (
    SELECT
        pt.*,
        pr.region_name AS dominant_region,
        pr.dominant_region_share,
        pg.genre_name AS dominant_genre,
        pg.dominant_genre_share,
        pp.platform_name AS dominant_platform,
        pp.dominant_platform_share,
        ROW_NUMBER() OVER (ORDER BY pt.sales DESC, pt.publisher_name) AS sales_rank
    FROM publisher_total AS pt
    LEFT JOIN publisher_region_leader AS pr ON pt.publisher_name = pr.publisher_name
    LEFT JOIN publisher_genre_leader AS pg ON pt.publisher_name = pg.publisher_name
    LEFT JOIN publisher_platform_leader AS pp ON pt.publisher_name = pp.publisher_name
),
breadth_bucket AS (
    SELECT
        CASE
            WHEN regions >= 4 AND genres >= 6 AND platforms >= 8 THEN 'broad_region_genre_platform'
            WHEN regions >= 4 AND (genres >= 4 OR platforms >= 5) THEN 'moderately_broad'
            WHEN games <= 2 OR genres <= 2 OR platforms <= 2 THEN 'narrow_or_small_portfolio'
            ELSE 'middle_portfolio'
        END AS breadth_bucket,
        COUNT(*) AS publishers,
        SUM(games) AS games,
        SUM(game_platforms) AS game_platforms,
        SUM(sales) AS sales
    FROM publisher_total
    GROUP BY breadth_bucket
),
region_publisher_leaders AS (
    SELECT
        region_name,
        publisher_name,
        SUM(reported_sales_volume) AS sales,
        SUM(reported_sales_volume) / NULLIF(SUM(SUM(reported_sales_volume)) OVER (PARTITION BY region_name), 0) AS share_within_region,
        ROW_NUMBER() OVER (PARTITION BY region_name ORDER BY SUM(reported_sales_volume) DESC, publisher_name) AS region_rank
    FROM base_fact
    GROUP BY region_name, publisher_name
)
SELECT
    'publisher_breadth_profile' AS evidence_block,
    'publisher' AS grain,
    publisher_name AS item,
    dominant_region AS item_2,
    dominant_genre AS item_3,
    'publisher_sales_rank' AS rank_label,
    CAST(sales_rank AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(games AS BIGINT) AS games,
    CAST(game_platforms AS BIGINT) AS game_platforms,
    CAST(platforms AS BIGINT) AS platforms,
    CAST(1 AS BIGINT) AS publishers,
    CAST(genres AS BIGINT) AS genres,
    CAST(regions AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(sales / NULLIF((SELECT total_sales FROM total_sales), 0), 4) AS sales_share,
    ROUND(sales / NULLIF(game_platforms, 0), 4) AS avg_sales_per_game_platform,
    ROUND(dominant_region_share, 4) AS secondary_value,
    'dominant_region_share' AS secondary_label,
    'Compare publisher scale with portfolio breadth and regional dependence.' AS notes
FROM publisher_profile
WHERE sales_rank <= 30
UNION ALL
SELECT
    'publisher_genre_specialization' AS evidence_block,
    'publisher' AS grain,
    publisher_name AS item,
    dominant_genre AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'dominant_genre_share' AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(games AS BIGINT) AS games,
    CAST(game_platforms AS BIGINT) AS game_platforms,
    CAST(platforms AS BIGINT) AS platforms,
    CAST(1 AS BIGINT) AS publishers,
    CAST(genres AS BIGINT) AS genres,
    CAST(regions AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(dominant_genre_share, 4) AS sales_share,
    CAST(NULL AS DOUBLE) AS avg_sales_per_game_platform,
    ROUND(dominant_platform_share, 4) AS secondary_value,
    'dominant_platform_share' AS secondary_label,
    'Check whether broad publishers are still concentrated in one genre or one platform.' AS notes
FROM publisher_profile
WHERE sales_rank <= 30
UNION ALL
SELECT
    'publisher_breadth_buckets' AS evidence_block,
    'breadth_bucket' AS grain,
    breadth_bucket AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'portfolio_breadth_bucket' AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(games AS BIGINT) AS games,
    CAST(game_platforms AS BIGINT) AS game_platforms,
    CAST(NULL AS BIGINT) AS platforms,
    CAST(publishers AS BIGINT) AS publishers,
    CAST(NULL AS BIGINT) AS genres,
    CAST(NULL AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(sales / NULLIF((SELECT total_sales FROM total_sales), 0), 4) AS sales_share,
    CAST(NULL AS DOUBLE) AS avg_sales_per_game_platform,
    CAST(publishers AS DOUBLE) AS secondary_value,
    'publishers' AS secondary_label,
    'Summarize how much sales volume sits in broad versus narrow publisher portfolios.' AS notes
FROM breadth_bucket
UNION ALL
SELECT
    'regional_publisher_leaders' AS evidence_block,
    'region_publisher' AS grain,
    region_name AS item,
    publisher_name AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'rank_within_region' AS rank_label,
    CAST(region_rank AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(NULL AS BIGINT) AS games,
    CAST(NULL AS BIGINT) AS game_platforms,
    CAST(NULL AS BIGINT) AS platforms,
    CAST(1 AS BIGINT) AS publishers,
    CAST(NULL AS BIGINT) AS genres,
    CAST(1 AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(share_within_region, 4) AS sales_share,
    CAST(NULL AS DOUBLE) AS avg_sales_per_game_platform,
    CAST(NULL AS DOUBLE) AS secondary_value,
    'not_applicable' AS secondary_label,
    'Show whether publisher leadership changes across regions.' AS notes
FROM region_publisher_leaders
WHERE region_rank <= 3
UNION ALL
SELECT
    'balanced_large_publishers' AS evidence_block,
    'publisher' AS grain,
    publisher_name AS item,
    dominant_region AS item_2,
    dominant_genre AS item_3,
    'publisher_sales_rank' AS rank_label,
    CAST(sales_rank AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(games AS BIGINT) AS games,
    CAST(game_platforms AS BIGINT) AS game_platforms,
    CAST(platforms AS BIGINT) AS platforms,
    CAST(1 AS BIGINT) AS publishers,
    CAST(genres AS BIGINT) AS genres,
    CAST(regions AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(dominant_region_share, 4) AS sales_share,
    ROUND(dominant_genre_share, 4) AS avg_sales_per_game_platform,
    ROUND(dominant_platform_share, 4) AS secondary_value,
    'dominant_platform_share' AS secondary_label,
    'Provide top publisher candidates with region, genre, and platform dependence metrics for balance screening.' AS notes
FROM publisher_profile
WHERE sales_rank <= 50
