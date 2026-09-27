-- gold_facts.sql
-- Fact tables at their natural grain (design §3). Read current SCD 2 rows only.

-- 1. New registrations: kommun × month × fuel (SCB TAB3277)
CREATE OR REFRESH MATERIALIZED VIEW gold.fct_nyregistrering_manad (
  CONSTRAINT fuel_mapped  EXPECT (drivmedel IS NOT NULL)         ON VIOLATION FAIL UPDATE,
  CONSTRAINT not_negative EXPECT (COALESCE(antal >= 0, true))
)
COMMENT 'New passenger-car registrations per kommun, month and conformed fuel. Source SCB TAB3277, current rows.'
AS
SELECT
  s.kommun_kod,
  s.period            AS scb_period,        -- joins gold.dim_datum.scb_period
  s.period_start      AS manad_start,
  d.drivmedel,
  s.drivmedel_scb_kod,
  s.antal,
  s.status
FROM silver.scb_tab3277 s
LEFT JOIN gold.dim_drivmedel d ON d.scb_kod = s.drivmedel_scb_kod
WHERE s.__END_AT IS NULL;

-- 2. Cars in traffic at year-end: kommun × year × fuel (Trafikanalys T10026, zero-filled grid)
CREATE OR REFRESH MATERIALIZED VIEW gold.fct_fordon_i_trafik_ar (
  CONSTRAINT fuel_mapped  EXPECT (drivmedel IS NOT NULL) ON VIOLATION FAIL UPDATE,
  CONSTRAINT not_negative EXPECT (antal >= 0)
)
COMMENT 'Passenger cars in traffic at year-end per kommun, year and conformed fuel. Omitted source rows are 0 with is_filled_zero.'
AS
SELECT
  g.kommun_kod,
  g.ar,
  d.drivmedel,
  g.drivmedel_kod     AS drivmedel_trafa_kod,
  g.antal,
  g.is_filled_zero
FROM silver.trafa_t10026_grid g
LEFT JOIN gold.dim_drivmedel d ON d.trafa_kod = g.drivmedel_kod;

-- 3. Electricity price per zone and local day (Elpriset just nu)
CREATE OR REFRESH MATERIALIZED VIEW gold.fct_elpris_dag (
  CONSTRAINT day_length EXPECT (n_kvartar IN (92, 96, 100))
)
COMMENT 'Daily spot price statistics per price zone, SEK/kWh excl. VAT, grid fees and taxes. Simple means over quarter-hours.'
AS
SELECT
  elomrade,
  datum_lokal                                   AS datum,
  ROUND(AVG(sek_per_kwh), 5)                    AS sek_medel,
  MIN(sek_per_kwh)                              AS sek_min,
  MAX(sek_per_kwh)                              AS sek_max,
  ROUND(percentile(sek_per_kwh, 0.9), 5)        AS sek_p90,
  COUNT(*)                                      AS n_kvartar,
  COUNT_IF(sek_per_kwh < 0)                     AS n_negativa
FROM silver.elpris
GROUP BY elomrade, datum_lokal;

-- 4. Kommun × year: population, land area, cars total and company-owned (SCB TAB628 + TAB3276, pivoted from long format)
CREATE OR REFRESH MATERIALIZED VIEW gold.fct_kommun_ar (
  CONSTRAINT population_present EXPECT (folkmangd IS NOT NULL),
  CONSTRAINT cars_present       EXPECT (personbilar_totalt IS NOT NULL)
)
COMMENT 'One row per kommun and year. Land area uses a new SCB method from 2025 (finding 42); company share = TAB3276 030 / 000.'
AS
WITH pop AS (
  SELECT kommun_kod, ar,
         MAX(CASE WHEN contentscode = 'BE0101U2' THEN varde END) AS folkmangd,
         MAX(CASE WHEN contentscode = 'BE0101U3' THEN varde END) AS landareal_km2
  FROM silver.scb_tab628
  WHERE __END_AT IS NULL
  GROUP BY kommun_kod, ar
),
cars AS (
  SELECT kommun_kod, ar,
         MAX(CASE WHEN agarkategori = '000' THEN antal END) AS personbilar_totalt,
         MAX(CASE WHEN agarkategori = '030' THEN antal END) AS personbilar_juridisk
  FROM silver.scb_tab3276
  WHERE __END_AT IS NULL
  GROUP BY kommun_kod, ar
)
SELECT
  COALESCE(p.kommun_kod, c.kommun_kod)                          AS kommun_kod,
  COALESCE(p.ar, c.ar)                                          AS ar,
  CAST(p.folkmangd AS BIGINT)                                   AS folkmangd,
  p.landareal_km2,
  c.personbilar_totalt,
  c.personbilar_juridisk,
  ROUND(try_divide(c.personbilar_juridisk, c.personbilar_totalt), 4) AS andel_juridisk
FROM pop p
FULL OUTER JOIN cars c ON c.kommun_kod = p.kommun_kod AND c.ar = p.ar;