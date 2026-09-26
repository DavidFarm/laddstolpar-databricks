-- ops.scb_riket_check: sum over the 290 kommuner vs Riket, per SCB table, dimension, measure and period.
-- Silver holds only kommuner, so Riket ('00') is read from bronze, from the SAME landing file
-- as the kommun values: both sides come from one SCB delivery.
-- Non-additive measures are excluded: TAB628 BE0101U1 (inh/km²), TAB3276 per-1,000 categories (finding 42).
-- unallocated are cars in riket but not in län/kommun

CREATE OR REFRESH MATERIALIZED VIEW laddstolpar_df.ops.scb_riket_check (
  CONSTRAINT complete_kommuner EXPECT (n_kommuner = 290),
  CONSTRAINT one_delivery      EXPECT (n_files = 1),
  CONSTRAINT within_rule       EXPECT (within_rule)
)
COMMENT 'Reconciliation: sum over the 290 kommuner vs Riket per SCB table, dimension, measure and period. Rule per row: exact / rounding / noise (2025+) / suppressed.'
AS
WITH kommun_rows AS (
  SELECT 'TAB3277' AS tabell, drivmedel_scb_kod AS dim, contentscode, period,
         CAST(antal AS DECIMAL(20,2)) AS v, _file
  FROM laddstolpar_df.silver.scb_tab3277
  WHERE __END_AT IS NULL
  UNION ALL
  SELECT 'TAB628', kon, contentscode, CAST(ar AS STRING),
         CAST(varde AS DECIMAL(20,2)), _file
  FROM laddstolpar_df.silver.scb_tab628
  WHERE __END_AT IS NULL AND contentscode <> 'BE0101U1'
  UNION ALL
  SELECT 'TAB3276', agarkategori, contentscode, CAST(ar AS STRING),
         CAST(antal AS DECIMAL(20,2)), _file
  FROM laddstolpar_df.silver.scb_tab3276
  WHERE __END_AT IS NULL AND enhet = 'antal'
),
kommun_agg AS (
  SELECT tabell, dim, contentscode, period,
         count(*)              AS n_kommuner,
         count_if(v IS NULL)   AS n_null_kommuner,
         sum(v)                AS sum_kommuner,      -- NULLs ignored
         count(DISTINCT _file) AS n_files,
         max(_file)            AS _file
  FROM kommun_rows
  GROUP BY ALL
),
riket AS (
  SELECT 'TAB3277' AS tabell, drivmedel AS dim, contentscode, tid AS period,
         CAST(value AS DECIMAL(20,2)) AS riket, _file
  FROM laddstolpar_df.bronze.scb_tab3277 WHERE region = '00'
  UNION ALL
  SELECT 'TAB628', kon, contentscode, tid, CAST(value AS DECIMAL(20,2)), _file
  FROM laddstolpar_df.bronze.scb_tab628 WHERE region = '00'
  UNION ALL
  SELECT 'TAB3276', agarkategori, contentscode, tid, CAST(value AS DECIMAL(20,2)), _file
  FROM laddstolpar_df.bronze.scb_tab3276 WHERE region = '00'
),
classified AS (
  SELECT k.*, r.riket,
         CAST(left(k.period, 4) AS INT) AS ar,
         k.sum_kommuner - r.riket       AS diff,
         CASE
           WHEN r.riket IS NULL                        THEN 'riket_missing'
           WHEN k.n_null_kommuner > 0                  THEN 'suppressed'   -- '..' cells (taxi)
           WHEN k.tabell IN ('TAB3277', 'TAB3276')     THEN 'unallocated'  -- vehicles in Riket without a kommun (finding 50)
           WHEN CAST(left(k.period, 4) AS INT) >= 2025 THEN 'noise'        -- SCB cell-key noise, TAB628 only (finding 43)
           WHEN k.contentscode = 'BE0101U3'            THEN 'rounding'     -- land area, 2 decimals per kommun
           ELSE 'exact'
         END AS regel
  FROM kommun_agg k
  LEFT JOIN riket r
    ON  r.tabell = k.tabell AND r.dim = k.dim
    AND r.contentscode = k.contentscode AND r.period = k.period
    AND r._file = k._file
)
SELECT tabell, dim, contentscode, period, ar,
       n_kommuner, n_null_kommuner, n_files,
       sum_kommuner, riket, diff,
       round(try_divide(diff, riket) * 100, 4) AS diff_pct,
       regel,
       COALESCE(
         CASE regel
           WHEN 'exact'       THEN diff = 0
           WHEN 'rounding'    THEN abs(diff) <= 0.005 * n_kommuner
           WHEN 'suppressed'  THEN diff <= 0
           WHEN 'unallocated' THEN diff <= 0 AND abs(diff) <= 0.01 * abs(riket)   -- gap ≤ 1% of Riket (observed max 0.47%)
           WHEN 'noise'       THEN abs(diff) <= 0.00001 * abs(riket)              -- observed max 9 of 10.6M
         END,
         false
       ) AS within_rule
FROM classified;

-- ops.scb_retired_code_check: retired region codes hold nothing, so dropping them loses no data.
-- 1917 = Heby's pre-2007 code (now 0331); 15/16 = former Älvsborg/Skaraborg counties (now 14). Finding 22.
-- SCB encodes "nothing" as 0 in TAB3277 and as '..' in TAB3276 (finding 24); the rule accepts either.

CREATE OR REFRESH MATERIALIZED VIEW laddstolpar_df.ops.scb_retired_code_check (
  CONSTRAINT holds_nothing EXPECT (COALESCE(holds_nothing, false))
)
COMMENT 'Retired region codes (1917, 15, 16) in the SCB bronze tables: no positive values, every NULL marked.'
AS
WITH r AS (
  SELECT 'TAB3277' AS tabell, region, value, status
  FROM laddstolpar_df.bronze.scb_tab3277 WHERE region IN ('1917', '15', '16')
  UNION ALL
  SELECT 'TAB3276', region, value, status
  FROM laddstolpar_df.bronze.scb_tab3276 WHERE region IN ('1917', '15', '16')
)
SELECT tabell, region,
       count(*)                                       AS n_cells,
       count_if(value = 0)                            AS n_zero,
       count_if(value IS NULL)                        AS n_null,
       count_if(value > 0)                            AS n_positive,
       count(*) > 0
         AND count_if(value > 0) = 0
         AND count_if(value IS NULL AND COALESCE(status, '') <> '..') = 0 AS holds_nothing
FROM r
GROUP BY tabell, region;