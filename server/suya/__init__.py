"""Suya-Server: Datenschutz-/Impressum-Seiten und die Schnittstelle für gespendete Nächte und Fehlerberichte.

Module:
  config     Einstellungen (Umgebungsvariablen, Grenzen)
  storage    Ablage auf der Platte: Spender, Schlüssel, Protokoll, Aufräumen
  limits     Mengenbegrenzung je Adresse, Spender und Tag (nur im Arbeitsspeicher)
  attest     Challenges und Prüfung der App-Attest-Assertions
  appattest  Apples App-Attest-Format (Attestation, Assertion, Zertifikatskette)
  api        HTTP-Anfragen: Seiten, Spende, Löschen, Fehlerbericht
"""
