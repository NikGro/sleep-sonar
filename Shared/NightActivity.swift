import ActivityKit
import AppIntents
import Foundation
import Synchronization

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
    }
    var start: Date
}

/// Knopf „Ausblenden“ in der Live-Aktivität. Läuft in der App (dort ist `FadeSoundsAction.run` gesetzt).
struct FadeSoundsIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Klänge ausblenden"
    static let openAppWhenRun: Bool = false
    func perform() async throws -> some IntentResult {
        await FadeSoundsAction.run()
        return .result()
    }
}

enum FadeSoundsAction {
    static let run = IntentAction()
}

/// Knopf „Abspielen“ für die Schlafklänge in der Live-Aktivität.
struct PlaySoundsIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Klänge abspielen"
    static let openAppWhenRun: Bool = false
    func perform() async throws -> some IntentResult {
        await PlaySoundsAction.run()
        return .result()
    }
}

enum PlaySoundsAction {
    static let run = IntentAction()
}

/// Knopf „Sofort aus“ während des Ausblendens.
struct StopSoundsIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Klänge sofort aus"
    static let openAppWhenRun: Bool = false
    func perform() async throws -> some IntentResult {
        await StopSoundsAction.run()
        return .result()
    }
}

enum StopSoundsAction {
    static let run = IntentAction()
}

/// Was ein Knopf der Live-Aktivität in der App auslöst. Die App setzt es beim Start (`set`), der Knopf ruft es
/// auf – geschützt durch einen Mutex, weil beides aus verschiedenen Threads kommen kann.
final class IntentAction: Sendable {
    private let handler = Mutex<(@Sendable () async -> Void)?>(nil)

    func set(_ action: @escaping @Sendable () async -> Void) {
        handler.withLock { $0 = action }
    }

    func callAsFunction() async {
        let action = handler.withLock { $0 }
        await action?()
    }
}
