-- ops.nobil_coverage_check: stations per county, open-data dump (silver) vs NOBIL's own statistics
-- from the SAME landing run (finding 45). Warn only: the gap is a documented limitation.
CREATE OR REFRESH MATERIALIZED VIEW laddstolpar_df.ops.nobil_coverage_check (
  CONSTRAINT both_present     EXPECT (dump_count IS NOT NULL AND stats_count IS NOT NULL),
  CONSTRAINT same_snapshot    EXPECT (COALESCE(dump_snapshot = stats_snapshot, false)),
  CONSTRAINT dump_not_above   EXPECT (COALESCE(diff <= 0, false)),
  CONSTRAINT gap_within_limit EXPECT (COALESCE(abs(diff) <= 0.2 * stats_count, false))  -- observed max 14% (Jönköping)
)
COMMENT 'Coverage: NOBIL stations per county in the open-data dump vs NOBIL statistics from the same run.'
AS
WITH dump AS (
  SELECT k.lan_kod, count(*) AS dump_count, max(s._snapshot_date) AS dump_snapshot
  FROM laddstolpar_df.silver.nobil_station s
  JOIN laddstolpar_df.silver.kommun k USING (kommun_kod)
  WHERE s.__END_AT IS NULL
  GROUP BY k.lan_kod
),
stats AS (
  SELECT countyid AS lan_kod, county, station_count AS stats_count, _snapshot_date AS stats_snapshot
  FROM laddstolpar_df.bronze.nobil_stats_county
  WHERE _snapshot_date = (SELECT max(_snapshot_date) FROM laddstolpar_df.bronze.nobil_stats_county)
)
SELECT coalesce(d.lan_kod, st.lan_kod)                                          AS lan_kod,
       st.county,
       d.dump_count, st.stats_count,
       d.dump_count - st.stats_count                                             AS diff,
       round(try_divide(d.dump_count - st.stats_count, st.stats_count) * 100, 1) AS diff_pct,
       d.dump_snapshot, st.stats_snapshot
FROM dump d
FULL OUTER JOIN stats st ON st.lan_kod = d.lan_kod;


-- ops.nobil_quality_check: one row of structural facts about NOBIL silver. Repeats the view-level
-- rules as MV expectations, because expectation metrics are not recorded for views that feed
-- AUTO CDC FROM SNAPSHOT flows (26 Sep); this row is the evidence.
CREATE OR REFRESH MATERIALIZED VIEW laddstolpar_df.ops.nobil_quality_check (
  CONSTRAINT unique_keys             EXPECT (n_dup_station = 0 AND n_dup_connector = 0),
  CONSTRAINT all_capacity_known      EXPECT (n_unknown_capacity = 0),
  CONSTRAINT charging_has_kw         EXPECT (n_charging_without_kw = 0),
  CONSTRAINT all_inside_sweden       EXPECT (n_outside_sweden = 0),
  CONSTRAINT connectors_have_station EXPECT (n_orphan_connectors = 0)
)
COMMENT 'Structural checks on silver.nobil_station / nobil_connector (current rows), one row.'
AS
WITH s AS (SELECT * FROM laddstolpar_df.silver.nobil_station   WHERE __END_AT IS NULL),
     c AS (SELECT * FROM laddstolpar_df.silver.nobil_connector WHERE __END_AT IS NULL)
SELECT
  (SELECT count(*) FROM s)                                              AS n_stations,
  (SELECT count(*) - count(DISTINCT station_id) FROM s)                 AS n_dup_station,
  (SELECT count_if(lat IS NULL OR NOT (lat BETWEEN 55.0 AND 69.5 AND lon BETWEEN 10.5 AND 24.5)) FROM s)
                                                                        AS n_outside_sweden,
  (SELECT count_if(is_public IS NOT TRUE) FROM s)                       AS n_not_public,
  (SELECT count(*) FROM c)                                              AS n_connectors,
  (SELECT count(*) - count(DISTINCT station_id, connector_no) FROM c)   AS n_dup_connector,
  (SELECT count(*) FROM c LEFT ANTI JOIN laddstolpar_df.silver.nobil_capacity cap
     ON cap.attrvalid = c.capacity_code)                                AS n_unknown_capacity,
  (SELECT count_if(current_type IN ('AC', 'DC') AND kw IS NULL) FROM c) AS n_charging_without_kw,
  (SELECT count_if(evse_id IS NULL) FROM c)                             AS n_no_evse_id,
  (SELECT count(*) FROM c LEFT ANTI JOIN s USING (station_id))          AS n_orphan_connectors,
  (SELECT round(sum(kw) / 1000, 1) FROM c)                              AS mw_naive;