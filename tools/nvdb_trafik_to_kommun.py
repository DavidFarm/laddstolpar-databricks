"""Aggregate NVDB 'Trafik' (traffic flow on state roads) to kommun level -> seed CSV.

Local only, no Azure. Standard library + numpy + pyshp (pure Python), because GDAL-based
packages are blocked by Windows Application Control on this machine.

Inputs (both in the git-ignored trafik/ folder):
  trafik/*.gpkg                      Trafikverket Lastkajen, dataprodukt Trafik (SWEREF99 TM), CC0
  trafik/scb_granser/**/Kommun*.shp  SCB kommun borders (SWEREF99 TM), CC0  -- or the Kommun*.zip itself
  trafik/scb_granser/RegSO*.gpkg  SCB RegSO 2025 areas (SWEREF99 TM), CC0 -- kommun geometry; Kommun*.shp only for names
Output (committed, feeds 04_seeds):
  seeds/nvdb_trafik_kommun.csv

Method: each road section is assigned to the kommun that contains its midpoint (measured
along the line). Vehicle-km per day = section length (km) x ÅDT (all vehicles). Divided roads
are stored as two carriageways with per-direction flows, so both are summed (checked 2026-09-27).
Borders come from RegSO 2025.

Run from the repo root:  python tools/nvdb_trafik_to_kommun.py
"""
import csv
import math
import sqlite3
import struct
import sys
import time
from pathlib import Path

import numpy as np
import shapefile  # pyshp

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

TRAFIK = Path("trafik")
OUT = Path("seeds") / "nvdb_trafik_kommun.csv"
MEASURED = {"Stickprovsmätning", "Helårsmätning"}
FALLBACK_M = 2_000          # max distance (m) for assigning a midpoint outside all kommun polygons


# ---------------- GeoPackage geometry -> list of (n, 2) coordinate arrays ----------------
def _wkb_parts(buf, pos, out):
    e = "<" if buf[pos] == 1 else ">"
    gtype = struct.unpack_from(e + "I", buf, pos + 1)[0]
    pos += 5
    has_z = bool(gtype & 0x80000000) or (gtype % 10000) // 1000 in (1, 3)
    has_m = bool(gtype & 0x40000000) or (gtype % 10000) // 1000 in (2, 3)
    base = (gtype & 0x0FFFFFFF) % 1000
    dims = 2 + has_z + has_m
    if base == 2:  # LineString
        n = struct.unpack_from(e + "I", buf, pos)[0]
        pos += 4
        vals = struct.unpack_from(e + "d" * (n * dims), buf, pos)
        pos += 8 * n * dims
        out.append(np.array(vals, dtype=float).reshape(n, dims)[:, :2])
        return pos
    if base == 3:  # Polygon: rings (outer + holes), each closed
        n_rings = struct.unpack_from(e + "I", buf, pos)[0]
        pos += 4
        for _ in range(n_rings):
            n = struct.unpack_from(e + "I", buf, pos)[0]
            pos += 4
            vals = struct.unpack_from(e + "d" * (n * dims), buf, pos)
            pos += 8 * n * dims
            out.append(np.array(vals, dtype=float).reshape(n, dims)[:, :2])
        return pos
    if base in (5, 6, 7):  # MultiLineString, MultiPolygon, GeometryCollection
        n = struct.unpack_from(e + "I", buf, pos)[0]
        pos += 4
        for _ in range(n):
            pos = _wkb_parts(buf, pos, out)
        return pos
    raise ValueError(f"Unsupported WKB geometry type {gtype}")


def gpkg_parts(blob):
    if blob is None or blob[:2] != b"GP" or blob[3] & 0b100000:
        return []
    env_bytes = {0: 0, 1: 32, 2: 48, 3: 48, 4: 64}[(blob[3] >> 1) & 0b111]
    parts = []
    _wkb_parts(blob, 8 + env_bytes, parts)
    return parts


def midpoint(parts):
    """Point halfway along the total length of all parts (parts taken in stored order)."""
    seg_len = [np.hypot(*np.diff(p, axis=0).T) for p in parts if len(p) >= 2]
    total = sum(float(s.sum()) for s in seg_len)
    if total == 0:
        p = parts[0]
        return float(p[0, 0]), float(p[0, 1]), 0.0
    half, walked = total / 2, 0.0
    for p, s in zip([p for p in parts if len(p) >= 2], seg_len):
        for i, L in enumerate(s):
            if walked + L >= half:
                t = (half - walked) / L if L else 0.0
                x = p[i, 0] + t * (p[i + 1, 0] - p[i, 0])
                y = p[i, 1] + t * (p[i + 1, 1] - p[i, 1])
                return float(x), float(y), total
            walked += L
    p = parts[-1]
    return float(p[-1, 0]), float(p[-1, 1]), total


# ---------------- kommun polygons ----------------
def find_kommun_source():
    shp = sorted(p for p in (TRAFIK / "scb_granser").rglob("*.shp") if "kommun" in p.name.lower())
    if shp:
        return shp[0]
    zips = sorted(p for p in (TRAFIK / "scb_granser").rglob("*.zip") if "kommun" in p.name.lower())
    if zips:
        return zips[0]
    raise FileNotFoundError("No Kommun*.shp or Kommun*.zip under trafik/scb_granser/")


def load_kommuner(src):
    for enc in ("utf-8", "latin-1"):          # SCB's .dbf may be UTF-8 or Latin-1 (å, ä, ö in names)
        try:
            r = shapefile.Reader(str(src), encoding=enc)
            recs = r.records()
            break
        except (UnicodeDecodeError, shapefile.ShapefileException):   # pyshp 3 raises its own dbfFileException
            continue
    fields = [f[0] for f in r.fields[1:]]
    print(f"Kommun layer: {src.name} | {len(r)} records | encoding {enc} | fields: {fields}")
    # code field: the one whose values are all 4-digit strings/numbers; name field: first text field that isn't the code
    code_f = next(f for f in fields if all(str(rec[f]).strip().zfill(4).isdigit() and len(str(rec[f]).strip()) <= 4 for rec in recs))
    name_f = next((f for f in fields if f != code_f and isinstance(recs[0][f], str)), None)
    print(f"  using code field '{code_f}', name field '{name_f}'")
    kommuner = []
    for rec, shp in zip(recs, r.shapes()):
        pts = np.asarray(shp.points, dtype=float)
        bounds = list(shp.parts) + [len(pts)]
        rings = [pts[bounds[i]:bounds[i + 1]] for i in range(len(shp.parts))]
        edges = np.vstack([np.hstack([ring[:-1], ring[1:]]) for ring in rings if len(ring) >= 2])  # x1,y1,x2,y2
        kommuner.append({
            "kod": str(rec[code_f]).strip().zfill(4),
            "namn": str(rec[name_f]).strip() if name_f else "",
            "bbox": shp.bbox,             # xmin, ymin, xmax, ymax
            "edges": edges,
            "verts": pts,
        })
    print(f"  {len(kommuner)} kommuner, {sum(len(k['verts']) for k in kommuner):,} vertices")
    return kommuner

def find_regso_source():
    g = sorted((TRAFIK / "scb_granser").rglob("RegSO*.gpkg"))
    if not g:
        raise FileNotFoundError("No RegSO*.gpkg under trafik/scb_granser/")
    return g[-1]


def load_kommuner_regso(src, names):
    """Kommun polygons built from SCB RegSO 2025 areas (detailed borders, finding 70).
    Each kommun = all its RegSO polygons with their edges combined. The even-odd test over the
    combined edges equals the union: RegSO areas tile the kommun without overlap, so shared
    internal borders are crossed twice and never change the parity."""
    con = sqlite3.connect(src)
    rows = con.execute('SELECT kommunkod, sp_geometry FROM "RegSO_2025"').fetchall()
    con.close()
    rings_by_kod = {}
    for kod, blob in rows:
        rings_by_kod.setdefault(kod, []).extend(gpkg_parts(blob))
    kommuner = []
    for kod in sorted(rings_by_kod):
        rings = rings_by_kod[kod]
        verts = np.vstack(rings)
        edges = np.vstack([np.hstack([r[:-1], r[1:]]) for r in rings if len(r) >= 2])
        kommuner.append({
            "kod": kod,
            "namn": names.get(kod, ""),
            "bbox": (verts[:, 0].min(), verts[:, 1].min(), verts[:, 0].max(), verts[:, 1].max()),
            "edges": edges,
            "verts": verts,
        })
    print(f"RegSO layer: {src.name} | {len(rows):,} areas -> {len(kommuner)} kommuner, "
          f"{sum(len(k['verts']) for k in kommuner):,} vertices")
    return kommuner

def points_in_polygon(px, py, edges, chunk_pts=1000, chunk_edges=20000):
    """Even-odd rule over all rings (holes and islands handled). Returns a bool array."""
    inside = np.zeros(len(px), dtype=bool)
    for i in range(0, len(px), chunk_pts):
        x = px[i:i + chunk_pts, None]
        y = py[i:i + chunk_pts, None]
        crossings = np.zeros(x.shape[0], dtype=np.int64)
        for j in range(0, len(edges), chunk_edges):
            x1, y1, x2, y2 = (edges[j:j + chunk_edges, k][None, :] for k in range(4))
            straddle = (y1 > y) != (y2 > y)
            with np.errstate(divide="ignore", invalid="ignore"):
                x_cross = x1 + (y - y1) * (x2 - x1) / (y2 - y1)
            crossings += np.count_nonzero(straddle & (x < x_cross), axis=1)
        inside[i:i + chunk_pts] = crossings % 2 == 1
    return inside


def dist_to_edges(x, y, edges):
    """Shortest distance from one point to any border segment (not just to the corners)."""
    x1, y1, x2, y2 = edges.T
    dx, dy = x2 - x1, y2 - y1
    seg2 = dx * dx + dy * dy
    with np.errstate(divide="ignore", invalid="ignore"):
        t = np.clip(np.where(seg2 > 0, ((x - x1) * dx + (y - y1) * dy) / seg2, 0.0), 0.0, 1.0)
    return float(np.min(np.hypot(x1 + t * dx - x, y1 + t * dy - y)))


# ---------------- main ----------------
t0 = time.time()
gpkg = sorted(TRAFIK.glob("*.gpkg"))[-1]
con = sqlite3.connect(gpkg)
table, geom_col = con.execute(
    "SELECT c.table_name, g.column_name FROM gpkg_contents c JOIN gpkg_geometry_columns g USING (table_name) "
    "WHERE c.data_type = 'features'").fetchone()
betraktelse = next((ln.split(":", 1)[1].strip() for p in TRAFIK.glob("Leveransinformation*.txt")
                    for ln in p.read_text(encoding="utf-8", errors="replace").splitlines()
                    if ln.startswith("Betraktelsedatum")), "")
print(f"Traffic: {gpkg.name} | layer {table} | betraktelsedatum {betraktelse or 'unknown'}")

rows = con.execute(
    f'SELECT "{geom_col}", EXTENT_LENGTH, Adt_samtliga_fordon, Adt_tunga_fordon, Matmetod, Matarsperiod FROM "{table}"'
).fetchall()
con.close()

mx, my, length_m, adt, adt_heavy, measured, year = [], [], [], [], [], [], []
n_nogeom = 0
for blob, ext_len, a, a_h, method, period in rows:
    parts = gpkg_parts(blob)
    if not parts:
        n_nogeom += 1
        continue
    x, y, geom_len = midpoint(parts)
    mx.append(x)
    my.append(y)
    length_m.append(ext_len if ext_len is not None else geom_len)
    adt.append(a if a is not None else np.nan)
    adt_heavy.append(a_h if a_h is not None else np.nan)
    measured.append(method in MEASURED)
    year.append(period // 100 if period else np.nan)
mx, my = np.array(mx), np.array(my)
length_km = np.array(length_m) / 1000
adt, adt_heavy = np.array(adt, dtype=float), np.array(adt_heavy, dtype=float)
measured, year = np.array(measured), np.array(year, dtype=float)
vkm = length_km * adt
print(f"  {len(rows):,} sections read, {n_nogeom} without geometry, {len(mx):,} midpoints "
      f"({time.time() - t0:.0f} s)")

names = {k["kod"]: k["namn"] for k in load_kommuner(find_kommun_source())}   # names + code cross-check only
kommuner = load_kommuner_regso(find_regso_source(), names)
assert set(names) == {k["kod"] for k in kommuner}, "RegSO kommun codes differ from the kommun layer"

# Point-in-polygon, candidates by bbox first
owner = np.full(len(mx), -1)
n_hits = np.zeros(len(mx), dtype=int)
for ki, k in enumerate(kommuner):
    xmin, ymin, xmax, ymax = k["bbox"]
    cand = np.where((mx >= xmin) & (mx <= xmax) & (my >= ymin) & (my <= ymax))[0]
    if len(cand) == 0:
        continue
    # hit = cand[points_in_polygon(mx[cand], my[cand], k["edges"])]
    hit = cand[points_in_polygon(mx[cand], my[cand], k["edges"], chunk_pts=250)]
    n_hits[hit] += 1
    owner[hit] = np.where(owner[hit] == -1, ki, owner[hit])   # first match wins
print(f"  point-in-polygon done ({time.time() - t0:.0f} s): "
      f"{(n_hits == 1).sum():,} in exactly one kommun, {(n_hits > 1).sum():,} in more than one, "
      f"{(n_hits == 0).sum():,} in none")

# Fallback: midpoints just outside every polygon (coastline generalisation, bridges) -> nearest vertex within FALLBACK_M
outside = np.where(owner == -1)[0]
n_fallback, n_dropped = 0, 0
for i in outside:
    best, best_d = -1, FALLBACK_M
    for ki, k in enumerate(kommuner):
        xmin, ymin, xmax, ymax = k["bbox"]
        if not (xmin - FALLBACK_M <= mx[i] <= xmax + FALLBACK_M and ymin - FALLBACK_M <= my[i] <= ymax + FALLBACK_M):
            continue
        d = dist_to_edges(mx[i], my[i], k["edges"])
        if d < best_d:
            best, best_d = ki, d
    if best >= 0:
        owner[i] = best
        n_fallback += 1
    else:
        n_dropped += 1
print(f"  fallback: {n_fallback} assigned to the nearest kommun within {FALLBACK_M} m, {n_dropped} dropped "
      f"({length_km[owner == -1].sum():,.1f} km, {np.nansum(vkm[owner == -1]) / 1e6:,.3f} M vehicle-km/day)")

# Aggregate per kommun (all kommuner, zero where no state road)
out_rows = []
for ki, k in enumerate(kommuner):
    m = owner == ki
    v = vkm[m]
    ok = ~np.isnan(v)
    vkm_sum = float(np.nansum(v))
    out_rows.append({
        "kommun_kod": k["kod"],
        "kommun_namn": k["namn"],
        "n_sections": int(m.sum()),
        "road_km": round(float(length_km[m].sum()), 3),
        "vkm_per_day": round(vkm_sum, 1),
        "vkm_heavy_per_day": round(float(np.nansum(length_km[m] * adt_heavy[m])), 1),
        "max_adt": int(np.nanmax(adt[m])) if ok.any() else 0,
        "vkm_share_measured": round(float(np.nansum(v[measured[m]]) / vkm_sum), 4) if vkm_sum else 0,
        "vkm_weighted_year": round(float(np.nansum(v * year[m]) / np.nansum(v[~np.isnan(year[m])])), 1) if vkm_sum else 0,
        "n_sections_no_adt": int((~ok).sum()),
        "betraktelsedatum": betraktelse,
    })
out_rows.sort(key=lambda r: r["kommun_kod"])

OUT.parent.mkdir(exist_ok=True)
with OUT.open("w", encoding="utf-8", newline="") as f:          # UTF-8 without BOM (finding 66)
    w = csv.DictWriter(f, fieldnames=list(out_rows[0]))
    w.writeheader()
    w.writerows(out_rows)

# ---------------- checks ----------------
tot_in_km, tot_in_vkm = length_km.sum(), np.nansum(vkm)
tot_out_km = sum(r["road_km"] for r in out_rows)
tot_out_vkm = sum(r["vkm_per_day"] for r in out_rows)
print(f"\nWrote {OUT} ({len(out_rows)} kommuner) in {time.time() - t0:.0f} s")
print(f"Totals in  : {tot_in_km:,.0f} km, {tot_in_vkm / 1e6:,.1f} M vehicle-km/day")
print(f"Totals out : {tot_out_km:,.0f} km, {tot_out_vkm / 1e6:,.1f} M vehicle-km/day "
      f"({100 * tot_out_vkm / tot_in_vkm:.2f}% of input)")
print(f"Kommuner with no state road section: {sum(r['n_sections'] == 0 for r in out_rows)}")
print(f"Duplicate kommun codes: {len(out_rows) - len({r['kommun_kod'] for r in out_rows})}")
print("\nTop 10 by vehicle-km per day:")
for r in sorted(out_rows, key=lambda r: -r["vkm_per_day"])[:10]:
    print(f"  {r['kommun_kod']} {r['kommun_namn']:<18} {r['vkm_per_day'] / 1e3:>9,.0f} k vkm/d  "
          f"{r['road_km']:>7,.0f} km  max ÅDT {r['max_adt']:>6,}")
print("\nSpot checks:")
for kod in ("0180", "0680", "1480", "2023", "2321", "2584", "2463"):
    r = next((r for r in out_rows if r["kommun_kod"] == kod), None)
    if r:
        print(f"  {kod} {r['kommun_namn']:<18} {r['vkm_per_day'] / 1e3:>9,.0f} k vkm/d  {r['road_km']:>7,.0f} km  "
              f"max ÅDT {r['max_adt']:>6,}  measured {100 * r['vkm_share_measured']:.0f}%  year {r['vkm_weighted_year']}")
