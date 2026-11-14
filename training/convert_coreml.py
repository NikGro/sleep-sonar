"""Wandelt das gelernte Schlafphasen-Modell (training/model/suya_e2e.pt) in zwei Core-ML-Modelle:

- SuyaEpochEncoder: je 30-s-Epoche ein normiertes Log-Mel-Bild (64 x 300) -> 96 Merkmale (CNN)
- SuyaNightSequence: alle Epochen der Nacht (T x 96) -> Wahrscheinlichkeiten Wach/REM/Kern/Tief (GRU)

Aufruf: python3 training/convert_coreml.py   (schreibt nach Suya/Model/)
"""
import os, sys
import numpy as np, torch, torch.nn as nn
import coremltools as ct

class Net(nn.Module):   # wie in training/train_e2e.py
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

class Encoder(nn.Module):
    def __init__(s, net): super().__init__(); s.cnn = net.cnn
    def forward(s, x): return s.cnn(x).flatten(1)          # (N,1,64,300) -> (N,96)

class Sequence(nn.Module):
    def __init__(s, net): super().__init__(); s.gru = net.gru; s.out = net.out
    def forward(s, e):
        y, _ = s.gru(e); return s.out(y).softmax(-1)        # (1,T,96) -> (1,T,4)

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
net = Net(); net.load_state_dict(torch.load(os.path.join(root, "training/model/suya_e2e.pt"), map_location="cpu")); net.eval()
enc, seq = Encoder(net).eval(), Sequence(net).eval()
outdir = os.path.join(root, "Suya/Model"); os.makedirs(outdir, exist_ok=True)

x = torch.randn(4, 1, 64, 300)
m1 = ct.convert(torch.jit.trace(enc, x),
                inputs=[ct.TensorType(name="mel", shape=(ct.RangeDim(1, 256, default=64), 1, 64, 300))],
                outputs=[ct.TensorType(name="embedding")], minimum_deployment_target=ct.target.iOS17,
                compute_precision=ct.precision.FLOAT32)
m1.short_description = "Suya: Merkmale je 30-s-Epoche aus Log-Mel (64 x 300)"
m1.save(os.path.join(outdir, "SuyaEpochEncoder.mlpackage"))

e = torch.randn(1, 50, 96)
m2 = ct.convert(torch.jit.trace(seq, e),
                inputs=[ct.TensorType(name="embeddings", shape=(1, ct.RangeDim(1, 2400, default=900), 96))],
                outputs=[ct.TensorType(name="probabilities")], minimum_deployment_target=ct.target.iOS17,
                compute_precision=ct.precision.FLOAT32)
m2.short_description = "Suya: Schlafphasen (Wach, REM, Kern, Tief) aus den Epochen-Merkmalen der Nacht"
m2.save(os.path.join(outdir, "SuyaNightSequence.mlpackage"))

# Referenz für die Prüfung auf dem Mac (CI): zufällige Eingaben und PyTorch-Ausgaben
rng = np.random.default_rng(1)
xr = rng.standard_normal((3, 1, 64, 300)).astype(np.float32)
er = rng.standard_normal((1, 40, 96)).astype(np.float32)
with torch.no_grad():
    np.savez(os.path.join(root, "training/model/reference.npz"), x=xr, enc=enc(torch.tensor(xr)).numpy(),
             e=er, seq=seq(torch.tensor(er)).numpy())
print("ok")
