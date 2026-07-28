-- task_025_multiplatform_strategy_evidence.sql
-- Evidence SQL for task_025.
-- Public query: Does releasing a game on more platforms actually broaden sales quality, or can multi-platform strategy mainly add complexity without proportional lift?
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
)
,
game_platform_scope AS (
    SELECT
        game_key,
        game_name,
        publisher_name,
        genre_name,
        COUNT(DISTINCT platform_name) AS platform_count,
        COUNT(DISTINCT game_platform_key) AS game_platforms,
        COUNT(DISTINCT region_name) FILTER (WHERE reported_sales_volume > 0) AS regions,
        SUM(reported_sales_volume) AS sales
    FROM base_fact
    GROUP BY game_key, game_name, publisher_name, genre_name
),
game_scope_bucket AS (
    SELECT
        CASE
            WHEN platform_count = 1 THEN 'single_platform_games'
            WHEN platform_count = 2 THEN 'two_platform_games'
            WHEN platform_count BETWEEN 3 AND 4 THEN 'three_to_four_platform_games'
            ELSE 'five_plus_platform_games'
        END AS platform_scope_bucket,
        COUNT(*) AS games,
        SUM(platform_count) AS platforms,
        SUM(game_platforms) AS game_platforms,
        SUM(regions) AS region_appearances,
        SUM(sales) AS sales
    FROM game_platform_scope
    GROUP BY platform_scope_bucket
),
game_ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY sales DESC, game_name) AS sales_rank,
        sales / NULLIF(platform_count, 0) AS sales_per_platform
    FROM game_platform_scope
),
game_region AS (
    SELECT
        game_key,
        game_name,
        region_name,
        SUM(reported_sales_volume) AS region_sales
    FROM base_fact
    GROUP BY game_key, game_name, region_name
),
game_region_balance AS (
    SELECT
        gr.game_key,
        gr.game_name,
        gs.publisher_name,
        gs.genre_name,
        gs.platform_count,
        gs.regions,
        gs.sales,
        gr.region_name AS dominant_region,
        gr.region_sales / NULLIF(gs.sales, 0) AS dominant_region_share,
        ROW_NUMBER() OVER (ORDER BY gs.sales DESC, gs.game_name) AS sales_rank
    FROM game_region AS gr
    JOIN game_platform_scope AS gs
      ON gr.game_key = gs.game_key
    QUALIFY ROW_NUMBER() OVER (PARTITION BY gr.game_key ORDER BY gr.region_sales DESC, gr.region_name) = 1
),
bucket_region_coverage AS (
    SELECT
        CASE
            WHEN platform_count = 1 THEN 'single_platform_games'
            WHEN platform_count = 2 THEN 'two_platform_games'
            WHEN platform_count BETWEEN 3 AND 4 THEN 'three_to_four_platform_games'
            ELSE 'five_plus_platform_games'
        END AS platform_scope_bucket,
        CASE
            WHEN regions >= 4 THEN 'four_region_coverage'
            WHEN regions = 3 THEN 'three_region_coverage'
            WHEN regions = 2 THEN 'two_region_coverage'
            WHEN regions = 1 THEN 'one_region_coverage'
            ELSE 'no_positive_region'
        END AS region_coverage_bucket,
        COUNT(*) AS games,
        SUM(platform_count) AS platforms,
        SUM(game_platforms) AS game_platforms,
        SUM(sales) AS sales
    FROM game_platform_scope
    GROUP BY platform_scope_bucket, region_coverage_bucket
),
publisher_strategy AS (
    SELECT
        publisher_name,
        COUNT(*) AS games,
        SUM(CASE WHEN platform_count > 1 THEN 1 ELSE 0 END) AS multi_platform_games,
        SUM(sales) AS sales,
        SUM(CASE WHEN platform_count > 1 THEN sales ELSE 0 END) AS multi_platform_sales,
        ROW_NUMBER() OVER (ORDER BY SUM(sales) DESC, publisher_name) AS publisher_sales_rank
    FROM game_platform_scope
    GROUP BY publisher_name
)
SELECT
    'platform_scope_summary' AS evidence_block,
    'platform_scope_bucket' AS grain,
    platform_scope_bucket AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'bucket_sales_rank' AS rank_label,
    CAST(ROW_NUMBER() OVER (ORDER BY sales DESC, platform_scope_bucket) AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(games AS BIGINT) AS games,
    CAST(game_platforms AS BIGINT) AS game_platforms,
    CAST(platforms AS BIGINT) AS platforms,
    CAST(NULL AS BIGINT) AS publishers,
    CAST(NULL AS BIGINT) AS genres,
    CAST(region_appearances AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(sales / NULLIF((SELECT total_sales FROM total_sales), 0), 4) AS sales_share,
    ROUND(sales / NULLIF(game_platforms, 0), 4) AS avg_sales_per_game_platform,
    ROUND(sales / NULLIF(games, 0), 4) AS secondary_value,
    'sales_per_game' AS secondary_label,
    'Platform-scope baseline quantifies whether multi-platform games dominate sales or only add catalogue complexity.' AS notes
FROM game_scope_bucket
UNION ALL
SELECT
    'top_game_platform_scope_examples' AS evidence_block,
    'game' AS grain,
    game_name AS item,
    publisher_name AS item_2,
    genre_name AS item_3,
    'game_sales_rank' AS rank_label,
    CAST(sales_rank AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(1 AS BIGINT) AS games,
    CAST(game_platforms AS BIGINT) AS game_platforms,
    CAST(platform_count AS BIGINT) AS platforms,
    CAST(1 AS BIGINT) AS publishers,
    CAST(1 AS BIGINT) AS genres,
    CAST(regions AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(sales / NULLIF((SELECT total_sales FROM total_sales), 0), 4) AS sales_share,
    ROUND(sales_per_platform, 4) AS avg_sales_per_game_platform,
    CAST(platform_count AS DOUBLE) AS secondary_value,
    'platform_count' AS secondary_label,
    'Top games reveal whether the largest hits are single-platform or genuinely multi-platform.' AS notes
FROM game_ranked
WHERE sales_rank <= 25
UNION ALL
SELECT
    'game_region_balance_by_platform_scope' AS evidence_block,
    'game_region_balance' AS grain,
    game_name AS item,
    dominant_region AS item_2,
    CAST(platform_count AS VARCHAR) AS item_3,
    'game_sales_rank' AS rank_label,
    CAST(sales_rank AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(1 AS BIGINT) AS games,
    CAST(NULL AS BIGINT) AS game_platforms,
    CAST(platform_count AS BIGINT) AS platforms,
    CAST(1 AS BIGINT) AS publishers,
    CAST(1 AS BIGINT) AS genres,
    CAST(regions AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(sales / NULLIF((SELECT total_sales FROM total_sales), 0), 4) AS sales_share,
    ROUND(sales / NULLIF(platform_count, 0), 4) AS avg_sales_per_game_platform,
    ROUND(dominant_region_share, 4) AS secondary_value,
    'dominant_region_share' AS secondary_label,
    'More platforms can broaden access, but regional concentration can remain high.' AS notes
FROM game_region_balance
WHERE sales_rank <= 30
UNION ALL
SELECT
    'platform_scope_region_coverage' AS evidence_block,
    'platform_scope_region_coverage' AS grain,
    platform_scope_bucket AS item,
    region_coverage_bucket AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'coverage_sales_rank_within_scope' AS rank_label,
    CAST(ROW_NUMBER() OVER (PARTITION BY platform_scope_bucket ORDER BY sales DESC, region_coverage_bucket) AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(games AS BIGINT) AS games,
    CAST(game_platforms AS BIGINT) AS game_platforms,
    CAST(platforms AS BIGINT) AS platforms,
    CAST(NULL AS BIGINT) AS publishers,
    CAST(NULL AS BIGINT) AS genres,
    CAST(NULL AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(sales / NULLIF(SUM(sales) OVER (PARTITION BY platform_scope_bucket), 0), 4) AS sales_share,
    ROUND(sales / NULLIF(game_platforms, 0), 4) AS avg_sales_per_game_platform,
    CAST(NULL AS DOUBLE) AS secondary_value,
    'not_applicable' AS secondary_label,
    'Coverage rows test whether multi-platform games actually extend regional reach.' AS notes
FROM bucket_region_coverage
UNION ALL
SELECT
    'publisher_multiplatform_exposure' AS evidence_block,
    'publisher_strategy' AS grain,
    publisher_name AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'publisher_sales_rank' AS rank_label,
    CAST(publisher_sales_rank AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(games AS BIGINT) AS games,
    CAST(NULL AS BIGINT) AS game_platforms,
    CAST(NULL AS BIGINT) AS platforms,
    CAST(1 AS BIGINT) AS publishers,
    CAST(NULL AS BIGINT) AS genres,
    CAST(NULL AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(sales / NULLIF((SELECT total_sales FROM total_sales), 0), 4) AS sales_share,
    CAST(NULL AS DOUBLE) AS avg_sales_per_game_platform,
    ROUND(multi_platform_sales / NULLIF(sales, 0), 4) AS secondary_value,
    'multi_platform_sales_share_within_publisher' AS secondary_label,
    'Publisher exposure shows whether multi-platform strategy is concentrated among certain publishers.' AS notes
FROM publisher_strategy
WHERE publisher_sales_rank <= 25;
