-- silver.kommun: one row per kommun (290), conformed from three seeds.
-- Facts about the kommun only; assumptions (cost factor, tourist flag) belong in gold.
-- Price zone = kommun override if checked one by one, else the county default (design findings 27-28).

CREATE OR REFRESH MATERIALIZED VIEW kommun (
  CONSTRAINT valid_kommun_kod    EXPECT (kommun_kod RLIKE '^[0-9]{4}$')             ON VIOLATION FAIL UPDATE,
  CONSTRAINT lan_found           EXPECT (lan_namn IS NOT NULL)                       ON VIOLATION FAIL UPDATE,
  CONSTRAINT zone_assigned       EXPECT (elomrade IN ('SE1','SE2','SE3','SE4'))      ON VIOLATION FAIL UPDATE,
  CONSTRAINT kommungrupp_present EXPECT (kommungrupp IS NOT NULL)                    ON VIOLATION FAIL UPDATE,
  CONSTRAINT known_split_flag    EXPECT (elomrade_is_split IS NOT NULL)              ON VIOLATION FAIL UPDATE,
  -- Observation: split kommuner whose primary zone is not yet sourced
  CONSTRAINT zone_reviewed       EXPECT (NOT elomrade_needs_review)
)
COMMENT 'Conformed kommun list: SKR kommungrupp 2023 + price zone (county default, kommun override). One row per kommun.'
AS
WITH skr AS (
  SELECT * FROM laddstolpar_df.bronze.seed_skr_kommungrupp
  QUALIFY ROW_NUMBER() OVER (PARTITION BY kommun_kod ORDER BY _ingested_at DESC) = 1
),
lan AS (
  SELECT * FROM laddstolpar_df.bronze.seed_elomrade_lan_default
  QUALIFY ROW_NUMBER() OVER (PARTITION BY lan_kod ORDER BY _ingested_at DESC) = 1
),
ovr AS (
  SELECT * FROM laddstolpar_df.bronze.seed_elomrade_kommun_override
  QUALIFY ROW_NUMBER() OVER (PARTITION BY kommun_kod ORDER BY _ingested_at DESC) = 1
)
SELECT
  s.kommun_kod,
  s.kommun_namn,
  substr(s.kommun_kod, 1, 2)                            AS lan_kod,
  l.lan_namn,
  s.gruppkod,
  s.huvudgrupp,
  s.kommungrupp,
  COALESCE(o.elomrade_primary, l.elomrade_default)      AS elomrade,
  o.elomrade_secondary,
  CASE
    WHEN o.kommun_kod IS NULL                                        THEN false
    WHEN lower(trim(o.is_split)) IN ('true','1','yes','ja','y','j')  THEN true
    WHEN lower(trim(o.is_split)) IN ('false','0','no','nej','n','')
         OR o.is_split IS NULL                                        THEN false
  END                                                   AS elomrade_is_split,
  COALESCE(upper(concat_ws(' ', o.primary_basis, o.note)) LIKE '%NEEDS REVIEW%', false)
                                                        AS elomrade_needs_review,
  CASE WHEN o.kommun_kod IS NOT NULL THEN 'kommun_override' ELSE 'lan_default' END
                                                        AS elomrade_level,
  COALESCE(o.primary_basis, l.basis)                    AS elomrade_basis,
  COALESCE(o.source, l.source)                          AS elomrade_source
FROM skr s
LEFT JOIN lan l ON l.lan_kod    = substr(s.kommun_kod, 1, 2)
LEFT JOIN ovr o ON o.kommun_kod = s.kommun_kod;