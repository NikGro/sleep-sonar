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
            notes.append("Health-Berechtigung: \(error.localizedDescription)")
        }

        // Schlafphasen (alle Quellen, z. B. Apple Watch)
        do {
            let d = HKSampleQueryDescriptor(
                predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
                sortDescriptors: [SortDescriptor(\.startDate)])
            let samples = try await d.result(for: store)
            var csv = "start,end,stage,source,device\n"
            for s in samples {
                csv += "\(iso.string(from: s.startDate)),\(iso.string(from: s.endDate)),"
                    + "\(HealthManager.name(for: s.value)),\(clean(s.sourceRevision.source.name)),"
                    + "\(clean(s.device?.model ?? ""))\n"
            }
            try csv.write(to: folder.appendingPathComponent("watch_sleep.csv"), atomically: true, encoding: .utf8)
            notes.append("Schlafphasen: \(samples.count) Einträge")
        } catch {
            notes.append("Schlafphasen: Fehler \(error.localizedDescription)")
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
                notes.append("\(file): \(samples.count) Werte")
            } catch {
                notes.append("\(file): Fehler \(error.localizedDescription)")
            }
        }
        return notes
    }

    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    /// Packt den Ordner als ZIP (über NSFileCoordinator, ohne Zusatzbibliothek).
    static func zip(folder: URL) throws -> URL {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("SleepSonar_\(folder.lastPathComponent).zip")
        try? FileManager.default.removeItem(at: target)
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordError) { zipped in
            do { try FileManager.default.copyItem(at: zipped, to: target) } catch { copyError = error }
        }
        if let e = coordError ?? (copyError as NSError?) { throw e }
        return target
    }
}
