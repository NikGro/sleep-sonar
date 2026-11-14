"""Einstellungen. Alles über Umgebungsvariablen änderbar, was sich je Installation unterscheidet."""
import os
import re

DATA = os.environ.get("DATA", "/data")                   # Spenden, Fehlerberichte, Protokoll
SITE = os.environ.get("SITE", "/site")                   # fertige Seiten (site_src/build.py)
PORT = int(os.environ.get("PORT", "8770"))

# Spenden
MAX_BYTES = int(os.environ.get("MAX_BYTES", str(80 * 2**20)))   # ein ganzes Nachtpaket
KEEP_DAYS = int(os.environ.get("KEEP_DAYS", "183"))             # 6 Monate
NIGHTS_PER_DONOR_DAY = 4
OPEN_PER_DONOR = 2                                       # gleichzeitig unvollständige Nächte je Spender
DONOR_DAY_BYTES = 400 * 2**20
PART_MAX = 8 * 2**20                                     # ein Teil (die App sendet 4 MB)
PART_KEEP = 86400                                        # unvollständige Nächte nach 24 h verwerfen
MAX_PARTS = 64

# Fehlerberichte
BUG_KEEP_DAYS = 365
BUG_MAX = 400 * 1024                                     # Text, technische Angaben, bis zu 5 Absturzprotokolle
BUG_PER_IP_HOUR = 10
BUG_PER_DAY = 200

# allgemein
REQUESTS_PER_IP_HOUR = 300
DAY_BYTES = 4 * 2**30                                    # höchstens 4 GB pro Tag insgesamt
MIN_FREE = int(os.environ.get("MIN_FREE", str(30 * 2**30)))   # so viel auf der Platte frei lassen
LOG_MAX = 5 * 2**20                                      # protokoll.jsonl danach einmal umbenennen (.1)

# App Attest
ATTEST = os.environ.get("ATTEST", "optional")            # off | optional | required
APP_ID = os.environ.get("APP_ID", "")                    # "TEAMID.de.nikgro.sleepsonar"; leer = aus
ATTEST_ENV = os.environ.get("ATTEST_ENV", "production")
CHALLENGE_SECONDS = 300
MAX_CHALLENGES = 5000

DONOR_ID = re.compile(r"^[0-9A-F]{8}$")
NIGHT_ID = re.compile(r"^[0-9A-Za-z-]{8,40}$")
KEY = re.compile(r"^[0-9A-Za-z-]{32,64}$")
SHA256_HEX = re.compile(r"^[0-9a-f]{64}$")
