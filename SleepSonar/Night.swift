import Foundation

/// Eine aufgenommene Nacht: der Ordner unter Documents/Nights und alles, was darin liegt.
/// Einzige Stelle, die Dateinamen, Spalten und die Zeitquellen (Start, Ton-Beginn, Ende) kennt.
///
/// Ordnerinhalt:
/// - `audio_000.m4a` …     AAC, 16 kHz mono, je Datei höchstens eine Stunde (nach 24 h gelöscht)
/// - `audio_index.csv`     `file,start` – Startzeit jeder Audiodatei
/// - `levels.csv`          `time,rms_db,peak_db,low_250hz_db,mid_1200hz_db,high_4500hz_db` je Sekunde
/// - `motion.csv`          `time,activity_g,max_delta_g,pitch_deg,roll_deg`
/// - `gaps.csv`            `from_s,to_s` – mit Stille aufgefüllte Aussetzer (Sekunden auf der Ton-Zeitachse)
/// - `sounds.csv`          `seconds,state` – eigene Schlafklänge an/aus (Sekunden seit Start)
/// - `events.log`          Protokoll der Aufnahme (Zeitstempel, zwei Leerzeichen, Text)
/// - `meta.json`           Start, Ende, Gerät, Version, Aussetzer
/// - `model.json`          Schlafphasen des Modells (Cache)
/// - `summary.json`        Kurzfassung für die Liste
/// - `events.json`         erkannte Geräusche, `events_partial.json` während der Erkennung
/// - `donation.json`       Stand der Datenspende
/// - `analysis_attempts`   Zahl der Auswertungsversuche je App-Build
/// - `spende_mel.f16`      grobes Klangbild (Float16-Log-Mel) für die Spende, 7 Tage
/// - `watch_sleep.csv`     Schlafphasen aus Health (Export)
/// - `klang_ref.csv`       Bezugspegel der Schlafklänge (Test der Echo-Entfernung)
struct Night: Hashable, Sendable, Identifiable {
    let folder: URL
    var id: URL { folder }

    init(_ folder: URL) { self.folder = folder }

    enum File: String, CaseIterable, Sendable {
        case audioIndex = "audio_index.csv", levels = "levels.csv", motion = "motion.csv", gaps = "gaps.csv"
        case sounds = "sounds.csv", log = "events.log", meta = "meta.json", model = "model.json"
        case summary = "summary.json", soundEvents = "events.json", soundEventsPartial = "events_partial.json"
        case donation = "donation.json", analysisAttempts = "analysis_attempts"
        case mel = "spende_mel.f16", watchSleep = "watch_sleep.csv", soundReference = "klang_ref.csv"
    }

    func url(_ file: File) -> URL { folder.appendingPathComponent(file.rawValue) }
    func exists(_ file: File) -> Bool { FileManager.default.fileExists(atPath: url(file).path) }
    func text(_ file: File) -> String? { try? String(contentsOf: url(file), encoding: .utf8) }

    var name: String { folder.lastPathComponent }
    var isPresent: Bool { FileManager.default.fileExists(atPath: folder.path) }

    /// Audiodateien in Aufnahme-Reihenfolge
    var audioFiles: [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "m4a" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    var hasAudio: Bool { !audioFiles.isEmpty }

    // MARK: meta.json

    /// Inhalt von meta.json (freie Schlüssel, die der Recorder schreibt)
    var meta: [String: Any] {
        guard let data = try? Data(contentsOf: url(.meta)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    func writeMeta(_ meta: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url(.meta), options: .atomic)
    }

    // MARK: Zeiten

    /// Beginn der Aufnahme (meta.json „start“)
    var start: Date? { (meta["start"] as? String).flatMap(Self.date) }

    /// Beginn des Tons (erste Zeile in audio_index.csv), sonst Beginn der Aufnahme.
    /// Darauf beziehen sich die 30-s-Epochen des Modells, die Watch-Phasen der Spende und der Export.
    var audioStart: Date? {
        if let text = text(.audioIndex) {
            let lines = text.split(separator: "\n")
            if lines.count > 1, let s = lines[1].split(separator: ",").last, let d = Self.date(String(s)) { return d }
        }
        return start
    }

    /// Ende der Nacht: meta.json „end“, sonst die letzte Änderung einer Audiodatei
    var end: Date? {
        if let e = meta["end"] as? String, let d = Self.date(e) { return d }
        return audioFiles
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
    }

    var created: Date {
        (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    // MARK: Zeitstempel

    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

    /// ISO 8601 mit Sekundenbruchteilen, wie alle Dateien der Nacht
    static func timestamp(_ date: Date, fractionalSeconds: Bool = true) -> String {
        fractionalSeconds ? fractional.format(date) : whole.format(date)
    }

    /// liest Zeitstempel mit oder ohne Sekundenbruchteile
    static func date(_ text: String) -> Date? {
        (try? fractional.parse(text)) ?? (try? whole.parse(text))
    }

    /// Erste Spalte (Zeitstempel) jeder Zeile einer CSV-Datei ohne Kopfzeile
    func timestamps(_ file: File) -> [Date] {
        guard let text = text(file) else { return [] }
        return text.split(separator: "\n").dropFirst().compactMap { line in
            guard let comma = line.firstIndex(of: ",") else { return nil }
            return Self.date(String(line[..<comma]))
        }
    }

    /// Spalte `column` je Zeile als Zahl (fehlende/kaputte Werte werden übergangen)
    func column(_ file: File, _ column: Int) -> [Float] {
        guard let text = text(file) else { return [] }
        return text.split(separator: "\n").dropFirst().compactMap { line in
            let cols = line.split(separator: ",")
            return cols.count > column ? Float(cols[column]) : nil
        }
    }
}

enum Device {
    /// Gerätekennung wie „iPhone17,1“
    static let model: String = {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }()
}
