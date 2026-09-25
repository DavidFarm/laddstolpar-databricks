-- silver.drivmedel: conformed fuel type with each source's code (design section 3, finding 36).
-- Mapping from the Git seed; labels from Trafikanalys (SCB bronze keeps codes only).
-- Every seed code must exist in its source table, so a typo stops the update.

CREATE OR REFRESH MATERIALIZED VIEW drivmedel (
  CONSTRAINT scb_code_in_source   EXPECT (scb_kod_in_source)            ON VIOLATION FAIL UPDATE,
  CONSTRAINT trafa_code_in_source EXPECT (drivmedel_namn IS NOT NULL)   ON VIOLATION FAIL UPDATE,
  CONSTRAINT known_laddbar        EXPECT (laddbar IS NOT NULL)          ON VIOLATION FAIL UPDATE
)
COMMENT 'Conformed fuel types (BEV, PHEV, HEV, BENSIN, DIESEL, ETANOL, GAS, OVRIGT) mapped to SCB TAB3277 and Trafikanalys T10026 codes.'
AS
WITH m AS (
  SELECT * FROM laddstolpar_df.bronze.seed_drivmedel_map
  QUALIFY ROW_NUMBER() OVER (PARTITION BY drivmedel ORDER BY _ingested_at DESC) = 1
),
scb AS (
  SELECT DISTINCT drivmedel AS scb_kod FROM laddstolpar_df.bronze.scb_tab3277
),
trafa AS (
  SELECT drivmedel AS trafa_kod, MAX(drivmedel_label) AS trafa_label
  FROM laddstolpar_df.bronze.trafa_t10026
  GROUP BY drivmedel
)
SELECT
  m.drivmedel,
  t.trafa_label                                   AS drivmedel_namn,
  m.scb_kod,
  m.trafa_kod,
  CASE lower(trim(m.laddbar)) WHEN 'true' THEN true WHEN 'false' THEN false END AS laddbar,
  s.scb_kod IS NOT NULL                           AS scb_kod_in_source
FROM m
LEFT JOIN scb   s ON s.scb_kod   = m.scb_kod
LEFT JOIN trafa t ON t.trafa_kod = m.trafa_kod;