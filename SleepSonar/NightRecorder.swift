import Foundation
import SonarDSP

/// Schreibt eine Nachtmessung in einen eigenen Ordner:
///
/// - `readings.csv`  – Auswertung 2× pro Sekunde
/// - `iq50.bin`      – Sonar-Rohdaten 50 Hz: je Wert Float32 Realteil, Imaginärteil, Sendepegel
///                     (Little Endian, auf den Sendepegel normiert) → nachträglich neu auswertbar
/// - `iq50_index.csv`– Zeitstempel je 50 Werte (1 s), um Lücken nach Neustarts zu erkennen
/// - `motion.csv`    – Beschleunigungssensor, 1× pro Sekunde
/// - `events.log`    – Start, Neustarts, Unterbrechungen, Pegeländerungen …
/// - `meta.json`     – Gerät, Frequenz, Abtastrate, Start/Ende
///
/// Threadsicher: alle Schreibzugriffe laufen über eine serielle Queue.
final class NightRecorder: @unchecked Sendable {
    let folder: URL
    let startDate: Date
    private let queue = DispatchQueue(label: "night.recorder")
    private var readings: FileHandle?
    private var iq: FileHandle?
    private var iqIndex: FileHandle?
    private var motion: FileHandle?
    private var events: FileHandle?
    private var iqBuffer = Data()
    private var iqCount = 0
    private var meta: [String: Any] = [:]
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static var nightsFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nights", isDirectory: true)
    }

    init(meta: [String: Any]) throws {
        startDate = Date()
        let name = DateFormatter.nightName.string(from: startDate)
        folder = Self.nightsFolder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        readings = try Self.open(folder, "readings.csv",
            header: "time,status,breaths_per_min,breath_conf,breath_amp_mm,movement_mm_s,"
                + "heart_bpm,heart_conf,quiet_s,snr,level_db,tx_level,tx_ceiling\n")
        iq = try Self.open(folder, "iq50.bin", header: nil)
        iqIndex = try Self.open(folder, "iq50_index.csv", header: "time,sample_index\n")
        motion = try Self.open(folder, "motion.csv",
            header: "time,activity_g,max_delta_g,pitch_deg,roll_deg\n")
        events = try Self.open(folder, "events.log", header: nil)
        self.meta = meta
        self.meta["start"] = iso.string(from: startDate)
        writeMeta()
    }

    private static func open(_ folder: URL, _ name: String, header: String?) throws -> FileHandle {
        let url = folder.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: header.map { Data($0.utf8) })
        let h = try FileHandle(forWritingTo: url)
        h.seekToEndOfFile()
        return h
    }

    // MARK: - Schreiben

    /// Vom Tap-Thread: ein 50-Hz-Wert.
    func appendIQ(_ z: Complex, gain: Float) {
        var re = Float(z.re), im = Float(z.im), g = gain
        var chunk = Data(capacity: 12)
        withUnsafeBytes(of: &re) { chunk.append(contentsOf: $0) }
        withUnsafeBytes(of: &im) { chunk.append(contentsOf: $0) }
        withUnsafeBytes(of: &g) { chunk.append(contentsOf: $0) }
        let now = Date()
        queue.async {
            if self.iqCount % 50 == 0 {
                self.iqIndex?.write(Data("\(self.iso.string(from: now)),\(self.iqCount)\n".utf8))
            }
            self.iqBuffer.append(chunk)
            self.iqCount += 1
            if self.iqBuffer.count >= 12 * 250 {   // alle 5 s schreiben
                self.iq?.write(self.iqBuffer)
                self.iqBuffer.removeAll(keepingCapacity: true)
            }
        }
    }

    func appendReading(_ r: SonarReading, txLevel: Float, ceiling: Float) {
        let now = Date()
        func f(_ v: Double?, _ d: Int = 2) -> String { v.map { String(format: "%.\(d)f", $0) } ?? "" }
        let line = [
            iso.string(from: now), r.status.rawValue, f(r.breathsPerMinute), f(r.breathConfidence, 3),
            f(r.breathAmplitudeMM), f(r.movementMMPerSecond), f(r.heartBPM, 1), f(r.heartConfidence),
            f(r.quietSeconds, 1), f(r.snr), f(r.levelDB), f(Double(txLevel), 3), f(Double(ceiling), 3)
        ].joined(separator: ",") + "\n"
        queue.async { self.readings?.write(Data(line.utf8)) }
    }

    func appendMotion(activity: Double, maxDelta: Double, pitch: Double, roll: Double) {
        let line = "\(iso.string(from: Date())),\(String(format: "%.5f,%.5f,%.1f,%.1f", activity, maxDelta, pitch, roll))\n"
        queue.async { self.motion?.write(Data(line.utf8)) }
    }

    func event(_ text: String) {
        let line = "\(iso.string(from: Date()))  \(text)\n"
        queue.async { self.events?.write(Data(line.utf8)) }
    }

    func setMeta(_ key: String, _ value: Any) {
        queue.async {
            self.meta[key] = value
            self.writeMeta()
        }
    }

    /// Schließt alle Dateien. Danach nichts mehr schreiben.
    func finish() {
        let end = Date()
        queue.sync {
            if !iqBuffer.isEmpty { iq?.write(iqBuffer); iqBuffer.removeAll() }
            meta["end"] = iso.string(from: end)
            meta["iq_samples"] = iqCount
            writeMeta()
            for h in [readings, iq, iqIndex, motion, events] { try? h?.close() }
            readings = nil; iq = nil; iqIndex = nil; motion = nil; events = nil
        }
    }

    private func writeMeta() {
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("meta.json"))
        }
    }
}

extension DateFormatter {
    static let nightName: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        return f
    }()
}
