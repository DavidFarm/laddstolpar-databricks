-- silver.scb_tab3276: passenger cars in traffic per kommun, owner category and year (SCB TAB3276).
-- AUTO CDC, SCD 2 on the value. Category 040 (taxi) has suppressed cells ('..' -> NULL + status, finding 24).

CREATE TEMPORARY VIEW scb_tab3276_clean (
  CONSTRAINT known_kommun      EXPECT (kommun_i_listan)                         ON VIOLATION FAIL UPDATE,
  CONSTRAINT known_category    EXPECT (kategori IS NOT NULL)                    ON VIOLATION FAIL UPDATE,
  CONSTRAINT valid_sequence    EXPECT (_snapshot_ts IS NOT NULL)                ON VIOLATION FAIL UPDATE,
  CONSTRAINT missing_is_marked EXPECT (antal IS NOT NULL OR status IS NOT NULL),
  CONSTRAINT not_negative      EXPECT (antal IS NULL OR antal >= 0)
)
AS SELECT
  b.region                                           AS kommun_kod,
  b.agarkategori,
  CASE b.agarkategori
    WHEN '000' THEN 'totalt'
    WHEN '010' THEN 'kvinnor'
    WHEN '020' THEN 'man'
    WHEN '030' THEN 'juridisk_person'               -- company cars (flag in gold, finding 24)
    WHEN '040' THEN 'taxi'
    WHEN '050' THEN 'fysiska_personer_per_1000_inv'
    WHEN '060' THEN 'totalt_per_1000_inv'
  END                                                AS kategori,
  CASE WHEN b.agarkategori IN ('050', '060') THEN 'per_1000_inv' ELSE 'antal' END AS enhet,
  b.contentscode,
  CAST(b.tid AS INT)                                 AS ar,
  CAST(b.value AS BIGINT)                            AS antal,
  b.status,
  COALESCE(
    try_to_timestamp(b._snapshot_updated, "yyyy-MM-dd'T'HH:mm:ss'Z'"),
    try_to_timestamp(b._snapshot_updated, "yyyyMMdd'T'HHmmss'Z'")
  )                                                  AS _snapshot_ts,
  b._file,
  b._ingested_at,
  k.kommun_kod IS NOT NULL                           AS kommun_i_listan
FROM STREAM(laddstolpar_df.bronze.scb_tab3276) b
LEFT JOIN laddstolpar_df.silver.kommun k ON k.kommun_kod = b.region
WHERE length(b.region) = 4
  AND b.region <> '1917';            -- Heby's retired code, all '..' here (finding 24)

CREATE OR REFRESH STREAMING TABLE scb_tab3276
COMMENT 'Passenger cars in traffic per kommun, owner category and year (SCB TAB3276), long format. SCD 2 on the value.';

CREATE FLOW scb_tab3276_cdc AS AUTO CDC INTO scb_tab3276
FROM STREAM(scb_tab3276_clean)
KEYS (kommun_kod, agarkategori, contentscode, ar)
SEQUENCE BY _snapshot_ts
COLUMNS * EXCEPT (kommun_i_listan)
STORED AS SCD TYPE 2
TRACK HISTORY ON * EXCEPT (status, _snapshot_ts, _file, _ingested_at);