import SwiftUI

/// Einwilligung zur Datenspende (Übertragung: DonationUploader). Keine Vorauswahl, jederzeit widerrufbar;
/// Zeitpunkt und Textversion werden gespeichert (Art. 7 Abs. 1 DSGVO).
@MainActor
final class DataDonation: ObservableObject {
    static let shared = DataDonation()
    /// erhöhen, wenn sich der Einwilligungstext inhaltlich ändert → erneut fragen
    static let textVersion = 4   // 3: Übertragung an suya.ng-lab.de, 6 Monate, ab 18 · 4: ältere Nächte einzeln

    enum State: String { case undecided, granted, declined }

    private let d = UserDefaults.standard
    @Published private(set) var state: State
    @Published private(set) var date: Date?
    /// zufällige Spender-Nummer (nicht Apple-ID oder Gerät); bleibt für Löschanfragen erhalten
    @Published private(set) var donorID: String?
    /// Löschung der bisher gespendeten Nächte verlangt (wird mit der Übertragung an den Server geschickt)
    @Published private(set) var deletionRequested: Date?
    /// Löschanfrage beim Server angekommen
    @Published private(set) var deletionSent: Bool
    @Published private(set) var uploads: Int
    @Published private(set) var lastUpload: Date?

    private init() {
        let version = d.integer(forKey: "donation.version")
        let s = State(rawValue: d.string(forKey: "donation.state") ?? "") ?? .undecided
        // Zustimmung zu einem älteren Text gilt nicht für einen neuen
        state = (s == .granted && version != Self.textVersion) ? .undecided : s
        date = d.object(forKey: "donation.date") as? Date
        donorID = d.string(forKey: "donation.id")
        deletionRequested = d.object(forKey: "donation.deletion") as? Date
        deletionSent = d.bool(forKey: "donation.deletionSent")
        uploads = d.integer(forKey: "donation.uploads")
        lastUpload = d.object(forKey: "donation.lastUpload") as? Date
    }

    /// geheimer Schlüssel dieser Installation: nur wer ihn hat, kann für die Spender-Nummer hochladen oder löschen
    /// liegt im Schlüsselbund (früher in UserDefaults – wird beim ersten Zugriff umgezogen)
    var secretKey: String {
        if let k = Keychain.get("donation.key") { return k }
        let k = d.string(forKey: "donation.key") ?? (UUID().uuidString + "-" + UUID().uuidString.prefix(8))
        if Keychain.set("donation.key", k) { d.removeObject(forKey: "donation.key") } else { d.set(k, forKey: "donation.key") }
        return k
    }

    func countUpload() {
        uploads += 1; lastUpload = Date()
        d.set(uploads, forKey: "donation.uploads"); d.set(lastUpload, forKey: "donation.lastUpload")
    }

    func markDeletionSent() {
        deletionSent = true
        DonationUploader.forgetSentNights()   // auf dem Server gelöscht → in der App nicht mehr „gespendet am …“
        d.set(true, forKey: "donation.deletionSent")
        uploads = 0; d.set(0, forKey: "donation.uploads")
        AppAttestClient.reset()
        // schon wieder zugestimmt, während die Löschung noch unterwegs war: Hinweis darauf nicht stehen lassen
        if state == .granted {
            deletionRequested = nil; deletionSent = false
            d.removeObject(forKey: "donation.deletion"); d.set(false, forKey: "donation.deletionSent")
        }
    }

    var shouldAsk: Bool { state == .undecided }

    func grant() {
        if donorID == nil {
            donorID = String(UUID().uuidString.prefix(8))
            d.set(donorID, forKey: "donation.id")
        }
        // nach einer erledigten Löschung neu anfangen; eine noch offene Löschung bleibt stehen und geht zuerst raus
        if deletionSent {
            deletionRequested = nil; deletionSent = false
            d.removeObject(forKey: "donation.deletion"); d.set(false, forKey: "donation.deletionSent")
        }
        set(.granted)
        Task { await DonationUploader.shared.run() }
    }

    func decline() { set(.declined) }

    /// Löschung verlangen: widerruft auch die Spende (Art. 17 DSGVO)
    func requestDeletion() {
        deletionRequested = Date()
        deletionSent = false
        d.set(deletionRequested, forKey: "donation.deletion")
        d.set(false, forKey: "donation.deletionSent")
        if state == .granted { decline() }
        Task { await DonationUploader.shared.run() }
    }

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
    /// im Onboarding: statt zu schließen weiter
    var onDone: (() -> Void)?

    init(onDone: (() -> Void)? = nil) { self.onDone = onDone }

    private func done() { if let onDone { onDone() } else { dismiss() } }

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
                    ("applewatch", tr("Die Schlafphasen deiner Apple Watch für dieselbe Zeit und wann Suyas Einschlafklänge liefen – ohne Uhrzeit, nur ab Aufnahmebeginn gezählt.")),
                    ("person.crop.circle.badge.questionmark", tr("iPhone-Modell, App-Version und eine zufällige Spender-Nummer. Kein Name, keine Apple-ID, kein Datum.")),
                ])
                section(tr("Welche Nächte"), color: Theme.color(.rem), points: [
                    ("moon.zzz", tr("Nur Nächte ab deiner Zustimmung, mit mindestens 5 Stunden Aufnahme und Schlafphasen der Watch.")),
                    ("hand.tap", tr("Ältere Nächte kannst du einzeln spenden: Nacht gedrückt halten, solange ihr Klangbild noch auf dem iPhone ist (7 Tage).")),
                ])
                section(tr("Wohin"), color: Theme.color(.deep), points: [
                    ("lock.shield", tr("Verschlüsselt und nur im WLAN an den Suya-Server in Hamburg. Dort nur für das Training, nie weitergegeben, nach 6 Monaten gelöscht.")),
                ])
                section(tr("Deine Entscheidung"), color: Theme.color(.wake), points: [
                    ("hand.raised", tr("Freiwillig. Suya funktioniert ohne Spende genauso.")),
                    ("arrow.uturn.backward", tr("Du kannst jederzeit unter „Mehr“ widerrufen und mit deiner Spender-Nummer die Löschung verlangen.")),
                    ("person.badge.clock", tr("Spenden ist ab 18 Jahren möglich.")),
                ])

                Link(tr("Alle Einzelheiten in der Datenschutzerklärung"), destination: URL(string: tr("https://suya.ng-lab.de/datenschutz#spende"))!)
                    .font(.callout).tint(Theme.color(.core))

                // beide Antworten gleich gewichtet (keine Vorauswahl, kein Hervorheben)
                VStack(spacing: 12) {
                    Button(tr("Ja, Nächte spenden")) { Haptics.select(); donation.grant(); done() }
                        .buttonStyle(MoonButtonStyle(prominent: false))
                    Button(tr("Nein, danke")) { Haptics.select(); donation.decline(); done() }
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
/// Die Zeilen liegen in einer List-Section; Dialog und Rückfrage hängen am Aufrufer (`donationDialogs`),
/// sonst verteilt SwiftUI sie auf jede Zeile und der Dialog schließt sich von selbst wieder.
struct DonationSection: View {
    @ObservedObject private var donation = DataDonation.shared
    @Binding var asking: Bool
    @Binding var confirmDelete: Bool

    var body: some View {
        Group {
            switch donation.state {
            case .granted:
                Text(tr("Du spendest Nächte seit %@.", donation.date?.formatted(date: .abbreviated, time: .omitted) ?? ""))
                    .font(.callout)
                if let last = donation.lastUpload, donation.uploads > 0 {
                    Text(tr("Gespendet: %d Nächte, zuletzt am %@.", donation.uploads, last.formatted(date: .abbreviated, time: .omitted)))
                        .font(.caption).foregroundStyle(Theme.mist)
                }
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
                if let when = donation.deletionRequested {
                    Text(donation.deletionSent
                         ? tr("Löschung am %@ beantragt und vom Server bestätigt.", when.formatted(date: .abbreviated, time: .omitted))
                         : tr("Löschung am %@ beantragt. Sie wird gesendet, sobald das iPhone online ist.", when.formatted(date: .abbreviated, time: .omitted)))
                        .font(.caption).foregroundStyle(Theme.mist)
                } else {
                    Button(tr("Löschung meiner Daten beantragen")) { confirmDelete = true }
                        .foregroundStyle(Theme.alert)
                }
            }
        }
    }
}

extension View {
    /// Einwilligungsdialog und Lösch-Rückfrage zum `DonationSection` – einmal an der Liste, nicht an den Zeilen
    func donationDialogs(asking: Binding<Bool>, confirmDelete: Binding<Bool>) -> some View {
        sheet(isPresented: asking) { DonationConsentView() }
            .alert(tr("Alle gespendeten Nächte löschen lassen?"), isPresented: confirmDelete) {
                Button(tr("Löschung beantragen"), role: .destructive) { Haptics.warning(); DataDonation.shared.requestDeletion() }
                Button(tr("Abbrechen"), role: .cancel) {}
            } message: {
                Text(tr("Die Spende wird damit auch widerrufen."))
            }
    }
}
