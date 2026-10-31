"""Python-Nachbau von SleepStaging.swift (v3) – vektorisiert, für das Anpassen an Labordaten.

Aufteilung: `prepare()` rechnet alles, was nicht von Parametern abhängt (Grundpegel,
Atemregelmäßigkeit), einmal je Person vor. `estimate()` wendet die Regeln an.
Stage-Codes: 0 Wach, 1 REM, 2 Kern, 3 Tief.
"""
import numpy as np
from numpy.lib.stride_tricks import sliding_window_view as swv

DEFAULTS = dict(eventDB=12.0, wakeScore=6.0, smoothEpochs=8, deepMaxEvents=0.3,
                deepRegularityQuantile=0.6, deepMaxProgress=0.6, remRegularityQuantile=0.4,
                remMaxEvents=2.0, remDelayEpochs=120, majorityEpochs=10, minBlockEpochs=10)
EP = 30


def prepare(rms, high):
    rms = np.asarray(rms, float)
    high = np.asarray(high, float)
    n = len(rms) // EP
    # Grundpegel: 20-%-Quantil (Index count/5 der sortierten Werte) in [c-150, c+150)
    base = np.empty(n)
    for e in range(n):
        c = e * EP + EP // 2
        v = np.sort(rms[max(0, c - 150):min(len(rms), c + 150)])
        base[e] = v[len(v) // 5]
    resid = rms[:n * EP].reshape(n, EP) - base[:, None]
    # Regelmäßigkeit: max. Autokorrelation (Lag 3–10 s) des Hochtonpegels in [c-60, c+60)
    reg = np.zeros(n)
    centers = np.arange(n) * EP + EP // 2
    ok = (centers - 60 >= 0) & (centers + 60 <= len(high))
    if ok.any():
        W = swv(high, 120)[centers[ok] - 60]
        d = W - W.mean(1, keepdims=True)
        den = (d * d).sum(1)
        best = np.zeros(len(d))
        for lag in range(3, 11):
            best = np.maximum(best, (d[:, :-lag] * d[:, lag:]).sum(1) / np.where(den > 1e-9, den, np.inf))
        reg[ok] = best
    return dict(n=n, resid=resid, reg=reg)


def moving_mean(x, k):
    c = np.concatenate([[0.0], np.cumsum(x)])
    i = np.arange(len(x))
    lo = np.maximum(0, i - k)
    hi = np.minimum(len(x) - 1, i + k)
    return (c[hi + 1] - c[lo]) / (hi - lo + 1)


def estimate(pre, p=DEFAULTS, events=None):
    n = pre["n"]
    ev = (pre["resid"] > p["eventDB"]).sum(1).astype(float) if events is None else events
    # Wach/Schlaf, gewichtete Nachbarschaft
    score = np.zeros(n)
    for k, w in ((-4, .15), (-3, .15), (-2, .15), (-1, .3), (0, 1.0), (1, .3), (2, .15)):
        sh = np.zeros(n)
        if k < 0:
            sh[-k:] = ev[:n + k]
        elif k > 0:
            sh[:-k] = ev[k:]
        else:
            sh = ev
        score += w * sh
    asleep = score <= p["wakeScore"]
    # kurze Schlafinseln (< 3 Epochen) zwischen Wach entfernen
    i = 0
    while i < n:
        if not asleep[i]:
            i += 1
            continue
        j = i
        while j < n and asleep[j]:
            j += 1
        if j - i < 3 and i > 0 and j < n:
            asleep[i:j] = False
        i = j
    win = 20
    onset, offset = n, -1
    if n >= win:
        s = swv(asleep.astype(int), win).sum(1) >= 18
        idx = np.flatnonzero(s)
        if len(idx):
            onset, offset = idx[0], idx[-1] + win - 1
    m = np.zeros(n, bool)
    if offset >= onset:
        m[onset:offset + 1] = True
    asleep &= m
    st = np.zeros(n, int)
    sl = np.flatnonzero(asleep)
    if len(sl):
        k = int(p["smoothEpochs"])
        q = moving_mean(ev, k)
        r = moving_mean(pre["reg"], k)
        rs = np.sort(r[sl])
        quant = lambda x: rs[min(len(rs) - 1, int(x * (len(rs) - 1)))]
        rDeep, rRem = quant(p["deepRegularityQuantile"]), quant(p["remRegularityQuantile"])
        prog = (sl - onset) / max(1, offset - onset)
        deep = (q[sl] <= p["deepMaxEvents"]) & (r[sl] >= rDeep) & (prog < p["deepMaxProgress"])
        rem = ~deep & (r[sl] <= rRem) & (q[sl] <= p["remMaxEvents"]) & (sl - onset >= p["remDelayEpochs"])
        st[sl] = np.where(deep, 3, np.where(rem, 1, 2))
    return smooth(st, asleep, int(p["majorityEpochs"]), int(p["minBlockEpochs"]))


def smooth(st, asleep, maj, min_block):
    n = len(st)
    out = st.copy()
    if maj > 0:
        onehot = np.zeros((n, 4))
        onehot[np.arange(n), st] = asleep
        c = np.vstack([np.zeros(4), np.cumsum(onehot, 0)])
        i = np.arange(n)
        lo = np.maximum(0, i - maj)
        hi = np.minimum(n, i + maj + 1)
        cnt = c[hi] - c[lo]
        # Swift: Dictionary-max bei Gleichstand ist nicht festgelegt; hier gewinnt der kleinere Code
        best = cnt.argmax(1)
        out[asleep] = best[asleep]
    i = 0
    while i < n:
        s = out[i]
        j = i
        while j < n and out[j] == s:
            j += 1
        if s in (1, 3) and j - i < min_block:
            out[i:j] = 2
        i = j
    return out


def confusion(pred, lab):
    M = np.zeros((4, 4), int)
    ok = lab >= 0
    np.add.at(M, (lab[ok], pred[ok]), 1)
    return M


def kappa(M):
    n = M.sum()
    if n == 0:
        return np.nan
    po = np.trace(M) / n
    pe = (M.sum(0) * M.sum(1)).sum() / n / n
    return (po - pe) / (1 - pe) if pe < 1 else 0.0


def error_runs(pred, lab):
    """Nutzer-Kriterien: (Minuten fälschlich „wach“ obwohl Schlaf, längster zusammenhängender Fehlabschnitt in Minuten)."""
    ok = lab >= 0
    false_wake = int(((pred == 0) & (lab > 0) & ok).sum()) / 2
    wrong = (pred != lab) & ok
    longest = run = 0
    for w in wrong:
        run = run + 1 if w else 0
        longest = max(longest, run)
    return false_wake, longest / 2
