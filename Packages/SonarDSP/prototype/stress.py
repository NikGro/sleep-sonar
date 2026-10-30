import numpy as np, sonar_proto as sp
def run(rr=15, hr=68, body=0.005, noise=0.01, breath_mm=4.0, heart_mm=0.15, harmonic=0.0, seconds=35, seed=2):
    sr=48000; f=20000.; lam=sp.C/f; rng=np.random.default_rng(seed); p=sp.Processor(sr,f)
    for start in range(0, seconds*sr, 4800):
        t=(start+np.arange(4800))/sr
        ph=2*np.pi*rr/60*t
        b=np.sin(ph)+harmonic*np.sin(2*ph+0.5)+harmonic*0.5*np.sin(3*ph+1.0)
        d=0.5+breath_mm/1000*b+heart_mm/1000*np.sin(2*np.pi*hr/60*t)
        x=0.1*np.cos(2*np.pi*f*t+0.7)+body*np.cos(2*np.pi*f*t-4*np.pi*d/lam+1.3)+noise*rng.standard_normal(4800)
        p.feed(x,start)
    return p.analyze()
cases=[("Basis",{}),
       ("Atem 9 / Puls 55",dict(rr=9,hr=55)),
       ("Atem 22 / Puls 92",dict(rr=22,hr=92)),
       ("Echo 4x schwächer",dict(body=0.00125)),
       ("Echo 10x schwächer",dict(body=0.0005)),
       ("Flache Atmung 1.5 mm",dict(breath_mm=1.5)),
       ("Unregelm. Atmung (Oberwellen)",dict(harmonic=0.4)),
       ("Puls 0.05 mm",dict(heart_mm=0.05)),
       ("Leeres Bett",dict(body=0.0)),
       ("Unregelm. + Puls 0.3 mm",dict(harmonic=0.4, heart_mm=0.3)),
       ("Unregelm. Atem 12 / Puls 75",dict(harmonic=0.5, rr=12, hr=75)),
]
for name,kw in cases:
    r=run(**kw)
    print(f"{name:32s} Atem {r['rr'] or 0:5.1f} (k={r['rr_conf']:.2f})  Puls {r['hr'] or 0:5.1f} (k={r['hr_conf']:5.1f})  Hub {r['amp_mm']:5.1f} mm  Bew {r['move']:5.1f}  snr={r['snr']:5.1f} {r['status']}")
