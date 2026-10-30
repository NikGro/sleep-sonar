@preconcurrency import AVFAudio
import Foundation

/// Nimmt das Mikrofon passiv auf (kein Ton wird gesendet).
///
/// Ordnerinhalt einer Nacht:
/// - `audio_000.m4a`, `audio_001.m4a`, … – AAC, 16 kHz mono, je Datei max. 1 Stunde
/// - `audio_index.csv` – Startzeit jeder Audiodatei
/// - `levels.csv`      – je Sekunde Pegel gesamt und in drei Bändern (dBFS)
/// - `motion.csv`, `events.log`, `meta.json` – wie gehabt
///
/// Alle Audio-Methoden laufen auf dem Tap-Thread, abgesichert per Lock.
final class PassiveRecorder: @unchecked Sendable {
    static let sampleRate = 16_000.0
    static let bitRate = 24_000
    static let secondsPerFile = 3600.0

    let folder: URL
    let startDate: Date
    private let lock = NSLock()
    private let io = DispatchQueue(label: "passive.io")
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: PassiveRecorder.sampleRate,
                                          channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var file: AVAudioFile?
    private var fileIndex = -1
    private var framesInFile: AVAudioFramePosition = 0
    private var finished = false

    // Pegel je Sekunde: gesamt + Bänder (Brummen/Schnarchen, Stimme/Atem, Zischen)
    private var bands = [Biquad.bandpass(f: 250, q: 0.7, fs: PassiveRecorder.sampleRate),
                         Biquad.bandpass(f: 1_200, q: 0.7, fs: PassiveRecorder.sampleRate),
                         Biquad.bandpass(f: 4_500, q: 0.7, fs: PassiveRecorder.sampleRate)]
    private var sumAll = 0.0
    private var sumBand = [0.0, 0.0, 0.0]
    private var peak: Float = 0
    private var count = 0
    private let onSecond: @Sendable (_ db: Double, _ bands: [Double]) -> Void

    private var levels: FileHandle?
    private var audioIndex: FileHandle?
    private var motion: FileHandle?
    private var events: FileHandle?
    private var meta: [String: Any]

    init(meta: [String: Any], onSecond: @escaping @Sendable (Double, [Double]) -> Void) throws {
        startDate = Date()
        folder = NightRecorder.nightsFolder
            .appendingPathComponent(DateFormatter.nightName.string(from: startDate) + "_audio", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.meta = meta
        self.onSecond = onSecond
        levels = try Self.open(folder, "levels.csv", "time,rms_db,peak_db,low_250hz_db,mid_1200hz_db,high_4500hz_db\n")
        audioIndex = try Self.open(folder, "audio_index.csv", "file,start\n")
        motion = try Self.open(folder, "motion.csv", "time,activity_g,max_delta_g,pitch_deg,roll_deg\n")
        events = try Self.open(folder, "events.log", nil)
        self.meta["start"] = iso.string(from: startDate)
        self.meta["mode"] = "passive_audio"
        self.meta["audio_sample_rate"] = Self.sampleRate
        self.meta["audio_bitrate"] = Self.bitRate
        writeMeta()
    }

    private static func open(_ folder: URL, _ name: String, _ header: String?) throws -> FileHandle {
        let url = folder.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: header.map { Data($0.utf8) })
        let h = try FileHandle(forWritingTo: url)
        h.seekToEndOfFile()
        return h
    }

    // MARK: - Audio (Tap-Thread)

    func handle(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        do {
            if converter == nil || converterInput != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: outFormat)
                converterInput = buffer.format
            }
            guard let converter else { return }
            let ratio = Self.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if once.done { status.pointee = .noDataNow; return nil }
                once.done = true
                status.pointee = .haveData
                return buffer
            }
            if let err { throw err }
            guard out.frameLength > 0 else { return }
            try write(out)
            measure(out)
        } catch {
            eventLocked("Audio-Fehler: \(error.localizedDescription)")
        }
    }

    private func write(_ buf: AVAudioPCMBuffer) throws {
        if file == nil || Double(framesInFile) >= Self.secondsPerFile * Self.sampleRate {
            file = nil   // vorherige Datei abschließen
            fileIndex += 1
            let name = String(format: "audio_%03d.m4a", fileIndex)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: Self.bitRate,
            ]
            let url = folder.appendingPathComponent(name)
            do {
                file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            } catch {
                // Falls der Encoder die Bitrate nicht mag: Standard-Bitrate
                var fallback = settings
                fallback.removeValue(forKey: AVEncoderBitRateKey)
                file = try AVAudioFile(forWriting: url, settings: fallback,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
                eventLocked("AAC mit Standard-Bitrate (\(error.localizedDescription))")
            }
            framesInFile = 0
            let line = "\(name),\(iso.string(from: Date()))\n"
            io.async { self.audioIndex?.write(Data(line.utf8)) }
        }
        try file?.write(from: buf)
        framesInFile += AVAudioFramePosition(buf.frameLength)
    }

    private func measure(_ buf: AVAudioPCMBuffer) {
        guard let p = buf.floatChannelData?[0] else { return }
        let n = Int(buf.frameLength)
        for i in 0..<n {
            let x = p[i]
            let xd = Double(x)
            sumAll += xd * xd
            peak = max(peak, abs(x))
            for b in 0..<3 {
                let y = bands[b].process(xd)
                sumBand[b] += y * y
            }
            count += 1
            if count >= Int(Self.sampleRate) {
                func db(_ s: Double) -> Double { 10 * log10(s / Double(count) + 1e-14) }
                let rms = db(sumAll)
                let bandDB = sumBand.map(db)
                let pk = 20 * log10(Double(peak) + 1e-7)
                let line = String(format: "%@,%.1f,%.1f,%.1f,%.1f,%.1f\n",
                                  iso.string(from: Date()), rms, pk, bandDB[0], bandDB[1], bandDB[2])
                io.async { self.levels?.write(Data(line.utf8)) }
                onSecond(rms, bandDB)
                sumAll = 0; sumBand = [0, 0, 0]; peak = 0; count = 0
            }
        }
    }

    // MARK: - Protokoll

    func appendMotion(activity: Double, maxDelta: Double, pitch: Double, roll: Double) {
        let line = "\(iso.string(from: Date())),\(String(format: "%.5f,%.5f,%.1f,%.1f", activity, maxDelta, pitch, roll))\n"
        io.async { self.motion?.write(Data(line.utf8)) }
    }

    func event(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        eventLocked(text)
    }

    private func eventLocked(_ text: String) {
        let line = "\(iso.string(from: Date()))  \(text)\n"
        io.async { self.events?.write(Data(line.utf8)) }
    }

    func setMeta(_ key: String, _ value: Any) {
        io.async {
            self.meta[key] = value
            self.writeMeta()
        }
    }

    func finish() {
        lock.lock()
        finished = true
        file = nil          // AAC-Datei abschließen
        let files = fileIndex + 1
        lock.unlock()
        let end = Date()
        io.sync {
            meta["end"] = iso.string(from: end)
            meta["audio_files"] = files
            writeMeta()
            for h in [levels, audioIndex, motion, events] { try? h?.close() }
            levels = nil; audioIndex = nil; motion = nil; events = nil
        }
    }

    private func writeMeta() {
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("meta.json"))
        }
    }
}

/// Einfacher Biquad-Bandpass (RBJ, konstante Spitzenverstärkung 0 dB).
struct Biquad {
    var b0, b1, b2, a1, a2: Double
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    static func bandpass(f: Double, q: Double, fs: Double) -> Biquad {
        let w = 2 * Double.pi * f / fs
        let alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha
        return Biquad(b0: alpha / a0, b1: 0, b2: -alpha / a0, a1: -2 * cos(w) / a0, a2: (1 - alpha) / a0)
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}
