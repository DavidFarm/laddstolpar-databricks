-- gold_marts.sql
-- mart_kommun_metric: one row per kommun × metric (long format, method §6).
-- value = the metric; better = direction; pct_rank = percentile position, 0 = worst, 1 = best (ties share the midrank).

CREATE OR REFRESH MATERIALIZED VIEW gold.mart_kommun_metric (
    CONSTRAINT known_metric     EXPECT (metric IN ('ev_demand', 'growth', 'growth_raw', 'growth_stock',
                                                 'price', 'price_zone_alt', 'supply', 'supply_county',
                                                 'supply_traffic', 'through_traffic', 'traffic', 'traffic_intensity')) ON VIOLATION FAIL UPDATE,
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

-- Traffic on state roads (gold.fct_trafik_kommun) + population in the latest year (gold.fct_kommun_ar)
py AS (SELECT MAX(ar) AS y FROM gold.fct_kommun_ar WHERE folkmangd IS NOT NULL),
tr AS (
  SELECT s.kommun_kod,
         s.kw_dc,
         CAST(t.vkm_per_day AS DOUBLE) AS vkm,
         CAST(t.road_km     AS DOUBLE) AS road_km,
         CAST(f.folkmangd   AS DOUBLE) AS pop,
         format_string('NVDB Trafik %s; SCB population %d', CAST(t.betraktelsedatum AS STRING), py.y) AS as_of
  FROM sup_k s
  JOIN gold.fct_trafik_kommun t USING (kommun_kod)
  JOIN gold.fct_kommun_ar f     USING (kommun_kod)
  CROSS JOIN py
  WHERE f.ar = py.y
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
  UNION ALL   -- 9. Existing supply per traffic: public DC kW per 1,000 vehicle-km/day (P2; method §2.5)
  -- Rule (b): no state-road traffic → treated as fully served (+∞, lower = better → worst position)
  SELECT t.kommun_kod, 'supply_traffic', 'lower',
         CASE WHEN t.vkm > 0 THEN t.kw_dc / (t.vkm / 1000) ELSE CAST('Infinity' AS DOUBLE) END,
         t.kw_dc, t.vkm, CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE),
         CASE WHEN t.vkm > 0
              THEN format_string('%.0f kW public DC for %.0f k vehicle-km/day', t.kw_dc, t.vkm / 1000)
              ELSE 'No state road: treated as fully served (rule b)' END,
         t.as_of
  FROM tr t

  UNION ALL   -- 10. Through-traffic: vehicle-km/day on state roads per inhabitant (P2; finding 72)
  SELECT t.kommun_kod, 'through_traffic', 'higher',
         try_divide(t.vkm, t.pop),
         t.vkm, t.pop, CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE),
         format_string('%.0f k vehicle-km/day for %.0f inhabitants', t.vkm / 1000, t.pop),
         t.as_of
  FROM tr t

  UNION ALL   -- 11. Traffic volume (context only, weight 0)
  SELECT t.kommun_kod, 'traffic', 'higher',
         t.vkm,
         t.vkm, t.road_km, CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE),
         format_string('%.0f k vehicle-km/day on %.0f km of state road', t.vkm / 1000, t.road_km),
         t.as_of
  FROM tr t

  UNION ALL   -- 12. Traffic intensity ≈ mean ÅDT (context only; rejected as an index metric, finding 72)
  SELECT t.kommun_kod, 'traffic_intensity', 'higher',
         CASE WHEN t.road_km > 0 THEN t.vkm / t.road_km ELSE 0 END,
         t.vkm, t.road_km, CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE),
         format_string('%.0f vehicles per road-km', CASE WHEN t.road_km > 0 THEN t.vkm / t.road_km ELSE 0 END),
         t.as_of
  FROM tr t
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

-- Runs = strategy × variant (14: P1 × 6, P2 × 8; only_scenario limits the α variants to P2). Method §3.3, §5.
CREATE OR REFRESH MATERIALIZED VIEW gold.mart_kommun_score_component
COMMENT 'Attractiveness contribution per run (strategy × variant), kommun and component: weight × percentile position of the metric used.'
AS
WITH runs AS (
  SELECT w.scenario, w.scenario_namn, v.variant, v.variant_namn,
         w.metric                                                          AS component,
         CASE WHEN w.metric = v.swap_from THEN v.swap_to ELSE w.metric END AS metric_used,
         w.weight
  FROM gold.param_scenario_weights w
  CROSS JOIN gold.param_variant v
  WHERE v.only_scenario IS NULL OR v.only_scenario = w.scenario
)
SELECT r.scenario, r.scenario_namn, r.variant, r.variant_namn,
       m.kommun_kod, r.component, r.metric_used, r.weight,
       m.value, m.pct_rank,
       r.weight * m.pct_rank AS contribution,
       m.detail
FROM runs r
JOIN gold.mart_kommun_metric m ON m.metric = r.metric_used;

-- Attractiveness and votes per run and kommun (method §4.2): votes = quantity^α × attractiveness ÷ cost; quantity = EVs (P1) or state-road traffic (P2)
CREATE OR REFRESH MATERIALIZED VIEW gold.mart_kommun_score (
  CONSTRAINT all_components     EXPECT (n_components = n_expected)                        ON VIOLATION FAIL UPDATE,
  CONSTRAINT attractiveness_ok  EXPECT (COALESCE(attractiveness BETWEEN 0 AND 1, false))  ON VIOLATION FAIL UPDATE,
  CONSTRAINT votes_ok           EXPECT (COALESCE(votes >= 0, false))                      ON VIOLATION FAIL UPDATE
)
COMMENT 'Per run and kommun: attractiveness a (0–1, weighted percentile positions), quantity (EVs in P1, state-road traffic in P2), α, cost factor and votes = quantity^α × a ÷ cost.'
AS
WITH s AS (
  SELECT scenario, variant, kommun_kod,
         SUM(contribution) AS attractiveness,
         COUNT(*)          AS n_components
  FROM gold.mart_kommun_score_component
  GROUP BY scenario, variant, kommun_kod
),
n AS (SELECT scenario, COUNT(*) AS n_expected FROM gold.param_scenario_weights GROUP BY scenario),
run AS (
  SELECT st.scenario, v.variant,
         COALESCE(v.alpha, st.alpha)       AS alpha,
         COALESCE(v.quantity, st.quantity) AS quantity,
         v.use_cost_factor
  FROM gold.param_strategy st
  CROSS JOIN gold.param_variant v
  WHERE v.only_scenario IS NULL OR v.only_scenario = st.scenario
),
qv AS (
  SELECT kommun_kod, metric AS quantity, value AS quantity_value
  FROM gold.mart_kommun_metric
  WHERE metric IN ('ev_demand', 'traffic')
),
b AS (
  SELECT s.scenario, s.variant, s.kommun_kod,
         s.attractiveness, s.n_components, n.n_expected,
         r.quantity, q.quantity_value, r.alpha,
         CASE WHEN r.use_cost_factor THEN CAST(c.cost_factor AS DOUBLE) ELSE 1.0 END AS cost_factor
  FROM s
  JOIN n USING (scenario)
  JOIN run r USING (scenario, variant)
  JOIN qv q ON q.kommun_kod = s.kommun_kod AND q.quantity = r.quantity
  JOIN gold.dim_kommun k ON k.kommun_kod = s.kommun_kod
  JOIN gold.param_cost_factor c ON c.gruppkod = k.gruppkod
)
SELECT b.*,
       POWER(b.quantity_value, b.alpha) * b.attractiveness / b.cost_factor AS votes,
       RANK() OVER (PARTITION BY scenario, variant ORDER BY attractiveness DESC) AS attractiveness_rank,
       RANK() OVER (PARTITION BY scenario, variant
                    ORDER BY POWER(quantity_value, alpha) * attractiveness / cost_factor DESC) AS votes_rank
FROM b;

-- Allocation: the N largest quotients votes / divisor (Sainte-Laguë, first divisor from param_model), cap per kommun
CREATE OR REFRESH MATERIALIZED VIEW gold.mart_allocation_station (
  CONSTRAINT within_cap EXPECT (station_no_in_kommun <= max_per_kommun) ON VIOLATION FAIL UPDATE
)
COMMENT 'One row per allocated station and run, in allocation order (seat_no). Highest-averages method on votes = top-N of the quotient pool.'
AS
WITH p AS (
  SELECT MAX(CASE WHEN parameter = 'n_stations'     THEN CAST(value AS INT)    END) AS n_stations,
         MAX(CASE WHEN parameter = 'max_per_kommun' THEN CAST(value AS INT)    END) AS max_per_kommun,
         MAX(CASE WHEN parameter = 'first_divisor'  THEN CAST(value AS DOUBLE) END) AS first_divisor
  FROM gold.param_model
),
q AS (
  SELECT s.scenario, s.variant, s.kommun_kod, s.votes, s.attractiveness, s.cost_factor,
         js.j, p.n_stations, p.max_per_kommun,
         CASE WHEN js.j = 1 THEN p.first_divisor ELSE 2 * js.j - 1 END           AS divisor,
         s.votes / CASE WHEN js.j = 1 THEN p.first_divisor ELSE 2 * js.j - 1 END AS quotient
  FROM gold.mart_kommun_score s
  CROSS JOIN p
  CROSS JOIN (SELECT explode(sequence(1, max_per_kommun)) AS j FROM p) js
  WHERE s.votes > 0
),
ranked AS (
  SELECT q.*,
         ROW_NUMBER() OVER (PARTITION BY scenario, variant
                            ORDER BY quotient DESC, votes DESC, kommun_kod, j) AS seat_no   -- deterministic tie-break
  FROM q
)
SELECT scenario, variant, seat_no, kommun_kod,
       j AS station_no_in_kommun, divisor, cost_factor, attractiveness, votes, quotient, max_per_kommun
FROM ranked
WHERE seat_no <= n_stations;

-- Allocation per run and kommun (all 290, 0 where none)
CREATE OR REFRESH MATERIALIZED VIEW gold.mart_allocation (
  CONSTRAINT within_cap EXPECT (n_stations <= max_per_kommun) ON VIOLATION FAIL UPDATE,
  CONSTRAINT run_total  EXPECT (run_stations = n_target)      ON VIOLATION FAIL UPDATE
)
COMMENT 'Stations per run and kommun, with attractiveness, EV, α, votes, ranks, first seat and new capacity (station_kw × stations).'
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
SELECT s.scenario, s.variant, s.kommun_kod,
       s.attractiveness, s.attractiveness_rank, 
       s.quantity, s.quantity_value, s.alpha, 
       s.cost_factor, s.votes, s.votes_rank,
       CAST(COALESCE(a.n_stations, 0) AS INT)                                   AS n_stations,
       a.first_seat,
       COALESCE(a.n_stations, 0) * p.station_kw                                 AS kw_new,
       SUM(COALESCE(a.n_stations, 0)) OVER (PARTITION BY s.scenario, s.variant) AS run_stations,
       p.n_target,
       p.max_per_kommun
FROM gold.mart_kommun_score s
LEFT JOIN a USING (scenario, variant, kommun_kod)
CROSS JOIN p;

-- Combined allocation (method §4.3): n₁ seats from the first strategy (its own seats 1 … n₁), then
-- n_stations − n₁ from the second, continuing the divisors after each kommun's first-part stations.
-- Precomputed for n₁ = 0, step, …, n_stations and every variant shared by both strategies → dashboard slider.
CREATE OR REFRESH MATERIALIZED VIEW gold.mart_allocation_combined_station (
  CONSTRAINT within_cap  EXPECT (station_no_in_kommun <= max_per_kommun) ON VIOLATION FAIL UPDATE,
  CONSTRAINT seat_in_run EXPECT (seat_no BETWEEN 1 AND n_target)         ON VIOLATION FAIL UPDATE
)
COMMENT 'One row per allocated station per slider setting (n_p1) and variant: seats 1..n_p1 from the first strategy, the rest from the second with continued Sainte-Laguë divisors.'
AS
WITH p AS (
  SELECT MAX(CASE WHEN parameter = 'n_stations'     THEN CAST(value AS INT)    END) AS n_target,
         MAX(CASE WHEN parameter = 'max_per_kommun' THEN CAST(value AS INT)    END) AS max_per_kommun,
         MAX(CASE WHEN parameter = 'first_divisor'  THEN CAST(value AS DOUBLE) END) AS first_divisor,
         MAX(CASE WHEN parameter = 'combined_step'  THEN CAST(value AS INT)    END) AS step
  FROM gold.param_model
),
s1 AS (SELECT scenario AS s1 FROM gold.param_strategy WHERE combine_order = 1),
s2 AS (SELECT scenario AS s2 FROM gold.param_strategy WHERE combine_order = 2),
settings AS (SELECT explode(sequence(0, n_target, step)) AS n_p1 FROM p),
vars AS (SELECT variant FROM gold.param_variant WHERE only_scenario IS NULL),   -- variants that exist for both strategies
js AS (SELECT explode(sequence(1, max_per_kommun)) AS j FROM p),

-- Part 1: the first strategy's own seats 1 … n₁
part1 AS (
  SELECT st.n_p1, a.variant, a.seat_no, s1.s1 AS part, a.kommun_kod,
         a.station_no_in_kommun, a.divisor, a.quotient
  FROM settings st
  CROSS JOIN s1
  JOIN gold.mart_allocation_station a ON a.scenario = s1.s1 AND a.seat_no <= st.n_p1
  JOIN vars v ON v.variant = a.variant
),
k1 AS (
  SELECT n_p1, variant, kommun_kod, COUNT(*) AS k
  FROM part1
  GROUP BY n_p1, variant, kommun_kod
),

-- Part 2: the second strategy's quotient pool, each kommun starting after its Part 1 stations
pool2 AS (
  SELECT st.n_p1, sc.variant, sc.kommun_kod, sc.votes, js.j,
         CASE WHEN js.j = 1 THEN p.first_divisor ELSE 2 * js.j - 1 END           AS divisor,
         sc.votes / CASE WHEN js.j = 1 THEN p.first_divisor ELSE 2 * js.j - 1 END AS quotient
  FROM settings st
  CROSS JOIN p
  CROSS JOIN s2
  CROSS JOIN js
  JOIN gold.mart_kommun_score sc ON sc.scenario = s2.s2 AND sc.votes > 0
  JOIN vars v ON v.variant = sc.variant
  LEFT JOIN k1 ON k1.n_p1 = st.n_p1 AND k1.variant = sc.variant AND k1.kommun_kod = sc.kommun_kod
  WHERE js.j > COALESCE(k1.k, 0)
),
part2 AS (
  SELECT q.*,
         ROW_NUMBER() OVER (PARTITION BY n_p1, variant
                            ORDER BY quotient DESC, votes DESC, kommun_kod, j) AS rn   -- deterministic tie-break
  FROM pool2 q
)
SELECT x.n_p1, x.variant, x.seat_no, x.part, x.kommun_kod, x.station_no_in_kommun, x.divisor, x.quotient,
       p.n_target, p.max_per_kommun
FROM (
  SELECT n_p1, variant, seat_no, part, kommun_kod, station_no_in_kommun, divisor, quotient FROM part1
  UNION ALL
  SELECT q.n_p1, q.variant, q.n_p1 + q.rn, s2.s2, q.kommun_kod, q.j, q.divisor, q.quotient
  FROM part2 q CROSS JOIN s2 CROSS JOIN p
  WHERE q.rn <= p.n_target - q.n_p1
) x
CROSS JOIN p;

-- Combined allocation per slider setting, variant and kommun (all 290, 0 where none)
CREATE OR REFRESH MATERIALIZED VIEW gold.mart_allocation_combined (
  CONSTRAINT within_cap      EXPECT (n_stations <= max_per_kommun) ON VIOLATION FAIL UPDATE,
  CONSTRAINT run_total       EXPECT (run_stations = n_target)      ON VIOLATION FAIL UPDATE,
  CONSTRAINT default_present EXPECT (default_present = 1)          ON VIOLATION FAIL UPDATE
)
COMMENT 'Combined allocation per slider setting (n_p1 = stations from the first strategy), variant and kommun: stations from each part, total, new kW; is_default marks the recommended setting.'
AS
WITH p AS (
  SELECT MAX(CASE WHEN parameter = 'n_stations'            THEN CAST(value AS INT)    END) AS n_target,
         MAX(CASE WHEN parameter = 'max_per_kommun'        THEN CAST(value AS INT)    END) AS max_per_kommun,
         MAX(CASE WHEN parameter = 'station_kw'            THEN CAST(value AS DOUBLE) END) AS station_kw,
         MAX(CASE WHEN parameter = 'n_stations_p1_default' THEN CAST(value AS INT)    END) AS n_p1_default,
         MAX(CASE WHEN parameter = 'combined_step'         THEN CAST(value AS INT)    END) AS step
  FROM gold.param_model
),
settings AS (SELECT explode(sequence(0, n_target, step)) AS n_p1 FROM p),
vars     AS (SELECT variant FROM gold.param_variant WHERE only_scenario IS NULL),
grid AS (   -- from the parameters, not from the result: every setting × shared variant × kommun
  SELECT s.n_p1, v.variant, k.kommun_kod
  FROM settings s CROSS JOIN vars v CROSS JOIN gold.dim_kommun k
),
a AS (
  SELECT n_p1, variant, kommun_kod,
         COUNT_IF(seat_no <= n_p1) AS n_part1,
         COUNT_IF(seat_no >  n_p1) AS n_part2,
         MIN(seat_no)              AS first_seat
  FROM gold.mart_allocation_combined_station
  GROUP BY n_p1, variant, kommun_kod
),
b AS (
  SELECT g.n_p1, g.variant, g.kommun_kod,
         CAST(COALESCE(a.n_part1, 0) AS INT) AS n_part1,
         CAST(COALESCE(a.n_part2, 0) AS INT) AS n_part2,
         a.first_seat
  FROM grid g
  LEFT JOIN a ON a.n_p1 = g.n_p1 AND a.variant = g.variant AND a.kommun_kod = g.kommun_kod
)
SELECT b.*,
       b.n_part1 + b.n_part2                                            AS n_stations,
       (b.n_part1 + b.n_part2) * p.station_kw                           AS kw_new,
       SUM(b.n_part1 + b.n_part2) OVER (PARTITION BY b.n_p1, b.variant) AS run_stations,
       b.n_p1 = p.n_p1_default                                          AS is_default,
       MAX(CASE WHEN b.n_p1 = p.n_p1_default THEN 1 ELSE 0 END) OVER () AS default_present,
       p.n_target,
       p.max_per_kommun
FROM b CROSS JOIN p;