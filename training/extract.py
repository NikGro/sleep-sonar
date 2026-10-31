#!/usr/bin/env python3
"""PSG-Audio → dieselben Sekunden-Merkmale wie die App (PassiveRecorder.swift).

Je Person (V*/APNEA_EDF/<id>/<id>[001..].edf + passende .rml):
  - Mikrofon-Kanal (48 kHz) lesen, in Stücken, auf 16 kHz heruntertakten (FIR + jede 3. Probe)
  - je Sekunde: Pegel (RMS, dBFS bezogen auf den EDF-Wertebereich), Spitze, drei Bandpässe
    (RBJ, Q 0.7: 250 / 1200 / 4500 Hz) – identisch zur App
  - Labor-Schlafphasen je 30 s aus der RML (NeuroAdultAASM, vom Menschen bewertet)
Ergebnis: features/<id>.npz  (rms, peak, low, mid, high: float32 je Sekunde; stage: int8 je Epoche)
Stage-Codes wie in der App: 0 Wach, 1 REM, 2 Kern (N1+N2), 3 Tief (N3), -1 unbewertet.
"""
import glob
import json
import os
import re
import sys
import time
import xml.etree.ElementTree as ET

import numpy as np
import pyedflib
from scipy.signal import firwin, lfilter, lfilter_zi

ROOT = os.environ.get("PSG_ROOT", "/data/hf")
OUT = os.environ.get("OUT", "/features")
FS_OUT = 16_000
STAGE_CODE = {"Wake": 0, "REM": 1, "NonREM1": 2, "NonREM2": 2, "NonREM3": 3, "NonREM4": 3}


def biquad_bandpass(f, q, fs):
    w = 2 * np.pi * f / fs
    alpha = np.sin(w) / (2 * q)
    a0 = 1 + alpha
    b = np.array([alpha / a0, 0.0, -alpha / a0])
    a = np.array([1.0, -2 * np.cos(w) / a0, (1 - alpha) / a0])
    return b, a


def parse_rml(path):
    root = ET.parse(path).getroot()
    for el in root.iter():  # Namensräume entfernen, damit die Pfade einfach bleiben
        if "}" in el.tag:
            el.tag = el.tag.split("}", 1)[1]
    acq = root.find(".//Acquisition")
    segs = [int(float(s.find("Duration").text)) for s in acq.findall(".//Segments/Segment")]
    dur = acq.find(".//Sessions/Session/Duration")
    total = int(float(dur.text)) if dur is not None else sum(segs)
    stages = root.findall(".//StagingData/UserStaging/NeuroAdultAASMStaging/Stage")
    n = total // 30
    lab = np.full(n, -1, np.int8)
    trans = [(int(float(s.get("Start"))), s.get("Type")) for s in stages]
    trans.sort()
    for i, (start, typ) in enumerate(trans):
        end = trans[i + 1][0] if i + 1 < len(trans) else total
        code = STAGE_CODE.get(typ, -1)
        lab[start // 30:min(n, end // 30)] = code
    return total, segs, lab


def find_rml(sid):
    for v in ("V3", "V2", "V1"):
        for sub in ("APNEA_RML", "APNEA_RML_clean"):
            p = os.path.join(ROOT, v, sub, sid + ".rml")
            if os.path.exists(p):
                return p
    return None


def part_files(d):
    files = glob.glob(os.path.join(d, "*.edf"))

    def idx(f):
        m = re.search(r"(?:\[|%5B)(\d+)(?:\]|%5D)", os.path.basename(f))
        return int(m.group(1)) if m else 0
    return sorted(files, key=idx), [idx(f) for f in sorted(files, key=idx)]


def extract(sid, edf_dir):
    rml = find_rml(sid)
    if not rml:
        return "keine RML"
    total, segs, lab = parse_rml(rml)
    if "VFTP" in edf_dir and not os.path.exists(os.path.join(edf_dir, ".done")):
        return "unvollstaendig (FTP laeuft noch)"
    files, idxs = part_files(edf_dir)
    if not files:
        return "keine EDF"
    expected = len(segs) or len(files)
    if idxs != list(range(1, len(files) + 1)) or len(files) < expected:
        return f"unvollständig ({len(files)}/{expected} Teile)"

    fir = firwin(97, 7000, fs=48_000)
    zi_fir = None
    bands = [biquad_bandpass(f, 0.7, FS_OUT) for f in (250, 1200, 4500)]
    zi_b = [None, None, None]
    phase = 0  # Position für das Heruntertakten (jede 3. Probe), über Stückgrenzen hinweg
    buf = np.zeros(0, np.float64)
    rows = {k: [] for k in ("rms", "peak", "low", "mid", "high")}

    for f in files:
        e = pyedflib.EdfReader(f)
        try:
            labels = [l.lower() for l in e.getSignalLabels()]
            ch = next(i for i, l in enumerate(labels) if l.startswith("mic") and e.getSampleFrequency(i) >= 8000)
            fs = e.getSampleFrequency(ch)
            if int(fs) != 48_000:
                return f"Mikrofon mit {fs} Hz"
            scale = max(abs(e.getPhysicalMaximum(ch)), abs(e.getPhysicalMinimum(ch))) or 1.0
            n = e.getNSamples()[ch]
            step = 48_000 * 60
            for start in range(0, n, step):
                x = e.readSignal(ch, start, min(step, n - start)) / scale
                if zi_fir is None:
                    zi_fir = lfilter_zi(fir, [1.0]) * x[0]
                y, zi_fir = lfilter(fir, [1.0], x, zi=zi_fir)
                y = y[(3 - phase) % 3::3]
                phase = (phase + len(x)) % 3
                buf = np.concatenate([buf, y])
                nsec = len(buf) // FS_OUT
                if nsec == 0:
                    continue
                block = buf[:nsec * FS_OUT].reshape(nsec, FS_OUT)
                buf = buf[nsec * FS_OUT:]
                flat = block.reshape(-1)
                rows["rms"].append(10 * np.log10((block ** 2).mean(1) + 1e-14))
                rows["peak"].append(20 * np.log10(np.abs(block).max(1) + 1e-7))
                for k, (b, a) in enumerate(bands):
                    if zi_b[k] is None:
                        zi_b[k] = np.zeros(2)
                    yb, zi_b[k] = lfilter(b, a, flat, zi=zi_b[k])
                    rows[("low", "mid", "high")[k]].append(
                        10 * np.log10((yb.reshape(nsec, FS_OUT) ** 2).mean(1) + 1e-14))
        finally:
            e.close()

    feats = {k: np.concatenate(v).astype(np.float32) for k, v in rows.items()}
    np.savez_compressed(os.path.join(OUT, sid + ".npz"), stage=lab, total=total,
                        rml=os.path.relpath(rml, ROOT), **feats)
    return f"ok {len(feats['rms'])} s, {int((lab >= 0).sum())} Epochen bewertet"


def main():
    os.makedirs(OUT, exist_ok=True)
    dirs = sorted(d for d in glob.glob(os.path.join(ROOT, "V*", "APNEA_EDF", "*")) if os.path.isdir(d))
    only = sys.argv[1:]
    log = open(os.path.join(OUT, "extract_log.jsonl"), "a")
    shard, nshard = (int(x) for x in os.environ.get("SHARD", "0/1").split("/"))
    for i, d in enumerate(dirs):
        if i % nshard != shard:
            continue
        sid = os.path.basename(d)
        if only and sid not in only:
            continue
        if os.path.exists(os.path.join(OUT, sid + ".npz")):
            continue
        t = time.time()
        try:
            msg = extract(sid, d)
        except Exception as ex:  # einzelne kaputte Dateien überspringen
            msg = f"Fehler: {ex!r}"
        line = {"id": sid, "result": msg, "seconds": round(time.time() - t, 1)}
        print(json.dumps(line), flush=True)
        log.write(json.dumps(line) + "\n")
        log.flush()


if __name__ == "__main__":
    main()
