# SleepSonar

Eigene Schlaf-App fürs iPhone: Schlafmessung per Ultraschall (Sonar), Schlafphasen (Wach, Kern, Tief, REM) werden in Apple Health geschrieben.

**Stand 0.1.0:** Test-App. Prüft, ob die per AltStore installierte App Schlafphasen in Health schreiben darf. Noch kein Sonar.

## Build

Jeder Push auf `main` baut über GitHub Actions eine `.ipa`
(Actions → letzter Lauf → Artifacts → `SleepSonar-ipa`, die ZIP entpacken).

## Installation mit AltStore Classic (Windows)

1. iTunes und iCloud **von apple.com** installieren (nicht die Microsoft-Store-Versionen).
2. AltServer von https://altstore.io herunterladen, installieren und starten.
3. iPhone per Kabel anschließen, im Tray-Symbol „Install AltStore“ wählen, mit Apple-ID anmelden.
4. iPhone: Einstellungen → Allgemein → VPN & Geräteverwaltung → Apple-ID vertrauen.
   Einstellungen → Datenschutz & Sicherheit → Entwicklermodus aktivieren (Neustart).
5. App installieren, eine der beiden Varianten:
   - **Vom PC:** iPhone angeschlossen lassen, **Shift gedrückt halten** und auf das AltServer-Tray-Symbol klicken → „Sideload .ipa…“ → `SleepSonar.ipa` wählen.
   - **Vom iPhone:** `SleepSonar.ipa` in iCloud Drive/Dateien legen, AltStore → „Meine Apps“ → „+“ → IPA wählen.

## Test

In der App nacheinander tippen:
1. **Health-Zugriff anfragen**: Schlaf schreiben und lesen erlauben.
2. **Testnacht schreiben**: legt eine erfundene Nacht von gestern 23:00 bis heute 07:00 an.
3. **Zurücklesen**: zeigt die Minuten je Phase.

Danach in Health → Schlaf nachsehen. **Löschen** entfernt alle Einträge der App wieder.
