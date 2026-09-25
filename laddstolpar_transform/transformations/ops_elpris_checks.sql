-- ops.elpris_day_check: one row per zone and local day in the price window.
-- Built on a date spine so that a MISSING day shows up as a row with n_rows = 0.
-- expected_rows comes from the length of the local day (Europe/Stockholm): 92/96/100.

CREATE OR REFRESH MATERIALIZED VIEW laddstolpar_df.ops.elpris_day_check (
  -- Duplicates break the "re-runnable without duplicates" requirement -> stop the update
  CONSTRAINT no_duplicate_quarter EXPECT (n_rows = n_distinct_starts) ON VIOLATION FAIL UPDATE,
  -- A missing or short day is an observation: keep going, record the pass rate
  CONSTRAINT day_complete         EXPECT (n_rows = expected_rows)
)
COMMENT 'Day-level quality check for silver.elpris: completeness (DST-aware) and uniqueness per zone and local day.'
AS
WITH bounds AS (
  SELECT MIN(datum_lokal) AS d0, MAX(datum_lokal) AS d1
  FROM laddstolpar_df.silver.elpris
),
spine AS (
  SELECT z.elomrade, d.datum_lokal
  FROM (SELECT explode(sequence(d0, d1, INTERVAL 1 DAY)) AS datum_lokal FROM bounds) d
  CROSS JOIN (VALUES ('SE1'), ('SE2'), ('SE3'), ('SE4')) AS z(elomrade)
),
agg AS (
  SELECT elomrade, datum_lokal,
         COUNT(*)                                        AS n_rows,
         COUNT(DISTINCT time_start_utc)                  AS n_distinct_starts,
         SUM(CASE WHEN sek_per_kwh < 0 THEN 1 ELSE 0 END) AS n_negative
  FROM laddstolpar_df.silver.elpris
  GROUP BY elomrade, datum_lokal
)
SELECT
  s.elomrade,
  s.datum_lokal,
  CAST((unix_timestamp(to_utc_timestamp(CAST(date_add(s.datum_lokal, 1) AS TIMESTAMP), 'Europe/Stockholm'))
      - unix_timestamp(to_utc_timestamp(CAST(s.datum_lokal AS TIMESTAMP), 'Europe/Stockholm'))) / 900 AS INT)
                                        AS expected_rows,
  COALESCE(a.n_rows, 0)                 AS n_rows,
  COALESCE(a.n_distinct_starts, 0)      AS n_distinct_starts,
  COALESCE(a.n_negative, 0)             AS n_negative
FROM spine s
LEFT JOIN agg a USING (elomrade, datum_lokal);