import ActivityKit
import AppIntents
import Foundation

/// Live-Aktivität während der Nachtaufnahme (Dynamic Island, Sperrbildschirm, StandBy).
struct NightActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// iPhone wird gerade bewegt
        var handled: Bool
        /// eingestellte Schlafklänge (nil = keine gewählt)
        var sounds: String? = nil
        /// Klänge laufen gerade
        var playing: Bool = false
        /// Ausblenden läuft von … bis …
        var fadeStart: Date? = nil
        var fadeEnd: Date? = nil
        /// Wecker klingelt gerade (Titel)
        var alarm: String? = nil
        var canSnooze: Bool = false
        /// geschlummert bis
        var snoozeUntil: Date? = nil
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

/// Knopf „Abspielen“ für die Schlafklänge in der Live-Aktivität.
struct PlaySoundsIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Klänge abspielen"
    static var openAppWhenRun: Bool = false
    func perform() async throws -> some IntentResult {
        await PlaySoundsAction.run?()
        return .result()
    }
}

enum PlaySoundsAction {
    nonisolated(unsafe) static var run: (@Sendable () async -> Void)?
}

/// Knopf „Sofort aus“ während des Ausblendens.
struct StopSoundsIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Klänge sofort aus"
    static var openAppWhenRun: Bool = false
    func perform() async throws -> some IntentResult {
        await StopSoundsAction.run?()
        return .result()
    }
}

enum StopSoundsAction {
    nonisolated(unsafe) static var run: (@Sendable () async -> Void)?
}

/// Wecker „Aus“ in der Live-Aktivität (Suya klingelt während der Aufnahme selbst).
struct StopAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Wecker aus"
    static var openAppWhenRun: Bool = false
    func perform() async throws -> some IntentResult {
        await StopAlarmAction.run?()
        return .result()
    }
}

enum StopAlarmAction {
    nonisolated(unsafe) static var run: (@Sendable () async -> Void)?
}

/// Wecker „Schlummern“ in der Live-Aktivität.
struct SnoozeAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Schlummern"
    static var openAppWhenRun: Bool = false
    func perform() async throws -> some IntentResult {
        await SnoozeAlarmAction.run?()
        return .result()
    }
}

enum SnoozeAlarmAction {
    nonisolated(unsafe) static var run: (@Sendable () async -> Void)?
}
