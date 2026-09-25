-- silver.scb_tab3277: new registrations per kommun, fuel type and month (SCB TAB3277).
-- AUTO CDC, SCD 2: SCB revises preliminary months; each new publication is a new snapshot in bronze.
-- History is tracked on the VALUE only, so a republication with unchanged numbers creates no new version.

-- Step 1: clean and filter (pipeline-scoped view, not stored)
CREATE TEMPORARY VIEW scb_tab3277_clean (
  CONSTRAINT known_kommun      EXPECT (kommun_i_listan)               ON VIOLATION FAIL UPDATE,
  CONSTRAINT valid_period      EXPECT (period_start IS NOT NULL)      ON VIOLATION FAIL UPDATE,
  CONSTRAINT valid_sequence    EXPECT (_snapshot_ts IS NOT NULL)      ON VIOLATION FAIL UPDATE,
  CONSTRAINT count_present     EXPECT (antal IS NOT NULL),
  CONSTRAINT count_not_negative EXPECT (antal >= 0)
)
AS SELECT
  b.region                                                   AS kommun_kod,
  b.drivmedel                                                AS drivmedel_scb_kod,
  b.contentscode,
  b.tid                                                      AS period,
  to_date(concat(substr(b.tid, 1, 4), '-', substr(b.tid, 6, 2), '-01')) AS period_start,
  CAST(b.value AS BIGINT)                                    AS antal,
  b.status,
  COALESCE(
    try_to_timestamp(b._snapshot_updated, "yyyy-MM-dd'T'HH:mm:ss'Z'"),   -- ISO form from the SCB API
    try_to_timestamp(b._snapshot_updated, "yyyyMMdd'T'HHmmss'Z'")        -- sanitised form used in landing paths (finding 21)
  )                                                          AS _snapshot_ts,
  b._file,
  b._ingested_at,
  k.kommun_kod IS NOT NULL                                   AS kommun_i_listan
FROM STREAM(laddstolpar_df.bronze.scb_tab3277) b
LEFT JOIN laddstolpar_df.silver.kommun k ON k.kommun_kod = b.region
WHERE length(b.region) = 4          -- kommun level only (drops 00 Riket, the 21 län and former län 15/16)
  AND b.region <> '1917';           -- Heby's retired code, all zeros in our period (finding 22)

-- Step 2: the SCD 2 target
CREATE OR REFRESH STREAMING TABLE scb_tab3277
COMMENT 'New registrations per kommun, SCB fuel code and month (SCB TAB3277). SCD 2 on the value; current rows have __END_AT IS NULL.';

CREATE FLOW scb_tab3277_cdc AS AUTO CDC INTO scb_tab3277
FROM STREAM(scb_tab3277_clean)
KEYS (kommun_kod, drivmedel_scb_kod, contentscode, period)
SEQUENCE BY _snapshot_ts
COLUMNS * EXCEPT (kommun_i_listan)
STORED AS SCD TYPE 2
TRACK HISTORY ON * EXCEPT (status, _snapshot_ts, _file, _ingested_at);