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
RE_ACCT = re.compile(r"(?:ACCOUNT NUMBER|^\s*TRACT):\s*(\w+)\s+(.+?)\s*$")
RE_OPER = re.compile(r"OPERATOR NUMBER:\s*(\d+)")
RE_CROP = re.compile(r"Crop Day:\s*(\d+)")
# 19534 111376 18.80 16.19 86.10 30.72 0.70 16.51 13.86 14.36 231.75 231.75 227.12 30.35
RE_SAMPLED = re.compile(r"^\s*(\d{3,})\s+(\d{3,})\s+((?:" + NUM + r"\s+){11}" + NUM + r")\s*$")
# 19552 30.70   (not cored: tons only)
RE_TONSONLY = re.compile(r"^\s*(\d{3,})\s+(" + NUM + r")\s*$")
# 19534 111376 09-02 54-398 06:46:35AM 07:12:50AM 50.00 19.65 30.35
RE_DAILY = re.compile(r"^\s*(\d{3,})\s+(?:(\d{3,})\s+)?(\w+)-(\w+)\s+(\S+)\s+(?:(\S+)\s+)?(\d{1,2}:\d{2}(?::\d{2})?\s*[AP]M)\s+(\d{1,2}:\d{2}(?::\d{2})?\s*[AP]M)\s+(" + NUM + r")\s+(" + NUM + r")\s+(" + NUM + r")\s*$", re.I)
RE_TOTAL = re.compile(r"TODAY TRACT TOTAL\s+((?:" + NUM + r"\s+){11}" + NUM + r")")
# the other receipt layout (TRX# TRK# TRA. HAU. TONS ...): 43441 416 285 9095 29.40 1.00 288.1 20.7 77.0 42.0 20.70 18.49 89.30 17.43 15.23 17.62 247.15 247.15
RE_SAMPLED2 = re.compile(r"^\s*(\d{3,})\s+(\w+)\s+(\w+)\s+(\w+)\s+(" + NUM + r")\s+((?:" + NUM + r"\s+){12}" + NUM + r")\s*$")
RE_TOTAL2 = re.compile(r"TODAY'?S TRACT TOTAL\s+((?:" + NUM + r"\s+){13}" + NUM + r")")


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
    if "DAILY TRANSACTION REPORT" in text.upper() and "TRACT NO" in text.upper():
        return parse_dtr(text, name)
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
            m = RE_SAMPLED2.match(ln)
            if m:
                v = [fnum(x) for x in m.group(6).split()]
                samples[m.group(1)] = {"brix": v[5], "pol": v[6], "purity": v[7], "sed": v[0],
                                       "fiber": v[10], "trs": v[11], "crs": v[12], "tonsR": fnum(m.group(5)), "acct": cur}
                continue
            m = RE_TOTAL2.search(ln)
            if m and cur is not None:
                v = [fnum(x) for x in m.group(1).split()]
                totals[cur] = {"tons": v[0], "trs": v[12], "crs": v[13], "brix": v[6]}
                continue
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
        if m.group(6) and re.match(r"^\w{1,8}$", m.group(6)): ld["trailer"] = m.group(6)     # some boards number the trailer, not the truck
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


# ---- Daily Transaction Report (Raceland Raw Sugar style). It has no scale times: the ticket numbers (062-2045)
# run in the order the mill weighed the trucks, so loads are matched in order instead of by time.
RE_DTR_HEAD = re.compile(r"^(.*?)\s+CROP DAY:\s*(\d+)\s+(\d{1,2})/(\d{1,2})/(\d{4})")
RE_DTR_PROD = re.compile(r"Producer No\.:\s*(\w+)\s+(.+?)\s*$")
RE_DTR_TRACT = re.compile(r"TRACT NO\.:\s*(\w+)(?:\s*-\s*(.+?))?(?:\s+Owner:.*|\s+CRS:.*)?\s*$")
RE_DTR_SAMPLE = re.compile(r"^\s*\d+\s+(\d+-\d+)\s+((?:" + NUM + r"\s+){13}" + NUM + r")\s*$")
RE_DTR_AVG = re.compile(r"\*\*AVERAGE\s*\*\*\s+((?:" + NUM + r"\s+){12}" + NUM + r")")
RE_DTR_LOAD = re.compile(r"^\s*\d+\s+(\d+-\d+)\s+([\d,]+)\s+([\d,]+)\s+([\d,]+)\s+(" + NUM + r")\s+(" + NUM + r")\s+([YN])\s+(\w+)\s+[\d,]+\s+(.*?)\s*\[(\w+)\]")


def parse_dtr(text, name):
    mill, crop, day, prod, pname = "", None, None, "", ""
    cur, names, samples, loads, avg = None, {}, {}, {}, {}
    for ln in text.splitlines():
        m = RE_DTR_HEAD.match(ln)
        if m and not day:
            mill, crop = m.group(1).strip(), int(m.group(2))
            day = "%04d-%02d-%02d" % (int(m.group(5)), int(m.group(3)), int(m.group(4)))
        m = RE_DTR_PROD.search(ln)
        if m and not prod: prod, pname = m.group(1), m.group(2).strip()
        m = RE_DTR_TRACT.search(ln)
        if m:
            cur = m.group(1)
            if m.group(2): names[cur] = m.group(2).strip()
            continue
        m = RE_DTR_AVG.search(ln)
        if m and cur:
            v = [fnum(x) for x in m.group(1).split()]
            avg[cur] = {"trs": v[11], "crs": v[12]}
            continue
        m = RE_DTR_SAMPLE.match(ln)
        if m:
            v = [fnum(x) for x in m.group(2).split()]
            samples[m.group(1)] = {"brix": v[4], "pol": v[5], "purity": v[6], "fiber": v[9], "trs": v[10], "crs": v[11], "sed": v[13]}
            continue
        m = RE_DTR_LOAD.match(ln)
        if m and cur:
            tk, trl, tid = m.group(1), m.group(8).lstrip("0"), m.group(10)
            # trailer 0395 + truck [395127] -> 395-127, the way trucks are numbered on the board (hauler-truck)
            truck = trl + "-" + tid[len(trl):] if trl and tid.startswith(trl) and len(tid) > len(trl) else tid
            seq = int(tk.split("-")[-1])
            ld = {"rcpt": tk, "truck": truck, "time": None, "seq": seq, "tons": fnum(m.group(5)),
                  "gross": round(fnum(m.group(2)) / 2000, 2), "tare": round(fnum(m.group(3)) / 2000, 2)}
            ld.update(samples.get(tk, {}))
            loads.setdefault(cur, []).append(ld)
    if not day: return [], "could not find the date"
    if not loads: return [], "no loads in this report"
    reps = []
    for tr, ls in loads.items():
        for ld in ls:
            if "trs" not in ld and ld["rcpt"] in samples: ld.update(samples[ld["rcpt"]])
        tons = round(sum(x["tons"] for x in ls), 2)
        reps.append({"day": day, "mill": mill, "operator": prod, "operatorName": pname, "account": tr, "accountName": names.get(tr, ""),
                     "cropDay": crop, "file": name[:120], "totals": dict({"tons": tons}, **avg.get(tr, {})), "loads": ls})
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
        fname = urllib.parse.unquote(self.headers.get("X-File-Name", "") or "")[:160]
        if fname and len(files) == 1 and files[0][0] == "report.pdf":
            files = [(fname, files[0][1])]
        if not files:
            # an email with no PDF (a reply, a note): accept it so the email service does not keep retrying
            return self._send(200, {"status": "nopdf"})
        results, notes = [], []
        for nm, data in files:
            try:
                reps, note = parse_pdf(data, nm)
            except Exception:
                reps, note = [], "could not read the PDF"
            if note: notes.append({"file": nm, "note": note})
            if not reps: continue
            # each PDF goes in with its reports, so the original can be opened from the Mill tab
            pdf64 = base64.b64encode(data).decode("ascii") if len(data) <= 8 * 1024 * 1024 else None
            if key:
                code, res = rpc("mill_report", {"p_key": key, "p_reports": reps, "p_pdf": pdf64, "p_name": nm[:160]})
            else:
                code, res = rpc("mill_report_upload", {"p_reports": reps, "p_pdf": pdf64, "p_name": nm[:160]}, token)
            if code >= 300:
                return self._send(code, res)
            results += res or []
        if not results:
            return self._send(200, {"status": "nothing", "files": notes})
        return self._send(200, {"status": "done", "results": results, "files": notes})
