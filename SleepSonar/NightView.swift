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
    @State private var demo: URL?
    @ObservedObject private var donation = DataDonation.shared
    @ObservedObject private var uploader = DonationUploader.shared
    @State private var deleting: [URL] = []

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
                                         busy: exporting == url || uploader.active == url)
                            }
                        }
                    }
                    .listRowBackground(Theme.ink)
                    .listRowSeparatorTint(Theme.hairline)
                    .task { if !recording { summaries.load(url) } }
                    .contextMenu {
                        if !recording {
                            if donation.state == .granted, DonationUploader.canResend(url) {
                                Button {
                                    Task {
                                        exporting = url
                                        defer { exporting = nil }
                                        await DonationUploader.shared.resend(url)
                                        let st = NightDonationState.existing(url)
                                        message = st?.sent != nil ? tr("Nacht gespendet.")
                                            : (st?.skipped ?? st?.waiting).map(NightDonationState.reasonText)
                                    }
                                } label: {
                                    Label(DonationUploader.donateLabel(url), systemImage: "arrow.up.heart")
                                }
                            }
                            if let left = NightFinisher.exportTimeLeft(url) {
                                Button {
                                    Task { await export(url) }
                                } label: {
                                    // Untertitel im Menü: wie lange der Ton noch da ist
                                    Label {
                                        Text(tr("Alles exportieren (mit Audio)"))
                                        Text(tr("Noch %@ möglich", left))
                                    } icon: {
                                        Image(systemName: "square.and.arrow.up")
                                    }
                                }
                            }
                            Button(role: .destructive) {
                                deleting = [url]
                            } label: {
                                Label(tr("Löschen"), systemImage: "trash")
                            }
                        }
                    }
                }
                .onDelete { idx in deleting = idx.map { nights[$0] } }
                if let message {
                    Text(message).font(.caption).foregroundStyle(Theme.mist).listRowBackground(Theme.ink)
                }
            }
            .listStyle(.plain)
            .nightBackground()
            .navigationDestination(item: $demo) { NightAnalysisView(folder: $0) }
            .onAppear {
                if let s = DemoScreens.screen, s.hasPrefix("night"), let f = DemoScreens.demoNight() {
                    refresh()
                    if s != "nights" { demo = f }
                }
            }
            .navigationTitle(tr("Nächte"))
            .toolbarTitleDisplayMode(.inlineLarge)
            .suyaTopEdge()
            .onAppear(perform: refresh)
            .onChange(of: rec.isRunning) { refresh() }
            .refreshable { refresh() }
            .sheet(item: $share) { item in ShareSheet(items: item.urls) }
            .alert(tr("Willst du diese Nacht löschen?"),
                   isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })) {
                Button(tr("Nacht löschen"), role: .destructive) {
                    for url in deleting where !(rec.isRunning && rec.folder == url) {
                        try? FileManager.default.removeItem(at: url)
                    }
                    deleting = []
                    Haptics.warning()
                    refresh()
                }
                Button(tr("Abbrechen"), role: .cancel) { deleting = [] }
            } message: {
                Text(tr("Aufnahme, Auswertung und Geräusche dieser Nacht werden vom iPhone gelöscht. Einträge in Health bleiben."))
            }
        }
    }

    private func refresh() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: NightRecorder.nightsFolder,
                                                                 includingPropertiesForKeys: nil)) ?? []
        nights = dirs.filter { $0.hasDirectoryPath }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        summaries.preload(nights)
    }

    /// ZIP mit allem: Ton, Pegel, Bewegung, Auswertung und Watch-Daten aus Health (24 h nach der Nacht möglich)
    private func export(_ url: URL) async {
        exporting = url
        message = nil
        defer { exporting = nil }
        let end = NightFinisher.nightEnd(url) ?? Date()
        let start = DonationUploader.audioStart(url) ?? end.addingTimeInterval(-12 * 3600)
        _ = await NightExport.writeHealthData(into: url, from: start, to: end)
        do {
            share = ShareItem(urls: [try NightExport.zip(folder: url, includeAudio: true)])
        } catch {
            message = tr("ZIP konnte nicht erstellt werden: %@", error.localizedDescription)
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}

/// Kurzfassung einer Nacht für die Liste (Schlafphasen aus dem Modell, ohne Health).
/// Wird je Nacht in summary.json gespeichert, damit die Liste sofort Grafiken zeigt.
struct NightSummary: Codable {
    /// 100 + Modellversion: ändert sich das Modell, werden Zusammenfassungen (und Health-Einträge) neu berechnet.
    /// (bis 7: Regeln)
    static let currentVersion = 100 + NightModel.version
    var version = currentVersion
    let start: Date
    let stagesCode: String
    let epochSeconds: Double

    init(start: Date, stages: [SleepStaging.Stage], epochSeconds: Double) {
        self.start = start
        self.stagesCode = String(stages.map { Character(String($0.rawValue)) })
        self.epochSeconds = epochSeconds
    }

    var stages: [SleepStaging.Stage] { stagesCode.compactMap { $0.wholeNumberValue.flatMap(SleepStaging.Stage.init) } }
    var asleepSeconds: Double { Double(stagesCode.filter { $0 != "0" }.count) * epochSeconds }
    var totalSeconds: Double { Double(stagesCode.count) * epochSeconds }
    var score: SleepScore? { SleepScore.compute(stages, epochSeconds: epochSeconds) }

    static func file(_ folder: URL) -> URL { folder.appendingPathComponent("summary.json") }

    /// Gespeicherte Fassung, egal ob aktuell (für die sofortige Anzeige)
    static func cached(_ folder: URL) -> NightSummary? {
        guard let data = try? Data(contentsOf: file(folder)) else { return nil }
        return try? JSONDecoder().decode(NightSummary.self, from: data)
    }

    var isCurrent: Bool { version == Self.currentVersion }
    /// Ist der Ton schon gelöscht, bleibt auch eine ältere Fassung gültig (neu rechnen geht nicht mehr).
    func isCurrent(for folder: URL) -> Bool {
        isCurrent || (NightExport.audioFiles(in: folder).isEmpty && NightModel.cachedAnyVersion(folder) == nil)
    }

    func save(_ folder: URL) {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.file(folder), options: .atomic) }
    }
}

@MainActor
final class NightSummaries: ObservableObject {
    @Published private(set) var items: [URL: NightSummary] = [:]
    private var failed: Set<URL> = []
    private var checked: Set<URL> = []
    private var queue: Task<Void, Never>?

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
        // nacheinander rechnen (das Modell braucht je Nacht etwas Speicher und Zeit)
        let previous = queue
        queue = Task {
            await previous?.value
            let r = try? await Task.detached(priority: .utility) { () -> NightSummary in
                let e = try NightAnalyzer.estimate(folder: url)
                let s = NightSummary(start: e.start, stages: e.stages, epochSeconds: e.epochSeconds)
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
                    HStack(spacing: 8) {
                        ScoreMoon(score: score.total, size: 22)
                        Text("\(score.total)").font(Theme.display(19).monospacedDigit())
                            .accessibilityHidden(true)
                    }
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
