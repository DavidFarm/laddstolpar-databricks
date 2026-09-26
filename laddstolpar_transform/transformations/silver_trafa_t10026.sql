-- silver.trafa_t10026: passenger cars in traffic at year-end per kommun, fuel and year (Trafikanalys T10026).
-- AUTO CDC, SCD 2 on the value. Trafikanalys has no "updated" field and bronze _snapshot is the
-- selection slice ('ar=2020-2025'), not a time (finding 49), so the sequence is arrival order (_ingested_at).
-- Omitted zero rows (finding 25) are NOT filled here; the zero-grid fill is a separate MV.

CREATE TEMPORARY VIEW trafa_t10026_clean (
  CONSTRAINT known_kommun   EXPECT (kommun_i_listan)          ON VIOLATION FAIL UPDATE,
  CONSTRAINT known_fuel     EXPECT (drivmedel_i_listan)       ON VIOLATION FAIL UPDATE,
  CONSTRAINT valid_year     EXPECT (ar IS NOT NULL)           ON VIOLATION FAIL UPDATE,
  CONSTRAINT value_present  EXPECT (antal IS NOT NULL)        ON VIOLATION FAIL UPDATE,  -- T10026 has no '..' markers
  CONSTRAINT valid_sequence EXPECT (_ingested_at IS NOT NULL) ON VIOLATION FAIL UPDATE,
  CONSTRAINT not_negative   EXPECT (antal IS NULL OR antal >= 0)
)
AS SELECT
  b.regkom                                  AS kommun_kod,
  b.reglan                                  AS lan_kod,
  b.drivmedel                               AS drivmedel_kod,   -- Trafikanalys' own code; conformed key joined in gold
  b.drivmedel_label                         AS drivmedel_namn,
  try_cast(b.ar AS INT)                     AS ar,
  try_cast(b.itrfslut AS BIGINT)            AS antal,
  b._snapshot,
  b._file,
  b._ingested_at,
  k.kommun_kod IS NOT NULL                  AS kommun_i_listan,
  d.trafa_kod  IS NOT NULL                  AS drivmedel_i_listan   -- ⚠️ column name assumed
FROM STREAM(laddstolpar_df.bronze.trafa_t10026) b
LEFT JOIN laddstolpar_df.silver.kommun    k ON k.kommun_kod = b.regkom
LEFT JOIN laddstolpar_df.silver.drivmedel d ON d.trafa_kod  = b.drivmedel   -- ⚠️
WHERE b.regkom    <> 't1'     -- county totals: kept in bronze for the ops reconciliation (finding 26)
  AND b.drivmedel <> 't1';    -- fuel total: redundant, sum of fuels = t1 (finding 36)

CREATE OR REFRESH STREAMING TABLE trafa_t10026
COMMENT 'Passenger cars in traffic at year-end per kommun, fuel and year (Trafikanalys T10026), Trafikanalys fuel codes. Omitted zero rows not filled. SCD 2 on the value.';

CREATE FLOW trafa_t10026_cdc AS AUTO CDC INTO trafa_t10026
FROM STREAM(trafa_t10026_clean)
KEYS (kommun_kod, drivmedel_kod, ar)
SEQUENCE BY _ingested_at
COLUMNS * EXCEPT (kommun_i_listan, drivmedel_i_listan)
STORED AS SCD TYPE 2
TRACK HISTORY ON * EXCEPT (lan_kod, drivmedel_namn, _snapshot, _file, _ingested_at);