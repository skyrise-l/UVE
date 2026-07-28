-- task_021_global_regional_balance_evidence.sql
-- Evidence SQL for task_021.
-- Public query: Which games and platforms look globally strong but have uneven regional demand, and where is the market balance different?
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
region_baseline AS (
    SELECT
        region_name,
        COUNT(DISTINCT game_key) AS games,
        COUNT(DISTINCT game_platform_key) AS game_platforms,
        COUNT(DISTINCT platform_name) AS platforms,
        SUM(reported_sales_volume) AS sales
    FROM base_fact
    GROUP BY region_name
),
game_total AS (
    SELECT
        game_key,
        game_name,
        COUNT(DISTINCT game_platform_key) AS game_platforms,
        COUNT(DISTINCT platform_name) AS platforms,
        COUNT(DISTINCT region_name) FILTER (WHERE reported_sales_volume > 0) AS regions,
        SUM(reported_sales_volume) AS sales
    FROM base_fact
    GROUP BY game_key, game_name
),
game_ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY sales DESC, game_name) AS sales_rank
    FROM game_total
),
top_game_concentration AS (
    SELECT
        COUNT(*) AS games,
        SUM(CASE WHEN sales_rank <= 10 THEN sales ELSE 0 END) AS top10_sales,
        MAX(CASE WHEN sales_rank = 1 THEN game_name END) AS top_game_name,
        MAX(CASE WHEN sales_rank = 1 THEN sales END) AS top_game_sales,
        SUM(sales) AS all_game_sales
    FROM game_ranked
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
game_balance AS (
    SELECT
        gr.game_key,
        gr.game_name,
        gt.sales,
        gt.game_platforms,
        gt.platforms,
        gt.regions,
        gr.region_name AS dominant_region,
        gr.region_sales AS dominant_region_sales,
        gr.region_sales / NULLIF(gt.sales, 0) AS dominant_region_share,
        ROW_NUMBER() OVER (ORDER BY gt.sales DESC, gr.game_name) AS sales_rank
    FROM game_region AS gr
    JOIN game_total AS gt
      ON gr.game_key = gt.game_key
    QUALIFY ROW_NUMBER() OVER (PARTITION BY gr.game_key ORDER BY gr.region_sales DESC, gr.region_name) = 1
),
platform_total AS (
    SELECT
        platform_name,
        COUNT(DISTINCT game_key) AS games,
        COUNT(DISTINCT game_platform_key) AS game_platforms,
        COUNT(DISTINCT region_name) FILTER (WHERE reported_sales_volume > 0) AS regions,
        SUM(reported_sales_volume) AS sales
    FROM base_fact
    GROUP BY platform_name
),
platform_region AS (
    SELECT
        platform_name,
        region_name,
        SUM(reported_sales_volume) AS region_sales
    FROM base_fact
    GROUP BY platform_name, region_name
),
platform_balance AS (
    SELECT
        pr.platform_name,
        pt.sales,
        pt.games,
        pt.game_platforms,
        pt.regions,
        pr.region_name AS dominant_region,
        pr.region_sales / NULLIF(pt.sales, 0) AS dominant_region_share,
        ROW_NUMBER() OVER (ORDER BY pt.sales DESC, pr.platform_name) AS sales_rank
    FROM platform_region AS pr
    JOIN platform_total AS pt
      ON pr.platform_name = pt.platform_name
    QUALIFY ROW_NUMBER() OVER (PARTITION BY pr.platform_name ORDER BY pr.region_sales DESC, pr.region_name) = 1
),
coverage AS (
    SELECT
        CASE
            WHEN regions >= 4 THEN 'four_region_games'
            WHEN regions = 3 THEN 'three_region_games'
            WHEN regions = 2 THEN 'two_region_games'
            WHEN regions = 1 THEN 'one_region_games'
            ELSE 'no_positive_region'
        END AS coverage_bucket,
        COUNT(*) AS games,
        SUM(game_platforms) AS game_platforms,
        SUM(sales) AS sales
    FROM game_total
    GROUP BY coverage_bucket
)
SELECT
    'region_market_baseline' AS evidence_block,
    'region' AS grain,
    region_name AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'region_sales_rank' AS rank_label,
    CAST(ROW_NUMBER() OVER (ORDER BY sales DESC, region_name) AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(games AS BIGINT) AS games,
    CAST(game_platforms AS BIGINT) AS game_platforms,
    CAST(platforms AS BIGINT) AS platforms,
    CAST(NULL AS BIGINT) AS publishers,
    CAST(NULL AS BIGINT) AS genres,
    CAST(1 AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(sales / NULLIF((SELECT total_sales FROM total_sales), 0), 4) AS sales_share,
    ROUND(sales / NULLIF(game_platforms, 0), 4) AS avg_sales_per_game_platform,
    CAST(NULL AS DOUBLE) AS secondary_value,
    'not_applicable' AS secondary_label,
    'Quantify regional market baseline before interpreting global hits as broadly balanced.' AS notes
FROM region_baseline
UNION ALL
SELECT
    'game_sales_concentration' AS evidence_block,
    'all_games' AS grain,
    'top_10_games' AS item,
    top_game_name AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'top10_sales_share' AS rank_label,
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
    ROUND(top10_sales, 4) AS reported_sales_volume,
    ROUND(top10_sales / NULLIF(all_game_sales, 0), 4) AS sales_share,
    CAST(NULL AS DOUBLE) AS avg_sales_per_game_platform,
    ROUND(top_game_sales / NULLIF(all_game_sales, 0), 4) AS secondary_value,
    'top_game_sales_share' AS secondary_label,
    'Use concentration to separate a few global hits from the long tail.' AS notes
FROM top_game_concentration
UNION ALL
SELECT
    'top_game_regional_balance' AS evidence_block,
    'game' AS grain,
    game_name AS item,
    dominant_region AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'game_sales_rank' AS rank_label,
    CAST(sales_rank AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(1 AS BIGINT) AS games,
    CAST(game_platforms AS BIGINT) AS game_platforms,
    CAST(platforms AS BIGINT) AS platforms,
    CAST(NULL AS BIGINT) AS publishers,
    CAST(NULL AS BIGINT) AS genres,
    CAST(regions AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(sales / NULLIF((SELECT total_sales FROM total_sales), 0), 4) AS sales_share,
    ROUND(sales / NULLIF(game_platforms, 0), 4) AS avg_sales_per_game_platform,
    ROUND(dominant_region_share, 4) AS secondary_value,
    'dominant_region_share' AS secondary_label,
    'Top games should be checked for regional balance rather than assumed to be evenly global.' AS notes
FROM game_balance
WHERE sales_rank <= 20
UNION ALL
SELECT
    'platform_regional_balance' AS evidence_block,
    'platform' AS grain,
    platform_name AS item,
    dominant_region AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'platform_sales_rank' AS rank_label,
    CAST(sales_rank AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(games AS BIGINT) AS games,
    CAST(game_platforms AS BIGINT) AS game_platforms,
    CAST(1 AS BIGINT) AS platforms,
    CAST(NULL AS BIGINT) AS publishers,
    CAST(NULL AS BIGINT) AS genres,
    CAST(regions AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(sales / NULLIF((SELECT total_sales FROM total_sales), 0), 4) AS sales_share,
    ROUND(sales / NULLIF(game_platforms, 0), 4) AS avg_sales_per_game_platform,
    ROUND(dominant_region_share, 4) AS secondary_value,
    'dominant_region_share' AS secondary_label,
    'Platform strength can be global or region-skewed; this block identifies the difference.' AS notes
FROM platform_balance
WHERE sales_rank <= 15
UNION ALL
SELECT
    'cross_region_coverage' AS evidence_block,
    'game_region_coverage_bucket' AS grain,
    coverage_bucket AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'coverage_bucket_sales_rank' AS rank_label,
    CAST(ROW_NUMBER() OVER (ORDER BY sales DESC, coverage_bucket) AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(games AS BIGINT) AS games,
    CAST(game_platforms AS BIGINT) AS game_platforms,
    CAST(NULL AS BIGINT) AS platforms,
    CAST(NULL AS BIGINT) AS publishers,
    CAST(NULL AS BIGINT) AS genres,
    CAST(NULL AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(sales / NULLIF((SELECT total_sales FROM total_sales), 0), 4) AS sales_share,
    ROUND(sales / NULLIF(game_platforms, 0), 4) AS avg_sales_per_game_platform,
    CAST(NULL AS DOUBLE) AS secondary_value,
    'not_applicable' AS secondary_label,
    'Coverage buckets show whether global volume is carried by broadly distributed games or narrower regional successes.' AS notes
FROM coverage;
