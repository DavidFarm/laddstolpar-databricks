"""Second NVDB 'Trafik' check: attributes only (standard library, no geometry parsing).
Answers: why is the total length above the state-road network size (directions? history?),
how much of the flow is measured vs assessed, and are sections unique?
Run from the repo root:  python tools/nvdb_trafik_attrs.py
"""
import sqlite3
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

gpkg = sorted(Path("trafik").glob("*.gpkg"))[-1]          # latest download (v2)
con = sqlite3.connect(gpkg)
table = con.execute("SELECT table_name FROM gpkg_contents WHERE data_type = 'features'").fetchone()[0]
print(f"File: {gpkg.name} | layer: {table}\n")


def show(title, sql):
    cur = con.execute(sql)
    cols = [d[0] for d in cur.description]
    print(f"--- {title}")
    print("  " + " | ".join(cols))
    for row in cur.fetchall():
        print("  " + " | ".join(f"{v:,.1f}" if isinstance(v, float) else str(v) for v in row))
    print()


show("Sizes", f'''
    SELECT COUNT(*) AS n_rows,
           COUNT(DISTINCT Avsnittsidentitet) AS n_avsnitt,
           COUNT(DISTINCT ELEMENT_ID) AS n_elements,
           SUM(EXTENT_LENGTH) / 1000.0 AS km_extent_length
    FROM "{table}"''')

show("Validity (VALID_TO 99991231 = current)", f'''
    SELECT VALID_TO, COUNT(*) AS n, SUM(EXTENT_LENGTH) / 1000.0 AS km
    FROM "{table}" GROUP BY VALID_TO ORDER BY n DESC LIMIT 10''')

show("Direction / role / host", f'''
    SELECT DIRECTION, ROLE, ISHOST, COUNT(*) AS n, SUM(EXTENT_LENGTH) / 1000.0 AS km
    FROM "{table}" GROUP BY 1, 2, 3 ORDER BY km DESC''')

show("Rows per Avsnittsidentitet", f'''
    SELECT n_rows_per_avsnitt, COUNT(*) AS n_avsnitt
    FROM (SELECT Avsnittsidentitet, COUNT(*) AS n_rows_per_avsnitt FROM "{table}" GROUP BY 1)
    GROUP BY 1 ORDER BY 1 LIMIT 10''')

show("Measurement method", f'''
    SELECT Matmetod, COUNT(*) AS n, SUM(EXTENT_LENGTH) / 1000.0 AS km,
           SUM(EXTENT_LENGTH * Adt_samtliga_fordon) / 1e9 AS million_vehicle_km_per_day
    FROM "{table}" GROUP BY 1 ORDER BY km DESC''')

show("Measurement year (first 4 digits of Matarsperiod)", f'''
    SELECT Matarsperiod / 100 AS year, COUNT(*) AS n, SUM(EXTENT_LENGTH) / 1000.0 AS km
    FROM "{table}" GROUP BY 1 ORDER BY 1''')

show("Carriageway pairs: same flow on both sides, or per direction?", f'''
    WITH s AS (
      SELECT Avsnittsidentitet AS a, ROLE, SUM(EXTENT_LENGTH) AS len, MAX(Adt_samtliga_fordon) AS adt
      FROM "{table}" WHERE ROLE LIKE 'Syskon%' GROUP BY 1, 2)
    SELECT COUNT(*) AS n_pairs_same_section,
           SUM(f.adt = b.adt) AS same_flow_both_sides,
           AVG(1.0 * f.adt / b.adt) AS mean_ratio_fram_bak,
           SUM(f.len) / 1000.0 AS km_fram, SUM(b.len) / 1000.0 AS km_bak
    FROM s f JOIN s b ON f.a = b.a AND f.ROLE = 'Syskon fram' AND b.ROLE = 'Syskon bak' ''')

show("Highest flows (which road, which role)", f'''
    SELECT Adt_samtliga_fordon, ROLE, DIRECTION, Avsnittsidentitet, ELEMENT_ID, EXTENT_LENGTH, Matarsperiod
    FROM "{table}" ORDER BY Adt_samtliga_fordon DESC LIMIT 8''')

con.close()
