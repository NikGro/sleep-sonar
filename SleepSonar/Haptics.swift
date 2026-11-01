import UIKit

/// Dezentes haptisches Feedback, nur bei Aktionen der Person (nie von selbst).
@MainActor
enum Haptics {
    /// Knopf mit Wirkung (Start, Stopp, Abspielen)
    static func tap() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    /// Auswahl ändern (Schalter, Klang an/aus, Wochentag, Ton)
    static func select() { UISelectionFeedbackGenerator().selectionChanged() }
    /// Etwas wurde gesichert oder gestartet
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    /// Etwas wurde gelöscht oder beendet
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}
