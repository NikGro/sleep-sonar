"""Erzeugt die Seiten (Start, Datenschutz, Impressum) in allen Sprachen aus texts/<sprache>.json.
Aufruf: python3 server/site_src/build.py  → schreibt nach server/site/
Deutsch liegt unter /, die anderen Sprachen unter /<code>/ (en, es, fr, it, pt, nl, ja, ko, zh)."""
import html, json, os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(HERE), "site")
LANGS = ["de", "en", "es", "fr", "it", "pt", "nl", "ja", "ko", "zh"]
NAMES = {"de": "Deutsch", "en": "English", "es": "Español", "fr": "Français", "it": "Italiano", "pt": "Português",
         "nl": "Nederlands", "ja": "日本語", "ko": "한국어", "zh": "简体中文"}
HTML_LANG = {"pt": "pt-BR", "zh": "zh-Hans"}
EMAIL = "Niklas.Gross@outlook.com"
ADDRESS = "Niklas Groß<br>Lorichsstraße 3<br>22307 Hamburg"


def base(lang):
    return "/" if lang == "de" else f"/{lang}/"


def url(lang, page):
    if lang == "de":
        return {"index": "/", "privacy": "/datenschutz", "imprint": "/impressum"}[page]
    return {"index": f"/{lang}", "privacy": f"/{lang}/privacy", "imprint": f"/{lang}/imprint"}[page]


def path(lang, page):
    if lang == "de":
        return {"index": "index.html", "privacy": "datenschutz.html", "imprint": "impressum.html"}[page]
    return f"{lang}/{page}.html"


def mail():
    return f'<a href="mailto:{EMAIL}">{EMAIL}</a>'


def page(lang, T, kind, title, body):
    langs = " · ".join(f'<a href="{url(l, kind)}" lang="{HTML_LANG.get(l, l)}"{" aria-current=\"page\"" if l == lang else ""}>{NAMES[l]}</a>'
                       for l in LANGS)
    other = "imprint" if kind == "privacy" else "privacy"
    nav = (f'<a href="{url(lang, "privacy")}">{T["nav_privacy"]}</a><a href="{url(lang, "imprint")}">{T["nav_imprint"]}</a>'
           if kind == "index" else f'<a href="{url(lang, other)}">{T["nav_" + other]}</a>')
    return f"""<!DOCTYPE html>
<html lang="{HTML_LANG.get(lang, lang)}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)} – Suya</title>
<link rel="icon" href="/favicon.svg">
<link rel="stylesheet" href="/style.css">
</head>
<body>
<main>
<header><img src="/favicon.svg" alt=""><a href="{url(lang, 'index')}">Suya</a>
<nav>{nav}</nav></header>
{body}
<footer><a href="{url(lang, 'privacy')}">{T["nav_privacy"]}</a> · <a href="{url(lang, 'imprint')}">{T["nav_imprint"]}</a><br><span class="langs">{langs}</span></footer>
</main>
</body>
</html>
"""


def privacy(lang, T):
    d = lambda k: T[k]
    authoritative = "" if lang == "de" else f' {d("authoritative").format(link=url("de", "privacy"))}'
    b = f"""<h1>{d("p_title")}</h1>
<p class="muted">{d("p_sub")}{authoritative}</p>

<div class="card"><p><strong>{d("short_label")}</strong> {d("short").format(donation="#spende" if lang == "de" else "#donation")}</p></div>

<h2>1. {d("h_controller")}</h2>
<address>{ADDRESS}<br>{d("country")}{d("email_label")}: {mail()}</address>
<p>{d("dpo")}</p>

<h2>2. {d("h_device")}</h2>
<h3>{d("mic_h")}</h3><p>{d("mic_p")}</p>
<h3>{d("motion_h")}</h3><p>{d("motion_p")}</p>
<h3>{d("health_h")}</h3><p>{d("health_p")}</p>
<h3>{d("alarm_h")}</h3><p>{d("alarm_p")}</p>
<h3>{d("share_h")}</h3><p>{d("share_p")}</p>
<p><strong>{d("basis_label")}</strong> {d("device_basis")}</p>

<h2 id="{'spende' if lang == 'de' else 'donation'}">3. {d("h_donation")}</h2>
<p>{d("don_p")}</p>
<h3>{d("what_h")}</h3>
<ul><li>{d("what_1")}</li><li>{d("what_2")}</li><li>{d("what_3")}</li></ul>
<p>{d("which_p")}</p>
<h3>{d("purpose_h")}</h3><p>{d("purpose_p")}</p>
<h3>{d("basis_h")}</h3><p>{d("basis_p")}</p>
<h3>{d("where_h")}</h3><p>{d("where_p1")}</p><p>{d("where_p2")}</p><p>{d("attest_p")}</p>
<h3>{d("withdraw_h")}</h3><p>{d("withdraw_p")}</p>

<h2>4. {d("h_web")}</h2>
<p>{d("web_p")}</p>

<h2>5. {d("bug_h")}</h2>
<p>{d("bug_p")}</p>

<h2>6. {d("h_rights")}</h2>
<p>{d("rights_p1")}</p>
<p>{d("rights_p2")}</p>

<h2>7. {d("h_medical")}</h2>
<p>{d("medical_p")}</p>

<h2>8. {d("h_changes")}</h2>
<p>{d("changes_p")}</p>"""
    return page(lang, T, "privacy", T["p_title"], b)


def imprint(lang, T):
    b = f"""<h1>{T["i_title"]}</h1>
<p class="muted">{T["i_sub"]}</p>
<div class="card">
<address>{ADDRESS}<br>{T["country_plain"]}</address>
<p>{T["email_label"]}: {mail()}</p>
</div>
<h2>{T["i_resp_h"]}</h2>
<p>{T["i_resp_p"]}</p>
<h2>{T["i_note_h"]}</h2>
<p>{T["i_note_1"]}</p>
<p>{T["i_note_2"]}</p>"""
    return page(lang, T, "imprint", T["i_title"], b)


def index(lang, T):
    b = f"""<h1>{T["x_title"]}</h1>
<p>{T["x_p"]}</p>
<div class="card"><p><strong>{T["x_card_b"]}</strong> {T["x_card"]}</p></div>
<p class="muted">{T["x_muted"]}</p>"""
    return page(lang, T, "index", T["x_title"], b)


if __name__ == "__main__":
    base_keys = None
    for lang in LANGS:
        T = json.load(open(os.path.join(HERE, "texts", f"{lang}.json"), encoding="utf-8"))
        if base_keys is None: base_keys = set(T)
        missing = base_keys - set(T)
        assert not missing, (lang, missing)
        for kind, fn in (("index", index), ("privacy", privacy), ("imprint", imprint)):
            p = os.path.join(OUT, path(lang, kind))
            os.makedirs(os.path.dirname(p), exist_ok=True)
            open(p, "w", encoding="utf-8").write(fn(lang, T))
    print("Seiten geschrieben:", len(LANGS), "Sprachen")
