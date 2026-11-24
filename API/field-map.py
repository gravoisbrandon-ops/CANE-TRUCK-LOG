"""Cane Truck Log: a farm's field map (Yote Farmview export) read into the fields the Farm tab shows.

POST /api/field-map with the file as the body: a zipped shapefile (.shp + .dbf, .prj in latitude/longitude) or a
GeoJSON file. Returns {"fields": [...], "tracks": [...], "count": n}. Each field: track, field, variety, stubble
(the file's own label), acres, c (center, [lat, lon]) and g (outline rings, [[lon, lat], ...], 6 decimals).
Nothing is saved here: the page saves the result with field_map_put after the person checks it.
"""
from http.server import BaseHTTPRequestHandler
import io, json, math, re, struct, zipfile

MAX_BYTES = 15 * 1024 * 1024
KEYS = {
    "field": ["field_id", "field", "fieldid", "field_name", "name"],
    "track": ["farm", "track", "farm_name"],
    "sub": ["sub_track", "subtrk", "subtrack"],
    "variety": ["variety", "var"],
    "stubble": ["stubble", "crop_stage", "stage"],
    "acres": ["acres", "area_ac", "acre"],
}


def pick(props, kind):
    low = {str(k).lower(): v for k, v in props.items()}
    for k in KEYS[kind]:
        if k in low and low[k] not in (None, ""):
            return low[k]
    return ""


def ring_area_centroid(r):
    a = cx = cy = 0.0
    for i in range(len(r) - 1):
        x0, y0 = r[i][0], r[i][1]; x1, y1 = r[i + 1][0], r[i + 1][1]
        f = x0 * y1 - x1 * y0; a += f; cx += (x0 + x1) * f; cy += (y0 + y1) * f
    if abs(a) < 1e-15:
        xs = [p[0] for p in r]; ys = [p[1] for p in r]
        return 0.0, (sum(xs) / len(xs), sum(ys) / len(ys))
    return a / 2, (cx / (3 * a), cy / (3 * a))


def acres_of(rings):
    # outer rings add, holes subtract; degrees to feet at this latitude
    tot = 0.0
    for r in rings:
        if len(r) < 4: continue
        lat = sum(p[1] for p in r) / len(r)
        fx = 364567.2 * math.cos(math.radians(lat)); fy = 364567.2
        a, _ = ring_area_centroid([(p[0] * fx, p[1] * fy) for p in r])
        tot += a
    return abs(tot) / 43560.0


def norm_rings(geom):
    t = geom.get("type"); c = geom.get("coordinates") or []
    polys = [c] if t == "Polygon" else c if t == "MultiPolygon" else []
    out = []
    for poly in polys:
        for ring in poly:
            rr = [[round(float(p[0]), 6), round(float(p[1]), 6)] for p in ring]
            if len(rr) >= 4: out.append(rr)
    return out


def feature(props, rings):
    field = str(pick(props, "field")).strip()
    track = str(pick(props, "track")).strip()
    sub = str(pick(props, "sub")).strip()
    if not field or not rings: return None
    best = max(rings, key=lambda r: abs(ring_area_centroid(r)[0]))
    _, (cx, cy) = ring_area_centroid(best)
    try: acres = float(pick(props, "acres") or 0)
    except ValueError: acres = 0
    if not acres > 0: acres = acres_of(rings)
    if not (-180 <= cx <= 180 and -90 <= cy <= 90): return None
    return {"track": track, "sub": sub, "field": field, "variety": str(pick(props, "variety")).strip(),
            "stubble": str(pick(props, "stubble")).strip(), "acres": round(acres, 2),
            "c": [round(cy, 6), round(cx, 6)], "g": rings}


def from_geojson(j):
    fs = j.get("features") if j.get("type") == "FeatureCollection" else [j] if j.get("type") == "Feature" else []
    return [x for x in (feature(f.get("properties") or {}, norm_rings(f.get("geometry") or {})) for f in fs) if x]


def read_dbf(b):
    n = struct.unpack("<I", b[4:8])[0]; hl, rl = struct.unpack("<HH", b[8:12])
    flds, i = [], 32
    while i < hl - 1 and b[i] != 0x0D:
        nm = b[i:i + 11].split(b"\0")[0].decode("latin1"); ln = b[i + 16]; flds.append((nm, ln)); i += 32
    rows = []
    for r in range(n):
        o = hl + r * rl
        if b[o:o + 1] == b"*": rows.append(None); continue     # a deleted record
        o += 1; rec = {}
        for nm, ln in flds:
            raw = b[o:o + ln]
            try: v = raw.decode("utf-8").strip()
            except UnicodeDecodeError: v = raw.decode("latin1").strip()
            rec[nm] = v.replace("\x19", "'"); o += ln
        rows.append(rec)
    return rows


def read_shp(b):
    shapes, o = [], 100
    while o + 8 <= len(b):
        ln = struct.unpack(">i", b[o + 4:o + 8])[0] * 2; rec = b[o + 8:o + 8 + ln]; o += 8 + ln
        st = struct.unpack("<i", rec[0:4])[0] if len(rec) >= 4 else 0
        if st not in (5, 15, 25):     # polygons (plain, Z, M)
            shapes.append([]); continue
        nparts, npts = struct.unpack("<ii", rec[36:44])
        parts = list(struct.unpack("<%di" % nparts, rec[44:44 + 4 * nparts])) + [npts]
        p0 = 44 + 4 * nparts
        pts = [struct.unpack("<dd", rec[p0 + 16 * k:p0 + 16 * k + 16]) for k in range(npts)]
        shapes.append([[[round(x, 6), round(y, 6)] for x, y in pts[parts[k]:parts[k + 1]]] for k in range(nparts)])
    return shapes


def from_zip(data):
    z = zipfile.ZipFile(io.BytesIO(data))
    names = [n for n in z.namelist() if not n.startswith("__MACOSX")]
    shp = [n for n in names if n.lower().endswith(".shp")]
    if not shp: raise ValueError("no .shp file in the zip")
    out = []
    for s in shp:
        base = s[:-4]
        dbf = next((n for n in names if n.lower() == (base + ".dbf").lower()), None)
        prj = next((n for n in names if n.lower() == (base + ".prj").lower()), None)
        if not dbf: raise ValueError("the zip has " + s + " but no .dbf with the field names")
        if prj:
            p = z.read(prj).decode("latin1", "replace")
            if p.strip().upper().startswith("PROJCS"):
                raise ValueError("this shapefile is projected (" + p.split('"')[1] + "). Export it in latitude/longitude (WGS 84) instead.")
        shapes = read_shp(z.read(s)); rows = read_dbf(z.read(dbf))
        for g, props in zip(shapes, rows):
            if props is None or not g: continue
            f = feature(props, [r for r in g if len(r) >= 4])
            if f: out.append(f)
    return out


def convert(data):
    if data[:2] == b"PK":
        fs = from_zip(data)
    else:
        try: j = json.loads(data.decode("utf-8-sig"))
        except Exception: raise ValueError("send a zipped shapefile or a .geojson file")
        fs = from_geojson(j)
    if not fs: raise ValueError("no fields with an ID and an outline were found in this file")
    if len(fs) > 3000: raise ValueError("too many fields in one file (over 3,000)")
    return {"fields": fs, "count": len(fs), "tracks": sorted({f["track"] for f in fs if f["track"]})}


class handler(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        b = json.dumps(obj, separators=(",", ":")).encode("utf-8")
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0 or n > MAX_BYTES: return self._send(400, {"error": "no file, or the file is too big"})
        try: return self._send(200, convert(self.rfile.read(n)))
        except Exception as e: return self._send(400, {"error": str(e) or "could not read that file"})
