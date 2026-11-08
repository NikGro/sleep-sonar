"""Prüft die Übersetzungen: gleiche Anzahl wie _keys.json, gleiche Platzhalter in gleicher Reihenfolge."""
import json, re, sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from strings_en import EN
D = os.path.dirname(os.path.abspath(__file__))
keys = json.load(open(os.path.join(D, "_keys.json")))
P = re.compile(r"%[0-9.]*[@dfs%]|%0\d+d")
ok = True
for lang in sys.argv[1:]:
    tr = json.load(open(os.path.join(D, f"{lang}.json")))
    if len(tr) != len(keys): print(lang, "Anzahl", len(tr), "statt", len(keys)); ok = False; continue
    for i, (k, t) in enumerate(zip(keys, tr)):
        if P.findall(k) != P.findall(t): print(lang, i, "Platzhalter:", EN[k], "|", t); ok = False
        if t == EN[k] and len(t) > 12 and not t.startswith("http"): print(lang, i, "unübersetzt?", t)
print("ok" if ok else "FEHLER")
