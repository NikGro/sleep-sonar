import SonarDSP
import SwiftUI
import UIKit

/// Liste der aufgezeichneten Nächte, jede mit kleinem Hypnogramm.
struct NightView: View {
    @ObservedObject private var rec = PassiveNightEngine.shared
    @StateObject private var summaries = NightSummaries()
    @State private var nights: [URL] = []
    @State private var exporting: URL?
    @State private var share: ShareItem?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                if nights.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Noch keine Nacht aufgezeichnet").font(Theme.display(22))
                        Text("Starte heute Abend unter „Heute Nacht“ die Aufnahme. Morgens findest du sie hier.")
                            .font(.callout).foregroundStyle(Theme.mist)
                    }
                    .padding(.vertical, 24)
                    .listRowBackground(Theme.ink)
                }
                ForEach(nights, id: \.self) { url in
                    let recording = rec.isRunning && rec.folder == url
                    Group {
                        if recording {
                            NightRow(url: url, summary: nil, recording: true, busy: false)
                        } else {
                            NavigationLink {
                                NightAnalysisView(folder: url)
                            } label: {
                                NightRow(url: url, summary: summaries.items[url], recording: false,
                                         busy: exporting == url)
                            }
                        }
                    }
                    .listRowBackground(Theme.ink)
                    .listRowSeparatorTint(Theme.hairline)
                    .task { if !recording { summaries.load(url) } }
                    .contextMenu {
                        if !recording {
                            Button {
                                Task { await export(url) }
                            } label: {
                                Label("Daten und Watch teilen (ZIP)", systemImage: "square.and.arrow.up")
                            }
                            if !NightExport.audioFiles(in: url).isEmpty {
                                Button {
                                    share = ShareItem(urls: NightExport.audioFiles(in: url))
                                } label: {
                                    Label("Audio teilen", systemImage: "waveform")
                                }
                            }
                        }
                    }
                }
                .onDelete { idx in
                    for i in idx where !(rec.isRunning && rec.folder == nights[i]) {
                        try? FileManager.default.removeItem(at: nights[i])
                    }
                    refresh()
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(Theme.mist).listRowBackground(Theme.ink)
                }
            }
            .listStyle(.plain)
            .nightBackground()
            .navigationTitle("Nächte")
            .toolbarBackground(Theme.ink, for: .navigationBar)
            .onAppear(perform: refresh)
            .onChange(of: rec.isRunning) { refresh() }
            .refreshable { refresh() }
            .sheet(item: $share) { item in ShareSheet(items: item.urls) }
        }
    }

    private func refresh() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: NightRecorder.nightsFolder,
                                                                 includingPropertiesForKeys: nil)) ?? []
        nights = dirs.filter { $0.hasDirectoryPath }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func export(_ url: URL) async {
        exporting = url
        message = nil
        defer { exporting = nil }
        var start = Date().addingTimeInterval(-12 * 3600), end = Date()
        if let data = try? Data(contentsOf: url.appendingPathComponent("meta.json")),
           let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let s = meta["start"] as? String, let d = iso.date(from: s) { start = d }
            if let e = meta["end"] as? String, let d = iso.date(from: e) { end = d }
        }
        let notes = await NightExport.writeHealthData(into: url, from: start, to: end)
        do {
            share = ShareItem(urls: [try NightExport.zip(folder: url)])
            if !notes.isEmpty { message = notes.joined(separator: "\n") }
        } catch {
            message = "ZIP konnte nicht erstellt werden: \(error.localizedDescription)"
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}

/// Kurzfassung einer Nacht für die Liste (eigene Schätzung, ohne Health).
struct NightSummary {
    let start: Date
    let stages: [SleepStaging.Stage]
    let epochSeconds: Double

    var asleepSeconds: Double { Double(stages.filter { $0 != .wake }.count) * epochSeconds }
    var totalSeconds: Double { Double(stages.count) * epochSeconds }
}

@MainActor
final class NightSummaries: ObservableObject {
    @Published private(set) var items: [URL: NightSummary] = [:]
    private var failed: Set<URL> = []

    func load(_ url: URL) {
        guard items[url] == nil, !failed.contains(url) else { return }
        Task {
            let r = try? await Task.detached(priority: .utility) { try NightAnalyzer.estimate(folder: url) }.value
            if let r {
                items[url] = NightSummary(start: r.start, stages: r.stages, epochSeconds: r.epochSeconds)
            } else {
                failed.insert(url)
            }
        }
    }
}

private struct NightRow: View {
    let url: URL
    let summary: NightSummary?
    let recording: Bool
    let busy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Theme.display(19, weight: .medium))
                Spacer()
                if busy { ProgressView().tint(Theme.moon) }
            }
            if recording {
                Text("Aufnahme läuft").font(.callout).foregroundStyle(Theme.mist)
            } else if let summary {
                Hypnogram(stages: summary.stages.map { Optional($0) }, start: summary.start,
                          epochSeconds: summary.epochSeconds, compact: true)
                    .frame(height: 34)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                Text("\(NightAnalysisView.hm(summary.asleepSeconds)) geschlafen, "
                     + "\(times(summary.start, summary.totalSeconds))")
                    .font(.callout).foregroundStyle(Theme.mist)
            } else {
                Text(sizeText).font(.callout).foregroundStyle(Theme.mist)
            }
        }
        .padding(.vertical, 10)
    }

    private var startDate: Date? {
        if let s = summary?.start { return s }
        let name = url.lastPathComponent.replacingOccurrences(of: "_audio", with: "")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        return f.date(from: name)
    }

    private var title: String {
        guard let d = startDate else { return url.lastPathComponent }
        // Eine Nacht wird nach dem Morgen benannt, an dem man aufwacht.
        return "Nacht zum " + d.addingTimeInterval(6 * 3600).formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private func times(_ start: Date, _ seconds: Double) -> String {
        let end = start.addingTimeInterval(seconds)
        return "\(start.formatted(date: .omitted, time: .shortened)) bis \(end.formatted(date: .omitted, time: .shortened))"
    }

    private var sizeText: String {
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +)
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
