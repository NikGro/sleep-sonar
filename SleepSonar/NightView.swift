import SonarDSP
import SwiftUI
import UIKit

struct NightView: View {
    @StateObject private var sonar = SonarEngine()
    @State private var nights: [URL] = []
    @State private var confirmStop = false
    @State private var exporting: URL?
    @State private var exportNotes: [String] = []
    @State private var share: ShareItem?
    @State private var exportError: String?

    static let carrier = 20_000.0

    var body: some View {
        NavigationStack {
            List {
                if sonar.isRunning {
                    runningSection
                } else {
                    Section("Vor dem Schlafen") {
                        Label("iPhone ans Ladekabel.", systemImage: "battery.100.bolt")
                        Label("iPhone 30–100 cm neben dich, Unterseite (Lautsprecher) zu dir.",
                              systemImage: "iphone.gen3")
                        Label("Apple Watch tragen, Schlaf-Fokus wie gewohnt.", systemImage: "applewatch")
                        Label("App nicht wegwischen. Bildschirm sperren ist okay.", systemImage: "lock")
                        Label("Systemlautstärke wie beim Test einstellen und nachts nicht verändern.",
                              systemImage: "speaker.wave.3")
                        Label("20 kHz, automatischer Pegel (max. 85 %). In Health wird nichts geschrieben.",
                              systemImage: "waveform")
                    }
                    Section {
                        Button {
                            Task {
                                await sonar.start(carrierHz: Self.carrier, volume: SonarEngine.autoStartLevel,
                                                  auto: true, night: true)
                                refresh()
                            }
                        } label: {
                            Label("Nachtmessung starten", systemImage: "moon.stars.fill").font(.headline)
                        }
                        if let e = sonar.errorMessage { Text(e).foregroundStyle(.red) }
                    }
                }

                Section("Gespeicherte Nächte") {
                    if nights.isEmpty {
                        Text("Noch keine").foregroundStyle(.secondary)
                    }
                    ForEach(nights, id: \.self) { url in
                        NightRow(url: url, isRecording: sonar.nightRecorder?.folder == url,
                                 isExporting: exporting == url) {
                            Task { await export(url) }
                        }
                    }
                    .onDelete { idx in
                        for i in idx where sonar.nightRecorder?.folder != nights[i] {
                            try? FileManager.default.removeItem(at: nights[i])
                        }
                        refresh()
                    }
                    if !exportNotes.isEmpty {
                        ForEach(exportNotes, id: \.self) { Text($0).font(.caption) }
                    }
                    if let exportError { Text(exportError).foregroundStyle(.red).font(.caption) }
                }
            }
            .navigationTitle("Nacht")
            .onAppear(perform: refresh)
            .sheet(item: $share) { item in ShareSheet(items: [item.url]) }
            .confirmationDialog("Nachtmessung beenden?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Beenden", role: .destructive) {
                    sonar.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { refresh() }
                }
            }
        }
    }

    @ViewBuilder private var runningSection: some View {
        Section("Läuft") {
            if let start = sonar.startDate {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    LabeledContent("Dauer", value: Self.duration(ctx.date.timeIntervalSince(start)))
                }
            }
            if let r = sonar.reading {
                LabeledContent("Status", value: Self.statusText(r.status))
                LabeledContent("Atmung", value: r.breathsPerMinute.map { String(format: "%.1f /min", $0) } ?? "–")
                LabeledContent("Bewegung", value: String(format: "%.0f mm/s", r.movementMMPerSecond))
                LabeledContent("Echo/Rauschen", value: String(format: "%.1f", r.snr))
            }
            LabeledContent("Sendepegel", value: "\(Int((sonar.currentLevel * 100).rounded())) % "
                           + "(max. \(Int((sonar.ceiling * 100).rounded())) %)")
            LabeledContent("iPhone-Bewegung", value: String(format: "%.3f g%@", sonar.motionActivity,
                           sonar.motionActivity > MotionLogger.handledThreshold ? " – angefasst" : ""))
            LabeledContent("Systemlautstärke", value: "\(Int((sonar.systemVolume * 100).rounded())) %")
            LabeledContent("Neustarts", value: "\(sonar.diagnostics.restarts)")
            Button(role: .destructive) { confirmStop = true } label: {
                Label("Nachtmessung beenden", systemImage: "stop.circle.fill").font(.headline)
            }
        }
        if !sonar.diagnostics.events.isEmpty {
            Section("Ereignisse") {
                ForEach(sonar.diagnostics.events, id: \.self) { Text($0).font(.caption.monospaced()) }
            }
        }
    }

    private func refresh() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: NightRecorder.nightsFolder, includingPropertiesForKeys: nil)) ?? []
        nights = dirs.filter { $0.hasDirectoryPath }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func export(_ url: URL) async {
        exporting = url
        exportError = nil
        defer { exporting = nil }
        // Start/Ende aus meta.json für das Health-Zeitfenster
        var start = Date().addingTimeInterval(-12 * 3600), end = Date()
        if let data = try? Data(contentsOf: url.appendingPathComponent("meta.json")),
           let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let s = meta["start"] as? String, let d = iso.date(from: s) { start = d }
            if let e = meta["end"] as? String, let d = iso.date(from: e) { end = d }
        }
        exportNotes = await NightExport.writeHealthData(into: url, from: start, to: end)
        do {
            share = ShareItem(url: try NightExport.zip(folder: url))
        } catch {
            exportError = "ZIP fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    static func statusText(_ s: SonarReading.Status) -> String {
        switch s {
        case .warmingUp: "Sammle Daten"
        case .noEcho: "Kein Körperecho"
        case .moving: "Bewegung"
        case .collecting: "Ruhig"
        case .ok: "Atmung erkannt"
        }
    }
}

private struct NightRow: View {
    let url: URL
    let isRecording: Bool
    let isExporting: Bool
    let onExport: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(url.lastPathComponent.replacingOccurrences(of: "_", with: "  "))
                    .font(.body.monospacedDigit())
                Text(isRecording ? "zeichnet auf …" : sizeText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isExporting {
                ProgressView()
            } else if !isRecording {
                Button("Exportieren", action: onExport).buttonStyle(.bordered)
            }
        }
    }

    private var sizeText: String {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +)
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

private struct ShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
