-- task_026_genre_platform_fit_evidence.sql
-- Draft evidence SQL for task_026.
-- Public query: Which genre-platform pairings explain market strength better than looking at genres or platforms separately?
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
combo_total AS (
    SELECT
        genre_name,
        platform_name,
        COUNT(DISTINCT game_key) AS games,
        COUNT(DISTINCT game_platform_key) AS game_platforms,
        COUNT(DISTINCT publisher_name) AS publishers,
        COUNT(DISTINCT region_name) FILTER (WHERE reported_sales_volume > 0) AS regions,
        SUM(reported_sales_volume) AS sales
    FROM base_fact
    GROUP BY genre_name, platform_name
),
combo_ranked AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY sales DESC, genre_name, platform_name) AS sales_rank
    FROM combo_total
),
genre_total AS (
    SELECT genre_name, SUM(reported_sales_volume) AS genre_sales, COUNT(DISTINCT game_key) AS games
    FROM base_fact
    GROUP BY genre_name
),
genre_platform AS (
    SELECT
        genre_name,
        platform_name,
        SUM(reported_sales_volume) AS sales,
        COUNT(DISTINCT game_key) AS games
    FROM base_fact
    GROUP BY genre_name, platform_name
),
genre_dominant_platform AS (
    SELECT
        gp.genre_name,
        gp.platform_name,
        gp.sales,
        gt.genre_sales,
        gp.sales / NULLIF(gt.genre_sales, 0) AS platform_share_within_genre,
        gt.games AS genre_games
    FROM genre_platform AS gp
    JOIN genre_total AS gt ON gp.genre_name = gt.genre_name
    QUALIFY ROW_NUMBER() OVER (PARTITION BY gp.genre_name ORDER BY gp.sales DESC, gp.platform_name) = 1
),
platform_total AS (
    SELECT platform_name, SUM(reported_sales_volume) AS platform_sales, COUNT(DISTINCT game_key) AS games
    FROM base_fact
    GROUP BY platform_name
),
platform_genre AS (
    SELECT platform_name, genre_name, SUM(reported_sales_volume) AS sales, COUNT(DISTINCT game_key) AS games
    FROM base_fact
    GROUP BY platform_name, genre_name
),
platform_dominant_genre AS (
    SELECT
        pg.platform_name,
        pg.genre_name,
        pg.sales,
        pt.platform_sales,
        pg.sales / NULLIF(pt.platform_sales, 0) AS genre_share_within_platform,
        pt.games AS platform_games
    FROM platform_genre AS pg
    JOIN platform_total AS pt ON pg.platform_name = pt.platform_name
    QUALIFY ROW_NUMBER() OVER (PARTITION BY pg.platform_name ORDER BY pg.sales DESC, pg.genre_name) = 1
),
region_combo AS (
    SELECT
        region_name,
        genre_name,
        platform_name,
        SUM(reported_sales_volume) AS sales,
        COUNT(DISTINCT game_key) AS games
    FROM base_fact
    GROUP BY region_name, genre_name, platform_name
),
region_combo_leaders AS (
    SELECT
        region_name,
        genre_name,
        platform_name,
        sales,
        games,
        ROW_NUMBER() OVER (PARTITION BY region_name ORDER BY sales DESC, genre_name, platform_name) AS region_rank,
        sales / NULLIF(SUM(sales) OVER (PARTITION BY region_name), 0) AS region_sales_share
    FROM region_combo
),
combo_region_coverage AS (
    SELECT
        CASE
            WHEN regions >= 4 THEN 'four_region_genre_platform_pairs'
            WHEN regions = 3 THEN 'three_region_genre_platform_pairs'
            WHEN regions = 2 THEN 'two_region_genre_platform_pairs'
            WHEN regions = 1 THEN 'one_region_genre_platform_pairs'
            ELSE 'no_positive_region'
        END AS coverage_bucket,
        COUNT(*) AS combos,
        SUM(games) AS games,
        SUM(game_platforms) AS game_platforms,
        SUM(sales) AS sales
    FROM combo_total
    GROUP BY coverage_bucket
)
SELECT
    'genre_platform_market_baseline' AS evidence_block,
    'genre_platform_pair' AS grain,
    genre_name AS item,
    platform_name AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'genre_platform_sales_rank' AS rank_label,
    CAST(sales_rank AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(games AS BIGINT) AS games,
    CAST(game_platforms AS BIGINT) AS game_platforms,
    CAST(1 AS BIGINT) AS platforms,
    CAST(publishers AS BIGINT) AS publishers,
    CAST(1 AS BIGINT) AS genres,
    CAST(regions AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(sales / NULLIF((SELECT total_sales FROM total_sales), 0), 4) AS sales_share,
    ROUND(sales / NULLIF(game_platforms, 0), 4) AS avg_sales_per_game_platform,
    CAST(NULL AS DOUBLE) AS secondary_value,
    'not_applicable' AS secondary_label,
    'Rank genre-platform pairings before interpreting genre or platform strength in isolation.' AS notes
FROM combo_ranked
WHERE sales_rank <= 20
UNION ALL
SELECT
    'genre_dominant_platform' AS evidence_block,
    'genre' AS grain,
    genre_name AS item,
    platform_name AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'dominant_platform_share_within_genre' AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(genre_games AS BIGINT) AS games,
    CAST(NULL AS BIGINT) AS game_platforms,
    CAST(1 AS BIGINT) AS platforms,
    CAST(NULL AS BIGINT) AS publishers,
    CAST(1 AS BIGINT) AS genres,
    CAST(NULL AS BIGINT) AS regions,
    ROUND(genre_sales, 4) AS reported_sales_volume,
    ROUND(platform_share_within_genre, 4) AS sales_share,
    CAST(NULL AS DOUBLE) AS avg_sales_per_game_platform,
    ROUND(sales, 4) AS secondary_value,
    'dominant_platform_sales' AS secondary_label,
    'Quantify whether a genre is broadly portable or led by one platform.' AS notes
FROM genre_dominant_platform
UNION ALL
SELECT
    'platform_dominant_genre' AS evidence_block,
    'platform' AS grain,
    platform_name AS item,
    genre_name AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'dominant_genre_share_within_platform' AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(platform_games AS BIGINT) AS games,
    CAST(NULL AS BIGINT) AS game_platforms,
    CAST(1 AS BIGINT) AS platforms,
    CAST(NULL AS BIGINT) AS publishers,
    CAST(1 AS BIGINT) AS genres,
    CAST(NULL AS BIGINT) AS regions,
    ROUND(platform_sales, 4) AS reported_sales_volume,
    ROUND(genre_share_within_platform, 4) AS sales_share,
    CAST(NULL AS DOUBLE) AS avg_sales_per_game_platform,
    ROUND(sales, 4) AS secondary_value,
    'dominant_genre_sales' AS secondary_label,
    'Identify whether platform performance is diversified across genres or dominated by one content type.' AS notes
FROM platform_dominant_genre
UNION ALL
SELECT
    'regional_genre_platform_leaders' AS evidence_block,
    'region_genre_platform_pair' AS grain,
    region_name AS item,
    genre_name AS item_2,
    platform_name AS item_3,
    'rank_within_region' AS rank_label,
    CAST(region_rank AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(games AS BIGINT) AS games,
    CAST(NULL AS BIGINT) AS game_platforms,
    CAST(1 AS BIGINT) AS platforms,
    CAST(NULL AS BIGINT) AS publishers,
    CAST(1 AS BIGINT) AS genres,
    CAST(1 AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(region_sales_share, 4) AS sales_share,
    CAST(NULL AS DOUBLE) AS avg_sales_per_game_platform,
    CAST(NULL AS DOUBLE) AS secondary_value,
    'not_applicable' AS secondary_label,
    'Expose regional exceptions in which a different genre-platform pairing leads.' AS notes
FROM region_combo_leaders
WHERE region_rank <= 3
UNION ALL
SELECT
    'genre_platform_region_coverage' AS evidence_block,
    'coverage_bucket' AS grain,
    coverage_bucket AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'coverage_bucket' AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
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
    CAST(NULL AS DOUBLE) AS avg_sales_per_game_platform,
    CAST(combos AS DOUBLE) AS secondary_value,
    'genre_platform_pairs' AS secondary_label,
    'Separate strong local pairings from pairings that travel across regions.' AS notes
FROM combo_region_coverage
