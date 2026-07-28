-- task_027_release_era_genre_migration_evidence.sql
-- Draft evidence SQL for task_027.
-- Public query: How did the mix of game genres shift across release eras, and which shifts look like real demand changes rather than just more releases?
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
era_fact AS (
    SELECT
        *,
        CASE
            WHEN release_year < 1990 THEN 'pre_1990'
            WHEN release_year BETWEEN 1990 AND 1999 THEN '1990s'
            WHEN release_year BETWEEN 2000 AND 2009 THEN '2000s'
            WHEN release_year >= 2010 THEN '2010s_plus'
            ELSE 'unknown_year'
        END AS release_era
    FROM base_fact
),
era_baseline AS (
    SELECT
        release_era,
        MIN(release_year) AS start_year,
        MAX(release_year) AS end_year,
        COUNT(DISTINCT game_key) AS games,
        COUNT(DISTINCT game_platform_key) AS game_platforms,
        COUNT(DISTINCT platform_name) AS platforms,
        COUNT(DISTINCT genre_name) AS genres,
        SUM(reported_sales_volume) AS sales
    FROM era_fact
    GROUP BY release_era
),
era_genre AS (
    SELECT
        release_era,
        genre_name,
        COUNT(DISTINCT game_key) AS games,
        COUNT(DISTINCT game_platform_key) AS game_platforms,
        SUM(reported_sales_volume) AS sales,
        ROW_NUMBER() OVER (PARTITION BY release_era ORDER BY SUM(reported_sales_volume) DESC, genre_name) AS era_genre_rank,
        SUM(reported_sales_volume) / NULLIF(SUM(SUM(reported_sales_volume)) OVER (PARTITION BY release_era), 0) AS share_within_era
    FROM era_fact
    GROUP BY release_era, genre_name
),
genre_era AS (
    SELECT
        genre_name,
        release_era,
        COUNT(DISTINCT game_key) AS games,
        SUM(reported_sales_volume) AS sales,
        SUM(reported_sales_volume) / NULLIF(SUM(SUM(reported_sales_volume)) OVER (PARTITION BY genre_name), 0) AS era_share_within_genre,
        ROW_NUMBER() OVER (PARTITION BY genre_name ORDER BY SUM(reported_sales_volume) DESC, release_era) AS genre_era_rank
    FROM era_fact
    GROUP BY genre_name, release_era
),
genre_dominant_era AS (
    SELECT *
    FROM genre_era
    WHERE genre_era_rank = 1
),
year_profile AS (
    SELECT
        release_year,
        COUNT(DISTINCT game_platform_key) AS releases,
        COUNT(DISTINCT game_key) AS games,
        SUM(reported_sales_volume) AS sales,
        SUM(reported_sales_volume) / NULLIF(COUNT(DISTINCT game_platform_key), 0) AS avg_sales_per_release,
        ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT game_platform_key) DESC, release_year) AS release_count_rank,
        ROW_NUMBER() OVER (ORDER BY SUM(reported_sales_volume) DESC, release_year) AS sales_rank
    FROM era_fact
    WHERE release_year IS NOT NULL
    GROUP BY release_year
),
region_era_genre AS (
    SELECT
        region_name,
        release_era,
        genre_name,
        SUM(reported_sales_volume) AS sales,
        SUM(reported_sales_volume) / NULLIF(SUM(SUM(reported_sales_volume)) OVER (PARTITION BY region_name, release_era), 0) AS share_within_region_era,
        ROW_NUMBER() OVER (PARTITION BY region_name, release_era ORDER BY SUM(reported_sales_volume) DESC, genre_name) AS rank_within_region_era
    FROM era_fact
    GROUP BY region_name, release_era, genre_name
),
era_platform_leader AS (
    SELECT
        release_era,
        platform_name,
        SUM(reported_sales_volume) AS sales,
        COUNT(DISTINCT game_key) AS games,
        SUM(reported_sales_volume) / NULLIF(SUM(SUM(reported_sales_volume)) OVER (PARTITION BY release_era), 0) AS share_within_era,
        ROW_NUMBER() OVER (PARTITION BY release_era ORDER BY SUM(reported_sales_volume) DESC, platform_name) AS rank_within_era
    FROM era_fact
    GROUP BY release_era, platform_name
)
SELECT
    'era_sales_release_baseline' AS evidence_block,
    'release_era' AS grain,
    release_era AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'era_sales_share' AS rank_label,
    CAST(NULL AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(start_year AS BIGINT) AS start_year,
    CAST(end_year AS BIGINT) AS end_year,
    CAST(games AS BIGINT) AS games,
    CAST(game_platforms AS BIGINT) AS game_platforms,
    CAST(platforms AS BIGINT) AS platforms,
    CAST(NULL AS BIGINT) AS publishers,
    CAST(genres AS BIGINT) AS genres,
    CAST(NULL AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(sales / NULLIF((SELECT total_sales FROM total_sales), 0), 4) AS sales_share,
    ROUND(sales / NULLIF(game_platforms, 0), 4) AS avg_sales_per_game_platform,
    CAST(NULL AS DOUBLE) AS secondary_value,
    'not_applicable' AS secondary_label,
    'Establish whether era shifts are driven by release supply or sales conversion.' AS notes
FROM era_baseline
UNION ALL
SELECT
    'era_genre_leaders' AS evidence_block,
    'era_genre' AS grain,
    release_era AS item,
    genre_name AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'rank_within_era' AS rank_label,
    CAST(era_genre_rank AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(games AS BIGINT) AS games,
    CAST(game_platforms AS BIGINT) AS game_platforms,
    CAST(NULL AS BIGINT) AS platforms,
    CAST(NULL AS BIGINT) AS publishers,
    CAST(1 AS BIGINT) AS genres,
    CAST(NULL AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(share_within_era, 4) AS sales_share,
    ROUND(sales / NULLIF(game_platforms, 0), 4) AS avg_sales_per_game_platform,
    CAST(NULL AS DOUBLE) AS secondary_value,
    'not_applicable' AS secondary_label,
    'Identify the leading genres within each release era.' AS notes
FROM era_genre
WHERE era_genre_rank <= 3
UNION ALL
SELECT
    'genre_dominant_era' AS evidence_block,
    'genre' AS grain,
    genre_name AS item,
    release_era AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'dominant_era_share_within_genre' AS rank_label,
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
    ROUND(era_share_within_genre, 4) AS sales_share,
    CAST(NULL AS DOUBLE) AS avg_sales_per_game_platform,
    CAST(NULL AS DOUBLE) AS secondary_value,
    'not_applicable' AS secondary_label,
    'Show whether each genre is concentrated in one era or spread across time.' AS notes
FROM genre_dominant_era
UNION ALL
SELECT
    'year_release_sales_alignment' AS evidence_block,
    'release_year' AS grain,
    CAST(release_year AS VARCHAR) AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'sales_rank_minus_release_rank' AS rank_label,
    CAST(sales_rank - release_count_rank AS DOUBLE) AS rank_value,
    CAST(release_year AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(games AS BIGINT) AS games,
    CAST(releases AS BIGINT) AS game_platforms,
    CAST(NULL AS BIGINT) AS platforms,
    CAST(NULL AS BIGINT) AS publishers,
    CAST(NULL AS BIGINT) AS genres,
    CAST(NULL AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    CAST(NULL AS DOUBLE) AS sales_share,
    ROUND(avg_sales_per_release, 4) AS avg_sales_per_game_platform,
    CAST(release_count_rank AS DOUBLE) AS secondary_value,
    'release_count_rank' AS secondary_label,
    'Compare release supply and reported sales quality by year.' AS notes
FROM year_profile
WHERE sales_rank <= 10 OR release_count_rank <= 10
UNION ALL
SELECT
    'region_era_genre_leaders' AS evidence_block,
    'region_era_genre' AS grain,
    region_name AS item,
    release_era AS item_2,
    genre_name AS item_3,
    'rank_within_region_era' AS rank_label,
    CAST(rank_within_region_era AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(NULL AS BIGINT) AS games,
    CAST(NULL AS BIGINT) AS game_platforms,
    CAST(NULL AS BIGINT) AS platforms,
    CAST(NULL AS BIGINT) AS publishers,
    CAST(1 AS BIGINT) AS genres,
    CAST(1 AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(share_within_region_era, 4) AS sales_share,
    CAST(NULL AS DOUBLE) AS avg_sales_per_game_platform,
    CAST(NULL AS DOUBLE) AS secondary_value,
    'not_applicable' AS secondary_label,
    'Check whether genre migration differs by region.' AS notes
FROM region_era_genre
WHERE rank_within_region_era = 1
UNION ALL
SELECT
    'era_platform_leaders' AS evidence_block,
    'era_platform' AS grain,
    release_era AS item,
    platform_name AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'rank_within_era' AS rank_label,
    CAST(rank_within_era AS DOUBLE) AS rank_value,
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
    ROUND(share_within_era, 4) AS sales_share,
    CAST(NULL AS DOUBLE) AS avg_sales_per_game_platform,
    CAST(NULL AS DOUBLE) AS secondary_value,
    'not_applicable' AS secondary_label,
    'Use platform leadership to separate genre changes from hardware-cycle effects.' AS notes
FROM era_platform_leader
WHERE rank_within_era <= 3
