import SwiftUI

/// Entwickler-Werkzeug: Schreiben in Apple Health Schritt für Schritt prüfen.
struct HealthTestView: View {
    @StateObject private var health = HealthManager()
    @State private var busy = false

    var body: some View {
        List {
            Section {
                action(tr("1. Health-Zugriff anfragen"), systemImage: "heart.text.square") {
                    await health.requestAuthorization()
                }
                action(tr("2. Testnacht schreiben"), systemImage: "bed.double") {
                    await health.writeTestNight()
                }
                action(tr("3. Zurücklesen"), systemImage: "chart.bar") {
                    await health.readBack()
                }
            } header: {
                header(tr("Schritt für Schritt"))
            }
            .listRowBackground(Theme.raised)

            Section {
                action(tr("Eigene Einträge löschen"), systemImage: "trash", destructive: true) {
                    await health.deleteOwnSamples()
                }
            }
            .listRowBackground(Theme.raised)

            Section {
                if health.log.isEmpty {
                    Text(tr("Noch nichts passiert.")).font(.callout).foregroundStyle(Theme.mist)
                }
                ForEach(Array(health.log.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.callout)
                }
            } header: {
                header(tr("Protokoll"))
            }
            .listRowBackground(Theme.raised)
        }
        .nightBackground()
        .navigationTitle(tr("Health-Schreibtest"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.ink, for: .navigationBar)
        .disabled(busy)
        .overlay { if busy { ProgressView().tint(Theme.moon) } }
    }

    private func header(_ t: String) -> some View {
        Text(t).font(Theme.display(17, weight: .medium)).foregroundStyle(Theme.moon).textCase(nil)
    }

    private func action(_ title: String, systemImage: String, destructive: Bool = false,
                        _ work: @escaping () async -> Void) -> some View {
        Button {
            busy = true
            Task {
                await work()
                busy = false
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage).frame(width: 22)
                    .foregroundStyle(destructive ? Theme.alert : Theme.mist)
                Text(title).font(.callout)
                    .foregroundStyle(destructive ? Theme.alert : Theme.moon)
            }
        }
    }
}
