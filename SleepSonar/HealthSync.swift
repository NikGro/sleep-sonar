import Foundation
import HealthKit
import SonarDSP

/// Trägt Suyas Schlafphasen in Apple Health ein – immer, außer die Watch (oder eine andere
/// Schlaf-App) hat für dieselbe Nacht schon Schlaf eingetragen: die hat Vorrang.
///
/// Läuft nach dem Ende einer Aufnahme und bei jedem Öffnen der App für die Nächte der letzten
/// 7 Tage. Kommt die Watch-Nacht später an, werden Suyas Einträge dieser Nacht wieder gelöscht.
/// Ändert sich das Modell, werden Suyas Einträge neu geschrieben.
enum HealthSync {
    private static let store = HKHealthStore()
    private static let type = HKCategoryType(.sleepAnalysis)
    /// Metadaten an jedem Eintrag: Ordnername der Nacht und Version der Auswertung (Schlüssel heißt noch „Rules“)
    static let nightKey = "SuyaNight"
    static let rulesKey = "SuyaRules"
    /// kürzere Aufnahmen (z. B. Tests) nicht eintragen
    private static let minAsleep: TimeInterval = 60 * 60
    private static var running = false

    static func syncRecent() async {
        guard HKHealthStore.isHealthDataAvailable(), !running else { return }
        running = true
        defer { running = false }
        try? await store.requestAuthorization(toShare: [type], read: [type])
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: NightRecorder.nightsFolder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        let engine = await MainActor.run { (PassiveNightEngine.shared.isRunning, PassiveNightEngine.shared.folder) }
        for url in dirs where url.hasDirectoryPath {
            if engine.0 && engine.1 == url { continue }   // läuft noch
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            guard created > cutoff else { continue }
            await sync(folder: url)
        }
    }

    static func sync(folder: URL) async {
        // eigene Schätzung (gespeichert oder neu gerechnet)
        let night: (start: Date, stages: [SleepStaging.Stage], epochSeconds: Double)
        if let c = NightSummary.cached(folder), c.isCurrent(for: folder) {
            night = (c.start, c.stages, c.epochSeconds)
        } else {
            guard let e = try? await Task.detached(priority: .utility, operation: {
                try NightAnalyzer.estimate(folder: folder)
            }).value else { return }
            NightSummary(start: e.start, stages: e.stages, epochSeconds: e.epochSeconds).save(folder)
            night = e
        }
        let ep = night.epochSeconds
        let end = night.start.addingTimeInterval(Double(night.stages.count) * ep)
        let range = HKQuery.predicateForSamples(withStart: night.start, end: end)
        guard let samples = try? await HKSampleQueryDescriptor(
            predicates: [.categorySample(type: type, predicate: range)],
            sortDescriptors: [SortDescriptor(\.startDate)]).result(for: store) else { return }

        let own = Bundle.main.bundleIdentifier ?? ""
        let mine = samples.filter { $0.sourceRevision.source.bundleIdentifier == own }
        let asleepValues: Set<Int> = [HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                                      HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                                      HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                                      HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue]
        let foreignSleep = samples.contains {
            $0.sourceRevision.source.bundleIdentifier != own && asleepValues.contains($0.value)
        }

        // Watch hat Vorrang
        if foreignSleep {
            if !mine.isEmpty {
                try? await store.delete(mine)
            }
            return
        }
        // schon in dieser Fassung eingetragen?
        let name = folder.lastPathComponent
        if !mine.isEmpty, mine.allSatisfy({
            ($0.metadata?[nightKey] as? String) == name && ($0.metadata?[rulesKey] as? Int) == NightSummary.currentVersion
        }) { return }

        let stages = night.stages
        guard let first = stages.firstIndex(where: { $0 != .wake }),
              let last = stages.lastIndex(where: { $0 != .wake }),
              Double(stages.filter { $0 != .wake }.count) * ep >= minAsleep else {
            if !mine.isEmpty { try? await store.delete(mine) }
            return
        }
        let meta: [String: Any] = [nightKey: name, rulesKey: NightSummary.currentVersion]
        var out: [HKCategorySample] = [
            HKCategorySample(type: type, value: HKCategoryValueSleepAnalysis.inBed.rawValue,
                             start: night.start, end: end, metadata: meta)
        ]
        // zusammenhängende Phasen vom Einschlafen bis zum Aufwachen
        var i = first
        while i <= last {
            var j = i
            while j <= last && stages[j] == stages[i] { j += 1 }
            out.append(HKCategorySample(type: type, value: value(stages[i]).rawValue,
                                        start: night.start.addingTimeInterval(Double(i) * ep),
                                        end: night.start.addingTimeInterval(Double(j) * ep), metadata: meta))
            i = j
        }
        do {
            if !mine.isEmpty { try await store.delete(mine) }
            try await store.save(out)
        } catch {
            // nächster Versuch beim nächsten Öffnen der App
        }
    }

    private static func value(_ s: SleepStaging.Stage) -> HKCategoryValueSleepAnalysis {
        switch s {
        case .wake: .awake
        case .rem: .asleepREM
        case .core: .asleepCore
        case .deep: .asleepDeep
        }
    }
}
