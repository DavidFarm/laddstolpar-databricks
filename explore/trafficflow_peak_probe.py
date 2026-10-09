"""
trafficflow_peak_probe.py  –  Slutprojekt Laddstolpar, David Färm (DE25)

Purpose
    One short, time-boxed probe of Trafikverket's open API object `TrafficFlow`
    during weekday peak hour, run LOCALLY (not in Azure, so no compute cost).
    Answers: how many measurement sites exist, where (county), and which sites
    carry the most traffic -> is this usable as a "main roads" signal per kommun?

Output (in ./trafficflow_probe/)
    raw_<UTC timestamp>.json   the unchanged API response per snapshot (landing format)
    flat_<UTC timestamp>.csv   one row per record, for quick inspection
    summary.txt                what to paste back into the chat

Run
    pip install requests
    export TRV_API_KEY=...         (PowerShell:  $env:TRV_API_KEY="...")
    python trafficflow_peak_probe.py                 # 3 snapshots, 5 min apart (~10 min)
    python trafficflow_peak_probe.py --snapshots 1   # single snapshot

Best time: a weekday 16:15–17:30.

Unverified (⚠️): the exact namespace/schemaversion for TrafficFlow and the exact
field names. The script probes a few combinations first and reads every field
with .get(), so a wrong guess shows up as a clear message, not a crash.
"""

import argparse
import csv
import json
import os
import sys
import time
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

import requests

URL = "https://api.trafikinfo.trafikverket.se/v2/data.json"
OUT = Path("trafficflow_probe")

# (namespace, schemaversion) candidates, tried in order until one returns data.
CANDIDATES = [
    ("Road.TrafficInfo", "1.5"),
    ("Road.TrafficInfo", "1.4"),
    (None, "1.4"),
    (None, "1.0"),
]


def build_query(key, namespace, version, minutes_back, limit):
    ns = f' namespace="{namespace}"' if namespace else ""
    # Only recent measurements: the unfiltered query returned stale cache data in Labb2.
    return f"""<REQUEST>
  <LOGIN authenticationkey="{key}"/>
  <QUERY objecttype="TrafficFlow"{ns} schemaversion="{version}" limit="{limit}">
    <FILTER>
      <GT name="MeasurementTime" value="$dateadd(-0.00:{minutes_back:02d}:00)"/>
    </FILTER>
  </QUERY>
</REQUEST>"""


def post(key, namespace, version, minutes_back=15, limit=20000):
    body = build_query(key, namespace, version, minutes_back, limit)
    r = requests.post(URL, data=body.encode("utf-8"),
                      headers={"Content-Type": "text/xml"}, timeout=60)
    try:
        payload = r.json()
    except ValueError:
        return r.status_code, None, r.text[:500]
    result = (payload.get("RESPONSE", {}).get("RESULT") or [{}])[0]
    if "ERROR" in result:
        return r.status_code, None, json.dumps(result["ERROR"], ensure_ascii=False)
    return r.status_code, payload, None


def records_of(payload):
    result = (payload.get("RESPONSE", {}).get("RESULT") or [{}])[0]
    return result.get("TrafficFlow", []) or []


def parse_wgs84(rec):
    # Expected "POINT (lon lat)" — longitude first (Labb2 lesson).
    wkt = (rec.get("Geometry") or {}).get("WGS84")
    if not wkt or "(" not in wkt:
        return None, None
    try:
        lon, lat = wkt.split("(")[1].rstrip(")").split()
        return float(lon), float(lat)
    except ValueError:
        return None, None


def county_of(rec):
    for k in ("CountyNo", "County"):
        v = rec.get(k)
        if v is not None:
            return v[0] if isinstance(v, list) and v else v
    return None


def flatten(rec):
    lon, lat = parse_wgs84(rec)
    return {
        "SiteId": rec.get("SiteId"),
        "MeasurementTime": rec.get("MeasurementTime"),
        "VehicleType": rec.get("VehicleType"),
        "VehicleFlowRate": rec.get("VehicleFlowRate"),
        "AverageVehicleSpeed": rec.get("AverageVehicleSpeed"),
        "SpecificLane": rec.get("SpecificLane"),
        "MeasurementSide": rec.get("MeasurementSide"),
        "County": county_of(rec),
        "RegionId": rec.get("RegionId"),
        "lon": lon,
        "lat": lat,
    }


def find_working_candidate(key):
    for ns, ver in CANDIDATES:
        status, payload, err = post(key, ns, ver, minutes_back=15, limit=5)
        label = f"namespace={ns!r}, schemaversion={ver}"
        if err:
            print(f"  ✗ {label}: HTTP {status} – {err[:200]}")
            continue
        n = len(records_of(payload))
        print(f"  ✓ {label}: HTTP {status}, {n} records in test call")
        if n:
            return ns, ver, records_of(payload)[0]
    return None, None, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--snapshots", type=int, default=3)
    ap.add_argument("--interval", type=int, default=300, help="seconds between snapshots")
    ap.add_argument("--minutes-back", type=int, default=15)
    args = ap.parse_args()

    key = os.environ.get("TRV_API_KEY")
    if not key:
        sys.exit("Set TRV_API_KEY first (never paste the key into the script).")

    OUT.mkdir(exist_ok=True)
    print("Step 1 – probing namespace/schemaversion:")
    ns, ver, sample = find_working_candidate(key)
    if not ver:
        sys.exit("No candidate worked. Paste the ✗ lines above into the chat.")
    print("Sample record (field names to check):")
    print(json.dumps(sample, ensure_ascii=False, indent=2)[:1500])

    all_rows = []
    deadline = time.time() + args.snapshots * args.interval + 120  # time-box
    for i in range(args.snapshots):
        if time.time() > deadline:
            print("Time-box reached, stopping.")
            break
        ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        status, payload, err = post(key, ns, ver, minutes_back=args.minutes_back)
        if err:
            print(f"Snapshot {i+1}: error {err[:200]}")
        else:
            recs = records_of(payload)
            # Raw file: unchanged response, but without the key (the key is only in the request).
            (OUT / f"raw_{ts}.json").write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
            rows = [flatten(r) | {"snapshot_utc": ts} for r in recs]
            with open(OUT / f"flat_{ts}.csv", "w", newline="", encoding="utf-8") as f:
                w = csv.DictWriter(f, fieldnames=list(rows[0].keys()) if rows else ["empty"])
                w.writeheader()
                w.writerows(rows)
            all_rows.extend(rows)
            print(f"Snapshot {i+1}/{args.snapshots} at {ts}: {len(recs)} records")
        if i < args.snapshots - 1:
            time.sleep(args.interval)

    # ---------- summary ----------
    sites = {r["SiteId"] for r in all_rows if r["SiteId"] is not None}
    counties = Counter()
    site_county = {}
    for r in all_rows:
        if r["SiteId"] is not None:
            site_county[r["SiteId"]] = r["County"]
    counties.update(site_county.values())
    vtypes = Counter(r["VehicleType"] for r in all_rows)

    # Per site: sum flow over lanes/sides per snapshot, then average over snapshots.
    per_site_snap = defaultdict(float)
    for r in all_rows:
        if r["SiteId"] is None or r["VehicleFlowRate"] is None:
            continue
        per_site_snap[(r["SiteId"], r["snapshot_utc"])] += float(r["VehicleFlowRate"])
    per_site = defaultdict(list)
    for (site, _snap), v in per_site_snap.items():
        per_site[site].append(v)
    avg_flow = {s: sum(v) / len(v) for s, v in per_site.items()}
    coords = {}
    for r in all_rows:
        if r["SiteId"] is not None and r["lon"] is not None:
            coords[r["SiteId"]] = (r["lon"], r["lat"])
    missing_geo = len(sites) - len(coords)

    lines = [
        f"Probe run: {datetime.now().isoformat(timespec='minutes')} (local time)",
        f"Working query: namespace={ns!r}, schemaversion={ver}",
        f"Snapshots: {len({r['snapshot_utc'] for r in all_rows})}, records total: {len(all_rows)}",
        f"Distinct sites: {len(sites)}, sites without coordinates: {missing_geo}",
        f"Sites per county (code: count): {dict(sorted(counties.items(), key=lambda x: str(x[0])))}",
        f"VehicleType values: {dict(vtypes)}",
        "",
        "Top 25 sites by average summed flow (vehicles/hour, all lanes/sides; check VehicleType before trusting):",
    ]
    for s, v in sorted(avg_flow.items(), key=lambda x: -x[1])[:25]:
        lon, lat = coords.get(s, (None, None))
        lines.append(f"  site {s}: {v:,.0f} veh/h  county {site_county.get(s)}  lon {lon} lat {lat}")
    text = "\n".join(lines)
    (OUT / "summary.txt").write_text(text, encoding="utf-8")
    print("\n" + text)
    print(f"\nFiles in {OUT.resolve()}. Paste summary.txt into the chat.")


if __name__ == "__main__":
    main()
