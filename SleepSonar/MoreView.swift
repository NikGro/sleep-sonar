import AlarmKit
import AVFoundation
import HealthKit
import SwiftUI

/// Einstellungen und Hilfe: übersprungene Erlaubnisse, Datenspende, Hinweise, Rechtliches.
struct MoreView: View {
    enum Permission: Hashable { case microphone, health, alarm }
    @State private var pending: [Permission] = []
    @State private var askingDonation = false
    @State private var confirmDonationDelete = false
    @State private var reportingBug = false

    /// noch nicht gefragte Erlaubnisse (abgelehnte lassen sich nur in den iOS-Einstellungen ändern)
    private func refresh() {
        var p: [Permission] = []
        if AVAudioApplication.shared.recordPermission == .undetermined { p.append(.microphone) }
        if HKHealthStore.isHealthDataAvailable(),
           HKHealthStore().authorizationStatus(for: HKCategoryType(.sleepAnalysis)) == .notDetermined { p.append(.health) }
        if #available(iOS 26.0, *), AlarmManager.shared.authorizationState == .notDetermined { p.append(.alarm) }
        pending = p
    }

    private func ask(_ p: Permission) async {
        switch p {
        case .microphone: _ = await AVAudioApplication.requestRecordPermission()
        case .health: try? await NightExport.requestAuthorization()
        case .alarm: if #available(iOS 26.0, *) { _ = await AlarmBackend.authorize() }
        }
        refresh()
    }

    var body: some View {
        NavigationStack {
            List {
                // Knöpfe nur für Erlaubnisse, die im Onboarding übersprungen wurden (noch nicht gefragt)
                if !pending.isEmpty {
                    Section {
                        ForEach(pending, id: \.self) { p in
                            Button { Task { await ask(p) } } label: {
                                switch p {
                                case .microphone: Label(tr("Mikrofon erlauben"), systemImage: "mic")
                                case .health: Label(tr("Health-Zugriff erlauben"), systemImage: "heart.text.square")
                                case .alarm: Label(tr("Wecker erlauben"), systemImage: "alarm")
                                }
                            }
                        }
                    } header: {
                        ListHeader(tr("Erlaubnisse"))
                    } footer: {
                        Text(tr("Diese Erlaubnisse hast du beim Start übersprungen."))
                            .foregroundStyle(Theme.mist)
                    }
                    .listRowBackground(Theme.raised)
                }

                Section {
                    DonationSection(asking: $askingDonation, confirmDelete: $confirmDonationDelete)
                } header: {
                    ListHeader(tr("Datenspende"))
                } footer: {
                    Text(tr("Hilft, die Schätzung für alle genauer zu machen. Kein Ton, nur ein grobes Klangbild, aus dem sich keine Sprache verstehen lässt."))
                        .foregroundStyle(Theme.mist)
                }
                .listRowBackground(Theme.raised)

                Section {
                    tip("moon.zzz", tr("„Schlafaufnahme starten“ und „Schlafaufnahme beenden“ gibt es in der Kurzbefehle-App, zum Beispiel als Automation beim Schlaf-Fokus."))
                    tip("bolt", tr("Über Nacht ans Ladekabel. Die Aufnahme braucht etwa so viel Strom wie Musik hören."))
                    tip("iphone.gen3", tr("Unterseite mit dem Mikrofon zu dir, etwa eine Armlänge entfernt."))
                    tip("hand.raised", tr("Suya sendet keinen Ton aus und stört andere Apps nicht."))
                    tip("heart.text.square", tr("Suya trägt jede Nacht in Health ein und liest die Schlafphasen deiner Apple Watch zum Vergleich. Hat die Watch eine Nacht eingetragen, hat sie Vorrang."))
                } header: {
                    ListHeader(tr("Tipps"))
                }
                .listRowBackground(Theme.raised)

                Section {
                    Text(tr("Die Schlafphasen sind eine Schätzung aus Geräuschen und keine medizinische Messung. Bei Verdacht auf Schlafstörungen hilft ein Arzt oder ein Schlaflabor."))
                        .font(.callout).foregroundStyle(Theme.mist)
                } header: {
                    ListHeader(tr("Wichtig"))
                }
                .listRowBackground(Theme.raised)

                Section {
                    Button { reportingBug = true } label: {
                        Label(tr("Fehler melden"), systemImage: "ladybug")
                    }
                } header: {
                    ListHeader(tr("Sonstiges"))
                }
                .tint(Theme.moon)
                .listRowBackground(Theme.raised)

                Section {
                    Link(destination: URL(string: tr("https://suya.ng-lab.de/datenschutz"))!) {
                        Label(tr("Datenschutzerklärung"), systemImage: "hand.raised")
                    }
                    Link(destination: URL(string: tr("https://suya.ng-lab.de/impressum"))!) {
                        Label(tr("Impressum"), systemImage: "info.circle")
                    }
                    NavigationLink { SoundCreditsView() } label: {
                        Label(tr("Quellen der Klänge"), systemImage: "music.note")
                    }
                    LabeledContent {
                        Text(Self.version)
                    } label: {
                        Label(tr("Version"), systemImage: "number")
                    }
                } header: {
                    ListHeader(tr("Rechtliches"))
                }
                .tint(Theme.moon)
                .listRowBackground(Theme.raised)

            }
            .nightBackground()
            .onAppear(perform: refresh)
            .donationDialogs(asking: $askingDonation, confirmDelete: $confirmDonationDelete)
            .sheet(isPresented: $reportingBug) { BugReportView() }
            .navigationTitle(tr("Mehr"))
            .toolbarTitleDisplayMode(.inlineLarge)
            .suyaTopEdge()
        }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(Theme.mist)
            Text(text).font(.callout)
        }
    }

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}
