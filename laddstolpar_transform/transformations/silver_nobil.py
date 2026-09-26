# silver_nobil.py
# NOBIL chargers in silver: station facts and connector facts.
# AUTO CDC FROM SNAPSHOT, SCD 2 (stations/connectors that disappear from NOBIL get __END_AT).
# Silver = facts only. Business rules (EVSE rule, car/van filter, is_fast/is_ultra, public only)
# are applied in gold (design 0.1, 2026-09-26).

from pyspark import pipelines as dp

BRONZE   = "laddstolpar_df.bronze.nobil_stations"
KOMMUN   = "laddstolpar_df.silver.kommun"
CAPACITY = "laddstolpar_df.silver.nobil_capacity"

# Latest complete snapshot only. Explicit filter to Swedish 4-digit kommun codes: this drops the
# 10 Danish stations tagged SWE (3-digit codes, finding 46); known_kommun then proves the rest are real.
LATEST_SWEDISH = f"""
  SELECT b.*, k.kommun_kod AS known_kommun_kod
  FROM {BRONZE} b
  LEFT JOIN {KOMMUN} k ON k.kommun_kod = b.csmd:Municipality_ID::string
  WHERE b._snapshot_date = (SELECT max(_snapshot_date) FROM {BRONZE})
    AND b.csmd:Land_code::string = 'SWE'
    AND length(b.csmd:Municipality_ID::string) = 4
"""

# ---------- stations ----------

@dp.temporary_view(name="nobil_station_checked")
@dp.expect_or_fail("known_kommun", "kommun_i_listan")
@dp.expect_or_fail("unique_station", "n_rows_station = 1")
@dp.expect_or_fail("valid_station_id", "station_id IS NOT NULL")
@dp.expect("position_parsed", "lat IS NOT NULL AND lon IS NOT NULL")
@dp.expect("inside_sweden", "lat BETWEEN 55.0 AND 69.5 AND lon BETWEEN 10.5 AND 24.5")  # also catches lat/lon swapped (finding 34)
@dp.expect("availability_present", "availability_code IS NOT NULL")
@dp.expect("status_operational", "station_status = 1")                                  # dump returns only status 1 (finding 45)
def nobil_station_checked():
    return spark.sql(f"""
      WITH s AS ({LATEST_SWEDISH}),
      p AS (SELECT s.*, split(regexp_replace(csmd:Position::string, '[() ]', ''), ',') AS pos FROM s)
      SELECT
        station_id,
        csmd:name::string                          AS station_name,
        csmd:Street::string                        AS street,
        csmd:House_number::string                  AS house_number,
        csmd:Zipcode::string                       AS zipcode,
        csmd:City::string                          AS postal_town,     -- postal town, NOT kommun (finding 31)
        csmd:Municipality_ID::string               AS kommun_kod,
        csmd:Owned_by::string                      AS owned_by,
        csmd:Operator::string                      AS operator,
        csmd:Number_charging_points::bigint        AS n_charging_points,  -- = connectors, not EVSEs
        csmd:Station_status::bigint                AS station_status,
        csmd:Position::string                      AS position_raw,
        try_cast(element_at(pos, 1) AS DOUBLE)     AS lat,             -- "(lat,lon)", latitude first
        try_cast(element_at(pos, 2) AS DOUBLE)     AS lon,
        attr:st['2'].attrvalid::string             AS availability_code,
        attr:st['2'].attrvalid::string = '1'       AS is_public,       -- 1 = Public (attributes.php)
        csmd:Created::string                       AS created_raw,     -- no timezone in source
        csmd:Updated::string                       AS updated_raw,
        count(*) OVER (PARTITION BY station_id)    AS n_rows_station,
        known_kommun_kod IS NOT NULL               AS kommun_i_listan,
        _snapshot_date, _rights, _file, _ingested_at
      FROM p
    """)

@dp.temporary_view(name="nobil_station_src")
def nobil_station_src():
    return spark.read.table("nobil_station_checked").drop("kommun_i_listan", "n_rows_station")

dp.create_streaming_table(
    name="nobil_station",
    comment="NOBIL charging stations in Sweden (latest snapshot), one row per station. Facts only; SCD 2.",
)
dp.create_auto_cdc_from_snapshot_flow(
    target="nobil_station",
    source="nobil_station_src",
    keys=["station_id"],
    stored_as_scd_type=2,
    track_history_except_column_list=["created_raw", "updated_raw",
                                      "_snapshot_date", "_rights", "_file", "_ingested_at"],
)

# ---------- connectors ----------

@dp.temporary_view(name="nobil_connector_checked")
@dp.expect_or_fail("known_capacity_code", "capacity_in_seed")   # add unknown codes to the seed, don't guess
@dp.expect_or_fail("unique_connector", "n_rows_connector = 1")
@dp.expect("evse_id_present", "evse_id IS NOT NULL")             # observed ~83%; warn = evidence
def nobil_connector_checked():
    return spark.sql(f"""
      WITH s AS ({LATEST_SWEDISH}),
      c AS (
        SELECT s.station_id, x.key AS connector_no, x.value AS conn,
               s._snapshot_date, s._file, s._ingested_at
        FROM s, LATERAL variant_explode(s.attr:conn) AS x
        WHERE s.known_kommun_kod IS NOT NULL
      )
      SELECT
        c.station_id,
        c.connector_no,
        nullif(conn:['28'].attrval::string, '')    AS evse_id,
        conn:['4'].attrvalid::string               AS connector_type_code,
        conn:['4'].trans::string                   AS connector_type,
        conn:['5'].attrvalid::string               AS capacity_code,
        cap.kw,                                                        -- NULL for H2
        cap.current_type,                                              -- AC / DC / H2 / ...
        conn:['17'].attrvalid::string              AS vehicle_type_code,
        conn:['17'].trans::string                  AS vehicle_type,
        conn:['20'].attrvalid::string              AS charge_mode_code,
        conn:['26'].attrvalid::string              AS energy_carrier_code,
        cap.attrvalid IS NOT NULL                  AS capacity_in_seed,
        count(*) OVER (PARTITION BY c.station_id, c.connector_no) AS n_rows_connector,
        c._snapshot_date, c._file, c._ingested_at
      FROM c
      LEFT JOIN {CAPACITY} cap ON cap.attrvalid = c.conn:['5'].attrvalid::string
    """)

@dp.temporary_view(name="nobil_connector_src")
def nobil_connector_src():
    return spark.read.table("nobil_connector_checked").drop("capacity_in_seed", "n_rows_connector")

dp.create_streaming_table(
    name="nobil_connector",
    comment="NOBIL connectors (latest snapshot), one row per station x connector, kW via silver.nobil_capacity. Facts only; SCD 2.",
)
dp.create_auto_cdc_from_snapshot_flow(
    target="nobil_connector",
    source="nobil_connector_src",
    keys=["station_id", "connector_no"],
    stored_as_scd_type=2,
    track_history_except_column_list=["_snapshot_date", "_file", "_ingested_at"],
)