-- task_022_genre_regional_preference_evidence.sql
-- Evidence SQL for task_022.
-- Public query: Which game genres travel well across regions, and which genres depend strongly on specific regional markets?
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
genre_total AS (
    SELECT
        genre_name,
        COUNT(DISTINCT game_key) AS games,
        COUNT(DISTINCT game_platform_key) AS game_platforms,
        COUNT(DISTINCT platform_name) AS platforms,
        COUNT(DISTINCT publisher_name) AS publishers,
        COUNT(DISTINCT region_name) FILTER (WHERE reported_sales_volume > 0) AS regions,
        SUM(reported_sales_volume) AS sales
    FROM base_fact
    GROUP BY genre_name
),
genre_ranked AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY sales DESC, genre_name) AS sales_rank
    FROM genre_total
),
genre_region AS (
    SELECT
        genre_name,
        region_name,
        COUNT(DISTINCT game_key) AS games,
        COUNT(DISTINCT game_platform_key) AS game_platforms,
        SUM(reported_sales_volume) AS sales
    FROM base_fact
    GROUP BY genre_name, region_name
),
genre_region_share AS (
    SELECT
        gr.*,
        gt.sales AS genre_sales,
        gr.sales / NULLIF(gt.sales, 0) AS genre_region_share,
        ROW_NUMBER() OVER (PARTITION BY gr.genre_name ORDER BY gr.sales DESC, gr.region_name) AS region_rank_within_genre
    FROM genre_region AS gr
    JOIN genre_total AS gt
      ON gr.genre_name = gt.genre_name
),
genre_specialization AS (
    SELECT
        genre_name,
        region_name AS dominant_region,
        sales AS dominant_region_sales,
        genre_sales,
        genre_region_share AS dominant_region_share,
        ROW_NUMBER() OVER (ORDER BY genre_sales DESC, genre_name) AS genre_sales_rank
    FROM genre_region_share
    WHERE region_rank_within_genre = 1
),
region_genre_leaders AS (
    SELECT
        region_name,
        genre_name,
        games,
        game_platforms,
        sales,
        ROW_NUMBER() OVER (PARTITION BY region_name ORDER BY sales DESC, genre_name) AS genre_rank_in_region,
        sales / NULLIF(SUM(sales) OVER (PARTITION BY region_name), 0) AS region_genre_share
    FROM genre_region
),
genre_platform AS (
    SELECT
        genre_name,
        platform_name,
        COUNT(DISTINCT game_key) AS games,
        COUNT(DISTINCT game_platform_key) AS game_platforms,
        SUM(reported_sales_volume) AS sales
    FROM base_fact
    GROUP BY genre_name, platform_name
),
genre_platform_leader AS (
    SELECT
        gp.genre_name,
        gp.platform_name AS leading_platform,
        gp.sales AS leading_platform_sales,
        gt.sales AS genre_sales,
        gp.sales / NULLIF(gt.sales, 0) AS leading_platform_share,
        ROW_NUMBER() OVER (ORDER BY gt.sales DESC, gp.genre_name) AS genre_sales_rank
    FROM genre_platform AS gp
    JOIN genre_total AS gt
      ON gp.genre_name = gt.genre_name
    QUALIFY ROW_NUMBER() OVER (PARTITION BY gp.genre_name ORDER BY gp.sales DESC, gp.platform_name) = 1
)
SELECT
    'genre_global_baseline' AS evidence_block,
    'genre' AS grain,
    genre_name AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'genre_sales_rank' AS rank_label,
    CAST(sales_rank AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(games AS BIGINT) AS games,
    CAST(game_platforms AS BIGINT) AS game_platforms,
    CAST(platforms AS BIGINT) AS platforms,
    CAST(publishers AS BIGINT) AS publishers,
    CAST(1 AS BIGINT) AS genres,
    CAST(regions AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(sales / NULLIF((SELECT total_sales FROM total_sales), 0), 4) AS sales_share,
    ROUND(sales / NULLIF(game_platforms, 0), 4) AS avg_sales_per_game_platform,
    CAST(NULL AS DOUBLE) AS secondary_value,
    'not_applicable' AS secondary_label,
    'Start with global genre scale before judging whether a genre travels broadly.' AS notes
FROM genre_ranked
UNION ALL
SELECT
    'genre_regional_specialization' AS evidence_block,
    'genre' AS grain,
    genre_name AS item,
    dominant_region AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'genre_sales_rank' AS rank_label,
    CAST(genre_sales_rank AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(NULL AS BIGINT) AS games,
    CAST(NULL AS BIGINT) AS game_platforms,
    CAST(NULL AS BIGINT) AS platforms,
    CAST(NULL AS BIGINT) AS publishers,
    CAST(1 AS BIGINT) AS genres,
    CAST(NULL AS BIGINT) AS regions,
    ROUND(genre_sales, 4) AS reported_sales_volume,
    ROUND(genre_sales / NULLIF((SELECT total_sales FROM total_sales), 0), 4) AS sales_share,
    CAST(NULL AS DOUBLE) AS avg_sales_per_game_platform,
    ROUND(dominant_region_share, 4) AS secondary_value,
    'dominant_region_share' AS secondary_label,
    'A genre can be globally large but still region-dependent; dominant-region share is the key anchor.' AS notes
FROM genre_specialization
UNION ALL
SELECT
    'region_genre_leaders' AS evidence_block,
    'region_genre' AS grain,
    region_name AS item,
    genre_name AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'genre_rank_in_region' AS rank_label,
    CAST(genre_rank_in_region AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(games AS BIGINT) AS games,
    CAST(game_platforms AS BIGINT) AS game_platforms,
    CAST(NULL AS BIGINT) AS platforms,
    CAST(NULL AS BIGINT) AS publishers,
    CAST(1 AS BIGINT) AS genres,
    CAST(1 AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(region_genre_share, 4) AS sales_share,
    ROUND(sales / NULLIF(game_platforms, 0), 4) AS avg_sales_per_game_platform,
    CAST(NULL AS DOUBLE) AS secondary_value,
    'not_applicable' AS secondary_label,
    'Regional leaders reveal local demand structure that a global genre ranking can miss.' AS notes
FROM region_genre_leaders
WHERE genre_rank_in_region <= 3
UNION ALL
SELECT
    'genre_platform_fit' AS evidence_block,
    'genre_platform_leader' AS grain,
    genre_name AS item,
    leading_platform AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'genre_sales_rank' AS rank_label,
    CAST(genre_sales_rank AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(NULL AS BIGINT) AS games,
    CAST(NULL AS BIGINT) AS game_platforms,
    CAST(1 AS BIGINT) AS platforms,
    CAST(NULL AS BIGINT) AS publishers,
    CAST(1 AS BIGINT) AS genres,
    CAST(NULL AS BIGINT) AS regions,
    ROUND(genre_sales, 4) AS reported_sales_volume,
    ROUND(genre_sales / NULLIF((SELECT total_sales FROM total_sales), 0), 4) AS sales_share,
    CAST(NULL AS DOUBLE) AS avg_sales_per_game_platform,
    ROUND(leading_platform_share, 4) AS secondary_value,
    'leading_platform_share_within_genre' AS secondary_label,
    'Genre performance should be read with platform fit, not only with region totals.' AS notes
FROM genre_platform_leader;
