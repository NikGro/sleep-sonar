"""Abgleich: Log-Mel aus der App (Spende) gegen Log-Mel aus dem Training (FLAC) fuer dieselbe Nacht."""
import json, struct, sys, zlib
import numpy as np, soundfile as sf, torch, torch.nn as nn, torchaudio
dev = "cuda" if torch.cuda.is_available() else "cpu"
flac, labels, suya, model = sys.argv[1:5]
mel = torchaudio.transforms.MelSpectrogram(16000, n_fft=1024, hop_length=1600, n_mels=64, f_min=50, f_max=7800).to(dev)
x, sr = sf.read(flac, dtype="float32"); lab = np.load(labels).astype(np.int64)
n = min(len(x) // (sr * 30), len(lab)); x = x[:n * 30 * sr]
A = []
for s in range(0, len(x), sr * 600):
    seg = torch.tensor(x[s:s + sr * 600], device=dev); A.append(torch.log(mel(seg) + 1e-10)[:, : len(seg) // 1600])
A = torch.cat(A, 1)[:, : n * 300].cpu().numpy()            # (64, Bilder) Training
raw = zlib.decompress(open(suya, "rb").read(), -15); k = struct.unpack("<I", raw[5:9])[0]; head = json.loads(raw[9:9 + k])
fr = head["frames"]; B = np.frombuffer(raw[9 + k: 9 + k + fr * 128], dtype="<f2").astype(np.float32).reshape(fr, 64).T
print("Bilder Training", A.shape[1], "App", B.shape[1], "Epochen", n, len(head["watch"]))
m = min(A.shape[1], B.shape[1])
# Versatz suchen (bis +-600 Bilder) ueber die Lautstaerke je Bild
ea, eb = A.mean(0), B.mean(0)
L = m - 1300
def corr(o): return np.corrcoef(ea[600 + o: 600 + o + L], eb[600: 600 + L])[0, 1]
best = max(range(-600, 601), key=corr); print("Korrelation beim besten Versatz:", round(float(corr(best)), 3), "bei 0:", round(float(corr(0)), 3))
print("bester Versatz (Bilder, App gegen Training):", best)
a = A[:, 600 + best: 600 + best + L]; b = B[:, 600: 600 + L]
print("Mittel je Band Training:", np.round(a.mean(1)[::8], 2))
print("Mittel je Band App     :", np.round(b.mean(1)[::8], 2))
print("Streuung je Band Training:", np.round(a.std(1)[::8], 2))
print("Streuung je Band App     :", np.round(b.std(1)[::8], 2))
print("Korrelation je Band:", np.round([np.corrcoef(a[i], b[i])[0, 1] for i in range(0, 64, 8)], 3))
print("mittlere Abweichung:", float(np.abs(a - b).mean()))
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


def norm(M):
    M = torch.tensor(M); M = M - M.median(1, keepdim=True).values; M = M / (M.std() + 1e-6)
    e = M.shape[1] // 300; return M[:, : e * 300].T.reshape(e, 300, 64).permute(0, 2, 1).contiguous()
net = Net().to(dev); net.load_state_dict(torch.load(model, map_location=dev)); net.eval()
@torch.no_grad()
def pred(X):
    e = torch.cat([net.cnn(X[i:i + 200].to(dev).reshape(-1, 1, 64, 300)).reshape(-1, net.gru.input_size) for i in range(0, len(X), 200)])
    y, _ = net.gru(e[None]); return net.out(y)[0].argmax(-1).cpu().numpy()
def kappa(p, y):
    ok = y >= 0; C = np.zeros((4, 4)); np.add.at(C, (y[ok], p[ok]), 1); N = C.sum(); po = np.trace(C) / N; pe = (C.sum(0) * C.sum(1)).sum() / N / N
    return round(float((po - pe) / (1 - pe)), 3), {k: int((p == i).sum() / 2) for i, k in enumerate(["Wach", "REM", "Kern", "Tief"])}
pa = pred(norm(A)); pb = pred(norm(B)); yw = np.array(head["watch"])
print("Modell auf Training-Mel (Labels Datei):", kappa(pa, lab[: len(pa)]))
print("Modell auf App-Mel (Watch aus Spende):", kappa(pb, yw[: len(pb)]))
print("Uebereinstimmung der beiden Vorhersagen:", float((pa[: min(len(pa), len(pb))] == pb[: min(len(pa), len(pb))]).mean()))
