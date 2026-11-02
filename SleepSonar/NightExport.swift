import Foundation
import HealthKit

/// Holt die Vergleichsdaten (Apple Watch u. a.) aus Health und packt eine Nacht als ZIP.
enum NightExport {
    private static let store = HKHealthStore()

    private static let quantityTypes: [(HKQuantityTypeIdentifier, HKUnit, String)] = [
        (.heartRate, HKUnit.count().unitDivided(by: .minute()), "heart_rate.csv"),
        (.respiratoryRate, HKUnit.count().unitDivided(by: .minute()), "respiratory_rate.csv"),
        (.heartRateVariabilitySDNN, HKUnit.secondUnit(with: .milli), "hrv_sdnn_ms.csv"),
        (.oxygenSaturation, HKUnit.percent(), "oxygen_saturation.csv"),
    ]

    static func requestAuthorization() async throws {
        var read: Set<HKObjectType> = [HKCategoryType(.sleepAnalysis)]
        for (id, _, _) in quantityTypes { read.insert(HKQuantityType(id)) }
        try await store.requestAuthorization(toShare: [HKCategoryType(.sleepAnalysis)], read: read)
    }

    /// Schreibt die Health-Daten von (start − 2 h) bis (ende + 2 h) in den Ordner der Nacht.
    static func writeHealthData(into folder: URL, from start: Date, to end: Date) async -> [String] {
        var notes: [String] = []
        let iso = ISO8601DateFormatter()
        let predicate = HKQuery.predicateForSamples(withStart: start.addingTimeInterval(-7200),
                                                    end: end.addingTimeInterval(7200))
        do {
            try await requestAuthorization()
        } catch {
            notes.append(tr("Health-Berechtigung: %@", error.localizedDescription))
        }

        // Schlafphasen (alle Quellen, z. B. Apple Watch)
        do {
            let d = HKSampleQueryDescriptor(
                predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
                sortDescriptors: [SortDescriptor(\.startDate)])
            let samples = try await d.result(for: store)
            var csv = "start,end,stage,source,device\n"
            // Suyas eigene Einträge nicht: die Datei ist der Vergleich mit der Watch
            let own = Bundle.main.bundleIdentifier ?? ""
            for s in samples where s.sourceRevision.source.bundleIdentifier != own {
                csv += "\(iso.string(from: s.startDate)),\(iso.string(from: s.endDate)),"
                    + "\(HealthManager.name(for: s.value)),\(clean(s.sourceRevision.source.name)),"
                    + "\(clean(s.device?.model ?? ""))\n"
            }
            try csv.write(to: folder.appendingPathComponent("watch_sleep.csv"), atomically: true, encoding: .utf8)
            notes.append(tr("Schlafphasen: %d Einträge", samples.count))
        } catch {
            notes.append(tr("Schlafphasen: Fehler %@", error.localizedDescription))
        }

        for (id, unit, file) in quantityTypes {
            do {
                let d = HKSampleQueryDescriptor(
                    predicates: [.quantitySample(type: HKQuantityType(id), predicate: predicate)],
                    sortDescriptors: [SortDescriptor(\.startDate)])
                let samples = try await d.result(for: store)
                var csv = "start,end,value,source\n"
                for s in samples {
                    csv += "\(iso.string(from: s.startDate)),\(iso.string(from: s.endDate)),"
                        + "\(s.quantity.doubleValue(for: unit)),\(clean(s.sourceRevision.source.name))\n"
                }
                try csv.write(to: folder.appendingPathComponent("watch_" + file), atomically: true, encoding: .utf8)
                notes.append(tr("%@: %d Werte", file, samples.count))
            } catch {
                notes.append(tr("%@: Fehler %@", file, error.localizedDescription))
            }
        }
        return notes
    }

    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    /// Audiodateien einer Nacht (für separates Teilen).
    static func audioFiles(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "m4a" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Packt den Ordner als ZIP (über NSFileCoordinator, ohne Zusatzbibliothek).
    /// Ohne `includeAudio` werden die Audiodateien weggelassen (klein genug für den Chat).
    static func zip(folder: URL, includeAudio: Bool = false) throws -> URL {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("export_" + folder.lastPathComponent, isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        for f in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        where includeAudio || f.pathExtension != "m4a" {
            try fm.copyItem(at: f, to: staging.appendingPathComponent(f.lastPathComponent))
        }
        let target = fm.temporaryDirectory
            .appendingPathComponent("Suya_\(folder.lastPathComponent)\(includeAudio ? "_mit_Audio" : "").zip")
        try? fm.removeItem(at: target)
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: staging, options: .forUploading, error: &coordError) { zipped in
            do { try FileManager.default.copyItem(at: zipped, to: target) } catch { copyError = error }
        }
        if let e = coordError ?? (copyError as NSError?) { throw e }
        return target
    }
}
