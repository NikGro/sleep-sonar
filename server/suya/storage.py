"""Ablage auf der Platte. Verzeichnis- und Dateinamen sind Teil des Datenbestands auf dem NAS und bleiben deutsch:

  spender/<Nummer>/schluessel.sha256   Hash des geheimen Schlüssels der Installation
  spender/<Nummer>/appattest.json      öffentlicher App-Attest-Schlüssel und Zähler
  spender/<Nummer>/naechte/<id>.suya   gespendete Nächte; .<id>.teile/ = noch unvollständig
  fehler/<id>.json                     Fehlerberichte
  protokoll.jsonl                      Ereignisse ohne IP-Adressen (Nachweis von Löschungen)
"""
import hashlib
import hmac
import json
import os
import shutil
import time

from . import config

status = {"cleanup": None}                               # letzter Lauf der Löschroutine


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def donor_dir(donor):
    return os.path.join(config.DATA, "spender", donor)


def nights_dir(donor):
    return os.path.join(donor_dir(donor), "naechte")


def night_file(donor, night):
    return os.path.join(nights_dir(donor), night + ".suya")


def parts_dir(donor, night):
    return os.path.join(nights_dir(donor), f".{night}.teile")


def attest_file(donor):
    return os.path.join(donor_dir(donor), "appattest.json")


def _key_file(donor):
    return os.path.join(donor_dir(donor), "schluessel.sha256")


def write_atomic(path, text):
    with open(path + ".tmp", "w") as f:
        f.write(text)
    os.replace(path + ".tmp", path)


def key_matches(donor, key):
    """True/False, ob der Schlüssel passt; None, wenn für die Nummer noch keiner hinterlegt ist."""
    path = _key_file(donor)
    if not os.path.exists(path):
        return None
    with open(path) as f:
        stored = f.read().strip()
    return hmac.compare_digest(stored, hashlib.sha256(key.encode()).hexdigest())


def store_key(donor, key):
    os.makedirs(donor_dir(donor), exist_ok=True)
    write_atomic(_key_file(donor), hashlib.sha256(key.encode()).hexdigest())


def delete_donor(donor):
    shutil.rmtree(donor_dir(donor), ignore_errors=True)


def log_event(kind, donor):
    """Nur Ereignis, Spender-Nummer und Zeit."""
    path = os.path.join(config.DATA, "protokoll.jsonl")
    try:
        if os.path.getsize(path) > config.LOG_MAX:
            os.replace(path, path + ".1")
    except OSError:
        pass
    with open(path, "a") as f:
        f.write(json.dumps({"t": now_iso(), "ereignis": kind, "spender": donor}) + "\n")


def free_bytes():
    return shutil.disk_usage(config.DATA).free


def _remove(path):
    if os.path.isdir(path):
        shutil.rmtree(path, ignore_errors=True)
    else:
        os.remove(path)


def _listdir(path):
    return os.listdir(path) if os.path.isdir(path) else []


def cleanup_once():
    """Nächte nach KEEP_DAYS, Fehlerberichte nach BUG_KEEP_DAYS, unvollständige Uploads nach 24 h löschen.
    Ein Fehler bei einem Eintrag hält den Rest nicht auf. Gibt die Zahl der Probleme zurück."""
    now = time.time()
    cut_nights = now - config.KEEP_DAYS * 86400
    cut_bugs = now - config.BUG_KEEP_DAYS * 86400
    problems = 0
    for donor in _listdir(os.path.join(config.DATA, "spender")):
        folder = nights_dir(donor)
        for name in _listdir(folder):
            path = os.path.join(folder, name)
            try:
                age = os.path.getmtime(path)
                if name.startswith("."):
                    if age < now - config.PART_KEEP:
                        _remove(path)
                elif age < cut_nights:
                    _remove(path)
                    log_event("abgelaufen", donor)
            except Exception as e:
                problems += 1
                print("Aufräumen:", type(e).__name__, e, flush=True)
    bugs = os.path.join(config.DATA, "fehler")
    for name in _listdir(bugs):
        path = os.path.join(bugs, name)
        try:
            if os.path.getmtime(path) < cut_bugs:
                _remove(path)
        except Exception as e:
            problems += 1
            print("Aufräumen:", type(e).__name__, e, flush=True)
    status["cleanup"] = now_iso()
    return problems


def cleanup_loop():
    """Stündlich aufräumen; der Thread überlebt jeden Fehler."""
    while True:
        try:
            cleanup_once()
        except Exception as e:
            print("Aufräumen fehlgeschlagen:", type(e).__name__, e, flush=True)
        time.sleep(3600)
