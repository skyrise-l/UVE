-- task_029_blockbuster_long_tail_structure_evidence.sql
-- Draft evidence SQL for task_029.
-- Public query: Is reported sales volume broadly distributed across games, or is it driven by blockbusters, and where does the long tail still matter?
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
game_total AS (
    SELECT
        game_key,
        game_name,
        genre_name,
        COUNT(DISTINCT platform_name) AS platforms,
        COUNT(DISTINCT region_name) FILTER (WHERE reported_sales_volume > 0) AS regions,
        SUM(reported_sales_volume) AS sales
    FROM base_fact
    GROUP BY game_key, game_name, genre_name
),
game_ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY sales DESC, game_name) AS sales_rank,
        COUNT(*) OVER () AS total_games
    FROM game_total
),
game_bucket AS (
    SELECT
        *,
        CASE
            WHEN sales_rank <= GREATEST(1, CEIL(total_games * 0.01)) THEN 'top_1_percent_games'
            WHEN sales_rank <= GREATEST(1, CEIL(total_games * 0.05)) THEN 'top_1_to_5_percent_games'
            WHEN sales_rank <= GREATEST(1, CEIL(total_games * 0.20)) THEN 'top_5_to_20_percent_games'
            ELSE 'bottom_80_percent_games'
        END AS sales_bucket
    FROM game_ranked
),
bucket_summary AS (
    SELECT
        sales_bucket,
        COUNT(*) AS games,
        SUM(platforms) AS platforms_sum,
        SUM(sales) AS sales,
        AVG(sales) AS avg_game_sales,
        AVG(regions) AS avg_regions_per_game
    FROM game_bucket
    GROUP BY sales_bucket
),
genre_game_rank AS (
    SELECT
        genre_name,
        game_key,
        game_name,
        sales,
        ROW_NUMBER() OVER (PARTITION BY genre_name ORDER BY sales DESC, game_name) AS genre_rank,
        COUNT(*) OVER (PARTITION BY genre_name) AS genre_games,
        SUM(sales) OVER (PARTITION BY genre_name) AS genre_sales
    FROM game_total
),
genre_blockbuster_profile AS (
    SELECT
        genre_name,
        COUNT(*) AS games,
        SUM(sales) AS sales,
        SUM(CASE WHEN genre_rank <= GREATEST(1, CEIL(genre_games * 0.10)) THEN sales ELSE 0 END) AS top10pct_sales,
        MAX(CASE WHEN genre_rank = 1 THEN game_name END) AS top_game,
        MAX(CASE WHEN genre_rank = 1 THEN sales END) AS top_game_sales
    FROM genre_game_rank
    GROUP BY genre_name
),
platform_game AS (
    SELECT
        platform_name,
        game_key,
        game_name,
        SUM(reported_sales_volume) AS sales
    FROM base_fact
    GROUP BY platform_name, game_key, game_name
),
platform_game_rank AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY platform_name ORDER BY sales DESC, game_name) AS platform_rank,
        COUNT(*) OVER (PARTITION BY platform_name) AS platform_games,
        SUM(sales) OVER (PARTITION BY platform_name) AS platform_sales
    FROM platform_game
),
platform_blockbuster_profile AS (
    SELECT
        platform_name,
        COUNT(*) AS games,
        SUM(sales) AS sales,
        SUM(CASE WHEN platform_rank <= GREATEST(1, CEIL(platform_games * 0.10)) THEN sales ELSE 0 END) AS top10pct_sales,
        MAX(CASE WHEN platform_rank = 1 THEN game_name END) AS top_game,
        MAX(CASE WHEN platform_rank = 1 THEN sales END) AS top_game_sales
    FROM platform_game_rank
    GROUP BY platform_name
),
game_region AS (
    SELECT
        gb.sales_bucket,
        bf.region_name,
        SUM(bf.reported_sales_volume) AS sales,
        COUNT(DISTINCT bf.game_key) AS games
    FROM base_fact AS bf
    JOIN game_bucket AS gb ON bf.game_key = gb.game_key
    GROUP BY gb.sales_bucket, bf.region_name
),
coverage_by_bucket AS (
    SELECT
        sales_bucket,
        CASE
            WHEN regions >= 4 THEN 'four_region_games'
            WHEN regions = 3 THEN 'three_region_games'
            WHEN regions = 2 THEN 'two_region_games'
            ELSE 'one_region_games'
        END AS region_coverage_bucket,
        COUNT(*) AS games,
        SUM(sales) AS sales
    FROM game_bucket
    GROUP BY sales_bucket, region_coverage_bucket
)
SELECT
    'global_game_sales_bucket_concentration' AS evidence_block,
    'sales_bucket' AS grain,
    sales_bucket AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'game_sales_bucket' AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(games AS BIGINT) AS games,
    CAST(NULL AS BIGINT) AS game_platforms,
    CAST(platforms_sum AS BIGINT) AS platforms,
    CAST(NULL AS BIGINT) AS publishers,
    CAST(NULL AS BIGINT) AS genres,
    CAST(NULL AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(sales / NULLIF((SELECT total_sales FROM total_sales), 0), 4) AS sales_share,
    ROUND(avg_game_sales, 4) AS avg_sales_per_game_platform,
    ROUND(avg_regions_per_game, 4) AS secondary_value,
    'avg_regions_per_game' AS secondary_label,
    'Quantify blockbuster concentration before describing the long tail.' AS notes
FROM bucket_summary
UNION ALL
SELECT
    'genre_blockbuster_dependency' AS evidence_block,
    'genre' AS grain,
    genre_name AS item,
    top_game AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'top10pct_game_share_within_genre' AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(games AS BIGINT) AS games,
    CAST(NULL AS BIGINT) AS game_platforms,
    CAST(NULL AS BIGINT) AS platforms,
    CAST(NULL AS BIGINT) AS publishers,
    CAST(1 AS BIGINT) AS genres,
    CAST(NULL AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(top10pct_sales / NULLIF(sales, 0), 4) AS sales_share,
    CAST(NULL AS DOUBLE) AS avg_sales_per_game_platform,
    ROUND(top_game_sales / NULLIF(sales, 0), 4) AS secondary_value,
    'top_game_share_within_genre' AS secondary_label,
    'Measure whether each genre is hit-driven or has a broader long tail.' AS notes
FROM genre_blockbuster_profile
UNION ALL
SELECT
    'platform_blockbuster_dependency' AS evidence_block,
    'platform' AS grain,
    platform_name AS item,
    top_game AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'top10pct_game_share_within_platform' AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(games AS BIGINT) AS games,
    CAST(NULL AS BIGINT) AS game_platforms,
    CAST(1 AS BIGINT) AS platforms,
    CAST(NULL AS BIGINT) AS publishers,
    CAST(NULL AS BIGINT) AS genres,
    CAST(NULL AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(top10pct_sales / NULLIF(sales, 0), 4) AS sales_share,
    CAST(NULL AS DOUBLE) AS avg_sales_per_game_platform,
    ROUND(top_game_sales / NULLIF(sales, 0), 4) AS secondary_value,
    'top_game_share_within_platform' AS secondary_label,
    'Measure whether platform sales are hit-driven or distributed across a broader catalog.' AS notes
FROM platform_blockbuster_profile
UNION ALL
SELECT
    'regional_sales_by_global_game_bucket' AS evidence_block,
    'region_bucket' AS grain,
    region_name AS item,
    sales_bucket AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'region_global_bucket_mix' AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(games AS BIGINT) AS games,
    CAST(NULL AS BIGINT) AS game_platforms,
    CAST(NULL AS BIGINT) AS platforms,
    CAST(NULL AS BIGINT) AS publishers,
    CAST(NULL AS BIGINT) AS genres,
    CAST(1 AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(sales / NULLIF(SUM(sales) OVER (PARTITION BY region_name), 0), 4) AS sales_share,
    CAST(NULL AS DOUBLE) AS avg_sales_per_game_platform,
    CAST(NULL AS DOUBLE) AS secondary_value,
    'not_applicable' AS secondary_label,
    'Check whether regions rely differently on global blockbusters versus tail games.' AS notes
FROM game_region
UNION ALL
SELECT
    'long_tail_region_coverage' AS evidence_block,
    'sales_bucket_region_coverage' AS grain,
    sales_bucket AS item,
    region_coverage_bucket AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'region_coverage_within_sales_bucket' AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(games AS BIGINT) AS games,
    CAST(NULL AS BIGINT) AS game_platforms,
    CAST(NULL AS BIGINT) AS platforms,
    CAST(NULL AS BIGINT) AS publishers,
    CAST(NULL AS BIGINT) AS genres,
    CAST(NULL AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(sales / NULLIF(SUM(sales) OVER (PARTITION BY sales_bucket), 0), 4) AS sales_share,
    CAST(NULL AS DOUBLE) AS avg_sales_per_game_platform,
    CAST(games AS DOUBLE) AS secondary_value,
    'games' AS secondary_label,
    'Separate a low-sales long tail from cross-region tail coverage.' AS notes
FROM coverage_by_bucket
