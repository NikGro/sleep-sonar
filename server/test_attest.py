"""Prüft App Attest (Attestation + Assertion) mit einer selbst erzeugten Zertifikatskette und den Server von Ende zu Ende."""
import base64, datetime, hashlib, json, os, sys, threading, time, urllib.request, cbor2
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
import appattest

def name(cn): return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])
now = datetime.datetime.now(datetime.timezone.utc)
def cert(subj, pub, issuer, ikey, ca, ext=None):
    b = (x509.CertificateBuilder().subject_name(name(subj)).issuer_name(name(issuer)).public_key(pub)
         .serial_number(x509.random_serial_number()).not_valid_before(now - datetime.timedelta(days=1))
         .not_valid_after(now + datetime.timedelta(days=30))
         .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True))
    if ext: b = b.add_extension(x509.UnrecognizedExtension(appattest.NONCE_OID, ext), critical=False)
    return b.sign(ikey, hashes.SHA384() if ca else hashes.SHA256())
rk = ec.generate_private_key(ec.SECP384R1()); root = cert("root", rk.public_key(), "root", rk, True)
ik = ec.generate_private_key(ec.SECP384R1()); inter = cert("inter", ik.public_key(), "root", rk, True)
open("/tmp/aat/root.pem", "wb").write(root.public_bytes(serialization.Encoding.PEM))
appattest.ROOT_PEM = "/tmp/aat/root.pem"

APP = "TEAM123456.de.nikgro.sleepsonar"
def make_attestation(challenge, app=APP, env=b"appattest" + b"\0" * 7):
    kk = ec.generate_private_key(ec.SECP256R1())
    point = kk.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    kid = hashlib.sha256(point).digest()
    auth = hashlib.sha256(app.encode()).digest() + b"\x40" + (0).to_bytes(4, "big") + env + len(kid).to_bytes(2, "big") + kid
    nonce = hashlib.sha256(auth + hashlib.sha256(challenge).digest()).digest()
    ext = bytes([0x30, 0x24, 0xa1, 0x22, 0x04, 0x20]) + nonce
    leaf = cert("leaf", kk.public_key(), "inter", ik, False, ext)
    att = cbor2.dumps({"fmt": "apple-appattest", "attStmt": {"x5c": [leaf.public_bytes(serialization.Encoding.DER), inter.public_bytes(serialization.Encoding.DER)], "receipt": b""}, "authData": auth})
    return kk, base64.b64encode(kid).decode(), att
def make_assertion(kk, counter, data, app=APP):
    auth = hashlib.sha256(app.encode()).digest() + b"\x00" + counter.to_bytes(4, "big")
    nonce = hashlib.sha256(auth + hashlib.sha256(data).digest()).digest()
    return cbor2.dumps({"signature": kk.sign(nonce, ec.ECDSA(hashes.SHA256())), "authenticatorData": auth})

# Unit
kk, kid, att = make_attestation(b"abc")
pem, c = appattest.verify_attestation(APP, kid, att, b"abc"); print("attest ok")
for bad, args in (("andere challenge", (APP, kid, att, b"xyz")), ("andere app", ("OTHER.app", kid, att, b"abc")), ("dev env", (APP, kid, att, b"abc", "development"))):
    try: appattest.verify_attestation(*args); print("FEHLT:", bad)
    except appattest.AttestError as e: print("abgelehnt ok:", bad, "-", e)
print("assert ok, Zähler", appattest.verify_assertion(APP, pem, 0, make_assertion(kk, 1, b"d"), b"d"))
for bad, args in (("falsche Daten", (APP, pem, 0, make_assertion(kk, 1, b"d"), b"e")), ("Zähler alt", (APP, pem, 5, make_assertion(kk, 3, b"d"), b"d"))):
    try: appattest.verify_assertion(*args); print("FEHLT:", bad)
    except appattest.AttestError as e: print("abgelehnt ok:", bad, "-", e)

# Server-Integration
os.environ.update(DATA="/tmp/aat/data", SITE=os.path.join(os.path.dirname(os.path.abspath(__file__)), "site"), PORT="8790", APP_ID=APP, ATTEST="optional")
import importlib, shutil; shutil.rmtree("/tmp/aat/data", ignore_errors=True)
import suya_server as S; S.appattest = appattest; S.MIN_FREE = 0; os.makedirs("/tmp/aat/data/spender", exist_ok=True)
srv = S.ThreadingHTTPServer(("127.0.0.1", 8790), S.H); threading.Thread(target=srv.serve_forever, daemon=True).start()
U = "http://127.0.0.1:8790"
def call(path, data=None, headers={}, method=None):
    r = urllib.request.Request(U + path, data=data, headers=headers, method=method or ("POST" if data is not None else "GET"))
    try:
        with urllib.request.urlopen(r) as x: return x.status, json.loads(x.read())
    except urllib.error.HTTPError as e: return e.code, json.loads(e.read())
D, T = "ABCD1234", "t" * 40
H = {"X-Spender": D, "X-Schluessel": T}
ch = call("/api/attest/challenge")[1]["challenge"]
kk, kid, att = make_attestation(base64.b64decode(ch))
print("register", call("/api/attest/register", json.dumps({"keyId": kid, "attestation": base64.b64encode(att).decode(), "challenge": ch}).encode(), H))
body = os.urandom(5000); bh = hashlib.sha256(body).hexdigest()
print("upload ohne assertion", call("/api/spende/nacht", body, {**H, "X-Nacht": "n-00000001"}))
ch = call("/api/attest/challenge")[1]["challenge"]
a = base64.b64encode(make_assertion(kk, 1, f"nacht|{ch}|{D}|n-00000001|{bh}".encode())).decode()
print("upload mit assertion", call("/api/spende/nacht", body, {**H, "X-Nacht": "n-00000001", "X-Assertion": a, "X-Challenge": ch}))
print("replay gleiche challenge", call("/api/spende/nacht", body, {**H, "X-Nacht": "n-00000002", "X-Assertion": a, "X-Challenge": ch}))
ch = call("/api/attest/challenge")[1]["challenge"]
a = base64.b64encode(make_assertion(kk, 2, f"loeschen|{ch}|{D}||".encode())).decode()
print("loeschen", call("/api/spende/loeschen", b"", {**H, "X-Assertion": a, "X-Challenge": ch}))
print("ohne attest spender upload", call("/api/spende/nacht", body, {"X-Spender": "FFFF0000", "X-Schluessel": T, "X-Nacht": "n-00000003"}))
S.ATTEST = "required"
print("required upload ohne attest", call("/api/spende/nacht", body, {"X-Spender": "FFFF0001", "X-Schluessel": T, "X-Nacht": "n-00000004"}))
print("required loeschen ohne attest", call("/api/spende/loeschen", b"", {"X-Spender": "FFFF0000", "X-Schluessel": T}))

# Teile: 3 Teile, mittleres zuerst fehlend, dann nachgereicht; mit App Attest beim letzten Teil
S.ATTEST = "optional"
D2 = "ABCD9999"; H2 = {"X-Spender": D2, "X-Schluessel": T}
ch = call("/api/attest/challenge")[1]["challenge"]
kk2, kid2, att2 = make_attestation(base64.b64decode(ch))
print("register2", call("/api/attest/register", json.dumps({"keyId": kid2, "attestation": base64.b64encode(att2).decode(), "challenge": ch}).encode(), H2)[0])
blob = os.urandom(10000); full = hashlib.sha256(blob).hexdigest(); parts = [blob[:4000], blob[4000:8000], blob[8000:]]
ph = lambda i: {**H2, "X-Nacht": "n-teile-01", "X-Teil": str(i), "X-Teile": "3", "X-Gesamt": full}
print("teil 0", call("/api/spende/teil", parts[0], ph(0)))
print("teil 2", call("/api/spende/teil", parts[2], ph(2)))
ch = call("/api/attest/challenge")[1]["challenge"]
a = base64.b64encode(make_assertion(kk2, 1, f"nacht|{ch}|{D2}|n-teile-01|{full}".encode())).decode()
print("teil 1 (letzter)", call("/api/spende/teil", parts[1], {**ph(1), "X-Assertion": a, "X-Challenge": ch}))
print("datei da:", os.path.getsize(f"/tmp/aat/data/spender/{D2}/naechte/n-teile-01.suya") == 10000)
