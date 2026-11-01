import Foundation

/// Übersetzung: Schlüssel ist der deutsche Text, die englische Fassung steht in
/// en.lproj/Localizable.strings. Fehlt ein Eintrag, bleibt der deutsche Text stehen
/// (CI prüft mit scripts/check_strings.py, dass jeder Schlüssel übersetzt ist).
func tr(_ de: String) -> String {
    Bundle.main.localizedString(forKey: de, value: de, table: nil)
}

/// Übersetzung mit Platzhaltern (%@, %d …) wie bei String(format:).
func tr(_ de: String, _ args: CVarArg...) -> String {
    String(format: tr(de), locale: Locale.current, arguments: args)
}
