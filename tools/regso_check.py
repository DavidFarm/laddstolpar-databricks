# tools/regso_check.py – kommun coverage and actual geometry types
import sqlite3, struct, collections

con = sqlite3.connect("trafik/RegSO_2025.gpkg")
T = "RegSO_2025"

print("kommuner, blank codes, regso ids, code length min/max:",
      con.execute(f"""SELECT COUNT(DISTINCT kommunkod),
                             SUM(kommunkod IS NULL OR kommunkod = ''),
                             COUNT(DISTINCT regsokod),
                             MIN(LENGTH(kommunkod)), MAX(LENGTH(kommunkod))
                      FROM {T}""").fetchone())
print("regsokod prefix != kommunkod:",
      con.execute(f"SELECT SUM(substr(regsokod,1,4) <> kommunkod) FROM {T}").fetchone()[0])
print("Stockholm-area kommuner (0162 Danderyd, 0180 Stockholm, 0183 Sundbyberg, 0184 Solna, 0186 Lidingö):",
      con.execute(f"""SELECT kommunkod, COUNT(*) FROM {T}
                      WHERE kommunkod IN ('0162','0180','0183','0184','0186')
                      GROUP BY 1 ORDER BY 1""").fetchall())

# GPKG blob: 'GP', version, flags; envelope size from flag bits 1-3; bit 4 = empty; then WKB
ENV = {0: 0, 1: 32, 2: 48, 3: 48, 4: 64}
types, empty = collections.Counter(), 0
for (b,) in con.execute(f"SELECT sp_geometry FROM {T}"):
    flags = b[3]
    empty += (flags >> 4) & 1
    off = 8 + ENV[(flags >> 1) & 7]
    t = struct.unpack(("<" if b[off] == 1 else ">") + "I", b[off+1:off+5])[0]
    types[t] += 1
print("WKB types (3 = Polygon, 6 = MultiPolygon):", dict(types), "| empty:", empty)
con.close()