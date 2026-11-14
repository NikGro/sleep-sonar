import AppIntents

/// Kurzbefehle: Nachtaufnahme starten / beenden (Kurzbefehle-App, Siri, Automationen).
/// Öffnet die App zum Starten (iOS erlaubt den Mikrofonstart sonst nur mit einer Rückfrage bei jedem
/// Ausführen – die Hintergrund-Variante als `AudioRecordingIntent` hat in Automationen jedes Mal
/// „Erlauben / Abbrechen“ gezeigt).
struct StartNightRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Schlafaufnahme starten"
    static let description = IntentDescription("Startet die Nachtaufnahme von Suya (nur Mikrofon).")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let rec = PassiveNightEngine.shared
        if rec.isRunning {
            return .result(dialog: IntentDialog(stringLiteral: tr("Die Nachtaufnahme läuft bereits.")))
        }
        await rec.start()
        if let error = rec.errorMessage {
            return .result(dialog: IntentDialog(stringLiteral: tr("Start fehlgeschlagen: %@", error)))
        }
        return .result(dialog: IntentDialog(stringLiteral: tr("Nachtaufnahme gestartet. Gute Nacht!")))
    }
}

struct StopNightRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Schlafaufnahme beenden"
    static let description = IntentDescription("Beendet die laufende Nachtaufnahme von Suya.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let rec = PassiveNightEngine.shared
        guard rec.isRunning else {
            return .result(dialog: IntentDialog(stringLiteral: tr("Es läuft gerade keine Nachtaufnahme.")))
        }
        let duration = rec.startDate.map { NightView.duration(Date().timeIntervalSince($0)) } ?? ""
        rec.stop()
        return .result(dialog: IntentDialog(stringLiteral: tr("Nachtaufnahme beendet (%@).", duration)))
    }
}

struct SuyaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartNightRecordingIntent(),
                    phrases: ["Starte Schlafaufnahme in \(.applicationName)",
                              "\(.applicationName) Nacht starten"],
                    shortTitle: "Aufnahme starten",
                    systemImageName: "moon.stars.fill")
        AppShortcut(intent: StopNightRecordingIntent(),
                    phrases: ["Beende Schlafaufnahme in \(.applicationName)",
                              "\(.applicationName) Nacht beenden"],
                    shortTitle: "Aufnahme beenden",
                    systemImageName: "stop.circle.fill")
    }
}
