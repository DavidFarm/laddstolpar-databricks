-- silver.scb_tab628: population, land area and density per kommun and year (SCB TAB628).
-- AUTO CDC, SCD 2 on the value. Long format: one row per kommun x measure x year; pivot happens in gold.

CREATE TEMPORARY VIEW scb_tab628_clean (
  CONSTRAINT known_kommun      EXPECT (kommun_i_listan)                         ON VIOLATION FAIL UPDATE,
  CONSTRAINT known_measure     EXPECT (matt IS NOT NULL)                        ON VIOLATION FAIL UPDATE,
  CONSTRAINT valid_sequence    EXPECT (_snapshot_ts IS NOT NULL)                ON VIOLATION FAIL UPDATE,
  CONSTRAINT missing_is_marked EXPECT (varde IS NOT NULL OR status IS NOT NULL),
  CONSTRAINT not_negative      EXPECT (varde IS NULL OR varde >= 0)
)
AS SELECT
  b.region                                           AS kommun_kod,
  b.kon,
  b.contentscode,
  CASE b.contentscode
    WHEN 'BE0101U2' THEN 'folkmangd'                 -- population 31 Dec
    WHEN 'BE0101U3' THEN 'landareal_km2'             -- land area 1 Jan the following year
    WHEN 'BE0101U1' THEN 'invanare_per_km2'          -- ratio, not additive
  END                                                AS matt,
  CAST(b.tid AS INT)                                 AS ar,
  CAST(b.value AS DECIMAL(18,2))                     AS varde,
  b.status,
  COALESCE(
    try_to_timestamp(b._snapshot_updated, "yyyy-MM-dd'T'HH:mm:ss'Z'"),
    try_to_timestamp(b._snapshot_updated, "yyyyMMdd'T'HHmmss'Z'")
  )                                                  AS _snapshot_ts,
  b._file,
  b._ingested_at,
  k.kommun_kod IS NOT NULL                           AS kommun_i_listan
FROM STREAM(laddstolpar_df.bronze.scb_tab628) b
LEFT JOIN laddstolpar_df.silver.kommun k ON k.kommun_kod = b.region
WHERE length(b.region) = 4;          -- kommun level only (TAB628 has no retired codes, finding 22)

CREATE OR REFRESH STREAMING TABLE scb_tab628
COMMENT 'Population, land area and density per kommun and year (SCB TAB628), long format. SCD 2 on the value.';

CREATE FLOW scb_tab628_cdc AS AUTO CDC INTO scb_tab628
FROM STREAM(scb_tab628_clean)
KEYS (kommun_kod, kon, contentscode, ar)
SEQUENCE BY _snapshot_ts
COLUMNS * EXCEPT (kommun_i_listan)
STORED AS SCD TYPE 2
TRACK HISTORY ON * EXCEPT (status, _snapshot_ts, _file, _ingested_at);