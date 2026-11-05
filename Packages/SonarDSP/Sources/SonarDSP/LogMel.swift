import Foundation

/// Log-Mel-Spektrogramm genau wie beim Training (torchaudio.transforms.MelSpectrogram mit
/// 16 kHz, n_fft 1024, Hop 1600 = 10 Bilder je Sekunde, 64 Mel-Bänder von 50 bis 7800 Hz,
/// Hann-Fenster, zentriert mit Spiegelung, Leistung, HTK-Mel-Skala, ohne Normierung).
///
/// Wie im Training wird der Ton in 10-min-Stücken gerechnet (jedes Stück eigens zentriert) und
/// danach die ganze Nacht normiert: je Band der Median abgezogen, durch die Standardabweichung
/// aller Werte geteilt.
public struct LogMel: Sendable {
    public static let sampleRate = 16000
    public static let nFFT = 1024
    public static let hop = 1600
    public static let bands = 64
    public static let framesPerEpoch = 300
    public static let segmentSeconds = 600

    private let window: [Float]
    private let filters: [[(Int, Float)]]   // je Band: (FFT-Bin, Gewicht) ungleich 0
    private let fft: FFT

    public init() {
        let n = Self.nFFT
        window = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
        fft = FFT(n: n)
        // Mel-Filterbank wie torchaudio.functional.melscale_fbanks (htk, norm None)
        let nFreqs = n / 2 + 1
        func hz2mel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
        func mel2hz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
        let allFreqs = (0..<nFreqs).map { Double($0) * Double(Self.sampleRate / 2) / Double(nFreqs - 1) }
        let mMin = hz2mel(50), mMax = hz2mel(7800)
        let fPts = (0..<(Self.bands + 2)).map { mel2hz(mMin + (mMax - mMin) * Double($0) / Double(Self.bands + 1)) }
        var fb: [[(Int, Float)]] = []
        for b in 0..<Self.bands {
            var row: [(Int, Float)] = []
            for (i, f) in allFreqs.enumerated() {
                let down = (f - fPts[b]) / (fPts[b + 1] - fPts[b])
                let up = (fPts[b + 2] - f) / (fPts[b + 2] - fPts[b + 1])
                let w = max(0, min(down, up))
                if w > 0 { row.append((i, Float(w))) }
            }
            fb.append(row)
        }
        filters = fb
    }

    /// log(Mel + 1e-10) für ein Stück Ton: Bilder × Bänder, ohne das letzte (zentrierte) Bild,
    /// so wie im Training `[:, : len(seg) // 1600]`.
    public func segment(_ x: [Float]) -> [[Float]] {
        let n = Self.nFFT, half = n / 2
        let frames = x.count / Self.hop
        guard frames > 0, x.count > half else { return [] }
        // Spiegelung an den Rändern (reflect, ohne Randwert)
        func at(_ i: Int) -> Float {
            var j = i
            if j < 0 { j = -j }
            if j >= x.count { j = 2 * (x.count - 1) - j }
            return x[max(0, min(x.count - 1, j))]
        }
        var out: [[Float]] = []
        out.reserveCapacity(frames)
        var re = [Float](repeating: 0, count: n), im = [Float](repeating: 0, count: n)
        var power = [Float](repeating: 0, count: n / 2 + 1)
        for f in 0..<frames {
            let start = f * Self.hop - half
            for k in 0..<n {
                let i = start + k
                re[k] = (i >= 0 && i < x.count ? x[i] : at(i)) * window[k]
                im[k] = 0
            }
            fft.forward(&re, &im)
            for k in 0...(n / 2) { power[k] = re[k] * re[k] + im[k] * im[k] }
            var row = [Float](repeating: 0, count: Self.bands)
            for b in 0..<Self.bands {
                var s: Float = 0
                for (i, w) in filters[b] { s += power[i] * w }
                row[b] = log(s + 1e-10)
            }
            out.append(row)
        }
        return out
    }

    /// Ganze Nacht: Ton (16 kHz) → normierte Epochen-Bilder, je Epoche 64 × 300 Werte
    /// (Band-weise hintereinander, wie das Modell sie erwartet: [Band][Bild]).
    public func night(_ x: [Float], epochs maxEpochs: Int? = nil) -> (epochs: Int, values: [Float]) {
        let sr = Self.sampleRate
        var n = x.count / (sr * 30)
        if let maxEpochs { n = min(n, maxEpochs) }
        guard n > 0 else { return (0, []) }
        let usable = n * 30 * sr
        var frames: [[Float]] = []
        frames.reserveCapacity(n * Self.framesPerEpoch)
        var s = 0
        while s < usable {
            let e = min(usable, s + sr * Self.segmentSeconds)
            frames.append(contentsOf: segment(Array(x[s..<e])))
            s = e
        }
        frames = Array(frames.prefix(n * Self.framesPerEpoch))
        return (n, Self.normalize(frames, epochs: n))
    }

    /// Je Band den Median abziehen (bei gerader Anzahl der untere, wie torch.median), dann durch
    /// die Standardabweichung aller Werte (mit n−1) teilen.
    public static func normalize(_ frames: [[Float]], epochs n: Int) -> [Float] {
        let T = frames.count
        var med = [Float](repeating: 0, count: bands)
        var col = [Float](repeating: 0, count: T)
        for b in 0..<bands {
            for t in 0..<T { col[t] = frames[t][b] }
            col.sort()
            med[b] = col[(T - 1) / 2]
        }
        var sum = 0.0, sq = 0.0
        for t in 0..<T { for b in 0..<bands { let v = Double(frames[t][b] - med[b]); sum += v; sq += v * v } }
        let count = Double(T * bands)
        let mean = sum / count
        let sd = Float(((sq - count * mean * mean) / max(1, count - 1)).squareRoot()) + 1e-6
        // Ausgabe: Epoche, Band, Bild
        var out = [Float](repeating: 0, count: n * bands * framesPerEpoch)
        for e in 0..<n {
            for b in 0..<bands {
                let base = (e * bands + b) * framesPerEpoch
                for k in 0..<framesPerEpoch {
                    let t = e * framesPerEpoch + k
                    out[base + k] = t < T ? (frames[t][b] - med[b]) / sd : 0
                }
            }
        }
        return out
    }
}

/// Einfache Radix-2-FFT (komplex, in place), ohne Accelerate – läuft auch auf Linux (Tests).
struct FFT: Sendable {
    let n: Int
    private let cosT: [Float], sinT: [Float], rev: [Int]

    init(n: Int) {
        self.n = n
        let bits = Int(log2(Double(n)))
        cosT = (0..<(n / 2)).map { Float(cos(-2 * Double.pi * Double($0) / Double(n))) }
        sinT = (0..<(n / 2)).map { Float(sin(-2 * Double.pi * Double($0) / Double(n))) }
        rev = (0..<n).map { i in
            var r = 0, v = i
            for _ in 0..<bits { r = (r << 1) | (v & 1); v >>= 1 }
            return r
        }
    }

    func forward(_ re: inout [Float], _ im: inout [Float]) {
        for i in 0..<n where rev[i] > i { re.swapAt(i, rev[i]); im.swapAt(i, rev[i]) }
        var size = 2
        while size <= n {
            let halfSize = size / 2, step = n / size
            var start = 0
            while start < n {
                var k = 0
                for j in start..<(start + halfSize) {
                    let wr = cosT[k], wi = sinT[k]
                    let l = j + halfSize
                    let tr = re[l] * wr - im[l] * wi
                    let ti = re[l] * wi + im[l] * wr
                    re[l] = re[j] - tr; im[l] = im[j] - ti
                    re[j] += tr; im[j] += ti
                    k += step
                }
                start += size
            }
            size *= 2
        }
    }
}
