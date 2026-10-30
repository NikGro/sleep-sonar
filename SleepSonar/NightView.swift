import SwiftUI
import UIKit

struct NightView: View {
    @StateObject private var rec = PassiveNightEngine()
    @State private var nights: [URL] = []
    @State private var confirmStop = false
    @State private var exporting: URL?
    @State private var exportNotes: [String] = []
    @State private var share: ShareItem?
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            List {
                if rec.isRunning {
                    runningSection
                } else {
                    Section("Vor dem Schlafen") {
                        Label("iPhone ans Ladekabel und neben das Bett, Mikrofon (Unterseite) zu dir.",
                              systemImage: "iphone.gen3")
                        Label("Apple Watch tragen.", systemImage: "applewatch")
                        Label("App nicht wegwischen. Bildschirm sperren und andere Apps nutzen ist okay.",
                              systemImage: "lock")
                        Label("Es wird nur zugehört, kein Ton gesendet. Die Aufnahme bleibt auf dem iPhone, "
                              + "bis du sie selbst teilst.", systemImage: "mic")
                    }
                    Section {
                        Button {
                            Task {
                                await rec.start()
                                refresh()
                            }
                        } label: {
                            Label("Nachtaufnahme starten", systemImage: "moon.stars.fill").font(.headline)
                        }
                        if let e = rec.errorMessage { Text(e).foregroundStyle(.red) }
                    }
                }

                Section("Gespeicherte Nächte") {
                    if nights.isEmpty { Text("Noch keine").foregroundStyle(.secondary) }
                    ForEach(nights, id: \.self) { url in
                        NightRow(url: url, isRecording: rec.isRunning && rec.folder == url,
                                 isExporting: exporting == url,
                                 onExport: { Task { await export(url) } },
                                 onShareAudio: {
                                     let files = NightExport.audioFiles(in: url)
                                     if !files.isEmpty { share = ShareItem(urls: files) }
                                 })
                    }
                    .onDelete { idx in
                        for i in idx where !(rec.isRunning && rec.folder == nights[i]) {
                            try? FileManager.default.removeItem(at: nights[i])
                        }
                        refresh()
                    }
                    ForEach(exportNotes, id: \.self) { Text($0).font(.caption) }
                    if let exportError { Text(exportError).foregroundStyle(.red).font(.caption) }
                }
            }
            .navigationTitle("Nacht")
            .onAppear(perform: refresh)
            .sheet(item: $share) { item in ShareSheet(items: item.urls) }
            .confirmationDialog("Nachtaufnahme beenden?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Beenden", role: .destructive) {
                    rec.stop()
                    refresh()
                }
            }
        }
    }

    @ViewBuilder private var runningSection: some View {
        Section("Läuft") {
            if let start = rec.startDate {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    LabeledContent("Dauer", value: Self.duration(ctx.date.timeIntervalSince(start)))
                }
            }
            LabeledContent("Pegel", value: String(format: "%.0f dBFS", rec.levelDB))
            LabeledContent("Tief / Mitte / Hoch",
                           value: rec.bandDB.map { String(format: "%.0f", $0) }.joined(separator: " / "))
            LabeledContent("Mikrofon", value: rec.inputName)
            LabeledContent("iPhone-Bewegung", value: String(format: "%.3f g%@", rec.motionActivity,
                           rec.motionActivity > MotionLogger.handledThreshold ? " – angefasst" : ""))
            LabeledContent("Neustarts", value: "\(rec.restarts)")
            Button(role: .destructive) { confirmStop = true } label: {
                Label("Nachtaufnahme beenden", systemImage: "stop.circle.fill").font(.headline)
            }
        }
        if !rec.events.isEmpty {
            Section("Ereignisse") {
                ForEach(rec.events, id: \.self) { Text($0).font(.caption.monospaced()) }
            }
        }
    }

    private func refresh() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: NightRecorder.nightsFolder,
                                                                 includingPropertiesForKeys: nil)) ?? []
        nights = dirs.filter { $0.hasDirectoryPath }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func export(_ url: URL) async {
        exporting = url
        exportError = nil
        defer { exporting = nil }
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
            share = ShareItem(urls: [try NightExport.zip(folder: url)])
        } catch {
            exportError = "ZIP fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}

private struct NightRow: View {
    let url: URL
    let isRecording: Bool
    let isExporting: Bool
    let onExport: () -> Void
    let onShareAudio: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading) {
                    Text(url.lastPathComponent.replacingOccurrences(of: "_", with: "  "))
                        .font(.body.monospacedDigit())
                    Text(isRecording ? "zeichnet auf …" : sizeText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isExporting { ProgressView() }
            }
            if !isRecording && !isExporting {
                if hasLevels {
                    NavigationLink {
                        NightAnalysisView(folder: url)
                    } label: {
                        Label("Auswerten", systemImage: "chart.bar.xaxis").font(.callout.bold())
                    }
                }
                HStack {
                    Button("Daten + Watch (ZIP)", action: onExport).buttonStyle(.bordered)
                    if hasAudio {
                        Button("Audio teilen", action: onShareAudio).buttonStyle(.bordered)
                    }
                }
                .font(.callout)
            }
        }
    }

    private var hasAudio: Bool { !NightExport.audioFiles(in: url).isEmpty }
    private var hasLevels: Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("levels.csv").path)
    }

    private var sizeText: String {
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +)
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

private struct ShareItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
