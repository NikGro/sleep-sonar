import Foundation
import OSLog

/// Protokoll für Fehler, die den Zustand verändern (Speichern gescheitert, Schlüsselbund, Wecker, Spende).
/// Erscheint in der Konsole und – auf Wunsch – im Fehlerbericht (`Log.recent`). Keine Inhalte der Nacht,
/// keine Spender-Nummern oder Schlüssel.
enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "de.nikgro.sleepsonar"
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let alarm = Logger(subsystem: subsystem, category: "alarm")
    static let donation = Logger(subsystem: subsystem, category: "donation")
    static let recording = Logger(subsystem: subsystem, category: "recording")
    static let analysis = Logger(subsystem: subsystem, category: "analysis")
    static let keychain = Logger(subsystem: subsystem, category: "keychain")

    /// Meldungen dieses App-Laufs ab Stufe „Fehler“ und „Hinweis“ (iOS liefert nur den laufenden Prozess),
    /// neueste zuletzt, höchstens `limit` Zeilen
    static func recent(limit: Int = 200) -> String {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return "" }
        let since = store.position(timeIntervalSinceLatestBoot: max(0, ProcessInfo.processInfo.systemUptime - 24 * 3600))
        guard let entries = try? store.getEntries(at: since, matching: NSPredicate(format: "subsystem == %@", subsystem))
        else { return "" }
        let lines = entries.compactMap { $0 as? OSLogEntryLog }
            .filter { $0.level == .error || $0.level == .fault || $0.level == .notice }
            .map { "\(Night.timestamp($0.date)) [\($0.category)] \($0.composedMessage)" }
        return lines.suffix(limit).joined(separator: "\n")
    }
}

extension Data {
    /// Schreiben, und ein Scheitern protokollieren statt es zu verschlucken
    @discardableResult
    func save(to url: URL, _ what: StaticString = "Datei") -> Bool {
        do {
            try write(to: url, options: .atomic)
            return true
        } catch {
            Log.storage.error("\(what, privacy: .public) \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
