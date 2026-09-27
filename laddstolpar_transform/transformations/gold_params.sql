-- gold_params.sql
-- Business assumptions as parameter tables (Git seed → 04_seeds → bronze → here).
-- Assumptions live here, not in dimensions, so robustness runs change parameters only.

-- Scenario weights: relative points in the seed, normalised to sum 1 per scenario
CREATE OR REFRESH MATERIALIZED VIEW gold.param_scenario_weights (
  CONSTRAINT known_metric     EXPECT (metric IN ('ev_demand', 'growth', 'price', 'supply')) ON VIOLATION FAIL UPDATE,
  CONSTRAINT weight_valid     EXPECT (COALESCE(weight_raw >= 0, false))                     ON VIOLATION FAIL UPDATE,
  CONSTRAINT scenario_nonzero EXPECT (COALESCE(weight_sum > 0, false))                      ON VIOLATION FAIL UPDATE,
  CONSTRAINT one_row_per_pair EXPECT (n_same_pair = 1)                                      ON VIOLATION FAIL UPDATE,
  CONSTRAINT all_four_metrics EXPECT (n_metrics = 4)                                        ON VIOLATION FAIL UPDATE
)
COMMENT 'Scenario weights per metric (method §3.2). weight = weight_raw / Σ weight_raw per scenario.'
AS
WITH w AS (
  SELECT scenario, scenario_namn, metric, try_cast(weight AS DOUBLE) AS weight_raw
  FROM bronze.seed_param_scenario_weights
)
SELECT
  scenario,
  scenario_namn,
  metric,
  weight_raw,
  SUM(weight_raw) OVER (PARTITION BY scenario)                    AS weight_sum,
  weight_raw / SUM(weight_raw) OVER (PARTITION BY scenario)       AS weight,
  COUNT(*) OVER (PARTITION BY scenario, metric)                   AS n_same_pair,
  COUNT(*) OVER (PARTITION BY scenario)                           AS n_metrics
FROM w;

-- Robustness variants: each swaps one metric or switches the cost factor off (method §5)
CREATE OR REFRESH MATERIALIZED VIEW gold.param_variant (
  CONSTRAINT swap_is_pair  EXPECT ((swap_from IS NULL) = (swap_to IS NULL))                                ON VIOLATION FAIL UPDATE,
  CONSTRAINT swap_from_ok  EXPECT (COALESCE(swap_from IN ('ev_demand', 'growth', 'price', 'supply'), true)) ON VIOLATION FAIL UPDATE,
  CONSTRAINT cost_flag_set EXPECT (use_cost_factor IS NOT NULL)                                             ON VIOLATION FAIL UPDATE
)
COMMENT 'Robustness variants. Runs = scenarios × variants; blank swap = no metric swap (NULLIF, finding 64).'
AS
SELECT
  variant,
  variant_namn,
  NULLIF(swap_from, '')                      AS swap_from,
  NULLIF(swap_to, '')                        AS swap_to,
  try_cast(use_cost_factor AS BOOLEAN)       AS use_cost_factor
FROM bronze.seed_param_variant;

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