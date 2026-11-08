import AVFoundation
import CoreML
import Foundation
import SonarDSP

/// Schlafphasen aus dem gelernten Modell (Labor + eigene Nächte, siehe training/).
///
/// Ablauf je Nacht: Ton der Aufnahme (16 kHz) in 10-min-Stücken lesen → Log-Mel wie im Training
/// (SonarDSP.LogMel) → je 30-s-Epoche Merkmale (SuyaEpochEncoder) → ganze Nacht auf einmal
/// (SuyaNightSequence) → Wach/REM/Kern/Tief. Das Ergebnis wird je Nacht in model.json gespeichert.
enum NightModel {
    /// erhöhen, wenn ein neues Modell eingebaut wird → Nächte werden neu berechnet
    static let version = 2   // 2: Zeiten mit eigenen Schlafklängen ausgeblendet

    private struct Cache: Codable { var version: Int; var stages: String }

    static func cached(_ folder: URL) -> [SleepStaging.Stage]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("model.json")),
              let c = try? JSONDecoder().decode(Cache.self, from: data), c.version == version else { return nil }
        return c.stages.compactMap { $0.wholeNumberValue.flatMap(SleepStaging.Stage.init) }
    }

    static var isAvailable: Bool {
        Bundle.main.url(forResource: "SuyaEpochEncoder", withExtension: "mlmodelc") != nil
            && Bundle.main.url(forResource: "SuyaNightSequence", withExtension: "mlmodelc") != nil
    }

    enum Failure: Error { case noAudio, noModel }

    /// Rechnet die Nacht (dauert je nach iPhone etwa eine Minute). `progress`: 0 … 1
    static func stages(folder: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) throws
        -> [SleepStaging.Stage] {
        if let c = cached(folder) { return c }
        let files = NightExport.audioFiles(in: folder)
        guard !files.isEmpty else { throw Failure.noAudio }
        guard let encURL = Bundle.main.url(forResource: "SuyaEpochEncoder", withExtension: "mlmodelc"),
              let seqURL = Bundle.main.url(forResource: "SuyaNightSequence", withExtension: "mlmodelc")
        else { throw Failure.noModel }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let encoder = try MLModel(contentsOf: encURL, configuration: config)
        let sequence = try MLModel(contentsOf: seqURL, configuration: config)

        // 1) Log-Mel in 10-min-Stücken über alle Dateien hinweg (wie die zusammengefügte Datei im Training)
        var frames = try melFrames(files: files) { progress(0.7 * $0) }
        let n = frames.count / LogMel.framesPerEpoch
        let values = LogMel.normalize(frames, epochs: n, masked: soundFrames(folder))
        frames = []

        // 2) Merkmale je Epoche, in Paketen
        let per = LogMel.bands * LogMel.framesPerEpoch
        let embed = try MLMultiArray(shape: [1, NSNumber(value: n), 96], dataType: .float32)
        let eptr = embed.dataPointer.bindMemory(to: Float.self, capacity: n * 96)
        let batch = 64
        var e0 = 0
        while e0 < n {
            let b = min(batch, n - e0)
            let input = try MLMultiArray(shape: [NSNumber(value: b), 1, 64, 300], dataType: .float32)
            let iptr = input.dataPointer.bindMemory(to: Float.self, capacity: b * per)
            values.withUnsafeBufferPointer { src in
                iptr.update(from: src.baseAddress! + e0 * per, count: b * per)
            }
            let out = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mel": input]))
            guard let emb = out.featureValue(for: "embedding")?.multiArrayValue else { throw Failure.noModel }
            for i in 0..<b { for j in 0..<96 { eptr[(e0 + i) * 96 + j] = emb[[NSNumber(value: i), NSNumber(value: j)]].floatValue } }
            e0 += b
            progress(0.7 + 0.28 * Double(e0) / Double(n))
        }

        // 3) ganze Nacht
        let out = try sequence.prediction(from: MLDictionaryFeatureProvider(dictionary: ["embeddings": embed]))
        guard let p = out.featureValue(for: "probabilities")?.multiArrayValue else { throw Failure.noModel }
        var stages: [SleepStaging.Stage] = []
        stages.reserveCapacity(n)
        for t in 0..<n {
            var best = 0, bv = -Float.infinity
            for c in 0..<4 {
                let v = p[[0, NSNumber(value: t), NSNumber(value: c)]].floatValue
                if v > bv { bv = v; best = c }
            }
            stages.append(SleepStaging.Stage(rawValue: best) ?? .core)   // 0 Wach, 1 REM, 2 Kern, 3 Tief
        }
        let cache = Cache(version: version, stages: String(stages.map { Character(String($0.rawValue)) }))
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: folder.appendingPathComponent("model.json"), options: .atomic)
        }
        progress(1)
        return stages
    }
}

extension NightModel {
    /// Roh-Log-Mel der ganzen Nacht (10 Bilder je Sekunde, 64 Bänder), auf ganze 30-s-Epochen gekürzt –
    /// genau die Eingabe des Trainings. Auch für die Datenspende.
    static func melFrames(files: [URL], progress: (Double) -> Void = { _ in }) throws -> [[Float]] {
        let sr = LogMel.sampleRate
        let total = files.reduce(0) { $0 + Int((try? AVAudioFile(forReading: $1))?.length ?? 0) }
        let epochs = total / (sr * 30)
        guard epochs >= 20 else { throw Failure.noAudio }
        let usable = epochs * 30 * sr
        let mel = LogMel()
        var frames: [[Float]] = []
        frames.reserveCapacity(epochs * LogMel.framesPerEpoch)
        var reader = AudioStream(files: files)
        var done = 0
        while done < usable {
            let want = min(sr * LogMel.segmentSeconds, usable - done)
            let chunk = try reader.read(want)
            guard !chunk.isEmpty else { break }
            frames.append(contentsOf: mel.segment(chunk))
            done += chunk.count
            progress(Double(done) / Double(usable))
        }
        let n = min(epochs, frames.count / LogMel.framesPerEpoch)
        guard n >= 20 else { throw Failure.noAudio }
        return Array(frames.prefix(n * LogMel.framesPerEpoch))
    }

    /// Bild-Bereiche (10 je Sekunde), in denen eigene Schlafklänge liefen – aus sounds.csv, für
    /// ältere Nächte aus dem Protokoll. Etwas Rand davor, Ausblenden (30 s) und Nachhall danach.
    static func soundFrames(_ folder: URL) -> [Range<Int>] {
        var marks: [(Double, Bool)] = []
        if let text = try? String(contentsOf: folder.appendingPathComponent("sounds.csv"), encoding: .utf8) {
            for line in text.split(separator: "\n").dropFirst() {
                let c = line.split(separator: ",")
                if c.count == 2, let s = Double(c[0]) { marks.append((s, c[1] == "an")) }
            }
        } else if let log = try? String(contentsOf: folder.appendingPathComponent("events.log"), encoding: .utf8),
                  let meta = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
                  let obj = try? JSONSerialization.jsonObject(with: meta) as? [String: Any],
                  let startText = obj["start"] as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let start = iso.date(from: startText) else { return [] }
            for line in log.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2, let t = iso.date(from: String(parts[0])) else { continue }
                let text = parts[1].trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("Klänge an") || text.hasPrefix("Sounds on") { marks.append((t.timeIntervalSince(start), true)) }
                if text.hasPrefix("Klänge aus") || text.hasPrefix("Sounds off") { marks.append((t.timeIntervalSince(start), false)) }
            }
        }
        var out: [Range<Int>] = []
        var on: Double?
        for (s, isOn) in marks.sorted(by: { $0.0 < $1.0 }) {
            if isOn { if on == nil { on = s } }
            else if let o = on { out.append(Int((o - 2) * 10)..<Int((s + 35) * 10)); on = nil }
        }
        if let o = on { out.append(Int((o - 2) * 10)..<Int((o + 3 * 3600) * 10)) }   // „aus“ fehlt: höchstens 3 h
        return out
    }
}

/// Liest mehrere Audiodateien nacheinander als einen Strom (Mono, 16 kHz, Float).
private struct AudioStream {
    let files: [URL]
    private var index = 0
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(LogMel.sampleRate),
                                       channels: 1, interleaved: false)!

    init(files: [URL]) { self.files = files }

    mutating func read(_ count: Int) throws -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(count)
        while out.count < count {
            if file == nil {
                guard index < files.count else { break }
                let f = try AVAudioFile(forReading: files[index])
                index += 1
                file = f
                converter = f.processingFormat.sampleRate == target.sampleRate && f.processingFormat.channelCount == 1
                    ? nil : AVAudioConverter(from: f.processingFormat, to: target)
            }
            guard let f = file else { break }
            // Lesen am Dateiende wirft bei AVAudioFile einen Fehler statt 0 Samples zu liefern; eine
            // abgebrochene Datei (z. B. Akku leer) endet ebenso vorzeitig → dann einfach die nächste
            let left = f.length - f.framePosition
            if left <= 0 { file = nil; continue }
            let want = AVAudioFrameCount(min(Int64(count - out.count), min(left, 1 << 18)))
            guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: want) else { break }
            do { try f.read(into: buf, frameCount: want) } catch { file = nil; continue }
            if buf.frameLength == 0 { file = nil; continue }
            if let converter {
                let ratio = target.sampleRate / f.processingFormat.sampleRate
                guard let conv = AVAudioPCMBuffer(pcmFormat: target,
                                                  frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * ratio) + 32)
                else { break }
                var fed = false
                converter.convert(to: conv, error: nil) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true; status.pointee = .haveData; return buf
                }
                if let ch = conv.floatChannelData { out.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(conv.frameLength))) }
            } else if let ch = buf.floatChannelData {
                out.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
            }
        }
        return out
    }
}
