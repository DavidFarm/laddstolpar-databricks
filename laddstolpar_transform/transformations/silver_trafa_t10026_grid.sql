-- silver.trafa_t10026_grid: complete kommun × fuel × year grid for T10026.
-- Trafikanalys omits rows instead of sending zeros (finding 25): 412 of 13,920 kommun rows.
-- Missing combinations are filled with 0 and flagged, so sums and completeness checks are correct.
-- Reads current SCD 2 rows only.

CREATE OR REFRESH MATERIALIZED VIEW trafa_t10026_grid (
  CONSTRAINT antal_present EXPECT (antal IS NOT NULL) ON VIOLATION FAIL UPDATE
)
COMMENT 'Passenger cars in traffic at year-end per kommun, fuel and year (T10026), complete grid: omitted rows filled with 0 and flagged.'
AS
WITH cur AS (
  SELECT kommun_kod, drivmedel_kod, ar, antal
  FROM laddstolpar_df.silver.trafa_t10026
  WHERE __END_AT IS NULL
),
grid AS (
  SELECT k.kommun_kod, d.trafa_kod AS drivmedel_kod, y.ar
  FROM laddstolpar_df.silver.kommun k
  CROSS JOIN laddstolpar_df.silver.drivmedel d
  CROSS JOIN (SELECT DISTINCT ar FROM cur) y
)
SELECT
  g.kommun_kod,
  g.drivmedel_kod,
  g.ar,
  COALESCE(c.antal, 0) AS antal,
  c.antal IS NULL      AS is_filled_zero
FROM grid g
LEFT JOIN cur c USING (kommun_kod, drivmedel_kod, ar);