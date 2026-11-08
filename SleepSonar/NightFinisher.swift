import Foundation
import SonarDSP

/// Speicher sparen, für alle: Ist eine Nacht fertig ausgewertet (Geräusche, Modell, Ausschnitte) und 24 Stunden
/// vorbei (so lange lässt sie sich komplett mit Ton exportieren), wird der Ton gelöscht. Vorher wird das grobe Klangbild (Spektrogramm, kein Ton) gesichert und 7 Tage behalten – so lässt sich
/// eine Nacht auch nachträglich spenden. Konnte das Modell nicht rechnen, bleibt der Ton erhalten.
@MainActor
enum NightFinisher {
    /// so lange bleibt das Spektrogramm einer Nacht auf dem iPhone
    static let keepMelDays: Double = 7
    /// so lange bleibt der Ton nach dem Ende der Nacht (Export mit Audio)
    static let keepAudioHours: Double = 24

    /// Ende der Nacht: meta.json „end“, sonst die letzte Änderung einer Audiodatei
    nonisolated static func nightEnd(_ folder: URL) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let e = obj["end"] as? String, let d = iso.date(from: e) { return d }
        return NightExport.audioFiles(in: folder)
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
    }

    /// verbleibende Zeit für den Export mit Audio, z. B. „5 Std., 12 Min.“ (in der Sprache des iPhones)
    nonisolated static func exportTimeLeft(_ folder: URL) -> String? {
        guard canExportAudio(folder) else { return nil }
        let left = max(60, keepAudioHours * 3600 - Date().timeIntervalSince(nightEnd(folder) ?? Date()))
        let f = DateComponentsFormatter()
        f.allowedUnits = left >= 3600 ? [.hour, .minute] : [.minute]
        f.unitsStyle = .short
        f.maximumUnitCount = 2
        return f.string(from: left)
    }

    /// Ton noch da und Nacht keine 24 Stunden her: Export mit Audio möglich
    nonisolated static func canExportAudio(_ folder: URL) -> Bool {
        guard !NightExport.audioFiles(in: folder).isEmpty else { return false }
        guard let end = nightEnd(folder) else { return true }
        return Date().timeIntervalSince(end) < keepAudioHours * 3600
    }
    private static var running = false

    static func run() async {
        guard !running, !PassiveNightEngine.shared.isRunning else { return }
        running = true
        defer { running = false }
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: NightStore.nightsFolder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for folder in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where folder.hasDirectoryPath {
            if PassiveNightEngine.shared.isRunning { break }
            let files = NightExport.audioFiles(in: folder)
            guard !files.isEmpty else { continue }
            if !DonationUploader.hasMel(folder) {
                let ok = await Task.detached(priority: .utility) { DonationUploader.writeMel(folder: folder, files: files) }.value
                guard ok else { continue }
            }
            // Ton erst nach 24 Stunden löschen (bis dahin: Export mit Audio)
            if let end = nightEnd(folder), Date().timeIntervalSince(end) < keepAudioHours * 3600 { continue }
            _ = try? await NightAudioTrim.trim(folder)   // Ton weg, Ausschnitte bleiben; scheitert das Modell, bleibt er
        }
        cleanupMel()
    }

    /// Spektrogramme älterer Nächte löschen (außer eine Spende wartet noch darauf)
    static func cleanupMel() {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: NightStore.nightsFolder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for folder in dirs where DonationUploader.hasMel(folder) {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            guard Date().timeIntervalSince(created) > keepMelDays * 86400 else { continue }
            if let s = NightDonationState.existing(folder), s.waiting != nil, s.sent == nil, s.skipped == nil,
               Date().timeIntervalSince(created) < 14 * 86400 { continue }
            try? FileManager.default.removeItem(at: DonationUploader.melURL(folder))
        }
    }
}
