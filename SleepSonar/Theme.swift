import SonarDSP
import SwiftUI

/// Gestaltung von Suya – ein Konzept für alle Bildschirme.
///
/// Die App wird nachts im Dunkeln geöffnet: Hintergrund ist tiefe blaue Tinte (kein Schwarz).
/// Jede Farbe hat genau eine Aufgabe:
/// - **ink / raised / hairline** – Flächen: Hintergrund, gruppierte Einstellungen, Linien und Inaktives
/// - **moon** – Text, Zahlen, Hauptknöpfe, Navigation (Tab-Leiste, Zurück, Abbrechen/Sichern)
/// - **mist** – Nebentext, Erklärungen, Symbole vor Text
/// - **accent** (Violett) – Abschnittsüberschriften und Zustand: Schalter an, Auswahl, Häkchen, Regler
/// - **alert** – Fehler und Löschen
/// - **Phasenfarben** (`color(_:)`) – nur für Schlafdaten: Hypnogramm, Phasen, Schlafwert-Teile.
///   Einzige Ausnahme: die drei Abschnitte im Einwilligungsdialog zur Datenspende.
/// Schrift: Überschriften und große Zahlen in New York (Serif), alles andere SF.
/// Das eine auffällige Element je Bildschirm: Atemlinie, Mond/Schlafwert oder Hypnogramm.
enum Theme {
    static let ink = Color(red: 0x12 / 255, green: 0x16 / 255, blue: 0x2B / 255)        // Hintergrund
    static let raised = Color(red: 0x1B / 255, green: 0x20 / 255, blue: 0x3D / 255)     // Flächen
    static let hairline = Color(red: 0x2E / 255, green: 0x34 / 255, blue: 0x62 / 255)   // Linien
    static let moon = Color(red: 0xEE / 255, green: 0xE6 / 255, blue: 0xCF / 255)       // Text
    static let mist = Color(red: 0x93 / 255, green: 0x98 / 255, blue: 0xBD / 255)       // Nebentext
    static let alert = Color(red: 0xF2 / 255, green: 0x8B / 255, blue: 0x7A / 255)      // Fehler, Löschen
    /// Überschriften und Zustand (an, ausgewählt)
    static var accent: Color { color(.rem) }

    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static func color(_ stage: SleepStaging.Stage) -> Color {
        switch stage {
        case .wake: Color(red: 0xF0 / 255, green: 0xB3 / 255, blue: 0x5B / 255)   // Nachttischlampe
        case .rem: Color(red: 0xC5 / 255, green: 0x9B / 255, blue: 0xFF / 255)    // Traum-Lila
        case .core: Color(red: 0x6F / 255, green: 0x9B / 255, blue: 0xEA / 255)   // Blau
        case .deep: Color(red: 0x4C / 255, green: 0x5F / 255, blue: 0xD6 / 255)   // tiefes Indigo
        }
    }
}

/// Ruhige Abschnittsüberschrift: Serif, normale Schreibweise, kein Großbuchstaben-Etikett.
struct SectionTitle: View {
    let text: String
    var color: Color = Theme.accent
    init(_ text: String, color: Color = Theme.accent) { self.text = text; self.color = color }
    var body: some View {
        Text(text)
            .font(Theme.display(20, weight: .medium))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Hintergrund für alle Bildschirme.
struct NightBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Theme.ink.ignoresSafeArea())
            .foregroundStyle(Theme.moon)
            .tint(Theme.moon)
    }
}

extension View {
    func nightBackground() -> some View { modifier(NightBackground()) }
}

/// Knopf in Mondlicht (Hauptaktion) bzw. als Umriss (Nebenaktion).
struct MoonButtonStyle: ButtonStyle {
    var prominent = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .foregroundStyle(prominent ? Theme.ink : Theme.moon)
            .background {
                if prominent {
                    Capsule().fill(Theme.moon)
                } else {
                    Capsule().strokeBorder(Theme.hairline, lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Kleine Legende für die Phasenfarben.
struct StageLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            ForEach([SleepStaging.Stage.wake, .rem, .core, .deep], id: \.self) { s in
                HStack(spacing: 5) {
                    Circle().fill(Theme.color(s)).frame(width: 8, height: 8)
                    Text(s.displayName).font(.caption).foregroundStyle(Theme.mist)
                }
            }
        }
    }
}

extension SleepStaging.Stage {
    /// Name in der Sprache des Systems
    var displayName: String { tr(name) }
}

/// Überschrift über einer gruppierten Liste (Mehr, Einstellungen): wie SectionTitle, etwas kleiner.
struct ListHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Theme.display(17, weight: .medium)).foregroundStyle(Theme.accent).textCase(nil)
    }
}

extension View {
    /// Kopfleiste: ab iOS 26 blendet der Inhalt beim Scrollen weich unter dem Titel aus (Verlauf statt
    /// harter Kante); davor eine deckende Leiste in Nachttinte.
    @ViewBuilder func suyaTopEdge() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self.toolbarBackground(Theme.ink, for: .navigationBar)
        }
    }
}

extension ToolbarContent {
    /// Ab iOS 26 legt das System Knöpfe in der Kopfleiste auf Glas; Suya zeichnet sie selbst.
    @ToolbarContentBuilder func suyaPlain() -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

/// Runder Knopf für die Kopfleiste (z. B. „+“): Violett gefüllt, Symbol in Nachttinte.
struct SuyaRoundButton: View {
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.accent))
        }
        .buttonStyle(.plain)
    }
}

/// Text-Knopf für die Kopfleiste: Bestätigen in Mondweiß fett, Abbrechen in Nebelgrau.
struct SuyaBarButton: View {
    let title: String
    var confirm = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(confirm ? .semibold : .regular))
                .foregroundStyle(confirm ? Theme.ink : Theme.mist)
                .padding(.horizontal, confirm ? 14 : 4)
                .padding(.vertical, 6)
                .background { if confirm { Capsule().fill(Theme.moon) } }
        }
        .buttonStyle(.plain)
    }
}

/// Umschalter im Suya-Stil statt des Glas-Segmentreglers: Kapsel in Flächenfarbe, Auswahl in Violett.
struct SuyaSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.0) { value, label in
                let on = value == selection
                Text(label)
                    .font(.callout.weight(on ? .semibold : .regular))
                    .foregroundStyle(on ? Theme.ink : Theme.moon)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        if on { Capsule().fill(Theme.accent).matchedGeometryEffect(id: "sel", in: ns) }
                    }
                    .contentShape(Capsule())
                    .onTapGesture {
                        guard !on else { return }
                        withAnimation(.spring(duration: 0.25)) { selection = value }
                    }
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(4)
        .background(Capsule().fill(Theme.raised))
    }
}
