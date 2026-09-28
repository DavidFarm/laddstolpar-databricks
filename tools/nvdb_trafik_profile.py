"""Profile the NVDB 'Trafik' GeoPackage downloaded from Lastkajen.

Local only, no Azure. Standard library only (sqlite3 + struct): a GeoPackage is an
SQLite database, so no GDAL/pyogrio is needed (those DLLs are blocked by Windows
Application Control on this machine).

Run from the repo root:  python tools/nvdb_trafik_profile.py
"""
import math
import sqlite3
import statistics
import struct
from collections import Counter
from pathlib import Path
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")  # safe on a Swedish Windows console

TRAFIK = Path("trafik")


# ---------- GeoPackage geometry blob -> 2D length (metres in a projected CRS) ----------
def _wkb_length(buf, pos):
    """Return (length, new_pos, first_y) for one WKB geometry starting at pos."""
    little = buf[pos] == 1
    e = "<" if little else ">"
    gtype = struct.unpack_from(e + "I", buf, pos + 1)[0]
    pos += 5
    # dimensions: ISO (1000 = Z, 2000 = M, 3000 = ZM) or EWKB flags
    has_z = bool(gtype & 0x80000000) or (gtype % 10000) // 1000 in (1, 3)
    has_m = bool(gtype & 0x40000000) or (gtype % 10000) // 1000 in (2, 3)
    base = (gtype & 0x0FFFFFFF) % 1000
    dims = 2 + has_z + has_m

    if base == 2:  # LineString
        n = struct.unpack_from(e + "I", buf, pos)[0]
        pos += 4
        length, prev, first_y = 0.0, None, None
        for _ in range(n):
            x, y = struct.unpack_from(e + "dd", buf, pos)
            pos += 8 * dims
            if prev:
                length += math.hypot(x - prev[0], y - prev[1])
            else:
                first_y = y
            prev = (x, y)
        return length, pos, first_y
    if base in (5, 7):  # MultiLineString, GeometryCollection
        n = struct.unpack_from(e + "I", buf, pos)[0]
        pos += 4
        total, first_y = 0.0, None
        for _ in range(n):
            part, pos, y = _wkb_length(buf, pos)
            total += part
            first_y = first_y if first_y is not None else y
        return total, pos, first_y
    raise ValueError(f"Unsupported WKB geometry type {gtype}")


def gpkg_blob_length(blob):
    """GeoPackage binary header ('GP', version, flags, srs_id, envelope) + WKB -> (length, first_y)."""
    if blob is None or blob[:2] != b"GP":
        return None, None
    flags = blob[3]
    env_bytes = {0: 0, 1: 32, 2: 48, 3: 48, 4: 64}[(flags >> 1) & 0b111]
    if flags & 0b100000:  # empty geometry
        return 0.0, None
    length, _, first_y = _wkb_length(blob, 8 + env_bytes)
    return length, first_y


def north_to_lat(northing):
    """Rough latitude from a SWEREF99 TM northing (within ~0.2 deg, enough for bands)."""
    return northing / 111_180


# ---------- profile ----------
gpkg = next(TRAFIK.glob("*.gpkg"))
print(f"File: {gpkg.name}  ({gpkg.stat().st_size / 1e6:.1f} MB)")
print("Other files in folder:", [p.name for p in TRAFIK.iterdir() if p != gpkg])

con = sqlite3.connect(gpkg)
cur = con.cursor()

print("\nCoordinate systems:")
for row in cur.execute("SELECT srs_id, organization, organization_coordsys_id, srs_name FROM gpkg_spatial_ref_sys"):
    print("  ", row)

layers = cur.execute(
    "SELECT c.table_name, c.data_type, c.srs_id, c.min_x, c.min_y, c.max_x, c.max_y, g.column_name, g.geometry_type_name "
    "FROM gpkg_contents c LEFT JOIN gpkg_geometry_columns g USING (table_name)"
).fetchall()

for table, dtype, srs, minx, miny, maxx, maxy, geom_col, geom_type in layers:
    n = cur.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0]
    print(f"\n=== Layer '{table}' | {dtype} | {geom_type} | {n:,} rows | srs {srs}")
    cols = [(r[1], r[2]) for r in cur.execute(f'PRAGMA table_info("{table}")')]
    attr_cols = [c for c, _ in cols if c != geom_col]
    print("Columns:")
    for c, t in cols:
        print(f"  {c:<40} {t}")
    if minx is not None:
        print(f"Extent (layer CRS): x {minx:,.0f} to {maxx:,.0f}  y {miny:,.0f} to {maxy:,.0f}"
              f"  ~ lat {north_to_lat(miny):.1f} to {north_to_lat(maxy):.1f} if SWEREF99 TM (Sweden ~55.3 to 69.1)")

    if geom_col:
        # Length per feature, and road-km per latitude band (from each feature's first vertex)
        bands = Counter()
        total_m, n_bad, n_null = 0.0, 0, 0
        band_edges = [55, 58, 60, 62, 64, 66, 68, 70]
        for (blob,) in cur.execute(f'SELECT "{geom_col}" FROM "{table}"'):
            try:
                m, y = gpkg_blob_length(blob)
            except (ValueError, struct.error, KeyError):
                n_bad += 1
                continue
            if m is None:
                n_null += 1
                continue
            total_m += m
            if y is not None:
                lat = north_to_lat(y)
                band = next((f"{lo}-{hi}" for lo, hi in zip(band_edges, band_edges[1:]) if lo <= lat < hi), "outside")
                bands[band] += m / 1000
        print(f"Total length: {total_m / 1000:,.0f} km  (state road network ~98,500 km, to be checked)"
              + (f"  | {n_bad} geometries not parsed" if n_bad else "")
              + (f"  | {n_null} empty/non-GPKG geometries" if n_null else ""))
        if bands:
            print("km per latitude band (approx.):")
            for lo, hi in zip(band_edges, band_edges[1:]):
                print(f"  {lo}-{hi} N  {bands.get(f'{lo}-{hi}', 0):>10,.0f} km")
            if bands.get("outside"):
                print(f"  outside   {bands['outside']:>10,.0f} km")

    # Candidate attributes
    low = {c: c.lower() for c in attr_cols}
    adt = [c for c in attr_cols if "adt" in low[c] or "ådt" in low[c]]
    year = [c for c in attr_cols if any(s in low[c] for s in ("år", "matar", "mätår", "year", "period"))]
    geo = [c for c in attr_cols if any(s in low[c] for s in ("kommun", "lan", "län", "region"))]
    print("\nÅDT-like columns:", adt)
    for c in adt:
        vals = [r[0] for r in cur.execute(f'SELECT "{c}" FROM "{table}"')]
        nums = [v for v in vals if isinstance(v, (int, float))]
        nulls = sum(v is None for v in vals)
        if nums:
            print(f"  {c}: nulls {nulls:,}, min {min(nums)}, median {statistics.median(nums)}, max {max(nums)}")
        else:
            print(f"  {c}: nulls {nulls:,}, no numeric values")
    print("Year/period-like columns:", year)
    for c in year[:3]:
        top = cur.execute(f'SELECT "{c}", COUNT(*) FROM "{table}" GROUP BY 1 ORDER BY 2 DESC LIMIT 8').fetchall()
        print(f"  {c} top values: {top}")
    print("Kommun/län-like columns:", geo)

    if attr_cols:
        sel = ", ".join(f'"{c}"' for c in attr_cols)
        print("\nFirst 3 rows (attributes only):")
        for row in cur.execute(f'SELECT {sel} FROM "{table}" LIMIT 3'):
            print("  ", dict(zip(attr_cols, row)))

con.close()