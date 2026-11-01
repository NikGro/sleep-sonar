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
                        Text(tr("Noch keine Nacht aufgezeichnet")).font(Theme.display(22))
                        Text(tr("Starte heute Abend unter „Heute Nacht“ die Aufnahme. Morgens findest du sie hier."))
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
                                Label(tr("Daten und Watch teilen (ZIP)"), systemImage: "square.and.arrow.up")
                            }
                            Button {
                                Task { await export(url, includeAudio: true) }
                            } label: {
                                Label(tr("Alles fürs Training teilen (mit Audio)"), systemImage: "shippingbox")
                            }
                            if !NightExport.audioFiles(in: url).isEmpty {
                                Button {
                                    share = ShareItem(urls: NightExport.audioFiles(in: url))
                                } label: {
                                    Label(tr("Audio teilen"), systemImage: "waveform")
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
            .navigationTitle(tr("Nächte"))
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
        summaries.preload(nights)
    }

    private func export(_ url: URL, includeAudio: Bool = false) async {
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
            share = ShareItem(urls: [try NightExport.zip(folder: url, includeAudio: includeAudio)])
            if !notes.isEmpty { message = notes.joined(separator: "\n") }
        } catch {
            message = tr("ZIP konnte nicht erstellt werden: %@", error.localizedDescription)
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}

/// Kurzfassung einer Nacht für die Liste (eigene Schätzung, ohne Health).
/// Wird je Nacht in summary.json gespeichert, damit die Liste sofort Grafiken zeigt.
struct NightSummary: Codable {
    /// erhöhen, wenn sich die Regeln ändern → alte Zusammenfassungen werden neu berechnet
    static let rulesVersion = 5
    var version = rulesVersion
    /// Änderungsdatum von events.json (Geräusche fließen in die Schätzung ein)
    var eventsDate: Date?
    let start: Date
    let stagesCode: String
    let epochSeconds: Double

    init(start: Date, stages: [SleepStaging.Stage], epochSeconds: Double, eventsDate: Date?) {
        self.start = start
        self.stagesCode = String(stages.map { Character(String($0.rawValue)) })
        self.epochSeconds = epochSeconds
        self.eventsDate = eventsDate
    }

    var stages: [SleepStaging.Stage] { stagesCode.compactMap { $0.wholeNumberValue.flatMap(SleepStaging.Stage.init) } }
    var asleepSeconds: Double { Double(stagesCode.filter { $0 != "0" }.count) * epochSeconds }
    var totalSeconds: Double { Double(stagesCode.count) * epochSeconds }
    var score: SleepScore? { SleepScore.compute(stages, epochSeconds: epochSeconds) }

    static func file(_ folder: URL) -> URL { folder.appendingPathComponent("summary.json") }
    static func eventsDate(_ folder: URL) -> Date? {
        try? folder.appendingPathComponent("events.json").resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }

    /// Gespeicherte Fassung, egal ob aktuell (für die sofortige Anzeige)
    static func cached(_ folder: URL) -> NightSummary? {
        guard let data = try? Data(contentsOf: file(folder)) else { return nil }
        return try? JSONDecoder().decode(NightSummary.self, from: data)
    }

    var isCurrent: Bool { version == Self.rulesVersion }
    func isCurrent(for folder: URL) -> Bool { isCurrent && eventsDate == Self.eventsDate(folder) }

    func save(_ folder: URL) {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.file(folder), options: .atomic) }
    }
}

@MainActor
final class NightSummaries: ObservableObject {
    @Published private(set) var items: [URL: NightSummary] = [:]
    private var failed: Set<URL> = []
    private var checked: Set<URL> = []

    /// Gespeicherte Zusammenfassungen sofort übernehmen (klein, schnell)
    func preload(_ urls: [URL]) {
        for url in urls where items[url] == nil {
            if let c = NightSummary.cached(url) { items[url] = c }
        }
    }

    /// Im Hintergrund prüfen und bei Bedarf neu berechnen
    func load(_ url: URL) {
        guard !checked.contains(url), !failed.contains(url) else { return }
        checked.insert(url)
        if let c = items[url] ?? NightSummary.cached(url), c.isCurrent(for: url) {
            items[url] = c
            return
        }
        Task {
            let r = try? await Task.detached(priority: .utility) { () -> NightSummary in
                let events = NightSummary.eventsDate(url)
                let e = try NightAnalyzer.estimate(folder: url)
                let s = NightSummary(start: e.start, stages: e.stages, epochSeconds: e.epochSeconds, eventsDate: events)
                s.save(url)
                return s
            }.value
            if let r { items[url] = r } else { failed.insert(url) }
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
            HStack(alignment: .center) {
                Text(title).font(Theme.display(19, weight: .medium))
                Spacer()
                if busy {
                    ProgressView().tint(Theme.moon)
                } else if let score = summary?.score {
                    ScoreRing(score: score.total, size: 38, line: 3)
                }
            }
            if recording {
                Text(tr("Aufnahme läuft")).font(.callout).foregroundStyle(Theme.mist)
            } else if let summary {
                Hypnogram(stages: summary.stages.map { Optional($0) }, start: summary.start,
                          epochSeconds: summary.epochSeconds, compact: true)
                    .frame(height: 34)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                Text(tr("%@ geschlafen, %@", NightAnalysisView.hm(summary.asleepSeconds),
                        times(summary.start, summary.totalSeconds)))
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
        return NightAnalysisView.title(d)
    }

    private func times(_ start: Date, _ seconds: Double) -> String {
        let end = start.addingTimeInterval(seconds)
        return tr("%@ bis %@", start.formatted(date: .omitted, time: .shortened), end.formatted(date: .omitted, time: .shortened))
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
