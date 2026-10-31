import AppIntents

/// Kurzbefehle: Nachtaufnahme starten / beenden (Kurzbefehle-App, Siri, Automationen).
struct StartNightRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Schlafaufnahme starten"
    static var description = IntentDescription("Startet die Nachtaufnahme von Silent Night (nur Mikrofon).")
    /// iOS erlaubt den Start einer Mikrofonaufnahme nur aus dem Vordergrund.
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let rec = PassiveNightEngine.shared
        if rec.isRunning {
            return .result(dialog: "Die Nachtaufnahme läuft bereits.")
        }
        await rec.start()
        if let error = rec.errorMessage {
            return .result(dialog: IntentDialog(stringLiteral: "Start fehlgeschlagen: \(error)"))
        }
        return .result(dialog: "Nachtaufnahme gestartet. Gute Nacht!")
    }
}

struct StopNightRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Schlafaufnahme beenden"
    static var description = IntentDescription("Beendet die laufende Nachtaufnahme von Silent Night.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let rec = PassiveNightEngine.shared
        guard rec.isRunning else {
            return .result(dialog: "Es läuft gerade keine Nachtaufnahme.")
        }
        let duration = rec.startDate.map { NightView.duration(Date().timeIntervalSince($0)) } ?? ""
        rec.stop()
        return .result(dialog: IntentDialog(stringLiteral: "Nachtaufnahme beendet (\(duration))."))
    }
}

struct SleepSonarShortcuts: AppShortcutsProvider {
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
