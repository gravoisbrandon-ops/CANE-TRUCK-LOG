"""Cane Truck Log: the mill's Daily Cane Receipt (PDF) in, matched to the trucks logged the day before.

POST /api/mill-report
  * From an email service or a Gmail script (no sign-in): /api/mill-report?key=mrk_...  (the portal's mill report key,
    Setup > Mill reports). The body is the PDF itself, or JSON with the email's attachments
    (Postmark: {"Attachments":[{"Name","Content"(base64),"ContentType"}]}; or {"pdf": base64} / {"pdfs": [base64, ...]}).
  * From the site's upload button: the signed-in person's token in Authorization: Bearer ..., body is the PDF.
Each PDF is read here and every tract on it is sent to the database, which puts the mill's tons and TRS on the
matching loads (see mill_report / _mr_apply in schema.sql).
"""
from http.server import BaseHTTPRequestHandler
import base64, io, json, os, re, urllib.parse, urllib.request

SUPABASE_URL = os.environ.get("SUPABASE_URL", "https://ljftmpmpejwsfmyijmkm.supabase.co").rstrip("/")
SUPABASE_KEY = os.environ.get("SUPABASE_ANON_KEY", "sb_publishable_zRr4uLcCz1N7jSgqS2j9YA_ikBH6Uxz")
MAX_BYTES = 15 * 1024 * 1024

NUM = r"-?[\d,]+\.\d+"
RE_DATE = re.compile(r"^\s*(\d{1,2})/(\d{1,2})/(\d{2,4})\s*$")
RE_ACCT = re.compile(r"ACCOUNT NUMBER:\s*(\d+)\s+(.+?)\s*$")
RE_OPER = re.compile(r"OPERATOR NUMBER:\s*(\d+)")
RE_CROP = re.compile(r"Crop Day:\s*(\d+)")
# 19534 111376 18.80 16.19 86.10 30.72 0.70 16.51 13.86 14.36 231.75 231.75 227.12 30.35
RE_SAMPLED = re.compile(r"^\s*(\d{3,})\s+(\d{3,})\s+((?:" + NUM + r"\s+){11}" + NUM + r")\s*$")
# 19552 30.70   (not cored: tons only)
RE_TONSONLY = re.compile(r"^\s*(\d{3,})\s+(" + NUM + r")\s*$")
# 19534 111376 09-02 54-398 06:46:35AM 07:12:50AM 50.00 19.65 30.35
RE_DAILY = re.compile(r"^\s*(\d{3,})\s+(?:(\d{3,})\s+)?(\d+)-(\d+)\s+(\S+)\s+(?:(\S+)\s+)?(\d{1,2}:\d{2}(?::\d{2})?\s*[AP]M)\s+(\d{1,2}:\d{2}(?::\d{2})?\s*[AP]M)\s+(" + NUM + r")\s+(" + NUM + r")\s+(" + NUM + r")\s*$", re.I)
RE_TOTAL = re.compile(r"TODAY TRACT TOTAL\s+((?:" + NUM + r"\s+){11}" + NUM + r")")


def fnum(s):
    return float(s.replace(",", ""))


def t24(s):
    s = s.replace(" ", "").upper()
    m = re.match(r"(\d{1,2}):(\d{2})(?::(\d{2}))?([AP])M", s)
    h, mi, se = int(m.group(1)), int(m.group(2)), int(m.group(3) or 0)
    if m.group(4) == "P" and h != 12: h += 12
    if m.group(4) == "A" and h == 12: h = 0
    return "%02d:%02d:%02d" % (h, mi, se)


def ymd(m):
    y = int(m.group(3)); y = y + 2000 if y < 100 else y
    return "%04d-%02d-%02d" % (y, int(m.group(1)), int(m.group(2)))


def parse_pdf(data, name=""):
    """Returns (reports, note). One report per grower-tract, each with its day and loads."""
    from pypdf import PdfReader
    reader = PdfReader(io.BytesIO(data))
    pages = [(p.extract_text() or "") for p in reader.pages]
    text = "\n".join(pages)
    if "CANE" not in text.upper() or "RECEIPT" not in text.upper().replace(" ", ""):
        return [], "not a daily cane receipt"
    day, oper, crop = None, None, None
    accts, samples, totals = {}, {}, {}
    cur = None
    for pg in pages:
        lines = pg.splitlines()
        for ln in lines[:6]:
            m = RE_DATE.match(ln)
            if m and not day: day = ymd(m)
        for ln in lines:
            m = RE_OPER.search(ln)
            if m: oper = m.group(1)
            m = RE_CROP.search(ln)
            if m and not crop: crop = int(m.group(1))
            m = RE_ACCT.search(ln)
            if m:
                cur = m.group(1); accts[cur] = m.group(2).strip(); continue
            m = RE_SAMPLED.match(ln)
            if m:
                v = [fnum(x) for x in m.group(3).split()]
                samples[m.group(1)] = {"sample": m.group(2), "brix": v[0], "pol": v[1], "purity": v[2], "sed": v[4],
                                       "fiber": v[7], "trs": v[8], "crs": v[10], "tonsR": v[11], "acct": cur}
                continue
            m = RE_TONSONLY.match(ln)
            if m and cur is not None:
                samples.setdefault(m.group(1), {"tonsR": fnum(m.group(2)), "acct": cur}); continue
            m = RE_TOTAL.search(ln)
            if m and cur is not None:
                v = [fnum(x) for x in m.group(1).split()]
                totals[cur] = {"tons": v[11], "trs": v[8], "crs": v[10], "brix": v[0]}
    if not day:   # the Daily Tons page: "Date: 11/22/26 07:23 11/21/26"
        m = re.search(r"Date:\s*\S+\s+\S+\s+(\d{1,2})/(\d{1,2})/(\d{2,4})", text)
        if m: day = ymd(m)
    loads = {}
    for ln in text.splitlines():
        m = RE_DAILY.match(ln)
        if not m: continue
        rc, op, ac = m.group(1), m.group(3), m.group(4)
        truck = m.group(5)
        ld = {"rcpt": rc, "truck": truck, "time": t24(m.group(7)), "gross": fnum(m.group(9)), "tare": fnum(m.group(10)), "tons": fnum(m.group(11))}
        s = samples.get(rc) or {}
        for k in ("sample", "brix", "pol", "purity", "sed", "fiber", "trs", "crs"):
            if k in s: ld[k] = s[k]
        loads.setdefault((op, ac), []).append(ld)
    # no Daily Tons page: nothing to match trucks with
    if not loads:
        return [], "no truck list (Daily Tons page) in this PDF"
    reps = []
    for (op, ac), ls in loads.items():
        key = ac if ac in accts else ac.lstrip("0") if ac.lstrip("0") in accts else None
        if key is None:
            key = next((k for k in accts if k.lstrip("0") == ac.lstrip("0")), None)
        reps.append({"day": day, "operator": op, "operatorName": operator_name(text, op), "account": ac,
                     "accountName": accts.get(key, "") if key else "", "cropDay": crop, "file": name[:120],
                     "totals": totals.get(key) if key else None, "loads": ls})
    return reps, None


def operator_name(text, op):
    m = re.search(r"^\s*" + re.escape(op) + r"\s+(.+?)\s*$", text, re.M)
    if m and not re.match(r"[\d.]", m.group(1)): return m.group(1)
    m = re.search(r"ACCOUNT NUMBER:[^\n]*\n\s*([^\n]+)", text)
    return m.group(1).strip() if m else ""


def pdfs_from(body, ctype):
    """The PDFs in the request: the body itself, or base64 attachments in JSON."""
    out = []
    if body[:5] == b"%PDF-":
        return [("report.pdf", body)]
    try:
        j = json.loads(body.decode("utf-8"))
    except Exception:
        return out
    atts = j.get("Attachments") or j.get("attachments") or []
    for a in atts:
        nm = a.get("Name") or a.get("name") or a.get("filename") or "attachment.pdf"
        ct = (a.get("ContentType") or a.get("contentType") or a.get("content_type") or "").lower()
        c = a.get("Content") or a.get("content") or ""
        if "pdf" not in ct and not nm.lower().endswith(".pdf"): continue
        try: out.append((nm, base64.b64decode(c)))
        except Exception: pass
    for c in ([j["pdf"]] if j.get("pdf") else []) + list(j.get("pdfs") or []):
        try: out.append((j.get("name") or "report.pdf", base64.b64decode(c)))
        except Exception: pass
    return out


def rpc(fn, args, token=None):
    h = {"Content-Type": "application/json", "apikey": SUPABASE_KEY}
    # a signed-in person's token; the older JWT-style anon key also goes here, the newer sb_publishable key does not
    if token: h["Authorization"] = "Bearer " + token
    elif SUPABASE_KEY.startswith("eyJ"): h["Authorization"] = "Bearer " + SUPABASE_KEY
    req = urllib.request.Request(SUPABASE_URL + "/rest/v1/rpc/" + fn, data=json.dumps(args).encode("utf-8"), method="POST", headers=h)
    try:
        with urllib.request.urlopen(req, timeout=50) as r:
            return r.status, json.loads(r.read().decode("utf-8") or "null")
    except urllib.error.HTTPError as e:
        try: msg = json.loads(e.read().decode("utf-8")).get("message")
        except Exception: msg = None
        return e.code, {"error": msg or ("HTTP %d" % e.code)}


class handler(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        b = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        self._send(200, {"ok": True, "what": "Cane Truck Log mill report intake. POST the Daily Cane Receipt PDF here."})

    def do_POST(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        key = (q.get("key") or [""])[0].strip()
        auth = self.headers.get("Authorization", "")
        token = auth[7:].strip() if auth.lower().startswith("bearer ") else ""
        if not key and not token:
            return self._send(401, {"error": "no key"})
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0 or n > MAX_BYTES:
            return self._send(400, {"error": "no file, or the file is too big"})
        body = self.rfile.read(n)
        files = pdfs_from(body, self.headers.get("Content-Type", ""))
        if not files:
            # an email with no PDF (a reply, a note): accept it so the email service does not keep retrying
            return self._send(200, {"status": "nopdf"})
        reports, notes = [], []
        for nm, data in files:
            try:
                r, note = parse_pdf(data, nm)
            except Exception as e:
                r, note = [], "could not read the PDF"
            reports += r
            if note: notes.append({"file": nm, "note": note})
        if not reports:
            return self._send(200, {"status": "nothing", "files": notes})
        if key:
            code, res = rpc("mill_report", {"p_key": key, "p_reports": reports})
        else:
            code, res = rpc("mill_report_upload", {"p_reports": reports}, token)
        if code >= 300:
            return self._send(code, res)
        return self._send(200, {"status": "done", "results": res, "files": notes})
