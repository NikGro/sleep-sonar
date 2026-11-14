"""Neue Texte in alle Sprachen eintragen und ungenutzte entfernen.
Aufruf: python3 scripts/i18n/update.py neu.json   (neu.json: {deutscher Text: {"en": …, "es": …, …}})
Ohne Datei: nur ungenutzte Texte aus strings_en.py und allen Sprachdateien entfernen."""
import glob, json, os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__)); SCRIPTS = os.path.dirname(HERE); ROOT = os.path.dirname(SCRIPTS)
sys.path.insert(0, SCRIPTS)
g = open(os.path.join(SCRIPTS, "gen_strings.py")).read(); ns = {"__file__": os.path.join(SCRIPTS, "gen_strings.py")}
exec(g.split("# weitere Sprachen")[0].split("missing = sorted")[0], ns)
used = ns["keys_in_code"]()
from strings_en import EN
src = "".join(open(f, encoding="utf-8").read() for f in glob.glob(f"{ROOT}/Suya/*.swift") + glob.glob(f"{ROOT}/Widgets/*.swift"))
new = json.load(open(sys.argv[1], encoding="utf-8")) if len(sys.argv) > 1 else {}
keep = lambda k: k in used or ('"' + k + '"') in src or k in new
en = {k: v for k, v in EN.items() if keep(k)}
en.update({k: v["en"] for k, v in new.items()})
q = lambda s: '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'
p = os.path.join(SCRIPTS, "strings_en.py"); s = open(p, encoding="utf-8").read()
a = s.index("EN = {"); b = s.index("\n}\n", a) + 3
s = s[:a] + "EN = {\n" + "".join(f"{q(k)}: {q(v)},\n" for k, v in en.items()) + "}\n" + s[b:]
open(p, "w", encoding="utf-8").write(s)
for f in glob.glob(os.path.join(HERE, "*.json")):
    lang = os.path.basename(f)[:-5]
    if lang.startswith("_"): continue
    d = json.load(open(f, encoding="utf-8"))
    d = {k: v for k, v in d.items() if keep(k)}
    for k, v in new.items(): d[k] = v[lang]
    json.dump(d, open(f, "w", encoding="utf-8"), ensure_ascii=False, indent=1, sort_keys=True)
print("Texte:", len(en), "neu:", len(new), "entfernt:", len(EN) - len(en) + len([k for k in new if k in EN]))
