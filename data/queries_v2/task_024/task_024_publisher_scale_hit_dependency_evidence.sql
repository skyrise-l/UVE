-- task_024_publisher_scale_hit_dependency_evidence.sql
-- Evidence SQL for task_024.
-- Public query: Which publishers look strong because they have broad portfolios, and which are more dependent on a few hits or specific regions?
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
publisher_total AS (
    SELECT
        publisher_name,
        COUNT(DISTINCT game_key) AS games,
        COUNT(DISTINCT game_platform_key) AS game_platforms,
        COUNT(DISTINCT platform_name) AS platforms,
        COUNT(DISTINCT genre_name) AS genres,
        COUNT(DISTINCT region_name) FILTER (WHERE reported_sales_volume > 0) AS regions,
        SUM(reported_sales_volume) AS sales
    FROM base_fact
    GROUP BY publisher_name
),
publisher_ranked AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY sales DESC, publisher_name) AS sales_rank
    FROM publisher_total
),
publisher_game AS (
    SELECT
        publisher_name,
        game_key,
        game_name,
        COUNT(DISTINCT game_platform_key) AS game_platforms,
        COUNT(DISTINCT platform_name) AS platforms,
        COUNT(DISTINCT region_name) FILTER (WHERE reported_sales_volume > 0) AS regions,
        SUM(reported_sales_volume) AS sales
    FROM base_fact
    GROUP BY publisher_name, game_key, game_name
),
publisher_top_game AS (
    SELECT
        pg.publisher_name,
        pg.game_name AS top_game,
        pg.sales AS top_game_sales,
        pt.sales AS publisher_sales,
        pt.games,
        pt.game_platforms,
        pt.platforms,
        pt.genres,
        pt.regions,
        pg.sales / NULLIF(pt.sales, 0) AS top_game_share,
        ROW_NUMBER() OVER (ORDER BY pt.sales DESC, pg.publisher_name) AS publisher_sales_rank
    FROM publisher_game AS pg
    JOIN publisher_total AS pt
      ON pg.publisher_name = pt.publisher_name
    QUALIFY ROW_NUMBER() OVER (PARTITION BY pg.publisher_name ORDER BY pg.sales DESC, pg.game_name) = 1
),
publisher_region AS (
    SELECT
        publisher_name,
        region_name,
        SUM(reported_sales_volume) AS sales
    FROM base_fact
    GROUP BY publisher_name, region_name
),
publisher_region_balance AS (
    SELECT
        pr.publisher_name,
        pr.region_name AS dominant_region,
        pr.sales AS dominant_region_sales,
        pt.sales AS publisher_sales,
        pr.sales / NULLIF(pt.sales, 0) AS dominant_region_share,
        ROW_NUMBER() OVER (ORDER BY pt.sales DESC, pr.publisher_name) AS publisher_sales_rank
    FROM publisher_region AS pr
    JOIN publisher_total AS pt
      ON pr.publisher_name = pt.publisher_name
    QUALIFY ROW_NUMBER() OVER (PARTITION BY pr.publisher_name ORDER BY pr.sales DESC, pr.region_name) = 1
),
publisher_genre AS (
    SELECT
        publisher_name,
        genre_name,
        COUNT(DISTINCT game_key) AS games,
        SUM(reported_sales_volume) AS sales
    FROM base_fact
    GROUP BY publisher_name, genre_name
),
publisher_genre_leader AS (
    SELECT
        pg.publisher_name,
        pg.genre_name AS leading_genre,
        pg.sales AS leading_genre_sales,
        pt.sales AS publisher_sales,
        pg.sales / NULLIF(pt.sales, 0) AS leading_genre_share,
        ROW_NUMBER() OVER (ORDER BY pt.sales DESC, pg.publisher_name) AS publisher_sales_rank
    FROM publisher_genre AS pg
    JOIN publisher_total AS pt
      ON pg.publisher_name = pt.publisher_name
    QUALIFY ROW_NUMBER() OVER (PARTITION BY pg.publisher_name ORDER BY pg.sales DESC, pg.genre_name) = 1
),
publisher_scale_bucket AS (
    SELECT
        CASE
            WHEN sales_rank <= 10 THEN 'top_10_publishers'
            WHEN sales_rank <= 50 THEN 'rank_11_to_50_publishers'
            ELSE 'long_tail_publishers'
        END AS publisher_scale_bucket,
        COUNT(*) AS publishers,
        SUM(games) AS games,
        SUM(game_platforms) AS game_platforms,
        SUM(sales) AS sales
    FROM publisher_ranked
    GROUP BY publisher_scale_bucket
)
SELECT
    'publisher_scale_baseline' AS evidence_block,
    'publisher' AS grain,
    publisher_name AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
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
    ROUND(sales / NULLIF(games, 0), 4) AS secondary_value,
    'sales_per_game' AS secondary_label,
    'Scale baseline separates publisher size from portfolio quality.' AS notes
FROM publisher_ranked
WHERE sales_rank <= 25
UNION ALL
SELECT
    'publisher_hit_dependency' AS evidence_block,
    'publisher_top_game' AS grain,
    publisher_name AS item,
    top_game AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'publisher_sales_rank' AS rank_label,
    CAST(publisher_sales_rank AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(games AS BIGINT) AS games,
    CAST(game_platforms AS BIGINT) AS game_platforms,
    CAST(platforms AS BIGINT) AS platforms,
    CAST(1 AS BIGINT) AS publishers,
    CAST(genres AS BIGINT) AS genres,
    CAST(regions AS BIGINT) AS regions,
    ROUND(publisher_sales, 4) AS reported_sales_volume,
    ROUND(publisher_sales / NULLIF((SELECT total_sales FROM total_sales), 0), 4) AS sales_share,
    ROUND(publisher_sales / NULLIF(game_platforms, 0), 4) AS avg_sales_per_game_platform,
    ROUND(top_game_share, 4) AS secondary_value,
    'top_game_sales_share_within_publisher' AS secondary_label,
    'A publisher can be large because of many games or because one hit dominates.' AS notes
FROM publisher_top_game
WHERE publisher_sales_rank <= 25 OR top_game_share >= 0.5
UNION ALL
SELECT
    'publisher_region_balance' AS evidence_block,
    'publisher_region_balance' AS grain,
    publisher_name AS item,
    dominant_region AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'publisher_sales_rank' AS rank_label,
    CAST(publisher_sales_rank AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(NULL AS BIGINT) AS games,
    CAST(NULL AS BIGINT) AS game_platforms,
    CAST(NULL AS BIGINT) AS platforms,
    CAST(1 AS BIGINT) AS publishers,
    CAST(NULL AS BIGINT) AS genres,
    CAST(NULL AS BIGINT) AS regions,
    ROUND(publisher_sales, 4) AS reported_sales_volume,
    ROUND(publisher_sales / NULLIF((SELECT total_sales FROM total_sales), 0), 4) AS sales_share,
    CAST(NULL AS DOUBLE) AS avg_sales_per_game_platform,
    ROUND(dominant_region_share, 4) AS secondary_value,
    'dominant_region_share_within_publisher' AS secondary_label,
    'Region balance distinguishes broadly global publishers from region-heavy publishers.' AS notes
FROM publisher_region_balance
WHERE publisher_sales_rank <= 25
UNION ALL
SELECT
    'publisher_genre_focus' AS evidence_block,
    'publisher_genre_leader' AS grain,
    publisher_name AS item,
    leading_genre AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'publisher_sales_rank' AS rank_label,
    CAST(publisher_sales_rank AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(NULL AS BIGINT) AS games,
    CAST(NULL AS BIGINT) AS game_platforms,
    CAST(NULL AS BIGINT) AS platforms,
    CAST(1 AS BIGINT) AS publishers,
    CAST(1 AS BIGINT) AS genres,
    CAST(NULL AS BIGINT) AS regions,
    ROUND(publisher_sales, 4) AS reported_sales_volume,
    ROUND(publisher_sales / NULLIF((SELECT total_sales FROM total_sales), 0), 4) AS sales_share,
    CAST(NULL AS DOUBLE) AS avg_sales_per_game_platform,
    ROUND(leading_genre_share, 4) AS secondary_value,
    'leading_genre_share_within_publisher' AS secondary_label,
    'Genre focus checks whether publisher scale comes from a balanced catalogue or one dominant genre.' AS notes
FROM publisher_genre_leader
WHERE publisher_sales_rank <= 25
UNION ALL
SELECT
    'publisher_scale_bucket_concentration' AS evidence_block,
    'publisher_scale_bucket' AS grain,
    publisher_scale_bucket AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'bucket_sales_rank' AS rank_label,
    CAST(ROW_NUMBER() OVER (ORDER BY sales DESC, publisher_scale_bucket) AS DOUBLE) AS rank_value,
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
    ROUND(sales / NULLIF(game_platforms, 0), 4) AS avg_sales_per_game_platform,
    CAST(NULL AS DOUBLE) AS secondary_value,
    'not_applicable' AS secondary_label,
    'Publisher concentration bucket shows how much market weight sits with the largest publisher group.' AS notes
FROM publisher_scale_bucket;
