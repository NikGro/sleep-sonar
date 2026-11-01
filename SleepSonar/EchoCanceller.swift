import Accelerate
import AVFoundation
import Foundation

/// Rechnet die eigenen Schlafklänge aus dem Mikrofon heraus (adaptiver NLMS-Filter, 16 kHz).
///
/// Die Klänge werden direkt am Mischer abgegriffen (Referenz) und mit ihrer Zeit gespeichert.
/// Für jeden Mikrofon-Block lernt der Filter, wie die Referenz nach Lautsprecher, Raum und
/// Mikrofon klingt (4096 Abgriffe = 256 ms), und zieht diese Schätzung ab.
/// In einer Simulation mit Nachhall waren das rund 30 dB weniger Klang im Mikrofon.
/// Nachhall, der länger als 256 ms dauert, bleibt teilweise übrig.
final class EchoCanceller: @unchecked Sendable {
    static let shared = EchoCanceller()

    static let sampleRate = 16_000.0
    private let taps = 4096
    /// so viele Samples „Zukunft“ der Referenz deckt der Filter ab (Zeitstempel sind nicht exakt)
    private let lead = 256
    private let mu: Float = 0.3

    private let lock = NSLock()
    private var ring = [Float](repeating: 0, count: 16_000 * 8)
    private var written = 0                       // Referenz-Samples insgesamt
    private var anchor: (index: Int, host: UInt64)?
    private var weights: [Float]                  // umgekehrt gespeichert: neueste Referenz zuletzt
    private var lastReference = Date.distantPast
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private let refFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                          channels: 1, interleaved: false)!
    private static let ticksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1e9 * Double(info.denom) / Double(info.numer)
    }()

    private init() { weights = [Float](repeating: 0, count: taps) }

    /// Läuft gerade ein Klang? (dann lohnt das Abziehen)
    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastReference) < 1
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        weights = [Float](repeating: 0, count: taps)
        anchor = nil
        written = 0
    }

    // MARK: Referenz (Wiedergabe-Thread)

    func pushReference(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        // auf Mono mischen
        let n = Int(buffer.frameLength), ch = Int(buffer.format.channelCount)
        guard let mono = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                                   sampleRate: buffer.format.sampleRate,
                                                                   channels: 1, interleaved: false)!,
                                          frameCapacity: AVAudioFrameCount(n)) else { return }
        mono.frameLength = AVAudioFrameCount(n)
        let m = mono.floatChannelData![0]
        memcpy(m, data[0], n * 4)
        for c in 1..<max(1, ch) { vDSP_vadd(m, 1, data[c], 1, m, 1, vDSP_Length(n)) }
        var scale = 1 / Float(max(1, ch))
        vDSP_vsmul(m, 1, &scale, m, 1, vDSP_Length(n))

        lock.lock(); defer { lock.unlock() }
        if converter == nil || converterInput != mono.format {
            converter = AVAudioConverter(from: mono.format, to: refFormat)
            converterInput = mono.format
        }
        guard let converter,
              let out = AVAudioPCMBuffer(pcmFormat: refFormat,
                                         frameCapacity: AVAudioFrameCount(Double(n) * Self.sampleRate / buffer.format.sampleRate) + 64)
        else { return }
        var done = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if done { status.pointee = .noDataNow; return nil }
            done = true
            status.pointee = .haveData
            return mono
        }
        guard err == nil, out.frameLength > 0 else { return }
        anchor = (written, hostTime)
        let p = out.floatChannelData![0]
        for i in 0..<Int(out.frameLength) { ring[(written + i) % ring.count] = p[i] }
        written += Int(out.frameLength)
        lastReference = Date()
    }

    // MARK: Mikrofon (Aufnahme-Thread, 16 kHz mono)

    /// Zieht den geschätzten Klang-Anteil in place ab.
    func process(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        guard let p = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard let anchor, Date().timeIntervalSince(lastReference) < 1 else { return }
        let n = Int(buffer.frameLength)
        // Referenz-Index des ersten Mikrofon-Samples
        let dt = (Double(hostTime) - Double(anchor.host)) / Self.ticksPerSecond
        let start = anchor.index + Int((dt * Self.sampleRate).rounded())
        // Fenster für Sample i: Referenz [start+i+lead-taps+1 … start+i+lead]
        let first = start + lead - taps + 1
        guard first >= written - ring.count + 1 else { return }   // fehlende Referenz zählt als Stille
        var seg = [Float](repeating: 0, count: n + taps - 1)
        for k in 0..<seg.count {
            let idx = first + k
            seg[k] = (idx >= 0 && idx < written) ? ring[idx % ring.count] : 0
        }
        seg.withUnsafeBufferPointer { s in
            weights.withUnsafeMutableBufferPointer { w in
                // laufende Energie des Fensters
                var energy: Float = 0
                vDSP_svesq(s.baseAddress!, 1, &energy, vDSP_Length(taps))
                for i in 0..<n {
                    let x = s.baseAddress! + i
                    var y: Float = 0
                    vDSP_dotpr(w.baseAddress!, 1, x, 1, &y, vDSP_Length(taps))
                    let e = p[i] - y
                    p[i] = e
                    if energy > 1e-7 {
                        var g = mu * e / (energy + 1e-6)
                        vDSP_vsma(x, 1, &g, w.baseAddress!, 1, w.baseAddress!, 1, vDSP_Length(taps))
                    }
                    if i + 1 < n {
                        energy += x[taps] * x[taps] - x[0] * x[0]
                        if energy < 0 { energy = 0 }
                    }
                }
            }
        }
    }
}
