import AVFoundation
import SwiftUI

/// Erster Start: kurz erklären und alle Berechtigungen nacheinander erfragen, am Ende die Datenspende.
/// Jeder Schritt lässt sich überspringen; alles ist später unter „Mehr“ bzw. in den iOS-Einstellungen änderbar.
struct OnboardingView: View {
    static let doneKey = "onboarding.done"
    let finish: () -> Void

    private enum Step: Int, CaseIterable { case welcome, microphone, health, alarm, donation }
    @State private var step: Step = .welcome
    @State private var busy = false

    var body: some View {
        Group {
            if step == .donation {
                DonationConsentView { finish() }
            } else {
                page
            }
        }
        .animation(.easeInOut(duration: 0.25), value: step)
        .interactiveDismissDisabled()
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            progress.padding(.top, 20)
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 18) {
                icon
                Text(title).font(Theme.display(34)).foregroundStyle(Theme.accent)
                Text(text).font(.body).foregroundStyle(Theme.moon)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(Theme.mist)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 24)
            VStack(spacing: 12) {
                Button(primary) { Haptics.select(); Task { await advance(ask: true) } }
                    .buttonStyle(MoonButtonStyle())
                    .disabled(busy)
                if step != .welcome {
                    Button(tr("Später")) { Haptics.select(); Task { await advance(ask: false) } }
                        .buttonStyle(MoonButtonStyle(prominent: false))
                        .disabled(busy)
                }
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .nightBackground()
    }

    /// Punkte oben: wie weit man ist
    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? Theme.accent : Theme.hairline)
                    .frame(width: s == step ? 22 : 8, height: 8)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var icon: some View {
        switch step {
        case .welcome:
            MoonDisc(lit: true).frame(width: 72, height: 72)
        default:
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 72, height: 72)
                .background(Circle().fill(Theme.accent.opacity(0.16)))
        }
    }

    private var symbol: String {
        switch step {
        case .microphone: "mic"
        case .health: "heart.text.square"
        case .alarm: "alarm"
        default: ""
        }
    }

    private var title: String {
        switch step {
        case .welcome: tr("Willkommen bei Suya")
        case .microphone: tr("Mikrofon")
        case .health: tr("Apple Health")
        case .alarm: tr("Wecker")
        case .donation: ""
        }
    }

    private var text: String {
        switch step {
        case .welcome:
            tr("Suya hört nachts deinem Atem und deinen Bewegungen zu und schätzt daraus deine Schlafphasen – ganz ohne Uhr am Handgelenk.")
        case .microphone:
            tr("Für die Nachtaufnahme braucht Suya das Mikrofon. Die Aufnahmen bleiben auf deinem iPhone, bis du sie selbst teilst.")
        case .health:
            tr("Suya trägt deine Nächte in Apple Health ein. Hast du eine Apple Watch, liest Suya ihre Schlafphasen zum Vergleich – die Watch hat dann Vorrang.")
        case .alarm:
            tr("Damit dich Suya wecken kann – auch im leichten Schlaf kurz vor der Weckzeit –, braucht es die Erlaubnis für Wecker.")
        case .donation: ""
        }
    }

    private var detail: String? {
        switch step {
        case .welcome: tr("Gleich fragt Suya nach den nötigen Erlaubnissen. Jede kannst du überspringen und später in den Einstellungen ändern.")
        case .microphone: tr("Ohne Mikrofon kann Suya keine Nacht aufnehmen.")
        default: nil
        }
    }

    private var primary: String {
        switch step {
        case .welcome: tr("Los geht's")
        case .microphone: tr("Mikrofon erlauben")
        case .health: tr("Health verbinden")
        case .alarm: tr("Wecker erlauben")
        case .donation: ""
        }
    }

    private func advance(ask: Bool) async {
        busy = true
        defer { busy = false }
        if ask {
            switch step {
            case .microphone: _ = await AVAudioApplication.requestRecordPermission()
            case .health: try? await NightExport.requestAuthorization()
            case .alarm: if #available(iOS 26.0, *) { _ = await AlarmBackend.authorize() }
            default: break
            }
        }
        var next = Step(rawValue: step.rawValue + 1) ?? .donation
        if next == .alarm, !SmartAlarm.isAvailable { next = .donation }
        // schon entschieden (z. B. bei einer neueren App-Version): Datenspende nicht noch einmal fragen
        if next == .donation, !DataDonation.shared.shouldAsk { finish(); return }
        step = next
    }
}
