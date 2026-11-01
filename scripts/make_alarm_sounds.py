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

SOUNDS = {"morgenlicht": marimba, "harfe": harp, "glocke": bell, "klassisch": classic,
          "voegel": lambda: from_loop("voegel"), "bach": lambda: from_loop("bach"), "wellen": lambda: from_loop("wellen")}
for name, fn in SOUNDS.items():
    x = fn(); x[-int(0.05 * SR):] *= np.linspace(1, 0, int(0.05 * SR)); x /= np.max(np.abs(x))
    y = (x * 10 ** (-1 / 20) * 32767).astype("<i2"); raw = f"/tmp/{name}.raw"; y.tofile(raw)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "s16le", "-ar", str(SR), "-ac", "1", "-i", raw,
                    "-c:a", "aac", "-b:a", "128k", os.path.join(OUT, f"wecker_{name}.m4a")], check=True)
    os.remove(raw); print(name)
