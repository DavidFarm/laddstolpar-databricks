# tools/map_region_check.py – which of our 290 kommuner can the AI/BI "County/City" choropleth draw?
import csv

with open("seeds/nvdb_trafik_kommun.csv", encoding="utf-8") as f:
    ours = {r["kommun_kod"]: r["kommun_namn"] for r in csv.DictReader(f)}
with open("trafik/county-district-names.csv", encoding="utf-8-sig") as f:
    se = [r for r in csv.DictReader(f) if r["country_2_letter"] == "SE"]

print(f"Map lookup: {len(se)} Swedish rows | ours: {len(ours)} kommuner")
by_code = {}
for r in se:
    by_code.setdefault(r["country_specific_code"], []).append(r["name"])

ok        = [k for k in ours if k in by_code and ours[k] in by_code[k]]
code_only = [(k, ours[k], by_code[k]) for k in ours if k in by_code and ours[k] not in by_code[k]]
missing   = [(k, ours[k]) for k in ours if k not in by_code]
extra     = [(c, n) for c, n in by_code.items() if c not in ours]

print(f"Code and name match: {len(ok)} | code matches, name differs: {len(code_only)} | "
      f"our code missing: {len(missing)} | map codes not ours: {len(extra)}")
print("\nCode matches, name differs (first 20):", code_only[:20])
print("\nOur kommuner missing from the map (first 30):", missing[:30])
print("\nMap codes that aren't kommun codes (first 20):", extra[:20])