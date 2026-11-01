import SwiftUI

struct HealthTestView: View {
    @StateObject private var health = HealthManager()
    @State private var busy = false

    var body: some View {
        Group {
            List {
                Section(tr("Schritt für Schritt")) {
                    action(tr("1. Health-Zugriff anfragen"), systemImage: "heart.text.square") {
                        await health.requestAuthorization()
                    }
                    action(tr("2. Testnacht schreiben"), systemImage: "bed.double") {
                        await health.writeTestNight()
                    }
                    action(tr("3. Zurücklesen"), systemImage: "chart.bar") {
                        await health.readBack()
                    }
                }
                Section {
                    action(tr("Eigene Einträge löschen"), systemImage: "trash", role: .destructive) {
                        await health.deleteOwnSamples()
                    }
                }
                Section(tr("Protokoll")) {
                    if health.log.isEmpty {
                        Text(tr("Noch nichts passiert.")).foregroundStyle(.secondary)
                    }
                    ForEach(Array(health.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.callout)
                    }
                }
            }
            .navigationTitle(tr("Health-Schreibtest"))
            .disabled(busy)
        }
    }

    private func action(_ title: String, systemImage: String, role: ButtonRole? = nil,
                        _ work: @escaping () async -> Void) -> some View {
        Button(role: role) {
            busy = true
            Task {
                await work()
                busy = false
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}
