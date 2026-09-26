-- silver.nobil_capacity: NOBIL charging-capacity code (attribute type 5) -> kW and current type.
-- Seed from Git (seeds/nobil_capacity.csv): the 30 codes on nobil.no/admin/attributes.php
-- plus 4 codes found only in the data (43, 46, 48, 50), labelled from the API's own 'trans'.
-- kw_basis: stated (label on the reference page) / stated_in_data (label in the API response) /
--           derived (sqrt(3) x 230 V x A, Norwegian IT-grid codes 16-18) / none (no charging power).

CREATE OR REFRESH MATERIALIZED VIEW nobil_capacity (
  CONSTRAINT unique_code        EXPECT (n_rows_code = 1)                                           ON VIOLATION FAIL UPDATE,
  CONSTRAINT valid_code         EXPECT (attrvalid RLIKE '^[0-9]+$')                                ON VIOLATION FAIL UPDATE,
  CONSTRAINT valid_current_type EXPECT (current_type IN ('AC', 'DC', 'H2', 'BIOGAS', 'UNKNOWN'))   ON VIOLATION FAIL UPDATE,
  CONSTRAINT valid_kw_basis     EXPECT (kw_basis IN ('stated', 'stated_in_data', 'derived', 'none')) ON VIOLATION FAIL UPDATE,
  CONSTRAINT charging_has_kw    EXPECT (current_type NOT IN ('AC', 'DC') OR kw > 0)                ON VIOLATION FAIL UPDATE,
  CONSTRAINT non_charging_no_kw EXPECT (current_type IN ('AC', 'DC') OR kw IS NULL)                ON VIOLATION FAIL UPDATE
)
COMMENT 'NOBIL charging-capacity code -> kW and current type (AC/DC/H2/BIOGAS/UNKNOWN). Seed, version-controlled in Git.'
AS SELECT
  attrvalid,
  try_cast(nullif(kw, '') AS DECIMAL(7,2))   AS kw,
  current_type,
  kw_basis,
  nobil_label,
  count(*) OVER (PARTITION BY attrvalid)      AS n_rows_code,
  _file,
  _ingested_at
FROM laddstolpar_df.bronze.seed_nobil_capacity;