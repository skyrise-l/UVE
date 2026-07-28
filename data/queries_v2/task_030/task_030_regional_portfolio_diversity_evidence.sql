-- task_030_regional_portfolio_diversity_evidence.sql
-- Draft evidence SQL for task_030.
-- Public query: Which regional markets have broad portfolios, and which depend on narrower platform, genre, or publisher structures?
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
region_total AS (
    SELECT
        region_name,
        COUNT(DISTINCT game_key) AS games,
        COUNT(DISTINCT game_platform_key) AS game_platforms,
        COUNT(DISTINCT platform_name) AS platforms,
        COUNT(DISTINCT genre_name) AS genres,
        COUNT(DISTINCT publisher_name) AS publishers,
        SUM(reported_sales_volume) AS sales
    FROM base_fact
    GROUP BY region_name
),
region_platform AS (
    SELECT region_name, platform_name, SUM(reported_sales_volume) AS sales
    FROM base_fact
    GROUP BY region_name, platform_name
),
region_platform_leader AS (
    SELECT
        rp.region_name,
        rp.platform_name,
        rp.sales,
        rt.sales AS region_sales,
        rp.sales / NULLIF(rt.sales, 0) AS leader_share
    FROM region_platform AS rp
    JOIN region_total AS rt ON rp.region_name = rt.region_name
    QUALIFY ROW_NUMBER() OVER (PARTITION BY rp.region_name ORDER BY rp.sales DESC, rp.platform_name) = 1
),
region_genre AS (
    SELECT region_name, genre_name, SUM(reported_sales_volume) AS sales
    FROM base_fact
    GROUP BY region_name, genre_name
),
region_genre_leader AS (
    SELECT
        rg.region_name,
        rg.genre_name,
        rg.sales,
        rt.sales AS region_sales,
        rg.sales / NULLIF(rt.sales, 0) AS leader_share
    FROM region_genre AS rg
    JOIN region_total AS rt ON rg.region_name = rt.region_name
    QUALIFY ROW_NUMBER() OVER (PARTITION BY rg.region_name ORDER BY rg.sales DESC, rg.genre_name) = 1
),
region_publisher AS (
    SELECT region_name, publisher_name, SUM(reported_sales_volume) AS sales
    FROM base_fact
    GROUP BY region_name, publisher_name
),
region_publisher_leader AS (
    SELECT
        rp.region_name,
        rp.publisher_name,
        rp.sales,
        rt.sales AS region_sales,
        rp.sales / NULLIF(rt.sales, 0) AS leader_share
    FROM region_publisher AS rp
    JOIN region_total AS rt ON rp.region_name = rt.region_name
    QUALIFY ROW_NUMBER() OVER (PARTITION BY rp.region_name ORDER BY rp.sales DESC, rp.publisher_name) = 1
),
region_profile AS (
    SELECT
        rt.*,
        rpl.platform_name AS top_platform,
        rpl.leader_share AS top_platform_share,
        rgl.genre_name AS top_genre,
        rgl.leader_share AS top_genre_share,
        rpub.publisher_name AS top_publisher,
        rpub.leader_share AS top_publisher_share,
        ROW_NUMBER() OVER (ORDER BY rt.sales DESC, rt.region_name) AS region_sales_rank
    FROM region_total AS rt
    LEFT JOIN region_platform_leader AS rpl ON rt.region_name = rpl.region_name
    LEFT JOIN region_genre_leader AS rgl ON rt.region_name = rgl.region_name
    LEFT JOIN region_publisher_leader AS rpub ON rt.region_name = rpub.region_name
),
region_pair_genre_similarity AS (
    SELECT
        a.region_name AS region_a,
        b.region_name AS region_b,
        SUM(a.sales * b.sales) / NULLIF(SQRT(SUM(a.sales * a.sales)) * SQRT(SUM(b.sales * b.sales)), 0) AS genre_mix_cosine_similarity
    FROM region_genre AS a
    JOIN region_genre AS b
      ON a.genre_name = b.genre_name AND a.region_name < b.region_name
    GROUP BY a.region_name, b.region_name
),
region_concentration_snapshot AS (
    SELECT
        region_name,
        top_platform,
        top_genre,
        top_publisher,
        GREATEST(top_platform_share, top_genre_share, top_publisher_share) AS strongest_single_axis_share,
        CASE
            WHEN top_platform_share >= top_genre_share AND top_platform_share >= top_publisher_share THEN 'platform'
            WHEN top_genre_share >= top_platform_share AND top_genre_share >= top_publisher_share THEN 'genre'
            ELSE 'publisher'
        END AS strongest_concentration_axis
    FROM region_profile
)
SELECT
    'region_market_breadth_baseline' AS evidence_block,
    'region' AS grain,
    region_name AS item,
    top_platform AS item_2,
    top_genre AS item_3,
    'region_sales_rank' AS rank_label,
    CAST(region_sales_rank AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(games AS BIGINT) AS games,
    CAST(game_platforms AS BIGINT) AS game_platforms,
    CAST(platforms AS BIGINT) AS platforms,
    CAST(publishers AS BIGINT) AS publishers,
    CAST(genres AS BIGINT) AS genres,
    CAST(1 AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(sales / NULLIF((SELECT total_sales FROM total_sales), 0), 4) AS sales_share,
    ROUND(sales / NULLIF(game_platforms, 0), 4) AS avg_sales_per_game_platform,
    ROUND(top_platform_share, 4) AS secondary_value,
    'top_platform_share' AS secondary_label,
    'Establish each region market size and breadth before concentration analysis.' AS notes
FROM region_profile
UNION ALL
SELECT
    'region_platform_concentration' AS evidence_block,
    'region_platform' AS grain,
    region_name AS item,
    platform_name AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'top_platform_share' AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(NULL AS BIGINT) AS games,
    CAST(NULL AS BIGINT) AS game_platforms,
    CAST(1 AS BIGINT) AS platforms,
    CAST(NULL AS BIGINT) AS publishers,
    CAST(NULL AS BIGINT) AS genres,
    CAST(1 AS BIGINT) AS regions,
    ROUND(region_sales, 4) AS reported_sales_volume,
    ROUND(leader_share, 4) AS sales_share,
    CAST(NULL AS DOUBLE) AS avg_sales_per_game_platform,
    ROUND(sales, 4) AS secondary_value,
    'top_platform_sales' AS secondary_label,
    'Quantify platform concentration within each regional market.' AS notes
FROM region_platform_leader
UNION ALL
SELECT
    'region_genre_concentration' AS evidence_block,
    'region_genre' AS grain,
    region_name AS item,
    genre_name AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'top_genre_share' AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(NULL AS BIGINT) AS games,
    CAST(NULL AS BIGINT) AS game_platforms,
    CAST(NULL AS BIGINT) AS platforms,
    CAST(NULL AS BIGINT) AS publishers,
    CAST(1 AS BIGINT) AS genres,
    CAST(1 AS BIGINT) AS regions,
    ROUND(region_sales, 4) AS reported_sales_volume,
    ROUND(leader_share, 4) AS sales_share,
    CAST(NULL AS DOUBLE) AS avg_sales_per_game_platform,
    ROUND(sales, 4) AS secondary_value,
    'top_genre_sales' AS secondary_label,
    'Quantify genre concentration within each regional market.' AS notes
FROM region_genre_leader
UNION ALL
SELECT
    'region_publisher_concentration' AS evidence_block,
    'region_publisher' AS grain,
    region_name AS item,
    publisher_name AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'top_publisher_share' AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(NULL AS BIGINT) AS games,
    CAST(NULL AS BIGINT) AS game_platforms,
    CAST(NULL AS BIGINT) AS platforms,
    CAST(1 AS BIGINT) AS publishers,
    CAST(NULL AS BIGINT) AS genres,
    CAST(1 AS BIGINT) AS regions,
    ROUND(region_sales, 4) AS reported_sales_volume,
    ROUND(leader_share, 4) AS sales_share,
    CAST(NULL AS DOUBLE) AS avg_sales_per_game_platform,
    ROUND(sales, 4) AS secondary_value,
    'top_publisher_sales' AS secondary_label,
    'Quantify publisher concentration within each regional market.' AS notes
FROM region_publisher_leader
UNION ALL
SELECT
    'region_pair_genre_similarity' AS evidence_block,
    'region_pair' AS grain,
    region_a AS item,
    region_b AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'genre_mix_cosine_similarity' AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(NULL AS BIGINT) AS games,
    CAST(NULL AS BIGINT) AS game_platforms,
    CAST(NULL AS BIGINT) AS platforms,
    CAST(NULL AS BIGINT) AS publishers,
    CAST(NULL AS BIGINT) AS genres,
    CAST(2 AS BIGINT) AS regions,
    CAST(NULL AS DOUBLE) AS reported_sales_volume,
    ROUND(genre_mix_cosine_similarity, 4) AS sales_share,
    CAST(NULL AS DOUBLE) AS avg_sales_per_game_platform,
    CAST(NULL AS DOUBLE) AS secondary_value,
    'not_applicable' AS secondary_label,
    'Compare whether regions have similar or distinct genre portfolios.' AS notes
FROM region_pair_genre_similarity
UNION ALL
SELECT
    'region_pair_genre_similarity' AS evidence_block,
    'region_pair' AS grain,
    'insufficient_sample_regions' AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'genre_mix_cosine_similarity' AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(NULL AS BIGINT) AS games,
    CAST(NULL AS BIGINT) AS game_platforms,
    CAST(NULL AS BIGINT) AS platforms,
    CAST(NULL AS BIGINT) AS publishers,
    CAST(NULL AS BIGINT) AS genres,
    CAST(NULL AS BIGINT) AS regions,
    CAST(NULL AS DOUBLE) AS reported_sales_volume,
    CAST(NULL AS DOUBLE) AS sales_share,
    CAST(NULL AS DOUBLE) AS avg_sales_per_game_platform,
    CAST(NULL AS DOUBLE) AS secondary_value,
    'sample_only_placeholder' AS secondary_label,
    'Placeholder only for sample rows when fewer than two regions have sales; full results should contain real region-pair similarities.' AS notes
WHERE NOT EXISTS (SELECT 1 FROM region_pair_genre_similarity)
UNION ALL
SELECT
    'region_strongest_concentration_axis' AS evidence_block,
    'region' AS grain,
    region_name AS item,
    strongest_concentration_axis AS item_2,
    CASE
        WHEN strongest_concentration_axis = 'platform' THEN top_platform
        WHEN strongest_concentration_axis = 'genre' THEN top_genre
        ELSE top_publisher
    END AS item_3,
    'strongest_single_axis_share' AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(NULL AS BIGINT) AS games,
    CAST(NULL AS BIGINT) AS game_platforms,
    CAST(NULL AS BIGINT) AS platforms,
    CAST(NULL AS BIGINT) AS publishers,
    CAST(NULL AS BIGINT) AS genres,
    CAST(1 AS BIGINT) AS regions,
    CAST(NULL AS DOUBLE) AS reported_sales_volume,
    ROUND(strongest_single_axis_share, 4) AS sales_share,
    CAST(NULL AS DOUBLE) AS avg_sales_per_game_platform,
    CAST(NULL AS DOUBLE) AS secondary_value,
    'not_applicable' AS secondary_label,
    'Identify the main axis through which each region is most concentrated.' AS notes
FROM region_concentration_snapshot
