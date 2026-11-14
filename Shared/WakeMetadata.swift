import AlarmKit
import AppIntents
import Foundation

/// Zusatzdaten eines Suya-Weckers (für die Schlummer-Anzeige im Widget).
@available(iOS 26.0, *)
struct WakeMetadata: AlarmMetadata {
    var label: String
}

/// „Schlummern beenden“ in der Schlummer-Anzeige: stoppt den Countdown, der Wecker klingelt
/// dann nicht noch einmal (wiederholte Wecker bleiben für die nächsten Tage gestellt).
@available(iOS 26.0, *)
struct StopSnoozeIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Schlummern beenden"
    static let openAppWhenRun: Bool = false
    @Parameter(title: "Wecker") var alarmID: String

    init() {}
    init(alarmID: UUID) { self.alarmID = alarmID.uuidString }

    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: alarmID) { try? AlarmManager.shared.stop(id: id) }
        return .result()
    }
}
