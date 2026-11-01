import ActivityKit
import Foundation

/// Live-Aktivität während der Nachtaufnahme (Dynamic Island, Sperrbildschirm, StandBy).
struct NightActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// iPhone wird gerade bewegt
        var handled: Bool
    }
    var start: Date
}
