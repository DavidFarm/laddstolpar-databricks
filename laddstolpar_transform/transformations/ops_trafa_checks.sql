-- ops.trafa_lan_check: T10026 sum over kommuner vs the county total (regkom 't1'), per county, fuel and year.
-- County totals are read from bronze (silver drops them, finding 26); latest arrival wins, as in silver.
-- Kommun side from the zero-filled grid, so omitted rows count as 0 (finding 25).

CREATE OR REFRESH MATERIALIZED VIEW laddstolpar_df.ops.trafa_lan_check (
  CONSTRAINT county_total_present EXPECT (lan_total IS NOT NULL),
  CONSTRAINT exact_sum            EXPECT (COALESCE(diff = 0, false))
)
COMMENT 'Reconciliation: T10026 sum over kommuner vs county total (regkom t1) per county, fuel and year.'
AS
WITH kommun_sum AS (
  SELECT k.lan_kod, g.drivmedel_kod, g.ar,
         count(*)     AS n_kommuner,
         sum(g.antal) AS sum_kommuner
  FROM laddstolpar_df.silver.trafa_t10026_grid g
  JOIN laddstolpar_df.silver.kommun k USING (kommun_kod)
  GROUP BY ALL
),
lan_total AS (
  SELECT reglan                                          AS lan_kod,
         drivmedel                                       AS drivmedel_kod,
         CAST(ar AS INT)                                 AS ar,
         CAST(max_by(itrfslut, _ingested_at) AS BIGINT)  AS lan_total
  FROM laddstolpar_df.bronze.trafa_t10026
  WHERE regkom = 't1' AND drivmedel <> 't1'
  GROUP BY ALL
)
SELECT s.lan_kod, s.drivmedel_kod, s.ar, s.n_kommuner,
       s.sum_kommuner, l.lan_total,
       s.sum_kommuner - l.lan_total AS diff
FROM kommun_sum s
LEFT JOIN lan_total l USING (lan_kod, drivmedel_kod, ar);


-- ops.trafa_scb_cars_check: cross-source. Passenger cars in traffic per kommun and year:
-- Trafikanalys T10026 (sum of fuels, finding 36) vs SCB TAB3276 owner category 'totalt'.
-- Same register (Trafikanalys is responsible for both), so they should agree.

CREATE OR REFRESH MATERIALIZED VIEW laddstolpar_df.ops.trafa_scb_cars_check (
  CONSTRAINT both_present  EXPECT (trafa_totalt IS NOT NULL AND scb_totalt IS NOT NULL),
  CONSTRAINT same_register EXPECT (COALESCE(diff = 0, false))
)
COMMENT 'Cross-source: passenger cars in traffic per kommun and year, T10026 (sum of fuels) vs TAB3276 (totalt). Same register.'
AS
WITH trafa AS (
  SELECT kommun_kod, ar, sum(antal) AS trafa_totalt
  FROM laddstolpar_df.silver.trafa_t10026_grid
  GROUP BY ALL
),
scb AS (
  SELECT kommun_kod, ar, antal AS scb_totalt
  FROM laddstolpar_df.silver.scb_tab3276
  WHERE __END_AT IS NULL AND agarkategori = '000'
)
SELECT kommun_kod, ar, trafa_totalt, scb_totalt,
       trafa_totalt - scb_totalt AS diff
FROM trafa
FULL OUTER JOIN scb USING (kommun_kod, ar);