#!/usr/bin/env python3
"""Erzeugt die SideStore/AltStore-Quelle (source.json) für eine neue Version.

Liest Version, Datenschutz-Schlüssel und Berechtigungen direkt aus der IPA bzw.
der Entitlements-Datei, damit SideStore beim Prüfen keine Abweichung findet.
Ältere Versionen werden aus der bisherigen Quelle übernommen (max. 10).
"""
import argparse
import datetime as dt
import hashlib
import json
import os
import plistlib
import urllib.request
import zipfile


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ipa", required=True)
    ap.add_argument("--entitlements", required=True)
    ap.add_argument("--repo", required=True, help="owner/name")
    ap.add_argument("--tag", required=True)
    ap.add_argument("--notes", default="")
    ap.add_argument("--out", default="source.json")
    a = ap.parse_args()

    with zipfile.ZipFile(a.ipa) as z:
        name = next(n for n in z.namelist() if n.endswith(".app/Info.plist") and n.count("/") == 2)
        info = plistlib.loads(z.read(name))
    with open(a.entitlements, "rb") as f:
        ents = plistlib.load(f)
    data = open(a.ipa, "rb").read()

    base = f"https://github.com/{a.repo}"
    source_url = f"{base}/releases/latest/download/source.json"
    raw = f"https://raw.githubusercontent.com/{a.repo}/main"

    version = {
        "version": info["CFBundleShortVersionString"],
        "buildVersion": info["CFBundleVersion"],
        "date": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "localizedDescription": a.notes.strip() or "Neue Version",
        "downloadURL": f"{base}/releases/download/{a.tag}/SleepSonar.ipa",
        "size": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "minOSVersion": info.get("MinimumOSVersion", "17.0"),
    }

    # bisherige Versionen übernehmen
    older = []
    try:
        with urllib.request.urlopen(source_url, timeout=20) as r:
            prev = json.load(r)
        older = [v for v in prev["apps"][0]["versions"] if v.get("version") != version["version"]]
    except Exception as e:  # erste Veröffentlichung oder Netzfehler
        print("Keine bisherige Quelle:", e)

    privacy = {k: v for k, v in info.items() if k.startswith("NS") and k.endswith("UsageDescription")}
    source = {
        "name": "SleepSonar",
        "identifier": "de.nikgro.sleepsonar.source",
        "sourceURL": source_url,
        "subtitle": "Schlaf-Tracking per Sonar",
        "description": "Eigene Builds von SleepSonar, automatisch aus GitHub.",
        "iconURL": f"{raw}/assets/icon.png",
        "website": base,
        "tintColor": "#6EC8FF",
        "apps": [{
            "name": "SleepSonar",
            "bundleIdentifier": info["CFBundleIdentifier"],
            "developerName": "Niklas Groß",
            "subtitle": "Schlafphasen per Ultraschall",
            "localizedDescription": "Misst Atmung und Bewegung per Ultraschall-Sonar über Lautsprecher "
                                    "und Mikrofon und schreibt Schlafphasen in Apple Health.",
            "iconURL": f"{raw}/assets/icon.png",
            "tintColor": "#6EC8FF",
            "category": "utilities",
            "versions": [version] + older[:9],
            "appPermissions": {
                "entitlements": sorted(ents.keys()),
                "privacy": privacy,
            },
        }],
        "news": [],
    }
    with open(a.out, "w") as f:
        json.dump(source, f, indent=2, ensure_ascii=False)
    print(json.dumps(version, indent=2))


if __name__ == "__main__":
    main()
