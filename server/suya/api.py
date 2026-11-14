"""HTTP-Anfragen. Die Schnittstelle ist englisch; die früheren deutschen Pfade, Köpfe und Antwortfelder
gelten weiter, damit ältere App-Versionen funktionieren.

  POST /api/donation/part     (alt /api/spende/teil)
       Köpfe: X-Donor (alt X-Spender, 8 Zeichen), X-Key (alt X-Schluessel, geheimer Schlüssel der Installation),
       X-Night (alt X-Nacht), X-Part (alt X-Teil, 0 …), X-Parts (alt X-Teile), X-Total-Hash (alt X-Gesamt,
       sha256 des ganzen Pakets). Inhalt: ein Teil. Mit dem letzten fehlenden Teil wird zusammengesetzt.
       Schlüssel, App Attest und alle Grenzen werden vor dem Speichern jedes Teils geprüft.
  POST /api/donation/delete   (alt /api/spende/loeschen)  löscht alle Nächte dieser Spender-Nummer
  POST /api/bug-report        (alt /api/fehler)  JSON {text, contact, technical, crashes}
  GET  /api/status
  GET  /api/attest/challenge  {"challenge": base64}, einmal gültig, 5 Minuten
  POST /api/attest/register   JSON {keyId, attestation, challenge} (base64)

Fehler: {"error": Meldung, "code": maschinenlesbar, "fehler": Meldung (alt)}.
Es werden keine IP-Adressen gespeichert.
"""
import base64
import hashlib
import json
import os
import re
import secrets
import shutil
import time
from http.server import BaseHTTPRequestHandler

from . import attest, config, limits, storage

ROUTES_POST = {
    "/api/donation/part": "upload_part", "/api/spende/teil": "upload_part",
    "/api/donation/delete": "delete", "/api/spende/loeschen": "delete",
    "/api/attest/register": "register",
}
BUG_PATHS = {"/api/bug-report", "/api/fehler"}
PAGES = {"/": "index.html", "/datenschutz": "datenschutz.html", "/impressum": "impressum.html",
         "/style.css": "style.css", "/favicon.svg": "favicon.svg"}
LANG_PAGE = re.compile(r"^/(en|es|fr|it|pt|nl|ja|ko|zh)(?:/(privacy|imprint))?$")
SECURITY_HEADERS = {
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "Content-Security-Policy": "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; "
                               "frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
    "X-Frame-Options": "DENY",
    "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
}


class Refusal(Exception):
    """Anfrage abgelehnt: HTTP-Status, Fehlercode, Meldung"""

    def __init__(self, status, code, message):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


def _clip(value, n):
    return value[:n] if isinstance(value, str) else ""


def _readable(text):
    """Absturzprotokoll (JSON von MetricKit) lesbar ablegen, sonst als Text"""
    try:
        return json.loads(text)
    except Exception:
        return text


class Handler(BaseHTTPRequestHandler):
    server_version = "Suya"
    sys_version = ""
    timeout = 60                 # hängende Verbindungen nicht ewig offen halten
    protocol_version = "HTTP/1.0"

    def log_message(self, *args):   # keine Zugriffsprotokolle (keine IP-Adressen auf der Platte)
        pass

    # ---------- Hilfen ----------
    def header(self, name, old):
        return self.headers.get(name) or self.headers.get(old) or ""

    def send(self, status, obj=None, body=None, ctype="application/json; charset=utf-8"):
        data = body if body is not None else json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in SECURITY_HEADERS.items():
            self.send_header(k, v)
        self.send_header("Cache-Control", "no-store" if ctype.startswith("application/json") else "public, max-age=3600")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def refuse(self, status, code, message, donor=None):
        if donor:
            storage.log_event(f"fehler {status}: {message}", donor)
        return self.send(status, {"error": message, "code": code, "fehler": message})

    def content_length(self):
        """fehlt/kaputt/negativ → -1"""
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return -1
        return n if n >= 0 else -1

    def handle_one_request(self):
        try:
            super().handle_one_request()
        except Exception as e:          # nie den ganzen Server mitreißen; ohne IP protokollieren
            print("Fehler in Anfrage:", type(e).__name__, e, flush=True)

    # ---------- GET ----------
    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/") or "/"
        if path == "/api/status":
            cleanup = storage.status["cleanup"]
            return self.send(200, {"ok": True, "attest": attest.enabled(), "cleanup": cleanup, "aufraeumen": cleanup})
        if path == "/api/attest/challenge":
            if limits.too_many_requests(self):
                return self.refuse(429, "rate_limited", "zu viele Anfragen")
            c = attest.new_challenge()
            if c is None:
                return self.refuse(503, "busy", "später")
            return self.send(200, {"challenge": c})
        name = PAGES.get(path)
        m = LANG_PAGE.match(path)
        if m:
            name = f"{m.group(1)}/{m.group(2) or 'index'}.html"
        if not name:
            return self.send(404, body=b"Nicht gefunden", ctype="text/plain; charset=utf-8")
        ext = name.rsplit(".", 1)[-1]
        ctype = {"css": "text/css", "svg": "image/svg+xml"}.get(ext, "text/html") + "; charset=utf-8"
        with open(os.path.join(config.SITE, name), "rb") as f:
            self.send(200, body=f.read(), ctype=ctype)

    do_HEAD = do_GET

    # ---------- POST ----------
    def do_POST(self):
        if limits.too_many_requests(self):
            return self.refuse(429, "rate_limited", "zu viele Anfragen")
        path = self.path.split("?")[0]
        if path in BUG_PATHS:
            return self.bug_report()
        route = ROUTES_POST.get(path)
        if not route:
            return self.refuse(404, "not_found", "unbekannt")
        donor = self.header("X-Donor", "X-Spender").upper()
        key = self.header("X-Key", "X-Schluessel")
        if not config.DONOR_ID.match(donor) or not config.KEY.match(key):
            return self.refuse(400, "bad_donor", "Spender-Nummer oder Schlüssel ungültig")
        try:
            return getattr(self, route)(donor, key)
        except Refusal as r:
            return self.refuse(r.status, r.code, r.message, donor if route == "upload_part" else None)

    def do_PUT(self):
        self.refuse(405, "method_not_allowed", "nicht erlaubt")

    do_DELETE = do_PATCH = do_OPTIONS = do_PUT

    # ---------- Spende ----------
    def _part_headers(self):
        night = self.header("X-Night", "X-Nacht")
        try:
            index = int(self.header("X-Part", "X-Teil"))
            total = int(self.header("X-Parts", "X-Teile"))
        except ValueError:
            raise Refusal(400, "bad_part", "Teil ungültig")
        full = self.header("X-Total-Hash", "X-Gesamt").lower()
        if not config.NIGHT_ID.match(night):
            raise Refusal(400, "bad_night", "Nacht-Kennung ungültig")
        if not (0 <= index < total <= config.MAX_PARTS) or not config.SHA256_HEX.match(full):
            raise Refusal(400, "bad_part", "Teil ungültig")
        return night, index, total, full

    def _check_new_part(self, donor, key, night, n):
        """Alles prüfen, bevor ein Byte gespeichert wird (limits.lock muss gehalten werden).
        Gibt zurück, ob der Schlüssel schon hinterlegt war."""
        known = storage.key_matches(donor, key)
        if known is False:
            raise Refusal(403, "key_mismatch", "Schlüssel passt nicht")
        folder = storage.nights_dir(donor)
        parts = storage.parts_dir(donor, night)
        finished = os.path.exists(storage.night_file(donor, night))
        if not os.path.isdir(parts) and not finished:   # neue Nacht: Tages- und Offen-Grenzen
            names = os.listdir(folder) if os.path.isdir(folder) else []
            recent = [f for f in names if not f.startswith(".")
                      and time.time() - os.path.getmtime(os.path.join(folder, f)) < 86400]
            open_now = [f for f in names if f.endswith(".teile")]
            if len(recent) + len(open_now) >= config.NIGHTS_PER_DONOR_DAY:
                raise Refusal(429, "too_many_nights", "zu viele Nächte heute")
            if len(open_now) >= config.OPEN_PER_DONOR:
                raise Refusal(429, "too_many_open", "zu viele offene Nächte")
        have = sum(os.path.getsize(os.path.join(parts, f)) for f in os.listdir(parts)) if os.path.isdir(parts) else 0
        if have + n > config.MAX_BYTES:
            raise Refusal(413, "too_large", "Paket zu groß")
        refusal = limits.bytes_refusal(donor, n)
        if refusal:
            raise Refusal(*refusal)
        return known

    def _receive(self, path, n):
        """n Bytes in eine Datei schreiben; False bei abgebrochener Verbindung"""
        left = n
        with open(path + ".tmp", "wb") as f:
            while left:
                chunk = self.rfile.read(min(left, 1 << 20))
                if not chunk:
                    break
                f.write(chunk)
                left -= len(chunk)
        if left:
            os.remove(path + ".tmp")
            return False
        os.replace(path + ".tmp", path)
        return True

    def _assemble(self, donor, night, total, full):
        parts = storage.parts_dir(donor, night)
        out = os.path.join(storage.nights_dir(donor), f".{night}.part")
        digest = hashlib.sha256()
        with open(out, "wb") as f:
            for k in range(total):
                with open(os.path.join(parts, str(k)), "rb") as src:
                    for chunk in iter(lambda: src.read(1 << 20), b""):
                        digest.update(chunk)
                        f.write(chunk)
        shutil.rmtree(parts, ignore_errors=True)
        if digest.hexdigest() != full:
            os.remove(out)
            raise Refusal(400, "hash_mismatch", "Paket passt nicht zum Hash")
        os.replace(out, storage.night_file(donor, night))

    def upload_part(self, donor, key):
        night, index, total, full = self._part_headers()
        n = self.content_length()
        if n <= 0 or n > config.PART_MAX:
            raise Refusal(413, "bad_size", "Teil zu groß oder leer")
        if storage.free_bytes() < config.MIN_FREE + n:
            raise Refusal(507, "disk_full", "Speicher voll")
        with limits.lock:
            known = self._check_new_part(donor, key, night, n)
        err = attest.check(self, donor, "nacht", night, full)   # jede Teil-Anfrage braucht eine eigene Assertion
        if err:
            raise Refusal(403, "attest_failed", err)
        with limits.lock:
            now_known = storage.key_matches(donor, key)
            if now_known is False:
                raise Refusal(403, "key_mismatch", "Schlüssel passt nicht")
            if known is None and now_known is None:
                storage.store_key(donor, key)
            limits.add_bytes(donor, n)
        parts = storage.parts_dir(donor, night)
        os.makedirs(parts, exist_ok=True)
        if not self._receive(os.path.join(parts, str(index)), n):
            raise Refusal(400, "aborted", "Teil abgebrochen")
        missing = [k for k in range(total) if not os.path.exists(os.path.join(parts, str(k)))]
        if missing:
            return self.send(202, {"ok": True, "missing": missing, "fehlt": missing})
        self._assemble(donor, night, total, full)
        storage.log_event("nacht", donor)
        return self.send(201, {"ok": True, "night": night, "nacht": night})

    def delete(self, donor, key):
        with limits.lock:
            known = storage.key_matches(donor, key)
        if known is False:
            raise Refusal(403, "key_mismatch", "Schlüssel passt nicht")
        if known:
            err = attest.check(self, donor, "loeschen")
            if err:
                raise Refusal(403, "attest_failed", err)
            with limits.lock:
                storage.delete_donor(donor)
            storage.log_event("geloescht", donor)
        return self.send(200, {"ok": True, "deleted": bool(known), "geloescht": bool(known)})

    def register(self, donor, key):
        if not attest.enabled():
            raise Refusal(503, "attest_off", "App Attest nicht eingerichtet")
        n = self.content_length()
        if n <= 0 or n > 64 * 1024:
            raise Refusal(413, "too_large", "zu groß")
        try:
            j = json.loads(self.rfile.read(n))
            key_id, attestation, challenge = j["keyId"], base64.b64decode(j["attestation"]), j["challenge"]
        except Exception:
            raise Refusal(400, "unreadable", "unlesbar")
        with limits.lock:
            known = storage.key_matches(donor, key)
            if known is False:
                raise Refusal(403, "key_mismatch", "Schlüssel passt nicht")
            failed = attest.register(donor, key_id, attestation, challenge)
            if failed:
                raise Refusal(*failed)
            if known is None:
                storage.store_key(donor, key)
        storage.log_event("appattest", donor)
        return self.send(201, {"ok": True})

    # ---------- Fehlerbericht ----------
    def bug_report(self):
        """Nur Text, freiwillige Kontaktangabe und technische Angaben; keine IP auf der Platte"""
        if not limits.bug_report_allowed(self):
            return self.refuse(429, "rate_limited", "zu viele Berichte, bitte später")
        n = self.content_length()
        if n <= 0 or n > config.BUG_MAX:
            return self.refuse(413, "bad_size", "Bericht zu lang oder leer")
        if storage.free_bytes() < config.MIN_FREE:
            return self.refuse(507, "disk_full", "Speicher voll")
        try:
            obj = json.loads(self.rfile.read(n))
        except Exception:
            return self.refuse(400, "unreadable", "Bericht unlesbar")
        if not isinstance(obj, dict):
            return self.refuse(400, "unreadable", "Bericht unlesbar")
        text = obj.get("text")
        if not isinstance(text, str) or not text.strip():
            return self.refuse(400, "text_missing", "Beschreibung fehlt")
        tech = obj.get("technical", obj.get("technik"))
        tech = tech if isinstance(tech, dict) else {}
        crashes = obj.get("crashes", obj.get("absturz"))
        crashes = crashes if isinstance(crashes, list) else []
        report = {
            "zeit": storage.now_iso(),
            "text": _clip(text, 8000),
            "kontakt": _clip(obj.get("contact", obj.get("kontakt")), 200),
            "technik": {_clip(k, 40): _clip(v, 300) for k, v in list(tech.items())[:40] if isinstance(k, str)},
            "absturz": [_readable(_clip(c, 64 * 1024)) for c in crashes[:5]],
        }
        if "log" in obj:
            report["protokoll"] = _clip(obj.get("log"), 64 * 1024)
        rid = time.strftime("%Y%m%d-%H%M%S", time.gmtime()) + "-" + secrets.token_hex(3)
        folder = os.path.join(config.DATA, "fehler")
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, rid + ".json"), "w") as f:
            json.dump(report, f, ensure_ascii=False, indent=1)
        limits.count_bug_report()
        storage.log_event("fehlerbericht " + rid, "-")
        return self.send(201, {"ok": True, "id": rid, "nummer": rid})
