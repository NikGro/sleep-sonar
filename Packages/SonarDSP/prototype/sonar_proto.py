"""Prototyp der Sonar-Signalverarbeitung (Vorlage für die Swift-Version).

Ablauf:
  48 kHz Mikrofon  ->  I/Q-Mischung mit Trägerfrequenz  ->  Mittelung 480 Samples (100 Hz)
  -> Dezimierung auf 50 Hz  ->  Kreisfit (statisches Echo = Mittelpunkt)
  -> Phase um den Mittelpunkt, entfaltet  ->  Weg in mm (lambda/4pi pro rad)
  -> Atemfrequenz (Autokorrelation 1.5-10 s), Puls (Bandpass + Autokorrelation 0.4-1.5 s)
  -> Bewegung: |dz|/r als Wegänderung in mm/s, 1 s gemittelt
"""
import numpy as np

C = 343.0  # Schallgeschwindigkeit m/s


def circle_fit(x, y):
    """Algebraischer Kreisfit (Kasa). Gibt (cx, cy, r) oder None."""
    A = np.column_stack([x, y, np.ones_like(x)])
    b = -(x * x + y * y)
    # Normalgleichungen 3x3 (so auch in Swift lösbar)
    AtA = A.T @ A
    Atb = A.T @ b
    try:
        D, E, F = np.linalg.solve(AtA, Atb)
    except np.linalg.LinAlgError:
        return None
    cx, cy = -D / 2, -E / 2
    r2 = cx * cx + cy * cy - F
    if r2 <= 0:
        return None
    return cx, cy, np.sqrt(r2)


def autocorr_peak(sig, lag_min, lag_max):
    sig = sig - sig.mean()
    denom = np.dot(sig, sig)
    if denom <= 0:
        return None, 0.0
    best_lag, best = None, -1.0
    vals = {}
    for lag in range(lag_min, min(lag_max, len(sig) - 2) + 1):
        v = np.dot(sig[:-lag], sig[lag:]) / denom
        vals[lag] = v
    # erstes deutliches lokales Maximum bevorzugen, sonst globales
    lags = sorted(vals)
    for i in range(1, len(lags) - 1):
        l = lags[i]
        if vals[l] > vals[lags[i - 1]] and vals[l] >= vals[lags[i + 1]] and vals[l] > 0.3:
            best_lag, best = l, vals[l]
            break
    if best_lag is None:
        l = max(vals, key=vals.get)
        best_lag, best = l, vals[l]
    # parabolische Interpolation
    if best_lag - 1 in vals and best_lag + 1 in vals:
        a, b_, c = vals[best_lag - 1], vals[best_lag], vals[best_lag + 1]
        den = a - 2 * b_ + c
        off = 0.5 * (a - c) / den if den != 0 else 0.0
        return best_lag + float(np.clip(off, -0.5, 0.5)), best
    return float(best_lag), best


def moving_avg(x, n):
    """Kausaler gleitender Mittelwert (am Anfang kürzeres Fenster, kein Null-Padding)."""
    if n <= 1:
        return np.asarray(x, dtype=float)
    c = np.cumsum(np.insert(np.asarray(x, dtype=float), 0, 0.0))
    out = np.empty(len(x))
    for i in range(len(x)):
        lo = max(0, i + 1 - n)
        out[i] = (c[i + 1] - c[lo]) / (i + 1 - lo)
    return out


class Processor:
    def __init__(self, sr=48000, f=20000.0):
        self.sr, self.f = sr, f
        self.lam = C / f
        self.block = sr // 100  # 100 Hz
        self.acc = 0j
        self.count = 0
        self.dec = []
        self.z50 = []  # 50 Hz komplexe Werte
        self.vel = []  # Bewegung mm/s pro 100-Hz-Schritt
        self.prev = None
        self.radius = None
        self.n = 0  # Samplezähler (für Trägerphase)

    def feed(self, x, start_sample):
        # Trägerphase aus absoluter Sampleposition (wie AVAudioTime.sampleTime)
        idx = start_sample + np.arange(len(x))
        lo = np.exp(-2j * np.pi * self.f * idx / self.sr)
        mixed = x * lo
        for v in mixed:  # in Swift: einfache Schleife
            self.acc += v
            self.count += 1
            if self.count == self.block:
                z = self.acc / self.block
                self.acc, self.count = 0j, 0
                self._on100(z)

    def _on100(self, z):
        if self.prev is not None and self.radius:
            dz = abs(z - self.prev)
            self.vel.append(dz / self.radius * self.lam / (4 * np.pi) * 1000 * 100)  # mm/s
        self.prev = z
        self.dec.append(z)
        if len(self.dec) == 2:
            self.z50.append((self.dec[0] + self.dec[1]) / 2)
            self.dec = []
            self.z50 = self.z50[-1500:]  # 30 s

    def analyze(self):
        fs = 50.0
        z = np.array(self.z50)
        if len(z) < fs * 8:
            return None
        fit = circle_fit(z.real[-1000:], z.imag[-1000:])
        spread = np.std(z)
        # Rauschen pro Sample aus Nachbardifferenzen (Atmung ist dagegen sehr langsam)
        dz = np.diff(z[-500:])
        noise = np.sqrt(np.mean(np.abs(dz) ** 2) / 2)
        level_db = 20 * np.log10(abs(z[-50:].mean()) + 1e-12)
        use_fit = fit is not None and fit[2] < 20 * spread * np.sqrt(2) + 1e-12
        if use_fit:
            cx, cy, r = fit
            ph = np.unwrap(np.angle(z - (cx + 1j * cy)))
            disp = -ph * self.lam / (4 * np.pi) * 1000  # mm
        else:
            zc = z - z.mean()
            cov = np.cov(np.vstack([zc.real, zc.imag]))
            w, v = np.linalg.eigh(cov)
            u = v[:, -1]
            proj = zc.real * u[0] + zc.imag * u[1]
            r = max(np.sqrt(w[-1]) * 2, 1e-12)
            disp = proj / r * self.lam / (4 * np.pi) * 1000
        snr = r / (noise + 1e-15)
        if snr < SNR_MIN:
            return dict(rr=None, rr_conf=0, hr=None, hr_conf=0, move=0.0, amp_mm=0, fit=use_fit,
                        quiet_s=0, snr=snr, status="kein Echo", level_db=level_db)
        # Bewegung: Geschwindigkeit der geglätteten Wegkurve, je 0.5 s
        sm = moving_avg(disp, 10)
        v = np.abs(np.diff(sm)) * fs
        half = int(fs / 2)
        nseg = len(v) // half
        seg_v = np.array([v[len(v) - (k + 1) * half: len(v) - k * half].mean() for k in range(nseg)])[::-1]
        move = float(seg_v[-2:].mean())  # letzte Sekunde
        # Atemfenster: nur ruhige Zeit seit der letzten Bewegung
        moving = np.where(seg_v > MOVE_MM_S)[0]
        start = 0 if len(moving) == 0 else (moving[-1] + 2) * half
        start = max(start, len(disp) - int(30 * fs))
        quiet = disp[start:]
        rr = rr_conf = None
        amp = None
        if len(quiet) >= 10 * fs:
            t = np.arange(len(quiet))
            q = quiet - np.polyval(np.polyfit(t, quiet, 1), t)
            breath = moving_avg(q, 20)
            lag, rr_conf = autocorr_peak(breath, int(1.5 * fs), int(10 * fs))
            rr = 60 * fs / lag if lag else None
            amp = float(np.ptp(breath[-int(10 * fs):]))
        hr = hr_conf = None
        if len(quiet) >= 10 * fs:
            hb = moving_avg(quiet, 5) - moving_avg(quiet, 30)
            hb = hb[-int(20 * fs):]
            excl = [n * rr for n in range(2, 12)] if rr and rr_conf > RR_CONF_MIN else []
            hr, hr_conf = spectral_peak(hb, fs, 50, 150, exclude=excl)
        status = "Bewegung" if move > MOVE_MM_S else ("ok" if rr and rr_conf > RR_CONF_MIN else "sammle Daten")
        return dict(rr=rr, rr_conf=rr_conf or 0, hr=hr, hr_conf=hr_conf or 0, move=move,
                    amp_mm=amp or 0, fit=use_fit, quiet_s=len(quiet) / fs, snr=snr, status=status,
                    level_db=level_db)


MOVE_MM_S = 15.0
SNR_MIN = 1.8
RR_CONF_MIN = 0.5
HR_CONF_MIN = 6.0


def spectral_peak(sig, fs, bpm_lo, bpm_hi, step=0.5, exclude=(), exclude_width=5.0):
    """DFT auf Raster (Hann-Fenster). Konfidenz = Peak / Mittel im Band."""
    n = len(sig)
    w = 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(n) / (n - 1))
    x = (sig - sig.mean()) * w
    bpms = np.arange(bpm_lo, bpm_hi + step, step)
    t = np.arange(n) / fs
    p = np.array([abs(np.dot(x, np.exp(-2j * np.pi * b / 60 * t))) ** 2 for b in bpms])
    mask = np.ones(len(bpms), bool)
    for e in exclude:
        mask &= np.abs(bpms - e) > exclude_width
    if not mask.any():
        return None, 0.0
    pm = np.where(mask, p, -1)
    i = int(np.argmax(pm))
    return float(bpms[i]), float(p[i] / (p[mask].mean() + 1e-30))


def simulate(seconds=60, sr=48000, f=20000.0, rr_bpm=15, hr_bpm=68,
             breath_mm=4.0, heart_mm=0.15, move_at=(40, 42), noise=0.01, seed=1):
    rng = np.random.default_rng(seed)
    lam = C / f
    p = Processor(sr, f)
    chunk = 4800
    out = []
    for start in range(0, seconds * sr, chunk):
        t = (start + np.arange(chunk)) / sr
        d = 0.5 + breath_mm / 1000 * np.sin(2 * np.pi * rr_bpm / 60 * t) \
            + heart_mm / 1000 * np.sin(2 * np.pi * hr_bpm / 60 * t)
        if move_at:
            a, b = move_at
            ramp = np.clip((t - a) / (b - a), 0, 1)
            d = d + 0.10 * (0.5 - 0.5 * np.cos(np.pi * ramp))
        direct = 0.1 * np.cos(2 * np.pi * f * t + 0.7)
        body = 0.005 * np.cos(2 * np.pi * f * t - 4 * np.pi * d / lam + 1.3)
        x = direct + body + noise * rng.standard_normal(chunk)
        p.feed(x, start)
        if (start + chunk) % sr == 0:
            r = p.analyze()
            if r:
                out.append((int((start + chunk) / sr), r))
    return out


if __name__ == "__main__":
    for sec, r in simulate():
        print(f"{sec:3d}s ruhig {r['quiet_s']:4.1f}s   Atem {r['rr'] or 0:5.1f}/min (k={r['rr_conf']:.2f})  "
              f"Puls {r['hr'] or 0:5.1f}/min (k={r['hr_conf']:.2f})  "
              f"Bew {r['move']:6.1f} mm/s  Hub {r['amp_mm']:4.1f} mm  fit={r['fit']}  "
              f"Pegel {r['level_db']:.0f} dB")
