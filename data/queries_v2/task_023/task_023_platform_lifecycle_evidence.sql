-- task_023_platform_lifecycle_evidence.sql
-- Evidence SQL for task_023.
-- Public query: How do platform lifecycles shape reported sales, and do high-release years line up with high-sales years?
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
year_total AS (
    SELECT
        release_year,
        COUNT(DISTINCT game_key) AS games,
        COUNT(DISTINCT game_platform_key) AS game_platforms,
        COUNT(DISTINCT platform_name) AS platforms,
        COUNT(DISTINCT publisher_name) AS publishers,
        SUM(reported_sales_volume) AS sales
    FROM base_fact
    WHERE release_year IS NOT NULL
    GROUP BY release_year
),
year_ranked AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY sales DESC, release_year) AS sales_rank
    FROM year_total
),
platform_year AS (
    SELECT
        platform_name,
        release_year,
        COUNT(DISTINCT game_key) AS games,
        COUNT(DISTINCT game_platform_key) AS game_platforms,
        SUM(reported_sales_volume) AS sales
    FROM base_fact
    WHERE release_year IS NOT NULL
    GROUP BY platform_name, release_year
),
platform_total AS (
    SELECT
        platform_name,
        MIN(release_year) AS start_year,
        MAX(release_year) AS end_year,
        COUNT(DISTINCT game_key) AS games,
        COUNT(DISTINCT game_platform_key) AS game_platforms,
        SUM(reported_sales_volume) AS sales,
        ROW_NUMBER() OVER (ORDER BY SUM(reported_sales_volume) DESC, platform_name) AS platform_sales_rank
    FROM base_fact
    WHERE release_year IS NOT NULL
    GROUP BY platform_name
),
platform_peak_sales AS (
    SELECT
        platform_name,
        release_year AS peak_sales_year,
        sales AS peak_year_sales
    FROM platform_year
    QUALIFY ROW_NUMBER() OVER (PARTITION BY platform_name ORDER BY sales DESC, release_year) = 1
),
platform_peak_supply AS (
    SELECT
        platform_name,
        release_year AS peak_release_count_year,
        game_platforms AS peak_year_game_platforms
    FROM platform_year
    QUALIFY ROW_NUMBER() OVER (PARTITION BY platform_name ORDER BY game_platforms DESC, release_year) = 1
),
platform_lifecycle AS (
    SELECT
        pt.platform_name,
        pt.start_year,
        pt.end_year,
        pt.games,
        pt.game_platforms,
        pt.sales,
        pt.platform_sales_rank,
        ps.peak_sales_year,
        ps.peak_year_sales,
        pc.peak_release_count_year,
        pc.peak_year_game_platforms,
        CASE WHEN ps.peak_sales_year = pc.peak_release_count_year THEN 1 ELSE 0 END AS peak_year_matches
    FROM platform_total AS pt
    JOIN platform_peak_sales AS ps
      ON pt.platform_name = ps.platform_name
    JOIN platform_peak_supply AS pc
      ON pt.platform_name = pc.platform_name
),
platform_phase AS (
    SELECT
        py.platform_name,
        CASE
            WHEN pt.start_year = pt.end_year THEN 'single_year'
            WHEN py.release_year <= pt.start_year + (pt.end_year - pt.start_year) / 3.0 THEN 'early_phase'
            WHEN py.release_year <= pt.start_year + 2 * (pt.end_year - pt.start_year) / 3.0 THEN 'middle_phase'
            ELSE 'late_phase'
        END AS lifecycle_phase,
        COUNT(DISTINCT py.release_year) AS years,
        SUM(py.game_platforms) AS game_platforms,
        SUM(py.sales) AS sales
    FROM platform_year AS py
    JOIN platform_total AS pt
      ON py.platform_name = pt.platform_name
    GROUP BY py.platform_name, lifecycle_phase
),
selected_phase AS (
    SELECT pp.*, pt.sales AS platform_sales, pt.platform_sales_rank
    FROM platform_phase AS pp
    JOIN platform_total AS pt
      ON pp.platform_name = pt.platform_name
    WHERE pt.platform_sales_rank <= 10
),
decade_region AS (
    SELECT
        CASE
            WHEN release_year < 1990 THEN 'pre_1990'
            WHEN release_year < 2000 THEN '1990s'
            WHEN release_year < 2010 THEN '2000s'
            ELSE '2010s_plus'
        END AS release_era,
        region_name,
        COUNT(DISTINCT game_platform_key) AS game_platforms,
        COUNT(DISTINCT platform_name) AS platforms,
        SUM(reported_sales_volume) AS sales
    FROM base_fact
    WHERE release_year IS NOT NULL
    GROUP BY release_era, region_name
)
SELECT
    'release_year_market_baseline' AS evidence_block,
    'release_year' AS grain,
    CAST(release_year AS VARCHAR) AS item,
    CAST(NULL AS VARCHAR) AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'release_year_sales_rank' AS rank_label,
    CAST(sales_rank AS DOUBLE) AS rank_value,
    CAST(release_year AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(games AS BIGINT) AS games,
    CAST(game_platforms AS BIGINT) AS game_platforms,
    CAST(platforms AS BIGINT) AS platforms,
    CAST(publishers AS BIGINT) AS publishers,
    CAST(NULL AS BIGINT) AS genres,
    CAST(NULL AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(sales / NULLIF((SELECT total_sales FROM total_sales), 0), 4) AS sales_share,
    ROUND(sales / NULLIF(game_platforms, 0), 4) AS avg_sales_per_game_platform,
    ROUND(game_platforms / NULLIF(games, 0), 4) AS secondary_value,
    'platform_versions_per_game' AS secondary_label,
    'Year-level baseline distinguishes release supply from sales conversion.' AS notes
FROM year_ranked
WHERE sales_rank <= 15
UNION ALL
SELECT
    'platform_lifecycle_summary' AS evidence_block,
    'platform' AS grain,
    platform_name AS item,
    CAST(peak_sales_year AS VARCHAR) AS item_2,
    CAST(peak_release_count_year AS VARCHAR) AS item_3,
    'platform_sales_rank' AS rank_label,
    CAST(platform_sales_rank AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(start_year AS BIGINT) AS start_year,
    CAST(end_year AS BIGINT) AS end_year,
    CAST(games AS BIGINT) AS games,
    CAST(game_platforms AS BIGINT) AS game_platforms,
    CAST(1 AS BIGINT) AS platforms,
    CAST(NULL AS BIGINT) AS publishers,
    CAST(NULL AS BIGINT) AS genres,
    CAST(NULL AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(sales / NULLIF((SELECT total_sales FROM total_sales), 0), 4) AS sales_share,
    ROUND(sales / NULLIF(game_platforms, 0), 4) AS avg_sales_per_game_platform,
    CAST(peak_year_matches AS DOUBLE) AS secondary_value,
    'peak_sales_year_matches_peak_release_count_year' AS secondary_label,
    'Platform lifecycle needs both sales peak and release-count peak; they need not match.' AS notes
FROM platform_lifecycle
WHERE platform_sales_rank <= 15
UNION ALL
SELECT
    'selected_platform_phase_profile' AS evidence_block,
    'platform_phase' AS grain,
    platform_name AS item,
    lifecycle_phase AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'platform_sales_rank' AS rank_label,
    CAST(platform_sales_rank AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(NULL AS BIGINT) AS games,
    CAST(game_platforms AS BIGINT) AS game_platforms,
    CAST(1 AS BIGINT) AS platforms,
    CAST(NULL AS BIGINT) AS publishers,
    CAST(NULL AS BIGINT) AS genres,
    CAST(NULL AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(sales / NULLIF(platform_sales, 0), 4) AS sales_share,
    ROUND(sales / NULLIF(game_platforms, 0), 4) AS avg_sales_per_game_platform,
    CAST(years AS DOUBLE) AS secondary_value,
    'years_in_phase' AS secondary_label,
    'Phase rows show whether platform sales are concentrated early, middle, or late in its release span.' AS notes
FROM selected_phase
UNION ALL
SELECT
    'release_era_region_mix' AS evidence_block,
    'release_era_region' AS grain,
    release_era AS item,
    region_name AS item_2,
    CAST(NULL AS VARCHAR) AS item_3,
    'era_region_sales_rank' AS rank_label,
    CAST(ROW_NUMBER() OVER (PARTITION BY release_era ORDER BY sales DESC, region_name) AS DOUBLE) AS rank_value,
    CAST(NULL AS BIGINT) AS release_year,
    CAST(NULL AS BIGINT) AS start_year,
    CAST(NULL AS BIGINT) AS end_year,
    CAST(NULL AS BIGINT) AS games,
    CAST(game_platforms AS BIGINT) AS game_platforms,
    CAST(platforms AS BIGINT) AS platforms,
    CAST(NULL AS BIGINT) AS publishers,
    CAST(NULL AS BIGINT) AS genres,
    CAST(1 AS BIGINT) AS regions,
    ROUND(sales, 4) AS reported_sales_volume,
    ROUND(sales / NULLIF(SUM(sales) OVER (PARTITION BY release_era), 0), 4) AS sales_share,
    ROUND(sales / NULLIF(game_platforms, 0), 4) AS avg_sales_per_game_platform,
    CAST(NULL AS DOUBLE) AS secondary_value,
    'not_applicable' AS secondary_label,
    'Era-by-region rows support trend claims without reducing platform lifecycle to a single global year.' AS notes
FROM decade_region;
