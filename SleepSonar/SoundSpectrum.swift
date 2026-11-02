import Accelerate
import AVFoundation
import SwiftUI

/// Frequenzbänder der gerade gespielten Klänge (für das Leuchten um den Probehören-Knopf).
/// Wird aus dem Abgriff am Mischer gefüttert (Audio-Thread), gelesen von der Anzeige (Hauptthread).
final class SoundSpectrum: @unchecked Sendable {
    static let shared = SoundSpectrum()
    static let bandCount = 24

    private let lock = NSLock()
    private var smoothed = [Float](repeating: 0, count: bandCount)
    private let n = 2048
    private let log2n: vDSP_Length = 11
    private let setup: FFTSetup
    private var window: [Float]

    private init() {
        setup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: 2048)
        vDSP_hann_window(&window, vDSP_Length(2048), Int32(vDSP_HANN_NORM))
    }

    /// aktuelle Bänder 0 … 1 (tief → hoch)
    var bands: [Float] {
        lock.lock(); defer { lock.unlock() }
        return smoothed
    }

    func reset() {
        lock.lock(); smoothed = [Float](repeating: 0, count: Self.bandCount); lock.unlock()
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData, Int(buffer.frameLength) >= n else { return }
        var x = [Float](repeating: 0, count: n)
        vDSP_vmul(ch[0], 1, window, 1, &x, 1, vDSP_Length(n))
        var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                x.withUnsafeBufferPointer { xp in
                    xp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }
        // logarithmische Bänder von ~40 Hz bis ~12 kHz
        let sr = Float(buffer.format.sampleRate)
        let binHz = sr / Float(n)
        var out = [Float](repeating: 0, count: Self.bandCount)
        for b in 0..<Self.bandCount {
            let f0 = 40 * pow(300, Float(b) / Float(Self.bandCount))
            let f1 = 40 * pow(300, Float(b + 1) / Float(Self.bandCount))
            let i0 = max(1, Int(f0 / binHz)), i1 = min(n / 2 - 1, max(i0 + 1, Int(f1 / binHz)))
            var m: Float = 0
            vDSP_meanv(Array(mags[i0..<i1]), 1, &m, vDSP_Length(i1 - i0))
            let db = 10 * log10(m + 1e-12)
            out[b] = min(1, max(0, (db + 40) / 60))   // etwa −40 … +20 dB(FFT) → 0 … 1
        }
        lock.lock()
        for b in 0..<Self.bandCount {
            // schnell rauf, langsam runter
            let k: Float = out[b] > smoothed[b] ? 0.5 : 0.12
            smoothed[b] += k * (out[b] - smoothed[b])
        }
        lock.unlock()
    }
}

/// Leuchten um den Probehören-Knopf, das mit dem Klang atmet: ringsum wölbt es sich je nach
/// Lautstärke der Frequenzbänder unterschiedlich weit hinaus (tiefe Töne unten, hohe oben).
struct SpectrumGlow: View {
    var playing: Bool
    /// Radius des Knopfs
    var inner: CGFloat = 56
    var reach: CGFloat = 30

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !playing)) { _ in
            Canvas { ctx, size in
                let bands = SoundSpectrum.shared.bands
                guard !bands.isEmpty else { return }
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let steps = 120
                var path = Path()
                for k in 0...steps {
                    let theta = Double(k) / Double(steps) * 2 * .pi       // 0 = unten, im Uhrzeigersinn
                    // 0 (unten) … 1 (oben), links und rechts gleich
                    let u = theta <= .pi ? theta / .pi : (2 * .pi - theta) / .pi
                    let x = u * Double(bands.count - 1)
                    let i0 = Int(x), i1 = min(bands.count - 1, i0 + 1)
                    let f = Float(x - Double(i0))
                    let v = CGFloat(bands[i0] * (1 - f) + bands[i1] * f)
                    let r = inner + 6 + v * reach
                    let angle = Double.pi / 2 + theta
                    let p = CGPoint(x: c.x + cos(angle) * r, y: c.y + sin(angle) * r)
                    if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                path.closeSubpath()
                ctx.fill(path, with: .radialGradient(
                    Gradient(colors: [Theme.accent.opacity(0.55), Theme.accent.opacity(0.18), .clear]),
                    center: c, startRadius: inner * 0.9, endRadius: inner + reach + 8))
            }
            .blur(radius: 10)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
