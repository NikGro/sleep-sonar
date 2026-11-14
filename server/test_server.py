"""Tests für die Schnittstelle des Suya-Servers (laufen in der CI: python -m unittest server/test_server.py)."""
import hashlib, importlib, json, os, sys, tempfile, threading, time, unittest, urllib.error, urllib.request
from http.server import ThreadingHTTPServer

DATA = tempfile.mkdtemp()
os.environ.update(DATA=DATA, SITE=tempfile.mkdtemp(), MIN_FREE="0", MAX_BYTES=str(3 * 2**20), ATTEST="optional")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
srv = importlib.import_module("suya_server")

KEY = "k" * 40


def post(url, body=b"", **headers):
    req = urllib.request.Request(url, data=body, method="POST", headers={k.replace("_", "-"): v for k, v in headers.items()})
    try:
        r = urllib.request.urlopen(req, timeout=10)
        return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


class Server(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.httpd = ThreadingHTTPServer(("127.0.0.1", 0), srv.H)
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.httpd.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()

    def setUp(self):
        srv.ip_hits.clear(); srv.donor_bytes.clear(); srv.bug_hits.clear()
        srv.day.update(date="", bytes=0); srv.bug_day.update(tag="", n=0)
        srv.ATTEST = "optional"

    def part(self, donor, night, i, total, data, full, key=KEY):
        return post(self.base + "/api/spende/teil", data, X_Spender=donor, X_Schluessel=key, X_Nacht=night,
                    X_Teil=str(i), X_Teile=str(total), X_Gesamt=full)

    def test_complete_upload(self):
        a, b = b"A" * 1000, b"B" * 500
        full = hashlib.sha256(a + b).hexdigest()
        self.assertEqual(self.part("AAAA0001", "nacht-0001", 0, 2, a, full)[0], 202)
        code, j = self.part("AAAA0001", "nacht-0001", 1, 2, b, full)
        self.assertEqual(code, 201, j)
        with open(os.path.join(DATA, "spender", "AAAA0001", "naechte", "nacht-0001.suya"), "rb") as f:
            self.assertEqual(f.read(), a + b)
        # anderer Schlüssel: abgelehnt
        self.assertEqual(self.part("AAAA0001", "nacht-0002", 0, 1, a, full, key="x" * 40)[0], 403)

    def test_attest_required_before_first_part(self):
        srv.ATTEST = "required"
        code, _ = self.part("BBBB0001", "nacht-0001", 0, 2, b"x" * 100, "0" * 64)
        self.assertEqual(code, 403)
        self.assertFalse(os.path.exists(os.path.join(DATA, "spender", "BBBB0001")), "nichts speichern ohne Nachweis")

    def test_total_size_limit(self):
        chunk = b"z" * (2 * 2**20)
        self.assertEqual(self.part("CCCC0001", "nacht-0001", 0, 3, chunk, "0" * 64)[0], 202)
        self.assertEqual(self.part("CCCC0001", "nacht-0001", 1, 3, chunk, "0" * 64)[0], 413)   # > MAX_BYTES

    def test_open_nights_per_donor(self):
        for k in range(2):
            self.assertEqual(self.part("DDDD0001", f"nacht-000{k}", 0, 2, b"x", "0" * 64)[0], 202)
        self.assertEqual(self.part("DDDD0001", "nacht-0009", 0, 2, b"x", "0" * 64)[0], 429)

    def test_cleanup_survives_leftovers(self):
        nd = os.path.join(DATA, "spender", "EEEE0001", "naechte")
        os.makedirs(os.path.join(nd, ".alt.teile"), exist_ok=True)
        old = os.path.join(nd, "alt.suya"); open(old, "wb").write(b"x")
        past = time.time() - 400 * 86400
        for p in (os.path.join(nd, ".alt.teile"), old): os.utime(p, (past, past))
        self.assertEqual(srv.cleanup_once(), 0)
        self.assertFalse(os.path.exists(old))
        self.assertFalse(os.path.exists(os.path.join(nd, ".alt.teile")))
        self.assertIsNotNone(srv.status["aufraeumen"])

    def test_unknown_delete_not_logged(self):
        p = os.path.join(DATA, "protokoll.jsonl")
        before = open(p).read() if os.path.exists(p) else ""
        code, j = post(self.base + "/api/spende/loeschen", b"", X_Spender="FFFF0001", X_Schluessel=KEY)
        self.assertEqual((code, j.get("geloescht")), (200, False))
        after = open(p).read() if os.path.exists(p) else ""
        self.assertNotIn("FFFF0001", after[len(before):])

    def test_bug_reports_count_only_accepted(self):
        srv.BUG_PER_DAY = 2
        for _ in range(5):
            self.assertEqual(post(self.base + "/api/fehler", b"kaputt")[0], 400)
        srv.bug_hits.clear()
        ok = json.dumps({"text": "Absturz"}).encode()
        self.assertEqual(post(self.base + "/api/fehler", ok)[0], 201)


if __name__ == "__main__":
    unittest.main()
