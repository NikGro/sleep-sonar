# Idee: Datenspende (Stand 31.10.2026, noch nicht umgesetzt)

Ziel: Nutzer können freiwillig Nächte spenden, damit das Schlafphasen-Modell für alle besser wird.

## Ablauf in der App
- Bei der Einrichtung ein Dialog „Datenspende“ mit zwei gleichwertigen Knöpfen („Ja, spenden“ / „Nein, danke“).
  **Keine Vorauswahl** – vorangekreuzte Einwilligungen sind nach DSGVO unwirksam (EuGH Planet49, C-673/17).
- Kurzer, ehrlicher Text: was übertragen wird, wozu, wie lange gespeichert, wie man widerruft.
- Jederzeit in den Einstellungen abschaltbar; Liste der bereits gespendeten Nächte; Löschanfrage per Spender-ID.
- Einwilligung mit Zeitpunkt und Textversion dokumentieren (Art. 7 Abs. 1 DSGVO).

## Welche Nächte („qualifiziert“)
- mindestens 5 h durchgehende Aufnahme ohne Lücke
- Apple-Watch-Schlafphasen decken diese Zeit ab (Watch getragen)
- automatische Prüfung in der App, Upload danach automatisch

## Was übertragen wird
- **kein Rohaudio**
- Merkmale, die das Modell braucht (Stand heute: Sekunden-Pegel + 3 Bänder; für Stufe 3 ggf. grobes Spektrum oder Embeddings, siehe unten)
- Watch-Phasen je 30 s, optional Puls/Atemfrequenz
- Zeit relativ zum Aufnahmebeginn, kein Datum
- zufällige Spender-ID (nicht Apple-ID/Gerät), App-Version, iPhone-Modell (Mikrofon unterscheidet sich)

## Übertragung / Speicherung
- HTTPS an einen kleinen Upload-Dienst (nicht die Synology direkt im Internet), keine IP-Protokolle
- Zugriff nur für mich; Löschung auf Anfrage über die Spender-ID

## Offene Fragen
- Zählt das als „health-related human subject research“ (Apple 5.1.3 → Ethikkommission nötig) oder reicht die DSGVO-Einwilligung (Art. 9 Abs. 2 lit. a)? → Nik prüft.
- Einwilligungstext + Datenschutzerklärung vor dem Start prüfen lassen.
- Merkmalsumfang so wählen, dass das Training gleich gut bleibt wie mit Audio (siehe Abschnitt Qualität).

## Qualität: Merkmale statt Audio
- Stufe 1 + 2 (Regeln / Klassifikator auf Sekunden-Merkmalen): 1:1 gleich gut, die Modelle sehen nie Audio.
- Stufe 3 (Audio-Modell): mit Sekunden-Pegeln **nicht** gleich gut. Optionen:
  - grobes Log-Mel-Spektrum (z. B. 32–64 Bänder, ~10 Bilder/s): fast alles, was Atem/Schnarchen/Bewegung ausmacht; Sprache praktisch nicht verständlich, aber nicht beweisbar unmöglich
  - Embeddings vom Audio-Modell auf dem iPhone: Kopf trainierbar wie mit Audio, aber das „Ohr“ selbst nicht mehr nachtrainierbar
