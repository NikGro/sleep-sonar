"""Tests für die Schnittstelle des Suya-Servers (CI: python -m unittest test_server test_attest)."""
import hashlib, json, os, sys, tempfile, threading, time, unittest, urllib.error, urllib.request
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from suya import api, config, limits, storage

DATA = tempfile.mkdtemp()
config.DATA, config.SITE, config.MIN_FREE, config.MAX_BYTES = DATA, tempfile.mkdtemp(), 0, 3 * 2**20

KEY = "k" * 40


def post(url, body=b"", **headers):
    req = urllib.request.Request(url, data=body, method="POST", headers={k.replace("_", "-"): v for k, v in headers.items()})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        with e:
            return e.code, json.loads(e.read() or b"{}")


class Server(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.httpd = ThreadingHTTPServer(("127.0.0.1", 0), api.Handler)
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.httpd.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown(); cls.httpd.server_close()

    def setUp(self):
        limits.reset()
        config.ATTEST = "optional"
        config.BUG_PER_DAY = 200

    def part(self, donor, night, i, total, data, full, key=KEY):
        """neue englische Schnittstelle"""
        return post(self.base + "/api/donation/part", data, X_Donor=donor, X_Key=key, X_Night=night,
                    X_Part=str(i), X_Parts=str(total), X_Total_Hash=full)

    def legacy_part(self, donor, night, i, total, data, full, key=KEY):
        """alte deutsche Schnittstelle (ältere App-Versionen)"""
        return post(self.base + "/api/spende/teil", data, X_Spender=donor, X_Schluessel=key, X_Nacht=night,
                    X_Teil=str(i), X_Teile=str(total), X_Gesamt=full)

    def test_complete_upload(self):
        a, b = b"A" * 1000, b"B" * 500
        full = hashlib.sha256(a + b).hexdigest()
        code, j = self.part("AAAA0001", "nacht-0001", 0, 2, a, full)
        self.assertEqual((code, j["missing"], j["fehlt"]), (202, [1], [1]))
        code, j = self.part("AAAA0001", "nacht-0001", 1, 2, b, full)
        self.assertEqual((code, j["night"]), (201, "nacht-0001"))
        with open(os.path.join(DATA, "spender", "AAAA0001", "naechte", "nacht-0001.suya"), "rb") as f:
            self.assertEqual(f.read(), a + b)
        code, j = self.part("AAAA0001", "nacht-0002", 0, 1, a, full, key="x" * 40)
        self.assertEqual((code, j["code"], j["fehler"]), (403, "key_mismatch", "Schlüssel passt nicht"))

    def test_legacy_interface(self):
        a = b"L" * 300
        full = hashlib.sha256(a).hexdigest()
        code, j = self.legacy_part("ABAB0001", "nacht-legacy", 0, 1, a, full)
        self.assertEqual((code, j["nacht"]), (201, "nacht-legacy"))
        code, j = post(self.base + "/api/spende/loeschen", b"", X_Spender="ABAB0001", X_Schluessel=KEY)
        self.assertEqual((code, j["geloescht"], j["deleted"]), (200, True, True))

    def test_wrong_hash(self):
        code, j = self.part("ACAC0001", "nacht-hash1", 0, 1, b"abc", "0" * 64)
        self.assertEqual((code, j["code"]), (400, "hash_mismatch"))
        self.assertFalse(os.path.exists(os.path.join(DATA, "spender", "ACAC0001", "naechte", "nacht-hash1.suya")))

    def test_attest_required_before_first_part(self):
        config.ATTEST = "required"
        code, j = self.part("BBBB0001", "nacht-0001", 0, 2, b"x" * 100, "0" * 64)
        self.assertEqual((code, j["code"]), (403, "attest_failed"))
        self.assertFalse(os.path.exists(os.path.join(DATA, "spender", "BBBB0001")), "nichts speichern ohne Nachweis")

    def test_total_size_limit(self):
        chunk = b"z" * (2 * 2**20)
        self.assertEqual(self.part("CCCC0001", "nacht-0001", 0, 3, chunk, "0" * 64)[0], 202)
        self.assertEqual(self.part("CCCC0001", "nacht-0001", 1, 3, chunk, "0" * 64)[0], 413)   # > MAX_BYTES

    def test_open_nights_per_donor(self):
        for k in range(2):
            self.assertEqual(self.part("DDDD0001", f"nacht-000{k}", 0, 2, b"x", "0" * 64)[0], 202)
        code, j = self.part("DDDD0001", "nacht-0009", 0, 2, b"x", "0" * 64)
        self.assertEqual((code, j["code"]), (429, "too_many_open"))

    def test_bad_headers(self):
        self.assertEqual(self.part("kaputt", "nacht-0001", 0, 1, b"x", "0" * 64)[1]["code"], "bad_donor")
        self.assertEqual(self.part("ADAD0001", "n", 0, 1, b"x", "0" * 64)[1]["code"], "bad_night")
        self.assertEqual(self.part("ADAD0001", "nacht-0001", 3, 2, b"x", "0" * 64)[1]["code"], "bad_part")
        self.assertEqual(post(self.base + "/api/gibtsnicht", b"", X_Donor="ADAD0001", X_Key=KEY)[0], 404)

    def test_cleanup_survives_leftovers(self):
        nd = os.path.join(DATA, "spender", "EEEE0001", "naechte")
        os.makedirs(os.path.join(nd, ".alt.teile"), exist_ok=True)
        old = os.path.join(nd, "alt.suya")
        with open(old, "wb") as f:
            f.write(b"x")
        past = time.time() - 400 * 86400
        for p in (os.path.join(nd, ".alt.teile"), old):
            os.utime(p, (past, past))
        self.assertEqual(storage.cleanup_once(), 0)
        self.assertFalse(os.path.exists(old))
        self.assertFalse(os.path.exists(os.path.join(nd, ".alt.teile")))
        self.assertIsNotNone(storage.status["cleanup"])

    def test_unknown_delete_not_logged(self):
        p = os.path.join(DATA, "protokoll.jsonl")
        def read():
            if not os.path.exists(p):
                return ""
            with open(p) as f:
                return f.read()
        before = read()
        code, j = post(self.base + "/api/donation/delete", b"", X_Donor="FFFF0001", X_Key=KEY)
        self.assertEqual((code, j.get("deleted")), (200, False))
        self.assertNotIn("FFFF0001", read()[len(before):])

    def test_bug_reports_count_only_accepted(self):
        config.BUG_PER_DAY = 2
        for _ in range(5):
            self.assertEqual(post(self.base + "/api/bug-report", b"kaputt")[0], 400)
        limits.bug_hits.clear()
        code, j = post(self.base + "/api/bug-report", json.dumps({"text": "Absturz", "contact": "x", "log": "zeile"}).encode())
        self.assertEqual(code, 201)
        with open(os.path.join(DATA, "fehler", j["id"] + ".json")) as f:
            saved = json.load(f)
        self.assertEqual((saved["kontakt"], saved["protokoll"]), ("x", "zeile"))
        self.assertEqual(post(self.base + "/api/fehler", json.dumps({"text": "alt"}).encode())[0], 201)
        self.assertEqual(post(self.base + "/api/fehler", json.dumps({"text": "zu viel"}).encode())[0], 429)

    def test_status(self):
        with urllib.request.urlopen(self.base + "/api/status") as r:
            j = json.loads(r.read())
        self.assertTrue(j["ok"])
        self.assertIn("cleanup", j)


if __name__ == "__main__":
    unittest.main()
