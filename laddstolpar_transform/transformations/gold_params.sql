-- gold_params.sql
-- Business assumptions as parameter tables (Git seed → 04_seeds → bronze → here).
-- Assumptions live here, not in dimensions, so robustness runs change parameters only.

-- Scenario weights: relative points in the seed, normalised to sum 1 per scenario
-- Attractiveness-index weights per strategy: relative points in the seed, normalised to sum 1 per scenario
CREATE OR REFRESH MATERIALIZED VIEW gold.param_scenario_weights (
  CONSTRAINT known_metric     EXPECT (metric IN ('growth', 'price', 'supply', 'supply_traffic', 'through_traffic')) ON VIOLATION FAIL UPDATE,
  CONSTRAINT weight_valid     EXPECT (COALESCE(weight_raw >= 0, false))                     ON VIOLATION FAIL UPDATE,
  CONSTRAINT scenario_nonzero EXPECT (COALESCE(weight_sum > 0, false))                      ON VIOLATION FAIL UPDATE,
  CONSTRAINT one_row_per_pair EXPECT (n_same_pair = 1)                                      ON VIOLATION FAIL UPDATE,
  CONSTRAINT all_five_metrics EXPECT (n_metrics = 5)                                        ON VIOLATION FAIL UPDATE,
  CONSTRAINT has_strategy     EXPECT (has_strategy)                                         ON VIOLATION FAIL UPDATE
)
COMMENT 'Attractiveness-index weights per strategy (method §3.3). EV demand is the quantity in the votes, not an index metric. weight = weight_raw / Σ weight_raw per scenario.'
AS
WITH w AS (
  SELECT w.scenario, w.scenario_namn, w.metric, try_cast(w.weight AS DOUBLE) AS weight_raw,
         s.scenario IS NOT NULL AS has_strategy
  FROM bronze.seed_param_scenario_weights w
  LEFT JOIN (SELECT DISTINCT scenario FROM bronze.seed_param_strategy) s ON s.scenario = w.scenario
)
SELECT
  scenario,
  scenario_namn,
  metric,
  weight_raw,
  SUM(weight_raw) OVER (PARTITION BY scenario)                    AS weight_sum,
  weight_raw / SUM(weight_raw) OVER (PARTITION BY scenario)       AS weight,
  COUNT(*) OVER (PARTITION BY scenario, metric)                   AS n_same_pair,
  COUNT(*) OVER (PARTITION BY scenario)                           AS n_metrics,
  has_strategy
FROM w;

-- Strategy parameters (method §3.3, §4.2, §4.3): votes = quantity^α × attractiveness ÷ cost; combine_order for the slider
CREATE OR REFRESH MATERIALIZED VIEW gold.param_strategy (
  CONSTRAINT alpha_valid     EXPECT (COALESCE(alpha BETWEEN 0 AND 1, false))    ON VIOLATION FAIL UPDATE,
  CONSTRAINT quantity_known  EXPECT (quantity IN ('ev_demand', 'traffic'))      ON VIOLATION FAIL UPDATE,
  CONSTRAINT order_valid     EXPECT (COALESCE(combine_order IN (1, 2), false))  ON VIOLATION FAIL UPDATE,
  CONSTRAINT unique_scenario EXPECT (n_same = 1)                                ON VIOLATION FAIL UPDATE,
  CONSTRAINT unique_order    EXPECT (n_same_order = 1)                          ON VIOLATION FAIL UPDATE,
  CONSTRAINT has_weights     EXPECT (COALESCE(n_weight_rows > 0, false))        ON VIOLATION FAIL UPDATE
)
COMMENT 'Per strategy: size elasticity α, quantity in the votes (EVs or state-road traffic) and its order in the combined allocation (1 = first n₁ seats).'
AS
SELECT
  s.scenario,
  try_cast(s.alpha AS DOUBLE)                    AS alpha,
  s.quantity,
  try_cast(s.combine_order AS INT)               AS combine_order,
  s.note,
  COUNT(*) OVER (PARTITION BY s.scenario)        AS n_same,
  COUNT(*) OVER (PARTITION BY s.combine_order)   AS n_same_order,
  w.n_weight_rows
FROM bronze.seed_param_strategy s
LEFT JOIN (SELECT scenario, COUNT(*) AS n_weight_rows
           FROM bronze.seed_param_scenario_weights GROUP BY scenario) w
  ON w.scenario = s.scenario;
  
-- Robustness variants: each swaps one metric or switches the cost factor off (method §5)
CREATE OR REFRESH MATERIALIZED VIEW gold.param_variant (
  CONSTRAINT swap_is_pair        EXPECT ((swap_from IS NULL) = (swap_to IS NULL))                         ON VIOLATION FAIL UPDATE,
  CONSTRAINT swap_from_ok        EXPECT (COALESCE(swap_from IN ('growth', 'price', 'supply', 'supply_traffic', 'through_traffic'), true)) ON VIOLATION FAIL UPDATE,
  CONSTRAINT cost_flag_set       EXPECT (use_cost_factor IS NOT NULL)                                     ON VIOLATION FAIL UPDATE,
  CONSTRAINT alpha_parsed        EXPECT ((alpha_raw IS NULL) = (alpha IS NULL))                           ON VIOLATION FAIL UPDATE,
  CONSTRAINT alpha_valid         EXPECT (COALESCE(alpha BETWEEN 0 AND 1, true))                           ON VIOLATION FAIL UPDATE,
  CONSTRAINT only_scenario_known EXPECT (only_scenario IS NULL OR scenario_exists)                        ON VIOLATION FAIL UPDATE,
  CONSTRAINT quantity_known EXPECT (COALESCE(quantity IN ('ev_demand', 'traffic'), true)) ON VIOLATION FAIL UPDATE
)
COMMENT 'Robustness variants. Runs = strategies × variants (only_scenario limits a variant to one strategy); blank = no swap / strategy α (NULLIF, finding 64).'
AS
SELECT
  v.variant,
  v.variant_namn,
  NULLIF(v.swap_from, '')                    AS swap_from,
  NULLIF(v.swap_to, '')                      AS swap_to,
  try_cast(v.use_cost_factor AS BOOLEAN)     AS use_cost_factor,
  NULLIF(v.alpha, '')                        AS alpha_raw,
  try_cast(NULLIF(v.alpha, '') AS DOUBLE)    AS alpha,
  NULLIF(v.only_scenario, '')                AS only_scenario,
  NULLIF(v.quantity, '')                     AS quantity,
  s.scenario IS NOT NULL                     AS scenario_exists
FROM bronze.seed_param_variant v
LEFT JOIN (SELECT DISTINCT scenario FROM bronze.seed_param_strategy) s
  ON s.scenario = NULLIF(v.only_scenario, '');
  
-- Cost factor per SKR kommungrupp, driven from the groups that actually exist in dim_kommun (one row per gruppkod)
CREATE OR REFRESH MATERIALIZED VIEW gold.param_cost_factor (
  CONSTRAINT factor_present EXPECT (COALESCE(cost_factor > 0, false))                ON VIOLATION FAIL UPDATE,
  CONSTRAINT one_label      EXPECT (n_labels = 1)                                    ON VIOLATION FAIL UPDATE,
  CONSTRAINT label_matches  EXPECT (COALESCE(kommungrupp = seed_kommungrupp, false))
)
COMMENT 'Assumed relative build cost per SKR kommungrupp (design 2.5). One row per group; every group in dim_kommun must have a factor.'
AS
WITH groups AS (
  SELECT gruppkod,
         MIN(kommungrupp)             AS kommungrupp,
         COUNT(DISTINCT kommungrupp)  AS n_labels,      -- must be 1: a code with two labels is a seed error
         COUNT(*)                     AS n_kommuner
  FROM gold.dim_kommun
  GROUP BY gruppkod
)
SELECT
  g.gruppkod,
  g.kommungrupp,
  s.kommungrupp                              AS seed_kommungrupp,
  try_cast(s.cost_factor AS DECIMAL(4, 2))   AS cost_factor,
  s.basis,
  g.n_kommuner,
  g.n_labels
FROM groups g
LEFT JOIN bronze.seed_param_cost_factor s ON s.gruppkod = g.gruppkod;

-- Model parameters (numeric key/value)
CREATE OR REFRESH MATERIALIZED VIEW gold.param_model (
  CONSTRAINT value_numeric EXPECT (value IS NOT NULL)   ON VIOLATION FAIL UPDATE,
  CONSTRAINT unique_param  EXPECT (n_same_param = 1)    ON VIOLATION FAIL UPDATE
)
COMMENT 'Model parameters: stations, station size, cap, first divisor, PHEV weight, windows.'
AS
SELECT
  parameter,
  try_cast(value AS DECIMAL(12, 4))          AS value,
  unit,
  note,
  COUNT(*) OVER (PARTITION BY parameter)     AS n_same_param
FROM bronze.seed_param_model;