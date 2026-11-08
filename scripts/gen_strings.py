#!/usr/bin/env python3
"""Schreibt die .strings-Dateien aus strings_en.py und prüft, dass jeder tr("…")-Schlüssel
im Code eine englische Übersetzung hat. Aufruf: python3 scripts/gen_strings.py [--check]"""
import glob, os, re, sys
sys.path.insert(0, os.path.dirname(__file__))
from strings_en import EN, DYNAMIC, INFOPLIST_EN, SHORTCUTS
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def esc(s): return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
def write(path, pairs):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write("/* Erzeugt von scripts/gen_strings.py – nicht von Hand ändern. */\n")
        for k, v in pairs: f.write(f'"{esc(k)}" = "{esc(v)}";\n')

def keys_in_code():
    keys = set()
    pat = re.compile(r'tr\(\s*(?:\w+ \? )?"((?:[^"\\]|\\.)*)"(?:\s*:\s*"((?:[^"\\]|\\.)*)")?')
    for f in glob.glob(f"{ROOT}/SleepSonar/*.swift") + glob.glob(f"{ROOT}/Widgets/*.swift"):
        for m in pat.finditer(open(f, encoding="utf-8").read()):
            keys.update(k.encode().decode("unicode_escape").encode("latin1").decode("utf-8") if "\\" in k else k
                        for k in m.groups() if k)
    return keys | set(DYNAMIC)

missing = sorted(keys_in_code() - set(EN))
if missing:
    print("Ohne englische Übersetzung:"); [print("  ", k) for k in missing]; sys.exit(1)
# Platzhalter müssen übereinstimmen
bad = [k for k, v in EN.items() if re.findall(r"%[0-9.]*[@dfs%]|%0\d+d", k) != re.findall(r"%[0-9.]*[@dfs%]|%0\d+d", v)]
if bad:
    print("Platzhalter passen nicht:"); [print("  ", k) for k in bad]; sys.exit(1)
# weitere Sprachen: scripts/i18n/<sprache>.json – {deutscher Schlüssel: Übersetzung}
import json
I18N = os.path.join(os.path.dirname(os.path.abspath(__file__)), "i18n")
extra = json.load(open(os.path.join(I18N, "_extra.json"), encoding="utf-8"))
LANGS = ["es", "fr", "it", "pt-BR", "nl", "ja", "ko", "zh-Hans"]
P = re.compile(r"%[0-9.]*[@dfs%]|%0\d+d")
problems = []
if "--check" in sys.argv:
    print(f"{len(EN)} Übersetzungen vollständig"); sys.exit(0)

pairs = sorted(EN.items())
for target in ("SleepSonar", "Widgets"):
    write(f"{ROOT}/{target}/en.lproj/Localizable.strings", pairs)
    write(f"{ROOT}/{target}/de.lproj/Localizable.strings", [])
write(f"{ROOT}/SleepSonar/en.lproj/InfoPlist.strings", sorted(INFOPLIST_EN.items()))
write(f"{ROOT}/SleepSonar/en.lproj/AppShortcuts.strings", [(k, v[0]) for k, v in SHORTCUTS.items()])
write(f"{ROOT}/SleepSonar/de.lproj/AppShortcuts.strings", [(k, v[1]) for k, v in SHORTCUTS.items()])
for lang in LANGS:
    d = json.load(open(os.path.join(I18N, f"{lang}.json"), encoding="utf-8"))
    problems += [f"{lang}: fehlt: {k}" for k in sorted(set(EN) - set(d))]
    problems += [f"{lang}: Platzhalter: {k}" for k in EN if k in d and P.findall(k) != P.findall(d[k])]
if problems:
    print("Übersetzungen unvollständig:"); [print("  ", p) for p in problems]; sys.exit(1)
for lang in LANGS:
    d = json.load(open(os.path.join(I18N, f"{lang}.json"), encoding="utf-8"))
    lp = sorted((k, d[k]) for k in EN)
    for target in ("SleepSonar", "Widgets"):
        write(f"{ROOT}/{target}/{lang}.lproj/Localizable.strings", lp)
    write(f"{ROOT}/SleepSonar/{lang}.lproj/InfoPlist.strings", sorted(extra["infoplist"][lang].items()))
    write(f"{ROOT}/SleepSonar/{lang}.lproj/AppShortcuts.strings", list(zip(SHORTCUTS.keys(), extra["shortcuts"][lang])))
print("geschrieben:", len(pairs), "Einträge,", 2 + len(LANGS), "Sprachen")
