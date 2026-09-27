-- gold_marts.sql
-- mart_kommun_metric: one row per kommun × metric (long format, method §6).
-- value = the metric; better = direction; pct_rank = percentile position, 0 = worst, 1 = best (ties share the midrank).

CREATE OR REFRESH MATERIALIZED VIEW gold.mart_kommun_metric (
  CONSTRAINT known_metric     EXPECT (metric IN ('ev_demand', 'growth', 'growth_raw', 'growth_stock',
                                                 'price', 'price_zone_alt', 'supply', 'supply_county')) ON VIOLATION FAIL UPDATE,
  CONSTRAINT value_present    EXPECT (value IS NOT NULL)                          ON VIOLATION FAIL UPDATE,
  CONSTRAINT rank_in_range    EXPECT (COALESCE(pct_rank BETWEEN 0 AND 1, false))  ON VIOLATION FAIL UPDATE,
  CONSTRAINT one_row_per_pair EXPECT (n_same_pair = 1)                            ON VIOLATION FAIL UPDATE,
  CONSTRAINT all_kommuner     EXPECT (n_kommuner = n_dim)                         ON VIOLATION FAIL UPDATE
)
COMMENT 'Score inputs per kommun and metric with percentile positions. Robustness variants are extra metrics (method §5).'
AS
WITH
p AS (   -- model parameters (gold.param_model)
  SELECT
    MAX(CASE WHEN parameter = 'phev_weight'          THEN CAST(value AS DOUBLE) END) AS phev_weight,
    MAX(CASE WHEN parameter = 'growth_window_months' THEN CAST(value AS INT)    END) AS growth_months,
    MAX(CASE WHEN parameter = 'price_window_days'    THEN CAST(value AS INT)    END) AS price_days
  FROM gold.param_model
),
km AS (
  SELECT kommun_kod, lan_kod, elomrade, COALESCE(elomrade_secondary, elomrade) AS elomrade_alt
  FROM gold.dim_kommun
),

-- Fleet: latest year in the data, and two years earlier
fy AS (SELECT MAX(ar) AS y FROM gold.fct_fordon_i_trafik_ar),
ev AS (
  SELECT f.kommun_kod,
         SUM(CASE WHEN f.ar = fy.y     AND f.drivmedel = 'BEV'  THEN f.antal END) AS bev,
         SUM(CASE WHEN f.ar = fy.y     AND f.drivmedel = 'PHEV' THEN f.antal END) AS phev,
         SUM(CASE WHEN f.ar = fy.y                              THEN f.antal END) AS tot,
         SUM(CASE WHEN f.ar = fy.y - 2 AND f.drivmedel = 'BEV'  THEN f.antal END) AS bev_prev,
         SUM(CASE WHEN f.ar = fy.y - 2                          THEN f.antal END) AS tot_prev,
         SUM(CASE WHEN f.ar = fy.y     AND f.drivmedel = 'BEV'  THEN f.antal END)
           + MAX(p.phev_weight) * SUM(CASE WHEN f.ar = fy.y AND f.drivmedel = 'PHEV' THEN f.antal END) AS ev
  FROM gold.fct_fordon_i_trafik_ar f CROSS JOIN fy CROSS JOIN p
  GROUP BY f.kommun_kod
),

-- New registrations over the growth window, shrinkage towards the county share (method §2.2)
rm AS (SELECT MAX(manad_start) AS m1 FROM gold.fct_nyregistrering_manad),
g AS (
  SELECT format_string('SCB TAB3277 %s – %s',
                       date_format(add_months(rm.m1, 1 - p.growth_months), 'yyyy-MM'),
                       date_format(rm.m1, 'yyyy-MM')) AS as_of
  FROM rm CROSS JOIN p
),
reg AS (
  SELECT r.kommun_kod,
         CAST(SUM(CASE WHEN r.drivmedel = 'BEV' THEN r.antal ELSE 0 END) AS DOUBLE) AS x,
         CAST(SUM(r.antal) AS DOUBLE)                                              AS n
  FROM gold.fct_nyregistrering_manad r CROSS JOIN rm CROSS JOIN p
  WHERE r.manad_start > add_months(rm.m1, -p.growth_months)
  GROUP BY r.kommun_kod
),
reg_c AS (
  SELECT r.*, km.lan_kod,
         SUM(r.x) OVER (PARTITION BY km.lan_kod) / SUM(r.n) OVER (PARTITION BY km.lan_kod) AS p_c,
         SUM(r.x) OVER () / SUM(r.n) OVER ()                                              AS p_nat
  FROM reg r JOIN km USING (kommun_kod)
),
kk AS (   -- method of moments: tau2 = observed variance around the county share − expected sampling variance
  SELECT tau2,
         CASE WHEN tau2 > 0 THEN GREATEST(p_nat * (1 - p_nat) / tau2 - 1, 0) END AS k_est   -- NULL = no real spread → county share
  FROM (
    SELECT AVG(POWER(x / n - p_c, 2)) - AVG(p_c * (1 - p_c) / n) AS tau2,
           MAX(p_nat) AS p_nat
    FROM reg_c
    WHERE n > 0
  )
),

-- Existing public DC supply (gold.fct_laddstation, EVSE rule applied)
nb AS (SELECT format_string('NOBIL %s', CAST(MAX(_snapshot_date) AS STRING)) AS as_of FROM gold.fct_laddstation),
sup_k AS (
  SELECT km.kommun_kod, km.lan_kod,
         CAST(COALESCE(s.kw_dc, 0) AS DOUBLE) AS kw_dc,
         CAST(e.ev AS DOUBLE)                 AS ev
  FROM km
  JOIN ev e USING (kommun_kod)
  LEFT JOIN (SELECT kommun_kod, SUM(kw_dc) AS kw_dc FROM gold.fct_laddstation GROUP BY kommun_kod) s
    USING (kommun_kod)
),

-- Zone price over the window, weighted by quarter-hours (= mean over all quarter-hours)
pd AS (SELECT MAX(datum) AS d1 FROM gold.fct_elpris_dag),
price AS (
  SELECT e.elomrade,
         CAST(SUM(e.sek_medel * e.n_kvartar) / SUM(e.n_kvartar) AS DOUBLE) AS sek,
         MIN(e.datum) AS d0,
         MAX(e.datum) AS d1
  FROM gold.fct_elpris_dag e CROSS JOIN pd CROSS JOIN p
  WHERE e.datum > date_sub(pd.d1, p.price_days)
  GROUP BY e.elomrade
),

metrics AS (
  -- 1. EV demand
  SELECT e.kommun_kod, 'ev_demand' AS metric, 'higher' AS better,
         CAST(e.ev AS DOUBLE) AS value,
         CAST(NULL AS DOUBLE) AS numerator, CAST(NULL AS DOUBLE) AS denominator,
         CAST(NULL AS DOUBLE) AS prior,     CAST(NULL AS DOUBLE) AS k,
         format_string('BEV %d + %.1f × PHEV %d', e.bev, p.phev_weight, e.phev) AS detail,
         format_string('T10026 year-end %d', fy.y) AS as_of
  FROM ev e CROSS JOIN p CROSS JOIN fy

  UNION ALL   -- 2. Growth: D shrunk towards the county share
  SELECT r.kommun_kod, 'growth', 'higher',
         CASE WHEN kk.k_est IS NULL THEN r.p_c ELSE (r.x + kk.k_est * r.p_c) / (r.n + kk.k_est) END,
         r.x, r.n, r.p_c, kk.k_est,
         format_string('%d BEV of %d new cars; county %.1f%%; k %s',
                       CAST(r.x AS BIGINT), CAST(r.n AS BIGINT), 100 * r.p_c,
                       COALESCE(CAST(CAST(ROUND(kk.k_est) AS BIGINT) AS STRING), 'none')),
         g.as_of
  FROM reg_c r CROSS JOIN kk CROSS JOIN g

  UNION ALL   -- 3. Growth without shrinkage (robustness)
  SELECT r.kommun_kod, 'growth_raw', 'higher',
         try_divide(r.x, r.n),
         r.x, r.n, r.p_c, CAST(NULL AS DOUBLE),
         format_string('%d BEV of %d new cars', CAST(r.x AS BIGINT), CAST(r.n AS BIGINT)),
         g.as_of
  FROM reg_c r CROSS JOIN g

  UNION ALL   -- 4. Growth as change in BEV share of the fleet, C (robustness)
  SELECT e.kommun_kod, 'growth_stock', 'higher',
         try_divide(e.bev, e.tot) - try_divide(e.bev_prev, e.tot_prev),
         CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE),
         format_string('BEV share of fleet %.1f%% (%d) vs %.1f%% (%d)',
                       100 * try_divide(e.bev, e.tot), fy.y, 100 * try_divide(e.bev_prev, e.tot_prev), fy.y - 2),
         format_string('T10026 year-end %d and %d', fy.y - 2, fy.y)
  FROM ev e CROSS JOIN fy

  UNION ALL   -- 5. Electricity price, primary zone
  SELECT km.kommun_kod, 'price', 'lower',
         pr.sek,
         CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE),
         format_string('%s mean %.3f kr/kWh', km.elomrade, pr.sek),
         format_string('Elpriset just nu %s – %s', CAST(pr.d0 AS STRING), CAST(pr.d1 AS STRING))
  FROM km JOIN price pr ON pr.elomrade = km.elomrade

  UNION ALL   -- 6. Electricity price, secondary zone for split kommuner (robustness)
  SELECT km.kommun_kod, 'price_zone_alt', 'lower',
         pr.sek,
         CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE),
         format_string('%s mean %.3f kr/kWh', km.elomrade_alt, pr.sek),
         format_string('Elpriset just nu %s – %s', CAST(pr.d0 AS STRING), CAST(pr.d1 AS STRING))
  FROM km JOIN price pr ON pr.elomrade = km.elomrade_alt

  UNION ALL   -- 7. Existing supply: public DC kW per EV in the kommun
  SELECT s.kommun_kod, 'supply', 'lower',
         try_divide(s.kw_dc, s.ev),
         s.kw_dc, s.ev, CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE),
         format_string('%.0f kW public DC for %.0f EVs', s.kw_dc, s.ev),
         nb.as_of
  FROM sup_k s CROSS JOIN nb

  UNION ALL   -- 8. Existing supply counted per county (robustness, border spillover)
  SELECT s.kommun_kod, 'supply_county', 'lower',
         SUM(s.kw_dc) OVER (PARTITION BY s.lan_kod) / SUM(s.ev) OVER (PARTITION BY s.lan_kod),
         SUM(s.kw_dc) OVER (PARTITION BY s.lan_kod), SUM(s.ev) OVER (PARTITION BY s.lan_kod),
         CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE),
         format_string('county %s: %.0f kW public DC for %.0f EVs', s.lan_kod,
                       SUM(s.kw_dc) OVER (PARTITION BY s.lan_kod), SUM(s.ev) OVER (PARTITION BY s.lan_kod)),
         nb.as_of
  FROM sup_k s CROSS JOIN nb
),

ranked AS (
  SELECT m.*,
         RANK()   OVER (PARTITION BY metric ORDER BY CASE WHEN better = 'higher' THEN value ELSE -value END) AS r_min,
         COUNT(*) OVER (PARTITION BY metric, value)      AS n_ties,
         COUNT(*) OVER (PARTITION BY metric)             AS n_kommuner,
         COUNT(*) OVER (PARTITION BY metric, kommun_kod) AS n_same_pair
  FROM metrics m
)
SELECT
  kommun_kod,
  metric,
  value,
  better,
  (r_min + (n_ties - 1) / 2.0 - 1) / (n_kommuner - 1) AS pct_rank,   -- midrank: ties share the middle of their positions
  numerator,
  denominator,
  prior,
  k,
  detail,
  as_of,
  n_ties,
  n_kommuner,
  n_same_pair,
  (SELECT COUNT(*) FROM gold.dim_kommun) AS n_dim
FROM ranked;

-- Runs = scenario × variant (18). Each variant swaps at most one component's metric (method §5).
CREATE OR REFRESH MATERIALIZED VIEW gold.mart_kommun_score_component
COMMENT 'Score contribution per run (scenario × variant), kommun and component: weight × percentile position of the metric used.'
AS
WITH runs AS (
  SELECT w.scenario, w.scenario_namn, v.variant, v.variant_namn,
         w.metric                                                          AS component,
         CASE WHEN w.metric = v.swap_from THEN v.swap_to ELSE w.metric END AS metric_used,
         w.weight
  FROM gold.param_scenario_weights w
  CROSS JOIN gold.param_variant v
)
SELECT r.scenario, r.scenario_namn, r.variant, r.variant_namn,
       m.kommun_kod, r.component, r.metric_used, r.weight,
       m.value, m.pct_rank,
       r.weight * m.pct_rank AS contribution,
       m.detail
FROM runs r
JOIN gold.mart_kommun_metric m ON m.metric = r.metric_used;

-- Score per run and kommun
CREATE OR REFRESH MATERIALIZED VIEW gold.mart_kommun_score (
  CONSTRAINT all_components EXPECT (n_components = n_expected)                 ON VIOLATION FAIL UPDATE,
  CONSTRAINT score_in_range EXPECT (COALESCE(score BETWEEN 0 AND 1, false))    ON VIOLATION FAIL UPDATE
)
COMMENT 'Total score (0–1) per run and kommun, with rank within the run.'
AS
WITH s AS (
  SELECT scenario, variant, kommun_kod,
         SUM(contribution) AS score,
         COUNT(*)          AS n_components
  FROM gold.mart_kommun_score_component
  GROUP BY scenario, variant, kommun_kod
)
SELECT s.*,
       n.n_expected,
       RANK() OVER (PARTITION BY s.scenario, s.variant ORDER BY s.score DESC) AS score_rank
FROM s
JOIN (SELECT scenario, COUNT(*) AS n_expected FROM gold.param_scenario_weights GROUP BY scenario) n
  USING (scenario);

-- Allocation: the 50 largest quotients score / (cost × divisor), at most max_per_kommun per kommun (method §4)
CREATE OR REFRESH MATERIALIZED VIEW gold.mart_allocation_station (
  CONSTRAINT within_cap EXPECT (station_no_in_kommun <= max_per_kommun) ON VIOLATION FAIL UPDATE
)
COMMENT 'One row per allocated station and run, in allocation order (seat_no). Highest-averages method = top-N of the quotient pool.'
AS
WITH p AS (
  SELECT MAX(CASE WHEN parameter = 'n_stations'     THEN CAST(value AS INT)    END) AS n_stations,
         MAX(CASE WHEN parameter = 'max_per_kommun' THEN CAST(value AS INT)    END) AS max_per_kommun,
         MAX(CASE WHEN parameter = 'first_divisor'  THEN CAST(value AS DOUBLE) END) AS first_divisor
  FROM gold.param_model
),
base AS (
  SELECT s.scenario, s.variant, s.kommun_kod, s.score,
         CASE WHEN v.use_cost_factor THEN CAST(c.cost_factor AS DOUBLE) ELSE 1.0 END AS cost_factor
  FROM gold.mart_kommun_score s
  JOIN gold.param_variant v     USING (variant)
  JOIN gold.dim_kommun k        USING (kommun_kod)
  JOIN gold.param_cost_factor c USING (gruppkod)
),
q AS (
  SELECT b.*, js.j, p.n_stations, p.max_per_kommun,
         CASE WHEN js.j = 1 THEN p.first_divisor ELSE 2 * js.j - 1 END                     AS divisor,
         b.score / (b.cost_factor * CASE WHEN js.j = 1 THEN p.first_divisor ELSE 2 * js.j - 1 END) AS quotient
  FROM base b
  CROSS JOIN p
  CROSS JOIN (SELECT explode(sequence(1, max_per_kommun)) AS j FROM p) js
),
ranked AS (
  SELECT q.*,
         ROW_NUMBER() OVER (PARTITION BY scenario, variant
                            ORDER BY quotient DESC, score DESC, kommun_kod, j) AS seat_no   -- deterministic tie-break
  FROM q
)
SELECT scenario, variant, seat_no, kommun_kod,
       j AS station_no_in_kommun, divisor, cost_factor, score, quotient, max_per_kommun
FROM ranked
WHERE seat_no <= n_stations;

-- Allocation per run and kommun (all 290, 0 where none)
CREATE OR REFRESH MATERIALIZED VIEW gold.mart_allocation (
  CONSTRAINT within_cap EXPECT (n_stations <= max_per_kommun) ON VIOLATION FAIL UPDATE,
  CONSTRAINT run_total  EXPECT (run_stations = n_target)      ON VIOLATION FAIL UPDATE
)
COMMENT 'Stations per run and kommun, with score, rank, first seat and new capacity (station_kw × stations).'
AS
WITH p AS (
  SELECT MAX(CASE WHEN parameter = 'n_stations'     THEN CAST(value AS INT)    END) AS n_target,
         MAX(CASE WHEN parameter = 'max_per_kommun' THEN CAST(value AS INT)    END) AS max_per_kommun,
         MAX(CASE WHEN parameter = 'station_kw'     THEN CAST(value AS DOUBLE) END) AS station_kw
  FROM gold.param_model
),
a AS (
  SELECT scenario, variant, kommun_kod,
         COUNT(*)     AS n_stations,
         MIN(seat_no) AS first_seat
  FROM gold.mart_allocation_station
  GROUP BY scenario, variant, kommun_kod
)
SELECT s.scenario, s.variant, s.kommun_kod, s.score, s.score_rank,
       CAST(COALESCE(a.n_stations, 0) AS INT)                               AS n_stations,
       a.first_seat,
       COALESCE(a.n_stations, 0) * p.station_kw                             AS kw_new,
       SUM(COALESCE(a.n_stations, 0)) OVER (PARTITION BY s.scenario, s.variant) AS run_stations,
       p.n_target,
       p.max_per_kommun
FROM gold.mart_kommun_score s
LEFT JOIN a USING (scenario, variant, kommun_kod)
CROSS JOIN p;