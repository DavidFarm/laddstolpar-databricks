-- gold_dims.sql
-- Conformed dimensions for the gold star schema (design §3).
-- Dimensions hold facts; assumptions (cost factor, weights) live in gold param tables.

-- 1. Kommun: one row per kommun (290)
CREATE OR REFRESH MATERIALIZED VIEW gold.dim_kommun (
  CONSTRAINT valid_kommun_kod EXPECT (kommun_kod RLIKE '^[0-9]{4}$')             ON VIOLATION FAIL UPDATE,
  CONSTRAINT valid_zone       EXPECT (elomrade IN ('SE1', 'SE2', 'SE3', 'SE4'))  ON VIOLATION FAIL UPDATE,
  CONSTRAINT group_present    EXPECT (gruppkod IS NOT NULL)                      ON VIOLATION FAIL UPDATE
)
COMMENT 'Kommun dimension, one row per kommun. Price zone incl. secondary zone for split kommuner; SKR kommungrupp 2023.'
AS
SELECT
  kommun_kod,
  kommun_namn,
  lan_kod,
  lan_namn,
  gruppkod,
  huvudgrupp,
  kommungrupp,
  gruppkod = 'C9'     AS is_besoksnaring,     -- SKR "Landsbygdskommun med besöksnäring" = tourist flag (finding 12)
  elomrade,
  elomrade_secondary,                        -- only the 13 split kommuner; used by the zone sensitivity run
  elomrade_is_split,
  elomrade_level,
  elomrade_basis,
  elomrade_source
FROM silver.kommun;

-- 2. Price zone: SE1–SE4. Every zone used anywhere in silver must get a name, or the update fails.
CREATE OR REFRESH MATERIALIZED VIEW gold.dim_elomrade (
  CONSTRAINT zone_named EXPECT (elomrade_namn IS NOT NULL) ON VIOLATION FAIL UPDATE
)
COMMENT 'Price zone dimension. Zones are taken from the data; names from Svenska kraftnät''s naming (Luleå/Sundsvall/Stockholm/Malmö).'
AS
WITH used AS (
  SELECT elomrade FROM silver.kommun
  UNION
  SELECT elomrade_secondary FROM silver.kommun WHERE elomrade_secondary IS NOT NULL
  UNION
  SELECT elomrade FROM silver.elpris
)
SELECT u.elomrade, n.elomrade_namn, n.zon_nr
FROM used u
LEFT JOIN (
  SELECT * FROM VALUES
    ('SE1', 'Luleå', 1), ('SE2', 'Sundsvall', 2), ('SE3', 'Stockholm', 3), ('SE4', 'Malmö', 4)
    AS t(elomrade, elomrade_namn, zon_nr)
) n USING (elomrade);

-- 3. Fuel: conformed key with both source codes
CREATE OR REFRESH MATERIALIZED VIEW gold.dim_drivmedel (
  CONSTRAINT both_codes EXPECT (scb_kod IS NOT NULL AND trafa_kod IS NOT NULL) ON VIOLATION FAIL UPDATE
)
COMMENT 'Fuel dimension: conformed key (BEV, PHEV …) with the SCB TAB3277 code and the Trafikanalys T10026 code.'
AS
SELECT drivmedel, drivmedel_namn, scb_kod, trafa_kod, laddbar
FROM silver.drivmedel;

-- 4. Calendar: one row per day, from the first fleet year to the last price day (both taken from the data)
CREATE OR REFRESH MATERIALIZED VIEW gold.dim_datum (
  CONSTRAINT date_present EXPECT (datum IS NOT NULL) ON VIOLATION FAIL UPDATE
)
COMMENT 'Calendar dimension. scb_period (2025M10) joins TAB3277; ar joins yearly facts; datum joins daily prices.'
AS
WITH bounds AS (
  SELECT
    make_date((SELECT MIN(ar) FROM silver.trafa_t10026_grid), 1, 1) AS d0,
    (SELECT MAX(datum_lokal) FROM silver.elpris)                     AS d1
),
spine AS (
  SELECT explode(sequence(d0, d1, INTERVAL 1 DAY)) AS d FROM bounds
)
SELECT
  d                                                  AS datum,
  year(d)                                            AS ar,
  quarter(d)                                         AS kvartal,
  month(d)                                           AS manad,
  trunc(d, 'MM')                                     AS manad_start,
  date_format(d, 'yyyy-MM')                          AS ar_manad,
  concat(year(d), 'M', lpad(month(d), 2, '0'))       AS scb_period,
  weekofyear(d)                                      AS iso_vecka,
  extract(DAYOFWEEK_ISO FROM d)                      AS veckodag_iso,   -- 1 = Monday … 7 = Sunday
  extract(DAYOFWEEK_ISO FROM d) >= 6                 AS is_helg,
  CASE WHEN month(d) IN (12, 1, 2) THEN 'vinter'
       WHEN month(d) IN (3, 4, 5)  THEN 'vår'
       WHEN month(d) IN (6, 7, 8)  THEN 'sommar'
       ELSE 'höst' END                               AS sasong
FROM spine;