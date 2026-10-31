import AVFoundation
import Foundation
import SoundAnalysis

/// Geräusche der Nacht (Schnarchen, Sprechen, Husten …) mit Apples eingebauter Geräuscherkennung.
///
/// Läuft nach der Aufnahme über die stündlichen m4a-Dateien (nur auf dem Gerät) und speichert
/// das Ergebnis als `events.json` im Ordner der Nacht. Die Clips werden nicht ausgeschnitten:
/// Abgespielt wird direkt aus der Nachtaufnahme an der passenden Stelle.
struct SoundEvent: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case snoring, talking, coughing, gasping, animal, noise

        var name: String {
            switch self {
            case .snoring: "Schnarchen"
            case .talking: "Sprechen"
            case .coughing: "Husten und Niesen"
            case .gasping: "Luftschnappen"
            case .animal: "Tiere"
            case .noise: "Auffällige Geräusche"
            }
        }

        var symbol: String {
            switch self {
            case .snoring: "zzz"
            case .talking: "bubble.left"
            case .coughing: "lungs"
            case .gasping: "wind"
            case .animal: "pawprint"
            case .noise: "speaker.wave.2"
            }
        }

        /// Schlafgeräusch (zählt nicht als Unruhe) oder Wachgeräusch (zählt als Unruhe)?
        var meansSleep: Bool { self == .snoring || self == .gasping }
        var meansWake: Bool { self == .talking || self == .coughing }

        /// Apple-Klassen (SNClassifierIdentifier.version1), die zu dieser Art gehören
        var labels: Set<String> {
            switch self {
            case .snoring: ["snoring"]
            case .talking: ["speech", "whispering", "shout", "yell", "laughter", "giggling", "chuckle_chortle",
                            "crying_sobbing", "screaming", "singing", "humming"]
            case .coughing: ["cough", "sneeze", "nose_blowing", "throat_clearing"]
            case .gasping: ["gasp"]
            case .animal: ["dog", "dog_bark", "dog_whimper", "dog_growl", "cat", "cat_meow", "cat_purr"]
            case .noise: ["door", "door_slam", "knock", "door_bell", "alarm_clock", "telephone", "ringtone",
                          "glass_breaking", "smoke_detector", "siren", "baby_crying"]
            }
        }

        var threshold: Double {
            switch self {
            case .snoring: 0.5
            case .talking: 0.6
            default: 0.5
            }
        }
    }

    let kind: Kind
    /// Sekunden ab Aufnahmebeginn
    let start: Double
    let end: Double
    /// höchste Sicherheit der Erkennung (0…1)
    let confidence: Double

    var id: String { "\(kind.rawValue)-\(Int(start * 10))" }
    var duration: Double { end - start }
}

struct SoundEventFile: Codable {
    static let currentVersion = 1
    var version: Int
    var events: [SoundEvent]
}

enum SoundEventDetector {
    static func fileURL(_ folder: URL) -> URL { folder.appendingPathComponent("events.json") }

    /// Bereits ausgewertete Geräusche (oder nil, wenn noch nicht ausgewertet).
    static func cached(in folder: URL) -> [SoundEvent]? {
        guard let data = try? Data(contentsOf: fileURL(folder)),
              let file = try? JSONDecoder().decode(SoundEventFile.self, from: data),
              file.version == SoundEventFile.currentVersion else { return nil }
        return file.events
    }

    /// Wertet alle Audiodateien der Nacht aus. `progress` bekommt 0…1.
    static func analyze(folder: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [SoundEvent] {
        if let c = cached(in: folder) { return c }
        let files = NightExport.audioFiles(in: folder)
        let events = try await Task.detached(priority: .userInitiated) { () throws -> [SoundEvent] in
            var windows: [(kind: SoundEvent.Kind, start: Double, end: Double, conf: Double)] = []
            for (i, url) in files.enumerated() {
                // Dateiname audio_NNN.m4a: jede Datei deckt genau eine Stunde ab
                let idx = Int(url.deletingPathExtension().lastPathComponent.split(separator: "_").last ?? "") ?? i
                let offset = Double(idx) * PassiveRecorder.secondsPerFile
                let analyzer = try SNAudioFileAnalyzer(url: url)
                let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
                request.overlapFactor = 0.5
                let observer = Collector()
                try analyzer.add(request, withObserver: observer)
                analyzer.analyze()
                for w in observer.windows {
                    windows.append((w.kind, w.start + offset, w.end + offset, w.conf))
                }
                progress(Double(i + 1) / Double(max(1, files.count)))
            }
            return merge(windows)
        }.value
        let data = try JSONEncoder().encode(SoundEventFile(version: SoundEventFile.currentVersion, events: events))
        try? data.write(to: fileURL(folder))
        return events
    }

    /// Fenster gleicher Art mit weniger als 20 s Abstand zu einer Episode zusammenfassen.
    static func merge(_ windows: [(kind: SoundEvent.Kind, start: Double, end: Double, conf: Double)]) -> [SoundEvent] {
        var out: [SoundEvent] = []
        for kind in SoundEvent.Kind.allCases {
            let ws = windows.filter { $0.kind == kind }.sorted { $0.start < $1.start }
            var cur: (start: Double, end: Double, conf: Double)?
            for w in ws {
                if let c = cur, w.start - c.end <= 20 {
                    cur = (c.start, max(c.end, w.end), max(c.conf, w.conf))
                } else {
                    if let c = cur { out.append(SoundEvent(kind: kind, start: c.start, end: c.end, confidence: c.conf)) }
                    cur = (w.start, w.end, w.conf)
                }
            }
            if let c = cur { out.append(SoundEvent(kind: kind, start: c.start, end: c.end, confidence: c.conf)) }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Sekunden-Markierungen für die Regeln.
    static func marks(_ events: [SoundEvent]) -> (sleep: Set<Int>, wake: Set<Int>) {
        var sleep = Set<Int>(), wake = Set<Int>()
        for e in events {
            let range = Int(e.start)..<max(Int(e.start) + 1, Int(e.end.rounded(.up)))
            if e.kind.meansSleep { sleep.formUnion(range) }
            if e.kind.meansWake { wake.formUnion(range) }
        }
        return (sleep, wake)
    }

    private final class Collector: NSObject, SNResultsObserving, @unchecked Sendable {
        var windows: [(kind: SoundEvent.Kind, start: Double, end: Double, conf: Double)] = []

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let r = result as? SNClassificationResult else { return }
            let start = r.timeRange.start.seconds
            let end = start + r.timeRange.duration.seconds
            for kind in SoundEvent.Kind.allCases {
                var best = 0.0
                for label in kind.labels {
                    if let c = r.classification(forIdentifier: label)?.confidence { best = max(best, c) }
                }
                if best >= kind.threshold { windows.append((kind, start, end, best)) }
            }
        }

        func request(_ request: SNRequest, didFailWithError error: Error) {}
        func requestDidComplete(_ request: SNRequest) {}
    }
}

/// Spielt einen Ausschnitt der Nachtaufnahme ab (2 s Vorlauf, höchstens 20 s).
@MainActor
final class NightClipPlayer: ObservableObject {
    @Published private(set) var playingID: String?
    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?

    func toggle(_ event: SoundEvent, folder: URL) {
        if playingID == event.id { stop(); return }
        stop()
        let file = Int(event.start / PassiveRecorder.secondsPerFile)
        let url = folder.appendingPathComponent(String(format: "audio_%03d.m4a", file))
        guard FileManager.default.fileExists(atPath: url.path),
              let p = try? AVAudioPlayer(contentsOf: url) else { return }
        if !PassiveNightEngine.shared.isRunning {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        let local = event.start - Double(file) * PassiveRecorder.secondsPerFile
        p.currentTime = max(0, local - 2)
        p.volume = 1
        p.play()
        player = p
        playingID = event.id
        let length = min(event.duration + 4, 20)
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(length))
            if !Task.isCancelled { self?.stop() }
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        player?.stop()
        player = nil
        playingID = nil
    }
}
