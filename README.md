<p align="center">
  <img src="docs/logo.png" width="128" alt="Suya-Logo">
</p>

<h1 align="center">Suya</h1>
<p align="center"><b>Schlaf-Tracker fürs iPhone, der einfach zuhört.</b><br>
Leg das iPhone neben das Bett – Suya erkennt aus Atmung und Bewegung deine Schlafphasen.<br>
Ohne Uhr, ohne Armband, ohne Cloud.</p>

<p align="center">
  <img src="docs/screenshots/tonight.jpg" width="200" alt="Heute Nacht">
  <img src="docs/screenshots/night.jpg" width="200" alt="Auswertung einer Nacht">
  <img src="docs/screenshots/sounds.jpg" width="200" alt="Einschlafklänge">
  <img src="docs/screenshots/alarms.jpg" width="200" alt="Wecker">
</p>

## Was Suya kann

- **Schlafphasen nur übers Mikrofon** – Wach, REM, Kern- und Tiefschlaf. Ein kleines neuronales Netz
  wertet die Nacht direkt auf dem iPhone aus; nichts verlässt das Gerät.
- **Schlafwert** aus Dauer, Ruhe, Tief- und REM-Schlaf und Aufwachen – mit Zeitstrahl der Nacht.
- **Apple Health**: Die Phasen landen auf Wunsch in Health. Mit Apple Watch siehst du beide Schätzungen
  nebeneinander.
- **Wecker mit Wecken im leichten Schlaf** – klingelt wie der iPhone-Wecker, auch bei Stummschaltung und
  im Schlaf-Fokus (AlarmKit).
- **27 Einschlafklänge** in Studioqualität, frei mischbar, mit Timer und Ausblenden beim Einschlafen.
  Laufende Klänge zählen nicht in die Auswertung.
- **Live-Aktivität**, Kurzbefehle („Schlafaufnahme starten“), Aufnahme im Querformat für den Nachttisch.
- **10 Sprachen**: Deutsch, Englisch, Spanisch, Französisch, Italienisch, Portugiesisch, Niederländisch,
  Japanisch, Koreanisch, Chinesisch.

## Datenschutz

- Ausgewertet wird **auf dem iPhone**. Der Ton bleibt 24 Stunden zum Export verfügbar und wird danach
  gelöscht; übrig bleibt nur ein grobes Klangbild, aus dem sich keine Sprache verstehen lässt.
- **Freiwillige Datenspende**: Wer möchte, spendet einzelne Nächte (nur das Klangbild und die
  Schlafphasen, keine Aufnahmen) an einen eigenen Server in Hamburg, damit das Modell besser wird.
  Widerruf und Löschung jederzeit in der App.
- Datenschutzerklärung: <https://suya.ng-lab.de/datenschutz> · Impressum: <https://suya.ng-lab.de/impressum>

## Installieren (SideStore)

SideStore → **Sources** → **+** → diese Adresse eintragen:

```
https://github.com/NikGro/suya/releases/latest/download/source.json
```

Danach Suya einmal aus dieser Quelle installieren. Neue Versionen erscheinen dann automatisch unter
„My Apps“. Damit Suya mit einer kostenlosen Apple-ID auf Apple Health zugreifen darf, braucht es ein
leicht angepasstes SideStore – siehe [sidestore/README.md](sidestore/README.md).

Versionen heißen *Jahr.Monat.Nummer* (z. B. `26.11.14`); jeder Push auf `main` baut und veröffentlicht
eine neue Version.

## Aufbau

| Ordner | Inhalt |
|---|---|
| `SleepSonar/` | die App (SwiftUI): Aufnahme, Auswertung, Wecker, Klänge, Datenspende |
| `Packages/SonarDSP/` | Signalverarbeitung (Log-Mel-Spektrogramm, Normierung) mit Tests |
| `Widgets/` | Live-Aktivität und Widgets |
| `training/` | Training des Schlafphasen-Modells (PyTorch → Core ML) |
| `server/` | Server für Datenspende, Fehlerberichte und die Webseiten (läuft auf einer Synology) |
| `scripts/` | Übersetzungen, Klänge, Hilfsskripte |

**Das Modell** lernt aus Tonaufnahmen von Schlaflabor-Messungen (öffentlicher Datensatz) und aus eigenen
Nächten mit Apple-Watch-Schlafphasen. Aufbau angelehnt an SoundSleepNet: Log-Mel-Spektrogramm je
30-Sekunden-Abschnitt → kleines CNN → bidirektionales GRU über die ganze Nacht.

## Lizenz

[PolyForm Noncommercial 1.0.0](LICENSE): Ansehen, Ausprobieren, Verändern und Weitergeben sind für
nicht-kommerzielle Zwecke erlaubt; kommerzielle Nutzung nur mit schriftlicher Erlaubnis.
Die Schlafklänge stammen von freesound.org (CC0 / CC BY) und stehen unter ihren eigenen Lizenzen –
Namensnennung in der App unter „Quellen der Klänge“.

---

<sub>**English:** Suya is an iPhone sleep tracker that only listens: put the phone next to your bed and an
on-device neural network estimates your sleep stages (wake, REM, core, deep) from breathing and movement
sounds – no watch, no cloud. It writes to Apple Health, has a smart alarm that wakes you in light sleep,
27 high-quality sleep sounds and is available in 10 languages. Install via SideStore with the source URL
above. Source-available under the PolyForm Noncommercial License.</sub>
