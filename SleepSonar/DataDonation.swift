import SwiftUI

/// Einwilligung zur Datenspende (noch ohne Übertragung). Keine Vorauswahl, jederzeit widerrufbar;
/// Zeitpunkt und Textversion werden gespeichert (Art. 7 Abs. 1 DSGVO).
@MainActor
final class DataDonation: ObservableObject {
    static let shared = DataDonation()
    /// erhöhen, wenn sich der Einwilligungstext inhaltlich ändert → erneut fragen
    static let textVersion = 1

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(tr("Nächte spenden?"))
                    .font(Theme.display(30))
                    .padding(.top, 28)
                Text(tr("Somnivo lernt Schlafphasen aus Geräuschen. Mit gespendeten Nächten kann die Schätzung für alle genauer werden."))
                    .font(.body)

                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(tr("Was übertragen wird"))
                    point("waveform.slash", tr("Lautstärke und Merkmale je Sekunde. Kein Ton, keine Aufnahmen."))
                    point("applewatch", tr("Die Schlafphasen deiner Apple Watch für dieselbe Zeit."))
                    point("person.crop.circle.badge.questionmark", tr("iPhone-Modell, App-Version und eine zufällige Spender-Nummer. Kein Name, keine Apple-ID, kein Datum."))
                }

                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(tr("Welche Nächte"))
                    point("moon.zzz", tr("Nur Nächte mit mindestens 5 Stunden Aufnahme und Schlafphasen der Watch."))
                }

                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(tr("Deine Entscheidung"))
                    point("hand.raised", tr("Freiwillig. Somnivo funktioniert ohne Spende genauso."))
                    point("arrow.uturn.backward", tr("Du kannst jederzeit unter „Mehr“ widerrufen und mit deiner Spender-Nummer die Löschung verlangen."))
                    point("clock", tr("Noch wird nichts gesendet. Die Übertragung kommt mit einem späteren Update."))
                }

                VStack(spacing: 12) {
                    Button(tr("Ja, Nächte spenden")) { donation.grant(); dismiss() }
                        .buttonStyle(MoonButtonStyle(prominent: false))
                    Button(tr("Nein, danke")) { donation.decline(); dismiss() }
                        .buttonStyle(MoonButtonStyle(prominent: false))
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .nightBackground()
        .interactiveDismissDisabled()
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(Theme.mist)
            Text(text).font(.callout)
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
                Button(tr("Spende widerrufen"), role: .destructive) { donation.decline() }
                    .foregroundStyle(Theme.alert)
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
