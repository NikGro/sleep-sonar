"""Erzeugt die Schlafklänge (eigene Synthese, frei von Rechten) als nahtlose 60-s-Schleifen."""
import numpy as np, subprocess, os
from scipy import signal
SR = 22050; DUR = 60; FADE = 3
N = int(SR * (DUR + FADE)); t = np.arange(N) / SR
rng = np.random.default_rng(7)
OUT = os.path.join(os.path.dirname(__file__), "..", "SleepSonar", "SleepSounds")

def white(): return rng.standard_normal(N)
def pink():
    b, a = [0.049922035, -0.095993537, 0.050612699, -0.004408786], [1, -2.494956002, 2.017265875, -0.522189400]
    return signal.lfilter(b, a, white())
def brown():
    x = np.cumsum(white()); return signal.lfilter([1, -1], [1, -0.995], x)  # Drift entfernen
def lp(x, f): return signal.sosfilt(signal.butter(4, f, "low", fs=SR, output="sos"), x)
def hp(x, f): return signal.sosfilt(signal.butter(2, f, "high", fs=SR, output="sos"), x)
def bp(x, lo, hi): return signal.sosfilt(signal.butter(2, [lo, hi], "band", fs=SR, output="sos"), x)
def slow(period, depth, phase=0): return 1 - depth / 2 + depth / 2 * np.sin(2 * np.pi * t / period + phase)
def norm(x): return x / np.max(np.abs(x))

def rain():
    base = hp(pink(), 400) * 0.6 + lp(white(), 6000) * 0.25
    drops = np.zeros(N); idx = rng.integers(0, N - 400, 9000)
    for i in idx:
        d = rng.uniform(0.2, 1.0) * np.exp(-np.arange(300) / rng.uniform(20, 60))
        drops[i:i + 300] += d * rng.choice([-1, 1])
    return norm(base) + norm(bp(drops, 1500, 8000)) * 0.35

def waves():
    x = lp(pink(), 1200) * 0.8 + lp(white(), 3000) * 0.15
    env = np.zeros(N); period = 9.5
    for k in range(int((DUR + FADE) / period) + 2):
        c = k * period + rng.uniform(-1, 1)
        env += np.exp(-((t - c - 3) / 2.2) ** 2) * rng.uniform(0.7, 1.0)
    return norm(x * (0.15 + env))

def wind():
    x = white(); y = np.zeros(N); seg = SR // 2
    for s in range(0, N, seg):            # langsam wandernde Mittenfrequenz
        f = 420 + 200 * np.sin(2 * np.pi * s / SR / 13) + 100 * np.sin(2 * np.pi * s / SR / 5.3)
        y[s:s + seg] = bp(x[max(0, s - 2048):s + seg], f * 0.6, f * 1.8)[-len(y[s:s + seg]):]
    return norm(lp(y, 2000) * slow(11, 0.8) * slow(4.3, 0.3, 1))

def fire():
    rumble = lp(brown(), 300)
    crack = np.zeros(N); idx = rng.integers(0, N - 800, 1400)
    for i in idx:
        L = rng.integers(60, 600); crack[i:i + L] += rng.standard_normal(L) * np.exp(-np.arange(L) / (L / 4)) * rng.uniform(0.2, 1)
    return norm(rumble) * 0.7 + norm(bp(crack, 800, 7000)) * 0.45 + norm(hp(pink(), 2000)) * 0.05

def fan():
    hum = sum(np.sin(2 * np.pi * f * t) / (k + 1) for k, f in enumerate([100, 200, 300])) * 0.04
    air = lp(pink(), 2500) * (1 + 0.05 * np.sin(2 * np.pi * 18 * t))
    return norm(air) + hum

def pinknoise(): return norm(lp(pink(), 9000))
def brownnoise(): return norm(lp(brown(), 4000))

SOUNDS = {"regen": rain, "wellen": waves, "wind": wind, "kamin": fire, "ventilator": fan,
          "rosa": pinknoise, "braun": brownnoise}
for name, fn in SOUNDS.items():
    x = fn(); n = SR * DUR; f = SR * FADE
    # nahtlos: Ende in den Anfang überblenden
    ramp = np.linspace(0, 1, f)
    loop = x[:n].copy(); loop[:f] = x[n:n + f] * (1 - ramp) + x[:f] * ramp
    loop = loop / np.max(np.abs(loop)) * 10 ** (-3 / 20)
    raw = f"/tmp/{name}.raw"; loop.astype("<f4").tofile(raw)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "f32le", "-ar", str(SR), "-ac", "1", "-i", raw,
                    "-c:a", "aac", "-b:a", "96k", os.path.join(OUT, f"{name}.m4a")], check=True)
    os.remove(raw); print(name)
