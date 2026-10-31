"""Stufe 2: Epochen-Merkmale aus den Sekundenwerten der App (rms, peak, low, mid, high in dBFS).

Alles wird je Nacht normalisiert (Abstand zum ruhigen Grundpegel bzw. zum Nacht-Median),
damit Mikrofon und Raum (Labor vs. iPhone im Schlafzimmer) möglichst keine Rolle spielen.
Muss später 1:1 in Swift nachgebaut werden – daher nur einfache Rechenschritte.
"""
import numpy as np
from numpy.lib.stride_tricks import sliding_window_view as swv

EP = 30


def _autocorr_feats(x, centers, half=60, lags=range(2, 13)):
    """Max. Autokorrelation (Atemrhythmus 2–12 s) und Lag des Maximums im Fenster ±half s."""
    n = len(centers)
    best = np.zeros(n)
    lag_at = np.zeros(n)
    ok = (centers - half >= 0) & (centers + half <= len(x))
    if ok.any():
        W = swv(x, 2 * half)[centers[ok] - half]
        d = W - W.mean(1, keepdims=True)
        den = (d * d).sum(1)
        den = np.where(den > 1e-9, den, np.inf)
        b = np.full(len(d), -1.0)
        la = np.zeros(len(d))
        for lag in lags:
            r = (d[:, :-lag] * d[:, lag:]).sum(1) / den
            better = r > b
            b = np.where(better, r, b)
            la = np.where(better, lag, la)
        best[ok] = np.maximum(b, 0)
        lag_at[ok] = la
    return best, lag_at


def _baseline(x, n):
    """20-%-Quantil in ±150 s je Epoche (wie in der App)."""
    base = np.empty(n)
    for e in range(n):
        c = e * EP + EP // 2
        v = np.sort(x[max(0, c - 150):min(len(x), c + 150)])
        base[e] = v[len(v) // 5]
    return base


def _smooth(x, k):
    c = np.concatenate([np.zeros((1,) + x.shape[1:]), np.cumsum(x, 0)])
    i = np.arange(len(x))
    lo = np.maximum(0, i - k)
    hi = np.minimum(len(x) - 1, i + k)
    return (c[hi + 1] - c[lo]) / (hi - lo + 1)[:, None]


BASE_NAMES = []


def epoch_features(rms, peak, low, mid, high):
    rms, peak, low, mid, high = (np.asarray(a, float) for a in (rms, peak, low, mid, high))
    n = len(rms) // EP
    if n == 0:
        return np.zeros((0, 0)), []
    cut = n * EP
    centers = np.arange(n) * EP + EP // 2
    cols, names = [], []

    def add(name, v):
        cols.append(np.asarray(v, float))
        names.append(name)

    for nm, x in (("rms", rms), ("low", low), ("mid", mid), ("high", high)):
        base = _baseline(x, n)
        r = x[:cut].reshape(n, EP) - base[:, None]
        add(f"{nm}_mean", r.mean(1))
        add(f"{nm}_std", r.std(1))
        add(f"{nm}_p90", np.percentile(r, 90, axis=1))
        add(f"{nm}_max", r.max(1))
        add(f"{nm}_base_rel", base - np.median(base))   # Grundpegel relativ zur Nacht
        for t in (6, 12, 18):
            add(f"{nm}_ev{t}", (r > t).sum(1))
        add(f"{nm}_diff", np.abs(np.diff(x[:cut].reshape(n, EP), axis=1)).mean(1))
    crest = (peak - rms)[:cut].reshape(n, EP)
    add("crest_mean", crest.mean(1))
    add("crest_max", crest.max(1))
    sl = (high - low)[:cut].reshape(n, EP)
    add("tilt_hl", sl.mean(1) - np.median(sl))
    sm = (mid - low)[:cut].reshape(n, EP)
    add("tilt_ml", sm.mean(1) - np.median(sm))
    for nm, x in (("high", high), ("low", low), ("rms", rms)):
        reg, lag = _autocorr_feats(x, centers)
        add(f"{nm}_reg", reg)
        add(f"{nm}_lag", lag)
    reg2, _ = _autocorr_feats(high, centers, half=150)
    add("high_reg5", reg2)

    F = np.stack(cols, 1)
    # Kontext: geglättete Versionen über ±2, ±5, ±10 Epochen (1, 2,5, 5 min)
    ctx = [F]
    cnames = list(names)
    for k in (2, 5, 10):
        ctx.append(_smooth(F, k))
        cnames += [f"{c}_s{k}" for c in names]
    # Rang innerhalb der Nacht (0..1) für die wichtigsten Merkmale – unabhängig vom Mikrofon
    for c in ("rms_ev12", "high_reg", "high_std", "rms_std"):
        j = names.index(c)
        v = _smooth(F[:, [j]], 5)[:, 0]
        ctx.append((np.argsort(np.argsort(v)) / max(1, n - 1))[:, None])
        cnames.append(f"{c}_rank")
    t = np.arange(n)
    ctx.append(np.stack([t * EP / 3600.0, t / max(1, n - 1)], 1))
    cnames += ["hours_since_start", "night_fraction"]
    return np.concatenate(ctx, 1).astype(np.float32), cnames
