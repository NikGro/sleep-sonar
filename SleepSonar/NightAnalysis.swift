import Charts
import Foundation
import HealthKit
import SonarDSP
import SwiftUI

/// Lädt eine Mikrofon-Nacht, schätzt die Schlafphasen und holt die Watch-Phasen zum Vergleich.
struct NightAnalysisResult {
    var start: Date
    var epochSeconds: Double
    var ours: [SleepStaging.Stage]
    var watch: [SleepStaging.Stage?]
    var watchSource: String
    var agreement: (fourClass: Double, sleepWake: Double, epochs: Int)
    var events: [SoundEvent]

    func minutes(_ stages: [SleepStaging.Stage?], _ s: SleepStaging.Stage) -> Double {
        Double(stages.filter { $0 == s }.count) * epochSeconds / 60
    }
}

enum NightAnalyzer {
    enum Failure: LocalizedError {
        case noLevels
        var errorDescription: String? {
            tr("Diese Nacht hat keine Pegeldaten (nur Nächte aus der Mikrofon-Aufnahme lassen sich auswerten).")
        }
    }

    /// Nur die eigene Schätzung (ohne Health) – schnell genug für die Nächte-Liste.
    static func estimate(folder: URL) throws -> (start: Date, stages: [SleepStaging.Stage], epochSeconds: Double) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // levels.csv: time,rms_db,peak_db,low,mid,high
        guard let levelText = try? String(contentsOf: folder.appendingPathComponent("levels.csv"), encoding: .utf8)
        else { throw Failure.noLevels }
        // Jede Zeile = eine Audiosekunde (lückenlos). Nach Reihenfolge einsortieren, nicht nach
        // Uhrzeit – sonst entstehen durch minimale Taktabweichungen Scheinlücken.
        var seconds: [SleepStaging.Second?] = []
        var first: Date?
        for line in levelText.split(separator: "\n").dropFirst() {
            let c = line.split(separator: ",", omittingEmptySubsequences: false)
            guard c.count >= 6, let rms = Double(c[1]), let mid = Double(c[4]), let high = Double(c[5]) else {
                seconds.append(nil); continue
            }
            if first == nil { first = iso.date(from: String(c[0])) }
            seconds.append(.init(rms: rms, mid: mid, high: high))
        }
        guard let first, !seconds.isEmpty else { throw Failure.noLevels }
        let total = seconds.count

        // motion.csv: time,activity_g,…
        var motion = [Double?](repeating: nil, count: total)
        if let mt = try? String(contentsOf: folder.appendingPathComponent("motion.csv"), encoding: .utf8) {
            for line in mt.split(separator: "\n").dropFirst() {
                let c = line.split(separator: ",")
                guard c.count >= 2, let t = iso.date(from: String(c[0])), let a = Double(c[1]) else { continue }
                let i = Int(t.timeIntervalSince(first).rounded())
                if i >= 0 && i < total { motion[i] = a }
            }
        }

        let params = SleepStaging.Parameters()
        // Geräusche (falls schon ausgewertet): Schnarchen = Schlaf, Sprechen/Husten = Unruhe
        let marks = SoundEventDetector.marks(SoundEventDetector.cached(in: folder) ?? [])
        let epochs = SleepStaging.estimate(seconds: seconds, motion: motion, sleepSounds: marks.sleep,
                                           wakeSounds: marks.wake, parameters: params)
        return (first, epochs.map(\.stage), Double(params.epochSeconds))
    }

    static func analyze(folder: URL, progress: @escaping @Sendable (Double) -> Void = { _ in })
        async throws -> NightAnalysisResult {
        let events = (try? await SoundEventDetector.analyze(folder: folder, progress: progress)) ?? []
        let (first, ours, epochSeconds) = try await Task.detached(priority: .userInitiated) {
            try estimate(folder: folder)
        }.value
        let end = first.addingTimeInterval(Double(ours.count) * epochSeconds)

        // Watch-Phasen aus Health (ohne Einträge dieser App)
        let (watch, source) = await watchStages(from: first, to: end, epochs: ours.count, epochSeconds: epochSeconds)
        let agreement = SleepStaging.agreement(ours.map { Optional($0) }, watch)
        return NightAnalysisResult(start: first, epochSeconds: epochSeconds, ours: ours, watch: watch,
                                   watchSource: source, agreement: agreement, events: events)
    }

    static func watchStages(from start: Date, to end: Date, epochs: Int, epochSeconds: Double) async
        -> ([SleepStaging.Stage?], String) {
        var result = [SleepStaging.Stage?](repeating: nil, count: epochs)
        let store = HKHealthStore()
        let type = HKCategoryType(.sleepAnalysis)
        try? await store.requestAuthorization(toShare: [type], read: [type])
        let predicate = HKQuery.predicateForSamples(withStart: start.addingTimeInterval(-3600),
                                                    end: end.addingTimeInterval(3600))
        let d = HKSampleQueryDescriptor(predicates: [.categorySample(type: type, predicate: predicate)],
                                        sortDescriptors: [SortDescriptor(\.startDate)])
        guard let samples = try? await d.result(for: store) else { return (result, "") }
        let ownBundle = Bundle.main.bundleIdentifier ?? ""
        let foreign = samples.filter { $0.sourceRevision.source.bundleIdentifier != ownBundle }
        var sources = Set<String>()
        for s in foreign {
            let stage: SleepStaging.Stage?
            switch HKCategoryValueSleepAnalysis(rawValue: s.value) {
            case .awake: stage = .wake
            case .asleepCore: stage = .core
            case .asleepDeep: stage = .deep
            case .asleepREM: stage = .rem
            default: stage = nil   // „Im Bett“ / „Schlafend (ohne Phase)“
            }
            guard let stage else { continue }
            sources.insert(s.sourceRevision.source.name)
            for e in 0..<epochs {
                let mid = start.addingTimeInterval((Double(e) + 0.5) * epochSeconds)
                if mid >= s.startDate && mid < s.endDate { result[e] = stage }
            }
        }
        // Zeit im Bett ohne Watch-Eintrag zwischen erster und letzter Watch-Phase = wach
        if let firstIdx = result.firstIndex(where: { $0 != nil }),
           let lastIdx = result.lastIndex(where: { $0 != nil }) {
            for e in firstIdx...lastIdx where result[e] == nil { result[e] = .wake }
        }
        return (result, sources.sorted().joined(separator: ", "))
    }
}

struct NightAnalysisView: View {
    let folder: URL
    @State private var result: NightAnalysisResult?
    @State private var error: String?
    @State private var soundProgress: Double?
    @StateObject private var player = NightClipPlayer()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 48) {
                if let error {
                    Text(error).foregroundStyle(Theme.alert)
                } else if let r = result {
                    content(r)
                } else {
                    VStack(spacing: 14) {
                        if let p = soundProgress, p < 1 {
                            ProgressView(value: p).tint(Theme.moon).frame(maxWidth: 220)
                            Text(tr("Geräusche der Nacht werden erkannt (%d %%)", Int(p * 100)))
                                .font(.callout).foregroundStyle(Theme.mist)
                            Text(tr("Das passiert einmal je Nacht und bleibt auf dem iPhone. Du kannst die App verlassen: Was fehlt, erledigt das iPhone später am Ladekabel."))
                                .font(.caption).foregroundStyle(Theme.mist)
                        } else {
                            ProgressView().tint(Theme.moon)
                            Text(tr("Nacht wird ausgewertet")).font(.callout).foregroundStyle(Theme.mist)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .defaultScrollAnchor(DemoScreens.screen == "nightBottom" ? .bottom : .top)
        .nightBackground()
        .navigationTitle(result.map { Self.title($0.start) } ?? tr("Auswertung"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            BackgroundAnalysis.analysisStarted()
            defer { BackgroundAnalysis.analysisEnded() }
            do {
                let r = try await NightAnalyzer.analyze(folder: folder) { p in
                    Task { @MainActor in soundProgress = p }
                }
                result = r
                // Liste aktuell halten
                NightSummary(start: r.start, stages: r.ours, epochSeconds: r.epochSeconds,
                             eventsDate: NightSummary.eventsDate(folder)).save(folder)
            } catch { self.error = error.localizedDescription }
        }
        .onDisappear { player.stop() }
    }

    @ViewBuilder private func content(_ r: NightAnalysisResult) -> some View {
        let ours = r.ours.map { Optional($0) }
        let hasWatch = r.watch.contains { $0 != nil }
        let asleep = ours.filter { $0 != nil && $0 != .wake }.count

        // Dauer und Schlafwert nebeneinander: Mond so groß wie die Zahl, Beschriftungen in einer Zeile,
        // rechte Spalte bündig mit dem rechten Rand der Balken darunter
        let score = SleepScore.compute(r.ours, epochSeconds: r.epochSeconds)
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow(alignment: .center) {
                Text(Self.hm(Double(asleep) * r.epochSeconds))
                    .font(Theme.display(44, weight: .light))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let score {
                    ScoreMoon(score: score.total, size: 52, showNumber: true)
                        .gridColumnAlignment(.trailing)
                }
            }
            GridRow(alignment: .firstTextBaseline) {
                Text(tr("geschlafen, %@ bis %@ Uhr", r.start.formatted(date: .omitted, time: .shortened),
                        r.start.addingTimeInterval(Double(r.ours.count) * r.epochSeconds)
                            .formatted(date: .omitted, time: .shortened)))
                    .font(.callout).foregroundStyle(Theme.mist)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if score != nil {
                    Text(tr("Schlafwert")).font(.callout).foregroundStyle(Theme.mist)
                        .fixedSize()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 16)

        if let score = SleepScore.compute(r.ours, epochSeconds: r.epochSeconds) {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(tr("Schlafwert"))
                // Farbe je Teil nach dem, was er misst (wie die Phasenfarben)
                ScorePart(label: tr("Dauer"), value: score.duration, max: 50, colors: [Theme.color(.core)])
                ScorePart(label: tr("Ruhe"), value: score.efficiency, max: 20, colors: [Theme.color(.deep)])
                ScorePart(label: tr("Tief und REM"), value: score.depth, max: 20,
                          colors: [Theme.color(.deep), Theme.color(.rem)])
                ScorePart(label: tr("Wenig Aufwachen"), value: score.interruptions, max: 10,
                          colors: [Theme.color(.wake)])
            }
        }

        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Suya")
            Hypnogram(stages: ours, start: r.start, epochSeconds: r.epochSeconds)
                .frame(height: 112)
            StageLegend()
        }

        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(r.watchSource.isEmpty ? "Apple Watch" : r.watchSource)
            if hasWatch {
                Hypnogram(stages: r.watch, start: r.start, epochSeconds: r.epochSeconds)
                    .frame(height: 112)
            } else {
                Text(tr("Für diese Nacht gibt es keine Watch-Schlafphasen in Health. Ist die Watch synchronisiert und der Health-Zugriff erlaubt?"))
                    .font(.callout).foregroundStyle(Theme.mist)
            }
        }

        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(tr("Zeit je Phase"))
            ForEach([SleepStaging.Stage.wake, .rem, .core, .deep], id: \.self) { s in
                StageRow(stage: s, ours: r.minutes(ours, s),
                         watch: hasWatch ? r.minutes(r.watch, s) : nil,
                         scale: Double(r.ours.count) * r.epochSeconds / 60)
            }
            if hasWatch {
                HStack(spacing: 16) {
                    Label("Suya", systemImage: "circle.fill").foregroundStyle(Theme.moon)
                    Label(tr("Watch"), systemImage: "circle").foregroundStyle(Theme.mist)
                }
                .font(.caption)
                .labelStyle(SmallDotLabel())
            }
        }

        // Nur Geräusche, während derer geschlafen wurde (Gespräche vorm Einschlafen u. Ä. ausblenden)
        let asleepEvents = r.events.filter { e in
            let i = Int(((e.start + e.end) / 2) / r.epochSeconds)
            return i >= 0 && i < r.ours.count && r.ours[i] != .wake
        }
        SoundSection(events: asleepEvents, start: r.start,
                     total: Double(r.ours.count) * r.epochSeconds, folder: folder, player: player)

        if r.agreement.epochs > 0 {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(tr("Vergleich mit der Watch"))
                // über die volle Breite wie die übrigen Elemente
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Figure(value: String(format: "%.0f %%", r.agreement.sleepWake * 100), label: tr("Schlaf oder wach gleich"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Figure(value: String(format: "%.0f %%", r.agreement.fourClass * 100), label: tr("Phase gleich"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
                Text(tr("Verglichen über %@.", Self.hm(Double(r.agreement.epochs) * r.epochSeconds)))
                    .font(.caption).foregroundStyle(Theme.mist)
            }
        }

        Text(tr("Die Schätzung ist noch in Entwicklung. Wach und Schlaf sind halbwegs verlässlich, Tief und REM noch grob. Kein Medizinprodukt."))
            .font(.caption).foregroundStyle(Theme.mist)
    }

    static func title(_ d: Date) -> String {
        tr("Nacht zum %@", d.addingTimeInterval(6 * 3600).formatted(.dateTime.weekday(.wide).day().month(.wide)))
    }

    static func hm(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        return tr("%d h %02d min", m / 60, m % 60)
    }
}

/// Ein Teil des Schlafwerts als schmaler Balken.
private struct ScorePart: View {
    let label: String
    let value: Int
    let max: Int
    let colors: [Color]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.callout)
                Spacer()
                Text("\(value) / \(max)").font(.callout.monospacedDigit()).foregroundStyle(Theme.mist)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.raised)
                    Capsule().fill(LinearGradient(colors: colors.count > 1 ? colors : colors + colors,
                                                  startPoint: .leading, endPoint: .trailing))
                        .frame(width: Swift.max(8, g.size.width * CGFloat(value) / CGFloat(max)))
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct Figure: View {
    let value: String
    let label: String
    var alignment: HorizontalAlignment = .leading
    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(value).font(Theme.display(30)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(Theme.mist)
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
        }
    }
}

private struct SmallDotLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 7))
            configuration.title
        }
    }
}

/// Minuten einer Phase: eigener Balken (gefüllt) und Watch (Umriss) übereinander.
private struct StageRow: View {
    let stage: SleepStaging.Stage
    let ours: Double
    let watch: Double?
    let scale: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(stage.displayName).font(.callout)
                Spacer()
                Text(tr("%d min", Int(ours))).font(.callout.monospacedDigit())
                if let watch {
                    Text(tr("Watch %d", Int(watch))).font(.caption.monospacedDigit()).foregroundStyle(Theme.mist)
                        .frame(minWidth: 70, alignment: .trailing)
                }
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.raised)
                    Capsule().fill(Theme.color(stage))
                        .frame(width: max(4, w * CGFloat(ours / max(scale, 1))))
                    if let watch {
                        Capsule().strokeBorder(Theme.moon.opacity(0.7), lineWidth: 1)
                            .frame(width: max(4, w * CGFloat(watch / max(scale, 1))))
                    }
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Hypnogramm: Phasen als Stufen (Wach oben, Tief unten), wie man es von Schlafberichten kennt.
struct Hypnogram: View {
    let stages: [SleepStaging.Stage?]
    let start: Date
    let epochSeconds: Double
    var compact = false

    private struct Segment: Identifiable {
        let id: Int
        let stage: SleepStaging.Stage
        let from: Date
        let to: Date
    }

    private static let names = [SleepStaging.Stage.wake, .rem, .core, .deep].map(\.displayName)
    private static let labelWidth: CGFloat = 38

    private var segments: [Segment] {
        var out: [Segment] = []
        var i = 0
        while i < stages.count {
            guard let s = stages[i] else { i += 1; continue }
            var j = i
            while j < stages.count && stages[j] == s { j += 1 }
            out.append(Segment(id: i, stage: s, from: start.addingTimeInterval(Double(i) * epochSeconds),
                               to: start.addingTimeInterval(Double(j) * epochSeconds)))
            i = j
        }
        return out
    }

    var body: some View {
        Chart(segments) { seg in
            RectangleMark(xStart: .value("von", seg.from), xEnd: .value("bis", seg.to),
                          y: .value("Phase", seg.stage.displayName), height: .ratio(compact ? 1 : 0.3))
                .foregroundStyle(Theme.color(seg.stage))
                .cornerRadius(compact ? 0 : 2)
        }
        .chartYScale(domain: Self.names)
        // Phasennamen selbst zeichnen, genau auf der Mitte ihres Balkens (die Achsenbeschriftung
        // von Charts saß leicht versetzt)
        .chartYAxis(.hidden)
        .chartOverlay { proxy in
            if !compact {
                GeometryReader { g in
                    if let frame = proxy.plotFrame {
                        let plot = g[frame]
                        ForEach(Self.names, id: \.self) { name in
                            if let y = proxy.position(forY: name) {
                                Text(name)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.mist)
                                    .lineLimit(1)
                                    .frame(width: Self.labelWidth, alignment: .leading)
                                    .position(x: plot.minX - Self.labelWidth / 2 - 6, y: plot.minY + y)
                            }
                        }
                    }
                }
            }
        }
        .padding(.leading, compact ? 0 : Self.labelWidth + 6)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour)) { _ in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel(format: .dateTime.hour()).foregroundStyle(Theme.mist)
            }
        }
        .chartXAxis(compact ? .hidden : .automatic)
        .chartLegend(.hidden)
    }
}
