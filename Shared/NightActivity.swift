import ActivityKit
import AppIntents
import Foundation

/// Live-Aktivität während der Nachtaufnahme (Dynamic Island, Sperrbildschirm, StandBy).
struct NightActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// iPhone wird gerade bewegt
        var handled: Bool
        /// laufende Schlafklänge (nil = keine)
        var sounds: String? = nil
        /// Ausblenden läuft von … bis …
        var fadeStart: Date? = nil
        var fadeEnd: Date? = nil
    }
    var start: Date
}

/// Knopf „Ausblenden“ in der Live-Aktivität. Läuft in der App (dort ist `FadeSoundsAction.run` gesetzt).
struct FadeSoundsIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Klänge ausblenden"
    static var openAppWhenRun: Bool = false
    func perform() async throws -> some IntentResult {
        await FadeSoundsAction.run?()
        return .result()
    }
}

enum FadeSoundsAction {
    nonisolated(unsafe) static var run: (@Sendable () async -> Void)?
}
