import SonarDSP
import SwiftUI

/// Gestaltung von Silent Night.
///
/// Idee: Die App wird nachts im Dunkeln geöffnet. Hintergrund ist tiefe blaue Tinte (kein Schwarz),
/// Text und der einzige Akzent sind warmes Mondlicht. Das eine auffällige Element ist die Atemlinie
/// bzw. das Hypnogramm – alles andere bleibt ruhig. Überschriften und Zahlen in New York (Serif).
enum Theme {
    static let ink = Color(red: 0x12 / 255, green: 0x16 / 255, blue: 0x2B / 255)        // Hintergrund
    static let raised = Color(red: 0x1B / 255, green: 0x20 / 255, blue: 0x3D / 255)     // Flächen
    static let hairline = Color(red: 0x2E / 255, green: 0x34 / 255, blue: 0x62 / 255)   // Linien
    static let moon = Color(red: 0xEE / 255, green: 0xE6 / 255, blue: 0xCF / 255)       // Text, Akzent
    static let mist = Color(red: 0x93 / 255, green: 0x98 / 255, blue: 0xBD / 255)       // Nebentext
    static let alert = Color(red: 0xF2 / 255, green: 0x8B / 255, blue: 0x7A / 255)      // Fehler

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
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(Theme.display(20, weight: .medium))
            .foregroundStyle(Theme.moon)
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
                    Text(s.name).font(.caption).foregroundStyle(Theme.mist)
                }
            }
        }
    }
}
