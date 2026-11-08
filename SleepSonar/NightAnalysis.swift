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
        case noModel
        var errorDescription: String? {
            tr("Für diese Nacht gibt es keine Auswertung (der Ton fehlt oder das Modell konnte nicht rechnen).")
        }
    }

    /// Schlafphasen der Nacht aus dem Modell (gespeichert oder neu gerechnet, braucht dann den Ton).
    /// Beginn: erste Audiodatei (darauf beziehen sich die 30-s-Epochen des Modells).
    static func estimate(folder: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) throws
        -> (start: Date, stages: [SleepStaging.Stage], epochSeconds: Double) {
        guard let start = DonationUploader.audioStart(folder) else { throw Failure.noModel }
        let stages: [SleepStaging.Stage]
        if let c = NightModel.cached(folder) {
            stages = c
        } else if NightExport.audioFiles(in: folder).isEmpty, let c = NightModel.cachedAnyVersion(folder) {
            stages = c   // Ton schon gelöscht: das zuletzt gerechnete Ergebnis behalten
        } else {
            guard NightModel.isAvailable, let s = try? NightModel.stages(folder: folder, progress: progress)
            else { throw Failure.noModel }
            stages = s
        }
        guard !stages.isEmpty else { throw Failure.noModel }
        return (start, stages, 30)
    }

    /// Geräusche (erst), dann Modell, dann die Watch-Phasen zum Vergleich.
    static func analyze(folder: URL, sounds: @escaping @Sendable (Double) -> Void = { _ in },
                        model: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> NightAnalysisResult {
        let events = (try? await SoundEventDetector.analyze(folder: folder, progress: sounds)) ?? []
        let (first, ours, epochSeconds) = try await Task.detached(priority: .userInitiated) {
            try estimate(folder: folder, progress: model)
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
    @State private var modelProgress: Double?

    /// ein Zeitraum für alle Zeitstrahlen der Nacht (Suya und Watch)
    private func span(_ r: NightAnalysisResult) -> ClosedRange<Date> {
        let n = max(r.ours.count, r.watch.count, 1)
        return r.start...r.start.addingTimeInterval(Double(n) * r.epochSeconds)
    }
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
                        if let p = modelProgress, p < 1 {
                            ProgressView(value: p).tint(Theme.moon).frame(maxWidth: 220)
                            Text(tr("Das Modell hört die Nacht nach (%d %%). Das passiert einmal je Nacht auf dem iPhone.", Int(p * 100)))
                                .font(.callout).foregroundStyle(Theme.mist)
                        } else if let p = soundProgress, p < 1 {
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
                let r = try await NightAnalyzer.analyze(folder: folder,
                    sounds: { p in Task { @MainActor in soundProgress = p } },
                    model: { p in Task { @MainActor in modelProgress = p } })
                result = r
                // Liste aktuell halten
                NightSummary(start: r.start, stages: r.ours, epochSeconds: r.epochSeconds).save(folder)
            } catch { self.error = error.localizedDescription }
            modelProgress = nil
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
                Text(tr("geschlafen, %@ bis %@", r.start.formatted(date: .omitted, time: .shortened),
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
            Hypnogram(stages: ours, start: r.start, epochSeconds: r.epochSeconds, domain: span(r))
                .frame(height: 112)
            StageLegend()
        }

        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(r.watchSource.isEmpty ? "Apple Watch" : r.watchSource)
            if hasWatch {
                Hypnogram(stages: r.watch, start: r.start, epochSeconds: r.epochSeconds, domain: span(r))
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

        DonationStatusSection(folder: folder)

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
    /// gemeinsamer Zeitraum, damit Regeln, Modell und Watch genau übereinander liegen
    var domain: ClosedRange<Date>? = nil

    private struct Segment: Identifiable {
        let id: Int
        let stage: SleepStaging.Stage
        let from: Date
        let to: Date
    }

    private static let names = [SleepStaging.Stage.wake, .rem, .core, .deep].map(\.displayName)

    private var hourStep: Int {
        let d = domain.map { $0.upperBound.timeIntervalSince($0.lowerBound) } ?? Double(stages.count) * epochSeconds
        return d > 9 * 3600 ? 2 : 1
    }
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
            // nur die Stunde („3“ statt „03 Uhr“, im 12-h-Format „12“ statt „0“), bei langen Nächten jede zweite – sonst überlappen sie
            AxisMarks(values: .stride(by: .hour, count: hourStep)) { v in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel(centered: false, anchor: .top) {
                    if let d = v.as(Date.self) { Text(d.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)))) }
                }
                .foregroundStyle(Theme.mist)
            }
        }
        .chartXAxis(compact ? .hidden : .automatic)
        .chartXScale(domain: domain ?? start...start.addingTimeInterval(max(1, Double(stages.count)) * epochSeconds))
        .chartLegend(.hidden)
    }
}


/// Stand der Datenspende dieser Nacht (nur wenn du spendest).
struct DonationStatusSection: View {
    let folder: URL
    @ObservedObject private var donation = DataDonation.shared
    @ObservedObject private var uploader = DonationUploader.shared
    @State private var state: NightDonationState?

    private var working: Bool { uploader.active == folder }

    var body: some View {
        if donation.state == .granted {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(tr("Datenspende"))
                if working {
                    if let p = uploader.progress {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(uploader.phase ?? tr("Wird vorbereitet und übertragen …"))
                                Spacer()
                                Text("\(Int(p * 100)) %").monospacedDigit()
                            }
                            .font(.callout).foregroundStyle(Theme.mist)
                            ProgressView(value: p).tint(Theme.moon)
                        }
                    } else {
                        HStack(spacing: 10) {
                            ProgressView().tint(Theme.moon)
                            Text(uploader.phase ?? tr("Wird vorbereitet und übertragen …")).font(.callout).foregroundStyle(Theme.mist)
                        }
                    }
                } else {
                    Text(text).font(.callout).foregroundStyle(Theme.mist)
                    // gesendet → erneut senden; noch nicht gespendet (z. B. vor der Zustimmung) → von Hand spenden
                    if DonationUploader.canResend(folder), state?.waiting == nil || state?.sent != nil {
                        Button(state?.sent != nil ? tr("Erneut senden") : tr("Diese Nacht spenden")) { resend() }
                            .font(.callout).tint(Theme.moon)
                    }
                }
            }
            .task { state = NightDonationState.existing(folder) }
            .onChange(of: working) { _, w in if !w { state = NightDonationState.existing(folder) } }
        }
    }

    private var text: String {
        guard let state else { return tr("Wird nach dem Aufwachen vorbereitet und im WLAN gesendet.") }
        if let sent = state.sent {
            return tr("Gespendet am %@.", sent.formatted(date: .abbreviated, time: .shortened))
        }
        if state.skipped == NightDonationState.beforeConsent, DonationUploader.canResend(folder) {
            return tr("Vor deiner Zustimmung aufgenommen – wird nicht automatisch gespendet. Du kannst sie von Hand spenden.")
        }
        if let s = state.skipped { return NightDonationState.reasonText(s) }
        if let w = state.waiting { return NightDonationState.reasonText(w) }
        return NightDonationState.reasonText(NightDonationState.converting)
    }

    private func resend() {
        Task { await DonationUploader.shared.resend(folder) }
    }
}
