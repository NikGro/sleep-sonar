"""Suya-Modell v3 - Vorverarbeitung und Training wie bei den Asleep-Forschern:

- SoundSleepNet (Hong et al. 2022): je 30-s-Fenster das gleichmäßige Grundrauschen abziehen
  ("adaptive spectral gating"), keine Normierung über die ganze Nacht. Jede Epoche steht für sich -
  eine laute Stunde kann den Rest der Nacht nicht mehr verderben, und es ginge auch live in der Nacht.
  Abwandlung im Training: Tonhöhe verschieben (hier: Mel-Bänder um ±2 verschieben).
- HomeSleepNet (Tran et al. 2023): Geräusche einmischen (hier: die 16 Schlafklänge der App, dazu Pegel,
  Klangfarbe und Hall verändert) und Konsistenz-Training: dieselbe Stelle sauber und verändert soll
  dieselben Phasen ergeben.

Gating (gleich in der App umzusetzen, LogMel): je Epoche und Band Grundrauschen = 20-%-Quantil der 300
Bilder (unterer Wert, sortiert), y = max(0, x - Grund - GATE_DB*ln(10)/10) / 4.

Aufruf: python train_e2e_v3.py <psg-dir> <home-dir> <out-dir> <sounds.npz>
  TEST="nacht7,..."  diese Nächte nur prüfen (je mit und ohne künstlichen Klang);  FINAL=1  Endmodell
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
ITERS = int(os.environ.get("ITERS", "3500"))
GATE_DB = float(os.environ.get("GATE_DB", "3"))
W_CONS = float(os.environ.get("W_CONS", "6.0"))   # JSD-Gewicht (AugMix nutzt 12 je Stück)
EVAL_EVERY = int(os.environ.get("EVAL_EVERY", "1000"))
# NORM=gate: je Epoche Grundrauschen abziehen (Forscher). NORM=night: alte Normierung über die ganze Nacht wie
# in der App (Median je Band, dann Streuung), Zeiten mit laufenden Schlafklängen durch den Median der übrigen Nacht ersetzt.
NORM = os.environ.get("NORM", "gate")
# bekannte Schlafklang-Zeiten echter Nächte (Sekunden ab Aufnahmebeginn), z. B. "nacht7:0-3670"
MASK_SEC = {k: tuple(map(float, v.split("-"))) for k, v in (x.split(":") for x in os.environ.get("MASK_SEC", "").split(",") if x)}   # Lernkurve: so oft auf den Testnächten messen
NAMES = ["Wach", "REM", "Kern", "Tief"]; t0 = time.time()
mel = torchaudio.transforms.MelSpectrogram(16000, n_fft=1024, hop_length=1600, n_mels=64, f_min=50, f_max=7800).to(dev)

def logmel(path, lab):
    """-> roh (n, 64, 300) half (natürlicher Log der Mel-Leistung, wie in der App)"""
    x, sr = sf.read(path, dtype="float32")
    n = min(len(x) // (sr * 30), len(lab)); x = x[:n * 30 * sr]
    M = []
    for s in range(0, len(x), sr * 600):
        seg = torch.tensor(x[s:s + sr * 600], device=dev)
        M.append(torch.log(mel(seg) + 1e-10)[:, : len(seg) // 1600])
    M = torch.cat(M, 1)[:, : n * 300]
    return M.T.reshape(n, 300, 64).permute(0, 2, 1).contiguous().half().cpu(), lab[:n]

def gate(raw):
    """raw: (..., 64, 300) -> je Epoche Grundrauschen abziehen (siehe oben)"""
    x = raw.float()
    floor = x.sort(-1).values[..., 59:60]          # 20-%-Quantil der 300 Bilder (Index 59)
    return (x - floor - GATE_DB * np.log(10) / 10).clamp(min=0) / 4

def night_norm(x, keep=None):
    """x: (n, 64, 300) roh auf dev, keep: bool (n*300,) oder None. Genau wie LogMel.normalize(masked:) in der App."""
    n = x.shape[0]; F = x.float().permute(1, 0, 2).reshape(64, n * 300).clone()
    if keep is not None and keep.sum() > F.shape[1] // 4 and not bool(keep.all()):
        F[:, ~keep] = F[:, keep].median(1, keepdim=True).values
    F = F - F.median(1, keepdim=True).values
    F = F / (F.std() + 1e-6)
    return F.reshape(64, n, 300).permute(1, 0, 2).contiguous()

def frames_keep(T, spans, device):
    """spans: Liste (a, b) in Bildern (10/s); 2 s davor und 35 s danach mit ausblenden wie in der App"""
    keep = torch.ones(T, dtype=torch.bool, device=device)
    for a, b in spans: keep[max(0, int(a) - 20):min(T, int(b) + 350)] = False
    return keep

def base_keep(k, n):
    return frames_keep(n * 300, [(MASK_SEC[k][0] * 10, MASK_SEC[k][1] * 10)], dev) if k in MASK_SEC else None

# Schlafklänge (roh, (64, T)), auf Median 0 je Band gebracht
bank = [torch.tensor(v.astype(np.float32)) for v in np.load(soundfile).values()]
bank = [b - b.median(1, keepdim=True).values for b in bank if b.shape[1] >= 20]

# Alltagsgeräusche (FSD50K, CC0/CC BY) - kurze Ereignisse, optional (EVERYDAY=Pfad zur npz)
events = []
if os.environ.get("EVERYDAY") and os.path.exists(os.environ["EVERYDAY"]):
    events = [torch.tensor(v.astype(np.float32)) for v in np.load(os.environ["EVERYDAY"]).values()]
    events = [e - e.median(1, keepdim=True).values for e in events]
print("Alltagsgeräusche:", len(events), flush=True)

def lmean(x):
    """log der mittleren Leistung (x: natürlicher Log der Leistung)"""
    return torch.logsumexp(x.reshape(-1), 0) - np.log(x.numel())

def snr_shift(sig, noise, rng):
    """wie HomeSleepNet: Geräusch so skalieren, dass SNR gleichverteilt in -10 … +10 dB liegt
    (bezogen auf die mittlere Leistung der Strecke bzw. des Abschnitts)"""
    return lmean(sig) - lmean(noise) - rng.uniform(-10, 10) * np.log(10) / 10

def add_events(x, rng=np.random):
    """x: (L, 64, 300) roh. Streut 1-10 Alltagsgeräusche an zufällige Stellen, jedes mit SNR -10 … +10 dB."""
    L = x.shape[0]; T = L * 300
    y = x.permute(1, 0, 2).reshape(64, T)
    for _ in range(rng.randint(1, 11) * max(1, L // 80)):
        e = events[rng.randint(len(events))].to(x.device)
        n = min(e.shape[1], T); a = rng.randint(0, T - n + 1)
        seg = y[:, a:a + n]; e = e[:, :n]
        y[:, a:a + n] = torch.logaddexp(seg, e + snr_shift(seg, e, rng))
    return y.reshape(64, L, 300).permute(1, 0, 2)

def add_sound(raw, rng=np.random, src=None, spans=None):
    """raw: (L, 64, 300) roh auf dev. Legt einen Klang in Schleife über einen zufälligen Abschnitt
    (mit Ausblenden), SNR -10 … +10 dB zur Strecke. src: Klangliste (Standard Schlafklänge)."""
    src = src or bank
    L = raw.shape[0]; T = L * 300
    snd = src[rng.randint(len(src))].to(raw.device)
    tilt = (rng.rand() - 0.5) * torch.linspace(-1, 1, 64, device=raw.device).view(64, 1)   # Lautsprecher/Raum
    reps = T // snd.shape[1] + 2; off = rng.randint(snd.shape[1])
    s = snd.repeat(1, reps)[:, off:off + T] + tilt
    x = raw.float().permute(1, 0, 2).reshape(64, T)
    s = s + snr_shift(x, s, rng)
    # Abschnitt: oft ab Beginn (Einschlafen), sonst irgendwo; mind. 10 min oder die ganze Strecke
    a = 0 if rng.rand() < 0.6 else rng.randint(T)
    b = min(T, a + rng.randint(min(T, 6000), T + 1))
    env = torch.full((T,), -30.0, device=raw.device)
    env[a:b] = 0
    fade = min(300, b - a)
    if b < T and fade > 0:   # 30 s Ausblenden
        env[b - fade:b] = torch.linspace(0, -12, fade, device=raw.device)
    x = torch.logaddexp(x, s + env.view(1, T))
    if spans is not None: spans.append((a, b))    # bekannter Schlafklang-Abschnitt (für die Maske wie in der App)
    return x.reshape(64, L, 300).permute(1, 0, 2)

def vary(raw, rng=np.random, spans=None):
    """Abwandlung einer Strecke roh (L, 64, 300) auf dev: Pegel, Klangfarbe, Tonhöhe, Hall, Geräusch."""
    x = raw.float()
    L = x.shape[0]
    x = x + rng.uniform(-3, 3)                                                    # Pegel (± ~13 dB)
    x = x + (rng.rand() - 0.5) * 2 * torch.linspace(-1, 1, 64, device=x.device).view(1, 64, 1)   # Klangfarbe
    k = rng.randint(-2, 3)                                                        # Tonhöhe ≈ Bänder verschieben
    if k: x = torch.roll(x, k, dims=1)
    if rng.rand() < 0.5:                                                          # Hall: Leistung klingt nach
        a = float(np.exp(-0.1 / rng.uniform(0.15, 0.8)))                          # Nachhall 0,15 … 0,8 s
        p = x.exp().permute(1, 0, 2).reshape(64, L * 300)
        h = p.clone()
        for d in range(1, 9):                                                     # Näherung mit 8 Verzögerungen
            h[:, d:] += (a ** d) * p[:, :-d]
        x = torch.log(h + 1e-10).reshape(64, L, 300).permute(1, 0, 2)
    # Geräusch wie HomeSleepNet: jede Abwandlung bekommt ein eigenes
    r = rng.rand()
    if not events:
        if r < 0.6: x = add_sound(x, rng, spans=spans)
    elif r < 0.25: x = add_sound(x, rng, spans=spans)                             # Schlafklang
    elif r < 0.55: x = add_sound(x, rng, events)                                  # Dauergeräusch (Lüfter, Regen …)
    elif r < 0.85: x = add_events(x.clone(), rng)                                 # einzelne Geräusche
    elif r < 0.95: x = add_events(add_sound(x, rng, events), rng)                 # beides
    return x

lab_data = []
files = sorted(glob.glob(os.path.join(psgdir, "*.flac")))
for i, f in enumerate(files):
    y = np.load(f[:-5] + ".labels.npy").astype(np.int64)
    if (y >= 0).sum() < int(os.environ.get("LAB_MIN", "240")) or (y > 0).sum() < 60 // (1 + 9 * ("LAB_MIN" in os.environ)): continue
    raw, y = logmel(f, y)
    lab_data.append((raw, torch.tensor(y)))
    if i % 50 == 0: print(f"Labor {i}/{len(files)}  %.0f s" % (time.time() - t0), flush=True)
homes = {}
for f in sorted(glob.glob(os.path.join(homedir, "*.flac"))):
    raw, y = logmel(f, np.load(f[:-5] + ".labels.npy").astype(np.int64))
    homes[os.path.basename(f)[:-5]] = (raw, torch.tensor(y), y)
print(len(lab_data), "Laborpersonen, eigene Naechte:", {k: len(v[2]) for k, v in homes.items()}, flush=True)
g = gate(lab_data[0][0][:50].to(dev))
print("Gating-Werte Labor 0: Mittel %.3f, Anteil 0: %.2f, max %.2f" % (g.mean(), (g == 0).float().mean(), g.max()), flush=True)

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

def prepare(raw, k, mode, seed=1):
    """ganze Nacht fürs Modell: mode '' (sauber), 'klang' (Schlafklang), 'alltag' (Dauergeräusch)"""
    r = raw.to(dev).float(); n = len(raw); spans = []
    if mode == "klang": r = add_sound(r, np.random.RandomState(seed), spans=spans)
    if mode == "alltag": r = add_sound(r, np.random.RandomState(seed), events)
    if NORM == "night":
        keep = base_keep(k, n)
        if spans:   # Schlafklang-Zeit ist in der App bekannt und wird ausgeblendet
            sk = frames_keep(n * 300, spans, dev); keep = sk if keep is None else keep & sk
        return night_norm(r, keep)
    return torch.cat([gate(r[i:i + 200]) for i in range(0, n, 200)])

def quick_kappa(net, k, sound):
    raw, _, y = homes[k]
    X = prepare(raw, k, "klang" if sound else "")
    p = predict(net, X).argmax(1); ok = y >= 0
    C = np.zeros((4, 4)); np.add.at(C, (y[ok], p[ok]), 1)
    return float(kappa(C))

curve = []
CROP = int(os.environ.get("CROP", "80"))   # 4 Strecken x 3 Fassungen x 80 Epochen = gleicher Speicher wie vorher 8 x 120
def train(own, iters=ITERS, crop=CROP, watch=()):
    """own: Liste von Nacht-Schlüsseln aus homes, W_NIGHT-fach gewichtet.
    watch: Testnächte für die Lernkurve - zurück kommt dann der Stand mit dem besten Mittelwert."""
    best, best_state = -9.0, None
    net = Net().to(dev); opt = torch.optim.AdamW(net.parameters(), lr=1.5e-3, weight_decay=1e-2)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=1.5e-3, total_steps=iters)
    w = torch.tensor([1.5, 1.6, 0.6, 1.6], device=dev)
    lossf = nn.CrossEntropyLoss(weight=w, ignore_index=-1)
    p_night = W_NIGHT * len(own) / (W_NIGHT * len(own) + len(lab_data))
    for it in range(iters):
        net.train(); clean, aug1, aug2, yb = [], [], [], []
        for _ in range(4):
            key = None
            if own and np.random.rand() < p_night:
                key = own[np.random.randint(len(own))]; raw, Y, _ = homes[key]
            else:
                raw, Y = lab_data[np.random.randint(len(lab_data))]
            L = min(crop, len(Y)); s = np.random.randint(0, len(Y) - L + 1)
            if NORM == "night":
                # ganze Nacht abwandeln und normieren (wie in der App), dann denselben Ausschnitt nehmen
                r = raw.to(dev).float(); n = len(raw); kb = base_keep(key, n) if key else None
                def nn_(x, sp):
                    keep = kb
                    if sp:
                        sk = frames_keep(n * 300, sp, dev); keep = sk if keep is None else keep & sk
                    return night_norm(x, keep)[s:s + L]
                sp1, sp2 = [], []
                clean.append(nn_(r, [])); aug1.append(nn_(vary(r, spans=sp1), sp1)); aug2.append(nn_(vary(r, spans=sp2), sp2))
                del r
            else:
                r = raw[s:s + L].to(dev)
                clean.append(gate(r)); aug1.append(gate(vary(r))); aug2.append(gate(vary(r)))
            yb.append(Y[s:s + L].to(dev))
        if NORM == "night" and dev == "cuda": torch.cuda.empty_cache()   # große Ganz-Nacht-Puffer freigeben (sonst Fragmentierung)
        L = min(len(v) for v in yb)
        st = lambda vs: torch.stack([v[:L] for v in vs])
        yb = st(yb)
        out = net(torch.cat([st(clean), st(aug1), st(aug2)]))   # alle drei in einem Durchgang (BatchNorm sieht alles)
        oc, o1, o2 = out[:4], out[4:8], out[8:]
        ce = lambda o: lossf(o.reshape(-1, 4), yb.reshape(-1))
        loss = ce(oc) + 0.5 * (ce(o1) + ce(o2))
        # Konsistenz wie AugMix/HomeSleepNet: Jensen-Shannon über sauber + zwei Abwandlungen (je Epoche gemittelt)
        P = [o.reshape(-1, 4).softmax(-1) for o in (oc, o1, o2)]
        logM = torch.clamp((P[0] + P[1] + P[2]) / 3, 1e-7, 1).log()
        cons = sum(nn.functional.kl_div(logM, p, reduction="batchmean") for p in P) / 3
        loss = loss + W_CONS * cons
        opt.zero_grad(); loss.backward(); nn.utils.clip_grad_norm_(net.parameters(), 1.0); opt.step(); sched.step()
        if it % 250 == 0 or it == iters - 1:
            mem = torch.cuda.max_memory_allocated() / 2**30 if dev == "cuda" else 0
            print(f"  Schritt {it}/{iters}  Verlust {loss.item():.3f}  Konsistenz {cons.item():.3f}  GPU max {mem:.1f} GB  %.0f s" % (time.time() - t0), flush=True)
        if watch and ((it + 1) % EVAL_EVERY == 0 or it == iters - 1):
            ks = {f"{k}{'+klang' if snd else ''}": round(quick_kappa(net, k, snd), 3) for k in watch for snd in (False, True)}
            m = float(np.mean(list(ks.values())))
            curve.append(dict(step=it + 1, mean=round(m, 3), **ks))
            print(f"  LERNKURVE Schritt {it + 1}: Mittel {m:.3f}  {ks}", flush=True)
            if m > best:
                best = m; best_state = {k: v.detach().clone().cpu() for k, v in net.state_dict().items()}
                res["bester_schritt"] = it + 1
            res["lernkurve"] = curve; save()
    if best_state is not None: net.load_state_dict(best_state)
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
TAG = os.environ.get("RUN_TAG", "")   # Namenszusatz der Ergebnisdateien, damit Läufe sich nicht überschreiben
def save(): json.dump(res, open(os.path.join(out, f"e2e_v3{TAG}.json"), "w"), indent=1)
def evaluate(tag, net, k):
    raw, _, y = homes[k]
    for mode, name in (("", ""), ("klang", "_mitklang"), ("alltag", "_mitalltag")):
        if mode == "alltag" and not events: continue
        res[f"{tag}_{k}{name}"] = r = score(predict(net, prepare(raw, k, mode)).argmax(1), y)
        print(tag, k, mode.upper() or "SAUBER", {a: b for a, b in r.items() if a != "pred"}, "%.0f s" % (time.time() - t0), flush=True)
    save()

test = [k for k in os.environ.get("TEST", "").split(",") if k in homes]
if test:
    net = train([k for k in homes if k not in test], watch=test)
    print("BESTER STAND bei Schritt", res.get("bester_schritt"), flush=True)
    for k in test: evaluate("ungesehen_bester_stand", net, k)
if os.environ.get("FINAL") == "1":
    # Endmodell so lange lernen, wie es in der Lernkurve am besten war (auf 500 aufgerundet)
    steps = int(-(-res.get("bester_schritt", ITERS) // 500) * 500) if test else ITERS
    print("ENDMODELL mit", steps, "Schritten", flush=True)
    net = train(list(homes), iters=steps)
    torch.save(net.state_dict(), os.path.join(out, f"model_e2e_v3{TAG}.pt"))
    for k in homes: evaluate("gelernt", net, k)
