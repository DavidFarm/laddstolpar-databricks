-- silver.elpris: one row per price zone and quarter-hour.
-- Source: bronze.elpris (append-only, one file = one zone x one local day).
-- Negative prices are valid market prices and are deliberately NOT filtered.
-- time_end_utc is derived (start + 15 min): the source's time_end is wrong at the
-- DST fall-back 2025-10-26 (design finding 37); the source value is kept for audit.

CREATE OR REFRESH STREAMING TABLE elpris (
  -- Structural: if these fail, ingestion is broken -> stop the update
  CONSTRAINT valid_zone            EXPECT (elomrade IN ('SE1','SE2','SE3','SE4')) ON VIOLATION FAIL UPDATE,
  CONSTRAINT valid_timestamps      EXPECT (time_start_utc IS NOT NULL AND time_end_utc IS NOT NULL) ON VIOLATION FAIL UPDATE,
  -- Unusable row: drop it, the pass rate shows how many
  CONSTRAINT price_present         EXPECT (sek_per_kwh IS NOT NULL) ON VIOLATION DROP ROW,
  -- Observations: keep the row, record the pass rate as evidence
  CONSTRAINT source_end_consistent EXPECT (time_end_source_utc = time_end_utc),
  CONSTRAINT plausible_price       EXPECT (sek_per_kwh BETWEEN -10 AND 50)
)
COMMENT 'Spot price per zone and quarter-hour, excl. VAT, fees and taxes (Elpriset just nu). Timestamps in UTC.'
AS SELECT
  elomrade,
  CAST(time_start AS TIMESTAMP)                        AS time_start_utc,
  CAST(time_start AS TIMESTAMP) + INTERVAL 15 MINUTES  AS time_end_utc,         -- derived: window is all quarter-hour
  CAST(time_end   AS TIMESTAMP)                        AS time_end_source_utc,  -- kept for audit
  CAST(substr(time_start, 1, 10) AS DATE)              AS datum_lokal,
  CAST(SEK_per_kWh AS DECIMAL(10,5))                   AS sek_per_kwh,
  CAST(EUR_per_kWh AS DECIMAL(10,5))                   AS eur_per_kwh,
  CAST(EXR AS DECIMAL(10,5))                           AS exr,
  _file,
  _ingested_at
FROM STREAM(laddstolpar_df.bronze.elpris);