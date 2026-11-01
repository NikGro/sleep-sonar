import numpy as np, subprocess, os
SR = 22050; DUR = 30.0
t = np.arange(int(SR * DUR)) / SR
rng = np.random.default_rng(1)

def env(start, a=0.01, d=1.5):
    x = np.zeros_like(t); i = int(start * SR)
    n = len(t) - i; tt = np.arange(n) / SR
    x[i:] = np.minimum(tt / a, 1) * np.exp(-tt / d); return x

def tone(f, start, d=1.5, harm=(1, .3, .1)):
    e = env(start, d=d)
    return sum(h * np.sin(2 * np.pi * f * (k + 1) * t) for k, h in enumerate(harm)) * e

def morgenlicht():   # sanftes Arpeggio, wird dichter
    notes = [523.25, 659.25, 783.99, 1046.5]
    x = np.zeros_like(t); s = 0.0; step = 0.9
    while s < DUR - 1:
        for i, f in enumerate(notes):
            x += tone(f, s + i * step / 4, d=1.8, harm=(1, .15, .05))
        s += step * 2.2; step = max(0.45, step * 0.93)
    return x

def glocke():        # FM-Glocke, alle 2 s
    x = np.zeros_like(t)
    for s in np.arange(0, DUR - 1, 2.0):
        e = env(s, a=0.003, d=2.2); m = 1.4 * e
        x += np.sin(2 * np.pi * 440 * t + m * 3 * np.sin(2 * np.pi * 440 * 1.41 * t)) * e
    return x

def klassisch():     # Doppelpiep, weich gerundet
    x = np.zeros_like(t)
    for s in np.arange(0, DUR - 0.5, 1.0):
        for k in (0, 0.18):
            i0 = int((s + k) * SR); n = int(0.12 * SR)
            w = np.sin(np.pi * np.arange(n) / n) ** 0.5
            x[i0:i0 + n] += np.sign(np.sin(2 * np.pi * 1760 * t[i0:i0 + n])) * 0.35 * w + np.sin(2 * np.pi * 1760 * t[i0:i0 + n]) * 0.5 * w
    return x

def wellen():        # Rauschen in Wellen + leise Glöckchen
    noise = rng.standard_normal(len(t))
    # Tiefpass (einfach): gleitender Mittelwert
    k = 40; noise = np.convolve(noise, np.ones(k) / k, mode="same")
    swell = 0.5 - 0.5 * np.cos(2 * np.pi * t / 7.0)
    x = noise * swell * 3
    for s in np.arange(3, DUR - 1, 7.0):
        x += tone(1318.5, s, d=2.5, harm=(1, .1)) * 0.3
    return x

SOUNDS = {"morgenlicht": morgenlicht, "glocke": glocke, "klassisch": klassisch, "wellen": wellen}
os.makedirs("out", exist_ok=True)
for name, fn in SOUNDS.items():
    x = fn()
    x[-int(0.05 * SR):] *= np.linspace(1, 0, int(0.05 * SR))
    x /= np.max(np.abs(x))
    # Grundton in voller Lautstärke; Lautstärke und Anstieg rechnet die App je Wecker hinein
    y = (x * 10 ** (-1 / 20) * 32767).astype("<i2")
    raw = f"out/{name}.raw"; y.tofile(raw)
    dst = f"/home/claude/sleepsonar/SleepSonar/Sounds/{name}.caf"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "s16le", "-ar", str(SR), "-ac", "1", "-i", raw,
                    "-c:a", "pcm_s16le", dst], check=True)
    os.remove(raw)
print("ok")
