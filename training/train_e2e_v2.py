"""Suya-Modell v2: wie train_e2e.py (Spektrogramm -> Merkmale je 30-s-Epoche -> GRU über die Nacht),
aber robust gegen eigene Schlafklänge.

Neu gegenüber v1:
1. Robuste Normierung je Nacht: je Band den Median abziehen, durch die Medianabweichung (MAD) aller
   Werte teilen statt durch die Standardabweichung. Eine laute Stunde (Regen, Meer …) verzerrt so die
   ganze Nacht kaum noch. -> Die App muss beim Einbau dieses Modells genauso normieren (LogMel, robust).
2. Klänge ins Training mischen: Die Schlafklänge der App (training/model/sleep_sounds_logmel.npz) werden
   zufällig in Labor- und eigene Nächte gemischt (Leistung addiert im Log-Mel), verschieden lang und laut,
   mit 30 s Ausblenden. Die Normierung bleibt die der Nacht ohne Klang - genau das soll die robuste
   Normierung leisten.

Aufruf: python train_e2e_v2.py <psg-dir> <home-dir> <out-dir> <sounds.npz>
  TEST="nacht7,..."   diese Nächte nicht lernen, nur prüfen (je mit und ohne künstlichen Klang)
  FINAL=1             danach mit allen Nächten lernen und model_e2e_v2.pt speichern
"""
import glob, json, os, sys, time
import numpy as np, soundfile as sf, torch, torch.nn as nn, torchaudio

dev = "cuda" if torch.cuda.is_available() else "cpu"; torch.manual_seed(0); np.random.seed(0)
if os.name == "nt":   # niedrige Priorität, damit der PC bedienbar bleibt
    import ctypes; ctypes.windll.kernel32.SetPriorityClass(ctypes.windll.kernel32.GetCurrentProcess(), 0x4000)
if dev == "cuda":
    # nie mehr als ~85 % des Grafikspeichers: sonst lagert Windows in den Arbeitsspeicher aus
    # (vielfach langsamer, PC laggt) - lieber nimmt cuDNN dann einen sparsameren Rechenweg
    torch.cuda.set_per_process_memory_fraction(float(os.environ.get("GPU_FRACTION", "0.85")))
    torch.backends.cudnn.benchmark = False
psgdir, homedir, out, soundfile = sys.argv[1:5]
W_NIGHT = int(os.environ.get("W_NIGHT", "20"))
P_SOUND = float(os.environ.get("P_SOUND", "0.5"))
ITERS = int(os.environ.get("ITERS", "2500"))
NAMES = ["Wach", "REM", "Kern", "Tief"]; t0 = time.time()
mel = torchaudio.transforms.MelSpectrogram(16000, n_fft=1024, hop_length=1600, n_mels=64, f_min=50, f_max=7800).to(dev)

def robust_stats(M):
    """M: (64, T) roh. Median je Band, Skala = 1.4826 * Median |M - med| (über alle Werte)."""
    med = M.median(1, keepdim=True).values
    d = (M - med).abs().flatten()
    # sehr lange Vektoren: jeden k-ten Wert nehmen (gleichmäßig, wiederholbar - die App macht es genauso:
    # Reihenfolge Band für Band, k = aufgerundet Anzahl / 4 Mio., Median = unterer Median wie torch)
    if d.numel() > 4_000_000: d = d[:: -(-d.numel() // 4_000_000)]
    # Untergrenze: Nächte mit viel völliger Stille (gleiche Werte) hätten sonst eine winzige Skala und
    # riesige Werte - das hat in Lauf 021 die BatchNorm-Statistik zerstört (Modell sagte nur noch Kern)
    sd = float((M - med).std())
    return med, max(float(1.4826 * d.median()), 0.25 * sd, 0.3)

def logmel(path, lab):
    """-> roh (n, 64, 300) half, Median (64,1), Skala"""
    x, sr = sf.read(path, dtype="float32")
    n = min(len(x) // (sr * 30), len(lab)); x = x[:n * 30 * sr]
    M = []
    for s in range(0, len(x), sr * 600):
        seg = torch.tensor(x[s:s + sr * 600], device=dev)
        M.append(torch.log(mel(seg) + 1e-10)[:, : len(seg) // 1600])
    M = torch.cat(M, 1)[:, : n * 300]
    med, sc = robust_stats(M)
    raw = M.T.reshape(n, 300, 64).permute(0, 2, 1).contiguous()
    return raw.half().cpu(), med.view(1, 64, 1).cpu(), sc, lab[:n]

def norm(raw, med, sc): return ((raw.float() - med.to(raw.device)) / sc).clamp(-12, 12)

# Schlafklänge (roh, (64, T)), auf Median 0 je Band gebracht
bank = [torch.tensor(v.astype(np.float32)) for v in np.load(soundfile).values()]
bank = [b - b.median(1, keepdim=True).values for b in bank if b.shape[1] >= 20]

def add_sound(raw, med, rng=np.random):
    """raw: (L, 64, 300) roh auf dev. Mischt einen Klang über einen zufälligen Abschnitt (mit Ausblenden)."""
    L = raw.shape[0]; T = L * 300
    snd = bank[rng.randint(len(bank))].to(raw.device)
    # Pegel: 5 … 35 dB über dem Grundpegel der Nacht (Leistung, natürlicher Log)
    lvl = rng.uniform(5, 35) * np.log(10) / 10
    tilt = (rng.rand() - 0.5) * torch.linspace(-1, 1, 64, device=raw.device).view(64, 1)   # Lautsprecher/Raum
    reps = T // snd.shape[1] + 2; off = rng.randint(snd.shape[1])
    s = snd.repeat(1, reps)[:, off:off + T] + med.view(64, 1).to(raw.device) + lvl + tilt
    # Abschnitt: oft ab Beginn (Einschlafen), sonst irgendwo; mind. 10 min oder die ganze Strecke
    a = 0 if rng.rand() < 0.6 else rng.randint(T)
    b = min(T, a + rng.randint(min(T, 6000), T + 1))
    env = torch.full((T,), -30.0, device=raw.device)
    env[a:b] = 0
    fade = min(300, b - a)
    if b < T and fade > 0:   # 30 s Ausblenden
        env[b - fade:b] = torch.linspace(0, -12, fade, device=raw.device)
    s = s + env.view(1, T)
    x = raw.float().permute(1, 0, 2).reshape(64, T)
    x = torch.logaddexp(x, s)
    return x.reshape(64, L, 300).permute(1, 0, 2)

lab_data = []
files = sorted(glob.glob(os.path.join(psgdir, "*.flac")))
for i, f in enumerate(files):
    y = np.load(f[:-5] + ".labels.npy").astype(np.int64)
    if (y >= 0).sum() < int(os.environ.get("LAB_MIN", "240")) or (y > 0).sum() < 60 // (1 + 9 * ("LAB_MIN" in os.environ)): continue
    raw, med, sc, y = logmel(f, y)
    lab_data.append((raw, med, sc, torch.tensor(y)))
    if i % 50 == 0: print(f"Labor {i}/{len(files)}  %.0f s" % (time.time() - t0), flush=True)
homes = {}
for f in sorted(glob.glob(os.path.join(homedir, "*.flac"))):
    raw, med, sc, y = logmel(f, np.load(f[:-5] + ".labels.npy").astype(np.int64))
    homes[os.path.basename(f)[:-5]] = (raw, med, sc, torch.tensor(y), y)
print(len(lab_data), "Laborpersonen, eigene Naechte:", {k: len(v[4]) for k, v in homes.items()}, flush=True)
scs = np.array([v[2] for v in lab_data])
print("Skalen Labor min/median/max: %.2f / %.2f / %.2f" % (scs.min(), np.median(scs), scs.max()),
      "| eigene:", {k: round(v[2], 2) for k, v in homes.items()}, flush=True)

class Net(nn.Module):
    def __init__(s, h=96):
        super().__init__()
        s.cnn = nn.Sequential(
            nn.Conv2d(1, 16, 5, padding=2), nn.BatchNorm2d(16), nn.ReLU(), nn.MaxPool2d((2, 2)),
            nn.Conv2d(16, 32, 5, padding=2), nn.BatchNorm2d(32), nn.ReLU(), nn.MaxPool2d((2, 3)),
            nn.Conv2d(32, 64, (3, 5), padding=(1, 2)), nn.BatchNorm2d(64), nn.ReLU(), nn.MaxPool2d((2, 5)),
            nn.Conv2d(64, h, 3, padding=1), nn.BatchNorm2d(h), nn.ReLU(), nn.AdaptiveAvgPool2d(1))
        s.drop = nn.Dropout(0.3)
        s.gru = nn.GRU(h, h, num_layers=2, batch_first=True, bidirectional=True, dropout=0.2)
        s.out = nn.Linear(2 * h, 4)
    def forward(s, x):
        B, T = x.shape[:2]
        e = s.cnn(x.reshape(B * T, 1, 64, 300)).reshape(B, T, -1)
        y, _ = s.gru(s.drop(e)); return s.out(y)

def lab_look(x):   # Labor weniger nach Labor klingen lassen (normiert)
    B = x.shape[0]
    tilt = (torch.rand(B, 1, 1, 1, device=dev) - 0.5) * torch.linspace(-1, 1, 64, device=dev).view(1, 1, 64, 1)
    floor = torch.rand(B, 1, 1, 1, device=dev) * 1.5 - 0.5
    x = torch.logaddexp(x + tilt, floor + 0.3 * torch.randn_like(x[:, :, :, :1]))
    return x + 0.05 * torch.randn_like(x)

def train(own, iters=ITERS, crop=120):
    """own: Liste von Nacht-Schlüsseln aus homes, W_NIGHT-fach gewichtet"""
    net = Net().to(dev); opt = torch.optim.AdamW(net.parameters(), lr=1.5e-3, weight_decay=1e-2)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=1.5e-3, total_steps=iters)
    w = torch.tensor([1.5, 1.6, 0.6, 1.6], device=dev)
    lossf = nn.CrossEntropyLoss(weight=w, ignore_index=-1)
    p_night = W_NIGHT * len(own) / (W_NIGHT * len(own) + len(lab_data))
    for it in range(iters):
        net.train(); xb, yb, src = [], [], []
        for _ in range(4):
            if own and np.random.rand() < p_night:
                raw, med, sc, Y, _ = homes[own[np.random.randint(len(own))]]; is_lab = False
            else:
                raw, med, sc, Y = lab_data[np.random.randint(len(lab_data))]; is_lab = True
            L = min(crop, len(Y)); s = np.random.randint(0, len(Y) - L + 1)
            r = raw[s:s + L].to(dev)
            if np.random.rand() < P_SOUND: r = add_sound(r, med)
            xb.append(norm(r, med, sc)); yb.append(Y[s:s + L].to(dev)); src.append(is_lab)
        L = min(len(v) for v in yb)
        xb = torch.stack([v[:L] for v in xb]); yb = torch.stack([v[:L] for v in yb])
        m = torch.tensor(src, device=dev, dtype=torch.bool)
        if m.any(): xb[m] = lab_look(xb[m])
        loss = lossf(net(xb).reshape(-1, 4), yb.reshape(-1))
        opt.zero_grad(); loss.backward(); nn.utils.clip_grad_norm_(net.parameters(), 1.0); opt.step(); sched.step()
        if it % 250 == 0 or it == iters - 1:
            mem = torch.cuda.max_memory_allocated() / 2**30 if dev == "cuda" else 0
            print(f"  Schritt {it}/{iters}  Verlust {loss.item():.3f}  GPU max {mem:.1f} GB  %.0f s" % (time.time() - t0), flush=True)
    return net

@torch.no_grad()
def predict(net, X):
    net.eval()
    e = torch.cat([net.cnn(X[i:i + 200].to(dev).float().reshape(-1, 1, 64, 300)).reshape(-1, net.gru.input_size)
                   for i in range(0, len(X), 200)])
    y, _ = net.gru(e[None]); return net.out(y)[0].softmax(-1).cpu().numpy()

def kappa(C):
    N = C.sum(); po = np.trace(C) / N; pe = (C.sum(0) * C.sum(1)).sum() / N / N
    return (po - pe) / (1 - pe)

def score(p, y):
    ok = y >= 0; C = np.zeros((4, 4)); np.add.at(C, (y[ok], p[ok]), 1)
    return dict(kappa=round(float(kappa(C)), 3), acc=round(float(np.trace(C) / C.sum()), 3),
                minutes={k: int((p == i).sum() / 2) for i, k in enumerate(NAMES)},
                watch_minutes={k: int((y == i).sum() / 2) for i, k in enumerate(NAMES)}, pred="".join(map(str, p)))

res = {}
def save(): json.dump(res, open(os.path.join(out, "e2e_v2.json"), "w"), indent=1)
def evaluate(tag, net, k):
    raw, med, sc, _, y = homes[k]
    res[f"{tag}_{k}"] = r = score(predict(net, norm(raw.to(dev), med, sc)).argmax(1), y)
    print(tag, k, {a: b for a, b in r.items() if a != "pred"}, "%.0f s" % (time.time() - t0), flush=True)
    # Belastungstest: 60 min Regen ab Beginn künstlich dazu
    rng = np.random.RandomState(1)
    rs = add_sound(raw.to(dev), med, rng)
    res[f"{tag}_{k}_mitklang"] = r = score(predict(net, norm(rs, med, sc)).argmax(1), y)
    print(tag, k, "MIT KUENSTLICHEM KLANG", {a: b for a, b in r.items() if a != "pred"}, flush=True)
    save()

test = [k for k in os.environ.get("TEST", "").split(",") if k in homes]
if test:
    net = train([k for k in homes if k not in test])
    for k in test: evaluate("ungesehen", net, k)
if os.environ.get("FINAL") == "1":
    net = train(list(homes))
    torch.save(net.state_dict(), os.path.join(out, "model_e2e_v2.pt"))
    for k in homes: evaluate("gelernt", net, k)
