import AlarmKit
import Foundation

/// Zusatzdaten eines Somnivo-Weckers (für die Schlummer-Anzeige im Widget).
@available(iOS 26.0, *)
struct WakeMetadata: AlarmMetadata {
    var label: String
}
