#!/usr/bin/env python3
"""Stufe 3, Vorbereitung: Mikrofon-Kanal aus PSG-Audio als 16-kHz-Mono-FLAC (wie in der App).

Je Person: <OUT>/<id>.flac (16 bit, Pegel bezogen auf den EDF-Wertebereich wie extract.py)
und <OUT>/<id>.labels.npy (Phase je 30 s: 0 Wach, 1 REM, 2 Kern, 3 Tief, -1 unbewertet).
So muss der PC später keine 48-kHz-EDFs mehr lesen (≈ 1/10 der Datenmenge).
"""
import glob
import json
import os
import sys
import time

import numpy as np
import pyedflib
import soundfile as sf
from scipy.signal import firwin, lfilter, lfilter_zi

sys.path.insert(0, os.path.dirname(__file__))
from extract import ROOT, find_rml, parse_rml, part_files  # noqa: E402

OUT = os.environ.get("OUT", "/audio16k")


def convert(sid, edf_dir):
    rml = find_rml(sid)
    if not rml:
        return "keine RML"
    if "VFTP" in edf_dir and not os.path.exists(os.path.join(edf_dir, ".done")):
        return "unvollstaendig (FTP)"
    total, segs, lab = parse_rml(rml)
    files, idxs = part_files(edf_dir)
    expected = len(segs) or len(files)
    if not files or idxs != list(range(1, len(files) + 1)) or len(files) < expected:
        return f"unvollstaendig ({len(files)}/{expected} Teile)"
    fir = firwin(97, 7000, fs=48_000)
    zi = None
    phase = 0
    tmp = os.path.join(OUT, sid + ".flac.part")
    with sf.SoundFile(tmp, "w", samplerate=16_000, channels=1, subtype="PCM_16", format="FLAC") as out:
        for f in files:
            e = pyedflib.EdfReader(f)
            try:
                labels = [l.lower() for l in e.getSignalLabels()]
                ch = next(i for i, l in enumerate(labels) if l.startswith("mic") and e.getSampleFrequency(i) >= 8000)
                if int(e.getSampleFrequency(ch)) != 48_000:
                    return "Mikrofon nicht 48 kHz"
                scale = max(abs(e.getPhysicalMaximum(ch)), abs(e.getPhysicalMinimum(ch))) or 1.0
                n = e.getNSamples()[ch]
                step = 48_000 * 60
                for start in range(0, n, step):
                    x = e.readSignal(ch, start, min(step, n - start)) / scale
                    if zi is None:
                        zi = lfilter_zi(fir, [1.0]) * x[0]
                    y, zi = lfilter(fir, [1.0], x, zi=zi)
                    y = y[(3 - phase) % 3::3]
                    phase = (phase + len(x)) % 3
                    out.write(np.clip(y, -1, 1).astype(np.float32))
            finally:
                e.close()
    os.replace(tmp, os.path.join(OUT, sid + ".flac"))
    np.save(os.path.join(OUT, sid + ".labels.npy"), lab)
    return "ok"


def main():
    os.makedirs(OUT, exist_ok=True)
    shard, nshard = (int(x) for x in os.environ.get("SHARD", "0/1").split("/"))
    dirs = sorted(d for d in glob.glob(os.path.join(ROOT, "V*", "APNEA_EDF", "*")) if os.path.isdir(d))
    log = open(os.path.join(OUT, "audio_log.jsonl"), "a")
    for i, d in enumerate(dirs):
        if i % nshard != shard:
            continue
        sid = os.path.basename(d)
        if os.path.exists(os.path.join(OUT, sid + ".flac")):
            continue
        t = time.time()
        try:
            msg = convert(sid, d)
        except Exception as ex:
            msg = f"Fehler: {ex!r}"
        if not msg.startswith("unvollst"):
            line = {"id": sid, "result": msg, "seconds": round(time.time() - t, 1)}
            print(json.dumps(line), flush=True)
            log.write(json.dumps(line) + "\n")
            log.flush()


if __name__ == "__main__":
    main()
