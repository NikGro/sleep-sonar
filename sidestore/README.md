# SideStore mit HealthKit

SideStore signiert Apps mit deiner kostenlosen Apple-ID. Dabei lässt es nur
Berechtigungen durch, die auf einer festen Liste stehen. HealthKit fehlt dort,
obwohl Apple es auch für kostenlose Accounts freischaltet. Deshalb verliert
SleepSonar beim Signieren den Health-Zugriff.

`patch_healthkit.py` (von [kenantan32/sidestore-healthkit](https://github.com/kenantan32/sidestore-healthkit))
ergänzt in SideSign, der Signier-Bibliothek von SideStore, sechs Zeilen:

- `com.apple.developer.healthkit` und `…healthkit.access` gelten als erlaubte Berechtigungen.
- Die App-ID-Funktion HealthKit (`HK421J6T7P`) wird beim Registrieren mit eingeschaltet.

Sonst ist es das offizielle SideStore (Branch `develop`).

## Bauen

Actions → **Build SideStore (HealthKit)** → *Run workflow*.
Ergebnis: Artifact `SideStore-HealthKit-ipa`.

## Installieren

Mit iloader am PC: „Import IPA“ → `SideStore.ipa`. Danach in iloader unter
„Manage Pairing File“ für SideStore „Place Pairing File“ ausführen.
In SideStore **Enable Beta Updates aus** lassen, sonst ersetzt ein offizielles
Update die gepatchte Version.
