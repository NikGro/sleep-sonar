# Training (Stufe 1)

Passt die Regel-Schätzung aus `SleepStaging.swift` an Labordaten an.

- `extract.py`: PSG-Audio (EDF + RML) → Sekunden-Merkmale wie in der App (`features/<id>.npz`)
- `rules.py`: Python-Nachbau von `SleepStaging.estimate` (v3), geprüft gegen die Swift-Werte
- `fit.py`: Zufallssuche über die Parameter, 5-fache Kreuzvalidierung über Personen

Daten: PSG-Audio (Korompili et al., CC BY 4.0). Keine Daten im Repo.
