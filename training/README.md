# Training (Stufe 1)

Passt die Regel-Schätzung aus `SleepStaging.swift` an Labordaten an.

- `extract.py`: PSG-Audio (EDF + RML) → Sekunden-Merkmale wie in der App (`features/<id>.npz`)
- `rules.py`: Python-Nachbau von `SleepStaging.estimate` (v3), geprüft gegen die Swift-Werte
- `fit.py`: Zufallssuche über die Parameter, 5-fache Kreuzvalidierung über Personen

Daten: PSG-Audio (Korompili et al., CC BY 4.0). Keine Daten im Repo.

## Gütekriterien (Nutzerwunsch)
Neben Kappa zählen zwei Fehler, die im Alltag am meisten stören:
- **falsch „wach“**: Minuten, die als wach gelten, obwohl geschlafen wurde
- **längster Fehlabschnitt**: längste zusammenhängende Zeit mit falscher Phase

Die Abstimmung bestraft beides (60 min längster Fehlabschnitt ≙ −0,1 Kappa, 30 min falsch wach ≙ −0,1 Kappa).
