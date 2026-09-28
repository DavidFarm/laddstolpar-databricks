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

-- 5. Charging stations: one row per public station, latest NOBIL snapshot.
--    Gold rules (design 0.1, 26 Sep): public only; station 84436 excluded; car/van connectors only;
--    EVSE rule (Σ over EVSEs of max connector kW; no EVSE ID = own EVSE); fast/ultra on DC.
CREATE OR REFRESH MATERIALIZED VIEW gold.fct_laddstation (
  CONSTRAINT has_power       EXPECT (kw_total > 0),
  CONSTRAINT dc_within_total EXPECT (kw_dc <= kw_total) ON VIOLATION FAIL UPDATE
)
COMMENT 'Public charging stations (NOBIL, CC BY 4.0), car/van connectors only. kW is nameplate, EVSE rule applied (finding 54).'
AS
WITH st AS (
  SELECT station_id, station_name, kommun_kod, operator, owned_by, lat, lon, _snapshot_date
  FROM silver.nobil_station
  WHERE __END_AT IS NULL
    AND is_public
    AND station_id <> 84436                                         -- test entry "Test_Warfvinges" (finding 57)
),
conn AS (
  SELECT station_id,
         COALESCE(NULLIF(evse_id, ''), concat('conn:', connector_no)) AS evse_key,  -- no EVSE ID = own EVSE
         kw,
         current_type
  FROM silver.nobil_connector
  WHERE __END_AT IS NULL
    AND vehicle_type_code IN ('1', '6', '11', '12', '15', '22')    -- includes cars or vans (finding 55)
    AND current_type IN ('AC', 'DC')                               -- excludes hydrogen (finding 48)
),
evse AS (
  SELECT station_id, evse_key,
         MAX(kw)                                          AS kw_evse,
         MAX(CASE WHEN current_type = 'DC' THEN kw END)   AS kw_dc_evse,
         COUNT(*)                                         AS n_conn,
         COUNT_IF(current_type = 'DC')                    AS n_dc_conn
  FROM conn
  GROUP BY station_id, evse_key
),
agg AS (
  SELECT station_id,
         COUNT(*)                      AS n_evse,
         SUM(n_conn)                   AS n_anslutningar,
         SUM(n_dc_conn)                AS n_dc_anslutningar,
         SUM(kw_evse)                  AS kw_total,
         COALESCE(SUM(kw_dc_evse), 0)  AS kw_dc,
         MAX(kw_dc_evse)               AS kw_dc_max
  FROM evse
  GROUP BY station_id
)
SELECT
  st.station_id,
  st.station_name,
  st.kommun_kod,
  st.operator,
  st.owned_by,
  a.n_anslutningar,
  a.n_dc_anslutningar,
  a.n_evse,
  a.kw_total,
  a.kw_dc,
  a.kw_dc_max,
  COALESCE(a.kw_dc_max >= 50, false)   AS is_fast,     -- DC >= 50 kW
  COALESCE(a.kw_dc_max >= 150, false)  AS is_ultra,    -- DC >= 150 kW
  st.lat,
  st.lon,
  COALESCE(st.lat BETWEEN 55.0 AND 69.5 AND st.lon BETWEEN 10.5 AND 24.5, false) AS position_valid,
  st._snapshot_date
FROM st
JOIN agg a USING (station_id);

-- Traffic on state roads per kommun (NVDB Trafik, one snapshot; findings 69-71)
CREATE OR REFRESH MATERIALIZED VIEW gold.fct_trafik_kommun (
  CONSTRAINT one_row_per_kommun EXPECT (n_same = 1) ON VIOLATION FAIL UPDATE,
  CONSTRAINT kommun_in_dim      EXPECT (in_dim)     ON VIOLATION FAIL UPDATE
)
COMMENT 'Kommun grain: state-road sections, road km, vehicle-km/day (all + heavy), max ÅDT, measured share, weighted measurement year, betraktelsedatum.'
AS
SELECT
  t.kommun_kod, t.n_sections, t.road_km, t.vkm_per_day, t.vkm_heavy_per_day, t.max_adt,
  t.vkm_share_measured, t.vkm_weighted_year, t.n_sections_no_adt, t.betraktelsedatum,
  COUNT(*) OVER (PARTITION BY t.kommun_kod) AS n_same,
  d.kommun_kod IS NOT NULL                  AS in_dim
FROM silver.nvdb_trafik_kommun t
LEFT JOIN gold.dim_kommun d ON d.kommun_kod = t.kommun_kod;
