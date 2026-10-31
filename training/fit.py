#!/usr/bin/env python3
"""Stufe 1: Parameter der Regel-Schätzung (v3) an PSG-Audio anpassen, ehrlich per Personen-Kreuzvalidierung.

Vorgehen:
  1. Für jede Person einmal vorrechnen (Grundpegel, Atemregelmäßigkeit, Ereignisse je eventDB).
  2. N zufällige Parametersätze (+ die heutigen Standardwerte) auf ALLEN Personen auswerten,
     je Person die 4x4-Verwechslungsmatrix speichern.
  3. 5-fache Kreuzvalidierung über Personen: auf 4/5 den besten Satz wählen (mittleres Kappa),
     auf dem unberührten 1/5 messen. Das ist die ehrliche Zahl für „neue Menschen“.
  4. Endgültiger Satz = bester auf allen Personen; Ergebnis nach results/.
"""
import glob
import json
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import rules  # noqa: E402

FEAT = os.environ.get("FEAT", "/features")
OUT = os.environ.get("OUT", "/results")
N_RANDOM = int(os.environ.get("N_RANDOM", "1500"))
EVENT_DB = [4.0, 6.0, 8.0, 10.0, 12.0, 15.0, 18.0]
rng = np.random.default_rng(7)


def sample():
    return dict(
        eventDB=float(rng.choice(EVENT_DB)),
        wakeScore=float(rng.uniform(1, 20)),
        smoothEpochs=int(rng.integers(2, 16)),
        deepMaxEvents=float(np.exp(rng.uniform(np.log(0.05), np.log(4)))),
        deepRegularityQuantile=float(rng.uniform(0.2, 0.9)),
        deepMaxProgress=float(rng.uniform(0.3, 1.01)),
        remRegularityQuantile=float(rng.uniform(0.05, 0.7)),
        remMaxEvents=float(np.exp(rng.uniform(np.log(0.2), np.log(8)))),
        remDelayEpochs=int(rng.integers(0, 160)),
        majorityEpochs=int(rng.integers(0, 13)),
        minBlockEpochs=int(rng.integers(0, 13)),
    )


def load():
    subj = []
    for f in sorted(glob.glob(os.path.join(FEAT, "*.npz"))):
        d = np.load(f)
        lab = d["stage"].astype(int)
        pre = rules.prepare(d["rms"], d["high"])
        n = min(pre["n"], len(lab))
        lab = lab[:n]
        if (lab >= 0).sum() < 240 or (lab > 0).sum() < 60:  # < 2 h bewertet oder kaum Schlaf
            continue
        pre["n"] = n
        pre["resid"] = pre["resid"][:n]
        pre["reg"] = pre["reg"][:n]
        ev = {db: (pre["resid"] > db).sum(1).astype(float) for db in EVENT_DB}
        subj.append(dict(id=os.path.basename(f)[:-4], pre=pre, ev=ev, lab=lab))
    return subj


def evaluate(p, subj):
    return np.stack([rules.confusion(rules.estimate(s["pre"], p, s["ev"][p["eventDB"]]), s["lab"]) for s in subj])


def kappas(Ms):
    return np.array([rules.kappa(M) for M in Ms])


def summary(Ms):
    tot = Ms.sum(0)
    k = kappas(Ms)
    sw = [np.array([[M[0, 0], M[0, 1:].sum()], [M[1:, 0].sum(), M[1:, 1:].sum()]]) for M in Ms]
    ksw = np.array([rules.kappa(m) for m in sw])
    return dict(kappa_mean=float(np.nanmean(k)), kappa_median=float(np.nanmedian(k)),
                kappa_pooled=float(rules.kappa(tot)), acc_pooled=float(np.trace(tot) / tot.sum()),
                sleepwake_kappa_mean=float(np.nanmean(ksw)),
                recall={n: float(tot[i, i] / max(1, tot[i].sum())) for i, n in enumerate(["Wach", "REM", "Kern", "Tief"])},
                confusion=tot.tolist())


def main():
    os.makedirs(OUT, exist_ok=True)
    t = time.time()
    subj = load()
    print(f"{len(subj)} Personen geladen ({time.time() - t:.0f} s)", flush=True)
    lab_all = np.concatenate([s["lab"] for s in subj])
    dist = {n: int((lab_all == i).sum()) for i, n in enumerate(["Wach", "REM", "Kern", "Tief"])}
    print("Labor-Verteilung (Epochen):", dist, flush=True)

    params = [dict(rules.DEFAULTS)] + [sample() for _ in range(N_RANDOM)]
    res = []
    for i, p in enumerate(params):
        res.append(evaluate(p, subj))
        if i % 100 == 0:
            print(f"{i}/{len(params)}  {time.time() - t:.0f} s", flush=True)
    K = np.stack([kappas(M) for M in res])  # (Parametersätze, Personen)

    # Nachschärfen: Umgebung der 20 besten leicht variieren
    top = np.argsort(-np.nanmean(K, 1))[:20]
    for j in top:
        for _ in range(15):
            p = dict(params[j])
            key = rng.choice(list(p))
            q = sample()
            p[key] = q[key]
            params.append(p)
            res.append(evaluate(p, subj))
    K = np.stack([kappas(M) for M in res])

    folds = np.arange(len(subj)) % 5
    rng.shuffle(folds)
    cv_M = []
    chosen = []
    for f in range(5):
        tr, te = folds != f, folds == f
        b = int(np.nanargmax(np.nanmean(K[:, tr], 1)))
        chosen.append(b)
        cv_M.append(res[b][te])
    cv_M = np.concatenate(cv_M)
    best = int(np.nanargmax(np.nanmean(K, 1)))
    out = dict(
        persons=len(subj), lab_distribution=dist, configs=len(params),
        defaults_v3=summary(res[0]),
        crossvalidated=summary(cv_M),
        best_all=summary(res[best]), best_params=params[best],
        fold_choices=[params[b] for b in chosen],
        per_person=[dict(id=s["id"], kappa_default=float(K[0, i]), kappa_best=float(K[best, i])) for i, s in enumerate(subj)],
    )
    json.dump(out, open(os.path.join(OUT, "stage1.json"), "w"), indent=1)
    print(json.dumps({k: out[k] for k in ("persons", "defaults_v3", "crossvalidated", "best_params")}, indent=1))


if __name__ == "__main__":
    main()
