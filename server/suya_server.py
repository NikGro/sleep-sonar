"""Suya-Server: Datenschutz/Impressum als Seiten und die Schnittstelle für gespendete Nächte.

Nur Python-Standardbibliothek. Hinter dem DSM-Reverse-Proxy (TLS dort), lauscht selbst nur im Heimnetz.

Schnittstelle (alles JSON-Antworten):
  POST /api/spende/nacht      Kopf: X-Spender (8 Zeichen, in der App sichtbar), X-Schluessel (geheimes Token der
                              Installation), X-Nacht (zufällige Nacht-Kennung). Inhalt: Spendenpaket (≤ MAX_BYTES).
  POST /api/spende/loeschen   Kopf: X-Spender, X-Schluessel. Löscht alle Nächte dieser Spender-Nummer.
  GET  /api/status            {"ok": true}
  GET  /api/attest/challenge  {"challenge": base64} – einmal gültig, 5 Minuten
  POST /api/attest/register   Kopf: X-Spender, X-Schluessel. Inhalt JSON {keyId, attestation, challenge} (base64).
                              Bindet einen App-Attest-Schlüssel an die Spender-Nummer.

App Attest (Apple): Ist für eine Spender-Nummer ein Schlüssel hinterlegt, braucht jede weitere Anfrage eine
Assertion (Kopf X-Assertion + X-Challenge) über "art|challenge|spender|nacht|sha256(inhalt)".
ATTEST=required: ohne App Attest gar nicht (für die App-Store-Version). ATTEST=optional: wer kann, muss.

Spender-Nummer und Schlüssel: Beim ersten Hochladen wird ein Hash des Schlüssels hinterlegt. Danach geht
Hochladen und Löschen nur mit demselben Schlüssel - wer bloß die 8-stellige Nummer kennt, kann nichts löschen.
Es werden keine IP-Adressen gespeichert; für die Mengenbegrenzung liegen sie nur kurz im Arbeitsspeicher.
"""
import base64, hashlib, hmac, json, os, re, secrets, shutil, threading, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

ROOT = os.environ.get("DATA", "/data")                 # Spenden
SITE = os.environ.get("SITE", "/site")                 # Seiten
PORT = int(os.environ.get("PORT", "8770"))
MAX_BYTES = int(os.environ.get("MAX_BYTES", str(80 * 2**20)))
KEEP_DAYS = int(os.environ.get("KEEP_DAYS", "183"))   # 6 Monate
PER_DONOR_DAY = 4                                      # Nächte je Spender und Tag
PER_IP_HOUR = 30                                       # Anfragen je Adresse und Stunde (nur im Speicher)
DAY_BYTES = 4 * 2**30                                  # höchstens 4 GB pro Tag insgesamt
MIN_FREE = 30 * 2**30                                  # mindestens 30 GB frei lassen

ATTEST = os.environ.get("ATTEST", "optional")          # off | optional | required
APP_ID = os.environ.get("APP_ID", "")                  # "TEAMID.de.nikgro.sleepsonar" – leer: App Attest aus
ATTEST_ENV = os.environ.get("ATTEST_ENV", "production")
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # mit python -I fehlt das eigene Verzeichnis
try:
    import appattest
except ImportError:                                    # ohne cryptography/cbor2 läuft der Rest trotzdem
    appattest = None
challenges = {}                                        # base64 → Ablaufzeit

ID = re.compile(r"^[0-9A-F]{8}$")
NIGHT = re.compile(r"^[0-9A-Za-z-]{8,40}$")
TOKEN = re.compile(r"^[0-9A-Za-z-]{32,64}$")
lock = threading.Lock()
ip_hits, day = {}, {"date": "", "bytes": 0}

def donor_dir(d): return os.path.join(ROOT, "spender", d)

def token_ok(d, token):
    """True, wenn der Schlüssel passt; beim ersten Mal wird er hinterlegt."""
    p = os.path.join(donor_dir(d), "schluessel.sha256")
    h = hashlib.sha256(token.encode()).hexdigest()
    if not os.path.exists(p):
        return None
    return hmac.compare_digest(open(p).read().strip(), h)

def log_event(kind, d):
    """Nur Ereignis, Spender-Nummer und Zeit - für Nachweise (z. B. erledigte Löschungen)."""
    with open(os.path.join(ROOT, "protokoll.jsonl"), "a") as f:
        f.write(json.dumps({"t": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "ereignis": kind, "spender": d}) + "\n")

def take_challenge(c):
    """einmal verwendbar und höchstens 5 Minuten alt"""
    with lock:
        exp = challenges.pop(c, 0)
    return exp > time.time()

def attest_file(d): return os.path.join(donor_dir(d), "appattest.json")

def check_attest(h, d, kind, night="", body_hash=""):
    """None = in Ordnung, sonst Fehlermeldung."""
    p = attest_file(d)
    if not os.path.exists(p):
        # Löschen geht immer (Recht auf Löschung), Hochladen in der App-Store-Version nur mit App Attest
        return "App Attest nötig" if ATTEST == "required" and kind == "nacht" else None
    a, c = h.headers.get("X-Assertion") or "", h.headers.get("X-Challenge") or ""
    if not a or not c or not take_challenge(c): return "Assertion oder Challenge fehlt"
    info = json.load(open(p))
    data = f"{kind}|{c}|{d}|{night}|{body_hash}".encode()
    try:
        info["counter"] = appattest.verify_assertion(APP_ID, info["key"], info["counter"], base64.b64decode(a), data)
    except Exception as e:
        return f"Assertion ungültig ({e})"
    with open(p + ".tmp", "w") as f: json.dump(info, f)
    os.replace(p + ".tmp", p)
    return None

def cleanup_loop():
    """Täglich: Nächte löschen, die älter als KEEP_DAYS sind."""
    while True:
        cut = time.time() - KEEP_DAYS * 86400
        base = os.path.join(ROOT, "spender")
        for d in (os.listdir(base) if os.path.isdir(base) else []):
            nd = os.path.join(base, d, "naechte")
            for f in (os.listdir(nd) if os.path.isdir(nd) else []):
                p = os.path.join(nd, f)
                if os.path.getmtime(p) < cut:
                    os.remove(p); log_event("abgelaufen", d)
        time.sleep(86400)

class H(BaseHTTPRequestHandler):
    server_version = "Suya"
    sys_version = ""

    def log_message(self, *a):   # keine Zugriffsprotokolle (keine IP-Adressen auf der Platte)
        pass

    def send(self, code, obj=None, body=None, ctype="application/json; charset=utf-8"):
        data = body if body is not None else json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:")
        self.end_headers()
        if self.command != "HEAD": self.wfile.write(data)

    def limited(self):
        ip = self.headers.get("X-Forwarded-For", self.client_address[0]).split(",")[-1].strip()   # letzter Eintrag kommt vom eigenen Proxy
        now = time.time()
        with lock:
            hits = [t for t in ip_hits.get(ip, []) if now - t < 3600]
            hits.append(now); ip_hits[ip] = hits
            if len(ip_hits) > 10000: ip_hits.clear()
            return len(hits) > PER_IP_HOUR

    # ---------- Seiten ----------
    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/") or "/"
        if path == "/api/status": return self.send(200, {"ok": True, "attest": bool(APP_ID and appattest) and ATTEST != "off"})
        if path == "/api/attest/challenge":
            if self.limited(): return self.send(429, {"fehler": "zu viele Anfragen"})
            c = base64.b64encode(secrets.token_bytes(32)).decode()
            with lock:
                now = time.time()
                for k in [k for k, v in challenges.items() if v < now]: del challenges[k]
                if len(challenges) > 5000: return self.send(503, {"fehler": "später"})
                challenges[c] = now + 300
            return self.send(200, {"challenge": c})
        pages = {"/": "index.html", "/datenschutz": "datenschutz.html", "/impressum": "impressum.html",
                 "/style.css": "style.css", "/favicon.svg": "favicon.svg"}
        f = pages.get(path)
        m = re.match(r"^/(en|es|fr|it|pt|nl|ja|ko|zh)(?:/(privacy|imprint))?$", path)
        if m: f = f"{m.group(1)}/{m.group(2) or 'index'}.html"
        if not f: return self.send(404, body=b"Nicht gefunden", ctype="text/plain; charset=utf-8")
        ctype = {"css": "text/css", "svg": "image/svg+xml"}.get(f.rsplit(".", 1)[-1], "text/html") + "; charset=utf-8"
        self.send(200, body=open(os.path.join(SITE, f), "rb").read(), ctype=ctype)
    do_HEAD = do_GET

    # ---------- Schnittstelle ----------
    def do_POST(self):
        if self.limited(): return self.send(429, {"fehler": "zu viele Anfragen"})
        d = (self.headers.get("X-Spender") or "").upper()
        token = self.headers.get("X-Schluessel") or ""
        if not ID.match(d) or not TOKEN.match(token):
            return self.send(400, {"fehler": "Spender-Nummer oder Schlüssel ungültig"})
        path = self.path.split("?")[0]
        if path == "/api/spende/nacht": return self.upload(d, token)
        if path == "/api/spende/loeschen": return self.delete(d, token)
        if path == "/api/attest/register": return self.register(d, token)
        self.send(404, {"fehler": "unbekannt"})

    def upload(self, d, token):
        night = self.headers.get("X-Nacht") or ""
        n = int(self.headers.get("Content-Length") or 0)
        if not NIGHT.match(night): return self.send(400, {"fehler": "Nacht-Kennung ungültig"})
        if n <= 0 or n > MAX_BYTES: return self.send(413, {"fehler": "Paket zu groß oder leer"})
        if shutil.disk_usage(ROOT).free < MIN_FREE + n: return self.send(507, {"fehler": "Speicher voll"})
        today = time.strftime("%Y-%m-%d", time.gmtime())
        with lock:
            if day["date"] != today: day.update(date=today, bytes=0)
            if day["bytes"] + n > DAY_BYTES: return self.send(503, {"fehler": "Tageslimit erreicht"})
            ok = token_ok(d, token)
            if ok is False: return self.send(403, {"fehler": "Schlüssel passt nicht"})
            nd = os.path.join(donor_dir(d), "naechte"); os.makedirs(nd, exist_ok=True)
            recent = [f for f in os.listdir(nd) if time.time() - os.path.getmtime(os.path.join(nd, f)) < 86400]
            if len(recent) >= PER_DONOR_DAY: return self.send(429, {"fehler": "zu viele Nächte heute"})
            if ok is None:
                open(os.path.join(donor_dir(d), "schluessel.sha256"), "w").write(hashlib.sha256(token.encode()).hexdigest())
            day["bytes"] += n
        tmp = os.path.join(nd, f".{night}.part")
        left = n
        with open(tmp, "wb") as f:
            while left:
                chunk = self.rfile.read(min(left, 1 << 20))
                if not chunk: break
                f.write(chunk); left -= len(chunk)
        if left: os.remove(tmp); return self.send(400, {"fehler": "Übertragung abgebrochen"})
        hsh = hashlib.sha256()
        with open(tmp, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""): hsh.update(chunk)
        err = check_attest(self, d, "nacht", night, hsh.hexdigest())
        if err: os.remove(tmp); return self.send(403, {"fehler": err})
        os.replace(tmp, os.path.join(nd, night + ".suya"))
        log_event("nacht", d)
        self.send(201, {"ok": True, "nacht": night})

    def delete(self, d, token):
        with lock:
            ok = token_ok(d, token)
            if ok is False: return self.send(403, {"fehler": "Schlüssel passt nicht"})
        if ok:
            err = check_attest(self, d, "loeschen")
            if err: return self.send(403, {"fehler": err})
        with lock:
            if ok is not None: shutil.rmtree(donor_dir(d), ignore_errors=True)
        log_event("geloescht", d)
        self.send(200, {"ok": True, "geloescht": ok is not None})

    def register(self, d, token):
        if ATTEST == "off" or not APP_ID or not appattest: return self.send(503, {"fehler": "App Attest nicht eingerichtet"})
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0 or n > 64 * 1024: return self.send(413, {"fehler": "zu groß"})
        try:
            j = json.loads(self.rfile.read(n))
            key_id, att, c = j["keyId"], base64.b64decode(j["attestation"]), j["challenge"]
        except Exception:
            return self.send(400, {"fehler": "unlesbar"})
        if not take_challenge(c): return self.send(403, {"fehler": "Challenge ungültig"})
        try:
            pem, counter = appattest.verify_attestation(APP_ID, key_id, att, base64.b64decode(c), ATTEST_ENV)
        except Exception as e:
            return self.send(403, {"fehler": f"Attestation ungültig ({e})"})
        with lock:
            ok = token_ok(d, token)
            if ok is False: return self.send(403, {"fehler": "Schlüssel passt nicht"})
            if os.path.exists(attest_file(d)): return self.send(409, {"fehler": "schon registriert"})
            os.makedirs(donor_dir(d), exist_ok=True)
            if ok is None:
                open(os.path.join(donor_dir(d), "schluessel.sha256"), "w").write(hashlib.sha256(token.encode()).hexdigest())
            json.dump({"keyId": key_id, "key": pem, "counter": counter}, open(attest_file(d), "w"))
        log_event("appattest", d)
        self.send(201, {"ok": True})

if __name__ == "__main__":
    os.makedirs(os.path.join(ROOT, "spender"), exist_ok=True)
    threading.Thread(target=cleanup_loop, daemon=True).start()
    print("Suya-Server auf Port", PORT, flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
