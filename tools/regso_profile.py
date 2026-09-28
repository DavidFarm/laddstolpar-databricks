# tools/regso_profile.py – layers, SRS, columns and rough detail level of the RegSO GeoPackage
import sqlite3, sys

path = sys.argv[1] if len(sys.argv) > 1 else "trafik/RegSO_2025.gpkg"
con = sqlite3.connect(path)

for t, dt, srs in con.execute("SELECT table_name, data_type, srs_id FROM gpkg_contents"):
    n = con.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0]
    cols = con.execute(f'PRAGMA table_info("{t}")').fetchall()
    first = con.execute(f'SELECT * FROM "{t}" LIMIT 1').fetchone()
    print(f"{t} ({dt}, srs_id={srs}), rows={n}")
    print("  columns:", ", ".join(f"{c[1]}:{c[2]}" for c in cols))
    print("  first row:", [v for v in first if not isinstance(v, bytes)])

for t, g in con.execute("SELECT table_name, column_name FROM gpkg_geometry_columns"):
    b = con.execute(f'SELECT SUM(LENGTH("{g}")) FROM "{t}"').fetchone()[0]
    print(f"geometry {t}.{g}: {b/1e6:.1f} MB ≈ {b//16:,} points (rough, 16 bytes per x,y)")

for r in con.execute("SELECT srs_id, organization, organization_coordsys_id, srs_name FROM gpkg_spatial_ref_sys"):
    print("SRS:", r)
con.close()