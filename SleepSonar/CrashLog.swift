import Foundation
import MetricKit

/// Sammelt Absturzprotokolle über MetricKit (iOS liefert sie beim nächsten Start) und hält die letzten
/// fünf aus den vergangenen 30 Tagen bereit – nur für „Fehler melden“, nichts wird automatisch gesendet.
/// Inhalt: Programmablauf beim Absturz, Gerät, iOS-Version; keine Aufnahmen, keine Schlafdaten.
final class CrashLog: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = CrashLog()
    private static let keep = 5
    private static let maxAge: TimeInterval = 30 * 86400
    static let maxBytes = 60 * 1024                    // je Protokoll, damit ein Bericht klein bleibt

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Absturzprotokolle", isDirectory: true)
    }

    func start() {
        MXMetricManager.shared.add(self)
        store(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) { store(payloads) }

    private func store(_ payloads: [MXDiagnosticPayload]) {
        let crashes = payloads.flatMap { p in (p.crashDiagnostics ?? []).map { (p.timeStampEnd, $0) } }
        guard !crashes.isEmpty else { return }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        for (i, (time, crash)) in crashes.enumerated() {
            let url = Self.folder.appendingPathComponent("\(f.string(from: time))-\(i).json")
            if !FileManager.default.fileExists(atPath: url.path) { try? crash.jsonRepresentation().write(to: url) }
        }
        Self.prune()
    }

    /// nur die neuesten `keep` aus den letzten 30 Tagen behalten
    static func prune() {
        let files = list()
        for (i, f) in files.enumerated() where i >= keep || Date().timeIntervalSince(f.date) > maxAge {
            try? FileManager.default.removeItem(at: f.url)
        }
    }

    static func list() -> [(url: URL, date: Date)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
    }

    /// Protokolle für einen Bericht (neueste zuerst, je höchstens `maxBytes`)
    static func recent() -> [String] {
        prune()
        return list().prefix(keep).compactMap { f in
            guard let data = try? Data(contentsOf: f.url), let text = String(data: data, encoding: .utf8) else { return nil }
            return String(text.prefix(maxBytes))
        }
    }
}
