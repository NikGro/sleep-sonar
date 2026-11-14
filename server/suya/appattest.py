"""Prüfung von Apples App Attest (DeviceCheck) – nach Apples Anleitung
„Validating apps that connect to your server“.

Einmalig je Installation: Attestation (Schlüssel wurde von Apple für genau diese App auf einem echten Gerät erzeugt).
Danach je Anfrage: Assertion (Signatur mit diesem Schlüssel über den Inhalt der Anfrage, Zähler steigt).
"""
import base64
import datetime
import hashlib
import os

import cbor2
from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

ROOT_PEM = os.path.join(os.path.dirname(os.path.abspath(__file__)), "apple_app_attestation_root_ca.pem")
NONCE_OID = x509.ObjectIdentifier("1.2.840.113635.100.8.2")
AAGUID = {"production": b"appattest" + b"\x00" * 7, "development": b"appattestdevelop"}


class AttestError(Exception):
    pass


def _auth_data(a):
    """authenticatorData: rpIdHash(32) | flags(1) | counter(4) | [aaguid(16) | credIdLen(2) | credId | …]"""
    if len(a) < 37:
        raise AttestError("authData zu kurz")
    out = {"rp": a[:32], "counter": int.from_bytes(a[33:37], "big")}
    if len(a) >= 55:
        out["aaguid"] = a[37:53]
        n = int.from_bytes(a[53:55], "big")
        out["cred"] = a[55:55 + n]
    return out


def _basic_constraints(cert):
    try:
        return cert.extensions.get_extension_for_class(x509.BasicConstraints).value
    except x509.ExtensionNotFound:
        return None


def _valid_now(cert, now):
    return cert.not_valid_before_utc <= now <= cert.not_valid_after_utc


def _verify_chain(der_list, now=None):
    """Kette Blatt → Zwischenzertifikat → Apples Wurzel wie bei Apple: genau zwei Zertifikate von der App,
    jedes direkt vom nächsten signiert, alle gerade gültig, nur die oberen dürfen Zertifikate ausstellen
    (CA-Kennzeichen) und ihre Pfadlänge wird eingehalten."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    if not isinstance(der_list, list) or len(der_list) != 2:
        raise AttestError("Zertifikatskette: zwei Zertifikate erwartet")
    with open(ROOT_PEM, "rb") as f:
        root = x509.load_pem_x509_certificate(f.read())
    try:
        certs = [x509.load_der_x509_certificate(d) for d in der_list]
    except (ValueError, TypeError) as e:
        raise AttestError(f"Zertifikat unlesbar: {e}")
    chain = certs + [root]
    for cert in chain:
        if not _valid_now(cert, now):
            raise AttestError("Zertifikat abgelaufen oder noch nicht gültig")
    leaf_bc = _basic_constraints(certs[0])
    if leaf_bc is not None and leaf_bc.ca:
        raise AttestError("Blatt-Zertifikat darf keine CA sein")
    for depth, issuer in enumerate(chain[1:]):
        bc = _basic_constraints(issuer)
        if bc is None or not bc.ca:
            raise AttestError("Aussteller ist keine CA")
        # depth = Zahl der Zwischen-CAs unterhalb dieses Ausstellers
        if bc.path_length is not None and depth > bc.path_length:
            raise AttestError("Pfadlänge überschritten")
    for child, parent in zip(chain, chain[1:]):
        try:
            child.verify_directly_issued_by(parent)
        except (ValueError, TypeError, InvalidSignature) as e:
            raise AttestError(f"Zertifikatskette ungültig: {e}")
    return certs[0]


def _cert_nonce(cert):
    """Erweiterung 1.2.840.113635.100.8.2: SEQUENCE { [1] { OCTET STRING nonce } } – die 32 Bytes am Ende."""
    try:
        raw = cert.extensions.get_extension_for_oid(NONCE_OID).value.value
    except x509.ExtensionNotFound:
        raise AttestError("Nonce-Erweiterung fehlt")
    if len(raw) < 32 or raw[-34:-32] != b"\x04\x20":
        raise AttestError("Nonce-Erweiterung unlesbar")
    return raw[-32:]


def verify_attestation(app_id, key_id_b64, attestation, challenge, environment="production"):
    """Gibt (öffentlicher Schlüssel als PEM, Zähler) zurück oder wirft AttestError.
    app_id: "TEAMID.bundle.id", challenge: die Bytes, die der Server vorher ausgegeben hat."""
    try:
        key_id = base64.b64decode(key_id_b64)
        obj = cbor2.loads(attestation)
        stmt, auth = obj["attStmt"], obj["authData"]
    except (ValueError, TypeError, KeyError, cbor2.CBORDecodeError) as e:
        raise AttestError(f"Attestation unlesbar: {e}")
    if obj.get("fmt") != "apple-appattest":
        raise AttestError("falsches Format")
    if not isinstance(stmt, dict) or "x5c" not in stmt:
        raise AttestError("Zertifikate fehlen")
    cred = _verify_chain(stmt["x5c"])
    client_hash = hashlib.sha256(challenge).digest()
    if _cert_nonce(cred) != hashlib.sha256(auth + client_hash).digest():
        raise AttestError("Nonce passt nicht")
    pub = cred.public_key()
    if not isinstance(pub, ec.EllipticCurvePublicKey):
        raise AttestError("kein EC-Schlüssel")
    point = pub.public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    if hashlib.sha256(point).digest() != key_id:
        raise AttestError("Schlüssel-ID passt nicht")
    a = _auth_data(auth)
    if a["rp"] != hashlib.sha256(app_id.encode()).digest():
        raise AttestError("andere App")
    if a["counter"] != 0:
        raise AttestError("Zähler nicht 0")
    if a.get("aaguid") != AAGUID[environment]:
        raise AttestError("falsche Umgebung")
    if a.get("cred") != key_id:
        raise AttestError("Credential-ID passt nicht")
    pem = pub.public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo).decode()
    return pem, 0


def verify_assertion(app_id, public_pem, last_counter, assertion, client_data):
    """Gibt den neuen Zähler zurück oder wirft AttestError. client_data: die Bytes, über die die App signiert hat."""
    try:
        obj = cbor2.loads(assertion)
        sig, auth = obj["signature"], obj["authenticatorData"]
    except (ValueError, TypeError, KeyError, cbor2.CBORDecodeError) as e:
        raise AttestError(f"Assertion unlesbar: {e}")
    nonce = hashlib.sha256(auth + hashlib.sha256(client_data).digest()).digest()
    pub = serialization.load_pem_public_key(public_pem.encode())
    try:
        pub.verify(sig, nonce, ec.ECDSA(hashes.SHA256()))
    except InvalidSignature:
        raise AttestError("Signatur ungültig")
    a = _auth_data(auth)
    if a["rp"] != hashlib.sha256(app_id.encode()).digest():
        raise AttestError("andere App")
    if a["counter"] <= last_counter:
        raise AttestError("Zähler nicht gestiegen")
    return a["counter"]
