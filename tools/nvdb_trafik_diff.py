# tools/nvdb_trafik_diff.py – v1 (SCB kommun layer) vs v2 (RegSO) per kommun
import csv
import numpy as np

def load(p):
    with open(p, encoding="utf-8") as f:
        return {r["kommun_kod"]: r for r in csv.DictReader(f)}

old = load("trafik/nvdb_trafik_kommun_v1_scbkommun.csv")
new = load("seeds/nvdb_trafik_kommun.csv")
assert old.keys() == new.keys(), "kommun codes differ"

kods = sorted(new)
name = {k: new[k]["kommun_namn"] for k in kods}
n_o = np.array([int(old[k]["n_sections"]) for k in kods])
n_n = np.array([int(new[k]["n_sections"]) for k in kods])
v_o = np.array([float(old[k]["vkm_per_day"]) for k in kods])
v_n = np.array([float(new[k]["vkm_per_day"]) for k in kods])
d = v_n - v_o
with np.errstate(divide="ignore", invalid="ignore"):
    pct = np.where(v_o > 0, d / v_o, np.inf)

print("Zero sections  v1:", [(kods[i], name[kods[i]]) for i in np.where(n_o == 0)[0]])
print("Zero sections  v2:", [(kods[i], name[kods[i]]) for i in np.where(n_n == 0)[0]])
print(f"Kommuner changed: {(d != 0).sum()} of 290 | sections moved ≈ {np.abs(n_n - n_o).sum() // 2:,} "
      f"| Σ|Δ| = {np.abs(d).sum() / 1e6:.2f} M vkm/d of {v_n.sum() / 1e6:.1f} M")

edges = [0, 0.01, 0.05, 0.10, 0.25, np.inf]
labels = ["<1%", "1–5%", "5–10%", "10–25%", "≥25%"]
a = np.abs(pct[d != 0])
print("|Δ%| among changed:", {labels[i]: int(((a >= edges[i]) & (a < edges[i + 1])).sum()) for i in range(5)})

r_o, r_n = np.argsort(np.argsort(v_o)), np.argsort(np.argsort(v_n))
print(f"Spearman ρ(v1, v2) = {np.corrcoef(r_o, r_n)[0, 1]:.4f} | max rank shift = {np.abs(r_n - r_o).max()}")

def show(title, idx):
    print(f"\n{title}")
    for i in idx:
        print(f"  {kods[i]} {name[kods[i]]:<18} {v_o[i] / 1e3:>7,.0f} → {v_n[i] / 1e3:>7,.0f} k  "
              f"Δ {d[i] / 1e3:>+7,.0f} k  ({100 * pct[i]:>+6.1f}%)  sections {n_o[i]} → {n_n[i]}")

show("Top 12 by |Δ| (absolute):", np.argsort(-np.abs(d))[:12])
show("Top 12 by |Δ%| (relative, v1 > 0):", [i for i in np.argsort(-np.abs(np.where(np.isfinite(pct), pct, 0))) if d[i] != 0][:12])