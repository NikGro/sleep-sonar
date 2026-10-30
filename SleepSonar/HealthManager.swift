import Foundation
import HealthKit

/// Kapselt den Zugriff auf Apple Health (Schlafanalyse).
@MainActor
final class HealthManager: ObservableObject {
    private let store = HKHealthStore()
    private let sleepType = HKCategoryType(.sleepAnalysis)

    @Published var log: [String] = []

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private func say(_ line: String) {
        log.insert(line, at: 0)
    }

    // MARK: - Berechtigung

    func requestAuthorization() async {
        guard isAvailable else {
            say("❌ Health ist auf diesem Gerät nicht verfügbar.")
            return
        }
        do {
            try await store.requestAuthorization(toShare: [sleepType], read: [sleepType])
            switch store.authorizationStatus(for: sleepType) {
            case .sharingAuthorized:
                say("✅ Schreibzugriff auf Schlaf erlaubt.")
            case .sharingDenied:
                say("⚠️ Schreibzugriff verweigert. Health → Profil → Apps → SleepSonar → Schlaf aktivieren.")
            default:
                say("⚠️ Berechtigung noch nicht festgelegt.")
            }
        } catch {
            // Fehlt das HealthKit-Entitlement in der Signatur, landet man hier.
            say("❌ Berechtigungsfehler: \(error.localizedDescription)")
        }
    }

    // MARK: - Testnacht schreiben

    /// Schreibt eine erfundene Nacht (gestern 23:00 bis heute 07:00) mit allen Phasen.
    func writeTestNight() async {
        let cal = Calendar.current
        guard let start = cal.date(byAdding: .hour, value: -1, to: cal.startOfDay(for: Date())) else { return }

        // (Phase, Dauer in Minuten) – Summe = 480 min = 8 h
        let plan: [(HKCategoryValueSleepAnalysis, Int)] = [
            (.awake, 15), (.asleepCore, 45), (.asleepDeep, 60), (.asleepCore, 40),
            (.asleepREM, 25), (.asleepCore, 50), (.asleepDeep, 40), (.asleepCore, 35),
            (.asleepREM, 35), (.awake, 5), (.asleepCore, 50), (.asleepREM, 45),
            (.asleepCore, 25), (.awake, 10)
        ]

        let metadata: [String: Any] = ["SleepSonarTest": true]
        var samples: [HKCategorySample] = []
        var cursor = start
        for (value, minutes) in plan {
            let end = cursor.addingTimeInterval(TimeInterval(minutes * 60))
            samples.append(HKCategorySample(type: sleepType, value: value.rawValue,
                                            start: cursor, end: end, metadata: metadata))
            cursor = end
        }
        // Gesamtzeitraum zusätzlich als "Im Bett"
        samples.append(HKCategorySample(type: sleepType,
                                        value: HKCategoryValueSleepAnalysis.inBed.rawValue,
                                        start: start, end: cursor, metadata: metadata))

        do {
            try await store.save(samples)
            say("✅ Testnacht geschrieben (\(samples.count) Einträge). Jetzt in Health → Schlaf nachsehen.")
        } catch {
            say("❌ Schreiben fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    // MARK: - Zurücklesen

    /// Liest alle Schlaf-Einträge dieser App der letzten 48 h und summiert sie je Phase.
    func readBack() async {
        let since = Date().addingTimeInterval(-48 * 3600)
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: since, end: Date()),
            HKQuery.predicateForObjects(from: HKSource.default())
        ])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: sleepType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        do {
            let results = try await descriptor.result(for: store)
            if results.isEmpty {
                say("ℹ️ Keine eigenen Schlaf-Einträge der letzten 48 h gefunden.")
                return
            }
            var minutes: [Int: Double] = [:]
            for s in results {
                minutes[s.value, default: 0] += s.endDate.timeIntervalSince(s.startDate) / 60
            }
            let lines = minutes.sorted { $0.key < $1.key }.map { key, value in
                "\(Self.name(for: key)): \(Int(value)) min"
            }
            say("📊 Gelesen: " + lines.joined(separator: " · "))
        } catch {
            say("❌ Lesen fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    // MARK: - Aufräumen

    func deleteOwnSamples() async {
        let predicate = HKQuery.predicateForObjects(from: HKSource.default())
        let type = sleepType
        let store = self.store
        do {
            let count: Int = try await withCheckedThrowingContinuation { cont in
                store.deleteObjects(of: type, predicate: predicate) { _, count, error in
                    if let error { cont.resume(throwing: error) } else { cont.resume(returning: count) }
                }
            }
            say("🗑️ \(count) Einträge von SleepSonar gelöscht.")
        } catch {
            say("❌ Löschen fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    static func name(for raw: Int) -> String {
        switch HKCategoryValueSleepAnalysis(rawValue: raw) {
        case .inBed: return "Im Bett"
        case .awake: return "Wach"
        case .asleepCore: return "Kern"
        case .asleepDeep: return "Tief"
        case .asleepREM: return "REM"
        case .asleepUnspecified: return "Schlafend"
        default: return "Unbekannt (\(raw))"
        }
    }
}
