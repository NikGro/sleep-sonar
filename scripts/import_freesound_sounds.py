"""Macht aus freien Aufnahmen von freesound.org (nur CC0 / CC BY, Vorschau in hoher Qualität) nahtlose
Schleifen für SleepSonar/SleepSounds/: sucht den ruhigsten, gleichmäßigsten Abschnitt (ohne Anfang und Ende
der Aufnahme), schneidet ihn auf höchstens 60 s und blendet das Ende in den Anfang über. Gleichmäßig
tickende Klänge (Uhr, Herzschlag) werden auf eine ganze Zahl von Schlägen geschnitten, damit die Naht
nicht stolpert. Aufruf: import_freesound_sounds.py <Ordner mit name.ogg> [name …]"""
import os, subprocess, sys
import numpy as np

SRC = sys.argv[1]
ONLY = set(sys.argv[2:])
OUT = os.path.join(os.path.dirname(__file__), "..", "SleepSonar", "SleepSounds")
SR = 44100; MAXLEN = 60; FADE = 2.0; EDGE = 5
PERIODIC = {"uhr", "herzschlag"}


def load(path):
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", path, "-f", "f32le", "-ac", "2", "-ar", str(SR), "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.float32).reshape(-1, 2).astype(np.float64)


def envelope(x, hop):
    m = x.mean(1); n = len(m) // hop
    return np.sqrt((m[: n * hop].reshape(n, hop) ** 2).mean(1) + 1e-12)


def period(x):
    """Schlagabstand in Samples über die Autokorrelation der Hüllkurve (0,3 … 2 s)"""
    hop = 441; e = envelope(x, hop); e = e - e.mean()
    ac = np.correlate(e, e, "full")[len(e) - 1:]
    lo, hi = int(0.3 * SR / hop), int(2.0 * SR / hop)
    return (lo + int(np.argmax(ac[lo:hi]))) * hop


def best_start(x, L):
    """Abschnitt mit gleichmäßigster Lautstärke und ähnlichem Klang an Anfang und Ende"""
    hop = SR // 10; e = np.log(envelope(x, hop)); n = len(e); w = L // hop
    first, last = EDGE * 10, n - w - EDGE * 10
    if last <= first: return max(0, (len(x) - L) // 2)
    best, arg = None, first
    for s in range(first, last, 10):
        seg = e[s:s + w]
        score = seg.std() + 2 * abs(seg[:20].mean() - seg[-20:].mean())
        if best is None or score < best: best, arg = score, s
    return arg * hop


for name in sorted(f[:-4] for f in os.listdir(SRC) if f.endswith(".ogg")):
    if ONLY and name not in ONLY: continue
    x = load(os.path.join(SRC, name + ".ogg"))
    fade = int(SR * FADE)
    L = min(len(x) - fade - 2 * EDGE * SR, SR * MAXLEN)
    if name in PERIODIC:
        p = period(x); L = max(p, (L // p) * p); fade = min(int(SR * 0.25), p // 3)
    s = best_start(x, L + fade)
    seg = x[s:s + L + fade]
    loop = seg[:L].copy()
    r = np.sqrt(np.linspace(0, 1, fade))[:, None]           # gleiche Leistung beim Überblenden
    loop[:fade] = seg[L:L + fade] * np.sqrt(1 - r ** 2) + seg[:fade] * r
    loop = loop / np.max(np.abs(loop)) * 10 ** (-3 / 20)
    tmp = f"/tmp/{name}.f32"; loop.astype("<f4").tofile(tmp)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "f32le", "-ar", str(SR), "-ac", "2", "-i", tmp,
                    "-c:a", "aac", "-b:a", "128k", os.path.join(OUT, f"{name}.m4a")], check=True)
    os.remove(tmp)
    print(name, round(L / SR, 1), "s ab", round(s / SR, 1), "s", "(Takt %.2f s)" % (p / SR) if name in PERIODIC else "")
