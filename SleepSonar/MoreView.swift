import SwiftUI

/// Einstellungen und Hilfe: Health-Zugriff, Kurzbefehle, Hinweise, Entwickler-Werkzeuge.
struct MoreView: View {
    @State private var healthNote: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task {
                            do {
                                try await NightExport.requestAuthorization()
                                healthNote = "Erledigt. Ändern kannst du das in der Health-App unter Profil, Apps, Somnivo."
                            } catch {
                                healthNote = "Health hat nicht geantwortet: \(error.localizedDescription)"
                            }
                        }
                    } label: {
                        Label("Health-Zugriff erlauben", systemImage: "heart.text.square")
                    }
                    if let healthNote {
                        Text(healthNote).font(.caption).foregroundStyle(Theme.mist)
                    }
                } header: {
                    header("Apple Health")
                } footer: {
                    Text("Somnivo liest die Schlafphasen deiner Apple Watch, um sie mit der eigenen Schätzung zu vergleichen.")
                        .foregroundStyle(Theme.mist)
                }
                .listRowBackground(Theme.raised)

                Section {
                    tip("moon.zzz", "„Schlafaufnahme starten“ und „Schlafaufnahme beenden“ gibt es in der Kurzbefehle-App, "
                        + "zum Beispiel als Automation beim Schlaf-Fokus.")
                    tip("bolt", "Über Nacht ans Ladekabel. Die Aufnahme braucht etwa so viel Strom wie Musik hören.")
                    tip("iphone.gen3", "Unterseite mit dem Mikrofon zu dir, etwa eine Armlänge entfernt.")
                    tip("hand.raised", "Somnivo sendet keinen Ton aus und stört andere Apps nicht.")
                } header: {
                    header("Tipps")
                }
                .listRowBackground(Theme.raised)

                Section {
                    Text("Die Schlafphasen sind eine Schätzung aus Geräuschen und keine medizinische Messung. "
                         + "Bei Verdacht auf Schlafstörungen hilft ein Arzt oder ein Schlaflabor.")
                        .font(.callout).foregroundStyle(Theme.mist)
                } header: {
                    header("Wichtig")
                }
                .listRowBackground(Theme.raised)

                Section {
                    NavigationLink("Health-Schreibtest") { HealthTestView() }
                    LabeledContent("Version", value: Self.version)
                } header: {
                    header("Für Entwickler")
                }
                .listRowBackground(Theme.raised)
            }
            .nightBackground()
            .navigationTitle("Mehr")
            .toolbarBackground(Theme.ink, for: .navigationBar)
        }
    }

    private func header(_ t: String) -> some View {
        Text(t).font(Theme.display(17, weight: .medium)).foregroundStyle(Theme.moon).textCase(nil)
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(Theme.mist)
            Text(text).font(.callout)
        }
    }

    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
