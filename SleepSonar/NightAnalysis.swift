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

    func minutes(_ stages: [SleepStaging.Stage?], _ s: SleepStaging.Stage) -> Double {
        Double(stages.filter { $0 == s }.count) * epochSeconds / 60
    }
}

enum NightAnalyzer {
    enum Failure: LocalizedError {
        case noLevels
        var errorDescription: String? {
            "Diese Nacht hat keine Pegeldaten (nur Nächte aus der Mikrofon-Aufnahme lassen sich auswerten)."
        }
    }

    static func analyze(folder: URL) async throws -> NightAnalysisResult {
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
        let epochs = SleepStaging.estimate(seconds: seconds, motion: motion, parameters: params)
        let ours = epochs.map(\.stage)
        let epochSeconds = Double(params.epochSeconds)
        let end = first.addingTimeInterval(Double(ours.count) * epochSeconds)

        // Watch-Phasen aus Health (ohne Einträge dieser App)
        let (watch, source) = await watchStages(from: first, to: end, epochs: ours.count, epochSeconds: epochSeconds)
        let agreement = SleepStaging.agreement(ours.map { Optional($0) }, watch)
        return NightAnalysisResult(start: first, epochSeconds: epochSeconds, ours: ours, watch: watch,
                                   watchSource: source, agreement: agreement)
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

    var body: some View {
        List {
            if let error {
                Text(error).foregroundStyle(.red)
            } else if let r = result {
                Section {
                    Text("Erste, regelbasierte Schätzung aus Geräuschen und Handy-Bewegung. "
                         + "Wach/Schlaf ist halbwegs belastbar, Tief und REM sind noch grob.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section("SleepSonar (Mikrofon)") {
                    Hypnogram(stages: r.ours.map { Optional($0) }, start: r.start, epochSeconds: r.epochSeconds)
                        .frame(height: 140)
                }
                Section(r.watchSource.isEmpty ? "Apple Watch (keine Daten gefunden)" : "Apple Watch (\(r.watchSource))") {
                    if r.watch.contains(where: { $0 != nil }) {
                        Hypnogram(stages: r.watch, start: r.start, epochSeconds: r.epochSeconds)
                            .frame(height: 140)
                    } else {
                        Text("Keine Watch-Schlafphasen für diesen Zeitraum in Health. "
                             + "Watch synchronisiert? Health-Zugriff erlaubt?").font(.callout)
                    }
                }
                if r.agreement.epochs > 0 {
                    Section("Übereinstimmung mit der Watch") {
                        LabeledContent("Wach / Schlaf", value: String(format: "%.0f %%", r.agreement.sleepWake * 100))
                        LabeledContent("Alle 4 Phasen", value: String(format: "%.0f %%", r.agreement.fourClass * 100))
                        LabeledContent("Verglichene Zeit",
                                       value: NightView.duration(Double(r.agreement.epochs) * r.epochSeconds))
                    }
                }
                Section("Minuten je Phase") {
                    Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow {
                            Text("").gridColumnAlignment(.leading)
                            Text("SleepSonar").bold()
                            Text("Watch").bold()
                        }
                        ForEach(SleepStaging.Stage.allCases, id: \.self) { s in
                            GridRow {
                                Text(s.name).gridColumnAlignment(.leading)
                                Text("\(Int(r.minutes(r.ours.map { Optional($0) }, s)))")
                                Text(r.watch.contains(where: { $0 != nil }) ? "\(Int(r.minutes(r.watch, s)))" : "–")
                            }
                        }
                    }
                    .font(.callout.monospacedDigit())
                }
            } else {
                HStack { ProgressView(); Text("Werte aus …") }
            }
        }
        .navigationTitle("Auswertung")
        .task {
            do { result = try await NightAnalyzer.analyze(folder: folder) }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct Hypnogram: View {
    let stages: [SleepStaging.Stage?]
    let start: Date
    let epochSeconds: Double

    private struct Segment: Identifiable {
        let id: Int
        let stage: SleepStaging.Stage
        let from: Date
        let to: Date
    }

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
                          y: .value("Phase", seg.stage.name))
                .foregroundStyle(color(seg.stage))
        }
        .chartYScale(domain: ["Wach", "REM", "Kern", "Tief"])
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
    }

    private func color(_ s: SleepStaging.Stage) -> Color {
        switch s {
        case .wake: .orange
        case .rem: .cyan
        case .core: .blue
        case .deep: .indigo
        }
    }
}
