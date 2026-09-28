-- silver.nvdb_trafik_kommun: traffic on state roads per kommun (Trafikverket NVDB dataprodukt Trafik, CC0).
-- Seed from Git (seeds/nvdb_trafik_kommun.csv), produced locally by tools/nvdb_trafik_to_kommun.py:
-- section midpoint -> kommun via SCB RegSO 2025 areas; vehicle-km/day = length x ÅDT, both carriageways
-- summed (findings 69-71). A source fact, not an assumption, so it passes silver like nobil_capacity.

CREATE OR REFRESH MATERIALIZED VIEW nvdb_trafik_kommun (
  CONSTRAINT known_kommun     EXPECT (is_known_kommun)                                        ON VIOLATION FAIL UPDATE,
  CONSTRAINT unique_kommun    EXPECT (n_rows_kommun = 1)                                      ON VIOLATION FAIL UPDATE,
  CONSTRAINT all_kommuner     EXPECT (n_rows_total = n_kommun_ref)                            ON VIOLATION FAIL UPDATE,
  CONSTRAINT values_parsed    EXPECT (COALESCE(n_sections IS NOT NULL AND road_km IS NOT NULL
                                               AND vkm_per_day IS NOT NULL AND vkm_heavy_per_day IS NOT NULL
                                               AND max_adt IS NOT NULL AND vkm_share_measured IS NOT NULL
                                               AND n_sections_no_adt IS NOT NULL, false))    ON VIOLATION FAIL UPDATE,
  CONSTRAINT not_negative     EXPECT (COALESCE(n_sections >= 0 AND road_km >= 0 AND vkm_per_day >= 0
                                               AND vkm_heavy_per_day >= 0 AND max_adt >= 0, false)) ON VIOLATION FAIL UPDATE,
  CONSTRAINT share_in_range   EXPECT (COALESCE(vkm_share_measured BETWEEN 0 AND 1, false))    ON VIOLATION FAIL UPDATE,
  CONSTRAINT one_betraktelse  EXPECT (COALESCE(same_betraktelse, false))                      ON VIOLATION FAIL UPDATE,
  CONSTRAINT heavy_within_all EXPECT (COALESCE(vkm_heavy_per_day <= vkm_per_day, false)),
  CONSTRAINT name_matches     EXPECT (COALESCE(kommun_namn = ref_kommun_namn, false)),
  CONSTRAINT has_state_road   EXPECT (n_sections > 0)       -- warn: expected 1 (Sundbyberg, finding 71)
)
COMMENT 'State-road traffic per kommun: sections, road km, vehicle-km/day (all + heavy), max ÅDT, measured share, weighted measurement year. NVDB Trafik via local preprocessing, CC0.'
AS
WITH src AS (
  SELECT
    kommun_kod,
    kommun_namn,
    try_cast(n_sections         AS INT)             AS n_sections,
    try_cast(road_km            AS DECIMAL(12,3))   AS road_km,
    try_cast(vkm_per_day        AS DECIMAL(14,1))   AS vkm_per_day,
    try_cast(vkm_heavy_per_day  AS DECIMAL(14,1))   AS vkm_heavy_per_day,
    try_cast(max_adt            AS INT)             AS max_adt,
    try_cast(vkm_share_measured AS DECIMAL(6,4))    AS vkm_share_measured,
    NULLIF(try_cast(vkm_weighted_year AS DECIMAL(6,1)), 0) AS vkm_weighted_year,  -- the script writes 0 where there is no traffic
    try_cast(n_sections_no_adt  AS INT)             AS n_sections_no_adt,
    try_cast(betraktelsedatum   AS DATE)            AS betraktelsedatum,
    _file,
    _ingested_at
  FROM laddstolpar_df.bronze.seed_nvdb_trafik_kommun
)
SELECT
  s.*,
  k.kommun_namn                                                        AS ref_kommun_namn,
  k.kommun_kod IS NOT NULL                                             AS is_known_kommun,
  COUNT(*) OVER (PARTITION BY s.kommun_kod)                            AS n_rows_kommun,
  COUNT(*) OVER ()                                                     AS n_rows_total,
  r.n_kommun_ref,
  MIN(s.betraktelsedatum) OVER () = MAX(s.betraktelsedatum) OVER ()   AS same_betraktelse
FROM src s
LEFT JOIN silver.kommun k ON k.kommun_kod = s.kommun_kod
CROSS JOIN (SELECT COUNT(*) AS n_kommun_ref FROM silver.kommun) r;