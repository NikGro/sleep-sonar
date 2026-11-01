import SwiftUI

/// Einwilligung zur Datenspende (noch ohne Übertragung). Keine Vorauswahl, jederzeit widerrufbar;
/// Zeitpunkt und Textversion werden gespeichert (Art. 7 Abs. 1 DSGVO).
@MainActor
final class DataDonation: ObservableObject {
    static let shared = DataDonation()
    /// erhöhen, wenn sich der Einwilligungstext inhaltlich ändert → erneut fragen
    static let textVersion = 2

    enum State: String { case undecided, granted, declined }

    private let d = UserDefaults.standard
    @Published private(set) var state: State
    @Published private(set) var date: Date?
    /// zufällige Spender-Nummer (nicht Apple-ID oder Gerät); bleibt für Löschanfragen erhalten
    @Published private(set) var donorID: String?

    private init() {
        let version = d.integer(forKey: "donation.version")
        let s = State(rawValue: d.string(forKey: "donation.state") ?? "") ?? .undecided
        // Zustimmung zu einem älteren Text gilt nicht für einen neuen
        state = (s == .granted && version != Self.textVersion) ? .undecided : s
        date = d.object(forKey: "donation.date") as? Date
        donorID = d.string(forKey: "donation.id")
    }

    var shouldAsk: Bool { state == .undecided }

    func grant() {
        if donorID == nil {
            donorID = String(UUID().uuidString.prefix(8))
            d.set(donorID, forKey: "donation.id")
        }
        set(.granted)
    }

    func decline() { set(.declined) }

    private func set(_ s: State) {
        state = s
        date = Date()
        d.set(s.rawValue, forKey: "donation.state")
        d.set(date, forKey: "donation.date")
        d.set(Self.textVersion, forKey: "donation.version")
    }
}

/// Dialog: was gespendet wird, wozu, wie man widerruft. Zwei gleichwertige Knöpfe.
struct DonationConsentView: View {
    @ObservedObject private var donation = DataDonation.shared
    @Environment(\.dismiss) private var dismiss

    /// Überschriften in REM-Violett, Text in Mondweiß; Symbole je Abschnitt in einer Phasenfarbe
    private let heading = Theme.accent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 14) {
                    MoonDisc(lit: true)
                        .frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                    Text(tr("Nächte spenden?"))
                        .font(Theme.display(32))
                        .foregroundStyle(heading)
                    Text(tr("Suya lernt Schlafphasen aus Geräuschen. Mit gespendeten Nächten wird ein Modell trainiert, das die Schätzung für alle genauer machen soll."))
                        .font(.body)
                }
                .padding(.top, 28)

                section(tr("Was übertragen wird"), color: Theme.color(.core), points: [
                    ("waveform.slash", tr("Ein grobes Klangbild der Nacht (Spektrogramm, 10-mal pro Sekunde) und die Lautstärke je Sekunde. Daraus lässt sich Atem, Schnarchen und Bewegung erkennen, aber keine Sprache verstehen. Kein Ton, keine Aufnahmen.")),
                    ("applewatch", tr("Die Schlafphasen deiner Apple Watch für dieselbe Zeit.")),
                    ("person.crop.circle.badge.questionmark", tr("iPhone-Modell, App-Version und eine zufällige Spender-Nummer. Kein Name, keine Apple-ID, kein Datum.")),
                ])
                section(tr("Welche Nächte"), color: Theme.color(.rem), points: [
                    ("moon.zzz", tr("Nur Nächte mit mindestens 5 Stunden Aufnahme und Schlafphasen der Watch.")),
                ])
                section(tr("Deine Entscheidung"), color: Theme.color(.wake), points: [
                    ("hand.raised", tr("Freiwillig. Suya funktioniert ohne Spende genauso.")),
                    ("arrow.uturn.backward", tr("Du kannst jederzeit unter „Mehr“ widerrufen und mit deiner Spender-Nummer die Löschung verlangen.")),
                    ("clock", tr("Noch wird nichts gesendet. Die Übertragung kommt mit einem späteren Update.")),
                ])

                // beide Antworten gleich gewichtet (keine Vorauswahl, kein Hervorheben)
                VStack(spacing: 12) {
                    Button(tr("Ja, Nächte spenden")) { donation.grant(); dismiss() }
                        .buttonStyle(MoonButtonStyle(prominent: false))
                    Button(tr("Nein, danke")) { donation.decline(); dismiss() }
                        .buttonStyle(MoonButtonStyle(prominent: false))
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .nightBackground()
        .interactiveDismissDisabled()
    }

    private func section(_ title: String, color: Color, points: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title, color: heading)
            ForEach(points, id: \.1) { symbol, text in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(color)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(color.opacity(0.16)))
                    Text(text).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 7)
                }
            }
        }
    }
}

/// Abschnitt unter „Mehr“: Stand der Einwilligung, widerrufen oder nachträglich zustimmen.
struct DonationSection: View {
    @ObservedObject private var donation = DataDonation.shared
    @State private var asking = false

    var body: some View {
        Group {
            switch donation.state {
            case .granted:
                Text(tr("Du spendest Nächte seit %@.", donation.date?.formatted(date: .abbreviated, time: .omitted) ?? ""))
                    .font(.callout)
                // Widerrufen so leicht und gleich gestaltet wie Zustimmen
                Button(tr("Spende widerrufen")) { donation.decline() }
                    .foregroundStyle(Theme.moon)
            case .declined, .undecided:
                Text(tr("Du spendest keine Nächte.")).font(.callout)
                Button(tr("Nächte spenden …")) { asking = true }
                    .foregroundStyle(Theme.moon)
            }
            if let id = donation.donorID {
                LabeledContent(tr("Spender-Nummer"), value: id)
                    .font(.callout)
            }
        }
        .sheet(isPresented: $asking) { DonationConsentView() }
    }
}
