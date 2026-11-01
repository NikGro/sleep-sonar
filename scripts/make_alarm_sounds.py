"""Wecktöne für Suya (30 s als m4a, volle Lautstärke; Lautstärke und Anstieg rechnet die App je Wecker hinein).
Selbst erzeugt: Morgenlicht (Marimba), Harfe, Glocke, Klassisch. Natur: Vögel, Bach (CC0, aus SleepSounds)."""
import numpy as np, subprocess, os
from scipy import signal
SR = 44100; DUR = 30
t = np.arange(SR * DUR) / SR
OUT = os.path.join(os.path.dirname(__file__), "..", "SleepSonar", "Sounds")
rng = np.random.default_rng(3)

def reverb(x, rt=1.8, mix=0.25):
    L = int(rt * SR); ir = rng.standard_normal(L) * np.exp(-np.arange(L) / (rt * SR / 6.9))
    ir = signal.sosfilt(signal.butter(2, 5000, "low", fs=SR, output="sos"), ir); ir /= np.sqrt((ir ** 2).sum())
    return (1 - mix) * x + mix * signal.fftconvolve(x, ir)[:len(x)] * 3

def note(f, start, dur, partials, decays, amps):
    n = int(dur * SR); i = int(start * SR); tt = np.arange(n) / SR; y = np.zeros(n)
    for p, d, a in zip(partials, decays, amps): y += a * np.sin(2 * np.pi * f * p * tt) * np.exp(-tt / d)
    y *= np.minimum(tt / 0.004, 1); out = np.zeros(len(t)); out[i:i + n] = y[:max(0, min(n, len(t) - i))]; return out

def marimba():
    scale = [523.25, 587.33, 659.25, 783.99, 880.0, 1046.5]   # C-Dur pentatonisch
    pattern = [0, 2, 4, 3, 5, 4, 2, 1]; x = np.zeros(len(t)); s = 0.3; k = 0
    while s < DUR - 1.5:
        f = scale[pattern[k % len(pattern)]]
        x += note(f, s, 1.5, [1, 3.93, 9.2], [0.45, 0.12, 0.04], [1, 0.35, 0.12]); s += 0.32; k += 1
        if k % 8 == 0: s += 0.9
    return reverb(x)

def karplus(f, start, dur=2.5):
    n = int(dur * SR); N = int(SR / f); buf = rng.uniform(-1, 1, N); y = np.zeros(n)
    for i in range(n):
        y[i] = buf[i % N]; buf[i % N] = 0.996 * 0.5 * (buf[i % N] + buf[(i + 1) % N])
    out = np.zeros(len(t)); i0 = int(start * SR); m = max(0, min(n, len(t) - i0)); out[i0:i0 + m] = y[:m]; return out

def harp():
    chord = [261.63, 329.63, 392.0, 523.25, 659.25, 783.99, 1046.5]; x = np.zeros(len(t)); s = 0.2
    while s < DUR - 2.5:
        for j, f in enumerate(chord): x += karplus(f, s + j * 0.11) * 0.6
        s += 3.2
    return reverb(x, 2.2, 0.3)

def bell():
    x = np.zeros(len(t))
    for s in np.arange(0.2, DUR - 3, 3.0):
        x += note(392.0, s, 4.0, [0.56, 1, 1.19, 1.71, 2.0, 2.74, 3.0], [2.5, 2.2, 1.6, 1.0, 0.9, 0.6, 0.5],
                  [0.5, 1, 0.6, 0.4, 0.35, 0.25, 0.2])
    return reverb(x, 2.5, 0.3)

def classic():
    x = np.zeros(len(t))
    for s in np.arange(0.2, DUR - 0.5, 1.2):
        for k in range(4):
            x += note(1318.5, s + k * 0.13, 0.11, [1, 2, 3], [0.06, 0.04, 0.03], [1, 0.25, 0.1]) * \
                 (np.arange(len(t)) < int((s + k * 0.13 + 0.09) * SR))
    return reverb(x, 0.6, 0.15)

def from_loop(name):
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i",
                          os.path.join(os.path.dirname(__file__), "..", "SleepSonar", "SleepSounds", f"{name}.m4a"),
                          "-t", str(DUR), "-f", "f32le", "-ac", "1", "-ar", str(SR), "-"], capture_output=True, check=True).stdout
    x = np.frombuffer(raw, np.float32).astype(np.float64); return np.pad(x, (0, max(0, len(t) - len(x))))[:len(t)]


# --- Melodien (eigene Kompositionen) ---
def midi(n): return 440.0 * 2 ** ((n - 69) / 12)

def pad(freqs, start, dur, amp=0.12):
    n = int(dur * SR); i = int(start * SR); tt = np.arange(n) / SR
    env = np.minimum(tt / 1.2, 1) * np.minimum((dur - tt) / 1.2, 1)
    y = sum(np.sin(2 * np.pi * f * tt) + 0.3 * np.sin(2 * np.pi * 2 * f * tt + 0.3) for f in freqs) * env * amp
    out = np.zeros(len(t)); m = max(0, min(n, len(t) - i)); out[i:i + m] = y[:m]; return out

def sunrise():
    # D-Dur, ruhig aufsteigend: Melodie (Celesta) über weichen Flächen, 2 Takte je Akkord
    chords = [[62, 66, 69], [59, 62, 66], [55, 59, 62], [57, 61, 64]]       # D  Hm  G  A
    melody = [(74, 1), (76, .5), (78, .5), (81, 1.5), (78, .5), (76, 1), (74, 1), (73, 1), (71, 1),
              (74, 1), (76, .5), (78, .5), (79, 1.5), (81, .5), (83, 1), (81, 1), (78, 2)]
    beat = 0.5; x = np.zeros(len(t)); bar = 0.0
    while bar < DUR - 1:
        for k, c in enumerate(chords):
            x += pad([midi(n) for n in c], bar + k * 8 * beat, 8 * beat + 1)
        tpos = bar
        for n, d in melody:
            x += note(midi(n), tpos, 2.0, [1, 2, 4.2], [0.9, 0.35, 0.12], [1, 0.25, 0.08]) * 0.6
            tpos += d * beat * 2
        bar += 32 * beat
    return reverb(x, 2.4, 0.35)

def musicbox():
    # 3/4-Walzer in F-Dur, Spieluhr-Klang (hohe Teiltöne, kurzes Abklingen)
    tune = [77, 81, 84, 81, 79, 77, 76, 79, 84, 82, 81, 79, 77, 81, 84, 89, 88, 86, 84, 82, 81, 79, 77, 77]
    bass = [53, 60, 57, 52, 60, 55, 53, 60]
    beat = 0.36; x = np.zeros(len(t)); s0 = 0.2
    while s0 < DUR - 2:
        for i, n in enumerate(tune):
            x += note(midi(n), s0 + i * beat, 1.6, [1, 2.0, 5.4, 9.9], [0.9, 0.45, 0.12, 0.05], [1, 0.4, 0.2, 0.08]) * 0.55
        for j, n in enumerate(bass):
            x += note(midi(n), s0 + j * 3 * beat, 1.8, [1, 2.0], [0.8, 0.3], [0.6, 0.2]) * 0.4
        s0 += len(tune) * beat + 0.8
    return reverb(x, 1.6, 0.25)

def guitar():
    # I – V – vi – IV in C, gezupfte Arpeggios mit kleiner Melodie obenauf
    prog = [[48, 52, 55, 60, 64], [43, 50, 55, 59, 62], [45, 52, 57, 60, 64], [41, 48, 53, 57, 60]]
    top = [76, 74, 72, 72]
    x = np.zeros(len(t)); s0 = 0.2; step = 0.24
    while s0 < DUR - 3:
        for k, ch in enumerate(prog):
            base = s0 + k * 8 * step
            for j, n in enumerate(ch + ch[-2:0:-1][:3]):
                x += karplus(midi(n), base + j * step, 2.2) * 0.5
            x += karplus(midi(top[k]), base + 4 * step, 2.5) * 0.6
        s0 += len(prog) * 8 * step
    return reverb(x, 1.8, 0.25)

SOUNDS = {"sonnenaufgang": sunrise, "spieluhr": musicbox, "gitarre": guitar, "morgenlicht": marimba, "harfe": harp, "glocke": bell, "klassisch": classic,
          "voegel": lambda: from_loop("voegel"), "bach": lambda: from_loop("bach"), "wellen": lambda: from_loop("wellen"),
          "stille": lambda: np.zeros(len(t)) + 1e-6}
for name, fn in SOUNDS.items():
    x = fn(); x[-int(0.05 * SR):] *= np.linspace(1, 0, int(0.05 * SR))
    if name != "stille": x /= np.max(np.abs(x))
    y = (x * 10 ** (-1 / 20) * 32767).astype("<i2"); raw = f"/tmp/{name}.raw"; y.tofile(raw)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "s16le", "-ar", str(SR), "-ac", "1", "-i", raw,
                    "-c:a", "aac", "-b:a", "128k", os.path.join(OUT, f"wecker_{name}.m4a")], check=True)
    os.remove(raw); print(name)
