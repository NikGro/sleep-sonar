"""Einfaches Training wie beim App-Modell: Aufnahmen plus Watch-Wahrheit, Normierung ueber die ganze Nacht,
keine Rauschentfernung, keine Geraeusch-Stufe. Zeiten mit laufenden App-Klaengen (MASK_SEC) zaehlen weder
beim Lernen noch bei der Messung. Feste Schrittzahl, nichts wird an den Testnaechten ausgesucht.

Urspruenglich: Labor + eigene Nacht, ohne vorgeschaltetes Ohr (Aufbau wie SoundSleepNet: Spektrogramm ->
Merkmale je 30-s-Epoche -> Zusammenhang zwischen Epochen).

Labor-Spektrogramme werden beim Training zufaellig veraendert (Klangfarbe, Grundrauschen), damit sie
weniger nach Labor klingen. Test: deine Nacht in 4 Zeitbloecken, jeweils 3 Bloecke (gewichtet) im
Training, der 4. ungesehen. Zusaetzlich: wie gut auf 20 % ungesehenen Laborpersonen.
"""
import glob, json, os, sys, time
import numpy as np, soundfile as sf, torch, torch.nn as nn, torchaudio

dev = "cuda"
def seed(n): torch.manual_seed(n); np.random.seed(n)
seed(0)
psgdir, homedir, out = sys.argv[1:4]
W_NIGHT = int(os.environ.get("W_NIGHT", "20"))
NAMES = ["Wach", "REM", "Kern", "Tief"]; t0 = time.time()
mel = torchaudio.transforms.MelSpectrogram(16000, n_fft=1024, hop_length=1600, n_mels=64, f_min=50, f_max=7800).to(dev)

def logmel(path, lab):
    x, sr = sf.read(path, dtype="float32")
    n = min(len(x) // (sr * 30), len(lab)); x = x[:n * 30 * sr]
    M = []
    for s in range(0, len(x), sr * 600):
        seg = torch.tensor(x[s:s + sr * 600], device=dev)
        M.append(torch.log(mel(seg) + 1e-10)[:, : len(seg) // 1600])
    M = torch.cat(M, 1)[:, : n * 300]
    M = M - M.median(1, keepdim=True).values; M = M / (M.std() + 1e-6)
    return M.T.reshape(n, 300, 64).permute(0, 2, 1).contiguous(), lab[:n]

lab_data = []
files = sorted(glob.glob(os.path.join(psgdir, "*.flac")))
for i, f in enumerate(files):
    y = np.load(f[:-5] + ".labels.npy").astype(np.int64)
    if (y >= 0).sum() < 240 or (y > 0).sum() < 60: continue
    X, y = logmel(f, y)
    lab_data.append((X.half().cpu(), torch.tensor(y)))
    if i % 50 == 0: print(f"Labor {i}/{len(files)}  %.0f s" % (time.time() - t0), flush=True)
homes = {}
for f in sorted(glob.glob(os.path.join(homedir, "*.flac"))):
    X, y = logmel(f, np.load(f[:-5] + ".labels.npy").astype(np.int64))
    homes[os.path.basename(f)[:-5]] = (X, torch.tensor(y, device=dev), y)
# Zeiten mit App-Klaengen ausblenden: Epochen, die das Intervall beruehren, bekommen Label -1
MASK_SEC = {k: tuple(map(float, v.split("-"))) for k, v in (x.split(":") for x in os.environ.get("MASK_SEC", "").split(",") if x)}
for k, (a, b) in MASK_SEC.items():
    if k in homes:
        X, yt, y = homes[k]; y = y.copy(); y[int(a // 30): int(np.ceil(b / 30))] = -1
        homes[k] = (X, torch.tensor(y, device=dev), y)
        print("ausgeblendet", k, int(a), "-", int(b), "s", flush=True)
print(len(lab_data), "Laborpersonen, eigene Naechte:", {k: len(v[2]) for k, v in homes.items()}, flush=True)
lab_test = set()
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

def augment(x):   # x: (B, T, 64, 300) normiertes Log-Mel
    B = x.shape[0]
    tilt = (torch.rand(B, 1, 1, 1, device=dev) - 0.5) * torch.linspace(-1, 1, 64, device=dev).view(1, 1, 64, 1)
    floor = torch.rand(B, 1, 1, 1, device=dev) * 1.5 - 0.5          # Grundrauschen anheben
    x = torch.logaddexp(x + tilt, floor + 0.3 * torch.randn_like(x[:, :, :, :1]))
    return x + 0.05 * torch.randn_like(x)

def train(own, iters=2500, crop=120):
    """own: Liste (X, Y) eigener Naechte, W_NIGHT-fach gewichtet"""
    net = Net().to(dev); opt = torch.optim.AdamW(net.parameters(), lr=1.5e-3, weight_decay=1e-2)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=1.5e-3, total_steps=iters)
    w = torch.tensor([1.5, 1.6, 0.6, 1.6], device=dev)
    lossf = nn.CrossEntropyLoss(weight=w, ignore_index=-1)
    train_lab = [i for i in range(len(lab_data)) if i not in lab_test]
    p_night = W_NIGHT * len(own) / (W_NIGHT * len(own) + len(train_lab))
    for it in range(iters):
        net.train(); xb, yb, src = [], [], []
        for _ in range(4):
            if own and np.random.rand() < p_night:
                XO, YO = own[np.random.randint(len(own))]
                L = min(crop, len(YO)); s = np.random.randint(0, len(YO) - L + 1)
                xb.append(XO[s:s + L]); yb.append(YO[s:s + L]); src.append(0)
            else:
                X, y = lab_data[train_lab[np.random.randint(len(train_lab))]]
                L = min(crop, len(y)); s = np.random.randint(0, len(y) - L + 1)
                xb.append(X[s:s + L].to(dev).float()); yb.append(y[s:s + L].to(dev)); src.append(1)
        L = min(len(v) for v in yb)
        xb = torch.stack([v[:L] for v in xb]); yb = torch.stack([v[:L] for v in yb])
        m = torch.tensor(src, device=dev, dtype=torch.bool)
        if m.any(): xb[m] = augment(xb[m])
        loss = lossf(net(xb).reshape(-1, 4), yb.reshape(-1))
        opt.zero_grad(); loss.backward(); nn.utils.clip_grad_norm_(net.parameters(), 1.0); opt.step(); sched.step()
    return net

@torch.no_grad()
def predict(net, X):
    net.eval(); outs = []
    # in Stuecken, damit der Grafikspeicher reicht; GRU sieht trotzdem die ganze Nacht
    e = torch.cat([net.cnn(X[i:i + 200].to(dev).float().reshape(-1, 1, 64, 300)).reshape(-1, net.gru.input_size)
                   for i in range(0, len(X), 200)])
    y, _ = net.gru(e[None]); return net.out(y)[0].softmax(-1).cpu().numpy()

def kappa(C):
    N = C.sum(); po = np.trace(C) / N; pe = (C.sum(0) * C.sum(1)).sum() / N / N
    return (po - pe) / (1 - pe)

def conf(pred, y):
    ok = y >= 0; C = np.zeros((4, 4)); np.add.at(C, (y[ok], pred[ok]), 1); return C


def score(p, y):
    C = conf(p, y)
    return dict(kappa=round(float(kappa(C)), 3), acc=round(float(np.trace(C) / C.sum()), 3),
                minutes={k: int((p == i).sum() / 2) for i, k in enumerate(NAMES)},
                watch_minutes={k: int((y == i).sum() / 2) for i, k in enumerate(NAMES)}, pred="".join(map(str, p)))

def show(tag, r):
    print(tag, {k: v for k, v in r.items() if k != "pred"}, "%.0f s" % (time.time() - t0), flush=True)


ITERS = int(os.environ.get("ITERS", "2500"))
TEST = [k for k in os.environ.get("TEST", "nacht7,nacht8,joanna3").split(",") if k in homes]
SEEDS = [int(x) for x in os.environ.get("SEEDS", "0,1,2").split(",")]
TAG = os.environ.get("RUN_TAG", "_einfach")
res = {}
def save(): json.dump(res, open(os.path.join(out, "e2e%s.json" % TAG), "w"), indent=1)
def H(names): return [(homes[k][0], homes[k][1]) for k in names]
def test(tag, net, names):
    ks = {}
    for k in names:
        r = score(predict(net, homes[k][0]).argmax(1), homes[k][2]); res[tag + "_" + k] = r; show(tag + " " + k, r); ks[k] = r["kappa"]
    save(); return ks

# 1) altes App-Modell auf denselben Testnaechten (mit Ausblendung) als Massstab
old = os.path.join(out, "model_e2e_final.pt")
if os.path.exists(old):
    net = Net().to(dev); net.load_state_dict(torch.load(old, map_location=dev)); test("altes_app_modell", net, TEST)
# 2) einfaches Training ohne die Testnaechte, mehrere Zufallsstarts
train_names = [k for k in homes if k not in TEST]
print("Training mit", train_names, "Test:", TEST, "Schritte:", ITERS, flush=True)
allk = []
for sd in SEEDS:
    seed(sd); allk.append(test("ungesehen_seed%d" % sd, train(H(train_names), iters=ITERS), TEST))
print("MITTEL ungesehen:", {k: round(float(np.mean([a[k] for a in allk])), 3) for k in TEST},
      "min:", {k: min(a[k] for a in allk) for k in TEST}, flush=True)
# 3) Endmodell mit allen Naechten (Zufallsstart 0)
if os.environ.get("FINAL", "1") == "1":
    seed(0); net = train(H(list(homes)), iters=ITERS)
    torch.save(net.state_dict(), os.path.join(out, "model_e2e%s.pt" % TAG))
    test("gelernt", net, list(homes))
print("FERTIG %.0f s" % (time.time() - t0), flush=True)
