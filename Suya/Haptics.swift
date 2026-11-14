import UIKit

/// Dezentes haptisches Feedback, nur bei Aktionen der Person (nie von selbst).
@MainActor
enum Haptics {
    /// Knopf mit Wirkung (Start, Stopp, Abspielen)
    static func tap() { impact.impactOccurred(); impact.prepare() }
    /// Auswahl ändern (Schalter, Klang an/aus, Wochentag, Ton)
    static func select() { selection.selectionChanged(); selection.prepare() }

    // vorbereitet halten, damit das Feedback ohne Anlaufzeit kommt
    private static let impact: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .medium); g.prepare(); return g
    }()
    private static let selection: UISelectionFeedbackGenerator = {
        let g = UISelectionFeedbackGenerator(); g.prepare(); return g
    }()
    /// Etwas wurde gesichert oder gestartet
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    /// Etwas wurde gelöscht oder beendet
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}
