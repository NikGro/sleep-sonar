"""Übernimmt freie Naturklänge aus Blanket (github.com/rafaelmardojai/blanket, nur CC0 / gemeinfrei / CC BY)
als nahtlose Schleifen (höchstens 60 s, 2 s überblendet) in SleepSonar/SleepSounds/."""
import numpy as np, subprocess, os, sys
SRC = sys.argv[1] if len(sys.argv) > 1 else "/tmp/blanket/data/resources/sounds"
OUT = os.path.join(os.path.dirname(__file__), "..", "SleepSonar", "SleepSounds")
SR = 44100; MAXLEN = 60; FADE = 2
MAP = {"regen": "rain", "gewitter": "storm", "wellen": "waves", "bach": "stream", "wind": "wind",
       "kamin": "fireplace", "voegel": "birds", "sommernacht": "summer-night", "zug": "train",
       "boot": "boat", "cafe": "coffee-shop", "stadt": "city"}
for name, src in MAP.items():
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", f"{SRC}/{src}.ogg", "-f", "f32le", "-ac", "2",
                          "-ar", str(SR), "-"], capture_output=True, check=True).stdout
    x = np.frombuffer(raw, np.float32).reshape(-1, 2).astype(np.float64)
    f = SR * FADE
    n = min(len(x) - f, SR * MAXLEN)
    loop = x[:n].copy(); r = np.linspace(0, 1, f)[:, None]
    loop[:f] = x[n:n + f] * (1 - r) + x[:f] * r        # Ende in den Anfang überblenden → nahtlos
    loop = loop / np.max(np.abs(loop)) * 10 ** (-3 / 20)
    tmp = f"/tmp/{name}.f32"; loop.astype("<f4").tofile(tmp)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "f32le", "-ar", str(SR), "-ac", "2", "-i", tmp,
                    "-c:a", "aac", "-b:a", "128k", os.path.join(OUT, f"{name}.m4a")], check=True)
    os.remove(tmp); print(name, round(n / SR, 1), "s")
