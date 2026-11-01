import AppIntents

/// Kurzbefehle: Nachtaufnahme starten / beenden (Kurzbefehle-App, Siri, Automationen).
/// `AudioRecordingIntent`: iOS erlaubt damit den Aufnahmestart im Hintergrund (ohne Entsperren),
/// solange gleichzeitig eine Live-Aktivität läuft – die startet die Aufnahme selbst.
struct StartNightRecordingIntent: AudioRecordingIntent {
    static var title: LocalizedStringResource = "Schlafaufnahme starten"
    static var description = IntentDescription("Startet die Nachtaufnahme von Suya (nur Mikrofon).")
    static var openAppWhenRun: Bool = false

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
    static var title: LocalizedStringResource = "Schlafaufnahme beenden"
    static var description = IntentDescription("Beendet die laufende Nachtaufnahme von Suya.")
    static var openAppWhenRun: Bool = false

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
