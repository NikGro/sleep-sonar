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
    /// langsamer Mittelwert je Band (dB): das Leuchten zeigt, was gerade lauter oder leiser ist als üblich
    private var slow = [Float](repeating: -200, count: bandCount)
    private var slowTotal: Float = -200
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
        lock.lock()
        smoothed = [Float](repeating: 0, count: Self.bandCount)
        slow = [Float](repeating: -200, count: Self.bandCount)
        slowTotal = -200
        lock.unlock()
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        // die jüngsten n Werte (kürzere Puffer mit Nullen auffüllen)
        let len = Int(buffer.frameLength), take = min(n, len)
        var x = [Float](repeating: 0, count: n)
        for i in 0..<take { x[i] = ch[0][len - take + i] * window[i] }
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
        var dbs = [Float](repeating: 0, count: Self.bandCount)
        for b in 0..<Self.bandCount {
            let f0 = 40 * pow(300, Float(b) / Float(Self.bandCount))
            let f1 = 40 * pow(300, Float(b + 1) / Float(Self.bandCount))
            let i0 = max(1, Int(f0 / binHz)), i1 = min(n / 2 - 1, max(i0 + 1, Int(f1 / binHz)))
            var m: Float = 0
            vDSP_meanv(Array(mags[i0..<i1]), 1, &m, vDSP_Length(i1 - i0))
            dbs[b] = 10 * log10(m + 1e-12)
        }
        // Gesamtlautstärke des Puffers
        var ms: Float = 0
        vDSP_measqv(ch[0], 1, &ms, vDSP_Length(buffer.frameLength))
        let total = 10 * log10(ms + 1e-12)
        lock.lock()
        if slowTotal < -150 { slowTotal = total; slow = dbs }
        slowTotal += 0.02 * (total - slowTotal)
        // Ganzes Leuchten: kräftig, wenn es lauter wird als zuletzt üblich; in leisen Momenten fast weg
        let whole = max(-1, min(1, (total - slowTotal) / 2.5))
        for b in 0..<Self.bandCount {
            slow[b] += 0.02 * (dbs[b] - slow[b])
            // Form: Band lauter als sein Mittel → an dieser Stelle weiter hinaus
            let shape = max(-1, min(1, (dbs[b] - slow[b]) / 4))
            // leise Momente → fast nichts, laute → ganz ausgedehnt
            let target = max(0, min(1, 0.5 + 0.5 * whole + 0.25 * shape))
            // sofort rauf, zügig runter
            let k: Float = target > smoothed[b] ? 0.9 : 0.5
            smoothed[b] += k * (target - smoothed[b])
        }
        lock.unlock()
    }
}

/// Leuchten um den Probehören-Knopf, das mit dem Klang atmet: ringsum wölbt es sich je nach
/// Lautstärke der Frequenzbänder unterschiedlich weit hinaus (tiefe Töne unten, hohe oben).
struct SpectrumGlow: View {
    /// weich zwischen den Messungen (~10 je Sekunde) gleiten, damit 60 Bilder/s ruhig wirken
    private final class Easing { var values: [Float] = [] }
    @State private var easing = Easing()
    var playing: Bool
    /// Radius des Knopfs
    var inner: CGFloat = 56
    var reach: CGFloat = 30

    var body: some View {
        // Die Werte je Bild außerhalb der Zeichenfläche holen und hineinreichen: Nur so zeichnet SwiftUI
        // neu – liest die Zeichenfläche sie selbst, sieht SwiftUI keine Änderung (es erneuerte sich
        // nur zufällig, z. B. beim Bildschirmfoto).
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !playing)) { tl in
            glow(bands: eased(tl.date))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func eased(_ date: Date) -> [Float] {
        let target = SoundSpectrum.shared.bands
        if easing.values.count != target.count { easing.values = target }
        for i in target.indices { easing.values[i] += 0.35 * (target[i] - easing.values[i]) }
        return easing.values
    }

    private func glow(bands: [Float]) -> some View {
            Canvas { ctx, size in
                guard !bands.isEmpty else { return }
                // Helligkeit folgt der Lautstärke: in stillen Momenten kaum zu sehen
                let mean = CGFloat(bands.reduce(0, +) / Float(bands.count))
                ctx.opacity = 0.2 + 0.8 * min(1, mean * 1.3)
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
                    let r = inner + 2 + v * reach
                    let angle = Double.pi / 2 + theta
                    let p = CGPoint(x: c.x + cos(angle) * r, y: c.y + sin(angle) * r)
                    if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                path.closeSubpath()
                ctx.fill(path, with: .radialGradient(
                    Gradient(colors: [Theme.accent.opacity(0.95), Theme.accent.opacity(0.55), Theme.accent.opacity(0.08)]),
                    center: c, startRadius: inner * 0.95, endRadius: inner + reach))
            }
            .blur(radius: 7)
    }
}
