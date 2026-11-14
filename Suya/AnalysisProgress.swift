import Foundation

/// Wie weit das Modell eine Nacht gerade gerechnet hat (0 … 1), für Nächte-Liste und Detailansicht –
/// unabhängig davon, wer die Rechnung angestoßen hat (Liste, Health-Abgleich, Hintergrund, Detailansicht).
@MainActor
final class AnalysisProgress: ObservableObject {
    static let shared = AnalysisProgress()
    @Published private(set) var values: [String: Double] = [:]

    func value(_ folder: URL) -> Double? { values[folder.lastPathComponent] }

    /// Nacht wartet auf die Rechnung (0 %), ohne einen schon laufenden Fortschritt zurückzusetzen
    nonisolated static func start(_ folder: URL) {
        let key = folder.lastPathComponent
        Task { @MainActor in if AnalysisProgress.shared.values[key] == nil { AnalysisProgress.shared.values[key] = 0 } }
    }

    /// aus jedem Thread; Schritte unter einem Prozent werden nicht weitergereicht, 1 = fertig (Eintrag weg)
    nonisolated static func report(_ folder: URL, _ p: Double) {
        let key = folder.lastPathComponent
        Task { @MainActor in
            let s = AnalysisProgress.shared
            if p >= 1 { s.values[key] = nil; return }
            if let old = s.values[key], abs(old - p) < 0.01 { return }
            s.values[key] = p
        }
    }
}
