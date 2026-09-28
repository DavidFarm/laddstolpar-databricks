# tools/traffic_intensity_peek.py – rank kommuner by vehicle-km per road-km (≈ mean ÅDT), local only
import csv

with open("seeds/nvdb_trafik_kommun.csv", encoding="utf-8") as f:
    rows = list(csv.DictReader(f))
for r in rows:
    km = float(r["road_km"])
    r["intensity"] = float(r["vkm_per_day"]) / km if km else 0.0
rows.sort(key=lambda r: -r["intensity"])
rank = {r["kommun_kod"]: i + 1 for i, r in enumerate(rows)}

print("Top 15 by intensity:")
for r in rows[:15]:
    print(f'  {rank[r["kommun_kod"]]:>3} {r["kommun_kod"]} {r["kommun_namn"]:<18} {r["intensity"]:>7,.0f}  road {float(r["road_km"]):>6,.0f} km')
print("\nSpot checks (rank of 290):")
for kod in ("0180", "1480", "1280", "0680", "0480", "0360", "1440", "2023", "2321", "2463", "2584", "0183"):
    r = next(r for r in rows if r["kommun_kod"] == kod)
    print(f'  {rank[kod]:>3} {kod} {r["kommun_namn"]:<18} {r["intensity"]:>7,.0f}')