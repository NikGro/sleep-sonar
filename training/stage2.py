#!/usr/bin/env python3
"""Stufe 2: gelernter Klassifikator auf Epochen-Merkmalen (Gradient Boosting).

  1. Labor (PSG-Audio): 5-fache Kreuzvalidierung über Personen → ehrliche Zahlen für Fremde
  2. Modell auf allen Laborpersonen trainieren
  3. Test an eigenen Nächten mit Apple-Watch-Phasen (Ordner NIGHTS, je Nacht levels.csv + watch_sleep.csv
     oder eine ZIP aus der App) – diese Nächte sieht das Training nie.

Nachbearbeitung wie bei der Watch: Wahrscheinlichkeiten über ±k Epochen mitteln, dann zu kurze
Tief/REM-Blöcke zu Kern. Gütekriterien: Kappa, falsches Wach, längster Fehlabschnitt.
"""
import csv
import datetime as dt
import glob
import io
import json
import os
import sys
import time
import zipfile

import numpy as np
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.utils.class_weight import compute_sample_weight

sys.path.insert(0, os.path.dirname(__file__))
import features  # noqa: E402
import rules  # noqa: E402

FEAT = os.environ.get("FEAT", "/features")
NIGHTS = os.environ.get("NIGHTS", "/nights")
OUT = os.environ.get("OUT", "/results")
NAMES = ["Wach", "REM", "Kern", "Tief"]


def load_lab():
    X, Y, G, ids = [], [], [], []
    for i, f in enumerate(sorted(glob.glob(os.path.join(FEAT, "*.npz")))):
        d = np.load(f)
        F, cn = features.epoch_features(d["rms"], d["peak"], d["low"], d["mid"], d["high"])
        lab = d["stage"].astype(int)
        n = min(len(F), len(lab))
        F, lab = F[:n], lab[:n]
        if (lab >= 0).sum() < 240 or (lab > 0).sum() < 60:
            continue
        X.append(F)
        Y.append(lab)
        G.append(np.full(n, len(ids)))
        ids.append(os.path.basename(f)[:-4])
    return X, Y, ids, cn


def _t(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


def load_night(path):
    """Eigene Nacht: Ordner oder ZIP mit levels.csv und watch_sleep.csv."""
    if path.endswith(".zip"):
        z = zipfile.ZipFile(path)

        def rd(name):
            m = [n for n in z.namelist() if n.endswith("/" + name) or n == name]
            return io.TextIOWrapper(z.open(m[0]), encoding="utf-8") if m else None
    else:
        def rd(name):
            p = os.path.join(path, name)
            return open(p, encoding="utf-8") if os.path.exists(p) else None
    lv = list(csv.DictReader(rd("levels.csv")))
    t0 = _t(lv[0]["time"])
    cols = {k: np.array([float(r[c]) for r in lv]) for k, c in
            (("rms", "rms_db"), ("peak", "peak_db"), ("low", "low_250hz_db"), ("mid", "mid_1200hz_db"),
             ("high", "high_4500hz_db"))}
    ws = rd("watch_sleep.csv")
    E = len(lv) // 30
    lab = np.full(E, -1)
    if ws:
        code = {"Wach": 0, "REM": 1, "Kern": 2, "Tief": 3}
        segs = []
        for r in csv.DictReader(ws):
            st = r["stage"]
            st = {"awake": "Wach", "asleepREM": "REM", "asleepCore": "Kern", "asleepDeep": "Tief"}.get(st, st)
            if st in code:
                segs.append((_t(r["start"]), _t(r["end"]), code[st]))
        for e in range(E):
            m = t0 + dt.timedelta(seconds=e * 30 + 15)
            for a, b, c in segs:
                if a <= m < b:
                    lab[e] = c
        idx = np.flatnonzero(lab >= 0)
        if len(idx):
            lab[idx[0]:idx[-1] + 1][lab[idx[0]:idx[-1] + 1] < 0] = 0  # Lücken zwischen Watch-Phasen = wach
    return cols, lab


def postprocess(P, k, min_block):
    if k > 0:
        c = np.vstack([np.zeros(P.shape[1]), np.cumsum(P, 0)])
        i = np.arange(len(P))
        lo, hi = np.maximum(0, i - k), np.minimum(len(P), i + k + 1)
        P = (c[hi] - c[lo]) / (hi - lo)[:, None]
    out = P.argmax(1)
    i = 0
    while i < len(out):
        j = i
        while j < len(out) and out[j] == out[i]:
            j += 1
        if out[i] in (1, 3) and j - i < min_block:
            out[i:j] = 2
        i = j
    return out


def model():
    return HistGradientBoostingClassifier(max_iter=250, learning_rate=0.05, max_leaf_nodes=15,
                                          min_samples_leaf=60, l2_regularization=1.0, random_state=0)


def fit(Xs, Ys):
    X = np.concatenate(Xs)
    y = np.concatenate(Ys)
    m = y >= 0
    w = compute_sample_weight("balanced", y[m])
    # Personen gleich gewichten (lange Aufnahmen sollen nicht dominieren)
    sizes = np.concatenate([np.full(len(v), 1.0 / max(1, (v >= 0).sum())) for v in Ys])[m]
    w = w * sizes / sizes.mean()
    return model().fit(X[m], y[m], sample_weight=w)


def evaluate(pred, lab):
    M = rules.confusion(pred, lab)
    fw, lw = rules.error_runs(pred, lab)
    return M, fw, lw


def summarize(Ms, fws, lws):
    tot = sum(Ms)
    k = [rules.kappa(M) for M in Ms]
    return dict(kappa_mean=float(np.nanmean(k)), kappa_median=float(np.nanmedian(k)),
                kappa_pooled=float(rules.kappa(tot)), acc=float(np.trace(tot) / tot.sum()),
                false_wake_min_mean=float(np.mean(fws)), longest_wrong_min_mean=float(np.mean(lws)),
                recall={n: float(tot[i, i] / max(1, tot[i].sum())) for i, n in enumerate(NAMES)},
                confusion=tot.tolist())


def main():
    os.makedirs(OUT, exist_ok=True)
    t = time.time()
    X, Y, ids, cn = load_lab()
    print(f"{len(ids)} Laborpersonen, {sum(len(x) for x in X)} Epochen, {len(cn)} Merkmale ({time.time() - t:.0f} s)",
          flush=True)
    rng = np.random.default_rng(1)
    folds = np.arange(len(ids)) % 5
    rng.shuffle(folds)
    probs = [None] * len(ids)
    for f in range(5):
        tr = [i for i in range(len(ids)) if folds[i] != f]
        m = fit([X[i] for i in tr], [Y[i] for i in tr])
        for i in range(len(ids)):
            if folds[i] == f:
                probs[i] = m.predict_proba(X[i])
        print(f"Fold {f + 1}/5 fertig ({time.time() - t:.0f} s)", flush=True)
    grid = {}
    for k in (0, 2, 4, 6, 8):
        for mb in (0, 4, 8):
            r = [evaluate(postprocess(probs[i], k, mb), Y[i]) for i in range(len(ids))]
            grid[(k, mb)] = summarize(*zip(*r))
    best = max(grid, key=lambda key: grid[key]["kappa_mean"] - grid[key]["longest_wrong_min_mean"] / 600
               - grid[key]["false_wake_min_mean"] / 300)
    print("Labor, Kreuzvalidierung (unbekannte Personen):", best, json.dumps(grid[best]), flush=True)

    final = fit(X, Y)
    nights = {}
    for p in sorted(glob.glob(os.path.join(NIGHTS, "*"))):
        try:
            cols, lab = load_night(p)
        except Exception as ex:
            print("Nacht übersprungen", p, ex)
            continue
        F, _ = features.epoch_features(cols["rms"], cols["peak"], cols["low"], cols["mid"], cols["high"])
        lab = lab[:len(F)]
        pred = postprocess(final.predict_proba(F), *best)
        M, fw, lw = evaluate(pred, lab)
        mins = {n: int((pred == i).sum() / 2) for i, n in enumerate(NAMES)}
        watch = {n: int((lab == i).sum() / 2) for i, n in enumerate(NAMES)}
        nights[os.path.basename(p)] = dict(kappa=float(rules.kappa(M)), acc=float(np.trace(M) / max(1, M.sum())),
                                          false_wake_min=fw, longest_wrong_min=lw, minutes=mins, watch=watch,
                                          confusion=M.tolist())
        print("Eigene Nacht", os.path.basename(p), json.dumps(nights[os.path.basename(p)]), flush=True)

    imp = None
    json.dump(dict(persons=len(ids), features=cn, postprocess=best,
                   grid={f"{k[0]},{k[1]}": v for k, v in grid.items()}, crossvalidated=grid[best],
                   nights=nights, importance=imp), open(os.path.join(OUT, "stage2.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
