"""Tests für App Attest: Prüfung von Attestation und Assertion mit einer selbst erzeugten Zertifikatskette
und der Ablauf am Server (Registrieren, Teile mit Assertion, Wiederholung, Löschen).
Läuft in der CI: python -m unittest test_server test_attest"""
import base64, datetime, hashlib, importlib, json, os, sys, tempfile, threading, unittest, urllib.error, urllib.request
from http.server import ThreadingHTTPServer

import cbor2
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
if "suya_server" not in sys.modules:
    os.environ.update(DATA=tempfile.mkdtemp(), SITE=tempfile.mkdtemp(), MIN_FREE="0", ATTEST="optional")
srv = importlib.import_module("suya_server")
import appattest

APP = "TEAM123456.de.nikgro.sleepsonar"
NOW = datetime.datetime.now(datetime.timezone.utc)


def _name(cn):
    return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])


def _cert(subj, pub, issuer, ikey, ca, ext=None, days=(-1, 30), path_length=None):
    b = (x509.CertificateBuilder().subject_name(_name(subj)).issuer_name(_name(issuer)).public_key(pub)
         .serial_number(x509.random_serial_number()).not_valid_before(NOW + datetime.timedelta(days=days[0]))
         .not_valid_after(NOW + datetime.timedelta(days=days[1]))
         .add_extension(x509.BasicConstraints(ca=ca, path_length=path_length), critical=True))
    if ext:
        b = b.add_extension(x509.UnrecognizedExtension(appattest.NONCE_OID, ext), critical=False)
    return b.sign(ikey, hashes.SHA384() if ca else hashes.SHA256())


ROOT_KEY = ec.generate_private_key(ec.SECP384R1())
ROOT = _cert("root", ROOT_KEY.public_key(), "root", ROOT_KEY, True)
INTER_KEY = ec.generate_private_key(ec.SECP384R1())
INTER = _cert("inter", INTER_KEY.public_key(), "root", ROOT_KEY, True)
_root_pem = os.path.join(tempfile.mkdtemp(), "root.pem")
with open(_root_pem, "wb") as f:
    f.write(ROOT.public_bytes(serialization.Encoding.PEM))


def make_attestation(challenge, app=APP, env=b"appattest" + b"\0" * 7, leaf_days=(-1, 30), leaf_ca=False,
                     inter=None, extra=()):
    kk = ec.generate_private_key(ec.SECP256R1())
    point = kk.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    kid = hashlib.sha256(point).digest()
    auth = (hashlib.sha256(app.encode()).digest() + b"\x40" + (0).to_bytes(4, "big") + env
            + len(kid).to_bytes(2, "big") + kid)
    nonce = hashlib.sha256(auth + hashlib.sha256(challenge).digest()).digest()
    leaf = _cert("leaf", kk.public_key(), "inter", INTER_KEY, leaf_ca, bytes([0x30, 0x24, 0xa1, 0x22, 0x04, 0x20]) + nonce,
                 days=leaf_days)
    chain = [leaf, inter or INTER, *extra]
    att = cbor2.dumps({"fmt": "apple-appattest", "authData": auth, "attStmt": {
        "x5c": [c.public_bytes(serialization.Encoding.DER) for c in chain], "receipt": b""}})
    return kk, base64.b64encode(kid).decode(), att


def make_assertion(kk, counter, data, app=APP):
    auth = hashlib.sha256(app.encode()).digest() + b"\x00" + counter.to_bytes(4, "big")
    nonce = hashlib.sha256(auth + hashlib.sha256(data).digest()).digest()
    return cbor2.dumps({"signature": kk.sign(nonce, ec.ECDSA(hashes.SHA256())), "authenticatorData": auth})


class Verify(unittest.TestCase):
    def setUp(self):
        self._old_root = appattest.ROOT_PEM
        appattest.ROOT_PEM = _root_pem

    def tearDown(self):
        appattest.ROOT_PEM = self._old_root

    def test_attestation(self):
        kk, kid, att = make_attestation(b"abc")
        pem, counter = appattest.verify_attestation(APP, kid, att, b"abc")
        self.assertEqual(counter, 0)
        for args in ((APP, kid, att, b"xyz"), ("OTHER.app", kid, att, b"abc"), (APP, kid, att, b"abc", "development")):
            with self.assertRaises(appattest.AttestError):
                appattest.verify_attestation(*args)

    def test_chain_rules(self):
        def rejected(**kw):
            kk, kid, att = make_attestation(b"abc", **kw)
            with self.assertRaises(appattest.AttestError):
                appattest.verify_attestation(APP, kid, att, b"abc")
        rejected(leaf_days=(-30, -1))                 # abgelaufen
        rejected(leaf_days=(1, 30))                   # noch nicht gültig
        rejected(leaf_ca=True)                        # Blatt darf nicht ausstellen
        rejected(inter=_cert("inter", INTER_KEY.public_key(), "root", ROOT_KEY, False))   # Zwischenzert. keine CA
        rejected(inter=_cert("inter", INTER_KEY.public_key(), "root", ROOT_KEY, True, days=(-30, -1)))
        rejected(extra=(INTER,))                      # mehr als zwei Zertifikate

    def test_garbage(self):
        for att in (b"", b"\x00\x01", cbor2.dumps({"fmt": "apple-appattest"}), cbor2.dumps([1, 2])):
            with self.assertRaises(appattest.AttestError):
                appattest.verify_attestation(APP, "AAAA", att, b"abc")
        with self.assertRaises(appattest.AttestError):
            appattest.verify_assertion(APP, "x", 0, b"\xff", b"d")

    def test_assertion(self):
        kk, kid, att = make_attestation(b"abc")
        pem, _ = appattest.verify_attestation(APP, kid, att, b"abc")
        self.assertEqual(appattest.verify_assertion(APP, pem, 0, make_assertion(kk, 1, b"d"), b"d"), 1)
        with self.assertRaises(appattest.AttestError):   # andere Daten
            appattest.verify_assertion(APP, pem, 0, make_assertion(kk, 1, b"d"), b"e")
        with self.assertRaises(appattest.AttestError):   # Zähler läuft rückwärts
            appattest.verify_assertion(APP, pem, 5, make_assertion(kk, 3, b"d"), b"d")


def call(base, path, data=None, headers=None):
    req = urllib.request.Request(base + path, data=data, headers=headers or {},
                                 method="POST" if data is not None else "GET")
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


class ServerFlow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.saved = (srv.APP_ID, srv.appattest, srv.ATTEST, appattest.ROOT_PEM)
        srv.APP_ID, srv.appattest = APP, appattest
        appattest.ROOT_PEM = _root_pem
        cls.httpd = ThreadingHTTPServer(("127.0.0.1", 0), srv.H)
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.httpd.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown(); cls.httpd.server_close()
        srv.APP_ID, srv.appattest, srv.ATTEST, appattest.ROOT_PEM = cls.saved

    def setUp(self):
        srv.ip_hits.clear(); srv.donor_bytes.clear()
        srv.day.update(date="", bytes=0)
        srv.ATTEST = "optional"

    def challenge(self):
        code, j = call(self.base, "/api/attest/challenge")
        self.assertEqual(code, 200)
        return j["challenge"]

    def register(self, donor, key):
        ch = self.challenge()
        kk, kid, att = make_attestation(base64.b64decode(ch))
        body = json.dumps({"keyId": kid, "attestation": base64.b64encode(att).decode(), "challenge": ch}).encode()
        code, _ = call(self.base, "/api/attest/register", body, {"X-Spender": donor, "X-Schluessel": key})
        self.assertIn(code, (200, 201))
        return kk

    def part(self, donor, key, night, i, total, data, full, assertion=None):
        h = {"X-Spender": donor, "X-Schluessel": key, "X-Nacht": night, "X-Teil": str(i), "X-Teile": str(total),
             "X-Gesamt": full}
        if assertion: h.update({"X-Assertion": assertion[0], "X-Challenge": assertion[1]})
        return call(self.base, "/api/spende/teil", data, h)

    def sign(self, kk, counter, kind, donor, night="", full=""):
        ch = self.challenge()
        a = make_assertion(kk, counter, f"{kind}|{ch}|{donor}|{night}|{full}".encode())
        return base64.b64encode(a).decode(), ch

    def test_parts_need_assertion_each(self):
        donor, key = "ABCD9999", "t" * 40
        kk = self.register(donor, key)
        blob = os.urandom(10000)
        full = hashlib.sha256(blob).hexdigest()
        parts = [blob[:4000], blob[4000:8000], blob[8000:]]
        night = "n-teile-01"
        # ohne Assertion abgelehnt, bevor etwas gespeichert wird
        self.assertEqual(self.part(donor, key, night, 0, 3, parts[0], full)[0], 403)
        self.assertEqual(self.part(donor, key, night, 0, 3, parts[0], full, self.sign(kk, 1, "nacht", donor, night, full))[0], 202)
        # dieselbe Challenge ein zweites Mal: abgelehnt
        a = self.sign(kk, 2, "nacht", donor, night, full)
        self.assertEqual(self.part(donor, key, night, 2, 3, parts[2], full, a)[0], 202)
        self.assertEqual(self.part(donor, key, night, 1, 3, parts[1], full, a)[0], 403)
        code, j = self.part(donor, key, night, 1, 3, parts[1], full, self.sign(kk, 3, "nacht", donor, night, full))
        self.assertEqual(code, 201, j)
        path = os.path.join(srv.ROOT, "spender", donor, "naechte", night + ".suya")
        self.assertEqual(os.path.getsize(path), 10000)
        # Löschen mit Assertion
        code, j = call(self.base, "/api/spende/loeschen", b"",
                       {"X-Spender": donor, "X-Schluessel": key,
                        **dict(zip(("X-Assertion", "X-Challenge"), self.sign(kk, 4, "loeschen", donor)))})
        self.assertEqual((code, j.get("geloescht")), (200, True))
        self.assertFalse(os.path.exists(path))

    def test_required_mode(self):
        srv.ATTEST = "required"
        body = os.urandom(100)
        full = hashlib.sha256(body).hexdigest()
        # ohne registrierten Schlüssel kein Hochladen …
        self.assertEqual(self.part("FFFF0001", "t" * 40, "n-required-1", 0, 1, body, full)[0], 403)
        # … aber Löschen geht immer
        code, _ = call(self.base, "/api/spende/loeschen", b"", {"X-Spender": "FFFF0001", "X-Schluessel": "t" * 40})
        self.assertEqual(code, 200)


if __name__ == "__main__":
    unittest.main()
