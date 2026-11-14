"""App Attest am Server: einmalige Challenges und die Assertion, die jede Anfrage eines registrierten
Spenders mitbringt – signiert über "art|challenge|spender|nacht|sha256(paket)"."""
import base64
import json
import os
import secrets
import threading
import time

from . import config, storage

try:
    from . import appattest
except ImportError:              # ohne cryptography/cbor2 läuft der Rest trotzdem
    appattest = None

_challenges = {}                 # base64 → Ablaufzeit
_challenge_lock = threading.Lock()
_counter_lock = threading.Lock()  # Zähler einer Assertion nie gleichzeitig fortschreiben


def enabled():
    return bool(config.APP_ID and appattest) and config.ATTEST != "off"


def new_challenge():
    """None, wenn zu viele offen sind"""
    c = base64.b64encode(secrets.token_bytes(32)).decode()
    now = time.time()
    with _challenge_lock:
        for k in [k for k, v in _challenges.items() if v < now]:
            del _challenges[k]
        if len(_challenges) > config.MAX_CHALLENGES:
            return None
        _challenges[c] = now + config.CHALLENGE_SECONDS
    return c


def take_challenge(c):
    """einmal verwendbar und höchstens 5 Minuten alt"""
    with _challenge_lock:
        expires = _challenges.pop(c, 0)
    return expires > time.time()


def check(handler, donor, kind, night="", body_hash=""):
    """None = in Ordnung, sonst Fehlermeldung. kind: "nacht" (Hochladen) oder "loeschen"."""
    path = storage.attest_file(donor)
    if not os.path.exists(path):
        # Löschen geht immer (Recht auf Löschung); Hochladen in der App-Store-Version nur mit App Attest
        if config.ATTEST == "required" and kind == "nacht":
            return "App Attest nötig"
        return None
    assertion = handler.headers.get("X-Assertion") or ""
    challenge = handler.headers.get("X-Challenge") or ""
    if not assertion or not challenge or not take_challenge(challenge):
        return "Assertion oder Challenge fehlt"
    data = f"{kind}|{challenge}|{donor}|{night}|{body_hash}".encode()
    with _counter_lock:
        with open(path) as f:
            info = json.load(f)
        try:
            raw = base64.b64decode(assertion)
            info["counter"] = appattest.verify_assertion(config.APP_ID, info["key"], info["counter"], raw, data)
        except Exception as e:
            return f"Assertion ungültig ({e})"
        storage.write_atomic(path, json.dumps(info))
    return None


def register(donor, key_id, attestation, challenge):
    """Gibt (Status, Fehlercode, Meldung) bei Fehler zurück, sonst None."""
    if not take_challenge(challenge):
        return 403, "challenge_invalid", "Challenge ungültig"
    try:
        pem, counter = appattest.verify_attestation(config.APP_ID, key_id, attestation,
                                                    base64.b64decode(challenge), config.ATTEST_ENV)
    except Exception as e:
        return 403, "attestation_invalid", f"Attestation ungültig ({e})"
    path = storage.attest_file(donor)
    if os.path.exists(path):
        return 409, "already_registered", "schon registriert"
    os.makedirs(storage.donor_dir(donor), exist_ok=True)
    storage.write_atomic(path, json.dumps({"keyId": key_id, "key": pem, "counter": counter}))
    return None
